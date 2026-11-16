'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {admission} = require('../scripts/local_token_gateway.cjs');

for (const outcome of ['transport_error', 'success']) {
  test(`settlement failure preserves ${outcome} audit and fails closed without secrets`, () => {
    const emitted = [];
    const operations = [];
    const gate = admission({requestLimit: 4, ledger(event) {
      operations.push(event.action);
      if (event.action === 'settle') throw Error('secret-provider-credential');
    }, emit: record => emitted.push(record)});
    gate.authorizeRequest(Buffer.from('{}'), {}, 'request-1');
    const record = {request_id: 'request-1', error: outcome === 'transport_error' ? 'upstream_error' : null,
      status: outcome === 'transport_error' ? 502 : 200, usage: null, accounting_issues: ['usage_missing']};
    assert.doesNotThrow(() => gate.audit(record));
    assert.equal(emitted.length, 1);
    assert.deepEqual(emitted[0], {...record, ledger_error: 'settlement_failed'});
    assert.equal(JSON.stringify(emitted).includes('secret-provider-credential'), false);
    assert.equal(record.ledger_error, undefined);
    assert.throws(() => gate.authorizeRequest(Buffer.from('{}'), {}, 'request-2'), /request_limit/);
    assert.deepEqual(operations, ['reserve', 'settle']);
  });
}
