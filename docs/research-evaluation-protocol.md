# Research evaluation protocol

M1.1 fixture experiments are infrastructure demonstrations. They establish no
quality advantage of any solver architecture and must not generate a scientific
delta from deterministic generated outputs.

Future experiments must preregister task subset role (development, pilot, final),
pin dataset and grader, use common task/repetition coordinates and model endpoint
profiles, retain every failed/incomplete cell, and avoid tuning on final grading
outcomes. A native-compatible evaluator is not automatically adversarially sound.

Budget regimes are distinct: equal measured monetary budget; equal wall time;
equal model/tool access; equal local verification; and practical unrestricted.
Do not describe invocation count alone as scientific fairness. Record all roles,
tool/model calls and attempts; missing usage/cost remains unknown. Cost estimates
and authoritative provider charges have separate provenance and coverage.

Quality is conditional on complete task repetitions and must disclose coverage.
Unavailable tasks and infra errors are never zero-quality observations. Report
macro per-task mean separately from pooled test counts. Pair only matching task
and repetition with valid results in both arms; disclose excluded pairs. Attempts
on the same task are not independent tasks. Confidence intervals for small pilots
are exploratory; add a task-cluster statistical implementation before publishing
inferential comparisons. No inference implementation is claimed in M1.1.

Before paid experiments: validate trusted native collection against real positive
and negative controls; enforce provider/network/budget policy in the solver
sandbox; establish authoritative complete usage accounting. Live calls remain
disabled in the M1.1 infrastructure path until these gates are satisfied.

## Scoped M1.1c retrying results

`nl2repo-audited-v2` is explicitly limited to `retrying`, its independently frozen
23 canonical pytest identities, and benign ordinary submissions. Structured
collection in the candidate execution domain is not candidate-resistant
authentication. Report `trust_scope: benign_ordinary_submissions` alongside the
protocol and `quality_basis`; do not market it as an official leaderboard result,
paper-compatible score, or validation of all 104 NL2Repo tasks.

Preserve historical legacy/v1 evidence and blocked/untrusted labels. A successful
reference control cannot retroactively upgrade those observations. Keep v2
results separate by protocol and quality basis; disclose `candidate_collection_failure`
zeros separately from `validated_quality_result` evaluations and never convert
infrastructure failures into quality zeros. A single selected task is an
infrastructure-development control, not an independent task sample sufficient
for scientific solver-quality or architecture-advantage claims. Existing fairness,
coverage, pairing, preregistration, and paid-experiment gates still apply.
