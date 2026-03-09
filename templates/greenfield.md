# Greenfield Objective

## Objective
<!-- Derived from stack scaffolding conversation or user input. -->

## Project Vision
- **What it does**: <!-- From project-spec.md -->
- **Who it's for**: <!-- From project-spec.md -->
- **Core features**: <!-- From project-spec.md -->
- **Problem it solves**: <!-- From project-spec.md -->
- **Constraints**: <!-- From project-spec.md -->

## Project Type
<!-- Web app, CLI tool, API service, library, mobile app, full-stack, etc. -->

## Requirements
- [ ] <!-- Core requirement -->
- [ ] <!-- Core requirement -->
- [ ] <!-- Core requirement -->

## Acceptance Criteria
- [ ] <!-- "The system can X" -->
- [ ] <!-- "The system can Y" -->
- [ ] Project builds and runs successfully
- [ ] Test suite passes with meaningful coverage
- [ ] Documentation covers setup and basic usage

## Stack Selection

<!-- Filled by the stack scaffolding conversation in /hydra:start -->

### Runtime & Language
- Language: <!-- TypeScript, Python, Go, Rust, Java, Ruby, etc. -->
- Runtime: <!-- Node.js 22, Python 3.12, Go 1.22, etc. -->
- Package manager: <!-- pnpm, npm, bun, yarn, pip/uv, cargo, etc. -->

### Framework & Libraries
- Framework: <!-- Next.js, FastAPI, Express, Rails, Gin, Actix, etc. -->
- ORM/Database client: <!-- Prisma, Drizzle, SQLAlchemy, GORM, etc. -->
- Testing: <!-- Vitest, Jest, Pytest, Go test, etc. -->
- Linting: <!-- ESLint, Ruff, golangci-lint, Clippy, etc. -->

### Infrastructure
- Database: <!-- PostgreSQL, SQLite, MongoDB, none, etc. -->
- Auth: <!-- JWT, OAuth, session-based, Clerk, Auth.js, none, etc. -->
- Styling: <!-- Tailwind, CSS Modules, styled-components, none, etc. -->

### Cloud & Deployment
- Hosting model: <!-- PaaS (Vercel/Railway), Containers (Docker+K8s), Serverless, VMs -->
- Cloud provider: <!-- AWS, GCP, Azure, DigitalOcean, self-hosted, none -->
- Cloud region: <!-- us-east-1, us-central1, etc. -->
- IaC tool: Terraform <!-- Always Terraform for cloud-agnostic portability -->
- Container orchestration: <!-- Docker Compose, Kubernetes (EKS/GKE/AKS), ECS/Cloud Run, none -->

### CI/CD
- Platform: <!-- GitHub Actions, GitLab CI, CircleCI, none -->
- Pipeline stages: <!-- lint, test, security scan, build, deploy-staging, deploy-prod -->

### Observability
- Logging: <!-- Structured JSON via [library] → [destination: CloudWatch/Datadog/Loki] -->
- Monitoring: <!-- Datadog, Prometheus+Grafana, cloud-native, none -->
- Error tracking: <!-- Sentry, Bugsnag, none -->
- Tracing: <!-- OpenTelemetry, Jaeger, none -->

### Secret Management
- Approach: <!-- Cloud secret manager, HashiCorp Vault, Doppler, .env files only -->
- Provider: <!-- AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, none -->

### Environment Strategy
- Environments: <!-- dev, staging, prod -->
- Terraform state: <!-- S3+DynamoDB, GCS, Azure Storage -->
- Environment separation: <!-- Terraform workspaces, directory-per-env -->

## Tool Verification

<!-- Filled by the tool pre-flight check in /hydra:start -->

### Required Tools
| Tool | Required Version | Status | Install Command |
|------|-----------------|--------|-----------------|
| <!-- node --> | <!-- >= 20 --> | <!-- ✓ installed / ✗ missing --> | <!-- brew install node --> |
| <!-- pnpm --> | <!-- latest --> | <!-- ✓ / ✗ --> | <!-- npm install -g pnpm --> |

### Configuration Steps
- [ ] <!-- Initialize project: pnpm init / npm init -->
- [ ] <!-- Install dependencies -->
- [ ] <!-- Set up database -->
- [ ] <!-- Configure environment variables (.env.example) -->
- [ ] <!-- Set up linting + formatting -->
- [ ] <!-- Set up test runner -->
- [ ] <!-- Create .gitignore -->

## Architecture Decisions
<!-- Key decisions to make before building -->
- Project structure: <!-- monorepo, single package, etc. -->
- API style: <!-- REST, GraphQL, gRPC -->
- Directory structure: <!-- feature-based, layer-based -->
- Error handling: <!-- pattern to use -->
- IaC approach: Terraform (cloud-agnostic default)
- Environment strategy: <!-- workspaces vs directory-per-env -->
- Deployment strategy: <!-- blue-green, canary, rolling -->

## Pattern Reference
<!-- Conventions to establish from the start -->
- File naming: <!-- kebab-case, camelCase, etc. -->
- Import style: <!-- absolute paths, barrel exports, etc. -->
- Component pattern: <!-- if frontend: functional, server components, etc. -->
- State management: <!-- if frontend: context, zustand, redux, etc. -->

## Context Collection Notes
The Planner should:
1. Use the verified stack from Tool Verification
2. Create scaffold structure matching the chosen framework's conventions
3. Set up linting, formatting, and testing from the start
4. Generate .env.example with required environment variables
5. Document conventions in hydra/context/greenfield-scope.md
6. Initialize Terraform project structure in `infra/`
7. Generate CI/CD pipeline config for selected platform
8. Set up environment-specific Terraform variable files
9. Configure secret management for selected provider

## Out of Scope
-

## Constraints
-
