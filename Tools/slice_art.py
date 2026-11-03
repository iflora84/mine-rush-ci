"""Slices the ChatGPT art sheets in design-canvas/art into the asset catalog.

Usage: python Tools/slice_art.py design-canvas/art App/Assets.xcassets contact.png
"""
import json
import os
import sys

from PIL import Image

src, assets = sys.argv[1], sys.argv[2]


def imageset(name, img, fmt='png'):
    d = os.path.join(assets, f'{name}.imageset')
    os.makedirs(d, exist_ok=True)
    fn = f'{name}.{"jpg" if fmt == "jpeg" else "png"}'
    if fmt == 'jpeg':
        img.convert('RGB').save(os.path.join(d, fn), quality=88, optimize=True)
    else:
        img.save(os.path.join(d, fn), optimize=True)
    json.dump({'images': [{'idiom': 'universal', 'filename': fn}], 'info': {'author': 'xcode', 'version': 1}},
              open(os.path.join(d, 'Contents.json'), 'w'), indent=2)


def square(img, size, pad=0.06):
    bbox = img.getchannel('A').point(lambda a: 255 if a > 24 else 0).getbbox()
    img = img.crop(bbox)
    side = int(max(img.size) * (1 + pad * 2))
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def drop_border_bits(img):
    """Removes small alpha islands touching the cell edge (slivers of neighbouring icons)."""
    a = img.getchannel('A')
    w, h = img.size
    px = a.load()
    seen = bytearray(w * h)
    comps = []
    for sy in range(h):
        for sx in range(w):
            if seen[sy * w + sx] or px[sx, sy] <= 24:
                continue
            stack, comp, edge = [(sx, sy)], [], False
            seen[sy * w + sx] = 1
            while stack:
                x, y = stack.pop()
                comp.append((x, y))
                if x == 0 or y == 0 or x == w - 1 or y == h - 1:
                    edge = True
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] and px[nx, ny] > 24:
                        seen[ny * w + nx] = 1
                        stack.append((nx, ny))
            comps.append((comp, edge))
    biggest = max(len(c) for c, _ in comps)
    # The icon itself may touch the edge; only small edge islands are slivers.
    kill = [p for c, edge in comps if edge and len(c) < biggest * 0.25 for p in c]
    out = img.copy()
    op = out.load()
    for x, y in kill:
        op[x, y] = (0, 0, 0, 0)
    return out


def column_sheet(filename, names, size):
    """A row of characters on transparency, split on empty column gaps."""
    sheet = Image.open(os.path.join(src, filename)).convert('RGBA')
    alpha = sheet.getchannel('A')
    w, h = sheet.size
    filled = [any(alpha.getpixel((x, y)) > 24 for y in range(0, h, 2)) for x in range(w)]
    runs, start = [], None
    for x, f in enumerate(filled + [False]):
        if f and start is None:
            start = x
        if not f and start is not None:
            runs.append((start, x))
            start = None
    runs = [r for r in runs if r[1] - r[0] > 40]
    print(filename, 'columns:', runs)
    assert len(runs) == len(names), runs
    for name, (x0, x1) in zip(names, runs):
        imageset(name, square(sheet.crop((x0, 0, x1, h)), size))


def grid_sheet(filename, names, cols, size):
    sheet = Image.open(os.path.join(src, filename)).convert('RGBA')
    rows = (len(names) + cols - 1) // cols
    cw, ch = sheet.width / cols, sheet.height / rows
    for i, name in enumerate(names):
        r, c = divmod(i, cols)
        cell = sheet.crop((int(c * cw), int(r * ch), int((c + 1) * cw), int((r + 1) * ch)))
        imageset(name, square(drop_border_bits(cell), size))


workers = ['worker_milo', 'worker_pip', 'worker_bolt']
bosses = ['boss_sunnyQuarry', 'boss_crystalCaves', 'boss_volcanoVault']
icons = ['icon_bomb', 'icon_flag', 'icon_coin', 'icon_gem', 'icon_chest', 'icon_pickaxe',
         'icon_scanner', 'icon_helmet', 'icon_explosion']
powerups = ['powerup_dynamite', 'powerup_radar', 'powerup_magnet', 'powerup_xray']
backdrops = ['bg_sunnyQuarry', 'bg_crystalCaves', 'bg_volcanoVault']

column_sheet('minerush-characters.png', workers, 512)
column_sheet('minerush-bosses.png', bosses, 640)
grid_sheet('minerush-icons.png', icons, 3, 256)
grid_sheet('minerush-powerups.png', powerups, 2, 256)

bg = Image.open(os.path.join(src, 'minerush-backdrops.png')).convert('RGB')
pw = bg.width / 3
for i, name in enumerate(backdrops):
    panel = bg.crop((int(i * pw) + 10, 0, int((i + 1) * pw) - 10, bg.height))
    imageset(name, panel.resize((600, 1200), Image.LANCZOS), fmt='jpeg')

icon = Image.open(os.path.join(src, 'minerush-appicon.png')).convert('RGB').resize((1024, 1024), Image.LANCZOS)
icon.save(os.path.join(assets, 'AppIcon.appiconset', 'icon-1024.png'), optimize=True)


def load(name, ext='png'):
    return Image.open(os.path.join(assets, f'{name}.imageset', f'{name}.{ext}')).convert('RGBA')


sheet = Image.new('RGBA', (1280, 1160), (255, 246, 232, 255))
for i, n in enumerate(workers):
    sheet.alpha_composite(load(n).resize((240, 240)), (20 + i * 250, 20))
for i, n in enumerate(bosses):
    sheet.alpha_composite(load(n).resize((240, 240)), (20 + i * 250, 270))
for i, n in enumerate(icons):
    sheet.alpha_composite(load(n).resize((120, 120)), (20 + i * 135, 530))
for i, n in enumerate(powerups):
    sheet.alpha_composite(load(n).resize((120, 120)), (800 + (i % 2) * 135, 20 + (i // 2) * 135))
for i, n in enumerate(backdrops):
    sheet.paste(load(n, 'jpg').resize((200, 400)), (20 + i * 210, 680))
sheet.paste(icon.resize((400, 400)), (860, 680))
sheet.save(sys.argv[3])
print('ok')
