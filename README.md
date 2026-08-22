# SkooBot: Reclauded

An autoplay addon for [Tales of Maj'Eyal](https://te4.org) — hand your character to a bot that
rests, explores and fights, and hands control back when it judges the situation needs a human.

> ## ⚠ Not released. Not installable. Nothing works yet.
>
> This repository is a **work in progress with no functioning addon in it.** `src/` contains a
> manifest and empty directories. There is no build, no release, no `.teaa`, and nothing to
> install. If you have arrived here expecting a working addon, you want
> **[the original SkooBot](https://github.com/SkoobyDoo/tome4-SkooBot)**, which is finished,
> published, and unaffected by anything here.
>
> If this repository became visible before it was meant to, that is what happened — it is
> early scaffolding, not an abandoned or broken release.

## What it is meant to be

The goal is removing the tedium of levelling a new character, roughly levels 1–15. It is
explicitly **not** trying to beat the game. The design target is a bot that stops early and
often rather than one that plays well — handing control back is the feature, not a failure.

> **Runs entirely offline.** No language model, no network requests, no API key, no telemetry.
> *Reclauded* is a play on *rebooted*: this is built with the help of Claude, an AI assistant,
> but contains none of it. It is ordinary Lua running inside your game.

## Relationship to the original SkooBot

This is a **separate addon and a successor, not an update.**
[The original](https://github.com/SkoobyDoo/tome4-SkooBot) remains published and untouched;
installing this one will never affect it. Different `short_name`, different listing, different
repository. Same author.

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
gets a clean repository rather than a rewrite in place. The original targets game version
1.6.7; this targets 1.7.6.

## Requirements

- **Tales of Maj'Eyal 1.7.6.** ToME addons are version-stamped and the game refuses
  mismatches, so this will not load on older or newer releases without a version bump.
- **Enable it in the Addons menu before you create the character you want to use it on.** A
  savefile records the addons it was made with, and the game silently ignores any addon a save
  does not list — so this will not attach to a character that already exists. There is no
  error message when that happens; the addon simply does nothing.
- No other addons required. Compatibility with other addons is untested.

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
| `src/` | The addon. This tree is what gets packed into a `.teaa` |
| `src/init.lua` | Addon manifest |
| `spec/` | [busted](https://lunarmodules.github.io/busted/) tests for logic that runs outside the game |
| `tools/` | Development tooling, including the test harness. **Never packaged into a release** |
| `docs/` | Design notes and decision records |
| `CLAUDE.md` | Orientation and the non-negotiable rules — read first |

Design documents worth reading before changing anything:
[stop conditions](docs/design-stop-conditions.md) (the decision core),
[harness](docs/design-harness.md) (how behaviour is verified against a live game),
[v1 latent bugs](docs/v1-latent-bugs.md),
[salvage from mishander's fork](docs/salvage-mishander.md).

## Development

Requires LuaJIT, `luacheck` and `busted`.

**`busted` must run under LuaJIT, not PUC Lua.** Install it into a 5.1 rocks tree
(`luarocks --lua-version 5.1 install busted`). This matters more than it sounds: on 5.4,
`loadstring`, `setfenv` and `unpack` are missing although they are correct in the game, while
5.4's `//` and bitwise operators compile although they crash in the game. A suite on the wrong
interpreter is testing a different language in both directions. `.busted` pins the interpreter
and `spec/dialect_spec.lua` fails the run if it is ever wrong again.

One gap remains that tests cannot close: the game ships **LuaJIT 2.0.2, x86** and a local build
is 2.1 — the same Lua 5.1 dialect, but 2.1 adds library functions (`table.new`, `table.clear`)
that resolve under test and fail in-game. Lint cannot see it either. Only the harness can.

```bash
luajit -bl src/init.lua /dev/null    # parse-check, no game launch
luacheck --std luajit .              # lint -- note the '.', see below
busted                               # unit tests; .busted supplies the paths
```

`luacheck --std luajit src/` **with a trailing slash checks nothing** and exits 3
(`couldn't read: Permission denied`). Use `.` or `src`.

Behaviour that only shows up inside a running game is tested by a harness that launches ToME,
drives it, and reads results back — no human at the keyboard. See
[docs/design-harness.md](docs/design-harness.md).

Project procedures — hosting, the machine account, issue conventions — are in
[docs/github-workflow.md](docs/github-workflow.md).

## Contributing and bug reports

Not yet, realistically: there is nothing to run. When there is, bug reports and pull requests
are welcome through this repository's issue tracker.

One piece of history that shapes how this will be handled: the original SkooBot did not die of
technical difficulty. It died with two working contributor fixes sitting unmerged while the
maintainer was unavailable. Building a contribution path that survives a maintainer being
absent for a year is tracked as a first-class task here, not an afterthought.

Task IDs (`T-nnn`) appear in issue titles and commit messages. They are permanent and are not
GitHub issue numbers.

## Licence

**GPL-3.0-or-later.** See [LICENSE](LICENSE) for the full text.

This is a derivative work. The attribution chain above is recorded in detail in
[NOTICE](NOTICE), as GPL-3.0 requires. Per-file GPL headers on code adapted from the game or
from earlier addons are retained deliberately and must not be stripped.

## Contact

`skoobot.reclauded@proton.me` — receive-only.

Not affiliated with or endorsed by Nicolas Casalini ("DarkGod"). *Tales of Maj'Eyal* is his
work; this is an unofficial third-party addon.
