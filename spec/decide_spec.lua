-- luacheck: std luajit+busted

-- The policy is a pure function of a snapshot, so it can be tested exhaustively
-- with no game running. That is the property worth keeping when T-020 replaces
-- the body of decide() with a scored evaluation: these examples are about what
-- the bot must never do, not about how it decides.
--
-- T-071.

local manifest = require "spec.support.manifest"
local decide = dofile(manifest.path("src/data/decide.lua"))

-- A snapshot of a healthy character standing in a quiet, explorable room.
local function snap(over)
  local s = {
    turn = 100, started_turn = 0, budget = 500,
    life = 100, max_life = 100,
    hostiles = 0,
    resting = false, running = false,
    wilderness = false, dead = false,
    can_explore = true,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

describe("decide", function()

  it("explores when rested, safe and with somewhere to go", function()
    local action = decide.decide(snap())
    assert.are.equal(decide.EXPLORE, action)
  end)

  it("rests when hurt and unthreatened", function()
    local action = decide.decide(snap{ life = 90 })
    assert.are.equal(decide.REST, action)
  end)

  -- Everything below is a reason to give the character back to the human.
  -- The design target is a bot that stops early and often; each of these is a
  -- complaint the original earned by not stopping.
  describe("hands control back", function()

    it("when a hostile is visible", function()
      local action, why = decide.decide(snap{ hostiles = 1 })
      assert.are.equal(decide.STOP, action)
      assert.is_truthy(why:match("hostile"))
    end)

    it("when a hostile is visible even at full health", function()
      assert.are.equal(decide.STOP, decide.decide(snap{ hostiles = 3, life = 100 }))
    end)

    it("when life is below half", function()
      local action, why = decide.decide(snap{ life = 49 })
      assert.are.equal(decide.STOP, action)
      assert.is_truthy(why:match("life"))
    end)

    it("when the character is dead", function()
      assert.are.equal(decide.STOP, decide.decide(snap{ dead = true }))
    end)

    it("on the world map", function()
      assert.are.equal(decide.STOP, decide.decide(snap{ wilderness = true }))
    end)

    it("when there is nothing left to explore", function()
      assert.are.equal(decide.STOP, decide.decide(snap{ can_explore = false }))
    end)

    -- The bound that makes an unattended run finite. Measured in game.turn,
    -- so interference cannot move it.
    it("when the turn budget is spent", function()
      local action, why = decide.decide(snap{ turn = 500, started_turn = 0, budget = 500 })
      assert.are.equal(decide.STOP, action)
      assert.is_truthy(why:match("budget"))
    end)

    it("and not one turn earlier", function()
      assert.are.equal(decide.EXPLORE,
        decide.decide(snap{ turn = 499, started_turn = 0, budget = 500 }))
    end)
  end)

  -- Precedence is the policy. These pin the order rather than the outcomes.
  describe("precedence", function()

    it("puts death before everything", function()
      assert.are.equal(decide.STOP,
        decide.decide(snap{ dead = true, resting = true, hostiles = 5 }))
    end)

    it("lets the engine finish a rest before deciding anything else", function()
      assert.are.equal(decide.CONTINUE, decide.decide(snap{ resting = true, life = 10 }))
    end)

    it("lets the engine finish a run before deciding anything else", function()
      assert.are.equal(decide.CONTINUE, decide.decide(snap{ running = true, hostiles = 2 }))
    end)

    -- A dead character is not "mid-action", whatever the flags say.
    it("does not let a stale resting flag outrank death", function()
      assert.are.equal(decide.STOP, decide.decide(snap{ resting = true, dead = true }))
    end)

    it("stops for a hostile rather than resting", function()
      assert.are.equal(decide.STOP, decide.decide(snap{ life = 60, hostiles = 1 }))
    end)

    it("rests rather than exploring at part health", function()
      assert.are.equal(decide.REST, decide.decide(snap{ life = 99 }))
    end)
  end)

  it("survives a snapshot with no max_life rather than dividing by zero", function()
    assert.has_no.errors(function() decide.decide(snap{ max_life = 0, life = 0 }) end)
  end)
end)
