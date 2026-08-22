-- SkooBot Devbridge, boot tier -- DEVELOPMENT ONLY. Never ship this addon.
--
-- Same protocol as the tome tier, alive at the main menu before any game
-- exists, so character creation and save loading need no human. Deliberately
-- duplicated rather than shared: the two addons mount separate trees and
-- cross-addon require is fragile.
--
-- Design and the engine gotchas behind it: docs/design-harness.md

local class      = require "engine.class"
local Key        = require "engine.Key"
local KeyBind    = require "engine.KeyBind"
local Mouse      = require "engine.Mouse"
local EngineGame = require "engine.Game"

-- See the tome tier for why this export is explicit (engine/Module.lua:699).
local bridge = { injecting = false, polls = 0, done = 0, last_seq = 0, tier = "boot" }
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

--- Which addons the engine actually loaded, sorted, comma-separated.
---
--- At this tier that is the boot module's set; the tome tier answers the same
--- question about the real game. Same helper in both so a scenario can ask
--- without caring which tier is answering (T-041, T-043).
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

class:bindHook("Boot:run", function()
	if not fs.exists(DIR) then fs.mkdir(DIR) end
	installPump(require "mod.class.Game")
	emit("ready tier=boot")
end)
