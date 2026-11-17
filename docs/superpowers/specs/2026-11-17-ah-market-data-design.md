# AH market data from the Battle.net API — design

Date: 2026-11-17. Status: draft for review.

## Why

The user plays the auction house as a mini-game. They want to see **trends** and **buy and sell windows** so they can
flip items and sell held materials at a good profit, and, near the end of leveling, see **what is worth farming**.
Today every market figure rests on in-game Auctionator scans: one lowest price and listing count per scan day, and
the Neutral (Blackwater) house is often days old. Blizzard's Game Data API now serves WoW: Forever auction house
snapshots, so a fetcher can record the market every hour, whether or not the user plays, and turn that into the
indicators TradeSkillMaster (TSM) is known for: market value, historical value, sale rate.

The user wants to see deals **on the dashboard** before logging in and **in game** while at the AH. No phone or
desktop alerts: they can only act while playing, and can't always log in fast.

The app may be shared with friends and published on GitHub later (each user with their own API client).

## Goals

- An hourly fetcher of the user's two houses (Horde, Neutral), keeping a history that supports hour-of-week patterns.
- Indicators: market value, historical value, sales per day, trend, best hour/weekday to buy and sell.
- Dashboard: flip deals (incl. Faction ↔ Neutral), sell windows for held items, trend charts, what to farm.
- In game: the same market values, sale rates and best-sell times, loaded at login; deals judged against the
  user's own fresh scan.
- A system tray icon showing whether the live server and the fetcher are running and healthy, with start/stop for
  each.
- Better logging for the server, fetcher and tray.

## Non-goals

- Notifications while away (phone, desktop toast).
- A hosted, shared fetcher (approach C below). The fetcher is written so it can move to one later, nothing more.
- Region-wide prices across the other Horde houses. Possible later via config; not built now.
- Prices for gear variants (bonus lists, suffixes): items are grouped by item ID, as the dashboard already does.

## Anti-goals (failure even if it works)

- Anything that automates AH actions in game (buying, posting, cancelling). The addon only shows information.
  Automation would break Blizzard's terms.
- Older API data overwriting a fresher in-game scan.
- The dashboard breaking, or losing any of today's figures, for a user without API credentials.
- The API secret appearing in a log, the page, a commit or the in-game file.

## Constraints and known facts

Probed 2026-11-16 with the user's client (see the scratch scripts in that session; facts repeated here):

- Token: `POST https://oauth.battle.net/token`, `grant_type=client_credentials`, HTTP Basic with client ID/secret.
- Host `https://us.api.blizzard.com`. Namespace `dynamic-forever-us` for rulesets and auctions, `static-forever-us`
  for items, `profile-forever-us` for characters. `locale=en_US`.
- `/data/wow/ruleset/index` → 1 PvP, 2 Normal, 3 Roleplay, 15 Roleplay PvP. The user's characters are Horde on
  ruleset 1 (PvP).
- `/data/wow/ruleset/1/auctions/` (trailing slash required) lists 15 houses: 110–121, 123–125. Every ruleset lists
  the same houses and returns the same data, so the ruleset in the path doesn't matter.
- `/data/wow/ruleset/1/auctions/{house}`: `{ auctions: [ { id, item: { id, ... }, quantity, buyout?, bid?,
  time_left } ] }`. `buyout` is for the whole stack. `auctions` can be missing (houses 112/115/118 are empty).
- `/data/wow/ruleset/1/auctions/{house}/commodities`: `{ auctions: [ { id, item: { id }, quantity, unit_price,
  time_left } ] }`.
- Busy houses: ~100–118k auctions plus ~85–97k commodity auctions, ~10 MB, ~2 s each. No `Last-Modified` header;
  the refresh cadence is unknown.
- **The user's Horde house is 113**: 69% of items had exactly the price of a same-day Auctionator scan (84% within
  5%); every other house was at most 5% exact.
- **Neutral is believed to be 116** (houses come in sets Alliance 110 / Horde 113 / Blackwater 116), **not verified**:
  Ledger Link had no Neutral prices to compare against. The builder adds a check (below).
- API rate limit: 36,000 requests per hour. Not a concern.
- The repo's Python is standard library only (`dashboard/server.py`, `livelog.py`, `zones.py`); the build is Lua 5.x
  (`dashboard/build.lua`, pure modules in `dashboard/lib/`); scripts are `.bat` and PowerShell (`install.ps1`).
  Keep it that way: no pip packages.
- WoW reads addon files only at login or `/reload`. An addon can't read arbitrary files.
- `data/` and `ledger.cfg` are git-ignored; everything generated goes there (or into the game folder).

## Approaches considered

- **A. Local Python fetcher with a SQLite history (chosen).** Standard-library Python, SQLite for hourly history,
  Python computes indicators and writes files the Lua build and the game read. Runs under the tray.
- **B. All in Lua inside `build.lua`.** Rejected: Lua here has no HTTPS or database; it would shell out to curl,
  parse 10 MB JSON in Lua, and tie fetching to builds.
- **C. A hosted fetcher shared with friends (e.g. GitHub Actions publishing to Releases/Pages).** No gaps while the
  PC is off, friends need no API account. Deferred: hosting, a public endpoint, a Service URL. The user chose A,
  written so that moving to C later means a workflow file plus a "download from URL" option, not a rewrite.

For the tray: **PowerShell** (`System.Windows.Forms.NotifyIcon`, built into Windows) was chosen over Python with
`pystray`/`Pillow` (first non-standard dependency, every friend would need pip) and over raw ctypes win32 code
(hard to maintain).

## Design

Built in three phases, each usable on its own.

### Several PCs

The user plays on more than one PC (the dashboard merges their saved files from `data/pcs/<name>/WTF`). **One PC
fetches**: the one that's on the most. Other PCs get the market data by copying that PC's `data/market.db` into
their own `data/` (the README explains it next to the WTF copy steps). There, `market.json` and `LedgerLink_Market`
are built from the copy, and the page and in-game UI show how old it is. Without a fetcher configured, the tray
shows the fetcher as "not set up". Merging several PCs' databases is not built.

### Phase 1: logging, fetcher and history, tray

#### Logging (`dashboard/ledgerlog.py`)

- One Python helper used by the server and the fetcher: `logging` with a `RotatingFileHandler`, ~1 MB per file,
  3 old copies, files in `data/`: `server.log`, `fetcher.log`. The tray writes `tray.log` in the same format with its
  own rotation.
- Line format: `2026-11-17 00:31:45 INFO server: message`. Levels INFO, WARNING, ERROR. Errors include the
  traceback.
- Logged: start and stop with the reason (tray, `wowstats stop`, crash); each build with its duration and warnings;
  each fetch per house (HTTP status, bytes, seconds, items, retries); token refreshes; combat-log files picked up;
  status changes. Page requests stay off.
- The secret is never logged (log the client ID's last 4 characters at most).
- `server.py`'s existing `log()` becomes a thin wrapper so existing call sites keep working.

#### Config (`ledger.cfg`, untracked; document in `ledger.cfg.example`)

```
bnet_id = ...
bnet_secret = ...
bnet_region = us
ah_ruleset = 1
ah_faction = 113
ah_neutral = 116
ah_every = 60          # minutes
```

No `bnet_id` → the fetcher doesn't start and the tray shows it as "not set up" (not an error).

#### Fetcher (`dashboard/fetcher.py`, pure parts in `dashboard/market_reduce.py` or similar)

Loop, every `ah_every` minutes:

1. Get a token (cached until a minute before it expires; refresh on 401).
2. For each configured house: GET auctions and commodities. Retry with backoff on errors and timeouts; a failed
   house doesn't stop the others.
3. **Skip duplicates**: if the set of auction IDs equals the previous snapshot's, Blizzard hasn't refreshed; record
   nothing for that house (log at INFO). This also teaches us the real refresh cadence from the log.
4. **Reduce** each snapshot to one row per item (both endpoints together):
   - `min`: lowest unit price (`unit_price`, or `buyout / quantity`; bid-only auctions don't count).
   - `market`: a TSM-style market value of this snapshot: sort all units by unit price, take the cheapest 15%;
     extend up to 30% while each next price is under 1.2× the previous one; average those. (Exact rules are the
     builder's; keep them in one pure function with tests.)
   - `units`, `listings`.
   - `sold`: estimated units sold since the previous snapshot. An auction that vanished whose previous `time_left`
     was longer than the gap between snapshots probably sold (or was cancelled; the two can't be told apart; note
     this on the page). A commodity auction whose quantity dropped counts the drop.
5. Write rows to SQLite, keep only the latest snapshot's auction IDs/time-left/quantity for the next comparison,
   write `data/fetcher_status.json` (`{ last_ok, last_try, next, error, houses: { id: { ok, t, items } } }`).
6. Raw downloads are discarded after reduction.

Data volume: ~10k items × 2 houses × 24 h ≈ 15 MB/day. **Rollup**: hourly rows older than 30 days fold into daily
rows (min of mins, average market, average units, sum of sold, hours seen). Steady state ≈ 0.5 GB.

#### Store (`data/market.db`)

Tables (the builder may adjust names and indexes):

- `snapshot(house, t, items, auctions)`: one per recorded snapshot.
- `hourly(house, t, item, min, market, units, listings, sold)`.
- `daily(house, day, item, min, market, units, sold, hours)`.
- `last_auctions(house, auction_id, item, quantity, time_left)`: the previous snapshot, for sales.

`t` is the fetch time (epoch seconds), since the API gives no snapshot time. Days are local calendar days.

#### Tray (`dashboard/tray.ps1`, started hidden)

- `wowstats live` starts the tray (single instance via a named mutex); the tray starts the live server and the
  fetcher as child processes (`pythonw`, no console).
- Icon: **green** both running and last fetch under ~1.5× `ah_every` old; **amber** one stopped, fetch failed, or
  overdue; **grey** both stopped. Tooltip: `Live: on · AH: last fetch 14:05, next 15:05`.
- Menu: Open dashboard · Live server ▸ Start / Stop · AH fetcher ▸ Start / Stop / Fetch now · Open logs folder ·
  Start with Windows (toggles a shortcut in the Startup folder) · Quit (stops both).
- Health: the server gets a `GET /status` endpoint (uptime, last build time and result); the fetcher's health is
  `data/fetcher_status.json`. Amber/red tooltips name the cause (the log line).
- "Fetch now": the tray signals the fetcher (e.g. a `data/fetch_now` flag file it checks every few seconds, or a
  local port; builder's call).
- `wowstats stop` stops the tray and both children; the existing `/stop` endpoint keeps working.
- **Gaps**: hours when the PC is off or the fetcher is stopped are simply missing; every indicator must tolerate
  gaps.

**Neutral check** (phase 1): after the next in-game Neutral scan (Ledger Link's book), compare it with every
Blackwater house the same way house 113 was found and log/report which matches; if it isn't 116, the user updates
`ah_neutral`. A small command (`python dashboard/fetcher.py --match`) is enough.

### Phase 2: indicators and the dashboard

#### Market engine (`dashboard/market.py`, pure functions with tests)

Reads `market.db`, writes `data/market.json` for `build.lua`. It runs before every build (`wowstats`, the live
server's rebuilds) and after each fetch, on any PC that has a `market.db`, so a PC with a copied database works
the same as the fetching one. Per house, per item:

- `now`, `nowAt`: latest API `min` and its time.
- `market`: weighted average of hourly `market` over 14 days, recent days weighted more (TSM's DBMarket idea).
- `historical`: average over 60 days (daily rows).
- `units`: listed now. `soldPerDay`: average estimated sales per day over 14 days.
- `trend`: change over 7 days (direction and percent).
- `week`: hour-of-week profile (168 buckets or a coarser grid such as 7 days × 6 four-hour blocks: builder's call),
  price relative to the item's market value, only when there are at least two weeks of data. Gives "best time to sell
  / buy".

Items with too little data say so instead of guessing.

#### Merging with in-game scans (in `build.lua` / `sources.lua`)

- Without `market.json` (or for an item it lacks), everything works exactly as today.
- **`now`**: whichever observation is newer, per item, the in-game scan or the API snapshot.
  - Auctionator's faction book stores only the scan day (`{ l, h, a, m }` per day; no time). An item whose latest
    in-game day is today is stamped with the **last faction AH visit of that day** from Ledger Link
    (`LedgerLinkDB.visits`, `{ t, kind, zone }`). Older in-game days are stamped at the end of their day.
  - Ledger Link's Neutral book already has a time per item (`t` → `seenAt`); use it.
  - Example: in-game scan at 01:00, API snapshot at 15:00 the same day → the API price wins; scan again at 16:00 →
    the in-game price wins until the next snapshot.
  - The file's save time and the build time are not used: they can be hours after the scan.
- **Market value, sale rate, trend, week profile**: from the API (the in-game book has one low per day, not enough).
- Net worth and held items are valued at **market value** where known, else at `now` (market value is steadier
  than one lowest listing). **Net worth history** (`networth_log.tsv`) switches to market value from the day this
  ships; earlier points can't be recalculated (the log keeps totals, not holdings), so the chart marks the switch
  ("valued at market from here") and keeps the older points as they are. The forecast uses points after the
  switch once there are enough, else all points.
- Crafts: buying reagents at `now`, selling at market value.
- `price_log.tsv` keeps recording in-game scans as today; API data lives only in `market.db`.

#### Dashboard (in `template.html`)

- **Deals (flip)**: items at or under a threshold of market value with enough sales per day, showing discount,
  sold per day, units listed, and profit per item after the 5% cut if relisted at market value. Ranked by expected
  profit (profit per item × what the market absorbs). Replaces today's buy signals.
- **Faction ↔ Neutral flips**: today's comparison, now with hourly Neutral data and the 15% Neutral cut.
- **Sell windows**: held items priced above market value that are selling, total extra gold, who holds them, and
  whether now is a good hour of the week. Replaces today's sell signals.
- **Trends**: hourly price charts with the "best time to sell / buy" strip.
- **What to farm**: value per hour from DropLab and Haul history (mobs and nodes already farmed), priced at market
  value and capped by sales per day ("the market takes ~N a day").
- Thresholds start from today's `I.MARKET` values; the builder may tune them.

### Phase 3: in game

- The market engine also writes a generated addon in the game's AddOns folder, **`LedgerLink_Market`**
  (`LedgerLink_Market.toc` + `MarketData.lua`), not into SavedVariables (the game overwrites SavedVariables at
  logout) and not into the repo's `addons/LedgerLink` (with `install.ps1 -Dev` that folder is a link to the repo).
  This is how TSM's desktop app does it. Contents: per item for both houses, market value, historical value, sales
  per day, trend, best hours to sell; plus when it was written.
- Ledger Link reads it as an optional dependency and exposes it to the other addons:
  - **Tooltips**: market value, sales per day, "good time to sell" when the current hour of the week is high.
  - **Make or Buy**: values crafts at market value instead of the lowest listing when available.
  - **Deals list** at the AH after a scan: what to buy to flip and what to post, judged by the fresh scan's prices
    against the file's market values. Information only (see anti-goals).
- The file is as old as the last login or `/reload`; the in-game UI shows its age.
- Respect `forever-client-api` rules for any game API used (retail names first, pcall, secret values).

## Left to the builder

- Exact market value, trend and week-profile formulas, thresholds, minimum-data rules (in pure tested functions).
- Table schemas, indexes, rollup timing, the "fetch now" signal.
- Page layout of the new sections, within the existing template's style.
- Size of `MarketData.lua` (trim to items seen in the last 30 days if needed) and the tooltip wording.
- Tests: Lua tests in `dashboard/tests/run.lua`, Python tests next to `test_live.py`, addon tests in each addon's
  `tests/`.
