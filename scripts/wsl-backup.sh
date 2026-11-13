#!/usr/bin/env bash
# wsl-backup: restic backup of the irreplaceable parts of this WSL home to the
# Synology. Its own repo and password, separate from the homelab backups.
#
#   wsl-backup          run a backup (+ apply retention)
#   wsl-backup status   show the latest snapshots and how old the newest is
#   wsl-backup init     create the repo (once)
#
# Scheduled by ~/.config/systemd/user/wsl-backup.timer (daily 12:30, no
# catch-up: it only runs if WSL is up at that moment).
#
# The password lives in ~/.config/restic-wsl/password. Keep a copy OUTSIDE
# this laptop (external password manager), or the backup is unreadable
# exactly when you need it.
set -euo pipefail

export RESTIC_REPOSITORY="${WSL_BACKUP_REPO:-sftp:synology:/home/restic-wsl}"
export RESTIC_PASSWORD_FILE="${WSL_BACKUP_PASSWORD_FILE:-$HOME/.config/restic-wsl/password}"

INCLUDES=(
  "$HOME/projects"
  "$HOME/homelab"
  "$HOME/dotfiles"
  "$HOME/.ssh"
  "$HOME/texmf"
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.claude/settings.json"
  "$HOME/.claude/agents"
  "$HOME/.claude/commands"
  "$HOME/.claude/skills"
  "$HOME/.claude/plans"
)
# Claude memory folders (not the session transcripts next to them).
for m in "$HOME"/.claude/projects/*/memory; do [[ -d "$m" ]] && INCLUDES+=("$m"); done
# Google Drive for desktop mirror on the Windows side (mirroring mode, so the
# files are local). Drive syncs deletions, so this is the versioned copy.
# Native Google Docs/Sheets are only link files here (accepted).
for d in /mnt/c/Users/*/"My Drive"; do [[ -d "$d" ]] && INCLUDES+=("$d"); done

# Rebuildable content, same idea as archive-project. Venvs are detected by
# their pyvenv.cfg, plus anything named .venv (Docker-made ones can lack the
# pyvenv.cfg).
EXCLUDES=(
  node_modules .venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .nox
  .next .nuxt .turbo .svelte-kit .parcel-cache .terraform .gradle
  .ipynb_checkpoints .julia
  .tmp.drivedownload .tmp.driveupload
  # Large, rebuildable if lost (decided 2026-11-13):
  "$HOME/projects/rawc/stocktimal/ml/bench"
)

log() { echo "[$(date -Is)] $*"; }

need_password() {
  [[ -s "$RESTIC_PASSWORD_FILE" ]] || {
    echo "No password file at $RESTIC_PASSWORD_FILE" >&2; exit 1; }
}

cmd_init() {
  need_password
  restic init
}

cmd_status() {
  need_password
  restic snapshots --compact --latest 5
  local last
  last=$(restic snapshots --json --latest 1 | python3 -c \
    'import json,sys; s=json.load(sys.stdin); print(s[-1]["time"][:19] if s else "")')
  if [[ -z "$last" ]]; then
    echo "No snapshots yet."
  else
    local days=$(( ( $(date +%s) - $(date -d "$last" +%s) ) / 86400 ))
    echo "Newest snapshot: $last (${days} day(s) ago)"
  fi
}

# Git worktrees: a .git FILE pointing into .../worktrees/... (submodules point
# into .../modules/... and stay included).
worktree_roots() {
  find "$HOME/projects" -name node_modules -prune -o -name .git -type f -print 2>/dev/null \
    | while read -r g; do
        grep -q '^gitdir: .*/worktrees/' "$g" 2>/dev/null && dirname "$g"
      done
}

# Synology only reachable at home. Strict host-key checking (BatchMode) also
# means we never talk to some other machine that happens to have that IP.
synology_reachable() {
  timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 synology true >/dev/null 2>&1
}

cmd_run() {
  need_password
  if ! synology_reachable; then
    log "synology not reachable (not on home network?), skipped"
    exit 0
  fi
  local excl=()
  for e in "${EXCLUDES[@]}"; do excl+=(--exclude "$e"); done
  while read -r w; do [[ -n "$w" ]] && excl+=(--exclude "$w"); done < <(worktree_roots)
  # Only back up paths that exist (e.g. no texmf on a fresh machine).
  local paths=()
  for p in "${INCLUDES[@]}"; do [[ -e "$p" ]] && paths+=("$p"); done

  # Folders we can't read (e.g. Docker-owned dev database dirs like data/db)
  # can't be backed up anyway; skip them explicitly instead of warning.
  local unreadable=0
  while read -r u; do
    [[ -n "$u" ]] && { excl+=(--exclude "$u"); unreadable=$((unreadable + 1)); }
  done < <(find "${paths[@]}" -name node_modules -prune -o -type d ! -readable -print -prune 2>/dev/null)
  ((unreadable)) && log "skipping $unreadable unreadable folder(s)"

  log "backup start (${#paths[@]} paths) -> $RESTIC_REPOSITORY"
  # Exit 3 = snapshot saved but some files were unreadable: warn, don't fail.
  local rc=0
  restic backup --tag wsl --exclude-if-present pyvenv.cfg "${excl[@]}" "${paths[@]}" || rc=$?
  if ((rc == 3)); then
    log "warning: snapshot saved, but some files could not be read"
  elif ((rc != 0)); then
    log "backup FAILED (restic exit $rc)"; exit "$rc"
  fi
  log "retention"
  restic forget --tag wsl --keep-daily 7 --keep-weekly 8 --keep-monthly 12 --prune
  log "done"
}

case "${1:-run}" in
  run) cmd_run ;;
  status) cmd_status ;;
  init) cmd_init ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command: $1 (run|status|init)" >&2; exit 2 ;;
esac
