// Dedicated offline installed-LSP calibration provider, bound to loopback only.
const http = require('node:http');
const fs = require('node:fs');
const audit = value => fs.appendFileSync('/workspace/provider.jsonl', JSON.stringify(value) + '\n');
http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const request = JSON.parse(body);
    audit(request);
    const results = request.messages.filter(message => message.role === 'tool');
    let message = {role: 'assistant', content: 'AGRU_LSP_TRIGGER_COMPLETE'};
    if (!results.length) message = {role: 'assistant', content: null, tool_calls: [{
      id: 'lsp-read', type: 'function', function: {name: 'read',
        arguments: JSON.stringify({path: '/workspace/input.agru'})}}]};
    if (results.length === 1) message = {role: 'assistant', content: null, tool_calls: [{
      id: 'lsp-edit', type: 'function', function: {name: 'write',
        arguments: JSON.stringify({path: '/workspace/input.agru', content: 'AGRU_DOCUMENT_EDITED\n'})}}]};
    if (request.stream) {
      res.writeHead(200, {'content-type': 'text/event-stream'});
      const delta = message.tool_calls ? {role: 'assistant', tool_calls: message.tool_calls.map((call, index) => ({index, ...call}))} : message;
      for (const [d, finish] of [[delta, null], [{}, message.tool_calls ? 'tool_calls' : 'stop']]) {
        res.write('data: ' + JSON.stringify({id: 'lsp-mock', object: 'chat.completion.chunk', model: 'lsp-fixture', choices: [{index: 0, delta: d, finish_reason: finish}]}) + '\n\n');
      }
      res.end('data: [DONE]\n\n');
      return;
    }
    res.writeHead(200, {'content-type': 'application/json'});
    res.end(JSON.stringify({id: 'lsp-mock', object: 'chat.completion', created: 1,
      model: 'lsp-fixture', choices: [{index: 0, message,
        finish_reason: message.tool_calls ? 'tool_calls' : 'stop'}],
      usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}}));
  });
}).listen(18080, '127.0.0.1');
