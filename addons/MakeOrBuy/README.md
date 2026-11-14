# Make or Buy

Auctionator's crafting info prices a recipe by buying every reagent. Make or Buy also checks whether
crafting a reagent yourself is cheaper, down through as many levels as needed (up to 6).

Example: Woolen Bag = 3 Bolt of Woolen Cloth + 1 Fine Thread. If bolts cost 6s on the AH but 9 Wool Cloth
costs 4s 59c, Make or Buy prices the bag with crafted bolts and shows the profit for that plan.

## Use

1. Open each of your professions once. Make or Buy saves your learned recipes per character.
2. Scan the AH with Auctionator as usual, and visit a vendor that sells your thread/dyes so Auctionator caches vendor prices.
3. In the Professions window, below Auctionator's lines:
   - **Make or Buy cost**: best cost for one craft, and how much it saves against buying all reagents.
   - **Make or Buy profit**: sale value × output quantity minus the best cost, exact to the copper. Sale value is the AH price after the 5% cut, or the vendor price if that's higher (shown as "(vendor)"). Auctionator rounds to the silver and ignores vendor prices, so the two numbers can differ.
   - **Spend** (third line, when it matters): with the window's "craft N" box above 1, or when you own some reagents
     (needs the **Stockpile** addon), the cash you still have to spend, e.g. `For 3 crafts: spend 14s 73c (using 4 you own)`.
   - **(price unreliable)** after the profit: the crafted item's AH price is a spike (1.5x or more its usual price), 3+ days old, or only 1-2 are listed.
   - **Hover**: the full plan for the batch, with both total and unit prices (`@each`) when buying or crafting more than 1, for example `3x Bolt of Woolen Cloth  craft 3x` → `9x Wool Cloth  have 4, AH`.
   - **Click** (AH open): searches the plan's AH shopping list in Auctionator, minus what you own. Vendor items are left out.
   - **Shift-click**: opens **WhereToFarm** (if installed) on where to get the reagents: the one that costs the most
     to buy first, with icons to switch to the others.
4. **Worth crafting tab** (gold-coin side tab under the profession icons on the right) covers the open
   profession. Switch views with the **Profit** / **Skill-up** / **Route** / **Learn** buttons; the view is remembered.
   - **Profit**: what's worth crafting to sell. Columns: best cost, sale value, profit and margin (profit ÷ cost). By default it lists only recipes with profit above 0 and every reagent priced. An orange `!` marks an unreliable AH price (hover for why).
   - **Skill-up**: the cheapest way to your next skill point. Columns: best cost, sale value, **net cost** (cost minus sale value; green `+` means you earn), and **per point** (net cost ÷ expected skill points). By default it lists only recipes that still give points, cheapest point first. Points you earn money on count as free, and among those the one needing fewest crafts comes first (so a 25%-chance green recipe doesn't top the list just because 4 crafts earn more than 1).
   - **Route**: the cheapest expected path from your skill to **Target skill** (top right; defaults to your current cap). One row per stretch: skill range, expected crafts, cash spent and net cost after selling. With **Include recipes to learn** ticked it also uses trainer and vendor recipes you don't know yet, when their learn cost pays off over the points they give; those rows say `(learn)`. **Search AH** (AH open) searches the whole route's shopping list, minus what you own.
   - **Learn**: recipes you don't know yet: the skill to learn them at (grey = not yet), the learn cost (trainer fee, or the recipe item's vendor/AH price), profit per craft, and **pays back** = crafts until the profit covers the learn cost.
   - **Sale value** is the AH price after the 5% cut, or the vendor price `(v)` if higher. The vendor price is a guaranteed floor and values items nobody lists on the AH.
   - **Show all recipes** includes everything (losing, unpriced, grey).
   - Click a header to sort, click again to reverse. Each view remembers its own sort.
   - Recipe names use skill-up colors (orange/yellow/green/grey). A green `*` means the cost relies on crafting your own reagents.
   - Hover: AH and vendor prices and which one is used, profit, what buying every reagent would give, the AH price age, the skill-up chance and per-point cost, and the full plan.
   - Left-click opens the recipe (known recipes only). Right-click (AH open) searches its shopping list in Auctionator.
   - **Shift-click** (needs **WhereToFarm**): where to get its reagents, opened on the priciest, with icons at the top
     right to switch to every other reagent (vendors nearest first, mobs, chests, fishing zones, quests). On a recipe
     you don't know yet (Learn view, `(learn)` route rows) it opens **where to learn it** instead: its trainers nearest
     first, or the vendors, drops and quests of its recipe item; the reagents are in the same icon strip. Click any row
     there to pin it on your map with a waypoint. The tooltip of an unknown recipe names the nearest place to learn it,
     e.g. `Learn from (trainer, 1 of 5)  Cook Ghilm, Dun Morogh (here)`.
   - **Ctrl-click**: shows the crafted item itself in a sticky tooltip, like a chat link (a bag's slots, gear stats,
     what a potion does). Ctrl-click it again, or the tooltip's X, to close it.
   - **Restock list** (bar at the bottom): **Alt-click** a recipe in any view to plan one more craft (a Route row adds its
     whole stretch), **Alt-right-click** to take one off. Listed recipes show a cyan `[n]`. The list spans all your
     professions and is saved per character. The bar shows the crafts and the cash still to spend; hover it for every
     craft's profit, the merged shopping list and what you own that it uses. **Search AH** (AH open) searches everything
     at once, minus what you own and vendor items; **Clear** empties it.
   - It works like the native side tabs. Click it again, click any profession tab or WhatsTraining's tab, switch profession or close the window to go back. It refreshes after each Auctionator scan.
5. `/mob [item link]` prints the cheapest way to get any item. `/mob` alone prints how many recipes are known.
6. `/mob owned` turns counting your own items (Stockpile) off or on. `/mob restock` prints the restock list and its
   shopping list; `/mob restock clear` empties it.
7. **Mail to your alts.** Each character saves what it crafts with (reagents of its known recipes) and what its
   restock list still needs, account-wide, when it logs in or out. At a mailbox, a **For your alts** list appears
   next to the mail window: items in your bags another character crafts with, restock needs first. Click a row to
   open Send Mail with that character's name, subject "Materials" and the stacks attached (whole stacks, as few extra as
   possible); you check it and press Send. Soulbound items, items you craft with yourself and characters of the
   other faction are left out. `/mob alts` prints the same list anywhere. Log in once with each alt (and open its
   professions) so the others know about it.
8. `/mob auctionator` hides Auctionator's own "To Craft" / "Profit" lines, and the Make or Buy lines move up into their place. Run it again to bring them back. Auctionator's AH Search button stays. You can also do this in Auctionator's options under Crafting Info.

## Rules

- Each reagent uses the cheaper of: buying it (lower of vendor and AH price), or crafting it with a learned recipe.
- When buying and crafting cost the same, buying wins.
- A craft route with an unpriced reagent anywhere in it is never chosen. A reagent that has no price and no recipe is shown as "missing prices" and counts as 0, as Auctionator does.
- Recipes that make several items per craft are costed per unit. The plan rounds the number of crafts up.
- Costs and profit use market prices, even for reagents you own (they could be sold instead). Only the
  **spend** figures subtract what you own (bags, bank and mail of this character, via the optional Stockpile addon),
  at any depth: owning 2 Bolts means crafting only 1.
- Only your own professions are scanned, never linked or guild views. Only learned recipes are crafted in plans.
- Skill-up chance per craft follows the classic rule: 100% while orange, then falling in a straight line from
  100% at the first yellow point to 0% at grey. The game doesn't show where yellow, green and grey start, so they're estimated:
  - start from the skill the recipe is learned at (from WhatsTraining's recipe data, bundled in `Data/RecipeData.lua`): yellow +25, grey +25 more, green halfway;
  - every scan notes each recipe's colour at your current skill, which narrows the estimate (seen yellow at 63: yellow started at 63 or before). Estimates get better as you level.
  - The colour the game shows right now always wins: if the estimate disagrees, the band average (yellow ~75%, green ~25%) is used.
  - Yellow/green figures are marked `~`. Orange recipes that give several points divide the cost accordingly.
- The route doesn't count skill points from crafting intermediates (e.g. Bolts) along the way, so it slightly overestimates crafts.
- AH price checks compare today's price with the median of up to 14 earlier scan days (needs 3+ days of history).

## Files

| File | Role |
| --- | --- |
| `Planner.lua` | Pure make-or-buy logic, no WoW calls; expands plans for a batch and what you own |
| `Market.lua` | Pure: flags spiking, stale or thin AH prices |
| `Skill.lua` | Pure: skill threshold estimates, skill-up chance, route planner |
| `Restock.lua` | Pure: the restock list merged into one shopping list, owned items shared across it |
| `Ranking.lua` | Plans every recipe of a profession (and unlearned ones), filters and sorts. Pure logic |
| `ProfitTab.lua` | The Worth crafting tab and its panel |
| `Scanner.lua` | Reads recipes, skill level and recipe colours from `C_TradeSkillUI` |
| `Core.lua` | Saved data, Auctionator prices and history, Stockpile, events, `/mob` |
| `Alts.lua` | Pure: each character's crafting profile, what to mail which alt, which stacks to attach |
| `MailPanel.lua` | The "For your alts" list at the mailbox and attaching the items |
| `Data/RecipeData.lua` | Generated from WhatsTraining (MIT) by `tools/gen_recipes.lua`: learn skill, trainer cost, source per recipe |
| `UI.lua` | Lines, tooltip and click-to-search in the Professions window |

Saved data: `MakeOrBuyCharDB` per character (recipes, restock list, skill estimates) and `MakeOrBuyDB` for the account
(each character's crafting profile, for mailing alts).

Optional addons: **Stockpile** (what you own), **WhereToFarm** (Shift-click). Make or Buy works without them.

Public API (used by **DropLab**): `MakeOrBuy.API.GetBuyPrice(itemID)` (copper, `"vendor"` or `"ah"`) and
`MakeOrBuy.API.GetSaleValue(itemID)` (AH after the 5% cut, or the vendor price if higher).

## Tests

Run from this folder with Lua 5.1+ (installed at `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`):

```
lua tests/run.lua
```

`tests/wow_mock.lua` fakes `C_TradeSkillUI`, Auctionator's API and the globals Core needs. The suites cover
the planner (equivalence partitions for buy/craft/missing and for owning none/some/all, boundary values for depth and
output quantity, the Woolen Bag use case), the market check (boundary values at each limit), the skill model
(boundaries at each threshold, state-based tests of accumulated observations, route use cases), the ranking
(boundary at profit = 0, a decision table for AH-vs-vendor sale value, learn cost and payback, sort order with
missing values), the restock list (boundary values for the count, owned items shared across entries as a state test, the
Woolen Bag + Bolts use case), mailing alts (decision table for who gets an item, boundary values for picking stacks, a
state test of the mailbox from inbox to attached, a smoke test of the panel), the scanner, and Core's events, prices, optional addons and slash command. `test_ui_smoke.lua` runs the UI code on fake widgets, catching Lua errors and
checking the text it shows. Layout and the look of the tab are checked in game.
