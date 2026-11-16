'use strict';
const assert = require('node:assert/strict');
const {budget} = require('../lib/agent_runtime/execution/authorized_provider_relay.cjs');
const quota = {requests: 2, tokens: 100, inputTokensPerByte: 1, inputTokenOverhead: 1,
  inputPricePerMillion: 1, outputPricePerMillion: 2, money: 1, expiresAt: 200,
  pricingEvidence: 'reviewed fixture price', tokenBoundEvidence: 'fixture byte upper bound'};
const body = {max_completion_tokens: 10};
let admit = budget({quota}, () => 100);
assert.equal(admit(Buffer.alloc(10), body).reserved_tokens, 21);
admit(Buffer.alloc(10), body);
assert.throws(() => admit(Buffer.alloc(1), body), /aggregate_budget_exhausted/);
admit = budget({quota: {...quota, tokens: 20}}, () => 100);
assert.throws(() => admit(Buffer.alloc(10), body), /aggregate_budget_exhausted/);
admit = budget({quota: {...quota, money: 0.000001}}, () => 100);
assert.throws(() => admit(Buffer.alloc(10), body), /aggregate_budget_exhausted/);
assert.throws(() => budget({quota}, () => 200)(Buffer.alloc(1), body), /aggregate_budget_exhausted/);
assert.throws(() => budget({quota: {...quota, pricingEvidence: null}}), /quota_configuration_invalid/);
console.log('authorized provider aggregate reservation tests passed (offline)');
