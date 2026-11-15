import re, subprocess, sys, os
G = os.environ.get("GODOT", "C:/Users/richa/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe")
L = os.path.join(os.path.dirname(os.path.abspath(__file__)), "godot_lock.py")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(os.environ.get("TEMP", "."), "mm_verify_logs")
os.makedirs(OUT, exist_ok=True)
ANSI = re.compile(r"\x1b\[[0-9;]*m")

def run(name, args):
    p = subprocess.run([sys.executable, L, G] + args, cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace")
    txt = ANSI.sub("", p.stdout + p.stderr)
    open(os.path.join(OUT, name + ".log"), "w", encoding="utf-8").write(txt)
    keys = [l.strip() for l in txt.splitlines() if re.match(r"\s*(Tests|Passing Tests|Failing Tests|Risky/Pending)\s+\d+", l)]
    fails = [l.strip() for l in txt.splitlines() if "[Failed]" in l]
    print(f"== {name} (exit {p.returncode}): " + "; ".join(keys))
    for f in fails[:10]:
        print("   " + f)
    sys.stdout.flush()

run("import", ["--headless", "--path", ".", "--import"])
run("full_headless", ["--headless", "--path", ".", "-s", "addons/gut/gut_cmdln.gd", "-gdir=res://test", "-gexit"])
GPU = ["test_noise3d", "test_hlsl_translation", "test_tex3d_buffer", "test_voxel_eval", "test_voxel_wood",
       "test_voxel_recipes", "test_voxel_hlsl_parity", "test_voxel_mesh_bake", "test_voxel_surface_pattern",
       "test_legacy_noise_hash", "test_voxel_export", "test_voxel_master", "test_exact_hash_nodes",
       "test_volume_export_formats"]
for t in GPU:
    run("gpu_" + t, ["--path", ".", "-s", "addons/gut/gut_cmdln.gd", f"-gtest=res://test/{t}.gd", "-gexit"])
