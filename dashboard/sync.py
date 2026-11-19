"""Sync between PCs through a Backblaze B2 bucket: WTF zips both ways, the market master's db one way.

File work only touches the data folder (never the game's WTF, which WoW overwrites at logout). Temporary files go in
<data>/sync_tmp, on the same volume as pcs/ (so the swaps are renames) and outside it (so a build never sees a
half-extracted copy). Standard library only; never imports server."""
import glob
import os
import re
import shutil
import zipfile

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
    import pathlib
    import sqlite3
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
    import market_store
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
    import sqlite3
    import market_store
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
