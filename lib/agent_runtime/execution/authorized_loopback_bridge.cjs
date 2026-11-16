// Solver-side bridge: no credentials, DNS, or upstream network access.
const http = require('node:http');
if (process.argv[2] !== 'bridge') throw new Error('bridge mode required');
http.createServer((req, res) => {
  const upstream = http.request({socketPath: '/relay/provider.sock', path: req.url,
    method: req.method, headers: req.headers}, response => {
    res.writeHead(response.statusCode, response.headers);
    response.pipe(res);
  });
  upstream.on('error', () => { res.writeHead(502); res.end(); });
  req.pipe(upstream);
}).listen(18080, '127.0.0.1', () => process.stdout.write(JSON.stringify({ready: 'bridge'}) + '\n'));
