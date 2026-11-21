#!/usr/bin/env bash
# gather.sh — the facts /status reads, as plain sections. One script for every project.
#
#   ~/.claude/skills/status/gather.sh [now|arc]      (default: now)
#   ~/.claude/skills/status/gather.sh overview       (every project, read-only: overview.py, overview.md)
#
# `now` is fast (a few seconds): one soft `git fetch`, one `gh run list`, local git, `claude agents`,
# session transcripts and the state files. `arc` adds everything slow: open PRs with checks, prod lag,
# issues, red runs per workflow, worktrees, unmerged branches, plans and roadmap. Independent remote
# calls run in parallel; every remote call has a short timeout and prints "unknown" when it fails.
#
# Run from anywhere inside a project (a git repo, a worktree, or a plain folder). It works out:
#   - project key: the main checkout's folder name (a worktree maps to its main repo);
#   - state dir: <main checkout>/.status/ (created on first run and added to .git/info/exclude, so it
#     never shows in git status); a plain folder uses <folder>/.status/;
#   - level: "full" when the repo has docs/agentic-workflow.md and docs/agentic-workflow.bindings.md
#     (paths for STATUS, ROADMAP and plans come from the bindings), else "minimal";
#   - project mode: `mode:` in the STATUS file's frontmatter, else inferred: active when the owner
#     typed in a Claude session here in the last 14 days, maintenance otherwise.
#
# Writes nothing to the repo's tracked files or to GitHub; its only writes are the .status dir and its
# exclude line. `git fetch` updates remote-tracking refs only.
#
# Optional overrides (env): STATUS_STATE_DIR, STATUS_SINCE (away moment, ISO), STATUS_PROJECT (key),
# STATUS_OWNER (display name), STATUS_DEPLOY_RE (deploy workflow regex),
# STATUS_FLAG_LABELS (default: "blocks-go-live next").
#
# Rendering (render.py, next to this script):
#   gather.sh now --render [--seen] [--running "<what> · <who> · since HH:MM"]… [--ask "<inbox line>"]…
# writes the finished `now` view to <state dir>/now.md and prints it: the plain-shell entry point
# (an alias, a tmux pane) and what /status runs. --seen also moves the away moment (only a /status
# the owner sees should); --running adds this session's own work; --ask appends an inbox line first.
#   gather.sh arc [<project>] --render
# (<project>: a name from the overview's list, e.g. stocktimal or medi-invest/website, from any folder)
# prints the facts plus pre-rendered parts (efforts parsed from STATUS, open PRs by effort, the
# Maintenance lines); the model writes the rest of arc.
set -uo pipefail

usage() { echo 'usage: gather.sh [now|arc [<project>]] [--render [--seen] [--running TEXT]… [--ask TEXT]…] | overview [--digest]' >&2; exit 2; }
view=now; render=0; rargs=(); target=""; digest=0
while [ $# -gt 0 ]; do
  case "$1" in
    now|arc|overview) view=$1 ;;
    --render) render=1 ;;
    --digest) digest=1 ;;
    --seen) rargs+=(--seen) ;;
    --running|--ask) [ $# -ge 2 ] || usage; rargs+=("$1" "$2"); shift ;;
    -*) usage ;;
    *) [ "$view" = arc ] && [ -z "$target" ] || usage; target=$1 ;;
  esac
  shift
done
self=$(readlink -f "${BASH_SOURCE[0]}")
# overview: every project at once, read-only (overview.py; see overview.md). --digest reads the digest on stdin.
if [ "$view" = overview ]; then
  exec python3 -I "$(dirname "$self")/overview.py" "$([ "$digest" = 1 ] && echo digest || echo gather)"
fi
# arc <project>: the project by name from the overview's list, from any folder.
if [ -n "$target" ]; then
  dir=$(python3 -I "$(dirname "$self")/overview.py" resolve "$target") || exit 2
  cd "$dir" || exit 1
fi
if [ "$render" = 1 ]; then
  "$self" "$view" | python3 -I "$(dirname "$self")/render.py" "$view" ${rargs[@]+"${rargs[@]}"}
  exit "${PIPESTATUS[1]}"
fi

gh_() { GH_PROMPT_DISABLED=1 timeout -k 1 "${GH_TIMEOUT:-8}" gh "$@" 2>/dev/null; }
or_none() { local out; out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "  none"; }
or_unknown() { local out; out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "(none, or gh unavailable)"; }
epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }
hhmm() { date -d "$1" '+%a %d %b %H:%M' 2>/dev/null; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- project
if root=$(git rev-parse --show-toplevel 2>/dev/null); then
  in_git=1
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
  main_root=$(dirname "$common_dir")
else
  in_git=0; root=$PWD; main_root=$PWD
fi
cd "$root" || exit 1
project=${STATUS_PROJECT:-$(basename "$main_root")}
state_dir=${STATUS_STATE_DIR:-$main_root/.status}
mkdir -p "$state_dir" 2>/dev/null
if [ "$in_git" = 1 ] && [ -z "${STATUS_STATE_DIR:-}" ]; then
  ex="$common_dir/info/exclude"; mkdir -p "$common_dir/info"
  grep -qxF '.status/' "$ex" 2>/dev/null || printf '.status/\n' >> "$ex"
fi
owner=${STATUS_OWNER:-$(git config user.name 2>/dev/null | awk '{print $1}')}; owner=${owner:-$USER}
flag_labels=${STATUS_FLAG_LABELS:-blocks-go-live next}
deploy_re=${STATUS_DEPLOY_RE:-deploy}

R=""; default_branch=main; url=""
if [ "$in_git" = 1 ]; then
  url=$(git remote get-url origin 2>/dev/null)
  R=$(printf '%s' "$url" | sed -nE 's#^(https://|git@|ssh://git@)github\.com[:/]([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
  db=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); [ -n "$db" ] && default_branch=${db#origin/}
  git rev-parse -q --verify "refs/heads/$default_branch" >/dev/null || \
    git rev-parse -q --verify "refs/remotes/origin/$default_branch" >/dev/null || default_branch=$(git branch --show-current)
fi

midnight=$(date +%FT00:00:00%:z); midnight_utc=$(date -u -d "$midnight" +%FT%TZ)

# ---------------------------------------------------------------- remote calls, started first, in parallel
# One soft fetch: agents merge PRs on GitHub from worktrees; without it merges are missed.
fetch_pid=""
if [ "$in_git" = 1 ] && [ -n "$url" ]; then
  GIT_TERMINAL_PROMPT=0 timeout -k 1 5 git fetch --quiet --no-tags origin >/dev/null 2>&1 &
  fetch_pid=$!
fi
# Recent runs on every branch, one call: running now, deploys and failures since the away moment and today.
if [ -n "$R" ]; then
  gh_ run list -R "$R" --limit "$([ "$view" = arc ] && echo 200 || echo 60)" \
    --json workflowName,headBranch,status,conclusion,createdAt,updatedAt,event,displayTitle,url > "$tmp/runs.json" &
fi
timeout -k 1 10 claude agents --json --all > "$tmp/agents.json" 2>/dev/null &
agents_pid=$!

level=minimal; B=""
if [ -f docs/agentic-workflow.md ] && [ -f docs/agentic-workflow.bindings.md ]; then level=full; B=docs/agentic-workflow.bindings.md; fi

# A binding row's cell, by the role's name (first column, regex, case-insensitive).
binding() {
  [ -n "$B" ] || return 0
  sed 's/\\|/\//g' "$B" | awk -F'|' -v re="$1" 'BEGIN{IGNORECASE=1} /^\|/ {
    k=$2; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k ~ re) { v=$3; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }'
}
first_code() { grep -o '`[^`]*`' | head -1 | tr -d '`'; }

plans_dir=""; roadmap_file=""; roadmap_section=""; status_file=""; status_raw=""; roadmap_raw=""
if [ "$level" = full ]; then
  plans_dir=$(binding '^Plans directory' | first_code)
  roadmap_raw=$(binding '^Roadmap')
  roadmap_file=$(printf '%s' "$roadmap_raw" | first_code)
  roadmap_section=$(printf '%s' "$roadmap_raw" | sed -nE 's/.*§ *"?([^",(]*)"?.*/\1/p' | trim)
  [ -f "$roadmap_file" ] || roadmap_file=""
  status_raw=$(binding '^Session pointer')
  status_file=$(printf '%s' "$status_raw" | first_code)
  [ -f "$status_file" ] || status_file=""
fi
# Waves (waves.py, next to this script): one `gh issue list` of its own, in parallel; it caches the issue
# states in the state dir for the overview and the SessionStart hook. now: attention items only; arc: the block.
python3 -I "$(dirname "$self")/waves.py" "$root" --cache $([ "$view" = now ] && echo --attention) > "$tmp/waves" 2>/dev/null &
declared=""
[ -n "$status_file" ] && declared=$(awk 'NR==1 && $0!="---"{exit} NR>1 && /^---/{exit} /^mode:/{print $2}' "$status_file")

echo "## clock"
echo "now $(date -Iseconds) · today since $midnight · view $view"

echo; echo "## project"
echo "key $project · level $level · checkout $root · main checkout $main_root"
echo "repo ${R:-none (no GitHub remote)} · default branch $default_branch · owner $owner · state dir $state_dir"
[ "$in_git" = 0 ] && echo "not a git repo: git and GitHub sections are skipped"

if [ "$level" = full ]; then
  echo; echo "## bindings (from $B)"
  echo "plans dir: ${plans_dir:-none bound}"
  echo "status file: ${status_file:-none}$( [ -z "$status_file" ] && printf ' (session pointer binds to: %s)' "$(printf '%s' "$status_raw" | cut -c1-160)")"
  echo "roadmap: ${roadmap_file:-none}${roadmap_section:+ § $roadmap_section}$( [ -z "$roadmap_file" ] && printf ' (roadmap binds to: %s)' "$(printf '%s' "$roadmap_raw" | cut -c1-160)")"
  if [ "$view" = arc ]; then
    echo "owner's gates (Irreversible steps): $(binding '^Irreversible' | cut -c1-400)"
    echo "owner's gates (Integration branch): $(binding '^Integration branch' | cut -c1-400)"
  fi
fi

# ---------------------------------------------------------------- arc: slow GitHub sections, in parallel
# Each writes its own file; they are printed in order further down.
if [ "$view" = arc ] && [ -n "$R" ]; then
  {
    echo "## main (remote)"
    gh_ api "repos/$R/commits/$default_branch" -q '"\(.sha[:8]) \(.commit.committer.date) \(.commit.message | split("\n")[0])"' | or_unknown
  } > "$tmp/a1" &
  {
    echo "## deployed (repo variables named *_DEPLOYED_SHA: sha · commits $default_branch is ahead · PRs merged since)"
    vars=$(gh_ variable list -R "$R" --json name,value -q '.[] | select(.name | endswith("_DEPLOYED_SHA")) | "\(.name) \(.value)"')
    while read -r v sha; do
      [ -z "$v" ] && continue
      sha=$(printf '%s' "$sha" | tr -d '[:space:]')
      if [[ ! "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then echo "$v unknown"; continue; fi
      cmp=$(gh_ api "repos/$R/compare/$sha...$default_branch" \
        -q '"\(.ahead_by) \([.commits[].commit.message | capture("^Merge pull request #(?<n>[0-9]+)|\\(#(?<m>[0-9]+)\\)$")? | "#" + (.n // .m)] | join(" "))"')
      echo "$v ${sha:0:8} · ahead ${cmp%% *} · PRs: $(p=${cmp#* }; echo "${p:-none}")"
    done <<< "$vars"
    [ -z "$vars" ] && echo "(no *_DEPLOYED_SHA variables: prod lag unknown; use the last deploy run instead)"
  } > "$tmp/a2" &
  {
    echo "## prs-open (number · title · author · bot? · draft · branch · opened · checks)"
    gh_ pr list -R "$R" --state open --limit 100 \
      --json number,title,author,isDraft,headRefName,createdAt,statusCheckRollup \
      -q '.[] | [ "#\(.number)", .title, .author.login,
          (if (.author.login | test("^app/|\\[bot\\]$")) then "BOT" else "person" end),
          (if .isDraft then "draft" else "ready" end), .headRefName, .createdAt[:10],
          ([.statusCheckRollup[]? | (.conclusion // .status) | ascii_downcase]
            | if length == 0 then "no checks"
              elif any(. == "failure" or . == "timed_out" or . == "cancelled" or . == "startup_failure") then "RED"
              elif any(. == "in_progress" or . == "queued" or . == "pending" or . == "") then "running"
              else "green" end) ] | join(" · ")' | or_unknown
  } > "$tmp/a3" &
  {
    echo "## issues (open total · opened today · flagged by label)"
    total=$(gh_ issue list -R "$R" --state open --limit 1000 --json number -q 'length')
    today=$(gh_ issue list -R "$R" --state open --search "created:>=$midnight" --limit 200 --json number -q 'length')
    echo "open ${total:-?} · opened today ${today:-?}"
    for l in $flag_labels; do
      gh_ issue list -R "$R" --state open --label "$l" --limit 50 --json number,title \
        -q ".[] | \"$l · #\(.number) · \(.title)\""
    done
  } > "$tmp/a4" &
  gh_ pr list -R "$R" --state all --limit 300 --json number,state,headRefName \
    -q '.[] | "\(.headRefName)\t\(.state | ascii_downcase) #\(.number)"' > "$tmp/prs_all" &
fi

# ---------------------------------------------------------------- sessions (local)
# The Claude session running this script: the nearest ancestor process named claude.
self_pid=""; p=$$
for _ in 1 2 3 4 5 6 7 8; do
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); { [ -z "$p" ] || [ "$p" -le 1 ]; } && break
  [ "$(ps -o comm= -p "$p" 2>/dev/null)" = claude ] && { self_pid=$p; break; }
done
transcript() { find "$HOME/.claude/projects" -maxdepth 2 -name "$1.jsonl" -print -quit 2>/dev/null; }
# Timestamps of the owner's own messages in a transcript, newest first: typed text, not tool results,
# task notifications or injected reminders.
owner_msgs() {
  tac "$1" | grep -m 400 '"type":"user"' | jq -r 'select(.isMeta != true and .isSidechain != true)
    | select(.message.content | (type == "string" and ((startswith("<task-notification") or startswith("<local-command")
        or startswith("<system-reminder")) | not))
      or (type == "array" and any(.[]; .type == "text") and all(.[]; .type != "tool_result")))
    | .timestamp' 2>/dev/null
}

# This project's checkouts: the worktrees, plus sibling folders that are clones of the same remote.
if [ "$in_git" = 1 ]; then
  paths=$( { git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}'
             for d in "$(dirname "$main_root")/$(basename "$main_root")"-*/; do
               [ -d "$d" ] || continue; d=${d%/}
               [ -n "$url" ] && [ "$(git -C "$d" remote get-url origin 2>/dev/null)" = "$url" ] && echo "$d"
             done; } | sort -u)
else
  paths=$root
fi

# Recent transcripts started in this project, newest first, as "file<TAB>cwd" (this session included;
# left out where it matters). Transcript folders are named after the cwd with / and . turned into -.
tmp_transcripts=$tmp/transcripts
while IFS= read -r pth; do
  [ -z "$pth" ] && continue
  for key in "$(printf '%s' "$pth" | tr '/' '-')" "$(printf '%s' "$pth" | tr '/.' '--')"; do
    ls -d "$HOME/.claude/projects/$key" "$HOME/.claude/projects/$key"-* 2>/dev/null
  done
done <<< "$paths" | sort -u | while read -r d; do ls -t "$d"/*.jsonl 2>/dev/null | head -10; done |
  xargs -r ls -t 2>/dev/null | head -40 | while read -r f; do
    cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" | cut -d'"' -f4); [ -z "$cwd" ] && continue
    printf '%s\n' "$paths" | grep -qxF "$cwd" || printf '%s\n' "$paths" | while read -r q; do [[ "$cwd" == "$q"/* ]] && echo y; done | grep -q y || continue
    printf '%s\t%s\n' "$f" "$cwd"
  done > "$tmp_transcripts"

wait "$agents_pid" 2>/dev/null
agents=$(cat "$tmp/agents.json" 2>/dev/null)
paths_json=$(printf '%s\n' "$paths" | jq -R . | jq -sc 'map(select(. != ""))')
mine=$(printf '%s' "$agents" | jq -c --argjson p "$paths_json" \
  '[.[]? | select(.cwd as $c | any($p[]; $c == . or ($c | startswith(. + "/"))))]' 2>/dev/null)
self_sid=$(printf '%s' "$agents" | jq -r --arg pid "$self_pid" '.[]? | select((.pid|tostring) == $pid) | .sessionId' 2>/dev/null)
live_sids=$(printf '%s' "$agents" | jq -r '.[]?.sessionId' 2>/dev/null)
others() { if [ -n "$self_sid" ]; then grep -vF "/$self_sid.jsonl"$'\t' "$tmp_transcripts"; else cat "$tmp_transcripts"; fi; }

# ---------------------------------------------------------------- away moment
gap_start=""; gap_end=""
if [ -n "$self_sid" ] && t=$(transcript "$self_sid") && [ -n "$t" ]; then
  # Walk back from the newest message (the one that asked for /status) to the first gap of 30+ minutes;
  # short messages after a long gap do not end the absence.
  later=""
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if [ -n "$later" ] && [ $(( $(epoch "$later") - $(epoch "$m") )) -ge 1800 ]; then gap_start=$m; gap_end=$later; break; fi
    later=$m
  done <<< "$(owner_msgs "$t")"
fi
seen=$(cat "$state_dir/seen" 2>/dev/null)
since=${STATUS_SINCE:-}
if [ -z "$since" ]; then
  since=$gap_start
  if [ -n "$seen" ] && { [ -z "$gap_end" ] || [ "$(epoch "$seen")" -gt "$(epoch "$gap_end")" ]; }; then since=$seen; fi
fi
[ -z "$since" ] && since=$midnight
since=$(date -d "$since" -Iseconds); since_utc=$(date -u -d "$since" +%FT%TZ)

if [ "$view" = now ]; then
  echo; echo "## owner (away since = start of the owner's last gap of 30+ min, or the last /status if later than the gap's end)"
  if [ -n "$gap_start" ]; then echo "last gap of 30+ min: $(hhmm "$gap_start") → $(hhmm "$gap_end")"
  else echo "last gap of 30+ min: none found (not run from a Claude session, no transcript, or no gap)"; fi
  if [ -n "$seen" ]; then echo "last /status: $(hhmm "$seen")"; else echo "last /status: never"; fi
  echo "away since: $(hhmm "$since") ($since)"
fi

# ---------------------------------------------------------------- mode
echo; echo "## mode (active development or maintenance)"
# Inferred from the owner's own messages: active when he typed in a Claude session here (other than
# this one) in the last 14 days. Commits do not count: agents commit under his name.
if [ -n "$declared" ]; then
  echo "mode $declared (declared in $status_file)"
else
  last_msg=""; last_title=""; cutoff14=$(date -d '-14 days' +%s)
  while IFS=$'\t' read -r f _; do
    [ "$(stat -c %Y "$f")" -lt "$cutoff14" ] && break   # newest first: older files cannot hold a newer message
    m=$(owner_msgs "$f" | head -1)
    # The newest transcript holding a message of his holds his newest message, near enough.
    if [ -n "$m" ]; then last_msg=$m; last_title=$(grep -o '"aiTitle":"[^"]*"' "$f" | tail -1 | cut -d'"' -f4); break; fi
  done < <(others)
  if [ -n "$last_msg" ] && [ "$(epoch "$last_msg")" -ge "$cutoff14" ]; then
    echo "mode active (inferred: your last message in a session here $(hhmm "$last_msg"), ${last_title:-no title}; within 14 days)"
  else
    newest=$(others | head -1 | cut -f1); when="none found"
    [ -n "$newest" ] && when="newest session here last active $(date -d "@$(stat -c %Y "$newest")" '+%a %d %b %Y')"
    echo "mode maintenance (inferred: no message from you in a session here in 14 days; $when)"
  fi
fi

# ---------------------------------------------------------------- status file (full level), printed whole
if [ -n "$status_file" ]; then
  echo; echo "## status file ($status_file, whole)"
  cat "$status_file"
  echo; echo "## (end of status file)"
fi

# ---------------------------------------------------------------- runs (one gh call, shared)
fetch_note="fetched just now"
if [ -n "$fetch_pid" ]; then wait "$fetch_pid" 2>/dev/null || fetch_note="fetch failed or timed out: origin may be stale"; fi
wait  # the runs list, and in arc the parallel sections
runs=$(cat "$tmp/runs.json" 2>/dev/null); runs_ok=1
printf '%s' "$runs" | jq -e 'type == "array"' >/dev/null 2>&1 || runs_ok=0
# Deploy workflows: name matches the deploy regex, or "infra" without being a CI/build/check job.
deploy_sel="select((.workflowName | test(\"$deploy_re\"; \"i\")) or ((.workflowName | test(\"infra\"; \"i\")) and (.workflowName | test(\"^(ci|build|security)\\\\b|lint|test|check|validat\"; \"i\") | not)))"
# Housekeeping deploys (a schedule, a base-image or dependency bump, a bot's merge) are Maintenance.
hk='(.event == "schedule") or ((.workflowName + " " + (.displayTitle // "")) | test("digest|base[- ]?image|python base|dependenc|dependabot|renovate|upkeep|\\bbump\\b|\\[bot\\]"; "i"))'
real_sel="select(($hk) | not)"; hk_sel="select($hk)"
on_main="select(.headBranch == \"$default_branch\")"
failed='select(.conclusion == "failure" or .conclusion == "startup_failure" or .conclusion == "timed_out")'
runs_q() { [ "$runs_ok" = 1 ] && printf '%s' "$runs" | jq -r "$1" 2>/dev/null; }

# Merged PRs from git, on the fetched default branch, first parent only: a squash merge is
# "Title (#n)", a merge commit "Merge pull request #n" with the title in its body.
mref=$default_branch; git rev-parse -q --verify "refs/remotes/origin/$default_branch" >/dev/null 2>&1 && mref=origin/$default_branch
merged_since() {
  git log "$mref" --first-parent --since="$1" --reverse --format='%x1e%cd%x1f%s%x1f%b' --date=format:'%a %d %b %H:%M' 2>/dev/null |
    awk 'BEGIN { RS = "\x1e"; FS = "\x1f" } NF >= 2 {
      t = $1; s = $2; b = $3; sub(/^\n+/, "", b); split(b, bl, "\n")
      if (match(s, /^Merge pull request #[0-9]+/)) { n = substr(s, 21, RLENGTH - 20); print "  " bl[1] " (#" n ") · " t }
      else if (match(s, /\(#[0-9]+\)$/)) print "  " s " · " t
      else print "  direct commit: " s " · " t }'
}

if [ "$view" = now ]; then
  echo; echo "## since (what changed since the away moment, $(hhmm "$since"))"
  if [ "$in_git" = 1 ] && [ -n "$url" ]; then
    echo "merged on $mref (from git, $fetch_note):"
    merged_since "$since" | or_none
  fi
  if [ -n "$R" ]; then
    echo "deploy runs on $default_branch started or finished (any outcome):"
    if [ "$runs_ok" = 1 ]; then
      runs_q "[.[] | $on_main | select(.updatedAt >= \"$since_utc\") | $deploy_sel] | .[] | $real_sel
        | \"  \\(.workflowName) · \\(if (.conclusion // \"\") == \"\" then .status else .conclusion end) · started \\(.createdAt) · last update \\(.updatedAt)\"" | or_none
      runs_q "[.[] | $on_main | select(.updatedAt >= \"$since_utc\") | $deploy_sel | $hk_sel] | select(length > 0)
        | \"  housekeeping (Maintenance only): \\(length) runs, \\([.[] | select(.conclusion != \"success\")] | length) not successful\""
      echo "runs on $default_branch that failed:"
      runs_q ".[] | $on_main | select(.updatedAt >= \"$since_utc\") | $failed
        | \"  \\(.workflowName) · \\(.conclusion) · started \\(.createdAt) · \\(.url)\"" | or_none
    else echo "  unknown (gh unavailable)"; fi
  fi
  if [ "$in_git" = 1 ]; then
    echo "local commits (all branches, newest first):"
    git log --all --since="$since" --format='  %h · %ad · %an · %D · %s' --date=format:'%a %d %b %H:%M' 2>/dev/null | head -15 | or_none
  fi

  echo; echo "## runs-active (workflow · branch · event · state · started), among the last 60 runs"
  if [ -n "$R" ]; then
    if [ "$runs_ok" = 1 ]; then
      runs_q '.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or .status == "pending")
        | "\(.workflowName) · \(.headBranch) · \(.event) · \(.status) · \(.createdAt)"' | or_none
      echo "red on $default_branch (latest completed run of each workflow among those 60, failed):"
      runs_q "[.[] | $on_main | select(.status == \"completed\")] | group_by(.workflowName) | map(max_by(.createdAt)) | .[] | $failed
        | \"  \\(.workflowName) · \\(.conclusion) · \\(.createdAt)\"" | or_none
    else echo "unknown (gh unavailable)"; fi
  else echo "no GitHub repo"; fi

  echo; echo "## done-today"
  if [ "$in_git" = 1 ] && [ -n "$url" ]; then
    echo "merged on $mref since midnight:"
    merged_since "$midnight" | or_none
  elif [ "$in_git" = 1 ]; then
    echo "commits today (all branches):"
    git log --all --since="$midnight" --format='  %h · %ad · %s' --date=format:'%H:%M' 2>/dev/null | head -15 | or_none
  fi
  if [ -n "$R" ]; then
    echo "deploy runs on $default_branch today that succeeded:"
    runs_q "[.[] | $on_main | select(.createdAt >= \"$midnight_utc\") | select(.conclusion == \"success\") | $deploy_sel] | .[] | $real_sel
      | \"  \\(.workflowName) · \\(.createdAt)\"" | or_none
    runs_q "[.[] | $on_main | select(.createdAt >= \"$midnight_utc\") | select(.conclusion == \"success\") | $deploy_sel | $hk_sel] | select(length > 0)
      | \"  housekeeping (Maintenance, one count line): \\(length) runs: \\(group_by(.workflowName) | map(\"\\(.[0].workflowName) ×\\(length)\") | join(\"; \"))\""
  fi

  # Effort hints: which plan files name each PR merged today or since the away moment.
  if [ -n "$plans_dir" ] && [ -d "$plans_dir" ]; then
    nums=$( { merged_since "$since"; merged_since "$midnight"; } | grep -oE '\(#[0-9]+\)' | tr -d '()#' | sort -un)
    if [ -n "$nums" ]; then
      echo; echo "## effort hints (PR → plan files in $plans_dir that name it; none: Ad hoc unless the status file names it)"
      for n in $nums; do
        hits=$(grep -lE "#$n\b" "$plans_dir"*.md 2>/dev/null | grep -vE '/(STATUS|ROADMAP|README|BACKLOG)\.md$' | tr '\n' ' ' | sed 's/ $//')
        echo "#$n → ${hits:-none}"
      done
    fi
  fi
fi

# ---------------------------------------------------------------- sessions
echo; echo "## sessions (other Claude sessions in this project, from claude agents: name · kind · state · last active · branch · cwd)"
if [ -z "$agents" ]; then
  echo "unknown (claude agents unavailable): use the worktrees' activity as the fallback (/status arc)"
else
  # Fields joined by \x1f, not tabs: read collapses empty tab-separated fields and shifts the rest.
  printf '%s' "$mine" | jq -r '.[] | [.sessionId, (.name // "?"), .kind, (.status // .state // "?"), ((.startedAt // 0) / 1000 | floor | tostring), .cwd] | join("\u001f")' |
  while IFS=$'\x1f' read -r sid name kind st started cwd; do
    [ "$sid" = "$self_sid" ] && continue   # the session running /status is not "another session"
    t=$(transcript "$sid"); last="? (started $(date -d "@$started" '+%a %d %b %H:%M'))"
    [ -n "$t" ] && last=$(date -d "@$(stat -c %Y "$t")" '+%a %d %b %H:%M')
    b=$(git -C "$cwd" branch --show-current 2>/dev/null); b=${b:-?}
    echo "$name · $kind · $st · last active $last · branch $b · $cwd"
  done | { out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "none"; }
fi
self_name=$(printf '%s' "$agents" | jq -r --arg s "$self_sid" '.[]? | select(.sessionId == $s) | .name // empty' 2>/dev/null)
echo "this session: ${self_name:-none (not run from a Claude session)}"

echo; echo "## last-sessions (recent Claude sessions started in this project, newest first; this session left out: last active · topic · branch · live? · cwd)"
others | head -"$([ "$view" = arc ] && echo 6 || echo 3)" | while IFS=$'\t' read -r f cwd; do
    sid=$(basename "$f" .jsonl)
    title=$(grep -o '"aiTitle":"[^"]*"' "$f" | tail -1 | cut -d'"' -f4)
    branch=$(tac "$f" | grep -m1 -o '"gitBranch":"[^"]*"' | cut -d'"' -f4)
    live=""; printf '%s\n' "$live_sids" | grep -qxF "$sid" && live=" · LIVE"
    echo "$(date -d "@$(stat -c %Y "$f")" '+%a %d %b %H:%M') · ${title:-(no title)} · ${branch:-?}$live · $cwd"
  done | { out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "none"; }
if [ "$view" = now ] && [ "$in_git" = 1 ]; then
  # Where you left off: what the newest earlier session's checkout still holds.
  lcwd=$(others | head -1 | cut -f2)
  if [ -n "$lcwd" ] && [ -d "$lcwd" ]; then
    lb=$(git -C "$lcwd" branch --show-current 2>/dev/null)
    ld=$(git -C "$lcwd" status --porcelain 2>/dev/null | wc -l)
    la=0; [ -n "$lb" ] && [ "$lb" != "$default_branch" ] && la=$(git -C "$lcwd" rev-list --count "$mref..$lb" 2>/dev/null)
    echo "left off in $lcwd: branch ${lb:-detached} · $ld uncommitted files · ${la:-0} commits not on $mref"
  fi
fi

# ---------------------------------------------------------------- arc: GitHub sections, local work, plans
if [ "$view" = arc ]; then
  for f in a1 a2 a3; do [ -s "$tmp/$f" ] && { echo; cat "$tmp/$f"; }; done
  if [ -n "$R" ]; then
    echo; echo "## runs-red (latest completed run per workflow on $default_branch among the last 200 runs, failed)"
    if [ "$runs_ok" = 1 ]; then
      runs_q "[.[] | $on_main | select(.status == \"completed\")] | group_by(.workflowName) | map(max_by(.createdAt)) | .[] | $failed
        | \"\\(.workflowName) · \\(.conclusion) · \\(.createdAt) · \\(.url)\"" | or_none
      echo; echo "## deploys (last completed deploy run on $default_branch per workflow; housekeeping today as a count)"
      runs_q "[.[] | $on_main | $deploy_sel | $real_sel | select(.status == \"completed\")] | group_by(.workflowName) | map(max_by(.createdAt)) | .[]
        | \"\\(.workflowName) · \\(.conclusion) · \\(.createdAt)\"" | or_none
      runs_q "[.[] | $on_main | select(.createdAt >= \"$midnight_utc\") | $deploy_sel | $hk_sel] | select(length > 0)
        | \"housekeeping today: \\(length) runs: \\(group_by(.workflowName) | map(\"\\(.[0].workflowName) ×\\(length)\") | join(\"; \")), \\([.[] | select(.status == \"completed\" and .conclusion != \"success\")] | length) failed\""
    else echo "unknown (gh unavailable)"; fi
    [ -s "$tmp/a4" ] && { echo; cat "$tmp/a4"; }
  fi

  if [ "$in_git" = 1 ]; then
    prs_all=$(cat "$tmp/prs_all" 2>/dev/null)
    echo; echo "## worktrees (branch · last commit · dirty files · PR · lock · activity <30 min)"
    git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}' > "$tmp/wts"
    i=0
    while read -r wt; do
      i=$((i + 1))
      (
        [ -d "$wt" ] || exit 0
        b=$(git -C "$wt" branch --show-current 2>/dev/null); b=${b:-detached}
        dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
        [ "$b" = "$default_branch" ] && [ "$dirty" = 0 ] && exit 0
        last=$(git -C "$wt" log -1 --format=%cr 2>/dev/null)
        pr=$(printf '%s\n' "$prs_all" | awk -F'\t' -v b="$b" '$1 == b {print $2; exit}'); pr=${pr:-no PR}
        lockf="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)/locked"; lock="unlocked"
        if [ -f "$lockf" ]; then
          pid=$(grep -o 'pid [0-9]*' "$lockf" | head -1 | cut -d' ' -f2)
          if [ -n "$pid" ] && [ "$pid" = "$self_pid" ]; then lock="held by this session"
          elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then lock="held by other session pid $pid"
          else lock="stale lock"; fi
        fi
        act=$(find "$wt" \( -name node_modules -o -name .venv -o -name .git -o -name dist \) -prune -o \
              -type f -newermt '-30 min' -print -quit 2>/dev/null)
        [ -n "$act" ] && act=ACTIVE || act=idle
        # An idle, clean worktree whose PR merged or closed is finished work: count it, do not list it.
        if [ "$act" = idle ] && [ "$dirty" = 0 ] && [[ "$pr" == merged* || "$pr" == closed* ]]; then echo "DONE"; exit 0; fi
        echo "$b · $last · $dirty · $pr · $lock · $act · $wt"
      ) > "$tmp/wt.$(printf %04d "$i")" &
    done < "$tmp/wts"
    wait
    cat "$tmp"/wt.* 2>/dev/null | awk '/^DONE$/ {d++; next} {print} END {if (d) print "+ " d " idle, clean worktrees whose PR merged or closed (cleanup candidates)"}' | or_none

    echo; echo "## unmerged (local branches with commits not on $mref: branch · commits ahead · last commit · PR; a merged PR means squash-merged, likely done)"
    git for-each-ref refs/heads --format='%(refname:short)' | while read -r b; do
      [ "$b" = "$default_branch" ] && continue
      n=$(git rev-list --count "$mref..$b" 2>/dev/null); [ "${n:-0}" = 0 ] && continue
      pr=$(printf '%s\n' "$prs_all" | awk -F'\t' -v b="$b" '$1 == b {print $2; exit}'); pr=${pr:-no PR}
      echo "$b · $n ahead · $(git log -1 --format='%cr' "$b") · $pr"
    done | head -15 | or_none
  fi

  if [ "$level" = full ]; then
    echo; echo "## plans (path · status · updated · title), live statuses only"
    for f in ${plans_dir}*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in STATUS.md|ROADMAP.md|README.md|BACKLOG.md) continue ;; esac
      # status/updated sit in YAML frontmatter or a fenced block at the top: read the first 12 lines.
      st=$(head -12 "$f" | awk '/^status:/{print $2; exit}')
      case "$st" in active|planned|proposed|blocked|parked) ;; *) continue ;; esac
      up=$(head -12 "$f" | awk '/^updated:/{print $2; exit}')
      title=$(grep -m1 '^# ' "$f" | sed 's/^# //')
      echo "$f · $st · ${up:-?} · $title"
    done | or_none

    echo; echo "## roadmap (effort · status · plan; done, dropped and superseded rows left out)"
    if [ -z "$roadmap_file" ]; then
      echo "none: no roadmap file bound (${roadmap_raw:-no Roadmap row})"
    else
      # The first table whose header has an Effort or Work column; columns found by name. Within the
      # bound section (§) when the binding names one.
      sed 's/\\|/\//g' "$roadmap_file" | awk -v sec="$roadmap_section" '
        BEGIN { insec = (sec == ""); IGNORECASE = 1 }
        /^#+ / { if (sec != "") insec = (index($0, sec) > 0); if (started) exit; next }
        !insec { next }
        /^\|/ {
          n = split($0, f, "|")
          if (!started) {
            ec = sc = pc = 0
            for (i = 2; i < n; i++) { h = f[i]; gsub(/^[ \t]+|[ \t]+$/, "", h)
              if (h ~ /^(effort|work)$/) ec = i; else if (h ~ /^status$/) sc = i; else if (h ~ /plan|where/) pc = i }
            if (ec) started = 1; next
          }
          if ($0 ~ /^\|[ :|-]+$/) next
          e = f[ec]; s = sc ? f[sc] : "listed"; p = pc ? f[pc] : ""
          gsub(/^[ \t]+|[ \t]+$/, "", e); gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/\*\*/, "", s)
          if (s ~ /^[^A-Za-z]*(done|dropped|superseded|retired)/) next
          print e " · " substr(s, 1, 110) " · " substr(p, 1, 60); next
        }
        started { exit }' | or_none
    fi
  fi
fi

# ---------------------------------------------------------------- waves (waves.py, started above)
if [ "$view" = now ]; then
  echo; echo "## waves (attention items from waves.py: close due, Now above the cap, plans off the ROADMAP; none: nothing)"
else
  echo; echo "## waves (waves.py: Now with progress, Next/Later counts, attention)"
fi
cat "$tmp/waves" 2>/dev/null

# ---------------------------------------------------------------- left for later (written by /wrap)
echo; echo "## left-for-later ($state_dir/next.md; handoff.md is fresh when written at or after the newest earlier session's last activity, 10 min slack)"
grep -E '^- ' "$state_dir/next.md" 2>/dev/null | or_none
if [ -f "$state_dir/handoff.md" ]; then
  hm=$(stat -c %Y "$state_dir/handoff.md"); lf=$(others | head -1 | cut -f1); la=0
  [ -n "$lf" ] && la=$(stat -c %Y "$lf")
  fresh=stale; [ "$hm" -ge $((la - 600)) ] && fresh=fresh
  echo "handoff: $state_dir/handoff.md · written $(date -d "@$hm" '+%a %d %b %H:%M') · $fresh"
else
  echo "handoff: none"
fi

# ---------------------------------------------------------------- inbox
echo; echo "## inbox ($state_dir/waiting.md)"
grep -E '^- ' "$state_dir/waiting.md" 2>/dev/null || echo "(empty)"
echo; echo "## decided ($state_dir/decided.md, last 24h)"
cutoff=$(date -d '-24 hours' +%s)
grep -E '^- ' "$state_dir/decided.md" 2>/dev/null | while IFS= read -r l; do
  ts=$(printf '%s' "$l" | sed -nE 's/^- ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}).*/\1/p')
  [ -n "$ts" ] && [ "$(epoch "$ts")" -ge "$cutoff" ] && printf '%s\n' "$l"
done | or_none
exit 0
