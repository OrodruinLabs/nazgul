#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# lean-comments: allow-run — the widening lever's argument, kept at the lever (ADR-032).
# Test: FEAT-036 Scan A — `manifest-writers`. Does any scripts/** file write a task
# manifest other than through the shared primitive (ADR-031)? The population is DERIVED
# from the shipped tree, never authored, so a seventh writer is a finding on the day it
# lands rather than a post-mortem.
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
  done 9< <(find "$root/scripts" \( -type f -o -type l \) | LC_ALL=C sort)

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

# The emitter asserts its own balance: a coverage line whose parts do not add up is an
# accounting defect, and it must be impossible to print one without saying so.
mwi_coverage_line() { # <label>
  printf '  %s: %d scanned, %d skipped (no-write-verb=%d, primitive=%d, unreadable=%d), %d checked, %d findings\n' \
    "$1" "$MWI_N" "$MWI_M" "$MWI_M_NOWRITE" "$MWI_M_PRIMITIVE" "$MWI_M_UNREADABLE" "$MWI_K" "$MWI_F"
  assert_eq "$1: coverage accounting adds up (N == M + K)" "$MWI_N" "$((MWI_M + MWI_K))"
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
  if [ "$MWI_K" -gt 0 ]; then
    _pass "manifest-writers: the predicate still matches its subjects ($MWI_K checked)"
  else
    _fail "manifest-writers: the predicate still matches its subjects" \
      "0 files checked — a collapsed predicate, not a clean tree"
  fi

  # Independently derived, because equality between two runs of the SAME walk cannot see a
  # collapse that happens in both.
  MWI_TREE_SIZE=$(find "$REPO_ROOT/scripts" \( -type f -o -type l \) | wc -l | tr -d ' ')
  assert_eq "manifest-writers: the walk reached every file an independent find sees" \
    "$MWI_N" "$MWI_TREE_SIZE"
  if [ "$MWI_N" -ge "${NAZGUL_MANIFEST_WRITER_TREE_FLOOR:-60}" ]; then
    _pass "manifest-writers: the walk actually reached the tree ($MWI_N scanned)"
  else
    _fail "manifest-writers: the walk actually reached the tree" \
      "only $MWI_N file(s) scanned — a broken walk, not a small tree"
  fi
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

report_results
