#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_file="${SYNC_APPS_FILE:-$repo_root/apps.json}"
out_dir="${SYNC_OUTPUT_DIR:-$repo_root}"
api_base="${SYNC_GITHUB_API_URL:-https://api.github.com}"
api_base="${api_base%/}"
release_base="${SYNC_RELEASE_BASE_URL:-https://github.com}"
release_base="${release_base%/}"
wait_attempts="${SYNC_WAIT_ATTEMPTS:-12}"
wait_interval="${SYNC_WAIT_INTERVAL_SEC:-5}"
retry_sleep="${SYNC_RETRY_SLEEP_SEC:-2}"

target_token="${1:-}"
expected_version="${2:-}"
expected_version="${expected_version#v}"

if [[ ! "$wait_attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNC_WAIT_ATTEMPTS must be a positive integer: $wait_attempts" >&2
  exit 1
fi

if [ -n "$expected_version" ]; then
  if [ -z "$target_token" ]; then
    echo "expected_version requires an explicit app token" >&2
    exit 1
  fi
  if [[ ! "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "expected_version must match MAJOR.MINOR.PATCH: $expected_version" >&2
    exit 1
  fi
fi

if [ -n "$target_token" ]; then
  if ! jq -e --arg t "$target_token" 'any(.[]; .token == $t)' "$apps_file" >/dev/null; then
    echo "Unknown app token in apps.json: $target_token" >&2
    exit 1
  fi
fi

auth_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$auth_token" ] && [[ "$auth_token" =~ [[:cntrl:]\"\\] ]]; then
  echo "Invalid characters in GitHub API token" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl_cfg="$tmp_dir/curl.cfg"
umask 077
{
  printf 'header = "Accept: application/vnd.github+json"\n'
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
  if [ -n "$auth_token" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$auth_token"
  fi
} > "$curl_cfg"
umask 022

semver_cmp() {
  local a1 a2 a3 b1 b2 b3
  IFS='.' read -r a1 a2 a3 <<<"$1"
  IFS='.' read -r b1 b2 b3 <<<"$2"
  local pair x y
  for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3"; do
    x="${pair%%:*}"
    y="${pair##*:}"
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then
      printf '%s' "-1"
      return 0
    elif [ "$((10#$x))" -gt "$((10#$y))" ]; then
      printf '%s' "1"
      return 0
    fi
  done
  printf '%s' "0"
}

read_current_version() {
  local token="$1"
  local app_type="$2"
  local ver=""
  if [ -f "$out_dir/bucket/${token}.json" ]; then
    ver="$(jq -r '.version // empty' "$out_dir/bucket/${token}.json" 2>/dev/null || true)"
  fi
  if [ -z "$ver" ]; then
    local rb_file="$out_dir/Casks/${token}.rb"
    if [ "$app_type" = "formula" ]; then
      rb_file="$out_dir/Formula/${token}.rb"
    fi
    if [ -f "$rb_file" ]; then
      ver="$(sed -En 's/^[[:space:]]*version[[:space:]]+"([^"]+)"$/\1/p' "$rb_file" | head -n 1)"
    fi
  fi
  if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ver"
  fi
}

FETCH_STATUS="000"

fetch_url() {
  local url="$1"
  local dest="$2"
  local use_api_cfg="${3:-false}"
  local quiet_404="${4:-false}"
  local attempt=1
  local max_attempts=3

  while true; do
    rm -f "$dest"
    FETCH_STATUS="000"
    local curl_args=(-sS -L --connect-timeout 15 --max-time 60 -o "$dest" -w '%{http_code}')
    if [ "$use_api_cfg" = "true" ]; then
      curl_args+=(-K "$curl_cfg")
    fi
    curl_args+=("$url")

    if FETCH_STATUS="$(curl "${curl_args[@]}")"; then
      if [ "$FETCH_STATUS" = "200" ] && [ -s "$dest" ]; then
        return 0
      fi
      if [[ "$FETCH_STATUS" != "429" && "$FETCH_STATUS" != "500" && "$FETCH_STATUS" != "502" && "$FETCH_STATUS" != "503" && "$FETCH_STATUS" != "504" ]]; then
        if [ "$quiet_404" != "true" ] || [ "$FETCH_STATUS" != "404" ]; then
          echo "HTTP ${FETCH_STATUS} fetching ${url}" >&2
        fi
        return 1
      fi
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Failed fetching ${url} after ${max_attempts} attempts (HTTP ${FETCH_STATUS})" >&2
      return 1
    fi
    sleep "$retry_sleep"
    attempt=$((attempt + 1))
  done
}

while IFS= read -r -u 3 app_json; do
  token="$(jq -r '.token' <<<"$app_json")"
  if [ -n "$target_token" ] && [ "$token" != "$target_token" ]; then
    continue
  fi

  repo="$(jq -r '.repo' <<<"$app_json")"
  app_type="$(jq -r '.type // "cask"' <<<"$app_json")"
  api_url="${api_base}/repos/${repo}/releases/latest"
  release_file="$tmp_dir/${token}-release.json"

  max_polls=1
  if [ -n "$expected_version" ]; then
    max_polls="$wait_attempts"
  fi

  poll=1
  tag_name=""
  is_draft="false"
  is_prerelease="false"
  release_date=""
  version=""

  while true; do
    quiet_404="false"
    if [ -n "$expected_version" ] && [ "$poll" -lt "$max_polls" ]; then
      quiet_404="true"
    fi

    if ! fetch_url "$api_url" "$release_file" true "$quiet_404"; then
      if [ -n "$expected_version" ] && [ "$poll" -lt "$max_polls" ] &&
        [[ "$FETCH_STATUS" == "404" || "$FETCH_STATUS" == "429" || "$FETCH_STATUS" == "000" || "$FETCH_STATUS" == 5* ]]; then
        echo "Waiting for ${repo} latest stable release >= v${expected_version} (attempt ${poll}/${max_polls}, HTTP ${FETCH_STATUS})..."
        sleep "$wait_interval"
        poll=$((poll + 1))
        continue
      fi
      exit 1
    fi

    tag_name="$(jq -r '.tag_name // empty' "$release_file")"
    is_draft="$(jq -r '.draft // false' "$release_file")"
    is_prerelease="$(jq -r '.prerelease // false' "$release_file")"
    release_date="$(jq -r '(.published_at // "") | if length >= 10 then .[0:10] else "" end' "$release_file")"
    version="${tag_name#v}"

    if [ -z "$expected_version" ]; then
      break
    fi

    has_checksums="$(jq -r '((.assets // []) | any((.name == "SHA256SUMS.txt" and (.state == null or .state == "uploaded")) or ((.digest // "") | startswith("sha256:"))))' "$release_file")"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
      [ "$is_draft" != "true" ] &&
      [ "$is_prerelease" != "true" ] &&
      [ "$has_checksums" = "true" ] &&
      [ "$(semver_cmp "$version" "$expected_version")" -ge 0 ]; then
      break
    fi

    if [ "$poll" -ge "$max_polls" ]; then
      echo "Timed out waiting for ${repo} latest stable release >= v${expected_version} (last seen: ${tag_name:-<none>}, draft=${is_draft}, prerelease=${is_prerelease}, checksums=${has_checksums})" >&2
      exit 1
    fi
    echo "Waiting for ${repo} latest stable release >= v${expected_version} (attempt ${poll}/${max_polls}, seen: ${tag_name:-<none>})..."
    sleep "$wait_interval"
    poll=$((poll + 1))
  done

  if [ -z "$version" ] || [ "$is_draft" = "true" ] || [ "$is_prerelease" = "true" ]; then
    echo "Skipping $token: no stable latest release ($tag_name)"
    continue
  fi

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Latest stable release tag for ${token} is not vMAJOR.MINOR.PATCH: ${tag_name}" >&2
    exit 1
  fi

  current_version="$(read_current_version "$token" "$app_type")"
  if [ -n "$current_version" ] && [ "$(semver_cmp "$version" "$current_version")" -lt 0 ]; then
    echo "Refusing to downgrade ${token} from v${current_version} to v${version}" >&2
    exit 1
  fi

  sums_file="$tmp_dir/${token}-SHA256SUMS.txt"
  sums_url="$(jq -r '(.assets // [])[] | select(.name == "SHA256SUMS.txt" and (.state == null or .state == "uploaded")) | .browser_download_url' "$release_file" | head -n 1)"
  if [ -n "$sums_url" ]; then
    expected_prefix="${release_base}/${repo}/releases/download/${tag_name}/"
    if [[ "$sums_url" != "${expected_prefix}"* ]]; then
      echo "Unexpected SHA256SUMS.txt download URL for $token: $sums_url (expected prefix $expected_prefix)" >&2
      exit 1
    fi
    fetch_url "$sums_url" "$sums_file" false
  else
    jq -r '(.assets // [])[] | select(.digest != null and (.digest | startswith("sha256:"))) | "\(.digest | sub("^sha256:"; ""))  \(.name)"' "$release_file" > "$sums_file"
  fi

  bash "$repo_root/scripts/sync_app.sh" "$token" "$version" "$sums_file" "$out_dir" "$apps_file" "$release_date"
  echo "Synced $token -> v$version"
done 3< <(jq -c '.[]' "$apps_file")
