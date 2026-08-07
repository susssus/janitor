#!/bin/bash
# Cleanup tasks : Library-first, allowlisted paths only (dev caches)

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
 echo " (no hogs found)"
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
 printf ' %8s %s\n' "$(fmt_kb "$kb")" "$label"
 printf ' %s\n' "$path"
 else
 hog_row "$id" "$(fmt_kb "$kb")" "$label"
 fi
 done < <(printf '%s\n' "${STATUS_ROWS[@]}" | sort -t'|' -k1,1nr)
}

# --- Cmd cleaners (catalog kind=cmd) ---

# brew cleanup -n … → KB. Honest reclaim estimate (not whole cache du).
brew_cleanup_estimate_kb() {
 local out num unit
 out="$(brew cleanup -n -s --prune=all 2>/dev/null || true)"
 # "==> This operation would free approximately 451.3MB of disk space."
 num="$(printf '%s\n' "$out" | sed -nE 's/.*approximately[[:space:]]+([0-9.]+)(KB|MB|GB|TB).*/\1/p' | tail -1)"
 unit="$(printf '%s\n' "$out" | sed -nE 's/.*approximately[[:space:]]+[0-9.]+(KB|MB|GB|TB).*/\1/p' | tail -1)"
 if [[ -z "$num" || -z "$unit" ]]; then
  echo 0
  return 0
 fi
 case "$unit" in
  KB) awk -v n="$num" 'BEGIN { printf "%d\n", n }' ;;
  MB) awk -v n="$num" 'BEGIN { printf "%d\n", n * 1024 }' ;;
  GB) awk -v n="$num" 'BEGIN { printf "%d\n", n * 1024 * 1024 }' ;;
  TB) awk -v n="$num" 'BEGIN { printf "%d\n", n * 1024 * 1024 * 1024 }' ;;
  *) echo 0 ;;
 esac
}

clean_homebrew() {
 if ! command -v brew >/dev/null 2>&1; then
  log_skip "homebrew" "Homebrew" "not installed"
  return 0
 fi

 local id="homebrew" label="Homebrew"
 local cache
 cache="$(brew --cache 2>/dev/null || true)"
 [[ -n "$cache" ]] || cache="$HOME/Library/Caches/Homebrew"

 if ! should_run "$id"; then
  log_skip "$id" "$label" "$(skip_reason_for "$id")" "$cache"
  return 0
 fi

 if [[ -n "$cache" ]] && ! assert_safe_path "$cache"; then
  log_task refuse "$label" "unsafe measure path" "$cache"
  return 0
 fi

 local before after freed status ts rc
 before=0
 [[ -n "$cache" && -e "$cache" ]] && before="$(du_kb "$cache")"
 ts="$(date -Iseconds 2>/dev/null || date)"

 # Plain `brew cleanup -s` barely moves the needle; --prune=all is what
 # actually frees old bottles/downloads. Assess must use brew's own estimate
 # (whole-cache du lied: ~521M shown, 0K freed).
 if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
  freed="$(brew_cleanup_estimate_kb)"
  if [[ "${freed:-0}" -le 0 ]]; then
   log_skip "$id" "$label" "brew has nothing to prune right now" "$cache"
   return 0
  fi
  status="dry run"
  log_task dry "$label" "would free ~$(fmt_kb "$freed") (brew cleanup -s --prune=all)" "$cache"
  log_line " path=${cache:--} before_kb=$before after_kb=0 freed_kb=$freed status=$status cmd=brew cleanup -s --prune=all"
  history_append "$ts" "$id" "${cache:--}" "$before" 0 "$freed" "$status"
  assess_append "$id" "$label" "$freed" "$status"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
  return 0
 fi

 rc=0
 if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  brew cleanup -s --prune=all || rc=$?
  brew autoremove || true
 else
  brew cleanup -s --prune=all >/dev/null 2>&1 || rc=$?
  brew autoremove >/dev/null 2>&1 || true
 fi

 after=0
 [[ -n "$cache" && -e "$cache" ]] && after="$(du_kb "$cache")"
 freed=$(( before - after ))
 if [[ "$freed" -lt 0 ]]; then freed=0; fi

 if [[ "$rc" -ne 0 && "$freed" -eq 0 ]]; then
  log_task skip "$label" "brew cleanup failed (exit $rc)" "$cache"
  log_line " path=${cache:--} before_kb=$before after_kb=$after freed_kb=0 status=failed exit=$rc"
  history_append "$ts" "$id" "${cache:--}" "$before" "$after" 0 "failed:$rc"
  return 0
 fi

 status="ok"
 log_task ok "$label" "freed $(fmt_kb "$freed")" "$cache"
 log_line " path=${cache:--} before_kb=$before after_kb=$after freed_kb=$freed status=$status exit=$rc"
 history_append "$ts" "$id" "${cache:--}" "$before" "$after" "$freed" "$status"
 assess_append "$id" "$label" "$freed" "$status"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
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
 log_skip "pip" "pip cache" "pip3 present; skipped"
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

 local id="simctl" label="Unavailable simulators"
 local path="$HOME/Library/Developer/CoreSimulator"
 local devices_root="$path/Devices"

 if ! should_run "$id"; then
 log_skip "$id" "$label" "$(skip_reason_for "$id")" "$path"
 return 0
 fi

 # UUIDs listed as unavailable (working sims must stay)
 local uuids=()
 local line uuid
 while IFS= read -r line; do
 [[ -z "$line" ]] && continue
 uuid="$(printf '%s' "$line" | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}' | head -1 || true)"
 [[ -n "$uuid" ]] && uuids+=("$uuid")
 done < <(xcrun simctl list devices unavailable 2>/dev/null || true)

 if [[ ${#uuids[@]} -eq 0 ]]; then
 log_skip "$id" "$label" "none unavailable (working sims kept)" "$path"
 return 0
 fi

 # Estimate only unavailable device dirs (not whole CoreSimulator)
 local estimate=0 dkb
 for uuid in "${uuids[@]}"; do
 if [[ -d "$devices_root/$uuid" ]]; then
 dkb="$(du_kb "$devices_root/$uuid")"
 estimate=$((estimate + dkb))
 fi
 done

 local before after freed status ts
 before="$(du_kb "$path")"
 ts="$(date -Iseconds 2>/dev/null || date)"

 if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
 freed="$estimate"
 log_task dry "$label" "would free ~$(fmt_kb "$freed") (${#uuids[@]} unavailable)" "$path"
 log_line " path=$(abs_path "$path") before_kb=$before after_kb=0 freed_kb=$freed status=dry run unavailable=${#uuids[@]}"
 history_append "$ts" "$id" "$path" "$before" 0 "$freed" "dry run"
 assess_append "$id" "$label" "$freed" "dry run"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
 return 0
 fi

 xcrun simctl delete unavailable >/dev/null 2>&1 || true
 after="$(du_kb "$path")"
 freed=$(( before - after ))
 if [[ "$freed" -lt 0 ]]; then freed=0; fi
 status="ok"
 log_task ok "$label" "freed $(fmt_kb "$freed") (${#uuids[@]} unavailable)" "$path"
 log_line " path=$(abs_path "$path") before_kb=$before after_kb=$after freed_kb=$freed status=$status"
 history_append "$ts" "$id" "$path" "$before" "$after" "$freed" "$status"
 assess_append "$id" "$label" "$freed" "$status"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
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
 log_line " path=$(abs_path "$logs_root") before_kb=$before after_kb=0 freed_kb=$freed status=dry run"
 history_append "$ts" "$id" "$logs_root" "$before" 0 "$freed" "dry run"
 assess_append "$id" "$label" "$freed" "dry run"
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
 log_line " path=$(abs_path "$logs_root") before_kb=$before after_kb=$after freed_kb=$freed status=$status"
 history_append "$ts" "$id" "$logs_root" "$before" "$after" "$freed" "$status"
 assess_append "$id" "$label" "$freed" "$status"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

# List …/Containers/*/Data/Library/Caches directories (null-safe via newlines; paths rarely have newlines)
list_container_cache_dirs() {
 local root="$HOME/Library/Containers"
 [[ -d "$root" ]] || return 0
 find "$root" -type d -path '*/Data/Library/Caches' 2>/dev/null || true
}

list_as_cache_dirs() {
 local root="$HOME/Library/Application Support"
 [[ -d "$root" ]] || return 0
 # Depth-limited: Cache/Caches leaves only (never whole AS apps)
 find "$root" -type d \( -name Cache -o -name Caches \) 2>/dev/null || true
}

sum_dirs_kb() {
 local total=0 kb d
 for d in "$@"; do
 [[ -d "$d" ]] || continue
 kb="$(du_kb "$d")"
 total=$((total + kb))
 done
 echo "$total"
}

clean_container_caches() {
 local id="container_caches" label="Sandboxed app caches"
 local measure="$HOME/Library/Containers"

 if ! should_run "$id"; then
  log_skip "$id" "$label" "$(skip_reason_for "$id")" "$measure"
  return 0
 fi

 local dirs=() d
 while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  is_container_caches_path "$(abs_path "$d")" || continue
  dirs+=("$d")
 done < <(list_container_cache_dirs)

 if [[ ${#dirs[@]} -eq 0 ]]; then
  log_skip "$id" "$label" "no container caches found" "$measure"
  return 0
 fi

 local estimate before after freed status ts
 estimate="$(sum_dirs_kb "${dirs[@]}")"
 ts="$(date -Iseconds 2>/dev/null || date)"
 before="$estimate"

 if [[ "${estimate:-0}" -le 0 ]]; then
  log_skip "$id" "$label" "nothing reclaimable" "$measure"
  return 0
 fi

 if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
  log_task dry "$label" "would free ~$(fmt_kb "$estimate") (${#dirs[@]} dirs)" "$measure"
  log_line " path=$(abs_path "$measure") before_kb=$before after_kb=0 freed_kb=$estimate status=dry run dirs=${#dirs[@]}"
  history_append "$ts" "$id" "$measure" "$before" 0 "$estimate" "dry run"
  assess_append "$id" "$label" "$estimate" "dry run"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + estimate))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
  return 0
 fi

 for d in "${dirs[@]}"; do
  assert_safe_path "$d" || continue
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
 done

 after="$(sum_dirs_kb "${dirs[@]}")"
 freed=$(( before - after ))
 if [[ "$freed" -lt 0 ]]; then freed=0; fi
 status="ok"
 log_task ok "$label" "freed $(fmt_kb "$freed") (${#dirs[@]} dirs)" "$measure"
 log_line " path=$(abs_path "$measure") before_kb=$before after_kb=$after freed_kb=$freed status=$status dirs=${#dirs[@]}"
 history_append "$ts" "$id" "$measure" "$before" "$after" "$freed" "$status"
 assess_append "$id" "$label" "$freed" "$status"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

clean_as_caches() {
 local id="as_caches" label="Application Support Cache folders"
 local measure="$HOME/Library/Application Support"

 if ! should_run "$id"; then
  log_skip "$id" "$label" "$(skip_reason_for "$id")" "$measure"
  return 0
 fi

 local dirs=() d
 while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  is_application_support_cache_path "$(abs_path "$d")" || continue
  dirs+=("$d")
 done < <(list_as_cache_dirs)

 if [[ ${#dirs[@]} -eq 0 ]]; then
  log_skip "$id" "$label" "no Application Support Cache folders" "$measure"
  return 0
 fi

 local estimate before after freed status ts
 estimate="$(sum_dirs_kb "${dirs[@]}")"
 ts="$(date -Iseconds 2>/dev/null || date)"
 before="$estimate"

 if [[ "${estimate:-0}" -le 0 ]]; then
  log_skip "$id" "$label" "nothing reclaimable" "$measure"
  return 0
 fi

 if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
  log_task dry "$label" "would free ~$(fmt_kb "$estimate") (${#dirs[@]} dirs)" "$measure"
  log_line " path=$(abs_path "$measure") before_kb=$before after_kb=0 freed_kb=$estimate status=dry run dirs=${#dirs[@]}"
  history_append "$ts" "$id" "$measure" "$before" 0 "$estimate" "dry run"
  assess_append "$id" "$label" "$estimate" "dry run"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + estimate))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
  return 0
 fi

 for d in "${dirs[@]}"; do
  assert_safe_path "$d" || continue
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
 done

 after="$(sum_dirs_kb "${dirs[@]}")"
 freed=$(( before - after ))
 if [[ "$freed" -lt 0 ]]; then freed=0; fi
 status="ok"
 log_task ok "$label" "freed $(fmt_kb "$freed") (${#dirs[@]} dirs)" "$measure"
 log_line " path=$(abs_path "$measure") before_kb=$before after_kb=$after freed_kb=$freed status=$status dirs=${#dirs[@]}"
 history_append "$ts" "$id" "$measure" "$before" "$after" "$freed" "$status"
 assess_append "$id" "$label" "$freed" "$status"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

# Parse docker system df reclaimable sizes → KB (best effort, portable awk)
docker_reclaimable_estimate_kb() {
 local out
 out="$(docker system df 2>/dev/null || true)"
 [[ -n "$out" ]] || { echo 0; return 0; }
 printf '%s\n' "$out" | grep -oE '[0-9]+(\.[0-9]+)?(B|KB|MB|GB|TB)[[:space:]]*\(' | sed 's/[[:space:]]*(//' | awk '
 {
  n = $0 + 0
  if ($0 ~ /TB$/) kb = n * 1024 * 1024 * 1024
  else if ($0 ~ /GB$/) kb = n * 1024 * 1024
  else if ($0 ~ /MB$/) kb = n * 1024
  else if ($0 ~ /KB$/) kb = n
  else kb = n / 1024
  s += kb
 }
 END { printf "%d\n", s + 0 }
 '
}

clean_docker_prune() {
 local id="docker_prune" label="Docker prune"

 if ! command -v docker >/dev/null 2>&1; then
  log_skip "$id" "$label" "docker not found"
  return 0
 fi
 if ! should_run "$id"; then
  log_skip "$id" "$label" "$(skip_reason_for "$id")"
  return 0
 fi

 local estimate freed status ts rc
 estimate="$(docker_reclaimable_estimate_kb)"
 ts="$(date -Iseconds 2>/dev/null || date)"

 if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
  if [[ "${estimate:-0}" -le 0 ]]; then
   log_skip "$id" "$label" "docker reports nothing reclaimable"
   return 0
  fi
  log_task dry "$label" "would free ~$(fmt_kb "$estimate") (docker system prune)" "-"
  log_line " path=- before_kb=$estimate after_kb=0 freed_kb=$estimate status=dry run cmd=docker system prune"
  history_append "$ts" "$id" "-" "$estimate" 0 "$estimate" "dry run"
  assess_append "$id" "$label" "$estimate" "dry run"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + estimate))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
  return 0
 fi

 local before_est after_est
 before_est="$estimate"
 rc=0
 if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  docker system prune -af || rc=$?
  docker builder prune -af || true
 else
  docker system prune -af >/dev/null 2>&1 || rc=$?
  docker builder prune -af >/dev/null 2>&1 || true
 fi
 after_est="$(docker_reclaimable_estimate_kb)"
 freed=$(( before_est - after_est ))
 if [[ "$freed" -lt 0 ]]; then freed=0; fi
 # If estimate was 0 but prune ran, still report ok with 0 rather than lie
 if [[ "$rc" -ne 0 && "$freed" -eq 0 ]]; then
  log_task skip "$label" "docker prune failed (exit $rc)" "-"
  history_append "$ts" "$id" "-" "$before_est" "$after_est" 0 "failed:$rc"
  return 0
 fi
 status="ok"
 log_task ok "$label" "freed $(fmt_kb "$freed")" "-"
 log_line " path=- before_kb=$before_est after_kb=$after_est freed_kb=$freed status=$status exit=$rc"
 history_append "$ts" "$id" "-" "$before_est" "$after_est" "$freed" "$status"
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
 container_caches) clean_container_caches ;;
 as_caches) clean_as_caches ;;
 docker_prune) clean_docker_prune ;;
 *)
 log_skip "$id" "$(task_label "$id")" "no cmd cleaner"
 ;;
 esac
}

run_all_cleaners() {
 local i id kind
 local deep_banner=0
 local brave_banner=0
 local stupid_banner=0

 for i in "${!JANITOR_TASK_IDS[@]}"; do
 id="${JANITOR_TASK_IDS[$i]}"
 kind="${JANITOR_TASK_KINDS[$i]}"

 if [[ -n "${JANITOR_ONLY:-}" ]]; then
 should_run "$id" || continue
 elif ! should_run "$id" && ! hog_is_in_enabled_set "$id"; then
 continue
 fi

 if hog_unlocked_by_deep "$id" && [[ "$deep_banner" -eq 0 ]]; then
 log_echo ""
 log_echo "${C_CYAN}${C_BOLD}── deep profile ──${C_RESET}"
 deep_banner=1
 fi
 if hog_unlocked_by_stupid "$id" && [[ "$stupid_banner" -eq 0 ]]; then
 log_echo ""
 log_echo "${C_YELLOW}${C_BOLD}── just stupid profile ──${C_RESET}"
 log_echo "${C_DIM}Past-cache regenerables (containers / AS Cache folders / Docker). Still never Documents or Downloads.${C_RESET}"
 stupid_banner=1
 fi
 if hog_unlocked_by_brave "$id" && [[ "$brave_banner" -eq 0 ]]; then
 log_echo ""
 log_echo "${C_YELLOW}${C_BOLD}── brave profile ──${C_RESET}"
 log_echo "${C_DIM}Wider caches (browsers/media). Still never Documents or Downloads.${C_RESET}"
 brave_banner=1
 fi

 if [[ "$kind" == "path" ]]; then
 clean_path_hog "$i"
 else
 clean_cmd_hog "$id"
 fi
 done
}
