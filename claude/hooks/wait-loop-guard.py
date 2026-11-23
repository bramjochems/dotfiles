#!/usr/bin/env python3
"""PreToolUse hook on Bash: refuse shell wait loops that can hang forever.

Two cases (23 Nov 2026, stocktimal: ~60 agent-hours lost in wait loops since 12 Nov):
1. A loop that waits on `pgrep -f "<text>"`. The loop's own shell command line
   contains <text>, so pgrep finds itself and the loop never ends.
   A bracket pattern ('[j]ust test-changed') does not match itself and is allowed.
2. A loop that polls for a condition (`until`/`while` with `sleep`) with no time limit.
   Deliberate forever loops (`while true` with no break/exit) pass.

Everything else passes untouched. Exit 0 with a JSON deny, or exit 0 silently.
"""
import json
import re
import sys

ADVICE = (
    "Instead: for your own command, run it with run_in_background and wait for its completion "
    "notice (or `cmd & pid=$!; wait $pid`). For another session's process, use a pattern that "
    "cannot match itself, e.g. pgrep -f '[j]ust test-changed', or `flock <lockfile> <cmd>`. "
    "Give every polling loop a time limit: `timeout 900 bash -c 'until ...; do sleep 10; done'`, "
    "or a deadline check (e.g. `[ $SECONDS -lt 900 ]`)."
)

LOOP = re.compile(r"\b(until|while)\b.*?\bdo\b", re.S)
PGREP_F = re.compile(r"\bpgrep\s+(?:-[a-zA-Z]*f[a-zA-Z]*\b[^|;&]*)")
LIMIT = re.compile(
    r"\btimeout\s+\d|\$SECONDS|\bSECONDS\b|date\s+\+%s|\bdeadline\b|"
    r"-(lt|le|gt|ge)\b|\(\(\s*[a-zA-Z_]\w*\s*[<>]|\bbreak\b.*\b(tries|attempts|max|limit)\b",
    re.I | re.S,
)


HEREDOC = re.compile(r"<<-?\s*(['\"])(\w+)\1[^\n]*\n(.*?)\n\s*\2\b", re.S)
SHELL_FED = re.compile(r"\b(bash|sh|zsh|ssh|sudo|eval|source)\b[^\n|;&]*$")


def strip_text_heredocs(cmd: str) -> str:
    """Drop the body of a quoted heredoc (<<'EOF') used as text, e.g. an issue body.
    Keep it when the heredoc feeds a shell (`bash <<'EOF'`), since that body runs."""
    def repl(m: re.Match) -> str:
        line_start = cmd.rfind("\n", 0, m.start()) + 1
        if SHELL_FED.search(cmd[line_start:m.start()]):
            return m.group(0)
        return "<<TEXT\nTEXT"
    return HEREDOC.sub(repl, cmd)


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason + " " + ADVICE,
        }
    }))
    sys.exit(0)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    cmd = strip_text_heredocs(cmd)
    if not LOOP.search(cmd):
        return
    for m in PGREP_F.finditer(cmd):
        if "[" not in m.group(0):
            deny("Blocked: a wait loop on `pgrep -f` matches its own shell (its command line "
                 "contains the pattern), so it never ends.")
    # A deliberate forever loop (`while true`/`while :` with no break or exit, e.g. a
    # background watcher that is meant to run until killed) is not a wait and passes.
    forever = re.search(r"\bwhile\s+(true|:)\s*;?\s*do\b", cmd) and not re.search(r"\b(break|exit)\b", cmd)
    if re.search(r"\bsleep\b", cmd) and not LIMIT.search(cmd) and not forever:
        deny("Blocked: a loop that waits for a condition with no time limit hangs for hours "
             "when the condition never comes true.")


if __name__ == "__main__":
    main()
