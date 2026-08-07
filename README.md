# Janitor

Mac **developer** housekeeper. Reclaims **disk** from known tool caches and regenerable leftovers under `~/Library`. Desktop sweeper box: **assess → choose (opt in) → sweep → done**.

**Disk hogs vs RAM hogs:** Janitor sweeps *disk* hogs (cache files on your SSD). *RAM* hogs are apps holding memory now; quit them (or restart) to free RAM. Deleting a cache does not empty memory. `janitor status` shows a RAM snapshot only; try `janitor educate ram`.

**Never** touches `~/Documents` or `~/Downloads`. Positive allowlist only (Caches, Logs, Developer, known tool dirs, plus narrow Just-stupid paths).

Each reclaimable target is a **hog** (`{^oo^}`) with **Hogging because:** / **If you swipe:** blurbs and optional **📖** educate copy.

## Tiers

| Tier | Flag / button | What it unlocks |
|------|----------------|-----------------|
| Default | Start sweep | Dev + AI desktop caches (Homebrew, npm, Gradle, Xcode DerivedData, Cursor, ChatGPT, …) |
| Deep | `--deep` / Start deep sweep | Default-off leftovers (e.g. Claude ShipIt) |
| Brave | `--brave` / Brave sweep | Browser & media caches (Chrome, Safari, Steam, Spotify, Discord, …) |
| Just stupid | `--stupid` / Just stupid | Superset of Brave, plus sandboxed `Containers/…/Caches`, Application Support `Cache`/`Caches` folders, Docker prune |

Desktop: help **`?`** sits to the **right** of Brave / Just stupid (hover tip + click alert; never starts a sweep). Nothing deletes until you check hogs and hit **Sweep now**.

## Commands

```bash
janitor status
janitor hogs
janitor discover
janitor educate npm          # or: janitor educate ram
janitor adopt shipit
janitor hog add ~/Library/Caches/my-tool
janitor clean --dry-run
janitor clean --brave --dry-run
janitor clean --stupid --dry-run
janitor clean --only homebrew,npm
janitor desktop              # also: --deep / --brave / --stupid
janitor tasks
janitor disable playwright
janitor enable playwright
janitor log [--path]
```

Catalog: [`config/hogs.catalog`](config/hogs.catalog).  
User config: `~/.config/janitor/disabled`, `~/.config/janitor/hogs`.  
Logs: `~/Library/Logs/janitor/`.

## Install

```bash
./install.sh
./install.sh --desktop    # ~/Desktop/Janitor.app
./install.sh --schedule   # optional weekly LaunchAgent
```

Put `~/bin` on your `PATH` if needed.

## Layout

```
bin/janitor                 # CLI
bin/janitor-desktop         # sweeper box orchestrator
bin/janitor-sweep-hud       # Swift HUD launcher
desktop/sweep-hud/          # HUD source
lib/{common,config,cleaners}.sh
config/hogs.catalog
install.sh
```
