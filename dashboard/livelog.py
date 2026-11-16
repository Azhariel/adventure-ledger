"""Reads WoW's combat log (Logs/WoWCombatLog-*.txt) into a live picture of the play session.

Pure: no files, no threads. Feed lines with LiveState.feed(line); read LiveState.snapshot(now).
Format notes (verified on WoW Forever, COMBAT_LOG_VERSION 22, 8 Nov 2026):
  "11/8/2026 21:40:51.486-3  EVENT,field,field,..."   (local time with its UTC offset in hours, two spaces)
  base fields: srcGUID, srcName, srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags
  prefix: SPELL_/RANGE_/SPELL_PERIODIC_/SPELL_BUILDING_ add spellId, spellName, school; SWING_ adds none;
          ENVIRONMENTAL_ puts its type after the advanced block
  advanced block (19 fields, on damage/heal/energize/cast success): infoGUID, ownerGUID, hp, maxHp, attackPower,
          spellPower, armor, absorb, ?, ?, powerType, power, maxPower, powerCost, posX, posY, uiMapID, facing, level
          (level = the character's ITEM level for players: 10 for a level-19 character; the real level for NPCs)
          (describes infoGUID: the source for most events, the target for SWING_DAMAGE_LANDED)
  damage suffix: amount, baseAmount, overkill (-1 = none), school, resisted, blocked, absorbed, critical, ...
  heal suffix:   amount, baseAmount, overhealing, absorbed, critical
  MAP_CHANGE: uiMapID, name, x0, x1, y0, y1  ->  map x = (y0 - posY) / (y0 - y1), map y = (x0 - posX) / (x0 - x1)
          (checked against MuddyBoots' trail: same point to the 4th decimal)
"""
import csv
import re
from collections import Counter, deque
from datetime import datetime, timedelta, timezone

MINE, PARTY, RAID = 0x1, 0x2, 0x4
HOSTILE = 0x40
TYPE_PLAYER, TYPE_PET, TYPE_GUARDIAN = 0x400, 0x1000, 0x2000

ADVANCED_SUFFIXES = ("_DAMAGE", "_DAMAGE_LANDED", "_HEAL", "_ENERGIZE", "_CAST_SUCCESS", "_DRAIN", "_LEECH")
FIGHT_GAP = 6.0          # seconds without damage to or from you that end a fight
OTHERS_TTL = 120.0       # players not seen for this long drop off "around you"
HOSTILE_RENOTIFY = 300.0
SNAPSHOT_VERSION = 2     # the page checks it: 2 = trail as (t, x, y) triples, players with "near"
NEAR_SECONDS = 20.0      # a player's own logged position stays good this long before "near you" replaces it

_TS = re.compile(r"^(\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+(?:\.\d+)?)([+-]\d+(?:[.:]\d+)?)?$")


def parse_time(stamp):
    """'11/8/2026 21:40:51.486-3' -> epoch seconds (None when unreadable)."""
    m = _TS.match(stamp.strip())
    if not m:
        return None
    mo, d, y, h, mi, s, off = m.groups()
    hours = 0.0
    if off:
        if ":" in off:
            a, b = off[1:].split(":")
            hours = int(a) + int(b) / 60
            hours = -hours if off[0] == "-" else hours
        else:
            hours = float(off)
    tz = timezone(timedelta(hours=hours))
    sec = float(s)
    whole = int(sec)
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), whole, tzinfo=tz)
    return dt.timestamp() + (sec - whole)


def flags(v):
    try:
        return int(v, 16)
    except (TypeError, ValueError):
        return 0


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def short_name(full):
    """'Azhariel-Deadheart-PvP-US' -> 'Azhariel Deadheart' (Forever names: First-Surname-Ruleset-Region)."""
    if not full or full == "nil":
        return "?"
    parts = full.split("-")
    if len(parts) >= 4:
        parts = parts[:-2]
    return " ".join(parts)


def prefix_len(event):
    if event.startswith(("SPELL_", "RANGE_", "DAMAGE_SHIELD", "DAMAGE_SPLIT")):
        return 3
    return 0  # SWING_, ENVIRONMENTAL_, UNIT_*, PARTY_KILL


def npc_id(guid):
    """'Creature-0-7062-0-77206-1797-00007115CE' -> 1797 (None for players and others)."""
    if guid and guid.startswith(("Creature-", "Vehicle-")):
        parts = guid.split("-")
        if len(parts) >= 6 and parts[5].isdigit():
            return int(parts[5])
    return None


def is_guid(v):
    return bool(v) and (v.startswith(("Player-", "Creature-", "Pet-", "Vehicle-", "GameObject-")) or v == "0000000000000000")


class LiveState:
    def __init__(self, file_name=None):
        self.file = file_name
        self.version = 0
        self.first_line = None
        self.last_line = None
        self.me = None              # dict once your GUID is known
        self.zone = None
        self.maps = {}              # uiMapID -> {name, x0, x1, y0, y1}
        self.current_map = None
        self.trail = deque(maxlen=900)   # (t, map, x, y)
        self.notes = deque(maxlen=60)
        self.fights = deque(maxlen=20)
        self.fight = None
        self.deaths = []
        self.others = {}            # guid -> {name, level, hp, maxHp, map, x, y, t, hostile}
        self.hostile_seen = {}      # guid -> last notified time
        self.recent_hits = deque(maxlen=8)   # damage taken: (t, source, spell, amount)
        self._reset_session()

    def _reset_session(self):
        self.session = {
            "start": None, "dmgDone": 0, "dmgTaken": 0, "healDone": 0, "overheal": 0,
            "kills": 0, "deaths": 0, "crits": 0, "hits": 0,
        }
        self.kills = Counter()
        self.npc_of = {}            # creature name -> npc id (for Wowhead links)
        self.kill_log = deque(maxlen=3000)   # (t, npc id, name): the Live tab's XP estimate
        self.spells = Counter()
        self.heals = Counter()

    # ------------------------------------------------------------------ helpers
    def _note(self, t, kind, text):
        self.notes.append({"t": t, "kind": kind, "text": text})

    def _is_me(self, guid):
        return self.me is not None and guid == self.me["guid"]

    def _mine(self, guid, fl):
        """You, or your pet / guardian."""
        if self._is_me(guid):
            return True
        return bool(fl & MINE) and bool(fl & (TYPE_PET | TYPE_GUARDIAN))

    def _learn_me(self, guid, name, fl):
        if fl & MINE and fl & TYPE_PLAYER and guid.startswith("Player-"):
            if self.me is None or self.me["guid"] != guid:
                switched = self.me is not None
                self.me = {"guid": guid, "name": short_name(name), "fullName": name}
                self.trail.clear()
                self.fight = None
                if switched:
                    self._reset_session()
                    self._note(self.last_line, "info", "Now playing " + self.me["name"])

    def _map_xy(self, map_id, px, py):
        b = self.maps.get(map_id)
        if not b:
            return None, None
        dx, dy = b["y0"] - b["y1"], b["x0"] - b["x1"]
        if dx == 0 or dy == 0:
            return None, None
        return (b["y0"] - py) / dx, (b["x0"] - px) / dy

    # ------------------------------------------------------------------ advanced block
    def _advanced(self, t, f, p, unit_name, unit_flags):
        guid = f[p]
        if not guid.startswith("Player-"):
            return
        ilvl = int(num(f[p + 18]))  # item level for players
        map_id = int(num(f[p + 16]))
        px, py = num(f[p + 14]), num(f[p + 15])
        x, y = self._map_xy(map_id, px, py)
        if self._is_me(guid):
            me = self.me
            me.update({
                "hp": int(num(f[p + 2])), "maxHp": int(num(f[p + 3])),
                "powerType": int(num(f[p + 10])), "power": int(num(f[p + 11])), "maxPower": int(num(f[p + 12])),
                "map": map_id, "x": x, "y": y, "facing": num(f[p + 17]), "itemLevel": ilvl, "at": t,
            })
            if self.fight is not None and me["maxHp"]:
                pct = me["hp"] / me["maxHp"]
                self.fight["minHp"] = min(self.fight["minHp"], pct)
            if x is not None:
                last = self.trail[-1] if self.trail else None
                if last is None or last[1] != map_id or abs(last[2] - x) + abs(last[3] - y) > 0.0015 or t - last[0] > 20:
                    self.trail.append((t, map_id, round(x, 4), round(y, 4)))
            return
        o = self.others.get(guid)
        if o is None:
            o = self.others[guid] = {"name": short_name(unit_name), "hostile": False}
        hostile = bool(unit_flags & HOSTILE)
        o.update({"itemLevel": ilvl, "hp": int(num(f[p + 2])), "maxHp": int(num(f[p + 3])),
                  "map": map_id, "x": x, "y": y, "t": t, "near": False})
        if hostile:
            o["hostile"] = True
            last = self.hostile_seen.get(guid)
            if last is None or t - last > HOSTILE_RENOTIFY:
                self._note(t, "hostile", "Enemy player nearby: %s (item level %d)" % (o["name"], ilvl))
            self.hostile_seen[guid] = t

    def _near(self, t, src, src_name, src_fl, dst, dst_name, dst_fl):
        """A spell between you and another player (your buff on a passer-by, their heal on you): the log's position
        is yours, not theirs, but they're within spell range, so they're placed where you are (near) until a line
        of their own gives their position."""
        if self.me is None:
            return
        if self._is_me(src) and dst.startswith("Player-") and dst != src:
            guid, name, fl = dst, dst_name, dst_fl
        elif self._is_me(dst) and src.startswith("Player-") and src != dst:
            guid, name, fl = src, src_name, src_fl
        else:
            return
        me = self.me
        o = self.others.get(guid)
        if o is None:
            o = self.others[guid] = {"name": short_name(name), "hostile": False}
        if fl & HOSTILE:
            o["hostile"] = True
        own = o.get("x") is not None and not o.get("near") and t - o.get("t", 0) <= NEAR_SECONDS
        if not own:
            o.update({"map": me.get("map"), "x": me.get("x"), "y": me.get("y"), "near": True})
        o["t"] = t

    # ------------------------------------------------------------------ fights
    def _touch_fight(self, t):
        if self.fight is not None and t - self.fight["last"] > FIGHT_GAP:
            self._close_fight()
        if self.fight is None:
            hp = self.me.get("hp") if self.me else None
            mx = self.me.get("maxHp") if self.me else None
            self.fight = {"start": t, "last": t, "dmgDone": 0, "dmgTaken": 0, "healDone": 0,
                          "targets": Counter(), "kills": [], "minHp": (hp / mx) if hp and mx else 1.0, "died": False}
        self.fight["last"] = t
        return self.fight

    def _close_fight(self):
        f = self.fight
        self.fight = None
        if f is None or (f["dmgDone"] == 0 and f["dmgTaken"] == 0):
            return
        rec = self._fight_view(f)
        self.fights.append(rec)
        foe = rec["target"] or "something"
        self._note(f["last"], "fight", "Fought %s: %d damage in %ds (%d dps), took %d" % (
            foe, f["dmgDone"], rec["seconds"], rec["dps"], f["dmgTaken"]))

    def _fight_view(self, f):
        secs = max(1.0, f["last"] - f["start"])
        target = f["targets"].most_common(1)[0][0] if f["targets"] else None
        extra = len(f["targets"]) - 1
        return {
            "start": f["start"], "end": f["last"], "seconds": round(secs), "dmgDone": f["dmgDone"],
            "dmgTaken": f["dmgTaken"], "healDone": f["healDone"], "dps": round(f["dmgDone"] / secs),
            "target": (target + (" +%d" % extra if extra > 0 else "")) if target else None,
            "targetNpc": self.npc_of.get(target) if target else None,
            "kills": list(f["kills"]), "minHp": round(f["minHp"], 3), "died": f["died"],
        }

    # ------------------------------------------------------------------ lines
    def feed(self, line):
        line = line.rstrip("\r\n")
        if "  " not in line:
            return
        stamp, rest = line.split("  ", 1)
        t = parse_time(stamp)
        if t is None:
            return
        try:
            f = next(csv.reader([rest]))
        except (csv.Error, StopIteration):
            return
        if not f:
            return
        self.version += 1
        if self.first_line is None:
            self.first_line = t
        self.last_line = t
        ev = f[0]

        if ev == "MAP_CHANGE" and len(f) >= 7:
            mid = int(num(f[1]))
            self.maps[mid] = {"name": f[2], "x0": num(f[3]), "x1": num(f[4]), "y0": num(f[5]), "y1": num(f[6])}
            self.current_map = mid
            return
        if ev == "ZONE_CHANGE" and len(f) >= 3:
            if f[2] != self.zone:
                self.zone = f[2]
                self._note(t, "zone", "Entered " + f[2])
            return
        if ev in ("COMBAT_LOG_VERSION", "COMBATANT_INFO", "ENCOUNTER_START", "ENCOUNTER_END") or len(f) < 9:
            return

        src, src_name, src_fl = f[1], f[2], flags(f[3])
        dst, dst_name, dst_fl = f[5], f[6], flags(f[7])
        self._learn_me(src, src_name, src_fl)
        self._learn_me(dst, dst_name, dst_fl)
        if self.me is None:
            return
        if self.session["start"] is None:
            self.session["start"] = t

        # advanced block
        p = 9 + prefix_len(ev)
        adv = False
        if ev.endswith(ADVANCED_SUFFIXES) and len(f) >= p + 19 and is_guid(f[p]):
            adv = True
            info = f[p]
            if info == src:
                self._advanced(t, f, p, src_name, src_fl)
            elif info == dst:
                self._advanced(t, f, p, dst_name, dst_fl)
        s = p + 19 if adv else p
        if ev.startswith("ENVIRONMENTAL_"):
            s += 1  # environmental type
        self._near(t, src, src_name, src_fl, dst, dst_name, dst_fl)

        src_mine = self._mine(src, src_fl)
        dst_me = self._is_me(dst)

        if ev in ("SWING_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "RANGE_DAMAGE", "ENVIRONMENTAL_DAMAGE",
                  "DAMAGE_SHIELD"):
            if len(f) <= s:
                return
            amount = int(num(f[s]))
            crit = len(f) > s + 7 and f[s + 7] == "1"
            if ev.startswith("SWING"):
                spell = "Melee"
            elif ev.startswith("ENVIRONMENTAL_"):
                spell = f[s - 1].title()
            else:
                spell = f[10]
            if src_mine and not dst_me:
                fight = self._touch_fight(t)
                fight["dmgDone"] += amount
                fight["targets"][short_name(dst_name)] += amount
                npc = npc_id(dst)
                if npc:
                    self.npc_of[dst_name] = npc
                self.session["dmgDone"] += amount
                self.session["hits"] += 1
                if crit:
                    self.session["crits"] += 1
                self.spells[spell] += amount
            elif dst_me:
                fight = self._touch_fight(t)
                fight["dmgTaken"] += amount
                self.session["dmgTaken"] += amount
                who = "Falling" if ev.startswith("ENVIRONMENTAL_") and spell == "Falling" else short_name(src_name)
                self.recent_hits.append((t, who if src_name != "nil" else spell, spell, amount))
            return

        if ev in ("SPELL_HEAL", "SPELL_PERIODIC_HEAL") and src_mine and len(f) > s + 2:
            amount, over = int(num(f[s])), int(num(f[s + 2]))
            eff = max(0, amount - over)
            self.session["healDone"] += eff
            self.session["overheal"] += over
            self.heals[f[10]] += eff
            if self.fight is not None:
                self.fight["healDone"] += eff
            return

        if ev == "PARTY_KILL" and (src_mine or src_fl & (PARTY | RAID)):
            name = short_name(dst_name) if dst.startswith("Player-") else dst_name
            npc = npc_id(dst)
            if npc:
                self.npc_of[name] = npc
            self.session["kills"] += 1
            self.kills[name] += 1
            if src_mine:
                self.kill_log.append((t, npc, name))
            if self.fight is not None:
                self.fight["kills"].append(name)
            self._note(t, "kill", ("Killed " if src_mine else "Group killed ") + name)
            return

        if ev == "UNIT_DIED" and dst_me:
            self.session["deaths"] += 1
            killer = self.recent_hits[-1] if self.recent_hits and t - self.recent_hits[-1][0] < 10 else None
            me = self.me
            death = {"t": t, "map": me.get("map"), "x": me.get("x"), "y": me.get("y"),
                     "killer": killer[1] if killer else None, "spell": killer[2] if killer else None}
            self.deaths.append(death)
            if self.fight is not None:
                self.fight["died"] = True
                self._close_fight()
            self._note(t, "death", "Died" + ((" to " + death["killer"]) if death["killer"] else ""))
            return

    # ------------------------------------------------------------------ output
    def tick(self, now):
        """Close a fight that went quiet (the log only says when things happen, never when they stop)."""
        if self.fight is not None and now - self.fight["last"] > FIGHT_GAP:
            self._close_fight()
            self.version += 1
        for guid in [g for g, o in self.others.items() if now - o.get("t", 0) > OTHERS_TTL]:
            del self.others[guid]

    def snapshot(self, now):
        me = dict(self.me) if self.me else None
        cur_map = me.get("map") if me else self.current_map
        if me is not None:
            me["zone"] = self.zone
            me["mapName"] = self.maps.get(cur_map, {}).get("name")
        # flat (t, x, y) triples on the current map: the page joins them onto Logbook's saved trail by time
        trail = []
        for t, m, x, y in self.trail:
            if m == cur_map:
                trail.extend((round(t, 1), x, y))
        players = []
        for o in self.others.values():
            if now - o.get("t", 0) <= OTHERS_TTL:
                players.append({
                    "name": o["name"], "itemLevel": o.get("itemLevel"), "hostile": o.get("hostile", False),
                    "map": o.get("map"), "x": o.get("x"), "y": o.get("y"),
                    "hp": round(o["hp"] / o["maxHp"], 3) if o.get("maxHp") else None, "ago": round(now - o["t"]),
                    "near": o.get("near", False),
                })
        players.sort(key=lambda o: (not o["hostile"], o["ago"]))
        sess = dict(self.session)
        sess["topKills"] = [(n, k, self.npc_of.get(n)) for n, k in self.kills.most_common(12)]
        sess["spells"] = self.spells.most_common(10)
        sess["heals"] = self.heals.most_common(8)
        return {
            "v": SNAPSHOT_VERSION,
            "file": self.file, "firstLine": self.first_line, "lastLine": self.last_line, "now": now,
            "me": me, "session": sess,
            "fight": self._fight_view(self.fight) if self.fight else None,
            "fights": list(reversed(self.fights)),
            "feed": sorted(self.notes, key=lambda n: -(n["t"] or 0)),
            "trail": trail,
            "killLog": [list(k) for k in self.kill_log],
            "deaths": [d for d in self.deaths if d["map"] == cur_map],
            "players": players[:40],
            "maps": {str(k): v["name"] for k, v in self.maps.items()},
        }
