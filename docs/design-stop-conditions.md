# Design: liveness vs. model validity

**Status:** built (§1.3 #13, §3 #12, §5 #11) · **Task:** T-026 (#12), T-027 (#13), T-020 (#11) · **Date:** 2026-08-21, revised 2026-08-23
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
2. **Per-entry hold flag — built (#15, 2026-08-23).** Since #56 each rule is an entry table in
   an ordered section (`data/rules.lua`), each placement its own table, and extra fields on an
   entry survive every move; the flag is one such field, `hold = true`, on a **Combat**
   placement only, and needed no migration. What was built, and where it stops short of the
   paragraph above:
   - **Toggle.** In the talent screen, Space on a Combat row, or *Hold while impaired* in the
     row's action menu. The row shows `, held` in its Kind column and the pane carries the
     flag's prose (`rules.HOLD_DESCRIPTION`). An add or a move into another section drops the
     flag there; it belongs to the Combat placement. Both entry kinds take it — a talent, an
     item, or a flee action (#59).
   - **Read.** `getCombatRotation()` in the act loop leaves a held entry out while the
     character is **impaired** — `attr("stunned")`, `attr("dazed")`, `attr("confused")` or
     `attr("frozen")`, the capability counters, never `== 1` — so the rotation falls through to
     the next entry exactly as it does for a talent on cooldown. Only Combat reads it; the
     Damage Prevention and Recovery triggers do not. It also returns **how many** entries it
     held, because holding is a third way for the rotation to come out empty and the stop that
     reports an empty rotation could name only two — a player who set the debuff to IGNORE and
     held every row was told "none configured, or all on cooldown", both untrue (#75).
   - **Not "one turn of stun left".** The paragraph above describes a tempo decision keyed on
     the *remaining* duration. The built form is the simple one: any impairment holds. It errs
     toward holding — a held hit waits for the whole stun rather than firing on its last turn
     — because reading remaining durations per effect is the lookahead this section says a
     heuristic should not pretend to have. The remaining-duration reading is filed as its own
     issue (a refinement on top of this flag, after the condition framework #12 gives it the
     effect list), not carried here as a to-do.
   - **Who it is for.** Only a player who has set `DEBUFF_STUNNED` (or DAZED / CONFUSED /
     FROZEN) to `WARN` or `IGNORE` ever sees it act: at `STOP` the bot has handed back before
     the rotation runs. The flag's prose says so. It is a refinement of option 1, not a
     replacement, and the default stop is untouched.
   - **Verified** by `spec/rules_spec.lua` (the flag survives normalize, a v1 migration, a
     reposition, a shift, a move out and back, and lands on its own table on an add) and
     `tools/scenario-hold.ps1` (on the fixture: a held talent first and an unheld second;
     stunned with the stop at `IGNORE`, the bot would use the second; the stun gone, the
     first).
3. **Effectiveness-aware scoring.** T-020 territory, and genuinely hard: it needs expected
   value over remaining effect duration. Not a v0.1 goal, and possibly never worth it.

Do not let option 3's existence justify weakening option 1 before it is built.

---

## 3. Framework mechanics

**Status: built (#12, 2026-08-23), on branch `issue-12`.** This section describes what is in
`src/data/conditions.lua` and how `src/superload/mod/class/Player.lua` consumes it; the
unit pins are `spec/conditions_spec.lua` and the in-game regression is
`tools/scenario-conditions.ps1`. The proposal this replaced is in the branch's history.

### 3.1 Definition list

One entry is the single source of truth for a condition's menu label, detection, default
policy, where the act loop consults it, what it says, and what capability it takes away.

```lua
{ code = "DEBUFF_DAZED", label = "Debuff: DAZED", default = "WARN",
  category = "debuff", site = "turn", blocks = { move = true }, blocked = "dazed",
  detect  = function(p) return counter(p, "dazed") > 0 end,
  message = "you are dazed" },
```

Drift between list and detection is what broke v1: `DEBUFF_ASLEEP` rendered as a working
toggle while its detection was dead code, with no mechanism to notice. One entry makes that
structurally impossible: the act loop walks the list, so an entry without a detector cannot
fire and a detector without an entry cannot exist.

**Two kinds of entry share the list**, told apart by `default`:

- **Policy entries** have a default of WARN / STOP / IGNORE. They are what the player sees in
  *Activate/Deactivate Bot Stop Conditions* and what the save keeps. Their codes, labels,
  defaults and **order** are v1's thirteen, unchanged — `DEBUFF_*` ×5, `LIFE_*` ×2,
  `DIALOG_LORE`, `TERRAIN_GLOWING_CHEST`, `SCOUTER_*` ×4 — so the menu and the save format did
  not change. `DEBUFF_STUNNED` stays a model-validity stop (§2.1), WARN as v1 shipped it.
- **Liveness entries** have no default and no policy: `CANNOT_MOVE` (`attr("never_move")`)
  and `ENCASED` (`attr("encased_in_ice")` or `attr("encased")`). They are never in the menu or
  the save, because §1 says liveness is not configurable; they exist so the capability they
  take away is declared once, with its detector, and read through `capabilities()`.

**Detection is by capability, as a counter.** Every status attribute is an additive
temporary value — two sources of stun make 2, confused is a 0–50 percentage — so every test
is `> 0` or truthiness, never `== 1`. The port carried v1's `== 1` tests marked `-- v1:` until
here; a doubly stunned or a 30%-confused character read as unafflicted. `DEBUFF_ASLEEP` is
ToME's own gate, `attr("sleep") and not attr("lucid_dreamer")`, so a Solipsist dreaming
lucidly is not asleep by the bot's reading at all.

**`site` says where an entry is consulted**, so the explore checks keep their place and
order and a terrain condition is never evaluated mid-fight:

| site | consulted | entries |
|---|---|---|
| `turn` | every decision, before the state branches, in list order | the five debuffs, `LIFE_LOWLIFE` (only with a hostile in view), the four `SCOUTER_*` |
| `explore` | the EXPLORE branch, after the air checks, before the level-change and move checks | `TERRAIN_GLOWING_CHEST`, at `HANDED_BACK` |
| `loop` | the per-turn survival initialiser, where the life delta is computed | `LIFE_BIGLOSS` (with `tryStop`, as v1: a WARN fires every big-loss turn) |
| `dialog` | the open-dialog check, by code; no detector | `DIALOG_LORE` |

One deliberate change of order: v1 checked `LIFE_LOWLIFE`, then the four power conditions,
then the debuffs; the loop checks the list in the menu's order, debuffs first. When two
conditions hold at once the bot stops either way; only the reason named differs.

**`ctx`** is what a detector is given besides the actor — the hostile count, the loop scratch
with the rank-weighted enemy figures (#62), the life-scaled own power, `cfg`, the chest scan
— built once per decision by `conditionContext()`. The module reads nothing else, which is
what lets the spec drive every predicate with a fake actor and a fake context.

**`blocks` and the act loop's response** — the half of #7's split that landed here. The loop
takes the union over every *detected* entry that declares a block, policy or not, through
`conditions.capabilities()`, and each state has a defined response:

| blocked | EXPLORE | FIGHT |
|---|---|---|
| `move` (dazed, frozen, asleep, `never_move` from any source) | hands back `Stopped: cannot move (…)` instead of calling auto-explore — the T-012 freeze | the rotation still runs — **a pinned character attacks what is next to it** — and only when no talent reaches does it hand back `Cannot act: cannot move (…), and no Combat talent reaches <name>`, instead of attempting the step the engine would refuse |
| `act` (asleep) | as `move` | hands back `Cannot act: cannot act (asleep)` before the rotation |
| `target` (encased in ice: talents reach only the ice) | as `move` | hands back `Cannot act: cannot target anything (encased in ice)` |

The policy and the block are two consumers of one signal (§1.1): `DEBUFF_DAZED` at IGNORE
still cannot explore, because dazed sets `never_move` and the block is consulted whatever
the policy says. The message names the specific conditions (`dazed`, `asleep`) and falls
back to the generic entry's words, `pinned, held, or overloaded`, only when nothing named
explains the block — so the T-012 and stop-notice scenarios read the same text they did.

Not built, on purpose: `BLACKOUT` (§1.2) — no turn-gap reading exists yet, and the entry
would be a policy condition added to the menu, which this issue kept unchanged. It is the
first candidate for a fourteenth entry.

### 3.2 Reconcile on access

Definitions live in code. Only the player's chosen `stoptype` persists. Built as T-019
(#52) and moved into the module as `conditions.reconcile(list)`:

```lua
-- Idempotent, unguarded by a "migrated" flag: at ~15 entries it is cheap
-- enough to run every access, so a hand-edited or half-written save repairs
-- itself. No version stamps -- self-healing convergence beats ordered
-- migrations. Rebuilt IN PLACE, so anything holding the table sees it.
function M.reconcile(list)
    if M.isCurrent(list) then return false end
    local chosen = {}
    for _, v in ipairs(list) do
        if type(v) == "table" and v.code and M.STOPTYPES[v.stoptype] then
            chosen[v.code] = v.stoptype
        end
    end
    for i = #list, 1, -1 do list[i] = nil end
    for i, def in ipairs(M.policy()) do        -- policy entries drive; orphans fall away
        list[i] = { label = def.label, code = def.code, stoptype = chosen[def.code] or def.default }
    end
    return true
end
```

Handles all three cases: definitions the save lacks are added at their current default;
orphans whose definition is gone are dropped (otherwise a retired condition lingers as a
phantom toggle controlling nothing — the ASLEEP failure in miniature); and labels are always
current. Liveness entries are never written, since they have no policy to keep.

`getStopCondition` additionally **fails closed**, returning a STOP entry rather than `nil`
for a code no definition carries, so a lookup bug degrades to "stopped" instead of crashing
mid-run, and logs the code.

### 3.3 Incidental fix

`tryStop` shadowed its own parameter in v1 — a condition *code* named `stoptype`, then
overwritten by the actual stoptype — so the diagnostic printed `Ignoring stop condition:
IGNORE` instead of naming the condition. Fixed in the port; the parameter is `code`.

## 4. Migration

Nothing to migrate from v1. Separate addon, separate `short_name`, no shared state.

---

## 5. Scored situational evaluation

**Status: built (#11, 2026-08-23), on branch `issue-11`, stacked on `issue-12`.** This section
describes `src/data/score.lua` and how the act loop follows it; the unit pins are
`spec/score_spec.lua`, the in-game regression `tools/scenario-scoring.ps1`, and the parity net
`tools/scenario-salvage-power.ps1`, whose numbers did not move.

### 5.1 The principle

The flat list can say warn / stop / ignore per named condition. It cannot say *how bad* the
situation is, or what to do about it short of stopping. The score says both — and **the list
stays the input, the score is the evaluation**: the four `SCOUTER_*` conditions keep their
codes, labels, WARN / STOP / IGNORE and their place in the menu; what changed is that their
detectors read a flag off the score instead of comparing a threshold each.

### 5.2 Inputs, knobs, terms

| input | from |
|---|---|
| own power, scaled by the life left (#62 item 3) | `score.ownPower(power.level(p), life, max_life)` |
| each visible hostile's power × its rank weight (#62 item 2), rank, distance, name | `spotHostiles` records them on each entry |
| count | `#hostiles` |
| what the player cannot do — move / act / target | `conditions.capabilities()` (§3.1), as the blocking conditions' words |
| life and air fractions; whether life fell this turn | the player; the loop scratch's delta |
| which power flags the player has *accepted* | a condition at IGNORE, or a WARN that fired and was restarted past |

The player's knobs are the **parameters**, replaced by nothing. Each is the denominator of
one term, so a term of 1 is exactly that knob's limit, 0.5 is half-way to it and 3 is three
times over:

| term | ratio | knob |
|---|---|---|
| `individual` | strongest weighted enemy / limit | `MAX_INDIVIDUAL_POWER` |
| `stronger` | strongest weighted enemy / (own + margin) | `MAX_DIFF_POWER` |
| `crowd` | weighted sum / (own + margin) | `MAX_COMBINED_POWER` |
| `count` | hostiles / limit | `MAX_ENEMY_COUNT` |
| `unseen` | (1 − life) / (1 − ratio), only when damage arrived with nothing in view | `IGNORE_DAMAGE_HEALTH_RATIO` |

**The score is the largest term** — how far past the worst of the player's limits the
situation is, in [0, ∞). A knob of zero makes its term infinite over anything ("threat over
any limit"). `unseen` is the T-011 threshold as a term: with nothing in view, the one threat
the explore branch faces is damage from a source it cannot see, and the ratio says how far
below the ignore line the character has fallen.

**The flags are v1's comparisons, made in the scorer unchanged** — `max > MAX_INDIVIDUAL_POWER`,
`max > own + MAX_DIFF_POWER`, `sum > own + MAX_COMBINED_POWER`, `count > MAX_ENEMY_COUNT` — so a
knob keeps meaning exactly what the options tab says it means, and the salvage scenario's
measured numbers hold to the decimal. The `EXPLORE_DAMAGE` flag is the T-011 stop. Each set
flag carries v1's wording with the figures compared (`details`), and every stop reason now
ends ` -- threat 2.3`.

**Distance changes no term, on purpose.** A boss at the edge of view is the same boss two
turns later with less room, and the stop should come at the edge. Distance decides posture.

### 5.3 Posture

The recommendation, with its reasons as strings:

| posture | when | the FIGHT branch does |
|---|---|---|
| `handback` | a flag the player has **not** accepted is set; or the player cannot act or target (§3.1 blocks); or own power is 0; or air is under 25% | stops with the reasons joined — in practice the first case never reaches FIGHT, because the turn-site condition stopped the bot already with the same reason |
| `retreat` | an accepted single-enemy flag (`individual` or `stronger`), the enemy **not adjacent**, the player able to move, and fewer than `RETREAT_LIMIT` (5) steps already taken in a row — against something as fast as the player a chase holds its distance for ever, and every step is a turn not spent fighting | one flee step from the strongest -- by the WEIGHTED figure since #80, the same one this table is written in (#59's `fleeStep`) -- before the rotation; with no step, the rotation as usual. The activation counts the steps; any other posture starts the count over |
| `hold` | an accepted crowd or count flag, and no single-enemy one | the rotation on what is in reach; with nothing in reach, **waits a turn** (`Actor:waitTurn`, a real action for the progress invariant) instead of walking into the crowd |
| `fight` | nothing over a limit; or the threat is over a limit, accepted, and already adjacent — a step away from something next to you gives it a free hit; or over a limit, accepted, and the player pinned | the rotation, then the approach, as v1 |

So with the defaults — every `SCOUTER_*` at STOP — nothing changes in what the bot does: a
flag stops it at the turn site with the figure, the knob and the score in the reason. The
postures matter once the player sets a power condition to **IGNORE** or restarts past a
**WARN**: where v1 then charged, the bot now steps back from a strong enemy it can still get
away from, and waits for a crowd to come to it.

**Not inputs, deliberately:** stunned and confused (§2.1 — the model does not know what they
cost, so they stay a stop, not a term); the remaining duration of anything (§2.3).

### 5.4 What the tooltip shows

Since #62 the checks compared a life-scaled own power and a rank-weighted enemy power while
the tooltip still showed the raw heuristic, so the figure in a stop reason could not be found
on screen. The tooltip now shows both, from the scorer's two helpers so they cannot drift:

```
Power Level: 120 -- counts as 48 to SkooBot (x0.4 normal)
Power Level: 80 -- counts as 52 to SkooBot (at 65% life)
```

The raw number is what v1 showed and what *Maximum Enemy Power* is written against; the
counted one is what the terms and the stop reasons carry. Ctrl still shows the components.

### 5.5 Explicitly out of scope

- **Walking to a glowing chest as a scored objective** (salvage-mishander.md item 9). It did
  not fall out of the scorer — the score evaluates threat, and a chest is an opportunity with a
  path and a guard check, which is a second kind of objective the loop has no slot for. Its
  own issue.
- **A non-linear life curve** for own power. The terms are ratios of that figure, so a curve
  there re-tunes every knob under the player; if it comes, it comes with a migration of the
  defaults.
- ~~**Weighing the strongest for the retreat step by the weighted figure.**~~ **Done (#80).**
  `fleeTarget` from `strongest` ranked by `bot.power`, the raw heuristic, as #59 documented,
  while `score.figures.strongest` ranked by the weighted figure and the `retreat` posture
  fired that very step. It now reads `h.power` — the weighted figure spotHostiles records on
  every entry — with the same `or 0` and the same nearer-on-tie rule as `score.lua`, so the
  two cannot pick different enemies.
