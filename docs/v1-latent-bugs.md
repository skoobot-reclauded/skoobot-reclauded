# Latent bugs in SkooBot v1

**Date:** 2026-08-21 (Bugs 1 and 2, by static analysis); 2026-08-23 (Bug 3, found while
porting). Against SkooBot 0.0.12
([SkoobyDoo/tome4-SkooBot](https://github.com/SkoobyDoo/tome4-SkooBot) at commit `ad23dea`).
All three were live in every released build and in the copy still published on te4.org and the
Steam Workshop today.

Bugs 1 and 2 are the **same defect class**: Lua binds `not` tighter than the relational
operators, so `not x == 1` parses as `(not x) == 1` — a boolean compared to a number, which is
*always false*. The code is syntactically valid, raises no error, and silently never runs.

A full sweep found exactly two instances of that class. There are no others. **Bug 3** is a
third latent bug of a different class — a table tested for truth — found later, while porting.

---

## Bug 1 — the drowning guard never ran

`superload/mod/class/Player.lua:642`

```lua
if terrain.air_level and terrain.air_level < 0 and not game.player.undead == 1 then
    -- run to air
```

| character | expression | result |
|---|---|---|
| undead (`undead = 1`) | `not 1 == 1` | `false` |
| living (`undead = nil`) | `not nil == 1` | `false` |
| *intended* | `undead ~= 1` | `true` |

The run-to-air block was unreachable from the day it was written (commit *"Added support for
undead not worrying about drowning"*, 2018-10-05) until the project ended.

**Matches user report — TheIronBird, Steam, 2018-11-29:**

> *"Is it all possible for you to add some kind of condition so that your char won't rest
> while losing air. I'v lost too many chars due to this."*

The author replied that it was "currently planned and should be included in the next release,"
and advised avoiding water levels. The feature already existed. Tracked as **T-015**; open for
eight years.

**Fix:** ~~`not game.player.can_breath` (mishander's fork already does this).~~

> **Correction (T-001, 2026-08-22).** That fix is **also dead code**: `can_breath` is *always*
> a table in 1.7.6 (`T/mod/class/Actor.lua:226`), so `not game.player.can_breath` is
> permanently false — mishander's replacement never runs either. The correct predicate is
> `terrain.air_level < 0 and not p:attr("no_breath") and (not air_condition or
> (p.can_breath[air_condition] or 0) <= 0)`. `undead` is the wrong test — `no_breath` is
> Skeleton-only. Full remediation, with the air-tile ranking and the `abs`/`MAX_INT`
> replacements v1 also needs, in [api-surface-1.7.6.md](api-surface-1.7.6.md) Remediation 5.

---

## Bug 2 — the ASLEEP stop condition never fired

`superload/mod/class/Player.lua:260`

```lua
if game.player:checkStop("DEBUFF_ASLEEP",
    game.player.sleep == 1 and not game.player.lucid_dreamer == 1,
    "#RED#AI Stopped: Player is Asleep!") then
```

`not game.player.lucid_dreamer == 1` is always `false`, so the whole condition is
`sleep == 1 and false` — **false for everyone, asleep or not, lucid dreamer or not.**

The stop condition was listed in the UI as `Debuff: ASLEEP / WARN`, appeared configurable,
and did nothing.

**Matches user report — h-youhei, issue #46 of the original repository, 2021-03-14:**

> *"With Base Game v1.7.2 and Skoobot v0.0.12, the soft-locks still occur.
> **When I get asleep**, playing melee character."*

**Fix:** ~~`game.player.sleep == 1 and game.player.lucid_dreamer ~= 1`.~~

> **Correction (T-001, 2026-08-22).** `lucid_dreamer ~= 1` is **still wrong**: the sustain
> stacks its bonus as a value of 5–25+, not 1, so `~= 1` is true for a lucid dreamer too. The
> effect attributes are additive counters, never boolean flags — this is the same class of
> error across every status stop (and a *third* instance: `confused` is a 0–50 percentage, so
> v1's `confused == 1` CONFUSED stop never fired either). Gate on capabilities:
> `p:attr("sleep") and not p:attr("lucid_dreamer")`. See
> [api-surface-1.7.6.md](api-surface-1.7.6.md) Remediation 4 and "Value-domain notes".


---

## Bug 3 — the FIGHT branch's target filter never filtered

*Added 2026-08-23 (#81). A different defect class from the two above, found while working on
the port rather than by the `not x == 1` sweep — that sweep's claim of "exactly two instances"
was about its own class and still holds.*

`superload/mod/class/Player.lua`, the FIGHT branch:

```lua
for _, enemy in pairs(hostiles) do
    if filterFailedTalents(getAvailableTalents(enemy)) then
        table.insert(targets, enemy)
    end
end
```

`filterFailedTalents` returns a **table**. In Lua every table is truthy, including an empty
one, so the condition is a constant `true` and every visible hostile became a target whether or
not anything could be used on it. The intended test is on the count. The port reproduced it
faithfully (D-12) and #12 and #11 both left it alone on purpose.

**The obvious repair is wrong**, which is why this survived a reading or two.
`getAvailableTalents` with no rotation reads every talent the character has and requires
`canProject` at the enemy's grid, so **range is part of the test**: a melee character five
squares from an orc has nothing available on it. Test `#... > 0` here and that orc is not a
target, `targets` comes out empty, and the "nothing left in sight: fight's over" branch sends
the bot to REST — which re-enters with the orc still in view, sets FIGHT again, and spins to
`THINK_LIMIT`. Melee stops working.

What the filter can honestly decide is the **pick**, not the target list: approach needs every
hostile, because closing the distance is how a melee talent comes into range, while the first
pick should be an enemy something can actually be used on. Fixed that way in #81.
`scenario-scoring.ps1` probe A is the guard on the trap — *"with nothing in reach it would
close the distance"* fails loudly under the naive repair.
---

## Why the original's issue #46 was closed without being fixed

The original repository's issue #46 ("Achieving SAI_STATE_EXPLORE after resting while being unable to move soft-locks
the game") was closed on 2020-08-04. h-youhei reproduced it seven months later and it was
never reopened.

It has **two independent root causes**, and the fix that closed it touched neither:

1. **ASLEEP never fires** (Bug 2 above). The bot doesn't know it's asleep.
2. **PINNED is not a stop condition at all.** The list has exactly five debuffs — STUNNED,
   CONFUSED, DAZED, FROZEN, ASLEEP. No PINNED, no DOMINATED.

Cause 2 is the more instructive one. The other four effects prevent the character from
*acting*, so the act loop stalls somewhere the bot notices. **Pinned blocks movement while
leaving actions available** — so the bot believes it can act, enters `SAI_STATE_EXPLORE`,
requests a move, fails, and retries. That is the freeze broness described:

> *"When player get Pinning effect(phys or poison) its often cause working bot to just
> drop-freeze the game."* — te4.org, 2021-08-05

**Implication for T-012:** the correct condition is not "am I pinned?" but **"can I move at
all?"** — which covers pinned, dominated, entangled, held, and anything a future ToME version
adds. mishander's fork checks `EFF_PINNED` only and is therefore an incomplete fix for the
same reason the original was.

---

## The tooling lesson (verified, not assumed)

`luacheck` detects this class by default. Confirmed against a reproduction:

```
prec.lua:2:26: Error prone negation: negation is executed before relational operator.
prec.lua:3:4: Error prone negation: negation is executed before relational operator.
```

Both bugs, named precisely, in milliseconds. `luacheck` 1.2.0 predates SkooBot's final
release — this was catchable in 2018 and 2020 with a tool that already existed.

**Neither bug was findable by playtesting**, which is the point. There is no error, no log
line, no crash; a feature simply doesn't happen, and the absence looks like a feature that was
never written. Two separate users reported the *symptoms* — lost characters, freezes — and
both reports were met with plausible non-fixes because the cause was invisible from inside the
game.

This is the concrete justification for **T-023** (lint in a pre-commit hook, enforced, not by
discipline). It is the cheapest task on the board and it would have prevented eight years of
one bug and the "closed but not fixed" status of another.
