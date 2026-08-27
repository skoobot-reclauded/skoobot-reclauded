-- SkooBot Devbridge, tome tier -- DEVELOPMENT ONLY. Never ship this addon.
--
-- Command channel:  harness writes /skoobot-bridge/cmd-NNNN.lua, we execute it.
-- Result channel:   print() -> te4_log.txt, every line tagged [BRIDGE].
--
-- The T-Engine home directory is mounted at / by bootstrap/boot.lua, so
-- /skoobot-bridge/ is <home>/4.0/skoobot-bridge/ on the real filesystem.
--
-- Design and the engine gotchas behind it: docs/design-harness.md

local class      = require "engine.class"
local Key        = require "engine.Key"
local KeyBind    = require "engine.KeyBind"
local Mouse      = require "engine.Mouse"
local EngineGame = require "engine.Game"

-- Addon hooks run in setmetatable({...}, {__index = _G}) (engine/Module.lua:699):
-- reads chain to _G but writes stay local, so a bare global assignment is
-- invisible to loadstring chunks. Export explicitly or every command sees nil.
local bridge = { injecting = false, polls = 0, done = 0, last_seq = 0, tier = "tome" }
_G.bridge = bridge
local DIR = "/skoobot-bridge/"

local function emit(s) print("[BRIDGE] "..tostring(s)) end
bridge.emit = emit

function bridge.say(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts+1] = tostring((select(i, ...))) end
	emit("say "..table.concat(parts, " "))
end

--- Fire a bound command by name on whatever currently has focus.
-- Key.current (engine/Key.lua:93) is the focused handler, so this follows
-- dialogs and drives menus as well as the map.
function bridge.key(virtual)
	local h = Key.current
	if not h then return "no key handler" end
	bridge.injecting = true
	local ok, err = pcall(h.triggerVirtual, h, virtual)
	bridge.injecting = false
	if not ok then return "error "..tostring(err) end
	return "key "..tostring(virtual)
end

--- Fire a raw keypress through the real dispatch path.
function bridge.rawkey(sym, ctrl, shift, alt)
	local h = Key.current
	if not h then return "no key handler" end
	bridge.injecting = true
	local ok, err = pcall(h.receiveKey, h, sym, ctrl or false, shift or false,
	                      alt or false, false, nil, false, sym)
	bridge.injecting = false
	if not ok then return "error "..tostring(err) end
	return "rawkey "..tostring(sym)
end

--- What is on screen right now, named. Menus are navigated by dialog class and
--- bound-command name, never by pixel position, so a resolution change mid-run
--- cannot break a test.
function bridge.dialogs()
	if not game or not game.dialogs then return "none" end
	local out = {}
	for i, d in ipairs(game.dialogs) do
		out[#out+1] = i..":"..tostring(d.title or d.__CLASSNAME or "?")
	end
	if #out == 0 then return "none" end
	return table.concat(out, " | ")
end

local function readAll(path)
	local f = fs.open(path, "r")
	if not f then return nil end
	local lines = {}
	while true do
		local l = f:readLine()
		if not l then break end
		lines[#lines+1] = l
	end
	f:close()
	return table.concat(lines, "\n")
end

-- Selection phase, guarded. Picks at most one command and claims it.
--
-- fs.delete cannot actually remove these files: physfs writes only beneath its
-- own write path, which the module repoints, so the delete silently no-ops and
-- an unguarded pump re-runs the same command forever. Advancing a monotonic
-- sequence makes execution idempotent whatever the filesystem does; the harness
-- does the real cleanup.
local claiming = false

local function claim()
	if claiming then return nil end
	claiming = true

	local pick, src
	local ok, err = pcall(function()
		bridge.polls = bridge.polls + 1
		if not fs.exists(DIR) then return end
		local pickseq
		for _, f in ipairs(fs.list(DIR)) do
			local n = f:match("^cmd%-(%d+)%.lua$")
			if n then
				n = tonumber(n)
				if n > bridge.last_seq and (not pickseq or n < pickseq) then pick, pickseq = f, n end
			end
		end
		if not pick then return end
		bridge.last_seq = pickseq
		src = readAll(DIR..pick)
		fs.delete(DIR..pick)   -- best effort; expected to no-op
	end)

	claiming = false
	if not ok then emit("ERR claim "..tostring(err)) return nil end
	return pick, src
end

-- Execution phase, deliberately UNGUARDED.
--
-- A command may never return: atEnd("created") runs birth, world generation and
-- a save/load cycle, and the frame that invoked it does not survive. Holding the
-- guard across execution would latch it true forever and silently kill the pump.
-- Guard the shared state (file selection), not the arbitrary code.
local function poll()
	local pick, src = claim()
	if not pick then return end
	if not src then emit(pick.." ERR unreadable") return end

	local fn, err = loadstring(src, "=bridge:"..pick)
	if not fn then emit(pick.." ERR compile "..tostring(err)) return end

	local ok, res = pcall(fn)
	bridge.done = bridge.done + 1
	emit(pick.." "..(ok and "OK" or "ERR").." "..tostring(res))
end

-- ---------------------------------------------------------------------------
-- Interference detection.
--
-- The development machine is also a machine a person uses. A keystroke, click
-- or resolution change mid-run produces failures that are NOT defects, and an
-- autonomous loop that cannot tell the difference will file phantom bugs and
-- then "fix" them. Everything not originating from the bridge is logged, so the
-- harness can void an overlapping result instead of believing it.
--
-- Resolution changes need no wrapper: the engine already logs [DO RESIZE].
-- ---------------------------------------------------------------------------

if not KeyBind.__skoobot_interference then
	KeyBind.__skoobot_interference = true

	local old_receiveKey = KeyBind.receiveKey
	function KeyBind:receiveKey(sym, ctrl, shift, alt, meta, unicode, isup, key, ismouse)
		if not bridge.injecting and not isup then
			emit("INTERFERE key sym="..tostring(sym).." turn="..tostring(game and game.turn))
		end
		return old_receiveKey(self, sym, ctrl, shift, alt, meta, unicode, isup, key, ismouse)
	end

	local old_receiveMouse = Mouse.receiveMouse
	function Mouse:receiveMouse(button, x, y, isup, force_name, extra)
		if not bridge.injecting and not isup then
			emit("INTERFERE mouse btn="..tostring(button).." turn="..tostring(game and game.turn))
		end
		return old_receiveMouse(self, button, x, y, isup, force_name, extra)
	end

	local old_idling = EngineGame.idling
	function EngineGame:idling(focus)
		emit("INTERFERE focus="..tostring(focus).." turn="..tostring(self.turn))
		return old_idling(self, focus)
	end
end

--- Which addons the engine actually loaded, sorted, comma-separated.
---
--- The engine drops any addon a savefile does not list, with one line in the
--- log and no other symptom (engine/Module.lua:565-569). Without this a
--- behaviour run can "verify" a game that never loaded the product. Assert on
--- this before measuring anything.
---
--- mod.addons is populated at Module.lua:549 and reachable from the running
--- game because Module.lua:163 stores the module table on the Game class as
--- __mod_info, which instances inherit.
function bridge.addons()
	local mi = rawget(_G, "game") and game.__mod_info
	local adds = mi and mi.addons
	if not adds then return "unknown" end
	local out = {}
	for name, _ in pairs(adds) do out[#out+1] = tostring(name) end
	if #out == 0 then return "none" end
	table.sort(out)
	return table.concat(out, ",")
end

--- One-line state snapshot. Turn count first: progress is measured in turns,
--- never wall-clock, so a resize or a stray click cannot fail a test on timing.
function bridge.state()
	local p = game and game.player
	if not p then return "no player" end
	return "turn="..tostring(game.turn)
		.." name="..tostring(p.name)
		.." life="..tostring(p.life).."/"..tostring(p.max_life)
		.." pos="..tostring(p.x)..","..tostring(p.y)
		.." zone="..tostring(game.zone and game.zone.short_name)
		.." level="..tostring(game.level and game.level.level)
		.." dialogs="..tostring(game.dialogs and #game.dialogs or 0)
end

-- ---------------------------------------------------------------------------
-- Pump from display(), not onTickEnd().
--
-- onTickEnd looks like the obvious hook and is wrong in both modules. In boot,
-- tick() only reaches engine.Game.tick -- and so onTickEndExecute -- when
-- self.level is set or self.stopped is true (boot/mod/class/Game.lua:454-462),
-- and the menu's demo level drops out across level changes. In tome,
-- onTickEndCapture (engine/Game.lua:380) swaps the callback set into a temporary
-- table during level changes, so a self-rescheduling callback can land in a set
-- that is discarded rather than merged. Either way the pump dies silently.
--
-- display() runs every frame regardless of level, dialog or tick state. One
-- fs.exists per frame is nothing.
-- ---------------------------------------------------------------------------

-- Arm BOTH mechanisms. They fail in complementary ways, so either alone leaves a
-- hole: display() stops when the OS window loses focus or is minimised, and
-- onTickEnd can be dropped by onTickEndCapture during a level change. Together
-- one always survives. Double-invocation is harmless -- claim() is guarded and
-- the sequence gate makes execution idempotent.
local function pumpOnce()
	local ok, err = pcall(poll)
	if not ok then emit("ERR poll "..tostring(err)) end
end

local function installPump(ModGame)
	if ModGame.__skoobot_bridged then return end
	ModGame.__skoobot_bridged = true

	local old_display = ModGame.display
	function ModGame:display(nb_keyframes)
		pumpOnce()
		return old_display(self, nb_keyframes)
	end

	-- Armed once, not per frame: onTickEndExecute clears the name table on every
	-- pass, so re-arming by name would append a fresh closure every tick and grow
	-- without bound.
	if game and game.onTickEnd then
		game:onTickEnd(function()
			pumpOnce()
			return game.TICK_RESCHEDULE
		end, "skoobot_devbridge_pump")
	end
end


-- ---------------------------------------------------------------------------
-- Creature dossiers (#135). OFF unless a run asks for them.
-- ---------------------------------------------------------------------------
--
-- A faithful record of a creature and of the character at the moments that
-- decide whether the power-level formula was right: the blow that WOULD kill,
-- the death, and the kill.
--
-- WHY THE WHOLE OBJECT rather than the fields the formula reads. The formula is
-- the thing under suspicion, so recording only its inputs can re-weight the
-- terms it already has and nothing else. #100's premise is that danger lives in
-- what a creature KNOWS and CARRIES -- fields nothing currently looks at -- so a
-- new TERM has to be proposable from an old record, or every idea costs another
-- sweep. Owner's call, 2026-08-25.
--
-- WHY HERE AND NOT IN src/. Owner's call, same day: a harness function only,
-- and off unless asked. A serializer in src/ is one that ships, and the first
-- thing wired to it starts writing files on a player's machine. pack.ps1
-- refuses anything under tools/, so this cannot.
--
-- The engine's own serializer is not reusable: Class:save() goes through
-- core.serial, which is C-side and writes into the savefile zip, turning every
-- cross-reference into a separate entry (engine/class.lua:443). It produces a
-- savefile, not a self-contained record.

local DOSSIER_SCHEMA = 1        -- bump when the shape changes; see below
local DOSSIER_DIR    = "/dossiers/"
local MAX_DEPTH      = 12
local MAX_KEYS       = 400

bridge.dossier = { on = false, schema = DOSSIER_SCHEMA, records = {}, creatures = {}, byform = {}, nform = 0,
                   seen_uids = {},
                   audit = { predicted = 0, deaths = 0, kills = 0, forms = 0, reused = 0, deltas = 0,
                             sightings = 0 } }

--- Marks a key the form has and this instance does not, so that "absent" and
--- "unchanged" stay distinguishable when a delta is reapplied. See #135.
local DOSSIER_ABSENT = "__absent"

--- Another game entity rather than part of this one?
--
-- A creature points at other creatures -- ai_target.actor, summoner,
-- escort_target -- and following those drags in the level and then the game.
-- Cut there and keep the neighbour's identity; the uid is enough to join
-- records afterwards, which is what "what else was in the room" needs.
local function dossierIsEntity(t)
	return type(t) == "table" and rawget(t, "uid") ~= nil and rawget(t, "name") ~= nil
end

local function dossierStub(e)
	return { __ref = "entity", uid = rawget(e, "uid"), name = tostring(rawget(e, "name")),
	         rank = rawget(e, "rank") }
end

--- Deep copy into plain data. Functions, userdata and threads are not state and
-- do not serialise. TRUNCATION IS ALWAYS MARKED: a silently trimmed field reads
-- as absent, absent reads as zero, and a zero quietly changes what a candidate
-- formula computes -- which is the error class this whole exercise exists to
-- find.
-- Presentation, never state, and skipped at EVERY depth -- unlike the
-- per-entity skip list below, which dossierWalk deliberately does not carry
-- into nested tables. A particle emitter's colour range keys are rM/rm and
-- gM/gm, which differ only in case: PowerShell's ConvertFrom-Json folds them
-- together and refuses the whole file, so one sparkle on one buff took out a
-- 29-class analysis. See #172.
local DOSSIER_NOISE = {
	particles = true, particle = true, particle1 = true, particle2 = true,
	_shader = true, shader = true, __particles = true,
}

local function dossierWalk(v, depth, seen, skip)
	local tv = type(v)
	if tv == "number" or tv == "string" or tv == "boolean" then return v end
	if tv ~= "table" then return nil end
	if seen[v] then return { __ref = "cycle" } end
	if depth > MAX_DEPTH then return { __truncated = "depth" } end

	seen[v] = true
	local out, n = {}, 0
	for k, val in pairs(v) do
		local tk = type(k)
		if (tk == "string" or tk == "number") and not (skip and skip[k]) and not DOSSIER_NOISE[k] then
			n = n + 1
			if n > MAX_KEYS then out.__truncated = "keys" break end
			if depth > 0 and dossierIsEntity(val) then
				out[k] = dossierStub(val)
			else
				local w = dossierWalk(val, depth + 1, seen, nil)
				if w ~= nil then out[k] = w end
			end
		end
	end
	seen[v] = nil
	return out
end

--- What makes two actors the SAME creature rather than the same instance.
-- Level belongs in it: a level 3 wolf is a different stat block from a level 2
-- one, and collapsing them would invent data that was never measured.
local function dossierIdent(a)
	return table.concat({
		tostring(rawget(a, "__CLASSNAME")), tostring(rawget(a, "name")),
		tostring(rawget(a, "rank")), tostring(rawget(a, "level")),
		tostring(rawget(a, "type")), tostring(rawget(a, "subtype")),
		tostring(rawget(a, "unique")),
	}, "|")
end

--- Deep difference: the parts of `now` that are not already in `base`.
-- Returns nil when the two are identical, which is the common case and the
-- one that makes this worth doing. Reapply by merging into the form, treating
-- DOSSIER_ABSENT as a deletion.
local function dossierDelta(base, now)
	local out, any = {}, false
	for k, v in pairs(now) do
		local b = base[k]
		if type(v) == "table" and type(b) == "table" then
			local sub = dossierDelta(b, v)
			if sub ~= nil then out[k] = sub ; any = true end
		elseif v ~= b then
			out[k] = v ; any = true
		end
	end
	for k in pairs(base) do
		if now[k] == nil then out[k] = DOSSIER_ABSENT ; any = true end
	end
	if not any then return nil end
	return out
end

--- One actor, split into the part that identifies the CREATURE and the part
--- that identifies this INSTANCE of it.
---
--- Most of a run is the same handful of species over and over -- a level's
--- worth of giant brown mice have identical stat blocks and differ only in
--- where they stand and how hurt they are. Storing the block once and
--- referencing it is the difference between megabytes and kilobytes, and it
--- costs nothing in fidelity: both halves are still recorded in full.
function bridge.dossierActor(a)
	if type(a) ~= "table" then return nil, nil end
	-- _no_save_fields is the ENTITY'S OWN list of what is runtime noise rather
	-- than state (engine/class.lua:445) -- a better answer than any list here.
	local skip = {}
	if type(a._no_save_fields) == "table" then
		for k in pairs(a._no_save_fields) do skip[k] = true end
	end
	skip._mo, skip._last_mo, skip._mo_final, skip._hooks = true, true, true, true

	local snap = dossierWalk(a, 0, {}, skip)
	if type(snap) ~= "table" then return nil, nil end

	-- The first snapshot of an identity becomes the form; later ones carry only
	-- what differs from it. Nothing is curated and nothing is assumed volatile,
	-- so a field nobody thought of still gets recorded the moment it moves.
	local d = bridge.dossier
	local key = dossierIdent(a)
	local id = d.byform[key]
	if not id then
		d.nform = d.nform + 1
		id = "c" .. d.nform
		d.byform[key] = id
		d.creatures[id] = snap
		d.audit.forms = d.audit.forms + 1
		return { form = id }, id
	end
	d.audit.reused = d.audit.reused + 1
	local delta = dossierDelta(d.creatures[id], snap)
	if delta == nil then return { form = id }, id end
	d.audit.deltas = d.audit.deltas + 1
	return { form = id, delta = delta }, id
end

--- What OUR formula makes of it -- recorded beside the raw fields and never
-- instead of them. A replay compares a candidate against this.
local function dossierFigures(a)
	local b = rawget(_G, "skoobot_reclauded")
	if not b or type(a) ~= "table" then return nil end
	local ok, res = pcall(function() return b.power(a) end)
	return ok and res or nil
end

--- Was anything WARNED about at this instant, and about whom? This is the
-- diagonal that matters: a death with no flag raised is the formula failing to
-- see it coming, which is worse than dying to something it did warn about.
local function dossierScore(p)
	local b = rawget(_G, "skoobot_reclauded")
	if not b or not p then return nil end
	local ok, s = pcall(function() return b.score(p) end)
	if not ok or type(s) ~= "table" then return nil end
	return dossierWalk({ flags = s.flags, terms = s.terms, figures = s.figures,
	                     posture = s.posture, details = s.details }, 0, {}, nil)
end

--- Append one record. Keyed by turn and moment so several hits in one turn do
-- not fill the ledger with near-identical rows.
local function dossierRecord(moment, subject, src)
	local d = bridge.dossier
	if not d.on then return end
	local p = game and game.player
	local turn = game and game.turn or -1
	local key = tostring(moment) .. ":" .. tostring(turn) .. ":" .. tostring(subject and subject.uid)
	if d.last_key == key then return end
	d.last_key = key

	local ok, rec = pcall(function()
		-- On a kill the player IS the source, and its delta is the largest thing
		-- on the row (the damage logs grow all run). Snapshot it once and let the
		-- other slot point at it rather than repeating it.
		local pRef = bridge.dossierActor(p)
		local sRef
		if src == p then sRef = { same = "player" }
		elseif src then sRef = bridge.dossierActor(src) end
		return {
			moment  = moment,
			turn    = turn,
			zone    = game.zone and game.zone.short_name,
			level   = game.level and game.level.level,
			subject = (subject == p) and { same = "player" } or bridge.dossierActor(subject),
			source  = sRef,
			player  = pRef,
			figures = { subject = dossierFigures(subject), source = src and dossierFigures(src) or nil,
			            player = dossierFigures(p) },
			score   = dossierScore(p),
		}
	end)
	if not ok then
		d.records[#d.records + 1] = { moment = moment, turn = turn, error = tostring(rec) }
		return
	end
	d.records[#d.records + 1] = rec
end

--- Install the hooks. Not installed means NOT INSTALLED -- no superload, no
-- serialisation, no cost -- rather than a hook that runs and discards, so the
-- ordinary dev loop pays nothing for this.
--- Everything now in view that this run has not recorded yet (#101).
---
--- The power level that matters is the one at FIRST SIGHTING. A creature read
--- at the moment it kills the character has been fought down and scores a
--- fraction of what it did when the fight began -- life is a term in the sum --
--- so "review the power levels of enemies recently seen (when first seen...
--- their power level will be stunted)" is a SAMPLING requirement, not an
--- analysis step. It cannot be reconstructed afterwards.
---
--- Every uid is marked once whether hostile or not, so a friendly costs one
--- reaction test per run rather than one per turn; only hostiles are recorded.
local function dossierSightings(p)
	local d = bridge.dossier
	local lvl = game and game.level
	if not lvl or not lvl.entities or not lvl.map then return end
	local seen = d.seen_uids
	-- pairs, not ipairs: game.level.entities is keyed by uid, not an array, so
	-- ipairs walks nothing and the sampler silently recorded zero. escort.lua
	-- has always used pairs on this same table.
	for _, a in pairs(lvl.entities) do
		local uid = a and rawget(a, "uid")
		if uid and a ~= p and not seen[uid] and a.x and a.y and not a.dead then
			if lvl.map.seens(a.x, a.y) and p:canSee(a) then
				seen[uid] = true
				if p:reactionToward(a) < 0 then
					d.audit.sightings = d.audit.sightings + 1
					dossierRecord("sighting", a, nil)
				end
			end
		end
	end
end

--- #153/#164: the engine aborts a run for a hostile, the bot then picks its
--- own branch. When those two disagree the bot explores again, the engine
--- aborts again, and the pair live-locks with no hand-back and no damage --
--- Shadowblade burned 21,368 turns that way against a black jelly that could
--- never move or reach it.
---
--- runStop is the one moment both views exist at once, so record them there:
--- the engine's own exported spotHostiles (the same one runCheck consults) and
--- the branch the bot is sitting in. A run of these records showing hostiles
--- in view while the state stays EXPLORE is the disagreement, caught rather
--- than argued.
local function dossierRunStop(p, msg)
	local reason = tostring(msg or "")
	if not reason:find("hostile spotted") then return end
	local seen = (p.spotHostiles and p:spotHostiles(true)) or {}
	local names = {}
	for i, h in ipairs(seen) do
		if i > 4 then break end
		names[#names + 1] = tostring(h.name or "?")
	end
	local b = rawget(_G, "skoobot_reclauded")
	bridge.dossier.records[#bridge.dossier.records + 1] = {
		moment     = "run_stop",
		turn       = game and game.turn,
		reason     = reason,
		engine_saw = #seen,
		names      = names,
		bot_state  = (b and b.stateName and b.stateName()) or nil,
		bot_active = (b and b.active) and true or false,
		x = p.x, y = p.y,
	}
end

function bridge.dossierOn()
	local d = bridge.dossier
	if d.on then return "already on" end
	d.on = true

	local Actor = require "mod.class.Actor"

	-- THE SEAM (owner's idea, 2026-08-25). engine/interface/ActorLife.lua:71:
	--   if self.onTakeHit then value = self:onTakeHit(value, src) end   -- 72
	--   self.life = self.life - value                                   -- 73
	-- Between those the damage is FINAL -- shields and resists already applied
	-- by onTakeHit -- and life is still PRE-HIT. So the character is whole here
	-- in a way it never is again: effects, cooldowns, resources, position.
	--
	-- onTakeHit rather than takeHit: the interesting point is mid-function, so a
	-- takeHit superload would have to reimplement it, and calling onTakeHit
	-- ourselves before delegating would run it TWICE, applying shields a second
	-- time. That is a correctness bug, not a style one.
	if not Actor.__skoobot_dossier_hit then
		Actor.__skoobot_dossier_hit = true
		local old = Actor.onTakeHit
		function Actor:onTakeHit(value, src, death_note)
			local adjusted = old(self, value, src, death_note)
			if self.player and not self.dead and type(adjusted) == "number"
			   and (self.life - adjusted) <= (self.die_at or 0) then
				bridge.dossier.audit.predicted = bridge.dossier.audit.predicted + 1
				-- PREDICTED, not confirmed: on_kill can cancel the death
				-- (ActorLife.lua:76), and self-resurrect can follow it. A blow
				-- that would have killed and did not is a near-death, which is
				-- the evidence that a warning was RIGHT -- so it is kept and
				-- labelled, not filtered out.
				dossierRecord("predicted_lethal", self, src)
			end
			return adjusted
		end
	end

	-- Confirmed deaths, and the audit. die() wipes the state inside itself --
	-- self-resurrect sets life/mana/stamina back to full and strips effects
	-- BEFORE any hook fires (mod/class/Actor.lua:3153-3175) -- so this is not
	-- where the snapshot comes from. It is where the death is COUNTED, and the
	-- gap against `predicted` measures what the damage seam misses: instadeath
	-- effects and anything calling die() directly never pass through takeHit.
	if not Actor.__skoobot_dossier_die then
		Actor.__skoobot_dossier_die = true
		local olddie = Actor.die
		function Actor:die(src, death_note)
			local dos = bridge.dossier
			if dos.on and not self.dead then
				local p = game and game.player
				if self.player then
					dos.audit.deaths = dos.audit.deaths + 1
					dossierRecord("death", self, src)
				elseif src and src == p then
					dos.audit.kills = dos.audit.kills + 1
					-- The character's state at the kill is the COST proxy: a
					-- warned enemy killed at 95% life is a dud, the same enemy
					-- killed at 5% means the warning was right, and "dispatched"
					-- alone cannot tell them apart.
					dossierRecord("kill", self, src)
				end
			end
			return olddie(self, src, death_note)
		end
	end
	-- #101: sample what enters view, as it enters view. playerFOV is where
	-- "what can I see" is recomputed, so it is the moment a creature becomes
	-- visible; anything later has already been fought.
	local Player = require "mod.class.Player"
	if not Player.__skoobot_dossier_fov then
		Player.__skoobot_dossier_fov = true
		local oldfov = Player.playerFOV
		function Player:playerFOV()
			local r = oldfov(self)
			if bridge.dossier.on and self == (game and game.player) then
				local ok, err = pcall(dossierSightings, self)
				if not ok then emit("ERR dossier sighting " .. tostring(err)) end
			end
			return r
		end
	end

	-- #153: the run-abort, which is where the engine's view and the bot's
	-- disagree. Harness-only and dossier-gated, like everything else here.
	if not Player.__skoobot_dossier_runstop then
		Player.__skoobot_dossier_runstop = true
		local oldrunstop = Player.runStop
		function Player:runStop(msg)
			if bridge.dossier.on and self == (game and game.player) then
				local ok, err = pcall(dossierRunStop, self, msg)
				if not ok then emit("ERR dossier runstop " .. tostring(err)) end
			end
			return oldrunstop(self, msg)
		end
	end

	return ("on schema=%d"):format(DOSSIER_SCHEMA)
end

--- Drain: hand the ledger over and forget it, so a long run does not grow
-- without bound and the harness owns the only copy.
function bridge.dossierDrain()
	local d = bridge.dossier
	local out = d.records
	d.records = {}
	d.last_key = nil
	return out
end

--- After a write, forget the interned forms too -- a drained file is
--- self-contained, and keeping them would make the next file reference ids
--- whose definitions it does not carry.
local function dossierForget()
	local d = bridge.dossier
	d.creatures, d.byform, d.nform = {}, {}, 0
	d.seen_uids = {}
end

--- Strict JSON, because the engine's encoder does not emit it: Json2 escapes
-- an apostrophe as \' (thirdparty/Json2.lua:334), which JSON has no such escape
-- for, so every file written through it failed to parse. See #135.
local JSON_ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
                   ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function jsonStr(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return JSON_ESC[c] or ("\\u%04x"):format(c:byte())
	end) .. '"'
end

-- inf has no JSON literal but 1e999 parses back to it in both Python and JS;
-- nan has neither, so it is marked rather than silently turned into null.
local function jsonNum(n)
	if n ~= n then return '"__nan"' end
	if n == math.huge then return "1e999" end
	if n == -math.huge then return "-1e999" end
	return ("%.14g"):format(n)
end

local function jsonEnc(v, out)
	local tv = type(v)
	if v == nil then out[#out+1] = "null"
	elseif tv == "boolean" then out[#out+1] = tostring(v)
	elseif tv == "number" then out[#out+1] = jsonNum(v)
	elseif tv == "string" then out[#out+1] = jsonStr(v)
	elseif tv ~= "table" then out[#out+1] = jsonStr(tostring(v))
	else
		local n, total = #v, 0
		for _ in pairs(v) do total = total + 1 end
		if n > 0 and total == n then
			out[#out+1] = "["
			for i = 1, n do
				if i > 1 then out[#out+1] = "," end
				jsonEnc(v[i], out)
			end
			out[#out+1] = "]"
		else
			out[#out+1] = "{"
			local first = true
			for k, val in pairs(v) do
				if not first then out[#out+1] = "," end
				first = false
				out[#out+1] = jsonStr(tostring(k))
				out[#out+1] = ":"
				jsonEnc(val, out)
			end
			out[#out+1] = "}"
		end
	end
end

--- Write the ledger to a file and forget it.
--
-- NOT returned through the result channel: that is the log, and a run's
-- dossiers are megabytes.
function bridge.dossierWrite(name)
	local recs = bridge.dossierDrain()
	-- creatures[] holds each distinct stat block once; every record points at
	-- one by id. A reader joins them back with record.subject.form.
	local payload = { schema = DOSSIER_SCHEMA, audit = bridge.dossier.audit,
	                  creatures = bridge.dossier.creatures, records = recs }
	local buf = {}
	local ok, err = pcall(jsonEnc, payload, buf)
	if not ok then return "ERR encode " .. tostring(err) end
	local encoded = table.concat(buf)
	-- NOT the bridge dir: that is mounted readable but is not under PhysFS's
	-- write path, so fs.open there returns nil without raising. The write path
	-- is the module dir (measured: C:\...\T-Engine.0	ome), and /dossiers/
	-- lands inside it.
	if not fs.exists(DOSSIER_DIR) then fs.mkdir(DOSSIER_DIR) end
	local path = DOSSIER_DIR .. tostring(name)
	local f = fs.open(path, "w")
	if not f then return "ERR open " .. path end
	f:write(encoded)
	f:close()
	local forms = bridge.dossier.audit.forms
	dossierForget()
	return ("wrote %s records=%d forms=%d bytes=%d"):format(path, #recs, forms, #encoded)
end

function bridge.dossierStatus()
	local d = bridge.dossier
	return ("on=%s schema=%d pending=%d predicted=%d deaths=%d kills=%d sightings=%d forms=%d reused=%d deltas=%d"):format(
		tostring(d.on), d.schema, #d.records, d.audit.predicted, d.audit.deaths, d.audit.kills,
		d.audit.sightings,
		d.audit.forms, d.audit.reused, d.audit.deltas)
end

class:bindHook("ToME:run", function()
	if not fs.exists(DIR) then fs.mkdir(DIR) end
	installPump(require "mod.class.Game")
	emit("ready tier=tome turn="..tostring(game and game.turn))
end)
