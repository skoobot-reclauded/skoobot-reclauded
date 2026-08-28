# Escort automation

How the bot behaves while an escort quest is live, and why. Issue **#93**.

Everything in the first section was read out of ToME 1.7.6's own source rather than inferred from
play, because the obvious mental model of an escort quest turns out to be wrong in the one way
that decides the whole design.

---

## 1. What the engine actually does

### 1.1 The escortee walks itself to the portal

This is the load-bearing fact. **The escortee does not follow the player.** Its AI is
`escort_quest` (`mod/ai/escort.lua:24`), and on a turn with nothing hostile in view it runs
`move_escort` (`:62`), which is an A\* straight at the portal:

```lua
newAI("move_escort", function(self)
    if self.escort_target then
        -- Randomly stop to give time to the player
        if rng.percent(35) then self:useEnergy() return true end
        local tx, ty = self.escort_target.x, self.escort_target.y
        ...
```

The 35% idle is the only thing that keeps it near the player at all — it is a handicap, not a
following behaviour. With a hostile within 10 grids that it can see, and **no** line of sight to
the portal, it runs `flee_dmap` and emotes *"Help!"*; otherwise it keeps walking.

So the escort is not "lead the NPC to safety". It is **"keep up with something that is already
walking into danger, and kill what attacks it."** A design that has the bot walk to the portal and
expect the escortee to trail behind would be modelling a game that does not exist.

### 1.2 Everything the bot needs is already on the actor

`data/quests/escort-duty.lua`'s `on_grant` sets all of this before the actor is placed:

| Field | Set at | What it is |
|---|---|---|
| `escort_quest = true` | `:143` | the marker that identifies the escortee |
| `quest_id` | `:141` | the quest to read status from |
| `reward_type` | `:142` | the giver key (`warrior`, `divination`, …) the reward table is keyed on |
| `faction` = the player's | `:139` | so it is never a hostile, and `spotHostiles` never sees it |
| `summoner` = the player | `:140` | |
| `escort_target = {x, y}` | `:195` | **the portal's coordinates, on the NPC** |
| `remove_from_party_on_death` | `:145` | it is a party member |

The portal itself is a cloned terrain grid carrying `escort_portal = true`, `always_remember` and
`notice` (`:180–186`). The engine's own auto-explore already treats `escort_portal` as a thing to
notice (`mod/class/Player.lua:1262`).

So the bot needs no tracking of its own: the destination, the identity and the quest are all
readable at any moment.

### 1.3 How it ends

- **Success**: the escortee steps on the portal. The grid's `on_move` (`:183`) sets the quest DONE
  and invokes chat `escort-quest` — the reward chat.
- **Failure**: the escortee dies. `on_die` (`:147`) sets the quest FAILED and removes it. If the
  *player* was the killer, `registerEscorts("betrayed")` and a different achievement.
- **Start**: chat `escort-quest-start` on grant.

### 1.4 The reward chat, in detail

`data/chats/escort-quest.lua` builds its answers from `EscortRewards:rewardChatAnwsers`
(`mod/class/EscortRewards.lua:489-587`), which emits one answer per available reward with a
generated label (amounts are static: +5 stats, +12 saves, +1 talent level, mastery 1.0):

```
[Improve Strength by +5]
[Improve physical save by +12]
[Learn talent Stunning Blow (+1 level(s))]
[Allow training of talent category Technique / Conditioning (at mastery 1.00)]
```

Note the last one: the label renders capitalized display names, never the type string
`technique/conditioning` — the one row that looks like it carries a stable id is the one that
does not. Talent rows vanish at max raw level, and the category rows — present on 7 of 8
kinds — vanish for a character who carries the category even locked. Only the stat rows have
a deterministic emission order; saves, talents and categories iterate `pairs`, so **nothing
may match by position** — labels are generated strings, and the stable keys are the
escortee's `reward_type` plus the row's own id in the plan's vocabulary (stat short name,
save key `mental|spell|phys`, talent id, type string — `design-build-plan.md` §3.2).

Each answer's `action` calls `game.party:reward(...)`, which opens a **second dialog** to
choose the recipient only when more than one eligible full-control party member exists
(`mod/class/Party.lua:471-473`) — for a solo character the reward applies at once, one dialog;
an Alchemist's golem makes it two.

---

## 2. What the bot does today

Nothing about escorts, specifically — and one part of that is already right.

**The hand-back at escort chats already happens.** The act loop returns
`stop(notice.HANDED_BACK, "a dialog is open: " .. top.title)` for every dialog that is not a
configured-ignorable lore popup (`src/superload/mod/class/Player.lua:1614`). #93 asks for that as
"the one change worth making straight away"; it needs no change, only a reason the player can act
on, which §3.4 adds.

What is wrong is everything else: auto-explore wanders off in whatever direction has unseen tiles,
the escortee walks the other way toward its portal, and the first thing that attacks it does so
out of the player's sight. The first long soak (#61) answered an escort's chat with its first
option because the rig had no idea what it was answering.

---

## 3. The design

### 3.1 A new state, modelled on SEEK

`SAI_STATE_ESCORT` sits beside `STATE_SEEK` (#78) and is built the same way: a walking objective
that **threat always outranks**. SEEK is the precedent for every structural choice here — the
score is re-read on each step rather than trusted from the step that started the walk, anything
but a `FIGHT` posture ends the walk, and a step limit stops it becoming a spin.

The one difference is what it walks toward. SEEK walks to a fixed grid. ESCORT walks toward
*an actor that is itself moving*, so its target is recomputed every step and the arrival test is a
band rather than a grid.

### 3.2 The three things it does, in order

1. **Threat first.** Hostiles in view → `STATE_FIGHT`, exactly as EXPLORE does. No special case:
   the escortee's safety is served by the player killing things, and the fight branch already
   knows how to do that.
2. **Guard.** With no hostile in the player's own view but one in view *of the escortee*, close on
   the escortee. This is the case the player-centric `spotHostiles` misses entirely and the reason
   the escortee dies off-screen.
3. **Keep up.** Otherwise, if the escortee is farther away than the follow band, step toward it;
   if it is inside the band, hold position and let it walk.

**Auto-explore is not called at all while an escort is live.** That is #93's step 1, and it falls
out of the state rather than needing a guard of its own: the ESCORT branch never reaches
`SAI_beginExplore`.

### 3.3 The follow band

Two numbers, both in the pure module so a spec can pin them:

- `FOLLOW_NEAR = 2` — inside this, hold. Standing on top of the escortee blocks the grid it wants
  to walk into and is how a bot deadlocks an A\*.
- `FOLLOW_FAR = 4` — beyond this, step toward it. Chosen to sit inside the escortee's own
  10-grid help radius, so the bot is in range of whatever it is fleeing from before it flees.

Between the two, hold. A band rather than a single distance, because a single distance oscillates
against a target that moves every turn.

### 3.4 What the player is told

An escort changes what the bot does, so the player is told once and can turn it off:

- A condition entry, **`ESCORT_ACTIVE`**, default **WARN**: *"escorting <name> — exploring is off
  until the escort ends"*. WARN means it says so once per escort and then gets on with it; a
  player who sets it to STOP gets the bot back at every turn of an escort; IGNORE turns the whole
  behaviour off and the bot explores as if the escort were not there.
- The escort chats keep today's hand-back, with the reason naming what it is: the start chat and
  the reward chat are the player's to answer, and §4 is why that is not being automated yet.

### 3.5 What is deliberately not built

**Answering the reward chat.** #93's step 3 wants per-escort-type reward preferences. Since
the 2026-08-26 split (recorded on #88), the *ordering* half lives in the build plan
(`design-build-plan.md` §3.2): per `reward_type` — the actual table keys `warrior`,
`divination`, `survival`, `alchemy`, `sun_paladin`, `defiler`, `temporal`, `exotic` — an
ordered preference over rows of kind `stat` / `save` / `talent` / `talent_type`, both the
normal and antimagic variants, ids only. `decline` and `betray` are **not** part of that
value: they are this issue's escort policy, wanting their own guard. What stays here is
decline, betray and its guard, answering the chat at all, the
recipient dialog, and matching the plan's ids to the generated labels. Three things argue for
leaving the chat half until the mechanism above has been played with:

1. Answering means matching **generated label strings**, not stable ids, and then handling the
   second `game.party:reward` dialog. That is a fragile pair to build blind.
2. `betray` means the bot killing a party member on the player's behalf. That is the same class of
   risk as #118's *"a build that lets people mistakenly kill their character on rails"*, and it
   wants the same deliberate guard rather than being folded into a first pass.
3. It is the half of #93 that has no effect on whether the escortee **survives**, which is what
   makes escorts fail today.

**Telling the escortee to wait.** It is a chat option on the escortee, so driving it means the bot
answering a chat — the thing §3.4 has just decided the player owns. It waits for the same
increment.

---

## 4. What the scenario measured, and what it did not

`tools/scenario-escort.ps1` grants a real escort quest with the engine's own
`Player:grantQuest("escort-duty")` and drives the branch on the fixture. Measured, all passing:

- the quest places an escortee carrying `escort_quest`, a quest id and an `escort_target`, and
  the player's reaction to it is friendly (`100`) — so §1.2 holds as written;
- at **WARN** the first decision hands back naming the escortee and saying exploring is off;
- after that acknowledgement the state is `SAI_STATE_ESCORT` and `player.running` is `nil` —
  auto-explore is genuinely never started, which is §3.2's step 1;
- an escortee 6 grids away is closed on: the player moves and the gap goes 6 → 5;
- an escortee adjacent is **waited** for: the player does not move, one action is counted, and
  the turn's energy is spent (1000 → 0), so #13's progress invariant sees a real action;
- **IGNORE** leaves the bot in `SAI_STATE_EXPLORE` with auto-explore running;
- with the escortee removed the bot returns to exploring by itself.

Still not measured, and not claimed:

- Whether `FOLLOW_NEAR = 2` is enough to keep the bot out of the escortee's A\* path in a
  corridor. A corridor is exactly one grid wide and the band may need to be direction-aware.
  The scenario places the escortee on open ground.
- Whether the escortee's 35% idle is frequent enough that a bot holding inside the band stays in
  its help radius over a long walk, or whether it falls behind on average. That needs a soak, not
  a scenario.
- What happens when the escortee's path and the player's are separated by a door the bot's
  `needsConsent` refuses (#64). The escortee will walk through; the bot will not follow, and the
  branch hands back with "no way through to \<name\>" rather than looping — which is the right
  shape but is reasoned, not observed.
- The `threatened` path. `escortThreatened` is exercised on every step (it is an argument to
  `plan`), but no probe has yet put a hostile beside the escortee and out of the player's view,
  because the scenario pacifies the level to reach the branch at all. That is the next probe to
  write, and it needs a hostile that is spawned rather than pacified.

---

## 5. Where the pieces are

| Piece | File |
|---|---|
| Detection, the band, the next step | `src/data/escort.lua` (pure, busted-pinned) |
| The state and its branch | `src/superload/mod/class/Player.lua` |
| The player's switch | `src/data/conditions.lua`, `ESCORT_ACTIVE` |
| Unit coverage | `spec/escort_spec.lua` |
| Behaviour coverage | `tools/scenario-escort.ps1` |
