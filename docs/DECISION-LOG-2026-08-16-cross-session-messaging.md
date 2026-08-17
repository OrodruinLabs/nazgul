# Decision Log — Cross-Session Messaging Adoption (2026-08-16)

Design: `docs/superpowers/specs/2026-08-16-cross-session-messaging-adoption-design.md`.
Evidence: `docs/superpowers/specs/2026-08-16-cross-session-messaging-platform-facts.md` (V1–V10, P1–P6).

## D-001 — Doctrine: messaging is an operator surface and an attack surface, never a loop mechanism

Cross-session messaging (Claude Code ≥2.1.224) is adopted for operator HITL steering (native,
documented, zero Nazgul code), peer-courtesy FYI (already permitted by RULES §17), inbound
hardening, and observability corroboration. It is NOT adopted as a wake, transport, or gate input
for the loop. Adopted rule (RULES §22): **an unguaranteed channel may shorten a wait, but may
never authorize one.** Delivery is documented as not guaranteed (delivered/held/refused; refusal
produces no sender notice; throttling opaque; four unrelated settings changes silently
reconfigure the transport).

## D-002 — The doorbell was proven to WORK, and cut anyway

P2/P5 measured the full cycle: a socket post to an idle session starts a turn; that turn's Stop
hook fires, can return decision:block, and the harness honors it — the engine genuinely re-enters.
It was cut on four independently sufficient grounds: (1) the canonical unattended shape
(heartbeat's `claude -p`) has no idle state — the hold's exit 0 is process exit; (2) redundant
where it works (background dispatches already have the documented harness resume) and impossible
where it is needed (the foreground-leak case's trigger event has already fired); (3) unbounded
silent failure (checked-in project `refuse`, invisible managed settings, measured indefinite `nc`
hang inside a 10s hook budget, measured `nc -w 1` false-success); (4) the 2026-07-21 log's D-002
items 3 and 4 already rejected this shape. The record must show this was a reliability-semantics
judgment, not a capability gap.

## D-003 — #104 Gap 3's fix is per-marker classification, not a hold inversion

"Confirmed wake path" is a per-dispatch property decidable at marker-write time: background
dispatches have the documented harness resume; a foreground marker present at Stop time is a
proven leak (a synchronous call cannot span a Stop). Hold only `background=="true"` unnamed
markers; quarantine the rest as `in_flight_orphan` and continue normally. The rejected
alternative (block-and-burn unless a session-global wake flag) was quantified: it force-stops a
legitimate hour-long background dispatch in ≤5 burned iterations, unrecoverably, and does not
clear the leaked marker that caused the incident.

## D-004 — Session locks are session-lifetime

`stop-hook.sh`'s EXIT trap unregistered the lock on every allowed stop, so §13's "never a second
loop" guard was vacuous outside a mid-loop turn (0 locks beside 4 live sessions, measured).
Locks now: registered at SessionStart, refreshed per Stop, released at SessionEnd, swept by pid
liveness — and carry cwd/toplevel/branch so a shared-tree collision (#195) is detectable.

## D-005 — Amendment to the 2026-07-21 log's closing rule (by pointer, not edit)

The 07-21 closing rule ("do not reintroduce a background-subagent driver unless the platform
documents parent re-engagement on child completion") stands unmodified for its subject. This log
adds the adjacent rule it never reached, now in RULES §22: no mechanism may be the sole means by
which a session obtains a turn unless the platform guarantees its delivery — `decision:"block"`
on Stop qualifies; the inbox socket does not. D-002 item 3 of the 07-21 log ("no session
resumption for a teammate that stalls") is retired for the OWN-SESSION case by P2/P5 and intact
for teammates; D-002 item 4 (watchdog re-poke) is reaffirmed — the doorbell was that shape.
Probes owed before any future revisit: harness resume for a `run_in_background:true` dispatch on
a background-capable host; whether UserPromptSubmit payloads distinguish peer-origin turns.
