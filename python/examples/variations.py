"""Renders seed variations of a material and exports each one.

    python variations.py <material_maker command> <graph.ptex> <output dir> [count] [port]

for example:

    python variations.py "godot --path ../.." bricks.ptex out 4
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from material_maker_client import DEFAULT_PORT, launch, split_command  # noqa: E402

command, graph, output_dir = split_command(sys.argv[1]), sys.argv[2], sys.argv[3]
count = int(sys.argv[4]) if len(sys.argv) > 4 else 4
port = int(sys.argv[5]) if len(sys.argv) > 5 else DEFAULT_PORT
name = os.path.splitext(os.path.basename(graph))[0]

process, mm = launch(command, port=port, graph=graph)
try:
    for i in range(count):
        if i > 0:
            mm.reseed()
        prefix = os.path.join(output_dir, "%s_%d" % (name, i))
        mm.render("Material", prefix + ".png", output=0, size=512)
        mm.export("Godot/Godot 4 Standard", prefix)
        print("Exported", prefix)
finally:
    mm.quit()
    process.wait(30)
