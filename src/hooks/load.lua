-- SkooBot: Reclauded -- runtime.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- spotHostiles is adapted from the original SkooBot's
-- superload/mod/class/Player.lua, which follows ToME's own resting checks
-- (Nicolas Casalini, GPL-3.0). Kept close to the original deliberately: it
-- uses LOS rather than telepathy, so that having telepathy does not stop the
-- bot resting -- a subtlety that is easy to lose in a rewrite.
--
-- ---------------------------------------------------------------------------
--
-- WALKING SKELETON (T-071). The policy lives in data/decide.lua as a pure
-- function; this file is the part that has to touch the game, and it is kept
-- as small as that requires. See data/decide.lua for what is deliberately
-- absent.

local class = require "engine.class"
local KeyBind = require "engine.KeyBind"

-- The decision policy, loaded from the addon's own data mount. Kept out of
-- this file so it can be unit-tested with no game running (spec/decide_spec).
local decide = dofile("/data-skoobot_reclauded/decide.lua")

-- How many game.turn units one activation may spend before handing back.
-- Turns, never seconds -- see data/decide.lua.
local TURN_BUDGET = 500

local bot = {
    active       = false,
    started_turn = 0,
    actions      = 0,
    last_reason  = nil,
}
_G.skoobot_reclauded = bot

local function say(msg)
    -- game.log for the player, print for te4_log.txt so the harness and any
    -- bug report can both see the same decisions.
    if game and game.log then game.log("#GOLD#[SkooBot] " .. msg) end
    print("[SKOOBOT] " .. msg)
end

--- Hostile actors the player can actually see.
--
-- LOS only, on purpose: telepathy would otherwise reveal something across the
-- level and stop the bot resting forever.
local function spotHostiles(self)
    local seen = {}
    if not self or not self.x then return seen end
    core.fov.calc_circle(
        self.x, self.y, game.level.map.w, game.level.map.h, self.sight or 10,
        function(_, x, y) return game.level.map:opaque(x, y) end,
        function(_, x, y)
            local actor = game.level.map(x, y, game.level.map.ACTOR)
            if actor and self:reactionToward(actor) < 0
               and self:canSee(actor) and game.level.map.seens(x, y) then
                seen[#seen + 1] = actor
            end
        end, nil)
    return seen
end

--- A snapshot of everything the policy is allowed to look at.
local function snapshot(p)
    return {
        turn         = game.turn or 0,
        started_turn = bot.started_turn,
        budget       = TURN_BUDGET,
        life         = p.life,
        max_life     = p.max_life,
        hostiles     = #spotHostiles(p),
        resting      = p.resting and true or false,
        running      = p.running and true or false,
        wilderness   = (game.zone and game.zone.wilderness) and true or false,
        dead         = p.dead and true or false,
        can_explore  = true,   -- only autoExplore() itself really knows
    }
end

function bot.stop(reason)
    if not bot.active then return end
    bot.active = false
    bot.last_reason = reason
    say("stopped after " .. bot.actions .. " action(s): " .. tostring(reason))
end

function bot.start()
    if bot.active then bot.stop("toggled off by the player") return end
    local p = game and game.player
    if not p then return end
    bot.active       = true
    bot.started_turn = game.turn or 0
    bot.actions      = 0
    bot.last_reason  = nil
    say("started at turn " .. bot.started_turn .. ", budget " .. TURN_BUDGET .. " turns")
    bot.step()
end

--- One decision, and the action that follows from it.
--
-- Returns true if the bot acted. Everything is wrapped by the caller: a Lua
-- error in here would otherwise land in the middle of the player's turn.
function bot.step()
    if not bot.active then return false end
    local p = game and game.player
    if not p then bot.stop("no player") return false end

    local action, reason = decide.decide(snapshot(p))

    if action == decide.CONTINUE then
        return false
    elseif action == decide.STOP then
        bot.stop(reason)
        return false
    elseif action == decide.REST then
        bot.actions = bot.actions + 1
        say("resting (" .. reason .. ")")
        p:restInit()
        return true
    elseif action == decide.EXPLORE then
        bot.actions = bot.actions + 1
        say("exploring (" .. reason .. ")")
        -- autoExplore() is the only thing that knows whether anywhere is left
        -- to go; a false return is the level being finished, not a fault.
        if not p:autoExplore() then
            bot.stop("auto-explore found nowhere left to go")
            return false
        end
        return true
    end

    bot.stop("unknown action " .. tostring(action))
    return false
end

-- Called from the Player superload after each of the player's turns. Guarded,
-- because this runs inside the engine's turn processing and an error here
-- would take the game down with it rather than just switching the bot off.
function bot.onPlayerAct()
    if not bot.active then return end
    local ok, err = pcall(bot.step)
    if not ok then
        bot.active = false
        say("stopped by an internal error: " .. tostring(err))
    end
end

class:bindHook("ToME:run", function()
    KeyBind:load("skoobot-reclauded")
    game.key:addBinds {
        TOGGLE_SKOOBOT_RECLAUDED = function() bot.start() end,
        STOP_SKOOBOT_RECLAUDED   = function() bot.stop("stopped by the player") end,
    }
    print("[SKOOBOT] ready; Shift+F3 toggles")
end)
