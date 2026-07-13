#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 APP_PATH PACKAGE_DIR OUTPUT_IPA" >&2
  exit 64
fi

app_path="$1"
package_dir="$2"
output_ipa="$3"

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi

rm -rf "$package_dir"
mkdir -p "$package_dir/Payload"
ditto "$app_path" "$package_dir/Payload/IPAPayloadLab.app"

plutil -lint "$package_dir/Payload/IPAPayloadLab.app/Info.plist"
test -x "$package_dir/Payload/IPAPayloadLab.app/IPAPayloadLab"
file "$package_dir/Payload/IPAPayloadLab.app/IPAPayloadLab" | grep -q 'Mach-O'

rm -f "$output_ipa"
(
  cd "$package_dir"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$output_ipa"
)

unzip -t "$output_ipa"
unzip -l "$output_ipa" | grep -q 'Payload/IPAPayloadLab.app/IPAPayloadLab'
test -s "$output_ipa"
echo "Created verified unsigned IPA: $output_ipa"
