# Test Plan: [Feature/Project Name]

## Overview
<!-- What is being tested and why -->

## Test Scope

### In Scope
- <!-- Component/feature to test -->
- <!-- Component/feature to test -->

### Out of Scope
- <!-- What we are NOT testing -->

## Test Strategy

### Unit Tests
- **Framework**: <!-- from project-profile.md -->
- **Location**: <!-- from test-strategy.md -->
- **Coverage target**: <!-- percentage or description -->
- **Key areas**:
  - <!-- Area 1: what to test -->
  - <!-- Area 2: what to test -->

### Integration Tests
- **Approach**: <!-- How integration tests are structured -->
- **Key flows**:
  - <!-- Flow 1 -->
  - <!-- Flow 2 -->

### E2E Tests (if applicable)
- **Tool**: <!-- Cypress, Playwright, etc. -->
- **Critical paths**:
  - <!-- Path 1 -->
  - <!-- Path 2 -->

## Test Data
- **Fixtures**: <!-- How test data is set up -->
- **Mocks**: <!-- External services to mock -->
- **Seeds**: <!-- Database seed data needed -->

## Acceptance Criteria Verification
<!-- Map each PRD acceptance criterion to specific test(s) -->
| PRD Criterion | Test Type | Test File | Status |
|--------------|-----------|-----------|--------|
| <!-- criterion --> | <!-- unit/integration/e2e --> | <!-- path --> | <!-- pending --> |

## Regression Tests
<!-- Tests to verify nothing existing breaks -->
- <!-- Existing test suite that must still pass -->
- <!-- Specific regression scenarios -->

## Test Commands
```bash
# Run all tests
# Run specific test suite
# Run with coverage
```
