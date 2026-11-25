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
           ((.type // "cask") | . == "cask" or . == "formula") and
           ((.winget_installer_type // "nullsoft") | . == "nullsoft" or . == "portable") and
           ((.npm == null) or (
             (.npm | type == "object") and
             ((.type // "cask") == "formula") and
             (.npm.package | type == "string" and test("^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$")) and
             ((.npm.bin // .bin // .token) | type == "string" and test("^[a-zA-Z0-9._-]+$"))
           )) and
           (.name | type == "string" and length > 0) and
           (.repo | type == "string" and test("^[^/]+/[^/]+$")) and
           (.desc | type == "string" and length > 0) and
           (.homepage | type == "string" and startswith("https://")) and
           (.license | type == "string" and length > 0) and
           (.asset_prefix | type == "string" and length > 0))
' "$apps_file" >/dev/null

shopt -s nullglob
rb_files=("$repo_root"/Casks/*.rb "$repo_root"/Formula/*.rb)
shopt -u nullglob
test "${#rb_files[@]}" -gt 0
for rb_file in "${rb_files[@]}"; do
  if command -v ruby >/dev/null 2>&1; then
    ruby -c "$rb_file" >/dev/null
  fi
done

if command -v brew >/dev/null 2>&1; then
  brew_major="$(brew --version 2>/dev/null | sed -n 's/^Homebrew \([0-9][0-9]*\)\..*/\1/p' | head -n 1)"
  if [ -n "$brew_major" ] && [ "$brew_major" -ge 4 ]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew style "${rb_files[@]}"
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
    (((.shortcuts // []) | length > 0) or ((.bin // "") != "")) and
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
sync_mock_pid=""
mock_pid=""
npm_mock_pid=""
cleanup() {
  for pid in "$sync_mock_pid" "$mock_pid" "$npm_mock_pid"; do
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

while IFS= read -r app_json; do
  token="$(jq -r '.token' <<<"$app_json")"
  app_type="$(jq -r '.type // "cask"' <<<"$app_json")"
  app_bundle="$(jq -r '.app_bundle // empty' <<<"$app_json")"
  bundle_id="$(jq -r '.bundle_id // empty' <<<"$app_json")"
  macos_min="$(jq -r '.macos_min // empty' <<<"$app_json")"
  cli_bin="$(jq -r '.bin // .token' <<<"$app_json")"
  windows_bin="$(jq -r '.windows_bin' <<<"$app_json")"
  windows_service="$(jq -r '.windows_service // empty' <<<"$app_json")"
  winget_id="$(jq -r '.winget_id // empty' <<<"$app_json")"
  winget_installer_type="$(jq -r '.winget_installer_type // "nullsoft"' <<<"$app_json")"
  prefix="$(jq -r '.asset_prefix' <<<"$app_json")"

  sums_file="$tmp_dir/${token}-SHA256SUMS.txt"
  if [ "$app_type" = "formula" ]; then
    grep -Fq "bin.install \"${cli_bin}\"" "$repo_root/Formula/${token}.rb"
    grep -Fq 'test do' "$repo_root/Formula/${token}.rb"
    jq -e --arg wb "$windows_bin" '.bin == $wb' "$repo_root/bucket/${token}.json" >/dev/null

    cat > "$sums_file" <<EOF
1111111111111111111111111111111111111111111111111111111111111111  ${prefix}-1.0.0-darwin-arm64.tar.gz
2222222222222222222222222222222222222222222222222222222222222222  ${prefix}-1.0.0-darwin-amd64.tar.gz
3333333333333333333333333333333333333333333333333333333333333333  ${prefix}-1.0.0-linux-arm64.tar.gz
4444444444444444444444444444444444444444444444444444444444444444  ${prefix}-1.0.0-linux-amd64.tar.gz
5555555555555555555555555555555555555555555555555555555555555555  ${prefix}-1.0.0-windows-amd64.zip
6666666666666666666666666666666666666666666666666666666666666666  ${prefix}-1.0.0-windows-arm64.zip
EOF
    bash "$repo_root/scripts/sync_app.sh" "$token" "1.0.0" "$sums_file" "$tmp_dir" "$apps_file" "2026-11-10"
    test -s "$tmp_dir/Formula/${token}.rb"
    test -s "$tmp_dir/bucket/${token}.json"
    if command -v ruby >/dev/null 2>&1; then
      ruby -c "$tmp_dir/Formula/${token}.rb" >/dev/null
    fi
  else
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
    if command -v ruby >/dev/null 2>&1; then
      ruby -c "$tmp_dir/Casks/${token}.rb" >/dev/null
    fi
  fi
  if [ -n "$winget_id" ]; then
    publisher="${winget_id%%.*}"
    pkg_subpath="${winget_id//.//}"
    first_char="$(printf '%s' "$publisher" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    gen_installer="$tmp_dir/winget/manifests/${first_char}/${pkg_subpath}/1.0.0/${winget_id}.installer.yaml"
    test -s "$gen_installer"
    if [ "$winget_installer_type" = "portable" ]; then
      grep -Fq "InstallerType: zip" "$gen_installer"
      grep -Fq "NestedInstallerType: portable" "$gen_installer"
      grep -Fq "RelativeFilePath: ${windows_bin}" "$gen_installer"
      grep -Fq "PortableCommandAlias: ${cli_bin}" "$gen_installer"
    fi
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

# Test publish_npm.sh end-to-end with a local mock Release + npm Registry server and real launcher smoke test
if command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  npm_root="$tmp_dir/npm-test"
  npm_assets="$npm_root/assets"
  npm_manifests="$npm_root/manifests"
  npm_staged="$npm_root/staged"
  npm_state="$npm_root/npm_state.json"
  npm_port_file="$npm_root/npm_port.txt"
  mkdir -p "$npm_assets/maybk/veri/releases/download/v1.0.0" "$npm_assets/maybk/veri/releases/download/v1.1.0" "$npm_manifests"

  # Build synthetic 6-platform release archives (1.0.0 & 1.1.0) + matching Formula/Scoop manifests
  python3 - "$npm_assets" "$npm_root" <<'PY'
import hashlib, io, pathlib, stat, tarfile, zipfile, sys

assets_root = pathlib.Path(sys.argv[1])
out_root = pathlib.Path(sys.argv[2])

unix_bin = b"""#!/usr/bin/env sh
if [ "${1:-}" = "--exit-code" ]; then
  echo "mock-stderr-code-${2:-1}" >&2
  exit "${2:-1}"
fi
echo "mock-veri-output: $*"
"""
win_bin = b"MZmock-windows-binary-payload"
license_txt = b"MIT License\n"
readme_en = b"""# veri

<img src="assets/demo-en.svg" alt="demo">

See [Usage Guide](./docs/guide/usage.md) and [Diagram](./assets/arch.png).
"""

def build_release(ver):
    rel_dir = assets_root / "maybk" / "veri" / "releases" / "download" / f"v{ver}"
    sums = []
    for suffix in ("darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"):
        fname = f"veri-{ver}-{suffix}.tar.gz"
        fpath = rel_dir / fname
        with tarfile.open(fpath, "w:gz") as tf:
            for name, data, mode in [
                ("veri", unix_bin, 0o755),
                ("LICENSE", license_txt, 0o644),
                ("README.en.md", readme_en, 0o644),
            ]:
                ti = tarfile.TarInfo(name=name)
                ti.size = len(data)
                ti.mode = mode
                tf.addfile(ti, io.BytesIO(data))
        digest = hashlib.sha256(fpath.read_bytes()).hexdigest()
        sums.append(f"{digest}  {fname}")

    for suffix in ("windows-amd64", "windows-arm64"):
        fname = f"veri-{ver}-{suffix}.zip"
        fpath = rel_dir / fname
        with zipfile.ZipFile(fpath, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("veri.exe", win_bin)
            zf.writestr("LICENSE", license_txt)
            zf.writestr("README.en.md", readme_en)
        digest = hashlib.sha256(fpath.read_bytes()).hexdigest()
        sums.append(f"{digest}  {fname}")

    (out_root / f"veri-{ver}-SHA256SUMS.txt").write_text("\n".join(sums) + "\n")

build_release("1.0.0")
build_release("1.1.0")
PY

  bash "$repo_root/scripts/sync_app.sh" veri "1.0.0" "$npm_root/veri-1.0.0-SHA256SUMS.txt" "$npm_manifests" "$apps_file" "2026-11-20"

  cat > "$npm_state" <<'EOF'
{
  "packages": {},
  "publish_order": [],
  "download_count": 0,
  "tamper_archive": false
}
EOF

  python3 - "$npm_state" "$npm_port_file" "$npm_assets" <<'PY' &
import base64, http.server, io, json, pathlib, sys, tarfile, urllib.parse

state_path = pathlib.Path(sys.argv[1])
port_path = pathlib.Path(sys.argv[2])
assets_root = pathlib.Path(sys.argv[3])

def load_state():
    return json.loads(state_path.read_text())

def save_state(st):
    state_path.write_text(json.dumps(st, indent=2))

class NpmMockHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        st = load_state()
        parsed = urllib.parse.urlparse(self.path)
        rel_path = parsed.path.lstrip("/")

        if rel_path.startswith("maybk/veri/releases/download/"):
            target = assets_root / rel_path
            if not target.is_file():
                return self.reply_json(404, {"error": "not found"})
            st["download_count"] += 1
            save_state(st)
            data = target.read_bytes()
            if st.get("tamper_archive"):
                data = data + b"TAMPERED"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        pkg_name = urllib.parse.unquote(rel_path)
        if pkg_name in st["packages"]:
            return self.reply_json(200, {"name": pkg_name, "versions": st["packages"][pkg_name]})
        return self.reply_json(404, {"error": "Not found"})

    def do_PUT(self):
        if self.headers.get("Authorization") != "Bearer mock-npm-token":
            return self.reply_json(401, {"error": "Unauthorized"})
        n = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(n).decode())
        pkg_name = urllib.parse.unquote(urllib.parse.urlparse(self.path).path.lstrip("/"))
        versions = payload.get("versions", {})
        if not versions:
            return self.reply_json(400, {"error": "Missing versions"})
        ver = next(iter(versions.keys()))
        meta = versions[ver]

        # Inspect uploaded tarball for executable bit on unix binaries & rewritten README links on main pkg
        attachments = payload.get("_attachments", {})
        tar_files = {}
        for att in attachments.values():
            raw_tgz = base64.b64decode(att["data"])
            with tarfile.open(fileobj=io.BytesIO(raw_tgz), mode="r:gz") as tf:
                for m in tf.getmembers():
                    tar_files[m.name] = m.mode
                    if m.name == "package/README.md":
                        meta["_readme_text"] = tf.extractfile(m).read().decode("utf-8")
        meta["_tar_files"] = tar_files

        st = load_state()
        pkg_vers = st["packages"].setdefault(pkg_name, {})
        if ver in pkg_vers:
            return self.reply_json(409, {"error": "Conflict"})
        pkg_vers[ver] = meta
        st["publish_order"].append(f"{pkg_name}@{ver}")
        save_state(st)
        return self.reply_json(201, {"ok": True, "id": pkg_name, "rev": "1-mock"})

srv = http.server.HTTPServer(("127.0.0.1", 0), NpmMockHandler)
port_path.write_text(str(srv.server_address[1]))
srv.serve_forever()
PY
  npm_mock_pid="$!"
  for _ in $(seq 1 30); do
    [ -s "$npm_port_file" ] && break
    sleep 0.05
  done
  npm_mock_port="$(cat "$npm_port_file")"
  npm_mock_url="http://127.0.0.1:${npm_mock_port}"

  # 1. Missing NPM_TOKEN gracefully skips
  NPM_TOKEN="" NPM_APPS_FILE="$apps_file" NPM_MANIFESTS_ROOT="$npm_manifests" \
    bash "$repo_root/scripts/publish_npm.sh" veri | grep -Fq "Skipping npm publish"

  # 2. Tampered archive SHA-256 fails fast with zero publishes
  jq '.tamper_archive = true' "$npm_state" > "$npm_state.tmp" && mv "$npm_state.tmp" "$npm_state"
  if NPM_TOKEN="mock-npm-token" NPM_APPS_FILE="$apps_file" NPM_MANIFESTS_ROOT="$npm_manifests" \
      NPM_REGISTRY_URL="$npm_mock_url" NPM_RELEASE_BASE_URL="$npm_mock_url" NPM_RETRY_SLEEP_SEC="0.05" \
      bash "$repo_root/scripts/publish_npm.sh" veri >/dev/null 2>&1; then
    echo "Expected publish_npm.sh to abort on SHA-256 mismatch" >&2
    exit 1
  fi
  jq -e '(.publish_order | length == 0)' "$npm_state" >/dev/null

  # 3. Clean 1.0.0 publish: 6 platform subpackages first, main package last
  jq '.tamper_archive = false | .download_count = 0' "$npm_state" > "$npm_state.tmp" && mv "$npm_state.tmp" "$npm_state"
  NPM_TOKEN="mock-npm-token" NPM_APPS_FILE="$apps_file" NPM_MANIFESTS_ROOT="$npm_manifests" \
    NPM_REGISTRY_URL="$npm_mock_url" NPM_RELEASE_BASE_URL="$npm_mock_url" NPM_RETRY_SLEEP_SEC="0.05" \
    NPM_OUTPUT_DIR="$npm_staged" \
    bash "$repo_root/scripts/publish_npm.sh" veri

  jq -e '
    (.publish_order | length == 7) and
    (.publish_order[6] == "@maybk/veri@1.0.0") and
    (.packages["@maybk/veri"]["1.0.0"].bin == {"veri": "bin/veri.js"}) and
    (.packages["@maybk/veri"]["1.0.0"].optionalDependencies | length == 6) and
    (.packages["@maybk/veri"]["1.0.0"].scripts == null) and
    (.packages["@maybk/veri"]["1.0.0"]._readme_text | contains("https://raw.githubusercontent.com/maybk/veri/v1.0.0/assets/demo-en.svg")) and
    (.packages["@maybk/veri"]["1.0.0"]._readme_text | contains("https://github.com/maybk/veri/blob/v1.0.0/docs/guide/usage.md")) and
    (.packages["@maybk/veri-darwin-arm64"]["1.0.0"].os == ["darwin"]) and
    (.packages["@maybk/veri-darwin-arm64"]["1.0.0"].cpu == ["arm64"]) and
    (.packages["@maybk/veri-darwin-arm64"]["1.0.0"].preferUnplugged == true) and
    (.packages["@maybk/veri-darwin-arm64"]["1.0.0"].scripts == null) and
    ((.packages["@maybk/veri-darwin-arm64"]["1.0.0"]._tar_files["package/bin/veri"] // 0) >= 493) and
    (.packages["@maybk/veri-win32-x64"]["1.0.0"].os == ["win32"]) and
    (.packages["@maybk/veri-win32-x64"]["1.0.0"]._tar_files | has("package/bin/veri.exe"))
  ' "$npm_state" >/dev/null

  # 4. Real Node.js launcher execution smoke test (current host platform/arch)
  host_key="$(node -e 'console.log(`${process.platform}-${process.arch}`)')"
  if [ -d "$npm_staged/$host_key" ]; then
    smoke_nm="$npm_root/smoke/node_modules/@maybk"
    mkdir -p "$smoke_nm"
    cp -R "$npm_staged/main" "$smoke_nm/veri"
    cp -R "$npm_staged/$host_key" "$smoke_nm/veri-$host_key"

    smoke_out="$(node "$smoke_nm/veri/bin/veri.js" --hello world)"
    [ "$smoke_out" = "mock-veri-output: --hello world" ]

    set +e
    smoke_err="$(node "$smoke_nm/veri/bin/veri.js" --exit-code 3 2>&1 >/dev/null)"
    smoke_rc="$?"
    set -e
    [ "$smoke_rc" -eq 3 ]
    grep -Fq "mock-stderr-code-3" <<<"$smoke_err"

    # Missing optional platform package exits cleanly with helpful stderr and empty stdout
    rm -rf "$smoke_nm/veri-$host_key"
    set +e
    missing_out="$(node "$smoke_nm/veri/bin/veri.js" 2>"$npm_root/missing.err")"
    missing_rc="$?"
    set -e
    [ "$missing_rc" -eq 1 ]
    [ -z "$missing_out" ]
    grep -Fq -- "--no-optional" "$npm_root/missing.err"
  fi

  # 5. Re-run for already-published 1.0.0 is 100% idempotent (0 downloads, 0 publishes)
  prev_downloads="$(jq -r '.download_count' "$npm_state")"
  NPM_TOKEN="mock-npm-token" NPM_APPS_FILE="$apps_file" NPM_MANIFESTS_ROOT="$npm_manifests" \
    NPM_REGISTRY_URL="$npm_mock_url" NPM_RELEASE_BASE_URL="$npm_mock_url" NPM_RETRY_SLEEP_SEC="0.05" \
    bash "$repo_root/scripts/publish_npm.sh" veri | grep -Fq "already published"
  jq -e --argjson prev "$prev_downloads" '(.publish_order | length == 7) and (.download_count == $prev)' "$npm_state" >/dev/null

  # 6. Partial-failure resume for 1.1.0: pre-seed 2 subpackages, verify only remaining 4 subpackages + main publish
  bash "$repo_root/scripts/sync_app.sh" veri "1.1.0" "$npm_root/veri-1.1.0-SHA256SUMS.txt" "$npm_manifests" "$apps_file" "2026-11-21"
  jq '
    .packages["@maybk/veri-darwin-arm64"]["1.1.0"] = {"version": "1.1.0"} |
    .packages["@maybk/veri-darwin-x64"]["1.1.0"] = {"version": "1.1.0"}
  ' "$npm_state" > "$npm_state.tmp" && mv "$npm_state.tmp" "$npm_state"

  NPM_TOKEN="mock-npm-token" NPM_APPS_FILE="$apps_file" NPM_MANIFESTS_ROOT="$npm_manifests" \
    NPM_REGISTRY_URL="$npm_mock_url" NPM_RELEASE_BASE_URL="$npm_mock_url" NPM_RETRY_SLEEP_SEC="0.05" \
    bash "$repo_root/scripts/publish_npm.sh" veri

  jq -e '
    (.publish_order | length == 12) and
    (.publish_order[7:12] == [
      "@maybk/veri-linux-arm64@1.1.0",
      "@maybk/veri-linux-x64@1.1.0",
      "@maybk/veri-win32-x64@1.1.0",
      "@maybk/veri-win32-arm64@1.1.0",
      "@maybk/veri@1.1.0"
    ])
  ' "$npm_state" >/dev/null
fi

# Test sync_all.sh with a local mock GitHub Releases API server
if command -v python3 >/dev/null 2>&1; then
  sync_root="$tmp_dir/sync-all-test"
  sync_out="$sync_root/out"
  sync_state="$sync_root/state.json"
  sync_port_file="$sync_root/port.txt"
  mkdir -p "$sync_out"

  cat > "$sync_state" <<'EOF'
{
  "veri_calls": 0,
  "mode": "normal",
  "sums_url_override": ""
}
EOF

  python3 - "$sync_state" "$sync_port_file" <<'PY' &
import http.server, json, pathlib, sys, urllib.parse

state_path = pathlib.Path(sys.argv[1])
port_path = pathlib.Path(sys.argv[2])

def load_state():
    return json.loads(state_path.read_text())

def save_state(st):
    state_path.write_text(json.dumps(st, indent=2))

def veri_sums(ver):
    return "\n".join([
        f"1111111111111111111111111111111111111111111111111111111111111111  veri-{ver}-darwin-arm64.tar.gz",
        f"2222222222222222222222222222222222222222222222222222222222222222  veri-{ver}-darwin-amd64.tar.gz",
        f"3333333333333333333333333333333333333333333333333333333333333333  veri-{ver}-linux-arm64.tar.gz",
        f"4444444444444444444444444444444444444444444444444444444444444444  veri-{ver}-linux-amd64.tar.gz",
        f"5555555555555555555555555555555555555555555555555555555555555555  veri-{ver}-windows-amd64.zip",
        f"6666666666666666666666666666666666666666666666666666666666666666  veri-{ver}-windows-arm64.zip",
    ]) + "\n"

class SyncMockHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        st = load_state()
        base = f"http://127.0.0.1:{self.server.server_address[1]}"
        p = urllib.parse.urlparse(self.path).path

        if p == "/repos/maybk/veri/releases/latest":
            st["veri_calls"] += 1
            calls = st["veri_calls"]
            save_state(st)
            mode = st["mode"]

            if mode == "eventual_404_then_200":
                if calls == 1:
                    return self.reply_json(404, {"message": "Not Found"})
                if calls == 2:
                    ver = "0.2.5"
                else:
                    ver = "0.2.6"
            elif mode == "stale_timeout":
                ver = "0.2.5"
            elif mode == "downgrade":
                ver = "0.2.5"
            elif mode == "draft":
                return self.reply_json(200, {
                    "tag_name": "v0.2.7",
                    "draft": True,
                    "prerelease": False,
                    "published_at": "2026-11-25T00:00:00Z",
                    "assets": [],
                })
            elif mode == "auth_403":
                return self.reply_json(403, {"message": "Forbidden"})
            elif mode == "semver_0_10_0":
                ver = "0.10.0"
            elif mode == "semver_0_9_0":
                ver = "0.9.0"
            elif mode == "digest_fallback":
                ver = "0.2.7"
                return self.reply_json(200, {
                    "tag_name": f"v{ver}",
                    "draft": False,
                    "prerelease": False,
                    "published_at": "2026-11-25T00:00:00Z",
                    "assets": [
                        {"name": f"veri-{ver}-darwin-arm64.tar.gz", "digest": "sha256:" + "1" * 64},
                        {"name": f"veri-{ver}-darwin-amd64.tar.gz", "digest": "sha256:" + "2" * 64},
                        {"name": f"veri-{ver}-linux-arm64.tar.gz", "digest": "sha256:" + "3" * 64},
                        {"name": f"veri-{ver}-linux-amd64.tar.gz", "digest": "sha256:" + "4" * 64},
                        {"name": f"veri-{ver}-windows-amd64.zip", "digest": "sha256:" + "5" * 64},
                        {"name": f"veri-{ver}-windows-arm64.zip", "digest": "sha256:" + "6" * 64},
                    ],
                })
            else:
                ver = "0.2.6"

            sums_url = st.get("sums_url_override") or f"{base}/maybk/veri/releases/download/v{ver}/SHA256SUMS.txt"
            return self.reply_json(200, {
                "tag_name": f"v{ver}",
                "draft": False,
                "prerelease": False,
                "published_at": "2026-11-25T00:00:00Z",
                "assets": [
                    {"name": "SHA256SUMS.txt", "browser_download_url": sums_url},
                ],
            })

        if p.startswith("/maybk/veri/releases/download/v") and p.endswith("/SHA256SUMS.txt"):
            ver = p.split("/download/v", 1)[1].split("/", 1)[0]
            data = veri_sums(ver).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        return self.reply_json(404, {"message": f"Unhandled GET {p}"})

srv = http.server.HTTPServer(("127.0.0.1", 0), SyncMockHandler)
port_path.write_text(str(srv.server_address[1]))
srv.serve_forever()
PY
  sync_mock_pid="$!"
  for _ in $(seq 1 30); do
    [ -s "$sync_port_file" ] && break
    sleep 0.05
  done
  sync_mock_port="$(cat "$sync_port_file")"
  sync_mock_url="http://127.0.0.1:${sync_mock_port}"

  # 1. expected_version without target app token must fail fast
  if SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
      bash "$repo_root/scripts/sync_all.sh" "" "0.2.6" >/dev/null 2>&1; then
    echo "Expected sync_all.sh to reject expected_version without app token" >&2
    exit 1
  fi

  # 2. Eventual consistency: first poll 404, second poll stale 0.2.5, third poll target 0.2.6 -> succeeds
  jq '.mode = "eventual_404_then_200" | .veri_calls = 0 | .sums_url_override = ""' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
    SYNC_WAIT_ATTEMPTS=4 SYNC_WAIT_INTERVAL_SEC=0.05 SYNC_RETRY_SLEEP_SEC=0.05 \
    bash "$repo_root/scripts/sync_all.sh" veri "v0.2.6" | grep -Fq "Synced veri -> v0.2.6"
  jq -e '.version == "0.2.6"' "$sync_out/bucket/veri.json" >/dev/null
  jq -e '.veri_calls == 3' "$sync_state" >/dev/null

  # 3. Anti-downgrade guard: existing 0.2.6 must reject older 0.2.5
  jq '.mode = "downgrade" | .veri_calls = 0' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  if SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
      bash "$repo_root/scripts/sync_all.sh" veri >/dev/null 2>&1; then
    echo "Expected sync_all.sh to refuse silent downgrade from 0.2.6 to 0.2.5" >&2
    exit 1
  fi

  # 4. expected_version timeout when upstream never advances -> fails fast
  jq '.mode = "stale_timeout" | .veri_calls = 0' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  if SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
      SYNC_WAIT_ATTEMPTS=2 SYNC_WAIT_INTERVAL_SEC=0.05 \
      bash "$repo_root/scripts/sync_all.sh" veri "0.2.7" >/dev/null 2>&1; then
    echo "Expected sync_all.sh to time out when expected_version never appears" >&2
    exit 1
  fi

  # 5. Untrusted SHA256SUMS.txt URL (tag mismatch) -> rejected
  jq --arg u "${sync_mock_url}/maybk/veri/releases/download/v0.2.5/SHA256SUMS.txt" \
    '.mode = "normal" | .veri_calls = 0 | .sums_url_override = $u' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  if SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
      bash "$repo_root/scripts/sync_all.sh" veri >/dev/null 2>&1; then
    echo "Expected sync_all.sh to reject SHA256SUMS.txt URL from a different tag" >&2
    exit 1
  fi

  # 6. Draft release -> skipped safely
  jq '.mode = "draft" | .veri_calls = 0 | .sums_url_override = ""' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
    bash "$repo_root/scripts/sync_all.sh" veri | grep -Fq "Skipping veri"

  # 7. Asset digest fallback (when SHA256SUMS.txt asset is absent) -> upgrades 0.2.6 -> 0.2.7
  jq '.mode = "digest_fallback" | .veri_calls = 0' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
    bash "$repo_root/scripts/sync_all.sh" veri "0.2.7" | grep -Fq "Synced veri -> v0.2.7"
  jq -e '.version == "0.2.7"' "$sync_out/bucket/veri.json" >/dev/null

  # 8. HTTP 403 fails fast without wasting expected_version polling attempts
  jq '.mode = "auth_403" | .veri_calls = 0' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  if SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
      SYNC_WAIT_ATTEMPTS=4 SYNC_WAIT_INTERVAL_SEC=0.05 \
      bash "$repo_root/scripts/sync_all.sh" veri "0.2.8" >/dev/null 2>&1; then
    echo "Expected sync_all.sh to fail fast on HTTP 403" >&2
    exit 1
  fi
  jq -e '.veri_calls == 1' "$sync_state" >/dev/null

  # 9. Numeric SemVer comparison: 0.2.7 -> 0.10.0 succeeds, and 0.10.0 -> 0.9.0 is rejected as downgrade
  jq '.mode = "semver_0_10_0" | .veri_calls = 0' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
    bash "$repo_root/scripts/sync_all.sh" veri "0.10.0" | grep -Fq "Synced veri -> v0.10.0"
  jq -e '.version == "0.10.0"' "$sync_out/bucket/veri.json" >/dev/null

  jq '.mode = "semver_0_9_0" | .veri_calls = 0' "$sync_state" > "$sync_state.tmp" && mv "$sync_state.tmp" "$sync_state"
  if SYNC_GITHUB_API_URL="$sync_mock_url" SYNC_RELEASE_BASE_URL="$sync_mock_url" SYNC_OUTPUT_DIR="$sync_out" \
      bash "$repo_root/scripts/sync_all.sh" veri >/dev/null 2>&1; then
    echo "Expected sync_all.sh to reject numeric SemVer downgrade from 0.10.0 to 0.9.0" >&2
    exit 1
  fi
fi
