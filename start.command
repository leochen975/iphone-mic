#!/bin/bash
#
# start.command - 一键启动 iPhone 无线麦克风。
# 双击运行，或从终端运行。按 Enter 停止。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${PORT:-8080}"
BIN_DIR="$SCRIPT_DIR/bin"
PLAYER="$BIN_DIR/bh_player"

echo "=============================================="
echo "  iPhone Wireless Microphone Launcher"
echo "=============================================="
echo ""

# 1. Python 环境
if command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
else
    echo "错误：未找到 python3。请先安装：xcode-select --install" >&2
    exit 1
fi
echo "✅ Python: $PYTHON"

# 2. BlackHole 驱动
if [ -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
    echo "✅ BlackHole 2ch: 已安装"
else
    echo "错误：未找到 BlackHole 2ch。请安装：brew install blackhole-2ch" >&2
    exit 1
fi

# 3. bh_player 编译
if [ ! -x "$PLAYER" ]; then
    echo "🔨 bh_player 不存在，开始编译..."
    "$SCRIPT_DIR/scripts/build_player.sh"
fi
echo "✅ bh_player: $PLAYER"

# 4. 清理旧进程
pkill -f "server.py" 2>/dev/null || true
pkill -f "bh_player" 2>/dev/null || true
sleep 1

# 5. 启动服务
echo ""
echo "🚀 启动服务器 (端口 $PORT)..."
PORT="$PORT" BH_PLAYER="$PLAYER" "$PYTHON" "$SCRIPT_DIR/server.py" &
SERVER_PID=$!
sleep 2

# 6. 显示局域网 IP（优先私有地址，避免 VPN 虚拟网卡地址）
IP="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -E '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1)"
if [ -z "$IP" ]; then
    IP="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
fi
[ -n "$IP" ] || IP="127.0.0.1"

echo ""
echo "=============================================="
echo "✅ 服务器已启动 (PID $SERVER_PID)"
echo "📱 iPhone Safari 打开: https://$IP:$PORT"
echo "   (确保 iPhone 与 Mac 在同一 Wi-Fi)"
echo ""
echo "按 Enter 停止服务器"
echo "=============================================="
read -r

kill "$SERVER_PID" 2>/dev/null || true
pkill -f "bh_player" 2>/dev/null || true
echo "服务器已停止。"
