#!/usr/bin/env bash
# mac_watch.sh — Passive background alerter via macOS notifications
# Runs every 10 minutes via launchd. Sends native notifications on threshold breach.
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

STATE_DIR="$HOME/.mac-healthkit"
STATE_FILE="$STATE_DIR/watch_state.txt"
DEBOUNCE_MINUTES=30

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
float_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }

now_epoch() { date '+%s'; }

# Returns 0 (true) if this key has NOT been alerted within the debounce window
debounce_check() {
  local key="$1"
  local now; now=$(now_epoch)
  local cutoff=$(( now - DEBOUNCE_MINUTES * 60 ))
  local last_alert
  last_alert=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
  [ "${last_alert:-0}" -lt "$cutoff" ]
}

debounce_record() {
  local key="$1"
  local now; now=$(now_epoch)
  grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  echo "${key}=${now}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

send_notification() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"${message}\" with title \"${title}\" subtitle \"mac-healthkit\"" \
    2>/dev/null || true
}

# ── [1] Load average > 6 ─────────────────────────────────────────────────────
LOAD_RAW=$(sysctl -n vm.loadavg 2>/dev/null || true)
LOAD_1M=$(echo "$LOAD_RAW" | awk '{print $2}')
[ -z "${LOAD_1M:-}" ] && LOAD_1M=$(uptime | sed 's/.*load averages*: //' | awk '{print $1}' | tr -d ',')

if float_gt "${LOAD_1M:-0}" "6"; then
  KEY="load_high"
  if debounce_check "$KEY"; then
    TOP_PROC=$(ps -axco "pid,pcpu,comm" 2>/dev/null | awk 'NR>1' | sort -rk2 | head -1 \
      | awk '{printf "%s (%.0f%%)", $3, $2}')
    send_notification "⚠️ High CPU Load" "Load: ${LOAD_1M} — top: ${TOP_PROC}. Run mac_check.sh"
    debounce_record "$KEY"
  fi
fi

# ── [2] Memory free < 15% ─────────────────────────────────────────────────────
free_pct=$(memory_pressure 2>/dev/null \
  | awk '/System-wide memory free percentage/{gsub(/%/,"",$NF); print $NF+0}')
: "${free_pct:=100}"

if float_lt "${free_pct}" "15"; then
  KEY="mem_low"
  if debounce_check "$KEY"; then
    TOP_MEM=$(ps -axco "rss,comm" 2>/dev/null | awk 'NR>1' | sort -rn | head -1 \
      | awk '{printf "%s (%dMB)", $2, int($1/1024)}')
    send_notification "⚠️ Low Memory" "Only ${free_pct}% free. Top: ${TOP_MEM}. Run: sudo purge"
    debounce_record "$KEY"
  fi
fi

# ── [3] Thermal throttling ────────────────────────────────────────────────────
THERMAL_LEVEL=$(sysctl -n kern.thermalevel 2>/dev/null || echo 0)
if [ "${THERMAL_LEVEL}" -gt 20 ]; then
  KEY="thermal_throttle"
  if debounce_check "$KEY"; then
    TOP_CPU=$(ps -axco "pcpu,comm" 2>/dev/null | awk 'NR>1' | sort -rn | head -1 \
      | awk '{printf "%s (%.0f%%)", $2, $1}')
    send_notification "🌡️ Thermal Throttling" \
      "Mac is throttling (level ${THERMAL_LEVEL}). Top CPU: ${TOP_CPU}. Check ventilation."
    debounce_record "$KEY"
  fi
fi

# ── [4] Battery low (on battery, < 10%) ──────────────────────────────────────
BATTERY_RAW=$(ioreg -r -c AppleSmartBattery -n AppleSmartBattery 2>/dev/null || true)
if [ -n "$BATTERY_RAW" ]; then
  batt_current=$(echo "$BATTERY_RAW" | awk '/"CurrentCapacity"/{print $NF}')
  batt_max=$(echo     "$BATTERY_RAW" | awk '/"MaxCapacity"/{print $NF}')
  is_charging=$(echo  "$BATTERY_RAW" | awk '/"IsCharging"/{print $NF}')
  ext_conn=$(echo     "$BATTERY_RAW" | awk '/"ExternalConnected"/{print $NF}')

  if [ -n "${batt_max:-}" ] && [ "${batt_max:-0}" -gt 0 ]; then
    batt_pct=$(awk -v c="${batt_current:-0}" -v m="$batt_max" \
      'BEGIN{printf "%.0f", (c/m)*100}')
    # Only alert if on battery (not charging, not plugged in)
    if [ "${is_charging:-}" != "Yes" ] && [ "${is_charging:-}" != "1" ] \
       && [ "${ext_conn:-}" != "Yes" ] && [ "${ext_conn:-}" != "1" ]; then
      if [ "${batt_pct:-100}" -lt 10 ]; then
        KEY="battery_low"
        if debounce_check "$KEY"; then
          send_notification "🔋 Battery Low" \
            "${batt_pct}% remaining. Plug in soon."
          debounce_record "$KEY"
        fi
      fi
    fi
  fi
fi

# ── [5] Any single process > 3 GB RAM ────────────────────────────────────────
while IFS= read -r proc_line; do
  proc_rss_kb=$(echo "$proc_line" | awk '{print $3+0}')
  proc_cmd=$(echo    "$proc_line" | awk '{print $4}')
  proc_mb=$(( proc_rss_kb / 1024 ))

  if [ "$proc_rss_kb" -gt 3145728 ]; then  # 3 GB in KB
    KEY="proc_mem_${proc_cmd}"
    if debounce_check "$KEY"; then
      send_notification "🐘 Memory Hog: ${proc_cmd}" \
        "${proc_mb} MB used. Fix: killall \"${proc_cmd}\""
      debounce_record "$KEY"
    fi
  fi
done < <(ps -axco "pid,pcpu,rss,comm" 2>/dev/null | awk 'NR>1' | sort -rk3 | head -20)

# ── [6] Heavy WebKit tab > 800 MB ────────────────────────────────────────────
while IFS= read -r wk_line; do
  wk_pid=$(echo    "$wk_line" | awk '{print $1}')
  wk_rss_kb=$(echo "$wk_line" | awk '{print $3+0}')
  wk_mb=$(( wk_rss_kb / 1024 ))

  if [ "$wk_rss_kb" -gt 819200 ]; then  # 800 MB in KB
    KEY="webkit_${wk_pid}"
    if debounce_check "$KEY"; then
      send_notification "🌐 Heavy Browser Tab" \
        "A browser tab is using ${wk_mb} MB (PID ${wk_pid}). Close some tabs."
      debounce_record "$KEY"
    fi
  fi
done < <(ps -axco "pid,pcpu,rss,comm" 2>/dev/null \
  | awk 'NR>1 && ($4 ~ /WebContent/ || $4 ~ /WebKit\.WebContent/) && $3 > 819200')

# ── Clean up debounce state older than 24 hours ───────────────────────────────
CUTOFF_24H=$(( $(now_epoch) - 86400 ))
awk -F= -v c="$CUTOFF_24H" '$2+0 > c' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
mv "${STATE_FILE}.tmp" "$STATE_FILE"
