# The build plan

How the bot spends a character's points, and why the obvious design does not work. Issue **#88**.

§1 is read out of ToME 1.7.6's own source rather than inferred, because the shape of the
problem — five pools on four different schedules, two of which are contingent — is what
decides everything after it.

**Finalized 2026-08-28. Nothing here is built yet.** The owner's decision of 2026-08-25
settles the interface (an in-game editor, in the style of the talent screen); the decisions of
2026-08-26 settle the gestures (stats as a standing policy; order captured by doing; escort
rewards as pools). This document settles the *model* the editor edits and the semantics the
bot applies, and closes the three questions the first pass (`12f221f`) left open — §8 records
the answers. The first pass also carried one load-bearing factual error about the engine,
corrected in §1.3: **no engine routine accounts for the point pools; every spend path in the
game is caller-side.** The safety rule survives, one layer higher than first stated.

---

## 1. What the engine actually does

### 1.1 There are five pools, not one

`mod/class/Actor.lua:3949`, the player's own level-up. Starting values are at `:191`.

| Pool | Field | At birth | Per level | Extra |
|---|---|---:|---|---|
| Stat points | `unused_stats` | 3 | `stats_per_level` (3) + rank adjust (0 for the player, rank 3) | **+10 at level 50** |
| Class points | `unused_talents` | 2 | +1 | **+1 more** on every 5th level; **+3 at 50** |
| Generic points | `unused_generics` | 1 | +1 | **−1** on every 5th level; **+3 at 50** |
| Category points | `unused_talents_types` | 0 | — | at **10, 20, 34**, then `(level−4) % 30 == 0` past 50 (64, 94, …) |
| Prodigies | `unused_prodigies` | 0 | — | at **25 and 42** |

Races can add more (`extra_talent_point_every` / `extra_generic_point_every`, `:3956` —
Cornac gets both every 10), birth descriptors add to or override the birth values (Adventurer
starts with **7** category points, `data/birth/classes/adventurer.lua:95-99`, `copy_add`;
Cornac adds 1), and points arrive from non-level sources too (the Infinite Dungeon challenge
reward can roll a category point or a prodigy point, `mod/class/GameState.lua:3742-3752`).
The plan never assumes it knows the schedule; it only ever reads the pools.

Two things fall straight out of that table and neither is obvious:

- **A level is not a unit of currency.** On level 5 the character gains two class points and
  *no* generic point. A plan expressed as "at level 5, take X" is expressed in the wrong units.
- **The pools are not interchangeable.** A generic point cannot buy a class talent. Any model
  with a single ordered list of "what to buy next" is wrong before it starts, because the next
  thing the player wants may not be payable with the point that just arrived.

### 1.2 Two more pools arrive contingently

- **Escort rewards.** `mod/class/EscortRewards.lua`'s `listRewards()` is a **static table
  keyed on `reward_type`** — eight kinds: `warrior`, `divination`, `survival`, `alchemy`,
  `sun_paladin`, `defiler`, `temporal`, `exotic` (`:284-453`). Each kind's menu is fixed but
  the menus are not uniform: 2–4 talent rows, 2 stats (`exotic`: all six), **and 1–2
  talent-category rows on 7 of 8 kinds** — often the most valuable reward, and one the first
  pass missed entirely. Five kinds carry an **antimagic variant** (its own talents, stats, and the
  only `saves` rows in the table). The variant is selected not by the character's antimagic
  status but by the **betray-to-Zigur choice in the start chat** (`data/chats/escort-quest.lua:26`
  reads `quest.to_zigur`); character status only gates which choices the start chat offers, and
  a character with the Zigur birth option can reach either variant per escort. All amounts are
  static (+5 stats, +12 saves, +1 talent level, mastery 1.0) — nothing is level-scaled — so an
  editor can show the real rows ahead of time. `getGiver()` draws a kind at random per escort
  (`chance = 70`, except `temporal` and `exotic` at 30; the givers' `classes` fields are dead
  data nothing reads, so any class can draw any kind) with no
  `unique` flag on any base kind, so kinds repeat and the count over a run is unbounded. Hooks
  (`EscortRewards:givers`, `:rewards`) can rewrite both tables, so menus are enumerated from
  `listRewards()` at runtime, never baked in.
- **One-off permanent choices**, of which Cursed Fate (#191) is the known case: accepting costs
  2 Willpower and grants a talent tree plus a point in `T_DEFILING_TOUCH`. #191 records that a
  build plan is where such a decision most naturally belongs.

**There is no ordinal to attach a preference to.** No "my third escort". Only "any escort of
this kind, in this order" — which is what makes these *pools* rather than plan entries.

### 1.3 Where points are actually spent — the correction

The first pass claimed the pool decrements live "inside the engine's own `learnTalent` /
stat-increase paths", so the plan could call the engine and let it do the accounting. **That
is false, and three independent source reads agree.** The lines it cited
(`Actor.lua:836/:861/:881/:902`) are inside **`Actor:useBuildOrder()`** (`:823-911`) — ToME's
own dormant build-order follower, a *caller* — and every spend path in the game does the same
thing:

| Caller | Checks it runs | Then |
|---|---|---|
| `LevelupDialog:incStat` (`:259-285`) | pool > 0, soft cap, hard cap | `incStat(sid, 1)`; `unused_stats -= 1` |
| `LevelupDialog:learnTalent` (`:378-431`) | pool ≥ 1, `canLearnTalent`, raw < `getMaxTPoints` | `learnTalent(t_id, true)` — **force**; pool −= 1 |
| `LevelupDialog:learnType` (`:433-495`) | pool > 0, tree `min_lev`, mastery-once guard | unlock or +0.2 mastery; pool −= 1 |
| `Actor:useBuildOrder` (`:823-911`) | the same caps and `canLearnTalent` | same shape, manual decrements |

The engine mutators (`ActorTalents:learnTalent`, `ActorStats:incStat`,
`learnTalentType`/`setTalentTypeMastery`) never touch a pool, and several checks the game
enforces on players exist **only** in the callers:

- **Engine-enforced** (survives a direct, unforced engine call): `canLearnTalent` — stat,
  level, special, and talent-dependency requirements per rank (`engine/interface/
  ActorTalents.lua:742-806`) — and the stat definition clamp (1..100). `learnTalent(tid, true)`
  **skips all of it**.
- **Caller-enforced only**: the pool balance itself; the talent rank cap (`t.points` /
  `getMaxTPoints` — nothing in the engine checks it); the stat soft cap
  `base ≥ level*1.4 + 20` and hard cap `isStatMax` / `base ≥ 60 + max(0, level−50)` — both
  compare the **base** stat (`getStat(sid, nil, nil, true)`), so gear and escort bonuses never
  consume headroom; the once-ever mastery bump per tree (`__increased_talent_types`); tree
  `min_lev`; the two-inscription-slot ceiling.

So the honest, implementable rule — the one every caller in the game already follows, and the
one the plan follows:

> **The plan replicates the module's canonical spend sequence: caller-side guards (the
> dialog's full check set), engine mutation, caller-side decrement of exactly what was
> spent.** A plan that skipped the guards could buy things the game says no to; a plan that
> forgot the decrement would mint points. Neither is negotiable.

`useBuildOrder` is both the precedent and the cautionary tale: it proves the sequence and the
walk-and-skip semantics in shipped engine code, and it omits `min_lev`, uses bare `t.points`,
and never starts cooldowns — the dialog is the parity target, not it. Where it and the dialog
disagree, the plan sides with the dialog (§4.3).

---

## 2. Why the naive design fails, measured

**#190 is the evidence, and it is not a small miss.** `sk.autoSpend()` (#158's band-aid) spends
"only into ones that ALREADY have a point", walking the **Combat rotation** for candidates. So:

- Recovery, Damage Prevention and Sustain rows are unreachable from it. **A heal, a shield or a
  sustain has never received a talent point in any sweep this project has run.**
- Generic trees are almost never in Combat, so the generic pass iterates a Combat-only list.
  **24 of 28 sweep-17 runs left both generic points untouched**, and every one of the 28
  finished its first allocation with points still unspent.

Two conclusions the design has to carry:

1. **The plan is keyed on talent ids, independent of the rotation.** What the bot *fights* with
   and what it *invests* in are different questions, and conflating them is exactly the bug.
2. **"Where a point already sits" is not a preference.** It is the absence of one.

---

## 3. The model

### 3.1 A plan is per-pool ordered preference, re-satisfied — not a script

The central decision, and the one everything else follows from.

Points do not arrive one level at a time in order. A quest reward can skip the character ahead;
an escort can hand over a stat mid-floor; level 5 grants two class points and no generic. And
talents carry hard level and prerequisite requirements, so **the next entry in a recorded order
may simply be unspendable at the moment a point appears**.

So on every application, for each pool with points in it:

> walk that pool's list in order and spend on the **first entry whose requirements are met
> right now**, rather than blocking on the head of it.

A plan that stalls because entry 4 needs level 10 is worse than no plan, because it stalls
*silently* — which is #190's failure mode in a different costume.

### 3.2 The plan value

One table per character, `data(p).buildplan`, plain strings, numbers and booleans throughout —
the shape the savefile serializer is proven on, and the shape that makes a plan and a template
the same value (§6):

```lua
{ version = 1,
  meta     = { subclass = "Archmage", class = "Mage", name = nil },
  stats    = { paused = false, rows = { {stat="wil", target=20},
                                        {stat="mag", target="max", suggested=true},
                                        {stat="con", target="max", suggested=true} } },
  class    = { paused = false, rows = { {tid="T_FLAME", target=5}, ... } },
  generic  = { paused = false, rows = { ... } },
  category = { paused = false, rows = { {kind="unlock", tree="spell/divination"}
                                      | {kind="mastery", tree="..."} | {kind="slot"} } },
  escort   = { paused = false, kinds = { warrior = {
                 normal    = { rows = { {kind="stat", id="str"} | {kind="save", id="spell"}
                             | {kind="talent", id="T_VITALITY"}
                             | {kind="talent_type", id="technique/conditioning"} } },
                 antimagic = { rows = { ... } } | nil }, ... } } }
```

| Pool | Shape | Why |
|---|---|---|
| **Stats** | ordered rows of `stat → target`, where `target` is a number or `"max"` | One mechanism for every pool. The owner's own policy — *"dump all into main stat, rest into con"* — **is** the two-row list `[{primary,"max"},{secondary,"max"}]`, and a break point is a finite-target row above them. The editor captions rows "break point" / "primary" / "spill" by position; storage knows no such words. See §8 Q3 |
| **Class points** | ordered rows of `talent id → target level` | |
| **Generic points** | its own ordered list, same row shape | A separate pool needs a separate list; see §1.1. A row whose talent's `generic` flag contradicts its list is moved to the tail of the right one on normalize — a kind-mismatched row can never reach the applier |
| **Category points** | ordered rows of **three kinds**: unlock a tree, the once-ever +0.2 mastery on a known tree, or an inscription slot — **one `slot` row per slot, two at most**; the Nth slot row is satisfied when `inscriptions_slots_added ≥ N` | A category point has three legal spends, not one — the first pass modelled only unlocks |
| **Escort rewards** | per `reward_type` — the exact table keys of §1.2 — an ordered preference over that kind's own menu, ids only, **both variants stored** for the five kinds that have one | The variant is a per-escort chat outcome, not a character fact; amounts and labels stay in the game's table, which hooks may rewrite |
| **Prodigies** | one choice at 25, one at 42 | Out of the first pass; see §7 |

Four invariants, all load-bearing:

- **Ids are stable and character-independent**: tid strings (`T_VITALITY`), tree type strings
  (`technique/conditioning`), stat short names (`str dex mag wil cun con`), the eight
  `reward_type` keys, save keys `mental|spell|phys`. Never localized names, never labels,
  never amounts.
- **The plan is stateless.** No cursor, no consumed flags, no stored row status. Whether a row
  is satisfied is always derived from the live actor — this is §3.1 made structural, and it is
  what makes a plan portable (§6).
- **Value-type closure**: a full walk of the plan finds only strings, numbers, booleans and
  plain tables. Normalize drops anything else.
- **Well-formed but unresolvable rows are kept, not pruned** — deliberately diverging from
  `rules.normalize`'s lost-talent pruning. An escort's category reward can add a tree mid-run
  that makes a dormant row live; a temporarily disabled DLC must not destroy authored intent.
  Normalize drops only the structurally malformed; the editor marks the unresolvable.

Access goes through one accessor, `getPlan(p)`, which runs `buildplan.normalize(plan)` on
**every** read — the `stopconditions`/`autotalents` reconcile-on-access pattern, which is what
makes a mid-run addon upgrade safe for saves. An empty plan normalizes to the empty shape and
the applier is then a no-op: **zero behaviour change for every existing save and every
plan-less character.**

### 3.3 Row states are derived, never stored

One pure predicate in `buildplan.lua`, shared verbatim by the applier's walk, the editor's
greying, and the residue report — so the three can never disagree:

- **stale** — the id does not resolve against the game's definition tables (an addon was
  removed). Skipped by the walk, shown with the raw id.
- **satisfied** — the ask is met: raw ≥ target; base stat ≥ break point; tree unlocked
  (`talents_types[tt]` **truthy** — `false` means present-but-locked, which is *not*
  satisfied); mastery already bumped; the Nth slot row once `inscriptions_slots_added ≥ N`;
  escort talent at max. Skipped.
- **inert** — provably never payable for this character. Deliberately narrow: today exactly
  one case, an escort `talent_type` row for a category the character already carries even
  locked (the reward chat filters it forever). Everything unprovable stays pending.
- **pending** — everything else, annotated *satisfiable now* or with the blocking requirement
  (`canLearnTalent`'s own reason, the cap, the `min_lev`). "Blocked" is a detail of pending,
  recomputed every time, never stored.

### 3.4 Capture the order by doing it — where clicks exist

The editor's capture gesture is the game's own level-up screen, per the owner's 2026-08-26
decision, and it covers **class, generic and category points** — the pools where allocation
is a click. A superloaded `LevelupDialog` records committed sessions (§5.2). Two pools have no
click to record and are form-edited rows in the plan dialog instead:

- **Stats.** A click sequence under-determines a standing policy — Mag×4, Con×2 cannot
  distinguish "Mag to 34" from "Mag forever" from cap-riding — and any inference is a guess
  written into a permanent policy. The owner's own framing (stats are *"a standing policy,
  not only an order"*) already concedes this; the recorder logs stat clicks and adopts none.
- **Escort preferences.** The chats arrive contingently in play; the drag-ordered menu rows
  are the only possible gesture, and the 2026-08-26 comment already describes exactly that.

#18's loadout proposal stays a natural *source* to seed from — discovery proposes, the player
fixes the order. The seed is thinner than it sounds: the
proposal contains only already-known, activated talents (no passives, no unknown talents, no
targets, no categories, no escorts), and its order is a **firing** order —
cooldown-descending, #190's "close to backwards for investing". Seeding fills membership;
the order and the targets are the player's. Seeding also proposes the two stat rows —
`primary` from #158's measured heuristic (the stat requirement of the shortest-cooldown
investable rotation talent), then Con — and never a break point, which is *"where the
thinking actually goes"*. Seeded rows carry `suggested = true` and reuse
`loadout.apply`'s never-touch-a-hand-moved-row merge semantics.

### 3.5 Never spend what the plan does not name

From the issue, and it is the safety property that makes the whole thing acceptable to run
unattended. When a pool's list is exhausted or nothing in it is currently satisfiable, the
points stay unspent. They are not scattered into whatever is nearest. The band-aid's spill
tail (`{str,dex,mag,wil,cun}`) exists so the harness never sticks; it is not carried over.

Two refinements the first pass did not carry:

- **A pool can be paused.** `paused = true` makes the walk skip the pool and its arrivals
  never fire the hand-back — the first-class expression of a deliberate hoard, needed because
  application walks full balances (§4.1). One info line per application while a paused pool
  holds points.
- **The escort pools cannot "leave it unspent."** The reward chat has **no decline row** — its
  answers are exactly the generated reward rows. When nothing a kind's list names is on the
  generated menu, the honest fallback is the thing that happens today: hand the chat back to
  the player. The editor says so on any kind whose preference cannot cover its menu.

That leaves the question **#167** asks — what the bot should then do about the "unspent points"
hand-back — and this design deliberately does not answer it. It only removes the reason it
fires in the common case. The seam is kept concrete in §4.4.

### 3.6 Log what was spent

Also from the issue. A plan applied silently is indistinguishable from a plan that did nothing,
which is the lesson of `#127`, `#169`, `#174` and `#178` in four different places this week.
Two sinks, both per spend: `game.log` for the player (the engine's own build-order follower
prints one violet line per spend — the precedent), and `chan.info("[BuildPlan] ...")` for the
scenarios, plus one summary line per application. Stop wording stays in `data/notice.lua`.

---

## 4. What the bot does at the hand-back

### 4.1 Two application sites, per-pool baselines, full balances

The activation snapshots the **five pools individually** (today it stores one sum, which
cannot name the stuck pool and can mask offsetting changes). Application then runs:

1. **At activation start**: apply, then snapshot the post-application balances. Residue at
   start does **not** stop the bot — starting it with known residue is the acknowledgment
   gesture, and it keeps the bot startable for a character whose plan cannot take the points.
   This is also what makes the core workflow close: *hand-back → edit the plan → restart →
   the stuck points are spent.* Only on a **real run**: `bot.query()` promises to act on
   nothing and builds the same activation, so application is gated off `do_nothing` — a
   query must never spend a point.
2. **Mid-activation**, when any pool differs from its snapshot: apply, then hand back **iff
   some pool received an arrival and still holds points after application** — naming the pool,
   the count, and the first blocked row's reason. Otherwise re-snapshot and continue.

The walk spends from **full current balances, not arrivals**. Forced, not chosen: every stop
clears the activation and every restart re-baselines, so arrival-only semantics could never
spend points that survived a stop — precisely the points a mid-run edit exists to redirect.
The baseline gates *stopping*; the plan gates *spending*; a hoard the player wants kept is a
paused pool.

### 4.2 The walk

Pools apply in the order **stats → category → class → generic**, and the four-pool pass
**repeats until a full pass spends nothing** — a fixpoint, not one sweep. The order handles
the common flow (a met stat requirement or a fresh unlock feeds `canLearnTalent` in the same
pass), and the fixpoint handles the reverse flow the order alone would miss: `canLearnTalent`
reads the **full** stat, and a generic spend can raise one — the undead Ghoul passive is a
generic talent that grants Str/Con through `inc_stats` (`data/talents/undeads/ghoul.lua:28-29`),
so a generic point can unblock a class row after the class pass already ran. The fixpoint is
bounded by the points held, and it closes that class of stall for future content too. Escort
pools are not applied here at all: they are consulted by #93 at
reward-chat time. Per pool: scan the rows in order, spend **one unit** on the first pending
row that is satisfiable now, log it, rescan from the head — `useBuildOrder`'s own semantics,
and what lets a newly satisfiable higher row pre-empt the next point — until nothing fires or
the pool is empty. If a spend raises a dialog (a learned tree's chat; #191's shape), the walk
aborts immediately and does not re-snapshot; the existing dialog check stops the bot at the
next decision and the remainder applies at the next activation start.

### 4.3 The spend transaction

Per §1.3, each unit spend is: the dialog's full guard set → the engine mutation (force form,
exactly as the dialog calls it) → the caller-side decrement → the log line. Dialog-parity
details, each a deliberate call:

- **Cooldown starts on a newly learned active** (raw 0 → 1), as the dialog does at finish —
  a just-learned talent must not fire the same turn through the bot's own rotation.
- **`udpateSustains()` once per application** that changed stats or talents, as the dialog's
  finish does — active sustains recompute on the new stats. It toggles sustains off and on,
  which is what the game itself does after every accepted level-up.
- **`on_levelup_close` is left on the engine's default path**: outside the dialog it fires
  per learn, which is how every non-dialog grant in the game (escort rewards included)
  already behaves. The applier does **not** set `is_dialog_talent_leveling` — a lingering
  flag would suppress the callback game-wide, a far worse failure than per-learn firing.
- **`on_levelup_changed` is mirrored** after the walk for each talent whose raw changed, as
  the dialog does; `useBuildOrder` skips it, but the bot is levelling the *player's*
  character.
- **No `no_unlearn` flag on ordinary spends** — plan-learned talents stay unlearnable through
  the game's own rolling window, exactly like hand-learned ones. The applier itself never
  unlearns anything.
- **`__increased_talent_types[tt]` is set by hand on a mastery bump**, as both callers do —
  or the player's own dialog would later permit an illegal second bump.

On the placement: the first pass cited #114 as "keep it out of a re-entrant engine routine",
and #114's own measurement later overturned that reading — the crash reproduced outside
`act()` too. The accurate lesson, and the rule here: **never call an engine entry point whose
in-flight state an engine callback can clear mid-routine** (`restInit` is one; these spend
calls carry no such state machine and are driven by the game's own dialog while the game
runs), and never spend inside `levelup` itself, which runs mid-`gainExp` under an engine
stack that is not prepared for the talent set to change. The hand-back site is the bot's own
decision point, after that stack has unwound — the same place the bot already fires talents.

### 4.4 The residue, and the #167 seam

If points remain and nothing in the plan can take them, the hand-back stands — the player is
told which pool is stuck and why, from the same derived-state predicate the editor shows. The
seam #88 leaves for #167, precisely:

- The residual stays **one bare `stop()`** at the same site — the *mechanism* is unchanged;
  the *text* is not: the reason now names the pool, count and blocker, composed from the
  residue data (`data/notice.lua` still owns the stop's wording home). No condition code is
  added — `getStopCondition` fails closed on an unknown code (STOP + an error log), so the
  `POINTS_UNSPENT` entry is #167's first move, not this one's; `conditions.reconcile` makes it
  save-compatible for free when it lands.
- Application and the residual stop are **two separable steps**, so #167 can later police the
  stop without touching the spending (or vice versa — its call).
- The residue is emitted as **data** — `{pool, count, reason, next_candidate}` — so #167's
  message function renders it without re-deriving, and the per-pool baselines double as its
  future `ctx.unspent`.
- Paused pools bypass the residue entirely; #167's condition should be told they exist.

---

## 5. The editor

### 5.1 Two surfaces, one predicate

The owner's decision names the style — the talent screen — and the talent screen's rebuild
(#56) already ships every idiom needed: sectioned TreeList with columns, mouse drag-reorder,
Enter-on-row action menus, the digit/Shift-arrow/Delete keyboard grammar, numeric entry, and
the proposal/preview mode where nothing is written until Merge/Replace. The plan editor is a
new dialog in the addon's own namespace beside it, with one section per pool; rows are
annotated from the same `buildplan` predicate the applier walks (satisfied / riding a cap /
blocked, with the game's own requirement wording), so what the editor greys and what the
walk skips can never drift apart.

The rejected alternative, recorded so it is not re-litigated: running the game's own
`LevelupDialog` against a point-inflated clone as a *planning* surface. It stacks four
unverified engine behaviours (an off-player dialog, golem backup/restore on a clone,
per-talent callback side effects on a fake actor, a real profile unlock reachable from the
clone) against a feature the list dialog provides with zero engine risk — and a recorded
session cannot *reorder* an existing plan anyway, which the mid-run gear case (§7) makes the
one operation that must stay cheap.

### 5.2 The recorder

A superloaded `LevelupDialog` (the addon's first dialog superload; sanctioned by the seam
rule — no hook covers stat or talent clicks or finish/cancel; only category clicks fire one,
`PlayerLevelup:addTalentType`/`subTalentType`, which is not enough for a recorder) wraps
`incStat`, `learnTalent`, `learnType`, `finish`, `cancel`. Successes are detected by pool delta — no dialog method returns success
usably — and adopted into the plan **on `finish()` only**; `cancel()` adopts nothing.
Adoption is direction-aware, per talent, comparing raw before and after the session:

- net learn → `target := max(target, final raw)`, appending `{tid, target}` at the list tail
  if absent — first appearance is the recorded order; helping a row along never lowers it;
- net unlearn → `target := min(target, final raw)` — the applier must never re-buy what the
  player just deliberately un-spent;
- category clicks append the matching `unlock`/`mastery` row; the inscription-slot purchase
  bypasses the click funnel, is detected by pool delta at finish, and appends `slot` rows
  until the plan holds as many as `inscriptions_slots_added`;
- stat clicks are logged, not adopted (§3.4), with one line saying where the stat policy
  lives.

Birth sessions are recorded like any other — the dialog's `on_birth` mode changes cooldowns
and unlearning, not the clicks — so a character's starting allocation is the natural head of
the recorded order. Recording never reorders existing rows, and each adoption is logged.

### 5.3 Editing mid-run means editing asks, and the editor says what it cannot do

The editor accepts every well-formed edit, including "impossible" ones, and labels exactly
what cannot happen — it never refuses, never confirm-dialogs, and **never spends or unlearns
anything itself**. The cases, settled:

- **Target below the invested rank**: accepted and stored as entered; the row renders
  satisfied with its overshoot ("3/2 — points cannot be un-spent; the bot will invest no
  further"). Never clamped up to raw — it is the honest ask, and the right one for a future
  character under §6.
- **Target raised**: input clamped to the live rank ceiling; a satisfied row flips back to
  pending by derivation, honoured at the next application.
- **Deleting an invested row**: allowed, no confirmation; the label carries the consequence
  ("keeps the points already spent; the bot will not invest further").
- **Reordering**: one drag, zero validation — order is preference, not dependency, and any
  order terminates. Cross-pool drags are refused with the reason (the pool is a property of
  the talent). This is the gear case: move one row, done.
- **Editing while points are pending**: safe by construction — the stop already cleared the
  activation, and an open dialog stops an active bot before its next application; Lua is
  single-threaded and the applier reads the plan fresh each run. Pool headers show the live
  balance and a dry-run forecast from the same walk ("2 waiting — the plan will spend 2 on
  the next run" / "no row can take them yet: Vitality → 3 needs level 8").
- **Stat break point already met, category row already unlocked, escort row that can never be
  offered**: all accepted, all labelled from the derived state; a value above the current cap
  is annotated "resumes as the cap rises", not refused.

Every such message is composed in `buildplan.lua`, one wording home, shared by editor rows,
forecasts and the residue report.

---

## 6. Per character now; a template is the same value, later

The live plan is **per character**: `data(p).buildplan`, riding the save like the stop
conditions and the talent rules, normalized on access, no migration for existing saves. Two
accessors ship with it — `bot.exportPlan(p)` (deep copy, `meta` restamped from
`p.descriptor`) and `bot.importPlan(p, tbl)` (normalize, replace, log one summary) — because
the harness needs them on day one (§9) and because they are the whole template mechanism in
embryo.

A **template is exactly `exportPlan`'s value with a name** — no second schema, ever. The
§3.2 invariants (stable ids, statelessness, value-type closure, `meta.subclass` stamped,
`version` + normalize as the single upgrade path, one accessor surface) are what make that
true, and they are design obligations, not implementation details. The template *store and
gestures* are a second pass: one file per template under the engine's writable home path,
written by a small serializer for the closed plan grammar and read by a **non-executing**
parser — the scalar settings store refuses tables by design, and both engine patterns that
execute player-disk Lua (guarded table-literal cfg, the quickbirth sandbox) are ruled out by
the addon's own read-don't-execute rule. Matching is **advisory, by `meta.subclass`**: any
template applies to any character, unsatisfiable rows are inert under §3.1's walk, and the
load list defaults to same-subclass with a show-all override — enforcement would buy nothing
(the guards already prevent every illegal spend) and would break the Adventurer by
construction.

One deliberate divergence from the #90/#95 settings precedent: account-level scalars seed new
characters silently; **a template is never auto-applied**. A plan drives permanent spending —
"seeding, yes; deciding, no" applies to templates exactly as it does to #18's proposal.

---

## 7. Deliberately not in the first pass

- **Prodigies.** Two choices in a run, both permanent, both with unique requirements. The
  machinery is the same but the stakes are not, and they are reachable long after level 20 —
  which is where M6 stops. (The pool's spend path is caller-side like the others —
  `UberTalent:use` decrements at selection, the dialog's finish re-checks and refunds — so
  the model extends when wanted.)
- **Gear-aware ordering.** *"You get a really good darkness staff and ring, max out the
  darkness spell that is in your rotation first rather than the acid one."* The owner's own
  note calls this advanced and probably not something the player would define. It is not
  modelled. What it argues for is that **re-ordering a plan mid-run must be cheap**, so a
  player who picks up the staff moves one row — §5.3 delivers exactly that.
- **Cursed Fate and other one-off permanent choices** (#191). The plan is where they belong,
  but the answer to that one is the owner's and is not settled.
- **Deriving a plan automatically** from #18's proposal. Seeding, yes; deciding, no.
- **The template store and its editor gestures** (§6). The semantics and vehicle are decided;
  the store is pass two, and it gates nothing in M6.

---

## 8. The three open questions, closed

1. **Per character, or a reusable template?** Both, staged: the live plan is per character
   now; the template is the same value with a name, stored later, never auto-applied — §6.
   The #90/#95 precedent transfers at the model layer (character-owned value, explicit
   copy-out gesture, no silent write-back) but not at the storage layer (the settings store
   holds scalars only; the plan is the first structured value and needs its own vehicle,
   chosen in §6).
2. **What a lowered target means mid-run.** It is accepted, stored as entered, and renders as
   satisfied-with-overshoot; nothing is un-spent, and the editor says so instead of appearing
   to obey — §5.3. More generally: every edit edits *asks*; all status is derived; the
   applier reads the plan fresh at each run, so every edit takes effect at the next
   application with no invalidation protocol.
3. **Whether stats want an ordered list after all.** Yes — and it is not a second mechanism
   but the same one: ordered `{stat, target|"max"}` rows, walked like every other pool. The
   three-field policy is the canonical two-or-three-row instance; "rest into Con" falls out
   of the soft cap plus fall-through with no overflow rule at all; and Str→X→Dex→Y→Str, the
   case the policy could not express, is three rows — §3.2. One provenance note: the
   2026-08-26 comment asked *"say if that is backwards, or if both pools want both
   mechanisms"* and was never answered on the record; this unification is the document's
   resolution of that question, and it is reversible at the presentation layer — the storage
   and the walk do not change if the owner prefers literal primary/secondary fields in the UI.

---

## 9. Where the pieces would go

| Piece | File |
|---|---|
| The plan model: normalize, row states, the walk selection, the recorder's adoption rules, the export/import core, the residue data, the messages | `src/data/buildplan.lua` (pure, busted-pinned — the superloads and accessors only *call* it) |
| Applying it: per-pool baselines, the two sites, the spend transaction | `src/superload/mod/class/Player.lua`, at the unspent-points hand-back |
| The recorder | `src/superload/mod/dialogs/LevelupDialog.lua` (the addon's first dialog superload), adoption logic from `buildplan.lua` |
| The editor | `src/overload/mod/dialogs/skoobot_reclauded/`, beside the talent screen |
| The escort half's menu | read from `EscortRewards:listRewards()` at runtime, per `docs/design-escort.md` §1.4 |
| Unit coverage | `spec/buildplan_spec.lua` — normalize properties, row-state derivation, walk selection incl. cap fall-through and pre-emption, recorder adoption, import/export round-trip |

The harness seam, so the sweeps exercise this instead of fighting it: the pre-run
`sk.autoSpend` call becomes `bot.importPlan(p, fixture)` over the devbridge — seeding a plan,
not spending points — and the mid-run auto-spend handler is gated off when a plan exists, or
it would spend exactly what the plan refused to and violate §3.5 under test. #190's fixes to
`autoSpend` itself stay harness work for plan-less characters, and are still not this issue.

## Relations

- **#190** — what the band-aid actually does, measured; the case for this issue.
- **#158** — the band-aid itself.
- **#167** — the unspent-points policy, which this narrows but does not answer; the seam it
  gets is §4.4.
- **#191** — a permanent build decision looking for somewhere to live.
- **#18** — the loadout proposal, a source to seed from — membership only, order is a firing
  order.
- **#93** — escort rewards; the allocation half lives here (the plan's `escort` pools), the
  chat half stays there and consumes them by regenerating labels from ids, never matching by
  position.
- **#114** — why this applies at the hand-back and not inside `levelup`; its own later
  measurement is why §4.3 states the rule as callback re-entrancy, not "inside act()".
- **#56** — the talent screen rebuild whose idioms the editor reuses.
