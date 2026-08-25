-- SkooBot: Reclauded -- the situation scored.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- How bad the situation is, and what to do about it short of stopping (#11).
--
-- Each of the player's knobs is the DENOMINATOR of one term, so a term of 1 is
-- exactly that knob's limit and the score is the largest term. The flags are
-- the same comparisons v1 made, so a knob means what it says.
--
-- Distance changes no term, deliberately: a boss at the edge of view is the
-- same boss two turns later with less room, so the stop comes at the edge.
-- Stunned and confused are deliberately not inputs either (design 2.1) -- the
-- model does not know what they cost, so they stay a stop.

local M = {}

M.FIGHT, M.HOLD, M.RETREAT, M.HANDBACK = "fight", "hold", "retreat", "handback"

-- Below this fraction of max_air a fight is lost to the water, not the
-- enemy: the explore branch runs for air at 0.75 and rest hands back at
-- 0.5, so this is the last line, for a fight the other two never saw.
M.LOW_AIR = 0.25

-- How many retreat steps in a row are worth taking from one threat. A step
-- buys a turn only if the enemy is slower or the step breaks its line of
-- sight; against something as fast as the player the chase holds its distance
-- for ever. Five is enough for the first case to show, cheap enough to waste
-- in the second.
M.RETREAT_LIMIT = 5

-- The flags, in the order their reasons are given.
M.FLAGS = { "SCOUTER_BIGENEMY", "SCOUTER_STRONGERENEMY", "SCOUTER_CROWDPOWER", "SCOUTER_ENEMYCOUNT", "EXPLORE_DAMAGE" }

--- A knob's term: value over limit, 1 at the limit. A limit of zero or less
--- is "none allowed": any value is infinitely over it, nothing is nothing.
local function term(value, limit)
    if limit > 0 then return value / limit end
    return value > 0 and math.huge or 0
end

--- A ratio, to one decimal: "1.5x your limit", the threat score. The tenth
--- carries meaning here -- 1.0 IS the limit.
--- Rounds before formatting: `%.1f` resolves an exact .x5 tie in the C
--- library, and glibc gives "0.2" for 0.25 where the MSVC runtime gives "0.3",
--- so the same fight read differently on Linux and Windows. See #30.
local function fmt1(x)
    if x ~= x or x == math.huge or x == -math.huge then return ("%.1f"):format(x) end
    local tenths = x >= 0 and math.floor(x * 10 + 0.5) or -math.floor(-x * 10 + 0.5)
    return ("%.1f"):format(tenths / 10)
end

--- A POWER LEVEL, whole (#84). Only the RENDERING rounds: every comparison
--- stays on the unrounded value, so a stop fires exactly where the knob says
--- it does, which does mean a figure can read equal to a limit it is a
--- fraction over. That is the right way round -- rounding the comparison
--- instead gives a threshold that moves by half a point depending on how it is
--- printed. Power levels are sums of non-negative parts, so nearest is
--- floor(x + 0.5).
local function fmt0(x)
    return ("%d"):format(math.floor((tonumber(x) or 0) + 0.5))
end

--- A block's name in parentheses when the caller gave one (the act loop
--- passes the blocking conditions' words, "asleep"), nothing otherwise.
local function named(block)
    if type(block) == "string" and block ~= "" then return " (" .. block .. ")" end
    return ""
end

--- The figure an enemy counts for: its heuristic power times its rank
--- weight (#62). One place, so the tooltip and the checks agree.
function M.enemyPower(raw, weight)
    return (raw or 0) * (tonumber(weight) or 1)
end

--- How much of the life scaling is quadratic (#79). 0 is the linear form #62
--- shipped, `raw * life/max_life`; 1 makes it `raw * (life/max_life)^2`, so
--- half life counts for a quarter; in between it interpolates.
---
--- 0.5, deliberately mild: the linear form is wrong (design-stop-conditions.md
--- 5.5), but this figure is the denominator of the `stronger` and `crowd`
--- terms, so a steep curve would make the bot markedly more cautious at every
--- wound, under every player, at once.
M.LIFE_CURVE = 0.5

--- The fraction of its power a character at this much life counts for.
---
--- f(x) = x * (1 - LIFE_CURVE * (1 - x)), which is x at LIFE_CURVE 0 and x^2
--- at 1. Three properties the spec asserts: f(1) = 1 EXACTLY whatever the
--- curve, so nothing the player tuned changes until they are hurt -- which is
--- why #79 needed no migration of MAX_DIFF_POWER or MAX_COMBINED_POWER; f(0)
--- = 0 and monotonic between, so more life is never worth less; and f(x) <= x,
--- so the curve only ever makes a hurt character read weaker.
---
--- #91: the arguments are the life POOL and its maximum -- `life - die_at`
--- over `max_life - die_at`, what data/life.lua returns -- not the raw pair.
function M.lifeFactor(pool, max)
    if not (max and max > 0) then return 1 end
    local x = pool / max
    if x < 0 then x = 0 elseif x > 1 then x = 1 end
    return x * (1 - M.LIFE_CURVE * (1 - x))
end

--- The figure the player counts for: the heuristic scaled by the life left
--- (#62), on the curve above (#79). One place, so the tooltip and the
--- checks agree.
function M.ownPower(raw, pool, max)
    return (raw or 0) * M.lifeFactor(pool, max)
end

--- Score a situation.
-- @param input a table:
--   own        the player's power as ownPower gives it
--   life       life fraction, 0-1 -- of the POOL the game kills at,
--              discounted for anything about to lapse (#91)
--   air        air fraction, 0-1 (nil when the character has no air)
--   hostiles   list of { power = weighted, rank = n, distance = n, name = s }
--   blocks     { move = x, act = x, target = x }, or nil: each truthy when
--              blocked, and a string naming what blocks it when known
--   damaged    true when life fell this turn
--   accepted   { SCOUTER_BIGENEMY = true, ... }: the flags the player has
--              told the bot to live with (IGNORE, or an acknowledged WARN)
--   retreats   how many retreat steps in a row the bot has already taken
-- @param knobs the settings: MAX_INDIVIDUAL_POWER, MAX_DIFF_POWER,
--   MAX_COMBINED_POWER, MAX_ENEMY_COUNT, IGNORE_DAMAGE_HEALTH_RATIO
-- @return a table:
--   score     the largest term
--   terms     individual, stronger, crowd, count, unseen
--   flags     the five flags, true or false
--   details   for each set flag, v1's wording of it with the figures
--   figures   own, count, max, sum, strongest, nearest
--   posture   M.FIGHT, M.HOLD, M.RETREAT or M.HANDBACK
--   reasons   strings, in the order they were weighed
--   suffix    the score as a message suffix, " -- threat 2.3"
function M.evaluate(input, knobs)
    local own = input.own or 0
    local blocks = input.blocks or {}
    local hostiles = input.hostiles or {}
    local accepted = input.accepted or {}
    local life = input.life or 1

    -- The figures: max and sum of the weighted powers, the strongest and
    -- the nearest hostile (the nearer one on a tie of power).
    local f = { own = own, count = #hostiles, max = 0, sum = 0, strongest = nil, nearest = nil }
    for _, h in ipairs(hostiles) do
        local pw = h.power or 0
        local d = h.distance or 0
        f.sum = f.sum + pw
        if not f.strongest or pw > f.max or (pw == f.max and d < (f.strongest.distance or 0)) then
            f.max = pw
            f.strongest = h
        end
        if not f.nearest or d < (f.nearest.distance or 0) then f.nearest = h end
    end

    -- The flags: v1's comparisons, unchanged, so a knob means what it says.
    local flags = {
        SCOUTER_BIGENEMY      = f.max > knobs.MAX_INDIVIDUAL_POWER,
        SCOUTER_STRONGERENEMY = f.max > own + knobs.MAX_DIFF_POWER,
        SCOUTER_CROWDPOWER    = f.sum > own + knobs.MAX_COMBINED_POWER,
        SCOUTER_ENEMYCOUNT    = f.count > knobs.MAX_ENEMY_COUNT,
        EXPLORE_DAMAGE        = (input.damaged and #hostiles == 0 and life <= knobs.IGNORE_DAMAGE_HEALTH_RATIO)
                                and true or false,
    }

    -- The terms: each flag's comparison as a ratio.
    local terms = {
        individual = term(f.max, knobs.MAX_INDIVIDUAL_POWER),
        stronger   = term(f.max, own + knobs.MAX_DIFF_POWER),
        crowd      = term(f.sum, own + knobs.MAX_COMBINED_POWER),
        count      = term(f.count, knobs.MAX_ENEMY_COUNT),
        unseen     = 0,
    }
    if input.damaged and #hostiles == 0 then
        terms.unseen = term(1 - life, 1 - knobs.IGNORE_DAMAGE_HEALTH_RATIO)
    end
    local score = 0
    for _, v in pairs(terms) do
        if v > score then score = v end
    end

    -- What the player sees when the bot hands back: the figures it compared,
    -- and the KNOB it compared them against, named as the options tab names it
    -- and with the limit itself, so a reason can be acted on without reading
    -- the docs first (#71). Power levels are whole and the ratios keep their
    -- decimal -- see fmt0 and fmt1.
    local function knob(name)
        local t = knobs.titles
        return (t and t[name]) or name
    end
    local details = {}
    if flags.SCOUTER_BIGENEMY then
        details.SCOUTER_BIGENEMY = "an enemy's power level, " .. fmt0(f.max) .. ", is above "
            .. fmt0(knobs.MAX_INDIVIDUAL_POWER) .. " (" .. knob("MAX_INDIVIDUAL_POWER") .. ")"
    end
    if flags.SCOUTER_STRONGERENEMY then
        details.SCOUTER_STRONGERENEMY = "an enemy's power level, " .. fmt0(f.max)
            .. ", is more than " .. fmt0(knobs.MAX_DIFF_POWER) .. " above yours, " .. fmt0(own)
            .. " at current life (" .. knob("MAX_DIFF_POWER") .. ")"
    end
    if flags.SCOUTER_CROWDPOWER then
        details.SCOUTER_CROWDPOWER = "the enemies in view add up to " .. fmt0(f.sum)
            .. ", more than " .. fmt0(knobs.MAX_COMBINED_POWER) .. " above yours, " .. fmt0(own)
            .. " at current life (" .. knob("MAX_COMBINED_POWER") .. ")"
    end
    if flags.SCOUTER_ENEMYCOUNT then
        details.SCOUTER_ENEMYCOUNT = f.count .. " enemies in sight, more than "
            .. fmt0(knobs.MAX_ENEMY_COUNT) .. " (" .. knob("MAX_ENEMY_COUNT") .. ")"
    end
    if flags.EXPLORE_DAMAGE then
        details.EXPLORE_DAMAGE = "took damage while exploring with life below "
            .. tostring(knobs.IGNORE_DAMAGE_HEALTH_RATIO) .. " of your life pool ("
            .. knob("IGNORE_DAMAGE_HEALTH_RATIO") .. ")"
    end

    -- The posture, and why.
    local reasons = {}
    local function say(fmt, ...) reasons[#reasons + 1] = fmt:format(...) end
    local posture
    local live = {}
    for _, code in ipairs(M.FLAGS) do
        if flags[code] and not accepted[code] then live[#live + 1] = code end
    end
    local single = (flags.SCOUTER_BIGENEMY and accepted.SCOUTER_BIGENEMY)
        or (flags.SCOUTER_STRONGERENEMY and accepted.SCOUTER_STRONGERENEMY)
    local many = (flags.SCOUTER_CROWDPOWER and accepted.SCOUTER_CROWDPOWER)
        or (flags.SCOUTER_ENEMYCOUNT and accepted.SCOUTER_ENEMYCOUNT)
    local adjacent = f.strongest and (f.strongest.distance or 0) <= 1

    if blocks.act then
        posture = M.HANDBACK
        say("cannot act%s", named(blocks.act))
    elseif blocks.target then
        posture = M.HANDBACK
        say("cannot target anything%s", named(blocks.target))
    elseif #hostiles > 0 and own <= 0 then
        posture = M.HANDBACK
        say("no power left to compare with")
    elseif input.air and input.air < M.LOW_AIR then
        posture = M.HANDBACK
        say("air is nearly gone (%d%%)", math.floor(input.air * 100))
    elseif #live > 0 then
        posture = M.HANDBACK
        for _, code in ipairs(live) do say("%s%s", details[code], M.suffix(score)) end
    elseif single then
        local who = f.strongest.name or "an enemy"
        local over = math.max(terms.individual, terms.stronger)
        if adjacent then
            posture = M.FIGHT
            say("%s is %sx your limit and adjacent: a step away would give it a free hit", who, fmt1(over))
        elseif blocks.move then
            posture = M.FIGHT
            say("%s is %sx your limit, and you cannot move", who, fmt1(over))
        elseif (input.retreats or 0) >= M.RETREAT_LIMIT then
            posture = M.FIGHT
            say("%s is %sx your limit at distance %d, and %d steps away have not shaken it", who, fmt1(over),
                f.strongest.distance or 0, input.retreats)
        else
            posture = M.RETREAT
            say("%s is %sx your limit at distance %d: step away first", who, fmt1(over), f.strongest.distance or 0)
        end
    elseif many then
        posture = M.HOLD
        if flags.SCOUTER_CROWDPOWER then
            say("the crowd is %sx your combined limit: fight what comes into reach, do not walk into it",
                fmt1(terms.crowd))
        else
            say("%d in view, over your limit of %s (%s): fight what comes into reach, do not walk into it",
                f.count, fmt0(knobs.MAX_ENEMY_COUNT), knob("MAX_ENEMY_COUNT"))
        end
    else
        posture = M.FIGHT
        if #hostiles == 0 then
            say("nothing in view")
        else
            say("%d in view, none over a limit%s", #hostiles, M.suffix(score))
        end
    end

    return {
        score = score, terms = terms, flags = flags, details = details, figures = f,
        posture = posture, reasons = reasons, suffix = M.suffix(score),
    }
end

--- The score as a message suffix: " -- threat 2.3", or " -- threat over any
--- limit" when a knob of zero made it infinite.
function M.suffix(score)
    if score == math.huge then return " -- threat over any limit" end
    return (" -- threat %s"):format(fmt1(score))
end

return M
