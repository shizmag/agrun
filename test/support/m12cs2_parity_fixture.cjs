// Frozen infrastructure responses, not model output or a reference implementation.
const crypto = require('node:crypto');
const implementation = '# Incomplete independently authored infrastructure fixture.\nclass RetryError(Exception):\n    pass\nclass Retrying:\n    def __init__(self, *args, **kwargs):\n        pass\ndef retry(*args, **kwargs):\n    def decorate(function):\n        return function\n    return decorate\n';
function response(parsed) {
  const users = (parsed.messages || []).filter(m => m.role === 'user');
  const prompt = users.map(m => typeof m.content === 'string' ? m.content : JSON.stringify(m.content)).join('\n');
  const matches = [...prompt.matchAll(/You are the (planner|coder|reviewer)\./g)];
  const role = matches.length ? matches[matches.length - 1][1] :
    prompt.includes('Independently verify the implementation against the task.') ? 'reviewer' :
    prompt.includes('Implement the task using the supplied plan') ? 'coder' :
    prompt.includes('Plan the change. Do not implement it.') ? 'planner' : 'single';
  const results = (parsed.messages || []).filter(m => m.role === 'tool').length;
  const message = {role: 'assistant', content: `S2 fixture ${role} complete; not model capability evidence.`};
  const names = (parsed.tools || []).map(t => t.function?.name);
  if (results === 0 && names.includes('read')) {
    message.content = null;
    message.tool_calls = [{id: `s2-${role}-read`, type: 'function', function: {
      name: 'read', arguments: JSON.stringify({path: '/workspace'})}}];
  } else if (results === 1 && names.includes('shell')) {
    const marker = `printf '%s\\n' 'S2 fixture ${role}' > s2-${role}.txt`;
    const write = ['single', 'coder'].includes(role) ? `\ncat > retrying.py <<'S2_FIXTURE_PY'\n${implementation}S2_FIXTURE_PY\n` : '';
    message.content = null;
    message.tool_calls = [{id: `s2-${role}-shell`, type: 'function', function: {
       name: 'shell', arguments: JSON.stringify({command: 'cd /workspace\n' + marker + write, timeout: 1000})}}];
  }
  return {message, observation: {s2_role: role, prompt_sha256: crypto.createHash('sha256').update(prompt).digest('hex'),
    request_sha256: crypto.createHash('sha256').update(JSON.stringify(parsed)).digest('hex'),
    tool_results: results, advertised_tool_names: names}};
}
module.exports = {response};
