#!/bin/bash
#
# start.sh - 前台启动服务器。
# 适合终端运行，也作为 launchd 自动启动入口。
# 会自动检测 Python、编译 bh_player，然后前台运行 server.py。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Python 检测（launchd 环境 PATH 可能很精简）。
if command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
elif [ -x /usr/bin/python3 ]; then
    PYTHON="/usr/bin/python3"
else
    echo "错误：未找到 python3。请安装 Xcode Command Line Tools：xcode-select --install" >&2
    exit 1
fi

PLAYER="${BH_PLAYER:-$SCRIPT_DIR/bin/bh_player}"

# 2. bh_player 不存在时自动编译。
if [ ! -x "$PLAYER" ]; then
    echo "bh_player 不存在，开始编译..." >&2
    "$SCRIPT_DIR/scripts/build_player.sh" >&2 || exit 1
fi

# 3. 前台运行服务器。
export BH_PLAYER="$PLAYER"
exec "$PYTHON" "$SCRIPT_DIR/server.py"
