/**
 * Small security helpers: cookie parsing, origin checks, JWT claim decoding.
 * No token is ever logged or returned by these helpers.
 */

const COOKIE_NAME = 'cbs_sid';

/** Read one cookie value from a raw Cookie header. */
function readCookie(req, name = COOKIE_NAME) {
  const header = req.headers.cookie;
  if (!header) return null;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    if (part.slice(0, idx).trim() === name) {
      try {
        return decodeURIComponent(part.slice(idx + 1).trim());
      } catch (e) {
        return null;
      }
    }
  }
  return null;
}

/** True when the request reached us over HTTPS (directly or via a trusted proxy). */
function isSecureRequest(req, config) {
  if (req.socket && req.socket.encrypted) return true;
  if (config.trustProxy) {
    const proto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim().toLowerCase();
    return proto === 'https';
  }
  return false;
}

/** Origins the browser is allowed to call us from. */
function expectedOrigins(req, config) {
  if (config.allowedOrigins.length) return config.allowedOrigins;
  const host = String(req.headers.host || '').toLowerCase();
  if (!host) return [];
  return [`${isSecureRequest(req, config) ? 'https' : 'http'}://${host}`];
}

/**
 * Origin check. Browsers always send Origin on WebSocket handshakes and on
 * POST/DELETE fetches, so `required` is used for the WebSocket upgrade.
 */
function originAllowed(req, config, { required }) {
  const origin = req.headers.origin;
  if (!origin) return !required;
  return expectedOrigins(req, config).includes(String(origin).toLowerCase());
}

function b64urlJson(segment) {
  const json = Buffer.from(segment, 'base64url').toString('utf8');
  const value = JSON.parse(json);
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

/**
 * Decode (NOT verify) a compact JWT and return its payload claims, or null when
 * the string is not shaped like a JWT. Signature verification is done by the
 * Flogo MCP server; this is only for display and session expiry.
 */
function decodeJwtClaims(token) {
  if (typeof token !== 'string') return null;
  if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$/.test(token)) return null;
  const [header, payload] = token.split('.');
  try {
    if (!b64urlJson(header)) return null;
    return b64urlJson(payload);
  } catch (e) {
    return null;
  }
}

/** Non-secret claims safe to show in the UI. */
function displayClaims(claims) {
  const str = v => (typeof v === 'string' || typeof v === 'number' ? String(v) : null);
  let scp = claims.scp !== undefined ? claims.scp : claims.scope;
  if (typeof scp === 'string') scp = scp.split(/\s+/).filter(Boolean);
  if (!Array.isArray(scp)) scp = [];
  return {
    sub: str(claims.sub),
    name: str(claims.name),
    scp: scp.map(String),
    exp: typeof claims.exp === 'number' ? claims.exp : null
  };
}

/** The token's sub for log lines. It is unverified here, so control characters (forged log lines) are replaced
 *  and the length is capped. */
function logSub(claims) {
  const sub = displayClaims(claims).sub;
  if (!sub) return '-';
  const clean = sub.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, '?');
  return clean.length > 128 ? `${clean.slice(0, 128)}...` : clean;
}

/** Short, non-reversible session id prefix for logs. */
function sidTag(id) {
  return id ? `${String(id).slice(0, 6)}...` : '-';
}

module.exports = {
  COOKIE_NAME,
  readCookie,
  isSecureRequest,
  originAllowed,
  decodeJwtClaims,
  displayClaims,
  logSub,
  sidTag
};
