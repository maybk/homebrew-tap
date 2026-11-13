#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_file="$repo_root/apps.json"

for sh_file in "$repo_root"/scripts/*.sh; do
  bash -n "$sh_file"
done

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
    manifests_base = File.join(ARGV[0], "winget/manifests")
    ver_dirs = Dir.glob(File.join(manifests_base, "**/*.yaml")).map { |f| File.dirname(f) }.uniq.sort
    ver_dirs.each do |ver_dir|
      rel = ver_dir.sub(%r{\A#{Regexp.escape(manifests_base)}/}, "")
      parts = rel.split("/")
      raise "Invalid WinGet directory depth: #{ver_dir}" if parts.length < 4
      expected_ver = parts.pop
      first_char = parts.shift
      expected_id = parts.join(".")
      raise "Shard mismatch in #{ver_dir}" unless first_char == parts.first[0].downcase

      files = Dir.glob(File.join(ver_dir, "*.yaml")).sort
      types = []
      files.each do |f|
        doc = Psych.safe_load_file(f, permitted_classes: [Date])
        raise "Invalid YAML root in #{f}" unless doc.is_a?(Hash)
        raise "PackageIdentifier mismatch in #{f}" unless doc["PackageIdentifier"] == expected_id
        raise "PackageVersion mismatch in #{f}" unless doc["PackageVersion"].to_s == expected_ver
        raise "Missing or unsupported ManifestVersion in #{f}" unless %w[1.12.0 1.28.0].include?(doc["ManifestVersion"])
        types << doc["ManifestType"]
      end
      %w[version installer defaultLocale].each do |req|
        raise "Missing ManifestType=#{req} in #{ver_dir}" unless types.include?(req)
      end
    end
  ' "$repo_root"
fi

tmp_dir="$(mktemp -d)"
mock_pid=""
cleanup() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" >/dev/null 2>&1 || true
    wait "$mock_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

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
    pkg_subpath="${winget_id//.//}"
    first_char="$(printf '%s' "$publisher" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    test -s "$tmp_dir/winget/manifests/${first_char}/${pkg_subpath}/1.0.0/${winget_id}.installer.yaml"
  fi
done < <(jq -c '.[]' "$apps_file")

# Test submit_winget_prs.sh state machine with a local mock GitHub API server
if command -v python3 >/dev/null 2>&1; then
  state_file="$tmp_dir/mock_state.json"
  port_file="$tmp_dir/mock_port.txt"
  cat > "$state_file" <<'EOF'
{
  "fork_exists": false,
  "upstream_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "fork_master_sha": "0000000000000000000000000000000000000000",
  "merge_conflict": false,
  "upstream_paths": [],
  "branches": {},
  "prs": [],
  "merge_upstream_calls": 0,
  "force_patch_calls": 0
}
EOF

  python3 - "$state_file" "$port_file" <<'PY' &
import http.server, json, pathlib, sys, urllib.parse

state_path = pathlib.Path(sys.argv[1])
port_path = pathlib.Path(sys.argv[2])

def load_state():
    return json.loads(state_path.read_text())

def save_state(st):
    state_path.write_text(json.dumps(st, indent=2))

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def read_json(self):
        n = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(n).decode()) if n > 0 else {}

    def check_auth(self):
        return self.headers.get("Authorization") == "Bearer mock-test-token"

    def do_GET(self):
        if not self.check_auth():
            return self.reply(401, {"message": "Bad credentials"})
        st = load_state()
        parsed = urllib.parse.urlparse(self.path)
        p = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if p == "/user":
            return self.reply(200, {"login": "maybk"})
        if p == "/repos/microsoft/winget-pkgs":
            return self.reply(200, {"default_branch": "master"})
        if p == "/repos/microsoft/winget-pkgs/git/ref/heads/master":
            return self.reply(200, {"object": {"sha": st["upstream_sha"]}})
        if p == "/repos/maybk/winget-pkgs":
            return self.reply(200, {"full_name": "maybk/winget-pkgs"}) if st["fork_exists"] else self.reply(404, {"message": "Not Found"})
        if p == "/repos/maybk/winget-pkgs/git/ref/heads/master":
            if not st["fork_exists"]:
                return self.reply(404, {"message": "Not Found"})
            return self.reply(200, {"object": {"sha": st["fork_master_sha"]}})
        if p.startswith("/repos/maybk/winget-pkgs/git/commits/"):
            return self.reply(200, {"tree": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}})
        if p.startswith("/repos/maybk/winget-pkgs/git/matching-refs/heads/"):
            if not st["fork_exists"]:
                return self.reply(404, {"message": "Not Found"})
            prefix = p.split("/matching-refs/heads/", 1)[1]
            items = [{"ref": f"refs/heads/{b}", "object": {"sha": sha}} for b, sha in sorted(st["branches"].items()) if b.startswith(prefix)]
            return self.reply(200, items)
        if p.startswith("/repos/maybk/winget-pkgs/git/ref/heads/"):
            b = p.split("/git/ref/heads/", 1)[1]
            if b in st["branches"]:
                return self.reply(200, {"ref": f"refs/heads/{b}", "object": {"sha": st["branches"][b]}})
            return self.reply(404, {"message": "Not Found"})
        if p.startswith("/repos/microsoft/winget-pkgs/contents/"):
            rel = p.split("/contents/", 1)[1]
            if rel in st["upstream_paths"]:
                return self.reply(200, [{"name": "ok"}])
            return self.reply(404, {"message": "Not Found"})
        if p == "/repos/microsoft/winget-pkgs/pulls":
            head = qs.get("head", [""])[0]
            state = qs.get("state", ["open"])[0]
            out = [pr for pr in st["prs"] if (not head or pr["head"] == head) and (state == "all" or pr["state"] == state)]
            return self.reply(200, out)
        if p == "/search/issues":
            q = qs.get("q", [""])[0]
            out = [pr for pr in st["prs"] if pr["state"] == "open"]
            return self.reply(200, {"total_count": len(out), "items": out})
        return self.reply(404, {"message": f"Unhandled GET {p}"})

    def do_POST(self):
        if not self.check_auth():
            return self.reply(401, {"message": "Bad credentials"})
        st = load_state()
        p = urllib.parse.urlparse(self.path).path
        data = self.read_json()

        if p == "/repos/microsoft/winget-pkgs/forks":
            st["fork_exists"] = True
            st["fork_master_sha"] = "1111111111111111111111111111111111111111"
            save_state(st)
            return self.reply(202, {"full_name": "maybk/winget-pkgs"})
        if p == "/repos/maybk/winget-pkgs/merge-upstream":
            st["merge_upstream_calls"] += 1
            if st.get("workflow_scope_blocked"):
                save_state(st)
                return self.reply(422, {"message": "refusing to allow a Personal Access Token to create or update workflow '.github/workflows/pesterTests.yaml' without 'workflow' scope"})
            if st["merge_conflict"]:
                save_state(st)
                return self.reply(409, {"message": "Merge conflict"})
            st["fork_master_sha"] = st["upstream_sha"]
            save_state(st)
            return self.reply(200, {"merge_type": "fast-forward"})
        if p == "/repos/maybk/winget-pkgs/git/trees":
            assert len(data.get("tree", [])) >= 3
            return self.reply(201, {"sha": "cccccccccccccccccccccccccccccccccccccccc"})
        if p == "/repos/maybk/winget-pkgs/git/commits":
            expected_parent = st["fork_master_sha"] if st.get("workflow_scope_blocked") else st["upstream_sha"]
            assert data["parents"] == [expected_parent]
            return self.reply(201, {"sha": "dddddddddddddddddddddddddddddddddddddddd", "message": data["message"]})
        if p == "/repos/maybk/winget-pkgs/git/refs":
            b = data["ref"].replace("refs/heads/", "", 1)
            st["branches"][b] = data["sha"]
            save_state(st)
            return self.reply(201, {"ref": data["ref"]})
        if p == "/repos/microsoft/winget-pkgs/pulls":
            num = 100 + len(st["prs"]) + 1
            pr = {
                "number": num,
                "title": data["title"],
                "head": data["head"],
                "base": data["base"],
                "body": data["body"],
                "state": "open",
                "merged_at": None,
                "html_url": f"https://github.com/microsoft/winget-pkgs/pull/{num}",
            }
            st["prs"].append(pr)
            save_state(st)
            return self.reply(201, pr)
        return self.reply(404, {"message": f"Unhandled POST {p}"})

    def do_PATCH(self):
        if not self.check_auth():
            return self.reply(401, {"message": "Bad credentials"})
        st = load_state()
        p = urllib.parse.urlparse(self.path).path
        data = self.read_json()
        if p == "/repos/maybk/winget-pkgs/git/refs/heads/master":
            st["force_patch_calls"] += 1
            if st.get("workflow_scope_blocked"):
                save_state(st)
                return self.reply(422, {"message": "refusing to allow a Personal Access Token to create or update workflow '.github/workflows/pesterTests.yaml' without 'workflow' scope"})
            st["fork_master_sha"] = data["sha"]
            save_state(st)
            return self.reply(200, {"object": {"sha": data["sha"]}})
        if p.startswith("/repos/maybk/winget-pkgs/git/refs/heads/"):
            b = p.split("/git/refs/heads/", 1)[1]
            st["branches"][b] = data["sha"]
            save_state(st)
            return self.reply(200, {"object": {"sha": data["sha"]}})
        return self.reply(404, {"message": f"Unhandled PATCH {p}"})

    def do_DELETE(self):
        if not self.check_auth():
            return self.reply(401, {"message": "Bad credentials"})
        st = load_state()
        p = urllib.parse.urlparse(self.path).path
        if p.startswith("/repos/maybk/winget-pkgs/git/refs/heads/"):
            b = p.split("/git/refs/heads/", 1)[1]
            st["branches"].pop(b, None)
            save_state(st)
            return self.reply(204)
        return self.reply(404, {"message": f"Unhandled DELETE {p}"})

srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(srv.server_address[1]))
srv.serve_forever()
PY
  mock_pid="$!"
  for _ in $(seq 1 30); do
    [ -s "$port_file" ] && break
    sleep 0.05
  done
  mock_port="$(cat "$port_file")"
  mock_api="http://127.0.0.1:${mock_port}"

  # 1. Missing token gracefully skips
  WINGET_GITHUB_TOKEN="" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit | grep -Fq "Skipping WinGet PR submission"

  # 2. First submission auto-creates fork, syncs master, and opens "New package" PR
  WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" WINGET_POLL_INTERVAL_SEC="0.05" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit
  jq -e '
    .fork_exists == true and
    .fork_master_sha == .upstream_sha and
    .merge_upstream_calls == 1 and
    (.prs | length == 1) and
    .prs[0].title == "New package: maybk.TunnelKit version 1.0.0" and
    .prs[0].head == "maybk:maybk.TunnelKit-1.0.0"
  ' "$state_file" >/dev/null

  # 3. Re-run while open PR exists is idempotent (no new PRs)
  WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit | grep -Fq "Open WinGet PR already exists"
  jq -e '.prs | length == 1' "$state_file" >/dev/null

  # 4. New version 1.1.0 defers while initial 1.0.0 New-Package PR is still unmerged
  sums_110="$tmp_dir/tunnelkit-1.1.0-SHA256SUMS.txt"
  sed 's/-1\.0\.0-/-1.1.0-/g' "$tmp_dir/tunnelkit-SHA256SUMS.txt" > "$sums_110"
  bash "$repo_root/scripts/sync_app.sh" tunnelkit "1.1.0" "$sums_110" "$tmp_dir" "$apps_file" "2026-11-13"
  WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit | grep -Fq "awaiting merge of initial onboarding PR"
  jq -e '.prs | length == 1' "$state_file" >/dev/null

  # 5. Once 1.0.0 merges upstream and upstream master advances: syncs fork master, deletes merged 1.0.0 branch, submits Update PR for 1.1.0
  jq '
    .prs[0].state = "closed" |
    .prs[0].merged_at = "2026-11-13T08:00:00Z" |
    .upstream_paths = ["manifests/m/maybk/TunnelKit", "manifests/m/maybk/TunnelKit/1.0.0"] |
    .upstream_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit
  jq -e '
    .fork_master_sha == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" and
    (.branches | has("maybk.TunnelKit-1.0.0") | not) and
    (.prs | length == 2) and
    .prs[1].title == "Update: maybk.TunnelKit to 1.1.0" and
    .prs[1].head == "maybk:maybk.TunnelKit-1.1.0"
  ' "$state_file" >/dev/null

  # 6. Closed unmerged PR skips automatic retry unless force_retry=true, and diverged fork master recovers via force PATCH
  jq '
    .prs[1].state = "closed" |
    .prs[1].merged_at = null |
    .upstream_sha = "ffffffffffffffffffffffffffffffffffffffff" |
    .merge_conflict = true
  ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit "false" | grep -Fq "skipping automatic retry"
  jq -e '.prs | length == 2' "$state_file" >/dev/null

  WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
    bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit "true"
  jq -e '
    .force_patch_calls == 1 and
    .fork_master_sha == "ffffffffffffffffffffffffffffffffffffffff" and
    (.prs | length == 3) and
    .prs[2].head == "maybk:maybk.TunnelKit-1.1.0-r2"
  ' "$state_file" >/dev/null

  # 7. When upstream modifies .github/workflows and PAT only has public_repo (no workflow scope), gracefully falls back to fork master SHA and still submits PR cleanly
  sums_120="$tmp_dir/tunnelkit-1.2.0-SHA256SUMS.txt"
  sed 's/-1\.0\.0-/-1.2.0-/g' "$tmp_dir/tunnelkit-SHA256SUMS.txt" > "$sums_120"
  bash "$repo_root/scripts/sync_app.sh" tunnelkit "1.2.0" "$sums_120" "$tmp_dir" "$apps_file" "2026-11-13"
  jq '
    .prs[2].state = "closed" |
    .prs[2].merged_at = "2026-11-13T09:00:00Z" |
    .upstream_paths = ["manifests/m/maybk/TunnelKit", "manifests/m/maybk/TunnelKit/1.0.0", "manifests/m/maybk/TunnelKit/1.1.0"] |
    .upstream_sha = "1212121212121212121212121212121212121212" |
    .merge_conflict = false |
    .workflow_scope_blocked = true
  ' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  stage7_out="$(
    WINGET_GITHUB_TOKEN="mock-test-token" WINGET_GITHUB_API_URL="$mock_api" WINGET_MANIFESTS_ROOT="$tmp_dir" WINGET_APPS_FILE="$apps_file" \
      bash "$repo_root/scripts/submit_winget_prs.sh" tunnelkit
  )"
  grep -Fq "token lacks workflow scope" <<<"$stage7_out"
  jq -e '
    .fork_master_sha == "ffffffffffffffffffffffffffffffffffffffff" and
    (.branches | has("maybk.TunnelKit-1.1.0-r2") | not) and
    (.prs | length == 4) and
    .prs[3].title == "Update: maybk.TunnelKit to 1.2.0" and
    .prs[3].head == "maybk:maybk.TunnelKit-1.2.0"
  ' "$state_file" >/dev/null
fi
