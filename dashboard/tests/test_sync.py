"""Tests for sync.py (WTF zips, the market bundle, sync jobs).   Usage: python dashboard/tests/test_sync.py"""
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import b2  # noqa: E402
import market_store as ms  # noqa: E402
import sync  # noqa: E402


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


class Dirs(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.wow = os.path.join(self.root, "wow")
        self.data = os.path.join(self.root, "data")
        os.makedirs(self.data)

    def tearDown(self):
        self._tmp.cleanup()

    def sv(self, rel, data=b"X = 1\n"):
        write(os.path.join(self.wow, "WTF", rel), data)


class WtfTests(Dirs):
    def test_pc_name_normalised(self):
        self.assertEqual(sync.pc_name({}, "EGB"), "egb")
        self.assertEqual(sync.pc_name({"pc_name": "Azhariel Base"}, "x"), "azhariel-base")
        with self.assertRaises(ValueError):
            sync.pc_name({"pc_name": "../x"}, "x")

    def test_zip_round_trip_skips_backups(self):
        self.sv("Account/A/SavedVariables/Logbook.lua", b"LogbookDB = {}\n")
        self.sv("Account/A/SavedVariables/Logbook.lua.bak", b"old")
        self.sv("Account/A/SavedVariables/Haul.lua.old", b"old")
        dest = os.path.join(self.root, "w.zip")
        self.assertGreater(sync.zip_wtf(self.wow, dest), 0)
        sync.install_wtf(dest, self.data, "egb")
        base = os.path.join(self.data, "pcs", "egb", "WTF", "Account", "A", "SavedVariables")
        self.assertEqual(read(os.path.join(base, "Logbook.lua")), b"LogbookDB = {}\n")
        self.assertEqual(sorted(os.listdir(base)), ["Logbook.lua"])
        self.assertFalse(os.path.exists(os.path.join(self.data, "sync_tmp", "egb")))

    def test_zip_without_wtf_raises(self):
        with self.assertRaises(FileNotFoundError):
            sync.zip_wtf(self.wow, os.path.join(self.root, "w.zip"))

    def test_install_replaces_old_folder(self):
        write(os.path.join(self.data, "pcs", "egb", "WTF", "Account", "Old", "x.lua"), b"stale")
        self.sv("Account/A/SavedVariables/Logbook.lua")
        dest = os.path.join(self.root, "w.zip")
        sync.zip_wtf(self.wow, dest)
        sync.install_wtf(dest, self.data, "egb")
        self.assertFalse(os.path.exists(os.path.join(self.data, "pcs", "egb", "WTF", "Account", "Old")))
        self.assertTrue(os.path.isdir(os.path.join(self.data, "pcs", "egb", "WTF", "Account", "A")))

    def old_folder(self):
        path = os.path.join(self.data, "pcs", "egb", "WTF", "Account", "Old", "x.lua")
        write(path, b"keep me")
        return path

    def test_zip_slip_rejected(self):
        old = self.old_folder()
        dest = os.path.join(self.root, "evil.zip")
        with zipfile.ZipFile(dest, "w") as z:
            z.writestr("Account/A/SavedVariables/ok.lua", "x")
            z.writestr("../../evil.lua", "x")
        with self.assertRaises(ValueError):
            sync.install_wtf(dest, self.data, "egb")
        self.assertEqual(read(old), b"keep me")
        self.assertFalse(os.path.exists(os.path.join(self.root, "evil.lua")))
        self.assertFalse(os.path.exists(os.path.join(self.data, "evil.lua")))
        for bad in ("C:/x.lua", "/abs.lua", "Account/../../x.lua"):
            with zipfile.ZipFile(dest, "w") as z:
                z.writestr("Account/a.lua", "x")
                z.writestr(bad, "x")
            with self.assertRaises(ValueError, msg=bad):
                sync.install_wtf(dest, self.data, "egb")

    def test_extract_failure_keeps_old_folder(self):
        old = self.old_folder()
        self.sv("Account/A/SavedVariables/Logbook.lua", os.urandom(200000))
        dest = os.path.join(self.root, "w.zip")
        sync.zip_wtf(self.wow, dest)
        data = read(dest)
        write(dest, data[:len(data) // 2])
        with self.assertRaises(Exception):
            sync.install_wtf(dest, self.data, "egb")
        self.assertEqual(read(old), b"keep me")
        self.assertFalse(os.path.exists(os.path.join(self.data, "sync_tmp", "egb")))

    def test_not_a_wtf_rejected(self):
        dest = os.path.join(self.root, "w.zip")
        with zipfile.ZipFile(dest, "w") as z:
            z.writestr("Config.wtf", "x")
        with self.assertRaises(ValueError) as cm:
            sync.install_wtf(dest, self.data, "egb")
        self.assertIn("not a WTF folder", str(cm.exception))

    def test_newest_save(self):
        os.makedirs(os.path.join(self.wow, "WTF", "Account"))
        self.assertIsNone(sync.newest_save(self.wow))
        self.sv("Account/A/SavedVariables/Logbook.lua")
        self.sv("Account/A/Realm/Des/SavedVariables/Haul.lua")
        os.utime(os.path.join(self.wow, "WTF", "Account/A/SavedVariables/Logbook.lua"), (1000, 1000))
        os.utime(os.path.join(self.wow, "WTF", "Account/A/Realm/Des/SavedVariables/Haul.lua"), (2000, 2000))
        self.assertEqual(sync.newest_save(self.wow), 2000)


def row(price=100):
    return {"min": price, "market": price, "units": 5, "listings": 1}


def fill(data, ts, house=113):
    """A market.db in data with one snapshot per t (one item each)."""
    s = ms.Store(os.path.join(data, "market.db"))
    for t in ts:
        s.record(house, t, {2589: row()}, {}, {t: (2589, 5, "LONG")})
    return s


def count(data, table="snapshot"):
    db = sqlite3.connect(os.path.join(data, "market.db"))
    try:
        return db.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
    finally:
        db.close()


class MarketTests(Dirs):
    def setUp(self):
        super().setUp()
        self.src = os.path.join(self.root, "src")
        os.makedirs(self.src)
        self.bundle = os.path.join(self.root, "market.zip")

    def export(self, ts):
        fill(self.src, ts).close()
        return sync.export_market(self.src, self.bundle)

    def test_export_import_round_trip(self):
        write(os.path.join(self.src, "networth_log.tsv"), b"t gold 1 2")
        got = self.export([100, 200])
        self.assertEqual(got["latest"], 200)
        self.assertEqual(got["store"], ms.STORE_VERSION)
        self.assertGreater(got["size"], 0)
        res = sync.import_market(self.bundle, self.data)
        self.assertEqual(res, {"latest": 200, "replaced_latest": None})
        self.assertEqual(count(self.data, "hourly"), 2)
        self.assertEqual(read(os.path.join(self.data, "networth_log.tsv")), b"t gold 1 2")
        db = sqlite3.connect(os.path.join(self.data, "market.db"))
        try:
            self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        finally:
            db.close()
        self.assertFalse(os.listdir(os.path.join(self.data, "sync_tmp")))

    def test_export_without_db_raises(self):
        with self.assertRaises(FileNotFoundError):
            sync.export_market(self.src, self.bundle)

    def test_import_while_other_connection_open(self):
        self.export([100, 200, 300])
        fetcher = fill(self.data, [50])
        try:
            sync.import_market(self.bundle, self.data)
            self.assertEqual(fetcher.db.execute("SELECT COUNT(*) FROM snapshot").fetchone()[0], 3)
            fetcher.record(113, 400, {2589: row()}, {}, {400: (2589, 5, "LONG")})
        finally:
            fetcher.close()
        self.assertEqual(count(self.data), 4)

    def bundle_db(self, prep):
        """A bundle whose market.db is built by prep(path)."""
        path = os.path.join(self.root, "custom.db")
        prep(path)
        with zipfile.ZipFile(self.bundle, "w") as z:
            z.write(path, "market.db")

    def test_import_refuses_newer_store(self):
        fill(self.data, [50]).close()

        def prep(path):
            s = fill(os.path.dirname(path), [])
            s.close()
            os.replace(os.path.join(os.path.dirname(path), "market.db"), path)
            db = sqlite3.connect(path)
            db.execute("PRAGMA user_version = %d" % (ms.STORE_VERSION + 1))
            db.close()
        self.bundle_db(prep)
        with self.assertRaises(ValueError) as cm:
            sync.import_market(self.bundle, self.data)
        self.assertIn("git pull", str(cm.exception))
        self.assertEqual(count(self.data), 1)

    def test_import_migrates_older_store(self):
        def prep(path):
            db = sqlite3.connect(path)
            db.executescript("CREATE TABLE snapshot (house INTEGER, t INTEGER, items INTEGER, auctions INTEGER);"
                             "INSERT INTO snapshot VALUES (113, 70, 1, 1);"
                             "CREATE TABLE hourly (house INTEGER, t INTEGER, item INTEGER, min INTEGER,"
                             " market INTEGER, units INTEGER, listings INTEGER, sold INTEGER);")
            db.close()
        self.bundle_db(prep)
        res = sync.import_market(self.bundle, self.data)
        self.assertEqual(res["latest"], 70)
        db = sqlite3.connect(os.path.join(self.data, "market.db"))
        try:
            self.assertIn("cheap", [c[1] for c in db.execute("PRAGMA table_info(hourly)")])
            self.assertEqual(ms.store_version(db), ms.STORE_VERSION)
        finally:
            db.close()

    def test_import_damaged_keeps_local(self):
        fill(self.data, [50]).close()
        self.bundle_db(lambda path: write(path, os.urandom(4096)))
        with self.assertRaises(ValueError) as cm:
            sync.import_market(self.bundle, self.data)
        self.assertIn("the market copy is damaged", str(cm.exception))
        self.assertEqual(count(self.data), 1)

    def test_import_reports_replaced_latest(self):
        fill(self.data, [100]).close()
        self.export([200])
        self.assertEqual(sync.local_latest(self.data), 100)
        self.assertEqual(sync.import_market(self.bundle, self.data), {"latest": 200, "replaced_latest": 100})
        self.assertEqual(sync.local_latest(self.data), 200)

    def test_local_latest_without_db(self):
        self.assertIsNone(sync.local_latest(self.data))


class FakeClient:
    """b2.Client's surface over a dict: name -> (bytes, info, uploaded)."""

    def __init__(self, clock):
        self.files, self.clock, self.calls, self.fail, self.block = {}, clock, [], None, None

    def list(self, prefix):
        self.calls.append(("list", prefix))
        if self.fail:
            raise self.fail
        return [{"name": n, "size": len(b), "uploaded": u, "info": dict(i)}
                for n, (b, i, u) in sorted(self.files.items()) if n.startswith(prefix)]

    def upload(self, name, path, info, progress=None):
        self.calls.append(("upload", name))
        if self.block:
            self.block.wait(5)
        if self.fail:
            raise self.fail
        self.files[name] = (read(path), {k: str(v) for k, v in info.items()}, self.clock())
        return {}

    def download(self, name, dest, progress=None):
        self.calls.append(("download", name))
        write(dest, self.files[name][0])
        return {}


def at(h, m=0, day=19):
    return time.mktime((2026, 11, day, h, m, 0, 0, 0, -1))


CFG = {"b2_key_id": "kid", "b2_key": "K3Y-SECRET", "b2_bucket": "ledger-sync"}


class SyncerTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.now = [at(12)]
        self.client = FakeClient(lambda: self.now[0])

    def tearDown(self):
        self._tmp.cleanup()

    def pc(self, name, master=False, cfg=None, client="shared"):
        """A Syncer for a PC with its own wow and data folders (a WTF with one file)."""
        wow, data = os.path.join(self.root, name, "wow"), os.path.join(self.root, name, "data")
        write(os.path.join(wow, "WTF", "Account", "A", "SavedVariables", "Logbook.lua"), ("-- %s\n" % name).encode())
        os.makedirs(data, exist_ok=True)
        c = dict(CFG if cfg is None else cfg)
        if master:
            c["market_master"] = "yes"
        return sync.Syncer(data, wow, c, self.client if client == "shared" else client, name,
                           now=lambda: self.now[0])

    def test_upload_then_import_on_other_pc(self):
        egb, home = self.pc("egb"), self.pc("azhariel-base", master=True)
        self.assertTrue(egb.run("upload-wtf")["ok"])
        self.now[0] += 60
        got = home.run("import")
        self.assertTrue(got["ok"], got)
        self.assertIn("egb", got["message"])
        self.assertTrue(got["rebuild"])
        self.assertEqual(read(os.path.join(home.data, "pcs", "egb", "WTF", "Account", "A", "SavedVariables",
                                           "Logbook.lua")), b"-- egb\n")
        again = home.run("import")
        self.assertEqual(again["message"], "Already up to date")
        self.assertFalse(again.get("rebuild"))

    def test_import_skips_own_name_any_case(self):
        me = self.pc("EGB")
        me.run("upload-wtf")
        me.run("import")
        self.assertFalse(os.path.exists(os.path.join(me.data, "pcs")))

    def market_on(self, syncer, ts):
        fill(syncer.data, ts).close()

    def test_master_never_imports_market(self):
        home, egb = self.pc("azhariel-base", master=True), self.pc("egb")
        self.market_on(home, [100])
        self.market_on(egb, [100, 200, 300])
        egb.master = True             # a work PC misconfigured as master uploads
        egb.run("upload-market")
        self.now[0] += 60
        home.run("import")
        self.assertEqual(count(home.data), 1)

    def test_non_master_imports_market(self):
        home, egb = self.pc("azhariel-base", master=True), self.pc("egb")
        self.market_on(home, [100, 200])
        self.assertTrue(home.run("upload-market")["ok"])
        self.now[0] += 60
        got = egb.run("import")
        self.assertTrue(got["ok"], got)
        self.assertIn("market db", got["message"])
        self.assertEqual(sync.local_latest(egb.data), 200)

    def test_non_master_cannot_upload_market(self):
        egb = self.pc("egb")
        self.market_on(egb, [100])
        got = egb.run("upload-market")
        self.assertEqual(got["message"], "Only the market master uploads the market db")
        self.assertNotIn(("upload", "market/market.zip"), self.client.calls)

    def test_busy_refuses_second_job(self):
        egb = self.pc("egb")
        self.client.block = threading.Event()
        t = threading.Thread(target=egb.run, args=("upload-wtf",))
        t.start()
        for _ in range(100):
            if ("upload", "wtf/egb.zip") in self.client.calls:
                break
            time.sleep(0.02)
        got = egb.run("import")
        self.client.block.set()
        t.join()
        self.assertEqual(got["message"], "Another sync job is running")

    def test_job_error_message_has_no_key(self):
        egb = self.pc("egb")
        self.client.fail = b2.B2Error(401, "bad_auth_token", "nope")
        got = egb.run("upload-wtf")
        self.assertFalse(got["ok"])
        self.assertIn("ledger.cfg", got["message"])
        with open(os.path.join(egb.data, sync.STATE_FILE), encoding="utf-8") as fh:
            self.assertNotIn("K3Y-SECRET", fh.read())
        self.client.fail = b2.B2Error(0, "network", "refused")
        self.assertIn("unreachable", egb.run("upload-wtf")["message"])

    def test_daily_due(self):
        home = self.pc("azhariel-base", master=True)
        self.market_on(home, [100])
        self.now[0] = at(7, 59)
        self.assertFalse(home.daily_due())
        self.now[0] = at(8, 1)
        self.assertTrue(home.daily_due())
        self.assertFalse(self.pc("egb").daily_due())      # not the master
        self.client.fail = b2.B2Error(503, "service_unavailable", "busy")
        home.run("upload-market")
        self.client.fail = None
        self.now[0] = at(8, 30)
        self.assertFalse(home.daily_due())                # retried at most hourly
        self.now[0] = at(9, 2)
        self.assertTrue(home.daily_due())
        self.assertTrue(home.run("upload-market")["ok"])
        self.now[0] = at(23, 0)
        self.assertFalse(home.daily_due())                # done today
        self.now[0] = at(7, 0, day=20)
        self.assertFalse(home.daily_due())
        self.now[0] = at(8, 0, day=20)
        self.assertTrue(home.daily_due())

    def test_status_due_flags(self):
        egb, home = self.pc("egb"), self.pc("azhariel-base", master=True)
        st = egb.status(self.now[0] - 10, None)
        self.assertTrue(st["configured"])
        self.assertTrue(st["uploadDue"])                  # never uploaded
        egb.run("upload-wtf")
        st = egb.status(self.now[0] - 10, None)
        self.assertFalse(st["uploadDue"])
        self.assertTrue(egb.status(self.now[0] + 5, self.now[0] + 200)["unsaved"])
        self.now[0] += 120
        st = home.status(None, None)
        self.assertTrue(st["importDue"])
        self.assertEqual([b["pc"] for b in st["bucket"] if b["kind"] == "wtf"], ["egb"])
        home.run("import")
        self.now[0] += 120
        st = home.status(None, None)
        self.assertFalse(st["importDue"])
        self.assertEqual(st["pcs"][0]["name"], "egb")
        bare = self.pc("bare", cfg={}, client=None)
        st = bare.status(None, None)
        self.assertFalse(st["configured"])
        self.assertFalse(bare.run("import")["ok"])


if __name__ == "__main__":
    unittest.main()
