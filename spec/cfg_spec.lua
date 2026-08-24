-- luacheck: std luajit+busted

-- data/cfg.lua: the settings file format (#90).
--
-- The bug this module exists for is invisible in a single session -- the file
-- on disk is right and the live table is right; only a RESTART shows the
-- loss. That is why nothing caught it for so long, and why the format is
-- pulled out here where it can be held to its shape without a game.
--
-- #90.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/cfg.lua")))
  return chunk()
end

describe("data/cfg.lua", function()
  local C

  setup(function() C = load() end)

  it("names one file per option, under the addon's own namespace", function()
    assert.equals("tome.skoobot_reclauded", C.NAMESPACE)
    assert.equals("/settings/tome.skoobot_reclauded.MAX_ENEMY_COUNT.cfg", C.path("MAX_ENEMY_COUNT"))
    -- Game:saveSettings wants the middle part only; it adds both ends.
    assert.equals("tome.skoobot_reclauded.MAX_ENEMY_COUNT", C.file("MAX_ENEMY_COUNT"))
  end)

  describe("line()", function()
    -- The guard is the fix. The engine runs these files before any addon
    -- exists, so the namespace table has to be created by the file itself.
    it("creates the namespace table before assigning into it", function()
      local out = C.line("MAX_ENEMY_COUNT", 77)
      assert.is_truthy(out:find("tome.skoobot_reclauded = tome.skoobot_reclauded or {}", 1, true),
        "no guard line: this is the whole bug")
      assert.is_truthy(out:find("tome.skoobot_reclauded.MAX_ENEMY_COUNT = 77", 1, true))
      -- The guard must come FIRST, or it guards nothing.
      assert.is_true(out:find("or {}", 1, true) < out:find("MAX_ENEMY_COUNT = 77", 1, true))
    end)

    it("writes booleans as booleans", function()
      assert.is_truthy(C.line("STOP_POPUP", true):find("STOP_POPUP = true", 1, true))
      assert.is_truthy(C.line("STOP_POPUP", false):find("STOP_POPUP = false", 1, true))
    end)

    it("ends with a newline, like every other cfg the engine writes", function()
      assert.equals("\n", C.line("MAX_ENEMY_COUNT", 12):sub(-1))
    end)

    -- A string would need quoting, and inventing that here would be a way to
    -- write a file that does not load. LOG_LEVEL is a number for this reason.
    it("refuses anything that is not a number or a boolean", function()
      local out, why = C.line("LOG_LEVEL", "debug")
      assert.is_nil(out)
      assert.is_truthy(tostring(why):find("string", 1, true))
      assert.is_nil(C.line("X", nil))
      assert.is_nil(C.line("X", {}))
    end)
  end)

  describe("parse()", function()
    it("reads back what line() wrote", function()
      for _, v in ipairs({ 77, 0, -3, 0.4, 1e6 }) do
        assert.equals(v, C.parse(C.line("MAX_ENEMY_COUNT", v), "MAX_ENEMY_COUNT"))
      end
      assert.is_true(C.parse(C.line("STOP_POPUP", true), "STOP_POPUP"))
      assert.is_false(C.parse(C.line("STOP_POPUP", false), "STOP_POPUP"))
    end)

    -- Every file on any machine today is the old form. Recovering them is
    -- the difference between fixing this and telling the player their
    -- settings were lost once.
    it("reads the OLD one-line form, which is what every existing file is", function()
      assert.equals(77, C.parse("tome.skoobot_reclauded.MAX_ENEMY_COUNT = 77\n", "MAX_ENEMY_COUNT"))
      assert.is_true(C.parse("tome.skoobot_reclauded.STOP_POPUP = true\n", "STOP_POPUP"))
    end)

    it("tolerates a BOM, CRLF, no trailing newline, and loose spacing", function()
      assert.equals(77, C.parse("\239\187\191tome.skoobot_reclauded.MAX_ENEMY_COUNT = 77", "MAX_ENEMY_COUNT"))
      assert.equals(77, C.parse("tome.skoobot_reclauded.MAX_ENEMY_COUNT = 77\r\n", "MAX_ENEMY_COUNT"))
      assert.equals(77, C.parse("tome.skoobot_reclauded.MAX_ENEMY_COUNT=77", "MAX_ENEMY_COUNT"))
      assert.equals(77, C.parse("tome.skoobot_reclauded.MAX_ENEMY_COUNT   =   77   \n", "MAX_ENEMY_COUNT"))
    end)

    -- The guard line assigns the NAMESPACE, not a name under it. If the
    -- pattern were loose enough to match it, every option would come back
    -- as nil (the guard's value is not a number) and the fix would look
    -- like the bug.
    it("does not mistake the guard line for a value", function()
      local guard = "tome.skoobot_reclauded = tome.skoobot_reclauded or {}\n"
      assert.is_nil(C.parse(guard, "MAX_ENEMY_COUNT"))
    end)

    it("does not read one option's value out of another's line", function()
      local text = C.line("MAX_ENEMY_COUNT", 77)
      assert.is_nil(C.parse(text, "MAX_INDIVIDUAL_POWER"))
      assert.is_nil(C.parse(text, "MAX_ENEMY"))          -- a prefix is not a name
    end)

    it("returns nil rather than guessing at anything it cannot read", function()
      assert.is_nil(C.parse("", "X"))
      assert.is_nil(C.parse(nil, "X"))
      assert.is_nil(C.parse("garbage", "X"))
      assert.is_nil(C.parse("tome.skoobot_reclauded.X = ", "X"))
      assert.is_nil(C.parse("tome.skoobot_reclauded.X = \"a string\"", "X"))
      assert.is_nil(C.parse("tome.skoobot_reclauded.X = 77", ""))
    end)

    -- A name with a magic pattern character in it must not become a pattern.
    it("treats the option name as a name, not a pattern", function()
      assert.is_nil(C.parse("tome.skoobot_reclauded.AXB = 77", "A.B"))
    end)
  end)

  -- #95: the settings screen and the runtime reader both walk these, so a
  -- setting that is in one and not the other is a setting that either never
  -- appears or never resolves. Held as an invariant rather than as a list,
  -- so adding the thirteenth option cannot half-land.
  describe("the per-character split (#95)", function()
    it("ORDER is exactly the options that have titles, once each", function()
      local seen = {}
      for _, name in ipairs(C.ORDER) do
        assert.is_nil(seen[name], "listed twice: " .. name)
        seen[name] = true
        assert.is_not_nil(C.TITLE[name], "no title for " .. name)
      end
      for name in pairs(C.TITLE) do
        assert.is_true(seen[name] == true, "titled but not in ORDER: " .. name)
      end
    end)

    -- The settings screen shows a description beside every row. A row
    -- with none is a row a player cannot act on.
    it("every option has a description, and no description is orphaned", function()
      for _, name in ipairs(C.ORDER) do
        assert.is_string(C.DESC[name], "no description for " .. name)
        assert.is_true(#C.DESC[name] > 40, "description too short to help: " .. name)
      end
      for name in pairs(C.DESC) do
        assert.is_not_nil(C.TITLE[name], "described but not an option: " .. name)
      end
    end)

    it("a range is only given where it is not the default, and is ordered", function()
      for name, r in pairs(C.RANGE) do
        assert.is_not_nil(C.TITLE[name], "ranged but not an option: " .. name)
        assert.is_true(r[1] < r[2], "range is inverted: " .. name)
      end
    end)

    it("every option wants a control the screen knows how to draw", function()
      for _, name in ipairs(C.ORDER) do
        local k = C.kind(name)
        assert.is_true(k == "number" or k == "boolean" or k == "choice", name .. " -> " .. tostring(k))
      end
    end)

    it("every per-character setting is a real option", function()
      for name in pairs(C.PER_CHARACTER) do
        assert.is_not_nil(C.TITLE[name], "per-character but not an option: " .. name)
      end
    end)

    -- The split itself, stated once. A threshold answers "how dangerous is
    -- this character's situation"; a preference answers "how do I like this
    -- addon to behave". Copying the second onto every new character would
    -- be an irritation, not a feature.
    it("the three preferences are the account's, not the character's", function()
      assert.is_nil(C.PER_CHARACTER.ACTION_DELAY)
      assert.is_nil(C.PER_CHARACTER.STOP_POPUP)
      assert.is_nil(C.PER_CHARACTER.LOG_LEVEL)
    end)

    it("every safety threshold is the character's", function()
      for _, name in ipairs({ "LOWHEALTH_RATIO", "IGNORE_DAMAGE_HEALTH_RATIO",
                              "MAX_INDIVIDUAL_POWER", "MAX_DIFF_POWER",
                              "MAX_COMBINED_POWER", "MAX_ENEMY_COUNT",
                              "NORMAL_POWER_RATIO", "ELITES_POWER_RATIO", "BOSS_POWER_RATIO" }) do
        assert.is_true(C.PER_CHARACTER[name] == true, name .. " should be per character")
      end
    end)
  end)
end)
