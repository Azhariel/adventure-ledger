"""SQLite store for hourly AH rows, with old hours folded into days. Standard library only."""
import json
import sqlite3
import time

import market_profile as mp

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshot (house INTEGER, t INTEGER, items INTEGER, auctions INTEGER);
CREATE TABLE IF NOT EXISTS hourly (
    house INTEGER, t INTEGER, item INTEGER,
    min INTEGER, market INTEGER, units INTEGER, listings INTEGER, sold INTEGER);
CREATE INDEX IF NOT EXISTS hourly_item ON hourly (house, item, t);
CREATE TABLE IF NOT EXISTS daily (
    house INTEGER, day TEXT, item INTEGER,
    min INTEGER, market REAL, units REAL, sold INTEGER, hours INTEGER,
    priced INTEGER,
    PRIMARY KEY (house, day, item));
-- Decayed hour-of-week profile; sums are relative to profile_state.upto (week_start of the newest folded week).
CREATE TABLE IF NOT EXISTS profile (
    house INTEGER, item INTEGER, dow INTEGER, hour INTEGER,
    wp REAL, w REAL, ws REAL, n INTEGER,
    PRIMARY KEY (house, item, dow, hour));
CREATE TABLE IF NOT EXISTS profile_state (house INTEGER PRIMARY KEY, upto INTEGER);
CREATE TABLE IF NOT EXISTS last_auctions (
    house INTEGER, auction_id INTEGER, item INTEGER, quantity INTEGER, time_left TEXT);
CREATE INDEX IF NOT EXISTS last_auctions_house ON last_auctions (house);
"""


def local_day(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


def read_profile(db, house, items=None):
    """Store.profile on any connection, so the engine can read it from a read-only one. `items`: only these."""
    got = db.execute("SELECT upto FROM profile_state WHERE house=?", (house,)).fetchone()
    out = {}
    sql, args = "SELECT item, dow, hour, wp, w, ws, n FROM profile WHERE house=?", (house,)
    if items is not None:
        sql, args = sql + " AND item IN (SELECT value FROM json_each(?))", args + (json.dumps(list(items)),)
    for item, dow, hour, wp, w, ws, n in db.execute(sql, args):
        out.setdefault(item, {})[(dow, hour)] = (wp, w, ws, n)
    return (got[0] if got else None), out


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        # WAL: a reader in another process does not block the fetcher.
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        if "priced" not in [c[1] for c in self.db.execute("PRAGMA table_info(daily)")]:
            # Older db: every folded hour had a price. `priced` = hours with a price (market is a mean over those).
            with self.db:   # commit, or the UPDATE's transaction stays open and holds a write lock
                self.db.execute("ALTER TABLE daily ADD COLUMN priced INTEGER")
                self.db.execute("UPDATE daily SET priced = hours")

    def record(self, house, t, rows, sold, ids):
        """One snapshot in one transaction. An item that sold out (in `sold`, not in `rows`) gets an
        unpriced row, so its sales are not lost."""
        with self.db:
            self.db.execute("INSERT INTO snapshot VALUES (?,?,?,?)", (house, t, len(rows), len(ids)))
            self.db.executemany(
                "INSERT INTO hourly VALUES (?,?,?,?,?,?,?,?)",
                [(house, t, item, r["min"], r["market"], r["units"], r["listings"], sold.get(item, 0))
                 for item, r in rows.items()])
            self.db.executemany(
                "INSERT INTO hourly VALUES (?,?,?,NULL,NULL,0,0,?)",
                [(house, t, item, n) for item, n in sold.items() if n > 0 and item not in rows])
            self.db.execute("DELETE FROM last_auctions WHERE house=?", (house,))
            self.db.executemany(
                "INSERT INTO last_auctions VALUES (?,?,?,?,?)",
                [(house, aid, item, qty, left) for aid, (item, qty, left) in ids.items()])

    def last_time(self, house):
        """Time of the latest snapshot, or None."""
        return self.db.execute("SELECT MAX(t) FROM snapshot WHERE house=?", (house,)).fetchone()[0]

    def items_at(self, house, t):
        """Items in the snapshot at t (0 if there is none)."""
        got = self.db.execute("SELECT items FROM snapshot WHERE house=? AND t=?", (house, t)).fetchone()
        return got[0] if got else 0

    def last_ids(self, house):
        """(time of the previous snapshot or None, {auction_id: (item, quantity, time_left)})."""
        got = self.db.execute("SELECT MAX(t) FROM snapshot WHERE house=?", (house,)).fetchone()[0]
        cur = self.db.execute(
            "SELECT auction_id, item, quantity, time_left FROM last_auctions WHERE house=?", (house,))
        return got, {aid: (item, qty, left) for aid, item, qty, left in cur}

    def profile(self, house):
        """(upto or None, {item: {(dow, hour): (wp, w, ws, n)}}) for the engine."""
        return read_profile(self.db, house)

    def _fold_profile(self, old):
        """Add the folded hourly rows (house, t, item, market, sold) to the profile, a whole (item, week) at a time."""
        weeks = {}
        for house, t, item, market, sold in old:
            weeks.setdefault((house, item, mp.week_start(t)), []).append((t, market, sold))
        for house in {k[0] for k in weeks}:
            got = self.db.execute("SELECT upto FROM profile_state WHERE house=?", (house,)).fetchone()
            u1 = got[0] if got else None
            u2 = max([k[2] for k in weeks if k[0] == house] + ([u1] if u1 is not None else []))
            if u1 is not None and u2 > u1:
                f = mp.decay((u2 - u1) / mp.WEEK)
                self.db.execute("UPDATE profile SET wp=wp*?, w=w*?, ws=ws*? WHERE house=?", (f, f, f, house))
            self.db.execute("INSERT OR REPLACE INTO profile_state VALUES (?,?)", (house, u2))
            for (h, item, wk), obs in weeks.items():
                if h != house:
                    continue
                f = mp.decay((u2 - wk) / mp.WEEK)
                for (dow, hour), (lr, sold, n) in mp.week_contrib(obs).items():
                    self.db.execute(
                        "INSERT INTO profile VALUES (?,?,?,?,?,?,?,?) ON CONFLICT (house, item, dow, hour) DO UPDATE SET "
                        "wp=wp+excluded.wp, w=w+excluded.w, ws=ws+excluded.ws, n=n+excluded.n",
                        (house, item, dow, hour, f * lr, f, f * sold, n))

    def rollup(self, now, keep_days=30):
        """Fold hourly rows older than keep_days into daily rows (local days) and the hour-of-week profile.
        The cutoff is a week start, so the profile only ever sees whole weeks (hourly keeps keep_days..keep_days+7).
        Returns rows folded."""
        cutoff = mp.week_start(now - keep_days * 86400)
        old = self.db.execute(
            "SELECT house, t, item, min, market, units, sold FROM hourly WHERE t < ?", (cutoff,)).fetchall()
        if not old:
            return 0
        groups = {}
        for house, t, item, mn, market, units, sold in old:
            groups.setdefault((house, local_day(t), item), []).append((mn, market, units, sold))
        with self.db:
            self._fold_profile([(house, t, item, market, sold) for house, t, item, _, market, _, sold in old])
            for (house, day, item), hrs in groups.items():
                n = len(hrs)
                mins = [h[0] for h in hrs if h[0] is not None]
                markets = [h[1] for h in hrs if h[1] is not None]
                units = sum(h[2] for h in hrs)
                sold = sum(h[3] for h in hrs)
                market_sum = sum(markets)
                priced = len(markets)
                prev = self.db.execute(
                    "SELECT min, market, units, sold, hours, priced FROM daily WHERE house=? AND day=? AND item=?",
                    (house, day, item)).fetchone()
                if prev:
                    prev = prev[:5] + (prev[5] if prev[5] is not None else prev[4],)   # NULL priced: old row
                    # Recompute from both: the stored day holds means over its hours / priced hours.
                    if prev[0] is not None:
                        mins.append(prev[0])
                    if prev[1] is not None:
                        market_sum += prev[1] * prev[5]
                        priced += prev[5]
                    units += prev[2] * prev[4]
                    sold += prev[3]
                    n += prev[4]
                self.db.execute(
                    "INSERT OR REPLACE INTO daily VALUES (?,?,?,?,?,?,?,?,?)",
                    (house, day, item, min(mins) if mins else None,
                     market_sum / priced if priced else None, units / n, sold, n, priced))
            self.db.execute("DELETE FROM hourly WHERE t < ?", (cutoff,))
        return len(old)

    def close(self):
        self.db.close()
