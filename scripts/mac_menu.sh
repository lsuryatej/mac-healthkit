#!/usr/bin/env bash
# mac_menu.sh — Interactive menu for mac-healthkit
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour palette (same as mac_check.sh) ────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
PURPLE='\033[38;5;135m'; BPURPLE='\033[1;38;5;135m'
GREEN='\033[0;32m';  BGREEN='\033[1;32m'
YELLOW='\033[0;33m'; BYELLOW='\033[1;33m'
RED='\033[0;31m';    CYAN='\033[0;36m'
BWHITE='\033[1;37m'; DGRAY='\033[2;37m'

TERM_W=$(tput cols 2>/dev/null || echo 80)

# ── Detected context (populated by detect_context) ───────────────────────────
MHK_POWER_SOURCE="unknown"
MHK_DISPLAY_COUNT=1
MHK_FRESH_WAKE=0
export MHK_POWER_SOURCE MHK_DISPLAY_COUNT MHK_FRESH_WAKE

# Session state
PERSONA=""           # set when user picks a style
LAST_RUN_TIME=""

# ── Helpers ───────────────────────────────────────────────────────────────────
sep() {
  printf "${DGRAY}"
  awk -v w="$TERM_W" 'BEGIN{for(i=0;i<w;i++) printf "─"; print ""}'
  printf "${RESET}"
}

# Prompt that always reads from the real tty
ask() {
  local prompt="${1:-▶}"
  printf "\n  ${BPURPLE}${prompt}${RESET}  " >&2
  local ans
  IFS= read -r ans < /dev/tty
  printf '%s' "$ans"
}

# ── Context detection — runs once at startup ──────────────────────────────────
detect_context() {
  # Power source
  if pmset -g batt 2>/dev/null | grep -q "AC Power"; then
    MHK_POWER_SOURCE="ac"
  else
    MHK_POWER_SOURCE="battery"
  fi

  # Number of active displays (each "Resolution:" line = one display)
  MHK_DISPLAY_COUNT=$(system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -c "Resolution:" || true)
  [ "${MHK_DISPLAY_COUNT:-0}" -lt 1 ] && MHK_DISPLAY_COUNT=1

  # Fresh wake: if system has been up less than 2 minutes, metrics may be spiked
  local _boot _now _uptime_s
  _boot=$(sysctl -n kern.boottime 2>/dev/null \
    | grep -oE 'sec = [0-9]+' | awk '{print $3}' || echo 0)
  _now=$(date '+%s')
  _uptime_s=$(( _now - ${_boot:-_now} ))
  [ "${_uptime_s:-9999}" -lt 120 ] && MHK_FRESH_WAKE=1 || MHK_FRESH_WAKE=0

  export MHK_POWER_SOURCE MHK_DISPLAY_COUNT MHK_FRESH_WAKE
}

# ── Context banner line ───────────────────────────────────────────────────────
context_line() {
  local power_s disp_s wake_s=""
  [ "${MHK_POWER_SOURCE}" = "ac" ] \
    && power_s="⚡ plugged in" \
    || power_s="🔋 on battery"

  [ "${MHK_DISPLAY_COUNT}" -gt 1 ] \
    && disp_s="${MHK_DISPLAY_COUNT} displays" \
    || disp_s="1 display"

  [ "${MHK_FRESH_WAKE}" = "1" ] && wake_s="  ·  just woken"

  printf "  ${DGRAY}${power_s}  ·  ${disp_s}${wake_s}${RESET}\n"
}

# ── Persona picker ────────────────────────────────────────────────────────────
pick_persona() {
  echo ""
  printf "  ${BWHITE}Output style?${RESET}\n\n"
  printf "  ${BWHITE}1${RESET}  ${BWHITE}Engineer${RESET}      ${DGRAY}raw numbers, PIDs, exact data${RESET}\n"
  printf "  ${BWHITE}2${RESET}  ${BWHITE}Plain English${RESET}  ${DGRAY}friendly language, traffic lights${RESET}\n"
  printf "  ${BWHITE}3${RESET}  ${BWHITE}Girly Pop 🎀${RESET}   ${DGRAY}creative-first, good vibes, PS/AE/Figma aware${RESET}\n"
  local p; p=$(ask "▶")
  case "${p}" in
    2) PERSONA="plaintext" ;;
    3) PERSONA="girlypop"  ;;
    *) PERSONA="engineer"  ;;
  esac
}

# ── Run health check ──────────────────────────────────────────────────────────
run_check() {
  [ -z "$PERSONA" ] && pick_persona
  echo ""
  sep
  bash "${SCRIPT_DIR}/mac_check.sh" --persona "${PERSONA}"
  sep
  LAST_RUN_TIME=$(date '+%H:%M:%S')
}

# ── Run weekly report ─────────────────────────────────────────────────────────
run_weekly() {
  echo ""
  sep
  bash "${SCRIPT_DIR}/mac_weekly_report.sh"
  sep
}

# ── Run disk diff ─────────────────────────────────────────────────────────────
run_disk() {
  echo ""
  sep
  if bash "${SCRIPT_DIR}/mac_disk_diff.sh" 2>&1; then
    true
  else
    printf "  ${YELLOW}mac_disk_diff.sh not found or failed.${RESET}\n"
  fi
  sep
}

# ── Quick fixes ───────────────────────────────────────────────────────────────
# Format: "LABEL|COMMAND|DESCRIPTION|WARNING"
# WARNING is empty for safe fixes.

FIXES_SAFE=(
  "Flush RAM cache|sudo purge|Clears inactive file cache. Apps just reload what they need — nothing is lost."
  "Stop Spotlight workers|killall -9 mds_stores mdworker|Stops the indexing workers immediately. They restart on their own within seconds."
  "Restart iCloud sync|killall bird|Restarts the iCloud daemon. Fixes most stuck-sync situations. Resumes automatically."
  "Show thermal log|pmset -g thermlog | tail -20|Displays the last 20 thermal events so you can see how long throttling has been happening."
  "Live process view|top -o cpu|Opens a live process monitor sorted by CPU. Press Q to exit."
  "Check disk space|df -h ~ | tail -1|Shows how much space is left on your main drive."
)

FIXES_CAREFUL=(
  "Stop all Docker containers|docker stop \$(docker ps -q)|Stops every running container.|Non-persistent container state will be lost. Only run this if you know what's running."
  "Quit Safari (free tab RAM)|osascript -e 'quit app \"Safari\"'|Closes Safari and releases all tab memory — often frees several GB instantly.|Open tabs close. Safari will offer to restore them on next launch (it does this by default)."
  "Reset Spotlight index|sudo mdutil -a -i off && sudo mdutil -a -i on|Disables then re-enables Spotlight. Resets a stuck or overloaded indexer.|Spotlight search will be unavailable for a few minutes while it reindexes."
  "Kill Notion GPU helper|killall 'Notion Helper (GPU)'|Force-quits the Notion GPU polling process. Notion stays open — just restart it.|Notion may need to be reopened. Any unsaved content in Notion could be affected."
)

quick_fixes_menu() {
  while true; do
    echo ""
    sep
    echo ""
    printf "  ${BGREEN}Safe to run — no data loss:${RESET}\n\n"

    local i=1
    for fix in "${FIXES_SAFE[@]}"; do
      local label="${fix%%|*}"
      local rest="${fix#*|}"; local cmd="${rest%%|*}"; local desc="${rest#*|}"
      printf "  ${BWHITE}%d${RESET}  %-30s  ${DGRAY}%s${RESET}\n" "$i" "$label" "$cmd"
      i=$(( i + 1 ))
    done

    echo ""
    printf "  ${BYELLOW}Use with care — read the warning first:${RESET}\n\n"

    local j=$i
    for fix in "${FIXES_CAREFUL[@]}"; do
      local label="${fix%%|*}"
      local rest="${fix#*|}"; local cmd="${rest%%|*}"; local rest2="${rest#*|}"; local warn="${rest2#*|}"
      printf "  ${BWHITE}%d${RESET}  %-30s  ${YELLOW}⚠  %s${RESET}\n" "$j" "$label" "$warn"
      j=$(( j + 1 ))
    done

    echo ""
    printf "  ${BWHITE}0${RESET}  ${DGRAY}Back${RESET}\n"

    local choice; choice=$(ask "▶")
    [ "${choice}" = "0" ] && return

    # Validate
    if ! [[ "${choice}" =~ ^[0-9]+$ ]]; then
      printf "  ${YELLOW}Type a number from the list.${RESET}\n"
      continue
    fi

    local idx=$(( choice - 1 ))
    local n_safe=${#FIXES_SAFE[@]}
    local n_careful=${#FIXES_CAREFUL[@]}

    if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n_safe" ]; then
      _run_fix "${FIXES_SAFE[$idx]}" "safe"
    elif [ "$idx" -ge "$n_safe" ] && [ "$idx" -lt $(( n_safe + n_careful )) ]; then
      _run_fix "${FIXES_CAREFUL[$(( idx - n_safe ))]}" "careful"
    else
      printf "  ${YELLOW}Invalid choice.${RESET}\n"
    fi
  done
}

_run_fix() {
  local fix_entry="$1" kind="$2"
  local label="${fix_entry%%|*}"
  local rest="${fix_entry#*|}"; local cmd="${rest%%|*}"
  local rest2="${rest#*|}"; local desc="${rest2%%|*}"; local warn="${rest2#*|}"
  [ "$warn" = "$desc" ] && warn=""  # safe fix: no warning field

  echo ""
  printf "  ${BWHITE}About to run:${RESET}  ${DGRAY}%s${RESET}\n\n" "$label"
  printf "  ${CYAN}  %s${RESET}\n\n" "$cmd"
  printf "  ${DGRAY}  %s${RESET}\n" "$desc"
  [ -n "$warn" ] && printf "\n  ${YELLOW}  ⚠  %s${RESET}\n" "$warn"

  local confirm; confirm=$(ask "Confirm? [y/N]")
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) printf "  ${DGRAY}Skipped.${RESET}\n"; return ;;
  esac

  echo ""
  sep
  eval "$cmd"
  local exit_code=$?
  sep

  if [ "$exit_code" -eq 0 ]; then
    printf "  ${BGREEN}✓ Done.${RESET}\n"
  else
    printf "  ${YELLOW}⚠ Command finished with exit code ${exit_code}.${RESET}\n"
  fi

  echo ""
  printf "  ${BWHITE}1${RESET}  Re-run health check to see the effect\n"
  printf "  ${BWHITE}2${RESET}  Run another fix\n"
  printf "  ${BWHITE}0${RESET}  Back\n"
  local next; next=$(ask "▶")
  case "$next" in
    1) run_check; post_run_menu ;;
    2) return ;;
    *) return ;;
  esac
}

# ── Post-run menu (shown after any diagnostic completes) ─────────────────────
post_run_menu() {
  while true; do
    echo ""
    printf "  ${DGRAY}Last run: %s${RESET}\n\n" "${LAST_RUN_TIME:-just now}"
    printf "  ${BWHITE}1${RESET}  Re-run the check\n"
    printf "  ${BWHITE}2${RESET}  Re-run in plain English\n"
    printf "  ${BWHITE}3${RESET}  Re-run in engineer mode\n"
    printf "  ${BWHITE}4${RESET}  Re-run in girlypop 🎀\n"
    printf "  ${BWHITE}5${RESET}  Try a quick fix\n"
    printf "  ${BWHITE}6${RESET}  Main menu\n"
    printf "  ${BWHITE}Q${RESET}  Quit\n"

    local choice; choice=$(ask "▶")
    case "$choice" in
      1) run_check ;;
      2) PERSONA="plaintext"; run_check ;;
      3) PERSONA="engineer";  run_check ;;
      4) PERSONA="girlypop";  run_check ;;
      5) quick_fixes_menu ;;
      6) return ;;
      q|Q) echo ""; exit 0 ;;
      *) printf "  ${YELLOW}Type a number from the list.${RESET}\n" ;;
    esac
  done
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    echo ""
    printf "${BPURPLE}  mac-healthkit${RESET}  ${DGRAY}$(date '+%a %b %-d  ·  %H:%M')${RESET}\n"
    context_line
    echo ""
    sep
    echo ""
    printf "  ${BWHITE}1${RESET}  Health check            ${DGRAY}full diagnostic snapshot${RESET}\n"
    printf "  ${BWHITE}2${RESET}  Weekly trend report     ${DGRAY}read from your log history${RESET}\n"
    printf "  ${BWHITE}3${RESET}  Disk growth check       ${DGRAY}what's eating ~/Library space${RESET}\n"
    printf "  ${BWHITE}4${RESET}  Quick fixes             ${DGRAY}safe commands to try now${RESET}\n"
    printf "  ${BWHITE}Q${RESET}  Quit\n"

    local choice; choice=$(ask "▶")
    case "$choice" in
      1) run_check; post_run_menu ;;
      2) run_weekly ;;
      3) run_disk ;;
      4) quick_fixes_menu ;;
      q|Q) echo ""; exit 0 ;;
      *) printf "  ${YELLOW}Type a number from the list above.${RESET}\n" ;;
    esac
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────
detect_context
main_menu
