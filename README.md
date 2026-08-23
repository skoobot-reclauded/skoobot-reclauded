# SkooBot: Reclauded

An autoplay addon for [Tales of Maj'Eyal](https://te4.org) — hand your character to a bot that
rests, explores and fights, and hands control back when it judges the situation needs a human.

> ## ⚠ Unreleased. No public build.
>
> This repository is a **pre-release work in progress.** The addon works — `src/` is a port of
> the original SkooBot 0.0.12 to ToME 1.7.6 with the defects users reported against it fixed —
> but nothing has been published: no listing, no download, no `.teaa` to install. Testers can
> build one themselves with `tools/pack.ps1` (see [Development](#development)); the release
> gate is `tools/clean-build.ps1`. If you want a finished, published addon today, you want
> **[the original SkooBot](https://github.com/SkoobyDoo/tome4-SkooBot)**, which remains
> published and unaffected by anything here.
>
> If this repository became visible before it was meant to, that is all that happened.

## What it does

The goal is removing the tedium of levelling a new character, roughly levels 1–15. It is
explicitly **not** trying to beat the game. The design target is a bot that stops early and
often rather than one that plays well — handing control back is the feature, not a failure.

Once enabled (see [Requirements](#requirements)), five keys drive it. They are deliberately
not the original SkooBot's keys, so the two addons can be installed together without
answering the same key; all five can be rebound in Game Options → Key Bindings.

| Key | Action |
|---|---|
| `Shift+F3` | Toggle the bot on |
| `Shift+F4` | Stop it |
| `Shift+F5` | Run a single action |
| `Shift+F6` | Ask what it would do next, without doing it |
| `Shift+F7` | Open the menu |

Running, the bot rests to full, auto-explores, hunts anything it spots and fights it with the
talents you have allowed. It hands control back when it hits a **stop condition**: a debuff
that makes its judgement invalid (stunned, confused, dazed, frozen, asleep), losing a quarter
of its life in one turn or falling under half (both adjustable), being unable to move, a
glowing chest in view, standing on a level change, or enemies that score too strong by its
**power level** estimate. Every stop is one line in the message log and a banner, always
saying why; a stop for something you should look at also names the key that restarts it, and
can open a popup. Every creature's tooltip shows the power-level estimate; hold `Ctrl` while
hovering to see how it was made up.

The menu (`Shift+F7`) holds the two things you configure per character:

- **Set Skill Usage** — the talent screen. Four sections — *Combat*, *Damage Prevention*,
  *Recovery*, *Sustain* — each an ordered list where position is priority; below them,
  everything the character can use, activatable items included. A talent may sit in several
  sections. Drag with the mouse, or use the keys the screen lists.
- **Stop conditions** — each one set to `STOP` (stops every time), `WARN` (stops once, then
  lets you restart through it until the condition clears) or `IGNORE`.

The thresholds behind the stop conditions (low-life ratio, maximum enemy power, enemy count,
action delay, whether a stop also opens a popup) are on the **[SkooBot: Reclauded]** tab of
Game Options.

> **Runs entirely offline.** No language model, no network requests, no API key, no telemetry.
> *Reclauded* is a play on *rebooted*: this is built with the help of Claude, an AI assistant,
> but contains none of it. It is ordinary Lua running inside your game.

## Relationship to the original SkooBot

This is a **separate addon and a successor, not an update.**
[The original](https://github.com/SkoobyDoo/tome4-SkooBot) remains published and untouched;
installing this one will never affect it. Different `short_name`, different keys, different
settings, different listing, different repository. Same author.

The lineage is four deep, and every layer is GPL-3.0:

```
Tales of Maj'Eyal        Nicolas "DarkGod" Casalini      the game, and the root of the licence
  └─ Player AI           Charidan                        first autoplay addon; ancestor of the line
      └─ SkooBot         SkoobyDoo, 2018–2020            threat scoring + talent-priority UI
          └─ fork        mishander, to 2024              unmerged fixes, carried forward here
              └─ SkooBot: Reclauded
```

Why a rebuild rather than a patch: of the outstanding user complaints against the original,
four share one root cause — the stop/act logic is a flat list of special cases where it needed
a scored evaluation of the situation. Fixing that means replacing the decision core, so it
gets a clean repository rather than a rewrite in place. The first step was the opposite of a
rewrite: a faithful port of the original onto 1.7.6, measured against it for parity, so that
every change since can be shown to be one. The original targets game version 1.6.7; this
targets 1.7.6.

Where it stands: the port is complete, and the six defects inherited from the original that
users reported — drowning while resting, freezing when pinned or asleep, stopping on a
single poison tick, walking past glowing chests, a talent list that fell off a short screen,
and marked-target talents stalling the rotation — are fixed and verified against a live game.
The talent screen has been rebuilt, and every stop now says why. The scored decision core is
design work, not code, yet.

## Requirements

- **Tales of Maj'Eyal 1.7.6**, which is what it is developed and tested on. The addon declares
  `1.7.6`, and the game's own rule for that declaration is looser than "exact match": it
  loads on any 1.7.x and on later 1.x minor releases, and is refused only on a lower minor
  (1.6.x and earlier) or a different major. So a future 1.7.7 or 1.8 will load it unchanged;
  the declared version is bumped only when a change in ToME is actually verified or
  required, not on every release.
- **Enable it in the Addons menu before you create the character you want to use it on.** A
  savefile records the addons it was made with, and the game silently ignores any addon a save
  does not list — so this will not attach to a character that already exists. There is no
  error message when that happens; the addon simply does nothing.
- No other addons required. Compatibility with other addons is untested, with one exception
  by design: it can be installed alongside the original SkooBot without either interfering
  with the other.

## Safety

Read this before ever running an autoplay addon, including this one:

- **It can get your character killed.** It makes combat and movement decisions on your behalf,
  and it will sometimes make them badly.
- **Do not use it on a character you would be upset to lose.** Roguelike mode gives you exactly
  one life; Adventure gives only a handful of extra ones. Exploration mode is the forgiving
  place to try an autoplay addon.
- The intended failure mode is stopping too often and too early. If it is ever doing the
  opposite, that is a bug worth reporting.
- The software comes with **absolutely no warranty**, as set out in sections 15 and 16 of the
  GPL. See [LICENSE](LICENSE).

## Layout

| Path | What it is |
|---|---|
| `src/` | The addon. This tree, and only this tree, is what gets packed into a `.teaa` |
| `src/init.lua` | Addon manifest |
| `src/data/` | Pure modules with no game dependency — power scoring, talent rules, stop notices, key names, settings defaults |
| `src/hooks/`, `src/overload/`, `src/superload/` | The game-facing half: keybinds and the options tab, the dialogs, and the act loop wrapped onto the player |
| `spec/` | [busted](https://lunarmodules.github.io/busted/) tests for the logic that runs outside the game |
| `tools/` | Development tooling: the test harness, its scenarios, the packer and the release gate. **Never packaged into a release** |
| `docs/` | Design notes and records |
| `CLAUDE.md` | Orientation and the non-negotiable rules — read first |
| `NOTICE` | The attribution chain, in the detail GPL-3.0 requires |

Design documents worth reading before changing anything:
[stop conditions](docs/design-stop-conditions.md) (the decision core, as designed),
[harness](docs/design-harness.md) (how behaviour is verified against a live game),
[the 1.7.6 API surface](docs/api-surface-1.7.6.md),
[v1 latent bugs](docs/v1-latent-bugs.md),
[salvage from mishander's fork](docs/salvage-mishander.md).

## Development

Requires LuaJIT, `luacheck` and `busted`. Versions in use:

- **LuaJIT 2.1.x** locally; the game ships **LuaJIT 2.0.2, x86**.
- **luacheck 1.2.0.**
- **busted 2.3.0**, installed into a Lua 5.1 rocks tree:
  `luarocks --lua-version 5.1 install busted`.

**`busted` must run under LuaJIT, not PUC Lua** — hence the 5.1 rocks tree. This matters more
than it sounds: on 5.4, `loadstring`, `setfenv` and `unpack` are missing although they are
correct in the game, while 5.4's `//` and bitwise operators compile although they crash in the
game. A suite on the wrong interpreter is testing a different language in both directions.
`.busted` pins the interpreter and `spec/dialect_spec.lua` fails the run if it is ever wrong
again.

One gap remains that tests cannot close: 2.1 and 2.0.2 are the same Lua 5.1 dialect, but 2.1
adds library functions (`table.new`, `table.clear`) that resolve under test and fail in-game.
Lint cannot see it either. Only the harness can.

```bash
luajit -bl src/init.lua /dev/null    # parse-check, no game launch
luacheck .                           # lint -- note the '.', see below
busted                               # unit tests; .busted supplies the paths
```

`luacheck src/` **with a trailing slash checks nothing** and exits 3
(`couldn't read: Permission denied`). Use `.` or `src`. `.luacheckrc` carries the whole
configuration, so no `--std` or `--ignore` on the command line.

A pre-commit hook (`tools/githooks`, enabled per clone with
`git config core.hooksPath tools/githooks`) runs all three against the index and refuses the
commit if any fails.

Behaviour that only shows up inside a running game is tested by a harness that launches ToME,
drives it, and reads results back — no human at the keyboard. See
[docs/design-harness.md](docs/design-harness.md). The scripts under `tools/` are run as
`powershell -ExecutionPolicy Bypass -File tools/<script>.ps1`; `harness.ps1` is the library
they share:

| Script | What it does |
|---|---|
| `setup-dev.ps1` | Junction `src/` and the devbridge into the game so it loads the working tree |
| `smoke-test.ps1` | Prove the bridge round-trips |
| `new-character.ps1` | Create and save a character for the scenarios to use |
| `scenario-*.ps1` | Drive the bot through one situation each and check what it did |
| `pack.ps1` | Build `dist/tome-skoobot_reclauded-<version>.teaa` from `src/` and check the archive |
| `clean-build.ps1` | The release gate: pack, remove every junction, install the `.teaa`, and prove the game loads *it* |

Project procedures — hosting, the machine account, issue conventions — are in
[docs/github-workflow.md](docs/github-workflow.md).

## Contributing and bug reports

Bug reports and pull requests are welcome through this repository's
[issue tracker](https://github.com/skoobot-reclauded/skoobot-reclauded/issues);
[CONTRIBUTING.md](CONTRIBUTING.md) has the conventions. Issues are identified by their
number; older titles and commits also carry `T-nnn` IDs, which are retired but remain valid
references.

One piece of history that shapes how this is handled: the original SkooBot did not die of
technical difficulty. It died with two working contributor fixes sitting unmerged while the
maintainer was unavailable. Building a contribution path that survives a maintainer being
absent for a year is tracked as a first-class task here, not an afterthought.

## Licence

**GPL-3.0-or-later.** See [LICENSE](LICENSE) for the full text.

This is a derivative work. The attribution chain above is recorded in detail in
[NOTICE](NOTICE), as GPL-3.0 requires. Per-file GPL headers on code adapted from the game or
from earlier addons are retained deliberately and must not be stripped.

## Contact

`skoobot.reclauded@proton.me` — receive-only.

Not affiliated with or endorsed by Nicolas Casalini ("DarkGod"). *Tales of Maj'Eyal* is his
work; this is an unofficial third-party addon.
