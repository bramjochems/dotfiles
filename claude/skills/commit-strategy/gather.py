#!/usr/bin/env python3
"""gather.py: the facts /commit-strategy reads, as plain sections. One script for every project.

Run from anywhere inside a project:
    ~/.claude/skills/commit-strategy/gather.py [--days 30]

Read-only: no `git fetch`, no writes to the repo, to GitHub or to billing settings. Every gh call
is bounded by a timeout, and a failed one prints "unknown (...)" in its section instead of
stopping the rest. Durations from `gh run list` are wall-clock; the "billed" figures are summed
job minutes (each job rounded up to the minute) for a small sample of recent runs.
"""
import argparse
import datetime as dt
import fnmatch
import json
import math
import os
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

try:
    import yaml
except ImportError:  # parsed by regex below when PyYAML is missing
    yaml = None

NOW = dt.datetime.now(dt.timezone.utc)


def sh(*cmd, timeout=40):
    """Run a command; return (ok, stdout, stderr). Never raises."""
    env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_PAGER="cat", NO_COLOR="1")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode == 0, p.stdout, p.stderr.strip()
    except Exception as e:  # timeout, missing binary
        return False, "", str(e)


def gh_json(*args, timeout=60):
    ok, out, err = sh("gh", *args, timeout=timeout)
    if not ok:
        return None, (err.splitlines() or ["failed"])[-1][:160]
    try:
        return json.loads(out or "null"), None
    except json.JSONDecodeError as e:
        return None, f"bad json: {e}"


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def p90(xs):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, math.ceil(0.9 * len(xs)) - 1)], 1)


def short(s, n=200):
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def section(title):
    print(f"\n## {title}")


# ---------------------------------------------------------------- project
ap = argparse.ArgumentParser()
ap.add_argument("--days", type=int, default=30)
args = ap.parse_args()
DAYS = args.days
SINCE = NOW - dt.timedelta(days=DAYS)

ok, root, _ = sh("git", "rev-parse", "--show-toplevel")
in_git = ok
root = Path(root.strip()) if ok else Path.cwd()
os.chdir(root)
main_root = root
if in_git:
    ok, common, _ = sh("git", "rev-parse", "--path-format=absolute", "--git-common-dir")
    if ok:
        main_root = Path(common.strip()).parent
project = main_root.name

repo = ""
default_branch = "main"
if in_git:
    ok, url, _ = sh("git", "remote", "get-url", "origin")
    m = re.search(r"github\.com[:/]([^/]+/[^/\s]+?)(?:\.git)?\s*$", url) if ok else None
    repo = m.group(1) if m else ""
    ok, db, _ = sh("git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if ok and db.strip():
        default_branch = db.strip().split("/", 1)[1]

bindings = root / "docs/agentic-workflow.bindings.md"
level = "full" if (root / "docs/agentic-workflow.md").exists() and bindings.exists() else "minimal"
target = "docs/agentic-workflow.bindings.md" if level == "full" else "CLAUDE.md"

section("project")
print(f"key {project} · level {level} · repo {repo or 'none (no GitHub origin)'} · default branch {default_branch}")
print(f"proposal goes in: {target}{'' if (root / target).exists() else ' (does not exist yet)'}")
print(f"window: last {DAYS} days (since {SINCE:%Y-%m-%d})")
if in_git:
    fh = Path(sh("git", "rev-parse", "--git-common-dir")[1].strip() or ".git") / "FETCH_HEAD"
    if fh.exists():
        age = (NOW.timestamp() - fh.stat().st_mtime) / 3600
        print(f"local origin/{default_branch} last fetched {age:.0f} h ago (no fetch is done here)")
if repo:
    info, err = gh_json("repo", "view", repo, "--json", "visibility,isArchived,pushedAt")
    print(f"github: {info['visibility'].lower()}, archived {info['isArchived']}, last push {info['pushedAt'][:10]}"
          if info else f"github: unknown ({err})")

# ---------------------------------------------------------------- workflows
DEPLOY_RE = re.compile(
    r"azure/webapps-deploy|az containerapp (update|up|create)|az functionapp|func azure functionapp publish|"
    r"azure/functions-action|static-web-apps-deploy|swa deploy|vercel (deploy|--prod)|netlify deploy|"
    r"wrangler (deploy|publish)|firebase deploy|az deployment (group|sub) create|flyctl deploy|"
    r"\bdeploy(-|_)?(dev|prod|staging)?\.sh\b|just deploy", re.I)
BUILD_RE = re.compile(r"docker/build-push-action|az acr build|docker push|\bbuildx build\b", re.I)
ENV_RE = re.compile(r"^\s*environment:\s*(?:\n\s*name:\s*)?['\"]?([\w${}. -]+?)['\"]?\s*$", re.M)


def load_wf(path):
    text = path.read_text(errors="replace")
    data = {}
    if yaml:
        try:
            data = yaml.safe_load(text) or {}
        except Exception:
            data = {}
    on = data.get("on", data.get(True, {})) if isinstance(data, dict) else {}
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {k: None for k in on}
    on = on or {}
    conc = data.get("concurrency") if isinstance(data, dict) else None
    return {
        "file": path.name, "name": (data.get("name") if isinstance(data, dict) else None) or path.name,
        "text": text, "on": on, "conc": conc, "jobs": list((data.get("jobs") or {}).keys()) if isinstance(data, dict) else [],
    }


wfs = [load_wf(p) for p in sorted((root / ".github/workflows").glob("*.y*ml"))] if (root / ".github/workflows").is_dir() else []
by_name = {w["name"]: w for w in wfs}


def trig(w, ev):
    return ev in w["on"]


def cfg(w, ev):
    c = w["on"].get(ev)
    return c if isinstance(c, dict) else {}


def runs_on_main_push(w):
    if not trig(w, "push"):
        return False
    br = cfg(w, "push").get("branches")
    if cfg(w, "push").get("tags") and not br:
        return False
    return br is None or any(fnmatch.fnmatch(default_branch, b) for b in br)


def signals(w):
    # Comments describe other workflows ("the prod auto-deploy..."); match only the YAML itself.
    t = "\n".join(l for l in w["text"].splitlines() if not l.lstrip().startswith("#"))
    s = []
    envs = sorted({e.strip() for e in ENV_RE.findall(t) if e.strip()})
    if DEPLOY_RE.search(t) or re.search(r"deploy", w["name"] + w["file"], re.I):
        prod = any(re.search(r"prod", e, re.I) for e in envs) or re.search(r"prod", w["name"] + w["file"], re.I)
        s.append("DEPLOYS" + (" (prod)" if prod else ""))
    if BUILD_RE.search(t):
        s.append("builds images")
    if re.search(r"gh pr merge|auto-?merge", t, re.I):
        s.append("merges PRs")
    if envs:
        s.append("env " + ",".join(envs)[:60])
    return s


def describe_filters(c):
    out = []
    for k in ("branches", "paths", "paths-ignore"):
        v = c.get(k)
        if v:
            shown = ", ".join(v[:6]) + (f", +{len(v) - 6}" if len(v) > 6 else "")
            out.append(f"{k}: {shown}")
    if c.get("types"):
        out.append("types: " + ",".join(c["types"]))
    return "; ".join(out)


def draft_gate(w):
    return bool(re.search(r"draft", w["text"])) and bool(re.search(r"pull_request\.draft|draft\s*==|!.*draft", w["text"]))


section("workflows on pull requests")
pr_wfs = [w for w in wfs if trig(w, "pull_request") or trig(w, "pull_request_target")]
if not wfs:
    print("  no .github/workflows (no CI on GitHub)")
elif not pr_wfs:
    print("  none: no workflow runs on pull_request")
for w in pr_wfs:
    ev = "pull_request" if trig(w, "pull_request") else "pull_request_target"
    conc = w["conc"]
    conc_s = ""
    if isinstance(conc, dict):
        cip = conc.get("cancel-in-progress")
        conc_s = f" · concurrency cancel-in-progress={str(cip).strip()[:50]}"
    elif isinstance(conc, str):
        conc_s = " · concurrency (no cancel)"
    flt = describe_filters(cfg(w, ev))
    print(f"- {w['name']} ({w['file']}) · {ev}{' [' + flt + ']' if flt else ' [every PR, every push]'}"
          f"{' · skips drafts' if draft_gate(w) else ''}{conc_s}{' · ' + ', '.join(signals(w)) if signals(w) else ''}")

section("what a merge to main starts")
chain = {w["name"]: "push to main" for w in wfs if runs_on_main_push(w)}
changed = True
while changed:  # follow workflow_run chains from main pushes
    changed = False
    for w in wfs:
        if w["name"] in chain or not trig(w, "workflow_run"):
            continue
        ups = cfg(w, "workflow_run").get("workflows") or []
        hit = [u for u in ups if u in chain]
        if hit:
            chain[w["name"]] = f"after {hit[0]}"
            changed = True
if not chain:
    print("  nothing in GitHub Actions")
for name, why in chain.items():
    w = by_name[name]
    flt = describe_filters(cfg(w, "push")) if why == "push to main" else ""
    print(f"- {name} ({w['file']}) · {why}{' [' + flt + ']' if flt else ''}"
          f"{' · ' + ', '.join(signals(w)) if signals(w) else ''}")
other = [w for w in wfs if w["name"] not in chain and w not in pr_wfs]
if other:
    kinds = defaultdict(list)
    for w in other:
        k = "+".join(sorted(str(e) for e in w["on"].keys())) or "?"
        kinds[k].append(w["name"] + (" [deploys]" if any(s.startswith("DEPLOYS") for s in signals(w)) else ""))
    print("other workflows (not started by a merge): " + "; ".join(f"{k}: {', '.join(v)}" for k, v in kinds.items()))

hosting = []
if in_git:
    ok, files, _ = sh("git", "ls-files")
    for f in files.splitlines():
        if re.search(r"(^|/)(vercel\.json|netlify\.toml|staticwebapp\.config\.json|firebase\.json|fly\.toml|wrangler\.toml|render\.yaml|app\.yaml)$", f):
            hosting.append(f)
for d in [root, *root.iterdir()] if root.is_dir() else []:
    if d.is_dir() and (d / ".vercel/project.json").exists():
        hosting.append(str((d / ".vercel").relative_to(root)) + " (local link)")
if hosting:
    print("hosting config in repo: " + ", ".join(hosting[:6]))

if repo:
    deps, err = gh_json("api", f"repos/{repo}/deployments?per_page=100")
    if deps is None:
        print(f"github deployments: unknown ({err})")
    elif not deps:
        print("github deployments: none recorded")
    else:
        recent = [d for d in deps if ts(d["created_at"]) >= SINCE]
        c = Counter((d["environment"], (d.get("creator") or {}).get("login", "?")) for d in recent)
        on_main = sum(1 for d in recent if d.get("ref") in (default_branch, None) or len(d.get("ref", "")) == 40)
        print(f"github deployments ({DAYS}d, max 100): " + ("; ".join(f"{e} by {who} ×{n}" for (e, who), n in c.most_common(6)) or "none in window")
              + (f" · newest {deps[0]['created_at'][:16]} {deps[0]['environment']}" if deps else ""))
    vars_, err = gh_json("api", f"repos/{repo}/actions/variables?per_page=100")
    if vars_:
        dv = [v["name"] for v in vars_.get("variables", []) if re.search(r"DEPLOY|ENABLED|PAUSE", v["name"])]
        if dv:
            print("deploy-related repo variables: " + ", ".join(
                f"{v['name']}={v['value'][:12]}" for v in vars_["variables"] if v["name"] in dv)[:300])

# ---------------------------------------------------------------- branch protection
if repo:
    section("branch protection")
    ok, out, err = sh("gh", "api", f"repos/{repo}/branches/{default_branch}/protection")
    if ok:
        p = json.loads(out)
        rc = (p.get("required_status_checks") or {}).get("contexts") or []
        print(f"protected · required checks: {', '.join(rc) or 'none'} · reviews required: {'yes' if p.get('required_pull_request_reviews') else 'no'}")
    else:
        print("classic protection: " + ("not protected" if "not protected" in err.lower() else short(err, 120)))
    rules, err = gh_json("api", f"repos/{repo}/rules/branches/{default_branch}")
    print("rulesets on default branch: " + (", ".join(r["type"] for r in rules) or "none") if rules is not None else f"rulesets: unknown ({err})")

# ---------------------------------------------------------------- CI runs
runs = []
if repo and wfs:
    section(f"CI runs ({DAYS}d, wall-clock minutes)")
    runs, err = gh_json("run", "list", "-R", repo, "-L", "1000", "--created", f">={SINCE:%Y-%m-%d}", "--json",
                        "databaseId,workflowName,event,conclusion,status,createdAt,updatedAt,startedAt,headBranch,headSha",
                        timeout=120)
    if runs is None:
        print(f"unknown ({err})")
        runs = []
    else:
        oldest = min((r["createdAt"] for r in runs), default=None)
        print(f"{len(runs)} runs" + (f" (limit hit: covers only since {oldest[:10]})" if len(runs) >= 1000 else ""))
        groups = defaultdict(list)
        for r in runs:
            groups[(r["workflowName"], r["event"])].append(r)
        rows = []
        for (wn, ev), rs in groups.items():
            real = [r for r in rs if r["conclusion"] not in ("skipped",) and r["status"] == "completed"]
            durs = [(ts(r["updatedAt"]) - ts(r["startedAt"] or r["createdAt"])).total_seconds() / 60 for r in real]
            # A run whose jobs were all skipped by an `if:` still completes as success in ~0 min.
            work = [d for d in durs if d >= 1.0]
            skipped = len(rs) - len(work)
            rows.append((sum(work), wn, ev, len(rs), skipped, med(work), p90(work),
                         sum(1 for r in rs if r["conclusion"] == "cancelled"),
                         sum(1 for r in rs if r["conclusion"] == "failure")))
        rows.sort(reverse=True)
        for tot, wn, ev, n, sk, md, pn, canc, fail in rows[:12]:
            timing = f"median {md} min, p90 {pn} · ~{tot:.0f} wall-min total" if md is not None else "no run did work"
            print(f"- {wn} [{ev}] · {n} runs, {sk} skipped/<1 min · {timing} · {fail} failed, {canc} cancelled")
        if len(rows) > 12:
            print(f"  +{len(rows) - 12} smaller workflow/event pairs, ~{sum(r[0] for r in rows[12:]):.0f} wall-min together")

        def billed_sample(wn, ev, k=5):
            cand = [r for r in runs if r["workflowName"] == wn and r["event"] == ev
                    and r["conclusion"] in ("success", "failure") and r["startedAt"]
                    and (ts(r["updatedAt"]) - ts(r["startedAt"])).total_seconds() >= 60][:k]
            vals = []
            for r in cand:
                j, _ = gh_json("run", "view", str(r["databaseId"]), "-R", repo, "--json", "jobs")
                if not j:
                    continue
                m = 0
                for job in j["jobs"]:
                    if job.get("startedAt") and job.get("completedAt") and job["conclusion"] != "skipped":
                        m += math.ceil(max(0, (ts(job["completedAt"]) - ts(job["startedAt"])).total_seconds()) / 60)
                vals.append(m)
            return vals

        heavy_pr = next((r for r in rows if r[2] == "pull_request"), None)
        heavy_push = next((r for r in rows if r[2] == "push"), None)
        for r in (heavy_pr, heavy_push):
            if r:
                b = billed_sample(r[1], r[2])
                if b:
                    print(f"billed sample, {r[1]} [{r[2]}]: last {len(b)} real runs {b} job-min → median {med(b)}")
        MAIN_CI = heavy_pr[1] if heavy_pr else None

# ---------------------------------------------------------------- PRs and pushes
prs = []
if repo:
    section(f"pull requests ({DAYS}d)")
    prs, err = gh_json("pr", "list", "-R", repo, "--state", "all", "-L", "300", "--search", f"created:>={SINCE:%Y-%m-%d}",
                       "--json", "number,title,author,isDraft,state,createdAt,mergedAt,headRefName", timeout=90)
    if prs is None:
        print(f"unknown ({err})")
        prs = []
    else:
        is_bot = lambda p: p["author"].get("is_bot") or p["author"]["login"].endswith("[bot]") or p["author"]["login"].startswith("app/")
        people = [p for p in prs if not is_bot(p)]
        bots = [p for p in prs if is_bot(p)]
        print(f"people: {len(people)} opened, {sum(1 for p in people if p['mergedAt'])} merged, "
              f"{sum(1 for p in people if p['state'] == 'OPEN')} open ({sum(1 for p in people if p['state'] == 'OPEN' and p['isDraft'])} draft)")
        lead = [(ts(p["mergedAt"]) - ts(p["createdAt"])).total_seconds() / 3600 for p in people if p["mergedAt"]]
        if lead:
            print(f"people PRs open→merged: median {med(lead)} h, p90 {p90(lead)} h")
        bc = Counter(p["author"]["login"] for p in bots)
        print(f"bots: {len(bots)} PRs ({', '.join(f'{k} ×{v}' for k, v in bc.most_common()) or 'none'}), "
              f"{sum(1 for p in bots if p['mergedAt'])} merged, {sum(1 for p in bots if p['state'] == 'CLOSED' and not p['mergedAt'])} closed unmerged, "
              f"{sum(1 for p in bots if p['state'] == 'OPEN')} open now")
        if runs:
            branch_author = {p["headRefName"]: is_bot(p) for p in prs}
            prr = defaultdict(list)
            for r in runs:
                if r["event"] == "pull_request":
                    prr[r["headBranch"]].append(r)
            pushes = [len({r["headSha"] for r in rs}) for b, rs in prr.items() if not branch_author.get(b, False)]
            if pushes:
                print(f"pushes per people-PR branch (distinct head SHAs with a PR run): median {med(pushes)}, p90 {p90(pushes)}, max {max(pushes)} over {len(pushes)} branches")
            if MAIN_CI:
                billed_per, quick = [], 0
                for b, rs in prr.items():
                    if branch_author.get(b, False):
                        continue
                    real = sorted((r for r in rs if r["workflowName"] == MAIN_CI and r["conclusion"] not in ("skipped",)
                                   and r["startedAt"] and (ts(r["updatedAt"]) - ts(r["startedAt"])).total_seconds() >= 60),
                                  key=lambda r: r["createdAt"])
                    if not real:
                        continue
                    billed_per.append(len(real))
                    quick += sum(1 for a, c in zip(real, real[1:]) if (ts(c["createdAt"]) - ts(a["createdAt"])).total_seconds() < 1800)
                if billed_per:
                    print(f"real '{MAIN_CI}' runs per people-PR branch: median {med(billed_per)}, p90 {p90(billed_per)}, "
                          f"max {max(billed_per)}; {quick} follow-up runs came <30 min after the previous one")

        open_prs, _ = gh_json("pr", "list", "-R", repo, "--state", "open", "-L", "40", "--json", "number,title,isDraft,files")
        pend = [p for p in open_prs or [] if any(re.search(r"^\.github/(workflows/|dependabot)|(^|/)CLAUDE\.md$|agentic-workflow\.bindings\.md$|\.claude/agents/", f["path"]) for f in p.get("files") or [])]
        for p in pend:
            print(f"pending change to CI or rules: {short(p['title'], 90)} (#{p['number']}{', draft' if p['isDraft'] else ''})")

# ---------------------------------------------------------------- main branch history
DOC_RE = re.compile(r"(^docs/|\.md$|^\.claude/|^plans/|^\.planning/|(^|/)check-docs\.\w+$)")
if in_git:
    section(f"commits landing on {default_branch} ({DAYS}d, first parent, local origin/{default_branch})")
    ref = f"origin/{default_branch}" if sh("git", "rev-parse", "-q", "--verify", f"origin/{default_branch}")[0] else default_branch
    ok, out, _ = sh("git", "log", ref, "--first-parent", f"--since={SINCE:%Y-%m-%d}", "--format=@@%H%x09%P%x09%s", "--name-only", timeout=60)
    merges = direct_doc = direct_code = squash = 0
    code_dirs = Counter()
    for block in out.split("@@")[1:]:
        lines = [l for l in block.splitlines() if l.strip()]
        sha, parents, subj = (lines[0].split("\t") + ["", ""])[:3]
        files = lines[1:]
        if len(parents.split()) > 1:
            merges += 1
        elif re.search(r"\(#\d+\)\s*$", subj):
            squash += 1
        elif files and all(DOC_RE.search(f) for f in files):
            direct_doc += 1
        else:
            direct_code += 1
            code_dirs.update({f.split("/")[0] for f in files if not DOC_RE.search(f)})
    print(f"PR merges {merges} · squash merges {squash} · direct doc-only commits {direct_doc} · direct commits touching code {direct_code}"
          + (f" (top dirs: {', '.join(f'{d} ×{n}' for d, n in code_dirs.most_common(5))})" if direct_code else ""))
    ok, last, _ = sh("git", "log", ref, "-1", "--format=%ad", "--date=short")
    print(f"last commit on {ref}: {last.strip()}")

# ---------------------------------------------------------------- bots config
section("bot config")
dep = root / ".github/dependabot.yml"
if dep.exists() and yaml:
    try:
        d = yaml.safe_load(dep.read_text()) or {}
        for u in d.get("updates", []):
            dirs = u.get("directories") or [u.get("directory")]
            groups = list((u.get("groups") or {}).keys())
            print(f"- dependabot {u.get('package-ecosystem')} {','.join(map(str, dirs))[:50]} · {u.get('schedule', {}).get('interval')} · "
                  f"{'groups: ' + ','.join(groups) if groups else 'UNGROUPED'} · limit {u.get('open-pull-requests-limit', 5)}")
    except Exception as e:
        print(f"dependabot.yml unparsable: {e}")
elif dep.exists():
    print("dependabot.yml present (PyYAML missing; read it by hand)")
else:
    print("no dependabot.yml")
for f in ("renovate.json", ".github/renovate.json", "renovate.json5"):
    if (root / f).exists():
        print(f"renovate config: {f}")
merger = [w["name"] for w in wfs if re.search(r"gh pr merge|enable-auto-merge|automerge", w["text"], re.I)]
if merger:
    print("auto-merge workflows: " + ", ".join(merger))
bot_ci = [w["name"] for w in wfs if re.search(r"user\.type\s*==\s*'Bot'|\[bot\]|dependabot", w["text"]) and (trig(w, "pull_request") or trig(w, "pull_request_target"))]
if bot_ci:
    print("PR workflows with bot-specific logic: " + ", ".join(bot_ci))

# ---------------------------------------------------------------- existing rules
section("existing rules about PRs, main, pushes, CI")
RULE_RE = re.compile(r"(\bPRs?\b|pull request|\bdraft\b|ready for review|gh pr ready|doc-only|docs-only|"
                     r"(push|commit|merge)\w* (straight |directly )?(to|on(to)?) `?main|reaches `?main|auto-?deploy|deploys? on)", re.I)
for f in ("CLAUDE.md", "AGENTS.md", "docs/agentic-workflow.bindings.md", ".claude/agents/coding.md"):
    p = root / f
    if not p.exists():
        continue
    hits = [(i, l) for i, l in enumerate(p.read_text(errors="replace").splitlines(), 1) if RULE_RE.search(l)]
    print(f"{f}: {len(hits)} matching lines" + ("" if hits else " (no rule on this)"))
    for i, l in hits[:8]:
        print(f"  {i}: {short(l, 260)}")
    if len(hits) > 8:
        print(f"  +{len(hits) - 8} more")
hooks = []
ok, hp, _ = sh("git", "config", "core.hooksPath")
for d in ("scripts/githooks", ".githooks", ".husky", "githooks"):
    if (root / d).is_dir():
        hooks += [f"{d}/{x.name}" for x in sorted((root / d).iterdir())
                  if x.is_file() and not x.name.startswith("_") and not x.name.endswith(".sample")]
if (root / ".pre-commit-config.yaml").exists():
    hooks.append(".pre-commit-config.yaml")
hp = hp.strip()
installed = [x.name for x in Path(hp).iterdir() if x.is_file() and not x.name.endswith(".sample")] if hp and Path(hp).is_dir() else []
print("git hooks in repo: " + (", ".join(sorted(set(hooks))[:8]) if hooks else "none")
      + (f" · installed in {hp}: {', '.join(sorted(installed)) or 'none'}" if hp else ""))

# ---------------------------------------------------------------- doc-only
section("doc-only candidates")
ign = set()
for w in pr_wfs:
    c = cfg(w, "pull_request")
    ign.update("!" + x for x in c.get("paths-ignore") or [])
    ign.update(x for x in c.get("paths") or [] if x.startswith("!"))
if ign:
    print("ignored by PR workflows: " + ", ".join(sorted(ign)[:12]))
if in_git:
    ok, out, _ = sh("git", "grep", "-n", "-I", "-E", r"""['"/]docs/[A-Za-z0-9_./-]+\.md|['"/][A-Za-z0-9_./-]*README\.md|['"]docs['"] */""",
                    "--", ":(glob)**/*test*", ":(glob)**/*spec*", ":(glob)**/tests/**")
    # Keep lines that read the file; an ADR named in an assertion message is not a dependency.
    hits = [h for h in out.splitlines() if re.search(r"read_text|open\(|readFile|read\(|Path\(|path\.join|/ ", h)]
    print(f"tests that read a doc file: {len(hits)}" + ("" if hits else " (none found)"))
    for h in hits[:5]:
        print("  " + short(h, 180))
print()
