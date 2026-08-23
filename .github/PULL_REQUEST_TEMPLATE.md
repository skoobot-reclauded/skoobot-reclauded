<!--
Thank you. A short PR with a clear "why" is easier to merge than a large one
with a clear "what". See CONTRIBUTING.md for the full list of what a PR needs.
-->

**Closes** #<!-- issue number; open one first if there is none -->

**Why**
<!-- What was wrong or missing, and why this is the right fix. The diff shows
     what changed; this is the part the diff cannot show. -->

**How it was verified**
<!-- Tick what applies and say what you ran. A change to pure logic under
     src/data/ gets a busted spec in spec/; a change to in-game behaviour gets
     a tools/scenario-*.ps1 run against the live game, or -- if you cannot run
     the harness -- an honest description of the manual test: which class,
     which zone, what you watched for. -->
- [ ] `luacheck .` clean and `busted` green (the pre-commit hook ran them)
- [ ] busted spec added or updated: <!-- spec/… -->
- [ ] harness scenario run: <!-- tools/scenario-… , result -->
- [ ] manual in-game test: <!-- what, where, outcome -->

**Licensing**
- [ ] GPL-3.0 headers are intact on any adapted code (nothing stripped, nothing
      re-attributed)
- [ ] If this adapts someone else's code, `NOTICE` credits them
- [ ] Nothing under `tools/` or `spec/` is referenced from `src/`
