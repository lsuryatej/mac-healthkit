#!/usr/bin/env bash
# mac_logger.sh — Silent background health logger for launchd
# Appends one CSV row to ~/.mac-healthkit/logs/health.csv every run.
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail
trap '' PIPE   # prevent SIGPIPE (exit 141) from | head -1 chains

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
  echo "timestamp,load_1m,load_5m,load_15m,mem_free_pct,swap_used_mb,swap_out_total,compressed_pages,top_cpu_proc,top_cpu_pct,top_mem_proc,top_mem_mb,gpu_util_pct,thermal_level,battery_pct,battery_health_pct,cpu_power_mw" \
    > "$LOG_FILE"
fi

# ── Timestamp ─────────────────────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ── Load averages ─────────────────────────────────────────────────────────────
LOAD_RAW=$(sysctl -n vm.loadavg 2>/dev/null || true)
if [ -n "$LOAD_RAW" ]; then
  LOAD_1M=$(echo  "$LOAD_RAW" | awk '{print $2}')
  LOAD_5M=$(echo  "$LOAD_RAW" | awk '{print $3}')
  LOAD_15M=$(echo "$LOAD_RAW" | awk '{print $4}')
else
  LOAD_LINE=$(uptime)
  LOAD_1M=$(echo  "$LOAD_LINE" | sed 's/.*load averages*: //' | awk '{print $1}' | tr -d ',')
  LOAD_5M=$(echo  "$LOAD_LINE" | sed 's/.*load averages*: //' | awk '{print $2}' | tr -d ',')
  LOAD_15M=$(echo "$LOAD_LINE" | sed 's/.*load averages*: //' | awk '{print $3}' | tr -d ',')
fi

# ── Memory — memory_pressure is authoritative ─────────────────────────────────
MEM_PRESSURE_OUT=$(memory_pressure 2>/dev/null || true)
mem_free_pct=$(echo "$MEM_PRESSURE_OUT" \
  | awk '/System-wide memory free percentage/{gsub(/%/,"",$NF); print $NF+0}')
: "${mem_free_pct:=0}"
swap_out_total=$(echo "$MEM_PRESSURE_OUT" | awk '/^Swapouts:/{print $NF+0}')
: "${swap_out_total:=0}"

# Actual swap space used
SWAP_USAGE=$(sysctl -n vm.swapusage 2>/dev/null || true)
swap_used_mb=$(echo "$SWAP_USAGE" \
  | awk '{for(i=1;i<=NF;i++) if($i=="used") print int($(i+2)+0)}')
: "${swap_used_mb:=0}"

# Compressed pages count
VM_STAT=$(vm_stat 2>/dev/null || true)
compressed_pages=$(echo "$VM_STAT" \
  | awk '/Pages occupied by compressor:/{gsub(/\./,"",$NF); print $NF+0}')
: "${compressed_pages:=0}"

# ── Top CPU process ───────────────────────────────────────────────────────────
TOP_CPU_LINE=$(ps -axco "pid,pcpu,rss,comm" 2>/dev/null | awk 'NR>1' | sort -rk2 | head -1)
TOP_CPU_PCT=$(echo "$TOP_CPU_LINE" | awk '{print $2}')
TOP_CPU_CMD=$(echo "$TOP_CPU_LINE" | awk '{print $4}')

# ── Top MEM process ───────────────────────────────────────────────────────────
TOP_MEM_LINE=$(ps -axco "pid,pcpu,rss,comm" 2>/dev/null | awk 'NR>1' | sort -rk3 | head -1)
TOP_MEM_MB=$(echo "$TOP_MEM_LINE" | awk '{printf "%.0f", $3/1024}')
TOP_MEM_CMD=$(echo "$TOP_MEM_LINE" | awk '{print $4}')

# ── GPU utilization (ioreg, no root) ─────────────────────────────────────────
gpu_util_pct=$(ioreg -r -c IOAccelerator 2>/dev/null \
  | awk '/Device Utilization %/{print $NF; exit}')
: "${gpu_util_pct:=N/A}"

# ── Thermal level (no root) ───────────────────────────────────────────────────
thermal_level=$(sysctl -n kern.thermalevel 2>/dev/null || echo 0)

# ── Battery (ioreg, no root) ──────────────────────────────────────────────────
BATTERY_RAW=$(ioreg -r -c AppleSmartBattery -n AppleSmartBattery 2>/dev/null || true)
if [ -n "$BATTERY_RAW" ]; then
  _batt_int() { echo "$BATTERY_RAW" \
    | grep -oE "\"${1}\"[[:space:]]*=[[:space:]]*[0-9]+" | grep -oE '[0-9]+$' | head -1; }
  batt_current=$(_batt_int "CurrentCapacity")
  batt_max=$(_batt_int "MaxCapacity")
  batt_design=$(_batt_int "DesignCapacity")
  if [ -n "${batt_max:-}" ] && [ "${batt_max:-0}" -gt 0 ]; then
    battery_pct=$(awk -v c="${batt_current:-0}" -v m="$batt_max" \
      'BEGIN{printf "%.0f", (c/m)*100}')
    battery_health_pct=$(awk -v m="$batt_max" -v d="${batt_design:-1}" \
      'BEGIN{printf "%.1f", (m/d)*100}')
  else
    battery_pct="N/A"; battery_health_pct="N/A"
  fi
else
  battery_pct="N/A"; battery_health_pct="N/A"
fi

# ── CPU power (skip silently — requires sudo) ─────────────────────────────────
cpu_power_mw="N/A"

# ── Append CSV row ────────────────────────────────────────────────────────────
printf '"%s",%s,%s,%s,%s,%s,%s,%s,"%s",%s,"%s",%s,%s,%s,%s,%s,%s\n' \
  "$TIMESTAMP" \
  "${LOAD_1M:-0}" \
  "${LOAD_5M:-0}" \
  "${LOAD_15M:-0}" \
  "${mem_free_pct:-0}" \
  "${swap_used_mb:-0}" \
  "${swap_out_total:-0}" \
  "${compressed_pages:-0}" \
  "${TOP_CPU_CMD:-unknown}" \
  "${TOP_CPU_PCT:-0}" \
  "${TOP_MEM_CMD:-unknown}" \
  "${TOP_MEM_MB:-0}" \
  "${gpu_util_pct}" \
  "${thermal_level:-0}" \
  "${battery_pct}" \
  "${battery_health_pct}" \
  "${cpu_power_mw}" \
  >> "$LOG_FILE"
