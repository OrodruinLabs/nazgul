#!/usr/bin/env bash
# Bootstrap scrub map — Nazgul-token removal rules for /nazgul:bootstrap-project.
# Sourced by scripts/bootstrap-transform.sh. No side effects on source.
#
# To add a new rule when the final assertion fires:
#   1. Classify the token (path vs prose)
#   2. Add to the appropriate array below
#   3. Update tests/fixtures/bootstrap-transform/{input,expected}/ accordingly
#   4. Re-run: tests/run-tests.sh --filter=bootstrap-transform

# Class 1 — Path rewrites. Applied longest-first via sort in transform.
# Format: "find|replace"  (replace may be "__DROP__" to mean "drop containing sentence/line")
BOOTSTRAP_SCRUB_PATH_RULES=(
  "nazgul/docs/manifest.md|__DROP__"
  "nazgul/docs/|docs/"
  "nazgul/context/|docs/context/"
  "nazgul/config.json|__DROP__"
  "nazgul/plan.md|__DROP__"
  "nazgul/tasks/|__DROP__"
  "nazgul/checkpoints/|__DROP__"
  "nazgul/reviews/|__DROP__"
  "nazgul/logs/|__DROP__"
)

# Class 2 — Prose term rewrites (safety net). All map to __DROP__ (sentence removal).
# Patterns are extended-regex fragments combined into one alternation and matched
# as case-sensitive SUBSTRINGS (no automatic word boundaries). If a future rule
# needs word-boundary behavior, encode it in the pattern itself (e.g. with
# `[^[:alnum:]_]` on either side, since `\b` is not portable).
BOOTSTRAP_SCRUB_PROSE_RULES=(
  "Nazgul pipeline|__DROP__"
  "Nazgul loop|__DROP__"
  "the Nazgul framework|__DROP__"
  "Nazgul framework|__DROP__"
  "Nazgul's review board|__DROP__"
  "Nazgul|__DROP__"
  "NAZGUL_[A-Z_]*|__DROP__"
)

# Class 4 — YAML frontmatter keys to remove from agent files.
BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE=(
  "nazgul"
  "review-board"
  "loop-phase"
)

# Class 4 — description prefixes to strip (leading text only).
BOOTSTRAP_SCRUB_DESCRIPTION_PREFIXES=(
  "Pipeline:"
  "Post-loop:"
  "Specialist:"
)

# Files dropped entirely from the bundle (matched on basename).
BOOTSTRAP_SCRUB_DROP_FILES=(
  "manifest.md"
)
