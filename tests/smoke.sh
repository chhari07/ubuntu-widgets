#!/usr/bin/env bash
# Runs both widgets on the current display in a throwaway home folder, with made-up
# GitHub data, and checks they stay up. Pass a folder to save a screenshot there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOTS="${1:-}"
TMP="$(mktemp -d)"
PIDS=()
# shellcheck disable=SC2317  # runs from the trap
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home" PATH="$ROOT/tests/fixtures:$PATH"
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1  # CI runners block WebKit's sandbox; made-up data only
mkdir -p "$HOME"
"$ROOT/install.sh" --github-user octocat --no-start >/dev/null

for dir in contribution-calendar repo-analyser; do
  python3 "$HOME/.local/share/ubuntu-widgets/$dir/widget.py" --show >"$TMP/$dir.log" 2>&1 &
  PIDS+=("$!")
done
sleep 12

status=0
for i in 0 1; do
  if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
    echo "[fail] widget $i exited"; status=1
  fi
done
if grep -l 'Traceback' "$TMP"/*.log; then
  cat "$TMP"/*.log; status=1
fi
check_file() { if [[ -s "$1" ]]; then echo "[ok] $1"; else echo "[fail] missing $1"; status=1; fi; }
check_file "$HOME/.cache/ubuntu-widgets/repo-analyser/data.json"
if [[ -n "$SHOTS" ]]; then
  mkdir -p "$SHOTS"
  import -window root "$SHOTS/desktop.png"
fi
exit "$status"
