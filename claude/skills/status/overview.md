# /status overview

One view across all projects: **the list** (one line per project, rendered by the script) and **the digest** (a short
block per project in the list, written by you from the script's facts). The view lives in
`~/projects/.status/overview.md`. The rules of SKILL.md step 3 apply (names before numbers, only checked facts, times
as `HH:MM` today and `Ddd D Mmm` otherwise).

**Read-only.** The script runs no `git fetch` and no `gh`; it reads local refs, the files and the transcripts. Never
write to a project's `.status/` from this view: do not move `seen`, do not touch `waiting.md` or `decided.md`. The only
file written is `~/projects/.status/overview.md`, and the script writes it.

## The calls: two, nothing else

```bash
~/.claude/skills/status/gather.sh overview          # ~2 s: writes the list part of overview.md, prints it plus the facts
~/.claude/skills/status/gather.sh overview --digest <<'EOF'
## Digest
...your blocks...
EOF
```

The second call replaces the digest part of overview.md with stdin and prints the whole view: that output *is* the
view, so do not repeat the list or the digest in the chat. No Read, grep or other call in between: the facts are the
whole picture. Your reply after it: at most three lines, only what the view cannot say (a doc that looks wrong, a
project that seems misfiled); nothing to add: `Done.`

From a plain shell, `gather.sh overview` refreshes the list and keeps the last digest under it, marked as older.

## The list (the script's)

```
- **<name>** · <active | maintenance> · <your last message there> · <working towards> · <attention> · you <7 d>/<4 wk> h · agents <7 d>/<4 wk> h
Other (not a project): <folders> · <n> sessions · last <when> · <hours>
Quiet (<n>: declared maintenance, or nothing in 4 weeks)
- **<name>** · <mode> · last <commit | session> <when>
```

- **Sorted** by your last typed message; projects where you never typed (in 90 days) below those, by their last
  activity of any kind (a session's last write or the newest local commit).
- **Mode:** `mode:` in the Status file, else active when you typed in a session there in the last 14 days.
- **Working towards:** the Status file's efforts in building now; else the active plans (or their resume blocks);
  else the first `.status/next.md` item; else the newest session topic; else the README.
- **Attention**, at most one, first that applies: the inbox (`waiting.md`) count; red on main per the last
  `now.md`/`arc.md` (with its date, since the overview does not ask GitHub); `standing: N`, the items in the Status
  file's waiting-on-the-owner section; uncommitted files in the checkouts.
- **Hours** from transcript timestamps: gaps under 15 minutes count as active, longer gaps not at all. *You*: the gaps
  between your own typed messages, merged across the project's sessions; *agents*: between assistant and tool events
  in the sessions and their subagents, merged (wall clock with an agent at work, so parallel agents do not add up).
- **What is a project** (`overview.conf`: roots, excludes): a git repo under a root, or a folder there with Claude
  sessions in the last 90 days. Worktrees count under their main repo. A root itself, a folder that holds projects,
  and a folder that is gone go on the Other line. The facts end with a coverage section (excluded, Other, and the
  folders that are no project) for checking; it is not part of the view.

## The digest (yours)

One block per project in the list's main group, **in the list's order**; Quiet and Other get none. A blank line
between blocks. Each block, from that project's `### <name>` facts and nothing else:

```markdown
## Digest

### <name> · <mode>
- **Goal:** <what it is for, a few words> → <what it works towards now, one line>
- **Recent:**
  - <2 to 4 lines: what got done in the last 2–4 weeks, as outcomes in the owner's words>
- **Left off:** <the last session's topic and when>; <unfinished: uncommitted work, a handoff, next.md items>; <waits on you: the inbox, the Status file's waiting-on-owner>
- *based on: <the sources you used, e.g. STATUS, roadmap, 15 commits, 8 sessions, next.md>*
```

Bullets, not bare lines: markdown joins bare consecutive lines into one paragraph in `glow`.

- **Goal**, in this order of sources: the Status file, roadmap and live plans (full level); otherwise the README's
  first paragraph. *Working towards* comes from the efforts in building now, the active plans, `next.md`, or the
  session topics. No source for the purpose: say what the sessions were about, `purpose unknown (no README)`.
- **Recent** from the commits (10 shown with a Status file or roadmap, 15 without; merge subjects are the PRs; dependency bumps are already left out, and Status-file
  updates say where things stand rather than what was done) and the session topics. Group, do not list: "Run page
  speed: one parse per worker (#385, #398)", not one line per commit. A PR or issue keeps its name before its
  number; a plan code gets its name (`MCP over OAuth (E16)`), never a bare `#123` or `E16`.
- **Left off:** the newest session's topic and date; uncommitted files and branches ahead of main (a branch ahead may
  be a squash-merged PR: say "may be merged" unless the commits show otherwise); a fresh handoff; the first one or
  two next.md items; inbox lines and the Status file's waiting-on-owner items, by name. Nothing there: `nothing
  recorded`.
- **A project with only sessions** (no README, no docs, no commits) still gets a block: Goal from the session topics
  (`seems to be: …`), Recent from the topics, Left off the newest session.
- **based on** names only sources you actually used, from the block's `based-on candidates`, with counts where the
  facts give them.
- Keep each block to about eight lines: the digest is for "where does each project stand", not a status report.

## Zoom: `/status arc <project>`

From any folder: `~/.claude/skills/status/gather.sh arc <project> --render`, where `<project>` is a name from the list
(`stocktimal`, `medi-invest/website`; a unique part of a name is enough; an ambiguous name prints the candidates).
It runs the project's ordinary `arc` there (its one fetch and its gh calls included); then follow SKILL.md's `arc`
steps as usual, writing `arc.md` in the state dir that the gather output names.
