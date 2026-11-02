
module top(
    input                       clk,
    input                       rst_n,          // A2 = KEY_1：手动下一张
    input                       key1,           // B2 = KEY_2：自动播放 开/关
    input                       key2,           // C1 = KEY_4：轮播周期
    input                       key3,           // B1 = KEY_3：IO 测试版新增（此前从未声明）
    input  [3:0]                dip,            // C8/C7/C6/C5 = SWKEY_1..4：IO 测试版新增

	output [7:0]                seg_sel,        // IO 测试版：由 6 位扩到 8 位
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
localparam [ADDR_BITS-1:0] FRAME_PIXELS = 21'd307200;   // 640*480
localparam [ADDR_BITS-1:0] BUF0_ADDR    = 21'd0;
localparam [ADDR_BITS-1:0] BUF1_ADDR    = FRAME_PIXELS;
localparam [ADDR_BITS-1:0] BUF2_ADDR    = FRAME_PIXELS * 2;
localparam [ADDR_BITS-1:0] BUF3_ADDR    = FRAME_PIXELS * 3;
// 【2026-10-07 第5块帧缓冲】第 5 块基址 = 307200*4 = 1228800。
// 容量核算：EG_PHY_SDRAM_2M_32 = 2M x 32bit = 2,097,152 words，
//           5 块占用 1,536,000 words = 73.2%，最高地址 1,535,999 < 2,097,152 ✓
localparam [ADDR_BITS-1:0] BUF4_ADDR    = FRAME_PIXELS * 4;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] tide_video;
wire        display_valid;
reg  [1:0]  display_valid_sync;
wire        display_valid_video;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire [1:0]  period_sel;        // 轮播周期档位 0=1s 1=3s 2=5s
wire [6:0]  seg_data_period;
reg  [3:0]  period_digit;      // 档位对应的数码管数字 1/3/5
wire [7:0]  fade_alpha;        // 转场亮度（sd_card_clk 域产生，视频域使用）
wire [2:0]  dbg_found;         // 调试观测：扫描到几张
wire [2:0]  dbg_cached;        // 调试观测：加载成功几张
wire [2:0]  song_no;
wire [2:0]  song_total;
wire        menu_on;
wire [3:0]  menu_item;           // 菜单当前项 0..8
wire [2:0]  menu_trans;          // 转场方式 0..4（拓展②）
wire [1:0]  menu_scale;          // 缩放模式 0..3（拓展③）
wire        render_zoom;         // board-side 2x zoom applied under transition cover
wire        menu_info;           // 分辨率/缩放比 OSD 开关（拓展④）
wire        menu_music;          // 【2026-10-06】音乐开/关
wire [2:0]  menu_vol;            // 【2026-10-06】音量档位 0..6
wire [1:0]  menu_brightness;     // 亮度档位 25/50/75/100%
wire [2:0]  menu_contrast;       // 对比度档位 50/75/90/100/110/125/150%
wire        idle_dim;            // 30 秒无操作自动降亮度
wire [15:0] bmp_hdr_w;           // BMP 头里的实际宽高（信息栏显示）
wire [15:0] bmp_hdr_h;
wire        boot_skip;           // 开场动画跳过（任意键，sd_card_clk 域的电平）
wire [2:0]  dbg_preload;       // 调试观测：预加载源序号
wire        auto_play_en;      // 自动轮播是否开启（v3.1：数码管显示 A/E 用）

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
// 【2026-10-07 第5块帧缓冲 · 步骤3】显示索引加宽到 3 位：0..3 = 4 张原图，4 = 推近版。
// 为什么不能只加一位"use_addr4"：轮播要走遍 0..4，"下一张"的逻辑需要 3 位。
// 好在这个信号只有 3 个消费点，加宽比额外维护一位更不容易出错。
wire [2:0]  disp_buf_idx;
wire        write_use_addr4;
// video_clk 域同步后的显示索引（低 2 位给 frame_fifo 的基址选择，
// 最高位给 read_use_addr4）—— 两者来自【同一个寄存器】，天然同拍。
reg  [2:0]  disp_idx_sync1;
reg  [2:0]  disp_idx_sync2;
wire [2:0]  disp_idx_video = disp_idx_sync2;
wire        disp_use_addr4 = disp_idx_video[2];

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire [2:0] transition_mode;
wire [7:0] transition_alpha_gray;
wire de_0;
wire de_img_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

// HDMI 音频链路：独立音频主时钟、I2S 测试音和 ACR 时钟恢复
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_sample_tick;
wire signed [15:0] music_sample;
// 【2026-10-06】音量：7 档，系数 k = vol_sel+1（1/8 .. 7/8）。
//   用【移位】实现除 8，乘 k 只有 3 位宽 —— 不会引入 MULT18 那种大乘法器，
//   所以对那条本来就紧的时序路径没有影响。
// 7 档音量，全部用【算术右移】实现 —— 不引入乘法器，也不会碰那条本来就紧的时序路径。
//   档位 0..6 对应：静音 / 1/16 / 1/8 / 1/4 / 1/2 / 5/8 / 原样
wire signed [15:0] music_vol_q =
       (menu_vol == 3'd6) ?  music_sample :
       (menu_vol == 3'd5) ? ((music_sample >>> 1) + (music_sample >>> 3)) :
       (menu_vol == 3'd4) ?  (music_sample >>> 1) :
       (menu_vol == 3'd3) ?  (music_sample >>> 2) :
       (menu_vol == 3'd2) ?  (music_sample >>> 3) :
       (menu_vol == 3'd1) ?  (music_sample >>> 4) : 16'sd0;
wire [7:0] music_envelope;
// 三频带包络（audio_mclk 域）—— 驱动屏幕三层视差波浪
wire [7:0] music_env_low;
wire [7:0] music_env_mid;
wire [7:0] music_env_high;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;
wire        audio_rst;
wire        audio_video_rst;
wire        audio_reset_async;
reg  [1:0]  audio_rst_sync = 2'b11;
reg  [1:0]  audio_video_rst_sync = 2'b11;
reg  [1:0]  scene_idx_sync1;
reg  [1:0]  scene_idx_sync2;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// 50MHz -> 约12.3MHz 音频主时钟（64fs I2S，接近48kHz采样率）
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// 音频 PLL 未锁定或系统复位时立即置位；分别在两个目的时钟域同步释放。
// 这样异步状态不会直接撤销各模块寄存器的复位，避免 recovery 违例。
assign audio_reset_async = rst_all | ~audio_pll_lock;

always @(posedge audio_mclk or posedge audio_reset_async) begin
    if (audio_reset_async)
        audio_rst_sync <= 2'b11;
    else
        audio_rst_sync <= {audio_rst_sync[0], 1'b0};
end

always @(posedge video_clk or posedge audio_reset_async) begin
    if (audio_reset_async)
        audio_video_rst_sync <= 2'b11;
    else
        audio_video_rst_sync <= {audio_video_rst_sync[0], 1'b0};
end

assign audio_rst       = audio_rst_sync[1];
assign audio_video_rst = audio_video_rst_sync[1];

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all)
        display_valid_sync <= 2'b00;
    else
        display_valid_sync <= {display_valid_sync[0], display_valid};
end

assign display_valid_video = display_valid_sync[1];

// 【2026-10-07 步骤3】显示索引跨到 video_clk 域。
// 整个 3 位量【一起】打两拍 —— 低 2 位（基址选择）和最高位（第5块选中）
// 因此永远同拍。若各自同步，边界上会出现"索引选了第5块、use_addr4 还是旧值"
// 或者反过来 —— 那就是交接文档 §3.6 那类"读一块、按另一块处理"的错误。
// sd_card_clk 与 video_clk 无相位关系，所以这两拍是必需的。
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        disp_idx_sync1 <= 3'd0;
        disp_idx_sync2 <= 3'd0;
    end else begin
        disp_idx_sync1 <= disp_buf_idx;
        disp_idx_sync2 <= disp_idx_sync1;
    end
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        scene_idx_sync1 <= 2'd0;
        scene_idx_sync2 <= 2'd0;
    end else begin
        // 【2026-10-06】场景名跟着【图片】走，不跟着【缓冲号】走。
        //   缩放开时缓冲1 装的是图1 的推近版，但名字/太阳月亮星星都是按缓冲号配的，
        //   会显示成"晴海"+白天的太阳。这里把缩放开时的场景索引钉成 0（= 晨潮），
        //   于是推近版也叫「晨潮」，日月星也和原图一致 —— 它就是同一张图，只是推近了。
        // 【2026-10-07 步骤3】取【同步后】的 3 位索引的低 2 位。
        //   块4（推近版）低 2 位是 0 -> 场景索引自然算成 0（晨潮），
        //   和原图一致 —— 不需要再靠 menu_scale[0] 去钉，但结论相同。
        scene_idx_sync1 <= disp_idx_video[1:0];
        scene_idx_sync2 <= scene_idx_sync1;
    end
end

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（最多四帧预加载） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    // 【2026-10-06】原来这里是 3'd4 —— 它【覆盖】了 sd_card_bmp 里的参数默认值，
    // 所以只改那边没用，扫描永远只找 4 张、img_sector4 永远是 0，
    // 切缩放时"重载"去读扇区 0（不是 BMP）-> header_match 失败 -> 画面保持原样。
    // 这就是"缩放开关能切、画面不推近"的根因。
    .SCAN_TARGET_COUNT (3'd4),
    .AUTO_PERIOD_DEF   (2'd1)          // 默认 3 秒
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (rst_n),        // A2 = KEY_1：手动切下一张
    .key_auto          (key1),         // B2 = KEY_2：启停自动轮播
    .key_period        (key3),         // B1 = KEY_3：轮播周期 1/3/5 秒
                                       //   原来这里错接成 key2(C1=KEY_4)，
                                       //   导致 B1 上的 K3 完全没接线、按了没反应
    .key_song          (key2),         // C1 = KEY_4：切下一首歌
                                       //   （菜单做好后 K4 改成"进出菜单"，
                                       //     切歌移进菜单里的"歌曲"项）
    .song_no           (song_no),
    .song_total_o      (song_total),
    .menu_on_o         (menu_on),
    .menu_item_o       (menu_item),
    .menu_trans_o      (menu_trans),
    .menu_scale_o      (menu_scale),
    .render_zoom_o     (render_zoom),
    .menu_info_o       (menu_info),
    .menu_music_o      (menu_music),
    .menu_vol_o        (menu_vol),
    .menu_brightness_o (menu_brightness),
    .menu_contrast_o   (menu_contrast),
    .idle_dim_o        (idle_dim),
    .bmp_hdr_w_o       (bmp_hdr_w),
    .bmp_hdr_h_o       (bmp_hdr_h),
    .boot_skip_o       (boot_skip),
    .state_code        (state_code),
    .period_sel_o      (period_sel),
    .fade_alpha        (fade_alpha),
    .transition_mode       (transition_mode),
    .transition_alpha_gray (transition_alpha_gray),
    .dbg_found_o       (dbg_found),
    .dbg_cached_o      (dbg_cached),
    .dbg_preload_o     (dbg_preload),
    .auto_play_o       (auto_play_en),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .write_use_addr4   (write_use_addr4),
    .disp_buf_idx      (disp_buf_idx[1:0]),
    .disp_use_addr4    (disp_buf_idx[2]),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .audio_clk         (audio_mclk),
    .audio_rst         (audio_rst),
    .audio_sample_tick (audio_sample_tick),
    .audio_sample      (music_sample),   // 这是流的【输出】，不能改动
    .audio_envelope    (music_envelope),
    .audio_env_low     (music_env_low),
    .audio_env_mid     (music_env_mid),
    .audio_env_high    (music_env_high)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

// 轮播周期档位 -> 数字 1/3/5
always @(*) begin
    case (period_sel)
        2'd0:    period_digit = 4'd1;
        2'd1:    period_digit = 4'd3;
        default: period_digit = 4'd5;
    endcase
end

seg_decoder seg_decoder_period(
    .bin_data          (period_digit),
    .seg_data          (seg_data_period)
);

// ===================== 数码管 / 双色 LED 双模式 =====================
// 板上 SW6 物理决定这 16 根线通向数码管还是双色 LED（二者互斥）。
// FPGA 看不见 SW6 的位置，所以用【拨码 SW4 (dip[3])】告诉它当前在哪一边 ——
// 拨 SW6 的时候顺手把 SW4 拨到对应位置即可：
//     dip[3] = 0  ->  数码管模式（8 位扫描）
//     dip[3] = 1  ->  LED 模式（两相扫描：红行 / 绿行）
//
// ---- 已由 IO 测试版 + LED 测试版实测确认的拓扑 ----
//   SEL 是 8 根"公共极"线，DIG 是 8 根"独立"线，全部低有效。
//     数码管 ：SEL0..SEL7 = 第 1..8 位（左 -> 右）
//              DIG0..DIG7 = a, b, c, d, e, f, g, dp
//     双色LED：SEL0 = 红行，SEL1 = 绿行（SEL2..7 这 8 个灯不用）
//              DIG0..DIG7 = 位置 0..7（左 -> 右）
//   注意 SEL 编号与 seg_sel 位序错位：物理 SEL n -> seg_sel 位 (n+6) mod 8
//     SEL0->bit6(F16) SEL1->bit7(E16) SEL2->bit0(E12) SEL3->bit1(E10)
//     SEL4->bit2(C13) SEL5->bit3(F10) SEL6->bit4(E11) SEL7->bit5(D11)
//   DIG 编号与 seg_data 位序一致：DIG n -> seg_data 位 n
//
// ---- 为什么整块逻辑放在 sd_card_clk 域（而不是 clk）----
//   1) 要显示的 disp_buf_idx / state_code / dbg_cached / period_sel / auto_play_en
//      全部产生在 sd_card_clk 域，同域读取不需要任何跨域同步；
//   2) 音频包络 music_envelope 在 audio_mclk 域，而 timing.sdc 里
//      audio_mclk 与 sd_card_clk 已经是 asynchronous 时钟组，
//      两级同步器采过去即可，不需要新增约束。
//   如果放在 clk 域，两条都会变成未约束的跨域路径
//   （实测：audio_mclk -> clk 会产生 8 条 setup 违例，最差 -1.404ns，
//     因为 timing.sdc 的异步组里漏了 clk）。

// 音频包络跨到 sd_card_clk 域（慢变量显示值，两级同步足够）
reg [7:0] env_sync1, env_sync2;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        env_sync1 <= 8'd0;
        env_sync2 <= 8'd0;
    end else begin
        env_sync1 <= music_envelope;
        env_sync2 <= env_sync1;
    end
end
wire [7:0] env_val = env_sync2;

// 包络 0..255 -> 0..99 显示值，再拆成十位/个位。
// 除以 10 用乘倒数实现：6554 / 65536 ≈ 0.100006，对 0..99 全范围精确。
// 三级流水：sd_card_clk 是 10ns，两个乘法器串在一拍里过不去。
reg [7:0] env99_s1;      // 第1级：0..255 -> 0..99
reg [7:0] env99_s2;      // 第2级：把 s1 再延一拍，给个位计算配对用
reg [3:0] env_tens_r;    // 第2级：十位 0..9
reg [7:0] env_ones_r;    // 第3级：个位 0..9
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        env99_s1   <= 8'd0;
        env99_s2   <= 8'd0;
        env_tens_r <= 4'd0;
        env_ones_r <= 8'd0;
    end else begin
        env99_s1   <= (env_val * 16'd100) >> 8;
        env99_s2   <= env99_s1;
        env_tens_r <= (env99_s1 * 16'd6554) >> 16;
        env_ones_r <= env99_s2 - (env_tens_r * 8'd10);
    end
end
wire [3:0] env_tens = env_tens_r;
wire [3:0] env_ones = env_ones_r[3:0];

// ---------- 模式 A：数码管 8 位扫描 ----------
// 扫描节奏与原来一致：200Hz 帧率 × 8 位。sd_card_clk = 100MHz -> 62500 拍/位
localparam [15:0] SEG_SCAN_DIV = 16'd62499;

reg [15:0] seg_timer;
reg [2:0]  seg_sc;                       // 物理位序号 0..7（0 = 最左）
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        seg_timer <= 16'd0;
        seg_sc    <= 3'd0;
    end else if (seg_timer >= SEG_SCAN_DIV) begin
        seg_timer <= 16'd0;
        seg_sc    <= seg_sc + 3'd1;      // 3 位自然回绕 0..7
    end else begin
        seg_timer <= seg_timer + 16'd1;
    end
end

// 8 位字段规划（左 -> 右）
//   位1 图片编号1-4 | 位2 模式A/E | 位3 周期1/3/5 | 位4 包络十位
//   位5 包络个位    | 位6 bank    | 位7 BMP状态码 | 位8 已加载张数
wire [3:0] fld_img  = {2'b00, disp_buf_idx} + 4'd1;
wire [3:0] fld_mode = auto_play_en ? 4'hA : 4'hE;         // A = AUTO，E = 手动
wire [3:0] fld_per  = (period_sel == 2'd0) ? 4'd1 :
                      (period_sel == 2'd1) ? 4'd3 : 4'd5;
// ===================== 数码管 8 位字段分配 =====================
//  位1 图片号    位2 熄灭    位3 模式A/E   位4 周期1/3/5
//  位5 熄灭      位6 扫描到几张   位7 熄灭   位8 已加载
//
// 熄灭位不是浪费 —— 它们把 8 位切成四组，留白比塞满更清楚：
//      ┌───┐   ┌───┬───┐   ┌───┐   ┌───┐
//      │ 2 │ _ │ A │ 3 │ _ │ 4 │ _ │ 4 │
//      └───┘   └───┴───┘   └───┘   └───┘
//       图片号   模式+周期   扫描到   已加载
//
// 去掉的两位：
//   音频包络（原 4/5 位）—— LED 灯带和屏幕潮汐线已经在表达同一件事，重复
//   状态码  （原 7 位）  —— 纯内部状态，正常运行在 0/1 间跳，观众无法理解
reg  [3:0] fld_cur;
always @(*) begin
    case (seg_sc)
        3'd0:    fld_cur = fld_img;
        3'd1:    fld_cur = 4'd0;                    // 熄灭（分组留白）
        3'd2:    fld_cur = fld_mode;                // A = 自动 / E = 手动
        3'd3:    fld_cur = fld_per;                 // 1 / 3 / 5 秒
        3'd4:    fld_cur = {1'b0, song_no};         // 当前歌曲号 1..5
                                                     //   【临时占用】原规格是"熄灭"。
                                                     //   为了这一轮能一眼确认切歌成不成功，
                                                     //   先借位 5 显示歌号；菜单做好后
                                                     //   会移进菜单的"歌曲"项，这里还原成熄灭。
        3'd5:    fld_cur = {2'b00, dbg_found};      // 扫描到几张
        3'd6:    fld_cur = 4'd0;                    // 熄灭（分组留白）
        default: fld_cur = {1'b0, dbg_cached};      // 已加载几张
    endcase
end

// 熄灭位：段码全部关闭（低有效，全 1 = 全灭）
//   位 5 现在显示歌号，所以从熄灭名单里去掉
wire fld_blank = (seg_sc == 3'd1) || (seg_sc == 3'd6);

wire [6:0] seg_sc_pat;
seg_decoder seg_decoder_sc(
    .bin_data (fld_cur),
    .seg_data (seg_sc_pat)
);
wire [6:0] seg_sc_show = fld_blank ? 7'b111_1111 : seg_sc_pat;

wire [2:0] seg_sc_bit   = seg_sc + 3'd6;             // 物理 SEL n -> seg_sel 位 (n+6)%8
wire [7:0] seg_sel_dig  = ~(8'b0000_0001 << seg_sc_bit);
// seg_data_dig 在下面"小数点电平表"处生成 —— 最高位 dp 用作第二组潮汐灯带

// ===================== 潮汐灯带 =====================
// 意象：8 个位置 = 一段海面的 8 个刻度。柱长 = 潮位，亮度波 = 水的流动。
//
// 色标由【位置】决定，不是由电平决定 —— 这样一眼就能看出"涨到哪了"：
//     位置   1    2    3    4    5    6    7    8
//     色标   绿   绿   绿   琥珀 琥珀 橙   红   红
//           └─ 低潮 ─┘  └─ 中潮 ─┘  └── 高潮 ──┘
//   绿 = 浅滩；琥珀 = 潮间带（红+绿同时导通，肉眼混合成黄）；红 = 高潮线。
//   和画面上的潮线是同一套语义。
//
// 亮度调制：列扫描本来就给了我们一个时间窗口 —— 在一列的 250us 里把灯只开一部分
// 时间，肉眼看到的就是不同亮度。每个灯 8 档（duty 0..8），于是灯带上可以叠一道
// 亮度波，看起来像水在流。波速跟电平：安静时几乎不动，响起来跑得快。
//
// 电平平滑：tide_pcm_stream 的包络每 768 个采样点才刷新一次
// （48000 / 768 = 62.5Hz），直接拿来显示会一跳一跳。做一个标准 VU 表的
// attack/release：升高立即跟上，回落缓慢。
reg [7:0]  level_disp;
reg [17:0] decay_cnt;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        level_disp <= 8'd0;
        decay_cnt  <= 18'd0;
    end else if (env_val >= level_disp) begin
        level_disp <= env_val;                          // attack：立即跟上
        decay_cnt  <= 18'd0;
    end else if (decay_cnt >= 18'd150_000) begin        // release：1.5ms 落一档
        decay_cnt  <= 18'd0;
        level_disp <= level_disp - 8'd1;
    end else begin
        decay_cnt <= decay_cnt + 18'd1;
    end
end

// 平滑后的电平 0..255 -> 潮位柱长 0..8（末档用低 5 位是否非零补齐，避免满值只亮 7 颗）
wire [3:0] bar_len = {1'b0, level_disp[7:5]} + {3'b000, (|level_disp[4:0])};
wire [2:0] bar_top = (bar_len[3:0] == 4'd8) ? 3'd7 : bar_len[2:0];

// 峰值保持：新高立刻跟上，之后每 0.1 秒回落一档（sd_card_clk 100MHz * 0.1s = 1e7 拍）
reg [2:0]  peak_pos;
reg [23:0] peak_hold;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        peak_pos  <= 3'd0;
        peak_hold <= 24'd0;
    end else if (bar_top >= peak_pos) begin
        peak_pos  <= bar_top;
        peak_hold <= 24'd0;
    end else if (peak_hold >= 24'd10_000_000) begin
        peak_hold <= 24'd0;
        if (peak_pos != 3'd0) peak_pos <= peak_pos - 3'd1;
    end else begin
        peak_hold <= peak_hold + 24'd1;
    end
end
// ---- 慢速时基：峰值闪烁 + 静音呼吸 + 自检扫描，共用一个计数器 ----
// 自检模式（SW2 = dip[1] = 1）：不依赖音频，潮位 0->7->0 自动来回。
// 用途：把"LED 驱动代码有问题"和"音频包络恒为 0"两种情况区分开。
//   自检能扫、音乐不动 -> LED 驱动没问题，是音频包络没上来（PCM 流没跑）
//   自检也不动         -> LED 驱动或模式选择本身有问题
reg [26:0] slow_cnt;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) slow_cnt <= 27'd0;
    else         slow_cnt <= slow_cnt + 27'd1;
end
wire       blink_on = slow_cnt[25];                            // 约 1.5Hz
wire [2:0] br_idx   = slow_cnt[24:22];
wire [3:0] breathe_duty = slow_cnt[25] ? (4'd7 - {1'b0, br_idx})   // 三角波呼吸
                                       : {1'b0, br_idx};
wire [2:0] st_idx = slow_cnt[25:23];
wire [3:0] st_len = slow_cnt[26] ? (4'd7 - {1'b0, st_idx}) : {1'b0, st_idx};

// 显示用的潮位 / 峰值（自检时被接管）
wire [3:0] disp_len  = dip[1] ? st_len  : bar_len;
wire [2:0] disp_peak = dip[1] ? st_idx  : peak_pos;
wire       disp_idle = dip[1] ? (st_len == 4'd0) : (bar_len == 4'd0);
wire       peak_vis  = dip[1] ? 1'b1 : blink_on;   // 自检时红点常亮，便于观察

// ---- 流动亮度波的相位推进（速度跟电平）----
// 用相位累加器（DDS）而不是"27 位计数器 + 27 位比较器"：
// 每次 tick 往累加器里加一个跟电平成正比的增量，溢出就推进一格相位。
// 这样只要 14 位 tick 计数器 + 17 位加法器，比原来的方案小很多。
//   静音：约 0.45s 走一格（8 格一圈 3.6 秒）
//   满电平：约 0.20s 走一格（一圈 1.6 秒）
reg [13:0] wave_tick;
reg [16:0] wave_acc;
reg [2:0]  wave_ph;
wire [16:0] wave_sum = wave_acc + 17'd24 + {12'd0, level_disp[7:3]};
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        wave_tick <= 14'd0;
        wave_acc  <= 17'd0;
        wave_ph   <= 3'd0;
    end else if (wave_tick >= 14'd16383) begin      // 16384 拍 = 164us
        wave_tick <= 14'd0;
        wave_acc  <= {1'b0, wave_sum[15:0]};        // 保留余数
        if (wave_sum[16]) wave_ph <= wave_ph + 3'd1;   // 3 位自然回绕 0..7
    end else begin
        wave_tick <= wave_tick + 14'd1;
    end
end

// ---- 逐列扫描 + 列内 8 档 PWM ----
// 为什么不用"按行扫描"：行的公共极一根线要供整行 LED 的电流。整条柱子亮时
// 一行 8 颗灯分掉 8mA 驱动，每颗只剩约 1mA；而红点独占一行能拿全额 2.8mA。
// 结果就是"柱子越长越暗、红点特别亮"——亮度不恒定。
// 逐列扫描后任何时刻每根行线最多带 1 颗灯（2.8mA，远在 8mA 之内），亮度一致。
// 帧率：8 列 × 8 子档 × 3125 拍 = 200000 拍 = 2ms = 500Hz
reg [11:0] pwm_cnt;
reg [5:0]  pwm_idx;                     // {col[2:0], sub[2:0]}，共 64 个时隙
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        pwm_cnt <= 12'd0;
        pwm_idx <= 6'd0;
    end else if (pwm_cnt >= 12'd3124) begin
        pwm_cnt <= 12'd0;
        pwm_idx <= pwm_idx + 6'd1;      // 6 位自然回绕
    end else begin
        pwm_cnt <= pwm_cnt + 12'd1;
    end
end
wire [2:0] led_col = pwm_idx[5:3];
wire [2:0] led_sub = pwm_idx[2:0];

// ===================== LED 音乐律动：照搬 v31 =====================
// v31（haichao_v31_2026-10-02.bit，BCFE1C2D）的那一版用户认可，原样搬回。
//
// 做法：两相行扫描，红行 / 绿行轮流导通（各 0.25ms，整周期 2kHz）
//   相位 0：只开红行，DIG = ~红掩码（只有峰值那一列低）  -> 一个红点
//   相位 1：只开绿行，DIG = ~绿掩码（柱子那几列低）      -> 绿色电平柱
//
// 电平平滑照旧：包络每 768 采样（62.5Hz）才更新一次，升高立即跟上、回落缓慢。
// 柱子长度实时跟随，不做任何上升限速。
wire [7:0] v31_green_mask = ~(8'hFF << disp_len);
wire [7:0] v31_red_mask   = (disp_len != 4'd0) ? (8'b0000_0001 << disp_peak) : 8'd0;

reg [14:0] led_phase_cnt;
reg        led_phase;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        led_phase_cnt <= 15'd0;
        led_phase     <= 1'b0;
    end else if (led_phase_cnt >= 15'd24999) begin   // 每相 0.25ms -> 2kHz
        led_phase_cnt <= 15'd0;
        led_phase     <= ~led_phase;
    end else begin
        led_phase_cnt <= led_phase_cnt + 15'd1;
    end
end

// SEL0 -> seg_sel[6]，SEL1 -> seg_sel[7]（物理 SEL n 对应位 (n+6)%8）
// 红/绿行到底是 SEL0 还是 SEL1，两次实测结论不一致，所以用 dip[2] 现场对调，
// 不用重新构建：dip[2]=0 -> SEL0 红 / SEL1 绿；dip[2]=1 -> 对调。
wire [7:0] led_sel_red = dip[2] ? 8'b0111_1111 : 8'b1011_1111;
wire [7:0] led_sel_grn = dip[2] ? 8'b1011_1111 : 8'b0111_1111;

// 动态(SW4=1)：v31 的律动 —— 绿柱 + 红点，两相行扫描
wire [7:0] v31_sel_mux  = led_phase ? led_sel_grn : led_sel_red;
wire [7:0] v31_data_mux = led_phase ? ~v31_green_mask : ~v31_red_mask;

// ===================== 小数点潮汐灯带 =====================
// 8 位数码管每一位都有一个小数点（DIG7），8 个连起来正好是一排 8 格。
// 数字照常显示状态，小数点这一排单独做潮汐灯带 —— 这样 DIG 模式下也能看到音乐律动。
// 扫描到某一位时，在那一位的窗口里对 dp 做 PWM 调光，不影响该位的数字段。
reg [12:0] dp_cnt;
reg [2:0]  dp_sub;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        dp_cnt <= 13'd0;
        dp_sub <= 3'd0;
    end else if (dp_cnt >= 13'd7811) begin      // 7812 拍 = 78us -> 12.8kHz
        dp_cnt <= 13'd0;
        dp_sub <= dp_sub + 3'd1;
    end else begin
        dp_cnt <= dp_cnt + 13'd1;
    end
end

wire [2:0] dp_dw = seg_sc - wave_ph;
wire [3:0] dp_wave_duty = (dp_dw == 3'd0)                  ? 4'd8 :
                          (dp_dw == 3'd1 || dp_dw == 3'd7) ? 4'd6 : 4'd4;
wire dp_in_bar    = ({1'b0, seg_sc} < disp_len);
wire dp_peak_here = (seg_sc == disp_peak);

// ===================== 拨码分配（v3.1-final）=====================
//   SW1 = dip[0]  设备选择：0 = 数码管，1 = 双色 LED   ← 必须与 SW6 同步拨
//   SW2 = dip[1]  LED 自检：1 = 自动扫描自检，0 = 跟音乐
//   SW3 = dip[2]  红/绿行对调：0 = SEL0 红，1 = 对调
//   SW4 = dip[3]  静态 / 动态：0 = 静态，1 = 动态
//
// 为什么需要 SW1：SW6 只切换【显示器件公共极的供电】（DIGVCC / LEDVCC），
// 不切数据线 —— 这 16 根线永远同时接着两种器件。而且 LED 的红/绿行正是
// SEL0/SEL1，也就是数码管的位1/位2。所以 FPGA 必须被告知"现在哪一边通电"，
// 否则只要送 LED 图案，数码管的位1/位2 就必然跟着乱跳。
//
// 四种组合（SW6 要与 SW1 对齐）：
//   SW1=0 SW4=0  SW6->DIGVCC   数码管：只有 8 位数字
//   SW1=0 SW4=1  SW6->DIGVCC   数码管：数字全灭，只有小数点律动
//   SW1=1 SW4=0  SW6->LEDVCC   双色 LED：全红
//   SW1=1 SW4=1  SW6->LEDVCC   双色 LED：潮汐律动
wire dev_led = dip[0];      // 1 = 双色 LED，0 = 数码管
wire dyn     = dip[3];      // 1 = 动态（律动），0 = 静态

wire [3:0] dp_duty = !dyn                                    ? 4'd0
                   : (dp_peak_here && peak_vis && !disp_idle) ? 4'd8
                   : (dp_in_bar)                              ? dp_wave_duty
                   : (disp_idle && seg_sc == 3'd0)            ? breathe_duty
                   :                                          4'd0;
wire dp_on = ({1'b0, dp_sub} < dp_duty);
// 数码管侧的静态/动态：
//   静态(0) -> 送段码，dp 恒灭        -> 只有 8 位数字
//   动态(1) -> 段码全部关掉，只留 dp  -> 只有小数点那一排律动
wire [7:0] seg_data_dig = dyn ? {~dp_on, 7'b111_1111}   // 只有小数点
                              : {1'b1,    seg_sc_show};  // 只有数字（含分组留白的熄灭位）

// LED 侧的静态/动态：
//   静态(0) -> 红行常开 + 逐列扫描，每列都点红灯 -> 全红
//              （逐列而不是一次全亮：一次全亮会让红行一根线带 8 颗灯，
//                8mA 驱动被分掉，每颗只剩约 1mA，亮度会塌）
//   动态(1) -> v31 的音乐律动（绿柱 + 红点，两相行扫描）
wire [7:0] led_sel_out = dyn ? v31_sel_mux  : led_sel_red;
wire [7:0] led_dat_out = dyn ? v31_data_mux : ~(8'b0000_0001 << led_col);

// ---------- 输出选择（由 SW1 决定，须与 SW6 对齐）----------
assign seg_sel  = dev_led ? led_sel_out : seg_sel_dig;
assign seg_data = dev_led ? led_dat_out : seg_data_dig;

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .de_img            (de_img_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .de_img            (de_img_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid_video ? vout_data_raw : 24'd0;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (display_valid_video && video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_4       (BUF4_ADDR),
    .read_use_addr4    (disp_use_addr4),
    .zoom_2x           (render_zoom),
    .read_addr_index   (disp_idx_video[1:0]),
    .read_len          (FRAME_PIXELS),
    .read_en           (display_valid_video && video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_4      (BUF4_ADDR),
    .write_use_addr4   (write_use_addr4),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== HDMI 音频：TF 卡 PCM =====================
hdmi_audio_pcm_i2s_64fs u_hdmi_audio_pcm_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (audio_rst),
    .I_sample    (music_vol_q),   // 【2026-10-06】走音量
    .O_sample_tick(audio_sample_tick),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

// 2.0：直接跨时钟域把 PCM 样本送入 HDMI 音频包，绕开 I2S 回环采样误差。
pcm_hdmi_bridge u_pcm_hdmi_bridge(
    .audio_clk   (audio_mclk),
    .audio_rst   (audio_rst),
    // 【2026-10-06】音乐开关：关掉采样节拍 -> PCM 流停住 -> 输出停在最后一个样点。
    //   直流电平不发声（只会有一瞬间的偏移），听感上就是"暂停"。
    .sample_tick (audio_sample_tick & menu_music),
    .sample      (music_vol_q),   // 【2026-10-06】这才是真正进 HDMI 音频包的那一路，音量必须接这里
    .video_clk   (video_clk),
    .video_rst   (audio_video_rst),
    .audio_valid (audio_valid),
    .audio_left  (audio_left_data),
    .audio_right (audio_right_data)
);

tide_overlay u_tide_overlay(
    .clk        (video_clk),
    .rst        (rst_all),
    .vs         (vs),
    .de         (de),
    .active     (display_valid_video),
    .audio_level(music_envelope),
    .band_low   (music_env_low),
    .band_mid   (music_env_mid),
    .band_high  (music_env_high),
    .scene_index(scene_idx_sync2),
    // 文字 OSD 需要的播放状态
    .osd_idx    (disp_buf_idx),
    .osd_total  (dbg_cached),
    .osd_auto   (auto_play_en),
    .osd_period (period_sel),
    .osd_song       (song_no),
    .osd_song_total (song_total),
    .menu_on        (menu_on),
    .menu_item      (menu_item),
    .menu_trans     (menu_trans),
    .menu_scale     (menu_scale),
    .menu_info      (menu_info),
    .menu_music     (menu_music),
    .menu_vol       (menu_vol),
    .menu_brightness(menu_brightness),
    .menu_contrast  (menu_contrast),
    .idle_dim       (idle_dim),
    .bmp_hdr_w      (bmp_hdr_w),
    .bmp_hdr_h      (bmp_hdr_h),
    // 开场动画：任意键跳过（动画期间左下角还有署名，由 boot_active 门控）
    .boot_skip  (boot_skip),
    // 开场动画要等显示链路：edid_valid = HDMI core 读到了显示器的 EDID，
    // 也就是"对面在、DDC 握手完成了"。FPGA 看不到显示器什么时候锁住信号，
    // 所以 boot_anim 里再补一段可调延时。
    .link_up    (edid_valid),
    // 诊断：SW2 拨到自检档 -> 旁路整个叠加层，只看原始画面。
    // 用来区分"SDRAM/帧缓存坏了"和"叠加层引入噪点"。
    .bypass     (dip[1]),
    .transition_mode       (transition_mode),
    .transition_alpha_gray (transition_alpha_gray),
    // 屏幕调试面板已彻底移除（用户要求）。数码管仍可读全部内部状态。
    .rgb_in     (vout_data),
    .rgb_out    (tide_video)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (audio_video_rst),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (tide_video),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
// 640x480@60（VIC 1，标准 CEA 模式）。时序与 color_bar.v 的 VIDEO_640_480
// 参数组、以及官方例程 lab_ex5_i2s 完全一致：
//   行 800 = 640 + 16(fp) + 96(sync) + 48(bp)
//   场 525 = 480 + 10(fp) +  2(sync) + 33(bp)
// 像素时钟 25MHz -> 实际刷新率 25e6/(800*525) = 59.52Hz
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 125        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
