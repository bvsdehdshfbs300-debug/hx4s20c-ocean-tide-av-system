module tide_pcm_stream #(
    // 多歌支持后，这两个参数退化成"卡上歌单还没读出来时的兜底值"。
    // 真正用哪个 LBA、放多少扇区，由 sd_card_bmp 从卡上的歌单扇区解析后送进来。
    parameter [31:0] START_LBA = 32'd131080,
    parameter [31:0] SECTORS   = 32'd22088
)(
    input wire sd_clk,
    input wire audio_clk,
    input wire sd_rst,
    input wire audio_rst,
    input wire enable,
    output wire sd_req,
    output reg [31:0] sd_lba,
    input wire [7:0] sd_data,
    input wire sd_valid,
    input wire sd_end,
    input wire sample_tick,
    output reg signed [15:0] sample,
    output reg [7:0] envelope,
    // ---- 多歌支持 ----
    input wire [31:0] song_lba,       // 当前这首的起始 LBA（0 = 还没读到，用兜底值）
    input wire [31:0] song_sectors,   // 当前这首的扇区数（0 = 还没读到，用兜底值）
    input wire        song_restart,   // 脉冲：立刻从当前这首的开头重放
    output reg        song_done,      // 一拍的脉冲：当前这首放完了，请切下一首
    // 【2026-10-05 退残留】原来的 vol_scale 音量系数端口已删除。
    // 它曾被用来做 sample <= (fifo_read_data * vol_scale) >>> 8，
    // vol_scale=0 时就是完全静音 —— 这就是"上板无声"的根因。
    // 采样现在直接直通 fifo_read_data，音量在源头（PCM 素材）定死。
    // 三频带包络（策划案里的"让每一类声音都有对应现象"）：
    //   低 -> 深层涌浪    中 -> 水面纹理    高 -> 泡沫与浪花
    output reg [7:0] env_low,
    output reg [7:0] env_mid,
    output reg [7:0] env_high
);
    // Extended Gray pointers retain the wrap bit, so full and empty cannot alias.
    localparam IDLE = 2'd0, READ = 2'd1, GAP = 2'd2;

    reg [12:0] wr_bin, rd_bin;
    reg [12:0] wr_gray, rd_gray;
    reg [12:0] rd_sync1, rd_sync2, wr_sync1, wr_sync2;
    reg [7:0] lo_byte;
    reg lo_seen;
    reg [1:0] state;
    reg [31:0] sector_index;
    reg started;
    reg [7:0] peak;
    reg [9:0] peak_count;

    //========================================================================
    // 三频带分离 —— 两个一阶 IIR 低通，相减得到三个频带
    //
    //   一阶低通： y += (x - y) >>> k     等效截止 fc ≈ fs / (2π·2^k)
    //     k = 5  ->  fc ≈ 240 Hz    （低频分界）
    //     k = 2  ->  fc ≈ 1900 Hz   （中/高交界）
    //
    //   低频 = lp1                  （240Hz 以下：鼓、贝斯 -> 深层涌浪）
    //   中频 = lp2 - lp1            （240Hz~1.9kHz：人声、旋律 -> 水面纹理）
    //   高频 = x   - lp2            （1.9kHz 以上：镲片、齿音 -> 泡沫浪花）
    //
    // 每个频带各自做 768 采样的峰值检波，和总包络同拍输出。
    // 成本：2 个减法 + 2 个算术右移 + 3 个绝对值 + 3 个比较器，不用乘法器。
    //========================================================================
    reg signed [15:0] lp1, lp2;
    wire signed [15:0] df1 = sample - lp1;
    wire signed [15:0] df2 = sample - lp2;

    wire signed [15:0] band_low  = lp1;
    wire signed [15:0] band_mid  = lp2 - lp1;
    wire signed [15:0] band_high = sample - lp2;

    wire [15:0] mag_low  = band_low[15]  ? (~band_low  + 16'd1) : band_low;
    wire [15:0] mag_mid  = band_mid[15]  ? (~band_mid  + 16'd1) : band_mid;
    wire [15:0] mag_high = band_high[15] ? (~band_high + 16'd1) : band_high;

    reg [7:0] pk_low, pk_mid, pk_high;

    wire [15:0] fifo_read_data;
    wire fifo_write = (state == READ) && sd_valid && lo_seen;
    ram_infer_wfifo_32_32_512 #(
        .DATAWIDTH_A(16),
        .DATAWIDTH_B(16),
        .ADDRWIDTH_A(12),
        .ADDRWIDTH_B(12),
        .MODE("SDP")
    ) u_audio_ram (
        .clka(sd_clk), .rsta(sd_rst), .cea(1'b1), .ocea(1'b0),
        .wea(fifo_write), .dia({sd_data, lo_byte}), .addra(wr_bin[11:0]),
        .doa(),
        .clkb(audio_clk), .rstb(audio_rst), .ceb(1'b1), .oceb(1'b0),
        .web(1'b0), .dib(16'd0), .addrb(rd_bin[11:0]),
        .dob(fifo_read_data)
    );
    // ---- gray_to_bin 必须先声明后使用 ----
    // 下面的 always 块（过程代码）要用它。Verilog 要求函数在过程代码里
    // 使用前必须已声明；写在后面会被当成"未声明的隐式函数"静默处理，
    // 返回值就是垃圾 —— 会让 FIFO 深度判定全错、音频流起不来。
    // （原来的代码是在 assign 里用的，连续赋值在整模块解析后才展开，
    //   所以放在后面也能用；过程代码不行。）
    function [12:0] gray_to_bin;
        input [12:0] g;
        integer i;
        begin
            gray_to_bin[12] = g[12];
            for (i = 11; i >= 0; i = i - 1)
                gray_to_bin[i] = gray_to_bin[i+1] ^ g[i];
        end
    endfunction

    // Gray 码转二进制是 XOR 链，再减一次得到"已用深度" —— 整条路 8 级逻辑
    // （其中 4 级加法器）。在 sd_card_clk = 100MHz 下太深，会把 sd_lba / scan
    // 这些寄存器的 CE 路径拖到违例（实测 -241ps，3 条）。
    // 深度只是"慢变的水平指示"，晚一个周期对 FIFO 判定没有任何影响，
    // 所以把深度计算打一拍再拿去比较，把长链从 CE 路径上摘掉。
    reg [12:0] used_sd_r;
    reg [12:0] used_audio_r;
    always @(posedge sd_clk or posedge sd_rst) begin
        if (sd_rst) used_sd_r <= 13'd0;
        else        used_sd_r <= wr_bin - gray_to_bin(rd_sync2);
    end
    always @(posedge audio_clk or posedge audio_rst) begin
        if (audio_rst) used_audio_r <= 13'd0;
        else           used_audio_r <= gray_to_bin(wr_sync2) - rd_bin;
    end
    wire [12:0] used_sd    = used_sd_r;
    wire [12:0] used_audio = used_audio_r;
    wire [15:0] magnitude = sample[15] ? -sample : sample;
    assign sd_req = (state == READ);

    // 歌长/起点：卡上还没读到歌单时（值为 0）退回编译期兜底值，
    // 免得 sector_index 永远等不到 cur_len_r-1 而死循环。
    //
    // 【必须寄存一拍】—— 这里踩过一次时序坑：
    //   song_lba 来自 sd_card_bmp 的 5 路 32 位选择器，如果直接
    //   "选择器 -> 32 位加法器 -> sector_index"，从 song_sel 到
    //   sector_index 的路径是 11 级逻辑、10.9ns，超过 10ns 周期，
    //   实测 Setup WNS 掉到 -1187ps（40 条失败路径）。
    //   中间插一级寄存器后就切成了两段短路径。
    //   歌号切换本身是低频事件，多这一拍完全无感。
    reg [31:0] cur_lba_r;
    reg [31:0] cur_len_r;
    // 本首最后一个扇区号。原来比的是常数 SECTORS-1，现在长度是变量，
    // 若写成 "sector_index >= cur_len_r - 1"，那个 32 位减法会落在
    // sector_index 自己的回环路径上。
    reg [31:0] cur_last_r;
    // 再插一级：song_sectors 来自 sd_card_bmp 的 5 路 32 位选择器，
    // 若"选择器 -> 32 位减法 -> cur_last_r"挤在一拍，实测 9.326ns
    // 直接吃掉全部余量（起点 mux47 = song_sel 的选择器，终点 cur_last_r_reg[27]）。
    // 先寄存成 cur_len_pre，减法就只面对一个寄存器。
    reg [31:0] cur_len_pre;

    always @(posedge sd_clk or posedge sd_rst) begin
        if (sd_rst) begin
            cur_len_pre <= SECTORS;
            cur_lba_r   <= START_LBA;
            cur_len_r   <= SECTORS;
            cur_last_r  <= SECTORS - 32'd1;
        end else begin
            cur_len_pre <= (song_sectors == 32'd0) ? SECTORS : song_sectors;
            cur_lba_r   <= (song_lba     == 32'd0) ? START_LBA : song_lba;
            cur_len_r   <= cur_len_pre;
            cur_last_r  <= cur_len_pre - 32'd1;
        end
    end

    always @(posedge sd_clk or posedge sd_rst) begin
        if (sd_rst) begin
            wr_bin <= 13'd0;
            wr_gray <= 13'd0;
            rd_sync1 <= 13'd0;
            rd_sync2 <= 13'd0;
            lo_byte <= 8'd0;
            lo_seen <= 1'b0;
            state <= IDLE;
            sd_lba <= START_LBA;
            sector_index <= 32'd0;
            song_done <= 1'b0;
        end else begin
            song_done <= 1'b0;                  // 一拍脉冲，默认清掉
            rd_sync1 <= rd_gray;
            rd_sync2 <= rd_sync1;
            case (state)
                IDLE: if (enable && used_sd <= 13'd3584) begin
                    sd_lba <= cur_lba_r + sector_index;
                    state <= READ;
                end
                READ: begin
                    if (sd_valid) begin
                        if (!lo_seen) begin
                            lo_byte <= sd_data;
                            lo_seen <= 1'b1;
                        end else begin
                            wr_bin <= wr_bin + 13'd1;
                            wr_gray <= ((wr_bin + 13'd1) >> 1) ^ (wr_bin + 13'd1);
                            lo_seen <= 1'b0;
                        end
                    end
                    if (sd_end) begin
                        // 放完本首最后一个扇区 -> 回到本首开头并通知顶层切下一首
                        if (sector_index >= cur_last_r) begin
                            sector_index <= 32'd0;
                            song_done    <= 1'b1;
                        end else begin
                            sector_index <= sector_index + 32'd1;
                        end
                        lo_seen <= 1'b0;
                        state <= GAP;
                    end
                end
                GAP: state <= IDLE; // Let CMD17 return to its wait state.
                default: state <= IDLE;
            endcase
            // 切歌：放在 case 之后，确保覆盖本拍 case 里可能发生的自增。
            // 当前扇区会先读完（最多 512 字节 ≈ 5ms 音频），所以切歌有极短残留，
            // 用户已确认可以接受。
            if (song_restart) sector_index <= 32'd0;
        end
    end

    always @(posedge audio_clk or posedge audio_rst) begin
        if (audio_rst) begin
            rd_bin <= 13'd0;
            rd_gray <= 13'd0;
            wr_sync1 <= 13'd0;
            wr_sync2 <= 13'd0;
            sample <= 16'sd0;
            started <= 1'b0;
            envelope <= 8'd0;
            peak <= 8'd0;
            peak_count <= 10'd0;
            lp1 <= 16'sd0;
            lp2 <= 16'sd0;
            pk_low <= 8'd0;
            pk_mid <= 8'd0;
            pk_high <= 8'd0;
            env_low <= 8'd0;
            env_mid <= 8'd0;
            env_high <= 8'd0;
        end else begin
            wr_sync1 <= wr_gray;
            wr_sync2 <= wr_sync1;
            if (used_audio >= 13'd512)
                started <= 1'b1;
            if (sample_tick) begin
                if (started && used_audio != 13'd0) begin
                                        // 【音量缩放已移除】属于 7 项菜单那一轮，回退时没退到源码，
                    // 一直挂在音频通路上 —— 疑似导致上板无声。恢复成原始样本。
                    sample <= fifo_read_data;
                    rd_bin <= rd_bin + 13'd1;
                    rd_gray <= ((rd_bin + 13'd1) >> 1) ^ (rd_bin + 13'd1);
                end else
                    sample <= 16'sd0;

                // 两个一阶低通（算术右移保留符号）
                lp1 <= lp1 + (df1 >>> 5);
                lp2 <= lp2 + (df2 >>> 2);

                if (magnitude[14:7] > peak)
                    peak <= magnitude[14:7];
                if (mag_low[14:7] > pk_low)
                    pk_low <= mag_low[14:7];
                if (mag_mid[14:7] > pk_mid)
                    pk_mid <= mag_mid[14:7];
                if (mag_high[14:7] > pk_high)
                    pk_high <= mag_high[14:7];

                if (peak_count == 10'd767) begin
                    envelope <= peak;
                    env_low  <= pk_low;
                    env_mid  <= pk_mid;
                    env_high <= pk_high;
                    peak <= 8'd0;
                    pk_low <= 8'd0;
                    pk_mid <= 8'd0;
                    pk_high <= 8'd0;
                    peak_count <= 10'd0;
                end else
                    peak_count <= peak_count + 10'd1;
            end
        end
    end
endmodule
