# Model catalog verification

Branch: `feat/model-catalog-pricing`. Historical M1.2b evidence is unchanged.
No provider calls were performed for this work.

Test-first evidence: catalog tests initially failed with the missing module;
CLI integration initially rejected `--model-catalog`. During concurrent integration
an intermediate full run failed on report fixtures without `models` and an
unsupported parameter-delivery fixture. Compatibility/default handling and the
explicit fixture declaration corrected those failures without weakening gates.

- Full regression: `mise run test`: **777 runs / 4,991 assertions**, zero failures
  or errors, 19 opt-in installed-binary skips (seed 63681).
- Final focused catalog/integration tests after attribution recomputation:
  **10 runs / 45 assertions**, zero failures/errors/skips.
- `mise run smoke`: PASS, entirely offline.
- `mise run lint`: PASS.
- `openspec validate --all --strict`: **9 passed / 0 failed**.
- `git diff --check`: PASS.

Independent reviewer challenged endpoint binding, silently ignored parameters,
mutable accounting semantics, malformed tariffs, pricing references and forged
derived attribution statuses. Corrections bind endpoint and explicit wire-ID
parameter delivery, freeze accounting rules, reject dangling references, and
recompute scoped gateway identity before estimating. Missing pricing references
remain explicitly documented as unpriced for minimal declarations. Trusted local
evidence is not a cryptographic served-model attestation.

The checked-in operator declaration contains only the confirmed low/base relation,
known route mapping and shared tariff reference. It contains no numerical rates
or invented accounting capabilities; its estimate remains unknown. Synthetic
test tariffs verify exact arithmetic and included/additive token categories.
No historical experiment is automatically repriced or relabeled.
