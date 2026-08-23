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

### Not in this version

- Preset talent loadouts and auto-discovery are planned for 0.1.0 and not yet in (#18).
- The scored situation evaluation that replaces the stop-condition list, tempo-aware talent
  holding and fleeing are after 0.1 (#11, #15, #59).
