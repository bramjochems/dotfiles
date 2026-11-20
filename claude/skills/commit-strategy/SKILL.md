---
name: commit-strategy
description: Assess one project qualitatively (does a merge deploy, how risky is a change, how costly is CI, how much do agents push, what is doc-only, how many bot PRs) and propose how work reaches main there - straight to main, a PR with CI on each push, or a draft PR marked ready once per review round; how pushes are batched; how bot PRs are handled; which paths count as doc-only. Proposes a ready-to-paste section for the bindings or CLAUDE.md plus CI changes; never writes them. Use for /commit-strategy, "how should agents commit/push/PR here", "PR strategy for this project", or when CI minutes or PR churn look out of proportion.
---

# Commit strategy

**Input:** nothing (the project you are in), or `--days N` for the gather window (default 30).
**Output:** one screen in the chat, in the template below: a TL;DR, six short answers, a proposed section to
paste, CI changes as suggestions, and what is unknown.

**Proposes, never writes.** Read-only toward the repo, GitHub and billing: no commits, no doc or workflow edits, no
`gh` writes, no `git fetch`. The owner approves the section and applies it, or tells an agent to.

## Why per project

Commits cost nothing. **Pushes that start CI, and merges that start builds or deploys, are what cost**: minutes,
noise, and on some projects a production publish. Stocktimal's analysis (`~/projects/meta/overview/analysis/
churn-actions.md`) showed one rule cannot fit every repo: there a ready-PR push costs ~17 billed minutes and a merge
deploys nothing, so pushes are rationed; on a cheap-CI site that deploys on every merge, a push per change is fine
and the merge is the event that matters. So the strategy is read from the project's own facts each time.

The owner's standing preference (it is the default, not something to argue against): small, locally verified and
doc-only changes merge locally and push; PRs are for changes that need CI to validate what cannot be checked
locally, or where a reviewed record is wanted.

## The patterns

A strategy assigns one route to each kind of change, plus one rule for bot PRs. Use these names in the output.

| Pattern | What agents do | Fits when |
|---|---|---|
| **direct-to-main** | Commit on `main` (or merge locally with `--no-ff`), run the local gate, push once per batch. | The change is doc-only here (see below); or the whole project is solo/dormant: no parallel work, a merge deploys nothing, and the local gate is the same as CI's. |
| **PR, CI per push** | Branch, open a normal PR, push; every push runs CI. Merge on a green head. | CI is cheap (about 10 billed minutes or less per run) and agents push little (median about one real CI run per PR). Batching would save little and drafts would add a step. |
| **draft PR, ready once** | Open the PR as a draft (CI skips drafts or runs only cheap checks). Mark it ready once when done: that runs CI. A review round: commit per topic, push once at the end of the round, then run CI once (toggle ready, or the project's equivalent). | CI is costly (about 15 billed minutes or more, or slow enough that people wait) or agents push often (two or more real runs per PR, many follow-ups under 30 minutes apart). |
| **full PR gate** | An overlay on either PR pattern: no exceptions for "small" code changes, merge only with green CI on the exact head commit, and the owner's go before merging. Emergencies only with a follow-up record. | A merge publishes to production by itself, or the change touches a high-risk area (migrations, auth/tenancy, infra and IAM, the deploy chain, payments), or CI runs checks nobody can run locally. |
| **bot PRs** | Bots keep CI on every push (they cannot toggle draft and they force-push refreshes). Too many? Group them (Dependabot `groups`, one group across `directories`, a slower `schedule`) rather than skip CI. Auto-merge green non-major bumps only where CI covers what the merge ships. | Always, for every project with Dependabot, Renovate or a CI app opening PRs. |

**Pushes, everywhere:** commit as finely as traceability wants (one commit per topic, STATUS on its own); push once
per batch or per review round, not per commit. This is the same in every pattern; only the cost of breaking it
differs.

**Doc-only here** means: paths that (1) the PR workflows ignore or check only cheaply, (2) no test reads (the gather
lists tests that read a doc file; such a doc is code for routing), and (3) change nothing a merge ships, or
ship identical output (a rebuild of unchanged code counts as identical). Name the paths and the exceptions.

## 1. Gather

```bash
~/.claude/skills/commit-strategy/gather.py            # from anywhere inside the project
```

It prints: level and target file; PR workflows with their path filters, draft gates and concurrency; what a merge to
main starts (following `workflow_run` chains) with deploy and image-build signals; hosting config and GitHub
deployments (Vercel shows up there as `Production by vercel[bot]`); deploy-related repo variables (a pause switch
shows here); branch protection; CI runs per workflow and event (wall-clock median and p90, skipped, failed,
cancelled) and a billed sample (summed job minutes) for the heaviest PR and push workflow; PRs by people and bots,
pushes and real CI runs per PR branch; open PRs that change CI or the rules; what landed on main (merges vs direct
doc-only vs direct code commits); Dependabot entries with grouping; existing rules in `CLAUDE.md`, `AGENTS.md`, the
bindings and `.claude/agents/coding.md`; git hooks; doc-only candidates.

Then read, and only this:
- the rule lines the gather quotes, in full, so you know what the proposal replaces;
- for any workflow marked `DEPLOYS` that a merge starts, its top comment, to tell prod from dev and automatic from
  conditional;
- with hosting config (Vercel, Netlify, Static Web Apps), its build-skip setting (`ignoreCommand` etc.) and any
  decision record about it, so you do not propose undoing a deliberate choice;
- a *pending change to CI or rules* (an open PR): read its description. Assess the project **as it will be once that
  PR lands**, and say so in the TL;DR.

When the run list hit its limit, the per-PR figures cover a shorter window than the PR counts: say "in the last N
days" with the window it printed. Wall-clock time understates cost when jobs run in parallel; use the billed sample
for cost, wall-clock for "do people wait".

## 2. Answer the six questions

One line each: the answer as a word or short phrase first, then the evidence in names.

1. **Does a merge deploy, and where?** nothing / CI only / image builds / dev / **prod, automatically**. Name the
   mechanism (Vercel Git integration, a `workflow_run` chain, a pause switch that is off).
2. **How risky is a typical change, and what can only CI catch?** From the areas of recent merges and the gates:
   checks that cannot run locally (container scans, Bicep build, a suite that takes an hour locally, a hosted build).
3. **How costly and slow is CI?** cheap / moderate / costly, from the billed sample; slow if the p90 wall time makes
   an agent wait.
4. **How much do agents push?** low / high, from real CI runs per people-PR branch and quick follow-ups. Also: are
   commits already landing direct on main, and are they doc-only?
5. **What is doc-only here?** The paths, and the exceptions (docs read by tests, content that ships).
6. **Bot PRs:** volume per month, share closed unmerged (superseded), grouping, auto-merge, and whether the bot's
   merges deploy.

## 3. Pick the strategy

Work it out per change kind, in this order; the first match wins.

1. **No GitHub remote:** everything direct-to-main; pushing is backup, not publishing. Stop; there is no CI to tune.
2. **Doc-only changes:** direct-to-main when doc-only is non-empty by the definition above. With deploy-on-merge, the
   push is still a publish, so it keeps whatever owner go the project requires for a publish; batch them.
3. **Solo or dormant project** (no PRs by people in the window, no other sessions, a merge deploys nothing, local gate
   equals CI): code direct-to-main too; a PR only for dependency refreshes and for anything needing CI-only checks.
4. **Code in a project with parallel work:** PR, CI per push when CI is cheap and pushes are low; draft PR, ready once
   when either is not. Add the **full PR gate** when question 1 says prod, automatically, or for the high-risk
   areas named in question 2 (gate only those areas when the rest is low-risk).
5. **Bot PRs:** CI on every push, always. Propose grouping when there are more than about one bot PR per week per
   ecosystem or many close unmerged; propose auto-merge only when CI covers what a merge ships.

Then compare with the existing rules the gather quoted. Most projects already have some: say **matches**, **sharpens**
(same intent, adds a missing case), or **changes** (a different route), and for a change, the evidence that justifies
it. Prefer replacing the existing rule text to adding a second one that says nearly the same.

Every route gets a one-line **because** with the deciding fact, and the section ends with **Revisit when**: the facts
that would flip the choice (CI cost doubling, deploy-on-merge turned on or off, a second agent working in parallel,
bot volume). That is what lets a later agent see the strategy no longer fits.

## 4. Output

At most about 50 lines including the pasted section. Names before numbers: `the dependency refresh (#8)`, not `#8`;
a workflow by its name, not its file, unless the file is the instruction.

````markdown
# <project> · commit strategy · <Ddd D Mmm>
**TL;DR:** <code route>; <doc-only route>; <bot rule>. <one line: the two facts that decide it>.
<matches | sharpens | changes> the current rule (<where>)<: what changes>.

## Answers
- **Merge deploys:** <answer> · <evidence>
- **Risk / CI-only checks:** <answer> · <evidence>
- **CI cost:** <cheap | moderate | costly> · <billed min per run, wall median/p90>
- **Agent pushes:** <low | high> · <real runs per PR, quick follow-ups, direct commits>
- **Doc-only:** <paths>; except <exceptions>
- **Bots:** <volume, grouping, auto-merge, whether their merges deploy>

## Proposed section · for <target file> (<replaces | sits next to> <existing rule>)
```markdown
### Commit, push and PR strategy
| Change | Route | Because |
|---|---|---|
| Doc-only: <paths> | <route + local gate> | <fact> |
| <code / area> | <route> | <fact> |
| Review fixes | Commit per topic; push once per round; <how CI runs once> | <fact> |
| Bot PRs | <rule> | <fact> |
| Merging | <condition + whose go> | <fact> |

**Revisit when:** <fact that would flip it>; <another>.
```

## CI changes worth making · suggestions, nothing applied
1. <change> · <what it fixes, in a few words> · <cost or risk>

**Unknown:** <what the gather could not read>   (leave out when nothing)
````

- In the bindings (full level) the section goes under the bindings table, before "Deliberate deviations"; in
  `CLAUDE.md` (minimal level), next to the existing rule on commits and pushing, or at the end of the rules.
- **CI changes:** at most four, most valuable first. Typical ones: a draft gate on the costly PR workflow; dropping
  `synchronize` plus a bot-only caller (as stocktimal PR #399 does); skipping main's CI when the PR already tested
  the merged tree; `cancel-in-progress` only for PRs, so main runs queue; a filter gap where a test reads an ignored
  path; Dependabot grouping across directories or a slower schedule. Leave out a change the project's decision
  records already rejected, unless the facts changed (say which).
- **Only checked facts.** Every number and name comes from the gather or the files you read. A failed source is
  `unknown (<reason>)`, never filled from memory.
