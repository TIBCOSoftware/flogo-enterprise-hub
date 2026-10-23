/**
 * WebSocket proxy (backend-for-frontend).
 *
 * Browser  --ws(cookie)-->  this server  --ws(Authorization: Bearer <jwt>)-->  Flogo orchestrator
 *
 * The browser connects to  /proxy?target=<url-encoded upstream ws url>.
 * The upgrade is accepted only when:
 *   - the Origin header matches this server's origin (or ALLOWED_ORIGINS),
 *   - the HttpOnly session cookie maps to a live session,
 *   - target is on the ALLOWED_UPSTREAMS allow-list (exact match),
 *   - the upstream accepted the handshake.
 * One upstream connection per browser connection; frames are piped both ways.
 */

const http = require('http');
const WebSocket = require('ws');
const { readCookie, originAllowed, logSub, sidTag } = require('./security');

const PROXY_PATH = '/proxy';

function rejectUpgrade(socket, status, message) {
  if (socket.destroyed) return;
  const body = `${message}\n`;
  socket.write(
    `HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\n` +
      'Connection: close\r\n' +
      'Content-Type: text/plain; charset=utf-8\r\n' +
      'Cache-Control: no-store\r\n' +
      `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n` +
      body
  );
  socket.destroy();
}

function sendableCode(code) {
  return (code >= 1000 && code <= 1014 && code !== 1004 && code !== 1005 && code !== 1006) ||
    (code >= 3000 && code <= 4999)
    ? code
    : null;
}

function trimReason(reason) {
  let text = Buffer.isBuffer(reason) ? reason.toString('utf8') : String(reason || '');
  while (Buffer.byteLength(text) > 123) text = text.slice(0, -1);
  return text;
}

/** Close a ws without throwing; map unsendable codes (1005/1006) sensibly. */
function closeQuietly(ws, code, reason, fallbackCode) {
  try {
    if (ws.readyState === WebSocket.CONNECTING) return ws.terminate();
    if (ws.readyState !== WebSocket.OPEN) return;
    const sendable = sendableCode(code);
    if (sendable) return ws.close(sendable, trimReason(reason));
    if (code === 1005) return ws.close();
    return ws.close(fallbackCode || 1011, trimReason(reason) || 'Connection lost');
  } catch (e) {
    ws.terminate();
  }
}

function attachProxy(server, { store, config }) {
  const wss = new WebSocket.WebSocketServer({ noServer: true, maxPayload: config.maxMessageBytes });

  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {});

    let url;
    try {
      url = new URL(req.url, 'http://placeholder');
    } catch (e) {
      return rejectUpgrade(socket, 400, 'Bad request');
    }
    if (url.pathname !== PROXY_PATH) return rejectUpgrade(socket, 404, 'Not found');

    if (!originAllowed(req, config, { required: true })) {
      console.warn('[proxy] rejected upgrade: origin not allowed');
      return rejectUpgrade(socket, 403, 'Origin not allowed');
    }

    const sid = readCookie(req);
    const session = store.get(sid);
    if (!session) {
      console.warn('[proxy] rejected upgrade: not signed in');
      return rejectUpgrade(socket, 401, 'Sign in first');
    }

    const target = url.searchParams.get('target');
    if (!target || !config.allowedUpstreams.includes(target)) {
      console.warn(`[proxy] rejected upgrade: target not allowed sid=${sidTag(sid)}`);
      return rejectUpgrade(socket, 403, 'Target not allowed');
    }

    const tag = `sub=${logSub(session.claims)} sid=${sidTag(sid)} target=${target}`;

    let upstream;
    try {
      upstream = new WebSocket(target, {
        headers: { Authorization: `Bearer ${session.token}` },
        handshakeTimeout: config.upstreamTimeoutMs,
        perMessageDeflate: false,
        followRedirects: false,
        maxPayload: config.maxMessageBytes
      });
    } catch (err) {
      // ws throws synchronously on an unusable URL/option; config validation should prevent it, but never crash.
      console.warn(`[proxy] cannot open upstream (${err.message}) ${tag}`);
      return rejectUpgrade(socket, 502, 'Upstream unavailable');
    }

    let settled = false;
    const abortUpstream = () => {
      if (settled) return;
      settled = true;
      upstream.terminate();
    };
    socket.once('close', abortUpstream);

    upstream.once('unexpected-response', (upReq, upRes) => {
      if (settled) return;
      settled = true;
      console.warn(`[proxy] upstream rejected handshake (${upRes.statusCode}) ${tag}`);
      upRes.resume();
      upReq.destroy();
      rejectUpgrade(socket, 502, `Upstream rejected the connection (${upRes.statusCode})`);
    });

    upstream.on('error', err => {
      if (settled) return;
      settled = true;
      console.warn(`[proxy] upstream unavailable (${err.code || err.message}) ${tag}`);
      rejectUpgrade(socket, 502, 'Upstream unavailable');
    });

    upstream.once('open', () => {
      if (settled) return;
      settled = true;
      socket.removeListener('close', abortUpstream);

      // The session may have been signed out while we were connecting.
      if (store.get(sid) !== session) {
        upstream.terminate();
        return rejectUpgrade(socket, 401, 'Sign in first');
      }

      // Keep the upstream tied to the browser socket until the browser handshake succeeds: handleUpgrade
      // destroys the socket without calling back when it rejects the handshake (bad key / version).
      const dropUpstream = () => upstream.terminate();
      socket.once('close', dropUpstream);
      wss.handleUpgrade(req, socket, head, client => {
        socket.removeListener('close', dropUpstream);
        bridge(client, upstream, session, tag, config);
      });
    });
  });

  return wss;
}

// Backpressure: queue at most HIGH_WATER bytes for a slow receiver, then stop reading from the sender until the queue
// drains to half. Frames already in flight when the sender is paused can still arrive, so the pair is closed if the
// queue passes a hard limit anyway (memory stays bounded either way).
const HIGH_WATER = 1024 * 1024;

function bridge(client, upstream, session, tag, config) {
  console.log(`[proxy] open ${tag}`);

  const closeBoth = reason => {
    closeQuietly(client, 1008, reason);
    closeQuietly(upstream, 1000, reason);
  };
  session.connections.add(closeBoth);

  // Backstop for the session store's expiry timer: never relay a frame for an expired session.
  const expired = () => {
    if (Date.now() < session.expiresAt) return false;
    closeBoth('Session expired');
    return true;
  };
  const hardLimit = Math.max(16 * 1024 * 1024, 2 * config.maxMessageBytes + HIGH_WATER);
  const relay = (from, to, label) => {
    let warned = false;
    from.on('message', (data, isBinary) => {
      if (expired() || to.readyState !== WebSocket.OPEN) return;
      to.send(data, { binary: isBinary }, () => {
        if (from.isPaused && from.readyState === WebSocket.OPEN && to.bufferedAmount <= HIGH_WATER / 2) from.resume();
      });
      if (to.bufferedAmount > hardLimit) {
        console.warn(`[proxy] closing: ${to.bufferedAmount} bytes queued for a slow receiver ${tag}`);
        return closeBoth('Too much data queued');
      }
      if (to.bufferedAmount >= HIGH_WATER && !from.isPaused) {
        from.pause();
        if (!warned) {
          warned = true;
          console.warn(`[proxy] slow receiver: pausing the ${label} until it catches up ${tag}`);
        }
      }
    });
  };
  relay(client, upstream, 'browser');
  relay(upstream, client, 'upstream');

  let logged = false;
  const done = (side, code) => {
    session.connections.delete(closeBoth);
    if (!logged) {
      logged = true;
      console.log(`[proxy] closed by ${side} (${code}) ${tag}`);
    }
  };

  client.on('close', (code, reason) => {
    done('browser', code);
    closeQuietly(upstream, code, reason, 1001);
  });
  upstream.on('close', (code, reason) => {
    done('upstream', code);
    closeQuietly(client, code, reason, 1011);
  });

  client.on('error', () => upstream.terminate());
  upstream.on('error', () => closeQuietly(client, 1011, 'Upstream error'));
}

module.exports = { attachProxy, PROXY_PATH };
