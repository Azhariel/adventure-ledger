"""Hourly Battle.net auction-house fetcher: records per-item prices into data/market.db.

    python dashboard/fetcher.py          loop forever (the tray starts this)
    python dashboard/fetcher.py --once   one fetch, then exit
    python dashboard/fetcher.py --match faction|neutral   which house our in-game scans match

Control files in the data folder: fetch_now (run now), fetcher_stop (exit). Status goes to fetcher_status.json."""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bnet  # noqa: E402
import ledgerlog  # noqa: E402
import market_reduce  # noqa: E402
import market_store  # noqa: E402
import server  # noqa: E402  (read_config and the data folder rule)

KIND_HOUSES = {"faction": [110, 111, 112, 113, 114, 115, 119, 120, 123, 124],
               "neutral": [116, 117, 118, 121, 125]}
POLL = 5   # seconds between checks for fetch_now / fetcher_stop while waiting
_lock_handle = None   # held for the process lifetime


def acquire_lock(path):
    """Single instance: True if we now hold the lock, False if another process does."""
    global _lock_handle
    import msvcrt
    fh = open(path, "a+b")
    try:
        fh.seek(0)
        msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        fh.close()
        return False
    _lock_handle = fh
    return True


def next_run(last_try, every_min, now):
    """When to fetch next. Never in the past, so waking from a long sleep gives one run, not a burst."""
    return max(last_try + every_min * 60, now)


def write_status(path, status):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(status, fh)
    os.replace(tmp, path)


def read_status(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def run_once(client, store, houses, now, log, last_ok=None):
    """Fetch and record every house. One house failing never stops the others."""
    out = {"last_ok": last_ok, "last_try": now, "next": None, "error": None, "houses": {}}
    errors = []
    for house in houses:
        started = time.time()
        try:
            auctions, commodities = client.house(house)
            ids = market_reduce.snapshot_ids(auctions, commodities)
            prev_t, prev_ids = store.last_ids(house)
            if prev_t is not None and set(ids) == set(prev_ids):
                items = store.db.execute("SELECT items FROM snapshot WHERE house=? AND t=?",
                                         (house, prev_t)).fetchone()[0]
                out["houses"][str(house)] = {"ok": True, "t": prev_t, "items": items}
                log.info("house %s: ok, %d items, %d auctions, %.1fs, unchanged", house, items, len(ids),
                         time.time() - started)
                continue
            rows = market_reduce.reduce(auctions, commodities)
            sold = market_reduce.estimate_sold(prev_ids, ids, now - prev_t) if prev_t is not None else {}
            store.record(house, now, rows, sold, ids)
            out["houses"][str(house)] = {"ok": True, "t": now, "items": len(rows)}
            log.info("house %s: ok, %d items, %d auctions, %.1fs, recorded, %d units sold", house, len(rows),
                     len(ids), time.time() - started, sum(sold.values()))
        except Exception as e:   # a bad body (ValueError) must not stop the other house or the loop
            out["houses"][str(house)] = {"ok": False, "t": None, "items": 0}
            errors.append("house %s: %s" % (house, e))
            log.error("house %s failed: %s", house, e)
    if any(h["ok"] for h in out["houses"].values()):
        out["last_ok"] = now
    out["error"] = "; ".join(errors) or None
    return out


def wait_until(when, data, log):
    """Sleep until `when`; returns "now" for a fetch_now request, "stop" for fetcher_stop, else "time"."""
    now_file = os.path.join(data, "fetch_now")
    stop_file = os.path.join(data, "fetcher_stop")
    while True:
        if os.path.exists(stop_file):
            os.remove(stop_file)
            return "stop"
        if os.path.exists(now_file):
            os.remove(now_file)
            log.info("fetch requested (tray)")
            return "now"
        left = when - time.time()
        if left <= 0:
            return "time"
        time.sleep(min(POLL, left))


def match_score(book, rows):
    """How well in-game prices {item: copper} agree with a house's reduced rows {item: {"min": ...}}."""
    shared = exact = near = 0
    for item, price in book.items():
        row = rows.get(item)
        if row is None:
            continue
        shared += 1
        low = row["min"]
        if low == price:
            exact += 1
        if abs(low - price) <= price * 0.05:
            near += 1
    return {"shared": shared, "exact": exact, "near": near}


def read_book(wow, kind):
    """The prices saved in game ({item: copper}), through dump_prices.lua."""
    out = subprocess.run([server.lua_exe(), os.path.join(HERE, "dump_prices.lua"), wow, kind],
                         capture_output=True, text=True, check=True).stdout
    book = {}
    for line in out.splitlines():
        item, _, price = line.partition("\t")
        book[int(item)] = int(price)
    return book


def match_houses(kind, cfg, config):
    """Compare the saved in-game book with every house of that kind; print which one is ours."""
    wow = cfg.get("wow")
    if not wow:
        print("no wow folder: set wow = your _forever_ folder in ledger.cfg")
        return 1
    book = read_book(wow, kind)
    if not book:
        if kind == "neutral":
            print("no Neutral prices saved yet: scan the Neutral AH, /reload, then run this again")
        else:
            print("no Auctionator prices saved yet: scan the AH, /reload, then run this again")
        return 0
    client = bnet.Client(config)
    scores = []
    for house in KIND_HOUSES[kind]:
        try:
            auctions, commodities = client.house(house)
        except Exception as e:
            print("house %d: failed: %s" % (house, e))
            continue
        scores.append((house, match_score(book, market_reduce.reduce(auctions, commodities))))
    scores.sort(key=lambda hs: hs[1]["exact"], reverse=True)
    print("%d %s prices saved in game" % (len(book), kind))
    for house, sc in scores:
        pct = lambda n: 100 * n // len(book)   # noqa: E731
        print("house %d: %d shared, %d exact (%d%%), %d within 5%% (%d%%)" % (
            house, sc["shared"], sc["exact"], pct(sc["exact"]), sc["near"], pct(sc["near"])))
    if scores:
        best = scores[0][0]
        configured = config.faction if kind == "faction" else config.neutral
        key = "ah_" + kind
        if best == configured:
            print("%s = %d matches best" % (key, best))
        else:
            print("%s = %d, but house %d matches best: set %s = %d in ledger.cfg" % (
                key, configured, best, key, best))
    return 0


def main(argv=None, cfg=None, data=None):
    ap = argparse.ArgumentParser(description="Hourly AH fetcher")
    ap.add_argument("--once", action="store_true", help="fetch once and exit")
    ap.add_argument("--match", choices=sorted(KIND_HOUSES),
                    help="find which Battle.net house matches the prices saved in game, then exit")
    args = ap.parse_args(argv)
    if cfg is None:
        cfg = server.read_config()
    if data is None:
        data = server.DATA
    config = bnet.Config.from_cfg(cfg)
    if args.match:   # read-only: no store, status file, log file or lock, so it can run beside the loop
        if config is None:
            print("not set up: add bnet_id and bnet_secret to ledger.cfg")
            return 1
        return match_houses(args.match, cfg, config)
    os.makedirs(data, exist_ok=True)
    status_path = os.path.join(data, "fetcher_status.json")
    if config is None:
        write_status(status_path, {"last_ok": None, "last_try": None, "next": None,
                                   "error": "not set up", "houses": {}})
        return 0
    log = ledgerlog.get("fetcher", data)
    if not acquire_lock(os.path.join(data, "fetcher.lock")):
        log.info("already running")
        return 0
    client = bnet.Client(config, log=log)
    store = market_store.Store(os.path.join(data, "market.db"))
    houses = [config.faction, config.neutral]
    last_ok = read_status(status_path).get("last_ok")
    last_rollup = 0
    log.info("fetcher started: %r", config)
    try:
        while True:
            now = int(time.time())
            status = run_once(client, store, houses, now, log, last_ok)
            last_ok = status["last_ok"]
            if now - last_rollup >= 86400:
                folded = store.rollup(now)
                last_rollup = now
                if folded:
                    log.info("rollup: folded %d hourly rows into days", folded)
            status["next"] = None if args.once else next_run(now, config.every, int(time.time()))
            write_status(status_path, status)
            if args.once:
                return 0
            if wait_until(status["next"], data, log) == "stop":
                log.info("stopped (tray)")
                return 0
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
