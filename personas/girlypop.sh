#!/usr/bin/env bash
# girlypop.sh — Girly Pop persona for mac-healthkit 🎀
# Creative-first output: PS/AE/Figma-aware, friendly slang, zero jargon.
# Part of mac-healthkit: https://github.com/lsuryatej/mac-healthkit
# License: GPL-3.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/../scripts/mac_check.sh" --persona girlypop "$@"
