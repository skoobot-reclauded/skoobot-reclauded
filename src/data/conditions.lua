-- SkooBot: Reclauded -- the conditions the bot watches for, as data.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, superload/mod/class/Player.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- ---------------------------------------------------------------------------
--
-- One entry per condition is the single source of truth for its name in the
-- menu, its default policy, how it is detected, where in the act loop it is
-- consulted, what it says when it fires, and what it stops the character
-- doing (#12; docs/design-stop-conditions.md 3.1). v1 kept the list and the
-- detection apart -- a table of labels in one function and an if-chain of
-- `p.stunned == 1` tests in another -- and the two drifted: DEBUFF_ASLEEP
-- rendered as a working toggle while its test was dead code, and nothing
-- could notice. Here the act loop walks this list; an entry with no
-- detector cannot fire, and a detector with no entry cannot exist.
--
-- Two kinds of entry share the list, told apart by `default`:
--
--   * POLICY entries have a default of WARN, STOP or IGNORE. They are what
--     the player sees in "Activate/Deactivate Bot Stop Conditions" and what
--     the save keeps (code and chosen stoptype only; everything else is
--     read from here on every access). Their order IS the menu's order and
--     the saved list's order, and their codes and labels are the save's --
--     rename nothing. They are the model-validity boundary of the design's
--     2: "my risk model is not meaningful here, the player's is".
--   * LIVENESS entries have no default and no policy. The player cannot
--     configure them, because they are not policy: attempting to path while
--     unable to move is a bug, not a risk appetite (design 1.1). They exist
--     so that the capability they take away is declared once, with its
--     detector, and consulted by the act loop through capabilities().
--
-- Detection is by CAPABILITY, never by effect name: `attr("never_move")` is
-- the one predicate ToME's own move() gates on and covers sixteen effects
-- plus encumbrance, where an effect list could never be complete. The
-- status attributes are additive counters (two sources of stun make 2;
-- confused is a 0-50 percentage), so every test is on truthiness or > 0,
-- never `== 1` -- v1's `== 1` read a doubly stunned or a 30%-confused
-- character as unafflicted (docs/api-surface-1.7.6.md, value-domain notes).
--
-- `blocks` says what a detected condition takes away -- move, act, target --
-- and the act loop's response is defined by the union over everything that
-- is detected: in EXPLORE a move-blocked character hands back rather than
-- calling auto-explore (the T-012 freeze); in FIGHT it still fires the
-- talents that reach (a pinned character can attack), and hands back only
-- when none does, saying why. The policy and the block are two consumers of
-- one signal: DEBUFF_DAZED at IGNORE still cannot path, because dazed sets
-- never_move and the loop consults the block whatever the policy says.
--
-- Pure: no globals, no ToME API beyond the actor methods a detector calls,
-- and everything else about the situation arrives in `ctx` from the act
-- loop (see detect below), so spec/conditions_spec.lua covers every
-- predicate, message and the reconciliation without a running game.

local M = {}

M.WARN, M.STOP, M.IGNORE = "WARN", "STOP", "IGNORE"
M.STOPTYPES = { WARN = true, STOP = true, IGNORE = true }

-- Where an entry is consulted. An entry fires only at its site, so a
-- terrain condition is never checked mid-fight and the explore checks keep
-- the order they had.
M.SITE_TURN    = "turn"      -- every decision, before the state branches
M.SITE_EXPLORE = "explore"   -- the EXPLORE branch, after the air checks
M.SITE_LOOP    = "loop"      -- the per-turn survival initialiser (life delta)
M.SITE_DIALOG  = "dialog"    -- the open-dialog check; no detector, see the entry

-- #77: how many whole turns the character has to have missed before it is
-- worth saying so. One: losing a turn to a stun is the thing being reported.
-- Counted in the character's OWN turns -- the act wrapper normalises for
-- global_speed, so a slowed character is not permanently blacked out.
M.BLACKOUT_TURNS = 1

-- The severities a policy entry may stop with: the values of data/notice.lua.
-- Unset means STOPPED (the player must look).
M.HANDED_BACK = "handed_back"

-- What a detector is given besides the actor, filled in by the act loop:
--   ctx.hostiles     how many hostiles are in view
--   ctx.score        the situation scored (data/score.lua, #11): the four
--                    power conditions read their flag from it and word
--                    their message from its details and its suffix
--   ctx.cfg          function(key) -> the setting's value
--   ctx.chestInView  function(p) -> is an unopened glowing chest in view
--   ctx.delta        life change this turn (SITE_LOOP only)
--   ctx.turnsLost    whole turns the character never got (#77)

--- A status attribute as the counter it is: 0 when absent.
local function counter(p, name)
    local v = p:attr(name)
    return type(v) == "number" and v or 0
end

--- A power condition: a STOP policy entry whose detector and message are
--- both read off the score. The flag is v1's comparison, made there, and
--- the message is v1's wording of it with the threat score appended.
local function scored(code, label)
    return {
        code = code, label = label, default = "STOP",
        category = "power", site = M.SITE_TURN, blocks = {},
        detect  = function(_, ctx) return ctx.score.flags[code] and true or false end,
        message = function(_, ctx) return ctx.score.details[code] .. ctx.score.suffix end,
    }
end

M.LIST = {
    -- Debuffs. The five of v1, in its order. Stunned and confused take no
    -- capability away in 1.7.6 -- a stunned character acts and moves, at
    -- half damage and half speed with three talents on cooldown; a confused
    -- one has a percentage chance to act randomly -- so they block nothing
    -- here: they are the model-validity boundary, a stop because the threat
    -- estimate cannot be trusted while they hold (design 2.1). Not demoted
    -- to score inputs (the body's retraction).
    { code = "DEBUFF_STUNNED", label = "Debuff: STUNNED", default = "WARN",
      category = "debuff", site = M.SITE_TURN, blocks = {},
      detect = function(p) return counter(p, "stunned") > 0 end,
      message = function(p)
          local n = counter(p, "stunned")
          return "you are stunned" .. (n > 1 and (" (x" .. n .. ")") or "")
      end },
    { code = "DEBUFF_CONFUSED", label = "Debuff: CONFUSED", default = "WARN",
      category = "debuff", site = M.SITE_TURN, blocks = {},
      -- The value is the chance, 0-50, that a move or a talent goes astray
      -- and loses the turn (Actor.lua:1395, :5953). v1 tested `== 1`, so
      -- the stop fired only at exactly 1%.
      detect = function(p) return counter(p, "confused") > 0 end,
      message = function(p)
          return ("you are confused (%d%% chance to act randomly)"):format(counter(p, "confused"))
      end },
    -- Dazed sets never_move (physical.lua:568) and halves power and
    -- defence; any damage ends it. Frozen is two effects: FROZEN (encased,
    -- never_move, no healing, talents only reach the ice) and FROZEN_FEET
    -- (a pin). Both set `frozen` and never_move; only the first encases,
    -- which the ENCASED liveness entry below reads separately.
    { code = "DEBUFF_DAZED", label = "Debuff: DAZED", default = "WARN",
      category = "debuff", site = M.SITE_TURN, blocks = { move = true }, blocked = "dazed",
      detect = function(p) return counter(p, "dazed") > 0 end,
      message = "you are dazed" },
    { code = "DEBUFF_FROZEN", label = "Debuff: FROZEN", default = "WARN",
      category = "debuff", site = M.SITE_TURN, blocks = { move = true }, blocked = "frozen",
      detect = function(p) return counter(p, "frozen") > 0 end,
      message = "you are frozen" },
    -- ToME's own gate, Actor.lua:1402/4448/5800: asleep the character can
    -- neither move nor use a talent that costs a turn, but still receives
    -- turns -- so a bot that kept going would spin, and the block is what
    -- stops it trying. v1 wrote `not p.lucid_dreamer == 1`, always false,
    -- so the stop never fired (T-012). A Solipsist with Lucid Dreamer up is
    -- not asleep by this test at all; one who wants sleep left alone sets
    -- the condition to IGNORE.
    { code = "DEBUFF_ASLEEP", label = "Debuff: ASLEEP", default = "WARN",
      category = "debuff", site = M.SITE_TURN, blocks = { move = true, act = true }, blocked = "asleep",
      detect = function(p) return (p:attr("sleep") and not p:attr("lucid_dreamer")) and true or false end,
      message = "you are asleep" },

    -- #77: the turns that went by while the character could not act at all
    -- -- paralysis, stoning, a time stun. Not a state the bot can observe
    -- while it lasts: the engine gives the player no turn, so nothing runs
    -- and there is nothing to detect. What is observable is the gap
    -- afterwards, on the first turn it gets back, and a player who looks up
    -- to find the fight has moved on wants to be told why.
    --
    -- ctx.turnsLost is WHOLE TURNS the character never got, counted by the
    -- act wrapper against the engine's clock and normalised for the
    -- character's own speed. It is deliberately not a game.turn figure: the
    -- first build read one off the BOT's decision clock, which does not move
    -- during a rest or an auto-explore run, and so announced a blackout
    -- after every single rest.
    --
    -- WARN by default -- it is news, not danger, and the thing that caused
    -- it is over by the time this fires.
    { code = "TURNS_BLACKOUT", label = "Turns: BLACKOUT", default = "WARN",
      category = "turns", site = M.SITE_TURN, blocks = {}, severity = M.HANDED_BACK,
      detect = function(_, ctx) return (ctx.turnsLost or 0) >= M.BLACKOUT_TURNS end,
      message = function(_, ctx)
          local turns = ctx.turnsLost or 0
          return ("lost %d turn%s while unable to act"):format(turns, turns == 1 and "" or "s")
      end },

    -- Life. BIGLOSS is read where the life delta is computed, once per real
    -- turn; LOWLIFE only while something hostile is in view, as v1 had it.
    { code = "LIFE_BIGLOSS", label = "Life: BIGLOSS", default = "WARN",
      category = "life", site = M.SITE_LOOP, blocks = {},
      detect = function(p, ctx)
          return ctx.delta < 0 and math.abs(ctx.delta) / p.max_life >= ctx.cfg("LOWHEALTH_RATIO") / 2
      end,
      message = function(_, ctx)
          return "lost more than " .. math.floor(100 * ctx.cfg("LOWHEALTH_RATIO") / 2)
              .. "% of max life in one turn (half of LOWHEALTH_RATIO)"
      end },
    { code = "LIFE_LOWLIFE", label = "Life: LOWLIFE", default = "STOP",
      category = "life", site = M.SITE_TURN, blocks = {},
      detect = function(p, ctx)
          return ctx.hostiles > 0 and p.life < p.max_life * ctx.cfg("LOWHEALTH_RATIO")
      end,
      message = "life is below LOWHEALTH_RATIO" },

    -- A lore popup is not a state of the character: the act loop reads the
    -- dialog stack itself and consults this entry's policy by code (IGNORE
    -- closes the popup and carries on). No detector, on purpose.
    { code = "DIALOG_LORE", label = "Dialog: LORE", default = "IGNORE",
      category = "dialog", site = M.SITE_DIALOG, blocks = {} },

    -- Hands back (not a stop) while exploring, once per chest: the player
    -- decides whether to open it, since they can be guarded (T-013). Walking
    -- TO the chest is #11's, deliberately not here.
    { code = "TERRAIN_GLOWING_CHEST", label = "Terrain: Glowing Chest", default = "WARN",
      category = "terrain", site = M.SITE_EXPLORE, blocks = {}, severity = M.HANDED_BACK,
      detect = function(p, ctx) return ctx.chestInView(p) and true or false end,
      message = "a glowing chest is nearby -- open it yourself, they can be guarded" },

    -- Power level: the four thresholds of v1, read off the situation score
    -- (#11). The score makes v1's comparisons over the rank-weighted enemy
    -- figures (#62) and the player's life-scaled own power, and carries
    -- the figures in its wording -- which is what the salvage scenario
    -- reads back -- with the threat score appended. The policy here still
    -- decides whether a flag stops the bot; the posture the score
    -- recommends is what the fight branch does when it does not.
    --
    -- SCOUTER_CROWDPOWER, #62 (salvage-mishander.md item 4): the crowd
    -- threshold is relative to the character, not a constant. v1 compared
    -- the sum with MAX_COMBINED_POWER alone, so the same crowd stopped a
    -- level-30 and a level-3 character alike; now the sum has to exceed
    -- the character's own (life-scaled) power by that much. The default
    -- stays 500, so the setting's meaning changed under it: it is the
    -- margin above yours.
    scored("SCOUTER_ENEMYCOUNT",    "Power Level: ENEMYCOUNT"),
    scored("SCOUTER_BIGENEMY",      "Power Level: BIGENEMY"),
    scored("SCOUTER_STRONGERENEMY", "Power Level: STRONGERENEMY"),
    scored("SCOUTER_CROWDPOWER",    "Power Level: CROWDPOWER"),

    -- Liveness: no default, so never in the menu or the save. `generic`
    -- marks the catch-all whose name is used only when no named condition
    -- explains the block, so a dazed character is told "dazed", not
    -- "pinned, held, or overloaded" as well.
    { code = "CANNOT_MOVE", label = "Immobilised",
      category = "liveness", site = M.SITE_TURN, blocks = { move = true },
      blocked = "pinned, held, or overloaded", generic = true,
      detect = function(p) return p:attr("never_move") and true or false end },
    { code = "ENCASED", label = "Encased",
      category = "liveness", site = M.SITE_TURN, blocks = { move = true, target = true },
      blocked = "encased in ice",
      detect = function(p) return (p:attr("encased_in_ice") or p:attr("encased")) and true or false end },
}

local byCode = {}
for _, def in ipairs(M.LIST) do byCode[def.code] = def end

--- The definition for a code, or nil.
function M.find(code)
    return byCode[code]
end

--- The policy entries, in menu order: those with a default.
function M.policy()
    local out = {}
    for _, def in ipairs(M.LIST) do
        if def.default then out[#out + 1] = def end
    end
    return out
end

--- An entry's message when it has fired, as plain prose.
function M.message(def, p, ctx)
    if type(def.message) == "function" then return def.message(p, ctx) end
    return def.message or def.label
end

-------------------------------------------------------------------------------
-- Capabilities
-------------------------------------------------------------------------------

--- What the character cannot do right now, from every detected entry that
--- declares a block, policy or not. Returns a table with, for each of move,
--- act and target, either nil or the list of entries blocking it, plus
--- `any` (true when anything is blocked). Cheap: the detectors are attr
--- reads.
function M.capabilities(p, ctx)
    local caps = { any = false }
    for _, def in ipairs(M.LIST) do
        if def.blocks and next(def.blocks) and def.detect and def.detect(p, ctx) then
            for what in pairs(def.blocks) do
                caps[what] = caps[what] or {}
                caps[what][#caps[what] + 1] = def
                caps.any = true
            end
        end
    end
    return caps
end

--- The blockers of one capability, named for a message: "dazed",
--- "asleep, encased in ice", or the generic entry's words when no named
--- condition explains it -- "pinned, held, or overloaded".
function M.blockedText(defs)
    local names, generic = {}, nil
    for _, def in ipairs(defs or {}) do
        if def.generic then
            generic = def.blocked
        elseif def.blocked then
            names[#names + 1] = def.blocked
        end
    end
    if #names == 0 then return generic or "blocked" end
    return table.concat(names, ", ")
end

-------------------------------------------------------------------------------
-- Reconcile on access (T-019 / #52, design 3.2)
-------------------------------------------------------------------------------

--- True when a saved list is exactly the policy entries, in order, with
--- their current labels.
function M.isCurrent(list)
    local policy = M.policy()
    if #list ~= #policy then return false end
    for i, def in ipairs(policy) do
        local v = list[i]
        if type(v) ~= "table" or v.code ~= def.code or v.label ~= def.label then return false end
    end
    return true
end

--- Bring a saved list into step with the policy entries, IN PLACE, so that
--- anything already holding the table sees the result: the same codes in
--- the same order with fresh labels, the player's WARN/STOP/IGNORE kept
--- wherever its code survives, a missing code added at its default, a
--- retired code dropped, and anything malformed (a non-table entry, an
--- unknown stoptype) treated as unset. Idempotent and unversioned, so a
--- hand-edited save repairs itself. Returns true when the list changed.
function M.reconcile(list)
    if M.isCurrent(list) then return false end
    local chosen = {}
    for _, v in ipairs(list) do
        if type(v) == "table" and v.code and M.STOPTYPES[v.stoptype] then
            chosen[v.code] = v.stoptype
        end
    end
    for i = #list, 1, -1 do list[i] = nil end
    for i, def in ipairs(M.policy()) do
        list[i] = { label = def.label, code = def.code, stoptype = chosen[def.code] or def.default }
    end
    return true
end

return M
