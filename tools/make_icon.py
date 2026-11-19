#!/usr/bin/env python3
"""Rasterize the supplied SVG artwork into the macOS app icon format."""
import os
import shutil
import subprocess
import sys
import tempfile


def run(command):
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_icon.py SOURCE.svg DESTINATION.icns")

    source, output = sys.argv[1:]
    output = os.path.abspath(output)
    with tempfile.TemporaryDirectory() as temp_dir:
        run(["/usr/bin/qlmanage", "-t", "-s", "512", "-o", temp_dir, source])
        rendered = os.path.join(temp_dir, os.path.basename(source) + ".png")
        if not os.path.isfile(rendered):
            raise RuntimeError(f"Quick Look did not render {source}")

        iconset = os.path.join(temp_dir, "AppIcon.iconset")
        os.makedirs(iconset)
        sizes = (16, 32, 64, 128, 256, 512)
        for size in sizes:
            png = os.path.join(iconset, f"icon_{size}x{size}.png")
            run(["/usr/bin/sips", "-z", str(size), str(size), rendered, "--out", png])

        for size in (32, 64, 256, 512):
            src = os.path.join(iconset, f"icon_{size}x{size}.png")
            dst = os.path.join(iconset, f"icon_{size // 2}x{size // 2}@2x.png")
            shutil.copyfile(src, dst)

        run(["/usr/bin/iconutil", "-c", "icns", iconset, "-o", output])


if __name__ == "__main__":
    main()
