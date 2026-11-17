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
SNAPSHOT_EVERY = 60   # minutes: Blizzard makes a new snapshot about hourly (seen in Last-Modified; not documented)
SHRINK_FROM = 1000   # a house this big never really halves between two snapshots an hour apart
SHRINK_SKIPS = 3     # ...but if it stays halved over this many snapshots in a row, it really did
REPLACE_TRIES = 5   # 0.2 s apart
BAD_NUMBER = "bad number in ledger.cfg (ah_ruleset, ah_faction, ah_neutral or ah_every)"
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


def write_status(path, status, log=None):
    """Write atomically. Windows refuses the replace while the tray is reading the file: retry, then skip."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(status, fh)
    for attempt in range(REPLACE_TRIES):
        try:
            os.replace(tmp, path)
            return True
        except PermissionError:
            if attempt < REPLACE_TRIES - 1:
                time.sleep(0.2)
    if log is not None:
        log.warning("could not write %s (in use); trying again next time", os.path.basename(path))
    return False


def read_status(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def run_once(client, store, houses, now, log, last_ok=None, every=60, skips=None):
    """Fetch and record every house. One house failing never stops the others.
    every: minutes between fetches. skips: {house: (partial snapshots skipped in a row, the last one's time)},
    kept by the caller."""
    skips = {} if skips is None else skips
    out = {"last_ok": last_ok, "last_try": now, "next": None, "error": None, "houses": {}}
    errors = []
    for house in houses:
        started = time.time()
        try:
            prev_t = store.last_time(house)
            got = client.house_since(house, prev_t)
            if got is None:   # 304: nothing newer than the last snapshot, nothing downloaded
                out["houses"][str(house)] = {"ok": True, "t": prev_t, "items": store.items_at(house, prev_t)}
                log.info("house %s: ok, not modified since %s, %.1fs", house,
                         time.strftime("%H:%M", time.localtime(prev_t)), time.time() - started)
                continue
            auctions, commodities, modified = got
            # Date the snapshot when Blizzard made it, so sales gaps and hours of the week are right. Fall back
            # to the fetch time when the header is missing, in the future, or not after the last snapshot.
            t = modified
            if t is None or t > now or (prev_t is not None and t <= prev_t):
                t = now
            ids = market_reduce.snapshot_ids(auctions, commodities)
            prev_ids = store.last_ids(house)[1] if prev_t is not None else {}
            skipped, skipped_t = skips.get(house, (0, None))
            before = skipped - 1 if t == skipped_t else skipped   # the same snapshot downloaded again counts once
            # recent: the last recorded snapshot is at most two snapshots old, plus one per snapshot skipped since
            recent = prev_t is not None and now - prev_t <= (2 + before) * max(every, SNAPSHOT_EVERY) * 60
            if (recent and before < SHRINK_SKIPS
                    and len(prev_ids) >= SHRINK_FROM and len(ids) < len(prev_ids) / 2):
                # Most likely a missing or cut-short list: recording it would count every LONG auction
                # as sold and forget the previous auctions. Skip it and compare the next one with the old.
                # After a long gap (PC off) or a few skipped snapshots in a row, the house may really have
                # shrunk.
                skipped = before + 1
                skips[house] = (skipped, t)
                why = "only %d auctions, had %d: skipped as a partial response (%d of %d)" % (
                    len(ids), len(prev_ids), skipped, SHRINK_SKIPS)
                out["houses"][str(house)] = {"ok": False, "t": None, "items": 0}
                errors.append("house %s: %s" % (house, why))
                log.warning("house %s: %s", house, why)
                continue
            skips.pop(house, None)
            if prev_t is not None and ids == prev_ids:   # quantities too: a partly bought commodity changes
                out["houses"][str(house)] = {"ok": True, "t": prev_t, "items": store.items_at(house, prev_t)}
                log.info("house %s: ok, %d auctions, %.1fs, unchanged", house, len(ids), time.time() - started)
                continue
            rows = market_reduce.reduce(auctions, commodities)
            sold = market_reduce.estimate_sold(prev_ids, ids, t - prev_t) if prev_t is not None else {}
            store.record(house, t, rows, sold, ids)
            out["houses"][str(house)] = {"ok": True, "t": t, "items": len(rows)}
            log.info("house %s: ok, %d items, %d auctions, %.1fs, recorded as of %s, %d units sold", house,
                     len(rows), len(ids), time.time() - started, time.strftime("%H:%M", time.localtime(t)),
                     sum(sold.values()))
        except Exception as e:   # a bad body (ValueError) must not stop the other house or the loop
            out["houses"][str(house)] = {"ok": False, "t": None, "items": 0}
            errors.append("house %s: %s" % (house, e))
            log.exception("house %s failed: %s", house, e)
    if any(h["ok"] for h in out["houses"].values()):
        out["last_ok"] = now
    out["error"] = "; ".join(errors) or None
    return out


def remove_flag(path, log):
    try:
        os.remove(path)
    except OSError as e:   # e.g. the tray writing it right now: act on it anyway
        log.warning("could not remove %s: %s", os.path.basename(path), e)


def wait_until(when, data, log):
    """Sleep until `when`; returns "now" for a fetch_now request, "stop" for fetcher_stop, else "time"."""
    now_file = os.path.join(data, "fetch_now")
    stop_file = os.path.join(data, "fetcher_stop")
    while True:
        if os.path.exists(stop_file):
            remove_flag(stop_file, log)
            return "stop"
        if os.path.exists(now_file):
            remove_flag(now_file, log)
            log.info("fetch requested (tray)")
            return "now"
        left = when - time.time()
        if left <= 0:
            return "time"
        time.sleep(min(POLL, left))


def rollup(store, now, log):
    """Fold old hours into days; a failure is logged and retried the next day, never fatal."""
    try:
        folded = store.rollup(now)
    except Exception:
        log.exception("rollup failed")
        return 0
    if folded:
        log.info("rollup: folded %d hourly rows into days", folded)
    return folded


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
    if args.match:   # read-only: no store, status file, log file or lock, so it can run beside the loop
        try:
            config = bnet.Config.from_cfg(cfg)
        except ValueError as e:
            print("%s: %s" % (BAD_NUMBER, e))
            return 1
        if config is None:
            print("not set up: add bnet_id and bnet_secret to ledger.cfg")
            return 1
        return match_houses(args.match, cfg, config)
    os.makedirs(data, exist_ok=True)
    log = ledgerlog.get("fetcher", data)   # before anything can fail: under pythonw this is the only trace
    try:
        return loop(args, cfg, data, log)
    except Exception:
        log.exception("crashed")
        raise


def loop(args, cfg, data, log):
    status_path = os.path.join(data, "fetcher_status.json")
    try:
        config = bnet.Config.from_cfg(cfg)
    except ValueError as e:
        log.error("%s: %s", BAD_NUMBER, e)
        write_status(status_path, {"last_ok": None, "last_try": None, "next": None,
                                   "error": BAD_NUMBER, "houses": {}}, log)
        return 2
    if config is None:
        write_status(status_path, {"last_ok": None, "last_try": None, "next": None,
                                   "error": "not set up", "houses": {}}, log)
        return 0
    if not acquire_lock(os.path.join(data, "fetcher.lock")):
        log.info("already running")
        return 0
    client = bnet.Client(config, log=log)
    store = market_store.Store(os.path.join(data, "market.db"))
    houses = [config.faction, config.neutral]
    last_ok = read_status(status_path).get("last_ok")
    last_rollup = 0
    skips = {}
    log.info("fetcher started: %r", config)
    try:
        while True:
            now = int(time.time())
            status = run_once(client, store, houses, now, log, last_ok, config.every, skips)
            last_ok = status["last_ok"]
            if now - last_rollup >= 86400:
                rollup(store, now, log)
                last_rollup = now
            status["next"] = None if args.once else next_run(now, config.every, int(time.time()))
            write_status(status_path, status, log)
            if args.once:
                return 0
            if wait_until(status["next"], data, log) == "stop":
                log.info("stopped (tray)")
                return 0
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
