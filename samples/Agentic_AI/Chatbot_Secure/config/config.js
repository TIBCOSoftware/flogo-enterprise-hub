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

const defaultUpstream = 'ws://localhost:9970/retailbanking';

const allowedUpstreams = list(process.env.ALLOWED_UPSTREAMS, defaultUpstream);

module.exports = {
  // Server port (default: 3001, so it runs alongside the shared Chatbot on 3000)
  port: parseInt(process.env.PORT || '3001', 10),

  // Interface to bind (default: loopback only). Set HOST=0.0.0.0 only behind HTTPS.
  host: process.env.HOST || '127.0.0.1',

  // Upstream WebSocket URLs the proxy may connect to (comma-separated, exact match)
  allowedUpstreams,

  // URL pre-filled in the browser (must be one of ALLOWED_UPSTREAMS)
  wsUrl: allowedUpstreams.includes(process.env.WS_URL) ? process.env.WS_URL : allowedUpstreams[0] || defaultUpstream,

  // Direct mode: the browser connects straight to the upstream WebSocket with NO token.
  // Off by default; only useful for unauthenticated samples.
  directMode: String(process.env.DIRECT_MODE || 'false').toLowerCase() === 'true',

  // Server-side session lifetime (capped by the JWT's own exp claim)
  sessionTtlMinutes: parseInt(process.env.SESSION_TTL_MINUTES || '480', 10),

  // Secure cookie flag: auto (= when the request arrived over HTTPS), true, or false
  cookieSecure: String(process.env.COOKIE_SECURE || 'auto').toLowerCase(),

  // Trust X-Forwarded-Proto from a TLS-terminating reverse proxy
  trustProxy: String(process.env.TRUST_PROXY || 'false').toLowerCase() === 'true',

  // Allowed browser origins (comma-separated). Empty = the server's own origin only.
  allowedOrigins: list(process.env.ALLOWED_ORIGINS, '').map(o => o.toLowerCase()),

  // Upstream handshake timeout and max message size
  upstreamTimeoutMs: parseInt(process.env.UPSTREAM_TIMEOUT_MS || '10000', 10),
  maxMessageBytes: parseInt(process.env.MAX_MESSAGE_BYTES || String(1024 * 1024), 10),

  // Application name
  appName: 'Flogo Chatbot (Secure Proxy)'
};
