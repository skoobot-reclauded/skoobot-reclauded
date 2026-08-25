-- luacheck: std luajit+busted

-- data/power.lua is the original SkooBot's threat heuristic, ported as a
-- pure module. These tests pin the port to worked-by-hand NUMBERS so that a
-- change to the formula is a deliberate change to a test and not an accident.
--
-- THE OFFENCE NUMBERS ARE NO LONGER v1's, and that was the point of #115.
-- v1's crit arithmetic was wrong twice over -- the caller had already turned
-- the percentage into a fraction and offensePowerLevel divided by 100 again,
-- and it multiplied BY the crit term instead of weighting with it -- which
-- pinned physScore, spellScore and mindScore at ~1.0 whatever the actor's
-- power stats. A power level was life, defence, stats and weapon damage.
-- v1 also wrote `combat_generic_crit or <school>`, and 0 is truthy in Lua, so
-- an actor carrying that field scored no crit at all.
--
-- The fixture's level went 32.46 -> 185 as a result. The four MAX_* defaults
-- did NOT move with it (maintainer, 2026-08-24: ship as-is), so they are v1's
-- numbers against a corrected formula until #101 measures new ones.
--
-- One of the original's oddities is still pinned on purpose: `melee` is always
-- computed, even when `ranged` is present, because `not ranged and ... or
-- combatDamage()` falls through to the `or`. Fixing that is #100's call.

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

    it("phys = (dam * (1 + crit * (critmult - 1)) + 1) * speed", function()
      -- crit (11+9)/100 = 0.20; critmult 50/100 + 1.5 = 2.0; 20 * (1 + 0.20) = 24
      assert.is_near(25, s.physScore, 1e-9)                 -- (24 + 1) * 1
    end)

    it("spell uses a +4 crit offset", function()
      assert.is_near(34, s.spellScore, 1e-9)                -- crit (6+4)/100 = 0.10; (30 * 1.10 + 1) * 1
    end)

    it("mind is scaled by mind speed", function()
      assert.is_near(98, s.mindScore, 1e-9)                 -- crit 0.20; (40 * 1.20 + 1) * 2
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
    assert.is_near(185, power.level(fakeActor(), 1), 1e-9)     -- 5 + 25 + 34 + 98 + 10 + 6 + 7
  end)

  it("takes the speed multiplier from the caller, not from the actor", function()
    local fast = power.scores(fakeActor(), 2)
    assert.is_near(50, fast.physScore, 1e-9)               -- (24 + 1) * 2
    assert.is_near(68, fast.spellScore, 1e-9)              -- (33 + 1) * 2
    assert.is_near(196, fast.mindScore, 1e-9)              -- (48 + 1) * 2 * 2
    assert.is_near(5, fast.survivalScore, 1e-9)            -- unaffected
  end)

  -- #115: ADDS to the per-school chance, as ToME does (Combat.lua:1454), where
  -- v1 wrote `generic or school` and 0 is truthy in Lua -- so an actor carrying
  -- the field at all scored a crit chance of exactly zero.
  it("a generic crit chance adds to the per-school one", function()
    local s = power.scores(fakeActor({ combat_generic_crit = 10 }), 1)
    -- crit (11 + 10 + 9)/100 = 0.30; 20 * (1 + 0.30) = 26
    assert.is_near(27, s.physScore, 1e-9)
  end)

  it("a generic crit of zero does not wipe the per-school one", function()
    local s = power.scores(fakeActor({ combat_generic_crit = 0 }), 1)
    assert.is_near(25, s.physScore, 1e-9)                  -- unchanged from the fixture
  end)

  -- The whole point of #115: offence must move the figure. On v1's arithmetic
  -- these two differed by 4.6%.
  it("offence responds to the actor's power stats", function()
    local base = power.level(fakeActor(), 1)
    local hard = power.level(fakeActor({ combat_mindpower = 400 }), 1)
    assert.is_true(hard > base * 3)
  end)

  it("a character with no crit at all is still worth its damage", function()
    local s = power.scores(fakeActor({ combat_physcrit = -9, combat_critical_power = 0 }), 1)
    assert.is_near(21, s.physScore, 1e-9)                  -- crit 0; (20 * 1 + 1) * 1
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
      assert.is_near(185, power.level(fakeActor({ rank = 4 }), 1), 1e-9)
    end)
  end)
end)
