-- luacheck: std luajit+busted

-- data/damagetypes.lua: what a damage type leaves behind (#170).
--
-- The table is derived mechanically from ToME 1.7.6's data/damage_types.lua.
-- These specs pin the rows where a HAND-WRITTEN table would go wrong, because
-- one already did: #170's own summary has three wrong rows out of five, and
-- the `tactical` hints it set out to replace are wrong in both directions.
--
-- So the cases below are chosen to fail if anyone ever "tidies" the table back
-- into the plausible version.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/damagetypes.lua")))
  return chunk()
end

describe("data/damagetypes.lua", function()
  local M
  before_each(function() M = load() end)

  describe("the rows the obvious table gets wrong", function()
    it("base FIRE leaves NOTHING -- burning is FIREBURN's", function()
      -- #170's table says "FIRE -> burning". The base fire projector sets no
      -- effect at all; EFF_BURNING is set by FIREBURN and FIRE_STUN.
      assert.is_nil(M.worst("FIRE"))
      assert.same({}, M.effects("FIRE"))
    end)

    it("base LIGHTNING brainlocks; it does NOT daze", function()
      -- #170's table says "LIGHTNING -> daze chance". The daze is
      -- LIGHTNING_DAZE's, and base LIGHTNING sets EFF_BRAINLOCKED instead --
      -- a different effect with a different consequence for the bot.
      assert.equal("impair", M.worst("LIGHTNING"))
      assert.same({ "BRAINLOCKED" }, M.effects("LIGHTNING"))
      assert.equal("disable", M.worst("LIGHTNING_DAZE"))
    end)

    it("base BLIGHT leaves nothing; the diseases are their own types", function()
      -- #170's table says "BLIGHT -> disease". Base blight sets no effect.
      assert.is_nil(M.worst("BLIGHT"))
    end)

    it("ICE and POISON are the two rows that were right", function()
      assert.equal("disable", M.worst("ICE"))
      -- FROZEN only. ICE's projector also sets EFF_WET, which is deliberately
      -- NOT here: being wet does nothing to the character by itself. It is not
      -- nothing, though -- ICE freezes at 25% and at 50% against a wet target,
      -- so wetness is a freeze amplifier. That belongs in whatever prices the
      -- chance, not in a list of what can be done to you.
      assert.same({ "FROZEN" }, M.effects("ICE"))
      -- POISON's effect is a damage-over-time, not a control effect, so it is
      -- deliberately not in the table at all.
      assert.is_nil(M.worst("POISON"))
    end)
  end)

  describe("worst", function()
    it("calls a turn-remover a disable", function()
      assert.equal("disable", M.worst("FREEZE"))
      assert.equal("disable", M.worst("PINNING"))
      assert.equal("disable", M.worst("PHYSICAL_STUN"))
    end)

    it("calls a degrader an impair", function()
      assert.equal("impair", M.worst("BLIND"))
      assert.equal("impair", M.worst("SILENCE"))
      assert.equal("impair", M.worst("SLOW"))
    end)

    it("prefers disable when a type does both", function()
      -- RETHREAD sets BLINDED, CONFUSED, PINNED and STUNNED.
      assert.equal("disable", M.worst("RETHREAD"))
    end)

    it("is nil for a type that only deals damage, and nil is an ANSWER", function()
      -- The common case. A caller treating nil as "unknown" rather than
      -- "nothing" would price every plain bolt as a threat.
      assert.is_nil(M.worst("PHYSICAL"))
      assert.is_nil(M.worst("ARCANE"))
      assert.is_nil(M.worst("COLD"))
    end)

    it("is nil for nonsense rather than erroring", function()
      assert.is_nil(M.worst(nil))
      assert.is_nil(M.worst(42))
      assert.is_nil(M.worst({}))
      assert.is_nil(M.worst("NOT_A_TYPE"))
    end)
  end)

  describe("effects", function()
    it("always returns a table", function()
      assert.same({}, M.effects(nil))
      assert.same({}, M.effects("NOT_A_TYPE"))
      assert.is_table(M.effects("ICE"))
    end)
  end)

  describe("the table itself", function()
    it("classifies every row by its own effect lists", function()
      -- Guards the generator's invariant: `worst` is never hand-set. If a row
      -- says disable, it must actually name a DISABLE effect.
      for name, row in pairs(M.BY_TYPE) do
        local hasDisable = false
        for _, e in ipairs(row.effects) do
          if M.DISABLE[e] then hasDisable = true end
        end
        assert.equal(hasDisable and "disable" or "impair", row.worst,
          "row " .. name .. " is classified against its own effects")
      end
    end)

    it("lists no row whose effects are all unclassified", function()
      for name, row in pairs(M.BY_TYPE) do
        local known = false
        for _, e in ipairs(row.effects) do
          if M.DISABLE[e] or M.IMPAIR[e] then known = true end
        end
        assert.is_true(known, "row " .. name .. " names no effect this module knows")
      end
    end)

    it("is big enough to be the real table, not a sample", function()
      local n = 0
      for _ in pairs(M.BY_TYPE) do n = n + 1 end
      assert.is_true(n > 60, "only " .. n .. " rows; the 1.7.6 derivation gives 72")
    end)
  end)
end)
