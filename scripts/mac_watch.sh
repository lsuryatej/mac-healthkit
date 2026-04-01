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

# Check if we already alerted for this key within debounce window
debounce_check() {
  local key="$1"
  local now
  now=$(now_epoch)
  local cutoff=$(( now - DEBOUNCE_MINUTES * 60 ))
  local last_alert
  last_alert=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
  [ "${last_alert:-0}" -lt "$cutoff" ]
}

# Record that we alerted for this key
debounce_record() {
  local key="$1"
  local now
  now=$(now_epoch)
  # Remove existing entry for key
  grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  echo "${key}=${now}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Send a native macOS notification
send_notification() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"${message}\" with title \"${title}\" subtitle \"mac-healthkit\"" 2>/dev/null || true
}

# ── Load average check ────────────────────────────────────────────────────────
LOAD_LINE=$(uptime)
LOAD_1M=$(echo "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $1}' | tr -d ',')

if float_gt "${LOAD_1M:-0}" "6"; then
  KEY="load_high"
  if debounce_check "$KEY"; then
    # Find top CPU process
    TOP_PROC=$(ps aux 2>/dev/null | sort -rk3 | awk 'NR==2{
      n=split($11,p,"/"); name=p[n]
      sub(/\.app.*/,"",name)
      printf "%s (%.0f%%)", name, $3
    }')
    send_notification "High CPU Load" "Load avg: ${LOAD_1M} — Top process: ${TOP_PROC}. Check with: mac_check.sh"
    debounce_record "$KEY"
  fi
fi

# ── Memory free < 15% ─────────────────────────────────────────────────────────
VM_STAT=$(vm_stat 2>/dev/null || true)
PAGE_SIZE=$(pagesize 2>/dev/null || echo 16384)

pages_free=$(echo "$VM_STAT"        | awk '/Pages free/{gsub(/\./,"",$NF); print $NF+0}')
pages_speculative=$(echo "$VM_STAT" | awk '/Pages speculative/{gsub(/\./,"",$NF); print $NF+0}')
total_ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 1)
total_ram_mb=$(( total_ram_bytes / 1024 / 1024 ))
free_mb=$(( (pages_free + pages_speculative) * PAGE_SIZE / 1024 / 1024 ))
free_pct=$(awk -v f="$free_mb" -v t="$total_ram_mb" 'BEGIN{printf "%.1f", (f/t)*100}')

if float_lt "${free_pct:-100}" "15"; then
  KEY="mem_low"
  if debounce_check "$KEY"; then
    TOP_MEM=$(ps aux 2>/dev/null | sort -rk6 | awk 'NR==2{
      n=split($11,p,"/"); name=p[n]
      sub(/\.app.*/,"",name)
      printf "%s (%dMB)", name, int($6/1024)
    }')
    send_notification "Low Memory" "Only ${free_pct}% free. Top: ${TOP_MEM}. Run: sudo purge"
    debounce_record "$KEY"
  fi
fi

# ── Any single process > 3 GB RAM ────────────────────────────────────────────
while IFS= read -r proc_line; do
  proc_rss_kb=$(echo "$proc_line" | awk '{print $6+0}')
  proc_cmd=$(echo "$proc_line"    | awk '{n=split($11,p,"/"); name=p[n]; sub(/\.app.*/,"",name); print name}')
  proc_mb=$(( proc_rss_kb / 1024 ))

  if [ "$proc_rss_kb" -gt 3145728 ]; then  # 3 * 1024 * 1024 KB = 3 GB
    KEY="proc_mem_${proc_cmd}"
    if debounce_check "$KEY"; then
      send_notification "Memory Hog Detected" "${proc_cmd} is using ${proc_mb} MB. Fix: killall \"${proc_cmd}\""
      debounce_record "$KEY"
    fi
  fi
done < <(ps aux 2>/dev/null | sort -rk6 | awk 'NR>1 && NR<=20')

# ── WebKit tab > 800 MB ───────────────────────────────────────────────────────
while IFS= read -r wk_line; do
  wk_rss_kb=$(echo "$wk_line" | awk '{print $6+0}')
  wk_pid=$(echo "$wk_line"    | awk '{print $2}')
  wk_mb=$(( wk_rss_kb / 1024 ))

  if [ "$wk_rss_kb" -gt 819200 ]; then  # 800 MB in KB
    KEY="webkit_${wk_pid}"
    if debounce_check "$KEY"; then
      send_notification "Heavy Browser Tab" "A browser tab is using ${wk_mb} MB (PID ${wk_pid}). Close some tabs."
      debounce_record "$KEY"
    fi
  fi
done < <(ps aux 2>/dev/null | awk '($11 ~ /WebContent|WebKit\.WebContent/) && ($6 > 819200)')

# Clean up old debounce entries (older than 24 hours)
CUTOFF_24H=$(( $(now_epoch) - 86400 ))
awk -F= -v c="$CUTOFF_24H" '$2 > c' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
mv "${STATE_FILE}.tmp" "$STATE_FILE"
