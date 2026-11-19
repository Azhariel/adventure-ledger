"""Backblaze B2 client for the sync between PCs (native API v3, standard library only).

Never puts the application key, the key id:key pair or a token into an exception, a log line or a return value:
B2's own error text is passed through a scrubber that removes them."""
import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

AUTH_URL = "https://api.backblazeb2.com/b2api/v3/b2_authorize_account"
TIMEOUT = 120
RETRY_DELAYS = (5, 15, 45)   # seconds between attempts on 503 / timeout / an expired upload token (as bnet.py)
CHUNK = 256 * 1024


class B2Error(Exception):
    """status: HTTP status (0 for network trouble); code and message from B2's JSON error (scrubbed)."""

    def __init__(self, status, code, message):
        super().__init__("%s: %s" % (code, message))
        self.status = status
        self.code = code
        self.message = message

    def __repr__(self):
        return "B2Error(%r, %r, %r)" % (self.status, self.code, self.message)


class _Body:
    """A file streamed to urllib with a progress callback."""

    def __init__(self, fh, total, progress):
        self.fh, self.total, self.progress, self.sent = fh, total, progress, 0

    def read(self, n=-1):
        data = self.fh.read(CHUNK if n is None or n < 0 else min(n, CHUNK))
        self.sent += len(data)
        if self.progress:
            self.progress(self.sent, self.total)
        return data


def _sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _quote(s):
    return urllib.parse.quote(s, safe="/")


class Client:
    def __init__(self, key_id, key, bucket, auth_url=AUTH_URL, delays=RETRY_DELAYS, sleep=time.sleep,
                 opener=urllib.request.urlopen):
        self._key_id, self._key, self.bucket = key_id, key, bucket
        self.auth_url, self.delays, self.sleep, self.opener = auth_url, tuple(delays), sleep, opener
        self._acct = None   # {"api", "download", "token", "bucket_id"}
        self._secrets = [key, "%s:%s" % (key_id, key),
                         base64.b64encode(("%s:%s" % (key_id, key)).encode()).decode()]

    # ---------------------------------------------------------------- plumbing
    def _scrub(self, text):
        text = str(text)
        for s in self._secrets:
            if s:
                text = text.replace(s, "***")
        return text[:300]

    def _error(self, status, raw):
        try:
            obj = json.loads(raw)
            code, msg = str(obj.get("code") or "error"), str(obj.get("message") or "")
        except (ValueError, AttributeError):
            code, msg = "error", "HTTP %s" % status
        return B2Error(status, self._scrub(code), self._scrub(msg))

    def _open(self, req):
        """(response) or raises B2Error; network trouble is status 0."""
        try:
            return self.opener(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as e:
            try:
                raw = e.read()
            except OSError:
                raw = b""
            raise self._error(e.code, raw) from None
        except (urllib.error.URLError, OSError) as e:
            raise B2Error(0, "network", self._scrub(getattr(e, "reason", e))) from None

    def _retrying(self, fn):
        """Call fn(); retry on 503, network trouble and 401 (after dropping the token) as B2 asks."""
        attempt, reauthed = 0, False
        while True:
            try:
                return fn()
            except B2Error as e:
                if e.status == 401 and e.code in ("expired_auth_token", "bad_auth_token") and not reauthed \
                        and self._acct is not None:
                    reauthed, self._acct = True, None
                    continue
                if e.status in (0, 429, 503) and attempt < len(self.delays):
                    self.sleep(self.delays[attempt])
                    attempt += 1
                    continue
                raise

    def _authorize(self):
        if self._acct:
            return self._acct
        basic = base64.b64encode(("%s:%s" % (self._key_id, self._key)).encode()).decode()
        req = urllib.request.Request(self.auth_url, headers={"Authorization": "Basic " + basic})
        with self._open(req) as resp:
            obj = json.loads(resp.read())
        self._secrets.append(obj.get("authorizationToken") or "")
        api = obj.get("apiInfo", {}).get("storageApi", {})
        acct = {"api": api.get("apiUrl"), "download": api.get("downloadUrl"), "token": obj.get("authorizationToken"),
                "account": obj.get("accountId"), "bucket_id": None}
        for b in (api.get("allowed") or {}).get("buckets") or []:
            if b and b.get("name") == self.bucket:
                acct["bucket_id"] = b.get("id")
        self._acct = acct
        if not acct["bucket_id"]:
            got = self._call("b2_list_buckets", {"accountId": acct["account"], "bucketName": self.bucket})
            ids = [b.get("bucketId") for b in got.get("buckets") or [] if b.get("bucketName") == self.bucket]
            if not ids:
                self._acct = None
                raise B2Error(404, "no_bucket", "bucket %s not found for this key" % self.bucket)
            acct["bucket_id"] = ids[0]
        return acct

    def _call(self, name, body):
        acct = self._authorize()
        req = urllib.request.Request(acct["api"] + "/b2api/v3/" + name, data=json.dumps(body).encode(),
                                     headers={"Authorization": acct["token"], "Content-Type": "application/json"})
        with self._open(req) as resp:
            return json.loads(resp.read())

    # ---------------------------------------------------------------- API
    def list(self, prefix):
        """Every file under prefix: [{"name", "size", "uploaded" (unix seconds), "info"}]."""
        def run():
            out, start = [], None
            while True:
                body = {"bucketId": self._authorize()["bucket_id"], "prefix": prefix, "maxFileCount": 1000}
                if start:
                    body["startFileName"] = start
                got = self._call("b2_list_file_names", body)
                for f in got.get("files") or []:
                    out.append({"name": f.get("fileName"), "size": f.get("contentLength") or 0,
                                "uploaded": (f.get("uploadTimestamp") or 0) / 1000.0, "info": f.get("fileInfo") or {}})
                start = got.get("nextFileName")
                if not start:
                    return out
        return self._retrying(run)

    def upload(self, name, path, info, progress=None):
        sha1, size = _sha1(path), os.path.getsize(path)

        def run():
            up = self._call("b2_get_upload_url", {"bucketId": self._authorize()["bucket_id"]})
            self._secrets.append(up.get("authorizationToken") or "")
            headers = {"Authorization": up["authorizationToken"], "X-Bz-File-Name": _quote(name),
                       "Content-Type": "b2/x-auto", "Content-Length": str(size), "X-Bz-Content-Sha1": sha1}
            for k, v in (info or {}).items():
                headers["X-Bz-Info-" + k] = _quote(str(v))
            with open(path, "rb") as fh:
                req = urllib.request.Request(up["uploadUrl"], data=_Body(fh, size, progress), headers=headers,
                                             method="POST")
                try:
                    with self._open(req) as resp:
                        return json.loads(resp.read())
                except B2Error as e:
                    if e.status == 401 and e.code == "expired_auth_token":
                        # an upload URL's token expired: B2 says get a new upload URL, not a new account token
                        raise B2Error(503, e.code, e.message) from None
                    raise
        return self._retrying(run)

    def download(self, name, dest, progress=None):
        def run():
            acct = self._authorize()
            req = urllib.request.Request("%s/file/%s/%s" % (acct["download"], _quote(self.bucket), _quote(name)),
                                         headers={"Authorization": acct["token"]})
            h = hashlib.sha1()
            try:
                with self._open(req) as resp, open(dest, "wb") as out:
                    want = resp.headers.get("X-Bz-Content-Sha1")
                    total, got = int(resp.headers.get("Content-Length") or 0), 0
                    for block in iter(lambda: resp.read(CHUNK), b""):
                        out.write(block)
                        h.update(block)
                        got += len(block)
                        if progress:
                            progress(got, total)
                if want and want != "none" and not want.startswith("unverified:") and want != h.hexdigest():
                    raise B2Error(200, "bad_sha1", "the download of %s was damaged" % name)
                return {"size": got}
            except BaseException:
                try:
                    os.remove(dest)
                except OSError:
                    pass
                raise
        return self._retrying(run)
