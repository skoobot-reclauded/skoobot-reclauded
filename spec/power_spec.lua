-- luacheck: std luajit+busted

-- data/power.lua is the original SkooBot's threat heuristic, ported as a
-- pure module. These tests pin the port to the original's NUMBERS, worked
-- by hand from SkooBot 0.0.12's superload/mod/class/Actor.lua, so that a
-- later change to the formula (T-020) is a deliberate change to a test and
-- not an accident of porting.
--
-- Two of the original's oddities are part of what is pinned, on purpose:
--   * the crit chance is divided by 100 twice (once by the caller, once in
--     offensePowerLevel), so it contributes far less than it reads as;
--   * `melee` is always computed, even when `ranged` is present, because
--     `not ranged and ... or combatDamage()` falls through to the `or`.
-- Fixing either is T-020's decision, with the tooltip and the stop
-- thresholds re-tuned to match.

local manifest = require "spec.support.manifest"

local function loadPower()
  local chunk = assert(loadfile(manifest.path("src/data/power.lua")))
  return chunk()
end

--- A stand-in for an Actor: the fields and methods power.lua reads.
local function fakeActor(over)
  local a = {
    life = 100, max_life = 200,
    combat_dam = 20, combat_physcrit = 11, combat_critical_power = 50, combat_physspeed = 1,
    combat_spellpower = 30, combat_spellcrit = 6, combat_spellspeed = 1,
    combat_mindpower = 40, combat_mindcrit = 16, combat_mindspeed = 2,
    combat_def = 10, combat_armor = 5,
    inc_stats = { 1, 2, 3 },
    combat = { dam = 7 },
    INVEN_MAINHAND = 1,
    inven = { [1] = {}, QUIVER = nil },
    attrs = {},
  }
  function a:getInven(which) return self.inven[which] end
  function a:attr(name) return self.attrs[name] end
  function a.combatDamage(_, combat, _, ammo)
    if ammo then return 9 end
    return combat and combat.dam or 0
  end
  for k, v in pairs(over or {}) do a[k] = v end
  return a
end

describe("data/power.lua", function()
  local power

  setup(function() power = loadPower() end)

  it("is a pure module exposing scores, level and sum", function()
    assert.is_function(power.scores)
    assert.is_function(power.level)
    assert.is_function(power.sum)
  end)

  describe("scores, worked by hand from SkooBot 0.0.12", function()
    local s

    setup(function() s = power.scores(fakeActor(), 1) end)

    it("survival = life/10 * life/max_life", function()
      assert.is_near(5, s.survivalScore, 1e-9)              -- 100/10 * 100/200
    end)

    it("phys = (dam * (crit/100 * (critpower/100 + 1.5)) + 1) * speed, crit already /100 once", function()
      -- crit chance (11+9)/100 = 0.2, then /100 again = 0.002; 0.002 * 2.0 = 0.004
      assert.is_near(1.08, s.physScore, 1e-9)               -- (20 * 0.004 + 1) * 1
    end)

    it("spell uses a +4 crit offset", function()
      assert.is_near(1.06, s.spellScore, 1e-9)              -- (30 * 0.002 + 1) * 1
    end)

    it("mind is scaled by mind speed", function()
      assert.is_near(2.32, s.mindScore, 1e-9)               -- (40 * 0.004 + 1) * 2
    end)

    it("defense = def/2 + armor", function()
      assert.is_near(10, s.defenseScore, 1e-9)
    end)

    it("stats = the sum of inc_stats", function()
      assert.are.equal(6, s.statScore)
    end)

    it("melee falls through to combatDamage(combat) with no weapon", function()
      assert.are.equal(7, s.attackScores.melee)
      assert.is_nil(s.attackScores.ranged)
    end)
  end)

  it("level is the recursive sum of every score", function()
    assert.is_near(32.46, power.level(fakeActor(), 1), 1e-9)   -- 5 + 1.08 + 1.06 + 2.32 + 10 + 6 + 7
  end)

  it("takes the speed multiplier from the caller, not from the actor", function()
    local fast = power.scores(fakeActor(), 2)
    assert.is_near(2.16, fast.physScore, 1e-9)
    assert.is_near(2.12, fast.spellScore, 1e-9)
    assert.is_near(4.64, fast.mindScore, 1e-9)
    assert.is_near(5, fast.survivalScore, 1e-9)            -- unaffected
  end)

  it("a generic crit chance replaces the per-school one", function()
    local s = power.scores(fakeActor({ combat_generic_crit = 0.5 }), 1)
    -- 0.5 / 100 = 0.005; 0.005 * 2.0 = 0.01; 20 * 0.01 + 1 = 1.2
    assert.is_near(1.2, s.physScore, 1e-9)
  end)

  it("scores a ranged weapon from its ammo, and still computes melee", function()
    local a = fakeActor()
    a.inven[1] = { { archery = "bow", combat = { dam = 3 } } }
    a.inven.QUIVER = { { archery_ammo = "bow", combat = { dam = 4 } } }
    local s = power.scores(a, 1)
    assert.are.equal(9, s.attackScores.ranged)            -- combatDamage(combat, nil, ammo.combat)
    assert.are.equal(7, s.attackScores.melee)             -- the `or` branch, not the weapon's dam
  end)

  it("sum recurses into nested tables", function()
    assert.are.equal(10, power.sum({ 1, { 2, { 3 } }, x = 4 }))
  end)

  -- #62 (salvage-mishander.md item 2): the rank bands are mishander's
  -- `rank < 3` / `rank < 4` cuts over ToME 1.7.6's rank table
  -- (mod/class/Actor.lua textRank / allowedRanks).
  describe("rankBand over ToME 1.7.6's rank table", function()
    local TABLE = {
      { 1,   "critter",    "normal" },
      { 2,   "normal",     "normal" },
      { 3,   "elite",      "elite"  },
      { 3.2, "rare",       "elite"  },
      { 3.5, "unique",     "elite"  },
      { 4,   "boss",       "boss"   },
      { 5,   "elite boss", "boss"   },
      { 10,  "god",        "boss"   },
      { 11,  "godslayer",  "boss"   },
    }
    for _, row in ipairs(TABLE) do
      local rank, name, band = row[1], row[2], row[3]
      it(("rank %s (%s) is band %s"):format(rank, name, band), function()
        assert.are.equal(band, power.rankBand(rank))
      end)
    end

    it("an actor with no rank is normal, the engine's own default", function()
      assert.are.equal("normal", power.rankBand(nil))
    end)

    it("exposes the band names as constants", function()
      assert.are.equal("normal", power.RANK_NORMAL)
      assert.are.equal("elite", power.RANK_ELITE)
      assert.are.equal("boss", power.RANK_BOSS)
    end)
  end)

  describe("rankWeight", function()
    local WEIGHTS = { normal = 0.4, elite = 1.0, boss = 2.0 }   -- mishander's defaults

    it("returns the band's weight for every rank in the table", function()
      assert.are.equal(0.4, power.rankWeight({ rank = 1 },   WEIGHTS))
      assert.are.equal(0.4, power.rankWeight({ rank = 2 },   WEIGHTS))
      assert.are.equal(1.0, power.rankWeight({ rank = 3 },   WEIGHTS))
      assert.are.equal(1.0, power.rankWeight({ rank = 3.2 }, WEIGHTS))
      assert.are.equal(1.0, power.rankWeight({ rank = 3.5 }, WEIGHTS))
      assert.are.equal(2.0, power.rankWeight({ rank = 4 },   WEIGHTS))
      assert.are.equal(2.0, power.rankWeight({ rank = 5 },   WEIGHTS))
      assert.are.equal(2.0, power.rankWeight({ rank = 10 },  WEIGHTS))
      assert.are.equal(2.0, power.rankWeight({ rank = 11 },  WEIGHTS))
    end)

    it("is 1 for a band with no weight, so an unconfigured band changes nothing", function()
      assert.are.equal(1, power.rankWeight({ rank = 2 }, { elite = 1.0, boss = 2.0 }))
      assert.are.equal(1, power.rankWeight({ rank = 4 }, {}))
      assert.are.equal(1, power.rankWeight({ rank = 4 }, nil))
      assert.are.equal(1, power.rankWeight({ rank = 4 }, { boss = "not a number" }))
    end)

    it("treats a rankless actor as normal", function()
      assert.are.equal(0.4, power.rankWeight({}, WEIGHTS))
      assert.are.equal(0.4, power.rankWeight(nil, WEIGHTS))
    end)

    it("does not change scores or level", function()
      assert.is_near(32.46, power.level(fakeActor({ rank = 4 }), 1), 1e-9)
    end)
  end)
end)
