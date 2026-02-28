# Migration Plan: [Migration Name]

## Overview
<!-- What is being migrated and why -->

## Source -> Target
- **From**: <!-- Current technology/version/architecture -->
- **To**: <!-- Target technology/version/architecture -->

## Scope Assessment
- **Files affected**: <!-- count and paths -->
- **Services affected**: <!-- list -->
- **Data affected**: <!-- tables, volumes, etc. -->

## Feature Parity Matrix
| Feature | Source | Target | Status | Notes |
|---------|--------|--------|--------|-------|
| <!-- feature --> | <!-- how it works now --> | <!-- how it will work --> | <!-- pending/done --> | <!-- notes --> |

## Migration Phases

### Phase 1: Preparation
- [ ] <!-- Setup new environment/dependencies -->
- [ ] <!-- Create compatibility layer if needed -->
- [ ] <!-- Set up feature flags -->

### Phase 2: Parallel Running
- [ ] <!-- Run old and new side by side -->
- [ ] <!-- Verify output parity -->
- [ ] <!-- Monitor for discrepancies -->

### Phase 3: Cutover
- [ ] <!-- Switch traffic/references to new system -->
- [ ] <!-- Verify everything works -->
- [ ] <!-- Remove old system references -->

### Phase 4: Cleanup
- [ ] <!-- Remove old code/configs -->
- [ ] <!-- Update documentation -->
- [ ] <!-- Remove feature flags -->

## Rollback Plan
<!-- Detailed steps to revert at each phase -->

### Phase 1 Rollback
- <!-- Step -->

### Phase 2 Rollback
- <!-- Step -->

### Phase 3 Rollback
- <!-- Step -->

## Risk Assessment
| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|-----------|
| <!-- risk --> | <!-- H/M/L --> | <!-- H/M/L --> | <!-- mitigation --> |

## Validation Checklist
- [ ] All existing tests pass on new system
- [ ] Performance benchmarks met or exceeded
- [ ] No data loss verified
- [ ] Rollback tested successfully
- [ ] Documentation updated
