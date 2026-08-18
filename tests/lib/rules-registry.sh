#!/usr/bin/env bash
# RULES.md §15's registry of bound coverage-honesty entry points, DERIVED from the
# document that declares it. Shared so a test cannot re-author the denominator it
# is checking (tests/lib/status-consumer-scan.sh is the same shape for consumers).
#
# The bullet names its driver too; $REGISTRY_DRIVER_REL is dropped by identity,
# never by pattern, and a caller that sets nothing drops nothing.

_registry_bullet() {
  awk '/^- \*\*The registry of bound entry points lives HERE/{f=1} f{print} f && /^$/{exit}' "$1"
}

_registry_members() {
  _registry_bullet "$1" | grep -oE '`[^`]+`' | tr -d '`' | awk '{print $1}' \
    | grep -E '^(scripts|tests|agents)/.*\.(sh|md)$' \
    | grep -vxF "${REGISTRY_DRIVER_REL:-}" | awk '!seen[$0]++'
}

# A registry path to the name its coverage line prints, read from the file's OWN emitter
# when that slot is a literal; basename is the fallback, never a per-member table.
_registry_token() {
  local rel="$1" root="${2:-}" lit="" b
  if [ -n "$root" ] && [ -r "$root/$rel" ]; then
    lit=$(grep -oE "(^|[^%[:alnum:]._/-])[A-Za-z][A-Za-z0-9._/-]*: ($REGISTRY_COUNT_SLOT_RE) scanned," "$root/$rel" 2>/dev/null \
      | awk 'NR==1{sub(/^[^A-Za-z]*/, ""); sub(/:.*/, ""); sub(/\/.*/, ""); print}')
  fi
  if [ -n "$lit" ]; then printf '%s\n' "$lit"; return 0; fi
  b="${rel##*/}"; b="${b%.sh}"; b="${b%.md}"
  printf '%s\n' "${b%-guard}"
}

# The §15 grammar as a PRODUCER writes it: unresolved count slots (`%d`, or `<N>` in an
# agent spec), so an assertion on a literal line is not mistaken for a mechanism.
REGISTRY_COUNT_SLOT_RE='%[0-9]*d|<[A-Za-z]+>'
REGISTRY_EMITTER_RE="($REGISTRY_COUNT_SLOT_RE) scanned, ($REGISTRY_COUNT_SLOT_RE) skipped \\([^)]*\\), ($REGISTRY_COUNT_SLOT_RE) [a-z]+, ($REGISTRY_COUNT_SLOT_RE) [a-z]+"

# The shipped trees a §15 emitter can live in. `tests` is scanned deliberately: its
# emitters are SKIPPED by name below rather than left outside the denominator.
REGISTRY_EMITTER_SURFACES="scripts skills agents templates hooks references .claude-plugin tests"

# _registry_emitter_scan <root> [surfaces] -> "<state>\t<rel>" per file, state being
# `emitter` (its text produces a §15 line) or `unreadable` (it could not be asked).
_registry_emitter_scan() {
  local root="$1" surfaces="${2:-$REGISTRY_EMITTER_SURFACES}" s f rel
  for s in $surfaces; do
    [ -d "$root/$s" ] || continue
    find "$root/$s" -type f 2>/dev/null
  done | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$root"/}"
    if [ ! -r "$f" ]; then
      printf 'unreadable\t%s\n' "$rel"
    elif grep -qE "$REGISTRY_EMITTER_RE" "$f" 2>/dev/null; then
      printf 'emitter\t%s\n' "$rel"
    fi
  done
}

# The bullet states its own size in words; a list that has outgrown it is a doc
# contradicting itself, which is a finding here rather than a silent re-count.
_registry_declared_count() {
  local w
  w=$(_registry_bullet "$1" \
    | grep -oE '(Five|Six|Seven|Eight|Nine|Ten|Eleven|Twelve|Thirteen|Fourteen|Fifteen|Sixteen|Seventeen|Eighteen|Nineteen|Twenty) entry points are bound' \
    | awk 'NR==1{print $1}')   # not `head -1`: it SIGPIPEs its producer (#230)
  case "$w" in
    Five) echo 5 ;; Six) echo 6 ;; Seven) echo 7 ;; Eight) echo 8 ;; Nine) echo 9 ;;
    Ten) echo 10 ;; Eleven) echo 11 ;; Twelve) echo 12 ;; Thirteen) echo 13 ;;
    Fourteen) echo 14 ;; Fifteen) echo 15 ;; Sixteen) echo 16 ;; Seventeen) echo 17 ;;
    Eighteen) echo 18 ;; Nineteen) echo 19 ;; Twenty) echo 20 ;;
    *) echo "" ;;
  esac
}

# _registry_missing <newline-tokens> <space-covered> — tokens with no driver.
_registry_missing() {
  local tok
  for tok in $1; do
    case " $2 " in *" $tok "*) ;; *) printf '%s\n' "$tok" ;; esac
  done
}

