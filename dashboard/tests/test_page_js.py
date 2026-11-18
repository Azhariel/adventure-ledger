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
