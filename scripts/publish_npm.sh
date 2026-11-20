#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_token="${1:-}"

apps_file="${NPM_APPS_FILE:-$repo_root/apps.json}"
manifests_root="${NPM_MANIFESTS_ROOT:-$repo_root}"
registry_url="${NPM_REGISTRY_URL:-https://registry.npmjs.org}"
registry_url="${registry_url%/}"
release_base="${NPM_RELEASE_BASE_URL:-https://github.com}"
release_base="${release_base%/}"
dry_run="${NPM_DRY_RUN:-false}"
retry_sleep="${NPM_RETRY_SLEEP_SEC:-1}"
output_dir="${NPM_OUTPUT_DIR:-}"

if [ -n "$target_token" ]; then
  if ! jq -e --arg t "$target_token" 'any(.[]; .token == $t)' "$apps_file" >/dev/null; then
    echo "Unknown app token in apps.json: $target_token" >&2
    exit 1
  fi
fi

npm_token="${NPM_TOKEN:-}"
if [ "$dry_run" != "true" ] && [ -z "$npm_token" ]; then
  echo "Skipping npm publish: NPM_TOKEN is not configured."
  exit 0
fi

if [ -n "$npm_token" ] && [[ "$npm_token" =~ [[:cntrl:]\"\\] ]]; then
  echo "Invalid characters in NPM_TOKEN" >&2
  exit 1
fi

for cmd in curl jq node npm tar unzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

npmrc_file="$tmp_dir/.npmrc"
resp_file="$tmp_dir/registry-resp.json"
registry_host_path="${registry_url#http://}"
registry_host_path="${registry_host_path#https://}"

umask 077
{
  printf 'registry=%s/\n' "$registry_url"
  if [ -n "$npm_token" ]; then
    printf '//%s/:_authToken=%s\n' "$registry_host_path" "$npm_token"
  fi
} > "$npmrc_file"
umask 022

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1) }'
  else
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
  fi
}

encode_npm_pkg() {
  printf '%s' "${1//\//%2F}"
}

extract_formula_sha() {
  local formula_file="$1"
  local suffix="$2"
  awk -v sfx="$suffix" '
    index($0, sfx "\"") > 0 { found=1; next }
    found && /sha256[[:space:]]+"/ {
      sub(/.*sha256[[:space:]]+"/, "")
      sub(/".*/, "")
      print tolower($0)
      exit
    }
  ' "$formula_file"
}

npm_version_exists() {
  local pkg="$1"
  local ver="$2"
  local encoded
  encoded="$(encode_npm_pkg "$pkg")"
  local url="${registry_url}/${encoded}"

  local attempt=1
  local max_attempts=3
  local status="000"
  while true; do
    : > "$resp_file"
    status="000"
    if status="$(curl -sS --connect-timeout 15 --max-time 60 -H "Accept: application/vnd.npm.install-v1+json" -o "$resp_file" -w '%{http_code}' "$url")"; then
      if [ "$status" = "404" ]; then
        return 1
      fi
      if [ "$status" = "200" ]; then
        jq -e --arg v "$ver" '(.versions // {}) | has($v)' "$resp_file" >/dev/null 2>&1
        return $?
      fi
      if [[ "$status" != "429" && "$status" != "502" && "$status" != "503" && "$status" != "504" ]]; then
        local msg=""
        if [ -s "$resp_file" ]; then
          msg="$(jq -r '.error // .message // empty' "$resp_file" 2>/dev/null || true)"
        fi
        echo "npm registry query failed for ${pkg} (HTTP ${status}): ${msg}" >&2
        exit 1
      fi
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "npm registry query timed out or failed for ${pkg} (HTTP ${status})" >&2
      exit 1
    fi
    sleep "$retry_sleep"
    attempt=$((attempt + 1))
  done
}

download_verified_archive() {
  local url="$1"
  local expected_prefix="$2"
  local expected_sha="$3"
  local dest="$4"

  if [[ "$url" != "${expected_prefix}"* ]]; then
    echo "Unexpected archive URL: $url (expected prefix $expected_prefix)" >&2
    exit 1
  fi

  local attempt=1
  local max_attempts=3
  local status="000"
  while true; do
    rm -f "$dest"
    status="000"
    if status="$(curl -sS -L --connect-timeout 15 --max-time 120 -o "$dest" -w '%{http_code}' "$url")"; then
      if [ "$status" = "200" ] && [ -s "$dest" ]; then
        break
      fi
      if [[ "$status" != "429" && "$status" != "502" && "$status" != "503" && "$status" != "504" ]]; then
        echo "Failed to download ${url} (HTTP ${status})" >&2
        exit 1
      fi
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Download failed after ${max_attempts} attempts: ${url} (HTTP ${status})" >&2
      exit 1
    fi
    sleep "$retry_sleep"
    attempt=$((attempt + 1))
  done

  local actual_sha
  actual_sha="$(sha256_file "$dest")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "SHA-256 mismatch for $(basename "$dest"): expected ${expected_sha}, got ${actual_sha}" >&2
    exit 1
  fi
}

extract_archive() {
  local archive="$1"
  local ext="$2"
  local dest_dir="$3"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  if [ "$ext" = "tar.gz" ]; then
    tar -xzf "$archive" -C "$dest_dir"
  else
    unzip -q -o "$archive" -d "$dest_dir"
  fi
}

publish_package_dir() {
  local pkg_name="$1"
  local pkg_ver="$2"
  local pkg_dir="$3"

  if [ "$dry_run" = "true" ]; then
    local pack_dir="$tmp_dir/packs"
    mkdir -p "$pack_dir"
    NPM_CONFIG_USERCONFIG="$npmrc_file" npm pack "$pkg_dir" --pack-destination "$pack_dir" --loglevel=warn >/dev/null
    echo "[dry-run] Packed ${pkg_name}@${pkg_ver}"
    return 0
  fi

  local attempt=1
  local max_attempts=3
  while true; do
    if NPM_CONFIG_USERCONFIG="$npmrc_file" npm publish "$pkg_dir" \
      --access public \
      --ignore-scripts \
      --loglevel=warn \
      --registry "${registry_url}/" >/dev/null; then
      echo "Published ${pkg_name}@${pkg_ver}"
      return 0
    fi

    if npm_version_exists "$pkg_name" "$pkg_ver"; then
      echo "Published ${pkg_name}@${pkg_ver} (confirmed after retry check)"
      return 0
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Failed to publish ${pkg_name}@${pkg_ver} after ${max_attempts} attempts" >&2
      exit 1
    fi
    sleep "$retry_sleep"
    attempt=$((attempt + 1))
  done
}

rewrite_readme_links() {
  local src_readme="$1"
  local dest_readme="$2"
  local repo="$3"
  local version="$4"
  node - "$src_readme" "$dest_readme" "$repo" "$version" <<'NODE'
const fs = require('node:fs');
const [src, dest, repo, version] = process.argv.slice(2);
const rawBase = `https://raw.githubusercontent.com/${repo}/v${version}`;
const blobBase = `https://github.com/${repo}/blob/v${version}`;
let md = fs.readFileSync(src, 'utf8');
md = md.replace(/(src=["'])(?:\.\/)?(assets\/[^"']+)(["'])/g, (_, p1, rel, p3) => `${p1}${rawBase}/${rel}${p3}`);
md = md.replace(/(\]\()\.\/([^)#\s]+(?:#[^)\s]+)?)(\))/g, (_, p1, rel, p3) => {
  const base = /\.(svg|png|jpe?g|gif|webp)$/i.test(rel.split('#')[0]) ? rawBase : blobBase;
  return `${p1}${base}/${rel}${p3}`;
});
fs.writeFileSync(dest, md, 'utf8');
NODE
}

render_launcher_js() {
  local out_file="$1"
  local main_pkg="$2"
  local cli_bin="$3"
  local windows_bin="$4"

  cat > "$out_file" <<EOF
#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');

const PLATFORMS = {
  'darwin-arm64': { pkg: '${main_pkg}-darwin-arm64', bin: '${cli_bin}' },
  'darwin-x64':   { pkg: '${main_pkg}-darwin-x64',   bin: '${cli_bin}' },
  'linux-arm64':  { pkg: '${main_pkg}-linux-arm64',  bin: '${cli_bin}' },
  'linux-x64':    { pkg: '${main_pkg}-linux-x64',    bin: '${cli_bin}' },
  'win32-x64':    { pkg: '${main_pkg}-win32-x64',    bin: '${windows_bin}' },
  'win32-arm64':  { pkg: '${main_pkg}-win32-arm64',  bin: '${windows_bin}' },
};

const key = \`\${process.platform}-\${process.arch}\`;
const target = PLATFORMS[key];
if (!target) {
  process.stderr.write(
    \`Error: ${main_pkg} does not provide a prebuilt binary for \${process.platform}/\${process.arch}.\n\` +
    \`Supported targets: \${Object.keys(PLATFORMS).join(', ')}.\n\`
  );
  process.exit(1);
}

let binPath;
try {
  const pkgJsonPath = require.resolve(\`\${target.pkg}/package.json\`);
  binPath = path.join(path.dirname(pkgJsonPath), 'bin', target.bin);
} catch {
  process.stderr.write(
    \`Error: platform binary package "\${target.pkg}" is not installed.\n\` +
    'Make sure optional dependencies are enabled (do not pass --no-optional / --omit=optional) and reinstall ${main_pkg}.\n'
  );
  process.exit(1);
}

process.on('SIGINT', () => {});

const result = spawnSync(binPath, process.argv.slice(2), {
  stdio: 'inherit',
  windowsHide: false,
});

if (result.error) {
  process.stderr.write(\`Error: failed to execute \${binPath}: \${result.error.message}\n\`);
  process.exit(1);
}

if (result.signal) {
  process.removeAllListeners(result.signal);
  process.kill(process.pid, result.signal);
  process.exit(1);
}

process.exit(result.status ?? 1);
EOF
  chmod 0755 "$out_file"
}

while IFS= read -r -u 3 app_json; do
  token="$(jq -r '.token' <<<"$app_json")"
  if [ -n "$target_token" ] && [ "$token" != "$target_token" ]; then
    continue
  fi

  npm_pkg="$(jq -r '.npm.package // empty' <<<"$app_json")"
  if [ -z "$npm_pkg" ]; then
    continue
  fi
  if [[ ! "$npm_pkg" =~ ^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "Invalid npm package name for $token: $npm_pkg" >&2
    exit 1
  fi

  app_type="$(jq -r '.type // "cask"' <<<"$app_json")"
  if [ "$app_type" != "formula" ]; then
    echo "npm publishing currently supports formula CLI apps only: $token (type=$app_type)" >&2
    exit 1
  fi

  formula_file="$manifests_root/Formula/${token}.rb"
  scoop_file="$manifests_root/bucket/${token}.json"
  if [ ! -s "$formula_file" ] || [ ! -s "$scoop_file" ]; then
    echo "Missing Formula or Scoop manifest for npm app $token" >&2
    exit 1
  fi

  version="$(jq -r '.version // empty' "$scoop_file")"
  formula_ver="$(sed -En 's/^[[:space:]]*version[[:space:]]+"([^"]+)"$/\1/p' "$formula_file" | head -n 1)"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$version" != "$formula_ver" ]; then
    echo "Version mismatch between Formula (${formula_ver}) and Scoop (${version}) for $token" >&2
    exit 1
  fi

  if [ "$dry_run" != "true" ] && npm_version_exists "$npm_pkg" "$version"; then
    echo "npm ${npm_pkg}@${version} is already published."
    continue
  fi

  repo="$(jq -r '.repo' <<<"$app_json")"
  desc="$(jq -r '.desc' <<<"$app_json")"
  homepage="$(jq -r '.homepage' <<<"$app_json")"
  license="$(jq -r '.license' <<<"$app_json")"
  asset_prefix="$(jq -r '.asset_prefix' <<<"$app_json")"
  npm_bin="$(jq -r '.npm.bin // .bin // .token' <<<"$app_json")"
  cli_bin="$(jq -r '.bin // .token' <<<"$app_json")"
  windows_bin="$(jq -r '.windows_bin' <<<"$app_json")"
  keywords_json="$(jq -c '.tags // []' <<<"$app_json")"

  for ident in "$npm_bin" "$cli_bin" "$windows_bin"; do
    if [[ ! "$ident" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      echo "Invalid binary name for $token: $ident" >&2
      exit 1
    fi
  done

  darwin_arm64_sha="$(extract_formula_sha "$formula_file" "darwin-arm64.tar.gz")"
  darwin_amd64_sha="$(extract_formula_sha "$formula_file" "darwin-amd64.tar.gz")"
  linux_arm64_sha="$(extract_formula_sha "$formula_file" "linux-arm64.tar.gz")"
  linux_amd64_sha="$(extract_formula_sha "$formula_file" "linux-amd64.tar.gz")"
  windows_amd64_sha="$(jq -r '.architecture["64bit"].hash // empty' "$scoop_file" | tr '[:upper:]' '[:lower:]')"
  windows_arm64_sha="$(jq -r '.architecture["arm64"].hash // empty' "$scoop_file" | tr '[:upper:]' '[:lower:]')"

  for sum in "$darwin_arm64_sha" "$darwin_amd64_sha" "$linux_arm64_sha" "$linux_amd64_sha" "$windows_amd64_sha" "$windows_arm64_sha"; do
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
      echo "Missing or invalid trusted SHA-256 in manifests for $token" >&2
      exit 1
    fi
  done

  app_work="$tmp_dir/app-${token}"
  mkdir -p "$app_work/archives" "$app_work/extract" "$app_work/packages"
  expected_dl_prefix="${release_base}/${repo}/releases/download/v${version}/"

  # 6-platform matrix: npm_os|npm_cpu|go_os|go_arch|ext|bin_name|expected_sha
  targets=(
    "darwin|arm64|darwin|arm64|tar.gz|${cli_bin}|${darwin_arm64_sha}"
    "darwin|x64|darwin|amd64|tar.gz|${cli_bin}|${darwin_amd64_sha}"
    "linux|arm64|linux|arm64|tar.gz|${cli_bin}|${linux_arm64_sha}"
    "linux|x64|linux|amd64|tar.gz|${cli_bin}|${linux_amd64_sha}"
    "win32|x64|windows|amd64|zip|${windows_bin}|${windows_amd64_sha}"
    "win32|arm64|windows|arm64|zip|${windows_bin}|${windows_arm64_sha}"
  )

  sample_extract_dir=""
  optional_deps_json="{}"

  for spec in "${targets[@]}"; do
    IFS='|' read -r npm_os npm_cpu go_os go_arch ext bin_name expected_sha <<<"$spec"
    sub_pkg="${npm_pkg}-${npm_os}-${npm_cpu}"
    optional_deps_json="$(jq -c --arg k "$sub_pkg" --arg v "$version" '. + {($k): $v}' <<<"$optional_deps_json")"

    if [ "$dry_run" != "true" ] && npm_version_exists "$sub_pkg" "$version"; then
      echo "npm ${sub_pkg}@${version} is already published."
      continue
    fi

    asset_name="${asset_prefix}-${version}-${go_os}-${go_arch}.${ext}"
    archive_url="${expected_dl_prefix}${asset_name}"
    archive_path="$app_work/archives/${asset_name}"
    extract_dir="$app_work/extract/${npm_os}-${npm_cpu}"

    download_verified_archive "$archive_url" "$expected_dl_prefix" "$expected_sha" "$archive_path"
    extract_archive "$archive_path" "$ext" "$extract_dir"
    [ -z "$sample_extract_dir" ] && sample_extract_dir="$extract_dir"

    src_bin="$extract_dir/${bin_name}"
    if [ ! -f "$src_bin" ] || [ ! -s "$src_bin" ] || [ -L "$src_bin" ]; then
      echo "Verified archive ${asset_name} is missing regular binary ${bin_name}" >&2
      exit 1
    fi

    sub_dir="$app_work/packages/${npm_os}-${npm_cpu}"
    mkdir -p "$sub_dir/bin"
    cp "$src_bin" "$sub_dir/bin/${bin_name}"
    chmod 0755 "$sub_dir/bin/${bin_name}"

    sub_files_json='["bin"]'
    if [ -f "$extract_dir/LICENSE" ] && [ ! -L "$extract_dir/LICENSE" ]; then
      cp "$extract_dir/LICENSE" "$sub_dir/LICENSE"
      sub_files_json='["bin", "LICENSE"]'
    fi

    jq --indent 2 -n \
      --arg name "$sub_pkg" \
      --arg version "$version" \
      --arg desc "${desc} (${npm_os}-${npm_cpu} binary)" \
      --arg homepage "$homepage" \
      --arg license "$license" \
      --arg repo "$repo" \
      --arg os "$npm_os" \
      --arg cpu "$npm_cpu" \
      --argjson files "$sub_files_json" \
      '{
        name: $name,
        version: $version,
        description: $desc,
        homepage: $homepage,
        license: $license,
        repository: { type: "git", url: ("git+https://github.com/" + $repo + ".git") },
        bugs: { url: ("https://github.com/" + $repo + "/issues") },
        os: [$os],
        cpu: [$cpu],
        files: $files,
        preferUnplugged: true,
        publishConfig: { access: "public" }
      }' > "$sub_dir/package.json"

    publish_package_dir "$sub_pkg" "$version" "$sub_dir"
  done

  # If all 6 subpackages were already published in an earlier interrupted run, fetch one verified archive for LICENSE/README.
  if [ -z "$sample_extract_dir" ]; then
    sample_asset="${asset_prefix}-${version}-linux-amd64.tar.gz"
    sample_archive="$app_work/archives/${sample_asset}"
    sample_extract_dir="$app_work/extract/sample"
    download_verified_archive "${expected_dl_prefix}${sample_asset}" "$expected_dl_prefix" "$linux_amd64_sha" "$sample_archive"
    extract_archive "$sample_archive" "tar.gz" "$sample_extract_dir"
  fi

  main_dir="$app_work/packages/main"
  mkdir -p "$main_dir/bin"
  render_launcher_js "$main_dir/bin/${npm_bin}.js" "$npm_pkg" "$cli_bin" "$windows_bin"

  main_files_json='["bin"]'
  if [ -f "$sample_extract_dir/LICENSE" ] && [ ! -L "$sample_extract_dir/LICENSE" ]; then
    cp "$sample_extract_dir/LICENSE" "$main_dir/LICENSE"
    main_files_json="$(jq -c '. + ["LICENSE"]' <<<"$main_files_json")"
  fi
  if [ -f "$sample_extract_dir/README.en.md" ] && [ ! -L "$sample_extract_dir/README.en.md" ]; then
    rewrite_readme_links "$sample_extract_dir/README.en.md" "$main_dir/README.md" "$repo" "$version"
    main_files_json="$(jq -c '. + ["README.md"]' <<<"$main_files_json")"
  elif [ -f "$sample_extract_dir/README.md" ] && [ ! -L "$sample_extract_dir/README.md" ]; then
    rewrite_readme_links "$sample_extract_dir/README.md" "$main_dir/README.md" "$repo" "$version"
    main_files_json="$(jq -c '. + ["README.md"]' <<<"$main_files_json")"
  fi

  jq --indent 2 -n \
    --arg name "$npm_pkg" \
    --arg version "$version" \
    --arg desc "$desc" \
    --arg homepage "$homepage" \
    --arg license "$license" \
    --arg repo "$repo" \
    --arg bin_name "$npm_bin" \
    --argjson keywords "$keywords_json" \
    --argjson files "$main_files_json" \
    --argjson opt_deps "$optional_deps_json" \
    '{
      name: $name,
      version: $version,
      description: $desc,
      homepage: $homepage,
      license: $license,
      repository: { type: "git", url: ("git+https://github.com/" + $repo + ".git") },
      bugs: { url: ("https://github.com/" + $repo + "/issues") },
      keywords: $keywords,
      bin: { ($bin_name): ("bin/" + $bin_name + ".js") },
      files: $files,
      engines: { node: ">=18" },
      optionalDependencies: $opt_deps,
      publishConfig: { access: "public" }
    }' > "$main_dir/package.json"

  if [ -n "$output_dir" ]; then
    mkdir -p "$output_dir"
    cp -R "$app_work/packages/." "$output_dir/"
  fi

  publish_package_dir "$npm_pkg" "$version" "$main_dir"
done 3< <(jq -c '.[]' "$apps_file")
