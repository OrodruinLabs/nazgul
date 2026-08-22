#!/usr/bin/env bash
set -euo pipefail

# Nazgul Prompt Guard — UserPromptSubmit text heuristic, fires in EVERY mode
# (hitl, afk, yolo alike); config.json is read for existence only, never for `mode`.
# NOT the mechanism that makes an illegitimate status change ineffective —
# task-transition.sh's compare-and-swap and the stop-hook's reconciliation are (ADR-020).
# Returns exit 2 to block the prompt, exit 0 to allow.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"
source "$SCRIPT_DIR/lib/structured-state.sh"

# One vocabulary, one definition: a restated copy here is how CANCELLED — the terminal
# status with no evidence gate — stayed unguarded through the objective that shipped it.
STATUS_ALT=$(printf '%s' "$VALID_STATUSES" | tr -s ' \t\n' '|' | sed 's/^|//; s/|$//')

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# Prompt comes from the UserPromptSubmit stdin envelope ({"prompt":"..."}), like pre-tool-guard.sh.
# Drained BEFORE any early exit: quitting mid-write EPIPEs the harness, turning the hook nonzero under pipefail.
STDIN_JSON=$(cat 2>/dev/null || echo "")

# If Nazgul not initialized, allow all prompts
if [ ! -f "$CONFIG" ]; then
  exit 0
fi
USER_PROMPT=$(printf '%s' "$STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null || echo "")

# If no prompt content available, allow
if [ -z "$USER_PROMPT" ]; then
  exit 0
fi

# Block manual NAZGUL_COMPLETE signals — only the review gate should emit this
if echo "$USER_PROMPT" | grep -q 'NAZGUL_COMPLETE'; then
  echo "BLOCKED: NAZGUL_COMPLETE can only be emitted by the review gate, not typed manually." >&2
  echo "Use /nazgul:start to resume the loop or /nazgul:status to check progress." >&2
  exit 2
fi

# A substring cannot detect intent (ADR-025), so this covers only the unambiguous shape: an
# imperative verb at line start, a TASK-NNN/PATCH-NNN, and a status word, outside fences/quotes/backticks.
scan_status_imperative() {
  printf '%s\n' "$1" | awk -v statuses="$STATUS_ALT" '
    BEGIN {
      # CLOSED enumerations — a list marker or lead-in absorbed before the verb, never a general matcher.
      marker = "([-*+]|[0-9]+[.)])[[:space:]]+"
      leadin = "([Pp]lease|[Cc]an[[:space:]]+you|[Cc]ould[[:space:]]+you|[Jj]ust|[Nn]ow|[Oo]kay|[Oo][Kk]|[Gg]o[[:space:]]+ahead[[:space:]]+and)[[:space:],]+"
      lead   = "^[[:space:]]*(" marker ")?(" leadin ")*"
      verb   = "^([Ss]et|[Cc]hange|[Mm]ark(s|ed)?)([^[:alnum:]_]|$)"
      # Width matches the repo-wide ^(TASK|PATCH)-[0-9]+$; a narrower copy here reads as silence, not rigour.
      taskre = "(^|[^[:alnum:]_])(TASK|PATCH)-[0-9]+([^[:alnum:]_]|$)"
      statre = "(^|[^[:alnum:]_])(" statuses ")([^[:alnum:]_]|$)"
    }
    function span_of(s,   pfx, rest, tend, send, last, sp) {
      if (!match(s, lead)) return ""
      pfx = RLENGTH
      rest = substr(s, pfx + 1)
      if (!match(rest, verb)) return ""
      if (!match(s, taskre)) return ""
      tend = RSTART + RLENGTH - 1
      if (!match(s, statre)) return ""
      send = RSTART + RLENGTH - 1
      last = (tend > send) ? tend : send
      if (last <= pfx) return ""
      sp = substr(s, pfx + 1, last - pfx)
      sub(/[^[:alnum:]_]+$/, "", sp)
      return sp
    }
    {
      raw = $0
      bare = raw
      if (raw ~ /^[[:space:]]*(```|~~~)/) { fence = !fence; kind = "a code fence"; eff = "" }
      else if (fence)                     { kind = "a code fence"; eff = "" }
      else if (raw ~ /^[[:space:]]*>/) {
        kind = "a blockquote"; eff = ""
        sub(/^([[:space:]]*>)+[[:space:]]*/, "", bare)
      }
      else {
        kind = "an inline code span"
        eff = raw
        gsub(/`[^`]*`/, " ", eff)
      }
      sp = span_of(eff)
      if (sp != "") { print "BLOCK"; print NR; print raw; print sp; exit 0 }
      if (!sup) {
        sp = span_of(bare)
        if (sp != "") { sup = 1; supn = NR; supk = kind; supl = raw }
      }
    }
    END { if (sup) { print "SUPPRESS"; print supn; print supk; print supl } }
  '
}

SCAN_REPORT=$(scan_status_imperative "$USER_PROMPT" || true)
SCAN_VERDICT=$(printf '%s\n' "$SCAN_REPORT" | sed -n '1p')
SCAN_LINE_NO=$(printf '%s\n' "$SCAN_REPORT" | sed -n '2p')

if [ "$SCAN_VERDICT" = "BLOCK" ]; then
  SCAN_LINE=$(printf '%s\n' "$SCAN_REPORT" | sed -n '3p')
  SCAN_SPAN=$(printf '%s\n' "$SCAN_REPORT" | sed -n '4p')
  echo "BLOCKED: Task status changes must go through the proper state machine." >&2
  echo "prompt-guard: matched line ${SCAN_LINE_NO}: ${SCAN_LINE}" >&2
  echo "prompt-guard: offending substring: ${SCAN_SPAN}" >&2
  echo "Use /nazgul:task to manage tasks or let the pipeline handle transitions." >&2
  echo "To discuss this text rather than run it, wrap it in backticks, a fenced block, or a > quote." >&2
  exit 2
fi

# A candidate only stripping made invisible is reported, never collapsed into "no match".
if [ "$SCAN_VERDICT" = "SUPPRESS" ]; then
  SCAN_KIND=$(printf '%s\n' "$SCAN_REPORT" | sed -n '3p')
  SCAN_LINE=$(printf '%s\n' "$SCAN_REPORT" | sed -n '4p')
  echo "prompt-guard: allowed — line ${SCAN_LINE_NO} is a status-change imperative suppressed inside ${SCAN_KIND}, so it reads as prose, not an instruction: ${SCAN_LINE}" >&2
fi

# Allow everything else
exit 0
