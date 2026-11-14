-- Usage (from the Haul folder):  lua tests/run.lua
local root = (arg and arg[0] or ""):match("^(.-)tests[/\\]run%.lua$") or ""
package.path = root .. "tests/?.lua;" .. package.path

local H = require("harness")
H.root = root

for _, suite in ipairs({ "test_session", "test_core", "test_ui_smoke" }) do
    print("[" .. suite .. "]")
    local before = #H.tests
    require(suite)(H)
    -- Run each suite's tests as they are registered so output stays grouped
    local slice = {}
    for i = before + 1, #H.tests do
        slice[#slice + 1] = H.tests[i]
    end
    H.tests = slice
    H.suiteOk = H.run() and (H.suiteOk ~= false)
    H.tests = {}
end

if H.suiteOk == false then
    os.exit(1)
end
