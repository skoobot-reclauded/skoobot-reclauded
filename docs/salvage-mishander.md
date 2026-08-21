# Salvage triage: mishander's SkooBot fork

**Task:** T-004 · **Date:** 2026-08-21 · **Source:** `mishander/tome4-SkooBot` @ `83c5d1e`,
9 commits ahead of SkooBot `master`, +173/−22.

Licensing settled by D-5: full GPL-3.0 derivative, copying permitted. mishander's authorship
is preserved in [NOTICE](../NOTICE) regardless of what the licence strictly requires — this
work was submitted upstream as PR #51 in good faith and was never merged.

**A fifth contributor surfaced during triage:** `Shchvova` (Vlad Svoka) contributed
`settings.lua` defaults via PR #1 to the fork. Added to NOTICE.

---

## Headline finding: an 8-year-old bug in the *original*

`superload/mod/class/Player.lua:642` in SkooBot 0.0.12:

```lua
if terrain.air_level and terrain.air_level < 0 and not game.player.undead == 1 then
```

In Lua, `not` binds tighter than `==`, so this parses as `(not game.player.undead) == 1`.
`not x` yields a boolean, and comparing a boolean to the number `1` is **always false** — for
undead and living characters alike. Verified under LuaJIT:

| character | expression | result |
|---|---|---|
| undead (`undead = 1`) | `not 1 == 1` | `false` |
| living (`undead = nil`) | `not nil == 1` | `false` |
| *intended* | `undead ~= 1` | `true` |

> Full write-up of this and a second instance of the same defect: [v1-latent-bugs.md](v1-latent-bugs.md)

**The entire "run to air when drowning" block was unreachable for the whole life of the
project.** The code was written in October 2018 (commit *"Added support for undead not
worrying about drowning"*) and never once executed.

This is exactly user complaint **T-015**. TheIronBird, Steam, 2018-11-29:

> *"Is it all possible for you to add some kind of condition so that your char won't rest
> while losing air. I'v lost too many chars due to this."*

The author replied that it was "currently planned" — not realising the feature already
existed and was dead. Players lost characters to a single misplaced pair of parentheses for
eight years.

**Consequence for the rebuild:** this is the strongest possible argument for T-023
(enforce linting) and for the test harness. A trivial static check catches it; no amount of
playtesting reliably does, because the failure is silent — nothing errors, the bot simply
never acts.

---

## Verdict summary

| # | Change | Verdict | Fixes |
|---|---|---|---|
| 1 | `IGNORE_DAMAGE_HEALTH_RATIO` | **Take (concept)** | T-011 |
| 2 | Rank-weighted enemy power ratios | **Take (concept)** | toward T-020 |
| 3 | HP-weighted own power level | **Take** | toward T-020 |
| 4 | Relative crowd-power threshold | **Take** | toward T-020 |
| 5 | `can_breath` replacing the broken undead check | **Take** | T-015 |
| 6 | `canMove` filter in `getPathToAir` | **Take** | T-015 |
| 7 | Pinned check before explore | **Take, but incomplete** | T-012 |
| 8 | Level-change `turnCount` handling | **Take (concept)** | UX |
| 9 | Glowing chest seeking | **Rewrite** | T-013 |
| 10 | Debug `game.log` spam | **Reject** | — |
| 11 | `evaluatePowerLevel` shadowing + dead code | **Reject** | — |
| 12 | Hardcoded Sun Paladin talent preset | **Reject (keep the idea)** | — |
| 13 | `install.bat` / `install_and_run.bat` | **Reject** | — |

---

## Take

**1. `IGNORE_DAMAGE_HEALTH_RATIO` (default 0.75).** Suppresses the "took damage while
exploring" stop while life is above the threshold. Directly answers lukesilveira's complaint
that a single poison tick halts the bot. Right diagnosis, right shape of fix. Under T-020 this
becomes an input to the score rather than a standalone flag.

**2. Rank-weighted power ratios** — `NORMAL_POWER_RATIO` 0.4, `ELITES_POWER_RATIO` 1.0,
`BOSS_POWER_RATIO` 2.0, applied by `actor.rank`. mishander's own note on why:

> *"checking simply power level leads to a stop every time you see bunch of common mobs, and
> if you increase threshold — you start getting into hard situations where couple of rare mobs
> are threatening to kill you."*

That is precisely the flat-threshold failure T-020 exists to fix, identified independently
from play. Take the insight; the magic numbers (`rank < 3`, `rank < 4`) need named constants.

**3. HP-weighted own power** — `evaluatePowerLevel() * (life / max_life)`. Obvious in
hindsight and absent from the original. mishander flags that it probably shouldn't be linear,
and they're right; a character at 51% life is worse off than half-strength because it has
fewer turns of margin.

**4. Relative crowd threshold** — `sumVisibleEnemyPower > myPowerLevel + MAX_COMBINED_POWER`
rather than an absolute cutoff. Correct: threat is relative to the character, not a constant.

**5–6. Drowning fixes.** `not game.player.can_breath` replaces the broken undead check, and
`getPathToAir` gains `self:canMove(x, y, false)` so it stops pathing to air tiles it cannot
reach. Both correct. Note that these fix a *live* bug (#5) and a *latent* one (#6) that was
masked by #5 — the pathing was never exercised.

**7. Pinned check before `SAI_beginExplore()`** — prevents the freeze where the bot tries to
explore while unable to move. Fixes the reported symptom, but **incomplete**: it only tests
`EFF_PINNED`, while mishander's own PR text and broness's bug report both mention Dominate,
and h-youhei reported the same freeze from *sleep*. The general form is "can I move at all?",
not "am I pinned?". Take the fix, generalise the condition — full reasoning in
[v1-latent-bugs.md](v1-latent-bugs.md).

**8. Level-change `turnCount` handling.** Lets the bot start on a level-entrance tile instead
of immediately stopping. mishander wanted to rebind auto-explore to the bot entirely and hit
this. Sound UX; the flag-based implementation is clumsy and should fall out of state handling
naturally rather than needing a counter.

## Rewrite

**9. Glowing chest seeking.** Right goal, unsafe implementation. It calls `SAI_movePlayer`
*inside* a FOV callback, discards the return value, and keeps scanning — so it moves toward
whichever chest happens to come last in iteration order, with no reachability check and no
stop. mishander labelled it "(beta)" and separately noted it sometimes fails. Reimplement
against the T-020 scorer: a chest is a scored objective, not a special case wedged into the
act loop.

## Reject

**10. Debug logging.** ~15 `game.log("#LIGHT_RED# ...")` calls on hot paths, including inside
a per-tile FOV callback — that fires for every visible tile, every turn. Log spam and a real
performance cost. mishander said as much:

> *"Added bunch of debug output which may need or need not be wrapped in some OUTPUT_IF_DEBUG
> macro function"*

They were right that it needed gating and never did it. The rebuild wants a proper levelled
debug channel from day one.

**11. `evaluatePowerLevel` shadowing.** A file-local `evaluatePowerLevel(actor)` that wraps
`actor:evaluatePowerLevel()` — same name, different thing, one call away from itself. Also
carries unreachable code after an exhaustive if/elseif/else, which mishander annotated
`--WTF IS THAT?`. Keep the behaviour, discard the structure.

**12. Hardcoded Sun Paladin preset.** The 2024 commits (`t1`, `test`) add a
`defaultsunpaladin` button wiring up mishander's personal build by talent *name* string. Pure
scratch work, and name-matching is fragile across localisations and game versions. **But the
underlying idea — preset talent loadouts so a new character isn't configured from scratch — is
good and generalisable.** Logged separately; that was the single most-repeated confusion in the
original's user feedback.

**13. Install scripts.** Hardcode a 7-Zip path and a Steam install path, and carry a template
bug — the archive is named `tome-skoobot-.teaa`, with the version variable never substituted.
We need our own, driven from `init.lua`'s `addon_version`.

---

## Net

Roughly **60% of the diff is worth taking**, mostly as insight rather than lines: mishander
independently diagnosed the flat-threshold problem that the historical analysis identified as
the root cause behind four separate user complaints. Two people arriving at the same
conclusion from opposite directions — one from play, one from the issue record — is good
evidence T-020 is the right central bet.

The remaining 40% is debug scaffolding and personal configuration, which is what
work-in-progress on a private fork is supposed to look like. No criticism implied.
