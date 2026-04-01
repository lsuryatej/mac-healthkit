#!/usr/bin/env bash
# engineer.sh — mac_check.sh wrapper tuned for developers
# Output: terse, numbered sections, PIDs, exact MB, raw + normalised names
# Part of mac-healthkit: https://github.com/yourusername/mac-healthkit
# License: GPL-3.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/../scripts/mac_check.sh" --persona engineer "$@"
