#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_font.py —— 为屏幕 OSD 生成点阵字库

输出两份：
  1. font_rom.hex   —— $readmemh 格式（每行一个字节，十六进制）
  2. font_rom.v     —— 同数据的 Verilog 包（含地址常量，供 tide_overlay 引用）

字库分三段（地址连续，用 base + code*bytes 定位）：

  段A 中文 16x16   12 字   base=0      每字 32 字节
  段B 中文 32x32    8 字   base=384    每字 128 字节
  段C ASCII 8x16   39 字   base=1408   每字 16 字节
  合计 2032 字节 -> 2048（11 位地址）

每个字的点阵按行存放，每行按字节从左到右（MSB = 最左像素）。
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_HAN = r"C:\Windows\Fonts\msyh.ttc"      # 微软雅黑
FONT_MONO = r"C:\Windows\Fonts\consola.ttf"  # Consolas（等宽，适合 8x16）

# ---- 段A：中文 16x16（片名 + 底部元信息 + 菜单）----
# 前 13 个字是常驻字幕用的，后 25 个是菜单用的。
# 【这个顺序就是字库编码】改动它等于改动 RTL 里的字符码，两边必须同步。
A_CHARS = ("潮汐作曲家自动轮播间隔秒手"      # 0..12  常驻字幕
           "歌曲放模式周期"                  # 13..19 菜单项
           "亮度对比音量"                    # 20..24 菜单项
           "系统信息"                        # 25..28 菜单项
           "设置选择调整退出"                # 29..37 标题与按键提示
           "奶蛙大队")                        # 38..41 制作方署名
# ---- 段B：中文 32x32（场景名）----
B_CHARS = "晨潮晴海暮港夜航"                  # 8 字
# ---- 段C：ASCII 8x16 ----
C_CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ/."
# ---- 段D：中文 16x16（开场动画片头卡的"正式名称"行）----
# 【为什么单独开一段、而且放在最后】
#   段A/B/C 的基址已经【写死】在 tide_overlay.v 的 faddr 里
#   （0 / 1344 / 2368）。往 A_CHARS 里插字会把 B/C 的基址整体顶走，
#   而 KNOWN_ISSUES 专门记过"字库基址改了但 RTL 没同步"这个坑。
#   所以新增的字【一律往后摞成新段】，已有三段一个字节都不动。
#
# 内容 = 「基于 FPGA 的海洋音画实时生成装置」里段A没有的那些字。
# 「」留着是为了以后要换成 STATE.md 里的正式全称
#   基于 FPGA 的「潮汐作曲家」海洋音画实时生成装置
D_CHARS = "基于的海洋音画实时生成装置「」"    # 15 字

# ---- 段E：中文 32x32（原生高清，不再靠 16x16 放大 2 倍）----
#   用户反馈"文字块状"——16x16 放大 2 倍必然是方块堆的。用原生 32x32 才细腻。
#   这 18 个字同时供给【片头卡】和【主界面顶部片名】。
E_CHARS = "潮汐作曲家基于的海洋音画实时生成装置"      # 18 字
# ---- 段F：ASCII 16x32（片头卡的 TIDE COMPOSER 与 FPGA）----
#   第 0 个是【空格】—— "TIDE COMPOSER" 中间要用，段F 里必须自带，
#   因为一个 run 只能用一段字库（不能跨段取字）。
#   之后 13 个字母：T I D E C O M P S R F G A
F_CHARS = " TIDECOMPSRFGA"                           # 14 字（含空格）

# ---- 段G：中文 16x16（7 项菜单的菜单项文字）----
# 【为什么要重做一份】一个 run 只能用【一段】字库（ofont 是每个 run 一个），
#   菜单项文字是一条 run，7 项要用到的 19 个字必须【全部】在这段里 ——
#   哪怕段A 已经有「放/式/信/息/系/统」，也得在这里再做一份。
#   7 项文字：歌曲 / 播放 / 音量 / 轮播周期 / 转场方式 / 缩放 / 信息显示
# 【2026-10-06】末尾追加「音量」两个字（码 19、20）—— 音量做成 7 档放菜单第 3 项。
#   段G 是最后一段，加字只影响 TOTAL，前面所有段的基址一个字节都不动 ✓
G_CHARS = "歌曲播放模式轮周期转场方缩信息显示系统音量亮度正在"  # 25 字（菜单 + 播放字幕）

A_W, A_H, A_BYTES = 16, 16, 32
B_W, B_H, B_BYTES = 32, 32, 128
C_W, C_H, C_BYTES = 8, 16, 16
D_W, D_H, D_BYTES = 16, 16, 32
E_W, E_H, E_BYTES = 32, 32, 128
F_W, F_H, F_BYTES = 16, 32, 64
G_W, G_H, G_BYTES = 16, 16, 32
A_BASE = 0
B_BASE = A_BASE + len(A_CHARS) * A_BYTES       # 0 + 13*32   = 416
C_BASE = B_BASE + len(B_CHARS) * B_BYTES       # 416 + 8*128 = 1440
D_BASE = C_BASE + len(C_CHARS) * C_BYTES       # 2368 + 39*16 = 2992
E_BASE = D_BASE + len(D_CHARS) * D_BYTES       # 2992 + 15*32 = 3472
F_BASE = E_BASE + len(E_CHARS) * E_BYTES       # 3472 + 18*128 = 5776
G_BASE = F_BASE + len(F_CHARS) * F_BYTES       # 5776 + 14*64 = 6672
TOTAL  = G_BASE + len(G_CHARS) * G_BYTES       # 6672 + 19*32 = 7280
# 地址位宽自动计算：原来写死 11 位，字库一超过 2048 字节就会高位被截断。
ADDR_BITS = max(11, (TOTAL - 1).bit_length())
ADDR_MAX  = (1 << ADDR_BITS) - 1


def render(ch, w, h, font_path, size, dx=0, dy=0):
    """把一个字渲染成 w*h 的 1bpp 点阵，返回行列表，每行是字符串 '0101...'"""
    SS = 4                                        # 4 倍超采样再阈值化，边缘干净
    img = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(img)
    try:
        f = ImageFont.truetype(font_path, size * SS)
    except Exception:
        f = ImageFont.load_default()
    # 用 anchor 让字居中；中文字形自带边距
    bb = d.textbbox((0, 0), ch, font=f)
    gw, gh = bb[2] - bb[0], bb[3] - bb[1]
    x = (w * SS - gw) // 2 - bb[0] + dx * SS
    y = (h * SS - gh) // 2 - bb[1] + dy * SS
    d.text((x, y), ch, font=f, fill=255)
    img = img.resize((w, h), Image.LANCZOS)
    px = img.load()
    rows = []
    for yy in range(h):
        rows.append("".join("1" if px[xx, yy] > 110 else "0" for xx in range(w)))
    return rows


def pack(rows, w):
    """行点阵 -> 字节序列（每行 w/8 字节，MSB 在最左）"""
    out = []
    for r in rows:
        for b in range(w // 8):
            v = 0
            for k in range(8):
                if r[b * 8 + k] == "1":
                    v |= (0x80 >> k)
            out.append(v)
    return out


def blank(w, h):
    return ["0" * w for _ in range(h)]


def main():
    data = bytearray(TOTAL)

    # ---- 段A：中文 16x16 ----
    for i, ch in enumerate(A_CHARS):
        rows = render(ch, A_W, A_H, FONT_HAN, 15)
        by = pack(rows, A_W)
        off = A_BASE + i * A_BYTES
        data[off:off + A_BYTES] = bytes(by)

    # ---- 段B：中文 32x32 ----
    for i, ch in enumerate(B_CHARS):
        rows = render(ch, B_W, B_H, FONT_HAN, 31)
        by = pack(rows, B_W)
        off = B_BASE + i * B_BYTES
        data[off:off + B_BYTES] = bytes(by)

    # ---- 段C：ASCII 8x16 ----
    for i, ch in enumerate(C_CHARS):
        rows = render(ch, C_W, C_H, FONT_MONO, 13) if ch != " " else blank(C_W, C_H)
        by = pack(rows, C_W)
        off = C_BASE + i * C_BYTES
        data[off:off + C_BYTES] = bytes(by)

    # ---- 段D：中文 16x16（片头卡正式名称）----
    for i, ch in enumerate(D_CHARS):
        rows = render(ch, D_W, D_H, FONT_HAN, 15)
        by = pack(rows, D_W)
        off = D_BASE + i * D_BYTES
        data[off:off + D_BYTES] = bytes(by)

    # ---- 段E：中文 32x32（原生高清片名/片头卡大字）----
    for i, ch in enumerate(E_CHARS):
        rows = render(ch, E_W, E_H, FONT_HAN, 31)
        by = pack(rows, E_W)
        off = E_BASE + i * E_BYTES
        data[off:off + E_BYTES] = bytes(by)

    # ---- 段F：ASCII 16x32（原生高清副标题）----
    for i, ch in enumerate(F_CHARS):
        rows = render(ch, F_W, F_H, FONT_MONO, 28) if ch != " " else blank(F_W, F_H)
        by = pack(rows, F_W)
        off = F_BASE + i * F_BYTES
        data[off:off + F_BYTES] = bytes(by)

    # ---- 段G：中文 16x16（7 项菜单文字）----
    for i, ch in enumerate(G_CHARS):
        rows = render(ch, G_W, G_H, FONT_HAN, 15)
        by = pack(rows, G_W)
        off = G_BASE + i * G_BYTES
        data[off:off + G_BYTES] = bytes(by)

    # ---- 输出 hex ----
    hex_path = os.path.join(HERE, "font_rom.hex")
    with open(hex_path, "w", encoding="ascii") as f:
        for v in data:
            f.write("%02x\n" % v)

    # ---- 输出 Verilog 常量包 ----
    v_path = os.path.join(HERE, "font_rom_map.vh")
    with open(v_path, "w", encoding="utf-8") as f:
        f.write("// 自动生成，请勿手改 —— 由 gen_font.py 产出\n")
        f.write("// 段A 中文16x16  base=%d  每字%d字节\n" % (A_BASE, A_BYTES))
        f.write("// 段B 中文32x32  base=%d  每字%d字节\n" % (B_BASE, B_BYTES))
        f.write("// 段C ASCII8x16  base=%d  每字%d字节\n" % (C_BASE, C_BYTES))
        f.write("// 段D 中文16x16  base=%d  每字%d字节（新增段，A/B/C 基址不变）\n"
                % (D_BASE, D_BYTES))
        f.write("// 段E 中文32x32  base=%d  每字%d字节（原生高清片名）\n"
                % (E_BASE, E_BYTES))
        f.write("// 段F ASCII16x32 base=%d  每字%d字节（原生高清副标题）\n"
                % (F_BASE, F_BYTES))
        f.write("localparam FONT_A_BASE = %d'd%d;\n" % (ADDR_BITS, A_BASE))
        f.write("localparam FONT_B_BASE = %d'd%d;\n" % (ADDR_BITS, B_BASE))
        f.write("localparam FONT_C_BASE = %d'd%d;\n" % (ADDR_BITS, C_BASE))
        f.write("localparam FONT_D_BASE = %d'd%d;\n" % (ADDR_BITS, D_BASE))
        f.write("localparam FONT_E_BASE = %d'd%d;\n" % (ADDR_BITS, E_BASE))
        f.write("localparam FONT_F_BASE = %d'd%d;\n" % (ADDR_BITS, F_BASE))
        f.write("// 段G 中文16x16  base=%d  每字%d字节（7 项菜单文字）\n"
                % (G_BASE, G_BYTES))
        f.write("localparam FONT_G_BASE = %d'd%d;\n" % (ADDR_BITS, G_BASE))

    # ---- 输出字库 ROM 模块（组合读，综合成 LUT ROM）----
    # 为什么不用 BRAM：BRAM 读有一拍延迟，会打乱整条视频流水线的像素对齐；
    # 组合读虽然多花约 1500~2000 LUT，但完全不动时序，风险最低。
    # 注意：Verilog 源文件保持纯 ASCII 注释（TD 对非 ASCII 源码不友好）
    rom_path = os.path.join(HERE, "font_rom.v")
    with open(rom_path, "w", encoding="ascii") as f:
        f.write("// AUTO-GENERATED by gen_font.py -- do not edit by hand.\n")
        f.write("// On-screen OSD bitmap font, %d bytes, combinational read.\n" % TOTAL)
        f.write("// segA CJK 16x16 base=%d / segB CJK 32x32 base=%d / segC ASCII 8x16 base=%d\n"
                % (A_BASE, B_BASE, C_BASE))
        f.write("module font_rom(\n")
        f.write("    input  wire [%d:0] addr,\n" % (ADDR_BITS - 1))
        f.write("    output reg  [7:0]  dout\n")
        f.write(");\n")
        f.write("    always @* begin\n")
        f.write("        case (addr)\n")
        for i, v in enumerate(data):
            f.write("            %d'd%d: dout = 8'h%02x;\n" % (ADDR_BITS, i, v))
        f.write("            default: dout = 8'h00;\n")
        f.write("        endcase\n")
        f.write("    end\n")
        f.write("endmodule\n")

    # ---- 自检：打印几个字的点阵，肉眼确认没渲染错 ----
    print("总字节数:", TOTAL, " 地址位宽:", ADDR_BITS, " (容量 %d)" % ADDR_MAX)
    for label, chars, base, w, h, nb in (
            ("A 16x16", A_CHARS, A_BASE, A_W, A_H, A_BYTES),
            ("B 32x32", B_CHARS, B_BASE, B_W, B_H, B_BYTES),
            ("C 8x16", C_CHARS, C_BASE, C_W, C_H, C_BYTES),
            ("D 16x16 新增", D_CHARS, D_BASE, D_W, D_H, D_BYTES),
            ("E 32x32 原生", E_CHARS, E_BASE, E_W, E_H, E_BYTES),
            ("F 16x32 ASCII", F_CHARS, F_BASE, F_W, F_H, F_BYTES),
            ("G 16x16 菜单", G_CHARS, G_BASE, G_W, G_H, G_BYTES)):
        print("\n--- %s ---" % label)
        for i in range(min(2, len(chars))):
            off = base + i * nb
            print("  [%d] %r" % (i, chars[i]))
            for r in range(h):
                row = ""
                for b in range(w // 8):
                    row += format(data[off + r * (w // 8) + b], "08b")
                print("      " + row.replace("0", "·").replace("1", "█"))
    print("\n已写出:", hex_path)
    print("已写出:", v_path)


if __name__ == "__main__":
    main()
