# maybk Package Tap & Bucket

Official Homebrew Tap (macOS / Linux), Scoop Bucket (Windows), WinGet manifests, and npm CLI publisher for [maybk](https://github.com/maybk) desktop and CLI applications.

## Usage

### Homebrew (macOS / Linux)

```bash
# CLI tools (Formula)
brew install maybk/tap/<formula>
brew upgrade maybk/tap/<formula>

# Desktop apps (Cask)
brew install --cask maybk/tap/<cask>
brew upgrade --cask maybk/tap/<cask>
```

### Scoop (Windows)

```powershell
scoop bucket add maybk https://github.com/maybk/homebrew-tap
scoop install maybk/<app>

# Upgrade installed packages
scoop update <app>
```

### WinGet (Windows)

```powershell
winget install maybk.<App>
```

### npm (macOS / Linux / Windows)

```bash
npm install -g @maybk/<cli>
npm install -g @maybk/<cli>@latest

# Or run without global install
npx -y @maybk/<cli> --help
```

## Available Packages

| Package | Homebrew (`macOS` / `Linux`) | Scoop (`Windows`) | WinGet (`Windows`) | npm (`CLI`) | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| [TunnelKit](https://github.com/maybk/tunnelkit) | `brew install --cask maybk/tap/tunnelkit` | `scoop install maybk/tunnelkit` | `winget install maybk.TunnelKit` | — | Fortinet SSL-VPN desktop and menu bar client |
| [veri](https://github.com/maybk/veri) | `brew install maybk/tap/veri` | `scoop install maybk/veri` | `winget install maybk.Veri` | `npm install -g @maybk/veri` | Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill) |

## Adding a New Application

1. Append an entry to [`apps.json`](./apps.json): omit `"type"` (or set `"cask"`) for desktop apps, set `"type": "formula"` for CLI binaries, and optionally add `"npm": { "package": "@maybk/<cli>", "bin": "<cli>" }` to enable npm publishing.
2. Run `bash scripts/sync_all.sh <token>` (or trigger the **Sync Releases** GitHub Action) and verify with `bash scripts/test_sync.sh`.

## Automated Synchronization

- **Homebrew & Scoop**: `.github/workflows/sync.yml` polls the latest stable GitHub Releases every 30 minutes (and accepts `workflow_dispatch` / `repository_dispatch`) to update `Formula/`, `Casks/`, `bucket/`, and `winget/`.
- **WinGet (`microsoft/winget-pkgs`)**: Configure a repository Actions secret named `WINGET_GITHUB_TOKEN` (a GitHub Classic PAT with `public_repo` scope). On each sync run, `scripts/submit_winget_prs.sh` fast-forwards the `<owner>/winget-pkgs` fork to upstream `master`, cleans up merged branches, and opens `New package` / `Update` pull requests to `microsoft/winget-pkgs` idempotently.
- **npm (`registry.npmjs.org`)**: Configure a repository Actions secret named `NPM_TOKEN` (a Granular Access Token with write access to `@maybk/*` and CI 2FA bypass enabled). On each sync run, `scripts/publish_npm.sh` verifies all 6 release archives against the synced manifest SHA-256 digests and idempotently publishes the platform `optionalDependencies` packages followed by the main wrapper package.
