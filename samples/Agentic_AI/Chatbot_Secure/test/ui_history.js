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
function makeJwt(sub, ttlSeconds = 3600) {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub, name: `Test ${sub}`, scp: ['profile:read'], iat: now, exp: now + ttlSeconds };
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

// Mock orchestrator: answers each message after a delay (long enough to switch chats in between)
function startMockUpstream() {
  return new Promise(resolve => {
    const wss = new WebSocket.WebSocketServer({ host: '127.0.0.1', port: 0, path: '/retailbanking' });
    wss.on('connection', ws => {
      ws.on('message', data => {
        let text = data.toString();
        try {
          text = JSON.parse(text).message;
        } catch (e) {
          /* plain text */
        }
        setTimeout(() => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ message: `reply to: ${text}` })), 1500);
      });
    });
    wss.on('listening', () => resolve({ wss, url: `ws://127.0.0.1:${wss.address().port}/retailbanking` }));
  });
}

let UPSTREAM = 'ws://127.0.0.1:1/unused';

async function startServer(port) {
  let logs = '';
  const child = spawn(process.execPath, ['server.js'], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      ALLOWED_UPSTREAMS: UPSTREAM,
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
  const mock = await startMockUpstream();
  UPSTREAM = mock.url;
  let server = await startServer(appPort);
  const browser = spawn(browserPath, [
    '--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', 'about:blank'
  ], { stdio: 'ignore' });

  const cleanup = async () => {
    server.child.kill();
    mock.wss.close();
    const exited = new Promise(resolve => (browser.exitCode !== null ? resolve() : browser.once('exit', resolve)));
    browser.kill();
    await Promise.race([exited, sleep(5000)]);
    try {
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
    } catch (e) {
      console.log(`(could not remove the temporary browser profile ${profile}: ${e.code})`);
    }
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
    // History as the page stores it, for the CURRENT server session (its historyId)
    const plant = () => page.eval(`fetch('/auth/session', { credentials: 'same-origin' }).then(r => r.json()).then(s => {
      localStorage.setItem('flogoChatbotSecure_owner', s.historyId || s.sub); // (sub: what older versions keyed on)
      localStorage.setItem('flogoChatbotSecure_chats', JSON.stringify([{ id: 'chat-1', title: 'Chat 1',
        createdAt: new Date().toISOString(), messages: [
          { type: 'user', content: 'What is my balance?', timestamp: new Date().toISOString() },
          { type: 'bot', content: ${JSON.stringify(SECRET)}, timestamp: new Date().toISOString() }] }]));
      localStorage.setItem('flogoChatbotSecure_currentChatId', 'chat-1');
      localStorage.setItem('flogoChatbotSecure_chatCounter', '1');
      return true; })`);
    const signIn = (sub, ttl) => page.eval(`fetch('/auth/session', { method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: ${JSON.stringify(makeJwt(sub, ttl))} }) })
      .then(r => r.status)`);
    const authSettled = () => page.eval(`!document.getElementById('authSignedIn').hidden ||
      !document.getElementById('authSignedOut').hidden`);

    // 1. The previous customer's history is in localStorage, but the session is gone (server restarted).
    await page.goto(`${origin}/client-config`);
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant();
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
    await plant();
    await page.goto(`${origin}/`);
    await check('the signed-in owner reloads: their conversation is restored', async () => {
      await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    });

    // 3. A different user signs in on this browser: they never see it, and it is deleted.
    const ownerBefore = (await stored()).owner;
    assert.strictEqual(await signIn('CUST-B'), 200);
    await page.goto(`${origin}/`);
    await waitUntil(authSettled, 'sign-in panel rendered');
    await check('a different user signs in: the previous conversation is not shown and is deleted', async () => {
      await waitUntil(async () => ![null, ownerBefore].includes((await stored()).owner), 'history owner switched');
      assert.ok(!(await text()).includes(SECRET), 'another user sees the cached balance');
      assert.ok(!String((await stored()).chats || '').includes(SECRET), 'cached balance still stored');
    });

    // 3b. A token that merely CLAIMS the same sub (this server does not check signatures) starts a new session: the
    //     earlier session's history is not handed to it.
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant();
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    assert.strictEqual(await signIn('CUST-A'), 200); // forged: any signature is accepted here
    await page.goto(`${origin}/`);
    await waitUntil(authSettled, 'sign-in panel rendered');
    await check('a new sign-in claiming the same sub does not get the earlier session conversation', async () => {
      await sleep(500);
      assert.ok(!(await text()).includes(SECRET), 'a forged token with the same sub sees the cached balance');
      assert.ok(!String((await stored()).chats || '').includes(SECRET), 'cached balance still stored');
    });

    // 3c. The session expires while the tab is idle and nothing is connected: the history goes at expiry.
    assert.strictEqual(await signIn('CUST-A', 6), 200);
    await plant();
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    await check('an idle tab (no connection) drops the conversation when the session expires', async () => {
      await waitUntil(async () => !(await text()).includes(SECRET), 'conversation removed at expiry', 15000);
      assert.deepStrictEqual(await stored(), { owner: null, chats: null });
      assert.strictEqual(await page.eval(`document.getElementById('authSignedOut').hidden`), false);
    });

    // 4. Sign out with the button: the history is gone.
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant();
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    await page.eval(`document.getElementById('signOutBtn').click(), true`);
    await check('Sign out clears the conversation on screen and in the browser', async () => {
      await waitUntil(async () => !(await text()).includes(SECRET), 'conversation removed');
      assert.deepStrictEqual(await stored(), { owner: null, chats: null });
    });

    // 5. Sign-out in another tab: this tab drops the history too (no reload).
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant();
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

    // 6. A reply belongs to the chat its connection was opened in: switching chats ends that conversation, and the
    //    reply never lands in the chat now on screen.
    page.listeners.push(m => {
      if (m.method === 'Page.javascriptDialogOpening') page.send('Page.handleJavaScriptDialog', { accept: true });
    });
    assert.strictEqual(await signIn('CUST-A'), 200);
    await page.goto(`${origin}/`);
    await waitUntil(authSettled, 'sign-in panel rendered');
    await page.eval(`document.getElementById('connectBtn').click(), true`);
    await waitUntil(async () => (await text()).includes('Connected to server'), 'connected');
    await page.eval(`(() => { const i = document.getElementById('messageInput'); i.value = 'what is my balance';
      document.getElementById('sendBtn').click(); document.getElementById('newChatBtn').click(); return true; })()`);
    await check('switching to a new chat while a reply is pending ends the connection; the reply never lands in the new chat', async () => {
      await sleep(2500); // the mock answers after 1.5 s
      const t = await text();
      assert.ok(!t.includes('reply to: what is my balance'), 'the reply was shown in the newly opened chat');
      const stored = await page.eval(`JSON.stringify(chatbot.chats.get('chat-2') ? chatbot.chats.get('chat-2').messages : [])`);
      assert.ok(!stored.includes('reply to:'), 'the reply was filed into the new chat');
      assert.strictEqual(await page.eval('chatbot.isConnected'), false, 'still connected after switching chats');
      const first = await page.eval(`JSON.stringify(chatbot.chats.get('chat-1').messages.map(m => m.content))`);
      assert.ok(first.includes('what is my balance') && first.includes('Disconnected'), first);
      assert.ok(!/session ended/i.test(t), 'a deliberate disconnect must not report a session problem');
    });

    // 7. Sign-out that cannot reach the server: still signed in (and told so), history kept until it really ends.
    await page.eval(`document.getElementById('connectBtn').click(), true`);
    await waitUntil(async () => (await text()).includes('Connected to server'), 'connected again');
    await page.send('Fetch.enable', { patterns: [{ urlPattern: '*/auth/session*', requestStage: 'Request' }] });
    const failer = m => {
      if (m.method === 'Fetch.requestPaused') {
        const fail = m.params.request.method === 'DELETE';
        page.send(fail ? 'Fetch.failRequest' : 'Fetch.continueRequest',
          fail ? { requestId: m.params.requestId, errorReason: 'InternetDisconnected' } : { requestId: m.params.requestId });
      }
    };
    page.listeners.push(failer);
    let dialog = '';
    page.listeners.push(m => {
      if (m.method === 'Page.javascriptDialogOpening') dialog = m.params.message;
    });
    await page.eval(`document.getElementById('signOutBtn').click(), true`);
    await check('a sign-out that cannot reach the server says so and stays signed in (no false "signed out")', async () => {
      await waitUntil(async () => dialog.length > 0, 'sign-out failure message');
      assert.match(dialog, /still signed in/);
      assert.strictEqual(await page.eval(`document.getElementById('authSignedIn').hidden`), false, 'shows signed out');
      const st = await page.eval(`fetch('/auth/session', { credentials: 'same-origin' }).then(r => r.json()).then(j => j.signedIn)`);
      assert.strictEqual(st, true, 'the server session is still live, as the page says');
    });
    page.listeners.splice(page.listeners.indexOf(failer), 1);
    await page.send('Fetch.disable');
    await page.eval(`document.getElementById('signOutBtn').click(), true`);
    await check('a normal sign-out shows no error', async () => {
      await waitUntil(async () => (await page.eval(`document.getElementById('authSignedOut').hidden`)) === false, 'signed out');
      await sleep(500);
      const err = await page.eval(`document.getElementById('authError').hidden ? '' : document.getElementById('authError').textContent`);
      assert.strictEqual(err, '', `error shown after a normal sign-out: ${err}`);
    });

    // 8. Accessibility: every control has an accessible name (from Chrome's accessibility tree), and a chat can be
    //    opened from the keyboard.
    assert.strictEqual(await signIn('CUST-A'), 200);
    await page.goto(`${origin}/`);
    await waitUntil(authSettled, 'sign-in panel rendered');
    await waitUntil(async () => (await page.eval('chatbot.chatOwner')) !== null, 'history claimed for the session');
    await page.eval(`document.getElementById('newChatBtn').click(), document.getElementById('newChatBtn').click(), true`);
    await waitUntil(async () => (await page.eval('chatbot.chats.size')) === 2, 'two chats listed');
    await check('every button, text box and checkbox has an accessible name (Send, New chat, chat list, URL, message)', async () => {
      await page.send('Accessibility.enable');
      const { nodes } = await page.send('Accessibility.getFullAXTree');
      const controls = nodes.filter(n => !n.ignored && ['button', 'textbox', 'checkbox', 'combobox'].includes(n.role && n.role.value));
      // an icon glyph (private-use character) or a bare symbol such as '+' is not a name: require a letter or digit
      const unnamed = controls.filter(n => !/[\p{L}\p{N}]/u.test(String((n.name && n.name.value) || '')));
      assert.ok(controls.length >= 10, `only ${controls.length} controls found`);
      assert.deepStrictEqual(unnamed.map(n => `${n.role.value} named ${JSON.stringify((n.name && n.name.value) || '')}`), []);
      const names = controls.map(n => n.name.value);
      for (const want of ['Send message', 'New chat', 'Message', 'Upstream WebSocket URL', 'Delete Chat 1', 'Chat 1']) {
        assert.ok(names.includes(want), `no control named "${want}" (have: ${names.join(' | ')})`);
      }
    });
    await check('a chat can be opened from the keyboard (Tab to its title, Enter)', async () => {
      await page.eval(`document.querySelector('#chatSessions .chat-session-title').focus(), true`);
      await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
      await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
      await waitUntil(async () => (await page.eval('chatbot.currentChatId')) === 'chat-1', 'chat-1 opened by keyboard');
      assert.strictEqual(await page.eval(`document.querySelector('#chatSessions [aria-current="true"]').textContent`), 'Chat 1');
    });

    // 9. Stored history is untrusted: odd values are repaired or dropped, start-up still completes (panel, session
    //    timer), a bad stored counter never makes New chat overwrite a chat, and saving keeps working.
    assert.strictEqual(await signIn('CUST-A', 8), 200);
    await page.eval(`fetch('/auth/session', { credentials: 'same-origin' }).then(r => r.json()).then(s => {
      localStorage.setItem('flogoChatbotSecure_owner', s.historyId);
      localStorage.setItem('flogoChatbotSecure_chats', JSON.stringify([
        { id: 'chat-1', title: { toString: null }, createdAt: 'garbage', messages: [
          { type: 'bot', content: { toString: null }, timestamp: 'garbage' },
          { type: 'evil', content: 'dropped', timestamp: 'garbage' },
          { type: 'bot', content: 'IMPORTANT HISTORY', timestamp: 'garbage' }] },
        { id: 'chat-2', title: 'Chat 2', createdAt: new Date().toISOString(), messages: [] },
        { id: '<img src=x onerror=alert(1)>', title: 'x', messages: [] }, 'junk', null]));
      localStorage.setItem('flogoChatbotSecure_currentChatId', 'chat-1');
      localStorage.setItem('flogoChatbotSecure_chatCounter', 'abc');
      return true; })`);
    await page.goto(`${origin}/`);
    await check('odd stored history does not break start-up: signed-in panel filled, valid messages kept, bad ones dropped', async () => {
      await waitUntil(async () => (await page.eval(`document.getElementById('authName').textContent`)) === 'Test CUST-A', 'panel');
      await waitUntil(async () => (await text()).includes('IMPORTANT HISTORY'), 'valid message shown');
      assert.deepStrictEqual(await page.eval('Array.from(chatbot.chats.keys())'), ['chat-1', 'chat-2']);
      assert.ok(!(await text()).includes('dropped'), 'a message with an unknown type was shown');
      assert.ok(!(await text()).includes('NaN'), 'an invalid timestamp was shown as NaN');
    });
    await check('New chat after a bad stored counter creates chat-3 (never overwrites chat-1), and saving still works', async () => {
      await page.eval(`document.getElementById('newChatBtn').click(), true`);
      assert.strictEqual(await page.eval('chatbot.currentChatId'), 'chat-3');
      const saved = JSON.parse(await page.eval(`localStorage.getItem('flogoChatbotSecure_chats')`));
      assert.deepStrictEqual(saved.map(c => c.id), ['chat-1', 'chat-2', 'chat-3']);
      assert.ok(JSON.stringify(saved).includes('IMPORTANT HISTORY'), 'chat-1 history lost');
    });
    await check('...and the session check still runs: the history goes when that session expires', async () => {
      // (chat-3 is on screen now, so wait on the stored history and the in-memory chats, not on the visible text)
      await waitUntil(async () => (await stored()).owner === null, 'stored history removed at expiry', 15000);
      assert.deepStrictEqual(await stored(), { owner: null, chats: null });
      assert.strictEqual(await page.eval('chatbot.chats.size'), 0, 'chats still in memory');
      assert.ok(!(await text()).includes('IMPORTANT HISTORY'));
    });

    // 10. Keyboard focus follows the task: sign in -> Connect -> message box; Disconnect -> Connect; a chat opened
    //     from the list keeps focus; Sign out -> token box.
    const enter = async () => {
      await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
      await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    };
    const focusedId = () => page.eval(`document.activeElement ? (document.activeElement.id || document.activeElement.dataset.chatId || document.activeElement.tagName) : ''`);
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await page.eval(`document.getElementById('authSignedOut').hidden`)) === false, 'signed out');
    await check('keyboard: Enter in the token box signs in and moves focus to Connect', async () => {
      await page.eval(`(() => { const i = document.getElementById('jwtInput'); i.value = ${JSON.stringify(makeJwt('CUST-A'))}; i.focus(); return true; })()`);
      await enter();
      await waitUntil(async () => (await focusedId()) === 'connectBtn', 'focus on Connect', 5000);
    });
    await check('keyboard: Enter on Connect connects and moves focus to the message box', async () => {
      await enter();
      await waitUntil(async () => (await focusedId()) === 'messageInput', 'focus on the message box', 5000);
    });
    await check('keyboard: Disconnect moves focus back to Connect', async () => {
      await page.eval(`document.getElementById('disconnectBtn').focus(), true`);
      await enter();
      await waitUntil(async () => (await focusedId()) === 'connectBtn', 'focus on Connect', 5000);
    });
    await check('keyboard: opening a chat from the list keeps focus on that chat', async () => {
      await page.eval(`document.getElementById('newChatBtn').click(), true`);
      await page.eval(`document.querySelector('#chatSessions button.chat-session-title[data-chat-id="chat-1"]').focus(), true`);
      await enter();
      await waitUntil(async () => (await page.eval('chatbot.currentChatId')) === 'chat-1', 'chat-1 opened');
      assert.strictEqual(await focusedId(), 'chat-1');
    });
    await check('keyboard: Sign out moves focus to the token box', async () => {
      await page.eval(`document.getElementById('signOutBtn').focus(), true`);
      await enter();
      await waitUntil(async () => (await focusedId()) === 'jwtInput', 'focus on the token box', 5000);
    });

    // 11. A session check that gets NO answer (network error, 5xx) is not a sign-out: the history stays, the page says
    //     so, Connect is locked, and it retries. Only the session's known expiry ends it without the server.
    let mode = 'pass';
    const interceptor = m => {
      if (m.method !== 'Fetch.requestPaused') return;
      const id = m.params.requestId;
      if (m.params.request.method !== 'GET' || mode === 'pass') return page.send('Fetch.continueRequest', { requestId: id });
      if (mode === 'fail') return page.send('Fetch.failRequest', { requestId: id, errorReason: 'InternetDisconnected' });
      return page.send('Fetch.fulfillRequest', { requestId: id, responseCode: 503,
        responseHeaders: [{ name: 'Content-Type', value: 'text/plain' }], body: Buffer.from('busy').toString('base64') });
    };
    page.listeners.push(interceptor);
    await page.send('Fetch.enable', { patterns: [{ urlPattern: '*/auth/session*', requestStage: 'Request' }] });
    const note = () => page.eval(`document.getElementById('authNote').hidden ? '' : document.getElementById('authNote').textContent`);
    const connectLocked = () => page.eval(`document.getElementById('connectBtn').disabled`);

    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant();
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    for (const [label, m] of [['a network error', 'fail'], ['an HTTP 503', '503']]) {
      mode = m;
      await page.eval('chatbot.refreshAuthStatus().then(() => true)');
      await check(`${label} on the session check keeps the conversation (screen and storage), says so and locks Connect`, async () => {
        assert.ok((await text()).includes(SECRET), 'conversation removed from the screen');
        assert.ok(String((await stored()).chats || '').includes(SECRET), 'conversation deleted from storage');
        assert.match(await note(), /Cannot reach the server/);
        assert.strictEqual(await connectLocked(), true, 'Connect usable while the session is unverified');
        assert.strictEqual(await page.eval(`document.getElementById('authSignedIn').hidden`), false);
      });
    }
    mode = 'pass';
    await check('when the server answers again the page recovers by itself (note gone, Connect usable, chats kept)', async () => {
      await waitUntil(async () => (await note()) === '', 'retry succeeded', 40000);
      assert.strictEqual(await connectLocked(), false);
      assert.ok((await text()).includes(SECRET));
    });

    assert.strictEqual(await signIn('CUST-A', 6), 200);
    await plant();
    await page.goto(`${origin}/`);
    await waitUntil(async () => (await text()).includes(SECRET), 'restored conversation');
    mode = 'fail';
    await check('with the server unreachable, the conversation still goes when the session\'s known expiry passes', async () => {
      await waitUntil(async () => (await stored()).owner === null, 'history removed at the known expiry', 20000);
      assert.ok(!(await text()).includes(SECRET));
      assert.strictEqual(await page.eval(`document.getElementById('authSignedOut').hidden`), false);
    });

    mode = 'pass';
    assert.strictEqual(await signIn('CUST-A'), 200);
    await plant();
    mode = 'fail';
    await page.goto(`${origin}/`);
    await check('a page loaded while the server is unreachable neither shows nor deletes the history; it is restored once the server answers', async () => {
      await waitUntil(async () => /Cannot reach the server/.test(await note()), 'unreachable note', 10000);
      assert.ok(!(await text()).includes(SECRET), 'history shown before the session was verified');
      assert.ok(String((await stored()).chats || '').includes(SECRET), 'history deleted because the server was unreachable');
      mode = 'pass';
      await waitUntil(async () => (await text()).includes(SECRET), 'history restored after the retry', 40000);
    });
    page.listeners.splice(page.listeners.indexOf(interceptor), 1);
    await page.send('Fetch.disable');

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
