#!/bin/bash
# Cleanup tasks — Library-first, allowlisted paths only (dev caches)

# Status / hog rows: "kb|id|label|path"
STATUS_ROWS=()

status_add_hog() {
  local id="$1" label="$2" path="$3" kb
  if [[ -z "$path" || ! -e "$path" ]]; then
    return 0
  fi
  kb="$(du_kb "$path")"
  STATUS_ROWS+=("${kb}|${id}|${label}|${path}")
}

report_sizes() {
  STATUS_ROWS=()
  local i id label path

  for i in "${!JANITOR_TASK_IDS[@]}"; do
    id="${JANITOR_TASK_IDS[$i]}"
    label="${JANITOR_TASK_LABELS[$i]}"
    path="$(hog_measure_path "$id" 2>/dev/null || true)"
    status_add_hog "$id" "$label" "$path"
  done

  # Report-only big dirs (never cleaned)
  status_add_hog "_report_cursor_as" "Cursor Application Support (report only)" \
    "$HOME/Library/Application Support/Cursor"
  status_add_hog "_report_docker" "Docker Containers (report only)" \
    "$HOME/Library/Containers/com.docker.docker"
  status_add_hog "_report_android_sdk" "Android SDK tree (report only)" \
    "$HOME/Library/Android"

  if [[ ${#STATUS_ROWS[@]} -eq 0 ]]; then
    echo "  (no hogs found)"
    return 0
  fi

  local row kb id label path rest
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    kb="${row%%|*}"
    rest="${row#*|}"
    id="${rest%%|*}"
    rest="${rest#*|}"
    label="${rest%%|*}"
    path="${rest#*|}"
    if [[ "$id" == _report_* ]]; then
      printf '  %8s  %s\n' "$(fmt_kb "$kb")" "$label"
      printf '           %s\n' "$path"
    else
      hog_row "$id" "$(fmt_kb "$kb")" "$label"
    fi
  done < <(printf '%s\n' "${STATUS_ROWS[@]}" | sort -t'|' -k1,1nr)
}

# --- Cmd cleaners (catalog kind=cmd) ---

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

clean_pip3() {
  if ! command -v pip3 >/dev/null 2>&1; then
    log_skip "pip3" "pip3 cache" "pip3 not found"
    return 0
  fi
  run_cmd_task "pip3" "pip3 cache" "$HOME/Library/Caches/pip" \
    pip3 cache purge
}

clean_pip() {
  if command -v pip3 >/dev/null 2>&1; then
    log_skip "pip" "pip cache" "pip3 present — skipped"
    return 0
  fi
  if ! command -v pip >/dev/null 2>&1; then
    log_skip "pip" "pip cache" "pip not found"
    return 0
  fi
  run_cmd_task "pip" "pip cache" "$HOME/Library/Caches/pip" \
    pip cache purge
}

clean_pub_cache() {
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
  local id="old_logs" label="Old Library/Logs (>14d)"

  if ! should_run "$id"; then
    log_skip "$id" "$label" "$(skip_reason_for "$id")" "$logs_root"
    return 0
  fi

  assert_safe_path "$logs_root" || return 0

  if [[ ! -d "$logs_root" ]]; then
    log_skip "$id" "$label" "missing" "$logs_root"
    return 0
  fi

  local before after freed status ts
  before="$(du_kb "$logs_root")"
  ts="$(date -Iseconds 2>/dev/null || date)"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    local estimate=0
    estimate="$(find "$logs_root" -type f -mtime +14 \
      ! -path "$logs_root/janitor/*" \
      -exec du -sk {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')" || estimate=0
    freed="$estimate"
    log_task dry "$label" "would free ~$(fmt_kb "$freed")" "$logs_root"
    log_line "  path=$(abs_path "$logs_root") before_kb=$before after_kb=0 freed_kb=$freed status=dry-run"
    history_append "$ts" "$id" "$logs_root" "$before" 0 "$freed" "dry-run"
    assess_append "$id" "$label" "$freed" "dry-run"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
    TOTAL_TASKS=$((TOTAL_TASKS + 1))
    return 0
  fi

  find "$logs_root" -type f -mtime +14 \
    ! -path "$logs_root/janitor/*" \
    -delete 2>/dev/null || true
  find "$logs_root" -mindepth 1 -type d -empty \
    ! -path "$logs_root/janitor" \
    ! -path "$logs_root/janitor/*" \
    -delete 2>/dev/null || true

  after="$(du_kb "$logs_root")"
  freed=$(( before - after ))
  if [[ "$freed" -lt 0 ]]; then freed=0; fi
  status="ok"
  log_task ok "$label" "freed $(fmt_kb "$freed")" "$logs_root"
  log_line "  path=$(abs_path "$logs_root") before_kb=$before after_kb=$after freed_kb=$freed status=$status"
  history_append "$ts" "$id" "$logs_root" "$before" "$after" "$freed" "$status"
  assess_append "$id" "$label" "$freed" "$status"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

# Run one catalog/custom path hog via run_path_task
clean_path_hog() {
  local i="$1"
  local id="${JANITOR_TASK_IDS[$i]}"
  local label="${JANITOR_TASK_LABELS[$i]}"
  local path="${JANITOR_TASK_PATHS[$i]}"
  local mode="${JANITOR_TASK_MODES[$i]}"
  run_path_task "$id" "$label" "$path" "$mode"
}

# Dispatch a cmd hog by id
clean_cmd_hog() {
  local id="$1"
  case "$id" in
    homebrew) clean_homebrew ;;
    npm) clean_npm ;;
    pip) clean_pip ;;
    pip3) clean_pip3 ;;
    pub_cache) clean_pub_cache ;;
    simctl) clean_simctl ;;
    old_logs) clean_old_logs ;;
    *)
      log_skip "$id" "$(task_label "$id")" "no cmd cleaner"
      ;;
  esac
}

run_all_cleaners() {
  local i id kind
  local deep_banner=0

  for i in "${!JANITOR_TASK_IDS[@]}"; do
    id="${JANITOR_TASK_IDS[$i]}"
    kind="${JANITOR_TASK_KINDS[$i]}"

    if [[ -n "${JANITOR_ONLY:-}" ]]; then
      # --only: run matching ids only; no skip spam for the rest
      should_run "$id" || continue
    elif ! should_run "$id" && ! hog_is_in_enabled_set "$id"; then
      # Silent skip: default-off catalog hogs unless adopted or --deep
      continue
    fi

    if hog_unlocked_by_deep "$id" && [[ "$deep_banner" -eq 0 ]]; then
      log_echo ""
      log_echo "${C_CYAN}${C_BOLD}── deep profile ──${C_RESET}"
      deep_banner=1
    fi

    if [[ "$kind" == "path" ]]; then
      clean_path_hog "$i"
    else
      clean_cmd_hog "$id"
    fi
  done
}
