#!/usr/bin/env python3
"""Rung 3 (no-MCP variant): call the Flogo BankAPIGateway (identity provider + API gateway stand-in) directly - no
LLM, no MCP - and prove the agent -> API controls hold at the gateway, using the same OAuth client-credentials flow
the Flogo agents use. Start BankAPIGateway first, then:
  GATEWAY_SIGNING_KEY=... GATEWAY_CLIENTS_FILE=<file with "client_id | secret | scopes" lines> PG_PWD=...   python no-mcp/_rebuild/gateway_smoke.py
(the clients file is what `SELECT * FROM register_agent_client(...)` printed, one row per agent)
Resets the DB before and after (../../reset_data.sql)."""
import base64, csv, hashlib, hmac, io, json, os, subprocess, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE_DIR = os.path.dirname(os.path.dirname(HERE))
ISSUER, AUDIENCE = "harbor-bank-idp", "harbor-bank-api"
KEY = os.environ["GATEWAY_SIGNING_KEY"]
REG = {"signing_key": KEY, "clients": {}}
for line in open(os.environ["GATEWAY_CLIENTS_FILE"], encoding="utf-8"):
    if line.count("|") >= 2:
        cid, sec, scopes = [x.strip() for x in line.split("|")[:3]]
        REG["clients"][cid] = {"secret": sec, "scopes": scopes.split()}


def _b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class gw:  # minimal HS256 signer, to forge expired / wrong-key / wrong-audience tokens
    ISSUER, AUDIENCE = ISSUER, AUDIENCE
    @staticmethod
    def sign(claims, key):
        h = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
        b = _b64(json.dumps(claims, separators=(",", ":")).encode())
        return f"{h}.{b}." + _b64(hmac.new(key.encode(), f"{h}.{b}".encode(), hashlib.sha256).digest())

URL = os.environ.get("BANK_GATEWAY_URL", "http://127.0.0.1:9895")
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"), "-d", "bankops_agents", "-q"]
fails = 0

def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))
def v(sql): return list(q(sql)[0].values())[0]
def reset(): subprocess.run(BASE + ["-f", os.path.join(SAMPLE_DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:300]}"))
    fails += 0 if cond else 1

def http(method, path, token=None, body=None, headers=None, form=None):
    h = dict(headers or {})
    data = None
    if form is not None:
        data = form.encode(); h["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    if token: h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(URL + path, data, method=method, headers=h)
    try:
        r = urllib.request.urlopen(req, timeout=30); return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)

def token(cid, secret=None):
    basic = base64.b64encode(f"{cid}:{secret or REG['clients'][cid]['secret']}".encode()).decode()
    return http("POST", "/oauth/token", headers={"Authorization": "Basic " + basic}, form="grant_type=client_credentials")

reset()
# --- the identity provider: each agent is its own OAuth client
st, r = token("agt-insight-01")
check("insight agent gets a token with ONLY its scopes", st == 200 and r["scope"] == "accounts:read txns:read", r)
ins = r["access_token"]
st, r = token("agt-insight-01", "wrong-secret")
check("wrong client secret -> 401 invalid_client", st == 401 and r["error"] == "invalid_client", r)
st, r = token("agt-made-up", "x")
check("unknown client -> 401 invalid_client", st == 401, r)
svc = token("agt-servicing-01")[1]["access_token"]

# --- the gateway: token validation
check("no token -> 401", http("GET", "/api/accounts/ACC-1001")[0] == 401)
forged = gw.sign({"iss": gw.ISSUER, "sub": "agt-servicing-01", "aud": [gw.AUDIENCE], "scp": ["cards:block"],
                  "iat": int(time.time()), "exp": int(time.time()) + 600}, "not-the-bank-key")
check("forged token (wrong signing key) -> 401", http("POST", "/api/cards/CARD-4421/block", forged, {"reason": "x"})[0] == 401)
expired = gw.sign({"iss": gw.ISSUER, "sub": "agt-servicing-01", "aud": [gw.AUDIENCE], "scp": ["cards:block"],
                   "iat": int(time.time()) - 1200, "exp": int(time.time()) - 600}, REG["signing_key"])
check("expired token -> 401", http("POST", "/api/cards/CARD-4421/block", expired, {"reason": "x"})[0] == 401)
wrong_aud = gw.sign({"iss": gw.ISSUER, "sub": "agt-servicing-01", "aud": ["some-other-api"], "scp": ["cards:block"],
                     "iat": int(time.time()), "exp": int(time.time()) + 600}, REG["signing_key"])
check("token for another audience -> 401", http("POST", "/api/cards/CARD-4421/block", wrong_aud, {"reason": "x"})[0] == 401)

# --- least privilege by scope, enforced by the gateway (not the agent)
st, r = http("GET", "/api/accounts/ACC-1001", ins)
check("insight reads ACC-1001", st == 200 and r["records"][0]["access"] == "GRANTED", r)
st, r = http("POST", "/api/cards/CARD-4421/block", ins, {"reason": "lost"})
check("insight token on the block endpoint -> 403 insufficient_scope (cards:block)",
      st == 403 and r.get("required_scope") == "cards:block", r)
check("...card still ACTIVE, refusal audited as MISSING_SCOPE",
      v("SELECT status FROM cards WHERE card_id='CARD-4421'") == "ACTIVE" and
      v("SELECT count(*) FROM agent_audit WHERE agent_id='agt-insight-01' AND reason='MISSING_SCOPE_cards:block'") == "1")

# --- the registry still decides (kill switch) even with a valid token and scope
leg = token("agt-legacy-07")[1]["access_token"]
st, r = http("GET", "/api/accounts/ACC-1001", leg)
check("suspended agent with a valid token and scope -> DENIED AGENT_SUSPENDED", st == 200 and
      r["records"][0]["access"] == "DENIED" and r["records"][0]["reason"] == "AGENT_SUSPENDED", r)

# --- the servicing agent can act; privileged changes wait for a person
st, r = http("POST", "/api/cards/CARD-4421/block", svc, {"reason": "customer reported it lost"})
check("servicing blocks CARD-4421 (blocked_by = its own client id)", st == 200 and r["records"][0]["outcome"] == "CARD_BLOCKED"
      and r["records"][0]["blocked_by"] == "agt-servicing-01", r)
st, r = http("POST", "/api/accounts/ACC-1001/limit-requests", svc, {"new_daily_limit": "25000", "justification": "deposit"})
check("limit increase -> SUBMITTED_FOR_HUMAN_APPROVAL, limit unchanged", st == 200 and
      r["records"][0]["outcome"] == "SUBMITTED_FOR_HUMAN_APPROVAL" and
      v("SELECT daily_transfer_limit FROM accounts WHERE account_id='ACC-1001'") == "10000.00", r)
q("UPDATE agent_identities SET status='SUSPENDED' WHERE agent_id='agt-servicing-01'")
st, r = http("POST", "/api/cards/CARD-9013/block", svc, {"reason": "compromised"})
check("kill switch: same token, now AGENT_SUSPENDED", r["records"][0]["outcome"] == "NOT_EXECUTED"
      and r["records"][0]["reason"] == "AGENT_SUSPENDED", r)

print("\naudit trail:")
for x in q("SELECT agent_id, tool, target, decision, reason FROM agent_audit ORDER BY audit_id"):
    print(f"  {x['agent_id']:<17} {x['tool']:<24} {x['target'] or '':<10} {x['decision']:<17} {x['reason']}")
reset()
print(f"\n{'GATEWAY EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
