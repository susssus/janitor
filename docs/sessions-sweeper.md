# Cowork sessions sweeper (`janitor sessions`)

## Problem

Claude desktop runs Cowork in a local Linux VM. Three things grow and nothing cleans them up on a schedule:

| Layer | Where (host) | What grows |
|---|---|---|
| Host session state | `~/Library/Application Support/Claude/local-agent-mode-sessions/<session>/<conversation>/local_<id>/` | One `local_<id>` sandbox per task/subagent run (often ~300 MB), never deleted |
| VM `/sessions` disk | `…/Claude/vm_bundles/claudevm.bundle/sessiondata.img` | Holds `/sessions/*` inside the VM; fills up → ENOSPC, new sessions fail |
| VM root disk | `…/claudevm.bundle/rootfs.img` | Raw image that only grows; never trimmed |

The cache allowlist can't (and shouldn't) cover this: it's session state. So it gets its own narrow allowlist plus gates, instead of a looser global allowlist.

## Commands

```
janitor sessions [inspect]        read-only: layout, sizes, stale sandboxes, VM fill
janitor sessions sweep [--dry-run] [--max-age DAYS] [-v]
janitor sessions sweep --scheduled   (LaunchAgent; sweeps only if adopted)
janitor sessions vm               exit 0 ok / 1 warn / 2 critical
janitor sessions vm-reset [--full]   interactive only
```

Catalog hog: `cowork_sandboxes` (default `off`). A manual `janitor sessions sweep` counts as opting in. `janitor clean --deep` includes it too. Scheduled runs need `janitor adopt cowork_sandboxes`. `janitor status` shows two report-only rows (sessions folder, VM bundle).

VM reset is deliberately **not** a catalog hog, so no `clean` tier (not even `--stupid`) can trigger it.

## What gets deleted

Only paths matching `is_cowork_sweepable_path` (`lib/common.sh`):

- `local-agent-mode-sessions/<session>/<conversation>/local_<hex/uuid>`, at exactly that depth
- `vm_bundles/claudevm.bundle/sessiondata.img`, only inside `vm-reset`
- `vm_bundles`, only inside `vm-reset --full`

Anything else under `local-agent-mode-sessions/` or `vm_bundles/` is denied, even for other sweepers. `as_caches` used to match any `Cache` folder under Application Support, including ones inside live sandboxes. It now skips both trees.

## Gates

1. **Claude must be quit.** `pgrep -x Claude`, plus `lsof` on the VM images. The check runs again before each delete.
2. **Layout check.** Any `local_*` folder at an unexpected depth → refuse everything, and `inspect` lists what it found. Claude updates can move things; we fail closed.
3. **Stale** = nothing inside the sandbox has changed in `SANDBOX_MAX_AGE_DAYS` (14).
4. **The newest sandbox per conversation is always kept**, whatever its age.
5. **First sweep on a Mac is a dry run** (marker: `~/.config/janitor/sessions.ok`). Under `--scheduled` it sends a notification saying what the next run will delete.
6. **`vm-reset`** needs a terminal, shows sizes, wants you to type `reset`, and re-checks that Claude is quit.

## "Does the VM have space?"

The Mac can't run `df /sessions`, so there are two signals:

- **Host heuristic (always on).** `sessiondata.img` is sparse: fill ≈ allocated (`du`) / capacity (`stat`). The VM doesn't trim, so allocated only grows, which makes this an **upper bound**. It can false-alarm after cleanup but can't miss a full disk.
- **Probe (optional, exact).** If `PROBE_FILE` has a line newer than `PROBE_MAX_AGE_H` (36 h), it's used instead. Format, one JSON line per run:
  `{"ts":<epoch>,"sessions_pct":<n>,"root_pct":<n>,"sessions_count":<n>}`

  To feed it, make a daily Cowork scheduled task with `~/Claude/janitor` connected, with a prompt like:

  > Run `printf '{"ts":%s,"sessions_pct":%s,"root_pct":%s,"sessions_count":%s}\n' "$(date +%s)" "$(df -P /sessions | awk 'NR==2{print $5+0}')" "$(df -P / | awk 'NR==2{print $5+0}')" "$(ls /sessions | wc -l)"` and append the output line to `vm-df.jsonl` in the connected janitor folder. Nothing else.

  Every probe run is itself a session, so keep it daily at most. The sweeper cleans up after it.

Levels (`sessions.conf`): `/sessions` ≥ 80 % warn / ≥ 92 % critical; rootfs ≥ 12 / 18 GB; Mac free < 20 / 8 GB.

## Remediation ladder

Least destructive first. The scheduled job only ever does step 1; for the rest it notifies.

1. `janitor sessions sweep`
2. Claude desktop: Help → Troubleshooting → **Free Up Cowork Disk Space** (Anthropic's own cleaner; it knows which sessions are live)
3. Delete old sessions in the Cowork sidebar
4. `janitor sessions vm-reset` (`--full` also drops rootfs). **If you swipe:** files kept only inside VM sessions are lost; connected folders are host shares and stay.

## Schedule

`launchd/com.susssus.janitor.sessions.plist`: daily 13:17, `janitor sessions sweep --scheduled`. Claude is usually open in the daytime, so a skipped sweep is normal. After 7 skips in a row, the notification says so. Install with `./install.sh --schedule-sessions`.

## Open questions

- Layout comes from public bug reports, not verified on every build. Run `janitor sessions` first. `layout: ok` means sweeps can run.
- Is anything in an older `local_*` needed to resume a session? Keeping the newest per conversation should cover resume. If not, raise `SANDBOX_MAX_AGE_DAYS`.

## Sources

- rootfs.img grows unbounded; session state lives in local-agent-mode-sessions: https://github.com/anthropics/claude-code/issues/65577
- `local_<id>` sandboxes never cleaned; in-app "Free Up Cowork Disk Space": https://claudeissues.com/issue/92158
- `/sessions` fills within hours for scheduled-task users: https://claudeissues.com/issue/44622
- Per-session plugin copies; deleting sessions + sessiondata.img: https://claudeissues.com/issue/37860
- Quit + delete vm_bundles workaround: https://claudeissues.com/issue/75302
