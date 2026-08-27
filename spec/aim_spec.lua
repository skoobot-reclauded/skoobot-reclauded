-- luacheck: std luajit+busted

-- data/aim.lua: where to put an area talent (#148).
--
-- The weighting is ToME's own (mod/ai/tactical.lua:179), so these fixtures are
-- the shapes that AI produces: a count of foes caught, of allies caught, and
-- of times the character catches itself -- each already zero when the talent's
-- target type cannot hit that kind at all.
--
-- The cases that matter are the ones where the best TARGET and the best AIM
-- POINT differ, because that difference is the whole issue.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/aim.lua")))
  return chunk()
end

--- A counted candidate, as the caller's dummy projection would hand it over.
local function cand(x, y, foes, allies, selfhit)
  return { x = x, y = y, foes = foes or 0, allies = allies or 0, selfhit = selfhit or 0 }
end

describe("data/aim.lua", function()
  local M
  before_each(function() M = load() end)

  describe("candidates", function()
    it("offers each enemy's own grid", function()
      local c = M.candidates({ {x=1,y=1}, {x=5,y=9} })
      assert.equal(2, #c)
      assert.same({x=1,y=1}, c[1])
      assert.same({x=5,y=9}, c[2])
    end)

    it("dedupes, so a repeated grid cannot look like a preference", function()
      assert.equal(1, #M.candidates({ {x=3,y=3}, {x=3,y=3} }))
    end)

    it("skips anything without a position rather than erroring", function()
      local c = M.candidates({ {x=1,y=1}, {}, "no", nil, {x=nil,y=2} })
      assert.equal(1, #c)
    end)

    it("is empty for no enemies, and for nonsense", function()
      assert.same({}, M.candidates({}))
      assert.same({}, M.candidates(nil))
      assert.same({}, M.candidates("no"))
    end)
  end)

  describe("score", function()
    it("is the number of foes caught when nothing else is", function()
      assert.equal(9, M.score(cand(1, 1, 9)))
    end)

    it("charges one per ally", function()
      assert.equal(9 - 2, M.score(cand(1, 1, 9, 2)))
    end)

    it("charges five for catching yourself", function()
      assert.equal(9 - 5, M.score(cand(1, 1, 9, 0, 1)))
    end)

    it("takes the knobs when they are given", function()
      local o = { self_compassion = 1, ally_compassion = 0 }
      assert.equal(9 - 1, M.score(cand(1, 1, 9, 3, 1), o))
    end)

    it("is zero for nonsense rather than erroring", function()
      assert.equal(0, M.score(nil))
      assert.equal(0, M.score("no"))
      assert.equal(0, M.score({}))
    end)
  end)

  describe("best", function()
    it("beams the guy at the end of the hall, not the nearest one", function()
      -- The issue's own example. Aiming at the near enemy catches one; aiming
      -- at the far one lines the corridor up and catches nine. Same talent,
      -- same turn, and the bot used to pick the first because it picked a
      -- TARGET.
      local near, far = cand(2, 2, 1), cand(9, 2, 9)
      local c = M.best({ near, far })
      assert.same(far, c)
    end)

    it("refuses when nothing catches a foe", function()
      assert.is_nil(M.best({ cand(1, 1, 0), cand(2, 2, 0, 3) }))
    end)

    it("refuses a shot that costs more than it gains", function()
      -- One foe and yourself is -4. The engine gates on val > 0 the same way.
      assert.is_nil(M.best({ cand(1, 1, 1, 0, 1) }))
    end)

    it("takes the shot that catches you when the foes justify it", function()
      -- Nine foes and yourself is 4, which beats a clean single. Finite, not
      -- forbidden -- that is the point of a compassion weight.
      local risky = cand(9, 2, 9, 0, 1)
      assert.same(risky, M.best({ cand(1, 1, 1), risky }))
    end)

    it("prefers the clean shot when the scores tie", function()
      -- 3 foes clean, versus 8 foes and yourself: both score 3. The engine
      -- would shuffle; this takes the one that does not hit the character.
      local clean, risky = cand(1, 1, 3), cand(9, 9, 8, 0, 1)
      assert.equal(M.score(clean), M.score(risky))
      assert.same(clean, M.best({ risky, clean }))
    end)

    it("prefers fewer allies when score and self-hits tie", function()
      local clean, messy = cand(1, 1, 4), cand(2, 2, 5, 1)
      assert.equal(M.score(clean), M.score(messy))
      assert.same(clean, M.best({ messy, clean }))
    end)

    it("is stable when everything ties, so the same board gives the same shot", function()
      -- Deliberately NOT the engine's rng.float(0, 0.9) shuffle: a scenario
      -- cannot pin a random choice and a player cannot learn one.
      local a, b = cand(1, 1, 4), cand(2, 2, 4)
      assert.same(a, M.best({ a, b }))
      assert.same(b, M.best({ b, a }))
    end)

    it("returns the score beside the candidate", function()
      local c, s = M.best({ cand(1, 1, 4, 1) })
      assert.equal(3, s)
      assert.equal(4, c.foes)
    end)

    it("is nil for an empty list and for nonsense", function()
      assert.is_nil(M.best({}))
      assert.is_nil(M.best(nil))
      assert.is_nil(M.best("no"))
      assert.is_nil(M.best({ "no", 7 }))
    end)

    it("honours knobs that turn compassion off", function()
      -- ai_state.self_compassion == false means 0 in the engine; the caller
      -- resolves that to a number before it gets here.
      local risky = cand(9, 9, 2, 0, 1)
      assert.is_nil(M.best({ risky }))
      assert.same(risky, M.best({ risky }, { self_compassion = 0 }))
    end)
  end)
end)
