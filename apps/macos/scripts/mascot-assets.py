# Builds the assistant images in assets.xcassets from the generated line art (design §8.2).
#
#   python apps/macos/scripts/mascot-assets.py SOURCE_DIR
#
# SOURCE_DIR holds the chosen drawings on white: avatar.png (head and shoulders), and optionally
# thinking.png and wave.png. Each becomes an image set with a light and a dark appearance: the
# white background is cut out (the outer edge unmixed from white). The character keeps its paper
# in dark mode, like a sticker, only dimmed; swapping ink and paper turned the eyes into white
# disks.
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "app" / "assets.xcassets"
SOURCE = Path(sys.argv[1])

INK = np.array([0x2F, 0x2E, 0x2B], float)        # line color of the drawings
DIM = 0.9                                        # paper brightness in dark mode

# name: (source file, crop as fractions of a bounding box (left, top, right, bottom), output px, file
# whose bounding box is used). The thinking pose is cropped like the avatar, so the face stays put
# when the state changes even though its wind swirl widens the drawing.
SETS = {
    "AssistantAvatar": ("avatar.png", (0.0, -0.03, 1.0, 0.80), 192, "avatar.png"),
    "AssistantThinking": ("thinking.png", (0.0, -0.03, 1.0, 0.80), 192, "avatar.png"),
    "AssistantWave": ("wave.png", (0.0, 0.0, 1.0, 1.0), 480, "wave.png"),
}


def cut_out(path):
    rgb = np.asarray(Image.open(path).convert("RGB"), float)
    near_white = rgb.min(axis=2) > 242
    labels, _ = ndimage.label(near_white)
    edge = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    background = np.isin(labels, edge[edge > 0])
    alpha = np.where(background, 0.0, 1.0)
    # The outer edge is line color blended with white: recover its coverage.
    band = ndimage.binary_dilation(background, iterations=2) & ~background
    lum = rgb.mean(axis=2)
    coverage = np.clip((255 - lum) / (255 - INK.mean()), 0, 1)
    alpha[band] = coverage[band]
    rgb[band] = INK
    return rgb, alpha


def crop(rgb, alpha, box, size, reference):
    ys, xs = np.nonzero(reference > 0.05)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    w, h = x1 - x0, y1 - y0
    l, t, r, b = x0 + box[0] * w, y0 + box[1] * h, x0 + box[2] * w, y0 + box[3] * h
    side = max(r - l, b - t) * 1.06
    cx, cy = (l + r) / 2, (t + b) / 2
    img = Image.fromarray(np.dstack([rgb, alpha * 255]).astype(np.uint8), "RGBA")
    img = img.crop((int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2)))
    return img.resize((size, size), Image.LANCZOS)


def darken(img):
    a = np.asarray(img, float)
    return Image.fromarray(np.concatenate([a[..., :3] * DIM, a[..., 3:]], axis=2).astype(np.uint8), "RGBA")


for name, (file, box, size, like) in SETS.items():
    if not (SOURCE / file).exists():
        continue
    folder = ASSETS / f"{name}.imageset"
    folder.mkdir(exist_ok=True)
    rgb, alpha = cut_out(SOURCE / file)
    light = crop(rgb, alpha, box, size, cut_out(SOURCE / like)[1])
    light.save(folder / f"{name}.png", optimize=True)
    darken(light).save(folder / f"{name}-dark.png", optimize=True)
    contents = {
        "images": [
            {"filename": f"{name}.png", "idiom": "universal"},
            {"filename": f"{name}-dark.png", "idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}]},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(name, light.size)
