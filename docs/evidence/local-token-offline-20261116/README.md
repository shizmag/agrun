# Local token comparison: offline installed-client validation

This is **transport simulation**, not live-provider or model-quality evidence.
No live API calls were made. The installed OpenCode client ran in Docker against
synthetic in-process responses through the local gateway. The synthetic responses
do not implement the task; successful execution does not imply a passing verdict.

The complete nine-cell rotating schedule exercised 21 inference stages and 42
sequential provider requests. The temporary internal ledger reserved 87,384,192
tokens nonrefundably and settled 630 synthetic usage tokens, with no unknown
usage, unknown model, unresolved violation, or halt. Each cell was independently
regraded. Portable regrade reproduced all nine original results, and the frozen
bundle's integrity verified. `summary.json` contains the sanitized result and
bundle digest; hidden procedures, task repositories, credentials and `.agru`
state are intentionally excluded.

Reproduction (requires installed Docker images and separately provisioned assets):

```sh
mise exec -- bundle exec ruby scripts/local_comparison_offline.rb \
  .agru/local-offline-validation-fresh .agru/nl2repo
```

Use a fresh output directory for an isolated ledger. This script is an internal
offline harness; production CLI commands cannot override the authorization ledger.
The portable evaluator is the same implementation, not an independently designed
evaluation semantics. Additional hardening after this run extracted admission
for explicit concurrent-rejection tests; those tests pass independently.
