/**
 * Main server file for the Flogo Chatbot (Secure Proxy) application.
 * Serves the chat UI, keeps the signed-in user's JWT in a server-side session,
 * and proxies the browser's WebSocket to the Flogo orchestrator with an
 * Authorization: Bearer header (browsers cannot set that header themselves).
 */

const express = require('express');
const http = require('http');
const path = require('path');
const config = require('./config/config');
const { SessionStore } = require('./lib/sessions');
const { attachProxy } = require('./lib/proxy');

const store = new SessionStore({ ttlMs: config.sessionTtlMinutes * 60 * 1000, maxSessions: config.maxSessions });

const app = express();
app.disable('x-powered-by');
if (config.trustProxy) app.set('trust proxy', 1);

// Basic hardening headers
app.use((req, res, next) => {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer'
  });
  next();
});

// Middleware (JSON only; the sign-in endpoint does not accept form posts)
app.use(express.json({ limit: '32kb' }));

// Serve static files from public directory
app.use(express.static(path.join(__dirname, 'public')));

// Routes
app.use('/auth', require('./routes/auth')({ store, config }));
app.use('/', require('./routes/index'));

// Error handling middleware (never log request bodies: they may contain a token)
app.use((err, req, res, next) => {
  if (err && err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Invalid JSON body' });
  }
  if (err && err.type === 'entity.too.large') {
    return res.status(413).json({ error: 'Request body too large' });
  }
  // Other client errors from the body parser (unsupported charset / encoding, ...) keep their 4xx status.
  if (err && Number.isInteger(err.status) && err.status >= 400 && err.status < 500) {
    return res.status(err.status).json({ error: err.expose && err.message ? err.message : 'Bad request' });
  }
  console.error('Error:', err && err.message ? err.message : 'unknown error');
  res.status(500).json({ error: 'Internal server error' });
});

const server = http.createServer(app);
attachProxy(server, { store, config });

server.listen(config.port, config.host, () => {
  const shownHost = config.host === '127.0.0.1' || config.host === '0.0.0.0' ? 'localhost' : config.host;
  console.log(`Flogo Chatbot (Secure Proxy) running on http://${shownHost}:${config.port}`);
  console.log(`Allowed upstreams: ${config.allowedUpstreams.join(', ') || '(none)'}`);
  console.log(`Direct mode: ${config.directMode ? 'ENABLED (no token is sent)' : 'disabled'}`);
});

module.exports = server;
