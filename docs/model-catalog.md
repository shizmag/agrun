# Explicit operator model catalogs

`agru bench plan MANIFEST --model-catalog CATALOG.json` and `bench run` accept
an optional operator-owned JSON catalog. The option is also available on
`bench live plan`, `preflight`, and `run`; it neither authorizes calls nor widens
the M1.2b single-agent live pilot. Offline execution stays offline.

No new top-level manifest field is introduced. Each selected model declares
`catalog_route` and a matching `model_profile`: provider, exact model wire ID,
`tool_policy.endpoint`, and `inference_parameters`. All three offline solver
strategies use the same resolved manifest snapshot.

Illustrative declaration, not verified provider metadata or production rates:

```json
{
  "revision": "operator-reviewed-v1",
  "models": {"base": {}},
  "variants": {
    "low": {"model": "base", "parameters": {"reasoning_effort": "low"}}
  },
  "routes": {
    "operator-low": {
      "variant": "low", "provider": "operator-provider",
      "endpoint": "operator-endpoint", "wire_id": "operator-wire-id",
      "parameter_delivery": "wire_id"
    }
  },
  "pricing": {}
}
```

The low variant explicitly references its base. Suffixes establish no identity,
capabilities, prices, or inference semantics. Parameters are declarative:
existing adapters do not universally transport generic inference parameters.
The operator must verify that the chosen route implements intended semantics;
otherwise this is not evidence of a low-effort dispatch.
Nonempty parameters require explicit `parameter_delivery: wire_id`; unsupported
generic parameter delivery is rejected rather than silently ignored.

Resolution evidence is frozen into the manifest and digest. Report arms expose
requested `model_resolution`, not proof of the model actually served. Reloading
stored experiments never consults the current catalog or backfills historical
records. Missing tariffs remain unknown. Explicit catalog accounting uses exact
rational amounts (`amount_encoding: exact_rational`), not guessed production
rates. Root-step totals are not automatically repriced: event category mapping
and provider accounting require independent verification.

`models/catalog.json` records only the operator-confirmed low/base inheritance
and the previously observed gateway mapping. It supplies no numerical rates or
verified accounting declaration, and therefore cannot yield a numeric estimate.
It does not modify or reinterpret any M1.2b manifest or report.

## Pricing and attribution contract

Variants may reference the same named pricing profile. An explicit `null` pricing
reference means unknown; a non-null dangling reference is an invalid catalog.
An omitted pricing reference is also unpriced (for minimal legacy declarations).
Profiles retain tariff revision/provenance, currency, token denominator and exact
decimal-string rates for `input`, `cached_input`, `output`, and `reasoning`.
The resolved snapshot includes the catalog content digest: changing content even
under the same revision changes the manifest digest.

Route `accounting` declares `input_includes_cached` and
`output_includes_reasoning`, both explicit booleans, plus provenance. Included
subcategories are subtracted before pricing; missing, negative, fractional,
inconsistent or unknown counts leave the estimate unknown. No absent category is
treated as zero. Rates and token denominator use exact rational arithmetic;
`amount` is a numerator/denominator string, without floating-point rounding.

`ModelCatalog#attribute` preserves requested, gateway and caller-supplied served
evidence separately. Gateway matching requires the configured provider (or
explicit `gateway_provider`), endpoint and canonical model; it never creates a
served attestation. `cost` requires matching scoped gateway evidence, and rejects
conflicting supplied served evidence. Its output is only a configured-tariff
estimate for supplied categories, never a claim of complete usage or a charge.
Caller-supplied evidence remains trusted local input, not cryptographic proof.
