# Contributing

Thank you for considering it. This page says how to report a bug, what a pull request needs,
and — honestly — what happens to your contribution if the maintainer goes quiet.

## Where things go

**An issue is work. A discussion is everything on the way to work.** That is the whole rule,
and it exists so the tracker stays a list of things somebody intends to do rather than a
mixture of questions, wishes and reports.

| You have | Where |
|---|---|
| A bug — it did something wrong, or failed to stop when it should have | **Issue**, bug-report template |
| A question — how do I, is it meant to, which setting | **Discussions → Q&A** |
| A run to describe — what happened over an hour of play | **Discussions → Playtest reports** |
| A wish — something you would like it to do | **Discussions → Ideas** |
| A pull request | **Issue first**, then the PR closing it |

Nothing is lost by guessing wrong; things get moved. **Playtest reports are the one worth
singling out** — during the `0.x` betas they are the most useful thing anyone can send, more
than a bug report, because what decides when 1.0 is ready is whether the thing is pleasant to
play and no test can answer that.

New releases are announced in **Discussions → Announcements**. Watch the repository with
*Custom → Releases* (or *Discussions*) if you want to hear about builds; there is no listing
page and no mailing list.

## Bug reports

**Issues are the tracker.** File bugs as GitHub issues in this repository; there is
no other list anywhere, on purpose. Use the bug-report template — it asks for the few facts
(game version, addon version, other addons, class, what the bot was doing, the stop message)
that decide whether a report can be reproduced at all.

Read the Safety section of the [README](README.md) first. The bot stopping early and often is
the design, not a bug. The bot getting a character hurt when a human would have stopped is
the bug this project most wants to hear about.

## Pull requests

Pull requests are welcome once the repository is public — if you can read this on GitHub, it
is. What a PR needs, and the template will ask for:

- **An issue it closes.** Open one first if none exists; one sentence is enough. The issue is
  where the "why" lives and where the work is tracked.
- **How it was verified.** Logic that runs outside the game (everything under `src/data/`) gets
  a [busted](https://lunarmodules.github.io/busted/) spec in `spec/`. Behaviour that only shows
  up inside a running game gets a `tools/scenario-*.ps1` run against the live game — see
  [docs/design-harness.md](docs/design-harness.md). If you cannot run the harness, say so and
  describe the manual test: which class, which zone, what you watched for. "Works for me" is a
  data point, not a verification.
- **The checks pass.** `luacheck .` with zero warnings and `busted` green, under LuaJIT — the
  tracked pre-commit hook runs both on every commit (`git config core.hooksPath
  tools/githooks`), and the CI workflow runs them again on every push. Setup is in the
  README's Development section.
- **GPL-3.0 headers intact.** Much of `src/` is adapted from the game and from the original
  SkooBot, and every adapted file carries its original header. Do not strip, move or
  re-attribute one. If *you* adapt someone else's code, add them to [NOTICE](NOTICE) — the
  attribution chain there is how the project pays its own debts, and yours join it.
- **Commit messages that say why.** Imperative subject with the issue number in parentheses
  — `Stop for glowing chests instead of walking past them (#8)` — and a body that explains
  the reasoning, not the diff.
- **Comments that a maintainer would be wrong without.** The reasoning behind a change belongs
  in the issue and the commit message; the code needs the rule and the trap it avoids. One
  sentence and a pointer — `-- Poll rather than hook: the engine clears this first (see
  #1337)` — instead of a paragraph re-arguing a decision that is already written down
  somewhere. Always worth the space: why an approach that looks right does *not* work, an
  engine citation with its file and line, and the reason not to retry the obvious fix.
  Long-form findings go in `docs/`, not in `src/`.

Nothing under `tools/` or `spec/` may be referenced from `src/`: `tools/` executes arbitrary
Lua from disk by design and is never packaged, and `tools/pack.ps1` refuses an archive that
contains either.

## If the maintainer is absent

The original SkooBot did not die of technical difficulty. It died with two working contributor
fixes sitting unmerged while the maintainer was unavailable, and was carried on in a fork that
most users never found. This project was started knowing that, so here is where things stand —
the current state, not a promise.

- **What exists today:** the organisation is owned by one person, and the procedures for a
  second administrator and for the project's machine account to keep the tracker moving are
  written down in [docs/github-workflow.md](docs/github-workflow.md) §9, including the two
  facts that are still blank.
- **The intent:** a second human admin who can merge, and a machine account that can triage
  issues and label what is ready, so that a good PR does not sit for a year because one
  calendar went dark. Until the second admin is named, that intent is not yet a mechanism.
- **Anything beyond that is tracked, not assumed:** #17 (the contribution path) and #41 (the
  review rule and what happens in the maintainer's absence) are the issues; read them for the
  current state rather than this page, which will lag.
- **The licence needs nobody's permission.** This is GPL-3.0-or-later. If the repository is
  public and unanswered, fork it, keep the headers and the `NOTICE` chain, and carry on — that
  is exactly how this project relates to its own predecessor, and it is the one mechanism that
  cannot fail for want of a maintainer.

## Contact

`skoobot.reclauded@proton.me` — receive-only. For anything that belongs in the tracker, an
issue is better: it is visible to whoever picks the project up next.
