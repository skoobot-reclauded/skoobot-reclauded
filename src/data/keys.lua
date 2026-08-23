-- SkooBot: Reclauded -- a key binding, written the way a player reads it.
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
-- The engine stores a binding as a string, "sym:_F7:false:true:false:false"
-- (engine/KeyBind.lua:146; the order is sym:ctrl:shift:alt:meta). Its own
-- formatter, KeyBind:formatKeyString (:158), renders that as "SF7" -- one
-- letter per modifier and no separator -- which is what the Key Bindings
-- screen shows. A message to the player reads better as "Shift+F7", which is
-- also what this addon's messages said by hand until #57 made them look the
-- binding up instead of repeating the default. This module does the
-- expansion.
--
-- It is pure: the symbol's display name comes from the caller (core.key.symName
-- over engine.KeyBind's constants in the game, a table under busted), so
-- spec/keys_spec.lua covers it without a running game. Mouse and gesture
-- bindings are not expanded; describe() returns nil for them and the caller
-- falls back to the engine's formatter.

local M = {}

-- Shown in this order, the way Windows writes its own shortcuts.
local MODIFIERS = {
    { flag = "ctrl",  label = "Ctrl"  },
    { flag = "alt",   label = "Alt"   },
    { flag = "shift", label = "Shift" },
    { flag = "meta",  label = "Meta"  },
}

--- Expand an engine key string into "Ctrl+Shift+F7" form.
-- @param ks       the binding string, e.g. "sym:_F7:false:true:false:false"
-- @param symname  function(sym) -> the display name of a symbol such as "_F7"
--                 or "64", or nil when it does not know it
-- @return the description, or nil when `ks` is not a keyboard binding
function M.describe(ks, symname)
    if type(ks) ~= "string" then return nil end

    local uni = ks:match("^uni:(.+)$")
    if uni then return uni end

    local sym, ctrl, shift, alt, meta =
        ks:match("^sym:([^:]+):([a-z]+):([a-z]+):([a-z]+):([a-z]+)$")
    if not sym then return nil end

    local name
    if sym:sub(1, 1) == "=" then
        -- a literal name, as the engine's formatter treats it
        name = sym:sub(2)
    else
        name = symname and symname(sym) or nil
        if name == nil or name == "" then
            -- nothing better than the symbol itself: "_F13" reads as "F13"
            name = (sym:gsub("^_", ""))
        end
    end

    local on = { ctrl = ctrl == "true", shift = shift == "true", alt = alt == "true", meta = meta == "true" }
    local parts = {}
    for _, m in ipairs(MODIFIERS) do
        if on[m.flag] then parts[#parts + 1] = m.label end
    end
    parts[#parts + 1] = name
    return table.concat(parts, "+")
end

return M
