#!/usr/bin/env bash
# Bootstrap scrub map — Hydra-token removal rules for /hydra:bootstrap-project.
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
  "hydra/docs/manifest.md|__DROP__"
  "hydra/docs/|docs/"
  "hydra/context/|docs/context/"
  "hydra/config.json|__DROP__"
  "hydra/plan.md|__DROP__"
  "hydra/tasks/|__DROP__"
  "hydra/checkpoints/|__DROP__"
  "hydra/reviews/|__DROP__"
  "hydra/logs/|__DROP__"
)

# Class 2 — Prose term rewrites (safety net). All map to __DROP__ (sentence removal).
# Match is whole-word, case-sensitive except where noted.
BOOTSTRAP_SCRUB_PROSE_RULES=(
  "Hydra pipeline|__DROP__"
  "Hydra loop|__DROP__"
  "the Hydra framework|__DROP__"
  "Hydra framework|__DROP__"
  "Hydra's review board|__DROP__"
  "Hydra|__DROP__"
  "HYDRA_[A-Z_]*|__DROP__"
)

# Class 4 — YAML frontmatter keys to remove from agent files.
BOOTSTRAP_SCRUB_FRONTMATTER_REMOVE=(
  "hydra"
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
