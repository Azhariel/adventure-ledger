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
        self.assertEqual(mr.market_value([10] * 6 + [11] * 4 + [100] * 10), 10)

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
