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

const defaultUpstream = 'ws://localhost:9970/retailbanking';

const allowedUpstreams = list(process.env.ALLOWED_UPSTREAMS, defaultUpstream).map(wsUrl);

module.exports = {
  // Server port (default: 3001, so it runs alongside the shared Chatbot on 3000)
  port: positiveInt('PORT', 3001, 65535),

  // Interface to bind (default: loopback only). Set HOST=0.0.0.0 only behind HTTPS.
  host: process.env.HOST || '127.0.0.1',

  // Upstream WebSocket URLs the proxy may connect to (comma-separated, exact match)
  allowedUpstreams,

  // URL pre-filled in the browser (must be one of ALLOWED_UPSTREAMS)
  wsUrl: allowedUpstreams.includes(process.env.WS_URL) ? process.env.WS_URL : allowedUpstreams[0] || defaultUpstream,

  // Direct mode: the browser connects straight to the upstream WebSocket with NO token.
  // Off by default; only useful for unauthenticated samples.
  directMode: oneOf('DIRECT_MODE', 'false', ['true', 'false']) === 'true',

  // Server-side session lifetime (capped by the JWT's own exp claim); at most 30 days
  sessionTtlMinutes: positiveInt('SESSION_TTL_MINUTES', 480, 30 * 24 * 60),

  // Most signed-in sessions kept in memory; the oldest is dropped when a new one would exceed it
  maxSessions: positiveInt('MAX_SESSIONS', 1000),

  // Secure cookie flag: auto (= when the request arrived over HTTPS), true, or false
  cookieSecure: oneOf('COOKIE_SECURE', 'auto', ['auto', 'true', 'false']),

  // Trust X-Forwarded-Proto from a TLS-terminating reverse proxy
  trustProxy: oneOf('TRUST_PROXY', 'false', ['true', 'false']) === 'true',

  // Allowed browser origins (comma-separated). Empty = the server's own origin only.
  allowedOrigins: list(process.env.ALLOWED_ORIGINS, '').map(o => o.toLowerCase()),

  // Upstream handshake timeout and max message size
  upstreamTimeoutMs: positiveInt('UPSTREAM_TIMEOUT_MS', 10000, 2 ** 31 - 1),
  maxMessageBytes: positiveInt('MAX_MESSAGE_BYTES', 1024 * 1024, 2 ** 31 - 1),

  // Application name
  appName: 'Flogo Chatbot (Secure Proxy)'
};
