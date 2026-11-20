---
name: status
description: Show where the current project stands in one fixed, screen-sized shape, and keep the owner's inbox. Works in every project; reads the project's planning docs through its agentic-workflow bindings when it has them, and git, gh and Claude session logs otherwise. `/status now` (the default) is what changed since the owner was away, what waits on him, what was decided for him, what runs and what got done today, and writes a pane file for a tmux side pane; `/status arc` is the efforts as Now / Next / Later with progress and maintenance (or, without planning docs, recent sessions, open PRs and unmerged work), and writes arc.md. Also defines how the orchestrator asks the owner (the inbox) and how it ends every report. Use for /status, "status?", "where are we", "what was I doing", "what's open", "what waits on me", after a session was killed, and whenever you are about to ask the owner something.
---

# Status

**Input:** `now` (the default: a bare `/status` is `now`) or `arc`.
**Output:** the view in the chat, in the template below and nothing else; `now` writes the pane file, `arc` writes
arc.md, and both update the inbox and the seen time.

**Be fast.** `/status now` is one gather call, then one Bash call that writes the files, then the view: no Read,
grep or other exploration in between. Everything the template needs is in the gather output (at full level it
prints the Status file whole) plus your own context. `arc` may read the Progress sections of the efforts in Now
(step 1.3) and nothing else.

**Read-only toward the repo and GitHub.** No commits, no doc edits (not even STATUS), no GitHub writes. The gather
script runs one `git fetch` (remote-tracking refs only). The only writes are in the state dir `.status/` in the
main checkout, which git ignores through `.git/info/exclude`: `now.md`, `arc.md`, `waiting.md`, `decided.md`,
`seen`. When the view shows something wrong in the docs (STATUS stale, a ROADMAP row that disagrees), say so in one
line under the view; fixing it is separate work.

## How the project is read

Nothing here is project-specific. The gather script works out, from the folder you run it in:

| What | How |
|---|---|
| Project key | the main checkout's folder name; a worktree maps to its main repo (`stocktimal-status-skill` → `stocktimal`); a plain folder is its own name |
| State dir | `<main checkout>/.status/` (a worktree uses its main checkout's; a plain folder its own). The gather script creates it and adds `.status/` to the repo's `.git/info/exclude`, so it never shows in `git status` (override: `STATUS_STATE_DIR`) |
| Owner | first word of `git config user.name` (Bram) |
| Repo | the GitHub `origin` remote; none means the GitHub parts are skipped |
| Level | **full** when the repo has `docs/agentic-workflow.md` and `docs/agentic-workflow.bindings.md`; **minimal** otherwise |
| Full: paths | from the bindings file: *Plans directory*, *Roadmap* (a file, or a file § section), *Session pointer* (the Status file). A role that binds to no file is printed as its binding text |
| Full: owner's gates | the bindings' *Irreversible steps* and *Integration branch* rows, plus the project's `CLAUDE.md` rules on merging, pushing and deploying |
| Project mode | `mode:` in the Status file's frontmatter (`active` or `maintenance`); otherwise inferred: `active` when the owner typed a message in a Claude session in this project (other than the one running `/status`) in the last 14 days, `maintenance` otherwise. Commits do not count: agents commit under his name. The gather output says which, and on what basis |
| Prod lag | repo variables named `*_DEPLOYED_SHA` (e.g. `PROD_DEPLOYED_SHA`), compared with the default branch; none means prod lag is unknown and deploy runs stand in |
| Bots | PR authors `app/…` or `…[bot]` (Dependabot, a CI app) |
| Housekeeping deploys | deploy runs from a schedule, a base-image or dependency bump, or a bot's merge (matched on the workflow name and run title). They are not deploys of the owner's work: never in Since you were away or Done today, only one count line under Maintenance |
| Flag labels | `blocks-go-live` and `next` (the methodology's labels; a project without them simply has none flagged) |

Gather command, from anywhere inside the project, with the view:

```bash
~/.claude/skills/status/gather.sh now    # a few seconds: one fetch, one gh call, local facts
~/.claude/skills/status/gather.sh arc    # slower: PRs, prod lag, issues, worktrees, plans, roadmap
```

**Full level, reading the Status file.** Projects name its sections differently; map them by meaning:
- *Building now*: "Building now", "▶ Now — …", "Where we are", "In flight", and any effort section above the
  waiting/parked ones (medi-automation has one section per effort);
- *Waiting on the owner*: "Waiting on the owner", "Waiting on people, not on code";
- *Parked / next*: "Parked / next", "⏭️ Next up". Sections such as "Where things run", "CI on this repo" or
  "Watch-outs" are facts, not efforts.
- **No Status file bound** (the session pointer is a block inside each plan, as in the Medi-Invest websites): Now is
  the roadmap's rows in their order, and each active plan's resume block (e.g. `## Where I left off`) is its
  state. Read only those blocks.
- **No roadmap**: leave Later and Drifting out. **No plans dir**: progress is the Status file's own words.

## Asking the owner: three tiers

Every choice you meet while working falls in one tier. This is a first calibration: the "Decided for you" block
is where the owner sees the middle tier and vetoes, and each veto or "you could have just done that" moves an
example between tiers here.

| Tier | When | What you do |
|---|---|---|
| **Ask** | irreversible; outward-facing (a customer, a partner, a lawyer, a public page); costs money; changes scope or design direction; goes against a stated preference of the owner; one of the project's owner's gates | the inbox procedure below, then wait |
| **Decide and notify** | reversible, within an established pattern, with a clear best option | do it, append a line to `decided.md`, mention it in your report |
| **Decide silently** | mechanical; a rule already decides it | do it |

Examples (the project's own gates, from its bindings and `CLAUDE.md`, come first):

- **Ask:** merging a PR to the integration branch where a PR is the gate, unless the owner already gave the go for
  that PR or batch; pushing where a push publishes or deploys; every prod deploy, same exception; any
  state-changing cloud or `gh` command (ask, then wait; never ask and run in the same turn); mail or documents to
  anyone outside; review findings sorted *needs owner*; a larger deferral where keep-or-drop is unclear; ratifying
  a plan or an ADR; a paid tier or a new cloud resource; changing an assumption the owner set.
- **Decide and notify:** review findings sorted *decided by Claude* or *decided under a rule* (applied one commit
  per topic, so a veto is a revert); a deploy to dev; filing an out-of-scope item as an issue; UI wording within
  the existing copy; a sub-agent run below the top tier; which of two equivalent fixes to take.
- **Decide silently:** lint and format fixes; regenerating generated code; resolving a conflict in generated files;
  rerunning a flaky job once; opening a draft PR; post-merge cleanup scripts; doc-only reconciles of STATUS.

When unsure between Ask and Decide and notify, ask: a wrong notify costs a revert, a wrong silent decision costs
trust.

### The inbox: `waiting.md`

The owner reads it end to end, so it is **hard-capped at 7 items, one line each, at most ~150 characters of
text** (the link's URL not counted). Detail lives behind the link (PR, plan, scratch file), never in the line.

```markdown
# <project> · waiting on <Owner>
- 2026-11-20 19:47 · <Effort or thing>: <question>? <option> / <option> → <recommendation>. Blocks: <what>. [<link name>](<url>) (<session>)
```

- The date is when it was asked; `<session>` is the asking session's name from `claude agents`.
- Kinds that belong here: a decision, a merge, a deploy go, a command for the owner to run, something to send.
  Only what a session actually put to the owner; a green PR nobody asked about is not an inbox item.

**Asking is a procedure, in this order:**

1. Write the line to `waiting.md` (append; the file is per project and shared by sessions).
2. Ask in the chat: the same question, options and recommendation, plus whatever detail the owner needs.
3. When he answers, remove the line, then act. A partial answer rewrites the line to what is still open.

**Inbox full (7 items):** do not start new work that will need something from the owner; work that needs nothing
from him continues. When a question comes up in running work, park that work (it goes on the Parked line of your
report, with the question kept in its plan or scratch file) and ask when a slot frees. The one exception is a
live prod incident (prod down, data loss or a security issue): ask it at once, even as an eighth item. Nothing else
may exceed the cap.

**`decided.md`** has the same shape, one line per decision, newest last, with what you chose and the alternative:
`- 2026-11-20 18:35 · <Effort>: <what you chose> (not <alternative>). [<link name>](<url>) (<session>)`.
Lines older than 7 days are dropped when `/status` reconciles.

## Reporting while working

The convention for every report to the owner:

- **Finished work comes as a TL;DR first** (one to three lines), then a verdict: `Worth reading the details? <yes |
  no>: <why, in one line>`. Details only when he asks.
- **Names before numbers** (step 3).
- **Every report ends with the same block**, one line each, names not numbers, `none` when empty:

```markdown
**Waiting on you:** <n of 7>: <short names, semicolon-separated>
**Running:** <what, in domain words>; …
**Done:** <since your last report>
**Parked:** <what, and what it waits for>
```

## 1. Gather

1. **Your own session first.** You are the orchestrator, so the most current facts are in your own context.
   Write down, before any tool call:
   - every subagent, background task, workflow and background command you started that has not reported back:
     what it does in domain words, the effort it serves, when it started;
   - what finished since the away moment (step 2), and what finished today;
   - questions you put to the owner that are not in `waiting.md` (a gap: add them in step 1.4).
   A finished agent whose result you have not relayed yet goes under Since you were away, not under Running.
2. **Run the gather command for the view.** Both views print the project (key, level, repo, owner, state dir),
   the bindings and the Status file whole (full level), the project mode, the other live Claude sessions in this
   project's checkouts (from `claude agents --json`), the last Claude sessions here with their topics, and the
   inbox and last day's decisions.
   - `now` adds: the away moment; what changed since then (PRs merged on the fetched default branch, deploy runs,
     failed runs on it, local commits); runs in progress and red on the default branch (from the last 60 runs);
     merged and deployed today; effort hints (which plan files name each merged PR); and where the last session
     left off (its checkout's branch, uncommitted files, commits not on the default branch).
   - `arc` adds: the remote head, deployed SHAs and the PRs the default branch is ahead by, open PRs with checks
     and a bot mark, red runs and the last deploy per workflow, issues and flagged issues, worktrees, unmerged
     branches, live plans and roadmap rows (full level).
   A section a project lacks is left out or says why. A section that says `unknown` stays unknown in the view.

   **The away moment** is the start of the most recent gap of 30 minutes or more between the owner's messages in
   this session (short messages after the gap do not end it), or the last `/status` if that is later than the
   gap's end. The gather script computes it from the session transcript and the `seen` file.
3. **Full level:** the Status file is in the gather output; do not read it again. With no Status file bound,
   read the active plans' resume blocks. For `arc`, also read the Progress / Build log / Slices section of each
   effort in Now, and nothing else of the plans. **Minimal level, and `now` at any level:** read nothing else;
   the gather output is the whole picture.
4. **Reconcile the inbox.** For each line in `waiting.md`:
   - asked by this session and answered in your context, or settled (the PR shows as merged in the gather output,
     the deploy ran): remove it;
   - older than 2 days: keep it, and mark it `(asked Ddd D Mmm, still open?)` in the view;
   - asked by a session that `claude agents` no longer lists: keep it, mark it `(asking session gone)`.
   Add any open question from step 1.1 that has no line. Drop lines older than 7 days from `decided.md`.

**Other sessions** come from the sessions section, which leaves out the session running `/status`: one line each
with name, kind, `busy`/`idle` (interactive) or state (background), last activity and branch. A background session
in state `blocked` is waiting for input: say so. Their sub-agents are not visible; their CI and deploys are, and go
under their effort like any run. Only when the sessions section says `claude agents` is unavailable, fall back to
the worktrees: files changed in the last 30 minutes in a worktree that is not yours means another session's agent
at work; name it by its branch.

## 2. The view

- `arc` given: `arc`. Anything else, or nothing: `now`.
- `arc` in mode `maintenance`: the Maintenance block first and Now / Next / Later on one line each (minimal level:
  Maintenance first, then the rest).

Under the view, one line: `Other view: /status arc` (or `now`). When the mode was inferred, one more line:
`Mode inferred: <basis from the gather output>; set mode: in STATUS to fix it` (full level with a Status file) or
just the basis (otherwise).

## 3. Rules for every line

- **Most important first.** The order of blocks is fixed; inside a block, what blocks the most work or is oldest
  goes first.
- **Names before numbers, always.** `Upload page and checks (#331)`, never `#331` alone. A PR or issue gets its
  title shortened to its meaning in the owner's words; a plan code (P6, slice 1b, A8, W11, E6) gets its name the
  first time on the screen: `Pre-launch reset (P6)`. Read the name from the plan; never invent one.
- **One line per item**, starting with the thing, then the state. No prose where a line will do; detail goes behind
  a link.
- **Blank line between blocks and between effort groups.**
- **Screen-sized:** at most about 45 lines including blank lines. When a block overflows, keep the most recent or
  most blocking and end it with `+N more (where to look)`. The Waiting block never truncates (it has at most 7).
- **Only checked facts.** Every number and name comes from step 1's output. When a source failed, write
  `unknown (gh unavailable)`; never fill from memory.
- **Times** in the owner's local time, `HH:MM` today, `Ddd D Mmm` otherwise.

Grouping by effort (full level), first match wins:
1. the Status file names the number in that effort's entry, or one of the effort's plans names it (the gather
   output's effort hints for `now`; at `arc`, `grep -lE '#391\b' <plans dir>*.md` when needed);
2. it carries `blocks-go-live`: the effort the Status file ties go-live to (e.g. a customer's test period); with
   none, it is a flagged issue under Maintenance;
3. it refers to an item already grouped (`Refs #385` where #385 is grouped), or its title or body names the effort.
A CI run or deploy goes with the PRs it carries when that is known (a deploy of main carries what prod lacks).
Everything else is **Ad hoc**: it needs no plan or issue to be listed. At minimal level everything is Ad hoc, so
leave the effort headings out and list the items directly.

## 4. `now`

```markdown
<!-- overview:now project=<project> level=<full|minimal> mode=<mode> updated=<ISO time> running=<n> waiting=<n> inbox_full=<yes|no> -->
# <project> · now · <Ddd D Mmm HH:MM>

**INBOX FULL (7 of 7): no new work that needs you; answer one to free a slot.**

## Since you were away (<HH:MM>, <duration>)
- Finished: <agent's work, in domain words> · <verdict in a few words>
- Merged: <PR name (#n)>; <PR name (#n)>
- Committed: <n> commits on <branch>: <the gist in a few words>   (only when there is no remote)
- Deployed: <env> HH:MM (<what, as names>) | <env> FAILED HH:MM
- Red on main: <workflow> since HH:MM
- New: <n> items in your inbox (<numbers>); <n> decided for you; <n> issues filed (by your sessions)
(nothing: "Nothing changed since HH:MM.")

## Where you left off                      (minimal level only)
- <Ddd D Mmm HH:MM> · <last session's topic> · <branch> (· still open)
- <one line: uncommitted files or an unmerged branch in that checkout, if any>

## Waiting on <Owner> (<n> of 7)
1. <line from waiting.md, without the date and session; age mark if older than 2 days>
Standing (STATUS): <short names, semicolon-separated>

## Decided for you (last 24h) · veto by saying which
- HH:MM <Effort>: <what was chosen>

## Running
**<Effort name>**
- <what, in domain words> · <agent / PR / CI / session> · since HH:MM

**Ad hoc**
- <what> · since HH:MM

**Other sessions**
- <session name> · <busy | idle since HH:MM | blocked: needs input> · <branch>
(nothing: "Nothing running.")

## Done today
- <Effort name>: <PR name (#n)>; <PR name (#n)>
- Deployed: dev HH:MM, prod HH:MM (prod <sha>)

Maintenance: <red on main, housekeeping deploys, in a few words> → /status arc
Other view: /status arc
```

- **The INBOX FULL line** appears only when `waiting.md` holds 7 items; otherwise leave it and its blank line out.
- **Since you were away** covers the time since the away moment from the gather output, and leaves out what the
  owner already saw (his own merges, things you told him after the gap ended). At most six lines, kinds in
  the order above, empty kinds left out. Its `New` line counts inbox and decided lines dated after the away moment.
- **Where you left off** (minimal level) answers "what was I doing": the newest entry of the last-sessions section
  (this session is already left out), and what that checkout still holds uncommitted or unmerged. Leave it out
  when there is no earlier session.
- **Waiting on <Owner>** is `waiting.md` after step 1.4, in its order, numbered. The Status file's waiting-on-owner
  items go on the Standing line (leave the line out at minimal level or when there are none). Nothing else goes
  here: a green PR, a bot PR or prod behind main are Maintenance unless a session asked the owner about them (then
  they are an inbox line).
- **Decided for you** is `decided.md`'s last 24 hours, newest first, at most five lines, then `+N more
  (decided.md)`. Leave the block out when it is empty.
- **Running** is step 1.1, the in-progress runs, and the other sessions; group by effort, Ad hoc, then Other
  sessions last. The session running `/status` is never under Other sessions.
- **Done today:** PRs merged since midnight grouped by effort (or, without GitHub, today's commits in a few
  words), and the successful deploys. One line per effort. Leave the block out when nothing was done.
- **Maintenance:** one line pointing to `arc`, from what `now` gathered only (red on main, housekeeping deploys as
  a count); bot PRs and prod lag are `arc`'s. Leave it out when there is nothing.
- **Merged** comes from the default branch after the fetch: `Title (#n)` lines. A `direct commit:` line is not a
  merge; mention it only under Done today when it says something (a STATUS update about a deploy does). When the
  gather output says the fetch failed, add `(origin not fetched)` to the Merged line.

Then write the files (step 6) in one Bash call and show the view.

## 5. `arc`

### Full level

```markdown
<!-- overview:arc project=<project> level=full mode=<mode> updated=<ISO time> -->
# <project> · arc · <Ddd D Mmm HH:MM> · <mode>[ (inferred)]

## Now
1. **<Effort name>** · <progress, e.g. 5 of 7 slices merged> · <next milestone and its date or gate> · [plan](<path>)
   - In the pipeline: <PR name (#n)>; <issue name (#n), go-live>; +N issues

## Next
- **<Effort name>** · <what it waits for>

## Later
<N> efforts: <name>; <name>; …

## Drifting
<N> efforts marked active on the ROADMAP but in neither Now nor Next: <name (plan updated date)>; …

## Maintenance
- Prod is <N> PRs behind main: <PR names>
- Bot PRs: <PR name (#n)>, <checks>, open since <date>
- Housekeeping deploys today: <n> (<workflow> ×<n>; …)[, <n> failed]
- Red on main: <workflow> since <time> | none
- Open issues: <N> (<N> opened today); flagged, no effort: <issue name (#n)>; …

Inbox: <n> of 7 → /status now
```

- **Now** is the efforts under the Status file's building-now section(s), in its order, a blank line between
  efforts; with no Status file, the roadmap's rows in order. **Next** is the parked/next entries, in order, at most
  five, then `+N more`. **Later** is every other open roadmap row, names only, at most eight, then `+N more`.
  A block with no source is left out.
- **Progress** is counted from the plan: slices or steps merged of the total the plan lists, naming the open ones.
  When a plan has no countable list, give the last milestone in under ten words. Never a percentage.
- **Drifting** is the roadmap rows whose status says Active but that are in neither Now nor Next. It is a signal for
  the owner; the skill changes no status.
- **Pipeline** under an effort: its open PRs, then its flagged issues, then a count of the rest. Flagged issues that
  match no effort go under Maintenance.
- **Prod behind main** is Maintenance, not a waiting item, unless a session asked the owner for the go. Without a
  `*_DEPLOYED_SHA` variable, write the last deploy run instead (`last prod deploy Ddd D Mmm, success`).

### Minimal level

```markdown
<!-- overview:arc project=<project> level=minimal mode=<mode> updated=<ISO time> -->
# <project> · arc · <Ddd D Mmm HH:MM> · <mode>[ (inferred)]

## Recent sessions
- <Ddd D Mmm HH:MM> · <topic> · <branch>[ · open]

## Open PRs
- <PR name (#n)> · <checks> · <draft|ready> · open since <date>

## Unmerged work
- <branch> · <N> commits ahead[ · PR #n] · <last commit, relative>
- <checkout> · <N> uncommitted files

## Maintenance
- Dependabot / bot PRs: <PR name (#n)>, <checks>, open since <date>; …
- Red on main: <workflow> since <time> | none
- Last deploy: <workflow> <Ddd D Mmm>, <outcome>
- Housekeeping deploys today: <n> (<workflow> ×<n>; …)[, <n> failed]
- Open issues: <N> (<N> opened today)

Inbox: <n> of 7 → /status now
```

- **Recent sessions:** the last-sessions section, at most five, newest first. The topic is the session's title;
  it is the "what was I doing" answer, so keep its words.
- **Open PRs** are people's PRs; bot PRs go under Maintenance. **Unmerged work** is the unmerged and worktrees
  sections: branches ahead of the default branch whose PR is not merged, and checkouts with uncommitted files. A
  branch whose PR merged (squash) is done work: leave it out.
- Leave out a block with nothing in it, and every GitHub line when there is no GitHub repo
  (`No GitHub remote: local git only.` once, under the heading).

## 6. The state files

All in the state dir from the gather output (`<main checkout>/.status/`; it already exists), written atomically
(`cat > "$f.tmp" <<'EOF' … EOF` then `mv "$f.tmp" "$f"`), so a pane never shows half a file. Write the view file,
any inbox or decided changes and `seen` in one Bash call:

| File | Written by | Content |
|---|---|---|
| `now.md` | `/status now` and a bare `/status` | the `now` view, byte for byte |
| `arc.md` | `/status arc` | the `arc` view, byte for byte |
| `waiting.md` | the asking procedure; step 1.4 | the inbox |
| `decided.md` | Decide and notify; step 1.4 prunes | the decisions |
| `seen` | every `/status` run, after the view is shown | the current time, `date -Iseconds` |

Line 1 of `now.md` and `arc.md` is a machine-readable HTML comment (the cross-project overview reads `updated=`,
`running=`, `waiting=`, `inbox_full=`, `level=` and `mode=`; `running` counts the lines under Running, `waiting`
the numbered items); line 2 is the heading with the time, so a stale pane is visible at a glance. Plain markdown, no
tables, so it reads well in `glow` and in `cat`. The files are per project, not per worktree: the last session to
write wins.

**Keeping it fresh.** After `/status now` has run once in a session, rewrite `now.md` (without printing the view)
whenever one of its lines changes: an agent starts or reports back, a question is asked or answered, a PR merges, a
deploy finishes. Reuse what you know; run `gather.sh now` again only when GitHub state changed. Do not touch
`seen` then: only a `/status` the owner sees moves it.

Opening the pane (from inside tmux, in the project; in a plain folder use `$PWD` for `p`):

```bash
p=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
tmux split-window -h -l 72 "watch -t -n5 cat $p/.status/now.md"
# with glow installed:
tmux split-window -h -l 72 "watch -t -c -n5 glow -s dark -w 70 $p/.status/now.md"
```
