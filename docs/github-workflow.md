# GitHub workflow

**Status:** current as of 2026-08-23 · **Issues:** #17 (T-022), #20 (T-035), #22 (T-033),
#30, #35, #41, #43, #44

How this project is hosted, who acts on GitHub, how a change reaches `main`, and the two rules
that must not be broken. Written to be readable by someone who has never seen this repo
before — including a future maintainer, a contributor, or an assistant with no prior context.

Machine-specific credential mechanics are deliberately **not** here; see
[Where the credentials live](#where-the-credentials-live). Nothing in this document depends on
a file outside this repository: where a decision is cited by its `D-n` number, the sentence
carries what was decided.

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
rating on te4.org. This project starts from zero instead of inheriting or displacing it. Two
decisions fix that: **D-1** — rebuild as a new repository, the original untouched — and
**D-3** — a new `short_name` (`skoobot_reclauded`), because reusing `skoobot` would hijack the
live addon in every player's addon list.

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

  On the development machine a global-gitconfig `includeIf` applies the machine-account
  identity to any checkout under `Documents\skoobot-reclauded*`, so worktrees and fresh
  clones there get it without the two commands above. And the tracked pre-commit hook
  refuses a commit whose author is not the machine account (#39), so a clone that missed
  both is stopped at the first commit rather than found at push time.

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
when it is an issue with a milestone. Work that lives only in a design document, a chat, or a
private note is not tracked: file it. There is no second board anywhere, on purpose — two
boards drift within a week.

**An issue is identified by its number, and nothing else.** Until 2026-08-22 every task also
carried a permanent `T-nnn` ID in its title and in commit messages, allocated by hand in
themed blocks, so that `git log --grep=T-010` would survive a tracker migration. That scheme
is retired (decision **D-13**, held by the maintainer: *the blocks filled within days, every
new finding needed an allocation before it could be filed, and GitHub already links `#54`
wherever it appears*). **Nothing is edited retroactively** — the T-IDs already in titles,
commits and docs stay valid references, and `T-010 in:title` or `git log --grep=T-010` still
finds them.

- **Titles are plain**: `Stop for glowing chests instead of walking past them`. No prefix.
- **Commit messages cite the issue number**: `Fix talent fallthrough (#5)`. GitHub links it,
  and `git log --grep='(#5)'` is the audit trail. If the tracker is ever migrated, the
  numbers are mapped then.
- **The commit that finishes an issue says so, in a `Closes #n` trailer** (**D-17**,
  2026-08-24). At the foot of the message, beside `Co-Authored-By`, and **only on the commit
  that finishes it** — the plain `(#n)` citation above stays on every commit that touches the
  issue, finishing or not.

  **Close the issue yourself. The trailer will probably not do it for you**, and that is
  measured rather than assumed (2026-08-24, #113): same repository, same default branch, same
  keyword in the same position, one variable. `510235f`'s `Closes #104` closed #104 when the
  maintainer pushed from their own clone; `9500c1e`'s `Closes #112` closed nothing when
  `tools/push-addon.ps1` pushed it with the machine account's fine-grained PAT. The scripted
  path (§2.2) is the one where it does not fire, so it is the case to plan for. Fixing that is
  #113 — the script knows which commits it pushed and holds a token that can close an issue.

  **The trailer is worth writing anyway**, which is why the rule stands: it puts the claim
  *this finishes #n* in the history, where `git log --grep='Closes #'` finds it and a rebase
  cannot strip it, and it makes the author state that judgement at the moment they are best
  placed to make it. Automation was the convenience; the record is the point.

  **Not in the subject, and not on the second line.** The keyword is parsed anywhere in the
  message, so it gains nothing by being near the top, and the second line is the blank one
  after the subject. A trailer also survives the `--ff-only` rebase flow, where a SHA written
  into an issue comment does not — comments on this board cite `7622e0e` and `fd6e72f`, and
  neither is on `main` any more.

  **The trailer is written after the judgement, never instead of it.** *An issue is not done
  because its reported symptom stopped* (**D-16**) is a call no keyword can make, and an
  auto-close is silent where issues here close with a comment saying what landed and what is
  left. If the issue's own argument still stands, the commit does not carry the trailer, and
  the remaining scope is filed as its own issue first.

  **It catches less than it looks like it should, and that is not an argument against it.** An
  issue whose close condition is an *event* rather than a change — a green CI run, a play pass,
  a maintainer's ruling — cannot be closed by any commit, and those are the ones that go stale:
  of the four found open-but-finished on 2026-08-24, two could not have been caught this way.
  The backstop is a periodic sweep of the open board against `main`, run before a release is
  cut (#111) — and, until #113, that sweep is also what catches an issue whose trailer was
  written and never acted on. `tools/githooks/commit-msg` warns — it never refuses — when a
  subject cites neither an issue nor a decision, which is the shape the other two had.
- **Every issue gets a milestone** (M1 Baseline and tooling · M2 Core model · M3 Inherited
  defects · M4 Release readiness · M5 Post-0.1) and labels from the existing set.
- **Dependencies and "subsumed by" relations go in the issue body**, not in a document and
  not in a label, so the board explains its own ordering. An issue that is blocked says by
  what; an issue that another one absorbs says so and is closed when the absorbing one is.
- **The `next` label is the priority signal.** A handful of open issues carry it at any time,
  and that set — not milestone order, not issue number, not whatever a document happens to
  mention first — is what a session picks from. Applying it is the maintainer's call; it comes
  off when the issue closes or is set aside. There is no other priority label and no project
  board: one signal, kept small, stays honest.
- **A need stated in a document is either filed as an issue or removed from the document.**
  A design document may say what a thing should do; it may not carry a to-do. A sentence that
  amounts to "this still needs doing" becomes an issue, cited from the document by number, or
  it goes. This is what keeps "single source of truth" true rather than aspirational — a
  reader who finishes a document has read no work that the tracker does not also show.
- Automated work files, comments on, and edits issues as the machine account (§2.2); the
  verified mechanics live with the credentials (see below).

Decisions (`D-n`) are **not** issues and are not filed as such. They are reasoning, not work.
**D-7** puts them where they are: tasks are GitHub issues; decisions and research stay in the
maintainer's private archive until the repository is public, when their visibility is
revisited (§8). They are cited here by ID, and every citation carries its one-line substance,
so that a reader without the record still knows what was decided and why.

---

## 5. How a change reaches `main`

This is the review rule, written as the practice it already is. Decided by the owner on
2026-08-23. Revisiting it was once deferred to going public; that happened on 2026-08-24
and changed nothing here (§8).

1. **Every code change is made in a worktree on an issue branch.** The integration checkout
   is always `main` and always clean; anything that touches `src/`, `tools/` or `spec/` is
   done in `git worktree add ../skoobot-reclauded-<n> -b issue-<n>`. Docs-only changes may go
   straight onto `main`, committed at once. Worktrees inherit the identity, the blank
   credential helper and the hooks from §3.
2. **The issue's scenarios run from that checkout** before it merges: `busted` for pure
   logic, the relevant `tools/scenario-*.ps1` against the live game for behaviour. Every
   commit on the branch has already passed the pre-commit hook, so parse, lint and unit tests
   are not re-run by hand.
3. **It reaches `main` by fast-forward only** — `git merge --ff-only issue-<n>` — so `main`'s
   history *is* the branch's history, and nothing lands that was not built on the current
   tip. If the fast-forward is refused, `main` moved: rebase the branch, re-run the scenarios
   if the rebase touched the files under test, merge again.
4. **The owner reads the diff, and is the only one who pushes `main`.** Before anything leaves
   the machine: `git log origin/main..main` and `git diff origin/main..main`. Assistant
   sessions commit locally and comment on the issue — *done locally in `<sha>`, close after
   push* — and close nothing themselves. The machine account's token *can* push (§7); the
   rule is that `main` is pushed only after the owner has read it, through the push script.
   An unattended session's work may be parked on a throwaway branch on the remote as
   insurance; that branch is not `main`, is never merged from the remote side, and is deleted
   once the work is reviewed.
5. **Releases are cut only from a tag the owner made.** `tools/pack.ps1 -Release` refuses a
   dirty tree and an untagged `HEAD`, so a released `.teaa` always names a commit, and a
   `v<a.b.c>` tag must equal `addon_version` in `src/init.lua` (§6 checks this on every such
   tag push).

What this is **not**: a pull-request review flow. For the maintainer's own and the assistant's
work, the reviewer and the pusher are the same person, and a PR would add a round-trip without
adding a reader. **A PR-based review flow waits on there being an outside contributor**, not on the
repository being public — that happened on 2026-08-24, and the reviewer and the pusher are
still the same person. Contributions from outside will arrive as pull requests because that is
the only way in, and how they are reviewed and merged is decided when the first one arrives
(see [CONTRIBUTING.md](../CONTRIBUTING.md) for what a PR needs meanwhile).

Nothing above is branch protection or a ruleset, and none is to be added for this purpose:
**D-9** — the owner accepted the history-rewrite risk on 2026-08-21 and closed the question.
The fast-forward rule is a working practice, not a control, and is kept because it costs three
commands and makes the history readable.

---

## 6. Continuous integration (advisory)

`.github/workflows/check.yml` runs on every push and pull request, on `ubuntu-latest`, and
does what the pre-commit hook does on a machine that is not the maintainer's:

| Step | What it proves |
|---|---|
| `luajit -bl <file> /dev/null` over every tracked `.lua` | each file parses under LuaJIT, the game's own parser |
| `luacheck .` | zero warnings against the `.luacheckrc` that declares ToME's global surface |
| `busted` | the unit suite under LuaJIT, including `spec/dialect_spec.lua` and the manifest's homepage-vs-origin check |
| packaging check | the contents of `src/` zip with `init.lua` at the archive root, no `tools/`, `spec/` or `docs/` entry, no `src/` prefix, no backslash in any entry name, no directory entries — the rules `tools/pack.ps1` enforces |
| tag check (tag pushes only) | a `v<a.b.c>` tag equals `addon_version` in `src/init.lua` |

Two things are deliberate about how it installs its tools. The Lua tree is built with
`hererocks` into `$HOME`, **outside the workspace**, because `luacheck .` descends into
dot-directories (verified on 1.2.0) and a `.lua/` or `.luarocks/` tree in the checkout would
be linted along with the addon. And the versions are pinned to the ones the repo is written
against — luacheck 1.2.0, busted 2.3.0 — so a CI failure means the code changed, not the tool.

It is **advisory**. Three limits, and all three are known rather than hoped around:

- **It cannot block a merge while the repository is private.** Required status checks are a
  branch-protection / ruleset feature, and on GitHub's free plan those are available only on
  public repositories. Nothing blocks `--ff-only` locally either; the hook is the gate there.
- **It will not be made to block for history-protection reasons after the flip** (**D-9**:
  the owner accepted the history-rewrite risk and closed the question; §5). Whether to require *these* checks as status checks — a different purpose, catching a broken
  push rather than a rewritten one — is a separate decision, taken when the repo goes public
  (§8).
- **It cannot run the harness.** There is no game on a runner. Everything that only a live
  game can show — the LuaJIT 2.1-versus-2.0.2 library gap (`table.new` resolves in CI and
  fails in-game), stop conditions, the talent screen — is verified by `tools/scenario-*.ps1`
  on the maintainer's machine, per §5 step 2. CI proves the tree is well-formed; the harness
  proves the addon works.

What it adds over the hook is the second machine: a check that passes locally and fails in
CI is a dependency on the maintainer's PATH, rocks tree or tool version, which is exactly the
class of thing a contributor would hit first.

---

## 7. Token lifecycle

The fine-grained PAT `skoobot-reclauded-claude` is scoped to the `skoobot-reclauded` org and
**expires 2026-11-19**. Expiry is silent: calls simply start failing as unauthenticated.

After any rotation, confirm the vault actually changed by recomputing the token's SHA-256
fingerprint (first 96 bits) and comparing it to the recorded one — this verifies the change
without either party looking at the value.

Note that a repo's `.permissions` block reports the **account's role**, not the token's scope
ceiling. `push:true` there does not mean a push will succeed; the token's Contents permission
is the real gate. Do not infer token scope from that field.

**Contents is read/write**, since the first push needed it on 2026-08-21. It was read-only
before that, which meant the token structurally could not force-push or delete a branch.

That property is gone, and **the maintainer has accepted the risk rather than replacing it**
(**D-9**: the owner accepted the history-rewrite risk and closed the question): this project
does not need that level of security. `main` is deliberately unprotected. Do not add branch
protection or rulesets for it, and do not raise it as a finding — it is a closed question,
revisitable later if the project's exposure changes.

What remains is ordinary hygiene rather than a control: don't force-push `main`, and let a
history rewrite be something done on purpose rather than by accident. The push script keeps a
`git bundle` beside the repo and pushes annotated milestone tags with `--follow-tags`; both
are cheap conveniences, and neither is load-bearing. Durability of the maintainer's own
material is handled by external backups outside this project entirely.

---

## 8. Going public

The repository is private until the addon is releasable. Flipping it public is an owner
action in the repository settings — the machine account's token has no admin permission — and
is separate from *publishing* the addon on te4.org and Steam, which has its own issue (#34).
Everything below is checked before the flip, in this order, and the flip is done by the owner
with the list in hand. Worked through on **2026-08-24**; `[x]` rows were verified that day.

- [x] **The mechanical gates are green** — parse, `luacheck .`, `busted`, the harness
      scenarios untainted, and the packed artifact loading standalone
      ([release-0.1.md](release-0.1.md) §4). **The judgement gate is not a condition of the
      flip** (**D-14**, 2026-08-24): it binds 1.0.0, the first build to reach the te4.org and
      Steam listings. The flip makes a beta downloadable, not a listing. The long-term
      per-class soak (#61) is not a gate; a full level 1→15 run is not a gate (owner,
      2026-08-23).
- [x] **`src/init.lua` `homepage` is correct.** `spec/manifest_spec.lua` checks it against the
      `origin` remote, so this is already enforced; it reads
      `https://github.com/skoobot-reclauded/skoobot-reclauded`.
- [ ] **Delete the `overnight/` throwaway refs from `origin`.** They exist to be deleted
      (§2.3 of the archive's `OPERATIONS.md`) and would otherwise become public branches on
      the first day, advertising WIP that `main` already carries:
      `tools/push-branch.ps1 -Prefix overnight/<date> -List` then `-Delete`. Do this only once
      the work they insure is on `origin/main`.
- [ ] **The repository's website URL in its settings is correct.** Owner action — the bot
      token lacks admin. As of 2026-08-23 it points at `…/tree/master/docs`, and the branch is
      `main`, so the link is dead from the first visitor: set it to `…/tree/main/docs` or to
      the README.
- [ ] **`CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/bug_report.md` and
      `.github/PULL_REQUEST_TEMPLATE.md` are present and still true.** They were written while
      the repo was private and describe the public state in the future tense in places; read
      them once as a stranger would.
- [x] **The addon's documents point at nothing local-only (#43).** Re-run 2026-08-24: the
      `grep -rn -E '\.\./|research archive' CLAUDE.md README.md docs` hits are worktree
      examples that stay inside the working tree and the deliberate "never the research
      archive's clone" sentence in `first-run.md` §8. Two further sweeps were clean —
      `git grep` for `C:\…` style absolute paths over every tracked file returned nothing, and
      so did one for `localuser`, the maintainer's personal address, and the vault mechanics
      (`.kdbx`, `.dpapi`, `ClaudeSecrets`) outside `.gitignore`'s own comment about excluding
      them.
- [x] **The README banner is replaced.** The "Unreleased. No public build." block is gone;
      a beta banner, an **Installing** section and a pointer to Safety took its place
      (2026-08-24).
- [ ] **Immediately after the flip, re-check the token's effective permissions.** A
      fine-grained token gets implicit read on anything public, which is harmless; confirm
      that nothing newly public became *writable* by it that should not be, and that the
      `.permissions` field is read with §7's caveat (it reports the account's role, not the
      token's ceiling).
- [ ] **Rulesets and branch protection are NOT enabled for history protection.** **D-9**: the
      owner accepted the history-rewrite risk and closed the question. Whether to require the
      CI status checks from §6 (#30) — a different purpose — becomes technically possible at
      the flip and is a separate decision to take then, not a default to drift into.
- [x] **Decided: the decision record is not published.** **D-15** (2026-08-24) answers what
      D-7 deferred and takes D-8's option — the maintainer's archive goes to a *private* repo
      in the org, **unsanitised**, and losing it is explicitly accepted. Nothing in this
      repository depends on it: every `D-n` cited here carries its own one-line substance, so
      the public documents stand alone. Creating that repo is unscheduled and gates nothing.
- [ ] **Revisit the review flow (§5).** A PR-based flow for outside contributors is worth
      having when there are outside contributors. The fast-forward rule for the maintainer's
      own work stays unless decided otherwise.
- [ ] **Know what the flip changes for `gh` and the token — and what it does not.** The hard
      rules do not move: `gh` stays logged out (§2.2), automation still uses the machine
      account's token, and the original SkooBot is still untouchable (§2.1). What changes is
      exposure: anyone can now open issues and pull requests (so the templates and the `next`
      label do real work from day one); a leaked token would let someone act as the bot in
      public; and GitHub's secret scanning runs on public repositories, which is a reason to
      confirm — not assume — that no credential has ever been committed.
- [x] **The credential audit is done** (2026-08-24), and it covered the tracker as well as
      the tree. Every commit in the history was scanned for token shapes, private keys and
      vault paths: nothing. So were all 104 issue bodies and all 215 comments — **which this
      list had never asked for**, and which is where the only findings were: an inventory of
      what the vault holds, a machine path, and a recorded token fingerprint. No value was
      ever committed or posted. The five items were edited, the removed text kept in the
      maintainer's local notes, and the residue is a tool name plus two file extensions that
      the public `.gitignore` already carries. **The rule this leaves behind: issue bodies and
      comments are as public as code, and anything filed from now on is written that way.**
- [x] **The PAT expiry stays 2026-11-19.** Owner's decision, 2026-08-24: it is fine as it is.
      Shortening it was a suggestion, not a finding — **do not re-raise it**. Rotation is
      §1.2.1 of the maintainer's operations notes and the push scripts warn from 30 days out.

---

## 9. If the maintainer is gone

The original SkooBot did not die of technical difficulty. It died with two working
contributor fixes unmerged while the maintainer was unavailable. This section is what is
known today about avoiding that, stated plainly. Both issues that once tracked the gap — #17,
the contribution path, and #41, the bus-factor interim — are closed, and closed by being
answered rather than abandoned: the answer is the rest of this section. What is still open is
the recovery material, which is #40.

- **The org owner can do everything on GitHub.** `skoobot-reclauded` is owned by the
  `SkoobyDoo` account. That account can flip the repository public, add admins, and mint a
  new machine account or a new token for the existing one. Nothing in §2–§7 depends on the
  existing machine, vault or token surviving: a new fine-grained token on the machine
  account, configured as in §2.2 and §3, reproduces the whole setup. The mailbox is a
  separate account and is covered by the next point.
- **The recovery material for the vault and the project mailbox is held by the maintainer
  off-machine** — confirmed 2026-08-24. It lives in the maintainer's own personal vault,
  under their own backups, outside this repository and outside every repository this project
  controls. *Where* is deliberately not recorded anywhere in the project's own material: the
  operations notes are the map of the project's vault, and the recovery material for that
  vault must not be described by the same map. What matters here is that a single machine
  loss does not end the bot identity or the mailbox.
- **There will be no second org admin.** Decided by the owner, and not an open question —
  do not re-raise it, and do not file it as a risk. **This is the honest position, stated
  plainly:** the org has one human, so if that person stops answering, nobody can merge a
  pull request, change a setting, or mint a token, and the project is in the position the
  original was in. That is a cost the owner has weighed and accepted, not an oversight
  waiting to be corrected.

  What carries continuity instead is the last point in this section, and it is not nothing:
  the repository is public and GPL-3.0, so a fork needs no one's permission and loses no
  history. The difference from the original is that this time the code, the tests, the
  harness and the reasoning all travel with it.
- **The machine account can triage, once someone holds its token.** Filing, labelling,
  commenting and closing all work as the bot (§2.2), so a second admin with a fresh token can
  keep the tracker honest without touching code. Merging is a human decision; §5 does not
  change in the maintainer's absence, only who the reader is.
- **The licence is the continuity mechanism that needs nobody's permission.** This is
  GPL-3.0-or-later with the attribution chain in `NOTICE`. If the repository is public and
  unmaintained, anyone can fork it, keep the headers and the chain, and carry on — which is
  exactly how this project relates to its own predecessor. A public repository is therefore
  itself part of the answer, which is one more reason §8 matters.

---

## Where the credentials live

The vault, the wrapped master password, and the exact retrieval procedure are held by the
maintainer **outside this repository**, in material that is machine-bound, local-only and never
published. Nothing here depends on it: every rule in this document can be followed with any
fine-grained token belonging to the machine account, read from wherever the maintainer keeps
it, and the push script that wraps §2.2 is kept with that material rather than here because it
encodes one machine's layout.

If that machine is gone, the credentials are gone with it — by design. Re-establishing access
means the owner, or a second admin (§9), minting a new token; nothing here can be recovered
from this repo alone, and nothing here needs to be.
