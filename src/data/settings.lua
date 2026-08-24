-- SkooBot: Reclauded -- settings defaults.
--
-- Copyright (C) 2018-2020 SkoobyDoo (SkooBot 0.0.12, data/settings.lua)
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- PORTED FROM SkooBot 0.0.12 (D-12). Same six settings and defaults, under a
-- namespace the original does not use, so the two addons' settings files
-- never read each other's values.

config.settings.skoobot_reclauded = config.settings.skoobot_reclauded or {}

-- Run once per process: this file is dofile'd from the ToME:run hook.
if config.settings.skoobot_reclauded.loaded then return end
config.settings.skoobot_reclauded.loaded = true

config.settings.tome.skoobot_reclauded = config.settings.tome.skoobot_reclauded or {}
local s = config.settings.tome.skoobot_reclauded

-- #90: recover what the engine could not.
--
-- Each setting lives in its own /settings/*.cfg, which the engine runs as
-- Lua at startup -- BEFORE any addon exists. A file written by any build
-- before this one says `tome.skoobot_reclauded.X = v` with no table to put
-- it in, so it dies, is swallowed, and the defaults below land on nothing.
-- Every option the player ever chose was silently discarded on the next
-- start, and only a restart showed it: the file was right, and the live
-- table was right for the rest of the session.
--
-- data/cfg.lua writes a form that creates the table first, so from now on
-- the engine's own load works. This pass is for the files already on disk.
-- It runs BEFORE the defaults, and only fills what is still nil, so a value
-- the engine did manage to load wins and re-reading is harmless.
--
-- The file is READ, not executed: it is on the player's disk, and running
-- it would be running whatever is in it.
--
-- Everything here is best-effort. A missing file, an unreadable one, a line
-- that says something unexpected -- each falls through to the default,
-- which is exactly what happened before this existed. It must never be the
-- reason the addon fails to load.
local cfg = dofile("/data-skoobot_reclauded/cfg.lua")
local PERSISTED = {
    "LOWHEALTH_RATIO", "IGNORE_DAMAGE_HEALTH_RATIO",
    "MAX_INDIVIDUAL_POWER", "MAX_DIFF_POWER", "MAX_COMBINED_POWER", "MAX_ENEMY_COUNT",
    "NORMAL_POWER_RATIO", "ELITES_POWER_RATIO", "BOSS_POWER_RATIO",
    "ACTION_DELAY", "STOP_POPUP", "LOG_LEVEL",
}
for _, name in ipairs(PERSISTED) do
    if type(s[name]) == "nil" then
        local ok, value = pcall(function()
            local f = fs.open(cfg.path(name), "r")
            if not f then return nil end
            local text = f:read(4096)
            f:close()
            return cfg.parse(text, name)
        end)
        if ok and value ~= nil then s[name] = value end
    end
end

if type(s.LOWHEALTH_RATIO)      == "nil" then s.LOWHEALTH_RATIO      = 0.5 end
-- T-011: below this life fraction, damage taken while exploring hands back;
-- above it, a scratch (a single poison tick) is ignored. Added over v1.
-- 0.9, not the 0.75 first shipped: DOTs ramp, and letting a quarter of a
-- character's life go before the bot hands back is too permissive (owner
-- review on #6).
if type(s.IGNORE_DAMAGE_HEALTH_RATIO) == "nil" then s.IGNORE_DAMAGE_HEALTH_RATIO = 0.9 end
if type(s.MAX_INDIVIDUAL_POWER) == "nil" then s.MAX_INDIVIDUAL_POWER = 200 end
if type(s.MAX_DIFF_POWER)       == "nil" then s.MAX_DIFF_POWER       = 10  end
-- #62 (salvage-mishander.md item 4): since the crowd threshold became
-- relative, this is the margin the combined enemy power may exceed the
-- character's own (life-scaled) power by, not an absolute cutoff. The
-- default is v1's 500 unchanged; its meaning is not.
if type(s.MAX_COMBINED_POWER)   == "nil" then s.MAX_COMBINED_POWER   = 500 end
if type(s.MAX_ENEMY_COUNT)      == "nil" then s.MAX_ENEMY_COUNT      = 12  end
if type(s.ACTION_DELAY)         == "nil" then s.ACTION_DELAY         = 0   end

-- #62 (salvage-mishander.md item 2): an enemy's power is multiplied by the
-- weight for its rank band before the power-level stop conditions compare
-- it. mishander's defaults, kept as shipped: commons count for less than
-- half, elites and rares at face value, bosses double. The bands are
-- data/power.lua's rankBand (critter/normal; elite/rare/unique; boss and up).
if type(s.NORMAL_POWER_RATIO)   == "nil" then s.NORMAL_POWER_RATIO   = 0.4 end
if type(s.ELITES_POWER_RATIO)   == "nil" then s.ELITES_POWER_RATIO   = 1.0 end
if type(s.BOSS_POWER_RATIO)     == "nil" then s.BOSS_POWER_RATIO     = 2.0 end

-- #58: show the "why did it stop" popup (StopDialog) on a STOPPED notice.
-- Off by default: the log line and the big-news banner carry the stop; the
-- popup is for players who want to be made to read it. The popup's own
-- checkbox turns this off again; the options tab turns it back on.
if type(s.STOP_POPUP)           == "nil" then s.STOP_POPUP           = false end

-- #46: how much the bot writes to te4_log.txt, as a level number from
-- data/log.lua (0 off, 1 error, 2 warn, 3 info, 4 debug, 5 trace). A number
-- rather than a name because the settings writer quotes nothing, so a name
-- would come back as a global read of nil. 3 is info: one line per action
-- and per stop, which is what a bug report is read from; the per-decision
-- and per-talent chatter is off. The options tab cycles it by name;
-- skoobot_reclauded.log.setLevel() changes it for the session.
if type(s.LOG_LEVEL)            == "nil" then s.LOG_LEVEL            = 3     end
