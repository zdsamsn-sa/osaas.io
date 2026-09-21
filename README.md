# OSaaS My Apps Keep-Alive

每 8 小时检查 My Apps：

- **已是 Running 且 URL 可访问** → 直接跳过（与控制台绿点 Running 一致）
- **不可访问** → 执行 `restart`（对应 UI Resume），等待恢复到可访问
- 结果发送到 **Telegram**（文字 + 应用页面截图）

## 需要的 Secrets

GitHub 仓库 → **Settings → Secrets and variables → Actions**：

| Secret 名称 | 说明 |
|-------------|------|
| `OSC_ACCESS_TOKEN` | OSaaS API Token（Settings → API → Create New Token） |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token（@BotFather） |
| `TELEGRAM_CHAT_ID` | 接收消息的 Chat ID |

### 获取 OSC_ACCESS_TOKEN

1. https://app.osaas.io → **Settings → API**
2. 点 **+ Create New Token**
3. 复制 Token（只显示一次）

### 获取 Telegram

1. [@BotFather](https://t.me/BotFather) → `/newbot` → 得到 `TELEGRAM_BOT_TOKEN`
2. 私聊 Bot 或拉进群
3. 打开 `https://api.telegram.org/bot<TOKEN>/getUpdates`，找 `chat.id` 作为 `TELEGRAM_CHAT_ID`

## 本地测试

```bash
export OSC_ACCESS_TOKEN="你的token"
export TELEGRAM_BOT_TOKEN="可选"
export TELEGRAM_CHAT_ID="可选"

chmod +x scripts/keep-alive.sh
./scripts/keep-alive.sh
```

## 逻辑说明

1. `osc myapp list` 得到应用名和 URL（如 zdsa → https://d5a4f3bcdd.apps.osaas.io）
2. HTTP 探测 URL：可访问 → **跳过**（等同截图 Status=Running）
3. 不可访问 → `osc restart eyevinn-web-runner <name>`，轮询直到可访问
4. 截图应用公开页，连同结果发 Telegram

## 注意

- 免费计划应用可能休眠，定时 restart 可唤醒
- 截图是应用公开 URL，不是需登录的控制台
- 未配置 Telegram 时仍会 keep-alive，只是不发消息
