import sys, os, json
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

# Characters: split on empty column gaps.
chars = Image.open(os.path.join(src, 'minerush-characters.png')).convert('RGBA')
alpha = chars.getchannel('A')
w, h = chars.size
filled = [any(alpha.getpixel((x, y)) > 24 for y in range(0, h, 2)) for x in range(w)]
runs, start = [], None
for x, f in enumerate(filled + [False]):
    if f and start is None: start = x
    if not f and start is not None:
        runs.append((start, x)); start = None
runs = [r for r in runs if r[1] - r[0] > 40]
print('character columns:', runs)
assert len(runs) == 3, runs
for name, (x0, x1) in zip(['worker_milo', 'worker_pip', 'worker_bolt'], runs):
    imageset(name, square(chars.crop((x0, 0, x1, h)), 512))

def drop_border_bits(img):
    # Remove alpha islands that touch the cell edge (slivers of neighbouring icons).
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
    # Small islands on the edge are neighbours' slivers; the icon itself may touch the edge.
    kill = [p for c, edge in comps if edge and len(c) < biggest * 0.25 for p in c]
    out = img.copy()
    op = out.load()
    for x, y in kill:
        op[x, y] = (0, 0, 0, 0)
    return out

# Icons: 3x3 grid.
icons = Image.open(os.path.join(src, 'minerush-icons.png')).convert('RGBA')
names = ['icon_bomb', 'icon_flag', 'icon_coin', 'icon_gem', 'icon_chest', 'icon_pickaxe',
         'icon_scanner', 'icon_helmet', 'icon_explosion']
cw, ch = icons.width / 3, icons.height / 3
for i, name in enumerate(names):
    r, c = divmod(i, 3)
    cell = icons.crop((int(c * cw), int(r * ch), int((c + 1) * cw), int((r + 1) * ch)))
    imageset(name, square(drop_border_bits(cell), 256))

# Backdrops: three vertical panels, trimmed in from the seams.
bg = Image.open(os.path.join(src, 'minerush-backdrops.png')).convert('RGB')
pw = bg.width / 3
for i, name in enumerate(['bg_sunnyQuarry', 'bg_crystalCaves', 'bg_volcanoVault']):
    panel = bg.crop((int(i * pw) + 10, 0, int((i + 1) * pw) - 10, bg.height))
    imageset(name, panel.resize((600, 1200), Image.LANCZOS), fmt='jpeg')

# App icon: opaque 1024.
icon = Image.open(os.path.join(src, 'minerush-appicon.png')).convert('RGB').resize((1024, 1024), Image.LANCZOS)
icon.save(os.path.join(assets, 'AppIcon.appiconset', 'icon-1024.png'), optimize=True)

# Contact sheet for review.
sheet = Image.new('RGBA', (1280, 900), (255, 246, 232, 255))
for i, n in enumerate(['worker_milo', 'worker_pip', 'worker_bolt']):
    sheet.alpha_composite(Image.open(os.path.join(assets, f'{n}.imageset', f'{n}.png')).resize((240, 240)), (20 + i * 250, 20))
for i, n in enumerate(names):
    sheet.alpha_composite(Image.open(os.path.join(assets, f'{n}.imageset', f'{n}.png')).resize((120, 120)), (20 + i * 135, 280))
for i, n in enumerate(['bg_sunnyQuarry', 'bg_crystalCaves', 'bg_volcanoVault']):
    sheet.paste(Image.open(os.path.join(assets, f'{n}.imageset', f'{n}.jpg')).resize((200, 400)), (20 + i * 210, 420))
sheet.paste(icon.resize((400, 400)), (860, 420))
sheet.save(sys.argv[3])
print('ok')
