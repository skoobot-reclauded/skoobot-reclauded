# SkooBot: Reclauded

An autoplay addon for [Tales of Maj'Eyal](https://te4.org) 1.7.6. Hand your character to a
bot that rests, explores and fights — and hands control back when it judges the situation
needs a human.

The goal is removing the tedium of levelling a new character, roughly levels 1–15. It is not
trying to beat the game, and it should stop early and often rather than get you killed.

> **Runs entirely offline.** No language model, no network requests, no API key, no telemetry.
> *Reclauded* is a play on *rebooted* — this was built with the help of Claude, an AI
> assistant, but contains none of it. It's ordinary Lua running inside your game.

**Status: early.** Not yet feature-complete against the original SkooBot.

## Relationship to SkooBot

This is a **separate addon** and a successor, not an update.
[The original](https://github.com/SkoobyDoo/tome4-SkooBot) remains published and untouched;
installing this will not affect it. Different `short_name`, different listing.

Why a reboot rather than a patch: four of the six outstanding user complaints against the
original share a single root cause — the bot's stop/act logic is a flat pile of special cases
where it needed a scored evaluation of the situation. Fixing that properly means replacing the
decision core, so it gets a clean repo.

The full post-mortem, including every user complaint with its source, lives in the research
archive alongside this repo.

## Layout

| Path | What it is |
|---|---|
| `src/` | The addon itself. This tree is what gets packed into a `.teaa` |
| `src/init.lua` | Addon manifest |
| `spec/` | [busted](https://lunarmodules.github.io/busted/) tests for logic that can run outside the game |
| `tools/` | Development tooling — the test harness. **Never packaged into a release** |
| `docs/` | Design notes |
| `CLAUDE.md` | Orientation and the non-negotiable rules — read this first |

## Development

Requires LuaJIT, `luacheck` and `busted`. Note the game itself runs **LuaJIT 2.0.2, x86** --
same Lua 5.1 dialect as a local 2.1 build, but not the same version, so a 2.1-only idiom will
pass `busted` and fail in-game.

Parse-check without launching the game:

```bash
luajit -bl src/init.lua /dev/null
```

Lint:

```bash
luacheck --std luajit src/
```

Run tests:

```bash
busted spec/
```

## Project procedures

Hosting, the machine account, issue conventions, and the two rules that must not be broken —
never touch the original SkooBot repo, never authenticate as the human owner — are in
[docs/github-workflow.md](docs/github-workflow.md). Read it before doing anything on GitHub.

## Licence

GPL-3.0. See [LICENSE](LICENSE).

This is a derivative work with a four-deep attribution chain — Nicolas Casalini (ToME) →
Charidan (Player AI) → SkoobyDoo (SkooBot) → mishander (fork fixes). See [NOTICE](NOTICE).
Per-file GPL headers on code adapted from the game are retained deliberately and should not
be stripped.
