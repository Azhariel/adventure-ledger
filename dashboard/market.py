"""AH market engine. Calculations first (pure, no I/O); the sqlite/file glue lives below its own section.
`rows` is always one item's [(t, min, market, units, listings, sold)] hourly rows, oldest first.
min/market are None for an hour the item was sold out; sold is an int. Days are local days."""
import math
import statistics
import time

import market_profile as mp

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

def market_value(rows, end):
    """Sales- and recency-weighted mean of the hourly market price over the 14 days up to `end`."""
    lo = end - C["MARKET_DAYS"] * DAY
    num = den = 0.0
    count = 0
    for t, _mn, market, _u, _l, sold in rows:
        if market is None or not (lo < t <= end):
            continue
        w = (sold + 1) * 0.5 ** ((end - t) / DAY / C["MARKET_HALF_LIFE_DAYS"])
        num += w * market
        den += w
        count += 1
    if count < C["MIN_SNAPSHOTS"]:
        return None
    return int(round(num / den))


def trend(rows, now):
    """Market value now vs a week ago, as a fraction. None until the data reaches back a week."""
    then = now - C["TREND_DAYS"] * DAY
    if not rows or rows[0][0] > then:
        return None
    a, b = market_value(rows, now), market_value(rows, then)
    if a is None or b is None:
        return None
    return a / b - 1


def sold_per_day(rows, now):
    if not rows:
        return 0.0
    lo = now - C["MARKET_DAYS"] * DAY
    total = sum(r[5] for r in rows if r[0] > lo)
    return total / max(1, min(C["MARKET_DAYS"], (now - rows[0][0]) / DAY))


def historical(day_means):
    return sum(day_means) / len(day_means) if day_means else None


def shifted(rows, now):
    """A new price level that is holding: most of the last 48h sits beyond +-SHIFT_PCT of the
    market value from before that window, with real sales. A one-night dump fails the share test."""
    cut = now - C["SHIFT_HOURS"] * 3600
    ref = market_value(rows, cut)
    if not ref:
        return None
    win = [(t, m / ref, sold) for t, _mn, m, _u, _l, sold in rows if cut < t <= now and m is not None]
    if len(win) < C["SHIFT_MIN_SNAPS"] or sum(s for _, _, s in win) < C["SHIFT_MIN_SOLD"]:
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
    stored = stored or {}
    cur = mp.week_start(now)
    by_week = {}
    for t, _mn, market, _u, _l, sold in rows:
        wk = mp.week_start(t)
        if upto is None or wk > upto:
            by_week.setdefault(wk, []).append((t, market, sold))
    spans = bool(rows) and rows[-1][0] - rows[0][0] >= C["WEEK_MIN_WEEKS"] * 7 * DAY
    if not (spans or stored):
        return None
    F = mp.decay((cur - upto) / mp.WEEK) if (stored and upto is not None) else 0
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


def item_summary(rows, day_means, stored, upto, latest, now):
    out = {"units": 0, "listings": 0}
    last = rows[-1] if rows else None
    if last and last[0] == latest and last[1] is not None:
        out["units"], out["listings"], out["now"] = last[3], last[4], last[1]
    out["market"] = market_value(rows, now)
    out["historical"] = historical(day_means)
    out["soldPerDay"] = round(sold_per_day(rows, now), 2)
    out["trend"] = trend(rows, now)
    out["days"] = len({time.strftime("%Y-%m-%d", time.localtime(r[0])) for r in rows})
    out["shifted"] = shifted(rows, now)
    out["week"] = item_week(stored, upto, rows, now)
    return {k: v for k, v in out.items() if v is not None}


# ---------------------------------------------------------------- I/O (added in Task 7)
