# bootstrap-transform fixture provenance

tier: synthetic
consumer: `tests/test-bootstrap-transform.sh`, driving `scripts/bootstrap-transform.sh` and `scripts/lib/bootstrap-scrub-map.sh`
reason: this fixture is the scrubber's own input corpus — the Nazgul tokens in `input/` are the point, not a leak

## What it is

`input/` is a miniature stand-in for a project that has been through `/nazgul:init`:
context notes, generated agents, and generated docs, all still carrying the Nazgul
vocabulary the bootstrap scrub pass exists to remove. `expected/` is the byte-for-byte
result the scrubber must produce from it.

Every file here was hand-authored for this test. Nothing was captured from a real run,
and nothing describes a real project — the subject matter is a deliberately generic
placeholder application, so there is no third-party content at any tier.

## Why the Nazgul tokens here are not a boundary violation

`tests/test-repo-content-boundary.sh` R1 hunts operator home paths, which this fixture
has none of. It deliberately does **not** grep for Nazgul runtime vocabulary: doing so
would false-positive on exactly this directory, whose whole job is to hold that
vocabulary so the scrubber can be proven to strip it. The exemption is this tier
declaration, living with the fixture — never an inline suppression marker in the guard.

## Form pins

None. A `synthetic` fixture pins nothing about a real producer's output; its authority
is the `expected/` tree, which the consuming test compares in full. There is nothing
here that can rot out of agreement with an external reality.
