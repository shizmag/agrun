const assert = require('node:assert/strict');
const {response} = require('./m12cs2_parity_fixture.cjs');
const tools = ['read', 'shell'].map(name => ({function: {name}}));
for (const role of ['single', 'planner', 'coder', 'reviewer']) {
  const prompt = role === 'single' ? 'Implement the public retrying specification.' : `You are the ${role}.\npublic specification`;
  const messages = [{role: 'user', content: prompt}];
  const read = response({messages, tools});
  assert.equal(read.observation.s2_role, role);
  assert.equal(read.message.tool_calls[0].function.name, 'read');
  messages.push({role: 'tool', content: 'read fixture result'});
  const shell = response({messages, tools});
  const command = JSON.parse(shell.message.tool_calls[0].function.arguments).command;
  assert.ok(command.includes(`s2-${role}.txt`));
  assert.equal(command.includes('class RetryError'), role === 'single' || role === 'coder');
  assert.ok(!command.includes('reference'));
  messages.push({role: 'tool', content: 'shell fixture result'});
  assert.equal(response({messages, tools}).message.tool_calls, undefined);
}
console.log('S2 parity routing: four roles, native read/shell, finite fixture sequence passed');
