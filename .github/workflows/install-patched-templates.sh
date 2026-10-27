#!/bin/bash
# Installs the export templates built with Material Maker's Godot patches
# (godot-templates-build.yml) over the official ones, for --headless rendering
# in the exported application.
# usage: install-patched-templates.sh <export templates directory> <platform>...
# (platforms: linux, windows, macos)
# Needs GH_TOKEN, GITHUB_REPOSITORY and GODOT_VERSION. Without patched
# templates, or with templates built from other patches, the official
# templates are kept (Material Maker then renders --headless runs with a
# hidden window).
set -u
TEMPLATES_DIR="$1"
shift
TAG="godot-templates-${GODOT_VERSION}"
PATCH_HASH=$(cat material_maker/misc/mm.patch material_maker/misc/headless.patch | sha256sum 2>/dev/null || cat material_maker/misc/mm.patch material_maker/misc/headless.patch | shasum -a 256)
PATCH_HASH=$(echo "$PATCH_HASH" | cut -c1-16)
NOTES=$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json body --jq .body 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "::warning::No $TAG release (run the Build Export Templates workflow): using the official templates"
  exit 0
fi
if [[ "$NOTES" != *"patches: ${PATCH_HASH}"* ]]; then
  echo "::warning::The $TAG release was built from other patches than mm.patch and headless.patch (${PATCH_HASH}): using the official templates"
  exit 0
fi
DOWNLOAD_DIR=$(mktemp -d)
for platform in "$@"; do
  gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --pattern "export_templates_${platform}.zip" --dir "$DOWNLOAD_DIR" || exit 1
  unzip -o "$DOWNLOAD_DIR/export_templates_${platform}.zip" -d "$TEMPLATES_DIR" || exit 1
  echo "Installed the patched ${platform} templates"
done
ls -la "$TEMPLATES_DIR"
