#!/usr/bin/env bash
set -uo pipefail
# test-messaging-posture — RULES §22's two mechanical rules over the shipped
# surface (spec 1-B):
#   R1: no shipped file names crossSessionInbound / isolatePeerMachines
#       (inbound posture is the operator's; Nazgul documents in docs/+README
#       only, which are NOT scanned surfaces)
#   R2: no shipped file references CLAUDE_CODE_MESSAGING_SOCKET / _TOKEN
#       outside the read-only allowlist — with no sanctioned poster, ANY
#       reference is a potential post (and covers token-never-logged).
# Coverage grammar per RULES §15. K>0 floor. Dogfooded synthetic violators.
TEST_NAME="test-messaging-posture"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="

SURFACE_ROOT="${NAZGUL_POSTURE_SURFACE_ROOT:-$REPO_ROOT}"
SURFACES="scripts skills agents templates hooks"
# Read-only allowlist (repo-relative), exactly per the spec's Global Constraint:
ALLOW_RE='^(scripts/doctor\.sh|scripts/lib/session-tracker\.sh)$'

scanned=0; skipped_unreadable=0; checked=0; findings=0

scan_file() {
  local f="$1" rel="${1#$SURFACE_ROOT/}" hits
  scanned=$((scanned + 1))
  if [ ! -r "$f" ]; then skipped_unreadable=$((skipped_unreadable + 1)); return 0; fi
  checked=$((checked + 1))
  hits=$(grep -nE 'crossSessionInbound|isolatePeerMachines' "$f" 2>/dev/null | head -3)
  if [ -n "$hits" ]; then
    findings=$((findings + 1))
    _fail "R1: $rel names an inbound-posture settings key" "$hits"
  fi
  if ! printf '%s' "$rel" | grep -qE "$ALLOW_RE"; then
    hits=$(grep -nE 'CLAUDE_CODE_MESSAGING_(SOCKET|TOKEN)' "$f" 2>/dev/null | head -3)
    if [ -n "$hits" ]; then
      findings=$((findings + 1))
      _fail "R2: $rel references the messaging socket/token outside the allowlist" "$hits"
    fi
  fi
  return 0
}

for s in $SURFACES; do
  [ -d "$SURFACE_ROOT/$s" ] || continue
  while IFS= read -r f; do
    scan_file "$f"
  done < <(find "$SURFACE_ROOT/$s" -type f \( -name '*.sh' -o -name '*.md' -o -name '*.json' \) 2>/dev/null | sort)
done

if [ "$checked" -gt 0 ]; then
  [ "$findings" -eq 0 ] && _pass "R1+R2: shipped surface is messaging-posture-clean ($checked files)"
else
  _fail "K>0 floor: the scan examined at least one file" "checked=0 — a scan that scans nothing is a broken scan, not a clean surface"
fi

# --- Dogfood: the predicates must catch synthetic violators (never run
#     through scan_file, which would count them as findings) ---
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-posture-XXXXXX"); trap 'rm -rf "$SCRATCH"' EXIT
printf 'printf x | nc -U "$CLAUDE_CODE_MESSAGING_SOCKET"\n' > "$SCRATCH/v1.sh"
grep -qE 'CLAUDE_CODE_MESSAGING_(SOCKET|TOKEN)' "$SCRATCH/v1.sh" \
  && _pass "dogfood: synthetic socket-poster caught by R2 predicate" \
  || _fail "dogfood: synthetic socket-poster caught by R2 predicate"
printf 'jq %s.crossSessionInbound="accept"%s s.json\n' "'" "'" > "$SCRATCH/v2.sh"
grep -qE 'crossSessionInbound|isolatePeerMachines' "$SCRATCH/v2.sh" \
  && _pass "dogfood: synthetic posture-writer caught by R1 predicate" \
  || _fail "dogfood: synthetic posture-writer caught by R1 predicate"

# Sibling idiom (tests/test-dispatch-brief-contract.sh:215-220): the coverage
# line is the LAST stdout line, and the verdict is the exit code.
RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$scanned" "$skipped_unreadable" "$skipped_unreadable" "$checked" "$findings"
exit "$RC"
