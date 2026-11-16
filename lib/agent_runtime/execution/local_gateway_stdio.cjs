'use strict';
// Trusted network-disabled container: one bounded-lifetime HTTP connection.
const net = require('node:net');
const fs = require('node:fs');
let active = false;
const server = net.createServer(socket => {
  if (active) { socket.destroy(); return; }
  active = true;
  socket.setTimeout(600000, () => socket.destroy());
  process.stdin.pipe(socket);
  socket.pipe(process.stdout);
  const stop = () => { socket.destroy(); process.exit(0); };
  socket.on('close', stop);
  socket.on('error', stop);
  process.stdin.on('end', stop);
  process.stdin.on('error', stop);
  process.stdout.on('error', stop);
});
server.maxConnections = 8;
server.listen('/relay/relay.sock', () => {
  fs.chmodSync('/relay/relay.sock', 0o600);
  fs.chownSync('/relay/relay.sock', 65534, 65534);
});
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0));
