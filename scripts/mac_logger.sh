#!/usr/bin/env bash
# mac_logger.sh — Silent background health logger for launchd
# Appends one CSV row to ~/.mac-healthkit/logs/health.csv every run.
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

LOG_DIR="$HOME/.mac-healthkit/logs"
LOG_FILE="$LOG_DIR/health.csv"
MAX_SIZE_BYTES=$((50 * 1024 * 1024))  # 50 MB

# ── Ensure log directory exists ───────────────────────────────────────────────
mkdir -p "$LOG_DIR"

# ── Rotate if oversized ───────────────────────────────────────────────────────
if [ -f "$LOG_FILE" ]; then
  file_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$file_size" -gt "$MAX_SIZE_BYTES" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1"
  fi
fi

# ── Write CSV header if file is new ───────────────────────────────────────────
if [ ! -f "$LOG_FILE" ]; then
  echo "timestamp,load_1m,load_5m,load_15m,mem_free_pct,swap_out_total,compressed_pages,top_cpu_proc,top_cpu_pct,top_mem_proc,top_mem_mb,cpu_power_mw" > "$LOG_FILE"
fi

# ── Timestamp ─────────────────────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ── Load averages ─────────────────────────────────────────────────────────────
LOAD_LINE=$(uptime)
LOAD_1M=$(echo  "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $1}' | tr -d ',')
LOAD_5M=$(echo  "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $2}' | tr -d ',')
LOAD_15M=$(echo "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $3}' | tr -d ',')

# ── Memory ────────────────────────────────────────────────────────────────────
VM_STAT=$(vm_stat 2>/dev/null || true)
PAGE_SIZE=$(pagesize 2>/dev/null || echo 16384)

pages_free=$(echo "$VM_STAT"        | awk '/Pages free/{gsub(/\./,"",$NF); print $NF+0}')
pages_speculative=$(echo "$VM_STAT" | awk '/Pages speculative/{gsub(/\./,"",$NF); print $NF+0}')
pages_compressed=$(echo "$VM_STAT"  | awk '/Pages occupied by compressor/{gsub(/\./,"",$NF); print $NF+0}')
swap_out_total=$(echo "$VM_STAT"    | awk '/Swapouts/{gsub(/\./,"",$NF); print $NF+0}')

total_ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 1)
total_ram_mb=$(( total_ram_bytes / 1024 / 1024 ))
free_mb=$(( (pages_free + pages_speculative) * PAGE_SIZE / 1024 / 1024 ))
mem_free_pct=$(awk -v f="$free_mb" -v t="$total_ram_mb" 'BEGIN{printf "%.1f", (f/t)*100}')

# ── Top CPU process ───────────────────────────────────────────────────────────
TOP_CPU_LINE=$(ps aux 2>/dev/null | sort -rk3 | awk 'NR==2{print}')
TOP_CPU_PCT=$(echo "$TOP_CPU_LINE" | awk '{print $3}')
TOP_CPU_CMD=$(echo "$TOP_CPU_LINE" | awk '{print $11}' | awk -F'/' '{print $NF}' | sed 's/\.app.*//')

# ── Top MEM process ───────────────────────────────────────────────────────────
TOP_MEM_LINE=$(ps aux 2>/dev/null | sort -rk6 | awk 'NR==2{print}')
TOP_MEM_MB=$(echo "$TOP_MEM_LINE" | awk '{printf "%.0f", $6/1024}')
TOP_MEM_CMD=$(echo "$TOP_MEM_LINE" | awk '{print $11}' | awk -F'/' '{print $NF}' | sed 's/\.app.*//')

# ── CPU power (skip silently — requires sudo) ─────────────────────────────────
CPU_POWER_MW="N/A"
# powermetrics requires root; logger runs unprivileged — skip

# ── Append CSV row ────────────────────────────────────────────────────────────
printf '"%s",%s,%s,%s,%s,%s,%s,"%s",%s,"%s",%s,%s\n' \
  "$TIMESTAMP" \
  "${LOAD_1M:-0}" \
  "${LOAD_5M:-0}" \
  "${LOAD_15M:-0}" \
  "${mem_free_pct:-0}" \
  "${swap_out_total:-0}" \
  "${pages_compressed:-0}" \
  "${TOP_CPU_CMD:-unknown}" \
  "${TOP_CPU_PCT:-0}" \
  "${TOP_MEM_CMD:-unknown}" \
  "${TOP_MEM_MB:-0}" \
  "${CPU_POWER_MW}" \
  >> "$LOG_FILE"
