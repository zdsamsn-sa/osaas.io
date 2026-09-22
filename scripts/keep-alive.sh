#!/usr/bin/env bash
# OSaaS My Apps Keep-Alive
# 目标：找到 Suspended 的 Resume → 执行 → 等到 Running / URL 可访问

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

# 控制台 Suspended 的绿色 Resume ≈ 把副本从 0 拉回 1
do_resume() {
  local name="$1"
  log "  → Resume: set-instance-replicas eyevinn-web-runner $name 1"
  if npx -y @osaas/cli set-instance-replicas eyevinn-web-runner "$name" 1 2>&1 | tee -a "$REPORT_FILE"; then
    log "  set-instance-replicas 已发送"
  else
    log "  ⚠ set-instance-replicas 失败（可能 token 耗尽或权限不足）"
  fi
  # 再尝试 restart 作为兜底
  log "  → 兜底 restart eyevinn-web-runner $name"
  npx -y @osaas/cli restart eyevinn-web-runner "$name" 2>&1 | tee -a "$REPORT_FILE" || true
}

wait_healthy() {
  local url="$1"
  local name="$2"
  local max_attempts=30   # 约 5 分钟（Resume 后起 pod 约 10–30s，token 恢复可能更久）
  local i
  for i in $(seq 1 "$max_attempts"); do
    sleep 10
    if is_healthy "$url"; then
      log "  ✓ [$i/$max_attempts] $name 已 Running / 可访问"
      return 0
    fi
    log "  [$i/$max_attempts] 等待 Running..."
  done
  log "  ✗ 等待超时，仍未 Running"
  return 1
}

shot_app_page() {
  local url="$1"
  local out="$2"
  export SHOT_URL="$url" SHOT_OUT="$out"
  node <<'NODE'
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
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

tg_send_text() {
  local text="$1"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 0
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

tg_send_photo() {
  local photo="$1" caption="$2"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 0
  [ -f "$photo" ] && [ -s "$photo" ] || return 0
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
    -F chat_id="${TELEGRAM_CHAT_ID}" \
    -F photo="@${photo}" \
    -F caption="${caption}" >/dev/null 2>&1 || true
}

# ---------- main ----------

log ""
log "=== 1. List My Apps ==="
MYAPPS_RAW=$(parse_myapps)
log "$MYAPPS_RAW"

# 即使 myapp list 为空，仍尝试对已知实例名做 Resume（Suspended 时 list 可能为空）
# 可从环境变量指定，默认 zdsa
APP_NAMES="${OSAAS_APP_NAMES:-zdsa}"

if [ -z "$MYAPPS_RAW" ]; then
  log "myapp list 为空（可能全部 Suspended），将按预设名称尝试 Resume: $APP_NAMES"
fi

UTC_NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# 收集要处理的 name + url
declare -A APP_URLS
while IFS= read -r line; do
  if ! echo "$line" | grep -qE 'https?://'; then continue; fi
  n=$(echo "$line" | sed -E 's/^[[:space:]]*([a-zA-Z0-9_-]+).*/\1/')
  u=$(echo "$line" | grep -oE 'https?://[^[:space:]]+' | head -1 | sed 's/[.,;:)]$//')
  [ -n "$n" ] && [ -n "$u" ] && APP_URLS["$n"]="$u"
done <<< "$MYAPPS_RAW"

# 确保预设名称也在列表里（Suspended 时可能没有 URL）
for n in $APP_NAMES; do
  if [ -z "${APP_URLS[$n]:-}" ]; then
    # 常见公开域名形态；你的实例是 d5a4f3bcdd.apps.osaas.io
    APP_URLS["$n"]="${OSAAS_APP_URL:-https://d5a4f3bcdd.apps.osaas.io}"
  fi
done

log ""
log "=== 2. 检查 / Resume / 等待 Running ==="

for name in "${!APP_URLS[@]}"; do
  url="${APP_URLS[$name]}"
  log ""
  log "--- App: $name ---"
  log "  URL: $url"

  if is_healthy "$url"; then
    log "  ✓ 已 Running → 跳过 Resume"
    ACTION="无需启动（已在运行）"
    STATUS="Running / Online"
    CONCLUSION="应用在线，跳过 Resume"
  else
    log "  → 不可访问（可能 Suspended），执行 Resume..."
    do_resume "$name"
    if wait_healthy "$url" "$name"; then
      ACTION="已点击 Resume（set replicas=1 + restart），服务器已 Online"
      STATUS="Running / Online"
      CONCLUSION="Resume 成功，应用已恢复"
    else
      ACTION="已尝试 Resume，仍未恢复"
      STATUS="Suspended / Unhealthy"
      CONCLUSION="可能因免费额度 token 耗尽无法 Resume。请升级计划或等额度恢复后重试。"
    fi
  fi

  # 应用页截图
  app_shot="${SCREENSHOT_DIR}/${name}-app.png"
  if shot_app_page "$url" "$app_shot" 2>&1 | tee -a "$REPORT_FILE" | grep -q app_shot_ok; then
    log "  ✓ 应用页截图成功"
    tg_send_photo "$app_shot" "应用页面 ${name}
${url}"
  else
    log "  ⚠ 应用页截图失败（未 Running 时常见）"
  fi

  # SkyMC 风格报告
  REPORT_MSG="✅ OSaaS 保活已执行
应用: ${name}
当前状态: ${STATUS}
启动操作: ${ACTION}
应用地址: ${url}
执行时间: ${UTC_NOW}
结论: ${CONCLUSION}"

  log ""
  log "$REPORT_MSG"
  tg_send_text "$REPORT_MSG"
done

log ""
log "=== 3. 最终 My Apps 列表 ==="
parse_myapps | tee -a "$REPORT_FILE" || true

log ""
log "========================================"
log " Keep-Alive finished"
log "========================================"
