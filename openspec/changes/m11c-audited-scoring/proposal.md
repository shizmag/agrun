# Scoped audited scientific scoring

## Why
M1.1b retained real pytest observations without promoting an authoritative score.
Controlled software-generation experiments need a reproducible scoring contract
that detects ordinary collection/report contamination without claiming security
against arbitrary hostile code executing inside pytest.

## What Changes
- Add immutable `nl2repo-audited-v2`, preserving historical protocols and evidence.
- Pin retrying's independently collected canonical test population.
- Require reference preflight, clean candidate preparation, structured phase
  results, independent validation, and immutable evidence before score promotion.
- Distinguish candidate collection-policy zero from infrastructure/ambiguous
  failure, and expose quality basis, protocol, coverage and missingness.
- Use the existing experiment runner, store, regrading and report interfaces.

## Impact
Only the pinned retrying task is supported initially. Network/provider execution
is not added. Same-process coherent report forgery remains outside the supported
benign/ordinary-submission trust boundary.
