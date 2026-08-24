# Releasing

**Issue:** #33 · **Date:** 2026-08-23 · **Status:** procedure; first exercised by 0.1.0

How a version of SkooBot: Reclauded goes from `main` to a tagged, packed, downloadable
artifact. Publishing the artifact to te4.org and Steam is a separate, human-only step:
[publishing.md](publishing.md). What has to be true before 0.1 in particular may be cut is
[release-0.1.md](release-0.1.md).

---

## 1. Two version numbers, two rules

`src/init.lua` carries both, and the engine reads both.

**`addon_version = {0,1,0}`** is ours. It is bumped **every release**, and only there. It
appears in the archive name (`tome-skoobot_reclauded-0.1.0.teaa`), in the Addons menu, on the
te4.org listing, in the engine log's `Binding addon` line, and so in every bug report. The
series is `0.x.y`: `y` for a release that only fixes, `x` for one that adds.

**The series starts at 0.1.0.** The manifest has said `{0,1,0}` since the scaffold, nothing
has shipped before it, and the original's `0.0.x` numbers belong to the original. That closes
the question #33 left open: there is no `0.0.13`, and no release number is ever reused.

**Every `0.x.y` is a beta prerelease, and `1.0.0` is the first publish** (**D-14**,
2026-08-24 — `0.x` is a GitHub-only beta; `1.0.0` is the first te4.org / Steam publish, and
D-11's judgement bar moves to it). Concretely:

| | `0.x.y` | `1.0.0` |
|---|---|---|
| Where it goes | a GitHub Release marked **prerelease**, and nowhere else | te4.org and the Steam Workshop as well |
| Who it is for | testers who were pointed at it | anyone browsing the in-game Addons banner |
| The bar | §4 of [release-0.1.md](release-0.1.md) — the mechanical gates | the mechanical gates **and** the judgement gate |
| [publishing.md](publishing.md) | not executed | executed, by hand, by the maintainer |

So `1.0.0` is a goal with a definition rather than a number that arrives eventually, and it is
the one release where "does this feel good to a stranger" is a gate. Which build earns it is
the owner's call and is deliberately not reducible to a checklist.

**`version = {1,7,6}`** is the ToME version the addon is built against. The engine's rule for
whether an addon loads is `engine.version_nearly_same(game, addon)` (`engine/version.lua:90`):
**same major, and the addon's minor below the game's, or equal with the addon's patch at or
below the game's.** So `{1,7,6}` loads on 1.7.6, 1.7.7 and 1.8.0, and not on 1.7.5 or 2.0.0.
A newer game does not refuse it.

Bump `version` **only when a ToME change is verified or required**: a newer game breaks
something and the fix lands with the bump, or a feature needs an engine the older game lacks.
Never as routine maintenance. Stamping a new game version onto unchanged code was the only
maintenance the original received for its last eighteen months, and it verified nothing.

## 2. CHANGELOG.md

[CHANGELOG.md](../CHANGELOG.md) is in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
form and is written for players. Work accumulates under `## [Unreleased]` as it lands — a
change that a player would notice gets a line in the same commit, or the release commit has
to reconstruct it from the log. A release turns that section into `## [0.x.y] - YYYY-MM-DD`
and opens a new, empty `## [Unreleased]` above it. `tools/pack.ps1 -Release` refuses to build
a version that has no section, so this is not optional.

## 3. The procedure

A release commit carries the manifest bump and the CHANGELOG move and nothing else. Features
are already on `main`; if one is not, it is not in this release.

1. **Gates green on `main`.** For 0.1 the list is [release-0.1.md](release-0.1.md) §4. In
   general: parse, `luacheck .`, `busted`, the harness scenarios untainted, and
   `tools/clean-build.ps1`. A release is cut from a clean checkout of `main`; the tree must
   show nothing in `git status`.
2. **Bump `addon_version`** in `src/init.lua`. Bump `version` only under the rule in §1.
   Read the `description` field while there: it is the text the Addons menu shows, and from
   1.0.0 both listings.

   > **0.1.0 is the exception: there is nothing to bump.** The manifest has said `{0,1,0}`
   > since the scaffold and 0.1.0 is the first release, so this step is a *check*, not an
   > edit — confirm it reads `{0,1,0}` and move on. Bumping it here would ship 0.2.0 as the
   > first release and burn 0.1.0 forever, because no release number is ever reused (§1).
   > Every release after this one really does bump.
3. **Move the CHANGELOG.** `## [Unreleased]` → `## [0.x.y] - <today>`; add a fresh empty
   `## [Unreleased]` above it.
4. **Commit:** `Release 0.x.y (#n)`, where `#n` is the issue that tracks the release — for
   0.1.0 that is #32, which owns the gate list; a later release gets its own issue. The body
   says what the release is for, as every commit here does.
5. **Tag, annotated, on that commit, named exactly `v` + `addon_version`:**

   ```
   git tag -a v0.x.y -m "Release 0.x.y"
   ```

   The tag is the cheapest recovery point there is: `git checkout v0.x.y` followed by step 6
   rebuilds the artifact's contents from nothing but the repository, which is why the build
   refuses to run without it.

   **Annotated, not signed** — owner's call, 2026-08-24. A signed tag would let a stranger
   verify that the maintainer, and not the machine account, blessed a particular build; that
   is worth having eventually and is not worth the key management during a beta nobody has
   downloaded yet. The one signature this repository does carry is on `HUMAN.md`, where the
   point is authorship rather than release provenance. Revisit at 1.0.0, when a build starts
   reaching people who have no reason to trust it.
6. **Build the release artifact:**

   ```
   powershell -ExecutionPolicy Bypass -File tools/pack.ps1 -Release
   ```

   `-Release` refuses — listing every reason at once — unless the tree is clean, `CHANGELOG.md`
   has the `## [0.x.y]` section, and `HEAD` carries `v0.x.y`. It writes
   `dist/tome-skoobot_reclauded-0.x.y.teaa`, the canonical name with no commit stamp (a
   development build is `…-0.x.y-g<sha7>[-dirty].teaa`, #53). If it refuses after the tag was
   made: `git tag -d v0.x.y`, fix, commit, tag again. A tag that has been pushed is never
   moved; a mistake found after a push is a new patch version.
7. **Gate the artifact, not the tree:** `tools/clean-build.ps1 -SkipPack` takes the newest
   `.teaa` in `dist/` — the one just built — strips every development junction, installs it
   into the game and proves from the engine's own log that it loaded from the archive. This
   launches the game.
8. **Push with the tag:** `git push --follow-tags origin main`.
9. **GitHub Release** on `v0.x.y`: title `SkooBot: Reclauded 0.x.y`, body the CHANGELOG
   section verbatim, and the artifact attached **inside a zip** —
   `tome-skoobot_reclauded-0.x.y.zip` containing the `.teaa`. **Every `0.x` release is marked
   prerelease** (D-14), which keeps it out of the *Latest release* slot and off the repository
   sidebar's headline:

   ```
   gh release create v0.x.y dist/tome-skoobot_reclauded-0.x.y.zip \
     --title 'SkooBot: Reclauded 0.x.y' --notes-file notes.md --prerelease
   ```

   The machine account may create it, under the rules in
   [github-workflow.md](github-workflow.md) §2.2. Drop `--prerelease` only at 1.0.0.
10. **Publish** to te4.org and Steam: [publishing.md](publishing.md). Human only, and **only
    at 1.0.0** (D-14). A `0.x` release stops at step 9.

## 4. Builds reach people zipped, never as a bare `.teaa`

This applies to testers as much as to releases. A known download path strips the hyphens
from a `.teaa` file name on the way down, so `tome-skoobot_reclauded-0.1.0.teaa` arrives as
`tomeskoobot_reclauded0.1.0.teaa`. The engine only considers archives whose name starts
`tome-` (`engine/Module.lua:409`); the renamed file is skipped **silently**, the addon never
appears in the menu, and the tester reports "it does nothing". A zip survives the trip. Tell
the recipient to extract the `.teaa` into `game/addons/` unchanged.

## 5. The rolling development build

Between releases the newest build worth testing lives in **one** GitHub Release, tagged
`latest-dev` and titled `latest-dev-g<sha7>`. It is deleted and recreated whenever there is
something worth handing to a tester, so there is never more than one and no development build
is kept for its own sake.

| | `latest-dev` | `v0.x.y` |
|---|---|---|
| Tag | `latest-dev`, moved to each new build | `v0.x.y`, never moved once pushed |
| Title | `latest-dev-g<sha7>` | `SkooBot: Reclauded 0.x.y` |
| Asset | `tome-skoobot_reclauded-0.x.y-g<sha7>.zip` | `tome-skoobot_reclauded-0.x.y.zip` |
| Lifetime | until the next build replaces it | permanent |
| Prerelease | always | every `0.x` (D-14); dropped at 1.0.0 |
| CHANGELOG | not touched; `## [Unreleased]` stands | moved to `## [0.x.y]` |
| Gate | section 5.1 | section 4 and [release-0.1.md](release-0.1.md) section 4 |
| Play tested | no, and the notes say so | yes -- the judgement gate at 1.0.0 |

**The tag is stable and moves; it is deliberately not `latest-dev-<sha>`.** The release page URL
then never changes, so the README, an issue or a message to a tester can point at "the current
development build" once and stay correct, and the repository does not accumulate a dead tag per
test build. Nothing about the commit is lost: it is in the title, in the asset filename, and in
the release's own target. The cost is that anyone who has fetched `latest-dev` sees it jump on
the next fetch, which is what a development channel is for.

### 5.1 What a development build must still pass

Not the release gate -- being cheap is the point -- but never less than this, because it is a
public download a stranger can find:

1. **Clean tree, and the commit pushed.** A build from a commit nobody can check out cannot be
   reproduced from the report it generates.
2. **`luacheck .`, `busted`, and the parse check** -- the three the pre-commit hook already
   runs, so this costs nothing on a commit that went through it.
3. **`tools/pack.ps1`** with no `-Release`, which writes
   `dist/tome-skoobot_reclauded-0.x.y-g<sha7>.teaa` (#53).
4. **`tools/clean-build.ps1 -SkipPack`** -- the artifact loads standalone, proven from the
   engine's own `Binding addon` line. **This is the one gate a development build must not
   skip.** A mis-packed archive is ignored *silently* (section 4), so the only report you would
   ever get back is "it does nothing", from someone who cannot tell that from a bug.
5. **Zipped**, for the reason in section 4. That applies to a development build more than a
   release, because it is handed to people directly.

Play testing is explicitly **not** a gate here. A development build is untested by definition
and its notes have to say so; a tester who thinks they were given a release will report the
wrong things.

### 5.2 Replacing it

From a clean checkout of `main` whose HEAD is pushed, with `<sha7>` the short hash and `<sha>`
the full one:

```powershell
powershell -ExecutionPolicy Bypass -File tools/pack.ps1
powershell -ExecutionPolicy Bypass -File tools/clean-build.ps1 -SkipPack
Compress-Archive dist/tome-skoobot_reclauded-0.1.0-g<sha7>.teaa `
                 dist/tome-skoobot_reclauded-0.1.0-g<sha7>.zip
```

Then replace the release. `--cleanup-tag` is what lets the tag move: it removes the tag with the
release, so the next `create` re-points it at the new commit.

```
gh release delete latest-dev --yes --cleanup-tag
gh release create latest-dev dist/tome-skoobot_reclauded-0.1.0-g<sha7>.zip \
  --target <sha> --title 'latest-dev-g<sha7>' --notes-file notes.md --prerelease
```

`--target` takes a **full** 40-character SHA or a branch name; an abbreviated hash is rejected
with `HTTP 422: Release.target_commitish is invalid`. The machine account creates it, under
[github-workflow.md](github-workflow.md) section 2.2, exactly as at step 9.

The notes are written fresh each time and say what the build is for. They must state that it is
a development snapshot, name the commit, carry the install steps, and say that it has had no
play testing.

## 6. Hotfixes


Same procedure with `y` bumped: the fix lands on `main` with its test, then steps 2–10. There
are no release branches; `main` is always the next release. Until 1.0 there is no promise to
patch anything but the latest version.
