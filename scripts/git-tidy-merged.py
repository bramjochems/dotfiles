#!/usr/bin/env python3
"""git-tidy-merged: delete local branches (and their linked worktrees) whose
work is safely merged. Dry run by default; --go to actually delete.

Conservative by design: anything it cannot prove safe is kept and reported.
A branch is deleted only if ALL of these hold:

  1. It is not the default branch, not checked out in the main checkout or in
     a worktree that is kept, not mid-rebase/bisect, and not matched by a keep
     rule: `git config branch.<name>.keep true`, a glob in
     <main checkout>/.status/keep-branches, or the built-in globs below.
  2. Either (a) its tip is an ancestor of origin/<default>, or (b) gh shows a
     MERGED PR into <default> with that head branch whose headRefOid equals the
     local tip exactly. Any OPEN PR for the branch keeps it; so does a latest
     PR that was closed without merging. If gh cannot answer, keep.
  3. If it is checked out in a linked worktree: the worktree has no modified,
     staged or untracked files, is not locked (unless the lock's pid is dead),
     no live Claude session and no process has its cwd inside it, it is not a
     .claude/worktrees agent worktree in a repo with a live session, and every
     directory in it is ours to delete. Then `git worktree remove` (never
     --force), then the branch.
  4. In a repo with a live Claude session: no commit, ref update or worktree
     creation for it in the last --hours (default 12), unless 2(b)'s exact
     match holds (a merged PR whose head is the local tip): a session's own
     just-merged branch may go, a fresh branch or placeholder may not.

Case (a) deletes with `git branch -d`; case (b) with `git branch -D` right
after re-checking that the tip still equals the PR head. Never touches the
main checkout's working tree, never deletes remote branches, never rm -rf.
Only state change in a dry run: `git fetch --prune origin` (remote-tracking
refs only).
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PROJECTS_ROOT = Path(os.environ.get("PROJECTS_ROOT", Path.home() / "projects")).resolve()
BUILTIN_KEEP_GLOBS = ["archive/*", "backup/*", "keep/*", "wip/*"]
SKIP_DIRS = {"node_modules", ".venv", "venv", ".git", "__pycache__", ".next", "dist", "build", ".cache"}


# ---------------------------------------------------------------- helpers

def run(args, cwd=None, check=False):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {p.stderr.strip()}")
    return p


def git(repo, *args, check=False):
    return run(["git", "-C", str(repo), *args], check=check)


def inside(path, root):
    path, root = str(path), str(root).rstrip("/")
    return path == root or path.startswith(root + "/")


def pid_alive(pid):
    return Path(f"/proc/{pid}").exists()


def live_sessions():
    """Live Claude sessions as dicts with resolved 'cwd'. None if unknown."""
    p = run(["claude", "agents", "--json"])
    if p.returncode != 0:
        return None
    try:
        data = json.loads(p.stdout)
    except json.JSONDecodeError:
        return None
    out = []
    for a in data:
        cwd = a.get("cwd")
        if not cwd:
            continue
        pid = a.get("pid")
        if pid and not pid_alive(pid):
            continue
        out.append({"cwd": os.path.realpath(cwd), "name": a.get("name") or a.get("id") or "?",
                    "pid": pid})
    return out


def process_cwds():
    """cwd of every process we can see (ours, at least)."""
    cwds = []
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            cwds.append((int(d.name), os.path.realpath(os.readlink(d / "cwd"))))
        except OSError:
            pass
    return cwds


def github_slug(url):
    m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$", url or "")
    return f"{m.group(1)}/{m.group(2)}" if m else None


def find_main_checkouts(root):
    found = []
    for dirpath, dirnames, _ in os.walk(root):
        if os.path.isdir(os.path.join(dirpath, ".git")):
            found.append(Path(dirpath))
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != "worktrees"]
        if Path(dirpath).relative_to(root).parts.__len__() >= 4:
            dirnames[:] = []
    return sorted(found)


# ---------------------------------------------------------------- per repo

class Repo:
    def __init__(self, path, sessions, proc_cwds, hours):
        top = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir", check=True).stdout.strip()
        self.common_dir = Path(top)
        self.main = self.common_dir.parent  # main checkout (non-bare repos)
        self.sessions_all = sessions
        self.proc_cwds = proc_cwds
        self.hours = hours
        self.items = []  # (action, branch, worktree, reason_key, reason_text)

    def rel(self, p):
        try:
            return str(Path(p).relative_to(PROJECTS_ROOT))
        except ValueError:
            return str(p)

    # -- facts
    def load(self):
        f = git(self.main, "fetch", "--quiet", "--prune", "origin")
        if f.returncode != 0:
            msg = next((l for l in f.stderr.splitlines() if l.startswith("fatal")), f.stderr.strip()[:120] or "no output")
            return f"git fetch origin failed ({msg}); nothing decided"
        ref = git(self.main, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").stdout.strip()
        self.slug = github_slug(git(self.main, "config", "--get", "remote.origin.url").stdout.strip())
        if ref.startswith("origin/"):
            self.default = ref[len("origin/"):]
        elif self.slug:
            p = run(["gh", "repo", "view", self.slug, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"])
            self.default = p.stdout.strip() if p.returncode == 0 else ""
        else:
            self.default = ""
        if not self.default or git(self.main, "rev-parse", "--verify", "--quiet",
                                   f"refs/remotes/origin/{self.default}").returncode != 0:
            return "default branch unknown (no origin/HEAD); nothing decided"
        self.target = f"refs/remotes/origin/{self.default}"

        # worktrees
        self.worktrees = []
        cur = None
        for line in git(self.main, "worktree", "list", "--porcelain").stdout.splitlines():
            if line.startswith("worktree "):
                cur = {"path": os.path.realpath(line[9:]), "branch": None, "locked": None,
                       "prunable": False, "main": not self.worktrees}
                self.worktrees.append(cur)
            elif line.startswith("branch refs/heads/"):
                cur["branch"] = line[len("branch refs/heads/"):]
            elif line == "locked" or line.startswith("locked "):
                cur["locked"] = line[7:] if line.startswith("locked ") else ""
            elif line == "prunable" or line.startswith("prunable "):
                cur["prunable"] = True
        for wt in self.worktrees:
            wt["gitdir"] = Path(git(wt["path"], "rev-parse", "--path-format=absolute", "--git-dir").stdout.strip()
                                or "/nonexistent") if not wt["prunable"] else None

        # sessions in this repo
        paths = [w["path"] for w in self.worktrees]
        if self.sessions_all is None:
            self.sessions = None
        else:
            self.sessions = [s for s in self.sessions_all if any(inside(s["cwd"], p) for p in paths)]
            # a session started above the repo (e.g. in ~/projects) can work in it too
            self.sessions += [dict(s, name=s["name"] + f" (above, in {self.rel(s['cwd']) or s['cwd']})")
                              for s in self.sessions_all
                              if s not in self.sessions and any(inside(p, s["cwd"]) for p in paths)]
        # a live pid holding a worktree lock also counts as a live session here
        self.lock_pids_live = []
        for wt in self.worktrees:
            pid = self.lock_pid(wt)
            if pid and pid_alive(pid):
                self.lock_pids_live.append(pid)
        self.session_live = self.sessions is None or bool(self.sessions) or bool(self.lock_pids_live)

        # keep globs
        self.keep_globs = list(BUILTIN_KEEP_GLOBS)
        kf = self.main / ".status" / "keep-branches"
        if kf.exists():
            for l in kf.read_text().splitlines():
                l = l.strip()
                if l and not l.startswith("#"):
                    self.keep_globs.append(l)

        # in-progress rebase/bisect per worktree
        self.busy_branches = {}
        for wt in self.worktrees:
            gd = wt["gitdir"]
            if not gd:
                continue
            for sub in ("rebase-merge/head-name", "rebase-apply/head-name"):
                f = gd / sub
                if f.exists():
                    name = f.read_text().strip().removeprefix("refs/heads/")
                    self.busy_branches[name] = "rebase in progress in " + self.rel(wt["path"])
            if (gd / "BISECT_START").exists():
                name = (gd / "BISECT_START").read_text().strip().removeprefix("refs/heads/")
                self.busy_branches[name] = "bisect in progress in " + self.rel(wt["path"])

        fmt = "%(refname:short)%00%(objectname)%00%(committerdate:unix)"
        self.branches = []
        for line in git(self.main, "for-each-ref", f"--format={fmt}", "refs/heads/").stdout.splitlines():
            name, sha, cdate = line.split("\0")
            self.branches.append({"name": name, "sha": sha, "cdate": int(cdate or 0)})
        return None

    def lock_pid(self, wt):
        if wt["locked"] is None:
            return None
        m = re.search(r"\bpid (\d+)", wt["locked"])
        return int(m.group(1)) if m else None

    def last_activity(self, name, wt):
        ts = []
        log = self.common_dir / "logs" / "refs" / "heads" / name
        if log.exists():
            for l in log.read_text(errors="replace").splitlines():
                m = re.search(r"> (\d+) [+-]\d{4}\t", l)
                if m:
                    ts.append(int(m.group(1)))
        if wt and wt.get("gitdir"):
            # worktree creation / last checkout (not the dir mtime: index refreshes touch that)
            for f in ("commondir", "HEAD"):
                try:
                    ts.append(int((wt["gitdir"] / f).stat().st_mtime))
                except OSError:
                    pass
        return max(ts) if ts else 0

    def prs(self, name):
        """PRs with this head branch, newest first, or None if gh can't answer."""
        if not self.slug:
            return None
        p = run(["gh", "pr", "list", "--repo", self.slug, "--head", name, "--state", "all",
                 "--limit", "100", "--json", "number,state,headRefOid,baseRefName,createdAt"])
        if p.returncode != 0:
            return None
        try:
            return sorted(json.loads(p.stdout), key=lambda x: x["createdAt"], reverse=True)
        except (json.JSONDecodeError, KeyError):
            return None

    def worktree_blocker(self, wt):
        """Reason a linked worktree may not be removed, or None."""
        path = wt["path"]
        if wt["prunable"]:
            return "worktree-missing", f"worktree dir missing ({self.rel(path)}); left for `git worktree prune`"
        if wt["locked"] is not None:
            pid = self.lock_pid(wt)
            if pid is None:
                return "worktree-locked", f"worktree locked ({wt['locked'] or 'no reason'})"
            if pid_alive(pid):
                return "worktree-locked", f"worktree locked by live pid {pid}"
        if self.sessions is None:
            return "sessions-unknown", "`claude agents --json` failed; can't rule out a session in the worktree"
        for s in self.sessions:
            if inside(s["cwd"], path) and not "(above, " in s["name"]:
                return "worktree-in-use", f"live session {s['name']} is in the worktree"
        for pid, cwd in self.proc_cwds:
            if inside(cwd, path):
                return "worktree-in-use", f"process {pid} has its cwd in the worktree"
        inside_sessions = [s for s in self.sessions if "(above, " not in s["name"]]
        if (inside_sessions or self.lock_pids_live) and inside(path, self.main / ".claude" / "worktrees"):
            names = ", ".join(s["name"] for s in inside_sessions) or "lock holder"
            return "agent-worktree-live-repo", f"Claude agent worktree while a session is live in this repo ({names})"
        st = git(path, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none")
        if st.returncode != 0 or st.stderr.strip():
            return "worktree-dirty", f"git status failed or warned: {(st.stderr.strip() or 'error')[:120]}"
        if st.stdout.strip():
            n = len(st.stdout.splitlines())
            return "worktree-dirty", f"worktree has {n} modified/staged/untracked path(s)"
        if (Path(path) / ".gitmodules").exists():
            return "worktree-submodules", "worktree has submodules (remove would need --force)"
        bad = self.undeletable(path)
        if bad:
            return "worktree-unwritable", f"not ours to delete: {self.rel(bad)}"
        return None

    def undeletable(self, root):
        """First directory under root we can't fully read/write, so that
        `git worktree remove` would fail halfway. None if all fine."""
        uid = os.getuid()
        err = []
        for dirpath, dirnames, _ in os.walk(root, onerror=lambda e: err.append(e.filename)):
            if err:
                return err[0]
            try:
                st = os.lstat(dirpath)
            except OSError:
                return dirpath
            if st.st_uid != uid or not os.access(dirpath, os.R_OK | os.W_OK | os.X_OK):
                return dirpath
        return err[0] if err else None

    # -- decisions
    def plan(self):
        now = time.time()
        wt_by_branch = {w["branch"]: w for w in self.worktrees if w["branch"]}
        candidates = []
        for b in self.branches:
            name = b["name"]
            wt = wt_by_branch.get(name)
            if name == self.default:
                self.keep(name, wt, "default-branch", "default branch")
                continue
            cfg = git(self.main, "config", "--get", f"branch.{name}.keep").stdout.strip().lower()
            if cfg and cfg not in ("false", "no", "off", "0"):
                self.keep(name, wt, "keep-rule", f"branch.{name}.keep = {cfg}")
                continue
            g = next((g for g in self.keep_globs if fnmatch.fnmatchcase(name, g)), None)
            if g:
                src = "built-in" if g in BUILTIN_KEEP_GLOBS else ".status/keep-branches"
                self.keep(name, wt, "keep-rule", f"matches keep glob {g} ({src})")
                continue
            if name in self.busy_branches:
                self.keep(name, wt, "in-use", self.busy_branches[name])
                continue
            m = re.fullmatch(r"worktree-agent-(a[0-9a-f]+)", name)
            if m and not wt and any(Path(w["path"]).name == f"agent-{m.group(1)}" for w in self.worktrees):
                self.keep(name, wt, "in-use", f"placeholder of agent worktree agent-{m.group(1)}, which still exists")
                continue
            if wt and wt["main"]:
                self.keep(name, None, "main-checkout", "checked out in the main checkout")
                continue
            recent = None
            if self.session_live:
                act = max(b["cdate"], self.last_activity(name, wt))
                if now - act < self.hours * 3600:
                    who = "unknown (claude agents failed)" if self.sessions is None else \
                        ", ".join(s["name"] for s in self.sessions) or "a live lock holder"
                    recent = f"touched {(now - act) / 3600:.1f}h ago; live session in repo: {who}"
            candidates.append((b, wt, recent))

        with ThreadPoolExecutor(8) as ex:
            pr_lists = list(ex.map(lambda c: self.prs(c[0]["name"]), candidates))

        for (b, wt, recent), prs in zip(candidates, pr_lists):
            name, sha = b["name"], b["sha"]
            # Recent activity in a repo with a live session keeps a branch, unless a merged PR
            # into the default branch has exactly this tip as its head: that work is provably
            # done (a fresh branch or a placeholder never has one), so the caller's own
            # just-merged branch can go. Worktree checks below still apply.
            if recent and not (prs and any(p["state"] == "MERGED" and p["baseRefName"] == self.default
                                            and p["headRefOid"] == sha for p in prs)
                               and not any(p["state"] == "OPEN" for p in prs)):
                self.keep(name, wt, "recent-live-session", recent)
                continue
            if prs is None:
                self.keep(name, wt, "gh-unavailable", "couldn't read PRs from gh (open PR can't be ruled out)")
                continue
            open_ = [p for p in prs if p["state"] == "OPEN"]
            if open_:
                self.keep(name, wt, "open-pr", f"open PR #{open_[0]['number']}")
                continue
            if prs and prs[0]["state"] == "CLOSED":
                self.keep(name, wt, "closed-pr", f"latest PR #{prs[0]['number']} was closed without merging")
                continue
            ancestor = git(self.main, "merge-base", "--is-ancestor", sha, self.target).returncode == 0
            merged = [p for p in prs if p["state"] == "MERGED" and p["baseRefName"] == self.default]
            match = next((p for p in merged if p["headRefOid"] == sha), None)
            if ancestor:
                how, reason = "a", f"tip is an ancestor of origin/{self.default}"
            elif match:
                how, reason = "b", f"merged PR #{match['number']}, local tip = PR head"
            else:
                if merged:
                    why = f"merged PR #{merged[0]['number']} but local tip differs from its head (local commits after/besides the PR)"
                elif prs:
                    why = f"PR #{prs[0]['number']} is {prs[0]['state'].lower()} into {prs[0]['baseRefName']}, not {self.default}"
                else:
                    why = f"not merged: not an ancestor of origin/{self.default}, no PR"
                self.keep(name, wt, "not-merged", why)
                continue
            if wt:
                block = self.worktree_blocker(wt)
                if block:
                    self.keep(name, wt, *block)
                    continue
            self.items.append(("delete", name, wt, how, reason, match["headRefOid"] if match and how == "b" else None))

    def keep(self, name, wt, key, text):
        self.items.append(("keep", name, wt, key, text, None))

    # -- actions
    def execute(self):
        results = []
        for i, (action, name, wt, how, reason, pr_head) in enumerate(self.items):
            if action != "delete":
                continue
            err = self.delete_one(name, wt, how, pr_head)
            if err:
                self.items[i] = ("keep", name, wt, "delete-refused", err, None)
        return results

    def delete_one(self, name, wt, how, pr_head):
        cur = git(self.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}").stdout.strip()
        if how == "b" and cur != pr_head:
            return f"tip changed to {cur[:10]} since the check; kept"
        if how == "a" and git(self.main, "merge-base", "--is-ancestor", cur, self.target).returncode != 0:
            return "tip changed and is no longer an ancestor; kept"
        if wt:
            block = self.worktree_blocker(wt)  # re-check right before removal
            if block:
                return block[1]
            if wt["locked"] is not None:  # lock held by a dead pid (checked above)
                u = git(self.main, "worktree", "unlock", wt["path"])
                if u.returncode != 0:
                    return f"worktree unlock failed: {u.stderr.strip()}"
            r = git(self.main, "worktree", "remove", wt["path"])
            if r.returncode != 0:
                return f"git worktree remove refused (would need force): {r.stderr.strip()[:160]}"
        if how == "b":
            cur = git(self.main, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}").stdout.strip()
            if cur != pr_head:
                return f"tip changed to {cur[:10]} before -D; kept" + (" (worktree already removed)" if wt else "")
            r = git(self.main, "branch", "-D", name)
        else:
            r = git(self.main, "branch", "-d", name)
        if r.returncode != 0:
            return f"git branch {'-D' if how == 'b' else '-d'} refused: {r.stderr.strip()[:160]}" + \
                (" (worktree already removed)" if wt else "")
        return None

    # -- output
    def report(self, go):
        deletes = [x for x in self.items if x[0] == "delete"]
        keeps = [x for x in self.items if x[0] == "keep"]
        verb = "deleted" if go else "would delete"
        for _, name, wt, how, reason, _ in deletes:
            w = f"  + worktree {self.rel(wt['path'])}" if wt else ""
            flag = "-d" if how == "a" else "-D"
            print(f"  {verb:12}  {name}{w}\n                ({flag}) {reason}")
        for _, name, wt, key, reason, _ in sorted(keeps, key=lambda x: (x[3], x[1])):
            w = f"  [worktree {self.rel(wt['path'])}]" if wt else ""
            print(f"  keep          {name}{w}\n                {key}: {reason}")
        return len(deletes), Counter(x[3] for x in keeps)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("repos", nargs="*", help="repo paths (default: current repo)")
    ap.add_argument("--all", action="store_true", help=f"every main checkout under {PROJECTS_ROOT}")
    ap.add_argument("--go", action="store_true", help="actually delete (default: dry run)")
    ap.add_argument("--hours", type=float, default=12, help="recency window in repos with a live session (default 12)")
    a = ap.parse_args()

    if a.all and a.repos:
        ap.error("give repo paths or --all, not both")
    paths = find_main_checkouts(PROJECTS_ROOT) if a.all else [Path(p) for p in (a.repos or ["."])]

    sessions = live_sessions()
    if sessions is None:
        print("warning: `claude agents --json` failed: every repo is treated as having a live session", file=sys.stderr)
    proc = process_cwds()

    total_del, total_keep, seen = 0, Counter(), set()
    print(f"git-tidy-merged {'(--go: DELETING)' if a.go else '(dry run; --go to delete)'}")
    for p in paths:
        try:
            repo = Repo(p, sessions, proc, a.hours)
        except RuntimeError as e:
            print(f"\n== {p}\n  skipped: not a git repo ({e})")
            continue
        if repo.main in seen:
            continue
        seen.add(repo.main)
        err = repo.load()
        print(f"\n== {repo.rel(repo.main)}", end="")
        if err:
            print(f"\n  skipped: {err}")
            total_keep["repo-skipped"] += 1
            continue
        live = []
        if repo.sessions is None:
            live = ["unknown"]
        else:
            live = [s["name"] for s in repo.sessions] + [f"lock pid {x}" for x in sorted(set(repo.lock_pids_live))
                                                         if x not in {s['pid'] for s in repo.sessions}]
        print(f"  (default {repo.default}; live: {', '.join(live) or 'none'})")
        repo.plan()
        if a.go:
            repo.execute()
        n, c = repo.report(a.go)
        if not repo.items:
            print("  (no local branches)")
        total_del += n
        total_keep += c

    verb = "Deleted" if a.go else "Would delete"
    print(f"\nSummary: {verb} {total_del} branch(es); kept {sum(total_keep.values())}"
          + (": " + ", ".join(f"{k} {v}" for k, v in total_keep.most_common()) if total_keep else ""))


if __name__ == "__main__":
    main()
