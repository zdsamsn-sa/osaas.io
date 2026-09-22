# OSaaS My Apps Keep-Alive

自动打开 [My Apps](https://app.osaas.io/dashboard/my-apps)，在 **Suspended Apps** 上点击绿色 **Resume**，并等待变为 Running。

每 8 小时运行一次（也可手动触发）。

## Secrets（仓库 Settings → Secrets → Actions）

| 名称 | 必填 | 说明 |
|------|------|------|
| `OSC_ACCESS_TOKEN` | 是 | Settings → API → Create Token |
| `OSC_SESSION_COOKIE` | **强烈建议** | 已登录浏览器的 Cookie，才能真正点到 Resume |
| `TELEGRAM_BOT_TOKEN` | 否 | Telegram Bot |
| `TELEGRAM_CHAT_ID` | 否 | 接收通知的 Chat ID |

### 如何获取 `OSC_SESSION_COOKIE`

1. 用 Chrome 登录 https://app.osaas.io  
2. 打开开发者工具 (F12) → **Application** → **Cookies** → `https://app.osaas.io`  
3. 复制全部 Cookie，拼成一行：`name1=value1; name2=value2; ...`  
4. 粘贴到 GitHub Secret `OSC_SESSION_COOKIE`  

Cookie 会过期，失效后重新复制一次。

## 逻辑

1. 探测应用 URL 是否可访问 → 可访问则跳过  
2. 否则用 Playwright 打开 `https://app.osaas.io/dashboard/my-apps`  
3. 找到 **Resume** 按钮并点击  
4. 等待页面出现 Running / URL 可访问  
5. 发 Telegram：控制台截图 + 应用页截图 + 文字报告  

## 注意：token 耗尽

若页面提示 *suspended due to token exhaustion*，平台会拒绝 Resume。  
需 **升级计划** 或 **等待额度恢复** 后，自动化才能成功。

## 可选变量（Settings → Variables）

- `OSAAS_APP_NAMES` 默认 `zdsa`  
- `OSAAS_APP_URL` 默认 `https://d5a4f3bcdd.apps.osaas.io`
