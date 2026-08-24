# SkooBot: Reclauded

An autoplay addon for [Tales of Maj'Eyal](https://te4.org) — hand your character to a bot that
rests, explores and fights, and hands control back when it judges the situation needs a human.

> ## ⚠ Beta. GitHub only — not on te4.org or the Steam Workshop.
>
> Every `0.x` release is a **beta prerelease**, published here and nowhere else. It is not in
> the game's Addons browser, and it will not be until **1.0.0** — the first version meant to
> be met by someone who did not come looking for it.
>
> **[Download from the releases page](https://github.com/skoobot-reclauded/skoobot-reclauded/releases)**,
> and see [Installing](#installing) — the `.teaa` ships inside a zip, and the file name matters.
>
> **No numbered release has been cut yet.** What is there today is **`latest-dev`**: a
> development snapshot of `main`, rebuilt whenever there is something worth testing and deleted
> without notice. Every build is checked to load and run in a clean game before it is posted,
> and none of them has been play tested. Numbered `0.x` betas will appear beside it, and those
> are the ones that keep their download link.
>
> If you want a finished, published addon today, you want
> **[the original SkooBot](https://github.com/SkoobyDoo/tome4-SkooBot)**, which remains
> published and is unaffected by anything here.

## Installing

1. **Download the `.zip`** from the [releases page](https://github.com/skoobot-reclauded/skoobot-reclauded/releases)
   and extract the `.teaa` inside it — `tome-skoobot_reclauded-<version>.teaa` from a numbered
   release, or `tome-skoobot_reclauded-<version>-g<commit>.teaa` from `latest-dev`.
2. **Do not rename the `.teaa`.** The game only considers archives whose name begins `tome-`,
   and it skips anything else **silently** — no error, the addon simply never appears. Some
   download paths strip the hyphens from a bare `.teaa`, which is why releases ship zipped.
3. **Drop the `.teaa` into `game/addons/`** inside your ToME installation, beside the addons
   that shipped with the game. On Steam that is the game's folder under
   `steamapps/common/`; on a standalone install it is wherever you unpacked ToME.
4. **Start the game and enable it** in Addons — but read the next point before you do.
5. **Enable it before you create the character you want to use it on.** A savefile records
   the addons it was made with, and the game silently ignores any addon a save does not list.
   It cannot attach to a character that already exists. This is the single most common reason
   an autoplay addon appears to do nothing.
6. Confirm it loaded: the Addons list shows *SkooBot: Reclauded* with its version, and
   `te4_log.txt` in the game directory carries a `Binding addon` line naming
   `skoobot_reclauded`.

Then press `Shift+F7` in game to open the menu. New characters get a one-time introduction;
[docs/first-run.md](docs/first-run.md) is the longer version.

**Beta means beta.** Report anything that surprises you — that is what this release is for,
and [Contributing and bug reports](#contributing-and-bug-reports) says how. Read
[Safety](#safety) first; it is short and it matters.

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
can open a popup. The power-level stops also say how far over your limits the room is -- a
**threat** score where 1 is the worst of your limits -- and a power-level condition you set
to `IGNORE` or restart past is played rather than charged: a step away from a single enemy
over your limit while it is not yet adjacent, a wait for a crowd to come into reach. Every
creature's tooltip shows the power-level estimate and what the bot counts it for; hold `Ctrl`
while hovering to see how it was made up.

The menu (`Shift+F7`) holds the two things you configure per character:

- **Talent rules** — the talent screen. Four sections — *Combat*, *Damage Prevention*,
  *Recovery*, *Sustain* — each an ordered list where position is priority; below them,
  everything the character can use, activatable items included. A talent may sit in several
  sections. Drag with the mouse, or use the keys the screen lists.
- **Stop conditions** — each one set to `STOP` (stops every time), `WARN` (stops once, then
  lets you restart through it until the condition clears) or `IGNORE`.

The thresholds behind the stop conditions are on the addon's own **Settings** screen, reached
from its menu (`Shift+F7`). They come in two kinds, and the screen says which each one is:

- **safety thresholds** -- the low-life ratio, the power limits, the enemy count -- belong to
  the **character you are playing**, because a level 3 Alchemist and a level 30 Bulwark do not
  want the same answer to "how dangerous is this". A character that has not changed one simply
  uses the default;
- **preferences** -- the action delay, whether a stop opens a popup, how much is logged --
  are yours and apply to every character.

One action on that screen copies a character's thresholds onto the defaults new characters
start with, so the global settings can be set from a character you have just tuned. The
**[SkooBot: Reclauded]** tab in Game Options is still there and points at it.

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
| `src/hooks/`, `src/overload/`, `src/superload/` | The game-facing half: keybinds and the options-tab pointer, the dialogs (menu, talents, stop conditions, settings), and the act loop wrapped onto the player |
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
[salvage from mishander's fork](docs/salvage-mishander.md),
[review of yura9111's PR](docs/salvage-yura9111.md).

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

2.1 and 2.0.2 are the same Lua 5.1 dialect, but 2.1 adds library functions (`table.new`,
`table.clear`, `table.move`) that resolve under test and fail in-game. Lint cannot see that —
luacheck's `luajit` std is one set for both patch levels — and neither can a runtime probe
from this side, since the call succeeds on the machine doing the checking. What
`spec/dialect_spec.lua` does instead is **scan the source** of everything the game loads
(`src/` and the devbridge) and fail on the line that names one (#63). That is not proof the
code runs under 2.0.2 — only running it is, which is the harness, and the CI job that runs the
suite under a real 2.0 build (#63, waiting on #30) — but it catches the call as it is written.

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
