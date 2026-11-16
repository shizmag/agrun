// Offline calibration server: stdio JSON-RPC only; no packages or network.
const fs = require('node:fs');
const log = process.env.AGRU_LSP_TRANSCRIPT;
if (!log) throw new Error('AGRU_LSP_TRANSCRIPT required');
const record = value => fs.appendFileSync(log, JSON.stringify(value) + '\n');
record({event: 'launch', pid: process.pid});
let buffer = Buffer.alloc(0);
let stopping = false;
function send(message) {
  const body = Buffer.from(JSON.stringify({jsonrpc: '2.0', ...message}));
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}
function receive(message) {
  record({event: 'receive', ...message});
  if (message.method === 'initialize') {
    send({id: message.id, result: {capabilities: {textDocumentSync: 1,
      hoverProvider: true}, serverInfo: {name: 'agru-offline-calibration', version: '1'}}});
  } else if (message.method === 'textDocument/didOpen') {
    send({method: 'textDocument/publishDiagnostics', params: {
      uri: message.params.textDocument.uri, diagnostics: [{range: {
        start: {line: 0, character: 0}, end: {line: 0, character: 1}},
      severity: 2, source: 'agru-calibration', message: 'AGRU_LSP_DOCUMENT_OBSERVED'}]}});
  } else if (message.method === 'textDocument/hover') {
    send({id: message.id, result: {contents: {kind: 'plaintext', value: 'AGRU_LSP_HOVER'}}});
  } else if (message.method === 'shutdown') {
    stopping = true;
    send({id: message.id, result: null});
  } else if (message.method === 'exit') {
    process.exit(stopping ? 0 : 1);
  } else if (Object.hasOwn(message, 'id')) {
    send({id: message.id, result: null});
  }
}
process.stdin.on('data', chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const end = buffer.indexOf('\r\n\r\n');
    if (end < 0) return;
    const match = buffer.subarray(0, end).toString().match(/^Content-Length: (\d+)$/im);
    if (!match) throw new Error('Content-Length required');
    const length = Number(match[1]);
    if (length > 1048576) throw new Error('frame too large');
    if (buffer.length < end + 4 + length) return;
    const message = JSON.parse(buffer.subarray(end + 4, end + 4 + length));
    buffer = buffer.subarray(end + 4 + length);
    receive(message);
  }
});
