/**
 * Browser test of the chat history (no Flogo needed): a cached conversation is shown only to the signed-in user who
 * owns it - never before the session check, never after the session ended, never to another user.
 *
 * Drives headless Chrome (or Edge) over the DevTools protocol with the `ws` package. Set CHROME_PATH if the browser is
 * not in a standard location.
 *
 * Run: npm run test:ui
 */

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');

const ROOT = path.join(__dirname, '..');
const SECRET = 'Available balance 48,213.77 on ****9921';

// ---------------------------------------------------------------- helpers

const b64u = obj => Buffer.from(JSON.stringify(obj)).toString('base64url');
function makeJwt(sub) {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub, name: `Test ${sub}`, scp: ['profile:read'], iat: now, exp: now + 3600 };
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

function getJson(port, urlPath) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: urlPath }, res => {
      let data = '';
      res.on('data', c => (data += c));
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch (e) {
          reject(e);
        }
      });
    }).on('error', reject);
  });
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitUntil(fn, label, ms = 10000) {
  const end = Date.now() + ms;
  for (;;) {
    if (await fn()) return;
    if (Date.now() > end) throw new Error(`timed out: ${label}`);
    await sleep(100);
  }
}

function findBrowser() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser'
  ];
  return candidates.find(p => p && fs.existsSync(p));
}

async function startServer(port) {
  let logs = '';
  const child = spawn(process.execPath, ['server.js'], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      ALLOWED_UPSTREAMS: 'ws://127.0.0.1:1/unused',
      SIGNIN_PER_MINUTE: '1000',
      ALLOWED_ORIGINS: '',
      WS_URL: '',
      DIRECT_MODE: 'false',
      COOKIE_SECURE: 'auto',
      TRUST_PROXY: 'false'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  child.stdout.on('data', d => (logs += d));
  child.stderr.on('data', d => (logs += d));
  await waitUntil(async () => {
    try {
      await getJson(port, '/client-config');
      return true;
    } catch (e) {
      return false;
    }
  }, 'chatbot server start');
  return { child, logs: () => logs };
}

/** Minimal DevTools-protocol client for one page. */
class Page {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl, { perMessageDeflate: false });
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = [];
    this.ws.on('message', raw => {
      const msg = JSON.parse(raw.toString());
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      } else if (msg.method) {
        this.listeners.forEach(l => l(msg));
      }
    });
  }
  open() {
    return new Promise((resolve, reject) => {
      this.ws.once('open', resolve);
      this.ws.once('error', reject);
    });
  }
  send(method, params = {}) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`page error: ${r.exceptionDetails.text} in ${expression}`);
    return r.result.value;
  }
  async goto(url) {
    await this.send('Page.navigate', { url });
    await waitUntil(async () => {
      try {
        return (await this.eval('document.readyState')) === 'complete';
      } catch (e) {
        return false; // navigating
      }
    }, `load ${url}`);
  }
}

// ---------------------------------------------------------------- test

let passed = 0;
let failed = 0;
async function check(label, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`PASS ${label}`);
  } catch (err) {
    failed += 1;
    console.log(`FAIL ${label}\n     ${err.message}`);
  }
}

(async () => {
  const browserPath = findBrowser();
  if (!browserPath) {
    console.log('SKIP: no Chrome/Edge found (set CHROME_PATH)');
    return;
  }
  const appPort = await freePort();
  const cdpPort = await freePort();
  const origin = `http://127.0.0.1:${appPort}`;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'chatbot-ui-'));
  let server = await startServer(appPort);
  const browser = spawn(browserPath, [
    '--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', 'about:blank'
  ], { stdio: 'ignore' });

  const cleanup = async () => {
    server.child.kill();
    browser.kill();
    await sleep(500);
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  };

  try {
    let target;
    await waitUntil(async () => {
      try {
        target = (await getJson(cdpPort, '/json/list')).find(t => t.type === 'page');
        return !!target;
      } catch (e) {
        return false;
      }
    }, 'browser DevTools endpoint');
    const page = new Page(target.webSocketDebuggerUrl);
    await page.open();
    await page.send('Page.enable');
    await page.send('Runtime.enable');

    const text = () => page.eval('document.body.innerText');
    const stored = () => page.eval(`JSON.stringify({ owner: localStorage.getItem('flogoChatbotSecure_owner'),
      chats: localStorage.getItem('flogoChatbotSecure_chats') })`).then(JSON.parse);
    const plant = owner => page.eval(`(() => {
      localStorage.setItem('flogoChatbotSecure_owner', ${JSON.stringify(owner)});
      localStorage.setItem('flogoChatbotSecure_chats', JSON.stringify([{ id: 'chat-1', title: 'Chat 1',
        createdAt: new Date().toISOString(), messages: [
          { type: 'user', content: 'What is my balance?', timestamp: new Date().toISOString() },
          { type: 'bot', content: ${JSON.stringify(SECRET)}, timestamp: new Date().toISOString() }] }]));
      localStorage.setItem('flogoChatbotSecure_currentChatId', 'chat-1');
      localStorage.setItem('flogoChatbotSecure_chatCounter', '1');
      return true; })()`);
    const signIn = sub => page.eval(`fetch('/auth/session', { method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: ${JSON.stringify(makeJwt(sub))} }) })
      .then(r => r.status)`);
    const authSettled = () => page.eval(`!document.getElementById('authSignedIn').hidden ||
      !document.getElementById('authSignedOut').hidden`);

    // 1. The previous customer's history is in localStorage, but the session is gone (server restarted).
    await page.goto(`${origin}/client-config`);
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant('CUST-A');
    server.child.kill();
    await sleep(300);
    server = await startServer(appPort);

    // Hold the session check so the page is observed BEFORE it knows who is signed in.
    await page.send('Fetch.enable', { patterns: [{ urlPattern: '*/auth/session*', requestStage: 'Request' }] });
    const paused = [];
    page.listeners.push(m => m.method === 'Fetch.requestPaused' && paused.push(m.params.requestId));
    await page.send('Page.navigate', { url: `${origin}/` });
    await waitUntil(async () => paused.length > 0, 'the page asks /auth/session');
    await check('while the session check is pending, the cached conversation is not shown', async () => {
      await sleep(300);
      const t = await text();
      assert.ok(!t.includes(SECRET), 'cached balance visible before the session check');
    });
    for (const id of paused) await page.send('Fetch.continueRequest', { requestId: id });
    await page.send('Fetch.disable');
    await waitUntil(authSettled, 'sign-in panel rendered');
    await check('signed out after a server restart: the conversation stays hidden and is deleted from the browser', async () => {
      await sleep(300);
      assert.ok(!(await text()).includes(SECRET), 'cached balance visible while signed out');
      assert.deepStrictEqual(await stored(), { owner: null, chats: null });
    });

    // 2. The same user, still signed in, reloads: their history comes back.
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant('CUST-A');
    await page.goto(`${origin}/`);
    await check('the signed-in owner reloads: their conversation is restored', async () => {
      await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    });

    // 3. A different user signs in on this browser: they never see it, and it is deleted.
    assert.strictEqual(await signIn('CUST-B'), 200);
    await page.goto(`${origin}/`);
    await waitUntil(authSettled, 'sign-in panel rendered');
    await check('a different user signs in: the previous conversation is not shown and is deleted', async () => {
      await waitUntil(async () => (await stored()).owner === 'CUST-B', 'owner switched to CUST-B');
      assert.ok(!(await text()).includes(SECRET), 'another user sees the cached balance');
      assert.ok(!String((await stored()).chats || '').includes(SECRET), 'cached balance still stored');
    });

    // 4. Sign out with the button: the history is gone.
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant('CUST-A');
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    await page.eval(`document.getElementById('signOutBtn').click(), true`);
    await check('Sign out clears the conversation on screen and in the browser', async () => {
      await waitUntil(async () => !(await text()).includes(SECRET), 'conversation removed');
      assert.deepStrictEqual(await stored(), { owner: null, chats: null });
    });

    // 5. Sign-out in another tab: this tab drops the history too (no reload).
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant('CUST-A');
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    const other = await page.send('Target.createTarget', { url: `${origin}/` }).catch(() => null);
    await check('a sign-out in another tab removes the conversation from this tab as well', async () => {
      assert.ok(other, 'could not open a second tab');
      const t2 = (await getJson(cdpPort, '/json/list')).find(t => t.id === other.targetId);
      const page2 = new Page(t2.webSocketDebuggerUrl);
      await page2.open();
      await page2.send('Runtime.enable');
      await waitUntil(async () => {
        try {
          return (await page2.eval(`typeof chatbot !== 'undefined' && !!chatbot && !document.getElementById('authSignedIn').hidden`)) === true;
        } catch (e) {
          return false;
        }
      }, 'second tab signed in');
      await page2.eval(`document.getElementById('signOutBtn').click(), true`);
      await waitUntil(async () => !(await text()).includes(SECRET), 'first tab cleared');
      page2.ws.close();
    });

    page.ws.close();
  } catch (err) {
    failed += 1;
    console.log(`FAIL ${err.message}\n${server.logs()}`);
  } finally {
    await cleanup();
  }
  console.log(`\n${failed ? 'UI HISTORY FAILED' : 'UI HISTORY OK'}  (${passed} passed, ${failed} failed)`);
  process.exitCode = failed ? 1 : 0;
})();
