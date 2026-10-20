# 从透明品牌图生成 macOS 26 风格圆角图标。
# 源图：frontend/assets/app_icon_tb.png（透明底，蓝色文档 + 勾选）
# 输出：Windows ICO、macOS PNG/ICNS。
import shutil
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "frontend" / "assets"
RUNNER_RESOURCES = ROOT / "frontend" / "windows" / "runner" / "resources"
MACOS_ICONS = (
    ROOT / "frontend" / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
)

SIZE = 1024
SOURCE = ASSETS / "app_icon_tb.png"
WINDOWS_ICO = ASSETS / "app_icon.ico"
RUNNER_ICO = RUNNER_RESOURCES / "app_icon.ico"

# macOS 图标留出约 8% 画布边距，Windows 图标留约 3%，避免任务栏里显得过小。
WINDOWS_MARGIN = 32
MACOS_MARGIN = 80

# 图形在圆角底板内的占比；在上一版基础上缩到 80%，留出更充足的安全边距。
ART_SHRINK = 0.8
WINDOWS_ART_RATIO = 0.82 * ART_SHRINK
MACOS_ART_RATIO = 0.84 * ART_SHRINK
# 图形本身视觉重心略偏左，向右补偿约 3% 底板宽度。
ART_OFFSET_X_RATIO = 0.03

ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
MACOS_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def _rounded_mask(size: int, box: tuple[int, int, int, int], radius: int) -> Image.Image:
    """生成连续圆角遮罩；4 倍超采样后缩小，边缘更平滑。"""
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        tuple(value * scale for value in box),
        radius=radius * scale,
        fill=255,
    )
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def _make_tile(margin: int, art_ratio: float) -> Image.Image:
    source = Image.open(SOURCE).convert("RGBA")
    art = source.crop(source.getchannel("A").getbbox())

    box = (margin, margin, SIZE - margin, SIZE - margin)
    tile_width = box[2] - box[0]
    tile_height = box[3] - box[1]
    radius = int(min(tile_width, tile_height) * 0.225)
    mask = _rounded_mask(SIZE, box, radius)

    # 极浅的纵向冷白渐变，保持品牌蓝色为主，不引入新色相。
    tile = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    pixels = tile.load()
    top_color = (255, 255, 255)
    bottom_color = (243, 248, 255)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        color = tuple(
            round(top_color[i] * (1 - t) + bottom_color[i] * t)
            for i in range(3)
        ) + (255,)
        for x in range(SIZE):
            pixels[x, y] = color
    tile.putalpha(mask)

    scale = min(tile_width * art_ratio / art.width, tile_height * art_ratio / art.height)
    art_width = max(1, round(art.width * scale))
    art_height = max(1, round(art.height * scale))
    art = art.resize((art_width, art_height), Image.Resampling.LANCZOS)
    art_x = (
        margin
        + (tile_width - art_width) // 2
        + round(tile_width * ART_OFFSET_X_RATIO)
    )
    art_y = margin + (tile_height - art_height) // 2
    tile.alpha_composite(art, (art_x, art_y))

    # 浅色内边，让白色图标在浅色桌面上也有清晰边界。
    border_width = 3
    border_scale = 4
    border_mask = Image.new("L", (SIZE * border_scale, SIZE * border_scale), 0)
    border_draw = ImageDraw.Draw(border_mask)
    border_box = tuple(value * border_scale for value in box)
    border_draw.rounded_rectangle(
        border_box, radius=radius * border_scale, fill=255
    )
    inner_box = tuple(
        value * border_scale
        for value in (
            box[0] + border_width,
            box[1] + border_width,
            box[2] - border_width,
            box[3] - border_width,
        )
    )
    border_draw.rounded_rectangle(
        inner_box,
        radius=max(0, radius - border_width) * border_scale,
        fill=0,
    )
    border_mask = border_mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    border = Image.new("RGBA", (SIZE, SIZE), (220, 232, 247, 255))
    border.putalpha(border_mask)
    tile.alpha_composite(border)
    return tile


def main() -> None:
    windows_icon = _make_tile(WINDOWS_MARGIN, art_ratio=WINDOWS_ART_RATIO)
    windows_icon.save(WINDOWS_ICO, format="ICO", sizes=ICO_SIZES)
    shutil.copyfile(WINDOWS_ICO, RUNNER_ICO)

    macos_icon = _make_tile(MACOS_MARGIN, art_ratio=MACOS_ART_RATIO)
    MACOS_ICONS.mkdir(parents=True, exist_ok=True)
    for size in MACOS_SIZES:
        macos_icon.resize((size, size), Image.Resampling.LANCZOS).save(
            MACOS_ICONS / f"app_icon_{size}.png"
        )
    macos_icon.save(
        MACOS_ICONS / "app_icon.icns",
        format="ICNS",
        sizes=[(size, size) for size in MACOS_SIZES],
    )

    print(f"Windows ICO: {WINDOWS_ICO}")
    print(f"Runner ICO:  {RUNNER_ICO}")
    print(f"macOS icons: {MACOS_ICONS}")


if __name__ == "__main__":
    main()
