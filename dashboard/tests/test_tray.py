"""Tests for tray.ps1's non-GUI parts (colour and tooltip, config, log rotation, startup shortcut).
Usage (from the Dashboard folder):  python tests/test_tray.py      (Windows: runs Windows PowerShell)"""
import json
import os
import subprocess
import tempfile
import time
import unittest

TRAY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tray.ps1")


def ps(body):
    """Dot-source tray.ps1 without its icon, run `body`, return what it printed as JSON."""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "case.ps1")
        with open(path, "w", encoding="utf-8-sig") as fh:   # BOM: Windows PowerShell reads it as UTF-8
            fh.write(". '%s' -NoGui\n%s\n" % (os.path.abspath(TRAY), body))
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path],
                             capture_output=True, text=True, check=True)
    if out.stderr.strip():
        raise AssertionError(out.stderr)
    return json.loads(out.stdout)


class TrayStateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        now = int(time.time())
        fresh = "@{ last_ok = %d; next = %d; error = $null }" % (now - 600, now + 3000)
        cases = {
            "fresh": "-ServerUp $true -FetcherUp $true -Status %s" % fresh,
            "server_stopped": "-ServerUp $false -FetcherUp $true -Status %s" % fresh,
            "server_hung": "-ServerUp $false -ServerProcAlive $true -FetcherUp $true -Status %s" % fresh,
            "fetcher_stopped": "-ServerUp $true -FetcherUp $false -Status %s" % fresh,
            "fetch_error": "-ServerUp $true -FetcherUp $true -Status @{ last_ok = %d; error = 'house 113: HTTP 503' }"
                           % (now - 600),
            "overdue": "-ServerUp $true -FetcherUp $true -EveryMin 60 -Status @{ last_ok = %d; error = $null }"
                       % (now - 5401),
            "just_in_time": "-ServerUp $true -FetcherUp $true -EveryMin 60 -Status @{ last_ok = %d; error = $null }"
                       % (now - 5300),
            "every_10": "-ServerUp $true -FetcherUp $true -EveryMin 10 -Status @{ last_ok = %d; error = $null }"
                        % (now - 1200),
            "no_fetch_yet": "-ServerUp $true -FetcherUp $true -Status $null",
            "both_stopped": "-ServerUp $false -FetcherUp $false -Status %s" % fresh,
            "not_set_up": "-ServerUp $true -FetcherUp $false -NotSetUp $true -Status @{ error = 'not set up' }",
            "not_set_up_off": "-ServerUp $false -FetcherUp $false -NotSetUp $true -Status $null",
            "long_error": "-ServerUp $true -FetcherUp $true -Status @{ last_ok = %d; error = '%s' }"
                          % (now - 600, "x" * 200),
        }
        body = "$now = %d\n$r = @{}\n" % now
        for name, args in cases.items():
            body += "$r['%s'] = Get-TrayState -Now $now %s\n" % (name, args)
        body += "$r | ConvertTo-Json -Depth 3"
        cls.r = ps(body)

    def check(self, name, colour, *tip_parts):
        got = self.r[name]
        self.assertEqual(got["Colour"], colour, got)
        for part in tip_parts:
            self.assertIn(part, got["Tip"])
        self.assertLessEqual(len(got["Tip"]), 63)

    def test_both_running_fresh_fetch_is_green(self):
        self.check("fresh", "green", "Live: on", "AH: last fetch ", ", next ")

    def test_server_stopped_is_amber(self):
        self.check("server_stopped", "amber", "Live: stopped")

    def test_server_process_up_but_not_answering_is_amber(self):
        self.check("server_hung", "amber", "Live: not answering")

    def test_fetcher_stopped_is_amber(self):
        self.check("fetcher_stopped", "amber", "Live: on", "AH: stopped")

    def test_fetch_error_is_amber_and_names_it(self):
        self.check("fetch_error", "amber", "AH: fetch failed: house 113: HTTP 503")

    def test_overdue_at_one_and_a_half_times_ah_every(self):
        self.check("overdue", "amber", "AH: overdue, last fetch ")
        self.check("just_in_time", "green")
        self.check("every_10", "amber", "overdue")

    def test_no_fetch_yet_is_amber(self):
        self.check("no_fetch_yet", "amber", "AH: no fetch yet")

    def test_both_stopped_is_grey(self):
        self.check("both_stopped", "grey", "Live: stopped", "AH: stopped")

    def test_not_set_up_is_never_amber(self):
        self.check("not_set_up", "green", "Live: on", "AH: not set up")
        self.check("not_set_up_off", "grey", "AH: not set up")

    def test_long_tooltip_is_cut_to_63(self):
        self.check("long_error", "amber", "AH: fetch failed: xxx")


class TrayHelpersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def test_not_set_up_rules(self):
        r = ps("@{\n"
               " no_id = Test-NotSetUp @{} $null $false\n"
               " id = Test-NotSetUp @{ bnet_id = 'x' } $null $false\n"
               " fetcher_said = Test-NotSetUp @{ bnet_id = 'x' } @{ error = 'not set up' } $false\n"
               " fetcher_running_again = Test-NotSetUp @{ bnet_id = 'x' } @{ error = 'not set up' } $true\n"
               "} | ConvertTo-Json")
        self.assertEqual(r, {"no_id": True, "id": False, "fetcher_said": True, "fetcher_running_again": False})

    def test_read_config_matches_server_rules(self):
        cfg = os.path.join(self.dir, "ledger.cfg")
        with open(cfg, "w", encoding="utf-8") as fh:
            fh.write("# comment\nwow = C:\\Games\\WoW\\_forever_\nbnet_id =\nah_every = 30  # minutes\n\nnot a pair\n"
                     "ah_neutral = # unset\nbnet_region = a#b\n")
        r = ps("Read-LedgerConfig '%s' | ConvertTo-Json" % cfg)
        self.assertEqual(r, {"wow": "C:\\Games\\WoW\\_forever_", "ah_every": "30", "bnet_region": "a#b"})

    def test_data_dir_prefers_env_then_config(self):
        r = ps("$env:LEDGER_DATA = '%s'\n$a = Get-DataDir @{ data = 'D:\\elsewhere' }\n"
               "$env:LEDGER_DATA = $null\n$b = Get-DataDir @{ data = 'D:\\elsewhere' }\n$c = Get-DataDir @{}\n"
               "@($a, $b, $c) | ConvertTo-Json" % self.dir)
        self.assertEqual(r[0], os.path.abspath(self.dir))
        self.assertEqual(r[1], "D:\\elsewhere")
        self.assertEqual(os.path.normcase(r[2]),
                         os.path.normcase(os.path.abspath(os.path.join(os.path.dirname(TRAY), "..", "data"))))

    def test_log_line_format_and_rotation(self):
        log = os.path.join(self.dir, "tray.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("x" * 999_990)
        for n in (1, 2, 3):
            with open(log + ".%d" % n, "w", encoding="utf-8") as fh:
                fh.write("old %d" % n)
        ps("Write-TrayLog '%s' 'live server started (pid 42)'\n'[]'" % log)
        with open(log, encoding="utf-8") as fh:
            line = fh.read()
        self.assertRegex(line, r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d INFO tray: live server started \(pid 42\)\r?\n$")
        self.assertEqual(os.path.getsize(log + ".1"), 999_990)
        with open(log + ".2", encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "old 1")
        with open(log + ".3", encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "old 2")   # old 3 dropped
        self.assertFalse(os.path.exists(log + ".4"))

    def test_startup_shortcut_created_and_removed(self):
        lnk = os.path.join(self.dir, "Adventure Ledger.lnk")
        r = ps("New-StartupLink '%s'\n$t = (New-Object -ComObject WScript.Shell).CreateShortcut('%s').TargetPath\n"
               "$made = Test-Path '%s'\nRemove-StartupLink '%s'\n"
               "@{ made = $made; target = $t; gone = -not (Test-Path '%s') } | ConvertTo-Json" % (lnk, lnk, lnk, lnk, lnk))
        self.assertTrue(r["made"])
        self.assertTrue(r["gone"])
        self.assertEqual(os.path.normcase(r["target"]),
                         os.path.normcase(os.path.abspath(os.path.join(os.path.dirname(TRAY), "tray.bat"))))

    def test_default_shortcut_is_in_the_startup_folder(self):
        r = ps("Get-StartupLinkPath | ConvertTo-Json")
        self.assertTrue(r.endswith("\\Start Menu\\Programs\\Startup\\Adventure Ledger.lnk"), r)


if __name__ == "__main__":
    unittest.main()
