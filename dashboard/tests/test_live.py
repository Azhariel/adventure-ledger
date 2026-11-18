"""Tests for livelog.py (the combat-log reader).   Usage (from the Dashboard folder):  python tests/test_live.py
Lines are real WoW Forever combat-log lines (8 Nov 2026), trimmed to the ones each case needs."""
import http.client
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import livelog  # noqa: E402

# server.py makes its data folder on import: point it at a scratch one first.
_SCRATCH = tempfile.mkdtemp()
os.environ["LEDGER_DATA"] = _SCRATCH
import server  # noqa: E402
import market_store  # noqa: E402

ME = "Player-6800-00A90C3E"
MAP = '11/8/2026 21:24:21.690-3  MAP_CHANGE,1421,"Silverpine Forest",1666.666626,-1133.333252,3449.999756,-750.000000'
ZONE = '11/8/2026 21:24:21.690-3  ZONE_CHANGE,0,"Silverpine Forest",0'
MIND_BLAST = ('11/8/2026 21:40:48.827-3  SPELL_DAMAGE,Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,0x80000000,'
              'Creature-0-7062-0-77206-1797-00007115CE,"Giant Grizzled Bear",0x10a48,0x80000000,8102,"Mind Blast",0x20,'
              'Creature-0-7062-0-77206-1797-00007115CE,0000000000000000,289,368,44,0,307,0,0,0,1,0,0,0,5.39,1238.23,1421,'
              '5.9322,13,79,79,-1,32,0,0,0,nil,nil,nil,ST')
BEAR_SWING = ('11/8/2026 21:40:51.486-3  SWING_DAMAGE,Creature-0-7062-0-77206-1797-00007115CE,"Giant Grizzled Bear",0x10a48,'
              '0x80000000,Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,0x80000000,'
              'Creature-0-7062-0-77206-1797-00007115CE,0000000000000000,238,368,44,0,307,0,0,0,1,0,0,0,22.84,1229.40,1421,'
              '6.0626,13,14,19,-1,1,0,0,0,nil,nil,nil')
BEAR_LANDED = ('11/8/2026 21:40:51.487-3  SWING_DAMAGE_LANDED,Creature-0-7062-0-77206-1797-00007115CE,"Giant Grizzled Bear",'
               '0x10a48,0x80000000,Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,0x80000000,Player-6800-00A90C3E,'
               '0000000000000000,498,512,164,25,521,0,0,0,0,780,955,0,26.37,1228.61,1421,2.1691,10,14,19,-1,1,0,0,0,nil,nil,nil')
HEAL = ('11/8/2026 21:40:52.832-3  SPELL_HEAL,Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,0x80000000,'
        'Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,0x80000000,1260198,"Touch of the Grave",0x20,'
        'Player-6800-00A90C3E,0000000000000000,512,512,164,25,521,0,0,0,0,875,955,0,26.04,1227.80,1421,2.7537,10,26,26,6,0,nil')
KILL = ('11/8/2026 21:40:59.947-3  PARTY_KILL,Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,0x80000000,'
        'Creature-0-7062-0-77206-1797-00007115CE,"Giant Grizzled Bear",0x10a48,0x80000000,0')
ENEMY = ('11/8/2026 21:41:10.000-3  SPELL_CAST_SUCCESS,Player-6922-00954BFC,"Fæng-Stonepaw-PvP-US",0x548,0x80000000,'
         '0000000000000000,nil,0x80000000,0x80000000,1459,"Arcane Intellect",0x40,Player-6922-00954BFC,0000000000000000,'
         '900,980,10,10,300,0,0,0,0,500,600,0,30.0,1230.0,1421,1.0,24')
DIED = ('11/8/2026 21:40:55.000-3  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-6800-00A90C3E,'
        '"Azhariel-Deadheart-PvP-US",0x511,0x80000000,0')


def state(*lines):
    s = livelog.LiveState("test.txt")
    for line in lines:
        s.feed(line)
    return s


class TimeAndNames(unittest.TestCase):
    def test_time_uses_the_logged_utc_offset(self):
        # 21:40:51.486 at UTC-3 = 00:40:51.486 UTC next day
        self.assertAlmostEqual(livelog.parse_time("11/9/2026 00:40:51.486+0"),
                               livelog.parse_time("11/8/2026 21:40:51.486-3"), places=3)
        self.assertIsNone(livelog.parse_time("garbage"))

    def test_forever_names_drop_ruleset_and_region(self):
        self.assertEqual(livelog.short_name("Azhariel-Deadheart-PvP-US"), "Azhariel Deadheart")
        self.assertEqual(livelog.short_name("nil"), "?")

    def test_npc_id_comes_from_the_creature_guid(self):
        self.assertEqual(livelog.npc_id("Creature-0-7062-0-77206-1797-00007115CE"), 1797)
        self.assertIsNone(livelog.npc_id("Player-6800-00A90C3E"))


class YouAndTheMap(unittest.TestCase):
    def test_finds_you_by_flags_and_reads_health_mana_position(self):
        s = state(MAP, ZONE, BEAR_LANDED)
        me = s.snapshot(0)["me"]
        self.assertEqual(me["guid"], ME)
        self.assertEqual(me["name"], "Azhariel Deadheart")
        self.assertEqual((me["hp"], me["maxHp"], me["power"], me["maxPower"]), (498, 512, 780, 955))
        self.assertEqual(me["itemLevel"], 10)  # not the character level (19)
        self.assertEqual(me["zone"], "Silverpine Forest")

    def test_world_position_converts_to_map_coordinates_like_muddyboots(self):
        s = state(MAP)
        x, y = s._map_xy(1421, 1229.40, 22.84)   # posX, posY as in the log... order matters:
        x2, y2 = s._map_xy(1421, 22.84, 1229.40)
        # MuddyBoots' trail had (0.51, 0.7788) for world (-514.47, 1308.2); check the formula on that point
        mx, my = s._map_xy(1421, -514.47, 1308.2)
        self.assertAlmostEqual(mx, (3449.999756 - 1308.2) / (3449.999756 + 750.0), places=6)
        self.assertAlmostEqual(my, (1666.666626 + 514.47) / (1666.666626 + 1133.333252), places=6)
        self.assertNotEqual((x, y), (x2, y2))

    def test_trail_is_time_x_y_triples_on_the_current_map(self):
        s = state(MAP, ZONE, BEAR_LANDED)
        snap = s.snapshot(0)
        trail, me = snap["trail"], snap["me"]
        self.assertEqual(snap["v"], livelog.SNAPSHOT_VERSION)
        self.assertEqual(len(trail), 3)
        self.assertEqual(trail[0], round(me["at"], 1))
        self.assertEqual((trail[1], trail[2]), (round(me["x"], 4), round(me["y"], 4)))

    def test_a_buff_on_a_passer_by_places_them_near_you(self):
        # real line, 15 Nov 2026: the advanced block is the caster's (you), so the target has no position of its own
        buff = ('11/8/2026 21:40:52.000-3  SPELL_CAST_SUCCESS,Player-6800-00A90C3E,"Azhariel-Deadheart-PvP-US",0x511,'
                '0x80000000,Player-6922-007A5281,"Soren-Dawnsworn-PvP-US",0x10518,0x80000000,1245,"Power Word: Fortitude",'
                '0x2,Player-6800-00A90C3E,0000000000000000,812,812,168,30,766,0,0,0,0,1282,1282,400,22.84,1229.40,1421,'
                '1.7282,18')
        s = state(MAP, ZONE, BEAR_LANDED, buff)
        snap = s.snapshot(s.last_line)
        me = snap["me"]
        soren = [p for p in snap["players"] if p["name"].startswith("Soren")]
        self.assertEqual(len(soren), 1)
        self.assertTrue(soren[0]["near"])
        self.assertEqual((soren[0]["map"], soren[0]["x"], soren[0]["y"]), (me["map"], me["x"], me["y"]))
        self.assertFalse(soren[0]["hostile"])

    def test_no_position_until_the_map_edges_are_known(self):
        s = state(BEAR_LANDED)
        self.assertIsNone(s.snapshot(0)["me"]["x"])


class Fights(unittest.TestCase):
    def test_damage_both_ways_heal_and_kill_make_one_fight(self):
        s = state(MAP, BEAR_LANDED, MIND_BLAST, BEAR_SWING, HEAL, KILL)
        snap = s.snapshot(0)
        self.assertEqual(snap["session"]["dmgDone"], 79)
        self.assertEqual(snap["session"]["dmgTaken"], 14)        # SWING_DAMAGE only, not its _LANDED twin
        self.assertEqual(snap["session"]["healDone"], 20)        # 26 healed, 6 overheal
        self.assertEqual(snap["session"]["kills"], 1)
        self.assertEqual(snap["session"]["spells"], [("Mind Blast", 79)])
        self.assertIsNotNone(snap["fight"])
        s.tick(livelog.parse_time("11/8/2026 21:41:10.000-3"))  # 10 s after the last damage
        snap = s.snapshot(0)
        self.assertIsNone(snap["fight"])
        f = snap["fights"][0]
        self.assertEqual((f["target"], f["dmgDone"], f["dmgTaken"], f["kills"]), ("Giant Grizzled Bear", 79, 14, ["Giant Grizzled Bear"]))
        self.assertEqual(f["targetNpc"], 1797)
        self.assertEqual(snap["session"]["topKills"], [("Giant Grizzled Bear", 1, 1797)])
        self.assertEqual(snap["killLog"][0][1:], [1797, "Giant Grizzled Bear"])
        self.assertEqual(f["seconds"], 3)

    def test_gap_boundary_six_seconds_keeps_the_fight_open(self):
        s = state(MAP, BEAR_LANDED, MIND_BLAST)
        t = livelog.parse_time("11/8/2026 21:40:48.827-3")
        s.tick(t + livelog.FIGHT_GAP)
        self.assertIsNotNone(s.fight)
        s.tick(t + livelog.FIGHT_GAP + 0.01)
        self.assertIsNone(s.fight)

    def test_death_names_the_last_hit(self):
        s = state(MAP, BEAR_LANDED, BEAR_SWING, DIED)
        snap = s.snapshot(0)
        self.assertEqual(snap["session"]["deaths"], 1)
        self.assertEqual(snap["deaths"][0]["killer"], "Giant Grizzled Bear")
        self.assertTrue(snap["fights"][0]["died"])
        self.assertEqual(snap["feed"][0]["kind"], "death")


class Others(unittest.TestCase):
    def test_enemy_player_is_listed_and_announced_once(self):
        s = state(MAP, BEAR_LANDED, ENEMY, ENEMY)
        now = livelog.parse_time("11/8/2026 21:41:15.000-3")
        snap = s.snapshot(now)
        self.assertEqual(len(snap["players"]), 1)
        p = snap["players"][0]
        self.assertEqual((p["name"], p["hostile"], p["itemLevel"]), ("Fæng Stonepaw", True, 24))
        self.assertEqual(sum(1 for n in snap["feed"] if n["kind"] == "hostile"), 1)

    def test_players_drop_off_after_two_minutes(self):
        s = state(MAP, BEAR_LANDED, ENEMY)
        t = livelog.parse_time("11/8/2026 21:41:10.000-3")
        s.tick(t + livelog.OTHERS_TTL + 1)
        self.assertEqual(s.snapshot(t + livelog.OTHERS_TTL + 1)["players"], [])

    def test_lines_before_you_appear_are_ignored_and_junk_does_not_crash(self):
        s = state("", "not a log line", "11/8/2026 21:40:48.827-3  SPELL_DAMAGE,broken", ENEMY)
        self.assertIsNone(s.snapshot(0)["me"])


ROW = {1: {"min": 5, "market": 5, "units": 1, "listings": 1}}
T0 = 1794000000   # a real time: the engine's week maths cannot go back to 1970 on Windows


class MarketWatch(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.mkdtemp()
        self.old = server.DATA
        server.DATA = self.data
        self.store = market_store.Store(os.path.join(self.data, "market.db"))
        self.store.record(113, T0, ROW, {}, {})
        self.app = server.App("wow", 0)

    def tearDown(self):
        self.store.close()
        server.DATA = self.old

    def test_new_snapshot_runs_the_engine_then_builds(self):
        app, store = self.app, self.store
        calls = []
        app.build = lambda: calls.append(1)
        sig = app.market_signature()
        self.assertEqual(app.market_tick(sig), sig)
        self.assertEqual(calls, [])                      # nothing new: no build
        store.record(113, T0 + 3600, ROW, {}, {})
        new = app.market_tick(sig)
        self.assertNotEqual(new, sig)
        self.assertTrue(os.path.isfile(os.path.join(self.data, "market.lua")))   # the tick ran the engine
        self.assertEqual(calls, [1])                     # a new snapshot: one build
        self.assertEqual(app.market_tick(new), new)
        self.assertEqual(calls, [1])
        # a rollup moves profile_state.upto, which also counts as a change
        store.db.execute("INSERT INTO profile_state VALUES (113, 5)")
        store.db.commit()
        self.assertNotEqual(app.market_signature(), new)

    def test_no_rebuild_when_the_engine_wrote_nothing(self):
        calls = []
        self.app.build = lambda: calls.append(1)
        with mock.patch.object(server.market, "run", return_value="unchanged") as run:
            self.app.market_tick("stale")
        self.assertEqual(run.call_count, 1)
        self.assertEqual(calls, [])

    def lua_ok(self):
        return mock.patch.object(server.subprocess, "run",
                                 return_value=subprocess.CompletedProcess([], 0, stdout="built", stderr=""))

    def test_build_never_runs_the_engine(self):
        with mock.patch.object(server.market, "run") as run, self.lua_ok() as lua:
            self.app.build()
        run.assert_not_called()
        self.assertEqual(lua.call_count, 1)
        self.assertTrue(self.app.last_build["ok"])

    def test_a_failing_engine_is_logged_and_the_page_still_builds(self):
        for err in (RuntimeError("boom"), sqlite3.OperationalError("database is locked")):
            with self.subTest(err=err):
                app = server.App("wow", 0)
                built = []
                real_build, app.build = app.build, lambda: built.append(1)
                with mock.patch.object(server.market, "run", side_effect=err) as run:
                    with self.assertLogs("server", "ERROR") as logs:
                        app.market_tick("stale")
                    self.assertIn("market engine failed", logs.output[0])
                    self.assertEqual(built, [])            # nothing new to show: no rebuild from the tick
                    app.build = real_build
                    with self.lua_ok() as lua:
                        app.build()                        # a later build runs build.lua and never the engine
                    self.assertEqual(run.call_count, 1)
                self.assertEqual(lua.call_count, 1)
                self.assertTrue(app.last_build["ok"])

    def test_a_locked_db_never_stops_the_page_build(self):
        self.store.db.execute("PRAGMA locking_mode=EXCLUSIVE")   # the fetcher mid-write, as readers see it
        self.store.db.execute("BEGIN EXCLUSIVE")
        connect = sqlite3.connect
        try:
            built = []
            real_build, self.app.build = self.app.build, lambda: built.append(1)
            # readers give up at once instead of after the default 5 s
            with mock.patch.object(server.market.sqlite3, "connect", lambda *a, **k: connect(*a, timeout=0, **k)):
                self.app.market_tick("stale")
            self.assertFalse(os.path.exists(os.path.join(self.data, "market.lua")))   # the engine could not read
            self.assertEqual(built, [])
            self.app.build = real_build
            with self.lua_ok() as lua:
                self.app.build()
            self.assertEqual(lua.call_count, 1)
        finally:
            self.store.db.rollback()

    def test_startup_runs_the_engine_before_the_first_build(self):
        order = []
        self.app.run_engine = lambda: order.append("engine")
        self.app.build = lambda: order.append("build")
        self.app.stop.set()                              # leave the poll loop at once
        self.app.watch_sv()
        self.assertEqual(order, ["engine", "build"])

    def test_market_tick_reruns_on_wanted_change(self):
        app = self.app
        built = []
        app.build = lambda: built.append(1)
        sig = app.market_signature()
        app.market_tick("stale")                         # the first engine run and build
        self.assertEqual(built, [1])
        self.assertEqual(app.market_tick(sig), sig)      # nothing changed: nothing runs
        self.assertEqual(built, [1])
        with open(os.path.join(self.data, "market_wanted.tsv"), "w", encoding="utf-8") as fh:
            fh.write("PvP Horde\t1\n")
        new = app.market_signature()
        self.assertNotEqual(new, sig)
        self.assertEqual(app.market_tick(sig), new)      # one tick: engine and build
        self.assertEqual(built, [1, 1])

    def test_signature_is_empty_without_a_db(self):
        old = server.DATA
        server.DATA = tempfile.mkdtemp()
        try:
            self.assertEqual(server.App("wow", 0).market_signature(), "")
        finally:
            server.DATA = old


class HistoryEndpoint(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.mkdtemp()
        self.old = server.DATA
        server.DATA = self.data
        self.app = server.App("wow", 0)
        self.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.app))
        self.app.port = self.httpd.server_address[1]
        self.httpd.RequestHandlerClass = server.make_handler(self.app)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        server.DATA = self.old

    def get(self, query, host=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.app.port)
        conn.request("GET", "/history" + query, headers={"Host": host or "127.0.0.1:%d" % self.app.port})
        r = conn.getresponse()
        body = r.read()
        conn.close()
        return r.status, r.getheader("Cache-Control"), body

    def make_db(self):
        store = market_store.Store(os.path.join(self.data, "market.db"))
        store.record(113, T0, ROW, {}, {})
        store.close()

    def test_history_endpoint_bad_params(self):
        self.make_db()
        for q in ("?house=x&item=1", "?house=113", "?house=113&item=-1", "?house=0&item=1", ""):
            with self.subTest(q=q):
                self.assertEqual(self.get(q)[0], 400)

    def test_history_no_db_404(self):
        self.assertEqual(self.get("?house=113&item=1")[0], 404)

    def test_history_returns_rows_and_never_writes(self):
        self.make_db()
        before = os.stat(os.path.join(self.data, "market.db")).st_mtime_ns
        code, cache, body = self.get("?house=113&item=1")
        self.assertEqual((code, cache), (200, "no-store"))
        got = json.loads(body)
        self.assertEqual(got["hourly"], [[T0, 5, 5, 1]])
        self.assertEqual(os.stat(os.path.join(self.data, "market.db")).st_mtime_ns, before)

    def test_history_unknown_item_empty(self):
        self.make_db()
        code, _, body = self.get("?house=113&item=424242")
        self.assertEqual(code, 200)
        got = json.loads(body)
        self.assertEqual((got["hourly"], got["daily"], got["week"]), ([], [], None))

    def test_history_wrong_host_403(self):
        self.make_db()
        self.assertEqual(self.get("?house=113&item=1", host="evil.example:80")[0], 403)

    def test_history_failure_is_503(self):
        self.make_db()
        with mock.patch.object(server.market, "history", side_effect=RuntimeError("boom")):
            with self.assertLogs("server", "ERROR"):
                self.assertEqual(self.get("?house=113&item=1")[0], 503)


if __name__ == "__main__":
    unittest.main(verbosity=1)
