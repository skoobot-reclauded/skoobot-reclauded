-- SkooBot: Reclauded -- the levelled debug channel (#46).
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- One channel for everything the bot writes about itself (#46): five levels,
-- one setting, two sinks, and nothing spent when a level is off.
--
--   error   the addon is wrong: an unknown stop condition, a liveness trip
--   warn    the player should probably know: a rule dropped for a talent
--           the character no longer has
--   info    one line per event the bot took part in. A few lines a turn.
--   debug   per-decision reasoning: state, life deltas, sustain attempts
--   trace   per-talent and per-iteration chatter. Never on by default.
--
-- An info line carries NO level tag, so what the scenarios grep for reads as
-- it did before levels existed: `^\[SKOOBOT\]` is every line of the addon's,
-- `^\[SKOOBOT\] \[(debug|trace)\]` is the chatter.
--
-- Stops are never logged through the user sink: data/notice.lua owns what the
-- player sees of a stop, so one notice per stop stays true (#58).
--
-- Cheap when off by construction: a call at a disabled level returns before it
-- touches its arguments, so pass a format and arguments, and pass a function
-- when the ARGUMENTS are costly. Nothing here raises into the act loop.

local M = {}

M.PREFIX = "[SKOOBOT]"

-- A logger at level N emits 1..N, so a higher number is noisier; 0 is silence,
-- errors included. Numbers are what the setting persists (see data/cfg.lua),
-- names are what the options tab and the bridge speak.
M.LEVELS = { off = 0, error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
M.NAMES  = { [0] = "off", "error", "warn", "info", "debug", "trace" }
M.MAX    = 5

-- What the product ships with. Info, not warn: the one-line-per-action
-- narrative is what a bug report is read from, at a few lines a turn.
M.DEFAULT = "info"

-- The user sink sees this level and anything louder.
M.USER_LEVEL = "warn"

-- Info: the one-line-per-action narrative is what a bug report is read from.
function M.level(v)
    if type(v) == "number" then
        if v ~= math.floor(v) or v < 0 or v > M.MAX then
            return nil, "no such log level: " .. tostring(v)
        end
        return v
    end
    if type(v) == "string" then
        local n = M.LEVELS[v:lower()]
        if n then return n end
        local num = tonumber(v)
        if num then return M.level(num) end
    end
    return nil, "no such log level: " .. tostring(v)
end

--- The name of a level number, or nil.
function M.name(n)
    return M.NAMES[n]
end

--- One formatted line: the prefix, the level tag for anything but info, and
--- the text.
function M.line(n, text)
    if n == M.LEVELS.info then
        return M.PREFIX .. " " .. text
    end
    return M.PREFIX .. " [" .. tostring(M.NAMES[n] or n) .. "] " .. text
end

--- One formatted line: the prefix, the level tag for anything but info, and
--- the text.
local function render(fmt, ...)
    if type(fmt) == "function" then
        local ok, r = pcall(fmt, ...)
        if ok then return tostring(r) end
        return "(log message function failed: " .. tostring(r) .. ")"
    end
    local n = select("#", ...)
    if n == 0 then return tostring(fmt) end
    local s = tostring(fmt)
    local ok, out = pcall(s.format, s, ...)
    if ok then return out end
    local parts = { s }
    for i = 1, n do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, " ") .. " (log format error: " .. tostring(out) .. ")"
end

-- A format with no arguments is taken as it is, so a literal "%" in a plain
-- message is not a crash. Looked up as fmt:format(...) rather than a captured
-- string.format, so a test can prove the formatter was not reached.
function M.new(opts)
    opts = opts or {}
    local sink = opts.sink or print
    local user = opts.user
    local level = M.level(opts.level) or M.LEVELS[M.DEFAULT]
    local USER = M.LEVELS[M.USER_LEVEL]
    local L = { module = M }   -- the level table and names, for whoever holds only the logger

    --- Set the level; returns its name, or nil and a message for an unknown
    --- one, in which case nothing changes.
    function L.setLevel(v)
        local n, err = M.level(v)
        if not n then return nil, err end
        level = n
        return M.NAMES[n]
    end

    --- The current level's name.
    function L.getLevel()
        return M.NAMES[level]
    end

    --- The current level's number.
    function L.getLevelNumber()
        return level
    end

    --- Would a line at this level be emitted right now?
    function L.enabled(v)
        local n = M.level(v)
        return n ~= nil and n > 0 and n <= level
    end

    local function emit(n, fmt, ...)
        local text = render(fmt, ...)
        sink(M.line(n, text))
        if user and n <= USER then
            pcall(user, M.NAMES[n], text)
        end
    end

    -- Gated before the arguments are looked at, against upvalues: a disabled
    -- call is a call, a compare and a return.
    function L.error(fmt, ...) if level >= 1 then emit(1, fmt, ...) end end
    function L.warn(fmt, ...)  if level >= 2 then emit(2, fmt, ...) end end
    function L.info(fmt, ...)  if level >= 3 then emit(3, fmt, ...) end end
    function L.debug(fmt, ...) if level >= 4 then emit(4, fmt, ...) end end
    function L.trace(fmt, ...) if level >= 5 then emit(5, fmt, ...) end end

    --- Log at a level given by name or number; an unknown level or "off"
    --- emits nothing.
    function L.log(v, fmt, ...)
        local n = M.level(v)
        if n and n > 0 and n <= level then emit(n, fmt, ...) end
    end

    return L
end

return M
