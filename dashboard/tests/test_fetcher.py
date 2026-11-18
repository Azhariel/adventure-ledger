"""Tests for fetcher.py.   Usage: python dashboard/tests/test_fetcher.py"""
import json
import logging
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

HERE_TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE_TESTS, ".."))
import bnet  # noqa: E402
import fetcher  # noqa: E402
import market_store  # noqa: E402
import server  # noqa: E402

LOG = logging.getLogger("test_fetcher")
LOG.addHandler(logging.NullHandler())
LOG.propagate = False


def auction(aid, item, qty=4, buyout=400, left="LONG"):
    return {"id": aid, "item": {"id": item}, "quantity": qty, "buyout": buyout, "time_left": left}


class FakeClient:
    """Like bnet.Client.house_since. data: house -> (auctions, commodities[, snapshot time]) or an exception.
    With a snapshot time no newer than `since`, answers "not modified" (None), as Blizzard's 304."""
    def __init__(self, data):
        self.data = data
        self.asked = []   # (house, since) per call
        self.ignore_since = False

    def house_since(self, h, since):
        self.asked.append((h, since))
        got = self.data[h]
        if isinstance(got, Exception):
            raise got
        auctions, commodities, *mod = got
        mod = mod[0] if mod else None
        if since is not None and mod is not None and mod <= since and not self.ignore_since:
            return None
        return auctions, commodities, mod


class FetcherTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = market_store.Store(os.path.join(self.dir.name, "market.db"))

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def test_status_carries_house_key(self):
        c = FakeClient({113: ([auction(1, 10)], [])})
        st = fetcher.run_once(c, self.store, [113], 1000, LOG, keys={113: "PvP Horde"})
        self.assertEqual(st["houses"]["113"]["key"], "PvP Horde")

    def test_run_once_records_both(self):
        c = FakeClient({113: ([auction(1, 10)], []), 116: ([auction(2, 20), auction(3, 21)], [])})
        st = fetcher.run_once(c, self.store, [113, 116], 1000, LOG)
        self.assertEqual(st["houses"]["113"], {"ok": True, "t": 1000, "items": 1})
        self.assertEqual(st["houses"]["116"], {"ok": True, "t": 1000, "items": 2})
        self.assertEqual(st["last_ok"], 1000)
        self.assertIsNone(st["error"])
        self.assertEqual(self.store.db.execute("SELECT COUNT(DISTINCT house) FROM hourly").fetchone()[0], 2)

    def test_one_house_fails(self):
        c = FakeClient({113: ([auction(1, 10)], []), 116: bnet.ApiError(503, "/auctions/116")})
        st = fetcher.run_once(c, self.store, [113, 116], 1000, LOG)
        self.assertTrue(st["houses"]["113"]["ok"])
        self.assertFalse(st["houses"]["116"]["ok"])
        self.assertIn("116", st["error"])
        self.assertIn("503", st["error"])
        self.assertEqual(st["last_ok"], 1000)

    def test_both_fail_keeps_last_ok(self):
        c = FakeClient({113: bnet.ApiError(503, "x"), 116: ValueError("not json")})
        self.assertIsNone(fetcher.run_once(c, self.store, [113, 116], 1000, LOG)["last_ok"])
        self.assertEqual(fetcher.run_once(c, self.store, [113, 116], 2000, LOG, last_ok=500)["last_ok"], 500)

    def test_unchanged_snapshot_skipped(self):
        c = FakeClient({113: ([auction(1, 10)], [])})
        fetcher.run_once(c, self.store, [113], 1000, LOG)
        st = fetcher.run_once(c, self.store, [113], 4600, LOG)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM snapshot").fetchone()[0], 1)
        self.assertEqual(st["houses"]["113"], {"ok": True, "t": 1000, "items": 1})

    def test_sold_uses_previous(self):
        c = FakeClient({113: ([auction(1, 10, qty=4), auction(2, 11)], [])})
        fetcher.run_once(c, self.store, [113], 1000, LOG)
        c.data[113] = ([auction(2, 11)], [])   # auction 1 vanished (LONG, so not expired)
        fetcher.run_once(c, self.store, [113], 1000 + 3600, LOG)
        sold = self.store.db.execute("SELECT sold FROM hourly WHERE item=10 AND t=4600").fetchone()
        self.assertEqual(sold, (4,))

    def snapshots(self):
        return self.store.db.execute("SELECT COUNT(*) FROM snapshot").fetchone()[0]

    def test_quantity_change_alone_is_recorded(self):
        def com(qty):
            return {"id": 9, "item": {"id": 30}, "quantity": qty, "unit_price": 5, "time_left": "LONG"}
        c = FakeClient({113: ([], [com(10)])})
        fetcher.run_once(c, self.store, [113], 1000, LOG)
        c.data[113] = ([], [com(7)])   # same auction id, 3 units bought
        st = fetcher.run_once(c, self.store, [113], 4600, LOG)
        self.assertEqual(self.snapshots(), 2)
        self.assertEqual(st["houses"]["113"]["t"], 4600)
        self.assertEqual(self.store.db.execute("SELECT sold FROM hourly WHERE item=30 AND t=4600").fetchone(), (3,))

    def test_shrunken_snapshot_skipped(self):
        # A missing or cut-short list would make every LONG auction look sold.
        full = [auction(i, 10) for i in range(1000)]
        c = FakeClient({113: (full, [])})
        fetcher.run_once(c, self.store, [113], 1000, LOG)
        c.data[113] = (full[:499], [])
        with self.assertLogs(LOG, "WARNING") as logs:
            st = fetcher.run_once(c, self.store, [113], 4600, LOG, last_ok=1000)
        self.assertIn("499", logs.output[0])
        self.assertFalse(st["houses"]["113"]["ok"])
        self.assertIn("499", st["error"])
        self.assertEqual(st["last_ok"], 1000)
        self.assertEqual(self.snapshots(), 1)
        self.assertEqual(len(self.store.last_ids(113)[1]), 1000)
        c.data[113] = (full[:500], [])   # half is still believable
        self.assertTrue(fetcher.run_once(c, self.store, [113], 8200, LOG)["houses"]["113"]["ok"])
        self.assertEqual(self.snapshots(), 2)

    def test_shrink_after_a_long_gap_is_accepted(self):
        # The PC was off for a day: the house may really have halved since, so the check doesn't apply.
        full = [auction(i, 10) for i in range(1000)]
        c = FakeClient({113: (full, [])})
        fetcher.run_once(c, self.store, [113], 1000, LOG, every=60)
        c.data[113] = (full[:400], [])
        st = fetcher.run_once(c, self.store, [113], 1000 + 86400, LOG, every=60)
        self.assertTrue(st["houses"]["113"]["ok"])
        self.assertEqual(self.snapshots(), 2)

    def test_shrink_that_lasts_is_accepted_after_three_skips(self):
        full = [auction(i, 10) for i in range(1000)]
        c = FakeClient({113: (full, [])})
        skips = {}
        fetcher.run_once(c, self.store, [113], 1000, LOG, every=60, skips=skips)
        c.data[113] = (full[:400], [])
        t = 1000
        with self.assertLogs(LOG, "WARNING"):
            for _ in range(fetcher.SHRINK_SKIPS):
                t += 3600
                self.assertFalse(fetcher.run_once(c, self.store, [113], t, LOG, every=60, skips=skips)
                                 ["houses"]["113"]["ok"])
        self.assertEqual(self.snapshots(), 1)
        t += 3600
        self.assertTrue(fetcher.run_once(c, self.store, [113], t, LOG, every=60, skips=skips)["houses"]["113"]["ok"])
        self.assertEqual(self.snapshots(), 2)
        self.assertEqual(skips.get(113, 0), 0, "a recorded snapshot resets the count")

    def test_small_house_may_empty(self):
        c = FakeClient({113: ([auction(i, 10) for i in range(999)], [])})
        fetcher.run_once(c, self.store, [113], 1000, LOG)
        c.data[113] = ([], [])
        self.assertTrue(fetcher.run_once(c, self.store, [113], 4600, LOG)["houses"]["113"]["ok"])
        self.assertEqual(self.snapshots(), 2)

    def test_not_modified_records_nothing(self):
        c = FakeClient({113: ([auction(1, 10)], [], 900)})
        fetcher.run_once(c, self.store, [113], 1000, LOG)
        with self.assertLogs(LOG, "INFO") as logs:
            st = fetcher.run_once(c, self.store, [113], 1600, LOG, last_ok=1000)
        self.assertEqual(c.asked[-1], (113, 900), "asks for data newer than the last snapshot")
        self.assertEqual(self.snapshots(), 1)
        self.assertEqual(st["houses"]["113"], {"ok": True, "t": 900, "items": 1})
        self.assertEqual(st["last_ok"], 1600, "a 304 is a good fetch")
        self.assertIn("not modified", logs.output[0])

    def test_snapshot_is_dated_by_blizzard(self):
        c = FakeClient({113: ([auction(1, 10, qty=4), auction(2, 11)], [], 900)})
        st = fetcher.run_once(c, self.store, [113], 1000, LOG)
        self.assertEqual(st["houses"]["113"]["t"], 900)
        c.data[113] = ([auction(2, 11)], [], 900 + 3600)
        fetcher.run_once(c, self.store, [113], 1000 + 3600 + 1200, LOG)
        self.assertEqual(self.store.db.execute("SELECT t FROM snapshot ORDER BY t").fetchall(), [(900,), (4500,)])
        self.assertEqual(self.store.db.execute("SELECT sold FROM hourly WHERE item=10 AND t=4500").fetchone(), (4,))

    def test_snapshot_time_falls_back_to_the_fetch_time(self):
        # no Last-Modified, one in the future, or one not after the last snapshot: use the fetch time
        c = FakeClient({113: ([auction(1, 10)], [], None)})
        self.assertEqual(fetcher.run_once(c, self.store, [113], 1000, LOG)["houses"]["113"]["t"], 1000)
        c.data[113] = ([auction(2, 10)], [], 9999)
        self.assertEqual(fetcher.run_once(c, self.store, [113], 2000, LOG)["houses"]["113"]["t"], 2000)
        c.ignore_since = True   # a server that answers in full even though nothing is newer
        c.data[113] = ([auction(3, 10)], [], 1500)
        self.assertEqual(fetcher.run_once(c, self.store, [113], 3000, LOG)["houses"]["113"]["t"], 3000)

    def test_partial_check_works_with_frequent_fetches(self):
        # Fetching every 10 minutes, the last snapshot is still about an hour old: still "recent"
        full = [auction(i, 10) for i in range(1000)]
        c = FakeClient({113: (full, [], 1000)})
        fetcher.run_once(c, self.store, [113], 1000, LOG, every=10)
        c.data[113] = (full[:400], [], 4600)
        with self.assertLogs(LOG, "WARNING"):
            self.assertFalse(fetcher.run_once(c, self.store, [113], 4700, LOG, every=10)["houses"]["113"]["ok"])

    def test_same_partial_snapshot_counts_as_one_skip(self):
        # Re-downloading the same cut-short snapshot every 10 minutes is no new evidence that the house shrank
        full = [auction(i, 10) for i in range(1000)]
        c = FakeClient({113: (full, [], 1000)})
        skips = {}
        fetcher.run_once(c, self.store, [113], 1000, LOG, every=10, skips=skips)
        t = 1000
        with self.assertLogs(LOG, "WARNING"):
            for snap in range(fetcher.SHRINK_SKIPS):
                c.data[113] = (full[:400], [], 1000 + 3600 * (snap + 1))
                for _ in range(4):
                    t += 600
                    t = max(t, c.data[113][2] + 60)
                    self.assertFalse(fetcher.run_once(c, self.store, [113], t, LOG, every=10, skips=skips)
                                     ["houses"]["113"]["ok"])
        c.data[113] = (full[:400], [], 1000 + 3600 * (fetcher.SHRINK_SKIPS + 1))
        t = c.data[113][2] + 60
        self.assertTrue(fetcher.run_once(c, self.store, [113], t, LOG, every=10, skips=skips)["houses"]["113"]["ok"])
        self.assertEqual(self.snapshots(), 2)

    def test_house_failure_logs_traceback(self):
        c = FakeClient({113: ValueError("not json")})
        with self.assertLogs(LOG, "ERROR") as logs:
            fetcher.run_once(c, self.store, [113], 1000, LOG)
        self.assertIsNotNone(logs.records[0].exc_info)

    def test_next_run_after_sleep(self):
        self.assertEqual(fetcher.next_run(1000, 60, 1000 + 5 * 3600), 1000 + 5 * 3600)
        self.assertEqual(fetcher.next_run(1000, 60, 1500), 4600)

    def test_write_status_atomic(self):
        p = os.path.join(self.dir.name, "s.json")
        fetcher.write_status(p, {"a": 1})
        with open(p) as fh:
            self.assertEqual(json.load(fh), {"a": 1})
        self.assertFalse(os.path.exists(p + ".tmp"))

    def test_second_instance_exits(self):
        p = os.path.join(self.dir.name, "fetcher.lock")
        self.assertTrue(fetcher.acquire_lock(p))
        try:
            self.assertFalse(fetcher.acquire_lock(p))
        finally:
            fetcher._lock_handle.close()
            fetcher._lock_handle = None


class RobustnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.addCleanup(self.cleanup)
        patch = unittest.mock.patch.object(sys, "stdout", None)   # no console log lines in the test output
        patch.start()
        self.addCleanup(patch.stop)

    def cleanup(self):
        lg = logging.getLogger("fetcher")   # process-wide: close it so the temp dir can go
        for h in list(lg.handlers):
            h.close()
            lg.removeHandler(h)
        self.tmp.cleanup()

    def test_not_set_up(self):
        self.assertEqual(fetcher.main([], cfg={}, data=self.dir), 0)
        with open(os.path.join(self.dir, "fetcher_status.json")) as fh:
            self.assertEqual(json.load(fh)["error"], "not set up")

    def test_write_status_retries_while_the_file_is_read(self):
        real = os.replace
        calls = []

        def busy_twice(src, dst):
            calls.append(src)
            if len(calls) <= 2:
                raise PermissionError(13, "in use")   # the tray reading it (Windows)
            real(src, dst)
        p = os.path.join(self.dir, "s.json")
        with unittest.mock.patch.object(fetcher.os, "replace", busy_twice), \
                unittest.mock.patch.object(fetcher.time, "sleep"):
            fetcher.write_status(p, {"a": 1}, LOG)
        with open(p) as fh:
            self.assertEqual(json.load(fh), {"a": 1})
        self.assertEqual(len(calls), 3)

    def test_write_status_gives_up_without_raising(self):
        def busy(src, dst):
            raise PermissionError(13, "in use")
        with unittest.mock.patch.object(fetcher.os, "replace", busy), \
                unittest.mock.patch.object(fetcher.time, "sleep"), \
                self.assertLogs(LOG, "WARNING"):
            fetcher.write_status(os.path.join(self.dir, "s.json"), {"a": 1}, LOG)

    def test_inline_comment_in_config(self):
        cfg = os.path.join(self.dir, "ledger.cfg")
        with open(cfg, "w", encoding="utf-8") as fh:
            fh.write("bnet_id = abcd\nbnet_secret = s3#cret\nah_every = 60  # minutes\nah_faction =\t# unset\n")
        got = server.read_config(cfg)
        self.assertEqual(got, {"bnet_id": "abcd", "bnet_secret": "s3#cret", "ah_every": "60"})
        self.assertEqual(bnet.Config.from_cfg(got).every, 60)

    def test_bad_number_in_config_is_logged(self):
        cfg = {"bnet_id": "abcd", "bnet_secret": "s3cret", "ah_every": "sixty"}
        self.assertNotEqual(fetcher.main(["--once"], cfg=cfg, data=self.dir), 0)
        with open(os.path.join(self.dir, "fetcher.log"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn(" ERROR fetcher: ", text)
        self.assertIn("sixty", text)
        self.assertNotIn("Traceback", text)
        self.assertNotIn("s3cret", text)

    def test_bad_house_entry_is_named_in_the_status(self):
        cfg = {"bnet_id": "abcd", "bnet_secret": "s3cret", "ah_houses": "PvP 999"}
        self.assertNotEqual(fetcher.main(["--once"], cfg=cfg, data=self.dir), 0)
        with open(os.path.join(self.dir, "fetcher_status.json")) as fh:
            error = json.load(fh)["error"]
        self.assertIn("ah_houses", error)
        self.assertIn("PvP 999", error)

    def test_loop_fetches_each_configured_house_once(self):
        cfg = {"bnet_id": "abcd", "bnet_secret": "s3cret", "ah_houses": "PvP 113, PvP 116, PvP 119"}
        c = FakeClient({h: ([auction(1, 10)], []) for h in (113, 116, 119)})
        with unittest.mock.patch.object(fetcher.bnet, "Client", return_value=c):
            self.assertEqual(fetcher.main(["--once"], cfg=cfg, data=self.dir), 0)
        fetcher._lock_handle.close()
        fetcher._lock_handle = None
        self.assertEqual([h for h, _ in c.asked], [113, 116, 119])
        with open(os.path.join(self.dir, "fetcher_status.json")) as fh:
            self.assertEqual(json.load(fh)["houses"]["116"]["key"], "PvP Neutral")

    def test_unknown_ruleset_name_is_warned_once(self):
        cfg = {"bnet_id": "abcd", "bnet_secret": "s3cret", "ah_houses": "Mystery 113, pvp 116"}
        c = FakeClient({h: ([auction(1, 10)], []) for h in (113, 116)})
        with unittest.mock.patch.object(fetcher.bnet, "Client", return_value=c):
            self.assertEqual(fetcher.main(["--once"], cfg=cfg, data=self.dir), 0)
        fetcher._lock_handle.close()
        fetcher._lock_handle = None
        with open(os.path.join(self.dir, "fetcher.log"), encoding="utf-8") as fh:
            warnings = [line for line in fh if " WARNING " in line]
        self.assertEqual(len(warnings), 1)
        self.assertIn("Mystery", warnings[0])
        self.assertIn("unknown ruleset name Mystery (", warnings[0])   # pvp is PvP, not unknown

    def test_crash_is_logged(self):
        cfg = {"bnet_id": "abcd", "bnet_secret": "s3cret"}
        with unittest.mock.patch.object(fetcher, "run_once", side_effect=RuntimeError("boom")):
            with self.assertRaises(RuntimeError):
                fetcher.main(["--once"], cfg=cfg, data=self.dir)
        fetcher._lock_handle.close()
        fetcher._lock_handle = None
        with open(os.path.join(self.dir, "fetcher.log"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn(" ERROR fetcher: crashed", text)
        self.assertIn("RuntimeError: boom", text)

    def test_rollup_failure_does_not_stop_the_fetcher(self):
        st = market_store.Store(os.path.join(self.dir, "x.db"))
        self.addCleanup(st.close)
        with unittest.mock.patch.object(st, "rollup", side_effect=OSError("disk")), self.assertLogs(LOG, "ERROR"):
            self.assertEqual(fetcher.rollup(st, 1000, LOG), 0)

    def test_flag_file_removal_failure_still_stops(self):
        open(os.path.join(self.dir, "fetcher_stop"), "w").close()
        with unittest.mock.patch.object(fetcher.os, "remove", side_effect=PermissionError(13, "in use")), \
                self.assertLogs(LOG, "WARNING"):
            self.assertEqual(fetcher.wait_until(0, self.dir, LOG), "stop")


class ImportTests(unittest.TestCase):
    def test_importing_fetcher_leaves_server_log_alone(self):
        # Another process holding server.log open stops the live server rotating it (Windows).
        with tempfile.TemporaryDirectory() as tmp:
            code = "import logging, fetcher; print(len(logging.getLogger('server').handlers))"
            out = subprocess.run([sys.executable, "-c", code], cwd=os.path.dirname(HERE_TESTS),
                                 env=dict(os.environ, LEDGER_DATA=tmp), capture_output=True, text=True, check=True)
            self.assertEqual(out.stdout.strip(), "0")
            self.assertFalse(os.path.exists(os.path.join(tmp, "server.log")))


class MatchHouses(unittest.TestCase):
    class Client:
        def __init__(self, config, **kw):
            self.config = config

        def house(self, h):
            # house 113 sells item 1 at 100, 116 item 2 at 50, the rest nothing
            return ([auction(1, 1, qty=1, buyout=100)] if h == 113 else [auction(2, 2, qty=1, buyout=50)] if h == 116 else []), []

    def run_match(self, books, cfg_extra=None, kind="faction"):
        import io
        cfg = dict({"wow": "x", "bnet_id": "abcd", "bnet_secret": "s"}, **(cfg_extra or {}))
        config = bnet.Config.from_cfg(cfg)
        out = io.StringIO()
        with (unittest.mock.patch.object(fetcher, "read_book", return_value=books),
              unittest.mock.patch.object(fetcher.bnet, "Client", self.Client),
              unittest.mock.patch.object(sys, "stdout", out)):
            self.assertEqual(fetcher.match_houses(kind, cfg, config), 0)
        return out.getvalue()

    def test_match_reports_per_book(self):
        out = self.run_match({"PvP": {1: 100}, "Normal": {2: 50}}, {"ah_houses": "PvP 116"})
        self.assertEqual(out.count("house 113:"), 2)   # one ranking per book
        self.assertIn('book "PvP"', out)
        self.assertIn('book "Normal"', out)
        self.assertIn('add "PvP 113" to ah_houses', out)

    def test_match_configured_house_says_so(self):
        out = self.run_match({"PvP Horde": {1: 100}}, {"ah_houses": "PvP 113"})
        self.assertIn('"PvP 113" matches best', out)
        self.assertNotIn("to ah_houses", out)

    def test_match_legacy_book_uses_the_neutral_ruleset(self):
        out = self.run_match({"? Neutral": {2: 50}}, {"ah_houses": "Normal 113, Normal 116"}, "neutral")
        self.assertIn('"Normal 116" matches best', out)
        out = self.run_match({"? Neutral": {2: 50}}, {"ah_houses": "PvP 113"}, "neutral")
        self.assertIn('add "<ruleset> 116" to ah_houses', out)


class MatchScore(unittest.TestCase):
    def test_match_score(self):
        book = {1: 100, 2: 200, 3: 300}
        rows = {1: {"min": 100}, 2: {"min": 205}, 4: {"min": 9}}
        self.assertEqual(fetcher.match_score(book, rows), {"shared": 2, "exact": 1, "near": 2})


if __name__ == "__main__":
    unittest.main()
