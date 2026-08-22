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

-- What a green run here still does not prove.
--
-- The game ships LuaJIT 2.0.2; this interpreter is 2.1. Same Lua 5.1 dialect,
-- different runtime, and 2.1 added library functions 2.0.2 does not have --
-- table.new and table.clear resolve here and would fail in-game. No assertion
-- can catch that from this side: the call succeeds on the machine doing the
-- checking. Lint cannot catch it either, because luacheck's `luajit` std does
-- not distinguish the two patch levels. Only running the real game does,
-- which is what the harness is for (docs/design-harness.md).
