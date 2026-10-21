'use strict';
const test = require('node:test');
const assert = require('node:assert');
const WebSocket = require('ws');
const { createRelay } = require('../src/relay');
const { audible } = require('../src/routing');
const { verifyMojang } = require('../src/auth');

const cfg = { proximityRange: 48, whisperRange: 24 };

test('routing rules', () => {
  const rooms = new Map([['r1', { type: 'isolated' }], ['r2', { type: 'open' }]]);
  const a = { world: 'mc.example.org:25565|minecraft:overworld', pos: [0, 64, 0] };
  const b = { world: a.world, pos: [30, 64, 0] };
  const far = { world: a.world, pos: [100, 64, 0] };
  const otherWorld = { world: 'other.net:25565|minecraft:overworld', pos: [1, 64, 0] };
  assert.equal(audible(a, b, rooms, cfg, false), true);
  assert.equal(audible(a, b, rooms, cfg, true), false, 'whisper range 24 < 30');
  assert.equal(audible(a, far, rooms, cfg, false), false);
  assert.equal(audible(a, otherWorld, rooms, cfg, false), false);
  assert.equal(audible({ ...a, room: 'r1' }, { ...far, room: 'r1' }, rooms, cfg, false), true, 'room ignores distance');
  assert.equal(audible({ ...a, room: 'r1' }, b, rooms, cfg, false), false, 'isolated room is not heard nearby');
  assert.equal(audible({ ...a, room: 'r2' }, b, rooms, cfg, false), true, 'open room still heard nearby');
  assert.equal(audible({ world: null, pos: null, room: 'r2' }, { world: null, pos: null, room: 'r2' }, rooms, cfg, false), true, 'rooms work without a world');
});

test('mojang hasJoined verification', async () => {
  const ok = await verifyMojang('Steve', 'abc', async (url) => {
    assert.match(url, /hasJoined\?username=Steve&serverId=abc$/);
    return { status: 200, json: async () => ({ id: '069a79f444e94726a5befca90e38aaf5', name: 'Steve' }) };
  });
  assert.deepEqual(ok, { uuid: '069a79f444e94726a5befca90e38aaf5', name: 'Steve' });
  assert.equal(await verifyMojang('Steve', 'abc', async () => ({ status: 204 })), null);
});

function client(port, name, verifyOK = true) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/voice`);
    const inbox = [];
    const audio = [];
    let waiters = [];
    ws.on('message', (data, binary) => {
      if (binary) { audio.push(data); return; }
      const m = JSON.parse(data.toString());
      inbox.push(m);
      waiters = waiters.filter((w) => (w.pred(m) ? (w.resolve(m), false) : true));
      if (m.t === 'challenge') ws.send(JSON.stringify({ t: 'auth', name, uuid: name + '-uuid' }));
      if (m.t === 'welcome') resolve(api);
      if (m.t === 'error' && m.fatal) resolve(api);
    });
    ws.on('error', reject);
    const api = {
      ws, inbox, audio,
      sendJSON: (o) => ws.send(JSON.stringify(o)),
      next: (pred) => new Promise((res) => {
        const hit = inbox.find(pred);
        if (hit) { inbox.splice(inbox.indexOf(hit), 1); return res(hit); }
        waiters.push({ pred, resolve: res });
      }),
      sendAudio: (flags, payload) => ws.send(Buffer.concat([Buffer.from([1, flags, 0, 7]), payload]), { binary: true }),
    };
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('end to end: auth, proximity, whisper, private rooms', async () => {
  const relay = createRelay({ port: 0, peerUpdateMs: 50, verify: async (name, nonce) => (name === 'Mallory' ? null : { name, uuid: name.toLowerCase() + 'uuid' }) });
  await new Promise((r) => relay.wss.on('listening', r));
  const port = relay.wss.address().port;
  try {
    const alex = await client(port, 'Alex');
    const steve = await client(port, 'Steve');
    const zoe = await client(port, 'Zoe');
    const mallory = await client(port, 'Mallory');
    assert.ok(mallory.inbox.some((m) => m.t === 'error' && m.fatal), 'unverified account rejected');

    const world = 'play.example.net:25565|minecraft:overworld';
    alex.sendJSON({ t: 'state', world, pos: [0, 70, 0], yaw: 0 });
    steve.sendJSON({ t: 'state', world, pos: [10, 70, 0], yaw: 90 });
    zoe.sendJSON({ t: 'state', world, pos: [500, 70, 0], yaw: 0 });
    await sleep(80);

    alex.sendAudio(0, Buffer.from('hello'));
    await sleep(80);
    assert.equal(steve.audio.length, 1, 'nearby player hears');
    assert.equal(zoe.audio.length, 0, 'far player does not');
    const frame = steve.audio[0];
    assert.equal(frame[0], 1);
    assert.equal(frame.readUInt16BE(2), 7, 'sequence preserved');
    assert.equal(frame.subarray(6).toString(), 'hello');
    const peers = await steve.next((m) => m.t === 'peers' && m.list.some((p) => p.name === 'Alex'));
    const alexPeer = peers.list.find((p) => p.name === 'Alex');
    assert.equal(frame.readUInt16BE(4), alexPeer.id, 'speaker id matches peer list');
    assert.ok(!peers.list.some((p) => p.name === 'Zoe'), 'far peers not listed');

    // Private, password-protected isolated room between Alex and Zoe (500 blocks apart).
    alex.sendJSON({ t: 'room.create', name: 'Squad', public: false, password: 'pw', type: 'isolated' });
    const created = await alex.next((m) => m.t === 'room.created');
    const rooms = await steve.next((m) => m.t === 'rooms');
    assert.ok(!rooms.list.some((r) => r.name === 'Squad'), 'private room not listed');
    zoe.sendJSON({ t: 'room.join', id: created.id, password: 'nope' });
    await zoe.next((m) => m.t === 'error' && /password/.test(m.msg));
    zoe.sendJSON({ t: 'room.join', id: created.id, password: 'pw' });
    await zoe.next((m) => m.t === 'room' && m.room && m.room.members.length === 2);

    steve.audio.length = 0;
    alex.sendAudio(0, Buffer.from('squad'));
    await sleep(80);
    assert.equal(zoe.audio.length, 1, 'room member hears across any distance');
    assert.equal(steve.audio.length, 0, 'isolated room is not heard by nearby non-members');

    alex.sendJSON({ t: 'room.leave' });
    await alex.next((m) => m.t === 'room' && m.room === null);
    alex.sendAudio(1, Buffer.from('psst'));
    await sleep(80);
    assert.equal(steve.audio.length, 1, 'whisper within 24 blocks');
    steve.sendJSON({ t: 'state', world, pos: [30, 70, 0], yaw: 0 });
    await sleep(30);
    alex.sendAudio(1, Buffer.from('psst'));
    await sleep(80);
    assert.equal(steve.audio.length, 1, 'whisper beyond 24 blocks not delivered');

    for (const c of [alex, steve, zoe]) c.ws.close();
  } finally {
    await relay.close();
  }
});
