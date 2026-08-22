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

### 4.1 Ten traps, each of which cost a debugging cycle

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

**The savefile directory comes from the character's name**, not from the name passed to
`Module:instanciate` (mod/dialogs/Birther.lua:225). `randomBirth()` also randomises the name,
so an unattended run lands in an unpredictable directory unless the name is set explicitly
afterwards.

**Saving is asynchronous.** `background_saves` defaults to true, so `game:saveGame()` returns
immediately while a separate thread writes `game.teag.tmp` and renames it. Killing the process
on the strength of that return leaves a zero-byte `.tmp` and no save at all. Wait for the real
file, not for the call.

---

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

**Three junctions, not two.** The devbridge pair is the channel; `tome-skoobot_reclauded` is
the product. Until it existed, every harness run exercised the bridge and never once loaded
the thing under test.

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
| `tools/setup-dev.ps1` | creates/removes the three junctions and `resolution.cfg` |
| `tools/harness.ps1` | `Start-Game`, `Invoke-Bridge`, `Stop-Game`, `Wait-LogLine`, `Show-LoadDiagnostics` |
| `tools/smoke-test.ps1` | proves the loop end to end |
| `tools/test-unfocused.ps1` | proves the pump survives a minimised window |
| `tools/new-character.ps1` | creates and saves a character with no human input |

Character creation drives the Birther's own `randomBirth()`, so no descriptor knowledge is
hardcoded here and nothing breaks when ToME adds a class.
