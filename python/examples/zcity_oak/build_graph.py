"""Builds material_maker/examples/voxel_oak.ptex: voxkit's oak as a 3D graph.

    python build_graph.py --mm "<godot> --path <repo> --" [--out voxel_oak.ptex] [--port 7693]

The graph is Voxel Inputs -> Voxel Wood -> Voxel Material (linear albedo,
bump 1), the context values set for the 162 x 18 x 18 voxel oak beam of
ZCity's kit test (seed 21, age 0.6, grain along x, pith at (6.48, 11.34)
voxels across the beam).  A remote node "Oak" controls the four arch
parameters of the wood and has two presets:

    voxkit  every parameter at the value of voxkit's appearance.wood()
    zcity   gentler arches (starting values, to be tuned by eye)

Needs numpy only through material_maker_client (no numpy is used here).
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from material_maker_client import launch  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_OUT = os.path.join(REPO, "material_maker", "examples", "voxel_oak.ptex")

UPM = 81.0
BEAM = {"seed": 21, "age": 0.6, "pith_voxels": (6.48, 11.34)}  # w*0.36, h*0.63 of an 18 x 18 beam

# Voxel Inputs outputs -> Voxel Wood inputs
WIRES = [(2, 0), (1, 1), (8, 2), (9, 3), (3, 4), (5, 5), (10, 6)]  # Seed, Normal, Axis, Origin, Age, Fresh, Footprint

# the arch parameters controlled by the remote node: (label, wood parameter)
REMOTE = [("Flow amount", "flow_amount"), ("Flow scale", "flow_scale"), ("Pith wander", "pith_wander"), ("Ripple amount", "ripple_amount")]
PRESETS = {
    "voxkit": [7.0, 0.014, 4.0, 0.7],
    # (the plan's starting values were 3.0, 0.009, 2.0, 0.4; these keep the ring count and bring the arches
    # down to about 0.3 of voxkit's, see README.md)
    "zcity": [4.0, 0.006, 1.0, 0.2],
}


def build(mm, out):
    mm.new_graph()
    mm.create_node(type="voxel_inputs", name="Inputs", position=[0, 0])
    mm.create_node(type="voxel_wood", name="Wood", position=[420, 0])
    mm.create_node(type="material_voxel", name="Beam", position=[840, 0])
    for src, dst in WIRES:
        mm.connect("Inputs", "Wood", from_port=src, to_port=dst)
    mm.connect("Wood", "Beam", from_port=0, to_port=0)  # Albedo -> albedo_tex
    mm.connect("Wood", "Beam", from_port=2, to_port=2)  # Roughness -> roughness_tex
    mm.connect("Wood", "Beam", from_port=1, to_port=6)  # Bump -> bump_tex
    mm.set_parameter("Beam", "linear_albedo", True)
    mm.set_parameter("Beam", "bump", 1.0)

    pu, pv = BEAM["pith_voxels"]
    values = {
        "Inputs:vox_seed": BEAM["seed"], "Inputs:vox_age": BEAM["age"],
        "Inputs:vox_axis_x": 1.0, "Inputs:vox_axis_y": 0.0, "Inputs:vox_axis_z": 0.0,
        "Inputs:vox_origin_x": 0.0, "Inputs:vox_origin_y": pu / UPM, "Inputs:vox_origin_z": pv / UPM,
    }
    mm.set_parameters(values)

    widgets = [{"name": "param%d" % i, "label": label, "type": "linked_control",
                "linked_widgets": [{"node": "Wood", "widget": parameter}]}
               for i, (label, parameter) in enumerate(REMOTE)]
    mm.create_node(item={"type": "remote", "widgets": widgets}, name="Oak", position=[420, -360])
    for preset in ("zcity", "voxkit"):  # ends on voxkit: the graph is saved with the voxkit values
        mm.set_parameters({"Oak:param%d" % i: v for i, v in enumerate(PRESETS[preset])})
        mm.save_preset(preset, node="Oak")
    mm.save(out)
    drop_default_material(out)


def drop_default_material(path):
    """A new graph comes with a Static PBR Material node, that the server cannot delete and that
    would be the graph's material for exports: remove it from the saved file (as the .ptex files
    of the voxel tests have only the Voxel Material)"""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    nodes = [n for n in data["nodes"] if n.get("type") != "material"]
    names = {n["name"] for n in nodes}
    data["nodes"] = nodes
    data["connections"] = [c for c in data.get("connections", []) if c["from"] in names and c["to"] in names]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent="\t", sort_keys=True, ensure_ascii=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mm", required=True, help='the Material Maker command, e.g. "godot --path <repo> --"')
    ap.add_argument("--out", default=DEFAULT_OUT, help="the .ptex file to write")
    ap.add_argument("--port", type=int, default=7693)
    args = ap.parse_args()
    process, mm = launch(args.mm, port=args.port)
    try:
        build(mm, os.path.abspath(args.out))
        print("wrote", os.path.abspath(args.out))
    finally:
        try:
            mm.quit()
        except Exception:
            pass
        try:
            process.wait(60)
        except Exception:
            process.kill()


if __name__ == "__main__":
    main()
