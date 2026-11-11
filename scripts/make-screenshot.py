#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
#
# Makes the README screenshot, packaging/screenshot/screenshot.png: the widget,
# rendered with made-up sample data (`--snapshot`), on a drawn dusk-mountains
# wallpaper. Nothing from this Mac's calendar or location is used.
#
#   scripts/make-screenshot.py
#
# Needs a release build (swift build -c release), rsvg-convert and ImageMagick.

import os
import random
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
OUT = os.path.join(ROOT, "packaging", "screenshot")
BIN = os.path.join(ROOT, ".build", "release", "SimpleDesktopWidget")

W, H = 3000, 1800          # canvas, in pixels (the widget is rendered at 2x)


def ridge(seed, base, amp, step, roughness):
    """A mountain silhouette as an SVG path: random midpoint-ish walk across the canvas."""
    rnd = random.Random(seed)
    pts, y = [], base
    for x in range(-50, W + 100, step):
        y += rnd.uniform(-roughness, roughness)
        y = max(base - amp, min(base + amp * 0.4, y))
        pts.append((x, y))
    d = f"M -50 {H} " + " ".join(f"L {x} {y:.0f}" for x, y in pts) + f" L {W + 100} {H} Z"
    return d


def background_svg():
    rnd = random.Random(7)
    stars = "".join(
        f'<circle cx="{rnd.uniform(0, W):.0f}" cy="{rnd.uniform(0, H * 0.45):.0f}" '
        f'r="{rnd.uniform(1.2, 3.2):.1f}" fill="#fff" opacity="{rnd.uniform(0.25, 0.8):.2f}"/>'
        for _ in range(140))
    layers = [
        # seed, base y, amplitude, step, roughness, colour
        (3, 1050, 260, 60, 70, "#3b3f6b"),
        (11, 1210, 230, 50, 60, "#2a2d52"),
        (23, 1390, 200, 45, 55, "#1c1e3b"),
        (41, 1580, 160, 40, 45, "#11122a"),
    ]
    mountains = "".join(f'<path d="{ridge(s, b, a, st, r)}" fill="{c}"/>' for s, b, a, st, r, c in layers)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#0d1633"/>
  <stop offset="0.38" stop-color="#2b3a78"/>
  <stop offset="0.62" stop-color="#8d5a8f"/>
  <stop offset="0.78" stop-color="#e98a6b"/>
  <stop offset="0.9" stop-color="#f6c27a"/>
</linearGradient>
<radialGradient id="sun" cx="0.3" cy="0.66" r="0.35">
  <stop offset="0" stop-color="#ffd9a0" stop-opacity="0.75"/>
  <stop offset="1" stop-color="#ffd9a0" stop-opacity="0"/>
</radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="url(#sky)"/>
<rect width="{W}" height="{H}" fill="url(#sun)"/>
{stars}
{mountains}
</svg>
'''


def run(args, **kw):
    subprocess.run(args, check=True, **kw)


def main():
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp()
    widget = os.path.join(work, "widget.png")
    run([BIN, "--snapshot", widget], env={**os.environ, "TZ": "America/Denver"}, capture_output=True)

    svg = os.path.join(work, "background.svg")
    with open(svg, "w") as f:
        f.write(background_svg())
    bg = os.path.join(work, "background.png")
    run(["rsvg-convert", "-w", str(W), "-h", str(H), "-o", bg, svg])

    # Widget towards the top right, as it might sit on a real desktop.
    out = os.path.join(OUT, "screenshot.png")
    run(["magick", bg, widget, "-gravity", "northeast", "-geometry", "+170+60", "-composite",
         "-resize", "50%", "-strip", out])
    print("made", out)


if __name__ == "__main__":
    main()
