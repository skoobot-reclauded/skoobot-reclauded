-- luacheck: std luajit+busted

-- data/escort.lua: who is being escorted, and where the bot should stand.
--
-- The fixtures are built the way data/quests/escort-duty.lua builds the real
-- thing: escort_quest on the actor, the quest id beside it, and the portal's
-- grid written onto the actor as escort_target. The band is asserted at its
-- edges, because an off-by-one there is the difference between holding
-- position and standing on the grid the escortee's A* wants next.
--
-- #93. The engine reading behind the design is in docs/design-escort.md.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/escort.lua")))
  return chunk()
end

--- The player, reduced to what plan() reads.
local function player(x, y)
  return { x = x or 10, y = y or 10 }
end

--- Remove a field in an override table. `x = nil` cannot: pairs skips it, so
--- the default survives and the case under test never happens.
local NONE = setmetatable({}, { __tostring = function() return "NONE" end })

--- An escortee as the quest leaves it: party faction, a marker, a quest id and
--- the portal on the actor itself.
local function escortee(over)
  local a = {
    name = "Bar, the lost warrior",
    escort_quest = true,
    quest_id = "escort-duty-trollmire-2",
    escort_target = { x = 40, y = 40 },
    x = 10, y = 10,
  }
  for k, v in pairs(over or {}) do
    if v == NONE then a[k] = nil else a[k] = v end
  end
  return a
end

--- Chebyshev, which is what the grid actually walks.
local function dist(ax, ay, bx, by)
  return math.max(math.abs(ax - bx), math.abs(ay - by))
end

describe("data/escort.lua", function()
  local M

  setup(function() M = load() end)

  it("loads and exposes the three plans", function()
    assert.is_table(M)
    assert.are.equal("hold", M.HOLD)
    assert.are.equal("close", M.CLOSE)
    assert.are.equal("done", M.DONE)
  end)

  describe("finding the escortee", function()
    it("picks the actor carrying escort_quest", function()
      local npc = escortee()
      local found = M.escortee({ { name = "rat" }, npc, { name = "wolf" } })
      assert.are.equal(npc, found)
    end)

    it("finds nothing when no actor carries the marker", function()
      assert.is_nil(M.escortee({ { name = "rat" }, { name = "wolf" } }))
    end)

    it("tolerates an empty or missing list", function()
      assert.is_nil(M.escortee({}))
      assert.is_nil(M.escortee(nil))
    end)

    -- The quest removes the actor on death, but the bot can look between the
    -- kill and the removal.
    it("ignores a dead escortee", function()
      assert.is_nil(M.escortee({ escortee{ dead = true } }))
    end)

    -- An actor off the map has no position to walk to.
    it("ignores an escortee with no position", function()
      assert.is_nil(M.escortee({ escortee{ x = NONE, y = NONE } }))
    end)

    it("asks the caller whether the quest is still live, and believes a no", function()
      local asked
      local found = M.escortee({ escortee() }, function(id) asked = id return false end)
      assert.are.equal("escort-duty-trollmire-2", asked)
      assert.is_nil(found)
    end)

    it("keeps the escortee when the quest is live", function()
      local npc = escortee()
      assert.are.equal(npc, M.escortee({ npc }, function() return true end))
    end)
  end)

  describe("the portal", function()
    it("reads the grid the quest wrote onto the actor", function()
      local x, y = M.target(escortee())
      assert.are.equal(40, x)
      assert.are.equal(40, y)
    end)

    it("returns nothing when the quest could not place a portal", function()
      assert.is_nil(M.target(escortee{ escort_target = NONE }))
      assert.is_nil(M.target(escortee{ escort_target = {} }))
      assert.is_nil(M.target(nil))
    end)
  end)

  describe("the plan", function()
    it("is done when there is no escortee left", function()
      assert.are.equal(M.DONE, M.plan(player(), nil, { dist = dist }))
      assert.are.equal(M.DONE, M.plan(player(), escortee{ dead = true }, { dist = dist }))
    end)

    it("is done rather than guessing when it has no distance function", function()
      assert.are.equal(M.DONE, M.plan(player(), escortee(), {}))
    end)

    it("holds inside the band", function()
      local npc = escortee{ x = 13, y = 10 }   -- 3 away: between NEAR and FAR
      assert.are.equal(M.HOLD, M.plan(player(10, 10), npc, { dist = dist }))
    end)

    it("holds at the far edge, and closes one grid past it", function()
      local at = escortee{ x = 10 + M.FOLLOW_FAR, y = 10 }
      assert.are.equal(M.HOLD, M.plan(player(10, 10), at, { dist = dist }))
      local past = escortee{ x = 10 + M.FOLLOW_FAR + 1, y = 10 }
      assert.are.equal(M.CLOSE, M.plan(player(10, 10), past, { dist = dist }))
    end)

    it("holds when standing right beside it", function()
      assert.are.equal(M.HOLD, M.plan(player(10, 10), escortee{ x = 11, y = 10 }, { dist = dist }))
    end)

    -- The case a player-centric hostile scan misses: something is on them and
    -- the bot cannot see it, so the band does not get to decide.
    it("closes on a threatened escortee that is inside the band", function()
      local npc = escortee{ x = 13, y = 10 }
      local plan, why = M.plan(player(10, 10), npc, { dist = dist, threatened = true })
      assert.are.equal(M.CLOSE, plan)
      assert.is_truthy(why:find("something is on"))
    end)

    -- ...but not into a shuffle when it is already beside them: the answer
    -- there is to fight, which is the caller's branch, not this one's.
    it("still holds beside a threatened escortee", function()
      local npc = escortee{ x = 11, y = 10 }
      assert.are.equal(M.HOLD, M.plan(player(10, 10), npc, { dist = dist, threatened = true }))
    end)

    it("says how far away it is, by name", function()
      local _, why = M.plan(player(10, 10), escortee{ x = 20, y = 10 }, { dist = dist })
      assert.is_truthy(why:find("Bar, the lost warrior"))
      assert.is_truthy(why:find("10"))
    end)
  end)

  describe("the hold bound (#129)", function()
    it("exists, and is not so small that the escortee's own idling trips it", function()
      -- mod/ai/escort.lua:64 -- it stops 35% of its own turns on purpose, so a
      -- run of a few holds is ordinary and only a long one means anything.
      assert.is_true(M.HOLD_LIMIT >= 10)
    end)

    it("is finite: holding was unbounded, which cost 4.7x the game time", function()
      assert.is_number(M.HOLD_LIMIT)
      assert.is_true(M.HOLD_LIMIT < math.huge)
    end)
  end)

  describe("the band itself", function()
    it("is ordered, and leaves room to stand", function()
      assert.is_true(M.FOLLOW_NEAR >= 1)
      assert.is_true(M.FOLLOW_FAR > M.FOLLOW_NEAR)
    end)

    -- mod/ai/escort.lua:41 -- the escortee panics about hostiles within 10, so
    -- a bot that only closes past 10 would arrive after the fleeing started.
    it("keeps the bot inside the escortee's own help radius", function()
      assert.is_true(M.FOLLOW_FAR < 10)
    end)
  end)
end)
