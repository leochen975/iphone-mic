#!/bin/bash
#
# uninstall_launchd.sh - 卸载 launchd 开机自启。
#
set -euo pipefail

LABEL="com.iphone-mic"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

echo "✅ 已卸载 $LABEL"
