-- luacheck: std luajit+busted

-- data/explorestall.lua: the engine-vs-bot spotting disagreement, counted.
--
-- The counts under test are the two halves of one moment: what the engine
-- could see when it aborted a run (the seens map accumulated over the run
-- path) and what is visible from the grid the run stopped on, after
-- runStopped's recompute. A disagreement is wide > 0 with narrow == 0.
--
-- The consecutive rule is the whole point -- a hostile that moves out of view
-- produces one honest disagreement and must never reach the limit. #153, #164.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/explorestall.lua")))
  return chunk()
end

describe("explorestall", function()
  local M
  before_each(function() M = load() end)

  describe("note", function()
    it("counts a disagreement: the engine saw one, the stopping grid sees none", function()
      local st = {}
      assert.equal(1, M.note(st, 1, 0))
      assert.equal(2, M.note(st, 1, 0))
      assert.equal(3, M.note(st, 1, 0))
    end)

    it("counts a disagreement whatever the size of the engine's set", function()
      local st = {}
      assert.equal(1, M.note(st, 7, 0))
    end)

    it("does not count an abort both views agree about", function()
      local st = {}
      assert.equal(0, M.note(st, 2, 2))
      assert.equal(0, M.note(st, 1, 3))
    end)

    it("does not count a run that ended with nothing in view", function()
      local st = {}
      assert.equal(0, M.note(st, 0, 0))
    end)

    it("resets on any abort the views agree about", function()
      local st = {}
      M.note(st, 1, 0)
      M.note(st, 1, 0)
      assert.equal(2, st.n)
      assert.equal(0, M.note(st, 1, 1))
    end)

    it("resets when a hostile the bot CAN see aborts the run", function()
      -- The case that must never reach the limit: the bot sees it too, so the
      -- FIGHT branch takes over and there is no disagreement to act on.
      local st = {}
      M.note(st, 1, 0)
      M.note(st, 1, 0)
      assert.equal(0, M.note(st, 1, 1))
      assert.is_false(M.stalled(st))
    end)

    it("returns zero rather than erroring on nonsense", function()
      assert.equal(0, M.note(nil, 1, 0))
      assert.equal(0, M.note("no", 1, 0))
      local st = {}
      assert.equal(0, M.note(st, nil, nil))
      assert.equal(0, M.note(st, "x", "y"))
    end)
  end)

  describe("stalled", function()
    it("is false below the limit and true at it", function()
      local st = {}
      for _ = 1, M.LIMIT - 1 do M.note(st, 1, 0) end
      assert.is_false(M.stalled(st))
      M.note(st, 1, 0)
      assert.is_true(M.stalled(st))
    end)

    it("stays true once reached, so the branch does not oscillate", function()
      local st = {}
      for _ = 1, M.LIMIT do M.note(st, 1, 0) end
      assert.is_true(M.stalled(st))
      M.note(st, 1, 0)
      assert.is_true(M.stalled(st))
    end)

    it("is false for nonsense", function()
      assert.is_false(M.stalled(nil))
      assert.is_false(M.stalled("no"))
      assert.is_false(M.stalled({}))
    end)
  end)

  it("has no reset, so a restart cannot hand the pair a fresh budget", function()
    -- #140's lesson, applied here: the only thing that starts exploring again
    -- is the disagreement not recurring, which note() already resets on.
    assert.is_nil(M.clear)
    local st = {}
    for _ = 1, M.LIMIT do M.note(st, 1, 0) end
    assert.is_true(M.stalled(st))
  end)

  it("takes three consecutive disagreements, which is the frozen geometry", function()
    -- One disagreement is a hostile that moved. Three in a row from the same
    -- pair of grids is an immovable one, and that is what live-locks (#164).
    local st = {}
    M.note(st, 1, 0)
    M.note(st, 1, 1)   -- it moved into view: honest, and resets
    M.note(st, 1, 0)
    M.note(st, 1, 0)
    assert.is_false(M.stalled(st))
    M.note(st, 1, 0)
    assert.is_true(M.stalled(st))
  end)
end)
