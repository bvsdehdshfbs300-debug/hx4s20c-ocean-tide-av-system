//============================================================================
// boot_anim.v —— 开场动画「白幕显影」（4.50 秒，开机播放一次）
//
// 设计依据：STATE.md 第十节 + 第十一节（用户已确认，以白幕方案为准）
//
//   0.00s        纯白（像一张没曝光的相纸）
//   0.60s        光刃自上而下开始扫过，略斜
//                扫过处白色溶解，露出后面的海景（月亮/波浪/泡沫/灯塔…）
//   2.22s        光刃到底，海景完全显现
//   2.22~3.39s   定格；白幕强度从 0 涨到峰值
//   3.39~4.50s   白幕像退潮一样从下往上退去并溶解，融入主界面
//   任意键        跳过：帧号按 SKIP_STEP 大步前进，200ms 内补到满
//
// 三个技术点（对应策划里写的 ①②③）：
//   ① 余晖拖尾（一阶 IIR）： trail <= trail + ((blade - trail) >>> 3)
//      拖尾边界永远滞后于光刃，滞后量正比于光刃速度 —— 扫得越快拖得越长。
//   ② 斜切 + ease：ys = y + (x >> 4) 就是斜切（640px 跨 40px，约 3.6 度）。
//      ease 用【速度累加器】做：前 ACC_N 帧每帧 +VEL_ACC，之后每帧 -VEL_DEC，
//      速度三角形积分出位置。全程只有加法与移位，不占乘法器，也不用存 LUT。
//   ③ 字与光同源：不给文字单独做动画 —— 白幕按行盖住【整幅画面】，
//      白幕没退的地方连同文字一起是白的，光扫到哪一行哪一行的字才出来。
//
// 【为什么白幕放在 Stage 1（s1 流水寄存器之前）而不是最后】
//   白色是饱和色：白幕盖住之后，不论下面是原色还是加色发光，混合结果都是 255。
//   所以放在加法层【之前】和放在整条链路【之后】画面完全一样。
//   但放在前面能被【已有的】s1 寄存器吸收 —— 不新增流水级、不给输出通路
//   新添乘法器延迟。这条链路的余量本来就不宽（KNOWN_ISSUES 里有记录）。
//
// 【分两个模块的原因】
//   署名 r12/r13 要在【文字那一层】就被 boot_active 门控，而那一层在文件很早的
//   位置；白幕混合又要走 x/y。所以时基（boot_timebase）在文件前部例化，
//   混合器（boot_veil）在 Stage 1 例化，各取所需。
//============================================================================

//----------------------------------------------------------------------------
// 时基：帧计数 + 光刃位置 + 余晖 + 退潮边界。全部【每帧】算一次。
//----------------------------------------------------------------------------
module boot_timebase(
    input  wire       clk,
    input  wire       rst,
    input  wire       vs,              // 垂直同步（低有效）
    input  wire       skip,            // 已同步到本域的“任意键”电平
    input  wire       link_up,         // 显示链路已握手（EDID 读完 = 显示器在）
    output reg        boot_active,     // 动画进行中（署名只在期间显示）
    output reg signed [12:0] blade,    // 光刃位置（px，可负 = 屏幕上方外）
    output reg signed [12:0] trail,    // 余晖拖尾边界（一阶 IIR）
    output reg signed [12:0] ebb,      // 退潮白幕边界
    output reg [7:0]  ebb_amt,        // 退潮白幕强度
    output wire [1:0] warm_fade       // 黄光刃强度档：0 满 / 1 半 / 2 四分之一 / 3 关
);
    // ---- 帧边界 = vs 的下降沿（vs 低有效，y 在 vs 低时被复位）----
    reg vs_d;
    always @(posedge clk or posedge rst) begin
        if (rst) vs_d <= 1'b1;
        else     vs_d <= vs;
    end
    wire frame_start = vs_d && !vs;

    // ---- 节拍表（640x480 @ 59.52Hz，1 帧 = 16.80ms）----
    localparam [8:0] F_WHITE_END = 9'd36;     // 0.60s 纯白结束，光刃起扫
    localparam [8:0] F_SWEEP_END = 9'd156;    // 2.62s 光刃到底，海景全显
    localparam [8:0] F_HOLD_END  = 9'd202;    // 3.39s 定格结束，退潮开始
    localparam [8:0] F_TOTAL     = 9'd268;    // 4.50s 结束，交还主界面
    localparam [8:0] SKIP_STEP   = 9'd24;     // 跳过步长：最坏 268/24*16.8ms ≈ 188ms

    //----------------------------------------------------------------------
    // 【等显示链路】—— 修"重启后看不到开场动画"
    //
    // 原来帧计数从 rst 释放就开始走（上电后约 20ms），268 帧 = 4.5s。
    // 但 HDMI core 这时才刚开始读 EDID、显示器还要自己锁一次信号
    // （常见的电视要 3~8 秒），于是 4.5 秒在你看到任何东西之前就跑完了。
    //
    // FPGA 【看不到】显示器什么时候锁住 —— 顶层连 HPD 引脚都没有，
    // core 的 O_video_locked 也是空的。所以只能：
    //   ① 用 EDID 读完（显示器应答了 DDC = 对面在、握手完成）当门；
    //   ② 再等一个可调延时，把显示器自己锁定那几秒盖住。
    //
    // 等待期间画面【停在第一帧 = 纯白】，所以这段等待看起来就是
    // "白幕静场"长了一点，不会像是死机或黑屏。
    //
    // 【手感不对就改这两个数】
    //   START_DELAY 调大 -> 白幕多停一会儿（显示器慢就把这个加大）
    //   1 帧 = 16.80ms；300 帧 = 5.0s
    // 默认取 5.0s 而不是 3s：用户报告"重启后完全看不到动画"，
    // 而动画原本只占 0~4.5s，说明显示器锁定发生在 4.5s 之后，
    // 延时给 3s 仍然会漏掉开头。宁可白幕多停一会儿，也不要再看不到。
    localparam [9:0]  START_DELAY = 10'd390;   // 链路就绪后再等 6.5s
    localparam [11:0] WAIT_MAX    = 12'd840;   // 兜底：最多等 14.1s（防显示器 DDC 不通时卡死）

    // ---- 光刃行程与速度 ----
    // 【为什么必须走到 600 而不是 480】屏幕"斜切坐标" ys = y + (x>>4) 最大能到
    //   479 + 39 = 518，而主刃口要 d = blade - ys >= 64 才算【完全】化开。
    //   原来 BLADE_END = 480：屏幕最底一行差 d = 480-518 = -38 -> 恒为纯白，
    //   署名（ys 458..465）也要 blade >= 529 才全露 —— 结果【署名永远没被扫到】，
    //   底部信息栏右半边也一直是白的。走到 600 才能把整屏（含最右下角）扫干净。
    //
    // 位移校验 = 峰值速度 * 总帧数 / 2 / 2^5 = 352 * 120 / 2 / 32 = 660 = 600-(-60) ✓
    localparam signed [12:0] BLADE_START = -13'sd60;
    localparam signed [12:0] BLADE_END   = 13'sd600;
    localparam [5:0]  ACC_N   = 6'd32;        // 前 32 帧加速
    localparam signed [12:0] VEL_ACC = 13'sd11;
    localparam signed [12:0] VEL_DEC = 13'sd4;   // 11*32 == 4*88，峰值速度对齐

    // ---- 退潮 ----
    // 【方向：白幕自下而上退去】—— 用户 2026-10-05 最终要求。
    // 白幕占据 ys <= ebb 的【上方】，ebb 从 480（整屏都是白的）减到 -60，
    // 白幕的【下沿】一路上升、最后从屏幕上沿退出，海景从下方先露出来。
    localparam signed [12:0] EBB_START = 13'sd480;
    localparam [7:0]  EBB_MAX = 8'd138;       // 138 = 2*69，和定格段的斜率正好接上

    reg [8:0]  bf;         // 帧号
    reg [8:0]  sf;         // 扫描段内的帧序号
    reg signed [12:0] vel;
    reg signed [23:0] pos_acc;   // 1/32 px 累加器

    // ---- 显示链路等待 ----
    reg        link_seen;  // EDID 读到过（电平锁存，脉冲/电平都吃得下）
    reg [9:0]  pre_cnt;    // 链路就绪之后又等了多少帧
    reg [11:0] wait_cnt;   // 从复位起一共等了多少帧（兜底用）
    wire       boot_go = (link_seen && (pre_cnt >= START_DELAY)) || (wait_cnt >= WAIT_MAX);

    // ---- 黄光刃强度档（每帧一个值，逐像素那边只做移位）----
    // 两件事必须靠它解决，否则预览里一眼就能看出来：
    //   ① 光刃还在屏幕上方时，暖区会漏到屏幕顶部，把"纯白起"弄成"顶部淡黄"；
    //   ② 光刃扫到底之后停在 y=480 不动，黄光会永远赖在屏幕下沿。
    // 注意：warm_fade 已经在端口表里声明成 output wire 了，
    // 这里只能 assign，不能再来一句 "wire [1:0] warm_fade = ..." ——
    // 那是【重复声明 + 初始化】，TD 会直接报 HDL-8007。
    assign warm_fade =
          (blade < 13'sd0)              ? 2'd3 :   // 刃还没进屏 -> 纯白
          (bf    <= F_SWEEP_END)        ? 2'd0 :   // 扫描中 -> 满强度
          (bf    <= F_SWEEP_END + 9'd24)? 2'd1 :   // 扫完 0.40s -> 半
          (bf    <= F_SWEEP_END + 9'd48)? 2'd2 :   // 再 0.40s -> 四分之一
                                          2'd3;    // 关掉（退潮开始时黄光已经没了）

    // ---- 下一帧的组合值（先算好，再一起打拍）----
    wire [8:0] step    = skip ? SKIP_STEP : 9'd1;
    wire [8:0] bf_next = ((bf + step) > F_TOTAL) ? F_TOTAL : (bf + step);

    wire signed [12:0] vel_step = (sf < ACC_N) ? VEL_ACC
                                : (vel > 13'sd0) ? -VEL_DEC : 13'sd0;
    wire signed [12:0] vel_next = vel + vel_step;
    wire signed [23:0] pos_next = pos_acc + vel_next;
    wire signed [12:0] blade_n  = pos_next >>> 5;

    wire signed [12:0] blade_new = (bf_next <= F_WHITE_END) ? BLADE_START :
                                   (bf_next <= F_SWEEP_END) ? blade_n    : BLADE_END;
    wire signed [12:0] trail_new = trail + ((blade_new - trail) >>> 3);

    wire [8:0] ebb_i  = bf_next - F_HOLD_END;     // 0..66
    // 【退潮强度的坑】原来让白幕在【定格阶段】就从 0 涨到峰值（怕退潮"啪"一下），
    // 结果定格那 1.2 秒整屏被糊上 54% 白 —— 片名在最上方，直接被糊掉；
    // 而场景名/底部在下方，退潮时下方先 clear，所以它们后来反而清晰了。
    // 现在改成：定格阶段【一点都不糊】，退潮开始的 8 帧内快速涨到峰值。
    // 0.13s 的建立时间肉眼基本看不出"啪"，但换回了定格时干净的画面。
    wire [8:0] ebb_ramp = (ebb_i < 9'd8) ? (ebb_i << 4) : {1'b0, EBB_MAX};
    wire [8:0] amt_new  = (bf_next < F_HOLD_END) ? 9'd0 : ebb_ramp;
    // 退潮边界【上移】（白幕自下而上退去）
    wire signed [12:0] ebb_new = (bf_next < F_HOLD_END) ? EBB_START
                                                        : (EBB_START - (ebb_i << 3));

    // 【片名不再单独做行扫描】用户最终要求：光扫到哪一行，哪一行的字才被写出来。
    // 这由白幕本身完成 —— 白幕按行盖住整幅画面，字跟着一起显影，
    // 所以 boot_timebase 不需要再输出任何"写字进度"。

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bf          <= 9'd0;
            sf          <= 9'd0;
            vel         <= 13'sd0;
            pos_acc     <= BLADE_START <<< 5;
            blade       <= BLADE_START;
            trail       <= BLADE_START;
            ebb         <= EBB_START;
            ebb_amt     <= 8'd0;
            boot_active <= 1'b1;
            link_seen   <= 1'b0;
            pre_cnt     <= 10'd0;
            wait_cnt    <= 12'd0;
        end else if (frame_start) begin
            // ---- 显示链路等待：这三个计数器【不管 boot_go】都要走 ----
            if (link_up) link_seen <= 1'b1;
            if (wait_cnt < WAIT_MAX)                 wait_cnt <= wait_cnt + 12'd1;
            if (link_seen && (pre_cnt < START_DELAY)) pre_cnt <= pre_cnt + 10'd1;

            // ---- 动画本体：只在 boot_go 之后才动 ----
            // 在那之前画面停在第一帧（纯白），看起来就是白幕静场久一点。
            if (boot_go) begin
                bf          <= bf_next;
                sf          <= (bf_next <= F_WHITE_END) ? 9'd0 : (sf + 9'd1);
                vel         <= (bf_next <= F_WHITE_END) ? 13'sd0 : vel_next;
                pos_acc     <= (bf_next <= F_WHITE_END) ? (BLADE_START <<< 5) : pos_next;
                blade       <= blade_new;
                trail       <= trail_new;
                ebb         <= ebb_new;
                ebb_amt     <= amt_new[7:0];
            end
            // 等待期间保持 boot_active=1 -> 白幕满 -> 纯白（就是动画的第一帧）
            boot_active <= boot_go ? (bf_next < F_TOTAL) : 1'b1;
        end
    end
endmodule

//----------------------------------------------------------------------------
// 白幕混合：把「未显影 = 纯白」按行盖到画面上。
//
// 【ys 是上一级算好并打拍送进来的，不是在这里现算】
//   第一版这里吃 x/y 现算 ys，结果 x_reg -> ... -> MULT18 -> s1_repl 成了
//   全设计最长的路径：39.6ns / 40ns，余量只剩 +103ps。报告里 net 占 23.5ns（60%），
//   也就是 KNOWN_ISSUES 说的"组合逻辑扇出过大 -> 布线拥塞"。
//   按那一条的修法【插一级流水寄存器】：ys 和 repl 先各存一拍，这一级只剩
//   一次 8x8 乘法与加法，路径被砍掉一半以上，而且下游完全不用动。
//----------------------------------------------------------------------------
module boot_veil(
    input  wire [10:0] ys,            // 斜切后的行坐标 = y + (x>>4)，已打拍
    input  wire [23:0] rgb_in,        // Stage 1 选出来的颜色（含文字/菜单/署名）
    input  wire signed [12:0] blade,
    input  wire signed [12:0] trail,
    input  wire signed [12:0] ebb,
    input  wire [7:0]  ebb_amt,
    input  wire        boot_active,
    input  wire [1:0]  warm_fade,     // 黄光刃强度档（0 满 / 3 关）
    input  wire        fg_on,         // 前景豁免：灯塔。置 1 时【不受白幕影响】
    output wire [23:0] rgb_out
);
    wire signed [12:0] ys_s = {3'b0, ys};
    wire signed [12:0] d    = blade - ys_s;      // >0 = 光刃已扫过这一行
    wire signed [12:0] dt   = trail - ys_s;      // >0 = 在余晖拖尾范围内

    // ---- 主刃口：刃前全白；刃后 64px 线性余晖 ----
    reg [8:0] v_main;
    always @* begin
        if (d <= 13'sd0)             v_main = 9'd255;
        else if (d < 13'sd64)        v_main = 9'd255 - ({3'b0, d[5:0]} << 2);
        else                         v_main = 9'd0;
    end

    // ---- 拖尾：更宽更弱的一层，边界是滞后于光刃的 IIR 值 ----
    reg [8:0] v_trail;
    always @* begin
        if ((dt > 13'sd0) && (dt < 13'sd128)) v_trail = 9'd128 - {2'b0, dt[6:0]};
        else                                  v_trail = 9'd0;
    end

    wire [8:0] veil_a = (v_main > v_trail) ? v_main : v_trail;

    // ---- 退潮：白幕占据 ys <= ebb 的【上方】，ebb 下降 = 白幕自下而上退去 ----
    wire [8:0] veil_b = ((ys_s <= ebb) && ({1'b0, ebb_amt} > veil_a))
                        ? {1'b0, ebb_amt} : veil_a;
    // 动画结束后必须【逐像素等于原值】，不能让残留的白幕挂在主界面上
    wire [8:0] veil   = (!boot_active) ? 9'd0 : ((veil_b > 9'd255) ? 9'd255 : veil_b);

    // ---- 混合：out = in + ((幕布色 - in) * veil) >> 8 ----
    // 用 >>8 而不是 /255：误差 <= 1/255，肉眼不可见，但省掉一个除法器。
    wire [7:0]  vr  = veil[7:0];
    wire [7:0]  ir  = 8'd255 - rgb_in[23:16];
    wire [7:0]  ig  = 8'd255 - rgb_in[15:8];
    wire [7:0]  ib  = 8'd255 - rgb_in[7:0];
    wire [15:0] pr  = ir * vr;
    wire [15:0] pg  = ig * vr;
    wire [15:0] pb  = ib * vr;

    wire [7:0]  mr = rgb_in[23:16] + pr[15:8];
    wire [7:0]  mg = rgb_in[15:8]  + pg[15:8];
    wire [7:0]  mb = rgb_in[7:0]   + pb[15:8];

    //========================================================================
    // 黄光刃 —— 【必须靠混色，不能靠加色】
    //
    // STATE.md 第十一节已经记过这个坑：灯塔光晕是加色混合，
    // 在【白底上完全失效】（白已经最亮，再加还是白）。
    // 所以"在白幕上画一道黄光"用加色是做不出来的，看不见。
    //
    // 这里改成【把幕布本身染暖】：刃口附近的幕布色从
    //   白 (255,255,255) 拉向 灯塔黄 (255,218,98)
    // ——比例沿用光束那套（R 给满、G 约 0.86、B 约 0.38），
    // 于是白幕上能真看见一道暖黄的光扫过去，而不是加了个看不见的东西。
    //
    // 削减量写成【常数乘法】：cut = (255 - 幕布色) * weff >> 8，
    // 需要 37/157 两个常数乘 —— TD 会用移位加法实现，不额外占乘法器。
    //
    // weff = min(warm, veil)：warm 表示离刃口多近，veil 表示这里还有多少幕布。
    // 两者取小，保证【已经化开的海景】不会被染黄 —— 那里 veil 小，自然就干净了。
    //========================================================================
    // dw 把暖区中心往"已扫过"一侧偏 16px：白幕一侧约 48px、化开一侧约 80px 带暖色，
    // 看起来就是光扫过去之后留下的余温，而不是一条硬边。
    wire signed [12:0] dw = d + 13'sd16;
    wire signed [12:0] aw = (dw < 13'sd0) ? -dw : dw;
    wire [7:0] wbase = (aw >= 13'sd64) ? 8'd0 : (8'd64 - aw[7:0]);
    wire [7:0] wrm0  = (wbase > 8'd59) ? 8'd240 : (wbase << 2);   // 0..240
    // 按档位衰减：扫完之后黄光必须退掉，不能赖在屏幕下沿
    wire [7:0] wrm   = (warm_fade == 2'd0) ? wrm0 :
                       (warm_fade == 2'd1) ? (wrm0 >> 1) :
                       (warm_fade == 2'd2) ? (wrm0 >> 2) : 8'd0;
    wire [7:0] weff  = (wrm < vr) ? wrm : vr;

    wire [7:0] cut_g = ({8'd0, 8'd37}  * weff) >> 8;   // 255 -> 218
    wire [7:0] cut_b = ({8'd0, 8'd157} * weff) >> 8;   // 255 ->  98

    // mg/mb 一定 >= 对应的 cut：
    //   mg >= (255*veil)>>8 ≈ 0.996*veil，而 cut <= 157*veil/256 ≈ 0.613*veil。
    //
    // 【fg_on】灯塔画在白幕【之上】—— 用户要求"一上电就看得见灯塔立在白幕前"。
    //   所以灯塔像素直接输出原值，白幕和黄光都不作用在它身上。
    //   注意：灯塔的【加色光晕/光束】在 Stage 2，加在白底上是看不见的
    //   （白已最亮）—— 能看见的是塔身本身，这也是用户要的效果。
    assign rgb_out = fg_on ? rgb_in :
                     (veil == 9'd0)
                     ? rgb_in
                     : { mr, mg - cut_g, mb - cut_b };
endmodule
