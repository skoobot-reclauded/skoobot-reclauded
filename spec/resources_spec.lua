-- luacheck: std luajit+busted

-- data/resources.lua: the class pools a character runs on (#128).
--
-- The fixtures are shaped the way engine/interface/ActorResource.lua shapes
-- them: a registry of defs carrying short_name/minname/maxname, and an actor
-- holding self[short_name] and its bounds. The inverted case is the one worth
-- the tests -- Equilibrium and Paradox count UP as they are spent, so a full
-- bar is a character in trouble and the naive fraction reads it backwards.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/resources.lua")))
  return chunk()
end

--- A def as defineResource builds one.
local function def(short, over)
  local d = {
    name = short:gsub("^%l", string.upper),
    short_name = short,
    minname = "min_" .. short,
    maxname = "max_" .. short,
    invert_values = false,
    talent = "T_" .. short:upper() .. "_POOL",
  }
  for k, v in pairs(over or {}) do d[k] = v end
  return d
end

local MANA  = def("mana")
local EQUIL = def("equilibrium", { invert_values = true })
local STAM  = def("stamina")

--- The game's own test for "this resource is the actor's": the def names a
--- gating talent and the actor knows it (PlayerDumpJSON.lua:93).
local function knowing(...)
  local set = {}
  for _, d in ipairs({...}) do set[d.talent] = true end
  return function(t) return set[t] == true end
end
local KNOWS_ALL = function() return true end

describe("data/resources.lua", function()
  local M
  setup(function() M = load() end)

  describe("headroom", function()
    it("is 1 when nothing is spent and 0 when exhausted", function()
      assert.are.equal(1, M.headroom(MANA, 100, 0, 100))
      assert.are.equal(0, M.headroom(MANA, 0, 0, 100))
    end)

    it("is the fraction left in between", function()
      assert.are.equal(0.25, M.headroom(MANA, 25, 0, 100))
    end)

    it("honours a non-zero minimum", function()
      -- half of the usable span, not half of the maximum
      assert.are.equal(0.5, M.headroom(MANA, 150, 100, 200))
    end)

    -- The whole reason this function exists rather than a division.
    it("reads an INVERTED pool from the top down", function()
      assert.are.equal(1, M.headroom(EQUIL, 0, 0, 100))    -- empty equilibrium is fine
      assert.are.equal(0, M.headroom(EQUIL, 100, 0, 100))  -- full equilibrium is trouble
      assert.are.equal(0.25, M.headroom(EQUIL, 75, 0, 100))
    end)

    it("clamps rather than returning a number outside 0..1", function()
      assert.are.equal(1, M.headroom(MANA, 500, 0, 100))
      assert.are.equal(0, M.headroom(MANA, -20, 0, 100))
    end)

    it("declines a pool with no span, rather than dividing by zero", function()
      assert.is_nil(M.headroom(MANA, 0, 0, 0))
      assert.is_nil(M.headroom(MANA, nil, 0, 100))
    end)
  end)

  describe("of()", function()
    -- A warrior carries a mana field it never uses; 0/0 is not a starved
    -- caster and must not be reported as one.
    it("ignores a pool the actor does not run on", function()
      -- ToME gives EVERY actor a max for every resource, so the warrior below
      -- has a full-size mana bar it never uses. The span is fine; what makes
      -- it not his is that he does not know the gating talent.
      local warrior = { mana = 0, min_mana = 0, max_mana = 100, stamina = 100, min_stamina = 0, max_stamina = 100 }
      local pools = M.of(warrior, { MANA, STAM }, knowing(STAM))
      assert.are.equal(1, #pools)
      assert.are.equal("stamina", pools[1].short)
    end)

    it("reports the pools an actor does run on, lowest headroom first", function()
      local caster = {
        mana = 10, min_mana = 0, max_mana = 100,
        stamina = 90, min_stamina = 0, max_stamina = 100,
      }
      local pools = M.of(caster, { STAM, MANA }, KNOWS_ALL)
      assert.are.equal(2, #pools)
      assert.are.equal("mana", pools[1].short)     -- 0.10 sorts before 0.90
      assert.are.equal("stamina", pools[2].short)
    end)

    it("marks a pool low, and an inverted one low when it is FULL", function()
      local a = { equilibrium = 95, min_equilibrium = 0, max_equilibrium = 100 }
      local pools = M.of(a, { EQUIL }, KNOWS_ALL)
      assert.is_true(pools[1].low)
      assert.is_true(pools[1].inverted)
    end)

    it("tolerates nonsense without raising", function()
      assert.are.same({}, M.of(nil, { MANA }, KNOWS_ALL))
      assert.are.same({}, M.of({}, nil, KNOWS_ALL))
      -- no predicate at all: nothing is claimed, rather than everything
      assert.are.same({}, M.of({ mana = 5, min_mana = 0, max_mana = 100 }, { MANA }))
    end)
  end)

  describe("an unbounded pool", function()
    -- max_equilibrium and max_paradox are `false` in the engine: they
    -- accumulate rather than deplete and have no ceiling, so a fraction would
    -- be invented. Measured on a live Oozemancer, which knows the equilibrium
    -- pool and has max=false.
    local UNB = def("equilibrium", { invert_values = true })

    it("is reported by value, with no headroom and never as low", function()
      local a = { equilibrium = 300, min_equilibrium = 0, max_equilibrium = false }
      local pools = M.of(a, { UNB }, KNOWS_ALL)
      assert.are.equal(1, #pools)
      assert.is_nil(pools[1].headroom)
      assert.is_true(pools[1].unbounded)
      assert.is_false(pools[1].low)
      assert.are.equal(300, pools[1].value)
    end)

    it("describes as a value, not a fraction", function()
      local a = { equilibrium = 300, min_equilibrium = 0, max_equilibrium = false }
      assert.are.equal("equilibrium=300", M.describe(M.of(a, { UNB }, KNOWS_ALL)))
    end)

    it("sorts after the pools that do have a headroom", function()
      local a = {
        mana = 10, min_mana = 0, max_mana = 100,
        equilibrium = 300, min_equilibrium = 0, max_equilibrium = false,
      }
      local pools = M.of(a, { UNB, MANA }, KNOWS_ALL)
      assert.are.equal("mana", pools[1].short)
      assert.are.equal("equilibrium", pools[2].short)
    end)
  end)

  describe("reporting", function()
    it("names only the low ones", function()
      local a = { mana = 5, min_mana = 0, max_mana = 100, stamina = 90, min_stamina = 0, max_stamina = 100 }
      local low = M.low(M.of(a, { MANA, STAM }, KNOWS_ALL))
      assert.are.equal(1, #low)
      assert.are.equal("mana", low[1].short)
    end)

    it("describes them compactly, worst first", function()
      local a = { mana = 12, min_mana = 0, max_mana = 100, stamina = 90, min_stamina = 0, max_stamina = 100 }
      assert.are.equal("mana:0.12 stamina:0.90", M.describe(M.of(a, { MANA, STAM }, KNOWS_ALL)))
    end)

    it("describes nothing as an empty string, not an error", function()
      assert.are.equal("", M.describe(nil))
      assert.are.equal("", M.describe({}))
    end)
  end)
end)
