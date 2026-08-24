-- SkooBot: Reclauded -- the situation scored.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ---------------------------------------------------------------------------
--
-- The flat stop list can say warn / stop / ignore per named condition. It
-- cannot say how bad a situation is, or what to do about it short of
-- stopping (#11). This module says both, from the inputs the four
-- power-level conditions compared one at a time:
--
--   * the player's own power, scaled by the life left (#62, item 3) --
--     the life POOL the game kills at, since #91;
--   * each visible hostile's power, weighted by its rank band (#62, item 2),
--     with its rank and its distance;
--   * how many there are;
--   * what the condition list says the player cannot do (move / act /
--     target, data/conditions.lua);
--   * the life and air fractions, and whether damage arrived this turn;
--   * which of the power conditions the player has told the bot to live
--     with -- set to IGNORE, or a WARN already acknowledged.
--
-- The player's four knobs -- MAX_INDIVIDUAL_POWER, MAX_DIFF_POWER,
-- MAX_COMBINED_POWER, MAX_ENEMY_COUNT -- and IGNORE_DAMAGE_HEALTH_RATIO are
-- the parameters, replaced by nothing: each is the denominator of one
-- TERM, so a term of 1 is exactly that knob's limit, 0.5 is half-way to it
-- and 3 is three times over. The design principle (design-stop-conditions.md
-- 5): the list stays the input, the score is the evaluation.
--
--   individual  strongest weighted enemy / MAX_INDIVIDUAL_POWER
--   stronger    strongest weighted enemy / (own + MAX_DIFF_POWER)
--   crowd       weighted sum / (own + MAX_COMBINED_POWER)
--   count       hostiles / MAX_ENEMY_COUNT
--   unseen      (1 - life) / (1 - IGNORE_DAMAGE_HEALTH_RATIO), only when
--               damage arrived with nothing in view: the one threat the
--               explore branch faces, and the T-011 threshold as a term
--
-- The SCORE is the largest term: how far past the worst of the player's
-- limits the situation is, in [0, inf). The FLAGS are the four SCOUTER_*
-- conditions and the explore-damage stop, computed from the same
-- comparisons v1 made so that a knob means exactly what it says; the
-- condition list reads them, and WARN / STOP / IGNORE still decides whether
-- a flag stops the bot. Distance changes no term: a boss at the edge of
-- view is the same boss two turns later with less room, and the stop
-- should come at the edge.
--
-- The POSTURE is the recommendation, with its reasons:
--
--   handback  a flag the player has not accepted is set -- the reason
--             names the figure, the knob and the score -- or the model has
--             nothing to say: the player cannot act or target, has no
--             power left, or is nearly out of air
--   retreat   an accepted single-enemy flag: the enemy is not adjacent yet
--             and the player can move, so step away first -- up to
--             RETREAT_LIMIT steps in a row, after which the chase is not
--             working and the posture is fight
--   hold      an accepted crowd or count flag and no single-enemy one:
--             fight what comes into reach, wait for the rest rather than
--             walk into it
--   fight     nothing is over a limit, or what is over is adjacent and
--             accepted -- a step away from something next to you gives it
--             a free hit
--
-- Stunned and confused are deliberately NOT inputs (design 2.1): the
-- model does not know what they cost, so they stay a stop, not a term.
--
-- Pure: no globals, no ToME API. spec/score_spec.lua pins every term, flag
-- and posture without a running game.

local M = {}

M.FIGHT, M.HOLD, M.RETREAT, M.HANDBACK = "fight", "hold", "retreat", "handback"

-- Below this fraction of max_air a fight is lost to the water, not the
-- enemy: the explore branch runs for air at 0.75 and rest hands back at
-- 0.5, so this is the last line, for a fight the other two never saw.
M.LOW_AIR = 0.25

-- How many retreat steps in a row are worth taking from one threat. A
-- step away buys a turn only if the enemy is slower, or the step breaks
-- its line of sight; against something as fast as the player the chase
-- holds its distance for ever, and every step is a turn not spent
-- fighting. Five is enough for the first case to show and cheap enough
-- to waste in the second.
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
--- carries meaning here -- 1.0 IS the limit, and 1.4 against 0.9 is the
--- difference between over and under.
local function fmt1(x)
    return ("%.1f"):format(x)
end

--- A POWER LEVEL, whole (#84). These are three- and four-figure numbers
--- built from a heuristic over a creature's life, damage, crits, speed,
--- defence, stats and weapons; the tenth of one is noise the player cannot
--- act on and cannot check, and "1080.1" reads as a precision the figure
--- does not have. Owner's call from the 2026-08-23 playtest.
---
--- Only the RENDERING rounds. Every comparison stays on the unrounded value,
--- so a stop still fires exactly where the knob says it does -- which does
--- mean a figure can read equal to a limit it is a fraction over. That is
--- the right way round: the alternative is rounding the comparison, and a
--- threshold that moves by half a point depending on how it is printed.
---
--- Power levels are sums of non-negative parts, so nearest is floor(x + 0.5).
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

--- How much of the life scaling is quadratic (#79). 0 is the linear form
--- #62 shipped, `raw * life/max_life`; 1 makes it `raw * (life/max_life)^2`,
--- so half life counts for a quarter. In between it interpolates.
---
--- 0.5, chosen deliberately mild. mishander's own note and
--- design-stop-conditions.md 5.5 both say the linear form is wrong -- a
--- character at 51% life is worse off than half-strength, because it has
--- fewer turns of margin, must spend some of them healing, and cannot take
--- the risk that a crit ends the run. But this figure is the denominator of
--- the `stronger` and `crowd` terms, so a steep curve would make the bot
--- markedly more cautious at every wound, under every player, at once.
M.LIFE_CURVE = 0.5

--- The fraction of its power a character at this much life counts for.
---
--- f(x) = x * (1 - LIFE_CURVE * (1 - x)), which is x at LIFE_CURVE 0 and
--- x^2 at 1. Properties that matter and are asserted in the spec:
---
---   * f(1) = 1 EXACTLY, whatever the curve. A character at full life
---     counts for its whole power level, so nothing the player has tuned
---     changes until they are hurt -- which is why #79 needed no migration
---     of MAX_DIFF_POWER or MAX_COMBINED_POWER.
---   * f(0) = 0, and f is monotonic in between, so more life is never worth
---     less.
---   * f(x) <= x for x in [0, 1]: the curve only ever makes a hurt
---     character read as weaker, never stronger.
---
--- #91: the two arguments are the life POOL and its maximum -- what
--- data/life.lua returns, `life - die_at` over `max_life - die_at` -- not
--- the raw pair. For a character with no die_at they are the same numbers;
--- for a Lich they are not remotely.
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

    -- What the player sees when the bot hands back. The figures it compared,
    -- and the KNOB it compared them against -- named as the options tab
    -- names it, with the limit itself, so a reason can be acted on without
    -- reading the docs first (#71). It used to say "is above
    -- MAX_INDIVIDUAL_POWER": a setting key, which nothing on screen mapped
    -- to a title, and no number at all.
    --
    -- POWER LEVELS are whole (#84): three- and four-figure heuristic sums
    -- whose tenth is noise. The ratios below -- "1.5x your limit", the
    -- threat score -- keep their decimal, where 1.0 is the limit and the
    -- tenth is the whole point.
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
            .. tostring(knobs.IGNORE_DAMAGE_HEALTH_RATIO) .. " of maximum ("
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
    return (" -- threat %.1f"):format(score)
end

return M
