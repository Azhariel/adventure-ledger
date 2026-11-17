"""Tests for fetcher.py.   Usage: python dashboard/tests/test_fetcher.py"""
import json
import logging
import os
import subprocess
import sys
import tempfile
import unittest

HERE_TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE_TESTS, ".."))
import bnet  # noqa: E402
import fetcher  # noqa: E402
import market_store  # noqa: E402

LOG = logging.getLogger("test_fetcher")
LOG.addHandler(logging.NullHandler())
LOG.propagate = False


def auction(aid, item, qty=4, buyout=400, left="LONG"):
    return {"id": aid, "item": {"id": item}, "quantity": qty, "buyout": buyout, "time_left": left}


class FakeClient:
    def __init__(self, data):
        self.data = data   # house -> (auctions, commodities) or an exception

    def house(self, h):
        got = self.data[h]
        if isinstance(got, Exception):
            raise got
        return got


class FetcherTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = market_store.Store(os.path.join(self.dir.name, "market.db"))

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

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

    def test_next_run_after_sleep(self):
        self.assertEqual(fetcher.next_run(1000, 60, 1000 + 5 * 3600), 1000 + 5 * 3600)
        self.assertEqual(fetcher.next_run(1000, 60, 1500), 4600)

    def test_write_status_atomic(self):
        p = os.path.join(self.dir.name, "s.json")
        fetcher.write_status(p, {"a": 1})
        with open(p) as fh:
            self.assertEqual(json.load(fh), {"a": 1})
        self.assertFalse(os.path.exists(p + ".tmp"))

    def test_not_set_up(self):
        self.assertEqual(fetcher.main([], cfg={}, data=self.dir.name), 0)
        with open(os.path.join(self.dir.name, "fetcher_status.json")) as fh:
            self.assertEqual(json.load(fh)["error"], "not set up")

    def test_second_instance_exits(self):
        p = os.path.join(self.dir.name, "fetcher.lock")
        self.assertTrue(fetcher.acquire_lock(p))
        try:
            self.assertFalse(fetcher.acquire_lock(p))
        finally:
            fetcher._lock_handle.close()
            fetcher._lock_handle = None


class ImportTests(unittest.TestCase):
    def test_importing_fetcher_leaves_server_log_alone(self):
        # Another process holding server.log open stops the live server rotating it (Windows).
        with tempfile.TemporaryDirectory() as tmp:
            code = "import logging, fetcher; print(len(logging.getLogger('server').handlers))"
            out = subprocess.run([sys.executable, "-c", code], cwd=os.path.dirname(HERE_TESTS),
                                 env=dict(os.environ, LEDGER_DATA=tmp), capture_output=True, text=True, check=True)
            self.assertEqual(out.stdout.strip(), "0")
            self.assertFalse(os.path.exists(os.path.join(tmp, "server.log")))


class MatchScore(unittest.TestCase):
    def test_match_score(self):
        book = {1: 100, 2: 200, 3: 300}
        rows = {1: {"min": 100}, 2: {"min": 205}, 4: {"min": 9}}
        self.assertEqual(fetcher.match_score(book, rows), {"shared": 2, "exact": 1, "near": 2})


if __name__ == "__main__":
    unittest.main()
