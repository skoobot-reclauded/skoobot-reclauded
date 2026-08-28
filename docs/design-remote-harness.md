# Design: the slot harness — parallel sweeps across machines

**Status:** implemented · **Issues:** #182, #189, #194, #196, #197, #198 · **Date:** 2026-08-28
**Operating it:** [runbook-sweeps.md](runbook-sweeps.md) · **The serial harness underneath:** [design-harness.md](design-harness.md)

A full 29-class sweep took ~2h15 on one machine, and that cost shaped development: work
stacked up while a sweep ran, so the next sweep measured ten changes at once and attributed
none of them. The goal of everything here is **latency, not throughput** — the owner's
formulation: *"10 instance sweep means the delay is 10 minutes… I can go make a sandwich and
have results."*

Measured walls, same roster, same per-class budget:

| Configuration | Wall |
|---|---|
| Serial, one machine | ~2h15 |
| Two machines, serial halves (#182) | 72 min |
| One machine, 8 slots (#194) | **19.1 min** |
| 8 remote + 4 local slots | ~16 min |

---

## 1. Topology

Two Hyper-V guests on one host, 8 vCPU each, GPU-PV partitions of the same card.

- **TestVM07** — the development machine: sessions, checkouts, the standard game pipeline.
  May additionally run up to 4 sweep slots (procedure cap; the 5th instance is reserved for
  the dev pipeline).
- **TestVM08** (192.168.50.88) — a dumb runner: Windows, sshd, git, the game, a repo clone.
  **No credentials, no vault, no GitHub token** — driven entirely from TestVM07, and its git
  can only read. 8 slots (procedure cap).

The caps are procedure, not code, by owner decision (2026-08-28): the tooling stays honest
about what was measured rather than encoding a policy that hardware changes would silently
invalidate. The measured basis: 8 slots is near-linear on 8 vCPU (aggregate 767 turns/s
against 90 solo, CPU 61%) with disk active time at 93% — the ceiling is I/O from the
engine's own logging, not cores — and with both guests hot the *host* saturates (observed at
95–98%), which starves every VM at once. Past that point more slots make every machine
slower, including the one the owner is typing in.

## 2. Driving a machine you can only ssh into

Windows OpenSSH puts every session in **session 0**, isolated from all desktops since
Vista. SDL finds no display, the game exits with `No displays available`, and the harness
reports the far less helpful `NO BRIDGE after 60s` over an empty log. This has nothing to do
with who is logged on: session 0 can never own a window, so **ssh can never start the game**
(#182).

The bridge is a scheduled task registered with `/it` ("only when the user is logged on"),
which Windows starts with an interactive token in the console session. ssh drops a command
file (`skoobot-agent\cmd.ps1`), pokes the task with `schtasks /run`, and polls for a marker
file; the transcript accumulates in `run.log`. Consequence: **the runner stays logged on at
the console** — logged off, there is no session to launch into.

Two rules follow from the runner having no credentials:

- It only ever runs a **pushed commit**: every command file starts with
  `git reset --hard origin/main`. What a sweep measured has to be nameable, and a pile of
  rsync'd edits is not (#175). Uncommitted work is not remotely testable, by design.
- Remote commands travel as files or `-EncodedCommand`, never inline: quoting through
  ssh → cmd.exe → powershell mangles quotes and `$`, and results come home **zipped**,
  because the scp server side is cmd.exe, which does not expand a glob in a remote path and
  reports success while copying nothing.

## 3. Slots: several games on one machine

A **slot** is a game directory plus an engine home. Both are needed:

- `te4_log.txt` — which the harness reads its *results* out of — is written to the game
  **working directory**, and the engine also bootstraps its engine code from there
  (`NO SELFEXE: bootstrapping from CWD`). One knob controls both, so the log cannot be
  relocated alone; pointing CWD elsewhere hangs the engine at `Running lua loader code…`.
- Sharing one log is impossible regardless: the engine opens it `'w'`, so each launch
  truncates whatever its siblings had written.
- The engine home (`--home`, to which the engine appends `T-Engine\4.0`) isolates saves,
  settings, profiles, and the bridge command channel per slot.

A slot is nearly free: `bootstrap`, `lib`, `lib64`, `locales` and everything under `game\`
except `addons` are junctions to the install; loose files hard-link; eight slots cost
~565 MB of real bytes. Each slot home is seeded with:

- `settings`, `profiles`, `boot` copied from the machine's real home;
- `profiles/online/generic/firstrun.profile` (`firstrun = 1`) — the **only** suppressor of
  the "Welcome to Tales of Maj'Eyal" first-run dialog (boot `mod/class/Game.lua:596`,
  engine `PlayerProfile.lua:427`; it is the online profile dir even for offline play). Found
  the hard way: TestVM08 never had one, so every launch there opened on the popup (#196);
- `disable_all_connectivity.cfg` and `firstrun_gdpr.cfg` — without them `engine/init.lua:99`
  forces connectivity ON and the menu fetches news and a te4.org WebView.

**The addon junctions inside a slot are the slot's own, pinned** to the checkout the tools
live in — never resolved through the install's junctions, which `setup-dev` repoints (#198).
Without the pin, a dev session switching worktrees mid-sweep silently switches what every
slot measures, and `Assert-JunctionsOwned` starts refusing launches minutes in. Pinning to
"the checkout the tools live in" is also the isolation procedure: **run the scheduler from a
detached worktree frozen at the commit under test**, and the pins, the workers, and the
stamp all come from the frozen tree while the dev session does as it likes. The hazard is
not theoretical — the first pinned-slot test stamped another session's commit that had
landed in the shared checkout minutes earlier, unnoticed.

The harness lease became slot-local for the same reason: it guards one engine home, so it
lives in the home it guards (`<home>\skoobot-bridge\harness.lock`). Hardcoded to the user
profile it was machine-wide, four games fought over one lock file, and the losers died
before writing a log (#189). Slot workers therefore never touch the machine lease — the
standard pipeline's single-occupancy rule is unaffected by any number of slots.

## 4. The scheduler

`tools/sweep-parallel.ps1` is a work queue over N slots, not a fixed split: a slot takes the
next class the moment it is free, so one slow class cannot hold the rest. Any class set
runs — the roster, a handful, or `-Repeat N` of one class for a distribution instead of an
anecdote (each rep in its own `repN` directory; reps are separate samples, never averaged,
because the spread is the point).

**A worker runs `sweep-classes.ps1 -Only <one class>` inside its slot** rather than
reimplementing birth, placement or scoring — so a parallel row means exactly what a serial
row means, and the merge is `sweep-classes -SummarizeOnly` over the union. `-KeepSkips`
keeps the sweep's skip policy when `-Only` is merely the dispatch mechanism; without it the
by-name override ("run one anyway") applies and Adventurer burns ten minutes measuring the
build (#194). Skip rows are written to disk so a merge says SKIPPED, not MISSING.

Two timeouts, because a series must never be hostage to one run:

- **Birth: 300s** (down from 900 — the old figure predates anyone watching a birth fail;
  Mindslayer spent every second of it, #184).
- **A whole class: birth + run + 180s slack.** A run that loops without advancing game time
  hits no other limit — soak's budget is measured against progress it never makes. On
  firing, the slot's game is killed by pid from that slot's own lease, the class is recorded
  `TIMEOUT` with its transcript kept, and the queue continues.

Known limit: the watchdog stops the job but not the worker's child powershell tree; the
chain self-terminates once its game dies, and the ledger reap at the slot's next completion
bounds the residue (#196, open note). Cold start is the other soft spot: eight simultaneous
first launches can cost a class to the 60s menu-bridge timeout (#197).

## 5. Leaks, and the launch ledger

Slot mode surfaced a class of bug serial mode had silently janitored **for the harness's
entire life**: serial `Stop-Game` kills every `t-engine` *by name*, so any game a failure
path forgot to stop was cleaned up by the next launch, invisibly. Slot mode cannot kill by
name — that would kill sibling slots — so every forgotten game leaked for real. The first
full-roster run accumulated 22 processes on an 8-slot machine and pushed the host to 95–98%
CPU: an orphan parks on the boot menu, which renders a full animated background, making a
leaked game close to the most expensive way to do nothing (#196).

The primary source was found only by adversarial review, and it is a language trap:
`… | Select-String '^ZONE ' | … | Select-Object -First 1` **kills the native child the
instant the match passes**, before the child's `finally { Stop-Game }` runs — so every
*successful* zone read leaked the game it had loaded (measured: ~200ms pipeline death vs
~500ms cleanup; 7 of 8 first-wave races lost). The fix is to run the child to completion and
parse the captured output. Secondary sources: exits that reported a launch failure without
stopping the not-ready game, and a `finally` under `$ErrorActionPreference='Stop'` whose
evidence-gathering could abort before reaching `Stop-Game` (evidence is best-effort; the
kill is not).

Because leak sources recur, the backstop is structural: **every launch appends
`pid,start-time` to a per-home `launched.log`**, and the scheduler reaps at class end by
*identity* — pid AND start time, so a recycled pid is not a match. The lease cannot serve
this purpose: it records only the latest launch, so each new launch orphans its
predecessor's record. The reap line prints unconditionally (`ledger: N launch(es), M
reaped`) because the first reaper shipped inert — it grepped the job transcript for lines
that never reach it — and its happy-path test read "no REAPED lines" as *no false positives*
when it was actually *blindness*. Zero launches recorded now means the ledger broke, loudly.

The through-line of the whole incident, and the design rule it left behind: **five separate
defects destroyed or hid their own evidence** (birth timeouts kept 206 bytes, #183; crashes
kept no log, #185; a fetch overwrote a fresh result, #188; the scheduler cleared wave-1
transcripts; the inert reaper). Every fix was the same shape — make something print or
persist unconditionally, because silence reads as success.

## 6. Measurement integrity, and combining sweep data

The rules that keep a merged table honest, each learned from a specific lie:

- **The build stamp is keyed on the loaded trees and the run protocol, not the commit**
  (#175, #214): a commit touching docs changes nothing the game executes, so two machines at
  different commits are one measurement **when the trees and `proto` both match**; the merged
  header prints both lines. `proto` exists because "tools" is not all passive — `soak.ps1`
  injects the rungs, auto-spends, places the character and applies the stop conditions, and
  `sweep-classes.ps1` sets the run parameters and computes the verdict #210's rule freezes
  into the row. Four sweeps with identical trees ran three different protocols before this was
  noticed. The boundary for adding a file to `proto`: stamp what changes the **content** of a
  comparable row, leave out what changes whether a row **exists** — the latter surfaces as
  MISSING / TIMEOUT / UNBIRTHABLE / NO RESULT, which #187 already names beside the headline.
  A merge whose halves disagree on `proto` says so and still renders: the rows are
  individually true, and refusing would throw away good rows to make a point (#212).
- **The stamp is taken before the first class runs, from a slot's game dir** — taken at
  summary time it named a commit created an hour into the run (#186), and taken from the
  install it would name whatever checkout a dev session had mounted (#198).
- **Every contributing machine leaves a line in `stamps.txt`**; the controller's own
  junctions describe the controller and nothing else (#182).
- **Merging is selective, never a blanket expand**: class files copy only when the name is
  free (a collision means both machines ran the class — investigate, never pick a winner),
  the remote `stamps.txt` is *appended*, the remote `summary.md` is discarded and re-derived.
  A blanket expand once replaced a fresh 14,794-turn result with a stale smoke test, both
  rows labelled CLEARED, detected only because an unrelated count disagreed (#188).
- **What fell out of the denominator is named next to the percentage it invalidates**:
  MISSING rows for a half that never arrived, and attempted-but-not-comparable classes
  (`UNBIRTHABLE`, `TIMEOUT`, crashes) beside the headline (#187). A sweep that lost two
  classes once reported `27 of 27 (100%)`; the exclusions were individually correct and
  collectively a lie.
- **Transcripts always survive**: `<class>.job.log` per class, `<class>.birth.log` on birth
  failure, `<class>.crash-te4_log.txt` on a crash — because the engine truncates its log on
  the next launch, and three separate incidents were undiagnosable for lack of exactly these
  files (#183, #185, #196).

## 7. Decisions ledger

| Decision | Rejected alternative, and why |
|---|---|
| Slots with own game dirs | Shared `te4_log.txt` — impossible, the engine opens it `'w'`; relocating it — impossible, log location and engine bootstrap share the CWD knob |
| Split the roster across machines | Whole sweeps per machine — doubles throughput, halves nothing; the wait was the problem |
| Workers wrap the serial sweep | A parallel-native runner — its rows would need their own trust chain; a wrapped serial row is already trusted |
| Reap by launch ledger, at class end | Reap by lease — records only the latest launch; reap by transcript grep — the lines never reach the transcript; kill by name — kills siblings |
| Caps as procedure | Caps in code — encodes today's hardware into the tool and invalidates silently when it changes (owner, 2026-08-28) |
| Frozen worktree + pinned junctions for local sweeps | Sweeping from the shared checkout — a dev session's ff-merge mutates `src/` under running measurements; pinning alone — the pinned directory's *contents* still move |
| Runner resets to `origin/main` | Syncing the working tree — unnameable measurements; also the runner holds no credentials, so it could not push results of its own state anywhere |
| Two timeouts per class | One overall budget — a game-time loop consumes any budget invisibly; soak's own limit is measured against progress a stuck run never makes |
