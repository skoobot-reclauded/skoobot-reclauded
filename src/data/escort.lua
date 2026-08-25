-- SkooBot: Reclauded -- escorts: who is being escorted, and where to stand.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- The escortee walks ITSELF to the portal and does not follow the player, so
-- this is a keep-up-and-guard problem, not a lead-the-way one. The engine
-- reading behind that, and the whole design, is in docs/design-escort.md (#93).
--
-- No game globals: distance arrives as a function so the arithmetic can be
-- held to its shape without a running game, as data/power.lua is.

local M = {}

--- What the escort branch should do this step.
M.HOLD, M.CLOSE, M.DONE = "hold", "close", "done"

--- The follow band, in grids. Inside NEAR the bot holds -- standing on the
--- escortee's next grid is how an A* deadlocks. Beyond FAR it closes. FAR sits
--- inside the escortee's own 10-grid "Help!" radius (mod/ai/escort.lua:41), so
--- the bot is already in range of whatever it panics about.
M.FOLLOW_NEAR = 2
M.FOLLOW_FAR  = 4

--- Steps in one escort walk before the branch gives up and says so, the way
--- STATE_SEEK bounds its own walk (#78).
M.STEP_LIMIT = 80

local function isTable(v) return type(v) == "table" end

--- The escortee among `actors`, or nil.
---
--- `escort_quest` is set by the quest on grant (data/quests/escort-duty.lua),
--- and is the only marker that survives; the actor's faction is the player's,
--- so nothing that looks for hostiles will ever find it. `isLive`, when given,
--- is asked whether the actor's quest is still running -- the quest engine
--- stays on the caller's side of the line.
function M.escortee(actors, isLive)
    for _, a in pairs(actors or {}) do
        if isTable(a) and a.escort_quest and a.x and a.y and not a.dead then
            if not isLive or isLive(a.quest_id) then return a end
        end
    end
    return nil
end

--- Where the escortee is headed, or nil: the portal's grid, which the quest
--- writes onto the actor itself as `escort_target`.
function M.target(npc)
    if not isTable(npc) then return nil end
    local t = npc.escort_target
    if not isTable(t) or type(t.x) ~= "number" or type(t.y) ~= "number" then return nil end
    return t.x, t.y
end

--- A name for a message. The quest generates one per escortee, so this is what
--- the player sees in the hand-back.
function M.name(npc)
    if not isTable(npc) then return "someone" end
    local n = npc.name
    if type(n) == "string" and n ~= "" then return n end
    return "someone"
end

--- What to do this step, and why, as (action, reason).
---
--- `opts.dist(ax, ay, bx, by)` is the distance function; `opts.threatened` is
--- true when something hostile is in the ESCORTEE's view rather than the
--- player's -- the case a player-centric hostile scan misses, and the one that
--- gets escortees killed off-screen.
function M.plan(p, npc, opts)
    opts = opts or {}
    if not isTable(npc) or npc.dead or not npc.x or not npc.y then
        return M.DONE, "the escort is over"
    end
    if not isTable(p) or not p.x or not p.y then
        return M.DONE, "no position"
    end
    local dist = opts.dist
    if type(dist) ~= "function" then return M.DONE, "no distance function" end
    local d = dist(p.x, p.y, npc.x, npc.y)
    if type(d) ~= "number" then return M.DONE, "no distance" end

    -- Threat beats the band in both directions: something is on them, so close
    -- whatever the spacing says. Never the other way -- a threatened escortee
    -- the bot is already standing beside wants the bot to fight, not to shuffle.
    if opts.threatened and d > M.FOLLOW_NEAR then
        return M.CLOSE, ("something is on %s"):format(M.name(npc))
    end
    if d > M.FOLLOW_FAR then
        return M.CLOSE, ("%s is %d away"):format(M.name(npc), d)
    end
    return M.HOLD, ("%s is %d away"):format(M.name(npc), d)
end

return M
