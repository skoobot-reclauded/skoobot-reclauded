# GitHub workflow

**Status:** current as of 2026-08-21 · **Tasks:** T-022, T-033, T-035

How this project is hosted, who acts on GitHub, and the two rules that must not be broken.
Written to be readable by someone who has never seen this repo before — including a future
maintainer, a contributor, or an assistant with no prior context.

Machine-specific credential mechanics are deliberately **not** here; see
[Where the credentials live](#where-the-credentials-live).

---

## 1. Topology

| Thing | Value |
|---|---|
| Organisation | `skoobot-reclauded`, owned by the `SkoobyDoo` account |
| Repository | `skoobot-reclauded/skoobot-reclauded` (private until releasable) |
| Machine account | `skoobot-reclauded-bot` |
| Contact address | project mailbox — **receive-only**, outbound is out of scope |

The org exists so the successor gets its own namespace, repo ownership, README and avatar
without a second personal account. GitHub's terms allow one free account per person, machine
accounts excepted, and enforcement is account suspension — not a risk worth attaching to a
released addon.

**Automated work commits and files issues as `skoobot-reclauded-bot`, never as `SkoobyDoo`.**
That is the point of the machine account: assistant-written code is not attributed to a human
who did not write it. Commits additionally carry a `Co-Authored-By: Claude` trailer.

---

## 2. The two hard rules

### 2.1 Never touch the original SkooBot

The protected repo is **`SkoobyDoo/tome4-SkooBot`**, along with its te4.org page and Steam
Workshop listing. It is a live artifact with real users — 146 Steam subscribers and a 5.0/5
rating on te4.org. This project starts from zero instead of inheriting or displacing it.
Recorded as **D-1** and **D-3** in the research archive's `TASKS.md`.

Never push to it, rename it, transfer it, archive it, or open a pull request against it. Never
create a GitHub *fork* of it: forks display "forked from" and default new PRs to the parent,
which is exactly the coupling this avoids. **D-5** makes the project a full GPL-3.0 derivative
with copying permitted, so a git-level fork buys nothing that copying does not.

Creating a brand-new repo cannot affect the old one. That is always safe.

A note on the token, because the nuance is easy to state wrongly: the bot's fine-grained PAT
is scoped to the `skoobot-reclauded` org, and reports `push:false, admin:false` on
`tome4-SkooBot`. But `tome4-SkooBot` is **public**, and fine-grained tokens get implicit public
read regardless of scoping. The accurate claim is that the token **cannot write** to the old
repo — not that it cannot see it.

### 2.2 Never authenticate as the human

`gh auth login` is **not** to be run, and `gh` is deliberately left logged out. An interactive
login would authenticate as `SkoobyDoo` and make every subsequent action attributable to them,
including anything that touches rule 2.1.

The supported path is a fine-grained personal access token belonging to the machine account:

```
read the token from the vault  ->  set GH_TOKEN for the life of the script  ->  clear it
```

**That covers `gh` only. `git` does not read `GH_TOKEN`.** This distinction is the whole of
rule 2.2 in practice, and getting it wrong does not fail loudly — it fails by succeeding as
the wrong person.

Left to itself an unattended `git push` reaches whatever credential helper is configured
(Git Credential Manager, on Windows), which falls back to an **interactive** sign-in. If a
human completes that prompt, GCM stores *their* credential, and every later push from that
clone silently runs as them. That is exactly the outcome this rule exists to prevent, arrived
at without anyone doing anything wrong.

Two measures, and both are needed:

- **Take the helper out of the loop for the push**, and supply the token through a transient
  helper that lives only for that one command, so nothing is written to disk:

  ```bash
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=<machine-account>; echo password=$GH_TOKEN; }; f' \
      push origin main
  ```

  The empty first `-c` resets the helper list so the configured helper is never consulted;
  the second adds the transient one. `$GH_TOKEN` is single-quoted so the shell git spawns
  expands it — the value never appears on a command line.

- **Block the interactive fallback in the clone**, so a bare `git push` fails loudly instead
  of quietly asking a human to authenticate:

  ```bash
  git config --local credential.helper ''
  ```

  Clone-level and untracked, so repeat it on any fresh clone, next to the identity and
  hooks steps in §3.

Bracket the push with checks rather than trusting it: working tree clean and every outgoing
commit authored by the machine account before; fetch first and refuse if the remote moved;
afterwards confirm the branch matches the remote and that **no credential was cached** by the
push. The machine-specific script that does all of this, and the vault mechanics it depends
on, are deliberately not in this repo — see [Where the credentials live](#where-the-credentials-live).

Never write the token to a file, a commit, a log line, or the conversation. Verify access by
using the token, or by checking a value's length or fingerprint — never by printing it.

---

## 3. Identity

The chosen posture is **loosely separate**: a distinct project mailbox so the public contact
address is not a personal one, with no attempt to conceal who is behind the project.

Practical consequences:

- Do **not** put a personal email address in the README, `src/init.lua` metadata, the te4.org
  listing, or the Steam Workshop page. Use the project mailbox: `skoobot.reclauded@proton.me`.
- **Set the repo-local git identity to the machine account** in every clone, before the first
  commit:

  ```bash
  git config user.name  "skoobot-reclauded-bot"
  git config user.email "319607269+skoobot-reclauded-bot@users.noreply.github.com"
  ```

  Without it, git falls back to the global identity and commits land under whoever is at the
  keyboard. That is how the first eleven commits here ended up authored by the owner; they
  were rewritten to the machine account on 2026-08-21, while the repo was still unpushed and
  the fix was free.

- **Point git at the tracked hooks, in every clone**, in the same breath:

  ```bash
  git config core.hooksPath tools/githooks
  ```

  `tools/githooks/pre-commit` parse-checks, lints and unit-tests the **index** — what the
  commit will actually contain, not the working tree — and refuses the commit if any of them
  fail. It exists because v1 leaked four globals, one of which (`if not x == y`, parsed as
  `(not x) == y`) was silent: nothing errored, the bot simply never acted, playtesting could
  not surface it, and it cost users characters for eight years. luacheck flags that class
  with no configuration at all, and the version that does predates v1's final release.

  Like the identity above, this is clone-level and **untracked**, so it does not survive a
  fresh clone. That is the whole reason the hook itself is tracked in `tools/` rather than
  dropped into `.git/hooks`, where it would vanish.

  The escape hatch is `git commit --no-verify`, for genuine emergencies. Reaching for it
  routinely turns an enforced check back into a remembered one.
- **This is attribution, not concealment.** The two are easy to confuse. Do **not** bother
  with private org membership, separate te4.org / Steam identities, or hiding that SkoobyDoo
  is behind the project — none of that is wanted. Assistant-written commits carry the machine
  account because the owner did not write them, which is the opposite of hiding.
- The mailbox is **receive-only**. If outbound mail is ever needed, note that Proton's free
  tier has no SMTP (Bridge is paid), so the provider choice would have to be revisited.

---

## 4. Issue and commit conventions

**GitHub Issues in this repository are the single source of truth for tasks.** A task exists
when it is an issue with a milestone. Work that lives only in a design document, a chat, a
local note, or the research archive is not tracked: file it. There is no second board anywhere,
on purpose — two boards drift within a week.

Task IDs (`T-001`, `T-010`, …) are permanent and are **not** GitHub issue numbers, which will
never match. The mapping is the issue list itself.

- **T-IDs go in issue titles**: `T-010 — Conditional / marked-target talents stall the
  rotation`. To find an issue by T-ID, search `T-010 in:title`.
- **T-IDs go in commit messages**: `Fix talent fallthrough (T-010)`. That keeps
  `git log --grep=T-010` working as the audit trail independently of GitHub, which matters
  because the tracker can be migrated but history cannot.
- **Allocating an ID**: take the next free number in the themed block — `00x` baseline and
  tooling · `01x` inherited defects · `02x` core model and release features · `03x`
  housekeeping · `04x` verification, harness and dev loop · `05x` release and packaging ·
  `06x` safety and credentials · `07x` tracking, documentation and continuity — found by
  searching issue titles for the highest one in that block. Gaps are unallocated, not retired;
  no lettered sub-IDs.
- **Every issue gets a milestone** (M1 Baseline and tooling · M2 Core model · M3 Inherited
  defects · M4 Release readiness) and labels from the existing set. Dependencies and
  "subsumed by" relations go in the issue body, so the board explains its own ordering.
- Automated work files, comments on, and edits issues as the machine account (§2.2); the
  verified mechanics live with the credentials (see below).

Decisions (`D-n`) are **not** issues and are not filed as such. They are reasoning, not work;
they are held by the maintainer in the local research archive for now and cited here by ID,
each citation carrying its one-line substance.

---

## 5. Token lifecycle

The fine-grained PAT `skoobot-reclauded-claude` is scoped to the `skoobot-reclauded` org and
**expires 2026-11-19**. Expiry is silent: calls simply start failing as unauthenticated.

After any rotation, confirm the vault actually changed by recomputing the token's SHA-256
fingerprint (first 96 bits) and comparing it to the recorded one — this verifies the change
without either party looking at the value.

Note that a repo's `.permissions` block reports the **account's role**, not the token's scope
ceiling. `push:true` there does not mean a push will succeed; the token's Contents permission
is the real gate. Do not infer token scope from that field.

**Contents is read/write, and that means the token can rewrite history.** It was read-only
until the first push needed it on 2026-08-21. While it was read-only, an automated agent
holding it structurally *could not* force-push or delete a branch; that protection is gone and
nothing replaced it. `main` is not protected — branch protection returns 403 for this token,
and rulesets need Pro or a public repo — so the constraint is now a rule rather than a
mechanism:

- **Never `--force`, never `--force-with-lease`, never delete `main`.** A history rewrite
  needs explicit owner sign-off, in advance. The full-history rewrite done on 2026-08-21 was
  safe only because nothing had been pushed yet.
- Treat "it is on GitHub" as **not a backup**. A bad force-push is usually recoverable from
  the local reflog for 90 days, which is a window, not a guarantee. The push script keeps a
  `git bundle` off to one side and each milestone gets an annotated tag, so a rewrite is
  recoverable from more than one direction.
- Enable rulesets the day the repo goes public (T-054).

---

## Where the credentials live

The vault, the wrapped master password, and the exact retrieval procedure are recorded in
`OPERATIONS.md` in the research archive (`Project Summary`), which is local-only and never
published. They are machine-bound and deliberately kept out of this repo, which is intended to
go public.

If that machine is gone, the credentials are gone with it — by design. Re-establishing access
means the owner creating a new token; nothing here can be recovered from this repo alone, and
nothing here needs to be.
