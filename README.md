# maybk Package Tap & Bucket

Official Homebrew Tap (macOS / Linux), Scoop Bucket (Windows), and WinGet manifests for [maybk](https://github.com/maybk) desktop and CLI applications.

## Usage

### Homebrew (macOS / Linux)

```bash
brew install --cask maybk/tap/<app>

# Upgrade installed packages
brew upgrade
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
| [TunnelKit](https://github.com/maybk/tunnelkit) | `brew install --cask maybk/tap/tunnelkit` | `scoop install maybk/tunnelkit` | `winget install maybk.TunnelKit` | Cross-platform Fortinet SSL-VPN desktop and menu bar client |

## Adding a New Application

1. Append the application entry to [`apps.json`](./apps.json).
2. Run `bash scripts/sync_all.sh <token>` or trigger the **Sync Releases** GitHub Action.
