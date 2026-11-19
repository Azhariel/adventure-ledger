"""Tests for sync.py (WTF zips, the market bundle, sync jobs).   Usage: python dashboard/tests/test_sync.py"""
import os
import sqlite3
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
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


if __name__ == "__main__":
    unittest.main()
