#!/usr/bin/env bash
# Ubuntu Widgets installer. Works from a clone or piped from the release URL:
#   curl -fsSL https://github.com/chhari07/ubuntu-widgets/releases/latest/download/install.sh | bash
# Everything goes into your home folder. sudo is never used.
set -euo pipefail

# All in one function so a cut-off download can't run half a script.
main() {

VERSION="1.0.0"
REPO="chhari07/ubuntu-widgets"
APP_ID="io.github.chhari07.UbuntuWidgets"

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
TARGET="$DATA/ubuntu-widgets"

GITHUB_USER=""
ONLY="calendar,analyser"
START=1

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' RESET=$'\e[0m'
else
  BOLD='' DIM='' GREEN='' YELLOW='' RED='' RESET=''
fi

section() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
ok()      { printf '  %s[ok]%s    %s\n' "$GREEN" "$RESET" "$1"; }
skip()    { printf '  %s[skip]%s  %s\n' "$DIM" "$RESET" "$1"; }
warn()    { printf '  %s[warn]%s  %s\n' "$YELLOW" "$RESET" "$1" >&2; }
die()     { printf '%s[error]%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  cat <<USAGE
Ubuntu Widgets $VERSION: GitHub widgets for the Ubuntu desktop.

Usage: install.sh [options]

  --github-user NAME   GitHub user shown by the contribution calendar.
                       Default: saved name, then your gh login, then a prompt.
  --only LIST          Widgets to install: calendar, analyser, or both
                       separated by a comma. Default: both.
  --no-start           Install without starting the widgets now.
  --version            Print the version.
  -h, --help           Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-user) [[ $# -ge 2 ]] || die "--github-user needs a name"; GITHUB_USER="$2"; shift ;;
    --only)        [[ $# -ge 2 ]] || die "--only needs a list"; ONLY="$2"; shift ;;
    --no-start)    START=0 ;;
    --version)     echo "$VERSION"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

WANT_CALENDAR=0 WANT_ANALYSER=0
IFS=',' read -ra picks <<< "$ONLY"
for pick in "${picks[@]}"; do
  case "$pick" in
    calendar) WANT_CALENDAR=1 ;;
    analyser) WANT_ANALYSER=1 ;;
    *) die "Unknown widget: $pick (use calendar, analyser)" ;;
  esac
done
(( WANT_CALENDAR + WANT_ANALYSER > 0 )) || die "--only needs at least one widget"

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not with sudo."
[[ "$(uname -s)" == Linux ]] || die "Ubuntu Widgets runs on Linux only."

has_gi() {
  python3 - "$@" >/dev/null 2>&1 <<'PY'
import sys
import gi
gi.require_version(sys.argv[1], sys.argv[2])
PY
}

section "Checking requirements"
has_gi Gtk 3.0 || die "GTK for Python is missing. Run: sudo apt install python3-gi gir1.2-gtk-3.0"
ok "Python and GTK 3"

if (( WANT_ANALYSER )); then
  if has_gi WebKit2 4.1; then
    ok "WebKitGTK 4.1"
  elif (( WANT_CALENDAR )); then
    WANT_ANALYSER=0
    warn "Skipping the repo analyser: WebKitGTK is missing."
    warn "To add it: sudo apt install gir1.2-webkit2-4.1, then run this installer again."
  else
    die "WebKitGTK is missing. Run: sudo apt install gir1.2-webkit2-4.1"
  fi
fi

if (( WANT_ANALYSER )); then
  if ! command -v gh >/dev/null; then
    warn "GitHub CLI is missing, so the repo analyser has no data yet."
    warn "To fix it: sudo apt install gh, then gh auth login"
  elif ! gh auth status >/dev/null 2>&1; then
    warn "GitHub CLI is not logged in, so the repo analyser has no data yet."
    warn "To fix it: gh auth login"
  else
    ok "GitHub CLI is logged in"
  fi
fi

valid_user() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; }

saved_user() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("user", ""))' \
    "$CONF/ubuntu-widgets/contribution-calendar/config.json" 2>/dev/null || true
}

if (( WANT_CALENDAR )); then
  [[ -n "$GITHUB_USER" ]] || GITHUB_USER="$(saved_user)"
  if [[ -z "$GITHUB_USER" ]] && command -v gh >/dev/null; then
    GITHUB_USER="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  # Reads the terminal directly, because stdin is the script itself under curl | bash.
  if [[ -z "$GITHUB_USER" ]] && { exec 3</dev/tty; } 2>/dev/null; then
    printf 'GitHub user name for the contribution calendar: ' >/dev/tty
    read -r GITHUB_USER <&3 || true
    exec 3<&-
  fi
  [[ -n "$GITHUB_USER" ]] || die "No GitHub user name. Pass one with --github-user NAME"
  valid_user "$GITHUB_USER" || die "Not a valid GitHub user name: $GITHUB_USER"
fi

WORK=""
cleanup() { [[ -z "$WORK" ]] || rm -rf "$WORK"; }
trap cleanup EXIT

SCRIPT="${BASH_SOURCE[0]:-}"
SOURCE=""
if [[ -f "$SCRIPT" ]]; then
  HERE="$(cd "$(dirname "$SCRIPT")" && pwd)"
  [[ -f "$HERE/widgets/repo-analyser/widget.py" ]] && SOURCE="$HERE"
fi

if [[ -z "$SOURCE" ]]; then
  section "Downloading version $VERSION"
  command -v curl >/dev/null || die "curl is missing. Run: sudo apt install curl"
  WORK="$(mktemp -d)"
  BASE="https://github.com/$REPO/releases/download/v$VERSION"
  curl -fsSL -o "$WORK/ubuntu-widgets.tar.gz" "$BASE/ubuntu-widgets.tar.gz" || die "Download failed: $BASE/ubuntu-widgets.tar.gz"
  curl -fsSL -o "$WORK/ubuntu-widgets.tar.gz.sha256" "$BASE/ubuntu-widgets.tar.gz.sha256" || die "Download failed: checksum file"
  (cd "$WORK" && sha256sum --check --quiet ubuntu-widgets.tar.gz.sha256) || die "Checksum did not match. Nothing was installed."
  ok "Checksum verified"
  mkdir "$WORK/src"
  tar -xzf "$WORK/ubuntu-widgets.tar.gz" -C "$WORK/src" --strip-components=1
  SOURCE="$WORK/src"
fi

entry() {  # name comment widget-dir arg extra-lines
  local exec_path="$TARGET/$3/widget.py"
  exec_path="${exec_path//\\/\\\\\\\\}"
  exec_path="${exec_path//\"/\\\\\\\"}"
  printf '[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nExec=python3 "%s" %s\nIcon=%s\nTerminal=false\nStartupNotify=false\nCategories=Utility;\n%s' \
    "$1" "$2" "$exec_path" "$4" "$TARGET/$3/github-mark.svg" "$5"
}

stop_widget() {
  if pkill -f "python3 $TARGET/$1/widget.py" 2>/dev/null; then
    sleep 1  # let the old copy release its app name
  fi
}

install_widget() {  # dir name comment app-suffix
  local dir="$1" name="$2" comment="$3" suffix="$4"
  stop_widget "$dir"
  rm -rf "${TARGET:?}/$dir"
  mkdir -p "$TARGET/$dir"
  find "$SOURCE/widgets/$dir" -maxdepth 1 -type f -exec cp {} "$TARGET/$dir/" \;
  chmod 755 "$TARGET/$dir/widget.py"
  mkdir -p "$DATA/applications" "$CONF/autostart"
  entry "$name" "$comment" "$dir" "--show" "" > "$DATA/applications/$APP_ID.$suffix.desktop"
  entry "$name" "$comment" "$dir" "--background" $'NoDisplay=true\nX-GNOME-Autostart-enabled=true\n' \
    > "$CONF/autostart/$APP_ID.$suffix.desktop"
  ok "$name"
}

section "Installing into $TARGET"
mkdir -p "$TARGET"
cp "$SOURCE/uninstall.sh" "$TARGET/uninstall.sh"
chmod 755 "$TARGET/uninstall.sh"
echo "$VERSION" > "$TARGET/VERSION"

if (( WANT_CALENDAR )); then
  mkdir -p "$CONF/ubuntu-widgets/contribution-calendar"
  printf '{"user": "%s"}\n' "$GITHUB_USER" > "$CONF/ubuntu-widgets/contribution-calendar/config.json"
  install_widget contribution-calendar "GitHub Contribution Calendar" "Your GitHub contribution graph on the desktop" ContributionCalendar
else
  skip "GitHub Contribution Calendar"
fi

if (( WANT_ANALYSER )); then
  install_widget repo-analyser "GitHub Repo Analyser" "GitHub repo stats and merge line on the desktop" RepoAnalyser
else
  skip "GitHub Repo Analyser"
fi

if command -v update-desktop-database >/dev/null; then
  update-desktop-database -q "$DATA/applications" 2>/dev/null || true
fi

start_widget() {
  setsid python3 "$TARGET/$1/widget.py" --show >/dev/null 2>&1 < /dev/null &
}

if (( START )); then
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    section "Starting"
    (( WANT_CALENDAR )) && start_widget contribution-calendar
    (( WANT_ANALYSER )) && start_widget repo-analyser
    ok "Widgets are on your desktop. Drag them anywhere, right-click for the menu."
  else
    warn "No desktop session found, so nothing was started. The widgets start at your next login."
  fi
fi

section "Done"
echo "  Ubuntu Widgets $VERSION is installed and starts at every login."
(( WANT_CALENDAR )) && echo "  Calendar user: $GITHUB_USER"
echo "  Hidden a widget? Open it again from the app launcher."
echo "  Remove everything: $TARGET/uninstall.sh"

}

main "$@"
