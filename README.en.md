# Package Tap & Bucket

Official package distribution hub for desktop and CLI applications, maintaining Homebrew Tap (macOS / Linux), Scoop Bucket (Windows), WinGet manifests, and npm CLI packages.

**[简体中文](./README.md)** · **English** &nbsp;|&nbsp; **[Maintenance Guide](./docs/guide/maintenance.md)**

## Available Packages

| Package | Homebrew | Scoop | WinGet | npm | Description |
| :--- | :---: | :---: | :---: | :---: | :--- |
| [TunnelKit](https://github.com/maybk/tunnelkit) | Cask | ✓ | ✓ | — | Fortinet SSL-VPN desktop and menu bar client |
| [veri](https://github.com/maybk/veri) | Formula | ✓ | ✓ | ✓ | Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill) |

## Installation & Upgrades

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
scoop update <app>
```

### WinGet (Windows)

```powershell
winget install maybk.<App>
winget upgrade maybk.<App>
```

### npm (macOS / Linux / Windows)

```bash
npm install -g @maybk/<cli>
npm install -g @maybk/<cli>@latest

# Or run without global install
npx -y @maybk/<cli> --help
```

## Maintenance

See the [Maintenance Guide](./docs/guide/maintenance.md) for sync architecture, onboarding new applications, least-privilege credentials, and manual runs.
