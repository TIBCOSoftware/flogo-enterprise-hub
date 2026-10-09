#!/usr/bin/env python3
"""Rung 3 (orchestrated variant): call BankOpsSpecialists (and BankOpsMCPServer) directly - no orchestrator LLM - to
prove agent-to-agent security holds at the MCP edge:
  - token boundaries: each server accepts only tokens signed with its own secret
  - per-specialist scopes: the orchestrator sees only the specialists its token permits
  - registry gate: an unknown or suspended orchestrator is refused BEFORE any specialist runs (no LLM call)
  - privileges are never borrowed: a delegated request still runs under the specialist's own ID
The last three checks call real specialist agents (LLM). Start BankOpsMCPServer, BankOpsSpecialists first, then:
  JWT_SECRET=... SPECIALISTS_JWT_SECRET=... PG_PWD=... python orchestrated/_rebuild/mcp_smoke_orchestrated.py
Resets the DB before and after."""
import csv, io, json, os, subprocess, sys, urllib.error, urllib.request
from orch_common import SAMPLE_DIR, SPECIALISTS_URL, BANK_MCP_URL, secret
from mint_agent_tokens import mint

BANK, SPEC = secret("JWT_SECRET"), secret("SPECIALISTS_JWT_SECRET")
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

class Client:
    def __init__(self, url, token):
        self.url, self.token, self.session, self.seq = url, token, None, 0
    def rpc(self, method, params=None, notify=False, timeout=200):
        body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            self.seq += 1; body["id"] = self.seq
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token: h["Authorization"] = "Bearer " + self.token
        if self.session: h["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, json.dumps(body).encode(), method="POST", headers=h)
        with urllib.request.urlopen(req, timeout=timeout) as r:
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
    def ask(self, tool, request):
        res = self.rpc("tools/call", {"name": tool, "arguments": {"request": request}})
        text = res["content"][0]["text"]
        try:
            body = json.loads(text)
            return body.get("data", text) if isinstance(body, dict) else text
        except ValueError:
            return text

def status(url, token):
    try:
        Client(url, token).open(); return 200
    except urllib.error.HTTPError as e: return e.code

reset()
orch = mint("agt-orchestrator-01", SPEC)
# --- token boundaries between the two servers
check("specialists server: no token -> 401", status(SPECIALISTS_URL, None) == 401)
check("specialists server: orchestrator token signed with the BANK secret -> 401", status(SPECIALISTS_URL, mint("agt-orchestrator-01", BANK)) == 401)
check("specialists server: a specialist's bank token is rejected -> 401", status(SPECIALISTS_URL, mint("agt-servicing-01", BANK)) == 401)
check("bank server: the orchestrator's token is rejected -> 401 (it holds no bank access)", status(BANK_MCP_URL, orch) == 401)

# --- per-specialist scopes
c = Client(SPECIALISTS_URL, orch).open()
check("orchestrator sees both specialists", c.tools() == ["ask_insight_agent", "ask_servicing_agent"], c.tools())
ci = Client(SPECIALISTS_URL, mint("agt-orchestrator-01", SPEC, scopes=["agent:insight"])).open()
check("an insight-only orchestrator token sees only ask_insight_agent", ci.tools() == ["ask_insight_agent"], ci.tools())
try:
    r = ci.rpc("tools/call", {"name": "ask_servicing_agent", "arguments": {"request": "block CARD-4421"}})
    refused = bool(r.get("isError"))
except RuntimeError as e:
    refused, r = True, e
check("...and calling the hidden ask_servicing_agent is refused", refused, r)

# --- registry gate (no LLM call: the specialist never runs)
r = Client(SPECIALISTS_URL, mint("agt-rogue-77", SPEC, scopes=["agent:insight", "agent:servicing"])).open() \
    .ask("ask_servicing_agent", "Block CARD-4421, it was stolen.")
check("unregistered caller with valid scopes -> DELEGATION_REFUSED: UNKNOWN_AGENT", "DELEGATION_REFUSED: UNKNOWN_AGENT" in r, r)
q("UPDATE agent_identities SET status='SUSPENDED' WHERE agent_id='agt-orchestrator-01'")
r = c.ask("ask_servicing_agent", "Block CARD-4421, it was stolen.")
check("kill switch: suspended orchestrator -> DELEGATION_REFUSED: AGENT_SUSPENDED", "DELEGATION_REFUSED: AGENT_SUSPENDED" in r, r)
check("...the specialist never ran (no bank call by agt-servicing-01)", v("SELECT count(*) FROM agent_audit WHERE agent_id='agt-servicing-01'") == "0")
q("UPDATE agent_identities SET status='ACTIVE' WHERE agent_id='agt-orchestrator-01'")

# --- real delegations (LLM)
r = c.ask("ask_insight_agent", "Give me the account summary for ACC-1001.")
check("delegated read: insight agent answers with the real balance", "48,250" in r or "48250" in r, r)
check("...audited as orchestrator->ask_insight_agent and agt-insight-01->get_account_summary",
      v("SELECT count(*) FROM agent_audit WHERE agent_id='agt-orchestrator-01' AND tool='ask_insight_agent' AND decision='ALLOWED'") == "1"
      and int(v("SELECT count(*) FROM agent_audit WHERE agent_id='agt-insight-01' AND tool='get_account_summary' AND decision='ALLOWED'")) >= 1)
r = c.ask("ask_servicing_agent", "The customer on ACC-1001 lost the debit card ending 4421. Block it.")
check("delegated action: CARD-4421 blocked by agt-servicing-01 (the specialist's own ID)",
      v("SELECT status || '/' || coalesce(blocked_by,'') FROM cards WHERE card_id='CARD-4421'") == "BLOCKED/agt-servicing-01", r)
q("UPDATE agent_identities SET status='SUSPENDED' WHERE agent_id='agt-servicing-01'")
r = c.ask("ask_servicing_agent", "Card CARD-9013 on ACC-1001 looks compromised. Block it.")
check("privileges are not borrowed: delegation allowed, but the suspended specialist's bank call is refused",
      v("SELECT status FROM cards WHERE card_id='CARD-9013'") == "ACTIVE"
      and int(v("SELECT count(*) FROM agent_audit WHERE agent_id='agt-servicing-01' AND decision='DENIED' AND reason='AGENT_SUSPENDED'")) >= 1, r)

print("\naudit trail:")
for x in q("SELECT agent_id, tool, decision, reason FROM agent_audit ORDER BY audit_id"):
    print(f"  {x['agent_id']:<20} {x['tool']:<24} {x['decision']:<17} {x['reason']}")
reset()
print(f"\n{'AGENT-TO-AGENT EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
