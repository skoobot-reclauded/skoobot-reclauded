-- SkooBot: Reclauded -- what a damage type leaves behind.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- #170 measured that control effects are twice as likely when the killer
-- scored LOW (40% against 21% over 53 deaths), and that the power model has no
-- term for them at all. This is the lookup that term needs: given a damage
-- type, what it can do to you besides damage.
--
-- DERIVED MECHANICALLY from data/damage_types.lua in ToME 1.7.6, by walking
-- each newDamageType block and collecting the EFF_* names its projector sets.
-- Not transcribed, and deliberately not summarised: #170's own summary table
-- has three wrong rows out of five, and the `tactical` hints it was written to
-- replace are wrong in both directions for Ice Bolt. A hand-written table of
-- this is a table that drifts.
--
-- To regenerate after a ToME upgrade: split data/damage_types.lua on
-- "newDamageType{", take `type = "X"` and every EFF_ name in the block, and
-- keep the ones naming a DISABLE or IMPAIR effect below.
--
-- No game globals; a plain table, so a spec can pin it without a running game.

local M = {}

--- Effects that take the character's turns away outright.
M.DISABLE = {
    FROZEN = true, STUNNED = true, DAZED = true, TIME_PRISON = true,
    PINNED = true, FROZEN_FEET = true,
}

--- Effects that degrade rather than remove: still acting, acting worse.
M.IMPAIR = {
    BLINDED = true, SILENCED = true, CONFUSED = true, SLOW = true,
    DIM_VISION = true, BRAINLOCKED = true, SHOCKED = true,
    BURNING_SHOCK = true, SLOW_MOVE = true, OFFBALANCE = true,
}

--- Damage type -> what it can leave behind. Types that leave nothing are
--- ABSENT, which is the interesting half: see the specs.
---
--- Only effects named in DISABLE or IMPAIR are listed, so a projector's other
--- side effects do not appear. EFF_WET is the one worth knowing about: ICE
--- sets it, it does nothing to the character by itself, and it doubles ICE's
--- own freeze chance from 25% to 50%. A freeze amplifier belongs wherever the
--- chance is priced, not in a list of what can be done to you.
M.BY_TYPE = {
    ACID_BLIND               = { worst = "impair", effects = { "BLINDED" } },
    ARCANE_SILENCE           = { worst = "impair", effects = { "SILENCED" } },
    BLACK_HOLE_GRAVITY       = { worst = "impair", effects = { "SLOW" } },
    BLIND                    = { worst = "impair", effects = { "BLINDED" } },
    BLINDCUSTOMMIND          = { worst = "impair", effects = { "BLINDED" } },
    BLINDING_INK             = { worst = "impair", effects = { "BLINDED" } },
    BLINDING_POWDER          = { worst = "impair", effects = { "BLINDED" } },
    BLINDPHYSICAL            = { worst = "impair", effects = { "BLINDED" } },
    BLOODSPRING              = { worst = "impair", effects = { "OFFBALANCE" } },
    BLOOD_BOIL               = { worst = "impair", effects = { "SLOW" } },
    BRAINSTORM               = { worst = "impair", effects = { "BLINDED", "BRAINLOCKED" } },
    CAUSTIC_MIRE             = { worst = "impair", effects = { "SLOW" } },
    CHRONOSLOW               = { worst = "impair", effects = { "SLOW" } },
    COLDNEVERMOVE            = { worst = "disable", effects = { "FROZEN_FEET" } },
    COLDSTUN                 = { worst = "disable", effects = { "STUNNED" } },
    CONFUSION                = { worst = "impair", effects = { "CONFUSED" } },
    DARKKNOCKBACK            = { worst = "impair", effects = { "BRAINLOCKED" } },
    DARKNESS_BLIND           = { worst = "impair", effects = { "BLINDED" } },
    DARKSTUN                 = { worst = "disable", effects = { "STUNNED" } },
    DISTORTION               = { worst = "disable", effects = { "OFFBALANCE", "STUNNED" } },
    DREAMFORGE               = { worst = "impair", effects = { "BRAINLOCKED", "OFFBALANCE" } },
    ENTANGLE                 = { worst = "disable", effects = { "PINNED" } },
    FEARKNOCKBACK            = { worst = "impair", effects = { "BRAINLOCKED" } },
    FIREKNOCKBACK            = { worst = "impair", effects = { "OFFBALANCE" } },
    FIREKNOCKBACK_MIND       = { worst = "impair", effects = { "OFFBALANCE" } },
    FLAMESHOCK               = { worst = "impair", effects = { "BURNING_SHOCK" } },
    FLARE                    = { worst = "impair", effects = { "BLINDED" } },
    FREEZE                   = { worst = "disable", effects = { "FROZEN" } },
    GRASPING_MOSS            = { worst = "disable", effects = { "PINNED", "SLOW_MOVE" } },
    GRAVITY                  = { worst = "impair", effects = { "SLOW" } },
    GRAVITYPIN               = { worst = "disable", effects = { "PINNED" } },
    HALLUCINOGENIC_MOSS      = { worst = "impair", effects = { "CONFUSED" } },
    ICE                      = { worst = "disable", effects = { "FROZEN" } },
    ICE_SLOW                 = { worst = "impair", effects = { "SLOW" } },
    ITEM_LIGHTNING_DAZE      = { worst = "disable", effects = { "DAZED" } },
    ITEM_LIGHT_BLIND         = { worst = "impair", effects = { "BLINDED" } },
    ITEM_NATURE_SLOW         = { worst = "impair", effects = { "SLOW" } },
    LIGHTNING                = { worst = "impair", effects = { "BRAINLOCKED" } },
    LIGHTNING_DAZE           = { worst = "disable", effects = { "DAZED", "SHOCKED" } },
    LIGHT_BLIND              = { worst = "impair", effects = { "BLINDED" } },
    MIND                     = { worst = "impair", effects = { "BRAINLOCKED" } },
    MINDFREEZE               = { worst = "disable", effects = { "FROZEN" } },
    MINDKNOCKBACK            = { worst = "impair", effects = { "OFFBALANCE" } },
    MINDSLOW                 = { worst = "impair", effects = { "SLOW" } },
    NIGHTMARE                = { worst = "impair", effects = { "SLOW" } },
    PESTILENT_BLIGHT         = { worst = "disable", effects = { "BLINDED", "PINNED", "SILENCED" } },
    PHYSICAL_STUN            = { worst = "disable", effects = { "STUNNED" } },
    PHYSKNOCKBACK            = { worst = "impair", effects = { "OFFBALANCE" } },
    PINNING                  = { worst = "disable", effects = { "PINNED" } },
    RANDOM_BLIND             = { worst = "impair", effects = { "BLINDED" } },
    RANDOM_CONFUSION         = { worst = "impair", effects = { "CONFUSED" } },
    RANDOM_CONFUSION_PHYS    = { worst = "impair", effects = { "CONFUSED" } },
    RANDOM_SILENCE           = { worst = "impair", effects = { "SILENCED" } },
    RANDOM_WARP              = { worst = "disable", effects = { "BLINDED", "CONFUSED", "PINNED", "STUNNED" } },
    REPULSION                = { worst = "impair", effects = { "OFFBALANCE" } },
    RETHREAD                 = { worst = "disable", effects = { "BLINDED", "CONFUSED", "PINNED", "STUNNED" } },
    RIGOR_MORTIS             = { worst = "impair", effects = { "SLOW" } },
    SANCTITY                 = { worst = "impair", effects = { "SILENCED" } },
    SAND                     = { worst = "impair", effects = { "BLINDED" } },
    SILENCE                  = { worst = "impair", effects = { "SILENCED" } },
    SLIME                    = { worst = "impair", effects = { "SLOW" } },
    SLOW                     = { worst = "impair", effects = { "SLOW" } },
    SMOKESCREEN              = { worst = "impair", effects = { "DIM_VISION", "SILENCED" } },
    SPELLKNOCKBACK           = { worst = "impair", effects = { "OFFBALANCE" } },
    STATIC_NET               = { worst = "impair", effects = { "SLOW" } },
    STICKY_SMOKE             = { worst = "impair", effects = { "DIM_VISION" } },
    STOP                     = { worst = "disable", effects = { "STUNNED" } },
    TEMPORALSTUN             = { worst = "disable", effects = { "STUNNED" } },
    TERROR                   = { worst = "disable", effects = { "CONFUSED", "SLOW", "STUNNED" } },
    TIME_PRISON              = { worst = "disable", effects = { "TIME_PRISON" } },
    TK_PUSHPIN               = { worst = "disable", effects = { "PINNED" } },
    WAVE                     = { worst = "impair", effects = { "OFFBALANCE" } },
}

--- The worst thing `damtype` can leave behind: "disable", "impair", or nil.
---
--- nil is a real answer and the common one -- most damage types only deal
--- damage. A caller that treats nil as "unknown" rather than "nothing" will
--- price every plain fire bolt as a threat.
function M.worst(damtype)
    local e = type(damtype) == "string" and M.BY_TYPE[damtype] or nil
    return e and e.worst or nil
end

--- Every effect `damtype` can leave behind, newest-first order not guaranteed.
--- Always a table, empty when there is nothing.
function M.effects(damtype)
    local e = type(damtype) == "string" and M.BY_TYPE[damtype] or nil
    return (e and e.effects) or {}
end

return M
