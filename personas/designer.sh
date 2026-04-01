#!/usr/bin/env bash
# designer.sh — mac_check.sh wrapper tuned for non-technical users
# Output: plain English, traffic-light emojis, no PIDs, rounded MB, fix suggestions
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/../scripts/mac_check.sh" --persona designer "$@"
