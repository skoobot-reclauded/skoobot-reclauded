# CLAUDE.md

Orientation for anyone — human or assistant — picking this repo up cold.

## What this is

`SkooBot: Reclauded`, an autoplay addon for Tales of Maj'Eyal 1.7.6. A successor to the
original SkooBot, not an update to it. `src/` is the shipped addon; `tools/` is development
tooling that is never packaged; `docs/` is design record.

The research archive that this project came out of lives beside it at `../Project Summary` —
post-mortem of the original, every user complaint with its source, the decision log, and the
task-ID mapping. It is read-only history.

## Read before acting

| If you are about to… | Read first |
|---|---|
| Touch GitHub, auth, issues, or publishing | **[docs/github-workflow.md](docs/github-workflow.md)** |
| Touch the test harness or `tools/` | [docs/design-harness.md](docs/design-harness.md) |
| Change stop conditions or the act loop | [docs/design-stop-conditions.md](docs/design-stop-conditions.md) |
| Copy anything from the original or mishander's fork | [NOTICE](NOTICE), [docs/salvage-mishander.md](docs/salvage-mishander.md) |

## Rules that are not negotiable

1. **Never touch `SkoobyDoo/tome4-SkooBot`**, its te4.org page, or its Steam listing. No
   pushes, no PRs, no forks, no transfers. It is live and has real users. See
   [docs/github-workflow.md](docs/github-workflow.md) §2.1.
2. **Never run `gh auth login`.** `gh` is logged out on purpose. Automated work authenticates
   as the machine account `skoobot-reclauded-bot` via a token read from the vault, never as
   the human owner. See §2.2.
3. **Never print a credential** into a log, a commit, a file, or the conversation. Verify by
   using the value, or by its length or fingerprint.
4. **`tools/` must never ship.** The devbridge executes arbitrary Lua from disk by design.
   Only `src/` is packed into a `.teaa`.
5. **GPL-3.0, four-deep attribution.** Casalini → Charidan → SkoobyDoo → mishander. Keep
   per-file GPL headers on adapted code; do not strip them.

## Conventions

- Task IDs (`T-nnn`) are permanent and are **not** GitHub issue numbers. Put them in issue
  titles and in commit messages (`Fix talent fallthrough (T-010)`), so `git log --grep=T-010`
  survives any tracker migration. Mapping is in `../Project Summary/TASKS.md`.
- Decisions (`D-n`) live in `TASKS.md`, not in issues. They are reasoning, not work items.
- The game's Lua is **LuaJIT 2.0.2, x86**. Local LuaJIT is 2.1 — same dialect, so a 2.1-only
  idiom passes `busted` and fails in-game. Parse-check with
  `luajit -bl <file> /dev/null`; lint with `luacheck --std luajit src/`.

## Verifying behaviour

There is a working harness that drives a real game unattended — launch, command, observe,
kill. Do not hand-test what it can test. Do not trust a failing run that came back `Tainted`;
that means a human touched the machine mid-run and the result is void.

```
powershell -File tools/smoke-test.ps1        # bridge round-trip
powershell -File tools/new-character.ps1     # create and save a character, no human input
```
