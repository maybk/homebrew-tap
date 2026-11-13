#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_token="${1:-}"
force_retry="${2:-false}"

apps_file="${WINGET_APPS_FILE:-$repo_root/apps.json}"
manifests_root="${WINGET_MANIFESTS_ROOT:-$repo_root}"
api_base="${WINGET_GITHUB_API_URL:-https://api.github.com}"
api_base="${api_base%/}"
upstream_repo="${WINGET_UPSTREAM_REPO:-microsoft/winget-pkgs}"
fork_repo_name="${WINGET_FORK_REPO_NAME:-winget-pkgs}"
poll_interval="${WINGET_POLL_INTERVAL_SEC:-3}"

if [ -n "$target_token" ]; then
  if ! jq -e --arg t "$target_token" 'any(.[]; .token == $t)' "$apps_file" >/dev/null; then
    echo "Unknown app token in apps.json: $target_token" >&2
    exit 1
  fi
fi

auth_token="${WINGET_GITHUB_TOKEN:-}"
if [ -z "$auth_token" ]; then
  echo "Skipping WinGet PR submission: WINGET_GITHUB_TOKEN is not configured."
  exit 0
fi

if [[ "$auth_token" =~ [[:cntrl:]\"\\] ]]; then
  echo "Invalid characters in WINGET_GITHUB_TOKEN" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl_cfg="$tmp_dir/curl.cfg"
resp_file="$tmp_dir/resp.json"
umask 077
cat > "$curl_cfg" <<EOF
header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: 2022-11-28"
header = "Authorization: Bearer ${auth_token}"
EOF
umask 022

API_STATUS="000"

api_request() {
  local method="$1"
  local endpoint="$2"
  local body_file="${3:-}"
  local url
  if [[ "$endpoint" == http://* || "$endpoint" == https://* ]]; then
    url="$endpoint"
  else
    url="${api_base}${endpoint}"
  fi

  local attempt=1
  local max_attempts=3
  local backoff=1
  while true; do
    : > "$resp_file"
    local curl_args=(-sS -L -K "$curl_cfg" -X "$method" -o "$resp_file" -w '%{http_code}')
    if [ -n "$body_file" ]; then
      curl_args+=(-H "Content-Type: application/json" --data-binary "@$body_file")
    fi
    curl_args+=("$url")

    API_STATUS="000"
    if API_STATUS="$(curl "${curl_args[@]}")"; then
      if [[ "$API_STATUS" != "429" && "$API_STATUS" != "502" && "$API_STATUS" != "503" && "$API_STATUS" != "504" ]]; then
        return 0
      fi
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      return 0
    fi
    sleep "$backoff"
    backoff=$((backoff * 2))
    attempt=$((attempt + 1))
  done
}

api_expect_2xx() {
  local context="$1"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    local msg=""
    if [ -s "$resp_file" ]; then
      msg="$(jq -r '.message // empty' "$resp_file" 2>/dev/null || cat "$resp_file")"
    fi
    echo "GitHub API error during ${context} (HTTP ${API_STATUS}): ${msg}" >&2
    exit 1
  fi
}

api_request GET "/user"
api_expect_2xx "GET /user"
fork_owner="$(jq -r '.login // empty' "$resp_file")"
if [ -z "$fork_owner" ]; then
  echo "Unable to determine authenticated GitHub username from WINGET_GITHUB_TOKEN" >&2
  exit 1
fi
fork_repo="${fork_owner}/${fork_repo_name}"

UPSTREAM_DEFAULT_BRANCH=""
SYNCED_UPSTREAM_SHA=""
SYNCED_BASE_TREE_SHA=""

ensure_fork_synced() {
  if [ -n "$SYNCED_UPSTREAM_SHA" ] && [ -n "$SYNCED_BASE_TREE_SHA" ]; then
    return 0
  fi

  api_request GET "/repos/${upstream_repo}"
  api_expect_2xx "GET /repos/${upstream_repo}"
  UPSTREAM_DEFAULT_BRANCH="$(jq -r '.default_branch // "master"' "$resp_file")"

  api_request GET "/repos/${upstream_repo}/git/ref/heads/${UPSTREAM_DEFAULT_BRANCH}"
  api_expect_2xx "GET upstream ref ${UPSTREAM_DEFAULT_BRANCH}"
  local upstream_sha
  upstream_sha="$(jq -r '.object.sha // empty' "$resp_file")"
  if [[ ! "$upstream_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid upstream HEAD SHA for ${upstream_repo}:${UPSTREAM_DEFAULT_BRANCH}" >&2
    exit 1
  fi

  api_request GET "/repos/${fork_repo}"
  if [ "$API_STATUS" = "404" ]; then
    echo "Creating fork ${fork_repo} from ${upstream_repo}..."
    local fork_payload="$tmp_dir/fork_payload.json"
    jq -n '{default_branch_only: true}' > "$fork_payload"
    api_request POST "/repos/${upstream_repo}/forks" "$fork_payload"
    api_expect_2xx "POST /repos/${upstream_repo}/forks"

    local ready=0
    local i
    for ((i = 1; i <= 20; i++)); do
      api_request GET "/repos/${fork_repo}/git/ref/heads/${UPSTREAM_DEFAULT_BRANCH}"
      if [ "$API_STATUS" = "200" ]; then
        ready=1
        break
      fi
      sleep "$poll_interval"
    done
    if [ "$ready" -ne 1 ]; then
      echo "Timed out waiting for fork ${fork_repo}:${UPSTREAM_DEFAULT_BRANCH} to become ready" >&2
      exit 1
    fi
  else
    api_expect_2xx "GET /repos/${fork_repo}"
    api_request GET "/repos/${fork_repo}/git/ref/heads/${UPSTREAM_DEFAULT_BRANCH}"
    api_expect_2xx "GET fork ref ${UPSTREAM_DEFAULT_BRANCH}"
  fi

  local fork_sha
  fork_sha="$(jq -r '.object.sha // empty' "$resp_file")"
  if [ "$fork_sha" != "$upstream_sha" ]; then
    local merge_payload="$tmp_dir/merge_upstream.json"
    jq -n --arg branch "$UPSTREAM_DEFAULT_BRANCH" '{branch: $branch}' > "$merge_payload"
    api_request POST "/repos/${fork_repo}/merge-upstream" "$merge_payload"
    if [[ "$API_STATUS" != "200" && "$API_STATUS" != "409" && "$API_STATUS" != "422" ]]; then
      api_expect_2xx "POST /repos/${fork_repo}/merge-upstream"
    fi

    api_request GET "/repos/${fork_repo}/git/ref/heads/${UPSTREAM_DEFAULT_BRANCH}"
    api_expect_2xx "GET fork ref after merge-upstream"
    fork_sha="$(jq -r '.object.sha // empty' "$resp_file")"

    if [ "$fork_sha" != "$upstream_sha" ]; then
      local force_payload="$tmp_dir/force_ref.json"
      jq -n --arg sha "$upstream_sha" '{sha: $sha, force: true}' > "$force_payload"
      api_request PATCH "/repos/${fork_repo}/git/refs/heads/${UPSTREAM_DEFAULT_BRANCH}" "$force_payload"
      api_expect_2xx "PATCH fork ref ${UPSTREAM_DEFAULT_BRANCH}"
    fi
    echo "Synced ${fork_repo}:${UPSTREAM_DEFAULT_BRANCH} -> ${upstream_sha:0:10}"
  fi

  api_request GET "/repos/${fork_repo}/git/commits/${upstream_sha}"
  api_expect_2xx "GET commit ${upstream_sha}"
  SYNCED_BASE_TREE_SHA="$(jq -r '.tree.sha // empty' "$resp_file")"
  if [[ ! "$SYNCED_BASE_TREE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Invalid base tree SHA for ${upstream_sha}" >&2
    exit 1
  fi
  SYNCED_UPSTREAM_SHA="$upstream_sha"
}

regex_escape() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

while IFS= read -r -u 3 app_json; do
  token="$(jq -r '.token' <<<"$app_json")"
  if [ -n "$target_token" ] && [ "$token" != "$target_token" ]; then
    continue
  fi

  winget_id="$(jq -r '.winget_id // empty' <<<"$app_json")"
  if [ -z "$winget_id" ]; then
    continue
  fi

  repo="$(jq -r '.repo' <<<"$app_json")"
  publisher="${winget_id%%.*}"
  first_char="$(printf '%s' "$publisher" | cut -c1 | tr '[:upper:]' '[:lower:]')"
  pkg_subpath="${winget_id//.//}"
  pkg_manifest_root="$manifests_root/winget/manifests/${first_char}/${pkg_subpath}"

  version=""
  if [ -f "$manifests_root/bucket/${token}.json" ]; then
    version="$(jq -r '.version // empty' "$manifests_root/bucket/${token}.json")"
  fi
  if [ -z "$version" ] && [ -d "$pkg_manifest_root" ]; then
    version="$(find "$pkg_manifest_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -V | tail -n 1)"
  fi
  if [ -z "$version" ]; then
    continue
  fi

  local_ver_dir="$pkg_manifest_root/$version"
  if [ ! -d "$local_ver_dir" ]; then
    continue
  fi

  version_yaml="$local_ver_dir/${winget_id}.yaml"
  installer_yaml="$local_ver_dir/${winget_id}.installer.yaml"
  default_locale_yaml="$local_ver_dir/${winget_id}.locale.en-US.yaml"
  if [ ! -s "$version_yaml" ] || [ ! -s "$installer_yaml" ] || [ ! -s "$default_locale_yaml" ]; then
    echo "Incomplete WinGet manifest files in $local_ver_dir" >&2
    exit 1
  fi

  manifest_ver="$(awk -F': *' '$1 == "ManifestVersion" { sub(/\r$/, "", $2); print $2; exit }' "$version_yaml")"
  if [[ ! "$manifest_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid ManifestVersion in $version_yaml: $manifest_ver" >&2
    exit 1
  fi
  schema_short="${manifest_ver%.*}"

  id_re="$(regex_escape "$winget_id")"
  ver_re="$(regex_escape "$version")"
  base_branch="${winget_id}-${version}"
  retry_re="^${id_re}-${ver_re}-r([0-9]+)$"

  fork_pkg_branches=()
  api_request GET "/repos/${fork_repo}/git/matching-refs/heads/${winget_id}-"
  if [ "$API_STATUS" = "200" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] && fork_pkg_branches+=("$b")
    done < <(jq -r --arg re "^refs/heads/${id_re}-[0-9]+\\.[0-9]+\\.[0-9]+(-r[0-9]+)?$" '.[] | .ref | select(test($re)) | sub("^refs/heads/"; "")' "$resp_file")
  elif [ "$API_STATUS" != "404" ]; then
    api_expect_2xx "GET matching-refs for ${winget_id}"
  fi

  open_pkg_pr_url=""
  existing_open_url=""
  existing_merged_url=""
  closed_unmerged_num=""
  checked_base_branch=0
  max_retry=1

  if [ "${#fork_pkg_branches[@]}" -gt 0 ]; then
    for b in "${fork_pkg_branches[@]}"; do
      is_target_ver=0
      if [ "$b" = "$base_branch" ]; then
        is_target_ver=1
        checked_base_branch=1
      elif [[ "$b" =~ $retry_re ]]; then
        is_target_ver=1
        r_num="${BASH_REMATCH[1]}"
        if [ "$r_num" -gt "$max_retry" ]; then
          max_retry="$r_num"
        fi
      fi

      api_request GET "/repos/${upstream_repo}/pulls?state=all&head=${fork_owner}:${b}&per_page=10"
      api_expect_2xx "GET pulls for ${fork_owner}:${b}"
      b_open_url="$(jq -r '[.[] | select(.state == "open")][0].html_url // empty' "$resp_file")"
      b_merged_url="$(jq -r '[.[] | select(.merged_at != null)][0].html_url // empty' "$resp_file")"
      b_closed_num="$(jq -r '[.[] | select(.state == "closed" and .merged_at == null)][0].number // empty' "$resp_file")"

      if [ -n "$b_open_url" ] && [ -z "$open_pkg_pr_url" ]; then
        open_pkg_pr_url="$b_open_url"
      fi

      if [ "$is_target_ver" -eq 1 ]; then
        [ -n "$b_open_url" ] && [ -z "$existing_open_url" ] && existing_open_url="$b_open_url"
        [ -n "$b_merged_url" ] && [ -z "$existing_merged_url" ] && existing_merged_url="$b_merged_url"
        [ -n "$b_closed_num" ] && closed_unmerged_num="$b_closed_num"
      fi

      if [ -z "$b_open_url" ] && [ -n "$b_merged_url" ]; then
        ensure_fork_synced
        api_request DELETE "/repos/${fork_repo}/git/refs/heads/${b}"
        if [[ "$API_STATUS" == "204" || "$API_STATUS" == "422" || "$API_STATUS" == "404" ]]; then
          echo "Cleaned up merged branch ${fork_repo}:${b}"
        else
          api_expect_2xx "DELETE merged ref ${b}"
        fi
      fi
    done
  fi

  upstream_ver_path="manifests/${first_char}/${pkg_subpath}/${version}"
  api_request GET "/repos/${upstream_repo}/contents/${upstream_ver_path}"
  if [ "$API_STATUS" = "200" ]; then
    echo "WinGet ${winget_id} ${version} is already published in ${upstream_repo}."
    continue
  elif [ "$API_STATUS" != "404" ]; then
    api_expect_2xx "GET upstream ${upstream_ver_path}"
  fi

  if [ "$checked_base_branch" -eq 0 ]; then
    api_request GET "/repos/${upstream_repo}/pulls?state=all&head=${fork_owner}:${base_branch}&per_page=10"
    api_expect_2xx "GET pulls for ${fork_owner}:${base_branch}"
    b_open_url="$(jq -r '[.[] | select(.state == "open")][0].html_url // empty' "$resp_file")"
    b_merged_url="$(jq -r '[.[] | select(.merged_at != null)][0].html_url // empty' "$resp_file")"
    b_closed_num="$(jq -r '[.[] | select(.state == "closed" and .merged_at == null)][0].number // empty' "$resp_file")"
    [ -n "$b_open_url" ] && [ -z "$existing_open_url" ] && existing_open_url="$b_open_url"
    [ -n "$b_merged_url" ] && [ -z "$existing_merged_url" ] && existing_merged_url="$b_merged_url"
    [ -n "$b_closed_num" ] && closed_unmerged_num="$b_closed_num"
  fi

  if [ -n "$existing_open_url" ]; then
    echo "Open WinGet PR already exists for ${winget_id} ${version}: ${existing_open_url}"
    continue
  fi
  if [ -n "$existing_merged_url" ]; then
    echo "WinGet PR for ${winget_id} ${version} is already merged: ${existing_merged_url}"
    continue
  fi

  target_branch="$base_branch"
  if [ -n "$closed_unmerged_num" ]; then
    if [ "$force_retry" != "true" ]; then
      echo "Previous WinGet PR #${closed_unmerged_num} for ${winget_id} ${version} was closed without merging; skipping automatic retry (set force_winget_retry=true to retry)."
      continue
    fi
    target_branch="${base_branch}-r$((max_retry + 1))"
  fi

  upstream_pkg_path="manifests/${first_char}/${pkg_subpath}"
  api_request GET "/repos/${upstream_repo}/contents/${upstream_pkg_path}"
  if [ "$API_STATUS" = "200" ]; then
    pr_title="Update: ${winget_id} to ${version}"
    pr_desc="Automated package update for \`${winget_id}\` version \`${version}\` (https://github.com/${repo}/releases/tag/v${version})."
  elif [ "$API_STATUS" = "404" ]; then
    if [ -z "$open_pkg_pr_url" ]; then
      search_q="repo:${upstream_repo} is:pr is:open \"${winget_id}\" in:title"
      encoded_q="$(jq -rn --arg q "$search_q" '$q | @uri')"
      api_request GET "/search/issues?q=${encoded_q}&per_page=5"
      if [ "$API_STATUS" = "200" ]; then
        open_pkg_pr_url="$(jq -r '.items[0].html_url // empty' "$resp_file")"
      fi
    fi
    if [ -n "$open_pkg_pr_url" ]; then
      echo "Package ${winget_id} is awaiting merge of initial onboarding PR (${open_pkg_pr_url}); deferring ${version} until initial PR merges."
      continue
    fi
    pr_title="New package: ${winget_id} version ${version}"
    pr_desc="New package submission for \`${winget_id}\` version \`${version}\` (https://github.com/${repo}/releases/tag/v${version})."
  else
    api_expect_2xx "GET upstream ${upstream_pkg_path}"
  fi

  ensure_fork_synced

  tree_items_file="$tmp_dir/tree_items.jsonl"
  : > "$tree_items_file"
  while IFS= read -r yf; do
    [ -f "$yf" ] || continue
    fname="$(basename "$yf")"
    jq -n \
      --arg path "${upstream_ver_path}/${fname}" \
      --rawfile content "$yf" \
      '{path: $path, mode: "100644", type: "blob", content: $content}' >> "$tree_items_file"
  done < <(find "$local_ver_dir" -maxdepth 1 -type f -name '*.yaml' | LC_ALL=C sort)

  tree_payload="$tmp_dir/tree_payload.json"
  jq -s --arg base_tree "$SYNCED_BASE_TREE_SHA" '{base_tree: $base_tree, tree: .}' "$tree_items_file" > "$tree_payload"
  api_request POST "/repos/${fork_repo}/git/trees" "$tree_payload"
  api_expect_2xx "POST git/trees for ${winget_id} ${version}"
  new_tree_sha="$(jq -r '.sha // empty' "$resp_file")"

  commit_payload="$tmp_dir/commit_payload.json"
  jq -n \
    --arg message "$pr_title" \
    --arg tree "$new_tree_sha" \
    --arg parent "$SYNCED_UPSTREAM_SHA" \
    '{message: $message, tree: $tree, parents: [$parent]}' > "$commit_payload"
  api_request POST "/repos/${fork_repo}/git/commits" "$commit_payload"
  api_expect_2xx "POST git/commits for ${winget_id} ${version}"
  new_commit_sha="$(jq -r '.sha // empty' "$resp_file")"

  api_request GET "/repos/${fork_repo}/git/ref/heads/${target_branch}"
  ref_payload="$tmp_dir/ref_payload.json"
  if [ "$API_STATUS" = "404" ]; then
    jq -n --arg ref "refs/heads/${target_branch}" --arg sha "$new_commit_sha" '{ref: $ref, sha: $sha}' > "$ref_payload"
    api_request POST "/repos/${fork_repo}/git/refs" "$ref_payload"
    api_expect_2xx "POST git/refs ${target_branch}"
  elif [ "$API_STATUS" = "200" ]; then
    jq -n --arg sha "$new_commit_sha" '{sha: $sha, force: true}' > "$ref_payload"
    api_request PATCH "/repos/${fork_repo}/git/refs/heads/${target_branch}" "$ref_payload"
    api_expect_2xx "PATCH git/refs ${target_branch}"
  else
    api_expect_2xx "GET git/ref/heads/${target_branch}"
  fi

  pr_body_file="$tmp_dir/pr_body.md"
  cat > "$pr_body_file" <<EOF
## Description
${pr_desc}

## Checklist

- [x] Signed the [Contributor License Agreement](https://cla.opensource.microsoft.com)
- [ ] Linked to an issue (if applicable)

## Manifest Checklist

- [x] Checked that there aren't other open [pull requests](https://github.com/microsoft/winget-pkgs/pulls) for the same manifest update/change
- [x] This PR only modifies one (1) manifest
- [ ] Validated manifest locally with \`winget validate --manifest <path>\` ([validation guide](https://github.com/microsoft/winget-pkgs/blob/master/doc/ValidationFailureGuide.md))
- [ ] Tested manifest locally with \`winget install --manifest <path>\`
- [x] Manifest conforms to the [${schema_short} schema](https://github.com/microsoft/winget-pkgs/tree/master/doc/manifest/schema/${manifest_ver})
EOF

  pr_payload="$tmp_dir/pr_payload.json"
  jq -n \
    --arg title "$pr_title" \
    --arg head "${fork_owner}:${target_branch}" \
    --arg base "$UPSTREAM_DEFAULT_BRANCH" \
    --rawfile body "$pr_body_file" \
    '{title: $title, head: $head, base: $base, body: $body, maintainer_can_modify: true}' > "$pr_payload"
  api_request POST "/repos/${upstream_repo}/pulls" "$pr_payload"
  api_expect_2xx "POST pulls for ${winget_id} ${version}"
  created_pr_url="$(jq -r '.html_url // empty' "$resp_file")"
  echo "Submitted WinGet PR for ${winget_id} ${version}: ${created_pr_url}"
done 3< <(jq -c '.[]' "$apps_file")
