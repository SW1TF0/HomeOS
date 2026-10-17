"""Draws the SmartMenuKJ app icon, a dot-matrix S on black, for every platform.

    python3 tool/make_icons.py

rewrites the Android, iOS, macOS, Windows and Linux icons and docs/icon.png. Needs Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BLACK, WHITE, RED = '#000000', '#FFFFFF', '#D71921'

# The S on a dot grid: '#' a white dot, 'R' the red one.
S = ['..####.',
     '.#....R',
     '#......',
     '#......',
     '.#####.',
     '......#',
     '......#',
     '#....#.',
     '.####..']
# The same S for icons too small for round dots, drawn pixel-sharp.
SMALL = ['.###R',
         '#....',
         '#....',
         '.###.',
         '....#',
         '....#',
         '####.']
DOT = 0.8  # dot diameter, as a share of the distance between dots


def dots(height, cx, cy, glyph=S):
    """Yields (x, y, radius, colour) of every dot of a glyph [height] tall, centred on (cx, cy)."""
    rows, cols = len(glyph), len(glyph[0])
    pitch = height / (rows - 1 + DOT)
    left, top = cx - (cols - 1) * pitch / 2, cy - (rows - 1) * pitch / 2
    for r, line in enumerate(glyph):
        for c, ch in enumerate(line):
            if ch != '.':
                yield left + c * pitch, top + r * pitch, DOT * pitch / 2, RED if ch == 'R' else WHITE


def icon(size, shape):
    """The icon as an image. shape: 'square' (full bleed), 'rounded' or 'mac' (rounded, with a margin)."""
    if size < 40:
        return small_icon(size, shape)
    scale = 4  # draw big, then shrink, for smooth dots
    big = size * scale
    image = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    inset = round(big * 100 / 1024) if shape == 'mac' else 0
    box = big - 2 * inset
    if shape == 'square':
        draw.rectangle((0, 0, big, big), fill=BLACK)
    else:
        draw.rounded_rectangle((inset, inset, big - inset - 1, big - inset - 1), radius=box * 0.225, fill=BLACK)
    for x, y, r, colour in dots(box * 0.6, big / 2, big / 2):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=colour)
    image = image.resize((size, size), Image.LANCZOS)
    return image.convert('RGB') if shape == 'square' else image


def small_icon(size, shape):
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if shape == 'square':
        draw.rectangle((0, 0, size, size), fill=BLACK)
    else:
        draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=max(2, size // 5), fill=BLACK)
    pitch = max(2, round(size * 0.6 / 7))
    dot = pitch if pitch == 2 else pitch - 1
    width, height = 4 * pitch + dot, 6 * pitch + dot
    left, top = (size - width) // 2, (size - height) // 2
    for r, line in enumerate(SMALL):
        for c, ch in enumerate(line):
            if ch != '.':
                x, y = left + c * pitch, top + r * pitch
                draw.rectangle((x, y, x + dot - 1, y + dot - 1), fill=RED if ch == 'R' else WHITE)
    return image.convert('RGB') if shape == 'square' else image


def vector(monochrome=False):
    """An Android vector drawable of the dots, on the 108 x 108 dp adaptive icon canvas (66 dp safe circle)."""
    paths = {}
    for x, y, r, colour in dots(44, 54, 54):
        paths.setdefault(WHITE if monochrome else colour, []).append(
            f'M{x - r:.2f},{y:.2f}a{r:.2f},{r:.2f} 0 1,0 {2 * r:.2f},0a{r:.2f},{r:.2f} 0 1,0 {-2 * r:.2f},0z')
    body = ''.join(f'\n    <path android:fillColor="{c}" android:pathData="{"".join(p)}" />' for c, p in paths.items())
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Made by tool/make_icons.py. -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:width="108dp" android:height="108dp"\n'
            f'    android:viewportWidth="108" android:viewportHeight="108">{body}\n</vector>\n')


def main():
    res = ROOT / 'android/app/src/main/res'
    for folder, size in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        icon(size, 'rounded').save(res / f'mipmap-{folder}/ic_launcher.png')
    (res / 'drawable/ic_launcher_foreground.xml').write_text(vector())
    (res / 'drawable/ic_launcher_monochrome.xml').write_text(vector(monochrome=True))

    ios = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for path in ios.glob('Icon-App-*.png'):
        points, factor = path.stem.removeprefix('Icon-App-').split('@')
        icon(round(float(points.split('x')[0]) * int(factor.removesuffix('x'))), 'square').save(path)

    mac = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for path in mac.glob('app_icon_*.png'):
        icon(int(path.stem.removeprefix('app_icon_')), 'mac').save(path)

    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    icons = [icon(s, 'rounded') for s in sizes]
    icons[-1].save(ROOT / 'windows/runner/resources/app_icon.ico', sizes=[(s, s) for s in sizes], append_images=icons[:-1])

    icon(256, 'rounded').save(ROOT / 'assets/icon.png')
    icon(1024, 'rounded').save(ROOT / 'docs/icon.png')


if __name__ == '__main__':
    main()
