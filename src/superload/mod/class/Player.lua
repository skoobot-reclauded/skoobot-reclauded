-- SkooBot: Reclauded -- the one place the product touches the player class.
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
-- Superload surface is a liability, not a feature (T-021): every method
-- wrapped here is a method another addon may also wrap, and a place this
-- addon can break a game it is not otherwise involved in. The original
-- superloaded a great deal of mod.class.Player and mod.class.Actor.
--
-- This wraps exactly ONE method, adds no fields to the class, and does
-- nothing at all unless the bot is switched on. All of the actual logic lives
-- in hooks/load.lua and data/decide.lua, where it can be changed without
-- touching the game's own classes.

local _M = loadPrevious(...)

local old_act = _M.act
function _M:act(...)
    local ret = old_act(self, ...)

    -- Only the player character, and only when asked. rawget avoids creating
    -- a dependency on load order between the hook and this superload.
    local bot = rawget(_G, "skoobot_reclauded")
    if bot and bot.active and game and game.player == self then
        bot.onPlayerAct()
    end

    return ret
end

return _M
