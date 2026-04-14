#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="e2e-bootstrap-project"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/assertions.sh"

echo "=== $TEST_NAME ==="

command -v claude >/dev/null 2>&1 || {
  echo "SKIP: claude CLI not available"
  exit 0
}

run_fixture() {
  local fixture_name="$1"
  local min_expected_files="$2"
  local fixture_src="$SCRIPT_DIR/fixtures/$fixture_name"
  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/e2e-bootstrap-$fixture_name-XXXXXX")
  trap 'rm -rf "$work"' RETURN
  cp -R "$fixture_src/." "$work/"
  (cd "$work" && git init -q && git add -A && git -c user.email=e2e@test -c user.name=e2e commit -q -m init)

  echo ""
  echo "--- running /hydra:bootstrap-project against $fixture_name ---"

  (cd "$work" && claude -p "/hydra:bootstrap-project \"A demo app for e2e validation\" --yes --overwrite" 2>&1) || {
    _fail "$fixture_name: skill invocation exit 0"
    return 1
  }
  _pass "$fixture_name: skill invocation exit 0"

  # Bundle checks
  local got_docs
  got_docs=$(find "$work/docs" -maxdepth 2 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$got_docs" -ge "$min_expected_files" ]; then
    _pass "$fixture_name: >=$min_expected_files docs produced (got $got_docs)"
  else
    _fail "$fixture_name: too few docs" "expected >=$min_expected_files, got $got_docs"
  fi

  # No Hydra tokens anywhere in bundle. Boundary pattern matches the one the
  # transform uses so E2E failures correspond to real Hydra leaks (not
  # incidental substrings like "dehydrate").
  local leaks
  leaks=$(grep -rinE '(^|[^[:alnum:]_])(hydra|Hydra|HYDRA)(/|[^[:alnum:]]|$)' "$work/docs" "$work/.claude" 2>/dev/null || true)
  if [ -z "$leaks" ]; then
    _pass "$fixture_name: no Hydra tokens leaked"
  else
    _fail "$fixture_name: Hydra tokens leaked" "$leaks"
  fi

  # Reviewer frontmatter is valid YAML
  local bad_fm=0
  while IFS= read -r f; do
    if ! awk 'BEGIN{state=0} /^---$/{state++; if(state==2){exit 0}} END{exit state==2?0:1}' "$f"; then
      bad_fm=$((bad_fm+1))
    fi
  done < <(find "$work/.claude/agents" -type f -name '*.md' 2>/dev/null)
  if [ "$bad_fm" -eq 0 ]; then
    _pass "$fixture_name: all reviewer frontmatter valid"
  else
    _fail "$fixture_name: $bad_fm reviewer(s) with bad frontmatter"
  fi
}

run_fixture "minimal-greenfield" 3    # PRD + TRD + test-plan at minimum
run_fixture "nextjs-brownfield"   4   # + at least one ADR

report_results
