# Migration Objective

## Objective
<!-- Describe what's being migrated and to what target. -->

## Migration Type
<!-- Framework upgrade, language migration, cloud migration, DB migration, etc. -->

## Current State
- **Source**: <!-- Current technology/version -->
- **Scale**: <!-- How much code/data is affected -->

## Target State
- **Target**: <!-- Target technology/version -->
- **Compatibility**: <!-- What must remain compatible -->

## Requirements
- [ ] Feature parity with current system
- [ ] Zero data loss during migration
- [ ] Rollback plan tested and documented
- [ ] All existing tests pass on new system
- [ ] Performance equal or better than current

## Acceptance Criteria
- [ ] <!-- Specific migration criterion -->
- [ ] <!-- Specific migration criterion -->
- [ ] Rollback can be executed within N minutes

## Pattern Reference
<!-- Filled by Planner -->
- Current implementation: <!-- paths -->
- Migration tool/approach: <!-- tool, docs -->
- Compatibility matrix: <!-- what changes, what stays -->

## Context Collection Notes
The Planner should:
1. Map ALL components affected by the migration
2. Create a compatibility matrix (what works, what needs changes)
3. Identify breaking changes and their impact
4. Plan a phased migration if possible (expand-contract pattern)
5. Document in hydra/context/migration-scope.md

## Rollback Plan
<!-- Detailed steps to revert the migration -->
1. <!-- Step 1 -->
2. <!-- Step 2 -->

## Risk Assessment
| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|-----------|
| <!-- risk --> | <!-- HIGH/MED/LOW --> | <!-- HIGH/MED/LOW --> | <!-- mitigation --> |

## Out of Scope
-

## Constraints
-
