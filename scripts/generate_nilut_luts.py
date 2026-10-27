"""Bake upstream and Flickerly-trained NILUT styles into sRGB lookup tables.

Requires the checkpoint/notebook preserved by artifacts/nilut-preview and a
Python environment with PyTorch, NumPy, Pillow. No model code runs in the app.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image
import torch

from nilut_original_grades import STYLES
from train_nilut_originals import load_style_model, predict

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "artifacts/nilut-preview"
DESTINATION = ROOT / "Flickerly/Resources/NILUT"
REPORT = ROOT / "artifacts/nilut-integration"
DIMENSION = 65
REVISION = "effe074007edf48b1081f3838b8d30bee8ec18e1"


def sample_cube(cube, rgb):
    coordinates = rgb * (DIMENSION-1)
    base = np.minimum(np.floor(coordinates).astype(np.int32), DIMENSION-2)
    fraction = coordinates - base
    r, g, b = np.moveaxis(base, -1, 0)
    rd, gd, bd = np.moveaxis(fraction, -1, 0)
    output = np.zeros_like(rgb)
    for db in (0, 1):
        for dg in (0, 1):
            for dr in (0, 1):
                weight = (rd if dr else 1-rd)*(gd if dg else 1-gd)*(bd if db else 1-bd)
                output += weight[..., None] * cube[b+db, g+dg, r+dr]
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Verify existing bundled bytes without rewriting them")
    args = parser.parse_args()
    torch.set_num_threads(4)
    original_manifest = json.loads((SOURCE / "asset-manifest.json").read_text())
    for entry in original_manifest["files"]:
        path = SOURCE / entry["file"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], path
    spec = importlib.util.spec_from_file_location("nilut_preview", SOURCE / "run_preview.py")
    upstream = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upstream)
    model = upstream.original_architecture().eval().requires_grad_(False)
    checkpoint = torch.load(SOURCE / "model/nilutx3style.pt", map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["model"], strict=True)
    grid = np.linspace(0, 1, DIMENSION, dtype=np.float32)
    b, g, r = np.meshgrid(grid, grid, grid, indexing="ij")
    coordinates = np.stack([r, g, b], axis=-1).reshape(-1, 3)
    # An independent model oracle for the native rendering/color-space tests.
    patches = np.array([
        [0,0,0], [255,255,255], [255,0,0], [0,255,0], [0,0,255],
        [255,255,0], [255,0,255], [0,255,255],
        *[[n,n,n] for n in [4,8,16,32,64,96,128,160,192,224,248]],
        [198,134,99], [116,75,58], [232,186,160], [43,93,166],
        [63,122,68], [204,176,77], [204,51,77], [123,80,176],
    ], dtype=np.uint8)
    oracle_rgb = patches.astype(np.float32)/255
    assets, measurements = [], []
    if not args.check:
        DESTINATION.mkdir(parents=True, exist_ok=True)
        REPORT.mkdir(parents=True, exist_ok=True)
    for index, code in enumerate([1,3,4]):
        prediction = upstream.predict(model, coordinates, index)
        packed = prediction.astype("<f2")
        # Header: magic, version, edge dimension, original upstream style ID.
        data = struct.pack("<8sHHI", b"NILUTLUT", 1, DIMENSION, code) + packed.tobytes()
        filename = f"style-{index+1}.nlut"
        path = DESTINATION / filename
        if args.check:
            assert path.read_bytes() == data, f"Generated LUT differs: {path}"
        else:
            path.write_bytes(data)
        cube = packed.astype(np.float32).reshape(DIMENSION, DIMENSION, DIMENSION, 3)
        style_measurements = []
        for name in ["demo", "landscape"]:
            with Image.open(SOURCE / f"{name}-original.png") as image:
                original = np.asarray(image).astype(np.float32)/255
            with Image.open(SOURCE / f"{name}-style-{index+1}.png") as image:
                direct = np.asarray(image).astype(np.float32)
            approx = np.empty_like(original)
            for y in range(0, len(original), 128):
                approx[y:y+128] = sample_cube(cube, original[y:y+128])
            error = np.abs(np.clip(approx*255+0.5,0,255).astype(np.uint8).astype(np.float32)-direct)
            measurement = {
                "example": name,
                "mean_absolute_error_8bit": float(error.mean()),
                "p99_absolute_error_8bit": float(np.quantile(error,0.99)),
                "maximum_absolute_error_8bit": float(error.max()),
            }
            assert measurement["mean_absolute_error_8bit"] < 0.25, measurement
            assert measurement["p99_absolute_error_8bit"] <= 1, measurement
            assert measurement["maximum_absolute_error_8bit"] <= 3, measurement
            style_measurements.append(measurement)
        oracle = upstream.predict(model, oracle_rgb, index)
        assets.append({
            "file": filename, "upstream_lut": f"LUT{code:02}",
            "style_index": index+1, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "reference_output_srgb": oracle.tolist(),
        })
        measurements.append({"style": index+1, "measurements": style_measurements})
        print(json.dumps({"file": filename, "bytes": len(data), "measurements": style_measurements}), flush=True)
    originals = ROOT / "artifacts/nilut-originals"
    training = json.loads((originals/"training.json").read_text())
    checkpoint_path = originals/training["model_file"]
    assert hashlib.sha256(checkpoint_path.read_bytes()).hexdigest() == training["model_sha256"]
    for target in training["targets"]:
        assert hashlib.sha256((ROOT/target["file"]).read_bytes()).hexdigest() == target["sha256"]
    validation = np.random.default_rng(11991).random((32768, 3), dtype=np.float32)
    for index, (identifier, slug, name) in enumerate(STYLES):
        original_model, model_sha = load_style_model(training, index)
        packed = predict(original_model, coordinates, index).astype("<f2")
        data = struct.pack("<8sHHI", b"NILUTLUT", 1, DIMENSION, identifier) + packed.tobytes()
        filename = f"{slug}.nlut"
        if args.check:
            assert (DESTINATION/filename).read_bytes() == data, filename
        else:
            (DESTINATION/filename).write_bytes(data)
        cube = packed.astype(np.float32).reshape(DIMENSION,DIMENSION,DIMENSION,3)
        error = np.abs(sample_cube(cube,validation)-predict(original_model,validation,index))*255
        measurement = {"mean_absolute_error_8bit":float(error.mean()),"p99_absolute_error_8bit":float(np.quantile(error,.99)),
                       "p999_absolute_error_8bit":float(np.quantile(error,.999)),"maximum_absolute_error_8bit":float(error.max())}
        # The revised Natural has a narrow high-curvature region near saturated
        # yellow. Bound its tail explicitly rather than claiming a uniform
        # per-channel approximation. Photo-specific gates live in the verifier.
        assert measurement["mean_absolute_error_8bit"] < .1, measurement
        assert measurement["p99_absolute_error_8bit"] < 1, measurement
        assert measurement["p999_absolute_error_8bit"] < 4, measurement
        assert measurement["maximum_absolute_error_8bit"] < 16, measurement
        assets.append({"file":filename,"name":name,"style_index":index+4,"identifier":identifier,
                       "provenance":"Flickerly original authored LUT, fitted with a new conditional NILUT; not an upstream sample style",
                       "model_sha256":model_sha,"target_sha256":training["targets"][index]["sha256"],
                       "bytes":len(data),"sha256":hashlib.sha256(data).hexdigest(),
                       "reference_output_srgb":predict(original_model,oracle_rgb,index).tolist()})
        measurements.append({"style":index+4,"measurements":[measurement]})
        print(json.dumps({"file":filename,"bytes":len(data),"measurements":measurement}),flush=True)
    manifest = {
        "source": "https://github.com/mv-lab/nilut", "revision": REVISION,
        "model_sha256": hashlib.sha256((SOURCE/"model/nilutx3style.pt").read_bytes()).hexdigest(),
        "dimension": DIMENSION, "format": "v1, little-endian float16 RGB, red fastest, blue slowest",
        "color_space": "encoded sRGB input and output, opaque alpha",
        "reference_input_srgb8": patches.tolist(), "styles": assets,
    }
    manifest_bytes = (json.dumps(manifest,indent=2)+"\n").encode()
    notice = (
        "NILUT: Conditional Neural Implicit 3D Lookup Tables for Image Enhancement\n"
        "Marcos V. Conde, Javier Vazquez-Corral, Michael S. Brown, Radu Timofte. AAAI 2024.\n"
        "https://github.com/mv-lab/nilut\n"
        f"Source revision: {REVISION}\n\n"
        "N1-N3 were generated from the official nilutx3style.pt weights.\n"
        "Style 1 = LUT01; Style 2 = LUT03; Style 3 = LUT04.\n"
        "The original model is approximated with a 65x65x65 sRGB lattice.\n"
        "NILUT source copyright (c) 2023 Marcos V. Conde, MIT License (see LICENSE.txt).\n"
        "\nN4 Natural, N5 Soft Warm and N6 Cool Matte are original Flickerly grades.\n"
        "A separate conditional residual NILUT was fitted to three authored 65-cubed LUTs.\n"
        "N4 and N5 use the revised v2 targets/network; N6 retains the v1 network output.\n"
        "No upstream model weights, style mixtures, or photographs were used for that fit.\n"
        "Architecture adapted from the MIT-licensed NILUT implementation.\n"
        "Training sources, target LUTs, checkpoint, hashes and measured errors are preserved\n"
        "in scripts/train_nilut_originals.py and artifacts/nilut-originals/.\n"
        "All six styles are baked offline; only their color cubes ship in the app.\n"
    ).encode()
    text_assets = {
        "manifest.json": manifest_bytes,
        "LICENSE.txt": (SOURCE/"upstream/LICENSE").read_bytes(),
        "NOTICE.txt": notice,
    }
    for name, data in text_assets.items():
        if args.check:
            assert (DESTINATION/name).read_bytes() == data, name
        else:
            (DESTINATION/name).write_bytes(data)
    if not args.check:
        (REPORT/"lut-accuracy.json").write_text(json.dumps(measurements,indent=2)+"\n")
    print("Verified bundled NILUT assets" if args.check else "Generated bundled NILUT assets", flush=True)


if __name__ == "__main__":
    main()
