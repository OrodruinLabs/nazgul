#!/usr/bin/env bash
set -euo pipefail

# Nazgul Lean-Comments Guard — blocks comment bloat in source edits.
#
# Two invocation modes:
#   1. PreToolUse hook (default): reads the Write/Edit/MultiEdit tool JSON from
#      stdin and inspects the content being written. Exit 0 = allow, Exit 2 =
#      block with reason on stderr.
#   2. Pre-commit-style check: `lean-comments-guard.sh --check FILE [FILE...]`
#      scans files already on disk. Exit 0 = clean, Exit 2 = violations found.
#      Used by the implementer/review steps before marking work IMPLEMENTED.
#
# Comment bloat (any of):
#   a. a run of >= N+1 consecutive line comments (// or #) that is not a license
#      header (N = guards.max_consecutive_comment_lines, default 2);
#   b. a <remarks>/<para> or multi-paragraph doc block on a NON-public member
#      (private/internal/protected method, test member, or private Python def);
#   c. a banner / separator comment (a run of ─ ━ ═ — or - = * _ ~);
#   d. a comment that narrates/restates the next line of code (micro-optimization
#      noise, or heavy token overlap with the following statement).
#
# Full XML/JSDoc/docstring on a PUBLIC member is allowed and expected. A single
# short comment explaining a non-obvious domain/venue quirk is allowed.
#
# No-op when guards.lean_comments is false so projects can opt out.

# --- Source-file extension → comment style -----------------------------------
# Returns "cfamily" (// line, /// or /** doc), "hash" (# line, """ docstring),
# or "" when the extension is not a recognized source language. NOTE: shell,
# yaml, and similar config formats are deliberately NOT covered — their header
# comment blocks are legitimate and not the kind of bloat this guard targets.
comment_style_for() {
  local path="$1" ext
  ext="${path##*.}"
  case "$ext" in
    cs|ts|tsx|js|jsx|mjs|cjs|mts|cts|go|java|rs|c|cc|cpp|cxx|h|hpp|hh|kt|kts|swift|php|scala|m|mm|dart)
      echo "cfamily" ;;
    py|rb)
      echo "hash" ;;
    *)
      echo "" ;;
  esac
}

# --- Detection engine --------------------------------------------------------
# Reads content on stdin, prints findings as "LINE|CATEGORY|MESSAGE" lines.
detect_violations() {
  local style="$1" maxrun="$2"
  awk -v style="$style" -v maxrun="$maxrun" '
    { line[NR] = $0 }
    END {
      n = NR
      # ---- (a) consecutive plain line-comment runs --------------------------
      i = 1
      while (i <= n) {
        if (is_plain(line[i])) {
          j = i; lic = 0
          while (j <= n && is_plain(line[j])) { if (is_lic(line[j])) lic = 1; j++ }
          rl = j - i
          if (rl > maxrun && !lic)
            emit(i, "comment-run", rl " consecutive line comments exceed the max of " maxrun)
          i = j
        } else i++
      }
      # ---- (c) banner / separator comments ----------------------------------
      for (i = 1; i <= n; i++) {
        if (is_plain(line[i]) || is_doc(line[i])) {
          if (is_banner(body(line[i]))) emit(i, "banner", "banner/separator comment")
        }
      }
      # ---- (d) restating / micro-optimization narration ---------------------
      for (i = 1; i < n; i++) {
        if (is_plain(line[i]) && !is_blank(line[i+1]) && !is_plain(line[i+1]) && !is_doc(line[i+1])) {
          b = tolower(body(line[i]))
          if (b ~ /pre-?siz|avoid re-?siz|avoid re-?alloc|reduce alloc|avoid alloc|for performance|micro-?opt|hot[ -]?path|fast[ -]?path|increment the|decrement the|loop over|loop through|iterate over|iterate through/) {
            emit(i, "restate", "comment narrates/justifies the next line (micro-optimization noise)")
          } else {
            split("", cw, " ")
            cb = b; gsub(/[^a-z0-9_]+/, " ", cb); nn = split(cb, ww, " ")
            for (k = 1; k <= nn; k++) if (length(ww[k]) >= 4) cw[ww[k]] = 1
            code = tolower(line[i+1]); gsub(/[^a-z0-9_]+/, " ", code); mm = split(code, pp, " ")
            shared = 0
            for (k = 1; k <= mm; k++) { w = pp[k]; if (length(w) >= 4 && (w in cw)) { shared++; delete cw[w] } }
            if (shared >= 3) emit(i, "restate", "comment substantially restates the next line of code")
          }
        }
      }
      # ---- (b) heavy doc on a non-public member -----------------------------
      if (style == "cfamily") {
        i = 1
        while (i <= n) {
          has_remarks = 0; multi = 0; gstart = 0
          if (is_doc(line[i])) {
            gstart = i; blankdoc = 0; cnt = 0
            while (i <= n && is_doc(line[i])) {
              if (tolower(line[i]) ~ /<remarks>|<para>/) has_remarks = 1
              if (body(line[i]) ~ /^[ \t]*$/) blankdoc = 1
              cnt++; i++
            }
            if (blankdoc || cnt >= 6) multi = 1
          } else if (line[i] ~ /\/\*\*/) {
            gstart = i; bl = 0
            while (i <= n) {
              if (tolower(line[i]) ~ /<remarks>|<para>/) has_remarks = 1
              if (line[i] ~ /^[ \t]*\*[ \t]*$/) bl++
              if (line[i] ~ /\*\//) { i++; break }
              i++
            }
            if (bl >= 1) multi = 1
          } else { i++; continue }
          if (has_remarks || multi) {
            k = gstart; testish = 0
            # advance to the line after the doc group
            k = i
            while (k <= n) {
              t = line[k]; sub(/^[ \t]+/, "", t)
              if (t ~ /^$/) { k++; continue }
              if (t ~ /^\[/) { if (tolower(t) ~ /test|fact|theory|testmethod|setup|teardown/) testish = 1; k++; continue }
              break
            }
            if (k <= n) {
              ld = line[k]; sub(/^[ \t]+/, "", ld)
              nonpub = (ld ~ /^(private|internal|protected)[^A-Za-z]/)
              if (tolower(ld) ~ /void[ \t]+test|task[ \t]+test/) testish = 1
              if (nonpub || testish) {
                why = has_remarks ? "<remarks>/<para> doc" : "multi-paragraph doc block"
                emit(gstart, "doc-on-nonpublic", why " on a non-public/test member")
              }
            }
          }
        }
      }
      # ---- (b) multi-paragraph docstring on a private/test Python def --------
      if (style == "hash") {
        for (i = 1; i < n; i++) {
          ld = line[i]; sub(/^[ \t]+/, "", ld)
          if (ld ~ /^(async[ \t]+)?def[ \t]+(_[A-Za-z0-9]|test_)/) {
            k = i + 1
            while (k <= n && is_blank(line[k])) k++
            if (k > n) continue
            dl = line[k]; sub(/^[ \t]+/, "", dl)
            if (dl ~ /^"""/) {
              rest = dl; sub(/^"""/, "", rest)
              if (index(rest, "\"\"\"") > 0) continue   # single-line docstring is fine
              blankin = 0; k2 = k + 1
              while (k2 <= n) { if (index(line[k2], "\"\"\"") > 0) break; if (is_blank(line[k2])) blankin = 1; k2++ }
              if (blankin) emit(i, "doc-on-nonpublic", "multi-paragraph docstring on a private/test function")
            }
          }
        }
      }
    }
    function is_blank(s) { return (s ~ /^[ \t]*$/) }
    function lt(s) { sub(/^[ \t]+/, "", s); return s }
    function is_plain(s,   t) {
      t = lt(s)
      if (style == "cfamily") return (t ~ /^\/\// && t !~ /^\/\/\// && t !~ /^\/\/!/)
      return (t ~ /^#/ && t !~ /^#!/)
    }
    function is_doc(s,   t) { t = lt(s); if (style == "cfamily") return (t ~ /^\/\/\//); return 0 }
    function body(s,   t) {
      t = lt(s)
      if (style == "cfamily") { sub(/^\/\/+!?/, "", t) } else { sub(/^#+/, "", t) }
      sub(/^[ \t]+/, "", t); return t
    }
    function is_lic(s) { return (tolower(s) ~ /copyright|spdx|licensed under|all rights reserved|@license|permission is hereby granted|apache license|mit license/) }
    function is_banner(b,   c) {
      if (index(b, "─") || index(b, "━") || index(b, "═") || index(b, "—")) {
        c = b; gsub(/[^─━═—]/, "", c); if (length(c) >= 9) return 1
      }
      if (b ~ /[-=*_~][-=*_~][-=*_~][-=*_~]/) return 1
      return 0
    }
    function emit(ln, cat, msg) { print ln "|" cat "|" msg }
  '
}

# --- Config resolution -------------------------------------------------------
# Echoes "ENABLED MAXRUN" or "DISABLED 0".
resolve_config() {
  local mode="$1" config="$2"
  local enabled maxrun
  if [ -f "$config" ]; then
    enabled=$(jq -r 'if .guards.lean_comments == false then "false" else "true" end' "$config" 2>/dev/null || echo "true")
    maxrun=$(jq -r '.guards.max_consecutive_comment_lines // 2' "$config" 2>/dev/null || echo "2")
  else
    # No project config: hook mode treats this as "not a Nazgul project" and
    # stays out of the way; explicit --check defaults to enabled.
    if [ "$mode" = "hook" ]; then enabled="false"; else enabled="true"; fi
    maxrun="2"
  fi
  case "$maxrun" in
    ''|*[!0-9]*) maxrun="2" ;;
  esac
  if [ "$enabled" = "true" ]; then echo "ENABLED $maxrun"; else echo "DISABLED 0"; fi
}

# Print findings for a given content blob; return 0 clean, 1 if any finding.
report_for_content() {
  local style="$1" maxrun="$2" fname="$3" content="$4"
  local findings
  findings=$(printf '%s' "$content" | detect_violations "$style" "$maxrun")
  [ -z "$findings" ] && return 0
  echo "NAZGUL LEAN-COMMENTS: Blocked — comment bloat in ${fname}" >&2
  while IFS='|' read -r ln _cat msg; do
    [ -z "$ln" ] && continue
    echo "  ${fname}:${ln} — ${msg}" >&2
  done <<< "$findings"
  echo "Cut it to a one-line quirk note or delete it. Full XML/JSDoc/docstring is" >&2
  echo "for PUBLIC interface members only; <inheritdoc/> goes on the implementation." >&2
  return 1
}

# =============================================================================
# Mode 1: --check FILE [FILE...]
# =============================================================================
if [ "${1:-}" = "--check" ]; then
  shift
  CONFIG="${NAZGUL_CONFIG:-${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul/config.json}"
  read -r STATE MAXRUN < <(resolve_config check "$CONFIG")
  if [ "$STATE" = "DISABLED" ]; then
    exit 0
  fi
  RC=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    style=$(comment_style_for "$f")
    [ -z "$style" ] && continue
    if ! report_for_content "$style" "$MAXRUN" "$f" "$(cat "$f")"; then
      RC=2
    fi
  done
  exit "$RC"
fi

# =============================================================================
# Mode 2: PreToolUse hook (stdin JSON)
# =============================================================================
INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
CONFIG="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul/config.json"
read -r STATE MAXRUN < <(resolve_config hook "$CONFIG")
if [ "$STATE" = "DISABLED" ]; then
  exit 0
fi

case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "")
    ;;
  Edit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
    ;;
  MultiEdit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    # Inspect the concatenation of all new_string values for this file.
    CONTENT=$(echo "$INPUT" | jq -r '[.tool_input.edits // [] | .[] | .new_string // ""] | join("\n")' 2>/dev/null || echo "")
    ;;
  *)
    exit 0
    ;;
esac

[ -z "$FILE_PATH" ] && exit 0
STYLE=$(comment_style_for "$FILE_PATH")
[ -z "$STYLE" ] && exit 0

if ! report_for_content "$STYLE" "$MAXRUN" "$FILE_PATH" "$CONTENT"; then
  exit 2
fi
exit 0
