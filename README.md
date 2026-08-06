# Janitor

Mac **developer** housekeeper. Reclaims **disk** from known tool caches (`~/.gradle`, `~/.npm`, Xcode DerivedData, …) and regenerable leftovers under `~/Library`.

**Disk hogs vs RAM hogs:** Janitor sweeps *disk* hogs : cache files that sit on your SSD and free gigabytes when cleared. *RAM* hogs are apps holding memory right now; quit them (or restart) to free RAM. Deleting a cache folder does not empty memory. `janitor status` shows a RAM snapshot for pressure awareness only : it is not a RAM cleaner. Try `janitor educate ram`.

**Never** touches `~/Documents`, `~/Downloads`. Catalog also lists common **AI desktop** caches (ChatGPT, Perplexity, Claude, Gemini, Grok, …) under `~/Library/Caches` : they only show size when the folder exists. Brave/Stupid mode adds browser/media caches.

## Hogs

Each reclaimable target is a **hog** ({^oo^}). List them one row per hog. Choose / done UI shows **Hogging because:** and **If you swipe:** : tap **📖** (or `janitor educate <id>`) for up to three short paragraphs more.

```bash
janitor hogs
janitor discover
janitor educate npm
janitor adopt shipit
janitor clean __PROT0__ __PROT1__
```

Catalog lives in the repo (`config/hogs.catalog__PROT34____PROT95__ disable <id>` (saved in `~/.config/janitor/disabled__PROT39__janitor desktop`.

## Opt out of tasks

```bash
janitor tasks # list ids + enabled/disabled/off
janitor disable playwright # never clean this (until re-enabled)
janitor enable playwright
janitor clean __PROT3__ homebrew,npm,old_logs
```

Config is per-user and portable: `~/.config/janitor/disabled__PROT43__config/disabled.example__PROT44__~/Documents__PROT45__~/Downloads__PROT46__~/Library/Caches__PROT47__~/.gradle__PROT48__`__PROT49__`__PROT50__~/bin__PROT51__PATH__PROT52__`__PROT53__`__PROT54__clean__PROT55__~/Library/Logs/janitor/__PROT56__~/Library/Logs/janitor/clean-YYYYMMDD-HHMMSS.log__PROT57__~/Library/Logs/janitor/latest.log__PROT58__~/Library/Logs/janitor/history.tsv__PROT59__~/Library/Logs/janitor/desktop-debug.log__PROT60__du__PROT61__df__PROT62__brew cleanup -s` + `autoremove` (measures brew cache) |
| npm | `npm cache clean --force` |
| pip / pip3 | `pip cache purge` |
| Gradle | `~/.gradle/caches__PROT67__.downloadIntermediates__PROT68__~/.android/cache__PROT69__qemu/*__PROT70__DerivedData__PROT71__.cache__PROT72__~/Library/Caches/CocoaPods__PROT73__~/.dartServer__PROT74__dart__PROT75__flutter pub cache clean` |
| Simulators | `xcrun simctl delete unavailable` |
| Old logs | `~/Library/Logs__PROT78__janitor/__PROT79__~/Library/Caches/Cursor__PROT80__status__PROT81__/System/Volumes/Data__PROT82____PROT14____PROT83____PROT15____PROT84____PROT16____PROT85____PROT19____PROT86____PROT20____PROT87____PROT21____PROT88__janitor adopt <id>` to enable without the flag. Desktop welcome offers **Brave / Stupid sweep**.

Report-only (never cleaned): Docker.raw / Containers, full Cursor Application Support, whole Android SDK tree.

## Layout

```
bin/janitor
bin/janitor-desktop # sweeper box orchestrator (welcome → assess → choose → sweep → done)
bin/janitor-sweep-hud # launches multi-phase Swift sweeper box
bin/janitor-sweep-hud.appbin # compiled Swift UI (built by desktop/build-app.sh)
desktop/sweep-hud/ # Swift source for the sweeper box
lib/common.sh
lib/config.sh # ~/.config/janitor + hog catalog loader
lib/cleaners.sh
config/hogs.catalog # known DEV hogs (repo)
config/hogs.example # user hogs file template
config/disabled.example
install.sh
launchd/…
desktop/ # app builder + icon
```

## Schedule

`./install.sh --schedule` loads a LaunchAgent with a PATH that includes Homebrew, nvm node (if present), and Flutter. Working directory is `$HOME`. Script logging does not depend on stdout redirects.

```bash
launchctl list | grep janitor
```
