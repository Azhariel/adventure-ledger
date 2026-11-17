"""Battle.net API client for the WoW Forever auction houses (standard library only)."""
import base64
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


class Config:
    def __init__(self, client_id, secret, region="us", ruleset=1, faction=113, neutral=116, every=60):
        self.client_id = client_id
        self.secret = secret
        self.region = region
        self.ruleset = int(ruleset)
        self.faction = int(faction)
        self.neutral = int(neutral)
        self.every = int(every)   # minutes between fetches

    @classmethod
    def from_cfg(cls, cfg):
        if not cfg.get("bnet_id") or not cfg.get("bnet_secret"):
            return None
        return cls(cfg["bnet_id"], cfg["bnet_secret"], cfg.get("bnet_region", "us"),
                   cfg.get("ah_ruleset", 1), cfg.get("ah_faction", 113),
                   cfg.get("ah_neutral", 116), cfg.get("ah_every", 60))

    def __repr__(self):   # never show the secret
        return "Config(client_id=...%s, region=%r, ruleset=%d, faction=%d, neutral=%d, every=%d)" % (
            self.client_id[-4:], self.region, self.ruleset, self.faction, self.neutral, self.every)


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
        cfg = self.config
        query = urllib.parse.urlencode({"namespace": "dynamic-forever-" + cfg.region, "locale": "en_US"})
        url = "https://%s.api.blizzard.com%s?%s" % (cfg.region, path, query)
        refreshed = False
        attempt = 0
        while True:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + self._bearer()})
            try:
                with self.opener(req, timeout=TIMEOUT) as resp:
                    return json.loads(resp.read())
            except urllib.error.HTTPError as e:
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
        base = "/data/wow/ruleset/%d/auctions/%d" % (self.config.ruleset, house)
        auctions = self.get(base).get("auctions") or []
        commodities = self.get(base + "/commodities").get("auctions") or []
        return auctions, commodities
