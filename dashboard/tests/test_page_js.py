"""Runs functions cut from template.html in Node, so the page's JS has tests.  Skipped without node (or lua)."""
import json
import os
import re
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DASH = os.path.dirname(HERE)
TEMPLATE = os.path.join(DASH, "template.html")

NODE = shutil.which("node")
LUA = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Lua", "bin", "lua.exe")
if not os.path.isfile(LUA):
    LUA = shutil.which("lua")


def _regex_end(line, i):
    """Index of the closing `/` of the regex literal that opens at line[i] (or the last index when it never closes)."""
    in_class = False
    i += 1
    while i < len(line):
        ch = line[i]
        if ch == "\\":
            i += 1
        elif ch == "[":
            in_class = True
        elif ch == "]":
            in_class = False
        elif ch == "/" and not in_class:
            return i
        i += 1
    return len(line) - 1


def _depth_delta(line, state):
    """Net bracket depth of one line, skipping '...', "..." and `...` strings, // comments and /* */ comments.

    `state` is [quote or None, in_block_comment]; a backtick string may span lines, the others end with the line.
    Template-literal `${...}` is not tracked: its braces are balanced inside the string, so skipping the string is enough."""
    depth, i, n = 0, 0, len(line)
    quote, block = state
    while i < n:
        ch = line[i]
        if block:
            if line.startswith("*/", i):
                block, i = False, i + 1
        elif quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = None
        elif line.startswith("//", i):
            break
        elif line.startswith("/*", i):
            block, i = True, i + 1
        elif ch in "'\"`":
            quote = ch
        elif ch == "/" and re.search(r"(^|[(,=:\[!&|?{};]|return)\s*$", line[:i]):
            i = _regex_end(line, i)
        elif ch in "{([":
            depth += 1
        elif ch in "})]":
            depth -= 1
        i += 1
    state[0] = quote if quote == "`" else None
    state[1] = block
    return depth


def _cut(lines, start, name):
    """Lines of the declaration starting at `start`, ended where bracket depth is back to 0 (a const also needs `;`)."""
    state, depth = [None, False], 0
    is_fn = bool(re.match(r"(async )?function ", lines[start]))
    for j in range(start, len(lines)):
        depth += _depth_delta(lines[j], state)
        if depth > 0 or state[0] or state[1]:
            continue
        code = lines[j].split("//")[0].rstrip()
        if is_fn:
            if depth == 0 and "{" in "\n".join(lines[start:j + 1]) and code.endswith("}"):
                return "\n".join(lines[start:j + 1])
        elif code.endswith(";"):
            return "\n".join(lines[start:j + 1])
    raise AssertionError("declaration of %s in template.html never closes (bracket depth never returns to 0)" % name)


def page_js(names, prelude=""):
    """Source of the named top-level `function NAME(` / `const NAME =` declarations of template.html.

    Each is cut by bracket depth from its first line to where depth is back to 0 (a const also at the `;`)."""
    with open(TEMPLATE, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    out = [prelude]
    for name in names:
        decl = re.compile(r"^((async )?function %s\(|const %s\s*=)" % (re.escape(name), re.escape(name)))
        for i, line in enumerate(lines):
            if decl.match(line):
                out.append(_cut(lines, i, name))
                break
        else:
            raise AssertionError("no top-level declaration of %s in template.html" % name)
    return "\n".join(out)


def run_node(js):
    """stdout of the script; skips the test without node."""
    if NODE is None:
        raise unittest.SkipTest("no node")
    got = subprocess.run([NODE, "-e", js], capture_output=True, text=True, encoding="utf-8", timeout=60)
    if got.returncode != 0:
        raise AssertionError("node failed:\n" + got.stderr)
    return got.stdout


def cell(dow, hour):
    return dow * 24 + hour


def hits(dow, hours, p):
    return [(cell(dow, h), p) for h in hours]


# Fixture grids: lists of (0-based cell, pct vs usual); every listed cell has 3 observations
RUN4 = [(cell(d, h), 0.05 + 0.01 * d) for d in (0, 2, 4, 6) for h in (10, 11)]
GRIDS = {
    "same-day runs": hits(1, range(19, 23), 0.08) + hits(6, range(4, 9), -0.07),
    "midnight and week end": [(cell(0, 23), 0.10), (cell(1, 0), 0.10)] + [(cell(6, 22), -0.10), (cell(6, 23), -0.10), (0, -0.10)],
    "gap split": hits(1, (19, 20, 22, 23), 0.08),
    "short run": hits(3, (12,), 0.2),
    "runs truncated": RUN4,
}

JS_STRIP = ["WEEKDAYS", "cellNum", "computeStrip", "stripText"]
RULE = {"MIN_N": 2, "STRIP_PCT": 0.05, "STRIP_MIN_HOURS": 2, "STRIP_RUNS": 2}


def lua_strip(cells):
    code = """
package.path = [[%s/lib/?.lua]] .. ";" .. package.path
local T = require("trends")
local g = { p = {}, s = {}, n = {}, own = true }
for i = 1, 168 do g.p[i], g.s[i], g.n[i] = false, false, false end
for _, c in ipairs({ %s }) do g.p[c[1] + 1], g.s[c[1] + 1], g.n[c[1] + 1] = c[2], 1, 3 end
local s = T.strip(g)
local function runs(l)
    local o = {}
    for i, r in ipairs(l) do o[i] = string.format('{"dow":%%d,"from":%%d,"to":%%d}', r.dow, r.from, r.to) end
    return "[" .. table.concat(o, ",") .. "]"
end
io.write('{"sell":' .. runs(s.sell) .. ',"buy":' .. runs(s.buy) .. '}')
""" % (DASH.replace("\\", "/"), ", ".join("{%d, %r}" % c for c in cells))
    got = subprocess.run([LUA, "-e", code], capture_output=True, text=True)
    if got.returncode != 0:
        raise AssertionError(got.stderr)
    return json.loads(got.stdout)


@unittest.skipIf(NODE is None, "no node")
class PageJsTests(unittest.TestCase):
    def js_strip(self, cells):
        js = page_js(JS_STRIP, "const stripRule = () => (%s);" % json.dumps(RULE)) + """
const cells = %s, week = { p: Array(168).fill(false), n: Array(168).fill(false), own: true };
for (const [c, p] of cells) { week.p[c] = p; week.n[c] = 3; }
process.stdout.write(JSON.stringify(computeStrip(week)));
""" % json.dumps(cells)
        return json.loads(run_node(js))

    @unittest.skipIf(LUA is None, "no Lua interpreter")
    def test_strip_parity(self):
        for name, cells in GRIDS.items():
            with self.subTest(name):
                self.assertEqual(self.js_strip(cells), lua_strip(cells))
        # the fixtures are not vacuous
        self.assertEqual(len(self.js_strip(GRIDS["gap split"])["sell"]), 2)
        self.assertEqual(self.js_strip(GRIDS["short run"]), {"sell": [], "buy": []})
        self.assertEqual(len(self.js_strip(RUN4)["sell"]), 2)

    def test_strip_text_midnight(self):
        js = page_js(JS_STRIP, "const stripRule = () => (%s);" % json.dumps(RULE)) + """
const week = { p: Array(168).fill(false), n: Array(168).fill(false), own: true };
week.p[23] = 0.1; week.n[23] = 3; week.p[24] = 0.1; week.n[24] = 3;
process.stdout.write(stripText(computeStrip(week)));
"""
        self.assertEqual(run_node(js), '<span class="sell">Sell: Mon 23–Tue 1</span>')

    def test_history_retry(self):
        prelude = """
let calls = 0, fail = true;
const fetch = () => { calls++; return Promise.resolve(fail ? { ok: false, status: 503 } : { ok: true, json: () => ({}) }); };
const HIST = new Map(), DR = { open: false }, trendsAt = () => null;
const drawHeader = () => {}, drawPrice = () => {}, drawWeek = () => {};
"""
        js = page_js(["loadHistory"], prelude) + """
const tick = () => new Promise(r => setTimeout(r, 0));
const out = [];
(async () => {
  loadHistory(113, 5); await tick(); await tick();
  out.push([calls, HIST.get("113:5").state]);
  loadHistory(113, 5); await tick(); await tick();
  out.push(calls);
  fail = false; loadHistory(113, 5); await tick(); await tick();
  out.push([calls, HIST.get("113:5").state]);
  out.push([calls, loadHistory(113, 5).state]);
  HIST.set("1:1", { state: "loading" }); loadHistory(1, 1);
  out.push(calls);
  process.stdout.write(JSON.stringify(out));
})();
"""
        self.assertEqual(json.loads(run_node(js)), [[1, "fail"], 2, [3, "ok"], [3, "ok"], 3])

    def test_drawer_series_pick(self):
        js = page_js(["cellNum", "pickSeries"]) + """
const empty = [], allNull = [{ x: 1, lo: null, mk: null }], real = [{ x: 2, lo: 5, mk: null }];
process.stdout.write(JSON.stringify([pickSeries(empty, null, allNull, real) === real, pickSeries(empty, null), pickSeries(real, allNull) === real]));
"""
        self.assertEqual(json.loads(run_node(js)), [True, None, True])

    def test_page_js_cuts_by_depth(self):
        js = page_js(["when", "pctVsUsual", "FC"], "const clock = t => 'C', date = t => 'D';") + """
process.stdout.write(JSON.stringify([when(86400), typeof FC.holt, pctVsUsual(0.1)]));
"""
        self.assertEqual(json.loads(run_node(js)), ["D", "function", "+10%"])
        with self.assertRaises(AssertionError):
            page_js(["noSuchThing"])

    def test_pct_vs_usual_tiny(self):
        js = page_js(["pctVsUsual"]) + """
process.stdout.write(JSON.stringify([0.004, -0.004, 0, 0.06, -0.06].map(pctVsUsual)));
"""
        got = json.loads(run_node(js))
        self.assertEqual(got, ["±0%", "±0%", "±0%", "+6%", "−6%"])
        self.assertFalse([g for g in got[:3] if g.startswith("+") or g.startswith("−")])

    def test_money_axis_flat_series(self):
        js = page_js(["moneyAxis"]) + """
process.stdout.write(JSON.stringify([moneyAxis([1, 1, 1]), moneyAxis([1, 11]), moneyAxis([5, 400]), moneyAxis([7]), moneyAxis([])]));
"""
        flat, wide, wider, one, none = json.loads(run_node(js))
        self.assertGreaterEqual(flat["max"] - flat["min"], 2)
        self.assertLessEqual(flat["min"], 1)
        self.assertGreaterEqual(flat["max"], 1)
        self.assertGreaterEqual(one["max"] - one["min"], 2)
        for spread in (wide, wider, none):
            self.assertIsNone(spread.get("min"))
            self.assertIsNone(spread.get("max"))

    def test_forecast_sane(self):
        js = page_js(["forecastShown"]) + """
process.stdout.write(JSON.stringify([forecastShown(100, 110), forecastShown(100, 24), forecastShown(100, 25), forecastShown(100, 401),
  forecastShown(100, 400), forecastShown(0, 5), forecastShown(100, NaN)]));
"""
        self.assertEqual(json.loads(run_node(js)), [True, False, True, False, True, False, False])

    HOUR_DATA = """
const grid = (ci, p, n) => { const w = { p: Array(168).fill(false), n: Array(168).fill(false) }; w.p[ci] = p; w.n[ci] = n; return w; };
const DATA = { trends: { stripRule: { MIN_N: 2, STRIP_PCT: 0.05 }, houses: { "PvP Horde": {
  items: {
    "1": { week: Object.assign(grid(30, 0.08, 3), { own: true }) },
    "2": { week: Object.assign(grid(30, 0.20, 3), { own: false }) },
    "3": { week: Object.assign(grid(30, 0.20, 1), { own: true }) },
    "5": { week: Object.assign(grid(30, 0.20, 1), { own: true }) },
  },
  families: [{ key: "herb", label: "Herbs", ids: [2, 3, 4], week: grid(30, -0.06, 4) },
             { key: "ore", label: "Ore", ids: [5], week: grid(30, 0.3, 1) }] } } } };
"""

    def test_hour_usual(self):
        js = page_js(["cellNum", "stripRule", "trendsAt", "hourUsual"], self.HOUR_DATA) + """
process.stdout.write(JSON.stringify([hourUsual(1, "PvP Horde", 30), hourUsual(2, "PvP Horde", 30), hourUsual(3, "PvP Horde", 30),
  hourUsual(4, "PvP Horde", 30), hourUsual(5, "PvP Horde", 30), hourUsual(1, "PvP Horde", 31), hourUsual(9, "PvP Horde", 30),
  hourUsual(1, "PvP Neutral", 30)]));
"""
        own, fam, thin, famOnly, thinFam, otherHour, unknown, noGrid = json.loads(run_node(js))
        self.assertEqual(own, {"p": 0.08, "fam": False})
        self.assertEqual(fam, {"p": -0.06, "fam": "Herbs"}, "own week not own: the family's cell")
        self.assertEqual(thin, {"p": -0.06, "fam": "Herbs"}, "own cell with n < MIN_N is skipped")
        self.assertEqual(famOnly, {"p": -0.06, "fam": "Herbs"}, "an item with no grid of its own still has its family's")
        self.assertIsNone(thinFam, "family cell with n < MIN_N is skipped too")
        self.assertIsNone(otherHour)
        self.assertIsNone(unknown)
        self.assertIsNone(noGrid, "no grid for the house: nothing")

    def test_sell_hour_text(self):
        js = page_js(["stripRule", "hourVerdict"], "const DATA = { trends: { stripRule: { MIN_N: 2, STRIP_PCT: 0.05 } } };") + """
process.stdout.write(JSON.stringify([hourVerdict({ p: 0.05 }), hourVerdict({ p: 0.2, fam: "Herbs" }), hourVerdict({ p: -0.05 }),
  hourVerdict({ p: 0.049 }), hourVerdict({ p: -0.01 }), hourVerdict(null)]));
"""
        self.assertEqual(json.loads(run_node(js)), ["good hour", "good hour", "slow hour", "usual", "usual", ""])

    def test_signal_hints_follow_the_rule(self):
        js = page_js(["cellNum", "rulePct", "houseCuts", "cutTxt", "dealsHintText", "sellWinHintText"]) + """
const rule = { DEAL_BELOW: 0.5, DEAL_MIN_SOLD: 5, SELL_ABOVE: 1.25 };
process.stdout.write(JSON.stringify([dealsHintText(rule), dealsHintText(undefined), sellWinHintText(rule), sellWinHintText(null)]));
"""
        deal, dealBare, sell, sellBare = json.loads(run_node(js))
        self.assertTrue(deal.startswith("Under its market value by 50% or more and selling 5+ a day. Profit each:"), deal)
        self.assertNotIn("undefined", dealBare)
        self.assertNotIn("NaN", dealBare)
        self.assertIn("(5% Faction, 15% Neutral)", dealBare)
        self.assertTrue(sell.startswith("Things you hold priced 25% or more over market value, still selling."), sell)
        self.assertTrue(sellBare.startswith("Things you hold priced well over market value"), sellBare)

    def test_move_basis_text(self):
        js = page_js(["moveBasisText"]) + """
process.stdout.write(JSON.stringify([moveBasisText({ moveBasis: "shifted" }, "up"), moveBasisText({ moveBasis: "trend" }, "down"),
  moveBasisText({ moveBasis: "scan" }, "up"), moveBasisText({ moveBasis: "scan" }, "down"), moveBasisText({}, "up")]));
"""
        self.assertEqual(json.loads(run_node(js)), ["new price level", "7-day trend", "vs launch low", "vs peak", ""])

    RULE = ("const RULE = { RISE: 0.25, FALL: -0.20, MOVER_MIN_SOLD: 2, FLIP_MIN_LISTED: 5, DEAL_BELOW: 0.5, DEAL_MIN_SOLD: 5,"
            " cut: { faction: 0.05, neutral: 0.15 } };")

    def test_movers_hint_follows_the_rule(self):
        js = page_js(["cellNum", "rulePct", "moversHintText"], self.RULE) + """
process.stdout.write(JSON.stringify([moversHintText(RULE, "up"), moversHintText(RULE, "down"), moversHintText(undefined, "up"),
  moversHintText(null, "down"), moversHintText({ RISE: 0.4, FALL: -0.1, MOVER_MIN_SOLD: 3 }, "up")]));
"""
        up, down, upBare, downBare, other = json.loads(run_node(js))
        self.assertEqual(up, "Market value up 25% or more over 7 days, or a new price level that has held for 2 days (API, 2+ sold a day)."
                             " Items the API sells fewer than 2 a day are left out. Items the API has no trend for yet: 50% or more over their launch low, as before.")
        self.assertEqual(down, "Market value down 20% or more over 7 days, or a new price level that has held for 2 days (API, 2+ sold a day)."
                               " Items the API sells fewer than 2 a day are left out. Items the API has no trend for yet: 30% or more under their peak, as before.")
        self.assertEqual(upBare, "50% or more over their launch low, at least 20 listed, launch low 10c or more.", "no API: today's hint")
        self.assertEqual(downBare, "30% or more under their peak: a chance to buy, or a market flooding.")
        self.assertTrue(other.startswith("Market value up 40% or more over 7 days,"), other)
        self.assertIn("(API, 3+ sold a day)", other)
        self.assertIn("fewer than 3 a day are left out.", other)

    def test_lone_deal_pill_and_snapshot_age(self):
        js = page_js(["cellNum", "rulePct", "houseCuts", "cutTxt", "dealsHintText", "LONE_TITLE", "LONE_COUNTED", "lonePill", "apiAsOf"],
                     "const when = t => 'T' + t;") + """
process.stdout.write(JSON.stringify([lonePill({ lone: true, guessed: true }), lonePill({ id: 1 }), lonePill(null),
  apiAsOf("PvP Horde", [{ key: "PvP Horde", apiAt: 5 }, { key: "PvP Neutral" }]), apiAsOf("PvP Neutral", [{ key: "PvP Neutral" }]),
  apiAsOf("PvP Horde", undefined), dealsHintText({ DEAL_SUSPECT: 0.9 }), dealsHintText(undefined)]));
"""
        lone, plain, none, asof, noAt, noSrc, hint, hintBare = json.loads(run_node(js))
        self.assertIn(">one cheap listing?</span>", lone)
        self.assertIn('title="Far under market: probably a single stray listing. Per day counts one unit."', lone)
        self.assertEqual((plain, none), ("", ""))
        self.assertEqual((asof, noAt, noSrc), ("API as of T5", "", ""))
        self.assertIn("Where that count isn't in yet, items 90% or more under are probably one stray listing: per day counts one unit.", hint)
        self.assertIn("capped by how many are listed within 10% of the lowest price.", hint)
        self.assertNotIn("stray", hintBare)

    def test_counted_lone_deal_and_listed_cell(self):
        js = page_js(["cellNum", "LONE_TITLE", "LONE_COUNTED", "lonePill", "dealListed"], "const short = n => String(n);") + """
process.stdout.write(JSON.stringify([lonePill({ lone: true, cheap: 1 }), dealListed({ basis: "api", cheap: 3, units: 77 }),
  dealListed({ basis: "api", units: 4 }), dealListed({ basis: "scans", available: 9 }), dealListed({ basis: "scans" })]));
"""
        lone, counted, bare, scans, none = json.loads(run_node(js))
        self.assertIn(">one cheap listing</span>", lone)
        self.assertIn('title="Only one unit is listed within 10% of the lowest price. Per day counts it alone."', lone)
        self.assertEqual(counted, '<span data-sort="3" title="3 within 10% of the lowest price, 77 listed in all">3 / 77</span>')
        self.assertEqual((bare, scans, none), ("4", "9", ""))

    def test_sell_window_extra_cell(self):
        js = page_js(["extraCell"], "const money = v => v + 'c'; const short = v => 'S' + v;") + """
process.stdout.write(JSON.stringify([extraCell({ extra: 3000, sells: 6, count: 40, soldPerDay: 6.5 }),
  extraCell({ extra: 1500, sells: 3, count: 3, soldPerDay: 10 }), extraCell({ extra: 200, count: 2 })]));
"""
        capped, all_, legacy = json.loads(run_node(js))
        self.assertEqual(capped, '<span data-sort="3000" title="Selling 6 of your 40 today (about S6.5 sell a day)">3000c</span>')
        self.assertEqual(all_, '<span data-sort="1500" title="Selling all 3 you have today (about S10 sell a day)">1500c</span>')
        self.assertEqual(legacy, '<span data-sort="200" title="Everything you hold: this row is priced from your scans">200c</span>')

    def test_now_at_falls_back_to_the_tab_snapshot(self):
        js = page_js(["nowAtOf"]) + """
const tab = { apiAt: 70 };
process.stdout.write(JSON.stringify([nowAtOf({ nowFrom: "api" }, tab), nowAtOf({ nowFrom: "api", nowAt: 60 }, tab),
  nowAtOf({ nowFrom: "scan", nowAt: 90 }, tab), nowAtOf({ nowFrom: "scan" }, tab), nowAtOf({ nowFrom: "api" }, null) ?? "none"]));
"""
        self.assertEqual(json.loads(run_node(js)), [70, 60, 90, None, "none"])

    def test_craft_flip_cells(self):
        js = page_js(["sellsIn", "flipLearn", "flipLearnText", "flipWho", "flipCrafts"],
                     "const money = v => (v / 100) + 's'; const moneyText = money; const esc = s => String(s);") + """
const des = { id: "d", name: "Des" };
process.stdout.write(JSON.stringify([sellsIn(0.351), sellsIn(1.5), sellsIn(2), sellsIn(0.001),
  flipWho({ crafter: des, who: [des] }),
  flipWho({ crafter: { ...des, learn: { how: "trainer", cost: 200 } }, who: [des], paysBackIn: 1 }),
  flipWho({ crafter: { ...des, learn: { how: "vendor" } }, who: [des] }),
  flipWho({ crafter: des, who: [des, { id: "a", name: "Azhariel" }, { id: "b", name: "Bo", learn: { how: "trainer", cost: 5 } }] }),
  flipCrafts({ crafts: 348, capBy: 2771, capName: "Tin Ore" }), flipCrafts({ crafts: 120, capBy: "sales" })]));
"""
        out = json.loads(run_node(js))
        self.assertEqual(out[:4], ["21m", "1h 30m", "2h", "1m"])
        self.assertEqual(out[4], "Des")
        self.assertEqual(out[5], '<span title="Pays back in 1 flip">Des · learn 2s</span>')
        self.assertEqual(out[6], "Des · vendor recipe")
        self.assertEqual(out[7], '<span title="Also: Azhariel, Bo (learn 0.05s)">Des +2</span>')
        self.assertEqual(out[8], '<span data-sort="348">348 (Tin Ore)</span>')
        self.assertEqual(out[9], '<span data-sort="120">120 (sales)</span>')

    def test_price_unsure_pill(self):
        js = page_js(["UNSURE_TITLE", "unsurePill"]) + """
process.stdout.write(JSON.stringify([unsurePill({ unsure: true }), unsurePill({})]));
"""
        on, off = json.loads(run_node(js))
        self.assertEqual(on, ' <span class="pill death" title="Few sales or listings at this house: this price may be one odd listing">price unsure</span>')
        self.assertEqual(off, "")

    def test_craft_flip_who_titles_are_text_and_sub_learns_show(self):
        js = page_js(["flipLearn", "flipLearnText", "flipWho"],
                     "const money = v => `<span class=\"coin\" data-sort=\"${v}\">${v / 100}s</span>`; const moneyText = v => (v / 100) + 's'; const esc = s => String(s).replace(/\"/g, '&quot;');") + """
const des = { id: "d", name: "Des" };
process.stdout.write(JSON.stringify([
  flipWho({ crafter: des, who: [des, { id: "b", name: "Bo", learn: { how: "trainer", cost: 200 } }] }),
  flipWho({ crafter: des, who: [des], subLearns: [{ name: "Smelt Tin", cost: 50 }] })]));
"""
        other, sub = json.loads(run_node(js))
        title = other.split('title="', 1)[1].split('"', 1)[0]
        self.assertEqual(title, "Also: Bo (learn 2s)")
        self.assertNotIn("<", title)
        self.assertIn('Des · learn Smelt Tin <span class="coin"', sub)

    def test_neutral_header_says_where_faction_prices_come_from(self):
        js = page_js(["factionPricesNote"]) + """
process.stdout.write(JSON.stringify([factionPricesNote({ DEAL_BELOW: 0.5 }), factionPricesNote(undefined)]));
"""
        withApi, without = json.loads(run_node(js))
        self.assertEqual(withApi, "Each house's prices are the newer of your last scan and the API's latest snapshot.")
        self.assertEqual(without, '<span class="pill faction">Faction AH</span> prices come from Auctionator.')

    def test_flip_hints_and_cuts_follow_the_rule(self):
        js = page_js(["cellNum", "rulePct", "houseCuts", "cutTxt", "dealsHintText", "flipsHintText", "gapMin"],
                     self.RULE + " let DATA = {};") + """
const bare = [flipsHintText(undefined), gapMin(), houseCuts(undefined)];
DATA = { signalRule: Object.assign({}, RULE, { FLIP_MIN_LISTED: 8 }) };
process.stdout.write(JSON.stringify(bare.concat([flipsHintText(DATA.signalRule), gapMin(),
  dealsHintText({ DEAL_BELOW: 0.5, DEAL_MIN_SOLD: 5, cut: { faction: 0.1, neutral: 0.2 } }), houseCuts({ cut: { faction: 0.1 } })])));
"""
        flipBare, gapBare, cutsBare, flip, gap, deal, cutsPart = json.loads(run_node(js))
        self.assertEqual(flipBare, "Gap = Neutral against Faction. The flip columns are what one item makes after the house's cut"
                         " (15% at Neutral, 5% at Faction). One stray listing sets the price in a thin market, so the default view"
                         " keeps items with 5 or more listed at both houses.", "no API: today's hint")
        self.assertEqual(gapBare, 5)
        self.assertEqual(cutsBare, {"faction": 0.05, "neutral": 0.15})
        self.assertIn("keeps items with 8 or more listed at both houses.", flip)
        self.assertTrue(flip.endswith(" Prices are the newer of your last scan and the API's latest snapshot."), flip)
        self.assertEqual(gap, 8, "the page's flip filter is the build's FLIP_MIN_LISTED")
        self.assertIn("(10% Faction, 20% Neutral)", deal)
        self.assertEqual(cutsPart, {"faction": 0.1, "neutral": 0.15}, "a missing cut falls back to today's")


JS_SYNC = ["esc", "SYNC_NOT_SET_UP", "SYNC_LABELS", "syncClock", "syncMB", "syncDue", "syncRunLabel", "syncButton",
           "syncRows", "syncResult"]
NOW = 1795100000


def sync_status(**over):
    st = {"configured": True, "name": "egb", "master": False, "bucketName": "ledger-sync", "error": None,
          "busy": None, "last": None, "newestSave": NOW - 600, "wtfUploadAt": NOW - 300, "marketUpload": None,
          "marketImportAt": None, "localLatest": NOW - 7200, "pcs": [], "bucket": [], "uploadDue": False,
          "importDue": False, "unsaved": False}
    st.update(over)
    return st


@unittest.skipIf(NODE is None, "no node")
class SyncPageTests(unittest.TestCase):
    def call(self, expr, st, run=None):
        js = page_js(JS_SYNC) + "\nconst st = %s, run = %s;\nprocess.stdout.write(JSON.stringify(%s));" % (
            json.dumps(st), json.dumps(run), expr)
        return json.loads(run_node(js))

    def rows(self, st, run=None):
        return self.call("syncRows(st, %d, run)" % NOW, st, run)

    def test_sync_not_configured(self):
        html = self.rows({"configured": False})
        self.assertIn("Sync isn't set up: add b2_key_id, b2_key and b2_bucket to ledger.cfg, then restart the tray.",
                      html)
        for b in re.findall(r"<button[^>]*>", html):
            self.assertIn("disabled", b)
        st = {"configured": False, "last": {"ok": False, "at": NOW, "message": "Sync isn't set up: x"}}
        self.assertEqual(self.call("syncResult(st, run, %d)" % NOW, st), "", "the page already says so")

    def test_sync_upload_due_is_primary(self):
        html = self.rows(sync_status(uploadDue=True, newestSave=NOW - 60, wtfUploadAt=None))
        self.assertRegex(html, r'class="syncbtn primary" data-sync="upload-wtf"')
        self.assertRegex(html, r"Played since your last upload: last save \d\d:\d\d, uploaded never\.")
        calm = self.rows(sync_status())
        self.assertRegex(calm, r'class="syncbtn" data-sync="upload-wtf"')
        self.assertRegex(calm, r"Up to date, uploaded \d\d:\d\d\.")

    def test_sync_master_only_market_button(self):
        self.assertNotIn("Upload market db", self.rows(sync_status()))
        self.assertIn("Upload market db", self.rows(sync_status(master=True, name="azhariel-base")))

    def test_sync_unsaved_warning(self):
        html = self.rows(sync_status(unsaved=True))
        self.assertRegex(html, r"WoW hasn&#39;t saved since \d\d:\d\d: /reload or log out first, or this upload misses "
                               r"the latest play\.|WoW hasn't saved since \d\d:\d\d: /reload or log out first, or this "
                               r"upload misses the latest play\.")

    def test_sync_import_due_per_pc(self):
        st = sync_status(importDue=True, bucket=[{"kind": "wtf", "pc": "azhariel-base", "at": NOW - 120, "size": 1}],
                         pcs=[{"name": "azhariel-base", "importedAt": NOW - 4000}])
        html = self.rows(st)
        self.assertRegex(html, r"azhariel-base uploaded \d\d:\d\d, you have \d\d:\d\d\.")
        self.assertRegex(html, r'class="syncbtn primary" data-sync="import"')

    def test_sync_market_preview(self):
        st = sync_status(importDue=True, bucket=[{"kind": "market", "pc": "azhariel-base", "at": NOW - 60,
                                                  "size": 5, "latest": NOW - 1800}])
        self.assertRegex(self.rows(st), r"Import replaces this PC&#39;s market db|Import replaces this PC's market db "
                                        r"\(newest hour \d\d:\d\d\) with azhariel-base's \(newest hour \d\d:\d\d\)\.")

    def test_sync_running_labels(self):
        html = self.rows(sync_status(), {"kind": "upload-wtf", "step": "uploading", "progress": [1258291, 1677722]})
        self.assertIn("Uploading 1.2 / 1.6 MB", html)
        for b in re.findall(r"<button[^>]*>", html):
            self.assertIn("disabled", b)
        self.assertIn("Zipping…", self.rows(sync_status(), {"kind": "upload-wtf", "step": "zipping"}))

    def test_sync_due_flag(self):
        self.assertTrue(self.call("syncDue(st)", sync_status(uploadDue=True)))
        self.assertTrue(self.call("syncDue(st)", sync_status(importDue=True)))
        self.assertFalse(self.call("syncDue(st)", sync_status()))
        self.assertFalse(self.call("syncDue(st)", {"configured": False, "uploadDue": True}))

    def test_sync_result_line(self):
        st = sync_status(last={"ok": False, "at": NOW - 30, "message": "Bucket unreachable: check the connection"})
        self.assertRegex(self.call("syncResult(st, run, %d)" % NOW, st),
                         r"^Bucket unreachable: check the connection · \d\d:\d\d$")
        st = sync_status(last={"ok": True, "at": NOW, "message": "Uploaded WTF (1.6 MB) at 18:46"})
        self.assertEqual(self.call("syncResult(st, run, %d)" % NOW, st), "Uploaded WTF (1.6 MB) at 18:46",
                         "a message with its own time gets no second one")

    def test_sync_escapes_names(self):
        st = sync_status(importDue=True, bucket=[{"kind": "wtf", "pc": "<b>x", "at": NOW - 60, "size": 1}])
        html = self.rows(st)
        self.assertNotIn("<b>x", html)
        self.assertIn("&lt;b&gt;x", html)
