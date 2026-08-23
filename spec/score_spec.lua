-- luacheck: std luajit+busted

-- data/score.lua is the situation scored (#11): the four power knobs and
-- IGNORE_DAMAGE_HEALTH_RATIO as the denominators of five terms, the flags
-- as v1's comparisons, and a posture with reasons. These tests pin each
-- term to its knob, each flag to v1's comparison (the parity the salvage
-- scenario measures in-game), the two figure helpers the tooltip and the
-- checks share, and every posture rule, with fake situations.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/score.lua")))
  return chunk()
end

local KNOBS = {
  MAX_INDIVIDUAL_POWER = 200, MAX_DIFF_POWER = 10, MAX_COMBINED_POWER = 500,
  MAX_ENEMY_COUNT = 12, IGNORE_DAMAGE_HEALTH_RATIO = 0.9,
}

local function knobs(over)
  local k = {}
  for key, v in pairs(KNOBS) do k[key] = v end
  for key, v in pairs(over or {}) do k[key] = v end
  return k
end

local function hostile(power, distance, over)
  local h = { power = power, distance = distance, rank = 2, name = "rat" }
  for k, v in pairs(over or {}) do h[k] = v end
  return h
end

local function situation(over)
  local s = { own = 50, life = 1, air = 1, hostiles = {}, blocks = {}, damaged = false, accepted = {} }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

describe("data/score.lua", function()
  local S

  setup(function() S = load() end)

  describe("the figure helpers", function()
    it("enemyPower is the heuristic times the rank weight, 1 when unweighted", function()
      assert.equals(240, S.enemyPower(120, 2))
      assert.equals(120, S.enemyPower(120, nil))
      assert.equals(48, S.enemyPower(120, "0.4"))
      assert.equals(0, S.enemyPower(nil, 2))
    end)

    it("ownPower is the heuristic scaled by the life fraction", function()
      assert.equals(40, S.ownPower(100, 40, 100))
      assert.equals(100, S.ownPower(100, 100, 100))
      assert.equals(100, S.ownPower(100, 10, 0))      -- no max_life: unscaled
    end)
  end)

  describe("nothing in view", function()
    it("scores zero and fights", function()
      local r = S.evaluate(situation(), knobs())
      assert.equals(0, r.score)
      assert.equals(S.FIGHT, r.posture)
      assert.same({ "nothing in view" }, r.reasons)
      for _, code in ipairs(S.FLAGS) do assert.is_false(r.flags[code], code) end
      assert.equals(0, r.figures.count)
      assert.is_nil(r.figures.strongest)
    end)
  end)

  describe("the terms are each knob's ratio", function()
    it("individual = max / MAX_INDIVIDUAL_POWER", function()
      local r = S.evaluate(situation({ hostiles = { hostile(100, 3) } }), knobs())
      assert.is_near(0.5, r.terms.individual, 1e-9)
    end)

    it("stronger = max / (own + MAX_DIFF_POWER)", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(120, 3) } }), knobs())
      assert.is_near(2, r.terms.stronger, 1e-9)
    end)

    it("crowd = sum / (own + MAX_COMBINED_POWER)", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(100, 3), hostile(175, 4) } }), knobs())
      assert.is_near(0.5, r.terms.crowd, 1e-9)
    end)

    it("count = n / MAX_ENEMY_COUNT", function()
      local r = S.evaluate(situation({ hostiles = { hostile(1, 3), hostile(1, 3), hostile(1, 3) } }), knobs())
      assert.is_near(0.25, r.terms.count, 1e-9)
    end)

    it("unseen = (1 - life) / (1 - IGNORE_DAMAGE_HEALTH_RATIO), only when damaged with nothing in view", function()
      local r = S.evaluate(situation({ life = 0.8, damaged = true }), knobs())
      assert.is_near(2, r.terms.unseen, 1e-9)
      assert.equals(0, S.evaluate(situation({ life = 0.8, damaged = false }), knobs()).terms.unseen)
      assert.equals(0, S.evaluate(situation({ life = 0.8, damaged = true, hostiles = { hostile(1, 1) } }),
        knobs()).terms.unseen)
    end)

    it("the score is the largest term", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(120, 3) } }), knobs())
      assert.is_near(2, r.score, 1e-9)                  -- stronger, over individual 0.6
    end)

    it("a zero knob makes the term infinite over anything and zero over nothing", function()
      local r = S.evaluate(situation({ hostiles = { hostile(1, 3) } }), knobs({ MAX_INDIVIDUAL_POWER = 0 }))
      assert.equals(math.huge, r.terms.individual)
      assert.equals(math.huge, r.score)
      assert.equals(0, S.evaluate(situation(), knobs({ MAX_INDIVIDUAL_POWER = 0 })).terms.individual)
      assert.equals(" -- threat over any limit", S.suffix(r.score))
    end)
  end)

  describe("the flags are v1's comparisons", function()
    local function flag(code, over, k)
      return S.evaluate(situation(over), knobs(k)).flags[code]
    end

    it("BIGENEMY: max > MAX_INDIVIDUAL_POWER, whatever own is", function()
      assert.is_true(flag("SCOUTER_BIGENEMY", { own = 1000, hostiles = { hostile(201, 3) } }))
      assert.is_false(flag("SCOUTER_BIGENEMY", { hostiles = { hostile(200, 3) } }))
    end)

    it("STRONGERENEMY: max > own + MAX_DIFF_POWER", function()
      assert.is_true(flag("SCOUTER_STRONGERENEMY", { own = 50, hostiles = { hostile(61, 3) } }))
      assert.is_false(flag("SCOUTER_STRONGERENEMY", { own = 50, hostiles = { hostile(60, 3) } }))
    end)

    it("CROWDPOWER: sum > own + MAX_COMBINED_POWER", function()
      assert.is_true(flag("SCOUTER_CROWDPOWER", { own = 50, hostiles = { hostile(300, 3), hostile(251, 3) } }))
      assert.is_false(flag("SCOUTER_CROWDPOWER", { own = 50, hostiles = { hostile(300, 3), hostile(250, 3) } }))
    end)

    it("ENEMYCOUNT: count > MAX_ENEMY_COUNT", function()
      local many = {}
      for i = 1, 13 do many[i] = hostile(1, 3) end
      assert.is_true(S.evaluate(situation({ hostiles = many }), knobs()).flags.SCOUTER_ENEMYCOUNT)
      many[13] = nil
      assert.is_false(S.evaluate(situation({ hostiles = many }), knobs()).flags.SCOUTER_ENEMYCOUNT)
    end)

    it("EXPLORE_DAMAGE: damaged, nothing in view, life at or below the ratio", function()
      assert.is_true(S.evaluate(situation({ life = 0.9, damaged = true }), knobs()).flags.EXPLORE_DAMAGE)
      assert.is_false(S.evaluate(situation({ life = 0.91, damaged = true }), knobs()).flags.EXPLORE_DAMAGE)
      assert.is_false(S.evaluate(situation({ life = 0.5, damaged = false }), knobs()).flags.EXPLORE_DAMAGE)
    end)

    it("the details carry v1's wording with the figures compared", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(300, 3), hostile(251, 3) } }), knobs())
      assert.equals("an enemy's power level, 300.0, is above MAX_INDIVIDUAL_POWER", r.details.SCOUTER_BIGENEMY)
      assert.equals("an enemy's power level, 300.0, is more than MAX_DIFF_POWER above yours (50.0 at current life)",
        r.details.SCOUTER_STRONGERENEMY)
      assert.equals("the combined enemy power level, 551.0, is more than MAX_COMBINED_POWER above yours "
        .. "(50.0 at current life)", r.details.SCOUTER_CROWDPOWER)
      assert.is_nil(r.details.SCOUTER_ENEMYCOUNT)
    end)
  end)

  describe("the figures", function()
    it("pick the strongest, the nearer on a tie, and the nearest", function()
      local r = S.evaluate(situation({ hostiles = {
        hostile(10, 5, { name = "far weak" }), hostile(40, 4, { name = "far strong" }),
        hostile(40, 2, { name = "near strong" }), hostile(5, 1, { name = "adjacent weak" }) } }), knobs())
      assert.equals("near strong", r.figures.strongest.name)
      assert.equals("adjacent weak", r.figures.nearest.name)
      assert.equals(40, r.figures.max)
      assert.equals(95, r.figures.sum)
      assert.equals(4, r.figures.count)
    end)
  end)

  describe("the posture", function()
    it("a crowd of weak mobs at range: fight", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(8, 4), hostile(8, 5), hostile(8, 6) } }), knobs())
      assert.equals(S.FIGHT, r.posture)
      assert.equals("3 in view, none over a limit -- threat 0.3", r.reasons[1])
    end)

    it("a boss adjacent at 40% life, not accepted: handback, the reason naming the score", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 1, { name = "boss", rank = 4 }) } }),
        knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.is_true(r.flags.SCOUTER_BIGENEMY)
      assert.is_true(r.flags.SCOUTER_STRONGERENEMY)
      assert.equals("an enemy's power level, 480.0, is above MAX_INDIVIDUAL_POWER -- threat 16.0", r.reasons[1])
      assert.equals("an enemy's power level, 480.0, is more than MAX_DIFF_POWER above yours (20.0 at current life)"
        .. " -- threat 16.0", r.reasons[2])
      assert.is_near(16, r.score, 1e-9)                 -- 480 / (20 + 10)
    end)

    it("the same boss accepted and adjacent: fight, a step away would give it a free hit", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 1, { name = "boss" }) },
        accepted = { SCOUTER_BIGENEMY = true, SCOUTER_STRONGERENEMY = true } }), knobs())
      assert.equals(S.FIGHT, r.posture)
      assert.equals("boss is 16.0x your limit and adjacent: a step away would give it a free hit", r.reasons[1])
    end)

    it("the same boss accepted at distance 3: retreat", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3, { name = "boss" }) },
        accepted = { SCOUTER_BIGENEMY = true, SCOUTER_STRONGERENEMY = true } }), knobs())
      assert.equals(S.RETREAT, r.posture)
      assert.equals("boss is 16.0x your limit at distance 3: step away first", r.reasons[1])
    end)

    it("the same boss accepted at distance 3 after RETREAT_LIMIT steps away: fight, the chase failed", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3, { name = "boss" }) },
        retreats = S.RETREAT_LIMIT,
        accepted = { SCOUTER_BIGENEMY = true, SCOUTER_STRONGERENEMY = true } }), knobs())
      assert.equals(S.FIGHT, r.posture)
      assert.equals("boss is 16.0x your limit at distance 3, and 5 steps away have not shaken it", r.reasons[1])
      r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3, { name = "boss" }) },
        retreats = S.RETREAT_LIMIT - 1,
        accepted = { SCOUTER_BIGENEMY = true, SCOUTER_STRONGERENEMY = true } }), knobs())
      assert.equals(S.RETREAT, r.posture)
    end)

    it("the same boss accepted at distance 3, but pinned: fight", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3, { name = "boss" }) },
        blocks = { move = true },
        accepted = { SCOUTER_BIGENEMY = true, SCOUTER_STRONGERENEMY = true } }), knobs())
      assert.equals(S.FIGHT, r.posture)
      assert.equals("boss is 16.0x your limit, and you cannot move", r.reasons[1])
    end)

    it("one of two single-enemy flags accepted and the other not: still handback", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3, { name = "boss" }) },
        accepted = { SCOUTER_BIGENEMY = true } }), knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.equals(1, #r.reasons)
      assert.truthy(r.reasons[1]:find("MAX_DIFF_POWER", 1, true))
    end)

    it("a crowd over its limit, accepted, nothing adjacent: hold", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(300, 4), hostile(300, 5) },
        accepted = { SCOUTER_CROWDPOWER = true } }), knobs({ MAX_INDIVIDUAL_POWER = 1000, MAX_DIFF_POWER = 1000 }))
      assert.equals(S.HOLD, r.posture)
      assert.is_true(r.flags.SCOUTER_CROWDPOWER)
      assert.equals("the crowd is 1.1x your combined limit: fight what comes into reach, do not walk into it",
        r.reasons[1])
    end)

    it("too many, accepted: hold, by the count", function()
      local many = {}
      for i = 1, 13 do many[i] = hostile(1, 3) end
      local r = S.evaluate(situation({ hostiles = many, accepted = { SCOUTER_ENEMYCOUNT = true } }), knobs())
      assert.equals(S.HOLD, r.posture)
      assert.equals("13 in view, over MAX_ENEMY_COUNT: fight what comes into reach, do not walk into it", r.reasons[1])
    end)

    it("a crowd over its limit, not accepted: handback", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(300, 4), hostile(300, 5) } }),
        knobs({ MAX_INDIVIDUAL_POWER = 1000, MAX_DIFF_POWER = 1000 }))
      assert.equals(S.HANDBACK, r.posture)
      assert.truthy(r.reasons[1]:find("MAX_COMBINED_POWER above yours", 1, true))
      assert.truthy(r.reasons[1]:find(" -- threat 1.1", 1, true))
    end)

    it("a single accepted flag outranks an accepted crowd: retreat, not hold", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3), hostile(300, 5) },
        accepted = { SCOUTER_BIGENEMY = true, SCOUTER_STRONGERENEMY = true, SCOUTER_CROWDPOWER = true } }), knobs())
      assert.equals(S.RETREAT, r.posture)
    end)

    it("cannot act or cannot target: handback before anything else, naming the block when given", function()
      local r = S.evaluate(situation({ hostiles = { hostile(1, 1) }, blocks = { act = true } }), knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.same({ "cannot act" }, r.reasons)
      r = S.evaluate(situation({ hostiles = { hostile(1, 1) }, blocks = { act = "asleep", move = "asleep" } }), knobs())
      assert.same({ "cannot act (asleep)" }, r.reasons)
      r = S.evaluate(situation({ hostiles = { hostile(1, 1) }, blocks = { target = "encased in ice" } }), knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.same({ "cannot target anything (encased in ice)" }, r.reasons)
    end)

    it("no power left with something in view: handback", function()
      local r = S.evaluate(situation({ own = 0, hostiles = { hostile(1, 1) } }), knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.same({ "no power left to compare with" }, r.reasons)
    end)

    it("air nearly gone: handback, with the percentage", function()
      local r = S.evaluate(situation({ air = 0.2, hostiles = { hostile(1, 1) } }), knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.same({ "air is nearly gone (20%)" }, r.reasons)
      assert.equals(S.FIGHT, S.evaluate(situation({ air = 0.25, hostiles = { hostile(1, 1) } }), knobs()).posture)
    end)

    it("damage with nothing in view below the ratio: handback, the explore-damage flag", function()
      local r = S.evaluate(situation({ life = 0.5, damaged = true }), knobs())
      assert.equals(S.HANDBACK, r.posture)
      assert.is_true(r.flags.EXPLORE_DAMAGE)
      assert.equals("took damage while exploring, and life is below IGNORE_DAMAGE_HEALTH_RATIO -- threat 5.0",
        r.reasons[1])
    end)

    it("a scratch with nothing in view above the ratio: fight, and the term says how close", function()
      local r = S.evaluate(situation({ life = 0.95, damaged = true }), knobs())
      assert.equals(S.FIGHT, r.posture)
      assert.is_false(r.flags.EXPLORE_DAMAGE)
      assert.is_near(0.5, r.terms.unseen, 1e-9)
    end)
  end)

  describe("suffix()", function()
    it("renders the score to one decimal", function()
      assert.equals(" -- threat 0.0", S.suffix(0))
      assert.equals(" -- threat 2.3", S.suffix(2.34))
    end)
  end)
end)
