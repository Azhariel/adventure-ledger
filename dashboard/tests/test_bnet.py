"""Tests for bnet.py (Battle.net client), with a fake opener: no network.   Usage: python dashboard/tests/test_bnet.py"""
import io
import json
import os
import sys
import unittest
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import bnet  # noqa: E402

CFG = {"bnet_id": "abcd1234", "bnet_secret": "s3cret"}
GET_PATH = "/data/wow/ruleset/1/auctions/113"


class Resp(io.BytesIO):
    def __init__(self, data, headers=None):
        super().__init__(data)
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeOpener:
    """Token requests get a token; other requests pop a canned (status, body[, headers]) from `script`."""
    def __init__(self, script=(), token_status=200):
        self.script = list(script)
        self.token_status = token_status
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        if "oauth.battle.net" in req.full_url:
            return self._reply(self.token_status, {"access_token": "tok%d" % (len(self.tokens()) - 1), "expires_in": 1000})
        status, body, *headers = self.script.pop(0)
        return self._reply(status, body, headers[0] if headers else None)

    def _reply(self, status, body, headers=None):
        if status >= 300:   # like the real urlopen, which raises for 304 too
            raise urllib.error.HTTPError("u", status, "err", {}, io.BytesIO(b""))
        return Resp(json.dumps(body).encode(), headers)

    def tokens(self):
        return [r for r in self.requests if "oauth.battle.net" in r.full_url]

    def gets(self):
        return [r for r in self.requests if "oauth.battle.net" not in r.full_url]


class Log:
    def __init__(self):
        self.lines = []

    def __getattr__(self, level):
        return lambda msg, *args: self.lines.append(msg % args)


class BnetTest(unittest.TestCase):
    def client(self, opener, **kw):
        self.sleeps = []
        self.t = 1000.0
        return bnet.Client(bnet.Config.from_cfg(CFG), opener=opener, sleep=self.sleeps.append, now=lambda: self.t, **kw)

    def test_from_cfg_defaults(self):
        c = bnet.Config.from_cfg(CFG)
        self.assertEqual((c.region, [h["id"] for h in c.houses], c.every), ("us", [113, 116], 10))
        self.assertEqual([h["key"] for h in c.houses], ["PvP Horde", "PvP Neutral"])
        self.assertNotIn("s3cret", repr(c))
        self.assertIn("PvP Horde=113", repr(c))
        self.assertIsNone(bnet.Config.from_cfg({"bnet_secret": "x"}))

    def test_from_cfg_converts_ints(self):
        c = bnet.Config.from_cfg(dict(CFG, ah_ruleset="2", ah_faction="114", ah_neutral="117", ah_every="30"))
        self.assertEqual(([h["key"] for h in c.houses], c.every), (["Normal Horde", "Normal Neutral"], 30))
        self.assertEqual([h["id"] for h in c.houses], [114, 117])

    def test_from_cfg_houses_setting_wins(self):
        c = bnet.Config.from_cfg(dict(CFG, ah_houses="Roleplay PvP 119", ah_faction="114"))
        self.assertEqual([h["id"] for h in c.houses], [119])
        self.assertEqual(c.ruleset_id(119), 15)

    def test_parse_houses_list(self):
        hs = bnet.parse_houses({"ah_houses": "PvP 113, PvP 116, Roleplay PvP 119"})
        self.assertEqual([(h["key"], h["id"]) for h in hs],
                         [("PvP Horde", 113), ("PvP Neutral", 116), ("Roleplay PvP Alliance", 119)])
        self.assertEqual(hs[0], {"key": "PvP Horde", "ruleset": "PvP", "side": "Horde", "id": 113})

    def test_parse_houses_legacy_keys(self):
        hs = bnet.parse_houses({"ah_faction": "113", "ah_neutral": "116"})
        self.assertEqual([h["key"] for h in hs], ["PvP Horde", "PvP Neutral"])

    def test_parse_houses_errors_name_the_entry(self):
        for bad in ("PvP 999", "113", "PvP x", "PvP 113, PvP 113"):
            with self.assertRaises(ValueError) as cm:
                bnet.parse_houses({"ah_houses": bad})
            self.assertIn(bad.split(",")[-1].strip(), str(cm.exception))

    def test_token_cached(self):
        op = FakeOpener([(200, {})] * 3)
        c = self.client(op)
        c.get(GET_PATH)
        c.get(GET_PATH)
        self.assertEqual(len(op.tokens()), 1)
        self.t += 1000 - 60 + 1
        c.get(GET_PATH)
        self.assertEqual(len(op.tokens()), 2)

    def test_url(self):
        op = FakeOpener([(200, {})])
        self.client(op).get(GET_PATH)
        self.assertEqual(op.gets()[0].full_url, "https://us.api.blizzard.com" + GET_PATH
                         + "?namespace=dynamic-forever-us&locale=en_US")
        self.assertEqual(op.gets()[0].get_header("Authorization"), "Bearer tok0")

    def test_401_refreshes_once(self):
        op = FakeOpener([(401, None), (200, {"ok": 1})])
        self.assertEqual(self.client(op).get(GET_PATH), {"ok": 1})
        self.assertEqual(len(op.tokens()), 2)

    def test_401_twice_raises(self):
        op = FakeOpener([(401, None), (401, None)])
        with self.assertRaises(bnet.ApiError) as cm:
            self.client(op).get(GET_PATH)
        self.assertEqual(cm.exception.status, 401)

    def test_retries_then_raises(self):
        op = FakeOpener([(503, None)] * 4)
        c = self.client(op)
        with self.assertRaises(bnet.ApiError) as cm:
            c.get(GET_PATH)
        self.assertEqual(self.sleeps, [5, 15, 45])
        self.assertEqual((cm.exception.status, cm.exception.path), (503, GET_PATH))

    def test_404_not_retried(self):
        op = FakeOpener([(404, None)])
        with self.assertRaises(bnet.ApiError):
            self.client(op).get(GET_PATH)
        self.assertEqual(self.sleeps, [])

    def test_token_failure_hides_secret(self):
        log = Log()
        c = self.client(FakeOpener(token_status=401), log=log)
        with self.assertRaises(bnet.ApiError) as cm:
            c.get(GET_PATH)
        self.assertNotIn("s3cret", str(cm.exception))
        self.assertTrue(log.lines)
        self.assertFalse(any("s3cret" in line or "abcd1234" in line for line in log.lines))

    def test_house_missing_auctions(self):
        op = FakeOpener([(200, {"id": 112}), (200, {})])
        self.assertEqual(self.client(op).house(113), ([], []))

    def test_house_returns_both(self):
        op = FakeOpener([(200, {"auctions": [{"id": 1}]}), (200, {"auctions": [{"id": 2}]})])
        self.assertEqual(self.client(op).house(113), ([{"id": 1}], [{"id": 2}]))
        self.assertTrue(op.gets()[1].full_url.split("?")[0].endswith("/auctions/113/commodities"))


    # house_since: conditional requests, so a fetch that finds nothing new downloads nothing
    LM = "Tue, 17 Nov 2026 22:24:55 GMT"
    LM_T = 1794954295   # the same instant in epoch seconds

    def test_house_since_not_modified(self):
        op = FakeOpener([(304, None), (304, None)])
        self.assertIsNone(self.client(op).house_since(113, self.LM_T))
        self.assertEqual([r.get_header("If-modified-since") for r in op.gets()], [self.LM, self.LM])

    def test_house_since_returns_the_snapshot_time(self):
        op = FakeOpener([(200, {"auctions": [{"id": 1}]}, {"Last-Modified": self.LM}),
                         (200, {"auctions": [{"id": 2}]}, {"Last-Modified": self.LM})])
        self.assertEqual(self.client(op).house_since(113, self.LM_T - 3600),
                         ([{"id": 1}], [{"id": 2}], self.LM_T))

    def test_house_since_without_a_time_asks_plainly(self):
        op = FakeOpener([(200, {"auctions": []}), (200, {"auctions": []})])
        self.assertEqual(self.client(op).house_since(113, None), ([], [], None))
        self.assertEqual([r.get_header("If-modified-since") for r in op.gets()], [None, None])

    def test_house_since_one_changed_fetches_the_other_whole(self):
        # a snapshot is both lists: if only one says "changed", the other is downloaded too
        op = FakeOpener([(304, None), (200, {"auctions": [{"id": 2}]}, {"Last-Modified": self.LM}),
                         (200, {"auctions": [{"id": 1}]}, {"Last-Modified": self.LM})])
        self.assertEqual(self.client(op).house_since(113, self.LM_T - 3600),
                         ([{"id": 1}], [{"id": 2}], self.LM_T))
        self.assertIsNone(op.gets()[2].get_header("If-modified-since"))

    def test_bad_last_modified_is_ignored(self):
        op = FakeOpener([(200, {"auctions": []}, {"Last-Modified": "soon"}), (200, {"auctions": []})])
        self.assertEqual(self.client(op).house_since(113, None), ([], [], None))

    def test_not_modified_is_not_retried(self):
        op = FakeOpener([(304, None), (304, None)])
        self.client(op).house_since(113, self.LM_T)
        self.assertEqual(self.sleeps, [])


if __name__ == "__main__":
    unittest.main()
