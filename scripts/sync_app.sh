#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 6 ]; then
  echo "Usage: $0 <app-token> <version> <sha256sums-file> [output-dir] [apps-json] [release-date]" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_token="$1"
version="${2#v}"
sums_file="$3"
out_dir="${4:-$repo_root}"
apps_file="${5:-$repo_root/apps.json}"
release_date="${6:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must match MAJOR.MINOR.PATCH: $version" >&2
  exit 1
fi

if [ -n "$release_date" ] && [[ ! "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Release date must match YYYY-MM-DD: $release_date" >&2
  exit 1
fi

if [ ! -f "$sums_file" ]; then
  echo "SHA256SUMS file does not exist: $sums_file" >&2
  exit 1
fi

app_json="$(jq -cer --arg token "$app_token" '.[] | select(.token == $token)' "$apps_file")"
name="$(jq -r '.name' <<<"$app_json")"
repo="$(jq -r '.repo' <<<"$app_json")"
desc="$(jq -r '.desc' <<<"$app_json")"
desc_zh="$(jq -r '.desc_zh // empty' <<<"$app_json")"
homepage="$(jq -r '.homepage' <<<"$app_json")"
license="$(jq -r '.license' <<<"$app_json")"
macos_min="$(jq -r '.macos_min // empty' <<<"$app_json")"
app_bundle="$(jq -r '.app_bundle' <<<"$app_json")"
bundle_id="$(jq -r '.bundle_id' <<<"$app_json")"
dot_dir="$(jq -r '.dot_dir' <<<"$app_json")"
windows_bin="$(jq -r '.windows_bin' <<<"$app_json")"
windows_service="$(jq -r '.windows_service // empty' <<<"$app_json")"
windows_helper="$(jq -r '.windows_helper // empty' <<<"$app_json")"
winget_id="$(jq -r '.winget_id // empty' <<<"$app_json")"
winget_product_code="$(jq -r '.winget_product_code // empty' <<<"$app_json")"
winget_install_location="$(jq -r '.winget_install_location // empty' <<<"$app_json")"
asset_prefix="$(jq -r '.asset_prefix' <<<"$app_json")"

extract_sum() {
  local asset="$1"
  local sum
  sum="$(
    awk -v target="$asset" '
      NF >= 2 {
        file = $2
        sub(/^\*/, "", file)
        if (file == target) {
          print tolower($1)
          exit
        }
      }
    ' "$sums_file"
  )"
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Missing or invalid SHA-256 for $asset in $sums_file" >&2
    exit 1
  fi
  printf '%s' "$sum"
}

extract_optional_sum() {
  local asset="$1"
  awk -v target="$asset" '
    NF >= 2 {
      file = $2
      sub(/^\*/, "", file)
      if (file == target) {
        print tolower($1)
        exit
      }
    }
  ' "$sums_file"
}

macos_arm64_sha="$(extract_sum "${asset_prefix}-${version}-macos-arm64.dmg")"
macos_amd64_sha="$(extract_sum "${asset_prefix}-${version}-macos-amd64.dmg")"
linux_arm64_sha="$(extract_sum "${asset_prefix}-${version}-linux-arm64.tar.gz")"
linux_amd64_sha="$(extract_sum "${asset_prefix}-${version}-linux-amd64.tar.gz")"
windows_amd64_sha="$(extract_sum "${asset_prefix}-${version}-windows-amd64.zip")"
windows_arm64_sha="$(extract_sum "${asset_prefix}-${version}-windows-arm64.zip")"
windows_amd64_setup_sha="$(extract_optional_sum "${asset_prefix}-${version}-windows-amd64-setup.exe")"
windows_arm64_setup_sha="$(extract_optional_sum "${asset_prefix}-${version}-windows-arm64-setup.exe")"

format_ruby_list() {
  local pad="$1"
  shift
  local items=("$@")
  if [ "${#items[@]}" -eq 1 ]; then
    printf '"%s"' "${items[0]}"
  else
    printf '[\n'
    while IFS= read -r item; do
      [ -n "$item" ] && printf '%s  "%s",\n' "$pad" "$item"
    done < <(printf '%s\n' "${items[@]}" | LC_ALL=C sort -u)
    printf '%s]' "$pad"
  fi
}

render_zap_stanza() {
  local indent="$1"
  local del_json="$2"
  shift 2
  local trash_items=("$@")
  local del_items=()
  while IFS= read -r d; do
    [ -n "$d" ] && del_items+=("$d")
  done < <(jq -r '.[]' <<<"$del_json")

  if [ "${#del_items[@]}" -gt 0 ]; then
    local del_str trash_str
    del_str="$(format_ruby_list "${indent}    " "${del_items[@]}")"
    trash_str="$(format_ruby_list "${indent}    " "${trash_items[@]}")"
    printf '%szap delete: %s,\n%s    trash:  %s' "$indent" "$del_str" "$indent" "$trash_str"
  else
    local trash_str
    trash_str="$(format_ruby_list "$indent" "${trash_items[@]}")"
    printf '%szap trash: %s' "$indent" "$trash_str"
  fi
}

linux_bins_stanza="$(
  jq -r '.linux_binaries[] | "    binary \"" + . + "\""' <<<"$app_json"
)"

macos_zap_stanza="$(
  render_zap_stanza "    " "$(jq -c '.macos_zap_delete // []' <<<"$app_json")" \
    "${dot_dir}" \
    "~/Library/Application Support/${bundle_id}" \
    "~/Library/Caches/${bundle_id}" \
    "~/Library/Preferences/${bundle_id}.plist" \
    "~/Library/Saved Application State/${bundle_id}.savedState"
)"

linux_zap_stanza="$(
  render_zap_stanza "    " "$(jq -c '.linux_zap_delete // []' <<<"$app_json")" "${dot_dir}"
)"

macos_depends_stanza=""
if [ -n "$macos_min" ]; then
  macos_depends_stanza=$'\n'"    depends_on macos: :${macos_min}"$'\n'
fi

mkdir -p "$out_dir/Casks" "$out_dir/bucket"

cat > "$out_dir/Casks/${app_token}.rb" <<EOF
cask "${app_token}" do
  arch arm: "arm64", intel: "amd64"

  version "${version}"
  sha256 arm:          "${macos_arm64_sha}",
         intel:        "${macos_amd64_sha}",
         arm64_linux:  "${linux_arm64_sha}",
         x86_64_linux: "${linux_amd64_sha}"

  on_macos do
    url "https://github.com/${repo}/releases/download/v#{version}/${asset_prefix}-#{version}-macos-#{arch}.dmg"
${macos_depends_stanza}
    app "${app_bundle}"

    postflight_steps do
      run "/usr/bin/xattr",
          args:           ["-rd", "com.apple.quarantine", "{{appdir}}/${app_bundle}"],
          writable_paths: ["${app_bundle}"],
          writable_base:  :appdir
    end

    uninstall quit: "${bundle_id}"

${macos_zap_stanza}
  end
  on_linux do
    url "https://github.com/${repo}/releases/download/v#{version}/${asset_prefix}-#{version}-linux-#{arch}.tar.gz"

${linux_bins_stanza}

${linux_zap_stanza}
  end

  name "${name}"
  desc "${desc}"
  homepage "${homepage}"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
end
EOF

windows_proc="${windows_bin%.exe}"
jq --indent 4 -n \
  --arg version "$version" \
  --arg desc "$desc" \
  --arg homepage "$homepage" \
  --arg license "$license" \
  --arg repo "$repo" \
  --arg asset_prefix "$asset_prefix" \
  --arg name "$name" \
  --arg windows_bin "$windows_bin" \
  --arg windows_proc "$windows_proc" \
  --arg windows_service "$windows_service" \
  --arg windows_helper "$windows_helper" \
  --arg amd64_sha "$windows_amd64_sha" \
  --arg arm64_sha "$windows_arm64_sha" \
  '
  (
    ["Get-Process -Name '\''" + $windows_proc + "'\'' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue"]
    +
    (if ($windows_service != "" and $windows_helper != "") then
      [
        "if ($cmd -eq '\''uninstall'\'' -and (Get-Service -Name '\''" + $windows_service + "'\'' -ErrorAction SilentlyContinue) -and (Test-Path \"$dir\\" + $windows_helper + "\")) {",
        "    $proc = Start-Process \"$dir\\" + $windows_helper + "\" -ArgumentList '\''uninstall-service'\'' -Wait -PassThru -WindowStyle Hidden",
        "    if ($proc.ExitCode -ne 0) {",
        "        warn \"Failed to remove '\''" + $windows_service + "'\'' service automatically. Run as Administrator: sc.exe stop " + $windows_service + "; sc.exe delete " + $windows_service + "\"",
        "    }",
        "}"
      ]
     else [] end)
  ) as $pre_uninstall |
  {
    version: $version,
    description: $desc,
    homepage: $homepage,
    license: $license,
    architecture: {
      "64bit": {
        url: ("https://github.com/" + $repo + "/releases/download/v" + $version + "/" + $asset_prefix + "-" + $version + "-windows-amd64.zip"),
        hash: $amd64_sha
      },
      "arm64": {
        url: ("https://github.com/" + $repo + "/releases/download/v" + $version + "/" + $asset_prefix + "-" + $version + "-windows-arm64.zip"),
        hash: $arm64_sha
      }
    },
    pre_uninstall: $pre_uninstall,
    shortcuts: [
      [
        $windows_bin,
        $name
      ]
    ],
    checkver: (if $homepage == ("https://github.com/" + $repo) then "github" else { github: ("https://github.com/" + $repo) } end),
    autoupdate: {
      architecture: {
        "64bit": {
          url: ("https://github.com/" + $repo + "/releases/download/v$version/" + $asset_prefix + "-$version-windows-amd64.zip")
        },
        "arm64": {
          url: ("https://github.com/" + $repo + "/releases/download/v$version/" + $asset_prefix + "-$version-windows-arm64.zip")
        }
      },
      hash: {
        url: "$baseurl/SHA256SUMS.txt"
      }
    }
  }
  ' > "$out_dir/bucket/${app_token}.json"

if [ -n "$winget_id" ] && [[ "$windows_amd64_setup_sha" =~ ^[0-9a-f]{64}$ ]] && [[ "$windows_arm64_setup_sha" =~ ^[0-9a-f]{64}$ ]]; then
  publisher="${winget_id%%.*}"
  pkg_name="${winget_id#*.}"
  first_char="$(printf '%s' "$publisher" | cut -c1 | tr '[:upper:]' '[:lower:]')"
  winget_dir="$out_dir/winget/manifests/${first_char}/${publisher}/${pkg_name}/${version}"
  mkdir -p "$winget_dir"
  amd64_upper="$(printf '%s' "$windows_amd64_setup_sha" | tr '[:lower:]' '[:upper:]')"
  arm64_upper="$(printf '%s' "$windows_arm64_setup_sha" | tr '[:lower:]' '[:upper:]')"

  cat > "$winget_dir/${winget_id}.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.version.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
EOF

  {
    cat <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
InstallerType: nullsoft
Scope: machine
UpgradeBehavior: install
ProductCode: ${winget_product_code}
ElevationRequirement: elevatesSelf
EOF
    if [ -n "$release_date" ]; then
      printf 'ReleaseDate: %s\n' "$release_date"
    fi
    if [ -n "$winget_install_location" ]; then
      printf "InstallationMetadata:\n  DefaultInstallLocation: '%s'\n" "$winget_install_location"
    fi
    cat <<EOF
Installers:
- Architecture: x64
  InstallerUrl: https://github.com/${repo}/releases/download/v${version}/${asset_prefix}-${version}-windows-amd64-setup.exe
  InstallerSha256: ${amd64_upper}
- Architecture: arm64
  InstallerUrl: https://github.com/${repo}/releases/download/v${version}/${asset_prefix}-${version}-windows-arm64-setup.exe
  InstallerSha256: ${arm64_upper}
ManifestType: installer
ManifestVersion: 1.12.0
EOF
  } > "$winget_dir/${winget_id}.installer.yaml"

  en_tags="$(jq -r '(.tags // [])[] | "- " + .' <<<"$app_json")"
  {
    cat <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
PackageLocale: en-US
Publisher: ${publisher}
PublisherUrl: https://github.com/${publisher}
PublisherSupportUrl: https://github.com/${repo}/issues
PackageName: ${name}
PackageUrl: ${homepage}
License: ${license}
LicenseUrl: https://github.com/${repo}/blob/HEAD/LICENSE
ShortDescription: ${desc}
EOF
    if [ -n "$en_tags" ]; then
      printf 'Tags:\n%s\n' "$en_tags"
    fi
    cat <<EOF
ReleaseNotesUrl: https://github.com/${repo}/releases/tag/v${version}
ManifestType: defaultLocale
ManifestVersion: 1.12.0
EOF
  } > "$winget_dir/${winget_id}.locale.en-US.yaml"

  if [ -n "$desc_zh" ]; then
    zh_tags="$(jq -r '(.tags_zh // [])[] | "- " + .' <<<"$app_json")"
    {
      cat <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.locale.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
PackageLocale: zh-CN
PackageName: ${name}
ShortDescription: ${desc_zh}
EOF
      if [ -n "$zh_tags" ]; then
        printf 'Tags:\n%s\n' "$zh_tags"
      fi
      cat <<EOF
ManifestType: locale
ManifestVersion: 1.12.0
EOF
    } > "$winget_dir/${winget_id}.locale.zh-CN.yaml"
  fi
fi
