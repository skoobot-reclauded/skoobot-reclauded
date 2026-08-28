# Runbook: sweeps and deep dives on the slot harness

**Status:** current · **Date:** 2026-08-28 · **Architecture and why:**
[design-remote-harness.md](design-remote-harness.md)

How to start parallel class sweeps and single-class deep dives across the two machines.
Everything here is copy-paste; the reasons live in the design doc.

## The two machines, and the caps

| Machine | Role | Slot cap |
|---|---|---|
| TestVM07 (this one) | Development + up to **4** sweep slots | **4** — the machine runs 5 game instances at most, and the 5th is **reserved for the standard pipeline** (another session's dev work) |
| TestVM08 (192.168.50.88) | Dedicated runner | **8** |

**The caps are procedure, not code** (owner, 2026-08-28). Nothing stops `-Slots 12`; do not
run it. Measured basis: 8 slots on an 8-vCPU guest is near-linear (767 turns/s aggregate
against 90 solo) with CPU at 61% — but disk active time at 93%, and with both machines hot
the *host* saturates, which starves every VM including the one you are typing in.

A sweep on this machine must leave the standard pipeline alone: run it **from a frozen
worktree** (below), never from `skoobot-reclauded/` itself. Slots take no machine lease and
never touch the install's junctions, so the dev session keeps working; the freeze is what
protects the *sweep* from the dev session's junction switches and ff-merges (#198).

## Preflight: is the runner up?

Ping is useless — both VMs ship with every inbound ICMP rule disabled. Check TCP and the
agent in one probe:

**Run it with `-EncodedCommand`.** The inline form this runbook used until 2026-08-28 was
tested only in bash; in PowerShell — which every other recipe on this page uses — the `|`
ends the remote command early and the rest goes to the runner's own cmd.exe, so the check
returns **nothing at all** (`design-remote-harness.md` §2).

```powershell
$q = @'
$s = schtasks /query /tn skoobot-agent /fo list
$s | Where-Object { $_ -match 'Status' }
'games: ' + (Get-Process t-engine -EA SilentlyContinue).Count
'@
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($q))
ssh -i ~/.ssh/skoobot_runner -o BatchMode=yes -o ConnectTimeout=10 localuser@192.168.50.88 "powershell -NoProfile -EncodedCommand $enc"
```

**Proceed only if you can see BOTH `Status: Ready` and `games: 0`.** Anything else — `Running`,
a non-zero count, an error, an empty answer, output you did not expect — means **do not poke
it**. Ask whoever is running, or work locally.

That is deliberately a positive requirement rather than the prohibition it used to be
("`Status: Running` … do not poke it"). A rule phrased as the prohibition fails **open**: a
probe that returns nothing contains no `Running`, so a literal reading proceeds and pokes a
busy machine — which is this issue's own incident, reached through a broken check instead of a
skipped one. Phrased as a requirement, every failure mode including ones nobody anticipated
lands on "do not poke".

Two reading rules from the same incident, for when the check was skipped:

- **A fetch an order of magnitude smaller than usual is the tell.** Every sweep in the series
  produced 243–274 files; the foreign result was 11. Nothing else in the output looked wrong —
  the build stamp was correct and the table read `1 of 1 cleared their first floor (100%)`.
- **`sweep-stale-*` directories on the runner are evidence, not litter.** They are what #188's
  move-aside preserved when a second controller took over, and until the results directory is
  stamped with an owner they are the only trace of whose run was displaced.

Do not delete a `sweep-stale-*` directory you cannot account for.

## Recipe 1 — full roster, remote only (fastest simple case, ~20 min)

Everything the runner executes goes through the agent: drop a command file, poke the task,
poll for the marker. From this repo:

```powershell
$cmd = @'
$ErrorActionPreference = 'Continue'
$repo = 'C:\Users\localuser\Documents\skoobot-reclauded'
& git -C $repo fetch --quiet origin; & git -C $repo reset --hard --quiet origin/main
"repo at $(& git -C $repo rev-parse --short HEAD)"
Get-Process t-engine -EA SilentlyContinue | Stop-Process -Force
Remove-Item 'C:\Users\localuser\slots', "$repo\build\results\sweep" -Recurse -Force -EA SilentlyContinue
Start-Sleep -Seconds 4
& powershell -ExecutionPolicy Bypass -File "$repo\tools\sweep-parallel.ps1" -Slots 8 -Minutes 4 -Dossier 2>&1
"end; t-engine left: $((Get-Process t-engine -EA SilentlyContinue).Count)"
Get-Process t-engine -EA SilentlyContinue | Stop-Process -Force
'@
$f = Join-Path $env:TEMP 'cmd.ps1'; Set-Content $f $cmd -Encoding utf8
scp -i $env:USERPROFILE\.ssh\skoobot_runner $f localuser@192.168.50.88:C:/Users/localuser/skoobot-agent/cmd.ps1
ssh -i $env:USERPROFILE\.ssh\skoobot_runner localuser@192.168.50.88 "powershell -NoProfile -Command \"Remove-Item C:\Users\localuser\skoobot-agent\run.done -EA SilentlyContinue; schtasks /run /tn skoobot-agent\""
```

Poll `C:\Users\localuser\skoobot-agent\run.done` over ssh; the transcript is
`skoobot-agent\run.log`. **The runner only ever runs a pushed commit** — the command file
resets to `origin/main`, so push first; uncommitted work is not remotely testable, by design.

## Recipe 2 — split roster, 8 remote + 4 local (~16 min)

1. Push, then confirm `origin/main` is the commit you mean to measure.
2. Remote share: Recipe 1's command file, with the class list added to the
   `sweep-parallel.ps1` line, e.g. `-Only 'Cursed,Doomed,…' -Slots 8`. Roughly two thirds of
   the roster; roster order is in `build\results\classes-cornac.txt`.
3. Local share, **from a frozen worktree** so the dev session cannot move the code mid-run:

```powershell
git -C C:\Users\localuser\Documents\skoobot-reclauded worktree add --detach C:\Users\localuser\Documents\skoobot-sweep-freeze origin/main
$main = 'C:\Users\localuser\Documents\skoobot-reclauded'
& powershell -ExecutionPolicy Bypass -File C:\Users\localuser\Documents\skoobot-sweep-freeze\tools\sweep-parallel.ps1 `
    -Only 'Shadowblade,…,Adventurer' -KeepSkips -Slots 4 -Minutes 4 -Dossier `
    -Roster "$main\build\results\classes-cornac.txt" -OutDir "$main\build\results\sweep"
```

   `-KeepSkips` matters: without it, naming classes with `-Only` overrides the skip table
   and Adventurer burns ten minutes measuring the build (#194). Put Adventurer in the local
   share so its SKIPPED row exists and the merge does not report it MISSING.
4. Merge (see below), analyze, archive.

## Recipe 3 — deep dive one class

```powershell
.\tools\sweep-parallel.ps1 -Only 'Doomed' -Repeat 8 -Slots 8   # remote, via Recipe 1's wrapper
.\tools\sweep-parallel.ps1 -Only 'Doomed' -Repeat 4 -Slots 4   # local, via a frozen worktree
```

Each repetition lands in its own `rep1..repN` directory — reps are separate samples and are
never averaged into one row (the spread is the point). Summarise one rep with
`sweep-classes.ps1 -SummarizeOnly -OutDir <rep dir>`.

## Merging the halves

Fetch the runner's results as one zip (cmd.ps1 through the agent):

```powershell
Compress-Archive -Path 'C:\Users\localuser\Documents\skoobot-reclauded\build\results\sweep\*' -DestinationPath 'C:\Users\localuser\results.zip' -Force
```

then scp it back and merge **selectively** — never expand the zip straight into the local
results directory. A blanket expand overwrites same-named local files, which once replaced a
real 14,794-turn run with a stale smoke test, silently, both rows labelled CLEARED (#188):

```powershell
Expand-Archive C:\tmp\results.zip C:\tmp\rh -Force
Get-ChildItem C:\tmp\rh -File | ForEach-Object {
    $dst = Join-Path 'build\results\sweep' $_.Name
    if ($_.Name -eq 'summary.md') { return }                       # re-derived below
    if ($_.Name -eq 'stamps.txt') { Get-Content $_ | Add-Content 'build\results\sweep\stamps.txt'; return }
    if (Test-Path $dst) { Write-Host "COLLISION refused: $($_.Name)"; return }
    Copy-Item $_.FullName $dst
}
```

A collision means both machines ran the same class — investigate; do not pick a winner. Then:

```powershell
.\tools\sweep-classes.ps1 -SummarizeOnly            # one table over the union
.\tools\analyze-sweep.ps1 -Dir .\build\results\sweep
Move-Item .\build\results\sweep .\build\results\sweep-NN
```

The merged header lists one stamp line per machine. Different commits are fine **when the
trees _and_ `proto` match** — the trees name the code the game loaded, `proto` names the code
that drove the run (`soak.ps1`, `sweep-classes.ps1`), and the commit is decoration
(#175, #186, #214). If the halves disagree on `proto` the summary says so and still renders
the table; each half is internally comparable, but the merged headline is not attributable to
either.

## Reading the result honestly

- The headline counts comparable runs. Classes that were attempted and failed are **named
  next to the percentage** (`UNBIRTHABLE`, `TIMEOUT`, crash) — if that line exists, the 100%
  is not the whole story (#187).
- Every class-end prints `ledger: N launch(es), M reaped`. **N is usually 3** (birth, zone
  read, soak). `M > 0` means a Stop-Game path failed and the reaper cleaned up — file it.
  `N = 0` on a class whose row says anything other than `SKIPPED` means the launch ledger or
  the launch path itself broke — worse, file it first (#196). A skipped class launches
  nothing and says so — `ledger: skipped, no launch` — so a clean sweep produces **no**
  `0 launch(es)` lines at all, and one that does is always worth reading (#203).
- A sweep directory is self-describing about all three of its provenance layers: **what ran**
  (`stamps.txt`, the machine build stamps), **what judged** (each row's own verdict, frozen at
  measurement time), and **what rendered** (`tabled.txt`, appended on every summary, and named
  in the summary header).
- **The summarizer owns presentation and aggregation only; every judgement is recorded in the
  row at measurement time.** A summarizer change may alter what a table *says* about a row,
  never what the row *concluded* — `Outcome` and `Comparable` are computed in the run loop and
  `-SummarizeOnly` only reads them. A changed judge rule gets new verdicts only from new runs;
  re-judging an archive is a deliberate re-scoring pass into a new directory, never a quiet
  property of re-tabling (#210).
- Slot addon pins **repair themselves**: `New-SlotSet` re-points any of the three that names
  the wrong checkout, or one that no longer exists, and says so (`re-pinned slotN ...`). So
  deleting a freeze worktree is safe — the next batch fixes the pool. It was not always: a
  pool pinned at a deleted checkout lost four of eight slots to `NO RESULT` until the
  junctions were removed by hand (#204).
- `Skipped this run:` is derived from the rows, so it names what was actually skipped and
  why — not what the skip lists contain (#208). On a placed sweep (`-StartZone`) the
  town-start classes are **not** skipped and normally appear in the table.
- The roster is Maj'Eyal only: **steamtech classes are campaign-gated and never appear in
  it**, so their absence is not a skip and not a defect.
- Per-class turn counts run slightly lower under 8-way load than solo; compare outcomes
  across sweeps, not raw turns.

## Reading the corpus

`analyze-sweep.ps1` reads one sweep; `analyze-trend.ps1` reads all of them (#61).

```powershell
powershell -ExecutionPolicy Bypass -File tools/analyze-trend.ps1 -Out build/TREND.md
powershell -ExecutionPolicy Bypass -File tools/analyze-trend.ps1 -Class Skirmisher -NoMatrix
```

- Nothing is tracked. The archive directories are the ledger and the table is regenerated on
  demand, so it cannot drift from its data (#175).
- **Read `## Comparability boundaries` before comparing two columns.** A trend read across a
  change of trees, protocol, start zone, stop conditions or cap is not one measurement, and
  the boundary belongs beside any claim that spans it (#187, #214). The outcome matrix
  deliberately does not draw them.
- A sweep flagged **not internally one measurement** holds runs that disagree with *each
  other*, which no per-sweep summary can see. Sweeps 17, 19 and 21 each contain runs that
  silently dropped a `SCOUTER_*` condition (#206); they predate `conditions_missing`, so that
  is visible only here.
- The fingerprint is read from each run's own `soak.json`, never `stamps.txt` — sweeps 01-16
  have no stamp file, and the run is what recorded the protocol it actually ran under.
- Start zone is per **class**, not per sweep: the DLC class families start behind a town
  intro, so `norgos-lair (+1 class-specific)` is normal and is not a policy split.

## When something wedges

- **A slot is stuck**: nothing to do — the class cap kills that slot's game by pid and the
  queue continues; the class is recorded TIMEOUT with its transcript kept.
- **The whole remote run must die**: over ssh —
  `schtasks /end /tn skoobot-agent`, then `Get-Process t-engine | Stop-Process -Force`,
  then kill stray `powershell` processes (spare your own: `Where-Object { $_.Id -ne $PID }`).
- **Leftover state**: `C:\Users\localuser\slots` (either machine) is disposable — delete it;
  every recipe rebuilds slots from scratch. The frozen worktree is removed with
  `git worktree remove --force C:\Users\localuser\Documents\skoobot-sweep-freeze`.
- **Games left after a run** (`t-engine left:` above 0 in the wrapper's last line): kill by
  hand *on the sweep machine only* and file it — with the ledger reap in place this should
  no longer happen, and an instance of it is evidence of a new leak path (#196).
