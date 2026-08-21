# stop-payload fixture provenance

## Machine-checked declaration

`tests/test-repo-content-boundary.sh` R2 parses the fields below and RECOMPUTES every
`pin:` line against this directory. A pin that drifts from disk fails the suite — which is
the whole reason the numbers live here as pins rather than as prose.

tier: captured-redacted
consumer: the Stop-payload classification arms of `scripts/stop-hook.sh`, via `tests/test-in-flight-hold.sh` (FEAT-033 TASK-004/TASK-005/TASK-007)
producer: the Claude Code harness — a real `Stop` hook invocation, read from the hook's own stdin
captured: 2026-08-21 (FEAT-033 owed probe, `nazgul/context/218-probe-results.md`)
redacted: 2026-08-21 (TASK-001, FEAT-033)

```form-pins
pin: file-count | 1 | . | *.json
pin: occurrences | 3 | . | "i[d]":"
pin: occurrences | 2 | . | "type":"suba[g]ent"
pin: occurrences | 1 | . | "type":"sh[e]ll"
pin: occurrences | 3 | . | "status":"runn[i]ng"
pin: matching-files | 1 | . | "hook_event_name":"St[o]p"
```

The pin evaluator greps the whole fixture directory, and this file lives *in* it rather than
one level up. Each pattern therefore carries a one-character bracket class (`suba[g]ent`
matches `subagent`) so a pin line cannot match itself, and every JSON quotation in the prose
below is spaced (`"type": "subagent"`) so the documentation cannot inflate its own counts.

## `stop-two-subagents-one-shell.json`

- **Tier**: `captured-redacted` — one real payload, four identifier fields overwritten. Nothing
  was reshaped, reordered, or reconstructed. See "What is captured and what is not".
- **Producer**: the harness's `Stop` hook invocation. Captured by a single write-only line added
  after `scripts/notify.sh`'s existing `INPUT=$(cat …)`, so the probe consumed no stdin of its
  own and could not introduce a #155-class hang.
- **Captured on**: 2026-08-21, from this project's own session
- **Redacted on**: 2026-08-21 (TASK-001, FEAT-033)

### Why this payload and not another

It is the **exact scenario ADR-027 is about**, observed live rather than argued: at a real `Stop`,
two dispatched subagents and one backgrounded shell waiter were in flight at once. Filtering on
`"type": "subagent"` yields `LIVE = 2` and the loop holds; an unfiltered count would also have
counted the `until …; do sleep …; done` waiter, which no dispatch will ever finish. The type
filter's necessity is demonstrated here on this project's own session — not only on the borrowed
mixed capture, which is the reason `../stop-payload-synthetic/` exists.

### What is captured and what is not

| Aspect | Status | Why it matters |
|---|---|---|
| The top-level key set, and its order | **captured** | `Stop` carries no `agent_id` / `agent_transcript_path` / `agent_type`; `SubagentStop` does. That asymmetry is evidence. |
| `background_tasks` present at all, unflagged and ungated | **captured** | the `jq -e 'has("background_tasks")'` predicate the whole design hangs on |
| Entry count, and the type/status of every entry | **captured** | 2 subagents + 1 shell, all running — the pinned counts above |
| `id` values (`aa1ea376b575466c8`, `b1l9mz9r4`) | **captured** | they are the real agentId / shell id forms, and the subagent one is exactly the agentId of the dispatch that produced it |
| `agent_type` values, incl. the `nazgul:` namespace prefix | **captured** | the plugin-namespaced spelling a name-matching design would have had to normalise |
| `last_assistant_message`, and the shell entry's `command` | **captured** | this project's own text; kept because a redaction here would misrepresent how much a payload carries |
| No trailing newline — the file's last byte is `}` | **captured** | see below |
| `session_id`, `transcript_path`, `cwd`, `prompt_id` | **overwritten** | operator-identifying; not evidence |

`agent_id` is listed by the redaction rule but does not occur: a `Stop` payload has no such
field. That is a captured fact about the event shape, not a scrub that happened to find nothing.

### The trailing byte is part of the fixture

The captured file's last byte is `}`, with **no** trailing newline — that is what the harness
writes to a hook's stdin. Any regeneration of this fixture must preserve it. A fixture that ends
in a newline would silently forgive a reader that blocks until it sees one, which is the exact
#155 failure class the bounded stdin idiom (ADR-027 condition C1) exists to close.

### How it was redacted

```sh
jq -c '.session_id = "…" | .transcript_path = "…" | .cwd = "…" | .prompt_id = "…"'
```

then the trailing newline stripped. The redaction is verifiable in one line — every byte outside
those four values is unchanged:

```sh
diff <(jq -cS 'del(.session_id,.transcript_path,.cwd,.prompt_id)' <capture>) \
     <(jq -cS 'del(.session_id,.transcript_path,.cwd,.prompt_id)' stop-two-subagents-one-shell.json)
```

The replacement paths use `/Users/dev/…`, an allowlisted placeholder name in
`tests/test-repo-content-boundary.sh` R1, so the fixture keeps a realistically-shaped absolute
path without carrying a real one.

### Consumer

`scripts/stop-hook.sh` reads two independent counts off this array and nothing else (ADR-027 Q2):

```sh
LIVE=$(… | jq '[.background_tasks[] | select(.type=="subagent")
               | select(.status=="running" or .status=="pending")] | length')
SUBAGENT_PRESENT=$(… | jq '[.background_tasks[] | select(.type=="subagent")] | length')
```

Against this fixture that is `LIVE = 2`, `SUBAGENT_PRESENT = 2`, `entries = 3`. No field outside
`background_tasks[]` is parsed by the classification; the rest is carried so the fixture stays a
whole payload rather than an excerpt chosen to suit a parser.

### What it pins

That the hold arm fires on real producer output. Two live subagents plus one shell waiter is the
only in-flight shape #218 was ever reported against, and this is that shape as the harness
actually emitted it.

### Never observed, and therefore not here

`LIVE == 0`, `SUBAGENT_PRESENT == 0`, and any status other than `running` have **never** been
captured. No redaction of this file can produce them, so they live in
`../stop-payload-synthetic/` and are labelled synthetic there. Nothing in this directory should
ever be cited as evidence about those cases.
