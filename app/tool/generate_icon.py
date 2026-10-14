"""Generates the codeaw launcher icon and launch screen artwork.

The geometry below is the single source of truth. It is written out as:

- Android vector drawables (adaptive icon layers, API 26+) and the legacy
  mipmap PNGs (API 24-25), rasterised with Pillow;
- the Android splash icon and the iOS launch images: the icon circle with an
  empty bubble, which the Flutter launch animation then types `>_` into;
- the iOS app icons;
- lib/ui/common/codeaw_icon.dart, the same paths for the Flutter launch animation.

    python tool/generate_icon.py                    # from app/
    python tool/generate_icon.py --preview out.png  # also render a mockup sheet

Requires Pillow and numpy.
"""

import argparse
import json
import math
from pathlib import Path as FsPath

import numpy as np
from PIL import Image, ImageChops, ImageDraw

APP = FsPath(__file__).resolve().parent.parent
RES = APP / "android/app/src/main/res"
IOS = APP / "ios/Runner/Assets.xcassets"
DART = APP / "lib/ui/common/codeaw_icon.dart"

# Adaptive icon canvas: 108x108, of which the centre 72x72 is visible and the
# centre 66-diameter circle is never masked.
CANVAS = 108
VIEWPORT = 72

GRADIENT_START = "#19B59F"  # top-left
GRADIENT_END = "#0B7A6C"  # bottom-right
BUBBLE = "#FFFFFF"

# Android 12+ lays a splash icon without an icon background out in a 288 dp box
# and masks it to a 192 dp circle. The art is scaled so that the visible 72-unit
# circle is 160 dp wide, the size Android uses for the default launcher icon.
SPLASH_BOX = 288
SPLASH_SCALE = 160 / 192

# App surfaces from lib/ui/common/app_theme.dart; only used by the preview sheet.
SURFACES = ("#FCFCFE", "#151820")


class Path:
    """Minimal path builder that emits SVG path data and flattens to polygons."""

    def __init__(self):
        self._d = []
        self._polys = []

    def move(self, p):
        self._d.append(f"M{_n(p[0])},{_n(p[1])}")
        self._polys.append([p])
        return self

    def line(self, p):
        self._d.append(f"L{_n(p[0])},{_n(p[1])}")
        self._polys[-1].append(p)
        return self

    def cubic(self, c1, c2, p, steps=48):
        p0 = self._polys[-1][-1]
        self._d.append(f"C{_n(c1[0])},{_n(c1[1])} {_n(c2[0])},{_n(c2[1])} {_n(p[0])},{_n(p[1])}")
        for i in range(1, steps + 1):
            t = i / steps
            u = 1 - t
            self._polys[-1].append((
                u**3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t**3 * p[0],
                u**3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t**3 * p[1],
            ))
        return self

    def arc(self, c, r, a0, a1, steps=48):
        """Circular arc around c from angle a0 to a1 (degrees, y axis down).

        The current point must already be at angle a0.
        """
        end = _polar(c, r, a1)
        large = 1 if abs(a1 - a0) > 180 else 0
        sweep = 1 if a1 > a0 else 0
        self._d.append(f"A{_n(r)},{_n(r)} 0 {large} {sweep} {_n(end[0])},{_n(end[1])}")
        for i in range(1, steps + 1):
            self._polys[-1].append(_polar(c, r, a0 + (a1 - a0) * i / steps))
        return self

    def close(self):
        self._d.append("Z")
        return self

    def __add__(self, other):
        out = Path()
        out._d = self._d + other._d
        out._polys = self._polys + other._polys
        return out

    @property
    def data(self):
        return "".join(self._d)

    def mask(self, scale, size, offset=0.0):
        """Even-odd fill rendered as an 'L' image (subpaths XOR together)."""
        out = Image.new("L", (size, size), 0)
        for poly in self._polys:
            layer = Image.new("L", (size, size), 0)
            ImageDraw.Draw(layer).polygon([(x * scale + offset, y * scale + offset) for x, y in poly], fill=255)
            out = ImageChops.logical_xor(out.convert("1"), layer.convert("1")).convert("L")
        return out


def _n(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")


def _polar(c, r, deg):
    a = math.radians(deg)
    return (c[0] + r * math.cos(a), c[1] + r * math.sin(a))


# --- geometry ---------------------------------------------------------------

BUBBLE_BODY = (32, 31, 76, 67)  # the bubble without its tail
BUBBLE_RADIUS = 12


def bubble():
    (x0, y0, x1, y1), r = BUBBLE_BODY, BUBBLE_RADIUS
    # Tail: the left edge runs on down to a point, then cuts back to the bottom edge.
    tip, base = (x0, y1 + 10), (x0 + 14, y1)
    dx, dy = base[0] - tip[0], base[1] - tip[1]
    k = math.hypot(dx, dy)
    ux, uy = dx / k, dy / k
    tip_r, base_r = 3.5, 3  # softening of the two tail corners
    return (
        Path()
        .move((x0 + r, y0))
        .line((x1 - r, y0))
        .arc((x1 - r, y0 + r), r, -90, 0)
        .line((x1, y1 - r))
        .arc((x1 - r, y1 - r), r, 0, 90)
        .line((base[0] + base_r, y1))
        .cubic(base, base, (base[0] - ux * base_r, base[1] - uy * base_r))
        .line((tip[0] + ux * tip_r, tip[1] + uy * tip_r))
        .cubic(tip, tip, (x0, tip[1] - tip_r))
        .line((x0, y0 + r))
        .arc((x0 + r, y0 + r), r, 180, 270)
        .close()
    )


def chevron(tip, arm, half_width):
    """'>' stroked with round caps and a round outer join, as a filled outline."""
    tx, ty = tip
    h, s = half_width, half_width / math.sqrt(2)
    a, b = (tx - arm, ty - arm), (tx - arm, ty + arm)
    return (
        Path()
        .move((a[0] + s, a[1] - s))
        .line((tx + s, ty - s))
        .arc(tip, h, -45, 45)
        .line((b[0] + s, b[1] + s))
        .arc(b, h, 45, 225)
        .line((tx - h * math.sqrt(2), ty))
        .line((a[0] - s, a[1] + s))
        .arc(a, h, 135, 315)
        .close()
    )


def underscore(x0, x1, y, half_width):
    h = half_width
    return (
        Path()
        .move((x0, y - h))
        .line((x1, y - h))
        .arc((x1, y), h, -90, 90)
        .line((x0, y + h))
        .arc((x0, y), h, 90, 270)
        .close()
    )


def glyph_parts():
    # ">_" centred in the bubble body (54, 49).
    w, arm = 3.5, 7.5  # half stroke width, chevron arm reach
    tx, ty = 50.75, 49
    return chevron((tx, ty), arm, w), underscore(tx + 5, tx + 14, ty + arm, w)


def glyph():
    chevron_part, underscore_part = glyph_parts()
    return chevron_part + underscore_part


def circle():
    """The visible 72-unit area of the adaptive canvas, as the splash screen shows it."""
    c, r = (CANVAS / 2, CANVAS / 2), VIEWPORT / 2
    return Path().move((c[0] - r, c[1])).arc(c, r, 180, 360).arc(c, r, 0, 180).close()


# --- android resources ------------------------------------------------------

VECTOR_HEAD = f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tool/generate_icon.py; edit that instead. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="{CANVAS}dp"
    android:height="{CANVAS}dp"
    android:viewportWidth="{CANVAS}"
    android:viewportHeight="{CANVAS}">
"""

GRADIENT_FILL = f"""        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="{CANVAS}"
                android:endY="{CANVAS}"
                android:startColor="{GRADIENT_START}"
                android:endColor="{GRADIENT_END}" />
        </aapt:attr>
"""


def write_vectors():
    full = f"M0,0H{CANVAS}V{CANVAS}H0Z"
    files = {
        "drawable/ic_launcher_background.xml": (
            f'    <path android:pathData="{full}">\n{GRADIENT_FILL}    </path>\n'
        ),
        # The glyph reuses the background gradient so it reads as a cut-out.
        "drawable/ic_launcher_foreground.xml": (
            f'    <path\n        android:fillColor="{BUBBLE}"\n        android:pathData="{bubble().data}" />\n'
            f'    <path android:pathData="{glyph().data}">\n{GRADIENT_FILL}    </path>\n'
        ),
        # Themed icons only use alpha, so the glyph has to be a real hole here.
        "drawable/ic_launcher_monochrome.xml": (
            f'    <path\n        android:fillColor="#FFFFFFFF"\n        android:fillType="evenOdd"\n'
            f'        android:pathData="{(bubble() + glyph()).data}" />\n'
        ),
        # The launch animation starts from an empty bubble; drawable/splash_icon_animated.xml
        # targets the "art" group.
        "drawable/splash_icon.xml": (
            f'    <group\n        android:name="art"\n        android:pivotX="{CANVAS // 2}"\n'
            f'        android:pivotY="{CANVAS // 2}"\n        android:scaleX="{SPLASH_SCALE:.6f}"\n'
            f'        android:scaleY="{SPLASH_SCALE:.6f}">\n'
            f'        <path android:pathData="{circle().data}">\n'
            + "".join("    " + line + "\n" for line in GRADIENT_FILL.splitlines())
            + "        </path>\n"
            f'        <path\n            android:fillColor="{BUBBLE}"\n            android:pathData="{bubble().data}" />\n'
            "    </group>\n"
        ),
    }
    for name, body in files.items():
        (RES / name).write_text(VECTOR_HEAD + body + "</vector>\n", encoding="utf-8", newline="\n")

    adaptive = RES / "mipmap-anydpi-v26/ic_launcher.xml"
    adaptive.parent.mkdir(exist_ok=True)
    adaptive.write_text(
        """<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tool/generate_icon.py; edit that instead. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
""",
        encoding="utf-8",
        newline="\n",
    )


# --- raster -----------------------------------------------------------------

def _rgb(hex_):
    return tuple(int(hex_[i : i + 2], 16) for i in (1, 3, 5))


def render_canvas(size):
    """Full 108x108 adaptive canvas (both layers) as an RGBA image."""
    scale = size / CANVAS
    t = (np.arange(size)[:, None] + np.arange(size)[None, :]) / (2 * (size - 1))
    start, end = np.array(_rgb(GRADIENT_START), float), np.array(_rgb(GRADIENT_END), float)
    grad = Image.fromarray((start + (end - start) * t[..., None]).round().astype(np.uint8))
    white = ImageChops.subtract(bubble().mask(scale, size), glyph().mask(scale, size))
    grad.paste(Image.new("RGB", (size, size), _rgb(BUBBLE)), (0, 0), white)
    return grad.convert("RGBA")


def render_splash(size):
    """The splash icon in its SPLASH_BOX square: the gradient circle and an empty bubble."""
    scale = size / CANVAS * SPLASH_SCALE
    offset = size / 2 - CANVAS / 2 * scale
    units = (np.arange(size) + 0.5 - offset) / scale
    t = np.clip((units[:, None] + units[None, :]) / (2 * CANVAS), 0, 1)
    start, end = np.array(_rgb(GRADIENT_START), float), np.array(_rgb(GRADIENT_END), float)
    grad = Image.fromarray((start + (end - start) * t[..., None]).round().astype(np.uint8))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(grad, (0, 0), circle().mask(scale, size, offset))
    out.paste(Image.new("RGB", (size, size), _rgb(BUBBLE)), (0, 0), bubble().mask(scale, size, offset))
    return out


def crop_viewport(img):
    size = img.width
    inset = round(size * (CANVAS - VIEWPORT) / 2 / CANVAS)
    return img.crop((inset, inset, size - inset, size - inset))


def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse((0, 0, size - 1, size - 1), fill=255)
    return m


def write_legacy_pngs(hi):
    """Pre-O launchers get the adaptive composition under a circular mask."""
    view = crop_viewport(hi)
    view.putalpha(circle_mask(view.width))
    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        view.resize((px, px), Image.LANCZOS).save(RES / f"mipmap-{density}/ic_launcher.png", optimize=True)


def write_ios_app_icons(hi):
    """Full-bleed squares, since iOS applies its own mask. App icons must not have an alpha channel."""
    view = crop_viewport(hi).convert("RGB")
    icons = IOS / "AppIcon.appiconset"
    for entry in json.loads((icons / "Contents.json").read_text(encoding="utf-8"))["images"]:
        px = round(float(entry["size"].split("x")[0]) * int(entry["scale"].rstrip("x")))
        view.resize((px, px), Image.LANCZOS).save(icons / entry["filename"], optimize=True)


def write_ios_launch_images(splash):
    for suffix, factor in (("", 1), ("@2x", 2), ("@3x", 3)):
        px = SPLASH_BOX * factor
        splash.resize((px, px), Image.LANCZOS).save(IOS / f"LaunchImage.imageset/LaunchImage{suffix}.png", optimize=True)


def write_dart():
    chevron_part, underscore_part = glyph_parts()
    DART.write_text(
        f"""// Generated by tool/generate_icon.py; edit that instead.
import 'dart:ui';

/// The launcher icon in its {CANVAS}-unit adaptive icon canvas, as SVG path data.
const codeawIconBubble = '{bubble().data}';
const codeawIconChevron = '{chevron_part.data}';
const codeawIconUnderscore = '{underscore_part.data}';

/// The bubble without its tail, and its corner radius.
const codeawIconBubbleBody = Rect.fromLTRB({", ".join(f"{float(v)}" for v in BUBBLE_BODY)});
const codeawIconBubbleRadius = {float(BUBBLE_RADIUS)};

/// Icon background gradient, from the top-left to the bottom-right corner.
const codeawIconGradient = [Color(0xFF{GRADIENT_START[1:]}), Color(0xFF{GRADIENT_END[1:]})];

/// The circle the launch screens show around the bubble, in icon units.
const codeawIconCircleRadius = {VIEWPORT / 2};

/// The launch screens draw the icon canvas in a {SPLASH_BOX} dp box, scaled so the circle is 160 dp wide.
const codeawSplashBox = {float(SPLASH_BOX)};
const codeawSplashScale = {SPLASH_SCALE!r};
""",
        encoding="utf-8",
        newline="\n",
    )


def write_preview(hi, splash, out):
    """Mockup sheet: common launcher masks, a themed icon, small sizes and the launch screens."""
    tile, pad = 320, 40
    sheet = Image.new("RGB", (pad + 5 * (tile + pad), 3 * tile + 4 * pad), (236, 239, 238))
    view = crop_viewport(hi).resize((tile, tile), Image.LANCZOS)
    masks = []
    for shape in ("circle", "squircle", "rounded", "teardrop"):
        m = Image.new("L", (tile * 4, tile * 4), 0)
        d = ImageDraw.Draw(m)
        s = tile * 4
        if shape == "circle":
            d.ellipse((0, 0, s, s), fill=255)
        elif shape == "squircle":
            pts = []
            for i in range(720):
                a = 2 * math.pi * i / 720
                c, si = math.cos(a), math.sin(a)
                pts.append((s / 2 + s / 2 * math.copysign(abs(c) ** 0.4, c), s / 2 + s / 2 * math.copysign(abs(si) ** 0.4, si)))
            d.polygon(pts, fill=255)
        elif shape == "rounded":
            d.rounded_rectangle((0, 0, s, s), radius=s * 0.22, fill=255)
        else:
            d.rounded_rectangle((0, 0, s, s), radius=s / 2, fill=255)
            d.rectangle((s / 2, s / 2, s, s), fill=255)
        masks.append(m.resize((tile, tile), Image.LANCZOS))
    for i, m in enumerate(masks):
        sheet.paste(view, (pad + i * (tile + pad), pad), m)

    # Themed (monochrome) icon as Android 13+ tints it.
    size = tile * 4
    scale = size / CANVAS
    mono = crop_viewport((bubble() + glyph()).mask(scale, size).convert("RGB")).convert("L").resize((tile, tile), Image.LANCZOS)
    x = pad + 4 * (tile + pad)
    sheet.paste(Image.new("RGB", (tile, tile), (205, 232, 225)), (x, pad), masks[0])
    sheet.paste(Image.new("RGB", (tile, tile), (12, 58, 50)), (x, pad), ImageChops.multiply(mono, masks[0]))

    # Real legacy PNGs, on light and dark backgrounds, at 1x and zoomed 4x.
    y = 2 * pad + tile
    dark = (32, 36, 38)
    sheet.paste(Image.new("RGB", (sheet.width - 2 * pad, tile), dark), (pad, y))
    x = pad + 20
    for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
        icon = Image.open(RES / f"mipmap-{density}/ic_launcher.png")
        sheet.paste(icon, (x, y + 20), icon)
        x += icon.width + 24
    for density in ("mdpi", "hdpi"):
        icon = Image.open(RES / f"mipmap-{density}/ic_launcher.png")
        big = icon.resize((icon.width * 4, icon.height * 4), Image.NEAREST)
        sheet.paste(big, (x, y + 20), big)
        x += big.width + 24

    # Launch screens on both app surfaces, then the iOS app icon under an iOS-like mask.
    y = 3 * pad + 2 * tile
    small = splash.resize((tile, tile), Image.LANCZOS)
    for i, surface in enumerate(SURFACES):
        x = pad + i * (tile + pad)
        sheet.paste(Image.new("RGB", (tile, tile), _rgb(surface)), (x, y))
        sheet.paste(small, (x, y), small)
    ios = Image.open(IOS / "AppIcon.appiconset/Icon-App-1024x1024@1x.png").resize((tile, tile), Image.LANCZOS)
    sheet.paste(ios, (pad + 2 * (tile + pad), y), masks[2])
    sheet.save(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--preview", metavar="PNG", help="also write a mockup sheet to this path")
    args = parser.parse_args()

    write_vectors()
    hi = render_canvas(CANVAS * 24)
    write_legacy_pngs(hi)
    write_ios_app_icons(hi)
    splash = render_splash(SPLASH_BOX * 12)
    write_ios_launch_images(splash)
    write_dart()
    if args.preview:
        write_preview(hi, splash, args.preview)


if __name__ == "__main__":
    main()
