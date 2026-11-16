'use strict';
// One reusable HTTP connection through the stage's single-connection stdio bridge.
// The helper is network-disabled and holds no upstream credentials.
const http = require('node:http');
if (process.argv[2] !== 'bridge') throw Error('bridge mode required');
const agent = new http.Agent({keepAlive: true, maxSockets: 1});
http.createServer((req, res) => {
  const headers = {...req.headers, connection: 'keep-alive'};
  const upstream = http.request({socketPath: '/relay/relay.sock', path: req.url,
    method: req.method, headers, agent}, response => {
    res.writeHead(response.statusCode, response.headers);
    response.pipe(res);
  });
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
  req.pipe(upstream);
}).listen(18080, '127.0.0.1', () => process.stdout.write(JSON.stringify({ready: 'bridge'}) + '\n'));
