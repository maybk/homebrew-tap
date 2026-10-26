#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
  echo "Usage: $0 <app-token> <version> <sha256sums-file> [output-dir] [apps-json]" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_token="$1"
version="${2#v}"
sums_file="$3"
out_dir="${4:-$repo_root}"
apps_file="${5:-$repo_root/apps.json}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must match MAJOR.MINOR.PATCH: $version" >&2
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
desc_zh="$(jq -r '.desc_zh' <<<"$app_json")"
homepage="$(jq -r '.homepage' <<<"$app_json")"
license="$(jq -r '.license' <<<"$app_json")"
macos_min="$(jq -r '.macos_min' <<<"$app_json")"
app_bundle="$(jq -r '.app_bundle' <<<"$app_json")"
bundle_id="$(jq -r '.bundle_id' <<<"$app_json")"
dot_dir="$(jq -r '.dot_dir' <<<"$app_json")"
windows_bin="$(jq -r '.windows_bin' <<<"$app_json")"
winget_id="$(jq -r '.winget_id' <<<"$app_json")"
winget_product_code="$(jq -r '.winget_product_code' <<<"$app_json")"
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

linux_bins_stanza="$(
  jq -r '.linux_binaries[] | "    binary \"" + . + "\""' <<<"$app_json"
)"

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

    app "${app_bundle}"

    postflight_steps do
      run "/usr/bin/xattr",
          args:           ["-rd", "com.apple.quarantine", "{{appdir}}/${app_bundle}"],
          writable_paths: ["${app_bundle}"],
          writable_base:  :appdir
    end

    zap trash: [
      "${dot_dir}",
      "~/Library/Application Support/${bundle_id}",
      "~/Library/Caches/${bundle_id}",
      "~/Library/Preferences/${bundle_id}.plist",
      "~/Library/Saved Application State/${bundle_id}.savedState",
    ]
  end
  on_linux do
    url "https://github.com/${repo}/releases/download/v#{version}/${asset_prefix}-#{version}-linux-#{arch}.tar.gz"

${linux_bins_stanza}

    zap trash: "${dot_dir}"
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

cat > "$out_dir/bucket/${app_token}.json" <<EOF
{
  "version": "${version}",
  "description": "${desc}",
  "homepage": "${homepage}",
  "license": "${license}",
  "architecture": {
    "64bit": {
      "url": "https://github.com/${repo}/releases/download/v${version}/${asset_prefix}-${version}-windows-amd64.zip",
      "hash": "${windows_amd64_sha}"
    },
    "arm64": {
      "url": "https://github.com/${repo}/releases/download/v${version}/${asset_prefix}-${version}-windows-arm64.zip",
      "hash": "${windows_arm64_sha}"
    }
  },
  "bin": "${windows_bin}",
  "shortcuts": [
    [
      "${windows_bin}",
      "${name}"
    ]
  ],
  "checkver": {
    "github": "${homepage}"
  },
  "autoupdate": {
    "architecture": {
      "64bit": {
        "url": "https://github.com/${repo}/releases/download/v\$version/${asset_prefix}-\$version-windows-amd64.zip"
      },
      "arm64": {
        "url": "https://github.com/${repo}/releases/download/v\$version/${asset_prefix}-\$version-windows-arm64.zip"
      }
    },
    "hash": {
      "url": "\$baseurl/SHA256SUMS.txt"
    }
  }
}
EOF

if [[ "$windows_amd64_setup_sha" =~ ^[0-9a-f]{64}$ ]] && [[ "$windows_arm64_setup_sha" =~ ^[0-9a-f]{64}$ ]]; then
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

  cat > "$winget_dir/${winget_id}.installer.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
InstallerType: nullsoft
Scope: machine
UpgradeBehavior: install
ProductCode: ${winget_product_code}
ElevationRequirement: elevatesSelf
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

  cat > "$winget_dir/${winget_id}.locale.en-US.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
PackageLocale: en-US
Publisher: ${publisher}
PublisherUrl: https://github.com/${publisher}
PublisherSupportUrl: ${homepage}/issues
PackageName: ${name}
PackageUrl: ${homepage}
License: ${license}
LicenseUrl: ${homepage}/blob/HEAD/LICENSE
ShortDescription: ${desc}
ReleaseNotesUrl: ${homepage}/releases/tag/v${version}
ManifestType: defaultLocale
ManifestVersion: 1.12.0
EOF

  cat > "$winget_dir/${winget_id}.locale.zh-CN.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.locale.1.12.0.schema.json

PackageIdentifier: ${winget_id}
PackageVersion: ${version}
PackageLocale: zh-CN
ShortDescription: ${desc_zh}
ManifestType: locale
ManifestVersion: 1.12.0
EOF
fi
