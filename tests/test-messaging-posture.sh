#!/usr/bin/env bash
set -uo pipefail
# test-messaging-posture — RULES §22's two mechanical rules over the shipped
# surface (spec 1-B):
#   R1: no shipped file names crossSessionInbound / isolatePeerMachines
#       (inbound posture is the operator's; Nazgul documents in docs/+README
#       only, which are NOT scanned surfaces)
#   R2: no shipped file references CLAUDE_CODE_MESSAGING_SOCKET / _TOKEN
#       outside the read-only allowlist, and no allowlisted file CONNECTS to
#       what it is allowed to read (covers token-never-logged).
# The surface is the shipped FILE SET, not an extension whitelist: enumeration
# completeness is itself checked. Coverage grammar per RULES §15. K>0 floor,
# per-surface floors, dogfooded synthetic violators.
TEST_NAME="test-messaging-posture"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="

SURFACE_ROOT="${NAZGUL_POSTURE_SURFACE_ROOT:-$REPO_ROOT}"
# `references` and `.claude-plugin` are shipped plugin content and were missing
# (PR #223 review #13): agents read `${CLAUDE_PLUGIN_ROOT}/references/*.md` at runtime,
# and `.claude-plugin/` is the manifest the host loads. RULES §22 rule 2 claims "no
# shipped surface posts to the messaging socket, EVER" — a claim the scan must actually
# bind, or the rule's `[enforced]` tier is unearned. This is F-A's defect one level up:
# F-A fixed WHICH FILES within a surface are scanned; this fixes WHICH SURFACES exist.
SURFACES="scripts skills agents templates hooks references .claude-plugin"
# Read-only allowlist (repo-relative), exactly per the spec's Global Constraint:
ALLOW_RE='^(scripts/doctor\.sh|scripts/lib/session-tracker\.sh)$'
R1_KEY_RE='crossSessionInbound|isolatePeerMachines'
# doctor.sh must NAME a posture key to report the operator's effective posture
# (plan Global Constraint). R1's real subject there is WRITING one (design §298).
ALLOW_R1_RE='^scripts/doctor\.sh$'
R1_WRITE_RE='(crossSessionInbound|isolatePeerMachines)["'"'"']? *=[^=]'
R1_SETTINGS_WRITE_RE='(>|>>|tee|sponge)[^|;&]*settings(\.local)?\.json'
R2_KEY_RE='CLAUDE_CODE_MESSAGING_(SOCKET|TOKEN)'
# R2's second tier, carrying R1's shape: an allowlisted file may READ the value,
# never post to it. Denylist of connect constructs — named as §22's residual.
R2_CONNECT_RE='(nc|ncat|netcat)[^|;&]*-U[[:space:]]|socat[^|;&]*UNIX-(CONNECT|CLIENT|SENDTO)|openssl[^|;&]*s_client|(curl|wget)[^|;&]*--unix-socket|(>|>>|\||tee)[^|;&]*CLAUDE_CODE_MESSAGING_(SOCKET|TOKEN)|/dev/(tcp|udp)/'
# Pinned floor for the enumerator's own completeness: three shipped files carry
# no scanned extension (two git executes from core.hooksPath, one /nazgul:init injects).
POSTURE_ROSTER='scripts/git-hooks/pre-commit
scripts/git-hooks/pre-merge-commit
templates/CLAUDE.md.template'

# EVERY _fail below must increment `findings` before firing (PR #223 review #8). The
# coverage line this file emits is its §15 contract, `tests/test-coverage-honesty.sh`
# asserts the number, and a failing run that printed "0 findings" would be exactly the
# dishonest-accounting defect this scan exists to catch — committed by the scan itself.
scanned=0; skipped_unreadable=0; checked=0; findings=0
CHECKED_LIST=""

scan_file() {
  local f="$1" rel="${1#"$SURFACE_ROOT"/}" hits
  scanned=$((scanned + 1))
  if [ ! -r "$f" ]; then skipped_unreadable=$((skipped_unreadable + 1)); return 0; fi
  checked=$((checked + 1))
  CHECKED_LIST="$CHECKED_LIST$rel
"
  hits=$(grep -nE "$R1_KEY_RE" "$f" 2>/dev/null | head -3)
  if [ -n "$hits" ] && ! printf '%s' "$rel" | grep -qE "$ALLOW_R1_RE"; then
    findings=$((findings + 1))
    _fail "R1: $rel names an inbound-posture settings key" "$hits"
  elif [ -n "$hits" ]; then
    hits=$(grep -nE "$R1_WRITE_RE|$R1_SETTINGS_WRITE_RE" "$f" 2>/dev/null | head -3)
    if [ -n "$hits" ]; then
      findings=$((findings + 1))
      _fail "R1: $rel WRITES an inbound-posture setting (allowlisted to read one, never to set one)" "$hits"
    fi
  fi
  hits=$(grep -nE "$R2_KEY_RE" "$f" 2>/dev/null | head -3)
  if [ -n "$hits" ] && ! printf '%s' "$rel" | grep -qE "$ALLOW_RE"; then
    findings=$((findings + 1))
    _fail "R2: $rel references the messaging socket/token outside the allowlist" "$hits"
  elif [ -n "$hits" ]; then
    hits=$(grep -nE "$R2_CONNECT_RE" "$f" 2>/dev/null | head -3)
    if [ -n "$hits" ]; then
      findings=$((findings + 1))
      _fail "R2: $rel CONNECTS to the messaging socket (allowlisted to read the value, never to post to it)" "$hits"
    fi
  fi
  return 0
}

# No extension filter: an extension whitelist is a second, unstated surface
# definition, and three shipped files fall outside it (F-A).
for s in $SURFACES; do
  before=$checked
  if [ ! -d "$SURFACE_ROOT/$s" ]; then
    findings=$((findings + 1))
    _fail "surface floor: shipped surface '$s' exists" \
      "$SURFACE_ROOT/$s is absent — a renamed or emptied surface must fail, not drop out of the population"
    continue
  fi
  while IFS= read -r f; do
    scan_file "$f"
  done < <(find "$SURFACE_ROOT/$s" -type f 2>/dev/null | sort)
  if [ "$checked" -eq "$before" ]; then
    findings=$((findings + 1))
    _fail "surface floor: shipped surface '$s' contributed a checked file" \
      "0 checked under $SURFACE_ROOT/$s — an enumerator that reaches nothing is not a clean surface"
  fi
done

# Enumerator completeness: every shipped file the extension globs would have
# missed must be in the checked set, so the widening cannot silently regress.
INVISIBLE=""
for s in $SURFACES; do
  [ -d "$SURFACE_ROOT/$s" ] || continue
  while IFS= read -r f; do
    case "$f" in *.sh|*.md|*.json) continue ;; esac
    INVISIBLE="$INVISIBLE${f#"$SURFACE_ROOT"/}
"
  done < <(find "$SURFACE_ROOT/$s" -type f 2>/dev/null | sort)
done
inv_count=0; inv_missing=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -r "$SURFACE_ROOT/$rel" ] || continue
  inv_count=$((inv_count + 1))
  printf '%s' "$CHECKED_LIST" | grep -Fxq "$rel" && continue
  inv_missing=$((inv_missing + 1))
  findings=$((findings + 1))
  _fail "enumerator completeness: $rel is in the checked set" \
    "a shipped file no extension glob reaches was enumerated away — the surface is the shipped file set"
done <<EOF
$INVISIBLE
EOF
if [ "$inv_missing" -gt 0 ]; then :
elif [ "$inv_count" -gt 0 ]; then
  _pass "enumerator completeness: $inv_count shipped file(s) beyond the extension globs were all checked"
else
  _skip "enumerator completeness (no shipped file beyond the extension globs under $SURFACE_ROOT)"
fi

# The pinned roster is the floor under the check above: it proves that set has
# real subject matter. A synthetic surface root carries no roster of its own.
if [ "$SURFACE_ROOT" = "$REPO_ROOT" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if printf '%s' "$CHECKED_LIST" | grep -Fxq "$rel"; then
      _pass "enumerator roster: $rel is enumerated"
    else
      findings=$((findings + 1))
      _fail "enumerator roster: $rel is enumerated" \
        "absent from the checked set — either the enumerator missed it or it was deleted; update the roster deliberately"
    fi
  done <<EOF
$POSTURE_ROSTER
EOF
else
  _skip "enumerator roster pins (synthetic surface root carries no roster of its own)"
fi

if [ "$checked" -gt 0 ]; then
  [ "$findings" -eq 0 ] && _pass "R1+R2: shipped surface is messaging-posture-clean ($checked files)"
else
  if [ "$scanned" -eq 0 ]; then
    echo "$TEST_NAME: NOTHING CHECKED — no shipped surface files discovered under $SURFACE_ROOT" >&2
  else
    echo "$TEST_NAME: NOTHING CHECKED — all $scanned candidates skipped" >&2
  fi
  findings=$((findings + 1))
  _fail "K>0 floor: the scan examined at least one file" "checked=0 — a scan that scans nothing is a broken scan, not a clean surface"
fi
if [ "$scanned" -ne $((skipped_unreadable + checked)) ]; then
  echo "$TEST_NAME: INTERNAL — coverage accounting mismatch: $scanned scanned != $skipped_unreadable skipped + $checked checked" >&2
  findings=$((findings + 1))
  _fail "coverage accounting adds up (N == M + K)" "$scanned != $skipped_unreadable + $checked"
fi

# Dogfood — a detector that can only ever pass is evidence of nothing. Skipped
# under an injected surface root: the fixtures re-enter this file and recurse.
if [ -n "${NAZGUL_POSTURE_SURFACE_ROOT:-}" ]; then
  _skip "dogfood fixtures (inner run under an injected surface root)"
else
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-posture-XXXXXX"); trap 'rm -rf "$SCRATCH"' EXIT
printf 'printf x | nc -U "$CLAUDE_CODE_MESSAGING_SOCKET"\n' > "$SCRATCH/v1.sh"
grep -qE "$R2_KEY_RE" "$SCRATCH/v1.sh" \
  && _pass "dogfood: synthetic socket-poster caught by R2 predicate" \
  || _fail "dogfood: synthetic socket-poster caught by R2 predicate"
grep -qE "$R2_CONNECT_RE" "$SCRATCH/v1.sh" \
  && _pass "dogfood: the allowlisted-file connect predicate catches a piped nc -U post" \
  || _fail "dogfood: the allowlisted-file connect predicate catches a piped nc -U post"
printf 'curl --unix-socket "$SOCK" http://x/\nsocat - UNIX-CONNECT:/tmp/s\n' > "$SCRATCH/v5.sh"
grep -qE "$R2_CONNECT_RE" "$SCRATCH/v5.sh" \
  && _pass "dogfood: the connect predicate catches curl --unix-socket and socat UNIX-CONNECT" \
  || _fail "dogfood: the connect predicate catches curl --unix-socket and socat UNIX-CONNECT"
printf 'if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then command -v nc >/dev/null; fi\n' > "$SCRATCH/v6.sh"
grep -qE "$R2_CONNECT_RE" "$SCRATCH/v6.sh" \
  && _fail "dogfood: reading the value and probing for nc is not a connect" \
  || _pass "dogfood: reading the value and probing for nc is not a connect"
printf 'jq %s.crossSessionInbound="accept"%s s.json\n' "'" "'" > "$SCRATCH/v2.sh"
grep -qE "$R1_KEY_RE" "$SCRATCH/v2.sh" \
  && _pass "dogfood: synthetic posture-writer caught by R1 predicate" \
  || _fail "dogfood: synthetic posture-writer caught by R1 predicate"
grep -qE "$R1_WRITE_RE|$R1_SETTINGS_WRITE_RE" "$SCRATCH/v2.sh" \
  && _pass "dogfood: the allowlisted-file write predicate catches jq mutation syntax" \
  || _fail "dogfood: the allowlisted-file write predicate catches jq mutation syntax"
printf 'printf %s{"crossSessionInbound":"accept"}%s > ~/.claude/settings.json\n' "'" "'" > "$SCRATCH/v3.sh"
grep -qE "$R1_WRITE_RE|$R1_SETTINGS_WRITE_RE" "$SCRATCH/v3.sh" \
  && _pass "dogfood: the allowlisted-file write predicate catches a JSON-literal settings write" \
  || _fail "dogfood: the allowlisted-file write predicate catches a JSON-literal settings write"
printf 'v=$(jq -r %s.crossSessionInbound // empty%s "$f" 2>/dev/null)\n' "'" "'" > "$SCRATCH/v4.sh"
grep -qE "$R1_WRITE_RE|$R1_SETTINGS_WRITE_RE" "$SCRATCH/v4.sh" \
  && _fail "dogfood: a read of the key is not a write" \
  || _pass "dogfood: a read of the key is not a write"

# End-to-end: the regexes above prove the predicates fire; these prove the
# SCANNER does — allowlist inversion, counters, _fail emission, and exit code.
DOG="$SCRATCH/surface"
_dog_reset() {
  rm -rf "$DOG"
  # Every name in SURFACES must be materialised here or the per-surface floor fires —
  # which is the floor working, not a fixture bug. Adding a surface means adding it here.
  mkdir -p "$DOG/scripts/git-hooks" "$DOG/scripts/lib" "$DOG/skills" "$DOG/agents" \
    "$DOG/templates" "$DOG/hooks" "$DOG/references" "$DOG/.claude-plugin"
  printf '#!/usr/bin/env bash\necho ok\n' > "$DOG/scripts/x.sh"
  printf '#!/bin/sh\nexit 0\n' > "$DOG/scripts/git-hooks/pre-commit"
  printf '#!/bin/sh\nexit 0\n' > "$DOG/scripts/git-hooks/pre-merge-commit"
  printf '# skill\n' > "$DOG/skills/x.md"
  printf '# agent\n' > "$DOG/agents/x.md"
  printf '# template\n' > "$DOG/templates/CLAUDE.md.template"
  printf '{}\n' > "$DOG/hooks/hooks.json"
  printf '# reference\n' > "$DOG/references/x.md"
  printf '{"name":"x","version":"0.0.0"}\n' > "$DOG/.claude-plugin/plugin.json"
  cp "$REPO_ROOT/scripts/doctor.sh" "$DOG/scripts/doctor.sh"
  cp "$REPO_ROOT/scripts/lib/session-tracker.sh" "$DOG/scripts/lib/session-tracker.sh"
}
_dog_run() { NAZGUL_POSTURE_SURFACE_ROOT="$DOG" bash "$SCRIPT_DIR/$TEST_NAME.sh" 2>&1; }

_dog_reset
E_OUT=$(_dog_run); E_RC=$?
assert_exit_code "E0: the real read-only allowlisted files still scan clean" "$E_RC" 0
assert_contains "E0: a clean surface reports zero findings" "$E_OUT" ", 0 findings"

_dog_reset
printf 'printf x | nc -U "$CLAUDE_CODE_MESSAGING_SOCKET"\n' >> "$DOG/scripts/doctor.sh"
E_OUT=$(_dog_run); E_RC=$?
assert_contains "E1: a poster planted INSIDE an allowlisted file is a finding" \
  "$E_OUT" "R2: scripts/doctor.sh CONNECTS to the messaging socket"
assert_exit_code "E1: blocking — an allowlisted poster fails the scan" "$E_RC" 1
assert_contains "E1: counted as exactly one finding" "$E_OUT" ", 1 findings"

for rel in scripts/git-hooks/pre-commit scripts/git-hooks/pre-merge-commit templates/CLAUDE.md.template; do
  _dog_reset
  printf 'printf x | nc -U "$CLAUDE_CODE_MESSAGING_SOCKET"\n' >> "$DOG/$rel"
  E_OUT=$(_dog_run); E_RC=$?
  assert_contains "E2: $rel carries no scanned extension and is still checked" \
    "$E_OUT" "R2: $rel references the messaging socket/token outside the allowlist"
  assert_exit_code "E2: $rel — blocking" "$E_RC" 1
done

_dog_reset
printf 'jq %s.crossSessionInbound="accept"%s settings.json\n' "'" "'" >> "$DOG/templates/CLAUDE.md.template"
E_OUT=$(_dog_run); E_RC=$?
assert_contains "E3: an inbound-posture key in the injected template is a finding" \
  "$E_OUT" "R1: templates/CLAUDE.md.template names an inbound-posture settings key"
assert_exit_code "E3: blocking — R1 reaches the template too" "$E_RC" 1

_dog_reset
rm -rf "$DOG/hooks"
E_OUT=$(_dog_run); E_RC=$?
assert_contains "E4: an absent shipped surface fails the per-surface floor" \
  "$E_OUT" "surface floor: shipped surface 'hooks' exists"
assert_exit_code "E4: blocking — a vanished surface is not a clean surface" "$E_RC" 1

_dog_reset
rm -f "$DOG/hooks/hooks.json"
E_OUT=$(_dog_run); E_RC=$?
assert_contains "E5: an emptied shipped surface fails the per-surface floor" \
  "$E_OUT" "surface floor: shipped surface 'hooks' contributed a checked file"
assert_exit_code "E5: blocking — a surface that contributes nothing is not clean" "$E_RC" 1
fi

# Sibling idiom (tests/test-dispatch-brief-contract.sh:215-220): the coverage
# line is the LAST stdout line, and the verdict is the exit code.
RC=0
report_results || RC=1
printf '%s: %d scanned, %d skipped (unreadable=%d), %d checked, %d findings\n' \
  "$TEST_NAME" "$scanned" "$skipped_unreadable" "$skipped_unreadable" "$checked" "$findings"
exit "$RC"
