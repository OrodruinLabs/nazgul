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
#   c. a banner / separator comment (a run of box-drawing or ASCII rule chars);
#   d. a comment that narrates/restates the next line of code (micro-optimization
#      noise, or heavy token overlap with the following statement).
#
# Full XML/JSDoc/docstring on a PUBLIC member is allowed and expected. A single
# short comment explaining a non-obvious domain/venue quirk is allowed.
#
# Shell IS covered (FEAT-028 / TASK-012). The old blanket `.sh` exemption made
# the guard inert in a ~71-script shell repo — the header concern that motivated
# it is now handled explicitly instead: the ONE shebang-adjacent file-header
# block is exempt from the run limit, and everything after it is body. The only
# other escape is an explicit per-run annotation, `lean-comments: allow-run`,
# which waives the run limit for that run alone and never the banner or
# restatement rules.
#
# No-op when guards.lean_comments is false so projects can opt out.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"

# Shell-ness by extension, or by shebang when the path carries no usable one
# (githooks(5) names are extensionless). $2 is the content's first line, if known.
is_shell_source() {
  local path="$1" first="${2:-}"
  case "${path##*.}" in
    sh|bash) return 0 ;;
  esac
  [[ "$first" =~ ^#!.*[/[:space:]](ba|k|z)?sh([[:space:]]|$) ]] && return 0
  return 1
}

# Returns "cfamily" (// line, /// or /** doc), "hash" (# line, """ docstring),
# or "" when the file is not a recognized source language.
comment_style_for() {
  local path="$1" first="${2:-}"
  case "${path##*.}" in
    cs|ts|tsx|js|jsx|mjs|cjs|mts|cts|go|java|rs|c|cc|cpp|cxx|h|hpp|hh|kt|kts|swift|php|scala|m|mm|dart)
      echo "cfamily"; return 0 ;;
    py|rb)
      echo "hash"; return 0 ;;
  esac
  if is_shell_source "$path" "$first"; then echo "hash"; return 0; fi
  echo ""
}

# Detection engine: reads content on stdin, prints findings as
# "LINE|CATEGORY|MESSAGE". $3 (hdr) enables the shell file-header allowance.
detect_violations() {
  local style="$1" maxrun="$2" hdr="${3:-0}"
  awk -v style="$style" -v maxrun="$maxrun" -v hdr="$hdr" -v tsq="'''" '
    { line[NR] = $0 }
    END {
      n = NR
      # Heredoc bodies are DATA: this repo`s shell tests embed whole markdown
      # manifests, whose section headings are not comments.
      for (i = 1; i <= n; i++) {
        if (is_plain(line[i]) || is_doc(line[i])) continue
        p = index(line[i], "<<")
        if (!p || substr(line[i], p + 2, 1) == "<") continue
        rest = substr(line[i], p + 2)
        sub(/^-/, "", rest); sub(/^[ \t]+/, "", rest)
        gsub("[\"\047]", "", rest)
        if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) continue
        term = substr(rest, 1, RLENGTH)
        for (q = i + 1; q <= n; q++) { t = line[q]; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t); if (t == term) break }
        # No terminator ahead: that was a bit shift or a mention, not a heredoc.
        if (q > n) continue
        for (k = i + 1; k < q; k++) line[k] = ""
        i = q
      }
      # The file-header contract block: the FIRST comment run of a shell file,
      # reachable from the shebang across blank and shell-option lines only.
      hdrstart = 0; hdrend = 0
      if (hdr && n >= 1 && lt(line[1]) ~ /^#!/) {
        p = 2
        while (p <= n && (is_blank(line[p]) || is_prologue(line[p]))) p++
        if (p <= n && is_plain(line[p])) {
          hdrstart = p
          while (p <= n && is_plain(line[p])) p++
          hdrend = p - 1
        }
      }
      # (a) consecutive plain line-comment runs
      i = 1
      while (i <= n) {
        if (is_plain(line[i])) {
          j = i; lic = 0
          while (j <= n && is_plain(line[j])) { if (is_lic(line[j])) lic = 1; j++ }
          rl = j - i
          # A license header is exempt only in the first 3 lines of the scanned
          # content — a mid-file run mentioning a license must not slip through.
          if (rl > maxrun && !(lic && i <= 3) && i != hdrstart && !is_waived(line[i]))
            emit(i, "comment-run", rl " consecutive line comments exceed the max of " maxrun)
          i = j
        } else i++
      }
      # (c) banner / separator comments
      for (i = 1; i <= n; i++) {
        if (is_plain(line[i]) || is_doc(line[i])) {
          if (is_banner(body(line[i]))) emit(i, "banner", "banner/separator comment")
        }
      }
      # (d) a comment that narrates or repeats the line below it
      for (i = 1; i < n; i++) {
        # The header contract block describes the FILE, so its last line is not
        # narration of whatever code happens to follow it.
        if (hdrstart && i >= hdrstart && i <= hdrend) continue
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
      # (b) heavy doc on a non-public member
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
            # Multi-paragraph = a blank doc line splits paragraphs. A long
            # SINGLE-paragraph summary is fine, so line count alone never blocks.
            if (blankdoc) multi = 1
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
      # (b) multi-paragraph docstring on a private/test Python def
      if (style == "hash") {
        for (i = 1; i < n; i++) {
          ld = line[i]; sub(/^[ \t]+/, "", ld)
          if (ld ~ /^(async[ \t]+)?def[ \t]+(_[A-Za-z0-9]|test_)/) {
            k = i + 1
            while (k <= n && is_blank(line[k])) k++
            if (k > n) continue
            dl = line[k]; sub(/^[ \t]+/, "", dl)
            sub(/^[rRfFbBuU]+/, "", dl)   # optional string prefix: r/f/rf/b/u"""
            qq = ""
            if (dl ~ /^"""/) qq = "\"\"\""
            else if (substr(dl, 1, 3) == tsq) qq = tsq
            if (qq != "") {
              rest = substr(dl, 4)
              if (index(rest, qq) == 0) {   # not a single-line docstring
                blankin = 0; k2 = k + 1
                while (k2 <= n) { if (index(line[k2], qq) > 0) break; if (is_blank(line[k2])) blankin = 1; k2++ }
                if (blankin) emit(i, "doc-on-nonpublic", "multi-paragraph docstring on a private/test function")
              }
            }
          }
        }
      }
    }
    function is_blank(s) { return (s ~ /^[ \t]*$/) }
    function lt(s) { sub(/^[ \t]+/, "", s); return s }
    function is_plain(s,   t) {
      t = lt(s)
      if (style == "cfamily") {
        if (!(t ~ /^\/\// && t !~ /^\/\/\// && t !~ /^\/\/!/)) return 0
      } else if (!(t ~ /^#/ && t !~ /^#!/)) return 0
      return !is_directive(s)
    }
    function is_doc(s,   t) { t = lt(s); if (style == "cfamily") return (t ~ /^\/\/\//); return 0 }
    function is_prologue(s,   t) { t = lt(s); return (t ~ /^(set|shopt)[ \t]/) }
    function is_waived(s) { return (body(s) ~ /^lean-comments:[ \t]*allow-run([ \t]|$)/) }
    # A tool directive (shellcheck, noqa, ...) is machine-required syntax that
    # happens to look like a comment; it is never bloat and never a run member.
    function is_directive(s,   b) {
      b = tolower(body(s))
      return (b ~ /^(shellcheck|noqa|nosec|nolint|type:|pylint|eslint|prettier|mypy|ruff|flake8|pragma|ts-|biome|istanbul|codeql|fmt:|gofmt|golangci|checkstyle|suppress)/)
    }
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

# Config resolution: echoes "ENABLED MAXRUN" or "DISABLED 0".
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
# Sets LAST_FINDING_COUNT so callers can total findings without re-running awk.
LAST_FINDING_COUNT=0
report_for_content() {
  local style="$1" maxrun="$2" fname="$3" content="$4" hdr="${5:-0}"
  local findings
  findings=$(printf '%s' "$content" | detect_violations "$style" "$maxrun" "$hdr")
  LAST_FINDING_COUNT=$(printf '%s' "$findings" | grep -c '[^[:space:]]' || true)
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

# A vacuous clean must be distinguishable from a real one (TRD §6): a file that
# was never looked at is counted and named, never folded into the clean result.
emit_coverage_line() {
  printf 'lean-comments: %d scanned, %d skipped (unsupported-extension=%d, unreadable=%d), %d checked, %d findings\n' \
    "$SCANNED" "$((SKIP_EXT + SKIP_UNREADABLE))" "$SKIP_EXT" "$SKIP_UNREADABLE" "$CHECKED" "$FINDINGS"
}

emit_coverage_vacuous_event() {
  local nd
  if [ -n "${NAZGUL_CONFIG:-}" ]; then
    nd="$(dirname "$NAZGUL_CONFIG")"
  else
    nd="$(resolve_nazgul_dir)"
  fi
  [ -d "$nd" ] || return 0
  (
    export NAZGUL_DIR="$nd"
    export EVENTS_FILE="$nd/logs/events.jsonl"
    # shellcheck source=./lib/emit-event.sh
    source "$SCRIPT_DIR/lib/emit-event.sh"
    emit_event "coverage_vacuous" \
      entry_point "lean-comments" \
      scanned:n "$SCANNED" \
      skipped:n "$((SKIP_EXT + SKIP_UNREADABLE))"
  )
}

# Mode 1: --check FILE [FILE...]
if [ "${1:-}" = "--check" ]; then
  shift
  CONFIG="${NAZGUL_CONFIG:-$(resolve_nazgul_dir)/config.json}"
  read -r STATE MAXRUN < <(resolve_config check "$CONFIG")
  if [ "$STATE" = "DISABLED" ]; then
    exit 0
  fi
  RC=0
  SCANNED=0
  CHECKED=0
  SKIP_EXT=0
  SKIP_UNREADABLE=0
  FINDINGS=0
  for f in "$@"; do
    SCANNED=$((SCANNED + 1))
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      SKIP_UNREADABLE=$((SKIP_UNREADABLE + 1))
      echo "lean-comments: skipped (unreadable, not checked): $f" >&2
      continue
    fi
    first=$(head -1 "$f" 2>/dev/null || echo "")
    style=$(comment_style_for "$f" "$first")
    if [ -z "$style" ]; then
      SKIP_EXT=$((SKIP_EXT + 1))
      continue
    fi
    hdr=0
    is_shell_source "$f" "$first" && hdr=1
    CHECKED=$((CHECKED + 1))
    if ! report_for_content "$style" "$MAXRUN" "$f" "$(cat "$f")" "$hdr"; then
      RC=2
    fi
    FINDINGS=$((FINDINGS + LAST_FINDING_COUNT))
  done

  # Advisory surface (TRD §6 / ADR-019 D4): the counts and the nothing-checked
  # signal are the product; the exit code stays clean-vs-violations only.
  if [ "$SCANNED" -ne $((SKIP_EXT + SKIP_UNREADABLE + CHECKED)) ]; then
    echo "lean-comments: INTERNAL — coverage accounting mismatch: $SCANNED scanned != $((SKIP_EXT + SKIP_UNREADABLE)) skipped + $CHECKED checked" >&2
  fi
  if [ "$CHECKED" -eq 0 ] && [ "$SCANNED" -gt 0 ]; then
    echo "lean-comments: NOTHING CHECKED — all $SCANNED candidates skipped" >&2
    emit_coverage_vacuous_event
  fi
  emit_coverage_line
  exit "$RC"
fi

# Mode 2: PreToolUse hook (stdin JSON)
INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
CONFIG="$(resolve_nazgul_dir)/config.json"
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
    CONTENT=""
    ;;
  *)
    exit 0
    ;;
esac

[ -z "$FILE_PATH" ] && exit 0
# Not `printf | head -1`: $CONTENT is the whole tool payload, and past the 64 KiB
# pipe buffer the producer's SIGPIPE aborted this always-blocking gate silently (#230).
FIRST_LINE=${CONTENT%%$'\n'*}
STYLE=$(comment_style_for "$FILE_PATH" "$FIRST_LINE")
[ -z "$STYLE" ] && exit 0
HDR=0
is_shell_source "$FILE_PATH" "$FIRST_LINE" && HDR=1

if [ "$TOOL_NAME" = "MultiEdit" ]; then
  # Evaluate each edit's new_string INDEPENDENTLY: joining them would flag
  # comment runs that never actually become contiguous in the file.
  RC=0
  EDIT_COUNT=$(echo "$INPUT" | jq -r '.tool_input.edits // [] | length' 2>/dev/null || echo 0)
  case "$EDIT_COUNT" in ''|*[!0-9]*) EDIT_COUNT=0 ;; esac
  idx=0
  while [ "$idx" -lt "$EDIT_COUNT" ]; do
    CONTENT=$(echo "$INPUT" | jq -r --argjson i "$idx" '.tool_input.edits[$i].new_string // ""' 2>/dev/null || echo "")
    if ! report_for_content "$STYLE" "$MAXRUN" "$FILE_PATH" "$CONTENT" "$HDR"; then
      RC=2
    fi
    idx=$((idx + 1))
  done
  exit "$RC"
fi

if ! report_for_content "$STYLE" "$MAXRUN" "$FILE_PATH" "$CONTENT" "$HDR"; then
  exit 2
fi
exit 0
