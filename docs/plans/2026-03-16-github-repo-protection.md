# GitHub Repo Protection Setup Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Configure main branch protection with required status checks, PR reviews, and Copilot code review for the Strumtry/ai-hydra-framework repo.

**Architecture:** All configuration via `gh api` calls to the GitHub REST API. No code changes — purely repo settings. Uses branch protection rules (not rulesets) since this is a single-branch protection for `main`.

**Tech Stack:** GitHub CLI (`gh`), GitHub REST API, GitHub Actions

---

### Task 1: Enable branch protection on main

**Files:**
- No files — API configuration only

**Step 1: Apply branch protection rules**

```bash
gh api repos/Strumtry/ai-hydra-framework/branches/main/protection \
  --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["test"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false
}
EOF
```

This configures:
- **Required status checks**: `test` job must pass (from `.github/workflows/test.yml`), branch must be up-to-date with `main`
- **Required PR reviews**: 1 approving review, stale reviews dismissed on new pushes
- **No force pushes** to main
- **No deletions** of main
- **Admins NOT enforced** — allows you to bypass in emergencies

**Step 2: Verify protection is active**

Run: `gh api repos/Strumtry/ai-hydra-framework/branches/main/protection --jq '{status_checks: .required_status_checks.contexts, reviews: .required_pull_request_reviews.required_approving_review_count, force_push: .allow_force_pushes.enabled}'`

Expected:
```json
{"status_checks":["test"],"reviews":1,"force_push":false}
```

**Step 3: Verify by checking branch status**

Run: `gh api repos/Strumtry/ai-hydra-framework/branches/main --jq '{protected: .protected}'`

Expected: `{"protected":true}`

---

### Task 2: Enable Copilot code review as required reviewer

**Files:**
- No files — API/UI configuration only

**Step 1: Check Copilot review is active on the repo**

Run: `gh api repos/Strumtry/ai-hydra-framework/actions/workflows --jq '.workflows[] | select(.name | test("copilot|Copilot")) | {name, state}'`

Expected: Shows "Copilot code review" as active (already confirmed during planning).

**Step 2: Enable Copilot as a suggested reviewer on PRs**

Copilot code review is configured at the org/repo level through GitHub settings. To enable it:

Run:
```bash
gh api repos/Strumtry/ai-hydra-framework/copilot/reviews \
  --method PUT \
  --input - <<'EOF'
{
  "enabled": true
}
EOF
```

If the API endpoint is not available (it may require UI configuration), do this manually:
1. Go to: `https://github.com/Strumtry/ai-hydra-framework/settings` > Code review > Copilot
2. Enable "Copilot code review"
3. Set review scope to "All pull requests"

**Step 3: Test with the existing open PR**

Run: `gh pr list --state open`

If PR #1 is still open, request a Copilot review:
```bash
gh pr edit 1 --add-reviewer @copilot
```

Or if that syntax isn't supported:
```bash
gh api repos/Strumtry/ai-hydra-framework/pulls/1/requested_reviewers \
  --method POST \
  --field 'reviewers[]=copilot'
```

**Step 4: Verify**

Run: `gh pr view 1 --json reviewRequests --jq '.reviewRequests'`

Expected: Shows copilot in the reviewer list.

---

### Task 3: Verify end-to-end protection

**Files:**
- No files — verification only

**Step 1: Confirm direct push to main is blocked**

Run:
```bash
git stash
git checkout main
echo "# test" >> /dev/null
git checkout feat/FEAT-001-hydra-plugin-development
git stash pop 2>/dev/null || true
```

(We don't actually push — just verify the protection is in place via API.)

Run: `gh api repos/Strumtry/ai-hydra-framework/branches/main --jq '{protected: .protected, required_status_checks: .protection.required_status_checks.contexts, required_reviews: .protection.required_pull_request_reviews.required_approving_review_count}'`

Expected: `protected: true`, status checks include `test`, reviews require 1

**Step 2: Document the protection setup**

Print summary:
```
Branch Protection Summary for Strumtry/ai-hydra-framework:

  main branch:
    - Protected: yes
    - Required status checks: test (strict — branch must be up to date)
    - Required PR reviews: 1 approving review
    - Stale review dismissal: yes
    - Force push: blocked
    - Branch deletion: blocked
    - Admin bypass: allowed (for emergencies)
    - Copilot code review: enabled
```

---

## Task Dependency Graph

```
Task 1 (branch protection) — independent
Task 2 (Copilot review) — independent
Task 3 (verification) — depends on Task 1 + 2
```

Tasks 1 and 2 can run in parallel. Task 3 depends on both.

## Notes

- The org is on **Team plan** which fully supports branch protection rules
- `enforce_admins: false` lets you bypass protection in emergencies — change to `true` if you want strict enforcement for everyone
- The `test` status check name comes from the job name in `.github/workflows/test.yml`
- Copilot code review is a "dynamic workflow" managed by GitHub, not a file in the repo
- If you later want to require Copilot approval (not just review), you'd need to add it as a required check via rulesets
