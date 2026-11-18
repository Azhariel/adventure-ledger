"""Hour-of-week price profile: how much each (weekday, hour) cell deviates from its week's median price.
Pure functions, standard library only. All times are local (the AH rhythm follows the players' clock)."""
import math
import statistics
import time

HALF_LIFE_WEEKS = 2
CAP = 0.25           # a week's log-ratio is clipped to this (about +-28%), so one dump cannot skew a cell
WEEK = 7 * 86400


def week_start(t):
    """Local Monday 00:00 of the week holding t."""
    try:
        lt = time.localtime(t)
        return max(0, int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday - lt.tm_wday, 0, 0, 0, 0, 0, -1))))
    except (OverflowError, OSError, ValueError):   # Windows rejects local times before the epoch
        return 0


def cell(t):
    """(weekday 0=Mon..6, hour 0..23), local."""
    try:
        lt = time.localtime(t)
    except (OverflowError, OSError, ValueError):
        lt = time.gmtime(max(0, t))
    return lt.tm_wday, lt.tm_hour


def week_contrib(obs):
    """One item's (t, market, sold) rows within one week -> {cell: (lr, sold, n)}.
    lr = log(cell median / week median), clipped to +-CAP; n = priced observations. Unpriced cells are absent."""
    priced = [m for _, m, _ in obs if m is not None and m > 0]   # a price of 0 is unpriced: log(0) must not run
    if not priced:
        return {}
    ref = statistics.median(priced)
    cells = {}
    for t, market, sold in obs:
        c = cells.setdefault(cell(t), {"m": [], "sold": 0})
        c["sold"] += sold
        if market is not None and market > 0:
            c["m"].append(market)
    out = {}
    for key, c in cells.items():
        if c["m"]:
            lr = math.log(statistics.median(c["m"]) / ref)
            out[key] = (max(-CAP, min(CAP, lr)), c["sold"], len(c["m"]))
    return out


def decay(weeks):
    return 0.5 ** (weeks / HALF_LIFE_WEEKS)
