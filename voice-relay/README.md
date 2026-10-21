# ZMF Voice relay

The server that carries ZMF Voice audio between ZMF Java Launcher clients.
It is independent of the Minecraft server you play on: any server, any
version — only people using ZMF connected to the same relay hear each other.

* **Identity:** verified with Mojang's session server (`hasJoined`), the same
  check Minecraft servers use. The relay never receives access tokens.
* **Proximity:** clients report `<server address>|<dimension>` and position;
  audio is forwarded only to players in the same world within 48 blocks
  (24 when whispering). Clients spatialize it (3D, distance attenuation).
* **Rooms:** public (listed) or private (join by code), optional password,
  *isolated* (only members hear each other) or *open* (members anywhere +
  normal proximity).
* **Transport:** WebSocket (TLS via your host), 20 ms Opus frames.

## Run

```sh
npm ci && npm start            # listens on $PORT (default 24470)
npm test                       # unit + end-to-end tests
```

Environment: `PORT`, `ZMF_PROXIMITY_RANGE` (48), `ZMF_WHISPER_RANGE` (24),
`ZMF_AUTH=none` (testing only — disables identity verification).

## Deploy (no Mac needed)

A container image is built by GitHub Actions and pushed to
`ghcr.io/<owner>/zmf-voice-relay:latest` (workflow `Voice relay`).
Deploy it on any host that supports WebSockets and gives you HTTPS, e.g.
Render, Railway, Fly.io or a VPS behind Caddy. Then in the app:
**Voice › Relay URL** = `wss://your-host/voice`, or set the repository
variable `ZMF_VOICE_RELAY_URL` before building so it is the default.

The relay keeps everything in memory (rooms vanish when empty); a single
small instance handles hundreds of speakers.
