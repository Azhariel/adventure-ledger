"""Battle.net API client for the WoW Forever auction houses (standard library only)."""
import base64
import email.utils
import json
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://oauth.battle.net/token"
TIMEOUT = 120
RETRY_DELAYS = (5, 15, 45)   # seconds between attempts on 429 / 5xx / timeout


class ApiError(Exception):
    def __init__(self, status, path):
        super().__init__("Battle.net API error %s for %s" % (status or "timeout", path))
        self.status = status
        self.path = path


# The API's houses come in sets of three (Alliance / Horde / Neutral), so the side follows from the id
SIDE_OF = {}
for _ids in ((110, 113, 116), (111, 114, 117), (119, 120, 121), (123, 124, 125)):
    SIDE_OF.update(zip(_ids, ("Alliance", "Horde", "Neutral")))

# Only used by the legacy ah_ruleset key (and to build the API path); "PvP" is the only name verified in game
RULESETS = {1: "PvP", 2: "Normal", 3: "Roleplay", 15: "Roleplay PvP"}


def parse_houses(cfg):
    """The houses to fetch, in config order: [{"key": "PvP Horde", "ruleset": "PvP", "side": "Horde", "id": 113}].
    `ah_houses = PvP 113, PvP 116` (last token is the id, the rest the ruleset name); without it, the legacy
    ah_ruleset / ah_faction / ah_neutral keys. Raises ValueError naming the bad entry."""
    raw = str(cfg.get("ah_houses") or "").strip()
    if raw:
        entries = [e.strip() for e in raw.split(",")]
    else:
        try:
            name = RULESETS[int(cfg.get("ah_ruleset") or 1)]
            ids = (int(cfg.get("ah_faction") or 113), int(cfg.get("ah_neutral") or 116))
        except (KeyError, ValueError) as e:
            raise ValueError("bad legacy house setting: %s" % e) from None
        entries = ["%s %d" % (name, i) for i in ids]
    houses, seen = [], set()
    for entry in entries:
        *words, last = entry.split() or [""]
        if not words:
            raise ValueError("%r needs a ruleset name before the id" % entry)
        try:
            house_id = int(last)
        except ValueError:
            raise ValueError("%r: %r is not a house id" % (entry, last)) from None
        if house_id not in SIDE_OF:
            raise ValueError("%r: unknown house id %d" % (entry, house_id))
        if house_id in seen:
            raise ValueError("%r: house %d is listed twice" % (entry, house_id))
        seen.add(house_id)
        ruleset = " ".join(words)
        side = SIDE_OF[house_id]
        houses.append({"key": "%s %s" % (ruleset, side), "ruleset": ruleset, "side": side, "id": house_id})
    return houses


class Config:
    def __init__(self, client_id, secret, region="us", houses=None, every=10):
        self.client_id = client_id
        self.secret = secret
        self.region = region
        self.houses = houses if houses is not None else parse_houses({})
        self.every = int(every)   # minutes between fetches

    # until the fetcher reads houses (next task)
    @property
    def faction(self):
        return next((h["id"] for h in self.houses if h["side"] != "Neutral"), None)

    # until the fetcher reads houses (next task)
    @property
    def neutral(self):
        return next((h["id"] for h in self.houses if h["side"] == "Neutral"), None)

    @classmethod
    def from_cfg(cls, cfg):
        if not cfg.get("bnet_id") or not cfg.get("bnet_secret"):
            return None
        return cls(cfg["bnet_id"], cfg["bnet_secret"], cfg.get("bnet_region", "us"),
                   parse_houses(cfg), cfg.get("ah_every", 10))

    def ruleset_id(self, house):
        """The API path's ruleset number for a configured house (1 when the name isn't one we know)."""
        name = next((h["ruleset"] for h in self.houses if h["id"] == house), None)
        return next((i for i, n in RULESETS.items() if n == name), 1)

    def __repr__(self):   # never show the secret
        return "Config(client_id=...%s, region=%r, houses=[%s], every=%d)" % (
            self.client_id[-4:], self.region,
            ", ".join("%s=%d" % (h["key"], h["id"]) for h in self.houses), self.every)


class Client:
    def __init__(self, config, opener=urllib.request.urlopen, sleep=time.sleep, now=time.time, log=None):
        self.config = config
        self.opener = opener
        self.sleep = sleep
        self.now = now
        self.log = log
        self._token = None
        self._token_until = 0

    def _say(self, level, msg, *args):
        if self.log is not None:
            getattr(self.log, level)(msg, *args)

    def _fetch_token(self):
        cred = "%s:%s" % (self.config.client_id, self.config.secret)
        req = urllib.request.Request(
            TOKEN_URL, data=b"grant_type=client_credentials", method="POST",
            headers={"Authorization": "Basic " + base64.b64encode(cred.encode()).decode(),
                     "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with self.opener(req, timeout=TIMEOUT) as resp:
                body = json.loads(resp.read())
            self._token = body["access_token"]
            # renew a minute early so a token never expires mid-request
            self._token_until = self.now() + int(body["expires_in"]) - 60
        except urllib.error.HTTPError as e:
            self._say("error", "token request failed: HTTP %s (client ...%s)", e.code, self.config.client_id[-4:])
            raise ApiError(e.code, "/token") from None
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            self._say("error", "token request failed: %s", type(e).__name__)
            raise ApiError(0, "/token") from None

    def _bearer(self):
        if self._token is None or self.now() >= self._token_until:
            self._fetch_token()
        return self._token

    def get(self, path):
        return self.get_since(path, None)[0]

    def get_since(self, path, since):
        """(body, Last-Modified in epoch seconds or None). With `since` (epoch seconds), asks only for data
        newer than that: (None, None) when Blizzard answers 304 Not Modified."""
        cfg = self.config
        query = urllib.parse.urlencode({"namespace": "dynamic-forever-" + cfg.region, "locale": "en_US"})
        url = "https://%s.api.blizzard.com%s?%s" % (cfg.region, path, query)
        refreshed = False
        attempt = 0
        while True:
            headers = {"Authorization": "Bearer " + self._bearer()}
            if since is not None:
                headers["If-Modified-Since"] = email.utils.formatdate(since, usegmt=True)
            req = urllib.request.Request(url, headers=headers)
            try:
                with self.opener(req, timeout=TIMEOUT) as resp:
                    return json.loads(resp.read()), http_time(resp.headers.get("Last-Modified"))
            except urllib.error.HTTPError as e:
                if e.code == 304:
                    return None, None
                status = e.code
            except (urllib.error.URLError, OSError):   # includes timeouts
                status = 0
            if status == 401 and not refreshed:
                refreshed = True
                self._say("info", "token rejected for %s, refreshing", path)
                self._token = None
                continue
            if (status in (0, 429) or status >= 500) and attempt < len(RETRY_DELAYS):
                delay = RETRY_DELAYS[attempt]
                attempt += 1
                self._say("warning", "%s for %s, retrying in %ds", status or "timeout", path, delay)
                self.sleep(delay)
                continue
            raise ApiError(status, path)

    def house(self, house):
        base = "/data/wow/ruleset/%d/auctions/%d" % (self.config.ruleset_id(house), house)
        auctions = self.get(base).get("auctions") or []
        commodities = self.get(base + "/commodities").get("auctions") or []
        return auctions, commodities

    def house_since(self, house, since):
        """(auctions, commodities, snapshot time or None), or None when neither list changed after `since`.
        The snapshot time is Blizzard's Last-Modified, the moment the data was made, not when we fetched it."""
        base = "/data/wow/ruleset/%d/auctions/%d" % (self.config.ruleset_id(house), house)
        auctions, a_mod = self.get_since(base, since)
        commodities, c_mod = self.get_since(base + "/commodities", since)
        if auctions is None and commodities is None:
            return None
        # One list is new: the snapshot is both, so fetch the unchanged one whole
        if auctions is None:
            auctions, a_mod = self.get_since(base, None)
        if commodities is None:
            commodities, c_mod = self.get_since(base + "/commodities", None)
        mods = [m for m in (a_mod, c_mod) if m is not None]
        return (auctions.get("auctions") or [], commodities.get("auctions") or [], max(mods) if mods else None)


def http_time(value):
    """An HTTP date ("Tue, 17 Nov 2026 22:24:55 GMT") in epoch seconds; None if missing or unreadable."""
    if not value:
        return None
    try:
        return int(email.utils.parsedate_to_datetime(value).timestamp())
    except (TypeError, ValueError, IndexError):
        return None
