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

### The clinching evidence: STUNNED no longer means what v1 thinks

v1 treats `DEBUFF_STUNNED` as a stop condition. In ToME 1.7.6, stun does **not** prevent
acting:

> *"The target is stunned, reducing damage by 50%, putting 3 random talents on cooldown and
> reducing movement speed by 50%. While stunned talents cooldown twice as slow."*

It sets `stunned = 1`, halves damage and movement speed, and puts three talents on cooldown.
It blocks nothing outright. A stunned character can move and fight — worse than usual, but
perfectly able. v1 halts anyway, surrendering turns it could have used.

Meanwhile `DAZED` — which *does* incapacitate — sets `never_move`, so the capability check
catches it for free.

This is the argument for the whole approach. **Named conditions drift in meaning between game
versions; capabilities don't.** A bot that asks "can I move?" stays correct across a rules
change. A bot that asks "am I stunned?" silently becomes wrong the day the developer rebalances
stun, with nothing to signal that it has — which is precisely what happened here, and it went
unnoticed for the remaining life of the project.

**Reclassify accordingly:** stunned and confused are *impairments* that should feed the score
(fight yes, explore cautiously), not conditions that halt the bot.

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

### But "cannot act" needs no condition at all

`never_move` has a clean aggregate. **"Cannot act" has no usable twin, and doesn't need one.**

`mod/class/Player.lua`, first line of `act()`:

```lua
function _M:act()
    if not mod.class.Actor.act(self) then return end
```

and `Actor:act()` bails at the energy gate before any player control flow:

```lua
if self:attr("paralyzed")   then ... self.energy.value = 0 ... end
if self:attr("stoned")      then self.energy.value = 0 end
if self:attr("dont_act")    then self.energy.value = 0 end
if self:attr("time_stun")   then self.energy.value = 0 end
if self:attr("time_prison") then self.energy.value = 0 end
if self.energy.value < game.energy_to_act then return false end
if self:attr("never_act") then return false end
```

So when the character cannot act, **the player is never prompted** — no keypress is requested,
the engine simply ticks other actors. And because the addon superloads `Player:act()`, the
bot's code doesn't run either.

Three consequences:

1. **A `CANNOT_ACT` stop condition is unimplementable.** The detector would live in code that
   never executes during the very state it's meant to detect.
2. **A "player manually passes turns" policy is impossible**, not merely tedious — there is no
   prompt to pass at. Nor would it help: you cannot hand control to a player who also cannot
   act.
3. **The bot cannot spin here.** The immobilisation soft-lock exists precisely *because*
   movement blocking still grants turns. Act blocking doesn't. That asymmetry is the whole
   reason `never_move` needs handling and act blocking doesn't.

### The actionable moment is when it *ends*

The real hazard is invisible: you're paralysed, you take twenty hits, and you find out
afterwards from the log. The bot's first real turn after the gap is the only point where
anything can be decided.

Two mechanisms, both cheap:

- **`LIFE_BIGLOSS` already covers most of it.** The bot's remembered life is from *before* the
  blackout, so the delta on resume naturally spans the entire gap. It fires as designed.
- **Add a `BLACKOUT` condition** that measures the gap directly. `game.turn` advances by 1000
  per game turn, so recording it each bot turn makes the gap trivially detectable:

```lua
{
  code    = "BLACKOUT",
  label   = "Turns lost while unable to act",
  default = "WARN",
  detect  = function(p, ctx) return ctx.turnGap > 1 end,
  msg     = "lost %d turns while unable to act",
}
```

That surfaces the thing the player currently has to reconstruct from a post-mortem — and it
hands control back at the one moment they can actually use it.

For reference, ToME has its own version of this idea: `life_lost_warning` fires
`game.bignews` and disables input for two seconds after a large life drop.

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

### Fix: reconcile the saved list against the definitions

On access, walk the definitions and add anything the character is missing, using that
definition's current default. **The same pass must handle two adjacent cases**, or it leaves
the bug it's meant to fix:

| case | why it matters |
|---|---|
| **definition present, save missing** | the reported problem — new conditions never reach existing characters |
| **save present, definition gone** | a retired condition lingers as a phantom toggle in the config UI that controls nothing. That is the ASLEEP failure in miniature: a control that looks live and isn't |
| **label changed in code** | display text is stale forever, so the same condition reads differently on two characters |

So: **add missing, drop orphans, and take everything except the player's chosen `stoptype`
from the definition.**

```lua
-- Idempotent. Cheap at this size (~15 entries), so just run it on every
-- access rather than guarding with a "migrated" flag -- that way a save
-- that was hand-edited or half-written repairs itself too.
local function reconcileConditions(player)
    local saved = player.skoobot_conditions or {}
    local policy = {}
    for _, e in ipairs(saved) do policy[e.code] = e.stoptype end  -- keep only the choice

    local out = {}
    for _, def in ipairs(CONDITIONS) do        -- definitions drive; orphans fall away
        out[#out+1] = {
            code     = def.code,
            label    = def.label,              -- always current
            stoptype = policy[def.code] or def.default,
        }
    end
    player.skoobot_conditions = out
    return out
end
```

Because everything but `stoptype` is refreshed from the definition, the only thing the save
actually carries is the player's deviation from the defaults — the list form and an
overrides map converge on identical behaviour. Keeping the list shape is the smaller change
and reads more obviously in a save dump; if the schema is ever simplified, storing
`{code = stoptype}` alone is sufficient and loses nothing.

**No version stamps.** A reconcile that is idempotent and self-healing beats a chain of
version-gated migrations: there is no ordering to get wrong, nothing to forget to write, and
a save from any past or future version converges on the same correct state.

**Guard the lookup regardless.** `getStopCondition` currently returns `nil` after printing an
error, and every caller immediately dereferences `.stoptype`. Reconciliation makes that
unreachable in practice, but the function should still fail closed — return the definition's
default rather than `nil`, so a lookup bug degrades into "uses the default" instead of a
crash mid-run.

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
