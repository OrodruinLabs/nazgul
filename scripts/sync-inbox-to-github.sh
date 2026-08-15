#!/usr/bin/env bash
set -uo pipefail
# Nazgul Inbox -> GitHub board sync/check.
#
# Enforces the invariant: EVERY nazgul/inbox/*.md item has a GitHub issue on the
# board. Idempotent — an item carrying `issue: N` in its frontmatter is already
# synced and is never re-created.
#
#   sync-inbox-to-github.sh --check   report only; exit 1 if any item is unsynced OR stale
#   sync-inbox-to-github.sh           create missing issues, push changed bodies, then report
#
# Staleness is tracked by `synced_sha` in the item's frontmatter: the sha256 of the
# body at last push. Local sha != synced_sha means the file changed since and the
# issue body is out of date. "Exists on the board" and "matches the board" are
# different claims and this script checks both.
#
# Reports `N scanned, M skipped, K created, F failed` (RULES.md §15): "nothing to
# do" and "nothing was examined" must never be the same output.

REPO="OrodruinLabs/nazgul"
PROJECT_NUMBER=4
PROJECT_OWNER="OrodruinLabs"
PROJECT_ID="PVT_kwDOD5r1oM4BgZGi"
RANK_FIELD_ID="PVTF_lADOD5r1oM4BgZGizhalbgk"

# The label the GitHub inbox provider actually pulls on
# (scripts/lib/connector-github.sh: gh issue list --state open --label "$label").
# Read from config rather than hardcoded so the two sides cannot drift: an issue
# created without it is on the board but invisible to the work queue, which is how
# 98 of 102 open items came to be unreachable (issue #192).
PULL_LABEL=$(jq -r '.connectors.github.pull.label // empty' nazgul/config.json 2>/dev/null)
case "$PULL_LABEL" in ""|null) PULL_LABEL="nazgul" ;; esac

MODE="sync"; [ "${1:-}" = "--check" ] && MODE="check"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/nazgul-root.sh"
INBOX="$(resolve_nazgul_dir)/inbox"
[ -d "$INBOX" ] || { echo "sync-inbox: no inbox at $INBOX" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "sync-inbox: gh not installed" >&2; exit 1; }
cd "$INBOX" || exit 1

scanned=0; skipped=0; created=0; updated=0; failed=0; unsynced=0; stale=0

# Normalize any item missing type/rank (new arrivals land without them).
python3 - <<'PY'
import os,re,glob
FEATURE={'feature','improvement','refactor','chore','enhancement'}
maxrank=0
for f in glob.glob('*.md'):
    m=re.search(r'^rank:\s*(\d+)',open(f,encoding='utf-8').read(),re.M)
    if m: maxrank=max(maxrank,int(m.group(1)))
for f in sorted(glob.glob('*.md')):
    st=os.stat(f); t=open(f,encoding='utf-8').read()
    if not t.startswith('---'): continue
    end=t.find('\n---',3); fm=t[3:end]; rest=t[end:]
    ty=(lambda m:m.group(1).strip().strip('"') if m else '')(re.search(r'^type:\s*(.+)$',fm,re.M))
    changed=False
    if ty.lower() not in ('bug','feature'):
        b='feature' if ty.lower() in FEATURE else 'bug'
        fm=re.sub(r'^type:\s*.*$','type: '+b,fm,count=1,flags=re.M) if ty else fm.rstrip('\n')+'\ntype: '+b+'\n'
        changed=True
    if not re.search(r'^rank:\s*\d+',fm,re.M):
        maxrank+=1; fm=fm.rstrip('\n')+'\nrank: %d\n'%maxrank; changed=True
    if changed:
        open(f,'w',encoding='utf-8').write('---'+fm+rest); os.utime(f,(st.st_mtime,st.st_mtime))
PY

for f in *.md; do
  [ -f "$f" ] || continue
  scanned=$((scanned+1))
  if grep -qE '^issue: [0-9]+' "$f"; then
    num=$(awk -F': ' '/^issue:/{print $2; exit}' "$f")
    body=$(mktemp); awk 'BEGIN{n=0} /^---$/{n++; if(n<=2) next} n>=2{print}' "$f" > "$body"
    now=$(shasum -a 256 "$body" | cut -d' ' -f1)
    was=$(awk -F': ' '/^synced_sha:/{print $2; exit}' "$f")
    if [ "$now" = "$was" ]; then rm -f "$body"; skipped=$((skipped+1)); continue; fi
    if [ "$MODE" = "check" ]; then
      rm -f "$body"; stale=$((stale+1)); echo "sync-inbox: STALE #$num $f" >&2; continue
    fi
    mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
    if gh issue edit "$num" --repo "$REPO" --body-file "$body" >/dev/null 2>&1; then
      python3 -c "
import sys,re,os
f,h=sys.argv[1],sys.argv[2]; st=os.stat(f); t=open(f,encoding='utf-8').read()
t=re.sub(r'^synced_sha: .*\$','synced_sha: '+h,t,count=1,flags=re.M) if re.search(r'^synced_sha:',t,re.M) \
  else re.sub(r'^(issue: .*)\$', r'\1\nsynced_sha: '+h, t, count=1, flags=re.M)
open(f,'w',encoding='utf-8').write(t); os.utime(f,(st.st_mtime,st.st_mtime))" "$f" "$now"
      touch -t "$(date -r "$mt" +%Y%m%d%H%M.%S)" "$f" 2>/dev/null || true
      updated=$((updated+1))
    else
      echo "sync-inbox: UPDATE FAILED #$num $f" >&2; failed=$((failed+1))
    fi
    rm -f "$body"; sleep 0.3; continue
  fi
  if [ "$MODE" = "check" ]; then
    unsynced=$((unsynced+1)); echo "sync-inbox: UNSYNCED $f" >&2; continue
  fi
  rank=$(awk -F': ' '/^rank:/{print $2; exit}' "$f")
  pri=$(awk -F': ' '/^priority:/{print $2; exit}' "$f")
  typ=$(awk -F': ' '/^type:/{print $2; exit}' "$f")
  title=$(awk -F'title: ' '/^title:/{gsub(/"/,"",$2); print $2; exit}' "$f")
  [ -z "$title" ] && title=$(grep -m1 '^# ' "$f" | sed 's/^# //')
  [ -z "$title" ] && title="${f%.md}"
  title=$(printf '%s' "$title" | sed -E 's/^p[0-9]+ (—|-) *//')
  body=$(mktemp); awk 'BEGIN{n=0} /^---$/{n++; if(n<=2) next} n>=2{print}' "$f" > "$body"
  [ -s "$body" ] || cp "$f" "$body"
  mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
  url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$body" \
        --label "type:$typ" --label "priority:$pri" --label "$PULL_LABEL" 2>&1)
  rm -f "$body"
  num=$(printf '%s' "$url" | grep -oE '[0-9]+$')
  if [ -z "$num" ]; then echo "sync-inbox: FAILED $f :: $url" >&2; failed=$((failed+1)); continue; fi
  python3 -c "
import sys,re,os
f,n=sys.argv[1],sys.argv[2]; st=os.stat(f); t=open(f,encoding='utf-8').read()
t=re.sub(r'^(rank: .*)\$', r'\1\nissue: '+n, t, count=1, flags=re.M)
open(f,'w',encoding='utf-8').write(t); os.utime(f,(st.st_mtime,st.st_mtime))" "$f" "$num"
  touch -t "$(date -r "$mt" +%Y%m%d%H%M.%S)" "$f" 2>/dev/null || true
  item=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$url" --format json 2>/dev/null | jq -r '.id')
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    gh project item-edit --id "$item" --project-id "$PROJECT_ID" \
      --field-id "$RANK_FIELD_ID" --number "$rank" >/dev/null 2>&1
  fi
  created=$((created+1)); sleep 0.4
done

echo "sync-inbox: $scanned scanned, $skipped skipped (up to date), $created created, $updated updated, $stale stale, $failed failed"
if [ "$MODE" = "check" ] && { [ "$unsynced" -gt 0 ] || [ "$stale" -gt 0 ]; }; then
  [ "$unsynced" -gt 0 ] && echo "sync-inbox: $unsynced item(s) have no GitHub issue" >&2
  [ "$stale" -gt 0 ] && echo "sync-inbox: $stale item(s) changed since last push" >&2
  echo "sync-inbox: run without --check to reconcile" >&2
  exit 1
fi
[ "$failed" -gt 0 ] && exit 1
exit 0
