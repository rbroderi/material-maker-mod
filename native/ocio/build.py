"""Builds the OpenColorIO GDExtension of Material Maker.

    python native/ocio/build.py [--generator "Visual Studio 18 2026"] [--jobs n]

Downloads OpenColorIO and godot-cpp into native/ocio/build, builds and
installs OpenColorIO (with its dependencies), then builds the extension and
copies it, OpenColorIO's library and mm_ocio.gdextension to
addons/material_maker/ocio. Run Material Maker's import (or open the project
in the editor) afterwards so Godot registers the extension.

Needs git, CMake 3.24+, Python 3 and a C++17 compiler.
"""

import argparse
import os
import shutil
import subprocess
import sys

OCIO_VERSION = "v2.6.0"
GODOT_CPP_VERSION = "godot-4.5-stable"

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")


def run(command):
    print(">", " ".join(command), flush=True)
    subprocess.check_call(command)


def clone(url, tag, directory):
    if not os.path.isdir(directory):
        run(["git", "clone", "--depth", "1", "--branch", tag, url, directory])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--generator", default=None, help="CMake generator (default: CMake's choice)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    if shutil.which("cmake") is None or shutil.which("git") is None:
        sys.exit("git and cmake must be in the PATH")
    generator = []
    if args.generator:
        generator = ["-G", args.generator] + (["-A", "x64"] if "Visual Studio" in args.generator else [])
    os.makedirs(BUILD, exist_ok=True)
    clone("https://github.com/AcademySoftwareFoundation/OpenColorIO.git", OCIO_VERSION, os.path.join(BUILD, "ocio-src"))
    clone("https://github.com/godotengine/godot-cpp.git", GODOT_CPP_VERSION, os.path.join(BUILD, "godot-cpp"))
    # OpenColorIO, as a shared library that includes its dependencies
    install = os.path.join(BUILD, "ocio-install")
    installed = any(os.path.isdir(os.path.join(install, d, "cmake", "OpenColorIO")) for d in ("lib", "lib64"))
    # Position independent code: OpenColorIO's static dependencies end up in a
    # shared library. On macOS, the library's install name is relative to
    # the extension (@rpath).
    if installed:
        print("OpenColorIO is already installed in", install)
    else:
        run(["cmake", "-S", os.path.join(BUILD, "ocio-src"), "-B", os.path.join(BUILD, "ocio-build")] + generator + [
            "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DCMAKE_INSTALL_NAME_DIR=@rpath",
            "-DCMAKE_INSTALL_PREFIX=" + install,
            "-DBUILD_SHARED_LIBS=ON", "-DOCIO_INSTALL_EXT_PACKAGES=ALL",
            "-DOCIO_BUILD_APPS=OFF", "-DOCIO_BUILD_TESTS=OFF", "-DOCIO_BUILD_GPU_TESTS=OFF",
            "-DOCIO_BUILD_PYTHON=OFF", "-DOCIO_BUILD_DOCS=OFF", "-DOCIO_BUILD_OPENFX=OFF",
            "-DOCIO_DIRECTX_ENABLED=OFF"])
        run(["cmake", "--build", os.path.join(BUILD, "ocio-build"), "--config", "Release", "--target", "install", "--parallel", str(args.jobs)])
    # The extension (copied to the addon by a post build step)
    run(["cmake", "-S", HERE, "-B", os.path.join(BUILD, "ext"), "-DCMAKE_BUILD_TYPE=Release"] + generator)
    run(["cmake", "--build", os.path.join(BUILD, "ext"), "--config", "Release", "--target", "mm_ocio", "--parallel", str(args.jobs)])
    print("Done: the extension is in addons/material_maker/ocio")


if __name__ == "__main__":
    main()
