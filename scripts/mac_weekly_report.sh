#!/usr/bin/env bash
# mac_weekly_report.sh — Trend summary from health.csv log
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

LOG_FILE="${1:-$HOME/.mac-healthkit/logs/health.csv}"

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD='\033[1m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'
  RED='\033[0;31m'; GREEN='\033[0;32m'; RESET='\033[0m'
else
  BOLD=''; CYAN=''; YELLOW=''; RED=''; GREEN=''; RESET=''
fi

if [ ! -f "$LOG_FILE" ]; then
  echo "No log file found at: $LOG_FILE"
  echo "Run mac_logger.sh at least once, or wait for the launchd agent to generate data."
  exit 1
fi

TOTAL_ROWS=$(awk 'NR>1' "$LOG_FILE" | wc -l | tr -d ' ')
if [ "$TOTAL_ROWS" -lt 2 ]; then
  echo "Not enough data yet ($TOTAL_ROWS rows). Check back after the logger has run a few cycles."
  exit 0
fi

echo -e "${BOLD}${CYAN}mac-healthkit / Weekly Report${RESET}  $(date '+%Y-%m-%d %H:%M')"
echo "Log file: $LOG_FILE"
echo "════════════════════════════════════════════════════════"

# ── Date range ────────────────────────────────────────────────────────────────
FIRST_DATE=$(awk -F',' 'NR==2{gsub(/"/, "", $1); print $1}' "$LOG_FILE")
LAST_DATE=$(awk  -F',' 'END{gsub(/"/, "", $1); print $1}' "$LOG_FILE")
echo -e "\n${BOLD}Date Range${RESET}"
echo "  From: $FIRST_DATE"
echo "  To:   $LAST_DATE"
echo "  Rows: $TOTAL_ROWS"

# ── Load averages ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Load Average (1m)${RESET}"
awk -F',' 'NR>1 {
  v=$2+0
  sum+=v; count++
  if(v>peak) peak=v
  if(v>6) crit++
  else if(v>4) warn++
  else ok++
} END {
  if(count>0) avg=sum/count; else avg=0
  printf "  Average: %.2f   Peak: %.2f\n", avg, peak
  printf "  Normal (<4): %d rows  Elevated (4-6): %d rows  Critical (>6): %d rows\n", ok, warn, crit
}' "$LOG_FILE"

# ── Memory pressure distribution ─────────────────────────────────────────────
echo -e "\n${BOLD}Memory Pressure Distribution${RESET}"
awk -F',' 'NR>1 {
  v=$5+0
  if(v>=70) healthy++
  else if(v>=30) moderate++
  else critical++
  total++
} END {
  if(total>0) {
    printf "  Healthy   (free ≥70%%): %5d rows  (%5.1f%%)\n", healthy+0, (healthy+0)/total*100
    printf "  Moderate  (30–70%%):   %5d rows  (%5.1f%%)\n", moderate+0, (moderate+0)/total*100
    printf "  Critical  (<30%%):     %5d rows  (%5.1f%%)\n", critical+0, (critical+0)/total*100
  }
}' "$LOG_FILE"

# ── Top 5 CPU offenders ───────────────────────────────────────────────────────
echo -e "\n${BOLD}Top 5 Most Frequent CPU Offenders${RESET}"
awk -F',' 'NR>1 {
  gsub(/"/, "", $8)
  count[$8]++
} END {
  for (p in count) print count[p], p
}' "$LOG_FILE" | sort -rn | head -5 | awk '{printf "  %4d appearances   %s\n", $1, $2}'

# ── Top 5 memory events ───────────────────────────────────────────────────────
echo -e "\n${BOLD}Top 5 Worst Memory Events${RESET}"
awk -F',' 'NR>1 {
  gsub(/"/, "", $1); gsub(/"/, "", $10)
  print $11+0, $1, $10
}' "$LOG_FILE" | sort -rn | head -5 | awk '{printf "  %6d MB   %-20s   %s %s\n", $1, $3, $2, $3}' | \
  awk -F'   ' '{printf "  %s MB   %-28s   %s\n", $1, $2, $3}'

# cleaner version
echo ""
awk -F',' 'NR>1 {
  gsub(/"/, "", $1); gsub(/"/, "", $10)
  printf "%s %s %s\n", $11+0, $1, $10
}' "$LOG_FILE" | sort -rn | head -5 | \
  awk '{printf "  %6d MB   at %-24s  process: %s\n", $1, $2" "$3, $4}'

# ── Swap events ───────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Swap Activity${RESET}"
awk -F',' 'NR>1 {
  cur=$6+0
  if(NR>2 && cur > prev) swap_events++
  prev=cur
} END {
  printf "  Swap pressure events (swapout count increased): %d\n", swap_events+0
}' "$LOG_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Summary${RESET}"
echo "  Total log entries: $TOTAL_ROWS"
echo "  Tip: Run mac_check.sh for a live snapshot, mac_disk_diff.sh for disk growth."
echo ""
