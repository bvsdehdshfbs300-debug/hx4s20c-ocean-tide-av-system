
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    // 鑷姩杞挱鍛ㄦ湡妗ｄ綅锛?=1s 1=3s 2=5s銆傞粯璁?3 绉掞紙1 绉掓紨绀烘椂璇勫鐪嬩笉娓咃級
    parameter [1:0]   AUTO_PERIOD_DEF   = 2'd1
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       key_period,      // 绗笁涓寜閿細鍒囨崲杞挱鍛ㄦ湡 1/3/5 绉?
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output      [1:0]           period_sel_o,   // 褰撳墠鍛ㄦ湡妗ｄ綅锛屼緵 OSD/鏁扮爜绠℃樉绀?
    output reg  [7:0]           fade_alpha,     // 杞満浜害 0=鍏ㄩ粦 255=姝ｅ父锛坰d_card_clk 鍩燂級
    // ---- 灞忓箷璋冭瘯瑙傛祴锛坰d_card_clk 鍩燂紝鐢?tide_overlay 鍚屾鍚庢樉绀猴級----
    output wire [2:0]           dbg_found_o,    // 鎵弿鍒板嚑寮?
    output wire [2:0]           dbg_cached_o,   // 鎴愬姛鍔犺浇鍑犲紶
    output wire [2:0]           dbg_preload_o,  // 棰勫姞杞芥簮搴忓彿
    output wire                 auto_play_o,    // 鑷姩杞挱鏄惁寮€鍚紙鏁扮爜绠℃樉绀?A/E 鐢級

    output reg  [2:0]           transition_mode, // latched until this transition ends
    output wire [7:0]           transition_alpha_gray,
    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    // 【2026-10-07 第5块帧缓冲 · 步骤2】写侧第 5 块选中位。
    // 为什么不把 write_buf_idx 加宽成 3 位：那样 sd_card_bmp 里 8 处 2 位赋值、
    // top 里的连线、以及 frame_fifo 的端口全都要动。用一位 use_addr4 代替，
    // 位宽一处不动，只有这一个"哪块"的额外信息。
    // 写侧不需要额外打拍：write_req 是【保持到 ack】的电平握手，
    // 整个握手期间索引都是稳定的。
    output reg                  write_use_addr4,
    // 【2026-10-07 第5块帧缓冲 · 步骤3】显示侧第 5 块选中位。
    // disp_buf_idx 仍然 2 位不变；这一位补足"第 5 块"的信息。
    output wire                 disp_use_addr4,
    output wire [1:0]           disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,
    input                       audio_clk,
    input                       audio_rst,
    input                       audio_sample_tick,
    output wire signed [15:0]   audio_sample,
    output wire [7:0]           audio_envelope,
    // 三频带包络（低/中/高），供屏幕波浪分层驱动
    output wire [7:0]           audio_env_low,
    output wire [7:0]           audio_env_mid,
    output wire [7:0]           audio_env_high,
    // 多歌支持
    input                       key_song,      // 手动切下一首
    output wire [2:0]           song_no,       // 当前是第几首（0 起）
    output wire [2:0]           song_total_o,  // 卡上共几首（歌单里读出来的）
    // 菜单状态（要同步到视频域去渲染）
    output wire                 menu_on_o,
    output wire [3:0]           menu_item_o,
    output wire [2:0]           menu_trans_o,      // 转场方式（拓展②）
    output wire [1:0]           menu_scale_o,
    output wire                 render_zoom_o,     // applied zoom, changes only under the transition cover
    output wire                 menu_music_o,
    output wire [2:0]           menu_vol_o,      // 缩放模式（拓展③）
    output wire [1:0]           menu_brightness_o, // 0/1/2/3 = 25/50/75/100%
    output wire [2:0]           menu_contrast_o,   // 0..6 = 50/75/90/100/110/125/150%
    output wire                 idle_dim_o,        // 30 秒无操作后自动降至 25%
    output wire                 menu_info_o,       // 分辨率/缩放比 OSD 开关（拓展④）
    output wire [15:0]          bmp_hdr_w_o,       // BMP 头解析出的实际宽高（信息栏显示用）
    output wire [15:0]          bmp_hdr_h_o,
    // 开场动画跳过："任意键"（电平，见下面注释）
    output wire                 boot_skip_o
);

wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire             pcm_sd_read;
wire [31:0]      pcm_sd_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [2:0]        cached_count;          // 宸插畬鏁村啓鍏?SDRAM 鐨勫浘鐗囨暟閲?
reg [2:0]        preload_src_idx;       // 当前预加载的 TF 图片编号
reg              preload_done;
// 【2026-10-07 第5块帧缓冲 · 步骤3】轮播/显示索引，3 位。
//   0..3 = 4 张原图      4 = 图1 的推近版（只在缩放开时参与）
// 为什么必须加宽：2 位装不下"第 5 块"。以前是 4 块时代，2 位刚好。
// 【关键】disp_buf_idx / disp_use_addr4 都是从这个 3 位量【派生】出来的
//   （见下面的 assign），不再各自赋值 —— 这样两者永远同拍、不可能对不上。
//   交接文档 §3.6 那个"从一块 bank 读、按另一块处理"的坑就是这么来的。
reg [2:0]        img_idx;
// 淡出结束时要切到的目标块（3 位，和 img_idx 同宽）
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;        // 【2026-10-06】第5张 = 图1的推近版（缩放演示）
reg              load_busy;
reg [31:0]       load_timeout_cnt;

reg              load_abort;

// bmp_ready 鍏堣〃绀衡€滄簮鏂囦欢璇诲彇/閫?FIFO 瀹屾垚鈥濓紱鐪熸鍒囨樉绀鸿绛?write_finish_toggle 鍚屾鍚?
reg              source_done_seen;
reg              write_done_seen;
    reg              load_left_idle;        // bmp_read 是否已真的离开 IDLE（见握手说明）
    reg [1:0]        load_retry_cnt;        // 超时重试计数（竞争兜底）
    // 本次加载已持续的时钟数。前 20ms 内不接受"写帧完成"脉冲 ——
    // 一张 900KB 的图不可能那么快写完，那时的脉冲必定是上一帧的残留。
    reg [23:0]       load_elapsed;
    wire             load_settled = (load_elapsed >= 24'd2_000_000);
    always @(posedge clk or posedge rst) begin
        if (rst)                    load_elapsed <= 24'd0;
        else if (!load_busy)        load_elapsed <= 24'd0;
        else if (!load_settled)     load_elapsed <= load_elapsed + 24'd1;
    end

// 鍚屾 mem_clk 鍩熺殑 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [2:0] next_from_current;

    localparam [31:0] LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * 4;
    localparam [1:0]  LOAD_RETRY_MAX      = 2'd1;   // 超时后重试次数（含首次共 2 次尝试）

// 涓夋。杞挱鍛ㄦ湡瀵瑰簲鐨勬椂閽熷懆鏈熸暟锛圕LK_FREQ_HZ 鏄弬鏁帮紝姝ゅ涓哄父鏁版姌鍙狅紝涓嶄骇鐢熶箻娉曞櫒锛?
localparam [31:0] PERIOD_CYC_1S = CLK_FREQ_HZ * 1;
localparam [31:0] PERIOD_CYC_3S = CLK_FREQ_HZ * 3;
localparam [31:0] PERIOD_CYC_5S = CLK_FREQ_HZ * 5;

reg [1:0]  period_sel;
reg [31:0] auto_period_cyc;

// ---------------- 杞満锛堟贰鍑?-> 鍒囧浘 -> 娣″叆锛?---------------
localparam [2:0] FADE_IDLE = 3'd0,
                 FADE_OUT  = 3'd1,
                 FADE_IN   = 3'd2,
                 FADE_COVER = 3'd3,
                 FADE_SETTLE = 3'd4;

// 姣?8ms 璧颁竴妗ｏ紝32 妗ｇ害 256ms锛屾贰鍑?娣″叆鍚堣绾?0.5s
localparam [31:0] FADE_STEP_CYC = CLK_FREQ_HZ / 125;

// Two 32ms covered intervals: mask reaches every scanline before bank change,
// then the frame reader has time to adopt the new bank before revealing it.
localparam [31:0] COVER_CYC = CLK_FREQ_HZ / 1000 * 32;
reg [2:0]  fade_state;
// Bundled-data mailbox: hold mode + alpha stable until video acknowledges.
// Only the request/acknowledge toggles pass through synchronizers.
assign transition_alpha_gray = fade_alpha ^ (fade_alpha >> 1);
reg [31:0] fade_cnt;
reg [2:0]  pending_idx;     // 淡出结束时要切到的目标块（3 位，含第 5 块）
reg        render_zoom;
reg        pending_zoom;

// 【步骤3】显示侧的两个输出都从 img_idx【派生】——
//   disp_buf_idx  = 低 2 位（哪一块，0..3）
//   disp_use_addr4 = 最高位（1 = 第 5 块）
// 这样"索引"和"第5块选中"永远是同一个值的两个切片，不可能错拍。
// 同时这也满足了交接文档 §3.6 的铁律：img_idx 和 disp_buf_idx 必须一致。
assign disp_buf_idx    = img_idx[1:0];
assign disp_use_addr4  = img_idx[2];
assign render_zoom_o   = render_zoom;

// 妗ｄ綅閫夋嫨锛氱函 case 閫夋嫨甯告暟锛岀患鍚堟垚閫夋嫨鍣ㄨ€岄潪涔樻硶鍣?
always @(*) begin
    case (period_sel)
        2'd0:    auto_period_cyc = PERIOD_CYC_1S;
        2'd1:    auto_period_cyc = PERIOD_CYC_3S;
        default: auto_period_cyc = PERIOD_CYC_5S;
    endcase
end

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt >= (auto_period_cyc - 32'd1));
assign period_sel_o = period_sel;
assign dbg_found_o   = img_found_count;
assign dbg_cached_o  = cached_count;
assign dbg_preload_o = preload_src_idx;
assign auto_play_o   = auto_play_en;
assign next_from_current = next_index_limited(img_idx, cached_count, 3'd4);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = state_code_i;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

// 绗笁涓寜閿細杞挱鍛ㄦ湡鍒囨崲锛堟秷鎶?50ms锛屼笌鍙︿袱涓寜閿竴鑷达級
wire key_period_press;
wire key_song_press;
key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_period (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_period),
    .press_pulse(key_period_press)
);

//============================================================================
// 30 秒无操作自动节能。唤醒按键只负责恢复亮度，不继续传给原按键功能，
// 避免用户只是想点亮屏幕却意外切图、切歌或修改菜单。
// 100MHz * 30s = 3,000,000,000，32 位计数器可以容纳。
//============================================================================
localparam [31:0] IDLE_DIM_CYC = CLK_FREQ_HZ * 30;
reg [31:0] idle_dim_cnt;
reg        idle_dim;
wire       any_key_press_raw = key_next_press | key_auto_press |
                               key_period_press | key_song_press;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        idle_dim_cnt <= 32'd0;
        idle_dim     <= 1'b0;
    end else if (any_key_press_raw) begin
        idle_dim_cnt <= 32'd0;
        idle_dim     <= 1'b0;
    end else if (!idle_dim) begin
        if (idle_dim_cnt >= (IDLE_DIM_CYC - 32'd1)) begin
            idle_dim_cnt <= idle_dim_cnt;
            idle_dim     <= 1'b1;
        end else begin
            idle_dim_cnt <= idle_dim_cnt + 32'd1;
        end
    end
end

assign idle_dim_o = idle_dim;

//============================================================================
// 歌单读取与多歌切换
//
// 卡上 LBA 131072 是一个 512 字节的歌单扇区（由 _probe/build_card.py 生成）：
//   字节 0-3    'T','I','D','E'
//   字节 4      歌曲数 N
//   字节 8+8i   第 i 首起始 LBA   (uint32 小端)
//   字节 12+8i  第 i 首扇区数     (uint32 小端)
//
// 开机读一次就够 —— 以后改卡上的歌单、换歌、加歌都不用重新综合 FPGA。
// 时序上安排在【图片预加载之后、PCM 开始播放之前】，三者不争 SD 总线：
//   preload_done 之前 -> 总线归 bmp_read / sd_sec_read
//   preload_done 之后、pl_done 之前 -> 总线归本模块
//   pl_done 之后 -> 总线归 tide_pcm_stream
//============================================================================
localparam [31:0] PLAYLIST_LBA = 32'd131072;
localparam PL_IDLE = 2'd0, PL_REQ = 2'd1, PL_CAP = 2'd2, PL_END = 2'd3;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_song (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_song),
    .press_pulse(key_song_press)
);

//============================================================================
// 菜单状态机 + 按键门控（模态）
//
// K4 有两个角色：菜单关着时"切下一首歌"，菜单开着时"退出菜单"。
// 菜单打开时 K1/K2/K3 的原功能一律屏蔽 —— 否则一个键两个意思必然误触。
//============================================================================
wire       menu_on;
wire [3:0] menu_item;
wire [2:0] menu_trans;                 // 转场方式 0..4（来自 osd_menu 输出端口）
// 【2026-10-06 改】缩放从"4 档模式"简化成"开/关"：menu_zoom 1 位。
//   menu_scale_o 保持 [1:0] 位宽（高位恒 0），这样 top 那边的端口不用动。
wire       menu_zoom;                  // 缩放 1=推近 0=原样
wire       menu_music;                 // 音乐开/关（新增）
wire [2:0] menu_vol;                   // 音量档位 0..6（新增）
wire [1:0] menu_brightness;            // 亮度 25/50/75/100%
wire [2:0] menu_contrast;              // 对比度 50/75/90/100/110/125/150%
wire       menu_info;                  // 分辨率/缩放比 OSD 开关
wire       menu_cmd_song, menu_cmd_mode, menu_cmd_period;
wire [15:0] bmp_hdr_w, bmp_hdr_h;

reg        menu_zoom_d;                // 上一拍的缩放开关，用来产生变化沿
wire       zoom_chg = (menu_zoom != menu_zoom_d);

// ============================================================================
// 【2026-10-07 第5块帧缓冲 · 步骤3】原来的 zoom_pend / zoom_reload / zoom_go
// 三寄存器状态机【整段删除】。
//
// 它存在的唯一理由是：4 块缓冲时装不下第 5 张，只能覆盖缓冲1，
// 于是必须先"把显示切到缓冲0"确认没人读缓冲1，才敢重写它 ——
// 这条链子本身就是那 4 秒黑屏的来源。
//
// 现在推近版常驻缓冲4，5 张图开机全部预载完毕，没有任何东西需要重写，
// 所以这一整套"先确认再重载"的机制不需要了。
// 缩放切换变成纯粹的"换显示索引"，走下面 FADE_OUT 原有的淡出->淡入。
//
// 顺带修掉一个隐患：原来 menu_zoom_d 被【两个】always 块驱动
// （本块和紧随其后的一个），这是重复驱动。现在只留一个。
// ============================================================================
always @(posedge clk or posedge rst) begin
    if (rst) menu_zoom_d <= 1'b0;
    else     menu_zoom_d <= menu_zoom;
end

assign menu_on_o    = menu_on;
assign menu_item_o  = menu_item;
assign menu_trans_o = menu_trans;
assign menu_scale_o = {1'b0, menu_zoom};
assign menu_music_o = menu_music;
assign menu_vol_o   = menu_vol;
assign menu_brightness_o = menu_brightness;
assign menu_contrast_o   = menu_contrast;
assign menu_info_o  = menu_info;
assign bmp_hdr_w_o  = bmp_hdr_w;
assign bmp_hdr_h_o  = bmp_hdr_h;

//============================================================================
// 【2026-10-05 退残留】原来的"图像/音频参数"整块已删除
//
// 这里曾经有 bright_lv / cont_lv / vol_lv 三个 0..10 的档位寄存器，
// 分别驱动两类处理：亮度+对比度合成的仿射变换（视频末端 out = in*A + B）、
// 音量定点缩放（vol_scale -> tide_pcm_stream）。
// 两者都已从功能上拔掉 —— 仿射变换导致画面整体偏青，定点缩放导致上板无声 ——
// 但寄存器、输出端口和连线一直留在源码里，于是菜单里那三项成了"点了没反应"的死项。
// 现在源码回到 menu4 语义：歌曲 / 播放模式 / 轮播周期 / 系统信息。
//============================================================================

osd_menu #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .TIMEOUT_MS  (10000)
) u_osd_menu (
    .clk             (clk),
    .rst             (rst),
    .key_up          (key_next_press   & ~idle_dim), // 待机时首个按键只唤醒
    .key_down        (key_auto_press   & ~idle_dim),
    .key_adj         (key_period_press & ~idle_dim),
    .key_menu        (key_song_press   & ~idle_dim),
    .cmd_song_next   (menu_cmd_song),
    .cmd_mode_toggle (menu_cmd_mode),
    .cmd_period_next (menu_cmd_period),
    .menu_on         (menu_on),
    .item_sel        (menu_item),
    // 拓展项 ②③④ 的状态（转发给视频域渲染；后面交给读卡/转场用）
    .trans_sel       (menu_trans),
    .zoom_on         (menu_zoom),      // 2026-10-06: 缩放改成开/关
    .info_on         (menu_info),
    .music_on        (menu_music),     // 2026-10-06: 音乐开/关
    .vol_sel         (menu_vol),       // 2026-10-06: 音量档位
    .brightness_sel  (menu_brightness),
    .contrast_sel    (menu_contrast)
);

// 门控后的按键：菜单开着时这三条全部失效
wire key_next_g   = key_next_press   && !menu_on && !idle_dim;
wire key_auto_g   = key_auto_press   && !menu_on && !idle_dim;
wire key_period_g = key_period_press && !menu_on && !idle_dim;
wire key_song_g   = key_song_press   && !menu_on && !idle_dim;

//============================================================================
// 开场动画跳过 —— "任意键"
//
// 【必须是电平，不能是脉冲】它要跨到 video_clk 域（25MHz，一拍 40ns）。
// 脉冲同步过去必然丢；做成置 1 后一直保持到复位的电平，两级同步就够。
// 动画只在上电后播一次，所以这个位不需要清 —— 动画结束后 boot_active=0，
// 它留着也不会有任何作用。
//============================================================================
reg boot_skip_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        boot_skip_r <= 1'b0;
    else if (key_next_press || key_auto_press || key_period_press || key_song_press)
        boot_skip_r <= 1'b1;
end
assign boot_skip_o = boot_skip_r;

reg  [1:0] pl_state;
reg  [9:0] pl_cnt;                    // 本扇区已收到的字节序号
reg  [2:0] pl_count;                  // 卡上实际有几首
reg  [7:0] pl_ram [0:39];             // 字节 8..47 = 5 首 × (LBA 4B + 长度 4B)
reg        pl_done;
reg        pl_read;

wire pl_active = preload_done && !pl_done;

// sd_sec_read_data_valid 是从 sd_card_cmd 的字节计数器（byte_cnt_b）组合出来的，
// 如果直接拿它驱动 pl_ram 的写使能，会形成全区最紧的一条路径：
//   实测 9.127ns / 10ns，Logic Level 6，其中 79% 是走线延迟
//   （起点 sd_card_cmd_m0/byte_cnt_b[15]，终点 pl_ram_reg[131].ce）。
// 本模块只是"把字节收集起来"，晚一拍毫无影响 —— 所以先寄一拍再喂给收集逻辑。
reg        pl_dv_r;
reg [7:0]  pl_da_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pl_dv_r <= 1'b0;
        pl_da_r <= 8'd0;
    end else begin
        pl_dv_r <= sd_sec_read_data_valid;
        pl_da_r <= sd_sec_read_data;
    end
end

wire pl_wr = (pl_state == PL_CAP) && pl_dv_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pl_state <= PL_IDLE;
        pl_cnt   <= 10'd0;
        pl_count <= 3'd0;
        pl_done  <= 1'b0;
        pl_read  <= 1'b0;
    end else begin
        case (pl_state)
            PL_IDLE: if (pl_active) begin
                pl_read  <= 1'b1;
                pl_cnt   <= 10'd0;
                pl_state <= PL_REQ;
            end
            PL_REQ: pl_state <= PL_CAP;
            PL_CAP: begin
                if (pl_dv_r) pl_cnt <= pl_cnt + 10'd1;
                if (sd_sec_read_end) begin
                    pl_read  <= 1'b0;
                    pl_state <= PL_END;
                end
            end
            PL_END: begin
                pl_done  <= 1'b1;
                pl_state <= PL_IDLE;
            end
            default: pl_state <= PL_IDLE;
        endcase
        // 只留字节 8..47 这 40 个字节（正好 5 首），省掉一整块 RAM
        if (pl_wr && (pl_cnt >= 10'd8) && (pl_cnt < 10'd48))
            pl_ram[pl_cnt - 10'd8] <= pl_da_r;
        if (pl_wr && (pl_cnt == 10'd4))
            pl_count <= pl_da_r[2:0];
    end
end

// 小端解析（未读到时 pl_done=0，tide_pcm_stream 会用编译期兜底值）
wire [31:0] pl_lba0 = {pl_ram[3],  pl_ram[2],  pl_ram[1],  pl_ram[0]};
wire [31:0] pl_len0 = {pl_ram[7],  pl_ram[6],  pl_ram[5],  pl_ram[4]};
wire [31:0] pl_lba1 = {pl_ram[11], pl_ram[10], pl_ram[9],  pl_ram[8]};
wire [31:0] pl_len1 = {pl_ram[15], pl_ram[14], pl_ram[13], pl_ram[12]};
wire [31:0] pl_lba2 = {pl_ram[19], pl_ram[18], pl_ram[17], pl_ram[16]};
wire [31:0] pl_len2 = {pl_ram[23], pl_ram[22], pl_ram[21], pl_ram[20]};
wire [31:0] pl_lba3 = {pl_ram[27], pl_ram[26], pl_ram[25], pl_ram[24]};
wire [31:0] pl_len3 = {pl_ram[31], pl_ram[30], pl_ram[29], pl_ram[28]};
wire [31:0] pl_lba4 = {pl_ram[35], pl_ram[34], pl_ram[33], pl_ram[32]};
wire [31:0] pl_len4 = {pl_ram[39], pl_ram[38], pl_ram[37], pl_ram[36]};

reg  [2:0] song_sel;
wire [2:0] song_max = (pl_count == 3'd0) ? 3'd1 : pl_count;

wire [31:0] song_lba_sel =
    (song_sel == 3'd0) ? pl_lba0 : (song_sel == 3'd1) ? pl_lba1 :
    (song_sel == 3'd2) ? pl_lba2 : (song_sel == 3'd3) ? pl_lba3 : pl_lba4;
wire [31:0] song_len_sel =
    (song_sel == 3'd0) ? pl_len0 : (song_sel == 3'd1) ? pl_len1 :
    (song_sel == 3'd2) ? pl_len2 : (song_sel == 3'd3) ? pl_len3 : pl_len4;

assign song_no      = song_sel;
assign song_total_o = (pl_count == 3'd0) ? 3'd1 : pl_count;

// 放完自动下一首（Q3b）或手动切下一首（K4）
wire pcm_song_done;                                   // 由 tide_pcm_stream 驱动
// K4 只当菜单键！原来写成 "key_song_g || ..."，而 key_song_g = K4 && !menu_on，
// 于是菜单关着时按 K4 会【同时】开菜单和切歌 —— 一个键干两件事。
// 手动切歌统一走菜单里的「歌曲」项（menu_cmd_song）。
wire song_advance = menu_cmd_song || pcm_song_done;
reg  song_restart_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        song_sel      <= 3'd0;
        song_restart_r <= 1'b0;
    end else begin
        if (song_advance)
            song_sel <= (song_sel + 3'd1 >= song_max) ? 3'd0 : song_sel + 3'd1;
        song_restart_r <= song_advance;               // 迟一拍，等 song_sel 先稳定
    end
end

// 【2026-10-07 步骤3】轮播范围从 4 扩到 5（3 位），但【范围由调用方给】。
//   limit = 每轮几张。
//     缩放关 -> 传 4 -> 只走 0..3（4 张原图）
//     缩放开 -> 不走这个函数（0 <-> 4 来回，见下面的 menu_zoom 分支）
//
// 【为什么必须带 limit —— 这是仿真实测抓出来的 bug】
//   第一版把 default 臂写成 `(cur >= 3'd4) ? 0 : cur+1`，于是缩放关时
//   索引会走到 4 —— 也就是把【图1 的推近版】混进了正常轮播 ✗
//   用户明确要求"缩放关只轮播 4 张原图、第 5 块只在缩放开时参与"。
//   静态检查（文本层面）全过，是行为仿真跑出 [1,2,3,4,0,...] 才发现的。
//   所以这里改成 limit 参数化，把"轮几张"这件事写死在调用点。
function [2:0] next_index_limited;
    input [2:0] cur;
    input [2:0] count;      // 已缓存几张（守卫用，>=2 才有得轮）
    input [2:0] limit;      // 本轮轮播的张数：4 = 只轮原图
    begin
        case (count)
            3'd0: next_index_limited = 3'd0;
            3'd1: next_index_limited = 3'd0;
            3'd2: next_index_limited = (cur >= 3'd1) ? 3'd0 : (cur + 3'd1);
            3'd3: next_index_limited = (cur >= 3'd2) ? 3'd0 : (cur + 3'd1);
            default: next_index_limited = (cur >= (limit - 3'd1)) ? 3'd0 : (cur + 3'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        period_sel            <= AUTO_PERIOD_DEF;   // 浠呭叏灞€澶嶄綅鏃跺洖鍒伴粯璁ゆ。浣?
        fade_state            <= FADE_IDLE;
        transition_mode       <= 3'd0;
        fade_cnt              <= 32'd0;
        fade_alpha            <= 8'd255;
        pending_idx           <= 3'd0;
        render_zoom           <= 1'b0;
        pending_zoom          <= 1'b0;
        img_found_count       <= 3'd0;
        cached_count          <= 3'd0;
        preload_src_idx       <= 3'd0;
        preload_done          <= 1'b0;
        img_idx               <= 2'd0;
        write_buf_idx         <= 2'd0;
        write_use_addr4       <= 1'b0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;   // 【步骤2】补上：原来漏了复位（扫描会覆盖，但不干净）
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        load_retry_cnt        <= 2'd0;
        load_left_idle        <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            wrfin_tgl_sync        <= 3'b000;
            scan_kicked           <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            cached_count          <= 3'd0;
            preload_src_idx       <= 3'd0;
            preload_done          <= 1'b0;
            render_zoom           <= 1'b0;
            pending_zoom          <= 1'b0;
            img_idx               <= 2'd0;
            write_buf_idx         <= 2'd0;
            write_use_addr4       <= 1'b0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            load_retry_cnt        <= 2'd0;
            load_left_idle        <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 鎵弿闃舵缂撳瓨鍓?4 寮犲浘鐨勮捣濮?sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;   // 2026-10-06: 5th = zoom variant
                    default: ;
                endcase

                if (img_found_count < SCAN_TARGET_COUNT)
                    img_found_count <= img_found_count + 3'd1;
            end

            // ---- 鍔犺浇瀹屾垚鎻℃墜锛堜慨姝ｇ増锛?---
            // 鍘熷疄鐜扮洿鎺ュ垽鏂?`load_busy && bmp_ready`锛屼絾 bmp_read 鐨?ST_IDLE
            // 鏄椂搴忚祴鍊硷紝绂诲紑 IDLE 瑕佺瓑涓€涓懆鏈熴€備簬鏄?load_busy 鍒氱疆璧风殑涓嬩竴鎷?
            // bmp_ready 浠嶇劧鏄?1锛宻ource_done_seen 浼氬湪"杩樻病寮€濮嬭"鏃跺氨琚疆浣嶏紝
            // 璇ヤ俊鍙峰洜姝や笉鎼哄甫浠讳綍淇℃伅锛屽畬鎴愭潯浠堕€€鍖栨垚鍙湅 write_done_seen銆?
            // 涓€鏃︿笂涓€甯ф畫鐣欑殑 write_finish 鍚屾鑴夊啿钀借繘鏈鍔犺浇绐楀彛锛屾湰娆″姞杞?
            // 灏变細"绌哄畬鎴?锛歝ached_count 鍔犱簡銆乥ank 鍗存病鍐欍€傝繖鏄珵浜夛紝甯冨眬涓€鍙?
            // 灏卞彲鑳藉鐜般€?
            //
            // 淇硶锛氳姹?bmp_read 鐪熺殑绂诲紑杩?IDLE锛坙oad_left_idle锛夛紝
            // 鍐嶅洖鍒?IDLE锛屾墠绠?婧愭暟鎹€佸畬"銆?
            if (load_busy && !bmp_ready)
                load_left_idle <= 1'b1;                 // 纭璇诲彇鍣ㄧ湡鐨勫紑宸ヤ簡

            if (load_busy && bmp_ready && load_left_idle)
                source_done_seen <= 1'b1;               // 寮€宸ヨ繃 + 鍙堝洖鍒扮┖闂?= 鐪熼€佸畬

            // 璁颁綇鍐欏抚瀹屾垚鑴夊啿锛岄伩鍏嶁€滃厛鍐欏畬鍚庢簮缁撴潫鈥濆鑷磋剦鍐蹭涪澶辫€屽崱姝汇€?
            // 娉ㄦ剰锛氳繖閲屻€愪笉鑳姐€戝啀鍔?load_left_idle 鏉′欢 鈥斺€?瀹炴祴鍔犱簡涔嬪悗
            // cached 浠?绋冲畾 3"閫€鍖栨垚"鏈夋椂 2"锛岃鏄庡悎娉曠殑鍐欏畬鎴愯剦鍐蹭細鏃╀簬
            // load_left_idle 鍒版潵锛屽姞鏉′欢浼氭妸姝ｅ父鑴夊啿涔熸护鎺夈€?
            // 绔炰簤鏀圭敤"瓒呮椂閲嶈瘯"鏉ュ厹搴曪紙瑙佷笅闈㈢殑 load_retry_cnt锛夈€?
            // 必须加一道【最短时间门】：一张 900KB 的图不可能在 20ms 内写完，
            // 所以加载刚开始 20ms 内出现的 write_finish 脉冲一定是上一帧的残留。
            // 不挡的话本次加载会"空完成"—— cached_count 加了、SDRAM buffer 却没写，
            // 表现就是"四张都显示已加载，但其中几张满屏噪点"。
            // （之前试过用 load_left_idle 当门，结果把合法的脉冲也滤掉了，
            //   实测 cached 从稳定 3 退化成有时 2，所以改用时间门。）
            if (load_busy && load_settled && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 棰勫姞杞芥垚鍔熷悗缂撳瓨璁℃暟鍔犱竴锛涙墍鏈夊浘鐗囧啓瀹屽悗鎵嶅紑鏀捐棰戣鍙栥€?
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                load_retry_cnt   <= 2'd0;          // 成功则清零重试计数
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                cached_count     <= cached_count + 3'd1;
                preload_src_idx  <= preload_src_idx + 3'd1;

                if ((preload_src_idx + 3'd1) >= SCAN_TARGET_COUNT) begin
                    preload_done  <= 1'b1;
                    display_valid <= 1'b1;
                    img_idx       <= 3'd0;
                end
            end else if (load_busy) begin
                if (load_timeout_cnt >= LOAD_TIMEOUT_CYCLES) begin
                    // 鍔犺浇瓒呮椂銆傛彙鎵嬮噷鏈?涓婁竴甯ф畫鐣欑殑 write_finish 鑴夊啿钀借繘鏈
                    // 鍔犺浇绐楀彛"鐨勭珵浜夛紝鍗曟澶辫触閫氬父鏄灛鎬佺殑 鈥斺€?鎵€浠ュ厛閲嶈瘯鍚屼竴寮狅紝
                    // 閲嶈瘯 LOAD_RETRY_MAX 娆′粛澶辫触鎵嶈烦杩囪鏂囦欢銆?
                    // 锛堝師鏉ョ殑瀹炵幇鐩存帴璺宠繃锛屼簬鏄?cached_count 浼氬皯 1锛岃疆鎾氨灏戜竴寮犲浘锛?
                    load_busy        <= 1'b0;
                    load_timeout_cnt <= 32'd0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_abort       <= 1'b1;

                    if (load_retry_cnt >= LOAD_RETRY_MAX) begin
                        load_retry_cnt  <= 2'd0;
                        preload_src_idx <= preload_src_idx + 3'd1;
                        if ((preload_src_idx + 3'd1) >= SCAN_TARGET_COUNT && (cached_count != 3'd0)) begin
                            preload_done  <= 1'b1;
                            display_valid <= 1'b1;
                            img_idx       <= 3'd0;
                        end
                    end else begin
                        load_retry_cnt <= load_retry_cnt + 2'd1;   // 鍚屼竴寮犲啀鏉ヤ竴娆?
                    end
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 涓婄數鍚庤嚜鍔ㄥ彂璧蜂竴娆♀€滄壂鎻忓墠 4 寮?BMP鈥?
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse <= 1'b1;
                scan_kicked      <= 1'b1;
                auto_play_en     <= 1'b0;
                auto_cnt         <= 32'd0;
                img_found_count  <= 3'd0;
                cached_count     <= 3'd0;
                preload_src_idx  <= 3'd0;
                preload_done     <= 1'b0;
                img_idx          <= 2'd0;
                write_buf_idx    <= 2'd0;
                write_use_addr4  <= 1'b0;
                display_valid    <= 1'b0;
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
            end else if (scan_done) begin
                // ============================================================
                // 【2026-10-07 第5块帧缓冲 · 步骤3】缩放开关不再触发任何重载！
                //
                // 以前（4 块时代）：第 5 张（推近版）没地方放，只能覆盖缓冲1，
                //   所以开关一变就要【重跑一次预载】把新变体写进缓冲1。
                //   代价：黑屏约 4 秒 + 音乐停一下（图片和 PCM 都走 TF 卡抢带宽）。
                //
                // 现在（5 块时代）：推近版【常驻缓冲4】，4 张原图常驻缓冲0-3，
                //   开机时全部预载完毕。所以开关只是换个显示索引 ——
                //   零延迟、不读卡、音乐完全不受影响。
                //
                // 这一整段重跑逻辑（preload_done/display_valid 清零）就此删掉。
                // 只保留一件事：把显示钉回缓冲0（图1 原图）。真正的切换由下面的
                // 轮播逻辑在 FADE_OUT 里完成，走的是原有的淡出->淡入，不黑屏。
                // ============================================================
                if (!preload_done) begin
                    // 鍥剧墖鎸夐『搴忓啓鍏?buffer0..buffer3锛屽畬鎴愬悗涓嶅啀璁块棶 TF 鍗°€?
                    if (!load_busy && bmp_ready && (preload_src_idx < SCAN_TARGET_COUNT)) begin
                        // 【2026-10-06】索引1 装什么由缩放开关决定：
                        //   关 -> img_sector1（图2 原图）
                        //   开 -> img_sector4（图1 的推近版）
                        // 其余三个索引永远装原图，所以"缩放开"时轮播就是
                        // 图1 / 放大的图1 / 图3 / 图4 —— 用户要的效果在这条路上。
                        // 【步骤2】槽位表：0->图1 1->图2 2->图3 3->图4 4->图1推近版
                        // 槽4 不再看 menu_zoom —— 推近版有自己专用的缓冲了。
                        load_sector      <= sector_lut(preload_src_idx[1:0]);
                        write_buf_idx    <= preload_src_idx[1:0];
                        write_use_addr4  <= (preload_src_idx == 3'd4);
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        write_done_seen  <= 1'b0;
                        load_retry_cnt   <= 2'd0;
                        load_left_idle   <= 1'b0;   // 鏈鍔犺浇灏氭湭鐪熸寮€宸?
                    end else if (!load_busy && bmp_ready &&
                                 (preload_src_idx >= SCAN_TARGET_COUNT) && (cached_count != 3'd0)) begin
                        preload_done  <= 1'b1;
                        display_valid <= 1'b1;
                        img_idx       <= 3'd0;
                    end
                end else begin
                    // 绗笁涓寜閿細杞挱鍛ㄦ湡 1s -> 3s -> 5s -> 1s锛堜笌宸茬紦瀛樺浘鐗囨暟閲忔棤鍏筹級
                    // 【2026-10-07 步骤3】这里原来是"缩放切换时重载缓冲1"。
                    // 现在推近版常驻缓冲4、4 张原图常驻缓冲0-3，开机全部预载完毕，
                    // 所以【不再需要任何重载】—— 整段删除。
                    // 缩放切换从此只是换显示索引：不读卡、不黑屏、音乐不断。

                    if (key_period_g || menu_cmd_period) begin
                        period_sel <= (period_sel == 2'd2) ? 2'd0 : (period_sel + 2'd1);
                        auto_cnt   <= 32'd0;
                    end

                    // K2锛氳嚜鍔ㄨ疆鎾紑/鍏炽€?
                    if ((key_auto_g || menu_cmd_mode) && (cached_count > 3'd1)) begin
                        auto_play_en <= ~auto_play_en;
                        auto_cnt     <= 32'd0;
                    end

                    // 鑷姩杞挱璁℃椂锛氳浆鍦烘湡闂村喕缁擄紝鍒囧浘鍚庨噸鏂拌鏃讹紝閬垮厤杞満涓噸澶嶈Е鍙?
                    if (fade_state != FADE_IDLE) begin
                        auto_cnt <= auto_cnt;
                    end else if (auto_play_en && (cached_count > 3'd1)) begin
                        if (auto_tick)
                            auto_cnt <= 32'd0;
                        else
                            auto_cnt <= auto_cnt + 32'd1;
                    end else begin
                        auto_cnt <= 32'd0;
                    end

                    // ---------------- 杞満鐘舵€佹満 ----------------
                    // 鍒囧浘璇锋眰鍏堣繘鍏ユ贰鍑猴紝鍏ㄩ粦閭ｄ竴鍒绘墠鐪熸鍒?bank锛屽啀娣″叆銆?
                    case (fade_state)
                        FADE_IDLE: begin
                            fade_alpha <= 8'd255;
                            fade_cnt   <= 32'd0;
                            // 【2026-10-07 步骤3】zoom_chg 也触发一次切换：
                            // 缩放开关一变就【立刻】换到对应的那一块（块0 <-> 块4），
                            // 不用等 3 秒轮播周期。前面的 zoom_chg 分支已经把 img_idx
                            // 归到 3'd0（块0 原图），所以这里 pending_idx 一定算得出 4。
                            if ((key_next_g || (auto_play_en && auto_tick))
                                && (cached_count > 3'd1)) begin
                                // 【2026-10-07 步骤3】缩放改成"取哪一块"的关系，
                                // 不再是 4 块时代那套重载。pending_idx 3 位，直接取块号：
                                //   缩放【关】-> 正常轮播 4 张原图（块0..3，走 next_from_current）
                                //   缩放【开】-> 导演序列：块0 原图 -> 块4 推近版 -> 块1/2/3 原图
                                //                 -> 块0，再次进入推近段
                                // 块4 的 disp_buf_idx 低 2 位是 0，所以场景名/日月星仍按
                                // "图片号 0" 处理 —— 推近版就是晨潮，和原图一致 ✓
                                // （这比原来 top 里靠 menu_scale[0] 把场景索引钉成 0 更自然，
                                //   两处结论一致，不冲突。）
                                // All four original frame buffers use the same board-side
                                // scaler. Zoom no longer selects the pre-rendered fifth frame.
                                pending_idx  <= next_from_current;
                                pending_zoom <= render_zoom;
                                fade_state  <= FADE_OUT;
                                transition_mode <= menu_trans;
                                auto_cnt    <= 32'd0;
                            end
                        end

                        FADE_OUT: begin
                            if (fade_cnt >= (FADE_STEP_CYC - 32'd1)) begin
                                fade_cnt <= 32'd0;
                                if (fade_alpha <= 8'd8) begin
                                    fade_alpha   <= 8'd0;
                                    // 【2026-10-07 步骤3】一切从简：把 3 位块号整体写进
                                    // img_idx。disp_buf_idx / disp_use_addr4 都是它的切片
                                    // （见文件上方的 assign），所以【不可能】出现"读一块、
                                    // 按另一块处理"——交接文档 §3.6 那个坑从结构上消失了。
                                    // 5 张图全部常驻 SDRAM，这里只是换个索引，
                                    // 瞬时生效、不重读卡、不黑屏、不碰像素通路。
                                    fade_state <= FADE_COVER;
                                end else begin
                                    fade_alpha <= fade_alpha - 8'd8;
                                end
                            end else begin
                                fade_cnt <= fade_cnt + 32'd1;
                            end
                        end

                        FADE_COVER: begin
                            fade_alpha <= 8'd0;
                            if (fade_cnt >= COVER_CYC - 32'd1) begin
                                img_idx <= pending_idx;
                                render_zoom <= pending_zoom;
                                fade_cnt <= 32'd0;
                                fade_state <= FADE_SETTLE;
                            end else fade_cnt <= fade_cnt + 32'd1;
                        end
                        FADE_SETTLE: begin
                            fade_alpha <= 8'd0;
                            if (fade_cnt >= COVER_CYC - 32'd1) begin
                                fade_cnt <= 32'd0;
                                fade_state <= FADE_IN;
                            end else fade_cnt <= fade_cnt + 32'd1;
                        end
                        default: begin   // FADE_IN
                            if (fade_cnt >= (FADE_STEP_CYC - 32'd1)) begin
                                fade_cnt <= 32'd0;
                                if (fade_alpha >= 8'd247) begin
                                    fade_alpha <= 8'd255;
                                    fade_state <= FADE_IDLE;
                                end else begin
                                    fade_alpha <= fade_alpha + 8'd8;
                                end
                            end else begin
                                fade_cnt <= fade_cnt + 32'd1;
                            end
                        end
                    endcase
                    // Apply board-side zoom under the fully covered interval. The current
                    // picture index is preserved, so every one of the four images can zoom.
                    if (zoom_chg && preload_done) begin
                        pending_idx  <= img_idx;
                        pending_zoom <= menu_zoom;
                        transition_mode <= 3'd4;
                        fade_state  <= FADE_OUT;
                        fade_cnt    <= 32'd0;
                        auto_cnt    <= 32'd0;
                    end
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    // 拓展③ 缩放模式（0=适应 1=填充 2=拉伸 3=原始1:1）
    // 【D1 步】控制通路先铺好，重采样器还没写 —— 这个输入暂时没人消费，
    // 工具会把它裁掉，所以本步画面完全不变。
    .scale_mode             (2'd0),
    .hdr_width              (bmp_hdr_w),
    .hdr_height             (bmp_hdr_h),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    // SD 总线三路复用：歌单读取 -> PCM 播放 -> 图片扫描/预加载
    .sd_sec_read            (pl_active ? pl_read :
                             (preload_done ? pcm_sd_read : sd_sec_read)),
    .sd_sec_read_addr       (pl_active ? PLAYLIST_LBA :
                             (preload_done ? pcm_sd_addr : sd_sec_read_addr)),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

tide_pcm_stream u_tide_pcm_stream(
    .sd_clk          (clk),
    .audio_clk       (audio_clk),
    .sd_rst          (rst),
    .audio_rst       (audio_rst),
    // PCM 等歌单读完再开，避免和歌单读取抢 SD 总线
    .enable          (preload_done && bmp_ready && pl_done),
    .sd_req          (pcm_sd_read),
    .sd_lba          (pcm_sd_addr),
    .sd_data         (sd_sec_read_data),
    .sd_valid        (sd_sec_read_data_valid && preload_done && !pl_active),
    .sd_end          (sd_sec_read_end && preload_done && !pl_active),
    .sample_tick     (audio_sample_tick),
    .sample          (audio_sample),
    .envelope        (audio_envelope),
    .song_lba        (song_lba_sel),
    .song_sectors    (song_len_sel),
    .song_restart    (song_restart_r),
    .song_done       (pcm_song_done),
    .env_low         (audio_env_low),
    .env_mid         (audio_env_mid),
    .env_high        (audio_env_high)
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 榛樿锛氭澗寮€=1锛屾寜涓?0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
