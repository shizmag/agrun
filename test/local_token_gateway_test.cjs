'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {admission} = require('../scripts/local_token_gateway.cjs');

test('concurrent rejection cannot settle or steal another request reservation', () => {
  const events = [];
  const gate = admission({requestLimit: 2, ledger: event => events.push(event), emit() {}});
  gate.authorizeRequest(Buffer.from('{}'), {}, 'first');
  assert.throws(() => gate.authorizeRequest(Buffer.from('{}'), {}, 'rejected'), /request_limit/);
  gate.audit({request_id: 'rejected', usage: {total_tokens: 999}});
  assert.equal(events.length, 1);
  assert.throws(() => gate.authorizeRequest(Buffer.from('{}'), {}, 'still-rejected'), /request_limit/);
  gate.audit({request_id: 'first', response_model: 'cx/gpt-6-luna-low', usage: {total_tokens: 15}});
  gate.audit({request_id: 'first'});
  gate.authorizeRequest(Buffer.from('{}'), {}, 'second');
  gate.audit({request_id: 'second', response_model: 'cx/gpt-6-luna-low', usage: {total_tokens: 20}});
  assert.deepEqual(events.map(e => [e.action, e.request_id]), [
    ['reserve', 'first'], ['settle', 'first'], ['reserve', 'second'], ['settle', 'second']
  ]);
  assert.equal(events[1].usage.total_tokens, 15);
  assert.equal(events[3].usage.total_tokens, 20);
  assert.throws(() => gate.authorizeRequest(Buffer.from('{}'), {}, 'third'), /request_limit/);
});

test('failed admission never permits dispatch and oversized bodies never reserve', () => {
  let reservations = 0;
  const gate = admission({requestLimit: 1, ledger() { reservations++; throw Error('budget_exceeded'); }, emit() {}});
  assert.throws(() => gate.authorizeRequest(Buffer.alloc(1048577), {}, 'large'), /request_limit/);
  assert.equal(reservations, 0);
  assert.throws(() => gate.authorizeRequest(Buffer.from('{}'), {}, 'budget'), /budget_exceeded/);
  assert.equal(reservations, 1);
});
