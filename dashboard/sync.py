"""Sync between PCs through a Backblaze B2 bucket: WTF zips both ways, the market master's db one way.

File work only touches the data folder (never the game's WTF, which WoW overwrites at logout). Temporary files go in
<data>/sync_tmp, on the same volume as pcs/ (so the swaps are renames) and outside it (so a build never sees a
half-extracted copy). Standard library only; never imports server."""
import glob
import json
import logging
import os
import pathlib
import re
import shutil
import sqlite3
import threading
import time
import zipfile

import b2
import market_store

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,39}$")
SKIP_SUFFIXES = (".bak", ".old")


def pc_name(cfg, hostname):
    """This PC's name in the bucket and under other PCs' data/pcs: pc_name in ledger.cfg, else the hostname."""
    name = (cfg.get("pc_name") or hostname or "").strip().lower().replace(" ", "-")
    if not NAME_RE.match(name):
        raise ValueError("pc_name %r in ledger.cfg: use letters, digits, '.', '-' or '_' (up to 40)" % name)
    return name


def tmp_dir(data):
    path = os.path.join(data, "sync_tmp")
    os.makedirs(path, exist_ok=True)
    return path


def _rmtree(path):
    if os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)


def newest_save(wow):
    """Newest SavedVariables write under <wow>/WTF (the same files the live server watches), or None."""
    newest = None
    for pat in (("Account", "*", "SavedVariables", "*.lua"), ("Account", "*", "*", "*", "SavedVariables", "*.lua")):
        for path in glob.glob(os.path.join(wow, "WTF", *pat)):
            try:
                t = os.stat(path).st_mtime
            except OSError:
                continue
            if newest is None or t > newest:
                newest = t
    return newest


def zip_wtf(wow, dest):
    """Zip <wow>/WTF (paths relative to WTF, backups skipped) into dest; returns its size in bytes."""
    root = os.path.join(wow, "WTF")
    if not os.path.isdir(root):
        raise FileNotFoundError("no WTF folder in %s" % wow)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, dirs, files in os.walk(root):
            dirs.sort()
            for f in sorted(files):
                if f.lower().endswith(SKIP_SUFFIXES):
                    continue
                full = os.path.join(folder, f)
                z.write(full, os.path.relpath(full, root).replace(os.sep, "/"))
    return os.path.getsize(dest)


def _safe_members(z):
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        parts = name.split("/")
        if name.startswith("/") or re.match(r"^[A-Za-z]:", name) or ".." in parts:
            raise ValueError("unsafe path in zip: %r" % info.filename)
    return z.infolist()


def install_wtf(zip_path, data, name):
    """Replace <data>/pcs/<name>/WTF with the zip's contents. Any failure before the swap leaves the old copy."""
    work = os.path.join(tmp_dir(data), name)
    _rmtree(work)
    new_wtf = os.path.join(work, "WTF")
    try:
        with zipfile.ZipFile(zip_path) as z:
            members = _safe_members(z)
            if not any(m.filename.replace("\\", "/").split("/")[0] == "Account" for m in members):
                raise ValueError("not a WTF folder (no Account folder in the zip)")
            z.extractall(new_wtf, members)
        pc = os.path.join(data, "pcs", name)
        os.makedirs(pc, exist_ok=True)
        target = os.path.join(pc, "WTF")
        old = os.path.join(tmp_dir(data), "old-" + name)
        _rmtree(old)
        if os.path.isdir(target):
            os.rename(target, old)
        try:
            os.rename(new_wtf, target)
        except OSError:
            if os.path.isdir(old) and not os.path.exists(target):
                os.rename(old, target)   # put the previous copy back
            raise
        _rmtree(old)
    finally:
        _rmtree(work)


# ---------------------------------------------------------------- the market bundle (master -> others)
BUNDLE_LOGS = ("networth_log.tsv", "price_log.tsv", "price_log_neutral.tsv", "neutral_days.txt")


def _ro(path):
    return sqlite3.connect(pathlib.Path(path).resolve().as_uri() + "?mode=ro", uri=True)


def _latest(db):
    try:
        got = db.execute("SELECT MAX(t) FROM snapshot").fetchone()
    except Exception:   # noqa: BLE001  (no snapshot table)
        return None
    return got[0] if got else None


def local_latest(data):
    """Newest snapshot time in <data>/market.db, or None without one."""
    path = os.path.join(data, "market.db")
    if not os.path.isfile(path):
        return None
    db = _ro(path)
    try:
        return _latest(db)
    finally:
        db.close()


def export_market(data, dest):
    """Zip a consistent, compact copy of <data>/market.db plus the master's logs. Returns latest, store, size."""
    path = os.path.join(data, "market.db")
    if not os.path.isfile(path):
        raise FileNotFoundError("no market.db on this PC yet")
    copy = os.path.join(tmp_dir(data), "export.db")
    if os.path.exists(copy):
        os.remove(copy)
    try:
        db = _ro(path)
        try:
            db.execute("VACUUM INTO ?", (copy,))   # consistent while the fetcher writes; folds the WAL in
        finally:
            db.close()
        db = _ro(copy)
        try:
            latest, store = _latest(db) or 0, market_store.store_version(db)
        finally:
            db.close()
        with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
            z.write(copy, "market.db")
            for name in BUNDLE_LOGS:
                if os.path.isfile(os.path.join(data, name)):
                    z.write(os.path.join(data, name), name)
    finally:
        if os.path.exists(copy):
            os.remove(copy)
    return {"latest": latest, "store": store, "size": os.path.getsize(dest)}


def import_market(zip_path, data):
    """Replace <data>/market.db's contents (and the logs) with the bundle's. Safe while the fetcher's connection and
    the server's readers are open: the backup API copies pages under SQLite's locking, and no file is renamed."""
    work = os.path.join(tmp_dir(data), "market")
    _rmtree(work)
    os.makedirs(work)
    try:
        with zipfile.ZipFile(zip_path) as z:
            names = [m.filename for m in _safe_members(z)]
            if "market.db" not in names:
                raise ValueError("the market copy is damaged (no market.db in it)")
            z.extractall(work, [n for n in names if n == "market.db" or n in BUNDLE_LOGS])
        copy = os.path.join(work, "market.db")
        try:
            src = sqlite3.connect(copy)
            try:
                ok = src.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
                version = market_store.store_version(src)
            finally:
                src.close()
        except sqlite3.DatabaseError:
            ok = False
        if not ok:
            raise ValueError("the market copy is damaged: upload it again from the master")
        if version > market_store.STORE_VERSION:
            raise ValueError("the market copy is newer than this code: git pull on this PC")
        if version < market_store.STORE_VERSION:
            market_store.Store(copy).close()   # run the migrations here, so the live fetcher never meets an old schema
        replaced = local_latest(data)
        src = sqlite3.connect(copy)
        dst = sqlite3.connect(os.path.join(data, "market.db"), timeout=300)
        try:
            src.backup(dst)
            dst.execute("PRAGMA journal_mode=WAL")
            latest = _latest(dst) or 0
        finally:
            dst.close()
            src.close()
        for name in BUNDLE_LOGS:
            if os.path.isfile(os.path.join(work, name)):
                os.replace(os.path.join(work, name), os.path.join(data, name))
        return {"latest": latest, "replaced_latest": replaced}
    finally:
        _rmtree(work)


# ---------------------------------------------------------------- jobs, state and what's due

STATE_FILE = "sync_state.json"
WTF_PREFIX = "wtf/"
MARKET_NAME = "market/market.zip"
DAILY_HOUR = 8          # the master uploads its market bundle once a day from 08:00 local time (the user's pick)
RETRY_EVERY = 3600      # a failed daily upload is retried at most hourly
LIST_TTL = 60           # seconds a bucket listing is reused for the page's status
_LOG = logging.getLogger("server")   # the live server's log (server.log); messages never carry a key
NOT_SET_UP = "Sync isn't set up: add b2_key_id, b2_key and b2_bucket to ledger.cfg, then restart the tray."


def clock(t, now):
    """'18:46' today, 'yesterday 18:46', else 'Mon 17 18:46'."""
    lt = time.localtime(t)
    hm = time.strftime("%H:%M", lt)
    if lt[:3] == time.localtime(now)[:3]:
        return hm
    if lt[:3] == time.localtime(now - 86400)[:3]:
        return "yesterday " + hm
    return time.strftime("%a %d ", lt) + hm


def mb(n):
    return "%.1f MB" % (n / 1048576.0)


def _uploaded_at(f):
    """The upload time a file carries in its info ('at'), else B2's own upload time."""
    try:
        return float(f["info"]["at"])
    except (KeyError, TypeError, ValueError):
        return float(f.get("uploaded") or 0)


def _and(parts):
    return parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " and " + parts[-1]


class Syncer:
    """One sync job at a time for this PC. `client` has b2.Client's list/upload/download (None: not set up)."""

    def __init__(self, data, wow, cfg, client, hostname, now=time.time):
        self.data, self.wow, self.client, self.now = data, wow, client, now
        self.error = None
        try:
            self.name = pc_name(cfg, hostname)
        except ValueError as e:
            self.name, self.error = None, str(e)
        self.master = str(cfg.get("market_master", "")).strip().lower() in ("yes", "true", "1")
        self.bucket_name = cfg.get("b2_bucket")
        self.configured = bool(self.name and client is not None
                               and all(cfg.get(k) for k in ("b2_key_id", "b2_key", "b2_bucket")))
        self.busy = None
        self._installed = False
        self._lock = threading.Lock()
        self._listing = None   # (time, files)

    # ---------------------------------------------------------------- state file
    def _state_path(self):
        return os.path.join(self.data, STATE_FILE)

    def load(self):
        try:
            with open(self._state_path(), encoding="utf-8") as fh:
                got = json.load(fh)
            return got if isinstance(got, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self, state):
        tmp = self._state_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=1, sort_keys=True)
        os.replace(tmp, self._state_path())

    def _files(self, fresh=False, quick=False):
        """The bucket's files. quick (the page's status): one try, and a failure is reused for LIST_TTL like a
        listing, so an unreachable bucket never makes the page wait. Raises the B2Error it got."""
        now, listing = self.now(), self._listing
        if fresh or listing is None or now - listing[0] > LIST_TTL:
            try:
                listing = (now, self.client.list("", retry=not quick), None)
            except b2.B2Error as e:
                listing = (now, None, e)
            self._listing = listing
        if listing[2] is not None:
            raise listing[2]
        return listing[1]

    # ---------------------------------------------------------------- jobs
    def run(self, kind, progress=None):
        """Run one job ('upload-wtf', 'upload-market', 'import'); returns {"ok", "at", "message", ...}.
        progress(phase, done, total) is called while it runs."""
        if not self._lock.acquire(blocking=False):
            return {"ok": False, "at": self.now(), "message": "Another sync job is running", "refused": True}
        try:
            self.busy = kind
            self._installed = False   # set by _import per WTF swapped in: a later failure still needs a rebuild
            self._market = False      # set by _import once the market db is replaced
            t0 = time.time()
            _LOG.info("sync %s: started (this PC: %s)", kind, self.name)
            state = self.load()
            extra = {}
            try:
                if not self.configured:
                    raise ValueError(self.error or NOT_SET_UP)
                job = {"upload-wtf": self._upload_wtf, "upload-market": self._upload_market,
                       "import": self._import}.get(kind)
                if job is None:
                    raise ValueError("unknown sync job %r" % kind)
                extra = job(state, progress or (lambda *a: None))
                last = {"ok": True, "message": extra.pop("message")}
            except b2.B2Error as e:
                last = {"ok": False, "message": self._b2_message(e)}
                _LOG.warning("sync %s: %r", kind, e)   # B2's error is scrubbed of the key and tokens
            except (ValueError, OSError, zipfile.BadZipFile, sqlite3.Error) as e:
                last = {"ok": False, "message": str(e) or type(e).__name__}
                _LOG.warning("sync %s: %s: %s", kind, type(e).__name__, e)
            except Exception:   # noqa: BLE001  (a malformed reply, a bug: report it, never kill the job thread)
                _LOG.exception("sync %s failed", kind)
                last = {"ok": False, "message": "Sync failed: see server.log"}
            secs = time.time() - t0
            if last["ok"]:
                _LOG.info("sync %s: OK in %.1fs: %s", kind, secs, last["message"])
            else:
                _LOG.warning("sync %s: FAILED in %.1fs: %s", kind, secs, last["message"])
            last["kind"] = kind
            last["at"] = self.now()
            state["last"] = last
            try:
                self._save(state)
            except OSError:
                _LOG.exception("couldn't write %s", STATE_FILE)
            self._listing = None
            out = dict(last)
            out.update(extra)
            out["rebuild"] = self._installed
            out["market"] = self._market
            return out
        finally:
            self.busy = None
            _rmtree(os.path.join(self.data, "sync_tmp"))
            self._lock.release()

    @staticmethod
    def _b2_message(e):
        if e.status in (401, 403):
            return "Bucket refused the key: check b2_key_id / b2_key in ledger.cfg"
        if e.code == "network":
            return "Bucket unreachable: check the connection"
        return "Bucket: %s" % e

    def _upload_wtf(self, state, progress):
        progress("zipping", 0, 0)
        dest = os.path.join(tmp_dir(self.data), "wtf.zip")
        size = zip_wtf(self.wow, dest)
        _LOG.info("sync: zipped WTF (%s)", mb(size))
        now = self.now()
        self._upload(WTF_PREFIX + self.name + ".zip", dest, size, {"pc": self.name, "at": str(int(now))}, progress)
        state["wtf_upload"] = {"at": now, "size": size}
        return {"message": "Uploaded WTF (%s) at %s" % (mb(size), clock(now, now))}

    def _upload_market(self, state, progress):
        if not self.master:
            raise ValueError("Only the market master uploads the market db")
        now = self.now()
        state["market_try"] = now
        progress("copying", 0, 0)
        dest = os.path.join(tmp_dir(self.data), "market.zip")
        got = export_market(self.data, dest)
        _LOG.info("sync: copied the market db (%s, newest hour %s, store version %s)",
                  mb(got["size"]), clock(got["latest"], now), got["store"])
        self._upload(MARKET_NAME, dest, got["size"], {"pc": self.name, "at": str(int(now)),
                                                      "latest": str(got["latest"]), "store": str(got["store"])}, progress)
        state["market_upload"] = {"at": now, "size": got["size"], "latest": got["latest"],
                                  "day": time.strftime("%Y-%m-%d", time.localtime(now))}
        return {"message": "Uploaded the market db (%s, newest hour %s) at %s"
                           % (mb(got["size"]), clock(got["latest"], now), clock(now, now))}

    def _upload(self, name, path, size, info, progress):
        t0 = time.time()
        self.client.upload(name, path, info, progress=lambda s, t: progress("uploading", s, t))
        _LOG.info("sync: uploaded %s (%s) in %.1fs", name, mb(size), time.time() - t0)

    def _download(self, name, dest, size, phase, progress):
        t0 = time.time()
        self.client.download(name, dest, progress=lambda s, tot: progress(phase, s, tot))
        _LOG.info("sync: downloaded %s (%s) in %.1fs", name, mb(size), time.time() - t0)

    def _import(self, state, progress):
        files, now = self._files(fresh=True), self.now()
        for f in files:
            _LOG.info("sync: bucket has %s (%s, uploaded %s by %s)", f["name"], mb(f.get("size") or 0),
                      clock(_uploaded_at(f), now), (f.get("info") or {}).get("pc", "?"))
        imports = state.setdefault("imports", {})
        done, rebuild = [], False
        for f in files:
            n = f["name"]
            if not (n.startswith(WTF_PREFIX) and n.endswith(".zip")):
                continue
            pc = n[len(WTF_PREFIX):-len(".zip")].lower()
            t = _uploaded_at(f)
            if pc == self.name or not NAME_RE.match(pc) or t <= imports.get(pc, 0):
                continue
            phase = "importing " + pc
            progress(phase, 0, f.get("size") or 0)
            dest = os.path.join(tmp_dir(self.data), pc + ".zip")
            self._download(n, dest, f.get("size") or 0, phase, progress)
            try:
                install_wtf(dest, self.data, pc)
            except (ValueError, zipfile.BadZipFile) as e:
                raise ValueError("%s's upload is damaged (%s): upload it again from %s" % (pc, e, pc)) from None
            _LOG.info("sync: installed pcs/%s/WTF", pc)
            imports[pc], rebuild, self._installed = t, True, True
            done.append("%s's WTF (%s)" % (pc, clock(t, now)))
        market = next((f for f in files if f["name"] == MARKET_NAME), None)
        if market and not self.master:
            t, src = _uploaded_at(market), str((market.get("info") or {}).get("pc", "")).lower()
            if src != self.name and t > state.get("market_import", 0):
                progress("importing the market db", 0, market.get("size") or 0)
                dest = os.path.join(tmp_dir(self.data), "market.zip")
                self._download(MARKET_NAME, dest, market.get("size") or 0, "importing the market db", progress)
                got = import_market(dest, self.data)
                _LOG.info("sync: replaced the market db (newest hour %s, was %s)", clock(got["latest"], now),
                          clock(got["replaced_latest"], now) if got.get("replaced_latest") else "none")
                state["market_import"], self._market = t, True
                done.append("the market db (newest hour %s)" % clock(got["latest"], now))
        return {"message": "Imported " + _and(done) if done else "Already up to date", "rebuild": rebuild}

    # ---------------------------------------------------------------- what's due
    def daily_due(self):
        if not (self.master and self.configured):
            return False
        now = self.now()
        lt = time.localtime(now)
        if lt.tm_hour < DAILY_HOUR:
            return False
        state = self.load()
        if (state.get("market_upload") or {}).get("day") == time.strftime("%Y-%m-%d", lt):
            return False
        return now - state.get("market_try", 0) >= RETRY_EVERY

    def status(self, newest_save, last_play):
        """What the Sync page shows. Lists the bucket at most once a minute."""
        state = self.load()
        imports = state.get("imports") or {}
        pcs_dir = os.path.join(self.data, "pcs")
        pcs = []
        if os.path.isdir(pcs_dir):
            for d in sorted(os.listdir(pcs_dir)):
                if os.path.isdir(os.path.join(pcs_dir, d, "WTF")):
                    pcs.append({"name": d, "importedAt": imports.get(d.lower())})
        try:
            local = local_latest(self.data)
        except sqlite3.Error:
            local = None
        wtf_at = (state.get("wtf_upload") or {}).get("at")
        out = {"configured": self.configured, "name": self.name, "master": self.master,
               "bucketName": self.bucket_name, "error": self.error, "busy": self.busy, "last": state.get("last"),
               "newestSave": newest_save, "wtfUploadAt": wtf_at, "marketUpload": state.get("market_upload"),
               "marketImportAt": state.get("market_import"),
               "localLatest": local, "pcs": pcs, "bucket": [], "uploadDue": False, "importDue": False,
               "unsaved": bool(newest_save and last_play and last_play - newest_save > 60)}
        if not self.configured:
            return out
        out["uploadDue"] = newest_save is not None and newest_save > (wtf_at or 0)
        try:
            files = self._files(quick=True)
        except b2.B2Error as e:
            out["bucketError"] = self._b2_message(e)
            return out
        due = False
        for f in files:
            n, t = f["name"], _uploaded_at(f)
            if n.startswith(WTF_PREFIX) and n.endswith(".zip"):
                pc = n[len(WTF_PREFIX):-len(".zip")].lower()
                out["bucket"].append({"kind": "wtf", "pc": pc, "at": t, "size": f.get("size") or 0})
                due = due or (pc != self.name and t > imports.get(pc, 0))
            elif n == MARKET_NAME:
                info = f.get("info") or {}
                try:
                    latest = int(info.get("latest"))
                except (TypeError, ValueError):
                    latest = None
                pc = str(info.get("pc", "")).lower()
                out["bucket"].append({"kind": "market", "pc": pc, "at": t, "size": f.get("size") or 0,
                                      "latest": latest})
                due = due or (not self.master and pc != self.name and t > state.get("market_import", 0))
        out["importDue"] = due
        return out
