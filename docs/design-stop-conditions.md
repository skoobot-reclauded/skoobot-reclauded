# Design: data-driven condition framework

**Status:** proposed · **Task:** T-026 · **Date:** 2026-08-21
**Supersedes:** v1's `getStopConditionList()` + `checkForDebuffs()` split

Agreed direction: fold pinned and everything like it into the existing WARN/STOP/IGNORE
framework, driven from a definition list rather than a hardcoded if-chain. Two findings from
the ToME 1.7.6 source change the shape of that list, and a third changes how it persists.

---

## Keep: the policy layer

v1's tri-state is good and should survive unchanged.

- **STOP** — halt, unconditionally.
- **WARN** — halt *once*, remember the acknowledgement in `skoobotstopwarn`, and let the
  player resume. The flag auto-clears when the condition lifts, so it re-arms naturally.
- **IGNORE** — never halt on this.

The WARN re-arm behaviour is the non-obvious part and it's genuinely well designed. Don't
touch it.

---

## Finding 1 — the list must hold *capabilities*, not effect names

The obvious refactor is a list of effects: `EFF_PINNED`, `EFF_CONSTRICTED`, and so on. That
approach cannot be made correct.

**36 references to `never_move` across ToME's timed-effect files**, spanning at least sixteen
distinct effects:

```
SPYDRIC_POISON · CONSTRICTED · DAZED · FROZEN_FEET · PINNED · BONE_GRAB
GRAPPLED · CRUSHING_HOLD · STRANGLE_HOLD · PSIONIC_BIND · GARROTE
BEAR_TRAP · STONE_VINE · TREE_OF_LIFE · RECALL · …
```

mishander's fork checks `EFF_PINNED`. That is **one of sixteen**.

And an effect list still wouldn't be enough, because movement is also blocked by something
that isn't an effect at all — `Actor.lua:4186`, being over-encumbered:

```lua
self.encumbered = self:addTemporaryValue("never_move", 1)
```

A bot that picks up too much loot cannot move, is not under any effect, and would soft-lock
exactly the same way.

**The correct predicate is the one ToME's own `move()` gates on** (`Actor.lua:1416`):

```lua
elseif not force and self:attr("never_move") then
```

One check. Covers all sixteen effects, covers encumbrance, and stays correct when a future
ToME version adds the seventeenth — because it's the same predicate the game uses. This is
the difference between a list that needs maintaining forever and one that doesn't.

**Design rule: every entry detects a capability the bot needs, not a named cause of losing
it.**

---

## Finding 2 — "cannot move" must not mean "stop"

This is why folding pinned in as a plain stop condition would be a regression.

The five conditions v1 tracked all prevent the character *acting*, so halting is the only
sensible response. Immobilisation is different: **a pinned character can still attack.**
Halting there throws away turns the bot could use.

So an entry needs to say *what it takes away*, and the act loop consults that:

| condition | blocks | correct bot response |
|---|---|---|
| immobilised (`never_move`) | move | don't path, don't explore — **keep fighting** an adjacent target |
| incapacitated (stunned / dazed / stoned / `dont_act`) | act | nothing is possible; halt |
| asleep | act | halt |
| confused | reliable move | safe to fight, unsafe to explore |
| blind | target acquisition | fight only what's adjacent |

That table is also the reason this task feeds **T-020**. A scored evaluation needs to know
what the character *can currently do*; capability flags are an input to the score, not a gate
in front of it.

---

## Finding 3 — v1's list can never gain entries

`getStopConditionList()`:

```lua
if not game.player.skoobotstopconditions then game.player.skoobotstopconditions = { ... } end
return game.player.skoobotstopconditions
```

The defaults are written to the character **once**, then never reconciled. Any condition added
in a later version is invisible to every character created before it. Worse, `getStopCondition`
returns `nil` for an unknown code after printing an error, and every caller immediately does
`.stoptype` on it — so an older save meeting newer code crashes rather than degrading.

v1 never hit this because it stopped shipping. A project that intends to keep shipping will.

**Fix:** the definition list is **code**, and is the single source of truth. Only the player's
*overrides* persist:

```lua
game.player.skoobot_policy = { CANNOT_MOVE = "STOP" }   -- deviations only
```

Unknown keys are dropped on load; unset conditions fall back to the definition's default. New
conditions appear for existing characters automatically, and removed ones vanish harmlessly.

---

## Proposed shape

```lua
-- One entry = one thing the bot needs, its detector, its default policy,
-- and what its absence takes away. Single source of truth: the UI, the
-- detection, and the capability model all read from here.
CONDITIONS = {
  {
    code    = "CANNOT_MOVE",
    label   = "Immobilised",
    default = "WARN",
    blocks  = { move = true },
    detect  = function(p) return p:attr("never_move") end,
    msg     = "immobilised and unable to move",
  },
  {
    code    = "ASLEEP",
    label   = "Asleep",
    default = "WARN",
    blocks  = { act = true },
    -- ToME's own idiom, Actor.lua:1402/4448/5800. v1 tried to copy this and
    -- wrote `not p.lucid_dreamer == 1`, which is always false. See
    -- v1-latent-bugs.md.
    detect  = function(p) return p:attr("sleep") and not p:attr("lucid_dreamer") end,
    msg     = "asleep",
  },
  -- …
}
```

Adding a condition becomes one table entry. The UI list, the detection pass, and the
capability model are generated from it, so they cannot drift.

**Drift is not hypothetical.** It is exactly what broke v1: `DEBUFF_ASLEEP` existed in the
list, rendered in the config UI as a working `WARN` toggle, and its detection in
`checkForDebuffs()` was dead code. Two sources of truth, no mechanism to notice they
disagreed, and a user (h-youhei) reporting the resulting soft-lock in 2021 with nobody able to
see why.

---

## Also fix while in here

`tryStop` shadows its own parameter:

```lua
_M.tryStop = function(self, stoptype, msg)
    local stoptype = self:getStopCondition(stoptype).stoptype   -- param was a *code*
    if stoptype == "IGNORE" then print("... Ignoring stop condition: "..stoptype) ...
```

The parameter is a condition *code*, named `stoptype`, then shadowed by the actual stoptype —
so the diagnostic prints `Ignoring stop condition: IGNORE` instead of naming the condition.
Harmless, but it's the naming confusion that makes the rest of this code hard to read, and
`luacheck` flags shadowing.

---

## Migration note

v1 persisted the full record — `{label, code, stoptype}` — into the save. Under the new
scheme, labels and defaults live in code and only policy overrides persist. Nothing needs
migrating from v1 saves, since this is a separate addon with its own `short_name` and no
shared state.
