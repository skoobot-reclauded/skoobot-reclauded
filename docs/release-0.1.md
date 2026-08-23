# What makes 0.1 releasable

**Issue:** #32 · **Date:** 2026-08-23 · **Milestone:** M4 Release readiness

The owner's decisions, recorded so the gate list is not re-derived: **D-11** (2026-08-21,
*0.1 is v1's feature set working on 1.7.6, and a meaningful improvement on the last public
SkooBot*) and the 2026-08-23 rulings on presets, the 1→15 run and the release flow. How the
release is then cut is [releasing.md](releasing.md).

---

## 1. The bar

- **Floor:** SkooBot 0.0.12's feature set working on ToME 1.7.6 — rest, explore and fight for
  levels 1–15, the talent-section screen, the stop conditions with WARN / STOP / IGNORE.
- **Bar:** *a meaningful improvement over SkooBot 0.0.12 at its best.* The comparison point is
  the original as it played in 2019–2020, not as it was abandoned; "it loads on 1.7.6" is
  necessary and not sufficient. This is a **judgement the owner makes at release time against
  the complaint record**. It is not automatable and nothing below pretends it is.

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
| First-run UX pass (#54) — the manifest `description`, option wording, menu help, `docs/first-run.md` | pass done (`9c80862..5b13da1`); its findings are #71 #72 #73 (M4) and #74 (M5), open for the owner's triage |
| mishander's remaining takes — rank-weighted ratios, life-scaled own power, relative crowd threshold, level-entrance start (#62) | in (`d3becd0..9c2b081`) |
| Progress invariant replacing the turn-count stop (#13) | in (`29ee928`) — built ahead of M2 because it is small and regression-netted |
| Levelled debug channel (#46) | in (`a0b8a11`) |
| Flee action (#59) and hold-while-impaired (#15) | **built, on `main`, still M5** — implemented on the owner's "all work available" instruction; whether 0.1 ships them is the owner's call |

M4 is not gates only: the open rows are work.

## 4. Gates

All green on the release commit, in this order; a tainted harness result is void.

| Gate | How |
|---|---|
| Parse in the game's dialect | `luajit -bl <file> /dev/null` over every `.lua` under `src/` and `spec/` |
| Lint clean | `luacheck .` — 0 warnings |
| Unit tests green under LuaJIT | `busted` (`.busted` pins the interpreter; `spec/dialect_spec.lua` fails it otherwise) |
| Harness scenarios pass, untainted | `scenario-surface.ps1` (every entry point, parity with the port) · `scenario-talent-screen.ps1` (#56, #55) · `scenario-stop-notices.ps1` (#57, #58) · `scenario-t011-trivial-damage.ps1` (#6) · `scenario-t012-freeze.ps1` (#7) · `scenario-t013-glowing-chest.ps1` (#8) · `scenario-t015-drowning.ps1` (#10) · `scenario-t016-label-accumulation.ps1` (#51) · `scenario-t019-stale-conditions.ps1` (#52). `scenario-baseline-v1.ps1` measures the *original* and is not a gate on this addon. Added 2026-08-23 and part of the gate: `scenario-t010-marked-target.ps1` (#5, real combat) · `scenario-keybinds.ps1` (#50) · `scenario-loadout.ps1` (#18) · `scenario-salvage-power.ps1` and `scenario-salvage-entrance.ps1` (#62) · `scenario-first-run.ps1` (#54) · `scenario-debug-channel.ps1` (#46) · `scenario-liveness.ps1` (#13) · `scenario-flee.ps1` (#59) · `scenario-hold.ps1` (#15) · `scenario-conditions.ps1` (#12) · `scenario-scoring.ps1` (#11) · `scenario-hooks.ps1` (#14). **Run the whole set with `tools/run-scenarios.ps1`**, which records one JSON line per scenario under `build/results/` and re-runs a tainted one once; `scenario-walking-skeleton.ps1` is excluded as superseded. |
| The packed artifact loads standalone | `tools/pack.ps1 -Release`, then `tools/clean-build.ps1 -SkipPack` |
| #54 first-run pass done, #50 done, #18 done | #50 and #18 closed; #54's pass is done and its must-fix findings (#71 #72 #73) are closed or explicitly deferred by the owner |
| **The judgement gate** | The owner plays the release candidate against 0.0.12 with the complaint themes in hand — marked-target talents stalling the rotation, stops on trivial damage, the pin / dominate / sleep freeze, glowing chests walked past, the talent menu overflowing, drowning while resting, configuration nobody could discover — and records the verdict on #32. |

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
- **M5 Post-0.1**: #15 tempo-aware holding and #59 flee are *built* (see §3) but stay M5 until
  the owner rules them into 0.1; #67 #68 #69 #75 are their follow-ups.
