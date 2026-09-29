#!/usr/bin/env bash
# ============================================
# TraeWorkCheckin Daily Runner (macOS / Linux)
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/checkin.js"

# 0. 环境路径增强 (确保 launchd / cron 最小化环境下可正确识别 Homebrew / NVM 等 Node.js)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.nvm/versions/node/$(ls -t "$HOME/.nvm/versions/node" 2>/dev/null | head -1)/bin:$HOME/.fnm/current/bin:$HOME/.volta/bin:$HOME/.asdf/shims:$HOME/.local/bin:$PATH"

# 1. 优先检测系统是否已安装现代化 Node.js 18+
if command -v node >/dev/null 2>&1; then
  if node -e "if(typeof fetch!=='function'||!require('crypto').subtle)process.exit(1)" >/dev/null 2>&1; then
    node "$SCRIPT_PATH" "$@"
    exit $?
  fi
fi

# 2. 自动探查各平台原生 Trae 客户端安装路径（零依赖：无 Node 环境借用 Trae 内核）
FOUND_EXE=""

# 2.1 macOS 应用程序探查（支持 Apple Silicon M系列与 Intel 芯片）
if [ "$(uname -s)" = "Darwin" ]; then
  # (1) 常见标准安装路径检测
  for candidate in \
    "/Applications/TRAE SOLO CN.app/Contents/MacOS/TRAE SOLO CN" \
    "/Applications/Trae CN.app/Contents/MacOS/Trae CN" \
    "/Applications/Trae.app/Contents/MacOS/Trae" \
    "/Applications/TRAE SOLO.app/Contents/MacOS/TRAE SOLO" \
    "/Applications/TRAE.app/Contents/MacOS/TRAE" \
    "$HOME/Applications/TRAE SOLO CN.app/Contents/MacOS/TRAE SOLO CN" \
    "$HOME/Applications/Trae CN.app/Contents/MacOS/Trae CN" \
    "$HOME/Applications/Trae.app/Contents/MacOS/Trae" \
    "$HOME/Applications/TRAE SOLO.app/Contents/MacOS/TRAE SOLO" \
    "$HOME/Applications/TRAE.app/Contents/MacOS/TRAE"
  do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      FOUND_EXE="$candidate"
      break
    fi
  done

  # (2) /Applications 与 ~/Applications 动态通配扫描
  if [ -z "$FOUND_EXE" ]; then
    for app_dir in /Applications/[Tt][Rr][Aa][Ee]*.app "$HOME/Applications/"[Tt][Rr][Aa][Ee]*.app; do
      if [ -d "$app_dir/Contents/MacOS" ]; then
        for bin in "$app_dir/Contents/MacOS"/*; do
          if [ -f "$bin" ] && [ -x "$bin" ]; then
            FOUND_EXE="$bin"
            break 2
          fi
        done
      fi
    done
  fi

  # (3) macOS Spotlight (mdfind) 深度搜索（即便用户将 Trae 放在自定义目录也能秒级定位）
  if [ -z "$FOUND_EXE" ] && command -v mdfind >/dev/null 2>&1; then
    spotlight_app=$(mdfind "kMDItemCFBundleIdentifier == 'com.trae.app' || kMDItemCFBundleIdentifier == 'com.trae.solo' || kMDItemFSName == '*Trae*.app'" 2>/dev/null | head -n 1)
    if [ -n "$spotlight_app" ] && [ -d "$spotlight_app/Contents/MacOS" ]; then
      for bin in "$spotlight_app/Contents/MacOS"/*; do
        if [ -f "$bin" ] && [ -x "$bin" ]; then
          FOUND_EXE="$bin"
          break
        fi
      done
    fi
  fi
fi

# 2.2 Linux 路径探查
if [ "$(uname -s)" = "Linux" ] && [ -z "$FOUND_EXE" ]; then
  for candidate in \
    "$(command -v trae 2>/dev/null)" \
    "/usr/bin/trae" \
    "/usr/local/bin/trae" \
    "/opt/Trae/trae" \
    "/opt/trae/trae" \
    "$HOME/.local/share/trae/trae"
  do
    if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then
      FOUND_EXE="$candidate"
      break
    fi
  done
fi

# 3. 若找到 Trae 客户端，直接使用其内置 Electron 内核执行 (无感零依赖)
if [ -n "$FOUND_EXE" ]; then
  export ELECTRON_RUN_AS_NODE=1
  unset VSCODE_DEV
  "$FOUND_EXE" "$SCRIPT_PATH" "$@"
  exit $?
fi

echo "[ERROR] 未在当前计算机中检测到可用的执行环境！"
echo "-------------------------------------------------------------------------"
echo "未检测到 Node.js 18+，且未能自动定位到已安装的 Trae / TRAE SOLO 客户端。"
echo "排查建议："
echo "  1. 若已安装 Trae，请先打开一次 Trae 客户端后再运行本程序；"
echo "  2. 或安装 Node.js 18+（推荐从官网 https://nodejs.org 安装或 brew install node）。"
echo "-------------------------------------------------------------------------"
exit 1