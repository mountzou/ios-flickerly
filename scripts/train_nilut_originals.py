"""Fit a new conditional residual NILUT to three Flickerly-authored 3D LUTs.

Architecture adapted from mv-lab/nilut (MIT, see bundled LICENSE.txt).
Original upstream weights are never read or modified by this trainer.
CPU seed and optimizer schedule are fixed. Photos are validation-only.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn

from nilut_original_grades import STYLES, grade, grid

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "artifacts/nilut-originals"


class OriginalNILUT(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(nn.Linear(6, 256), nn.ReLU(),
                                 nn.Linear(256, 256), nn.Tanh(),
                                 nn.Linear(256, 256), nn.Tanh(), nn.Linear(256, 3))

    def raw(self, rgb, styles):
        conditions = nn.functional.one_hot(styles, 3).to(rgb.dtype)
        return rgb + self.net(torch.cat([rgb, conditions], -1))

    def forward(self, rgb, styles):
        return torch.clamp(self.raw(rgb, styles), 0, 1)


class EncodedNILUT(OriginalNILUT):
    """Low-frequency RGB features help fit the revised, steeper color mapping.

    Coordinates still refer only to RGB, with no spatial/image features. The
    legacy network remains available for byte-identical N6 regeneration.
    """
    def __init__(self):
        super().__init__()
        self.net[0] = nn.Linear(18, 256)

    def raw(self, rgb, styles):
        conditions = nn.functional.one_hot(styles, 3).to(rgb.dtype)
        features = [rgb]
        for frequency in (np.pi, 2*np.pi):
            features.extend([torch.sin(rgb*frequency), torch.cos(rgb*frequency)])
        return rgb + self.net(torch.cat([*features, conditions], -1))


@torch.inference_mode()
def predict(model, rgb, index):
    outputs = []
    for chunk in np.array_split(rgb, max(1, int(np.ceil(len(rgb)/32768)))):
        inputs = torch.from_numpy(chunk.astype(np.float32))
        outputs.append(model(inputs, torch.full((len(inputs),), index)).numpy())
    return np.concatenate(outputs)


def load_style_model(training, index):
    """N6 retains the approved v1 network output while N4/N5 are revised."""
    entry = training.get("retained_styles", {}).get(STYLES[index][1], training)
    path = OUTPUT / entry.get("model_file", "models/flickerly-originals-v1.pt")
    assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["model_sha256"]
    architecture = EncodedNILUT if entry.get("architecture_kind") == "fourier" else OriginalNILUT
    model = architecture().eval().requires_grad_(False)
    model.load_state_dict(torch.load(path, map_location="cpu", weights_only=True)["model"], strict=True)
    return model, entry["model_sha256"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--steps", type=int, default=24000)
    parser.add_argument("--targets-only", action="store_true")
    args = parser.parse_args()
    torch.set_num_threads(4)
    torch.manual_seed(35035)
    np.random.seed(35035)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT/"targets").mkdir(exist_ok=True)
    (OUTPUT/"models").mkdir(exist_ok=True)
    rgb = grid()
    targets = []
    target_metadata = []
    for index, (_, slug, name) in enumerate(STYLES):
        path = OUTPUT/"targets"/f"{slug}.cube"
        target = grade(rgb, index)
        version = 2 if index < 2 else 1
        header = f'TITLE "Flickerly {name} original target v{version}"\nLUT_3D_SIZE 65\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n'
        with path.open("w") as file:
            file.write(header)
            np.savetxt(file, target, fmt="%.8f")
        targets.append(target)
        target_metadata.append({"file": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        print(f"Authored target: {name}", flush=True)
    if args.targets_only:
        return
    inputs = torch.from_numpy(rgb)
    labels = torch.from_numpy(np.stack(targets))
    boundary_indices = torch.from_numpy(np.flatnonzero(((rgb == 0) | (rgb == 1)).any(-1)))
    # Independent off-grid samples catch interpolation/fit failures.
    validation = np.random.default_rng(9071).random((32768, 3), dtype=np.float32)
    expected = [grade(validation, i) for i in range(3)]
    # Oversample neutral ramp and representative skin hues, including dark tones.
    neutral = np.repeat(np.linspace(0, 1, 1024, dtype=np.float32)[:, None], 3, 1)
    skin_bases = np.array([[.91,.73,.63],[.78,.53,.39],[.45,.29,.22],[.27,.17,.13]], dtype=np.float32)
    skin = np.concatenate([np.clip(base + np.linspace(-.07,.07,128)[:,None], 0, 1) for base in skin_bases]).astype(np.float32)
    anchors = np.concatenate([neutral, skin])
    anchor_rgb = torch.from_numpy(anchors)
    anchor_targets = torch.from_numpy(np.stack([grade(anchors, i) for i in range(3)]))
    model = EncodedNILUT()
    nn.init.zeros_(model.net[-1].weight)
    nn.init.zeros_(model.net[-1].bias)
    optimizer = torch.optim.Adam(model.parameters(), lr=.001)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.steps, eta_min=.000025)
    start = time.monotonic()
    for step in range(args.steps):
        indices = torch.randint(len(inputs), (4096,))
        # Represent the gamut faces explicitly. Fit the unclamped residual so
        # out-of-range predictions still have a gradient at saturated colors.
        indices[:512] = boundary_indices[torch.randint(len(boundary_indices), (512,))]
        styles = torch.randint(3, (4096,))
        source, target = inputs[indices], labels[styles, indices]
        anchor_indices = torch.randint(len(anchors), (768,))
        anchor_styles = torch.randint(3, (768,))
        prediction = model.raw(source, styles)
        anchor_prediction = model.raw(anchor_rgb[anchor_indices], anchor_styles)
        loss = ((prediction-target)**2).mean() + .5*((anchor_prediction-anchor_targets[anchor_styles,anchor_indices])**2).mean() + .005*(prediction-target).abs().mean()
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        optimizer.step()
        scheduler.step()
        if step % 500 == 0 or step == args.steps-1:
            print(json.dumps({"step": step+1, "loss":float(loss.detach()), "seconds":round(time.monotonic()-start,1)}), flush=True)
    model.eval()
    metrics=[]
    for index, (_, slug, _) in enumerate(STYLES):
        error = np.abs(predict(model, validation, index)-expected[index])*255
        measurement = {"style": slug, "mean_8bit":float(error.mean()), "p99_8bit":float(np.quantile(error,.99)), "max_8bit":float(error.max())}
        metrics.append(measurement)
        print(json.dumps(measurement), flush=True)
    checkpoint = OUTPUT/"models/flickerly-originals-v2.pt"
    torch.save({"model":model.state_dict()}, checkpoint)
    retained = OUTPUT/"v1/flickerly-originals-v1.pt"
    metadata = {"version":2,"model_file":"models/flickerly-originals-v2.pt",
                "retained_styles":{"cool-matte":{"model_file":"v1/flickerly-originals-v1.pt","model_sha256":hashlib.sha256(retained.read_bytes()).hexdigest()}},
                "seed":35035,"steps":args.steps,"threads":4,"parameters":sum(p.numel() for p in model.parameters()),
                "architecture_kind":"fourier",
                "architecture":"18-256-ReLU-256-Tanh-256-Tanh-3; RGB + sin/cos(pi*RGB,2*pi*RGB) + 3-way one-hot, RGB residual + clamp",
                "torch":torch.__version__,"numpy":np.__version__,"training_inputs":"65^3 RGB lattice plus neutral/skin-color anchors; no photographs",
                "targets":target_metadata,"model_sha256":hashlib.sha256(checkpoint.read_bytes()).hexdigest(),"validation":metrics,
                "seconds":time.monotonic()-start}
    (OUTPUT/"training.json").write_text(json.dumps(metadata,indent=2)+"\n")


if __name__ == "__main__":
    main()
