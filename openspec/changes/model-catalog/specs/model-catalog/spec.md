# Model catalog integration

## ADDED Requirements

### Requirement: Explicit resolution and durable evidence
The CLI SHALL accept an optional catalog path when planning and running.
Resolution SHALL bind a requested route snapshot into the manifest digest.
Manifests without a catalog SHALL retain their historical shape.

#### Scenario: Offline strategy parity and catalog-independent reload
- GIVEN an explicit operator route and matching manifest profile
- WHEN single-agent, fixed-workflow and compositional-dsl offline cells run
- THEN they share the resolved manifest snapshot
- AND reports retain that snapshot after the catalog changes
- AND no provider call or automatic historical repricing occurs.

### Requirement: Honest dispatch and accounting scope
Catalog declarations SHALL NOT imply verified capabilities or universal adapter
transport of inference parameters. Missing tariffs SHALL remain unknown.
Live execution SHALL retain existing authorization and single-agent gates.

#### Scenario: Unverified accounting remains unknown
- **WHEN** a resolved route lacks verified accounting semantics or a tariff
- **THEN** its cost estimate SHALL remain unknown and SHALL NOT become a provider charge
