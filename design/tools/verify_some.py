"""Re-run some GPU test files through verify_all's runner."""
import sys, importlib.util
spec = importlib.util.spec_from_file_location("va_src", __file__.replace("verify_some.py", "verify_all.py"))
src = open(spec.origin, encoding="utf-8").read()
# keep everything above the run sequence (definitions), then run only the requested GPU files
head = src.split("run(\"import\"")[0]
exec(compile(head, spec.origin, "exec"))
for t in sys.argv[1:]:
    run("gpu_" + t, ["--path", ".", "-s", "addons/gut/gut_cmdln.gd", f"-gtest=res://test/{t}.gd", "-gexit"])
