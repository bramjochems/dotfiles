#!/usr/bin/env python3
"""waves.py: where a project's waves stand, read-only.

    waves.py [PATH] [--json | --attention | --line] [--offline] [--cache]

A wave is a plan file with `issues: [...]` in its frontmatter and a done-criterion (`done:`); the ROADMAP's
`## Now` / `## Next` / `## Later` sections give the order, one line per wave linking its plan
(docs/agentic-workflow.md §2-3). PATH is any folder in the project (default: the cwd).

Reads the bindings (`docs/agentic-workflow.bindings.md`: Plans directory, Roadmap, Now cap; default cap 3),
every plan's frontmatter, the ROADMAP sections, and issue states from ONE
`gh issue list --state all --limit 1000` call. Reports the Now waves with progress, the Next/Later counts and
what needs attention: close due (all listed issues closed, or the plan unchanged in git for 14 days), listed
issues that don't exist, Now above the cap, and live plans (proposed/active) with no ROADMAP line.

Output: a short text form (default); `--json` (for the views); `--attention` (one line per attention item,
nothing when there is none: /status now); `--line` (at most one quiet line: the SessionStart hook).
`--offline`: no gh; issue states come from the cache in <main checkout>/.status/waves-issues.json, when there
is one. `--cache`: after a successful gh call, write that cache (only /status passes it; the state dir must
already exist). Nothing else is ever written. Standard library only.
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

STALE_DAYS = 14
DEFAULT_CAP = 3
HUBS = {"STATUS.md", "ROADMAP.md", "README.md", "BACKLOG.md"}
LIVE = {"proposed", "active"}
CACHE = "waves-issues.json"
SECTIONS = ("now", "next", "later")


def run(cmd, cwd, timeout=10):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace", timeout=timeout,
                           env={**os.environ, "GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0"})
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


# ------------------------------------------------------------------ project and bindings
def project(path):
    path = os.path.abspath(path)
    rc, top, _ = run(["git", "rev-parse", "--show-toplevel"], path)
    if rc != 0:
        return {"root": path, "main": path, "git": False}
    top = top.strip()
    _, common, _ = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], top)
    return {"root": top, "main": os.path.dirname(common.strip()) or top, "git": True}


def binding(text, role):
    for line in text.replace("\\|", "/").splitlines():
        c = line.split("|")
        if line.startswith("|") and len(c) > 3 and re.search(role, c[1].strip(), re.I):
            return c[2].strip()
    return ""


def first_code(s):
    m = re.search(r"`([^`]*)`", s)
    return m.group(1) if m else ""


def bindings(root):
    b = read(os.path.join(root, "docs", "agentic-workflow.bindings.md"))
    out = {"bound": bool(b), "plans": "", "roadmap": "", "cap": DEFAULT_CAP, "cap_source": "default"}
    if b:
        out["plans"] = first_code(binding(b, r"^Plans directory"))
        out["roadmap"] = first_code(binding(b, r"^Roadmap"))
        cap = binding(b, r"^Now cap")
        m = re.search(r"\d+", cap)
        if m:
            out["cap"], out["cap_source"] = int(m.group()), "bindings"
    if not out["plans"]:  # before the bindings exist: the usual places
        for guess in (".planning/", "docs/planning/", "docs/plans/"):
            if os.path.isdir(os.path.join(root, guess)):
                out["plans"], out["plans_guessed"] = guess, True
                break
    if out["plans"] and not out["plans"].endswith("/"):
        out["plans"] += "/"
    if not out["roadmap"] and out["plans"] and os.path.isfile(os.path.join(root, out["plans"], "ROADMAP.md")):
        out["roadmap"] = out["plans"] + "ROADMAP.md"
    return out


# ------------------------------------------------------------------ plans
def frontmatter(text):
    """`key: value` lines of a leading --- block (or, failing that, the first 12 lines)."""
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        block = []
        for l in lines[1:]:
            if l.strip() == "---":
                break
            block.append(l)
    else:
        block = lines[:12]
    fm = {}
    for l in block:
        m = re.match(r"^([a-z_]+):\s*(.*)$", l)
        if m and m.group(1) not in fm:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def issue_list(v):
    """`[1, 2]`, `1, 2`, `#1 #2` -> [1, 2]; None when the key is absent."""
    if v is None:
        return None
    return [int(x) for x in re.findall(r"\d+", v)]


def unquote(s):
    s = (s or "").strip()
    return s[1:-1] if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"" else s


def plans(root, pdir):
    out = {}
    d = os.path.join(root, pdir)
    if not pdir or not os.path.isdir(d):
        return out
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".md") or fn in HUBS:
            continue
        text = read(os.path.join(d, fn))
        fm = frontmatter(text)
        title = next((l[2:].strip() for l in text.splitlines() if l.startswith("# ")), "") or fn[:-3]
        title = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", title).replace("**", "").replace("`", "")
        done = unquote(fm.get("done", ""))
        if not done:  # a "**Done when:** ..." line in the body
            m = re.search(r"^\*\*Done(?: when| criterion)?:?\*\*:?\s*(.+)$", text, re.M | re.I)
            done = m.group(1).strip() if m else ""
        out[fn] = {"file": pdir + fn, "status": fm.get("status", "").split(" ")[0], "kind": fm.get("kind", ""),
                   "issues": issue_list(fm.get("issues")), "done": done, "title": title}
    return out


# ------------------------------------------------------------------ roadmap
LINK = re.compile(r"\]\(([^)\s#]+\.md)(?:#[^)]*)?\)")


def roadmap(root, rpath):
    """-> (structured?, {now|next|later: [{"line", "name", "plan"}]})."""
    text = read(os.path.join(root, rpath)) if rpath else ""
    secs = {k: [] for k in SECTIONS}
    cur, lvl, found = None, 0, False
    for line in text.splitlines():
        m = re.match(r"^(#+)\s+(.*)$", line)
        if m:
            word = re.sub(r"[^a-z]", " ", m.group(2).lower()).split()
            if word and word[0] in SECTIONS:
                cur, lvl, found = word[0], len(m.group(1)), True
                continue
            if cur and len(m.group(1)) <= lvl:
                cur = None
            continue
        if not cur:
            continue
        s = line.strip()
        if not (re.match(r"^([-*]|\d+\.)\s+", s) or (s.startswith("|") and not re.match(r"^\|[\s:|-]+$", s))):
            continue
        if s.startswith("|") and not LINK.search(s) and re.search(r"\b(effort|wave|goal|plan)\b", s, re.I) \
                and not re.search(r"\w{12,}", s):  # a table header row
            continue
        lk = LINK.search(s)
        plan = os.path.basename(lk.group(1)) if lk else ""
        name = re.sub(r"^([-*]|\d+\.)\s+", "", s).strip("| ")
        name = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", name).replace("**", "").replace("`", "")
        name = re.split(r"\s+[·|—–]\s+|\s+-\s+|:\s", name)[0].strip()
        secs[cur].append({"line": s, "name": name, "plan": plan})
    return found, secs


# ------------------------------------------------------------------ issues
def repo_of(root):
    rc, url, _ = run(["git", "remote", "get-url", "origin"], root)
    m = re.match(r"^(?:https://|git@|ssh://git@)github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url.strip()) if rc == 0 else None
    return m.group(1) if m else ""


def issues(proj, offline, cache):
    """-> ({number: {"state", "title"}} or None, source note)."""
    if not proj["git"]:
        return None, "not a git repo: no issues"
    repo = repo_of(proj["root"])
    if not repo:
        return None, "no GitHub remote: issue states unknown"
    cpath = os.path.join(os.environ.get("STATUS_STATE_DIR") or os.path.join(proj["main"], ".status"), CACHE)
    if offline:
        try:
            c = json.loads(read(cpath))
            got = {int(k): v for k, v in c["issues"].items()}
            return got, f"cached {c['fetched'][:16].replace('T', ' ')}"
        except (ValueError, KeyError, TypeError):
            return None, "offline, no cached issue states (run /status)"
    rc, out, err = run(["gh", "issue", "list", "-R", repo, "--state", "all", "--limit", "1000",
                        "--json", "number,state,title"], proj["root"], timeout=8)
    try:
        data = json.loads(out) if rc == 0 else None
    except ValueError:
        data = None
    if not isinstance(data, list):
        why = (err.strip().splitlines() or ["failed"])[-1][:80]
        return None, f"gh unavailable ({why}): issue states unknown"
    got = {d["number"]: {"state": d["state"].lower(), "title": d["title"]} for d in data}
    if cache and os.path.isdir(os.path.dirname(cpath)):
        tmp = cpath + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"fetched": datetime.now().astimezone().isoformat(timespec="seconds"), "repo": repo,
                           "issues": got}, f)
            os.replace(tmp, cpath)
        except OSError:
            pass
    note = f"gh {repo}" + (" (1000 issues: the oldest may be missing)" if len(data) >= 1000 else "")
    return got, note


def last_change(root, rel):
    """Unix time of the last commit that touched the file; None when untracked or not in git."""
    rc, out, _ = run(["git", "log", "-1", "--format=%ct", "--", rel], root)
    return int(out.strip()) if rc == 0 and out.strip().isdigit() else None


# ------------------------------------------------------------------ the report
def collect(path=".", offline=False, cache=False):
    proj = project(path)
    root = proj["root"]
    b = bindings(root)
    ps = plans(root, b["plans"])
    structured, secs = roadmap(root, b["roadmap"])
    rep = {"project": os.path.basename(proj["main"]), "path": root, "plans_dir": b["plans"] or None,
           "plans_guessed": bool(b.get("plans_guessed")), "roadmap": b["roadmap"] or None,
           "cap": b["cap"], "cap_source": b["cap_source"], "structured": structured,
           "now": [], "next": [], "later": [], "unlisted_waves": [], "drift": [], "attention": [],
           "issues_source": "", "notes": []}
    wave_plans = {fn for fn, p in ps.items() if p["issues"] is not None}
    if not structured and not wave_plans:
        rep["state"] = "no waves yet"
        if b["roadmap"] and os.path.isfile(os.path.join(root, b["roadmap"])):
            rep["notes"].append(f"ROADMAP isn't structured yet (no ## Now / ## Next / ## Later in {b['roadmap']})")
        return rep
    iss, rep["issues_source"] = issues(proj, offline, cache)
    now = time.time()

    def wave(entry, fn, section):
        p = ps.get(fn)
        w = {"name": entry.get("name") if entry else "", "plan": p["file"] if p else (fn or None),
             "status": p["status"] if p else None, "title": p["title"] if p else None,
             "done": p["done"] if p else "", "issues": (p["issues"] if p else None) or [],
             "closed": None, "open": None, "missing": [], "close_due": []}
        w["name"] = w["title"] or w["name"] or fn
        if not p:
            if section == "now":
                rep["attention"].append({"kind": "no-plan", "text": f"Now wave without a plan file: {w['name']}"})
            return w
        if iss is not None and w["issues"]:
            known = [n for n in w["issues"] if n in iss]
            w["missing"] = [n for n in w["issues"] if n not in iss]
            w["closed"] = sum(iss[n]["state"] == "closed" for n in known)
            w["open"] = len(known) - w["closed"]
            if w["missing"]:
                nums = ", ".join(f"#{n}" for n in w["missing"])
                rep["attention"].append({"kind": "missing-issue",
                                         "text": f"{w['name']} lists {nums}: no such issue here (missing, or a PR)"})
        if section == "now":
            if w["closed"] is not None and w["open"] == 0 and w["closed"] > 0:
                w["close_due"].append(f"all {w['closed']} issues closed")
            t = last_change(root, p["file"])
            w["last_change"] = datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds") if t else None
            if t and now - t >= STALE_DAYS * 86400:
                w["close_due"].append(f"plan unchanged for {int((now - t) // 86400)} days")
            if w["close_due"]:
                rep["attention"].append({"kind": "close-due", "text": f"Close due: {w['name']} ({'; '.join(w['close_due'])})"})
            if not w["issues"]:
                rep["notes"].append(f"Now wave {w['name']} lists no issues: (issues: [...] in its frontmatter)")
        return w

    if structured:
        for s in SECTIONS:
            rep[s] = [wave(e, e["plan"], s) for e in secs[s]]
        if len(secs["now"]) > b["cap"]:
            rep["attention"].append({"kind": "cap", "text": f"Now holds {len(secs['now'])} waves, cap {b['cap']}"})
        on_roadmap = {e["plan"] for s in SECTIONS for e in secs[s] if e["plan"]}
        for fn, p in ps.items():
            if p["status"] in LIVE and fn not in on_roadmap:
                rep["drift"].append({"plan": p["file"], "status": p["status"], "title": p["title"]})
        if rep["drift"]:
            names = "; ".join(d["title"] for d in rep["drift"][:3]) + (f" +{len(rep['drift']) - 3}" if len(rep["drift"]) > 3 else "")
            rep["attention"].append({"kind": "drift",
                                     "text": f"{len(rep['drift'])} proposed/active plans with no ROADMAP line: {names}"})
    else:
        rep["notes"].append(f"ROADMAP isn't structured yet (no ## Now / ## Next / ## Later in {b['roadmap'] or 'no roadmap bound'})")
        rep["unlisted_waves"] = [wave(None, fn, "unlisted") for fn in sorted(wave_plans)]
    rep["state"] = "waves" if structured else "plans with issues, no structured ROADMAP"
    order = ["close-due", "cap", "no-plan", "missing-issue", "drift"]
    rep["attention"].sort(key=lambda a: order.index(a["kind"]))
    return rep


def progress(w):
    if not w["issues"]:
        return "no issues listed"
    if w["closed"] is None:
        return f"{len(w['issues'])} issues (states unknown)"
    if w["closed"] + w["open"] == 0:
        return f"none of its {len(w['issues'])} listed issues found"
    return f"{w['closed']} of {w['closed'] + w['open']} issues closed"


def cut(s, n):
    s = (s or "").strip()
    return s if len(s) <= n else s[: n - 1].rsplit(" ", 1)[0] + "…"


def text(rep):
    out = [f"Waves · {rep['project']}" + (f" · cap {rep['cap']}" if rep["structured"] else "")]
    if rep["state"] == "no waves yet":
        out.append("No waves yet." + (" " + rep["notes"][0] + "." if rep["notes"] else ""))
        return out
    if rep["structured"]:
        out.append(f"Now ({len(rep['now'])} of {rep['cap']}):" if rep["now"] else "Now: none")
        for w in rep["now"]:
            flag = f" · CLOSE DUE ({'; '.join(w['close_due'])})" if w["close_due"] else ""
            done = f" · done when: {cut(w['done'], 90)}" if w["done"] else ""
            out.append(f"- {w['name']} · {progress(w)}{done}{flag}" + (f" · {w['plan']}" if w["plan"] else ""))
        out.append(f"Next: {len(rep['next'])} · Later: {len(rep['later'])}")
    else:
        out.append(rep["notes"][0] + ".")
        out.append(f"Plans listing issues ({len(rep['unlisted_waves'])}):")
        for w in rep["unlisted_waves"]:
            out.append(f"- {w['name']} · {w['status'] or '?'} · {progress(w)} · {w['plan']}")
    if rep["attention"]:
        out.append("Attention:")
        out += [f"- {a['text']}" for a in rep["attention"]]
    if rep["issues_source"]:
        out.append(f"(issues: {rep['issues_source']})")
    return out


def main():
    args = sys.argv[1:]
    flags = {a for a in args if a.startswith("--")}
    paths = [a for a in args if not a.startswith("--")]
    unknown = flags - {"--json", "--attention", "--line", "--offline", "--cache"}
    if unknown or len(paths) > 1:
        sys.exit(__doc__)
    path = paths[0] if paths else "."
    if not os.path.isdir(path):
        sys.exit(f"waves.py: no folder {path}")
    rep = collect(path, offline="--offline" in flags, cache="--cache" in flags)
    if "--json" in flags:
        json.dump(rep, sys.stdout, indent=1)
        sys.stdout.write("\n")
    elif "--attention" in flags:
        for a in rep["attention"]:
            print(a["text"])
    elif "--line" in flags:
        kinds = [a["kind"] for a in rep["attention"]]
        bits = []
        due = [a["text"].split(": ", 1)[1].split(" (")[0] for a in rep["attention"] if a["kind"] == "close-due"]
        if due:
            bits.append(f"close due: {'; '.join(due)}")
        if "cap" in kinds:
            bits.append(f"Now {len(rep['now'])} of cap {rep['cap']}")
        if "drift" in kinds:
            bits.append(f"{len(rep['drift'])} plans off the ROADMAP")
        if "missing-issue" in kinds or "no-plan" in kinds:
            bits.append("wave lists need fixing")
        if bits:
            print("waves: " + " · ".join(bits) + " → /status arc")
    else:
        print("\n".join(text(rep)))


if __name__ == "__main__":
    main()
