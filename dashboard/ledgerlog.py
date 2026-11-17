"""Shared logging for the dashboard: one dated, levelled, rotating file per component (server.log, fetcher.log)."""
import logging
import logging.handlers
import os
import sys

FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"
DATEFMT = "%Y-%m-%d %H:%M:%S"


def get(component, data_dir):
    log = logging.getLogger(component)
    if log.handlers:   # already set up in this process
        return log
    log.setLevel(logging.INFO)
    log.propagate = False
    fmt = logging.Formatter(FORMAT, DATEFMT)
    fh = logging.handlers.RotatingFileHandler(os.path.join(data_dir, component + ".log"), maxBytes=1_000_000,
                                              backupCount=3, encoding="utf-8")
    fh.setFormatter(fmt)
    log.addHandler(fh)
    if sys.stdout is not None:   # pythonw has no stdout
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(fmt)
        log.addHandler(sh)
    return log
