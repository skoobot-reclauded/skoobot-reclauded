# CLAUDE.md

Orientation for anyone — human or assistant — picking this repo up cold.

## What this is

`SkooBot: Reclauded`, an autoplay addon for Tales of Maj'Eyal 1.7.6. A successor to the
original SkooBot, not an update to it. `src/` is the shipped addon; `tools/` is development
tooling that is never packaged; `docs/` is design record.

The research archive that this project came out of lives beside it at `../Project Summary` —
post-mortem of the original, every user complaint with its source, and the decision log. It is
read-only history and holds no tasks; **tasks live only in this repo's GitHub Issues.**

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

- **GitHub Issues are the single source of truth for tasks.** A task exists when it is an
  issue with a milestone; work that lives only in a document, a chat, or a local file is not
  tracked — file it, as the machine account. Task IDs (`T-nnn`) are permanent and are **not**
  GitHub issue numbers. Put them in issue titles and in commit messages
  (`Fix talent fallthrough (T-010)`), so `git log --grep=T-010` survives any tracker
  migration. The mapping is the issue list itself (search `T-010 in:title`); allocate the next
  free number in the themed block by searching titles for the highest one in use. Blocks and
  procedure: [docs/github-workflow.md](docs/github-workflow.md) §4.
- Decisions (`D-n`) are reasoning, not work items. They are held by the maintainer in the local
  research archive — not in this repo, not in issues, for now — and are cited by ID; every
  citation here should carry its one-line substance.
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
