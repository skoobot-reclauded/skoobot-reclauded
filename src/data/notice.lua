-- SkooBot: Reclauded -- how a stop is worded and coloured.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- The one place a stop becomes what the player sees (#58): call sites pass
-- plain text and a severity, and nothing else words or colours a stop.
--
-- Text carries no colour codes and no trailing period, so it reads the same in
-- the log, the banner, the popup and in `last_reason`, which the harness
-- asserts on. Nothing here formats -- a `%` stays a `%` -- so pass the result
-- to game.log as an argument, never as the format string.

local M = {}

M.STOPPED     = "stopped"
M.HANDED_BACK = "handed_back"
M.CANNOT_ACT  = "cannot_act"

M.PREFIX = "[SkooBot]"

local STYLE = {
    [M.STOPPED]     = { colour = "#LIGHT_RED#", label = "Stopped" },
    [M.HANDED_BACK] = { colour = "#GOLD#",      label = "Handed back" },
    [M.CANNOT_ACT]  = { colour = "#ORANGE#",    label = "Cannot act" },
}

--- Compose the renderings of one stop: severity (anything unknown is treated
--- as STOPPED, the loud one), the reason as plain prose, and an optional hint.
--- Returns { severity, label, colour, reason, line, banner, popup }.
function M.compose(severity, text, hint)
    local style = STYLE[severity]
    if not style then severity, style = M.STOPPED, STYLE[M.STOPPED] end
    text = tostring(text or "")
    if hint == "" then hint = nil end

    local reason = style.label .. ": " .. text
    local body = reason
    if hint then body = body .. " (" .. hint .. ")" end

    return {
        severity = severity,
        label    = style.label,
        colour   = style.colour,
        reason   = reason,
        line     = style.colour .. "#{bold}#" .. M.PREFIX .. "#{normal}# " .. body,
        banner   = style.colour .. "SkooBot " .. style.label:lower() .. ": " .. text,
        popup    = style.colour .. reason .. "#WHITE#" .. (hint and ("\n\n" .. hint) or ""),
    }
end

return M
