-- SkooBot: Reclauded -- the explore stall: when the engine and the bot see
-- different sets of hostiles.
--
-- Copyright (C) 2026 SkoobyDoo
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. See LICENSE.
--
-- The engine's runCheck reads a seens map that ACCUMULATES over the run path:
-- Map:cleanFOV is gated on map.clean_fov (engine/Map.lua:460), which only a
-- drawn frame arms (:620), and act()'s run loop draws none. runStopped then
-- arms it and recomputes, so the same function returns the wide set before
-- that call and the narrow one after. Neither view is stale; they are
-- different sets, and the engine's is a superset. See #153.
--
-- No game globals: the two counts arrive as numbers so the arithmetic can be
-- held to its shape without a running game, as data/escort.lua is.

local M = {}

--- Consecutive disagreements on one level before the explore branch stops
--- re-issuing a run the engine will abort identically.
---
--- Not 1. A hostile that genuinely leaves view between the abort and
--- runStopped's recompute produces one honest disagreement, and abandoning a
--- level for that would cost real exploring. Three consecutive means the
--- geometry is frozen -- an immovable hostile visible from the run path and
--- not from where the run stops -- which is the case that never resolves on
--- its own. #164's black jelly and #153's poison ivy are both that.
M.LIMIT = 3

local function isTable(v) return type(v) == "table" end
local function count(v) return tonumber(v) or 0 end

--- Record one run-abort and return the consecutive disagreement count.
---
--- `st` carries {n} across turns and is mutated; it belongs on the LEVEL, not
--- on the activation -- a restart that cleared it would let the pair live-lock
--- again with a fresh budget, which is #140's lesson.
---
--- `wide` is what the engine could see when it aborted the run, `narrow` what
--- is visible from the grid it stopped on. Counting only the consecutive run
--- is what keeps a moving hostile from ever reaching the limit: any abort
--- where the two agree resets it, and a completed explore agrees trivially
--- because both are zero.
function M.note(st, wide, narrow)
    if not isTable(st) then return 0 end
    if count(wide) > 0 and count(narrow) == 0 then
        st.n = (st.n or 0) + 1
    else
        st.n = 0
    end
    return st.n
end

--- Has running-explore stopped being a way to make progress on this level?
---
--- Deliberately has no reset, the way #140's escort anchor has none: the only
--- thing that should start exploring again is the disagreement not recurring,
--- which note() already resets on. A reset here would let a restart hand the
--- pair a fresh budget to live-lock in.
function M.stalled(st)
    return isTable(st) and (st.n or 0) >= M.LIMIT
end

return M
