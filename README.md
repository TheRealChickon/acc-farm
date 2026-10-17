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
| Tower first clears | next uncleared floor of every tower you switched on (main towers, Dream parts, Mage parts) |
| Story first clears | next uncleared story boss in game order |
| Open instant packs | opens instant packs from your backpack (off by default) |
| Story tower crystals | climbs one world's story tower; steps aside whenever something higher in the list is ready |

A fight that is lost **Losses before skipping** times in one game day is left alone until the next day, so the
farm moves on to other towers "until it gets hard" by itself.

## Rules built in

- Deck changes only in **Deck 15** (`slot_15`). Your other decks are never touched.
- At least 1.4 s between two game commands. No hooks, no listeners.
- Only runs on the account in Settings (default `Whousleaks`).
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
- After a game update: `python3 tools/build_data.py <macro/data/towers.json> <macro/data/story.json>` rebuilds `src/data.lua`.
