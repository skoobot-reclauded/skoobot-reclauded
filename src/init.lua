long_name = "SkooBot: Reclauded"
short_name = "skoobot_reclauded"
for_module = "tome"
version = {1,7,6}
addon_version = {0,1,0}
weight = 1000
author = { "SkoobyDoo (skoobot.reclauded@proton.me)" }
homepage = "https://github.com/skoobot-reclauded/skoobot-reclauded"
description = [[A reboot of SkooBot: hand your character over to a bot that rests, explores, and fights for you, and hands control back when it judges the situation needs you.

The point is to take the tedium out of levelling a new character, not to beat the game. Expect it to stop often and early rather than get you killed.

RUNS ENTIRELY OFFLINE. No language model, no network requests, no API key, no telemetry. "Reclauded" is a play on "rebooted" -- this addon was built with the help of Claude, an AI assistant, but contains none of it. It is ordinary Lua running inside your game.

This is a separate addon from the original SkooBot, which remains published and unchanged. Installing this one will not touch it.

Status: early. Not yet feature-complete against the original.]]
tags = { 'bot', 'ai', 'auto', 'autoplay', 'skoobot' }

-- Directories this addon contributes.
--
-- These are not cosmetic. `hooks = true` makes the engine loadfile()
-- <addon>/hooks/load.lua and error(err) on failure, outside any pcall
-- (engine/Module.lua:697-698) -- so declaring a directory that holds no
-- load.lua aborts module load the first time the addon is enabled.
-- data/overload/superload over an empty directory are mount-only and
-- harmless, but they are kept honest too so the manifest describes the
-- tree rather than an intention.
--
-- Flip each one on in the same commit that gives its tree real content.
-- spec/manifest_spec.lua enforces that: a flag may be true only if the
-- matching directory holds a file that is not .gitkeep.
hooks = false
overload = false
superload = false
data = false
