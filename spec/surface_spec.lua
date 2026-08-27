-- luacheck: std luajit+busted

-- The superload surface, held to what #14 left and #76 finished: one file,
-- ONE one-line wrapper, nothing added to either class. Monkey-patching
-- Player and Actor is why the original broke on every ToME release, so
-- growing this surface is a decision, and this spec makes it one -- a second
-- wrapper, a method added to the class, or a wrapper that grows a body fails
-- here until the spec is changed with it. The tooltip line, the third
-- wrapper 0.1 started with, is an engine hook now; postUseTalent, the
-- second, is useTalent's return read where the bot already had it. What only
-- a running game can show -- that the wrapper is the one the engine calls
-- and the hook fires -- is tools/scenario-hooks.ps1.
--
-- #14, #76.

local manifest = require "spec.support.manifest"

local function read(rel)
  local f = assert(io.open(manifest.path(rel), "r"), "cannot open " .. rel)
  local s = f:read("*a")
  f:close()
  return s
end

local function exists(rel)
  local f = io.open(manifest.path(rel), "r")
  if f then f:close() return true end
  return false
end

--- The file's lines with comment lines dropped, so that prose about the
--- class does not count as code touching it.
local function codeLines(src)
  local out = {}
  for line in src:gmatch("[^\n]*") do
    if not line:match("^%s*%-%-") then out[#out + 1] = line end
  end
  return out
end

describe("the superload surface (#14)", function()
  local src, lines

  setup(function()
    src = read("src/superload/mod/class/Player.lua")
    lines = codeLines(src)
  end)

  it("is the Player superload alone; the Actor superload is gone", function()
    assert.is_true(exists("src/superload/mod/class/Player.lua"))
    assert.is_false(exists("src/superload/mod/class/Actor.lua"),
      "src/superload/mod/class/Actor.lua is back: the tooltip line is the Actor:tooltip hook (hooks/load.lua)")
  end)

  -- game/loader/init.lua chains every addon's superload of a class through
  -- loadPrevious: each gets the previous one's table. One call, before any
  -- use of the class, and the class returned, is what keeps the original
  -- SkooBot's wrappers and these chaining rather than clobbering.
  it("chains through loadPrevious once, first, and returns the class", function()
    local calls, at = 0, nil
    for i, line in ipairs(lines) do
      calls = calls + select(2, line:gsub("loadPrevious%(", ""))
      if line:match("^local _M = loadPrevious%(%.%.%.%)%s*$") then at = i end
    end
    assert.are.equal(1, calls)
    assert.is_truthy(at, "no `local _M = loadPrevious(...)` line")
    for i = 1, at - 1 do
      assert.is_nil(lines[i]:match("%f[%w_]_M%f[^%w_]"),
        "the class is touched before loadPrevious, at line " .. i .. ": " .. lines[i])
    end
    assert.is_truthy(src:match("\nreturn _M%s*$"), "the file does not end with `return _M`")
  end)

  -- ONE wrapper from #76 until #153; TWO now. postUseTalent existed only to
  -- see a talent that refused -- the one case the engine's Actor:postUseTalent
  -- hook cannot see, because it fires after `if not ret then return end` --
  -- and the same fact is in useTalent's `false` return, which SAI_useTalent
  -- already had. `act` has no hook equivalent in 1.7.6 and stays.
  --
  -- Growing this list back is a decision, and this is where it is made.
  --
  -- `runStopped` was added for #153, against api-surface-1.7.6.md's rule: is
  -- there a hook? No -- the only triggerHook in mod/class/Player.lua is
  -- Player:onEnterLevel:generateEscort -- so keep the wrapper, say why in the
  -- file, and make its body one delegating line. What it measures cannot be
  -- taken anywhere else: the engine's runCheck reads a seens map that
  -- accumulates over the run path, and runStopped's own body is what cleans
  -- it, so the disagreement only exists as the difference between the same
  -- function called either side of that call. The alternative was a counter
  -- over "explore made no progress", which cannot tell #153's disagreement
  -- from any other explore failure and would mask the next one.
  it("wraps exactly act and runStopped, each on one line", function()
    local names, bodies = {}, {}
    for _, line in ipairs(lines) do
      local name = line:match("^function _M[:%.]([%w_]+)")
      if name then
        names[#names + 1] = name
        bodies[name] = line
      end
    end
    assert.are.same({ "act", "runStopped" }, names)
    for name, line in pairs(bodies) do
      assert.is_truthy(line:match("%send$"),
        "the " .. name .. " wrapper is no longer one line: " .. line)
      -- The original must still be reached. Asserted as a reference rather
      -- than as `old_x(self, ` because that shape was `act`'s: it calls the
      -- original inline. `runStopped` cannot -- #153's measurement brackets
      -- that call, reading spotHostiles before it and after it -- so it hands
      -- the original to its helper instead. Both still delegate; only one can
      -- do it inline.
      assert.is_truthy(line:match("%f[%w_]old_" .. name .. "%f[^%w_]"),
        "the " .. name .. " wrapper no longer reaches the original: " .. line)
      assert.is_truthy(src:match("local%s+old_" .. name .. "%s*=%s*_M%." .. name),
        "old_" .. name .. " is not taken from the class table")
    end
  end)

  -- The replacement, asserted positively so that deleting the wrapper
  -- without reading the return would fail here rather than pass quietly.
  it("reads useTalent's refusal in SAI_useTalent instead (#76)", function()
    assert.is_truthy(src:find("local ret = game.player:useTalent(", 1, true),
      "SAI_useTalent no longer keeps useTalent's return")
    assert.is_truthy(src:find("if ret == false and bot.loop then bot.loop.talentfailed[tid] = true end", 1, true),
      "SAI_useTalent does not mark a refused talent from useTalent's return")
    -- `== false`, never `not ret`: nil is a talent still suspended awaiting
    -- targeting, which may yet fire and must not be recorded as failed.
    assert.is_nil(src:match("if%s+not%s+ret%s+.-talentfailed"),
      "a nil return is being treated as a refusal; nil is pending, not failed")
  end)

  it("adds nothing else to the class", function()
    for i, line in ipairs(lines) do
      assert.is_nil(line:match("^%s*_M[%.%[]"),
        "the class is written outside the wrapper, at line " .. i .. ": " .. line)
    end
  end)

  it("adds the tooltip line through the Actor:tooltip hook", function()
    local hooks = read("src/hooks/load.lua")
    assert.is_truthy(hooks:find('class:bindHook("Actor:tooltip"', 1, true),
      "hooks/load.lua does not bind Actor:tooltip")
    assert.is_truthy(src:find("function bot.tooltip(", 1, true),
      "the Player superload no longer defines bot.tooltip for the hook to call")
  end)
end)
