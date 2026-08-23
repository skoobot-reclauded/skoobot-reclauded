# Design: liveness vs. model validity

**Status:** proposed · **Task:** T-026 · **Date:** 2026-08-21
**Supersedes:** v1's `getStopConditionList()` + `checkForDebuffs()` split

> **Revised 2026-08-21** after author correction. An earlier draft of this document called
> v1's `DEBUFF_STUNNED` stop "over-conservative" on the grounds that a stunned character can
> still act. That was wrong about the intent. The stop is not a liveness guard — it is a
> deliberate **model-validity boundary**. See §2.

---

## 0. The decoupling

Two problems were being treated as one. They need different mechanisms, different defaults,
and different degrees of user control.

| | **§1 Liveness** | **§2 Model validity** |
|---|---|---|
| Question | *Can the bot make progress at all?* | *Is my risk model still meaningful?* |
| Failure mode | The game hangs or spins | The bot confidently makes a bad decision |
| Detection | Capability predicates + progress invariant | Named conditions |
| Configurable? | **No** — this is correctness | **Yes** — risk appetite and class semantics |
| Example | Immobilised, so pathing can never succeed | Stunned, so the power-level maths is invalid |

Conflating them produces the worst of both: liveness bugs that a user can accidentally
configure away, and risk policy hardcoded where the player's judgement is better.

---

## 1. Liveness — not configurable

### 1.1 Capability predicates

Detect what the bot *can do*, never the named cause. `never_move` has **36 references** across
ToME's timed-effect files spanning 16+ distinct effects:

```
SPYDRIC_POISON · CONSTRICTED · DAZED · FROZEN_FEET · PINNED · BONE_GRAB
GRAPPLED · CRUSHING_HOLD · STRANGLE_HOLD · PSIONIC_BIND · GARROTE
BEAR_TRAP · STONE_VINE · TREE_OF_LIFE · RECALL · …
```

mishander's fork checks `EFF_PINNED` — one of sixteen. And an effect list still couldn't be
correct, because `Actor.lua:4186` sets `never_move` for **encumbrance**, which is not an effect
at all. A bot that picks up too much loot soft-locks identically.

The predicate ToME's own `move()` gates on (`Actor.lua:1416`) is `self:attr("never_move")`.
One check, all sixteen, plus encumbrance, plus whatever 1.7.7 adds.

**Liveness use is unconditional:** if you cannot move, do not attempt to path. Not a policy —
attempting the impossible is simply a bug. (The same fact *also* feeds §2 as a configurable
risk condition. One signal, two consumers.)

### 1.2 "Cannot act" needs no handling at all

`mod/class/Player.lua`, first line of `act()`:

```lua
function _M:act()
    if not mod.class.Actor.act(self) then return end
```

`Actor:act()` bails at the energy gate after `paralyzed`/`stoned`/`dont_act`/`time_stun`/
`time_prison` zero it. **The player is never prompted, and the bot's superloaded code never
runs.** No spin is possible, and control cannot be handed to a player who equally cannot act.

This asymmetry is the whole point: **movement blocking still grants turns, which is why it
hangs. Act blocking doesn't.**

What *is* worth surfacing is the aftermath — the "attacked 24 times in a row" case, currently
only discoverable from a post-mortem of the log. `game.turn` counts engine ticks, not player
turns: an actor needs 1000 energy to act and receives 100 per tick (mod/class/Game.lua:80,
engine/GameEnergyBased.lua), so **it advances by 10 per player turn at normal speed**, more
slowly for a fast character and faster for a slow one. (An earlier draft of this section said
1000 per game turn; that is the energy figure, not the tick count, and the harness measured the
truth — `Assert-Turns -AtLeast 10` is "at least one turn".) The gap is measurable on the first
real turn after it:

```lua
{ code = "BLACKOUT", label = "Turns lost while unable to act", default = "WARN",
  detect = function(p, ctx) return ctx.turnGap > 10 end,   -- more than one player turn
  msg    = "lost %d turns while unable to act" }
```

That belongs in §2, not §1 — it's information for a decision, not a liveness guard.
`LIFE_BIGLOSS` already covers much of it incidentally, since the remembered life predates the
gap.

### 1.3 Progress invariant, not iteration caps

**Status: built (#13, 2026-08-23).** This section describes what is in
`src/superload/mod/class/Player.lua`; the regression is `tools/scenario-liveness.ps1`.

v1's hang guard, `Player.lua:857`:

```lua
if _M.skoobot.tempActivation.turnCount > 1000 then
    aiStop("#LIGHT_RED#AI Disabled. AI acted for 1000 turns. Did it get stuck?")
```

A magic number counting **invocations, not progress**. Three problems:

- A genuinely productive 1000-turn run trips the same wire as a spin. The message even asks
  the user to guess which happened.
- It only counts outer iterations. A spin *inside* one `act()` call is invisible to it.
- 1000 wasted iterations still happen before it fires.

yura9111's PR to the original — a counter of consecutive `autoExplore()` calls, stopping at
100 — had the same shape and the same flaws, and was rejected on review for them
([salvage-yura9111.md](salvage-yura9111.md)). The invocation-count design is now rejected
twice, once by each of its authors' defect classes.

**Better primitive: did game time advance?** Every bot iteration should consume energy. If
`game.turn` is unchanged after an iteration, no game time passed — by definition nothing
happened, whatever the code thinks it did.

What "iteration" means here is fixed by the engine. The per-turn driver, `playerActions()`,
runs once each time the engine hands the player a turn with the bot active and the player
neither running nor resting — from the `Player:act` wrapper, or from the `ACTION_DELAY` timer.
A run or a rest that the bot starts steps *inside* the engine's own `act()` and re-enters the
driver only when it ends; a nested `act()` the bot itself calls (auto-explore does) re-enters
it at once, in the same frame. So a spin of any shape — the pinned auto-explore that stops
without moving and is started again, a talent the game refuses every time, a move that never
lands — is a sequence of driver entries at one `game.turn`, nested or not.

```lua
-- Checked BEFORE the decision, from the second iteration of an activation
-- on; the first creates the counters. An unchanged game.turn means the
-- previous iteration spent no game time.
local act = bot.activation
if act then
    act.iterations = act.iterations + 1
    if game.turn == act.last_turn then
        act.stalled = act.stalled + 1
    else
        act.stalled = 0
        act.last_turn = game.turn
    end
    if act.stalled >= STALL_LIMIT then
        chan.info("[Liveness] no progress in %d iterations: %s", act.stalled, bot.inspect())
        return stop(notice.STOPPED, ("no progress in %d iterations (state: %s) -- please report this")
            :format(act.stalled, aiStateString()))
    end
end
skoobot_act()
```

`STALL_LIMIT` is **8**, a named constant with its reasoning beside it. One no-op iteration is
legitimate — auto-explore refuses to start because something just came into view, and the
next iteration fights — and nothing legitimate needs more than two; every no-op is a whole
decision on a frame the player is waiting for, so the limit is small, and eight leaves room
for a sequence nobody has thought of while still firing inside one keypress. The counters
live on the activation, so a restart by the player starts them clean.

This catches the general class rather than enumerated instances — the pinned freeze, the
explore soft-lock, encumbrance, and the next one nobody has hit yet. Capability checks (§1.1)
remain the cheap early-out that avoids reaching the guard at all; the invariant is the
backstop that makes "we missed a case" survivable instead of fatal. `scenario-liveness.ps1`
proves both halves: with the `never_move` guard bypassed for the bot alone (the engine's own
`move()` still refuses), the T-012 freeze trips the invariant in eight iterations and zero
game turns with `SAI_STATE_EXPLORE` in the reason; and a healthy run on the fixture — rest,
explore, fight, restarted after each legitimate hand-back — advances 1000+ game turns without
it firing.

**There is no absolute ceiling.** The design's objection to v1 was that a productive run
tripped a wire meant for a spin; any ceiling on iterations or turns would be that wire again,
and the progress invariant already bounds the only thing worth bounding. A run that is
advancing game time is, by the invariant's definition, doing something, and what it is doing
is the stop conditions' (§2) business, not liveness's.

**`THINK_LIMIT` (25) stays, as the inner guard.** It counts `skoobot_act()` re-entries within
one iteration — the REST-to-EXPLORE hop when there is nothing to rest for, HUNT-to-EXPLORE,
FIGHT-to-REST, `checkForAdditionalAction` after a free action — which happen at one
`game.turn` and are invisible to the invariant until the iteration ends. A productive chain is
two or three deep; 25 without settling is real spinning inside one decision, and it is caught
before it can overflow the stack. It measures a different thing from the invariant and does
not count player turns, so it has neither of v1's flaws.

Reporting the AI state in the stop message turns each trip into a bug report rather than a
shrug — and the full `inspect()` line goes to `te4_log.txt` through the debug channel (#46) at
info, so it is there at the default level, while the player is told once by the notice (#58).

---

## 2. Model validity — configurable, and deliberately so

### 2.1 What the stop conditions are actually for

The bot's threat model is `evaluatePowerLevel()` — a heuristic over offensive and defensive
stats. **It does not model impairment.** Under stun in 1.7.6 the character has −50% damage,
−50% movement speed, and three random talents on cooldown, and the power figure reflects none
of it.

So the bot will read a fight as winnable when it is not. The stop is not saying *"I would
hang"*; it is saying **"my model is out of its validity range here — hand this to a better
model, which is the player."**

That is a sound engineering decision, and it should be preserved. A heuristic that knows where
it stops being trustworthy is more valuable than one that extrapolates confidently.

**Correction to the earlier draft:** stunned and confused should **not** be quietly demoted to
score inputs. They may graduate to that later *if* the scorer earns it (§2.3), but until it
demonstrably models impairment, an honest boundary beats a confident guess.

### 2.2 Why WARN / STOP / IGNORE must stay per-condition

The tri-state is not a convenience. It carries knowledge the bot cannot derive:

- **Risk appetite** varies by player and by run. A one-life character and a throwaway test
  character want different answers to the same situation.
- **Class semantics invert the meaning of a condition.** A **Solipsist** wants `ASLEEP` set to
  `IGNORE` — sleep is *beneficial* for them. No universal heuristic gets that right, and
  hardcoding a class list would rot the moment a new class or addon changed the assumption.

The `lucid_dreamer` term in v1's ASLEEP check was an attempt to encode exactly this in code.
It was also the line that carried the precedence bug, so the check never fired — meaning the
mechanism intended to serve Solipsists was inoperative, and the `IGNORE` policy was doing the
work regardless. That is an argument for policy over cleverness: **the configuration was right
and the code was wrong.**

Keep the tri-state exactly as designed, including the WARN acknowledgement that auto-rearms
when the condition lifts.

### 2.3 The tempo problem, stated honestly

Priority-list talent selection cannot express the following:

> One turn of stun remaining. The best long-cooldown attack just came off cooldown. Correct
> play: shield or heal this turn, fire the big hit next turn at full damage. Naive play: fire
> it now at −50%.

This is a **tempo** decision, and a descending-priority list is structurally incapable of
representing it — priority encodes *what is best*, never *when*. Solving it properly means
lookahead over effect durations and cooldowns, which is a planner, not a heuristic.

Three honest options, in increasing cost:

1. **Stop and let the player play it.** What v1 does. Costs nothing, always correct, gives up
   automation exactly where automation is hardest. This stays the default.
2. **Per-talent suppression flag.** Since #56 each rule is an entry table in an ordered
   section (`data/rules.lua`), and extra fields on an entry survive every move; a flag —
   *"hold while impaired"* — lets the player encode "don't waste Execution while stunned"
   declaratively. Consistent with the existing philosophy of pushing
   irreducible judgement to the player rather than guessing. Only useful to players who set
   stun to `WARN`/`IGNORE`, so it is a refinement, not a replacement.
3. **Effectiveness-aware scoring.** T-020 territory, and genuinely hard: it needs expected
   value over remaining effect duration. Not a v0.1 goal, and possibly never worth it.

Do not let option 3's existence justify weakening option 1 before it is built.

---

## 3. Framework mechanics

### 3.1 Definition list

One entry is the single source of truth for a condition's UI, detection, default policy, and
capability implications.

```lua
CONDITIONS = {
  { code = "CANNOT_MOVE", label = "Immobilised", default = "WARN",
    blocks = { move = true },
    detect = function(p) return p:attr("never_move") end,
    msg    = "immobilised and unable to move" },

  { code = "ASLEEP", label = "Asleep", default = "WARN",
    -- ToME's own idiom, Actor.lua:1402/4448/5800. v1 wrote
    -- `not p.lucid_dreamer == 1`, always false. See v1-latent-bugs.md.
    -- Solipsists should set this to IGNORE; sleep is good for them.
    detect = function(p) return p:attr("sleep") and not p:attr("lucid_dreamer") end,
    msg    = "asleep" },

  { code = "STUNNED", label = "Stunned", default = "WARN",
    -- Model-validity boundary, NOT a liveness guard. A stunned character can
    -- act; evaluatePowerLevel() just cannot be trusted while they are. See §2.1.
    detect = function(p) return p:attr("stunned") end,
    msg    = "stunned -- threat estimate unreliable" },
  -- …
}
```

Drift between list and detection is what broke v1: `DEBUFF_ASLEEP` rendered as a working
toggle while its detection was dead code, with no mechanism to notice. One entry makes that
structurally impossible.

### 3.2 Reconcile on access

Definitions live in code. Only the player's chosen `stoptype` persists.

```lua
-- Idempotent, unguarded by a "migrated" flag: at ~15 entries it is cheap
-- enough to run every access, so a hand-edited or half-written save repairs
-- itself. No version stamps -- self-healing convergence beats ordered
-- migrations.
local function reconcileConditions(player)
    local policy = {}
    for _, e in ipairs(player.skoobot_conditions or {}) do policy[e.code] = e.stoptype end

    local out = {}
    for _, def in ipairs(CONDITIONS) do        -- definitions drive; orphans fall away
        out[#out+1] = { code = def.code, label = def.label,
                        stoptype = policy[def.code] or def.default }
    end
    player.skoobot_conditions = out
    return out
end
```

Handles all three cases: definitions the save lacks are added at their current default;
orphans whose definition is gone are dropped (otherwise a retired condition lingers as a
phantom toggle controlling nothing — the ASLEEP failure in miniature); and labels are always
current.

`getStopCondition` must additionally **fail closed**, returning the definition's default
rather than `nil`, so a lookup bug degrades to "used the default" instead of crashing mid-run.

### 3.3 Incidental fix

`tryStop` shadows its own parameter — a condition *code* named `stoptype`, then overwritten by
the actual stoptype — so the diagnostic prints `Ignoring stop condition: IGNORE` instead of
naming the condition. `luacheck` flags the shadowing.

---

## 4. Migration

Nothing to migrate from v1. Separate addon, separate `short_name`, no shared state.
