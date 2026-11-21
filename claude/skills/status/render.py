#!/usr/bin/env python3
"""render.py: turn gather.sh's facts into the finished /status view.

    gather.sh now | render.py now [--seen] [--running TEXT]... [--ask TEXT]...
    gather.sh arc | render.py arc

Normally run through `gather.sh now --render`. `now`: writes <state dir>/now.md atomically and prints
it. `arc`: prints the facts unchanged plus pre-rendered parts for the model (efforts parsed from the
Status file, open PRs grouped by effort, the Maintenance lines).

Grouping by effort is mechanical, first match wins: the Status file's effort entry names the PR;
a plan file that names it (gather's effort hints) is linked from an effort entry (else the plan's
own title is the group); the PR's title refers to a grouped number, or starts with the effort's
first word. Everything else goes under "Other".

Standard library only. Reads the state files itself (waiting.md, decided.md, next.md) so --ask
lines show at once; writes only in the state dir.
"""
import os
import re
import sys
from datetime import datetime, timedelta, timezone

MAX_INBOX = 7


# ------------------------------------------------------------------ parsing gather's output
def parse_sections(text):
    """'## name (...)' headers to {name: [lines]}; the Status file is kept whole."""
    secs, cur, in_status = {}, None, False
    for line in text.splitlines():
        if in_status:
            if line.startswith("## (end of status file)"):
                in_status, cur = False, None
            else:
                secs[cur].append(line)
            continue
        if line.startswith("## "):
            name = line[3:].split(" (")[0].strip()
            cur = name
            secs[cur] = [line]  # header kept: some carry facts (paths)
            in_status = name == "status file"
            continue
        if cur is not None:
            secs[cur].append(line)
    return secs


def body(secs, name):
    return [l for l in secs.get(name, [])[1:]]


def header(secs, name):
    return (secs.get(name) or [""])[0]


def kv(line, key):
    m = re.search(re.escape(key) + r" (\S+)", line)
    return m.group(1) if m else ""


def is_none(l):
    s = l.strip()
    return s in ("none", "(empty)", "") or s.startswith("(none") or s.startswith("unknown")


# ------------------------------------------------------------------ time
NOW = datetime.now().astimezone()
TODAY = NOW.date()


def parse_iso(s):
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return d.astimezone() if d.tzinfo else d.astimezone()
    except ValueError:
        return None


def parse_local(s):
    """'Fri 20 Nov 22:23' (no year) or '2026-11-20 22:18'."""
    for fmt in ("%Y-%m-%d %H:%M",):
        try:
            return datetime.strptime(s, fmt).astimezone()
        except ValueError:
            pass
    m = re.match(r"\w{3} (\d{1,2}) (\w{3}) (\d{2}):(\d{2})", s)
    if m:
        try:
            d = datetime.strptime(f"{NOW.year} {m.group(1)} {m.group(2)} {m.group(3)}:{m.group(4)}", "%Y %d %b %H:%M")
            if d.date() > TODAY:
                d = d.replace(year=NOW.year - 1)
            return d.astimezone()
        except ValueError:
            return None
    return None


def when(d, always_time=False):
    if d is None:
        return "?"
    if d.date() == TODAY:
        return d.strftime("%H:%M")
    s = f"{d.strftime('%a')} {d.day} {d.strftime('%b')}"
    return s + (d.strftime(" %H:%M") if always_time else "")


def duration(a, b):
    mins = int((b - a).total_seconds() // 60)
    if mins < 60:
        return f"{mins} min"
    h, m = divmod(mins, 60)
    if h < 48:
        return f"{h} h {m:02d}" if m else f"{h} h"
    return f"{h // 24} days"


# ------------------------------------------------------------------ names
def strip_md(s):
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    return s.replace("**", "").replace("`", "").replace("_", " ").strip()


def cut(s, n):
    s = s.strip()
    if len(s) <= n:
        return s
    s = s[: n - 1]
    if " " in s[n // 2:]:
        s = s[: s.rfind(" ")]
    return s.rstrip(" ,;:-·") + "…"


def first_clause(s, n=45):
    s = strip_md(s)
    for i, ch in enumerate(s):
        if i >= 12 and (s.startswith(": ", i) or s.startswith("; ", i) or s.startswith(" (", i)
                        or s.startswith(". ", i) or s.startswith(" — ", i)):
            s = s[:i]
            break
    return cut(s, n)


DOC_ONLY = re.compile(r"^(status|roadmap|plan|review|docs?)(, [\w -]+)*:", re.I)
PR_END = re.compile(r"\s*\(#(\d+)\)\s*$")
PR_ANY = re.compile(r"#(\d+)(?!\d)")


class PR:
    def __init__(self, title, n, at):
        self.n, self.at = n, at
        refs = [int(x) for x in re.findall(r"\(#(\d+)\)", title)]
        self.refs = [r for r in refs if r != n]
        self.title = re.sub(r"\s*\(#\d+\)", "", title).strip()

    def name(self, n=50):
        return f"{cut(self.title, n)} (#{self.n})"


def merged_prs(lines):
    """'  Title (#n) · Fri 20 Nov 12:10' lines; direct commits skipped; first line per number wins
    (doc commits after a merge often repeat its number)."""
    out, seen = [], set()
    for l in lines:
        s = l.strip()
        if is_none(s) or s.startswith("direct commit:") or " · " not in s:
            continue
        if DOC_ONLY.match(s):  # "status, roadmap: … (#n)": a doc update naming a PR, not a merge
            continue
        title, at = s.rsplit(" · ", 1)
        m = PR_END.search(title)
        if not m:
            continue
        n = int(m.group(1))
        if n in seen:
            continue
        seen.add(n)
        out.append(PR(title, n, parse_local(at)))
    return out


# ------------------------------------------------------------------ efforts from the Status file
GENERIC = re.compile(r"^(building now|now|in flight|where we are|current( work)?|active)$", re.I)
WAITING = re.compile(r"waiting", re.I)
PARKED = re.compile(r"parked|next", re.I)
FACTS = re.compile(r"where things run|^ci\b|watch|environment|facts|links|how to|working model", re.I)


class Effort:
    def __init__(self, name, kind):
        self.name, self.kind, self.text = name, kind, []

    def finish(self):
        t = "\n".join(self.text)
        self.nums = {int(x) for x in PR_ANY.findall(t)}
        self.plans = set(os.path.basename(x) for x in re.findall(r"\(([^()\s\[\]]+\.md)(?:#[^)]*)?\)", t))
        w = re.sub(r"[^a-z0-9]", "", self.name.split()[0].lower()) if self.name.split() else ""
        self.word = w if len(w) >= 4 else ""
        m = re.search(r"\(([A-Z]{1,3}\d+[a-z]?)\)", self.name)  # a plan code: "LCCT (E6)"
        self.code = m.group(1) if m else ""


def bullets(lines):
    """Top-level '- **Name** …' bullets with their continuation lines."""
    cur = None
    for l in lines:
        m = re.match(r"^- \*\*(.+?)\*\*", l)
        if m:
            cur = [m.group(1).strip().rstrip(":").strip(), [l]]
            yield cur
            continue
        if l.startswith("- ") or (l and not l.startswith(" ")):
            cur = None
            continue
        if cur is not None:
            cur[1].append(l)


def parse_status(lines):
    """-> (efforts in order, waiting-on-owner bullets)."""
    efforts, waiting, sec, sec_lines = [], [], None, []

    def flush():
        if sec is None:
            return
        h = re.sub(r"^[^A-Za-z#]+", "", sec).strip()
        if WAITING.search(h):
            for l in sec_lines:
                if l.startswith("- "):
                    waiting.append(l[2:])
            return
        if FACTS.search(h):
            return
        kind = "parked" if PARKED.search(h) and not re.search(r"\bnow\b", h, re.I) else "now"
        m = re.search(r"now\s*[—–-]\s*(.+)$", h, re.I)
        if GENERIC.match(h) or kind == "parked":
            for name, txt in bullets(sec_lines):
                e = Effort(strip_md(name), kind)
                e.text = txt
                efforts.append(e)
        else:
            e = Effort(strip_md(m.group(1) if m else h.split(":")[0]), kind)
            e.text = sec_lines
            efforts.append(e)

    for l in lines:
        if l.startswith("## "):
            flush()
            sec, sec_lines = l[3:], []
        elif sec is not None:
            sec_lines.append(l)
    flush()
    for e in efforts:
        e.finish()
    return efforts, waiting


def plan_title(path):
    try:
        with open(path) as f:
            for l in f:
                if l.startswith("# "):
                    return strip_md(l[2:]).split(" — ")[0].strip()
    except OSError:
        pass
    return os.path.splitext(os.path.basename(path))[0]


class Grouper:
    def __init__(self, efforts, hints, checkout):
        self.efforts, self.hints, self.checkout = efforts, hints, checkout
        self.by_plan = {}
        for e in efforts:
            for p in e.plans:
                self.by_plan.setdefault(p, e.name)

    def direct(self, n):
        for e in self.efforts:
            if n in e.nums:
                return e.name
        for f in self.hints.get(n, []):
            b = os.path.basename(f)
            if b in self.by_plan:
                return self.by_plan[b]
        for f in self.hints.get(n, []):  # a plan no entry links: its code or file name, else its title
            title = plan_title(os.path.join(self.checkout, f))
            stem = os.path.basename(f).split("-")[0].split(".")[0].lower()
            for e in self.efforts:
                if (e.code and re.search(r"\b%s\b" % re.escape(e.code), title)) or (e.word and stem == e.word):
                    return e.name
            return title
        return None

    def group(self, prs):
        g = {}
        for p in prs:
            g[p.n] = self.direct(p.n)
        for p in prs:  # refers to a grouped number, or starts with an effort's first word
            if g[p.n]:
                continue
            for r in p.refs:
                g[p.n] = g.get(r) or self.direct(r)
                if g[p.n]:
                    break
            if not g[p.n]:
                w = re.sub(r"[^a-z0-9]", "", (p.title.split() or [""])[0].lower())
                for e in self.efforts:
                    if e.word and w == e.word:
                        g[p.n] = e.name
                        break
        order = [e.name for e in self.efforts]
        groups = {}
        for p in prs:
            groups.setdefault(g[p.n] or "Other", []).append(p)
        keys = sorted(groups, key=lambda k: (k == "Other", order.index(k) if k in order else len(order)))
        return [(k, groups[k]) for k in keys]


# ------------------------------------------------------------------ state files
def read_lines(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except OSError:
        return []


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def line_time(l):
    m = re.match(r"^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2})", l)
    return parse_local(m.group(1)) if m else None


def inbox_text(l):
    s = re.sub(r"^- \d{4}-\d{2}-\d{2} \d{2}:\d{2} · ", "", l)
    return re.sub(r"\s*\([^()]*\)\s*$", "", s)  # the asking session


def decided_text(l):
    s = re.sub(r"^- \d{4}-\d{2}-\d{2} \d{2}:\d{2} · ", "", l)
    s = re.sub(r"\s*\([^()]*\)\s*$", "", s)
    s = re.sub(r"\s*\[[^\]]*\]\([^)]*\)\s*$", "", s)
    return cut(s, 110)


# ------------------------------------------------------------------ runs
def run_env(workflow):
    return workflow


def utc_local(s):
    d = parse_iso(s)
    return d


def deploy_lines(lines):
    """'  App Deploy: Prod · success · started X · last update Y' → latest per workflow."""
    latest = {}
    for l in lines:
        s = l.strip()
        if is_none(s) or s.startswith("housekeeping"):
            continue
        parts = s.split(" · ")
        if len(parts) < 3:
            continue
        wf, outcome = parts[0], parts[1]
        t = None
        for p in parts[2:]:
            if p.startswith("last update ") or p.startswith("started "):
                t = utc_local(p.split(" ", 2)[-1]) or t
        if len(parts) == 2 or re.match(r"^\d{4}-", parts[1]):  # done-today shape: wf · createdAt
            outcome, t = "success", utc_local(parts[1])
        if wf not in latest or (t and latest[wf][1] and t > latest[wf][1]):
            latest[wf] = (outcome, t)
    out = []
    for wf, (outcome, t) in sorted(latest.items(), key=lambda x: x[1][1] or NOW):
        if outcome == "success":
            out.append(f"{wf} {when(t)}")
        elif outcome in ("in_progress", "queued", "waiting", "pending"):
            out.append(f"{wf} running since {when(t)}")
        else:
            out.append(f"{wf} {outcome.upper()} {when(t)}")
    return out


# ------------------------------------------------------------------ now
def render_now(secs, args):
    proj = " ".join(body(secs, "project"))
    project = kv(proj, "key")
    level = kv(proj, "level")
    checkout = kv(proj, "checkout")
    owner = kv(proj, "owner") or "owner"
    state_dir = next((re.search(r"state dir (.+)$", l).group(1).strip() for l in body(secs, "project") if "state dir " in l), ".status")
    has_repo = "repo none" not in proj
    in_git = "not a git repo" not in proj

    mode_line = next((l for l in body(secs, "mode") if l.startswith("mode ")), "mode ?")
    mode = mode_line.split()[1]
    inferred = re.search(r"\(inferred: (.*)\)$", mode_line)

    away = None
    for l in body(secs, "owner"):
        m = re.match(r"away since: .*\((.+)\)$", l)
        if m:
            away = parse_iso(m.group(1))
    away = away or NOW.replace(hour=0, minute=0, second=0, microsecond=0)

    status_lines = body(secs, "status file")
    efforts, standing = parse_status(status_lines) if status_lines else ([], [])
    hints = {}
    for l in body(secs, "effort hints"):
        m = re.match(r"#(\d+) → (.+)$", l)
        if m and m.group(2) != "none":
            hints[int(m.group(1))] = m.group(2).split()
    grouper = Grouper(efforts, hints, checkout)

    # sessions
    this_session = "none"
    others = []
    for l in body(secs, "sessions"):
        if l.startswith("this session: "):
            this_session = l.split(": ", 1)[1].split(" (")[0]
            continue
        p = l.split(" · ")
        if len(p) >= 6:
            name, kind, st, last, branch = p[0], p[1], p[2], p[3].replace("last active ", ""), p[4].replace("branch ", "")
            if st == "busy":
                state = "busy"
            elif st == "idle":
                state = f"idle since {when(parse_local(last))}"
            elif st == "blocked":
                state = "blocked: needs input"
            else:
                state = st
            others.append(f"{name} · {state} · {branch}")

    # inbox: --ask appends first
    wpath = os.path.join(state_dir, "waiting.md")
    waiting = [l for l in read_lines(wpath) if l.startswith("- ")]
    notes = []
    for q in args["ask"]:
        if len(waiting) >= MAX_INBOX:
            notes.append(f"NOT ADDED (inbox full, {MAX_INBOX} of {MAX_INBOX}): {cut(q, 80)}")
            continue
        line = f"- {NOW.strftime('%Y-%m-%d %H:%M')} · {q} ({this_session if this_session != 'none' else 'shell'})"
        existing = read_lines(wpath) or [f"# {project} · waiting on {owner}"]
        write_atomic(wpath, "\n".join(existing + [line]) + "\n")
        waiting.append(line)

    dpath = os.path.join(state_dir, "decided.md")
    decided_all = [l for l in read_lines(dpath) if l.startswith("- ")]
    if args["seen"]:  # /status reconciles: drop decisions older than 7 days
        keep = [l for l in read_lines(dpath) if not (l.startswith("- ") and (line_time(l) or NOW) < NOW - timedelta(days=7))]
        if len(keep) != len(read_lines(dpath)):
            write_atomic(dpath, "\n".join(keep) + "\n")
    decided = [l for l in decided_all if (line_time(l) or NOW) >= NOW - timedelta(hours=24)]

    out = []
    B = out.append

    # ---- since you were away
    since = []
    sb = body(secs, "since")
    def sub(lines, prefix):
        res, on = [], False
        for l in lines:
            if not l.startswith(" "):
                on = l.startswith(prefix)
                continue
            if on:
                res.append(l)
        return res
    merged_hdr = next((l for l in sb if l.startswith("merged on ")), "")
    away_prs = merged_prs(sub(sb, "merged on "))
    if away_prs:
        names = "; ".join(p.name(40) for p in away_prs[-4:])
        more = f"; +{len(away_prs) - 4} more (Done today)" if len(away_prs) > 4 else ""
        nf = " (origin not fetched)" if "fetch failed" in merged_hdr else ""
        since.append(f"- Merged{nf}: {names}{more}")
    if in_git and not has_repo:
        commits = [l for l in sub(sb, "local commits") if not is_none(l)]
        if commits:
            branches = sorted({p.split(" · ")[3].split(",")[0].replace("HEAD -> ", "").strip() or "?" for p in (c.strip() for c in commits) if len(p.split(" · ")) > 4})
            gist = commits[0].strip().split(" · ")[-1]
            since.append(f"- Committed: {len(commits)} commits on {', '.join(b for b in branches if b) or '?'}: {cut(gist, 60)}")
    dep = deploy_lines(sub(sb, "deploy runs on"))
    if dep:
        since.append("- Deployed: " + "; ".join(dep))
    red = []
    for l in sub(sb, "runs on"):
        if not is_none(l):
            p = l.strip().split(" · ")
            red.append(f"{p[0]} since {when(parse_iso(p[2].replace('started ', '')))}")
    if red:
        since.append("- Red on main: " + "; ".join(dict.fromkeys(red)))
    new_in = [l for l in waiting if (line_time(l) or away) > away]
    new_dec = [l for l in decided_all if (line_time(l) or away) > away]
    if new_in or new_dec:
        since.append(f"- New: {len(new_in)} in your inbox; {len(new_dec)} decided for you")

    # ---- header
    running_items = []
    for r in args["running"]:
        running_items.append(("This session", r))
    ra = body(secs, "runs-active")
    active = {}
    for l in ra:
        if l.startswith("red on ") or l.startswith(" "):
            continue
        if is_none(l) or l.startswith("no GitHub"):
            continue
        p = l.split(" · ")
        if len(p) >= 5:
            key = f"{p[0]} on {p[1]}"
            t = parse_iso(p[4])
            n, t0 = active.get(key, (0, t))
            active[key] = (n + 1, min(t0, t) if t0 and t else (t0 or t))
    for k, (n, t) in active.items():
        running_items.append(("CI and deploys", f"{k}{f' ×{n}' if n > 1 else ''} · since {when(t)}"))
    for o in others:
        running_items.append(("Other sessions", o))

    stamp = f"{NOW.strftime('%a')} {NOW.day} {NOW.strftime('%b %H:%M')}"
    B(f"<!-- overview:now project={project} level={level} mode={mode} updated={NOW.isoformat(timespec='seconds')} "
      f"running={len(running_items)} waiting={len(waiting)} inbox_full={'yes' if len(waiting) >= MAX_INBOX else 'no'} -->")
    B(f"# {project} · now · {stamp}")
    B("")
    if len(waiting) >= MAX_INBOX:
        B(f"**INBOX FULL ({len(waiting)} of {MAX_INBOX}): no new work that needs you; answer one to free a slot.**")
        B("")
    for n in notes:
        B(f"**{n}**")
        B("")

    B(f"## Since you were away ({when(away, True)}, {duration(away, NOW)})")
    out.extend(since or [f"Nothing changed since {when(away, True)}."])
    B("")

    # ---- where you left off (minimal level)
    if level == "minimal":
        ls = [l for l in body(secs, "last-sessions") if " · " in l and not l.startswith("left off")]
        if ls:
            p = ls[0].split(" · ")
            live = " · still open" if "LIVE" in p else ""
            B("## Where you left off")
            B(f"- {when(parse_local(p[0]), True)} · {p[1]} · {p[2]}{live}")
            lo = next((l for l in body(secs, "last-sessions") if l.startswith("left off in")), "")
            m = re.search(r"branch (\S+) · (\d+) uncommitted files · (\d+) commits not on", lo)
            if m and (m.group(2) != "0" or m.group(3) != "0"):
                bits = []
                if m.group(2) != "0":
                    bits.append(f"{m.group(2)} uncommitted files")
                if m.group(3) != "0":
                    bits.append(f"{m.group(3)} commits not merged")
                B(f"- {', '.join(bits)} on {m.group(1)}")
            B("")

    # ---- left for later (/wrap)
    nxt = [l for l in read_lines(os.path.join(state_dir, "next.md")) if l.startswith("- ")]
    lfl = body(secs, "left-for-later")
    ho = next((l for l in lfl if l.startswith("handoff: ") and l.endswith("· fresh")), "")
    if nxt or ho:
        B(f"## Left for later ({len(nxt)})")
        for l in nxt[:4]:
            B("- " + cut(re.sub(r"^- \d{4}-\d{2}-\d{2} · ", "", l), 150))
        if len(nxt) > 4:
            B(f"+{len(nxt) - 4} more (.status/next.md)")
        if ho:
            p = ho.split(" · ")
            B(f"Handoff for the next agent ({when(parse_local(p[1].replace('written ', '')), True)}): .status/handoff.md")
        B("")

    # ---- waiting
    B(f"## Waiting on {owner} ({len(waiting)} of {MAX_INBOX})")
    for i, l in enumerate(waiting, 1):
        t = line_time(l)
        age = f" (asked {when(t)}, still open?)" if t and t < NOW - timedelta(days=2) else ""
        B(f"{i}. {inbox_text(l)}{age}")
    if not waiting:
        B("Nothing.")
    if standing and level == "full":
        names = [first_clause(s) for s in standing]
        more = f"; +{len(names) - 4} more (STATUS)" if len(names) > 4 else ""
        B(f"Standing (STATUS): {'; '.join(names[:4])}{more}")
    B("")

    # ---- decided
    if decided:
        B("## Decided for you (last 24h) · veto by saying which")
        for l in list(reversed(decided))[:5]:
            B(f"- {when(line_time(l))} {decided_text(l)}")
        if len(decided) > 5:
            B(f"+{len(decided) - 5} more (decided.md)")
        B("")

    # ---- waves: attention items only (waves.py)
    wv = [l.strip() for l in body(secs, "waves") if l.strip()]
    if wv:
        B("## Waves")
        out.extend(f"- {cut(l, 150)}" for l in wv)
        B("")

    # ---- running
    B("## Running")
    if not running_items:
        B("Nothing running.")
    last = None
    for g, item in running_items:
        if g != last:
            if last is not None:
                B("")
            B(f"**{g}**")
            last = g
        B(f"- {item}")
    B("")

    # ---- done today
    done = []
    db = body(secs, "done-today")
    today_prs = merged_prs(sub(db, "merged on "))
    if today_prs:
        for name, prs in grouper.group(today_prs):
            items = "; ".join(p.name(40) for p in prs[-4:])
            more = f"; +{len(prs) - 4} more" if len(prs) > 4 else ""
            done.append(f"- {name}: {items}{more}" if level == "full" else f"- {items}{more}")
    elif in_git and not has_repo:
        commits = [l.strip() for l in sub(db, "commits today") if not is_none(l)]
        if commits:
            done.append(f"- {len(commits)} commits: " + "; ".join(cut(c.split(' · ')[-1], 40) for c in commits[:3])
                        + (f"; +{len(commits) - 3} more" if len(commits) > 3 else ""))
    dd = deploy_lines([l for l in sub(db, "deploy runs on") if "housekeeping" not in l])
    if dd:
        done.append("- Deployed: " + "; ".join(dd))
    if done:
        B("## Done today")
        out.extend(done)
        B("")

    # ---- maintenance
    maint = []
    reds = [l.strip().split(" · ")[0] for l in ra if l.startswith("  ") and not is_none(l)]
    if reds:
        maint.append("red on main: " + ", ".join(reds))
    hk = next((l for l in db if "housekeeping" in l), "")
    m = re.search(r"(\d+) runs", hk)
    if m:
        maint.append(f"{m.group(1)} housekeeping deploys today")
    if maint:
        B(f"Maintenance: {'; '.join(maint)} → /status arc")
    B("Other view: /status arc")
    if inferred:
        tail = "; set mode: in STATUS to fix it" if status_lines else ""
        B(f"Mode inferred: {inferred.group(1)}{tail}")

    text = "\n".join(out) + "\n"
    write_atomic(os.path.join(state_dir, "now.md"), text)
    if args["seen"]:
        write_atomic(os.path.join(state_dir, "seen"), NOW.isoformat(timespec="seconds") + "\n")
    sys.stdout.write(text)


# ------------------------------------------------------------------ arc: pre-rendered parts
def render_arc(raw, secs):
    sys.stdout.write(raw)
    proj = " ".join(body(secs, "project"))
    checkout = kv(proj, "checkout")
    status_lines = body(secs, "status file")
    efforts, _ = parse_status(status_lines) if status_lines else ([], [])
    out = ["", "## pre-rendered (by render.py from the facts above; use these lines as they are)"]
    if efforts:
        out.append("efforts parsed from the status file (name · now|parked · numbers named · plans linked):")
        for e in efforts:
            out.append(f"  {e.name} · {e.kind} · {' '.join('#%d' % n for n in sorted(e.nums)) or '-'} · {' '.join(sorted(e.plans)) or '-'}")
    people, bots = [], []
    for l in body(secs, "prs-open"):
        p = l.split(" · ")
        if len(p) < 8:
            continue
        pr = PR(f"{p[1]} ({p[0]})", int(p[0][1:]), None)
        pr.checks, pr.draft, pr.opened = p[7], p[4], p[6]
        (bots if p[3] == "BOT" else people).append(pr)
    if people and efforts:
        out.append("open PRs by effort (status file, then title refs and first word; plans not searched at arc):")
        for name, prs in Grouper(efforts, {}, checkout).group(people):
            out.append(f"  {name}: " + "; ".join(f"{p.name(50)} {p.checks}" for p in prs))
    wv = [l for l in body(secs, "waves") if l.strip()]
    if wv and (kv(proj, "level") == "full" or not any(l.startswith("No waves yet") for l in wv)):
        out.append("Waves block (waves.py; put it under the heading ## Waves as it is, after Later):")
        out += [f"  {l}" for l in wv[1:]]
    if "repo none" in proj:
        sys.stdout.write("\n".join(out) + "\n")
        return
    out.append("Maintenance lines:")
    for p in bots:
        out.append(f"- Bot PR: {p.name(60)}, {p.checks}, open since {p.opened}")
    reds = [l.split(" · ")[0] for l in body(secs, "runs-red") if " · " in l]
    out.append(f"- Red on main: {', '.join(reds) if reds else 'none'}")
    hk = next((l for l in body(secs, "deploys") if l.startswith("housekeeping today")), "")
    if hk:
        out.append("- Housekeeping deploys today: " + hk.replace("housekeeping today: ", ""))
    iss = next((l for l in body(secs, "issues") if l.startswith("open ")), "")
    m = re.match(r"open (\S+) · opened today (\S+)", iss)
    if m:
        out.append(f"- Open issues: {m.group(1)} ({m.group(2)} opened today)")
    sys.stdout.write("\n".join(out) + "\n")


def main():
    argv = sys.argv[1:]
    view = argv.pop(0) if argv and argv[0] in ("now", "arc") else "now"
    args = {"seen": False, "running": [], "ask": []}
    while argv:
        a = argv.pop(0)
        if a == "--seen":
            args["seen"] = True
        elif a in ("--running", "--ask") and argv:
            args[a[2:]].append(argv.pop(0))
        else:
            sys.exit(f"render.py: unknown argument {a}")
    raw = sys.stdin.read()
    secs = parse_sections(raw)
    if "project" not in secs:
        sys.stdout.write(raw)
        sys.exit("render.py: no gather output to render")
    if view == "now":
        render_now(secs, args)
    else:
        render_arc(raw, secs)


if __name__ == "__main__":
    main()
