//============================================================================
// osd_menu.v —— 菜单状态机（模态）
//
// 放在 sd_card_clk 域：按键就在这里去抖（key_press_debounce），
// 菜单状态跟着按键走最自然。渲染在 video_clk 域，靠 menu_on / item_sel
// 两级同步过去 —— 这两个信号变化极慢（人手按键），两级同步足够。
//
// 【模态的代价】菜单打开时会屏蔽 K1/K2/K3 的原功能（切图 / 启停轮播 / 周期）。
// 缓解手段有三条：
//   1) 10 秒无操作自动退出
//   2) 面板底部常驻按键提示
//   3) 菜单有明确的视觉状态（面板 + 高亮条），不会让人分不清自己在哪一层
//
// 按键分配（菜单打开时）：
//   K1 = 上移一项      K2 = 下移一项      K3 = 调整当前项      K4 = 退出
// 菜单关闭时 K1/K2/K3 恢复本来的功能，K4 = 进入菜单。
//============================================================================
module osd_menu #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer TIMEOUT_MS  = 10000          // 无操作自动退出时间
)(
    input  wire       clk,
    input  wire       rst,
    // 已去抖的按键脉冲（都是一拍）
    input  wire       key_up,                      // K1 上移
    input  wire       key_down,                    // K2 下移
    input  wire       key_adj,                     // K3 调整
    input  wire       key_menu,                    // K4 进出菜单
    // 控制输出（都是一拍脉冲，交给 sd_card_bmp 去执行）
    output reg        cmd_song_next,               // 切下一首歌
    output reg        cmd_mode_toggle,             // 自动/手动 切换
    output reg        cmd_period_next,             // 周期 1/3/5 切换
    // 拓展项 ②③④ 的状态
    output reg  [2:0] trans_sel,                   // 0 DEFAULT, 1 SLIDE, 2 WAVE, 3 BLADE, 4 RIPPLE, 5 DITHER
    // 【2026-10-06 改】缩放从"4 档模式"简化成"开/关"：
    //   开 = 显示图1的推近版，关 = 正常显示原图。
    //   实现方式是切模式时重载缓冲0（装原图1 还是装推近版），
    //   所以不需要第 5 块帧缓冲，也不用动任何地址端口和位宽。
    output reg        zoom_on,                     // 缩放 1=推近 0=原样
    output reg        info_on,                     // 分辨率/缩放比 OSD 开关
    // 【2026-10-06 新增】音乐播放开关
    //   名字用「播放」而不是「暂停」：菜单字模用的是段G 那 19 个字
    //   （歌曲播放模式轮周期转场方缩信息显示系统），里面【没有】"暂停"两个字，
    //   但有"播""放"—— 用「播放」当项名就不用重新生成字库。
    output reg        music_on,                    // 1=播放 0=暂停
    output reg  [2:0] vol_sel,                     // 音量档位 0..6（2026-10-06 新增）
    output reg  [1:0] brightness_sel,              // 亮度档位 0/1/2/3 = 25/50/75/100%
    output reg  [2:0] contrast_sel,                // 对比度档位 0..6 = 50/75/90/100/110/125/150%
    // 菜单状态（要同步到视频域去渲染）
    output reg        menu_on,
    output reg  [3:0] item_sel
);
    // 9 项：歌曲 / 播放 / 音量 / 亮度 / 对比度 / 转场 / 缩放 / 信息 / 轮播周期。
    localparam [3:0] ITEM_LAST = 4'd8;

    localparam [31:0] TIMEOUT_CYC = CLK_FREQ_HZ / 1000 * TIMEOUT_MS;

    reg [31:0] idle_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            menu_on         <= 1'b0;
            item_sel        <= 4'd0;
            idle_cnt        <= 32'd0;
            cmd_song_next   <= 1'b0;
            cmd_mode_toggle <= 1'b0;
            cmd_period_next <= 1'b0;
            trans_sel       <= 3'd0;               // DEFAULT: existing fade out / fade in
            zoom_on         <= 1'b0;               // 默认：不缩放
            info_on         <= 1'b1;               // 默认：显示分辨率/缩放比
            music_on        <= 1'b1;               // 默认：播放
            vol_sel         <= 3'd4;               // 默认：中档
            brightness_sel  <= 2'd3;               // 默认：100%
            contrast_sel    <= 3'd3;               // 默认：100%
        end else begin
            // 三个命令都是一拍脉冲，默认清掉
            cmd_song_next   <= 1'b0;
            cmd_mode_toggle <= 1'b0;
            cmd_period_next <= 1'b0;

            if (key_menu) begin
                // K4：进出菜单。每次进来都从第一项开始，避免"上次停在哪"的困惑
                menu_on  <= ~menu_on;
                item_sel <= 4'd0;
                idle_cnt <= 32'd0;
            end else if (menu_on) begin
                // ---- 超时计数 ----
                if (key_up || key_down || key_adj) begin
                    idle_cnt <= 32'd0;                 // 有操作就重置
                end else if (idle_cnt < TIMEOUT_CYC) begin
                    idle_cnt <= idle_cnt + 32'd1;
                end else begin
                    menu_on <= 1'b0;                   // 超时自动淡出
                end

                // ---- 上下选择（回绕）----
                if (key_up) begin
                    item_sel <= (item_sel == 4'd0) ? ITEM_LAST
                                                   : (item_sel - 4'd1);
                end else if (key_down) begin
                    // 【修 3 位溢出】原来写的是 (item_sel + 3'd1 >= ITEM_COUNT)，
                    // item_sel 是 3 位，到 7 时 7+1 在 3 位里溢出成 0，
                    // 比较恒为假 -> 直接跳回第一项（上板现象：K2 无论在哪都跳回第一项）。
                    // 改成先判断"是不是最后一项"，再加。
                    item_sel <= (item_sel >= ITEM_LAST) ? 4'd0
                                                        : (item_sel + 4'd1);
                end

                // ---- K3 调整当前项 ----
                if (key_adj) begin
                    case (item_sel)
                        4'd0:    cmd_song_next    <= 1'b1;  // 歌曲
                        // 【2026-10-06】第 2 项 = 播放（音乐开关）。
                        //   原来它在第 8 项，但菜单渲染只画前 7 行 -> 根本没显示出来。
                        //   挪到第 2 项后一定画得出来，位置也更顺手。
                        4'd1:    music_on        <= ~music_on;   // 播放（音乐开/关）
                        // 【2026-10-06】第3项改成音量（7 档循环）；轮播周期和第7项对调
                        4'd2:    vol_sel <= (vol_sel >= 3'd6) ? 3'd0 : (vol_sel + 3'd1);
                        // 亮度四档：25/50/75/100%，三通道使用同一增益。
                        4'd3:    brightness_sel <= (brightness_sel == 2'd3)
                                                    ? 2'd0 : (brightness_sel + 2'd1);
                        // 对比度七档：50/75/90/100/110/125/150%，默认 100%。
                        4'd4:    contrast_sel <= (contrast_sel >= 3'd6)
                                                  ? 3'd0 : (contrast_sel + 3'd1);
                        // 拓展②③④：状态就存在本模块里（跟着按键走最自然），
                        // 一起同步到 video_clk 域去渲染。
                        4'd5:    trans_sel <= (trans_sel >= 3'd5) ? 3'd0
                                                                 : (trans_sel + 3'd1);
                        // 缩放：开/关两档（切模式会让 sd_card_bmp 重载缓冲1）
                        4'd6:    zoom_on   <= ~zoom_on;
                        4'd7:    info_on   <= ~info_on;
                        // 系统信息：只读，不响应
                        // 【2026-10-06】第7项改回轮播周期（原来这里是只读的系统信息）
                        4'd8:    cmd_period_next <= 1'b1;
                        // 7 项菜单，没有第 8 项了（播放模式自动/手动 用 K2 实体键切，
                        // 底栏那行也有显示，功能不丢）
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
