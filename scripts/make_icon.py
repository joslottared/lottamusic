# Generates Resources/AppIcon.png (wired earbud on the Lotta gradient).
# Usage: python3 scripts/make_icon.py [tilt_degrees] [output]  e.g. 26 Resources/AppIcon.png
import sys, math
from PIL import Image, ImageDraw, ImageFilter

S = 4096                       # supersampled canvas, downscaled to 1024
TOP, BOT = (254, 93, 97), (196, 32, 74)   # same gradient as the old icon
ANGLE = math.radians(float(sys.argv[1]) if len(sys.argv) > 1 else 28)
OUT = sys.argv[2] if len(sys.argv) > 2 else "icon.png"

def lerp(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

bg = Image.new("RGB", (S, S))
d = ImageDraw.Draw(bg)
for y in range(S):
    d.line([(0, y), (S, y)], fill=lerp(TOP, BOT, y / (S - 1)))

# Earbud designed upright in local units (head centre at 0,0), then rotated
# and placed: OX/OY = where the head centre lands, U = px per unit.
OX, OY, U = 2200, 1420, 1.0
ca, sa = math.cos(ANGLE), math.sin(ANGLE)
def T(x, y): return (OX + (x * ca - y * sa) * U, OY + (x * sa + y * ca) * U)

def ellipse(cx, cy, rx, ry, n=360):
    return [T(cx + rx * math.cos(2 * math.pi * i / n), cy + ry * math.sin(2 * math.pi * i / n)) for i in range(n)]

def capsule(cx, y0, y1, r, n=90):
    pts = [(cx + r * math.cos(math.pi + math.pi * i / n), y0 + r * math.sin(math.pi + math.pi * i / n)) for i in range(n + 1)]
    pts += [(cx + r * math.cos(math.pi * i / n), y1 + r * math.sin(math.pi * i / n)) for i in range(n + 1)]
    return [T(x, y) for x, y in pts]

# --- body: bulb head + stem, joined with a smooth fillet ---
HEAD_RX, HEAD_RY = 640, 590
STEM_X, STEM_R = 210, 150
STEM_TOP, STEM_BOT = 250, 1500
body = Image.new("L", (S, S), 0)
b = ImageDraw.Draw(body)
b.polygon(ellipse(0, 0, HEAD_RX, HEAD_RY), fill=255)
b.polygon(capsule(STEM_X, STEM_TOP, STEM_BOT, STEM_R), fill=255)
# fillet: closing (blur + threshold) rounds the concave head/stem joint
body = body.filter(ImageFilter.GaussianBlur(70)).point(lambda v: 255 if v > 110 else 0)
body = body.filter(ImageFilter.GaussianBlur(3))

# --- cutouts: speaker grille on the bulb, ring where the cable joins ---
cut = Image.new("L", (S, S), 0)
c = ImageDraw.Draw(cut)
c.polygon(ellipse(-150, -130, 250, 165), fill=255)
ring_y = STEM_BOT - 260
c.polygon([T(STEM_X - STEM_R - 20, ring_y - 26), T(STEM_X + STEM_R + 20, ring_y - 26),
           T(STEM_X + STEM_R + 20, ring_y + 26), T(STEM_X - STEM_R - 20, ring_y + 26)], fill=255)
cut = cut.filter(ImageFilter.GaussianBlur(3))

# --- cable: stamped circles along a cubic bezier, exits the bottom edge ---
def bez(p, t):
    k = len(p) - 1
    return tuple(sum(math.comb(k, j) * (1 - t) ** (k - j) * t ** j * p[j][i] for j in range(k + 1)) for i in range(2))

tip = T(STEM_X, STEM_BOT + STEM_R - 40)
down = T(STEM_X, STEM_BOT + 700)   # keeps the cable leaving along the stem axis
ctrl = [tip, down, (1100, 3150), (1350, 4500)]
cable = Image.new("L", (S, S), 0)
cc = ImageDraw.Draw(cable)
R = 50
for i in range(3001):
    x, y = bez(ctrl, i / 3000)
    cc.ellipse([x - R, y - R, x + R, y + R], fill=255)
cable = cable.filter(ImageFilter.GaussianBlur(3))

shape = Image.new("L", (S, S), 0)
shape.paste(255, mask=cable)
shape.paste(255, mask=body)
shape.paste(0, mask=cut)

# soft drop shadow for a bit of depth
shadow = shape.filter(ImageFilter.GaussianBlur(70)).point(lambda v: int(v * 0.25))
bg.paste((105, 8, 38), (0, 50), shadow)
bg.paste((255, 255, 255), (0, 0), shape)
bg.resize((1024, 1024), Image.LANCZOS).save(OUT)
