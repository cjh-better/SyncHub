#!/usr/bin/env python3
"""Generates AppIcon.icns (flat blue rounded square, white ↑↓ arrows). Re-run only if you want to tweak the icon."""
import io, struct
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
m = 100                                     # macOS icon grid: 824px body inside 1024 canvas
d.rounded_rectangle([m, m + 6, S - m, S - m + 6], radius=185, fill=(0, 0, 0, 40))   # soft shadow
d.rounded_rectangle([m, m, S - m, S - m], radius=185, fill=(0, 122, 255, 255))
W = (255, 255, 255, 255)
def arrow(cx, top, bottom, up):
    shaft, head_w, head_h = 46, 190, 150
    if up:
        d.polygon([(cx, top), (cx - head_w // 2, top + head_h), (cx + head_w // 2, top + head_h)], fill=W)
        d.rounded_rectangle([cx - shaft // 2, top + head_h - 10, cx + shaft // 2, bottom], radius=23, fill=W)
    else:
        d.polygon([(cx, bottom), (cx - head_w // 2, bottom - head_h), (cx + head_w // 2, bottom - head_h)], fill=W)
        d.rounded_rectangle([cx - shaft // 2, top, cx + shaft // 2, bottom - head_h + 10], radius=23, fill=W)
arrow(400, 290, 734, True)
arrow(624, 290, 734, False)

def png(size):
    b = io.BytesIO(); img.resize((size, size), Image.LANCZOS).save(b, "PNG"); return b.getvalue()
entries = [(b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
           (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512)]
body = b"".join(t + struct.pack(">I", 8 + len(p)) + p for t, p in ((t, png(s)) for t, s in entries))
open("AppIcon.icns", "wb").write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
img.resize((256, 256), Image.LANCZOS).save("AppIcon_preview.png")
print("ok")
