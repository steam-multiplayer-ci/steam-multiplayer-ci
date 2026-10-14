'use strict';
// Two-player check with Valve's public test app Spacewar (app ID 480):
//   role 0 creates a lobby tagged with SMCI_RUN and waits for a connection;
//   role 1 finds that lobby, joins, connects to the owner over Steam networking;
//   both send one message and wait for the other side's. Result goes to result.json.
// Needs steamworks_sdk/redistributable_bin/win64/steam_api64.dll from your own Steamworks SDK.
const fs = require('fs');
const crypto = require('crypto');
const { SteamworksSDK } = require('steamworks-ffi-node');

const RUN = process.env.SMCI_RUN || 'local-' + Date.now();
const ROLE = Number(process.env.SMCI_ROLE || 0);
const LIMIT_MS = Number(process.env.EXAMPLE_TIMEOUT_MS || 8 * 60 * 1000);
const t0 = Date.now();
const result = { role: ROLE, run: RUN, pass: false, steps: {} };
const short = (id) => crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 8);
const step = (k, v) => { result.steps[k] = v; console.log('[example] ' + k + ' = ' + JSON.stringify(v) + ' at ' + (Date.now() - t0) + ' ms'); };
const done = (pass, why) => {
  result.pass = pass;
  if (why) result.reason = why;
  result.ms = Date.now() - t0;
  fs.writeFileSync('result.json', JSON.stringify(result, null, 2));
  console.log('[example] ' + (pass ? 'PASS' : 'FAIL') + (why ? ' (' + why + ')' : ''));
  process.exit(pass ? 0 : 1);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (fn, ms, every = 100) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = await fn(); if (v) return v; await sleep(every); }
  return null;
};

fs.writeFileSync('steam_appid.txt', '480');
const steam = SteamworksSDK.getInstance();
if (!steam.init({ appId: 480 })) done(false, 'Steam init failed');
const me = (steam.getStatus() || {}).steamId;
step('init', { me: short(me) });

const pump = setInterval(() => {
  try { steam.runCallbacks(); } catch (e) {}
  try { steam.networkingSockets.runCallbacks(); } catch (e) {}
}, 33);
setTimeout(() => done(false, 'time limit'), LIMIT_MS).unref();

let conn = null;
let connected = false;
const inbox = [];
steam.networkingSockets.onConnectionRequest((req) => {
  const r = steam.networkingSockets.acceptConnection(req.connection);
  step('accept', { result: r });
  conn = req.connection;
});
steam.networkingSockets.onConnectionStateChange((c) => {
  if (c.newState === 3) { connected = true; conn = c.connection; }
  if (c.newState === 4 || c.newState === 5) step('closed', { state: c.newState });
});
const poll = () => {
  if (conn == null) return;
  for (const m of steam.networkingSockets.receiveMessages(conn, 16) || []) inbox.push(String(m.data));
};

(async () => {
  steam.networkingUtils.initRelayNetworkAccess();
  const relay = await until(() => {
    const s = steam.networkingUtils.getRelayNetworkStatus();
    return s && s.availability === 100 ? s : null;   // 100 = k_ESteamNetworkingAvailability_Current
  }, 120000, 500);
  const rs = steam.networkingUtils.getRelayNetworkStatus() || {};
  step('relay', { ready: !!relay, status: rs.availabilityName, pops: steam.networkingUtils.getPOPCount() });

  let lobbyId;
  if (ROLE === 0) {
    steam.networkingSockets.createListenSocketP2P(0);
    const res = await steam.matchmaking.createLobby(2 /* public */, 2);
    if (!res || !res.success) done(false, 'createLobby failed: ' + (res && res.error));
    lobbyId = String(res.lobbyId);
    steam.matchmaking.setLobbyData(lobbyId, 'smci_run', RUN);
    step('lobby', { created: true });
    await until(() => connected, LIMIT_MS, 100);
  } else {
    lobbyId = await until(async () => {
      steam.matchmaking.addRequestLobbyListStringFilter('smci_run', RUN, 0);
      steam.matchmaking.addRequestLobbyListDistanceFilter(3 /* worldwide */);
      const r = await steam.matchmaking.requestLobbyList();
      return r && r.success && r.lobbies && r.lobbies.length ? String(r.lobbies[0]) : null;
    }, LIMIT_MS, 3000);
    if (!lobbyId) done(false, 'lobby not found');
    step('lobby', { found: true });
    const j = await steam.matchmaking.joinLobby(lobbyId);
    if (!j || !j.success) done(false, 'joinLobby failed');
    const owner = steam.matchmaking.getLobbyOwner(lobbyId);
    step('join', { owner: short(owner) });
    conn = steam.networkingSockets.connectP2P(String(owner), 0);
    await until(() => connected, 120000, 100);
  }
  if (!connected) done(false, 'not connected');
  const info = steam.networkingSockets.getConnectionInfo(conn) || {};
  step('connected', { viaRelay: !!info.popIdRelay });

  steam.networkingSockets.sendReliable(conn, 'hello from ' + ROLE + ' ' + RUN);
  const got = await until(() => { poll(); return inbox.find((s) => s.startsWith('hello from ') && s.endsWith(' ' + RUN)); }, 60000, 50);
  if (!got) done(false, 'no message from the other side');
  step('message', { received: true });

  await sleep(3000);   // let the other side read ours before the connection closes
  try { steam.networkingSockets.closeConnection(conn, 0, 'done', true); } catch (e) {}
  try { steam.matchmaking.leaveLobby(lobbyId); } catch (e) {}
  clearInterval(pump);
  done(true);
})().catch((e) => done(false, 'error: ' + e.message));
