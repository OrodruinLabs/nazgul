#!/usr/bin/env bash
# Nazgul .gitignore block region rule — the ONE shell implementation of it.
#
# Extracted (#254 round-4, finding HEkr) because doctor.sh had re-implemented in bash a rule
# already stated in skills/init/SKILL.md and pinned byte-identically into skills/clean/SKILL.md,
# and the copy had drifted BEFORE IT SHIPPED, in both of the rule's clauses:
#
#   1. A sentinel-delimited region runs start-sentinel through END-sentinel INCLUSIVE, "regardless
#      of blank lines or comments between them". The doctor copy stopped at the first blank line
#      unconditionally, so an indented entry one blank line down was invisible and a wholly inert
#      block reported `pass ... with every region line flush-left` (finding HEYm).
#   2. A v1 region carrying NO end sentinel is bounded by OWNERSHIP, not adjacency: a line belongs
#      only if it is a `#` comment or a pattern beginning `nazgul/` (in the local block also
#      `.claude/agents/generated/` or `.mcp.json`). The doctor copy walked to the first blank line
#      regardless, so a user's own `  build/` sitting under the block was attributed to Nazgul and
#      answered with a state-archiving `--force` (finding HEag).
#
# The two SKILL.md copies are prompts and cannot call this; what the extraction buys is that every
# SHELL caller shares one implementation, and tests/test-shared-ignore-coverage.sh pins this
# implementation against the skills' stated rule. Honest boundary: that pin is a text comparison,
# not proof a model followed the prose on its turn.
#
# No top-level side effects. NOT `set -euo pipefail` — sourced into hook shells that keep their own
# options. RE-SOURCE GUARD: an ARRAY marker, which the environment cannot export (test-bounded-net).

[ "${_NZ_GITIGNORE_BLOCK_LOADED[1]:-}" = "loaded" ] && return 0
_NZ_GITIGNORE_BLOCK_LOADED=(0 loaded)

# Leading whitespace is tolerated when DETECTING or REMOVING (installs before the flush-left rule
# were appended indented), so every shape test below runs on the trimmed line while the
# indentation verdict is taken from the raw one.
_nzgi_trim() { local s="$1"; printf '%s' "${s#"${s%%[![:space:]]*}"}"; }

# Does this trimmed line belong to the region under the OWNERSHIP bound?
# _nzgi_owned <trimmed-line> [extra-prefix ...]
_nzgi_owned() {
  local t="$1" e
  shift
  case "$t" in
    '#'*) return 0 ;;
    nazgul/*) return 0 ;;
  esac
  for e in "$@"; do
    [ -n "$e" ] || continue
    case "$t" in "$e"*) return 0 ;; esac
  done
  return 1
}

# nzgi_region_indent <file> <start-sentinel> <end-sentinel> [owned-prefix ...]
#   -> absent | flush | indented
# `absent` is its own answer, never folded into `flush`: "no block here" and "a block whose every
# line is flush-left" are different states and only one of them is a pass (RULES.md §15).
nzgi_region_indent() {
  local file="$1" start="$2" end="$3"
  shift 3
  local line t seen=0 has_end=0 inr=0 bad=0

  [ -r "$file" ] || { printf 'absent'; return 0; }

  # Pass 1: is there an end sentinel AFTER the start? That decides which bound applies, and it
  # cannot be decided while walking, because the answer lies ahead of every line it governs.
  while IFS= read -r line || [ -n "$line" ]; do
    t="$(_nzgi_trim "$line")"
    if [ "$seen" -eq 0 ]; then
      case "$t" in "$start"*) seen=1 ;; esac
      continue
    fi
    case "$t" in "$end"*) has_end=1; break ;; esac
  done < "$file"

  [ "$seen" -eq 1 ] || { printf 'absent'; return 0; }

  # Pass 2: walk the region under whichever bound pass 1 selected.
  seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    t="$(_nzgi_trim "$line")"
    if [ "$inr" -eq 0 ]; then
      if [ "$seen" -eq 0 ]; then
        case "$t" in "$start"*)
          seen=1; inr=1
          case "$line" in [[:space:]]*) bad=1 ;; esac
          ;;
        esac
      fi
      continue
    fi
    if [ "$has_end" -eq 1 ]; then
      # Sentinel-delimited: blank lines and comments are INSIDE the region, so neither ends it.
      case "$line" in [[:space:]]*) bad=1 ;; esac
      case "$t" in "$end"*) break ;; esac
    else
      # Legacy v1: ownership, not adjacency. A blank line or EOF ends it, and so — sooner — does
      # the first line that qualifies as neither, which is NOT part of the block and whose
      # indentation must never be reported as the block's.
      case "$t" in '') break ;; esac
      _nzgi_owned "$t" "$@" || break
      case "$line" in [[:space:]]*) bad=1 ;; esac
    fi
  done < "$file"

  if [ "$bad" -eq 1 ]; then printf 'indented'; else printf 'flush'; fi
}
