#!/usr/bin/env bash
set -uo pipefail

# Test: shared-resource references in shipped prompts (FEAT-029 TASK-007, PRD AC8).
# The historical defect: a prompt cited `references/ui-brand.md` relative to nothing in
# particular, which resolves in a checkout of this repo and nowhere in an installed
# plugin. Both halves are therefore checked: every shared resource is cited from
# ${CLAUDE_PLUGIN_ROOT}, and every such citation resolves to a file that is actually
# INSIDE the packaged tree — the package is staged from what git would ship, so a
# working-tree-only or ignored file cannot pass for a packaged one.
#
# Extending this test (TASK-008/009/010): add the file globs of the newly qualified
# prompts to SCAN_GLOBS and their expected citations to REQUIRED_CITATIONS. The scanner
# itself is data-driven and needs no change; a second scanner is a defect, not a task.
TEST_NAME="test-reference-paths"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-reference-paths-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The prompt file sets scanned by this test. One entry per shell glob, relative to the
# repository root; a glob that matches nothing is a finding, not an empty pass.
SCAN_GLOBS="agents/*.md
agents/templates/*.md"

# Citations each listed file must carry, as "<file> <path-under-plugin-root>". This is
# the positive half: a reference silently deleted is not a compliant reference.
REQUIRED_CITATIONS="agents/debugger.md references/ui-brand.md
agents/discovery.md references/ui-brand.md
agents/feedback-aggregator.md references/ui-brand.md
agents/feedback-aggregator.md references/fix-first-heuristic.md
agents/planner.md references/ui-brand.md"

PLUGIN_ROOT_TOKEN='${CLAUDE_PLUGIN_ROOT}/'

MIN_SCANNED_FILES=20
MIN_SCANNED_REFS=10

# Stage the packaged plugin tree: every file git would ship (tracked, plus untracked
# files that are not ignored), copied out of the working tree into a clean root.
stage_package() {
  src="$1"
  dest="$2"
  manifest="$3"
  mkdir -p "$dest" || return 1
  git -C "$src" ls-files -z --cached --others --exclude-standard > "$manifest" 2>/dev/null || return 1
  staged=0
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    [ -f "$src/$rel" ] || continue
    mkdir -p "$dest/$(dirname "$rel")" || return 1
    cp "$src/$rel" "$dest/$rel" || return 1
    staged=$((staged + 1))
  done < "$manifest"
  [ "$staged" -gt 0 ] || return 1
  printf '%s\n' "$staged"
}

# Rewrite the qualified spelling away first, so what remains is genuinely unqualified
# rather than merely the tail of a qualified reference.
bare_refs() {
  sed 's|\${\{0,1\}CLAUDE_PLUGIN_ROOT}\{0,1\}/|__QUALIFIED__|g' "$1" \
    | grep -oE '(^|[^A-Za-z0-9._/-])references/[A-Za-z0-9._/-]+' \
    | sed 's|^[^r]*references/|references/|' || true
}

# Both shipped spellings of the plugin root, reduced to the path they name.
plugin_ref_paths() {
  grep -o '\${\{0,1\}CLAUDE_PLUGIN_ROOT}\{0,1\}/[A-Za-z0-9._/-]*' "$1" \
    | sed 's|.*CLAUDE_PLUGIN_ROOT}\{0,1\}/||' || true
}

# Expand a glob relative to the root, emitting repo-relative paths one per line, so a
# root path containing spaces cannot smear one match into several.
expand_glob() {
  ( cd "$1" && for m in $2; do [ -e "$m" ] && printf '%s\n' "$m"; done ) 2>/dev/null || true
}

ref_escapes_tree() {
  case "/$1" in
    */../*|*/..) return 0 ;;
  esac
  case "$1" in
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

# === Package staging: the tree every resolution below is judged against ===

PKG="$WORK/package"
PKG_FILES=$(stage_package "$REPO_ROOT" "$PKG" "$WORK/pkg-manifest" || true)
if [ -n "$PKG_FILES" ]; then
  _pass "package tree staged from the shipped file set ($PKG_FILES files)"
else
  _fail "package tree staged from the shipped file set" \
    "staging produced no files — nothing below actually resolved against a package"
fi
assert_file_exists "package tree carries the shared references directory" "$PKG/references/ui-brand.md"

# === The scan: every shipped prompt is qualified and every citation resolves ===

FILE_SCANNED=0
FILE_CHECKED=0
FILE_UNREADABLE=0
FILE_FINDINGS=0
REF_SCANNED=0
REF_CHECKED=0
REF_FINDINGS=0

while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  matched=0
  for rel in $(expand_glob "$REPO_ROOT" "$glob"); do
    f="$REPO_ROOT/$rel"
    [ -e "$f" ] || continue
    matched=$((matched + 1))
    FILE_SCANNED=$((FILE_SCANNED + 1))
    if [ ! -r "$f" ]; then
      FILE_UNREADABLE=$((FILE_UNREADABLE + 1))
      FILE_FINDINGS=$((FILE_FINDINGS + 1))
      _fail "$rel is readable" "prompt could not be read — not scanned"
      continue
    fi
    FILE_CHECKED=$((FILE_CHECKED + 1))

    unqualified=$(bare_refs "$f")
    if [ -n "$unqualified" ]; then
      FILE_FINDINGS=$((FILE_FINDINGS + 1))
      _fail "$rel: every shared reference is plugin-root qualified" "$unqualified"
    else
      _pass "$rel: every shared reference is plugin-root qualified"
    fi

    paths=$(plugin_ref_paths "$f")
    [ -n "$paths" ] || continue
    while IFS= read -r refpath; do
      [ -n "$refpath" ] || continue
      REF_SCANNED=$((REF_SCANNED + 1))
      REF_CHECKED=$((REF_CHECKED + 1))
      if ref_escapes_tree "$refpath"; then
        REF_FINDINGS=$((REF_FINDINGS + 1))
        _fail "$rel: $refpath stays inside the plugin tree" "reference escapes the plugin root"
      elif [ -e "$PKG/$refpath" ]; then
        _pass "$rel: $refpath resolves in the packaged tree"
      else
        REF_FINDINGS=$((REF_FINDINGS + 1))
        _fail "$rel: $refpath resolves in the packaged tree" "absent from the packaged tree: $refpath"
      fi
    done <<REF_LIST
$paths
REF_LIST
  done
  if [ "$matched" -eq 0 ]; then
    FILE_FINDINGS=$((FILE_FINDINGS + 1))
    _fail "scan glob '$glob' matches shipped prompts" "the glob matched no file — nothing was scanned for it"
  fi
done <<GLOB_LIST
$SCAN_GLOBS
GLOB_LIST

echo "  file-scan: ${FILE_SCANNED} scanned, $((FILE_SCANNED - FILE_CHECKED)) skipped (unreadable=${FILE_UNREADABLE}), ${FILE_CHECKED} checked, ${FILE_FINDINGS} findings"
echo "  reference-scan: ${REF_SCANNED} scanned, $((REF_SCANNED - REF_CHECKED)) skipped (unresolvable-form=0), ${REF_CHECKED} checked, ${REF_FINDINGS} findings"
assert_eq "file-scan: every scanned prompt was actually checked" "$FILE_CHECKED" "$FILE_SCANNED"
assert_eq "reference-scan: every scanned reference was actually checked" "$REF_CHECKED" "$REF_SCANNED"

if [ "$FILE_SCANNED" -ge "$MIN_SCANNED_FILES" ]; then
  _pass "file-scan: the globs matched the shipped prompt set (>= $MIN_SCANNED_FILES files)"
else
  _fail "file-scan: the globs matched the shipped prompt set (>= $MIN_SCANNED_FILES files)" \
    "scanned only $FILE_SCANNED"
fi
if [ "$REF_SCANNED" -ge "$MIN_SCANNED_REFS" ]; then
  _pass "reference-scan: citations were found to resolve (>= $MIN_SCANNED_REFS references)"
else
  _fail "reference-scan: citations were found to resolve (>= $MIN_SCANNED_REFS references)" \
    "scanned only $REF_SCANNED — a scan finding almost nothing is a scanner defect"
fi

# === Required citations: the qualified reference is present, not merely not-unqualified ===

while IFS=' ' read -r rel refpath; do
  [ -n "$rel" ] || continue
  f="$REPO_ROOT/$rel"
  if [ ! -f "$f" ]; then
    _fail "$rel exists to carry its shared reference" "prompt file is missing"
    continue
  fi
  assert_file_contains "$rel cites $refpath from the plugin root" "$f" "${PLUGIN_ROOT_TOKEN}${refpath}"
done <<CITATION_LIST
$REQUIRED_CITATIONS
CITATION_LIST

# === Controls: each half reports a real defect, and clears a compliant prompt ===

cat > "$WORK/bad-unqualified.md" <<'BAD_UNQUALIFIED'
---
name: bad-unqualified
---
Format ALL user-facing output per `references/ui-brand.md`.
BAD_UNQUALIFIED

assert_contains "control: an unqualified shared reference is reported" \
  "$(bare_refs "$WORK/bad-unqualified.md")" "references/ui-brand.md"

cat > "$WORK/bad-absent.md" <<'BAD_ABSENT'
---
name: bad-absent
---
Classify per `${CLAUDE_PLUGIN_ROOT}/references/does-not-exist.md`.
BAD_ABSENT

ABSENT_PATH=$(plugin_ref_paths "$WORK/bad-absent.md")
assert_eq "control: the citation is extracted as a package-relative path" "$ABSENT_PATH" "references/does-not-exist.md"
assert_file_not_exists "control: an absent packaged file does not resolve" "$PKG/$ABSENT_PATH"

cat > "$WORK/bad-escape.md" <<'BAD_ESCAPE'
---
name: bad-escape
---
Read `${CLAUDE_PLUGIN_ROOT}/../outside-the-plugin.md` and `$CLAUDE_PLUGIN_ROOT/references/../../etc/hosts`.
BAD_ESCAPE

ESCAPE_PATHS=$(plugin_ref_paths "$WORK/bad-escape.md")
assert_contains "control: the bare-dollar spelling is extracted too" "$ESCAPE_PATHS" "references/../../etc/hosts"
ESCAPE_FLAGGED=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ref_escapes_tree "$p"; then ESCAPE_FLAGGED=$((ESCAPE_FLAGGED + 1)); fi
done <<ESCAPE_LIST
$ESCAPE_PATHS
ESCAPE_LIST
assert_eq "control: both escaping references are reported" "$ESCAPE_FLAGGED" "2"
if ref_escapes_tree "references/ui-brand.md"; then
  _fail "control: a contained reference is not reported as escaping" "false positive on references/ui-brand.md"
else
  _pass "control: a contained reference is not reported as escaping"
fi

cat > "$WORK/good.md" <<'GOOD'
---
name: good
---
Format output per `${CLAUDE_PLUGIN_ROOT}/references/ui-brand.md`.
GOOD

assert_eq "control: a compliant prompt reports no unqualified reference" "$(bare_refs "$WORK/good.md")" ""
GOOD_PATH=$(plugin_ref_paths "$WORK/good.md")
assert_file_exists "control: a compliant citation resolves in the packaged tree" "$PKG/$GOOD_PATH"

# The package must be what ships, not what happens to sit in the checkout: an ignored
# file is present on disk and absent from the staged tree.
CTRL_REPO="$WORK/ctrl-repo"
mkdir -p "$CTRL_REPO/references"
git -C "$CTRL_REPO" init -q 2>/dev/null
printf 'shipped\n' > "$CTRL_REPO/references/shipped.md"
printf 'local only\n' > "$CTRL_REPO/references/ignored.md"
printf 'references/ignored.md\n' > "$CTRL_REPO/.gitignore"
git -C "$CTRL_REPO" add -A 2>/dev/null
CTRL_STAGED=$(stage_package "$CTRL_REPO" "$WORK/ctrl-pkg" "$WORK/ctrl-manifest" || true)
assert_file_exists "control: a shipped file is staged into the package" "$WORK/ctrl-pkg/references/shipped.md"
assert_file_exists "control: the ignored file exists in the working tree" "$CTRL_REPO/references/ignored.md"
assert_file_not_exists "control: an ignored file is NOT part of the package" "$WORK/ctrl-pkg/references/ignored.md"
if [ -n "$CTRL_STAGED" ] && [ "$CTRL_STAGED" -ge 2 ]; then
  _pass "control: package staging reports the file count it copied ($CTRL_STAGED)"
else
  _fail "control: package staging reports the file count it copied" "reported '$CTRL_STAGED'"
fi

report_results
