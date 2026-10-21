'use strict';
// Identity verification using the same mechanism Minecraft servers use:
// the client calls sessionserver.mojang.com/session/minecraft/join with its
// own access token and a serverId we chose; we then ask hasJoined whether
// that username really did so. The relay never sees the access token.

const crypto = require('crypto');

const SESSION_SERVER = process.env.ZMF_SESSION_SERVER || 'https://sessionserver.mojang.com';

function newNonce() {
  return crypto.randomBytes(20).toString('hex'); // 40 hex chars, valid serverId
}

async function verifyMojang(username, serverId, fetchImpl = fetch) {
  const url = `${SESSION_SERVER}/session/minecraft/hasJoined?username=${encodeURIComponent(username)}&serverId=${encodeURIComponent(serverId)}`;
  const res = await fetchImpl(url, { headers: { 'User-Agent': 'zmf-voice-relay' } });
  if (res.status !== 200) return null; // 204 = not joined
  const body = await res.json();
  if (!body || typeof body.id !== 'string' || typeof body.name !== 'string') return null;
  return { uuid: body.id.replace(/-/g, '').toLowerCase(), name: body.name };
}

module.exports = { newNonce, verifyMojang };
