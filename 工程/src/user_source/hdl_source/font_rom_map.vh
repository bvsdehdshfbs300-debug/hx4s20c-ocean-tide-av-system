// 自动生成，请勿手改 —— 由 gen_font.py 产出
// 段A 中文16x16  base=0  每字32字节
// 段B 中文32x32  base=1344  每字128字节
// 段C ASCII8x16  base=2368  每字16字节
// 段D 中文16x16  base=2992  每字32字节（新增段，A/B/C 基址不变）
// 段E 中文32x32  base=3472  每字128字节（原生高清片名）
// 段F ASCII16x32 base=5776  每字64字节（原生高清副标题）
localparam FONT_A_BASE = 13'd0;
localparam FONT_B_BASE = 13'd1344;
localparam FONT_C_BASE = 13'd2368;
localparam FONT_D_BASE = 13'd2992;
localparam FONT_E_BASE = 13'd3472;
localparam FONT_F_BASE = 13'd5776;
// 段G 中文16x16  base=6672  每字32字节（7 项菜单文字）
localparam FONT_G_BASE = 13'd6672;
