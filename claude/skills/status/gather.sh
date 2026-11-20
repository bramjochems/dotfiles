#!/usr/bin/env bash
# gather.sh — the facts /status reads, as plain sections. One script for every project.
#
# Run from anywhere inside a project (a git repo, a worktree, or a plain folder):
#   ~/.claude/skills/status/gather.sh
# It works out the project itself:
#   - project key: the main checkout's folder name (a worktree maps to its main repo);
#   - level: "full" when the repo has docs/agentic-workflow.md and docs/agentic-workflow.bindings.md
#     (paths for STATUS, ROADMAP and plans come from the bindings), else "minimal"
#     (git, gh, sessions, inbox only);
#   - project mode: `mode:` in the STATUS file's frontmatter, else inferred: active when the owner
#     typed in a Claude session here in the last 14 days, maintenance otherwise.
#
# Read-only: no `git fetch`, no writes to the repo or to GitHub. Every gh call is bounded, and a
# failed one prints "unknown" in its section instead of stopping the rest.
#
# Optional overrides (env): STATUS_STATE_DIR (inbox/pane dir), STATUS_SINCE (away moment, ISO),
# STATUS_PROJECT (key), STATUS_OWNER (display name), STATUS_DEPLOY_RE (deploy workflow regex),
# STATUS_FLAG_LABELS (default: "blocks-go-live next").
set -uo pipefail

gh_() { GH_PROMPT_DISABLED=1 timeout -k 1 20 gh "$@" 2>/dev/null; }
or_none() { local out; out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "  none"; }
or_unknown() { local out; out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "(none, or gh unavailable)"; }
epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }
hhmm() { date -d "$1" '+%a %d %b %H:%M' 2>/dev/null; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

# ---------------------------------------------------------------- project
if root=$(git rev-parse --show-toplevel 2>/dev/null); then
  in_git=1
  main_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
else
  in_git=0; root=$PWD; main_root=$PWD
fi
cd "$root" || exit 1
project=${STATUS_PROJECT:-$(basename "$main_root")}
state_dir=${STATUS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/overview/$project}
owner=${STATUS_OWNER:-$(git config user.name 2>/dev/null | awk '{print $1}')}; owner=${owner:-$USER}
flag_labels=${STATUS_FLAG_LABELS:-blocks-go-live next}
deploy_re=${STATUS_DEPLOY_RE:-}

R=""; default_branch=main
if [ "$in_git" = 1 ]; then
  url=$(git remote get-url origin 2>/dev/null)
  R=$(printf '%s' "$url" | sed -nE 's#^(https://|git@|ssh://git@)github\.com[:/]([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
  db=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); [ -n "$db" ] && default_branch=${db#origin/}
  git rev-parse -q --verify "refs/heads/$default_branch" >/dev/null || \
    git rev-parse -q --verify "refs/remotes/origin/$default_branch" >/dev/null || default_branch=$(git branch --show-current)
fi

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

midnight=$(date +%FT00:00:00%:z)
echo "## clock"
echo "now $(date -Iseconds) · today since $midnight"

echo; echo "## project"
echo "key $project · level $level · checkout $root · main checkout $main_root"
echo "repo ${R:-none (no GitHub remote)} · default branch $default_branch · owner $owner · state dir $state_dir"
[ "$in_git" = 0 ] && echo "not a git repo: git and GitHub sections are skipped"

if [ "$level" = full ]; then
  echo; echo "## bindings (from $B)"
  echo "plans dir: ${plans_dir:-none bound}"
  echo "status file: ${status_file:-none} ${status_file:+}$( [ -z "$status_file" ] && printf '(session pointer binds to: %s)' "$(printf '%s' "$status_raw" | cut -c1-160)")"
  echo "roadmap: ${roadmap_file:-none}${roadmap_section:+ § $roadmap_section}$( [ -z "$roadmap_file" ] && printf ' (roadmap binds to: %s)' "$(printf '%s' "$roadmap_raw" | cut -c1-160)")"
  echo "owner's gates (Irreversible steps): $(binding '^Irreversible' | cut -c1-400)"
  echo "owner's gates (Integration branch): $(binding '^Integration branch' | cut -c1-400)"
fi

declared=""
[ -n "$status_file" ] && declared=$(awk 'NR==1 && $0!="---"{exit} NR>1 && /^---/{exit} /^mode:/{print $2}' "$status_file")

# ---------------------------------------------------------------- GitHub
if [ -n "$R" ]; then
  echo; echo "## main (remote)"
  gh_ api "repos/$R/commits/$default_branch" -q '"\(.sha[:8]) \(.commit.committer.date) \(.commit.message | split("\n")[0])"' | or_unknown

  echo; echo "## deployed (repo variables named *_DEPLOYED_SHA: sha · commits $default_branch is ahead · PRs merged since)"
  vars=$(gh_ variable list -R "$R" --json name -q '.[].name | select(endswith("_DEPLOYED_SHA"))')
  for v in $vars; do
    sha=$(gh_ variable get "$v" -R "$R" | tr -d '[:space:]')
    if [[ ! "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then echo "$v unknown"; continue; fi
    cmp=$(gh_ api "repos/$R/compare/$sha...$default_branch" \
      -q '"\(.ahead_by) \([.commits[].commit.message | capture("^Merge pull request #(?<n>[0-9]+)|\\(#(?<m>[0-9]+)\\)$")? | "#" + (.n // .m)] | join(" "))"')
    echo "$v ${sha:0:8} · ahead ${cmp%% *} · PRs: $(p=${cmp#* }; echo "${p:-none}")"
  done
  [ -z "$vars" ] && echo "(no *_DEPLOYED_SHA variables: prod lag unknown; use deploy runs below)"

  echo; echo "## prs-open (number · title · author · bot? · draft · branch · opened · checks)"
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

  echo; echo "## runs-active (workflow · branch · event · started)"
  for s in in_progress queued; do
    gh_ run list -R "$R" --status "$s" --limit 50 --json workflowName,headBranch,event,createdAt \
      -q ".[] | \"\(.workflowName) · \(.headBranch) · \(.event) · \(.createdAt) · $s\""
  done | or_unknown

  echo; echo "## runs-red (latest run per workflow on $default_branch that failed)"
  gh_ run list -R "$R" --branch "$default_branch" --limit 200 --json workflowName,conclusion,createdAt,url \
    -q 'group_by(.workflowName) | map(max_by(.createdAt))
        | map(select(.conclusion == "failure" or .conclusion == "startup_failure" or .conclusion == "timed_out"))
        | .[] | "\(.workflowName) · \(.conclusion) · \(.createdAt) · \(.url)"' | or_unknown

  # Deploy workflows: name says "deploy", or "infra" without being a CI/build/check job.
  [ -z "$deploy_re" ] && deploy_re='deploy'
  deploy_sel="select((.workflowName | test(\"$deploy_re\"; \"i\")) or ((.workflowName | test(\"infra\"; \"i\")) and (.workflowName | test(\"^(ci|build|security)\\\\b|lint|test|check|validat\"; \"i\") | not)))"
  # Housekeeping deploys (a schedule, a base-image or dependency bump, a bot's merge) are Maintenance,
  # counted on one line, not deploys of the owner's work.
  hk='(.event == "schedule") or ((.workflowName + " " + (.displayTitle // "")) | test("digest|base[- ]?image|python base|dependenc|dependabot|renovate|upkeep|\\bbump\\b|\\[bot\\]"; "i"))'
  real_sel="select(($hk) | not)"; hk_sel="select($hk)"

  echo; echo "## merged-today (number · title · merged at)"
  gh_ pr list -R "$R" --state merged --search "merged:>=$midnight" --limit 100 \
    --json number,title,mergedAt -q 'sort_by(.mergedAt) | .[] | "#\(.number) · \(.title) · \(.mergedAt)"' | or_unknown

  echo; echo "## deploys-today (workflow · started), deploy runs on $default_branch that succeeded"
  midnight_utc=$(date -u -d "$midnight" +%FT%TZ)
  runs_today=$(gh_ run list -R "$R" --branch "$default_branch" --limit 200 --json workflowName,conclusion,createdAt,event,displayTitle \
    -q "[.[] | select(.createdAt >= \"$midnight_utc\") | select(.conclusion == \"success\") | $deploy_sel]")
  printf '%s' "$runs_today" | jq -r ".[] | $real_sel | \"\\(.workflowName) · \\(.createdAt)\"" 2>/dev/null | or_unknown
  printf '%s' "$runs_today" | jq -r "[.[] | $hk_sel] | select(length > 0)
    | \"housekeeping (Maintenance, one count line): \\(length) runs: \\(group_by(.workflowName) | map(\"\\(.[0].workflowName) ×\\(length)\") | join(\"; \"))\"" 2>/dev/null

  echo; echo "## issues (open total · opened today · flagged by label)"
  total=$(gh_ issue list -R "$R" --state open --limit 1000 --json number -q 'length')
  today=$(gh_ issue list -R "$R" --state open --search "created:>=$midnight" --limit 200 --json number -q 'length')
  echo "open ${total:-?} · opened today ${today:-?}"
  for l in $flag_labels; do
    gh_ issue list -R "$R" --state open --label "$l" --limit 50 --json number,title \
      -q ".[] | \"$l · #\(.number) · \(.title)\""
  done
fi

# ---------------------------------------------------------------- sessions
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
               [ -n "${url:-}" ] && [ "$(git -C "$d" remote get-url origin 2>/dev/null)" = "$url" ] && echo "$d"
             done; } | sort -u)
else
  paths=$root
fi
paths_json=$(printf '%s\n' "$paths" | jq -R . | jq -sc 'map(select(. != ""))')
agents=$(timeout -k 1 20 claude agents --json --all 2>/dev/null)
mine=$(printf '%s' "$agents" | jq -c --argjson p "$paths_json" \
  '[.[]? | select(.cwd as $c | any($p[]; $c == . or ($c | startswith(. + "/"))))]' 2>/dev/null)
self_sid=$(printf '%s' "$agents" | jq -r --arg pid "$self_pid" '.[]? | select((.pid|tostring) == $pid) | .sessionId' 2>/dev/null)

echo; echo "## owner (away since = start of the owner's last gap of 30+ min, or the last /status if later than the gap's end)"
gap_start=""; gap_end=""
if [ -n "$self_sid" ] && t=$(transcript "$self_sid") && [ -n "$t" ]; then
  msgs=$(owner_msgs "$t")
  # Walk back from the newest message (the one that asked for /status) to the first gap of 30+ minutes;
  # short messages after a long gap do not end the absence.
  later=""
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if [ -n "$later" ] && [ $(( $(epoch "$later") - $(epoch "$m") )) -ge 1800 ]; then gap_start=$m; gap_end=$later; break; fi
    later=$m
  done <<< "$msgs"
fi
seen=$(cat "$state_dir/seen" 2>/dev/null)
since=${STATUS_SINCE:-}
if [ -z "$since" ]; then
  since=$gap_start
  if [ -n "$seen" ] && { [ -z "$gap_end" ] || [ "$(epoch "$seen")" -gt "$(epoch "$gap_end")" ]; }; then since=$seen; fi
fi
[ -z "$since" ] && since=$midnight
since=$(date -d "$since" -Iseconds)
if [ -n "$gap_start" ]; then echo "last gap of 30+ min: $(hhmm "$gap_start") → $(hhmm "$gap_end")"
else echo "last gap of 30+ min: none found (not run from a Claude session, no transcript, or no gap)"; fi
if [ -n "$seen" ]; then echo "last /status: $(hhmm "$seen")"; else echo "last /status: never"; fi
echo "away since: $(hhmm "$since") ($since)"

echo; echo "## since (what changed since the away moment)"
since_utc=$(date -u -d "$since" +%FT%TZ)
if [ -n "$R" ]; then
  echo "merged:"
  gh_ pr list -R "$R" --state merged --search "merged:>=$since_utc" --limit 50 \
    --json number,title,mergedAt -q 'sort_by(.mergedAt) | .[] | "  #\(.number) · \(.title) · \(.mergedAt)"' | or_none
  echo "deploy runs started or finished (any outcome):"
  runs_since=$(gh_ run list -R "$R" --branch "$default_branch" --limit 200 --json workflowName,status,conclusion,createdAt,updatedAt,event,displayTitle \
    -q "[.[] | select(.updatedAt >= \"$since_utc\") | $deploy_sel]")
  printf '%s' "$runs_since" | jq -r ".[] | $real_sel
        | \"  \\(.workflowName) · \\(if (.conclusion // \"\") == \"\" then .status else .conclusion end) · started \\(.createdAt) · last update \\(.updatedAt)\"" 2>/dev/null | or_none
  printf '%s' "$runs_since" | jq -r "[.[] | $hk_sel] | select(length > 0)
    | \"  housekeeping (Maintenance only): \\(length) runs, \\([.[] | select(.conclusion != \"success\")] | length) not successful\"" 2>/dev/null
  echo "runs on $default_branch that failed:"
  gh_ run list -R "$R" --branch "$default_branch" --limit 200 --json workflowName,conclusion,createdAt,updatedAt \
    -q ".[] | select(.updatedAt >= \"$since_utc\")
        | select(.conclusion == \"failure\" or .conclusion == \"startup_failure\" or .conclusion == \"timed_out\")
        | \"  \(.workflowName) · \(.conclusion) · started \(.createdAt) · last update \(.updatedAt)\"" | or_none
  echo "issues opened:"
  gh_ issue list -R "$R" --state all --search "created:>=$since_utc" --limit 50 --json number,title,labels \
    -q '.[] | "  #\(.number) · \(.title) · \([.labels[].name] | join(","))"' | or_none
  echo "PRs opened:"
  gh_ pr list -R "$R" --state all --search "created:>=$since_utc" --limit 50 --json number,title,author,state \
    -q '.[] | "  #\(.number) · \(.title) · \(.author.login) · \(.state | ascii_downcase)"' | or_none
fi
if [ "$in_git" = 1 ]; then
  echo "local commits (all branches, newest first):"
  git log --all --since="$since" --format='  %h · %ad · %an · %D · %s' --date=format:'%a %d %b %H:%M' 2>/dev/null | head -15 | or_none
fi

echo; echo "## sessions (other Claude sessions in this project, from claude agents: name · kind · state · last active · branch · cwd)"
if [ -z "$agents" ]; then
  echo "unknown (claude agents unavailable): use the worktrees' activity column as the fallback"
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

echo; echo "## last-sessions (recent Claude sessions started in this project, newest first; this session left out: last active · topic · branch · live?)"
# Transcript folders are named after the session's cwd with / and . turned into -. Match every
# folder whose name starts with a checkout's key, then confirm by the cwd recorded in the transcript.
live_sids=$(printf '%s' "$agents" | jq -r '.[]?.sessionId' 2>/dev/null)
tmp_transcripts=$(mktemp)
while IFS= read -r pth; do
  [ -z "$pth" ] && continue
  for key in "$(printf '%s' "$pth" | tr '/' '-')" "$(printf '%s' "$pth" | tr '/.' '--')"; do
    ls -d "$HOME/.claude/projects/$key" "$HOME/.claude/projects/$key"-* 2>/dev/null
  done
done <<< "$paths" | sort -u | while read -r d; do ls -t "$d"/*.jsonl 2>/dev/null | head -10; done |
  xargs -r ls -t 2>/dev/null | head -40 | while read -r f; do
    sid=$(basename "$f" .jsonl); [ "$sid" = "$self_sid" ] && continue
    cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" | cut -d'"' -f4); [ -z "$cwd" ] && continue
    printf '%s\n' "$paths" | grep -qxF "$cwd" || printf '%s\n' "$paths" | while read -r q; do [[ "$cwd" == "$q"/* ]] && echo y; done | grep -q y || continue
    echo "$f"
  done > "$tmp_transcripts"
head -6 "$tmp_transcripts" | while read -r f; do
    sid=$(basename "$f" .jsonl)
    title=$(grep -o '"aiTitle":"[^"]*"' "$f" | tail -1 | cut -d'"' -f4)
    branch=$(tac "$f" | grep -m1 -o '"gitBranch":"[^"]*"' | cut -d'"' -f4)
    live=""; printf '%s\n' "$live_sids" | grep -qxF "$sid" && live=" · LIVE"
    echo "$(date -d "@$(stat -c %Y "$f")" '+%a %d %b %H:%M') · ${title:-(no title)} · ${branch:-?}$live"
  done | { out=$(cat); [ -n "$out" ] && printf '%s\n' "$out" || echo "none"; }

echo; echo "## mode (active development or maintenance)"
# Inferred from the owner's own messages: active when he typed in a Claude session here (other than
# this one) in the last 14 days. Commits do not count: agents commit under his name.
if [ -n "$declared" ]; then
  echo "mode $declared (declared in $status_file)"
else
  last_msg=""; last_title=""; cutoff14=$(date -d '-14 days' +%s)
  while read -r f; do
    [ "$(stat -c %Y "$f")" -lt "$cutoff14" ] && break   # newest first: older files cannot hold a newer message
    m=$(owner_msgs "$f" | head -1)
    if [ -n "$m" ] && { [ -z "$last_msg" ] || [ "$(epoch "$m")" -gt "$(epoch "$last_msg")" ]; }; then
      last_msg=$m; last_title=$(grep -o '"aiTitle":"[^"]*"' "$f" | tail -1 | cut -d'"' -f4)
    fi
  done < "$tmp_transcripts"
  if [ -n "$last_msg" ] && [ "$(epoch "$last_msg")" -ge "$cutoff14" ]; then
    echo "mode active (inferred: your last message in a session here $(hhmm "$last_msg"), ${last_title:-no title}; within 14 days)"
  else
    newest=$(head -1 "$tmp_transcripts"); when="none found"
    [ -n "$newest" ] && when="newest session here last active $(date -d "@$(stat -c %Y "$newest")" '+%a %d %b %Y')"
    echo "mode maintenance (inferred: no message from you in a session here in 14 days; $when)"
  fi
fi
rm -f "$tmp_transcripts"

# ---------------------------------------------------------------- local work
if [ "$in_git" = 1 ]; then
  prs_all=""; [ -n "$R" ] && prs_all=$(gh_ pr list -R "$R" --state all --limit 300 --json number,state,headRefName \
    -q '.[] | "\(.headRefName)\t\(.state | ascii_downcase) #\(.number)"')
  base=$default_branch; git rev-parse -q --verify "refs/remotes/origin/$default_branch" >/dev/null && base=origin/$default_branch

  echo; echo "## worktrees (branch · last commit · dirty files · PR · lock · activity <30 min; activity is the fallback signal)"
  git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}' | while read -r wt; do
    [ -d "$wt" ] || continue
    b=$(git -C "$wt" branch --show-current 2>/dev/null); b=${b:-detached}
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
    [ "$b" = "$default_branch" ] && [ "$dirty" = 0 ] && continue
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
    if [ "$act" = idle ] && [ "$dirty" = 0 ] && [[ "$pr" == merged* || "$pr" == closed* ]]; then echo "DONE"; continue; fi
    echo "$b · $last · $dirty · $pr · $lock · $act · $wt"
  done | awk '/^DONE$/ {d++; next} {print} END {if (d) print "+ " d " idle, clean worktrees whose PR merged or closed (cleanup candidates)"}' | or_none

  echo; echo "## unmerged (local branches with commits not on $base: branch · commits ahead · last commit · PR; a merged PR means squash-merged, likely done)"
  git for-each-ref refs/heads --format='%(refname:short)' | while read -r b; do
    [ "$b" = "$default_branch" ] && continue
    n=$(git rev-list --count "$base..$b" 2>/dev/null); [ "${n:-0}" = 0 ] && continue
    pr=$(printf '%s\n' "$prs_all" | awk -F'\t' -v b="$b" '$1 == b {print $2; exit}'); pr=${pr:-no PR}
    echo "$b · $n ahead · $(git log -1 --format='%cr' "$b") · $pr"
  done | head -15 | or_none
fi

# ---------------------------------------------------------------- planning docs (full level)
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

echo; echo "## inbox ($state_dir/waiting.md)"
grep -E '^- ' "$state_dir/waiting.md" 2>/dev/null || echo "(empty)"
echo; echo "## decided ($state_dir/decided.md, last 24h)"
cutoff=$(date -d '-24 hours' +%s)
grep -E '^- ' "$state_dir/decided.md" 2>/dev/null | while IFS= read -r l; do
  ts=$(printf '%s' "$l" | sed -nE 's/^- ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}).*/\1/p')
  [ -n "$ts" ] && [ "$(epoch "$ts")" -ge "$cutoff" ] && printf '%s\n' "$l"
done | or_none
exit 0
