# Logbook

Records your journey for the Adventure Ledger: XP and levels, gold by source, kills, quests, deaths, zones,
dungeon runs, professions, play sessions, how you spend your time, where you've walked, your damage from the
game's damage meter, and your flights. The dashboard's character modules (Overview, Progress, Gold, Combat &
quests, Play sessions, Your trades, the Live tab's XP estimate and trail) read it.

It replaces what the dashboard used to take from MuddyBoots. MuddyBoots is optional now:

- At Logbook's **first login** on a character, if MuddyBoots is loaded, Logbook copies its lifetime counters (XP
  by source and level, time by activity, fights, deaths, distance, crafts) into `LogbookCharDB.baseline`, once.
- The dashboard keeps MuddyBoots' log, sessions and trail from **before** Logbook's first login and uses Logbook's
  from then on. Counters are the baseline plus Logbook's own. Nothing is counted twice, even with both enabled.
- After that first login you can disable MuddyBoots. Leave its saved file in `WTF` if you want your older
  history to stay on the page.

Nothing to set up. `/logbook` says how much it has recorded, and whether the damage meter is available.

## What it records, and how

Forever runs the retail (Mainline) addon API, forbids the combat log, and hides some values ("secret"). Every call
is guarded, so a hidden value leaves a field empty rather than breaking anything.

| Line | Kind | From |
| --- | --- | --- |
| `in`, `out` | login or reload, logout | `PLAYER_ENTERING_WORLD`, `PLAYER_LOGOUT` |
| `zo` | zone change | `ZONE_CHANGED_NEW_AREA` |
| `ie`, `il` | dungeon entered (name, type, difficulty), left (seconds inside) | `IsInInstance`, `GetInstanceInfo` |
| `xp` | XP gained: amount, source (kill, quest, discover, dungeon, other), what | `PLAYER_XP_UPDATE` deltas, explained by the kill / discovery chat line or `QUEST_TURNED_IN` |
| `lv`, `ge` | level reached; gear worn at the ding | `PLAYER_LEVEL_UP`, `GetInventoryItemID` |
| `ki` | kill: name, npc, type, classification, XP, level | "X dies, you gain N experience"; the npc from your target, mouse-over or nameplates |
| `mn` | gold change: delta, source, what | `PLAYER_MONEY`, explained by hooks (repair, flight, vendor sale or buy, mail, AH, respec, postage), the loot line, a quest reward, or the open window. A vendor sale is matched by the item's exact sell price, so a fast run of sales keeps each name |
| `ah` | auction post (deposit), buyout, sale, expiry | AH post / purchase hooks, mail invoices, the expiry system line |
| `ma` | mail: AH sale invoice (buyer, copper, item), AH purchase invoice (seller, item), item taken, item sent | `TakeInboxMoney`, `AutoLootMailItem`, `TakeInboxItem`, `SendMail` hooks. A sale is logged once, when its gold arrives: the mailbox's open-all calls `TakeInboxMoney` again and again until then |
| `qa`, `qt`, `qx` | quest accepted (id, title, level), turned in (id, XP, copper, title), abandoned | `QUEST_ACCEPTED`, `QUEST_TURNED_IN`, `QUEST_REMOVED` right after you confirm Abandon (a failed or removed quest isn't an abandon) |
| `de` | death: likely killer, npc, environment, place, killer level and class, by a player | `PLAYER_DEAD`, your last hostile target in that fight, breath / fatigue timers |
| `fi` | fight from the damage meter: seconds, damage, taken, healed, enemies hit, who hurt you most (and how much), killing blow (attacker, spell) | `C_DamageMeter`, each finished session read once after `PLAYER_REGEN_ENABLED` |
| `sk` | skill rank: name, rank, max | `GetProfessions`, `CHAT_MSG_SKILL` (weapon skills) |
| `lo` | item received: id, quality, how (loot, made, roll, mail, bought, quest, trade, other), name, count | `CHAT_MSG_LOOT` and which window was open |
| `ga` | gathered: profession, item, count, with where you stood | the gathering spellcast, then the loot window |
| `fl` | flight: from, to, fare, seconds in the air, stops on the way | `TakeTaxiNode` (`TaxiNodeCost`, the `CURRENT` node, `GetNumRoutes` / `TaxiGetNodeSlot` for the stops), then `UnitOnTaxi` on `PLAYER_CONTROL_LOST` / `_GAINED` |

Every line starts with `time|played|uiMapID|x|y` (x, y in ten-thousandths of the map). Counters (`counts.*`) hold
totals and per-level totals (`kill:24`): XP by source and rested bonus, time per activity (combat, travel, dungeon,
town, idle, afk, dead; sampled every 5 seconds), distance by mode (foot, mount, swim, fly, ghost, hearth), fights
(count, seconds, longest, died), low-health moments and close calls, damage done / taken / healed and meter seconds
per level with best DPS and biggest fight (`damage`), damage per spell (`damageBy`) and per attacker (`damageFrom`),
crafts / catches / gathers per item, AH activity, flights (count, fares, seconds, longest), quests accepted / done /
abandoned, casts per spell, dungeon entries and time inside, repairs, respecs.
`snap[level]` keeps your gold, played time, zone and gear when you reached each level. `trail` keeps a point
whenever you've moved, per map.

Known limits:

- In dungeons the chat lines are secret, so a kill there has no name. Its XP still counts as dungeon XP.
- Kills that give no XP (grey mobs, level 60) aren't counted: the XP line is the only kill signal without the combat log.
- The `de` line's killer is your last hostile target during that fight. The damage meter's killing blow comes a
  second later in the `fi` line, and the dashboard uses it when there is one.
- The damage meter's numbers are secret in combat. A fight is read once you're out of combat; if you pull again
  within a second, it's read after the next one. Your pet's damage counts as yours.
- A logout to the character list can report level 1 and no gold. Logbook keeps the highest level it knows (the
  client's, the saved one, the levels reached) and saves the gold it tracked from `PLAYER_MONEY`.
- The game sometimes skips `PLAYER_LOGOUT` on a `/reload` (MuddyBoots misses it too), so there's no `out` line.
  Nothing is lost: the session is updated every 5 seconds and the saved file is still written.
- Flying along a zone border logs a `zo` line at every crossing.

## Next to record

From the Forever API docs (warcraft.wiki.gg, build 1.60.1), ranked by what they would add to the dashboard:

1. **Death recap** (`C_DeathRecap.GetRecapEvents`, the meter's `deathRecapID`) and durability before and after a
   death: what a death costs.
2. **Gear and item level over time** (`PLAYER_EQUIPMENT_CHANGED`, `C_Item.GetCurrentItemLevel`).
3. **Reputation** (`UPDATE_FACTION`, `C_Reputation.GetFactionDataByIndex`): standing over time, time left to the next standing.
4. **Durability and repair cost** (`UPDATE_INVENTORY_DURABILITY`, `GetInventoryItemDurability`).
5. **Rested pool** (`GetXPExhaustion`, `PLAYER_UPDATE_RESTING`).
6. **Group composition** (`GROUP_ROSTER_UPDATE`): XP per hour solo against grouped.
7. **Stats at each level** (`UnitStat`, `UnitArmor`, `GetCritChance`, outside combat).
8. **Talents and respecs** (`CHARACTER_POINTS_CHANGED`, `CONFIRM_TALENT_WIPE`).
9. **Bag space** (`C_Container.GetContainerNumFreeSlots`).

Checked in game (Nov 2026): the damage meter keeps one session per fight and Logbook reads them all; it leaves
`creatureName` empty and names the attacker in `combatSpellDetails.unitName`. Still untested on Forever: which
fields the death recap returns; how talent queries address the three-tree layout.

## Files

| File | Role |
| --- | --- |
| `Journal.lua` | Pure: saved-data shape, log lines, counters, sessions, trail, XP and money attribution, damage meter readings, chat-line parsers |
| `Core.lua` | Events, hooks, the damage meter and flight readers, the 5-second tick, `/logbook` |

Saved data: `LogbookCharDB` (per character; `flying` holds a flight in progress across a `/reload`), `LogbookDB`
(account: level, gold, played and last seen per character).

## Tests

`lua tests/run.lua` from this folder: the pure parts, and every event above against a stubbed client (secret
values, missing functions, the retail and Classic quest and profession APIs).
