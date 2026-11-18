"""Tests for market.py (engine calculations).   Usage: python dashboard/tests/test_market.py"""
import math
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import market as m  # noqa: E402
import market_profile as mp  # noqa: E402

START = int(time.mktime((2026, 10, 5, 0, 0, 0, 0, 0, -1)))   # a Monday 00:00


def hours(start, n, market, sold=0):
    return [(start + i * 3600, market, market, 5, 3, sold) for i in range(n)]


class MarketTests(unittest.TestCase):
    def test_market_value_follows_a_jump_in_days(self):
        rows = hours(START, 14 * 24, 100) + hours(START + 14 * 86400, 72, 200, sold=1)
        now = rows[-1][0]
        self.assertTrue(160 < m.market_value(rows, now) < 200)
        flat = hours(START, 14 * 24, 100)
        self.assertEqual(m.market_value(flat, flat[-1][0]), 100)

    def test_market_value_needs_min_snapshots(self):
        rows = hours(START, 5, 100)
        self.assertIsNone(m.market_value(rows, rows[-1][0]))

    def test_trend_needs_both_ends(self):
        short = hours(START, 6 * 24, 100)
        self.assertIsNone(m.trend(short, short[-1][0]))
        # a +10% step; the trend lags it by design (recency-weighted value now vs a week ago) -> +0.08
        rows = hours(START, 7 * 24, 100) + hours(START + 7 * 86400, 7 * 24, 110)
        self.assertAlmostEqual(m.trend(rows, rows[-1][0]), 0.08, delta=0.01)

    def test_shifted_up_after_a_real_jump(self):
        jump = START + 12 * 86400
        rows = hours(START, 12 * 24, 100) + hours(jump, 36, 190, sold=1)
        got = m.shifted(rows, rows[-1][0])
        self.assertEqual(got["dir"], "up")
        self.assertAlmostEqual(got["pct"], 0.9, delta=0.05)
        self.assertEqual(got["since"], jump)

    def test_one_night_dump_is_not_a_shift(self):
        rows = hours(START, 14 * 24 - 8, 100) + hours(START + (14 * 24 - 8) * 3600, 8, 40, sold=1)
        self.assertIsNone(m.shifted(rows, rows[-1][0]))

    def test_shifted_down_after_a_real_drop(self):
        rows = hours(START, 12 * 24, 100) + hours(START + 12 * 86400, 36, 50, sold=1)
        self.assertEqual(m.shifted(rows, rows[-1][0])["dir"], "down")

    def test_sales_in_sold_out_hours_count_toward_a_shift(self):
        start = START + 12 * 86400 - 8 * 3600
        jump = [(start + i * 3600, None, None, 0, 0, 1) if i % 8 == 0 else (start + i * 3600, 190, 190, 5, 3, 0)
                for i in range(44)]   # the only sales (6) happen in sold-out hours
        rows = hours(START, 12 * 24 - 8, 100) + jump
        self.assertEqual(m.shifted(rows, rows[-1][0])["dir"], "up")

    def test_sold_per_day(self):
        rows = hours(START, 14 * 24, 100, sold=2)
        self.assertAlmostEqual(m.sold_per_day(rows, rows[-1][0] + 3600), 48, delta=1)
        young = hours(START, 3 * 24, 100, sold=1)
        self.assertAlmostEqual(m.sold_per_day(young, START + 3 * 86400), 24, delta=0.5)

    def test_shift_needs_sales(self):
        rows = hours(START, 12 * 24, 100) + hours(START + 12 * 86400, 36, 190)
        self.assertIsNone(m.shifted(rows, rows[-1][0]))

    def _week_rows(self, days):
        rows = []
        for i in range(days * 24):
            t = START + i * 3600
            price = 120 if mp.cell(t) == (1, 20) else 100
            rows.append((t, price, price, 5, 3, 0))
        return rows

    def test_item_week_needs_two_weeks_and_most_cells(self):
        short = self._week_rows(9)
        self.assertIsNone(m.item_week(None, None, short, short[-1][0]))
        rows = self._week_rows(15)
        got = m.item_week(None, None, rows, rows[-1][0])
        self.assertIsNotNone(got)
        self.assertEqual(len(got["p"]), 168)
        self.assertAlmostEqual(got["p"][1 * 24 + 20], 0.2, delta=0.02)

    def test_item_week_combines_stored_and_recent(self):
        recent_start = START + 14 * 86400
        rows = hours(recent_start, 14 * 24, 100)
        now = rows[-1][0]
        stored = {(d, h): (0.0, 1.0, 0.0, 2) for d in range(7) for h in range(24)}
        stored[(1, 20)] = (math.log(1.2), 1.0, 0.0, 2)
        upto = recent_start - mp.WEEK
        got = m.item_week(stored, upto, rows, now)
        self.assertTrue(0 < got["p"][1 * 24 + 20] < 0.1)

    def test_sold_out_item_summary(self):
        rows = hours(START, 14 * 24, 100)
        latest = rows[-1][0] + 3600
        got = m.item_summary(rows, [100.0], None, None, latest, latest)
        self.assertNotIn("now", got)
        self.assertEqual(got["units"], 0)
        self.assertEqual(got["market"], 100)

    def test_house_week_shape(self):
        snaps = [(START, 40), (START + 3600, 50)]
        got = m.house_week(snaps, {START: 4})
        self.assertEqual(len(got["listings"]), 168)
        self.assertEqual(len(got["sold"]), 168)
        self.assertEqual(got["listings"][0], 40)
        self.assertEqual(got["sold"][0], 4)


if __name__ == "__main__":
    unittest.main()
