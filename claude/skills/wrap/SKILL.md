---
name: wrap
description: End a session so the next one starts fresh with /status instead of `claude --resume`. Writes this session's follow-ups to <project>/.status/next.md (merged with what is there, deduped, capped at 10), a handoff for the next agent in .status/handoff.md when work is half-finished, and questions for the owner to the /status inbox. Works in every project and in plain folders. Use for /wrap, "wrap up", "let's stop here", "end the session", "write a handoff", "what's left for later", and before the owner closes a long session.
argument-hint: "What the next session will be about (optional)"
---

# Wrap

The next session starts with `claude` and `/status`, which shows `next.md` as **Left for later** and points to
`handoff.md` while it is fresh. Resuming a long session drags its whole context along; this replaces that.

**Writes only in the state dir** (`<main checkout>/.status/`, the same as /status, out of git through
`.git/info/exclude`): `next.md`, `handoff.md` (+ `handoff.prev.md`) and `waiting.md`. No commits, no pushes, no
doc edits. If work is uncommitted, say so in the handoff and the reply; committing is the owner's call or the
session's own work, not /wrap's.

Helper: `~/.claude/skills/wrap/wrap.sh` (`prep`, `next`, `handoff`). Three Bash calls at most.

## 1. Look (one call)

```bash
~/.claude/skills/wrap/wrap.sh prep; git status --short 2>/dev/null | head; git log --oneline @{u}.. 2>/dev/null | head
```

## 2. Follow-ups → `next.md` (always)

From your own context: what this session left undone or found for later, that the owner (or a later session)
should pick up. One line each, owner-readable, no jargon he did not use:

```markdown
- 2026-11-20 · <what>: <why it matters, a few words>. → <where to pick it up: PR/issue link, plan § or path>
```

- **Merge with the existing list:** the same item twice → one line (keep the older date, the better wording);
  an item this session finished or that is settled → drop it; unsure whether it is done → keep it.
- **Order:** most important or most blocking first; that order decides what survives the cap.
- **Cap 10.** `wrap.sh next` keeps the first ten and writes a pruned note naming the rest; prune by order, not by
  hand.
- **Not here:** questions that wait on the owner (step 3), and what a plan, issue or STATUS already tracks unless
  the line adds the pointer the next session needs.
- Nothing left for later: still run it with the merged list (it drops done items).

```bash
~/.claude/skills/wrap/wrap.sh next <<'EOF'
- …
EOF
```

## 3. Questions for the owner → the inbox

A decision, a go, a command for him to run, something to send: the /status inbox procedure (`waiting.md`, at most
7, one line, ~150 characters; see `~/.claude/skills/status/SKILL.md` § The inbox). Append in that shape, with this
session's name from `claude agents`. Inbox full: the question goes in the handoff's open questions instead, and
the reply says so.

## 4. Half-finished → `handoff.md`

Write it when the next agent would otherwise have to reconstruct state: uncommitted or unpushed work, a branch or
PR mid-way, a plan step started, an agent or deploy still running, a decision half-made, or the owner said he will
continue later. Not for finished work: then step 2 is enough (and the old handoff stays, as handoff.md; /status
stops pointing to it once a newer session ran).

Content, for an agent that has read nothing of this session (tailor it to the argument, if one was given):

```markdown
# Handoff · <project> · <YYYY-MM-DD HH:MM> · <topic in a few words>

**Goal:** <what this work is for, one or two lines>
**State:** <done / in progress / not started, as facts: branch, last commit, PR, what runs>
**Next steps:** 1. … 2. … (in order; the first one is doable without asking)
**Decisions and gotchas not written anywhere else:** <only what is not in the artifacts below>
**Open questions:** <for the owner: also in the inbox; for the agent: what to find out>
**Artifacts:** <paths and links: plan §, ADR, PR, issue, scratch files, commits; reference, never copy>
**Verify with:** <the command or check that shows it works>
**Suggested skills:** </status first; then e.g. /review-branch, /commit-strategy, a project skill>
```

- **Reference, do not duplicate:** what a plan, ADR, issue, PR, commit or diff says is a link, not a paragraph.
- **Redact secrets:** no keys, tokens, passwords, connection strings or personal data (a name is fine, an email
  address or phone number is not); name where the secret lives instead.
- Under ~60 lines. Scratch files that the next agent needs must not live in a session scratchpad or `/tmp` that a
  reboot clears: name them as such, or say what to regenerate.

```bash
~/.claude/skills/wrap/wrap.sh handoff <<'EOF'
# Handoff · …
EOF
```

## 5. Reply

```markdown
Wrapped: <n> left for later (<n> new, <n> dropped as done[, <n> pruned]); <handoff written | no handoff: nothing half-finished>; <n> asked in your inbox.
<one line per thing he should know before closing: uncommitted work, something still running>
Next time: start fresh with `claude`, then `/status` (not `claude --resume`).
```

Then the reporting block from the status skill (Waiting on you / Running / Done / Parked).
