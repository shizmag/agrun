# Comparative experiment orchestration

`AgentRuntime::Benchmarks::ComparativeExperiment` accepts an existing Store and
ExperimentRunner. It does not construct a transport, enable providers, or relax
the runner's offline/live authorization rules.

```ruby
experiment = AgentRuntime::Benchmarks::ComparativeExperiment.new(store: store, runner: runner)
verification = experiment.run(manifest: manifest, evidence_kind: "simulated_relay")
experiment.freeze(experiment_id: manifest.data.fetch("experiment_id"),
  destination: "research-freeze", verification: verification)
```

The manifest controls the complete Cartesian matrix. One task, three solver
IDs, one model and three repetitions produce nine cells. Each submitted cell is regraded
from its persisted repository. Verification requires a fresh grading attempt,
unchanged submission and solver-attempt identities, and matching execution
status, score, verdict, protocol and quality basis. Missing submissions remain
explicitly unavailable, not successful verification. Regrading is an independent
attempt using the same grader implementation, not an independent grader audit.

The comparative strategy uses five runtime stages but only three inference
stages: inventory and validation are deterministic. Fixed workflow has three
runtime/inference stages; direct OpenCode has one. Execution telemetry remains
the authority for actual usage and cost; missing costs must not be interpreted
as zero.

Save verification as JSON to export via CLI:

```sh
bin/agru bench comparative freeze EXPERIMENT research-freeze --root .agru --verification verification.json
bin/agru bench comparative verify research-freeze
```

Export refuses an existing destination and rejects verification whose report
digest is stale. `experiment.json` contains the report, existing scientific
summary, submission identities, verification checks and limitations.
`SHA256SUMS` binds its exact bytes. Verification is offline and does not need
the original Store. It establishes bundle integrity, not authenticity or
re-execution of grading; changing both files can forge an unsigned bundle.
The export carries portable repository manifest entries (including file bytes and
modes), not mutable solver workspaces or hidden procedures. Reports may
contain operational paths, logs and adapter metadata; review before publishing.

Evidence kinds are explicit: `offline_fixture`, `simulated_relay`, or
`live_provider`. The caller is responsible for selecting the truthful kind;
this label is not served-model attestation. Simulated relay success must never
be represented as live-provider quality evidence.
# Installed OpenCode, isolated simulated relay

`bin/agru bench comparative plan` prints the nine-cell (three architectures ×
three repetitions) retrying manifest without starting a provider or Docker.
`bin/agru bench comparative readiness` checks the frozen sandbox image locally.
The explicit execution command is:

```sh
mise exec -- bundle exec ruby bin/agru bench comparative run simulation-001 .agru/simulation-001-freeze \
  --root .agru/simulation-001 --assets .agru/nl2repo --allow-simulated-execution
```

This runs the installed OpenCode executable in the frozen network-isolated
sandbox with a controlled HTTPS simulator through the trusted provider relay,
not a paid model. Each inference attempt has its own relay lifecycle and bound
attempt/cell identity in stored relay logs. NL2Repo
assets and audited grader images must already be installed. The stored report
labels this `simulated_relay`, binds relay-log SHA256 values and image digest, and
records `paid_provider_calls: false`. Regrades operate on captured submissions;
the freeze includes grading histories. This is infrastructure evidence, not
model-quality evidence, and must not be presented as a live-provider result.
