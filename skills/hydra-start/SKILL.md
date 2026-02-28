---
name: hydra-start
description: Start or resume a Hydra autonomous development loop. Auto-detects project state — no arguments needed. Optionally pass an objective to start new work.
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task
---

# Hydra Start

## Arguments
$ARGUMENTS

## Current Project State
- Config: !`cat hydra/config.json 2>/dev/null || echo "NOT_INITIALIZED"`
- Stored objective: !`jq -r '.objective // "none"' hydra/config.json 2>/dev/null || echo "none"`
- Discovery: !`cat hydra/context/discovery-summary.md 2>/dev/null || echo "NOT_RUN"`
- Classification: !`cat hydra/context/project-classification.md 2>/dev/null | head -5 || echo "NOT_CLASSIFIED"`
- Docs generated: !`ls hydra/docs/*.md 2>/dev/null | wc -l | tr -d ' '`
- Active tasks: !`grep -rl 'Status.*\(READY\|IN_PROGRESS\|IN_REVIEW\|IMPLEMENTED\|CHANGES_REQUESTED\)' hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Done tasks: !`grep -rl 'Status.*DONE' hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Total tasks: !`ls hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Active reviewers: !`ls .claude/agents/generated/ 2>/dev/null || echo "No reviewers generated"`
- Current plan: !`head -20 hydra/plan.md 2>/dev/null || echo "No plan yet"`
- Recovery Pointer: !`sed -n '/^## Recovery Pointer/,/^## /p' hydra/plan.md 2>/dev/null | head -7 || echo "none"`
- TODOs in codebase: !`grep -rn 'TODO\|FIXME\|HACK\|XXX' --include='*.ts' --include='*.js' --include='*.py' --include='*.rb' --include='*.go' --include='*.rs' --include='*.java' --include='*.md' . 2>/dev/null | head -10 || echo "none"`
- Test context: !`cat hydra/context/test-strategy.md 2>/dev/null | head -5 || echo "none"`

## Instructions

### Parse Arguments
- `$ARGUMENTS` may contain:
  - An objective string (optional — override for new work)
  - Flags: `--afk`, `--hitl`, `--max N`, `--yolo`, `--continue`
  - Or nothing at all (smart mode — this is the default)

### YOLO Mode Pre-flight (--yolo)
If `--yolo` flag is present:
1. Set `afk.enabled: true` and `afk.yolo: true` in config.json
2. Check if the current session was launched with `--dangerously-skip-permissions`:
   - Try running a quick Bash command — if no permission prompt fires, we're good
   - If permissions ARE being prompted, **STOP** and tell the user:
     ```
     YOLO mode requires --dangerously-skip-permissions. Restart with:
     claude --dangerously-skip-permissions
     Then re-run: /hydra-start --yolo --max N
     ```
3. Once confirmed, proceed with full autonomous mode — no pauses, no permission prompts, no human gates

### Smart State Detection

Evaluate the preprocessor data above. Work through this state machine top-to-bottom — take the FIRST state that matches:

---

#### STATE: NOT_INITIALIZED
**Detection:** Config shows "NOT_INITIALIZED"
**Action:** Tell the user: "Hydra not initialized. Run `/hydra-init` first."
**Stop here.**

---

#### STATE: ACTIVE_LOOP
**Detection:** Active tasks > 0 (any task with status READY, IN_PROGRESS, IN_REVIEW, IMPLEMENTED, or CHANGES_REQUESTED)
**Action:** Auto-resume the loop.
1. Tell the user: "Resuming: [stored objective]. [N] active tasks remaining."
2. Read `hydra/plan.md` → Recovery Pointer
3. Read the latest checkpoint in `hydra/checkpoints/`
4. Read the active task manifest
5. Update config.json: set mode from flags (afk/hitl), reset `current_iteration` to 0. If `current_iteration >= max_iterations`, ALSO reset `current_iteration` to 0 and bump `max_iterations` by its original value (e.g., 40 → 80) to allow the continued run to have a full iteration budget.
6. Delegate to the appropriate agent based on active task status:
   - READY/IN_PROGRESS → Implementer
   - IMPLEMENTED/IN_REVIEW → Review Gate
   - CHANGES_REQUESTED → Implementer (read consolidated feedback first)
   - BLOCKED → Show to user, ask what to do
7. The stop hook takes over from here.

---

#### STATE: OBJECTIVE_COMPLETE
**Detection:** Total tasks > 0 AND active tasks == 0 AND done tasks == total tasks
**Action:** All tasks are done.
1. Check if post-loop agents have already run (look for release notes, updated CHANGELOG, etc.)
2. If post-loop NOT run yet:
   - Tell user: "All [N] tasks complete. Running post-loop agents (documentation, release, observability)..."
   - Delegate to post-loop agents (documentation → release-manager → observability)
   - After post-loop: output HYDRA_COMPLETE
3. If post-loop already run:
   - Tell user: "Previous objective complete: [stored objective]. Starting objective derivation for next work..."
   - Fall through to FRESH state below to derive a new objective

---

#### STATE: DOCS_READY
**Detection:** Docs generated > 0 AND total tasks == 0
**Action:** Documents exist but no plan yet — run the planner.
1. Read stored objective from config.json
2. If objective exists: tell user "Docs ready. Running planner on existing documents..."
3. If no objective: read the PRD overview section as the objective, store it in config.json
4. Delegate to Planner agent
5. Review Plan (HITL mode: show plan for approval. AFK: continue.)
6. Delegate to Implementer
7. Stop hook takes over.

---

#### STATE: DISCOVERY_DONE
**Detection:** Discovery summary is NOT "NOT_RUN" AND docs generated == 0 AND total tasks == 0
**Action:** Discovery ran but no docs or plan yet.
1. Check if objective exists in config.json
2. If no objective: run **Objective Derivation** (see below)
3. Tell user: "Discovery complete. Generating documents, then planning..."
4. Delegate to Doc Generator agent. In HITL mode, pause for doc review.
5. Delegate to Planner agent. In HITL mode, pause for plan review.
6. Delegate to Implementer
7. Stop hook takes over.

---

#### STATE: FRESH
**Detection:** None of the above matched (config exists but discovery hasn't run)
**Action:** Fresh project — need discovery + everything.
1. Run **Objective Derivation** (see below) if no objective in config.json
2. Run Discovery agent (scans codebase, classifies project, generates reviewers)
3. Classify Project: In HITL mode, confirm classification with user.
4. Generate Documents: Delegate to Doc Generator. In HITL mode, pause for doc review.
5. Collect Context: Based on objective type, collect targeted context.
6. Delegate to Planner: Planner reads context + docs, decomposes into tasks.
7. Review Plan (HITL): Show plan for approval. AFK: continue.
8. Delegate to Implementer: Start working on the first READY task.
9. Stop hook takes over.

---

### Objective Derivation

When no objective exists in config.json and none was provided as an argument, Hydra derives one from project signals. The approach depends on whether this is a greenfield project.

#### Check: Is this a Greenfield Project?
If classification is `GREENFIELD` (from `hydra/context/project-classification.md`) OR the codebase has fewer than 10 source files:
→ Go to **Greenfield Stack Scaffolding** (below)

Otherwise → continue with signal scanning:

#### Step 1: Scan for signals (use the preprocessor data above + additional reads)
Gather signals in priority order:
1. **Project profile** — read `hydra/context/project-profile.md` for stated goals, purpose
2. **TODO/FIXME/HACK comments** — from the preprocessor TODOs data
3. **Failing tests** — run the project's test command (from config.json `project.test_command`) and capture failures
4. **README roadmap** — read the project's README.md for "roadmap", "planned features", "next steps" sections
5. **Recent git activity** — `git log --oneline -10` for patterns like "WIP:", "started:", incomplete work
6. **Open GitHub issues** — `gh issue list --limit 5 --state open` (if `gh` is available)

#### Step 2: Present or select
**HITL mode** — Present discovered signals as an interactive menu:
```
Hydra scanned your project and found potential work:

1. [signal description] (source: TODOs in src/payments/)
2. [signal description] (source: 2 failing tests in auth.test.ts)
3. [signal description] (source: GitHub issue #12)
4. Something else — tell me what you want to build

Which objective should I pursue?
```
Wait for user selection. If user picks "something else", use their input.

**AFK mode** — Auto-select the highest-priority signal:
- Priority: failing tests > TODOs with urgency keywords (FIXME, HACK) > open issues > WIP commits > general TODOs
- If zero signals found: error — "No objective could be derived from project context. Run `/hydra-start 'your objective'` to specify one."

#### Step 3: Store
Write the derived/selected objective to config.json:
```json
{
  "objective": "[the derived objective]",
  "objective_set_at": "[ISO 8601 timestamp]"
}
```
Append to `objectives_history` array.

---

### Greenfield Stack Scaffolding

For greenfield projects, Hydra asks about the desired stack and verifies/installs all required tools before proceeding.

#### Step 1: Stack Selection

**HITL mode** — Ask the user interactively:

```
This is a new project. Let's set up your stack.

What kind of project?
  1. Web app (React, Next.js, Vue, SvelteKit...)
  2. API / Backend (Express, FastAPI, Rails, Go, Rust...)
  3. CLI tool (Node, Python, Rust, Go...)
  4. Mobile app (React Native, Flutter, Swift, Kotlin...)
  5. Full-stack (frontend + backend + database)
  6. Library / Package
  7. Something else

Language?
  1. TypeScript    4. Rust
  2. Python        5. Java
  3. Go            6. Ruby

Package manager?
  (Suggest based on language: pnpm for TS, uv for Python, cargo for Rust, etc.)

Database?
  1. PostgreSQL    4. None
  2. SQLite        5. Other
  3. MongoDB

Auth?
  1. JWT           3. OAuth/OIDC
  2. Session-based 4. None / Later

Testing?
  (Suggest based on language: Vitest for TS, Pytest for Python, go test for Go, etc.)

Styling? (if frontend)
  1. Tailwind CSS  3. CSS Modules
  2. shadcn/ui     4. None / Other

Hosting model?
  1. PaaS (Vercel, Railway, Fly.io — managed, no infra to maintain)
  2. Containers (Docker + orchestration — full control)
  3. Serverless (Lambda, Cloud Functions, Cloud Run)
  4. VMs (EC2, Compute Engine, Droplets — traditional)

Cloud provider? (skip if PaaS only)
  1. AWS            4. DigitalOcean
  2. GCP            5. Self-hosted / On-prem
  3. Azure          6. None / Later

Container orchestration? (if Containers selected)
  1. Docker Compose (dev + small prod)
  2. Kubernetes (EKS/GKE/AKS — production scale)
  3. ECS / Cloud Run (cloud-managed containers)

CI/CD platform?
  1. GitHub Actions (Recommended)
  2. GitLab CI
  3. CircleCI
  4. None / Later

Observability?
  1. Datadog (full-stack monitoring)
  2. Prometheus + Grafana (self-hosted)
  3. Cloud-native (CloudWatch / Cloud Monitoring / Azure Monitor)
  4. Basic (structured logging + Sentry for errors)
  5. None / Later

Secret management?
  1. Cloud secret manager (AWS Secrets Manager / GCP Secret Manager / Azure Key Vault)
  2. HashiCorp Vault
  3. Doppler
  4. .env files only (dev/small projects)

Environments?
  1. dev + prod (simple)
  2. dev + staging + prod (standard)
  3. dev + staging + prod + preview per PR (full)
```

Present smart defaults based on prior answers (e.g., if TypeScript + Web → suggest Next.js + pnpm + Vitest + Tailwind).

**AFK mode** — Use the most popular/stable defaults for the detected project type:
- Web: TypeScript + Next.js + pnpm + Vitest + Tailwind + PostgreSQL + Vercel (PaaS)
- API: TypeScript + Express + pnpm + Vitest + PostgreSQL + Docker + AWS + Terraform + GitHub Actions
- CLI: TypeScript + Node + pnpm + Vitest + GitHub Actions
- Python API: Python + FastAPI + uv + Pytest + PostgreSQL + Docker + AWS + Terraform + GitHub Actions
- Infrastructure defaults: Terraform (always), GitHub Actions, structured logging + Sentry, dev + staging + prod

#### Step 2: Tool Pre-flight Check

After stack selection, map the chosen stack to required CLI tools and check each:

```
Checking prerequisites...
```

**Tool detection commands:**

| Tool | Check Command | Install (macOS) | Install (Linux) |
|------|--------------|-----------------|-----------------|
| node | `node --version` | `brew install node` | `curl -fsSL https://deb.nodesource.com/setup_22.x \| sudo bash - && sudo apt install -y nodejs` |
| pnpm | `pnpm --version` | `npm install -g pnpm` | `npm install -g pnpm` |
| npm | `npm --version` | (comes with node) | (comes with node) |
| bun | `bun --version` | `brew install oven-sh/bun/bun` | `curl -fsSL https://bun.sh/install \| bash` |
| yarn | `yarn --version` | `npm install -g yarn` | `npm install -g yarn` |
| python3 | `python3 --version` | `brew install python` | `sudo apt install -y python3` |
| uv | `uv --version` | `brew install uv` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| pip | `pip3 --version` | (comes with python) | (comes with python) |
| go | `go version` | `brew install go` | `sudo apt install -y golang` |
| rust/cargo | `cargo --version` | `brew install rust` | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| ruby | `ruby --version` | `brew install ruby` | `sudo apt install -y ruby` |
| docker | `docker --version` | `brew install --cask docker` | `sudo apt install -y docker.io` |
| postgresql | `pg_isready` or `psql --version` | `brew install postgresql@16 && brew services start postgresql@16` | `sudo apt install -y postgresql` |
| sqlite3 | `sqlite3 --version` | `brew install sqlite` | `sudo apt install -y sqlite3` |
| gh | `gh --version` | `brew install gh` | `sudo apt install -y gh` |
| jq | `jq --version` | `brew install jq` | `sudo apt install -y jq` |
| terraform | `terraform --version` | `brew install terraform` | `sudo apt install -y terraform` |
| kubectl | `kubectl version --client` | `brew install kubectl` | `sudo apt install -y kubectl` |
| helm | `helm version` | `brew install helm` | `sudo apt install -y helm` |
| aws-cli | `aws --version` | `brew install awscli` | `sudo apt install -y awscli` |
| gcloud | `gcloud --version` | `brew install --cask google-cloud-sdk` | `curl https://sdk.cloud.google.com \| bash` |
| az | `az --version` | `brew install azure-cli` | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |

**For each required tool:**
1. Run the check command
2. If installed: log `✓ [tool] [version]`
3. If missing:
   - **HITL mode**: Ask `"[tool] is not installed. Install it? (Y/n)"`
   - **AFK/YOLO mode**: Auto-install using the appropriate command
   - Detect platform: check for `brew` (macOS), `apt` (Debian/Ubuntu), `dnf` (Fedora), fall back to language-specific installers
4. After install: verify with the check command again
5. If install fails: mark as BLOCKED and continue with other tools

**Output format:**
```
Checking prerequisites for Next.js + PostgreSQL stack...
  node v22.1.0        ✓ installed
  pnpm v9.1.0         ✓ installed
  postgresql@16       ✗ not found
    → Installing via brew install postgresql@16...
    → Starting service: brew services start postgresql@16
    → postgresql@16    ✓ installed
  jq 1.7.1            ✓ installed

All tools ready.
```

#### Step 3: Tool Configuration

After all tools are verified, run initial configuration:

1. **Project initialization** — run the framework's init command:
   - `pnpm create next-app . --typescript --tailwind --eslint --app --src-dir`
   - `uv init && uv add fastapi uvicorn`
   - `cargo init`
   - etc.
2. **Database setup** (if selected):
   - Create database: `createdb [project-name]`
   - Generate `.env.example` with `DATABASE_URL=postgresql://localhost/[project-name]`
   - Copy to `.env` if it doesn't exist
3. **Tool config files**:
   - `.nvmrc` or `.tool-versions` (pin runtime version)
   - `.gitignore` (language-appropriate, include node_modules/, .env, etc.)
   - Linter config (`.eslintrc`, `ruff.toml`, etc.)
   - Formatter config (`.prettierrc`, etc.)
4. **Verify everything works**:
   - Run build: `pnpm build` / `cargo build` / `uv run python -c "import fastapi"`
   - Run tests: `pnpm test` / `pytest` / `cargo test`
   - Run lint: `pnpm lint` / `ruff check .` / `cargo clippy`
5. **Infrastructure scaffolding** (if cloud provider selected):
   - Initialize Terraform: `terraform -chdir=infra init` (after creating structure)
   - Create Terraform directory structure:
     ```
     infra/
     ├── main.tf              # Provider config, backend
     ├── variables.tf         # Input variables
     ├── outputs.tf           # Output values
     ├── versions.tf          # Required providers + versions
     ├── environments/
     │   ├── dev.tfvars
     │   ├── staging.tfvars
     │   └── prod.tfvars
     └── modules/             # Reusable modules (populated as needed)
     ```
   - Configure Terraform backend for selected cloud:
     - AWS: S3 + DynamoDB for state locking
     - GCP: GCS bucket for state
     - Azure: Azure Storage for state
   - Generate `.env.example` with cloud-specific variables
   - Create initial CI/CD pipeline config for selected platform
   - Generate `docker-compose.yml` for local development (if containers selected)
   - Set up `.github/workflows/terraform.yml` (if GitHub Actions selected) for plan-on-PR, apply-on-merge

#### Step 4: Store Stack & Generate Objective

Write verified stack to `config.json → project.stack`:
```json
{
  "project": {
    "stack": {
      "runtime": "node 22.1.0",
      "package_manager": "pnpm 9.1.0",
      "framework": "next.js 15",
      "database": "postgresql 16",
      "orm": "prisma",
      "testing": "vitest",
      "styling": "tailwind",
      "auth": "jwt",
      "additional": ["eslint", "prettier"]
    },
    "infrastructure": {
      "hosting_model": "containers",
      "cloud_provider": "aws",
      "cloud_region": "us-east-1",
      "iac_tool": "terraform",
      "container_orchestration": "ecs",
      "cicd_platform": "github-actions",
      "observability": "datadog",
      "secret_management": "aws-secrets-manager",
      "environments": ["dev", "staging", "prod"]
    },
    "tools_verified": true,
    "tools_installed": ["postgresql@16", "terraform"]
  }
}
```

Set the objective to:
```
"Scaffold [framework] project with [database], [auth], [testing], and [cloud_provider] infrastructure via Terraform — all tools verified and configured"
```

Store in config.json and proceed to Doc Generator → Planner → Implementer.

---

### New Objective Override (argument provided)

When the user explicitly passes an objective string in `$ARGUMENTS`:

1. **Check for existing active work:**
   - If active tasks exist, warn in HITL mode:
     ```
     You have an active objective: "[stored objective]" with [N] tasks remaining.
     Options:
     a. Archive it and start the new objective
     b. Cancel and resume current work (/hydra-start)
     ```
   - In AFK mode with active tasks: auto-archive and start new
   - If no active tasks: proceed directly
2. **Archive old work** (if applicable):
   - Create `hydra/archive/[YYYY-MM-DD-HHMMSS]/` directory
   - Move: plan.md, tasks/, reviews/, docs/, checkpoints/ into archive
   - Keep: config.json (will be updated), context/ (still valid for same project)
   - Update `objectives_history` in config.json with `completed_at` and `plan_archived_to`
3. **Store new objective** in config.json: set `objective`, `objective_set_at`, append to `objectives_history`
4. **Proceed with FRESH state pipeline** (discovery if stale → docs → plan → implement)

---

### `--continue` Flag (backward compatibility)

If `--continue` is present, behave exactly as ACTIVE_LOOP state. Also reset `current_iteration` to 0 if it has reached `max_iterations`.
If no active tasks found: "Nothing to continue. Run `/hydra-start` to auto-detect what to do."

---

### AFK Mode Notes
- Set `afk.enabled: true` in config
- Auto-commit on every state transition with `hydra:` prefix
- Security rejections → BLOCKED (requires human review later)
- No pauses for human review

### YOLO Mode Notes
- Everything in AFK mode, PLUS:
- Zero permission prompts — all tool calls execute immediately
- The agent goes full berserk: reads, writes, edits, runs tests, commits — no interruptions
- Requires launching Claude Code with `--dangerously-skip-permissions`
- Recommended for overnight/unattended runs on trusted codebases
- Security guard (pre-tool-guard.sh) still blocks genuinely destructive commands (rm -rf /, DROP TABLE, etc.)
