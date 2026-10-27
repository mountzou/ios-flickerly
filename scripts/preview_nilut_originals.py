"""Render inspectable comparisons using the exact packed app cubes (or targets)."""
import argparse
import hashlib
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont, ImageOps

from generate_nilut_luts import sample_cube
from nilut_original_grades import STYLES
from nilut_original_grades import linearize, encode

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT/"artifacts/nilut-originals"
SOURCES = [
    ("still-life", ROOT/"Flickerly/Catalog/catalog-sample.png", "Flickerly generated catalog sample"),
    ("landscape", ROOT/"artifacts/nilut-preview/landscape-original.png", "Existing NILUT experiment; see artifacts/nilut-preview/asset-manifest.json"),
    ("bird", ROOT/"artifacts/nilut-preview/demo-original.png", "NILUT repository demo; see artifacts/nilut-preview/asset-manifest.json"),
    ("portrait-light", OUTPUT/"inputs/portrait-light.png", "NASA / Eileen Collins; scikit-image v0.25.2 astronaut.png; https://scikit-image.org/docs/0.25.x/api/skimage.data.html#skimage.data.astronaut"),
    ("portrait-deep", OUTPUT/"inputs/portrait-deep.jpg", "NASA / Bill Stafford, Jessica Watkins jsc2026e035015_alt; https://images-assets.nasa.gov/image/jsc2026e035015_alt/jsc2026e035015_alt~orig.jpg"),
]


def srgb_image(path):
    with Image.open(path) as opened:
        image = ImageOps.exif_transpose(opened).convert("RGB")
        if opened.info.get("icc_profile"):
            source_profile = ImageCms.ImageCmsProfile(io.BytesIO(opened.info["icc_profile"]))
            image = ImageCms.profileToProfile(image, source_profile, ImageCms.createProfile("sRGB"), outputMode="RGB")
        return image


def render_cube(cube, rgb, intensity):
    result = np.empty_like(rgb)
    for row in range(0, len(rgb), 64):
        result[row:row+64] = sample_cube(cube, rgb[row:row+64])
    result = encode((1-intensity)*linearize(rgb)+intensity*linearize(result))
    return Image.fromarray(np.clip(result*255+.5, 0, 255).astype(np.uint8))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--targets", action="store_true")
    parser.add_argument("--intensity", type=float, default=1.0)
    parser.add_argument("--compare-previous", action="store_true")
    args = parser.parse_args()
    assert 0 <= args.intensity <= 1
    folder = OUTPUT/("target-previews" if args.targets else "comparisons")
    folder.mkdir(exist_ok=True)
    cubes=[]
    for _, slug, _ in STYLES:
        if args.targets:
            cubes.append(np.loadtxt(OUTPUT/"targets"/f"{slug}.cube", skiprows=4, dtype=np.float32).reshape(65,65,65,3))
        else:
            cubes.append(np.frombuffer((ROOT/"Flickerly/Resources/NILUT"/f"{slug}.nlut").read_bytes()[16:],dtype="<f2").astype(np.float32).reshape(65,65,65,3))
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 22)
    small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 16)
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    manifest=[]
    detail = ("portrait-deep-detail", OUTPUT/"inputs/portrait-deep.jpg", "Detail crop, same NASA / Bill Stafford reference; validation only")
    for name,path,credit in [*SOURCES, detail]:
        image = srgb_image(path)
        crop = (.32, .045, .65, .28) if name == "portrait-deep-detail" else None
        if crop:
            image = image.crop(tuple(round(value*(image.width if i%2==0 else image.height)) for i,value in enumerate(crop)))
        image.thumbnail((1500,1500), Image.Resampling.LANCZOS)
        rgb = np.asarray(image).astype(np.float32)/255
        images=[image]
        for cube, (_,slug,_) in zip(cubes,STYLES):
            result_image=render_cube(cube, rgb, args.intensity)
            suffix = "" if args.intensity == 1 else f"-{args.intensity*100:.0f}"
            result_image.save(folder/f"{name}-{slug}{suffix}.png",icc_profile=profile)
            images.append(result_image)
        width,cell_h=360, min(480,round(360*image.height/image.width))
        board=Image.new("RGB",(4*width+5*16,cell_h+106),(15,15,15))
        draw=ImageDraw.Draw(board)
        for i,(label,preview) in enumerate(zip(["Original","N4 / Natural","N5 / Soft Warm","N6 / Cool Matte"], images)):
            x=16+i*(width+16)
            draw.text((x,17),label,font=font,fill="white")
            thumb=ImageOps.contain(preview,(width,cell_h),Image.Resampling.LANCZOS)
            board.paste(thumb,(x+(width-thumb.width)//2,58+(cell_h-thumb.height)//2))
        draw.text((16,cell_h+74),f"Flickerly  /  intensity {args.intensity*100:.0f}%  /  " + ("authored target LUT" if args.targets else "bundled NILUT cubes"),font=small,fill=(160,160,160))
        board.save(folder/f"{name}-comparison{suffix}.jpg",quality=95,subsampling=0,icc_profile=profile)
        if args.compare_previous:
            revision=Image.new("RGB",(3*width+4*16,2*(cell_h+76)+30),(15,15,15))
            revision_draw=ImageDraw.Draw(revision)
            for index,(_,slug,style_name) in enumerate(STYLES[:2]):
                old=np.frombuffer((OUTPUT/"v1/resources"/f"{slug}.nlut").read_bytes()[16:],dtype="<f2").astype(np.float32).reshape(65,65,65,3)
                old_image=render_cube(old,rgb,args.intensity)
                row_y=index*(cell_h+76)
                for column,(label,preview) in enumerate(zip(["Original",f"{style_name} / previous",f"{style_name} / revised"],[image,old_image,images[index+1]])):
                    x=16+column*(width+16)
                    revision_draw.text((x,row_y+17),label,font=font,fill="white")
                    thumb=ImageOps.contain(preview,(width,cell_h),Image.Resampling.LANCZOS)
                    revision.paste(thumb,(x+(width-thumb.width)//2,row_y+58+(cell_h-thumb.height)//2))
            revision_draw.text((16,2*(cell_h+76)+3),f"Flickerly  /  same intensity {args.intensity*100:.0f}%  /  actual bundled cubes",font=small,fill=(160,160,160))
            revision.save(folder/f"{name}-revision{suffix}.jpg",quality=95,subsampling=0,icc_profile=profile)
        manifest.append({"name":name,"file":str(path.relative_to(ROOT)),"credit":credit,"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"normalized_crop":crop,"validation_only":True})
        print(f"Rendered {name}",flush=True)
    if not args.targets:
        (OUTPUT/"input-manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")


if __name__ == "__main__":
    main()
