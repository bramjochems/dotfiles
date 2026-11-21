#!/usr/bin/env bash
# Throwaway tests for git-tidy-merged. Builds a temp repo with fake gh/claude.
set -uo pipefail
T="$(cd "$(dirname "$0")" && pwd)/work"
TOOL=/home/bram/dotfiles/scripts/git-tidy-merged.py
rm -rf "$T"; mkdir -p "$T/bin" "$T/gh"
export FAKE_GH_DIR="$T/gh" FAKE_CLAUDE_JSON="$T/claude.json"
echo '[]' > "$FAKE_CLAUDE_JSON"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake: gh pr list --repo X --head NAME ...
while [ $# -gt 0 ]; do [ "$1" = --head ] && { shift; h="$1"; }; shift; done
f="$FAKE_GH_DIR/$(echo "$h" | tr / _).json"
[ -f "$f" ] && cat "$f" || echo '[]'
EOF
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_CLAUDE_JSON"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pr() { # branch number state headoid base
  echo "[{\"number\":$2,\"state\":\"$3\",\"headRefOid\":\"$4\",\"baseRefName\":\"${5:-main}\",\"createdAt\":\"2026-11-0${2}T00:00:00Z\"}]" \
    > "$FAKE_GH_DIR/$(echo "$1" | tr / _).json"
}

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
R="$T/repo"; cd "$R"
git config url."$T/origin.git".insteadOf https://github.com/test/repo.git
git remote set-url origin https://github.com/test/repo.git
echo node_modules/ > .gitignore; echo a > a; git add -A; git commit -qm init; git push -q origin main
git remote set-head origin main

# 1. placeholder at main -> delete (-d)
git branch worktree-agent-old
# 2. squash-merged: feat-sq tip == PR head -> delete (-D)
git checkout -q -b feat-sq; echo s > s; git commit -qam s -q; git add s; git commit -qm s2 --allow-empty
pr feat-sq 1 MERGED "$(git rev-parse HEAD)"
# 3. squash-merged, then an extra local commit -> keep
git checkout -q -b feat-sq-extra main; echo x > x; git add x; git commit -qm x
pr feat-sq-extra 2 MERGED "$(git rev-parse HEAD)"; echo y > y; git add y; git commit -qm "extra local"
git checkout -q main
# squash both into main on origin
git checkout -q -b tmp main; git merge -q --squash feat-sq >/dev/null; git commit -qm "squash #1"
git push -q origin tmp:main; git checkout -q main; git branch -q -D tmp
# 4. ancestor branch with OPEN PR -> keep
git branch open-pr-branch main; pr open-pr-branch 3 OPEN "$(git rev-parse main)"
# 5. closed-unmerged PR (not ancestor) -> keep
git checkout -q -b closed-branch main; echo c > c; git add c; git commit -qm c; pr closed-branch 4 CLOSED "$(git rev-parse HEAD)"; git checkout -q main
# 6. keep rules
git branch archive/old main; git branch parked main; git config branch.parked.keep true
git branch globbed main; mkdir -p .status; echo 'glob*' > .status/keep-branches
# 7. unmerged, no PR -> keep
git checkout -q -b local-only main; echo l > l; git add l; git commit -qm l; git checkout -q main
# 8. worktrees on merged branches
git worktree add -q "$T/wt-untracked" -b wt-untracked main; echo u > "$T/wt-untracked/new.txt"   # keep (untracked)
git worktree add -q "$T/wt-clean" -b wt-clean main; mkdir -p "$T/wt-clean/node_modules"; echo i > "$T/wt-clean/node_modules/x"  # delete (ignored ok)
git worktree add -q "$T/wt-modified" -b wt-modified main; echo m >> "$T/wt-modified/a"   # keep (modified)
git worktree add -q "$T/wt-staged" -b wt-staged main; echo st > "$T/wt-staged/st"; git -C "$T/wt-staged" add st  # keep (staged)
sleep 300 & LIVE=$!
git worktree add -q "$T/wt-livelock" -b wt-livelock main; git worktree lock --reason "claude agent x (pid $LIVE start 1)" "$T/wt-livelock"  # keep
git worktree add -q "$T/wt-deadlock" -b wt-deadlock main; git worktree lock --reason "claude agent y (pid 999999 start 1)" "$T/wt-deadlock"  # delete after unlock
git worktree add -q "$T/wt-cwd" -b wt-cwd main; (cd "$T/wt-cwd" && exec sleep 300) & CWDP=$!   # keep (process cwd)
git worktree add -q "$T/wt-sqdirty" -b wt-sqdirty main; echo q > "$T/wt-sqdirty/q"; git -C "$T/wt-sqdirty" add q; git -C "$T/wt-sqdirty" commit -qm q
pr wt-sqdirty 5 MERGED "$(git rev-parse wt-sqdirty)"; echo z > "$T/wt-sqdirty/untracked"   # keep: merged but untracked file
# 9. merged PR into a non-default base -> keep
git checkout -q -b stacked main; echo k > k; git add k; git commit -qm k; pr stacked 6 MERGED "$(git rev-parse HEAD)" other; git checkout -q main
# 10. placeholder whose agent worktree still exists (on another branch) -> keep
git branch worktree-agent-ab12 main; git worktree add -q "$T/agent-ab12" -b agent-work main; echo w > "$T/agent-ab12/w"
git status --porcelain

sleep 1
echo "===== DRY RUN (--hours 0)"
OUT1=$("$TOOL" --hours 0 "$R"); echo "$OUT1"

echo; echo "===== DRY RUN (live session in repo, recent branches)"
echo "[{\"pid\":$$,\"cwd\":\"$R\",\"name\":\"fake-live\"}]" > "$FAKE_CLAUDE_JSON"
OUT2=$("$TOOL" "$R"); echo "$OUT2"
echo "[{\"pid\":$$,\"cwd\":\"$T\",\"name\":\"fake-above\"}]" > "$FAKE_CLAUDE_JSON"
OUT2B=$("$TOOL" "$R"); echo "$OUT2B" | grep -E "live:|Summary"
echo '[]' > "$FAKE_CLAUDE_JSON"

echo; echo "===== GO (--hours 0)"
OUT3=$("$TOOL" --go --hours 0 "$R"); echo "$OUT3"
kill $LIVE $CWDP 2>/dev/null

echo; echo "===== CHECKS"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
has() { git -C "$R" rev-parse --verify -q "refs/heads/$1" >/dev/null; }
check "placeholder deleted"                 "! has worktree-agent-old"
check "squash-merged tip==head deleted"     "! has feat-sq"
check "squash-merged + extra commit kept"   "has feat-sq-extra"
check "open PR kept"                        "has open-pr-branch"
check "closed PR kept"                      "has closed-branch"
check "archive/* kept"                      "has archive/old"
check "branch.keep kept"                    "has parked"
check ".status/keep-branches glob kept"     "has globbed"
check "unmerged local-only kept"            "has local-only"
check "untracked worktree kept"             "has wt-untracked && [ -f $T/wt-untracked/new.txt ]"
check "clean worktree (ignored files) removed" "! has wt-clean && [ ! -e $T/wt-clean ]"
check "modified worktree kept"              "has wt-modified && grep -q m $T/wt-modified/a"
check "staged worktree kept"                "has wt-staged"
check "live-locked worktree kept"           "has wt-livelock && [ -d $T/wt-livelock ]"
check "dead-locked worktree removed"        "! has wt-deadlock && [ ! -e $T/wt-deadlock ]"
check "process-cwd worktree kept"           "has wt-cwd"
check "merged worktree w/ untracked kept"   "has wt-sqdirty && [ -f $T/wt-sqdirty/untracked ]"
check "PR merged into non-default kept"     "has stacked"
check "main kept, main tree untouched"      "has main && [ -z \"\$(git -C $R status --porcelain | grep -v '^?? .status/')\" ]"
check "live session: recent branches kept (dry run 2 proposes none)" "echo \"\$OUT2\" | grep -q 'Would delete 0'"
check "placeholder of existing agent worktree kept" "has worktree-agent-ab12"
check "session started above the repo blocks recent branches" "echo \"\$OUT2B\" | grep -q 'Would delete 0' && echo \"\$OUT2B\" | grep -q 'fake-above (above'"
check "remote untouched"                     "git -C $T/origin.git rev-parse -q --verify refs/heads/main >/dev/null"
exit $fail
