# S3 candidate environment identity (not accepted freeze)

`script/m12cs3_environment_freeze.rb` creates and validates a content-addressed
**candidate** manifest. It never dispatches a provider, runs a solver, grades an
artifact, changes runtime code, or promotes evidence to accepted status.
Historical or live labels are rejected: this utility's scope is installed mock
parity only. The requested route is `cx/gpt-6-luna-low`, not served-model proof.

## Input and execution

Use a JSON object containing a digest-pinned `image`, `requested_model`, and a
repository-relative tracked file path for each of these keys:

```
agent_binary sandbox_config tools plugins lsp mcp mock_relay_contract
model_catalog benchmark_revision task_manifest audited_v2_grader
export_contract resources_deadline scientific_protocol
```

Bindings are exact file bytes, not claims inferred from filenames. For sets of
tools/configuration, commit a complete inventory document with individual file
digests, version identifiers and effective settings. Commit binary identity
evidence extracted from the pinned image; the validator cannot independently
inspect an installed image or prove that an inventory is complete. Catalog
revision, benchmark revision, audited-v2 procedure, export policy, task manifest,
resource ceilings and deadline must be explicit in their bound documents.
Never put secrets or hidden grading procedures in solver workspaces.

```
mise exec -- bundle exec ruby script/m12cs3_environment_freeze.rb create /absolute/clean/worktree spec.json
mise exec -- bundle exec ruby script/m12cs3_environment_freeze.rb validate /absolute/clean/worktree candidate.json
```

Keep inputs and output outside the checkout or under ignored `.agru` state.
The output digest is SHA-256 over recursively key-sorted compact JSON excluding
only the top-level `sha256`. The manifest binds exact clean HEAD, pinned image,
all binding bytes, requested route, and distinct architecture cardinalities
1/3/3. It rejects dirty tracked/untracked state, changed HEAD, stale manifest
digests, missing bindings, external binding targets and schema/status changes.
Ignored files are intentionally outside Git cleanliness; they must not supply
execution-affecting configuration. This is identity validation, not a sandbox.

## Non-self-referential acceptance workflow

1. Finish implementation and A/B gates; parent commits implementation first.
2. Create a fresh isolated worktree at that exact commit. No changes affecting
   execution are permitted during the run, including ignored config or tools.
3. Generate the candidate manifest outside that worktree. Validate immediately
   before and after fresh installed parity; independently verify binary/image
   and effective configuration against bound inventories.
4. Require seven real installed mock invocations with semantic role/tool
   inspection: single; fixed planner/coder/reviewer; DSL planner/coder/reviewer.
   Cardinalities alone do not prove semantic architecture preservation.
5. Capture each actual submission once, then grade and regrade that immutable
   artifact independently. Preserve execution status separately from verdict.
   Bind parity report and artifact digests to this candidate digest and commit.
6. Store acceptance as a separate evidence record only after all gates pass.
   A later documentation commit may cite that prior frozen commit and digest;
   it must not rewrite the identity as its own new HEAD or imply that the new
   commit was tested. Any runtime/config/image change requires a new candidate
   and fresh parity. Never amend historical results into new controls.

No accepted freeze is created here. The validator does not implement the
acceptance evidence gates, prevent concurrent mutation, or attest host isolation.
Writer-quiescent export and scientific protocol gates remain prerequisites;
passing these unit tests cannot satisfy them. Existing S1/S2 scientific and
reconstruction documents remain authoritative for historical quarantine.

## Separate accepted-release attestation

The Ruby API `release(root, candidate, evidence, review)` now constructs a
separate accepted attestation; `validate_release(root, candidate, evidence,
review, attestation)` reconstructs it against the current clean checkout.
The candidate itself remains immutable and retains candidate status.
Evidence must bind candidate digest and runtime commit, declare installed mock
scope with `capability_claim: false`, contain nonempty artifact digest mapping,
and pass every gate listed in `GATES` in the script. Review must pass, declare
independence, name a nonempty reviewer distinct from producer, and bind the exact
evidence digest. Attestation binds both evidence and review digests.

These are explicit attestation assertions, not cryptographic proof of reviewer
independence or automatic parsing of underlying acceptance reports. The caller
must independently inspect the bound artifacts before asserting gates. Mock
scores cannot be relabeled as live capability. Missing gates block release;
runtime/config mutation invalidates both candidate and release validation.

An ignored `.agru/m12cs3-freeze-draft/inventory.json` records actual S2 source
configuration (binary digest, limits, relay, plugin/MCP/LSP settings and public
specification). Unknown image/catalog/assets/deadline fields remain unresolved,
not placeholder hashes. It is not a valid candidate input or accepted record.

The subsequent `sandbox/m12cs3-release-contract.json` captures the supplied pinned
image and inspected effective S2 policy, exact 120-second solve/grading deadlines,
catalog resolution and verified benchmark metadata. The ignored draft input
`.agru/m12cs3-freeze-draft/spec.json` maps all fourteen bindings to actual sources.
It remains a draft: historical live task manifest is bound as task identity only,
not reused as launch configuration. Grader source identity is not proof of the
audited-v2 effective image/procedure; those asset digests must be supplied before
acceptance. The historical base image's available/unvalidated metadata is not
promoted to audited-v2 readiness. Parent must commit the contract before candidate
creation in a clean worktree.

Independent mutation-review entry point: `test/m12cs3_environment_freeze_test.rb`
and `script/m12cs3_environment_freeze.rb` (`release`, `validate_release`). Review
should mutate evidence identity, each gate, review identity/digest, artifact hashes,
environment and live/capability labels; no accepted attestation is checked in.

Audited-v2 preparation is now recorded in the contract: actual grader image and
config digest, independently hashed image test source, locally hashed reference,
collector/transport/validator/promotion/adapter source hashes, test-manifest digest
and effective grader resource policy. S2 procedure/environment digests are labeled
historical observations from the postcommit evidence and a hash-verified Store
object; fresh S3 parity must bind its own procedure identity. Only hashes and
public identity metadata were copied, not hidden tests or reference contents.
The ignored input now binds the grader inventory contract rather than only its
Ruby source file. E's dirty-guard mutant exposed missing creation coverage:
explicit tests now reject both dirty tracked input and untracked input at create.
Removing the standalone stale-digest check is behaviorally redundant with full
manifest reconstruction; no internal-implementation assertion was added for it.

LSP availability is separately bound to B's version-correlated source evidence
in `sandbox/m12cs3-lsp-unavailability.json`. It is unavailable/N/A, not a paired
PASS and not proof of actual LSP startup, active LSP tools, or reproducible build
provenance. No release gate boolean has been relaxed or changed. The inventory records configured `lsp: false`
separately from the absence of an implemented runtime.

Update: E independently approved the native-LSP N/A classification. The contract
records that classification approval only, not release approval. The reviewed
source evidence file and its digest are unchanged; all acceptance template gates
remain false until final workstream results and the parent frozen commit exist.

## Parent post-commit command sheet

Do not run acceptance until A/B/C/E finish and E approves LSP classification.
Parent alone commits implementation. Refresh inventory hashes if any bound
source changed; commit the complete intended script/test/contract/docs set.
Create a clean isolated worktree at the exact resulting commit. Below, `FROZEN`
is its absolute path and `OUT` is a new absolute ignored evidence directory in
the original workspace, not inside the frozen worktree. `DRAFT` is the absolute
original `.agru/m12cs3-freeze-draft` directory. Preserve candidate bytes forever.

```sh
git worktree add --detach "$FROZEN" "$COMMIT"
mise exec -- bundle exec ruby "$FROZEN/script/m12cs3_environment_freeze.rb" create "$FROZEN" "$DRAFT/spec.json" > "$OUT/candidate.json"
mise exec -- bundle exec ruby "$FROZEN/script/m12cs3_environment_freeze.rb" validate "$FROZEN" "$OUT/candidate.json"
```

Run from `FROZEN`, with its own dependencies available through `.bundle/gems`:

```sh
AGRU_M12CS2_PARITY=1 AGRU_M12C_AGENT_IMAGE=sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1 AGRU_M12CS2_EVIDENCE_ROOT="$OUT/parity-01" AGRU_M12CS2_ASSETS="$ASSETS" mise exec -- bundle exec ruby test/m12cs2_offline_parity_test.rb
```

`ASSETS` is the verified original `.agru/nl2repo` absolute path, never a solver
workspace. Evidence directory must be new. Archive logs and actual Store objects,
not just scores. Repeat with a fresh `parity-02` directory if required; never
overwrite the original run or candidate. Validate candidate before and after
each acceptance run. Stop if checkout, effective config, image or tools differ.

Ignored `acceptance-input.json` and `review-input.json` are deliberately failing
templates. Copy them into `OUT`, fill candidate SHA/commit from candidate, and
hash every inspected evidence file into `artifacts` (name to SHA-256). Include A,
B, E's N/A review, parity reports, semantic inspections and immutable grade/regrade
evidence. Set each of eight gates true only after its evidence is verified.
`b_pass` means B's approved boundary gate, including explicitly reviewed N/A;
it must never describe unavailable LSP as a paired PASS. Independent reviewer
must set verdict/independence and distinct nonempty producer/reviewer identifiers,
and bind the canonical evidence digest, not the pretty-printed file digest.

Use this Ruby API driver, running from `FROZEN`, after inputs are complete:

```ruby
require_relative "script/m12cs3_environment_freeze"
f = M12cs3EnvironmentFreeze
root = Dir.pwd
out = ENV.fetch("OUT")
load_json = ->(name) { JSON.parse(File.read(File.join(out, name))) }
candidate = load_json.call("candidate.json")
evidence = load_json.call("acceptance-input.json")
review = load_json.call("review-input.json")
# Reviewer computes f.digest(evidence), records it in evidence_sha256, then signs
# off the exact review-input document through the independent review process.
attestation = f.release(root, candidate, evidence, review)
path = File.join(out, "release.json")
File.open(path, File::WRONLY | File::CREAT | File::EXCL) do |file|
  file.write(JSON.pretty_generate(attestation))
end
f.validate_release(root, candidate, evidence, review, load_json.call("release.json"))
```

After repeated acceptance, use `validate_release` again with the original four
documents. It must match exactly. New evidence requires a separate attestation,
never mutation of an old record. CLI supports candidate create/validate only;
release operations intentionally use the explicit Ruby API above.

Artifact integrity boundary: `release` validates artifact digest syntax and binds
the hash index; it does **not** open artifact paths or verify filesystem bytes.
Parent/reviewer must independently SHA-256-verify every indexed artifact and
retained Store object before asserting gates, and repeat that audit when validating
retained evidence. `validate_release` alone cannot detect changed external bytes
when the supplied hash index remains unchanged.

Effective environment inventory is taken from `SandboxOpenCodeLaunch#environment`,
not image defaults or runner allowlist: HOME is `/tmp/agru-home`, XDG config/data/
cache/state are beneath that HOME, and TMPDIR is `/tmp`. In particular effective
XDG config is **not** `/tmp/config`. The contract records the complete launch
environment; inline config bytes are generated from the bound configuration.
