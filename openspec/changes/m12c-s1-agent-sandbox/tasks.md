## 1. Protocol documentation

- [x] 1.1 Record historical quarantine, common sandbox conditions and distinct arm semantics.
- [x] 1.2 Define candidate identity fields, freeze prerequisites and offline acceptance matrix.
- [x] 1.3 Specify registration, authorization and honest outcome/accounting rules.

## 2. Specification validation

- [x] 2.1 Add normative requirements and acceptance scenarios for the new capability.
- [x] 2.2 Run strict OpenSpec validation and review documentation-only diff.

## 3. Future implementation gates (not completed by documentation)

Latest integration note: B reports 16 tests / 96 assertions on real Docker with
quota/race/concurrent-cwd controls implemented. Snapshot consistency is unresolved:
otherwise-successful runs become blocked with
`writer_quiescence_unsupported: tmpfs archive collected before container pause`;
diagnostic archives are discarded and no usable export is accepted. Native read
evidence has an invalid schema pending correction; installed three-arm/task
acceptance remains blocked. Final parent regression passed with 823 runs / 5205
assertions / 0 failures / 0 errors / 34 skips; lint, smoke and benchmark demo also
passed. Repeated sqlite3 inherited writable-connection warnings require review.
Delivery remains PARTIAL, with no frozen identity or acceptance PASS. These narrow
controls do not complete any of the end-to-end gates below or authorize freeze.
Independent F review retained an initial 16-test / 95-assertion run with one
effective-environment mismatch at `.agru/m12cs1-review-boundary.log`; the test's
explicit reviewed HOME/XDG setup is being corrected without production policy
loosening. Shared whole-call/architecture deadline and bounded cleanup remain
unproven because stages currently each receive a full timeout budget.
B's corrected explicit-environment run reports 16 tests / 96 assertions passed;
independent F corrected run also passed 16 tests / 96 assertions with zero
failures/errors/skips at
`.agru/m12cs1-review-boundary-corrected.log`. Initial failure is retained in
`docs/m1.2c-boundary-controls.md`. Actual installed tools are read/shell/subagent,
not bash/task; C's correction and final native evidence remain pending. Parent
strict validation passed at `.agru/m12cs1-final-openspec.log`; not acceptance PASS.
The reviewed exact PATH addition is not arbitrary image ENV inheritance. The
corrected boundary-control pass is narrow, not whole-agent acceptance; overall
delivery remains PARTIAL pending stable C/D native observations and snapshot work.

- [ ] 3.1 Implement shared sandbox policy and identity binding through coordinated component changes.
- [ ] 3.2 Add and pass installed-binary offline boundary, lifecycle, parity and evidence-integrity tests.
- [ ] 3.3 Review acceptance evidence before freezing a new identity; seek separate live authorization before dispatch.
