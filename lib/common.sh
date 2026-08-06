#!/bin/bash
# Shared helpers for janitor — logging, path safety, task runner

JANITOR_LOG_DIR="${JANITOR_LOG_DIR:-$HOME/Library/Logs/janitor}"
JANITOR_HISTORY="$JANITOR_LOG_DIR/history.tsv"
JANITOR_ASSESS_TSV="$JANITOR_LOG_DIR/last-assess.tsv"

# Sacrosanct — never touch (personal files)
SACROSANCT_DIRS=(
  "$HOME/Documents"
  "$HOME/Downloads"
)

# Positive allowlist — only these cache-like roots may be cleaned
janitor_allowlist_roots() {
  local roots=(
    "$HOME/Library/Caches"
    "$HOME/Library/Logs"
    "$HOME/Library/Developer"
    "$HOME/Library/Android"
    "$HOME/.cache"
    "$HOME/.npm"
    "$HOME/.gradle"
    "$HOME/.pub-cache"
    "$HOME/.dartServer"
    "$HOME/.android"
    # Narrow media-server cache (brave catalog); never whole Application Support
    "$HOME/Library/Application Support/stremio-server"
  )
  local brew_cache
  brew_cache="$(brew --cache 2>/dev/null || true)"
  if [[ -n "${brew_cache:-}" ]]; then
    roots+=("$brew_cache")
  fi
  printf '%s\n' "${roots[@]}"
}

die() {
  echo "janitor: $*" >&2
  exit 1
}

# --- Terminal candies (sanemaker-style): colors + kaomoji, no emoji ---
# Respect NO_COLOR / non-TTY. Logs stay plain (strip codes).

janitor_color_init() {
  if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
    return 0
  fi
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
}
janitor_color_init

# Kaomoji (ASCII-friendly Japanese emoticons)
K_FACE='(*^▽^*)'
K_SWEEP='(｀・ω・´)'
K_OK='(＾▽＾)'
K_DRY='(・・?)'
K_SKIP='(・_・;)'
K_NOPE='(>_<)'
K_DONE='☆*:.｡.o(≧▽≦)o.｡.:*☆'
K_WARN='(；￣Д￣)'

strip_ansi() {
  # shellcheck disable=SC2001
  printf '%s' "$*" | sed $'s/\033\\[[0-9;]*[mK]//g'
}

c_echo() {
  printf '%s\n' "$*"
}

c_or_log() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    log_echo "$*"
  else
    c_echo "$*"
  fi
}

banner() {
  local title="$1"
  local face="${2:-$K_FACE}"
  c_or_log "${C_CYAN}${C_BOLD}────────────────────────────────────────${C_RESET}"
  c_or_log "${C_CYAN}${C_BOLD}  ${face}  ${title}${C_RESET}"
  c_or_log "${C_CYAN}${C_BOLD}────────────────────────────────────────${C_RESET}"
}

section() {
  local title="$1"
  c_or_log "${C_BLUE}${C_BOLD}── ${title} ──${C_RESET}"
}

# Free space on home volume, in KB
free_kb() {
  df -k ~ | awk 'NR==2 {print $4}'
}

# Size of path in KB (0 if missing / unreadable)
du_kb() {
  local path="$1" kb
  if [[ ! -e "$path" ]]; then
    echo 0
    return 0
  fi
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')" || true
  echo "${kb:-0}"
}

# Human-readable from KB
fmt_kb() {
  local kb="${1:-0}"
  if [[ "$kb" -ge 1048576 ]]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fG", k/1048576 }'
  elif [[ "$kb" -ge 1024 ]]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fM", k/1024 }'
  else
    echo "${kb}K"
  fi
}

# Human-readable size of a path (— if missing)
path_size() {
  local path="$1" kb
  if [[ ! -e "$path" ]]; then
    echo "—"
    return 0
  fi
  kb="$(du_kb "$path")"
  if [[ "$kb" -eq 0 ]]; then
    # Exists but empty / unreadable
    local raw
    raw="$(du -sh "$path" 2>/dev/null | awk '{print $1}')" || true
    echo "${raw:-—}"
  else
    fmt_kb "$kb"
  fi
}

# Resolve to absolute path without requiring existence
abs_path() {
  local path="$1"
  if [[ "$path" == "~"* ]]; then
    path="${path/#\~/$HOME}"
  fi
  if [[ "$path" != /* ]]; then
    path="$(pwd)/$path"
  fi
  # Normalize .. and . when parent exists
  local dir base
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [[ -d "$dir" ]]; then
    echo "$(cd "$dir" && pwd)/$base"
  else
    echo "$path"
  fi
}

# Return 0 if path is under a sacrosanct directory
is_sacrosanct() {
  local resolved="$1" forbidden
  for forbidden in "${SACROSANCT_DIRS[@]}"; do
    if [[ "$resolved" == "$forbidden" || "$resolved" == "$forbidden"/* ]]; then
      return 0
    fi
  done
  return 1
}

# Return 0 if path is under an allowlisted cache root
path_is_allowlisted() {
  local resolved="$1" root
  resolved="$(abs_path "$resolved")"
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    root="$(abs_path "$root")"
    if [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]]; then
      return 0
    fi
  done < <(janitor_allowlist_roots)
  return 1
}

# Abort (or return non-zero) if path is forbidden or outside allowlist
assert_safe_path() {
  local path="$1"
  local resolved
  resolved="$(abs_path "$path")"
  if is_sacrosanct "$resolved"; then
    echo "janitor: REFUSED unsafe path (Documents/Downloads are sacrosanct): $resolved" >&2
    return 1
  fi
  if ! path_is_allowlisted "$resolved"; then
    echo "janitor: REFUSED path outside allowlisted cache roots: $resolved" >&2
    return 1
  fi
  return 0
}

# --- Logging ---

log_init() {
  local mode="${1:-clean}"
  mkdir -p "$JANITOR_LOG_DIR"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  LOG_FILE="$JANITOR_LOG_DIR/${mode}-${stamp}.log"
  TOTAL_FREED_KB=0
  TOTAL_TASKS=0
  : >"$LOG_FILE"
  # Fresh assess sheet for checkbox UI / --only selection
  printf 'id\tlabel\tfreed_kb\tstatus\n' >"$JANITOR_ASSESS_TSV"
  if [[ ! -f "$JANITOR_HISTORY" ]]; then
    printf 'timestamp\ttask_id\tpath\tbefore_kb\tafter_kb\tfreed_kb\tstatus\n' >"$JANITOR_HISTORY"
  fi
  {
    echo "# janitor ${mode}  $(date -Iseconds 2>/dev/null || date)"
    echo "# host=$(hostname -s 2>/dev/null || hostname)  user=$USER"
    echo "# dry_run=${DRY_RUN:-0}  deep=${DEEP:-0}  brave=${BRAVE:-0}  only=${JANITOR_ONLY:--}"
    echo "#"
  } >>"$LOG_FILE"
  ln -sfn "$LOG_FILE" "$JANITOR_LOG_DIR/latest.log"
}

log_line() {
  local msg="$*"
  [[ -n "${LOG_FILE:-}" ]] || return 0
  echo "$msg" >>"$LOG_FILE"
}

log_echo() {
  # Colored console + plain log
  local msg="$*"
  local plain
  plain="$(strip_ansi "$msg")"
  printf '%s\n' "$msg"
  log_line "$plain"
}

# Pretty task line + always-visible absolute path (second line).
# kind: ok | dry | skip | refuse | done
log_task() {
  local kind="$1" label="$2" detail="$3" path="${4:--}"
  local face mark color path_show
  case "$kind" in
    ok)     face="$K_OK";   mark="ok";      color="$C_GREEN" ;;
    dry)    face="$K_DRY";  mark="dry-run"; color="$C_YELLOW" ;;
    skip)   face="$K_SKIP"; mark="skip";    color="$C_DIM" ;;
    refuse) face="$K_NOPE"; mark="refuse";  color="$C_RED" ;;
    done)   face="$K_OK";   mark="done";    color="$C_GREEN" ;;
    *)      face="$K_SWEEP"; mark="$kind";  color="$C_CYAN" ;;
  esac
  path_show="$path"
  if [[ "$path" != "-" && -n "$path" ]]; then
    path_show="$(abs_path "$path")"
  fi
  log_echo "${color}${face}${C_RESET} ${C_BOLD}${label}${C_RESET}  [${mark}]  ${detail}"
  log_echo "    ${C_DIM}${path_show}${C_RESET}"
}

history_append() {
  local ts task_id path before after freed status
  ts="$1"; task_id="$2"; path="$3"; before="$4"; after="$5"; freed="$6"; status="$7"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$task_id" "$path" "$before" "$after" "$freed" "$status" >>"$JANITOR_HISTORY"
}

# Record a selectable assess row (for desktop checkboxes)
assess_append() {
  local id="$1" label="$2" freed="$3" status="$4"
  printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$freed" "$status" >>"$JANITOR_ASSESS_TSV"
}

# Remove a path tree after safety check
rm_path() {
  local path="$1"
  assert_safe_path "$path" || return 1
  if [[ -e "$path" ]]; then
    rm -rf "$path"
  fi
}

# Clear contents of a directory (keep the dir)
clear_dir_contents() {
  local path="$1"
  assert_safe_path "$path" || return 1
  if [[ -d "$path" ]]; then
    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
}

# Run a measured path-delete task.
# Args: id label path [mode]
#   mode: remove (default) | contents
run_path_task() {
  local id="$1" label="$2" path="$3" mode="${4:-remove}"
  local before after freed status ts

  if ! should_run "$id"; then
    log_skip "$id" "$label" "$(skip_reason_for "$id")" "$path"
    return 0
  fi

  if ! assert_safe_path "$path"; then
    log_task refuse "$label" "unsafe path" "$path"
    history_append "$(date -Iseconds 2>/dev/null || date)" "$id" "$path" 0 0 0 "refused"
    return 0
  fi

  if [[ ! -e "$path" ]]; then
    log_task skip "$label" "missing" "$path"
    history_append "$(date -Iseconds 2>/dev/null || date)" "$id" "$path" 0 0 0 "missing"
    return 0
  fi

  before="$(du_kb "$path")"
  ts="$(date -Iseconds 2>/dev/null || date)"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    freed="$before"
    after=0
    status="dry-run"
    log_task dry "$label" "would free $(fmt_kb "$freed")" "$path"
    log_line "  path=$(abs_path "$path") before_kb=$before after_kb=$after freed_kb=$freed status=$status"
    history_append "$ts" "$id" "$path" "$before" "$after" "$freed" "$status"
    assess_append "$id" "$label" "$freed" "$status"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
    TOTAL_TASKS=$((TOTAL_TASKS + 1))
    return 0
  fi

  if [[ "$mode" == "contents" ]]; then
    clear_dir_contents "$path" || true
  else
    rm_path "$path" || true
  fi

  after="$(du_kb "$path")"
  freed=$(( before - after ))
  if [[ "$freed" -lt 0 ]]; then freed=0; fi
  status="ok"
  log_task ok "$label" "freed $(fmt_kb "$freed")" "$path"
  log_line "  path=$(abs_path "$path") before_kb=$before after_kb=$after freed_kb=$freed status=$status"
  history_append "$ts" "$id" "$path" "$before" "$after" "$freed" "$status"
  assess_append "$id" "$label" "$freed" "$status"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

# Run a command task while measuring one or more cache paths.
# Args: id label measure_path cmd...
# measure_path may be empty ("") if unknown
run_cmd_task() {
  local id="$1" label="$2" measure_path="$3"
  shift 3
  local before=0 after=0 freed=0 status ts

  if ! should_run "$id"; then
    log_skip "$id" "$label" "$(skip_reason_for "$id")" "${measure_path:--}"
    return 0
  fi

  if [[ -n "$measure_path" ]]; then
    if ! assert_safe_path "$measure_path"; then
      log_task refuse "$label" "unsafe measure path" "$measure_path"
      history_append "$(date -Iseconds 2>/dev/null || date)" "$id" "$measure_path" 0 0 0 "refused"
      return 0
    fi
    before="$(du_kb "$measure_path")"
  fi

  ts="$(date -Iseconds 2>/dev/null || date)"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    freed="$before"
    status="dry-run"
    if [[ -n "$measure_path" ]]; then
      log_task dry "$label" "would free ~$(fmt_kb "$freed")  ($*)" "$measure_path"
    else
      log_task dry "$label" "$*" "-"
    fi
    log_line "  path=${measure_path:--} before_kb=$before after_kb=0 freed_kb=$freed status=$status cmd=$*"
    history_append "$ts" "$id" "${measure_path:--}" "$before" 0 "$freed" "$status"
    assess_append "$id" "$label" "$freed" "$status"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
    TOTAL_TASKS=$((TOTAL_TASKS + 1))
    return 0
  fi

  if [[ "${VERBOSE:-0}" -eq 1 ]]; then
    "$@" || true
  else
    "$@" >/dev/null 2>&1 || true
  fi

  if [[ -n "$measure_path" ]]; then
    after="$(du_kb "$measure_path")"
    freed=$(( before - after ))
    if [[ "$freed" -lt 0 ]]; then freed=0; fi
  fi
  status="ok"
  if [[ -n "$measure_path" ]]; then
    log_task ok "$label" "freed $(fmt_kb "$freed")" "$measure_path"
  else
    log_task done "$label" "done" "-"
  fi
  log_line "  path=${measure_path:--} before_kb=$before after_kb=$after freed_kb=$freed status=$status cmd=$*"
  history_append "$ts" "$id" "${measure_path:--}" "$before" "$after" "$freed" "$status"
  assess_append "$id" "$label" "$freed" "$status"
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
  TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

log_skip() {
  local id="$1" label="$2" reason="$3" path="${4:--}"
  log_task skip "$label" "$reason" "$path"
  log_line "  path=$path status=skipped reason=$reason"
  history_append "$(date -Iseconds 2>/dev/null || date)" "$id" "$path" 0 0 0 "skipped:$reason"
}

# Sum freed_kb from last-assess.tsv (post-clean / post-assess)
assess_total_freed_kb() {
  local f="${1:-$JANITOR_ASSESS_TSV}"
  if [[ ! -f "$f" ]]; then
    echo 0
    return 0
  fi
  awk -F'\t' 'NR>1 && $1 != "id" && $3 ~ /^[0-9]+$/ { s += $3 } END { print s+0 }' "$f"
}

assess_task_count() {
  local f="${1:-$JANITOR_ASSESS_TSV}"
  if [[ ! -f "$f" ]]; then
    echo 0
    return 0
  fi
  awk -F'\t' 'NR>1 && $1 != "id" && $1 != "" { n++ } END { print n+0 }' "$f"
}

log_finish() {
  local df_before="${1:-0}" df_after
  df_after="$(free_kb)"
  local df_delta=$(( (df_after - df_before) ))
  if [[ "$df_delta" -lt 0 ]]; then df_delta=0; fi

  log_echo ""
  log_echo "${C_MAGENTA}${C_BOLD}── summary ──${C_RESET}"
  log_echo "${C_MAGENTA}${C_BOLD}${K_DONE}${C_RESET} ${C_GREEN}${C_BOLD}Disk freed (measured): $(fmt_kb "$TOTAL_FREED_KB")${C_RESET} across $TOTAL_TASKS tasks"
  log_echo "${C_DIM}df avail delta: $(fmt_kb "$df_delta") (informational — APFS is noisy)${C_RESET}"
  log_echo "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
}

latest_log_path() {
  if [[ -L "$JANITOR_LOG_DIR/latest.log" || -f "$JANITOR_LOG_DIR/latest.log" ]]; then
    echo "$JANITOR_LOG_DIR/latest.log"
  else
    echo ""
  fi
}

# RAM snapshot (learned from sanemaker.sh) — report only, never frees RAM by itself
ram_report() {
  local out=()
  local MEM_BYTES MEM_GB
  MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  MEM_GB="$(awk -v b="$MEM_BYTES" 'BEGIN { printf "%.0f", b/1024/1024/1024 }')"
  out+=("Physical RAM: ${MEM_GB} GB")

  local PAGESIZE
  PAGESIZE="$(vm_stat 2>/dev/null | head -n 1 | awk '{gsub("\\.","",$8); print $8}')"
  PAGESIZE="${PAGESIZE:-4096}"

  local FREE ACTIVE INACTIVE SPEC WIRED COMPRESSED
  FREE="$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub("\\.","",$3); print $3}')"
  INACTIVE="$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')"
  SPEC="$(vm_stat 2>/dev/null | awk '/Pages speculative/ {gsub("\\.","",$3); print $3}')"
  WIRED="$(vm_stat 2>/dev/null | awk '/Pages wired down/ {gsub("\\.","",$4); print $4}')"
  COMPRESSED="$(vm_stat 2>/dev/null | awk '/Pages occupied by compressor/ {gsub("\\.","",$5); print $5}')"
  FREE="${FREE:-0}"; INACTIVE="${INACTIVE:-0}"; SPEC="${SPEC:-0}"
  WIRED="${WIRED:-0}"; COMPRESSED="${COMPRESSED:-0}"

  local AVAIL_KB COMP_KB WIRED_KB
  AVAIL_KB="$(awk -v p="$PAGESIZE" -v f="$FREE" -v i="$INACTIVE" -v s="$SPEC" \
    'BEGIN { printf "%.0f", (f+i+s)*p/1024 }')"
  COMP_KB="$(awk -v p="$PAGESIZE" -v c="$COMPRESSED" 'BEGIN { printf "%.0f", c*p/1024 }')"
  WIRED_KB="$(awk -v p="$PAGESIZE" -v w="$WIRED" 'BEGIN { printf "%.0f", w*p/1024 }')"

  out+=("Available-ish: $(fmt_kb "$AVAIL_KB")")
  out+=("Compressed: $(fmt_kb "$COMP_KB")")
  out+=("Wired: $(fmt_kb "$WIRED_KB")")

  if command -v memory_pressure >/dev/null 2>&1; then
    local PRESS FREEPCT_NUM
    PRESS="$(memory_pressure -Q 2>/dev/null | awk -F: '/System-wide memory free percentage/ {gsub(/^[ \t]+/,"",$2); print $2}')"
    if [[ -n "${PRESS:-}" ]]; then
      out+=("Memory free %: ${PRESS}")
      FREEPCT_NUM="$(echo "$PRESS" | tr -dc '0-9' | head -c 3)"
      if [[ -n "${FREEPCT_NUM:-}" && "$FREEPCT_NUM" -lt 10 ]]; then
        out+=("Warning: memory pressure likely high (free% < 10)")
      fi
    fi
  fi

  local line
  echo "RAM:"
  for line in "${out[@]}"; do
    echo "  $line"
  done
  echo "  Top memory processes (RSS):"
  ps -axo pid,comm,rss 2>/dev/null | sort -nr -k3 | head -n 8 | awk '
    BEGIN { printf "    %-7s %-32s %s\n", "PID", "PROCESS", "RSS" }
    NR<=8 { printf "    %-7s %-32s %.0fM\n", $1, $2, $3/1024 }
  ' || true
}

# Prefer Data volume when present (sanemaker style), else home
df_data() {
  if [[ -d /System/Volumes/Data ]]; then
    df -h /System/Volumes/Data
  else
    df -h ~
  fi
}
