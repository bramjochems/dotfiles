#!/usr/bin/env bash
# SessionStart hook (startup|clear), system-wide: a few lines on what waits in this folder.
#
# Keep the output SMALL: a pointer, not the state. It rides in the context for the whole session.
# Prints nothing when there is nothing to say. Local only: no network, no git fetch, no gh, so the
# git facts are as of the last fetch. A hard internal timeout kills it silently (nothing printed:
# output is buffered and written at the very end). PRs, CI and pushes are /status's job.
#
# .status/ is found the way /status does it (claude/skills/status/gather.sh): in a git repo the main
# checkout's (a worktree maps to its main checkout, via --git-common-dir); in a plain folder $PWD/.status.
# Unlike /status it never creates the folder.

if [ -z "${STATUS_CONTEXT_INNER:-}" ]; then
  command -v timeout >/dev/null || exit 0
  STATUS_CONTEXT_INNER=1 timeout -k 0.2 "${STATUS_CONTEXT_TIMEOUT:-0.9}" "$0" "$@" 2>/dev/null
  exit 0  # a timeout or failure stays silent: no output, no hook error
fi
set -u
exec 2>/dev/null

# Hook input (JSON on stdin): cwd and session_id. Without jq or input, use $PWD.
input=""; [ -t 0 ] || input=$(head -c 65536)
cwd=""; sid=""
if [ -n "$input" ] && command -v jq >/dev/null; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty'); sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
fi
cd "${cwd:-$PWD}" 2>/dev/null || exit 0

if common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  in_git=1; main_root=$(dirname "$common_dir"); here=$(git rev-parse --show-toplevel)
else
  in_git=0; main_root=$PWD
fi
state_dir=${STATUS_STATE_DIR:-$main_root/.status}
out=()

# ---------------------------------------------------------------- 1. .status/
if [ -d "$state_dir" ]; then
  parts=()
  n=$(grep -cE '^- ' "$state_dir/waiting.md" 2>/dev/null); [ "${n:-0}" -gt 0 ] && parts+=("$n waiting on you")
  n=$(grep -cE '^- ' "$state_dir/next.md" 2>/dev/null); [ "${n:-0}" -gt 0 ] && parts+=("$n left for later")
  if [ -f "$state_dir/handoff.md" ]; then
    # /status's rule: fresh when written at or after the newest earlier session's last activity (10 min
    # slack). Earlier sessions: transcripts under ~/.claude/projects/<cwd key>{,-*}, this one left out.
    # No earlier session found: fresh when written in the last 3 days.
    hm=$(stat -c %Y "$state_dir/handoff.md"); key=$(printf '%s' "$main_root" | tr '/.' '--')
    last=$(find "$HOME/.claude/projects/$key" "$HOME/.claude/projects/$key"-* -maxdepth 1 -name '*.jsonl' \
             ! -name "${sid:-none}.jsonl" -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    last=${last%.*}
    if [ -n "$last" ]; then fresh=$(( hm >= last - 600 )); else fresh=$(( hm >= $(date +%s) - 3*86400 )); fi
    [ "$fresh" = 1 ] && parts+=("handoff $(date -d "@$hm" '+%a %-d %b %H:%M') (.status/handoff.md)")
  fi
  if [ ${#parts[@]} -gt 0 ]; then
    line=".status: ${parts[0]}"; for p in "${parts[@]:1}"; do line+=" · $p"; done
    out+=("$line → /status")
  fi
fi

# ---------------------------------------------------------------- 2. git, local facts as of the last fetch
if [ "$in_git" = 1 ]; then
  db=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); db=${db#origin/}
  if [ -z "$db" ]; then for b in main master; do git rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null && { db=$b; break; }; done; fi
  if [ -n "$db" ] && git rev-parse -q --verify "refs/remotes/origin/$db" >/dev/null; then
    upstream="origin/$db"
    fetched=""; [ -f "$common_dir/FETCH_HEAD" ] && fetched=$(date -d "@$(stat -c %Y "$common_dir/FETCH_HEAD")" '+%a %H:%M')
    asof="as of last fetch${fetched:+ $fetched}"
    if git rev-parse -q --verify "refs/heads/$db" >/dev/null; then
      behind=$(git rev-list --count "refs/heads/$db..refs/remotes/$upstream")
      [ "${behind:-0}" -gt 0 ] && out+=("$db is $behind commit$([ "$behind" = 1 ] || echo s) behind $upstream $asof → pull")
    fi

    # Worktrees that look finished: not the main checkout, not this one, a branch (not detached) whose tip
    # is in origin/<default> but not on its first-parent line (a fresh branch with no commits of its own is
    # "contained" too), idle for an hour, and clean. Prunable ones (folder gone) are counted apart.
    # Cheap tests first; `git status` only on the few that pass them, in parallel.
    declare -A merged=()
    while read -r ref sha; do merged[$ref]=$sha; done < <(git for-each-ref --merged "refs/remotes/$upstream" \
      --format='%(refname) %(objectname)' refs/heads)
    declare -A firstparent=()
    while read -r sha; do firstparent[$sha]=1; done < <(git rev-list --first-parent -n 2000 "refs/remotes/$upstream")
    prunable=0; cands=(); now=$(date +%s)
    while IFS=$'\t' read -r path branch flag; do
      [ "$flag" = prunable ] && { prunable=$((prunable + 1)); continue; }
      [ "$path" = "$main_root" ] || [ "$path" = "$here" ] || [ -z "$branch" ] && continue
      [ -d "$path" ] || { prunable=$((prunable + 1)); continue; }
      tip=${merged[$branch]:-}; [ -n "$tip" ] || continue
      [ -n "${firstparent[$tip]:-}" ] && continue
      gd=""; read -r _ gd < "$path/.git" || continue; [[ "$gd" = /* ]] || gd="$path/$gd"
      [ $(( now - $(stat -c %Y "$gd/index" "$gd/HEAD" | sort -rn | head -1) )) -lt 3600 ] && continue
      cands+=("$path")
    done < <(git worktree list --porcelain | awk '
      /^worktree /{ if (p != "") print p "\t" b "\t" f; p = substr($0, 10); b = ""; f = "" }
      /^branch /{ b = substr($0, 8) } /^prunable/{ f = "prunable" }
      END{ if (p != "") print p "\t" b "\t" f }')
    finished=0
    if [ ${#cands[@]} -gt 0 ]; then
      finished=$(printf '%s\0' "${cands[@]}" | xargs -0 -P 8 -I{} sh -c \
        '[ -z "$(git -C "$1" status --porcelain 2>/dev/null | head -1)" ] && echo y' _ {} | grep -c y)
    fi
    if [ "$finished" -gt 0 ] || [ "$prunable" -gt 0 ]; then
      how="git worktree remove"; [ -x "$main_root/scripts/closeout.sh" ] && how="scripts/closeout.sh"
      w=()
      [ "$finished" -gt 0 ] && w+=("$finished worktree$([ "$finished" = 1 ] || echo s) look$([ "$finished" = 1 ] && echo s) finished (merged into $upstream, clean)")
      [ "$prunable" -gt 0 ] && { how+="; git worktree prune"; w+=("$prunable prunable (folder gone)"); }
      line=${w[0]}; [ ${#w[@]} -gt 1 ] && line+=" · ${w[1]}"
      out+=("$line, $asof → $how")
    fi
  fi
fi

[ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
exit 0
