#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# lean-comments: allow-run — the widening lever's argument, kept at the lever (ADR-032).
# Test: FEAT-036. ONE §15 entry point, TWO derived tokens over ONE walk of scripts/** —
# the shape of the thirteenth registry member (task-transition-guard.sh) and the
# fourteenth (review-file-class.sh). The entry counts as covered only when BOTH conform.
#
#   Scan A `manifest-writers` — does any scripts/** file WRITE a task manifest other than
#     through the shared primitive (ADR-031)?
#   Scan B `status-readers` — does any scripts/** file EXTRACT a task status other than
#     through the shared reader in scripts/lib/task-utils.sh?
#
# Both populations are DERIVED from the shipped tree, never authored, so a seventh writer
# or a second hand-rolled reader is a finding on the day it lands, not a post-mortem.
#
# Three scans ask three DIFFERENT questions of the same files, and a file can pass two
# and fail the third — they are not interchangeable:
#
#   | Scan | Asks |
#   |---|---|
#   | scs_run, tests/lib/status-consumer-scan.sh | is every status CONSUMER CANCELLED-aware or enumerated-exempt? |
#   | sas_scan, tests/test-cancelled-status-consumers.sh | does any script RESTATE the vocabulary, or carry a narrow id matcher? |
#   | Scan B, this file | does any script RE-IMPLEMENT the parse? |
#
# scripts/notify.sh is the worked example: it restates no vocabulary and, since TASK-009,
# is CANCELLED-aware — yet it had re-implemented the parse. Scan B closes that gap.
#
# Boundary, stated rather than implied: the walk covers scripts/** only — shell, where a
# leading `#` is a COMMENT. In Markdown that same strip removes ATX HEADINGS, so a widened
# walk would report a clean surface it never read. skills/**, templates/**, agents/** and
# RULES.md are covered by behavioural rows in tests/test-cancelled-status-consumers.sh
# instead. Do not widen this population.
TEST_NAME="test-manifest-write-integrity"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

# lean-comments: allow-run — the duplication this file exists to remove, one level up.
# The three pieces BOTH tokens share. A second copy of the walk inside Scan B would be
# exactly the defect this objective removes, so there is one: a walk that stopped
# enumerating would have to do so for both scans at once, and each scan's independently
# derived tree-size floor is what catches that.
nz_scripts_walk() { # <tree-root> -> every file/symlink under <root>/scripts, deterministically
  find "$1/scripts" \( -type f -o -type l \) | LC_ALL=C sort
}

# The emitter asserts its own balance: a coverage line whose parts do not add up is an
# accounting defect, and it must be impossible to print one without saying so.
nz_coverage_line() { # <label> <N> <M> <skip-detail> <K> <F>
  printf '  %s: %d scanned, %d skipped (%s), %d checked, %d findings\n' "$1" "$2" "$3" "$4" "$5" "$6"
  assert_eq "$1: coverage accounting adds up (N == M + K)" "$2" "$(($3 + $5))"
}

nz_floor_check() { # <label> <value> <floor> <what> <fail-detail>
  if [ "$2" -ge "$3" ]; then
    _pass "$1: $4 ($2)"
  else
    _fail "$1: $4" "$5"
  fi
}

# What binds a write to a TASK manifest rather than to some other file.
MWI_SIGNAL='(ttg_task_manifest_path|nazgul/tasks|TASK-[^[:space:]"]*\.md)'

# lean-comments: allow-run — the false finding this arm set exists to avoid, kept at the arm set.
# What "routed" means: the primitive's own write/lock functions. NOT nz_manifest_with_lock —
# that helper runs its command in a SUBSHELL, so scripts/close-objective.sh adopted the
# primitive in the current shell instead (issue #280). A predicate keyed on that one wrapper
# reads correctly-adopted code as unadopted, which is a false finding against the very
# adoption this scan exists to prove. TASK-002 and TASK-007 use the INNER `_locked` form
# because the lock is already held; TASK-004 uses the OUTER form. Both are adoption.
MWI_ROUTE='(nz_manifest_write|nz_manifest_write_locked|nz_manifest_lock_path|_nz_acquire_lock|_nz_release_lock)'

# lean-comments: allow-run — what makes an absent entry a finding rather than a silence.
# Enumerated exemptions, each individually justified: a discovered writer that is neither
# routed nor listed here is a FINDING, not an absent entry. The shipped tree needs none
# today — every writer is routed — so this reads `*)` only, and the machinery that would
# police an entry is proved by the dogfood arms rather than left unexercised.
mwi_exemption() { # <rel-path> -> prints justification, exit 0 if exempt
  case "$1" in
    *) return 1 ;;
  esac
}

MWI_EXEMPTION_FN="${MWI_EXEMPTION_FN:-mwi_exemption}"

# Derived from the live function's own case arms rather than a second authored copy, so the
# staleness checks cannot read a list the oracle has moved past.
mwi_exemption_paths() {
  declare -f "$MWI_EXEMPTION_FN" 2>/dev/null \
    | grep -oE '^[[:space:]]*\(?scripts/[A-Za-z0-9._/-]+\)' | tr -d '() \t'
}

_mwi_listed() { # <path> <newline-list>
  case $'\n'"$2" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# lean-comments: allow-run — the half that makes this a scan and not a grep.
# mwi_file_records <file> -> zero or more of:
#   P|primitive                      the file DEFINES the primitive (never matched by name)
#   R|routed                         the file calls a primitive write/lock function
#   S|routed-site|<line>|<detail>    a manifest-shaped write target inside a routing scope
#   F|unrouted|<line>|<detail>       a manifest write by another route
#   F|undecidable|<line>|<detail>    a write verb near manifest text whose target cannot be bound
#
# A write verb alone is not a finding. The target must be BOUND to a task manifest, which is
# why scripts/stop-hook.sh's `mv "$tmp" "$file"` in _in_flight_hold_claim is not a finding:
# that `$file` is the in-flight hold LEDGER, and neither its scope nor its caller's argument
# carries a manifest signal. Binding comes from three places — the enclosing scope's own
# signal, an assignment of a manifest-shaped name from a signal, and a first argument handed
# to a callee — because the path is routinely computed in one function and written in another.
mwi_file_records() {
  awk -v sig="$MWI_SIGNAL" -v route="$MWI_ROUTE" '
    function clean(t) { gsub(/^[("\047]+/, "", t); gsub(/["\047);,]+$/, "", t); return t }
    function is_sink(t) {
      return (t ~ /^&/ || t == "/dev/null" || t == "/dev/stderr" || t == "/dev/stdout" || t ~ /^\/dev\/fd\//)
    }
    function name_shape(v) {
      v = tolower(v)
      return (v == "file" || index(v, "manifest") > 0 || index(v, "task_file") > 0)
    }
    function ident_of(t,   s) {
      s = t
      if (!match(s, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) return ""
      s = substr(s, RSTART, RLENGTH); sub(/^\$\{?/, "", s); return s
    }
    function tclass(t,   v) {
      t = clean(t)
      if (t == "" || is_sink(t)) return ""
      if (t ~ /^\$[1-9]$/) return "bound"
      v = ident_of(t)
      if (v != "" && name_shape(v)) {
        if (t == "$" v || t == "${" v "}") return "bound"
        return "loose"
      }
      if (t ~ /\$\(/ && tolower(t) ~ /manifest|task_file/) return "loose"
      return ""
    }
    function ops(s, p, out,   seg, n, i, a, k) {
      seg = substr(s, p)
      sub(/[ \t]*(;|\|\||&&|\||\)).*$/, "", seg)
      n = split(seg, a, /[ \t]+/); k = 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "" || a[i] ~ /^-/ || a[i] ~ /[<>]/) continue
        out[++k] = a[i]
      }
      return k
    }
    function record(tok, verb,   c, key) {
      c = tclass(tok); if (c == "") return
      key = scope SUBSEP FNR SUBSEP verb SUBSEP clean(tok) SUBSEP c
      if (key in seen) return
      seen[key] = 1; recs[++recn] = key
    }
    function scan_verb(s, pat, verb, which,   p, o, k, i) {
      p = 1
      while (p <= length(s) && match(substr(s, p), pat)) {
        o = p + RSTART - 1 + RLENGTH
        delete O; k = ops(s, o, O)
        if (k > 0) {
          if (which == "first") record(O[1], verb)
          else if (which == "last") record(O[k], verb)
          else for (i = 1; i <= k; i++) record(O[i], verb)
        }
        p = o
      }
    }
    BEGIN { scope = "<toplevel>" }
    /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/ {
      s = $0; sub(/^[ \t]*(function[ \t]+)?/, "", s); sub(/[ \t]*\(\).*$/, "", s); scope = s
    }
    /^\}/ { scope = "<toplevel>" }
    /^[ \t]*#/ { next }
    # By DEFINING the primitive, never by filename — a rename must not satisfy this scan.
    /^nz_manifest_write_locked[ \t]*\(\)/ { prim = 1 }
    $0 ~ sig   { sigs[scope] = 1 }
    $0 ~ route { routed[scope] = 1; filerouted = 1 }
    {
      line = $0
      if (match(line, /(^|[ \t;&|(!])(local[ \t]+|export[ \t]+|declare[ \t]+-[a-zA-Z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        lhs = substr(line, RSTART, RLENGTH)
        sub(/^[ \t;&|(!]?(local[ \t]+|export[ \t]+|declare[ \t]+-[a-zA-Z]+[ \t]+)?/, "", lhs); sub(/=$/, "", lhs)
        rhs = substr(line, RSTART + RLENGTH)
        if (name_shape(lhs)) {
          if (rhs ~ sig) assign[scope SUBSEP lhs] = "sig"
          else if (rhs ~ /^"?\$\{?1\}?"?([ \t]|$)/ && !((scope SUBSEP lhs) in assign)) assign[scope SUBSEP lhs] = "p1"
        }
      }
      if (match(line, /^[ \t]*for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]/)) {
        lv = substr(line, RSTART, RLENGTH); sub(/^[ \t]*for[ \t]+/, "", lv); sub(/[ \t]+in[ \t]$/, "", lv)
        if (name_shape(lv) && substr(line, RSTART + RLENGTH) ~ sig) assign[scope SUBSEP lv] = "sig"
      }
      if (match(line, /(^|[ \t;&|(])[A-Za-z_][A-Za-z0-9_]*[ \t]+"?\$/)) {
        cs = substr(line, RSTART, RLENGTH)
        sub(/^[ \t;&|(]/, "", cs); sub(/[ \t]+"?\$$/, "", cs)
        delete O
        if (ops(line, RSTART + RLENGTH - 1, O) > 0) calls[++calln] = cs SUBSEP scope SUBSEP clean(O[1])
      }
      p = 1
      while (match(substr(line, p), ">>?[ \t]*[^ \t;&|]+")) {
        tok = substr(line, p + RSTART - 1, RLENGTH); p = p + RSTART - 1 + RLENGTH
        sub(/^>>?[ \t]*/, "", tok); record(tok, "redirect")
      }
      scan_verb(line, "(^|[ \t;&|(])mv[ \t]", "mv", "last")
      scan_verb(line, "(^|[ \t;&|(])cp[ \t]", "cp", "last")
      scan_verb(line, "(^|[ \t;&|(])tee[ \t]", "tee", "all")
      scan_verb(line, "sed[ \t]+-i[^ \t]*[ \t]", "sed -i", "last")
      scan_verb(line, "nz_rewrite_file[ \t]", "nz_rewrite_file", "first")
      scan_verb(line, "set_task_status[ \t]", "set_task_status", "first")
    }
    function tokbound(sc, tok,   v) {
      if (tok ~ /^\$[1-9]$/) return (sc in pbind)
      v = ident_of(tok); if (v == "" || !name_shape(v)) return 0
      if (sc in sigs) return 1
      if ((sc SUBSEP v) in assign) {
        if (assign[sc SUBSEP v] == "sig") return 1
        if (assign[sc SUBSEP v] == "p1" && (sc in pbind)) return 1
      }
      if (("<toplevel>" SUBSEP v) in assign && assign["<toplevel>" SUBSEP v] == "sig") return 1
      return 0
    }
    END {
      for (r = 0; r < 3; r++)
        for (i = 1; i <= calln; i++) {
          split(calls[i], C, SUBSEP)
          if (!(C[1] in pbind) && tokbound(C[2], C[3])) pbind[C[1]] = 1
        }
      if (prim) print "P|primitive"
      if (filerouted) print "R|routed"
      for (i = 1; i <= recn; i++) {
        split(recs[i], A, SUBSEP)
        sc = A[1]; ln = A[2]; verb = A[3]; tgt = A[4]; kind = A[5]
        if (kind == "loose") {
          if (sc in sigs) print "F|undecidable|" ln "|" sc "(): " verb " target " tgt " cannot be bound to a manifest"
          continue
        }
        if (!tokbound(sc, tgt)) continue
        if (sc in routed) print "S|routed-site|" ln "|" sc "(): " verb " " tgt
        else print "F|unrouted|" ln "|" sc "(): " verb " writes " tgt " outside nz_manifest_write*"
      }
    }
  ' "$1"
}

# lean-comments: allow-run — why the disposition has more than two answers.
# mwi_scan <tree-root> — the SINGLE driver: the shipped-tree arm and every dogfood arm go
# through it. Three answers, not two (RULES §15 / ADR-009): `no-write-verb` is a skip that
# states its reason, `undecidable` is a FINDING rather than a quiet allow, and `primitive`
# is a skip earned by DEFINING nz_manifest_write_locked.
# Walked on fd 9 so a caller's full stdin cannot truncate the population.
mwi_scan() {
  local root="$1" f rel out line rest kind ln nf local_findings kinds p
  MWI_N=0; MWI_M=0; MWI_K=0; MWI_F=0
  MWI_M_NOWRITE=0; MWI_M_PRIMITIVE=0; MWI_M_UNREADABLE=0
  MWI_CHECKED=""; MWI_ROUTED=""; MWI_EXEMPT=""; MWI_UNROUTED=""; MWI_UNDECIDABLE=""
  MWI_PRIMITIVE=""; MWI_FINDINGS=""; MWI_RETIRED=""; MWI_ORPHANED=""; MWI_CLASSES=""

  [ -d "$root/scripts" ] || return 1

  while IFS= read -r -u 9 f; do
    rel="${f#"$root"/}"
    MWI_N=$((MWI_N + 1))
    if [ ! -r "$f" ]; then
      MWI_M=$((MWI_M + 1)); MWI_M_UNREADABLE=$((MWI_M_UNREADABLE + 1))
      MWI_CLASSES="${MWI_CLASSES}${rel}|unreadable"$'\n'
      continue
    fi
    out=$(mwi_file_records "$f")
    if grep -qF 'P|primitive' <<< "$out"; then
      MWI_M=$((MWI_M + 1)); MWI_M_PRIMITIVE=$((MWI_M_PRIMITIVE + 1))
      MWI_PRIMITIVE="${MWI_PRIMITIVE}${rel}"$'\n'
      MWI_CLASSES="${MWI_CLASSES}${rel}|primitive"$'\n'
      continue
    fi
    if [ -z "$out" ]; then
      MWI_M=$((MWI_M + 1)); MWI_M_NOWRITE=$((MWI_M_NOWRITE + 1))
      MWI_CLASSES="${MWI_CLASSES}${rel}|no-write-verb"$'\n'
      continue
    fi
    MWI_K=$((MWI_K + 1)); MWI_CHECKED="${MWI_CHECKED}${rel}"$'\n'
    nf=0; local_findings=""; kinds=""
    while IFS= read -r line; do
      case "$line" in
        "F|"*)
          rest="${line#F|}"; kind="${rest%%|*}"; rest="${rest#*|}"; ln="${rest%%|*}"
          nf=$((nf + 1))
          local_findings="${local_findings}${rel}:${kind}:${ln}:${rest#*|}"$'\n'
          kinds="${kinds}${kind} " ;;
      esac
    done <<< "$out"
    if "$MWI_EXEMPTION_FN" "$rel" >/dev/null; then
      if [ "$nf" -eq 0 ]; then
        MWI_RETIRED="${MWI_RETIRED}${rel}"$'\n'; MWI_F=$((MWI_F + 1))
        MWI_CLASSES="${MWI_CLASSES}${rel}|retired"$'\n'
      else
        MWI_EXEMPT="${MWI_EXEMPT}${rel}"$'\n'
        MWI_CLASSES="${MWI_CLASSES}${rel}|exempt"$'\n'
      fi
    elif [ "$nf" -gt 0 ]; then
      MWI_F=$((MWI_F + nf)); MWI_FINDINGS="${MWI_FINDINGS}${local_findings}"
      case "$kinds" in *unrouted*) MWI_UNROUTED="${MWI_UNROUTED}${rel}"$'\n' ;; esac
      case "$kinds" in *undecidable*) MWI_UNDECIDABLE="${MWI_UNDECIDABLE}${rel}"$'\n' ;; esac
      case "$kinds" in
        *unrouted*) MWI_CLASSES="${MWI_CLASSES}${rel}|unrouted"$'\n' ;;
        *)          MWI_CLASSES="${MWI_CLASSES}${rel}|undecidable"$'\n' ;;
      esac
    else
      MWI_ROUTED="${MWI_ROUTED}${rel}"$'\n'
      MWI_CLASSES="${MWI_CLASSES}${rel}|routed"$'\n'
    fi
  done 9< <(nz_scripts_walk "$root")

  # Staleness, both directions: an exemption naming a path this walk never checked states a
  # fact that expired, exactly as one naming a path that has since adopted the primitive does.
  while IFS= read -r -u 9 p; do
    [ -n "$p" ] || continue
    _mwi_listed "$p" "$MWI_CHECKED" && continue
    MWI_ORPHANED="${MWI_ORPHANED}${p}"$'\n'; MWI_F=$((MWI_F + 1))
  done 9< <(mwi_exemption_paths)
  return 0
}

mwi_class_of() { # <rel-path> -> the class this walk assigned it, or "absent"
  local rel="$1" line
  while IFS= read -r line; do
    [ "${line%%|*}" = "$rel" ] && { printf '%s\n' "${line#*|}"; return 0; }
  done <<< "$MWI_CLASSES"
  printf 'absent\n'
}

mwi_coverage_line() { # <label>
  nz_coverage_line "$1" "$MWI_N" "$MWI_M" \
    "$(printf 'no-write-verb=%d, primitive=%d, unreadable=%d' "$MWI_M_NOWRITE" "$MWI_M_PRIMITIVE" "$MWI_M_UNREADABLE")" \
    "$MWI_K" "$MWI_F"
}

# --- The shipped tree ---

if ! mwi_scan "$REPO_ROOT"; then
  _fail "manifest-writers: the shipped tree is walkable" "no scripts/ directory under $REPO_ROOT"
else
  while IFS= read -r mwi_hit; do
    [ -n "$mwi_hit" ] || continue
    _fail "manifest-writers [${mwi_hit%%:*}]: writes a task manifest through the shared primitive" \
      "${mwi_hit#*:}" \
      "  fix: route the write through nz_manifest_write / nz_manifest_write_locked (ADR-031)"
  done <<< "$MWI_FINDINGS"
  while IFS= read -r mwi_stale; do
    [ -n "$mwi_stale" ] || continue
    _fail "manifest-writers [${mwi_stale}]: its exemption is RETIRED — it now routes through the primitive" \
      "remove the arm from mwi_exemption; an exemption that outlives its defect hides the next one"
  done <<< "$MWI_RETIRED"
  while IFS= read -r mwi_orphan; do
    [ -n "$mwi_orphan" ] || continue
    _fail "manifest-writers [${mwi_orphan}]: its exemption is ORPHANED — the walk never checked that path" \
      "remove the arm from mwi_exemption, or fix the path it names"
  done <<< "$MWI_ORPHANED"

  mwi_coverage_line "manifest-writers"
  assert_eq "manifest-writers: no shipped script writes a task manifest outside the primitive" \
    "$MWI_F" "0"

  # K > 0 BLOCKS. A predicate that stopped matching would skip every candidate and report a
  # clean tree — the exact failure this scan exists to prevent.
  nz_floor_check "manifest-writers" "$MWI_K" 1 "the predicate still matches its subjects" \
    "0 files checked — a collapsed predicate, not a clean tree"

  # Independently derived, because equality between two runs of the SAME walk cannot see a
  # collapse that happens in both.
  MWI_TREE_SIZE=$(find "$REPO_ROOT/scripts" \( -type f -o -type l \) | wc -l | tr -d ' ')
  assert_eq "manifest-writers: the walk reached every file an independent find sees" \
    "$MWI_N" "$MWI_TREE_SIZE"
  nz_floor_check "manifest-writers" "$MWI_N" "${NAZGUL_MANIFEST_WRITER_TREE_FLOOR:-60}" \
    "the walk actually reached the tree" \
    "only $MWI_N file(s) scanned — a broken walk, not a small tree"
  assert_eq "manifest-writers: the primitive was found and skipped, exactly once" \
    "$MWI_M_PRIMITIVE" "1"
fi

# --- The six adopters, named one by one (AC-5) ---

for mwi_adopter in \
  scripts/task-transition.sh \
  scripts/lib/task-transition-guard.sh \
  scripts/stop-hook.sh \
  scripts/close-objective.sh \
  scripts/red-run.sh; do
  assert_eq "adopter [$mwi_adopter]: classified routed, not merely unexamined" \
    "$(mwi_class_of "$mwi_adopter")" "routed"
  assert_not_contains "adopter [$mwi_adopter]: carries no unrouted manifest write" \
    "$MWI_FINDINGS" "$mwi_adopter:"
done
assert_eq "adopter [scripts/lib/manifest-write.sh]: skipped as the primitive it defines" \
  "$(mwi_class_of scripts/lib/manifest-write.sh)" "primitive"

# --- The calibration set: excluded ON TARGET, never on filename ---

assert_eq "calibration [scripts/lib/review-provenance.sh]: its mv targets a review dispatch manifest, not a task one" \
  "$(mwi_class_of scripts/lib/review-provenance.sh)" "no-write-verb"
assert_eq "calibration [scripts/teammate-idle-guard.sh]: its \$MANIFEST is a dispatch record, not a task manifest" \
  "$(mwi_class_of scripts/teammate-idle-guard.sh)" "no-write-verb"
assert_not_contains "calibration: neither is a finding" "$MWI_FINDINGS" "review-provenance.sh:"
assert_not_contains "calibration: neither is a finding (idle guard)" "$MWI_FINDINGS" "teammate-idle-guard.sh:"

# stop-hook.sh's `mv "$tmp" "$file"` in _in_flight_hold_claim writes the in-flight hold
# LEDGER — excluded because nothing binds that $file to a manifest, not by filename.
MWI_HOLD_RECORDS=$(mwi_file_records "$REPO_ROOT/scripts/stop-hook.sh")
assert_not_contains "calibration [scripts/stop-hook.sh]: the hold-ledger mv is not a manifest write" \
  "$MWI_HOLD_RECORDS" "_in_flight_hold_claim"
assert_not_contains "calibration [scripts/stop-hook.sh]: and the file yields no finding at all" \
  "$MWI_HOLD_RECORDS" "F|"
assert_contains "calibration [scripts/stop-hook.sh]: it is nonetheless recognised as a routed writer" \
  "$MWI_HOLD_RECORDS" "R|routed"

# --- Dogfood (AC-6): one violator per write shape, in a scratch tree ---

# lean-comments: allow-run — why the planted tree is the only place these arms can run.
# The shipped tree is all-clean, so every finding arm above would otherwise never execute:
# a scan that finds nothing because its pattern matches nothing is the defect this objective
# exists to remove. Each control below is RECORDED as having fired, not assumed.
MWI_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-manifest-writers-XXXXXX")
mkdir -p "$MWI_SCRATCH/scripts/lib"
{
  printf '#!/usr/bin/env bash\n'
  printf 'nz_manifest_write_locked() {\n  local state_root="$1" task_id="$2"\n  return 0\n}\n'
  printf 'nz_manifest_write() { nz_manifest_write_locked "$@"; }\n'
} > "$MWI_SCRATCH/scripts/lib/manifest-write.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$MWI_SCRATCH/scripts/clean.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'nz_manifest_write "$STATE" "$TASK_ID" -- producer\n'
} > "$MWI_SCRATCH/scripts/routed-writer.sh"
# The calibration shape, planted: a write verb on a $file bound to nothing manifest-shaped.
{
  printf '#!/usr/bin/env bash\n'
  printf 'ledger_claim() {\n  local file="$1"\n  mv "$tmp" "$file"\n}\n'
  printf 'ledger_claim "$LEDGER_PATH"\n'
} > "$MWI_SCRATCH/scripts/ledger-writer.sh"

mwi_scan "$MWI_SCRATCH"
mwi_coverage_line "dogfood-clean"
assert_eq "dogfood: a clean planted tree yields no findings" "$MWI_F" "0"
assert_eq "dogfood: the primitive is skipped by DEFINING the write function, not by its name" \
  "$MWI_M_PRIMITIVE" "1"
assert_eq "dogfood: a file that only calls the primitive is routed, and checked" \
  "$(mwi_class_of scripts/routed-writer.sh)" "routed"
assert_eq "dogfood: a write verb whose target binds to no manifest is skipped, on target" \
  "$(mwi_class_of scripts/ledger-writer.sh)" "no-write-verb"
MWI_CLEAN_N="$MWI_N"

# A file NAMED like the primitive but not defining it must not inherit the skip.
printf '#!/usr/bin/env bash\nMANIFEST="$STATE/nazgul/tasks/$T.md"\nprintf x > "$MANIFEST"\n' \
  > "$MWI_SCRATCH/scripts/lib/manifest-write-helper.sh"
mwi_scan "$MWI_SCRATCH"
assert_eq "dogfood: a look-alike filename that defines nothing is NOT skipped as the primitive" \
  "$MWI_M_PRIMITIVE" "1"
assert_eq "dogfood: and it is caught as a writer" \
  "$(mwi_class_of scripts/lib/manifest-write-helper.sh)" "unrouted"
rm -f "$MWI_SCRATCH/scripts/lib/manifest-write-helper.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'printf "%%s" "$out" > "$MANIFEST"\n'
} > "$MWI_SCRATCH/scripts/violator-redirect.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'manifest="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'printf -- "- **Blocked reason**: x\\n" >> "$manifest"\n'
} > "$MWI_SCRATCH/scripts/violator-append.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'task_file="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'mv "$tmp" "$task_file"\n'
} > "$MWI_SCRATCH/scripts/violator-mv.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'TASK_FILE=$(ttg_task_manifest_path "$NAZGUL_DIR" "$TASK_ID")\n'
  printf 'set_task_status "$TASK_FILE" READY IN_PROGRESS\n'
} > "$MWI_SCRATCH/scripts/violator-set-status.sh"
# The third answer: a write verb beside manifest text whose target cannot be bound.
{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'mv "$tmp" "${MANIFEST%%%%.md}.md"\n'
} > "$MWI_SCRATCH/scripts/violator-undecidable.sh"

mwi_scan "$MWI_SCRATCH"
mwi_coverage_line "dogfood-planted"
assert_eq "dogfood: all five planted violators are found, and only those five" "$MWI_F" "5"
assert_contains "dogfood: the redirect violator is named by file and kind" \
  "$MWI_FINDINGS" "scripts/violator-redirect.sh:unrouted"
assert_contains "dogfood: and by the verb and target it used" \
  "$MWI_FINDINGS" 'redirect writes $MANIFEST'
assert_contains "dogfood: the append violator is named by file and kind" \
  "$MWI_FINDINGS" "scripts/violator-append.sh:unrouted"
assert_contains "dogfood: and its verb is the append, not a truncating redirect" \
  "$MWI_FINDINGS" 'redirect writes $manifest'
assert_contains "dogfood: the mv violator is named by file and kind" \
  "$MWI_FINDINGS" "scripts/violator-mv.sh:unrouted"
assert_contains "dogfood: and by the verb it used" "$MWI_FINDINGS" 'mv writes $task_file'
assert_contains "dogfood: the set_task_status violator is named by file and kind" \
  "$MWI_FINDINGS" "scripts/violator-set-status.sh:unrouted"
assert_contains "dogfood: and by the verb it used" \
  "$MWI_FINDINGS" 'set_task_status writes $TASK_FILE'
assert_contains "dogfood: the unbindable target is a FINDING, not a quiet allow" \
  "$MWI_FINDINGS" "scripts/violator-undecidable.sh:undecidable"
assert_eq "dogfood: the unbindable target is classified undecidable, not unrouted" \
  "$(mwi_class_of scripts/violator-undecidable.sh)" "undecidable"
assert_eq "dogfood: the clean and routed files are untouched by the plant" \
  "$(mwi_class_of scripts/routed-writer.sh)" "routed"
MWI_PLANTED_N="$MWI_N"

rm -f "$MWI_SCRATCH/scripts/violator-redirect.sh" "$MWI_SCRATCH/scripts/violator-append.sh" \
  "$MWI_SCRATCH/scripts/violator-mv.sh" "$MWI_SCRATCH/scripts/violator-set-status.sh" \
  "$MWI_SCRATCH/scripts/violator-undecidable.sh"
mwi_scan "$MWI_SCRATCH"
mwi_coverage_line "dogfood-removed"
assert_eq "dogfood: removing the violators returns the scan to zero findings" "$MWI_F" "0"
assert_eq "dogfood: and the walk returned to its pre-plant size, not the planted one" \
  "$MWI_N" "$MWI_CLEAN_N"
if [ "$MWI_PLANTED_N" -gt "$MWI_CLEAN_N" ]; then
  _pass "dogfood: the planted walk was strictly larger than the cleaned one ($MWI_PLANTED_N > $MWI_CLEAN_N)"
else
  _fail "dogfood: the planted walk was strictly larger than the cleaned one" \
    "planted=$MWI_PLANTED_N cleaned=$MWI_CLEAN_N — the removal changed nothing the walk could see"
fi
if [ "$MWI_K" -gt 0 ]; then
  _pass "dogfood: the cleaned tree still checks something ($MWI_K checked)"
else
  _fail "dogfood: the cleaned tree still checks something" "K collapsed to 0"
fi

# --- Staleness, both directions, dogfooded on the same tree ---

mwi_exemption_retired() {
  case "$1" in
    scripts/routed-writer.sh) echo "planted: names a path that has since adopted the primitive" ;;
    *) return 1 ;;
  esac
}
MWI_EXEMPTION_FN=mwi_exemption_retired
mwi_scan "$MWI_SCRATCH"
assert_contains "staleness: an exemption naming an adopted path is RETIRED, and a finding" \
  "$MWI_RETIRED" "scripts/routed-writer.sh"
assert_eq "staleness: the retired exemption is counted as a finding" "$MWI_F" "1"

mwi_exemption_orphan() {
  case "$1" in
    scripts/gone.sh) echo "planted: names a path this walk never reached" ;;
    *) return 1 ;;
  esac
}
MWI_EXEMPTION_FN=mwi_exemption_orphan
mwi_scan "$MWI_SCRATCH"
assert_contains "staleness: an exemption naming an unwalked path is ORPHANED, and a finding" \
  "$MWI_ORPHANED" "scripts/gone.sh"
assert_eq "staleness: the orphaned exemption is counted as a finding" "$MWI_F" "1"

mwi_exemption_live() {
  case "$1" in
    scripts/violator-mv.sh) echo "planted: a real writer, individually justified" ;;
    *) return 1 ;;
  esac
}
printf '#!/usr/bin/env bash\ntask_file="$STATE/nazgul/tasks/$T.md"\nmv "$tmp" "$task_file"\n' \
  > "$MWI_SCRATCH/scripts/violator-mv.sh"
MWI_EXEMPTION_FN=mwi_exemption_live
mwi_scan "$MWI_SCRATCH"
assert_eq "exemption: an enumerated writer is checked and suppressed, not skipped" \
  "$(mwi_class_of scripts/violator-mv.sh)" "exempt"
assert_eq "exemption: and it contributes no finding" "$MWI_F" "0"
assert_contains "exemption: the paths are derived from the live function's own case arms" \
  "$(mwi_exemption_paths)" "scripts/violator-mv.sh"
MWI_EXEMPTION_FN=mwi_exemption
rm -f "$MWI_SCRATCH/scripts/violator-mv.sh"

# --- The walk survives a caller whose stdin is already full (fd 9) ---

MWI_STDIN_FILLER=$(mktemp "${TMPDIR:-/tmp}/nazgul-mwi-stdin-XXXXXX")
awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line" }' > "$MWI_STDIN_FILLER"
mwi_scan "$MWI_SCRATCH" < "$MWI_STDIN_FILLER"
MWI_STDIN_N="$MWI_N"
mwi_scan "$MWI_SCRATCH" < /dev/null
assert_eq "determinism: a caller's full stdin cannot truncate the walk (dedicated fd)" \
  "$MWI_STDIN_N" "$MWI_N"
rm -f "$MWI_STDIN_FILLER"
rm -rf "$MWI_SCRATCH"

# lean-comments: allow-run — the second token's own widening lever, kept at the lever.
# Scan B — `status-readers`. Does any scripts/** file extract a task status other than
# through the shared reader (scripts/lib/task-utils.sh:get_task_status)? Same walk, same
# comment strip, same here-strings, same derived exemption paths as Scan A.
#
# The manifest signal is Scan A's, verbatim, because "which file is a task manifest" is one
# question and must not acquire two answers in one entry point.
SRI_SIGNAL="$MWI_SIGNAL"

# The shared reader's entry points. A hand-rolled FIELD read is not this scan's subject —
# scripts/self-audit.sh parses `- **Retry count**:`; what is reserved here is the STATUS parse.
SRI_ROUTE='(get_task_status|read_task_status|count_tasks_by_status|count_tasks_and_find_active|get_active_task|has_status_frontmatter)'

# lean-comments: allow-run — why the field half is spelled without a backslash.
# What makes a read a STATUS read: the status field in any documented manifest format, or a
# status token in the pattern. `[Ss]tatus[^A-Za-z0-9_]*:` covers `status:`, `## Status:` and
# BOTH spellings of the list-item form — a shell literal writes it `Status\*\*:`, so a
# bracketed `[*][*]` matches the rendered manifest and misses every script that reads it.
SRI_STATUS='([Ss]tatus[^A-Za-z0-9_]*:|##[[:space:]]*[Ss]tatus|PLANNED|READY|IN_PROGRESS|IMPLEMENTED|IN_REVIEW|APPROVED|CHANGES_REQUESTED|DONE|BLOCKED|CANCELLED)'

# lean-comments: allow-run — what makes an absent entry a finding rather than a silence.
# Enumerated exemptions, individually justified: a discovered reader that is neither routed
# nor listed here is a FINDING. scripts/git-hooks/pre-commit is deliberately NOT listed —
# it reads no status at all, so an arm naming it would be ORPHANED by this scan's own
# staleness rule, and the row below proves that rather than asserting it.
sri_exemption() { # <rel-path> -> prints justification, exit 0 if exempt
  case "$1" in
    scripts/git-hooks/pre-merge-commit)
      echo "installed into the managed core.hooksPath dir and runs against arbitrary checkouts, where scripts/lib/task-utils.sh may not exist — it cannot source the authority, so it replicates the frontmatter-first precedence instead; the behavioural row below drives the SHIPPED function and asserts it agrees with get_task_status" ;;
    *) return 1 ;;
  esac
  return 0
}

SRI_EXEMPTION_FN="${SRI_EXEMPTION_FN:-sri_exemption}"

# Derived from the live function's own case arms, exactly as Scan A's is, so the staleness
# checks cannot read a list the oracle has moved past.
sri_exemption_paths() {
  declare -f "$SRI_EXEMPTION_FN" 2>/dev/null \
    | grep -oE '^[[:space:]]*\(?scripts/[A-Za-z0-9._/-]+\)' | tr -d '() \t'
}

# lean-comments: allow-run — the binding half, and the two rules that differ from Scan A.
# sri_file_records <file> -> zero or more of:
#   A|authority                       the file DEFINES the vocabulary or the reader
#   R|routed|<line>|<scope>           the file calls a shared-reader entry point
#   F|hand-rolled|<line>|<detail>     a status parse bound to a task manifest
#   F|undecidable|<line>|<detail>     a status read near manifest text whose subject cannot be bound
#
# Binding is Scan A's, from the same three sources — the enclosing scope's own signal, an
# assignment from a signal (file-wide for a global), and a first argument handed to a callee.
# TWO rules differ, and both were measured rather than assumed:
#   * name_shape is dropped. Scan A binds only `file`/`*manifest*`/`*task_file*` identifiers;
#     the one real hand-rolled reader in the tree holds its path in `tf`, and a name filter
#     reads it as a clean file. That is the #284 failure direction: silent, and dressed as
#     "looked and found none".
#   * There is no routed-site suppression. A write near nz_manifest_write IS the primitive's
#     own call; a hand parse near get_task_status is still a hand parse, so a routed scope
#     suppresses nothing and `routed` only ever explains why a file is CHECKED.
# lean-comments: allow-run — the scan's stated limit, kept at the scan.
# Boundary, stated rather than implied: a site is detected where the status pattern and the
# manifest-bound subject meet on one logical line (single-quoted programs are joined across
# lines first). A `while read … done < "$manifest"` whose status test lives in the loop body
# is outside that. The shipped tree contains no such site — every manifest-bound input
# redirect under scripts/** is the write primitive's own hash read — and the shape is caught
# the moment the parse is written as a read verb.
sri_file_records() {
  awk -v sig="$SRI_SIGNAL" -v route="$SRI_ROUTE" -v statpat="$SRI_STATUS" '
    function clean(t) { gsub(/^[("\047]+/, "", t); gsub(/["\047);,]+$/, "", t); return t }
    function is_sink(t) {
      return (t ~ /^&/ || t == "/dev/null" || t == "/dev/stderr" || t == "/dev/stdout" || t ~ /^\/dev\/fd\//)
    }
    function ident_of(t,   s) {
      s = t
      if (!match(s, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) return ""
      s = substr(s, RSTART, RLENGTH); sub(/^\$\{?/, "", s); return s
    }
    function tclass(t,   v) {
      t = clean(t)
      if (t == "" || is_sink(t)) return ""
      if (t ~ sig) return "direct"
      if (t ~ /^\$[1-9]$/) return "param"
      v = ident_of(t)
      if (v != "") { if (t == "$" v || t == "${" v "}") return "var"; return "loose" }
      if (t ~ /\$\(/) return "loose"
      return ""
    }
    # A read verb carries its PROGRAM as an operand, full of ; | ) — Scan A splits on
    # whitespace and truncates the command before the file operand, losing the one real reader.
    function ops(s, p, out,   i, n, ch, prev, cur, inq, depth, k, raw, j, m) {
      n = length(s); k = 0; m = 0; cur = ""; inq = ""; depth = 0; prev = ""
      delete raw
      for (i = p; i <= n; i++) {
        ch = substr(s, i, 1)
        if (inq != "") { cur = cur ch; if (ch == inq) inq = ""; prev = ch; continue }
        if (ch == "\047" || ch == "\"") { inq = ch; cur = cur ch; prev = ch; continue }
        if (ch == "(" && prev == "$") { depth++; cur = cur ch; prev = ch; continue }
        if (ch == ")") { if (depth > 0) { depth--; cur = cur ch; prev = ch; continue } break }
        if (depth == 0 && (ch == ";" || ch == "|" || ch == "&")) break
        if (ch == " " || ch == "\t") { if (cur != "") { raw[++m] = cur; cur = "" } prev = ch; continue }
        cur = cur ch; prev = ch
      }
      if (cur != "") raw[++m] = cur
      for (j = 1; j <= m; j++) {
        if (raw[j] == "<<<") { j++; continue }
        if (raw[j] ~ /^-/ || raw[j] ~ /[<>]/) continue
        out[++k] = raw[j]
      }
      return k
    }
    function record(tok, verb, ln,   c, key) {
      c = tclass(tok); if (c == "") return
      key = scope SUBSEP ln SUBSEP verb SUBSEP clean(tok) SUBSEP c
      if (key in seen) return
      seen[key] = 1; recs[++recn] = key
    }
    # minops = 2 for grep/sed/awk: with one operand the subject is STDIN, not a file, which
    # is why scripts/heartbeat.sh piping a relayed BLOCKED_TASK signal into grep is not a read.
    function scan_verb(s, pat, verb, ln, minops,   p, o, k) {
      p = 1
      while (p <= length(s) && match(substr(s, p), pat)) {
        o = p + RSTART - 1 + RLENGTH
        delete O; k = ops(s, o, O)
        if (k >= minops) record(O[k], verb, ln)
        p = o
      }
    }
    function odd_quotes(l,   t) { t = l; return (gsub(/\047/, "", t) % 2) }
    function process(s, ln) {
      if (s !~ statpat) return
      scan_verb(s, "(^|[ \t;&|(=$])grep[ \t]", "grep", ln, 2)
      scan_verb(s, "(^|[ \t;&|(=$])sed[ \t]",  "sed",  ln, 2)
      scan_verb(s, "(^|[ \t;&|(=$])awk[ \t]",  "awk",  ln, 2)
      scan_verb(s, "(^|[ \t;&|(=$])cat[ \t]",  "cat",  ln, 1)
      scan_verb(s, "(^|[ \t;&|(=$])head[ \t]", "head", ln, 1)
      scan_verb(s, "(^|[ \t;&|(=$])tail[ \t]", "tail", ln, 1)
    }
    BEGIN { scope = "<toplevel>" }
    /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/ {
      s = $0; sub(/^[ \t]*(function[ \t]+)?/, "", s); sub(/[ \t]*\(\).*$/, "", s); scope = s
    }
    /^\}/ { scope = "<toplevel>" }
    joining {
      buf = buf " " $0
      if (odd_quotes($0)) { joining = 0; process(buf, bufln) }
      next
    }
    /^[ \t]*#/ { next }
    # By DEFINING the vocabulary or the reader, never by filename — a rename must not satisfy
    # this scan. Same rule sas_scan already uses for scripts/lib/structured-state.sh.
    /^[ \t]*(VALID_STATUSES=|get_task_status[ \t]*\(\)|read_task_status[ \t]*\(\))/ { auth = 1 }
    $0 ~ sig   { sigs[scope] = 1 }
    $0 ~ route { rl[++rn] = scope SUBSEP FNR; filerouted = 1 }
    {
      line = $0
      if (match(line, /(^|[ \t;&|(!])(local[ \t]+|export[ \t]+|declare[ \t]+-[a-zA-Z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        lhs = substr(line, RSTART, RLENGTH)
        sub(/^[ \t;&|(!]?(local[ \t]+|export[ \t]+|declare[ \t]+-[a-zA-Z]+[ \t]+)?/, "", lhs); sub(/=$/, "", lhs)
        rhs = substr(line, RSTART + RLENGTH)
        if (rhs ~ sig) assign[scope SUBSEP lhs] = "sig"
        else if (rhs ~ /^"?\$\{?1\}?"?([ \t]|$)/ && !((scope SUBSEP lhs) in assign)) assign[scope SUBSEP lhs] = "p1"
      }
      if (match(line, /^[ \t]*for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]/)) {
        lv = substr(line, RSTART, RLENGTH); sub(/^[ \t]*for[ \t]+/, "", lv); sub(/[ \t]+in[ \t]$/, "", lv)
        if (substr(line, RSTART + RLENGTH) ~ sig) assign[scope SUBSEP lv] = "sig"
      }
      if (match(line, /(^|[ \t;&|(])[A-Za-z_][A-Za-z0-9_]*[ \t]+"?\$/)) {
        cs = substr(line, RSTART, RLENGTH)
        sub(/^[ \t;&|(]/, "", cs); sub(/[ \t]+"?\$$/, "", cs)
        delete O
        if (ops(line, RSTART + RLENGTH - 1, O) > 0) calls[++calln] = cs SUBSEP scope SUBSEP clean(O[1])
      }
      if (line ~ /(^|[ \t;&|(=$])(grep|sed|awk|cat|head|tail)[ \t]/ && odd_quotes(line)) {
        joining = 1; buf = line; bufln = FNR; next
      }
      process(line, FNR)
    }
    function tokbound(sc, tok, c,   v) {
      if (c == "direct") return 1
      if (c == "param") return (sc in pbind)
      v = ident_of(tok); if (v == "") return 0
      if ((sc SUBSEP v) in assign) {
        if (assign[sc SUBSEP v] == "sig") return 1
        if (assign[sc SUBSEP v] == "p1" && (sc in pbind)) return 1
      }
      if (("<toplevel>" SUBSEP v) in assign && assign["<toplevel>" SUBSEP v] == "sig") return 1
      if (sc in sigs) return 1
      return 0
    }
    END {
      for (r = 0; r < 3; r++)
        for (i = 1; i <= calln; i++) {
          split(calls[i], C, SUBSEP)
          if (!(C[1] in pbind) && tokbound(C[2], C[3], tclass(C[3]))) pbind[C[1]] = 1
        }
      if (auth) print "A|authority"
      for (i = 1; i <= rn; i++) { split(rl[i], Q, SUBSEP); print "R|routed|" Q[2] "|" Q[1] "()" }
      for (i = 1; i <= recn; i++) {
        split(recs[i], A, SUBSEP)
        sc = A[1]; ln = A[2]; verb = A[3]; tgt = A[4]; kind = A[5]
        if (kind == "loose") {
          if (sc in sigs) print "F|undecidable|" ln "|" sc "(): " verb " subject " tgt " cannot be bound to a manifest"
          continue
        }
        if (!tokbound(sc, tgt, kind)) continue
        print "F|hand-rolled|" ln "|" sc "(): " verb " parses a task status out of " tgt " instead of calling get_task_status"
      }
    }
  ' "$1"
}

# lean-comments: allow-run — why the disposition has more than two answers.
# sri_scan <tree-root> — the SINGLE driver: the shipped-tree arm and every dogfood arm go
# through it. Three skip reasons, each stating itself (RULES §15 / ADR-009): `no-status-read`
# is a file that never reads a status, `authority` is earned by DEFINING the vocabulary or
# the reader, and `unreadable` is a file the walk reached but could not open.
# Walked on fd 9, through the same nz_scripts_walk Scan A uses.
sri_scan() {
  local root="$1" f rel out line rest kind ln nf local_findings kinds p
  SRI_N=0; SRI_M=0; SRI_K=0; SRI_F=0
  SRI_M_NOREAD=0; SRI_M_AUTHORITY=0; SRI_M_UNREADABLE=0
  SRI_CHECKED=""; SRI_ROUTED=""; SRI_EXEMPT=""; SRI_HANDROLLED=""; SRI_UNDECIDABLE=""
  SRI_AUTHORITY=""; SRI_FINDINGS=""; SRI_RETIRED=""; SRI_ORPHANED=""; SRI_CLASSES=""

  [ -d "$root/scripts" ] || return 1

  while IFS= read -r -u 9 f; do
    rel="${f#"$root"/}"
    SRI_N=$((SRI_N + 1))
    if [ ! -r "$f" ]; then
      SRI_M=$((SRI_M + 1)); SRI_M_UNREADABLE=$((SRI_M_UNREADABLE + 1))
      SRI_CLASSES="${SRI_CLASSES}${rel}|unreadable"$'\n'
      continue
    fi
    out=$(sri_file_records "$f")
    if grep -qF 'A|authority' <<< "$out"; then
      SRI_M=$((SRI_M + 1)); SRI_M_AUTHORITY=$((SRI_M_AUTHORITY + 1))
      SRI_AUTHORITY="${SRI_AUTHORITY}${rel}"$'\n'
      SRI_CLASSES="${SRI_CLASSES}${rel}|authority"$'\n'
      continue
    fi
    if [ -z "$out" ]; then
      SRI_M=$((SRI_M + 1)); SRI_M_NOREAD=$((SRI_M_NOREAD + 1))
      SRI_CLASSES="${SRI_CLASSES}${rel}|no-status-read"$'\n'
      continue
    fi
    SRI_K=$((SRI_K + 1)); SRI_CHECKED="${SRI_CHECKED}${rel}"$'\n'
    nf=0; local_findings=""; kinds=""
    while IFS= read -r line; do
      case "$line" in
        "F|"*)
          rest="${line#F|}"; kind="${rest%%|*}"; rest="${rest#*|}"; ln="${rest%%|*}"
          nf=$((nf + 1))
          local_findings="${local_findings}${rel}:${kind}:${ln}:${rest#*|}"$'\n'
          kinds="${kinds}${kind} " ;;
      esac
    done <<< "$out"
    if "$SRI_EXEMPTION_FN" "$rel" >/dev/null; then
      if [ "$nf" -eq 0 ]; then
        SRI_RETIRED="${SRI_RETIRED}${rel}"$'\n'; SRI_F=$((SRI_F + 1))
        SRI_CLASSES="${SRI_CLASSES}${rel}|retired"$'\n'
      else
        SRI_EXEMPT="${SRI_EXEMPT}${rel}"$'\n'
        SRI_CLASSES="${SRI_CLASSES}${rel}|exempt"$'\n'
      fi
    elif [ "$nf" -gt 0 ]; then
      SRI_F=$((SRI_F + nf)); SRI_FINDINGS="${SRI_FINDINGS}${local_findings}"
      case "$kinds" in *hand-rolled*) SRI_HANDROLLED="${SRI_HANDROLLED}${rel}"$'\n' ;; esac
      case "$kinds" in *undecidable*) SRI_UNDECIDABLE="${SRI_UNDECIDABLE}${rel}"$'\n' ;; esac
      case "$kinds" in
        *hand-rolled*) SRI_CLASSES="${SRI_CLASSES}${rel}|hand-rolled"$'\n' ;;
        *)             SRI_CLASSES="${SRI_CLASSES}${rel}|undecidable"$'\n' ;;
      esac
    else
      SRI_ROUTED="${SRI_ROUTED}${rel}"$'\n'
      SRI_CLASSES="${SRI_CLASSES}${rel}|routed"$'\n'
    fi
  done 9< <(nz_scripts_walk "$root")

  # Staleness, both directions: an exemption naming a path this walk never checked states a
  # fact that expired, exactly as one naming a path that has since adopted the reader does.
  while IFS= read -r -u 9 p; do
    [ -n "$p" ] || continue
    _mwi_listed "$p" "$SRI_CHECKED" && continue
    SRI_ORPHANED="${SRI_ORPHANED}${p}"$'\n'; SRI_F=$((SRI_F + 1))
  done 9< <(sri_exemption_paths)
  return 0
}

sri_class_of() { # <rel-path> -> the class this walk assigned it, or "absent"
  local rel="$1" line
  while IFS= read -r line; do
    [ "${line%%|*}" = "$rel" ] && { printf '%s\n' "${line#*|}"; return 0; }
  done <<< "$SRI_CLASSES"
  printf 'absent\n'
}

sri_coverage_line() { # <label>
  nz_coverage_line "$1" "$SRI_N" "$SRI_M" \
    "$(printf 'no-status-read=%d, authority=%d, unreadable=%d' "$SRI_M_NOREAD" "$SRI_M_AUTHORITY" "$SRI_M_UNREADABLE")" \
    "$SRI_K" "$SRI_F"
}

# --- Scan B on the shipped tree ---

if ! sri_scan "$REPO_ROOT"; then
  _fail "status-readers: the shipped tree is walkable" "no scripts/ directory under $REPO_ROOT"
else
  while IFS= read -r sri_hit; do
    [ -n "$sri_hit" ] || continue
    _fail "status-readers [${sri_hit%%:*}]: reads a task status through the shared reader" \
      "${sri_hit#*:}" \
      "  fix: source scripts/lib/task-utils.sh and call get_task_status (AC-9)"
  done <<< "$SRI_FINDINGS"
  while IFS= read -r sri_stale; do
    [ -n "$sri_stale" ] || continue
    _fail "status-readers [${sri_stale}]: its exemption is RETIRED — it now reads through the authority" \
      "remove the arm from sri_exemption; an exemption that outlives its defect hides the next one"
  done <<< "$SRI_RETIRED"
  while IFS= read -r sri_orphan; do
    [ -n "$sri_orphan" ] || continue
    _fail "status-readers [${sri_orphan}]: its exemption is ORPHANED — the walk never checked that path" \
      "remove the arm from sri_exemption, or fix the path it names"
  done <<< "$SRI_ORPHANED"

  sri_coverage_line "status-readers"
  assert_eq "status-readers: no shipped script parses a task status outside the authority" \
    "$SRI_F" "0"

  # K > 0 BLOCKS. A predicate that stopped matching would skip every candidate and report a
  # clean tree — the exact failure this scan exists to prevent.
  nz_floor_check "status-readers" "$SRI_K" 1 "the predicate still matches its subjects" \
    "0 files checked — a collapsed predicate, not a clean tree"

  # Independently derived, because equality between two runs of the SAME walk cannot see a
  # collapse that happens in both.
  SRI_TREE_SIZE=$(find "$REPO_ROOT/scripts" \( -type f -o -type l \) | wc -l | tr -d ' ')
  assert_eq "status-readers: the walk reached every file an independent find sees" \
    "$SRI_N" "$SRI_TREE_SIZE"
  nz_floor_check "status-readers" "$SRI_N" "${NAZGUL_STATUS_READER_TREE_FLOOR:-60}" \
    "the walk actually reached the tree" \
    "only $SRI_N file(s) scanned — a broken walk, not a small tree"
  assert_eq "status-readers: both tokens walked the same population" "$SRI_N" "${MWI_TREE_SIZE:-0}"
fi

# --- The authority, by definition and by census ---

# lean-comments: allow-run — the hole a by-definition rule leaves, closed by name.
# The skip is earned by DEFINING VALID_STATUSES / get_task_status / read_task_status, so a
# rename cannot satisfy the scan. The residual is the mirror image: a THIRD file could claim
# the skip by defining one of them, and that is precisely how a hand-rolled reader would hide.
# The census is therefore pinned — two files, and exactly these two.
assert_eq "authority [scripts/lib/task-utils.sh]: skipped for defining get_task_status (TASK-008)" \
  "$(sri_class_of scripts/lib/task-utils.sh)" "authority"
assert_eq "authority [scripts/lib/structured-state.sh]: skipped for defining VALID_STATUSES" \
  "$(sri_class_of scripts/lib/structured-state.sh)" "authority"
assert_eq "authority: exactly two files define the vocabulary or the reader" \
  "$SRI_M_AUTHORITY" "2"
assert_eq "authority: and they are exactly those two" \
  "$SRI_AUTHORITY" "scripts/lib/structured-state.sh"$'\n'"scripts/lib/task-utils.sh"$'\n'
assert_contains "authority [scripts/lib/task-utils.sh]: carries the shared counters TASK-008 introduced" \
  "$(sri_file_records "$REPO_ROOT/scripts/lib/task-utils.sh")" "count_tasks_and_find_active()"

# --- Every routed reader, named one by one (AC-9) ---

for sri_reader in \
  scripts/board-sync-github.sh \
  scripts/close-objective.sh \
  scripts/lib/manifest-write.sh \
  scripts/lib/parallel-batch.sh \
  scripts/lib/task-transition-guard.sh \
  scripts/notify.sh \
  scripts/parallel-dispatch-guard.sh \
  scripts/parallel-rework-guard.sh \
  scripts/post-compact.sh \
  scripts/pre-compact.sh \
  scripts/scrub-stale-review-artifacts.sh \
  scripts/session-context.sh \
  scripts/stop-hook.sh \
  scripts/task-state-guard.sh \
  scripts/task-transition.sh \
  scripts/webhook-forward.sh; do
  assert_eq "reader [$sri_reader]: classified routed, not merely unexamined" \
    "$(sri_class_of "$sri_reader")" "routed"
  assert_not_contains "reader [$sri_reader]: carries no hand-rolled status parse" \
    "$SRI_FINDINGS" "$sri_reader:"
done

# scripts/notify.sh is the file the third question was written for: CANCELLED-aware since
# TASK-009 and restating no vocabulary, yet it had re-implemented the parse.
assert_contains "reader [scripts/notify.sh]: reaches its counts through count_tasks_and_find_active (TASK-009)" \
  "$(sri_file_records "$REPO_ROOT/scripts/notify.sh")" "R|routed"
assert_not_contains "reader [scripts/notify.sh]: and carries no parse of its own" \
  "$(sri_file_records "$REPO_ROOT/scripts/notify.sh")" "F|"

# --- The calibration set: excluded ON TARGET, never on filename ---

assert_eq "calibration [scripts/self-audit.sh]: hand-parses Retry count, which is a FIELD read, not a status read" \
  "$(sri_class_of scripts/self-audit.sh)" "no-status-read"
assert_eq "calibration [scripts/lib/review-evidence.sh]: its status-shaped tokens are review VERDICTS" \
  "$(sri_class_of scripts/lib/review-evidence.sh)" "no-status-read"
assert_eq "calibration [scripts/heartbeat.sh]: its BLOCKED_TASK grep reads a relayed halt signal on stdin, not a manifest" \
  "$(sri_class_of scripts/heartbeat.sh)" "no-status-read"
assert_eq "calibration [scripts/lib/stack-utils.sh]: its CHANGES_REQUESTED is a GitHub reviewDecision" \
  "$(sri_class_of scripts/lib/stack-utils.sh)" "no-status-read"
assert_not_contains "calibration: none of them is a finding" "$SRI_FINDINGS" "self-audit.sh:"
assert_not_contains "calibration: none of them is a finding (review-evidence)" "$SRI_FINDINGS" "review-evidence.sh:"
assert_not_contains "calibration: none of them is a finding (heartbeat)" "$SRI_FINDINGS" "heartbeat.sh:"

# ADR-032: the population stays scripts/** — a leading-# strip removes Markdown HEADINGS, so
# TASK-010 pinned this prose with executing rows in tests/test-cancelled-status-consumers.sh.
assert_eq "population [skills/start/SKILL.md]: outside this walk by decision, covered behaviourally (TASK-010)" \
  "$(sri_class_of skills/start/SKILL.md)" "absent"

# --- The one exemption, and the one deliberately withheld ---

assert_eq "exemption [scripts/git-hooks/pre-merge-commit]: checked and suppressed, not skipped" \
  "$(sri_class_of scripts/git-hooks/pre-merge-commit)" "exempt"
SRI_PMC_RECORDS=$(sri_file_records "$REPO_ROOT/scripts/git-hooks/pre-merge-commit")
assert_contains "exemption [pre-merge-commit]: its frontmatter awk is found by line and verb" \
  "$SRI_PMC_RECORDS" "task_status(): awk parses a task status"
assert_contains "exemption [pre-merge-commit]: and so is its list-item grep fallback" \
  "$SRI_PMC_RECORDS" "task_status(): grep parses a task status"
assert_contains "exemption [pre-merge-commit]: it carries a written justification" \
  "$(sri_exemption scripts/git-hooks/pre-merge-commit)" "cannot source the authority"

# lean-comments: allow-run — the row that makes the exemption a decision rather than a hole.
# The justification claims the replica agrees with the authority. That is checked, not
# asserted: the SHIPPED task_status is extracted from the hook and run beside get_task_status
# over both formats it replicates. A drift here is a finding against the exemption itself.
SRI_PMC_FN=$(awk '/^task_status\(\)[ \t]*\{/{f=1} f{print} f && /^\}/{exit}' \
  "$REPO_ROOT/scripts/git-hooks/pre-merge-commit")
SRI_PMC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-status-readers-pmc-XXXXXX")
printf -- '---\nstatus: IN_REVIEW\n---\n# TASK-001\n- **Status**: DONE\n' > "$SRI_PMC_DIR/frontmatter.md"
printf -- '# TASK-002\n- **Status**: CANCELLED\n' > "$SRI_PMC_DIR/list-item.md"
# The expected value is named, so "both returned empty" cannot pass as agreement; the fixture
# hides a STALE `- **Status**: DONE` under a live `status:`, so agreement is about precedence.
for sri_fixture in frontmatter:IN_REVIEW list-item:CANCELLED; do
  sri_fx="${sri_fixture%%:*}"; sri_want="${sri_fixture##*:}"
  SRI_PMC_OUT=$(bash -c '
    set -uo pipefail
    source "$1/scripts/lib/task-utils.sh"
    eval "$2"
    printf "%s|%s\n" "$(task_status "$3")" "$(get_task_status "$3" "")"
  ' _ "$REPO_ROOT" "$SRI_PMC_FN" "$SRI_PMC_DIR/${sri_fx}.md" 2>/dev/null) || SRI_PMC_OUT="err|err"
  assert_eq "exemption [pre-merge-commit]: its replica agrees with get_task_status on the ${sri_fx} format" \
    "$SRI_PMC_OUT" "${sri_want}|${sri_want}"
done
rm -rf "$SRI_PMC_DIR"

# lean-comments: allow-run — the second git-hook, and why enumerating it would be the hole.
# scripts/git-hooks/pre-commit shares pre-merge-commit's constraint but reads no task status
# at all — it gates on branch.feature and the current branch. An exemption naming it would
# assert a defect that does not exist, and this scan's own staleness rule says so: the arm is
# installed here on purpose and the walk reports it ORPHANED.
assert_eq "calibration [scripts/git-hooks/pre-commit]: reads no status, so it is skipped, not exempted" \
  "$(sri_class_of scripts/git-hooks/pre-commit)" "no-status-read"
if sri_exemption scripts/git-hooks/pre-commit >/dev/null 2>&1; then
  _fail "exemption [scripts/git-hooks/pre-commit]: is deliberately NOT enumerated" \
    "an arm names a path that reads no status — that is an exemption for a defect that does not exist"
else
  _pass "exemption [scripts/git-hooks/pre-commit]: is deliberately NOT enumerated"
fi
sri_exemption_precommit() {
  case "$1" in
    scripts/git-hooks/pre-commit) echo "planted: names a path that reads no status" ;;
    *) return 1 ;;
  esac
}
SRI_EXEMPTION_FN=sri_exemption_precommit
sri_scan "$REPO_ROOT"
assert_contains "exemption [scripts/git-hooks/pre-commit]: and enumerating it IS reported, as ORPHANED" \
  "$SRI_ORPHANED" "scripts/git-hooks/pre-commit"
SRI_EXEMPTION_FN=sri_exemption
sri_scan "$REPO_ROOT"

# --- Dogfood: one violator per read shape, in a scratch tree ---

# lean-comments: allow-run — why the planted tree is the only place these arms can run.
# The shipped tree has exactly one hand-rolled reader and it is exempt, so every finding arm
# above would otherwise never execute. Each control below is RECORDED as having fired.
SRI_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-status-readers-XXXXXX")
mkdir -p "$SRI_SCRATCH/scripts/lib"
# The shipped exemption names a path no scratch tree contains, which this scan correctly calls
# ORPHANED — so the planted trees carry their own empty oracle and count only their violators.
sri_exemption_none() { case "$1" in *) return 1 ;; esac; }
SRI_EXEMPTION_FN=sri_exemption_none
{
  printf '#!/usr/bin/env bash\n'
  printf 'VALID_STATUSES="PLANNED READY DONE CANCELLED"\n'
  printf 'read_task_status() {\n  local file="$1"\n  return 0\n}\n'
  printf 'get_task_status() { read_task_status "$@"; }\n'
} > "$SRI_SCRATCH/scripts/lib/task-utils.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$SRI_SCRATCH/scripts/clean.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'st=$(get_task_status "$MANIFEST" "")\n'
} > "$SRI_SCRATCH/scripts/routed-reader.sh"
# The calibration shape, planted: a status-shaped grep whose subject is STDIN, not a manifest.
{
  printf '#!/usr/bin/env bash\n'
  printf 'relay() {\n  local out="$1"\n  printf "%%s\\n" "$out" | grep -q "^BLOCKED_TASK"\n}\n'
  printf 'relay "$HALT_OUT"\n'
} > "$SRI_SCRATCH/scripts/stdin-reader.sh"
# And the field shape: a hand-rolled manifest read that is not a STATUS read.
{
  printf '#!/usr/bin/env bash\n'
  printf 'retries() {\n  local f="$STATE/nazgul/tasks/$1.md"\n'
  printf '  grep -E "^- [*][*]Retry count[*][*]:" "$f" | head -1\n}\n'
} > "$SRI_SCRATCH/scripts/field-reader.sh"

sri_scan "$SRI_SCRATCH"
sri_coverage_line "dogfood-clean"
assert_eq "dogfood: a clean planted tree yields no findings" "$SRI_F" "0"
assert_eq "dogfood: the authority is skipped by DEFINING the vocabulary, not by its name" \
  "$SRI_M_AUTHORITY" "1"
assert_eq "dogfood: a file that only calls the shared reader is routed, and checked" \
  "$(sri_class_of scripts/routed-reader.sh)" "routed"
assert_eq "dogfood: a status-shaped grep reading stdin is skipped, on target" \
  "$(sri_class_of scripts/stdin-reader.sh)" "no-status-read"
assert_eq "dogfood: a hand-rolled read of a NON-status field is skipped, on target" \
  "$(sri_class_of scripts/field-reader.sh)" "no-status-read"
SRI_CLEAN_N="$SRI_N"

# A file NAMED like the authority but defining neither the vocabulary nor the reader must not
# inherit the skip — that is how a rename would satisfy the scan.
{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$T.md"\n'
  printf 'grep -m1 "^status:" "$MANIFEST"\n'
} > "$SRI_SCRATCH/scripts/lib/task-utils-helper.sh"
sri_scan "$SRI_SCRATCH"
assert_eq "dogfood: a look-alike filename that defines nothing is NOT skipped as the authority" \
  "$SRI_M_AUTHORITY" "1"
assert_eq "dogfood: and it is caught as a reader" \
  "$(sri_class_of scripts/lib/task-utils-helper.sh)" "hand-rolled"
rm -f "$SRI_SCRATCH/scripts/lib/task-utils-helper.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'st=$(grep -E "Status.*DONE" "$MANIFEST")\n'
} > "$SRI_SCRATCH/scripts/violator-grep.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'manifest="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'st=$(sed -n "s/^status:[[:space:]]*//p" "$manifest")\n'
} > "$SRI_SCRATCH/scripts/violator-sed.sh"
# The multi-line program: the shape a line-oriented scan loses its file operand to.
{
  printf '#!/usr/bin/env bash\n'
  printf 'read_it() {\n  local tf="$1"\n'
  printf "  awk '/^---\$/{fm++; next}\n"
  printf "     fm==1 && /^status:/{print; exit}' \"\$tf\"\n"
  printf '}\n'
  printf 'read_it "$STATE/nazgul/tasks/$TASK_ID.md"\n'
} > "$SRI_SCRATCH/scripts/violator-multiline.sh"
# The case shape: a case never reads a file, so what is caught is the read verb inside it.
{
  printf '#!/usr/bin/env bash\n'
  printf 'is_done() {\n  local task_file="$1"\n'
  printf '  case "$(grep -m1 "^status:" "$task_file")" in\n'
  printf '    *DONE*) return 0 ;;\n  esac\n  return 1\n}\n'
  printf 'is_done "$STATE/nazgul/tasks/$TASK_ID.md"\n'
} > "$SRI_SCRATCH/scripts/violator-case.sh"
# The third answer: a status read beside manifest text whose subject cannot be bound.
{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$TASK_ID.md"\n'
  printf 'grep -m1 "^status:" "${MANIFEST%%%%.md}.md"\n'
} > "$SRI_SCRATCH/scripts/violator-undecidable.sh"

sri_scan "$SRI_SCRATCH"
sri_coverage_line "dogfood-planted"
assert_eq "dogfood: all five planted violators are found, and only those five" "$SRI_F" "5"
assert_contains "dogfood: the grep violator is named by file and kind" \
  "$SRI_FINDINGS" "scripts/violator-grep.sh:hand-rolled"
assert_contains "dogfood: and by the verb and subject it used" \
  "$SRI_FINDINGS" 'grep parses a task status out of $MANIFEST'
assert_contains "dogfood: the sed violator is named by file and kind" \
  "$SRI_FINDINGS" "scripts/violator-sed.sh:hand-rolled"
assert_contains "dogfood: and by the verb it used" \
  "$SRI_FINDINGS" 'sed parses a task status out of $manifest'
assert_contains "dogfood: the multi-line awk violator is named by file and kind" \
  "$SRI_FINDINGS" "scripts/violator-multiline.sh:hand-rolled"
assert_contains "dogfood: and by the verb it used, through a joined logical line" \
  "$SRI_FINDINGS" 'awk parses a task status out of $tf'
assert_contains "dogfood: the case violator is caught by the read verb inside it" \
  "$SRI_FINDINGS" "scripts/violator-case.sh:hand-rolled"
assert_contains "dogfood: and by the verb it used" \
  "$SRI_FINDINGS" 'grep parses a task status out of $task_file'
assert_contains "dogfood: the unbindable subject is a FINDING, not a quiet allow" \
  "$SRI_FINDINGS" "scripts/violator-undecidable.sh:undecidable"
assert_eq "dogfood: the unbindable subject is classified undecidable, not hand-rolled" \
  "$(sri_class_of scripts/violator-undecidable.sh)" "undecidable"
assert_eq "dogfood: the clean and routed files are untouched by the plant" \
  "$(sri_class_of scripts/routed-reader.sh)" "routed"
SRI_PLANTED_N="$SRI_N"

rm -f "$SRI_SCRATCH/scripts/violator-grep.sh" "$SRI_SCRATCH/scripts/violator-sed.sh" \
  "$SRI_SCRATCH/scripts/violator-multiline.sh" "$SRI_SCRATCH/scripts/violator-case.sh" \
  "$SRI_SCRATCH/scripts/violator-undecidable.sh"
sri_scan "$SRI_SCRATCH"
sri_coverage_line "dogfood-removed"
assert_eq "dogfood: removing the violators returns the scan to zero findings" "$SRI_F" "0"
assert_eq "dogfood: and the walk returned to its pre-plant size, not the planted one" \
  "$SRI_N" "$SRI_CLEAN_N"
if [ "$SRI_PLANTED_N" -gt "$SRI_CLEAN_N" ]; then
  _pass "dogfood: the planted walk was strictly larger than the cleaned one ($SRI_PLANTED_N > $SRI_CLEAN_N)"
else
  _fail "dogfood: the planted walk was strictly larger than the cleaned one" \
    "planted=$SRI_PLANTED_N cleaned=$SRI_CLEAN_N — the removal changed nothing the walk could see"
fi
nz_floor_check "dogfood" "$SRI_K" 1 "the cleaned tree still checks something" "K collapsed to 0"

# --- Staleness, both directions, dogfooded on the same tree ---

sri_exemption_retired() {
  case "$1" in
    scripts/routed-reader.sh) echo "planted: names a path that has since adopted the reader" ;;
    *) return 1 ;;
  esac
}
SRI_EXEMPTION_FN=sri_exemption_retired
sri_scan "$SRI_SCRATCH"
assert_contains "staleness: an exemption naming an adopted path is RETIRED, and a finding" \
  "$SRI_RETIRED" "scripts/routed-reader.sh"
assert_eq "staleness: the retired exemption is counted as a finding" "$SRI_F" "1"

sri_exemption_orphan() {
  case "$1" in
    scripts/gone.sh) echo "planted: names a path this walk never reached" ;;
    *) return 1 ;;
  esac
}
SRI_EXEMPTION_FN=sri_exemption_orphan
sri_scan "$SRI_SCRATCH"
assert_contains "staleness: an exemption naming an unwalked path is ORPHANED, and a finding" \
  "$SRI_ORPHANED" "scripts/gone.sh"
assert_eq "staleness: the orphaned exemption is counted as a finding" "$SRI_F" "1"

sri_exemption_live() {
  case "$1" in
    scripts/violator-grep.sh) echo "planted: a real reader, individually justified" ;;
    *) return 1 ;;
  esac
}
{
  printf '#!/usr/bin/env bash\n'
  printf 'MANIFEST="$STATE/nazgul/tasks/$T.md"\n'
  printf 'grep -E "Status.*DONE" "$MANIFEST"\n'
} > "$SRI_SCRATCH/scripts/violator-grep.sh"
SRI_EXEMPTION_FN=sri_exemption_live
sri_scan "$SRI_SCRATCH"
assert_eq "exemption: an enumerated reader is checked and suppressed, not skipped" \
  "$(sri_class_of scripts/violator-grep.sh)" "exempt"
assert_eq "exemption: and it contributes no finding" "$SRI_F" "0"
assert_contains "exemption: the paths are derived from the live function's own case arms" \
  "$(sri_exemption_paths)" "scripts/violator-grep.sh"
SRI_EXEMPTION_FN=sri_exemption_none
rm -f "$SRI_SCRATCH/scripts/violator-grep.sh"

# --- Scan B's walk survives a caller whose stdin is already full (fd 9) ---

SRI_STDIN_FILLER=$(mktemp "${TMPDIR:-/tmp}/nazgul-sri-stdin-XXXXXX")
awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line" }' > "$SRI_STDIN_FILLER"
sri_scan "$SRI_SCRATCH" < "$SRI_STDIN_FILLER"
SRI_STDIN_N="$SRI_N"
sri_scan "$SRI_SCRATCH" < /dev/null
assert_eq "determinism: a caller's full stdin cannot truncate Scan B's walk (dedicated fd)" \
  "$SRI_STDIN_N" "$SRI_N"
rm -f "$SRI_STDIN_FILLER"
rm -rf "$SRI_SCRATCH"


report_results
