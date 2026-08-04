#!/bin/bash
# Install janitor onto PATH; optional schedule + Desktop button.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/bin"
PLIST_SRC="$ROOT/launchd/com.susssus.janitor.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/com.susssus.janitor.plist"
LOG_DIR="${HOME}/Library/Logs/janitor"
DESKTOP_APP="${HOME}/Desktop/Janitor.app"

mkdir -p "$BIN_DIR" "$LOG_DIR" "${HOME}/Library/LaunchAgents"

ln -sfn "$ROOT/bin/janitor" "$BIN_DIR/janitor"
ln -sfn "$ROOT/bin/janitor-desktop" "$BIN_DIR/janitor-desktop"
chmod +x "$ROOT/bin/janitor" "$ROOT/bin/janitor-desktop" "$ROOT/install.sh" \
  "$ROOT/desktop/build-app.sh"

echo "Linked: $BIN_DIR/janitor -> $ROOT/bin/janitor"
echo "Logs:   $LOG_DIR/"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo
  echo "Add ~/bin to your PATH (zsh):"
  echo '  echo '\''export PATH="$HOME/bin:$PATH"'\'' >> ~/.zshrc && source ~/.zshrc'
fi

# Build a PATH suitable for unattended launchd runs
build_launchd_path() {
  local parts=()
  parts+=(/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)
  parts+=("$BIN_DIR")
  local nvm_node
  nvm_node="$(ls -d "$HOME/.nvm/versions/node"/*/bin 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "${nvm_node:-}" ]]; then
    parts+=("$nvm_node")
  fi
  if [[ -d "$HOME/development/flutter/bin" ]]; then
    parts+=("$HOME/development/flutter/bin")
  fi
  local IFS=:
  echo "${parts[*]}"
}

schedule=0
desktop=0
for arg in "$@"; do
  case "$arg" in
    --schedule) schedule=1 ;;
    --desktop) desktop=1 ;;
  esac
done

if [[ "$schedule" -eq 1 ]]; then
  LAUNCHD_PATH="$(build_launchd_path)"
  sed \
    -e "s|__JANITOR_BIN__|$BIN_DIR/janitor|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__PATH__|$LAUNCHD_PATH|g" \
    "$PLIST_SRC" > "$PLIST_DST"

  launchctl unload "$PLIST_DST" 2>/dev/null || true
  launchctl load "$PLIST_DST"
  echo "Scheduled: weekly Sunday 10:00 (LaunchAgent $PLIST_DST)"
else
  echo
  echo "Optional weekly schedule:"
  echo "  $0 --schedule"
fi

if [[ "$desktop" -eq 1 ]]; then
  "$ROOT/desktop/build-app.sh" "$ROOT/desktop/Janitor.app"
  rm -rf "$DESKTOP_APP"
  cp -R "$ROOT/desktop/Janitor.app" "$DESKTOP_APP"
  # Clear quarantine so double-click works
  xattr -dr com.apple.quarantine "$DESKTOP_APP" 2>/dev/null || true
  echo "Desktop button: $DESKTOP_APP"
  echo "Double-click Janitor → Assess → confirm → Clean now"
else
  echo
  echo "Optional Desktop button:"
  echo "  $0 --desktop"
fi

echo
echo "Try:"
echo "  janitor status"
echo "  janitor clean --dry-run"
echo "  janitor desktop"
echo "  janitor log"
