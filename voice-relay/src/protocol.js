'use strict';
// ZMF Voice protocol v1 — shared constants and binary framing.
//
// Control messages are JSON text frames ({ t: "<type>", ... }).
// Audio is binary:
//   client → relay: [0x01][flags u8][seq u16 BE][opus payload]
//   relay → client: [0x01][flags u8][seq u16 BE][speaker u16 BE][opus payload]
// flags bit 0 = whisper (reduced proximity range).

const PROTOCOL_VERSION = 1;
const AUDIO = 0x01;
const FLAG_WHISPER = 0x01;
const MAX_AUDIO_PAYLOAD = 1275; // largest legal Opus packet

function parseClientAudio(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 5 || buf[0] !== AUDIO) return null;
  const payload = buf.subarray(4);
  if (payload.length > MAX_AUDIO_PAYLOAD) return null;
  return { flags: buf[1], seq: buf.readUInt16BE(2), payload };
}

function encodeRelayAudio(speaker, flags, seq, payload) {
  const out = Buffer.allocUnsafe(6 + payload.length);
  out[0] = AUDIO;
  out[1] = flags & 0xff;
  out.writeUInt16BE(seq & 0xffff, 2);
  out.writeUInt16BE(speaker & 0xffff, 4);
  payload.copy(out, 6);
  return out;
}

module.exports = { PROTOCOL_VERSION, AUDIO, FLAG_WHISPER, MAX_AUDIO_PAYLOAD, parseClientAudio, encodeRelayAudio };
