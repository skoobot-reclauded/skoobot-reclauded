-- luacheck: std luajit+busted

-- The suite must run in the dialect the game runs, and nothing else in the
-- toolchain enforces that. .busted asks for luajit; this fails the build if
-- the request was not honoured -- which is the only check that survives
-- however busted was invoked, by whom, from what PATH.
--
-- This existed backwards for a while: four documents said unit tests ran
-- under LuaJIT and warned that a LuaJIT-2.1-only idiom might pass busted and
-- fail in-game. busted was in fact running PUC Lua 5.4, so the real behaviour
-- was the opposite -- ToME-dialect code (loadstring, setfenv, unpack) failed
-- under test while being perfectly correct in-game, and 5.4-only syntax
-- passed here and would crash in the game's LuaJIT 2.0.2. A green suite did
-- not mean what it appeared to mean. T-045.

describe("the test interpreter", function()
  it("is Lua 5.1, like the game", function()
    assert.are.equal("Lua 5.1", _VERSION)
  end)

  it("is LuaJIT, like the game", function()
    local jit = rawget(_G, "jit")
    assert.is_table(jit, "not running under LuaJIT -- check the `lua` key in .busted")
    assert.is_string(jit.version)
  end)

  -- Every one of these is absent from 5.4, and every one is used by code that
  -- has to run inside the game -- loadstring by the devbridge itself. If the
  -- suite is on the wrong interpreter, these are what break first.
  it("has the 5.1 library surface ToME code relies on", function()
    for _, name in ipairs({ "loadstring", "setfenv", "getfenv", "unpack" }) do
      assert.is_function(rawget(_G, name), name .. " is missing")
    end
  end)

  -- The complementary direction: 5.4-only syntax must not compile here, or it
  -- could reach the game, where it is a hard error.
  it("rejects syntax the game's Lua cannot parse", function()
    assert.is_nil(loadstring("return 7 // 2"), "integer division compiled; this is not 5.1")
    assert.is_nil(loadstring("return 1 & 3"), "bitwise and compiled; this is not 5.1")
  end)
end)
-- ---------------------------------------------------------------------------
-- The 2.1-vs-2.0.2 gap, checked from the source side (#63).
--
-- The game ships LuaJIT 2.0.2; this interpreter is 2.1. Same Lua 5.1 dialect,
-- different runtime, and 2.1 added library functions 2.0.2 does not have.
--
-- No RUNTIME probe can catch that from here -- the call succeeds on the
-- machine doing the checking -- and the obvious probe is worse than useless:
-- `table.new` and `table.clear` are nil in the base namespace under 2.1 as
-- well, until `require "table.new"` loads them, so asserting they are absent
-- passes identically on 2.0.2 and 2.1 and checks nothing. That was #63's own
-- proposed fallback; it does not work, and a green no-op assertion is worse
-- than a documented gap.
--
-- What can be checked from here is the SOURCE: no file the game loads may
-- name one of them. That is a scan, not an interpreter feature, so it holds
-- whichever LuaJIT ran the suite, and it fails on the line that introduces
-- the call rather than in a bug report from a player. It does not prove the
-- code runs under 2.0.2 -- only running it does, which is the harness, and
-- the CI job that runs this suite under a real 2.0 build (#63, waiting on
-- #30). It closes the one hole either of those would most likely find.
--
-- Lint cannot do this: luacheck's `luajit` std is one set for both patch
-- levels.

local manifest = require "spec.support.manifest"

-- Every directory whose Lua is loaded by the game's own interpreter. `src/`
-- ships; the devbridge does not ship but is loaded as an addon during every
-- harness run, so a 2.1-only call there fails in-game just as loudly.
local IN_GAME = { "src", "tools/devbridge", "tools/devbridge-boot" }

-- One entry per name LuaJIT 2.1 has and 2.0.2 does not. The pattern is
-- matched against code with comment lines removed, and it deliberately also
-- catches the `require "table.new"` spelling, since the module name contains
-- the call name.
local TWO_ONE_ONLY = {
  { pattern = "table%.new",             why = "table.new is a LuaJIT 2.1 extension" },
  { pattern = "table%.clear",           why = "table.clear is a LuaJIT 2.1 extension" },
  { pattern = "table%.move",            why = "table.move came from 5.3 by way of LuaJIT 2.1" },
  { pattern = "string%.buffer",         why = "string.buffer is 2.1-only, and only in late 2.1 builds" },
  { pattern = "coroutine%.isyieldable", why = "a 5.2 function LuaJIT 2.1 provides and 2.0.2 does not" },
}

--- The file's lines, numbered as the file numbers them, with whole-line
--- comments blanked rather than dropped -- prose naming one of these
--- functions (this file does it a few lines up) must not be a failure, and a
--- reported line has to be the line you can go and look at.
---
--- Split on "(.-)\n", not "[^\n]*": the latter yields an empty match between
--- every pair of lines, which would report every offence at roughly twice its
--- real line number.
local function codeLines(src)
  local out = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line:match("^%s*%-%-") and "" or line
  end
  return out
end

describe("the code the game loads", function()
  local files = {}

  setup(function()
    for _, dir in ipairs(IN_GAME) do
      for _, f in ipairs(manifest.luaFiles(dir)) do files[#files + 1] = f end
    end
  end)

  -- The scan's own floor. A walk that returned nothing would make every
  -- assertion below vacuously true, which is the failure this whole block
  -- exists to prevent; 19 files ship today, so 15 is a floor with slack and
  -- not a count to maintain.
  it("is found on disk", function()
    assert.is_true(#files >= 15, "only " .. #files .. " files found -- the walk is broken")
  end)

  it("calls no library function LuaJIT 2.0.2 lacks", function()
    local offences = {}
    for _, rel in ipairs(files) do
      local fh = assert(io.open(manifest.path(rel), "r"), "cannot open " .. rel)
      local body = fh:read("*a")
      fh:close()
      local lines = codeLines(body)
      for n, line in ipairs(lines) do
        for _, bad in ipairs(TWO_ONE_ONLY) do
          if line:match(bad.pattern) then
            offences[#offences + 1] = ("%s:%d %s"):format(rel, n, bad.why)
          end
        end
      end
    end
    assert.are.same({}, offences)
  end)
end)
