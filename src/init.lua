long_name = "SkooBot: Reclauded"
short_name = "skoobot_reclauded"
for_module = "tome"
version = {1,7,6}
addon_version = {0,1,0}
weight = 1000
author = { "SkoobyDoo (skoobot.reclauded@proton.me)" }
homepage = "https://github.com/skoobot-reclauded/skoobot-reclauded"
description = [[An autopilot for levelling: hand your character to a bot that rests, explores and fights for you, and hands control back whenever it judges the situation needs you.

BETA. Every 0.x version is an early build published on GitHub only -- not on te4.org and not on the Steam Workshop, and not there until 1.0.0. If you are running this, you were pointed at it. Expect rough edges, and please report them: https://github.com/skoobot-reclauded/skoobot-reclauded/issues

ENABLE THIS ADDON BEFORE CREATING THE CHARACTER YOU WANT TO USE IT ON. A savefile records the addons it was made with, and the game silently ignores any addon a save does not list -- no error, it is simply not there -- so it cannot attach to a character that already exists.

Getting started, in game: Shift+F7 opens the menu. Set which talents the bot may use (or let it suggest a loadout from the talents you know), then Shift+F3 starts it, and stops it again. Shift+F6 asks what it would do next without doing it. All five keys can be changed under Key Bindings.

The point is to take the tedium out of levelling a new character, not to beat the game. Expect it to stop often and early rather than get you killed -- low life, a debuff, a stronger enemy, a glowing chest, stairs -- and each stop says why. Which of those stop it, warn once, or are ignored is yours to set from the menu.

RUNS ENTIRELY OFFLINE. No language model, no network requests, no API key, no telemetry. "Reclauded" is a play on "rebooted" -- this addon was built with the help of Claude, an AI assistant, but contains none of it. It is ordinary Lua running inside your game.

A successor to the original SkooBot, not an update to it: everything the original did, on ToME 1.7.6, with the defects its users reported fixed -- marked-target talents stalling the rotation, stops on a scratch, the freeze when pinned or put to sleep, glowing chests walked past, drowning while resting, the talent list overflowing the screen. The original remains published and unchanged, and installing this one will not touch it.]]
tags = { 'bot', 'ai', 'auto', 'autoplay', 'skoobot' }

-- Directories this addon contributes.
--
-- Not cosmetic: `hooks = true` makes the engine loadfile()
-- <addon>/hooks/load.lua and error(err) on failure, outside any pcall
-- (engine/Module.lua:697-698), so declaring a directory that holds no load.lua
-- aborts module load the first time the addon is enabled. Flip each one on in
-- the same commit that gives its tree real content; spec/manifest_spec.lua
-- enforces that.
hooks = true
overload = true
superload = true
data = true
