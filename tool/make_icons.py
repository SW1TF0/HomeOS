"""Draws the SmartMenuKJ app icon, the house from the smarthomekj.eu logo on black, for every platform.

    python3 tool/make_icons.py

rewrites the Android, iOS, macOS, Windows and Linux icons and docs/icon.png. Needs Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BLACK, WHITE, BLUE = '#000000', '#FFFFFF', '#0071E3'

# The house on a 1 x 1 square: roof and walls, then the door cut into them.
HOUSE = [(0.5, 0.0), (1.0, 0.44), (0.88, 0.44), (0.88, 1.0), (0.12, 1.0), (0.12, 0.44), (0.0, 0.44)]
DOOR = (0.38, 0.6, 0.62, 1.0)


def shapes(height, cx, cy):
    """The house [height] tall, centred on (cx, cy): its outline as points and its door as a box."""
    left, top = cx - height / 2, cy - height / 2
    house = [(left + x * height, top + y * height) for x, y in HOUSE]
    x0, y0, x1, y1 = DOOR
    door = (left + x0 * height, top + y0 * height, left + x1 * height, top + y1 * height)
    return house, door


def icon(size, shape):
    """The icon as an image. shape: 'square' (full bleed), 'rounded' or 'mac' (rounded, with a margin)."""
    scale = 4  # draw big, then shrink, for smooth edges
    big = size * scale
    image = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    inset = round(big * 100 / 1024) if shape == 'mac' else 0
    box = big - 2 * inset
    if shape == 'square':
        draw.rectangle((0, 0, big, big), fill=BLACK)
    else:
        draw.rounded_rectangle((inset, inset, big - inset - 1, big - inset - 1), radius=box * 0.225, fill=BLACK)
    house, door = shapes(box * (0.62 if size < 40 else 0.5), big / 2, big / 2 - box * 0.01)
    draw.polygon(house, fill=WHITE)
    draw.rectangle(door, fill=BLUE)
    image = image.resize((size, size), Image.LANCZOS)
    return image.convert('RGB') if shape == 'square' else image


def vector(monochrome=False):
    """An Android vector drawable of the house, on the 108 x 108 dp adaptive icon canvas (66 dp safe circle)."""
    house, (x0, y0, x1, y1) = shapes(40, 54, 53)
    outline = 'M' + 'L'.join(f'{x:.2f},{y:.2f}' for x, y in house) + 'z'
    door = f'M{x0:.2f},{y0:.2f}H{x1:.2f}V{y1:.2f}H{x0:.2f}z'
    if monochrome:
        # One colour only: the door is cut out of the house.
        body = f'\n    <path android:fillColor="{WHITE}" android:fillType="evenOdd" android:pathData="{outline}{door}" />'
    else:
        body = (f'\n    <path android:fillColor="{WHITE}" android:pathData="{outline}" />'
                f'\n    <path android:fillColor="{BLUE}" android:pathData="{door}" />')
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
