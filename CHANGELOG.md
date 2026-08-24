# Changelog

All notable changes to SkooBot: Reclauded, for players. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the `addon_version` in
`src/init.lua` and are tagged `v<version>`. Issue numbers (`#n`) refer to this repository's
tracker.

Nothing has been released yet. The first release will be **0.1.0**; the baseline it is measured
against is the original SkooBot's last public version, **0.0.12**, and this section lists what is
different from it. How a release is cut: [docs/releasing.md](docs/releasing.md).

## [Unreleased]

### Added

- **The addon itself**: SkooBot 0.0.12 ported to Tales of Maj'Eyal 1.7.6 as a separate addon,
  `skoobot_reclauded`. It can be installed alongside the original SkooBot: its settings, its
  keys and its menus are its own, and neither addon reads the other's.
- **Glowing chests**: the bot hands back while an unopened glowing chest is in view, so you
  decide whether to open one. A new stop condition, *Terrain: Glowing Chest*, default WARN; set
  it to IGNORE to walk past as 0.0.12 did (#8).
- **Ignore scratches while exploring**: a new option, *Ignore Damage Above Life Ratio* (default
  0.9). Damage taken while exploring hands back only once life has fallen below it; a single
  poison tick no longer stops the bot (#6).
- **Items in the talent screen**: a worn item with a usable power is listed under its own name,
  not as "Activate Object", and its rule follows the item rather than the slot it sits in (#55).
- **Stop popup** (off by default): the option *Popup when the bot stops* shows a popup on every
  stop, with a "Don't show this popup again" checkbox (#58).
- **Suggest a loadout**: the talent screen's first row reads a suggested set of rules off the
  game's own talent data -- which talents attack, heal, defend, or are kept up -- and shows it
  with a reason per row before anything is written. *Merge* adds what is new and keeps every row
  you placed yourself; *Replace* clears the list first and asks. Mutually exclusive sustains (the
  chants, the hymns) are left for you to pick. The "no Combat talent is ready" stop points at
  it (#18).
- **Keybind collisions are reported, never fixed for you**: if another addon or the base game
  has an action on one of SkooBot: Reclauded's keys, one `[SkooBot]` line says which two
  actions share it and points at Escape > Key Bindings, and the menu shows *Keybinds: N
  collisions* with the pairs. Nothing is rebound (#50).
- **Threat checks from mishander's fork** (#62): each visible enemy's power counts at 0.4
  for normal rank, 1.0 for elites and rares, 2.0 for bosses (three new options, *Normal /
  Elite / Boss Power Ratio*), so a pack of commons no longer stops the bot where one rare would
  not; your own power is scaled by remaining life when compared, so the same enemy hands back
  sooner when you are hurt; and *Maximum Combined Enemy Power* now means *above your own
  power* rather than an absolute figure. Toggling the bot on the stairs you arrived by explores
  instead of handing back at once.
- **Flee** (#59): two built-in rows in the talent screen's Available list -- *Flee from the
  nearest hostile* and *Flee from the strongest hostile* -- can be placed in Combat like a
  talent. Where the rotation reaches one and a hostile is in view, the bot takes one step that
  increases its distance (preferring a tile the hostile cannot see); with no such step it is
  skipped like a talent on cooldown. Ask (Shift+F6) reports "would flee from <name> to the
  <direction>".
- **Hold while impaired** (#15): Space on a Combat row marks it *held*; while you are stunned,
  dazed, confused or frozen a held talent is skipped and the rotation falls through. Only
  meaningful when the matching stop condition is set to WARN or IGNORE.
- **Log level** (#46): a *Log level* entry on the options tab (off / error / warn / info / debug
  / trace; default info). Everything the bot does goes to `te4_log.txt` under `[SKOOBOT]`; only
  warnings and errors reach the message log.
- **A threat score, and a posture** (#11): the four power-level options and *Ignore Damage
  Above Life Ratio* are now the scale of one score -- 1 is the worst of your limits, 3 is three
  times over it -- and every power-level stop says it ("... above yours (52.0 at current life)
  -- threat 2.3"). With the stop conditions at their defaults nothing else changes. Set a
  power-level condition to IGNORE, or restart past a WARN, and the bot now plays the
  situation rather than charging: a step away from a single enemy over your limit while it
  is not yet adjacent, a wait for a crowd over your limit to come into reach. Every creature's
  tooltip shows the figure the bot counts it for beside the raw power level ("counts as 48 to
  SkooBot (x0.4 normal)"; your own "at 65% life").

### Changed

- **Talent screen rebuilt.** One sectioned list — Combat, Damage Prevention, Recovery,
  Sustain, plus Unassigned for everything else — with the selected talent's description beside
  it. Order within a section is priority. Move a talent by dragging it, with the keyboard
  (1–4 to a section, 0 or Delete to unassign, Shift+Up/Down to reorder) or through a menu on
  the row; a talent may sit in more than one section. The add → use type → priority chain of
  dialogs is gone. A 0.0.12-style configuration migrates on first open with its order kept
  (#56).
- **Stops are one kind of message.** Every stop is a `[SkooBot]` line in the message log in
  one colour per severity, repeated on the big-news banner, so it is not lost among combat
  lines. Messages that mention a key name the key you actually have bound (#57, #58).
- **Keys.** Shift+F3 toggle, Shift+F4 stop, Shift+F5 run once, Shift+F6 ask what it would do,
  Shift+F7 menu. The original's Alt+F1 / Shift+F1 stay with the original.
- **Talent picker fits the screen.** Long lists scroll instead of running off the top and
  bottom edges at 1366×768 (#9).
- **The bot stops when it makes no progress, not after a turn count** (#13). 0.0.12 stopped
  after 1000 actions whether or not they were doing anything; now an activation that makes no
  progress for 8 decisions in a row stops with the bot's state in the message ("please report
  this"), and a productive long run is never interrupted for its length.
- **First-run wording** (#54): the addon's description leads with what it does and the one
  thing to know (enable it before creating the character); the options are named in the words
  the stops use (*Maximum Enemy Power*, *Maximum Enemy Power Above Yours*, the ratios explained);
  the menu says how to start and what IGNORE / WARN / STOP mean when a stop condition is set.
- **Less of the game patched** (#14, #76). The addon now replaces one method of the player class,
  a one-line wrapper, and adds the *Power Level* tooltip line through the engine's own
  hook instead of patching every creature's tooltip. The line sits with the creature's stats
  (after M. save) rather than at the bottom of the tooltip.
- **The options say what they will take** (#74). Every numerical option used to open with
  *From 0 to 1000000*, whatever it meant. The two life fractions now offer *From 0 to 1* and
  the three rank ratios *From 0 to 10*, and the box holds you to it — typing `50` into *Low
  Health Ratio* meaning "50%" used to set a threshold of fifty times your maximum life, after
  which the bot stopped at the first enemy it saw. Fractions can still be typed with a decimal
  point. The power figures, the enemy count and the action delay keep the open range, having
  no natural ceiling, and a value you had already saved is left alone.
- **The power limits say they are a scale** (#82). The five that feed the threat figure —
  *Maximum Enemy Power*, *…Above Yours*, *Maximum Combined Enemy Power*, *Maximum Enemy Count*
  and *Ignore Damage Above Life Ratio* — now say so on the options tab. Each is the scale for
  one part of the figure every power stop ends with, where the limit you set counts as 1, so
  "threat 3" means three times past it. They read as five independent switches before, which
  is what they were until the scored evaluation replaced the flat list.
- **Cornered with nothing but a flee, the bot hands back** (#67). A rotation of *Flee from…*
  and nothing else, with no step left to take, used to walk into the thing it had been told to
  run from — the rotation's tail is "get closer", and with no talent above it that is a bump
  attack. It now stops with *cornered: no grid farther from …, and the rotation is flee only*.
  Put any talent under the flee and the old behaviour is back, on purpose: closing the distance
  is what brings that talent into range, and "fight when you cannot run" is then what you asked
  for.
- **"Flee from the strongest" now means the strongest as the bot counts it** (#80). It ranked
  by the raw power level while every stop reason, the threat score and the tooltip's "counts
  as" figure used the rank-weighted one. With a rare and a boss in view at once the two
  disagreed, and the bot could back away from the wrong one.
- **The "no Combat talent is ready" stop says when holding is the reason** (#75). With every
  Combat entry set to *hold while impaired* and the character stunned, the rotation is empty —
  but the stop said *none configured, or all on cooldown*, neither of which was true, and the
  only mention of holding was on the debug log. It now says *every one is held while impaired
  (N)*, or *N held while impaired, the rest on cooldown or unusable*. The "set talent usage in
  the menu" hint is now offered only when nothing is configured at all, rather than to a player
  whose talents are merely held.
- **A talent held while impaired is released on the impairment's last turn** (#68). *Hold while
  impaired* used to skip the entry for as long as the stun lasted, including the turn it was
  about to lapse on — which cost the rotation a turn and bought nothing. The bot now reads how
  long each impairment has left. It still errs toward holding: an impairment it cannot trace to
  a live effect, or one with several sources, is treated as lasting.
- **A third flee row: "Flee but keep sight"** (#69). For a character who fights at range. The
  plain flee takes the neighbouring grid the hostile has least sight of, which happily means
  stepping behind a tree — a wasted turn if the next row in the rotation is a bolt. This one
  considers only grids that still have line of sight to that hostile, and picks among them by
  the same rule. It is its own row, so it can sit above a plain flee: keep sight if you can,
  break it if you must.
- **The bot no longer walks into vault doors** (#64). A sealed vault door does not block
  movement as far as the game is concerned, so the bot's pathing ran straight through one: it
  walked into the door, the *"This door seems to have been sealed off"* prompt opened, and the
  bot handed back — and then did it again a few turns after you restarted it. An unattended
  ten-minute run measured 65 of its 66 stops as exactly that loop. The bot now treats any grid
  you would be *asked* about — sealed doors, locked doors, loose rocks — as somewhere it may
  not route through or flee into. You can still walk into one yourself, and it still hands back
  when the prompt opens, because the vault is your decision.
- **A new stop condition: *Turns: BLACKOUT*** (#77, default WARN). Paralysis, stoning and time
  stuns take turns away without the bot ever getting one — it cannot notice while it is
  happening, because the game never asks it what to do. On the first turn it gets back it now
  says *lost N turns while unable to act*, so a fight that has moved on while you looked away
  is explained rather than mysterious. It counts turns the character never got, at the
  character's own speed, so an ordinary rest is not a blackout and neither is being slowed. Set
  it to IGNORE if you would rather not hear about it. Your existing WARN/STOP/IGNORE choices are
  untouched: the other thirteen keep their order.
- **Being hurt counts for more than it did** (#79). Your own power level was scaled straight
  down by the life you had left, so half life read as exactly half strength. It is a curve now:
  half life counts for about a third, and a quarter life for about a sixth — a character at 51%
  life is worse off than half-strength, because it has fewer turns of margin, must spend some of
  them healing, and cannot take the risk that a crit ends the run. **At full life nothing
  changes**, so your *Maximum Enemy Power Above Yours* and *Maximum Combined Enemy Power* mean
  exactly what they did; the bot simply gets more careful sooner once you are wounded. The
  tooltip now spells the multiplier out ("at 65% life, x0.53").
- **The bot walks to a glowing chest instead of stopping across the room from it** (#78). It
  used to hand back the moment one came into view, leaving you to walk there yourself. It now
  walks over and hands back *next to* the chest, with the same message and the same
  *Terrain: Glowing Chest* setting deciding whether it happens at all — set it to IGNORE and
  the bot neither walks nor stops, exactly as before. It only walks with nothing hostile in
  sight and the room reading as safe, it re-checks that every step, and it gives up rather than
  crossing the whole level or routing through a sealed door.

### Fixed

Defects inherited from 0.0.12, all reported by its users:

- Talents that want a marked or confirmed target (Headshot and its kind) no longer stall the
  rotation; the bot falls through to the next priority (#5).
- Being pinned, dominated or otherwise unable to move no longer freezes the game while the bot
  tries to explore: it hands back with "cannot move". The *Asleep* stop now fires — in 0.0.12
  it never did (#7).
- The bot no longer drowns while resting underwater: when suffocating it stops resting and
  walks to the nearest reachable breathable tile. The 0.0.12 guard for this was unreachable
  code from the day it was written (#10).
- A stop condition added by an update can no longer crash a character created before it: the
  saved list is reconciled with the addon's on every read, keeping your WARN/STOP/IGNORE
  choices and dropping conditions that no longer exist (#52).
- The *Stunned*, *Confused*, *Dazed* and *Frozen* stops now fire whenever the effect is on you.
  0.0.12 tested each for a value of exactly 1, so a stun from two sources or a 30% confusion
  read as nothing; the bot now reads the effect as the game does and says how much ("stunned
  (x2)", "confused (30% chance to act randomly)"). And "cannot move" is no longer "cannot
  fight": pinned next to an enemy, the bot attacks; pinned with nothing in reach it hands back
  saying so, instead of trying a step the game refuses (#12).

And one nobody reported, found here:

- **Your settings are kept** (#90). Everything on the *[SkooBot: Reclauded]* options tab — the
  thresholds, the ratios, the stop popup, the log level — lasted exactly one session. The file
  on disk was correct and the tab showed the right value all session, so the loss was invisible
  until the next start, when every option quietly went back to its default. SkooBot 0.0.12 has
  the same defect, under its own name; if you ever set something there and felt it had not
  taken, it had not. Settings you had already chosen are recovered on first load rather than
  lost.

### Not in this version

- Walking to a glowing chest as a scored objective, and a non-linear life curve for your own power, are after 0.1 (#11, follow-ups).
