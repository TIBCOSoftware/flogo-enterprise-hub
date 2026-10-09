#!/usr/bin/env python3
"""Step 3: call the running BankOpsMCPServer with each agent's real JWT - no LLM - and prove both layers hold:
  layer 1 (Flogo MCP trigger): no/forged/expired token rejected; tools without the token's scope are hidden
  layer 2 (agent registry in PostgreSQL): suspended / unknown identities are refused even with a valid token
Start BankOpsMCPServer first, then:   JWT_SECRET=... PG_PWD=... python _rebuild/mcp_smoke.py
Resets the DB before and after (reset_data.sql)."""
import csv, io, json, os, subprocess, sys, urllib.error, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mint_agent_tokens import mint

URL = os.environ.get("MCP_URL", "http://localhost:9871/bankops-mcp")
SECRET = os.environ["JWT_SECRET"]
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"), "-d", "bankops_agents", "-q"]
fails = 0

def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:300]}"))
    fails += 0 if cond else 1

class Client:
    def __init__(self, token):
        self.token, self.session, self.seq = token, None, 0
    def rpc(self, method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            self.seq += 1; body["id"] = self.seq
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token: h["Authorization"] = "Bearer " + self.token
        if self.session: h["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(URL, json.dumps(body).encode(), method="POST", headers=h)
        with urllib.request.urlopen(req, timeout=30) as r:
            self.session = r.headers.get("Mcp-Session-Id") or self.session
            raw = r.read().decode()
        if notify or not raw.strip(): return None
        data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
        msg = json.loads(data[-1])
        if "error" in msg: raise RuntimeError(msg["error"])
        return msg["result"]
    def open(self):
        self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
        self.rpc("notifications/initialized", notify=True)
        return self
    def tools(self): return sorted(t["name"] for t in self.rpc("tools/list")["tools"])
    def call(self, tool, **args):
        res = self.rpc("tools/call", {"name": tool, "arguments": args})
        if res.get("isError"): return {"isError": True, "text": res["content"][0]["text"]}
        body = json.loads(res["content"][0]["text"])
        return (json.loads(body["data"]) if "data" in body else body)["records"]

def http_status(token):
    try:
        Client(token).open(); return 200
    except urllib.error.HTTPError as e: return e.code

reset()
# --- layer 1: the Flogo MCP Server trigger validates the token
check("no token -> 401", http_status(None) == 401, http_status(None))
forged = mint("agt-servicing-01", "not-the-bank-secret")
check("token signed with the wrong secret -> 401", http_status(forged) == 401, http_status(forged))
expired = mint("agt-servicing-01", SECRET, days=-1)
st = http_status(expired)
check("expired token -> 401", st == 401, st)

ins = Client(mint("agt-insight-01", SECRET)).open()
svc = Client(mint("agt-servicing-01", SECRET)).open()
check("insight token sees only its 3 tools", ins.tools() == ["get_account_summary", "list_recent_transactions", "whoami"], ins.tools())
check("servicing token sees all 6 tools", len(svc.tools()) == 6, svc.tools())
try:
    r = ins.call("block_card", card_id="CARD-4421", reason="calling a hidden tool directly")
    hidden_refused = isinstance(r, dict) and r.get("isError")
except RuntimeError as e:
    hidden_refused, r = True, e
check("insight token calling hidden block_card directly is refused", hidden_refused, r)
check("...and CARD-4421 is still ACTIVE", q("SELECT status FROM cards WHERE card_id='CARD-4421'")[0]["status"] == "ACTIVE")

# --- identity comes from the token, not from the model
r = ins.call("whoami")[0]
check("whoami resolves agt-insight-01 from the JWT sub", r["agent_id"] == "agt-insight-01" and r["status"] == "ACTIVE", r)
check("whoami shows the token's scopes", "accounts:read" in (r["token_scopes"] or ""), r)
r = ins.call("get_account_summary", account_id="ACC-1001")[0]
check("insight reads ACC-1001", r["access"] == "GRANTED" and r["customer_name"] == "Mei Lin Wong", r)

# --- layer 2: the registry refuses identities that a valid token alone does not make legitimate
leg = Client(mint("agt-legacy-07", SECRET)).open()
r = leg.call("get_account_summary", account_id="ACC-1001")[0]
check("suspended agent with a VALID token -> DENIED AGENT_SUSPENDED", r["access"] == "DENIED" and r["reason"] == "AGENT_SUSPENDED", r)
rogue = Client(mint("agt-rogue-99", SECRET, scopes=["cards:block"])).open()
r = rogue.call("block_card", card_id="CARD-7788", reason="rogue")[0]
check("token for an unregistered agent -> UNKNOWN_AGENT, nothing blocked",
      r["outcome"] == "NOT_EXECUTED" and r["reason"] == "UNKNOWN_AGENT", r)
check("...CARD-7788 still ACTIVE", q("SELECT status FROM cards WHERE card_id='CARD-7788'")[0]["status"] == "ACTIVE")

# --- the servicing agent can act, but privileged changes wait for a person
r = svc.call("block_card", card_id="CARD-4421", reason="customer reported it lost")[0]
check("servicing agent blocks CARD-4421", r["outcome"] == "CARD_BLOCKED" and r["blocked_by"] == "agt-servicing-01", r)
r = svc.call("request_limit_increase", account_id="ACC-1001", new_daily_limit="25000", justification="property deposit")[0]
check("limit increase -> SUBMITTED_FOR_HUMAN_APPROVAL", r["outcome"] == "SUBMITTED_FOR_HUMAN_APPROVAL" and r["request_id"], r)
check("...limit unchanged at 10000", q("SELECT daily_transfer_limit AS l FROM accounts WHERE account_id='ACC-1001'")[0]["l"] == "10000.00")

# --- kill switch: suspend in the registry, the same token stops working at once
q("UPDATE agent_identities SET status='SUSPENDED' WHERE agent_id='agt-servicing-01'")
r = svc.call("block_card", card_id="CARD-9013", reason="after suspension")[0]
check("kill switch: same token, now AGENT_SUSPENDED", r["outcome"] == "NOT_EXECUTED" and r["reason"] == "AGENT_SUSPENDED", r)

a = q("SELECT agent_id, tool, decision, reason FROM agent_audit ORDER BY audit_id")
# 7 rows: the hidden-tool call never reaches a flow - the trigger refuses it before any SQL runs
check("every call that reached a flow is audited (7) with the token's agent id", len(a) == 7 and {x["agent_id"] for x in a} >=
      {"agt-insight-01", "agt-servicing-01", "agt-legacy-07", "agt-rogue-99"}, a)
print("\naudit trail:")
for x in a: print(f"  {x['agent_id']:<17} {x['tool']:<24} {x['decision']:<17} {x['reason']}")

reset()
print(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
