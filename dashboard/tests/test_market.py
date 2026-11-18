"""Tests for market.py (engine calculations).   Usage: python dashboard/tests/test_market.py"""
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import market as m  # noqa: E402
import market_profile as mp  # noqa: E402
import market_store as ms  # noqa: E402

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


LUA = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Lua", "bin", "lua.exe")
if not os.path.isfile(LUA):
    LUA = shutil.which("lua")


class ToLuaTests(unittest.TestCase):
    def test_to_lua_round_trip_shape(self):
        self.assertEqual(m.to_lua({"a": 1, 2: [1.5, None, 'x"y']}), '{["a"]=1,[2]={1.5,nil,"x\\"y"}}')

    def test_nan_inf_and_none_are_never_written(self):
        got = m.to_lua({"a": float("nan"), "b": float("inf"), "c": None, "d": 2.5, "e": [float("-inf"), 1]})
        self.assertEqual(got, '{["d"]=2.5,["e"]={nil,1}}')

    def test_strings_are_escaped(self):
        self.assertEqual(m.to_lua("a\\b\nc\x01"), r'"a\\b\nc\001"')
        self.assertEqual(m.to_lua({"k\"": True}), '{["k\\""]=true}')


class RunTests(unittest.TestCase):
    NOW = START + 20 * 86400

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = os.path.join(self.dir, "market.db")
        self.out = os.path.join(self.dir, "market.lua")
        self.store = ms.Store(self.db)
        for i in range(8):
            self.snap(self.NOW - (7 - i) * 3600)

    def tearDown(self):
        self.store.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def snap(self, t, house=113):
        self.store.record(house, t, {2589: {"min": 100, "market": 110, "units": 5, "listings": 3}}, {2589: 1}, {1: (2589, 5, "L")})

    def run_(self, cfg=None):
        return m.run(self.db, self.out, cfg or {}, now=self.NOW + 3600)

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_run_writes_then_skips_unchanged(self):
        self.assertEqual(self.run_(), "written")
        with open(self.out, encoding="utf-8") as fh:
            self.assertTrue(fh.readline().startswith("-- sig:"))
        code = "dofile([[%s]]) print(LedgerMarket.houses[113].items[2589].market)" % self.out.replace("\\", "/")
        got = subprocess.run([LUA, "-e", code], capture_output=True, text=True)
        self.assertEqual(got.stdout.strip(), "110", got.stderr)
        before = os.stat(self.out).st_mtime_ns
        self.assertEqual(self.run_(), "unchanged")
        self.assertEqual(os.stat(self.out).st_mtime_ns, before)

    def test_run_new_snapshot_rewrites(self):
        self.assertEqual(self.run_(), "written")
        self.snap(self.NOW + 1800)
        self.assertEqual(self.run_(), "written")

    def test_run_new_house_config_rewrites(self):
        self.assertEqual(self.run_(), "written")
        self.assertEqual(self.run_({"ah_houses": "PvP 113"}), "written")
        with open(self.out, encoding="utf-8") as fh:
            self.assertIn('["key"]="PvP Horde"', fh.read())

    def test_run_no_db_is_no_data(self):
        self.assertEqual(m.run(os.path.join(self.dir, "nope.db"), self.out, {}), "no data")
        self.assertFalse(os.path.exists(self.out))

    def test_run_secret_never_written(self):
        self.run_({"bnet_secret": "S3CRET", "bnet_client": "CLIENTID"})
        with open(self.out, encoding="utf-8") as fh:
            text = fh.read()
        self.assertNotIn("S3CRET", text)
        self.assertNotIn("CLIENTID", text)

    def test_run_reads_a_db_from_before_the_profile_tables(self):
        for table in ("profile", "profile_state", "daily"):
            self.store.db.execute("DROP TABLE " + table)
        self.store.db.commit()
        self.assertEqual(self.run_(), "written")

    def test_failed_replace_leaves_no_temp_file_and_the_old_output(self):
        self.assertEqual(self.run_(), "written")
        with open(self.out, encoding="utf-8") as fh:
            old = fh.read()
        self.snap(self.NOW + 1800)
        with mock.patch("os.replace", side_effect=PermissionError), mock.patch("time.sleep"):
            with self.assertRaises(PermissionError):
                self.run_()
        self.assertEqual([f for f in os.listdir(self.dir) if f.endswith(".tmp")], [])
        with open(self.out, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), old)

    def test_run_leaves_the_db_alone(self):
        self.run_()
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM snapshot").fetchone()[0], 8)
        self.assertEqual(m.signature(m.open_ro(self.db)), "113:%d:" % (self.NOW))


if __name__ == "__main__":
    unittest.main()
