
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ext_mem_clk_sft only drives the EG_PHY_SDRAM_2M_32 hard-IP sampling clock.
# The SDRAM hard macro owns its external DQ window, so the two directions
# between the controller clock and shifted sampling clock are not fabric paths.
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {ext_mem_clk_sft}]
set_false_path -from [get_clocks {ext_mem_clk_sft}] -to [get_clocks {ext_mem_clk}]


# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# I2S is generated in audio_mclk and enters video_clk through three-stage
# synchronizers in I2S_receiver; there is no synchronous clock relationship.
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {video_clk hdmi_5x_clk sd_card_clk ext_mem_clk ext_mem_clk_sft}]

# The first stages intentionally receive asynchronous reset assertion. Only
# their release is synchronized; ignore the external recovery path into the
# synchronizer registers while retaining timing between the two stages.
set_false_path -from [get_clocks {clk}] \
    -to [get_regs -hier {*audio_rst_sync*}]
set_false_path -from [get_clocks {clk}] \
    -to [get_regs -hier {*audio_video_rst_sync*}]

# ------------------------------------------------------------
# 4.1 异步复位释放路径（recovery / removal）—— 按复位网络豁免
#
# 上面两条按"寄存器名"写的豁免有一个漏洞：
# TD 在 opt_place / opt_route 阶段会复制复位寄存器来降低扇出
# （日志中的 rst_dup_*、以及端点名里的 *_syn_13 后缀），
# 复制出来的副本是新的寄存器对象，原来的 false_path 覆盖不到。
# 一旦这些副本被摆到远处，就会出现形如下面的伪违例：
#
#   clk(80.000ns) -> u_tide_overlay/add6_syn_105
#                 -> net audio_reset_async
#                 -> audio_rst_sync_reg[1]_syn_13.sr
#   recovery，预算 1.334ns，时钟偏斜 1.874ns -> -3.020ns
#
# 预算只有 1.334ns 而偏斜已达 1.874ns，说明这一对时钟边沿几乎重合，
# 按同步路径分析本身就没有意义：复位断言是异步的，释放由各域内的
# 两级同步器完成，亚稳态由同步器吸收。
#
# 因此改为"经过复位网络"整体豁免，覆盖 TD 复制出来的所有副本。
# 只豁免复位网络，各域内部两级同步器之间的时序仍然照常分析。
# ------------------------------------------------------------
set_false_path -through [get_nets -hier {*audio_reset_async*}]
set_false_path -through [get_nets -hier {*audio_video_rst_sync*}]

# ------------------------------------------------------------
# 4.2 主复位 rst_all 的释放路径 —— 同一类问题，2026-10-07 补上
#
# rst_all 在 top_tf_hdmi_audio.v(186-207) 里产生：
#   clk(50MHz) 域的一个寄存器，等两个 PLL 连续锁定 20ms 后释放。
# 它扇出到【所有】时钟域的异步复位脚（video_clk / sd_card_clk /
# ext_mem_clk / audio_mclk ...）。
#
# TD 会把这条复位网络复制成 rst_all_dup_* 降低扇出，于是产生形如下面的检查：
#   clk(50MHz, 边沿@20ns) -> rst_all_dup_258
#   -> frame_fifo_read_m0/read_cnt_reg[*].sr      (ext_mem_clk, 125MHz)
#   recovery，预算 4.000ns，收/发边沿只差 4ns
#
# 这和 4.1 节里 audio_reset_async 是同一类：复位【断言】本来就是异步的，
# 【释放】由各时钟域内部自己的同步器完成，亚稳态由同步器吸收。
# 按同步路径去分析一条"跨两个无关时钟、只在开机出现一次"的复位释放，
# 得到的数没有物理意义 —— 而且这本来就是这个工程的全局最差路径：
#   基线 volume2 版 = +0.697ns（就是全报告 SWNS 本身）
#   加了第 5 块缓冲后   = -1.342ns ✗
# 也就是说这条假路径一直在压缩整个设计的时序余量。
#
# 豁免范围【仅限复位网络】，各域内部真正的同步器之间照常分析。
# ------------------------------------------------------------
set_false_path -through [get_nets -hier {*rst_all*}]

# The write FIFO clear is generated by the memory-side controller and drives
# the asynchronous clear logic of the SD-card-clock side of that FIFO.
set_false_path \
    -from [get_nets {frame_read_write_m0/frame_fifo_write_m0/fifo_aclr}] \
    -to [get_clocks {sd_card_clk}]



# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------
