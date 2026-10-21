# ZMF Voice

Proximity voice chat plus voice rooms, built into the ZMF client. It works
in every Minecraft world or server and needs **nothing installed on the
Minecraft server**. Only players using ZMF and connected to the same voice
relay can hear each other; everyone else on the server hears nothing.

ZMF Voice is an original implementation inspired by the feature set
players know from proximity-voice mods (proximity, whisper, groups,
push-to-talk, per-player volume). It does not reuse any mod's code, name or
assets, and it cannot talk to servers running such mods; it uses its own
relay instead.

## How it works

```
  game (any version) ──► ZMF telemetry thread (Java, reflection + mappings)
                              │ position, yaw, "<server>|<dimension>" ~10 Hz
                              ▼ JNI
  iOS app: VoiceClient ──WSS──► ZMF Voice relay ◄──WSS── other ZMF players
     mic → voice processing (AEC/NS) → Opus 20 ms ─┘        │
     ◄── Opus ── HRTF 3D playback (AVAudioEnvironmentNode) ◄─┘
```

* **Identity:** before joining, the app calls Mojang's session `join`
  endpoint with your own token; the relay checks `hasJoined` (exactly what
  Minecraft servers do). The relay never sees your token, and nobody can
  impersonate your username.
* **Proximity:** the relay forwards your audio only to players in the same
  world (same server address and dimension) within 48 blocks; whisper is 24
  blocks. Volume falls off with distance and is positioned in 3D around you.
* **Rooms:** create public (listed) or private (join by code) rooms, with an
  optional password. *Only room members* hears just the room; *room +
  nearby* also keeps normal proximity. Rooms work across different servers,
  in singleplayer, or from the launcher with no game running.
* **Controls:** push to talk or voice activation (adjustable threshold), mic
  gain, output volume, mute, deafen, whisper, per-player volume/mute, an
  in-game Talk button (HUD editor) and a "who's talking" overlay.

## Version coverage

| Feature | Versions |
|---|---|
| Rooms | every version (no game data needed) |
| Proximity | 1.14.4+ vanilla (Mojang publishes mappings), Fabric/Quilt on those versions (intermediary), and unobfuscated releases |
| Proximity on 1.14.3 and older | not available (no official mappings) — use rooms |

Players must type the **same server address** to share proximity (for example
`play.example.net` and `play.example.net:25565` match; `example.net` and
`play.example.net` do not).

## Hosting the relay

See [voice-relay/README.md](../voice-relay/README.md). Deploy the container
(`ghcr.io/<owner>/zmf-voice-relay`) or `voice-relay/render.yaml`, then set
the URL in the app (Multiplayer › Voice) or as repository variable
`ZMF_VOICE_RELAY_URL` before building. Everyone in a group must use the same
relay.

## Limits

* Positions are reported by clients; a modified client could lie about its
  position (identity cannot be faked).
* Voice needs the game running through ZMF for proximity; rooms do not.
* Audio is relayed (not peer-to-peer), so latency is network + ~40 ms.
* LAN hosts and guests report different server keys; use a room for LAN.
