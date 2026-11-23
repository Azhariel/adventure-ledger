# Stockpile

Counts the items each of your characters has in their bags, bank and mailbox. It shows the counts on item tooltips and shares them with other addons. MakeOrBuy uses them to leave out reagents you already own.

## What it tracks

- **Bags**: the backpack and equipped bags, including the reagent bag on clients that have one. They are rescanned whenever your bags change.
- **Bank**: the bank slots and bank bags and the character bank tabs (whichever the client has), plus the reagent bank if there is one. The game only lets addons read the bank while it's open, so there's nothing to click: **talk to a banker once per character**. Chat confirms it the first time per session (`Stockpile: bank saved (120 items, 14 kinds).`), and Stockpile keeps that snapshot until your next visit. The `/stockpile` window shows when this character's bank was last saved.
- **Mail**: attachments in your inbox, read when you open a mailbox. Each character's saved counts update the next time you log in or open the bank or mailbox on that character.

The data is account-wide (`StockpileDB`). Each character is keyed as `Name-Realm`.

## Tooltip

Any item one of your characters on this realm owns gets these lines:

```
Stockpile: 34
  Azhariel: 20 bags, 10 bank, 4 mail
  Bankalt: 50 bank
```

Names use class colors. The character you're playing comes first, then the others, most first. Characters on other realms are left out.

## Slash commands

- `/stockpile [item link or id]` (or `/stock`): who on this realm has the item, and where.
- `/stockpile forget Name-Realm`: stop tracking a character, for example one you deleted.
- `/stockpile`: a window with this character's counts in bags, bank and mail, when its bank was saved, and every tracked character. `/stockpile print` sends the same to the chat; `/stockpile help` lists the commands.

## API

The API is the global `Stockpile.API`, version 1:

| Call | Returns |
| --- | --- |
| `GetCount(itemID, scope)` | `total, list`. `scope` is `"character"` (the default; the current character only) or `"realm"` (every character on the current realm). `list` holds one entry per character that has the item: `{ name=, realm=, class=, bags=, bank=, mail=, total= }`, current character first. |
| `GetOwnedMap(scope)` | A new `{ [itemID] = count }` for the scope. The caller may change it. |
| `RegisterCallback(owner, fn)` | Calls `fn(owner)` after counts change. It is debounced to once per 0.3 s burst and only fires on a real change. |
| `UnregisterCallback(owner)` | Removes it. |

Before the character is known (before login finishes), `GetCount` returns `0, {}` and `GetOwnedMap` returns `{}`.

```lua
if Stockpile and Stockpile.API then
    local have = Stockpile.API.GetCount(2592, "realm") -- Wool Cloth on this realm
end
```

Addons using it should list `Stockpile` under `## OptionalDeps` so it loads first when installed, and keep working without it.

## Rules

- "Secret" values from this client are skipped and never saved.
- Events this client doesn't know are ignored; registering them can't break loading.

## Files

| File | Role |
| --- | --- |
| `Store.lua` | Pure logic: saved layout, counts per scope, owned map, tooltip and chat text |
| `Core.lua` | Scans bags, bank and mail on events; change callbacks; `/stockpile` |
| `API.lua` | The public `Stockpile.API` |
| `Tooltip.lua` | The item tooltip lines |

## Tests

Run from this folder with Lua 5.1+ (installed at `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`):

```
lua tests/run.lua
```

`tests/wow_mock.lua` fakes the container, mail, unit, timer and tooltip APIs.

- **Store**: equivalence partitions and boundary values for zero counts, several characters, the realm filter, and an owned-map copy that the caller can change.
- **Scanning**: bags, the reagent bag, the bank only while it's open (both layouts, the rescan a moment after opening, the once-per-session confirmation), bank tabs, mail, secret values, unknown events, and the debounced callback.
- **Contract**: the API.
- **Text**: the tooltip and the slash command.

How the tooltip looks is checked in game.
