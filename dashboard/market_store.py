"""SQLite store for hourly AH rows, with old hours folded into days. Standard library only."""
import sqlite3
import time

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
CREATE TABLE IF NOT EXISTS last_auctions (
    house INTEGER, auction_id INTEGER, item INTEGER, quantity INTEGER, time_left TEXT);
CREATE INDEX IF NOT EXISTS last_auctions_house ON last_auctions (house);
"""


def local_day(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


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

    def last_ids(self, house):
        """(time of the previous snapshot or None, {auction_id: (item, quantity, time_left)})."""
        got = self.db.execute("SELECT MAX(t) FROM snapshot WHERE house=?", (house,)).fetchone()[0]
        cur = self.db.execute(
            "SELECT auction_id, item, quantity, time_left FROM last_auctions WHERE house=?", (house,))
        return got, {aid: (item, qty, left) for aid, item, qty, left in cur}

    def rollup(self, now, keep_days=30):
        """Fold hourly rows older than keep_days into daily rows (local days). Returns rows folded."""
        cutoff = now - keep_days * 86400
        old = self.db.execute(
            "SELECT house, t, item, min, market, units, sold FROM hourly WHERE t < ?", (cutoff,)).fetchall()
        if not old:
            return 0
        groups = {}
        for house, t, item, mn, market, units, sold in old:
            groups.setdefault((house, local_day(t), item), []).append((mn, market, units, sold))
        with self.db:
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
