#!/usr/bin/env bash
# Removes Ubuntu Widgets: the widgets, launchers, autostart entries, settings and saved data.
set -euo pipefail

APP_ID="io.github.chhari07.UbuntuWidgets"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
TARGET="$DATA/ubuntu-widgets"

case "${1:-}" in
  "") ;;
  -h|--help) echo "Usage: uninstall.sh   Removes Ubuntu Widgets from your home folder."; exit 0 ;;
  *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
esac

[[ $EUID -ne 0 ]] || { echo "Run this as your normal user, not with sudo." >&2; exit 1; }

for dir in contribution-calendar repo-analyser; do
  pkill -f "python3 $TARGET/$dir/widget.py" 2>/dev/null || true
done

for suffix in ContributionCalendar RepoAnalyser; do
  rm -f "$DATA/applications/$APP_ID.$suffix.desktop" "$CONF/autostart/$APP_ID.$suffix.desktop"
done
if command -v update-desktop-database >/dev/null; then
  update-desktop-database -q "$DATA/applications" 2>/dev/null || true
fi

rm -rf "$TARGET" "$CONF/ubuntu-widgets" "$CACHE/ubuntu-widgets"
echo "Ubuntu Widgets has been removed."
