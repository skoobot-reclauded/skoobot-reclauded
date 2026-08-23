# Differentiation check

**Issue:** #19 · **Date:** 2026-08-23 · **Status:** checked against the M2/M5 direction;
re-run when a milestone closes

The question #19 asks: the category already has a maintained addon that does what SkooBot
did, so what is this one *for*, and is the work on the board still pointed at that? This
document answers it once and names the signs that would mean the answer has changed.

---

## 1. The category, and how everyone else in it works

Every player-autopilot addon for ToME descends from the same seed: the game's own `dumb_ai`,
the AI that plays the demo character behind the main menu. The line runs `dumb_ai` →
Charidan's *Player AI* → SkooBot (2018) on one branch, and Glavius' *Player GAI* (2018) →
ooli's *Player AIoo :idle TOME* (2024, on 1.7.6) on the other; *Auto Fight* and *ToME
Autobattler* sit beside them. When this project surveyed the category in 2026, AIoo was the
maintained alternative — a 2024 release for the current game, rated 4.3/5 on nine votes,
against the original SkooBot's 5.0/5 on seven votes and a last release in 2020 for 1.6.7. The
audience that wants this has somewhere to go. That is the risk #19 names.

**What the others do is re-point the NPC AI at the player.** This is verifiable in the
ancestor's code, which is public
([Charidan/Tales-of-Maj-Eyal-Player-AI](https://github.com/Charidan/Tales-of-Maj-Eyal-Player-AI)):
its `superload/mod/class/Player.lua` is a port of `dumb_ai` — a REST / EXPLORE / HUNT / FIGHT
state machine; the usable talents are exactly the ones the NPC AI is allowed
(`mode == "activated"`, not `no_npc_use`, not `no_dumb_use`); the target is the lowest-health
hostile in range; and the talent is chosen by `rng.range` over that list, under the comment
*"the AI is dumb and doesn't understand how powers work, so pick one at random"*. The
descendants keep the shape: the player sits in the NPC's seat and the engine's AI, or a copy
of it, drives. The engine's own tactical AI (`mod/ai/tactical.lua`, with `aiTalentTactics` in
`mod/class/interface/ActorAI.lua` weighing every talent's `tactical` table against what the
actor currently wants) is the obvious upgrade to that, and it is there for any addon to call
— which is precisely why wiring it up is not a differentiator. It is the crowded approach
because it is the cheap one.

## 2. What SkooBot does instead

Two things, and they are the whole product.

**Bespoke threat scoring that knows when to hand back.** `evaluatePowerLevel` (now
`data/power.lua`, a pure module) scores the character and every visible hostile on offence
and defence; `checkPowerLevel` compares the result against the *max individual*, *max
combined*, *max count* and *max difference* thresholds and hands control back when the fight
is one the bot should not be taking. The stop-condition list with its per-condition
WARN / STOP / IGNORE is the other half of the same idea: the bot declares where its model stops
being valid — stunned, asleep, a glowing chest in view — and gives the situation to the better
model, the player ([design-stop-conditions.md](design-stop-conditions.md) §2). An NPC AI has
no such notion. An NPC fights to the death by design; nothing in `dumb_ai` or the tactical AI
can say *"this is too dangerous for the one I am driving — give it back."*

**A talent-priority UI, so the bot plays the player's rotation.** The player places talents
in ordered sections — Combat, Damage Prevention, Recovery, Sustain — and the bot executes
that order (#56). It is a deliberate rotation, not a random pick and not a weight the engine
computed. The original's users singled this out as the thing they liked, and the ancestor has
nothing like it.

Together: *hand back when unsure, play my rotation when not*. A tedium remover for levels
1–15, not a substitute for the player. The README says the same in different words; this is
the mechanism behind it.

## 3. The current direction, checked against it

| Work | What it does | Verdict |
|---|---|---|
| **#11** scored situational evaluation (T-020, M2) | Replaces the flat special-case stop list with one score of the situation; mishander's rank-weighted ratios, HP-weighted own power and relative crowd threshold all feed it. The score answers *"should I be fighting this at all, or hand back?"* | **Keeps and deepens the scoring.** It does not adopt the tactical AI's want/avail weighting, and it does not choose talents. |
| **#18** presets and auto-discovery (0.1) | Reads each talent's `tactical` table — the metadata every ToME talent declares for the NPC AI: attack, heal, defend, escape, … — to place it in a starting section. **Explicitly does not call `aiTalentTactics`**, the NPC evaluator. | **Metadata in, evaluator out.** The game maintains the classification; the player's ordered list still decides what fires. The rejected alternative was mishander's name-string matching. |
| **#59** flee (M5) | Ports about twenty lines of the engine's flee logic as an action the bot places in its own loop, under its own stop conditions. | **A placed action, not NPC control.** The player is never handed to the engine's flee AI. |
| **#15** tempo-aware holding (M5) | A per-rule *hold while impaired* flag on the player's list ([design-stop-conditions.md](design-stop-conditions.md) §2.3). | Pure rotation UI. |
| **#12** condition framework, **#13** progress invariant (M2) | Liveness and model-validity made data-driven. | Extensions of the hand-back model. |

Nothing on the board moves toward the NPC seat. The two places where it could have —
classification for #18 and movement for #59 — both draw the line at using the engine's
*data* and not its *judgement*.

## 4. Conclusion, and the signs it is drifting

**Do not rebuild into the crowded approach.** Any of the following is a stop-and-discuss,
not a refactor:

- A call to `aiTalentTactics`, `doAI`, `runAI`, or anything under `mod/ai/` appears in
  `src/`; or `player.ai` / `ai_state` is set to drive the player.
- A `tactical` weight, or any engine-computed score, decides *which* talent fires rather
  than *where it starts* in the player's list.
- The order on the talent screen stops mattering — the bot "knows better".
- The power-level hand-back is removed, or defaulted off, in favour of fighting it out; or
  a losing fight no longer hands back at all.
- The pitch becomes *"plays the game for you"* rather than *"takes the tedium out and hands
  back."*

And the one sign that points the other way: if the scoring and the rotation UI both survive
and players still choose AIoo, the difference is **currency, not design** — the original lost
on targeting 1.6.7 while the game was 1.7.6, not on how it played. The remedy is keeping up
with ToME releases ([releasing.md](releasing.md) §1), not changing approach.
