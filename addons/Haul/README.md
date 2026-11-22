# Haul

Gold and XP per hour for your farming sessions. A small movable window shows:

```
Haul 0:42  1g 23s/h
Loot 85s · Coin 38s · Quests 10s
XP 12.3k/h · level in 25m
```

Hover it for the top 8 items by value, gold per hour per zone and your last sessions.

## Use

- `/haul` shows or hides the window. Drag it to move it. With Daylight UI installed it wears its look.
- `/haul reset` archives the current session and starts a new one.
- `/haul pause` / `/haul resume` stop and restart the clock. Nothing is counted while paused.
- `/haul history` prints the last 5 sessions. The last 30 are kept per character.

## What counts

- **Session**: from login until logout. A login within 10 minutes of logging out (a `/reload` or a quick relog)
  continues the same session; the time in between doesn't count.
- **AFK**: when the game flags you AFK, the clock pauses and the idle time before the flag (up to 5 minutes, back to
  your last loot or XP) is taken off. It resumes when you're back.
- **Coin**: money that arrives while the loot window is open, or within 1 second of the client's "You loot ..." /
  "Your share of the loot ..." line (either order). Each line pairs with one money change, so coin is never counted
  twice, and the localized line itself is never parsed. Money from vendors, mail, trades, the AH or the bank isn't
  income.
- **Quests**: the money reward of each quest you turn in.
- **Loot**: items from "You receive loot" and "You receive item" lines. Crafted items ("You create") and items bought
  while a merchant, mailbox, trade, AH or bank is open are not counted. Each item is valued when looted at the higher
  of its Auctionator price after the 5% AH cut and its vendor price. Soulbound junk with neither is worth 0. If the
  item's data isn't loaded yet it shows as "pricing..." and is valued as soon as it arrives.
- **XP**: every XP gain, including across level-ups. Time to level uses the session's XP rate.
- Rates show `--` during the first minute.
- Values the client marks as secret are skipped.

Auctionator is optional; without it items are valued at vendor price.

## Files

| File | Role |
| --- | --- |
| `Session.lua` | Pure session logic: pauses, income, XP rollover, rates, zones, history, format-string patterns |
| `Core.lua` | Saved data, game events, item valuation, `/haul` |
| `UI.lua` | The window and its tooltip |

## Tests

Run from this folder with Lua 5.1+ (installed at `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`):

```
lua tests/run.lua
```

`tests/wow_mock.lua` fakes the game and Auctionator APIs. The suites cover the session logic (equivalence partitions
for income kinds, boundary values for zero duration, exactly 5 idle minutes, the 1-minute rate threshold, level
rollover and the 30-session history limit, a decision table for AH-vs-vendor value), format-string-to-pattern
conversion against the enUS loot lines, Core's event handling (coin counted once in either event order, quest money,
crafted and bought items ignored, secret arguments skipped, pending item values, /reload resume at the 10-minute
boundary), and a smoke test of the UI on fake widgets. Layout is checked in game.
