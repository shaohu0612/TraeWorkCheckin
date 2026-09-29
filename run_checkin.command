#!/bin/bash
# ====================================================
# TraeWorkCheckin - 双击立即签到 (macOS 快捷方式)
# ====================================================
cd "$(dirname "$0")" || exit 1
chmod +x ./run_checkin.sh 2>/dev/null
/bin/bash ./run_checkin.sh
echo ""
read -p "按回车键关闭窗口..." _
