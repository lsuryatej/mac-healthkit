#!/usr/bin/env bash
# mac_check.sh — On-demand macOS health diagnostic
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail
trap '' PIPE   # don't exit on SIGPIPE (e.g. when piped to head or less)

# ── Terminal geometry ─────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

# ── Colour palette ────────────────────────────────────────────────────────────
# Designed for Mac terminal dark backgrounds.  NO_COLOR support removed —
# this script is built for the terminal experience.
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'

# Accent (purple — 256-colour, distinct from all status colours)
PURPLE='\033[38;5;135m'
BPURPLE='\033[1;38;5;135m'

# Status colours
GREEN='\033[0;32m'
BGREEN='\033[1;32m'
YELLOW='\033[0;33m'
BYELLOW='\033[1;33m'
RED='\033[0;31m'
BRED='\033[1;31m'
CYAN='\033[0;36m'

# Text
BWHITE='\033[1;37m'
DGRAY='\033[2;37m'   # dim gray — for labels, borders

# ── Helpers ───────────────────────────────────────────────────────────────────
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
float_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }

# Horizontal rule, full terminal width
hrule() {
  local char="${1:─}" pad="${2:-2}"
  printf '%*s' "$pad" '' | tr ' ' ' '
  awk -v w=$(( TERM_WIDTH - pad )) -v c="${1:-─}" \
    'BEGIN{for(i=0;i<w;i++) printf c; print ""}'
}

# Coloured progress bar — make_bar <pct 0-100> <width> <fill_color_code>
# fill_color_code e.g. "0;32" green, "0;33" amber, "0;31" red
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

# Coloured dot for status
dot() {
  local color="$1" label="$2"
  printf "\033[${color}m●\033[0m  \033[${color}m%s\033[0m" "$label"
}

# Section header — purple rule with optional dim subtitle
# Usage: section "Label"  or  section "Label" "subtitle text"
section() {
  local label="$1" subtitle="${2:-}"
  local title_len=$(( ${#label} + ${#subtitle} ))
  local prefix_len=9  # "  ─── " + " "
  [ -n "$subtitle" ] && prefix_len=$(( prefix_len + ${#subtitle} + 3 ))
  local rest=$(( TERM_WIDTH - ${#label} - prefix_len ))
  [ "$rest" -lt 4 ] && rest=4
  echo ""
  printf "\033[38;5;135m  ─── %s \033[0m" "$label"
  [ -n "$subtitle" ] && printf "\033[2;37m(%s) \033[0m" "$subtitle"
  printf "\033[2;37m"
  awk -v w="$rest" 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "\033[0m"
}

# Inline label (dim gray) + value (bright white)
kv() { printf "  ${DGRAY}%-22s${RESET}  ${BWHITE}%s${RESET}\n" "$1" "$2"; }

# Warning line (amber prefix)
warn_line() { printf "  ${YELLOW}▲${RESET}  %s\n" "$1"; }

# Critical line (red prefix)
crit_line() { printf "  ${RED}✕${RESET}  %s\n" "$1"; }

# ── Persona ───────────────────────────────────────────────────────────────────
PERSONA="engineer"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona) PERSONA="$2"; shift 2 ;;
    --persona=*) PERSONA="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
# Normalize aliases
[ "$PERSONA" = "girlypop" ] || [ "$PERSONA" = "girly-pop" ] || [ "$PERSONA" = "girly" ] && PERSONA="girly"
[ "$PERSONA" = "plaintext" ] || [ "$PERSONA" = "plain-text" ] || [ "$PERSONA" = "plain" ] && PERSONA="designer"

# ── ps helpers ────────────────────────────────────────────────────────────────
# -axco: short comm name, no path, no space-in-path issues, header stripped before sort
ps_by_cpu() { ps -axco "pid,pcpu,rss,comm" 2>/dev/null | awk 'NR>1' | sort -rk2 | head -8; }
ps_by_mem() { ps -axco "pid,pcpu,rss,comm" 2>/dev/null | awk 'NR>1' | sort -rk3 | head -8; }

# Inline normalisation block — shared by all ps awk calls
AWK_NORM='{
  cmd=$4
  if      (cmd ~ /WebKit\.WebContent/ || cmd == "WebContent") name="Safari Tab"
  else if (cmd ~ /Brave.*Renderer/ || cmd ~ /BraveRenderer/)  name="Brave Tab"
  else if (cmd ~ /mds_stores/ || cmd ~ /mdworker/)            name="Spotlight"
  else if (cmd == "bird")                                      name="iCloud Sync"
  else if (cmd ~ /kernel_task/)                               name="kernel"
  else if (cmd == "sysmond")                                   name="sysmond"
  else                                                         name=cmd
}'

# ── Network baseline — captured now, delta computed later ─────────────────────
NETSTAT_T0=$(netstat -ib 2>/dev/null || true)
T0=$(date '+%s')

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — COLLECT ALL METRICS (silent)
# ══════════════════════════════════════════════════════════════════════════════

# ── Load ──────────────────────────────────────────────────────────────────────
LOAD_RAW=$(sysctl -n vm.loadavg 2>/dev/null || true)
if [ -n "$LOAD_RAW" ]; then
  LOAD_1M=$(echo  "$LOAD_RAW" | awk '{print $2}')
  LOAD_5M=$(echo  "$LOAD_RAW" | awk '{print $3}')
  LOAD_15M=$(echo "$LOAD_RAW" | awk '{print $4}')
else
  _up=$(uptime)
  LOAD_1M=$(echo  "$_up" | sed 's/.*load averages*: //' | awk '{print $1}' | tr -d ',')
  LOAD_5M=$(echo  "$_up" | sed 's/.*load averages*: //' | awk '{print $2}' | tr -d ',')
  LOAD_15M=$(echo "$_up" | sed 's/.*load averages*: //' | awk '{print $3}' | tr -d ',')
fi
: "${LOAD_1M:=0}"; : "${LOAD_5M:=0}"; : "${LOAD_15M:=0}"

ECPU_COUNT=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 4)
PCPU_COUNT=$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo 4)
TOTAL_CORES=$(( ECPU_COUNT + PCPU_COUNT ))
LOAD_PCT=$(awk -v l="$LOAD_1M" -v c="$TOTAL_CORES" \
  'BEGIN{v=int(l/c*100); if(v>100)v=100; if(v<0)v=0; print v}')

# ── Memory ────────────────────────────────────────────────────────────────────
VM_STAT=$(vm_stat 2>/dev/null || true)
PAGE_SIZE=$(pagesize 2>/dev/null || echo 16384)

_pg_free=$(echo     "$VM_STAT" | awk '/Pages free:/{gsub(/\./,"",$NF); print $NF+0}')
_pg_inact=$(echo    "$VM_STAT" | awk '/Pages inactive:/{gsub(/\./,"",$NF); print $NF+0}')
_pg_purg=$(echo     "$VM_STAT" | awk '/Pages purgeable:/{gsub(/\./,"",$NF); print $NF+0}')
_pg_spec=$(echo     "$VM_STAT" | awk '/Pages speculative:/{gsub(/\./,"",$NF); print $NF+0}')
_pg_comp=$(echo     "$VM_STAT" | awk '/Pages occupied by compressor:/{gsub(/\./,"",$NF); print $NF+0}')
_pg_wire=$(echo     "$VM_STAT" | awk '/Pages wired down:/{gsub(/\./,"",$NF); print $NF+0}')
_pg_act=$(echo      "$VM_STAT" | awk '/Pages active:/{gsub(/\./,"",$NF); print $NF+0}')

TOTAL_RAM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
AVAIL_MB=$(( ( ${_pg_free:-0} + ${_pg_inact:-0} + ${_pg_purg:-0} + ${_pg_spec:-0} ) * PAGE_SIZE / 1024 / 1024 ))
ACTIVE_MB=$(( ${_pg_act:-0}  * PAGE_SIZE / 1024 / 1024 ))
WIRED_MB=$(( ${_pg_wire:-0}  * PAGE_SIZE / 1024 / 1024 ))
COMPRESSED_MB=$(( ${_pg_comp:-0} * PAGE_SIZE / 1024 / 1024 ))

MEM_PRESSURE_OUT=$(memory_pressure 2>/dev/null || true)
MEM_FREE_PCT=$(echo "$MEM_PRESSURE_OUT" \
  | awk '/System-wide memory free percentage/{gsub(/%/,"",$NF); print $NF+0}')
: "${MEM_FREE_PCT:=50}"
SWAPOUTS=$(echo "$MEM_PRESSURE_OUT" | awk '/^Swapouts:/{print $NF+0}')
SWAPINS=$(echo  "$MEM_PRESSURE_OUT" | awk '/^Swapins:/{print $NF+0}')
: "${SWAPOUTS:=0}"; : "${SWAPINS:=0}"
MEM_USED_PCT=$(( 100 - MEM_FREE_PCT ))

SWAP_USAGE=$(sysctl -n vm.swapusage 2>/dev/null || true)
SWAP_USED_MB=$(echo "$SWAP_USAGE" \
  | awk '{for(i=1;i<=NF;i++) if($i=="used") {val=$(i+2)+0; print int(val)}}')
: "${SWAP_USED_MB:=0}"

# ── Thermal ───────────────────────────────────────────────────────────────────
THERMAL_LEVEL=$(sysctl -n kern.thermalevel 2>/dev/null || echo 0)
if   [ "${THERMAL_LEVEL}" -eq 0 ];  then THERMAL_LABEL="cool";           THERMAL_PCT=0;   THERMAL_COLOR="0;32"
elif [ "${THERMAL_LEVEL}" -le 20 ]; then THERMAL_LABEL="warm";           THERMAL_PCT=33;  THERMAL_COLOR="0;33"
elif [ "${THERMAL_LEVEL}" -le 40 ]; then THERMAL_LABEL="throttling";     THERMAL_PCT=66;  THERMAL_COLOR="0;31"
else                                     THERMAL_LABEL="heavy throttle"; THERMAL_PCT=100; THERMAL_COLOR="0;31"
fi

# ── Battery ───────────────────────────────────────────────────────────────────
BATTERY_RAW=$(ioreg -r -c AppleSmartBattery -n AppleSmartBattery 2>/dev/null || true)
HAS_BATTERY=false
CHARGE_PCT=0; HEALTH_PCT="N/A"; CHARGE_STATE="unknown"; CHARGE_ICON=""
CYCLE_COUNT="N/A"; BATT_TEMP_C="N/A"; POWER_W="N/A"
BATT_COLOR="0;32"

if [ -n "$BATTERY_RAW" ]; then
  # Apple Silicon ioreg packs all battery properties onto one or two lines inside
  # a dictionary. awk '{print $NF}' grabs the last token of the whole line, not
  # the value for that key. Use grep -oE to extract exactly "KEY" = NUMBER.
  _batt_int() {
    echo "$BATTERY_RAW" \
      | grep -oE "\"${1}\"[[:space:]]*=[[:space:]]*[0-9]+" \
      | grep -oE '[0-9]+$' \
      | head -1
  }
  _batt_str() {
    echo "$BATTERY_RAW" \
      | grep -oE "\"${1}\"[[:space:]]*=[[:space:]]*[A-Za-z]+" \
      | grep -oE '[A-Za-z]+$' \
      | head -1
  }

  _cyc=$(_batt_int "CycleCount")
  _des=$(_batt_int "DesignCapacity")
  _soc=$(_batt_int "StateOfCharge")   # reliable % on Apple Silicon
  _max=$(_batt_int "MaxCapacity")
  _cur=$(_batt_int "CurrentCapacity")
  _chg=$(_batt_str "IsCharging")
  _ext=$(_batt_str "ExternalConnected")
  _tmp=$(_batt_int "Temperature")
  _amp=$(_batt_int "InstantAmperage")
  _vlt=$(_batt_int "Voltage")

  # StateOfCharge is a direct % on Apple Silicon — prefer it over CurrentCapacity/MaxCapacity
  # MaxCapacity on M-series is sometimes normalised to 100 (not mAh), so health needs care.
  _have_soc=false
  if [ -n "${_soc:-}" ] && [ "${_soc:-0}" -gt 0 ]; then _have_soc=true; fi

  if [ -n "${_max:-}" ] && [ "${_max:-0}" -gt 0 ]; then
    HAS_BATTERY=true

    # Charge %: prefer StateOfCharge, fall back to CurrentCapacity/MaxCapacity
    if $_have_soc; then
      CHARGE_PCT="$_soc"
    else
      CHARGE_PCT=$(awk -v c="${_cur:-0}" -v m="$_max" 'BEGIN{printf "%.0f",(c/m)*100}')
    fi

    # Health %: only meaningful if MaxCapacity and DesignCapacity are in same unit (mAh).
    # If MaxCapacity <= 100 and DesignCapacity > 100, they're in different units — skip.
    if [ -n "${_des:-}" ] && [ "${_des:-0}" -gt 100 ] && [ "${_max:-0}" -gt 100 ]; then
      HEALTH_PCT=$(awk -v m="$_max" -v d="$_des" 'BEGIN{printf "%.0f",(m/d)*100}')
    else
      HEALTH_PCT="N/A"
    fi
    CYCLE_COUNT="${_cyc:-N/A}"

    if   [ "${_chg:-}" = "Yes" ] || [ "${_chg:-}" = "1" ]; then
      CHARGE_STATE="charging"; CHARGE_ICON=" ⚡"
    elif [ "${_ext:-}" = "Yes" ] || [ "${_ext:-}" = "1" ]; then
      CHARGE_STATE="plugged in"; CHARGE_ICON=" ⚡"
    else
      CHARGE_STATE="on battery"; CHARGE_ICON=""
    fi

    # Temperature: Apple Silicon reports in centi-Celsius, not centi-Kelvin
    [ -n "${_tmp:-}" ] && [ "${_tmp:-0}" -gt 0 ] && \
      BATT_TEMP_C=$(awk -v t="$_tmp" 'BEGIN{printf "%.1f", t/100}')

    # InstantAmperage is a signed int reported as uint64 (two's complement).
    # Values > 10 digits are negative (discharging) — awk can't do exact 64-bit
    # arithmetic, so we skip the mW calculation and use pmset instead.
    if [ -n "${_amp:-}" ] && [ "${#_amp}" -le 10 ] && [ -n "${_vlt:-}" ]; then
      POWER_W=$(awk -v a="$_amp" -v v="$_vlt" \
        'BEGIN{w=(a*v)/1000000; if(w<0)w=-w; if(w>300)w=0; printf "%.1f",w}')
      [ "${POWER_W}" = "0.0" ] && POWER_W="N/A"
    else
      # Fall back to pmset which gives a clean watts reading
      POWER_W=$(pmset -g batt 2>/dev/null \
        | awk -F"'" '/Now drawing/{print $0}' \
        | grep -oE '[0-9]+\.[0-9]+ Watts' | head -1 || echo "N/A")
    fi

    if   [ "${HEALTH_PCT}" != "N/A" ] && float_lt "${HEALTH_PCT}" "80";  then BATT_COLOR="0;31"
    elif [ "${HEALTH_PCT}" != "N/A" ] && float_lt "${HEALTH_PCT}" "90";  then BATT_COLOR="0;33"
    else                                                                       BATT_COLOR="0;32"
    fi
  fi
fi

# ── GPU ───────────────────────────────────────────────────────────────────────
# Use grep -oE: ioreg packs properties onto one line on Apple Silicon,
# so awk $NF grabs the trailing dictionary instead of the numeric value.
GPU_UTIL=$(ioreg -r -c IOAccelerator 2>/dev/null \
  | grep -oE '"Device Utilization %"[[:space:]]*=[[:space:]]*[0-9]+' \
  | grep -oE '[0-9]+$' | head -1)
: "${GPU_UTIL:=0}"

# ── Context adjustments (set by mac_menu.sh via env vars) ─────────────────────
# MHK_DISPLAY_COUNT: number of active displays. Each extra display adds ~20%
#   GPU baseline on Apple Silicon, so the "active" threshold scales up.
#   1 display → active>50%, warn>70%
#   2 displays → active>70%, warn>80%
#   3 displays → active>85%, warn>90%
_display_count="${MHK_DISPLAY_COUNT:-1}"
GPU_ACTIVE_THRESHOLD=$(awk -v d="$_display_count" \
  'BEGIN{t=50+(d-1)*20; if(t>85)t=85; print int(t)}')
GPU_WARN_THRESHOLD=$(awk -v d="$_display_count" \
  'BEGIN{t=70+(d-1)*10; if(t>90)t=90; print int(t)}')
# WindowServer CPU is normal at ~5% per display; flag above 8% per display
WINSERVER_CPU_THRESHOLD=$(( _display_count * 8 ))

if   float_gt "${GPU_UTIL}" "${GPU_WARN_THRESHOLD}"; then GPU_COLOR="0;33"
else                                                       GPU_COLOR="0;32"
fi

# ── Top processes (captured once, reused) ─────────────────────────────────────
PS_ALL=$(ps -axco "pid,pcpu,rss,comm" 2>/dev/null | awk 'NR>1' || true)
TOP_CPU_LINE=$(echo "$PS_ALL" | sort -rk2 | head -1)
TOP_MEM_LINE=$(echo "$PS_ALL" | sort -rk3 | head -1)
TOP_CPU_NAME=$(echo "$TOP_CPU_LINE" | awk '{print $4}')
TOP_CPU_PCT=$(echo  "$TOP_CPU_LINE" | awk '{print $2}')
TOP_CPU_PID=$(echo  "$TOP_CPU_LINE" | awk '{print $1}')
TOP_MEM_NAME=$(echo "$TOP_MEM_LINE" | awk '{print $4}')
TOP_MEM_MB=$(echo   "$TOP_MEM_LINE" | awk '{printf "%.0f",$3/1024}')
TOP_MEM_PID=$(echo  "$TOP_MEM_LINE" | awk '{print $1}')

# ── Spotlight count ───────────────────────────────────────────────────────────
SPOT_COUNT=$(echo "$PS_ALL" | awk '/mds_stores|mdworker/{c++} END{print c+0}')

# ── iCloud bird ───────────────────────────────────────────────────────────────
BIRD_CPU=$(echo "$PS_ALL" | awk '$4=="bird"{print $2}' | head -1); : "${BIRD_CPU:=0}"

# ── VPN RSS ───────────────────────────────────────────────────────────────────
VPN_RSS_MB=$(echo "$PS_ALL" | awk '/NordVPN|openvpn|wireguard|mullvad|Tunnelblick/{sum+=$3} END{print int(sum/1024)}')
: "${VPN_RSS_MB:=0}"
VPN_NAME=$(echo "$PS_ALL" | awk '/NordVPN|openvpn|wireguard|mullvad|Tunnelblick/{print $4; exit}')
: "${VPN_NAME:=VPN}"

# ── Docker ────────────────────────────────────────────────────────────────────
DOCKER_CPU=$(echo "$PS_ALL" | awk '/docker|Docker/{sum+=$2} END{printf "%.1f",sum+0}')
: "${DOCKER_CPU:=0}"

# ── WebKit/browser heavy tabs ─────────────────────────────────────────────────
HEAVY_TABS=$(echo "$PS_ALL" \
  | awk '($4~/WebContent|WebKit\.WebContent/) && ($3/1024>500){print $1, int($3/1024)}')

# ── Active video call detection ───────────────────────────────────────────────
# Zoom, Teams, Meet, Webex inflate CPU/GPU readings — flag so user isn't alarmed.
VIDEOCALL_PROC=$(echo "$PS_ALL" \
  | awk '$4~/[Zz]oom|CptHost|[Tt]eams|[Gg]oogle [Mm]eet|[Ww]ebex/{print $4; exit}')
: "${VIDEOCALL_PROC:=}"

# ── Creative app detection (girly persona tool-specific callouts) ─────────────
CREATIVE_APP_LIST=$(echo "$PS_ALL" \
  | awk '$4~/Photoshop|AfterFX|lightroom|Lightroom|Figma|Premiere|Illustrator|Sketch|Blender/{
      printf "%s ", $4; found=1} END{if(!found) print ""}')
: "${CREATIVE_APP_LIST:=}"
# Detect which specific apps are running for per-app tips
PS_HAS_PHOTOSHOP=$(echo "$PS_ALL" | awk '$4~/Photoshop/{found=1} END{print found+0}')
PS_HAS_AE=$(echo        "$PS_ALL" | awk '$4~/AfterFX/{found=1} END{print found+0}')
PS_HAS_FIGMA=$(echo     "$PS_ALL" | awk '$4~/Figma/{found=1} END{print found+0}')

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — HEADER + AT A GLANCE
# ══════════════════════════════════════════════════════════════════════════════

CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
  || system_profiler SPHardwareDataType 2>/dev/null \
     | awk '/Chip:/{$1=""; print substr($0,2)}' \
  || echo "Apple Silicon")
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "macOS")
NOW=$(date '+%a %b %-d  ·  %H:%M')

# ── Header box ────────────────────────────────────────────────────────────────
_inner="  mac-healthkit   ${CHIP}  ·  macOS ${MACOS_VER}  ·  ${NOW}  "
_inner_len=${#_inner}
_box_w=$(( _inner_len + 2 ))

echo ""
printf "${DGRAY}"
awk -v w="$_box_w" 'BEGIN{printf "╭"; for(i=0;i<w;i++) printf "─"; print "╮"}'
printf "${RESET}"
printf "${DGRAY}│${RESET}${BWHITE}%s${RESET}${DGRAY}│${RESET}\n" "$_inner"
printf "${DGRAY}"
awk -v w="$_box_w" 'BEGIN{printf "╰"; for(i=0;i<w;i++) printf "─"; print "╯"}'
printf "${RESET}\n"

# ── Context notices (only when relevant) ─────────────────────────────────────
_context_shown=false
if [ "${MHK_FRESH_WAKE:-0}" = "1" ]; then
  printf "  ${YELLOW}Just woken from sleep — metrics may be elevated for 60–90 seconds.${RESET}\n"
  _context_shown=true
fi
if [ -n "${VIDEOCALL_PROC:-}" ]; then
  printf "  ${DGRAY}Video call in progress (${VIDEOCALL_PROC}) — elevated CPU/GPU readings are expected.${RESET}\n"
  _context_shown=true
fi
if [ "${_display_count:-1}" -gt 1 ]; then
  printf "  ${DGRAY}${_display_count} displays active — GPU and WindowServer baselines are higher than a single-display setup.${RESET}\n"
  _context_shown=true
fi
$_context_shown && echo ""

# ── Derive status colours used by at-a-glance (computed here, printed later) ─
if   float_gt "$LOAD_1M" "6"; then LOAD_COLOR="0;31"; LOAD_STATUS="very busy"
elif float_gt "$LOAD_1M" "4"; then LOAD_COLOR="0;33"; LOAD_STATUS="busy"
else                                LOAD_COLOR="0;32"; LOAD_STATUS="calm"
fi
if   float_lt "$MEM_FREE_PCT" "15"; then MEM_COLOR="0;31"; MEM_STATUS="critically low"
elif float_lt "$MEM_FREE_PCT" "30"; then MEM_COLOR="0;33"; MEM_STATUS="getting tight"
else                                     MEM_COLOR="0;32"; MEM_STATUS="plenty"
fi

# glance_row <label> <bar_pct> <bar_color> <right_value> <dot_color> <status_label>
glance_row() {
  local lbl="$1" pct="$2" bc="$3" val="$4" dc="$5" stat="$6"
  local bar; bar=$(make_bar "$pct" 22 "$bc")
  printf "  ${DGRAY}%-13s${RESET}  %s  ${BWHITE}%-14s${RESET}  $(dot "$dc" "$stat")\n" \
    "$lbl" "$bar" "$val"
}

# Deferred print — called at the end of Phase 3 so it appears at the bottom
print_at_a_glance() {
  echo ""
  if [ "$PERSONA" = "girly" ]; then
    printf "${BPURPLE}  🎀 AT A GLANCE${RESET}  ${DGRAY}"
  else
    printf "${BPURPLE}  AT A GLANCE${RESET}  ${DGRAY}"
  fi
  awk -v w=$(( TERM_WIDTH - 18 )) 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "${RESET}\n\n"

  glance_row "CPU load"  "$LOAD_PCT"      "$LOAD_COLOR"    "${LOAD_1M} / ${TOTAL_CORES} cores"  "$LOAD_COLOR"    "$LOAD_STATUS"
  glance_row "Memory"    "$MEM_USED_PCT"  "$MEM_COLOR"     "${MEM_FREE_PCT}% free"               "$MEM_COLOR"     "$MEM_STATUS"

  if $HAS_BATTERY; then
    glance_row "Battery"  "${CHARGE_PCT}"  "0;32"           "${CHARGE_PCT}%${CHARGE_ICON}"        "$BATT_COLOR"    "${CHARGE_STATE}"
  else
    printf "  ${DGRAY}%-13s${RESET}  ${DGRAY}%s${RESET}\n" "Battery" "not available"
  fi

  glance_row "GPU"      "${GPU_UTIL}"     "$GPU_COLOR"     "${GPU_UTIL}%"   "$GPU_COLOR" \
    "$([ "${GPU_UTIL}" -gt "${GPU_ACTIVE_THRESHOLD}" ] && echo "active" || echo "idle")"
  glance_row "Thermal"  "${THERMAL_PCT}"  "$THERMAL_COLOR" "level ${THERMAL_LEVEL}" \
    "$THERMAL_COLOR" "$THERMAL_LABEL"

  echo ""
  printf "  ${DGRAY}"
  awk -v w=$(( TERM_WIDTH - 4 )) 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "${RESET}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 3 — DETAIL SECTIONS
# ══════════════════════════════════════════════════════════════════════════════

# ── Load detail ───────────────────────────────────────────────────────────────
section "CPU Load"
if [ "$PERSONA" = "engineer" ]; then
  kv "1m / 5m / 15m" "${LOAD_1M}  ${LOAD_5M}  ${LOAD_15M}"
  kv "Cores" "${ECPU_COUNT} E-cores + ${PCPU_COUNT} P-cores"
  if float_gt "$LOAD_1M" "6"; then
    crit_line "Load is above 6 — system is under real stress."
  elif float_gt "$LOAD_1M" "4"; then
    warn_line "Load is above 4 — something is working hard."
  fi
elif [ "$PERSONA" = "girly" ]; then
  if float_gt "$LOAD_1M" "6"; then
    printf "  🚨 ${RED}not it bestie — your Mac is absolutely losing it rn${RESET} (load ${LOAD_1M})\n"
    printf "  clock the list below, something is being total ragebait\n"
  elif float_gt "$LOAD_1M" "4"; then
    printf "  🍋 ${YELLOW}lowkey stressed${RESET} (load ${LOAD_1M}) — something's giving main character energy, check below\n"
  else
    printf "  ✨ ${GREEN}we are slaying${RESET} — CPU is unbothered (load ${LOAD_1M}), understood the assignment\n"
  fi
  [ -n "${CREATIVE_APP_LIST:-}" ] && \
    printf "  ${DGRAY}creative apps detected: ${CREATIVE_APP_LIST}— elevated load is expected while working ✨${RESET}\n"
else
  if float_gt "$LOAD_1M" "6"; then
    printf "  ${RED}Your Mac is working very hard right now${RESET} (load ${LOAD_1M}).\n"
    printf "  Something is using a lot of CPU — check the list below.\n"
  elif float_gt "$LOAD_1M" "4"; then
    printf "  ${YELLOW}Busier than usual${RESET} (load ${LOAD_1M}). Things might feel a bit slow.\n"
  else
    printf "  ${GREEN}All calm${RESET} — load is ${LOAD_1M}, well within normal range.\n"
  fi
fi

# ── Memory detail ─────────────────────────────────────────────────────────────
section "Memory"
if [ "$PERSONA" = "engineer" ]; then
  kv "Total RAM"    "${TOTAL_RAM_MB} MB"
  kv "Available"    "${AVAIL_MB} MB  (${MEM_FREE_PCT}% free)"
  kv "Active"       "${ACTIVE_MB} MB"
  kv "Wired"        "${WIRED_MB} MB"
  kv "Compressed"   "${COMPRESSED_MB} MB"
  kv "Swap used"    "${SWAP_USED_MB} MB"
  kv "Swapins/outs" "${SWAPINS} / ${SWAPOUTS}"
  float_lt "$MEM_FREE_PCT" "15" && crit_line "Under 15% free — the system is swapping to disk."
  float_lt "$MEM_FREE_PCT" "30" && ! float_lt "$MEM_FREE_PCT" "15" && \
    warn_line "Under 30% free — memory pressure is elevated."
  [ "${SWAPOUTS:-0}" -gt 10000 ] && warn_line "High swap count (${SWAPOUTS}) — this Mac has been RAM-pressured for a while."
elif [ "$PERSONA" = "girly" ]; then
  printf "  ${BWHITE}${MEM_FREE_PCT}%%${RESET} free out of ${TOTAL_RAM_MB} MB"
  if float_lt "$MEM_FREE_PCT" "15"; then
    printf " — ${RED}bestie we are IN our memory crisis era 🚨${RESET}\n"
    printf "  your Mac is literally writing to disk because there's no room, it's giving 'about to crash'\n"
  elif float_lt "$MEM_FREE_PCT" "30"; then
    printf " — ${YELLOW}getting a little snacky on RAM 🍋${RESET} close a few apps maybe?\n"
  else
    printf " — ${GREEN}we ate and left no crumbs ✨${RESET}\n"
  fi
  [ "${SWAP_USED_MB:-0}" -gt 100 ] && \
    printf "  ${DGRAY}(${SWAP_USED_MB} MB spilled to disk — that's swap, your Mac is coping, try sudo purge)${RESET}\n"
  [ "${PS_HAS_PHOTOSHOP:-0}" = "1" ] && \
    printf "  ${DGRAY}tip: Photoshop is greedy with RAM by design — Edit > Purge > All clears its cache ✨${RESET}\n"
else
  printf "  You've got ${BWHITE}${MEM_FREE_PCT}%% free${RESET} out of ${TOTAL_RAM_MB} MB total"
  if float_lt "$MEM_FREE_PCT" "15"; then
    printf " — ${RED}that's very low${RESET}. Your Mac is writing to disk to compensate, which makes things slow.\n"
  elif float_lt "$MEM_FREE_PCT" "30"; then
    printf " — ${YELLOW}a bit tight${RESET}. Closing a few apps would help.\n"
  else
    printf " — ${GREEN}that's fine${RESET}.\n"
  fi
  [ "${SWAP_USED_MB:-0}" -gt 100 ] && \
    printf "  ${DGRAY}${SWAP_USED_MB} MB has spilled to disk (swap).${RESET}\n"
fi

# ── Top CPU consumers ─────────────────────────────────────────────────────────
section "What's using your CPU"
if [ "$PERSONA" = "engineer" ]; then
  printf "  ${DGRAY}%-6s  %-6s  %-8s  %s${RESET}\n" "PID" "%CPU" "RSS(MB)" "Name"
  printf "  ${DGRAY}%s${RESET}\n" "──────────────────────────────────────────"
  echo "$PS_ALL" | sort -rk2 | head -8 | awk "$AWK_NORM"'{
    pid=$1; cpu=$2; rss_mb=int($3/1024)
    color=(cpu+0>40)?"\033[0;31m":(cpu+0>15)?"\033[0;33m":"\033[0;37m"
    printf "  \033[2;37m%-6s\033[0m  %s%5s%%\033[0m  %6d MB  %s\n",pid,color,cpu,rss_mb,name
  }'
elif [ "$PERSONA" = "girly" ]; then
  printf "  ${DGRAY}clocking who's eating your CPU:${RESET}\n\n"
  echo "$PS_ALL" | sort -rk2 | head -7 | awk "$AWK_NORM"'{
    cpu=$2
    if(cpu+0>40)      icon="🚨"
    else if(cpu+0>15) icon="🍋"
    else              icon="✨"
    if(name~/Photoshop/)            tag=" — Edit > Purge > All to help"
    else if(name~/AfterFX/)         tag=" — rendering queen, she needs the CPU no cap"
    else if(name~/Figma/)           tag=" — try closing unused Figma pages"
    else if(name~/Premiere/)        tag=" — normal during export, bestie"
    else if(name~/WindowServer/)    tag=" — this is just your display, it is what it is"
    else                            tag=""
    printf "  %s  %-26s  %s%% CPU%s\n",icon,name,cpu,tag
  }'
else
  echo "$PS_ALL" | sort -rk2 | head -6 | awk "$AWK_NORM"'{
    cpu=$2; rss_mb=int($3/1024/100)*100
    icon=(cpu+0>40)?"●":(cpu+0>15)?"●":"·"
    color=(cpu+0>40)?"\033[0;31m":(cpu+0>15)?"\033[0;33m":"\033[2;37m"
    printf "  %s%s\033[0m  %-28s  %s%% CPU\n",color,icon,name,cpu
  }'
fi

# ── Top memory consumers ──────────────────────────────────────────────────────
section "What's using your RAM"
if [ "$PERSONA" = "engineer" ]; then
  printf "  ${DGRAY}%-6s  %-6s  %-8s  %s${RESET}\n" "PID" "%CPU" "RSS(MB)" "Name"
  printf "  ${DGRAY}%s${RESET}\n" "──────────────────────────────────────────"
  echo "$PS_ALL" | sort -rk3 | head -8 | awk "$AWK_NORM"'{
    pid=$1; cpu=$2; rss_mb=int($3/1024)
    color=(rss_mb>3000)?"\033[0;31m":(rss_mb>800)?"\033[0;33m":"\033[0;37m"
    printf "  \033[2;37m%-6s\033[0m  \033[2;37m%5s%%\033[0m  %s%6d MB\033[0m  %s\n",pid,cpu,color,rss_mb,name
  }'
elif [ "$PERSONA" = "girly" ]; then
  printf "  ${DGRAY}these apps are living rent free in your RAM:${RESET}\n\n"
  echo "$PS_ALL" | sort -rk3 | head -7 | awk "$AWK_NORM"'{
    rss_mb=int($3/1024)
    if(rss_mb>3000)      icon="🚨"
    else if(rss_mb>800)  icon="🍋"
    else                 icon="✨"
    if(name~/Photoshop/)          tag=" (she eats RAM, normal — purge from Edit menu)"
    else if(name~/AfterFX/)       tag=" (AE caches everything, that is her whole personality)"
    else if(name~/Safari Tab|Brave Tab/) tag=" (browser tab — close the ones you forgot about)"
    else if(name~/Lightroom/)     tag=" (Lightroom hoards previews — normal)"
    else                          tag=""
    printf "  %s  %-26s  %d MB%s\n",icon,name,rss_mb,tag
  }'
else
  echo "$PS_ALL" | sort -rk3 | head -6 | awk "$AWK_NORM"'{
    rss_mb=int($3/1024); rss_r=int($3/1024/100)*100
    icon=(rss_mb>3000)?"●":(rss_mb>800)?"●":"·"
    color=(rss_mb>3000)?"\033[0;31m":(rss_mb>800)?"\033[0;33m":"\033[2;37m"
    printf "  %s%s\033[0m  %-28s  ~%d MB\n",color,icon,name,rss_r
  }'
fi

# ── Thermal ───────────────────────────────────────────────────────────────────
section "Thermal"
if [ "$PERSONA" = "engineer" ]; then
  kv "kern.thermalevel" "${THERMAL_LEVEL}  ($(dot "$THERMAL_COLOR" "$THERMAL_LABEL"))"
  [ "${THERMAL_LEVEL}" -gt 0 ] && \
    warn_line "CPU/GPU are being clocked down to manage heat. Close heavy apps and check ventilation."
elif [ "$PERSONA" = "girly" ]; then
  if [ "${THERMAL_LEVEL}" -eq 0 ]; then
    printf "  ✨ ${GREEN}running cool, no drama${RESET} — understood the assignment\n"
  elif [ "${THERMAL_LEVEL}" -le 20 ]; then
    printf "  🍋 ${YELLOW}lowkey warm rn${RESET} — make sure vents aren't blocked (no lap pillow situation bestie)\n"
  else
    printf "  🚨 ${RED}she is BURNING UP${RESET} — Mac is throttling, that's why renders feel slow\n"
    printf "  close ${TOP_CPU_NAME} and give her a minute to cool down\n"
  fi
else
  if [ "${THERMAL_LEVEL}" -eq 0 ]; then
    printf "  ${GREEN}Running cool${RESET} — no throttling.\n"
  elif [ "${THERMAL_LEVEL}" -le 20 ]; then
    printf "  ${YELLOW}Getting warm${RESET} — performance may drop slightly. Make sure vents aren't blocked.\n"
  else
    printf "  ${RED}Actively throttling${RESET} — your chip is reducing speed to cool down.\n"
    printf "  Close the heaviest app (${TOP_CPU_NAME}) to help.\n"
  fi
fi

# ── Battery ───────────────────────────────────────────────────────────────────
section "Battery"
if $HAS_BATTERY; then
  if [ "$PERSONA" = "engineer" ]; then
    kv "Charge"       "${CHARGE_PCT}%${CHARGE_ICON}"
    _health_disp="${HEALTH_PCT}"; [ "$HEALTH_PCT" != "N/A" ] && _health_disp="${HEALTH_PCT}%"
    kv "Health"       "${_health_disp}  (${CYCLE_COUNT} cycles)"
    kv "Status"       "${CHARGE_STATE}"
    kv "Power draw"   "${POWER_W} W"
    kv "Temperature"  "${BATT_TEMP_C} °C"
    [ "${HEALTH_PCT}" != "N/A" ] && float_lt "${HEALTH_PCT}" "80" && \
      warn_line "Health below 80% — Apple recommends servicing at this point."
    [ "${CYCLE_COUNT:-0}" -gt 1000 ] 2>/dev/null && \
      warn_line "Cycle count over 1000 — past Apple's rated lifespan for M-series."
  elif [ "$PERSONA" = "girly" ]; then
    if   [ "${CHARGE_STATE}" = "charging" ]; then
      printf "  ✨ ${GREEN}${CHARGE_PCT}%% and charging${RESET} — power queen behavior ⚡\n"
    elif [ "${CHARGE_STATE}" = "plugged in" ]; then
      printf "  ⚡ ${GREEN}plugged in at ${CHARGE_PCT}%%${RESET} — we love a girlboss who stays powered\n"
    elif [ "${CHARGE_PCT}" -lt 15 ] 2>/dev/null; then
      printf "  🚨 ${RED}${CHARGE_PCT}%% BESTIE PLUG IN NOW${RESET}\n"
    elif [ "${CHARGE_PCT}" -lt 30 ] 2>/dev/null; then
      printf "  🍋 ${YELLOW}${CHARGE_PCT}%% on battery${RESET} — slay but also maybe find an outlet soon\n"
    else
      printf "  ✨ ${GREEN}${CHARGE_PCT}%% on battery${RESET} — we're good\n"
    fi
    if [ "${HEALTH_PCT}" != "N/A" ]; then
      if float_lt "${HEALTH_PCT}" "80"; then
        printf "  ${RED}battery health is ${HEALTH_PCT}%% — that's giving 'needs therapy' energy 🚨${RESET}\n"
        printf "  ${DGRAY}${CYCLE_COUNT} cycles — Apple recommends service below 80%${RESET}\n"
      else
        printf "  ${DGRAY}health ${HEALTH_PCT}%% (${CYCLE_COUNT} cycles) — she's holding up ✨${RESET}\n"
      fi
    fi
    printf "  ${DGRAY}temp ${BATT_TEMP_C}°C  ·  ${POWER_W} W draw${RESET}\n"
  else
    printf "  Battery is at ${BWHITE}${CHARGE_PCT}%%${RESET}${CHARGE_ICON}"
    printf ", ${CHARGE_STATE}. "
    if   [ "${HEALTH_PCT}" != "N/A" ] && float_lt "${HEALTH_PCT}" "80"; then
      printf "${RED}Health is ${HEALTH_PCT}%% — worth getting checked.${RESET}\n"
    elif [ "${HEALTH_PCT}" != "N/A" ] && float_lt "${HEALTH_PCT}" "90"; then
      printf "${YELLOW}Health is ${HEALTH_PCT}%% — starting to age.${RESET}\n"
    elif [ "${HEALTH_PCT}" != "N/A" ]; then
      printf "${GREEN}Health is ${HEALTH_PCT}%% — in great shape.${RESET}\n"
    else
      printf "${GREEN}Healthy.${RESET}\n"
    fi
    printf "  ${DGRAY}${CYCLE_COUNT} charge cycles  ·  ${POWER_W} W  ·  ${BATT_TEMP_C} °C${RESET}\n"
  fi
else
  printf "  ${DGRAY}No battery detected.${RESET}\n"
fi

# ── GPU ───────────────────────────────────────────────────────────────────────
section "GPU"
GPU_RENDERER=$(ioreg -r -c IOAccelerator 2>/dev/null | awk -F'"' '/IOClass/{print $4; exit}')
: "${GPU_RENDERER:=Apple GPU}"
if [ "$PERSONA" = "engineer" ]; then
  kv "Renderer"     "${GPU_RENDERER}"
  _gpu_label="idle"; [ "${GPU_UTIL}" -gt "${GPU_ACTIVE_THRESHOLD}" ] && _gpu_label="active"
  [ "${_display_count:-1}" -gt 1 ] && _gpu_label="${_gpu_label} (threshold ${GPU_ACTIVE_THRESHOLD}% w/ ${_display_count} displays)"
  kv "Utilization"  "${GPU_UTIL}%  ($(dot "$GPU_COLOR" "$_gpu_label"))"
  if [ "$(id -u)" -eq 0 ]; then
    PM_GPU=$(powermetrics --samplers gpu_power -n 1 -i 1000 2>/dev/null || true)
    kv "Power"       "$(echo "$PM_GPU" | awk '/^GPU Power:/{print $NF}')"
    kv "Bandwidth"   "$(echo "$PM_GPU" | awk '/GPU bandwidth:/{print $NF}') GBps"
  else
    printf "  ${DGRAY}Power and bandwidth: sudo required${RESET}\n"
  fi
elif [ "$PERSONA" = "girly" ]; then
  printf "  GPU is at ${BWHITE}${GPU_UTIL}%%${RESET}"
  if [ "${GPU_UTIL}" -gt "${GPU_ACTIVE_THRESHOLD}" ]; then
    printf " — ${YELLOW}she's working 🍋${RESET}\n"
    [ "${PS_HAS_AE:-0}" = "1" ] && \
      printf "  ${DGRAY}After Effects is rendering — GPU is doing its job bestie, this is fine ✨${RESET}\n"
    [ "${_display_count:-1}" -gt 1 ] && \
      printf "  ${DGRAY}(${_display_count} displays = higher baseline, clock it)${RESET}\n"
  else
    printf " — ${GREEN}just vibing ✨${RESET}\n"
  fi
else
  printf "  GPU load is ${BWHITE}${GPU_UTIL}%%${RESET}"
  [ "${GPU_UTIL}" -gt "${GPU_ACTIVE_THRESHOLD}" ] && \
    printf " — ${YELLOW}actively working${RESET}.\n" || printf " — ${GREEN}idle${RESET}.\n"
fi

# ── Network ───────────────────────────────────────────────────────────────────
section "Network"
# Take T1 reading and write to a temp file — awk -v strips embedded newlines from
# multi-line strings, so we use getline from a file instead.
_NET_TMP=$(mktemp /tmp/mhk_net.XXXXXX)
netstat -ib 2>/dev/null > "$_NET_TMP" || true
T1=$(date '+%s')
ELAPSED=$(( T1 - T0 )); [ "$ELAPSED" -lt 1 ] && ELAPSED=1

echo "$NETSTAT_T0" | awk \
  -v t1_file="$_NET_TMP" \
  -v elapsed="$ELAPSED" \
  -v persona="$PERSONA" '
BEGIN{
  # Read T1 snapshot: match rows where $3 is a Link or IP row (col 7 = Ibytes, col 10 = Obytes)
  while ((getline line < t1_file) > 0) {
    n = split(line, f)
    if (n >= 10 && f[1] !~ /^Name/ && f[1] != "") {
      ib1[f[1]] = f[7]+0; ob1[f[1]] = f[10]+0
    }
  }
}
# Match Link-level rows (have byte counters) for en* and utun*
/^(en|utun)[0-9]/ && $3 ~ /<Link/ {
  iface=$1; ib0=$7+0; ob0=$10+0
  if (iface in ib1) {
    din  = int((ib1[iface]-ib0)/elapsed/1024); if (din  < 0) din  = 0
    dout = int((ob1[iface]-ob0)/elapsed/1024); if (dout < 0) dout = 0
    if (din == 0 && dout == 0) next  # skip idle interfaces
    if (persona == "engineer")
      printf "  \033[2;37m%-8s\033[0m  \xe2\x86\x93 \033[1;37m%d\033[0m KB/s   \xe2\x86\x91 %d KB/s\n", \
        iface, din, dout
    else if (persona == "girly")
      printf "  %-8s  \xf0\x9f\x93\xa5 %d KB/s in   \xf0\x9f\x93\xa4 %d KB/s out\n", iface, din, dout
    else
      printf "  %-8s  \xe2\x86\x93 %d KB/s   \xe2\x86\x91 %d KB/s\n", iface, din, dout
  }
}' 2>/dev/null || true
rm -f "$_NET_TMP"

# ── Energy impact ─────────────────────────────────────────────────────────────
section "Energy Impact" "Activity Monitor score — higher = more battery drain"
ENERGY_OUT=$(top -stats pid,command,power -l 1 -o power -n 8 2>/dev/null || true)
if [ -n "$ENERGY_OUT" ]; then
  if [ "$PERSONA" = "engineer" ]; then
    printf "  ${DGRAY}%-6s  %-30s  %s${RESET}\n" "PID" "Name" "Score"
    printf "  ${DGRAY}%s${RESET}\n" "──────────────────────────────────────────"
    echo "$ENERGY_OUT" | awk '/^[0-9]+[[:space:]]/ && $1~/^[0-9]+$/{
      cmd=$2; if(cmd~/WebContent/)cmd="Safari Tab"; if(cmd~/BraveRenderer/)cmd="Brave Tab"
      color=(($NF+0)>100)?"\033[0;31m":(($NF+0)>30)?"\033[0;33m":"\033[2;37m"
      printf "  \033[2;37m%-6s\033[0m  %-30s  %s%s\033[0m\n",$1,cmd,color,$NF
    }'
  elif [ "$PERSONA" = "girly" ]; then
    printf "  ${DGRAY}battery drain leaderboard (lower = better):${RESET}\n\n"
    echo "$ENERGY_OUT" | awk '/^[0-9]+[[:space:]]/ && $1~/^[0-9]+$/{
      cmd=$2; if(cmd~/WebContent/)cmd="Safari Tab"; if(cmd~/BraveRenderer/)cmd="Brave Tab"
      if($NF+0>100)      icon="🚨"
      else if($NF+0>30)  icon="🍋"
      else               icon="✨"
      printf "  %s  %-28s  score: %s\n",icon,cmd,$NF
    }'
  else
    echo "$ENERGY_OUT" | awk '/^[0-9]+[[:space:]]/ && $1~/^[0-9]+$/{
      cmd=$2; if(cmd~/WebContent/)cmd="Safari Tab"; if(cmd~/BraveRenderer/)cmd="Brave Tab"
      color=(($NF+0)>100)?"\033[0;31m":(($NF+0)>30)?"\033[0;33m":"\033[2;37m"
      printf "  %s%-28s\033[0m  %s%s\033[0m\n",color,cmd,color,$NF
    }'
  fi
else
  printf "  ${DGRAY}Energy data unavailable.${RESET}\n"
fi

# ── Background agents ─────────────────────────────────────────────────────────
section "Background Agents"
_agents=$(launchctl list 2>/dev/null \
  | awk 'NR>1 && $3!~/^-$/ && $3!~/^com\.apple\./ && $3!~/^application\.com\.apple\./ \
         && $3!~/^com\.openssh/ && $3!~/^org\./' \
  | head -12)
if [ -n "$_agents" ]; then
  if [ "$PERSONA" = "engineer" ]; then
    printf "  ${DGRAY}%-8s  %-6s  %s${RESET}\n" "PID" "Exit" "Label"
    printf "  ${DGRAY}%s${RESET}\n" "──────────────────────────────────────────"
    echo "$_agents" | awk '{printf "  \033[2;37m%-8s  %-6s\033[0m  %s\n",$1,$2,$3}'
  elif [ "$PERSONA" = "girly" ]; then
    printf "  ${DGRAY}apps running in the background (the sneaky ones):${RESET}\n\n"
    echo "$_agents" | awk '{
      # Skip trailing numeric segments (e.g. application.com.foo.AppName.12345.67890)
      n=split($3,p,"."); name=p[n]
      for(i=n;i>=1;i--){ if(p[i]+0==0 && p[i]!="0"){ name=p[i]; break } }
      if($1!="-") printf "  \xe2\x9c\xa8  %-28s  running\n",name
      else        printf "  \xf0\x9f\x8d\x8b  %-28s  not running\n",name
    }'
  else
    echo "$_agents" | awk '{
      n=split($3,p,"."); name=p[n]
      for(i=n;i>=1;i--){ if(p[i]+0==0 && p[i]!="0"){ name=p[i]; break } }
      running=($1!="-")?"running":"not running"
      printf "  \033[2;37m·\033[0m  %-28s  \033[2;37m%s\033[0m\n",name,running
    }'
  fi
else
  if [ "$PERSONA" = "girly" ]; then
    printf "  ✨ ${DGRAY}no sneaky background apps detected, we're clean${RESET}\n"
  else
    printf "  ${DGRAY}No third-party agents running.${RESET}\n"
  fi
fi

# ── SoC Power (root only) ─────────────────────────────────────────────────────
section "SoC Power" "sudo required"
if [ "$(id -u)" -eq 0 ]; then
  PM_ALL=$(powermetrics --samplers cpu_power,gpu_power -n 1 -i 1000 2>/dev/null || true)
  if [ -n "$PM_ALL" ]; then
    _cpu_p=$(echo "$PM_ALL" | awk '/^CPU Power:/{print $NF}')
    _gpu_p=$(echo "$PM_ALL" | awk '/^GPU Power:/{print $NF}')
    _ane_p=$(echo "$PM_ALL" | awk '/^ANE Power:/{print $NF}')
    _drm_p=$(echo "$PM_ALL" | awk '/^DRAM Power:/{print $NF}')
    _pkg_p=$(echo "$PM_ALL" | awk '/^Package Power:/{print $NF}')
    _ec_f=$(echo  "$PM_ALL" | awk '/E-Cluster HW active frequency:/{print $NF}')
    _ec_r=$(echo  "$PM_ALL" | awk '/E-Cluster HW active residency:/{print $NF}')
    _pc_f=$(echo  "$PM_ALL" | awk '/P-Cluster HW active frequency:/{print $NF}')
    _pc_r=$(echo  "$PM_ALL" | awk '/P-Cluster HW active residency:/{print $NF}')

    kv "Package (total)" "${_pkg_p:-N/A}"
    kv "CPU / GPU"       "${_cpu_p:-N/A}  /  ${_gpu_p:-N/A}"
    kv "ANE / DRAM"      "${_ane_p:-N/A}  /  ${_drm_p:-N/A}"
    echo ""
    kv "E-cluster"  "${_ec_r:-N/A} active  @  ${_ec_f:-N/A} MHz"
    kv "P-cluster"  "${_pc_r:-N/A} active  @  ${_pc_f:-N/A} MHz"
  fi
else
  printf "  ${DGRAY}Run with sudo to see E/P cluster split, ANE, DRAM, and package power.${RESET}\n"
fi

# ── At a glance — printed here so it's always visible without scrolling ───────
print_at_a_glance

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 4 — SUGGESTED ACTIONS  (only shown when thresholds are crossed)
# ══════════════════════════════════════════════════════════════════════════════

# Collect triggered issues
_issues=""
_safe_cmds=""
_careful_cmds=""

# ── Helper to add a safe command ──────────────────────────────────────────────
add_safe() {
  # add_safe <command> <what it does>
  _safe_cmds="${_safe_cmds}CMD:$1|DESC:$2||"
}
add_careful() {
  # add_careful <command> <what it does> <warning>
  _careful_cmds="${_careful_cmds}CMD:$1|DESC:$2|WARN:$3||"
}
add_issue() { _issues="${_issues}  · $1\n"; }

# ── Memory low ────────────────────────────────────────────────────────────────
if float_lt "$MEM_FREE_PCT" "30"; then
  add_issue "Memory is ${MEM_FREE_PCT}% free"
  add_safe \
    "sudo purge" \
    "Flushes inactive file cache from RAM. Apps just reload what they need — no data lost."

  # Top memory hog (if not a system process)
  _top_is_system=$(echo "$TOP_MEM_NAME" | grep -cE '^(kernel|sysmond|WindowServer|launchd|loginwindow)$' || echo 0)
  if [ "${_top_is_system:-1}" -eq 0 ] && [ -n "$TOP_MEM_NAME" ]; then
    add_careful \
      "kill -9 ${TOP_MEM_PID}   # ${TOP_MEM_NAME}  (${TOP_MEM_MB} MB)" \
      "Force-quits ${TOP_MEM_NAME} and immediately frees ~${TOP_MEM_MB} MB." \
      "Any unsaved work in ${TOP_MEM_NAME} will be lost. Save first if you can."
  fi
fi

# ── High swap ─────────────────────────────────────────────────────────────────
if [ "${SWAP_USED_MB:-0}" -gt 500 ]; then
  add_issue "Swap is at ${SWAP_USED_MB} MB (RAM has been overflowing)"
  # purge already added if memory is low, avoid duplicate
  echo "$_safe_cmds" | grep -q "sudo purge" || \
    add_safe "sudo purge" "Flushes disk cache. Often brings swap usage down within seconds."
fi

# ── Swapout count high ────────────────────────────────────────────────────────
if [ "${SWAPOUTS:-0}" -gt 20000 ]; then
  add_issue "High swap event count (${SWAPOUTS}) — RAM pressure has been ongoing"
fi

# ── High load ─────────────────────────────────────────────────────────────────
if float_gt "$LOAD_1M" "4"; then
  if [ "${MHK_POWER_SOURCE:-unknown}" = "battery" ]; then
    add_issue "CPU load is ${LOAD_1M} — on battery, this is draining charge faster"
  else
    add_issue "CPU load is ${LOAD_1M} (threshold: 4)"
  fi
  _top_is_system=$(echo "$TOP_CPU_NAME" | grep -cE '^(kernel|sysmond|WindowServer|launchd|loginwindow)$' || echo 0)
  if [ "${_top_is_system:-1}" -eq 0 ] && [ -n "$TOP_CPU_NAME" ]; then
    add_careful \
      "kill -9 ${TOP_CPU_PID}   # ${TOP_CPU_NAME}  (${TOP_CPU_PCT}% CPU)" \
      "Force-quits ${TOP_CPU_NAME}. Should bring load down immediately." \
      "Any unsaved work in ${TOP_CPU_NAME} will be lost."
  fi
fi

# ── Spotlight overload ────────────────────────────────────────────────────────
if [ "${SPOT_COUNT:-0}" -gt 8 ]; then
  add_issue "Spotlight has ${SPOT_COUNT} worker processes (threshold: 8)"
  add_safe \
    "killall -9 mds_stores mdworker" \
    "Stops Spotlight indexing immediately. It will restart on its own. Safe to run."
  add_safe \
    "sudo mdutil -a -i off && sudo mdutil -a -i on" \
    "Disables then re-enables indexing — resets a stuck indexer. Takes a second."
fi

# ── iCloud bird ───────────────────────────────────────────────────────────────
if float_gt "${BIRD_CPU}" "20"; then
  add_issue "iCloud Sync (bird) is using ${BIRD_CPU}% CPU"
  add_safe \
    "killall bird" \
    "Restarts the iCloud sync daemon. It comes back automatically. Clears most stuck-sync situations."
fi

# ── VPN high memory ───────────────────────────────────────────────────────────
if [ "${VPN_RSS_MB:-0}" -gt 400 ]; then
  add_issue "${VPN_NAME} is holding ${VPN_RSS_MB} MB"
  add_careful \
    "killall ${VPN_NAME}" \
    "Force-quits the VPN client and frees ~${VPN_RSS_MB} MB." \
    "You'll lose your VPN connection. Reconnect from the app afterwards."
fi

# ── Docker ────────────────────────────────────────────────────────────────────
if float_gt "${DOCKER_CPU}" "10"; then
  add_issue "Docker is using ${DOCKER_CPU}% CPU combined"
  add_safe \
    "docker stats --no-stream" \
    "Shows which container is responsible. Run this first to identify the culprit."
  add_careful \
    "docker stop \$(docker ps -q)" \
    "Stops all running containers." \
    "This stops every container. Any work in non-persistent containers will be lost."
fi

# ── Thermal throttling ────────────────────────────────────────────────────────
if [ "${THERMAL_LEVEL}" -gt 0 ]; then
  add_issue "Thermal throttling is active (level ${THERMAL_LEVEL})"
  _top_is_system=$(echo "$TOP_CPU_NAME" | grep -cE '^(kernel|sysmond|WindowServer|launchd|loginwindow)$' || echo 0)
  if [ "${_top_is_system:-1}" -eq 0 ]; then
    add_careful \
      "kill -9 ${TOP_CPU_PID}   # ${TOP_CPU_NAME}" \
      "Removing the top CPU user should let the chip cool down and stop throttling." \
      "Unsaved work in ${TOP_CPU_NAME} will be lost."
  fi
  add_safe \
    "pmset -g thermlog | tail -20" \
    "Shows the recent thermal event log so you can see how long it's been happening."
fi

# ── Heavy browser tabs ────────────────────────────────────────────────────────
if [ -n "${HEAVY_TABS:-}" ]; then
  add_issue "One or more browser tabs are using over 500 MB each"
  add_careful \
    "osascript -e 'quit app \"Safari\"'" \
    "Quits Safari and closes all its tabs. Often frees several GB immediately." \
    "Any open tabs will be lost unless Safari has session restore enabled (it does by default)."
fi

# ── Only render this block if there's something to say ───────────────────────
if [ -n "$_issues" ] || [ -n "$_safe_cmds" ] || [ -n "$_careful_cmds" ]; then
  echo ""
  printf "${DGRAY}"
  awk -v w="$TERM_WIDTH" 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "${RESET}"
  echo ""

  if [ "$PERSONA" = "girly" ]; then
    printf "${BPURPLE}  🎀 BESTIE YOUR MAC NEEDS ATTENTION${RESET}\n"
    echo ""
    printf "  ${DGRAY}okay so here's the tea:${RESET}\n"
  else
    printf "${BPURPLE}  SUGGESTED ACTIONS${RESET}\n"
    echo ""
    printf "  ${DGRAY}Things worth looking at:${RESET}\n"
  fi
  printf "%b" "$_issues"

  if [ -n "$_safe_cmds" ]; then
    echo ""
    if [ "$PERSONA" = "girly" ]; then
      printf "  ${BGREEN}✨ safe to run, no drama:${RESET}\n"
    else
      printf "  ${BGREEN}Safe to run — no data loss:${RESET}\n"
    fi
    printf '%s' "$_safe_cmds" | tr '|' '\n' | awk '
      /^CMD:/ { cmd=substr($0,5); printf "\n  \033[1;37m  %s\033[0m\n", cmd }
      /^DESC:/{ printf "  \033[2;37m  %s\033[0m\n", substr($0,6) }
    '
  fi

  if [ -n "$_careful_cmds" ]; then
    echo ""
    if [ "$PERSONA" = "girly" ]; then
      printf "  ${BYELLOW}🍋 these could cause a moment, read first bestie:${RESET}\n"
    else
      printf "  ${BYELLOW}Use with care — read the warning first:${RESET}\n"
    fi
    printf '%s' "$_careful_cmds" | tr '|' '\n' | awk '
      /^CMD:/ { cmd=substr($0,5); printf "\n  \033[1;37m  %s\033[0m\n", cmd }
      /^DESC:/{ printf "  \033[2;37m  %s\033[0m\n", substr($0,6) }
      /^WARN:/{ printf "  \033[0;33m  ⚠  %s\033[0m\n", substr($0,6) }
    '
  fi
  echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
#  FOOTER
# ══════════════════════════════════════════════════════════════════════════════
echo ""
printf "${DGRAY}"
awk -v w="$TERM_WIDTH" 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
printf "${RESET}\n"
printf "  ${DGRAY}Weekly trends: bash scripts/mac_weekly_report.sh   Disk growth: bash scripts/mac_disk_diff.sh${RESET}\n"
echo ""
