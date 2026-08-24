# What makes 0.1 releasable

**Issue:** #32 · **Date:** 2026-08-23 · **Milestone:** M4 Release readiness

The owner's decisions, recorded so the gate list is not re-derived: **D-11** (2026-08-21,
*0.1 is v1's feature set working on 1.7.6, and a meaningful improvement on the last public
SkooBot*), the 2026-08-23 rulings on presets, the 1→15 run and the release flow, and
**D-14** (2026-08-24, *`0.x` is a GitHub-only beta prerelease; `1.0.0` is the first te4.org /
Steam publish, and D-11's judgement bar moves to it*). How the release is then cut is
[releasing.md](releasing.md).

> **What D-14 changed about this document.** It was written when 0.1 was *the* release. It no
> longer is: 0.1.0 is a beta, published only as a GitHub prerelease, for testers who were
> pointed at it. **The floor, the feature set and the mechanical gates below still bind
> 0.1.0.** **The judgement gate in §4 does not — it binds 1.0.0**, the first version that
> appears in the game's own Addons browser. Nothing else here moves.

---

## 1. The bar

- **Floor — binds 0.1.0.** SkooBot 0.0.12's feature set working on ToME 1.7.6 — rest, explore
  and fight for levels 1–15, the talent-section screen, the stop conditions with
  WARN / STOP / IGNORE.
- **Bar — binds 1.0.0** (D-14). *A meaningful improvement over SkooBot 0.0.12 at its best.*
  The comparison point is the original as it played in 2019–2020, not as it was abandoned;
  "it loads on 1.7.6" is necessary and not sufficient. This is a **judgement the owner makes
  against the complaint record**. It is not automatable and nothing below pretends it is —
  and it is deliberately arbitrary, because the thing it is protecting is a stranger's first
  impression from the in-game banner.

**So 0.1.0 ships on the floor plus §4's mechanical gates, and 1.0.0 adds the bar.** A beta is
allowed to be rough in ways a listing is not.

## 2. The three non-negotiables, honestly

1. **Minimised superload surface (#14, finished by #76) — done.** The addon superloads one
   class, `mod.class.Player`, for **one** one-line wrapper (`act`); the tooltip line is the
   engine's `Actor:tooltip` hook; nothing is added to either class and nothing leaks into
   `_G`. `Player:act` has no hook equivalent in 1.7.6 and stays. `postUseTalent` went when
   the rotation started reading `useTalent`'s return, which carries the same refusal (#76).
2. **A contribution path that survives a year without the maintainer (#17).** The original
   died of exactly this, with two working fixes unmerged. A 0.1 prerequisite.
3. **The judgement bar** in §1.

## 3. Minimum feature set

| | Status |
|---|---|
| Rest / explore / fight loop for levels 1–15, as ported (D-12) | in |
| Talent screen: sections, order, items by name (#56, #55) | in |
| Stop conditions: the 0.0.12 list plus glowing chest, with one notice per stop (#8, #57, #58) | in |
| Every cheap inherited-defect fix: #5 #6 #7 #8 #9 #10, plus #51 #52 #55 #48 #49 | in |
| Trivial-damage default 0.9 (#6, owner review) | in |
| Presets and auto-discovery (#18) — **GO for 0.1**, 2026-08-23 | in (`d9651f7`, 2026-08-23) |
| Keybind collision detection (#50) | in (`f87b46d`) |
| First-run UX pass (#54) — the manifest `description`, option wording, menu help, `docs/first-run.md` | pass done (`9c80862..5b13da1`), and so are all three of its findings: #73 (the menu's two choices say what they do), #72 (the addon introduces itself once, to a character with nothing set up) and #71 (stop reasons and condition labels in the player's words). #74, the option ranges, is **done** |
| mishander's remaining takes — rank-weighted ratios, life-scaled own power, relative crowd threshold, level-entrance start (#62) | in (`d3becd0..9c2b081`) |
| Settings written on the options tab survive a restart (#90) | in (`main`) — every option lasted one session before it; the tab was a lie, and every playtest ran at the defaults whatever was set |
| Power levels printed whole (#84) | in — the owner's playtest read *power level, 1080.1*; the ratios keep their decimal, where the tenth is the difference between over a limit and under it |
| Life measured over the pool the game kills at (#91) | in — `die_at`, which every life judgement ignored. A pool held up by something about to lapse is not counted, and the reason says which effect it did not count |
| Progress invariant replacing the turn-count stop (#13) | in (`29ee928`) — built ahead of M2 because it is small and regression-netted |
| Levelled debug channel (#46) | in (`a0b8a11`) |
| Flee action (#59) and hold-while-impaired (#15) | **in** — owner's ruling, 2026-08-24. Their follow-ups #67 (cornered), #68 (the last turn of a stun), #69 (keep sight), #75 (the stop wording) and #80 (which enemy is "strongest") ship with them, so what goes out is the finished shape rather than a first cut |
| #74 option ranges · #77 BLACKOUT condition · #78 walking to a glowing chest · #79 non-linear life curve · #81 the FIGHT target filter | **in** — all built, closed and on `main`. They were labelled M5 while the label was about intent; a release is cut from `main`, so they were always going to be in the build. Moved to M4 on 2026-08-24 so the milestone says what the build contains |

M4 is not gates only: the open rows are work.

## 4. Gates

All green on the release commit, in this order; a tainted harness result is void. Every row
binds **both** 0.1.0 and 1.0.0 except the last two: the judgement gate binds 1.0.0 only (D-14),
and the two D-16 rows were added for 0.1.0 (2026-08-24) — whether a later `0.x` inherits them
is open.

| Gate | How |
|---|---|
| Parse in the game's dialect | `luajit -bl <file> /dev/null` over every `.lua` under `src/` and `spec/` |
| Lint clean | `luacheck .` — 0 warnings |
| Unit tests green under LuaJIT | `busted` (`.busted` pins the interpreter; `spec/dialect_spec.lua` fails it otherwise, and since #63 also scans `src/` and the devbridge for calls LuaJIT 2.0.2 does not have) |
| Harness scenarios pass, untainted | `scenario-surface.ps1` (every entry point, parity with the port) · `scenario-talent-screen.ps1` (#56, #55) · `scenario-stop-notices.ps1` (#57, #58) · `scenario-t011-trivial-damage.ps1` (#6) · `scenario-t012-freeze.ps1` (#7) · `scenario-t013-glowing-chest.ps1` (#8) · `scenario-t015-drowning.ps1` (#10) · `scenario-t016-label-accumulation.ps1` (#51) · `scenario-t019-stale-conditions.ps1` (#52). `scenario-baseline-v1.ps1` measures the *original* and is not a gate on this addon. Added 2026-08-23 and part of the gate: `scenario-t010-marked-target.ps1` (#5, real combat) · `scenario-keybinds.ps1` (#50) · `scenario-loadout.ps1` (#18) · `scenario-salvage-power.ps1` and `scenario-salvage-entrance.ps1` (#62) · `scenario-first-run.ps1` (#54) · `scenario-debug-channel.ps1` (#46) · `scenario-liveness.ps1` (#13) · `scenario-flee.ps1` (#59) · `scenario-hold.ps1` (#15) · `scenario-conditions.ps1` (#12) · `scenario-scoring.ps1` (#11) · `scenario-hooks.ps1` (#14) · `scenario-settings.ps1` (#90 -- the only scenario that RESTARTS the game, because a setting that does not survive a restart is invisible to every other one) · `scenario-greeting.ps1` (#72) · `scenario-life.ps1` (#91). **Run the whole set with `tools/run-scenarios.ps1`**, which records one JSON line per scenario under `build/results/` and re-runs a tainted one once; `scenario-walking-skeleton.ps1` is excluded as superseded. |
| The packed artifact loads standalone | `tools/pack.ps1 -Release`, then `tools/clean-build.ps1 -SkipPack` |
| #54 first-run pass done, #50 done, #18 done | #50 and #18 closed; #54's pass is done and all three of its findings (#71 #72 #73) are built, awaiting the owner's play check before they are closed |
| **Owner-tested, more than casually** (D-16) | The owner plays the release candidate. How much is their call and is deliberately not a scenario count — the harness proves the mechanics still work, and it cannot tell you whether the thing is pleasant to hand a character to. **Added 2026-08-24**, superseding D-14's ruling that 0.1.0 ships on the mechanical gates alone; a lighter bar than the judgement gate below, and not that gate moved back |
| **No partial issue implementations** (D-16) | Nothing in the build may be work that stopped at its symptom. An issue is not done because the thing that was reported went away: if its own argument still stands, it is either finished or its remaining scope is filed as its own issue before the release is cut. Closed issues count — the failure mode is a closed issue whose unfinished half is now untracked, which is invisible to every other gate here |
| **The judgement gate — 1.0.0 only** (D-14) | The owner plays the release candidate against 0.0.12 with the complaint themes in hand — marked-target talents stalling the rotation, stops on trivial damage, the pin / dominate / sleep freeze, glowing chests walked past, the talent menu overflowing, drowning while resting, configuration nobody could discover — and records the verdict. **Not a gate on 0.1.0 or any other `0.x`**, which is a beta handed to testers who were told what it is; it gates the first build that appears in the game's Addons browser, where the audience did not consent to being a tester. |

## 5. Explicitly not a gate

**The full 1→15 run.** Owner, 2026-08-23: *not really definable* — it depends on class, birth
and RNG, and the bot handing back is the feature, so "did it reach 15 unattended" is not a
pass/fail. Per-class soak runs are tracked long-term in **#61**; their results are information
for the judgement gate, not a condition of release.

## 6. Explicitly deferred

- **M2 Core model**: nothing left deferred. #11 scored evaluation (T-020), #12 condition
  framework and #14 superload minimisation were folded into `main` on 2026-08-23 (owner:
  *all code from builds A/B/C can be merged*), after #13, the progress invariant, and #46, the
  debug channel, earlier the same day. Their follow-ups are tracked as their own issues.
- **M5 Post-0.1**: nothing built is deferred any more. The owner ruled #59 flee and #15
  tempo-aware holding into 0.1.0 on 2026-08-24, and on the same day the other ten closed M5
  issues moved to M4 — #67 #68 #69 #75 #80 (the flee and hold follow-ups), #74, #77, #78, #79
  and #81. **The move was bookkeeping catching up with reality:** every one of them was
  already on `main`, a release is cut from `main`, so the label was describing an intention
  the build had already overtaken. M5 now holds nine open issues and nothing closed, which
  makes it mean what it says — work that has not been done.

  The rule that made this confusing is worth keeping in view: **what is on `main` is what a
  build contains.** A milestone cannot keep code out of a release; only not merging it can.
