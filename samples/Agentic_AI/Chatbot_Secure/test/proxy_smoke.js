/**
 * Proxy-mode smoke test (no Flogo needed).
 *
 * Starts a mock upstream WebSocket server that records the handshake, starts
 * this chatbot with ALLOWED_UPSTREAMS pointing at the mock, and checks the
 * sign-in, cookie, Origin, allow-list and header-injection behaviour.
 *
 * Run: npm test
 */

const assert = require('assert');
const crypto = require('crypto');
const http = require('http');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');

const ROOT = path.join(__dirname, '..');
const MOCK_PORT = parseInt(process.env.MOCK_UPSTREAM_PORT || '9979', 10);

// ---------------------------------------------------------------- helpers

const b64u = obj => Buffer.from(JSON.stringify(obj)).toString('base64url');
function makeJwt(claims) {
  return `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u(claims)}.${crypto.randomBytes(32).toString('base64url')}`;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

function portFree(port) {
  return new Promise(resolve => {
    const srv = net.createServer();
    srv.once('error', () => resolve(false));
    srv.listen(port, '127.0.0.1', () => srv.close(() => resolve(true)));
  });
}

function request(port, method, urlPath, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers }, res => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', c => (data += c));
      res.on('end', () => {
        let json = null;
        try {
          json = JSON.parse(data);
        } catch (e) {
          /* not json */
        }
        resolve({ status: res.statusCode, headers: res.headers, text: data, json });
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

/** Resolve { ws } when open, or { status } when the upgrade is refused. */
function wsConnect(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers });
    ws.once('open', () => resolve({ ws }));
    ws.once('unexpected-response', (req, res) => {
      res.resume();
      req.destroy();
      resolve({ status: res.statusCode });
    });
    ws.once('error', err => reject(err));
  });
}

const nextMessage = (ws, ms = 3000) =>
  new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timed out waiting for a message')), ms);
    ws.once('message', (data, isBinary) => {
      clearTimeout(t);
      resolve(isBinary ? data : data.toString());
    });
  });

const nextClose = (ws, ms = 3000) =>
  new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.CLOSED) return resolve({ code: null });
    const t = setTimeout(() => reject(new Error('timed out waiting for close')), ms);
    ws.once('close', (code, reason) => {
      clearTimeout(t);
      resolve({ code, reason: reason.toString() });
    });
  });

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------- mock upstream

function startMockUpstream(port) {
  const handshakes = [];
  const connections = [];
  const server = http.createServer((req, res) => res.writeHead(404).end());
  const wss = new WebSocket.WebSocketServer({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    handshakes.push({ url: req.url, headers: { ...req.headers } });
    if (req.url === '/reject') {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, ws => {
      const conn = { ws, closed: null };
      connections.push(conn);
      ws.on('message', data => {
        const text = data.toString();
        if (text === 'server-close') return ws.close(4000, 'bye');
        ws.send(`echo:${text}`);
      });
      ws.on('close', (code, reason) => (conn.closed = { code, reason: reason.toString() }));
    });
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () =>
      resolve({ port: server.address().port, handshakes, connections, close: () => server.close() })
    );
  });
}

// ---------------------------------------------------------------- test runner

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`  PASS  ${name}`);
  } catch (err) {
    results.push({ name, ok: false });
    console.log(`  FAIL  ${name}\n        ${err && err.message}`);
  }
}

async function main() {
  const mockPort = (await portFree(MOCK_PORT)) ? MOCK_PORT : 0;
  const mock = await startMockUpstream(mockPort);
  const deadPort = await freePort();
  const appPort = await freePort();

  const upstream = `ws://127.0.0.1:${mock.port}/retailbanking`;
  const rejecting = `ws://127.0.0.1:${mock.port}/reject`;
  const dead = `ws://127.0.0.1:${deadPort}/retailbanking`;
  const origin = `http://127.0.0.1:${appPort}`;
  const proxyUrl = target => `ws://127.0.0.1:${appPort}/proxy?target=${encodeURIComponent(target)}`;

  console.log(`mock upstream: ${upstream}`);
  console.log(`chatbot:       ${origin}\n`);

  let logs = '';
  const child = spawn(process.execPath, ['server.js'], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(appPort),
      HOST: '127.0.0.1',
      ALLOWED_UPSTREAMS: [upstream, rejecting, dead].join(','),
      ALLOWED_ORIGINS: '',
      WS_URL: '',
      DIRECT_MODE: 'false',
      COOKIE_SECURE: 'auto',
      TRUST_PROXY: 'false',
      SESSION_TTL_MINUTES: '480'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  child.stdout.on('data', d => (logs += d));
  child.stderr.on('data', d => (logs += d));

  // wait for the server
  for (let i = 0; i < 100; i++) {
    try {
      if ((await request(appPort, 'GET', '/client-config')).status === 200) break;
    } catch (e) {
      /* not up yet */
    }
    await sleep(100);
  }

  const now = Math.floor(Date.now() / 1000);
  const token = makeJwt({
    iss: 'kestrel-bank-idp',
    aud: ['retail-banking-mcp'],
    sub: 'CUST-2026-00107',
    name: 'Smoke Test User',
    scp: ['profile:read', 'accounts:read'],
    iat: now,
    exp: now + 3600
  });
  const signature = token.split('.')[2];
  let cookie = null;

  try {
    await check('client-config lists the allow-list and direct mode is off', async () => {
      const r = await request(appPort, 'GET', '/client-config');
      assert.strictEqual(r.status, 200);
      assert.deepStrictEqual(r.json.allowedUpstreams, [upstream, rejecting, dead]);
      assert.strictEqual(r.json.directMode, false);
    });

    await check('(a) WS upgrade without a session cookie -> 401', async () => {
      const r = await wsConnect(proxyUrl(upstream), { Origin: origin });
      assert.strictEqual(r.status, 401);
    });

    await check('sign-in rejects a cross-origin POST (403), non-JSON (415), non-JWT and expired tokens (400)', async () => {
      const body = JSON.stringify({ token });
      let r = await request(appPort, 'POST', '/auth/session', {
        headers: { 'Content-Type': 'application/json', Origin: 'http://evil.example' },
        body
      });
      assert.strictEqual(r.status, 403);
      r = await request(appPort, 'POST', '/auth/session', { headers: { 'Content-Type': 'text/plain' }, body });
      assert.strictEqual(r.status, 415);
      r = await request(appPort, 'POST', '/auth/session', {
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: 'not-a-jwt' })
      });
      assert.strictEqual(r.status, 400);
      r = await request(appPort, 'POST', '/auth/session', {
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: makeJwt({ sub: 'x', exp: now - 60 }) })
      });
      assert.strictEqual(r.status, 400);
      assert.ok(!r.headers['set-cookie'], 'no cookie on failed sign-in');
    });

    await check('(b1) POST /auth/session sets an HttpOnly SameSite=Strict Path=/ cookie and never echoes the token', async () => {
      const r = await request(appPort, 'POST', '/auth/session', {
        headers: { 'Content-Type': 'application/json', Origin: origin },
        body: JSON.stringify({ token })
      });
      assert.strictEqual(r.status, 200, r.text);
      const setCookie = (r.headers['set-cookie'] || [])[0] || '';
      assert.match(setCookie, /^cbs_sid=[A-Za-z0-9_-]{40,};/);
      assert.match(setCookie, /HttpOnly/i);
      assert.match(setCookie, /SameSite=Strict/i);
      assert.match(setCookie, /Path=\//);
      assert.doesNotMatch(setCookie, /Secure/i, 'plain HTTP should not set Secure in auto mode');
      assert.ok(!r.text.includes(signature) && !r.text.includes(token), 'response must not contain the token');
      assert.strictEqual(r.json.sub, 'CUST-2026-00107');
      cookie = setCookie.split(';')[0];
    });

    await check('(g) GET /auth/session shows sub/name/scp/exp without the raw token', async () => {
      const r = await request(appPort, 'GET', '/auth/session', { headers: { Cookie: cookie } });
      assert.strictEqual(r.status, 200);
      assert.strictEqual(r.json.signedIn, true);
      assert.strictEqual(r.json.sub, 'CUST-2026-00107');
      assert.strictEqual(r.json.name, 'Smoke Test User');
      assert.deepStrictEqual(r.json.scp, ['profile:read', 'accounts:read']);
      assert.strictEqual(r.json.exp, now + 3600);
      assert.ok(!r.text.includes(signature), 'status must not contain the token');
      assert.match(r.headers['cache-control'] || '', /no-store/);
    });

    let live;
    await check('(b2) WS with cookie -> upstream receives Authorization: Bearer <exact token>', async () => {
      const before = mock.handshakes.length;
      const r = await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: cookie });
      assert.ok(r.ws, `expected open, got ${r.status}`);
      live = r.ws;
      const hs = mock.handshakes[before];
      assert.ok(hs, 'upstream saw no handshake');
      assert.strictEqual(hs.headers.authorization, `Bearer ${token}`);
      assert.ok(!hs.headers.cookie, 'browser cookie must not be forwarded upstream');
    });

    await check('(b3) messages round-trip both ways', async () => {
      const payload = JSON.stringify({ message: 'What is my balance?' });
      live.send(payload);
      assert.strictEqual(await nextMessage(live), `echo:${payload}`);
      live.send('second');
      assert.strictEqual(await nextMessage(live), 'echo:second');
    });

    await check('(d) upstream request URL is exactly the allowed path (no token, no query)', async () => {
      for (const hs of mock.handshakes) {
        assert.ok(!hs.url.includes(signature) && !hs.url.includes('token'), `URL leaked: ${hs.url}`);
      }
      assert.strictEqual(mock.handshakes[mock.handshakes.length - 1].url, '/retailbanking');
    });

    await check('browser close propagates upstream', async () => {
      const conn = mock.connections[mock.connections.length - 1];
      live.close(1000, 'done');
      await nextClose(live);
      for (let i = 0; i < 30 && !conn.closed; i++) await sleep(50);
      assert.ok(conn.closed, 'upstream connection was not closed');
      assert.strictEqual(conn.closed.code, 1000);
    });

    await check('upstream close propagates to the browser (code + reason)', async () => {
      const { ws } = await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: cookie });
      const closed = nextClose(ws);
      ws.send('server-close');
      const c = await closed;
      assert.strictEqual(c.code, 4000);
      assert.strictEqual(c.reason, 'bye');
    });

    await check('one upstream connection per browser connection (distinct handshake keys)', async () => {
      const before = mock.handshakes.length;
      const a = (await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: cookie })).ws;
      const b = (await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: cookie })).ws;
      assert.strictEqual(mock.handshakes.length, before + 2);
      const [k1, k2] = mock.handshakes.slice(before).map(h => h.headers['sec-websocket-key']);
      assert.ok(k1 && k2 && k1 !== k2);
      a.send('A');
      b.send('B');
      assert.strictEqual(await nextMessage(a), 'echo:A');
      assert.strictEqual(await nextMessage(b), 'echo:B');
      a.close();
      b.close();
      await Promise.all([nextClose(a), nextClose(b)]);
    });

    await check('(c) target not on the allow-list -> 403 (also near-misses and missing target)', async () => {
      const before = mock.handshakes.length;
      for (const url of [
        proxyUrl(`ws://127.0.0.1:${mock.port}/other`),
        proxyUrl(`${upstream}?x=1`),
        proxyUrl(`${upstream}/`),
        proxyUrl('ws://evil.example/retailbanking'),
        `ws://127.0.0.1:${appPort}/proxy`
      ]) {
        const r = await wsConnect(url, { Origin: origin, Cookie: cookie });
        assert.strictEqual(r.status, 403, url);
      }
      assert.strictEqual(mock.handshakes.length, before, 'no upstream connection should be attempted');
    });

    await check('(f) wrong or missing Origin -> 403 even with a valid cookie', async () => {
      let r = await wsConnect(proxyUrl(upstream), { Origin: 'http://evil.example', Cookie: cookie });
      assert.strictEqual(r.status, 403);
      r = await wsConnect(proxyUrl(upstream), { Origin: `http://localhost:${appPort + 1}`, Cookie: cookie });
      assert.strictEqual(r.status, 403);
      r = await wsConnect(proxyUrl(upstream), { Cookie: cookie });
      assert.strictEqual(r.status, 403);
    });

    await check('unknown session cookie -> 401; non-proxy path -> 404', async () => {
      let r = await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: 'cbs_sid=forged-session-id' });
      assert.strictEqual(r.status, 401);
      r = await wsConnect(`ws://127.0.0.1:${appPort}/other`, { Origin: origin, Cookie: cookie });
      assert.strictEqual(r.status, 404);
    });

    await check('upstream refusing the handshake or unreachable -> 502', async () => {
      let r = await wsConnect(proxyUrl(rejecting), { Origin: origin, Cookie: cookie });
      assert.strictEqual(r.status, 502);
      r = await wsConnect(proxyUrl(dead), { Origin: origin, Cookie: cookie });
      assert.strictEqual(r.status, 502);
    });

    await check('(e) DELETE /auth/session closes live connections and the next upgrade is rejected', async () => {
      const { ws } = await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: cookie });
      const conn = mock.connections[mock.connections.length - 1];
      const closed = nextClose(ws);
      const r = await request(appPort, 'DELETE', '/auth/session', { headers: { Cookie: cookie, Origin: origin } });
      assert.strictEqual(r.status, 200);
      assert.match((r.headers['set-cookie'] || [])[0] || '', /cbs_sid=;.*Expires=Thu, 01 Jan 1970/);
      assert.strictEqual((await closed).code, 1008);
      for (let i = 0; i < 30 && !conn.closed; i++) await sleep(50);
      assert.ok(conn.closed, 'upstream connection was not closed on sign-out');
      const again = await wsConnect(proxyUrl(upstream), { Origin: origin, Cookie: cookie });
      assert.strictEqual(again.status, 401);
      const status = await request(appPort, 'GET', '/auth/session', { headers: { Cookie: cookie } });
      assert.strictEqual(status.json.signedIn, false);
    });

    await check('server logs never contain the token or the full session id', async () => {
      await sleep(100);
      const sid = cookie.split('=')[1];
      assert.ok(!logs.includes(signature), 'token signature found in logs');
      assert.ok(!logs.includes(token.split('.')[1]), 'token payload found in logs');
      assert.ok(!logs.includes(sid), 'full session id found in logs');
      assert.match(logs, /sign-in sub=CUST-2026-00107 sid=/);
    });
  } finally {
    child.kill();
    mock.close();
  }

  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} checks passed`);
  if (failed) {
    console.log('\n--- server log ---\n' + logs);
    process.exitCode = 1;
  }
  setTimeout(() => process.exit(process.exitCode || 0), 200).unref();
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
