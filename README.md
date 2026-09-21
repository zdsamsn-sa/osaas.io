# OSaaS My Apps Keep-Alive

每 8 小时自动检查 https://app.osaas.io/dashboard/my-apps 中的应用。  
如果未运行则执行 Resume（对应 CLI 的 `restart`），并等待变为 Running。

## 登录与认证说明

OSaaS（app.osaas.io）支持以下登录方式：

| 方式 | 说明 |
|------|------|
| Email 魔法链接 | 输入邮箱，收到一次性登录链接（无密码） |
| GitHub OAuth | 用 GitHub 账号登录 |
| Google OAuth | 用 Google 账号登录 |
| Apple OAuth | 用 Apple ID 登录 |
| Passkey | 通行密钥 |

**重要**：每种登录方式会创建独立账号，即使邮箱相同也不会自动关联。

**自动化 / GitHub Actions 必须使用 Personal Access Token（PAT）**，官方完全支持。

### 获取 PAT

1. 登录 https://app.osaas.io
2. 左侧 **Settings** → **API** 标签
3. 复制 Personal Access Token

## 快速使用（GitHub）

1. 把本压缩包内容解压到你的 GitHub 仓库根目录（或新建仓库）
2. 仓库 → **Settings** → **Secrets and variables** → **Actions**  
   新建 Secret：
   - Name: `OSC_ACCESS_TOKEN`
   - Value: 你的 PAT
3. 推送代码后，到 **Actions** 页面手动触发一次 “OSaaS My Apps Keep-Alive” 进行测试
4. 之后会按 cron 每 8 小时自动运行

## 本地测试

```bash
export OSC_ACCESS_TOKEN="你的PAT"
chmod +x scripts/keep-alive.sh
./scripts/keep-alive.sh
```

需要先安装 Node.js 18+，脚本会自动通过 npx 使用 @osaas/cli。

## 文件说明

```
osaas-keepalive/
├── .github/
│   └── workflows/
│       └── osaas-keep-alive.yml   # GitHub Actions 定时任务
├── scripts/
│   └── keep-alive.sh              # 核心检查与 Resume 脚本
└── README.md
```

## 工作原理

- UI 上的 “Resume” 对应 CLI 命令：`osc restart <serviceId> <name>`
- 脚本会检查常见 runner：
  - eyevinn-web-runner
  - eyevinn-python-runner
  - eyevinn-golang-runner
  - eyevinn-dotnet-runner
  - eyevinn-wasm-runner
- 已处于 running / active / ready / healthy 状态的应用会跳过
- 未运行的会执行 restart，并轮询等待变为 running（最多约 3 分钟）

## 手动触发

在 GitHub 仓库的 **Actions** 标签页，选择 “OSaaS My Apps Keep-Alive”，点击 **Run workflow**。

## 注意事项

- 请妥善保管 PAT，不要提交到代码仓库
- 如需只监控某一个固定应用，可修改 `scripts/keep-alive.sh` 中的逻辑
- 首次运行建议先本地测试，确认能正确列出你的实例
