-- SkooBot: Reclauded -- how a stop is worded and coloured.
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
-- Until #58 a stop reached the player as whatever string its call site chose:
-- some twenty-five sites and at least eight spellings of the same event
-- ("AI Stopped:", " Ai Stopped:", "AI stopped:", "AI Stopping!", "AI
-- cancelled", "AI Disabled."), in red or gold -- colours the game's own log
-- uses for hits and effects -- so a stop had no visual identity of its own
-- and scrolled off with the next few combat lines. The player noticed the
-- character standing still, not why.
--
-- Call sites now pass plain text and a severity, and this module is the one
-- place that turns those into what the player sees:
--
--   STOPPED      the player must look: low life, a debuff, stuck.
--   HANDED_BACK  the bot finished or yielded on purpose: level change,
--                glowing chest, the player pressed stop.
--   CANNOT_ACT   the bot could not act: no path, everything on cooldown.
--
-- One fixed prefix and one colour per severity; the prefix is the identity.
-- The text is prose with no colour codes and no trailing period, so it reads
-- the same in the log, in the big-news banner, in the popup and in
-- `skoobot_reclauded.last_reason`, which the harness asserts on. Nothing here
-- formats: a `%` in the text is a `%`, and the caller passes the result to
-- game.log as an argument, not as the format string.
--
-- Pure: spec/notice_spec.lua covers it without a running game.

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

--- Compose the renderings of one stop.
-- @param severity  M.STOPPED, M.HANDED_BACK or M.CANNOT_ACT; anything else
--                  is treated as STOPPED, the loud one
-- @param text      the reason: plain prose, no colour codes, no trailing period
-- @param hint      optional: what to do about it, shown after the reason
-- @return a table:
--   severity  the severity actually used
--   label     "Stopped" / "Handed back" / "Cannot act"
--   colour    the severity's colour code
--   reason    "<label>: <text>" -- for last_reason; no prefix, no hint, no colour
--   line      the message-log line: colour, bold prefix, reason, hint in parentheses
--   banner    the big-news line: colour, "SkooBot <label>: <text>"
--   popup     the popup body: coloured reason, then the hint on its own line
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
