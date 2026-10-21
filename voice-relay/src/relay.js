'use strict';
const crypto = require('crypto');
const { WebSocketServer } = require('ws');
const { PROTOCOL_VERSION, FLAG_WHISPER, parseClientAudio, encodeRelayAudio } = require('./protocol');
const { newNonce, verifyMojang } = require('./auth');
const { audible, relevant } = require('./routing');

const DEFAULTS = {
  proximityRange: 48,      // blocks
  whisperRange: 24,
  maxRoomNameLength: 32,
  maxFramesPerSecond: 60,  // 20 ms Opus frames → 50/s
  peerUpdateMs: 200,
  authMode: 'mojang',      // 'mojang' | 'none' (testing only)
  maxClients: 2000,
};

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 32);
}

/**
 * Creates the relay. Options: { server | port, ...DEFAULTS overrides, verify }
 * Returns { wss, close(), stats() }.
 */
function createRelay(options = {}) {
  const cfg = { ...DEFAULTS, ...options };
  const verify = options.verify || verifyMojang;
  const wss = new WebSocketServer({
    server: options.server,
    port: options.server ? undefined : options.port,
    maxPayload: 16 * 1024,
    perMessageDeflate: false,
  });

  const clients = new Map();  // slot -> client
  const rooms = new Map();    // id -> room
  let nextSlot = 1;

  function allocSlot() {
    for (let i = 0; i < 65535; i++) {
      const s = nextSlot;
      nextSlot = nextSlot >= 65535 ? 1 : nextSlot + 1;
      if (!clients.has(s)) return s;
    }
    return 0;
  }

  function send(c, msg) {
    if (c.ws.readyState === 1) c.ws.send(JSON.stringify(msg));
  }

  function roomInfo(r) {
    return {
      id: r.id, name: r.name, public: r.public, hasPassword: !!r.passwordHash, type: r.type,
      members: [...r.members].map((s) => clients.get(s)).filter(Boolean).map((m) => ({ id: m.slot, name: m.name })),
    };
  }

  function publicRooms() {
    return [...rooms.values()].filter((r) => r.public).map(roomInfo);
  }

  function broadcastRooms() {
    const list = publicRooms();
    for (const c of clients.values()) if (c.authed) send(c, { t: 'rooms', list });
  }

  function leaveRoom(c) {
    if (!c.room) return;
    const r = rooms.get(c.room);
    c.room = null;
    if (r) {
      r.members.delete(c.slot);
      if (r.members.size === 0) rooms.delete(r.id);
      else for (const s of r.members) { const m = clients.get(s); if (m) send(m, { t: 'room', room: roomInfo(r) }); }
    }
    send(c, { t: 'room', room: null });
    broadcastRooms();
  }

  function joinRoom(c, r) {
    leaveRoom(c);
    r.members.add(c.slot);
    c.room = r.id;
    for (const s of r.members) { const m = clients.get(s); if (m) send(m, { t: 'room', room: roomInfo(r) }); }
    broadcastRooms();
  }

  function handleControl(c, msg) {
    switch (msg.t) {
      case 'state': {
        const world = typeof msg.world === 'string' && msg.world.length <= 300 ? msg.world : null;
        const pos = Array.isArray(msg.pos) && msg.pos.length === 3 && msg.pos.every(Number.isFinite) ? msg.pos.map(Number) : null;
        c.world = world;
        c.pos = pos;
        c.yaw = Number.isFinite(msg.yaw) ? msg.yaw : 0;
        return;
      }
      case 'room.list':
        return send(c, { t: 'rooms', list: publicRooms() });
      case 'room.create': {
        const name = String(msg.name || '').trim().slice(0, cfg.maxRoomNameLength);
        if (!name) return send(c, { t: 'error', msg: 'Room name required' });
        const type = msg.type === 'open' ? 'open' : 'isolated';
        const salt = crypto.randomBytes(16);
        const password = typeof msg.password === 'string' && msg.password.length > 0 ? msg.password.slice(0, 64) : null;
        const r = {
          id: crypto.randomBytes(6).toString('hex'), name, type,
          public: msg.public !== false,
          salt, passwordHash: password ? hashPassword(password, salt) : null,
          members: new Set(), owner: c.slot,
        };
        rooms.set(r.id, r);
        joinRoom(c, r);
        // Private rooms are joined by id (share code); they never appear in lists.
        return send(c, { t: 'room.created', id: r.id });
      }
      case 'room.join': {
        const r = rooms.get(String(msg.id || ''));
        if (!r) return send(c, { t: 'error', msg: 'Room not found' });
        if (r.passwordHash) {
          const given = hashPassword(String(msg.password || ''), r.salt);
          if (!crypto.timingSafeEqual(given, r.passwordHash)) return send(c, { t: 'error', msg: 'Wrong room password' });
        }
        return joinRoom(c, r);
      }
      case 'room.leave':
        return leaveRoom(c);
      case 'ping':
        return send(c, { t: 'pong', ts: msg.ts });
      default:
        return send(c, { t: 'error', msg: `Unknown message ${msg.t}` });
    }
  }

  function handleAudio(c, data) {
    const frame = parseClientAudio(data);
    if (!frame) return;
    const now = Date.now();
    if (now - c.rateWindow >= 1000) { c.rateWindow = now; c.rateCount = 0; }
    if (++c.rateCount > cfg.maxFramesPerSecond) return;
    c.lastTalk = now;
    const whisper = (frame.flags & FLAG_WHISPER) !== 0;
    let out = null;
    for (const l of clients.values()) {
      if (!l.authed || l.deafened || !audible(c, l, rooms, cfg, whisper)) continue;
      out = out || encodeRelayAudio(c.slot, frame.flags, frame.seq, frame.payload);
      if (l.ws.readyState === 1 && l.ws.bufferedAmount < 256 * 1024) l.ws.send(out, { binary: true });
    }
  }

  wss.on('connection', (ws, req) => {
    if (clients.size >= cfg.maxClients) { ws.close(1013, 'Relay full'); return; }
    const slot = allocSlot();
    const c = {
      ws, slot, authed: false, nonce: newNonce(), name: null, uuid: null,
      world: null, pos: null, yaw: 0, room: null, deafened: false,
      rateWindow: 0, rateCount: 0, lastTalk: 0, ip: req.socket.remoteAddress,
    };
    clients.set(slot, c);
    send(c, { t: 'challenge', v: PROTOCOL_VERSION, nonce: c.nonce, auth: cfg.authMode });

    ws.on('message', async (data, isBinary) => {
      if (isBinary) { if (c.authed) handleAudio(c, data); return; }
      let msg;
      try { msg = JSON.parse(data.toString()); } catch { return; }
      if (!msg || typeof msg.t !== 'string') return;
      if (!c.authed) {
        if (msg.t !== 'auth' || c.authPending) return;
        c.authPending = true;
        const name = String(msg.name || '').slice(0, 16);
        let identity = null;
        try {
          identity = cfg.authMode === 'none'
            ? { name, uuid: String(msg.uuid || '').replace(/-/g, '').toLowerCase() }
            : await verify(name, c.nonce);
        } catch (e) {
          identity = null;
        }
        c.authPending = false;
        if (!identity) { send(c, { t: 'error', msg: 'Minecraft account verification failed', fatal: true }); ws.close(4001, 'auth'); return; }
        // One connection per account: a new login replaces the old one.
        for (const other of clients.values()) {
          if (other !== c && other.authed && other.uuid === identity.uuid) other.ws.close(4002, 'Logged in elsewhere');
        }
        c.name = identity.name;
        c.uuid = identity.uuid;
        c.authed = true;
        send(c, { t: 'welcome', id: slot, name: c.name, uuid: c.uuid,
                  config: { proximityRange: cfg.proximityRange, whisperRange: cfg.whisperRange, frameMs: 20 },
                  rooms: publicRooms() });
        return;
      }
      if (msg.t === 'deafen') { c.deafened = !!msg.on; return; }
      handleControl(c, msg);
    });

    ws.on('close', () => {
      leaveRoom(c);
      clients.delete(slot);
    });
    ws.on('error', () => {});
  });

  // Peer list updates: names, positions, rooms and who is talking.
  const timer = setInterval(() => {
    const now = Date.now();
    for (const c of clients.values()) {
      if (!c.authed) continue;
      const list = [];
      for (const o of clients.values()) {
        if (!o.authed || !relevant(c, o, rooms, cfg)) continue;
        list.push({ id: o.slot, name: o.name, uuid: o.uuid, pos: o.pos, yaw: o.yaw, sameRoom: !!c.room && c.room === o.room,
                    talking: now - o.lastTalk < 300 });
      }
      send(c, { t: 'peers', list });
    }
  }, cfg.peerUpdateMs);

  return {
    wss,
    stats: () => ({ clients: clients.size, rooms: rooms.size }),
    close: () => new Promise((resolve) => { clearInterval(timer); for (const c of clients.values()) c.ws.terminate(); wss.close(() => resolve()); }),
  };
}

module.exports = { createRelay, DEFAULTS };
