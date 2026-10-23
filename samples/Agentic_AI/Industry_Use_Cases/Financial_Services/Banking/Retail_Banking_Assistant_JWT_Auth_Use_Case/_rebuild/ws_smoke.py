#!/usr/bin/env python3
"""Step 3: quick WebSocket check of RetailBankingSecureOrchestrator before the full chat e2e.

  python _rebuild/ws_smoke.py --no-auth-only   # orchestrator alone: the sign-in guard (no LLM call, no MCP needed)
  python _rebuild/ws_smoke.py                  # all three apps running: guard + a signed-in turn + an expired token

Checks
  1. no Authorization header              -> fixed "please sign in" reply, fast (no LLM call)
  2. JWT only as a ?token= query param    -> same sign-in reply (the token is read from the header only)
  3. Authorization: Bearer <valid JWT>    -> the assistant answers and says it is an AI   (skipped by --no-auth-only)
  4. Authorization: Bearer <expired JWT>  -> MCP rejects it (401) -> fixed "sign in again" reply (skipped likewise)

The JWT is minted here with the stdlib (HS256), as the bank's identity provider would: iss kestrel-bank-idp,
aud ["retail-banking-mcp"], sub CUST-2026-00101 (James Miller), the full customer scopes.
Env: WS_URL (default ws://localhost:9970/retailbanking), JWT_SECRET (= the MCP app's MCP.JWT_Secret; needed for
checks 3-4), REPLY_TIMEOUT (default 150 s). No DB state is changed. Requires: pip install websocket-client"""
import base64, hashlib, hmac, json, os, re, sys, time
import websocket   # pip install websocket-client

WS = os.environ.get("WS_URL", "ws://localhost:9970/retailbanking")
TIMEOUT = int(os.environ.get("REPLY_TIMEOUT", "150"))
SECRET = os.environ.get("JWT_SECRET", "")
NO_AUTH_ONLY = "--no-auth-only" in sys.argv[1:]
CUSTOMER_SCOPES = ("profile:read accounts:read transactions:read cards:read loans:read payees:read cases:read "
                   "branches:read cards:block disputes:write payments:write cases:write email:send").split()
SIGN_IN = re.compile(r"please sign in", re.I)
SIGN_IN_AGAIN = re.compile(r"not valid or has expired", re.I)
fails = 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

def check(label, cond, detail=""):
    global fails
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:300]}"))
    fails += 0 if cond else 1

def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def mint(sub="CUST-2026-00101", name="James Miller", scopes=CUSTOMER_SCOPES, ttl=3600, iat=None):
    """HS256 JWT signed with JWT_SECRET (stdlib only)."""
    iat = int(time.time()) if iat is None else iat
    head = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64url(json.dumps({"iss": "kestrel-bank-idp", "aud": ["retail-banking-mcp"], "sub": sub, "name": name,
                              "scp": list(scopes), "iat": iat, "exp": iat + ttl}, separators=(",", ":")).encode())
    sig = hmac.new(SECRET.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest()
    return f"{head}.{body}.{b64url(sig)}"

def turn(label, text, url=WS, header=None, timeout=TIMEOUT):
    """Open one connection, send one message, return (reply, seconds). Never prints the token."""
    try:
        ws = websocket.create_connection(url, timeout=timeout, header=header or [])
    except Exception as e:
        check(f"{label}: connect", False, f"{type(e).__name__}: {e}")
        return "", 0.0
    t, reply = time.time(), ""
    try:
        ws.send(text)
        reply = ws.recv()
        if isinstance(reply, bytes): reply = reply.decode("utf-8", errors="replace")
    except websocket.WebSocketTimeoutException:
        out(f"  ! {label}: no reply within {timeout}s")
    finally:
        ws.close()
    secs = time.time() - t
    out(f"  < {label} ({secs:.1f}s) " + reply[:300].replace("\n", " "))
    return reply, secs

# 1. no Authorization header -> sign-in reply without an LLM call (so it is fast)
reply, secs = turn("no header", "Hi, what's my checking balance?", timeout=30)
check("no Authorization header -> sign-in reply", bool(SIGN_IN.search(reply)), reply)
check("no Authorization header -> answered without an LLM call (< 5 s)", bool(reply) and secs < 5, f"{secs:.1f}s")

# 2. token only in the query string (or a non-Bearer scheme) -> still not signed in. Never verified, so no
#    JWT_SECRET needed: the orchestrator must not even look at it.
sep = "&" if "?" in WS else "?"
reply, _ = turn("query-param token", "Hi, what's my checking balance?", url=f"{WS}{sep}token={mint()}", timeout=30)
check("?token= query param is ignored -> sign-in reply", bool(SIGN_IN.search(reply)), reply)
reply, _ = turn("Basic scheme", "Hi", header=["Authorization: Basic dXNlcjpwYXNz"], timeout=30)
check("non-Bearer Authorization -> sign-in reply", bool(SIGN_IN.search(reply)), reply)
if not SECRET and not NO_AUTH_ONLY:
    out("SKIP checks 3-4: set JWT_SECRET (the MCP app's MCP.JWT_Secret) to mint tokens the MCP server accepts")

# 3 + 4 need the MCP server and the A2A agents
if SECRET and not NO_AUTH_ONLY:
    reply, _ = turn("signed in", "Hello, are you an AI assistant?", header=[f"Authorization: Bearer {mint()}"])
    check(f"signed in -> non-empty reply within {TIMEOUT}s", bool(reply.strip()))
    check("signed in -> reply says it is an AI",
          re.search(r"\bai\b|artificial|virtual assistant|automated", reply.lower()) is not None, reply)
    check("signed in -> not a sign-in error", not SIGN_IN.search(reply) and not SIGN_IN_AGAIN.search(reply), reply)
    expired = mint(iat=int(time.time()) - 7200, ttl=3600)
    reply, _ = turn("expired token", "What's my checking balance?", header=[f"Authorization: Bearer {expired}"])
    check("expired JWT -> 'sign in again' reply", bool(SIGN_IN_AGAIN.search(reply)), reply)

out(f"\n{'WEBSOCKET OK' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
