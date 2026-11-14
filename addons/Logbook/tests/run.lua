-- Offline tests for Logbook.   Usage (from the Logbook folder):  lua tests/run.lua
local root = (arg and arg[0] or ""):match("^(.-)tests[/\\]run%.lua$") or ""
package.path = root .. "tests/?.lua;" .. package.path

local H = { tests = {}, root = root }
function H.test(name, fn) H.tests[#H.tests + 1] = { name = name, fn = fn } end
function H.eq(a, b, msg)
    if a ~= b then
        error((msg and (msg .. ": ") or "") .. "expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end
function H.truthy(v, msg) if not v then error((msg or "expected truthy") .. ", got " .. tostring(v), 2) end end

local failed, total = 0, 0
for _, suite in ipairs({ "test_journal", "test_core" }) do
    print("[" .. suite .. "]")
    H.tests = {}
    require(suite)(H)
    for _, t in ipairs(H.tests) do
        total = total + 1
        local ok, err = pcall(t.fn)
        if ok then
            print("  ok   " .. t.name)
        else
            failed = failed + 1
            print("  FAIL " .. t.name .. "\n       " .. tostring(err))
        end
    end
end
print(string.format("\n%d passed, %d failed", total - failed, failed))
if failed > 0 then os.exit(1) end
