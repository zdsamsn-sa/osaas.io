#!/usr/bin/env bash
# OSaaS My Apps Keep-Alive
# 打开 https://app.osaas.io/dashboard/my-apps ，点击 Suspended 的 Resume，等到 Running

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

log() { echo "$@" | tee -a "$REPORT_FILE"; }

is_healthy() {
  local url="$1"
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 -L "$url" 2>/dev/null || echo "000")
  [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] || [ "$code" = "404" ]
}

parse_myapps() {
  npx -y @osaas/cli myapp list 2>/dev/null || true
}

# ---------- 核心：浏览器打开 My Apps，点击 Resume ----------
# 返回 0=成功点到并开始恢复；1=失败
click_resume_on_dashboard() {
  local app_name="${1:-zdsa}"
  local shot_before="${SCREENSHOT_DIR}/dashboard-before.png"
  local shot_after="${SCREENSHOT_DIR}/dashboard-after.png"
  export APP_NAME="$app_name"
  export SHOT_BEFORE="$shot_before"
  export SHOT_AFTER="$shot_after"
  export OSC_ACCESS_TOKEN
  export OSC_SESSION_COOKIE="${OSC_SESSION_COOKIE:-}"

  node <<'NODE'
const { chromium } = require('playwright');

(async () => {
  const token = process.env.OSC_ACCESS_TOKEN;
  const appName = process.env.APP_NAME || 'zdsa';
  const cookieHeader = process.env.OSC_SESSION_COOKIE || '';

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    userAgent:
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  });

  // 可选：用户提供的登录 Cookie（从浏览器复制），格式 name=value; name2=value2
  if (cookieHeader.trim()) {
    const cookies = cookieHeader.split(';').map((p) => {
      const [name, ...rest] = p.trim().split('=');
      return {
        name: name.trim(),
        value: rest.join('=').trim(),
        domain: '.osaas.io',
        path: '/',
      };
    }).filter((c) => c.name && c.value);
    if (cookies.length) await context.addCookies(cookies);
  }

  const page = await context.newPage();

  // 给所有请求带上 PAT（部分 API 认 x-pat-jwt / Authorization）
  await page.route('**/*', async (route) => {
    const headers = {
      ...route.request().headers(),
      authorization: `Bearer ${token}`,
      'x-pat-jwt': `Bearer ${token}`,
    };
    try {
      await route.continue({ headers });
    } catch {
      await route.continue();
    }
  });

  try {
    // 写入可能用到的 localStorage key
    await page.goto('https://app.osaas.io/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.evaluate((t) => {
      try {
        localStorage.setItem('osc_access_token', t);
        localStorage.setItem('access_token', t);
        localStorage.setItem('token', t);
        localStorage.setItem('pat', t);
        localStorage.setItem('OSC_ACCESS_TOKEN', t);
      } catch (_) {}
    }, token);

    await page.goto('https://app.osaas.io/dashboard/my-apps', {
      waitUntil: 'networkidle',
      timeout: 60000,
    });
    await page.waitForTimeout(4000);

    // 截图：操作前
    await page.screenshot({ path: process.env.SHOT_BEFORE, fullPage: true, type: 'png' }).catch(() => {});

    const bodyText = await page.locator('body').innerText().catch(() => '');

    // 仍在登录页
    if (/Continue with|Sign in|magic link|one-time password|登录/i.test(bodyText) &&
        !/Suspended Apps|My Apps|Resume/i.test(bodyText)) {
      console.error('NEED_LOGIN: 页面需要浏览器登录态。请配置 Secret OSC_SESSION_COOKIE（从已登录浏览器复制 Cookie）');
      process.exitCode = 2;
      await browser.close();
      return;
    }

    // 找 Resume 按钮：优先 Suspended 区域、含 app 名的行
    let clicked = false;
    const candidates = [
      page.getByRole('button', { name: /Resume/i }),
      page.locator('button:has-text("Resume")'),
      page.locator('[class*="Suspended"] button:has-text("Resume")'),
      page.locator(`text=${appName}`).locator('..').locator('button:has-text("Resume")'),
      page.locator('button').filter({ hasText: /^Resume$/ }),
    ];

    for (const loc of candidates) {
      const count = await loc.count().catch(() => 0);
      if (count > 0) {
        const btn = loc.first();
        await btn.scrollIntoViewIfNeeded().catch(() => {});
        await btn.click({ timeout: 10000 });
        clicked = true;
        console.log('CLICKED_RESUME');
        break;
      }
    }

    if (!clicked) {
      // 可能已经在 Running，没有 Resume 按钮
      if (/Running/i.test(bodyText) && new RegExp(appName, 'i').test(bodyText)) {
        console.log('ALREADY_RUNNING');
        process.exitCode = 0;
      } else if (/token exhaustion|upgrading your plan|token balance/i.test(bodyText)) {
        console.error('TOKEN_EXHAUSTED: 页面提示 token 耗尽，即使点 Resume 也可能被拒绝');
        // 仍尝试点一次（若有按钮）
        process.exitCode = 3;
      } else {
        console.error('NO_RESUME_BUTTON: 未找到 Resume 按钮');
        process.exitCode = 1;
      }
      await page.screenshot({ path: process.env.SHOT_AFTER, fullPage: true, type: 'png' }).catch(() => {});
      await browser.close();
      return;
    }

    // 点击后等待状态变化
    await page.waitForTimeout(5000);
    // 可能出现确认对话框
    const confirm = page.getByRole('button', { name: /Confirm|OK|Yes|Resume/i });
    if (await confirm.count().catch(() => 0)) {
      await confirm.first().click({ timeout: 5000 }).catch(() => {});
      await page.waitForTimeout(3000);
    }

    // 轮询页面直到出现 Running 或超时
    let ok = false;
    for (let i = 0; i < 24; i++) {
      await page.reload({ waitUntil: 'networkidle', timeout: 60000 }).catch(() => {});
      await page.waitForTimeout(5000);
      const t = await page.locator('body').innerText().catch(() => '');
      if (new RegExp(appName, 'i').test(t) && /Running/i.test(t) && !/Suspended/i.test(t.split(appName)[1]?.slice(0, 80) || '')) {
        ok = true;
        console.log('STATUS_RUNNING');
        break;
      }
      // Suspended 区域消失也算进展
      if (new RegExp(appName, 'i').test(t) && !/Suspended Apps[\s\S]{0,200}Resume/i.test(t)) {
        // 可能在恢复中
        console.log('RESUME_IN_PROGRESS', i);
      }
    }

    await page.screenshot({ path: process.env.SHOT_AFTER, fullPage: true, type: 'png' }).catch(() => {});
    process.exitCode = ok ? 0 : 4;
    if (!ok) console.error('WAIT_TIMEOUT: 点击 Resume 后仍未看到 Running（可能 token 不足）');
  } catch (e) {
    console.error('BROWSER_ERROR:', e.message);
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

shot_app() {
  local url="$1" out="$2"
  export SHOT_URL="$url" SHOT_OUT="$out"
  node <<'NODE'
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  try {
    await page.goto(process.env.SHOT_URL, { waitUntil: 'networkidle', timeout: 45000 });
    await page.waitForTimeout(2000);
    await page.screenshot({ path: process.env.SHOT_OUT, fullPage: true, type: 'png' });
    console.log('app_shot_ok');
  } catch (e) {
    console.error('app_shot_fail', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
NODE
}

# ---------- main ----------
APP_NAME="${OSAAS_APP_NAMES:-zdsa}"
APP_URL="${OSAAS_APP_URL:-https://d5a4f3bcdd.apps.osaas.io}"
UTC_NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

log ""
log "=== 1. List My Apps (CLI) ==="
MYAPPS_RAW=$(parse_myapps)
log "${MYAPPS_RAW:-（空 — 可能全部 Suspended）}"

log ""
log "=== 2. 打开控制台并点击 Resume ==="
log "  页面: https://app.osaas.io/dashboard/my-apps"
log "  应用: $APP_NAME"

STATUS="Unknown"
ACTION="未执行"
CONCLUSION=""

if is_healthy "$APP_URL"; then
  log "  ✓ 应用 URL 已可访问 → 跳过 Resume"
  STATUS="Running / Online"
  ACTION="无需启动（已在运行）"
  CONCLUSION="应用在线，跳过 Resume"
else
  log "  → URL 不可访问，使用浏览器点击 Resume..."
  set +e
  OUT=$(click_resume_on_dashboard "$APP_NAME" 2>&1)
  RC=$?
  set -e
  log "$OUT"

  # 发送控制台截图
  [ -f "${SCREENSHOT_DIR}/dashboard-before.png" ] && \
    tg_send_photo "${SCREENSHOT_DIR}/dashboard-before.png" "My Apps 点击前
https://app.osaas.io/dashboard/my-apps"
  [ -f "${SCREENSHOT_DIR}/dashboard-after.png" ] && \
    tg_send_photo "${SCREENSHOT_DIR}/dashboard-after.png" "My Apps 点击后"

  case $RC in
    0)
      if echo "$OUT" | grep -q ALREADY_RUNNING; then
        STATUS="Running / Online"
        ACTION="页面已是 Running，未点 Resume"
        CONCLUSION="应用已在运行"
      else
        STATUS="Running / Online"
        ACTION="已在控制台点击 Resume"
        CONCLUSION="Resume 成功，应用已恢复"
      fi
      ;;
    2)
      STATUS="Need Login"
      ACTION="无法进入控制台（缺少网页登录态）"
      CONCLUSION="请添加 Secret OSC_SESSION_COOKIE：浏览器登录 app.osaas.io 后复制 Cookie"
      ;;
    3)
      STATUS="Suspended (token exhausted)"
      ACTION="检测到 token 耗尽提示"
      CONCLUSION="请升级计划或等额度恢复后再 Resume"
      ;;
    4)
      STATUS="Suspended / Unhealthy"
      ACTION="已点击 Resume，但未变为 Running"
      CONCLUSION="可能仍因 token 耗尽被拒绝，请检查额度"
      ;;
    *)
      STATUS="Failed"
      ACTION="浏览器自动化失败"
      CONCLUSION="查看 Actions 日志；或配置 OSC_SESSION_COOKIE"
      ;;
  esac

  # 再等一会用 HTTP 确认
  if ! is_healthy "$APP_URL"; then
    for i in $(seq 1 12); do
      sleep 10
      if is_healthy "$APP_URL"; then
        STATUS="Running / Online"
        CONCLUSION="Resume 后 URL 已可访问"
        break
      fi
      log "  [$i/12] 等待 URL 可访问..."
    done
  fi
fi

# 应用页截图
app_shot="${SCREENSHOT_DIR}/app.png"
if shot_app "$APP_URL" "$app_shot" 2>&1 | tee -a "$REPORT_FILE" | grep -q app_shot_ok; then
  tg_send_photo "$app_shot" "应用页面 ${APP_NAME}
${APP_URL}"
fi

REPORT_MSG="✅ OSaaS 保活已执行
应用: ${APP_NAME}
当前状态: ${STATUS}
启动操作: ${ACTION}
应用地址: ${APP_URL}
控制台: https://app.osaas.io/dashboard/my-apps
执行时间: ${UTC_NOW}
结论: ${CONCLUSION}"

log ""
log "$REPORT_MSG"
tg_send_text "$REPORT_MSG"

log ""
log "=== 3. 最终 My Apps 列表 ==="
parse_myapps | tee -a "$REPORT_FILE" || true

log ""
log "========================================"
log " Keep-Alive finished"
log "========================================"
