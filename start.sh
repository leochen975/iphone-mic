#!/bin/bash
# iPhone 无线麦克风 - 启动脚本
cd "$(dirname "$0")"
PYTHON="/Users/leo/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
PORT=${PORT:-8080}

echo "启动 iPhone 无线麦克风服务器..."
$PYTHON server.py
