/**
 * Sign-in / sign-out routes for proxy mode.
 *
 *   POST   /auth/session  { "token": "<jwt>" }  -> sets HttpOnly session cookie
 *   GET    /auth/session                        -> signed-in status + non-secret claims
 *   DELETE /auth/session                        -> sign out (closes proxied connections)
 *
 * The raw token is never returned, logged, or placed in a URL.
 */

const express = require('express');
const {
  COOKIE_NAME,
  readCookie,
  isSecureRequest,
  originAllowed,
  decodeJwtClaims,
  displayClaims,
  sidTag
} = require('../lib/security');

const MAX_TOKEN_LENGTH = 16 * 1024;

module.exports = function authRoutes({ store, config }) {
  const router = express.Router();

  router.use((req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  });

  const cookieOptions = req => ({
    httpOnly: true,
    sameSite: 'strict',
    path: '/',
    secure: config.cookieSecure === 'true' || (config.cookieSecure === 'auto' && isSecureRequest(req, config))
  });

  const statusBody = session =>
    session
      ? {
          signedIn: true,
          ...displayClaims(session.claims),
          sessionExpiresAt: new Date(session.expiresAt).toISOString()
        }
      : { signedIn: false };

  const rejectCrossOrigin = (req, res) => {
    if (originAllowed(req, config, { required: false })) return false;
    res.status(403).json({ error: 'Origin not allowed' });
    return true;
  };

  router.get('/session', (req, res) => {
    res.json(statusBody(store.get(readCookie(req))));
  });

  router.post('/session', (req, res) => {
    if (rejectCrossOrigin(req, res)) return;
    if (!req.is('application/json')) {
      return res.status(415).json({ error: 'Send the token as JSON: {"token": "<jwt>"}' });
    }

    let token = req.body && typeof req.body.token === 'string' ? req.body.token.trim() : '';
    token = token.replace(/^Bearer\s+/i, '');
    if (!token || token.length > MAX_TOKEN_LENGTH) {
      return res.status(400).json({ error: 'A JWT is required' });
    }

    const claims = decodeJwtClaims(token);
    if (!claims) {
      return res.status(400).json({ error: 'That does not look like a JWT (header.payload.signature)' });
    }
    if (typeof claims.exp === 'number' && claims.exp * 1000 <= Date.now()) {
      return res.status(400).json({ error: 'This token has expired. Mint a new one and sign in again.' });
    }

    // Signing in again replaces the previous session (and closes its connections).
    const previous = readCookie(req);
    if (previous) store.destroy(previous, 'Signed in again');

    const session = store.create(token, claims);
    token = null;

    res.cookie(COOKIE_NAME, session.id, {
      ...cookieOptions(req),
      maxAge: Math.max(0, session.expiresAt - Date.now())
    });
    console.log(`[auth] sign-in sub=${displayClaims(claims).sub || '-'} sid=${sidTag(session.id)}`);
    res.json(statusBody(session));
  });

  router.delete('/session', (req, res) => {
    if (rejectCrossOrigin(req, res)) return;
    const id = readCookie(req);
    const session = store.get(id);
    if (session) {
      console.log(`[auth] sign-out sub=${displayClaims(session.claims).sub || '-'} sid=${sidTag(id)}`);
    }
    if (id) store.destroy(id, 'Signed out');
    res.clearCookie(COOKIE_NAME, cookieOptions(req));
    res.json({ signedIn: false });
  });

  return router;
};
