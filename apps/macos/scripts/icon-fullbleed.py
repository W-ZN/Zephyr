"""Zephyr's app icon, full bleed (design §8.3).

macOS 26 masks app icons to its own squircle and shrinks art that keeps transparent margins into a
gray tile. The source art (art/icon-art-1024.png: the paper on a rounded teal tile) keeps its
paper; this script lifts the paper off the tile and sets it on a full-bleed teal field, then writes
every size of AppIcon.appiconset.

usage: python apps/macos/scripts/icon-fullbleed.py   (numpy, scipy, Pillow)
"""
import os
import numpy as np
from PIL import Image, ImageFilter
HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, '..', 'art', 'icon-art-1024.png')
SET = os.path.join(HERE, '..', 'app', 'assets.xcassets', 'AppIcon.appiconset')
src = np.asarray(Image.open(ART).convert('RGB')).astype(np.float32) / 255
# The paper: light pixels inside the art's rounded square.
box = src[168:848, 248:782]
lum = box @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
alpha = np.clip((lum - 0.40) / (0.72 - 0.40), 0, 1)
bg = np.array([0.075, 0.33, 0.39], dtype=np.float32)
a = np.maximum(alpha, 1e-3)[..., None]
rgb = np.clip((box - (1 - a) * bg) / a, 0, 1)
glyph = Image.fromarray((np.dstack([rgb, alpha]) * 255).astype(np.uint8), 'RGBA')
from scipy import ndimage
labels, n = ndimage.label(alpha > 0.5)
sizes = ndimage.sum(np.ones_like(alpha), labels, range(1, n + 1))
keep = ndimage.binary_dilation(labels == (int(np.argmax(sizes)) + 1), iterations=4)
alpha = alpha * keep
glyph = Image.fromarray((np.dstack([rgb, alpha]) * 255).astype(np.uint8), 'RGBA')
ys, xs = np.nonzero(alpha > 0.05)
glyph = glyph.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
N = 1024
# Background: a quiet vertical gradient in the icon's teal, lighter at the top.
t = np.linspace(0, 1, N, dtype=np.float32)[:, None, None]
top, bottom = np.array([32, 108, 124], np.float32), np.array([9, 64, 78], np.float32)
canvas = np.broadcast_to(top * (1 - t) + bottom * t, (N, N, 3)).copy()
yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
glow = np.exp(-(((xx - N * 0.3) ** 2 + (yy - N * 0.18) ** 2) / (2 * (N * 0.42) ** 2)))[..., None]
canvas = canvas + glow * 18
out = Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), 'RGB').convert('RGBA')
h = int(N * 0.62)
w = int(glyph.width * h / glyph.height)
glyph = glyph.resize((w, h), Image.LANCZOS)
x, y = (N - w) // 2, (N - h) // 2 + 6
shadow = Image.new('RGBA', (N, N), (0, 0, 0, 0))
sa = glyph.split()[3].point(lambda v: v * 0.35)
shadow.paste((4, 30, 38, 255), (x, y + 18), sa)
shadow = shadow.filter(ImageFilter.GaussianBlur(22))
out = Image.alpha_composite(out, shadow)
out.alpha_composite(glyph, (x, y))
full = out.convert('RGB')
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        name = f'icon-{size}' + ('@2x' if scale == 2 else '') + '.png'
        full.resize((size * scale, size * scale), Image.LANCZOS).save(os.path.join(SET, name))
print('wrote', SET)
