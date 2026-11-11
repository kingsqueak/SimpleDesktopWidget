#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
#
# Makes SimpleDesktopWidget's app icon: packaging/icon/icon.svg, icon.png (1024 px)
# and Resources/AppIcon.icns. Same family style as SimpleHPSDR and PatchPrimeMac: a
# dark slate tile with a faint grid, blue, cyan and yellow. The picture is a clock
# face at ten past ten with a small lightning bolt.
#
#   scripts/make-icon.py
#
# Needs rsvg-convert (brew install librsvg), ImageMagick and iconutil (macOS).

import math
import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
OUT = os.path.join(ROOT, "packaging", "icon")
ICNS = os.path.join(ROOT, "Resources", "AppIcon.icns")

TILE = (100, 100, 824, 185)  # x, y, size, corner radius
CX, CY, R = 500, 500, 268    # the clock face


def hand(angle_deg, length, width, colour):
    a = math.radians(angle_deg - 90)
    x, y = CX + length * math.cos(a), CY + length * math.sin(a)
    return (f'<line x1="{CX}" y1="{CY}" x2="{x:.1f}" y2="{y:.1f}" stroke="{colour}" '
            f'stroke-width="{width}" stroke-linecap="round"/>')


def svg():
    x0, y0, size, r = TILE
    parts = [f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1F2633"/><stop offset="1" stop-color="#0B0D11"/></linearGradient>
<linearGradient id="glow" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3B82F6" stop-opacity="0.0"/><stop offset="1" stop-color="#3B82F6" stop-opacity="0.18"/></linearGradient>
<linearGradient id="ring" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2ED3C8"/><stop offset="1" stop-color="#106BD8"/></linearGradient>
<linearGradient id="bolt" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F9DF83"/><stop offset="1" stop-color="#F5B83B"/></linearGradient>
<clipPath id="c"><rect x="{x0}" y="{y0}" width="{size}" height="{size}" rx="{r}"/></clipPath>
</defs>
<rect x="{x0}" y="{y0}" width="{size}" height="{size}" rx="{r}" fill="url(#tile)"/>
<g clip-path="url(#c)">
<rect x="{x0}" y="{y0 + size // 2}" width="{size}" height="{size // 2}" fill="url(#glow)"/>
<g stroke="#FFFFFF" stroke-opacity="0.06" stroke-width="3">''']
    for y in (300, 512, 724):  # the faint grid
        parts.append(f'<line x1="{x0}" y1="{y}" x2="{x0 + size}" y2="{y}"/>')
    parts.append("</g>")

    # Face: dark disc, gradient ring, twelve ticks (the quarters longer).
    parts.append(f'<circle cx="{CX}" cy="{CY}" r="{R}" fill="#0B0F17" stroke="url(#ring)" stroke-width="34"/>')
    for i in range(12):
        a = math.radians(i * 30 - 90)
        outer = R - 40
        inner = outer - (52 if i % 3 == 0 else 26)
        w = 16 if i % 3 == 0 else 9
        parts.append(f'<line x1="{CX + inner * math.cos(a):.1f}" y1="{CY + inner * math.sin(a):.1f}" '
                     f'x2="{CX + outer * math.cos(a):.1f}" y2="{CY + outer * math.sin(a):.1f}" '
                     f'stroke="#E8EEF7" stroke-opacity="0.85" stroke-width="{w}" stroke-linecap="round"/>')
    # Ten past ten.
    parts.append(hand(300 + 5, 125, 30, "#F4F7FC"))   # hour
    parts.append(hand(60, 185, 20, "#F4F7FC"))        # minute
    parts.append(hand(170, 200, 8, "#2ED3C8"))        # second
    parts.append(f'<circle cx="{CX}" cy="{CY}" r="22" fill="#2ED3C8"/>')

    # The bolt, bottom right, overlapping the ring.
    bolt = [(742, 560), (640, 735), (712, 735), (668, 880), (815, 668), (738, 668), (790, 560)]
    pts = " ".join(f"{x},{y}" for x, y in bolt)
    parts.append(f'<polygon points="{pts}" fill="url(#bolt)" stroke="#0B0D11" stroke-width="14" stroke-linejoin="round"/>')

    parts.append("</g>")
    parts.append(f'<rect x="{x0 + 0.5}" y="{y0 + 0.5}" width="{size - 1}" height="{size - 1}" rx="{r}" fill="none" stroke="#FFFFFF" stroke-opacity="0.09" stroke-width="2"/>')
    parts.append("</svg>\n")
    return "\n".join(parts)


def run(args):
    subprocess.run(args, check=True, capture_output=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    svg_path = os.path.join(OUT, "icon.svg")
    with open(svg_path, "w") as f:
        f.write(svg())
    png = os.path.join(OUT, "icon.png")
    # librsvg, not ImageMagick's own SVG reader, which drops gradients.
    run(["rsvg-convert", "-w", "1024", "-h", "1024", "-o", png, svg_path])
    run(["magick", png, "-strip", png])
    work = tempfile.mkdtemp()
    iconset = os.path.join(work, "AppIcon.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            run(["magick", png, "-resize", f"{px}x{px}", "-strip", os.path.join(iconset, name)])
    run(["iconutil", "-c", "icns", iconset, "-o", ICNS])
    shutil.rmtree(work)
    print("made", svg_path, png, ICNS)


if __name__ == "__main__":
    main()
