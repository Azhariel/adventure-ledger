"""AH market engine. Calculations first (pure, no I/O); the sqlite/file glue lives below its own section.
`rows` is always one item's [(t, min, market, units, listings, sold)] hourly rows, oldest first.
min/market are None for an hour the item was sold out; sold is an int. Days are local days.
`buckets` are one item's rows summed per (local day, window segment): see day_buckets. The long windows
(market value, trend, sales, history) read buckets, so a month of hours never passes through Python."""
import collections
import math
import os
import pathlib
import sqlite3
import statistics
import sys
import tempfile
import time

import bnet
import market_profile as mp
import market_store

# Every threshold in one place.
C = {
    "MARKET_DAYS": 14,        # window of the market value
    "MARKET_HALF_LIFE_DAYS": 3,
    "MIN_SNAPSHOTS": 6,       # priced rows needed for a market value
    "HIST_DAYS": 60,
    "TREND_DAYS": 7,
    "SHIFT_HOURS": 48,
    "SHIFT_MIN_SNAPS": 12,
    "SHIFT_SHARE": 0.75,      # share of the window that must sit beyond the threshold
    "SHIFT_PCT": 0.25,
    "SHIFT_MIN_SOLD": 5,      # a "new price" needs sales behind it
    "WEEK_MIN_WEEKS": 2,
    "WEEK_MIN_N": 2,
    "WEEK_MIN_CELLS": 0.6,
}

DAY = 86400
CELLS = 168


# ---------------------------------------------------------------- calculations (pure)

# One (local day, segment) of an item's rows. lo/hi: first and last hour; wm = sum((sold+1)*market),
# w = sum(sold+1) and wt = sum((sold+1)*t) over priced hours; n = priced hours; sold = units sold;
# msum = sum(market) (for the day's mean).
Bucket = collections.namedtuple("Bucket", "day lo hi wm w wt n sold msum")


def edges(now):
    """Every window edge the engine reads. Buckets are split at each one, so a bucket sits wholly inside or
    outside every window; only the decay inside a bucket is approximated."""
    span = C["MARKET_DAYS"] * DAY
    then = now - C["TREND_DAYS"] * DAY
    cut = now - C["SHIFT_HOURS"] * 3600
    return sorted({now - span, then, then - span, cut, cut - span, now - C["HIST_DAYS"] * DAY})


def segment(t, cuts):
    return sum(1 for e in cuts if t > e)


def day_buckets(rows, cuts=()):
    """Rows -> buckets, the same sums the engine's SQL makes (for tests and small inputs)."""
    acc = {}
    for t, _mn, market, _u, _l, sold in rows:
        key = (market_store.local_day(t), segment(t, cuts))
        b = acc.get(key) or [t, t, 0, 0, 0, 0, 0, 0]
        b[0], b[1] = min(b[0], t), max(b[1], t)
        b[6] += sold
        if market is not None:
            b[2] += (sold + 1) * market
            b[3] += sold + 1
            b[4] += (sold + 1) * t
            b[5] += 1
            b[7] += market
        acc[key] = b
    return sorted((Bucket(day, *b) for (day, _s), b in acc.items()), key=lambda b: b.lo)


def _mid(b):
    return (b.lo + b.hi) / 2


def market_value(buckets, end):
    """Sales- and recency-weighted mean of the hourly market price over the 14 days up to `end`.
    Each bucket decays as a whole, at its rows' weighted mean time (exact to first order)."""
    lo = end - C["MARKET_DAYS"] * DAY
    num = den = 0.0
    count = 0
    hl = DAY * C["MARKET_HALF_LIFE_DAYS"]
    for _d, b_lo, b_hi, wm, w, wt, n, _s, _m in buckets:
        if not n or not (lo < (b_lo + b_hi) / 2 <= end):
            continue
        f = 0.5 ** ((end - wt / w) / hl)
        num += f * wm
        den += f * w
        count += n
    if count < C["MIN_SNAPSHOTS"]:
        return None
    return int(round(num / den))


def trend(buckets, now):
    """Market value now vs a week ago, as a fraction. None until the data reaches back a week."""
    then = now - C["TREND_DAYS"] * DAY
    if not buckets or min(b.lo for b in buckets) > then:
        return None
    a, b = market_value(buckets, now), market_value(buckets, then)
    if a is None or b is None:
        return None
    return a / b - 1


def sold_per_day(buckets, now):
    if not buckets:
        return 0.0
    lo = now - C["MARKET_DAYS"] * DAY
    total = sum(b.sold for b in buckets if _mid(b) > lo)
    return total / max(1, min(C["MARKET_DAYS"], (now - min(b.lo for b in buckets)) / DAY))


def historical(day_means):
    return sum(day_means) / len(day_means) if day_means else None


def hourly_day_means(buckets, now):
    """{local day: mean market price} over the priced hours of the last HIST_DAYS."""
    lo = now - C["HIST_DAYS"] * DAY
    sums = {}
    for b in buckets:
        if b.n and _mid(b) > lo:
            s = sums.setdefault(b.day, [0, 0])
            s[0] += b.msum
            s[1] += b.n
    return {day: ms / n for day, (ms, n) in sums.items()}


def shifted(buckets, rows, now):
    """A new price level that is holding: most of the last 48h (`rows`) sits beyond +-SHIFT_PCT of the
    market value from before that window, with real sales. A one-night dump fails the share test."""
    cut = now - C["SHIFT_HOURS"] * 3600
    ref = market_value(buckets, cut)
    if not ref:
        return None
    inwin = [r for r in rows if cut < r[0] <= now]
    # Sales in sold-out hours (market None) are real sales too; only share and ratio use priced rows.
    win = [(t, m / ref, sold) for t, _mn, m, _u, _l, sold in inwin if m is not None]
    if len(win) < C["SHIFT_MIN_SNAPS"] or sum(r[5] for r in inwin) < C["SHIFT_MIN_SOLD"]:
        return None
    pct = C["SHIFT_PCT"]
    for name, beyond in (("up", lambda r: r - 1 >= pct), ("down", lambda r: r - 1 <= -pct)):
        if sum(1 for _, r, _ in win if beyond(r)) / len(win) >= C["SHIFT_SHARE"]:
            since = win[-1][0]
            for t, r, _ in reversed(win):
                if not beyond(r):
                    break
                since = t
            return {"dir": name, "pct": round(statistics.median(r for _, r, _ in win) - 1, 2), "since": since}
    return None


def item_week(stored, upto, rows, now):
    """Hour-of-week profile: stored decayed sums (weeks up to `upto`) plus the newer weeks still in `rows`.
    Weeks at or before `upto` are skipped in rows so nothing counts twice."""
    stored = (stored or {}) if upto is not None else {}   # sums without a week anchor cannot be decayed
    cur = mp.week_start(now)
    by_week = {}
    for t, _mn, market, _u, _l, sold in rows:
        wk = mp.week_start(t)
        if upto is None or wk > upto:
            by_week.setdefault(wk, []).append((t, market, sold))
    spans = bool(rows) and rows[-1][0] - rows[0][0] >= C["WEEK_MIN_WEEKS"] * 7 * DAY
    if not (spans or stored):
        return None
    F = mp.decay((cur - upto) / mp.WEEK) if stored else 0
    W, WP, WS, N = {}, {}, {}, {}
    for key, (wp, w, ws, n) in stored.items():
        W[key], WP[key], WS[key], N[key] = w * F, wp * F, ws * F, n
    for wk, obs in by_week.items():
        f = mp.decay((cur - wk) / mp.WEEK)
        for key, (lr, sold, n) in mp.week_contrib(obs).items():
            W[key] = W.get(key, 0) + f
            WP[key] = WP.get(key, 0) + f * lr
            WS[key] = WS.get(key, 0) + f * sold
            N[key] = N.get(key, 0) + n
    p, s, n_out = [None] * CELLS, [None] * CELLS, [0] * CELLS
    for key, w in W.items():
        i = key[0] * 24 + key[1]
        n_out[i] = N[key]
        if w > 0:
            p[i] = round(math.exp(WP[key] / w) - 1, 3)
            s[i] = round(WS[key] / w, 1)
    if sum(1 for n in n_out if n >= C["WEEK_MIN_N"]) < C["WEEK_MIN_CELLS"] * CELLS:
        return None
    return {"p": p, "s": s, "n": n_out}


def house_week(snapshots, sold_by_t):
    """Whole-house hour-of-week shape. snapshots = [(t, auctions)], sold_by_t = {t: units sold in that hour}.
    listings = mean auctions per cell; sold = sold per cell per week seen. Cells without data are None."""
    auc, sold, weeks = {}, {}, set()
    for t, a in snapshots:
        auc.setdefault(mp.cell(t), []).append(a)
        weeks.add(mp.week_start(t))
    for t, s in sold_by_t.items():
        sold[mp.cell(t)] = sold.get(mp.cell(t), 0) + s
        weeks.add(mp.week_start(t))
    listings, sold_out = [None] * CELLS, [None] * CELLS
    for (d, h), v in auc.items():
        listings[d * 24 + h] = round(sum(v) / len(v), 1)
    for (d, h), v in sold.items():
        sold_out[d * 24 + h] = round(v / len(weeks), 1)
    return {"listings": listings, "sold": sold_out}


def item_summary(buckets, recent, last, day_means, now):
    """One item: `buckets` over the whole retention, `recent` its rows of the last SHIFT_HOURS (oldest first),
    `last` its row in the latest snapshot (None when it was not listed).
    The per-item `week` (item_week) is left out until the build reads it: step 2 of the AH market plan wires it
    in, from the stored profile plus the weeks still in hourly."""
    out = {"units": 0, "listings": 0}
    if last and last[1] is not None:
        out["units"], out["listings"], out["now"] = last[3], last[4], last[1]
    out["market"] = market_value(buckets, now)
    out["historical"] = historical(day_means)
    out["soldPerDay"] = round(sold_per_day(buckets, now), 2)
    out["trend"] = trend(buckets, now)
    out["days"] = len({b.day for b in buckets})
    out["shifted"] = shifted(buckets, recent, now)
    return {k: v for k, v in out.items() if v is not None}


# ---------------------------------------------------------------- I/O (sqlite in, market.lua out)


def to_lua(value):
    """A Lua table constructor for dicts, lists, numbers, strings and bools. None is skipped in a dict and is
    nil in a list; NaN and inf are never written (Lua cannot read them back), so they are skipped the same way."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, str):
        return _lua_str(value)
    if isinstance(value, dict):
        parts = []
        for k, v in value.items():
            if _unwritable(v):
                continue
            key = "[%d]" % k if isinstance(k, int) else "[%s]" % _lua_str(str(k))
            parts.append("%s=%s" % (key, to_lua(v)))
        return "{" + ",".join(parts) + "}"
    if isinstance(value, (list, tuple)):
        return "{" + ",".join("nil" if _unwritable(v) else to_lua(v) for v in value) + "}"
    raise TypeError("cannot write %r as Lua" % type(value).__name__)


def _unwritable(v):
    return v is None or (isinstance(v, float) and not math.isfinite(v))


def _lua_str(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def open_ro(db_path):
    """Read-only connection (the fetcher owns writes). None when there is no db file."""
    if not os.path.isfile(db_path):
        return None
    db = sqlite3.connect(pathlib.Path(db_path).resolve().as_uri() + "?mode=ro", uri=True)
    db.execute("PRAGMA threads=4")   # the engine's GROUP BYs sort millions of rows: let the sorter use helpers
    return db


def _has(db, table):
    """A db written before a table existed (the fetcher adds it on its next start) reads as empty."""
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def signature(db):
    """'house:latest snapshot:profile upto;...' over the houses that have snapshots. Changes when a snapshot
    arrives or the nightly rollup moves the profile."""
    try:
        rows = db.execute("SELECT house, MAX(t) FROM snapshot GROUP BY house ORDER BY house").fetchall()
    except sqlite3.Error:
        return ""
    upto = dict(db.execute("SELECT house, upto FROM profile_state")) if _has(db, "profile_state") else {}
    return ";".join("%d:%d:%s" % (h, t, "" if upto.get(h) is None else upto[h]) for h, t in rows)


def _house_keys(cfg):
    try:
        return {h["id"]: h["key"] for h in bnet.parse_houses(cfg)}
    except ValueError:
        return {}


def _buckets_sql(cuts):
    """The day_buckets sums in SQL: one row per (item, local day, segment) instead of one per hour.
    NOT INDEXED: the (house, item, t) index would cost a table lookup per row; reading the table in order and
    sorting is several times faster."""
    seg = "+".join("(t>%d)" % e for e in cuts) or "0"
    return ("SELECT item, date(t, 'unixepoch', 'localtime') AS day, %s AS seg, MIN(t), MAX(t), "
            "TOTAL(CASE WHEN market IS NOT NULL THEN (sold+1)*market END), "
            "TOTAL(CASE WHEN market IS NOT NULL THEN sold+1 END), TOTAL(CASE WHEN market IS NOT NULL THEN (sold+1)*t END), "
            "COUNT(market), TOTAL(sold), TOTAL(market) "
            "FROM hourly NOT INDEXED WHERE house=? GROUP BY item, day, seg" % seg)


def _house(db, house, keys, now):
    snaps = db.execute("SELECT t, auctions FROM snapshot WHERE house=? ORDER BY t", (house,)).fetchall()
    latest, first, count = snaps[-1][0], snaps[0][0], len(snaps)
    newest = [t for t, _ in reversed(snaps[-6:])]
    cut = now - C["SHIFT_HOURS"] * 3600

    buckets = {}
    for item, day, _seg, lo, hi, wm, w, wt, n, sold, msum in db.execute(_buckets_sql(edges(now)), (house,)):
        buckets.setdefault(item, []).append(Bucket(day, lo, hi, wm, w, wt, n, int(sold), msum))

    # Per hour only the recent rows: the shift window, and the newest snapshots' prices (older than the window
    # when the fetcher was off for a while).
    recent, last, recent_min = {}, {}, {t: {} for t in newest}
    since = min(cut, newest[-1] - 1)
    for item, t, mn, market, units, listings, sold in db.execute(
            "SELECT item, t, min, market, units, listings, sold FROM hourly NOT INDEXED WHERE house=? AND t>? "
            "ORDER BY item, t",
            (house, since)):
        row = (t, mn, market, units, listings, sold)
        if t == latest:
            last[item] = row
        if mn is not None and t in recent_min:
            recent_min[t][item] = mn
        if t > cut:
            recent.setdefault(item, []).append(row)
    sold_by_t = dict(db.execute("SELECT t, SUM(sold) FROM hourly NOT INDEXED WHERE house=? GROUP BY t", (house,)))

    lo_day = market_store.local_day(now - C["HIST_DAYS"] * DAY)
    by_day = {}
    for item, day, market in (db.execute(
            "SELECT item, day, market FROM daily WHERE house=? AND day>=? AND market IS NOT NULL", (house, lo_day))
            if _has(db, "daily") else ()):
        by_day.setdefault(item, {})[day] = market

    items = {}
    for item, bs in buckets.items():
        bs.sort(key=lambda b: b.lo)
        days = dict(by_day.get(item, {}))
        days.update(hourly_day_means(bs, now))   # hourly wins: daily only holds folded days, the two rarely overlap
        items[item] = item_summary(bs, recent.get(item, []), last.get(item), list(days.values()), now)

    recent = [{"t": t, "min": recent_min[t]} for t in newest]
    out = {"id": house, "latest": latest, "first": first, "snapshots": count,
           "week": house_week(snaps, sold_by_t), "recent": recent, "items": items}
    if house in keys:
        out["key"] = keys[house]
    return out


def run(db_path, out_path, cfg, now=None):
    """Write out_path (market.lua) from the db: "written", "unchanged" (nothing new since the last write)
    or "no data". Never writes the db, and copies nothing from the config but the house names."""
    db = open_ro(db_path)
    if db is None:
        return "no data"
    try:
        sig = signature(db)
        if not sig:
            return "no data"
        keys = _house_keys(cfg)
        # The house names are part of the stamp: changing ah_houses must rewrite the file.
        head = "-- sig: %s|%s" % (sig, ",".join("%d=%s" % kv for kv in sorted(keys.items())))
        try:
            with open(out_path, encoding="utf-8") as fh:
                if fh.readline().rstrip("\n") == head:
                    return "unchanged"
        except OSError:
            pass
        now = int(time.time() if now is None else now)
        houses = {h: _house(db, h, keys, now) for h, in db.execute("SELECT DISTINCT house FROM snapshot ORDER BY house").fetchall()}
        text = "%s\nLedgerMarket = %s\n" % (head, to_lua({"generated": now, "houses": houses}))
    finally:
        db.close()
    _write_atomic(out_path, text)
    return "written"


def _write_atomic(path, text, tries=10):
    """Unique temp file (two processes may build at once), then replace. Windows refuses the replace while
    another process has the file open: retry briefly. The temp file never outlives a failure."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        for attempt in range(tries):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                if attempt == tries - 1:
                    raise
                time.sleep(0.2)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def main():
    """One run against <data>/market.db. Always exits 0: a market problem must not stop the page building."""
    try:
        import server   # reads the config and makes the data folder, so only on the command line
        print(run(os.path.join(server.DATA, "market.db"), os.path.join(server.DATA, "market.lua"),
                  server.read_config()))
    except Exception as e:   # noqa: BLE001
        print("market: %s: %s" % (type(e).__name__, e), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
