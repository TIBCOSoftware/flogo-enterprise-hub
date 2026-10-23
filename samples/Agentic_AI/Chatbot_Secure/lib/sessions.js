/**
 * In-memory server-side session store (demo only).
 * Maps a random session id (the HttpOnly cookie value) to the user's JWT.
 * The browser never holds the token after sign-in.
 *
 * Production: use a shared store (e.g. Redis) and obtain the token from a real
 * OIDC login instead of a pasted JWT.
 */

const crypto = require('crypto');

class SessionStore {
  constructor({ ttlMs }) {
    this.ttlMs = ttlMs;
    this.sessions = new Map();
    this.sweeper = setInterval(() => this.sweep(), 60 * 1000);
    this.sweeper.unref();
  }

  create(token, claims) {
    const id = crypto.randomBytes(32).toString('base64url');
    const now = Date.now();
    let expiresAt = now + this.ttlMs;
    if (typeof claims.exp === 'number') expiresAt = Math.min(expiresAt, claims.exp * 1000);
    const session = { id, token, claims, createdAt: now, expiresAt, connections: new Set() };
    this.sessions.set(id, session);
    return session;
  }

  /** Return a live session, or null if missing/expired. */
  get(id) {
    if (!id) return null;
    const session = this.sessions.get(id);
    if (!session) return null;
    if (Date.now() >= session.expiresAt) {
      this.destroy(id, 'Session expired');
      return null;
    }
    return session;
  }

  /** Remove a session and close every proxied connection that belongs to it. */
  destroy(id, reason = 'Signed out') {
    const session = this.sessions.get(id);
    if (!session) return false;
    this.sessions.delete(id);
    for (const close of session.connections) {
      try {
        close(reason);
      } catch (e) {
        /* ignore */
      }
    }
    session.connections.clear();
    session.token = null;
    return true;
  }

  sweep() {
    const now = Date.now();
    for (const [id, session] of this.sessions) {
      if (now >= session.expiresAt) this.destroy(id, 'Session expired');
    }
  }
}

module.exports = { SessionStore };
