#!/bin/bash
# Cowork sessions sweeper : Claude desktop's local-agent-mode sessions + VM disk.
#
# This is session STATE, not cache, so it does not ride on the cache allowlist.
# Deletable paths are fixed in common.sh (is_cowork_sweepable_path); this file
# adds the gates: Claude must be quit, layout must look as expected, sandboxes
# must be stale, the newest sandbox per conversation is always kept, and the
# first sweep on a Mac is a dry run.
#
# Bash 3.2 safe (macOS /bin/bash): no assoc arrays, no mapfile.

SESSIONS_CONF="$JANITOR_CONFIG_DIR/sessions.conf"
SESSIONS_STATE="$JANITOR_CONFIG_DIR/sessions.state"
SESSIONS_OK_MARKER="$JANITOR_CONFIG_DIR/sessions.ok"

# Defaults (override in ~/.config/janitor/sessions.conf)
S_MAX_AGE_DAYS=14
S_VM_WARN_PCT=80
S_VM_CRIT_PCT=92
S_ROOTFS_WARN_GB=12
S_ROOTFS_CRIT_GB=18
S_HOST_FREE_WARN_GB=20
S_HOST_FREE_CRIT_GB=8
S_PROBE_FILE="$HOME/Claude/janitor/vm-df.jsonl"
S_PROBE_MAX_AGE_H=36
S_CLAUDE_PROC="Claude"

# Filled by the sweep / VM report
SESSIONS_SKIPPED_RUNNING=0
SESSIONS_FORCED_DRY=0
SESSIONS_STALE_COUNT=0
SESSIONS_STALE_KB=0
VM_LEVEL=0
VM_SUMMARY=""

# Parse KEY=value lines; known keys only, never sourced.
sessions_conf_load() {
 [[ -f "$SESSIONS_CONF" ]] || return 0
 local line key val
 while IFS= read -r line || [[ -n "$line" ]]; do
 [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
 key="${line%%=*}"
 val="${line#*=}"
 key="${key//[[:space:]]/}"
 val="${val#"${val%%[![:space:]]*}"}"
 val="${val%"${val##*[![:space:]]}"}"
 val="${val#\"}"; val="${val%\"}"
 case "$key" in
 SANDBOX_MAX_AGE_DAYS|VM_WARN_PCT|VM_CRIT_PCT|ROOTFS_WARN_GB|ROOTFS_CRIT_GB|HOST_FREE_WARN_GB|HOST_FREE_CRIT_GB|PROBE_MAX_AGE_H)
 if [[ ! "$val" =~ ^[0-9]+$ ]]; then
 echo "janitor: sessions.conf: $key must be a whole number (got '$val'), keeping default" >&2
 continue
 fi
 case "$key" in
 SANDBOX_MAX_AGE_DAYS) S_MAX_AGE_DAYS="$val" ;;
 VM_WARN_PCT) S_VM_WARN_PCT="$val" ;;
 VM_CRIT_PCT) S_VM_CRIT_PCT="$val" ;;
 ROOTFS_WARN_GB) S_ROOTFS_WARN_GB="$val" ;;
 ROOTFS_CRIT_GB) S_ROOTFS_CRIT_GB="$val" ;;
 HOST_FREE_WARN_GB) S_HOST_FREE_WARN_GB="$val" ;;
 HOST_FREE_CRIT_GB) S_HOST_FREE_CRIT_GB="$val" ;;
 PROBE_MAX_AGE_H) S_PROBE_MAX_AGE_H="$val" ;;
 esac
 ;;
 PROBE_FILE) S_PROBE_FILE="$(hog_expand_path "$val")" ;;
 CLAUDE_PROC) S_CLAUDE_PROC="$val" ;;
 CLAUDE_SUPPORT) JANITOR_CLAUDE_SUPPORT="$(hog_expand_path "$val")" ;;
 "") ;;
 *) echo "janitor: sessions.conf: unknown key '$key' (ignored)" >&2 ;;
 esac
 done <"$SESSIONS_CONF"
 # Never 0 days: that would make every sandbox "stale"
 [[ "$S_MAX_AGE_DAYS" -ge 1 ]] || S_MAX_AGE_DAYS=1
}

cowork_sessions_root() { echo "$JANITOR_CLAUDE_SUPPORT/local-agent-mode-sessions"; }
cowork_bundle() { echo "$JANITOR_CLAUDE_SUPPORT/vm_bundles/claudevm.bundle"; }

# 0 if Claude desktop (or anything holding the VM disks) is running
claude_running() {
 if pgrep -x "$S_CLAUDE_PROC" >/dev/null 2>&1; then
 return 0
 fi
 if command -v lsof >/dev/null 2>&1; then
 local img
 for img in sessiondata.img rootfs.img; do
 if [[ -f "$(cowork_bundle)/$img" ]] && lsof -t "$(cowork_bundle)/$img" >/dev/null 2>&1; then
 return 0
 fi
 done
 fi
 return 1
}

# Apparent size in bytes (sparse files report full capacity here)
file_apparent_bytes() {
 # BSD stat on macOS; GNU stat elsewhere (GNU "-f" means filesystem, so pick by OS)
 if [[ "$(uname -s)" == "Darwin" ]]; then
 stat -f %z "$1" 2>/dev/null || echo 0
 else
 stat -c %s "$1" 2>/dev/null || echo 0
 fi
}

# Allocated KB (what the sparse file really occupies on disk)
file_alloc_kb() {
 local kb
 kb="$(du -k "$1" 2>/dev/null | awk '{print $1}')" || true
 echo "${kb:-0}"
}

# Layout check. Prints ok | absent | unknown and returns 0 only for ok.
# Expected: <root>/<session>/<conversation>/local_<uuid>, nothing else named local_*.
cowork_layout_check() {
 local root d rel depth n3=0 nother=0
 root="$(cowork_sessions_root)"
 if [[ ! -d "$root" ]]; then
 echo "absent"
 return 1
 fi
 while IFS= read -r d; do
 [[ -z "$d" ]] && continue
 rel="${d#"$root"/}"
 depth="$(printf '%s' "$rel" | awk -F/ '{print NF}')"
 if [[ "$depth" -eq 3 ]] && is_cowork_sandbox_name "$(basename "$d")"; then
 n3=$((n3 + 1))
 else
 nother=$((nother + 1))
 fi
 done < <(find "$root" -mindepth 1 -maxdepth 5 -type d -name 'local_*' -print -prune 2>/dev/null || true)
 if [[ "$nother" -gt 0 ]]; then
 echo "unknown"
 return 1
 fi
 echo "ok"
 return 0
}

# Conversation dirs that hold at least one sandbox
cowork_conversation_dirs() {
 local root
 root="$(cowork_sessions_root)"
 [[ -d "$root" ]] || return 0
 find "$root" -mindepth 3 -maxdepth 3 -type d -name 'local_*' 2>/dev/null \
 | sed 's|/[^/]*$||' | sort -u || true
}

# Valid sandboxes in one conversation dir, newest (by dir mtime) first
cowork_sandboxes_in() {
 local conv="$1" d
 # ls -t: portable newest-first. The parent path has spaces
 # ("Application Support"), so read lines, never word-split.
 while IFS= read -r d; do
 [[ -n "$d" && -d "$d" ]] || continue
 is_cowork_sandbox_name "$(basename "$d")" || continue
 printf '%s\n' "$d"
 done < <(ls -td "$conv"/local_* 2>/dev/null || true)
}

# 0 if anything inside $1 changed within S_MAX_AGE_DAYS
sandbox_recently_touched() {
 local hit
 hit="$(find "$1" -mtime -"$S_MAX_AGE_DAYS" -print 2>/dev/null | head -n 1 || true)"
 [[ -n "$hit" ]]
}

# Stale sandboxes: untouched for S_MAX_AGE_DAYS, never the newest per conversation
list_stale_sandboxes() {
 local conv d first
 while IFS= read -r conv; do
 [[ -z "$conv" ]] && continue
 first=1
 while IFS= read -r d; do
 [[ -z "$d" ]] && continue
 if [[ "$first" -eq 1 ]]; then
 first=0
 continue
 fi
 sandbox_recently_touched "$d" && continue
 printf '%s\n' "$d"
 done < <(cowork_sandboxes_in "$conv")
 done < <(cowork_conversation_dirs)
}

# Catalog cmd hog: cowork_sandboxes
clean_cowork_sandboxes() {
 local id="cowork_sandboxes" label="Cowork task sandboxes"
 local measure
 measure="$(cowork_sessions_root)"

 if ! should_run "$id"; then
 log_skip "$id" "$label" "$(skip_reason_for "$id")" "$measure"
 return 0
 fi
 if [[ ! -d "$measure" ]]; then
 log_skip "$id" "$label" "no Cowork sessions folder on this Mac" "$measure"
 return 0
 fi
 local layout
 layout="$(cowork_layout_check || true)"
 if [[ "$layout" != "ok" ]]; then
 log_task refuse "$label" "unexpected folder layout ($layout); refusing to delete anything. Run: janitor sessions inspect" "$measure"
 history_append "$(date -Iseconds 2>/dev/null || date)" "$id" "$measure" 0 0 0 "refused"
 return 0
 fi
 if claude_running; then
 SESSIONS_SKIPPED_RUNNING=1
 log_skip "$id" "$label" "Claude is running; quit it first (sandboxes may be in use)" "$measure"
 return 0
 fi

 local dirs=() d
 while IFS= read -r d; do
 [[ -z "$d" ]] && continue
 assert_safe_path "$d" 2>/dev/null || continue
 dirs+=("$d")
 done < <(list_stale_sandboxes)

 if [[ ${#dirs[@]} -eq 0 ]]; then
 log_skip "$id" "$label" "no stale sandboxes (>${S_MAX_AGE_DAYS}d, newest per conversation kept)" "$measure"
 return 0
 fi

 local estimate before after freed status ts dry="${DRY_RUN:-0}"
 estimate="$(sum_dirs_kb "${dirs[@]}")"
 before="$estimate"
 ts="$(date -Iseconds 2>/dev/null || date)"
 SESSIONS_STALE_COUNT=${#dirs[@]}
 SESSIONS_STALE_KB=$estimate

 # First sweep on this Mac: look, don't touch
 if [[ "$dry" -ne 1 && ! -f "$SESSIONS_OK_MARKER" ]]; then
 dry=1
 SESSIONS_FORCED_DRY=1
 log_echo "${C_YELLOW}First Cowork sweep on this Mac: dry run only. The next run deletes.${C_RESET}"
 fi

 if [[ "$dry" -eq 1 ]]; then
 log_task dry "$label" "would free ~$(fmt_kb "$estimate") (${#dirs[@]} stale sandboxes)" "$measure"
 for d in "${dirs[@]}"; do log_line " would remove: $d"; done
 history_append "$ts" "$id" "$measure" "$before" 0 "$estimate" "dry run"
 assess_append "$id" "$label" "$estimate" "dry run"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + estimate))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
 if [[ "$SESSIONS_FORCED_DRY" -eq 1 ]]; then
 config_ensure
 date -Iseconds >"$SESSIONS_OK_MARKER" 2>/dev/null || date >"$SESSIONS_OK_MARKER"
 fi
 return 0
 fi

 local removed=0
 for d in "${dirs[@]}"; do
 # Re-check right before each delete: Claude may have started mid-sweep
 if claude_running; then
 SESSIONS_SKIPPED_RUNNING=1
 log_echo "${C_YELLOW}Claude started mid-sweep; stopping.${C_RESET}"
 break
 fi
 rm_path "$d" || continue
 log_line " removed: $d"
 removed=$((removed + 1))
 done

 after="$(sum_dirs_kb "${dirs[@]}")"
 freed=$(( before - after ))
 [[ "$freed" -ge 0 ]] || freed=0
 status="ok"
 log_task ok "$label" "freed $(fmt_kb "$freed") ($removed of ${#dirs[@]} stale sandboxes)" "$measure"
 history_append "$ts" "$id" "$measure" "$before" "$after" "$freed" "$status"
 assess_append "$id" "$label" "$freed" "$status"
 TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
 TOTAL_TASKS=$((TOTAL_TASKS + 1))
}

# --- VM health -------------------------------------------------------------

# Field from a flat JSON line: json_num '{"a":1}' a → 1
json_num() {
 printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"
}

level_name() {
 case "$1" in 0) echo "ok" ;; 1) echo "WARN" ;; *) echo "CRITICAL" ;; esac
}

join_notes() {
 local out="" n
 for n in "$@"; do
 [[ -z "$n" ]] && continue
 out="${out:+$out; }$n"
 done
 printf '%s' "$out"
}

# Bump VM_LEVEL to at least $1
vm_raise() { [[ "$1" -gt "$VM_LEVEL" ]] && VM_LEVEL="$1"; return 0; }

# Print VM/host space report; sets VM_LEVEL (0 ok, 1 warn, 2 critical) + VM_SUMMARY
sessions_vm_report() {
 VM_LEVEL=0
 VM_SUMMARY=""
 local bundle img cap alloc_kb pct="" pct_src="" rootfs_kb rootfs_gb free_gb
 local probe_line probe_ts probe_pct probe_root probe_count now age_h
 local notes=()
 bundle="$(cowork_bundle)"

 free_gb=$(( $(free_kb) / 1048576 ))
 if [[ "$free_gb" -lt "$S_HOST_FREE_CRIT_GB" ]]; then
 vm_raise 2; notes+=("Mac disk: ${free_gb} GB free")
 elif [[ "$free_gb" -lt "$S_HOST_FREE_WARN_GB" ]]; then
 vm_raise 1; notes+=("Mac disk: ${free_gb} GB free")
 fi
 printf ' %-26s %s GB free\n' "Mac disk" "$free_gb"

 if [[ ! -d "$bundle" ]]; then
 printf ' %-26s %s\n' "Cowork VM" "none on this Mac"
 VM_SUMMARY="$(join_notes "${notes[@]:-}")"
 return 0
 fi

 # /sessions: exact from a fresh probe, else upper bound from the sparse image
 if [[ -f "$S_PROBE_FILE" ]]; then
 probe_line="$(grep -v '^[[:space:]]*$' "$S_PROBE_FILE" 2>/dev/null | tail -n 1 || true)"
 probe_ts="$(json_num "$probe_line" ts)"
 probe_pct="$(json_num "$probe_line" sessions_pct)"
 probe_root="$(json_num "$probe_line" root_pct)"
 probe_count="$(json_num "$probe_line" sessions_count)"
 now="$(date +%s)"
 if [[ -n "$probe_ts" && -n "$probe_pct" ]]; then
 age_h=$(( (now - probe_ts) / 3600 ))
 if [[ "$age_h" -le "$S_PROBE_MAX_AGE_H" ]]; then
 pct="$probe_pct"
 pct_src="exact, probe ${age_h}h ago${probe_count:+, $probe_count sessions}"
 fi
 fi
 fi

 img="$bundle/sessiondata.img"
 if [[ -f "$img" ]]; then
 cap="$(file_apparent_bytes "$img")"
 alloc_kb="$(file_alloc_kb "$img")"
 if [[ -z "$pct" && "${cap:-0}" -gt 0 ]]; then
 pct=$(( alloc_kb * 1024 * 100 / cap ))
 [[ "$pct" -le 100 ]] || pct=100
 pct_src="upper bound from image; run the probe for exact"
 fi
 printf ' %-26s %s of %s on disk\n' "sessiondata.img" "$(fmt_kb "$alloc_kb")" "$(fmt_kb $(( cap / 1024 )))"
 fi
 if [[ -n "$pct" ]]; then
 printf ' %-26s %s%% full (%s)\n' "/sessions (in VM)" "$pct" "$pct_src"
 if [[ "$pct" -ge "$S_VM_CRIT_PCT" ]]; then
 vm_raise 2; notes+=("/sessions ${pct}% full")
 elif [[ "$pct" -ge "$S_VM_WARN_PCT" ]]; then
 vm_raise 1; notes+=("/sessions ${pct}% full")
 fi
 fi
 if [[ -n "${probe_root:-}" && -n "$pct_src" && "$pct_src" == exact* ]]; then
 printf ' %-26s %s%% full\n' "/ (in VM)" "$probe_root"
 fi

 if [[ -f "$bundle/rootfs.img" ]]; then
 rootfs_kb="$(file_alloc_kb "$bundle/rootfs.img")"
 rootfs_gb=$(( rootfs_kb / 1048576 ))
 printf ' %-26s %s on disk\n' "rootfs.img" "$(fmt_kb "$rootfs_kb")"
 if [[ "$rootfs_gb" -ge "$S_ROOTFS_CRIT_GB" ]]; then
 vm_raise 2; notes+=("VM root image ${rootfs_gb} GB")
 elif [[ "$rootfs_gb" -ge "$S_ROOTFS_WARN_GB" ]]; then
 vm_raise 1; notes+=("VM root image ${rootfs_gb} GB")
 fi
 fi
 printf ' %-26s %s\n' "Cowork VM bundle total" "$(path_size "$JANITOR_CLAUDE_SUPPORT/vm_bundles")"
 printf ' %-26s %s\n' "Level" "$(level_name "$VM_LEVEL")"

 if [[ "$VM_LEVEL" -ge 1 ]]; then
 echo
 echo " Fix, least destructive first:"
 echo "  1. janitor sessions sweep            (stale task sandboxes, Claude quit)"
 echo "  2. Claude: Help > Troubleshooting > Free Up Cowork Disk Space"
 echo "  3. Delete old sessions in the Cowork sidebar"
 echo "  4. janitor sessions vm-reset         (last resort; loses files kept only inside the VM)"
 fi
 VM_SUMMARY="$(join_notes "${notes[@]:-}")"
 return 0
}

# --- Notifications / state ---------------------------------------------------

sessions_notify() {
 local msg="$1"
 msg="${msg//\\/}"
 msg="${msg//\"/\'}"
 if command -v osascript >/dev/null 2>&1; then
 osascript -e "display notification \"$msg\" with title \"Janitor\" subtitle \"Cowork sessions\"" >/dev/null 2>&1 || true
 fi
 log_line "notify: $msg"
}

sessions_state_get() {
 local key="$1"
 [[ -f "$SESSIONS_STATE" ]] || { echo 0; return 0; }
 local v
 v="$(sed -n "s/^${key}=//p" "$SESSIONS_STATE" | tail -n 1)"
 echo "${v:-0}"
}

sessions_state_set() {
 local key="$1" val="$2" tmp
 config_ensure
 tmp="$(mktemp)"
 if [[ -f "$SESSIONS_STATE" ]]; then
 grep -v "^${key}=" "$SESSIONS_STATE" >"$tmp" 2>/dev/null || true
 fi
 echo "${key}=${val}" >>"$tmp"
 mv "$tmp" "$SESSIONS_STATE"
}

# --- Subcommands --------------------------------------------------------------

sessions_usage() {
 cat <<'EOF'
janitor sessions : Claude desktop Cowork sessions + VM disk

Usage:
 janitor sessions [inspect]       Read-only: layout, sizes, stale sandboxes, VM fill
 janitor sessions sweep [--dry-run] [--max-age DAYS] [-v]
                                  Delete stale local_<id> task sandboxes (Claude must be quit)
 janitor sessions vm              VM space check (exit 0 ok, 1 warn, 2 critical)
 janitor sessions vm-reset [--full]
                                  Interactive last resort: delete sessiondata.img
                                  (--full: whole vm_bundles; app rebuilds it)

Scheduled (LaunchAgent, ./install.sh --schedule-sessions):
 janitor sessions sweep --scheduled
   sweeps only if adopted (janitor adopt cowork_sandboxes), then checks the VM
   and sends a macOS notification on warn/critical.

Rules: never while Claude runs, never session/conversation folders, always keeps
the newest sandbox per conversation, first sweep on a Mac is a dry run.
Config: ~/.config/janitor/sessions.conf
EOF
}

sessions_inspect() {
 local root layout n_sessions=0 n_convs=0 n_sandboxes=0 stale_kb=0 d stale=()
 root="$(cowork_sessions_root)"
 banner "Cowork sessions (read-only)" "$K_FACE"
 echo
 section "Claude"
 if claude_running; then
 echo " running (sweeps will skip until you quit it)"
 else
 echo " not running"
 fi
 echo " support: $JANITOR_CLAUDE_SUPPORT"
 echo
 section "Sessions folder"
 layout="$(cowork_layout_check || true)"
 echo " layout: $layout"
 if [[ "$layout" == "absent" ]]; then
 echo " (no local-agent-mode-sessions folder; Cowork never ran here, or the path moved)"
 else
 n_sessions="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
 n_convs="$(cowork_conversation_dirs | grep -c . || true)"
 n_sandboxes="$(find "$root" -mindepth 3 -maxdepth 3 -type d -name 'local_*' 2>/dev/null | wc -l | tr -d ' ')"
 printf ' %-26s %s\n' "total size" "$(path_size "$root")"
 printf ' %-26s %s\n' "sessions" "$n_sessions"
 printf ' %-26s %s\n' "conversations w/ sandboxes" "$n_convs"
 printf ' %-26s %s\n' "task sandboxes (local_*)" "$n_sandboxes"
 if [[ "$layout" == "ok" ]]; then
 while IFS= read -r d; do
 [[ -n "$d" ]] && stale+=("$d")
 done < <(list_stale_sandboxes)
 if [[ ${#stale[@]} -gt 0 ]]; then
 stale_kb="$(sum_dirs_kb "${stale[@]}")"
 fi
 printf ' %-26s %s (%s), older than %sd\n' "stale (sweepable)" "${#stale[@]}" "$(fmt_kb "$stale_kb")" "$S_MAX_AGE_DAYS"
 else
 echo
 echo " Layout differs from local-agent-mode-sessions/<session>/<conversation>/local_<id>."
 echo " Janitor will not delete anything here until the layout is understood. local_* dirs found:"
 find "$root" -mindepth 1 -maxdepth 5 -type d -name 'local_*' -print -prune 2>/dev/null \
 | sed "s|^$root/| |" | head -n 10 || true
 fi
 fi
 echo
 section "Cowork VM"
 sessions_vm_report
 echo
 local state="not adopted (manual: janitor sessions sweep; scheduled: janitor adopt cowork_sandboxes)"
 hog_is_in_enabled_set cowork_sandboxes && state="adopted (scheduled sweeps on)"
 task_is_disabled cowork_sandboxes && state="disabled"
 echo "${C_DIM}cowork_sandboxes: ${state}${C_RESET}"
 [[ -f "$SESSIONS_OK_MARKER" ]] || echo "${C_DIM}First sweep on this Mac will be a dry run.${C_RESET}"
}

sessions_sweep() {
 local dry=0 verbose=0 scheduled=0
 while [[ $# -gt 0 ]]; do
 case "$1" in
 --dry-run) dry=1 ;;
 --scheduled) scheduled=1 ;;
 --max-age)
 shift
 [[ "${1:-}" =~ ^[0-9]+$ && "$1" -ge 1 ]] || die "--max-age needs whole days >= 1"
 S_MAX_AGE_DAYS="$1"
 ;;
 --max-age=*)
 local v="${1#--max-age=}"
 [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]] || die "--max-age needs whole days >= 1"
 S_MAX_AGE_DAYS="$v"
 ;;
 -v|--verbose) verbose=1 ;;
 -h|--help) sessions_usage; return 0 ;;
 *) die "unknown option: $1 (try: janitor sessions help)" ;;
 esac
 shift
 done

 DRY_RUN=$dry
 VERBOSE=$verbose
 BRAVE=0
 STUPID=0
 JANITOR_ONLY="cowork_sandboxes"
 # Manual run = explicit opt-in (deep unlocks the default-off hog).
 # Scheduled run = only if adopted.
 if [[ "$scheduled" -eq 1 ]]; then DEEP=0; else DEEP=1; fi
 export DRY_RUN VERBOSE DEEP BRAVE STUPID JANITOR_ONLY

 local df_before
 df_before="$(free_kb)"
 log_init "sessions"
 if [[ "$DRY_RUN" -eq 1 ]]; then
 banner "Cowork sessions sweep (dry run)" "$K_DRY"
 else
 banner "Cowork sessions sweep" "$K_SWEEP"
 fi
 log_line "# max_age_days=$S_MAX_AGE_DAYS scheduled=$scheduled support=$JANITOR_CLAUDE_SUPPORT"

 clean_cowork_sandboxes
 log_finish "$df_before"

 echo
 section "Cowork VM"
 local vm_out
 vm_out="$(mktemp)"
 sessions_vm_report >"$vm_out"
 cat "$vm_out"
 cat "$vm_out" >>"$LOG_FILE"
 rm -f "$vm_out"

 [[ "$scheduled" -eq 1 ]] || return 0

 # Scheduled: skip streak + notifications
 local streak msg=""
 streak="$(sessions_state_get SKIP_STREAK)"
 if [[ "$SESSIONS_SKIPPED_RUNNING" -eq 1 ]]; then
 streak=$((streak + 1))
 else
 streak=0
 fi
 sessions_state_set SKIP_STREAK "$streak"
 sessions_state_set LAST_RUN "$(date +%s)"

 if [[ "$VM_LEVEL" -ge 1 ]]; then
 msg="$(level_name "$VM_LEVEL"): ${VM_SUMMARY}. Try Help > Troubleshooting > Free Up Cowork Disk Space."
 elif [[ "$SESSIONS_FORCED_DRY" -eq 1 ]]; then
 msg="Found ${SESSIONS_STALE_COUNT} stale Cowork sandboxes ($(fmt_kb "$SESSIONS_STALE_KB")). Next run deletes them. Details: janitor log"
 fi
 if [[ "$streak" -ge 7 && $((streak % 7)) -eq 0 ]]; then
 msg="${msg:+$msg }Sweep skipped ${streak} days running: Claude is always open. Quit it once and run janitor sessions sweep."
 fi
 [[ -n "$msg" ]] && sessions_notify "$msg"
 return 0
}

sessions_vm_reset() {
 local full=0
 while [[ $# -gt 0 ]]; do
 case "$1" in
 --full) full=1 ;;
 -h|--help) sessions_usage; return 0 ;;
 *) die "unknown option: $1" ;;
 esac
 shift
 done
 [[ -t 0 && -t 1 ]] || die "vm-reset is interactive only (no terminal attached). It never runs on a schedule."

 local bundle target
 bundle="$(cowork_bundle)"
 if [[ "$full" -eq 1 ]]; then
 target="$JANITOR_CLAUDE_SUPPORT/vm_bundles"
 else
 target="$bundle/sessiondata.img"
 fi
 [[ -e "$target" ]] || die "nothing to reset: $target not found"
 claude_running && die "Claude is running. Quit Claude desktop fully (Cmd+Q), then retry."

 banner "Cowork VM reset" "$K_FACE"
 echo
 sessions_vm_report
 echo
 echo "Will delete: $target ($(path_size "$target") on disk)"
 echo
 echo "If you swipe: anything Claude saved only inside VM sessions is gone."
 echo "Connected folders are host shares and stay. Claude rebuilds a fresh VM disk on next use."
 if [[ "$full" -eq 1 ]]; then
 echo "--full also drops the VM root image; first Cowork start after will be slower."
 fi
 echo
 local answer=""
 read -r -p "Type 'reset' to continue: " answer
 [[ "$answer" == "reset" ]] || { echo "Cancelled."; return 1; }
 claude_running && die "Claude started. Cancelled."

 local df_before
 df_before="$(free_kb)"
 DRY_RUN=0
 log_init "vm-reset"
 JANITOR_VM_RESET=1
 [[ "$full" -eq 1 ]] && JANITOR_VM_RESET_FULL=1
 local before
 before="$(du_kb "$target")"
 if rm_path "$target"; then
 log_task ok "Cowork VM reset" "freed $(fmt_kb "$before")" "$target"
 history_append "$(date -Iseconds 2>/dev/null || date)" "cowork_vm_reset" "$target" "$before" 0 "$before" "ok"
 TOTAL_FREED_KB=$before
 TOTAL_TASKS=1
 else
 log_task refuse "Cowork VM reset" "refused by allowlist" "$target"
 fi
 # shellcheck disable=SC2034 # read by is_cowork_sweepable_path (common.sh)
 JANITOR_VM_RESET=0
 # shellcheck disable=SC2034
 JANITOR_VM_RESET_FULL=0
 log_finish "$df_before"
}

cmd_sessions() {
 sessions_conf_load
 local sub="${1:-inspect}"
 shift || true
 case "$sub" in
 inspect|status) sessions_inspect "$@" ;;
 sweep) sessions_sweep "$@" ;;
 vm)
 section "Cowork VM"
 sessions_vm_report
 return "$VM_LEVEL"
 ;;
 vm-reset) sessions_vm_reset "$@" ;;
 help|-h|--help) sessions_usage ;;
 *) die "unknown sessions subcommand: $sub (try: janitor sessions help)" ;;
 esac
}
