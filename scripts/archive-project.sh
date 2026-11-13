#!/usr/bin/env bash
# archive-project: pack a folder under ~/projects into one .tar.zst on the
# NAS, leaving out content that can be rebuilt (dependencies, venvs, build
# caches). Dry run by default; --go to actually do it.
#
# The archive keeps everything else, including .git (history), uncommitted
# work, gitignored data and .env files. "Gitignored" is NOT treated as
# "rebuildable": experiment results and secrets are often gitignored too.
#
# Target defaults: ARCHIVE_HOST=chuwi-nas, ARCHIVE_ROOT=/export/bram/archive
# (backed up weekly by restic; see homelab backup.md).
set -euo pipefail

REMOTE_HOST="${ARCHIVE_HOST:-chuwi-nas}"
REMOTE_ROOT="${ARCHIVE_ROOT:-/export/bram/archive}"
PROJECTS_ROOT="$(realpath "${PROJECTS_ROOT:-$HOME/projects}")"
ZSTD_LEVEL="${ZSTD_LEVEL:-12}"

# Directory names that are always rebuildable. Python venvs are detected by
# their pyvenv.cfg instead of by name; Rust target/ only next to Cargo.toml.
EXCLUDE_NAMES=(node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache
  .tox .nox .next .nuxt .turbo .svelte-kit .parcel-cache .terraform .gradle
  .ipynb_checkpoints)

usage() {
  cat <<EOF
Usage: archive-project [--go] [--remove-local] <project-dir>

  <project-dir>   a folder under $PROJECTS_ROOT (e.g. rawc/blogging)
  --go            build, upload and verify the archive (default: dry run)
  --remove-local  after a verified upload, delete the local folder
                  (asks you to type the project path to confirm)

Archive lands at $REMOTE_HOST:$REMOTE_ROOT/<path>.tar.zst (+ .sha256).
Restore:
  ssh $REMOTE_HOST cat '$REMOTE_ROOT/<path>.tar.zst' | zstd -dc | tar -x -C <dest>
EOF
}

GO=0; REMOVE_LOCAL=0; TARGET=""
while (($#)); do
  case "$1" in
    --go) GO=1 ;;
    --remove-local) REMOVE_LOCAL=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [[ -z "$TARGET" ]] || { echo "only one project at a time" >&2; exit 2; }; TARGET="$1" ;;
  esac
  shift
done
[[ -n "$TARGET" ]] || { usage >&2; exit 2; }
if ((REMOVE_LOCAL && !GO)); then
  echo "--remove-local requires --go" >&2; exit 2
fi

# Accept both "rawc/blogging" and a full or relative path.
if [[ -d "$TARGET" ]]; then
  DIR="$(realpath "$TARGET")"
else
  DIR="$(realpath -m "$PROJECTS_ROOT/$TARGET")"
fi
[[ -d "$DIR" ]] || { echo "not a directory: $DIR" >&2; exit 1; }
case "$DIR" in
  "$PROJECTS_ROOT"/*) ;;
  *) echo "refusing: $DIR is not inside $PROJECTS_ROOT" >&2; exit 1 ;;
esac
REL="${DIR#"$PROJECTS_ROOT"/}"
NAME="$(basename "$DIR")"
PARENT="$(dirname "$DIR")"
REMOTE_FILE="$REMOTE_ROOT/$REL.tar.zst"
REMOTE_DIR="$(dirname "$REMOTE_FILE")"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (install via ~/dotfiles/install/apt.sh)" >&2; exit 1; }; }
need tar
((GO)) && { need zstd; need rsync; need sha256sum; }

human() { numfmt --to=iec --suffix=B "$1"; }
size_of() { du -sb "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

# ---- collect excludes -------------------------------------------------------
mapfile -t RAW < <(
  {
    name_expr=()
    for n in "${EXCLUDE_NAMES[@]}"; do name_expr+=(-name "$n" -o); done
    unset 'name_expr[${#name_expr[@]}-1]'
    find "$DIR" -type d \( "${name_expr[@]}" \) -prune -print 2>/dev/null
    find "$DIR" -name pyvenv.cfg -type f -not -path '*/node_modules/*' -printf '%h\n' 2>/dev/null
    find "$DIR" -name Cargo.toml -type f -not -path '*/node_modules/*' -printf '%h/target\n' 2>/dev/null \
      | while read -r t; do [[ -d "$t" ]] && echo "$t"; done
  } | sort -u
)
# Drop paths nested inside another excluded path.
EXCL=()
for p in "${RAW[@]}"; do
  skip=0
  for q in "${EXCL[@]}"; do [[ "$p" == "$q"/* ]] && { skip=1; break; }; done
  ((skip)) || EXCL+=("$p")
done

TOTAL=$(size_of "$DIR")
EXCL_SIZE=0
((${#EXCL[@]})) && EXCL_SIZE=$(size_of "${EXCL[@]}")
KEEP=$((TOTAL - EXCL_SIZE))

# ---- report -------------------------------------------------------------------
echo "Project : $REL"
echo "Target  : $REMOTE_HOST:$REMOTE_FILE"
echo "Size    : $(human "$TOTAL") total, $(human "$EXCL_SIZE") stripped, ~$(human "$KEEP") archived (before compression)"
echo
if ((${#EXCL[@]})); then
  echo "Stripped (rebuildable):"
  for p in "${EXCL[@]}"; do
    printf '  %8s  %s\n' "$(human "$(size_of "$p")")" "${p#"$DIR"/}"
  done | sort -k1,1 -h -r | head -25
  ((${#EXCL[@]} > 25)) && echo "  ... and $(( ${#EXCL[@]} - 25 )) more"
else
  echo "Stripped: nothing matched"
fi
echo

echo "Git state (kept in the archive, shown for awareness):"
found_git=0
while IFS= read -r g; do
  found_git=1
  r="$(dirname "$g")"
  dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l)
  remotes=$(git -C "$r" remote 2>/dev/null | tr '\n' ' ')
  unpushed="-"
  git -C "$r" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 \
    && unpushed=$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null)
  stashes=$(git -C "$r" stash list 2>/dev/null | wc -l)
  printf '  %-40s dirty=%-4s unpushed=%-3s stashes=%-2s remotes=%s\n' \
    "${r#"$PROJECTS_ROOT"/}" "$dirty" "$unpushed" "$stashes" "${remotes:-NONE}"
done < <(find "$DIR" \( -name node_modules -o -name .next \) -prune -o -name .git -print 2>/dev/null | sort)
((found_git)) || echo "  (no git repos)"
echo

mapfile -t ENVS < <(find "$DIR" \( -name node_modules -o -name .venv \) -prune -o -type f -name '.env*' \
  ! -name '.env.example' ! -name '.env.sample' ! -name '.env.template' -print 2>/dev/null)
if ((${#ENVS[@]})); then
  echo "Possible secrets included (.env files):"
  printf '  %s\n' "${ENVS[@]#"$DIR"/}"
  echo
fi

# ---- remote preflight ----------------------------------------------------------
q() { printf '%q' "$1"; }
if ! ssh -n -o BatchMode=yes "$REMOTE_HOST" "test -f $(q "$REMOTE_ROOT/README.md")"; then
  echo "ABORT: $REMOTE_HOST:$REMOTE_ROOT/README.md not found (wrong host/path, or archive folder moved?)" >&2
  exit 1
fi
if ssh -n -o BatchMode=yes "$REMOTE_HOST" "test -e $(q "$REMOTE_FILE")"; then
  echo "ABORT: $REMOTE_FILE already exists on $REMOTE_HOST. Not overwriting." >&2
  exit 1
fi

if ((!GO)); then
  echo "Dry run. Nothing written. Re-run with --go to archive."
  exit 0
fi

# ---- build locally ------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/$NAME.tar.zst"
EXCL_FILE="$TMP/excludes"
: > "$EXCL_FILE"
for p in "${EXCL[@]}"; do echo "${p#"$PARENT"/}" >> "$EXCL_FILE"; done

echo "Building archive..."
tar -C "$PARENT" --anchored --no-wildcards --exclude-from="$EXCL_FILE" -cf - "$NAME" \
  | zstd -T0 -"$ZSTD_LEVEL" -q -o "$ARCHIVE"

echo "Testing archive locally..."
zstd -t -q "$ARCHIVE"
MEMBERS=$(zstd -dc "$ARCHIVE" | tar -t | wc -l)
for p in "${EXCL[@]}"; do
  if zstd -dc "$ARCHIVE" | tar -t | grep -q -x -F "${p#"$PARENT"/}/"; then
    echo "ABORT: excluded path ended up in archive: ${p#"$PARENT"/}" >&2; exit 1
  fi
done
HASH=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
echo "$HASH  $NAME.tar.zst" > "$ARCHIVE.sha256"
echo "  $MEMBERS entries, $(human "$(stat -c %s "$ARCHIVE")") compressed, sha256 ${HASH:0:16}..."

# ---- upload + verify on the NAS -------------------------------------------------
echo "Uploading to $REMOTE_HOST..."
ssh -n -o BatchMode=yes "$REMOTE_HOST" "mkdir -p $(q "$REMOTE_DIR") && chmod 755 $(q "$REMOTE_DIR")"
rsync -t --ignore-existing --chmod=F644 "$ARCHIVE" "$ARCHIVE.sha256" "$REMOTE_HOST:$(q "$REMOTE_DIR")/"

echo "Verifying on $REMOTE_HOST..."
ssh -n -o BatchMode=yes "$REMOTE_HOST" "cd $(q "$REMOTE_DIR") && sha256sum -c --quiet $(q "$NAME.tar.zst.sha256") && zstd -t -q $(q "$NAME.tar.zst")" \
  || { echo "ABORT: remote verification failed. Local folder untouched." >&2; exit 1; }
# Match the folder's owner (best-effort; integrity was checked above).
ssh -n -o BatchMode=yes "$REMOTE_HOST" "chown media:media $(q "$REMOTE_FILE") $(q "$REMOTE_FILE.sha256")" 2>/dev/null || true
echo "OK: $REMOTE_HOST:$REMOTE_FILE verified (sha256 + zstd test)."
echo "It gets backed up in the next weekly restic run."

# ---- optional local removal ------------------------------------------------------
if ((REMOVE_LOCAL)); then
  echo
  # Read the confirmation from the terminal, never from piped input.
  answer=""
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    echo "No terminal to confirm on. Local folder kept."
    exit 0
  fi
  read -r -u 3 -p "Delete local folder $DIR? Type '$REL' to confirm: " answer || true
  exec 3<&-
  if [[ "$answer" == "$REL" ]]; then
    rm -rf -- "$DIR"
    echo "Deleted $DIR"
  else
    echo "Not confirmed. Local folder kept."
  fi
fi
