long_name = "SkooBot Devbridge (menu)"
short_name = "skoobot_devbridge_boot"
for_module = "boot"
version = {1,0,0}
addon_version = {0,1,0}
weight = 2000
author = { "SkoobyDoo (skoobot.reclauded@proton.me)" }
description = [[DEVELOPMENT TOOL. NOT FOR RELEASE.

Boot-module half of the devbridge. Gives the harness a command channel at the main
menu, before any game exists, so character creation and save loading can be driven
without a human. Hands over to the tome-module half once a game starts.

Executes arbitrary Lua from disk by design. Never publish.]]
tags = { 'dev' }

hooks = true
