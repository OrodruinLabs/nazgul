#!/usr/bin/env bash
set -euo pipefail

# scripts/audit-agent-state-paths.sh — the roster audit for FEAT-030 (PRD AC2/AC4,
# RULES.md §15). Enumerates every file under agents/ (agents/templates/ included),
# opens each agent spec, and classifies every `nazgul/...` occurrence as
# state-write, state-read, or prose. A finding is an OPERATIONAL occurrence
# (state-write or state-read) that is not rooted at `<main_worktree_path>`; the
# `$(pwd)/nazgul` idiom is rooted at the working directory, not the main worktree,
# so it is a finding too.
#
# REPORTS, DOES NOT GATE — always exits 0. At the point in FEAT-030 where this
# ships the roster is unconverted and F > 0; a nonzero exit would hold the suite
# red across five conversion tasks. The `F == 0` gate over the shipped roster is a
# separate test (FEAT-030/TASK-011).
#
# Coverage grammar (RULES.md §15), emitted as the LAST stdout line, with
# N == M + K asserted by the emitter and a CLOSED skip-reason set:
#   audit-agent-state-paths: N scanned, M skipped (non-spec=a, unreadable=b, not-a-file=c), K checked, F findings
#     non-spec    — enumerated under agents/ but not a `.md` agent spec (e.g. reviewer-domains.json)
#     unreadable  — the file exists but could not be opened
#     not-a-file  — the enumerator produced a path that is not a regular file
# K == 0 with N > 0 emits `NOTHING CHECKED` on stderr. Like scripts/self-audit.sh
# and scripts/doctor.sh this advisory surface writes NO event for the vacuous case:
# it is a repo-scanning tool with no runtime tree of its own, and writing runtime
# state from a read-only scan would commit the very defect FEAT-030 closes.
#
# CLASSIFICATION is heuristic and its signals are enumerated so a conversion task
# can argue with a verdict rather than guess at it. An occurrence is OPERATIONAL
# on any one of six positive signals — two structural, four textual:
#   S1 it sits inside a fenced code block (fences here are often indented under a
#      numbered step, so the fence test ignores leading whitespace);
#   S2 the text before it on its line ends in a `>`/`>>` redirect;
#   T1 its line is a list item — the instruction idiom of this roster, where a
#      "Read first" enumeration names one state path per bullet;
#   T2 the line's leading token, markdown markers stripped, is in OP_TOKENS;
#   T3 an OP_TOKENS token sits immediately before it, decoration aside;
#   T4 a bare-form verb (BARE_OP) or an unambiguous shell command (PREFIX_CMD)
#      appears anywhere in the preceding text of that line.
# A NEGATION in the preceding text ("Do NOT write", "Never", "rather than")
# cancels T1-T4 but never S1/S2: a sentence forbidding an operation is not an
# instruction to perform it, while a real command is a real command.
# Everything left is prose — text that only names where a file lives, or says what
# another actor does with it. Prose is COUNTED, never silently dropped, so the
# exemption is visible (PRD AC4). WRITE vs READ: a write on the redirect, on a
# mutating command in the preceding text (mkdir/tee/cp/mv/rm/touch/git add/git rm),
# or on a leading, immediately-preceding, or anywhere-in-prefix write verb.
#
# Scan root override (same idiom as tests/test-shellcheck.sh and
# tests/test-repo-content-boundary.sh): NAZGUL_AGENT_AUDIT_SCAN_ROOT. The detector
# is unreachable against a converted tree, so it is driven from outside.
#
# Usage: audit-agent-state-paths.sh

# Byte-oriented throughout: grep -ob offsets index bytes and the prefix slice below
# must index the same units. An em dash is 3 bytes in UTF-8.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAN_ROOT="${NAZGUL_AGENT_AUDIT_SCAN_ROOT:-$REPO_ROOT}"
ENTRY="audit-agent-state-paths"

OCCURRENCE_RE='(\$\(pwd\)/nazgul|\$PWD/nazgul|\$\{PWD\}/nazgul|[^[:space:]'"'"'"`]*nazgul/[^[:space:]'"'"'"`]*)'
ROOT_MARKER='<main_worktree_path>/nazgul'

# A bare `nazgul` DIRECTORY argument (`self-audit.sh nazgul`) is the same cwd-dependent read
# with no slash for OCCURRENCE_RE to see; argument-position-scoped so prose mentions stay prose.
BARE_DIR_RE='(^|[[:space:]])["'"'"'`(]*(bash|sh|cd|ls|cat|source|[^[:space:]"'"'"'`]*\.(sh|bash))["'"'"'`)]*[[:space:]]+nazgul([[:space:]"'"'"'`);,.]|$)'

BARE_OP='read|write|create|append|update|record|save|persist|load|open|emit|copy|move'
BARE_OP="$BARE_OP"'|delete|remove|add|set|store|run|check|verify|scan|list|parse|log'
BARE_OP="$BARE_OP"'|generate|produce|overwrite|go|use'

OP_TOKENS="$BARE_OP"'|reads|writes|creates|appends|updates|records|saves|persists|loads'
OP_TOKENS="$OP_TOKENS"'|opens|emits|copies|moves|deletes|removes|adds|sets|stores|runs'
OP_TOKENS="$OP_TOKENS"'|checks|verifies|scans|lists|parses|logs|generates|produces'
OP_TOKENS="$OP_TOKENS"'|overwrites|goes|uses'
OP_TOKENS="$OP_TOKENS"'|mkdir|cat|jq|echo|printf|tee|git|cp|mv|rm|touch|grep|sed|awk|ls'
OP_TOKENS="$OP_TOKENS"'|find|source|bash|sh'

BARE_WRITE='write|create|append|update|record|save|persist|emit|copy|move|delete|remove'
BARE_WRITE="$BARE_WRITE"'|add|set|store|generate|produce|overwrite|go|mkdir|touch|tee'

WRITE_TOKENS="$BARE_WRITE"'|writes|creates|appends|updates|records|saves|persists|emits'
WRITE_TOKENS="$WRITE_TOKENS"'|copies|moves|deletes|removes|adds|sets|stores|generates'
WRITE_TOKENS="$WRITE_TOKENS"'|produces|overwrites|goes|cp|mv|rm'

PREFIX_CMD='mkdir|jq|cat|printf|echo|tee|touch|grep|sed|awk|source'
LIST_ITEM_RE='^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]'
REDIRECT_RE='>>?[[:space:]]*["'"'"'(]*$'
MUTATING_CMD_RE='(^|[^A-Za-z0-9_-])(mkdir|tee|touch|cp|mv|rm)[[:space:]]|git[[:space:]]+(add|rm)[[:space:]]'
NEGATION_RE='(^|[^A-Za-z])([Dd]o [Nn][Oo][Tt]|don'"'"'t|[Nn][Ee][Vv][Ee][Rr]|cannot|can'"'"'t|must not|rather than|instead of)([^A-Za-z]|$)'

SCANNED=0
CHECKED=0
SKIP_NON_SPEC=0
SKIP_UNREADABLE=0
SKIP_NOT_A_FILE=0
FINDINGS=0
OCC_WRITE=0
OCC_READ=0
OCC_PROSE=0
OCC_ROOTED=0
FINDING_LINES=""

# _strip_markers <line> — drop leading whitespace, one markdown list/quote/heading
# marker, and any leading emphasis run, so the token test sees the statement.
_strip_markers() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/^([-*+]|[0-9]+[.)]|>+|#{1,6})[[:space:]]+//; s/^[[:space:]]+//; s/^[*_`]+//'
}

_is_token() {
  printf '%s' "$1" | grep -qiE "^($2)\$"
}

# _is_rooted <match> — rooted means BEGINS at the symbolic root, after only syntactic
# delimiters; a substring test counts `$PWD/<main_worktree_path>/nazgul/x` as rooted.
_is_rooted() {
  local s="$1"
  while [ -n "$s" ]; do
    case "$s" in
      '='*|'('*|'['*|'{'*|'"'*|"'"*|'`'*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  case "$s" in "$ROOT_MARKER"*) return 0 ;; esac
  return 1
}

# _classify <line> <in_fence> <prefix-before-match> -> state-write|state-read|prose
_classify() {
  local line="$1" in_fence="$2" prefix="$3" first_tok prev_tok redirect=0 textual=0

  printf '%s' "$prefix" | grep -qE "$REDIRECT_RE" && redirect=1
  first_tok="$(_strip_markers "$line" | sed -E 's/([^A-Za-z0-9_-]).*$//')"
  prev_tok="$(printf '%s' "$prefix" | sed -E 's/[^A-Za-z0-9_-]+$//; s/^.*[^A-Za-z0-9_-]//')"

  if printf '%s' "$line" | grep -qE "$LIST_ITEM_RE" \
     || _is_token "$first_tok" "$OP_TOKENS" || _is_token "$prev_tok" "$OP_TOKENS" \
     || printf '%s' "$prefix" | grep -qE "(^|[^A-Za-z0-9_-])($PREFIX_CMD)([^A-Za-z0-9_-]|\$)" \
     || printf '%s' "$prefix" | grep -qiE "(^|[^A-Za-z0-9_-])($BARE_OP)([^A-Za-z0-9_-]|\$)"; then
    textual=1
  fi
  # A sentence forbidding the operation is not an instruction to perform it: the
  # negation overrides the textual signals, never a real command or redirect.
  printf '%s' "$prefix" | grep -qiE "$NEGATION_RE" && textual=0

  if [ "$in_fence" != "1" ] && [ "$redirect" != "1" ] && [ "$textual" != "1" ]; then
    printf 'prose'
    return 0
  fi

  if [ "$redirect" = "1" ] || printf '%s' "$prefix" | grep -qE "$MUTATING_CMD_RE" \
     || _is_token "$first_tok" "$WRITE_TOKENS" || _is_token "$prev_tok" "$WRITE_TOKENS" \
     || printf '%s' "$prefix" | grep -qiE "(^|[^A-Za-z0-9_-])($BARE_WRITE)([^A-Za-z0-9_-]|\$)"; then
    printf 'state-write'
    return 0
  fi
  printf 'state-read'
}

_check_file() {
  local rel="$1" full="$SCAN_ROOT/$1"
  local line lineno=0 in_fence=0 hit off match cls prefix undented tail_after bare_off
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Fences in this roster are frequently indented under a numbered step; a
    # column-0-only test leaves whole shell blocks reading as prose.
    undented="${line#"${line%%[![:space:]]*}"}"
    case "$undented" in
      '```'*|'~~~'*) in_fence=$((1 - in_fence)); continue ;;
    esac
    # `nazgul`, not `nazgul/`: the cwd-rooted idioms ($(pwd)|$PWD|${PWD})/nazgul carry no
    # trailing slash, and a `nazgul/`-only prefilter drops them before the matcher sees them.
    case "$line" in
      *nazgul*) ;;
      *) continue ;;
    esac
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      off="${hit%%:*}"
      match="${hit#*:}"
      prefix="${line:0:$off}"
      cls="$(_classify "$line" "$in_fence" "$prefix")"
      case "$cls" in
        prose) OCC_PROSE=$((OCC_PROSE + 1)); continue ;;
        state-write) OCC_WRITE=$((OCC_WRITE + 1)) ;;
        state-read) OCC_READ=$((OCC_READ + 1)) ;;
      esac
      if _is_rooted "$match"; then
        OCC_ROOTED=$((OCC_ROOTED + 1)); continue
      fi
      FINDINGS=$((FINDINGS + 1))
      FINDING_LINES="${FINDING_LINES}  ${rel}:${lineno}: ${cls} — ${match}
"
    done < <(printf '%s\n' "$line" | grep -obE "$OCCURRENCE_RE" || true)
    # A command taking a bare `nazgul` directory argument is a real command, so it is
    # operational for the same reason a fenced line is — hence in_fence=1 below.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      off="${hit%%:*}"
      match="${hit#*:}"
      tail_after="${match##*nazgul}"
      bare_off=$((off + ${#match} - ${#tail_after} - 6))
      prefix="${line:0:$bare_off}"
      cls="$(_classify "$line" 1 "$prefix")"
      case "$cls" in
        state-write) OCC_WRITE=$((OCC_WRITE + 1)) ;;
        *) cls="state-read"; OCC_READ=$((OCC_READ + 1)) ;;
      esac
      FINDINGS=$((FINDINGS + 1))
      FINDING_LINES="${FINDING_LINES}  ${rel}:${lineno}: ${cls} — nazgul
"
    done < <(printf '%s\n' "$line" | grep -obE "$BARE_DIR_RE" || true)
  done < "$full"
}

if [ ! -d "$SCAN_ROOT/agents" ]; then
  printf '%s: no agents/ directory under %s — the enumerator has nothing to walk\n' \
    "$ENTRY" "$SCAN_ROOT" >&2
else
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    SCANNED=$((SCANNED + 1))
    full="$SCAN_ROOT/$rel"
    if [ ! -f "$full" ]; then
      SKIP_NOT_A_FILE=$((SKIP_NOT_A_FILE + 1))
      continue
    fi
    case "$rel" in
      *.md) ;;
      *) SKIP_NON_SPEC=$((SKIP_NON_SPEC + 1)); continue ;;
    esac
    if [ ! -r "$full" ]; then
      SKIP_UNREADABLE=$((SKIP_UNREADABLE + 1))
      continue
    fi
    CHECKED=$((CHECKED + 1))
    _check_file "$rel"
  done < <(cd "$SCAN_ROOT" && find agents \( -type f -o -type l \) -print | LC_ALL=C sort)
fi

if [ "$FINDINGS" -gt 0 ]; then
  printf '%s: %d finding(s) — an operational path not rooted at <main_worktree_path>:\n' \
    "$ENTRY" "$FINDINGS"
  printf '%s' "$FINDING_LINES"
fi

printf '%s: occurrences %d classified (state-write=%d, state-read=%d, prose=%d), %d already rooted\n' \
  "$ENTRY" "$((OCC_WRITE + OCC_READ + OCC_PROSE))" "$OCC_WRITE" "$OCC_READ" "$OCC_PROSE" "$OCC_ROOTED"

SKIPPED=$((SKIP_NON_SPEC + SKIP_UNREADABLE + SKIP_NOT_A_FILE))
if [ "$SCANNED" -ne $((SKIPPED + CHECKED)) ]; then
  printf '%s: INTERNAL — coverage accounting mismatch: %d scanned != %d skipped + %d checked\n' \
    "$ENTRY" "$SCANNED" "$SKIPPED" "$CHECKED" >&2
fi
if [ "$CHECKED" -eq 0 ]; then
  if [ "$SCANNED" -gt 0 ]; then
    printf '%s: NOTHING CHECKED — all %d candidate(s) skipped\n' "$ENTRY" "$SCANNED" >&2
  else
    printf '%s: NOTHING CHECKED — no agent specs discovered\n' "$ENTRY" >&2
  fi
fi

printf '%s: %d scanned, %d skipped (non-spec=%d, unreadable=%d, not-a-file=%d), %d checked, %d findings\n' \
  "$ENTRY" "$SCANNED" "$SKIPPED" "$SKIP_NON_SPEC" "$SKIP_UNREADABLE" "$SKIP_NOT_A_FILE" \
  "$CHECKED" "$FINDINGS"

exit 0
