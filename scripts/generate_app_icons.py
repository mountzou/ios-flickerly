#!/usr/bin/env python3
"""Render the approved vector mark. Run normally to generate, or with --check.

Dependencies: scripts/app-icon-requirements.txt and a native Cairo installation.
The master SVG is authoritative; no generated image model is used in this step.
"""

import argparse
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import cairocffi as cairo
import cairosvg
from PIL import Image, PngImagePlugin
from PIL import __version__ as pillow_version

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "Branding/Flickerly"
CATALOG = ROOT / "Flickerly/Catalog/Assets.xcassets"
SIZES = [16, 20, 24, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87,
         120, 128, 152, 167, 180, 192, 256, 512, 1024, 2048]
VARIANTS = {
    "light": ("#000000", "#FFFFFF"),
    "dark": ("#FFFFFF", None),
    "tinted": ("#FFFFFF", "#000000"),
    "inverse": ("#FFFFFF", "#000000"),
    "mark-black": ("#000000", None),
    "mark-white": ("#FFFFFF", None),
}
INFO = {"author": "xcode", "version": 1}
# Scale the symbol around the center while keeping the icon canvas unchanged.
ICON_SCALE = 0.90


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


class StablePDFSurface(cairosvg.surface.PDFSurface):
    def _create_surface(self, width, height):
        surface, width, height = super()._create_surface(width, height)
        for key in [cairo.PDF_METADATA_CREATE_DATE, cairo.PDF_METADATA_MOD_DATE]:
            surface.set_metadata(key, "2026-10-24T00:00:00Z")
        surface.set_metadata(cairo.PDF_METADATA_TITLE, "Flickerly Grain")
        return surface, width, height


def svg_variants(icon=False):
    master = ET.parse(BRAND / "grain-mark.svg").getroot()
    paths = master.findall(".//{http://www.w3.org/2000/svg}path")
    assert len(paths) == 4, "Keep the approved body and three separate dots"
    assert not master.findall(".//{http://www.w3.org/2000/svg}image"), "Master must be vector paths"
    assert all(p.attrib["d"].strip().endswith("Z") for p in paths)
    body = "\n".join('    <path d="' + p.attrib["d"] + '"/>' for p in paths)
    result = {}
    for name, (foreground, background) in VARIANTS.items():
        backdrop = f'  <rect width="1024" height="1024" fill="{background}"/>\n' if background else ""
        result[name] = (
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            '  <title>Flickerly Grain</title>\n' + backdrop +
            f'  <g fill="{foreground}"' +
            (f' transform="translate(512 512) scale({ICON_SCALE}) translate(-512 -512)"' if icon else '') +
            '>\n' + body + '\n  </g>\n</svg>\n'
        ).encode()
    return result


def png(svg, size, transparent):
    raw = cairosvg.svg2png(bytestring=svg, output_width=size, output_height=size)
    image = Image.open(BytesIO(raw)).convert("RGBA" if transparent else "RGB")
    profile = PngImagePlugin.PngInfo()
    profile.add(b"sRGB", b"\x00")
    output = BytesIO()
    image.save(output, format="PNG", optimize=True, pnginfo=profile)
    return output.getvalue()


def pdf(svg):
    output = BytesIO()
    surface = StablePDFSurface(cairosvg.parser.Tree(bytestring=svg), output, dpi=72)
    surface.finish()
    result = output.getvalue()
    assert b"/Subtype /Image" not in result, "PDF must contain vector drawing, not a raster image"
    return result


def generate():
    outputs = {CATALOG / "Contents.json": json_bytes({"info": INFO})}
    vectors = svg_variants()
    icon_vectors = svg_variants(icon=True)
    rasters = {}
    for name, svg in vectors.items():
        outputs[BRAND / f"vector/flickerly-{name}.svg"] = svg
        outputs[BRAND / f"vector/flickerly-{name}.pdf"] = pdf(svg)
        for size in SIZES:
            data = png(svg, size, VARIANTS[name][1] is None)
            outputs[BRAND / f"png/{name}/flickerly-{name}-{size}.png"] = data
            rasters[name, size] = data

    # Keep a standalone PNG catalog for distribution; the app uses AppIcon.icon.
    images = []
    for variant in ["light", "dark", "tinted"]:
        filename = f"AppIcon-{variant.title()}-1024.png"
        entry = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if variant != "light":
            entry["appearances"] = [{"appearance": "luminosity", "value": variant}]
        images.append(entry)
        outputs[BRAND / "AppIcon.appiconset" / filename] = png(icon_vectors[variant], 1024, VARIANTS[variant][1] is None)
    contents = json_bytes({"images": images, "info": INFO})
    outputs[BRAND / "AppIcon.appiconset/Contents.json"] = contents

    # A native, recolorable vector asset is available for future in-app branding.
    outputs[CATALOG / "FlickerlyMark.imageset/FlickerlyMark.pdf"] = outputs[BRAND / "vector/flickerly-mark-black.pdf"]
    outputs[CATALOG / "FlickerlyMark.imageset/Contents.json"] = json_bytes({
        "images": [{"filename": "FlickerlyMark.pdf", "idiom": "universal"}],
        "info": INFO,
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    })

    # Standalone legacy set, kept outside the app to avoid duplicate icon names.
    legacy = BRAND / "ios-all-sizes/AppIcon.appiconset"
    entries = []
    slots = [("iphone", pt, scale) for pt in [20, 29, 40, 60] for scale in [2, 3]]
    slots += [("ipad", pt, scale) for pt in [20, 29, 40, 76] for scale in [1, 2]]
    slots += [("ipad", 83.5, 2), ("ios-marketing", 1024, 1)]
    for idiom, point_size, scale in slots:
        pixel_size = int(point_size * scale)
        filename = f"AppIcon-{pixel_size}.png"
        outputs[legacy / filename] = png(icon_vectors["light"], pixel_size, False)
        entries.append({"filename": filename, "idiom": idiom, "scale": f"{scale}x", "size": f"{point_size}x{point_size}"})
    outputs[legacy / "Contents.json"] = json_bytes({"images": entries, "info": INFO})

    # Web/social reuse from the same vector geometry.
    for size in [16, 32, 48, 192, 512]:
        outputs[BRAND / f"web/flickerly-{size}.png"] = rasters["light", size]
    frames = [Image.open(BytesIO(rasters["light", size])) for size in [16, 32, 48]]
    ico = BytesIO()
    frames[-1].save(ico, format="ICO", sizes=[(16, 16), (32, 32), (48, 48)], append_images=frames[:-1])
    outputs[BRAND / "web/favicon.ico"] = ico.getvalue()

    manifest = {
        "master": "grain-mark.svg",
        "master_sha256": sha256((BRAND / "grain-mark.svg").read_bytes()).hexdigest(),
        "renderer": {"CairoSVG": cairosvg.__version__, "Cairo": cairo.cairo_version_string(), "Pillow": pillow_version},
        "sizes": SIZES, "variants": list(VARIANTS),
        "files": {str(path.relative_to(ROOT)): sha256(data).hexdigest() for path, data in sorted(outputs.items())},
    }
    outputs[BRAND / "manifest.json"] = json_bytes(manifest)
    return outputs


def validate(outputs):
    for path, data in outputs.items():
        if path.suffix != ".png":
            continue
        image = Image.open(BytesIO(data))
        assert image.width == image.height, path
        pixels = image.convert("RGBA")
        if "/light/" in str(path) or "AppIcon-Light" in path.name:
            assert image.mode == "RGB" and pixels.getpixel((0, 0)) == (255, 255, 255, 255), path
        if "/dark/" in str(path) or "AppIcon-Dark" in path.name:
            assert image.mode == "RGBA" and pixels.getpixel((0, 0))[3] == 0, path
    for variant in ["light", "dark", "tinted"]:
        name = BRAND / f"AppIcon.appiconset/AppIcon-{variant.title()}-1024.png"
        assert Image.open(BytesIO(outputs[name])).size == (1024, 1024)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Re-render and verify all saved outputs")
    options = parser.parse_args()
    outputs = generate()
    validate(outputs)
    failures = []
    for path, expected in outputs.items():
        if options.check:
            if not path.exists() or path.read_bytes() != expected:
                failures.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
    if failures:
        raise SystemExit("Assets differ: " + ", ".join(failures))
    print(f'{"Verified" if options.check else "Generated"} {len(outputs)} files; '
          f'{len(SIZES)} sizes; {len(VARIANTS)} variants; vector SVG/PDF and iOS catalog.')


if __name__ == "__main__":
    main()
