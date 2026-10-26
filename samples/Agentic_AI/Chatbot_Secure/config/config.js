/**
 * Configuration module for the Flogo Chatbot (Secure Proxy) application
 * Loads environment variables with sensible defaults
 */

require('dotenv').config();

const list = (value, fallback) =>
  String(value === undefined || value === '' ? fallback : value)
    .split(',')
    .map(s => s.trim())
    .filter(Boolean);

// Invalid settings stop the server at startup with a clear message (rather than failing per request).
const fail = message => {
  throw new Error(`Invalid configuration: ${message}`);
};

const positiveInt = (name, fallback, max = Number.MAX_SAFE_INTEGER) => {
  const raw = process.env[name] === undefined || process.env[name] === '' ? String(fallback) : process.env[name].trim();
  if (!/^\d+$/.test(raw) || Number(raw) < 1 || Number(raw) > max) fail(`${name} must be a whole number from 1 to ${max} (got "${raw}")`);
  return Number(raw);
};

const oneOf = (name, fallback, allowed) => {
  const value = String(process.env[name] || fallback).trim().toLowerCase();
  if (!allowed.includes(value)) fail(`${name} must be one of ${allowed.join(' | ')} (got "${value}")`);
  return value;
};

const wsUrl = entry => {
  let url;
  try {
    url = new URL(entry);
  } catch (e) {
    fail(`ALLOWED_UPSTREAMS entry "${entry}" is not a URL`);
  }
  if (!['ws:', 'wss:'].includes(url.protocol) || url.hash) {
    fail(`ALLOWED_UPSTREAMS entry "${entry}" must be a ws:// or wss:// URL without a #fragment`);
  }
  return entry;
};

// A browser origin is scheme://host[:port], nothing else (a trailing slash or a path would never match a request).
const origin = entry => {
  let url;
  try {
    url = new URL(entry);
  } catch (e) {
    fail(`ALLOWED_ORIGINS entry "${entry}" is not a URL`);
  }
  if (!['http:', 'https:'].includes(url.protocol) || url.origin !== entry.toLowerCase()) {
    fail(`ALLOWED_ORIGINS entry "${entry}" must be an origin like https://chat.example.com (no path, no trailing slash)`);
  }
  return url.origin;
};

const hostName = entry => {
  const value = entry.toLowerCase();
  if (!/^(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(:\d{1,5})?$/.test(value)) fail(`ALLOWED_HOSTS entry "${entry}" must be host or host:port`);
  return value;
};

const defaultUpstream = 'ws://localhost:9970/retailbanking';

const allowedUpstreams = list(process.env.ALLOWED_UPSTREAMS, defaultUpstream).map(wsUrl);
const port = positiveInt('PORT', 3001, 65535);
const host = (process.env.HOST || '127.0.0.1').trim();
if (!/^(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.:-]+)$/.test(host)) fail(`HOST must be an interface address or name (got "${host}")`);
const allowedOrigins = list(process.env.ALLOWED_ORIGINS, '').map(origin);
if (process.env.WS_URL && !allowedUpstreams.includes(process.env.WS_URL)) {
  fail(`WS_URL "${process.env.WS_URL}" must be one of ALLOWED_UPSTREAMS`);
}

// Host header values this server answers to. A web page can point its own host name at 127.0.0.1 (DNS rebinding) and
// then send matching Host and Origin headers, so the Host must be one we know: the loopback names by default, plus the
// hosts of ALLOWED_ORIGINS and anything in ALLOWED_HOSTS (e.g. the name a reverse proxy forwards).
const allowedHosts = [
  ...new Set([
    `localhost:${port}`,
    `127.0.0.1:${port}`,
    `[::1]:${port}`,
    ...allowedOrigins.map(o => new URL(o).host),
    ...list(process.env.ALLOWED_HOSTS, '').map(hostName)
  ])
];

module.exports = {
  // Server port (default: 3001, so it runs alongside the shared Chatbot on 3000)
  port,

  // Interface to bind (default: loopback only). Set HOST=0.0.0.0 only behind HTTPS.
  host,

  // Upstream WebSocket URLs the proxy may connect to (comma-separated, exact match)
  allowedUpstreams,

  // URL pre-filled in the browser (must be one of ALLOWED_UPSTREAMS)
  wsUrl: process.env.WS_URL || allowedUpstreams[0] || defaultUpstream,

  // Direct mode: the browser connects straight to the upstream WebSocket with NO token.
  // Off by default; only useful for unauthenticated samples.
  directMode: oneOf('DIRECT_MODE', 'false', ['true', 'false']) === 'true',

  // Server-side session lifetime (capped by the JWT's own exp claim); at most 30 days
  sessionTtlMinutes: positiveInt('SESSION_TTL_MINUTES', 480, 30 * 24 * 60),

  // Most signed-in sessions kept in memory; when full, new sign-ins are refused (HTTP 429), never evicting anyone
  maxSessions: positiveInt('MAX_SESSIONS', 1000),

  // Sign-in attempts allowed per client address per minute (HTTP 429 above it)
  signinPerMinute: positiveInt('SIGNIN_PER_MINUTE', 10),

  // Secure cookie flag: auto (= when the request arrived over HTTPS), true, or false
  cookieSecure: oneOf('COOKIE_SECURE', 'auto', ['auto', 'true', 'false']),

  // Trust X-Forwarded-Proto from a TLS-terminating reverse proxy
  trustProxy: oneOf('TRUST_PROXY', 'false', ['true', 'false']) === 'true',

  // Allowed browser origins (comma-separated). Empty = the server's own origin only.
  allowedOrigins,

  // Host header values accepted (see above); anything else gets HTTP 421
  allowedHosts,

  // Proxied WebSocket connections (open + connecting): per signed-in session, and in total
  maxConnectionsPerSession: positiveInt('MAX_CONNECTIONS_PER_SESSION', 5),
  maxConnections: positiveInt('MAX_CONNECTIONS', 200),

  // Seconds between pings to each browser connection; one that misses a pong is closed (half-open connections)
  heartbeatSeconds: positiveInt('HEARTBEAT_SECONDS', 30, 3600),

  // Upstream handshake timeout and max message size
  upstreamTimeoutMs: positiveInt('UPSTREAM_TIMEOUT_MS', 10000, 2 ** 31 - 1),
  maxMessageBytes: positiveInt('MAX_MESSAGE_BYTES', 1024 * 1024, 2 ** 31 - 1),

  // Application name
  appName: 'Flogo Chatbot (Secure Proxy)'
};
