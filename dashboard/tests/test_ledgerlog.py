"""Tests for ledgerlog.py (the shared rotating logs).   Usage (from the Dashboard folder):  python tests/test_ledgerlog.py"""
import glob
import logging
import os
import re
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ledgerlog  # noqa: E402


class LedgerLogTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.addCleanup(self.cleanup)
        # no stdout handler: keeps the test output clean (and is what pythonw looks like)
        patch = unittest.mock.patch.object(sys, "stdout", None)
        patch.start()
        self.addCleanup(patch.stop)

    def cleanup(self):
        # loggers are process-wide: drop ours so the temp dir can go and the next test starts fresh
        lg = logging.getLogger("server")
        for h in list(lg.handlers):
            h.close()
            lg.removeHandler(h)
        self.tmp.cleanup()

    def lines(self):
        with open(os.path.join(self.dir, "server.log"), encoding="utf-8") as fh:
            return fh.read().splitlines()

    def test_line_format(self):
        ledgerlog.get("server", self.dir).info("built")
        self.assertRegex(self.lines()[-1], r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d INFO server: built$")

    def test_error_has_traceback(self):
        log = ledgerlog.get("server", self.dir)
        try:
            raise ValueError("bad")
        except ValueError:
            log.exception("boom")
        lines = self.lines()
        self.assertTrue(re.search(r" ERROR server: boom$", lines[0]))
        self.assertTrue(any("ValueError" in ln for ln in lines[1:]))

    def test_rotates(self):
        log = ledgerlog.get("server", self.dir)
        fh = [h for h in log.handlers if isinstance(h, logging.FileHandler)][0]
        fh.maxBytes = 200
        for i in range(50):
            log.info("line number %d" % i)
        names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(self.dir, "server.log*")))
        self.assertEqual(names, ["server.log", "server.log.1", "server.log.2", "server.log.3"])

    def test_get_twice_one_handler(self):
        ledgerlog.get("server", self.dir)
        log = ledgerlog.get("server", self.dir)
        self.assertEqual(len([h for h in log.handlers if isinstance(h, logging.FileHandler)]), 1)


if __name__ == "__main__":
    unittest.main()
