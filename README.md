# Janitor

Mac **developer** housekeeper. Reclaims **disk** from known tool caches (`~/.gradle`, `~/.npm`, Xcode DerivedData, …) and regenerable leftovers under `~/Library`.

**Disk hogs vs RAM hogs:** Janitor sweeps *disk* hogs: cache files that sit on your SSD and free gigabytes when cleared. *RAM* hogs are apps holding memory right now; quit them (or restart) to free RAM. Deleting a cache folder does not empty memory. `janitor status` shows a RAM snapshot for pressure awareness only; it is not a RAM cleaner. Try `janitor educate ram`.

**Never** touches `~/Documents`, `~/Downloads`. Catalog also lists common **AI desktop** caches (ChatGPT, Perplexity, Claude, Gemini, Grok, …) under `~/Library/Caches`; they only show size when the folder exists.

**Tiers**

- Default: dev / AI caches
- `--deep`: default-off leftovers (e.g. ShipIt)
- `--brave`: browser/media caches
- `--stupid`: one notch past caches (includes brave): sandboxed container caches, Application Support `Cache`/`Caches` folders, Docker prune

Desktop welcome: **Start sweep**, **Start deep sweep**, **Brave sweep**, **Just stupid** (help `?` buttons sit to the right of Brave / Just stupid so they never launch a sweep).

## Hogs

Each reclaimable target is a **hog** (`{^oo^}`). List them one row per hog. Choose / done UI shows **Hogging because:** and **If you swipe:**; tap **📖** (or `janitor educate <id>`) for up to three short paragraphs more.

```bash
janitor hogs
janitor discover
janitor educate npm
janitor adopt shipit
janitor clean --dry-run
janitor clean --brave --dry-run
janitor clean --stupid --dry-run
janitor desktop
```

Catalog: `config/hogs.catalog`. User opts: `~/.config/janitor/disabled`, `~/.config/janitor/hogs`.

## Opt out of tasks

```bash
janitor tasks
janitor disable playwright
janitor enable playwright
janitor clean --only homebrew,npm,old_logs
```

## Install

```bash
./install.sh
./install.sh --desktop   # Desktop/Janitor.app
```

Ensure `~/bin` is on your `PATH`.

## Layout

```
bin/janitor
bin/janitor-desktop
bin/janitor-sweep-hud
desktop/sweep-hud/
lib/common.sh
lib/config.sh
lib/cleaners.sh
config/hogs.catalog
install.sh
```

## Schedule

`./install.sh --schedule` loads a LaunchAgent. Logs live under `~/Library/Logs/janitor/`.
