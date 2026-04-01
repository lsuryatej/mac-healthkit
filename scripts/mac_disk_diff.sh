#!/usr/bin/env bash
# mac_disk_diff.sh — Snapshot ~/Library subdirs and diff vs last snapshot
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

SNAP_DIR="$HOME/.mac-healthkit/snapshots"
mkdir -p "$SNAP_DIR"

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
  BOLD='\033[1m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BOLD=''; CYAN=''; RESET=''
fi

TODAY=$(date '+%Y-%m-%d')
SNAP_TODAY="$SNAP_DIR/disk_${TODAY}.txt"

echo -e "${BOLD}${CYAN}mac-healthkit / Disk Diff${RESET}  $TODAY"
echo "════════════════════════════════════════════════════"

# ── Take today's snapshot ─────────────────────────────────────────────────────
echo "Scanning ~/Library (this may take a moment)..."
du -sh "$HOME/Library"/*/  2>/dev/null | sort -rh > "$SNAP_TODAY" || true
echo "Snapshot saved: $SNAP_TODAY"

# ── Find previous snapshot ────────────────────────────────────────────────────
PREV_SNAP=$(ls -1 "$SNAP_DIR"/disk_*.txt 2>/dev/null | grep -v "$SNAP_TODAY" | sort | tail -1 || true)

if [ -z "$PREV_SNAP" ]; then
  echo ""
  echo "This is your first snapshot. Run this script again next week to see what grew."
  echo ""
  echo "Current top 15 directories in ~/Library:"
  head -15 "$SNAP_TODAY"
  exit 0
fi

PREV_DATE=$(basename "$PREV_SNAP" | sed 's/disk_//' | sed 's/.txt//')
echo "Comparing against: $PREV_SNAP  ($PREV_DATE)"
echo ""

# ── Convert du sizes to bytes for comparison ──────────────────────────────────
# du -sh gives human sizes (G/M/K); we need numbers.
# We'll parse both snapshots into "bytes path" format using awk.

parse_snapshot() {
  local file="$1"
  awk '{
    size=$1; path=$2
    # strip trailing slash
    sub(/\/$/, "", path)
    # convert to KB for numeric comparison
    val=size
    unit=substr(size, length(size))
    num=substr(size, 1, length(size)-1)+0
    if (unit=="G") kb=num*1024*1024
    else if (unit=="M") kb=num*1024
    else if (unit=="K") kb=num
    else if (unit=="B") kb=num/1024
    else kb=num
    printf "%.0f\t%s\n", kb, path
  }' "$file"
}

TODAY_PARSED=$(parse_snapshot "$SNAP_TODAY")
PREV_PARSED=$(parse_snapshot "$PREV_SNAP")

# ── Diff: find directories that grew ─────────────────────────────────────────
echo -e "${BOLD}Directories that grew since $PREV_DATE:${RESET}"
echo ""

FOUND_GROWTH=0

while IFS=$'\t' read -r cur_kb cur_path; do
  prev_kb=$(echo "$PREV_PARSED" | awk -v p="$cur_path" 'BEGIN{FS="\t"} $2==p{print $1}' | head -1)
  if [ -z "$prev_kb" ]; then
    prev_kb=0
  fi
  diff_kb=$(( cur_kb - prev_kb ))
  # threshold: 500MB = 512000 KB
  if [ "$diff_kb" -gt 512000 ]; then
    FOUND_GROWTH=1
    diff_mb=$(( diff_kb / 1024 ))
    cur_mb=$(( cur_kb / 1024 ))
    dir_name=$(basename "$cur_path")

    if [ "$diff_mb" -gt 2048 ]; then
      icon="${RED}+${diff_mb} MB${RESET}"
    else
      icon="${YELLOW}+${diff_mb} MB${RESET}"
    fi

    echo -e "  $icon   $cur_path  (now ~${cur_mb} MB)"

    # ── Suggest fix for known bloat sources ────────────────────────────────────
    case "$dir_name" in
      "Application Support")
        # Check for known sub-offenders
        echo "         Possible culprits inside Application Support:"
        if [ -d "$HOME/Library/Application Support/Claude" ]; then
          CLAUDE_SIZE=$(du -sh "$HOME/Library/Application Support/Claude/vm_bundles" 2>/dev/null | awk '{print $1}' || echo "unknown")
          echo "           Claude vm_bundles: ~$CLAUDE_SIZE"
          echo "           Fix: rm -rf ~/Library/Application\\ Support/Claude/vm_bundles"
        fi
        if [ -d "$HOME/Library/Application Support/Google/Chrome" ]; then
          OPT_SIZE=$(du -sh "$HOME/Library/Application Support/Google/Chrome/Default/OptimizationGuide" 2>/dev/null | awk '{print $1}' || echo "unknown")
          echo "           Chrome OptGuideOnDeviceModel: ~$OPT_SIZE"
          echo "           Fix: rm -rf ~/Library/Application\\ Support/Google/Chrome/Default/OptimizationGuide*"
        fi
        ;;
      "Caches")
        echo "         Fix: rm -rf ~/Library/Caches/*  (safe to clear; apps rebuild)"
        ;;
      "Containers")
        if [ -d "$HOME/Library/Containers/com.docker.docker" ]; then
          DOCKER_SIZE=$(du -sh "$HOME/Library/Containers/com.docker.docker" 2>/dev/null | awk '{print $1}' || echo "unknown")
          echo "           Docker data: ~$DOCKER_SIZE"
          echo "           Fix: docker system prune -af  (removes unused images/containers)"
        fi
        ;;
      "Developer")
        echo "         Possible culprits: Xcode derived data, iOS simulators"
        echo "         Fix: rm -rf ~/Library/Developer/Xcode/DerivedData"
        echo "         Fix: xcrun simctl delete unavailable  (remove old simulators)"
        ;;
      "Logs")
        echo "         Fix: rm -rf ~/Library/Logs/*  (safe to clear)"
        ;;
      "Mail")
        echo "         Mail attachments and message cache have grown."
        echo "         In Mail.app: Mailbox > Erase Deleted Items, then Mailbox > Rebuild"
        ;;
      "Photos")
        echo "         Photos library has grown. If using iCloud Photos, this may be normal."
        ;;
    esac
    echo ""
  fi
done < <(echo "$TODAY_PARSED")

if [ "$FOUND_GROWTH" -eq 0 ]; then
  echo -e "  ${GREEN}No directories grew by more than 500 MB since $PREV_DATE.${RESET}"
  echo ""
fi

# ── Top 10 current sizes ──────────────────────────────────────────────────────
echo -e "${BOLD}Current top 10 ~/Library directories by size:${RESET}"
head -10 "$SNAP_TODAY" | awk '{printf "  %-8s  %s\n", $1, $2}'
echo ""
