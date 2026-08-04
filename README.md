# Janitor

Mac development housekeeper. Reclaims disk from **`~/Library`** caches/logs/dev leftovers and known tool caches (`~/.gradle`, `~/.npm`, `~/.pub-cache`, …).

## Desktop button (two-phase)

```bash
./install.sh --desktop
```

Puts **Janitor.app** on your Desktop. Double-click:

1. **Assess** (or Assess deep) — dry-run; nothing deleted  
2. Review the summary dialog  
3. **Clean now** — only then does cleanup run  

Cancel at either step leaves the disk untouched. Same flow from the terminal: `janitor desktop`.

## Sacrosanct

**Never touches** `~/Documents` or `~/Downloads` (hard path guard on every delete). No home-wide sweeps.

## Quick start

```bash
./install.sh            # symlink ~/bin/janitor + create log dir
./install.sh --desktop  # Desktop Janitor.app (assess → confirm → clean)
./install.sh --schedule # also: weekly LaunchAgent (Sun 10:00)
```

Ensure `~/bin` is on your `PATH`, then:

```bash
janitor status              # disk + reclaimable sizes (sorted)
janitor desktop             # GUI two-phase clean
janitor clean --dry-run     # preview + write log (no deletes)
janitor clean               # clean + always log what/how much
janitor clean --deep        # + larger Library/Caches app leftovers
janitor log                 # show latest session log
janitor log --path          # print path only
```

## Logging (always on)

Every `clean` (including dry-run and launchd) writes:

| File | Purpose |
|------|---------|
| `~/Library/Logs/janitor/clean-YYYYMMDD-HHMMSS.log` | Full session |
| `~/Library/Logs/janitor/latest.log` | Symlink to last run |
| `~/Library/Logs/janitor/history.tsv` | Append-only per-task rows |

Each task records path, before/after KB, freed KB, and status. The summary uses measured `du` totals; `df` delta is informational only (APFS is noisy).

## Default cleaners

| Task | Target |
|------|--------|
| Homebrew | `brew cleanup -s` + `autoremove` (measures brew cache) |
| npm | `npm cache clean --force` |
| pip / pip3 | `pip cache purge` |
| Gradle | `~/.gradle/caches` + daemon dir contents |
| Android | SDK `.downloadIntermediates`, `~/.android/cache`, emulator `qemu/*` temps |
| Xcode | `DerivedData` contents |
| Playwright / Google / HF | Named Library / `.cache` dirs |
| Stremio | stremio-cache (skipped if app/server running) |
| CocoaPods | `~/Library/Caches/CocoaPods` |
| Dart / Flutter | `~/.dartServer`; `dart`/`flutter pub cache clean` (not `pub cache repair`) |
| Simulators | `xcrun simctl delete unavailable` |
| Old logs | `~/Library/Logs` files older than 14 days (keeps `janitor/`) |
| Cursor | `~/Library/Caches/Cursor` only (not Application Support) |

`status` and each `clean` also print a **RAM snapshot** (available-ish, compressed, wired, memory free %, top RSS) — from the old `sanemaker.sh` playbook. Disk view prefers `/System/Volumes/Data`.

## `--deep`

Also clears named `~/Library/Caches` leftovers: Claude ShipIt, Mozilla, Firefox, Canva updater, Steam, Stremio5.

Still never touches Documents/Downloads, Docker.raw, full Cursor Application Support, or the whole Android SDK tree (those appear in `status` as report-only).

## Layout

```
bin/janitor
lib/common.sh      # logging, assert_safe_path, run_path_task / run_cmd_task
lib/cleaners.sh    # allowlisted tasks
install.sh
launchd/com.susssus.janitor.plist
```

## Schedule

`./install.sh --schedule` loads a LaunchAgent with a PATH that includes Homebrew, nvm node (if present), and Flutter. Working directory is `$HOME`. Script logging does not depend on stdout redirects.

```bash
launchctl unload ~/Library/LaunchAgents/com.susssus.janitor.plist
```
