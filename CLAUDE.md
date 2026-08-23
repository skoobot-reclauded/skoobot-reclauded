# CLAUDE.md

Orientation for anyone — human or assistant — picking this repo up cold.

## What this is

`SkooBot: Reclauded`, an autoplay addon for Tales of Maj'Eyal 1.7.6. A successor to the
original SkooBot, not an update to it. `src/` is the shipped addon; `tools/` is development
tooling that is never packaged; `docs/` is design record.

The post-mortem of the original, every user complaint with its source, and the decision log are
held by the maintainer outside this repository (on the development machine, in the research
archive beside this checkout). They are read-only history and hold no tasks; **tasks live only
in this repo's GitHub Issues.**

## Read before acting

| If you are about to… | Read first |
|---|---|
| Touch GitHub, auth, issues, or publishing | **[docs/github-workflow.md](docs/github-workflow.md)** |
| Touch the test harness or `tools/` | [docs/design-harness.md](docs/design-harness.md) |
| Change stop conditions or the act loop | [docs/design-stop-conditions.md](docs/design-stop-conditions.md) |
| Copy anything from the original, mishander's fork, or a PR to the original | [NOTICE](NOTICE), [docs/salvage-mishander.md](docs/salvage-mishander.md), [docs/salvage-yura9111.md](docs/salvage-yura9111.md) |

## Rules that are not negotiable

1. **Never touch `SkoobyDoo/tome4-SkooBot`**, its te4.org page, or its Steam listing. No
   pushes, no PRs, no forks, no transfers. It is live and has real users. See
   [docs/github-workflow.md](docs/github-workflow.md) §2.1.
2. **Never run `gh auth login`.** `gh` is logged out on purpose. Automated work authenticates
   as the machine account `skoobot-reclauded-bot` via a token read from the vault, never as
   the human owner. See [docs/github-workflow.md](docs/github-workflow.md) §2.2.
3. **Never print a credential** into a log, a commit, a file, or the conversation. Verify by
   using the value, or by its length or fingerprint.
4. **`tools/` must never ship.** The devbridge executes arbitrary Lua from disk by design.
   Only `src/` is packed into a `.teaa`, by `tools/pack.ps1`, which refuses any entry under
   `tools/` or `spec/`.
5. **GPL-3.0, four-deep attribution.** Casalini → Charidan → SkoobyDoo → mishander. Keep
   per-file GPL headers on adapted code; do not strip them.

## Conventions

- **GitHub Issues are the single source of truth for tasks.** A task exists when it is an
  issue with a milestone; work that lives only in a document, a chat, or a local file is not
  tracked — file it, as the machine account. **An issue is identified by its number only.**
  Cite it in commit messages (`Fix talent fallthrough (#5)`); titles carry no prefix. The
  `T-nnn` IDs in older titles, commits and docs are retired but valid references (D-13,
  2026-08-22) — never allocate a new one, never edit the old ones away. Procedure:
  [docs/github-workflow.md](docs/github-workflow.md) §4.
- Decisions (`D-n`) are reasoning, not work items. They are held by the maintainer outside this
  repository — not in this repo, not in issues, for now — and are cited by ID; every
  citation here should carry its one-line substance.
- Push with `--follow-tags` and don't force-push `main` — ordinary hygiene, not a security
  control. **D-9: the owner has accepted the history-rewrite risk and closed the question.**
  Do not add branch protection or rulesets for it, and do not re-raise it as a finding.
- The game's Lua is **LuaJIT 2.0.2, x86**, and `busted` must run under LuaJIT too — it ran
  under PUC Lua 5.4 until T-045, which made the suite test a different language in both
  directions (`loadstring`/`setfenv`/`unpack` absent under test but correct in-game; `//` and
  bitwise operators compiling under test but fatal in-game). `spec/dialect_spec.lua` now fails
  the run if that regresses. The residual gap is 2.1-vs-2.0.2 — `table.new`, `table.clear` and
  `table.move` resolve under test and fail in-game. Lint cannot see it (luacheck's `luajit` std
  is one set for both patch levels) and neither can a runtime probe, so `dialect_spec` **scans
  the source** of everything the game loads — `src/` and the devbridge — and fails on the line
  that names one (#63). Only the harness, or CI under a real 2.0 build (#63, waiting on #30),
  proves the code actually runs there.
- Parse-check with `luajit -bl <file> /dev/null`; lint with `luacheck .` — the tracked
  `.luacheckrc` carries the std and every per-path environment, so `--std` on the command line
  is redundant at best. The trailing-slash form `luacheck src/` checks **no files** and exits 3.

## Working in parallel

Several sessions may work here at once. Three rules make that safe; none costs a solo task
more than three commands (#60).

- **`skoobot-reclauded/` is the integration checkout: always `main`, always clean.** Anything
  that touches `src/`, `tools/` or `spec/` is done in a worktree on an issue branch and
  reaches `main` by fast-forward only, after the issue's scenarios ran from that checkout:

  ```
  git -C ../skoobot-reclauded worktree add ../skoobot-reclauded-57 -b issue-57
  …work, commit, run the issue's scenarios from that checkout…
  git -C ../skoobot-reclauded merge --ff-only issue-57
  git -C ../skoobot-reclauded worktree remove ../skoobot-reclauded-57
  git -C ../skoobot-reclauded branch -d issue-57
  ```

  Worktrees inherit the bot identity, the blank credential helper and `tools/githooks` —
  nothing to configure. If `--ff-only` refuses, `main` moved: `git rebase main` in the
  worktree, re-run the scenarios if the rebase touched your files, then merge. Docs-only
  changes may go straight onto `main`, committed at once; if the tree is dirty when you
  arrive, someone else is there — take a worktree.
- **The game is single-occupancy and the harness enforces it.** `Start-Game` holds a lease
  while its host process is alive and refuses if another live host holds one; `Stop-Game`
  never kills another host's game. If it reports the harness in use, do other work and come
  back — never kill `t-engine` by hand. The junctions must point at the checkout under test:
  `Start-Game` refuses otherwise, and `tools/setup-dev.ps1` run from that checkout fixes it
  (it repoints all three; run it again from `main`'s checkout when the worktree goes).
- **A launch that fails on infrastructure is retried once**, and the retry is printed. A
  scenario that passed on attempt 2 passed; a game that died is reported, not relaunched.

## Verifying behaviour

There is a working harness that drives a real game unattended — launch, command, observe,
kill. Do not hand-test what it can test. Do not trust a failing run that came back `Tainted`;
that means a human touched the machine mid-run and the result is void.

Every `.ps1` here needs `-ExecutionPolicy Bypass`: the machine's policy is `Restricted` in
every scope, so `powershell -File …` alone fails with "running scripts is disabled on this
system" before the script starts. Do not change the machine policy to make a document true.

```
powershell -ExecutionPolicy Bypass -File tools/setup-dev.ps1       # junction src/ + devbridge in
powershell -ExecutionPolicy Bypass -File tools/smoke-test.ps1      # bridge round-trip
powershell -ExecutionPolicy Bypass -File tools/new-character.ps1   # create and save a character
powershell -ExecutionPolicy Bypass -File tools/pack.ps1            # build dist/*.teaa
powershell -ExecutionPolicy Bypass -File tools/clean-build.ps1     # release gate
```
