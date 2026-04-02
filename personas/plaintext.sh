#!/usr/bin/env bash
# plaintext.sh — mac_check.sh wrapper, plain English output
# No PIDs, rounded numbers, traffic-light emojis, friendly fix suggestions.
# Part of mac-healthkit: https://github.com/lsuryatej/mac-healthkit
# License: GPL-3.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/../scripts/mac_check.sh" --persona plaintext "$@"
