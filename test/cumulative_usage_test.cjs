'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {cumulativeUsage} = require('../lib/agent_runtime/execution/cumulative_usage.cjs');
const counts = (p, c) => ({prompt_tokens: p, completion_tokens: c, total_tokens: p + c});
test('cumulative observations replace rather than sum and ignore non-count extras', () => {
  const first = cumulativeUsage(null, {...counts(0, 0), tokens_per_second: 1}).usage;
  const second = cumulativeUsage(first, {...counts(12, 4), tokens_per_second: 3}).usage;
  assert.deepEqual(second, counts(12, 4));
  assert.deepEqual(cumulativeUsage(second, {...counts(12, 4), tokens_per_second: 9}).usage, second);
  assert.deepEqual(cumulativeUsage(second, counts(13, 5)).usage, counts(13, 5));
  assert.equal(cumulativeUsage(second, counts(11, 4)).error, 'usage_conflict');
  assert.equal(cumulativeUsage(second, {...counts(12, 4), total_tokens: 99}).error, 'usage_total_mismatch');
  const detailed = {...second, completion_tokens_details: {reasoning_tokens: 3}};
  assert.equal(cumulativeUsage(detailed, {...second, completion_tokens_details: {reasoning_tokens: 2}}).error, 'usage_conflict');
  assert.equal(cumulativeUsage(second, {...second, completion_tokens_details: {reasoning_tokens: 5}}).error, 'usage_conflict');
});
