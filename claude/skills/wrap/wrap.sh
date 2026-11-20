#!/usr/bin/env bash
# wrap.sh — the mechanical half of /wrap. Same state dir as /status: <main checkout>/.status/
# (a worktree uses its main checkout's, a plain folder its own; override STATUS_STATE_DIR), kept out
# of git through .git/info/exclude.
#
#   wrap.sh prep               state dir, the current next.md, the inbox, whether a handoff exists
#   wrap.sh next    < items    replace next.md with these "- …" lines, capped at 10; the rest pruned with a note
#   wrap.sh handoff < doc      write handoff.md; the previous one becomes handoff.prev.md
set -uo pipefail
CAP=${WRAP_NEXT_CAP:-10}

if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  main_root=$(dirname "$common")
else
  common=""; main_root=$PWD
fi
state_dir=${STATUS_STATE_DIR:-$main_root/.status}
mkdir -p "$state_dir"
if [ -n "$common" ] && [ -z "${STATUS_STATE_DIR:-}" ]; then
  mkdir -p "$common/info"; grep -qxF '.status/' "$common/info/exclude" 2>/dev/null || printf '.status/\n' >> "$common/info/exclude"
fi
project=$(basename "$main_root")
atomic() { cat > "$1.tmp" && mv "$1.tmp" "$1"; }

case "${1:-}" in
  prep)
    echo "state dir: $state_dir · project: $project · today: $(date +%F)"
    echo; echo "## next.md (now)"; cat "$state_dir/next.md" 2>/dev/null || echo "(none yet)"
    echo; echo "## waiting.md (the inbox)"; grep -E '^- ' "$state_dir/waiting.md" 2>/dev/null || echo "(empty)"
    echo; echo "## handoff.md"
    if [ -f "$state_dir/handoff.md" ]; then echo "exists, written $(date -r "$state_dir/handoff.md" '+%a %d %b %H:%M'); /wrap replaces it and keeps it as handoff.prev.md"
    else echo "none"; fi
    ;;
  next)
    items=$(grep -E '^- ' || true)
    kept=$(printf '%s\n' "$items" | grep -E '^- ' | head -n "$CAP")
    pruned=$(printf '%s\n' "$items" | grep -E '^- ' | tail -n +"$((CAP + 1))")
    {
      echo "# $project · left for later"
      echo
      [ -n "$kept" ] && printf '%s\n' "$kept"
      if [ -n "$pruned" ]; then
        n=$(printf '%s\n' "$pruned" | wc -l)
        what=$(printf '%s\n' "$pruned" | sed -E 's/^- ([0-9]{4}-[0-9]{2}-[0-9]{2} · )?//; s/:.*//' | cut -c1-40 | paste -sd ';' | sed 's/;/; /g')
        echo
        echo "_Pruned $(date +%F): $n older item(s) over the cap of $CAP: $what._"
      fi
    } | atomic "$state_dir/next.md"
    echo "next.md: $(grep -cE '^- ' "$state_dir/next.md") items$([ -n "$pruned" ] && echo ", $(printf '%s\n' "$pruned" | wc -l) pruned") → $state_dir/next.md"
    ;;
  handoff)
    [ -f "$state_dir/handoff.md" ] && mv "$state_dir/handoff.md" "$state_dir/handoff.prev.md"
    atomic "$state_dir/handoff.md"
    echo "handoff.md written → $state_dir/handoff.md$([ -f "$state_dir/handoff.prev.md" ] && echo " (previous kept as handoff.prev.md)")"
    ;;
  *) echo "usage: wrap.sh prep | next < items | handoff < doc" >&2; exit 2 ;;
esac
