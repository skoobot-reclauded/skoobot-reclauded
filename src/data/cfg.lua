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
-- One option, one file under the engine's settings directory, holding Lua the
-- engine runs at startup. That is ToME's own mechanism (Game:saveSettings
-- writes /settings/<file>.cfg) and v1 used it under `tome.SkooBot`.
--
-- THE TRAP this module exists for (#90): the engine runs every one of those
-- files LONG BEFORE any addon is loaded, because the config is read to decide
-- what to load. So a file saying
--
--     tome.skoobot_reclauded.MAX_ENEMY_COUNT = 77
--
-- indexes a field that does not exist yet, dies, and is swallowed. It looks
-- like it works: the file on disk is right and the live table is right for the
-- rest of the session, and only a restart shows the loss.
--
-- Two halves to the repair, and this module is the shared half: `line()`
-- writes a form that creates the table first, so the engine's own startup load
-- works from now on, and `parse()` reads a value back out of a file's text, so
-- values written by an older build -- which is all of them -- are recovered.
-- data/settings.lua does that before it seeds any default.
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
--- namespace table, which at config-load time the engine has never got round
--- to. Without it the second line is a nil index and the value is lost on the
--- next start.
---
--- Numbers and booleans only, which is every setting this addon has; anything
--- else is refused rather than written badly (LOG_LEVEL is a number for
--- exactly this reason).
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
--- Reads the assignment rather than executing the file: the file is on the
--- player's disk, and running it would be running whatever is in it. Numbers
--- and booleans only, matching `line()`.
---
--- Tolerates what real files contain -- the guarded two-line form and the old
--- one-line form, a UTF-8 BOM, CRLF, whitespace anywhere reasonable. The
--- pattern is anchored on the option's own name, so the guard line, which
--- assigns the NAMESPACE and not a name under it, cannot be read as a value.
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


--- What each setting is CALLED where the player meets it (#71). One table,
--- read by the tab that draws the titles and by the reasons that quote them,
--- so the two cannot name the same knob differently. A stop that named the
--- setting key instead left the player nothing on screen to match it to.
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

--- Which settings belong to the CHARACTER, and which to the account (#95).
---
--- A threshold answers "how dangerous is this character's situation", and a
--- level 3 Alchemist and a level 30 Bulwark do not want the same answer. The
--- three left out answer "how do I like this addon to behave" -- how fast it
--- steps, whether it opens a popup, how much it prints -- which is the
--- player's, not the character's.
---
--- A character with no value of its own uses the account default, which is
--- what every existing save has and why this needs no migration.
M.PER_CHARACTER = {
    LOWHEALTH_RATIO            = true,
    IGNORE_DAMAGE_HEALTH_RATIO = true,
    MAX_INDIVIDUAL_POWER       = true,
    MAX_DIFF_POWER             = true,
    MAX_COMBINED_POWER         = true,
    MAX_ENEMY_COUNT            = true,
    NORMAL_POWER_RATIO         = true,
    ELITES_POWER_RATIO         = true,
    BOSS_POWER_RATIO           = true,
}

--- Every option this addon has, in the order the settings screen shows them:
--- the character's safety thresholds first, because they are what a player
--- comes to change, then the account preferences.
M.ORDER = {
    "LOWHEALTH_RATIO", "IGNORE_DAMAGE_HEALTH_RATIO",
    "MAX_INDIVIDUAL_POWER", "MAX_DIFF_POWER", "MAX_COMBINED_POWER", "MAX_ENEMY_COUNT",
    "NORMAL_POWER_RATIO", "ELITES_POWER_RATIO", "BOSS_POWER_RATIO",
    "ACTION_DELAY", "STOP_POPUP", "LOG_LEVEL",
}

--- What each option does, in the words the stops use (#54, #82, #95). One map,
--- read by the options tab and by the settings screen, so two copies of a
--- paragraph cannot drift into two paragraphs.
M.DESC = {
    LOWHEALTH_RATIO =
        "A fraction of your life pool (0.5 is half) -- your maximum life, plus whatever " ..
        "keeps you alive below zero, which is what the game itself measures. While " ..
        "enemies are in view, the bot " ..
        "stops when life is below it. The other life thresholds follow from it: losing half " ..
        "of this fraction in one turn is the Big Loss stop; in a fight, losing a quarter of " ..
        "it in one turn uses a Damage Prevention talent, and missing a quarter of it uses a " ..
        "Recovery talent.",
    IGNORE_DAMAGE_HEALTH_RATIO =
        "A fraction of your life pool (0.9 is nine tenths); see Low Health Ratio for what " ..
        "the pool is. While exploring with nothing " ..
        "in view, damage is ignored as long as life stays above it, so a single poison tick " ..
        "does not stop the bot; once life is below it, any damage taken while exploring hands " ..
        "back. It is also the scale that stop is measured on: life exactly at this ratio is " ..
        "threat 1, and twice as far below it is threat 2. See Maximum Enemy Power.",
    -- #82: since #11 these five are not independent switches -- each is the
    -- denominator of one term of the threat score, and the score is the
    -- largest term (data/score.lua). Every power stop ends " -- threat N",
    -- so the scale has to be said somewhere or the number is noise.
    MAX_INDIVIDUAL_POWER =
        "Stop when any enemy in view has a power level above this figure, whatever yours is. " ..
        "Power level is the addon's rough threat score for a creature -- its life, damage, " ..
        "crits, speed, defence, stats and weapons summed -- and is shown as \"Power Level\" " ..
        "in every creature's tooltip; hold Ctrl over a creature to see the parts.\n\n" ..
        "These five limits are also a scale: every stop for one of them ends \"-- threat N\", " ..
        "where the limit you set counts as 1, so threat 3 is three times past it. The stop " ..
        "says how far over the room is, not only that it is.",
    MAX_DIFF_POWER =
        "Stop when any enemy in view has a power level more than this much above your own. " ..
        "Your own power level is scaled by the life you have left, so the same enemy stops " ..
        "the bot sooner when you are hurt. On the threat scale, 1 is an enemy exactly this " ..
        "far above you. Power level and the threat figure: see Maximum Enemy Power.",
    MAX_COMBINED_POWER =
        "Stop when the power levels of every enemy in view, added together, are more than " ..
        "this much above your own (again scaled by the life you have left). A margin above " ..
        "yours, not an absolute figure. On the threat scale, 1 is a room exactly this far " ..
        "above you. Power level and the threat figure: see Maximum Enemy Power.",
    MAX_ENEMY_COUNT =
        "Stop when more than this many enemies are in view at once, whatever their power. On " ..
        "the threat scale, 1 is exactly this many in view -- twelve of them against a limit " ..
        "of twelve. The threat figure: see Maximum Enemy Power.",
    -- #62: the rank weights. data/power.lua says which ToME rank is which band.
    NORMAL_POWER_RATIO =
        "Critters and normal-rank enemies count for this multiple of their power level in " ..
        "the three power checks above: 0.4 means a common counts for less than half, so a " ..
        "pack of them does not read as a threat; 1 is face value.",
    ELITES_POWER_RATIO =
        "Elite, rare and unique enemies count for this multiple of their power level in the " ..
        "three power checks above: 1 is face value; 2 would count each as double.",
    BOSS_POWER_RATIO =
        "Bosses, elite bosses and anything stronger count for this multiple of their power " ..
        "level in the three power checks above: 2 counts each as double; 1 is face value.",
    ACTION_DELAY =
        "Seconds the bot waits between its actions, so you can watch what it does. 0 acts " ..
        "at full speed. Known to be rough: with a delay set, the bot also takes its next " ..
        "action when you press a key or move the mouse.",
    STOP_POPUP =
        "Also open a popup with the reason whenever the bot stops for something you should " ..
        "look at: low life, a debuff, being stuck. The message-log line and the banner are " ..
        "always shown. The popup's own checkbox turns this off again.",
    LOG_LEVEL =
        "How much the bot prints. 'off' says nothing; 'warn' only what went wrong; 'info' " ..
        "one line per action; 'debug' the reasoning behind each decision; 'trace' the " ..
        "talent-by-talent checks. The last two grow the log file quickly. Warnings and " ..
        "errors are also shown in the message log.",
}

--- The range a numeric option may be set to, where it is not the default
--- 0..1000000. #74: an option whose real range is 0..1 prompting "From 0 to
--- 1000000" is a prompt that teaches nothing.
M.RANGE = {
    LOWHEALTH_RATIO            = { 0, 1 },
    IGNORE_DAMAGE_HEALTH_RATIO = { 0, 1 },
    NORMAL_POWER_RATIO         = { 0, 10 },
    ELITES_POWER_RATIO         = { 0, 10 },
    BOSS_POWER_RATIO           = { 0, 10 },
}

--- What kind of control an option wants: a number, a yes/no, or a choice.
M.KIND = {
    STOP_POPUP = "boolean",
    LOG_LEVEL  = "choice",
}
function M.kind(name) return M.KIND[name] or "number" end
return M
