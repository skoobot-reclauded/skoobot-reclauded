# The build plan

How the bot spends a character's points, and why the obvious design does not work. Issue **#88**.

§1 is read out of ToME 1.7.6's own source rather than inferred, because the shape of the
problem — five pools on four different schedules, two of which are contingent — is what
decides everything after it.

**First pass. Nothing here is built yet.** The owner's decision of 2026-08-25 settles the
interface (an in-game editor, in the style of the talent screen); this settles the *model* the
editor edits and the semantics the bot applies. Where it records an open question, that
question is open.

---

## 1. What the engine actually does

### 1.1 There are five pools, not one

`mod/class/Actor.lua:3949`, the player's own level-up. Starting values are at `:191`.

| Pool | Field | At birth | Per level | Extra |
|---|---|---:|---|---|
| Stat points | `unused_stats` | 3 | `stats_per_level` (3) + rank adjust | **+10 at level 50** |
| Class points | `unused_talents` | 2 | +1 | **+1 more** on every 5th level |
| Generic points | `unused_generics` | 1 | +1 | **−1** on every 5th level |
| Category points | `unused_talents_types` | 0 | — | at **10, 20, 34**, then every 30 past 50 |
| Prodigies | `unused_prodigies` | 0 | — | at **25 and 42** |

Two things fall straight out of that table and neither is obvious:

- **A level is not a unit of currency.** On level 5 the character gains two class points and
  *no* generic point. A plan expressed as "at level 5, take X" is expressed in the wrong units.
- **The pools are not interchangeable.** A generic point cannot buy a class talent. Any model
  with a single ordered list of "what to buy next" is wrong before it starts, because the next
  thing the player wants may not be payable with the point that just arrived.

### 1.2 Two more pools arrive contingently

- **Escort rewards.** `mod/class/EscortRewards.lua`'s `listRewards()` is a **static table keyed
  on `reward_type`**: two stats and three talents per kind, some with `saves`, and a whole
  `antimagic` variant selected by the character's own antimagic status. `getGiver()` draws a
  kind at random per escort with no `unique` flag on any of the base eight, so kinds repeat and
  the count over a run is unbounded.
- **One-off permanent choices**, of which Cursed Fate (#191) is the known case: accepting costs
  2 Willpower and grants a talent tree plus a point in `T_DEFILING_TOUCH`. #191 records that a
  build plan is where such a decision most naturally belongs.

**There is no ordinal to attach a preference to.** No "my third escort". Only "any escort of
this kind, in this order" — which is what makes these *pools* rather than plan entries.

### 1.3 Where points are actually spent

`unused_stats` at `:836`, `unused_talents_types` at `:861`, `unused_talents` at `:881`,
`unused_generics` at `:902` — all inside the engine's own `learnTalent` / stat-increase paths.
So the plan never decrements anything itself: it calls the engine's own routines and the engine
does the accounting, with all of its own checks intact. That is the same rule the issue states
and it is not negotiable — a plan that wrote `unused_talents` directly would be able to buy
things the game says no to.

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

### 3.2 What each pool's preference looks like

| Pool | Shape | Why |
|---|---|---|
| **Stats** | `primary`, `secondary`, plus zero or more `break points` (`stat → value`) that pre-empt both until met | The owner's own description: *"dump all into main stat, rest into con or other second stat. Sometimes... hit a specific break point of a third stat"*. Three fields express a whole build |
| **Class points** | ordered list of `talent → target level` | |
| **Generic points** | its own ordered list | A separate pool needs a separate list; see §1.1 |
| **Category points** | ordered list of trees to unlock | Three in a normal run (10, 20, 34) |
| **Escort rewards** | per `reward_type`, an ordered preference over that kind's own fixed menu | The menu is enumerable in advance from `listRewards()`, so the editor can show real rows |
| **Prodigies** | one choice at 25, one at 42 | Out of the first pass; see §5 |

### 3.3 Capture the order by doing it, not by typing it

The editor is the game's own level-up gesture, and the plan is the **recording of a real
allocation session** rather than a form to fill in. #18's loadout proposal stays a natural
*source* to seed it from — discovery proposes, the player fixes the order.

That matters beyond convenience: a player who can express a plan only by typing talent names
will express a worse plan than one who can express it by spending points the way they always do.

### 3.4 Never spend what the plan does not name

From the issue, and it is the safety property that makes the whole thing acceptable to run
unattended. When a pool's list is exhausted or nothing in it is currently satisfiable, the
points stay unspent. They are not scattered into whatever is nearest.

That leaves the question **#167** asks — what the bot should then do about the "unspent points"
hand-back — and this design deliberately does not answer it. It only removes the reason it fires
in the common case.

### 3.5 Log what was spent

Also from the issue. A plan applied silently is indistinguishable from a plan that did nothing,
which is the lesson of `#127`, `#169`, `#174` and `#178` in four different places this week.

---

## 4. What the bot does at the hand-back

Today the act loop hands back on "you have unspent points to allocate". With a plan:

1. the hand-back fires as now;
2. the plan is applied, pool by pool, through the engine's own calls;
3. what was spent is logged;
4. if points remain and nothing in the plan can take them, the hand-back stands — the player is
   told which pool is stuck and why.

Applying on the hand-back rather than inside `levelup` keeps it out of a re-entrant engine
routine, which is #114's lesson and cost a crash to learn.

---

## 5. Deliberately not in the first pass

- **Prodigies.** Two choices in a run, both permanent, both with unique requirements. The
  machinery is the same but the stakes are not, and they are reachable long after level 20 —
  which is where M6 stops.
- **Gear-aware ordering.** *"You get a really good darkness staff and ring, max out the darkness
  spell that is in your rotation first rather than the acid one."* The owner's own note calls
  this advanced and probably not something the player would define. It is not modelled. What it
  argues for is that **re-ordering a plan mid-run must be cheap**, so a player who picks up the
  staff moves one row.
- **Cursed Fate and other one-off permanent choices** (#191). The plan is where they belong,
  but the answer to that one is the owner's and is not settled.
- **Deriving a plan automatically** from #18's proposal. Seeding, yes; deciding, no.

---

## 6. Open questions

1. **Per character, or a reusable template?** A plan is per character today by implication. A
   player running the same class repeatedly will want to reuse one, which is the same
   account-vs-character split `#90` and `#95` already settled for settings — likely the same
   answer, but it is not decided.
2. **What a target level means when the plan is edited mid-run.** Lowering a target below what
   is already invested cannot un-spend; the editor has to say so rather than appear to accept it.
3. **Whether stats want an ordered list too**, rather than the three-field policy in §3.2. The
   policy covers the owner's own described habit; whether it covers a build that wants
   Str→Dex→Str is untested.

---

## 7. Where the pieces would go

| Piece | File |
|---|---|
| The plan model, the pools, the re-satisfy rule | `src/data/buildplan.lua` (pure, busted-pinned) |
| Applying it | `src/superload/mod/class/Player.lua`, at the unspent-points hand-back |
| The editor | `src/overload/mod/dialogs/skoobot_reclauded/`, beside the talent screen |
| The escort half's menu | read from `EscortRewards:listRewards()`, per `docs/design-escort.md` §1.4 |
| Unit coverage | `spec/buildplan_spec.lua` |

## Relations

- **#190** — what the band-aid actually does, measured; the case for this issue.
- **#158** — the band-aid itself.
- **#167** — the unspent-points policy, which this narrows but does not answer.
- **#191** — a permanent build decision looking for somewhere to live.
- **#18** — the loadout proposal, a source to seed from.
- **#93** — escort rewards; the allocation half moved here, the chat half stayed there.
- **#114** — why this applies at the hand-back and not inside `levelup`.
