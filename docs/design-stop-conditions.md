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
only discoverable from a post-mortem of the log. `game.turn` advances by 1000 per game turn,
so the gap is measurable on the first real turn after it:

```lua
{ code = "BLACKOUT", label = "Turns lost while unable to act", default = "WARN",
  detect = function(p, ctx) return ctx.turnGap > 1 end,
  msg    = "lost %d turns while unable to act" }
```

That belongs in §2, not §1 — it's information for a decision, not a liveness guard.
`LIFE_BIGLOSS` already covers much of it incidentally, since the remembered life predates the
gap.

### 1.3 Progress invariant, not iteration caps

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

**Better primitive: did game time advance?** Every bot iteration should consume energy. If
`game.turn` is unchanged after an iteration, no game time passed — by definition nothing
happened, whatever the code thinks it did.

```lua
-- Liveness invariant: an iteration that does not advance game.turn did nothing.
-- N consecutive no-ops is a livelock regardless of cause -- including causes
-- not yet imagined, which is the point. Small N, because there is no legitimate
-- reason to burn several iterations on zero game time.
if game.turn == ctx.lastTurn then
    ctx.stalled = ctx.stalled + 1
    if ctx.stalled >= STALL_LIMIT then
        return aiStop(("#RED#AI stopped: no progress in %d iterations (state: %s)")
                      :format(ctx.stalled, aiStateString()))
    end
else
    ctx.stalled = 0
end
```

This catches the general class rather than enumerated instances — the pinned freeze, the
explore soft-lock, encumbrance, and the next one nobody has hit yet. Capability checks (§1.1)
remain the cheap early-out that avoids reaching the guard at all; the invariant is the
backstop that makes "we missed a case" survivable instead of fatal.

Reporting the AI state in the stop message turns each trip into a bug report rather than a
shrug.

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
