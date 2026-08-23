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
# The suite size is a claim about ONE runner, so it is read only off lines naming that runner:
# an unrelated "16 files" elsewhere counts a different population, not this one gone stale.
SUITE_ANCHOR='run-tests\.sh'
SUITE_SIZE_RE='[0-9]+ ([A-Za-z][A-Za-z/-]* )?files'
# The count noun NAMES the mechanism. A bare "N members" also matches RULES.md's "`unverifiable`
# and `not_merged` are separate members", which counts a different vocabulary entirely.
RED_RUN_SIZE_RE='[A-Za-z0-9]+ red-run refusal reasons'
RED_RUN_PIN_FILE="${NAZGUL_DOC_CONTRACT_RED_RUN_PIN:-$REPO_ROOT/tests/test-red-run-evidence.sh}"
CLOSER="${NAZGUL_DOC_CONTRACT_CLOSER:-$REPO_ROOT/scripts/close-objective.sh}"
CO_PIN_FILE="${NAZGUL_DOC_CONTRACT_CO_PIN:-$REPO_ROOT/tests/test-coverage-honesty.sh}"
# "skip reasons" is ordinary English and §16 calls two of them "distinct skip reasons" while
# counting nothing, so a size claim is read only where the closed-set framing follows the phrase.
SKIP_SIZE_RE='[A-Za-z0-9]+ skip reasons[^.]{0,16}a closed set'
# The event-name vocabulary's producers, each independently injectable. A DEDICATED EVENT_CO_LIB
# (not $CLOSER) so the skipreason family's own mutation, below, cannot starve this one too.
EVENT_CO_LIB="${NAZGUL_DOC_CONTRACT_EVENT_CLOSER:-$REPO_ROOT/scripts/close-objective.sh}"
STOP_HOOK_LIB="${NAZGUL_DOC_CONTRACT_STOP_HOOK:-$REPO_ROOT/scripts/stop-hook.sh}"
WORKTREE_UTILS_LIB="${NAZGUL_DOC_CONTRACT_WORKTREE_UTILS:-$REPO_ROOT/scripts/worktree-utils.sh}"
STACK_UTILS_LIB="${NAZGUL_DOC_CONTRACT_STACK_UTILS:-$REPO_ROOT/scripts/lib/stack-utils.sh}"
BOARD_SYNC_LIB="${NAZGUL_DOC_CONTRACT_BOARD_SYNC:-$REPO_ROOT/scripts/board-sync-github.sh}"
STAMP_PLAN_LIB="${NAZGUL_DOC_CONTRACT_STAMP_PLAN:-$REPO_ROOT/scripts/stamp-plan-objective.sh}"
REVIEW_EVIDENCE_LIB="${NAZGUL_DOC_CONTRACT_REVIEW_EVIDENCE:-$REPO_ROOT/scripts/lib/review-evidence.sh}"
BOUNDED_NET_LIB="${NAZGUL_DOC_CONTRACT_BOUNDED_NET:-$REPO_ROOT/scripts/lib/bounded-net.sh}"
READ_PAYLOAD_LIB="${NAZGUL_DOC_CONTRACT_READ_PAYLOAD:-$REPO_ROOT/scripts/lib/read-hook-payload.sh}"
EVENT_SIZE_RE='[A-Za-z0-9]+ lifecycle event types'
STOP_REASON_SIZE_RE='[A-Za-z0-9]+ stop_gate reasons'

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-doc-contract-XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

FAMILIES="field fieldcount reason reasoncount regcount ordinal tier suite mpresult mpresultcount mpevent mpeventcount redrun redruncount skipreason skipreasoncount event eventcount stopreason stopreasoncount"

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

# The seam's two vocabularies, read off its OWN call sites the way _derive_reasons reads the
# gate's. TASK-020 widened both; three documents kept the pre-widening counts, nothing bound them.
_derive_mp_results() {
  grep -oE '_mp_result ("[^"]*"|\$[A-Za-z_][A-Za-z_0-9]*) ("[^"]*"|\$[A-Za-z_][A-Za-z_0-9]*) ("[^"]*"|\$[A-Za-z_][A-Za-z_0-9]*) "[a-z_]+"' "$1" 2>/dev/null \
    | sed -E 's/.*"([a-z_]+)"$/\1/' | LC_ALL=C sort -u
}

_derive_mp_events() {
  grep -oE '_mp_emit "[^"]*" "merge_provider_[a-z_]+"' "$1" 2>/dev/null \
    | sed -E 's/.*"(merge_provider_[a-z_]+)"$/\1/' | LC_ALL=C sort -u
}

# The red-run gate's refusal vocabulary, off the same two emitters' call sites that
# tests/test-red-run-evidence.sh reads; a variable third argument is a passthrough, not a name.
_derive_red_run() {
  grep -oE '_ttg_red_run_(deny|empty_payload) "[^"]*" "[^"]*" "[^"]*"' "$1" 2>/dev/null \
    | sed -E 's/.*"([^"]*)"$/\1/' | grep -E '^[a-z_]+$' | LC_ALL=C sort -u
}

# The objective closer's CLOSED skip vocabulary, off the one terminal coverage printf that prints
# it: the `<reason>=%d` pairs inside its `skipped (...)` group, in the order that line prints them.
_derive_skip_reasons() {
  grep -oE '%d skipped \(([a-z-]+=%d, )*[a-z-]+=%d\)' "$1" 2>/dev/null \
    | awk 'NR == 1' | grep -oE '[a-z-]+=%d' | sed -E 's/=%d$//'
}

# lean-comments: allow-run — the anchor's inclusion and its exclusion are both silent, so
# both are stated where they are made.
# The event NAME vocabulary these producers emit, off the first LITERAL argument of
# emit_event/_ttg_emit_event/_bnet_emit; a variable-only call (`emit_event "$event"`) is a
# passthrough, excluded by the anchor. `_bnet_emit` is named here because it is exactly that
# passthrough — bounded-net.sh's own names are literal only at its wrapper's call sites, so a
# producer set that stops at `emit_event` reads that library as emitting nothing.
_derive_events() {
  local f
  for f in "$@"; do
    [ -r "$f" ] || continue
    grep -oE '_ttg_emit_event "\$[A-Za-z_][A-Za-z_0-9]*" "[a-z_]+"|_bnet_emit "[a-z_]+"|emit_event "[a-z_]+"' "$f"
  done | sed -E 's/.*"([a-z_]+)"$/\1/' | LC_ALL=C sort -u
}

# lean-comments: allow-run — the regex's two silent exclusions, stated where they are made.
# The stop_gate reason vocabulary off the three producers' call sites; a backslash continuation
# is joined first, since four call sites put `reason` on the next line. `reason` must sit
# IMMEDIATELY after `"stop_gate"` — ` +` admits whitespace only, so an intervening k/v pair hides
# the site — and its value must match `[a-z_]+`, so an interpolated or mixed-case value is a
# passthrough, not a name. SR4 plants one of each and measures that neither is derived.
_derive_stop_reasons() {
  local f
  for f in "$@"; do
    [ -r "$f" ] || continue
    sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$f"
  done | grep -oE '(emit_event|_su_emit) "stop_gate" +reason "[a-z_]+"' \
    | sed -E 's/.*reason "([a-z_]+)"$/\1/' | LC_ALL=C sort -u
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

# A document naming >= ENUM_MIN members of a closed vocabulary as a LIST is teaching the set and
# owes every member; one member is an example, and prose words like "absent" are never a list.
ENUM_MIN=2
ENUM_MARK=$'\001'

# The longest enumeration run of $1's members in $2: code spans with nothing between consecutive
# ones but list syntax (separator punctuation, a coordinating conjunction, or the next list item).
_enum_run() {
  local vocab="$1" tok bt='`' marked="$2"
  for tok in $vocab; do marked=${marked//"$bt$tok$bt"/"$ENUM_MARK"}; done
  printf '%s\n' "$marked" | awk -v m="$ENUM_MARK" '
    { buf = buf $0 "\n" }
    END {
      sep  = "[ \t]*([/,;|]|and|or|nor)[ \t]*"
      item = "[^\n]*\n[ \t]*([-*+]|[0-9]+\\.)[ \t]*"
      re = m "((" sep "|" item ")" m ")+"
      max = 0
      while (match(buf, re)) {
        seg = substr(buf, RSTART, RLENGTH)
        n = gsub(m, "", seg)
        if (n > max) max = n
        buf = substr(buf, RSTART + RLENGTH)
      }
      print max + 0
    }'
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
  eval "FDL_${family}=\"\$detail\""
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

# One closed vocabulary against one document. A stated count is an ADDITIONAL obligation, never
# the precondition for checking membership: an enumeration run binds every member on its own.
_check_vocabulary() {
  local family="$1" doc="$2" vocab="$3" haystack="$4" run="$5" claimed="$6" label="$7" emitter="$8"
  local tok why=""
  if [ -n "$claimed" ]; then
    why="states the vocabulary's size"
  elif [ "$run" -ge "$ENUM_MIN" ]; then
    why="lists $run of this closed vocabulary's members"
  fi
  for tok in $vocab; do
    SCANNED=$((SCANNED + 1))
    if [ -z "$why" ]; then
      _no_claim 1
    elif _token_in "$tok" "$haystack"; then
      _check "$family" 0 "$doc names $label '$tok'"
    else
      _check "$family" 1 "$doc names $label '$tok'" \
        "the document $why but omits '$tok', which $emitter"
    fi
  done
}

# Every runner-anchored size claim is its own binding: CLAUDE.md states the suite's size twice,
# and reading only the first would leave the second free to drift.
_check_suite_claims() {
  local doc="$1" region="$2" want="$3" word n=0
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    n=$((n + 1))
    SCANNED=$((SCANNED + 1))
    if [ "$word" = "$want" ]; then
      _check suite 0 "$doc: states $want files for the suite the runner discovers"
    else
      _check suite 1 "$doc: states the suite size the runner discovers" \
        "document says $word, the runner discovers $want"
    fi
  done <<< "$(grep -E "$SUITE_ANCHOR" <<< "$region" | grep -oiE "$SUITE_SIZE_RE" | awk '{ print $1 }')"
  if [ "$n" -eq 0 ]; then
    SCANNED=$((SCANNED + 1))
    _no_claim 1
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
  local doc path region flat passage pflat f fam fam_n word got idx ord tiers claimed per_doc

  FIELDS=$(_derive_fields "$guard_lib")
  REASONS=$(_derive_reasons "$guard_lib")
  MP_RESULTS=$(_derive_mp_results "$MP_LIB")
  MP_EVENTS=$(_derive_mp_events "$MP_LIB")
  RED_RUN=$(_derive_red_run "$guard_lib")
  SKIP_REASONS=$(_derive_skip_reasons "$CLOSER")
  EVENTS=$(_derive_events "$EVENT_CO_LIB" "$STOP_HOOK_LIB" "$BOARD_SYNC_LIB" "$STAMP_PLAN_LIB" \
    "$REVIEW_EVIDENCE_LIB" "$BOUNDED_NET_LIB" "$READ_PAYLOAD_LIB" "$guard_lib")
  STOP_REASONS=$(_derive_stop_reasons "$STOP_HOOK_LIB" "$WORKTREE_UTILS_LIB" "$STACK_UTILS_LIB")
  MEMBERS=$(_derive_registry_members "$content_root/RULES.md" 2>/dev/null)
  FIELD_N=$(printf '%s\n' "$FIELDS" | tr ' ' '\n' | grep -c '[^[:space:]]' || true)
  REASON_N=$(printf '%s\n' "$REASONS" | grep -c '[^[:space:]]' || true)
  MP_RESULT_N=$(printf '%s\n' "$MP_RESULTS" | grep -c '[^[:space:]]' || true)
  MP_EVENT_N=$(printf '%s\n' "$MP_EVENTS" | grep -c '[^[:space:]]' || true)
  RED_RUN_N=$(printf '%s\n' "$RED_RUN" | grep -c '[^[:space:]]' || true)
  SKIP_REASON_N=$(printf '%s\n' "$SKIP_REASONS" | grep -c '[^[:space:]]' || true)
  EVENT_N=$(printf '%s\n' "$EVENTS" | grep -c '[^[:space:]]' || true)
  STOP_REASON_N=$(printf '%s\n' "$STOP_REASONS" | grep -c '[^[:space:]]' || true)
  MEMBER_N=$(printf '%s\n' "$MEMBERS" | grep -c '[^[:space:]]' || true)
  SUITE_N=$(find "$name_root/tests" -maxdepth 1 -type f -name 'test-*.sh' 2>/dev/null | grep -c . || true)
  tiers=$(_derive_tiers "$content_root/RULES.md")
  TIER_E=$(awk '{ print $1 + 0 }' <<< "$tiers")
  TIER_A=$(awk '{ print $2 + 0 }' <<< "$tiers")
  TIER_H=$(awk '{ print $3 + 0 }' <<< "$tiers")

  SCANNED=0; SKIP_UNREADABLE=0; SKIP_NO_CLAIM=0; CHECKED=0; FINDINGS=0
  for fam in $FAMILIES; do eval "CK_${fam}=0; FD_${fam}=0; FDL_${fam}=''"; done

  # Population = top-level docs, the live reference docs one level under docs/, and every shipped
  # SKILL.md — enumerated, never authored; docs/superpowers/** is DATED record, so binding it lies.
  DOC_NAMES=$( { find "$name_root" -maxdepth 1 -type f -name '*.md'
                 find "$name_root/docs" -maxdepth 1 -type f -name '*.md'
                 find "$name_root/skills" -maxdepth 2 -type f -name 'SKILL.md'; } 2>/dev/null \
    | sed "s|^$name_root/||" | LC_ALL=C sort)
  DOC_N=$(printf '%s\n' "$DOC_NAMES" | grep -c '[^[:space:]]' || true)
  per_doc=$((FIELD_N + REASON_N + MP_RESULT_N + MP_EVENT_N + RED_RUN_N + SKIP_REASON_N + EVENT_N + STOP_REASON_N + 15))

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
      _check_vocabulary reason "$doc" "$REASONS" "$passage" "$(_enum_run "$REASONS" "$passage")" \
        "$(_claim_word "$pflat" '[A-Za-z0-9]+ closed refusal reasons')" \
        "refusal reason" "the gate emits"
      _check_count_claim reasoncount "$doc" "$pflat" '[A-Za-z0-9]+ closed refusal reasons' \
        "$REASON_N" "closed refusal reason"
    fi

    _check_count_claim regcount "$doc" "$flat" '[A-Za-z0-9]+ entry points are bound' \
      "$MEMBER_N" "§15 registry member"
    _check_count_claim suite "$doc" "$flat" '[A-Za-z0-9]+ files, all green' \
      "$SUITE_N" "discovered root suite"
    _check_suite_claims "$doc" "$region" "$SUITE_N"

    _check_vocabulary mpresult "$doc" "$MP_RESULTS" "$flat" "$(_enum_run "$MP_RESULTS" "$region")" \
      "$(_claim_word "$flat" '[A-Za-z0-9]+ named results')" \
      "merge-provider result" "the seam returns"
    _check_count_claim mpresultcount "$doc" "$flat" '[A-Za-z0-9]+ named results' \
      "$MP_RESULT_N" "merge-provider result"

    _check_vocabulary mpevent "$doc" "$MP_EVENTS" "$flat" "$(_enum_run "$MP_EVENTS" "$region")" \
      "$(_claim_word "$flat" '[A-Za-z0-9]+ additive event types')" \
      "merge-provider event" "the seam emits"
    _check_count_claim mpeventcount "$doc" "$flat" '[A-Za-z0-9]+ additive event types' \
      "$MP_EVENT_N" "merge-provider event"

    _check_vocabulary redrun "$doc" "$RED_RUN" "$flat" "$(_enum_run "$RED_RUN" "$region")" \
      "$(_claim_word "$flat" "$RED_RUN_SIZE_RE")" \
      "red-run refusal reason" "the red-run evidence gate emits"
    _check_count_claim redruncount "$doc" "$flat" "$RED_RUN_SIZE_RE" \
      "$RED_RUN_N" "red-run refusal reason"

    _check_vocabulary skipreason "$doc" "$SKIP_REASONS" "$flat" "$(_enum_run "$SKIP_REASONS" "$region")" \
      "$(_claim_word "$flat" "$SKIP_SIZE_RE")" \
      "closer skip reason" "the objective closer prints"
    _check_count_claim skipreasoncount "$doc" "$flat" "$SKIP_SIZE_RE" \
      "$SKIP_REASON_N" "closer skip reason"

    # No enum-run trigger: this vocabulary spans several unrelated producers, so ONE producer's
    # own sub-list elsewhere is not a claim about the whole cross-producer set.
    _check_vocabulary event "$doc" "$EVENTS" "$flat" 0 \
      "$(_claim_word "$flat" "$EVENT_SIZE_RE")" \
      "lifecycle event type" "these producers emit"
    _check_count_claim eventcount "$doc" "$flat" "$EVENT_SIZE_RE" \
      "$EVENT_N" "lifecycle event type"

    # Same "no enum-run trigger" reasoning as `event`: this vocabulary spans three
    # unrelated producer scripts, so one producer's own sub-list is not a whole-set claim.
    _check_vocabulary stopreason "$doc" "$STOP_REASONS" "$flat" 0 \
      "$(_claim_word "$flat" "$STOP_REASON_SIZE_RE")" \
      "stop_gate reason" "these three producers emit"
    _check_count_claim stopreasoncount "$doc" "$flat" "$STOP_REASON_SIZE_RE" \
      "$STOP_REASON_N" "stop_gate reason"

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

CO_PRINTFS=$(grep -cE '%d skipped \(([a-z-]+=%d, )*[a-z-]+=%d\)' "$CLOSER" 2>/dev/null || true)
assert_eq "the skip vocabulary comes from exactly one coverage printf in $(basename "$CLOSER")" \
  "$CO_PRINTFS" "1"

_scan_docs "$REPO_ROOT" "$DOC_ROOT" "$GUARD_LIB"

if [ -z "$FIELDS" ] || [ -z "$REASONS" ] || [ -z "$MP_RESULTS" ] || [ -z "$MP_EVENTS" ] \
   || [ -z "$RED_RUN" ] || [ -z "$SKIP_REASONS" ] || [ -z "$EVENTS" ] || [ -z "$STOP_REASONS" ]; then
  _fail "the merge contract is derived from the gate library" \
    "fields='$FIELDS' reasons='$(printf '%s' "$REASONS" | tr '\n' ' ')' mp_results='$(printf '%s' "$MP_RESULTS" | tr '\n' ' ')' mp_events='$(printf '%s' "$MP_EVENTS" | tr '\n' ' ')' red_run='$(printf '%s' "$RED_RUN" | tr '\n' ' ')' skip_reasons='$(printf '%s' "$SKIP_REASONS" | tr '\n' ' ')' events='$(printf '%s' "$EVENTS" | tr '\n' ' ')' stop_reasons='$(printf '%s' "$STOP_REASONS" | tr '\n' ' ')'" \
    "the contract could not be derived — this is 'never looked', not 'looked and found none'"
  echo "$TEST_NAME: NOTHING CHECKED — the gate library yielded no contract to bind" >&2
  report_results
  _emit_coverage
  exit 1
fi
_pass "the merge contract is derived from the gate library ($FIELD_N fields, $REASON_N refusal reasons)"
_pass "the merge-observation seam's vocabularies are derived from its own call sites ($MP_RESULT_N results, $MP_EVENT_N events)"
_pass "the stop_gate reason vocabulary is derived from its three producers' call sites ($STOP_REASON_N reasons)"
_pass "the §15 registry is derived from RULES.md's own bullet ($MEMBER_N members)"
_pass "the lifecycle event-name vocabulary is derived from its own producers' call sites ($EVENT_N events)"

# One denominator, two readers. tests/test-red-run-evidence.sh pins the same vocabulary against the
# same source; if its copy and this one ever disagree, the disagreement is the finding.
RED_RUN_SHIPPED=$(_derive_red_run "$REPO_ROOT/scripts/lib/task-transition-guard.sh" | tr '\n' ' ')
RED_RUN_PINNED=$(grep -oE "^VOCAB_EXPECTED='[^']*'" "$RED_RUN_PIN_FILE" 2>/dev/null \
  | sed -E "s/^VOCAB_EXPECTED='(.*)'\$/\1/" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
if [ -z "$RED_RUN_SHIPPED" ] || [ -z "$RED_RUN_PINNED" ]; then
  _fail "the red-run vocabulary has one denominator, not two" \
    "derived='$RED_RUN_SHIPPED' pinned='$RED_RUN_PINNED' from $RED_RUN_PIN_FILE — a pin that cannot be read is 'never looked'"
else
  assert_eq "the red-run vocabulary this test derives is the one tests/test-red-run-evidence.sh pins" \
    "$RED_RUN_SHIPPED" "$RED_RUN_PINNED"
fi
_pass "the red-run refusal vocabulary is derived from its own call sites ($RED_RUN_N reasons)"

# Same principle for the closer's skip set: tests/test-coverage-honesty.sh pins it by hand to check
# the coverage-line grammar, so a disagreement between that copy and this derivation IS the finding.
CO_SHIPPED=$(_derive_skip_reasons "$CLOSER" | LC_ALL=C sort | tr '\n' ' ')
CO_PINNED=$(grep -oE '^CO_REASONS="[^"]*"' "$CO_PIN_FILE" 2>/dev/null \
  | sed -E 's/^CO_REASONS="(.*)"$/\1/' | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
if [ -z "$CO_SHIPPED" ] || [ -z "$CO_PINNED" ]; then
  _fail "the closer's skip vocabulary has one denominator, not two" \
    "derived='$CO_SHIPPED' pinned='$CO_PINNED' from $CO_PIN_FILE — a pin that cannot be read is 'never looked'"
else
  assert_eq "the skip vocabulary this test derives is the one tests/test-coverage-honesty.sh pins" \
    "$CO_SHIPPED" "$CO_PINNED"
fi
_pass "the closer's skip vocabulary is derived from its own coverage printf ($SKIP_REASON_N reasons)"

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
  printf '_mut_red_run_sites() {\n'
  printf '  _ttg_red_run_deny "$1" "$2" "rr_alpha" "d"\n'
  printf '  _ttg_red_run_deny "$1" "$2" "rr_beta" "d"\n'
  printf '  _ttg_red_run_empty_payload "$1" "$2" "rr_gamma" "p" "$5" "$6"\n'
  printf '  _ttg_red_run_deny "$1" "$2" "$reason" "d"\n'
  printf '}\n'
} > "$MUT_LIB"

SHIPPED_FIELD_N="$FIELD_N"
SHIPPED_SKIP_REASONS="$SKIP_REASONS"
SHIPPED_MP_LIB="$MP_LIB"
SHIPPED_CLOSER="$CLOSER"
SHIPPED_EVENT_N="$EVENT_N"
SHIPPED_STOP_HOOK_LIB="$STOP_HOOK_LIB"
SHIPPED_STOP_REASON_N="$STOP_REASON_N"
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

# C1-C6: the enumeration trigger, driven with NO count claim in any fixture, so a green here is
# the threshold rule carrying the binding and never a count phrase carrying it for it.
MUT_MP="$SCRATCH/mutant-seam.sh"
{
  printf '_mut_seam() {\n'
  printf '  _mp_result "$1" "$2" "$3" "alpha_state"\n'
  printf '  _mp_result "$1" "$2" "$3" "beta_state"\n'
  printf '  _mp_result "$1" "$2" "$3" "gamma_state"\n'
  printf '  _mp_emit "$1" "merge_provider_alpha"\n'
  printf '  _mp_emit "$1" "merge_provider_beta"\n'
  printf '}\n'
} > "$MUT_MP"

_enum_case() {
  mkdir -p "$SCRATCH/$1"
  cat > "$SCRATCH/$1/CLAUDE.md"
  _scan_docs "$SCRATCH/$1" "$SCRATCH/$1" "$MUT_LIB"
}

# Every case also re-asserts N == M + K: a fixture that stops being checked must still be counted.
_enum_expect() {
  local label="$1" wc="$2" wf="$3" acct
  acct=$((SKIP_UNREADABLE + SKIP_NO_CLAIM + CHECKED))
  if [ "$CK_mpresult" -eq "$wc" ] && [ "$FD_mpresult" -eq "$wf" ] && [ "$SCANNED" -eq "$acct" ]; then
    _pass "[mutation] $label"
  else
    _fail "[mutation] $label" \
      "mpresult checked=$CK_mpresult (want $wc) findings=$FD_mpresult (want $wf); scanned=$SCANNED, M+K=$acct"
  fi
}

MP_LIB="$MUT_MP"
_enum_case enum-red <<'FIXTURE'
Every unusable state has its own name (`alpha_state`/`beta_state`), and each one is announced
as `merge_provider_alpha` or `merge_provider_beta`.
FIXTURE
assert_eq "[mutation] the mutant seam really is a different vocabulary" \
  "$MP_RESULT_N $MP_EVENT_N" "3 2"
_enum_expect "a widened seam with no doc update goes red through a bare list, no count stated" 3 1
# shellcheck disable=SC2154  # FDL_* is assigned indirectly, per family, by _check
case "$FDL_mpresult" in
  *gamma_state*) _pass "[mutation] the bare-list finding names the member the seam added" ;;
  *) _fail "[mutation] the bare-list finding names the member the seam added" \
       "detail was '$FDL_mpresult', which does not name 'gamma_state'" ;;
esac

_enum_case enum-green <<'FIXTURE'
Every unusable state has its own name (`alpha_state`/`beta_state`/`gamma_state`), and each one
is announced as `merge_provider_alpha` or `merge_provider_beta`.
FIXTURE
_enum_expect "the same bare list completed against the mutant seam goes green" 3 0

_enum_case enum-single <<'FIXTURE'
A named result such as `alpha_state` is what the seam returns when it could not ask the host,
and the tick that produced it is recorded as `merge_provider_alpha`.
FIXTURE
_enum_expect "one named member is an example, so it stays a counted no-claim" 0 0

_enum_case enum-prose <<'FIXTURE'
`alpha_state` (could not ask) is a named result distinct from `beta_state` (asked, and the
answer was no) — prose naming two members a clause apart, not a list teaching the set.
FIXTURE
_enum_expect "two members a clause apart are two examples, so they stay a counted no-claim" 0 0

MUT_MP_WORDS="$SCRATCH/mutant-seam-words.sh"
{
  printf '_mut_seam() {\n'
  printf '  _mp_result "$1" "$2" "$3" "pending"\n'
  printf '  _mp_result "$1" "$2" "$3" "stale"\n'
  printf '}\n'
} > "$MUT_MP_WORDS"
MP_LIB="$MUT_MP_WORDS"

_enum_case enum-words <<'FIXTURE'
Two of this seam's names are ordinary English, so a run can be pending, stale, or both without
the sentence being a vocabulary at all.
FIXTURE
_enum_expect "members that are also English words do not form a list in running prose" 0 0

_enum_case enum-words-spanned <<'FIXTURE'
The same two names written as identifiers ARE a list: `pending`, `stale`.
FIXTURE
_enum_expect "the identical words written as code spans do bind, so the rule reads form not luck" 2 0

# R1-R3: the same threshold rule over the red-run gate's vocabulary, which the mutant guard
# reproduces through BOTH emitters plus one variable-passthrough site that is not a name.
_rr_expect() {
  local label="$1" wc="$2" wf="$3" wn="$4" acct
  acct=$((SKIP_UNREADABLE + SKIP_NO_CLAIM + CHECKED))
  # shellcheck disable=SC2154  # CK_*/FD_* are assigned indirectly, per family, by _check
  if [ "$CK_redrun" -eq "$wc" ] && [ "$FD_redrun" -eq "$wf" ] \
     && [ "$FD_redruncount" -eq "$wn" ] && [ "$SCANNED" -eq "$acct" ]; then
    _pass "[mutation] $label"
  else
    _fail "[mutation] $label" \
      "redrun checked=$CK_redrun (want $wc) findings=$FD_redrun (want $wf); redruncount findings=$FD_redruncount (want $wn); scanned=$SCANNED, M+K=$acct"
  fi
}

_enum_case rr-red <<'FIXTURE'
The red-run evidence gate's refusal vocabulary is CLOSED: `rr_alpha`, `rr_beta`.
FIXTURE
assert_eq "[mutation] the mutant guard's red-run vocabulary excludes its passthrough site" \
  "$RED_RUN_N" "3"
_rr_expect "a widened red-run vocabulary with no doc update goes red through a bare list, no count stated" 3 1 0
# shellcheck disable=SC2154  # FDL_* is assigned indirectly, per family, by _check
case "$FDL_redrun" in
  *rr_gamma*) _pass "[mutation] the red-run finding names the reason the gate added" ;;
  *) _fail "[mutation] the red-run finding names the reason the gate added" \
       "detail was '$FDL_redrun', which does not name 'rr_gamma'" ;;
esac

_enum_case rr-green <<'FIXTURE'
The red-run evidence gate's refusal vocabulary is CLOSED: `rr_alpha`, `rr_beta`, `rr_gamma`.
FIXTURE
_rr_expect "the same bare list completed against the mutant guard goes green" 3 0 0

_enum_case rr-count <<'FIXTURE'
The gate emits two red-run refusal reasons: `rr_alpha`, `rr_beta`, `rr_gamma`.
FIXTURE
_rr_expect "a stale count is its own finding, with every member still named" 3 0 1

# CO1-CO4: the same threshold rule over the objective closer's skip set. A mutant closer IS just the
# one line the derivation reads, so these fixtures mutate the printf and nothing else.
_mutant_closer() {
  local out="$1" group
  group=$(printf '%s\n' "$2" | tr ' ' '\n' | grep -v '^$' \
    | awk '{ printf "%s%s=%%d", (NR > 1 ? ", " : ""), $0 }')
  printf "printf '%%s: %%d scanned, %%d skipped (%s), %%d closed, %%d refused'\n" "$group" > "$out"
}

_co_expect() {
  local label="$1" wc="$2" wf="$3" wn="$4" acct
  acct=$((SKIP_UNREADABLE + SKIP_NO_CLAIM + CHECKED))
  # shellcheck disable=SC2154  # CK_*/FD_* are assigned indirectly, per family, by _check
  if [ "$CK_skipreason" -eq "$wc" ] && [ "$FD_skipreason" -eq "$wf" ] \
     && [ "$FD_skipreasoncount" -eq "$wn" ] && [ "$SCANNED" -eq "$acct" ]; then
    _pass "[mutation] $label"
  else
    _fail "[mutation] $label" \
      "skipreason checked=$CK_skipreason (want $wc) findings=$FD_skipreason (want $wf); skipreasoncount findings=$FD_skipreasoncount (want $wn); scanned=$SCANNED, M+K=$acct"
  fi
}

_mutant_closer "$SCRATCH/mutant-closer.sh" "co-alpha co-beta co-gamma"
CLOSER="$SCRATCH/mutant-closer.sh"

_enum_case co-red <<'FIXTURE'
The closer's skip vocabulary is CLOSED: `co-alpha`, `co-beta`.
FIXTURE
assert_eq "[mutation] the mutant closer really is a different skip vocabulary" "$SKIP_REASON_N" "3"
_co_expect "a skip reason added to the closer's printf with no doc update goes red through a bare list, no count stated" 3 1 0
# shellcheck disable=SC2154  # FDL_* is assigned indirectly, per family, by _check
case "$FDL_skipreason" in
  *co-gamma*) _pass "[mutation] the skip-reason finding names the reason the closer added" ;;
  *) _fail "[mutation] the skip-reason finding names the reason the closer added" \
       "detail was '$FDL_skipreason', which does not name 'co-gamma'" ;;
esac

_enum_case co-green <<'FIXTURE'
The closer's skip vocabulary is CLOSED: `co-alpha`, `co-beta`, `co-gamma`.
FIXTURE
_co_expect "the same bare list completed against the mutant closer goes green" 3 0 0

_enum_case co-count <<'FIXTURE'
Its two skip reasons are a closed set: `co-alpha`, `co-beta`, `co-gamma`.
FIXTURE
_co_expect "a stale skip-reason count is its own finding, with every member still named" 3 0 1

# CO5: the SHIPPED documents against a tenth skip reason. Only the closer's printf is mutated, so a
# finding in any other family would be a binding reacting to a mechanism nobody touched.
MP_LIB="$SHIPPED_MP_LIB"
_mutant_closer "$SCRATCH/mutant-closer-tenth.sh" "$SHIPPED_SKIP_REASONS co-tenth"
CLOSER="$SCRATCH/mutant-closer-tenth.sh"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
if [ "$FD_skipreason" -ge 1 ] && [ "$FD_skipreasoncount" -ge 1 ] \
   && [ "$FINDINGS" -eq $((FD_skipreason + FD_skipreasoncount)) ]; then
  _pass "[mutation] a tenth skip reason turns every shipped document that teaches the set red, and nothing else ($FD_skipreason name, $FD_skipreasoncount count findings)"
else
  _fail "[mutation] a tenth skip reason turns every shipped document that teaches the set red, and nothing else" \
    "skipreason=$FD_skipreason skipreasoncount=$FD_skipreasoncount, total findings=$FINDINGS"
fi
case "$FDL_skipreason" in
  *co-tenth*) _pass "[mutation] the shipped-tree finding names the reason the closer added" ;;
  *) _fail "[mutation] the shipped-tree finding names the reason the closer added" \
       "detail was '$FDL_skipreason', which does not name 'co-tenth'" ;;
esac
CLOSER="$SHIPPED_CLOSER"

# EV1-EV3: the same threshold rule over the lifecycle event-name vocabulary, driven against a
# stop-hook.sh grown by one more emitter — AC1's "planted twelfth" dogfood.
MUT_STOP_HOOK="$SCRATCH/mutant-stop-hook.sh"
{ cat "$STOP_HOOK_LIB"; printf '\nemit_event "ev_planted"\n'; } > "$MUT_STOP_HOOK"
STOP_HOOK_LIB="$MUT_STOP_HOOK"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
assert_eq "[mutation] the mutant stop-hook really adds one more event type" \
  "$EVENT_N" "$((SHIPPED_EVENT_N + 1))"
if [ "$FD_event" -ge 1 ] && [ "$FINDINGS" -eq $((FD_event + FD_eventcount)) ]; then
  _pass "[mutation] a planted emitter with no doc update goes red through a bare list, and nothing else ($FD_event name, $FD_eventcount count findings)"
else
  _fail "[mutation] a planted emitter with no doc update goes red through a bare list, and nothing else" \
    "event findings=$FD_event, eventcount findings=$FD_eventcount, total findings=$FINDINGS"
fi
case "$FDL_event" in
  *ev_planted*) _pass "[mutation] the event finding names the emitter the mutant stop-hook added" ;;
  *) _fail "[mutation] the event finding names the emitter the mutant stop-hook added" \
       "detail was '$FDL_event', which does not name 'ev_planted'" ;;
esac
STOP_HOOK_LIB="$SHIPPED_STOP_HOOK_LIB"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
if [ "$FD_event" -eq 0 ] && [ "$FD_eventcount" -eq 0 ] && [ "$EVENT_N" -eq "$SHIPPED_EVENT_N" ]; then
  _pass "[mutation] removing the planted emitter returns zero event findings ($EVENT_N events, matching the shipped count)"
else
  _fail "[mutation] removing the planted emitter returns zero event findings" \
    "event findings=$FD_event, eventcount findings=$FD_eventcount, event_n=$EVENT_N (want $SHIPPED_EVENT_N)"
fi

# EV4: the same rule through the WIDENED half of the anchor — bounded-net.sh reaches the bus
# only through `_bnet_emit`, which `emit_event` alone would read as emitting nothing.
MUT_BNET="$SCRATCH/mutant-bounded-net.sh"
{ cat "$BOUNDED_NET_LIB"; printf '\n_bnet_emit "ev_bnet_planted"\n'; } > "$MUT_BNET"
SHIPPED_BOUNDED_NET_LIB="$BOUNDED_NET_LIB"
BOUNDED_NET_LIB="$MUT_BNET"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
assert_eq "[mutation] a plant at the _bnet_emit wrapper really adds one more event type" \
  "$EVENT_N" "$((SHIPPED_EVENT_N + 1))"
case "$FDL_event" in
  *ev_bnet_planted*) _pass "[mutation] the event finding names the emitter the mutant wrapper added" ;;
  *) _fail "[mutation] the event finding names the emitter the mutant wrapper added" \
       "detail was '$FDL_event', which does not name 'ev_bnet_planted'" ;;
esac
BOUNDED_NET_LIB="$SHIPPED_BOUNDED_NET_LIB"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
if [ "$FD_event" -eq 0 ] && [ "$EVENT_N" -eq "$SHIPPED_EVENT_N" ]; then
  _pass "[mutation] removing the wrapper plant returns zero event findings ($EVENT_N events, matching the shipped count)"
else
  _fail "[mutation] removing the wrapper plant returns zero event findings" \
    "event findings=$FD_event, event_n=$EVENT_N (want $SHIPPED_EVENT_N)"
fi

# SR1-SR3: the same threshold rule over the stop_gate reason vocabulary, mirroring EV1-EV3
# exactly, driven against a stop-hook.sh grown by one more `stop_gate` reason value.
MUT_STOP_HOOK_SR="$SCRATCH/mutant-stop-hook-sr.sh"
{ cat "$SHIPPED_STOP_HOOK_LIB"; printf '\nemit_event "stop_gate" reason "sr_planted"\n'; } > "$MUT_STOP_HOOK_SR"
STOP_HOOK_LIB="$MUT_STOP_HOOK_SR"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
assert_eq "[mutation] the mutant stop-hook really adds one more stop_gate reason" \
  "$STOP_REASON_N" "$((SHIPPED_STOP_REASON_N + 1))"
if [ "$FD_stopreason" -ge 1 ] && [ "$FINDINGS" -eq $((FD_stopreason + FD_stopreasoncount)) ]; then
  _pass "[mutation] a planted stop_gate reason with no doc update goes red through a bare list, and nothing else ($FD_stopreason name, $FD_stopreasoncount count findings)"
else
  _fail "[mutation] a planted stop_gate reason with no doc update goes red through a bare list, and nothing else" \
    "stopreason findings=$FD_stopreason, stopreasoncount findings=$FD_stopreasoncount, total findings=$FINDINGS"
fi
case "$FDL_stopreason" in
  *sr_planted*) _pass "[mutation] the stop_gate finding names the reason the mutant stop-hook added" ;;
  *) _fail "[mutation] the stop_gate finding names the reason the mutant stop-hook added" \
       "detail was '$FDL_stopreason', which does not name 'sr_planted'" ;;
esac
STOP_HOOK_LIB="$SHIPPED_STOP_HOOK_LIB"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
if [ "$FD_stopreason" -eq 0 ] && [ "$FD_stopreasoncount" -eq 0 ] && [ "$STOP_REASON_N" -eq "$SHIPPED_STOP_REASON_N" ]; then
  _pass "[mutation] removing the planted stop_gate reason returns zero findings ($STOP_REASON_N reasons, matching the shipped count)"
else
  _fail "[mutation] removing the planted stop_gate reason returns zero findings" \
    "stopreason findings=$FD_stopreason, stopreasoncount findings=$FD_stopreasoncount, stop_reason_n=$STOP_REASON_N (want $SHIPPED_STOP_REASON_N)"
fi

# lean-comments: allow-run — SR4 asserts a NON-change, so what it measures has to be stated.
# SR4 (INVERTED): the two shape boundaries `_derive_stop_reasons` states. A `reason` in second
# position and an interpolated value are both outside its regex, so a mutant carrying one of each
# must move STOP_REASON_N by ZERO — SR1 asserts +1, this asserts +0 with a plant present. The
# first literal stays `stop_gate` deliberately: any other token would add an event name, move
# EVENT_N and per_doc, and raise event-family findings that would destroy the isolation below.
MUT_STOP_HOOK_SR4="$SCRATCH/mutant-stop-hook-sr4.sh"
{ cat "$SHIPPED_STOP_HOOK_LIB"
  printf '\nemit_event "stop_gate" gate "g" reason "sr_second_position"\n'
  printf 'emit_event "stop_gate" reason "$sr_interpolated"\n'
} > "$MUT_STOP_HOOK_SR4"
STOP_HOOK_LIB="$MUT_STOP_HOOK_SR4"
_scan_docs "$REPO_ROOT" "$REPO_ROOT" "$GUARD_LIB"
assert_eq "[mutation] a second-position reason and an interpolated value are both outside the derivation" \
  "$STOP_REASON_N" "$SHIPPED_STOP_REASON_N"
if [ "$FD_stopreason" -eq 0 ] && [ "$FD_stopreasoncount" -eq 0 ] && [ "$FINDINGS" -eq 0 ]; then
  _pass "[mutation] a stop_gate plant outside the stated shape leaves every family clean ($STOP_REASON_N reasons, $FINDINGS total findings)"
else
  _fail "[mutation] a stop_gate plant outside the stated shape leaves every family clean" \
    "stopreason findings=$FD_stopreason, stopreasoncount findings=$FD_stopreasoncount, total findings=$FINDINGS"
fi
# No trailing rescan: nothing past here reads a scan, SHIPPED_LINE/SHIPPED_FINDINGS were captured
# before any mutation, and this scan is shipped-equivalent by its own assertion above.
STOP_HOOK_LIB="$SHIPPED_STOP_HOOK_LIB"

BIND_MODE="report"
RC=0
report_results || RC=1
printf '%s\n' "$SHIPPED_LINE"
[ "$SHIPPED_FINDINGS" -eq 0 ] || RC=1
exit "$RC"
