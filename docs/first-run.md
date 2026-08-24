# First-run audit: what a new player sees

**Issue:** #54 · **Date:** 2026-08-23 · **Milestone:** M4 Release readiness ·
**Regression:** `tools/scenario-first-run.ps1`

Two audiences, walked end to end through the harness on the deterministic fixture
(`fixture-berserker`: a Cornac Berserker on Trollmire 1 with nothing configured) and, for the
coexistence flow, on a character made with both SkooBot addons installed:

1. **New to SkooBot: Reclauded** — migrating from the original SkooBot, or from other addons.
2. **New character** — setting the bot up from scratch.

This is the record of every flow: the exact strings the player sees (the scenario's `NOTE`
lines and the engine log, quoted verbatim), then the findings, each with a severity and the file
its fix belongs to. It is not a judgement of whether any of it *feels* right — that is the
owner's, in play, and §12 lists what only play can answer.

Severity: **must-fix-for-0.1** · **should** · **note**. Fixes in the files this pass owns
(`src/init.lua`, `Menu.lua`, the option wording in `hooks/load.lua`) are done on the `issue-54`
branch and cited by file; everything else is filed as an issue and cited by number in §11.

The walk is scripted, so it is repeatable: every flow below is one section of
`scenario-first-run.ps1`, and the strings quoted here are what it printed on 2026-08-23 against
`b5a6d96` plus this branch, at the harness's 800×600 window. Run it after any change to a
message, a dialog or the manifest.

---

## 1. Install, as a user would

**What the gate does.** `tools/clean-build.ps1` packs `src/` into `dist/tome-skoobot_reclauded-0.1.0.teaa`,
removes the product junction so nothing can load from the working tree, installs the archive
into `game/addons/`, loads the harness save and reads the engine's own `Binding addon` line
(design-harness.md §4.2). That is the install path a te4.org or Workshop user takes, minus the
download.

**What the in-game Addons list shows.** The boot menu's *Configure Addons* dialog
(`boot/mod/dialogs/Addons.lua`) has four columns: *Addon*, *Active*, *Addon Version*, *Game
Version*. For this addon, read back from the loaded manifest:

```
long_name=[SkooBot: Reclauded] addon_version=0.1.0 game_version=1.7.6
```

so the row reads **SkooBot: Reclauded · Auto: Active · 0.1.0 · 1.7.6**. **The list does not
show the description at all** — there is no description column and no detail pane. The
description is seen only on te4.org, on the Workshop page, and by anyone who opens the
`.teaa`. That is an engine fact, not a defect, but it means the description has to do its
whole job off-line, before the game is started.

**The description, before.** It ended *"Status: early. Not yet feature-complete against the
original."* — false since the port reached 0.0.12's feature set with the six user-reported
defects fixed (release-0.1.md §3), and the last thing a prospective user read.

**The description, after** (`src/init.lua`, this branch): six paragraphs, 1750 characters,
in this order — what it does; ENABLE IT BEFORE CREATING THE CHARACTER (the engine drops an
unlisted addon silently); how to start in game, with the default keys (`Shift+F7` menu,
`Shift+F3` start/stop, `Shift+F6` ask) and that they can be rebound; what "stops often" means
and that the stop policy is the player's; runs offline, no language model; a successor to the
original with the reported defects named, and the original untouched. The scenario asserts the
keys it names are the keybind file's defaults (`toggle=Shift+F3 menu=Shift+F7`), so a change
to the defaults cannot leave the listing stale.

Evidence (scenario §manifest, in-game):

```
manifest  long_name=[SkooBot: Reclauded] addon_version=0.1.0 game_version=1.7.6 source=directory
          early=false enable=true toggle=Shift+F3 menu=Shift+F7
          first=[An autopilot for levelling: hand your character to a bot that rests, explores
          and fights for you, and hands control back whenever it judges the situation needs you.]
```

`source=directory` is the development junction. The clean-build gate, run from this branch at
03:30, is the install path proper: `tome-skoobot_reclauded-0.1.0-gde83a04.teaa` (65 609
bytes) installed into `game/addons/` with the product junction removed, and the engine's own
line

```
Binding addon	SkooBot: Reclauded	/addons/tome-skoobot_reclauded-0.1.0-gde83a04.teaa	tome-skoobot_reclauded-1.7.6
```

— loaded from the archive, all four declared directories mounted, no `Removing addon`, no
Lua error, no development tooling in the archive. **PASS.**

**Findings.** F1 (must-fix-for-0.1, `src/init.lua`) — the "early" line: **fixed**. F2 (note)
— the Addons list cannot show the description; nothing to do, the README carries the same text.

## 2. First launch: what the player sees at load

Engine log (`te4_log.txt`), one line each, from `hooks/load.lua`:

```
[SKOOBOT] ready; Shift+F3 toggles, Shift+F7 opens the menu
[SKOOBOT] [Keybinds] checked 5 actions: no collisions
```

Message log, as the player sees it:

```
load-msgs  message-log lines mentioning SkooBot = 0 | collisions=0
```

**Nothing.** With no keybind collision, the addon says nothing a player can see at load. A
player who read the description knows the keys; one who installed from a list (the Workshop
shows the title first) or inherited a friend's addon set has no way to know Shift+F7 exists
short of the Key Bindings screen, and the bot does not make itself known until a key is
pressed.

The `ready` line goes to `te4_log.txt` only, and should: the log is for the harness and bug
reports. But once per character, while the character has no talent rules, one message-log line
would close the gap: *"[SkooBot] Ready. Shift+F7 opens the menu: set the talents it may use
(or let it suggest a loadout), then Shift+F3 starts it."*, keys through `keyFor()`, then never
again for that character.

**Findings.** F3 (should, `src/hooks/load.lua` `ToME:runDone`, not this pass's region) —
filed, §11.

## 3. New character, nothing configured: the first toggle

The fixture is what a new character looks like: `rules=0 class=Berserker level=1 zone=trollmire`,
stop conditions at their defaults (`Debuff: STUNNED=WARN … Power Level: CROWDPOWER=STOP`).

**Pressing Shift+F3 on the map**, from a spot with nothing in view. Message log:

```
SkooBot: Reclauded toggle requested!
```

and the bot auto-explores (`active=true state=SAI_STATE_EXPLORE running=true`). At the first
creature in view — here at game turn 10, one player turn in — it stops:

```
[SkooBot] Cannot act: no Combat talent is ready -- none configured, or all on cooldown
(set talent usage in the SkooBot: Reclauded menu, Shift+F7, or let the bot suggest a loadout
from the talent screen)
```

in orange, with the banner *SkooBot cannot act: no Combat talent is ready -- none configured,
or all on cooldown*. The same text is reproduced deterministically by the scenario's query-mode
probe (`dturn=0`), so the regression does not depend on what wanders into view.

**Is the path from that message to a working bot obvious?** The message names the key, the
menu, and the suggestion. From the message, the steps to a configured bot are:

| # | Press | See |
|---|---|---|
| 1 | `Shift+F7` | the menu: *a) Set Skill Usage* |
| 2 | `a` | the talent screen; first row *6 unassigned -- suggest a loadout?* is selected |
| 3 | `Enter` | the proposal: *1. Combat -- suggested (3)*, *2. Damage Prevention -- suggested (1)*, *3. Recovery -- suggested (2)*; the apply row first and selected |
| 4 | `Enter` | *Apply the suggested loadout*: *a) Merge: add 6 new, keep every row you placed* |
| 5 | `a` | back on the rules view, *Merged: 6 added, 0 removed, 0 left as you placed them.* in the description pane |
| 6 | `Escape`, `Shift+F3` | the bot runs |

Six keypresses, no typing, no reading of any document. The one weak link is step 1's wording
(*Set Skill Usage*, see §4). The text itself has one avoidable ambiguity: the code knows
whether the Combat section is empty or merely on cooldown, and the message hedges
(*none configured, or all on cooldown*). A new character should read *no Combat talent is
configured*; a mid-fight player should read *every Combat talent is on cooldown*.

**Changed since (#71).** It does now. A character with no Combat row at all reads *Cannot act:
no Combat talent is configured*, with the same hint; rows that exist and could not be used this
turn read *no Combat talent is ready -- every one is on cooldown or unusable*; the two holding
cases (#75) are unchanged. What is counted is configured ROWS, not resolved talents, so a rule
naming a talent this character does not have is not reported as nothing configured.

**Findings.** F4 (should, `Player.lua` the cooldown site) — filed with the stop-text issue, §11,
and fixed there (#71).

## 4. The menu

`Shift+F7`:

```
title=[SkooBot: Reclauded]
rows=[a) Set Skill Usage | b) Activate/Deactivate Bot Stop Conditions | c) Cancel | Keybinds: OK]
w=413 h=381 game=800x600
```

The keybind status line (#50) reads *Keybinds: OK* in grey, and with a collision *Keybinds: 1
collision (see log)* in orange with the pair under it — `scenario-keybinds.ps1` covers that
state; it reads well.

**Before this branch** the menu was those four rows and nothing else: no key named, nothing
that says what *Skill Usage* is or how to begin. **After** (`Menu.lua`), a help paragraph
under the rows, every key looked up from the live binding (#57) so a remap shows:

```
How to start: a) put the talents the bot may use in its sections (or let its first row suggest
a loadout), then press Shift+F3 on the map. It rests, explores and fights, and hands back with a
[SkooBot] line saying why.
Keys: Shift+F3 start or stop, Shift+F4 stop, Shift+F5 one action, Shift+F6 say what it would do
next, Shift+F7 this menu. Change them under Escape > Key Bindings; the thresholds are under
Escape > Options > [SkooBot: Reclauded].
```

The menu still fits the screen at 800×600 (413×381).

**Changed since (#73).** The two choice names were v1's. *Set Skill Usage* is the talent-rules
screen; *Activate/Deactivate Bot Stop Conditions* is neither activate nor deactivate but a
WARN / STOP / IGNORE choice. They read *a) Talent rules -- which talents the bot may use* and
*b) Stop conditions -- when it hands back* now. They were left alone on the night of this pass
because `tools/scenario-keybinds.ps1` asserts the three names verbatim in two places and that
file was another lane's; the rename moved both files together, as predicted.

**Findings.** F5 (`Menu.lua` + `scenario-keybinds.ps1`) — filed as #73 and fixed there.
F6 (done, `Menu.lua`) — the help paragraph.

## 5. The talent screen from scratch

From the menu, *a)*:

```
title=[SkooBot: Reclauded - talent rules]
first=[6 unassigned -- suggest a loadout?]
headers=[1. Combat(0) | 2. Damage Prevention(0) | 3. Recovery(0) | 4. Sustain(0) | Available(6)]
h=600 game.h=600
```

The tutorial pane (top right) explains sections, priority, drag, the keys (1–4, 0/Delete,
Shift+Up/Down) and the suggestion; the description pane shows the selected row. A level-1
Berserker has six usable things: Attack, Warshout, Stunning Blow, and the three starting
infusions (wild, healing, regeneration).

**Enter on the first row** (the proposal):

```
entries=6 unassigned=0 skipped=0 choices=0
headers=[1. Combat -- suggested(3) | 2. Damage Prevention -- suggested(1) | 3. Recovery -- suggested(2)
         | 4. Sustain -- suggested(0) | Not placed (0) | Your choice (0)]
first=[Apply this suggestion...  (Enter: Merge / Replace / Cancel)]
rows=[Combat:T_WARSHOUT_BERSERKER, Combat:T_STUNNING_BLOW_ASSAULT, Combat:T_ATTACK,
      DamagePrevention:T_INFUSION:_WILD_2, Recovery:T_INFUSION:_HEALING_3, Recovery:T_INFUSION:_REGENERATION_1]
```

with the intro in the description pane (*This is a suggestion, read from the game's own talent
data: nothing has been written…*). Sensible for the class: the two cooldown talents ahead of
the basic attack, the wild infusion as damage prevention, healing and regeneration as recovery.

**Enter again** (the action menu):

```
title=[Apply the suggested loadout]
names=[a) Merge: add 6 new, keep every row you placed
     | b) Replace: clear the 0 current rows, write the 6 suggested
     | c) Cancel: write nothing]
```

Each answer says what it writes; Cancel returns to the proposal with nothing written. Merge:

```
proposal=false count=6 per=[Combat=3 DamagePrevention=1 Recovery=2 Sustain=0]
first=[Suggest a loadout...] said=true
```

— back on the rules view, the first row no longer carries a count, and the pane says what was
done. *Replace* over a non-empty list asks first, with *Keep them* focused
(`scenario-loadout.ps1`).

**The same walk on a second fresh character**, a Cornac Archer made for this pass
(`firstrun-archer`, 110 life): *7 unassigned -- suggest a loadout?* over *Available(8)*; the
proposal is Combat = Steady Shot, Headshot, Attack, Shoot; Damage Prevention = wild infusion;
Recovery = healing, regeneration; one talent under *Not placed (1)* with its reason. The
complaint that started the rebuild — an archer with Headshot stuck in the rotation (#5) — is
exactly this loadout, and the #5 fallthrough is what lets it run; the walk's first stop with it
was the stairs hand-back after 833 player turns (§9).

**Findings.** None to fix. F7 (note) — *clear the 0 current rows* on a fresh character is
grammatical but odd; harmless.

## 6. The stop-conditions dialogs

From the menu, *b)*. **Before**: *Pick a condition to customize* → *Pick a stop condition for:
DEBUFF_STUNNED* → `a) IGNORE | b) WARN | c) STOP`, the code as the title and no word about
what the three do. **After** (`Menu.lua`, this branch):

```
picker=[Stop conditions: pick one to change] items=14
  [a) Debuff: STUNNED - WARN | b) Debuff: CONFUSED - WARN | c) Debuff: DAZED - WARN
   | d) Debuff: FROZEN - WARN | e) Debuff: ASLEEP - WARN | f) Life: BIGLOSS - WARN
   | g) Life: LOWLIFE - STOP | h) Dialog: LORE - IGNORE | i) Terrain: Glowing Chest - WARN
   | j) Power Level: ENEMYCOUNT - STOP | k) Power Level: BIGENEMY - STOP
   | l) Power Level: STRONGERENEMY - STOP | m) Power Level: CROWDPOWER - STOP]
policy=[Debuff: STUNNED -- what should the bot do?]
options=[a) IGNORE -- never stop for this | b) WARN -- stop once, then carry on if restarted
       | c) STOP -- stop every time it applies]
after=WARN top=none
```

The three answers now say what they do (the semantics are `checkStop`'s: WARN stops once and
is remembered until the condition clears; STOP stops on every decision it holds for; IGNORE
never stops), and the second dialog names the condition by its label.

**The labels are still codes in capitals**: *Life: BIGLOSS*, *Power Level: STRONGERENEMY*,
*Dialog: LORE*. A player cannot tell BIGENEMY from STRONGERENEMY from CROWDPOWER without the
options tab, which since this branch explains them — under different names. The labels live in
`M.LIST` (`src/data/conditions.lua`, where #12 moved them from v1's `DEFAULT_CONDITIONS`);
`conditions.isCurrent` compares labels, so a rename reconciles a saved list on first load with
the player's choices kept, which is exactly what the #52 reconcile is for.

**Changed since (#71).** They are words: *Stunned*, *Confused*, *Dazed*, *Frozen*, *Asleep*,
*Turns lost while unable to act*, *Big life loss in one turn*, *Low life with enemies in view*,
*A lore dialog opened*, *Glowing chest in view*, *Too many enemies in view*, *An enemy above
Maximum Enemy Power*, *An enemy too far above your power*, *Enemies together too far above your
power* — the last three naming the options-tab titles they are compared against. The reconcile
did what it is for: a saved list takes the new labels on first load and every WARN / STOP /
IGNORE choice survives.

**Findings.** F8 (should, `Player.lua` `DEFAULT_CONDITIONS`) — filed with the stop-text
issue, §11, and fixed there (#71). F9 (done, `Menu.lua`) — the policy wording.

## 7. The options tab

Escape › Options › *[SkooBot: Reclauded]*. Eleven entries, every one with a description and
no capitals (`entries=11 empty=0 shouting=0`). **Before** — the two power titles read backwards
(`MAX_INDIVIDUAL_POWER` was *Max enemy power level*, `MAX_DIFF_POWER` was *Maximum Individual
Enemy Power*), "power level" was never explained, the combined-power text no longer matched
what #62 made it, *Action Delay* shouted in capitals, and the life ratios said "percent" for a
fraction. **After** (`hooks/load.lua`, this branch; keys and order unchanged, titles the
CHANGELOG names kept):

| Title | Value | Description |
|---|---|---|
| Low Health Ratio | 0.5 | A fraction of your maximum life (0.5 is half). While enemies are in view, the bot stops when life is below it. The other life thresholds follow from it: losing half of this fraction in one turn is the Big Loss stop; in a fight, losing a quarter of it in one turn uses a Damage Prevention talent, and missing a quarter of it uses a Recovery talent. |
| Ignore Damage Above Life Ratio | 0.9 | A fraction of your maximum life (0.9 is nine tenths). While exploring with nothing in view, damage is ignored as long as life stays above it, so a single poison tick does not stop the bot; once life is below it, any damage taken while exploring hands back. It is also the scale that stop is measured on: life exactly at this ratio is threat 1, and twice as far below it is threat 2. See Maximum Enemy Power. |
| Maximum Enemy Power | 200 | Stop when any enemy in view has a power level above this figure, whatever yours is. Power level is the addon's rough threat score for a creature -- its life, damage, crits, speed, defence, stats and weapons summed -- and is shown as "Power Level" in every creature's tooltip; hold Ctrl over a creature to see the parts.<br><br>These five limits are also a scale: every stop for one of them ends "-- threat N", where the limit you set counts as 1, so threat 3 is three times past it. The stop says how far over the room is, not only that it is. |
| Maximum Enemy Power Above Yours | 10 | Stop when any enemy in view has a power level more than this much above your own. Your own power level is scaled by the life you have left, so the same enemy stops the bot sooner when you are hurt. On the threat scale, 1 is an enemy exactly this far above you. Power level and the threat figure: see Maximum Enemy Power. |
| Maximum Combined Enemy Power | 500 | Stop when the power levels of every enemy in view, added together, are more than this much above your own (again scaled by the life you have left). A margin above yours, not an absolute figure. On the threat scale, 1 is a room exactly this far above you. Power level and the threat figure: see Maximum Enemy Power. |
| Maximum Enemy Count | 12 | Stop when more than this many enemies are in view at once, whatever their power. On the threat scale, 1 is exactly this many in view -- twelve of them against a limit of twelve. The threat figure: see Maximum Enemy Power. |
| Normal Enemy Power Ratio | 0.4 | Critters and normal-rank enemies count for this multiple of their power level in the three power checks above: 0.4 means a common counts for less than half, so a pack of them does not read as a threat; 1 is face value. |
| Elite Enemy Power Ratio | 1 | Elite, rare and unique enemies count for this multiple of their power level in the three power checks above: 1 is face value; 2 would count each as double. |
| Boss Enemy Power Ratio | 2 | Bosses, elite bosses and anything stronger count for this multiple of their power level in the three power checks above: 2 counts each as double; 1 is face value. |
| Action Delay | 0 | Seconds the bot waits between its actions, so you can watch what it does. 0 acts at full speed. Known to be rough: with a delay set, the bot also takes its next action when you press a key or move the mouse. |
| Popup when the bot stops | disabled | Also open a popup with the reason whenever the bot stops for something you should look at: low life, a debuff, being stuck. The message-log line and the banner are always shown. The popup's own checkbox turns this off again. |

The scenario reads all eleven back from the live tab and asserts the retitled pair, the
power-level clause, the margin wording and the absence of capitals.

**Fixed since this pass (#74):** selecting any numerical entry used to open the engine's
quantity prompt with *From 0 to 1000000*, because `createNumericalOption` was called without a
range. For the two life fractions that invited *50* for 50%, which is a threshold above maximum
life and a bot that stops at the first enemy. The number box accepts decimals, so only the
range was wrong. The two life fractions now prompt *From 0 to 1* and the three rank ratios
*From 0 to 10*; the power figures, the enemy count and the delay keep the open range, having no
natural ceiling. The minimum is enforced too, which it never was — it is `GetQuantity`'s sixth
argument, after the callback, and was simply never passed. A value already saved outside a
range is left alone; `Numberbox` bounds on edit, so this changes what can be typed and not what
is stored.

**Findings.** F10 (done, `hooks/load.lua` wording). F11 (`hooks/load.lua`
`createNumericalOption` calls) — filed as #74 and fixed there.

## 8. Coexistence with the original SkooBot

Run with a scratch copy of the original (0.0.12, `ad23dea`) junctioned in as
`game/addons/tome-skoobot` for the duration of the run only — never the research archive's
clone, and removed by the runner's `finally` (confirmed absent afterwards) — and a character
`coexist` made by `new-character.ps1 -RequiredAddons skoobot,skoobot_reclauded,skoobot_devbridge`
(a random class; the save lists `ashes-urhrok, cults, items-vault, orcs, skoobot,
skoobot_devbridge, skoobot_reclauded`).

- **Both load.** Engine log:
  ```
  Binding addon	SkooBot	nil	tome-skoobot-1.6.7
  Binding addon	SkooBot: Reclauded	nil	tome-skoobot_reclauded-1.7.6
  ```
  (1.6.7 is "nearly same" as 1.7.6 by the engine's rule, so the original loads as compatible.)
- **Both menus open on their own keys.** `Shift+F2` → *SkooBot Menu* (`a) Set Skill Usage |
  b) Activate/Deactivate Bot Stop Conditions | c) Cancel`); `Shift+F7` → *SkooBot: Reclauded*
  with the same three rows plus *Keybinds: OK*. The original's Alt+F1 / Shift+F1 / Alt+F2 /
  Alt+F3 / Shift+F2 and this addon's Shift+F3–F7 are disjoint, so #50's check finds nothing
  (`collisions=0 []`). Note that a migrating player sees **two menus with identical rows** —
  one more reason for F5.
- **The same question, both answers.** With nothing configured, the original's query
  (`Alt+F3`) says *"[Skoobot] [Combat] [Movement] All Combat talents on cooldown! / Have you
  configured talent usage? (Shift+F2 by default)"* — a hard-coded key; this addon's
  (`Shift+F6`) says *"[SkooBot] Cannot act: no Combat talent is ready -- none configured, or
  all on cooldown (set talent usage in the SkooBot: Reclauded menu, Shift+F7, or let the bot
  suggest a loadout from the talent screen)"* — the live key. Both leave both bots inactive.
  Since #71 this addon's half reads *no Combat talent is configured*, with the same hint.
- **No shared state.** `v1: ai_active=nil skoobot_start=true | ours: table=true active=false |
  v1 fields on player: autotalents=false stopconditions=false | ours: false` — nothing written
  on the player by either until it is configured; the original's settings live under
  `config.settings.tome.SkooBot`, this addon's under `config.settings.tome.skoobot_reclauded`
  (`v1 LOWHEALTH=0.5 ours LOWHEALTH=0.5`, each its own default).
- **No Lua error** with both bound.
- **One visible overlap:** `power_level_lines=2` — both superload `Actor:tooltip` and each adds
  a *Power Level* line, so a creature's tooltip carries it twice. Cosmetic, only with both
  installed, and the same formula (power.lua is the port of the original's). Since #14 ours
  is the engine's `Actor:tooltip` hook rather than a superload; the count is unchanged.

**Findings.** F12 (note) — the doubled tooltip line; not worth a guard for a configuration
nobody should keep.

## 9. The first stop

With the suggested loadout merged (§5) and the popup setting on for the run, `Shift+F3` from a
quiet spot on Trollmire 1. The bot explored and fought for 598 player turns (game turn 10 →
5990, 130 bot actions), killed a forest troll, reached level 2, and handed back:

```
message log   fixture-berserker killed Forest troll!
              [SkooBot] Handed back: you have unspent points to allocate
banner        SkooBot handed back: you have unspent points to allocate
popup         none   (HANDED_BACK never opens it; only STOPPED does)
```

Understandable cold: the bot stopped because the player has a level-up to spend. In gold, under
the `[SkooBot]` prefix, and on the banner. No power-level stop fired in those 598 turns with
the defaults (the soak under #61 measures that over hours; this is one run). The other two
first stops seen in this pass were the stairs: *Ran for 4 turns (stop reason: interesting
terrain). / [SkooBot] Handed back: standing on a level change* (fixture, second run, turn
2460) and *Ran for 54 turns (stop reason: at exit). / [SkooBot] Handed back: standing on a
level change* (the Archer, turn 8330, 105 actions) — the game's own auto-explore line
immediately above the bot's, which together read as one event.

**The texts a player would meet next are the ones to fix.** Every power-level and life stop is
worded in setting keys, which the player has never seen — since this branch the options tab
names them differently, by title:

```
Stopped: life is below LOWHEALTH_RATIO (restart with Shift+F3)
Stopped: took damage while exploring, and life is below IGNORE_DAMAGE_HEALTH_RATIO (restart with Shift+F3)
Stopped: an enemy's power level, 52, is above MAX_INDIVIDUAL_POWER (restart with Shift+F3)
Stopped: an enemy's power level, 52, is more than MAX_DIFF_POWER above yours (31.2 at current life) (restart with Shift+F3)
Stopped: the combined enemy power level, 140, is more than MAX_COMBINED_POWER above yours (31.2 at current life) (restart with Shift+F3)
Stopped: 13 enemies in sight, above MAX_ENEMY_COUNT (restart with Shift+F3)
Stopped: lost more than 25% of max life in one turn (half of LOWHEALTH_RATIO) (restart with Shift+F3)
```

**Changed since (#71, #91).** They name the option's title as the tab shows it, and the
number compared against. The life stops print the ratio itself rather than *half of maximum*,
so the wording holds at any setting; the power levels are whole since #84; and since #91 the
life figures are shares of the POOL the game kills at, not of maximum life, which for anything
carrying `die_at` is a different number:

```
Stopped: 41% of your life pool -- below 0.5 (Low Health Ratio)
Stopped: took damage while exploring with life below 0.9 of your life pool (Ignore Damage Above Life Ratio)
Stopped: an enemy's power level, 52, is above 200 (Maximum Enemy Power)
Stopped: an enemy's power level, 52, is more than 10 above yours, 31 at current life (Maximum Enemy Power Above Yours)
Stopped: the enemies in view add up to 140, more than 500 above yours, 31 at current life (Maximum Combined Enemy Power)
Stopped: 13 enemies in sight, more than 12 (Maximum Enemy Count)
Stopped: lost more than 25% of your life pool in one turn (half of Low Health Ratio)
```

The rest of the stop family reads well as it is: *cannot move (pinned, held, or overloaded)*,
*you are stunned*, *a glowing chest is nearby -- open it yourself, they can be guarded*,
*standing on a level change*, *a dialog is open: …*, *suffocating, and no reachable air*,
*below half breath*, *disabled by the player*.

**`data/notice.lua`.** This pass owns it and changed nothing: the prefix, the three labels
(*Stopped / Handed back / Cannot act*), the colours and the line / banner / popup shapes are
what the harness and `tools/soak.ps1` parse, and they read correctly. Every wording problem
found is in the reason text, which lives at the call sites in `Player.lua`.

**Findings.** F13 (should, `Player.lua` stop texts) — filed with F4 and F8 as one issue, §11.

## 10. Runs on this branch

All from the `issue-54` worktree on 2026-08-23, junctions repointed by `setup-dev.ps1` before
each, under the game lease; none tainted.

| Run | Result |
|---|---|
| `scenario-first-run.ps1` on `fixture-berserker` (03:15, 03:27, 03:29) | the first two failed only on the probe's own newline trap (fixed in the scenario; every product string was on screen); the third **PASS, 51 checks**. First stops: level-up hand-back at turn 5990 (598 player turns, 130 actions), stairs hand-back at turn 2460, level-up hand-back at turn 7200 |
| `clean-build.ps1` (03:30) | **PASS** — §1 |
| `scenario-first-run.ps1 -CoexistenceOnly` with the original junctioned (03:30) | **PASS** — §8; `coexist` save created; junction removed afterwards |
| `run-scenarios.ps1 -Only first-run,surface,talent-screen,keybinds,loadout,stop-notices` (03:31) | **PASS=6** — first-run 27 s, keybinds 17 s, loadout 17 s, stop-notices 15 s, surface 35 s, talent-screen 16 s; `build/results/2026-08-23.jsonl` |
| `new-character.ps1 -Name firstrun-archer -Class Archer` (03:58), then `scenario-first-run.ps1 -SaveName firstrun-archer -SkipCoexistence` (03:59) | **PASS, 51 checks** on a second fresh character — §5 and §9 |
| `run-scenarios.ps1` (the whole library, 15 with this one; 03:34) | **PASS=15**, no taint, 14–35 s each: first-run, keybinds, loadout, salvage-entrance, salvage-power, stop-notices, surface, t010-marked-target, t011-trivial-damage, t012-freeze, t013-glowing-chest, t015-drowning, t016-label-accumulation, t019-stale-conditions, talent-screen |

## 11. Findings, by severity

| # | Severity | Where | Finding | State |
|---|---|---|---|---|
| F1 | must-fix-for-0.1 | `src/init.lua` | description said "Status: early. Not yet feature-complete" | **fixed** |
| F10 | should | `src/hooks/load.lua` (wording) | two power titles read backwards; "power level" unexplained; combined power no longer a margin; shouting | **fixed** |
| F6 | should | `Menu.lua` | the menu named no key and gave no way in | **fixed** (help paragraph) |
| F9 | should | `Menu.lua` | WARN / STOP / IGNORE unexplained; condition shown by code | **fixed** |
| F13, F4, F8 | should | `Player.lua` | stop texts in setting keys; cooldown text hedges; condition labels are codes | **fixed** (#71) |
| F3 | should | `src/hooks/load.lua` `ToME:runDone` | nothing visible at load on a fresh character | **fixed** (#72) |
| F5 | should | `Menu.lua` + `scenario-keybinds.ps1` | *Set Skill Usage* / *Activate/Deactivate…* | **fixed** (#73) |
| F11 | should | `src/hooks/load.lua` (ranges) | every option prompts *From 0 to 1000000* | **fixed** (#74) |
| F2 | note | engine | the Addons list shows no description | nothing to do |
| F7 | note | `TalentDialog.lua` | *clear the 0 current rows* on a fresh character | nothing to do |
| F12 | note | both addons | tooltip *Power Level* twice with both installed | nothing to do |

Nothing in this walk is a must-fix beyond F1. The rest is readability, and the owner decides in
the morning which of the filed issues are 0.1 and which are after.

## 12. What only play can judge

- Whether the menu's help paragraph is the right length — it is five wrapped lines at 413 px.
- Whether *Keys: … Shift+F4 stop* beside *Shift+F3 start or stop* reads as redundant or as
  reassuring (the stop key exists because the toggle is hard to land while the bot acts).
- Whether the suggested Berserker loadout (§5) is what a player would have chosen, and how the
  proposal reads on a caster with exclusive sustains (*Your choice*).
- Whether the first stop on a fresh character — the level-up hand-back after ~600 turns —
  arrives too late to feel safe, or whether the silence while it explores is fine.
- Whether the description's closing list of fixed defects belongs on a store page or in the
  CHANGELOG only.
