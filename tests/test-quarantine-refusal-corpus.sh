#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# lean-comments: allow-run — why this file exists at all is the whole argument, and it is the
# reason two hardening fixes shipped as regressions.
# A PINNED CORPUS of manifest spellings that must ALWAYS read as a live typed reconciliation
# quarantine. The recogniser has been narrowed FOUR times, twice by a change written to harden it.
# Each narrowing was verified against the ONE input its report named, went red then green, and
# shipped — because "drive it red on the reported case" proves a test can fail and says NOTHING
# about what the fix stopped catching. The regressions lived only in the DIFFERENCE between the old
# predicate and the new one, which no test compared.
# So the durable check is not old-vs-new (after a refactor there is no "old"): it is a set of shapes
# that MUST be refused. A consolidation that narrows the predicate turns this red whichever
# direction it narrowed in, and whatever it was trying to fix.
# ADDING ROWS IS THE POINT. Removing one requires an argument that the shape is genuinely not a
# quarantine — never that it is inconvenient.
TEST_NAME="test-quarantine-refusal-corpus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

# Each row: <label>|<manifest text>. Provenance is named so a reader can tell a real shape
# from a guess.
QC_ROWS=(
  "canonical|- **Blocked kind**: reconciliation"
  "two spaces after the dash (PATCH-007 item 9)|-  **Blocked kind**: reconciliation"
  "tab after the dash (same class, never reported)|-	**Blocked kind**: reconciliation"
  "indented two spaces (3rd pass item 4)|  - **Blocked kind**: reconciliation"
  "indented with a tab (same class)|	- **Blocked kind**: reconciliation"
  "second of two kind lines (3rd pass item 1 REGRESSION)|- **Blocked kind**: review-evidence
- **Blocked kind**: reconciliation"
  "reconciliation first, another kind after|- **Blocked kind**: reconciliation
- **Blocked kind**: review-evidence"
  "trailing whitespace after the value|- **Blocked kind**: reconciliation   "
  "uppercase field name|- **BLOCKED KIND**: reconciliation"
  "mixed case value|- **Blocked kind**: Reconciliation"
  "surrounded by other manifest fields|## Metadata
- **Status**: BLOCKED
- **Blocked kind**: reconciliation
- **Blocked from**: DONE"
)

QC_SCANNED=0; QC_CHECKED=0; QC_FINDINGS=0; QC_MISSED=""
for _row in "${QC_ROWS[@]}"; do
  QC_SCANNED=$((QC_SCANNED + 1)); QC_CHECKED=$((QC_CHECKED + 1))
  _label="${_row%%|*}"; _text="${_row#*|}"
  if ttg_is_reconciliation_quarantine "$_text"; then
    _pass "corpus: detected — $_label"
  else
    QC_FINDINGS=$((QC_FINDINGS + 1)); QC_MISSED="$QC_MISSED$_label; "
    _fail "corpus: detected — $_label" \
      "this spelling is a live typed reconciliation quarantine and the recogniser did not see it" \
      "  a record NOT seen costs the block itself — BLOCKED -> CANCELLED would be ADMITTED here"
  fi
done

# The counter-corpus: a predicate widened until it matches everything refuses nothing useful,
# so the set above is only meaningful beside this one.
QC_NEG=(
  "already repaired, so it cannot re-qualify|- **Blocked kind**: reconciliation (repaired 2026-08-24)"
  "a different kind entirely|- **Blocked kind**: review-evidence"
  "a different kind entirely (git conflict)|- **Blocked kind**: git-conflict"
  "the word inside prose, not a field|This task mentions reconciliation in its description."
  "field present but blanked|- **Blocked kind**:"
)
for _row in "${QC_NEG[@]}"; do
  QC_SCANNED=$((QC_SCANNED + 1)); QC_CHECKED=$((QC_CHECKED + 1))
  _label="${_row%%|*}"; _text="${_row#*|}"
  if ttg_is_reconciliation_quarantine "$_text"; then
    QC_FINDINGS=$((QC_FINDINGS + 1))
    _fail "counter-corpus: NOT detected — $_label" \
      "the recogniser matched a shape that is not a live typed reconciliation quarantine" \
      "  a predicate that matches everything refuses nothing"
  else
    _pass "counter-corpus: NOT detected — $_label"
  fi
done

# A floor, so a vanished recogniser cannot pass this file by checking nothing (RULES.md §15).
QC_FLOOR=12
if [ "$QC_CHECKED" -ge "$QC_FLOOR" ]; then
  _pass "corpus floor: the recogniser was actually exercised ($QC_CHECKED shapes >= $QC_FLOOR)"
else
  _fail "corpus floor: the recogniser was actually exercised" \
    "only $QC_CHECKED shape(s) driven — a shrunken corpus is a weakened gate, not a clean one"
fi

printf '  quarantine-corpus: %d scanned, 0 skipped, %d checked, %d findings\n' \
  "$QC_SCANNED" "$QC_CHECKED" "$QC_FINDINGS"
assert_eq "quarantine-corpus: scanned == skipped + checked" "$QC_SCANNED" "$((0 + QC_CHECKED))"
assert_eq "quarantine-corpus: every pinned spelling is still refused" "${QC_MISSED% }" ""

# lean-comments: allow-run — this half exists because the reader-only half could not see the
# defect that shipped, and the argument for it IS the finding.
# THE WRITER HALF. Everything above pins what the RECOGNISER must accept, which is half a contract.
# PATCH-008 widened the reader's anchor and left every WRITER of the same field matching column 0:
# `repair`'s awk left an INDENTED record byte-identical while printing `recorded`, and
# `set_manifest_field` APPENDED a second record the reader's `grep -m1` then read past. Every row
# above stayed green throughout — a reader-side corpus is structurally blind to a writer.
# So each spelling the reader accepts is driven through EVERY writer of the field, end to end,
# asserting the record was updated IN PLACE: the field's line count is unchanged (nothing was
# appended) and the reader's answer changed (the write actually landed).
source "$SCRIPT_DIR/lib/setup.sh"

QW_TAB=$'\t'
# Two denominators, never one: assertions driven through the writers, and files walked by the
# scan. Summing them would report a number that answers neither question, so each gets its own line.
QW_SCANNED=0; QW_CHECKED=0; QW_FINDINGS=0
QW_FSCANNED=0; QW_FSKIPPED=0; QW_FCHECKED=0; QW_FFINDINGS=0

qw_assert() { # <name> <actual> <expected>
  QW_SCANNED=$((QW_SCANNED + 1)); QW_CHECKED=$((QW_CHECKED + 1))
  if [ "$2" = "$3" ]; then
    _pass "$1"
  else
    QW_FINDINGS=$((QW_FINDINGS + 1))
    _fail "$1" "expected '$3', got '$2'"
  fi
}

qw_line() { # <prefix> <case> <field> <value> -> one manifest field line in that spelling
  local f="$3"
  [ "$2" != "upper" ] || f=$(printf '%s' "$f" | tr '[:lower:]' '[:upper:]')
  printf '%s**%s**: %s' "$1" "$f" "$4"
}

# Counted WITHOUT the anchor under test, so an anchor that stops matching cannot also stop counting.
qw_field_lines() { # <file> <field>
  grep -ci -- "\*\*$2\*\*:" "$1" 2>/dev/null || true
}

qw_run_hook() { bash "$REPO_ROOT/scripts/stop-hook.sh" </dev/null >/dev/null 2>&1 || true; }

qw_run_cmd() {
  QW_EC=0
  QW_OUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/task-transition.sh" "$@" 2>&1) || QW_EC=$?
}

# Reviewed and committed, with a file scope outside scripts/**, tests/** so the red-run gate
# resolves not-applicable and repair's five evidence checks all pass.
qw_reviewed_manifest() { # <task-id> <status> <base-sha> <head-sha>
  printf -- '---\nstatus: %s\n---\n# %s: Test task\n\n## Metadata\n- **Depends on**: none\n- **Group**: 1\n- **Retry count**: 0/3\n- **Files modified**: ["docs/foo.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n' \
    "$2" "$1" "$3" "$4"
}

# <label>|<line prefix>|<field-name case>. Every entry is asserted reader-accepted below, so a
# writer spelling can never drift ahead of the recogniser it is supposed to match.
QW_SPELLINGS=(
  "canonical|- |as-is"
  "two spaces after the dash (PATCH-007 item 9)|-  |as-is"
  "tab after the dash (same class)|-${QW_TAB}|as-is"
  "indented two spaces (PATCH-008 item 4)|  - |as-is"
  "indented with a tab (same class)|${QW_TAB}- |as-is"
  "uppercase field name|- |upper"
  "indented AND uppercase|  - |upper"
)

# "unset" and "clean" are different answers, so the empty case is named rather than passing as
# backslash-free: a tree with no ERE form at all has not satisfied this, it has skipped it.
QW_ERE="${NZ_MANIFEST_FIELD_ANCHOR_ERE:-}"
if [ -z "$QW_ERE" ]; then
  QW_ERE_STATE="no ERE form defined"
else
  case "$QW_ERE" in
    *\\*) QW_ERE_STATE="backslash-survived" ;;
    *)   QW_ERE_STATE="clean" ;;
  esac
fi
qw_assert "writer anchor: the ERE transliteration exists and leaves no backslash" "$QW_ERE_STATE" "clean"

for _s in "${QW_SPELLINGS[@]}"; do
  IFS='|' read -r _lbl _pfx _case <<< "$_s"
  _text=$(qw_line "$_pfx" "$_case" "Blocked kind" "reconciliation")
  if ttg_is_reconciliation_quarantine "$_text"; then _seen="accepted"; else _seen="rejected"; fi
  qw_assert "writer corpus is bound to the reader: $_lbl" "$_seen" "accepted"
done

if [ "${#QW_SPELLINGS[@]}" -ge 5 ]; then
  qw_assert "writer corpus floor: enough spellings to discriminate" "ok" "ok"
else
  qw_assert "writer corpus floor: enough spellings to discriminate" "${#QW_SPELLINGS[@]}" ">=5"
fi

# WRITER A — task-transition.sh's repair awk, one quarantine fixture re-spelled per row.
# nz_rewrite_file exits 0 on a NO-OP, so a pattern that misses reports `recorded` over nothing.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_review_dir "TASK-001"
QW_MF="$TEST_DIR/nazgul/tasks/TASK-001.md"
QW_BASE=$(git -C "$TEST_DIR" rev-parse HEAD~1)
QW_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
qw_reviewed_manifest TASK-001 IN_REVIEW "$QW_BASE" "$QW_HEAD" > "$QW_MF"
qw_run_hook
sed -i.bak 's/^status: IN_REVIEW/status: DONE/' "$QW_MF" && rm -f "$QW_MF.bak"
qw_run_hook
QW_QUARANTINED=$(cat "$QW_MF")
if ttg_is_reconciliation_quarantine "$QW_QUARANTINED"; then _fix="live"; else _fix="none"; fi
qw_assert "writer A fixture: the hook really left a live quarantine at BLOCKED" \
  "$(get_task_status "$QW_MF" "")/$_fix" "BLOCKED/live"

for _s in "${QW_SPELLINGS[@]}"; do
  IFS='|' read -r _lbl _pfx _case <<< "$_s"
  QW_SPELLED=$(qw_line "$_pfx" "$_case" "Blocked kind" "reconciliation")
  printf '%s\n' "$QW_QUARANTINED" | QW_LINE="$QW_SPELLED" awk \
    '/^- \*\*Blocked kind\*\*: reconciliation$/ { print ENVIRON["QW_LINE"]; next } { print }' > "$QW_MF"
  if grep -qF -- "$QW_SPELLED" "$QW_MF"; then _hit="present"; else _hit="absent"; fi
  qw_assert "writer A fixture really carries the spelling — $_lbl" "$_hit" "present"
  QW_BEFORE=$(qw_field_lines "$QW_MF" "Blocked kind")
  qw_run_cmd repair TASK-001
  qw_assert "writer A (repair): completes — $_lbl" "$QW_EC" "0"
  qw_assert "writer A (repair): the record is updated in place, never appended beside — $_lbl" \
    "$(qw_field_lines "$QW_MF" "Blocked kind")" "$QW_BEFORE"
  if ttg_is_reconciliation_quarantine "$(cat "$QW_MF")"; then _q="live"; else _q="repaired"; fi
  qw_assert "writer A (repair): the repaired marker actually landed — $_lbl" "$_q" "repaired"
done
teardown_temp_dir

# WRITER B — stop-hook.sh's set_manifest_field, via the reconciliation quarantine that calls it.
# The seeded record carries a DIFFERENT kind, so an append shows up twice: a second line, a stale read.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_review_dir "TASK-001"
QW_MF="$TEST_DIR/nazgul/tasks/TASK-001.md"
QW_BASE=$(git -C "$TEST_DIR" rev-parse HEAD~1)
QW_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
QW_IN_REVIEW=$(qw_reviewed_manifest TASK-001 IN_REVIEW "$QW_BASE" "$QW_HEAD")
printf '%s\n' "$QW_IN_REVIEW" > "$QW_MF"
qw_run_hook

for _s in "${QW_SPELLINGS[@]}"; do
  IFS='|' read -r _lbl _pfx _case <<< "$_s"
  {
    printf '%s\n' "$QW_IN_REVIEW"
    qw_line "$_pfx" "$_case" "Blocked kind" "git-conflict"; printf '\n'
    qw_line "$_pfx" "$_case" "Blocked reason" "a stale git-conflict reason"; printf '\n'
  } > "$QW_MF"
  sed -i.bak 's/^status: IN_REVIEW/status: DONE/' "$QW_MF" && rm -f "$QW_MF.bak"
  QW_BEFORE_KIND=$(qw_field_lines "$QW_MF" "Blocked kind")
  QW_BEFORE_REASON=$(qw_field_lines "$QW_MF" "Blocked reason")
  qw_assert "writer B fixture: exactly one seeded kind record — $_lbl" "$QW_BEFORE_KIND" "1"
  qw_run_hook
  qw_assert "writer B (set_manifest_field): 'Blocked kind' updated in place — $_lbl" \
    "$(qw_field_lines "$QW_MF" "Blocked kind")" "$QW_BEFORE_KIND"
  qw_assert "writer B (set_manifest_field): 'Blocked reason' updated in place — $_lbl" \
    "$(qw_field_lines "$QW_MF" "Blocked reason")" "$QW_BEFORE_REASON"
  qw_assert "writer B (set_manifest_field): the reader sees the NEW kind, not the stale one — $_lbl" \
    "$(ttg_manifest_field "$(cat "$QW_MF")" "Blocked kind")" "reconciliation"
done
teardown_temp_dir

# WRITER C — ttg_apply_transition's `Blocked reason` upsert. The third writer of the same field,
# and the one re-review #4 did not name.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
QW_MF="$TEST_DIR/nazgul/tasks/TASK-001.md"
for _s in "${QW_SPELLINGS[@]}"; do
  IFS='|' read -r _lbl _pfx _case <<< "$_s"
  create_task_file "TASK-001" "IN_PROGRESS"
  { qw_line "$_pfx" "$_case" "Blocked reason" "a stale reason"; printf '\n'; } >> "$QW_MF"
  QW_BEFORE=$(qw_field_lines "$QW_MF" "Blocked reason")
  qw_assert "writer C fixture: exactly one seeded reason record — $_lbl" "$QW_BEFORE" "1"
  qw_run_cmd transition TASK-001 IN_PROGRESS BLOCKED --reason "the fresh reason"
  qw_assert "writer C (ttg_apply_transition): completes — $_lbl" "$QW_EC" "0"
  qw_assert "writer C (ttg_apply_transition): 'Blocked reason' updated in place — $_lbl" \
    "$(qw_field_lines "$QW_MF" "Blocked reason")" "$QW_BEFORE"
  qw_assert "writer C (ttg_apply_transition): the reader sees the NEW reason — $_lbl" \
    "$(ttg_manifest_field "$(cat "$QW_MF")" "Blocked reason")" "the fresh reason"
done
teardown_temp_dir

# lean-comments: allow-run — the scope of this scan is a decision, and it is recorded here.
# The behavioural half above can only drive the writers that exist TODAY. This half is the
# structural one: no script may hand-spell an anchor for a field the SHARED reader reads. The
# label set is DERIVED from the reader's own call sites rather than hand-listed, so a new
# quarantine field is covered the day it is introduced — and a derivation that collapses to
# nothing is itself a finding (the floor below).
QW_LABELS=$( {
    grep -rhoE '(ttg_manifest_field|_tsg_q_value)[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"' "$REPO_ROOT/scripts" \
      | sed -E 's/.*"([^"]*)"$/\1/'
    grep -rhoE 'MANIFEST_FIELD_ANCHOR\}[A-Za-z][A-Za-z ]*' "$REPO_ROOT/scripts" \
      | sed -E 's/^MANIFEST_FIELD_ANCHOR\}//'
  } | grep -v '^\$' | sed 's/[[:space:]]*$//' | grep -vE '^$' | sort -u )
QW_LABEL_N=$(printf '%s\n' "$QW_LABELS" | grep -cE '.' || true)

# `^`, optionally backslash-escaped, a dash, whitespace literal or class, then an asterisk pair in
# either dialect — tight enough that `^---` frontmatter and `^-[A-Za-z]` option matching stay out.
QW_ANCHOR_RE='\^\\?-([[:space:]]|\\[[:space:]]|\[\[:space:\]\]\*)*(\\\*\\\*|\[\*\]\[\*\])'
QW_HANDSPELLED=""
QW_RESIDUAL=0
while IFS= read -r _f; do
  QW_FSCANNED=$((QW_FSCANNED + 1))
  if ! head -1 "$_f" 2>/dev/null | grep -q '^#!'; then
    QW_FSKIPPED=$((QW_FSKIPPED + 1))
    continue
  fi
  QW_FCHECKED=$((QW_FCHECKED + 1))
  _hits=$(grep -nE "$QW_ANCHOR_RE" "$_f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  [ -n "$_hits" ] || continue
  while IFS= read -r _hit; do
    [ -n "$_hit" ] || continue
    _owned=""
    while IFS= read -r _lbl; do
      [ -n "$_lbl" ] || continue
      case "$_hit" in *"$_lbl"*) _owned="$_lbl" ;; esac
    done <<< "$QW_LABELS"
    if [ -n "$_owned" ]; then
      QW_FFINDINGS=$((QW_FFINDINGS + 1))
      QW_HANDSPELLED="$QW_HANDSPELLED${_f#"$REPO_ROOT/"}:${_hit%%:*}; "
      _fail "writer anchor: nothing hand-spells an anchor for '$_owned'" \
        "${_f#"$REPO_ROOT/"}:${_hit%%:*} pins the dash to column 0 for a field the reader reads tolerantly" \
        "  take the pattern from nz_manifest_field_pattern_ere so reader and writer cannot drift"
    else
      QW_RESIDUAL=$((QW_RESIDUAL + 1))
    fi
  done <<< "$_hits"
done < <(find "$REPO_ROOT/scripts" -type f | sort)

qw_assert "writer anchor: no hand-spelled anchor survives for any field the shared reader reads" \
  "${QW_HANDSPELLED% }" ""
if [ "$QW_LABEL_N" -ge 3 ]; then
  qw_assert "writer anchor: the label set was actually derived" "ok" "ok"
else
  qw_assert "writer anchor: the label set was actually derived" \
    "$QW_LABEL_N labels" ">=3 labels"
fi

# lean-comments: allow-run — this closes a hole the scan above cannot reach, and says why.
# The label-derived scan can only see a HAND-SPELLED label. `set_manifest_field` interpolates
# `${label}`, so its column-0 anchor carried no literal field name and was invisible to that scan
# while it WAS the live defect (re-review #4 item 4). Every function that builds a manifest field
# line under a variable label is therefore derived from the construction itself and bound directly:
# its body must take its match pattern from the shared builder.
QW_CONSTRUCT_RE='\-[[:space:]]\*\*(\$\{[A-Za-z_][A-Za-z0-9_]*\}|%s)\*\*:'
QW_VAR_UNITS=""
while IFS= read -r _f; do
  head -1 "$_f" 2>/dev/null | grep -q '^#!' || continue
  _lines=$(grep -nE "$QW_CONSTRUCT_RE" "$_f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1 || true)
  [ -n "$_lines" ] || continue
  while IFS= read -r _ln; do
    [ -n "$_ln" ] || continue
    _fn=$(awk -v target="$_ln" \
      '/^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { fn = $0; sub(/\(\).*/, "", fn) } NR == target { print fn; exit }' \
      "$_f")
    [ -n "$_fn" ] || _fn="(file scope)"
    case $'\n'"$QW_VAR_UNITS"$'\n' in *$'\n'"${_f}#${_fn}"$'\n'*) continue ;; esac
    QW_VAR_UNITS="${QW_VAR_UNITS:+$QW_VAR_UNITS$'\n'}${_f}#${_fn}"
  done <<< "$_lines"
done < <(find "$REPO_ROOT/scripts" -type f | sort)

QW_VAR_N=0
while IFS= read -r _unit; do
  [ -n "$_unit" ] || continue
  _f="${_unit%%#*}"; _fn="${_unit#*#}"
  QW_VAR_N=$((QW_VAR_N + 1))
  if [ "$_fn" = "(file scope)" ]; then
    _body=$(cat "$_f")
  else
    _body=$(awk -v fn="$_fn" \
      '$0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { inside = 1 } inside { print } inside && /^\}$/ { exit }' "$_f")
  fi
  if [ -z "$_body" ]; then
    qw_assert "writer binding: $_fn is extractable from ${_f#"$REPO_ROOT/"}" "empty" "non-empty"
  elif printf '%s\n' "$_body" | grep -q 'nz_manifest_field_pattern_ere'; then
    qw_assert "writer binding: $_fn takes its pattern from the shared builder" "bound" "bound"
  else
    qw_assert "writer binding: $_fn takes its pattern from the shared builder" \
      "hand-spelled in ${_f#"$REPO_ROOT/"}" "bound"
  fi
done <<< "$QW_VAR_UNITS"
if [ "$QW_VAR_N" -ge 1 ]; then
  qw_assert "writer binding: the variable-label writer set was actually derived" "ok" "ok"
else
  qw_assert "writer binding: the variable-label writer set was actually derived" "0 units" ">=1 unit"
fi

# lean-comments: allow-run — what this file does NOT close, counted rather than left unsaid.
# The scan above is bounded to the labels the SHARED reader reads. Every OTHER `- **Field**:`
# label in this codebase — `Retry count`, `ID`, `PR`, `Depends on`, `Status`, `Group`, the
# learned-rules document's own fields, and plan.md's Recovery Pointer family — is still read
# through a per-site hand-spelled column-0 anchor, and consolidating those is a separate unit of
# work with its own cost argument per field. Pinning the count is what stops that residual growing
# quietly: a NEW hand-spelling anywhere under scripts/ turns this red, and fixing one is a
# deliberate edit here rather than a silent drift. 27 -> 26 (#282): TASK-008 folded the `Status`
# and `Retry count` hand-spellings in task-utils.sh into one awk match, so the residual shrank.
QW_RESIDUAL_PIN=26
qw_assert "residual census: hand-spelled anchors for labels outside the shared reader" \
  "$QW_RESIDUAL" "$QW_RESIDUAL_PIN"

if [ "$QW_FCHECKED" -ge 20 ]; then
  qw_assert "writer scan floor: the scan really walked this codebase" "ok" "ok"
else
  qw_assert "writer scan floor: the scan really walked this codebase" "$QW_FCHECKED files" ">=20 files"
fi

printf '  quarantine-writer-drive: %d scanned, 0 skipped, %d checked, %d findings\n' \
  "$QW_SCANNED" "$QW_CHECKED" "$QW_FINDINGS"
assert_eq "writer drive: scanned == skipped + checked" "$QW_SCANNED" "$((0 + QW_CHECKED))"
printf '  quarantine-writer-scan: %d scanned, %d skipped (no-shebang=%d), %d checked, %d findings\n' \
  "$QW_FSCANNED" "$QW_FSKIPPED" "$QW_FSKIPPED" "$QW_FCHECKED" "$QW_FFINDINGS"
assert_eq "writer scan: scanned == skipped + checked" "$QW_FSCANNED" "$((QW_FSKIPPED + QW_FCHECKED))"


report_results
