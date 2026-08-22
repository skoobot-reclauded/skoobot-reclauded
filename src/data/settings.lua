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

if type(s.LOWHEALTH_RATIO)      == "nil" then s.LOWHEALTH_RATIO      = 0.5 end
-- T-011: below this life fraction, damage taken while exploring hands back;
-- above it, a scratch (a single poison tick) is ignored. Added over v1.
if type(s.IGNORE_DAMAGE_HEALTH_RATIO) == "nil" then s.IGNORE_DAMAGE_HEALTH_RATIO = 0.75 end
if type(s.MAX_INDIVIDUAL_POWER) == "nil" then s.MAX_INDIVIDUAL_POWER = 200 end
if type(s.MAX_DIFF_POWER)       == "nil" then s.MAX_DIFF_POWER       = 10  end
if type(s.MAX_COMBINED_POWER)   == "nil" then s.MAX_COMBINED_POWER   = 500 end
if type(s.MAX_ENEMY_COUNT)      == "nil" then s.MAX_ENEMY_COUNT      = 12  end
if type(s.ACTION_DELAY)         == "nil" then s.ACTION_DELAY         = 0   end
