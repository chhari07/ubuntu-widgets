#!/usr/bin/env bash
# Installs into a throwaway home folder and checks the results. Starts no widgets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

pass() { printf '  [ok]    %s\n' "$1"; }
fail() { printf '  [fail]  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
refuses() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$what"; else pass "$what"; fi; }

fresh() {
  export HOME="$TMP/home $1"
  mkdir -p "$HOME"
  unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME DISPLAY WAYLAND_DISPLAY || true
}

calendar_user() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["user"])' \
    "$HOME/.config/ubuntu-widgets/contribution-calendar/config.json"
}

SYSTEM_PATH="$PATH"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cp "$ROOT/tests/fixtures/gh" "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$SYSTEM_PATH"

echo "Full install (home folder has a space)"
fresh a
"$ROOT/install.sh" --github-user octocat --no-start >/dev/null
APP="$HOME/.local/share/applications/io.github.chhari07.UbuntuWidgets"
AUTO="$HOME/.config/autostart/io.github.chhari07.UbuntuWidgets"
for w in contribution-calendar/widget.py contribution-calendar/github-mark.svg repo-analyser/widget.py repo-analyser/ui.html repo-analyser/github-mark.svg uninstall.sh VERSION; do
  check "installed $w" test -e "$HOME/.local/share/ubuntu-widgets/$w"
done
check "launcher entries" test -f "$APP.ContributionCalendar.desktop" -a -f "$APP.RepoAnalyser.desktop"
check "autostart entries" test -f "$AUTO.ContributionCalendar.desktop" -a -f "$AUTO.RepoAnalyser.desktop"
check "calendar user saved" test "$(calendar_user)" = octocat
if command -v desktop-file-validate >/dev/null; then
  check "desktop entries valid" desktop-file-validate "$APP.ContributionCalendar.desktop" "$AUTO.RepoAnalyser.desktop"
fi
EXEC_LINE="$(python3 - "$AUTO.RepoAnalyser.desktop" <<'PY'
import sys
from gi.repository import GLib
key = GLib.KeyFile()
key.load_from_file(sys.argv[1], GLib.KeyFileFlags.NONE)
ok, argv = GLib.shell_parse_argv(key.get_string("Desktop Entry", "Exec"))
print(argv[1])
PY
)"
check "autostart path survives the space" test -f "$EXEC_LINE"

echo "Reinstall"
"$ROOT/install.sh" --github-user another-user --no-start >/dev/null
check "new user replaces old" test "$(calendar_user)" = another-user
"$ROOT/install.sh" --no-start >/dev/null
check "saved user is kept" test "$(calendar_user)" = another-user

echo "Name sources and bad input"
fresh b
"$ROOT/install.sh" --no-start >/dev/null
check "user taken from gh login" test "$(calendar_user)" = octocat
refuses "rejects a bad name" "$ROOT/install.sh" --github-user 'a"b/../c' --no-start
refuses "rejects an unknown widget" "$ROOT/install.sh" --only clock --no-start
refuses "rejects an unknown option" "$ROOT/install.sh" --nope

echo "One widget"
fresh c
"$ROOT/install.sh" --only analyser --no-start >/dev/null
check "analyser installed" test -f "$HOME/.local/share/ubuntu-widgets/repo-analyser/widget.py"
check "calendar not installed" test ! -e "$HOME/.local/share/ubuntu-widgets/contribution-calendar"

echo "No name available and no terminal"
fresh d
export PATH="$SYSTEM_PATH"
if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
  refuses "stops and asks for a name" setsid "$ROOT/install.sh" --no-start </dev/null
fi
export PATH="$FAKE_BIN:$SYSTEM_PATH"

echo "Uninstall"
fresh e
mkdir -p "$HOME/.config/autostart" "$HOME/.local/share/applications"
touch "$HOME/.config/autostart/other.desktop" "$HOME/.local/share/applications/other.desktop"
"$ROOT/install.sh" --github-user octocat --no-start >/dev/null
mkdir -p "$HOME/.cache/ubuntu-widgets/repo-analyser"
touch "$HOME/.cache/ubuntu-widgets/repo-analyser/data.json"
"$HOME/.local/share/ubuntu-widgets/uninstall.sh" >/dev/null
check "nothing of ours left" test -z "$(find "$HOME" -iname '*ubuntu*widgets*' -print -quit)"
check "other apps untouched" test -f "$HOME/.config/autostart/other.desktop" -a -f "$HOME/.local/share/applications/other.desktop"

if (( FAILS )); then
  printf '\n%d check(s) failed\n' "$FAILS"
  exit 1
fi
printf '\nAll checks passed\n'
