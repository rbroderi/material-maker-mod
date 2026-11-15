"""Run a command while holding a machine-wide lock, so only one Godot /
Material Maker process runs at a time when several agents share this machine.

Usage: python design/tools/godot_lock.py <command> [args...]
Waits (up to 2 hours) for the lock, runs the command, prints its output and
exits with its exit code.
"""
import msvcrt
import os
import subprocess
import sys
import tempfile
import time

LOCK = os.path.join(tempfile.gettempdir(), "mm_godot_run.lock")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    f = open(LOCK, "a+b")
    start = time.time()
    announced = False
    while True:
        try:
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            break
        except OSError:
            if not announced:
                print("godot_lock: waiting for another Godot run to finish...", flush=True)
                announced = True
            if time.time() - start > 7200:
                print("godot_lock: gave up after 2 hours", flush=True)
                return 3
            time.sleep(2)
    try:
        return subprocess.call(sys.argv[1:])
    finally:
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
        f.close()


if __name__ == "__main__":
    sys.exit(main())
