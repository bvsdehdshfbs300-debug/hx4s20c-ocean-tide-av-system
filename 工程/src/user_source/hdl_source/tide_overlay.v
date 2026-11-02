//============================================================================
// tide_overlay.v  ——  潮汐作曲家 屏幕叠加层（重新设计版）
//
// 设计原则（解决"界面丑"的根本问题）：
//   ① 统一色板   —— 所有元素只从背景图取色（暖白 / 冷紫），不再引入新颜色
//   ② 消灭硬边   —— 一切都做柔光衰减，没有生硬的边界
//   ③ 冷色剪影   —— 灯塔是比背景更暗的冷紫，与画面同色系
//   ④ 让位       —— 删掉音量柱和实心顶栏，把画面留给文字
//
// 相对旧版的改动：
//   月亮   八边形硬边 -> 八边形距离近似圆盘 + 径向光晕 + 水中倒影
//   灯塔   正红直筒矩形 -> 冷紫剪影 + 圆柱明暗 + 螺旋条纹 + 五段结构 +
//                        透视收分 + 塔顶灯脉冲 + 水面光柱（整体加宽 50%）
//   光束   塔顶闪烁的格子方块 -> 缓慢左右扫射的柔光楔形
//   星点   纯白方块 -> 柔光点 + 各自独立闪烁
//   潮汐线 3px 斜杠纹理 -> 1px 正弦柔光双层视差
//   删除   音量柱 / 实心顶栏
//   新增   底部渐变遮罩（给文字铺底）
//   调试面板改为由 dbg_en 控制，默认不显示
//
// 画布 640x480，像素坐标 x[10:0] y[9:0]。
//============================================================================
module tide_overlay(
    input wire clk,
    input wire rst,
    input wire vs,
    input wire de,
    input wire active,
    input wire [7:0] audio_level,
    // 三频带包络（audio_mclk 域，各自两级同步后使用）
    //   低频 -> 深层涌浪（远层：幅度大、波长大、慢）
    //   中频 -> 水面纹理（中层）
    //   高频 -> 泡沫与浪花（近层颗粒）
    input wire [7:0] band_low,
    input wire [7:0] band_mid,
    input wire [7:0] band_high,
    input wire [1:0] scene_index,
    // 文字 OSD 需要的播放状态（来自 sd_card_clk 域，变化很慢，两级同步足够）
    input wire [1:0] osd_idx,        // 当前图片序号 0..3
    input wire [2:0] osd_total,      // 已缓存图片总数
    input wire       osd_auto,       // 1 = 自动轮播，0 = 手动
    input wire [1:0] osd_period,     // 0=1s 1=3s 2=5s
    input wire [2:0] osd_song,       // 当前歌曲号（0 起）
    input wire [2:0] osd_song_total, // 卡上共几首
    // 菜单（sd_card_clk 域，变化极慢，两级同步足够）
    input wire       menu_on,
    input wire [3:0] menu_item,      // 当前选中第几项 0..8
    input wire [2:0] menu_trans,     // 转场方式 0..4（拓展②）
    input wire [1:0] menu_scale,     // 缩放开/关（拓展③，只用 bit0：0=原图 1=推近）
    input wire       menu_music,     // 音乐开/关（2026-10-06 新增）
    input wire [2:0] menu_vol,       // 音量档位 0..6（2026-10-06 新增）
    input wire [1:0] menu_brightness,// 亮度档位 0/1/2/3 = 25/50/75/100%
    input wire [2:0] menu_contrast,  // 对比度档位 0..6 = 50/75/90/100/110/125/150%
    input wire       idle_dim,       // 30 秒无操作后自动降到 25%
    input wire       menu_info,      // 分辨率/缩放比 OSD 开关（拓展④）
    input wire [15:0] bmp_hdr_w,     // BMP 头里的实际宽高（拓展④ 显示用）
    input wire [15:0] bmp_hdr_h,
    // 诊断开关：置 1 时整个叠加层被旁路，只送"转场后的原始画面"。
    // 用途：把"SDRAM/帧缓存坏了"和"叠加层引入噪点"两种情况一刀切开。
    // 开场动画的"任意键跳过"电平（来自 sd_card_clk 域，两级同步后使用）
    input wire       boot_skip,
    // 显示链路已握手（HDMI core 读完 EDID = 显示器在，同一个 video_clk 域）
    input wire       link_up,
    input wire       bypass,
    input wire [2:0] transition_mode,
    input wire [7:0] transition_alpha_gray,
    input wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    reg de_last;
    reg vs_last;
    reg [10:0] x;
    reg [9:0]  y;
    reg [7:0]  level_sync1, level_sync2;
    reg [1:0]  scene_sync1, scene_sync2;

    // OSD 播放状态跨到视频域
    reg [1:0] oi_s1, oi_s2;
    reg [2:0] ot_s1, ot_s2;
    reg       oa_s1, oa_s2;
    reg [1:0] op_s1, op_s2;
    // 菜单状态跨到视频域（变化极慢，两级同步足够）
    reg       mn_s1, mn_s2;
    reg [3:0] mi_s1, mi_s2;
    // 拓展项 ②③④ 的状态也在 sd_card_clk 域，同样两级同步
    reg [2:0] tr_s1, tr_s2;
    reg [1:0] sc_s1, sc_s2;
    reg       mu_s1, mu_s2;      // 音乐开/关（2026-10-06）
    reg [2:0] vol_s1, vol_s2;    // 音量档位（2026-10-06）
    reg [1:0] br_s1, br_s2;      // 亮度档位
    reg [2:0] ct_s1, ct_s2;      // 对比度档位
    reg       idim_s1, idim_s2;  // 自动待机降亮度
    reg       in_s1, in_s2;
    reg [15:0] bw_s1, bw_s2;
    // 歌曲号也来自 sd_card_clk 域，【必须】同步！
    // 漏掉这两根会让 TD 把"sd_card_clk -> 视频域组合逻辑"当成同步路径分析，
    // 实测报出 -12.443ns / 24 条违例（起点 pl_count_reg[2]，终点 s1_repl_reg[5]）。
    reg [2:0] os_s1, os_s2;
    reg [2:0] ost_s1, ost_s2;
    // 【2026-10-05 退残留】bright_lv / cont_lv / vol_lv 的同步寄存器
    // （br_s1/br_s2、ct_s1/ct_s2、vo_s1/vo_s2）已删除。
    // 它们只喂菜单里的亮度/对比度/音量三行数值显示；那三项已经不在菜单里了。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            oi_s1 <= 2'd0; oi_s2 <= 2'd0;
            ot_s1 <= 3'd0; ot_s2 <= 3'd0;
            oa_s1 <= 1'b0; oa_s2 <= 1'b0;
            op_s1 <= 2'd0; op_s2 <= 2'd0;
            mn_s1 <= 1'b0; mn_s2 <= 1'b0;
            mi_s1 <= 4'd0; mi_s2 <= 4'd0;
            tr_s1 <= 3'd0; tr_s2 <= 3'd0;
            sc_s1 <= 2'd0; sc_s2 <= 2'd0;
            mu_s1 <= 1'b1; mu_s2 <= 1'b1;
            vol_s1 <= 3'd1; vol_s2 <= 3'd1;
            br_s1 <= 2'd3; br_s2 <= 2'd3;
            ct_s1 <= 3'd3; ct_s2 <= 3'd3;
            idim_s1 <= 1'b0; idim_s2 <= 1'b0;
            in_s1 <= 1'b1; in_s2 <= 1'b1;
            bw_s1 <= 16'd0; bw_s2 <= 16'd0;
            os_s1 <= 3'd0; os_s2 <= 3'd0;
            ost_s1 <= 3'd0; ost_s2 <= 3'd0;
        end else begin
            oi_s1 <= osd_idx;    oi_s2 <= oi_s1;
            ot_s1 <= osd_total;  ot_s2 <= ot_s1;
            oa_s1 <= osd_auto;   oa_s2 <= oa_s1;
            op_s1 <= osd_period; op_s2 <= op_s1;
            mn_s1 <= menu_on;    mn_s2 <= mn_s1;
            mi_s1 <= menu_item;  mi_s2 <= mi_s1;
            tr_s1 <= menu_trans; tr_s2 <= tr_s1;
            sc_s1 <= menu_scale; sc_s2 <= sc_s1;
            mu_s1 <= menu_music; mu_s2 <= mu_s1;
            vol_s1 <= menu_vol;  vol_s2 <= vol_s1;
            br_s1 <= menu_brightness; br_s2 <= br_s1;
            ct_s1 <= menu_contrast; ct_s2 <= ct_s1;
            idim_s1 <= idle_dim; idim_s2 <= idim_s1;
            in_s1 <= menu_info;  in_s2 <= in_s1;
            bw_s1 <= bmp_hdr_w;  bw_s2 <= bw_s1;
            os_s1 <= osd_song;       os_s2 <= os_s1;
            ost_s1 <= osd_song_total; ost_s2 <= ost_s1;
        end
    end

    //========================================================================
    // 开场动画时基（见 boot_anim.v）
    //
    // "任意键跳过"来自 sd_card_clk 域，那边做成的是【电平】（按下就置 1，
    // 直到复位都保持），所以两级同步就够 —— 和 menu_on / item_sel 一个道理。
    // 【不要跨域传脉冲】：25MHz 域里一拍只有 40ns，同步过去必然丢。
    //========================================================================
    reg bs_s1, bs_s2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bs_s1 <= 1'b0;
            bs_s2 <= 1'b0;
        end else begin
            bs_s1 <= boot_skip;
            bs_s2 <= bs_s1;
        end
    end

    wire              boot_active;      // 动画进行中（署名只在期间显示）
    wire signed [12:0] boot_blade;      // 光刃位置
    wire signed [12:0] boot_trail;      // 余晖拖尾边界（一阶 IIR）
    wire signed [12:0] boot_ebb;        // 退潮白幕边界
    wire [7:0]        boot_ebb_amt;     // 退潮白幕强度
    wire [1:0]        boot_warm;        // 黄光刃强度档

    boot_timebase u_boot_timebase (
        .clk         (clk),
        .rst         (rst),
        .vs          (vs),
        .skip        (bs_s2),
        .link_up     (link_up),
        .boot_active (boot_active),
        .blade       (boot_blade),
        .trail       (boot_trail),
        .ebb         (boot_ebb),
        .ebb_amt     (boot_ebb_amt),
        .warm_fade   (boot_warm)
    );

    // 右上角歌曲字幕：每帧左移 1px，完全离开窗口后从右侧重新进入。
    reg [8:0] ticker_phase;
    always @(posedge clk or posedge rst) begin
        if (rst || boot_active)
            ticker_phase <= 9'd0;
        else if (vs_last && !vs)
            ticker_phase <= (ticker_phase >= 9'd344) ? 9'd0
                                                     : ticker_phase + 9'd1;
    end

    // 三频带各打两拍跨到视频域（来自 audio_mclk 域，变化很慢，两级足够）
    reg [7:0] bl_s1, bl_s2, bm_s1, bm_s2, bh_s1, bh_s2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bl_s1 <= 8'd0; bl_s2 <= 8'd0;
            bm_s1 <= 8'd0; bm_s2 <= 8'd0;
            bh_s1 <= 8'd0; bh_s2 <= 8'd0;
        end else begin
            bl_s1 <= band_low;  bl_s2 <= bl_s1;
            bm_s1 <= band_mid;  bm_s2 <= bm_s1;
            bh_s1 <= band_high; bh_s2 <= bh_s1;
        end
    end

    // 转场亮度跨到视频域并打两拍；该值每 8ms 才变一次，同步风险极低
    reg [2:0] effect_sync1, effect_sync2;
    reg [7:0] alpha_gray_sync1, alpha_gray_sync2;
    reg [7:0] fade_frame;
    reg [2:0] effect_frame;
    wire [7:0] fade_decoded;
    assign fade_decoded[7] = alpha_gray_sync2[7];
    assign fade_decoded[6] = fade_decoded[7] ^ alpha_gray_sync2[6];
    assign fade_decoded[5] = fade_decoded[6] ^ alpha_gray_sync2[5];
    assign fade_decoded[4] = fade_decoded[5] ^ alpha_gray_sync2[4];
    assign fade_decoded[3] = fade_decoded[4] ^ alpha_gray_sync2[3];
    assign fade_decoded[2] = fade_decoded[3] ^ alpha_gray_sync2[2];
    assign fade_decoded[1] = fade_decoded[2] ^ alpha_gray_sync2[1];
    assign fade_decoded[0] = fade_decoded[1] ^ alpha_gray_sync2[0];
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            effect_sync1 <= 3'd0;
            effect_sync2 <= 3'd0;
            alpha_gray_sync1 <= 8'h80;
            alpha_gray_sync2 <= 8'h80;
            fade_frame <= 8'd255;
            effect_frame <= 3'd0;
        end else begin
            effect_sync1 <= transition_mode;
            effect_sync2 <= effect_sync1;
            alpha_gray_sync1 <= transition_alpha_gray;
            alpha_gray_sync2 <= alpha_gray_sync1;
            // The mask never changes halfway through an active video frame.
            if (vs_last && !vs) begin
                fade_frame <= fade_decoded;
                effect_frame <= effect_sync2;
            end
        end
    end

    // 慢速时基：25MHz 下 tbase[25] 约 1.34s，tbase[22] 约 0.17s
    reg [27:0] tbase;
    always @(posedge clk or posedge rst) begin
        if (rst) tbase <= 28'd0;
        else     tbase <= tbase + 28'd1;
    end

    //========================================================================
    // 底部渐变遮罩 —— 给文字铺底，让白字压得住亮背景
    //   遮罩强度随 y 线性增长，最高 140/255（约 55% 压暗）
    //   与转场亮度合并成一个增益，只做一次乘法（省 DSP）
    //========================================================================
    wire [9:0]  sc_raw   = {1'b0, y[8:0]} - 10'd320;
    wire [7:0]  bot_scrim = (y < 10'd320) ? 8'd0 :
                            (sc_raw > 10'd140) ? 8'd140 : sc_raw[7:0];
    // 顶部也给片名铺一层（天空通常是画面最亮处）
    wire [7:0]  top_raw  = (y < 10'd72) ? (8'd72 - y[7:0]) : 8'd0;
    wire [7:0]  top_scrim = (top_raw > 8'd72) ? 8'd72 : top_raw;
    wire [7:0]  scrim_a  = (y < 10'd200) ? top_scrim : bot_scrim;
    wire transition_visible, transition_edge;
    transition_mask u_transition_mask (
        .x(x), .y(y), .mode(effect_frame), .alpha(fade_frame),
        .visible(transition_visible), .edge_on(transition_edge)
    );
    wire [8:0]  fade_gain  = (effect_frame == 3'd0)
                             ? ({1'b0, fade_frame} + 9'd1) : 9'd256;
    wire [8:0]  scrim_gain = 9'd255 - {1'b0, scrim_a};               // 115..255
    wire [17:0] gain_prod  = fade_gain * scrim_gain;
    wire [8:0]  gain       = gain_prod[16:8];                        // 约 /256
    wire [16:0] fade_r = rgb_in[23:16] * gain;
    wire [16:0] fade_g = rgb_in[15:8]  * gain;
    wire [16:0] fade_b = rgb_in[7:0]   * gain;
    wire [23:0] rgb_faded = !transition_visible ? 24'd0 :
                            transition_edge ? ((effect_frame == 3'd3)
                                                 ? 24'hffe4a6 : 24'h75d7e5) :
                            {fade_r[15:8], fade_g[15:8], fade_b[15:8]};

    //========================================================================
    // 天体 —— 太阳 / 月亮，【随场景变化】
    //
    //   0 晨潮 MORNING TIDE  低垂的朝阳，暖橙，偏左下（日出位置）
    //   1 晴海 CLEAR SEA     高挂的烈日，亮白，更小更锐
    //   2 暮港 DUSK HARBOR   暖黄月亮，中低
    //   3 夜航 NIGHT VOYAGE  冷白月亮，更高
    //
    // 位置/半径/颜色都由 scene_sync2 选，几何使用平方距离生成真圆。
    //========================================================================
    // Scene palette: keep the softer per-scene tones, but restore the
    // competition baseline's golden sun for CLEAR SEA.
    wire        cel_is_sun = (scene_sync2 <= 2'd1);
    wire [10:0] cel_x   = cel_is_sun ? 11'd500 : 11'd520;
    wire [9:0]  cel_y   = cel_is_sun ? 10'd112 : 10'd90;
    wire [23:0] cel_col = (scene_sync2 == 2'd0) ? 24'hffcf85 :
                            (scene_sync2 == 2'd1) ? 24'hffd84d :
                            (scene_sync2 == 2'd2) ? 24'hffe6ac : 24'hdbe6ff;

    wire [10:0] mn_dx = (x >= cel_x) ? (x - cel_x) : (cel_x - x);
    wire [10:0] mn_dy = (y >= cel_y) ? ({1'b0,y} - {1'b0,cel_y}) : ({1'b0,cel_y} - {1'b0,y});
    wire        mn_disc;
    wire [7:0]  mn_glow;
    celestial_circle u_celestial_circle (
        .dx       (mn_dx),
        .dy       (mn_dy),
        .is_sun   (cel_is_sun),
        .disc     (mn_disc),
        .glow     (mn_glow)
    );

    // 天体水中倒影：正下方一条竖向柔光带，越往下越窄越暗，带缓慢波纹
    wire [9:0]  mr_dy  = (y > 10'd196) ? ({1'b0, y[8:0]} - 10'd196) : 10'd0;
    wire [10:0] mr_w   = (mr_dy > 10'd160) ? 11'd1 : (11'd10 - {6'd0, mr_dy[8:5]});
    wire        mn_refl = (y > 10'd196) && (x > 11'd360) && (x < 11'd640) &&
                          (mn_dx <= mr_w);
    wire [7:0]  mr_fade = (mr_dy[8:2] < 8'd40) ? (8'd40 - mr_dy[8:2]) : 8'd0;
    wire [7:0]  mn_refl_a = (mn_refl && ((y[3:2] ^ tbase[5:4]) == 2'd0))
                            ? (mr_fade + (mr_fade >> 1)) : mr_fade;

    //========================================================================
    // 星点 —— 天空区（地平线以上）
    //
    // 原来只有 4 颗固定的星，白天黑夜都一样，不合理。
    // 改法：保留 4 颗"主星"（位置固定、各自闪烁），再叠一层【星场】——
    //   用空间散列生成，密度随场景变：
    //     晨潮/晴海 = 0（大白天没有星）
    //     暮港     = 稀疏
    //     夜航     = 满天
    // 星场用散列而不是逐个列坐标，成本只有几个 LUT，却能做出"满天"的效果。
    //========================================================================
    function [7:0] star_a;
        input [10:0] px;
        input [9:0]  py;
        input [10:0] sx;
        input [9:0]  sy;
        input [2:0]  sr;          // 光晕半径
        input        tw;          // 闪烁位
        reg [11:0] d;
        reg [11:0] rr;
        begin
            d  = ((px > sx) ? (px - sx) : (sx - px)) +
                 ((py > sy) ? ({1'b0,py} - {1'b0,sy}) : ({1'b0,sy} - {1'b0,py}));
            rr = {9'd0, sr} + {8'd0, sr, 1'b0};           // sr*3（原 sr*12，画出来是天上的大方块）
            if (d >= rr) star_a = 8'd0;
            else         star_a = ({4'd0, (rr - d)} >> 1) + (tw ? 8'd46 : 8'd18);
        end
    endfunction

    // ---- 星星：8 颗固定位置，只在暮港/夜航（scene_sync2 >= 2）出现 ----
    //
    // 【绝对不要用空间散列做星星】试过一次想要"满天星"，上板出来是一片麻点 ——
    // 那看起来是【噪点】不是星星。散列分布的好坏看代码判断不出来，也没法离线验证。
    //
    // 所以：老老实实用【固定坐标表】。每颗星一个硬编码坐标 + 自己的一位 tbase
    // 做闪烁，这就是"按固定频率布灵布灵"。
    //
    // 【2026-10-05 退残留】这一块原来有两处硬伤，TD 只报 warning 不报 error：
    //   1) night_en 在下面 st1..st4 里【先用后声明】—— Verilog 会给它隐式生成
    //      一根 1 位线，等于 star_a(...) & 1'b1，只留最低位，星星会整片消失。
    //      这正是 KNOWN_ISSUES「时序类 / 先用后声明」那个坑。必须【先声明后使用】。
    //   2) star_sum 被【声明了两遍】—— 一版只加 st1..st4，一版加全 8 颗。
    //      TD 明确说 "second declaration of 'star_sum' is ignored"：
    //      第二版整个被丢掉，st5..st8 白算，屏幕上其实只有 4 颗星，
    //      而 STATE.md 记的是 8 颗。现在合并成一份，8 颗全部生效。
    wire [7:0] night_en = (scene_sync2 >= 2'd2) ? 8'hFF : 8'd0;

    wire [7:0] st1 = star_a(x, y, 11'd92,  10'd58,  3'd1, tbase[21]) & night_en;
    wire [7:0] st2 = star_a(x, y, 11'd196, 10'd122, 3'd2, tbase[22]) & night_en;
    wire [7:0] st3 = star_a(x, y, 11'd288, 10'd44,  3'd1, tbase[23]) & night_en;
    wire [7:0] st4 = star_a(x, y, 11'd430, 10'd150, 3'd2, tbase[24]) & night_en;
    wire [7:0] st5 = star_a(x, y, 11'd64,  10'd36,  3'd1, tbase[20]) & night_en;
    wire [7:0] st6 = star_a(x, y, 11'd146, 10'd82,  3'd2, tbase[26]) & night_en;
    wire [7:0] st7 = star_a(x, y, 11'd340, 10'd30,  3'd1, tbase[19]) & night_en;
    wire [7:0] st8 = star_a(x, y, 11'd392, 10'd96,  3'd1, tbase[27]) & night_en;

    // 位宽给 11 位：虽然 star_a 单颗最大只有 (rr>>1)+46 ≈ 49（8 颗共 392），
    // 但 KNOWN_ISSUES 记的规则是"按数值上界给位宽"，多给一位是免费的保险。
    wire [10:0] star_sum = {3'b0, st1} + {3'b0, st2} + {3'b0, st3} + {3'b0, st4} +
                           {3'b0, st5} + {3'b0, st6} + {3'b0, st7} + {3'b0, st8};
    wire [7:0] star_add = (star_sum > 11'd255) ? 8'hFF : star_sum[7:0];

    //========================================================================
    // 灯塔 —— 中心线 x = 572，整体比旧版加宽 50%
    //
    //   y 258..271  锥顶    半宽 3 -> 9   （随 y 渐宽）
    //   y 272..291  灯室    半宽 10
    //   y 292..299  观景台  半宽 15       （比塔身宽，形成挑檐）
    //   y 300..443  塔身    半宽 9 -> 17  （透视收分）
    //   y 444..479  塔基    半宽 17 -> 26 （外扩裙座）
    //========================================================================
    wire [10:0] lh_dx   = (x >= 11'd572) ? (x - 11'd572) : (11'd572 - x);
    wire        lh_left = (x < 11'd572);

    reg [5:0] lh_hw;
    reg [2:0] lh_kind;                      // 0 锥顶 1 灯室 2 观景台 3 塔身 4 塔基
    // 各段相对起点的偏移（显式相减，避免直接切 y 的位导致算术错误）
    wire [9:0] lh_yr = y - 10'd258;         // 锥顶段内偏移 0..13
    wire [9:0] lh_yb = y - 10'd300;         // 塔身段内偏移 0..143
    wire [9:0] lh_yc = y - 10'd444;         // 塔基段内偏移 0..35
    always @* begin
        if (y < 10'd258) begin
            lh_hw = 6'd0;  lh_kind = 3'd0;
        end else if (y < 10'd272) begin
            lh_hw = 6'd3 + {4'd0, lh_yr[4:1]};               // 3 + (y-258)/2  -> 3..9
            lh_kind = 3'd0;
        end else if (y < 10'd292) begin
            lh_hw = 6'd10; lh_kind = 3'd1;                   // 灯室
        end else if (y < 10'd300) begin
            lh_hw = 6'd15; lh_kind = 3'd2;                   // 观景台
        end else if (y < 10'd444) begin
            lh_hw = 6'd9 + {4'd0, lh_yb[7:4]};               // 9 + (y-300)/16 -> 9..17
            lh_kind = 3'd3;
        end else begin
            lh_hw = 6'd17 + {4'd0, lh_yc[7:2]};              // 17 + (y-444)/4 -> 17..25
            lh_kind = 3'd4;
        end
    end

    wire lh_on = (y >= 10'd258) && (lh_dx <= {5'b0, lh_hw});

    // ---- 圆柱明暗：按 |dx| 相对 hw 的位置分 8 档，查表得亮度 ----
    // 月光在左上 -> 左侧受光。左侧取 LUM[3..0]，右侧取 LUM[4..7]。
    wire [5:0] lh_q  = (lh_hw >> 2) + 6'd1;
    wire [2:0] lh_n  = (lh_dx < lh_q)               ? 3'd0 :
                       (lh_dx < {lh_q[4:0], 1'b0})  ? 3'd1 :
                       (lh_dx < (lh_q + {lh_q[4:0],1'b0})) ? 3'd2 : 3'd3;
    wire [2:0] lh_t  = lh_left ? (3'd3 - lh_n) : (3'd4 + lh_n);
    reg [7:0] lh_lum;
    always @* case (lh_t)
        3'd0: lh_lum = 8'd107;
        3'd1: lh_lum = 8'd219;
        3'd2: lh_lum = 8'd255;
        3'd3: lh_lum = 8'd240;
        3'd4: lh_lum = 8'd199;
        3'd5: lh_lum = 8'd153;
        3'd6: lh_lum = 8'd110;
        default: lh_lum = 8'd66;
    endcase

    // ---- 螺旋条纹：band = y + dx/2 + 旋转相位 ----
    // dx/2 用补码表示，加法回绕后取第 4 位得到 16px 周期。
    // 相位随时间缓慢累加 -> 圆柱看起来在缓缓转动（约 15 LUT）
    // 左侧用 dx/2 的补码（显式取反加一，不用 4096 常量避免位宽警告）
    wire [11:0] lh_dxr  = {5'd0, (11'd572 - x)};
    wire [11:0] lh_dxs2 = (x >= 11'd572) ? {5'd0, (x - 11'd572)}
                                         : (~lh_dxr + 12'd1);
    wire [11:0] lh_sum  = {2'd0, y} + {6'd0, lh_dxs2[11:1]} + {6'd0, tbase[25:20]};
    wire        lh_stripe = lh_sum[4];

    // ---- 分段底色 ----
    reg [23:0] lh_base;
    always @* case (lh_kind)
        3'd0:    lh_base = 24'h24203c;    // 锥顶
        3'd1:    lh_base = 24'hffe8aa;    // 灯室（玻璃，暖黄）
        3'd2:    lh_base = 24'h2a2644;    // 观景台
        3'd3:    lh_base = lh_stripe ? 24'h3a2a44 : 24'h1a182e;   // 塔身 + 螺旋
        default: lh_base = 24'h141324;    // 塔基
    endcase

    // 灯室不参与明暗（自发光），其余按 lh_lum 调亮度。
    // 注意：乘法必须先落到 16 位变量再取高位 —— 直接写在拼接里的话，
    // 拼接是"自决定宽度"上下文，8位×8位只会留 8 位，右移会被整个丢掉。
    wire [15:0] lh_lr = lh_base[23:16] * lh_lum;
    wire [15:0] lh_lg = lh_base[15:8]  * lh_lum;
    wire [15:0] lh_lb = lh_base[7:0]   * lh_lum;
    wire [23:0] lh_col = (lh_kind == 3'd1) ? lh_base :
                         {lh_lr[15:8], lh_lg[15:8], lh_lb[15:8]};

    // 左缘一条柔和高光，强化圆柱感
    wire lh_edge_hi = lh_on && lh_left && (lh_dx > (lh_hw - 6'd1)) && (lh_dx < (lh_hw + 6'd1));

    //========================================================================
    // 扫射光束 —— 角度用 8 位三角波【连续】推进
    //
    // 原来用 tbase[25:22] 只有 16 个角度，每 0.168s 跳一格，看上去就是一格一格
    // 地闪（用户反馈"频闪持续时间太长"就是这个）。现在每 2.6ms 走一格、
    // 256 格一个来回，全程约 0.67 秒，肉眼看是连续扫过去的。
    //========================================================================
    reg [7:0] swp;
    wire swp_tick = (tbase[16:0] == 17'd0);           // 131072 拍 ≈ 5.2ms（用户要求频率减半）
    always @(posedge clk or posedge rst) begin
        if (rst) swp <= 8'd0;
        else if (swp_tick) swp <= swp + 8'd1;
    end
    wire signed [7:0] swp_t  = swp[7] ? (8'sd127 - swp[6:0]) : {1'b0, swp[6:0]};  // 0..127..0
    wire signed [7:0] lh_ang = swp_t - 8'sd64;        // -64..+63

    wire [10:0] lh_dist  = (x < 11'd572) ? (11'd572 - x) : 11'd0;
    wire signed [10:0] lh_dist_s = {1'b0, lh_dist};
    wire signed [17:0] lh_prod = lh_dist_s * lh_ang;
    wire signed [17:0] lh_off  = lh_prod >>> 10;      // 约 ±36
    wire [10:0] lh_byc = 11'd282 + lh_off[10:0];

    wire [10:0] lh_dyb = (y > lh_byc[9:0]) ? ({1'b0,y} - lh_byc)
                                           : (lh_byc - {1'b0,y});
    // 【用户二次反馈：不要加宽、颜色不要太亮】
    //   宽度 5..76 = 原设计（"往左射的光不用加宽"）
    //   强度：回到 4.2 备份那一版的公式，只放大 1.25 倍
    //     原版 lh_shade>>1              -> 远端峰值 38
    //     现在 (>>1)+(>>3) = 0.625 倍   -> 远端峰值 47（"稍微亮一点"）
    //   ⚠️ 这个公式是【远端比近端亮】（bw 从 5 长到 76），是原设计如此，
    //      用户明确要求回到这一版的亮度，所以保留，没换成固定梯度。
    wire [9:0]  lh_bw  = 10'd5 + (lh_dist >> 3);                    // 5..76，越远越宽
    wire lh_in_beam = (x < 11'd572) && (lh_dyb[9:0] < lh_bw);
    wire [9:0]  lh_shade = lh_bw - lh_dyb[9:0];
    wire [7:0]  lh_beam_a = lh_in_beam ? ((lh_shade >> 1) + (lh_shade >> 3)) : 8'd0;

    //========================================================================
    // 塔顶灯 —— 径向光晕 + 缓慢脉冲呼吸
    //========================================================================
    wire [10:0] lp_dx = lh_dx;
    wire [10:0] lp_dy = (y >= 10'd282) ? ({1'b0,y} - 11'd282) : (11'd282 - {1'b0,y});
    wire [11:0] lp_m  = {1'b0, lp_dx} + {1'b0, lp_dy};
    wire [7:0]  lp_a  = (lp_m < 12'd70) ? ({4'd0, (12'd70 - lp_m)} >> 1) : 8'd0;
    // 呼吸脉冲也要做空间限制（见下），这里先算出脉冲量
    wire [3:0]  pu    = tbase[25:22];
    wire [3:0]  pl_t  = pu[3] ? (4'd15 - pu) : pu;            // 0..7..0
    wire [7:0]  lp_a2 = lp_a + ((lp_m < 12'd70) ? {4'd0, pl_t} : 8'd0);

    //========================================================================
    // 水面光柱 —— 灯光在海面的竖直反射带
    //========================================================================
    wire [9:0]  wc_dy = (y > 10'd292) ? ({1'b0, y[8:0]} - 10'd292) : 10'd0;
    wire [10:0] wc_w  = (wc_dy > 10'd160) ? 11'd1 : (11'd11 - {7'd0, wc_dy[7:4]});
    wire        wc_on = (y > 10'd292) && (lh_dx <= wc_w);
    wire [7:0]  wc_a  = wc_on ? ((8'd36 - wc_dy[8:3]) & 8'h3F) : 8'd0;

    //========================================================================
    // 三层视差波浪 —— 音频可视化的主体
    //
    // 为什么之前"看起来差"：只有一条 1px 细线，而且波形是固定的正弦，
    // 音乐只让它整体上下平移 —— "水在动"和"音乐在响"是两件不相干的事。
    //
    // 现在按策划案的映射表分三层，每层由不同频带驱动：
    //   远层（涌浪） <- 低频   波长大(256px)、幅度大、走得慢
    //   中层（纹理） <- 中频   波长中(128px)
    //   近层（细波） <- 高频   波长小(64px)、幅度小、走得快
    // 每层做半透明填充（用移位加法混合，不用乘法器），叠出纵深。
    //========================================================================
    function [3:0] wav16;                  // 0..15 的正弦近似，中心 8
        input [3:0] i;
        case (i)
            4'd0:  wav16 = 4'd8;   4'd1:  wav16 = 4'd11;  4'd2:  wav16 = 4'd13;
            4'd3:  wav16 = 4'd15;  4'd4:  wav16 = 4'd15;  4'd5:  wav16 = 4'd15;
            4'd6:  wav16 = 4'd13;  4'd7:  wav16 = 4'd11;  4'd8:  wav16 = 4'd8;
            4'd9:  wav16 = 4'd5;   4'd10: wav16 = 4'd3;   4'd11: wav16 = 4'd1;
            4'd12: wav16 = 4'd1;   4'd13: wav16 = 4'd1;   4'd14: wav16 = 4'd3;
            default: wav16 = 4'd5;
        endcase
    endfunction

    // 整体水位：平滑包络 -> 涨潮落潮（0..31 像素行程）
    // 基准上移到 362：波浪带收在 y 300..386，给下面的场景名（396..427）让出空间
    wire [9:0] lvl_off = {5'd0, level_sync2[7:3]};
    wire [9:0] base_y  = 10'd362 - lvl_off;

    // ---- 远层：低频 -> 深层涌浪 ----
    // 两路不同波长的正弦相加，避免看出单一周期
    wire [3:0] s1a = wav16(x[7:4] + tbase[24:21]);
    wire [3:0] s1b = wav16(x[6:3] + tbase[25:22]);
    wire [5:0] w1  = {2'b0, s1a} + {3'b0, s1b[3:1]};           // 0..22
    wire [5:0] amp1 = 6'd10 + {1'b0, bl_s2[7:3]};              // 10..41，低频越大浪越高
    wire [9:0] y1 = base_y - 10'd2 - (({4'd0, w1} * amp1) >> 5);

    // ---- 中层：中频 -> 水面纹理 ----
    wire [3:0] s2a = wav16(x[6:3] + tbase[23:20]);
    wire [3:0] s2b = wav16(x[5:2] + tbase[24:21]);
    wire [5:0] w2  = {2'b0, s2a} + {3'b0, s2b[3:1]};
    wire [5:0] amp2 = 6'd6 + {1'b0, bm_s2[7:4]};               // 6..21
    wire [9:0] y2 = base_y + 10'd7 - (({4'd0, w2} * amp2) >> 5);

    // ---- 近层：高频 -> 细波 ----
    wire [3:0] s3a = wav16(x[5:2] + tbase[22:19]);
    wire [3:0] s3b = wav16(x[4:1] + tbase[23:20]);
    wire [5:0] w3  = {2'b0, s3a} + {3'b0, s3b[3:1]};
    wire [5:0] amp3 = 6'd3 + {2'b0, bh_s2[7:5]};               // 3..10
    wire [9:0] y3 = base_y + 10'd15 - (({4'd0, w3} * amp3) >> 5);

    // 波浪带：收在 y 300..386，不侵占下面的场景名（396..427）与元信息（434..）
    wire band_ok = (y >= 10'd300) && (y <= 10'd386);
    wire fill1 = band_ok && (y >= y1);
    wire fill2 = band_ok && (y >= y2);
    wire fill3 = band_ok && (y >= y3);

    // 半透明填充：远层 25%、中层 50%、近层 75%，全部用移位加法
    //   out = (bg*(4-a) + col*a) >> 2   a=1/2/3
    // 注：中间变量用 wr/wg/wb 前缀，避免和 OSD 的 r0..r8 段落标志撞名
    wire [9:0] wr1 = {2'b0, rgb_faded[23:16]} + {1'b0, rgb_faded[23:16], 1'b0} + 10'd28;
    wire [9:0] wg1 = {2'b0, rgb_faded[15:8]}  + {1'b0, rgb_faded[15:8],  1'b0} + 10'd66;
    wire [9:0] wb1 = {2'b0, rgb_faded[7:0]}   + {1'b0, rgb_faded[7:0],   1'b0} + 10'd104;
    wire [23:0] wcol1 = {wr1[9:2], wg1[9:2], wb1[9:2]};

    wire [10:0] wr2 = {3'b0, rgb_faded[23:16]} + 11'd32;
    wire [10:0] wg2 = {3'b0, rgb_faded[15:8]}  + 11'd86;
    wire [10:0] wb2 = {3'b0, rgb_faded[7:0]}   + 11'd128;
    wire [23:0] wcol2 = {wr2[8:1], wg2[8:1], wb2[8:1]};   // 注意取 [8:1] 而不是 [9:1]：
                                                          // 9 位拼三个会成 27 位被截断，
                                                          // 颜色就会跑到别的通道去（实测发绿）

    wire [10:0] wr3 = {3'b0, rgb_faded[23:16]} + {1'b0, rgb_faded[23:16], 1'b0} + 11'd24;
    wire [10:0] wg3 = {3'b0, rgb_faded[15:8]}  + {1'b0, rgb_faded[15:8],  1'b0} + 11'd70;
    wire [10:0] wb3 = {3'b0, rgb_faded[7:0]}   + {1'b0, rgb_faded[7:0],   1'b0} + 11'd110;
    wire [23:0] wcol3 = {wr3[9:2], wg3[9:2], wb3[9:2]};

    // 浪尖高光：每层波峰处一条细亮线
    wire crest1 = band_ok && (y >= y1) && (y < y1 + 10'd2);
    wire crest2 = band_ok && (y >= y2) && (y < y2 + 10'd2);
    wire crest3 = band_ok && (y >= y3) && (y < y3 + 10'd2);

    //========================================================================
    // 泡沫与浪花 —— 高频能量控制白色颗粒密度
    //   空间散列决定"哪些位置可能有点"，时间散列让点缓慢闪烁，
    //   高频能量越高，通过阈值的点越多（镲片一响，泡沫冒出来）
    //========================================================================
    reg [15:0] lfsr;
    wire foam_tick = (tbase[18:0] == 19'd0);            // 约 48Hz 更新一次
    always @(posedge clk or posedge rst) begin
        if (rst) lfsr <= 16'hACE1;
        else if (foam_tick) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end
    wire [7:0] sp_hash = { x[3:0] ^ y[6:3], y[3:0] ^ x[6:3] };   // 静态空间散列
    wire [7:0] tm_hash = { lfsr[3:0], lfsr[7:4] };               // 缓慢时间调制
    wire [8:0] foam_v  = {1'b0, sp_hash} + {1'b0, tm_hash};
    // 两道门：粗门给密度（高频越强点越多），细门强制"每 8 行才可能有点"。
    // 只有粗门的话，同一个 x 上一整段 y 会连续通过，看上去就是一把竖梳子。
    wire foam_gate = (foam_v[7:3] < bh_s2[7:3]);
    wire foam_fine = ((sp_hash[2:0] ^ y[2:0]) == 3'd0);
    wire foam = band_ok && (y >= y3) && (y < (y3 + 10'd20)) && foam_gate && foam_fine;

    //========================================================================
    // 灯塔闪光 —— 能量突变（鼓点）触发，然后衰减
    //   策划案：「能量突变 -> 灯塔闪光 -> 明显鼓点到来时光闪一下并衰减」
    //========================================================================
    reg [7:0] env_prev;
    reg [3:0] flash;
    wire flash_trig = (level_sync2 > (env_prev + 8'd22)) && (level_sync2 > 8'd70);
    // 衰减要快 —— 用户反馈"频闪每次持续时间有点长"：
    // 原来 10.5ms 一档 × 15 档 = 157ms，拖尾太长。现在 5.2ms × 12 档 ≈ 62ms。
    wire flash_tick = (tbase[16:0] == 17'd0);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            env_prev <= 8'd0;
            flash    <= 4'd0;
        end else begin
            env_prev <= level_sync2;
            if (flash_trig)            flash <= 4'd12;
            else if (flash_tick && flash != 4'd0) flash <= flash - 4'd1;
        end
    end
    // 闪光：【扩散式光晕】，只作用在塔顶灯周围，不是整屏！
    //
    // 两个要点：
    //  1) 必须做空间限制 —— flash_add 会加进 glow_sum，而 glow 是逐像素加到
    //     全屏的，不做限制就是鼓点一来整个画面一起亮。
    //  2) 光晕要"开"出去 —— 半径随 flash 衰减从 16px 扩到 64px，同时整体变暗，
    //     像水波一样向外扩散；再由内到外分三级亮度，边缘才不生硬。
    wire [11:0] fl_dy = (y >= 10'd282) ? ({1'b0, y} - 12'd282) : (12'd282 - {1'b0, y});
    wire [11:0] fl_m  = {1'b0, lh_dx} + fl_dy;
    wire [7:0]  fl_rad  = 8'd64 - {2'd0, flash, 2'd0};        // flash=12 -> 16px, 归零 -> 64px
    wire [11:0] fl_lim  = {4'd0, fl_rad};
    wire        fl_on   = (fl_m < fl_lim);
    wire [11:0] fl_rem  = fl_lim - fl_m;                      // 距光晕边界还有多远
    wire [7:0]  flash_add = (~fl_on)          ? 8'd0 :
                            (fl_rem >= 12'd24) ? {flash, 4'd0} :      // 核心
                            (fl_rem >= 12'd10) ? {flash, 3'd0} :      // 内晕
                                                 {2'd0, flash, 2'd0}; // 外缘

    //========================================================================
    // 顶部渐变遮罩已在上面与底部遮罩合并（scrim_a 按 y 二选一）
    //========================================================================

    //========================================================================
    // 文字 OSD —— 点阵字库 + 字符段渲染
    //
    // 布局（三段字库，地址 = base + code*每字字节 + cy*每行字节 + cx/8）：
    //   段A 中文16x16 base=0     段B 中文32x32 base=1344  段C ASCII8x16 base=2368
    //
    // 每个文字段的字距都是 2 的幂，所以"第几个字 / 字内坐标"只要移位和掩码，
    // 不用除法器。字库 ROM 组合读（综合成 LUT ROM），完全不动视频流水线。
    //
    // 版面（640x480，符合策划案"控制信息集中在边缘"）：
    //   y  16   潮 汐 作 曲 家              片名（居中）
    //   y  38   T I D E  C O M P O S E R
    //   y 396   暮 港                        场景名（居中）
    //   y 434   D U S K  H A R B O R
    //   y 458   03 / 04   自动轮播   间隔 3 秒
    //========================================================================
    // run0/run1（主界面片名）已改 2x + 居中，坐标用 cda/cdb/cya/cyb，不再用 dx0/dx1
    wire [10:0] dx2 = x - 11'd272;      // run2 场景名 CJK  32x32 pitch32 3格
    wire [10:0] dx3 = x - 11'd268;      // run3 场景名 EN   8x16  pitch8  13格
    wire [10:0] dx4 = x - 11'd78;       // run4 03 / 04    8x16  pitch8  7格  【均分】
    wire [10:0] dx5 = x - 11'd398;      // run5 自动/手动  16x16 pitch16 2格  【均分】
    wire [10:0] dx6 = x - 11'd506;      // run6 间隔        16x16 pitch16 2格  【均分】
    wire [10:0] dx7 = x - 11'd538;      // run7 周期数字    8x16  pitch8  1格  【均分】
    wire [10:0] dx8 = x - 11'd546;      // run8 秒          16x16 pitch16 1格  【均分】

    // ---- 常驻片名：只在【非开场动画】时画在顶部（动画期间让位给片头卡）----
    // ---- 常驻片名（主界面，2 倍放大，居中于 x=320）----------------------
    // 2x 的做法与片头卡一致：取字模时 ocx/ocy 取 dx/dy 的 [4:1]，字格步长翻倍。
    //   潮汐作曲家   5 字 x32 = 160px  x 240..400   y 16..48
    //   TIDE COMPOSER 13 x16  = 208px  x 216..424   y 52..84
    // 【顺带修掉一个既有小瑕疵】原来 cxA = dx0[4:0]，dx0 在 16..31 时
    //   ocx[4:3] = 2/3，faddr 会读到字模的【下一行】——
    //   第 2、4 个字（汐、曲）其实整体上移了 1 像素。取 [4:1] 之后自然消失。
    wire [10:0] cda = x - 11'd240;    // 潮汐作曲家
    wire [10:0] cdb = x - 11'd216;    // TIDE COMPOSER
    wire [9:0]  cya = y - 10'd16;     // 行内 y（0..31，再 [4:1] 取字模行）
    wire [9:0]  cyb = y - 10'd52;
    wire r0 = (!boot_active) && (y >= 10'd16) && (y < 10'd48) && (x >= 11'd240) && (x < 11'd400);
    wire r1 = (!boot_active) && (y >= 10'd52) && (y < 10'd84) && (x >= 11'd216) && (x < 11'd424);

    // "正在播放歌曲 1/5"：中文 96px + 间隔 8px + ASCII 24px。
    // 使用 x+phase 计算滚动坐标，避免有符号负坐标和减法下溢。
    wire [11:0] ticker_sum = {1'b0, x} + {3'b000, ticker_phase};
    wire [11:0] ticker_dx  = ticker_sum - 12'd640;
    wire ticker_line = active && !boot_active && !mn_s2 &&
                       (y >= 10'd16) && (y < 10'd32) &&
                       (x >= 11'd424) && (x < 11'd632) &&
                       (ticker_sum >= 12'd640) && (ticker_sum < 12'd768);
    wire r20 = ticker_line && (ticker_dx < 12'd96);
    wire r21 = ticker_line && (ticker_dx >= 12'd104) && (ticker_dx < 12'd128);
    reg [6:0] ticker_cjk_code;
    reg [6:0] ticker_num_code;
    always @* begin
        case (ticker_dx[6:4])
            3'd0: ticker_cjk_code = 7'd23;  // 正
            3'd1: ticker_cjk_code = 7'd24;  // 在
            3'd2: ticker_cjk_code = 7'd2;   // 播
            3'd3: ticker_cjk_code = 7'd3;   // 放
            3'd4: ticker_cjk_code = 7'd0;   // 歌
            default: ticker_cjk_code = 7'd1;// 曲
        endcase
        case ((ticker_dx - 12'd104) >> 3)
            12'd0: ticker_num_code = 7'd2 + {4'd0, os_s2};
            12'd1: ticker_num_code = 7'd37;
            default: ticker_num_code = 7'd1 + {4'd0, ost_s2};
        endcase
    end

    // ---- 开场片头卡（只在动画期间）--------------------------------------
    // 白幕正中三行，全部居中于 x=320：
    //   y150  潮汐作曲家        5 个 16x16  =  80px   x 280..360
    //   y178  TIDE COMPOSER    13 个  8x16  = 104px   x 268..372
    //   y206  基于 FPGA 的海洋音画实时生成装置
    //         ├ 基于          2 个 16x16 =  32px  x 200..232  (段D)
    //         ├ FPGA          4 个  8x16 =  32px  x 240..272  (段C)
    //         └ 的海洋音画实时生成装置  10 个 16x16 = 160px  x 280..440 (段D)
    //      合计 240px，x 200..440，居中 ✓
    //
    // 【为什么要拆成 3 个 run】字号是每个 run 一个（ofont），
    // 一行里中文 16x16 和 ASCII 8x16 混排必须拆开 —— 现有代码从来没混排过。
    // 片头卡的"存活判断"：光刃化开到这一行之前，卡片还在白幕上；
    // 化开之后卡片【直接消失】，而不是换成浅色 ——
    //   卡片在 y150..222，那一带既没有顶部遮罩也没有底部遮罩，
    //   背景是【浅色天空】。切成浅色的话字就糊在天空上了（预览里一眼可见）。
    //   消失点选在 blade = ys+64（正好是主刃口余晖的末端 = 这一行刚化开完），
    //   所以消失发生在光刃的过渡带里，看不出来。
    wire [10:0] ys_d = {1'b0, y} + {7'd0, x[10:4]};
    wire card_on = boot_active && (boot_blade < ($signed({2'b0, ys_d}) + 13'sd64));

    // ---- 片头卡版面（只在动画期间，2 倍放大）----------------------------
    // 【2x 放大怎么做的】取字模时把坐标【右移 1 位】：
    //   ocx = dx[4:1]   ocy = dy[4:1]   字格 = dx[8:5]（32px 一格）
    // 等于把每个字模像素铺成 2x2。不新增任何字模字节，也不加 LUT。
    //
    // 全部居中于 x=320：
    //   行1 y130..162  潮汐作曲家        5 字 x32 = 160px  x 240..400
    //   行2 y178..210  TIDE COMPOSER    13 x16    = 208px  x 216..424
    //   行3 y226..258  基于 FPGA 的海洋音画实时生成装置
    //        基于   2 字 x32 =  64px  x  64..128
    //        FPGA   4 x16    =  64px  x 144..208
    //        的海洋音画实时生成装置 11 字 x32 = 352px  x 224..576
    //        合计 64+16+64+16+352 = 512px，x 64..576，居中 ✓
    //
    // 【数错字数的教训】"的海洋音画实时生成装置"是【11】个字不是 10 个。
    // 少算 16px 就会把最后一个「置」挤出 run 范围 —— 照片上就是"有些字没有了"。
    wire [10:0] cd1 = x - 11'd240;   // 行1
    wire [10:0] cd2 = x - 11'd216;   // 行2
    wire [10:0] cd3 = x - 11'd64;    // 行3 基于
    wire [10:0] cd4 = x - 11'd144;   // 行3 FPGA
    wire [10:0] cd5 = x - 11'd224;   // 行3 的海洋音画实时生成装置
    wire [9:0]  cy1 = y - 10'd130;   // 行1 行内 y（0..31，再 [4:1] 取字模行）
    wire [9:0]  cy2 = y - 10'd178;   // 行2
    wire [9:0]  cy3 = y - 10'd226;   // 行3

    wire r14 = card_on && (y >= 10'd130) && (y < 10'd162) && (x >= 11'd240) && (x < 11'd400);
    wire r15 = card_on && (y >= 10'd178) && (y < 10'd210) && (x >= 11'd216) && (x < 11'd424);
    wire r16 = card_on && (y >= 10'd226) && (y < 10'd258) && (x >= 11'd64)  && (x < 11'd128);
    wire r17 = card_on && (y >= 10'd226) && (y < 10'd258) && (x >= 11'd144) && (x < 11'd208);
    wire r18 = card_on && (y >= 10'd226) && (y < 10'd258) && (x >= 11'd224) && (x < 11'd576);
    wire r2 = (y >= 10'd396) && (y < 10'd428) && (x >= 11'd272) && (x < 11'd368);
    wire r3 = (y >= 10'd434) && (y < 10'd450) && (x >= 11'd268) && (x < 11'd372);
    // 【底栏四项必须和署名无缝交棒】光刃扫到 y458 之前，底栏【根本不生成】，
    // 而不是靠白幕盖住 —— 因为 osd_on 的优先级里 r4 排在署名 r12/r13 前面，
    // 只要它参与竞争，重叠区(78..112)的字形位就会被它抢走，
    // 上板表现就是署名只剩「FROM 奶蛙」，「大队」被 03/04 顶掉。
    wire bar_ok = (~boot_active) || (boot_blade >= 13'sd530);
    // 【2026-10-06 改】「信息显示」开关控制【整条底栏】，不是只控分辨率。
    //   一次要控的是：03/04（图号）、分辨率/缩放比、手动/自动、间隔 N 秒。
    //   所以这里把 in_s2 并进 bar_ok —— 底栏四项一起隐现。
    wire bar_vis = bar_ok && in_s2;
    wire r4 = bar_vis && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd78)  && (x < 11'd134);   // 图号 n/n
    wire r5 = bar_vis && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd398) && (x < 11'd430);   // 手动/自动
    wire r6 = bar_vis && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd506) && (x < 11'd538);   // 间隔
    wire r7 = bar_vis && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd538) && (x < 11'd546);   // 周期数字
    wire r8 = bar_vis && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd546) && (x < 11'd562);   // 秒

    // 周期值 1/3/5 -> ASCII 码（'0'=1，所以 '1'=2 '3'=4 '5'=6）
    // 【必须声明在菜单代码之前】—— Verilog 里"先用后声明"会隐式生成一根 1 位线，
    // 综合出来是错的（之前 gray_to_bin 也是栽在这个规则上）。
    wire [6:0] period_code = (op_s2 == 2'd0) ? 7'd2 :
                             (op_s2 == 2'd1) ? 7'd4 : 7'd6;

    //========================================================================
    // 菜单浮层（模态）
    //
    // 版面（640x480）—— 4 项菜单，与 menu4 版完全一致
    //   （坐标经「菜单_实际坐标预览.png」逐像素核对过，见 STATE.md 第七节第 4 条）：
    //   面板   x 148..492  y 114..322
    //   标题   设 置        x0=176 y0=128  16x16 两格
    //   菜单项 x0=200       y0=172+行*32   16x16 四格/行，共 4 行（y 172..300）
    //   数值   x0=392       y0=172+行*32   8x16  八格/行
    //   高亮条 x 164..478   跟在【选中行】上（不是跟着光标 y 走）
    //
    // 【2026-10-05 退残留】上一轮为了塞下 7 项菜单，把面板撑到 y 100..380、
    //   行基准从 172 挪到 144。菜单回到 4 项后这里【整套退回 menu4 的数值】，
    //   而不是在 7 项版的基础上削一刀 —— 少一版布局就少一处没核过的坐标。
    //   m_yoff 基准、面板上下沿、标题 y0、高亮条基准四处必须一起改，缺一处就错位。
    //
    // 菜单打开时，常驻字幕（片名/场景名/底部信息）整段隐藏，把画面让给菜单。
    // 署名（r12/r13）是常驻的，不参与这个让位。
    //========================================================================
    //========================================================================
    // 4 项菜单（本备份点：7 项菜单的改造【尚未】开始）
    //   0 歌曲 / 1 播放模式 / 2 轮播周期 / 3 系统信息
    //========================================================================
    wire m_panel  = mn_s2 && (x >= 11'd148) && (x <= 11'd492) &&
                             (y >= 10'd114) && (y <= 10'd356);
    wire m_border = m_panel && ((x <= 11'd150) || (x >= 11'd490) ||
                                (y <= 10'd116) || (y >= 10'd354));

    // ---- 行号与字内坐标（行距 24px）----
    // 【踩过的坑】行距 32px 而字模只有 16px 高。原来直接用 (y-172) mod 16 当行内
    // 坐标，等于每个 32px 的行里把同一个字画了两遍，屏幕上就是"歌曲/歌曲"成对。
    // 必须再用 m_yoff[4] 把每行的【后半段】关掉。
    // 9 行使用 20px 行距；(m_yoff*205)>>12 在本区域内等价于 floor(m_yoff/20)。
    wire [9:0]  m_yoff = y - 10'd160;
    wire [17:0] m_rowm = m_yoff * 10'd205;
    wire [3:0]  m_row  = m_rowm[15:12];
    wire [9:0]  m_rowtop = {m_row, 4'b0} + {m_row, 2'b0};   // 行距 20px
    wire [9:0]  m_cy10 = (m_yoff >= m_rowtop) ? (m_yoff - m_rowtop) : 10'd31;
    wire        m_vis  = (m_cy10 < 10'd16);            // 每行只画前 16px
    wire [4:0]  m_cy   = m_cy10[4:0];                  // 行内 y（字高 16）

    wire [10:0] m_dx0 = x - 11'd176;                   // 标题
    wire [10:0] m_dx1 = x - 11'd200;                   // 菜单项文字
    // 数值列：8px 一格。
    // 【踩过的坑】"第几格"和"格内第几个像素"必须拆成两个信号！
    // 图省事写成 m_vi = (x-392)[2:0] 时，m_vi 其实是格内坐标，
    // 再拿它当格号去查字符表，就会每 8 个像素换一个字 —— 屏幕上一堆碎片。
    wire [10:0] m_dx2   = x - 11'd392;
    wire [2:0]  m_vcell = m_dx2[5:3];                  // 第几格（0..7）
    wire [2:0]  m_vi    = m_dx2[2:0];                  // 格内 x（0..7）

    wire r9  = mn_s2 && (y >= 10'd128) && (y < 10'd144) &&
               (x >= 11'd176) && (x < 11'd208);
    wire r10 = mn_s2 && m_vis && (y >= 10'd160) && (y < 10'd336) &&
               (x >= 11'd200) && (x < 11'd264);
    wire r11 = mn_s2 && m_vis && (y >= 10'd160) && (y < 10'd336) &&
               (x >= 11'd392) && (x < 11'd456);
    // ---- 制作方署名（左下角，比片名小一档）----
    // "FROM" 用 8x16 ASCII，"奶蛙大队" 用 16x16 中文，两段各自一个 run。
    // 【2026-10-05 退残留】这里原来把 m_dx12 / m_dx13 【声明了两遍】——
    //   一次在"常驻署名"那一版里，一次是改成"仅开场动画"时又补上的。
    //   同名 wire 重复声明在 Verilog 里是隐患（TD 只是容忍），已合并成一份。
    // 署名是【常驻】的：STATE.md 明确写着「左下角 from 奶蛙大队（已做好，常驻）」。
    //   所以 r12/r13 必须进 osd_on，否则下面 ocode 里那两条分支永远轮不到，
    //   上板表现就是"署名整个不见了"。
    //
    // 位置：原记录是 x 16..120，但那会【压到图片序号】——
    //   r4「03/03」起点是 x=116，而 r4 在优先级 mux 里排在 r12/r13 前面，
    //   所以 x 116..119 这 4 列会把「队」的右边缘切掉，上板看是两个字糊在一起。
    //   署名以前没被画出来，这个重叠一直没人看见。整体左移 8px 后：
    //   FROM x 8..40 / 奶蛙大队 x 48..112，与 x=116 的序号留出 4px（字模自带边距）。
    // 拓展④：底部信息栏的「分辨率 + 缩放比」，x210..322（14 格 ASCII）
    //   左边 03/04 到 x172、右边 手动 从 x300 起 —— 178 起留 6px 间隙，不会再黏在一起
    wire [10:0] rs_dx = x - 11'd210;
    wire        r19   = (y >= 10'd458) && (y < 10'd474) &&
                        (x >= 11'd210) && (x < 11'd322) && in_s2;
    wire [10:0] m_dx12 = x - 11'd8;
    wire [10:0] m_dx13 = x - 11'd48;
    // 【署名只在"开幕"显示，而且要"交棒"】署名是 boot_active 全程有效的，
    //   但底部信息栏是光刃扫到 y458 才露出来的 —— 中间约 2 秒两者同时在屏上，
    //   而署名(x8..112) 和 03/04(x78..134) 会重叠 78..112。
    //   所以光刃一到底部（blade>=530，即 y458 那一行化开完）署名就退场。
    //   boot_active 之外本来就不显示（见 osd_on 的 (r12|r13) & boot_active）。
    wire cred_on = boot_active && (boot_blade < 13'sd530);
    wire r12 = cred_on && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd8)  && (x < 11'd40);
    wire r13 = cred_on && (y >= 10'd458) && (y < 10'd474) && (x >= 11'd48) && (x < 11'd112);
    reg [6:0] m_code12;
    always @* begin
        case (m_dx12[4:3])
            2'd0: m_code12 = 7'd16;
            2'd1: m_code12 = 7'd28;
            2'd2: m_code12 = 7'd25;
            default: m_code12 = 7'd23;
        endcase
    end

    // "奶蛙大队" = 38 39 40 41
    reg [6:0] m_code13;
    always @* begin
        case (m_dx13[5:4])
            2'd0: m_code13 = 7'd38;
            2'd1: m_code13 = 7'd39;
            2'd2: m_code13 = 7'd40;
            default: m_code13 = 7'd41;
        endcase
    end

    //========================================================================
    // 拓展④：底部信息栏的「分辨率 + 缩放比」
    //   版面 x210..322 = 112px = 14 个 ASCII 格（8px/格）
    //   【必须预存成寄存器】串跟着换图才变（极慢），但每像素现算会挂到
    //   y -> repl 这条长链上。这里一次算好，每像素只做一次数组索引。
    //   段C 的 ASCII 码：空格0 '0'=1..'9'=10 'A'=11..'Z'=36 '/'=37 '.'=38
    //   缩放比按【适应】模式算 = min(640/w, 480/h)
    //========================================================================
    reg [6:0] rsw0, rsw1, rsw2, rsw3, rsw4, rsw5, rsw6;
    reg [6:0] rsw7, rsw8, rsw9, rsw10, rsw11, rsw12, rsw13;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rsw0<=7'd7; rsw1<=7'd5; rsw2<=7'd1; rsw3<=7'd34; rsw4<=7'd5; rsw5<=7'd9; rsw6<=7'd1;
            rsw7<=7'd0; rsw8<=7'd0; rsw9<=7'd2; rsw10<=7'd38; rsw11<=7'd1; rsw12<=7'd1; rsw13<=7'd34;
        end else begin
            case (bw_s2)
                // "1024X600 0.63X"
                16'd1024: begin
                    rsw0<=7'd2; rsw1<=7'd1;  rsw2<=7'd3;  rsw3<=7'd5;  rsw4<=7'd34; rsw5<=7'd7; rsw6<=7'd1;
                    rsw7<=7'd1; rsw8<=7'd0;  rsw9<=7'd1;  rsw10<=7'd38; rsw11<=7'd7; rsw12<=7'd4; rsw13<=7'd34; end
                // "1280X720 0.50X"
                16'd1280: begin
                    rsw0<=7'd2; rsw1<=7'd3;  rsw2<=7'd9;  rsw3<=7'd1;  rsw4<=7'd34; rsw5<=7'd8; rsw6<=7'd3;
                    rsw7<=7'd1; rsw8<=7'd0;  rsw9<=7'd1;  rsw10<=7'd38; rsw11<=7'd6; rsw12<=7'd1; rsw13<=7'd34; end
                // "1536X1024 .42X"
                16'd1536: begin
                    rsw0<=7'd2; rsw1<=7'd6;  rsw2<=7'd4;  rsw3<=7'd7;  rsw4<=7'd34; rsw5<=7'd2; rsw6<=7'd1;
                    rsw7<=7'd3; rsw8<=7'd5;  rsw9<=7'd0;  rsw10<=7'd38; rsw11<=7'd5; rsw12<=7'd3; rsw13<=7'd34; end
                // "640X480  1.00X"（默认档）
                default: begin
                    rsw0<=7'd7; rsw1<=7'd5;  rsw2<=7'd1;  rsw3<=7'd34; rsw4<=7'd5; rsw5<=7'd9; rsw6<=7'd1;
                    rsw7<=7'd0; rsw8<=7'd0;  rsw9<=7'd2;  rsw10<=7'd38; rsw11<=7'd1; rsw12<=7'd1; rsw13<=7'd34; end
            endcase
        end
    end
    // 串的取字：16 格，索引 = (x-174)>>3
    reg [6:0] m_code19;
    always @* begin
        case (rs_dx[6:3])
            4'd0:  m_code19 = rsw0;   4'd1:  m_code19 = rsw1;   4'd2:  m_code19 = rsw2;
            4'd3:  m_code19 = rsw3;   4'd4:  m_code19 = rsw4;   4'd5:  m_code19 = rsw5;
            4'd6:  m_code19 = rsw6;   4'd7:  m_code19 = rsw7;   4'd8:  m_code19 = rsw8;
            4'd9:  m_code19 = rsw9;   4'd10: m_code19 = rsw10;  4'd11: m_code19 = rsw11;
            4'd12: m_code19 = rsw12;  default: m_code19 = rsw13;
        endcase
    end
    // ---- 菜单项文字：9 行 × 4 格（索引 = 行*4 + 格）----
    // 【段G 的码】歌0 曲1 播2 放3 模4 式5 轮6 周7 期8 转9 场10 方11
    // 缩12 信13 息14 显15 示16 系17 统18 音19 量20 亮21 度22
    // 七个字全部来自段G（一个 run 只能用一段字库）。
    reg [6:0] m_code10;
    always @* begin
        case ({m_row, m_dx1[5:4]})
            6'd0:  m_code10 = 7'd0;    // 歌
            6'd1:  m_code10 = 7'd1;    // 曲
            6'd4:  m_code10 = 7'd2;    // 播
            6'd5:  m_code10 = 7'd3;    // 放
            6'd6:  m_code10 = 7'd127;
            6'd7:  m_code10 = 7'd127;
            6'd8:  m_code10 = 7'd19;   // 音
            6'd9:  m_code10 = 7'd20;   // 量
            6'd10: m_code10 = 7'd127;
            6'd11: m_code10 = 7'd127;
            // 行3 亮度
            6'd12: m_code10 = 7'd21;   // 亮
            6'd13: m_code10 = 7'd22;   // 度
            6'd14: m_code10 = 7'd127;
            6'd15: m_code10 = 7'd127;
            // 行4 对比度：本行切到段A，码 22/23/21 = 对/比/度。
            6'd16: m_code10 = 7'd22;
            6'd17: m_code10 = 7'd23;
            6'd18: m_code10 = 7'd21;
            6'd19: m_code10 = 7'd127;
            // 行5 转场方式（拓展②）
            6'd20: m_code10 = 7'd9;
            6'd21: m_code10 = 7'd10;
            6'd22: m_code10 = 7'd11;
            6'd23: m_code10 = 7'd5;
            // 行6 缩放（拓展③）
            6'd24: m_code10 = 7'd12;
            6'd25: m_code10 = 7'd3;
            6'd26: m_code10 = 7'd127;
            6'd27: m_code10 = 7'd127;
            // 行7 信息显示（拓展④）
            6'd28: m_code10 = 7'd13;
            6'd29: m_code10 = 7'd14;
            6'd30: m_code10 = 7'd15;
            6'd31: m_code10 = 7'd16;
            // 行8 轮播周期
            6'd32: m_code10 = 7'd6;
            6'd33: m_code10 = 7'd2;
            6'd34: m_code10 = 7'd7;
            6'd35: m_code10 = 7'd8;
            default: m_code10 = 7'd127;
        endcase
    end

    // ---- 菜单项数值（ASCII）：4 行 × 8 格（索引 = 行*8 + 格）----
    // ASCII 码约定：'0'=1 ... '9'=10，'A'=11 ... 'Z'=36，'/'=37，空格=0
    // 【2026-10-05 退残留】亮度/对比度/音量三行的数值（含下面四个档位拆位 wire）
    //   已删除；系统信息从行6 上移到行3 —— 键值 6'd53..55 变成 6'd29..31。
    reg [6:0] m_code11;
    function [6:0] transition_name;
        input [2:0] mode;
        input [2:0] cell_idx;
        reg [55:0] name_codes;
        begin
            // Eight 7-bit glyph codes, indexed left to right; A=11 .. Z=36.
            case (mode)
                3'd1: name_codes = {7'd0,7'd0,7'd0,7'd29,7'd22,7'd19,7'd14,7'd15}; // SLIDE
                3'd2: name_codes = {7'd0,7'd0,7'd0,7'd0,7'd33,7'd11,7'd32,7'd15}; // WAVE
                3'd3: name_codes = {7'd0,7'd0,7'd0,7'd12,7'd22,7'd11,7'd14,7'd15}; // BLADE
                3'd4: name_codes = {7'd0,7'd0,7'd28,7'd19,7'd26,7'd26,7'd22,7'd15}; // RIPPLE
                3'd5: name_codes = {7'd0,7'd0,7'd14,7'd19,7'd30,7'd18,7'd15,7'd28}; // DITHER
                default: name_codes = {7'd0,7'd14,7'd15,7'd16,7'd11,7'd31,7'd22,7'd30}; // DEFAULT
            endcase
            transition_name = name_codes[(7-cell_idx)*7 +: 7];
        end
    endfunction
    always @* begin
        case ({m_row, m_vcell})
            // 行0 歌曲 -> "  1/5"（右对齐到第 5..7 格）
            6'd5:  m_code11 = 7'd1 + {4'd0, os_s2} + 7'd1;             // 歌号
            6'd6:  m_code11 = 7'd37;                                   // '/'
            6'd7:  m_code11 = 7'd1 + {4'd0, ost_s2};                   // 总数
            // 行1 【2026-10-06】第2项 = 播放（音乐开/关）-> "ON" / "OFF"（4 格）
            //   原来这里是播放模式的 AUTO/MANU，和第 8 项对调了。
            6'd12: m_code11 = mu_s2 ? 7'd0  : 7'd25;                   // 空 / O
            6'd13: m_code11 = mu_s2 ? 7'd25 : 7'd16;                   // O  / F
            6'd14: m_code11 = mu_s2 ? 7'd24 : 7'd16;                   // N  / F
            6'd15: m_code11 = 7'd127;                                  // 空
            // 行2 轮播周期 -> "3S"（第 6..7 格）
            6'd22: m_code11 = 7'd127;                                  // 空
            6'd23: m_code11 = 7'd2 + {4'd0, vol_s2};                   // 音量档位 1..7（段C 的 '0' 是码1）
            // 行3 亮度：25 / 50 / 75 / 100
            6'd27: m_code11 = 7'd127;
            6'd28: m_code11 = (br_s2 == 2'd3) ? 7'd2 : 7'd127;
            6'd29: m_code11 = (br_s2 == 2'd0) ? 7'd3 :
                              (br_s2 == 2'd1) ? 7'd6 :
                              (br_s2 == 2'd2) ? 7'd8 : 7'd1;
            6'd30: m_code11 = (br_s2 == 2'd0) ? 7'd6 : 7'd1;
            6'd31: m_code11 = 7'd127;
            // 行4 对比度：50 / 75 / 90 / 100 / 110 / 125 / 150。
            7'd36: m_code11 = 7'd127;
            7'd37: m_code11 = (ct_s2 <= 3'd2) ? 7'd127 : 7'd2;
            7'd38: m_code11 = (ct_s2 == 3'd0) ? 7'd6  :
                                  (ct_s2 == 3'd1) ? 7'd8  :
                                  (ct_s2 == 3'd2) ? 7'd10 :
                                  (ct_s2 == 3'd3) ? 7'd1  :
                                  (ct_s2 == 3'd4) ? 7'd2  :
                                  (ct_s2 == 3'd5) ? 7'd3  : 7'd6;
            7'd39: m_code11 = (ct_s2 == 3'd1 || ct_s2 == 3'd5) ? 7'd6 : 7'd1;
            // 行5 转场方式。Seven cells fit DEFAULT.
            7'd41, 7'd42, 7'd43, 7'd44, 7'd45, 7'd46, 7'd47:
                m_code11 = transition_name(tr_s2, m_vcell);
            // 行6 缩放（拓展③）-> "ON"/"OFF"（第 5..7 格）
            //   【2026-10-06 改】原来这里是 FIT/FILL/FULL/1TO1 四档，
            //   现在简化成开/关：开 = 显示图1的推近版，关 = 显示原图。
            //   sc_s2 仍保持 [1:0] 位宽（没动端口），只用 bit0 当开关。
            7'd52: m_code11 = 7'd0;
            7'd53: m_code11 = 7'd25;
            7'd54: m_code11 = sc_s2[0] ? 7'd24 : 7'd16;
            7'd55: m_code11 = sc_s2[0] ? 7'd127: 7'd16;
            // 行7 信息显示（拓展④）-> "ON" / "OFF"
            7'd60: m_code11 = in_s2 ? 7'd0  : 7'd25;
            7'd61: m_code11 = in_s2 ? 7'd25 : 7'd16;
            7'd62: m_code11 = in_s2 ? 7'd24 : 7'd16;
            // 行8 轮播周期
            7'd69: m_code11 = 7'd127;
            7'd70: m_code11 = period_code;
            7'd71: m_code11 = 7'd29;
            default: m_code11 = 7'd127;
        endcase
    end

    // ---- 面板底色 / 高亮条 ----
    wire [7:0] mb_r = (rgb_faded[23:16] >> 2) + (rgb_faded[23:16] >> 3) + 8'd8;
    wire [7:0] mb_g = (rgb_faded[15:8]  >> 2) + (rgb_faded[15:8]  >> 3) + 8'd14;
    wire [7:0] mb_b = (rgb_faded[7:0]   >> 2) + (rgb_faded[7:0]   >> 3) + 8'd22;
    wire [7:0] hl_r = (rgb_faded[23:16] >> 1) + 8'd24;
    wire [7:0] hl_g = (rgb_faded[15:8]  >> 1) + 8'd62;
    wire [7:0] hl_b = (rgb_faded[7:0]   >> 1) + 8'd72;

    // 高亮条跟在【选中行】上，不是跟着光标 y —— 这是"选中"和"鼠标"的区别
    wire [9:0] m_hl_y0 = 10'd160 + {mi_s2, 4'b0} + {mi_s2, 2'b0};   // 行距 20px
    wire m_hl = m_panel && (y >= (m_hl_y0 - 10'd3)) && (y < (m_hl_y0 + 10'd19)) &&
                (x >= 11'd164) && (x <= 11'd478);


    // 直接拿 y 的低位当行号会让字模从中间开始读、末尾串到下一个字，
    // 整段变成乱码（实测只有 y0=16 的片名那一段是对的）。
    // run0/run1（主界面片名）已改 2x，行内坐标用 cya/cyb，不再用这两个。
    wire [4:0] cyB  = (y - 10'd396) & 10'h1F;        // run2  y0=396 (32 行)
    wire [4:0] cyC3 = (y - 10'd434) & 10'h0F;        // run3  y0=434
    wire [4:0] cyC4 = (y - 10'd458) & 10'h0F;        // run4..8 y0=458

    // 字内 x —— 每段 x0 不同，必须各用各的 dx
    // run0/run1 改 2x 后不再用这两个（见上面 cda/cdb）
    wire [4:0] cxB  = dx2[4:0];                      // run2  32x32（5 位够，0..31）
    wire [4:0] cxC3 = dx3[2:0];                      // run3  8x16
    wire [4:0] cxC4 = dx4[2:0];                      // run4  8x16
    wire [4:0] cxA5 = dx5[4:0];                      // run5  16x16
    wire [4:0] cxA6 = dx6[4:0];                      // run6  16x16
    wire [4:0] cxC7 = dx7[2:0];                      // run7  8x16
    wire [4:0] cxA8 = dx8[4:0];                      // run8  16x16

    //------------------------------------------------------------------
    // 片头卡是【深色】且不换色：它只在白幕上存在（见 card_on），
    // 光刃化开到那一行它就消失了 —— 所以不需要 title_dark 那套变色逻辑。
    // 动画结束后由顶部的常驻片名（r0/r1）接管，颜色照旧。
    //------------------------------------------------------------------
    reg [2:0]  ofont;                   // 0=A16 1=B32 2=C8 3=D16（新增段）
    reg [6:0]  ocode;
    reg [4:0]  ocx, ocy;
    reg [23:0] ocol;

    always @* begin
        ofont = 3'd0; ocode = 7'd127; ocx = 5'd0; ocy = 5'd0; ocol = 24'hffffff;
        // 菜单的优先级最高：它盖住常驻字幕
        if (r10) begin                                   // 菜单项文字（16x16）
            ofont = (m_row == 4'd4) ? 3'd0 : 3'd6;
            ocx = {1'b0, m_dx1[3:0]}; ocy = m_cy;
            ocol = 24'hffffff; ocode = m_code10;
        end else if (r11) begin                          // 菜单项数值（8x16）
            ofont = 2'd2; ocx = {2'b0, m_vi}; ocy = m_cy;
            ocol = 24'hffd98a; ocode = m_code11;
        end else if (r20) begin                          // 右上角滚动中文
            ofont = 3'd6; ocx = {1'b0, ticker_dx[3:0]};
            ocy = {1'b0, (y - 10'd16)}; ocol = 24'hfff0b8;
            ocode = ticker_cjk_code;
        end else if (r21) begin                          // 歌曲号 n/total
            ofont = 3'd2; ocx = {2'b0, ticker_dx[2:0]};
            ocy = {1'b0, (y - 10'd16)}; ocol = 24'hfff0b8;
            ocode = ticker_num_code;
        end else if (r19) begin                          // 拓展④ 分辨率/缩放比（段C ASCII）
            ofont = 3'd2; ocx = {2'b0, rs_dx[2:0]}; ocy = cyC4; ocol = 24'h9fb4d0;
            ocode = m_code19;
        end else if (r9) begin                           // 菜单标题「设 置」
            // ocy 必须用「y 减去标题自己的 y0=128」。原来误用了 m_yoff（= y-172），
            // 在 y=128 处会下溢成 980，[3:0] 取到 4 —— 行号全错。
            ofont = 2'd0; ocx = {1'b0, m_dx0[3:0]}; ocy = {1'b0, (y - 10'd128)};
            ocol = 24'hffffff; ocode = m_dx0[4] ? 7'd31 : 7'd30;
        // ---------------- 开场片头卡（白幕正中三行，2 倍放大）----------------
        // 2x 的关键就三处：ocx 取 dx[..:1]、ocy 取 dy[4:1]、字格步长翻倍。
        end else if (r14) begin                          // 潮汐作曲家（片头卡，段E 原生32x32）
            ofont = 3'd4; ocx = cd1[4:0]; ocy = cy1[4:0];
            ocol = 24'h2b3a52;
            case (cd1[8:5])
                3'd0: ocode = 7'd0;  3'd1: ocode = 7'd1;  3'd2: ocode = 7'd2;
                3'd3: ocode = 7'd3;  default: ocode = 7'd4;
            endcase
        end else if (r15) begin                          // TIDE COMPOSER（片头卡，段F 原生16x32）
            ofont = 3'd5; ocx = {1'b0, cd2[3:0]}; ocy = cy2[4:0];
            ocol = 24'h5a6a86;
            // 段F 码：0=空格 1=T 2=I 3=D 4=E 5=C 6=O 7=M 8=P 9=S 10=R
            case (cd2[7:4])
                4'd0:  ocode = 7'd1;   4'd1:  ocode = 7'd2;   4'd2:  ocode = 7'd3;
                4'd3:  ocode = 7'd4;   4'd4:  ocode = 7'd0;   4'd5:  ocode = 7'd5;
                4'd6:  ocode = 7'd6;   4'd7:  ocode = 7'd7;   4'd8:  ocode = 7'd8;
                4'd9:  ocode = 7'd6;   4'd10: ocode = 7'd9;   4'd11: ocode = 7'd4;
                default: ocode = 7'd10;
            endcase
        end else if (r16) begin                          // 基于（段E 原生32x32，2 格）
            ofont = 3'd4; ocx = cd3[4:0]; ocy = cy3[4:0];
            ocol = 24'h2b3a52;
            ocode = cd3[5] ? 7'd6 : 7'd5;                // 段E 码 5=基 6=于
        end else if (r17) begin                          // FPGA（段F 原生16x32，4 格）
            ofont = 3'd5; ocx = {1'b0, cd4[3:0]}; ocy = cy3[4:0];
            ocol = 24'h5a6a86;
            case (cd4[6:4])
                3'd0: ocode = 7'd11;                     // F
                3'd1: ocode = 7'd8;                      // P
                3'd2: ocode = 7'd12;                     // G
                default: ocode = 7'd13;                  // A
            endcase
        end else if (r18) begin                          // 的海洋音画实时生成装置（段E，【11】格）
            ofont = 3'd4; ocx = cd5[4:0]; ocy = cy3[4:0];
            ocol = 24'h2b3a52;
            // 段E 码 7..17 正好连续（的海洋音画实时生成装置），直接加
            ocode = 7'd7 + {2'b0, cd5[8:5]};
        end else if (r0) begin                                   // 潮汐作曲家（主界面，段E 原生32x32）
            ofont = 3'd4; ocx = cda[4:0]; ocy = cya[4:0];
            // 【注意这里是浅色】主界面背景是压暗的天空，浅色才对。
            // 片头卡用的同两个词是另一个 run（r14/r15），那边才是深色。
            ocol = 24'hf2f6ff;
            case (cda[8:5])
                3'd0: ocode = 7'd0;   3'd1: ocode = 7'd1;   3'd2: ocode = 7'd2;
                3'd3: ocode = 7'd3;   default: ocode = 7'd4;
            endcase
        end else if (r1) begin                          // TIDE COMPOSER（主界面，段F 原生16x32）
            ofont = 3'd5; ocx = {1'b0, cdb[3:0]}; ocy = cyb[4:0];
            ocol = 24'hc8cee0;
            // 段F 码：0=空格 1=T 2=I 3=D 4=E 5=C 6=O 7=M 8=P 9=S 10=R
            case (cdb[7:4])
                4'd0:  ocode = 7'd1;   4'd1:  ocode = 7'd2;   4'd2:  ocode = 7'd3;
                4'd3:  ocode = 7'd4;   4'd4:  ocode = 7'd0;   4'd5:  ocode = 7'd5;
                4'd6:  ocode = 7'd6;   4'd7:  ocode = 7'd7;   4'd8:  ocode = 7'd8;
                4'd9:  ocode = 7'd6;   4'd10: ocode = 7'd9;   4'd11: ocode = 7'd4;
                default: ocode = 7'd10;
            endcase
        end else if (r2) begin                          // 场景名（中文，随场景变）
            ofont = 2'd1; ocx = cxB;  ocy = cyB;  ocol = 24'hffffff;
            case (dx2[6:5])
                2'd0: ocode = {5'd0, scene_sync2} * 7'd2;             // 第1字
                2'd1: ocode = 7'd127;                                 // 中间留白
                default: ocode = {5'd0, scene_sync2} * 7'd2 + 7'd1;   // 第2字
            endcase
        end else if (r3) begin                          // 场景名（英文）
            ofont = 2'd2; ocx = cxC3; ocy = cyC3; ocol = 24'hc8cee0;
            case (scene_sync2)
                2'd0: case (dx3[6:3])   // MORNING TIDE
                    4'd0: ocode=7'd23; 4'd1: ocode=7'd25; 4'd2: ocode=7'd28;
                    4'd3: ocode=7'd24; 4'd4: ocode=7'd19; 4'd5: ocode=7'd24;
                    4'd6: ocode=7'd17; 4'd7: ocode=7'd0;  4'd8: ocode=7'd30;
                    4'd9: ocode=7'd19; 4'd10: ocode=7'd14; 4'd11: ocode=7'd15;
                    default: ocode=7'd0;
                endcase
                2'd1: case (dx3[6:3])   // CLEAR SEA
                    4'd0: ocode=7'd13; 4'd1: ocode=7'd22; 4'd2: ocode=7'd15;
                    4'd3: ocode=7'd11; 4'd4: ocode=7'd28; 4'd5: ocode=7'd0;
                    4'd6: ocode=7'd29; 4'd7: ocode=7'd15; 4'd8: ocode=7'd11;
                    default: ocode=7'd0;
                endcase
                2'd2: case (dx3[6:3])   // DUSK HARBOR
                    4'd0: ocode=7'd14; 4'd1: ocode=7'd31; 4'd2: ocode=7'd29;
                    4'd3: ocode=7'd21; 4'd4: ocode=7'd0;  4'd5: ocode=7'd18;
                    4'd6: ocode=7'd11; 4'd7: ocode=7'd28; 4'd8: ocode=7'd12;
                    4'd9: ocode=7'd25; 4'd10: ocode=7'd28; default: ocode=7'd0;
                endcase
                default: case (dx3[6:3]) // NIGHT VOYAGE
                    4'd0: ocode=7'd24; 4'd1: ocode=7'd19; 4'd2: ocode=7'd17;
                    4'd3: ocode=7'd18; 4'd4: ocode=7'd30; 4'd5: ocode=7'd0;
                    4'd6: ocode=7'd32; 4'd7: ocode=7'd25; 4'd8: ocode=7'd35;
                    4'd9: ocode=7'd11; 4'd10: ocode=7'd17; default: ocode=7'd15;
                endcase
            endcase
        end else if (r4) begin                          // 03 / 04
            ofont = 2'd2; ocx = cxC4; ocy = cyC4; ocol = 24'hbcc6dc;
            case (dx4[5:3])
                3'd0: ocode = 7'd1;                        // '0'
                3'd1: ocode = 7'd1 + {5'd0, oi_s2} + 7'd1; // 当前序号（1 起）
                3'd2: ocode = 7'd0;                        // 空格
                3'd3: ocode = 7'd37;                       // '/'
                3'd4: ocode = 7'd0;
                3'd5: ocode = 7'd1;
                default: ocode = 7'd1 + {4'd0, ot_s2};     // 总数
            endcase
        end else if (r5) begin                          // 自动轮播 / 手动
            ofont = 2'd0; ocx = cxA5; ocy = cyC4; ocol = 24'hbcc6dc;
            if (oa_s2) begin
                case (dx5[5:4])
                    2'd0: ocode = 7'd5;  2'd1: ocode = 7'd6;
                    2'd2: ocode = 7'd7;  default: ocode = 7'd8;
                endcase
            end else begin
                case (dx5[5:4])
                    2'd0: ocode = 7'd12; 2'd1: ocode = 7'd6;
                    default: ocode = 7'd127;
                endcase
            end
        end else if (r6) begin                          // 间隔
            ofont = 2'd0; ocx = cxA6; ocy = cyC4; ocol = 24'hbcc6dc;
            ocode = dx6[4] ? 7'd10 : 7'd9;
        end else if (r7) begin                          // 周期数字
            ofont = 2'd2; ocx = cxC7; ocy = cyC4; ocol = 24'hbcc6dc;
            ocode = period_code;
        end else if (r8) begin                          // 秒
            ofont = 2'd0; ocx = cxA8; ocy = cyC4; ocol = 24'hbcc6dc;
            ocode = 7'd11;
        end else if (r12) begin                         // 署名 "from"（8x16 ASCII）
            ofont = 2'd2; ocx = {2'b0, m_dx12[2:0]}; ocy = cyC4;
            ocol = 24'h000000; ocode = m_code12;   // 【用户要求】署名改纯黑
        end else if (r13) begin                         // 署名 "奶蛙大队"（16x16）
            ofont = 2'd0; ocx = {1'b0, m_dx13[3:0]}; ocy = cyC4;
            ocol = 24'h000000; ocode = m_code13;   // 【用户要求】署名改纯黑
        end
    end

    // 字库地址：base + code*每字字节 + cy*每行字节 + cx/8
    // 字库共 2992 字节（署名加了「奶蛙大队」），地址必须 12 位。
    // 基址【必须】和 font_rom_map.vh / gen_font.py 一致：
    //   段A=0   (42字, 每字 32B)   段B=1344 (8字, 每字 128B)   段C=2368 (39字, 每字 16B)
    // 【踩过的坑】上面的注释曾经停留在一版旧基址（1216/2240），
    //   而下面的代码是对的（1344/2368）—— 注释和代码不一致最容易误导下一次改动。
    // 注意：ocode=127 是空白标记，127<<7=16256 会回绕成一个真实地址，
    //      所以空白必须靠下面的 osd_blank 显式屏蔽，不能指望地址越界返回 0。
    // 【13 位】新增段E/F 之后总长 6672 字节，12 位(4095)装不下，必须扩到 13 位。
    //   基址：A=0 B=1344 C=2368 D=2992 E=3472 F=5776
    reg [12:0] faddr;
    always @* begin
        case (ofont)
            // 段A 中文16x16：每行 2 字节，字 32 字节
            3'd0:    faddr = 13'd0    + ({6'd0, ocode} << 5) + ({7'd0, ocy} << 1) + {11'd0, ocx[4:3]};
            // 段B 中文32x32：每行 4 字节，字 128 字节
            3'd1:    faddr = 13'd1344 + ({6'd0, ocode} << 7) + ({5'd0, ocy} << 2) + {11'd0, ocx[4:3]};
            // 段C ASCII8x16：每行 1 字节，字 16 字节
            3'd2:    faddr = 13'd2368 + ({6'd0, ocode} << 4) + {7'd0, ocy};
            // 段D 中文16x16（片头卡正式名称，16x16 版）
            3'd3:    faddr = 13'd2992 + ({6'd0, ocode} << 5) + ({7'd0, ocy} << 1) + {11'd0, ocx[4:3]};
            // 段E 中文32x32【原生高清】：片名 + 片头卡大字
            3'd4:    faddr = 13'd3472 + ({6'd0, ocode} << 7) + ({5'd0, ocy} << 2) + {11'd0, ocx[4:3]};
            // 段F ASCII16x32【原生高清】：TIDE COMPOSER / FPGA
            // 段F ASCII16x32【原生高清】：TIDE COMPOSER / FPGA
            3'd5:    faddr = 13'd5776 + ({6'd0, ocode} << 6) + ({6'd0, ocy} << 1) + {11'd0, ocx[4:3]};
            // 段G 中文16x16【7 项菜单文字】：一个 run 只能用一段字库
            default: faddr = 13'd6672 + ({6'd0, ocode} << 5) + ({7'd0, ocy} << 1) + {11'd0, ocx[4:3]};
        endcase
    end

    //========================================================================
    // 字库 ROM —— 【必须插一级流水】
    //
    // font_rom 是纯【组合】ROM（一个大 case），每个像素都要查一次，
    // 它本来就是全设计最长的那条路径。实测：
    //     字库 6672 字节 -> SWNS +0.293 ns   （勉强够）
    //     字库 7280 字节 -> SWNS +0.003 ns   ← 塌掉，40ns 周期用掉 39.997ns
    // 3ps 余量等于没有余量，任何扰动都会让 SDRAM 采样出错 ——
    // 上板表现就是【满屏椒盐噪点】（亮像素突然变暗）。
    //
    // 【为什么之前查不出来】构建日志里有很多条 "Setup WNS"（place/route 逐步
    //   报的中间值），抓日志尾部会读到中间值，看着像"余量恢复了"。
    //   【只认 final_timing.rpt 的 SWNS: / HWNS:】，那才是最终值。
    //
    // 插一级流水后：faddr 先寄存，ROM 读出的 fbyte 与 ocode/ocx 同拍对齐。
    // 代价：文字整体右移 1 像素 —— 肉眼看不出。
    //========================================================================
    reg [12:0] faddr_r;
    reg [6:0]  ocode_r;
    reg [2:0]  ocx_r;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            faddr_r <= 13'd0; ocode_r <= 7'd127; ocx_r <= 3'd0;
        end else begin
            faddr_r <= faddr;
            ocode_r <= ocode;
            ocx_r   <= ocx[2:0];
        end
    end

    wire [7:0] fbyte;
    font_rom u_font_rom(.addr(faddr_r), .dout(fbyte));

    // 位序反转后按 cx[2:0] 选位（每行最左像素在 MSB）
    wire [7:0] fbrev = {fbyte[0], fbyte[1], fbyte[2], fbyte[3],
                        fbyte[4], fbyte[5], fbyte[6], fbyte[7]};
    // 空白格必须显式判掉！
    // code=127 时地址会回绕到字库中间，读出一个真实的字，看上去就是乱码。
    wire osd_blank = (ocode_r == 7'd127);
    wire osd_px = (~osd_blank) && fbrev[ocx_r];
    // 菜单的三段（r9/r10/r11）永远生效；
    // 常驻字幕（r0..r8）在菜单打开时整段隐藏，把画面让给菜单。
    // 署名（r12/r13）：STATE.md 第十一节明确要求【只在开场动画期间显示】，
    //   所以用 boot_active 门控 —— 动画一结束它就退场，主界面上不再出现。
    wire osd_on = ((r9 | r10 | r11) || r19 || r20 || r21 || ((r12 | r13) & boot_active) ||
                   (r14 | r15 | r16 | r17 | r18) ||
                   ((r0 | r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8) && !mn_s2))
                  && osd_px;

    //========================================================================
    // 替换层：优先级从高到低
    //   三层波浪按"近层盖远层"叠放（fill3 > fill2 > fill1），
    //   这正是真实水面近处遮挡远处的效果，也自然形成视差纵深。
    //========================================================================
    // 优先级顺序很关键：
    //   描边 > 文字 > 高亮条 > 面板底色 > 波浪/灯塔 > 背景
    // 【踩过的坑】原来把 osd_on 排在 m_panel 后面 —— 面板底色覆盖整个面板区域，
    // 而文字也在那个区域里，结果面板出来了却一个字都看不见（"菜单没字"）。
    wire [23:0] repl =
          m_border ? 24'hcfe6f2 :          // 菜单面板描边
          osd_on   ? ocol :                // 所有文字（含菜单三段）压在面板之上
          m_hl     ? {hl_r, hl_g, hl_b} :  // 选中行高亮条（在文字之下）
          m_panel  ? {mb_r, mb_g, mb_b} :  // 面板底色（背景压暗 + 冷色偏移）
          // 【开场动画期间：灯塔压在波浪之上】
          //   平时是"波浪 > 灯塔"（近处的浪盖住塔基，物理上对，也形成纵深）。
          //   但白幕期要把灯塔完整地画在白幕上，如果还让波浪压在上面，
          //   塔身在波带(y300..386)那一段就会被波浪顶掉 ——
          //   要么浪漏到白幕上（用户第一次反馈），要么给塔挖出一个白缺口
          //   （我上一版用 & ~wave_on 修过头，用户第二次反馈）。
          //   所以开场期间把灯塔提到波浪之上，塔身完整；动画一结束就恢复原样。
          (boot_active && lh_edge_hi) ? 24'h5a4a6e :
          (boot_active && lh_on)      ? lh_col :
          crest3   ? 24'hbfeef4 :
          crest2   ? 24'h9fd8e8 :
          crest1   ? 24'h7fc0dc :
          fill3    ? wcol3 :
          fill2    ? wcol2 :
          fill1    ? wcol1 :
          lh_edge_hi ? 24'h5a4a6e :
          lh_on    ? lh_col :
          mn_disc  ? cel_col  :
                       rgb_faded;

    //========================================================================
    // 加法层：所有发光元素相加（暖白），带饱和
    //
    // 位宽！7 项各 8 位最大 1785，必须用 11 位承载，否则会回绕 ——
    // 溢出后 8 位截断的结果是"亮像素突然变暗"，肉眼就是满屏椒盐噪点。
    //========================================================================
    // 光束【不在这里】—— 它要单独加成【饱和亮黄】，见下面的 Stage 2。
    // 原因：暖白的 glow 走的是 R≈G≈B 的加色，做不出"亮黄"；
    // 光束要的是 R≈G 拉满、B 只给两三成，必须单独一路加。
    wire [10:0] glow_sum = {3'b0, mn_glow} +
                           {3'b0, lp_a2}     + {3'b0, wc_a}    +
                           {3'b0, mn_refl_a} + {3'b0, flash_add} +
                           {3'b0, (foam ? 8'd170 : 8'd0)};
    wire [7:0] glow = (glow_sum > 11'd255) ? 8'hFF : glow_sum[7:0];
    // 暖白：R 全给，G 约 0.94，B 约 0.75
    wire [7:0] glow_g = glow - (glow >> 4);
    wire [7:0] glow_b = glow - (glow >> 2);

    //========================================================================
    // 流水线：把这条 39.4ns 的组合链切成两段
    //
    // 为什么必须做：
    //   video_clk 周期 40ns（25MHz），实测从 y_reg[9] 到 repl[7] 的组合延迟
    //   已经 39.4ns，只剩 0.28ns 余量。其中 cell 只占 10.5ns（25 级，每级
    //   0.42ns 很正常），net 占 28.9ns（平均每条网线 1.2ns，正常应 0.2~0.4ns）。
    //   根因是 y 的【扇出 128】—— 叠加层里几十处 y >= y1 / y < y2 比较都在用它，
    //   逻辑被摊到芯片各处，布线拥塞。菜单还要往这个域加东西，不先加固必挂。
    //
    // 怎么切：
    //   Stage 1（原样保留）：x/y -> 几何判定 -> 配色 -> 优先级 mux -> repl
    //   【寄存器】把 repl / glow / star / 背景 一起存下来
    //   Stage 2（新增）：只剩 加法 + 饱和，5 级以内
    //
    // 插了寄存器之后，TD 能把 Stage 1 的逻辑聚成一簇（出口只有一个局部寄存器），
    // net 延迟会大幅下降 —— 这才是收益的真正来源，不是"少了一半逻辑"。
    //
    // 【逐像素完全等价】：s1_repl 与 s1_bg 取自【同一个像素】，叠加层和背景
    //   不会错位。整体比 HDMI 帧时序晚一拍 = 画面右移 1 像素，640 宽里差一列，
    //   肉眼不可见。
    //========================================================================
    //------------------------------------------------------------------
    // 开场动画白幕 —— 见 boot_anim.v
    //
    // 【流水线】原来这里是一级寄存器（几何 -> repl -> s1_repl）。
    // 加上白幕的 8x8 乘法之后，x_reg -> ... -> MULT18 -> s1_repl 变成全设计
    // 最长路径 39.6ns/40ns（余量只剩 +103ps），报告里 net 占 60% ——
    // 正是 KNOWN_ISSUES「组合逻辑扇出过大 -> 布线拥塞 / 插一级流水寄存器」那一条。
    //
    // 所以把这一级【拆成两级】：
    //   Stage 1a  几何 -> repl / glow / beam / star / bg        （打拍 -> r1_*）
    //   Stage 1b  白幕混合只作用在 r1_repl 上                    （再打拍 -> s1_*）
    // 【所有 s1_* 一起多打一拍】—— 只延 repl 会让叠加色和加法层错开 1 像素。
    // 代价：整体比原来再晚一拍（画面右移 1 像素，累计 2 像素，肉眼不可见）。
    //------------------------------------------------------------------
    reg [23:0] r1_repl;
    reg [10:0] r1_ys;           // 斜切行坐标 = y + (x >> 4)
    reg        r1_fg;           // 前景遮罩：灯塔 + 片名/副标题/署名，画在白幕【之上】
    reg [7:0]  r1_glow;
    reg [7:0]  r1_beam;
    reg [7:0]  r1_star;
    reg [23:0] r1_bg;
    reg        r1_live;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            r1_repl <= 24'd0;
            r1_ys   <= 11'd0;
            r1_fg   <= 1'b0;
            r1_glow <= 8'd0;
            r1_beam <= 8'd0;
            r1_star <= 8'd0;
            r1_bg   <= 24'd0;
            r1_live <= 1'b0;
        end else begin
            r1_repl <= transition_visible ? repl : 24'd0;
            r1_ys   <= {1'b0, y} + {7'd0, x[10:4]};    // 斜切：640px 跨 40px ≈ 3.6 度
            // 前景遮罩：这些内容画在白幕【之上】，不受白幕和黄光影响。
            //   lh       —— 灯塔（用户要求"一上电就看得见灯塔立在白幕前"）
            //   r0/r1    —— 片名「潮汐作曲家」+ 副标题（用户要求"一上电就在白幕上看到字"）
            //   r12/r13  —— 左下角署名（同上）
            // 场景名 / 底部信息栏【不在】这里 —— 它们仍然靠光刃扫出来。
            // 【必须 & osd_px】否则豁免的是 run 的【整个矩形】，
            // 白幕上就会出现一块块"底图透出来"的方块 —— 用户照片里看到的就是这个。
            // 只有【真正点亮的字形像素】才豁免。
            //
            // 灯塔不需要再 & ~wave_on —— 开场期间 repl 里灯塔已经压在波浪之上
            // （见 repl 里的 boot_active && lh_on 分支），所以 lh_on 覆盖的
            // 就是灯塔真正画出来的像素。
            r1_fg   <= lh_edge_hi | lh_on |
                       ((r14 | r15 | r16 | r17 | r18 | r12 | r13) & osd_px);
            r1_glow <= transition_visible ? glow : 8'd0;
            r1_beam <= transition_visible ? lh_beam_a : 8'd0;
            r1_star <= transition_visible ? star_add : 8'd0;
            r1_bg   <= rgb_faded;
            r1_live <= active && de && !bypass;
        end
    end

    wire [23:0] repl_v;
    boot_veil u_boot_veil (
        .ys          (r1_ys),
        .rgb_in      (r1_repl),
        .blade       (boot_blade),
        .trail       (boot_trail),
        .ebb         (boot_ebb),
        .ebb_amt     (boot_ebb_amt),
        .boot_active (boot_active),
        .warm_fade   (boot_warm),
        .fg_on       (r1_fg),
        .rgb_out     (repl_v)
    );

    reg [23:0] s1_repl;
    reg [7:0]  s1_glow;
    reg [7:0]  s1_beam;         // 灯塔光束（单独一路：饱和亮黄）
    reg [7:0]  s1_star;
    reg [23:0] s1_bg;
    reg        s1_live;         // 本拍是否输出叠加层（含 bypass 与消隐判断）

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_repl <= 24'd0;
            s1_glow <= 8'd0;
            s1_beam <= 8'd0;
            s1_star <= 8'd0;
            s1_bg   <= 24'd0;
            s1_live <= 1'b0;
        end else begin
            s1_repl <= repl_v;
            s1_glow <= r1_glow;
            s1_beam <= r1_beam;
            s1_star <= r1_star;
            s1_bg   <= r1_bg;
            s1_live <= r1_live;
        end
    end

    // Stage 2：只剩加法与饱和
    wire [7:0] s2_glow_g = s1_glow - (s1_glow >> 4);
    wire [7:0] s2_glow_b = s1_glow - (s1_glow >> 2);

    // 位宽：repl(255) + glow(255) + star(255) = 765，必须 10 位承载，
    // 用 9 位会回绕成 253，亮的地方反而发黑 —— 这就是之前"满屏噪点"的根源。
    // ---- 灯塔光束：饱和亮黄，单独一路 ----
    // R 全给、G 约 0.88、B 【减】0.25 —— 这样才是"亮黄"。
    //
    // 【为什么 B 是减不是加】原来 R/G/B 全是加色。加色在白幕上完全失效
    //   （255 + 任何值仍是 255），所以开场那 6.5 秒纯白期【根本看不见光束】——
    //   用户要的正是"白幕期就要看到"。
    //   改成 R/G 加、B 减之后：
    //     白幕 (255,255,255) -> R/G 饱和仍是 255，B 掉下来 = 亮黄 ✓
    //     海景 (暗) -> R/G 加上去、B 减掉 = 更亮更黄 ✓
    //   一个机制两边都对，而且纯加减，不用乘法器。
    wire [8:0] beam_sum = {1'b0, s1_beam};
    wire [7:0] beam_a   = beam_sum[8] ? 8'hFF : beam_sum[7:0];
    wire [9:0] bm_r = {2'b0, beam_a};
    wire [9:0] bm_g = {2'b0, beam_a} - ({2'b0, beam_a} >> 3);
    // 【B 减多少 = 白幕上有多黄】1.5 倍时白幕变 (255,255,86)，用户反馈"太亮黄"。
    //   收到 0.625 倍（最大 60）-> 白幕 (255,255,195)，是清亮的淡黄而不是浓黄。
    wire [9:0] bm_b = {2'b0, beam_a} >> 1;
    wire [9:0] bm_b2 = {2'b0, beam_a} >> 3;

    wire [9:0] rr10 = {2'b0, s1_repl[23:16]} + {2'b0, s1_glow}   + {2'b0, s1_star} + bm_r;
    wire [9:0] gg10 = {2'b0, s1_repl[15:8]}  + {2'b0, s2_glow_g} + {2'b0, s1_star} + bm_g;
    // 蓝通道：先求和，再做【饱和减法】（下溢钳到 0）。
    // 用 11 位承载，最高位就是借位 —— 比再挂一个比较器便宜。
    wire [9:0]  bb_add = {2'b0, s1_repl[7:0]} + {2'b0, s2_glow_b} + {2'b0, s1_star};
    wire [10:0] bb_sub = {1'b0, bb_add} - {1'b0, (bm_b + bm_b2)};
    wire [9:0]  bb10   = bb_sub[10] ? 10'd0 : bb_sub[9:0];

    //========================================================================
    // 亮度 / 对比度：合成【一个仿射变换】out = in*A + B
    //
    //   亮度增益 b = 128 + (档位-5)*16    -> 48..208  (0.375x .. 1.625x)
    //   对比度增益 c = 128 + (档位-5)*16  -> 48..208
    //   A = b*c/128      B = 128 - c
    //
    // 为什么能合并：亮度是 out1 = in*b/128；对比度是 out2 = (out1-128)*c/128 + 128
    // 展开就是 in*(b*c/16384) + 128 - c —— 一个乘、一个加，两项功能一起完成，
    // 每通道只要一个乘法器（而不是各一个、共 6 个）。
    //
    // 【默认档位 5/5 时 A=128、B=0，输出逐像素等于原值】——
    // 所以这个功能平时完全透明，不会改变已经调好的画面。
    //========================================================================
    // 先得到完整合成像素，再统一做亮度增益。三个通道使用同一个无符号系数，
    // 不引入偏置项，因此不会重现旧版仿射变换造成的偏青。
    wire [23:0] rgb_full = (!s1_live) ? s1_bg :
                           { (rr10 > 10'd255) ? 8'hFF : rr10[7:0],
                             (gg10 > 10'd255) ? 8'hFF : gg10[7:0],
                             (bb10 > 10'd255) ? 8'hFF : bb10[7:0] };

    wire [9:0] smooth_image_gain;
    wire signed [10:0] smooth_contrast_offset;

    video_level_ramp u_video_level_ramp (
        .clk             (clk),
        .rst             (rst),
        .frame_tick      (vs_last && !vs),
        .brightness_sel  (br_s2),
        .contrast_sel    (ct_s2),
        .idle_dim        (idim_s2),
        .image_gain      (smooth_image_gain),
        .contrast_offset (smooth_contrast_offset)
    );

    video_levels u_video_levels (
        .rgb_in          (rgb_full),
        .image_gain      (smooth_image_gain),
        .contrast_offset (smooth_contrast_offset),
        .rgb_out         (rgb_out)
    );

    //========================================================================
    // 像素坐标与相位
    //========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            de_last <= 1'b0;
            vs_last <= 1'b0;
            x <= 11'd0;
            y <= 10'd1023;
            level_sync1 <= 8'd0;
            level_sync2 <= 8'd0;
            scene_sync1 <= 2'd0;
            scene_sync2 <= 2'd0;
        end else begin
            de_last <= de;
            vs_last <= vs;
            level_sync1 <= audio_level;
            level_sync2 <= level_sync1;
            scene_sync1 <= scene_index;
            scene_sync2 <= scene_sync1;
            if (!vs)
                y <= 10'd1023;
            else if (de && !de_last)
                y <= y + 10'd1;
            if (!de_last && de)
                x <= 11'd0;
            else if (de)
                x <= x + 11'd1;
        end
    end
endmodule

// Exact rasterized circle and concentric circular halo. The multiply inputs
// are limited to 6 bits because the outer halo radius is at most 62 pixels.
module celestial_circle(
    input  wire [10:0] dx,
    input  wire [10:0] dy,
    input  wire        is_sun,
    output wire        disc,
    output wire [7:0]  glow
);
    wire [6:0] outer_r = is_sun ? 7'd62 : 7'd60;
    wire outer_box = (dx <= outer_r) && (dy <= outer_r);
    wire [11:0] dx_sq = dx[5:0] * dx[5:0];
    wire [11:0] dy_sq = dy[5:0] * dy[5:0];
    wire [12:0] dist_sq = {1'b0, dx_sq} + {1'b0, dy_sq};
    wire [12:0] body_sq  = is_sun ? 13'd576  : 13'd484;  // 24^2 / 22^2
    wire [12:0] ring1_sq = is_sun ? 13'd1024 : 13'd900;  // 32^2 / 30^2
    wire [12:0] ring2_sq = is_sun ? 13'd1600 : 13'd1444; // 40^2 / 38^2
    wire [12:0] ring3_sq = is_sun ? 13'd2500 : 13'd2304; // 50^2 / 48^2
    wire [12:0] outer_sq = is_sun ? 13'd3844 : 13'd3600; // 62^2 / 60^2

    assign disc = outer_box && (dist_sq <= body_sq);
    assign glow = !outer_box             ? 8'd0  :
                  (dist_sq <= body_sq)   ? 8'd28 :
                  (dist_sq <= ring1_sq)  ? 8'd20 :
                  (dist_sq <= ring2_sq)  ? 8'd12 :
                  (dist_sq <= ring3_sq)  ? 8'd7  :
                  (dist_sq <= outer_sq)  ? 8'd3  : 8'd0;
endmodule

// Brightness and contrast coefficients move four Q8 steps per frame. At
// 60 Hz, the largest 50% <-> 150% contrast transition takes about 0.53 s.
module video_level_ramp(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_tick,
    input  wire [1:0]  brightness_sel,
    input  wire [2:0]  contrast_sel,
    input  wire        idle_dim,
    output reg  [9:0]  image_gain,
    output reg signed [10:0] contrast_offset
);
    wire [8:0] user_brightness_target =
        (brightness_sel == 2'd0) ? 9'd64  :
        (brightness_sel == 2'd1) ? 9'd128 :
        (brightness_sel == 2'd2) ? 9'd192 : 9'd256;
    wire [8:0] brightness_target = idle_dim ? 9'd64 : user_brightness_target;
    wire [9:0] contrast_target =
        (contrast_sel == 3'd0) ? 10'd128 :
        (contrast_sel == 3'd1) ? 10'd192 :
        (contrast_sel == 3'd2) ? 10'd232 :
        (contrast_sel == 3'd3) ? 10'd256 :
        (contrast_sel == 3'd4) ? 10'd280 :
        (contrast_sel == 3'd5) ? 10'd320 : 10'd384;

    reg [8:0] brightness_gain;
    reg [9:0] contrast_gain;
    wire [18:0] combined_gain = brightness_gain * contrast_gain;
    wire signed [10:0] centered_offset =
        11'sd128 - $signed({2'b00, contrast_gain[9:1]});

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            brightness_gain <= 9'd256;
            contrast_gain    <= 10'd256;
            image_gain       <= 10'd256;
            contrast_offset  <= 11'sd0;
        end else if (frame_tick) begin
            image_gain      <= combined_gain[17:8];
            contrast_offset <= centered_offset;

            if (brightness_gain + 9'd4 < brightness_target)
                brightness_gain <= brightness_gain + 9'd4;
            else if (brightness_gain > brightness_target + 9'd4)
                brightness_gain <= brightness_gain - 9'd4;
            else
                brightness_gain <= brightness_target;

            if (contrast_gain + 10'd4 < contrast_target)
                contrast_gain <= contrast_gain + 10'd4;
            else if (contrast_gain > contrast_target + 10'd4)
                contrast_gain <= contrast_gain - 10'd4;
            else
                contrast_gain <= contrast_target;
        end
    end
endmodule

// Brightness and contrast are folded into one affine transform per channel.
// Contrast is centered at 128 and the result is saturated, so channels cannot
// wrap around or acquire a color cast near black/white.
module video_levels(
    input  wire [23:0] rgb_in,
    input  wire [9:0]  image_gain,
    input  wire signed [10:0] contrast_offset,
    output wire [23:0] rgb_out
);
    wire [17:0] scaled_r = rgb_in[23:16] * image_gain;
    wire [17:0] scaled_g = rgb_in[15:8]  * image_gain;
    wire [17:0] scaled_b = rgb_in[7:0]   * image_gain;
    wire signed [10:0] level_r = $signed({2'b00, scaled_r[16:8]}) + contrast_offset;
    wire signed [10:0] level_g = $signed({2'b00, scaled_g[16:8]}) + contrast_offset;
    wire signed [10:0] level_b = $signed({2'b00, scaled_b[16:8]}) + contrast_offset;
    wire [7:0] out_r = level_r[10] ? 8'd0 : (level_r > 11'sd255) ? 8'd255 : level_r[7:0];
    wire [7:0] out_g = level_g[10] ? 8'd0 : (level_g > 11'sd255) ? 8'd255 : level_g[7:0];
    wire [7:0] out_b = level_b[10] ? 8'd0 : (level_b > 11'sd255) ? 8'd255 : level_b[7:0];
    assign rgb_out = {out_r, out_g, out_b};
endmodule

// Resource-light spatial shutters. No extra frame buffers or pixel read ports.
// alpha=0 covers the entire background; alpha=255 reveals it exactly.
module transition_mask (
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [2:0] mode,
    input wire [7:0] alpha,
    output reg visible,
    output reg edge_on
);
    wire [11:0] a = {4'd0, alpha};
    wire [11:0] slide_limit = (a << 1) + (a >> 1); // 640/256
    wire [11:0] wave_limit = (a << 1) + (a >> 1) + (a >> 3) + (a >> 5); // 680/256
    wire [11:0] blade_limit = (a << 2) + (a >> 2) + (a >> 3); // 1120/256
    wire [11:0] radial_limit = a + (a >> 1) + (a >> 3); // 416/256
    reg [5:0] wave_offset;
    always @* begin
        case (y[8:4])
            5'd0,5'd16: wave_offset = 6'd20;
            5'd1,5'd15,5'd17,5'd31: wave_offset = 6'd28;
            5'd2,5'd14,5'd18,5'd30: wave_offset = 6'd34;
            5'd3,5'd13,5'd19,5'd29: wave_offset = 6'd38;
            5'd4,5'd12,5'd20,5'd28: wave_offset = 6'd40;
            5'd5,5'd11,5'd21,5'd27: wave_offset = 6'd38;
            5'd6,5'd10,5'd22,5'd26: wave_offset = 6'd34;
            5'd7,5'd9,5'd23,5'd25: wave_offset = 6'd28;
            5'd8,5'd24: wave_offset = 6'd20;
            default: wave_offset = 6'd12;
        endcase
    end
    wire [11:0] wave_score = {1'b0,x} + {6'd0,wave_offset};
    wire [11:0] blade_score = {1'b0,x} + {2'd0,y};
    wire [10:0] dx = (x >= 11'd320) ? x - 11'd320 : 11'd320 - x;
    wire [10:0] dy = (y >= 10'd240) ? {1'b0,y} - 11'd240 : 11'd240 - {1'b0,y};
    wire [10:0] hi = (dx > dy) ? dx : dy;
    wire [10:0] lo = (dx > dy) ? dy : dx;
    // Octagonal distance approximates a circle, without square/multiply/sqrt.
    wire [11:0] radial_score = {1'b0,hi} + ({1'b0,lo} >> 2) + ({1'b0,lo} >> 3);
    // Ordered 8x8 Bayer matrix: every rank 0..63 occurs exactly once.
    wire [5:0] bayer = {x[0]^y[0], y[0], x[1]^y[1], y[1], x[2]^y[2], y[2]};
    reg [11:0] score, limit;
    always @* begin
        score = 12'd0;
        limit = 12'd0;
        visible = 1'b1;
        edge_on = 1'b0;
        case (mode)
            3'd1: begin score = {1'b0,x}; limit = slide_limit; end
            3'd2: begin score = wave_score; limit = wave_limit; end
            3'd3: begin score = blade_score; limit = blade_limit; end
            3'd4: begin score = radial_score; limit = radial_limit; end
            3'd5: begin score = {6'd0,bayer}; limit = {6'd0,alpha[7:2]}; end
            default: begin score = 12'd0; limit = 12'd4095; end
        endcase
        if (mode >= 3'd1 && mode <= 3'd5) begin
            visible = (alpha == 8'd255) || ((alpha != 8'd0) && (score < limit));
            edge_on = visible && (alpha != 8'd255) && (mode >= 3'd2) &&
                      (mode <= 3'd4) && ((limit - score) <= 12'd5);
        end
    end
endmodule
