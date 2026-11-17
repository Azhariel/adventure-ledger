"""Tests for market_reduce.py (snapshot to per-item rows).   Usage: python dashboard/tests/test_market_reduce.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import market_reduce as mr  # noqa: E402


class MarketValueTests(unittest.TestCase):
    def test_market_uniform(self):
        self.assertEqual(mr.market_value([100] * 20), 100)

    def test_market_ignores_expensive_tail(self):
        self.assertEqual(mr.market_value([5] * 3 + [50] * 17), 5)

    def test_market_extends_to_30pct(self):
        # 20 units: starts with the cheapest 3, takes the 4th-6th (each under 1.2x the one before),
        # stops at 6 (30%) although the 7th is close too. 66/6 = 11; 3 units: 10; 7 units: 81/7 = 12.
        self.assertEqual(mr.market_value([10, 10, 10, 11, 12, 13, 15] + [100] * 13), 11)

    def test_market_extension_stops_at_a_jump(self):
        # 23 < 1.2 x 20 joins, 30 >= 1.2 x 23 stops it: 83/4 = 21 (3 units: 20; 6 units: 143/6 = 24).
        self.assertEqual(mr.market_value([20, 20, 20, 23, 30, 30] + [200] * 14), 21)

    def test_market_single(self):
        self.assertEqual(mr.market_value([7]), 7)


class ReduceTests(unittest.TestCase):
    def test_reduce_mixes_endpoints(self):
        auctions = [
            {"id": 1, "item": {"id": 2589}, "quantity": 4, "buyout": 400},
            {"id": 2, "item": {"id": 2589}, "quantity": 1, "bid": 50},
        ]
        commodities = [{"id": 3, "item": {"id": 2589}, "quantity": 10, "unit_price": 90}]
        self.assertEqual(mr.reduce(auctions, commodities),
                         {2589: {"min": 90, "market": 90, "units": 15, "listings": 3}})

    def test_reduce_skips_zero_quantity(self):
        auctions = [{"id": 1, "item": {"id": 7}, "quantity": 0, "buyout": 400},
                    {"id": 2, "item": {"id": 7}, "quantity": 2, "buyout": 100},
                    {"id": 3, "item": {"id": 8}, "quantity": -1, "buyout": 5}]
        commodities = [{"id": 4, "item": {"id": 9}, "quantity": 0, "unit_price": 3}]
        self.assertEqual(mr.reduce(auctions, commodities),
                         {7: {"min": 50, "market": 50, "units": 2, "listings": 1}})

    def test_snapshot_ids(self):
        auctions = [{"id": 1, "item": {"id": 5}, "quantity": 2, "buyout": 10, "time_left": "LONG"}]
        commodities = [{"id": 3, "item": {"id": 6}, "quantity": 7, "unit_price": 1, "time_left": "SHORT"}]
        self.assertEqual(mr.snapshot_ids(auctions, commodities),
                         {1: (5, 2, "LONG"), 3: (6, 7, "SHORT")})


class EstimateSoldTests(unittest.TestCase):
    def test_estimate_sold_long_vanished(self):
        self.assertEqual(mr.estimate_sold({1: (2589, 5, "LONG")}, {}, 3600), {2589: 5})

    def test_estimate_sold_medium_vanished_not_counted(self):
        self.assertEqual(mr.estimate_sold({1: (2589, 5, "MEDIUM")}, {}, 3600), {})

    def test_estimate_sold_partial_commodity(self):
        self.assertEqual(mr.estimate_sold({3: (2589, 10, "VERY_LONG")}, {3: (2589, 4, "VERY_LONG")}, 3600),
                         {2589: 6})


if __name__ == "__main__":
    unittest.main()
