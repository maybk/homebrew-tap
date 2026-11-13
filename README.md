# maybk Package Tap & Bucket

Official Homebrew Tap (macOS / Linux), Scoop Bucket (Windows), and WinGet manifests for [maybk](https://github.com/maybk) desktop and CLI applications.

## Usage

### Homebrew (macOS / Linux)

```bash
brew install --cask maybk/tap/<app>

# Upgrade installed packages
brew upgrade --cask maybk/tap/<app>
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

## Available Packages

| Package | Homebrew (`macOS` / `Linux`) | Scoop (`Windows`) | WinGet (`Windows`) | Description |
| :--- | :--- | :--- | :--- | :--- |
| [TunnelKit](https://github.com/maybk/tunnelkit) | `brew install --cask maybk/tap/tunnelkit` | `scoop install maybk/tunnelkit` | `winget install maybk.TunnelKit` | Fortinet SSL-VPN desktop and menu bar client |

## Adding a New Application

1. Append the application entry to [`apps.json`](./apps.json).
2. Run `bash scripts/sync_all.sh <token>` (or trigger the **Sync Releases** GitHub Action) and verify with `bash scripts/test_sync.sh`.

## Automated Synchronization

- **Homebrew & Scoop**: `.github/workflows/sync.yml` polls the latest stable GitHub Releases every 30 minutes (and accepts `workflow_dispatch` / `repository_dispatch`) to update `Casks/`, `bucket/`, and `winget/`.
- **WinGet (`microsoft/winget-pkgs`)**: Configure a repository Actions secret named `WINGET_GITHUB_TOKEN` (a GitHub Classic PAT with `public_repo` scope). On each sync run, `scripts/submit_winget_prs.sh` fast-forwards the `<owner>/winget-pkgs` fork to upstream `master`, cleans up merged branches, and opens `New package` / `Update` pull requests to `microsoft/winget-pkgs` idempotently.
