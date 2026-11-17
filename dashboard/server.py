"""Adventure Ledger live server: keeps dashboard.html fresh and streams the combat log to the page.

    pythonw server.py            (serve.bat / `wowstats live` start it without a console window)
    python server.py --no-open --port 8737 --wow "E:/World of Warcraft/_forever_"

What it does, all on this computer only (it listens on 127.0.0.1):
  * every 2 s it checks the SavedVariables files; when WoW writes them (/reload, logout) it runs build.lua and tells
    the open page to reload itself
  * every second it reads what WoW added to the newest Logs/WoWCombatLog-*.txt (type /combatlog in game) and sends
    the page a live picture: health, mana, position, fights, kills, players around you
  * it serves the newest screenshot from the Screenshots folder
Standard library only. Stop it with `wowstats stop` (or end pythonw.exe in Task Manager).
"""
import argparse
import glob
import json
import logging
import os
import queue
import re
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def read_config(path=os.path.join(ROOT, "ledger.cfg")):
    """ledger.cfg at the repo root: key = value lines (wow = the _forever_ folder, data = generated files).
    A # starts a comment at the start of a line, or after whitespace anywhere in it."""
    cfg = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    v = re.split(r"\s#", v, maxsplit=1)[0].strip()   # "ah_every = 60  # minutes"; "a#b" stays whole
                    if v:
                        cfg[k.strip()] = v
    except OSError:
        pass
    return cfg


CONFIG = read_config()
DATA = os.path.abspath(os.environ.get("LEDGER_DATA") or CONFIG.get("data") or os.path.join(ROOT, "data"))
os.makedirs(DATA, exist_ok=True)
import ledgerlog  # noqa: E402
import livelog  # noqa: E402
import zones  # noqa: E402
import urllib.request  # noqa: E402

PORT = 8737
SV_POLL, SV_SETTLE, LOG_POLL, PUSH_EVERY = 2.0, 2.0, 1.0, 1.0
MAX_START_READ = 40 * 1024 * 1024   # a huge log is read from its last 40 MB only
LOG_WRITE_EVERY = 300               # WoW Forever writes the combat log on a fixed 5-minute timer (measured)
SESSION_CARRY = 600                 # a new log file within 10 min of the last line continues the session
SHOT_RE = re.compile(r"^[\w .()-]+\.(jpg|jpeg|png|tga)$", re.I)
SHOT_TYPES = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "tga": "image/x-tga"}


# Set up in main(), not here: fetcher.py imports this module, and a second process holding
# server.log open stops the live server rotating it on Windows.
_LOG = logging.getLogger("server")


def log(msg):
    _LOG.info(msg)


def lua_exe():
    cand = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Lua", "bin", "lua.exe")
    return cand if os.path.isfile(cand) else "lua"


class Hub:
    """Server-sent events: one queue per open page."""

    def __init__(self):
        self.lock = threading.Lock()
        self.clients = set()

    def add(self):
        q = queue.Queue(maxsize=50)
        with self.lock:
            self.clients.add(q)
        return q

    def remove(self, q):
        with self.lock:
            self.clients.discard(q)

    def send(self, kind, data):
        msg = "event: %s\ndata: %s\n\n" % (kind, json.dumps(data, separators=(",", ":")))
        with self.lock:
            for q in list(self.clients):
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    pass  # a stalled page skips updates; the next snapshot is complete anyway


class App:
    def __init__(self, wow, port):
        self.wow = wow
        self.port = port
        self.hub = Hub()
        self.lock = threading.Lock()
        self.state = livelog.LiveState()
        self.log_path = None
        self.log_pos = 0
        self.log_rest = b""
        self.skip_partial = False
        self.log_writes = []               # wall times WoW wrote the file (seen by us)
        self.sent_version = -1
        self.build_info = {"ok": None, "at": None, "message": ""}
        self.started = time.time()
        self.last_build = None             # {"t", "ok", "seconds", "message"}, for /status
        self.stop = threading.Event()
        self.map_lock = threading.Lock()

    # ---------------------------------------------------------------- SavedVariables -> build.lua
    def sv_signature(self):
        sig = []
        pats = [
            os.path.join(self.wow, "WTF", "Account", "*", "SavedVariables", "*.lua"),
            os.path.join(self.wow, "WTF", "Account", "*", "*", "*", "SavedVariables", "*.lua"),
            os.path.join(HERE, "template.html"), os.path.join(HERE, "build.lua"), os.path.join(HERE, "lib", "*.lua"),
            os.path.join(DATA, "neutral_days.txt"),
        ]
        for pat in pats:
            for path in glob.glob(pat):
                try:
                    st = os.stat(path)
                    sig.append((path, st.st_mtime_ns, st.st_size))
                except OSError:
                    pass
        return tuple(sorted(sig))

    def build(self):
        t0 = time.time()
        out = os.path.join(DATA, "dashboard.html")
        try:
            r = subprocess.run([lua_exe(), os.path.join(HERE, "build.lua"), self.wow, out], cwd=HERE,
                               capture_output=True, text=True, timeout=120,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            ok = r.returncode == 0
            msg = (r.stdout if ok else (r.stderr or r.stdout)).strip()
        except (OSError, subprocess.SubprocessError) as e:
            ok, msg = False, str(e)
        self.build_info = {"ok": ok, "at": time.time(), "message": msg[-500:]}
        secs = time.time() - t0
        self.last_build = {"t": time.time(), "ok": ok, "seconds": round(secs, 1), "message": msg[-200:]}
        if ok:
            _LOG.info("built in %.1fs: %s", secs, msg[-300:])
        else:
            _LOG.warning("BUILD FAILED after %.1fs: %s", secs, msg[-300:])
        self.hub.send("rebuilt" if ok else "buildError", self.build_info)

    def watch_sv(self):
        last = self.sv_signature()
        self.build()
        while not self.stop.wait(SV_POLL):
            sig = self.sv_signature()
            if sig == last:
                continue
            # WoW writes one file per addon; wait until they stop changing
            while not self.stop.wait(SV_SETTLE):
                again = self.sv_signature()
                if again == sig:
                    break
                sig = again
            last = sig
            self.build()

    # ---------------------------------------------------------------- combat log tail
    def newest_log(self):
        files = glob.glob(os.path.join(self.wow, "Logs", "WoWCombatLog*.txt"))
        return max(files, key=os.path.getmtime) if files else None

    def open_log(self, path, keep=False):
        """Follow path. keep=True carries the session on (WoW opened a new file mid-session, e.g. Ledger Link's
        flush switching logging off and on): the new file is read from its start into the same picture."""
        with self.lock:
            if keep:
                self.state.file = os.path.basename(path)
            else:
                self.state = livelog.LiveState(os.path.basename(path))
        self.log_path, self.log_rest = path, b""
        size = os.path.getsize(path)
        self.log_pos = 0 if keep else max(0, size - MAX_START_READ)
        self.skip_partial = self.log_pos > 0
        log(("continuing in " if keep else "following ") + os.path.basename(path))

    def read_log(self):
        try:
            size = os.path.getsize(self.log_path)
        except OSError:
            return
        if size < self.log_pos:  # truncated or replaced: start over
            self.open_log(self.log_path)
            return
        if size == self.log_pos:
            return
        if self.log_pos > 0:  # not our first read: WoW just wrote
            self.log_writes = (self.log_writes + [time.time()])[-12:]
        with open(self.log_path, "rb") as fh:
            fh.seek(self.log_pos)
            data = fh.read(size - self.log_pos)
        self.log_pos += len(data)
        data = self.log_rest + data
        lines = data.split(b"\n")
        self.log_rest = lines.pop()  # unfinished last line
        if self.skip_partial and lines:
            lines.pop(0)
            self.skip_partial = False
        with self.lock:
            for raw in lines:
                self.state.feed(raw.decode("utf-8", "replace"))

    def watch_log(self):
        checked = 0
        while not self.stop.is_set():
            now = time.time()
            if now - checked > 5 or self.log_path is None:
                checked = now
                newest = self.newest_log()
                if newest and newest != self.log_path:
                    keep = False
                    if self.log_path:
                        try:
                            self.read_log()  # what WoW wrote when it closed the old file
                        except Exception as e:
                            log("log read error: %r" % (e,))
                        last = self.state.last_line
                        keep = last is not None and now - last < SESSION_CARRY
                    self.open_log(newest, keep=keep)
            if self.log_path:
                try:
                    self.read_log()
                except Exception as e:  # keep serving even if one read goes wrong
                    log("log read error: %r" % (e,))
            self.stop.wait(LOG_POLL)

    # ---------------------------------------------------------------- push to pages
    def newest_shot(self):
        best = None
        for path in glob.glob(os.path.join(self.wow, "Screenshots", "*")):
            name = os.path.basename(path)
            if SHOT_RE.match(name):
                m = os.path.getmtime(path)
                if best is None or m > best[1]:
                    best = (name, m)
        return {"name": best[0], "t": best[1]} if best else None

    def snapshot(self):
        now = time.time()
        with self.lock:
            self.state.tick(now)
            snap = self.state.snapshot(now)
            version = self.state.version
        snap["shot"] = self.newest_shot()
        snap["build"] = self.build_info
        snap["logSize"] = self.log_pos
        snap["logWrites"] = self.write_schedule()
        snap["mapImage"] = zones.IMAGE
        snap["mapsWithArt"] = sorted(zones.ZONES)
        return snap, version

    def write_schedule(self):
        """When WoW last wrote the log and when it should next (its timer, learned from the gaps we saw)."""
        try:
            mtime = os.path.getmtime(self.log_path) if self.log_path else None
        except OSError:
            mtime = None
        gaps = sorted(b - a for a, b in zip(self.log_writes, self.log_writes[1:]) if b - a > 30)
        every = gaps[len(gaps) // 2] if gaps else LOG_WRITE_EVERY
        nxt = None
        if mtime:
            nxt = mtime + every
            while nxt < time.time() - 5:
                nxt += every
        return {"last": mtime, "every": round(every), "next": nxt}

    def map_image(self, ui_map):
        """Path of the zone's map image, downloaded from Wowhead's image CDN the first time (None if unknown)."""
        zone = zones.ZONES.get(ui_map)
        if not zone:
            return None
        folder = os.path.join(DATA, "maps")
        path = os.path.join(folder, "%d.jpg" % ui_map)
        missing = path + ".missing"
        with self.map_lock:
            if os.path.isfile(path):
                return path
            if os.path.isfile(missing) and time.time() - os.path.getmtime(missing) < 86400:
                return None  # failed today: don't ask again on every page load
            os.makedirs(folder, exist_ok=True)
            url = zones.IMAGE_URL % zone[0]
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "AdventureLedger/1.0 (personal dashboard)"})
                with urllib.request.urlopen(req, timeout=20) as r:
                    data = r.read()
                if not data.startswith(bytes((0xFF, 0xD8))):
                    raise ValueError("not a JPEG")
                with open(path + ".part", "wb") as fh:
                    fh.write(data)
                os.replace(path + ".part", path)
                log("downloaded map %d (%s)" % (ui_map, zone[1]))
                return path
            except Exception as e:
                log("map %d download failed: %r" % (ui_map, e))
                open(missing, "w").close()
                return None

    def pusher(self):
        beat = 0
        while not self.stop.wait(PUSH_EVERY):
            beat += 1
            with self.lock:
                changed = self.state.version != self.sent_version
            if changed or beat % 5 == 0:  # at least every 5 s so "last line N s ago" stays honest
                snap, version = self.snapshot()
                self.sent_version = version
                self.hub.send("live", snap)


def make_handler(app):
    allowed_hosts = {"127.0.0.1:%d" % app.port, "localhost:%d" % app.port}

    class Handler(BaseHTTPRequestHandler):
        server_version = "AdventureLedger/1"

        def log_message(self, fmt, *args):
            pass

        def _host_ok(self):
            # refuse requests that reached us under another name (DNS rebinding from a web page)
            if self.headers.get("Host", "") not in allowed_hosts:
                self.send_error(403)
                return False
            return True

        def _send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if not self._host_ok():
                return
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html", "/dashboard.html"):
                try:
                    with open(os.path.join(DATA, "dashboard.html"), "rb") as fh:
                        body = fh.read()
                except OSError:
                    body = b"<p>dashboard.html isn't built yet. Check server.log.</p>"
                self._send(200, body, "text/html; charset=utf-8")
            elif path == "/status":
                now = time.time()
                body = {"ok": True, "pid": os.getpid(), "started": app.started,
                        "uptime": round(now - app.started), "last_build": app.last_build}
                self._send(200, json.dumps(body).encode(), "application/json")
            elif path == "/live.json":
                snap, _ = app.snapshot()
                self._send(200, json.dumps(snap).encode(), "application/json")
            elif path == "/events":
                self.events()
            elif path.startswith("/map/") and path.endswith(".jpg"):
                stem = path[len("/map/"):-len(".jpg")]
                img = app.map_image(int(stem)) if stem.isdigit() else None
                if not img:
                    self.send_error(404)
                    return
                with open(img, "rb") as fh:
                    body = fh.read()
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "max-age=86400")
                self.end_headers()
                self.wfile.write(body)
            elif path == "/favicon.ico":
                self.send_response(204)
                self.end_headers()
            elif path.startswith("/shots/"):
                name = os.path.basename(path[len("/shots/"):].replace("%20", " "))
                full = os.path.join(app.wow, "Screenshots", name)
                if not SHOT_RE.match(name) or not os.path.isfile(full):
                    self.send_error(404)
                    return
                with open(full, "rb") as fh:
                    body = fh.read()
                self._send(200, body, SHOT_TYPES[name.rsplit(".", 1)[1].lower()])
            else:
                self.send_error(404)

        def do_POST(self):
            if not self._host_ok():
                return
            # a custom header can't be sent cross-site without a CORS preflight, which we never approve
            if self.path == "/stop" and self.headers.get("X-Ledger") == "stop":
                self._send(200, b"stopping", "text/plain")
                app.stop.set()
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self.send_error(403)

        def events(self):
            q = app.hub.add()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                snap, _ = app.snapshot()
                self.wfile.write(("event: live\ndata: %s\n\n" % json.dumps(snap, separators=(",", ":"))).encode())
                self.wfile.flush()
                while not app.stop.is_set():
                    try:
                        msg = q.get(timeout=15)
                    except queue.Empty:
                        msg = ": ping\n\n"
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                pass
            finally:
                app.hub.remove(q)

    return Handler


def main():
    ledgerlog.get("server", DATA)
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--wow", default=os.environ.get("LEDGER_WOW") or CONFIG.get("wow"),
                    help="the _forever_ folder (default: wow = ... in ledger.cfg)")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--no-open", action="store_true", help="don't open the browser")
    args = ap.parse_args()
    if not args.wow:
        ap.error("say where WoW is: set wow = your _forever_ folder in ledger.cfg (repo root), or pass --wow")
    url = "http://127.0.0.1:%d/" % args.port

    app = App(os.path.abspath(args.wow), args.port)
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(app))
    except OSError:
        log("port %d is busy: the server is probably running already; opening the page" % args.port)
        if not args.no_open:
            webbrowser.open(url)
        return
    httpd.daemon_threads = True
    for fn in (app.watch_sv, app.watch_log, app.pusher):
        threading.Thread(target=fn, daemon=True).start()
    log("started (port %d, wow %s, pid %d)" % (args.port, app.wow, os.getpid()))
    if not args.no_open:
        threading.Timer(1.5, webbrowser.open, args=(url,)).start()
    reason = "stop endpoint"
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        reason = "keyboard"
    except Exception as e:
        reason = str(e) or type(e).__name__
        _LOG.exception("server crashed")
    app.stop.set()
    log("stopped (%s)" % reason)


if __name__ == "__main__":
    main()
