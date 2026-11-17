# AH Market Data, Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An hourly fetcher records houses 113 (Horde) and 116 (Neutral) from the Battle.net API into
`data/market.db`, with shared rotating logs, a `/status` endpoint on the live server, and a PowerShell tray icon that
starts, stops and shows the health of both.

**Architecture:** Standard-library Python modules in `dashboard/`: `ledgerlog.py` (logging), `bnet.py` (token +
GET with retries), `market_reduce.py` (pure: snapshot → per-item rows, sales estimate), `market_store.py` (SQLite),
`fetcher.py` (loop, status file, `--once`, `--match`). `tray.ps1` owns both processes. `wowstats live` starts the tray.

**Tech Stack:** Python 3.11 standard library (`urllib`, `sqlite3`, `logging`, `json`, `unittest`), Lua 5.x (one dump
script), PowerShell 5+ with `System.Windows.Forms`.

**Spec:** `docs/superpowers/specs/2026-11-17-ah-market-data-design.md` (Phase 1 and "Several PCs").

## Global Constraints

- Python: standard library only, no pip packages. Lua: the repo's `dashboard/lib` modules only.
- Config keys in `ledger.cfg` (untracked): `bnet_id`, `bnet_secret`, `bnet_region = us`, `ah_ruleset = 1`,
  `ah_faction = 113`, `ah_neutral = 116`, `ah_every = 60` (minutes). Read with `server.read_config`'s format.
- Token: `POST https://oauth.battle.net/token`, `grant_type=client_credentials`, HTTP Basic.
- Endpoints on `https://{region}.api.blizzard.com`, `namespace=dynamic-forever-{region}`, `locale=en_US`:
  `/data/wow/ruleset/{ruleset}/auctions/{house}` and `/data/wow/ruleset/{ruleset}/auctions/{house}/commodities`.
  `auctions` may be missing (= empty). `buyout` is per stack; commodities use `unit_price`.
- The secret never appears in logs, status files, the page or commits. Log at most the client ID's last 4 chars.
- Log line format: `2026-11-17 00:31:45 INFO server: message`. Files in the data folder: `server.log`,
  `fetcher.log`, `tray.log`; rotate at 1,000,000 bytes, keep 3 old copies.
- Status file `data/fetcher_status.json`: `{ "last_ok", "last_try", "next", "error", "houses": { "113": { "ok",
  "t", "items" } } }` (epoch seconds; `error` null or a message).
- Tray colours: green = both running and `now - last_ok < 1.5 × ah_every`; amber = one stopped, fetch error, or
  overdue; grey = both stopped. No `bnet_id` → fetcher "not set up", which counts as neither running nor amber.
- Hourly rows fold into daily rows after 30 days.
- No AH automation of any kind. Commits: Conventional Commits, atomic, no co-author trailer, never push.

## Review Focus

- The token request fails (bad secret, network): the log and status say why, and never contain the secret →
  test in Task 2.
- `ledger.cfg` has no `bnet_id`: `fetcher.py` exits 0 after logging "not set up", the tray shows it grey/"not set
  up", not amber → tests in Tasks 5 and 7.
- One house times out or returns 5xx: the other house is still recorded, the failed one retried with backoff, the
  loop keeps going, status names the error → test in Task 5.
- The PC sleeps for hours: on wake the fetcher runs once (no catch-up burst), and the gap is just missing rows →
  test in Task 5 (`next_run` after a long gap).
- The fetcher started twice (tray plus a manual run): the second exits with "already running" → test in Task 5
  (lock file).

---

### Task 1: Shared rotating logs

**Files:**
- Create: `dashboard/ledgerlog.py`
- Modify: `dashboard/server.py:64-74` (`log()`), `dashboard/server.py:441-446` (remove the size-delete block),
  `main()` start/stop lines
- Test: `dashboard/tests/test_ledgerlog.py`

**Interfaces:**
- Produces: `ledgerlog.get(component: str, data_dir: str) -> logging.Logger` (idempotent per component; writes
  `<data_dir>/<component>.log` and to stdout when there is one).

- [ ] **Step 1: Write the failing tests** (`unittest`, temp dir)
  - `test_line_format`: after `get("server", d).info("built")`, the last line of `server.log` matches
    `^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d INFO server: built$`.
  - `test_error_has_traceback`: `log.exception("boom")` inside `except ValueError` writes `ERROR server: boom` and a
    later line containing `ValueError`.
  - `test_rotates`: with the handler's `maxBytes` patched to 200, writing 50 lines leaves `server.log` plus at most
    `server.log.1`–`server.log.3`.
  - `test_get_twice_one_handler`: `get` twice → the logger has exactly one file handler.
- [ ] **Step 2: Run** `python dashboard/tests/test_ledgerlog.py` → FAIL (`No module named 'ledgerlog'`).
- [ ] **Step 3: Implement `ledgerlog.get`** with `logging.handlers.RotatingFileHandler(maxBytes=1_000_000,
  backupCount=3, encoding="utf-8")`, formatter `"%(asctime)s %(levelname)s %(name)s: %(message)s"`, datefmt
  `"%Y-%m-%d %H:%M:%S"`. Add a stdout handler only when `sys.stdout` is not None (pythonw has none).
- [ ] **Step 4: Run** the test → PASS.
- [ ] **Step 5: Switch the server.** `log(msg)` becomes `_LOG.info(msg)` (`_LOG = ledgerlog.get("server", DATA)`);
  delete the "remove server.log over 1 MB" block; log `started (port, wow, pid)` and `stopped (reason)` where the
  reason is `stop endpoint` or `keyboard` or the exception text (wrap `serve_forever` in `try/except Exception` →
  `_LOG.exception`). Each build logs its duration in seconds next to the existing message; build warnings at
  WARNING.
- [ ] **Step 6: Verify** `python dashboard/tests/test_live.py` and `test_ledgerlog.py` pass; run
  `python dashboard/server.py --no-open`, wait for a line, stop with Ctrl+C; `data/server.log` ends with a dated
  `started` and `stopped (keyboard)`.
- [ ] **Step 7: Commit** `feat(dashboard): dated, levelled, rotating logs for the live server`

### Task 2: Battle.net client

**Files:**
- Create: `dashboard/bnet.py`
- Test: `dashboard/tests/test_bnet.py`

**Interfaces:**
- Produces:
  - `bnet.Config.from_cfg(cfg: dict) -> Config | None` (None without `bnet_id`/`bnet_secret`); fields `client_id,
    secret, region, ruleset:int, faction:int, neutral:int, every:int` (minutes), defaults from Global Constraints.
    `repr()` hides the secret.
  - `bnet.Client(config, opener=urllib.request.urlopen, sleep=time.sleep, now=time.time, log=None)`
  - `Client.get(path: str) -> dict` (adds namespace/locale, bearer token; 401 → one token refresh and retry; 429/5xx/
    timeout → retries at 5, 15, 45 s, then raises `bnet.ApiError(status, path)`).
  - `Client.house(house: int) -> tuple[list, list]` (auctions, commodities; missing `auctions` → `[]`).

- [ ] **Step 1: Write the failing tests** with a fake `opener` that records requests and returns canned responses
  (status + JSON bytes); `sleep` records delays.
  - `test_from_cfg_defaults`: `{"bnet_id": "abcd1234", "bnet_secret": "s3cret"}` → region `us`, ruleset 1,
    faction 113, neutral 116, every 60; `"s3cret" not in repr(config)`. No `bnet_id` → `None`.
  - `test_token_cached`: two `get` calls → one token request; with `now` advanced past `expires_in - 60` → a second.
  - `test_url`: `get("/data/wow/ruleset/1/auctions/113")` requested
    `https://us.api.blizzard.com/data/wow/ruleset/1/auctions/113?namespace=dynamic-forever-us&locale=en_US`.
  - `test_401_refreshes_once`: first GET 401, then 200 → two token requests, result returned.
  - `test_retries_then_raises`: GET returns 503 four times → `sleep` called with 5, 15, 45; `ApiError` raised.
  - `test_token_failure_hides_secret`: token endpoint 401 → `ApiError`; its message and anything passed to `log`
    don't contain `"s3cret"`.
  - `test_house_missing_auctions`: auctions body `{"id": 112}` and commodities `{}` → `([], [])`.
- [ ] **Step 2: Run** `python dashboard/tests/test_bnet.py` → FAIL.
- [ ] **Step 3: Implement** `Config`, `ApiError(Exception)` (`status`, `path`), `Client` per Interfaces; timeout 120 s
  per request.
- [ ] **Step 4: Run** the test → PASS.
- [ ] **Step 5: Add the keys to `ledger.cfg.example`** (commented, with a line saying how to create a client at
  develop.battle.net and that each user uses their own).
- [ ] **Step 6: Commit** `feat(dashboard): Battle.net API client for WoW Forever auction houses`

### Task 3: Reduce a snapshot to per-item rows

**Files:**
- Create: `dashboard/market_reduce.py`
- Test: `dashboard/tests/test_market_reduce.py`

**Interfaces:**
- Produces:
  - `market_value(prices: list[int]) -> int` (unit prices, one per unit, any order).
  - `reduce(auctions: list, commodities: list) -> dict[int, dict]`: `{item_id: {"min", "market", "units",
    "listings"}}`.
  - `snapshot_ids(auctions, commodities) -> dict[int, tuple]`: `{auction_id: (item_id, quantity, time_left)}`.
  - `estimate_sold(prev: dict, cur: dict, gap_seconds: int) -> dict[int, int]`: `{item_id: units}`.
  - `TIME_LEFT_MIN = {"SHORT": 0, "MEDIUM": 1800, "LONG": 7200, "VERY_LONG": 43200}` (seconds).

- [ ] **Step 1: Write the failing tests**
  - `test_market_uniform`: `market_value([100] * 20) == 100`.
  - `test_market_ignores_expensive_tail`: `market_value([5] * 3 + [50] * 17) == 5` (cheapest 15% of 20 = 3 units;
    the next is not under 1.2 × 5).
  - `test_market_extends_to_30pct`: `market_value([10] * 6 + [11] * 4 + [100] * 10) == 10` with 6 units taken
    (cheapest 15% = 3, then extend while < 1.2 × previous up to 30% = 6) → mean of six 10s.
  - `test_market_single`: `market_value([7]) == 7`.
  - `test_reduce_mixes_endpoints`: an auction `{id: 1, item: {id: 2589}, quantity: 4, buyout: 400}`, a bid-only
    `{id: 2, item: {id: 2589}, quantity: 1, bid: 50}`, and a commodity `{id: 3, item: {id: 2589}, quantity: 10,
    unit_price: 90}` → `min 90`, `units 15`, `listings 3`, `market 90` (14 priced units: 10×90, 4×100; the cheapest 4 are all 90).
  - `test_estimate_sold_long_vanished`: prev `{1: (2589, 5, "LONG")}`, cur `{}`, gap 3600 → `{2589: 5}`.
  - `test_estimate_sold_medium_vanished_not_counted`: prev `{1: (2589, 5, "MEDIUM")}`, gap 3600 → `{}` (it could
    have expired).
  - `test_estimate_sold_partial_commodity`: prev `{3: (2589, 10, "VERY_LONG")}`, cur `{3: (2589, 4, "VERY_LONG")}` →
    `{2589: 6}`.
- [ ] **Step 2: Run** `python dashboard/tests/test_market_reduce.py` → FAIL.
- [ ] **Step 3: Implement.** Unit price = `unit_price`, or `buyout // quantity`; bid-only auctions count in `units`
  and `listings` but not in prices. `market_value`:

```
sort prices; n = len; take = max(1, ceil(0.15 * n)); cap = max(take, floor(0.30 * n))
while take < cap and prices[take] < 1.2 * prices[take - 1]: take += 1
return round(mean(prices[:take]))
```

  Sold: an auction in `prev` missing from `cur` whose `TIME_LEFT_MIN[time_left] >= gap_seconds` counts all its
  quantity; one present in both with a lower quantity counts the drop.
- [ ] **Step 4: Run** the test → PASS.
- [ ] **Step 5: Commit** `feat(dashboard): reduce AH snapshots to per-item prices and estimated sales`

### Task 4: SQLite store with rollup

**Files:**
- Create: `dashboard/market_store.py`
- Test: `dashboard/tests/test_market_store.py`

**Interfaces:**
- Consumes: row dicts from Task 3.
- Produces: `Store(path: str)` with
  - `record(house: int, t: int, rows: dict[int, dict], sold: dict[int, int], ids: dict[int, tuple]) -> None`
    (one transaction: a `snapshot` row, `hourly` rows with `sold` (0 when absent), replace `last_auctions` for the
    house)
  - `last_ids(house) -> tuple[int | None, dict]` (previous snapshot time and its ids)
  - `rollup(now: int, keep_days: int = 30) -> int` (hourly rows older than `now - keep_days*86400` → `daily`, by
    local calendar day; returns rows folded)
  - `close()`
- Schema (create if missing): `snapshot(house, t, items, auctions)`, `hourly(house, t, item, min, market, units,
  listings, sold)` with index `(house, item, t)`, `daily(house, day TEXT 'YYYY-MM-DD', item, min, market, units,
  sold, hours)` primary key `(house, day, item)`, `last_auctions(house, auction_id, item, quantity, time_left)`.
  `PRAGMA journal_mode=WAL` so a reader on another process doesn't block the fetcher.

- [ ] **Step 1: Write the failing tests** (temp file DB)
  - `test_record_and_last_ids`: record house 113 at t=1000 → `last_ids(113) == (1000, ids)`; `last_ids(116) ==
    (None, {})`.
  - `test_record_replaces_last_auctions`: a second record at 4600 → `last_ids` returns only the second set.
  - `test_rollup_folds_old_hours`: two hourly rows for item 2589 on one day 40 days ago (min 90 and 110, market 100
    and 120, units 10 and 20, sold 3 and 4) and one row today → `rollup` returns 2; `daily` has `min 90, market 110,
    units 15, sold 7, hours 2`; today's hourly row is still there.
  - `test_rollup_idempotent`: a second `rollup` returns 0 and changes nothing.
- [ ] **Step 2: Run** `python dashboard/tests/test_market_store.py` → FAIL.
- [ ] **Step 3: Implement** `Store` per Interfaces (daily = min of min, mean of market, mean of units, sum of sold,
  count of hours; merge into an existing daily row by recomputing from both).
- [ ] **Step 4: Run** the test → PASS.
- [ ] **Step 5: Commit** `feat(dashboard): store hourly AH rows in SQLite and fold old hours into days`

### Task 5: The fetcher

**Files:**
- Create: `dashboard/fetcher.py`
- Test: `dashboard/tests/test_fetcher.py`

**Interfaces:**
- Consumes: `bnet.Config`, `bnet.Client.house`, `bnet.ApiError`, `market_reduce.*`, `market_store.Store`,
  `ledgerlog.get("fetcher", data)`, `server.read_config` (or a copy of its parsing in a shared helper).
- Produces:
  - `run_once(client, store, houses: list[int], now: int, log) -> dict` (status dict, shape in Global Constraints;
    one house failing doesn't stop the others; a snapshot whose id set equals the previous one is skipped and logged
    "unchanged", status `ok` with the previous `t`)
  - `next_run(last_try: int, every_min: int, now: int) -> int` (`last_try + every*60`, but never earlier than `now`
    → a long sleep gives one run, no burst)
  - `write_status(path, status)` (atomic: write `.tmp`, `os.replace`)
  - CLI: `python dashboard/fetcher.py` (loop), `--once`, `--match faction|neutral` (Task 6). Loop: `run_once`,
    `rollup` once a day, `write_status`, then wait until `next_run`, checking every 5 s for `data/fetch_now`
    (delete it and run) and for `data/fetcher_stop` (delete it and exit 0, logged "stopped (tray)").
  - `acquire_lock(path) -> bool`: single instance via `data/fetcher.lock` held with `msvcrt.locking` for the
    process lifetime; when it returns False, `main` logs "already running" and exits 0.

- [ ] **Step 1: Write the failing tests** with a fake client (`house(h)` returns canned lists or raises
  `ApiError(503, ...)`) and a temp `Store`.
  - `test_run_once_records_both`: two houses → both in status `houses` with `ok: True`, `items` counts; store has
    rows for both; `last_ok == now`, `error is None`.
  - `test_one_house_fails`: 116 raises → 113 recorded, `houses["116"]["ok"] is False`, `error` mentions `116` and
    `503`, `last_ok == now` (set because one house succeeded). With both failing, `last_ok` keeps its previous
    value (None on a first run).
  - `test_unchanged_snapshot_skipped`: same canned data twice → second run adds no `snapshot` row.
  - `test_sold_uses_previous`: first run has a LONG auction, second (now + 3600) lacks it → `hourly.sold` for that
    item is its quantity.
  - `test_next_run_after_sleep`: `next_run(1000, 60, 1000 + 5 * 3600) == 1000 + 5 * 3600`; `next_run(1000, 60,
    1500) == 4600`.
  - `test_not_set_up`: `main([])` with a config dict lacking `bnet_id` returns 0 and writes status
    `{"error": "not set up", ...}` (tray reads this as "not set up").
  - `test_second_instance_exits`: holding the lock in the test, `acquire_lock(path)` returns False.
- [ ] **Step 2: Run** `python dashboard/tests/test_fetcher.py` → FAIL.
- [ ] **Step 3: Implement** per Interfaces. Log per house: status, items, auctions, seconds, unchanged/recorded;
  sold units total. Houses = `[config.faction, config.neutral]`. `main(argv, cfg=None)` so tests inject config.
- [ ] **Step 4: Run** the test → PASS.
- [ ] **Step 5: Verify live**: `python dashboard/fetcher.py --once` → `data/fetcher.log` shows both houses
  recorded with thousands of items; `data/fetcher_status.json` has `last_ok`; `sqlite3`-free check:
  `python -c "import sqlite3;c=sqlite3.connect('data/market.db');print(c.execute('select house,count(*) from hourly group by house').fetchall())"`
  prints two houses with thousands of rows. Run `--once` again within minutes → "unchanged" for both (or recorded
  if Blizzard refreshed); note which in the commit message body.
- [ ] **Step 6: Commit** `feat(dashboard): hourly AH fetcher with status file and single-instance lock`

### Task 6: Which house is ours (`--match`)

**Files:**
- Create: `dashboard/dump_prices.lua`
- Modify: `dashboard/fetcher.py` (`--match`)
- Test: `dashboard/tests/test_fetcher.py` (`MatchScore` cases)

**Interfaces:**
- Produces:
  - `dashboard/dump_prices.lua <wow folder> <faction|neutral>`: prints `itemID<TAB>price` for the latest scan day
    of Auctionator's book (faction) or every priced item of Ledger Link's Neutral book (neutral), using
    `lib/sources.lua` (`S.auctionator`, `S.neutral`) on the account SavedVariables, merging nothing.
  - `match_score(book: dict[int, int], rows: dict[int, dict]) -> dict` → `{"shared", "exact", "near"}` (near =
    within 5%).
  - `--match faction|neutral`: runs the dump (lua found like `server.lua_exe()`), fetches every house of that kind
    (faction: 110–115, 119, 120, 123, 124; neutral: 116–118, 121, 125), prints one line per house sorted by `exact`
    share, and says which configured house (`ah_faction` / `ah_neutral`) it matches or which it should be.
- [ ] **Step 1: Write the failing test** `test_match_score`: book `{1: 100, 2: 200, 3: 300}`, rows `{1: min 100,
  2: min 205, 4: min 9}` → `shared 2, exact 1, near 2`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Verify** `python dashboard/fetcher.py --match faction` ranks 113 first (≥ 60% exact after a fresh
  Horde scan). `--match neutral` with an empty Neutral book prints "no Neutral prices saved yet: scan the Neutral
  AH, /reload, then run this again" and exits 0.
- [ ] **Step 6: Commit** `feat(dashboard): match in-game scans to Battle.net auction houses`

### Task 7: Live server `/status`

**Files:**
- Modify: `dashboard/server.py` (`App` gains `started`, `last_build = {"t", "ok", "seconds", "message"}` set where
  builds run; `do_GET` route `/status`)

**Interfaces:**
- Produces: `GET /status` → `200 application/json` `{"ok": true, "pid", "started", "uptime", "last_build": {...} |
  null}`; same host check as other routes.

- [ ] **Step 1: Implement** the route and the build bookkeeping.
- [ ] **Step 2: Verify**: start the server with `--no-open`, `curl -s http://127.0.0.1:8737/status` returns the
  JSON with `pid` matching the process; after touching a SavedVariables file (or `/reload` in game) `last_build.t`
  moves.
- [ ] **Step 3: Commit** `feat(dashboard): live server reports its status at /status`

### Task 8: Tray icon and `wowstats` wiring

**Files:**
- Create: `dashboard/tray.ps1`, `dashboard/tray.bat` (starts it hidden:
  `powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0tray.ps1"`)
- Modify: `bin/wowstats.bat` (`live` → `tray.bat`; `stop` → also write `data/fetcher_stop` and signal the tray),
  `dashboard/serve.bat` comment, `README.md` (new "Auction house data from the Battle.net API" section: create a
  client, the keys, the tray, `--match`, copying `market.db` to other PCs; files table rows for the new files;
  `data/` row adds `market.db`, `fetcher_status.json`, `fetcher.log`, `tray.log`)

**Interfaces:**
- Consumes: `GET /status` (Task 7), `data/fetcher_status.json`, `fetch_now`/`fetcher_stop` flag files (Task 5),
  the `/stop` POST with header `X-Ledger: stop` (existing).
- Produces: tray behaviour per spec; `tray.log` in the Global Constraints format with its own rotation; single
  instance via named mutex `Global\AdventureLedgerTray`; tray quits when it finds `data/tray_stop` (written by
  `wowstats stop`).

- [ ] **Step 1: Implement** `tray.ps1`:
  - On start: start `pythonw server.py --no-open` and (when `bnet_id` is set in `ledger.cfg`) `pythonw fetcher.py`,
    keeping their `Process` objects; open the page once like `serve.bat` does.
  - Every 5 s: process alive? `/status` answers (2 s timeout)? status file `error` / `last_ok` age → colour and
    tooltip (`Live: on · AH: last fetch 14:05, next 15:05`; amber/grey tooltips name the cause). Icons drawn in code
    (a filled circle in green `#2e9d5b`, amber `#e0a030`, grey `#8a8a8a`), no image files. Log each status change.
  - Menu: Open dashboard · Live server ▸ Start / Stop · AH fetcher ▸ Start / Stop / Fetch now (disabled when not
    set up) · Open logs folder · Start with Windows (checkbox; creates/removes
    `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Adventure Ledger.lnk` → `tray.bat`) · Quit (stops both:
    `/stop` POST and `fetcher_stop`, waits up to 10 s, then kills).
- [ ] **Step 2: Verify by hand**, writing results in the commit body:
  1. `wowstats live` → one tray icon, green within a minute (after a fetch), page opens.
  2. Run `wowstats live` again → still one icon (mutex).
  3. Live server ▸ Stop → amber, tooltip says the server is stopped; Start → green.
  4. AH fetcher ▸ Fetch now → `fetcher.log` shows a run within ~5 s.
  5. Remove `bnet_id` from a copy of the config (or rename it temporarily) → fetcher "not set up", icon not amber
     for that reason; restore it.
  6. `wowstats stop` → tray gone, no `pythonw` left in Task Manager.
  7. Start with Windows → the shortcut exists; untick → gone.
- [ ] **Step 3: Commit** `feat(dashboard): tray icon that runs and watches the live server and AH fetcher`
  (README and wiring in the same commit, since they describe this behaviour).
