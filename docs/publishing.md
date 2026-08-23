# Publishing to te4.org and Steam Workshop

**Issue:** #34 · **Date:** 2026-08-23 · **Status:** procedure; not yet exercised

> ## Human-only procedure
>
> **Nothing in this document is to be executed by an assistant, a script, or the machine
> account.** It needs the maintainer's own te4.org login and Steam session, which exist
> nowhere in this repository and nowhere the bot can reach; the in-game dialog it uses only
> appears for a logged-in profile; and the harness launches the game with `--no-steam
> --no-web`, so a harness-driven game cannot publish even by accident. If you are an assistant
> reading this: the step you can take is to confirm the release in [releasing.md](releasing.md)
> is complete and stop.

Publishing comes **after** a release exists — tag `v0.x.y`, packed artifact, GitHub Release
([releasing.md](releasing.md) §3). The listings show the `addon_version` from `init.lua`, and a
listing version with no tag behind it cannot be rebuilt. Treat an upload as immutable: a
mistake is a new patch version, never a re-upload under the same number.

---

## 1. How the game publishes

ToME ships its own publishing tool: `tome-addon-dev.teaa` in `game/addons/`, an addon whose
dialog `mod/dialogs/debug/AddonDeveloper.lua` registers an addon on te4.org (`createAddon`),
uploads a version (`publishAddon`) and pushes it to the Steam Workshop (`publishAddonSteam`).
Three facts about it shape the procedure:

- It is `cheat_only`, so it loads **only in Developer Mode** (`engine/Module.lua:574`), and
  its dialog is reached from the in-game Debug menu (`Ctrl+A`, the `DEBUG_MODE` bind, itself
  cheat-only). Developer Mode is toggled from the in-game Escape menu (*Developer Mode*, in
  the engine's `GameMenu`) and **invalidates any savefile loaded while it is on.**
- Its *Register* and *Publish* entries are offered only when `profile.auth` is set — the
  profile is logged in — and the Workshop entry only when `core.steam.connected()`.
- It lists only addons loaded **from a directory** (`not add.teaa`), and what it uploads is
  **its own zip of that directory** (`zipAddon`: everything except `.git`, `.svn`, `.hg`,
  `CVS` and `pack.me`), written to `user-generated-addons/tome-skoobot_reclauded.teaa` under
  the game's user directory, with the MD5, `version` and `addon_version` sent alongside. It
  does not upload the `.teaa` `tools/pack.ps1 -Release` built.

The alternative is the website, `https://te4.org/addons/tome`, which takes a `.teaa` file —
the gated artifact itself. The site's upload form is enabled per profile by the game
(`profile:addonEnableUpload()`, called when the dialog zips an addon), so a profile that has
never published in-game may find no form there; the in-game path is the one that is known to
work on a fresh profile.

## 2. Prerequisites

- The release is complete: `v0.x.y` pushed, `dist/tome-skoobot_reclauded-0.x.y.teaa` built by
  `pack.ps1 -Release`, the GitHub Release up.
- The game **launched the normal way** — its own launcher, or Steam for the Workshop step —
  **not** through the harness and without `--no-steam` or `--no-web`. No harness session may
  hold the game (`tools/harness-lease.ps1`): the junctions it leaves behind are the ones this
  procedure depends on, and a `Stop-Game` from another session would kill the upload.
- **Logged in to the te4.org profile in-game** (main menu → Profile). This is the
  maintainer's own account.
- **Steam running and the game launched through it**, for the Workshop step.
- **A throwaway character** to turn Developer Mode on with. Never a character you keep.
- **The addon loaded from a directory** that matches the release tag exactly: a checkout at
  `v0.x.y` with a clean tree, junctioned in by `tools/setup-dev.ps1` as
  `game/addons/tome-skoobot_reclauded` → `src/`. Because the dialog zips the directory, what
  it uploads is what `pack.ps1 -Release` built only if the directory is that commit's `src/`
  and nothing else. Check before uploading: `unzip -l` the dialog's zip and the release
  `.teaa` and compare the entry lists — `.gitkeep` files or editor leftovers under `src/`
  would ship through the dialog and not through `pack.ps1`.
- `init.lua` has `tags` and `description` set (the dialog refuses without them), and the
  `description` text is what both listings will display. Read it once more.
- For the first Workshop upload, optionally a preview image: a 512×512 PNG at
  `user-generated-addons/tome-skoobot_reclauded-custom.png` in the game's user directory. The
  game generates a default one otherwise.

## 3. Procedure

1. Launch the game normally, log in to the profile, load the throwaway character.
2. Escape menu → *Developer Mode* → confirm. Back in the game, `Ctrl+A` → *Addon Developer*.
3. **First release only — register the short name.** *Register new Addon* → *SkooBot:
   Reclauded*. This sends `short_name`, `long_name`, `description` and `tags` from
   `init.lua`. Wait for "registered. You may now upload a version for it."
   - The short name is `skoobot_reclauded`, chosen by decision **D-3** (*a new short name,
     never the original's `skoobot`, so the live addon and its listing are never touched*).
     ToME accepts the underscore; **whether te4.org's registration does is unverified until
     this step runs.** If it refuses, stop here: changing the short name touches the
     manifest, the pack script, the settings namespace, the dialog paths and every saved
     character, and is a decision for the maintainer, not an improvisation at the upload.
4. **Upload the version.** *Publish Addon to te4.org* → *SkooBot: Reclauded* → release name
   `0.x.y`. The dialog zips the directory, sends it with the MD5 and both version numbers,
   and reports "uploaded, players may now play with it!" on success, or the server's reason.
5. **Check the listing** on te4.org: the version shown is `0.x.y`, the game version is the
   `version` from `init.lua`, the description reads as intended.
6. **Steam Workshop.** *Publish Addon to Steam Workshop* (the dialog itself says it needs the
   te4.org publish first). On the first upload it creates the Workshop item from
   `long_name`, `description`, `tags` and the preview image, stores the Workshop id against the
   addon on te4.org, and then asks you to accept the Workshop legal agreement in the Steam
   client — the item is invisible to others until that is done. Later uploads update the
   existing item.
7. Escape menu → *Developer Mode* → disable. Quit the game. Restore the development loop
   afterwards if the junction was repointed for this (`tools/setup-dev.ps1` from the usual
   checkout).
8. Note on the release issue that the listings are up, with the te4.org and Workshop links.

## 4. Not part of this procedure

- **Cross-linking from the original SkooBot's pages** — its te4.org listing, Workshop item,
  repository README — is the maintainer's call, made separately, by hand. Rule 1 in
  [CLAUDE.md](../CLAUDE.md) applies to anything automated: the original is never touched.
- **Credentials.** The te4.org and Steam logins are the maintainer's own. They are not in this
  repository, not in the vault the machine account reads, and not to be put in either.
