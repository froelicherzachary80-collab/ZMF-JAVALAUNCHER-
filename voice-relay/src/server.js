'use strict';
// Entry point: HTTP server with a health endpoint and the WebSocket relay at /voice.
const http = require('http');
const { createRelay } = require('./relay');

const port = Number(process.env.PORT || 24470);
const authMode = process.env.ZMF_AUTH === 'none' ? 'none' : 'mojang';
if (authMode === 'none') console.warn('WARNING: ZMF_AUTH=none — identities are NOT verified. Use only for local testing.');

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, ...relay.stats() }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('ZMF Voice relay. Connect ZMF Java Launcher to wss://<this host>/voice\n');
});

const relay = createRelay({
  server,
  authMode,
  proximityRange: Number(process.env.ZMF_PROXIMITY_RANGE || 48),
  whisperRange: Number(process.env.ZMF_WHISPER_RANGE || 24),
});

server.listen(port, () => console.log(`ZMF Voice relay listening on :${port} (auth=${authMode})`));
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => relay.close().then(() => process.exit(0)));
