#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_file="$repo_root/apps.json"
target_token="${1:-}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

tokens="$(jq -r '.[].token' "$apps_file")"
for token in $tokens; do
  if [ -n "$target_token" ] && [ "$token" != "$target_token" ]; then
    continue
  fi

  repo="$(jq -r --arg t "$token" '.[] | select(.token == $t) | .repo' "$apps_file")"
  api_url="https://api.github.com/repos/${repo}/releases/latest"
  if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    release_json="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}" "$api_url")"
  else
    release_json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url")"
  fi
  tag_name="$(jq -r '.tag_name // empty' <<<"$release_json")"
  is_draft="$(jq -r '.draft // false' <<<"$release_json")"
  is_prerelease="$(jq -r '.prerelease // false' <<<"$release_json")"
  version="${tag_name#v}"

  if [ -z "$version" ] || [ "$is_draft" = "true" ] || [ "$is_prerelease" = "true" ]; then
    echo "Skipping $token: no stable latest release ($tag_name)"
    continue
  fi

  sums_file="$tmp_dir/${token}-SHA256SUMS.txt"
  sums_url="$(jq -r '.assets[] | select(.name == "SHA256SUMS.txt") | .browser_download_url' <<<"$release_json" | head -n 1)"
  if [ -n "$sums_url" ]; then
    curl -fsSL "$sums_url" -o "$sums_file"
  else
    jq -r '.assets[] | select(.digest != null and (.digest | startswith("sha256:"))) | "\(.digest | sub("^sha256:"; ""))  \(.name)"' <<<"$release_json" > "$sums_file"
  fi

  bash "$repo_root/scripts/sync_app.sh" "$token" "$version" "$sums_file" "$repo_root" "$apps_file"
  echo "Synced $token -> v$version"
done
