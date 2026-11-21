# DropLab

Drop rates from your own kills, with how sure each rate is, and what each kill is worth. Questie's drop rates come
from old databases; DropLab counts what actually drops for you on Forever.

Requires **Make or Buy** (for prices). Works with **WhereToFarm** if installed.

## Use

Kill and loot as usual. DropLab counts in the background. Nothing to set up.

- **Mob tooltip**: hover a mob you've killed for one line: `DropLab: 4s 12c per kill · ~3g 91s/h · 84 kills`. Hold
  **Shift** for its most likely drops with your rate and range, e.g. `Linen Cloth  31% (23-41%)`. With Daylight UI's
  tooltips the numbers are value tiles on its card. `/droplab tooltip` turns it off or on.
- `/droplab` lists the mobs worth most per kill (5+ kills of a mob), with gold per hour at your pace.
- `/droplab [item link or ID]` lists every mob you've seen drop it: your rate and range, items per kill, items per
  hour at your pace, the buy price, and Questie's rate next to yours (`matches`, `you get more` or `you get less`).
- `/droplab target` prints your target's full record.
- **WhereToFarm**: hovering a mob in its window adds `Your kills: 31% (23% to 41%) over 84 kills`.
- **Dashboard**: the All characters view has a **Drop rates from your kills** table.

## How it counts

- **Kills** come from the "X dies, you gain N experience" chat line. Forever forbids the combat log, so that line
  is the only way to know about a kill you didn't loot. The line has only the mob's name. DropLab ties the name to
  the mob's ID from your target, your mouse-over or the corpse you loot. Kills of a name it hasn't met yet wait,
  and are added when it does.
- **Dungeons**: Forever hides unit names and IDs there, so target and mouse-over don't help. The loot window still
  gives each corpse's mob ID, and DropLab gets that mob's name from Questie's NPC data, which matches the waiting
  kills to it. A mob you never loot in a dungeon stays unmatched. The mob tooltip doesn't show there either.
- Hovering friendly NPCs only remembers their name; mobs get a record once they're killed or looted.
- **Drops** come from the loot window. The game says which corpse each slot comes from, so area loot is split
  correctly, and reopening a corpse never counts twice.
- **Rate** = corpses that dropped the item ÷ kills. Grey mobs and every kill at level 60 give no XP line. For those
  DropLab can only divide by the corpses you opened, and a corpse with nothing on it can't be opened, so those rates
  run high. They're marked "looted corpses" (an `*` on the dashboard).
- **The range** is a 95% Wilson interval: where the true rate most likely is. 2 drops in 3 kills shows
  `67% (21-94%)`. Lists rank by the low end, so a sure 30% beats a lucky 2 of 3.
- **Value per kill** = every drop at its sale value (Make or Buy: the AH price after the 5% cut, or the vendor
  price if higher) plus the coin, ÷ kills. Drops with no price yet are left out and counted in the tooltip.
- **Pace** (per hour): the time between kills of the same mob, when they're 2 minutes apart or less. It's shown
  after 5 such gaps.
- **Skinning** (or any second loot of a corpse after its loot is gone) is counted as gathered, not as a drop.
- Not counted: fishing, players' corpses, and anything the game hides (some dungeon data is secret on Forever).
- In a group, other players' kills that give you XP count as kills, but their loot doesn't reach your window.
  Group rates run low.
- Data is shared by all your characters: a mob drops the same things for any of them.

## Files

| File | Role |
| --- | --- |
| `Stats.lua` | Pure: recording loot and kills, rates, Wilson range, value, pace, rankings. No WoW calls |
| `Core.lua` | Saved data, loot window and XP line events, names, mob tooltip, `/droplab`, public API |

Saved data: `DropLabDB` (account-wide). Public API: `DropLab.API.GetItemRate(npcID, itemID)`,
`GetItemSources(itemID)`, `GetMob(npcID)`.

## Tests

Run from this folder with Lua 5.1+ (installed at `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`):

```
lua tests/run.lua
```

`tests/wow_mock.lua` fakes the loot window, units, chat, tooltip and Make or Buy's and WhereToFarm's APIs. The
suites cover GUID parsing and loot that isn't counted (equivalence partitions), XP lines (rested, group bonus,
thousands separators), the Wilson range (boundary values n = 0, k = 0, k = n and a known value), kills vs looted
corpses (decision table), one corpse opened, reopened, partly looted and skinned (state-based test), the pace and
the 5-kill minimum (boundary values), use cases for farming a camp and for `/droplab`, the tooltip, the API and
saved data.

Checked offline only so far. Not yet confirmed in game: that `GetLootSourceInfo` gives the coin amount for a coin slot
(there's a fallback that reads the slot text), and that `LOOT_OPENED` still comes with the slots when auto-loot
is on (DropLab also listens to `LOOT_READY`).
