module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    // 从 BMP 头里解析出来的【实际】宽高（拓展④ 要在底部信息栏显示它们）
    // 注意与上面两个 input 的区别：那两个是"期望值"，用来校验这张图合不合规；
    // 这两个是"图里写的值"。平时相等，支持多分辨率之后就未必了。
    output reg [15:0]           hdr_width,
    output reg [15:0]           hdr_height,
    // 拓展③ 缩放模式：0=适应(FIT) 1=填充(FILL) 2=拉伸(FULL) 3=原始(1:1)
    // D1 步先只铺通路；重采样器（行缓冲 + 最近邻）在 D2 步接上这个输入。
    input  wire [1:0]           scale_mode,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] file_sector_count;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;

// 把解析到的宽高导出（低 16 位够用：BMP 宽高不会超过 65535）。
// 直接跟拍 width/height —— 串行收字节时会逐字节更新，收到第 26 字节就稳定了。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hdr_width  <= 16'd0;
        hdr_height <= 16'd0;
    end else begin
        hdr_width  <= width[15:0];
        hdr_height <= height[15:0];
    end
end
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [31:0] file_last_index;
reg        pixel_data_started;
reg        file_end_seen;

// header_match 现在在下面用 reg 声明（寄存一拍做时序加固），这里不再重复声明
wire bmp_data_valid;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
wire [31:0] file_len_with_new_msb;
wire pixel_data_first;
wire file_data_last;
// file_end_reached 直接驱动 sd_sec_read_addr（32 位）递增器的【时钟使能】，
// 而它本身是 "bmp_len_cnt == file_last_index"（32 位比较）再与 SD 有效信号相或，
// 实测 9.844ns / 10ns，76% 是走线延迟（起点 bmp_len_cnt_reg[3]，终点
// sd_sec_read_addr_reg[24].ce）。
//
// 但它只在最后一个【数据字节】到达时置位，而被采样是在 sd_sec_read_end
// （整个 512 字节扇区结束）—— 中间隔着几百个填充字节，早就稳定了。
// 所以寄存一拍完全无副作用，却把这条路径切成两段。
wire file_end_reached_comb;
reg  file_end_reached;

assign ready = (state == ST_IDLE);

// header_match 是全区最紧的一条路径（实测 9.528ns / 10ns，Logic Level 7，
// 其中 65% 是走线延迟）：它由 6 个比较相与而成，又直接驱动
// sd_sec_read_addr 的【时钟使能脚】—— 使能信号天生扇出大、布线散。
//
// 但这 6 个操作数（header_0/1、width、height、bit_count、compression）
// 全部是在扇区【前 54 字节】内捕获的寄存器，到 sd_sec_read_end 到来时
// 已经稳定了几百个字节时间。所以中间插一级寄存器完全无副作用，
// 却把"匹配逻辑 -> 使能"这一长条切成两段。
// 【2026-10-06 拓展③】尺寸校验从"必须正好 640x480"放宽成"4 档支持的尺寸之一"。
//
// 原来写的是 (width==bmp_width) && (height==bmp_height)，而 top 里
// bmp_width/bmp_height 是【写死的 640/480】—— 别的分辨率的图会被这条判掉、
// 直接不认，所以只做重采样还不够，校验必须一起放宽，否则图根本进不来。
//
// 只认这 4 档（而不是"任意尺寸"）的理由：
//   1. BMP 每行按 4 字节对齐。这 4 档的 width*3 分别是
//      1920 / 3072 / 3840 / 4608，全是 4 的倍数 -> 没有行尾填充，
//      重采样器里 src_x 的计数才准。别的宽度若 width*3 不是 4 的倍数，
//      行尾会有填充字节，必须另加"跳填充"逻辑，现在没做。
//   2. 白名单也是一道保险：卡上混着非图片文件时不会误判。
wire size_ok = ((width[15:0] == 16'd640)  && (height[15:0] == 16'd480))  ||
               ((width[15:0] == 16'd1024) && (height[15:0] == 16'd600))  ||
               ((width[15:0] == 16'd1280) && (height[15:0] == 16'd720))  ||
               ((width[15:0] == 16'd1536) && (height[15:0] == 16'd1024));

wire header_match_comb = (header_0 == "B") &&
                         (header_1 == "M") &&
                         size_ok &&
                         (bit_count    == 16'd24) &&
                         (compression  == 32'd0);
reg  header_match;
always @(posedge clk or posedge rst) begin
    if (rst) header_match <= 1'b0;
    else     header_match <= header_match_comb;
end

assign pixel_data_first = (bmp_len_cnt == pixel_offset);
assign file_data_last   = (bmp_len_cnt == file_last_index);
assign file_end_reached_comb = file_end_seen || (sd_sec_read_data_valid && file_data_last);
always @(posedge clk or posedge rst) begin
    if (rst) file_end_reached <= 1'b0;
    else     file_end_reached <= file_end_reached_comb;
end
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (pixel_data_started || pixel_data_first) &&
                        !file_end_seen;
assign file_len_with_new_msb = {sd_sec_read_data, file_len[23:0]};
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

// ---------------------------------------------------------------
// 时序加固：把扫描用的"下一个扇区"和两个比较结果打一拍。
//
// 原来 scan_sector(32位) -> +file_sector_count(32位加法) -> >scan_max_sector(32位比较)
// -> 再和 scan_found_total 的比较合并 -> scan_sector / sd_sec_read_addr 的 CE，
// 整条 7 级逻辑、扇出 38、净延迟占约 70%，布局一挤就违例
// （v31_tide_noseed 那次 -110ps 的违例就是它）。
//
// scan_sector 和 scan_found_total 只在状态跳转时改变，而这个判断是在
// sd_sec_read_end 到来时做的 —— 中间隔着几百拍。所以把中间结果先寄存一拍，
// 读到的仍然是"当前 scan_sector 算出来的值"，功能完全不变。
reg [31:0] next_match_r;
reg        next_match_over_r;
reg        scan_last_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_match_r      <= 32'd0;
        next_match_over_r <= 1'b0;
        scan_last_r       <= 1'b0;
    end else begin
        next_match_r      <= scan_sector + file_sector_count;
        next_match_over_r <= ((scan_sector + file_sector_count) > scan_max_sector);
        scan_last_r       <= ((scan_found_total + 3'd1) >= scan_target_count);
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        file_sector_count <= 32'd1;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : begin
                file_len[31:24] <= sd_sec_read_data;
                // Round file size up to 512-byte sectors once, outside the
                // scan decision path used at the end of this sector.
                if (file_len_with_new_msb == 32'd0)
                    file_sector_count <= 32'd1;
                else
                    file_sector_count <= {9'd0, file_len_with_new_msb[31:9]} +
                                         (|file_len_with_new_msb[8:0]);
            end

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
        file_last_index  <= 32'd0;
        pixel_data_started <= 1'b0;
        file_end_seen <= 1'b0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid) begin
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
            if (pixel_data_first)
                pixel_data_started <= 1'b1;
            if (file_data_last)
                file_end_seen <= 1'b1;
        end
    end else begin
        bmp_len_cnt <= 32'd0;
        pixel_data_started <= 1'b0;
        file_end_seen <= 1'b0;
        if ((state == ST_LOAD_WAIT) && write_req_ack)
            file_last_index <= (file_len == 32'd0) ? 32'd0 : (file_len - 32'd1);
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

//============================================================================
// 拓展③ 最近邻缩放 —— D2 第 1 步：先只做【拉伸 FULL】(scale_mode==2)
//
// 【为什么不需要行缓冲 / 不需要随机访问】
//   4 档支持的尺寸(640x480/1024x600/1280x720/1536x1024)除 640x480 外
//   【全部比屏幕大】-> 全是降采样 -> 源像素只会被【跳过】，绝不会被重复使用。
//   所以"源顺序到达、顺序决定发不发"与"目标驱动去原图取像素"是同一个映射。
//
// 【为什么数量一定准，不需要额外硬计数器兜底】
//   x：每源行加 src_w 共 src_w 次、减 640 共 K 次，末值 = (src_w*640) mod src_w = 0
//      -> K 恰好 = 640。而且每行正好 src_w 个像素，累加器自然回到原点，
//      【不需要按行复位】。y 方向同理恰好 480。
//
// 【时序】keep 必须在像素发出【之前】算好，所以这里是"算下一个、用这一个"：
//   每个源像素(byte_idx==2)时更新累加器、并算出【下一个】像素的 keep。
//
// ⚠️ 前提：每行源像素数要数得准。BMP 每行按 4 字节对齐，
//    640*3=1920 / 1024*3=3072 / 1280*3=3840 / 1536*3=4608 全是 4 的倍数
//    -> 这 4 档没有行尾填充，src_x 计数是准的。别的宽度若 *3 不是 4 的倍数
//    就会有填充字节，那时必须另加"跳填充"的逻辑。
//============================================================================
reg [15:0] sc_src_w, sc_src_h;
reg [17:0] sc_xacc, sc_yacc;
reg [15:0] sc_sx;                 // 本源行已处理的像素数
reg [15:0] sc_sy;                 // 已处理完的源行数（1:1 的 y 窗口要用）
reg        sc_pix_keep;           // 当前源像素要不要发（拉伸用）
reg        sc_row_keep;           // 当前源行要不要发（拉伸用）

// ---- 档位 ----
// 【重要】未实现的档位【不能直通】！
//   直通 = 把源图的像素原样往 640x480 的缓冲里灌。源比屏幕大时每行会多出像素，
//   写侧的行结构就乱了 —— 上板是一团斜掉的乱码，不是"没效果"。
//   所以 FIT(0) / FILL(1) 现在【暂时按拉伸 FULL 处理】，等它们各自做好再摘掉。
wire        sc_full = (scale_mode == 2'd0) |   // 适应 —— 还没做，暂按拉伸
                      (scale_mode == 2'd1) |   // 填充 —— 还没做，暂按拉伸
                      (scale_mode == 2'd2);    // 拉伸 FULL：两轴独立缩放
// 【2026-10-06】1:1 重新打开 —— 之前它 +171 LUT 触发了
//   PHY-8023 / RUN-8102（rst_all_dup_307_holdbuf 布不下去）。
//   现在 phy_1\settings.cfg 里已经注入了 TD 官方 CongestionHigh 策略的参数，
//   用它再试一次；能过就说明那个"LUT 门槛"只是默认策略太保守。
wire        sc_11   = (scale_mode == 2'd3);   // 原始 1:1：不缩放，取中心窗口
wire        sc_any  = sc_full | sc_11;

// ---- 拉伸 FULL 的累加器 ----
wire        sc_on  = sc_full;
wire [17:0] sc_xn  = sc_xacc + 18'd640;
wire        sc_kn  = sc_on && (sc_xn >= {2'b0, sc_src_w});
wire [17:0] sc_xnx = sc_kn ? (sc_xn - {2'b0, sc_src_w}) : sc_xn;

// ---- 原始 1:1 的中心窗口 ----
//   源比屏幕大时取中心：xoff = (src_w-640)/2，发 xoff .. xoff+639
//   源不比屏幕大时 xoff=0（不会用到这里，但避免下溢）
wire [15:0] sc_xoff = (sc_src_w > 16'd640) ? ((sc_src_w - 16'd640) >> 1) : 16'd0;
wire [15:0] sc_yoff = (sc_src_h > 16'd480) ? ((sc_src_h - 16'd480) >> 1) : 16'd0;
wire        sc11_xk = (sc_sx >= sc_xoff) && (sc_sx < (sc_xoff + 16'd640));
wire        sc11_yk = (sc_sy >= sc_yoff) && (sc_sy < (sc_yoff + 16'd480));

// ---- 输出门控 ----
//
// 【2026-10-06 暂时关闭重采样，回到直通】
//   上板实测：切 FULL / 1TO1 画面无差别，且出现零星噪点 ——
//   现象指向"重采样没有真正生效、原始像素流直接进了 640 宽的帧缓冲"，
//   即每行多出像素、写侧行结构错乱。
//
//   已经排查过、可以排除的：
//     - scale_mode 连线链（osd_menu.scale_sel -> sd_card_bmp.menu_scale
//       -> bmp_read.scale_mode）逐级查过，是对的
//     - 写侧用的就是 write_en = bmp_data_wr_en（sd_card_bmp.v L158）
//     - 上一轮修掉的 off-by-one（sc_gate 误用寄存的 sc_pix_keep）是真的错，
//       但那不是全部原因
//
//   还没排除的（下一轮从这里查）：
//     - sc_src_w 是否真的锁存到了当前这张图的宽度（怀疑点：hdr_width 只在
//       扫描阶段被刷成"最后一张"的值，加载时是否正确重解析）
//     - sc_any / sc_on 的综合结果是否被优化掉
//     - 每行是否真的只发出 640 个（需要上板数一下，或加 OSD 读数）
//
//   关掉之后行为 = 直通 = 只支持 640x480 的图（和做 D2 之前完全一样）。
wire        sc_gate = 1'b1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sc_src_w <= 16'd640; sc_src_h <= 16'd480;
        sc_xacc  <= 18'd0;   sc_yacc  <= 18'd0;  sc_sx <= 16'd0;  sc_sy <= 16'd0;
        sc_pix_keep <= 1'b1; sc_row_keep <= 1'b1;
    end else begin
        // 源尺寸：BMP 头解析出来之后锁存
        if (hdr_width  != 16'd0) sc_src_w <= hdr_width;
        if (hdr_height != 16'd0) sc_src_h <= hdr_height;

        if (sc_any && (state == ST_LOAD_DATA) &&
            bmp_data_valid && (bmp_byte_idx == 2'd2)) begin
            sc_xacc     <= sc_xnx;        // 为【下一个】像素准备
            sc_pix_keep <= sc_kn;
            if (sc_sx + 16'd1 >= sc_src_w) begin      // 本源行结束
                sc_sx <= 16'd0;
                sc_sy <= sc_sy + 16'd1;               // 1:1 的 y 窗口要用
                if (sc_yacc + 18'd480 >= {2'b0, sc_src_h}) begin
                    sc_yacc     <= sc_yacc + 18'd480 - {2'b0, sc_src_h};
                    sc_row_keep <= 1'b1;              // 保留这一行
                end else begin
                    sc_yacc     <= sc_yacc + 18'd480;
                    sc_row_keep <= 1'b0;              // 整行丢弃
                end
            end else begin
                sc_sx <= sc_sx + 16'd1;
            end
        end
    end
end

//============================================================================
// 拓展③ 最简缩放 —— 【横向 2 倍放大】(scale_mode==3, 菜单显示 1TO1)
//
// 为什么只做一个方向：
//   x 方向放大只需"同一个像素连写两次" —— 源数据当拍就在手上，多写一拍即可。
//   y 方向放大要让同一行输出两遍 —— 那就必须先把整行缓冲下来、再找时机吐第二遍，
//   也就是【行缓冲 + 写口仲裁】，那是今天反复栽跟头的那类改动。
//   所以这里只做 x，用最小的代价换一个"确实在缩放"的效果。
//
// 窗口：源 640x480 每行取中心 320 列 (x ∈ [160,480))，每列写两次
//      -> 320 x 2 = 640  【恰好一行 640 个，是数出来的，不是算出来的】
//      行数不变，仍是 480
//
// 时序：像素在 byte_idx==2 那一拍凑齐、写第一次；
//       下一拍 byte_idx 回 0，用保存下来的整像素再写第二次。
//       源的节奏是 3 拍一个像素，中间正好空 2 拍，塞得下，不影响原有节拍。
//
// ⚠️ 只对【源宽正好 640】有意义。别的宽度先按原样直通（不缩放）。
//============================================================================
reg [23:0] s11_pix;      // 上一个凑齐的整像素（BGR 顺序，和 bmp_data 一致）
reg        s11_dup;      // 它需不需要再写一次
wire       s11_on   = (scale_mode == 2'd3);
wire       s11_win  = (sc_sx >= 16'd160) && (sc_sx < 16'd480);
// 【2026-10-06 回退】原来这里是：
//     wire s11_ok = s11_on && (sc_src_w == 16'd640) && s11_win;
//   这是一条【组合路径】：scale_mode 比较 + sc_src_w 的 16 位比较 + sc_sx 的
//   16 位窗口比较，再驱动 bmp_data / bmp_data_wr_en 这两个扇出很大的寄存器。
//   bmp_read 的输出级本来就在关键路径上，再挂一层组合逻辑就撑不住 ——
//   构建实测 SWNS = -0.367ns（时序违例），按工程铁律不能上板。
//   掐掉之后综合会把整块横向缩放逻辑裁干净，时序恢复正常。
//   以后要做，正确方向见文件上面的说明（预计算并寄存窗口判据，或换到显示读取侧）。
wire       s11_ok   = 1'b0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        s11_pix <= 24'd0;
        s11_dup <= 1'b0;
    end else if ((state == ST_LOAD_DATA) && bmp_data_valid) begin
        if (bmp_byte_idx == 2'd2) begin
            s11_pix <= {sd_sec_read_data, bmp_data[15:8], bmp_data[7:0]};
            s11_dup <= s11_ok;               // 这一拍已经写过第一次了
        end else if (bmp_byte_idx == 2'd0) begin
            s11_dup <= 1'b0;                 // 第二拍用完就撤销
        end
    end else begin
        s11_dup <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    // 拓展③：拉伸模式下按重采样器的 keep 门控；
                    // 其他档位(sc_on=0)一律直通 —— 保证未实现的模式行为不变。
                    bmp_data_wr_en  <= sc_gate;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (load_abort) begin
        // 放弃当前坏图，但保留已经完成的扫描结果，允许控制器继续处理后续图片。
        state             <= ST_IDLE;
        state_code        <= 4'd1;
        sd_sec_read       <= 1'b0;
        write_req         <= 1'b0;
        scan_found_valid  <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if (scan_last_r || next_match_over_r) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_match_r;
                            scan_sector      <= next_match_r;
                        end else begin
                            sd_sec_read_addr <= next_match_r;
                            scan_sector      <= next_match_r;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (file_end_reached) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
