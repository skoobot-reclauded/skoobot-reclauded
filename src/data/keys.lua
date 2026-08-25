-- SkooBot: Reclauded -- a key binding, written the way a player reads it.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- Expands the engine's binding strings into "Shift+F7" for messages (#57), and
-- finds this addon's actions that share a key with another (#50) -- advisory
-- only; nothing here rebinds. Engine mechanics, including the silent
-- first-wins dispatch #50 exists for: docs/api-surface-1.7.6.md, KeyBind.

local M = {}

-- Shown in this order, the way Windows writes its own shortcuts.
local MODIFIERS = {
    { flag = "ctrl",  label = "Ctrl"  },
    { flag = "alt",   label = "Alt"   },
    { flag = "shift", label = "Shift" },
    { flag = "meta",  label = "Meta"  },
}

--- Expand an engine key string into "Ctrl+Shift+F7", or nil when it is not a
--- keyboard binding. `symname` is core.key.symName: sym -> display name, or nil.
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

-- Collisions (#50).

-- What an action is bound to, the way bindKeys() decides it.
local function boundKeys(defs, remap, t)
    local def = defs[t]
    if not def then return {} end
    return remap[t] or def.default or {}
end

--- The addon's actions that share a key string with another: a list of
--- { type, keystring, others }, others sorted by name. `defs` and `remap` are
--- KeyBind.binds_def and .binds_remap; `ours` is our types, in report order.
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

--- The menu's status line for `n` collisions.
function M.summary(n)
    n = tonumber(n) or 0
    if n <= 0 then return "Keybinds: OK" end
    return ("Keybinds: %d collision%s (see log)"):format(n, n == 1 and "" or "s")
end

--- One collision as the player reads it: the key, then every action bound to
--- it with ours first. `nameOf` is type -> display name.
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
