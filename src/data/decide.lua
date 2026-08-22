-- SkooBot: Reclauded -- what to do next.
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
-- This is a WALKING SKELETON (T-071), not the decision core. It exists so that
-- there is a build that loads, does something observable, and hands control
-- back -- something to hang the tooling, the packer and the release gate on.
-- The real thing is a scored evaluation of the situation (T-020) over a
-- data-driven condition framework (T-026); four of the original's outstanding
-- complaints trace to exactly the flat-list-of-special-cases shape this file
-- has, so do not grow it. Replace it.
--
-- It is a PURE FUNCTION of a snapshot table on purpose: no globals, no ToME
-- API, no side effects. That is what lets spec/decide_spec.lua test the
-- policy without a running game, and it is the property worth keeping when
-- T-020 replaces the body.

local M = {}

M.STOP    = "stop"
M.REST    = "rest"
M.EXPLORE = "explore"
M.CONTINUE = "continue"

-- Hand back at half life. The design target is a bot that stops early and
-- often rather than one that plays well: handing control back is the feature.
M.LOW_LIFE_FRACTION = 0.5

--- Decide the next action from a snapshot of the world.
--
-- @param s table with:
--   turn           number   game.turn now
--   started_turn   number   game.turn when the bot was switched on
--   budget         number   how many game.turn units it may spend
--   life, max_life number
--   hostiles       number   hostile actors currently visible
--   resting        boolean  engine is mid-rest
--   running        boolean  engine is mid-run (auto-explore travel)
--   wilderness     boolean  the world map, where there is nothing to explore
--   dead           boolean
--   can_explore    boolean  there is somewhere left to auto-explore to
--
-- @return action, reason
function M.decide(s)
  -- Precedence is deliberate and is the whole policy. Anything that makes
  -- acting unsafe or meaningless comes before anything that makes it useful.

  if s.dead then
    return M.STOP, "the character is dead"
  end

  -- The engine is already carrying out a multi-turn action. Interrupting it
  -- to issue another one is how a bot ends up fighting itself.
  if s.resting or s.running then
    return M.CONTINUE, "the engine is mid-action"
  end

  if s.wilderness then
    return M.STOP, "on the world map, where auto-explore does not apply"
  end

  -- Combat is out of scope for the skeleton. A visible hostile is the human's
  -- problem until T-020 exists.
  if s.hostiles and s.hostiles > 0 then
    return M.STOP, ("%d hostile(s) visible"):format(s.hostiles)
  end

  if s.max_life and s.max_life > 0 and (s.life / s.max_life) < M.LOW_LIFE_FRACTION then
    return M.STOP, ("life %d/%d is below %d%%"):format(
      s.life, s.max_life, M.LOW_LIFE_FRACTION * 100)
  end

  -- Measured in game.turn, never wall-clock. A stray keystroke or a resize
  -- costs frames, not turns, so this bound cannot be moved by interference --
  -- the same principle the harness measures progress with, and the liveness
  -- invariant T-027 will generalise.
  if s.budget and (s.turn - s.started_turn) >= s.budget then
    return M.STOP, ("spent its budget of %d turns"):format(s.budget)
  end

  -- Rest before exploring: arriving somewhere new at part health is how a
  -- character dies to the first thing it meets.
  if s.max_life and s.life < s.max_life then
    return M.REST, ("life %d/%d"):format(s.life, s.max_life)
  end

  if s.can_explore == false then
    return M.STOP, "nothing left to explore here"
  end

  return M.EXPLORE, "rested and unthreatened"
end

return M
