#!/usr/bin/env bash
# OSaaS My Apps Keep-Alive
# 1) 应用公开页截图 (https://xxx.apps.osaas.io)
# 2) My Apps 控制台截图 (dashboard，尽量用 PAT 注入)
# 3) Telegram：两张图 + SkyMC 风格文字报告

set -euo pipefail

echo "========================================"
echo " OSaaS My Apps Keep-Alive"
echo " Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================"

if [ -z "${OSC_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: OSC_ACCESS_TOKEN is not set"
  exit 1
fi

REPORT_FILE=$(mktemp)
SCREENSHOT_DIR=$(mktemp -d)
trap 'rm -f "$REPORT_FILE"; rm -rf "$SCREENSHOT_DIR"' EXIT

log() {
  echo "$@" | tee -a "$REPORT_FILE"
}

is_healthy() {
  local url="$1"
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 -L "$url" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] || [ "$code" = "404" ]; then
    return 0
  fi
  return 1
}

parse_myapps() {
  npx -y @osaas/cli myapp list 2>/dev/null || true
}

do_restart() {
  local name="$1"
  log "  → 执行 restart: eyevinn-web-runner / $name"
  if npx -y @osaas/cli restart eyevinn-web-runner "$name" 2>&1 | tee -a "$REPORT_FILE"; then
    log "  Restart 命令已发送"
    return 0
  fi
  log "  ⚠ restart 失败"
  return 1
}

wait_healthy() {
  local url="$1"
  local name="$2"
  local max_attempts=24
  local i
  for i in $(seq 1 "$max_attempts"); do
    sleep 10
    if is_healthy "$url"; then
      log "  ✓ [$i/$max_attempts] $name 已恢复可访问 (Running)"
      return 0
    fi
    log "  [$i/$max_attempts] 仍不可访问，继续等待..."
  done
  log "  ✗ 等待超时，$name 仍未恢复"
  return 1
}

# 截图应用公开页
shot_app_page() {
  local url="$1"
  local out="$2"
  export SHOT_URL="$url"
  export SHOT_OUT="$out"
  node <<'NODE'
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  try {
    await page.goto(process.env.SHOT_URL, { waitUntil: 'networkidle', timeout: 45000 });
    await page.waitForTimeout(2500);
    await page.screenshot({ path: process.env.SHOT_OUT, fullPage: true, type: 'png' });
    console.log('app_shot_ok');
  } catch (e) {
    console.error('app_shot_fail:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
NODE
}

# 截图 My Apps 控制台（注入 PAT，尽量拿到和浏览器里一样的页面）
shot_dashboard() {
  local out="$1"
  export SHOT_OUT="$out"
  export OSC_ACCESS_TOKEN
  node <<'NODE'
const { chromium } = require('playwright');
(async () => {
  const token = process.env.OSC_ACCESS_TOKEN;
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await context.newPage();

  // 给所有请求加上 PAT，部分前端 API 会认
  await page.route('**/*', async (route) => {
    const headers = {
      ...route.request().headers(),
      'authorization': `Bearer ${token}`,
      'x-pat-jwt': `Bearer ${token}`,
    };
    try {
      await route.continue({ headers });
    } catch {
      await route.continue();
    }
  });

  try {
    // 先写 localStorage，部分 SPA 会读 token
    await page.goto('https://app.osaas.io/', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.evaluate((t) => {
      try {
        localStorage.setItem('osc_access_token', t);
        localStorage.setItem('access_token', t);
        localStorage.setItem('token', t);
        localStorage.setItem('pat', t);
      } catch (_) {}
    }, token);

    await page.goto('https://app.osaas.io/dashboard/my-apps', {
      waitUntil: 'networkidle',
      timeout: 45000,
    });
    await page.waitForTimeout(4000);

    // 若被踢到登录页，页面上通常有 "Continue with" / magic link 文案
    const bodyText = await page.locator('body').innerText().catch(() => '');
    if (/Continue with|magic link|Sign in|登录|one-time/i.test(bodyText) && !/My Apps|Running|nodejs/i.test(bodyText)) {
      console.error('dashboard_shot_fail: still on login page (PAT cannot establish web session)');
      process.exitCode = 1;
    } else {
      await page.screenshot({ path: process.env.SHOT_OUT, fullPage: true, type: 'png' });
      console.log('dashboard_shot_ok');
    }
  } catch (e) {
    console.error('dashboard_shot_fail:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
NODE
}

tg_send_text() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    return 0
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    >/dev/null 2>&1 || log "⚠ Telegram 文字发送失败"
}

tg_send_photo() {
  local photo="$1"
  local caption="$2"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    return 0
  fi
  if [ ! -f "$photo" ] || [ ! -s "$photo" ]; then
    return 0
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
    -F chat_id="${TELEGRAM_CHAT_ID}" \
    -F photo="@${photo}" \
    -F caption="${caption}" \
    >/dev/null 2>&1 || log "⚠ Telegram 图片发送失败"
}

# ---------- main ----------

log ""
log "=== 1. List My Apps ==="
MYAPPS_RAW=$(parse_myapps)
log "$MYAPPS_RAW"

if [ -z "$MYAPPS_RAW" ]; then
  log "未找到任何 My Apps，结束"
  tg_send_text "OSaaS 保活
未找到任何 My Apps"
  exit 0
fi

log ""
log "=== 2. 检查并按需 Resume ==="

FINAL_REPORT=""
UTC_NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

while IFS= read -r line; do
  if ! echo "$line" | grep -qE 'https?://'; then
    continue
  fi

  name=$(echo "$line" | sed -E 's/^[[:space:]]*([a-zA-Z0-9_-]+).*/\1/')
  url=$(echo "$line" | grep -oE 'https?://[^[:space:]]+' | head -1 | sed 's/[.,;:)]$//')
  type=$(echo "$line" | sed -nE 's/.*\(([^)]+)\).*/\1/p' || echo "app")

  if [ -z "$name" ] || [ -z "$url" ]; then
    continue
  fi

  log ""
  log "--- App: $name ---"
  log "  URL: $url"

  ACTION_TEXT=""
  STATUS_TEXT=""
  CONCLUSION=""

  if is_healthy "$url"; then
    log "  ✓ 已在 Running 且可访问 → 跳过"
    ACTION_TEXT="无需启动（已在运行）"
    STATUS_TEXT="Running / Online"
    CONCLUSION="应用在线，跳过 Resume"
    RESULT="SKIP"
  else
    log "  → 不可访问，执行 Resume (restart)..."
    if do_restart "$name"; then
      if wait_healthy "$url" "$name"; then
        ACTION_TEXT="已点击启动（restart），服务器已 Online"
        STATUS_TEXT="Running / Online"
        CONCLUSION="Resume 成功，应用已恢复"
        RESULT="RESUMED"
      else
        ACTION_TEXT="已执行 restart，但仍未恢复"
        STATUS_TEXT="Unhealthy"
        CONCLUSION="Resume 后仍不可访问，请检查控制台"
        RESULT="FAILED"
      fi
    else
      ACTION_TEXT="restart 命令失败"
      STATUS_TEXT="Unknown"
      CONCLUSION="请检查 Token 权限或实例名称"
      RESULT="FAILED"
    fi
  fi

  log "  结果: $RESULT"

  # --- 截图 1：应用真实页面 ---
  app_shot="${SCREENSHOT_DIR}/${name}-app.png"
  if shot_app_page "$url" "$app_shot" 2>&1 | tee -a "$REPORT_FILE" | grep -q app_shot_ok; then
    log "  ✓ 应用页截图成功"
    tg_send_photo "$app_shot" "应用页面 ${name}
${url}"
  else
    log "  ⚠ 应用页截图失败"
  fi

  # --- 截图 2：My Apps 控制台（尽量真实）---
  dash_shot="${SCREENSHOT_DIR}/${name}-dashboard.png"
  if shot_dashboard "$dash_shot" 2>&1 | tee -a "$REPORT_FILE" | grep -q dashboard_shot_ok; then
    log "  ✓ My Apps 控制台截图成功"
    tg_send_photo "$dash_shot" "My Apps 控制台
app.osaas.io/dashboard/my-apps"
  else
    log "  ⚠ 控制台截图失败（PAT 无法建立网页登录态时会出现，属正常）"
  fi

  # --- SkyMC 风格文字报告 ---
  REPORT_MSG="✅ OSaaS 保活已执行
应用: ${name} (${type})
当前状态: ${STATUS_TEXT}
启动操作: ${ACTION_TEXT}
应用地址: ${url}
执行时间: ${UTC_NOW}
结论: ${CONCLUSION}"

  log ""
  log "$REPORT_MSG"
  tg_send_text "$REPORT_MSG"

  FINAL_REPORT="${FINAL_REPORT}
${REPORT_MSG}
"
done <<< "$MYAPPS_RAW"

log ""
log "=== 3. 最终 My Apps 列表 ==="
parse_myapps | tee -a "$REPORT_FILE" || true

log ""
log "========================================"
log " Keep-Alive finished"
log "========================================"
