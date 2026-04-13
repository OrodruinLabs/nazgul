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

  awk -v on="$bundle_on" '
    /{{#bundle_mode}}/  { in_pos=1; next }
    /{{\/bundle_mode}}/ { in_pos=0; in_inv=0; next }
    /{{\^bundle_mode}}/ { in_inv=1; next }
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
  [ -f "$profile" ] && [ -f "$domains_json" ] || return 0

  # Baseline
  local -a candidates=("code-reviewer" "qa-reviewer")

  # Conditional adds by keyword presence
  if grep -qiE '\b(api|rest|graphql|endpoint)\b' "$profile"; then
    candidates+=("api-reviewer")
  fi
  if grep -qiE '\b(react|vue|svelte|angular|next\.js|nextjs|nuxt)\b' "$profile"; then
    candidates+=("frontend-reviewer")
  fi
  if grep -qiE '\b(auth|login|password|token|jwt|oauth)\b' "$profile"; then
    candidates+=("security-reviewer")
  fi
  if grep -qiE '\b(database|caching|redis|perf)\b' "$profile"; then
    candidates+=("performance-reviewer")
  fi

  # Filter to keys actually present in the JSON
  local d
  for d in "${candidates[@]}"; do
    if jq -e --arg d "$d" '.[$d]' "$domains_json" >/dev/null 2>&1; then
      echo "$d"
    else
      echo "warning: domain '$d' not in reviewer-domains.json — skipping" >&2
    fi
  done
}

# substitute_domain_vars <domain> <reviewer-domains.json>
#   Reads template from stdin, writes substituted template to stdout.
#   Handles that checklist / review_steps are JSON arrays (joined to markdown lists).
substitute_domain_vars() {
  local domain="$1"
  local json="$2"
  [ -f "$json" ] || { cat; return; }

  local name title desc cat checklist review_steps approved rejected ctx
  name="$domain"
  title=$(jq -r --arg d "$domain" '.[$d].title // $d' "$json")
  desc=$(jq -r --arg d "$domain" '.[$d].description // ""' "$json")
  cat=$(jq -r --arg d "$domain" '.[$d].category // "general"' "$json")
  # Array → "- item1\n- item2\n..."
  checklist=$(jq -r --arg d "$domain" '
    (.[$d].checklist // []) | map("- " + .) | join("\n")
  ' "$json")
  # Numbered list starting at 3 (the template hard-codes steps 1 and 2)
  review_steps=$(jq -r --arg d "$domain" '
    (.[$d].review_steps // []) | to_entries | map("\(.key + 3). \(.value)") | join("\n")
  ' "$json")
  approved=$(jq -r --arg d "$domain" '.[$d].approved_criteria // "no blocking issues"' "$json")
  rejected=$(jq -r --arg d "$domain" '.[$d].rejected_criteria // "blocking issues found"' "$json")
  ctx=$(jq -r --arg d "$domain" '.[$d].context_items // ""' "$json")

  # Use python/awk-style substitution because sed handles multiline values awkwardly.
  # Write template to a temp file so we can substitute via awk.
  local tpl
  tpl=$(mktemp)
  cat > "$tpl"

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

  rm -f "$tpl"
}
