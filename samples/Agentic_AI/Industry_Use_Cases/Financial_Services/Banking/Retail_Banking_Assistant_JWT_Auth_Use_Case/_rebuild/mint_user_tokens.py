#!/usr/bin/env python3
"""Mint one HS256 JWT per demo persona - the stand-in for Kestrel Bank's identity provider.

  JWT_SECRET=<same secret as MCP.JWT_Secret> python _rebuild/mint_user_tokens.py [hours=8] [persona ...] [options]

  personas   keys of tool_spec.PERSONAS (james, olivia, william, sophia, benjamin, emma, michael, patricia,
             james_view = James on a view-only channel, maya, daniel, priya). Default: all of them.
  --json          print {"<persona>": {"sub": ..., "name": ..., "scp": [...], "token": ...}, ...} instead of lines
  --expired       mint tokens that expired an hour ago (negative tests: the MCP trigger must answer 401)
  --wrong-secret  sign with a secret that is NOT JWT_SECRET (negative tests: the MCP trigger must answer 401)

Default output, one line per persona:   <persona> <TAB> <sub> <TAB> <token>
Claims: iss kestrel-bank-idp, aud ["retail-banking-mcp"], sub (customer id or staff id), name, scp (array of scopes),
iat, exp. Importable: mint(persona_or_sub, secret, hours=8, ...) for the test scripts.

Production: the bank's OAuth 2.0 / OIDC identity provider issues the token and the MCP Server trigger validates it
against the IdP's JWKS (Authentication Type = OAuth 2.0) instead of a shared secret. Standard library only; the
secret is read from the environment variable JWT_SECRET only (never from a file, never printed)."""
import base64, hashlib, hmac, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import PERSONAS

ISSUER, AUDIENCE = "kestrel-bank-idp", "retail-banking-mcp"
WRONG_SECRET = "not-the-kestrel-bank-signing-secret"


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def claims_for(persona, hours=8, now=None, scopes=None, sub=None, name=None, **extra):
    """The claim set for a persona key (or an ad-hoc subject when the key is unknown)."""
    now = int(now if now is not None else time.time())
    p = PERSONAS.get(persona, {"sub": persona, "name": persona, "scp": []})
    c = {"iss": ISSUER, "aud": [AUDIENCE], "sub": sub or p["sub"], "name": name or p["name"],
         "scp": list(scopes if scopes is not None else p["scp"]), "iat": now, "exp": now + int(hours * 3600)}
    c.update(extra)                    # tests may override / add claims (e.g. iss, aud, scope)
    return c


def sign(claims, secret):
    head = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = _b64(json.dumps(claims, separators=(",", ":")).encode())
    sig = _b64(hmac.new(secret.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
    return f"{head}.{body}.{sig}"


def mint(persona, secret, hours=8, now=None, scopes=None, **extra):
    """HS256 JWT for a persona key from tool_spec.PERSONAS (or any other string, used as the sub with no scopes).
    hours < 0 gives an already-expired token. extra claims override the defaults (e.g. aud=["other"])."""
    return sign(claims_for(persona, hours, now, scopes, **extra), secret)


def main(argv):
    as_json = "--json" in argv
    expired = "--expired" in argv
    wrong = "--wrong-secret" in argv
    args = [a for a in argv if not a.startswith("--")]
    unknown = [a for a in argv if a.startswith("--") and a not in ("--json", "--expired", "--wrong-secret")]
    if unknown:
        sys.exit(f"unknown option(s): {' '.join(unknown)}\n\n{__doc__}")
    secret = os.environ.get("JWT_SECRET") or sys.exit("set JWT_SECRET (the HS256 secret = the MCP.JWT_Secret app property)")
    hours = 8.0
    if args and args[0].replace(".", "", 1).isdigit():
        hours = float(args.pop(0))
    personas = args or list(PERSONAS)
    bad = [p for p in personas if p not in PERSONAS]
    if bad:
        sys.exit(f"unknown persona(s): {', '.join(bad)}. Known: {', '.join(PERSONAS)}")
    if expired:
        hours = -1.0
    if wrong:
        secret = WRONG_SECRET
    out = {}
    for p in personas:
        out[p] = {"sub": PERSONAS[p]["sub"], "name": PERSONAS[p]["name"], "scp": PERSONAS[p]["scp"],
                  "token": mint(p, secret, hours)}
    if as_json:
        print(json.dumps(out, indent=2))
    else:
        for p, v in out.items():
            print(f"{p}\t{v['sub']}\t{v['token']}")


if __name__ == "__main__":
    main(sys.argv[1:])
