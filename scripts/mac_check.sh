#!/usr/bin/env bash
# mac_check.sh — On-demand macOS health diagnostic
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

# ── Color / NO_COLOR ──────────────────────────────────────────────────────────
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
  ORANGE='\033[0;33m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; ORANGE=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
float_gt() { echo | awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
float_lt() { echo | awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }

# ── Persona ───────────────────────────────────────────────────────────────────
PERSONA="engineer"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona) PERSONA="$2"; shift 2 ;;
    --persona=*) PERSONA="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# ── Name normalisation (awk) ───────────────────────────────────────────────────
normalise_name() {
  echo "$1" | awk '{
    if ($0 ~ /WebKit\.WebContent/) { print "Safari Tab"; next }
    if ($0 ~ /Brave.*Renderer|BraveRenderer/) { print "Brave Tab"; next }
    if ($0 ~ /mds_stores|mdworker/) { print "Spotlight"; next }
    if ($0 ~ /^bird$/) { print "iCloud Sync"; next }
    if ($0 ~ /kernel_task/) { print "kernel [skip]"; next }
    if ($0 ~ /^sysmond$/) { print "sysmond [skip]"; next }
    if ($0 ~ /WebContent/) { print "Safari Tab"; next }
    print $0
  }'
}

# ── Section printer ───────────────────────────────────────────────────────────
SECTION=0
print_section() {
  SECTION=$((SECTION + 1))
  local num
  num=$(printf "%02d" "$SECTION")
  if [ "$PERSONA" = "engineer" ]; then
    echo -e "\n${BOLD}${CYAN}[$num] $1${RESET}"
    echo "────────────────────────────────────────"
  else
    echo -e "\n${BOLD}$1${RESET}"
    echo "────────────────────────────────────────"
  fi
}

status_label() {
  local val="$1" warn="$2" crit="$3"
  if float_gt "$val" "$crit"; then
    [ "$PERSONA" = "engineer" ] && echo -e "${RED}▶ CRITICAL${RESET}" || echo "🔴"
  elif float_gt "$val" "$warn"; then
    [ "$PERSONA" = "engineer" ] && echo -e "${YELLOW}▶ elevated${RESET}" || echo "🟡"
  else
    [ "$PERSONA" = "engineer" ] && echo -e "${GREEN}▶ nominal${RESET}" || echo "🟢"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  HEADER
# ══════════════════════════════════════════════════════════════════════════════
if [ "$PERSONA" = "engineer" ]; then
  echo -e "${BOLD}mac-healthkit / mac_check.sh${RESET}  $(date '+%Y-%m-%d %H:%M:%S')"
  uname -m | grep -q arm64 && echo "arch: Apple Silicon (arm64)" || echo "arch: $(uname -m)"
  sw_vers -productVersion | awk '{print "macOS " $0}'
else
  echo -e "${BOLD}Mac Health Check${RESET}  $(date '+%b %d, %Y  %H:%M')"
  echo "Running a quick check of your Mac's health..."
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [01] LOAD AVERAGE
# ══════════════════════════════════════════════════════════════════════════════
print_section "Load Average"

LOAD_RAW=$(sysctl -n vm.loadavg 2>/dev/null || uptime)
LOAD_1M=$(echo "$LOAD_RAW"  | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+$/) {print $i; exit}}')
LOAD_5M=$(echo "$LOAD_RAW"  | awk '{found=0; for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+$/) {found++; if(found==2){print $i; exit}}}')
LOAD_15M=$(echo "$LOAD_RAW" | awk '{found=0; for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+$/) {found++; if(found==3){print $i; exit}}}')

# Fallback: parse uptime output directly
if [ -z "$LOAD_1M" ]; then
  LOAD_LINE=$(uptime)
  LOAD_1M=$(echo  "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $1}' | tr -d ',')
  LOAD_5M=$(echo  "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $2}' | tr -d ',')
  LOAD_15M=$(echo "$LOAD_LINE" | sed 's/.*load averages: //' | awk '{print $3}' | tr -d ',')
fi

LOAD_STATUS=$(status_label "${LOAD_1M:-0}" 4 6)

if [ "$PERSONA" = "engineer" ]; then
  echo "1m: ${LOAD_1M}   5m: ${LOAD_5M}   15m: ${LOAD_15M}   $LOAD_STATUS"
  if float_gt "${LOAD_1M:-0}" "6"; then
    echo -e "${RED}  CRITICAL: load >6 — system is under heavy stress${RESET}"
  elif float_gt "${LOAD_1M:-0}" "4"; then
    echo -e "${YELLOW}  WARN: load >4 — find the culprit below${RESET}"
  fi
else
  echo "Right now: ${LOAD_1M}   (5-min avg: ${LOAD_5M})  $LOAD_STATUS"
  if float_gt "${LOAD_1M:-0}" "6"; then
    echo "🔴 Your Mac is working very hard right now. Something is using a lot of CPU."
  elif float_gt "${LOAD_1M:-0}" "4"; then
    echo "🟡 Your Mac is busier than usual. It may feel slow."
  else
    echo "🟢 Load is normal. Your Mac is not under stress."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [02] MEMORY PRESSURE
# ══════════════════════════════════════════════════════════════════════════════
print_section "Memory Pressure"

# Get memory stats via vm_stat
VM_STAT=$(vm_stat 2>/dev/null || true)
PAGE_SIZE=$(pagesize 2>/dev/null || echo 16384)

pages_free=$(echo "$VM_STAT"     | awk '/Pages free/{gsub(/\./,"",$NF); print $NF+0}')
pages_active=$(echo "$VM_STAT"   | awk '/Pages active/{gsub(/\./,"",$NF); print $NF+0}')
pages_wired=$(echo "$VM_STAT"    | awk '/Pages wired/{gsub(/\./,"",$NF); print $NF+0}')
pages_compressed=$(echo "$VM_STAT" | awk '/Pages occupied by compressor/{gsub(/\./,"",$NF); print $NF+0}')
swapouts=$(echo "$VM_STAT"       | awk '/Swapouts/{gsub(/\./,"",$NF); print $NF+0}')
pages_speculative=$(echo "$VM_STAT" | awk '/Pages speculative/{gsub(/\./,"",$NF); print $NF+0}')

total_ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
total_ram_mb=$(( total_ram_bytes / 1024 / 1024 ))

free_mb=$(( (pages_free + pages_speculative) * PAGE_SIZE / 1024 / 1024 ))
compressed_mb=$(( pages_compressed * PAGE_SIZE / 1024 / 1024 ))

if [ "$total_ram_mb" -gt 0 ]; then
  free_pct=$(awk -v f="$free_mb" -v t="$total_ram_mb" 'BEGIN{printf "%.1f", (f/t)*100}')
else
  free_pct="0"
fi

MEM_STATUS=$(status_label "$(awk -v p="$free_pct" 'BEGIN{print 100-p}')" 50 85)

# memory_pressure tool output
MEM_PRESSURE_LEVEL=$(memory_pressure 2>/dev/null | awk '/System-wide memory free percentage/{print $NF}' | tr -d '%' || echo "N/A")

if [ "$PERSONA" = "engineer" ]; then
  echo "Total RAM:        ${total_ram_mb} MB"
  echo "Free (approx):    ${free_mb} MB  (${free_pct}%)  $MEM_STATUS"
  echo "Compressed pages: ${pages_compressed} pages  (~${compressed_mb} MB)"
  echo "Swapouts total:   ${swapouts}"
  [ "$MEM_PRESSURE_LEVEL" != "N/A" ] && echo "memory_pressure:  ${MEM_PRESSURE_LEVEL}%"
  if float_lt "${free_pct}" "15"; then
    echo -e "${RED}  CRITICAL: <15% free — system will swap heavily${RESET}"
  elif float_lt "${free_pct}" "30"; then
    echo -e "${YELLOW}  WARN: <30% free — compression active${RESET}"
  fi
  [ "${swapouts:-0}" -gt 1000 ] && echo -e "${YELLOW}  WARN: high swapout count — RAM pressure has been ongoing${RESET}"
else
  echo "Total memory: ${total_ram_mb} MB"
  echo "Free memory:  ${free_mb} MB (${free_pct}%)  $MEM_STATUS"
  if float_lt "${free_pct}" "15"; then
    echo "🔴 Very little free memory. Your Mac may be slow because it's swapping data to disk."
    echo "   Try closing apps you're not using."
  elif float_lt "${free_pct}" "30"; then
    echo "🟡 Memory is getting tight. Some apps may be slow."
  else
    echo "🟢 Memory looks fine."
  fi
  [ "${swapouts:-0}" -gt 1000 ] && echo "🟡 Memory has been under pressure recently (high swap activity)."
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [03] TOP CPU CONSUMERS
# ══════════════════════════════════════════════════════════════════════════════
print_section "Top CPU Consumers"

# ps output: pid, %cpu, rss(kb), command
PS_CPU=$(ps aux -r 2>/dev/null | awk 'NR>1 && NR<=9 {print NR-1, $2, $3, $6, $11}' || \
         ps -eo pid,pcpu,rss,comm -r 2>/dev/null | awk 'NR>1 && NR<=9 {print NR-1, $1, $2, $3, $4}')

if [ "$PERSONA" = "engineer" ]; then
  echo "# PID       %CPU   RSS(MB)  Name (normalised)"
  ps aux 2>/dev/null | sort -rk3 | awk 'NR>1 && NR<=9 {
    pid=$2; cpu=$3; rss=int($6/1024)
    cmd=$11
    # normalise
    if (cmd ~ /WebKit\.WebContent|WebContent/) name="Safari Tab"
    else if (cmd ~ /Brave.*Renderer|BraveRenderer/) name="Brave Tab"
    else if (cmd ~ /mds_stores|mdworker/) name="Spotlight"
    else if (cmd == "bird") name="iCloud Sync"
    else if (cmd ~ /kernel_task/) name="kernel [skip]"
    else if (cmd == "sysmond") name="sysmond [skip]"
    else {
      n=split(cmd,parts,"/"); name=parts[n]
      sub(/\.app.*/,"",name)
    }
    printf "  [%d] PID %-6s  %5s%%  %5d MB  %s  (%s)\n", NR-1, pid, cpu, rss, name, cmd
  }'
else
  echo "These are the apps using the most CPU right now:"
  ps aux 2>/dev/null | sort -rk3 | awk 'NR>1 && NR<=9 {
    cpu=$3; rss=int($6/1024/100)*100
    cmd=$11
    if (cmd ~ /WebKit\.WebContent|WebContent/) name="Safari Tab"
    else if (cmd ~ /Brave.*Renderer|BraveRenderer/) name="Brave Tab (web page)"
    else if (cmd ~ /mds_stores|mdworker/) name="Spotlight (search index)"
    else if (cmd == "bird") name="iCloud Sync"
    else if (cmd ~ /kernel_task/) name="System Kernel (normal)"
    else if (cmd == "sysmond") name="System Monitor (normal)"
    else {
      n=split(cmd,parts,"/"); name=parts[n]
      sub(/\.app.*/,"",name)
    }
    icon="🟢"
    if (cpu+0 > 40) icon="🔴"
    else if (cpu+0 > 15) icon="🟡"
    printf "  %s  %-30s  %s%% CPU  (~%d MB RAM)\n", icon, name, cpu, rss
  }'
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [04] TOP MEMORY CONSUMERS
# ══════════════════════════════════════════════════════════════════════════════
print_section "Top Memory Consumers"

if [ "$PERSONA" = "engineer" ]; then
  echo "# PID       %MEM   RSS(MB)  Name (normalised)"
  ps aux 2>/dev/null | sort -rk6 | awk 'NR>1 && NR<=9 {
    pid=$2; mem=$4; rss=int($6/1024)
    cmd=$11
    if (cmd ~ /WebKit\.WebContent|WebContent/) name="Safari Tab"
    else if (cmd ~ /Brave.*Renderer|BraveRenderer/) name="Brave Tab"
    else if (cmd ~ /mds_stores|mdworker/) name="Spotlight"
    else if (cmd == "bird") name="iCloud Sync"
    else if (cmd ~ /kernel_task/) name="kernel [skip]"
    else if (cmd == "sysmond") name="sysmond [skip]"
    else {
      n=split(cmd,parts,"/"); name=parts[n]
      sub(/\.app.*/,"",name)
    }
    printf "  [%d] PID %-6s  %5s%%  %5d MB  %s  (%s)\n", NR-1, pid, mem, rss, name, cmd
  }'
else
  echo "These are the apps using the most memory right now:"
  ps aux 2>/dev/null | sort -rk6 | awk 'NR>1 && NR<=9 {
    mem=$4; rss=int($6/1024/100)*100
    cmd=$11
    if (cmd ~ /WebKit\.WebContent|WebContent/) name="Safari Tab"
    else if (cmd ~ /Brave.*Renderer|BraveRenderer/) name="Brave Tab (web page)"
    else if (cmd ~ /mds_stores|mdworker/) name="Spotlight (search index)"
    else if (cmd == "bird") name="iCloud Sync"
    else if (cmd ~ /kernel_task/) name="System Kernel (normal)"
    else if (cmd == "sysmond") name="System Monitor (normal)"
    else {
      n=split(cmd,parts,"/"); name=parts[n]
      sub(/\.app.*/,"",name)
    }
    icon="🟢"
    if (rss > 3000) icon="🔴"
    else if (rss > 1000) icon="🟡"
    printf "  %s  %-30s  ~%d MB\n", icon, name, rss
  }'
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [05] KNOWN CULPRIT DETECTION
# ══════════════════════════════════════════════════════════════════════════════
print_section "Known Culprit Detection"

CULPRITS_FOUND=0

culprit_header() {
  CULPRITS_FOUND=$((CULPRITS_FOUND + 1))
  if [ "$PERSONA" = "engineer" ]; then
    echo -e "${YELLOW}  ▶ $1${RESET}"
  else
    echo "🟡 $1"
  fi
}

culprit_info() {
  if [ "$PERSONA" = "engineer" ]; then
    echo "    $1"
  else
    echo "   $1"
  fi
}

# iWork RAM leaks (Pages, Numbers, Keynote)
for app in "Pages" "Numbers" "Keynote"; do
  rss=$(ps aux 2>/dev/null | awk -v a="$app" '$11 ~ a {sum+=$6} END{print int(sum/1024)}')
  if [ "${rss:-0}" -gt 1500 ]; then
    culprit_header "${app} RAM leak detected (${rss} MB)"
    culprit_info "iWork apps can leak RAM over long sessions."
    [ "$PERSONA" = "engineer" ] && culprit_info "Fix: killall ${app} && open -a ${app}" \
                                || culprit_info "Fix: quit and reopen ${app}."
  fi
done

# Notion GPU helper polling bug
NOTION_GPU=$(ps aux 2>/dev/null | awk '/Notion.*GPU|Notion.*Helper.*GPU/{print $3}' | head -1)
if [ -n "${NOTION_GPU:-}" ] && float_gt "${NOTION_GPU}" "10"; then
  culprit_header "Notion GPU Helper polling (${NOTION_GPU}% CPU)"
  culprit_info "Known Notion bug: GPU helper polls excessively."
  [ "$PERSONA" = "engineer" ] && culprit_info "Fix: killall 'Notion Helper (GPU)'" \
                               || culprit_info "Fix: quit Notion and reopen it."
fi

# iCloud bird heavy sync
BIRD_CPU=$(ps aux 2>/dev/null | awk '/^[^ ]+ +[0-9]+ /{if ($11 ~ /\/bird$/) print $3}' | head -1)
BIRD_RSS=$(ps aux 2>/dev/null | awk '/^[^ ]+ +[0-9]+ /{if ($11 ~ /\/bird$/) print int($6/1024)}' | head -1)
if [ -n "${BIRD_CPU:-}" ] && float_gt "${BIRD_CPU}" "20"; then
  culprit_header "iCloud Sync (bird) heavy activity: ${BIRD_CPU}% CPU, ${BIRD_RSS:-?} MB"
  culprit_info "iCloud is syncing a lot. Could be a large file upload or stuck sync."
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "Fix: killall bird  (it will restart, usually clears stuck sync)" \
    || culprit_info "Fix: run this in Terminal:  killall bird"
fi

# Spotlight workers
SPOT_COUNT=$(ps aux 2>/dev/null | grep -cE 'mds_stores|mdworker' || echo 0)
if [ "${SPOT_COUNT}" -gt 8 ]; then
  culprit_header "Spotlight: ${SPOT_COUNT} workers running (>8 threshold)"
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "Fix: sudo mdutil -a -i off && sudo mdutil -a -i on  (forces reindex cycle)" \
    || culprit_info "Spotlight is re-indexing heavily. It usually finishes on its own. If it persists for hours, run:  sudo mdutil -E /"
fi

# WebKit tabs >500MB
if [ "$PERSONA" = "engineer" ]; then
  ps aux 2>/dev/null | awk '($11 ~ /WebContent|WebKit\.WebContent/) && ($6/1024 > 500) {
    printf "  ▶ WARN  Heavy WebKit tab: PID %s  %.0f MB\n", $2, $6/1024
  }'
else
  ps aux 2>/dev/null | awk '($11 ~ /WebContent|WebKit\.WebContent/) && ($6/1024 > 500) {
    printf "  🟡 A browser tab is using a lot of memory: ~%.0f MB (try closing some tabs)\n", int($6/1024/100)*100
  }'
fi

# Brave renderers >8
BRAVE_COUNT=$(ps aux 2>/dev/null | grep -cE 'Brave.*Renderer|BraveRenderer' || echo 0)
if [ "${BRAVE_COUNT}" -gt 8 ]; then
  culprit_header "Brave: ${BRAVE_COUNT} renderer processes (>8 threshold)"
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "Close tabs or enable Brave's tab memory saving (brave://flags/#brave-tab-memory)" \
    || culprit_info "You have a lot of Brave tabs open. Closing some will free memory."
fi

# Docker CPU
DOCKER_CPU=$(ps aux 2>/dev/null | awk '/com.docker|docker-desktop/{sum+=$3} END{print sum+0}')
if float_gt "${DOCKER_CPU:-0}" "10"; then
  culprit_header "Docker: ${DOCKER_CPU}% CPU"
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "Fix: docker stats --no-stream  (find the hot container); or quit Docker Desktop" \
    || culprit_info "Docker is using a lot of CPU. If you're not using it, quit Docker Desktop."
fi

# Python/Jupyter CPU
PYTHON_CPU=$(ps aux 2>/dev/null | awk '/python|jupyter/{sum+=$3} END{print sum+0}')
if float_gt "${PYTHON_CPU:-0}" "20"; then
  culprit_header "Python/Jupyter: ${PYTHON_CPU}% CPU combined"
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "Check: ps aux | grep -E 'python|jupyter'" \
    || culprit_info "A Python script or Jupyter notebook is running heavily."
fi

# Node/Next.js CPU
NODE_CPU=$(ps aux 2>/dev/null | awk '/node/{sum+=$3} END{print sum+0}')
if float_gt "${NODE_CPU:-0}" "15"; then
  culprit_header "Node.js: ${NODE_CPU}% CPU combined"
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "Check: ps aux | grep node" \
    || culprit_info "Node.js (possibly a dev server like Next.js) is running heavily."
fi

# VPN memory
VPN_RSS=$(ps aux 2>/dev/null | awk '/NordVPN|openvpn|wireguard|mullvad/{sum+=$6} END{print int(sum/1024)}')
if [ "${VPN_RSS:-0}" -gt 300 ]; then
  culprit_header "VPN client: ${VPN_RSS} MB RAM"
  [ "$PERSONA" = "engineer" ] \
    && culprit_info "VPN helper processes are accumulating RAM. Restart VPN client." \
    || culprit_info "Your VPN app is using a lot of memory. Try disconnecting and reconnecting."
fi

if [ "$CULPRITS_FOUND" -eq 0 ]; then
  [ "$PERSONA" = "engineer" ] \
    && echo -e "  ${GREEN}▶ No known culprits detected${RESET}" \
    || echo "🟢 No known problem apps detected."
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [06] CPU + GPU POWER (sudo only)
# ══════════════════════════════════════════════════════════════════════════════
print_section "CPU + GPU Power Draw"

if [ "$(id -u)" -eq 0 ]; then
  POWER_RAW=$(powermetrics --samplers cpu_power -n 1 -i 1000 2>/dev/null || true)
  if [ -n "$POWER_RAW" ]; then
    CPU_POWER=$(echo "$POWER_RAW" | awk '/CPU Power/{print $NF}' | head -1)
    GPU_POWER=$(echo "$POWER_RAW" | awk '/GPU Power/{print $NF}' | head -1)
    if [ "$PERSONA" = "engineer" ]; then
      echo "CPU Power: ${CPU_POWER:-N/A}"
      echo "GPU Power: ${GPU_POWER:-N/A}"
    else
      echo "CPU Power draw: ${CPU_POWER:-N/A}"
      echo "GPU Power draw: ${GPU_POWER:-N/A}"
      echo "(Higher numbers = more battery drain)"
    fi
  else
    echo "  powermetrics returned no data."
  fi
else
  if [ "$PERSONA" = "engineer" ]; then
    echo "  [skipped — not root]  Re-run with: sudo $0"
  else
    echo "  Power data requires admin access. To see it, run:"
    echo "  sudo bash scripts/mac_check.sh"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  QUICK KILL COMMANDS
# ══════════════════════════════════════════════════════════════════════════════
if [ "$PERSONA" = "engineer" ]; then
  echo -e "\n${BOLD}${CYAN}── Quick Kill Commands ──────────────────────────────────────────────${RESET}"
  echo "  killall -9 mds_stores mdworker    # kill Spotlight indexing"
  echo "  killall bird                       # restart iCloud sync"
  echo "  osascript -e 'quit app \"Safari\"'  # quit Safari"
  echo "  sudo purge                         # flush disk cache (frees inactive RAM)"
  echo "  launchctl kickstart -k gui/\$(id -u)/com.machealthkit.logger"
else
  echo -e "\n${BOLD}── If you need to fix something, run this in Terminal ────────────────${RESET}"
  echo "  Stop Spotlight indexing:   killall mds_stores"
  echo "  Restart iCloud sync:       killall bird"
  echo "  Free some RAM:             sudo purge"
fi

echo ""
