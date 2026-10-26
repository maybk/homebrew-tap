#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_file="$repo_root/apps.json"

jq -e 'type == "array" and length > 0' "$apps_file" >/dev/null

for cask in "$repo_root"/Casks/*.rb; do
  [ -f "$cask" ]
  if command -v ruby >/dev/null 2>&1; then
    ruby -c "$cask" >/dev/null
  fi
  grep -Fq 'postflight_steps do' "$cask"
  grep -Fq 'run "/usr/bin/xattr"' "$cask"
  grep -Fq 'com.apple.quarantine' "$cask"
done

for manifest in "$repo_root"/bucket/*.json; do
  [ -f "$manifest" ]
  jq -e '.version and .architecture["64bit"].url and .architecture["arm64"].url' "$manifest" >/dev/null
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/SHA256SUMS.txt" <<'EOF'
1111111111111111111111111111111111111111111111111111111111111111  tunnelkit-1.0.0-macos-arm64.dmg
2222222222222222222222222222222222222222222222222222222222222222  tunnelkit-1.0.0-macos-amd64.dmg
3333333333333333333333333333333333333333333333333333333333333333  tunnelkit-1.0.0-linux-arm64.tar.gz
4444444444444444444444444444444444444444444444444444444444444444  tunnelkit-1.0.0-linux-amd64.tar.gz
5555555555555555555555555555555555555555555555555555555555555555  tunnelkit-1.0.0-windows-amd64.zip
6666666666666666666666666666666666666666666666666666666666666666  tunnelkit-1.0.0-windows-arm64.zip
7777777777777777777777777777777777777777777777777777777777777777  tunnelkit-1.0.0-windows-amd64-setup.exe
8888888888888888888888888888888888888888888888888888888888888888  tunnelkit-1.0.0-windows-arm64-setup.exe
EOF

bash "$repo_root/scripts/sync_app.sh" tunnelkit "1.0.0" "$tmp_dir/SHA256SUMS.txt" "$tmp_dir" "$apps_file"
test -s "$tmp_dir/Casks/tunnelkit.rb"
test -s "$tmp_dir/bucket/tunnelkit.json"
test -s "$tmp_dir/winget/manifests/m/maybk/TunnelKit/1.0.0/maybk.TunnelKit.installer.yaml"
