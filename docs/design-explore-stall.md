# The explore stall

Why the engine aborts a run for a hostile the bot cannot see, and what the bot does about
it. Issues **#153** (the disagreement) and **#164** (the live-lock it causes).

Everything in §1 was read out of ToME 1.7.6's own source and then **measured**, because the
obvious reading of it is wrong in the one way that decides the whole design — and was wrong in
this document's own first draft.

---

## 1. What the engine actually does

### 1.1 `seens` tracks LIT grids, not visible ones

This is the load-bearing fact, and it is the one that is easy to get wrong.

`spotHostiles` — both the engine's (`mod/class/Player.lua:915`) and the bot's line-identical
copy — reports an actor only where `game.level.map.seens(x, y)` is set. And `seens` is not
"in field of view". `engine/Map.lua:649`:

```lua
function _M:apply(x, y, v)
	self.infovs[x + y * self.w] = true
	if self.lites[x + y * self.w] then          -- <-- only if the grid is LIT
		self.seens[x + y * self.w] = v or 1
```

`infovs` is every grid in FOV. `seens` is only the lit part. Inside the character's own light
radius, `applyExtraLite` (`:663`) sets it unconditionally.

**So a hostile four to eight grids away, in plain line of sight and well inside sight range, is
simply not in `seens` while it stands in the dark.** Walk close enough to light it and it is.

| Field | Set when | Read by |
|---|---|---|
| `infovs` | in FOV, lit or not | the renderer, `applyExtraLite`'s guard |
| `seens` | in FOV **and lit**, or within the character's own light radius | **`spotHostiles`** |
| `lites` | the level generator; not recomputed by the FOV pass | `Map:apply` |

### 1.2 The map is only wiped when a frame is drawn

`Map:cleanFOV` (`engine/Map.lua:460`) returns early unless `map.clean_fov` is armed:

```lua
function _M:cleanFOV()
	if not self.clean_fov then return end
	self.clean_fov = false
	for i = 0, self.w * self.h - 1 do self.seens[i] = nil self.infovs[i] = nil end
	self._map:cleanSeen()
end
```

Across the whole engine and module there are exactly three assignments to that flag:

| Site | Sets | Note |
|---|---|---|
| `engine/Map.lua:462` | `false` | inside `cleanFOV` itself |
| **`engine/Map.lua:620`** | `true` | at the foot of **`Map:display()`** — a drawn frame |
| `mod/class/Player.lua:1314` | `true` | in `runStopped` |

`cleanFOV` has exactly one caller: `playerFOV()` (`mod/class/Player.lua:555`).

`Player:act()` runs a whole run inside one call — `while self:enoughEnergy() and self:runStep()
do end` — and draws no frame inside that loop. `runMoved()` (`:1306`) is just `playerFOV()`. So
every step **adds** to `seens` without clearing it.

### 1.3 So the two views differ by construction

Running A → B:

1. Run begins at **A**. `seens = FOV(A)`.
2. Step to **B**. `runMoved` → `playerFOV` → `cleanFOV` is inert → `seens = FOV(A) ∪ FOV(B)`.
3. `runCheck` (`:1211`) calls `spotHostiles` against **the union**, finds a hostile that was lit
   from A and is dark from B, and aborts the run.
4. `runStop` → `runStopped` (`engine/interface/PlayerRun.lua:380`) arms `clean_fov` **and
   recomputes**, so `seens = FOV(B)` — clean and current.
5. `afterAct` → `playerActions()` → `skoobot_act` → the bot's `spotHostiles` reads `FOV(B)`.
   The hostile is honestly not in it. The bot stays in EXPLORE and re-issues, correctly.

**Neither view is stale.** The engine's is a superset, and the difference is made of grids that
were lit — or walked near — earlier in the run and are dark now.

### 1.4 "Ran for 2 turns" is structural

`engine/interface/PlayerRun.lua:119`:

```lua
local ret, msg = self:runCheck()
if not ret and (self.running.cnt > 1 or self.running.busy) then
```

The first step is taken **unconditionally**; `runCheck` can only stop the run from step 2. So
one step always happens, its FOV is always accumulated, and the abort always reports two turns.
Every capture in #153 and #164 reads *"Ran for 2 turns"* for that reason, not by chance.

---

## 2. Why it live-locks, and why nothing caught it

The bot re-issues explore; the engine aborts it identically; nothing changes. #164's Shadowblade
burned **21,368 game turns over two grids with zero hand-backs**.

Every existing guard is blind to it:

- `game.turn` races, so **#13's liveness invariant is satisfied continuously** — it was the
  *fastest* run in the sweep by turn rate.
- There are no hand-backs, so **#140's stop-keyed loop endings** never fire.
- No damage is taken, so every survival branch is quiet.

**#145's IDLE detector caught it**, because it measures distinct grids rather than stops. That is
the only signal that needs neither.

An immovable hostile is why it never *ends*, not why it starts. Anything visible from part of a
run path and dark at the stopping grid produces the same abort; something that moves either comes
into the light or leaves the line, and the run eventually succeeds.

---

## 3. The frame-rate corollary

**The size of the disagreement is a function of how few frames get drawn.** In interactive play
the map is drawn continuously, `clean_fov` is almost always armed, and the accumulation is one
step deep. Under the harness, #164's run went at **260 turns/sec against a roster median of 96**,
so far more steps fit between drawn frames.

Two consequences, and both matter for reading measurements:

- It explains why this dominates sweeps and is rare in play.
- **A rate for this failure measured from a sweep overstates what a player sees.** #101 and #123
  should not read the sweep frequency as a product frequency for this class of stall.

A related prediction, not yet tested: a **poor light radius** should make a character more prone
to it, since a larger `lite` marks more grids unconditionally and leaves less for the accumulated
view to add. Nothing records the player's `lite` today, so the corpus cannot answer it.

---

## 4. What the bot does about it

### 4.1 Why three of the four obvious options are wrong

#153 listed four. The mechanism rules out three on correctness rather than cost:

| Option | Verdict |
|---|---|
| Believe the engine | **No.** Its set is path-accumulated, so this means targeting what the character cannot see from where it stands — the line **D-18** and #171 police |
| Widen `spotHostiles` to match | **No.** Same defect, and it puts accumulated visibility into every scoring decision the bot makes |
| Make the creature fightable | **No.** It is not visible from the stopping grid, and it fixes one creature |
| Remember and move on | **Yes**, and with a sharper trigger than "N attempts without progress" |

### 4.2 The guard

`src/data/explorestall.lua`, pure and busted-pinned. It counts **the disagreement itself** — the
engine's view held a hostile, the bot's does not — and never *why*. That is deliberate: lighting,
terrain, or whatever refines §1 next is counted the same way.

- **`LIMIT = 3`, consecutive.** One disagreement is a hostile that genuinely left view between the
  abort and the recompute, and abandoning a level for that would cost real exploring. Three in a
  row is frozen geometry. Any abort the two views agree about resets it, which is what stops a
  *moving* hostile ever reaching the limit.
- **No reset beyond that**, for #140's reason: a restart must not hand the pair a fresh budget.
- **Level-scoped**, not activation-scoped, for the same reason.

Past the limit the branch walks to a level change instead of exploring — the character is unhurt
and the level is genuinely unfinished, so a way off it is progress, and it is the route #137's
vault case already takes. With no exit known it hands back, which is the honest end of a
situation that was previously silent.

### 4.3 The measurement, and where it has to happen

`noteRunStop` wraps `runStopped` and reads the engine's own exported `spotHostiles` **either side
of the original call** — wide before, narrow after. That is the only place both sets exist, since
`runStopped`'s own body is what cleans the map.

It is the addon's **second** superload, and the surface is guarded in two places that must be
changed together — `spec/surface_spec.lua` reads the source, `tools/scenario-hooks.ps1` inspects
the class table the engine loaded. The justification is `api-surface-1.7.6.md`'s rule: no hook
exists (the only `triggerHook` in `mod/class/Player.lua` is
`Player:onEnterLevel:generateEscort`), so keep the wrapper, say why, and make its body one
delegating line.

**It is gated on `bot.active`**, so it is inert while a human plays: the guard exists to stop the
*bot* re-issuing its own explore. That keeps the cost of the second wrapper at one boolean for
anyone not using the bot.

Measured rather than parsed out of the stop reason, which would work today and break on a
translated game — the reason is built with `tformat` and its `" - offscreen"` suffix is itself
translatable.

---

## 5. What the scenario measures, and what it does not

`tools/scenario-explore-stall.ps1`. `runMoved`'s whole body is `playerFOV()`, so moving the
character and calling `playerFOV()` without arming the flag **is** what a run step does — the
probe is the mechanism, not an imitation of it, and needs no frame starvation.

Measured, all passing:

```
large brown snake at 62,27      sight 10, light radius 3
standing at 63,31 -- 4 away, in line of sight, unlit
    clean view       -> spotHostiles reports 0
    accumulated      -> reports the snake
    after runStopped -> 0 again
```

then the count, the limit in two further cycles, and the reset on an agreeing abort.

**The darkness is staged, and has to be.** Searching the fixture's own zone found **50 of 80
candidate grids in line of sight of a hostile and not one of them dark** — that zone cannot
produce this failure at all. The probe darkens one grid and restores it, asserting it was lit
first so an already-dark level cannot let it pass on a no-op.

Not measured, and not claimed:

- The end-to-end run #164 asks for: drive the bot and assert the explored fraction rises. It
  wants a geometry that survives the hostile's own AI, and is a separate scenario.
- Whether the guard's limit of 3 is right in the wild. It is reasoned from the 35%-idle figure
  and the frozen-geometry argument, not tuned against a sweep.
- The light-radius prediction in §3.

### Three wrong turns, kept because they are the trap

Each would have produced a **green scenario that tested nothing**, and none was catchable without
running it:

1. The far grid was chosen as the furthest walkable grid from the hostile — 67 tiles.
   `spotHostiles` walks `calc_circle` at *sight* radius from the character, so it never visited
   the hostile's grid and `seens` was irrelevant. It reported 0 for the right arithmetic and the
   wrong reason.
2. Candidates were then sorted furthest-first, assuming distant meant dark. 28 of 60 were blind
   when clean — all blind from **terrain**, not darkness, and no amount of accumulating helps a
   walk terrain has already blocked.
3. The `bot.active` gate, added last, would have silently disabled the whole measurement.

The probe now uses the engine's own discriminator rather than a proxy for it: in line of sight is
`infovs`, lit is `seens`, and the situation needs the first without the second.

---

## 6. Where the pieces are

| Piece | File |
|---|---|
| The count, the limit, the reset | `src/data/explorestall.lua` (pure, busted-pinned) |
| The measurement | `src/superload/mod/class/Player.lua`, `noteRunStop` |
| The decision | same file, `seekExploreStall`, and the `STATE_EXPLORE` branch |
| Read-only accessor for probes | `bot.exploreStalled()` |
| Unit coverage | `spec/explorestall_spec.lua` |
| Superload-surface guards | `spec/surface_spec.lua` **and** `tools/scenario-hooks.ps1` |
| Behaviour coverage | `tools/scenario-explore-stall.ps1` |
