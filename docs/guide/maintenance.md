# 维护指南

本文档说明本仓库的自动化同步架构、最小权限凭据配置、新应用接入流程与日常运维命令。

## 架构与自动化

本仓库采用**事件唤醒 + 中枢自主拉取**模式：上游项目发布经校验的 GitHub Release 后，仅向本仓库发送最小权限的 `workflow_dispatch` 信号；本仓库自主拉取上游 Release 元数据与 `SHA256SUMS.txt`、校验完整性、更新清单并分发至各下游包管理器。

### 自动化文件

| 文件 | 触发方式 | 职责 |
| :--- | :--- | :--- |
| [`.github/workflows/sync.yml`](../../.github/workflows/sync.yml) | `workflow_dispatch`、`workflow_call` | 事件驱动同步核心；不含 `schedule`（免疫 GitHub 公开仓库 60 天定时停用）与 `repository_dispatch`（上游无需 `Contents: write`） |
| [`.github/workflows/reconcile.yml`](../../.github/workflows/reconcile.yml) | 每日 `23 3 * * *`（UTC） | 独立错峰兜底，通过 `workflow_call` 复用 `sync.yml`，用于补齐漏触发、跟进延后 WinGet 更新及清理已合并 WinGet 分支 |
| [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) | `push`（`main`）、`pull_request` | 只读门禁：运行工作流契约测试、离线同步测试、`brew style` 与 Scoop / WinGet JSON Schema 校验 |
| [`.github/dependabot.yml`](../../.github/dependabot.yml) | 每周 | 分组更新工作流中固定的 40 位 GitHub Actions Commit SHA |

### 作业与密钥隔离（`sync.yml`）

三个变更阶段各自运行在独立的 FIFO 并发队列（`queue: max`、`cancel-in-progress: false`）中，权限与密钥严格分离：

| Job | `GITHUB_TOKEN` | 外部密钥 | 职责与隔离策略 |
| :--- | :--- | :--- | :--- |
| `manifests` | `contents: write` | 无 | 执行 [`scripts/sync_all.sh`](../../scripts/sync_all.sh)、[`scripts/test_sync.sh`](../../scripts/test_sync.sh) 与 `brew style`，通过 `git pull --rebase` 重试推送至 `main` |
| `winget` | `contents: read` | `WINGET_GITHUB_TOKEN` | `persist-credentials: false`；目标应用无 `winget_id` 时自动跳过；同步 fork 并幂等提交 `microsoft/winget-pkgs` PR |
| `npm` | `contents: read` | `NPM_TOKEN` | `persist-credentials: false`；目标应用无 `npm` 配置时自动跳过；逐一核对 6 平台归档 SHA-256 后独立发包，不受 WinGet 波动影响 |

### 一致性与安全约束

- **发布传播退避轮询**：携带 `expected_version` 与 `app` 时，[`scripts/sync_all.sh`](../../scripts/sync_all.sh) 对 GitHub Releases API 执行有界退避轮询（对 `404` / `429` / `5xx` 重试直到目标版本及校验和资产就绪，对 `401` / `403` 立即快速失败）。
- **防降级与地址锁定**：严格按数字 SemVer 拒绝静默降级，并强制校验 `SHA256SUMS.txt` 下载地址前缀为 `https://github.com/<repo>/releases/download/<tag>/`。

## 凭据与密钥

### 上游唤醒凭据（配置在各上游仓库）

上游仓库仅需具备触发本仓库 `workflow_dispatch` 的 **`Actions: write`** 权限，**严禁**授予 `Contents: write`：

- **推荐 —— 私有 GitHub App（无年度过期轮换）**：
  - 在账号下创建一个仅限本账号使用的 GitHub App，关闭 Webhook（取消勾选 `Active`）。
  - **仅安装到本仓库**，权限**仅开启 `Repository permissions -> Actions: Read and write`**（`Metadata: Read-only` 为自动必选，其余全部保持 `No access`）。
  - 在各上游仓库配置变量 `TAP_DISPATCH_APP_CLIENT_ID` 与密钥 `TAP_DISPATCH_APP_PRIVATE_KEY`（`.pem` 私钥）。
  - 建议将 `.pem` 备份至密码管理器；GitHub App 支持同时存在多把有效私钥，日后为新仓库生成新私钥不会导致已有仓库失效。
- **轻量替代 —— 单一 Fine-grained PAT**：
  - 创建仅授权本仓库、仅勾选 `Actions: Read and write` 的 Fine-grained PAT，配置为上游仓库密钥 `TAP_DISPATCH_TOKEN`。

### 中枢发布密钥（仅配置在本仓库）

- **`WINGET_GITHUB_TOKEN`**：带 `public_repo` 作用域的 GitHub Classic PAT，供 [`scripts/submit_winget_prs.sh`](../../scripts/submit_winget_prs.sh) 同步 `<owner>/winget-pkgs` fork 并向 `microsoft/winget-pkgs` 提交 PR。
- **`NPM_TOKEN`**：对 `@maybk/*` 具写入权限且开启 CI 2FA 绕过的 npm Granular Access Token，供 [`scripts/publish_npm.sh`](../../scripts/publish_npm.sh) 发布 npm 包。

## 接入新应用

所有上游仓库复用同一个 GitHub App，无需新建 App 或修改本仓库的安装授权：

1. **在 [`apps.json`](../../apps.json) 注册元数据**：桌面应用省略 `"type"`（或设为 `"cask"`），命令行二进制设为 `"type": "formula"`，按需补充 `"winget_id"` 与 `"npm"`。
2. **在新的上游仓库写入唤醒凭据**（复用[凭据与密钥](#凭据与密钥)中的共享 App）：
   ```bash
   gh variable set TAP_DISPATCH_APP_CLIENT_ID -R maybk/<repo> --body "<APP_CLIENT_ID>"
   gh secret set TAP_DISPATCH_APP_PRIVATE_KEY -R maybk/<repo> < "<path-to-private-key.pem>"
   ```
3. **接入 `notify-tap` 发布唤醒**：将 `veri`（或 `tunnelkit`）`.github/workflows/release.yml` 中的 `notify-tap` Job 复制到新仓库，并将 `TAP_APP` 改为新应用的 `token`。即便暂未配置第 2 步凭据，正式发版仍可正常完成，每日 `reconcile.yml` 会自动兜底同步。
4. **本地同步校验并更新入口文档**：同步更新 [`README.md`](../../README.md) 与 [`README.en.md`](../../README.en.md) 的软件列表，并执行本地验证：
   ```bash
   bash scripts/sync_all.sh <token>
   bash scripts/test_workflow_config.sh && bash scripts/test_sync.sh
   ```

## 手动触发与本地校验

### `sync.yml` 输入参数

| 参数 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `app` | `string` | 空 | 指定单个应用 `token`；留空则同步 `apps.json` 中的全部应用 |
| `expected_version` | `string` | 空 | 配合 `app` 使用的目标版本号（`MAJOR.MINOR.PATCH`），用于等待刚发布的 Release 生效 |
| `force_winget_retry` | `boolean` | `false` | 即使同版本先前的 WinGet PR 曾被未合并关闭，也强制新建重试分支提交 |

### 远端手动触发

按需同步单个应用、全量同步或强制重试 WinGet PR：

```bash
gh workflow run sync.yml -R maybk/homebrew-tap --ref main -f app=veri
gh workflow run sync.yml -R maybk/homebrew-tap --ref main
gh workflow run sync.yml -R maybk/homebrew-tap --ref main -f app=tunnelkit -f force_winget_retry=true
```

### 本地回归校验

```bash
bash scripts/test_workflow_config.sh && bash scripts/test_sync.sh
```
