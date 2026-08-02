## Report Contract (teammate dispatch)

Include this block verbatim at the END of every teammate prompt. Substitute
BOTH placeholders used across this contract before use: `<REPORT_PATH>` (in
the prompt block below, and again in the manifest snippet) and
`<teammate-session-name>` (used twice in the manifest snippet) — the dispatch
manifest filename MUST match the teammate's actual session name exactly:

> REPORT CONTRACT: Your final plain text is NOT delivered to anyone. Your LAST
> action MUST be writing your complete report to `<REPORT_PATH>` (create parent
> directories if needed). Do not idle before that file exists. Optionally, you
> may ALSO SendMessage a one-line completion summary to your team lead — but
> the file is the deliverable, the message is courtesy.

Before spawning the teammate, write its dispatch manifest so the TeammateIdle
guard can enforce the contract:

```bash
mkdir -p nazgul/dispatch
jq -n --arg t "<teammate-session-name>" --arg rp "<REPORT_PATH>" \
  --arg team "<team-name-or-empty>" \
  --arg f "$(jq -r '.feat_id // "default"' nazgul/config.json)" \
  --arg sa "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson sae "$(date +%s)" \
  '{teammate:$t, report_path:$rp, feat_id:$f, spawned_at:$sa, spawned_at_epoch:$sae, blocks:0}
   + (if $team != "" then {team:$team} else {} end)' \
  > "nazgul/dispatch/<teammate-session-name>.json"
```

Completion signal = idle notification + report file on disk. Read the report
from the file; never wait for a message. Dismissal is mandatory once you've
consumed it: send that teammate a SendMessage shutdown_request, and once it
approves, delete ONLY its `nazgul/dispatch/<session-name>.json` — never glob
`nazgul/dispatch/*.json`, which would also delete manifests belonging to
other concurrently active teams and silently disable their TeammateIdle
enforcement. Teammates never terminate on their own — `TeamCreate`/
`TeamDelete` no longer exist (removed in Claude Code v2.1.178), per-teammate
shutdown_request is the only teardown primitive, and team state is otherwise
removed only on normal session exit, so an undismissed teammate idles
forever unless the dispatcher dismisses it — there is no mechanical backstop
(RULES.md §18, FEAT-026/ADR-017).

This contract applies only to a genuine Agent-Teams teammate. Nazgul's own
dispatches (discovery, review, implementation) are unnamed one-shot `Agent`
dispatches, not teammates, and none of the above applies to them.
