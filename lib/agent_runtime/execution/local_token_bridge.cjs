'use strict';
// One reusable HTTP connection through the stage's single-connection stdio bridge.
// The helper is network-disabled and holds no upstream credentials.
const http = require('node:http');
if (process.argv[2] !== 'bridge') throw Error('bridge mode required');
const agent = new http.Agent({keepAlive: true, maxSockets: 1});
http.createServer((req, res) => {
  const chunks = [];
  let size = 0;
  req.on('data', chunk => { size += chunk.length; if (size > 1048576) req.destroy(); else chunks.push(chunk); });
  req.on('end', () => {
  let bytes;
  try {
    const body = JSON.parse(Buffer.concat(chunks));
    body.max_completion_tokens = 32000;
    bytes = Buffer.from(JSON.stringify(body));
  } catch (_) { res.writeHead(400); res.end(); return; }
  const headers = {...req.headers, connection: 'keep-alive', 'content-length': bytes.length};
  delete headers['transfer-encoding'];
  const upstream = http.request({socketPath: '/relay/relay.sock', path: req.url,
    method: req.method, headers, agent}, response => {
    res.writeHead(response.statusCode, response.headers);
    response.pipe(res);
  });
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
  upstream.end(bytes);
  });
}).listen(18080, '127.0.0.1', () => process.stdout.write(JSON.stringify({ready: 'bridge'}) + '\n'));
