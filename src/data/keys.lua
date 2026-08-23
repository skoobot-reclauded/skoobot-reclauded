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
--
-- The second half, collisions() and its two formatters, answers #50: which of
-- this addon's actions share a key with something else. Same discipline --
-- the engine's bind tables come in as plain data and nothing is rebound.

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

-- ---------------------------------------------------------------------------
-- Collisions (#50)
--
-- Every addon's defineAction lands in the one class-level table,
-- KeyBind.binds_def, and the player's remaps in KeyBind.binds_remap; a key
-- handler's own `binds` is rebuilt from those two by KeyBind:bindKeys
-- (engine/KeyBind.lua:127-136): each action is bound to its remap if there
-- is one, else to its default. When two actions land on one key string,
-- KeyBind:receiveKey (:228-233) fires the first one pairs() happens to yield
-- that has a handler, and returns -- the other never sees the key, and
-- nothing says so. These functions find that state from the two tables,
-- passed in as plain data, so the check runs under busted as well as in the
-- game. They only read: the addon never rebinds anything (advisory only).
-- ---------------------------------------------------------------------------

-- What an action is bound to, the way bindKeys() decides it.
local function boundKeys(defs, remap, t)
    local def = defs[t]
    if not def then return {} end
    return remap[t] or def.default or {}
end

--- The addon's actions that share a key string with another action.
-- @param defs   KeyBind.binds_def: type -> { default = {ks, ...}, name = ... }
-- @param remap  KeyBind.binds_remap: type -> {ks, ...}, replacing the default
--               for that type; nil when there are no remaps
-- @param ours   the addon's action types, in the order to report them
-- @return a list, possibly empty, of { type=, keystring=, others={type, ...} }:
--         one entry per (our action, key string) pair that another action is
--         also bound to, others sorted by name. An action with no binding,
--         or one that is not defined at all, collides with nothing.
function M.collisions(defs, remap, ours)
    remap = remap or {}
    local byKey = {}
    for t in pairs(defs) do
        for _, ks in ipairs(boundKeys(defs, remap, t)) do
            byKey[ks] = byKey[ks] or {}
            byKey[ks][t] = true
        end
    end

    local out = {}
    for _, t in ipairs(ours) do
        local seen = {}
        for _, ks in ipairs(boundKeys(defs, remap, t)) do
            if not seen[ks] then
                seen[ks] = true
                local others = {}
                for o in pairs(byKey[ks] or {}) do
                    if o ~= t then others[#others + 1] = o end
                end
                if #others > 0 then
                    table.sort(others)
                    out[#out + 1] = { type = t, keystring = ks, others = others }
                end
            end
        end
    end
    return out
end

--- The menu's status line for `n` collisions: "Keybinds: OK", or
--- "Keybinds: N collision(s) (see log)".
function M.summary(n)
    n = tonumber(n) or 0
    if n <= 0 then return "Keybinds: OK" end
    return ("Keybinds: %d collision%s (see log)"):format(n, n == 1 and "" or "s")
end

--- One collision as the player reads it: the key, then every action bound
--- to it with ours first -- `Shift+F3: "Toggle SkooBot: Reclauded" and
--- "Switch control to character 3"`.
-- @param c       an entry from collisions()
-- @param keyname the key, rendered (describe(), or the engine's formatter)
-- @param nameOf  function(type) -> the action's display name
function M.collisionText(c, keyname, nameOf)
    local names = { '"' .. tostring(nameOf(c.type)) .. '"' }
    for _, o in ipairs(c.others) do names[#names + 1] = '"' .. tostring(nameOf(o)) .. '"' end
    local list
    if #names == 2 then
        list = names[1] .. " and " .. names[2]
    else
        list = table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
    end
    return tostring(keyname) .. ": " .. list
end

return M
