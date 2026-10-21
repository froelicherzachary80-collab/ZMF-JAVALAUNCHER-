'use strict';
// Who hears whom. Pure functions so they can be unit tested.
//
// Rules (a "world" is the Minecraft server address + dimension reported by the
// client; rooms are relay-side groups that work in any world):
//   * Speaker and listener in the same room            → audible (no distance limit).
//   * Either one is in an *isolated* room (and not both in it) → not audible.
//   * Otherwise proximity: same non-null world and distance ≤ range,
//     where range is the whisper range if the frame is a whisper.

function distance(a, b) {
  const dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

function audible(speaker, listener, rooms, cfg, whisper) {
  if (speaker === listener) return false;
  const sRoom = speaker.room ? rooms.get(speaker.room) : null;
  const lRoom = listener.room ? rooms.get(listener.room) : null;
  if (sRoom && lRoom && sRoom === lRoom) return true;
  if ((sRoom && sRoom.type === 'isolated') || (lRoom && lRoom.type === 'isolated')) return false;
  if (!speaker.world || speaker.world !== listener.world || !speaker.pos || !listener.pos) return false;
  const range = whisper ? cfg.whisperRange : cfg.proximityRange;
  return distance(speaker.pos, listener.pos) <= range;
}

/// Peers a client should know about (for names, positions, talking indicators).
function relevant(self, other, rooms, cfg) {
  if (self === other) return false;
  if (self.room && self.room === other.room) return true;
  if (!self.world || self.world !== other.world || !self.pos || !other.pos) return false;
  return distance(self.pos, other.pos) <= cfg.proximityRange * 1.5;
}

module.exports = { audible, relevant, distance };
