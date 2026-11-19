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
