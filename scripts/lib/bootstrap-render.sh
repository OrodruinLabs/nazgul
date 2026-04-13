#!/usr/bin/env bash
# bootstrap-render.sh — Helpers for rendering agent prompts in bundle mode.
# Sourced by the bootstrap-project skill and tested by tests/test-bootstrap-render.sh.

# render_template <file>
#   Strip {{#bundle_mode}}/{{^bundle_mode}} conditional blocks based on
#   BUNDLE_MODE env var (empty or "false" = disabled; any other value = enabled).
render_template() {
  local file="$1"
  local bundle_on="false"
  case "${BUNDLE_MODE:-}" in
    ""|false|False|FALSE|0) bundle_on="false" ;;
    *) bundle_on="true" ;;
  esac

  # Markers must be on their OWN line (optionally prefixed with "# " so they
  # stay valid YAML inside frontmatter). Anchored match prevents mangling of
  # documentation blocks that reference the markers in prose.
  awk -v on="$bundle_on" '
    /^[[:space:]]*(#[[:space:]]*)?\{\{#bundle_mode\}\}[[:space:]]*$/  { in_pos=1; next }
    /^[[:space:]]*(#[[:space:]]*)?\{\{\/bundle_mode\}\}[[:space:]]*$/ { in_pos=0; in_inv=0; next }
    /^[[:space:]]*(#[[:space:]]*)?\{\{\^bundle_mode\}\}[[:space:]]*$/ { in_inv=1; next }
    in_pos { if (on == "true") print; next }
    in_inv { if (on == "false") print; next }
    { print }
  ' "$file"
}

# render_agent_prompt <agent-file> <state-root>
#   Render an agent prompt for pipeline execution: substitute hydra/ path
#   prefixes with <state-root>/. Does NOT apply bundle_mode; use render_template
#   directly when that's needed.
render_agent_prompt() {
  local file="$1"
  local state_root="$2"
  # Strip any trailing slash from state_root
  state_root="${state_root%/}"

  # Replace `hydra/` with `<state-root>/` everywhere. Word-boundary not needed;
  # hydra/ is a path-level prefix that doesn't appear outside paths.
  local sr_esc
  sr_esc=$(printf '%s' "$state_root" | sed 's/[\/&]/\\&/g')
  sed "s/hydra\//$sr_esc\//g" "$file"
}

# select_reviewer_domains <project-profile.md> <reviewer-domains.json>
#   Outputs one domain name per line. Baseline domains always included;
#   additional domains conditionally included based on profile keyword match.
#   Skips names not present in the JSON (emits a warning to stderr).
select_reviewer_domains() {
  local profile="$1"
  local domains_json="$2"
  # Fail fast on missing inputs so the skill surfaces the issue instead of
  # silently producing an empty reviewer set.
  if [ ! -f "$profile" ]; then
    echo "error: select_reviewer_domains: profile not found: $profile" >&2
    return 1
  fi
  if [ ! -f "$domains_json" ]; then
    echo "error: select_reviewer_domains: domains file not found: $domains_json" >&2
    return 1
  fi

  # Baseline
  local -a candidates=("code-reviewer" "qa-reviewer")

  # Conditional adds by keyword presence. Use `grep -wi` (POSIX word match) for
  # single-token keywords, and an explicit POSIX char-class boundary for
  # keywords that include non-word chars (e.g. "next.js"). `\b` is unreliable
  # in BSD grep, so we avoid it.
  if grep -qwiE '(api|rest|graphql|endpoint)' "$profile"; then
    candidates+=("api-reviewer")
  fi
  if grep -qiE '(^|[^[:alnum:]_])(react|vue|svelte|angular|next\.js|nextjs|nuxt)([^[:alnum:]_]|$)' "$profile"; then
    candidates+=("frontend-reviewer")
  fi
  if grep -qwiE '(auth|login|password|token|jwt|oauth)' "$profile"; then
    candidates+=("security-reviewer")
  fi
  if grep -qwiE '(database|caching|redis|perf)' "$profile"; then
    candidates+=("performance-reviewer")
  fi

  # Filter to keys actually present in the JSON.
  # jq -e exit codes: 0 = key found, 1 = key missing/null, other = parse/runtime error.
  # Don't swallow errors — a malformed domains JSON should fail loudly, not
  # silently produce an empty reviewer set.
  local d jq_rc
  for d in "${candidates[@]}"; do
    jq -e --arg d "$d" '.[$d]' "$domains_json" >/dev/null 2>&1
    jq_rc=$?
    case $jq_rc in
      0) echo "$d" ;;
      1) echo "warning: domain '$d' not in reviewer-domains.json — skipping" >&2 ;;
      *) echo "error: select_reviewer_domains: jq exit $jq_rc reading $domains_json" >&2
         return "$jq_rc" ;;
    esac
  done
}

# substitute_domain_vars <domain> <reviewer-domains.json>
#   Reads template from stdin, writes substituted template to stdout.
#   Handles that checklist / review_steps are JSON arrays (joined to markdown lists).
substitute_domain_vars() {
  local domain="$1"
  local json="$2"
  # Sourced libs deliberately don't use `set -euo pipefail` (would leak to
  # caller), so each fallible step checks its own exit status explicitly.
  if [ ! -f "$json" ]; then
    echo "error: substitute_domain_vars: domains file not found: $json" >&2
    return 1
  fi

  local name title desc cat checklist review_steps approved rejected ctx rc
  name="$domain"
  title=$(jq -r --arg d "$domain" '.[$d].title // $d' "$json")                           || { rc=$?; echo "error: jq failed on .title" >&2; return "$rc"; }
  desc=$(jq -r --arg d "$domain" '.[$d].description // ""' "$json")                      || { rc=$?; echo "error: jq failed on .description" >&2; return "$rc"; }
  cat=$(jq -r --arg d "$domain" '.[$d].category // "general"' "$json")                   || { rc=$?; echo "error: jq failed on .category" >&2; return "$rc"; }
  # Array → "- item1\n- item2\n..."
  checklist=$(jq -r --arg d "$domain" '
    (.[$d].checklist // []) | map("- " + .) | join("\n")
  ' "$json")                                                                             || { rc=$?; echo "error: jq failed on .checklist" >&2; return "$rc"; }
  # Numbered list starting at 3 (the template hard-codes steps 1 and 2)
  review_steps=$(jq -r --arg d "$domain" '
    (.[$d].review_steps // []) | to_entries | map("\(.key + 3). \(.value)") | join("\n")
  ' "$json")                                                                             || { rc=$?; echo "error: jq failed on .review_steps" >&2; return "$rc"; }
  approved=$(jq -r --arg d "$domain" '.[$d].approved_criteria // "no blocking issues"' "$json")   || { rc=$?; echo "error: jq failed on .approved_criteria" >&2; return "$rc"; }
  rejected=$(jq -r --arg d "$domain" '.[$d].rejected_criteria // "blocking issues found"' "$json") || { rc=$?; echo "error: jq failed on .rejected_criteria" >&2; return "$rc"; }
  ctx=$(jq -r --arg d "$domain" '.[$d].context_items // ""' "$json")                     || { rc=$?; echo "error: jq failed on .context_items" >&2; return "$rc"; }

  # Write template to a temp file so awk can substitute multiline values.
  local tpl
  tpl=$(mktemp "${TMPDIR:-/tmp}/bootstrap-domain.XXXXXX") || { echo "error: substitute_domain_vars: mktemp failed" >&2; return 1; }
  cat > "$tpl"  || { rc=$?; rm -f "$tpl"; echo "error: substitute_domain_vars: failed reading template from stdin" >&2; return "$rc"; }

  awk -v name="$name" -v title="$title" -v desc="$desc" -v cat="$cat" \
      -v checklist="$checklist" -v review_steps="$review_steps" \
      -v approved="$approved" -v rejected="$rejected" -v ctx="$ctx" '
    {
      gsub(/\{\{reviewer_name\}\}/, name)
      gsub(/\{\{title\}\}/, title)
      gsub(/\{\{description\}\}/, desc)
      gsub(/\{\{category\}\}/, cat)
      gsub(/\{\{checklist\}\}/, checklist)
      gsub(/\{\{review_steps\}\}/, review_steps)
      gsub(/\{\{approved_criteria\}\}/, approved)
      gsub(/\{\{rejected_criteria\}\}/, rejected)
      gsub(/\{\{context_items\}\}/, ctx)
      print
    }
  ' "$tpl"
  rc=$?
  rm -f "$tpl"
  return "$rc"
}
