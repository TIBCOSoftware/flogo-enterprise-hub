#!/usr/bin/env python3
"""Issue one HS256 JWT per agent privilege ID - the stand-in for your identity provider / token service.

  JWT_SECRET=<same secret as MCP.JWT_Secret> python _rebuild/mint_agent_tokens.py [days=30] [agent ...]

Prints `agent_id <TAB> token`. Claims: iss, sub (= privilege ID), aud, name, scp (scopes), iat, exp.
In production the agent's token comes from your IdP (OAuth 2.0 client credentials) and the MCP Server trigger
validates it against the IdP's JWKS (Authentication Type = OAuth 2.0) instead of a shared secret.
No dependencies - standard library only."""
import base64, hashlib, hmac, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import AGENTS

ISSUER, AUDIENCE = "harbor-bank-agent-registry", "bankops-mcp"

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def mint(agent_id, secret, days=30, scopes=None, now=None):
    now = int(now or time.time())
    a = AGENTS.get(agent_id, {"name": agent_id, "scp": []})
    claims = {"iss": ISSUER, "sub": agent_id, "aud": [AUDIENCE], "name": a["name"],
              "scp": scopes if scopes is not None else a["scp"], "iat": now, "exp": now + int(days * 86400)}
    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64(json.dumps(claims, separators=(",", ":")).encode())
    sig = b64(hmac.new(secret.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
    return f"{head}.{body}.{sig}"

if __name__ == "__main__":
    secret = os.environ.get("JWT_SECRET") or sys.exit("set JWT_SECRET")
    # orchestrated variant: the orchestrator's token is for the SPECIALISTS server, signed with its own secret
    spec_secret = os.environ.get("SPECIALISTS_JWT_SECRET")
    args = sys.argv[1:]
    days = float(args.pop(0)) if args and args[0].replace(".", "").isdigit() else 30
    for agent in args or AGENTS:
        if agent == "agt-orchestrator-01":
            if not spec_secret:
                print(f"{agent}\t(skipped: set SPECIALISTS_JWT_SECRET to mint the orchestrator's token)")
                continue
            print(f"{agent}\t{mint(agent, spec_secret, days)}")
        else:
            print(f"{agent}\t{mint(agent, secret, days)}")
