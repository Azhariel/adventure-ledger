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
| Make or Buy | Your recipes and what to craft or buy (Crafting, skill-ups, restock list, mail to alts) |
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
- **Level 60**: a power law (hours per level against level, on log scales) fitted to your finished levels, turned
  into a date by spreading those hours over your played time per day in the last 14 days.

### Market

Works from the file too (no server needed). From Auctionator's price database (one lowest and highest buyout and
the number listed per item per scan day) plus the dashboard's own price log, `price_log.tsv`: every build adds a line
for each item whose price changed, so each /reload after an AH scan is another point on the chart.

- **Faction / Neutral switch** (top right on Signals, Stockpile, Browse and Movers) picks which house's prices
  those modules use. The **item drawer** (click any row) draws both houses on one chart, with the forecast for
  the house in view and a separate chart of how many were listed.
- **Signals**: your stockpile's value per scan day with its forecast, your best sellers, buy low / sell high (with
  who holds each item worth selling, and how many in their bags, bank and mail). Click any row for its price history.
  With API data, buy low / sell high become two lists per house on the API's market value (items the API has no
  market value for keep the old scan-based rows, marked *scans*):
  - **Deals**: items priced 50% or more under their market value that sell 5 or more a day. Profit each is what
    one makes relisted at market value after the house's cut (5% Faction, 15% Neutral), at least 50c; per day is
    that times what the market takes a day, capped by how many are listed within 10% of the lowest price (Listed
    shows that count against all listed). The best 25, by profit per day. A deal with a single unit near its
    lowest price counts one unit a day and says *one cheap listing* next to its name. Until the fetcher has
    counted an item (snapshots from before this count), an item 90% or more under market is taken to be one
    stray listing and says *one cheap listing?*. The house pill shows how old the API snapshot is.
  - **Sell windows**: things any of your characters hold, priced 25% or more over market value at the house they'd
    sell at and still selling (1 or more a day) and at least 50c above it each, with the extra
    gold over market value, who holds them, and whether
    this hour of the week usually prices the item (or its family) well.
- **Stockpile** (all characters): now, launch low (lowest daily low), change against it, peak (highest daily
  low), supply (listed now vs the first scan day; fewer = green), trend, value, and a signal: *selling window*
  (2x the launch low or more and fewer listed), *rising* (+50%), *still cheap* (within 15% of the low).
- **Browse**: the full price database, or one trade-goods family (id lists in `dashboard/lib/insights.lua`, `I.FAMILIES`).
- **Movers**: rising fastest (+50% over a launch low of 10c or more, 20+ listed), fallen furthest (30% under peak).
  With API data, an item selling 2 or more a day is judged by the API alone: rising at +25% market value over 7
  days, fallen at -20%, or a *new price level* (most of the last 48 hours beyond its old market value, with sales),
  which comes first in either list. Items the API sells fewer than 2 a day are left out; items the API has no
  trend for yet keep the launch low and peak rules. Each row says
  which rule put it there, with sold a day and how many are listed; 30 rows per list.
- **Faction vs Neutral**: items priced at both houses, the gap, and what a flip makes after each house's cut (15%
  at Neutral, 5% at Faction). By default only items with 5+ listed at both, since one stray listing sets the price
  in a thin market. With API data each side's price is the newer of your last scan and the API's latest snapshot,
  marked *API* or *scan* (hover for when), and the table adds both houses' sales a day. The 25 best flips with 5+
  listed at both houses go on the engine's wanted list (`market_wanted.tsv`), like the top 25 deals, so their
  price lines stay detailed.
- **Your trades** and **Crafting** (the picked character): the AH ledger, and every craft at saved prices with
  what you'd pay after using what you hold, whether it will sell, and the cheapest skill-up route.
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

### Auction house data from the Battle.net API

Optional. Auctionator only knows the prices you scanned. The AH fetcher asks Blizzard's API for every listing at
your faction's house and the Neutral one each time Blizzard makes a new snapshot (about hourly; it checks every
10 minutes and downloads only when there's something new), and keeps per-item prices in `data/market.db`. Nothing in
the game is automated: it only reads the API.

1. Create your own API client at [develop.battle.net](https://develop.battle.net): log in with your Battle.net
   account and create a client (any name). Each person needs their own: never share or commit its ID and secret.
2. Add them to `ledger.cfg` (see `ledger.cfg.example`):

   | Key | What it is |
   | --- | --- |
   | `bnet_id`, `bnet_secret` | Your client's ID and secret |
   | `bnet_region` | `us` (default) |
   | `ah_houses` | The houses to fetch, e.g. `PvP 113, PvP 116`: ruleset name, then house id, comma-separated. The side follows from the id. `113` (Horde) and `116` (Neutral) matched on PvP; `--match` finds yours. The old `ah_ruleset`, `ah_faction` and `ah_neutral` still work when this is unset |
   | `ah_every` | Minutes between checks for a new snapshot, `10` by default |
   | `ah_reset` | The weekly reset, day and hour on your clock: `Tue 12`, `tuesday 12:00` (whole hours only; other minutes get a warning and the default). Default: Tuesday at the local hour of 15:00 UTC, the US reset. Set it if Forever resets at another time |

3. Run `wowstats live`. The tray starts the fetcher with the server.

To check the Neutral house, scan a goblin AH (Booty Bay, Gadgetzan, Everlook, or Forever's one just outside the
Crossroads in the Barrens), `/reload`, and run `python dashboard/fetcher.py --match neutral`. It compares Ledger
Link's Neutral prices with every Neutral house and says which one matches; if it isn't `116`, put the house it
names into `ah_houses` as `<ruleset> <id>` (or set `ah_neutral` if you still use the old keys). `--match faction`
does the same for your faction's house against Auctionator's latest scan day.

**The tray icon.** `wowstats live` puts a dot in the notification area. It runs the live server and the fetcher and
watches both every 5 seconds:

- **green**: both running, and the last fetch is less than 1.5 times `ah_every` old
- **amber**: one of them stopped, the last fetch failed, or a fetch is overdue
- **grey**: both stopped

Hover it for the details (`Live: on · AH: last fetch 14:05, next 15:05`); when it's amber the tooltip names the
cause. Without `bnet_id` the fetcher is "not set up", which never turns the dot amber. Right-click for the menu:
Open dashboard, Live server (Start, Stop), AH fetcher (Start, Stop, Fetch now), Open logs folder, Start with Windows
(a shortcut in your Startup folder), Quit (stops both). `wowstats stop` stops the tray, the server and the fetcher.
The logs are `server.log`, `fetcher.log` and `tray.log` in the data folder.

**Other PCs.** Only one PC needs to fetch: the one that's on the most. To use the data elsewhere, copy that PC's
`data/market.db` into the other PC's `data/` now and then (like the WTF copies below). Copy it while the fetcher is
stopped (tray > AH fetcher > Stop, then Start again after): the database keeps recent writes in a side file
(`market.db-wal`) while it runs, so a copy taken then can be incomplete. Hours when the fetching PC is off are simply
missing. Two databases are not merged: the copy replaces the old one.

**Trends tab.** With API data, the Market area gets a Trends tab: pick a house, then Whole house or a family of
trade goods, or search for an item. The family's price grid sits beside the house's sold grid (Whole house shows
listings beside sold), with a "Right now" table and how old the data is. Grids run Monday first in your local time:
pink is cheaper than usual, green pricier, blue is volume, blank means not enough data, and the reset hour is
outlined. A family grid pools its members' prices and fills in after about a week; an item's own grid needs about
two weeks.

**Item drawer.** Click an item row in Signals, Stockpile, Browse, Movers, Faction vs Neutral, Your trades or Trends
to open it in a panel at the side. It has a 14 days / 60 days / everything switch (everything needs the live
server), and its "Your scans" section holds the scan chart, listed bars and forecast the old item inspector had.
The live server serves `GET /history?house=<id>&item=<id>` (localhost only, read-only): hourly rows for about 30
days and daily rows for all time, straight from `market.db`.

Each build writes `data/market_wanted.tsv`: the page lists the items it needs (family members, items you hold,
items you've traded). `wowstats` then runs the engine again and rebuilds when the list changed what it wrote (the
live server reruns it within a poll). Detailed price lines are capped at 400 items per house; other items show
their numbers, and their history comes from the live server. To keep the page small, hourly prices are embedded
only for the 60 best-selling items you hold; for the rest the 14-day view draws daily prices in the file and
hourly ones from the live server.

### Live (second-monitor mode)

`wowstats live` starts the tray icon (above), which starts a small local server (Python, standard library only,
listening on `127.0.0.1:8737` only) and opens the page from it. `serve.bat` still starts the server alone. Then:

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
- **When you play** (Overview): time logged in as a weekday by hour grid on your own clock, with each weekday's total.
- **How it adds up** (Gold): gold when tracking began, plus earned, minus spent, against gold on hand. Each level-up
  saves your gold, so the starting gold is worked out from the first one, and money that changed without a log line
  is shown with the levels it happened between.
- **Net worth over time** (Gold): Stockpile only knows what you hold now, so every build appends gold and item value
  to `data/networth_log.tsv` when either changed; the chart draws that log, with gold on hand from each level-up for
  the time before it.
- **Gold per hour by activity** (Gold): Haul's sessions of 10 minutes or more, each labelled by what Logbook saw in
  it: gathering (5+ nodes, no fewer than kills), questing (quest XP at least kill XP) or grinding (kill XP ahead).
  Gold is Haul's coin, quest money and loot value over its active time. Under an hour of sessions is marked as little data.
- **Crafts at saved prices** (each character): every recipe with all its reagents priced. **You pay** is the cash one
  craft still needs once what the character holds is used (Make or Buy's `Expand`). **Will it sell** gives how many
  were listed at the last scan, on how many scan days, Make or Buy's price warnings (spike, few listed, old price) and
  your own sales. Click any craft row to inspect its full reagent tree (with unit prices, line totals, and sub-craft
  savings), gross vs net AH sale (after the 5% cut), profit margin, and `1×` / `5×` / `10×` batch scaling.
- **Skill-ups** (Crafting): Make or Buy's own `Skill.Route` on your known recipes, from your skill to the cap: each
  stretch's craft, crafts needed, cash and cost after selling the result, and the cheapest next point. Thresholds come
  from Make or Buy's recipe data and the colours it saw in game.
- **Auction house trades** (each character): reconstructs your AH ledger from the log's `ah`, `ma` (mail invoices)
  and `mn` (money) events — showing total earned, spent on buyouts/bids, posting deposits, net AH balance, chronological
  trades (with buyer/seller names and unit prices), and a **By item** summary (bought, avg buy, sold, avg sell, deposits
  and net per item).
- **Market: buy low, sell high** (All characters): items selling 30% or more under their usual price, and items you
  own at 25% or more over it. Usual = the median of the lowest price on each earlier scan day, as Make or Buy's own
  price check does. It needs 3 days of Auctionator scans; until then it says how many you have.
- **Mail to your alts** (All characters): a mail list you build on purpose. On Crafting, pick a recipe and a batch
  size and press **Add to mail list**; the list shows what each craft still needs after what the crafter holds
  (an intermediate it lacks is asked for as its own reagents), and which of your other characters of the same faction
  holds it, in bags, bank or mail. It's saved in your browser. Below it: what a Make or Buy restock list needs from
  another character. Make or Buy's "For your alts" list at the mailbox also suggests every reagent an alt's recipes
  use; the page leaves those guesses out.
- **Drop rates from your kills** (All characters): from the DropLab addon. Mobs with 5+ kills first, by value per
  kill, with gold per hour at your pace and each drop's rate and likely range. Uses DropLab's own `Stats.lua`, so
  the numbers match the game. Drops are valued at the AH price after the 5% cut (vendor prices aren't saved outside
  the game). `*` = only corpses you opened were counted.
- **Sortable tables & live search**: click any table column header to sort ascending/descending, and filter your full
  character/account inventory, quests, mobs, deaths, drop tables, and market databases with the search boxes. Most
  fought, Quests and Deaths have a **Show all** link that lets the table run its full length.

Charts load Chart.js from cdnjs, so they need an internet connection; everything else works offline. The page also
reads each of our addons' `.toc` from GitHub (at most every 6 hours) to say when an update is out; offline, the
Addons module still compares WoW's copy with yours. The Replay's map art comes from `data/maps` (the live server
downloads each zone once), or from Wowhead's image server for a zone that isn't there yet.

From any terminal: `wowstats` (or `wowstats -n` to build without opening the browser). Or directly:
`lua dashboard/build.lua [wow folder] [output file]` (defaults: `wow =` in `ledger.cfg`, `data/dashboard.html`).

## Playing on more than one PC

Each PC's WoW saves only the sessions played on it, so play elsewhere shows up as a hole: the Overview's Play
sessions lists "play this computer never logged", and Gold's How it adds up points at it. To add another PC:

1. Install the addons there too (`install.bat` on that PC, or copy the `addons` folders into its
   `Interface\AddOns`). Without them nothing is recorded there.
2. Now and then, copy that PC's `_forever_\WTF` folder into `data\pcs\<any name>\WTF` here (a copy of the WTF
   folder itself, holding `Account`, works too). Copy it after logging out there, so its files are written.
3. Run `wowstats`. The build merges every folder under `data\pcs` with this PC's files.

How it merges, per character: Logbook's log lines from every PC in time order (a line in two copies once),
every session piece, counters added up (records such as the longest fight: the highest), each level's
snapshot, the trail; MuddyBoots' older history once. Haul sessions, Make or Buy's recipes (each profession's
skill from the PC where it's highest) and Auctionator's scan days are combined; Stockpile's contents and the
account row (gold, level) come from the PC where the character was seen last. DropLab and Ledger Link's Neutral
visits are read from this PC only.

Copy the other PC's files here, not this PC's files onto the other: two copies of the same file share their log
(that's caught) and their counters (that isn't: they'd count twice). The build warns when two copies share lines.

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
| Crafts, skill-ups | Make or Buy's saved recipes, skill and recipe colours, priced and routed by Make or Buy's own `Planner.lua`, `Market.lua` and `Skill.lua` on Auctionator's prices |
| Net worth over time | The dashboard's own `networth_log.tsv` (one line per build where gold or items changed) |
| Gold per hour by activity | Haul's session history, labelled by Logbook's event log |
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
| `dashboard/lib/merge.lua` | Pure: merges each character's and account's saved files from several PCs (`data/pcs`) |
| `dashboard/lib/trends.lua` | Pure: hour-of-week grids, families, the weekly reset (`ah_reset`) and best buy and sell hours |
| `dashboard/lib/insights.lua` | Pure: market deals, session recaps, items to mail between characters, Faction vs Neutral |
| `dashboard/lib/signals.lua` | Pure: Deals, Sell windows, Rising and Fallen on the API's numbers, and the flips worth keeping in detail; every threshold in one table, `Sg.C` |
| `dashboard/template.html` | The page; `build.lua` puts the data where `/*DATA*/null` is |
| `dashboard/server.py` | Live server: rebuilds on SavedVariables changes, follows the newest combat log, serves the page and screenshots |
| `dashboard/livelog.py` | Pure: turns combat-log lines into the Live module's picture (you, fights, kills, players around you) |
| `dashboard/zones.py` | uiMapID → Wowhead zone id, and where the map sits in Wowhead's image |
| `dashboard/build.bat`, `serve.bat` | Build and open the page; start `server.py` without a console window |
| `dashboard/tray.ps1`, `tray.bat` | The tray icon: starts and watches the live server and the AH fetcher (`tray.bat` starts it hidden) |
| `dashboard/fetcher.py` | Hourly AH fetcher: Battle.net prices into `market.db`, status in `fetcher_status.json`; `--match` finds your houses |
| `dashboard/bnet.py` | Battle.net API client (token, auctions and commodities, retries) |
| `dashboard/market_reduce.py` | Pure: one price row per item from a snapshot, and estimated sales between two snapshots |
| `dashboard/market_store.py` | SQLite store for the hourly rows; folds hours older than 30 days into days |
| `dashboard/ledgerlog.py` | Dated, rotating logs for the server and the fetcher |
| `dashboard/dump_prices.lua` | Prints the prices saved in game, for `fetcher.py --match` |
| `addons/` | Logbook, Ledger Link, Make or Buy, Stockpile, Haul, DropLab (each with its own README and tests) |
| `install.bat`, `install.ps1` | Copies (or with `-Dev`, links) the addons into WoW and writes `ledger.cfg` |
| `bin/wowstats.bat` | The `wowstats` command |
| `ledger.cfg` | Your paths (not tracked; see `ledger.cfg.example`) |
| `data/` | Not tracked: `dashboard.html`, `price_log.tsv`, `price_log_neutral.tsv`, `networth_log.tsv`, `neutral_days.txt`, `maps/`, `pcs/` (other PCs' WTF copies), `market.db`, `market.lua`, `market_wanted.tsv`, `fetcher_status.json`, `server.log`, `fetcher.log`, `tray.log` |

## Tests

```
lua dashboard/tests/run.lua
python dashboard/tests/test_live.py
python dashboard/tests/test_tray.py      # also test_bnet, test_fetcher, test_ledgerlog, test_market_*
cd addons/<Addon> && lua tests/run.lua      # each addon has its own suite
```

The tests that run Make or Buy's and DropLab's own code find them through `wow =` in `ledger.cfg`.

RFC 8949 vectors for the CBOR decoder (each length and float size), base64 and JSON escaping, the 0x1A file case,
decision tables for money and zone time (boundary at the 10-minute gap, logouts), state-based tests for deaths and
levels, Make or Buy's real planner on the Woolen Bag case, and an end-to-end build from fixture SavedVariables.
