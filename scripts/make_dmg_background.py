#!/usr/bin/env python3
"""生成 DMG 安装窗口的背景图。

设计稿是 `scripts/dmg_background.png`（1484x1060，比例 1.4）。
本脚本只负责把它缩放成 Finder 窗口内容区的尺寸，输出 1x 与 @2x 两档：

    1x  -> 700x500   （= WIN_W x WIN_H，见 build_dmg.sh）
    2x  -> 1400x1000 （Retina）

窗口尺寸必须与设计稿同比例，否则 Finder 会把背景拉伸变形。
1484:1060 == 700:500 == 1.4，所以取 700x500。

用法：
    python3 scripts/make_dmg_background.py <输出目录>
"""

import os
import sys

from PIL import Image

# 画布尺寸（= Finder 窗口的**内容区**尺寸，必须与 build_dmg.sh 的 WIN_W/WIN_H 一致）
W, H = 700, 500

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(SCRIPT_DIR, "dmg_background.png")


def build(scale: int) -> Image.Image:
    """把设计稿缩放到目标尺寸。"""
    src = Image.open(SOURCE).convert("RGB")
    size = (W * scale, H * scale)
    if src.size != size:
        # LANCZOS：缩小 2 倍以上时唯一不掉细节的重采样
        src = src.resize(size, Image.LANCZOS)
    return src


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: make_dmg_background.py <输出目录>", file=sys.stderr)
        return 2
    if not os.path.isfile(SOURCE):
        print(f"错误：找不到设计稿 {SOURCE}", file=sys.stderr)
        return 1

    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    build(1).save(os.path.join(out_dir, "background.png"), "PNG")
    build(2).save(os.path.join(out_dir, "background@2x.png"), "PNG")
    print(f"    背景图: {W}x{H} 与 {W * 2}x{H * 2} -> {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
