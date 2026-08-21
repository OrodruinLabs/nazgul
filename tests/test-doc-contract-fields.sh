#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# Test: every count the documents state about the merge-evidence gate and about RULES.md §15's
# registry is DERIVED from the mechanism that enforces it, the document population included.
TEST_NAME="test-doc-contract-fields"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/rules-registry.sh"

echo "=== $TEST_NAME ==="

CONST_NAME="_TTG_MERGE_REQUIRED_FIELDS"
REGION_MARKER="## Merge Evidence"
# Both sources are injectable, and independently: a forced all-skip run still derives the real
# contract it fails to find documented, and a mutated constant can be aimed at either tree.
GUARD_LIB="${NAZGUL_DOC_CONTRACT_GUARD_LIB:-$REPO_ROOT/scripts/lib/task-transition-guard.sh}"
DOC_ROOT="${NAZGUL_DOC_CONTRACT_DOC_ROOT:-$REPO_ROOT}"
MP_LIB="${NAZGUL_DOC_CONTRACT_MP_LIB:-$REPO_ROOT/scripts/lib/merge-provider.sh}"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doc-contract-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

FAMILIES="field fieldcount reason reasoncount regcount ordinal tier suite mpresult mpresultcount mpevent mpeventcount"

_derive_fields() {
  # shellcheck disable=SC1090  # the source of truth is a parameter: that is the point
  ( . "$1" >/dev/null 2>&1; printf '%s' "${_TTG_MERGE_REQUIRED_FIELDS:-}" )
}

# The vocabulary is the set of reasons the gate can actually emit, read off its deny call
# sites the way tests/test-red-run-evidence.sh reads the red-run one.
_derive_reasons() {
  grep -oE '_ttg_merge_deny "[^"]*" "[^"]*" "[a-z_]+"' "$1" 2>/dev/null \
    | sed -E 's/.*"([a-z_]+)"$/\1/' | LC_ALL=C sort -u
}

# The merge-observation seam's two vocabularies, read off its OWN call sites the same way
# _derive_reasons reads the gate's. TASK-020 widened both (adding repo_mismatch and
# unbindable_repo) to close a HIGH security defect, and three documents kept the pre-widening
# counts because nothing bound them. Deriving them is what stops that from recurring.
_derive_mp_results() {
  grep -oE '_mp_result ("[^"]*"|\$[A-Za-z_][A-Za-z_0-9]*) ("[^"]*"|\$[A-Za-z_][A-Za-z_0-9]*) ("[^"]*"|\$[A-Za-z_][A-Za-z_0-9]*) "[a-z_]+"' "$1" 2>/dev/null \
    | sed -E 's/.*"([a-z_]+)"$/\1/' | LC_ALL=C sort -u
}

_derive_mp_events() {
  grep -oE '_mp_emit "[^"]*" "merge_provider_[a-z_]+"' "$1" 2>/dev/null \
    | sed -E 's/.*"(merge_provider_[a-z_]+)"$/\1/' | LC_ALL=C sort -u
}

_derive_driver() {
  _registry_bullet "$1" | tr '\n' ' ' | tr -s ' ' \
    | grep -oE '`[^`]+` drives every one of them' | sed -E 's/^`([^`]+)`.*/\1/'
}

_derive_registry_members() {
  # shellcheck disable=SC2034  # read by tests/lib/rules-registry.sh, not within this file
  REGISTRY_DRIVER_REL="$(_derive_driver "$1")"
  _registry_members "$1"
}

_derive_tiers() {
  awk '{ e += gsub(/\[enforced\]/, ""); a += gsub(/\[advisory\]/, "")
         h += gsub(/\[hook-driven only\]/, "") }
       END { printf "%d %d %d\n", e, a, h }' "$1" 2>/dev/null
}

# An English count word (cardinal or ordinal) or a bare integer, as an integer; empty when it
# is neither, which the callers treat as a finding rather than as a skip.
_num() {
  local w
  w=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$w" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$w"; return 0 ;;
  esac
  case "$w" in
    one|first) echo 1 ;;            two|second) echo 2 ;;
    three|third) echo 3 ;;          four|fourth) echo 4 ;;
    five|fifth) echo 5 ;;           six|sixth) echo 6 ;;
    seven|seventh) echo 7 ;;        eight|eighth) echo 8 ;;
    nine|ninth) echo 9 ;;           ten|tenth) echo 10 ;;
    eleven|eleventh) echo 11 ;;     twelve|twelfth) echo 12 ;;
    thirteen|thirteenth) echo 13 ;; fourteen|fourteenth) echo 14 ;;
    fifteen|fifteenth) echo 15 ;;   sixteen|sixteenth) echo 16 ;;
    seventeen|seventeenth) echo 17 ;; eighteen|eighteenth) echo 18 ;;
    nineteen|nineteenth) echo 19 ;; twenty|twentieth) echo 20 ;;
    *) echo "" ;;
  esac
}

# A release-noted document is checked in its NEWEST section only: older entries are frozen
# records of what was true when they shipped, and rewriting those would be the lie.
_live_region() {
  if grep -qE '^## \[' "$1"; then
    awk '/^## \[/ { n++ } n == 1 { print } n > 1 { exit }' "$1"
  else
    cat "$1"
  fi
}

_flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

# One claim's number token out of a region; empty when the document makes no such claim.
_claim_word() {
  grep -oiE "$2" <<< "$1" | awk 'NR==1 { print $1 }'
}

_token_in() {
  grep -qE "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|$)" <<< "$2"
}

# Best region = the marker-bearing paragraph naming the most fields. One passage must teach
# the whole list; a field scattered across unrelated paragraphs is not a lesson.
_best_merge_block() {
  local region="$1" dir="$2" n best="" hits high=-1 i f
  mkdir -p "$dir"
  printf '%s\n' "$region" > "$dir/region"
  n=$(awk -v outdir="$dir" -v marker="$REGION_MARKER" '
    BEGIN { RS = ""; n = 0 }
    index($0, marker) > 0 { n++; printf "%s\n", $0 > (outdir "/block-" n) }
    END { print n + 0 }' "$dir/region")
  i=1
  while [ "$i" -le "$n" ]; do
    hits=0
    for f in $FIELDS; do
      _token_in "$f" "$(cat "$dir/block-$i")" && hits=$((hits + 1))
    done
    if [ "$hits" -gt "$high" ]; then high="$hits"; best="$dir/block-$i"; fi
    i=$((i + 1))
  done
  [ -n "$best" ] && cat "$best"
}

BIND_MODE="report"

_check() {
  local family="$1" ok="$2" label="$3" detail="${4:-}"
  CHECKED=$((CHECKED + 1))
  eval "CK_${family}=\$((CK_${family} + 1))"
  if [ "$ok" = "0" ]; then
    [ "$BIND_MODE" = "report" ] && _pass "$label"
    return 0
  fi
  FINDINGS=$((FINDINGS + 1))
  eval "FD_${family}=\$((FD_${family} + 1))"
  [ "$BIND_MODE" = "report" ] && _fail "$label" "$detail"
  return 0
}

_no_claim() {
  SKIP_NO_CLAIM=$((SKIP_NO_CLAIM + $1))
}

_check_count_claim() {
  local family="$1" doc="$2" text="$3" re="$4" want="$5" noun="$6" word got
  SCANNED=$((SCANNED + 1))
  word=$(_claim_word "$text" "$re")
  if [ -z "$word" ]; then
    _no_claim 1
    return 0
  fi
  got=$(_num "$word")
  if [ -z "$got" ]; then
    _check "$family" 1 "$doc: its $noun count is a number this test can read" \
      "'$word' is neither an integer nor an English count word — an unreadable claim is not a checked one"
  elif [ "$got" = "$want" ]; then
    _check "$family" 0 "$doc: states $want $noun, the number derived from the mechanism"
  else
    _check "$family" 1 "$doc: states the derived $noun count" \
      "document says $got ('$word'), the mechanism yields $want"
  fi
}

_check_tier() {
  local doc="$1" claimed="$2" pos="$3" want="$4" tier="$5" got
  got=$(_num "$(awk -v p="$pos" '{ print $p }' <<< "$claimed")")
  if [ "$got" = "$want" ]; then
    _check tier 0 "$doc: states $want [$tier] rules, the count derived from RULES.md's tags"
  else
    _check tier 1 "$doc: states the derived [$tier] rule count" \
      "document says '${got:-unreadable}', RULES.md carries $want"
  fi
}

# _scan_docs <name-root> <content-root> <guard-lib> — names from the tree, content from the
# separately injectable doc root, contract values from the guard library and RULES.md.
_scan_docs() {
  local name_root="$1" content_root="$2" guard_lib="$3"
  local doc path region flat passage pflat f r fam fam_n word got idx ord tiers claimed per_doc

  FIELDS=$(_derive_fields "$guard_lib")
  REASONS=$(_derive_reasons "$guard_lib")
  MP_RESULTS=$(_derive_mp_results "$MP_LIB")
  MP_EVENTS=$(_derive_mp_events "$MP_LIB")
  MEMBERS=$(_derive_registry_members "$content_root/RULES.md" 2>/dev/null)
  FIELD_N=$(printf '%s\n' "$FIELDS" | tr ' ' '\n' | grep -c '[^[:space:]]' || true)
  REASON_N=$(printf '%s\n' "$REASONS" | grep -c '[^[:space:]]' || true)
  MP_RESULT_N=$(printf '%s\n' "$MP_RESULTS" | grep -c '[^[:space:]]' || true)
  MP_EVENT_N=$(printf '%s\n' "$MP_EVENTS" | grep -c '[^[:space:]]' || true)
  MEMBER_N=$(printf '%s\n' "$MEMBERS" | grep -c '[^[:space:]]' || true)
  SUITE_N=$(find "$name_root/tests" -maxdepth 1 -type f -name 'test-*.sh' 2>/dev/null | grep -c . || true)
  tiers=$(_derive_tiers "$content_root/RULES.md")
  TIER_E=$(awk '{ print $1 + 0 }' <<< "$tiers")
  TIER_A=$(awk '{ print $2 + 0 }' <<< "$tiers")
  TIER_H=$(awk '{ print $3 + 0 }' <<< "$tiers")

  SCANNED=0; SKIP_UNREADABLE=0; SKIP_NO_CLAIM=0; CHECKED=0; FINDINGS=0
  for fam in $FAMILIES; do eval "CK_${fam}=0; FD_${fam}=0"; done

  # Population = the repo-root documents PLUS the live reference docs one level under docs/.
  # docs/superpowers/** is deliberately excluded and the exclusion is stated rather than
  # discovered: those are DATED plans, specs and research whose counts were true at authorship,
  # so binding them would demand falsifying a historical record. Board 7 found the previous
  # -maxdepth 1 population "tree-derived in form, scope-authored in effect" — it could not see
  # docs/CONFIGURATION.md, the one file carrying the stale counts. Paths stay relative to the
  # name root so a doc in a subdirectory addresses correctly against the content root.
  DOC_NAMES=$( { find "$name_root" -maxdepth 1 -type f -name '*.md'
                 find "$name_root/docs" -maxdepth 1 -type f -name '*.md'; } 2>/dev/null \
    | sed "s|^$name_root/||" | LC_ALL=C sort)
  DOC_N=$(printf '%s\n' "$DOC_NAMES" | grep -c '[^[:space:]]' || true)
  per_doc=$((FIELD_N + REASON_N + MP_RESULT_N + MP_EVENT_N + 10))

  for doc in $DOC_NAMES; do
    path="$content_root/$doc"
    if [ ! -r "$path" ]; then
      SCANNED=$((SCANNED + per_doc))
      SKIP_UNREADABLE=$((SKIP_UNREADABLE + per_doc))
      [ "$BIND_MODE" = "report" ] && _skip "$doc: unreadable — its $per_doc bindings were not checked"
      continue
    fi
    region=$(_live_region "$path")
    flat=$(_flat "$region")
    passage=$(_best_merge_block "$region" "$SCRATCH/$(printf '%s' "$doc" | tr '/.' '__')")
    pflat=$(_flat "$passage")

    if [ -z "$passage" ]; then
      SCANNED=$((SCANNED + FIELD_N + REASON_N + 2))
      _no_claim $((FIELD_N + REASON_N + 2))
    else
      for f in $FIELDS; do
        SCANNED=$((SCANNED + 1))
        if _token_in "$f" "$passage"; then
          _check field 0 "$doc documents merge-evidence field '$f'"
        else
          _check field 1 "$doc documents merge-evidence field '$f'" \
            "'$f' is in $CONST_NAME but absent from $doc's '$REGION_MARKER' passage"
        fi
      done
      _check_count_claim fieldcount "$doc" "$pflat" '[A-Za-z0-9]+ fields under that' \
        "$FIELD_N" "merge-evidence field"
      claimed=$(_claim_word "$pflat" '[A-Za-z0-9]+ closed refusal reasons')
      for r in $REASONS; do
        SCANNED=$((SCANNED + 1))
        if [ -z "$claimed" ]; then
          _no_claim 1
        elif _token_in "$r" "$passage"; then
          _check reason 0 "$doc names refusal reason '$r'"
        else
          _check reason 1 "$doc names refusal reason '$r'" \
            "the document states the vocabulary's size but omits '$r', which the gate emits"
        fi
      done
      _check_count_claim reasoncount "$doc" "$pflat" '[A-Za-z0-9]+ closed refusal reasons' \
        "$REASON_N" "closed refusal reason"
    fi

    _check_count_claim regcount "$doc" "$flat" '[A-Za-z0-9]+ entry points are bound' \
      "$MEMBER_N" "§15 registry member"
    _check_count_claim suite "$doc" "$flat" '[A-Za-z0-9]+ files, all green' \
      "$SUITE_N" "discovered root suite"

    claimed=$(_claim_word "$flat" '[A-Za-z0-9]+ named results')
    for r in $MP_RESULTS; do
      SCANNED=$((SCANNED + 1))
      if [ -z "$claimed" ]; then
        _no_claim 1
      elif _token_in "$r" "$flat"; then
        _check mpresult 0 "$doc names merge-provider result '$r'"
      else
        _check mpresult 1 "$doc names merge-provider result '$r'" \
          "the document states the result vocabulary's size but omits '$r', which the seam returns"
      fi
    done
    _check_count_claim mpresultcount "$doc" "$flat" '[A-Za-z0-9]+ named results' \
      "$MP_RESULT_N" "merge-provider result"

    claimed=$(_claim_word "$flat" '[A-Za-z0-9]+ additive event types')
    for r in $MP_EVENTS; do
      SCANNED=$((SCANNED + 1))
      if [ -z "$claimed" ]; then
        _no_claim 1
      elif _token_in "$r" "$flat"; then
        _check mpevent 0 "$doc names merge-provider event '$r'"
      else
        _check mpevent 1 "$doc names merge-provider event '$r'" \
          "the document states the event vocabulary's size but omits '$r', which the seam emits"
      fi
    done
    _check_count_claim mpeventcount "$doc" "$flat" '[A-Za-z0-9]+ additive event types' \
      "$MP_EVENT_N" "merge-provider event"

    if [ -z "$(_registry_bullet "$path")" ]; then
      SCANNED=$((SCANNED + 1))
      _no_claim 1
    else
      while IFS= read -r ord; do
        [ -n "$ord" ] || continue
        SCANNED=$((SCANNED + 1))
        word=$(sed -E 's/^[Tt]he ([A-Za-z0-9]+) is .*/\1/' <<< "$ord")
        f=$(sed -E 's/^.*`([^`]+)`.*/\1/' <<< "$ord")
        idx=$(printf '%s\n' "$MEMBERS" | grep -nxF "$f" | cut -d: -f1)
        got=$(_num "$word")
        if [ -z "$idx" ]; then
          _check ordinal 1 "$doc: '$ord' names a registry member" \
            "'$f' is not in the member list derived from the registry bullet"
        elif [ "$got" = "$idx" ]; then
          _check ordinal 0 "$doc: '$f' is registry member $idx, as stated"
        else
          _check ordinal 1 "$doc: '$f' is stated at the position the registry puts it" \
            "document says $got ('$word'), the derived list puts it at $idx"
        fi
      done <<< "$(_flat "$(_registry_bullet "$path")" | grep -oE '[Tt]he [A-Za-z0-9]+ is `[^`]+`')"
    fi

    SCANNED=$((SCANNED + 3))
    claimed=$(grep -oiE '[A-Za-z0-9]+ enforced / [A-Za-z0-9]+ advisory / [A-Za-z0-9]+ hook-driven only' <<< "$flat" | awk 'NR==1')
    if [ -z "$claimed" ]; then
      _no_claim 3
    else
      _check_tier "$doc" "$claimed" 1 "$TIER_E" enforced
      _check_tier "$doc" "$claimed" 4 "$TIER_A" advisory
      _check_tier "$doc" "$claimed" 7 "$TIER_H" "hook-driven only"
    fi
  done
}

_emit_coverage() {
  printf '%s: %d scanned, %d skipped (unreadable=%d, no-claim=%d), %d checked, %d findings\n' \
    "$TEST_NAME" "$SCANNED" "$((SKIP_UNREADABLE + SKIP_NO_CLAIM))" \
    "$SKIP_UNREADABLE" "$SKIP_NO_CLAIM" "$CHECKED" "$FINDINGS"
}

if [ ! -r "$GUARD_LIB" ]; then
  SCANNED=0; SKIP_UNREADABLE=0; SKIP_NO_CLAIM=0; CHECKED=0; FINDINGS=0
  _fail "the gate library is readable" "not readable: $GUARD_LIB"
  echo "$TEST_NAME: NOTHING CHECKED — the gate library is unreadable, so no contract exists to bind" >&2
  report_results
  _emit_coverage
  exit 1
fi

ASSIGNMENTS=$(grep -cE "^${CONST_NAME}=" "$GUARD_LIB")
assert_eq "${CONST_NAME} has exactly one top-level assignment in $(basename "$GUARD_LIB")" \
  "$ASSIGNMENTS" "1"

_scan_docs "$REPO_ROOT" "$DOC_ROOT" "$GUARD_LIB"

if [ -z "$FIELDS" ] || [ -z "$REASONS" ] || [ -z "$MP_RESULTS" ] || [ -z "$MP_EVENTS" ]; then
  _fail "the merge contract is derived from the gate library" \
    "fields='$FIELDS' reasons='$(printf '%s' "$REASONS" | tr '\n' ' ')' mp_results='$(printf '%s' "$MP_RESULTS" | tr '\n' ' ')' mp_events='$(printf '%s' "$MP_EVENTS" | tr '\n' ' ')'" \
    "the contract could not be derived — this is 'never looked', not 'looked and found none'"
  echo "$TEST_NAME: NOTHING CHECKED — the gate library yielded no contract to bind" >&2
  report_results
  _emit_coverage
  exit 1
fi
_pass "the merge contract is derived from the gate library ($FIELD_N fields, $REASON_N refusal reasons)"
_pass "the merge-observation seam's vocabularies are derived from its own call sites ($MP_RESULT_N results, $MP_EVENT_N events)"
_pass "the §15 registry is derived from RULES.md's own bullet ($MEMBER_N members)"

DOC_FLOOR=2
if [ "$DOC_N" -ge "$DOC_FLOOR" ]; then
  _pass "the document population was derived from the tree ($DOC_N documents >= $DOC_FLOOR)"
else
  _fail "the document population was derived from the tree" \
    "found $DOC_N document(s) under $REPO_ROOT — an enumerator that finds nothing is 'never looked'"
fi

assert_eq "$TEST_NAME: N == M + K" "$SCANNED" "$((SKIP_UNREADABLE + SKIP_NO_CLAIM + CHECKED))"

if [ "$CHECKED" -eq 0 ]; then
  if [ "$SCANNED" -eq 0 ]; then
    echo "$TEST_NAME: NOTHING CHECKED — no bindings discovered under $REPO_ROOT" >&2
    _fail "the enumerator produced at least one binding" \
      "zero candidates — a broken enumerator, not a fully documented contract"
  else
    echo "$TEST_NAME: NOTHING CHECKED — all $SCANNED candidates skipped" >&2
    _fail "at least one document was readable enough to bind a claim to" \
      "all $SCANNED candidate bindings skipped under $DOC_ROOT"
  fi
elif [ "$DOC_ROOT" = "$REPO_ROOT" ]; then
  # A claim family no document exercises is a regex that stopped matching, which would
  # otherwise report a clean run over a claim nobody checked.
  for fam in $FAMILIES; do
    eval "fam_n=\$CK_${fam}"
    if [ "$fam_n" -ge 1 ]; then
      _pass "claim family '$fam' was actually checked ($fam_n bindings)"
    else
      _fail "claim family '$fam' was actually checked" \
        "no shipped document exercised it — every candidate fell into no-claim"
    fi
  done
fi

SHIPPED_LINE=$(_emit_coverage)
SHIPPED_FINDINGS="$FINDINGS"

# Mutation, both directions, through the same scan. B1/B2 (TASK-016/017) mutate the registry
# and ask whether a member has a driver; these mutate the SOURCE a document quotes.
MUT_LIB="$SCRATCH/mutant-guard.sh"
{
  printf '_TTG_MERGE_REQUIRED_FIELDS="%s extra-field"\n' "$FIELDS"
  printf '_mut_call_sites() {\n'
  printf '  _ttg_merge_deny "$1" "$2" "absent" "d"\n'
  printf '  _ttg_merge_deny "$1" "$2" "extra_reason" "d"\n'
  printf '}\n'
} > "$MUT_LIB"

SHIPPED_FIELD_N="$FIELD_N"
BIND_MODE="quiet"
# Aimed at the shipped documents, never at the injected root: the mutation is evidence about
# the binding itself, so a forced all-skip drive must not turn it vacuously green.
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$MUT_LIB"
assert_eq "[mutation] the mutant source really is a different contract" \
  "$FIELD_N $REASON_N" "$((SHIPPED_FIELD_N + 1)) 2"
# shellcheck disable=SC2154  # FD_*/CK_* are assigned indirectly, per family, by _check
if [ "$FD_fieldcount" -ge 1 ] && [ "$FD_field" -ge 1 ]; then
  _pass "[mutation] a field added to the constant with no doc update goes red ($FD_field name, $FD_fieldcount count findings)"
else
  _fail "[mutation] a field added to the constant with no doc update goes red" \
    "field findings=$FD_field, count findings=$FD_fieldcount — the documents passed against a contract they do not state"
fi

MUT_ROOT="$SCRATCH/updated-docs"
mkdir -p "$MUT_ROOT"
{
  printf -- '- **The registry of bound entry points lives HERE, not in a per-objective TRD.** Five entry points are bound\n'
  printf -- '  by the contract above: `tests/run-tests.sh`, `scripts/doctor.sh`, `scripts/self-audit.sh`,\n'
  printf -- '  `scripts/close-objective.sh`. The fifth is `tests/test-phantom.sh`, and\n'
  printf -- '  `tests/test-coverage-honesty.sh` drives every one of them.\n\n'
} > "$MUT_ROOT/RULES.md"
{
  printf '## Merge Evidence\n'
  printf 'The gate validates seven fields under that exact heading — `%s`, `extra-field` — ' \
    "$(printf '%s' "$FIELDS" | sed 's/ /`, `/g')"
  printf 'and emits two closed refusal reasons: `absent`, `extra_reason`.\n\n'
  printf 'Five entry points are bound by §15.\n'
} > "$MUT_ROOT/CLAUDE.md"

_scan_docs "$MUT_ROOT" "$MUT_ROOT" "$MUT_LIB"
if [ "$FINDINGS" -eq 0 ] && [ "$CHECKED" -ge 1 ]; then
  _pass "[mutation] documents updated with the mutant source go green ($CHECKED bindings, 0 findings)"
else
  _fail "[mutation] documents updated with the mutant source go green" \
    "checked=$CHECKED findings=$FINDINGS — the binding fails documents that DO state the derived contract"
fi

sed -e 's/Five entry points are bound/Six entry points are bound/' \
    -e 's|`scripts/close-objective.sh`\.|`scripts/close-objective.sh`, `scripts/lean-comments-guard.sh`.|' \
    "$MUT_ROOT/RULES.md" > "$SCRATCH/rules-grown.md"
cp "$SCRATCH/rules-grown.md" "$MUT_ROOT/RULES.md"
_scan_docs "$MUT_ROOT" "$MUT_ROOT" "$MUT_LIB"
# shellcheck disable=SC2154  # assigned indirectly by _check, as above
if [ "$FD_regcount" -eq 1 ] && [ "$FD_ordinal" -eq 1 ] && [ "$FD_field" -eq 0 ]; then
  _pass "[mutation] a sixth registry member turns the stale size AND the stale ordinal red, and nothing else"
else
  _fail "[mutation] a sixth registry member turns the stale size AND the stale ordinal red, and nothing else" \
    "regcount=$FD_regcount (want 1), ordinal=$FD_ordinal (want 1), field=$FD_field (want 0)"
fi

BIND_MODE="report"
RC=0
report_results || RC=1
printf '%s\n' "$SHIPPED_LINE"
[ "$SHIPPED_FINDINGS" -eq 0 ] || RC=1
exit "$RC"
