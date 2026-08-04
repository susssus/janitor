#!/bin/bash
# Cleanup tasks — Library-first, allowlisted paths only

# Status registry: "kb|label|path" lines collected then sorted
STATUS_ROWS=()

status_add() {
  local label="$1" path="$2" kb
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  kb="$(du_kb "$path")"
  STATUS_ROWS+=("${kb}|${label}|${path}")
}

report_sizes() {
  STATUS_ROWS=()

  # Default + deep measure paths (for status visibility)
  status_add "Homebrew cache" "$(brew --cache 2>/dev/null || echo /nonexistent)"
  status_add "npm cache (~/.npm)" "$HOME/.npm"
  status_add "pip cache" "$HOME/Library/Caches/pip"
  status_add "Gradle caches" "$HOME/.gradle/caches"
  status_add "Gradle daemon" "$HOME/.gradle/daemon"
  status_add "Android SDK downloads" "$HOME/Library/Android/sdk/.downloadIntermediates"
  status_add "Android cache" "$HOME/.android/cache"
  status_add "Android emulator qemu temps" "$HOME/Library/Android/sdk/emulator/qemu"
  status_add "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"
  status_add "Playwright" "$HOME/Library/Caches/ms-playwright"
  status_add "Google / Chrome" "$HOME/Library/Caches/Google"
  status_add "Hugging Face" "$HOME/.cache/huggingface"
  status_add "Stremio cache" "$HOME/Library/Application Support/stremio-server/stremio-cache"
  status_add "CocoaPods" "$HOME/Library/Caches/CocoaPods"
  status_add "Dart pub-cache" "$HOME/.pub-cache"
  status_add "Dart analysis server" "$HOME/.dartServer"
  status_add "CoreSimulator" "$HOME/Library/Developer/CoreSimulator"
  status_add "Library/Logs" "$HOME/Library/Logs"
  status_add "Cursor caches" "$HOME/Library/Caches/Cursor"
  # Deep targets (shown always so you see the hogs)
  status_add "Claude ShipIt cache" "$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt"
  status_add "Mozilla cache" "$HOME/Library/Caches/Mozilla"
  status_add "Firefox cache" "$HOME/Library/Caches/Firefox"
  status_add "Canva updater" "$HOME/Library/Caches/canva-updater"
  status_add "Steam cache" "$HOME/Library/Caches/Steam"
  status_add "Stremio5 cache" "$HOME/Library/Caches/com.westbridge.stremio5-mac"
  # Report-only big dirs (not cleaned by default)
  status_add "Cursor Application Support (report only)" "$HOME/Library/Application Support/Cursor"
  status_add "Docker Containers (report only)" "$HOME/Library/Containers/com.docker.docker"
  status_add "Android SDK tree (report only)" "$HOME/Library/Android"

  if [[ ${#STATUS_ROWS[@]} -eq 0 ]]; then
    echo "  (nothing found)"
    return 0
  fi

  local row kb label path rest
  # Sort numeric descending by kb
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    kb="${row%%|*}"
    rest="${row#*|}"
    label="${rest%%|*}"
    path="${rest#*|}"
    printf "  %8s  %s\n" "$(fmt_kb "$kb")" "$label"
  done < <(printf '%s\n' "${STATUS_ROWS[@]}" | sort -t'|' -k1,1nr)
}

# --- Individual cleaners ---

clean_homebrew() {
  if ! command -v brew >/dev/null 2>&1; then
    log_skip "homebrew" "Homebrew" "not installed"
    return 0
  fi
  local cache
  cache="$(brew --cache 2>/dev/null || true)"
  run_cmd_task "homebrew" "Homebrew" "$cache" \
    bash -c 'brew cleanup -s && brew autoremove'
}

clean_npm() {
  if ! command -v npm >/dev/null 2>&1; then
    log_skip "npm" "npm cache" "npm not found"
    return 0
  fi
  run_cmd_task "npm" "npm cache" "$HOME/.npm" \
    npm cache clean --force
}

clean_pip() {
  if command -v pip3 >/dev/null 2>&1; then
    run_cmd_task "pip3" "pip3 cache" "$HOME/Library/Caches/pip" \
      pip3 cache purge
  elif command -v pip >/dev/null 2>&1; then
    run_cmd_task "pip" "pip cache" "$HOME/Library/Caches/pip" \
      pip cache purge
  else
    log_skip "pip" "pip cache" "pip/pip3 not found"
  fi
}

clean_gradle() {
  run_path_task "gradle" "Gradle caches" "$HOME/.gradle/caches"
  run_path_task "gradle_daemon" "Gradle daemon" "$HOME/.gradle/daemon" contents
}

clean_android_downloads() {
  run_path_task "android_sdk_dl" "Android SDK downloads" \
    "$HOME/Library/Android/sdk/.downloadIntermediates"
}

clean_android_cache() {
  run_path_task "android_cache" "Android cache" "$HOME/.android/cache"
}

# Emulator qemu scratch (safe temps; keeps the emulator binary tree)
clean_android_qemu() {
  run_path_task "android_qemu" "Android emulator qemu temps" \
    "$HOME/Library/Android/sdk/emulator/qemu" contents
}

clean_xcode_derived() {
  run_path_task "xcode_derived" "Xcode DerivedData" \
    "$HOME/Library/Developer/Xcode/DerivedData" contents
}

clean_playwright() {
  run_path_task "playwright" "Playwright cache" \
    "$HOME/Library/Caches/ms-playwright"
}

clean_google() {
  run_path_task "google" "Google cache" "$HOME/Library/Caches/Google"
}

clean_huggingface() {
  run_path_task "huggingface" "Hugging Face cache" \
    "$HOME/.cache/huggingface"
}

clean_stremio() {
  local path="$HOME/Library/Application Support/stremio-server/stremio-cache"
  if pgrep -xq Stremio 2>/dev/null \
    || pgrep -fq 'Stremio\.app|stremio-server|/stremio$' 2>/dev/null; then
    log_skip "stremio" "Stremio cache" "Stremio is running" "$path"
    return 0
  fi
  run_path_task "stremio" "Stremio cache" "$path" contents
}

clean_cocoapods() {
  run_path_task "cocoapods" "CocoaPods cache" \
    "$HOME/Library/Caches/CocoaPods"
}

clean_dart_server() {
  run_path_task "dart_server" "Dart analysis server cache" \
    "$HOME/.dartServer"
}

clean_pub_cache() {
  # Prefer dart/flutter pub cache clean when available; else leave pub-cache alone
  # (full rm of ~/.pub-cache is painful for Flutter projects)
  if command -v dart >/dev/null 2>&1; then
    run_cmd_task "pub_cache" "Dart pub cache" "$HOME/.pub-cache" \
      dart pub cache clean --force
  elif command -v flutter >/dev/null 2>&1; then
    run_cmd_task "pub_cache" "Flutter pub cache" "$HOME/.pub-cache" \
      flutter pub cache clean -f
  else
    log_skip "pub_cache" "Dart/Flutter pub cache" "dart/flutter not found" \
      "$HOME/.pub-cache"
  fi
}

clean_simctl() {
  if ! command -v xcrun >/dev/null 2>&1; then
    log_skip "simctl" "Unavailable simulators" "xcrun not found"
    return 0
  fi
  local path="$HOME/Library/Developer/CoreSimulator"
  run_cmd_task "simctl" "Unavailable simulators" "$path" \
    xcrun simctl delete unavailable
}

clean_old_logs() {
  local logs_root="$HOME/Library/Logs"
  assert_safe_path "$logs_root" || return 0

  if [[ ! -d "$logs_root" ]]; then
    log_skip "old_logs" "Old Library/Logs" "missing" "$logs_root"
    return 0
  fi

  local before after freed status ts
  before="$(du_kb "$logs_root")"
  ts="$(date -Iseconds 2>/dev/null || date)"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    # Estimate: size of files older than 14d excluding janitor/
    local estimate=0
    estimate="$(find "$logs_root" -type f -mtime +14 \
      ! -path "$logs_root/janitor/*" \
      -exec du -sk {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')" || estimate=0
    freed="$estimate"
    log_echo "• Old Library/Logs (>14d)  [dry-run]  would free ~$(fmt_kb "$freed")"
    log_line "  path=$logs_root before_kb=$before after_kb=0 freed_kb=$freed status=dry-run"
    history_append "$ts" "old_logs" "$logs_root" "$before" 0 "$freed" "dry-run"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
    TOTAL_TASKS=$((TOTAL_TASKS + 1))
    return 0
  fi

  find "$logs_root" -type f -mtime +14 \
    ! -path "$logs_root/janitor/*" \
    -delete 2>/dev/null || true
  # Remove empty dirs left behind (not janitor)
  find "$logs_root" -mindepth 1 -type d -empty \
    ! -path "$logs_root/janitor" \
    ! -path "$logs_root/janitor/*" \
    -delete 2>/dev/null || true

  after="$(du_kb "$logs_root")"
  freed=$(( before - after ))
  if [[ "$freed" -lt 0 ]]; then freed=0; fi
  status="ok"
  log_echo "• Old Library/Logs (>14d)  freed $(fmt_kb "$freed")"
  log_line "  path=$logs_root before_kb=$before after_kb=$after freed_kb=$freed status=$status"
  history_append "$ts" "old_logs" "$logs_root" "$before" "$after" "$freed" "$status"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

clean_cursor_caches() {
  run_path_task "cursor_caches" "Cursor caches" "$HOME/Library/Caches/Cursor"
}

# --deep only ---

clean_deep_caches() {
  local paths=(
    "shipit|$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt|Claude ShipIt cache"
    "mozilla|$HOME/Library/Caches/Mozilla|Mozilla cache"
    "firefox|$HOME/Library/Caches/Firefox|Firefox cache"
    "canva|$HOME/Library/Caches/canva-updater|Canva updater cache"
    "steam|$HOME/Library/Caches/Steam|Steam cache"
    "stremio5|$HOME/Library/Caches/com.westbridge.stremio5-mac|Stremio5 cache"
  )
  local entry id path label
  for entry in "${paths[@]}"; do
    id="${entry%%|*}"
    rest="${entry#*|}"
    path="${rest%%|*}"
    label="${rest#*|}"
    run_path_task "$id" "$label" "$path"
  done
}

run_all_cleaners() {
  clean_homebrew
  clean_npm
  clean_pip
  clean_gradle
  clean_android_downloads
  clean_android_cache
  clean_android_qemu
  clean_xcode_derived
  clean_playwright
  clean_google
  clean_huggingface
  clean_stremio
  clean_cocoapods
  clean_dart_server
  clean_pub_cache
  clean_simctl
  clean_old_logs
  clean_cursor_caches

  if [[ "${DEEP:-0}" -eq 1 ]]; then
    log_echo ""
    log_echo "— deep profile —"
    clean_deep_caches
  fi
}
