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

-- #71: the titles the reasons quote come in with the knobs, from
-- data/cfg.lua in the game. Loaded here rather than copied, so a title
-- renamed there is a title renamed in these expectations.
local TITLES = assert(loadfile(manifest.path("src/data/cfg.lua")))().TITLE

local KNOBS = {
  MAX_INDIVIDUAL_POWER = 200, MAX_DIFF_POWER = 10, MAX_COMBINED_POWER = 500,
  MAX_ENEMY_COUNT = 12, IGNORE_DAMAGE_HEALTH_RATIO = 0.9,
  titles = TITLES,
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

    -- #79: the life scaling is a curve, not a straight line. mishander's
    -- own note and design 5.5: a character at 51% life is worse off than
    -- half-strength, because it has fewer turns of margin, must spend some
    -- of them healing, and cannot take the risk that a crit ends the run.
    it("lifeFactor is 1 at full life, whatever the curve", function()
      assert.equals(1, S.lifeFactor(100, 100))
      assert.equals(1, S.lifeFactor(1, 1))
      -- The property the migration question turned on: nothing a player has
      -- tuned changes until they are hurt, so MAX_DIFF_POWER and
      -- MAX_COMBINED_POWER keep their meaning and their defaults.
      assert.equals(120, S.ownPower(120, 100, 100))
    end)

    it("lifeFactor is 0 at no life, and 1 when there is no maximum to divide by", function()
      assert.equals(0, S.lifeFactor(0, 100))
      assert.equals(1, S.lifeFactor(10, 0))
      assert.equals(1, S.lifeFactor(10, nil))
    end)

    it("lifeFactor never rates a hurt character above its life fraction", function()
      for i = 0, 100 do
        local x = i / 100
        local f = S.lifeFactor(x, 1)
        assert.is_true(f <= x + 1e-12, ("f(%.2f) = %.4f is above the fraction"):format(x, f))
        assert.is_true(f >= 0, ("f(%.2f) is negative"):format(x))
      end
    end)

    it("lifeFactor is monotonic: more life is never worth less", function()
      local prev = -1
      for i = 0, 100 do
        local f = S.lifeFactor(i / 100, 1)
        assert.is_true(f >= prev, ("f is not monotonic at %.2f"):format(i / 100))
        prev = f
      end
    end)

    it("lifeFactor clamps a life outside 0..max", function()
      assert.equals(1, S.lifeFactor(150, 100))     -- overhealed
      assert.equals(0, S.lifeFactor(-20, 100))     -- dying
    end)

    it("the curve interpolates linear to quadratic, and 0.5 is what ships", function()
      assert.equals(0.5, S.LIFE_CURVE)
      -- f(x) = x * (1 - c(1 - x)): at c = 0.5 half life counts for 0.375,
      -- between the linear 0.5 and the quadratic 0.25.
      assert.is_true(math.abs(S.lifeFactor(50, 100) - 0.375) < 1e-9)
      assert.is_true(math.abs(S.lifeFactor(40, 100) - 0.28) < 1e-9)
      assert.is_true(math.abs(S.lifeFactor(25, 100) - 0.15625) < 1e-9)
    end)

    it("ownPower is the heuristic on that curve", function()
      assert.is_true(math.abs(S.ownPower(100, 40, 100) - 28) < 1e-9)
      assert.equals(100, S.ownPower(100, 100, 100))
      assert.equals(100, S.ownPower(100, 10, 0))      -- no max_life: unscaled
      assert.equals(0, S.ownPower(nil, 50, 100))
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
      assert.equals("an enemy's power level, 300, is above 200 (Maximum Enemy Power)", r.details.SCOUTER_BIGENEMY)
      assert.equals("an enemy's power level, 300, is more than 10 above yours, "
        .. "50 at current life (Maximum Enemy Power Above Yours)",
        r.details.SCOUTER_STRONGERENEMY)
      assert.equals("the enemies in view add up to 551, more than 500 above yours, "
        .. "50 at current life (Maximum Combined Enemy Power)", r.details.SCOUTER_CROWDPOWER)
      assert.is_nil(r.details.SCOUTER_ENEMYCOUNT)
    end)

    -- The titles come from the game (data/cfg.lua). Anything calling
    -- evaluate() without them -- a scenario probe, a unit test, a future
    -- caller -- must still get a reason, not an error and not a blank.
    it("names the key itself when the caller passes no titles (#71)", function()
      local bare = knobs()
      bare.titles = nil
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(300, 3) } }), bare)
      assert.equals("an enemy's power level, 300, is above 200 (MAX_INDIVIDUAL_POWER)",
        r.details.SCOUTER_BIGENEMY)
    end)

    -- #84: the owner's playtest read "an enemy's power level, 1080.1, is
    -- more than ...". A power level is a heuristic sum over life, damage,
    -- crits, speed, defence, stats and weapons; its tenth is noise the
    -- player cannot act on, and printing it claims a precision the figure
    -- does not have.
    it("prints power levels whole, rounded to nearest (#84)", function()
      local r = S.evaluate(situation({ own = 50.4, hostiles = { hostile(1080.1, 3) } }), knobs())
      assert.equals("an enemy's power level, 1080, is above 200 (Maximum Enemy Power)", r.details.SCOUTER_BIGENEMY)
      assert.is_truthy(r.details.SCOUTER_STRONGERENEMY
        :find("50 at current life (Maximum Enemy Power Above Yours)", 1, true))

      -- Nearest, not truncated: .6 goes up.
      local up = S.evaluate(situation({ own = 50, hostiles = { hostile(300.6, 3) } }), knobs())
      assert.equals("an enemy's power level, 301, is above 200 (Maximum Enemy Power)", up.details.SCOUTER_BIGENEMY)
    end)

    -- The RATIOS keep their decimal, and must: 1.0 is the limit, so the
    -- tenth is the difference between over and under. Rounding these would
    -- turn "1.4x your limit" into "1x your limit", which reads as at it.
    it("keeps the decimal on the ratios and the threat score (#84)", function()
      local r = S.evaluate(situation({ own = 20, hostiles = { hostile(480, 3) } }), knobs())
      assert.is_truthy(r.suffix:find("threat 16.0", 1, true))
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
      assert.equals("an enemy's power level, 480, is above 200 (Maximum Enemy Power) -- threat 16.0", r.reasons[1])
      assert.equals("an enemy's power level, 480, is more than 10 above yours, 20 at current life"
        .. " (Maximum Enemy Power Above Yours) -- threat 16.0", r.reasons[2])
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
      assert.truthy(r.reasons[1]:find("Maximum Enemy Power Above Yours", 1, true))
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
      assert.equals("13 in view, over your limit of 12 (Maximum Enemy Count): "
        .. "fight what comes into reach, do not walk into it", r.reasons[1])
    end)

    it("a crowd over its limit, not accepted: handback", function()
      local r = S.evaluate(situation({ own = 50, hostiles = { hostile(300, 4), hostile(300, 5) } }),
        knobs({ MAX_INDIVIDUAL_POWER = 1000, MAX_DIFF_POWER = 1000 }))
      assert.equals(S.HANDBACK, r.posture)
      assert.truthy(r.reasons[1]:find("Maximum Combined Enemy Power", 1, true))
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
      assert.equals("took damage while exploring with life below 0.9 of maximum "
        .. "(Ignore Damage Above Life Ratio) -- threat 5.0", r.reasons[1])
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
