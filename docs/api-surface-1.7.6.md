# The 1.7.6 API surface SkooBot v1 sits on

**Status:** complete · **Task:** T-001 · **Date:** 2026-08-21

**Method.** Every engine and module symbol SkooBot 0.0.12 touches was checked against the
extracted ToME 1.7.6 source: what v1's code *assumes* (signature, return domain, field name,
semantics) versus what 1.7.6 *provides*, with every claim cited as file:line. No 1.6.7 tree
exists on this machine and none was fetched, so this is a **surface check against the port
target, not a textual diff between engine versions** — a handful of findings are "v1 was
always wrong" rather than "the engine moved", and for porting purposes the distinction does
not matter. The empirical load baseline is **T-003** (v1 loads and runs on 1.7.2, which
covers the C-side loader mechanics that cannot be read from Lua). Every high-risk finding
was re-verified by an independent adversarial pass; where that pass corrected a status, the
corrected value is what appears below. Bugs already written up in
[v1-latent-bugs.md](v1-latent-bugs.md) and [salvage-mishander.md](salvage-mishander.md) are
cross-referenced, not re-reported — **except where this audit shows the documented fix is
itself wrong**, which happened three times (Remediation items 4 and 5).

**Path shorthand.** `E/` = T-Engine `engine/` tree · `T/` = ToME module (`mod/`, `data/`) ·
v1 files (`reference/skoobot-upstream`): `P` = `superload/mod/class/Player.lua`, `A` =
`superload/mod/class/Actor.lua`, `H` = `hooks/load.lua`, `S` = `data/settings.lua`, `K` =
`overload/data/keybinds/toggle-skoobot.lua`, `BTD`/`CAD`/`POD`/`SM` = the four dialogs under
`overload/mod/dialogs/`.

**Status legend.** **ok** = provided exactly as assumed · **ok†** = API as assumed, but v1's
*use* of it is broken (latent v1 bug, not an API change) · **changed** = 1.7.6 does not
provide what v1 assumes · **missing** = the symbol does not exist at all · **uncertain** =
not provable from this tree (C-side); mitigation given.

---

## The superload surface (evidence base for T-021)

v1 superloads exactly two class files, `mod.class.Player` and `mod.class.Actor`, via
`local _M = loadPrevious(...)` (P:34, A:30). What it actually does to them:

- **Replaces (wraps, previous kept):** three methods only.
  `Player:act` (P:872–887, wraps `old_act`), `Player:postUseTalent` (P:506–511 — the
  original resolves through inheritance to `T/mod/class/Actor.lua:6328`; Player defines
  none of its own), and `Actor:tooltip` (A:76–93, chains to `T/mod/class/Actor.lua:2008`).
- **Adds methods to the class table:** `checkStop`, `tryStop`, `getStopConditionList`,
  `getStopCondition`, `setStopCondition`, `pruneAutoTalents`, `getCombatTalents`,
  `getSustainableTalents`, `getSustainTalents`, `getRecoveryTalents`, `scheduleAction`,
  `playerActions`, `skoobot_start`, `skoobot_query`, `skoobot_runonce` (Player);
  `evaluatePowerLevel`, `evaluatePowerScores` (Actor).
- **Adds class-level mutable state:** `_M.skoobot` (P:42–47), `_M.ai_active` (P:93),
  `_M.skoobot_aiNearestHostileDistance` (P:376) — shared by every Player instance, never
  saved (E/class.lua:456–457 strips the metatable before serialising).
- **Adds instance fields that ride in the save file:** `skoobotstopwarn` (P:110),
  `skoobotstopconditions` (P:139–155), `skoobotautotalents` (BTD:138),
  `skoobotactiontimer` (P:834) — none is in a `_no_save_fields` filter, so all four persist.
- **Leaks bare globals:** `aiStop` (P:92), `checkForAdditionalAction` (P:267),
  `getUnspentTotal` (P:273), `skoobot_act` (P:573), `reduce` (A:2), `recSum` (A:15).

Everything else in the tables below is **merely called** — plain engine/module API reachable
from hooks, dialogs, and keybind handlers with no superload at all. The minimum surface for
the port is therefore the three wrappers, and even those shrink: the `act` wrapper exists
only to drive the bot's re-entrant loop, which Remediation 1 removes in favour of the engine
tick; `tooltip` is optional UI sugar. A collision sweep of every v1-defined name over both
1.7.6 trees found **zero collisions** (see the last table).

---

## mod.class.Player

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `useEnergy()` | P:203 | T/mod/class/Player.lua:433–439, E/Actor.lua:479–483 | ok | No-arg spends `game.energy_to_act`; Player's version also unpauses and fires `callbackOnActEnd` when energy drops below the threshold — this is what returns the turn to the engine. |
| `move(x, y)` | P:206–213 via :646, :759 | T/mod/class/Player.lua:312–366; T/mod/class/Actor.lua:1388–1441; E/Actor.lua:228–267 | **changed** | Return means "a move was **attempted**", not "position changed" (E/Actor.lua:228). Wall bump / bump-attack → `true` with energy intact; asleep, `never_move`, no energy, store tile → `false`; bad coords / no level → `nil`. v1's falsy tests at P:649/:760 misread every bump as success. Remediation 2. |
| `act()` | P:222; wrapper P:872–887 | T/mod/class/Player.lua:383–431 | **changed** | Returns **nothing on every path** (sole `return` at :384; falls off at :431). v1's `ret` is always nil. Every call re-runs the whole turn-start block of `T/Actor.lua:679–820` (turn_procs wipe, sustain break, automaticTalents, callbacks) without a game turn passing; v1 calls it re-entrantly from inside its own act wrapper — this is the pinned-freeze mechanism. Remediation 1. |
| `autoExplore()` | P:221 | T/mod/class/interface/PlayerExplore.lua:1820–2544 | ok | `true` = target found, but the **first step is already taken** (:2538) and a hidden Running popup is registered (:2514, :2534–2535) before it returns; `true` does not guarantee `self.running` is still set (a pinned first step ran `runStop`). All four `return false` exits are "explore ended here", three of them normal progress. |
| `restInit(nil,nil,nil,fn)` | P:234 | E/interface/PlayerRest.lua:28–53, :109–112 | ok | Nil what/past safe (:29–30); on_end receives `(cnt, rest_turns)` (:109). But on_end fires on **every** stop — including *synchronously inside restInit* on refusal (:49–50) and on damage/effect/death/suffocation/chat/teleport stops (T/Player.lua:786/810/827/839/847; T/Actor.lua:1690). One energy is spent on acceptance (:52). Remediation 9. |
| `resting` / `running` | P:844, :875 | E/interface/PlayerRest.lua:31/:111; E/interface/PlayerRun.lua:42–:381; T/PlayerExplore.lua:2511 | ok | Table while active, nil otherwise, as v1 assumes. |
| `setTarget(actor)` | P:739 | T/mod/class/Player.lua:910–913 → E/interface/GameTargeting.lua:326–332 | ok | Fills the on-screen cursor only; it does **not** pre-empt the targeting-coroutine yield. Aiming needs `force_target` (see `useTalent`). |
| `attackOrMoveDir(dir)` | P:755, :762 (commented out) | T/mod/class/Player.lua:1710–1717 | ok | Returns nothing. Dead code in v1; if revived, use `moveDir`/`move` and compare position. |
| spotHostiles loop (private copy) | P:277–326 | T/mod/class/Player.lua:915–956 | ok† | 1.7.6's own copy is line-identical except two hardenings v1 lacks: `if not self.x or not game.level then` (:917) and `actor:getName()` (:923). Adopt both; or call the class-exported `Player.spotHostiles(self, false)` (:956). |
| projectile fields `proj.src`/`start_x`/`project.def.x,y`/`homing.target` | P:300–326 (dead: `actors_only` guard :300, both callers pass true) | E/Projectile.lua:290–350; T/mod/class/Projectile.lua:75, :92 | ok | All fields still constructed as v1 reads them. Dead in v1; if projectile awareness is added, use the exported spotHostiles instead of a private loop. |

## mod.class.Actor

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `preUseTalent(t, true, true)` | P:477, :484 | T/mod/class/Actor.lua:5742–6013 (base E/interface/ActorTalents.lua:401) | ok | 4th param `ignore_ressources` added — 3-arg call fine, **never pass true there** (dry run would report unaffordable talents as usable). `fake` skips only the energy gate (:5805) and random-failure rolls; hard gates (forbid, feared, silence, sleep-without-lucid-dreamer :5800, on_pre_use :6002) and resource sufficiency (:5836) still apply — exactly what v1 wants. Same idiom as the engine's own `automaticTalents` (E/ActorTalents.lua:1128). |
| `postUseTalent(t, ret, silent)` — **wrapped** | P:506–511 | T/mod/class/Actor.lua:6328–6595 | ok | Returns **nil** (not false) on failure (:6329) — keep v1's truthiness test, never tighten to `== false`. Fires for sustain **deactivation** too (E/ActorTalents.lua:282); failure bookkeeping must ignore that path (check `self.deactivating_sustain_talent`). |
| status fields `confused` `dazed` `stunned` `frozen` `sleep` `lucid_dreamer` `undead` | P:240, :245, :250, :255, :260, :642 | see [Value-domain notes](#value-domain-notes-the-status-attributes) | **changed** / ok† mix | Every `== 1` comparison is wrong (temp values are additive counters, E/Entity.lua:925). Three are outright changed: `confused` is a 0–50 **percentage**, `frozen` has two unrelated sources, `lucid_dreamer` is a 5–25+ power. `undead` no longer decides breathing. Remediation 4–5. |
| `unused_stats/-talents/-generics/-talents_types/-prodigies` | P:274 | T/mod/class/Actor.lua:191–195 | ok | All five numeric on every actor at init. |
| `sight` | P:282, :302, :334 | T/mod/class/Actor.lua:199 | ok | Same `self.sight or 10` idiom as 1.7.6's own spotHostiles (T/Player.lua:920). |
| `reactionToward(actor)` | P:284 | T/mod/class/Actor.lua:1762–1781 | ok | Bounded [-100, 100]; `< 0` test safe; identical to T/Player.lua:922. |
| `canSee(actor)` | P:284 | T/mod/class/Actor.lua:7491–7507 | ok | Returns (bool, chance); one-arg form fine. |
| `combatDamage(w, nil, ammo)` | A:53, :55 | T/mod/class/interface/Combat.lua:1687–1704 | ok | Canonical call shape is Archery.lua:316. v1 quirk: passes the **unarmed** table as `weapon`, so training/physpower are unarmed's; pass the launcher's `o[1].combat` in the port. |
| `actor.combat` (unarmed table) | A:53, :55 | T/mod/class/Actor.lua:299–311 | ok | Guaranteed at init. |
| `o[1].combat.dam` | A:55 | T/mod/class/interface/Combat.lua:1708–1710 | ok | Live field. v1 quirk: melee uses raw `dam`, ranged uses rescaled `combatDamage()` — two different scales. |
| `o.archery` / `ammo.archery_ammo` / `ammo.combat` | A:49–53 | T/mod/class/interface/Archery.lua:757–766, :831; T/mod/class/Actor.lua:1964–1965 | ok | v1's expression is copied verbatim from T/Actor.lua:1965. |
| `combat_dam/-physcrit/-physspeed/-spellpower/-spellcrit/-spellspeed/-mindpower/-mindcrit/-mindspeed/-def/-armor` | A:62–64 | T/mod/class/Actor.lua:162–179 | ok | All eleven unconditionally set in init, names unchanged, plain numbers. |
| `combat_generic_crit` | A:62–64 | T/mod/class/interface/Combat.lua:1454, :1888, :1901 | ok† | Engine **adds** it to the type crit; v1's `or`-chain substitutes it for the whole crit chance when non-nil. Add, don't substitute. |
| `combat_critical_power` | A:62–64 | T/mod/class/interface/Combat.lua:1998–1999, :2027–2028, :2075–2076 | ok | Percent units, guarded reads; v1's `or 0` and `/100` match. |
| `global_speed` | A:62–64 | T/mod/class/Actor.lua:168, :4111–4116 | ok† | Present on every actor. v1 defect (not API): scores **enemies** with the *player's* speed. Use `self.global_speed`. |
| `tooltip(x, y, seen_by)` — **wrapped** | A:76–93 | T/mod/class/Actor.lua:2008–2294; T/mod/class/Player.lua:441–446 | ok | Player delegates by explicit class reference, so the Actor wrap reaches the player. Returns nil when unseen (v1 guards it); `tstring:add` varargs unchanged (E/utils.lua:1566–1571). |
| `getTalentFullDescription(t)` | BTD:150 | T/mod/class/Actor.lua:6717–6859 | ok | One-arg call fine; returns a tstring; nil-safe (:6718). |
| `attr("can_offshoot")` / `attr("psi_focus_combat")` | A:49–50 | T/mod/class/Actor.lua:1965; T/Archery.lua:771, :784 | ok† | Both fine as API (`can_offshoot` has **no setter** in base 1.7.6 — DLC unverified). v1 bug: `type ~= "offhand"` references the Lua builtin `type` (no such parameter in A), so both clauses are vacuously true and neither attr call ever runs. Harmless; delete the clauses or call `getCombatStats` (T/Actor.lua:1951). luacheck will **not** flag this — needs a review note (T-023). |

## engine.Actor / engine.Entity

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `enoughEnergy()` | P:268, :845, :867, :876 | E/Actor.lua:472–475 | ok | Optional `val` param; no-arg takes `game.energy_to_act`. No override anywhere. |
| `attr(prop)` | A:49–50, port-wide | E/Entity.lua:1158–1170 | ok | Returns the value when non-nil and non-zero, else nil. Temp values are **additive** by default (:925) and none of the status flags has a `temporary_values_conf` override — so they are counters, never test `== 1`. |
| `x` / `y` | P:279, :282, :331, :334, :367, :467, :641, :748 | E/Actor.lua:250–251; guard: T/mod/class/Player.lua:917 | ok† | Caveat: `deleteFromMap` no longer clears them (E/Actor.lua:464, commented out) — stale coordinates survive removal. Copy 1.7.6's guard `if not self.x or not game.level then` and re-validate cached enemy records against the map before pathing. |
| `name` / `uid` | P:285, :321, :481 | E/Actor.lua:45; E/Entity.lua:102–104, :164–166 | ok | uid is **not stable across save/load or clone** (E/Entity.lua:186–218). Prefer `getName()` for display (i18n); raw `.name` only for matching. |

## Engine interfaces (ActorTalents, ActorProject, ActorInventory, ActorStats, ActorLife, ActorResource, PlayerHotkeys)

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `useTalent(tid, _a, _b, _c, target)` | P:194 (sites :546, :712, :724, :740) | E/interface/ActorTalents.lua:141–356 | ok† | Signature unchanged; 5th arg is `force_target`, honoured for activated talents only (:156–164). **Return domain is wider than v1 assumes:** `false` = refused-without-acting for *any* reason (cooldown :171/:207, preUse gate, confirm-cancel, falsy action return); `nil` = **pending** — the talent coroutine yielded into interactive targeting (T/Player.lua:906 → E/GameTargeting.lua:312/:321) or a confirm dialog (:328–335), or the non-coroutine fallthrough (:306). v1:712/:724 call with no target → interactive targeting under the bot; v1:546 misreads pending-nil as failure. Remediation 3. |
| `getTalentFromId(tid)` | P:190, :193, :422, :471, :498, :543; BTD:71, :141 | E/interface/ActorTalents.lua:971–974 | ok | nil for unknown ids — guard the immediate `.name` derefs (P:190, :193). |
| `getTalentRange(t)` / `getTalentRadius(t)` | P:474 | E/interface/ActorTalents.lua:1049–1060 | ok | Takes the def **table**; no module override; same range+radius sum as E/ActorAI.lua:408. |
| `isTalentCoolingDown(t)` | P:477, :482, :498 | E/interface/ActorTalents.lua:1042–1046 | ok | Accepts id or table; remaining turns (number) or false. |
| `isTalentActive(tid)` | P:483 | E/interface/ActorTalents.lua:454–456 | ok | Table while active (never false), nil after deactivation — v1's nil test at P:545 is correct. |
| `getTalentRequiresTarget(t)` | P:478 | E/interface/ActorTalents.lua:1074–1077 | ok† | API fine. v1's unparenthesised `a and not b or c` still resolves safely (nil target → `canProject(tg, nil, nil)` → nil, E/ActorProject.lua:287) but parenthesise it in the port. |
| `canProject(tg, tx, ty)` | P:478 | E/interface/ActorProject.lua:286–342 | ok | Minimal `{type="hit"|"bolt", range=n}` is a valid tg (Target:getType fills defaults, E/Target.lua:665–696); same construction as the game's own AI (E/ActorAI.lua:406–408). |
| `sustain_talents[tid]` | P:545 | E/interface/ActorTalents.lua:107, :220, :238, :287 | ok | Always a truthy table while active (:228–229, guarded by postUseTalent), nil otherwise. |
| `talents` / `pairs(talents)` | P:380–386 | E/interface/ActorTalents.lua:102, :604, :661–662 | ok | tid → raw level; key removed at level 0. |
| talent def `.mode` `.no_npc_use` `.no_dumb_use` `.direct_hit` `.name` `.id` | P:475–476, :482 | E/interface/ActorTalents.lua:73–90; consumed by E/ActorAI.lua:385–406 | ok | Mode default "activated", asserted to three values; all flags live in 1.7.6 data. |
| `talent.hide ~= "true"` | BTD:72, :142 | value domain: `true` (41+3), `false` (4), `"always"` (14) in T/data/talents | ok† | The string `"true"` never occurs, so v1's filter never fires — hidden talents always listed (latent v1 bug). Test `not t.hide`. |
| `talent.name:capitalize()` | BTD:73, :84, :88, :92, :146 | E/interface/ActorTalents.lua:88; E/utils.lua:960 | ok | `_t` always yields a string. Optionally `getTalentDisplayName` for UI. |
| `hotkey[i]` | P:391–392 | E/interface/PlayerHotkeys.lua:122–150 | ok | `{"talent", tid}` / `{"inventory", name}`; 12 × (nb_hotkey_pages or 5) slots. v1's `getHotbarTalents` (P:388–396) is never called — delete. |
| `getInven(INVEN_MAINHAND)` / `getInven("QUIVER")` | A:41–42 | E/interface/ActorInventory.lua:92–100; T/mod/load.lua:120, :133 | ok | Both number and string forms supported; nil-safe. |
| `inc_stats` | A:66 | E/interface/ActorStats.lua:58–75 | ok | Dense, zero-filled 1..7 on 1.7.6 (7 stats incl. luck, T/mod/load.lua:183–190) — v1's ipairs reduce sums all of them. |
| `life` / `max_life` | P:600, :720; A:61 | E/interface/ActorLife.lua:30–33, :51, :58 | ok | `die_at` exists (default 0, can go below); prefer `(life - die_at) / (max_life - die_at)` for ratio thresholds. |
| `air` / `max_air` | P:638, :666 | T/data/resources.lua:45; E/interface/ActorResource.lua:61–62, :129–131 | ok† | Same 0–100 default, but **max_air is not constant** (Yeek 200, T/data/birth/races/yeek.lua:162; items 50/20). v1's absolute `air < 50` / `< 75` are wrong on those; the game's own thresholds are ratios (T/Player.lua:470, :837, :1219). Remediation 5. |
| `engine.interface.PlayerRest` (require) | P:31 | E/interface/PlayerRest.lua exists | ok | Local never used — drop; rely on inheritance. |

## engine.Map / core.fov / engine.Astar

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `game.level.map`, `.w`, `.h` | P:282, :302, :334 | E/Map.lua:210–225; E/Zone.lua:58, :1066 | ok | Level map is plain engine.Map — nothing sets a custom `map_class`. |
| `map(x, y, LAYER)` call form | P:283, :303, :335, :641 | E/Map.lua:371, :559–573 | ok | OOB → nil; per-grid tables always exist (:225). |
| layer constants `.TERRAIN`/`.ACTOR`/`.PROJECTILE` (both instance and `engine.Map.` spellings) | P:283, :303, :335, :670 | E/Map.lua:40–53; used both ways by 1.7.6 itself (T/Player.lua:921; T/mod/ai/improved_tactical.lua:851) | ok | v1 never hardcodes the numbers. |
| `map:opaque(x, y)` | P:282, :302, :334 | E/Map.lua:633–637 | ok | Same block callback shape as T/Player.lua:920. |
| `map.seens(x, y)` — dot call | P:284, :304 | E/Map.lua:217, :320–329, :373 | ok | Keep the **dot** form (the seens table is the `t` arg). seen = in-FOV **and** lit; `infovs` is the light-independent table and is not what v1 wants. |
| `map:checkEntity(x, y, TERRAIN, "change_level")` | P:670 | E/Map.lua:797–805 | ok | Returns the property value (numeric delta) or nil; nil-safe on OOB. |
| `map:compassDirection(dx, dy)` | P:208, :211 | E/Map.lua:1505–1519 | ok | nil only at (0,0), unreachable from Astar paths; the string is **locale-dependent** — log/debug use only. |
| `terrain.air_level` (+ `air_condition`) | P:336, :642 | data: T/data/general/grids/water.lua:29/:43/:50/:100–104, basic/lava/void; consumer: T/mod/class/Actor.lua:628–634, :7395–7398 | **changed** | Sign convention holds (negative = hazard) and one **positive** tile exists (+15 bubble, water.lua:104), but the 1.7.6 predicate has more inputs than v1 models: `air_condition` vs the `can_breath` table, `no_breath`, `invulnerable`. Deep water carries **no** air_condition, so water-breathing does not help there. Remediation 5. |
| `core.fov.calc_circle(x, y, w, h, r, block, apply, nil)` | P:282, :302, :334 | C-side; exact 8-arg form live at T/Player.lua:920–925 and 27 sites; callback contract E/interface/ActorFOV.lua:58–62 | ok | Optionally pass `map._fovcache.block_sight` as the 8th arg for plain-opacity blocks. |
| `core.fov.distance(x1, y1, x2, y2)` | P:318, :367, :369, :467 | C-side; E/Astar.lua:46; T/Player.lua:945 (byte-identical to P:318) | ok | An optional 5th arg was added (additive). Chebyshev-compatible on square grids. P:463/:467 `target_dist` is a dead local — drop. |
| bare `abs()` / `MAX_INT` in getPathToAir | P:344, :341 | **no definition anywhere** in E/ or T/ | **missing** | Latent crash, masked only by the dead drowning guard (v1-latent-bugs Bug 1); the moment T-015 fixes the guard, `attempt to call global 'abs'` fires. mishander had to hack both in locally (fork src/superload/mod/class/Player.lua:3–16). Use `math.abs` / `math.huge`. |
| `Astar.new(map, actor)` / `a:calc(sx, sy, tx, ty)` | P:28, :352–353, :747–748 | E/Astar.lua:30–33, :113–192, :90–100 | ok | nil for unreachable, out-of-bounds, start==target, or exhausted open set; path excludes the start tile, `path[1]` is the first step. Passability is **terrain-only** — actors/traps are not obstacles. Both failure branches print to stdout on every call. Remediation 13. |
| `engine.Map` global via `module()` | P:670 (`engine.Map.TERRAIN`) | E/Map.lua:29 | ok | Use the local `Map` at the call site instead; luacheck flags the unused local either way. |

## engine.Game / mod.class.Game

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `game:registerTimer(seconds, fn)` | P:835 | E/Game.lua:217–220; fired :196–208 | ok | One-shot, 30 keyframes = 1 s, keyed by function object; 0 fires next rendered frame. v1's armed-once `skoobotactiontimer` flag (P:833–834, never cleared, **saved**) is a v1 bug — clear it in the callback or drop it. |
| `game.paused` | P:832, :837 | E/GameTurnBased.lua:31; E/GameEnergyBased.lua:133–137; T/mod/class/Game.lua:1603; T/Player.lua:423–424, :435–436 | ok | Same pause/unpause loop mechanics v1's scheduleAction relies on. |
| `game:saveSettings(file, data)` | H:63, :79 | E/Game.lua:519–531; boot reload E/init.lua:90–94 | ok | Write side unchanged; no name prefix required. |
| nested `tome.SkooBot.X = v` load | H:63, :79 | `config.load` is C-side — no Lua definition | **uncertain** | Demonstrated vivification is **one level deep**; every shipped nested writer creates the intermediate table explicitly (T/uiset/Minimalist.lua:423–429; E/UserChat.lua:370). Whether v1's three-level bare assignment loads cannot be proven here. Remediation 7. |
| `game:registerDialog(d)` | H:34, :77; BTD:91, :97, :99, :112, :115, :126 | E/Game.lua:420–429 | ok | New `__refuse_dialog` early-out (:421) — inert for SkooBot. The trailing `1` at BTD:91/:115 lands on registerDialog and is silently discarded — it was meant as GetQuantity's `min` (v1 bug; pass it as the 6th ctor arg). |
| `game:unregisterDialog(d)` | BTD:56; CAD:26; POD:27; SM:22 | E/Game.lua:470–484 | ok | Safe on unregistered dialogs; runs cleanup/unload; restores key/mouse focus. |
| `game.dialogs` stack, `[#].title`, `[#].key.virtuals.EXIT()` | P:583–594 | E/Game.lua:40, :420–423; E/ui/Dialog.lua:369; E/KeyBind.lua:120, :271–273; T/mod/dialogs/LorePopup.lua:37, :98–108, :127 | **changed** | Stack mechanics intact (hash keys don't affect `#`). But the lore title is now built with `tformat` → **localised** — the English `"Lore found:"` match fails on any non-English locale, demoting every lore popup to the generic hard stop; `title` may also be nil (untitled dialogs) and `string.match(nil, …)` raises. The rest popup, hidden explore popup, and talent-confirm popup all sit on this stack. Remediation 6. |
| `game.w` / `game.h` | BTD:17 | E/Game.lua:39, :109 | ok | Same use as T/PartyLore.lua:127. |
| `game.zone.wilderness` | P:792, :807, :822, :849 | T/data/zones/wilderness/zone.lua:32 (sole setter); gated at T/mod/class/Game.lua:1238, :2062, :2664; T/Player.lua:351 | ok | Truthiness test correct. 1.7.6 itself nil-guards `game.zone` in equivalent positions (T/Player.lua:1362, :1367, :1506) — adopt `not game.zone or game.zone.wilderness`. Addon keybinds are not wrapped in `not_wild`, so the explicit checks stay necessary. |
| `game.log(msg)` | P:98, :183, :190, :208, :586, :594; H:11, :17, :23, :28, :33 | installed by uiset (T/uiset/Minimalist.lua:492); E/LogDisplay.lua:122–126; E/I18N.lua:72–93 | ok† | The first argument is a **format string and a translation key**: `tformat` always runs `_t` then `:format(...)`, with no pcall. A bare `%` in concatenated dialog titles (P:586, :594) or talent names (P:190) raises at runtime. Use `game.log("%s", msg)`. Remediation 12. |
| `game:onTickEnd(f)` | BTD:61–63; CAD:29–30; POD:30–31; SM:25–26 | E/Game.lua:342–353 | ok | Optional `name` param added — backward compatible. |

## engine.ui / engine.dialogs / mod.dialogs

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `engine.class`, `module(..., class.inherit(Dialog))` (both require- and global-path forms) | BTD:13; CAD:6; POD:6; SM:8 | E/class.lua:54, :93–97; every stock UI class (E/ui/Dialog.lua:27 etc.) | ok | Lua 5.1 `module()` idiom still universal in 1.7.6. |
| `Dialog.init(self, title, w, h)` | BTD:17; CAD:16; POD:17; SM:12 | E/ui/Dialog.lua:359–445 | ok | First three positionals unchanged. |
| `self.iw` / `self.ih` | BTD:18–29 | E/ui/Dialog.lua:447–457 | ok | Valid immediately after init (resize called at :445). |
| `loadUI` / `setupUI` / `setFocus` / `makeKeyChar` | BTD:38–45, :159–160; CAD:20–23, :45–46; POD:21–24, :46–47; SM:16–19, :78–79 | E/ui/Dialog.lua:537–554, :556–625, :736–742; E/ui/Base.lua:261–273 | ok | All placement keys (left/right/top/hcenter) present; `setupUI(true, true)` grows the 1×1 dialogs; `setupUI()` preserves explicit size. |
| `List.new{width, nb_items, list, fct}` | CAD:18; POD:19; SM:14 | E/ui/List.lua:29–60, :150–156 | ok | v1 items carry no `.fct`, so the dialog-level fct path runs. |
| `ListColumns.new{…}` | BTD:29 | E/ui/ListColumns.lua:29–52, :356–463 | ok | Fixed and percent widths both live. v1 quirks: columns sum to 102% (cosmetic); sorting the Priority column throws on the `priority=""` sentinel row and is swallowed by pcall — give it a numeric sentinel in the port. |
| `Textzone.new{…}` | BTD:21; H:70, :87 | E/ui/Textzone.lua:29–68 | ok | `.h` valid right after new (auto_height); accepts tstrings; `no_color_bleed` is a read-by-nobody vestige. |
| `TextzoneList.new` + `:switchItem(item, text)` | BTD:27, :132 | E/ui/TextzoneList.lua:30–47, :140–142 | ok | 2nd arg **is** the text; tstring or string both fine. |
| `Separator.new{dir="horizontal", size}` + `.w` | BTD:19–20 | E/ui/Separator.lua:27–42 | ok | Naming quirk unchanged ("horizontal" draws the vertical bar). |
| `GetQuantity.new(title, prompt, default, max, fn[, min])` | H:77; BTD:91, :115 | E/dialogs/GetQuantity.lua:30–57 | ok | 5-arg call maps exactly; action receives qty after unregister. Pass `min` as 6th arg in the port (see registerDialog row). |
| GameOptions `self.c_list:drawItem(item)` / `self.c_desc.w/.h` | H:64, :80; :70, :87 | T/mod/dialogs/GameOptions.lua:40, :84–90; E/ui/TreeList.lua:96–111, :305–310 | ok | `c_list` is recreated per tab switch — v1's closures look it up at call time, so they always hit the live widget. |
| lore popup detection | P:584, :591 | T/mod/dialogs/LorePopup.lua:37, :98–108 | **changed** | See game.dialogs row: match by `__CLASSNAME == "mod.dialogs.LorePopup"` (E/class.lua:76 stamps it on every instance), dismiss via the EXIT virtual only (restores `game.tooltip.inhibited`, :98–104 vs :127). Do not detect by `after_learn_cb` presence — nil for ShowLore-spawned popups. |
| `require "mod.dialogs.<X>"` via overload mount | BTD:9–10; SM:5, :32 | E/Module.lua:519–523; T/mod/dialogs/ listing (36 files, none named like v1's) | ok | No shadowing in either direction. The mount at "/" is one shared namespace — namespace the port's dialogs (`mod/dialogs/skoobot/`). |

## KeyBind / hooks / config

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `KeyBind:load("toggle-skoobot")` | H:7 | E/KeyBind.lua:46–61; overload mount E/Module.lua:519–523 | ok | Resolves for directory and .teaa forms; module's own list (T/mod/load.lua:114) doesn't include it, so the explicit load stays required. |
| `defineAction{default, type, group, name}` | K:20–49 | E/KeyBind.lua:33–41; group consumed only by E/dialogs/KeyBinder.lua:222–235 | ok | "actions" is a live group; skoobot entries list under it. |
| sym string `"sym:_F1:false:false:true:false"` | K:21, :28, :35, :42, :49 | E/KeyBind.lua:146–147, :164; E/Key.lua:220–224 | ok | Order is sym:ctrl:shift:alt:meta. No 1.7.6 default uses Alt/Shift + F1–F3 — no collisions (plain F1–F3 and Ctrl+F1–F3 are party binds). |
| `game.key:addBinds{VIRT = fn}` | H:8 | E/KeyBind.lua:278–291; dispatch :228–231 | ok† | Works — but only because UserChat's post-run `bindKeys()` rebuild (E/UserChat.lua:53–55, gated on `allow_userchat`, T/mod/init.lua:66) re-derives the key→virtual table after the hook has added the defs. Call `game.key:bindKeys()` yourself after addBinds (idempotent). Remediation 11. |
| `self.key:addBinds{EXIT = fn}` | BTD:54; CAD:26; POD:27; SM:22 | E/KeyBind.lua:271–291; E/data/keybinds/actions.lua:124–129; E/ui/Dialog.lua:508 | ok | Escape and click-outside both trigger the EXIT virtual. |
| `self.key:addCommands{__TEXTINPUT = fn}` | BTD:47; CAD:25; POD:26; SM:21 | E/KeyCommand.lua:113–184; E/Key.lua:598; gate E/KeyBind.lua:216 | ok | Requires `unicodeInput(true)`, which v1's on_register does. |
| `class:bindHook(name, fn)` | H:6, :42, :54 | E/class.lua:406–434 | ok | fn(self, data) contract unchanged; string-valued fct is a new additive option. |
| hook `ToME:run` | H:6 | T/mod/class/Game.lua:95–96 | ok† | Fires before runReal; game.key is final. Caveat: **chronoRestore** (T/Game.lua:1522–1545) replaces game.key and re-enters via runReal — hook-added binds are silently lost until next boot. Also superload `Game:setupCommands` (T/Game.lua:2047) for the binds. |
| hook `GameOptions:tabs` | H:42 | T/mod/dialogs/GameOptions.lua:48–52 | ok | data.tab(title, fct) unchanged; dialog constructed fresh per open. |
| hook `GameOptions:generateList` | H:54 | T/mod/dialogs/GameOptions.lua:82–90; E/ui/TreeList.lua:108–111, :305–310 | ok | Item shape {zone, name, status=fn, fct=fn} fully honoured. |
| `dofile("/data-skoobot/settings.lua")` | H:39 | mount E/Module.lua:495–502; hooks run at :686–700, after all loadAddon calls (:680–682) | ok | Path derives from `short_name` — if the port ships as a different short_name, **every** `/data-skoobot/` string must change. |
| `config.settings.tome.SkooBot[…]` (6 options) | P:21–23 (checkConfig) | T/mod/settings.lua:24; persistence E/Game.lua:519 + E/init.lua:90–92 | ok | Case-insensitive sweep of both trees for "skoobot": zero hits — the keys are addon-owned, nothing collides or validates them. |
| `config.settings.tome` availability at hook time | S:7–8 | created by T/mod/init.lua:81 via E/Module.lua:976 (font bootstrap), **before** loadAddons at :1041 | ok† | Guaranteed on 1.7.6 — but as an incidental side effect of the font system (the engine's own code still guards it, E/Module.lua:1043–1044). Open the defaults file with `config.settings.tome = config.settings.tome or {}`. |
| top-level `config.settings.SkooBot` run-once guard | S:2–5 | no collision; never persisted | ok | Per-boot flag, as v1 assumed. |

## engine.util / core misc / load mechanism

| symbol | v1 use | 1.7.6 | status | note |
|---|---|---|---|---|
| `util.coordToDir(dx, dy)` | P:177 | E/utils.lua:2306–2307, :2037–2053; square mode forced by E/Module.lua:958, :961 | ok† | 2-arg call fine on stock (square) ToME; returns nil under a hex addon. v1's `dx/dx` normalisation is sign-lossy (wrong dir for up/left) — but all consumers are commented out. If beeline moves are revived, use `util.getDir` (E/utils.lua:2334–2338) instead. |
| `util.getval(v, ...)` | P:475 | E/utils.lua:2440–2445 | ok | The exact `t.direct_hit` idiom lives on at E/ai/talented.lua:49. |
| `string.toTString(str)` | H:71, :88 | E/utils.lua:1628–1656 | ok | Memo cache added; both paths return a clone. All v1 markup (#COLOR#, #{bold}#) still parses. |
| `table.get(t, 1)` | A:42 | E/utils.lua:670–677 | ok | nil-safe descent; same idiom as T/Actor.lua:1964. |
| `core.key.modState("ctrl")` | A:80 | C-side; 30+ sites (E/DebugConsole.lua:222 etc.) | ok | Coexists with two stock Ctrl behaviours (cheat FOV dump, remembered-tile tooltip suppression) — no conflict. |
| `print(...)` | 28 sites; P:843 traceback | no global rebinding in E/ or T/ | ok | Route bot output through one levelled logger in the port; note E/Astar.lua:129/:151 also spams stdout. |
| `loadPrevious(...)` → previous class table | P:34; A:30 | Lua side only **mounts** superloads (E/Module.lua:510–517); the injecting loader is C-side | **uncertain** | Alive in 1.7.x (v1 loads on 1.7.2, T-003) but its return contract is unverifiable from source. Keep the call verbatim and first; declare as read_global in .luacheckrc; harness-assert `_M.__CLASSNAME` at load. Remediation 8. |
| dead requires `Dialog`/`Map`/`PlayerRest`/`PlayerExplore` | P:29–32 | files all exist | ok | All four locals unused — delete; luacheck flags them. |

## v1-defined names — collision sweep

Every name v1 introduces was swept over both full 1.7.6 trees (engine + module, definitions
and assignments). **Result: zero collisions.** No `_G` strict-mode metatable exists, so the
leaked globals are silent, not fatal.

| kind | names | v1 def | note |
|---|---|---|---|
| class-level state | `skoobot`, `ai_active`, `skoobot_aiNearestHostileDistance` | P:42–47, :93, :376 | Shared across all Player instances; never saved. `ai_active` is a plausible future engine name — namespace it in the port. |
| saved instance fields | `skoobotstopwarn`, `skoobotstopconditions`, `skoobotautotalents`, `skoobotactiontimer` | P:110, :139–155; BTD:138; P:834 | All four persist in the character save (no `_no_save_fields` entry). `skoobotstopconditions` has no version migration — a new stop code added later nil-indexes on old saves (P:105, :131). |
| added methods | checkStop, tryStop, getStopConditionList, getStopCondition, setStopCondition, pruneAutoTalents, getCombatTalents, getSustainableTalents, getSustainTalents, getRecoveryTalents, scheduleAction, playerActions, skoobot_start, skoobot_query, skoobot_runonce, evaluatePowerLevel, evaluatePowerScores | P/A various | Several ignore `self` and read `game.player` directly (P:138, :417, :831, :842); the keybind handlers call the colon-declared ones without self (H:12, :24, :29) — works only by accident. Give them real `self` in the port. |
| leaked globals | aiStop, checkForAdditionalAction, getUnspentTotal, skoobot_act, reduce, recSum | P:92, :267, :273, :573; A:2, :15 | Make all six `local function`; skoobot_act/checkForAdditionalAction are mutually recursive — forward-declare. Enforce via luacheck `allow_defined_top = false` (T-023). |
| overload files | BotTalentDialog, CustomActionDialog, PickOneDialog, SkoobotMenu; `/data/keybinds/toggle-skoobot.lua` | overload/ | Nothing in T/mod/dialogs/ or the keybind data shares these names. |
| config keys | `config.settings.SkooBot`, `config.settings.tome.SkooBot.*` | S:2–15 | Zero "skoobot" hits in either tree. |

---

## Remediation for the port

Ordered by how much of the port's design each one touches. Items 1–6 are the changed/missing
findings; 7–8 the uncertains; 9–13 concrete corrections the surface check surfaced along the way.

1. **`Player:act()` — never call it, never trust it** *(changed)*. It returns nothing on any
   path (T/Player.lua:383–431); v1's entire success-checking around it reads nil. The bot
   must not call `act()` and must not re-enter it from inside an act superload — that
   re-entrancy is the pinned-freeze mechanism (each call re-runs the full turn-start block,
   T/Actor.lua:679–820). After `autoExplore()`/`restInit()`, leave `game.paused = false` and
   return; let `GameTurnBased.tick` drive `Player.act`. If synchronous stepping is wanted,
   call `runStep()`/`restStep()` directly with explicit energy/position checks and a hard
   iteration cap. In any act override use `self` and pass the engine's argument through.
2. **`move(x, y)` returns "attempted", not "moved"** *(changed)*. Capture `ox, oy` before and
   compare `self.x, self.y` after — the same test 1.7.6 uses (T/Actor.lua:1424,
   E/PlayerRun.lua:140–142). Before deciding to move, pre-check `attr("never_move")`,
   `attr("sleep") and not attr("lucid_dreamer")`, `attr("encased_in_ice") or attr("encased")`,
   and `enoughEnergy()` — **this is the T-012 "can I move at all?" predicate**, covering
   pinned, encumbered, egg form and every other never_move source. Treat tiles whose TRAP
   entity has `is_store` as non-walkable (moving onto one opens the store, T/Player.lua:315–318).
   Do not issue moves while `attr("confused")` unless a random step is acceptable.
3. **`useTalent` return is not a success signal** *(contract wider than v1 assumes)*. For
   activated talents always pass `force_target` (5th arg) and `no_confirm = true` (7th arg) —
   including the Recovery/DamagePrevention self-casts at P:712/:724, or interactive targeting
   opens under the bot. `false` = refused-without-acting for *any* reason (not just cooldown);
   `nil` = pending (targeting/confirm coroutine yield) or fallthrough. Detect failure via the
   postUseTalent hook (already wrapped, P:507–511, ignoring the sustain-deactivation path) and
   treat a pending talent (targeting mode active, `#game.dialogs` grew) as a hard stop.
4. **Status attributes are additive counters, three with changed domains** *(changed:
   confused, frozen, lucid_dreamer)*. Never `== 1`. `confused` is a 0–50 **percentage** —
   the CONFUSED stop effectively never fires in v1; this is a **third latent v1 bug** (a
   `== 1` domain bug, distinct from the two `not x == 1` cases) and belongs in
   v1-latent-bugs.md. `frozen` is set by both real encasement (EFF_FROZEN) and a pure pin
   (EFF_FROZEN_FEET) — split into `attr("encased_in_ice")` (cannot act) and
   `attr("never_move")` (cannot move). The sleep gate is exactly
   `attr("sleep") and not attr("lucid_dreamer")` — **v1-latent-bugs.md Bug 2's suggested fix
   (`lucid_dreamer ~= 1`) is still wrong**: the Solipsist sustain's value is 5–25+, never 1;
   amend that doc. Full setter inventory in [Value-domain notes](#value-domain-notes-the-status-attributes).
5. **The drowning stack** *(changed: undead, terrain.air_level; missing: abs/MAX_INT)*.
   Breathing is decided per tile: hazardous =
   `air_level and air_level < 0 and not attr("no_breath") and not attr("invulnerable") and (not air_condition or (can_breath[air_condition] or 0) <= 0)`
   (T/Actor.lua:628–634, :7396–7397). Do not test `undead` (`no_breath` is Skeleton-only —
   Ghouls and Liches drown), and do not test `not can_breath` — it is **always a table**
   (T/Actor.lua:226), so **both v1-latent-bugs.md Bug 1's suggested fix and
   salvage-mishander.md item 5's "Take" import dead code**; downgrade item 5 to "take the
   intent, not the expression" and amend Bug 1. Player-side signals `is_suffocating` /
   `air_regen < 0` are the cheap alternative (T/Player.lua:1078, :1081). Compare
   `air / max_air` ratios, never absolute 50/75 (Yeek max_air = 200). In getPathToAir replace
   the nonexistent `abs`/`MAX_INT` (P:344/:341) with `math.abs`/`math.huge` — a crash
   currently masked by the dead guard — and rank candidate tiles by `air_level` so the +15
   bubble tile wins. Note the rest/EXPLORE ping-pong: restStop → on_end → EXPLORE while
   drowning re-rests every turn; the stop-reason handling in item 9 breaks the loop.
6. **Dialog identification** *(changed)*. The lore title is localised (`tformat`,
   T/LorePopup.lua:37) — the English `"Lore found:"` match breaks on non-English locales, and
   `title` can be nil. Match `game.dialogs[#game.dialogs].__CLASSNAME == "mod.dialogs.LorePopup"`;
   dismiss **only** via the EXIT virtual (restores `game.tooltip.inhibited`); guard any title
   read with `type(d.title) == "string"`. Whitelist the bot's own expected dialogs by
   __CLASSNAME (talent-confirm yesnoPopup, rest popup, hidden explore popup) before treating
   a non-empty stack as a stop.
7. **Settings persistence** *(uncertain)*. Nested `tome.SkooBot.X = v` relies on two-level
   auto-vivification no shipped 1.7.6 code needs; the C loader's behaviour is unprovable
   here. Write **one** settings file — `game:saveSettings("tome.skoobot", data)` with data
   beginning `tome.skoobot = tome.skoobot or {}\n` then explicit assignments (the
   Minimalist/UserChat pattern). Also open the defaults file with
   `config.settings.tome = config.settings.tome or {}` so the addon stops depending on the
   font-bootstrap side effect.
8. **`loadPrevious`** *(uncertain — C-side)*. Keep `local _M = loadPrevious(...)` verbatim as
   the first class reference in each superload file; declare it a read_global for superload/
   in .luacheckrc; add a one-time harness assertion that `_M.__CLASSNAME` is
   `"mod.class.Player"` / `"mod.class.Actor"` so a silent loader change is caught.
9. **`restInit` stop handling**. on_end fires on *every* stop, including synchronously inside
   restInit on refusal — v1's validateRest flips to EXPLORE unconditionally. Capture the stop
   reason (wrap restStop, or use on_very_end) and branch on it; treat `self.resting ~= nil`
   after restInit as "rest accepted" and do not attempt a second action that turn (one energy
   is already spent); never rest on a negative-air_level tile unless the item-5 predicate
   says it is breathable.
10. **Globals → locals** *(hygiene, enforced)*. Make aiStop, checkForAdditionalAction,
    getUnspentTotal, skoobot_act, reduce, recSum `local function`s (forward-declare the
    mutually recursive pair); give the added methods real `self`; namespace all per-character
    state under one saved table (versioned, migrated) and keep volatile state off the save
    (`_no_save_fields`). Enforce with luacheck under T-023.
11. **Keybind robustness**. Call `game.key:bindKeys()` immediately after
    `KeyBind:load` + `addBinds` in the ToME:run hook (removes the accidental dependency on
    UserChat's rebuild), and add the binds from a `Game:setupCommands` superload as well so
    they survive chronoRestore.
12. **`game.log` format discipline**. Never concatenate dynamic text into the first argument
    (it is a format string *and* a translation key, no pcall); use `game.log("%s", msg)`.
    Fixes the latent crash at P:586/:594/:190 on any `%` in a title or talent name.
13. **Small fixes basket**: nil-guard `getTalentFromId(...)` derefs (P:190, :193); test
    `not t.hide` (BTD:72, :142); pass GetQuantity `min` as the 6th ctor arg (BTD:91, :115);
    rename every `/data-skoobot/` path if the port's `short_name` changes; delete the dead
    requires (P:29–32) and dead helpers (getHotbarTalents, getDirNum, target_dist); harden
    Astar use (nil-check before `path[1]`, `add_check` to skip occupied intermediate tiles,
    cache the path per activation — every failed calc prints to stdout); copy the spotHostiles
    guard `not self.x or not game.level` and use `getName()`; clear the ACTION_DELAY timer
    flag in its callback; parenthesise the requires-target condition (P:478); delete the
    vacuous `type ~=` clauses or use `getCombatStats` (A:49–50); add `combat_generic_crit`
    to the type crit instead of substituting (A:62–64).

---

## Value-domain notes: the status attributes

All of these are plain actor properties written through `addTemporaryValue`, which is
**additive** with no `temporary_values_conf` override for any of them (E/Entity.lua:925;
conf list T/Actor.lua:119–152). Two simultaneous sources yield 2. `attr(prop)` returns the
accumulated number or nil (E/Entity.lua:1158–1170). **Correct test is always truthiness,
never `== 1`.**

| attribute | set by (1.7.6) | correct test | semantics |
|---|---|---|---|
| `stunned` | EFF_STUNNED (T/data/timed_effects/physical.lua:490), EFF_BURNING_SHOCK (:454), GLOOM_STUNNED (mental.lua:357), MADNESS_STUNNED (:885) — each +1 | `attr("stunned")` | Stun does **not** block acting or moving in 1.7.6 (damage −50%, 3 talents on cooldown, move speed −50%); stopping on it is a policy choice, not a "cannot act" condition — keep it out of the T-012 predicate. |
| `confused` | EFF_CONFUSED (mental.lua:137–138) and four others — each adds a bounded **percentage** (0–50, default 30) | `attr("confused")`; the value is the % chance | Engine rolls `rng.percent(...)` on move and talent use (T/Actor.lua:1395–1397, :5953–5955). v1's `== 1` fires only at exactly 1% — the stop never worked. |
| `dazed` | EFF_DAZED only (physical.lua:567, also adds never_move :568) | `attr("dazed")` | Blocks movement (via never_move), halves power/defense, does not block talents. |
| `frozen` | EFF_FROZEN (physical.lua:764; also encased_in_ice :761, no_healing, never_move) **and** EFF_FROZEN_FEET (:725; a pure pin, "able to act freely but not move") | split: `attr("encased_in_ice")` = cannot act normally; `attr("never_move")` = cannot move | Nothing in T/mod reads `attr("frozen")`; the engine keys the encasement on `encased_in_ice` (T/Actor.lua:1405–1407). |
| `sleep` | EFF_SLEEP/SLUMBER/NIGHTMARE (mental.lua:2342/2392/2451), EFF_SEDATED (physical.lua:3504), **and the Lucid Dreamer sustain itself** (dreaming.lua:119) — a Solipsist with it up has sleep ≥ 1 permanently | `attr("sleep") and not attr("lucid_dreamer")` — the engine's own gate, 16 call sites (T/Actor.lua:1402 etc.) | A bare sleep test stops the bot forever for that class. |
| `lucid_dreamer` | sustain: mind-scaled power 5–25+ (dreaming.lua:110, :118); items/effects: exactly 1 (robe.lua:219 etc.); additive, so item + sustain = power+1 | `attr("lucid_dreamer")` truthiness | 1.7.6 never compares it to 1. v1-latent-bugs Bug 2's proposed `~= 1` fix still fails the sustainer. |
| `never_move` | PINNED (physical.lua:3554), ~20 other effects (frozen feet, daze, ice, egg form, …), and **encumbrance** (T/Actor.lua:4186) | `attr("never_move")` | The general "cannot move" channel — the core of the T-012 predicate. |
| `undead` | race base descriptor (undead.lua:61) | do not use for breathing | Only remaining engine read is vim_on_death (T/Actor.lua:3433). `no_breath = 1` is **Skeleton-only** (undead.lua:221); Ghouls and Liches drown. |
| `can_breath` | **always a table** (T/Actor.lua:226 `t.can_breath = t.can_breath or {}`), keyed by the terrain's `air_condition` (naga: `{water=1}`) | `(can_breath[air_condition] or 0) > 0`, with `attr("no_breath")` as the override | `not can_breath` is always false on 1.7.6 — the fix recommended in v1-latent-bugs Bug 1 and salvage-mishander item 5 is dead code. |
| `air` / `max_air` | resource (T/data/resources.lua:45); max_air varies by race/item (Yeek 200; artifacts 50/20) | ratios (`air / max_air`), or `is_suffocating` / `air_regen < 0` | Terrain drowning subtracts air directly (T/Actor.lua:7398); it does **not** make air_regen negative — the rest-refusal at T/Player.lua:1078 never fires from water; the water stop is the 0.75-ratio check at :835–840. |

---

## Not changed, but fragile (T-021 watch list)

OK items whose 1.7.6 behaviour the port will rely on, but whose guarantee is incidental —
the kind of thing a future ToME patch could move without notice. Keep the superload surface
minimal and these isolated behind small wrappers.

- **Keybind activation order.** Hook-added binds only go live because UserChat rebuilds
  `game.key` after run (E/UserChat.lua:55, gated on `allow_userchat`). Own the rebuild
  (Remediation 11).
- **`config.settings.tome` at hook time** exists via the font bootstrap (E/Module.lua:976),
  not by contract — the engine itself still nil-guards it two lines after loadAddons.
- **Player inheritance order.** `restStop` resolves to PlayerRest's only because
  `engine.interface.PlayerRest` is listed *after* `mod.class.Actor` (whose :371 defines a
  dummy) in T/Player.lua:39–51 and `class.inherit` is last-wins (E/class.lua:100). A
  reordering silently kills every rest-stop callback.
- **Additive status counters.** None of the status flags has a `temporary_values_conf`
  entry today; a future entry (e.g. "maximum") would change the observed values. Truthiness
  tests survive that; anything numeric does not.
- **`attr("can_offshoot")` has no setter in base 1.7.6** — DLC content unverified; the
  getCombatStats path is the stable way in.
- **The dialog stack carries friendly dialogs** (rest popup, hidden `__hidden` explore
  popup, talent-confirm yesnoPopup). Any "non-empty stack = stop" heuristic is one engine UI
  addition away from a false stop; whitelist by `__CLASSNAME` (Remediation 6).
- **English string matching anywhere** is now a locale hazard — 1.7.x runs titles, log
  formats, and compass strings through `_t`. Match by class/field, log by `%s`.
- **Lua 5.1 `module()`** underpins the class system and the global paths
  (`engine.Map`, `engine.ui.Dialog`). Universal in 1.7.6, deprecated upstream in Lua —
  a T-Engine modernisation would touch every file; nothing to do but know it.
- **`coordToDir`'s 2-arg form** assumes square mode, which stock ToME forces
  (E/Module.lua:958/:961) — a hex addon flips `is_hex` process-wide and the call returns nil.
  `util.getDir` is hex-safe.
- **Stale `x`/`y` after map removal** (E/Actor.lua:464 clear is commented out) — currently
  harmless because scans are per-turn; any caching of actor records must re-validate.
- **`targetGetForPlayer`'s auto-accept bypass** (`config.settings.auto_accept_target`,
  E/GameTargeting.lua:314) changes whether an un-forced target yields — user-config-dependent
  behaviour under the bot; always passing force_target sidesteps it.
- **v1 save-file fields load fine on 1.7.6** (`skoobot*` instance fields, class.save
  mechanics unchanged) — but the port should not inherit the pattern: unversioned config in
  saves is how `skoobotstopconditions` becomes a nil-index on the first added stop code.
