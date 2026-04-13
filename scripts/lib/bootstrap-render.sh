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
