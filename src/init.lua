long_name = "SkooBot: Reclauded"
short_name = "skoobot_reclauded"
for_module = "tome"
version = {1,7,6}
addon_version = {0,1,0}
weight = 1000
author = { "SkoobyDoo (skoobot.reclauded@proton.me)" }
homepage = "https://github.com/SkoobyDoo/skoobot-reclauded"
description = [[A reboot of SkooBot: hand your character over to a bot that rests, explores, and fights for you, and hands control back when it judges the situation needs you.

The point is to take the tedium out of levelling a new character, not to beat the game. Expect it to stop often and early rather than get you killed.

RUNS ENTIRELY OFFLINE. No language model, no network requests, no API key, no telemetry. "Reclauded" is a play on "rebooted" -- this addon was built with the help of Claude, an AI assistant, but contains none of it. It is ordinary Lua running inside your game.

This is a separate addon from the original SkooBot, which remains published and unchanged. Installing this one will not touch it.

Status: early. Not yet feature-complete against the original.]]
tags = { 'bot', 'ai', 'auto', 'autoplay', 'skoobot' }

-- Directories this addon contributes. Kept honest: flip these on as the
-- corresponding trees actually gain content, not in advance.
hooks = true
overload = true
superload = true
data = true
