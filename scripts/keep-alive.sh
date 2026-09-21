#!/usr/bin/env bash
# OSaaS My Apps Keep-Alive
# - 已 Running 且可访问 → 跳过
# - 不可访问 → restart，等待恢复
# - 结果发 Telegram（文字 + 应用页面截图）

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

# HTTP 健康检查：能连上即视为 Running（与控制台绿点一致）
is_healthy() {
  local url="$1"
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 -L "$url" 2>/dev/null || echo "000")
  # 2xx/3xx 健康；部分应用根路径 404 但仍在跑，也接受
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

take_screenshot() {
  local url="$1"
  local out="$2"
  npx -y playwright screenshot --wait-for-timeout=5000 "$url" "$out" 2>/dev/null || return 1
  [ -f "$out" ] && [ -s "$out" ]
}

tg_send_text() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "Telegram 未配置，跳过发送文字"
    return 0
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="HTML" \
    --data-urlencode "text=${text}" \
    >/dev/null || log "⚠ Telegram 文字发送失败"
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
    >/dev/null || log "⚠ Telegram 图片发送失败"
}

# ---------- main ----------

log ""
log "=== 1. List My Apps ==="
MYAPPS_RAW=$(parse_myapps)
log "$MYAPPS_RAW"

if [ -z "$MYAPPS_RAW" ]; then
  log "未找到任何 My Apps，结束"
  tg_send_text "OSaaS Keep-Alive: 未找到任何 My Apps"
  exit 0
fi

log ""
log "=== 2. 检查并按需 Resume ==="

while IFS= read -r line; do
  if ! echo "$line" | grep -qE 'https?://'; then
    continue
  fi

  name=$(echo "$line" | sed -E 's/^[[:space:]]*([a-zA-Z0-9_-]+).*/\1/')
  url=$(echo "$line" | grep -oE 'https?://[^[:space:]]+' | head -1)

  if [ -z "$name" ] || [ -z "$url" ]; then
    continue
  fi

  log ""
  log "--- App: $name ---"
  log "  URL: $url"

  if is_healthy "$url"; then
    log "  ✓ 已在 Running 且可访问 → 跳过（与控制台 Running 一致）"
    RESULT="SKIP (already Running)"
  else
    log "  → 不可访问，执行 Resume (restart)..."
    if do_restart "$name"; then
      if wait_healthy "$url" "$name"; then
        RESULT="RESUMED → Running"
      else
        RESULT="RESUMED but still unhealthy"
      fi
    else
      RESULT="RESTART FAILED"
    fi
  fi

  log "  结果: $RESULT"

  shot="${SCREENSHOT_DIR}/${name}.png"
  if take_screenshot "$url" "$shot"; then
    log "  截图已保存: $shot"
    tg_send_photo "$shot" "OSaaS ${name}: ${RESULT}
${url}"
  else
    log "  截图失败（将只发文字）"
    tg_send_text "OSaaS <b>${name}</b>: ${RESULT}
${url}"
  fi
done <<< "$MYAPPS_RAW"

log ""
log "=== 3. 最终 My Apps 列表 ==="
parse_myapps | tee -a "$REPORT_FILE" || true

log ""
log "========================================"
log " Keep-Alive finished"
log "========================================"

SUMMARY=$(cat "$REPORT_FILE" | tail -c 3500)
tg_send_text "OSaaS Keep-Alive 完成
$(date -u '+%Y-%m-%d %H:%M:%S UTC')

<pre>${SUMMARY}</pre>" || true
