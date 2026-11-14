## 1. Baseline and independent audit
- [x] 1.1 Verify clean M1.1 baseline and create dedicated branch.
- [x] 1.2 Run baseline tests, lint, smoke and fixture acceptance.
- [x] 1.3 Launch independent protocol, control, grader, integration and review workstreams.
- [x] 1.4 Record independent upstream protocol and permission findings.

## 2. Contracts and test-first changes
- [x] 2.1 Define protocol, evidence, isolation and missingness requirements.
- [x] 2.2 Challenge contracts and record initial failing tests.
- [x] 2.3 Implement the smallest justified reusable changes.

## 3. Real acceptance gates
- [x] 3.1 Prepare one pinned official image and authorized controls.
- [ ] 3.2 Execute reference, empty and incorrect authoritative tests.
- [ ] 3.3 Persist a real experiment and independently regrade.

3.2/3.3 remain open as authoritative acceptance gates: official tests really ran
for all three controls, the incorrect control traversed ExperimentRunner and
independent regrade, and the private reference was Store-backed without solver
exposure. All results remain explicitly untrusted and unscored because native
collector authority has not been validated. See `docs/m1.1b-verification.md`.

## 4. Review and verification
- [x] 4.1 Record adversarial mutations and external blockers accurately.
- [x] 4.2 Run full regression, conformance and strict specification validation.
- [x] 4.3 Document evidence, commit intended changes and leave clean tree.
