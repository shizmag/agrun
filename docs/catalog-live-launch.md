# Catalog-backed live launch

`OpenCodeLaunch.new` accepts optional `model_profile:` and `model_resolution:`
keywords together. The profile and persisted resolution must agree on provider,
endpoint, exact wire model, inference parameters and route; fallback is disabled.
Nonempty inference parameters require explicit `parameter_delivery: wire_id`.
The launch does not interpret model suffixes or translate inference parameters.
Without these keywords the historical isolated launch remains unchanged.

LiveCLI passes the manifest's resolved evidence and profile to the launch. Its
authorization scope uses the exact wire route, not the catalog lookup key.
Catalog declarations are requested routing evidence, not served-model proof.
The existing explicit authorization, credential and executable checks still apply;
configuration isolation is not an egress sandbox or a hard spending limit.
