#!/usr/bin/env bash
# install.sh — Setup and teardown for mac-healthkit
# Part of mac-healthkit: https://github.com/lsuryatej/mac-healthkit
# License: GPL-3.0
set -euo pipefail

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
  RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
else
  BOLD=''; CYAN=''; GREEN=''; RED=''; YELLOW=''; RESET=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOGGER_PLIST_NAME="com.machealthkit.logger.plist"
WATCH_PLIST_NAME="com.machealthkit.watch.plist"
LOGGER_PLIST_DEST="$LAUNCH_AGENTS_DIR/$LOGGER_PLIST_NAME"
WATCH_PLIST_DEST="$LAUNCH_AGENTS_DIR/$WATCH_PLIST_NAME"

DATA_DIR="$HOME/.mac-healthkit"
LOG_DIR="$DATA_DIR/logs"
SNAP_DIR="$DATA_DIR/snapshots"

# ── Uninstall ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  echo -e "${BOLD}${CYAN}mac-healthkit / Uninstall${RESET}"
  echo "────────────────────────────────────────"

  for label in "com.machealthkit.logger" "com.machealthkit.watch"; do
    if launchctl list | grep -q "$label" 2>/dev/null; then
      launchctl unload "$LAUNCH_AGENTS_DIR/${label}.plist" 2>/dev/null || true
      echo -e "  ${GREEN}✓${RESET} Unloaded launchd agent: $label"
    fi
  done

  for plist in "$LOGGER_PLIST_DEST" "$WATCH_PLIST_DEST"; do
    if [ -f "$plist" ]; then
      rm -f "$plist"
      echo -e "  ${GREEN}✓${RESET} Removed: $plist"
    fi
  done

  if [ -f "/usr/local/bin/mhk" ]; then
    rm -f "/usr/local/bin/mhk"
    echo -e "  ${GREEN}✓${RESET} Removed: /usr/local/bin/mhk"
  fi

  echo ""
  echo -e "  ${YELLOW}Note:${RESET} Your log data is kept at $DATA_DIR"
  echo "  To also remove logs and snapshots:"
  echo "    rm -rf $DATA_DIR"
  echo ""
  echo -e "${GREEN}Uninstall complete.${RESET}"
  exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}mac-healthkit / Install${RESET}"
echo "────────────────────────────────────────"
echo "Repo root: $REPO_ROOT"
echo ""

# Make all scripts executable
SCRIPTS=(
  "$REPO_ROOT/scripts/mac_check.sh"
  "$REPO_ROOT/scripts/mac_logger.sh"
  "$REPO_ROOT/scripts/mac_menu.sh"
  "$REPO_ROOT/scripts/mac_weekly_report.sh"
  "$REPO_ROOT/scripts/mac_disk_diff.sh"
  "$REPO_ROOT/scripts/mac_watch.sh"
  "$REPO_ROOT/personas/engineer.sh"
  "$REPO_ROOT/personas/plaintext.sh"
  "$REPO_ROOT/personas/girlypop.sh"
)

for script in "${SCRIPTS[@]}"; do
  chmod +x "$script"
  echo -e "  ${GREEN}✓${RESET} chmod +x $(basename "$script")"
done

# Create data directories
mkdir -p "$LOG_DIR" "$SNAP_DIR"
echo -e "  ${GREEN}✓${RESET} Created: $LOG_DIR"
echo -e "  ${GREEN}✓${RESET} Created: $SNAP_DIR"

# ── Install mhk command ───────────────────────────────────────────────────────
MHK_BIN="/usr/local/bin/mhk"
mkdir -p /usr/local/bin
cat > "$MHK_BIN" <<WRAPPER
#!/usr/bin/env bash
exec "${REPO_ROOT}/scripts/mac_menu.sh" "\$@"
WRAPPER
chmod +x "$MHK_BIN"
echo -e "  ${GREEN}✓${RESET} Installed command: mhk → $MHK_BIN"

# Create LaunchAgents dir if needed
mkdir -p "$LAUNCH_AGENTS_DIR"

# ── Install logger plist ──────────────────────────────────────────────────────
sed "s|INSTALL_PATH_PLACEHOLDER|${REPO_ROOT}|g" \
  "$SCRIPT_DIR/$LOGGER_PLIST_NAME" > "$LOGGER_PLIST_DEST"
echo -e "  ${GREEN}✓${RESET} Installed: $LOGGER_PLIST_DEST"

# ── Install watch plist ───────────────────────────────────────────────────────
sed "s|INSTALL_PATH_PLACEHOLDER|${REPO_ROOT}|g" \
  "$SCRIPT_DIR/$WATCH_PLIST_NAME" > "$WATCH_PLIST_DEST"
echo -e "  ${GREEN}✓${RESET} Installed: $WATCH_PLIST_DEST"

# ── Load launchd agents ───────────────────────────────────────────────────────
for plist_dest in "$LOGGER_PLIST_DEST" "$WATCH_PLIST_DEST"; do
  label=$(basename "$plist_dest" .plist)
  # Unload first if already running (idempotent reinstall)
  launchctl unload "$plist_dest" 2>/dev/null || true
  launchctl load -w "$plist_dest"
  echo -e "  ${GREEN}✓${RESET} Loaded launchd agent: $label"
done

# ── Success summary ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${RESET}"
echo "────────────────────────────────────────"
echo ""
echo -e "${BOLD}How to use:${RESET}"
echo ""
echo "  Just type:"
echo "    mhk"
echo ""
echo "  That's it. The interactive menu will guide you from there."
echo ""
echo "  Background logger runs every 5 min automatically (launchd)."
echo "  Background watcher alerts via macOS notifications every 10 min (launchd)."
echo ""
echo "  Log data: $LOG_DIR/health.csv"
echo "  Snapshots: $SNAP_DIR/"
echo ""
echo "  To uninstall: bash $REPO_ROOT/install/install.sh --uninstall"
echo ""
