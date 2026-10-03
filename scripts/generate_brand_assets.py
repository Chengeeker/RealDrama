import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='从统一图形生成红果鉴 / 真果鉴平台资源；需要 Pillow。')
parser.add_argument('--output', type=Path, default=root)
parser.add_argument('--source', type=Path, default=root / 'assets/icon12-source.png')
parser.add_argument('--font', type=Path)
options = parser.parse_args()
output = options.output


def load_icon():
    source = Image.open(options.source)
    if 'A' in source.getbands() and source.getchannel('A').getextrema() != (255, 255):
        mark = source.convert('RGBA')
    else:
        source = source.convert('RGB')
        saturation = source.convert('HSV').getchannel('S')
        alpha = saturation.point(lambda value: max(0, min(255, round((value - 12) * 255 / 231))))
        mark = Image.new('RGBA', source.size, '#DE0E16')
        mark.putalpha(alpha)

    if mark.getchannel('A').point(lambda value: 255 if value >= 48 else 0).getbbox() is None:
        raise ValueError(f'图标源文件没有可识别的图形：{options.source}')

    width, height = mark.size
    side = max(width, height)
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(mark, ((side - width) // 2, (side - height) // 2))
    return canvas.resize((1024, 1024), Image.Resampling.LANCZOS)


def trim_icon(mark):
    bounds = mark.getchannel('A').point(lambda value: 255 if value >= 48 else 0).getbbox()
    width = bounds[2] - bounds[0]
    height = bounds[3] - bounds[1]
    padding = round(max(width, height) * 0.12)
    side = max(width, height) + padding * 2
    cropped = mark.crop(bounds)
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(
        cropped,
        (padding + (side - 2 * padding - width) // 2,
         padding + (side - 2 * padding - height) // 2),
    )
    return canvas


mark = load_icon()

platform_icon = Image.new('RGBA', mark.size, 'white')
platform_icon.alpha_composite(mark)


def save(image, name):
    destination = output / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)

save(platform_icon.convert('RGB'), 'assets/icon12.png')

for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    save(platform_icon.resize((size, size), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')

contents = json.loads((root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())
for entry in contents['images']:
    if 'filename' in entry:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        save(platform_icon.resize((size, size), Image.Resampling.LANCZOS).convert('RGB'),
             'ios/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename'])

save(platform_icon.resize((256, 256), Image.Resampling.LANCZOS), 'windows/runner/resources/app_icon.ico')

font_candidates = [options.font] if options.font else [
    Path('C:/Windows/Fonts/msyh.ttc'),
    Path('/System/Library/Fonts/PingFang.ttc'),
]
font_path = next((candidate for candidate in font_candidates if candidate and candidate.exists()), None)
if font_path is None:
    raise FileNotFoundError('未找到电视横幅所需字体，请使用 --font 指定字体文件。')
font = ImageFont.truetype(str(font_path), 76)
for name, resource in [('红果鉴', 'tv_banner'), ('真果鉴', 'tv_banner_all_sources')]:
    banner = Image.new('RGBA', (640, 360), '#101114')
    banner.alpha_composite(trim_icon(mark).resize((180, 180), Image.Resampling.LANCZOS), (44, 90))
    draw = ImageDraw.Draw(banner)
    draw.text((255, 128), name, font=font, fill='white')
    save(banner.convert('RGB'), f'android/app/src/main/res/drawable-xhdpi/{resource}.png')
