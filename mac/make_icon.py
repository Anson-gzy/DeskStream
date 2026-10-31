#!/usr/bin/env python3
"""Draws the app icon (three desks, each a stream of windows) into DeskStream/Assets.xcassets/AppIcon.appiconset.
python3 make_icon.py — rerun after changing the drawing; the PNGs are generated, don't edit them."""
import json, os, numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'DeskStream/Assets.xcassets/AppIcon.appiconset')

def body(S):
    """the full-bleed artwork: blue gradient, three columns of window cards"""
    g = np.linspace(0, 1, S)[:, None]
    top, bot = np.array([96, 168, 255]), np.array([30, 92, 222])
    grad = (top * (1 - g) + bot * g).astype(np.uint8)
    im = Image.fromarray(np.repeat(grad[:, None, :], S, 1).reshape(S, S, 3)).convert('RGBA')
    d = ImageDraw.Draw(im)
    cols = [[.30, .22], [.18, .26, .14], [.36]]
    cw, gap, x = S * .2, S * .07, S * .135
    for col in cols:
        y = S * .16
        for h in col:
            d.rounded_rectangle([x, y, x + cw, y + S * h], radius=S * .03, fill=(255, 255, 255, 235))
            y += S * h + S * .045
        x += cw + gap
    return im

def icon(px):
    # macOS grid: on a 1024 canvas the shape is 824 wide at 100 in, corner 185, with a soft drop shadow
    S = 1024 * 2
    b = round(S * 824 / 1024); o = (S - b) // 2
    mask = Image.new('L', (b, b)); ImageDraw.Draw(mask).rounded_rectangle([0, 0, b - 1, b - 1], radius=b * 185 / 824, fill=255)
    shadow = Image.new('L', (S, S)); shadow.paste(mask, (o, o + S * 12 // 1024))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 14 / 1024)).point(lambda v: v * 0.32)
    canvas = Image.composite(Image.new('RGBA', (S, S), (0, 0, 0, 255)), Image.new('RGBA', (S, S), (0, 0, 0, 0)), shadow)
    art = body(b); art.putalpha(mask)
    canvas.alpha_composite(art, (o, o))
    return canvas.resize((px, px), Image.LANCZOS)

os.makedirs(OUT, exist_ok=True)
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f'icon_{pt}x{pt}{"@2x" if scale == 2 else ""}.png'
        icon(pt * scale).save(os.path.join(OUT, name))
        images.append({'idiom': 'mac', 'size': f'{pt}x{pt}', 'scale': f'{scale}x', 'filename': name})
json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, open(os.path.join(OUT, 'Contents.json'), 'w'), indent=2)
json.dump({'info': {'author': 'xcode', 'version': 1}}, open(os.path.join(OUT, '..', 'Contents.json'), 'w'), indent=2)
