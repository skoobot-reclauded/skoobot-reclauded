# Design: behaviour-verification harness

**Status:** implemented · **Tasks:** D-4, T-005 · **Date:** 2026-08-21

Verifying that the bot *behaves* correctly needs a real game: the thing under test is a
decision loop reacting to game state. Unit tests cover pure logic; they cannot tell you the
bot stopped when it should have. This is the other half.

They also cover less than they appear to. `busted` ran under PUC Lua 5.4 rather than LuaJIT
until T-045, so the suite was testing a different language in both directions; it is pinned to
LuaJIT now, with `spec/dialect_spec.lua` failing the run if that regresses. Even correct, it
cannot see the difference between the game's LuaJIT 2.0.2 and a local 2.1 — `table.new`
resolves under test and fails in-game — and neither can lint. **That gap is this harness's
job**, and it is the reason the harness is not optional tooling.

---

## 0. Shape

Two channels, both of which already existed:

| Direction | Mechanism |
|---|---|
| Game to harness | `print()` into `te4_log.txt`, every line tagged `[BRIDGE]` |
| Harness to game | Lua command files under `<T-Engine home>/4.0/skoobot-bridge/`, executed on poll |

v1 already used tagged `print()` for debugging and the author tailed it with a filter. That
half was solved in 2018; only the input half was missing.

### 0.1 Two tiers

The pump lives in two separate dev addons, because the module a hook belongs to determines
when it is alive:

| Addon | for_module | Alive | Purpose |
|---|---|---|---|
| `tools/devbridge-boot` | boot 1.0.0 | main menu, before any game | start a new game, load a save |
| `tools/devbridge` | tome 1.7.6 | once a game runs | drive and observe the bot |

`Boot:run` (boot/mod/class/Game.lua:118) and `ToME:run` are ordinary addon hooks, so **neither
tier requires an engine modification.** An earlier draft proposed a `bootstrap/boot.lua` shim
for the menu tier; that would have been an engine edit needing revert-and-retest against a
clean build before release. It proved unnecessary and was dropped.

Addons are enabled by default when there is no savefile addon list to consult
(engine/Module.lua:562-595) which is exactly the menu case, so the boot tier needs no
configuration, no cheat mode, and no box ticked.

---

## 1. Why not the alternatives

**Headless.** The engine hard-requires an OpenGL context. SDL's dummy video driver is compiled
in and advertised at startup, but forcing it gives `error opening screen: No OpenGL support in
video driver` and an access violation. There is no CI story; runs happen on a real desktop.

**A socket.** LuaSocket is bundled (engine/PlayerProfile.lua:21). A TCP bridge buys latency we
do not need, at the cost of a firewall prompt, a connection lifecycle, and a client. Files
survive restarts, need no handshake, and a directory of past commands is a replayable suite.

**OS-level input synthesis.** Needs foreground focus, cannot read state back, cannot correlate
an action with its effect. It is the only way to exercise the SDL-to-engine layer, which is
the game's code and never under test here.

---

## 2. Input primitives

Injection happens in-process, at three levels of fidelity:

- `Key.current:triggerVirtual("REST")` fires a bound command by name. `Key.current`
  (engine/Key.lua:93) is the focused handler, so this follows dialogs and drives menus as well
  as the map.
- `Key.current:receiveKey(sym, ...)` is a synthetic keypress through the real dispatch path
  (engine/KeyCommand.lua:63).
- Direct Lua, for scenario setup: apply an effect, teleport, spawn. This is what turns
  "reproduce T-012" from a play session into three lines.

Screen coordinates are never used. Menus are addressed by dialog class name and bound-command
name, so changing resolution mid-run cannot break a test.

---

## 3. Interference

The development machine is also a machine a person uses. A keystroke, a click, or a resolution
change mid-run produces failures that are **not defects**, and an autonomous loop that cannot
tell the difference will file phantom bugs and then "fix" them.

So every input that did not originate from the bridge is logged. `bridge.injecting` is set
around injected input, and three wrappers report anything else:

| Wrapper | Emits |
|---|---|
| `KeyBind:receiveKey` | `INTERFERE key sym=... turn=...` |
| `Mouse:receiveMouse` | `INTERFERE mouse btn=...` (clicks only; motion is noise) |
| `Game:idling` | `INTERFERE focus=...` |

Resolution changes need no instrumentation: the engine already logs `[DO RESIZE]`.
`Invoke-Bridge` sets `Tainted` if any of these appear while a command was in flight. **A
tainted result is void and re-run, never recorded.**

The structural protection matters more than the detector: **tests measure progress in
`game.turn`, never wall-clock.** A click or a resize costs frames, not turns, so a
turn-counted assertion is immune by construction. That is the same principle as T-027's
progress invariant, arrived at independently, which is some evidence it is the right one.

---

## 4. Engine facts worth not rediscovering

- Log is `<game dir>/te4_log.txt`, opened in `w` mode, so it is **truncated every launch**.
  Pass `--flush-stdout` or it is block-buffered and tailing lags by kilobytes.
- Useful flags: `--flush-stdout`, `--home <dir>`, `--no-steam`, `--no-web`, `--safe-mode`.
- Focus does not gate ticking. `Game:idling` (engine/Game.lua:225) stores `has_os_focus` and
  nothing in engine or module ever reads it. The window may sit behind everything else.
- A separate C-side idle throttle toggles 30 FPS and 2 FPS. Measured poll rate at an idle menu
  is ~2.2/sec, so **worst-case command latency is ~500 ms**. That is the floor, not a bug.
- `game:onTickEnd(f, name)` returning `game.TICK_RESCHEDULE` is a self-perpetuating per-tick
  callback (engine/Game.lua:331). It looks like the obvious poll loop and is not —
  see 4.1. It also calls `requestNextTick`, which pins the engine at 30 FPS and holds a core.
- Addon directories load unpacked if named `<module>-<something>` with an `init.lua`
  (engine/Module.lua:409-414). Junction the repo tree in and edits go live on next launch.
- **Addons are scanned per module.** `listAddons` filters on `^<module.short_name>%-`, so at
  the main menu only `boot-*` addons are considered; `tome-*` ones are not looked at until a
  tome game is instanciated. A product addon can therefore be correctly installed and
  completely invisible at the menu tier — that is not a fault.
- **A savefile records its addon list, and the engine enforces it.** `Module:instanciate`
  passes `save_desc.addons` into `loadAddons` (`:1041`), which removes anything absent from
  it — `Removing addon <name>: not allowed by savefile` (`:565-569`) — and carries on. The
  addon is simply not there. Nothing errors, nothing is highlighted, and a behaviour run from
  such a save happily "verifies" a game that never loaded the thing under test. The
  enabled-by-default rule above applies only when there is **no** savefile list to consult,
  which is why the menu tier needs no configuration and a loaded game does.

  Two independent guards, in `harness.ps1`: `Assert-SaveAddons` reads `desc.lua` before
  launching, and `Assert-NoAddonDropped` watches the log after. The first catches a stale
  save without spending a launch; the second catches everything else, including an addon
  dropped for a reason the descriptor cannot show. **A save must be regenerated whenever the
  addon set changes** — `tools/new-character.ps1` does it unattended, and now refuses to
  write a save whose game did not load the product.
- The engine reboots into a module plus savefile via `Module:instanciate(mod, name, new_game,
  ...)` (engine/Module.lua:931), the same call the New Game menu makes.

- **Launch time has a long tail, and it is the main menu's demo level.** A launch is normally
  **~6 s**, but roughly **one in eight takes 90–166 s**. Nothing about the addon, the
  junctions or the harness affects it — measured with and without the product installed, and
  the same tail appears either way.

  The log carries no timestamps, so sampling it once a second is what locates the time. Two
  captured stalls, both ~166 s:

  | | where the seconds went |
  |---|---|
  | dungeon demo | 15 s after `C Map seens texture`, **57 s** after `[RoomsLoader:init] loaded room`, then 13–18 s gaps between `Loading tile` lines |
  | forest demo | 49 s, 36 s and 19 s gaps across the same phase |

  So it is the boot module building its background demo level: procedural room generation,
  then texture loading for whatever terrain it produced. Both are plausible sources of a long
  tail here — generation with rejection/retry is naturally heavy-tailed, and this VM has **no
  GPU**, so every `Loading tile` is a software texture upload. The exact split between the two
  is not pinned down; what is established is that it is demo-level construction, it is
  intermittent, and it is not ours.

  **A correction worth keeping, because the mistake is easy to repeat.** The first diagnosis
  blamed the te4.org profile connection: the gaps in the forest capture all ended on
  `Server latency` lines, which looked conclusive. It was not. Those lines are emitted
  periodically by a background thread, so they land at the boundary of *any* long gap.
  Disabling connectivity entirely left a 166 s stall in place, with no `Server latency` lines
  in the log at all. Periodic chatter is not evidence of causation — check that removing the
  suspect removes the symptom.

  **Disabling `disable_all_connectivity` does not help, and was tried.** An alternating A/B,
  eight launches per arm:

  | | median | typical mean | stalls >30 s |
  |---|---|---|---|
  | connectivity ON | 12.8 s | 10.1 s | 2 of 8 |
  | connectivity OFF | 59.7 s | 7.0 s | 4 of 8 |

  Stalls in both arms, more of them with it disabled. The typical case is perhaps a second
  better offline — inside the noise at this sample size — and the tail is untouched. The dev
  loop therefore runs **in the same configuration players run in**, and `setup-dev.ps1`
  manages no connectivity setting at all.

  That is the point worth keeping, more than the numbers. Two configurations would have meant
  every behaviour result carrying a silent "…but measured offline", and a retest step before
  release that someone has to remember. Trading a second of startup for a rule that depends on
  discipline is the wrong way round here — the same reasoning as §4.1's preference for
  removing a failure mode over detecting it. There is also nothing to test *against*: this
  install has no te4.org account, so the engine logs `no online profile active` and addon hash
  validation, achievements and character upload are inert either way.

### 4.1 Fourteen traps, each of which cost a debugging cycle

**The previous run's log can satisfy the next run's checks.** `te4_log.txt` is truncated by
the engine on startup — but not until it opens the file, measured at **~5 ms after
`Start-Process` returns**. `Reset-LogCursor` rewinds to offset 0, so a poll landing inside
that window reads the *whole previous run*: its `[BRIDGE] ready`, and its `cmd-0001.lua OK`.
`Start-Game` then reports a game that is up and answering **before the process has opened its
log**. Measured: two of four launches spaced three seconds apart returned in 0.0 s. That is a
false PASS, which is the only result this harness must never produce. `Clear-GameLog` now
deletes the file before launching — removing the possibility rather than detecting it — and
`Start-Game` additionally waits for the engine's own `[CPU] Detected` banner. Neither check
suffices alone, because the stale log contains the banner too. Guarded by
`tools/test-relaunch.ps1`.

**`Stop-Process -Force` does not wait for the process to die.** It returned in 6 ms with the
game still alive; the process actually exited 77 ms later. `Start-Game` calls `Stop-Game` and
then launches immediately, so without a wait a second engine starts while the first still
holds the GL context, the audio device and the log — two instances at once, the one thing
§6 says never to do. `Stop-Game` now polls until they are gone.

**`ready` is not readiness.** The hook emits `[BRIDGE] ready` from `Boot:run` / `ToME:run`,
which fires well before the `display()` pump starts turning. On a cold start — the first
launch after the addon set changes, when the engine recomputes addon MD5s — the pump stayed
silent for about a hundred seconds after `ready` while the window came up. `Start-Game`
returned on the log line, the first five commands were fired into that gap, timed out, and
were deleted unread. Five failures in a row, none of them real: precisely the class of result
this harness exists to prevent, produced by the harness itself. Readiness is now proved by a
round trip — `Start-Game` sends `return "pong"` and only reports ready when it comes back.
A warm start answers in about a second, so the generous timeout costs nothing when it is not
needed.

**`fs.delete` silently no-ops on the command files.** physfs writes only beneath its own write
path, which the module repoints. The first pump deleted nothing and re-ran `cmd-0001` about
170 times. Execution is now gated on a monotonic sequence, idempotent whatever the filesystem
does; the harness deletes. *This was an unbounded loop making no progress: T-027's exact
failure mode, in the tool built to catch it.*

**Addon hooks run in `setmetatable({...}, {__index = _G})`** (engine/Module.lua:699). Reads
chain to `_G`, writes stay local, so a bare `bridge = {}` is invisible to `loadstring` chunks.
Export with `_G.bridge = bridge`.

**`onTickEnd` is the wrong hook, in two different ways.** The boot module's `tick()` only
reaches `engine.Game.tick`, and so `onTickEndExecute`, when `self.level` is set or
`self.stopped` is true (boot/mod/class/Game.lua:454-462) — the menu's demo level supplies that
most of the time, but it drops out across level changes and the pump stalls with it. In the
tome module the problem is different: `onTickEndCapture` (engine/Game.lua:380) swaps the whole
callback set into a temporary table during level changes, so a callback that reschedules
itself can land in a set that is discarded rather than merged, and the pump dies silently at
the first transition. In a game about descending dungeons, that is immediately.

`display()` looks like the answer, and alone it is not: **it stops when the OS window loses
focus or is minimised.** Measured — the pump went silent immediately after
`INTERFERE focus=false`. On a machine a person also uses, that is not an edge case.

So **both tiers arm both mechanisms**: a `display()` wrapper and a self-rescheduling
`onTickEnd`. They fail in complementary ways — `display()` dies on focus loss, `onTickEnd`
dies on level-change capture — so one always survives. Double invocation is harmless because
`claim()` is guarded and the sequence gate makes execution idempotent. Verified against a
minimised window by `tools/test-unfocused.ps1`.

The `onTickEnd` callback is armed **once**, not re-armed per frame: `onTickEndExecute` clears
the name table on every pass, so re-arming by name would append a fresh closure every tick and
grow without bound.

**A re-entrancy guard must not span execution.** `core.display.forceRedraw()` re-enters
`display()` and so the pump, which argues for a guard — but a guard held across the command
latches forever the first time a command does not return, silently killing the pump. Guard the
shared state (file selection) and release before executing arbitrary code. *I shipped this bug
and it cost a full run to find.*

**Birth does not return.** `atEnd("created")` runs birth, world generation and a save/load
cycle; the frame that invoked it does not survive to report a result. Waiting for a reply that
will never arrive is not a diagnosis. Fire it with `-NoWait` and poll for the resulting state
instead — the same discipline as measuring turns rather than seconds.

**Visibility is stale until FOV is recomputed, and stale reads as "nothing there".** Hostile
detection goes through `game.level.map.seens`, which `mod.class.Player:playerFOV()` populates
(mod/class/Player.lua:550). In normal play that runs every turn, so it is always current. But
a scenario that *moves* the player — `teleportRandom` to set up a situation — and then asks
what is visible gets the answer for the old position, and after a teleport that answer is
usually zero. Zero is indistinguishable from success. The walking-skeleton scenario believed
it once, moved on, and the bot found four hostiles the instant it took a real turn. **Call
`playerFOV()` after any injected movement, before reading anything about visibility.**

**The savefile directory comes from the character's name**, not from the name passed to
`Module:instanciate` (mod/dialogs/Birther.lua:225). `randomBirth()` also randomises the name,
so an unattended run lands in an unpredictable directory unless the name is set explicitly
afterwards.

**Saving is asynchronous.** `background_saves` defaults to true, so `game:saveGame()` returns
immediately while a separate thread writes `game.teag.tmp` and renames it. Killing the process
on the strength of that return leaves a zero-byte `.tmp` and no save at all. Wait for the real
file, not for the call.

**`Stop-Game` kills the other session's game, and the victim reports a launch flake.** The
game install is one resource — one process, one log, one bridge directory, three junctions
pointing at exactly one checkout — and `Stop-Game` killed every `t-engine` it could see, with
`Start-Game` calling it first. Two sessions running scenarios at once therefore voided each
other, and the victim could not tell: on 2026-08-22 both `tome-tier pump never turned`
failures (00:55 and 21:15) were `status=CRASHED`, the process gone between a live boot-tier
pump and the tome-tier probe, and both archived logs end mid-load with no Lua error. That is
what a kill from outside looks like from inside, and it was read as the main menu's long tail.
The one genuine tail that day was a `TIMEOUT`.

So the game is **leased** (`tools/harness-lease.ps1`, #60). `Start-Game` records the host
process, its checkout and the game PID in `T-Engine/4.0/skoobot-bridge/harness.lock` and
refuses while another *live* host holds it; `Stop-Game` leaves a live holder's game alone and
still reaps everything, orphans included, when nobody live owns it. A lease is live while its
host process is, so a crashed run frees it by dying and nothing cleans up. It outlives
`Stop-Game` on purpose — `clean-build.ps1` restores junctions after stopping the game — and
ends when the host exits, which for `powershell -File` scenarios means the run. Children
inherit it through `SKOOBOT_HARNESS_HOST`, so `clean-build.ps1` can run `setup-dev.ps1`.

Two corollaries, enforced in the same place. `setup-dev.ps1` repoints the junctions to
whichever checkout runs it — that is how a worktree becomes the live one — and it refuses
under another host's lease, because repointing under a running game hands it a different
checkout mid-run. And `Start-Game` refuses if any junction that exists points at a checkout
other than the one its own `harness.ps1` lives in, naming the `setup-dev.ps1` to run: without
that, a scenario silently measured another checkout's `src/`. Both refusals are thrown, not
returned, so they cannot be mistaken for a result. `Load-Save` also retries the launch chain
once when it fails on infrastructure with the game still alive — the long tail occasionally
outlasts even the 240 s pump timeout — printing the retry and returning `Attempt`; a process
that *died* is reported, never relaunched, because after the lease that is a real crash or a
human. Guarded by `tools/test-occupancy.ps1`.

---

### 4.2 The load oracle

The release gate has no `[BRIDGE]` channel to ask about the product, because the product
junction is gone and only the packed archive is installed. The engine's own log answers it.
**All these lines are tab-separated**, because they are `print()` calls with several
arguments — matching `Checking addon tome-…` with a space silently never fires, and a gate
that never fires passes.

Two lines matter, and they are not the same question.

**Discovery** — `Module.lua:411`, emitted for everything in `/addons/`:

```
Checking addon<TAB>tome-skoobot_reclauded-0.1.0.teaa<TAB>:: (as dir)<TAB>false<TAB>:: (as teaa)<TAB>23<TAB>
```

`(as dir)` is `fs.exists(dir/init.lua)`; `(as teaa)` is `short_name:find(".teaa$")` — a match
position, or `nil`. This says only that the engine *looked* at it.

**Binding** — `Module.lua:490`, emitted only for addons actually loaded, and the line to
assert on:

```
Binding addon<TAB>SkooBot: Reclauded<TAB>/addons/tome-skoobot_reclauded-0.1.0.teaa<TAB>tome-skoobot_reclauded-0.1.0
 * with hooks
 * with superload
```

The **third field is `add.teaa`**: the archive path when the addon came from an archive, and
`nil` when it came from an unpacked directory. That one field is exactly the question the gate
exists to answer — *did this load from the artifact, or from the working tree?* — and it
answers it directly rather than by inference from what is absent.

The ` * with …` lines (`:496`, `:511`, `:522`, `:533`) follow their own `Binding addon` line,
so attribution is unambiguous: read from one `Binding addon` to the next. They appear once per
declared directory, so they also check that the manifest flags did what they claimed — a build
whose `init.lua` sets `hooks = true` and produces no ` * with hooks` did not mount what it
advertised.

Two absences complete the oracle, and absences need explicit assertions or they pass by
accident:

- no `Removing addon skoobot_reclauded` (§4, the savefile rule);
- no `Lua Error` after the addon is checked.

One trap in the negative space: a `.teaa` with no root `init.lua` is skipped at `:416`
**without any error at all** — nothing is printed for it beyond the `Checking addon` line. If a
junction is still present, the engine loads that instead and the gate passes on the working
tree rather than on the artifact. That is why the gate removes the product junction, why it
asserts on `Binding addon`'s third field rather than on the absence of complaints, and why
`tools/pack.ps1` refuses to emit an archive without a root `init.lua` in the first place.

### 4.3 Why the gate cannot be entirely bridge-free

The audit that specified this gate assumed the devbridge could be removed along with
everything else, since the oracle above is read from the log rather than through the bridge.
Reading it needs no bridge — but *reaching* it does.

`tome-*` addons are only scanned when a tome game is instanciated (§4), and the engine has no
command-line path into a module: its full flag set is `--flush-stdout`, `--home`,
`--ignore-window-change-pos`, `--no-debug`, `--no-sandbox`, `--no-steam`, `--no-web`,
`--safe-mode`, `--xpos`, `--ypos`. Booting into a module goes through
`util.showMainMenu`/`Module:instanciate` from inside Lua. So without something driving the
menu, the game sits at the main menu forever and never looks at a `tome-` addon at all.

The gate therefore removes the **product** junction — the one that could make it pass on the
working tree — and keeps the two devbridge junctions purely as the thing that presses the
buttons. What that leaves unproven is narrow and worth stating: it shows the product loads and
runs from the packed archive, not that the game runs with no dev addons present at all. The
devbridge cannot contaminate the artifact, because `tools/pack.ps1` packs only `src/` and
refuses any entry under `tools/`.

## 5. Footprint and release hygiene

The bridge **executes arbitrary Lua from disk** and must never ship. Two properties keep that
from being a matter of discipline:

1. It lives in `tools/`, which is not packaged. The release addon is `src/` only.
2. It is a separate addon, not a debug flag inside the product, so there is no gate to get
   wrong and no superload surface added to the shipped addon (cf. T-021).

Nothing in the engine, module, or DLC archives is modified. The whole footprint is:

| Change | Revert |
|---|---|
| Junction `game/addons/tome-skoobot_reclauded` → `src/` | remove it |
| Junction `game/addons/tome-skoobot-devbridge` → `tools/devbridge` | remove it |
| Junction `game/addons/boot-skoobot-devbridge` → `tools/devbridge-boot` | remove it |
| `T-Engine/4.0/settings/resolution.cfg` set to `800x600 Windowed` | one line, not reverted |
| `te4_log.txt`, `T-Engine/4.0/skoobot-bridge/`, `build/logs/` | artifacts, delete freely |
| `T-Engine/4.0/skoobot-bridge/harness.lock` | the lease (§4.1); stale once its host exits, delete freely |

**Three junctions, not two.** The devbridge pair is the channel; `tome-skoobot_reclauded` is
the product. Until it existed, every harness run exercised the bridge and never once loaded
the thing under test.

**The harness save carries six addons** (#27). Its descriptor,
`<T-Engine home>/4.0/tome/save/harness/desc.lua`, records `skoobot_reclauded` (the product
junction), `skoobot_devbridge` (the tome-tier junction), the three DLCs installed as
`<game dir>/dlcs/*.teaac` — `ashes-urhrok`, `orcs`, `cults` — and `items-vault`, from
`<game dir>/addons/tome-items-vault.teaa`. The boot-tier devbridge belongs to the boot module
and is never part of a tome save. Anything else under `<game dir>/addons/` is absent from
that list and so dropped on load (§4) — which is fine, because the harness needs exactly two
of the six, `skoobot_reclauded` and `skoobot_devbridge` (`$RequiredSaveAddons` in
`harness.ps1`); the rest only have to stay the same, since a save whose addon set changes
has to be regenerated with `tools/new-character.ps1`.

None of this is done by hand any more:

```
powershell -ExecutionPolicy Bypass -File .\tools\setup-dev.ps1            # apply
powershell -ExecutionPolicy Bypass -File .\tools\setup-dev.ps1 -Remove    # revert
```

It is idempotent, so re-running it is also how you check the state. It refuses to touch a
real directory sitting where a junction should be, and removes junctions through
`Directory::Delete(path, false)` rather than `Remove-Item -Recurse` — the latter can delete
*through* a junction, which here would mean emptying `src/` out of the working tree.

`resolution.cfg` is deliberately **not** reverted: the pre-harness value is recorded nowhere,
so restoring a guess is worse than leaving it, and it cannot affect whether an addon loads.

A clean-build check is therefore "delete three junctions", not "restore a patched file" —
and `-Remove` is exactly the inverse T-035 needs.

---

## 6. Tools

| File | Role |
|---|---|
| `tools/devbridge/` | tome tier: pump, injection, interference detection |
| `tools/devbridge-boot/` | boot tier: pump and injection at the main menu |
| `tools/setup-dev.ps1` | creates/removes the three junctions and `resolution.cfg`; refuses under another host's lease |
| `tools/harness.ps1` | `Start-Game`, `Load-Save`, `Invoke-Bridge`, `Stop-Game`, `Wait-LogLine`, `Show-LoadDiagnostics`; the assertions `Assert-Result`, `Assert-Turns`, and `Write-ScenarioResult` (§7) |
| `tools/harness-lease.ps1` | whose the game is: the lease, and which checkout the junctions point at (§4.1) |
| `tools/smoke-test.ps1` | proves the loop end to end |
| `tools/test-unfocused.ps1` | proves the pump survives a minimised window |
| `tools/test-relaunch.ps1` | proves a relaunch cannot be satisfied by the previous run's log |
| `tools/test-occupancy.ps1` | proves one live host owns the game and a dead one is taken over |
| `tools/new-character.ps1` | creates and saves a character with no human input; `-Class`/`-Race` make a fixture (§7) |
| `tools/scenario-*.ps1` | the scenario library (#4): one complaint or one fix each, exit 0 pass · 1 fail · 2 tainted · 3 inconclusive |
| `tools/scenario-t010-marked-target.ps1` | the #5 repro #4 deferred: a Combat talent the game refuses (Rockswallow, unmarked target) falls through to the next priority in real combat, on the fixture |
| `tools/run-scenarios.ps1` | runs the library in sequence, one child process per scenario, one JSON line per run under `build/results/`, re-runs a tainted one once, prints the table (§7) |
| `tools/soak.ps1` | the unattended long run (#61): the bot on the fixture with a counted resume policy, a stop histogram and a JSON summary (§7) |
| save `fixture-berserker` | the fixture: a Cornac Berserker made by `new-character.ps1 -Class Berserker`, on disk as `save/fixture_berserker/` (§7) |

Character creation drives the Birther's own `randomBirth()` by default, so no descriptor
knowledge is hardcoded here and nothing breaks when ToME adds a class. A fixture is made the
same way with the choice forced: `-Class` and `-Race` are resolved against the Birther's own
`all_races`/`all_classes` trees and selected through `raceUse()`/`classUse()`, which is what a
click calls, so a locked or disallowed choice fails loudly instead of producing a different
character. Either way birth is then *finished* through the dialogs' own `EXIT` binds — the
birth level-up dialog with nothing allocated, then the welcome text — because the rest of birth
(the starting quest, `onBirth`, `creating_player = false`; mod/class/Game.lua:322-377) runs from
those callbacks. Saving under the open dialogs, as the first version of the script did, worked
only because `creating_player` is not a saved field; the quest was simply never granted.

---

## 7. Fixtures and results

**Fixtures are saves with a known character.** The `harness` save is a random-class character
(it rolled a Halfling Rogue, 2026-08-21 local time) shared by every scenario that does not
care what it is, and it is never regenerated casually, since every lane relies on it; a scenario that
needs a particular talent set names a fixture instead. Fixtures are named `fixture-<subclass>`
and created by `tools/new-character.ps1 -Name fixture-<subclass> -Class <Subclass>`, with the
race left to the Birther's default (Human / Cornac) unless the scenario needs otherwise. The
first and so far only one is **`fixture-berserker`**: a melee class with no ranged or
marked-target talent of its own, chosen so that a scenario which needs such a talent learns it
explicitly (`p:learnTalent(tid, true, 1)`) and knows it is the only one — that is what
`scenario-t010-marked-target.ps1` does with Rockswallow. One trap, now handled in
`Get-SaveDirName`: the engine stores a save under `name:gsub("[^a-zA-Z0-9_-.]", "_"):lower()`
(engine/Savefile.lua:46), and in a Lua set `_-.` is an empty range, so the hyphen is replaced
too — `fixture-berserker` loads by that name and lives in `save/fixture_berserker/`.
A fixture is regenerated with the same command when the addon set changes (§4), and is never
written by a scenario: nothing a scenario learns, equips or configures is saved.

**One JSON line per run, under `build/results/`.** `run-scenarios.ps1` runs every
`tools/scenario-*.ps1` as its own `powershell -ExecutionPolicy Bypass -File` child — the unit
the lease works at (§4.1), so two sessions interleave at scenario granularity — and appends
`{scenario, status, exit, seconds, tainted, attempts, summary, lines[], when}` to
`build/results/<yyyy-MM-dd>.jsonl` through `Write-ScenarioResult`. The file is append-only: a
re-run is a second line with `attempts=2`, never an edit of the first, so the day's file is the
day's history. `build/` is gitignored, so nothing here reaches the repository. Two scenarios are
excluded by default and the runner says so: `scenario-baseline-v1` needs the original SkooBot
0.0.12 installed and its own save, and `scenario-walking-skeleton` is superseded by the
per-issue scenarios. Before each scenario the runner runs `setup-dev.ps1` from its own checkout,
so the junctions point at the tree under test even when another worktree ran last; if the game
is another live host's it waits and retries rather than recording a failure that is nobody's.

**Tainted is not OK, and is re-run once.** A scenario that exits 2 was touched by a human
mid-run (§3): its result is void, so the runner runs it again, once, and records both lines.
A second taint stays `TAINTED` — at that point the machine is in use and the answer is to run
later, not to keep trying. `-NoRetryOnTaint` records the first taint and moves on. An exit 3,
`INCONCLUSIVE`, is a scenario that could not build the situation it wanted to measure: it is
listed as such, and it is neither a pass nor a product failure; the runner's own exit code is 1
only for `FAIL`, `CRASHED`, `TIMEOUT` or a game that stayed `BUSY`.

**The soak's resume policy is a measuring device, never product behaviour.** `soak.ps1` (#61)
runs the bot on the fixture for `-MaxMinutes` (or to `-MaxLevel`, `-MaxTurns`, death, or
stuck) and counts what it meets. The bot stops on purpose and often — that is its design
(design-stop-conditions.md) — so a run that ended at the first stop would measure nothing; a
small policy restarts it, and **every restart is counted and reported** so a number in the
summary can be read for what it is. The policy: (a) a dialog is open → close it through its own
`EXIT` bind (the level-up dialog closes with nothing allocated; the death dialog is never
touched); one with `ACCEPT` but no `EXIT` gets `ACCEPT` (`accept-dialog`); a `Chat` has no binds
at all and cannot be escaped — the Trollmire 3 arrival opens one — so its *first* answer is given
through the dialog's own `use()`, the method typing the answer's letter calls, and the answer's
text is reported (`answer-chat`); (b) "standing on a level change" → stairs down or into another non-wilderness zone:
the game's own `CHANGE_LEVEL` bind, once; stairs up or into the wilderness: one real move off the
tile, because the bot cannot run in the wilderness and up is not progress; (c) the same reason
five times in a row with no turn taken → the `REST` bind once; if it recurs, up to three real
moves away, once, to a tile with no vault door beside it — the engine's own auto-explore
re-targets a vault door whenever the player stands *next* to it, diagonals included
(PlayerExplore.lua:1861), so a bot restarted where it handed back at the door prompt walks into
the same prompt forever, and a single step onto the door's other neighbour changes nothing; if
it still recurs, `STUCK <reason>` ends the run; (d) the player is dead → record the killer
(`game.player.killedBy`, set by `onPartyDeath`; there is no `died_from` in 1.7.6) and end;
(e) anything else → `skoobot_reclauded.start()` again; (f) **descend when explored** — the
first 30-minute run put 271 of its 338 stops on "standing on a level change" with two descents
in all: once a level is explored the engine's auto-explore targets an exit, usually the stairs
it arrived by, and `running_prev` keeps that target, so (b)'s step-off restarted a bot that
walked straight back. Now a hand-back on stairs up or the wilderness exit, when the level
reports nothing left to explore (`running_prev.explore == "exit"`, which auto-explore sets only
when no unseen tile, item or door is reachable, PlayerExplore.lua:2299 — read, never run, since
`autoExplore()` moves the player) or for the `-DescendAfter`th time on that level (3), walks to
the nearest down staircase the player has *seen*, through tiles the player has seen, by the
engine's own `engine.Astar` — the call the bot's combat pathing makes — one real move per poll,
spending turns as a player would and handing the game back to the bot the moment a hostile is
in view; on the stairs, the `CHANGE_LEVEL` bind. Counted as `descend`, and every move is
counted with it; no seen down staircase, or none reachable, falls through to (b) and the bot
explores more. The same walk is also the soak's way past a *loop it cannot step out of*: one
hand-back reason recurring `-LoopAfter` times (15) on one level. (c) only sees a loop that spends
no turns, and #64's sealed door spends a few — close, restart, the bot's own pathing walks back
through the door, prompt — so the second validation run spent all twelve minutes and 78 of 79
stops one tile from that door, with (b)'s step-away undone every time. A walk started that way
hands back only for an *adjacent* hostile, because a hostile in view that the bot cannot reach
is what the loop is made of. `-NoDescend` turns it off; (g) **next zone** — on the zone's last level
(`game.zone.max_level`) under the same trigger, or on the wilderness exit of an explored level
with no seen down staircase, the engine's own transition `game:changeLevel(1, "<zone>")` — the
call a step onto a zone entrance on the world map makes (Game.lua:2292), landing on the new
level's up staircase exactly as walking in does — to the first zone of a list not yet visited
(`game.visited_zones`) whose `level_range` minimum is at most the character's level + 2.
Counted as `next-zone`. The bot hands back in the wilderness by design ("cannot be used in the
wilderness"), which is why the first run never left Trollmire, and why the wilderness is never
entered deliberately. **The zone list is measurement carriage, not product**: trollmire,
ruins-kor-pul, norgos-lair, scintillating-caves, rhaloren-camp (all `level_range {1,7}`), then
old-forest, daikara, maze, sandworm-lair (`{7,16}`) — the order a character of that level would
usually take the early dungeons in, verified against `data/zones/<id>/zone.lua` (there is no
`kor-pul`; the ruins are `ruins-kor-pul`) and re-read from the installed module at start, so an
id with no `zone.lua` is dropped and reported rather than failing at the transition. `-Zones
"a,b,c"` replaces it. Either change may be refused by `changeLevelCheck` for two turns after a
kill; the soak then passes one turn through the `MOVE_STAY` bind and counts it (`wait`).
Nothing in it spends a point, writes a stat or moves the player except through the game's own
binds, the engine's own transitions and ordinary moves, every one of them counted. It
fills the fixture's Combat/Sustain/Recovery rules from what the character knows
(`-NoAutoRules` to skip), since a fresh fixture has none and could not fight — a player would
do that from the talent screen, and the crude rule set is part of what is measured. The
player's own stop-condition knobs can be set for the run (`-Conditions
"SCOUTER_STRONGERENEMY=WARN,…"`, through the product's conditions API, recorded in the
summary): the power-level conditions are `STOP` by default, and a `STOP` whose cause stays in
view stops every restart on the spot, by design, so a default run ends `STUCK` at the first
enemy above `MAX_DIFF_POWER` — which is a measurement, not a fault. The game autosaves on a
zone change under `game.save_name`, so the soak re-points that at `soak-scratch` right after
loading and the fixture is never overwritten. The output is a JSON summary — levels, turns,
wall-clock, deaths and killer, the stop histogram sorted by count, the resumes by action, the
two rungs' own counters (`rungs.descend`: taken, walks, moves, abandoned; `rungs.next_zone`:
taken, the transitions, the list used; `rungs.waits`), the Lua errors the engine logged, the
conditions set — plus a markdown twin and the same table printed; `descend` and `next-zone` are
rows of the resume table even at zero, so a summary always says whether they fired. **None of
this is how the product should behave**: a player who wants the bot to walk
through stops has the WARN/STOP/IGNORE policy for that, and anything the soak's histogram says
is worth changing is changed in the product under its own issue, with a scenario.
