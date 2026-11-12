#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_file="$repo_root/apps.json"

jq -e '
  type == "array" and length > 0 and
  (map(.token) | length == (unique | length)) and
  all(.[]; (.token | type == "string" and test("^[a-z0-9-]+$")) and
           (.name | type == "string" and length > 0) and
           (.repo | type == "string" and test("^[^/]+/[^/]+$")) and
           (.desc | type == "string" and length > 0) and
           (.homepage | type == "string" and startswith("https://")) and
           (.license | type == "string" and length > 0) and
           (.asset_prefix | type == "string" and length > 0))
' "$apps_file" >/dev/null

for cask in "$repo_root"/Casks/*.rb; do
  [ -f "$cask" ]
  if command -v ruby >/dev/null 2>&1; then
    ruby -c "$cask" >/dev/null
  fi
done

if command -v brew >/dev/null 2>&1; then
  brew_major="$(brew --version 2>/dev/null | sed -n 's/^Homebrew \([0-9][0-9]*\)\..*/\1/p' | head -n 1)"
  if [ -n "$brew_major" ] && [ "$brew_major" -ge 7 ]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew style "$repo_root"/Casks/*.rb
  fi
fi

for manifest in "$repo_root"/bucket/*.json; do
  [ -f "$manifest" ]
  jq -e '
    .version and
    .description and
    .homepage and
    .license and
    .architecture["64bit"].url and
    (.architecture["64bit"].hash | test("^[0-9a-f]{64}$")) and
    .architecture["arm64"].url and
    (.architecture["arm64"].hash | test("^[0-9a-f]{64}$")) and
    ((.shortcuts // []) | length > 0) and
    .checkver and
    .autoupdate.hash.url
  ' "$manifest" >/dev/null
  diff -u "$manifest" <(jq --indent 4 . "$manifest")
done

if command -v ruby >/dev/null 2>&1; then
  ruby -rpsych -rdate -e '
    Dir.glob(File.join(ARGV[0], "winget/manifests/*/*/*/*")).sort.each do |ver_dir|
      next unless File.directory?(ver_dir)
      expected_ver = File.basename(ver_dir)
      pkg_name = File.basename(File.dirname(ver_dir))
      publisher = File.basename(File.dirname(File.dirname(ver_dir)))
      expected_id = "#{publisher}.#{pkg_name}"

      files = Dir.glob(File.join(ver_dir, "*.yaml")).sort
      raise "Empty WinGet directory: #{ver_dir}" if files.empty?

      types = []
      files.each do |f|
        doc = Psych.safe_load_file(f, permitted_classes: [Date])
        raise "Invalid YAML root in #{f}" unless doc.is_a?(Hash)
        raise "PackageIdentifier mismatch in #{f}" unless doc["PackageIdentifier"] == expected_id
        raise "PackageVersion mismatch in #{f}" unless doc["PackageVersion"].to_s == expected_ver
        raise "Missing ManifestVersion in #{f}" unless doc["ManifestVersion"] == "1.12.0"
        types << doc["ManifestType"]
      end
      %w[version installer defaultLocale].each do |req|
        raise "Missing ManifestType=#{req} in #{ver_dir}" unless types.include?(req)
      end
    end
  ' "$repo_root"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

while IFS= read -r app_json; do
  token="$(jq -r '.token' <<<"$app_json")"
  app_bundle="$(jq -r '.app_bundle' <<<"$app_json")"
  bundle_id="$(jq -r '.bundle_id' <<<"$app_json")"
  macos_min="$(jq -r '.macos_min // empty' <<<"$app_json")"
  windows_service="$(jq -r '.windows_service // empty' <<<"$app_json")"
  winget_id="$(jq -r '.winget_id // empty' <<<"$app_json")"
  prefix="$(jq -r '.asset_prefix' <<<"$app_json")"

  grep -Fq "app \"${app_bundle}\"" "$repo_root/Casks/${token}.rb"
  grep -Fq 'postflight_steps do' "$repo_root/Casks/${token}.rb"
  grep -Fq 'run "/usr/bin/xattr"' "$repo_root/Casks/${token}.rb"
  grep -Fq 'com.apple.quarantine' "$repo_root/Casks/${token}.rb"
  grep -Fq "uninstall quit: \"${bundle_id}\"" "$repo_root/Casks/${token}.rb"
  if [ -n "$macos_min" ]; then
    grep -Fq "depends_on macos: :${macos_min}" "$repo_root/Casks/${token}.rb"
  fi
  if [ -n "$windows_service" ]; then
    jq -e --arg svc "$windows_service" 'any(.pre_uninstall[]; contains("$cmd -eq '\''uninstall'\''") and contains($svc))' "$repo_root/bucket/${token}.json" >/dev/null
  fi

  sums_file="$tmp_dir/${token}-SHA256SUMS.txt"
  cat > "$sums_file" <<EOF
1111111111111111111111111111111111111111111111111111111111111111  ${prefix}-1.0.0-macos-arm64.dmg
2222222222222222222222222222222222222222222222222222222222222222  ${prefix}-1.0.0-macos-amd64.dmg
3333333333333333333333333333333333333333333333333333333333333333  ${prefix}-1.0.0-linux-arm64.tar.gz
4444444444444444444444444444444444444444444444444444444444444444  ${prefix}-1.0.0-linux-amd64.tar.gz
5555555555555555555555555555555555555555555555555555555555555555  ${prefix}-1.0.0-windows-amd64.zip
6666666666666666666666666666666666666666666666666666666666666666  ${prefix}-1.0.0-windows-arm64.zip
7777777777777777777777777777777777777777777777777777777777777777  ${prefix}-1.0.0-windows-amd64-setup.exe
8888888888888888888888888888888888888888888888888888888888888888  ${prefix}-1.0.0-windows-arm64-setup.exe
EOF
  bash "$repo_root/scripts/sync_app.sh" "$token" "1.0.0" "$sums_file" "$tmp_dir" "$apps_file" "2026-11-10"
  test -s "$tmp_dir/Casks/${token}.rb"
  test -s "$tmp_dir/bucket/${token}.json"
  if [ -n "$winget_id" ]; then
    publisher="${winget_id%%.*}"
    pkg_name="${winget_id#*.}"
    first_char="$(printf '%s' "$publisher" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    test -s "$tmp_dir/winget/manifests/${first_char}/${publisher}/${pkg_name}/1.0.0/${winget_id}.installer.yaml"
  fi
done < <(jq -c '.[]' "$apps_file")
