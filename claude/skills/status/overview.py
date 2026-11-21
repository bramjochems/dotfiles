#!/usr/bin/env python3
"""overview.py: /status overview, one view across all projects (see overview.md).

    overview.py gather            facts for every project; writes the list to ~/projects/.status/overview.md
                                  and prints it, then a bounded facts block per project for the digest
    overview.py digest < FILE     replaces the digest part of overview.md with stdin and prints the whole file
    overview.py resolve NAME      prints the project folder NAME stands for (for `gather.sh arc NAME`)

Normally run through `gather.sh overview [--digest]` and `gather.sh arc <name>`.

Read-only toward every project: local git refs only (no fetch, no gh), no writes to any project's .status/.
The one file written is ~/projects/.status/overview.md. Projects, roots and excludes: overview.conf.

Time, from transcript timestamps (gaps under 15 minutes count as active, longer gaps not at all):
  yours   the gaps between your own typed messages in the project's sessions, merged across sessions;
  agents  the gaps between assistant and tool events in the project's sessions and their subagents, merged
          (wall clock with at least one agent at work, so parallel agents are not added up).
Standard library only.
"""
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from datetime import datetime

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True  # no __pycache__ in the skill dir
import render as R  # noqa: E402  (parse_status, strip_md, cut, first_clause, when, write_atomic, read_lines)
import waves as W  # noqa: E402  (collect: the waves, offline, from each project's cached issue states)

HOME = os.path.expanduser("~")
TRANSCRIPTS = os.path.join(HOME, ".claude", "projects")
OUT = os.path.join(HOME, "projects", ".status", "overview.md")
CONF = os.path.join(HERE, "overview.conf")
DIGEST_MARK = "<!-- digest: written by the model from `gather.sh overview` -->"

NOW = time.time()
DAY = 86400
GAP = 15 * 60
WEEK, MONTH = NOW - 7 * DAY, NOW - 28 * DAY
SESSION_DAYS = 90
ACTIVE_DAYS = 14
WORKTREES = {}
SELF_SID = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
SKIP_DIRS = {"node_modules", ".venv", "venv", "__pycache__", "dist", "build", "target", "site-packages", ".next"}
BUMP = re.compile(r"^(build|chore)\(deps[^)]*\)|^bump |^\[bot\]|dependabot|renovate", re.I)
STATEISH = re.compile(r"^(current state|current|state|status|where we are|where things stand)\b", re.I)
ELSEWHERE = re.compile(r"with someone|blocked on|on hold", re.I)
CAP_COMMITS, CAP_COMMITS_DOCS, CAP_SESSIONS, CAP_NEXT, CAP_ROWS = 15, 10, 8, 5, 8
NOW_TOTAL_FLAG = 8  # Now waves across all projects above this: too much in flight


# ------------------------------------------------------------------ config
def load_conf():
    roots, excludes, depth = [], [], 4
    for line in R.read_lines(CONF):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        k, _, v = line.partition(" ")
        v = os.path.expanduser(v.strip()).rstrip("/")
        if k == "root":
            roots.append(os.path.abspath(v))
        elif k == "exclude":
            excludes.append(os.path.abspath(v))
        elif k == "depth" and v.isdigit():
            depth = int(v)
    return roots or [os.path.join(HOME, "projects")], excludes, depth


def under(p, base):
    return p == base or p.startswith(base + "/")


# ------------------------------------------------------------------ discovery
def worktree_main(gitfile):
    """A .git file `gitdir: <main>/.git/worktrees/<name>` -> <main>."""
    try:
        with open(gitfile) as f:
            g = f.read().strip()
    except OSError:
        return None
    m = re.match(r"gitdir:\s*(.+)$", g)
    if not m or "/worktrees/" not in m.group(1):
        return None
    common = m.group(1).split("/worktrees/")[0]
    return os.path.dirname(common) if common.endswith("/.git") else None


def discover(roots, excludes, depth):
    """-> repos {path: root}, worktrees {path: main}."""
    repos, wts = {}, {}
    for root in roots:
        stack = [(root, 0)]
        while stack:
            d, lv = stack.pop()
            if any(under(d, x) for x in excludes):
                continue
            g = os.path.join(d, ".git")
            if os.path.isdir(g):
                repos[d] = root
                continue
            if os.path.isfile(g):
                m = worktree_main(g)
                if m:
                    wts[d] = m
                continue
            if lv >= depth:
                continue
            try:
                with os.scandir(d) as it:
                    for e in it:
                        if (e.is_dir(follow_symlinks=False) and not e.name.startswith(".")
                                and e.name not in SKIP_DIRS):
                            stack.append((e.path, lv + 1))
            except OSError:
                continue
    return repos, wts


# ------------------------------------------------------------------ transcripts
META = ("<task-notification", "<system-reminder", "<local-command", "Caveat:", "<bash-input", "<bash-stdout",
        "<bash-stderr", "<user-prompt-submit-hook", "<peer", "<teammate-message", "<artifact-co",
        "[Request interrupted", "This session is being continued from a previous conversation")


def _ts(line):
    i = line.rfind(b'"timestamp":"')
    if i < 0:
        return None
    try:
        return datetime.fromisoformat(line[i + 13:i + 37].split(b'"')[0].decode()).timestamp()
    except ValueError:
        return None


def _typed(line):
    """Is this user line a message the owner typed? (the rules of report_lint.py, plus slash commands)"""
    try:
        d = json.loads(line)
    except ValueError:
        return False
    if d.get("isSidechain") or d.get("isMeta") or d.get("isCompactSummary") or d.get("entrypoint") == "sdk-cli":
        return False
    if (d.get("origin") or {}).get("kind") not in (None, "human") or d.get("promptSource") not in (None, "typed"):
        return False
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return False
        c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    s = (c or "").lstrip()
    return bool(s) and not s.startswith(META)


def scan(path):
    """One transcript, streamed: cwd, title, branch, the owner's message times, agent event times (4 weeks)."""
    try:
        return _scan(path)
    except OSError:  # removed while we read
        return None


def _scan(path):
    sub = "/subagents/" in path
    want_agent = os.path.getmtime(path) >= MONTH
    cwd = title = custom = branch = None
    owner, agent = [], []
    try:
        fh = open(path, "rb")
    except OSError:
        return None
    with fh:
        for line in fh:
            if cwd is None:
                i = line.find(b'"cwd":"')
                if i >= 0:
                    cwd = line[i + 7:line.find(b'"', i + 7)].decode(errors="replace")
            if line.startswith(b'{"type":"ai-title"') or line.startswith(b'{"type":"custom-title"'):
                try:
                    d = json.loads(line)
                    title = d.get("aiTitle") or title
                    custom = d.get("customTitle") or custom
                except ValueError:
                    pass
                continue
            if b'"type":"assistant"' in line:
                kind = "a"
            elif b'"type":"user"' in line:
                kind = "u"
            else:
                continue
            j = line.rfind(b'"gitBranch":"')
            if j >= 0:
                branch = line[j + 13:line.find(b'"', j + 13)].decode(errors="replace")
            if kind == "u" and not sub and b'"type":"tool_result"' not in line and b'"isSidechain":true' not in line:
                if _typed(line):
                    t = _ts(line)
                    if t:
                        owner.append(t)
                continue
            if want_agent:
                t = _ts(line)
                if t and t >= MONTH:
                    agent.append(t)
    sid = os.path.basename(path)[:-6]
    if sub:  # <key>/<parent sid>/subagents/agent-x.jsonl
        sid = path.split("/subagents/")[0].rsplit("/", 1)[-1]
    return {"path": path, "sid": sid, "sub": sub, "cwd": cwd, "title": custom or title, "branch": branch,
            "owner": owner, "agent": agent, "mtime": os.path.getmtime(path)}


def transcripts():
    files = []
    for key in os.listdir(TRANSCRIPTS) if os.path.isdir(TRANSCRIPTS) else []:
        kd = os.path.join(TRANSCRIPTS, key)
        try:
            entries = list(os.scandir(kd))
        except OSError:
            continue
        for e in entries:
            if e.name.endswith(".jsonl") and e.stat().st_mtime >= NOW - SESSION_DAYS * DAY:
                files.append(e.path)
            elif e.is_dir():
                sd = os.path.join(e.path, "subagents")
                for dp, _, fs in os.walk(sd):
                    for f in fs:
                        p = os.path.join(dp, f)
                        if f.endswith(".jsonl") and os.path.getmtime(p) >= MONTH:
                            files.append(p)
    def size(p):
        try:
            return os.path.getsize(p)
        except OSError:
            return 0
    files.sort(key=size, reverse=True)  # big ones first, so no worker ends last on a 200 MB file
    with ProcessPoolExecutor(min(12, os.cpu_count() or 4)) as ex:
        return [r for r in ex.map(scan, files, chunksize=1) if r]


def active_seconds(ts, since):
    ts = sorted(ts)
    return sum(b - a for a, b in zip(ts, ts[1:]) if b - a < GAP and b >= since)


# ------------------------------------------------------------------ git (local refs only)
def git(path, *args):
    try:
        r = subprocess.run(["git", "--no-optional-locks", "-C", path, *args], capture_output=True, text=True, errors="replace", timeout=8)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def git_facts(path, excludes=()):
    f = {}
    db = git(path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip()
    db = db.split("/", 1)[1] if "/" in db else ""
    if not db:
        for c in ("main", "master"):
            if git(path, "rev-parse", "-q", "--verify", f"refs/heads/{c}").strip():
                db = c
                break
    db = db or git(path, "branch", "--show-current").strip() or "main"
    f["default"] = db
    # The newer of the local branch and its remote-tracking ref (both local; nothing is fetched).
    refs = git(path, "for-each-ref", "--format=%(committerdate:unix) %(refname:short)",
               f"refs/heads/{db}", f"refs/remotes/origin/{db}").split("\n")
    refs = sorted((l.split(" ", 1) for l in refs if " " in l), key=lambda x: -int(x[0]))
    dref = refs[0][1] if refs else db
    f["dref"] = dref
    last = git(path, "for-each-ref", "--sort=-committerdate", "--count=1", "--format=%(committerdate:unix)",
               "refs/heads", "refs/remotes").strip()
    f["last_commit"] = int(last) if last.isdigit() else 0
    log = git(path, "log", dref, "--first-parent", f"--since={int(MONTH)}", "--format=%x1e%ct%x1f%s%x1f%b")
    commits, bumps = [], 0
    for rec in log.split("\x1e"):
        p = rec.split("\x1f")
        if len(p) < 2:
            continue
        t, s, b = int(p[0].strip() or 0), p[1].strip(), (p[2] if len(p) > 2 else "").strip()
        m = re.match(r"Merge pull request #(\d+)", s)
        if m:
            s = f"{(b.splitlines() or [s])[0].strip()} (#{m.group(1)})"
        if BUMP.search(s):
            bumps += 1
            continue
        commits.append((t, s))
    f["commits"], f["bumps"] = commits, bumps
    f["branch"] = git(path, "branch", "--show-current").strip() or "detached"
    wts = [l[9:] for l in git(path, "worktree", "list", "--porcelain").splitlines() if l.startswith("worktree ")]
    dirty = []
    for w in wts or [path]:
        if os.path.isdir(w):
            n = len([l for l in git(w, "status", "--porcelain").splitlines()
                     if l.strip() and not any(under(os.path.join(w, l[3:].strip('"').rstrip("/")), x) for x in excludes)])
            if n:
                dirty.append((w, n))
    f["dirty"], f["worktrees"] = dirty, len(wts)
    ahead = []
    for l in git(path, "for-each-ref", "refs/heads", "--sort=-committerdate",
                 f"--format=%(refname:short)%09%(committerdate:unix)%09%(ahead-behind:{dref})").splitlines():
        p = l.split("\t")
        if len(p) == 3 and p[0] != db and p[2].split()[0].isdigit() and int(p[2].split()[0]) > 0 \
                and int(p[1]) >= NOW - ACTIVE_DAYS * DAY:
            ahead.append((p[0], int(p[2].split()[0]), int(p[1])))
    f["ahead"] = ahead
    return f


# ------------------------------------------------------------------ docs
def read(path, n=None):
    try:
        with open(path, errors="replace") as fh:
            return fh.read() if n is None else fh.read(n)
    except OSError:
        return ""


def binding(text, role):
    for l in text.replace("\\|", "/").splitlines():
        c = l.split("|")
        if l.startswith("|") and len(c) > 3 and re.search(role, c[1].strip(), re.I):
            return c[2].strip()
    return ""


def first_code(s):
    m = re.search(r"`([^`]*)`", s)
    return m.group(1) if m else ""


AGENTY = re.compile(r"^(guidance|instructions|rules|this file|notes) (for|to|on)\b|\bAI (coding )?agents\b|^use agents\b", re.I)


def first_paragraph(text, n=300):
    """The first run of prose lines that says what the project is: no headings, badges, html, tables, rules,
    front matter, and not the "guidance for AI agents" line a CLAUDE.md opens with."""
    paras, cur, fm = [], [], text.startswith("---")
    for i, l in enumerate(text.splitlines()):
        s = l.strip()
        if fm:
            if i > 0 and s == "---":
                fm = False
            continue
        if not s or s.startswith(("#", "![", "[![", "<", "|", "---", "```", "===", ">")):
            if cur:
                paras.append(" ".join(cur))
                cur = []
                if len(paras) >= 6:
                    break
            continue
        cur.append(s)
    if cur:
        paras.append(" ".join(cur))
    p = next((x for x in paras if not AGENTY.search(x) and len(x) > 30), "")
    return R.cut(R.strip_md(p), n) if p else ""


def section(text, name):
    """Lines under the heading that contains `name`, to the next heading of the same or higher level."""
    out, lvl = None, 0
    for l in text.splitlines():
        m = re.match(r"^(#+) ", l)
        if m:
            if out is not None and len(m.group(1)) <= lvl:
                break
            if out is None and name.lower() in l.lower():
                out, lvl = [], len(m.group(1))
                continue
        if out is not None:
            out.append(l)
    return out or []


def roadmap_rows(text, sec):
    """Open rows of the first table with an Effort or Work column (within the section, when bound);
    a roadmap that is a bullet list gives its bullets."""
    lines = section(text, sec) if sec else text.splitlines()
    rows, cols = [], None
    for l in lines:
        if not l.startswith("|"):
            if cols:
                break
            continue
        c = [x.strip() for x in l.replace("\\|", "/").split("|")[1:-1]]
        if cols is None:
            hs = [x.lower() for x in c]
            ec = next((i for i, h in enumerate(hs) if h in ("effort", "work")), None)
            if ec is not None:
                cols = (ec, next((i for i, h in enumerate(hs) if h == "status"), None))
            continue
        if re.match(r"^[ :|-]+$", l) or len(c) <= cols[0]:
            continue
        st = R.strip_md(c[cols[1]]) if cols[1] is not None and cols[1] < len(c) else "listed"
        if re.match(r"^[^A-Za-z]*(done|dropped|superseded|retired)", st, re.I):
            continue
        rows.append(f"{R.cut(R.strip_md(c[cols[0]]), 70)} · {R.cut(st, 60)}")
    if not rows:
        rows = [R.cut(R.strip_md(l[2:]), 130) for l in lines if l.startswith("- ")]
    return rows


def plan_name(fp):
    """The plan's heading, name first: "E16 — MCP over OAuth" -> "MCP over OAuth (E16)"."""
    h = next((l[2:] for l in read(fp, 4000).splitlines() if l.startswith("# ")), "")
    h = R.strip_md(h) or os.path.splitext(os.path.basename(fp))[0]
    m = re.match(r"^([A-Z]{1,4}\d+[a-z]?(?:\.\d+)?)\s*[—:–-]+\s*(.+)$", h)
    return R.cut(f"{m.group(2)} ({m.group(1)})" if m else h, 80)


def doc_facts(path):
    """Level, mode and the goal sources: bindings (STATUS, roadmap, plans), README, CLAUDE.md."""
    f = {"level": "minimal", "mode": "", "status": "", "efforts": [], "waiting": [], "roadmap": [], "plans": [],
         "resume": [], "srcs": []}
    bpath = os.path.join(path, "docs", "agentic-workflow.bindings.md")
    if os.path.isfile(os.path.join(path, "docs", "agentic-workflow.md")) and os.path.isfile(bpath):
        f["level"] = "full"
        b = read(bpath)
        st = first_code(binding(b, r"^Session pointer"))
        if st and os.path.isfile(os.path.join(path, st)):
            text = read(os.path.join(path, st))
            f["status"] = st
            f["srcs"].append("STATUS")
            fm = text.split("\n---", 1)[0] if text.startswith("---") else ""
            m = re.search(r"^mode:\s*(\S+)", fm, re.M)
            f["mode"] = m.group(1) if m else ""
            m = re.search(r"^updated:\s*(\S+)", fm, re.M)
            f["status_updated"] = m.group(1) if m else ""
            # Section by section, so a state section ("Current state", "Where we are") is told apart from
            # the efforts: its bullets are facts for the digest, not what the project works towards.
            chunks, waiting = [], []
            for l in text.splitlines():
                if l.startswith("## ") or not chunks:
                    chunks.append([])
                chunks[-1].append(l)
            for ch in chunks:
                head = re.sub(r"^[^A-Za-z]+", "", ch[0][3:]).strip() if ch[0].startswith("## ") else ""
                efforts, w = R.parse_status(ch)
                waiting += w
                if STATEISH.match(head):
                    bl = list(R.bullets(ch[1:]))
                    if bl:
                        efforts = []
                        for n, t in bl:
                            efforts.append(R.Effort(R.strip_md(n), "now"))
                            efforts[-1].text = t
                for e in efforts:
                    body = re.sub(r"\s+", " ", R.strip_md(" ".join(e.text))).strip()
                    body = re.sub(r"^-?\s*" + re.escape(e.name) + r"[:.]?\s*", "", body)
                    kind = "state" if STATEISH.match(head) or STATEISH.match(e.name) else \
                        "elsewhere" if e.kind == "now" and ELSEWHERE.search(e.name) else e.kind
                    if kind == "state" and STATEISH.match(e.name):  # a state section without bullets
                        e.name = R.first_clause(body, 45)
                    f["efforts"].append((e.name, kind, R.cut(body, 300)))
            f["waiting"] = [R.first_clause(w, 70) for w in waiting]
        rraw = binding(b, r"^Roadmap")
        rf = first_code(rraw)
        m = re.search(r'§ *"?([^",(]*)"?', rraw)
        if rf and os.path.isfile(os.path.join(path, rf)):
            f["roadmap"] = roadmap_rows(read(os.path.join(path, rf)), m.group(1).strip() if m else "")
            f["roadmap_file"] = rf + (f" § {m.group(1).strip()}" if m else "")
            if f["roadmap"]:
                f["srcs"].append("roadmap")
        pd = first_code(binding(b, r"^Plans directory"))
        if pd and os.path.isdir(os.path.join(path, pd)):
            plans = []
            for fn in sorted(os.listdir(os.path.join(path, pd))):
                if not fn.endswith(".md") or fn in ("STATUS.md", "ROADMAP.md", "README.md", "BACKLOG.md"):
                    continue
                fp = os.path.join(path, pd, fn)
                head = read(fp, 1500).splitlines()[:12]
                st = next((l.split()[1] for l in head if l.startswith("status:") and len(l.split()) > 1), "")
                if st not in ("active", "planned", "proposed", "blocked", "parked"):
                    continue
                up = next((l.split()[1] for l in head if l.startswith("updated:") and len(l.split()) > 1), "?")
                plans.append((up, fn, st, plan_name(fp), fp))
            plans.sort(key=lambda x: (x[0] != "?", x[0]), reverse=True)
            f["plans"] = [f"{t} · {st} · updated {up} · {pd}{fn}" for up, fn, st, t, _ in plans]
            if plans:
                f["srcs"].append("plans")
            if not f["status"]:  # the session pointer is a block inside each plan (the Medi-Invest websites)
                for up, fn, st, t, fp in plans[:3]:
                    blk = [l.strip() for l in section(read(fp), "left off") if l.strip()][:4]
                    if blk:
                        f["resume"].append((t, [R.cut(R.strip_md(l), 200) for l in blk]))
    for name in ("README.md", "readme.md", "README", "CLAUDE.md"):
        p = first_paragraph(read(os.path.join(path, name), 20000))
        if p:
            f["readme"], f["readme_src"] = p, name
            f["srcs"].append(name)
            break
    return f


# ------------------------------------------------------------------ state files (read only)
def state_facts(path):
    sd = os.path.join(path, ".status")
    f = {"inbox": [l for l in R.read_lines(os.path.join(sd, "waiting.md")) if l.startswith("- ")],
         "next": [l for l in R.read_lines(os.path.join(sd, "next.md")) if l.startswith("- ")],
         "red": "", "red_at": None, "handoff": None}
    best = None
    for fn in ("now.md", "arc.md"):
        lines = R.read_lines(os.path.join(sd, fn))
        if not lines:
            continue
        m = re.search(r"updated=(\S+)", lines[0])
        at = R.parse_iso(m.group(1)) if m else None
        if at is None or (best and at <= best[0]):
            continue
        red = ""
        for l in lines:
            m = re.match(r"^Maintenance: .*?red on main: ([^;→]+)", l) if fn == "now.md" else \
                re.match(r"^- Red on main: (.+)$", l)
            if m and m.group(1).strip() != "none":
                red = m.group(1).strip()
        best = (at, red)
    if best:
        f["red_at"], f["red"] = best
    hp = os.path.join(sd, "handoff.md")
    if os.path.isfile(hp):
        ls = [l.strip() for l in R.read_lines(hp) if l.strip()]
        head = next((R.strip_md(l.lstrip("# ")) for l in ls if l.startswith("#")), "")
        body = [R.cut(R.strip_md(l), 160) for l in ls if not l.startswith(("#", "<!--"))][:5]
        f["handoff"] = (os.path.getmtime(hp), head, body)
    return f


# ------------------------------------------------------------------ assembling
def stamp(t, always_time=False):
    return R.when(datetime.fromtimestamp(t).astimezone(), always_time) if t else "—"


def hours(s):
    h = s / 3600
    return "0" if h < 0.05 else f"{h:.1f}".rstrip("0").rstrip(".") if h < 10 else f"{h:.0f}"


class Project:
    def __init__(self, path, root, kind):
        self.path, self.root, self.kind = path, root, kind
        self.name = os.path.basename(path) if path == root else os.path.relpath(path, root)
        self.sessions, self.owner, self.agent = [], [], []
        self.git, self.docs, self.state, self.waves = {}, {}, {}, {}

    # facts
    def last_owner(self):
        return max(self.owner, default=0)

    def last_activity(self):
        return max([self.last_owner(), self.git.get("last_commit", 0)] + [s["mtime"] for s in self.sessions])

    def order(self):
        """Your last message first; projects where you never typed (90 d) below, by any activity."""
        lo = self.last_owner()
        return (0, -lo) if lo else (1, -self.last_activity())

    def mode(self):
        d = self.docs.get("mode")
        if d:
            return d, f"declared in {self.docs['status']}"
        lo = self.last_owner()
        if lo >= NOW - ACTIVE_DAYS * DAY:
            return "active", f"inferred: your last message here {stamp(lo, True)}"
        return "maintenance", "inferred: no message from you here in 14 days"

    def quiet(self):
        return self.docs.get("mode") == "maintenance" or self.last_activity() < MONTH

    def towards(self):
        now = [e[0] for e in self.docs.get("efforts", []) if e[1] == "now"]
        if now:
            return "; ".join(now[:2]) + (f" +{len(now) - 2}" if len(now) > 2 else "")
        if self.docs.get("resume"):
            return "; ".join(t for t, _ in self.docs["resume"][:2])
        act = [pl.split(" · ")[0] for pl in self.docs.get("plans", []) if " · active · " in pl]
        if act:
            return "; ".join(act[:2]) + (f" +{len(act) - 2}" if len(act) > 2 else "")
        nxt = self.state.get("next")
        if nxt:
            return re.sub(r"^- (\d{4}-\d{2}-\d{2} · )?", "", nxt[0])
        recent = [s for s in self.sessions if s["title"]]
        if recent:
            return recent[0]["title"]
        return self.docs.get("readme", "") or "—"

    def attention(self):
        n = len(self.state.get("inbox", []))
        if n:
            return f"inbox: {n} waiting{' (full)' if n >= 7 else ''}"
        if self.state.get("red"):
            at = self.state["red_at"]
            return f"red CI: {R.cut(self.state['red'], 30)} (as of {R.when(at, True)})"
        st = self.docs.get("waiting", [])
        if st:  # the Status file's waiting-on-the-owner section, when the inbox is empty
            return f"standing: {len(st)}"
        d = self.git.get("dirty", [])
        if d:
            n = sum(x[1] for x in d)
            return f"{n} uncommitted file{'s' if n > 1 else ''}" + (f" in {len(d)} checkouts" if len(d) > 1 else "")
        return ""

    def time(self):
        y = (active_seconds(self.owner, WEEK), active_seconds(self.owner, MONTH))
        a = (active_seconds(self.agent, WEEK), active_seconds(self.agent, MONTH))
        return y, a

    def time_str(self):
        y, a = self.time()
        return f"you {hours(y[0])}/{hours(y[1])} h · agents {hours(a[0])}/{hours(a[1])} h"


def build(lite=False):
    roots, excludes, depth = load_conf()
    repos, wts = discover(roots, excludes, depth)
    WORKTREES.update(wts)
    projects = {p: Project(p, r, "git") for p, r in repos.items()}
    others = {}  # label -> Project-like bucket
    scans = [] if lite else transcripts()
    if lite:  # resolve: only the cwd of each recent session, for the folder projects
        for key in os.listdir(TRANSCRIPTS) if os.path.isdir(TRANSCRIPTS) else []:
            kd = os.path.join(TRANSCRIPTS, key)
            for fn in os.listdir(kd) if os.path.isdir(kd) else []:
                fp = os.path.join(kd, fn)
                try:
                    recent = fn.endswith(".jsonl") and os.path.getmtime(fp) >= NOW - SESSION_DAYS * DAY
                    fh = open(fp, "rb") if recent else None
                except OSError:
                    fh = None
                if fh:
                    with fh:
                        for line in fh:
                            i = line.find(b'"cwd":"')
                            if i >= 0:
                                scans.append({"cwd": line[i + 7:line.find(b'"', i + 7)].decode(errors="replace"),
                                              "sub": False, "sid": fn[:-6]})
                                break
    sid_cwd = {s["sid"]: s["cwd"] for s in scans if not s["sub"] and s["cwd"]}

    def owner_of(cwd):
        """cwd -> (project path, None) | (None, other label) | (None, None) outside the roots."""
        if not cwd or any(under(cwd, x) for x in excludes):
            return None, None
        for w, m in wts.items():
            if under(cwd, w):
                return (m, None) if m in projects else (None, None)
        best = max((p for p in projects if under(cwd, p)), key=len, default=None)
        if best:
            return best, None
        root = max((r for r in roots if under(cwd, r)), key=len, default=None)
        if not root:
            return None, None
        par, base = os.path.dirname(cwd), os.path.basename(cwd)
        for p in projects:  # a removed sibling worktree: <parent>/<repo>-<branch>
            if os.path.dirname(p) == par and base.startswith(os.path.basename(p) + "-"):
                return p, None
        return None, cwd

    # folder projects: a folder under a root with sessions that is not a root, holds no project, still exists
    cands = sorted({c for s in scans for _, c in [owner_of(s["cwd"] or sid_cwd.get(s["sid"]))] if c})
    folder = {}
    for c in cands:
        if os.path.isdir(c) and c not in roots and not any(p.startswith(c + "/") for p in projects):
            top = next((f for f in folder if under(c, f)), None)
            if top is None:
                root = max((r for r in roots if under(c, r)), key=len)
                folder[c] = Project(c, root, "folder")
    projects.update(folder)

    for s in scans:
        cwd = s["cwd"] or sid_cwd.get(s["sid"])
        p, other = owner_of(cwd)
        if p is None and other:
            p = next((f for f in folder if under(other, f)), None)
        if p is None and other is None:
            continue
        if p is None:
            root = max((r for r in roots if under(other, r)), key=len)
            label = os.path.relpath(other, os.path.dirname(root)) if other == root else os.path.relpath(other, root)
            label = "~/" + os.path.relpath(other, HOME) if other == root else label
            if not os.path.isdir(other):
                label += " (gone)"
            prj = others.setdefault(label, Project(other, root, "other"))
        else:
            prj = projects[p]
        if lite:
            continue
        if not s["sub"]:
            if s["sid"] != SELF_SID:
                prj.owner += s["owner"]
            prj.sessions.append(s)
        prj.agent += s["agent"]
    if lite:
        return list(projects.values()), others
    for prj in list(projects.values()) + list(others.values()):
        prj.sessions.sort(key=lambda s: -s["mtime"])

    def facts(prj):
        if prj.kind == "git":
            prj.git = git_facts(prj.path, excludes)
        prj.docs = doc_facts(prj.path)
        prj.state = state_facts(prj.path)
        try:
            prj.waves = W.collect(prj.path, offline=True)
        except Exception as e:  # one odd project must not break the overview
            prj.waves = {"now": [], "attention": [], "issues_source": f"waves failed: {e}"}
        return prj
    with ThreadPoolExecutor(16) as ex:
        list(ex.map(facts, projects.values()))
    return list(projects.values()), others


# ------------------------------------------------------------------ the list (script-rendered)
def render_list(projects, others):
    live = sorted((p for p in projects if not p.quiet()), key=Project.order)
    quiet = sorted((p for p in projects if p.quiet()), key=lambda p: -p.last_activity())
    t = datetime.fromtimestamp(NOW).astimezone()
    out = [f"<!-- overview:all updated={t.isoformat(timespec='seconds')} projects={len(projects)} "
           f"listed={len(live)} quiet={len(quiet)} other={len(others)} -->",
           f"# Overview · {t.strftime('%a')} {t.day} {t.strftime('%b %H:%M')}",
           "",
           "Name · mode · you last here · working towards · attention · hours last 7 days/4 weeks",
           ""]
    for p in live:
        bits = [f"**{p.name}**", p.mode()[0], stamp(p.last_owner(), True) if p.last_owner() else "you: none in 90 d",
                R.cut(R.strip_md(p.towards()), 48)]
        a = p.attention()
        if a:
            bits.append(a)
        bits.append(p.time_str())
        out.append("- " + " · ".join(bits))
    out += render_waves(live + quiet)
    if others:
        o = sorted(others.values(), key=lambda p: -p.last_activity())
        names = "; ".join(k for k, _ in sorted(others.items(), key=lambda kv: -kv[1].last_activity()))
        ow = [x for p in o for x in p.owner]
        ag = [x for p in o for x in p.agent]
        out += ["", f"Other (not a project): {R.cut(names, 110)} · {sum(len(p.sessions) for p in o)} sessions · "
                f"last {stamp(max(p.last_activity() for p in o), True)} · you {hours(active_seconds(ow, WEEK))}/"
                f"{hours(active_seconds(ow, MONTH))} h · agents {hours(active_seconds(ag, WEEK))}/"
                f"{hours(active_seconds(ag, MONTH))} h"]
    if quiet:
        out += ["", f"Quiet ({len(quiet)}: declared maintenance, or nothing in 4 weeks)"]
        for p in quiet:
            last = p.last_activity()
            what = "commit" if last and last == p.git.get("last_commit") else "session" if last else ""
            out.append(f"- **{p.name}** · {p.mode()[0]} · last {what} {stamp(last)}" if last
                       else f"- **{p.name}** · {p.mode()[0]} · nothing in 90 d")
    return out


def wave_bits(w):
    prog = f"{w['closed']}/{w['closed'] + w['open']}" if w.get("closed") is not None and w["closed"] + w["open"] else \
        f"{len(w['issues'])} issues" if w.get("issues") else "no issues"
    due = " CLOSE DUE" if w.get("close_due") else ""
    return f"{R.cut(w['name'], 40)} {prog}{due}"


def render_waves(projects):
    """Per project its Now waves (progress from the cached issue states, close-due flags); the total."""
    rows, total = [], 0
    for p in projects:
        now = p.waves.get("now") or []
        if not now:
            continue
        total += len(now)
        cap = p.waves.get("cap", W.DEFAULT_CAP)
        over = f" ({len(now)} in Now, cap {cap})" if len(now) > cap else ""
        src = p.waves.get("issues_source", "")
        at = R.parse_iso(src.replace("cached ", "").replace(" ", "T")) if src.startswith("cached") else None
        asof = f" · issue states as of {R.when(at, True)}" if at else " · issue states unknown (run /status there)"
        rows.append(f"- **{p.name}**{over}: " + "; ".join(wave_bits(w) for w in now) + asof)
    if not rows:
        return ["", "Now waves: none yet (no project's ROADMAP has a ## Now section with waves)"]
    flag = f" · **above {NOW_TOTAL_FLAG}: too much in flight**" if total > NOW_TOTAL_FLAG else ""
    return ["", f"Now waves: {total} across {len(rows)} project{'' if len(rows) == 1 else 's'}{flag}"] + rows


# ------------------------------------------------------------------ facts for the digest
def render_facts(projects, others, excludes):
    out = ["", "## facts for the digest (one block per project in the list above; Quiet and Other have none)"]
    live = sorted((p for p in projects if not p.quiet()), key=Project.order)
    for p in live:
        d, g, s = p.docs, p.git, p.state
        mode, basis = p.mode()
        out += ["", f"### {p.name} · {p.kind} · level {d['level']} · mode {mode} ({basis}) · {p.path}"]
        src = list(d["srcs"])
        if d.get("readme"):
            out.append(f"{d['readme_src']}: {d['readme']}")
        if d["status"]:
            out.append(f"status file {d['status']} (updated {d.get('status_updated') or '?'}):")
            for name, kind, body in d["efforts"][:5]:
                out.append(f"  {kind}: {name}: {R.cut(body, 260 if kind == 'now' else 100)}")
            if d["waiting"]:
                out.append(f"  waiting on the owner: {'; '.join(d['waiting'][:6])}")
        if d["roadmap"]:
            out.append(f"roadmap {d['roadmap_file']}, open rows ({min(len(d['roadmap']), CAP_ROWS)} of "
                       f"{len(d['roadmap'])}):")
            out += [f"  {r}" for r in d["roadmap"][:CAP_ROWS]]
        if d["plans"]:
            out.append(f"live plans ({min(len(d['plans']), CAP_ROWS)} of {len(d['plans'])}, newest first):")
            out += [f"  {r}" for r in d["plans"][:CAP_ROWS]]
        for t, blk in d["resume"]:
            out.append(f"where I left off in {t}:")
            out += [f"  {l}" for l in blk]
        if p.kind == "git":
            c = g.get("commits", [])
            cap = CAP_COMMITS_DOCS if d["status"] or d["roadmap"] else CAP_COMMITS
            bump = f"; {g['bumps']} dependency bumps left out" if g.get("bumps") else ""
            out.append(f"commits on {g.get('dref')} (first parent), last 4 weeks: {len(c)}"
                       f"{f', newest {cap} shown' if len(c) > cap else ''}{bump}")
            out += [f"  {stamp(t)} · {R.cut(sj, 110)}" for t, sj in c[:cap]]
            if c:
                src.append("commits")
        allss = [x for x in p.sessions if x["mtime"] >= MONTH]
        ss = [x for x in allss if x["title"] or x["owner"]]
        bare = len(allss) - len(ss)
        out.append(f"sessions, last 4 weeks: {len(ss)}{f', newest {CAP_SESSIONS} shown' if len(ss) > CAP_SESSIONS else ''}"
                   f"{f' (+{bare} agent-run without title or a message from you)' if bare else ''}"
                   " (last active · topic · branch · your messages)")
        for x in ss[:CAP_SESSIONS]:
            out.append(f"  {stamp(x['mtime'], True)} · {x['title'] or '(no title)'} · {x['branch'] or '?'} · "
                       f"{len(x['owner'])}{' · this session' if x['sid'] == SELF_SID else ''}")
        if ss:
            src.append("sessions")
        lo = []
        if p.kind == "git":
            lo.append(f"main checkout on {g.get('branch')}; {g.get('worktrees', 1)} checkouts")
            for w, n in g.get("dirty", [])[:4]:
                lo.append(f"uncommitted: {n} files in {os.path.relpath(w, p.path) if w != p.path else 'main checkout'}")
            for b, n, t in g.get("ahead", [])[:3]:
                lo.append(f"branch {b}: {n} commits not on {g.get('dref')}, last {stamp(t)} (a squash-merged PR looks the same)")
        if s["next"]:
            src.append("next.md")
            lo.append(f"next.md ({len(s['next'])}): " + " | ".join(R.cut(re.sub(r'^- (\d{4}-\d{2}-\d{2} · )?', '', l), 120)
                                                              for l in s["next"][:CAP_NEXT]))
        if s["handoff"]:
            t, head, body = s["handoff"]
            newest = max((x["mtime"] for x in p.sessions), default=0)
            src.append("handoff.md")
            lo.append(f"handoff.md written {stamp(t, True)} ({'fresh' if t >= newest - 600 else 'older than the last session'}): "
                      f"{head}")
            lo += [f"  {l}" for l in body]
        if s["inbox"]:
            src.append("waiting.md")
            lo.append(f"inbox ({len(s['inbox'])} of 7):")
            lo += [f"  {R.cut(R.inbox_text(l), 150)}" for l in s["inbox"]]
        if s["red"]:
            lo.append(f"red on main per the last now/arc view ({R.when(s['red_at'], True)}): {s['red']}")
        wv = p.waves or {}
        if wv.get("now"):
            out.append("waves in Now: " + "; ".join(wave_bits(w) for w in wv["now"]))
        for a in (wv.get("attention") or [])[:3]:
            lo.append(f"waves: {a['text']}")
        out.append("left off:")
        out += [f"  {l}" for l in lo] or ["  nothing recorded"]
        out.append(f"time: {p.time_str()} · based-on candidates: {', '.join(dict.fromkeys(src)) or 'nothing'}")
    out += ["", "## coverage (for checking; not part of the view)",
            f"projects: {len(projects)} ({sum(p.kind == 'git' for p in projects)} git, "
            f"{sum(p.kind == 'folder' for p in projects)} folders with sessions)",
            f"excluded: {'; '.join(excludes) or 'none'}; worktrees are counted under their main repo",
            f"other: {'; '.join(sorted(others)) or 'none'}"]
    return out


# ------------------------------------------------------------------ commands
def write_out(text):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    R.write_atomic(OUT, text)


def cmd_gather():
    projects, others = build()
    lst = render_list(projects, others)
    # Keep the last digest (marked as older than the list) until the model writes a new one.
    cur = R.read_lines(OUT)
    old = cur[cur.index(DIGEST_MARK) + 1:] if DIGEST_MARK in cur else []
    old = [l for l in old if not l.startswith("(digest ")]
    m = (re.search(r"digest=(\S+)", cur[0]) or re.search(r"updated=(\S+)", cur[0])) if cur else None
    note = f"(digest from the overview of {R.when(R.parse_iso(m.group(1)), True)}; the list above is newer)" \
        if old and m else "(digest not written yet: /status overview)"
    if old and m:  # the digest keeps its own time
        lst[0] = lst[0].replace(" -->", f" digest={m.group(1)} -->")
    write_out("\n".join(lst + ["", DIGEST_MARK, note] + old) + "\n")
    roots, excludes, _ = load_conf()
    paths = [p.path for p in projects]
    rest = []

    def walk(d, root, lv):  # folders that are no project, hold none and are not excluded
        try:
            kids = sorted(e.path for e in os.scandir(d) if e.is_dir(follow_symlinks=False) and not e.name.startswith("."))
        except OSError:
            return
        for k in kids:
            if any(under(k, p) for p in paths + list(WORKTREES)) or any(under(k, x) for x in excludes):
                continue
            if any(under(p, k) for p in paths) and lv < 3:
                walk(k, root, lv + 1)
            else:
                rest.append(os.path.relpath(k, root))
    for r in roots:
        if r not in paths:
            walk(r, r, 1)
    facts = render_facts(projects, others, excludes)
    facts.append(f"no project (no git, no session in {SESSION_DAYS} d), under the roots: {'; '.join(rest) or 'none'}")
    sys.stdout.write("\n".join(lst) + "\n" + "\n".join(facts) + "\n")
    sys.stdout.write(f"\n(list written to {OUT}; the digest goes in with `gather.sh overview --digest`)\n")


def cmd_digest():
    digest = sys.stdin.read().strip("\n")
    cur = R.read_lines(OUT)
    if not cur:
        sys.exit("overview.py: no list yet; run `gather.sh overview` first")
    head = cur[:cur.index(DIGEST_MARK)] if DIGEST_MARK in cur else cur
    if head and "overview:all" in head[0]:
        head[0] = re.sub(r" digest=\S+", "", head[0]).replace(" -->", f" digest={datetime.now().astimezone().isoformat(timespec='seconds')} -->")
    while head and not head[-1].strip():
        head.pop()
    text = "\n".join(head + ["", DIGEST_MARK, digest]) + "\n"
    write_out(text)
    sys.stdout.write(text)


def cmd_resolve(name):
    projects, _ = build(lite=True)
    n = name.strip().rstrip("/").lower()
    for test in (lambda p: p.name.lower() == n or p.path.lower() == os.path.abspath(os.path.expanduser(name)).lower(),
                 lambda p: os.path.basename(p.path).lower() == n,
                 lambda p: n in p.name.lower()):
        hits = [p for p in projects if test(p)]
        if len(hits) == 1:
            print(hits[0].path)
            return
        if len(hits) > 1:
            sys.exit(f"'{name}' is ambiguous: {', '.join(sorted(p.name for p in hits))}")
    sys.exit(f"no project '{name}'; projects: {', '.join(sorted(p.name for p in projects))}")


def main():
    a = sys.argv[1:]
    if a and a[0] == "gather":
        cmd_gather()
    elif a and a[0] == "digest":
        cmd_digest()
    elif len(a) == 2 and a[0] == "resolve":
        cmd_resolve(a[1])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
