-- luacheck: std luajit+busted

-- data/log.lua is the levelled debug channel (#46). These specs pin what
-- the act loop, the options tab, the bridge and the harness rely on: level
-- gating, a disabled call that never formats or calls anything, the
-- "[SKOOBOT]" prefix with the level tag on every line but info, the user
-- sink seeing warn and above only, and a channel that never raises.

local manifest = require "spec.support.manifest"

local function loadLog()
  local chunk = assert(loadfile(manifest.path("src/data/log.lua")))
  return chunk()
end

describe("data/log.lua", function()
  local logm

  setup(function() logm = loadLog() end)

  local function fake(level)
    local lines, user = {}, {}
    local L = logm.new{
      sink = function(line) lines[#lines + 1] = line end,
      user = function(lvl, text) user[#user + 1] = lvl .. ":" .. text end,
      level = level,
    }
    return L, lines, user
  end

  describe("levels", function()
    it("names five levels and silence, in order", function()
      assert.same({ off = 0, error = 1, warn = 2, info = 3, debug = 4, trace = 5 }, logm.LEVELS)
      for n = 0, 5 do assert.equals(n, logm.LEVELS[logm.NAMES[n]]) end
      assert.equals(5, logm.MAX)
    end)

    it("resolves a name, a number or a numeric string, case-insensitively", function()
      assert.equals(4, logm.level("debug"))
      assert.equals(4, logm.level("DEBUG"))
      assert.equals(4, logm.level(4))
      assert.equals(4, logm.level("4"))
      assert.equals(0, logm.level("off"))
    end)

    it("refuses anything else with a message, rather than guessing", function()
      local n, err = logm.level("verbose")
      assert.is_nil(n)
      assert.matches("no such log level: verbose", err)
      assert.is_nil(logm.level(6))
      assert.is_nil(logm.level(-1))
      assert.is_nil(logm.level(2.5))
      assert.is_nil(logm.level(nil))
      assert.is_nil(logm.level({}))
    end)

    it("ships at info, with the user sink at warn", function()
      assert.equals("info", logm.DEFAULT)
      assert.equals("warn", logm.USER_LEVEL)
      assert.equals("info", logm.new{ sink = function() end }.getLevel())
    end)
  end)

  describe("gating", function()
    it("emits a level and everything louder, and nothing quieter", function()
      for _, lvl in ipairs({ "off", "error", "warn", "info", "debug", "trace" }) do
        local L, lines = fake(lvl)
        L.error("e") L.warn("w") L.info("i") L.debug("d") L.trace("t")
        assert.equals(logm.LEVELS[lvl], #lines, "at level " .. lvl)
        for _, name in ipairs({ "error", "warn", "info", "debug", "trace" }) do
          assert.equals(logm.LEVELS[name] <= logm.LEVELS[lvl], L.enabled(name), name .. " at " .. lvl)
        end
      end
    end)

    it("setLevel takes a name or a number, returns the name, and refuses an unknown one unchanged", function()
      local L, lines = fake("warn")
      assert.equals("trace", L.setLevel("trace"))
      assert.equals("trace", L.getLevel())
      assert.equals(5, L.getLevelNumber())
      assert.equals("warn", L.setLevel(2))
      local name, err = L.setLevel("loud")
      assert.is_nil(name)
      assert.matches("no such log level", err)
      assert.equals("warn", L.getLevel())
      L.info("hidden") L.warn("shown")
      assert.equals(1, #lines)
    end)

    it("log(level, ...) gates the same way, and 'off' or an unknown level emits nothing", function()
      local L, lines = fake("info")
      L.log("info", "a") L.log(2, "b") L.log("debug", "c") L.log("off", "d") L.log("nope", "e")
      assert.same({ "[SKOOBOT] a", "[SKOOBOT] [warn] b" }, lines)
    end)

    it("enabled() is false for 'off' and for an unknown level", function()
      local L = fake("trace")
      assert.is_false(L.enabled("off"))
      assert.is_false(L.enabled("nope"))
      assert.is_true(L.enabled("trace"))
    end)
  end)

  describe("laziness", function()
    -- Count the calls string.format receives across a block. The module
    -- reaches the formatter through the string metatable (fmt:format), so
    -- swapping the field is seen; swapping it is the one thing luacheck's
    -- read-only std is there to flag, hence the inline exemption.
    local function countFormat(block)
      local real = string.format
      local calls = 0
      string.format = function(...) calls = calls + 1 return real(...) end -- luacheck: ignore 122
      local ok, err = pcall(block)
      string.format = real -- luacheck: ignore 122
      assert.is_true(ok, err)
      return calls
    end

    it("does not call string.format for a disabled level", function()
      local L, lines = fake("warn")
      local calls = countFormat(function()
        L.debug("%s %d", "x", 1)
        L.info("%s", "y")
        L.trace("%s", "z")
      end)
      assert.equals(0, calls)
      assert.equals(0, #lines)
    end)

    it("does call string.format for an enabled level, with the arguments", function()
      local L, lines = fake("debug")
      local calls = countFormat(function() L.debug("%s=%d", "x", 1) end)
      assert.equals(1, calls)
      assert.same({ "[SKOOBOT] [debug] x=1" }, lines)
    end)

    it("does not call a message function for a disabled level", function()
      local L, lines = fake("info")
      local called = false
      L.debug(function() called = true return "expensive" end)
      assert.is_false(called)
      assert.equals(0, #lines)
    end)

    it("calls a message function for an enabled level, passing the arguments", function()
      local L, lines = fake("debug")
      L.debug(function(a, b) return a .. "+" .. b end, "x", "y")
      assert.same({ "[SKOOBOT] [debug] x+y" }, lines)
    end)
  end)

  describe("lines", function()
    it("prefixes every line with [SKOOBOT] and tags every level but info", function()
      local L, lines = fake("trace")
      L.error("e") L.warn("w") L.info("i") L.debug("d") L.trace("t")
      assert.same({
        "[SKOOBOT] [error] e",
        "[SKOOBOT] [warn] w",
        "[SKOOBOT] i",
        "[SKOOBOT] [debug] d",
        "[SKOOBOT] [trace] t",
      }, lines)
    end)

    it("keeps the scenario-visible shape: an info line is '[SKOOBOT] ' then the text", function()
      local L, lines = fake("info")
      L.info("[Action] Using Talent %s on target %s", "Attack", "a rat")
      assert.equals("[SKOOBOT] [Action] Using Talent Attack on target a rat", lines[1])
      assert.is_truthy(lines[1]:find("^%[SKOOBOT%] %[Action%]"))
    end)

    it("passes a format with no arguments through untouched, percent signs included", function()
      local L, lines = fake("info")
      L.info("lost 25% of max life")
      assert.equals("[SKOOBOT] lost 25% of max life", lines[1])
    end)

    it("renders a non-string message with tostring", function()
      local L, lines = fake("info")
      L.info(42)
      L.info(nil)
      assert.same({ "[SKOOBOT] 42", "[SKOOBOT] nil" }, lines)
    end)

    it("never raises on a bad format: the line says what was asked", function()
      local L, lines = fake("info")
      assert.has_no.errors(function() L.info("%d", "not a number") end)
      assert.has_no.errors(function() L.info("%s %s", "one") end)
      assert.equals(2, #lines)
      assert.is_truthy(lines[1]:find("%d not a number", 1, true))
      assert.is_truthy(lines[1]:find("log format error", 1, true))
      assert.is_truthy(lines[2]:find("log format error", 1, true))
    end)

    it("never raises when a message function fails", function()
      local L, lines = fake("info")
      assert.has_no.errors(function() L.info(function() error("boom") end) end)
      assert.is_truthy(lines[1]:find("log message function failed", 1, true))
    end)

    it("line() is the formatter the sink sees", function()
      assert.equals("[SKOOBOT] x", logm.line(3, "x"))
      assert.equals("[SKOOBOT] [error] x", logm.line(1, "x"))
      assert.equals("[SKOOBOT] [trace] x", logm.line(5, "x"))
    end)
  end)

  describe("user sink", function()
    it("receives warn and error only, as level name and bare text", function()
      local L, _, user = fake("trace")
      L.error("e %d", 1) L.warn("w") L.info("i") L.debug("d") L.trace("t")
      assert.same({ "error:e 1", "warn:w" }, user)
    end)

    it("is gated by the level like the file sink", function()
      local L, lines, user = fake("error")
      L.warn("w") L.error("e")
      assert.same({ "[SKOOBOT] [error] e" }, lines)
      assert.same({ "error:e" }, user)
      L.setLevel("off")
      L.error("silenced")
      assert.equals(1, #lines)
      assert.equals(1, #user)
    end)

    it("is optional, and its failure never reaches the caller", function()
      local lines = {}
      local L = logm.new{ sink = function(l) lines[#lines + 1] = l end, level = "warn" }
      assert.has_no.errors(function() L.warn("w") end)
      assert.equals(1, #lines)
      local bad = logm.new{
        sink = function(l) lines[#lines + 1] = l end,
        user = function() error("message log is down") end,
        level = "warn",
      }
      assert.has_no.errors(function() bad.warn("w") end)
      assert.equals(2, #lines)
    end)
  end)

  it("carries its module, so a holder of the logger alone can name the levels", function()
    local L = logm.new{ sink = function() end }
    assert.equals(logm, L.module)
    assert.equals("debug", L.module.name(4))
  end)

  it("starts at the default when the initial level is absent or unknown", function()
    local L = logm.new{ sink = function() end, level = "loud" }
    assert.equals("info", L.getLevel())
    assert.equals("trace", logm.new{ sink = function() end, level = 5 }.getLevel())
  end)
end)
