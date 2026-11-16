# Comparative architecture interventions

The operational pilot compares one complete-task model invocation against three
role-separated invocations. This is not an equal-inference-budget experiment.
All invocations use the same public task instruction, installed executable,
provider contract, tools, whole-agent isolation and immutable export mechanism.
Each role receives a fresh agent process and a repository reconstructed from
the previous stage's stored artifact, not a shared mutable solver directory.

* **Single agent:** one complete-task coding invocation.
* **Fixed workflow:** planner → coder → reviewer, passing the repository and
  stored textual role notes. Three model invocations; no conditional recovery.
* **Compositional DSL:** planner and deterministic repository inventory branch
  from the frozen input. Coder joins the typed plan and inventory. A local
  manifest validation stage validates the resulting repository representation;
  reviewer consumes the implementation notes and validation evidence. Five DAG
  stages, three model invocations. Runtime artifact storage records the explicit
  dependencies and typed outputs. The inventory and validation stages perform
  no model calls and do not execute hidden benchmark procedures.

Repository manifest validation is an integrity/structure check, **not** a
correctness evaluation. Its evidence explicitly reports `not_evaluated` for
quality. The audited grader alone supplies benchmark quality observations.
There is deliberately no automatic model retry: replay safety, bounded total
inference and revised artifact selection would otherwise introduce additional
interventions. This pilot tests typed composition and explicit local evidence,
not a claim about all possible compositional architectures.

Both multi-stage variants carry notes; that capability is shared, not a unique
DSL advantage. FixedWorkflow itself uses the trusted runtime for persistence;
the distinction is the solver program's inventory branch, join and explicit
validation evidence, not a claim that its underlying executor lacks a DAG.
The deterministic checks add overhead and information that are architecture
confounders to document. The offline simulator tests orchestration only and
cannot establish model quality or architectural superiority.
