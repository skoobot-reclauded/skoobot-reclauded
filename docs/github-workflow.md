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
- **This is attribution, not concealment.** The two are easy to confuse. Do **not** bother
  with private org membership, separate te4.org / Steam identities, or hiding that SkoobyDoo
  is behind the project — none of that is wanted. Assistant-written commits carry the machine
  account because the owner did not write them, which is the opposite of hiding.
- The mailbox is **receive-only**. If outbound mail is ever needed, note that Proton's free
  tier has no SMTP (Bridge is paid), so the provider choice would have to be revisited.

---

## 4. Issue and commit conventions

Task IDs (`T-001`, `T-010`, …) are permanent and are **not** GitHub issue numbers, which will
never match. The mapping lives in the research archive's `TASKS.md`.

- **T-IDs go in issue titles**: `T-010 — Conditional / marked-target talents stall the rotation`
- **T-IDs go in commit messages**: `Fix talent fallthrough (T-010)`

That keeps `git log --grep=T-010` working as the audit trail independently of GitHub, which
matters because the tracker can be migrated but history cannot.

Decisions (`D-n`) are **not** issues. They stay in `TASKS.md` — they are reasoning, not work.

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

---

## Where the credentials live

The vault, the wrapped master password, and the exact retrieval procedure are recorded in
`OPERATIONS.md` in the research archive (`Project Summary`), which is local-only and never
published. They are machine-bound and deliberately kept out of this repo, which is intended to
go public.

If that machine is gone, the credentials are gone with it — by design. Re-establishing access
means the owner creating a new token; nothing here can be recovered from this repo alone, and
nothing here needs to be.
