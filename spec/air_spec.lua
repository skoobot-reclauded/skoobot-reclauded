-- luacheck: std luajit+busted

-- data/air.lua is ToME's own suffocation rule (Actor.lua:622-634, 7395-7398),
-- pulled out as a pure predicate so the drowning fix (T-015) is tested against
-- the whole truth table without a running game. Two "fixes" before this one
-- were dead code that never ran (v1's undead precedence bug, mishander's
-- can_breath-is-always-a-table); these cases are exactly the ones those missed.

local manifest = require "spec.support.manifest"

local function loadAir()
  local chunk = assert(loadfile(manifest.path("src/data/air.lua")))
  return chunk()
end

describe("data/air.lua suffocates()", function()
  local air

  setup(function() air = loadAir() end)

  local function caps(over)
    local c = { can_breath = {} }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end

  it("does not suffocate on normal ground (no air_level)", function()
    assert.is_false(air.suffocates(caps(), nil, nil))
  end)

  it("suffocates in deep water it cannot breathe (the drowning case)", function()
    -- WATER_FLOOR: air_level = -5, air_condition = "water"
    assert.is_true(air.suffocates(caps(), -5, "water"))
  end)

  it("does NOT suffocate in water it can breathe", function()
    assert.is_false(air.suffocates(caps({ can_breath = { water = 1 } }), -5, "water"))
  end)

  it("treats a zero or negative can_breath value as unable to breathe", function()
    assert.is_true(air.suffocates(caps({ can_breath = { water = 0 } }), -5, "water"))
    assert.is_true(air.suffocates(caps({ can_breath = { water = -1 } }), -5, "water"))
  end)

  it("suffocates on an air_level tile with no air_condition", function()
    -- e.g. a vacuum/void tile: air_level set, condition nil -> cannot breathe
    assert.is_true(air.suffocates(caps(), -20, nil))
  end)

  it("never suffocates a no_breath actor (undead), even in water", function()
    -- This is the case v1's `not undead == 1` MEANT to cover and never did.
    assert.is_false(air.suffocates(caps({ no_breath = true }), -5, "water"))
  end)

  it("never suffocates an invulnerable actor", function()
    assert.is_false(air.suffocates(caps({ invulnerable = true }), -5, "water"))
  end)

  it("does not suffocate on a positive air_level tile it can breathe (a bubble)", function()
    assert.is_false(air.suffocates(caps({ can_breath = { water = 1 } }), 15, "water"))
  end)

  it("tolerates a nil can_breath table (the caller may not pass one)", function()
    local c = { no_breath = false }   -- no can_breath key at all
    assert.is_true(air.suffocates(c, -5, "water"))
  end)

  describe("breathable() is the inverse", function()
    it("true where suffocates is false", function()
      assert.is_true(air.breathable(caps(), nil, nil))
      assert.is_true(air.breathable(caps({ no_breath = true }), -5, "water"))
    end)
    it("false where suffocates is true", function()
      assert.is_false(air.breathable(caps(), -5, "water"))
    end)
  end)
end)
