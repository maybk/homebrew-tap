# Package Tap & Bucket

桌面端与命令行应用的官方包分发仓库，统一维护 Homebrew Tap（macOS / Linux）、Scoop Bucket（Windows）、WinGet 清单与 npm CLI 包。

**简体中文** · **[English](./README.en.md)** &nbsp;|&nbsp; **[维护指南](./docs/guide/maintenance.md)**

## 可用软件

| 软件 | Homebrew | Scoop | WinGet | npm | 简介 |
| :--- | :---: | :---: | :---: | :---: | :--- |
| [TunnelKit](https://github.com/maybk/tunnelkit) | Cask | ✓ | ✓ | — | 简洁轻量的跨平台 Fortinet SSL-VPN 桌面与菜单栏客户端 |
| [veri](https://github.com/maybk/veri) | Formula | ✓ | ✓ | ✓ | 面向 AI Agent 和开发者的多源联网检索与网页 Markdown 提取工具 |

## 安装与升级

### Homebrew（macOS / Linux）

```bash
# 命令行工具（Formula）
brew install maybk/tap/<formula>
brew upgrade maybk/tap/<formula>

# 桌面应用（Cask）
brew install --cask maybk/tap/<cask>
brew upgrade --cask maybk/tap/<cask>
```

### Scoop（Windows）

```powershell
scoop bucket add maybk https://github.com/maybk/homebrew-tap
scoop install maybk/<app>
scoop update <app>
```

### WinGet（Windows）

```powershell
winget install maybk.<App>
winget upgrade maybk.<App>
```

### npm（macOS / Linux / Windows）

```bash
npm install -g @maybk/<cli>
npm install -g @maybk/<cli>@latest

# 或免全局安装直接运行
npx -y @maybk/<cli> --help
```

## 维护与文档

同步架构、新应用接入流程、最小权限凭据配置与手动触发说明请参阅[维护指南](./docs/guide/maintenance.md)。
