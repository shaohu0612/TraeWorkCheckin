#!/usr/bin/env bash
# ====================================================
# TraeWorkCheckin - 自动签到管理控制台 (macOS / Linux 交互式)
# ====================================================

# 确保常用工具路径就绪 (支持 Apple Silicon / Intel Mac Homebrew、NVM、fnm 等)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.nvm/versions/node/$(ls -t "$HOME/.nvm/versions/node" 2>/dev/null | head -1)/bin:$HOME/.fnm/current/bin:$HOME/.volta/bin:$HOME/.asdf/shims:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run_checkin.sh"
LOG_DIR="$SCRIPT_DIR/log"
LOG_FILE="$LOG_DIR/checkin.log"

# 自动确保各脚本具备可执行权限
chmod +x "$RUNNER" "$SCRIPT_DIR/manage_autostart.sh" "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.command 2>/dev/null || true

# 检查当前运行环境类型
detect_runtime() {
  if command -v node >/dev/null 2>&1; then
    local node_ver
    node_ver=$(node -v 2>/dev/null)
    echo "Node.js ($node_ver)"
    return
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    for candidate in \
      "/Applications/TRAE SOLO CN.app/Contents/MacOS/TRAE SOLO CN" \
      "/Applications/Trae CN.app/Contents/MacOS/Trae CN" \
      "/Applications/Trae.app/Contents/MacOS/Trae" \
      "/Applications/TRAE SOLO.app/Contents/MacOS/TRAE SOLO" \
      "/Applications/TRAE.app/Contents/MacOS/TRAE" \
      "$HOME/Applications/TRAE SOLO CN.app/Contents/MacOS/TRAE SOLO CN" \
      "$HOME/Applications/Trae CN.app/Contents/MacOS/Trae CN" \
      "$HOME/Applications/Trae.app/Contents/MacOS/Trae"
    do
      if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        echo "Trae 内置运行时 (零依赖模式)"
        return
      fi
    done
    echo "未检测到 (请安装 Node 18+ 或先安装 Trae 客户端)"
  else
    echo "未检测到 (请安装 Node 18+ 或先安装 Trae 客户端)"
  fi
}

install_macos() {
  echo ""
  echo -e "\033[1;33m[正在处理] 正在配置 macOS 双轨全自动签到 (LaunchAgent)...\033[0m"
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST_FILE="$PLIST_DIR/com.traework.checkin.plist"
  OLD_PLIST_FILE="$PLIST_DIR/com.traework.autocheckin.plist"

  mkdir -p "$PLIST_DIR"
  mkdir -p "$LOG_DIR"

  # 清理旧版配置
  launchctl unload "$OLD_PLIST_FILE" 2>/dev/null || true
  rm -f "$OLD_PLIST_FILE" 2>/dev/null || true
  launchctl unload "$PLIST_FILE" 2>/dev/null || true

  cat <<EOF > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.traework.checkin</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUNNER</string>
        <string>--silent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>0</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF

  launchctl load -w "$PLIST_FILE" 2>/dev/null || launchctl load "$PLIST_FILE" 2>/dev/null || true

  echo -e "\033[1;32m[成功] macOS 双轨全自动签到已安装并成功激活！\033[0m"
  echo "--------------------------------------------------------"
  echo "保障说明："
  echo "  1. 开机/登录自启：每次登录系统桌面后，系统在后台静默执行签到；"
  echo "  2. 每日午夜补充：若每日 00:00 电脑在线（或休眠唤醒），自动等待 30 秒至 00:00:30 校准签到；"
  echo "  3. 执行完毕通知：签到完成后在屏幕右上角发送 macOS 原生通知。"
  echo "--------------------------------------------------------"
}

uninstall_macos() {
  echo ""
  echo -e "\033[1;33m[正在处理] 正在清理 macOS LaunchAgent 自动任务...\033[0m"
  PLIST_FILE="$HOME/Library/LaunchAgents/com.traework.checkin.plist"
  OLD_PLIST_FILE="$HOME/Library/LaunchAgents/com.traework.autocheckin.plist"
  removed=0

  if [ -f "$PLIST_FILE" ]; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    rm -f "$PLIST_FILE"
    removed=1
  fi
  if [ -f "$OLD_PLIST_FILE" ]; then
    launchctl unload "$OLD_PLIST_FILE" 2>/dev/null || true
    rm -f "$OLD_PLIST_FILE"
    removed=1
  fi

  if [ "$removed" -eq 1 ]; then
    echo -e "\033[1;32m[成功] 已成功注销并移除 LaunchAgent 服务。\033[0m"
  else
    echo -e "\033[90m[提示] 未检测到已配置的 LaunchAgent 服务。\033[0m"
  fi
  echo "[完成] macOS 自动签到配置已全部清理干净。"
}

install_linux() {
  echo ""
  echo -e "\033[1;33m[正在处理] 正在配置 Linux 桌面自启条目与每日零点定时任务...\033[0m"
  AUTOSTART_DIR="$HOME/.config/autostart"
  DESKTOP_FILE="$AUTOSTART_DIR/traework_checkin.desktop"
  OLD_DESKTOP_FILE="$AUTOSTART_DIR/traework_autocheckin.desktop"

  mkdir -p "$AUTOSTART_DIR"
  mkdir -p "$LOG_DIR"
  rm -f "$OLD_DESKTOP_FILE" 2>/dev/null || true

  cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Type=Application
Version=1.0
Name=TraeWorkCheckin
Comment=TraeWorkCheckin Daily Auto Check-in
Exec=/bin/bash "$RUNNER" --silent
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
EOF

  chmod +x "$DESKTOP_FILE"

  # 配置 crontab 每日零点定时签到
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "TraeWorkCheckin_Daily" ; echo "0 0 * * * /bin/bash \"$RUNNER\" --silent # TraeWorkCheckin_Daily") | crontab - 2>/dev/null || true
  fi

  echo -e "\033[1;32m[成功] Linux 双轨自动签到系统已成功安装！\033[0m"
  echo "效果：(1) 每次登录桌面环境后静默检测；(2) 每日 00:00 自动触发并校准至 00:00:30 执行签到。"
}

uninstall_linux() {
  echo ""
  echo -e "\033[1;33m[正在处理] 正在清理 Linux 桌面自启条目与定时任务...\033[0m"
  DESKTOP_FILE="$HOME/.config/autostart/traework_checkin.desktop"
  OLD_DESKTOP_FILE="$HOME/.config/autostart/traework_autocheckin.desktop"
  removed=0

  if [ -f "$DESKTOP_FILE" ]; then
    rm -f "$DESKTOP_FILE"
    removed=1
  fi
  if [ -f "$OLD_DESKTOP_FILE" ]; then
    rm -f "$OLD_DESKTOP_FILE"
    removed=1
  fi

  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "TraeWorkCheckin_Daily") | crontab - 2>/dev/null || true
  fi

  if [ "$removed" -eq 1 ]; then
    echo -e "\033[1;32m[成功] 已成功移除自启桌面文件与定时任务。\033[0m"
  else
    echo -e "\033[90m[提示] 未检测到已安装的自启条目。\033[0m"
  fi
  echo "[完成] Linux 自动签到配置已全部清理干净。"
}

do_install() {
  case "$(uname -s)" in
    Darwin*) install_macos ;;
    Linux*)  install_linux ;;
    *)       echo "[错误] 暂不支持的操作系统: $(uname -s)" ;;
  esac
}

do_uninstall() {
  case "$(uname -s)" in
    Darwin*) uninstall_macos ;;
    Linux*)  uninstall_linux ;;
    *)       echo "[错误] 暂不支持的操作系统: $(uname -s)" ;;
  esac
}

do_run() {
  echo ""
  echo -e "\033[1;36m[启动] 正在手动调用签到执行器 (查看实时效果)...\033[0m"
  /bin/bash "$RUNNER"
}

# 命令行非交互参数处理
if [ "$1" = "--install" ] || [ "$1" = "-i" ] || [ "$1" = "install" ]; then
  do_install
  exit 0
elif [ "$1" = "--uninstall" ] || [ "$1" = "-u" ] || [ "$1" = "uninstall" ]; then
  do_uninstall
  exit 0
elif [ "$1" = "--run" ] || [ "$1" = "-r" ] || [ "$1" = "run" ]; then
  do_run
  exit 0
fi

options=(
  "一键安装双轨全自动签到 (开机登录静默自启 + 每日 00:00:30 定时校准)"
  "彻底卸载所有自动任务 (移除 LaunchAgent 开机项与定时任务)"
  "立即测试执行签到 (查看当前运行日志与原生通知测试)"
  "退出管理控制台"
)
actions=("install" "uninstall" "run" "exit")

execute_action() {
  case "$1" in
    install)
      do_install
      echo ""
      read -p "请按回车键返回主菜单..." _
      ;;
    uninstall)
      do_uninstall
      echo ""
      read -p "请按回车键返回主菜单..." _
      ;;
    run)
      do_run
      echo ""
      read -p "请按回车键返回主菜单..." _
      ;;
    exit)
      echo ""
      echo "感谢使用，程序正在退出..."
      tput cnorm 2>/dev/null || true
      exit 0
      ;;
  esac
}

# 交互式光标与菜单渲染
tput civis 2>/dev/null || true
trap 'tput cnorm 2>/dev/null || true; exit 0' EXIT INT TERM

render_menu() {
  clear
  local os_name
  os_name="$(uname -s)"
  local arch_name
  arch_name="$(uname -m 2>/dev/null || echo '')"
  local runtime_desc
  runtime_desc="$(detect_runtime)"

  echo -e "\033[1;36m====================================================\033[0m"
  echo -e "\033[1;36m       TraeWorkCheckin - 自动签到管理控制台\033[0m"
  echo -e "\033[1;36m       操作系统: ${os_name} (${arch_name})\033[0m"
  echo -e "\033[1;36m====================================================\033[0m"

  echo -e "\033[1;33m[系统环境与任务状态看板]\033[0m"
  echo -e "  • 执行运行时: \033[32m${runtime_desc}\033[0m"

  if [ "$os_name" = "Darwin" ]; then
    local plist_file="$HOME/Library/LaunchAgents/com.traework.checkin.plist"
    if [ -f "$plist_file" ]; then
      if launchctl list 2>/dev/null | grep -q "com.traework.checkin"; then
        echo -e "  • 开机登录自启: \033[1;32m[已就绪 (LaunchAgent 运行中)]\033[0m"
        echo -e "  • 每日 00:00:30: \033[1;32m[已就绪 (午夜在线自动签到)]\033[0m"
      else
        echo -e "  • 开机登录自启: \033[1;33m[已配置 (等待系统唤醒加载)]\033[0m"
        echo -e "  • 每日 00:00:30: \033[1;33m[已配置 (等待系统唤醒加载)]\033[0m"
      fi
    else
      echo -e "  • 开机与每日定时: \033[90m[未安装 (请选择选项 1 一键开启)]\033[0m"
    fi
  elif [ "$os_name" = "Linux" ]; then
    local desktop_file="$HOME/.config/autostart/traework_checkin.desktop"
    if [ -f "$desktop_file" ]; then
      echo -e "  • 开机登录自启: \033[1;32m[已就绪 (Desktop Autostart)]\033[0m"
      echo -e "  • 每日 00:00:30: \033[1;32m[已就绪 (Crontab 定时器)]\033[0m"
    else
      echo -e "  • 开机与每日定时: \033[90m[未安装 (请选择选项 1 一键开启)]\033[0m"
    fi
  fi

  # 最近日志摘要
  if [ -f "$LOG_FILE" ]; then
    local last_log
    last_log=$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -c 1-50)
    if [ -n "$last_log" ]; then
      echo -e "  • 最近运行日志: \033[90m${last_log}...\033[0m"
    fi
  fi

  echo -e "\033[90m----------------------------------------------------\033[0m"
  echo -e "\033[90m  提示：使用数字键 [1 / 2 / 3 / 0] 快速选择\033[0m"
  echo -e "\033[90m        或使用键盘 [↑ / ↓] 移动光标，按 [Enter] 确认\033[0m"
  echo -e "\033[90m----------------------------------------------------\033[0m"
  echo ""

  for i in "${!options[@]}"; do
    num_hint="$((i + 1))"
    if [ "$i" -eq "$(( ${#options[@]} - 1 ))" ]; then
      num_hint="0"
    fi
    if [ "$i" -eq "$selected" ]; then
      echo -e " \033[1;32m▶ [$num_hint] ${options[$i]}\033[0m"
    else
      echo -e "   \033[90m[$num_hint]\033[0m \033[37m${options[$i]}\033[0m"
    fi
  done

  echo ""
  echo -e "\033[1;36m====================================================\033[0m"
}

selected=0

# 若检测到非交互终端（如无 tty 或重定向），输出帮助并退出
if [ ! -t 0 ]; then
  echo "[提示] 检测到重定向非交互环境，如需操作请传入参数：--install 或 --uninstall"
  exit 0
fi

while true; do
  render_menu
  IFS= read -rsn1 key
  if [[ $key == $'\x1b' ]]; then
    # 兼容 macOS 默认 bash 3.2 (不支持小数超时 read -t 0.1)
    if (( BASH_VERSINFO[0] >= 4 )); then
      read -rsn2 -t 0.1 rest 2>/dev/null || true
    else
      read -rsn2 -t 1 rest 2>/dev/null || true
    fi
    if [[ $rest == "[A" ]]; then
      selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} ))
    elif [[ $rest == "[B" ]]; then
      selected=$(( (selected + 1) % ${#options[@]} ))
    fi
  elif [[ $key == "" ]]; then
    execute_action "${actions[$selected]}"
  elif [[ $key == "1" ]]; then
    execute_action "install"
  elif [[ $key == "2" ]]; then
    execute_action "uninstall"
  elif [[ $key == "3" ]]; then
    execute_action "run"
  elif [[ $key == "0" || $key == "q" || $key == "Q" ]]; then
    execute_action "exit"
  fi
done