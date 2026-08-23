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

1. **Minimised superload surface (#14) — post-0.1.** 0.1 ships the ported surface: three
   wrapper methods across two classes (`Player:act`, `Player:postUseTalent`,
   `Actor:tooltip`), nothing added to either class, no leaked globals. Smaller than
   0.0.12's, and not the #14 end state. Stated as the exception it is.
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
| Presets and auto-discovery (#18) — **GO for 0.1**, 2026-08-23 | open |
| Keybind collision detection (#50) | open, prerequisite |
| First-run UX pass (#54) — including the manifest `description`, which still says "early" | open, prerequisite |

M4 is not gates only: the last three rows are work.

## 4. Gates

All green on the release commit, in this order; a tainted harness result is void.

| Gate | How |
|---|---|
| Parse in the game's dialect | `luajit -bl <file> /dev/null` over every `.lua` under `src/` and `spec/` |
| Lint clean | `luacheck .` — 0 warnings |
| Unit tests green under LuaJIT | `busted` (`.busted` pins the interpreter; `spec/dialect_spec.lua` fails it otherwise) |
| Harness scenarios pass, untainted | `tools/scenario-walking-skeleton.ps1` (loads, takes control, hands back) · `scenario-surface.ps1` (every entry point, parity with the port) · `scenario-talent-screen.ps1` (#56, #55) · `scenario-stop-notices.ps1` (#57, #58) · `scenario-t011-trivial-damage.ps1` (#6) · `scenario-t012-freeze.ps1` (#7) · `scenario-t013-glowing-chest.ps1` (#8) · `scenario-t015-drowning.ps1` (#10) · `scenario-t016-label-accumulation.ps1` (#51) · `scenario-t019-stale-conditions.ps1` (#52). `scenario-baseline-v1.ps1` measures the *original* and is not a gate on this addon. Scenarios added for #18, #50 and #54 join this list. |
| The packed artifact loads standalone | `tools/pack.ps1 -Release`, then `tools/clean-build.ps1 -SkipPack` |
| #54 first-run pass done, #50 done, #18 done | their issues closed |
| **The judgement gate** | The owner plays the release candidate against 0.0.12 with the complaint themes in hand — marked-target talents stalling the rotation, stops on trivial damage, the pin / dominate / sleep freeze, glowing chests walked past, the talent menu overflowing, drowning while resting, configuration nobody could discover — and records the verdict on #32. |

## 5. Explicitly not a gate

**The full 1→15 run.** Owner, 2026-08-23: *not really definable* — it depends on class, birth
and RNG, and the bot handing back is the feature, so "did it reach 15 unattended" is not a
pass/fail. Per-class soak runs are tracked long-term in **#61**; their results are information
for the judgement gate, not a condition of release.

## 6. Explicitly deferred

- **M2 Core model**, after 0.1: #11 scored evaluation (T-020), #12 condition framework, #13
  progress invariant, #14 superload minimisation.
- **M5 Post-0.1**: #15 tempo-aware holding, #59 flee.
