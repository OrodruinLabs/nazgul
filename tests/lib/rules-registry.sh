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

# A registry path to the name its coverage line actually prints.
_registry_token() {
  local b="${1##*/}"; b="${b%.sh}"; b="${b%.md}"
  printf '%s\n' "${b%-guard}"
}

# The bullet states its own size in words; a list that has outgrown it is a doc
# contradicting itself, which is a finding here rather than a silent re-count.
_registry_declared_count() {
  local w
  w=$(_registry_bullet "$1" \
    | grep -oE '(Five|Six|Seven|Eight|Nine|Ten|Eleven|Twelve|Thirteen|Fourteen|Fifteen|Sixteen|Seventeen|Eighteen|Nineteen|Twenty) entry points are bound' \
    | head -1 | awk '{print $1}')
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

