#!/bin/bash
# User config + hog catalog — portable PATH, no machine-specific hardcoding

# XDG-style config (portable across users)
JANITOR_CONFIG_DIR="${JANITOR_CONFIG_DIR:-$HOME/.config/janitor}"
JANITOR_DISABLED_FILE="$JANITOR_CONFIG_DIR/disabled"
JANITOR_HOGS_FILE="$JANITOR_CONFIG_DIR/hogs"
JANITOR_ASSESS_TSV="${JANITOR_LOG_DIR:-$HOME/Library/Logs/janitor}/last-assess.tsv"
JANITOR_CATALOG_FILE="${JANITOR_CATALOG_FILE:-$JANITOR_HOME/config/hogs.catalog}"

HOG_EMOJI="🐗"

# Runtime tables filled by catalog_load (parallel arrays)
JANITOR_TASK_IDS=()
JANITOR_TASK_LABELS=()
JANITOR_TASK_BLURBS=()
JANITOR_TASK_TRADEOFFS=()
JANITOR_TASK_EDUCATE=()
JANITOR_TASK_KINDS=()      # path | cmd
JANITOR_TASK_PATHS=()      # expanded path or cmd key
JANITOR_TASK_MODES=()      # remove | contents
JANITOR_TASK_DEFAULTS=()   # on | off | brave
JANITOR_TASK_EMOJIS=()
JANITOR_TASK_CUSTOM=()     # 0 | 1

# Expand ~ in a path string
hog_expand_path() {
  local path="$1"
  if [[ "$path" == "~"* ]]; then
    path="${path/#\~/$HOME}"
  fi
  echo "$path"
}

# Warn and skip bad catalog lines without aborting (set -e safe)
catalog_warn() {
  echo "janitor: catalog skip: $*" >&2
}

# Load repo catalog into runtime arrays. Safe if file missing/partial.
catalog_load() {
  JANITOR_TASK_IDS=()
  JANITOR_TASK_LABELS=()
  JANITOR_TASK_BLURBS=()
  JANITOR_TASK_TRADEOFFS=()
  JANITOR_TASK_EDUCATE=()
  JANITOR_TASK_KINDS=()
  JANITOR_TASK_PATHS=()
  JANITOR_TASK_MODES=()
  JANITOR_TASK_DEFAULTS=()
  JANITOR_TASK_EMOJIS=()
  JANITOR_TASK_CUSTOM=()

  local file="${JANITOR_CATALOG_FILE:-}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    catalog_warn "missing catalog at ${file:-unset}"
    return 0
  fi

  local line id kind path_or_cmd mode default emoji label blurb tradeoff educate
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r id kind path_or_cmd mode default emoji label blurb tradeoff educate <<<"$line" || true
    if [[ -z "${id:-}" || -z "${kind:-}" || -z "${label:-}" ]]; then
      catalog_warn "bad line: $line"
      continue
    fi
    case "$kind" in path|cmd) ;; *) catalog_warn "bad kind '$kind' for $id"; continue ;; esac
    case "${default:-on}" in on|off|brave) ;; *) default="on" ;; esac
    case "${mode:-remove}" in remove|contents) ;; *) mode="remove" ;; esac
    emoji="${emoji:-$HOG_EMOJI}"
    # ¶ → real newlines for educate paragraphs
    educate="${educate//¶/$'\n\n'}"

    JANITOR_TASK_IDS+=("$id")
    JANITOR_TASK_KINDS+=("$kind")
    if [[ "$kind" == "path" ]]; then
      JANITOR_TASK_PATHS+=("$(hog_expand_path "$path_or_cmd")")
    else
      JANITOR_TASK_PATHS+=("$path_or_cmd")
    fi
    JANITOR_TASK_MODES+=("$mode")
    JANITOR_TASK_DEFAULTS+=("$default")
    JANITOR_TASK_EMOJIS+=("$emoji")
    JANITOR_TASK_LABELS+=("$label")
    JANITOR_TASK_BLURBS+=("${blurb:-}")
    JANITOR_TASK_TRADEOFFS+=("${tradeoff:-}")
    JANITOR_TASK_EDUCATE+=("${educate:-}")
    JANITOR_TASK_CUSTOM+=("0")
  done <"$file"
}

# Merge user ~/.config/janitor/hogs (adopted ids + custom path lines)
user_hogs_load() {
  local file="$JANITOR_HOGS_FILE"
  [[ -f "$file" ]] || return 0

  local line id path mode label rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ "$line" == custom:* ]]; then
      rest="${line#custom:}"
      IFS='|' read -r id path mode label <<<"$rest" || true
      if [[ -z "${id:-}" || -z "${path:-}" ]]; then
        catalog_warn "bad custom hog: $line"
        continue
      fi
      mode="${mode:-contents}"
      label="${label:-$id}"
      path="$(hog_expand_path "$path")"
      # Skip duplicate ids
      if task_index "$id" >/dev/null 2>&1; then
        catalog_warn "custom id already in catalog: $id"
        continue
      fi
      JANITOR_TASK_IDS+=("$id")
      JANITOR_TASK_KINDS+=("path")
      JANITOR_TASK_PATHS+=("$path")
      JANITOR_TASK_MODES+=("$mode")
      JANITOR_TASK_DEFAULTS+=("on")
      JANITOR_TASK_EMOJIS+=("$HOG_EMOJI")
      JANITOR_TASK_LABELS+=("$label")
      JANITOR_TASK_BLURBS+=("you added this allowlisted cache path yourself")
      JANITOR_TASK_TRADEOFFS+=("depends on the path — regenerable cache data only if you chose well")
      JANITOR_TASK_EDUCATE+=("This is a custom hog you registered with janitor hog add.

Janitor only allows paths under known cache roots, and never Documents or Downloads.

If the tradeoff surprises you, disable or remove the line from ~/.config/janitor/hogs.")
      JANITOR_TASK_CUSTOM+=("1")
      continue
    fi

    # Adopted catalog id — mark default on by flipping DEFAULTS for that id
    id="$line"
    local idx
    idx="$(task_index "$id" 2>/dev/null || true)"
    if [[ -n "$idx" ]]; then
      JANITOR_TASK_DEFAULTS[$idx]="on"
    else
      catalog_warn "adopt unknown id (not in catalog): $id"
    fi
  done <"$file"
}

# Print index of task id, or return 1
task_index() {
  local want="$1" i
  for i in "${!JANITOR_TASK_IDS[@]}"; do
    if [[ "${JANITOR_TASK_IDS[$i]}" == "$want" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

task_blurb() {
  local want="$1" i
  i="$(task_index "$want" 2>/dev/null || true)"
  if [[ -n "$i" ]]; then
    echo "${JANITOR_TASK_BLURBS[$i]}"
    return 0
  fi
  echo ""
}

task_tradeoff() {
  local want="$1" i
  i="$(task_index "$want" 2>/dev/null || true)"
  if [[ -n "$i" ]]; then
    echo "${JANITOR_TASK_TRADEOFFS[$i]}"
    return 0
  fi
  echo ""
}

task_educate() {
  local want="$1" i
  i="$(task_index "$want" 2>/dev/null || true)"
  if [[ -n "$i" ]]; then
    echo "${JANITOR_TASK_EDUCATE[$i]}"
    return 0
  fi
  echo ""
}

# Educational one-liner for UI / done screen
task_hogging_because() {
  local id="$1" blurb
  blurb="$(task_blurb "$id")"
  [[ -n "$blurb" ]] || return 0
  if [[ "$blurb" == [Hh]ogging\ because:* ]]; then
    echo "$blurb"
  else
    echo "Hogging because: $blurb"
  fi
}

# Consequence of cleaning this hog
task_if_you_swipe() {
  local id="$1" t
  t="$(task_tradeoff "$id")"
  [[ -n "$t" ]] || return 0
  if [[ "$t" == [Ii]f\ you\ swipe:* ]]; then
    echo "$t"
  else
    echo "If you swipe: $t"
  fi
}

task_label() {
  local want="$1" i
  i="$(task_index "$want" 2>/dev/null || true)"
  if [[ -n "$i" ]]; then
    echo "${JANITOR_TASK_LABELS[$i]}"
    return 0
  fi
  echo "$want"
}

# 0 if this hog is in the enabled set (default on or adopted/custom), ignoring disable/only
hog_is_in_enabled_set() {
  local id="$1" i
  i="$(task_index "$id" 2>/dev/null || true)"
  [[ -n "$i" ]] || return 1
  [[ "${JANITOR_TASK_DEFAULTS[$i]}" == "on" ]] || return 1
  return 0
}

# Measure path for a catalog/cmd hog (best-effort for status rows)
hog_measure_path() {
  local id="$1" i kind path
  i="$(task_index "$id" 2>/dev/null || true)"
  [[ -n "$i" ]] || { echo ""; return 1; }
  kind="${JANITOR_TASK_KINDS[$i]}"
  path="${JANITOR_TASK_PATHS[$i]}"
  if [[ "$kind" == "path" ]]; then
    echo "$path"
    return 0
  fi
  case "$id" in
    homebrew) brew --cache 2>/dev/null || echo "" ;;
    npm) echo "$HOME/.npm" ;;
    pip|pip3) echo "$HOME/Library/Caches/pip" ;;
    pub_cache) echo "$HOME/.pub-cache" ;;
    simctl) echo "$HOME/Library/Developer/CoreSimulator" ;;
    old_logs) echo "$HOME/Library/Logs" ;;
    *) echo "" ;;
  esac
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

# True if id is listed in user hogs file (adopt or custom)
user_hog_listed() {
  local id="$1"
  [[ -f "$JANITOR_HOGS_FILE" ]] || return 1
  grep -E "^[[:space:]]*${id}[[:space:]]*$" "$JANITOR_HOGS_FILE" >/dev/null 2>&1 \
    || grep -E "^[[:space:]]*custom:${id}\\|" "$JANITOR_HOGS_FILE" >/dev/null 2>&1
}

# True if --deep unlocks this default=off catalog hog for this run
hog_unlocked_by_deep() {
  local id="$1" i
  [[ "${DEEP:-0}" -eq 1 ]] || return 1
  i="$(task_index "$id" 2>/dev/null || true)"
  [[ -n "$i" ]] || return 1
  [[ "${JANITOR_TASK_CUSTOM[$i]}" == "0" ]] || return 1
  [[ "${JANITOR_TASK_DEFAULTS[$i]}" == "off" ]] || return 1
  return 0
}

# True if --brave/--stupid unlocks this default=brave catalog hog
hog_unlocked_by_brave() {
  local id="$1" i
  [[ "${BRAVE:-0}" -eq 1 ]] || return 1
  i="$(task_index "$id" 2>/dev/null || true)"
  [[ -n "$i" ]] || return 1
  [[ "${JANITOR_TASK_CUSTOM[$i]}" == "0" ]] || return 1
  [[ "${JANITOR_TASK_DEFAULTS[$i]}" == "brave" ]] || return 1
  return 0
}

# should_run id — enabled set (or deep/brave-unlocked) + not disabled + JANITOR_ONLY
should_run() {
  local id="$1"
  if ! hog_is_in_enabled_set "$id" \
    && ! hog_unlocked_by_deep "$id" \
    && ! hog_unlocked_by_brave "$id"; then
    return 1
  fi
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
  if ! hog_is_in_enabled_set "$id" \
    && ! hog_unlocked_by_deep "$id" \
    && ! hog_unlocked_by_brave "$id"; then
    local i
    i="$(task_index "$id" 2>/dev/null || true)"
    if [[ -n "$i" && "${JANITOR_TASK_DEFAULTS[$i]}" == "brave" ]]; then
      echo "brave mode only (or adopt)"
      return
    fi
    echo "not adopted (default off)"
    return
  fi
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

# One-row hog line for CLI amble
# Args: id size_str label [state]
hog_row() {
  local id="$1" size="$2" label="$3" state="${4:-}"
  local emoji="$HOG_EMOJI" i
  i="$(task_index "$id" 2>/dev/null || true)"
  if [[ -n "$i" ]]; then
    emoji="${JANITOR_TASK_EMOJIS[$i]:-$HOG_EMOJI}"
  fi
  if [[ -n "$state" ]]; then
    printf '%s  %-18s %8s  %s  [%s]\n' "$emoji" "$id" "$size" "$label" "$state"
  else
    printf '%s  %-18s %8s  %s\n' "$emoji" "$id" "$size" "$label"
  fi
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
    elif hog_is_in_enabled_set "$id"; then
      state="enabled"
    elif [[ "${JANITOR_TASK_DEFAULTS[$i]}" == "brave" ]]; then
      state="brave"
    else
      state="off"
    fi
    printf '%-18s %-10s %s\n' "$id" "$state" "$label"
  done
  echo
  echo "Config: $JANITOR_DISABLED_FILE"
  echo "Hogs:   $JANITOR_HOGS_FILE"
  echo "Disable: janitor disable <id>"
  echo "Enable:  janitor enable <id>"
  echo "Adopt:   janitor adopt <id>"
}

# Ensure user hogs file exists (commented template) when writing
hogs_file_ensure() {
  config_ensure
  if [[ ! -f "$JANITOR_HOGS_FILE" ]]; then
    cat >"$JANITOR_HOGS_FILE" <<'EOF'
# Janitor — adopted / custom hogs (one per line)
# Catalog: shipit
# Custom:  custom:<id>|<path>|<mode>|<label>
EOF
  fi
}

cmd_adopt() {
  local id="$1"
  [[ -n "$id" ]] || { echo "usage: janitor adopt <id>" >&2; return 1; }
  local idx
  idx="$(task_index "$id" 2>/dev/null || true)"
  [[ -n "$idx" ]] || { echo "janitor: unknown catalog id: $id (try: janitor discover)" >&2; return 1; }
  if [[ "${JANITOR_TASK_CUSTOM[$idx]}" == "1" ]]; then
    echo "already a custom hog: $id"
    return 0
  fi
  hogs_file_ensure
  if user_hog_listed "$id"; then
    echo "already adopted: $id"
    return 0
  fi
  # If already default on, still record adopt for clarity
  echo "$id" >>"$JANITOR_HOGS_FILE"
  JANITOR_TASK_DEFAULTS[$idx]="on"
  echo "adopted: $id  ($JANITOR_HOGS_FILE)"
}

cmd_hog_add() {
  local raw_path="$1"
  local mode="${2:-contents}"
  local id label path
  [[ -n "$raw_path" ]] || { echo "usage: janitor hog add <path> [remove|contents]" >&2; return 1; }
  path="$(hog_expand_path "$raw_path")"
  path="$(abs_path "$path")"

  if ! path_is_allowlisted "$path"; then
    echo "janitor: REFUSED — path not under an allowlisted cache root: $path" >&2
    echo "janitor: (Documents and Downloads are never cleaned)" >&2
    return 1
  fi
  case "$mode" in remove|contents) ;; *)
    echo "janitor: mode must be remove or contents" >&2
    return 1
  ;; esac

  id="custom_$(basename "$path" | tr -c 'A-Za-z0-9_-' '_' | tr '[:upper:]' '[:lower:]')"
  id="${id%_}"
  # Uniquify if needed
  local n=1 base="$id"
  while task_index "$id" >/dev/null 2>&1; do
    id="${base}_$n"
    n=$((n + 1))
  done
  label="$(basename "$path") cache"

  hogs_file_ensure
  printf 'custom:%s|%s|%s|%s\n' "$id" "$path" "$mode" "$label" >>"$JANITOR_HOGS_FILE"

  JANITOR_TASK_IDS+=("$id")
  JANITOR_TASK_KINDS+=("path")
  JANITOR_TASK_PATHS+=("$path")
  JANITOR_TASK_MODES+=("$mode")
  JANITOR_TASK_DEFAULTS+=("on")
  JANITOR_TASK_EMOJIS+=("$HOG_EMOJI")
  JANITOR_TASK_LABELS+=("$label")
  JANITOR_TASK_BLURBS+=("you added this allowlisted cache path yourself")
  JANITOR_TASK_TRADEOFFS+=("depends on the path — regenerable cache data only if you chose well")
  JANITOR_TASK_EDUCATE+=("This is a custom hog you registered with janitor hog add.

Janitor only allows paths under known cache roots, and never Documents or Downloads.

If the tradeoff surprises you, disable or remove the line from ~/.config/janitor/hogs.")
  JANITOR_TASK_CUSTOM+=("1")

  echo "added hog: $id → $path"
  hog_row "$id" "$(path_size "$path")" "$label" "custom"
}

# List all hogs as one-row amble
cmd_hogs() {
  local i id label size state path
  section "Hogs"
  if [[ ${#JANITOR_TASK_IDS[@]} -eq 0 ]]; then
    echo "  (no hogs in catalog)"
    return 0
  fi
  for i in "${!JANITOR_TASK_IDS[@]}"; do
    id="${JANITOR_TASK_IDS[$i]}"
    label="${JANITOR_TASK_LABELS[$i]}"
    path="$(hog_measure_path "$id" 2>/dev/null || true)"
    if [[ -n "$path" && -e "$path" ]]; then
      size="$(fmt_kb "$(du_kb "$path")")"
    else
      size="—"
    fi
    if task_is_disabled "$id"; then
      state="disabled"
    elif hog_is_in_enabled_set "$id"; then
      if [[ "${JANITOR_TASK_CUSTOM[$i]}" == "1" ]]; then
        state="custom"
      else
        state="enabled"
      fi
    elif [[ "${JANITOR_TASK_DEFAULTS[$i]}" == "brave" ]]; then
      state="brave"
    else
      state="off"
    fi
    hog_row "$id" "$size" "$label" "$state"
  done
  echo
  echo "${C_DIM}Policy: never Documents or Downloads. Brave tier = browsers/media caches.${C_RESET}"
  echo "${C_DIM}Educate: janitor educate <id>   Adopt: janitor adopt <id>${C_RESET}"
}

# Discover: default-off / brave / disabled hogs that exist on disk
cmd_discover() {
  local i id label size path because swipe found=0
  section "Discover hogs"
  for i in "${!JANITOR_TASK_IDS[@]}"; do
    id="${JANITOR_TASK_IDS[$i]}"
    if hog_is_in_enabled_set "$id" && ! task_is_disabled "$id"; then
      continue
    fi
    path="$(hog_measure_path "$id" 2>/dev/null || true)"
    [[ -n "$path" && -e "$path" ]] || continue
    local kb
    kb="$(du_kb "$path")"
    [[ "$kb" -gt 0 ]] || continue
    size="$(fmt_kb "$kb")"
    label="${JANITOR_TASK_LABELS[$i]}"
    if [[ "${JANITOR_TASK_DEFAULTS[$i]}" == "brave" ]]; then
      hog_row "$id" "$size" "$label" "brave?"
    else
      hog_row "$id" "$size" "$label" "suggest"
    fi
    because="$(task_hogging_because "$id")"
    swipe="$(task_if_you_swipe "$id")"
    [[ -n "$because" ]] && echo "    ${C_DIM}${because}${C_RESET}"
    [[ -n "$swipe" ]] && echo "    ${C_DIM}${swipe}${C_RESET}"
    echo "    ${C_DIM}📖 janitor educate ${id}${C_RESET}"
    found=1
  done
  if [[ "$found" -eq 0 ]]; then
    echo "  (no new hogs found — your enabled set covers what's on disk)"
  else
    echo
    echo "${C_DIM}Adopt: janitor adopt <id>   ·   Wider sweep: janitor clean --brave${C_RESET}"
  fi
}

cmd_educate() {
  local id="$1"
  [[ -n "$id" ]] || { echo "usage: janitor educate <id|ram|disk>" >&2; return 1; }
  case "$id" in
    ram|memory|disk|hogs|ram-vs-disk|disk-vs-ram)
      banner "Educate me — disk hogs vs RAM hogs" "📖"
      echo
      explain_ram_vs_disk full
      echo
      return 0
      ;;
  esac
  local idx label because swipe edu
  idx="$(task_index "$id" 2>/dev/null || true)"
  [[ -n "$idx" ]] || { echo "janitor: unknown hog id: $id (or try: janitor educate ram)" >&2; return 1; }
  label="$(task_label "$id")"
  because="$(task_hogging_because "$id")"
  swipe="$(task_if_you_swipe "$id")"
  edu="$(task_educate "$id")"
  banner "Educate me — ${label}" "📖"
  echo
  [[ -n "$because" ]] && echo "$because"
  [[ -n "$swipe" ]] && echo "$swipe"
  echo
  if [[ -n "$edu" ]]; then
    printf '%s\n' "$edu"
  else
    echo "(no longer explanation for this hog yet)"
  fi
  echo
  explain_ram_vs_disk short
  echo
}

# Load catalog + user hogs (call after JANITOR_HOME is set)
janitor_hogs_init() {
  catalog_load
  user_hogs_load
}
