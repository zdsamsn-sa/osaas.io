#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo " OSaaS My Apps Keep-Alive"
echo " Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================"

if [ -z "${OSC_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: OSC_ACCESS_TOKEN is not set"
  exit 1
fi

# 常见 My Apps 对应的 runner serviceId
RUNNERS=(
  "eyevinn-web-runner"
  "eyevinn-python-runner"
  "eyevinn-golang-runner"
  "eyevinn-dotnet-runner"
  "eyevinn-wasm-runner"
)

echo ""
echo "=== 1. List My Apps ==="
npx @osaas/cli myapp list || true

echo ""
echo "=== 2. Check and Resume instances ==="

for serviceId in "${RUNNERS[@]}"; do
  echo ""
  echo "--- Service: $serviceId ---"

  # 尝试获取实例列表
  if ! instances_raw=$(npx @osaas/cli list "$serviceId" 2>/dev/null); then
    echo "  No instances or service not available"
    continue
  fi

  # 如果没有实例
  if echo "$instances_raw" | grep -qiE 'no instances|empty|\[\]' || [ -z "$instances_raw" ]; then
    echo "  No instances found"
    continue
  fi

  # 提取实例名（优先 JSON，否则简单文本解析）
  if echo "$instances_raw" | jq -e . >/dev/null 2>&1; then
    names=$(echo "$instances_raw" | jq -r '.[].name // empty' 2>/dev/null || true)
  else
    names=$(echo "$instances_raw" | grep -oE '[a-zA-Z0-9][a-zA-Z0-9_-]*' | head -20 || true)
  fi

  if [ -z "$names" ]; then
    echo "  Could not parse instance names, printing raw output for debug:"
    echo "$instances_raw"
    continue
  fi

  for name in $names; do
    # 过滤明显不是实例名的词
    if [[ "$name" =~ ^(name|status|url|id|service|instance|list|create|remove|describe|restart)$ ]]; then
      continue
    fi

    echo "  Checking instance: $name"

    # 获取当前状态
    status="unknown"
    if desc=$(npx @osaas/cli describe "$serviceId" "$name" 2>/dev/null); then
      status=$(echo "$desc" | grep -iE 'status|state|running|phase' | head -1 || echo "unknown")
      echo "    Current: $status"
    fi

    # 判断是否需要 Resume
    if echo "$status" | grep -qiE 'running|active|ready|healthy'; then
      echo "    ✓ Already running → skip"
    else
      echo "    → Not running, executing resume (restart)..."
      if npx @osaas/cli restart "$serviceId" "$name"; then
        echo "    Restart command sent"

        # 等待变成 running（最多约 3 分钟）
        for i in $(seq 1 18); do
          sleep 10
          current=$(npx @osaas/cli describe "$serviceId" "$name" 2>/dev/null | grep -iE 'status|state|running|phase' | head -1 || echo "unknown")
          echo "    [$i/18] status: $current"
          if echo "$current" | grep -qiE 'running|active|ready|healthy'; then
            echo "    ✓ $name is now running"
            break
          fi
        done
      else
        echo "    ⚠ restart failed for $name (may already be starting or not exist)"
      fi
    fi
  done
done

echo ""
echo "=== 3. Final My Apps list ==="
npx @osaas/cli myapp list || true

echo ""
echo "========================================"
echo " Keep-Alive finished"
echo "========================================"
