"""Tests for market_profile.py (hour-of-week profile).   Usage: python dashboard/tests/test_market_profile.py"""
import math
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import market_profile as mp  # noqa: E402


def at(day, hour, minute=0):
    """Local time on Monday 2026-11-16 + day."""
    return int(time.mktime((2026, 11, 16 + day, hour, minute, 0, 0, 0, -1)))


def week(prices, sold=0):
    return [(at(d, h), m, sold) for (d, h), m in prices.items()]


class ProfileTests(unittest.TestCase):
    def test_week_start_and_cell(self):
        t = at(2, 20, 30)   # Wednesday
        self.assertEqual(mp.week_start(t), at(0, 0))
        self.assertEqual(mp.cell(t), (2, 20))

    def test_contrib_relative_to_week_median(self):
        prices = {(d, h): 100 for d in range(7) for h in (10, 20)}
        prices[(1, 20)] = 120
        got = mp.week_contrib(week(prices))
        self.assertAlmostEqual(got[(1, 20)][0], math.log(1.2))
        self.assertEqual(got[(3, 10)][0], 0)
        self.assertEqual(got[(1, 20)][2], 1)

    def test_contrib_caps_a_dump(self):
        prices = {(d, 12): 100 for d in range(7)}
        prices[(4, 12)] = 10
        self.assertEqual(mp.week_contrib(week(prices))[(4, 12)][0], -mp.CAP)

    def test_contrib_sums_sold(self):
        obs = [(at(0, 9), 100, 2), (at(0, 9, 30), None, 3), (at(1, 9), 100, 0)]
        self.assertEqual(mp.week_contrib(obs)[(0, 9)][1:], (5, 1))

    def test_unpriced_week_gives_nothing(self):
        self.assertEqual(mp.week_contrib([(at(0, 9), None, 4), (at(1, 9), None, 1)]), {})

    def test_decay_half_every_two_weeks(self):
        self.assertEqual(mp.decay(2), 0.5)
        self.assertEqual(mp.decay(0), 1)


if __name__ == "__main__":
    unittest.main()
