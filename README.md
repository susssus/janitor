# Janitor

Mac **developer** housekeeper. Reclaims **disk** from known tool caches (`~/.gradle`, `~/.npm`, Xcode DerivedData, …) and regenerable leftovers under `~/Library`.

**Disk hogs vs RAM hogs:** Janitor sweeps *disk* hogs — cache files that sit on your SSD and free gigabytes when cleared. *RAM* hogs are apps holding memory right now; quit them (or restart) to free RAM. Deleting a cache folder does not empty memory. `janitor status` shows a RAM snapshot for pressure awareness only — it is not a RAM cleaner. Try `janitor educate ram`.

**Never** touches `~/Documents`, `~/Downloads`. Brave/Stupid mode can add browser/media *caches* (still never Documents/Downloads).

## Hogs

Each reclaimable target is a **hog** (🐗). List them one row per hog. Choose / done UI shows **Hogging because:** and **If you swipe:** — tap **📖** (or `janitor educate <id>`) for up to three short paragraphs more.

```bash
janitor hogs
janitor discover
janitor educate npm
janitor adopt shipit
janitor clean --brave --dry-run
```

Catalog lives in the repo (`config/hogs.catalog`). Your enabled extras and custom paths live in `~/.config/janitor/hogs` (not committed).

## Desktop button (sweeper box)

```bash
./install.sh --desktop
```

Puts **Janitor.app** on your Desktop. Double-click opens the **sweeper box**:

1. **Welcome** — Start sweep or Start deep (nothing deleted yet)  
2. **Assessing** — live indexing log while gauging reclaimable caches  
3. **Choose** — check what to clean (none checked by default; Check all / Uncheck all)  
4. **Sweeping** — live clean log for the tasks you checked  
5. **Done** — hooray + freed summary + swept task lines  

Permanent skips: `janitor disable <id>` (saved in `~/.config/janitor/disabled`).

Same flow from the terminal: `janitor desktop`.

## Opt out of tasks

```bash
janitor tasks                 # list ids + enabled/disabled/off
janitor disable playwright    # never clean this (until re-enabled)
janitor enable playwright
janitor clean --only homebrew,npm,old_logs
```

Config is per-user and portable: `~/.config/janitor/disabled` (see `config/disabled.example`).

## Sacrosanct

**Never touches** `~/Documents` or `~/Downloads` (hard path guard on every delete). Path hogs must also sit under an allowlisted cache root (`~/Library/Caches`, `~/.gradle`, …). No home-wide sweeps. No media.

## Quick start

```bash
./install.sh            # symlink ~/bin/janitor + create log dir
./install.sh --desktop  # Desktop Janitor.app (sweeper box UI)
./install.sh --schedule # also: weekly LaunchAgent (Sun 10:00)
```

Ensure `~/bin` is on your `PATH`, then:

```bash
janitor status              # disk + hog sizes (sorted)
janitor hogs                # 🐗 one row per hog
janitor discover            # suggestions to adopt
janitor desktop             # GUI: sweeper box
janitor tasks               # enable/disable list
janitor clean --dry-run     # preview + write log (no deletes)
janitor clean               # clean + always log what/how much
janitor clean --deep        # + default-off deep hogs (e.g. ShipIt)
janitor log                 # show latest session log
janitor log --path          # print path only
```

## Logging (always on)

Every `clean` (including dry-run and launchd) writes under `~/Library/Logs/janitor/` (local only — not shipped with the repo):

| File | Purpose |
|------|---------|
| `~/Library/Logs/janitor/clean-YYYYMMDD-HHMMSS.log` | Full session |
| `~/Library/Logs/janitor/latest.log` | Symlink to last run |
| `~/Library/Logs/janitor/history.tsv` | Append-only per-task rows |
| `~/Library/Logs/janitor/desktop-debug.log` | Desktop GUI / HUD debug trail |

Each task records path, before/after KB, freed KB, and status. The summary uses measured `du` totals; `df` delta is informational only (APFS is noisy).

## Default cleaners (catalog)

| Task | Target |
|------|--------|
| Homebrew | `brew cleanup -s` + `autoremove` (measures brew cache) |
| npm | `npm cache clean --force` |
| pip / pip3 | `pip cache purge` |
| Gradle | `~/.gradle/caches` + daemon dir contents |
| Android | SDK `.downloadIntermediates`, `~/.android/cache`, emulator `qemu/*` temps |
| Xcode | `DerivedData` contents |
| Playwright / HF | Named Library / `.cache` dirs |
| CocoaPods | `~/Library/Caches/CocoaPods` |
| Dart / Flutter | `~/.dartServer`; `dart`/`flutter pub cache clean` |
| Simulators | `xcrun simctl delete unavailable` |
| Old logs | `~/Library/Logs` files older than 14 days (keeps `janitor/`) |
| Cursor | `~/Library/Caches/Cursor` only (not Application Support) |

`status` prints disk, a short **disk vs RAM** primer, a **RAM snapshot** (not cleaned), then reclaimable disk hogs. Disk view prefers `/System/Volumes/Data`.

## `--deep` and `--brave` / `--stupid`

| Flag | Unlocks |
|------|---------|
| `--deep` | Default-off **dev** leftovers (e.g. Claude ShipIt) |
| `--brave` / `--stupid` | **Wider** browser & media caches (Chrome, Safari, Steam, Spotify, Discord, Stremio, …) |

Still **never** Documents/Downloads. Adopt individual brave hogs with `janitor adopt <id>` to enable without the flag. Desktop welcome offers **Brave / Stupid sweep**.

Report-only (never cleaned): Docker.raw / Containers, full Cursor Application Support, whole Android SDK tree.

## Layout

```
bin/janitor
bin/janitor-desktop   # sweeper box orchestrator (welcome → assess → choose → sweep → done)
bin/janitor-sweep-hud # launches multi-phase Swift sweeper box
bin/janitor-sweep-hud.appbin  # compiled Swift UI (built by desktop/build-app.sh)
desktop/sweep-hud/    # Swift source for the sweeper box
lib/common.sh
lib/config.sh         # ~/.config/janitor + hog catalog loader
lib/cleaners.sh
config/hogs.catalog   # known DEV hogs (repo)
config/hogs.example   # user hogs file template
config/disabled.example
install.sh
launchd/…
desktop/              # app builder + icon
```

## Schedule

`./install.sh --schedule` loads a LaunchAgent with a PATH that includes Homebrew, nvm node (if present), and Flutter. Working directory is `$HOME`. Script logging does not depend on stdout redirects.

```bash
launchctl list | grep janitor
```
