#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ci_workflow="$repo_root/.github/workflows/ci.yml"
sync_workflow="$repo_root/.github/workflows/sync.yml"
reconcile_workflow="$repo_root/.github/workflows/reconcile.yml"
dependabot_config="$repo_root/.github/dependabot.yml"

extract_job() {
  local file="$1"
  local job="$2"
  awk -v target="  ${job}:" '
    $0 == target { flag = 1; next }
    flag && /^  [a-zA-Z0-9_-]+:/ { exit }
    flag { print }
  ' "$file"
}

# 1. All workflows and Dependabot config parse as valid YAML.
if command -v ruby >/dev/null 2>&1; then
  ruby -rpsych -e '
    ARGV.each do |path|
      doc = Psych.safe_load_file(path)
      raise "Invalid YAML root in #{path}" unless doc.is_a?(Hash)
    end
  ' "$ci_workflow" "$sync_workflow" "$reconcile_workflow" "$dependabot_config"
fi

# 2. All workflows declare top-level permissions and pin third-party actions to full 40-char commit SHAs.
for wf in "$ci_workflow" "$sync_workflow" "$reconcile_workflow"; do
  test -s "$wf"
  grep -Eq '^permissions:' "$wf"
  while IFS= read -r line; do
    ref="${line#*uses: }"
    ref="${ref%%#*}"
    ref="$(printf '%s' "$ref" | tr -d '[:space:]')"
    if [[ "$ref" == ./* ]]; then
      continue
    fi
    if [[ ! "$ref" =~ ^[^@]+@[0-9a-f]{40}$ ]]; then
      echo "Unpinned GitHub Action in $wf: $line" >&2
      exit 1
    fi
  done < <(grep -E '^[[:space:]-]*uses:[[:space:]]+' "$wf")
done

# 3. Shared core actions stay pinned to one consistent commit SHA across workflows.
for shared_action in checkout setup-node; do
  pin_count="$(
    grep -hE "uses: actions/$shared_action@[0-9a-f]{40}" \
      "$ci_workflow" "$sync_workflow" "$reconcile_workflow" |
      sed -E "s/.*actions\/$shared_action@([0-9a-f]{40}).*/\1/" |
      sort -u |
      wc -l |
      tr -d '[:space:]'
  )"
  if [ "$pin_count" -ne 1 ]; then
    echo "Workflows must pin a single consistent actions/$shared_action commit SHA" >&2
    exit 1
  fi
done

# 4. ci.yml uses read-only permissions, disables persisted git credentials, and runs workflow & sync tests.
if ! grep -Fq 'contents: read' "$ci_workflow" || grep -Fq 'contents: write' "$ci_workflow"; then
  echo "ci.yml must use read-only repository permissions" >&2
  exit 1
fi
grep -Fq 'persist-credentials: false' "$ci_workflow"
grep -Fq 'bash scripts/test_workflow_config.sh' "$ci_workflow"
grep -Fq 'bash scripts/test_sync.sh' "$ci_workflow"

# 5. sync.yml is purely event-driven (workflow_dispatch + workflow_call), never scheduled or repository_dispatch.
grep -Fq 'workflow_dispatch:' "$sync_workflow"
grep -Fq 'workflow_call:' "$sync_workflow"
grep -Fq 'expected_version:' "$sync_workflow"
if grep -Eq '^[[:space:]]*schedule:' "$sync_workflow"; then
  echo "sync.yml must not declare on.schedule (keep schedules isolated in reconcile.yml to prevent 60-day inactivity disabling)" >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*repository_dispatch:' "$sync_workflow"; then
  echo "sync.yml must not declare repository_dispatch (use least-privilege workflow_dispatch requiring only Actions: write)" >&2
  exit 1
fi
if grep -Eq '^concurrency:' "$sync_workflow"; then
  echo "sync.yml must use job-level concurrency (not workflow-level) to avoid workflow_call concurrency deadlocks" >&2
  exit 1
fi

# 6. sync.yml enforces job-level least-privilege isolation and FIFO queuing.
manifests_job="$(extract_job "$sync_workflow" manifests)"
winget_job="$(extract_job "$sync_workflow" winget)"
npm_job="$(extract_job "$sync_workflow" npm)"

for required in \
  'group: sync-manifests' \
  'cancel-in-progress: false' \
  'queue: max' \
  'contents: write' \
  'fetch-depth: 0' \
  'bash scripts/sync_all.sh "$TARGET_APP" "$EXPECTED_VERSION"' \
  'bash scripts/test_sync.sh' \
  'brew style' \
  'git pull --rebase origin main'; do
  if ! grep -Fq -- "$required" <<<"$manifests_job"; then
    echo "sync.yml manifests job missing required contract: $required" >&2
    exit 1
  fi
done
if grep -Eq 'WINGET_GITHUB_TOKEN|NPM_TOKEN' <<<"$manifests_job"; then
  echo "sync.yml manifests job must not have access to external publishing secrets" >&2
  exit 1
fi

for required in \
  'needs: manifests' \
  "if: needs.manifests.outputs.has_winget == 'true'" \
  'group: sync-winget' \
  'cancel-in-progress: false' \
  'queue: max' \
  'contents: read' \
  'ref: ${{ needs.manifests.outputs.head_sha }}' \
  'persist-credentials: false' \
  'WINGET_GITHUB_TOKEN: ${{ secrets.WINGET_GITHUB_TOKEN }}'; do
  if ! grep -Fq -- "$required" <<<"$winget_job"; then
    echo "sync.yml winget job missing required contract: $required" >&2
    exit 1
  fi
done
if grep -Eq 'contents: write|NPM_TOKEN' <<<"$winget_job"; then
  echo "sync.yml winget job must stay read-only and isolated from NPM_TOKEN" >&2
  exit 1
fi

for required in \
  'needs: manifests' \
  "if: needs.manifests.outputs.has_npm == 'true'" \
  'group: sync-npm' \
  'cancel-in-progress: false' \
  'queue: max' \
  'contents: read' \
  'ref: ${{ needs.manifests.outputs.head_sha }}' \
  'persist-credentials: false' \
  'NPM_TOKEN: ${{ secrets.NPM_TOKEN }}'; do
  if ! grep -Fq -- "$required" <<<"$npm_job"; then
    echo "sync.yml npm job missing required contract: $required" >&2
    exit 1
  fi
done
if grep -Eq 'contents: write|WINGET_GITHUB_TOKEN' <<<"$npm_job"; then
  echo "sync.yml npm job must stay read-only and isolated from WINGET_GITHUB_TOKEN" >&2
  exit 1
fi

# 7. reconcile.yml is an isolated daily off-peak wrapper delegating explicitly to sync.yml via workflow_call.
grep -Fq 'schedule:' "$reconcile_workflow"
grep -Fq "cron: '23 3 * * *'" "$reconcile_workflow"
grep -Fq 'group: sync-reconcile' "$reconcile_workflow"
grep -Fq 'uses: ./.github/workflows/sync.yml' "$reconcile_workflow"
grep -Fq 'WINGET_GITHUB_TOKEN: ${{ secrets.WINGET_GITHUB_TOKEN }}' "$reconcile_workflow"
grep -Fq 'NPM_TOKEN: ${{ secrets.NPM_TOKEN }}' "$reconcile_workflow"
if grep -Fq 'secrets: inherit' "$reconcile_workflow"; then
  echo "reconcile.yml must forward publishing secrets explicitly instead of secrets: inherit" >&2
  exit 1
fi
if grep -Eq "cron: '(\*/|0 )" "$reconcile_workflow"; then
  echo "reconcile.yml cron must run at a non-zero off-peak minute" >&2
  exit 1
fi

# 8. Dependabot keeps pinned GitHub Actions SHAs updated weekly in a grouped PR.
test -s "$dependabot_config"
grep -Fq 'package-ecosystem: "github-actions"' "$dependabot_config"
grep -Fq 'interval: "weekly"' "$dependabot_config"
grep -Fq 'groups:' "$dependabot_config"
grep -Fq 'github-actions:' "$dependabot_config"
