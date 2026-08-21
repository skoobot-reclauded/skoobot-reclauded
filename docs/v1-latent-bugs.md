# Latent bugs in SkooBot v1, found by static analysis

**Date:** 2026-08-21 · Found while triaging for the rebuild, against SkooBot 0.0.12
(`reference/skoobot-upstream`). Both were live in every released build and in the copy still
published on te4.org and the Steam Workshop today.

Both are the **same defect class**: Lua binds `not` tighter than the relational operators, so
`not x == 1` parses as `(not x) == 1` — a boolean compared to a number, which is *always
false*. The code is syntactically valid, raises no error, and silently never runs.

A full sweep found exactly two instances. There are no others.

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

**Fix:** `not game.player.can_breath` (mishander's fork already does this).

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

**Matches user report — h-youhei, GitHub #46, 2021-03-14:**

> *"With Base Game v1.7.2 and Skoobot v0.0.12, the soft-locks still occur.
> **When I get asleep**, playing melee character."*

**Fix:** `game.player.sleep == 1 and game.player.lucid_dreamer ~= 1`.

---

## Why issue #46 was closed without being fixed

Issue #46 ("Achieving SAI_STATE_EXPLORE after resting while being unable to move soft-locks
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
