# Rust Core — Step 0 (Foundation) and Step 1 (Transition Validator) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a Rust workspace with pinned toolchain and CI, then port the task status vocabulary and transition validator into it as a CLI — while markdown remains the store — so the three shell consumers that drifted apart can call one validator.

**Architecture:** A Cargo workspace with `nazgul-core` (pure logic, no I/O, no harness knowledge) and `nazgul-cli` (argument parsing and process exit codes). Step 1 ports `scripts/lib/task-transition-guard.sh`'s state machine only: the edge table, the derived successor list, the granularity-aware dependency predicate, and the shared manifest-field reader. Nothing writes state. A differential test harness runs the shell and Rust implementations over the entire input space and asserts identical answers, which is what makes this safe to adopt incrementally.

**Tech Stack:** Rust (MSRV 1.88), `clap` 4.6 derive, `thiserror` 2, `regex` 1. No `rusqlite`, no `rmcp`, no `tokio` in this plan — the store and MCP seam land at Step 4.

**Spec:** `docs/superpowers/specs/2026-08-27-rust-core-refounding-design.md`

## Global Constraints

- **MSRV is 1.88**, required by `rmcp` 3.1.4 at Step 4. Pin it now so CI and development agree.
- **Runtime dependencies must not grow.** The shipped binary may depend on `git` only. No `jq`, no system SQLite, no network calls.
- **`main` is the default branch.** Never `master`.
- **The status vocabulary is exactly ten values:** `PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW APPROVED CHANGES_REQUESTED BLOCKED DONE CANCELLED`. `APPROVED` is real and is frequently forgotten — it appears in `TTG_STATUSES` at `scripts/lib/task-transition-guard.sh:99`.
- **The transition table has exactly 27 valid edges** out of 100 ordered pairs — 19 ordinary plus 8 into `CANCELLED`. Verified against source: `grep -cE '^\s+[A-Z_]+_[A-Z_]+\)\s+return 0 ;;' scripts/lib/task-transition-guard.sh` → `27`. It is reproduced verbatim in Task 3 from `scripts/lib/task-transition-guard.sh:33-65`. Do not add, remove, or "tidy" an edge.
- **`DONE` and `CANCELLED` are terminal** — they have no out-edges. `CANCELLED` is reachable from all eight non-terminal statuses.
- **Successor lists must be DERIVED by asking the table**, never hand-written. `ttg_allowed_next` (`:103-111`) is derived; a second hand-maintained list is exactly the duplicate-predicate defect this step exists to end.
- **"Terminal" and "never was a status" are different answers.** `allowed_next` returns an empty list for `DONE` and an error for `"BANANA"`.
- **Every checking entry point prints the fixed-grammar coverage line:** `N scanned, M skipped, K checked, F findings`, with `N == M + K`.
- **No task in this plan writes task state.** Markdown remains the store until Step 4.

---

## File Structure

| File | Responsibility |
|---|---|
| `rust-toolchain.toml` | Pins the toolchain so CI and dev agree |
| `Cargo.toml` (root) | Workspace manifest |
| `crates/nazgul-core/src/lib.rs` | Crate root, re-exports |
| `crates/nazgul-core/src/status.rs` | `Status` enum, parsing, display, `ALL` |
| `crates/nazgul-core/src/transition.rs` | The edge table, `valid_transition`, `allowed_next` |
| `crates/nazgul-core/src/dependency.rs` | `Granularity`, `dependency_satisfied`, expectation text |
| `crates/nazgul-core/src/manifest.rs` | Shared manifest-field reader |
| `crates/nazgul-cli/src/main.rs` | `clap` command tree, exit codes |
| `.github/workflows/rust.yml` | Native build matrix with artifact assertion |
| `tests/test-rust-shell-differential.sh` | Differential harness: shell vs Rust over the whole input space |

---

## Part A — Foundation

### Task 1: Pin the toolchain and create the workspace

**Files:**
- Create: `rust-toolchain.toml`
- Create: `Cargo.toml`
- Create: `crates/nazgul-core/Cargo.toml`
- Create: `crates/nazgul-core/src/lib.rs`
- Create: `crates/nazgul-cli/Cargo.toml`
- Create: `crates/nazgul-cli/src/main.rs`
- Modify: `.gitignore` — add `/target`

**Interfaces:**
- Consumes: nothing
- Produces: a buildable workspace; `nazgul_core` as a library crate name; a `nazgul` binary

**Context:** This machine has `rustc 1.86.0` from Homebrew with no `rustup`. MSRV 1.88 is required. Install `rustup` (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`) rather than upgrading the Homebrew Rust, so the toolchain file is authoritative and CI matches local exactly.

- [ ] **Step 1: Install rustup and the pinned toolchain**

```bash
command -v rustup >/dev/null 2>&1 || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install 1.88.0
rustup default 1.88.0
rustc --version
```

Expected: `rustc 1.88.0 (...)`. If it prints 1.86.0, the Homebrew binary is still ahead on `PATH`; put `$HOME/.cargo/bin` first.

- [ ] **Step 2: Write the toolchain pin**

Create `rust-toolchain.toml`:

```toml
[toolchain]
channel = "1.88.0"
components = ["rustfmt", "clippy"]
profile = "minimal"
```

- [ ] **Step 3: Write the workspace manifest**

Create `Cargo.toml`:

```toml
[workspace]
resolver = "2"
members = ["crates/nazgul-core", "crates/nazgul-cli"]

[workspace.package]
edition = "2021"
rust-version = "1.88"
license = "MIT"

[workspace.dependencies]
thiserror = "2"
regex = "1"
clap = { version = "4.6", features = ["derive"] }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
strip = true
panic = "abort"
```

- [ ] **Step 4: Write the core crate manifest and an empty lib**

Create `crates/nazgul-core/Cargo.toml`:

```toml
[package]
name = "nazgul-core"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
thiserror.workspace = true
regex.workspace = true
```

Create `crates/nazgul-core/src/lib.rs`:

```rust
//! Nazgul core: state machine, evidence types, and rendering.
//! Contains no knowledge of any agent harness.
```

- [ ] **Step 5: Write the CLI crate manifest and a stub main**

Create `crates/nazgul-cli/Cargo.toml`:

```toml
[package]
name = "nazgul-cli"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[[bin]]
name = "nazgul"
path = "src/main.rs"

[dependencies]
nazgul-core = { path = "../nazgul-core" }
clap.workspace = true
```

Create `crates/nazgul-cli/src/main.rs`:

```rust
fn main() {
    println!("nazgul {}", env!("CARGO_PKG_VERSION"));
}
```

- [ ] **Step 6: Add the target directory to .gitignore**

Append to `.gitignore`:

```gitignore
# Rust build artifacts
/target
```

- [ ] **Step 7: Build and verify the artifact exists**

```bash
cargo build --release
test -x target/release/nazgul || { echo "FAIL: binary absent despite build exit 0"; exit 1; }
./target/release/nazgul
```

Expected: prints `nazgul 0.1.0`. The `test -x` is deliberate — see Task 2.

- [ ] **Step 8: Commit**

```bash
git add rust-toolchain.toml Cargo.toml Cargo.lock crates/ .gitignore
git commit -m "feat(rust): pin toolchain 1.88 and scaffold nazgul-core/nazgul-cli workspace"
```

---

### Task 2: CI that proves an artifact exists

**Files:**
- Create: `.github/workflows/rust.yml`

**Interfaces:**
- Consumes: the workspace from Task 1
- Produces: CI green on four targets

**Context:** During design, `cargo build` failed its MSRV check and the wrapper still reported exit code 0; the failure was caught only because the binary was absent from disk. `RULES.md` §15's doctrine — "looked and found none" is not "never looked" — applies to build steps. **Every build job must assert the artifact exists**, never trust the exit code alone.

Use native runners, not `cross`: Step 4 adds `rusqlite` with `bundled`, which compiles vendored SQLite C source and needs a C toolchain. `ubuntu-24.04-arm` is free for public repos.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/rust.yml`:

```yaml
name: rust

on:
  push:
    paths: ['crates/**', 'Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml', '.github/workflows/rust.yml']
  pull_request:
    paths: ['crates/**', 'Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml', '.github/workflows/rust.yml']

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@1.88.0
        with:
          components: rustfmt, clippy
      - run: cargo fmt --all -- --check
      - run: cargo clippy --workspace --all-targets -- -D warnings
      - run: cargo test --workspace --all-targets

  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: macos-latest,     target: aarch64-apple-darwin }
          - { os: macos-13,         target: x86_64-apple-darwin }
          - { os: ubuntu-latest,    target: x86_64-unknown-linux-gnu }
          - { os: ubuntu-24.04-arm, target: aarch64-unknown-linux-gnu }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@1.88.0
        with:
          targets: ${{ matrix.target }}
      - run: cargo build --release --target ${{ matrix.target }}
      - name: Assert the artifact exists
        run: |
          BIN="target/${{ matrix.target }}/release/nazgul"
          if [ ! -x "$BIN" ]; then
            echo "FAIL: $BIN absent or not executable despite a zero exit from cargo build"
            exit 1
          fi
          echo "ok: $BIN ($(wc -c < "$BIN") bytes)"
```

- [ ] **Step 2: Verify the workflow parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/rust.yml')); print('yaml ok')"
```

Expected: `yaml ok`

- [ ] **Step 3: Verify fmt and clippy pass locally before pushing**

```bash
cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings
```

Expected: both silent, exit 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/rust.yml
git commit -m "ci(rust): native four-target matrix asserting artifact existence, not exit code"
```

---

## Part B — The transition validator

### Task 3: The Status enum and the transition table

**Files:**
- Create: `crates/nazgul-core/src/status.rs`
- Create: `crates/nazgul-core/src/transition.rs`
- Modify: `crates/nazgul-core/src/lib.rs`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `Status` (enum, `Copy`), `Status::ALL: [Status; 10]`, `Status::as_str(&self) -> &'static str`
  - `impl FromStr for Status`, `Err = ParseStatusError`
  - `transition::valid_transition(from: Status, to: Status) -> bool`

**Context — port fidelity:** the table below is transcribed from `scripts/lib/task-transition-guard.sh:33-65`. Twenty-four edges. `IMPLEMENTED -> DONE` is in the graph but is refused by a later evidence gate unless merge evidence validates (ADR-023) — that gate is Step 2, not this task. Keep the edge.

- [ ] **Step 1: Write the failing tests**

Create `crates/nazgul-core/src/status.rs` with tests only at first, then `transition.rs`. Put this in `crates/nazgul-core/src/transition.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::Status::*;

    /// The 24 edges, transcribed from task-transition-guard.sh:33-65.
    const EXPECTED_EDGES: &[(Status, Status)] = &[
        (Planned, Ready),
        (Planned, Blocked),
        (Ready, Blocked),
        (Ready, InProgress),
        (InProgress, Implemented),
        (InProgress, Blocked),
        (Implemented, Blocked),
        (Implemented, InReview),
        (Implemented, Done),
        (InReview, Done),
        (InReview, Approved),
        (InReview, ChangesRequested),
        (InReview, Blocked),
        (Approved, Done),
        (Approved, Blocked),
        (ChangesRequested, InProgress),
        (ChangesRequested, Blocked),
        (Blocked, Ready),
        (Blocked, InReview),
        (Planned, Cancelled),
        (Ready, Cancelled),
        (InProgress, Cancelled),
        (Implemented, Cancelled),
        (InReview, Cancelled),
        (Approved, Cancelled),
        (ChangesRequested, Cancelled),
        (Blocked, Cancelled),
    ];

    #[test]
    fn table_has_exactly_the_expected_edges() {
        for (from, to) in EXPECTED_EDGES {
            assert!(
                valid_transition(*from, *to),
                "expected edge {}->{} to be valid",
                from.as_str(),
                to.as_str()
            );
        }
    }

    #[test]
    fn every_other_pair_is_invalid() {
        let mut valid_count = 0usize;
        for from in Status::ALL {
            for to in Status::ALL {
                if valid_transition(from, to) {
                    valid_count += 1;
                    assert!(
                        EXPECTED_EDGES.contains(&(from, to)),
                        "unexpected edge {}->{}",
                        from.as_str(),
                        to.as_str()
                    );
                }
            }
        }
        assert_eq!(valid_count, EXPECTED_EDGES.len(), "edge count drifted");
    }

    #[test]
    fn terminal_statuses_have_no_out_edges() {
        for to in Status::ALL {
            assert!(!valid_transition(Status::Done, to), "DONE must be terminal");
            assert!(!valid_transition(Status::Cancelled, to), "CANCELLED must be terminal");
        }
    }

    #[test]
    fn cancelled_is_reachable_from_every_non_terminal_status() {
        for from in Status::ALL {
            if matches!(from, Status::Done | Status::Cancelled) {
                continue;
            }
            assert!(
                valid_transition(from, Status::Cancelled),
                "{} must reach CANCELLED",
                from.as_str()
            );
        }
    }

    #[test]
    fn no_self_edges() {
        for s in Status::ALL {
            assert!(!valid_transition(s, s), "{} -> itself must be invalid", s.as_str());
        }
    }
}
```

`EXPECTED_EDGES` holds **27** entries: 19 ordinary edges (source lines 33-55) plus 8 into `CANCELLED` (lines 58-65). Step 2 re-derives this from the source rather than trusting the count above.

- [ ] **Step 2: Verify the count against the shell before writing any implementation**

```bash
grep -cE '^\s+[A-Z_]+_[A-Z_]+\)\s+return 0 ;;' scripts/lib/task-transition-guard.sh
```

Expected: prints the authoritative edge count. **If it does not equal the number of entries in `EXPECTED_EDGES`, fix `EXPECTED_EDGES` — the shell is the source of truth.**

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cargo test -p nazgul-core
```

Expected: FAIL — `status.rs` and `transition.rs` are not declared in `lib.rs`, so compilation errors.

- [ ] **Step 4: Write the Status enum**

Create `crates/nazgul-core/src/status.rs`:

```rust
use std::fmt;
use std::str::FromStr;

/// Every status the machine knows. Mirrors TTG_STATUSES
/// (scripts/lib/task-transition-guard.sh:99).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Status {
    Planned,
    Ready,
    InProgress,
    Implemented,
    InReview,
    Approved,
    ChangesRequested,
    Blocked,
    Done,
    Cancelled,
}

impl Status {
    pub const ALL: [Status; 10] = [
        Status::Planned,
        Status::Ready,
        Status::InProgress,
        Status::Implemented,
        Status::InReview,
        Status::Approved,
        Status::ChangesRequested,
        Status::Blocked,
        Status::Done,
        Status::Cancelled,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            Status::Planned => "PLANNED",
            Status::Ready => "READY",
            Status::InProgress => "IN_PROGRESS",
            Status::Implemented => "IMPLEMENTED",
            Status::InReview => "IN_REVIEW",
            Status::Approved => "APPROVED",
            Status::ChangesRequested => "CHANGES_REQUESTED",
            Status::Blocked => "BLOCKED",
            Status::Done => "DONE",
            Status::Cancelled => "CANCELLED",
        }
    }

    /// Terminal statuses have no out-edges.
    pub fn is_terminal(&self) -> bool {
        matches!(self, Status::Done | Status::Cancelled)
    }
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("not a status: {0}")]
pub struct ParseStatusError(pub String);

impl FromStr for Status {
    type Err = ParseStatusError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Status::ALL
            .iter()
            .copied()
            .find(|c| c.as_str() == s)
            .ok_or_else(|| ParseStatusError(s.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_has_ten_entries_and_no_duplicates() {
        assert_eq!(Status::ALL.len(), 10);
        let mut seen: Vec<&str> = Status::ALL.iter().map(|s| s.as_str()).collect();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), 10, "duplicate status spelling");
    }

    #[test]
    fn round_trips_through_str() {
        for s in Status::ALL {
            assert_eq!(Status::from_str(s.as_str()), Ok(s));
        }
    }

    #[test]
    fn rejects_unknown_and_lowercase() {
        assert!(Status::from_str("BANANA").is_err());
        assert!(Status::from_str("done").is_err(), "parsing is case-sensitive");
    }

    #[test]
    fn approved_exists() {
        assert_eq!(Status::from_str("APPROVED"), Ok(Status::Approved));
    }
}
```

- [ ] **Step 5: Write the transition table**

Prepend to `crates/nazgul-core/src/transition.rs` (above the existing `mod tests`):

```rust
use crate::status::Status;

/// Constitution Article III state machine. Transcribed from
/// scripts/lib/task-transition-guard.sh:33-65. One source of truth for
/// every consumer; a second hand-maintained copy is the defect this ends.
pub fn valid_transition(from: Status, to: Status) -> bool {
    use Status::*;
    matches!(
        (from, to),
        (Planned, Ready)
            | (Planned, Blocked)
            | (Ready, Blocked)
            | (Ready, InProgress)
            | (InProgress, Implemented)
            | (InProgress, Blocked)
            | (Implemented, Blocked)
            | (Implemented, InReview)
            // ADR-023: in the graph, but a later evidence gate refuses it
            // unless merge evidence validates. Never unconditional.
            | (Implemented, Done)
            | (InReview, Done)
            | (InReview, Approved)
            | (InReview, ChangesRequested)
            | (InReview, Blocked)
            | (Approved, Done)
            | (Approved, Blocked)
            | (ChangesRequested, InProgress)
            | (ChangesRequested, Blocked)
            // BLOCKED exits: READY via /nazgul:task unblock,
            // IN_REVIEW via /nazgul:review --materialize.
            | (Blocked, Ready)
            | (Blocked, InReview)
            // ADR-022: CANCELLED is terminal and reachable from every
            // non-terminal status.
            | (Planned, Cancelled)
            | (Ready, Cancelled)
            | (InProgress, Cancelled)
            | (Implemented, Cancelled)
            | (InReview, Cancelled)
            | (Approved, Cancelled)
            | (ChangesRequested, Cancelled)
            | (Blocked, Cancelled)
    )
}
```

- [ ] **Step 6: Declare the modules**

Replace `crates/nazgul-core/src/lib.rs`:

```rust
//! Nazgul core: state machine, evidence types, and rendering.
//! Contains no knowledge of any agent harness.

pub mod status;
pub mod transition;

pub use status::{ParseStatusError, Status};
pub use transition::valid_transition;
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cargo test -p nazgul-core
```

Expected: PASS, 9 tests.

- [ ] **Step 8: Commit**

```bash
git add crates/nazgul-core/src/
git commit -m "feat(core): port the Status vocabulary and transition table from task-transition-guard.sh"
```

---

### Task 4: Derived successor lists

**Files:**
- Modify: `crates/nazgul-core/src/transition.rs`
- Modify: `crates/nazgul-core/src/lib.rs:6` (re-export)

**Interfaces:**
- Consumes: `Status`, `valid_transition` from Task 3
- Produces: `transition::allowed_next(from: Status) -> Vec<Status>`

**Context:** `ttg_allowed_next` (`scripts/lib/task-transition-guard.sh:103-111`) is **derived** by asking `ttg_valid_transition`, and returns rc 1 for a non-status because *"terminal" and "never was one" differ*. In Rust the type system gives us half of that for free — you cannot pass a non-`Status` — so the distinction is preserved at the CLI boundary in Task 7, where a string arrives.

- [ ] **Step 1: Write the failing tests**

Append to the `mod tests` block in `crates/nazgul-core/src/transition.rs`:

```rust
    #[test]
    fn allowed_next_is_derived_from_the_table() {
        for from in Status::ALL {
            let derived: Vec<Status> = Status::ALL
                .into_iter()
                .filter(|to| valid_transition(from, *to))
                .collect();
            assert_eq!(allowed_next(from), derived, "allowed_next drifted from the table");
        }
    }

    #[test]
    fn allowed_next_returns_results_in_status_all_order() {
        let got = allowed_next(Status::InReview);
        let want: Vec<Status> = Status::ALL
            .into_iter()
            .filter(|to| valid_transition(Status::InReview, *to))
            .collect();
        assert_eq!(got, want);
        assert_eq!(got.len(), 5, "IN_REVIEW has five successors");
    }

    #[test]
    fn terminal_statuses_yield_empty_successor_lists() {
        assert!(allowed_next(Status::Done).is_empty());
        assert!(allowed_next(Status::Cancelled).is_empty());
    }

    #[test]
    fn planned_has_exactly_three_successors() {
        let mut got = allowed_next(Status::Planned);
        got.sort();
        let mut want = vec![Status::Ready, Status::Blocked, Status::Cancelled];
        want.sort();
        assert_eq!(got, want);
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
cargo test -p nazgul-core allowed_next
```

Expected: FAIL — `cannot find function 'allowed_next'`.

- [ ] **Step 3: Implement**

Append to `crates/nazgul-core/src/transition.rs`, after `valid_transition`:

```rust
/// A status's legal successors, DERIVED by asking the table — never a
/// second hand-maintained list. Mirrors ttg_allowed_next
/// (scripts/lib/task-transition-guard.sh:103-111).
/// Terminal statuses yield an empty list; that is a real answer, not an error.
pub fn allowed_next(from: Status) -> Vec<Status> {
    Status::ALL
        .into_iter()
        .filter(|to| valid_transition(from, *to))
        .collect()
}
```

- [ ] **Step 4: Re-export and run tests**

Add to `crates/nazgul-core/src/lib.rs`:

```rust
pub use transition::{allowed_next, valid_transition};
```

(replacing the previous single-item `pub use transition::valid_transition;`)

```bash
cargo test -p nazgul-core
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/nazgul-core/src/
git commit -m "feat(core): derive allowed_next from the transition table"
```

---

### Task 5: Granularity-aware dependency predicate

**Files:**
- Create: `crates/nazgul-core/src/dependency.rs`
- Modify: `crates/nazgul-core/src/lib.rs`

**Interfaces:**
- Consumes: `Status` from Task 3
- Produces:
  - `Granularity` enum (`Task`, `Group`, `Feature`), `impl FromStr`
  - `dependency::dependency_satisfied(dep: Status, granularity: Granularity, yolo: bool) -> bool`
  - `dependency::expectation(granularity: Granularity, yolo: bool) -> String`

**Context:** Ported from `ttg_dependency_satisfied` (`scripts/lib/task-transition-guard.sh:203-229`). Three arms, and the reason they differ is load-bearing: under `group`/`feature` granularity **every task parks at IMPLEMENTED until one aggregate board runs**, so requiring `DONE` would be unsatisfiable. A `CANCELLED` dependency satisfies in **every** granularity (ADR-022) — it will never ship, so waiting on it is waiting forever.

`expectation()` reproduces `TTG_DEP_EXPECTED`, which callers print in diagnostics. The exact strings matter for the differential test in Task 8.

- [ ] **Step 1: Write the failing tests**

Create `crates/nazgul-core/src/dependency.rs` containing only:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::Status::*;

    #[test]
    fn group_and_feature_accept_implemented_or_later_plus_cancelled() {
        for g in [Granularity::Group, Granularity::Feature] {
            for s in [Implemented, InReview, Approved, Done, Cancelled] {
                assert!(dependency_satisfied(s, g, false), "{s} should satisfy under {g:?}");
            }
            for s in [Planned, Ready, InProgress, ChangesRequested, Blocked] {
                assert!(!dependency_satisfied(s, g, false), "{s} must not satisfy under {g:?}");
            }
        }
    }

    #[test]
    fn task_granularity_demands_done_or_cancelled() {
        for s in [Done, Cancelled] {
            assert!(dependency_satisfied(s, Granularity::Task, false));
        }
        for s in [Planned, Ready, InProgress, Implemented, InReview, Approved, ChangesRequested, Blocked] {
            assert!(!dependency_satisfied(s, Granularity::Task, false), "{s} must not satisfy");
        }
    }

    #[test]
    fn yolo_additionally_accepts_approved_under_task_granularity() {
        assert!(dependency_satisfied(Approved, Granularity::Task, true));
        assert!(!dependency_satisfied(Approved, Granularity::Task, false));
        assert!(dependency_satisfied(Done, Granularity::Task, true));
        assert!(dependency_satisfied(Cancelled, Granularity::Task, true));
        assert!(!dependency_satisfied(Implemented, Granularity::Task, true));
    }

    #[test]
    fn yolo_does_not_change_group_or_feature() {
        for g in [Granularity::Group, Granularity::Feature] {
            for s in Status::ALL {
                assert_eq!(
                    dependency_satisfied(s, g, true),
                    dependency_satisfied(s, g, false),
                    "yolo must not alter {g:?}"
                );
            }
        }
    }

    #[test]
    fn cancelled_satisfies_in_every_configuration() {
        for g in [Granularity::Task, Granularity::Group, Granularity::Feature] {
            for yolo in [true, false] {
                assert!(dependency_satisfied(Cancelled, g, yolo));
            }
        }
    }

    #[test]
    fn expectation_strings_match_the_shell() {
        assert_eq!(
            expectation(Granularity::Group, false),
            "IMPLEMENTED or later (review_gate.granularity=group) or CANCELLED"
        );
        assert_eq!(
            expectation(Granularity::Feature, false),
            "IMPLEMENTED or later (review_gate.granularity=feature) or CANCELLED"
        );
        assert_eq!(expectation(Granularity::Task, true), "APPROVED/DONE/CANCELLED");
        assert_eq!(expectation(Granularity::Task, false), "DONE or CANCELLED");
    }

    #[test]
    fn granularity_parses_and_defaults_are_explicit() {
        assert_eq!("task".parse::<Granularity>(), Ok(Granularity::Task));
        assert_eq!("group".parse::<Granularity>(), Ok(Granularity::Group));
        assert_eq!("feature".parse::<Granularity>(), Ok(Granularity::Feature));
        assert!("BANANA".parse::<Granularity>().is_err());
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cargo test -p nazgul-core dependency
```

Expected: FAIL — module not declared, symbols missing.

- [ ] **Step 3: Implement**

Prepend to `crates/nazgul-core/src/dependency.rs`:

```rust
use crate::status::Status;
use std::str::FromStr;

/// review_gate.granularity. Under group/feature every task parks at
/// IMPLEMENTED until one aggregate board runs, so DONE is unsatisfiable there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Granularity {
    Task,
    Group,
    Feature,
}

impl Granularity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Granularity::Task => "task",
            Granularity::Group => "group",
            Granularity::Feature => "feature",
        }
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("not a granularity: {0}")]
pub struct ParseGranularityError(pub String);

impl FromStr for Granularity {
    type Err = ParseGranularityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "task" => Ok(Granularity::Task),
            "group" => Ok(Granularity::Group),
            "feature" => Ok(Granularity::Feature),
            other => Err(ParseGranularityError(other.to_string())),
        }
    }
}

/// Is one PLANNED -> READY dependency satisfied?
/// Ported from ttg_dependency_satisfied (task-transition-guard.sh:203-229).
/// ADR-022: a CANCELLED dependency satisfies in EVERY granularity — it will
/// never ship, so waiting on it is waiting forever.
pub fn dependency_satisfied(dep: Status, granularity: Granularity, yolo: bool) -> bool {
    use Status::*;
    match granularity {
        Granularity::Group | Granularity::Feature => {
            matches!(dep, Implemented | InReview | Approved | Done | Cancelled)
        }
        Granularity::Task if yolo => matches!(dep, Done | Approved | Cancelled),
        Granularity::Task => matches!(dep, Done | Cancelled),
    }
}

/// The requirement in words, for a caller's diagnostic.
/// Mirrors TTG_DEP_EXPECTED; the exact strings are asserted by the
/// differential harness, so do not reword them.
pub fn expectation(granularity: Granularity, yolo: bool) -> String {
    match granularity {
        Granularity::Group | Granularity::Feature => format!(
            "IMPLEMENTED or later (review_gate.granularity={}) or CANCELLED",
            granularity.as_str()
        ),
        Granularity::Task if yolo => "APPROVED/DONE/CANCELLED".to_string(),
        Granularity::Task => "DONE or CANCELLED".to_string(),
    }
}
```

- [ ] **Step 4: Declare the module and run tests**

Add to `crates/nazgul-core/src/lib.rs`:

```rust
pub mod dependency;
pub use dependency::{dependency_satisfied, Granularity, ParseGranularityError};
```

```bash
cargo test -p nazgul-core
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/nazgul-core/src/
git commit -m "feat(core): port the granularity-aware dependency predicate"
```

---

### Task 6: Shared manifest-field reader

**Files:**
- Create: `crates/nazgul-core/src/manifest.rs`
- Modify: `crates/nazgul-core/src/lib.rs`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `manifest::FieldValue` enum — `Absent` | `Present(String)`
  - `manifest::field(text: &str, name: &str) -> FieldValue`
  - `manifest::is_reconciliation_quarantine(text: &str) -> bool`

**Context:** `ttg_manifest_field` (`:75-81`) reads the **first** matching line, case-insensitively, off the shared anchor `NZ_MANIFEST_FIELD_ANCHOR` = `^[[:space:]]*-[[:space:]]*\*\*` + field + `\*\*:`. It returns rc 1 when the line is absent, and **rc 0 with empty output when present but blanked — a different fact.** That distinction becomes `FieldValue`.

`ttg_is_reconciliation_quarantine` (`:92-95`) deliberately does **not** go through the field reader: it asks whether **any** line carries a live quarantine, not what the first one says. Routing it through a first-match reader was a real shipped defect (PATCH-007 item 9 / PATCH-008 item 1) — a manifest with `review-evidence` above `reconciliation` stopped being a quarantine and an illegal edge was admitted. The end-of-value anchor is what stops an already-repaired `reconciliation (repaired ...)` re-qualifying. **Preserve both properties.**

- [ ] **Step 1: Write the failing tests**

Create `crates/nazgul-core/src/manifest.rs` containing only:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_simple_field() {
        let m = "- **Status**: IN_REVIEW\n";
        assert_eq!(field(m, "Status"), FieldValue::Present("IN_REVIEW".into()));
    }

    #[test]
    fn absent_and_blank_are_different_facts() {
        assert_eq!(field("- **Other**: x\n", "Status"), FieldValue::Absent);
        assert_eq!(field("- **Status**:\n", "Status"), FieldValue::Present(String::new()));
        assert_eq!(field("- **Status**:   \n", "Status"), FieldValue::Present(String::new()));
    }

    #[test]
    fn takes_the_first_match_only() {
        let m = "- **Status**: DONE\n- **Status**: BLOCKED\n";
        assert_eq!(field(m, "Status"), FieldValue::Present("DONE".into()));
    }

    #[test]
    fn field_name_match_is_case_insensitive() {
        assert_eq!(field("- **status**: DONE\n", "Status"), FieldValue::Present("DONE".into()));
    }

    #[test]
    fn tolerates_leading_whitespace_and_spacing_variants() {
        assert_eq!(field("   -   **Status**: DONE\n", "Status"), FieldValue::Present("DONE".into()));
    }

    #[test]
    fn value_may_contain_colons() {
        let m = "- **Blocked reason**: failed: twice\n";
        assert_eq!(field(m, "Blocked reason"), FieldValue::Present("failed: twice".into()));
    }

    #[test]
    fn quarantine_detected_on_any_line_not_just_the_first() {
        let m = "- **Blocked kind**: review-evidence\n- **Blocked kind**: reconciliation\n";
        assert!(
            is_reconciliation_quarantine(m),
            "must scan every line; first-match narrowing was a shipped defect"
        );
    }

    #[test]
    fn quarantine_rejects_a_repaired_value() {
        let m = "- **Blocked kind**: reconciliation (repaired by hand)\n";
        assert!(!is_reconciliation_quarantine(m), "end-of-value anchor must hold");
    }

    #[test]
    fn quarantine_tolerates_trailing_whitespace_and_case() {
        assert!(is_reconciliation_quarantine("- **blocked kind**: RECONCILIATION   \n"));
    }

    #[test]
    fn quarantine_absent_when_no_such_line() {
        assert!(!is_reconciliation_quarantine("- **Status**: BLOCKED\n"));
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cargo test -p nazgul-core manifest
```

Expected: FAIL — module not declared.

- [ ] **Step 3: Implement**

Prepend to `crates/nazgul-core/src/manifest.rs`:

```rust
use regex::Regex;

/// A field lookup's result. `Absent` (no such line) and `Present("")`
/// (line exists, value blanked) are DIFFERENT FACTS — collapsing them is
/// the "looked and found none" vs "never looked" defect (RULES.md §15).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldValue {
    Absent,
    Present(String),
}

impl FieldValue {
    pub fn as_deref(&self) -> Option<&str> {
        match self {
            FieldValue::Absent => None,
            FieldValue::Present(v) => Some(v.as_str()),
        }
    }
}

/// The shared `- **Field**: value` anchor, matching NZ_MANIFEST_FIELD_ANCHOR
/// (scripts/lib/task-utils.sh:171). Case-insensitive on the field name.
fn field_pattern(name: &str) -> Regex {
    let escaped = regex::escape(name);
    Regex::new(&format!(r"(?im)^[ \t]*-[ \t]*\*\*{escaped}\*\*:"))
        .expect("field name escaped, pattern is well-formed")
}

/// The FIRST matching line's trimmed value.
/// Mirrors ttg_manifest_field (task-transition-guard.sh:75-81).
pub fn field(text: &str, name: &str) -> FieldValue {
    let re = field_pattern(name);
    for line in text.lines() {
        if re.is_match(line) {
            // The anchor ends at "**:", so the first colon after it delimits
            // the value. A value containing further colons is preserved.
            let value = match line.split_once("**:") {
                Some((_, rest)) => rest,
                None => "",
            };
            return FieldValue::Present(value.trim().to_string());
        }
    }
    FieldValue::Absent
}

/// Does this manifest carry a LIVE typed reconciliation quarantine ANYWHERE?
/// Deliberately not routed through `field`: that answers "what does the first
/// such line say", which narrowed this predicate and admitted an illegal
/// BLOCKED -> CANCELLED edge (PATCH-008 item 1). The end-of-value anchor is
/// what stops an already-repaired value re-qualifying.
pub fn is_reconciliation_quarantine(text: &str) -> bool {
    let re = Regex::new(r"(?im)^[ \t]*-[ \t]*\*\*Blocked kind\*\*:[ \t]*reconciliation[ \t]*$")
        .expect("static pattern is well-formed");
    text.lines().any(|line| re.is_match(line.trim_end_matches('\r')))
}
```

- [ ] **Step 4: Declare the module and run tests**

Add to `crates/nazgul-core/src/lib.rs`:

```rust
pub mod manifest;
pub use manifest::{field, is_reconciliation_quarantine, FieldValue};
```

```bash
cargo test -p nazgul-core
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/nazgul-core/src/
git commit -m "feat(core): shared manifest-field reader preserving absent-vs-blank and any-line quarantine"
```

---

### Task 7: The CLI surface

**Files:**
- Modify: `crates/nazgul-cli/src/main.rs`

**Interfaces:**
- Consumes: everything from Tasks 3-6
- Produces: the `nazgul` binary with `validate transition|dependency|allowed-next` and `manifest field|quarantine`

**Context:** Exit codes are the contract, because shell callers test them. **0 = valid/satisfied/present, 1 = invalid/unsatisfied/absent, 2 = input was not a status or granularity at all.** That third code is where `ttg_allowed_next`'s *"terminal and never-was-one differ"* distinction lives, now that a string can arrive from outside.

- [ ] **Step 1: Write the failing integration test**

Create `crates/nazgul-cli/tests/cli.rs`:

```rust
use std::process::Command;

fn nazgul(args: &[&str]) -> (i32, String) {
    let exe = env!("CARGO_BIN_EXE_nazgul");
    let out = Command::new(exe).args(args).output().expect("binary runs");
    let mut s = String::from_utf8_lossy(&out.stdout).to_string();
    s.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.code().unwrap_or(-1), s)
}

#[test]
fn valid_transition_exits_zero() {
    let (code, _) = nazgul(&["validate", "transition", "PLANNED", "READY"]);
    assert_eq!(code, 0);
}

#[test]
fn invalid_transition_exits_one() {
    let (code, _) = nazgul(&["validate", "transition", "PLANNED", "DONE"]);
    assert_eq!(code, 1);
}

#[test]
fn unknown_status_exits_two() {
    let (code, out) = nazgul(&["validate", "transition", "BANANA", "READY"]);
    assert_eq!(code, 2, "not-a-status is a third answer, not merely invalid");
    assert!(out.contains("BANANA"));
}

#[test]
fn allowed_next_lists_successors_and_terminal_is_empty_with_exit_zero() {
    let (code, out) = nazgul(&["validate", "allowed-next", "PLANNED"]);
    assert_eq!(code, 0);
    assert!(out.contains("READY") && out.contains("BLOCKED") && out.contains("CANCELLED"));

    let (code, out) = nazgul(&["validate", "allowed-next", "DONE"]);
    assert_eq!(code, 0, "terminal is a real answer");
    assert_eq!(out.trim(), "");
}

#[test]
fn allowed_next_on_non_status_exits_two() {
    let (code, _) = nazgul(&["validate", "allowed-next", "BANANA"]);
    assert_eq!(code, 2);
}

#[test]
fn dependency_respects_granularity_and_yolo() {
    let (code, _) = nazgul(&["validate", "dependency", "--status", "IMPLEMENTED", "--granularity", "group"]);
    assert_eq!(code, 0);

    let (code, _) = nazgul(&["validate", "dependency", "--status", "IMPLEMENTED", "--granularity", "task"]);
    assert_eq!(code, 1);

    let (code, _) = nazgul(&["validate", "dependency", "--status", "APPROVED", "--granularity", "task", "--yolo"]);
    assert_eq!(code, 0);
}

#[test]
fn dependency_prints_the_expectation_on_failure() {
    let (_, out) = nazgul(&["validate", "dependency", "--status", "READY", "--granularity", "task"]);
    assert!(out.contains("DONE or CANCELLED"));
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cargo test -p nazgul-cli
```

Expected: FAIL — the binary does not accept these subcommands.

- [ ] **Step 3: Implement the command tree**

Replace `crates/nazgul-cli/src/main.rs`:

```rust
use clap::{Parser, Subcommand};
use nazgul_core::{
    allowed_next, dependency, manifest, valid_transition, FieldValue, Granularity, Status,
};
use std::process::ExitCode;

/// Exit codes are the contract: shell callers test them.
/// 0 = yes, 1 = no, 2 = the input was not a member of the vocabulary at all.
const EXIT_YES: u8 = 0;
const EXIT_NO: u8 = 1;
const EXIT_NOT_A_MEMBER: u8 = 2;

#[derive(Parser)]
#[command(name = "nazgul", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// State-machine queries. Never writes.
    #[command(subcommand)]
    Validate(Validate),
    /// Manifest reads. Never writes.
    #[command(subcommand)]
    Manifest(ManifestCmd),
}

#[derive(Subcommand)]
enum Validate {
    /// Is FROM -> TO a legal edge?
    Transition { from: String, to: String },
    /// List a status's legal successors, one per line.
    AllowedNext { from: String },
    /// Is a PLANNED -> READY dependency satisfied?
    Dependency {
        #[arg(long)]
        status: String,
        #[arg(long, default_value = "task")]
        granularity: String,
        #[arg(long)]
        yolo: bool,
    },
}

#[derive(Subcommand)]
enum ManifestCmd {
    /// Print a field's value. Exit 1 when the field is absent.
    Field {
        #[arg(long)]
        file: std::path::PathBuf,
        #[arg(long)]
        name: String,
    },
    /// Exit 0 when the manifest carries a live reconciliation quarantine.
    Quarantine {
        #[arg(long)]
        file: std::path::PathBuf,
    },
}

fn parse_status(s: &str) -> Result<Status, ExitCode> {
    s.parse::<Status>().map_err(|e| {
        eprintln!("nazgul: {e}");
        ExitCode::from(EXIT_NOT_A_MEMBER)
    })
}

fn parse_granularity(s: &str) -> Result<Granularity, ExitCode> {
    s.parse::<Granularity>().map_err(|e| {
        eprintln!("nazgul: {e}");
        ExitCode::from(EXIT_NOT_A_MEMBER)
    })
}

fn read(path: &std::path::Path) -> Result<String, ExitCode> {
    std::fs::read_to_string(path).map_err(|e| {
        eprintln!("nazgul: cannot read {}: {e}", path.display());
        ExitCode::from(EXIT_NOT_A_MEMBER)
    })
}

fn run() -> Result<ExitCode, ExitCode> {
    let cli = Cli::parse();
    Ok(match cli.command {
        Command::Validate(Validate::Transition { from, to }) => {
            let (f, t) = (parse_status(&from)?, parse_status(&to)?);
            if valid_transition(f, t) {
                ExitCode::from(EXIT_YES)
            } else {
                eprintln!("nazgul: {f} -> {t} is not a legal transition");
                ExitCode::from(EXIT_NO)
            }
        }
        Command::Validate(Validate::AllowedNext { from }) => {
            let f = parse_status(&from)?;
            for s in allowed_next(f) {
                println!("{s}");
            }
            ExitCode::from(EXIT_YES)
        }
        Command::Validate(Validate::Dependency {
            status,
            granularity,
            yolo,
        }) => {
            let s = parse_status(&status)?;
            let g = parse_granularity(&granularity)?;
            if dependency::dependency_satisfied(s, g, yolo) {
                ExitCode::from(EXIT_YES)
            } else {
                eprintln!(
                    "nazgul: dependency at {s} does not satisfy; expected {}",
                    dependency::expectation(g, yolo)
                );
                ExitCode::from(EXIT_NO)
            }
        }
        Command::Manifest(ManifestCmd::Field { file, name }) => {
            let text = read(&file)?;
            match manifest::field(&text, &name) {
                FieldValue::Present(v) => {
                    println!("{v}");
                    ExitCode::from(EXIT_YES)
                }
                FieldValue::Absent => {
                    eprintln!("nazgul: field '{name}' absent");
                    ExitCode::from(EXIT_NO)
                }
            }
        }
        Command::Manifest(ManifestCmd::Quarantine { file }) => {
            let text = read(&file)?;
            if manifest::is_reconciliation_quarantine(&text) {
                ExitCode::from(EXIT_YES)
            } else {
                ExitCode::from(EXIT_NO)
            }
        }
    })
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(code) => code,
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cargo test --workspace
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/nazgul-cli/
git commit -m "feat(cli): validate and manifest read-only subcommands with three-valued exit codes"
```

---

### Task 8: Differential harness — shell versus Rust

**Files:**
- Create: `tests/test-rust-shell-differential.sh`

**Interfaces:**
- Consumes: the `nazgul` binary; `scripts/lib/task-transition-guard.sh`
- Produces: proof that the port is faithful across the entire input space

**Context:** This is the task that makes the strangler safe. Every later step trusts that the Rust validator answers exactly as the shell does; this proves it over **all 100 ordered status pairs** and **all 60 dependency combinations** (10 statuses × 3 granularities × 2 yolo values) rather than over samples. It follows the repo's existing test conventions: `set -uo pipefail`, and the fixed-grammar coverage line.

- [ ] **Step 1: Write the harness**

Create `tests/test-rust-shell-differential.sh`:

```bash
#!/usr/bin/env bash
# Differential test: the Rust validator must answer exactly as the shell does,
# across the ENTIRE input space. This is what makes the strangler safe.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/target/release/nazgul"

if [ ! -x "$BIN" ]; then
  echo "test-rust-shell-differential: FAIL - $BIN absent; run 'cargo build --release'" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

SCANNED=0
SKIPPED=0
CHECKED=0
FINDINGS=0

STATUSES="PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW APPROVED CHANGES_REQUESTED BLOCKED DONE CANCELLED"

# --- the vocabularies must match before anything else is comparable ---
rust_vocab=$(for s in $STATUSES; do echo "$s"; done | sort)
shell_vocab=$(for s in $TTG_STATUSES; do echo "$s"; done | sort)
SCANNED=$((SCANNED + 1)); CHECKED=$((CHECKED + 1))
if [ "$rust_vocab" != "$shell_vocab" ]; then
  echo "FINDING: status vocabulary differs between harness and TTG_STATUSES" >&2
  FINDINGS=$((FINDINGS + 1))
fi

# --- all 100 ordered transition pairs ---
for from in $STATUSES; do
  for to in $STATUSES; do
    SCANNED=$((SCANNED + 1))
    ttg_valid_transition "$from" "$to"; shell_rc=$?
    "$BIN" validate transition "$from" "$to" >/dev/null 2>&1; rust_rc=$?
    CHECKED=$((CHECKED + 1))
    if [ "$shell_rc" -ne "$rust_rc" ]; then
      echo "FINDING: transition $from -> $to: shell=$shell_rc rust=$rust_rc" >&2
      FINDINGS=$((FINDINGS + 1))
    fi
  done
done

# --- allowed_next for every status ---
for from in $STATUSES; do
  SCANNED=$((SCANNED + 1))
  shell_list=$(ttg_allowed_next "$from" | tr -d ' ' | tr ',' '\n' | sed '/^$/d' | sort)
  rust_list=$("$BIN" validate allowed-next "$from" 2>/dev/null | sed '/^$/d' | sort)
  CHECKED=$((CHECKED + 1))
  if [ "$shell_list" != "$rust_list" ]; then
    echo "FINDING: allowed_next($from): shell=[$(echo "$shell_list" | tr '\n' ' ')] rust=[$(echo "$rust_list" | tr '\n' ' ')]" >&2
    FINDINGS=$((FINDINGS + 1))
  fi
done

# --- all 60 dependency combinations ---
# ttg_dependency_satisfied reads granularity and yolo from a config.json,
# so build one per combination in a temp dir.
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

for gran in task group feature; do
  for yolo in true false; do
    mkdir -p "$TMP/$gran-$yolo"
    cat > "$TMP/$gran-$yolo/config.json" <<JSON
{"review_gate":{"granularity":"$gran"},"afk":{"yolo":$yolo}}
JSON
    for dep in $STATUSES; do
      SCANNED=$((SCANNED + 1))
      ttg_dependency_satisfied "$TMP/$gran-$yolo" "$dep"; shell_rc=$?
      if [ "$yolo" = "true" ]; then
        "$BIN" validate dependency --status "$dep" --granularity "$gran" --yolo >/dev/null 2>&1
      else
        "$BIN" validate dependency --status "$dep" --granularity "$gran" >/dev/null 2>&1
      fi
      rust_rc=$?
      CHECKED=$((CHECKED + 1))
      if [ "$shell_rc" -ne "$rust_rc" ]; then
        echo "FINDING: dependency dep=$dep gran=$gran yolo=$yolo: shell=$shell_rc rust=$rust_rc" >&2
        FINDINGS=$((FINDINGS + 1))
      fi
    done
  done
done

# --- the expectation strings callers print ---
for gran in task group feature; do
  for yolo in true false; do
    SCANNED=$((SCANNED + 1))
    ttg_dependency_satisfied "$TMP/$gran-$yolo" "PLANNED" >/dev/null 2>&1
    shell_exp="$TTG_DEP_EXPECTED"
    if [ "$yolo" = "true" ]; then
      rust_exp=$("$BIN" validate dependency --status PLANNED --granularity "$gran" --yolo 2>&1 >/dev/null)
    else
      rust_exp=$("$BIN" validate dependency --status PLANNED --granularity "$gran" 2>&1 >/dev/null)
    fi
    CHECKED=$((CHECKED + 1))
    case "$rust_exp" in
      *"$shell_exp"*) ;;
      *)
        echo "FINDING: expectation gran=$gran yolo=$yolo: shell='$shell_exp' not found in rust='$rust_exp'" >&2
        FINDINGS=$((FINDINGS + 1))
        ;;
    esac
  done
done

echo "test-rust-shell-differential: $SCANNED scanned, $SKIPPED skipped, $CHECKED checked, $FINDINGS findings"
[ "$SCANNED" -eq $((SKIPPED + CHECKED)) ] || { echo "coverage accounting defect" >&2; exit 3; }
[ "$FINDINGS" -eq 0 ] || exit 1
exit 0
```

- [ ] **Step 2: Make it executable and syntax-check**

```bash
chmod +x tests/test-rust-shell-differential.sh
bash -n tests/test-rust-shell-differential.sh && echo "syntax ok"
```

Expected: `syntax ok`

- [ ] **Step 3: Build release and run the harness**

```bash
cargo build --release
tests/test-rust-shell-differential.sh
```

Expected: `test-rust-shell-differential: 177 scanned, 0 skipped, 177 checked, 0 findings` and exit 0.
(1 vocabulary check + 100 transition pairs + 10 successor lists + 60 dependency combinations + 6 expectation strings.)
If findings appear, **the Rust side is wrong** — the shell is the source of truth for this step. Fix `nazgul-core` and re-run.

- [ ] **Step 4: Verify the harness can actually fail**

Temporarily break one edge in `crates/nazgul-core/src/transition.rs` (delete `| (Approved, Done)`), rebuild, and run:

```bash
cargo build --release && tests/test-rust-shell-differential.sh; echo "exit=$?"
```

Expected: at least 2 findings (the transition pair and `allowed_next(APPROVED)`), exit 1.
**Restore the edge and rebuild before continuing.** A test that has never been red is not evidence.

- [ ] **Step 5: Confirm restored and green**

```bash
cargo build --release && tests/test-rust-shell-differential.sh
```

Expected: 0 findings, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/test-rust-shell-differential.sh
git commit -m "test(rust): differential harness proving the port matches the shell across the whole input space"
```

---

## Part C — Spikes

These gate **Step 4 and later**, not Step 1. Part B can complete without them. Each produces a written answer appended to the spec's §12 table, not code.

### Task 9: Spike — do tool-restricted agents receive MCP tools?

**Files:**
- Modify: `docs/superpowers/specs/2026-08-27-rust-core-refounding-design.md` §12 (record the answer)

**Context:** Verified so far only for `general-purpose` subagents. `agents/templates/reviewer-base.md:4-13` declares `tools: Read, Glob, Grep`, and `RULES.md:102` records that this is what makes "reviewers are read-only" tool-enforced. If a restricted spec still receives `mcp__*`, that guarantee has a hole; if it does not, reviewers cannot use the MCP seam and need the CLI.

- [ ] **Step 1: Reuse the probe server from the design session**

```bash
ls /private/tmp/claude-501/*/*/scratchpad/probe-mcp-server.js 2>/dev/null || echo "regenerate: a 60-line stdio JSON-RPC server answering initialize, tools/list, tools/call"
```

- [ ] **Step 2: Write a restricted agent definition mirroring reviewer-base**

```bash
mkdir -p /tmp/mcp-spike/.claude/agents
cat > /tmp/mcp-spike/.claude/agents/restricted-probe.md <<'EOF'
---
name: restricted-probe
description: Spike agent with reviewer-base's exact tool restriction.
tools: Read, Glob, Grep
---
List every tool name available to you that begins with mcp__. Then try to call
mcp__nazgulprobe__nazgul_probe_ping with note set to RESTRICTED. Report the exact
tool names you saw and whether the call succeeded or why it failed.
EOF
```

- [ ] **Step 3: Run the probe with the restricted agent**

```bash
cd /tmp/mcp-spike
claude -p --strict-mcp-config --mcp-config <path-to-probe-mcp-config.json> \
  --permission-mode bypassPermissions \
  "Dispatch the restricted-probe agent via the Agent tool with run_in_background:false, then report its output verbatim."
```

- [ ] **Step 4: Record the answer in the spec**

Replace spike row 1 in §12 with the observed result and the date. If restricted agents do **not** receive `mcp__*`, add a line to §8 stating that reviewers use the CLI seam, not MCP.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-27-rust-core-refounding-design.md
git commit -m "docs(spec): record spike 1 — MCP tool visibility under a restricted agent spec"
```

---

### Task 10: Spike — filesystem safety for the store

**Files:**
- Modify: `docs/superpowers/specs/2026-08-27-rust-core-refounding-design.md` §12

**Context:** The repository lives under `~/Documents/…`, a path class commonly iCloud-synced, where SQLite WAL is documented-unsafe. This decides whether the store can use WAL, and whether `nazgul` must refuse to open a database on a synced or network filesystem.

- [ ] **Step 1: Determine the filesystem and sync status**

```bash
df -T . 2>/dev/null || df . 
mount | grep -i "$(df . | tail -1 | awk '{print $1}')"
ls -la ~/Library/Mobile\ Documents/ 2>/dev/null | head -3 || echo "no iCloud Mobile Documents"
xattr -l . 2>/dev/null | head
```

- [ ] **Step 2: Check whether the repo path is inside a synced tree**

```bash
brctl status 2>/dev/null | head -20 || echo "brctl unavailable — not iCloud-managed, or restricted"
```

- [ ] **Step 3: Record the answer and the resulting rule**

Update §12 spike row 3 with the observed filesystem. Add to §10 the concrete rule chosen: WAL plus `busy_timeout`, and whether `nazgul` refuses network/synced filesystems outright or warns. Add `state.db-wal` and `state.db-shm` to the ignore-block requirement in §12 row 4.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-27-rust-core-refounding-design.md
git commit -m "docs(spec): record spike 3 — filesystem class and the resulting WAL rule"
```

---

### Task 11: Spike — real binary size with a fully wired MCP server

**Files:**
- Modify: `docs/superpowers/specs/2026-08-27-rust-core-refounding-design.md` §11 and §12

**Context:** The 1.4 MB figure is a **lower bound** — the probe touched only `rmcp::model::ServerInfo`, so LTO may have stripped most of the SDK. Four committed binaries make the true number a distribution decision. This is now runnable because Task 1 installed toolchain 1.88, which `rmcp` 3.1.4 requires.

- [ ] **Step 1: Add a throwaway server binary with the real dependency set**

Create `crates/nazgul-cli/src/bin/size-probe.rs` with a working `rmcp` stdio server exposing three typed tools via `#[tool_router(server_handler)]`, following the pattern documented at `rmcp-3.1.4/src/handler/server/router/tool.rs:6-34`. Add to `crates/nazgul-cli/Cargo.toml`:

```toml
rmcp = { version = "3.1", features = ["server", "transport-io", "macros", "schemars"] }
tokio = { version = "1", features = ["rt", "macros", "io-std", "sync", "time"] }
rusqlite = { version = "0.32", features = ["bundled"] }
```

- [ ] **Step 2: Build and measure**

```bash
cargo build --release
ls -lh target/release/size-probe | awk '{print $5}'
otool -L target/release/size-probe 2>/dev/null | tail -n +2 || ldd target/release/size-probe
```

- [ ] **Step 3: Record and decide**

Update §11's size row with the measured figure. If four binaries exceed ~40 MB total, record the mitigation chosen (feature-gate the HTTP transport off, or fetch binaries at install rather than committing them).

- [ ] **Step 4: Remove the throwaway probe**

```bash
git rm -f crates/nazgul-cli/src/bin/size-probe.rs
# revert the three dependency lines added in Step 1
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(spec): record spike 5 — measured binary size with the full MCP dependency set"
```

---

## Self-Review

**Spec coverage.** §3 architecture → Task 1. §11 toolchain gap → Task 1 Step 1. §9 testing item 7 (CI proves artifacts exist) → Task 2. §7 step 1 "status vocabulary + transition validator" → Tasks 3-7. §9 testing item 2 (differential testing) → Task 8. §12 spikes 1, 3, 5 → Tasks 9-11.

**Deliberately out of scope, with reasons:** §12 spike 2 (plugin `.mcp.json` propagation) and spike 4 (shared-mode store scope) gate Step 4 and are cheaper to answer once the store exists. §7's precondition — extending `tests/test-manifest-write-integrity.sh`'s scans to `agents/**` and `skills/**` — is a change to a shipped §15-enrolled entry point and belongs in its own plan, since it must not silently narrow an existing guarantee. §7's "split before delete" of `pre-tool-guard.sh` belongs to Step 2. **These four gaps are named rather than left to be discovered.**

**Placeholder scan.** Four defects were found in the first draft of this plan and fixed rather than shipped: the edge count was stated as 24 and is **27** (verified by running the Task 3 Step 2 command against the source — 19 ordinary edges plus 8 into `CANCELLED`); a `allowed_next` test was written as an unreadable `fold` chain and replaced; the same test then appeared twice; and the differential harness's expected coverage line said 175 where the arithmetic gives **177**. Task 3 Step 2 still re-derives the count from source at execution time, because a number in prose is not evidence.

**Type consistency.** `Status`, `Granularity`, `FieldValue` are defined in Tasks 3, 5, 6 and used with those exact names in Task 7. `dependency_satisfied(dep, granularity, yolo)` keeps one signature throughout. `allowed_next` returns `Vec<Status>` in Task 4 and is consumed as such. The CLI's three exit codes are stated once in Task 7 and asserted in Task 8.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-08-27-rust-core-step0-step1.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — tasks executed in this session using executing-plans, batch execution with checkpoints

**Which approach?**
