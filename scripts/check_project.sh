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
  .github/workflows/build.yml
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
PY

if find Sources Tests -type f -name '*.swift' -print0 | xargs -0 grep -n $'\t' >/dev/null; then
  echo "Swift files must use spaces instead of tabs" >&2
  exit 1
fi

echo "Repository layout checks passed."
