#!/usr/bin/env python3
"""PreToolUse hook on Bash: refuse shell wait loops that can hang forever.

Why (23 Nov 2026, stocktimal): about 60 agent-hours were lost since 12 Nov in wait loops that
never ended. Two kinds are refused:
1. A while/until loop whose condition runs `pgrep -f "<text>"`. The loop's own shell command
   line contains <text>, so pgrep finds itself and the loop never ends. A bracket pattern
   ('[j]ust test-changed') cannot match itself.
2. A while/until loop that sleeps while waiting for a condition and has no limit on the whole
   loop. Limits: `timeout N` on the shell that runs the loop (`timeout 900 bash -c '...'`),
   $SECONDS or `date +%s`, or a counter the loop increments and compares. A per-attempt
   `timeout` inside the loop, or one on an earlier command, is not a limit.

Passes: deliberate forever loops (`while true` whose body has no break/exit/return), waits on
your own job (`while kill -0 $pid`), list walks (`while read`, loops that `shift`), and loops
that do not sleep. Quoted strings (commit
messages, PR bodies, python -c code) and heredoc bodies are text, not shell, unless they are
fed to a shell (`bash -c '...'`, `ssh host '...'`, `bash <<'EOF'`), in which case they are
checked too.

Fails open by design: on any internal error, odd input or very large input it says nothing and
the command runs. It only ever adds a refusal; it never blocks by crashing.
"""
import json
import re
import sys

MAX_LEN = 200_000

ADVICE = (
    "Instead: for your own command, run it with run_in_background and wait for its completion "
    "notice (or `cmd & pid=$!; wait $pid`). For another session's process, use a pattern that "
    "cannot match itself, e.g. pgrep -f '[j]ust test-changed', or `flock <lockfile> <cmd>`. "
    "Give a polling loop a limit on the whole loop: `timeout 900 bash -c 'until ...; do sleep 10; done'`, "
    "a deadline (`[ $SECONDS -lt 900 ]`), or a counter (`n=$((n+1)); [ $n -ge 90 ] && break`)."
)

SHELL_WORD = r"(?<![\w./-])(?:bash|sh|zsh|dash|ssh|sudo|eval|source)(?![\w./-])"
_PREFIX = r"\s*(?:(?:sudo|env|nice|nohup)\s+(?:-\S+\s+)*|timeout\s+(?:-\S+\s+)*\S+\s+)*"
FED_CMD = re.compile(_PREFIX + r"(?:bash|sh|zsh|dash|eval|source|ssh)(?![\w./-])")
PIPED_TO_SHELL = re.compile(r"\|\s*" + _PREFIX + r"(?:bash|sh|zsh|dash)(?![\w./-])")
TIMEOUT_THEN_SHELL = re.compile(r"\btimeout\s+(?:-\S+\s+)*\S+\s+(?:\S+\s+)*?(?:bash|sh|zsh|dash|ssh)(?:\s+\S+)*\s+$|\btimeout\s+(?:-\S+\s+)*\S+\s+(?:bash|sh|zsh|dash)\s+(?:-\S+\s+)*-\w*c\s*$")
KEYWORD = re.compile(r"(?<![\w$./-])(while|until|for|select|do|done)(?![\w./-])")
CMD_START = set(";&|({\n")
LEAD_WORDS = ("do", "then", "else", "!", "time")


def strip_heredocs(text):
    """Return text with heredoc bodies that are not fed to a shell replaced by blank lines,
    plus the list of shell-fed heredoc bodies (to check separately). Linear in the input."""
    lines = text.split("\n")
    out, fed = [], []
    i = 0
    marker = re.compile(r"(?<![\w)<])<<-?\s*(['\"]?)([A-Za-z_]\w*)\1")
    while i < len(lines):
        line = lines[i]
        out.append(line)
        found = list(marker.finditer(line))
        delims = [m.group(2) for m in found]
        i += 1
        if not delims:
            continue
        seg = re.split(r"[|;&(]", line[: found[0].start()])[-1]
        shell_fed = bool(FED_CMD.match(seg)) or bool(PIPED_TO_SHELL.search(line[found[-1].end():]))
        heredoc_timeout = bool(re.match(r"\s*timeout\s", seg))
        for d in delims:
            body = []
            while i < len(lines) and lines[i].strip() != d:
                body.append(lines[i])
                i += 1
            if i < len(lines):  # the delimiter line
                i += 1
            out.extend("" for _ in body)
            out.append("")
            if shell_fed:
                fed.append(("\n".join(body), heredoc_timeout))
    return "\n".join(out), fed


def mask_quotes(text):
    """Replace quoted content with 'x' (same length, so offsets keep matching the original).
    Return the masked text and the list of (start, end) spans of quoted content."""
    chars = list(text)
    spans = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c in "'\"":
            j = i + 1
            while j < n and text[j] != c:
                if c == '"' and text[j] == "\\":
                    j += 1
                j += 1
            for k in range(i + 1, min(j, n)):
                if chars[k] != "\n":
                    chars[k] = "x"
            spans.append((i + 1, min(j, n)))
            i = j + 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;"):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                chars[k] = "x"
            i = j
            continue
        i += 1
    return "".join(chars), spans


def at_command_position(s, pos):
    j = pos - 1
    while j >= 0 and s[j] in " \t":
        j -= 1
    if j < 0 or s[j] in CMD_START:
        return True
    k = j
    while k >= 0 and not s[k].isspace() and s[k] not in CMD_START:
        k -= 1
    return s[k + 1 : j + 1] in LEAD_WORDS


def loops(s):
    """Yield (keyword, start, cond_start, cond_end, body_start, body_end) for while/until loops."""
    stack = []
    for m in KEYWORD.finditer(s):
        kw = m.group(1)
        if kw != "done" and not at_command_position(s, m.start()):
            continue
        if kw in ("while", "until", "for", "select"):
            stack.append([kw, m.start(), m.end(), None, None])
        elif kw == "do":
            if stack and stack[-1][3] is None:
                stack[-1][3] = m.start()
                stack[-1][4] = m.end()
        elif kw == "done" and stack:
            kw0, start, cs, ce, bs = stack.pop()
            if ce is not None and kw0 in ("while", "until"):
                yield kw0, start, cs, ce, bs, m.start()


SLEEP = re.compile(r"(?<![\w./$-])sleep\s")
COUNTER = re.compile(
    r"\(\(\s*[A-Za-z_]\w*\s*(\+\+|--|\+=|-=)|(?<![\w-])[A-Za-z_]\w*(\+\+|--)(?![\w-])"
    r"|\b[A-Za-z_]\w*=\$\(\(\s*\$?[A-Za-z_]\w*\s*[-+]|\blet\s|\b[A-Za-z_]\w*\+=\d"
)
CAP = re.compile(r"\s-(lt|le|gt|ge|eq|ne)\s|\(\([^)]*[<>]|\[\s*\S+\s*!?=\s*\S+\s*\]")
DEADLINE = re.compile(r"\$\{?SECONDS\b|\bSECONDS\b|date\s+\+%s")
PGREP_F = re.compile(r"\bpgrep\s+(?:-\S+\s+)*(?:-[a-zA-Z]*f|--full)")


def check(raw, outer_timeout=False, depth=0):
    """Return a refusal reason for this shell text, or None."""
    if depth > 3:
        return None
    text, fed = strip_heredocs(raw)
    for body, has_timeout in fed:
        reason = check(body, outer_timeout or has_timeout, depth + 1)
        if reason:
            return reason
    s, spans = mask_quotes(text)

    # Strings handed to a shell (`bash -c '...'`, `ssh host '...'`) are code: check them too.
    for a, b in spans:
        before = s[max(0, a - 80) : a - 1]
        if re.search(SHELL_WORD + r"(\s+\S+)*\s+-\w*c\s*$", before) or re.search(r"\bssh\s+(\S+\s+)*$", before):
            reason = check(text[a:b], outer_timeout or bool(TIMEOUT_THEN_SHELL.search(before + " ")), depth + 1)
            if reason:
                return reason

    for kw, start, cs, ce, bs, be in loops(s):
        cond, body = s[cs:ce], s[bs:be]
        raw_cond = text[cs:ce]
        if PGREP_F.search(cond) and "[" not in raw_cond:
            return ("Blocked: a wait loop on `pgrep -f` matches its own shell (its command line "
                    "contains the pattern), so it never ends.")
        if not (SLEEP.search(body) or SLEEP.search(cond)):
            continue
        if kw == "while" and re.fullmatch(r"\s*(true|:)\s*;?\s*", cond):
            if not re.search(r"\b(break|exit|return)\b", body):
                continue  # meant to run until someone stops it
        if re.search(r"\bkill\s+-0\b", cond):
            continue  # waiting on your own job; no worse than `wait $pid`
        if re.match(r"\s*(IFS=\S*\s+)?read\b", cond) or re.search(r"\bshift\b", body):
            continue  # walks a list (rate-limited), ends when the input runs out
        loop_text = s[cs:be]
        limited = (
            outer_timeout
            or DEADLINE.search(loop_text)
            or (COUNTER.search(loop_text) and CAP.search(loop_text))
        )
        if not limited:
            return ("Blocked: a loop that waits for a condition with no limit on the whole loop "
                    "hangs for hours when the condition never comes true.")
    return None


def main():
    try:
        data = json.load(sys.stdin)
        cmd = data["tool_input"]["command"]
        if not isinstance(cmd, str) or len(cmd) > MAX_LEN:
            return
        reason = check(cmd)
    except Exception:
        return
    if reason:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason + " " + ADVICE,
            }
        }))


if __name__ == "__main__":
    main()
