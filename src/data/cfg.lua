-- SkooBot: Reclauded -- the settings: how they are stored, and what they
-- are called where the player meets them (#90, #71).
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
-- One option, one file under the engine's settings directory, holding Lua
-- the engine runs at startup. That is ToME's own mechanism (Game:saveSettings
-- writes /settings/<file>.cfg) and v1 used it under `tome.SkooBot`.
--
-- THE TRAP, and why this module exists (#90). The engine runs every one of
-- those files LONG BEFORE any addon is loaded -- the config is read to decide
-- what to load. So a file saying
--
--     tome.skoobot_reclauded.MAX_ENEMY_COUNT = 77
--
-- indexes a field that does not exist yet, dies, and is swallowed; the addon
-- then seeds its defaults over nothing and the player's choice is gone. It
-- looked like it worked, because the file on disk is correct and the live
-- table is correct for the rest of that session -- the loss is only visible
-- across a restart, which nothing tested. Every setting the owner chose in
-- every playtest before this was silently the default.
--
-- Two halves to the repair, and this module is the shared half:
--
--   * `line()` writes a form that creates the table first, so the engine's
--     own startup load works from now on;
--   * `parse()` reads a value back out of a file's text, so values written
--     by an older build -- which are all of them -- are recovered rather
--     than lost. data/settings.lua does that before it seeds any default.
--
-- Pure: no engine, no filesystem, no globals. The file IO is the caller's,
-- which is what lets busted hold this to its shape.

local M = {}

M.NAMESPACE = "tome.skoobot_reclauded"

--- Where one option's file lives, as the engine's virtual filesystem sees it.
function M.path(name)
    return "/settings/" .. M.NAMESPACE .. "." .. name .. ".cfg"
end

--- The name Game:saveSettings wants: the path without "/settings/" or ".cfg".
function M.file(name)
    return M.NAMESPACE .. "." .. name
end

--- The contents to write for one option.
---
--- Two lines, and the first is the whole point: `= x or {}` creates the
--- namespace table if the engine has not got round to the addon yet, which
--- at config-load time it never has. Without it the second line is a nil
--- index and the value is lost on the next start.
---
--- Numbers and booleans only, which is every setting this addon has. A
--- string would need quoting and there is no reason to invent that here;
--- anything else is refused rather than written badly (LOG_LEVEL is a
--- number for exactly this reason).
function M.line(name, value)
    local t = type(value)
    if t ~= "number" and t ~= "boolean" then
        return nil, "settings may only hold numbers and booleans, not " .. t
    end
    return ("%s = %s or {}\n%s.%s = %s\n"):format(
        M.NAMESPACE, M.NAMESPACE, M.NAMESPACE, name, tostring(value))
end

--- The value one option's file sets, or nil if the text does not set it.
---
--- Reads the assignment rather than executing the file: the caller is the
--- game, the file is on the player's disk, and running it would be running
--- whatever is in it. Numbers and booleans only, matching `line()`.
---
--- Tolerates what real files contain: the guarded two-line form and the old
--- one-line form; a UTF-8 BOM (the engine writes none, but anything that has
--- edited the file might); CRLF; and whitespace anywhere reasonable. The
--- pattern is anchored on the option's own name, so the guard line -- which
--- assigns the NAMESPACE and not a name under it -- cannot be mistaken for
--- a value.
function M.parse(text, name)
    if type(text) ~= "string" or type(name) ~= "string" or name == "" then return nil end
    local ns  = M.NAMESPACE:gsub("%.", "%%.")
    local key = name:gsub("(%W)", "%%%1")
    local raw = text:match(ns .. "%." .. key .. "%s*=%s*([^\r\n]*)")
    if not raw then return nil end
    raw = raw:gsub("%s+$", "")
    if raw == "true"  then return true  end
    if raw == "false" then return false end
    return tonumber(raw)
end


--- What each setting is CALLED where the player meets it (#71).
---
--- The options tab titles them; the stop reasons used to name the setting
--- key instead -- "life is below LOWHEALTH_RATIO" -- and nothing on screen
--- mapped one to the other. A player reading a stop had no way to find the
--- knob it was talking about.
---
--- One table, read by the tab that draws the titles and by the reasons that
--- quote them, so the two cannot drift into naming the same knob differently.
M.TITLE = {
    LOWHEALTH_RATIO            = "Low Health Ratio",
    IGNORE_DAMAGE_HEALTH_RATIO = "Ignore Damage Above Life Ratio",
    MAX_INDIVIDUAL_POWER       = "Maximum Enemy Power",
    MAX_DIFF_POWER             = "Maximum Enemy Power Above Yours",
    MAX_COMBINED_POWER         = "Maximum Combined Enemy Power",
    MAX_ENEMY_COUNT            = "Maximum Enemy Count",
    NORMAL_POWER_RATIO         = "Normal Enemy Power Ratio",
    ELITES_POWER_RATIO         = "Elite Enemy Power Ratio",
    BOSS_POWER_RATIO           = "Boss Enemy Power Ratio",
    ACTION_DELAY               = "Action Delay",
    STOP_POPUP                 = "Popup when the bot stops",
    LOG_LEVEL                  = "Log level",
}

--- The title, or the key itself when something asks for a name this does not
--- have. A reason that says "MAX_ENEMY_COUNT" is poor; one that errors is
--- worse.
function M.title(name)
    return M.TITLE[name] or tostring(name)
end
return M
