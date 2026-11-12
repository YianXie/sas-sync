"""Draw the SAS Bulletin app icon (1024px, supersampled) and build an .icns."""
import math, subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).parent
S = 4096                       # supersample canvas; downscaled to 1024
K = S / 1024
NAVY_TOP, NAVY_BOT = (22, 46, 104), (8, 20, 52)
RED = (200, 16, 46)
GOLD_A, GOLD_B = (255, 205, 64), (240, 150, 20)
INK = (70, 82, 110)


def k(*v):
    return [x * K for x in v]


def vgrad(size, top, bot):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        g.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return g.resize(size)


def rmask(box, r):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, r, fill=255)
    return m


img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- tile (macOS grid: 824px body inside 1024, radius ~185) ---
tile = k(100, 100, 924, 924)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(k(100, 118, 924, 942), 185 * K, fill=(0, 0, 0, 110))
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * K)))
bg = vgrad((S, S), NAVY_TOP, NAVY_BOT).convert("RGBA")
img.paste(bg, (0, 0), rmask(tile, 185 * K))
# soft top sheen
sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sheen).ellipse(k(-60, -420, 1084, 520), fill=(255, 255, 255, 26))
img.alpha_composite(Image.composite(sheen, Image.new("RGBA", (S, S)), rmask(tile, 185 * K)))

# --- paper sheet ---
paper = k(250, 230, 734, 800)
ps = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ps).rounded_rectangle(k(250, 250, 734, 820), 44 * K, fill=(0, 0, 0, 120))
img.alpha_composite(ps.filter(ImageFilter.GaussianBlur(16 * K)))
d = ImageDraw.Draw(img)
d.rounded_rectangle(paper, 44 * K, fill=(250, 250, 252))
# red masthead (rounded top only)
head = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(head).rectangle(k(250, 230, 734, 360), fill=RED + (255,))
img.alpha_composite(Image.composite(head, Image.new("RGBA", (S, S)), rmask(paper, 44 * K)))
d = ImageDraw.Draw(img)
d.rounded_rectangle(k(298, 278, 560, 312), 17 * K, fill=(255, 255, 255, 235))   # title bar
d.rounded_rectangle(k(590, 278, 686, 312), 17 * K, fill=(255, 255, 255, 140))   # date chip

# --- bullet rows ---
for i, y in enumerate([430, 530, 630, 730]):
    if y > 740:
        break
    col = RED if i == 0 else INK
    d.ellipse(k(300, y - 22, 344, y + 22), fill=col)
    w = [300, 250, 280][i % 3] if i < 3 else 200
    d.rounded_rectangle(k(372, y - 17, 372 + w, y + 17), 17 * K, fill=(200, 206, 220))

# --- gold star badge ---
cx, cy, R = 728, 712, 150
bs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(bs).ellipse(k(cx - R, cy - R + 14, cx + R, cy + R + 14), fill=(0, 0, 0, 130))
img.alpha_composite(bs.filter(ImageFilter.GaussianBlur(14 * K)))
badge = vgrad((S, S), GOLD_A, GOLD_B).convert("RGBA")
bm = Image.new("L", (S, S), 0)
ImageDraw.Draw(bm).ellipse(k(cx - R, cy - R, cx + R, cy + R), fill=255)
img.paste(badge, (0, 0), bm)
d = ImageDraw.Draw(img)
d.ellipse(k(cx - R, cy - R, cx + R, cy + R), outline=(255, 255, 255), width=int(16 * K))
pts = []
for j in range(10):
    a = -math.pi / 2 + j * math.pi / 5
    r = 92 if j % 2 == 0 else 40
    pts.append(((cx + r * math.cos(a)) * K, (cy + 6 + r * math.sin(a)) * K))
d.polygon(pts, fill=(255, 255, 255))

icon = img.resize((1024, 1024), Image.LANCZOS)
icon.save(OUT / "icon_1024.png")

# --- iconset -> icns ---
iset = OUT / "SASBulletin.iconset"
iset.mkdir(exist_ok=True)
for s in (16, 32, 128, 256, 512):
    icon.resize((s, s), Image.LANCZOS).save(iset / f"icon_{s}x{s}.png")
    icon.resize((s * 2, s * 2), Image.LANCZOS).save(iset / f"icon_{s}x{s}@2x.png")
subprocess.run(["iconutil", "-c", "icns", str(iset), "-o", str(OUT / "AppIcon.icns")], check=True)
print("ok")
