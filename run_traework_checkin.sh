#!/usr/bin/env bash
# ============================================
# TraeWorkCheckin Daily Runner Alias (macOS / Linux)
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash "$SCRIPT_DIR/run_checkin.sh" "$@"
