"""Tests for market_store.py (SQLite store and daily rollup).   Usage: python dashboard/tests/test_market_store.py"""
import os
import sqlite3
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import market_store as ms  # noqa: E402


def row(mn, market, units, listings=1):
    return {"min": mn, "market": market, "units": units, "listings": listings}


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = ms.Store(os.path.join(self.dir.name, "market.db"))

    def tearDown(self):
        self.store.close()  # Windows cannot delete an open file
        self.dir.cleanup()

    def test_record_and_last_ids(self):
        ids = {7: (2589, 4, "LONG")}
        self.store.record(113, 1000, {2589: row(90, 100, 10)}, {}, ids)
        self.assertEqual(self.store.last_ids(113), (1000, ids))
        self.assertEqual(self.store.last_ids(116), (None, {}))

    def test_record_replaces_last_auctions(self):
        self.store.record(113, 1000, {2589: row(90, 100, 10)}, {}, {7: (2589, 4, "LONG")})
        second = {8: (2589, 2, "SHORT")}
        self.store.record(113, 4600, {2589: row(90, 100, 10)}, {}, second)
        self.assertEqual(self.store.last_ids(113), (4600, second))

    def test_sold_defaults_to_zero(self):
        self.store.record(113, 1000, {1: row(1, 1, 1), 2: row(2, 2, 2)}, {2: 5}, {})
        got = dict(self.store.db.execute("SELECT item, sold FROM hourly"))
        self.assertEqual(got, {1: 0, 2: 5})

    def test_sold_out_item_recorded(self):
        self.store.record(113, 1000, {2: row(2, 2, 2)}, {7: 3, 2: 1, 8: 0}, {})
        got = self.store.db.execute("SELECT item, min, market, units, listings, sold FROM hourly ORDER BY item")
        self.assertEqual(got.fetchall(), [(2, 2, 2, 2, 1, 1), (7, None, None, 0, 0, 3)])

    def _hour(self, t, mn, market, units, sold):
        self.store.record(113, t, {2589: row(mn, market, units)}, {2589: sold}, {})

    def _fill(self):
        now = int(time.time())
        noon = time.mktime(time.localtime(now - 40 * 86400)[:3] + (12, 0, 0, 0, 0, -1))
        self._hour(int(noon), 90, 100, 10, 3)
        self._hour(int(noon) + 3600, 110, 120, 20, 4)
        self._hour(now, 50, 60, 5, 1)
        self.noon = int(noon)
        return now

    def test_rollup_folds_old_hours(self):
        now = self._fill()
        self.assertEqual(self.store.rollup(now), 2)
        days = self.store.db.execute("SELECT min, market, units, sold, hours FROM daily").fetchall()
        self.assertEqual(days, [(90, 110, 15, 7, 2)])
        left = self.store.db.execute("SELECT COUNT(*) FROM hourly").fetchone()[0]
        self.assertEqual(left, 1)

    def test_rollup_idempotent(self):
        now = self._fill()
        self.store.rollup(now)
        before = self.store.db.execute("SELECT * FROM daily").fetchall()
        self.assertEqual(self.store.rollup(now), 0)
        self.assertEqual(self.store.db.execute("SELECT * FROM daily").fetchall(), before)

    def test_rollup_merges_into_existing_day(self):
        now = self._fill()
        self.store.rollup(now)
        # A late hour for the same day arrives after the first fold.
        self._hour(self.noon + 7200, 80, 140, 30, 2)
        self.assertEqual(self.store.rollup(now), 1)
        days = self.store.db.execute("SELECT min, market, units, sold, hours FROM daily").fetchall()
        self.assertEqual(days, [(80, 120, 20, 9, 3)])

    def test_rollup_mixes_unpriced_hour(self):
        now = self._fill()
        self.store.record(113, self.noon + 7200, {}, {2589: 5}, {})   # sold out: no price that hour
        self.assertEqual(self.store.rollup(now), 3)
        days = self.store.db.execute("SELECT min, market, units, sold, hours FROM daily").fetchall()
        self.assertEqual(days, [(90, 110, 10, 12, 3)])

    def test_rollup_merges_unpriced_into_priced_day(self):
        now = self._fill()
        self.store.rollup(now)
        self.store.record(113, self.noon + 7200, {}, {2589: 5}, {})
        self.assertEqual(self.store.rollup(now), 1)
        days = self.store.db.execute("SELECT min, market, sold, hours, priced FROM daily").fetchall()
        self.assertEqual(days, [(90, 110, 12, 3, 2)])

    def test_rollup_all_unpriced_day(self):
        now = self._fill()
        t = self.noon - 86400
        self.store.record(113, t, {}, {2589: 2}, {})
        self.store.rollup(now)
        row_ = self.store.db.execute("SELECT min, market, sold, hours FROM daily ORDER BY day").fetchone()
        self.assertEqual(row_, (None, None, 2, 1))

    def test_migration_is_committed(self):
        path = os.path.join(self.dir.name, "old.db")
        db = sqlite3.connect(path)
        db.executescript("""CREATE TABLE daily (house INTEGER, day TEXT, item INTEGER, min INTEGER, market REAL,
            units REAL, sold INTEGER, hours INTEGER, PRIMARY KEY (house, day, item));
            INSERT INTO daily VALUES (113, '2026-01-01', 5, 10, 12.0, 3.0, 2, 3);""")
        db.commit()
        db.close()
        store = ms.Store(path)
        store.close()
        db = sqlite3.connect(path)
        self.assertEqual(db.execute("SELECT hours, priced FROM daily").fetchone(), (3, 3))
        db.close()

    def test_rollup_tolerates_null_priced(self):
        now = self._fill()
        self.store.rollup(now)
        self.store.db.execute("UPDATE daily SET priced = NULL")
        self.store.db.commit()
        self._hour(self.noon + 7200, 80, 140, 30, 2)
        self.store.rollup(now)
        days = self.store.db.execute("SELECT min, market, hours FROM daily").fetchall()
        self.assertEqual(days, [(80, 120, 3)])


if __name__ == "__main__":
    unittest.main()
