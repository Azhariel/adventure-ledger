"""Tests for b2.py against a fake B2 on 127.0.0.1.   Usage: python dashboard/tests/test_b2.py"""
import base64
import hashlib
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import b2  # noqa: E402

KEY_ID, KEY, BUCKET = "kid123", "K3Y-SECRET", "ledger-sync"


class Fake:
    """State of the fake service: stored files, what it saw, and the faults to inject."""

    def __init__(self):
        self.files = {}           # name -> (bytes, info, uploaded ms)
        self.seen = []            # (method, path, headers dict)
        self.upload_urls = 0
        self.fail_upload = 0      # answer this many uploads 401 expired_auth_token
        self.bad_sha1 = False
        self.auth_fail = None     # (status, code, extra body text)
        self.page = 1000          # max files per list page
        self.list_503 = 0         # answer this many listings 503


def make_handler(fake):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n else b""

        def _base(self):
            return "http://127.0.0.1:%d" % self.server.server_address[1]

        def do_GET(self):
            fake.seen.append(("GET", self.path, dict(self.headers)))
            if self.path.startswith("/b2api/v3/b2_authorize_account"):
                if fake.auth_fail:
                    status, code, extra = fake.auth_fail
                    return self._json(status, {"status": status, "code": code,
                                               "message": "rejected " + extra + self.headers.get("Authorization", "")})
                want = "Basic " + base64.b64encode(("%s:%s" % (KEY_ID, KEY)).encode()).decode()
                if self.headers.get("Authorization") != want:
                    return self._json(401, {"status": 401, "code": "unauthorized", "message": "bad key"})
                base = self._base()
                return self._json(200, {"accountId": "acc", "authorizationToken": "TOK", "apiInfo": {"storageApi": {
                    "apiUrl": base, "downloadUrl": base,
                    "allowed": {"buckets": [{"id": "BID", "name": BUCKET}]}}}})
            if self.path.startswith("/file/"):
                name = urllib.parse.unquote(self.path[len("/file/%s/" % BUCKET):])
                if name not in fake.files:
                    return self._json(404, {"status": 404, "code": "not_found", "message": "no such file"})
                data = fake.files[name][0]
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("X-Bz-Content-Sha1", "0" * 40 if fake.bad_sha1 else hashlib.sha1(data).hexdigest())
                self.end_headers()
                self.wfile.write(data)
                return
            self._json(404, {"status": 404, "code": "not_found", "message": self.path})

        def do_POST(self):
            fake.seen.append(("POST", self.path, dict(self.headers)))
            body = self._body()
            if self.path == "/b2api/v3/b2_get_upload_url":
                fake.upload_urls += 1
                return self._json(200, {"uploadUrl": self._base() + "/upload", "authorizationToken": "UTOK"})
            if self.path == "/upload":
                if fake.fail_upload:
                    fake.fail_upload -= 1
                    return self._json(401, {"status": 401, "code": "expired_auth_token", "message": "expired"})
                name = urllib.parse.unquote(self.headers["X-Bz-File-Name"])   # headers are case-insensitive here
                info = {k[len("X-Bz-Info-"):]: urllib.parse.unquote(v) for k, v in self.headers.items()
                        if k.lower().startswith("x-bz-info-")}
                info = {k.lower(): v for k, v in info.items()}
                if hashlib.sha1(body).hexdigest() != self.headers["X-Bz-Content-Sha1"]:
                    return self._json(400, {"status": 400, "code": "bad_request", "message": "sha1 mismatch"})
                fake.files[name] = (body, info, 1700000000000 + len(fake.files))
                return self._json(200, {"fileName": name, "contentLength": len(body)})
            if self.path == "/b2api/v3/b2_list_file_names" and fake.list_503:
                fake.list_503 -= 1
                return self._json(503, {"status": 503, "code": "service_unavailable", "message": "busy"})
            if self.path == "/b2api/v3/b2_list_file_names":
                req = json.loads(body)
                names = sorted(n for n in fake.files if n.startswith(req.get("prefix", ""))
                               and n >= (req.get("startFileName") or ""))
                page, rest = names[:fake.page], names[fake.page:]
                return self._json(200, {"files": [{"fileName": n, "contentLength": len(fake.files[n][0]),
                                                   "uploadTimestamp": fake.files[n][2], "fileInfo": fake.files[n][1]}
                                                  for n in page],
                                        "nextFileName": rest[0] if rest else None})
            self._json(404, {"status": 404, "code": "not_found", "message": self.path})
    return H


class B2Tests(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.fake))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/b2api/v3/b2_authorize_account" % self.httpd.server_address[1]
        self.dir = tempfile.TemporaryDirectory()
        self.client = b2.Client(KEY_ID, KEY, BUCKET, auth_url=self.url, delays=(0, 0, 0))

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.dir.cleanup()

    def file(self, name, data):
        path = os.path.join(self.dir.name, name)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_upload_sends_sha1_and_info(self):
        data = b"zip bytes" * 1000
        self.client.upload("wtf/egb.zip", self.file("a.zip", data), {"pc": "egb", "at": "123"})
        up = {k.lower(): v for k, v in [h for m, p, h in self.fake.seen if p == "/upload"][-1].items()}
        self.assertEqual(up["x-bz-content-sha1"], hashlib.sha1(data).hexdigest())
        self.assertEqual(up["x-bz-info-pc"], "egb")
        self.assertEqual(self.fake.files["wtf/egb.zip"][0], data)

    def test_upload_reports_progress(self):
        seen = []
        self.client.upload("x.bin", self.file("x.bin", b"a" * 300000), {}, progress=lambda s, t: seen.append((s, t)))
        self.assertEqual(seen[-1], (300000, 300000))

    def test_upload_retries_expired_token(self):
        self.fake.fail_upload = 1
        self.client.upload("wtf/egb.zip", self.file("a.zip", b"x"), {})
        self.assertEqual(self.fake.upload_urls, 2)
        self.assertIn("wtf/egb.zip", self.fake.files)

    def test_download_checks_sha1(self):
        self.client.upload("m.zip", self.file("m.zip", b"payload"), {})
        dest = os.path.join(self.dir.name, "out.zip")
        self.client.download("m.zip", dest)
        with open(dest, "rb") as fh:
            self.assertEqual(fh.read(), b"payload")
        os.remove(dest)
        self.fake.bad_sha1 = True
        with self.assertRaises(b2.B2Error) as cm:
            self.client.download("m.zip", dest)
        self.assertEqual(cm.exception.code, "bad_sha1")
        self.assertFalse(os.path.exists(dest))

    def test_list_returns_info_and_follows_pages(self):
        self.client.upload("wtf/a.zip", self.file("a", b"1"), {"pc": "a"})
        self.client.upload("wtf/b.zip", self.file("b", b"22"), {"pc": "b", "latest": "99"})
        self.client.upload("market/market.zip", self.file("c", b"3"), {})
        self.fake.page = 1
        got = self.client.list("wtf/")
        self.assertEqual([f["name"] for f in got], ["wtf/a.zip", "wtf/b.zip"])
        self.assertEqual(got[1]["info"]["latest"], "99")
        self.assertEqual(got[1]["size"], 2)
        self.assertLess(got[0]["uploaded"], 1e10)   # seconds, not B2's milliseconds

    def test_list_without_retry_tries_once(self):
        self.fake.list_503 = 1
        with self.assertRaises(b2.B2Error) as cm:
            self.client.list("wtf/", retry=False)
        self.assertEqual(cm.exception.status, 503)
        self.fake.list_503 = 1
        self.assertEqual(self.client.list("wtf/"), [], "the default still retries")

    def test_errors_never_contain_key(self):
        self.fake.auth_fail = (401, "bad_auth_token", KEY)
        with self.assertRaises(b2.B2Error) as cm:
            self.client.list("wtf/")
        err = cm.exception
        self.assertEqual(err.status, 401)
        for text in (str(err), repr(err), err.message):
            self.assertNotIn(KEY, text)
            self.assertNotIn(base64.b64encode(("%s:%s" % (KEY_ID, KEY)).encode()).decode(), text)

    def test_network_error_is_b2error(self):
        port = self.httpd.server_address[1]
        self.httpd.shutdown()
        self.httpd.server_close()
        client = b2.Client(KEY_ID, KEY, BUCKET, auth_url="http://127.0.0.1:%d/x" % port, delays=())
        with self.assertRaises(b2.B2Error) as cm:
            client.list("")
        self.assertEqual(cm.exception.code, "network")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.fake))   # for tearDown
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()


if __name__ == "__main__":
    unittest.main()
