# Salvage triage: yura9111's PR #48 to the original SkooBot

**Issues:** #17 (names the PR), #7 (the defect it targets), #13 (where its intent lands) ·
**Date:** 2026-08-23 · **Source:** `yura9111/tome4-SkooBot` @ `ffbddb1`, one commit on top of
SkooBot `2103961` (0.0.10 → 0.0.11 bump), +10/−1 across `init.lua` and
`superload/mod/class/Player.lua`. Opened 2019-10-31 against the original's issue #46
("Achieving SAI_STATE_EXPLORE after resting while being unable to move soft-locks the game"),
closed unmerged 2020-08-04.

This is the review D-10 asked for (*inherited fork/PR code is judged on the code and the
reasoning, never on provenance; everything merged is tested here; merit gates the testing*).
mishander's fork had [its own triage](salvage-mishander.md); this PR had none until now.

## What it does

A counter, `countSuccessiveAutoExploreActions`, incremented every time `SAI_beginExplore()`
calls `game.player:autoExplore()`, reset to zero whenever the bot is in any state other than
EXPLORE, and checked before each explore call:

```lua
if _M.skoobot.tempvals.countSuccessiveAutoExploreActions > 100 then
    return aiStop("#RED#AI Stopped: autoExplore infinite cycle detected.")
end
```

The author called it "somewhat of a dirty hack, but have no idea how to make a proper one and
the bug is CRITICAL". That is an accurate description, and no criticism: it is a backstop
against a loop whose cause they could not see, offered in good faith against a defect that
cost players characters.

## Verdict: reject the mechanism, credit the intent — both halves are already owned

| Half | Where it went |
|---|---|
| **The defect** — explore called while the character cannot move (pinned, dominated, asleep), which loops forever | Fixed at the root in 0.1 by #7: the explore branch is gated on `attr("never_move")`, the same predicate the engine's own `move()` uses, covering every immobilising effect and encumbrance; the sleep case (h-youhei's 2021 report on the same issue) is gated on `attr("sleep")`. Regression: `tools/scenario-t012-freeze.ps1`. |
| **The intent** — a backstop that stops the bot when it keeps doing the same thing and nothing happens | This is T-027 (#13), the liveness invariant — and #13 is explicitly a rejection of *this shape* of backstop. |

Why the mechanism does not survive its own review:

1. **It counts invocations, not progress.** A hundred `autoExplore()` calls is not evidence
   of a loop: on a large quiet level each call runs until something interrupts it (an item, a
   door, a new tile seen), and the bot re-enters explore without leaving the EXPLORE state, so
   a productive exploration and a frozen one look identical to the counter. v1's own
   `turnCount > 1000` guard has the same flaw and #13 replaces it for the same reason.
2. **It is scoped to one state.** The same spin in REST, HUNT or FIGHT is invisible to it. A
   progress invariant on `game.turn` — *an iteration that advanced no game time did nothing;
   N of those in a row is a livelock whatever the cause* — catches all of them, including
   causes nobody has imagined yet, and fires after a handful of no-ops rather than a hundred.
3. **It fires a stop with no diagnosis.** "autoExplore infinite cycle detected" tells the
   player nothing about why; #13 requires the AI state in the message so every trip is a bug
   report.
4. **It would have masked the root cause.** With this merged in 2019, the pin/sleep freeze
   becomes a mysterious stop after a pause rather than a freeze — less painful, and less
   likely to be found. #7 found it because the freeze was still there to reproduce.

No code is taken, so there is nothing to attribute in NOTICE; this document is the credit.
The reviewer's note on the original PR — that `autoExplore()` returning `false` was already
checked in 0.0.10 and the lock persisted — is consistent with the root cause being
`never_move`, which `autoExplore()` does not consult before the engine's move loop spins.

## Consequence

- #7: no change. Its scenario is the regression test for the defect this PR targeted.
- #13: this review is an input — the invocation-count design is now rejected twice, once by
  the original's author (`turnCount`) and once by a contributor (`countSuccessiveAutoExploreActions`),
  and both for the same defect class. The progress invariant should be written so that the
  T-012 scenario with the `never_move` guard *removed* trips it — that is the test that this
  backstop would have passed and the counter would have needed a hundred wasted turns to.
- #17: the PR is reviewed; the contribution-path failure it illustrates (a critical fix
  offered and never merged) stands as the motivating history.
