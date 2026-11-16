'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {observedUsage} = require('../lib/agent_runtime/execution/observed_usage.cjs');
test('usage observations whitelist bounded nonnegative safe integers only', () => {
  for (const value of [null, [], 'secret', 12]) assert.equal(observedUsage(value), null);
  const result = observedUsage({prompt_tokens: 12, completion_tokens: 'secret', total_tokens: -1,
    prompt_tokens_details: {cached_tokens: 3, audio_tokens: Infinity, secret: 'secret'},
    completion_tokens_details: {reasoning_tokens: Number.MAX_SAFE_INTEGER + 1, accepted_prediction_tokens: 2},
    secret: 'secret'});
  assert.deepEqual(result, {prompt_tokens: 12, completion_tokens: null, total_tokens: null,
    prompt_tokens_details: {cached_tokens: 3, audio_tokens: null},
    completion_tokens_details: {reasoning_tokens: null, audio_tokens: null,
      accepted_prediction_tokens: 2, rejected_prediction_tokens: null}});
  assert.ok(!JSON.stringify(result).includes('secret'));
});
