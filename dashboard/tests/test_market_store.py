"""Tests for market_store.py (SQLite store and daily rollup).   Usage: python dashboard/tests/test_market_store.py"""
import math
import os
import sqlite3
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import market_profile as mp  # noqa: E402
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

    def _week_rows(self, wk, bump=True):
        """Hourly rows for one week (Monday 00:00 = wk): 100 at 10:00 and 20:00 daily, +20% on Tuesday 20:00."""
        for d in range(7):
            for h in (10, 20):
                t = int(time.mktime(time.localtime(wk + d * 86400 + 3600 * 12)[:3] + (h, 0, 0, 0, 0, -1)))
                self._hour(t, 90, 120 if (bump and d == 1 and h == 20) else 100, 10, 1)

    def test_rollup_keeps_whole_weeks(self):
        now = int(time.time())
        ages = range(1, 46, 2)   # days ago: some fall in the 30-37 day margin the old cutoff would have deleted
        for a in ages:
            self._hour(now - a * 86400, 90, 100, 10, 1)
        cutoff = mp.week_start(now - 30 * 86400)
        self.store.rollup(now)
        ts = [r[0] for r in self.store.db.execute("SELECT t FROM hourly")]
        self.assertTrue(ts and min(ts) >= cutoff)
        self.assertEqual(len(ts), sum(1 for a in ages if now - a * 86400 >= cutoff))

    def test_rollup_fills_profile_and_decays(self):
        w1 = mp.week_start(int(time.time())) - 6 * mp.WEEK
        self._week_rows(w1)
        self.store.rollup(w1 + 6 * mp.WEEK)
        self._week_rows(w1 + mp.WEEK)
        self.store.rollup(w1 + 7 * mp.WEEK)
        upto, prof = self.store.profile(113)
        self.assertEqual(upto, mp.week_start(w1 + mp.WEEK))
        wp, w, ws, n = prof[2589][(1, 20)]
        self.assertAlmostEqual(w, 1 + mp.decay(1))
        self.assertAlmostEqual(wp / w, math.log(1.2))
        self.assertEqual(n, 2)
        self.assertAlmostEqual(ws, 1 + mp.decay(1))

    def test_rollup_profile_idempotent(self):
        w1 = mp.week_start(int(time.time())) - 6 * mp.WEEK
        self._week_rows(w1)
        self.store.rollup(w1 + 6 * mp.WEEK)
        before = self.store.profile(113)
        self.store.rollup(w1 + 6 * mp.WEEK)
        self.assertEqual(self.store.profile(113), before)
        self.assertEqual(self.store.profile(116), (None, {}))

    def test_read_profile_items_filter(self):
        w1 = mp.week_start(int(time.time())) - 6 * mp.WEEK
        self._week_rows(w1)
        self.store.rollup(w1 + 6 * mp.WEEK)
        upto, prof = self.store.profile(113)
        self.assertEqual(ms.read_profile(self.store.db, 113, [2589]), (upto, {2589: prof[2589]}))
        self.assertEqual(ms.read_profile(self.store.db, 113, [777]), (upto, {}))

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

    def test_record_writes_cheap(self):
        r = dict(row(90, 100, 10), cheap=4)
        self.store.record(113, 1000, {2589: r, 7: row(5, 5, 1)}, {8: 2}, {})
        got = self.store.db.execute("SELECT item, cheap FROM hourly ORDER BY item").fetchall()
        self.assertEqual(got, [(7, None), (8, None), (2589, 4)])

    def test_old_hourly_gains_cheap(self):
        path = os.path.join(self.dir.name, "old.db")
        db = sqlite3.connect(path)
        db.executescript("""CREATE TABLE hourly (house INTEGER, t INTEGER, item INTEGER,
            min INTEGER, market INTEGER, units INTEGER, listings INTEGER, sold INTEGER);
            INSERT INTO hourly VALUES (113, 1000, 5, 10, 12, 3, 1, 0);""")
        db.commit()
        db.close()
        store = ms.Store(path)
        store.record(113, 4600, {5: dict(row(10, 12, 3), cheap=2)}, {}, {})
        got = store.db.execute("SELECT t, cheap FROM hourly ORDER BY t").fetchall()
        store.close()
        self.assertEqual(got, [(1000, None), (4600, 2)])

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
