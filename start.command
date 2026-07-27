#!/bin/bash
echo "Starting iPhone Mic Server..."

# Kill any old instances
pkill -f "server.py" 2>/dev/null
pkill -f "bh_player" 2>/dev/null
sleep 1

# Start server on port 8081
cd "$(dirname "$0")"
PORT=8081 /Users/leo/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 server.py &

# Wait a moment
sleep 2

# Get IP
IP=$(ifconfig en0 2>/dev/null | grep "inet " | awk '{print $2}')
echo ""
echo "✅ Server running!"
echo "📱 iPhone Safari: https://$IP:8081"
echo ""
echo "Press Enter to stop server"
read
pkill -f "server.py" 2>/dev/null
pkill -f "bh_player" 2>/dev/null
echo "Server stopped"
