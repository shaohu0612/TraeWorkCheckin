#!/usr/bin/env bash
# ====================================================
# TraeWorkCheckin - 开机自启管理 (macOS / Linux 交互式)
# ====================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run_checkin.sh"

install_macos() {
  echo ""
  echo "[正在处理] 正在配置 macOS LaunchAgent 自启任务..."
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST_FILE="$PLIST_DIR/com.traework.checkin.plist"
  OLD_PLIST_FILE="$PLIST_DIR/com.traework.autocheckin.plist"
  mkdir -p "$PLIST_DIR"

  # 清理旧版配置
  launchctl unload "$OLD_PLIST_FILE" 2>/dev/null || true
  rm -f "$OLD_PLIST_FILE" 2>/dev/null || true

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
    <string>$SCRIPT_DIR/log/checkin.log</string>
    <key>StandardErrorPath</key>
    <string>$SCRIPT_DIR/log/checkin.log</string>
</dict>
</plist>
EOF

  launchctl unload "$PLIST_FILE" 2>/dev/null || true
  launchctl load "$PLIST_FILE"
  echo "[成功] macOS 开机登录自动签到已安装成功！"
  echo "效果：每次登录 macOS 桌面后，系统将自动在后台静默执行并在屏幕右上角发送系统通知。"
}

uninstall_macos() {
  echo ""
  echo "[正在处理] 正在清理 macOS LaunchAgent 自启任务..."
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
    echo "[成功] 已成功移除 LaunchAgent 服务。"
  else
    echo "[提示] 未检测到已配置的 LaunchAgent 服务。"
  fi
  echo "[完成] macOS 自启配置已全部清理干净。"
}

install_linux() {
  echo ""
  echo "[正在处理] 正在配置 Linux 桌面自启条目与每日零点定时任务..."
  AUTOSTART_DIR="$HOME/.config/autostart"
  DESKTOP_FILE="$AUTOSTART_DIR/traework_checkin.desktop"
  OLD_DESKTOP_FILE="$AUTOSTART_DIR/traework_autocheckin.desktop"
  mkdir -p "$AUTOSTART_DIR"
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

  # 配置 crontab 每日零点定时签到 (作为通宵在线的补充保障)
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "TraeWorkCheckin_Daily" ; echo "0 0 * * * /bin/bash \"$RUNNER\" --silent # TraeWorkCheckin_Daily") | crontab - 2>/dev/null || true
  fi

  echo "[成功] Linux 双轨自动签到系统已成功安装！"
  echo "效果：(1) 每次登录桌面环境后静默检测；(2) 每日 00:00 自动触发签到，右下角弹出桌面通知。"
}

uninstall_linux() {
  echo ""
  echo "[正在处理] 正在清理 Linux 桌面自启条目与定时任务..."
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

  # 清理 crontab
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "TraeWorkCheckin_Daily") | crontab - 2>/dev/null || true
  fi

  if [ "$removed" -eq 1 ]; then
    echo "[成功] 已成功移除自启桌面文件与定时任务。"
  else
    echo "[提示] 未检测到已安装的自启条目。"
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
  echo "[启动] 正在调用签到执行器..."
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
  "安装双轨全自动签到 (开机登录静默自启 + 每日零点定时触发)"
  "卸载所有自动任务 (彻底移除开机自启项与 TraeWork 定时任务)"
  "立即测试执行签到 (查看当前运行效果与实时控制台输出)"
  "退出管理程序"
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
  echo -e "\033[1;36m====================================================\033[0m"
  echo -e "\033[1;36m         TraeWorkCheckin - 开机自启管理\033[0m"
  echo -e "\033[1;36m         操作系统: $(uname -s)\033[0m"
  echo -e "\033[1;36m====================================================\033[0m"
  echo -e "\033[90m  提示：使用键盘 [↑ / ↓] 键移动光标，按 [Enter] 确认选择\033[0m"
  echo -e "\033[90m        亦可直接按下对应数字键 [1 / 2 / 3 / 0] 快速选择\033[0m"
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
    read -rsn2 -t 0.1 rest
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