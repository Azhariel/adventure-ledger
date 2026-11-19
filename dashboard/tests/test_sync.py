"""Tests for sync.py (WTF zips, the market bundle, sync jobs).   Usage: python dashboard/tests/test_sync.py"""
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
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


if __name__ == "__main__":
    unittest.main()
