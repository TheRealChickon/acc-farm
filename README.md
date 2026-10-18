# Card Clash Farm

Auto farm for Anime Card Clash with a window (Sami's old "dawidlib" look, rebuilt: drag it by the title bar,
resize from the bottom-right corner, `–` to fold it, RightControl to hide or show it).

## Start it

From GitHub (private repo, needs a read-only token saved once in the executor workspace as `acc-farm/token.txt`):

```lua
loadstring(request({Url="https://raw.githubusercontent.com/TheRealChickon/acc-farm/main/loader.lua",Headers={Authorization="token "..readfile("acc-farm/token.txt")}}).Body)()
```

Without GitHub (files copied into the executor workspace under `acc-farm/`):

```lua
getgenv().ACC_LOCAL = true loadstring(readfile("acc-farm/loader.lua"))()
```

Then press **Farm running** on the Farm tab.

## What it farms (Farm tab, top of the list goes first)

| Task | What it does |
|---|---|
| Daily login + quests | claims the daily login once a game day and finished daily quests |
| Tower repeats (packs) | every tower floor whose daily repeat reward has instant packs (floor 25 of each main tower: Forest 500k rolls a day, Tremor 400k, Darkness 450k, ...), once per game day |
| Story repeats (packs) | story boss repeats that drop instant packs (the last boss of every difficulty), once per game day |
| Story Skip (keys) | uses one Story Skip key per world to collect that world's daily rewards in one fight, at a start second the PC says wins (needs `ss_watch.py` running on the PC; off by default, idle with 0 keys; Clover Hideout and Deity Planet off until they have a deck) |
| Tower first clears | next uncleared floor of every tower you switched on (main towers, Dream parts, Mage parts) |
| Story first clears | next uncleared story boss in game order |
| Open instant packs | opens instant packs from your backpack (off by default) |
| Story tower crystals | climbs one world's story tower; steps aside whenever something higher in the list is ready |

## Beta tab (new, not tested in the game yet; Whousleaks only; starting one stops the farm)

| Button | What it does | PC side |
|---|---|---|
| Deity helper | Tower of Deity timed wins (4 Deity deck slots, not Deck 15) | `tasks/2026-10-17-deity` driver |
| Speed steering | presses the speed button near each fight's end so the next tower floor starts on a winning second | `steer_helper.py --tower .. --wave ..` |
| Ranked recorder | only reads ranked offers (no season right now) | `ranked_log.py ingest` |

## Cyberpunk tab (Events > Cyberpunk)

Starts and stops the Cyberpunk Run farm script, one switch per window (the window's own account) and shows what the farm and the deck optimiser
already write. It plays nothing itself: the shared `cyber_farm.lua` is read from the executor workspace every time it starts
(`AnimeCardClash/` for Whousleaks, `AnimeCardClash/umson/` for Umson_42), so it is always the newest one.

| Part | What it does |
|---|---|
| Switch "Cyberpunk farm running" | on = checks everything, sets the flag file to `1`, starts the script in its own thread; off = `_G.__CF_STOP` and `0` in `cyber_farm.flag` (and switches off the autoexec's restart after a rejoin, `umson/cyber.flag`). Starting stops the tower / story farm first (one script sends at a time); the tower / story farm waits while the Cyberpunk farm runs. |
| Script: Newest / Previous | Newest = `cyber_farm.lua`; if it is missing, does not compile or crashes in the first 30 s, `cyber_farm_prev.lua` starts instead. Previous = that one on purpose. |
| What it shows | state and act / room / Eddies / runs from `cyber_farm_hb.json`; from `cyber_status_<account>.json`: what it is aiming for, the next purchase, the deck in play, the best deck found, what the optimiser is trying now. |
| Safety lines | shop buying (OFF; if the settings say ON it is switched OFF at every start, never ON), the lock (`whousleaks_owner.json` / `umson/cyber_owner.json`: the farm waits unless it says `cyberpunk_w` / `cyberpunk_u`; the window never changes the lock), the anti-AFK heartbeat (anti-AFK runs from the autoexec, not from here). |
| Test mode | `_G.__CF_DRY`: the farm decides and logs but sends nothing. |
| Other account | its state, and a stop button (flag file only; start it from that account's own window). |

Joyride is not part of this tab. Stop and close also stops the Cyberpunk farm, but only when this window started it.

## Accounts

Runs on every account in Settings (default `Whousleaks, Umson_42`). Each account has its own settings file
(`acc-farm/settings_<name>.json`, Whousleaks keeps `acc-farm/settings.json`) and its own plan folder
(Whousleaks `AnimeCardClash/`, Umson_42 `AnimeCardClash/umson/`), so one client never waits for the other's climber.
Anti-AFK (Settings, on by default) takes a small step every 10 minutes.

A fight that is lost **Losses before skipping** times in one game day is left alone until the next day, so the
farm moves on to other towers "until it gets hard" by itself.

## Rules built in

- Deck changes only in **Deck 15** (`slot_15`). Your other decks are never touched.
- At least 1.4 s between two game commands. No hooks, no listeners.
- Only runs on the accounts in Settings (default `Whousleaks, Umson_42`).
- Waits while another script (the climbers) is running, and pauses when the game uses too much memory.

## Decks

**Best stored deck** uses the decks the optimiser already writes (`AnimeCardClash/tower_plan_<tower>.json`,
`climb_decks.json`, `story_plan.json`) and your own `acc-farm/decks.json`; with nothing stored it keeps Deck 15 as it is.
**Timed starts** asks the PC helpers (`tower_watcher.py`, `story_scan_watcher.py`) for a winning start second.

## Not done yet

Ranked, Tower of Deity and the Chainsaw event need one live look first (their commands need data the game only shows
live). **Probe** on the "Dailies & events" tab saves that data to `acc-farm/probe.json` without sending anything.

## For changes

- `src/` modules, `loader.lua` loads `dist/acc-farm.lua` (all modules in one file).
- After editing: `python3 tools/bundle.py` (rebuilds `dist/`), then `luau tests/run.luau` (fake game, runs hours of farming in a second).
  Without the Luau CLI (Windows PC): `lune run tests/run.luau` does the same. `python tools/check_farm.py` checks that the installed farm scripts still keep
  what the Cyberpunk tab relies on (stop flag, alive stamp, heartbeat, account table); run it after the Cyberpunk threads change `cyber_farm.lua`.
- After a game update: `python3 tools/build_data.py <macro/data/towers.json> <macro/data/story.json>` rebuilds `src/data.lua`.
