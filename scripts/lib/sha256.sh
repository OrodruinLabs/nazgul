#!/usr/bin/env bash
# Nazgul sha256 helper — the ONE copy of the sha256sum/shasum fallback body.
#
# Extracted (#254 C-i) because two hooks carried byte-identical copies of it
# behind contradictory recorded rationales: one said "duplicated rather than
# sourcing the review-gate provenance lib", the other said "uses the shared
# helper rather than reimplementing". Both objections were to depending on
# ~248 lines of REVIEW-GATE tooling, not to sourcing per se, so the body moved
# to a single-purpose micro-lib on the scripts/lib/nazgul-root.sh precedent:
# a hook that needs only a digest sources this and nothing else.
# scripts/lib/review-provenance.sh keeps `_rp_sha256` as a thin alias, so its
# callers (the stop-hook DONE gate, review-evidence, task-transition-guard)
# are untouched.
#
# No top-level side effects. NOT `set -euo pipefail` — this file is SOURCED into
# hook shells and must not alter their options.
#
# RE-SOURCE GUARD: an ARRAY marker, not a scalar. A scalar guard is FORGEABLE — the
# environment can export `_NAZGUL_SHA256_SOURCED=1` and the `return 0` fires before
# nz_sha256 is ever defined, so every caller silently degrades its digest to
# `unavailable` with nothing to indicate why. Arrays cannot be exported, so this
# marker can only come from an actual earlier source of this file. Same idiom and
# same reason as scripts/lib/review-file-class.sh; pinned by tests/test-bounded-net.sh.

[ "${_NZ_SHA256_LOADED[1]:-}" = "loaded" ] && return 0
_NZ_SHA256_LOADED=(0 loaded)

# Reads stdin, prints the 64-char lowercase hex digest. Returns 1 rather than
# aborting when neither tool exists, so a caller under `set -e` can degrade.
nz_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}
