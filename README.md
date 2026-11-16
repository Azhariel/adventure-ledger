# Adventure Ledger

A dashboard for WoW Forever built from what your addons already save: leveling, gold, time, zones, professions,
best crafts, net worth, the auction house (your faction's and the Neutral one, kept apart), fights and damage,
quests, deaths and flights, with forecasts. Plus a live view from the combat log while you play.

Made by Azhariel: [GitHub](https://github.com/Azhariel) · [Ko-fi](https://ko-fi.com/azhariel). Bug reports and ideas are welcome in the
[issues](https://github.com/Azhariel/adventure-ledger/issues).

Two parts:

- **`addons/`**: the in-game half, six addons that record what the dashboard shows.
- **`dashboard/`**: a Lua builder that reads your SavedVariables and writes one HTML page, and an optional
  Python live server. WoW never loads it.

## Install

1. Install [Lua 5.4](https://www.lua.org/download.html) (`%LOCALAPPDATA%\Programs\Lua\bin\lua.exe` is found on
   its own) and, for the live view, Python 3.
2. Double-click **`install.bat`**. It finds WoW Forever (or asks), copies the addons into `Interface\AddOns`,
   writes `ledger.cfg`, and says which of the other addons below you still need. Run it again after updating
   to replace the old copies (the page's ~/about/addons says when an update is out); replaced folders are backed
   up to `data\addon-backups`. Your saved data (the WTF
   folder) is never touched. Another WoW folder: `install.bat -Wow "D:\Games\World of Warcraft\_forever_"`.
3. Optional: put a `wowstats.bat` on your PATH containing `@call "<repo>\bin\wowstats.bat" %*`.

### Included addons

| Addon | What it records |
| --- | --- |
| Logbook | Your journey: XP, levels, gold by source, kills, quests, deaths, zones, dungeons, professions, sessions, trail, damage (from the game's damage meter), flights |
| Ledger Link | Keeps the combat log on for the Live view; keeps Neutral auction house prices apart from your faction's |
| Make or Buy | Your recipes and what to craft or buy (Best crafts, restock list, mail to alts) |
| Stockpile | What each character holds in bags, bank and mail |
| Haul | Your farming session: loot, coin and XP per hour |
| DropLab | What each kind of mob drops for you |

### Other addons it reads

These aren't ours to share, so the installer only checks for them:

| Addon | Feeds | Get it |
| --- | --- | --- |
| Auctionator | All auction house prices: the Market section, net worth, craft profits | [CurseForge](https://www.curseforge.com/wow/addons/auctionator) |
| QuestieDB | Item names | Comes with Questie: [CurseForge](https://www.curseforge.com/wow/addons/questie) |

The page builds with whatever is there; a module without its addon says what it's waiting for.

**Coming from MuddyBoots?** Keep it enabled for one login (or `/reload`) on each character with Logbook
installed. Logbook copies its lifetime counters and its older history (log, play sessions, trail) into its own
saved file, once, and carries on from there. After that you can remove MuddyBoots and its saved files.

## Develop

`install.bat -Dev` links the addons into WoW (directory junctions, no admin rights) instead of copying them,
so the game runs the repo's files: edit them here, never in `Interface\AddOns`. When WoW sees a change:

| You change | WoW picks it up |
| --- | --- |
| An existing `.lua` or `.xml` file | `/reload` |
| A new or renamed file, or a `.toc` | Restart the game (it reads `.toc` files only at startup) |
| A new addon folder in `addons/` | `install.bat -Dev` once, then restart the game |

A plain `install.bat` leaves those links alone (`-Copy` replaces them with copies). `ledger.cfg` holds your paths (see
`ledger.cfg.example`); git ignores it and `data/`, where the page, your price logs and the zone maps go, since
they hold your characters' data.

When you change an addon, raise the `## Version` in its `.toc` in the same push (patch for a fix, minor for
something new). The page's Addons module compares that line with the one on GitHub's `main` to tell players an
update is out; an unchanged version means no warning.

## Use

1. Log out of WoW (or `/reload`). WoW only writes SavedVariables then; no addon can save in between.
2. Run `wowstats` (or double-click `dashboard\build.bat`). It writes `data\dashboard.html` and opens it.

### Layout

A menu on the left holds every module, grouped as `~/character` (Overview, Progress, Gold, Combat & quests, Replay: the
character picked above the menu), `~/account` (Characters, Inventory, Mail to alts, Drop rates), `~/market`
(Signals, Stockpile, Browse, Movers, Faction vs Neutral, Your trades, Crafting), `~/live` and `~/about` (About:
what each module shows, for new users; Addons: each addon the page reads, its version in WoW, in your copy and
on GitHub, and what to do when one is out of date, switched off or missing). The address bar
remembers the module (`dashboard.html#/stockpile`). Colours are Dracula, with fixed roles: **cyan = Faction AH,
orange = Neutral AH, pink dashes and band = a forecast**.

### Motion

Each effect answers something you did or shows data arriving: charts trace in from the left, with the pink
forecast extending once the history has drawn; a pink bar slides between modules and a thumb slides in the
Faction / Neutral switch; panels settle in when a module opens; KPI numbers count up; a soft light follows the
pointer across panels; sparklines draw in when a table first appears; the clicked row flashes; the Live dot pulses
while the combat log is fresh. All of it switches off with the system's reduce-motion setting.

### Forecasts

- **Prices and stockpile value**: damped Holt (level plus a trend that fades, phi 0.85) on log daily lows, its
  smoothing picked by least squares; 7 days ahead with an 80% band. Needs 3 scan days.
- **Gold on hand**: least squares weighted toward recent play, carried a quarter of your played span ahead.
- **Next level**: your XP rate over the last few played hours against the XP still needed (Haul).
- **Level 60**: a power law (hours per level against level, on log scales) fitted to your finished levels.

### Market

Works from the file too (no server needed). From Auctionator's price database (one lowest and highest buyout and
the number listed per item per scan day) plus the dashboard's own price log, `price_log.tsv`: every build adds a line
for each item whose price changed, so each /reload after an AH scan is another point on the chart.

- **Faction / Neutral switch** (top right on Signals, Stockpile, Browse and Movers) picks which house's prices
  those modules use. The **item inspector** (click any row) draws both houses on one chart, with the forecast for
  the house in view and a separate chart of how many were listed.
- **Signals**: your stockpile's value per scan day with its forecast, your best sellers, buy low / sell high.
- **Stockpile** (all characters): now, launch low (lowest daily low), change against it, peak (highest daily
  low), supply (listed now vs the first scan day; fewer = green), trend, value, and a signal: *selling window*
  (2x the launch low or more and fewer listed), *rising* (+50%), *still cheap* (within 15% of the low).
- **Browse**: the full price database, or one trade-goods family (id lists in `dashboard/lib/insights.lua`, `I.FAMILIES`).
- **Movers**: rising fastest (+50% over a launch low of 10c or more, 20+ listed), fallen furthest (30% under peak).
- **Faction vs Neutral**: items priced at both houses, the gap, and what a flip makes after each house's cut (15%
  at Neutral, 5% at Faction). By default only items with 5+ listed at both, since one stray listing sets the price
  in a thin market.
- **Your trades** and **Crafting** (the picked character): the AH ledger and the best crafts at saved prices.
- Item, creature and quest names link to Wowhead; player names link to the WoW Forever armory.

### Neutral auction house

Auctionator keeps one price book per realm, so a scan at the goblin AH (Gadgetzan, Booty Bay, Everlook) used to
land in your faction's prices. **Ledger Link 0.2** notices when the AH you open is in one of those zones and keeps
Auctionator's price writes from that scan in its own book (`LedgerLinkDB.neutral`), which the build reads as the
Neutral AH (log: `price_log_neutral.tsv`). By default Auctionator's own book doesn't get them, so tooltips, Make or
Buy and net worth stay on faction prices. `/ledger neutral both` sends them to both; `/ledger neutral off` stops.

Days from before that went into Auctionator's book: list them in `data/neutral_days.txt` (one `YYYY-MM-DD` per line)
and the build moves them to the Neutral side. A Neutral-only day stands out by its listings: 13 Nov 2026 had about
180k against 1 to 2.4M on other days.

### Live (second-monitor mode)

`serve.bat` (or `wowstats live`) starts a small local server (Python, standard library only, listening on
`127.0.0.1:8737` only) and opens the page from it. Then:

- **The page refreshes itself** whenever WoW writes SavedVariables (every `/reload` and logout): the server reruns
  `build.lua` and the open page reloads, keeping your view, tab and scroll position.
- **A Live tab** reads the combat log while you play. WoW switches the log off at every logout: the **Ledger Link**
  addon switches it back on at login (or type `/combatlog`). WoW Forever writes the file on a **fixed 5-minute
  timer**, so the Live tab is up to 5 minutes behind; it shows a countdown to the next write. Nothing an addon can do
  writes it sooner (`LoggingCombat(false/true)`, `/combatlog` and `/reload` were all tested, 8 Nov 2026). It shows:
  - **XP to level**, estimated between saves: Haul's XP at your last save plus, for each kill since, the XP that
    creature gave you last time (Logbook). Quest XP shows after the next /reload. **Kills to level** divides
    what's left by the XP of what you farmed in the last 30 minutes.
  - your zone and position on the **real zone map** (Wowhead's classic map art, downloaded once per zone into
    `data/maps/` by the server; `zones.py` maps uiMapIDs to Wowhead zones and holds the alignment). The line is this
    session, the faint dots are your earlier visits (Logbook's trail). Hover a dot for who it is; "Zoom to you"
    zooms in.
  - creature names link to Wowhead (npc id from the combat log), and player names link to the WoW Forever armory
    (`PLAYER_URL` in `template.html`).
  - fights with damage per second, damage taken and lowest health
  - kills by creature, damage and healing by spell
  - your deaths and what hit you last
  - other players within combat-log range (about 50 yards), with enemies flagged
  - your newest screenshot

Stop it with `wowstats stop`. Its messages go to `data\server.log`. Notes:

- The combat log's level field holds a player's **item level**, not their character level, so the Live tab shows
  "Item lvl".
- `/chatlog` doesn't work on WoW Forever: it creates `Logs/WoWChatLog.txt` and never writes to it (tested 8 Nov 2026).
- WoW keeps every combat log file; delete old `Logs/WoWCombatLog-*.txt` files now and then.

Run it again whenever you want fresh numbers. With several characters, the picker above the menu switches between
them; **Characters** (under `~/account`) shows every alt side by side (level, class, played, gold, items, net worth, last played),
net worth and played time per character, and everything you own across all of them with who holds it. Alts that
only appear in Logbook's account file or in Stockpile are listed too (marked "no log" until they have a detailed
history). The page remembers which view you had open.

Also on the page:

- **Damage** (Combat & quests): damage per second and your best, damage by spell (your pet's included), what hurts
  you, and damage, damage taken and healing per fight at each level. A death whose killing blow the damage meter
  saw names that attacker and spell, marked *confirmed*; without it, the killer is your last hostile target.
- **Flights** (Progress): every route you've flown with its usual fare and time in the air, the stops on the way,
  and your recent flights. A route with a stop is counted apart from the direct one, since the fares differ.
- **Replay** (each character): pick a play session and watch it on the zone map. Your path draws itself from
  Logbook's trail (a point every 5 seconds while you move), and level-ups, deaths, quests, zones, dungeons,
  flights, gathering, rare loot, AH sales and kills appear where they happened. The moments list beside it jumps
  the playhead to any of them; scrub, zoom and pan the map. Stands over 20 seconds play as 20 seconds. Map art is
  the live server's cache of each zone (`data/maps`), or Wowhead's CDN for a zone it hasn't fetched yet.
- **Play sessions** (each character): a diary of every session, newest first: time, XP and levels, gold earned and
  spent, kills, quests, deaths, zones, profession gains, loot, what you made, and Auction House buys & sales. The log starts a new piece at
  every reload; pieces less than 30 minutes apart are one session.
- **Best crafts at saved prices** (each character): click any craft row to inspect its full reagent tree (with unit
  prices, line totals, and sub-craft savings), gross vs net AH sale (after the 5% cut), profit margin, and `1×` / `5×`
  / `10×` batch scaling.
- **Auction house trades** (each character): reconstructs your AH ledger from the log's `ah`, `ma` (mail invoices)
  and `mn` (money) events — showing total earned, spent on buyouts/bids, posting deposits, net AH balance, chronological
  trades (with buyer/seller names and unit prices), and a **By item** summary (bought, avg buy, sold, avg sell, deposits
  and net per item).
- **Market: buy low, sell high** (All characters): items selling 30% or more under their usual price, and items you
  own at 25% or more over it. Usual = the median of the lowest price on each earlier scan day, as Make or Buy's own
  price check does. It needs 3 days of Auctionator scans; until then it says how many you have.
- **Mail to your alts** (All characters): items one character holds that another crafts with or needs for its
  restock list. The in-game version is Make or Buy's "For your alts" list at the mailbox.
- **Drop rates from your kills** (All characters): from the DropLab addon. Mobs with 5+ kills first, by value per
  kill, with gold per hour at your pace and each drop's rate and likely range. Uses DropLab's own `Stats.lua`, so
  the numbers match the game. Drops are valued at the AH price after the 5% cut (vendor prices aren't saved outside
  the game). `*` = only corpses you opened were counted.
- **Sortable tables & live search**: click any table column header to sort ascending/descending, and filter your full
  character/account inventory, quests, drop tables, and market databases with the search boxes.

Charts load Chart.js from cdnjs, so they need an internet connection; everything else works offline. The page also
reads each of our addons' `.toc` from GitHub (at most every 6 hours) to say when an update is out; offline, the
Addons module still compares WoW's copy with yours. The Replay's map art comes from `data/maps` (the live server
downloads each zone once), or from Wowhead's image server for a zone that isn't there yet.

From any terminal: `wowstats` (or `wowstats -n` to build without opening the browser). Or directly:
`lua dashboard/build.lua [wow folder] [output file]` (defaults: `wow =` in `ledger.cfg`, `data/dashboard.html`).

## Where the numbers come from

| Section | Source |
| --- | --- |
| Leveling, XP sources, time per level, gold earned/spent, zones, professions, fights, quests, deaths | Logbook's event log and counters (per character) |
| Flight routes, fares and time in the air | Logbook's flight lines |
| Damage per second, damage by spell, what hurts you, killing blows | Logbook's readings of the game's damage meter (`C_DamageMeter`), from Logbook's first fight on |
| Gold on hand | Logbook (account file) |
| Inventory | Stockpile (bags, bank, mail) |
| Prices, price trends, net worth | Auctionator's price database (today's AH minimum; trend = lowest price per scan day) |
| Neutral AH prices | Ledger Link (account file), plus any days listed in `neutral_days.txt` |
| Best crafts | Make or Buy's saved recipes, priced by Make or Buy's own `Planner.lua` on Auctionator's prices |
| Restock list, Haul session | Make or Buy, Haul |
| Drop rates | DropLab (account file), with DropLab's `Stats.lua` |
| Item names | QuestieDB's item data, Haul's loot links, the log's loot lines, recipe names |

Notes:

- Time before Logbook was installed isn't known: the first level is marked `*` (partial).
- Zone time counts the time between logged events; gaps over 10 minutes and logouts count as offline.
- Money comes from the log's money lines (every change to your gold, by source), so quest gold is counted once.
  Logbook files an AH sale's gold under Auction house. History copied from MuddyBoots sometimes labels it "mail" (it arrives
  by mail); when an AH invoice of the same amount was logged within 5 seconds of it, it counts under Auction house.
  "Mail" is then gold from letters, e.g. from other players.
- Crafts use the AH price after the 5% cut. Vendor sell prices aren't saved outside the game, so the in-game tab can
  differ when the vendor price is higher.
- Items the AH has never seen are listed but not valued.

## Files

| File | Role |
| --- | --- |
| `dashboard/build.lua` | Finds characters under `WTF/Account`, loads each addon's file, writes the page |
| `dashboard/lib/util.lua` | Binary-safe SavedVariables loader, base64, JSON |
| `dashboard/lib/cbor.lua` | CBOR decoder (Auctionator's prices and QuestieDB's data are CBOR) |
| `dashboard/lib/sources.lua` | Readers for QuestieDB names, Auctionator and Ledger Link prices, log lines; joins Logbook's log with the history it copied from MuddyBoots |
| `dashboard/lib/model.lua` | Pure functions computing every figure on the page |
| `dashboard/lib/insights.lua` | Pure: market deals, session recaps, items to mail between characters, Faction vs Neutral |
| `dashboard/template.html` | The page; `build.lua` puts the data where `/*DATA*/null` is |
| `dashboard/server.py` | Live server: rebuilds on SavedVariables changes, follows the newest combat log, serves the page and screenshots |
| `dashboard/livelog.py` | Pure: turns combat-log lines into the Live module's picture (you, fights, kills, players around you) |
| `dashboard/zones.py` | uiMapID → Wowhead zone id, and where the map sits in Wowhead's image |
| `dashboard/build.bat`, `serve.bat` | Build and open the page; start `server.py` without a console window |
| `addons/` | Logbook, Ledger Link, Make or Buy, Stockpile, Haul, DropLab (each with its own README and tests) |
| `install.bat`, `install.ps1` | Copies (or with `-Dev`, links) the addons into WoW and writes `ledger.cfg` |
| `bin/wowstats.bat` | The `wowstats` command |
| `ledger.cfg` | Your paths (not tracked; see `ledger.cfg.example`) |
| `data/` | Not tracked: `dashboard.html`, `price_log.tsv`, `price_log_neutral.tsv`, `neutral_days.txt`, `maps/`, `server.log` |

## Tests

```
lua dashboard/tests/run.lua
python dashboard/tests/test_live.py
cd addons/<Addon> && lua tests/run.lua      # each addon has its own suite
```

The tests that run Make or Buy's and DropLab's own code find them through `wow =` in `ledger.cfg`.

RFC 8949 vectors for the CBOR decoder (each length and float size), base64 and JSON escaping, the 0x1A file case,
decision tables for money and zone time (boundary at the 10-minute gap, logouts), state-based tests for deaths and
levels, Make or Buy's real planner on the Woolen Bag case, and an end-to-end build from fixture SavedVariables.
