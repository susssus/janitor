#!/bin/bash
# User config + portable PATH — no machine-specific hardcoding required

# XDG-style config (portable across users)
JANITOR_CONFIG_DIR="${JANITOR_CONFIG_DIR:-$HOME/.config/janitor}"
JANITOR_DISABLED_FILE="$JANITOR_CONFIG_DIR/disabled"
JANITOR_ASSESS_TSV="${JANITOR_LOG_DIR:-$HOME/Library/Logs/janitor}/last-assess.tsv"

# Known task ids (for `janitor tasks` / enable / disable)
JANITOR_TASK_IDS=(
  homebrew npm pip pip3 gradle gradle_daemon
  android_sdk_dl android_cache android_qemu
  xcode_derived playwright google huggingface
  stremio cocoapods dart_server pub_cache simctl
  old_logs cursor_caches
  shipit mozilla firefox canva steam stremio5
)

JANITOR_TASK_LABELS=(
  "Homebrew"
  "npm cache"
  "pip cache"
  "pip3 cache"
  "Gradle caches"
  "Gradle daemon"
  "Android SDK downloads"
  "Android cache"
  "Android emulator qemu temps"
  "Xcode DerivedData"
  "Playwright cache"
  "Google / Chrome cache"
  "Hugging Face cache"
  "Stremio cache"
  "CocoaPods cache"
  "Dart analysis server"
  "Dart/Flutter pub cache"
  "Unavailable simulators"
  "Old Library/Logs"
  "Cursor caches"
  "Claude ShipIt cache"
  "Mozilla cache"
  "Firefox cache"
  "Canva updater cache"
  "Steam cache"
  "Stremio5 cache"
)

# Brief “what / when to keep” notes for the desktop checkbox UI (same order as IDs).
JANITOR_TASK_BLURBS=(
  "Old brew downloads & bottles. Safe — brew re-fetches when needed."
  "npm package tarball cache. Next npm install may re-download."
  "pip wheel/HTTP cache. Safe; packages re-download on next install."
  "pip3 wheel/HTTP cache. Safe; packages re-download on next install."
  "~/.gradle/caches build deps. Next Gradle/Android build re-downloads."
  "Gradle daemon working dirs. Daemons restart on next build."
  "Incomplete Android SDK download leftovers. Safe to clear."
  "Android tooling cache under ~/.android. Regenerates as needed."
  "Emulator qemu temp files. Safe if the emulator is not mid-run."
  "Xcode build products. First rebuild after this will be slower."
  "Playwright browser binaries for tests. Re-downloaded on next test run."
  "Google/Chrome app caches (not your bookmarks or passwords)."
  "Downloaded HF models/datasets. Large; only clear if you can re-fetch."
  "Stremio streaming cache. May re-buffer after clearing."
  "CocoaPods specs/pods cache. Next pod install re-fetches."
  "Dart analyzer cache. Regenerates when you open a Dart project."
  "Dart/Flutter package cache. Next pub get / flutter pub get re-fetches."
  "Removes dead/unavailable iOS simulators only — keeps working ones."
  "macOS Library/Logs older than 14 days. Does not touch app data."
  "Cursor editor caches only — not your project files."
  "Claude desktop auto-update leftovers. Safe."
  "Mozilla app cache. Safe; pages may load slightly slower once."
  "Firefox cache. Safe; pages may load slightly slower once."
  "Canva updater leftovers. Safe."
  "Steam download/cache leftovers. Won’t remove installed games."
  "Stremio5 app cache. May re-buffer after clearing."
)

# Lookup blurb by task id (empty string if unknown).
task_blurb() {
  local want="$1" i
  for i in "${!JANITOR_TASK_IDS[@]}"; do
    if [[ "${JANITOR_TASK_IDS[$i]}" == "$want" ]]; then
      echo "${JANITOR_TASK_BLURBS[$i]}"
      return 0
    fi
  done
  echo ""
}

config_ensure() {
  mkdir -p "$JANITOR_CONFIG_DIR"
  if [[ ! -f "$JANITOR_DISABLED_FILE" ]]; then
    cat >"$JANITOR_DISABLED_FILE" <<'EOF'
# Janitor — disabled task ids (one per line)
# Lines starting with # are comments.
# Example:
# playwright
# pub_cache
EOF
  fi
}

# Return 0 if task id is permanently disabled in config
task_is_disabled() {
  local id="$1"
  config_ensure
  [[ -f "$JANITOR_DISABLED_FILE" ]] || return 1
  grep -E "^[[:space:]]*${id}[[:space:]]*$" "$JANITOR_DISABLED_FILE" >/dev/null 2>&1
}

task_disable() {
  local id="$1"
  config_ensure
  if task_is_disabled "$id"; then
    echo "already disabled: $id"
    return 0
  fi
  echo "$id" >>"$JANITOR_DISABLED_FILE"
  echo "disabled: $id  ($JANITOR_DISABLED_FILE)"
}

task_enable() {
  local id="$1"
  config_ensure
  if [[ ! -f "$JANITOR_DISABLED_FILE" ]]; then
    echo "nothing disabled"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  grep -Ev "^[[:space:]]*${id}[[:space:]]*$" "$JANITOR_DISABLED_FILE" >"$tmp" || true
  mv "$tmp" "$JANITOR_DISABLED_FILE"
  echo "enabled: $id"
}

# should_run id — respects config disabled + JANITOR_ONLY=id1,id2
should_run() {
  local id="$1"
  if task_is_disabled "$id"; then
    return 1
  fi
  if [[ -n "${JANITOR_ONLY:-}" ]]; then
    case ",${JANITOR_ONLY}," in
      *",${id},"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

skip_reason_for() {
  local id="$1"
  if task_is_disabled "$id"; then
    echo "disabled in config"
    return
  fi
  if [[ -n "${JANITOR_ONLY:-}" ]]; then
    echo "not selected"
    return
  fi
  echo "skipped"
}

# Portable PATH so Finder / launchd find brew, node, flutter, etc.
janitor_augment_path() {
  local extras=()
  extras+=(/opt/homebrew/bin /usr/local/bin "$HOME/bin" /usr/bin /bin /usr/sbin /sbin)

  # nvm (any user)
  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    local nvm_node
    nvm_node="$(ls -d "$HOME/.nvm/versions/node"/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    [[ -n "${nvm_node:-}" ]] && extras+=("$nvm_node")
  fi

  # fnm / asdf shims
  [[ -d "$HOME/.local/share/fnm" ]] && extras+=("$HOME/.local/share/fnm")
  [[ -d "$HOME/.asdf/shims" ]] && extras+=("$HOME/.asdf/shims")

  # Flutter: prefer already-on-PATH; else probe common install locations (any user)
  if ! command -v flutter >/dev/null 2>&1; then
    local d
    for d in \
      "$HOME/flutter/bin" \
      "$HOME/development/flutter/bin" \
      "$HOME/sdk/flutter/bin" \
      "$HOME/src/flutter/bin" \
      "$HOME/tools/flutter/bin" \
      "/opt/flutter/bin"
    do
      if [[ -x "$d/flutter" ]]; then
        extras+=("$d")
        break
      fi
    done
  fi

  # Dart standalone
  [[ -d "$HOME/dart-sdk/bin" ]] && extras+=("$HOME/dart-sdk/bin")

  local p
  for p in "${extras[@]}"; do
    case ":${PATH}:" in
      *":${p}:"*) ;;
      *) PATH="${p}:${PATH}" ;;
    esac
  done
  export PATH
}

list_tasks() {
  config_ensure
  local i id label state
  printf '%-18s %-10s %s\n' "ID" "STATE" "LABEL"
  printf '%-18s %-10s %s\n' "------------------" "----------" "-----"
  for i in "${!JANITOR_TASK_IDS[@]}"; do
    id="${JANITOR_TASK_IDS[$i]}"
    label="${JANITOR_TASK_LABELS[$i]}"
    if task_is_disabled "$id"; then
      state="disabled"
    else
      state="enabled"
    fi
    printf '%-18s %-10s %s\n' "$id" "$state" "$label"
  done
  echo
  echo "Config: $JANITOR_DISABLED_FILE"
  echo "Disable: janitor disable <id>"
  echo "Enable:  janitor enable <id>"
}
