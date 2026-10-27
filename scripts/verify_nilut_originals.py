"""Validate learned grades against independent targets and bundled cubes.

This checks numerical fidelity, not whether a look is aesthetically preferable.
Photos are held out from training and used only for evaluation/visual review.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from generate_nilut_luts import sample_cube
from nilut_original_grades import STYLES, grade, linearize, encode, to_lab
from preview_nilut_originals import SOURCES, srgb_image
from train_nilut_originals import load_style_model, predict

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT/"artifacts/nilut-originals"


def errors(actual, expected):
    error = np.abs(actual-expected)*255
    return {"mean_8bit":float(error.mean()), "p99_8bit":float(np.quantile(error,.99)), "max_8bit":float(error.max())}


def main():
    torch.set_num_threads(4)
    training = json.loads((OUTPUT/"training.json").read_text())
    # Different seed and distribution from the trainer's validation set.
    random = np.random.default_rng(24035).random((65536,3),dtype=np.float32)
    axis=np.linspace(0,1,129,dtype=np.float32)
    u,v=np.meshgrid(axis,axis,indexing="ij")
    faces=np.concatenate([np.stack([u,v,np.full_like(u,end)],-1).reshape(-1,3)[:,order]
                          for end in (0,1) for order in ([0,1,2],[0,2,1],[2,0,1])])
    neutral=np.repeat(np.linspace(0,1,1024,dtype=np.float32)[:,None],3,1)
    photos=[]
    for name,path,_ in SOURCES:
        image=srgb_image(path)
        image.thumbnail((512,512))
        photos.append((name,np.asarray(image).reshape(-1,3).astype(np.float32)/255))
    results=[]
    for index,(_,slug,_) in enumerate(STYLES):
        model, _ = load_style_model(training, index)
        packed=(ROOT/"Flickerly/Resources/NILUT"/f"{slug}.nlut").read_bytes()
        if slug == "cool-matte":
            assert packed == (OUTPUT/"v1/resources/cool-matte.nlut").read_bytes(), "Approved N6 output must stay unchanged"
        cube=np.frombuffer(packed[16:],dtype="<f2").astype(np.float32).reshape(65,65,65,3)
        measurements={"style":slug,"sha256":hashlib.sha256(packed).hexdigest()}
        for name,source in [("random_rgb",random),("gamut_faces",faces),("neutral_ramp",neutral),*photos]:
            output=predict(model,source,index)
            fidelity=errors(output,grade(source,index))
            approximation=errors(sample_cube(cube,source),output)
            measurements[name]={"samples":len(source),"model_vs_authored_target":fidelity,"cube_vs_model":approximation}
            if index < 2 and name in ("still-life", "landscape", "bird"):
                new = encode(.2*linearize(source)+.8*linearize(sample_cube(cube,source)))
                old_cube = np.frombuffer((OUTPUT/"v1/resources"/f"{slug}.nlut").read_bytes()[16:],dtype="<f2").astype(np.float32).reshape(65,65,65,3)
                old = encode(.2*linearize(source)+.8*linearize(sample_cube(old_cube,source)))
                distance = np.linalg.norm(to_lab(new)-to_lab(source),axis=-1)*100
                old_distance = np.linalg.norm(to_lab(old)-to_lab(source),axis=-1)*100
                visibility = {"intensity":.8,"mean_srgb8_change":float(np.abs(new-source).mean()*255),
                              "mean_oklab_distance_x100":float(distance.mean()),
                              "previous_mean_oklab_distance_x100":float(old_distance.mean())}
                measurements[name]["visible_change"] = visibility
                assert visibility["mean_srgb8_change"] > 4, visibility
                assert visibility["mean_oklab_distance_x100"] > 1.7*visibility["previous_mean_oklab_distance_x100"], visibility
            assert np.isfinite(output).all() and output.min()>=0 and output.max()<=1
            if name == "random_rgb":
                assert fidelity["mean_8bit"] < .75 and fidelity["p99_8bit"] < 4, measurements
            if name not in ("gamut_faces",):
                assert approximation["mean_8bit"] < .25 and approximation["p99_8bit"] < 1, measurements
            if name in ("still-life", "landscape", "bird", "portrait-light", "portrait-deep"):
                assert approximation["mean_8bit"] < .1 and approximation["p99_8bit"] < .75, measurements
            if name == "neutral_ramp":
                assert np.diff(output,axis=0).min() > -.001, measurements
                assert (output[-1]*255).min() >=252, measurements
                if index==0:
                    assert np.ptp(output,axis=-1).max()*255 <3, measurements
        results.append(measurements)
        print(json.dumps(measurements),flush=True)
    (OUTPUT/"validation.json").write_text(json.dumps(results,indent=2)+"\n")
    print("Verified learned originals, independent RGB/scene samples, and shipped cubes.",flush=True)


if __name__ == "__main__":
    main()
