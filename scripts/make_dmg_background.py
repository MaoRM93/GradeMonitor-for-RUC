#!/usr/bin/env python3
"""生成 DMG 安装窗口的背景图。

设计：浅色渐变 + 居中标题 + 横向箭头 + 底部「替换失败怎么办」提示。
输出 1x (600x400) 与 @2x (1200x800) 两档，喂给 Finder 的 background picture。

用法：
    python3 scripts/make_dmg_background.py <输出目录>
"""

import sys
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# 画布尺寸（= Finder 窗口的**内容区**尺寸）
# 注意 build_dmg.sh 里给 Finder 的 window bounds 是 内容区高度 + 标题栏高度，
# 否则背景图底部会被标题栏挤掉一条。
W, H = 600, 400

# 与 app_theme.dart 一致
PRIMARY = (30, 136, 229)      # 0xFF1E88E5
PRIMARY_DEEP = (21, 101, 192)  # 0xFF1565C0
INK = (15, 23, 42)             # 0xFF0F172A
INK_SOFT = (100, 116, 139)     # 0xFF64748B
INK_FAINT = (148, 163, 184)    # 0xFF94A3B8
CARD = (248, 250, 252)         # 0xFFF8FAFC

FONT_CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"

# Finder 里的图标位置（由 .DS_Store 设定），中心点
ICON_Y = 200
APP_CX = 150
DIR_CX = 450
ICON_SIZE = 128


def font(size, bold=False):
    """Hiragino Sans GB：index 0 = W3(常规), index 2 = W6(粗)。"""
    idx = 2 if bold else 0
    return ImageFont.truetype(FONT_CJK, size, index=idx)


def draw_vertical_gradient(img, top, bottom):
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)


def rounded_arrow(draw, x0, x1, y, thickness, color):
    """横向箭头：圆头线段 + 实心三角头。"""
    head_len = 26
    head_half = 15
    shaft_end = x1 - head_len + 4
    r = thickness // 2

    # 杆身
    draw.line([(x0 + r, y), (shaft_end, y)], fill=color, width=thickness)
    draw.ellipse([x0, y - r, x0 + thickness, y + r], fill=color)

    # 箭头
    draw.polygon(
        [(shaft_end, y - head_half), (x1, y), (shaft_end, y + head_half)],
        fill=color,
    )


def build(scale):
    """scale=1 输出 600x400，scale=2 输出 1200x800。"""
    global W, H
    base_w, base_h = W, H
    W, H = base_w * scale, base_h * scale
    img = Image.new("RGB", (W, H), (255, 255, 255))

    # 渐变底：顶部近白，往下略深，形成一点纵向层次
    draw_vertical_gradient(img, (255, 255, 255), (238, 242, 247))

    # 顶部一道极淡的主题色光晕，呼应 app 图标
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [-W * 0.25, -H * 0.9, W * 1.25, H * 0.42],
        fill=(120, 180, 255),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(110 * scale))
    img = Image.blend(img, Image.blend(img, glow, 0.0), 0.0)
    # 用屏幕混合把光晕叠上去（比 blend 更自然）
    from PIL import ImageChops

    img = ImageChops.screen(img, glow.point(lambda v: int(v * 0.42)))

    d = ImageDraw.Draw(img)

    def S(v):
        """按 scale 缩放坐标/字号。"""
        return v * scale

    # ── 标题 ──
    title = "安装 GradeMonitor"
    f_title = font(S(27), bold=True)
    tw = d.textbbox((0, 0), title, font=f_title)[2]
    d.text(((W - tw) / 2, S(46)), title, font=f_title, fill=INK)

    # ── 副标题 ──
    sub = "把左边的 App 拖到右边的 Applications 文件夹"
    f_sub = font(S(15))
    sw = d.textbbox((0, 0), sub, font=f_sub)[2]
    d.text(((W - sw) / 2, S(84)), sub, font=f_sub, fill=INK_SOFT)

    # ── 箭头（带柔光投影）──
    ax0, ax1 = S(APP_CX + ICON_SIZE / 2 + 38), S(DIR_CX - ICON_SIZE / 2 - 28)
    ay = S(ICON_Y)

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    rounded_arrow(
        sd, ax0, ax1, ay + S(3), S(7), (30, 136, 229, 46)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(S(4)))
    img = Image.alpha_composite(img.convert("RGBA"), shadow)

    d = ImageDraw.Draw(img)
    rounded_arrow(d, ax0, ax1, ay, S(7), PRIMARY)

    # ── 底部提示卡片 ──
    pad_x, card_top = S(38), S(285)
    card_bottom = S(374)
    d.rounded_rectangle(
        [pad_x, card_top, W - pad_x, card_bottom],
        radius=S(12),
        fill=(255, 255, 255),
        outline=(226, 232, 240),
        width=S(1),
    )

    f_tip = font(S(12))
    f_tip_b = font(S(12), bold=True)

    # 三行居中。注意：不要用 ⌥ 等特殊符号——Hiragino Sans GB 无该字形会画成豆腐块。
    tip_lines = [
        ("替换失败？", "先彻底退出旧版本再拖一次", f_tip_b, f_tip, INK),
        ("按住 Option 键 + 右键点 Dock 图标 → 退出", None, f_tip, None, INK_SOFT),
        ("旧版本还在运行，系统就不允许覆盖它", None, f_tip, None, INK_FAINT),
    ]

    y = S(299)
    step = S(22)
    for head, tail, f_head, f_tail, color in tip_lines:
        if tail is None:
            tw = d.textbbox((0, 0), head, font=f_head)[2]
            d.text(((W - tw) / 2, y), head, font=f_head, fill=color)
        else:
            hw = d.textbbox((0, 0), head, font=f_head)[2]
            tww = d.textbbox((0, 0), tail, font=f_tail)[2]
            x = (W - (hw + tww)) / 2
            d.text((x, y), head, font=f_head, fill=color)
            d.text((x + hw, y), tail, font=f_tail, fill=INK_SOFT)
        y += step

    img = img.convert("RGB")
    W, H = base_w, base_h
    return img


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)

    for scale, name in ((1, "background.png"), (2, "background@2x.png")):
        img = build(scale)
        path = os.path.join(out_dir, name)
        img.save(path, "PNG", optimize=True)
        print(f"{path}  {img.size[0]}x{img.size[1]}  {os.path.getsize(path)} bytes")


if __name__ == "__main__":
    main()
