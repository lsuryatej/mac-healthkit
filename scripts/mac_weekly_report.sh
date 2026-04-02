#!/usr/bin/env bash
# mac_weekly_report.sh — Trend summary from health.csv log
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail
trap '' PIPE

LOG_FILE="${1:-$HOME/.mac-healthkit/logs/health.csv}"
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

# ── Colour palette (matches mac_check.sh) ────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
PURPLE='\033[38;5;135m'; BPURPLE='\033[1;38;5;135m'
GREEN='\033[0;32m';  BGREEN='\033[1;32m'
YELLOW='\033[0;33m'; BYELLOW='\033[1;33m'
RED='\033[0;31m';    BRED='\033[1;31m'
BWHITE='\033[1;37m'; DGRAY='\033[2;37m'
CYAN='\033[0;36m'

# ── Shared helpers ────────────────────────────────────────────────────────────
section() {
  local label="$1" subtitle="${2:-}"
  local rest=$(( TERM_WIDTH - ${#label} - ${#subtitle} - 12 ))
  [ "$rest" -lt 4 ] && rest=4
  echo ""
  printf "\033[38;5;135m  ─── %s \033[0m" "$label"
  [ -n "$subtitle" ] && printf "\033[2;37m(%s) \033[0m" "$subtitle"
  printf "\033[2;37m"
  awk -v w="$rest" 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "\033[0m"
}

kv()       { printf "  ${DGRAY}%-26s${RESET}  ${BWHITE}%s${RESET}\n" "$1" "$2"; }
warn_line(){ printf "  ${YELLOW}▲${RESET}  %s\n" "$1"; }
crit_line(){ printf "  ${RED}✕${RESET}  %s\n" "$1"; }

make_bar() {
  local pct=$1 width=${2:-20} fc="${3:-0;32}"
  awk -v p="$pct" -v w="$width" -v fc="$fc" 'BEGIN{
    filled=int(p*w/100); if(filled>w)filled=w; if(filled<0)filled=0
    empty=w-filled
    if(filled>0){ printf "\033[%sm", fc; for(i=0;i<filled;i++) printf "█" }
    printf "\033[2;37m"
    for(i=0;i<empty;i++) printf "░"
    printf "\033[0m"
  }'
}

hrule() {
  printf "${DGRAY}"
  awk -v w="$TERM_WIDTH" 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "${RESET}"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ ! -f "$LOG_FILE" ]; then
  echo ""
  printf "  ${RED}No log file found at: ${LOG_FILE}${RESET}\n"
  printf "  ${DGRAY}Install the launchd agent first: bash install/install.sh${RESET}\n\n"
  exit 1
fi

TOTAL_ROWS=$(awk 'NR>1' "$LOG_FILE" | wc -l | tr -d ' ')
if [ "${TOTAL_ROWS:-0}" -lt 2 ]; then
  echo ""
  printf "  ${YELLOW}Not enough data yet (${TOTAL_ROWS} rows).${RESET}\n"
  printf "  ${DGRAY}The logger runs every 5 minutes. Check back in a little while.${RESET}\n\n"
  exit 0
fi

# ── Schema detection ──────────────────────────────────────────────────────────
HEADER=$(head -1 "$LOG_FILE")
COL_COUNT=$(echo "$HEADER" | awk -F',' '{print NF}')
HAS_NEW_COLS=false; [ "$COL_COUNT" -ge 17 ] && HAS_NEW_COLS=true

# ── Date range ────────────────────────────────────────────────────────────────
FIRST_DATE=$(awk -F',' 'NR==2{gsub(/"/, "", $1); print $1}' "$LOG_FILE")
LAST_DATE=$(awk  -F',' 'END{gsub(/"/, "", $1); print $1}'  "$LOG_FILE")

# Compute span — use macOS date -j to parse "YYYY-MM-DD HH:MM:SS"
_t1=$(date -j -f "%Y-%m-%d %H:%M:%S" "$FIRST_DATE" "+%s" 2>/dev/null || echo 0)
_t2=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LAST_DATE"  "+%s" 2>/dev/null || echo 0)
_span_s=$(( _t2 - _t1 ))
_span_h=$(awk -v s="$_span_s" 'BEGIN{printf "%.1f", s/3600}')
_span_label=$(awk -v h="$_span_h" 'BEGIN{if(h+0>=48){printf "%.1f days",h/24}else{printf "%.1fh",h+0}}')

# ── Header ────────────────────────────────────────────────────────────────────
NOW=$(date '+%a %b %-d  ·  %H:%M')
_inner="  mac-healthkit  ·  Weekly Report  ·  ${NOW}  "
_box_w=$(( ${#_inner} + 2 ))

echo ""
printf "${DGRAY}"
awk -v w="$_box_w" 'BEGIN{printf "╭"; for(i=0;i<w;i++) printf "─"; print "╮"}'
printf "${RESET}"
printf "${DGRAY}│${RESET}${BWHITE}%s${RESET}${DGRAY}│${RESET}\n" "$_inner"
printf "${DGRAY}"
awk -v w="$_box_w" 'BEGIN{printf "╰"; for(i=0;i<w;i++) printf "─"; print "╯"}'
printf "${RESET}\n"

echo ""
kv "Log file"    "${LOG_FILE}"
kv "Rows"        "${TOTAL_ROWS}"
kv "Span"        "${_span_label}  (${FIRST_DATE}  →  ${LAST_DATE})"
kv "Schema"      "${COL_COUNT}-column $(${HAS_NEW_COLS} && echo "v2" || echo "v1 — run logger to upgrade")"

# ── Load average ─────────────────────────────────────────────────────────────
section "CPU Load" "1-minute average"
awk -F',' -v tw="$TERM_WIDTH" 'NR>1 {
  v=$2+0
  sum+=v; count++
  if(v>peak) peak=v
  if(v>6) crit++
  else if(v>4) warn++
  else ok++
} END {
  if(count==0) exit
  avg=sum/count
  # color for avg
  ac=(avg>6)?"\033[0;31m":(avg>4)?"\033[0;33m":"\033[0;32m"
  pc=(peak>6)?"\033[0;31m":(peak>4)?"\033[0;33m":"\033[0;32m"
  printf "  \033[2;37mAverage\033[0m  %s%.2f\033[0m        \033[2;37mPeak\033[0m  %s%.2f\033[0m\n", ac,avg, pc,peak
  printf "\n"
  # Distribution bar
  total=ok+warn+crit
  ok_pct=(total>0)?ok/total*100:0
  warn_pct=(total>0)?warn/total*100:0
  crit_pct=(total>0)?crit/total*100:0
  bar_w=tw-28; if(bar_w<10)bar_w=10
  ok_b=int(ok_pct*bar_w/100)
  warn_b=int(warn_pct*bar_w/100)
  crit_b=bar_w-ok_b-warn_b; if(crit_b<0)crit_b=0
  printf "  \033[2;37mCalmload  \033[0m"
  if(ok_b>0){printf "\033[0;32m"; for(i=0;i<ok_b;i++) printf "█"}
  if(warn_b>0){printf "\033[0;33m"; for(i=0;i<warn_b;i++) printf "█"}
  if(crit_b>0){printf "\033[0;31m"; for(i=0;i<crit_b;i++) printf "█"}
  printf "\033[0m\n"
  printf "  \033[2;37m          \033[0;32m■\033[0m calm (%d)   \033[0;33m■\033[0m elevated (%d)   \033[0;31m■\033[0m critical (%d)\033[0m\n",ok,warn,crit
}' "$LOG_FILE"

# ── Memory pressure ──────────────────────────────────────────────────────────
section "Memory Pressure" "% free at each sample"
awk -F',' -v tw="$TERM_WIDTH" 'NR>1 {
  v=$5+0
  sum+=v; count++
  if(v<min||min==0) min=v
  if(v>=70) healthy++
  else if(v>=30) moderate++
  else critical++
} END {
  if(count==0) exit
  avg=sum/count
  ac=(avg<15)?"\033[0;31m":(avg<30)?"\033[0;33m":"\033[0;32m"
  mc=(min<15)?"\033[0;31m":(min<30)?"\033[0;33m":"\033[0;32m"
  printf "  \033[2;37mAvg free\033[0m  %s%.1f%%\033[0m        \033[2;37mLowest seen\033[0m  %s%.1f%%\033[0m\n",ac,avg,mc,min
  printf "\n"
  bar_w=tw-28; if(bar_w<10)bar_w=10
  h_b=int(healthy/count*bar_w)
  m_b=int(moderate/count*bar_w)
  c_b=bar_w-h_b-m_b; if(c_b<0)c_b=0
  printf "  \033[2;37mDistrib   \033[0m"
  if(h_b>0){printf "\033[0;32m"; for(i=0;i<h_b;i++) printf "█"}
  if(m_b>0){printf "\033[0;33m"; for(i=0;i<m_b;i++) printf "█"}
  if(c_b>0){printf "\033[0;31m"; for(i=0;i<c_b;i++) printf "█"}
  printf "\033[0m\n"
  printf "  \033[2;37m          \033[0;32m■\033[0m healthy ≥70%% (%d)   \033[0;33m■\033[0m moderate (%d)   \033[0;31m■\033[0m critical <30%% (%d)\033[0m\n",healthy,moderate,critical
  if(critical>0) printf "  \033[0;33m▲\033[0m  %d samples below 30%% free — RAM was under pressure\033[0m\n",critical
}' "$LOG_FILE"

# ── Swap ─────────────────────────────────────────────────────────────────────
if $HAS_NEW_COLS; then
  section "Swap Usage" "disk overflow when RAM is full"
  awk -F',' 'NR>1 {
    v=$6+0
    sum+=v; count++
    if(v>peak) peak=v
    if(v>0) nonzero++
  } END {
    if(count==0) exit
    avg=sum/count
    pct=(count>0)?nonzero/count*100:0
    ac=(avg>1000)?"\033[0;31m":(avg>200)?"\033[0;33m":"\033[0;32m"
    pc=(peak>2000)?"\033[0;31m":(peak>500)?"\033[0;33m":"\033[0;32m"
    printf "  \033[2;37mAvg used\033[0m  %s%.0f MB\033[0m        \033[2;37mPeak\033[0m  %s%.0f MB\033[0m\n",ac,avg,pc,peak
    printf "  \033[2;37mSamples with swap active:\033[0m  %d of %d  (%.1f%%)\033[0m\n",nonzero,count,pct
    if(peak>500) printf "  \033[0;33m▲\033[0m  Peak swap exceeded 500 MB — Mac has been RAM-pressured\033[0m\n"
  }' "$LOG_FILE"
fi

# ── Top CPU offenders ────────────────────────────────────────────────────────
section "Frequent CPU Offenders" "most common top-CPU process at sample time"
awk -F',' 'NR>1 {
  gsub(/"/, "", $9)
  if($9!="" && $9!="N/A") count[$9]++
  total++
} END {
  for (p in count) print count[p], p
}' "$LOG_FILE" | sort -rn | head -6 | awk -v total="$TOTAL_ROWS" '{
  pct=($1+0>0 && total+0>0)?($1/total*100):0
  bar_w=20
  filled=int(pct*bar_w/100); if(filled>bar_w)filled=bar_w
  printf "  \033[1;37m%-22s\033[0m  ", $2
  printf "\033[0;32m"
  for(i=0;i<filled;i++) printf "█"
  printf "\033[2;37m"
  for(i=filled;i<bar_w;i++) printf "░"
  printf "\033[0m  %d× (%.0f%%)\n", $1, pct
}'

# ── Worst memory events ──────────────────────────────────────────────────────
section "Peak Memory Events" "top 5 highest single-process RSS readings"
awk -F',' 'NR>1 {
  gsub(/"/, "", $1); gsub(/"/, "", $11)
  mem=$12+0
  if(mem>0) printf "%06d %s %s\n", mem, $1, $11
}' "$LOG_FILE" | sort -rn | head -5 | awk '{
  mem=$1+0
  c=(mem>3000)?"\033[0;31m":(mem>800)?"\033[0;33m":"\033[0;32m"
  printf "  %s%5d MB\033[0m  \033[2;37m%s %s\033[0m  process: \033[1;37m%s\033[0m\n",c,mem,$2,$3,$4
}'

# ── GPU utilization ──────────────────────────────────────────────────────────
if $HAS_NEW_COLS; then
  GPU_DATA=$(awk -F',' 'NR>1 && $13+0>0 {print $13+0}' "$LOG_FILE" || true)
  if [ -n "${GPU_DATA:-}" ]; then
    section "GPU Utilization"
    echo "$GPU_DATA" | awk -v tw="$TERM_WIDTH" '
    {sum+=$1; count++; if($1>peak)peak=$1; if($1>50)high++}
    END {
      if(count==0) exit
      avg=sum/count
      ac=(avg>70)?"\033[0;33m":"\033[0;32m"
      pc=(peak>80)?"\033[0;31m":(peak>50)?"\033[0;33m":"\033[0;32m"
      printf "  \033[2;37mAverage\033[0m  %s%.1f%%\033[0m        \033[2;37mPeak\033[0m  %s%.1f%%\033[0m\n",ac,avg,pc,peak
      printf "  \033[2;37mSamples >50%%:\033[0m  %d of %d\033[0m\n",high+0,count
    }'
  fi
fi

# ── Thermal throttle ─────────────────────────────────────────────────────────
if $HAS_NEW_COLS; then
  section "Thermal Throttle Events"
  awk -F',' 'NR>1 {
    v=$14+0
    if(v>0) throttle++
    total++
  } END {
    if(total==0) exit
    pct=(throttle/total)*100
    c=(pct>20)?"\033[0;31m":(pct>5)?"\033[0;33m":"\033[0;32m"
    printf "  %sThrottling: %d of %d samples (%.1f%%)\033[0m\n",c,throttle+0,total,pct
    if(throttle>0)
      printf "  \033[2;37mWhen throttling occurs the chip reduces clock speed to cool down.\033[0m\n"
  }' "$LOG_FILE"
fi

# ── Battery health ───────────────────────────────────────────────────────────
if $HAS_NEW_COLS; then
  BATT_DATA=$(awk -F',' 'NR>1 && $16!="N/A" && $16+0>0 {print $16+0}' "$LOG_FILE" || true)
  if [ -n "${BATT_DATA:-}" ]; then
    section "Battery Health" "over log period"
    echo "$BATT_DATA" | awk '
    {sum+=$1; count++; if($1>peak||peak==0)peak=$1; if($1<min||min==0)min=$1}
    END {
      if(count==0) exit
      avg=sum/count
      c=(avg<80)?"\033[0;31m":(avg<90)?"\033[0;33m":"\033[0;32m"
      printf "  \033[2;37mAverage\033[0m  %s%.1f%%\033[0m   \033[2;37mMin seen\033[0m  \033[1;37m%.1f%%\033[0m   \033[2;37mMax seen\033[0m  \033[1;37m%.1f%%\033[0m\n",c,avg,min,peak
      if(avg<80) printf "  \033[0;33m▲\033[0m  Below 80%% — Apple recommends service\033[0m\n"
    }'
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
hrule
echo ""
printf "  ${DGRAY}Live snapshot: bash scripts/mac_check.sh   Disk growth: bash scripts/mac_disk_diff.sh${RESET}\n"
echo ""
