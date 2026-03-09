# Greenfield Stack Scaffolding

For greenfield projects, Hydra checks for a project spec, asks about the desired stack, and verifies/installs all required tools before proceeding.

## Step 0: Project Spec Detection

Before stack selection, check for a project specification:

1. **If `hydra/context/project-spec.md` already exists:** Skip this step (idempotent).
2. **Otherwise**, look for spec files in the project root (first match wins):
   - `project-spec.md`
   - `SPEC.md`
   - `spec.md`
   - `PROJECT.md`
   - `PRD.md`
3. **If a spec file is found:**
   - Read the file contents
   - If the file is structured (has clear headings for vision, features, users, etc.): parse and normalize into the standard `project-spec.md` format
   - If the file is unstructured (plain text brief, Notion export, freeform notes): place the full content in `## Raw Spec` and attempt best-effort extraction into structured sections (Vision, Target Users, Core Features, Problem Statement, Constraints)
   - If the file exceeds 500 lines: truncate `## Raw Spec` to 200 lines with note `[Truncated — original at: [filename]]`
   - Set `## Source` → Method: `imported`, Imported from: `[filename]`
   - Write to `hydra/context/project-spec.md`
   - Update `hydra/config.json` → set `project_spec` to `"imported"`
   - Tell user: `"Found project spec at [filename]. Using it for planning."`
4. **If no spec file found + HITL mode:**
   - Tell user: `"No project spec found. You can create one with /hydra:gen-spec, or we'll proceed with just the tech stack."`
   - Continue to Step 1.
5. **If no spec file found + AFK mode:** Skip silently, proceed to Step 1.

## Step 1: Stack Selection

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
  1. TypeScript    5. Java
  2. Python        6. Ruby
  3. Go            7. C# / .NET
  4. Rust

Package manager?
  (Suggest based on language: pnpm for TS, uv for Python, cargo for Rust, dotnet CLI for C#, etc.)

Database?
  1. PostgreSQL    4. None
  2. SQLite        5. Other
  3. MongoDB

Auth?
  1. JWT           3. OAuth/OIDC
  2. Session-based 4. None / Later

Testing?
  (Suggest based on language: Vitest for TS, Pytest for Python, go test for Go, xUnit/NUnit for C#, etc.)

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

Present smart defaults based on prior answers (e.g., if TypeScript + Web -> suggest Next.js + pnpm + Vitest + Tailwind).

**AFK mode** — Use the most popular/stable defaults for the detected project type:
- Web: TypeScript + Next.js + pnpm + Vitest + Tailwind + PostgreSQL + Vercel (PaaS)
- API: TypeScript + Express + pnpm + Vitest + PostgreSQL + Docker + AWS + Terraform + GitHub Actions
- CLI: TypeScript + Node + pnpm + Vitest + GitHub Actions
- Python API: Python + FastAPI + uv + Pytest + PostgreSQL + Docker + AWS + Terraform + GitHub Actions
- .NET API: C# + ASP.NET Core (Minimal APIs) + dotnet CLI + xUnit + PostgreSQL + Docker + Azure + Terraform + GitHub Actions
- Infrastructure defaults: Terraform (always), GitHub Actions, structured logging + Sentry, dev + staging + prod

## Step 2: Tool Pre-flight Check

After stack selection, map the chosen stack to required CLI tools and check each. See `references/tool-preflight.md` for the full tool detection commands table.

**For each required tool:**
1. Run the check command
2. If installed: log `[tool] [version]`
3. If missing:
   - **HITL mode**: Ask `"[tool] is not installed. Install it? (Y/n)"`
   - **AFK/YOLO mode**: Auto-install using the appropriate command
   - Detect platform: check for `brew` (macOS), `apt` (Debian/Ubuntu), `dnf` (Fedora), fall back to language-specific installers
4. After install: verify with the check command again
5. If install fails: mark as BLOCKED and continue with other tools

**Output format:**
```
Checking prerequisites for Next.js + PostgreSQL stack...
  node v22.1.0        installed
  pnpm v9.1.0         installed
  postgresql@16       not found
    -> Installing via brew install postgresql@16...
    -> Starting service: brew services start postgresql@16
    -> postgresql@16    installed
  jq 1.7.1            installed

All tools ready.
```

## Step 3: Tool Configuration

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

## Step 4: Store Stack & Generate Objective

Write verified stack to `config.json -> project.stack`:
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

Set the objective based on whether a project spec exists:

**If `hydra/context/project-spec.md` exists** (vision is available):
```
"Build [vision summary]: [framework] with [database], [auth], [testing], and [cloud_provider] infrastructure via Terraform — all tools verified and configured"
```
Where `[vision summary]` is a concise version of the `## Vision` section from project-spec.md.

**If no project spec** (current behavior):
```
"Scaffold [framework] project with [database], [auth], [testing], and [cloud_provider] infrastructure via Terraform — all tools verified and configured"
```

Store in config.json and proceed to Doc Generator -> Planner -> Implementer.
