#!/usr/bin/env bash
set -euo pipefail

required=(
  project.yml
  Package.swift
  Sources/ForgeCore/MachO.swift
  Sources/ForgeCore/ArArchive.swift
  Sources/ForgeCore/TarArchive.swift
  Sources/IPAPayloadLab/App/IPAPayloadLabApp.swift
  Sources/IPAPayloadLab/Info.plist
  .github/workflows/main.yml
)

for path in "${required[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
import json
import plistlib

with Path("Sources/IPAPayloadLab/Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion"):
    if key not in plist:
        raise SystemExit(f"Info.plist is missing {key}")

for path in Path("Resources/Assets.xcassets").rglob("Contents.json"):
    json.loads(path.read_text(encoding="utf-8"))

project = Path("project.yml").read_text(encoding="utf-8")
if "exactVersion: 4.9." in project:
    raise SystemExit("SWCompression 4.9.x requires iOS 17 but this project targets iOS 16")
if "exactVersion: 4.8.7" not in project:
    raise SystemExit("Expected the iOS 16-compatible SWCompression 4.8.7 pin")

payload_service = Path(
    "Sources/IPAPayloadLab/Services/PayloadPreparationService.swift"
).read_text(encoding="utf-8")
if "entries: [ForgeCore.TarEntry]" not in payload_service:
    raise SystemExit("ForgeCore.TarEntry must be module-qualified to avoid SWCompression ambiguity")
if "ForgeCore.TarArchive.open(tarData)" not in payload_service:
    raise SystemExit("ForgeCore.TarArchive must be module-qualified at the dependency boundary")

picker = Path("Sources/IPAPayloadLab/Views/DocumentPicker.swift").read_text(encoding="utf-8")
if "types = [.item]" not in picker or "types = [.item, .folder]" not in picker:
    raise SystemExit("Document picker must use broad provider-compatible content types")
if "asCopy: true" not in picker or "asCopy: false" in picker:
    raise SystemExit("Document picker must import a copy instead of opening provider files in place")

path_policy = Path("Sources/ForgeCore/PathPolicy.swift").read_text(encoding="utf-8")
pipeline = Path("Sources/IPAPayloadLab/Services/PatchPipeline.swift").read_text(encoding="utf-8")
if "validateFileName(_ name: String)" not in path_policy:
    raise SystemExit("Missing dedicated payload file-name validation")
if "PathPolicy.validateFileName(asset.name)" not in pipeline:
    raise SystemExit("Patch pipeline must validate payload names as single path components")
if 'standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")' in pipeline:
    raise SystemExit("Patch pipeline still contains the fragile URL-prefix comparison")
PY

if find Sources Tests -type f -name '*.swift' -print0 | xargs -0 grep -n $'\t' >/dev/null; then
  echo "Swift files must use spaces instead of tabs" >&2
  exit 1
fi

echo "Repository layout checks passed."
