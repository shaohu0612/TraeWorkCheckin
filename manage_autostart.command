#!/bin/bash
# ====================================================
# TraeWorkCheckin - 双击启动控制台 (macOS 快捷方式)
# ====================================================
cd "$(dirname "$0")" || exit 1
chmod +x ./manage_autostart.sh ./run_checkin.sh 2>/dev/null
exec /bin/bash ./manage_autostart.sh
