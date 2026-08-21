long_name = "SkooBot Devbridge"
short_name = "skoobot_devbridge"
for_module = "tome"
version = {1,7,6}
addon_version = {0,1,0}
weight = 2000
author = { "SkoobyDoo (skoobot.reclauded@proton.me)" }
description = [[DEVELOPMENT TOOL. NOT FOR RELEASE.

Opens a command bridge between a running game and an external test harness: reads Lua
command files from the T-Engine home directory, executes them, and reports results to
te4_log.txt. Also logs human input so an automated run can tell its own actions apart
from a person touching the keyboard.

This addon executes arbitrary Lua from disk by design. It must never be published.]]
tags = { 'dev' }

hooks = true
