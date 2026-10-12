#!/usr/bin/env python3
"""Write a neutral, trademark-free app icon for the hub (AppIcon-hub.solidimagestack).

The per-target icon stacks under Assets.xcassets are gitignored (they are game
art), so a fresh checkout's hub has NO icon: CFBundleIconName falls back to a
placeholder that names no stack, and the Home View shows the blank default. That
is fine on a development install and not fine for App Store Connect, which wants
the app to carry an icon. This draws one from nothing — three 1024x1024 layers
(an opaque back, a translucent middle, a front glyph), the shape a visionOS icon
stack takes — so a TestFlight build has one without shipping anyone's artwork.

    python3 visionos/mk_hub_icon.py            # writes it only if it is missing
    python3 visionos/mk_hub_icon.py --force    # rewrites it

An existing stack (e.g. the user's own art) is never touched without --force.
Needs Pillow (python3 -m pip install pillow).
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STACK = os.path.join(HERE, "Assets.xcassets", "AppIcon-hub.solidimagestack")
N = 1024


def _contents(path, obj):
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def _layer(name, img):
    d = os.path.join(STACK, f"{name}.solidimagestacklayer")
    iset = os.path.join(d, "Content.imageset")
    os.makedirs(iset, exist_ok=True)
    img.save(os.path.join(iset, f"{name.lower()}.png"))
    _contents(iset, {"images": [{"filename": f"{name.lower()}.png", "idiom": "vision", "scale": "2x"}],
                     "info": {"author": "xcode", "version": 1}})
    _contents(d, {"info": {"author": "xcode", "version": 1}})


def main():
    if os.path.isdir(STACK) and "--force" not in sys.argv:
        print(f"  icon: keeping existing {os.path.relpath(STACK, HERE)}")
        return 0
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("!! mk_hub_icon.py needs Pillow (python3 -m pip install pillow)", file=sys.stderr)
        return 1

    # Back: opaque, a vertical indigo-to-teal gradient (a layer with alpha here is
    # rejected by the asset compiler for the back of a visionOS stack).
    back = Image.new("RGB", (N, N))
    px = back.load()
    top, bot = (28, 24, 64), (12, 92, 112)
    for y in range(N):
        t = y / (N - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        for x in range(N):
            px[x, y] = c

    # Middle: a soft ring, the "hub".
    mid = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(mid)
    r_out, r_in = 360, 300
    c = N // 2
    d.ellipse([c - r_out, c - r_out, c + r_out, c + r_out], fill=(255, 255, 255, 70))
    d.ellipse([c - r_in, c - r_in, c + r_in, c + r_in], fill=(0, 0, 0, 0))

    # Front: a play triangle, optically centred.
    front = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(front)
    s = 190
    pts = [(c - s * 0.75 + 30, c - s), (c - s * 0.75 + 30, c + s), (c + s + 30, c)]
    d.polygon(pts, fill=(255, 255, 255, 255))
    # Four small dots around the ring: the games the hub carries.
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        x, y = c + 330 * math.cos(a), c + 330 * math.sin(a)
        d.ellipse([x - 26, y - 26, x + 26, y + 26], fill=(255, 255, 255, 220))

    os.makedirs(STACK, exist_ok=True)
    _layer("Front", front)
    _layer("Middle", mid)
    _layer("Back", back)
    _contents(STACK, {"info": {"author": "xcode", "version": 1},
                      "layers": [{"filename": "Front.solidimagestacklayer"},
                                 {"filename": "Middle.solidimagestacklayer"},
                                 {"filename": "Back.solidimagestacklayer"}]})
    print(f"  icon: wrote {os.path.relpath(STACK, HERE)} (neutral placeholder)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
