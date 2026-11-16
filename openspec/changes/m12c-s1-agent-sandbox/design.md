## Context

Historical file-tool denial did not restrict shell reads. The original smoke is
not a valid three-arm comparison. Existing contracts separate execution status,
evaluation verdict and evidence identity, and prohibit implicit live calls.

## Goals / Non-Goals

Goals: preregister a shared effective boundary, complete identity and offline
acceptance gates while preserving arm treatments and historical evidence.

Non-goals: implement production isolation, change public APIs, claim universal
security, freeze an untested identity, launch providers or expand the pilot.

## Decisions

Use one shared sandbox policy for all arms rather than removing shell from only
one arm: otherwise local testing/tool availability becomes a confound. Preserve
architecture-specific orchestration and prompts as explicit treatment identity.

Bind effective runtime/configuration and immutable image evidence, not merely a
protocol label. Mark candidate identity unfrozen until installed-binary offline
tests pass; material changes require a new acceptance cycle.

Keep old reports immutable rather than regrading/relabeling them as new cells.
Specify executable acceptance scenarios now; implementation owners must supply
actual offline tests and evidence before any future dispatch proposal.

## Risks / Trade-offs

Sandbox backends and provider transport may differ by platform. Record exact
platform and tested scope rather than inferring equivalent isolation. Credentials
need scoped transport without disclosure. Passing canaries cannot prove arbitrary
hostile-code containment. A small smoke cannot establish architecture superiority.

## Migration Plan

Documentation only. Implement and test the boundary separately; then register a
new frozen identity and seek explicit live approval. Historical runs retain their
original protocol and identities. No migration or backfill is performed here.
