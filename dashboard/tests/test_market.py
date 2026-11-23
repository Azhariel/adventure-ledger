"""Tests for market.py (engine calculations).   Usage: python dashboard/tests/test_market.py"""
import math
import os
import shutil
import sqlite3
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


def B(rows, now):
    """The buckets the engine's SQL would make for these rows at `now`."""
    return m.day_buckets(rows, m.edges(now))


def shifted(rows):
    now = rows[-1][0]
    return m.shifted(B(rows, now), [r for r in rows if r[0] > now - m.C["SHIFT_HOURS"] * 3600], now)


class MarketTests(unittest.TestCase):
    def test_market_value_follows_a_jump_in_days(self):
        rows = hours(START, 14 * 24, 100) + hours(START + 14 * 86400, 72, 200, sold=1)
        now = rows[-1][0]
        self.assertTrue(160 < m.market_value(B(rows, now), now) < 200)
        flat = hours(START, 14 * 24, 100)
        self.assertEqual(m.market_value(B(flat, flat[-1][0]), flat[-1][0]), 100)

    def test_market_value_needs_min_snapshots(self):
        rows = hours(START, 5, 100)
        self.assertIsNone(m.market_value(B(rows, rows[-1][0]), rows[-1][0]))

    def test_trend_needs_both_ends(self):
        short = hours(START, 6 * 24, 100)
        self.assertIsNone(m.trend(B(short, short[-1][0]), short[-1][0]))
        # a +10% step; the trend lags it by design (recency-weighted value now vs a week ago) -> +0.08
        rows = hours(START, 7 * 24, 100) + hours(START + 7 * 86400, 7 * 24, 110)
        self.assertAlmostEqual(m.trend(B(rows, rows[-1][0]), rows[-1][0]), 0.08, delta=0.01)

    def test_trend_with_zero_market_a_week_ago_is_none(self):
        rows = hours(START, 7 * 24, 0) + hours(START + 7 * 86400, 7 * 24, 100)
        now = rows[-1][0]
        self.assertIsNone(m.trend(B(rows, now), now))

    def test_shifted_up_after_a_real_jump(self):
        jump = START + 12 * 86400
        rows = hours(START, 12 * 24, 100) + hours(jump, 36, 190, sold=1)
        got = shifted(rows)
        self.assertEqual(got["dir"], "up")
        self.assertAlmostEqual(got["pct"], 0.9, delta=0.05)
        self.assertEqual(got["since"], jump)

    def test_one_night_dump_is_not_a_shift(self):
        rows = hours(START, 14 * 24 - 8, 100) + hours(START + (14 * 24 - 8) * 3600, 8, 40, sold=1)
        self.assertIsNone(shifted(rows))

    def test_shifted_down_after_a_real_drop(self):
        rows = hours(START, 12 * 24, 100) + hours(START + 12 * 86400, 36, 50, sold=1)
        self.assertEqual(shifted(rows)["dir"], "down")

    def test_sales_in_sold_out_hours_count_toward_a_shift(self):
        start = START + 12 * 86400 - 8 * 3600
        jump = [(start + i * 3600, None, None, 0, 0, 1) if i % 8 == 0 else (start + i * 3600, 190, 190, 5, 3, 0)
                for i in range(44)]   # the only sales (6) happen in sold-out hours
        rows = hours(START, 12 * 24 - 8, 100) + jump
        self.assertEqual(shifted(rows)["dir"], "up")

    def test_sold_per_day(self):
        rows = hours(START, 14 * 24, 100, sold=2)
        self.assertAlmostEqual(m.sold_per_day(B(rows, rows[-1][0] + 3600), rows[-1][0] + 3600), 48, delta=1)
        young = hours(START, 3 * 24, 100, sold=1)
        self.assertAlmostEqual(m.sold_per_day(B(young, START + 3 * 86400), START + 3 * 86400), 24, delta=0.5)

    def test_shift_needs_sales(self):
        rows = hours(START, 12 * 24, 100) + hours(START + 12 * 86400, 36, 190)
        self.assertIsNone(shifted(rows))

    def _week_rows(self, days):
        rows = []
        for i in range(days * 24):
            t = START + i * 3600
            price = 120 if mp.cell(t) == (1, 20) else 100
            rows.append((t, price, price, 5, 3, 0))
        return rows

    def test_item_week_needs_two_weeks_and_most_cells(self):
        short = self._week_rows(9)
        self.assertIs(m.item_week(None, None, short, short[-1][0])["own"], False)
        rows = self._week_rows(15)
        got = m.item_week(None, None, rows, rows[-1][0])
        self.assertIs(got["own"], True)
        self.assertEqual(len(got["p"]), 168)
        self.assertAlmostEqual(got["p"][1 * 24 + 20], 0.2, delta=0.02)

    def test_item_week_partial_returns_cells_not_none(self):
        rows = self._week_rows(3)
        got = m.item_week(None, None, rows, rows[-1][0])
        self.assertIs(got["own"], False)
        self.assertTrue(any(v is not False for v in got["p"]))
        self.assertEqual(len(got["n"]), 168)

    def test_item_week_own_after_two_weeks(self):
        rows = self._week_rows(15)
        self.assertIs(m.item_week(None, None, rows, rows[-1][0])["own"], True)

    def test_item_week_p_has_two_decimals(self):
        rows = [(START + i * 3600, 100 + (i * 7) % 13, 100 + (i * 7) % 13, 5, 3, 0) for i in range(15 * 24)]
        got = m.item_week(None, None, rows, rows[-1][0])
        ps = [v for v in got["p"] if v is not False]
        self.assertTrue(any(v != 0 for v in ps))
        for v in ps:
            self.assertEqual(v, round(v, 2))

    def test_item_week_nothing_is_none(self):
        self.assertIsNone(m.item_week({}, None, [], START))

    def test_week_arrays_use_false_not_none(self):
        got = m.item_week(None, None, self._week_rows(3), START + 3 * 86400)
        self.assertNotIn(None, got["p"])
        self.assertNotIn(None, got["s"])
        hw = m.house_week([(START, 40)], {START: 4})
        self.assertNotIn(None, hw["listings"])
        self.assertNotIn(None, hw["sold"])
        self.assertNotIn(None, hw["n"])

    def test_read_wanted_bad_lines(self):
        text = "PvP Horde" + chr(9) + "2447" + chr(10) + chr(10) + "broken" + chr(10) + "PvP Horde" + chr(9) + "x" + chr(10) + "PvP Neutral" + chr(9) + "765" + chr(10)
        self.assertEqual(m.read_wanted(text), {"PvP Horde": {2447}, "PvP Neutral": {765}})

    def test_align_fills_false(self):
        self.assertEqual(m.align([10, 20, 30], [(10, 5, 6), (30, None, 7)], 1), [5, False, False])
        self.assertEqual(m.align([10, 30], [(10, 5, 6), (30, None, 7)], 2), [6, 7])

    def test_spark_and_daily_days(self):
        now = START + 40 * 86400
        d = m.spark_days(now)
        self.assertEqual(len(d), 14)
        self.assertEqual(d[-1], ms.local_day(now))
        self.assertEqual(len(m.daily_days(now)), 60)
        self.assertEqual(m.daily_days(now)[-1], ms.local_day(now))

    def test_item_week_combines_stored_and_recent(self):
        recent_start = START + 14 * 86400
        rows = hours(recent_start, 14 * 24, 100)
        now = rows[-1][0]
        stored = {(d, h): (0.0, 1.0, 0.0, 2) for d in range(7) for h in range(24)}
        stored[(1, 20)] = (math.log(1.2), 1.0, 0.0, 2)
        upto = recent_start - mp.WEEK
        got = m.item_week(stored, upto, rows, now)
        self.assertTrue(0 < got["p"][1 * 24 + 20] < 0.1)

    def test_summary_carries_cheap(self):
        rows = hours(START, 14 * 24, 100)
        latest = rows[-1][0]
        last = (latest, 100, 100, 77, 9, 0, 3)
        self.assertEqual(m.item_summary(B(rows, latest), rows[-48:], last, [100.0], latest)["cheap"], 3)
        unknown = (latest, 100, 100, 77, 9, 0, None)
        self.assertNotIn("cheap", m.item_summary(B(rows, latest), rows[-48:], unknown, [100.0], latest))
        self.assertNotIn("cheap", m.item_summary(B(rows, latest), rows[-48:], last[:6], [100.0], latest))

    def test_sold_out_item_summary(self):
        rows = hours(START, 14 * 24, 100)
        latest = rows[-1][0] + 3600
        got = m.item_summary(B(rows, latest), rows[-48:], None, [100.0], latest)
        self.assertNotIn("now", got)
        self.assertEqual(got["units"], 0)
        self.assertEqual(got["market"], 100)

    def test_sql_buckets_match_day_buckets(self):
        d = tempfile.mkdtemp()
        try:
            st = ms.Store(os.path.join(d, "market.db"))
            rows = [(START + i * 3600, None if i % 5 == 0 else 100 + i, None if i % 5 == 0 else 100 + i, 5, 3, i % 3)
                    for i in range(20 * 24 - 10)]   # ends at 13:00, so the edges split days
            st.db.executemany("INSERT INTO hourly (house, t, item, min, market, units, listings, sold) VALUES (113,?,7,?,?,?,?,?)", rows)
            st.db.commit()
            now = rows[-1][0]
            got = sorted((m.Bucket(day, lo, hi, wm, w, wt, n, int(sold), msum, low)
                          for _i, day, _s, lo, hi, wm, w, wt, n, sold, msum, low
                          in st.db.execute(m._buckets_sql(m.edges(now)), (113, now))),
                         key=lambda b: b.lo)
            st.close()
            self.assertEqual(got, B(rows, now))
            self.assertGreater(len(got), 20)   # split at the edges, not only by day
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_house_week_shape(self):
        snaps = [(START, 40), (START + 3600, 50)]
        got = m.house_week(snaps, {START: 4})
        self.assertEqual(len(got["listings"]), 168)
        self.assertEqual(len(got["sold"]), 168)
        self.assertEqual(got["listings"][0], 40)
        self.assertEqual(got["sold"][0], 4)

    def test_house_week_gold(self):
        snaps = [(START, 40), (START + 3600, 50)]
        got = m.house_week(snaps, {START: 4}, {START: 12345})
        self.assertEqual(len(got["gold"]), 168)
        self.assertEqual(got["gold"][0], 12345)
        self.assertIs(got["gold"][1], False)
        self.assertNotIn(None, got["gold"])

    def test_gold_by_hour_values_sales_at_the_items_market_value(self):
        # 100k arrows at 1c weigh less than 3 bars at 5g; an item without a market value adds nothing
        rows = [(START, 2512, 100000), (START, 12359, 3), (START + 3600, 999, 7), (START + 3600, 12359, 1)]
        got = m.gold_by_hour(rows, {2512: 1, 12359: 50000})
        self.assertEqual(got, {START: 100000 + 150000, START + 3600: 50000})

    def test_trade_values_leave_out_joke_prices(self):
        # 200 ordinary items at 1-200g; one listed at 220,000g that keeps "selling" (cancelled and relisted)
        items = {i: {"market": (i + 1) * 10000, "soldPerDay": 3} for i in range(200)}
        items[1414] = {"market": 220140 * 10000, "soldPerDay": 5.9}
        items[7] = {"market": 5000, "soldPerDay": 0}       # never sells: not part of the house's prices
        items[8] = {"soldPerDay": 4}                        # no market value: nothing to count it at
        got = m.trade_values(items)
        self.assertNotIn(1414, got)
        self.assertNotIn(8, got)
        self.assertEqual(got[199], 200 * 10000, "the dearest real item stays")
        self.assertEqual(got[7], 5000, "an item that hasn't sold yet still has its value")

    def test_house_week_counts_snapshots_per_cell(self):
        week = 7 * 86400
        snaps = [(START, 40), (START + week, 60), (START + 3600, 50)]
        got = m.house_week(snaps, {START: 4})
        self.assertEqual(len(got["n"]), 168)
        self.assertEqual(got["n"][0], 2)
        self.assertEqual(got["n"][1], 1)
        self.assertIs(got["n"][2], False)
        self.assertEqual(got["listings"][0], 50)


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

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_run_writes_cheap_and_format_4(self):
        self.store.record(113, self.NOW + 60, {2589: {"min": 100, "market": 110, "units": 5, "listings": 3,
                                                    "cheap": 2}}, {}, {})
        self.assertEqual(self.run_(), "written")
        with open(self.out, encoding="utf-8") as fh:
            self.assertTrue(fh.readline().startswith("-- sig: f=4|"))
        code = "dofile([[%s]]) print(LedgerMarket.houses[113].items[2589].cheap)" % self.out.replace("\\", "/")
        got = subprocess.run([LUA, "-e", code], capture_output=True, text=True)
        self.assertEqual(got.stdout.strip(), "2", got.stderr)

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_run_reads_a_db_without_cheap(self):
        self.store.close()
        db = sqlite3.connect(self.db)
        db.execute("ALTER TABLE hourly DROP COLUMN cheap")
        db.commit()
        db.close()
        self.store = ms.Store.__new__(ms.Store)
        self.store.db = sqlite3.connect(":memory:")   # tearDown closes it; the engine reads the file read-only
        self.assertEqual(self.run_(), "written")
        code = "dofile([[%s]]) print(LedgerMarket.houses[113].items[2589].cheap)" % self.out.replace("\\", "/")
        got = subprocess.run([LUA, "-e", code], capture_output=True, text=True)
        self.assertEqual(got.stdout.strip(), "nil", got.stderr)

    def test_run_survives_zero_prices(self):
        for i in range(10 * 24):
            t = self.NOW - 10 * 86400 + i * 3600
            self.store.record(113, t + 60, {3000: {"min": 0, "market": 0, "units": 5, "listings": 3}}, {3000: 1}, {})
        self.assertEqual(self.run_(), "written")
        with open(self.out, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('["market"]=110', text)
        self.assertIn("[3000]", text)
        item = text.split("[3000]", 1)[1].split("[2589]", 1)[0]
        self.assertNotIn('["trend"]', item)

    def test_stamp_carries_format(self):
        db = m.open_ro(self.db)
        try:
            self.assertTrue(m.stamp(db, {}, "").startswith("-- sig: f=4|"))
        finally:
            db.close()

    def test_run_leaves_the_item_week_out(self):
        self.assertEqual(self.run_(), "written")
        with open(self.out, encoding="utf-8") as fh:
            text = fh.read()
        self.assertEqual(text.count('["week"]='), 1)   # the house's only
        self.assertIn('["market"]=110', text)

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_a_recording_in_progress_is_not_read(self):
        # the snapshot at T is whole; hourly rows at T+1h have no snapshot row yet (the fetcher is recording)
        t = self.NOW + 1800
        self.store.db.execute("INSERT INTO snapshot VALUES (113, ?, 2, 2)", (t,))
        self.store.db.executemany("INSERT INTO hourly (house, t, item, min, market, units, listings, sold) VALUES (?,?,?,?,?,?,?,?)", [
            (113, t, 2589, 100, 110, 5, 3, 1), (113, t, 777, 50, 55, 2, 1, 0),
            (113, t + 3600, 2589, 90, 95, 4, 2, 50), (113, t + 3600, 777, 40, 45, 1, 1, 50)])
        self.store.db.commit()
        self.assertEqual(m.run(self.db, self.out, {}, now=t + 3600 + 60), "written")
        code = ("dofile([[%s]]) local h = LedgerMarket.houses[113] "
                "print(h.latest, h.recent[1].t, h.items[2589].now, h.items[777].now, h.items[2589].soldPerDay, "
                "h.items[777].soldPerDay)") % self.out.replace("\\", "/")
        got = subprocess.run([LUA, "-e", code], capture_output=True, text=True)
        # 2589 sold 1 in each of the 9 recorded hours; the unrecorded hour's 50 sales are not read
        self.assertEqual(got.stdout.split(), [str(t), str(t), "100", "50", "9.0", "0.0"], got.stderr)

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


class HistoryTests(unittest.TestCase):
    NOW = START + 20 * 86400

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.store = ms.Store(os.path.join(self.dir, "market.db"))
        for i in range(48):
            self.store.record(113, self.NOW - (47 - i) * 3600,
                              {2589: {"min": 100, "market": 110, "units": 5, "listings": 3}}, {2589: 1}, {})
        self.store.db.execute("INSERT INTO daily VALUES (113, '2026-09-01', 2589, 90, 95.4, 4, 2, 24, 24)")
        self.store.db.commit()
        self.db = m.open_ro(os.path.join(self.dir, "market.db"))

    def tearDown(self):
        self.db.close()
        self.store.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_history_shapes(self):
        h = m.history(self.db, 113, 2589, self.NOW)
        self.assertEqual((h["house"], h["item"]), (113, 2589))
        self.assertEqual(len(h["hourly"]), 48)
        self.assertEqual(h["hourly"][-1], [self.NOW, 100, 110, 5])
        self.assertEqual(h["daily"][0], ["2026-09-01", 90, 95])           # the daily table, oldest first
        self.assertTrue(all(d[2] == 110 and d[1] == 100 for d in h["daily"][1:]))   # hourly days
        self.assertEqual([d[0] for d in h["daily"]], sorted(d[0] for d in h["daily"]))
        self.assertIs(h["week"]["own"], False)

    def test_history_hourly_wins_over_daily(self):
        day = h_day = m.market_store.local_day(self.NOW)
        self.store.db.execute("INSERT INTO daily VALUES (113, ?, 2589, 1, 1, 1, 0, 24, 24)", (day,))
        self.store.db.commit()
        got = {d[0]: d for d in m.history(self.db, 113, 2589, self.NOW)["daily"]}
        self.assertEqual(got[h_day][2], 110)

    def test_history_unknown_is_empty(self):
        h = m.history(self.db, 113, 999, self.NOW)
        self.assertEqual((h["hourly"], h["daily"], h["week"]), ([], [], None))
        self.assertEqual(m.history(self.db, 5, 2589, self.NOW)["hourly"], [])


class SeriesTests(unittest.TestCase):
    """market.lua's grids, series and sparklines (wanted items only for the heavy ones)."""
    NOW = START + 20 * 86400
    CFG = {"ah_houses": "PvP 113"}
    GAP = NOW - 30 * 3600   # 2589 sold out in this hour

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = os.path.join(self.dir, "market.db")
        self.out = os.path.join(self.dir, "market.lua")
        self.wanted = os.path.join(self.dir, "market_wanted.tsv")
        self.store = ms.Store(self.db)
        for i in range(72):
            t = self.NOW - (71 - i) * 3600
            rows = {777: {"min": 50, "market": 55, "units": 2, "listings": 1}}
            if t != self.GAP:
                rows[2589] = {"min": 100, "market": 110, "units": 5, "listings": 3}
            self.store.record(113, t, rows, {2589: 2, 777: 1}, {1: (2589, 5, "L")})

    def tearDown(self):
        self.store.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def want(self, *items):
        with open(self.wanted, "w", encoding="utf-8") as fh:
            fh.write("".join("PvP Horde\t%d\n" % i for i in items))

    def run_(self):
        return m.run(self.db, self.out, self.CFG, now=self.NOW + 60)

    def text(self):
        with open(self.out, encoding="utf-8") as fh:
            return fh.read()

    def lua(self, code):
        got = subprocess.run([LUA, "-e", "dofile([[%s]]) local h = LedgerMarket.houses[113] %s"
                              % (self.out.replace("\\", "/"), code)], capture_output=True, text=True)
        self.assertEqual(got.stderr, "")
        return got.stdout.split()

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_run_writes_series_for_wanted_items_only(self):
        self.want(2589)
        self.assertEqual(self.run_(), "written")
        got = self.lua("local a, b = h.items[2589], h.items[777] "
                       "print(a.hourly ~= nil, a.daily ~= nil, a.week ~= nil, b.hourly, b.daily, b.week, "
                       "#a.spark, #b.spark, #h.sparkDays, #a.hourly.min, #a.hourly.market, #h.ts, "
                       "#a.daily.market, #a.daily.min, #h.seriesDays, a.spark[14], a.daily.min[60])")
        self.assertEqual(got, ["true", "true", "true", "nil", "nil", "nil", "14", "14", "14",
                               "72", "72", "72", "60", "60", "60", "110", "100"])

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_series_cap_keeps_best_sellers(self):
        self.want(777, 2589)
        with mock.patch.dict(m.C, {"SERIES_MAX_ITEMS": 1}):
            self.assertEqual(self.run_(), "written")
        self.assertEqual(self.lua("print(h.items[2589].hourly ~= nil, h.items[777].hourly)"), ["true", "nil"])

    def test_wanted_change_rewrites(self):
        self.want(2589)
        self.assertEqual(self.run_(), "written")
        self.assertEqual(self.run_(), "unchanged")
        self.want(777)
        self.assertEqual(self.run_(), "written")
        self.assertEqual(self.run_(), "unchanged")
        with open(self.out, encoding="utf-8") as fh:
            head = fh.readline().rstrip("\n")
        db = m.open_ro(self.db)
        try:
            self.assertEqual(head, m.stamp(db, {113: "PvP Horde"}, "PvP Horde\t777\n"))
        finally:
            db.close()
        self.assertRegex(head, r"^-- sig: f=4\|113:\d+:\|113=PvP Horde\|w=[0-9a-f]{12}$")

    def test_missing_wanted_file_still_writes(self):
        self.assertEqual(self.run_(), "written")
        text = self.text()
        self.assertNotIn('["hourly"]', text)
        self.assertIn('["spark"]', text)
        self.assertIn('["seriesDays"]', text)

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_sold_out_hours_are_false_in_hourly(self):
        self.want(2589)
        self.assertEqual(self.run_(), "written")
        got = self.lua("for k, t in ipairs(h.ts) do if t == %d then "
                       "print(h.items[2589].hourly.min[k], h.items[2589].hourly.market[k]) end end "
                       "print(h.items[2589].hourly.min[1])" % self.GAP)
        self.assertEqual(got, ["false", "false", "100"])

    def test_no_nil_holes(self):
        self.want(2589, 777)
        self.assertEqual(self.run_(), "written")
        text = self.text()
        for key in ('["hourly"]', '["daily"]', '["spark"]', '["week"]'):
            self.assertIn(key, text)
        self.assertGreaterEqual(text.count('["own"]='), 2)   # both items' own week, not only the house's
        self.assertNotRegex(text, r"[{,]nil[,}]")

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_daily_table_fills_folded_days_and_hourly_wins(self):
        old, today = ms.local_day(self.NOW - 10 * 86400), ms.local_day(self.NOW)
        self.store.db.executemany("INSERT INTO daily VALUES (113,?,2589,?,?,5,1,24,24)",
                                  [(old, 70, 77.0), (today, 900, 999.0)])
        self.store.db.commit()
        self.want(2589)
        self.assertEqual(self.run_(), "written")
        got = self.lua("local a = h.items[2589] for k, d in ipairs(h.sparkDays) do "
                       "if d == '%s' or d == '%s' then print(a.spark[k]) end end "
                       "for k, d in ipairs(h.seriesDays) do "
                       "if d == '%s' or d == '%s' then print(a.daily.market[k], a.daily.min[k]) end end"
                       % (old, today, old, today))
        self.assertEqual(got, ["77", "110", "77", "70", "110", "100"])


if __name__ == "__main__":
    unittest.main()
