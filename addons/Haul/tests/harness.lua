-- Minimal test harness: runs outside WoW (Lua 5.1-5.4). Provides test registration, assertions,
-- and loaders that execute addon files with the same (addonName, ns) varargs WoW passes them.
local H = { tests = {}, root = nil }

function H.test(name, fn)
    H.tests[#H.tests + 1] = { name = name, fn = fn }
end

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

function H.eq(actual, expected, msg)
    if actual ~= expected then
        error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
    end
end

function H.near(actual, expected, msg)
    if type(actual) ~= "number" or math.abs(actual - expected) > 1e-9 then
        error((msg and (msg .. ": ") or "") .. "expected ~" .. fmt(expected) .. ", got " .. fmt(actual), 2)
    end
end

function H.truthy(v, msg)
    if not v then
        error((msg or "expected truthy value") .. ", got " .. fmt(v), 2)
    end
end

-- Loads addon source files into a fresh namespace table.
function H.load(files, ns)
    ns = ns or {}
    for _, file in ipairs(files) do
        local chunk, err = loadfile(H.root .. file)
        if not chunk then
            error(err)
        end
        chunk("Haul", ns)
    end
    return ns
end


function H.run()
    local passed, failed = 0, 0
    for _, t in ipairs(H.tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            print("  ok   " .. t.name)
        else
            failed = failed + 1
            print("  FAIL " .. t.name .. "\n       " .. tostring(err))
        end
    end
    print(string.format("\n%d passed, %d failed", passed, failed))
    return failed == 0
end

return H
