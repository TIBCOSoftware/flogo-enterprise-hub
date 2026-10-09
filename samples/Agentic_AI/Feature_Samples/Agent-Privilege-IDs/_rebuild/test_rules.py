#!/usr/bin/env python3
"""Step 1: run the EXACT tool SQL from tool_spec.py against bankops_agents and assert the privilege rules.
No Flogo, no LLM. The agent id is bound the way the MCP flows bind it (from the token), never from an argument.
Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> python _rebuild/test_rules.py          (PSQL / PG_HOST / PG_USER env vars override defaults)
"""
import csv, io, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "bankops_agents"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = 0

def lit(v): return "'" + str(v).replace("'", "''") + "'"

def sub(sql, params, agent, args):
    assert sorted(re.findall(r"\?(\w+)", sql)) == sorted(p for p, _ in params), sql
    for ph, src in params:
        val = agent if src == "sub" else ('["scopes"]' if src == "scopes" else args.get(src, ""))
        sql, n = re.subn(r"\?" + ph + r"(?=[\s;),])", lambda _m: lit(val), sql)
        assert n == 1, f"placeholder ?{ph} used {n} times"
    return sql

def psql(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: print(r.stderr); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def call(agent, tool, **args):
    t = T[tool]
    psql(sub(*t["write"], agent, args))
    return psql(sub(*t["read"], agent, args))

def one(sql): return psql(sql)[0]

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    fails += 0 if cond else 1

def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

INS, SVC, OLD = "agt-insight-01", "agt-servicing-01", "agt-legacy-07"
reset()

# identity
r = call(INS, "whoami")[0]
check("whoami: insight agent is ACTIVE with an accountable owner", r["status"] == "ACTIVE" and "priya" in r["owner"], r)
check("whoami: insight agent entitled to read tools only",
      r["entitled_tools"] == "get_account_summary, list_recent_transactions, whoami", r)
r = call(OLD, "whoami")[0]
check("whoami: legacy agent shows SUSPENDED", r["status"] == "SUSPENDED" and r["registry_check"] == "AGENT_SUSPENDED", r)
r = call("agt-made-up", "whoami")[0]
check("whoami: unknown agent id -> UNKNOWN", r["status"] == "UNKNOWN" and r["registry_check"] == "UNKNOWN_AGENT", r)

# least-privilege reads
r = call(INS, "get_account_summary", account_id="acc-1001")[0]
check("insight reads account summary", r["access"] == "GRANTED" and r["balance"] == "48250.75", r)
r = call(INS, "get_account_summary", account_id="ACC-9999")[0]
check("unknown account -> NOT_FOUND", r["access"] == "NOT_FOUND", r)
r = call(INS, "list_recent_transactions", account_id="ACC-1001")
check("insight lists 5 transactions, newest first", len(r) == 5 and r[0]["txn_id"] == "TXN-50001", r)
r = call(OLD, "get_account_summary", account_id="ACC-1001")[0]
check("suspended identity -> DENIED AGENT_SUSPENDED, no data", r["access"] == "DENIED" and r["reason"] == "AGENT_SUSPENDED"
      and not r["balance"], r)
r = call(OLD, "list_recent_transactions", account_id="ACC-1001")
check("legacy agent not entitled to transactions", len(r) == 1 and r[0]["reason"] == "AGENT_SUSPENDED", r)

# defence in depth: even if the token layer were bypassed, the registry refuses
r = call(INS, "block_card", card_id="CARD-4421", reason="lost")[0]
check("insight agent cannot block a card (NOT_ENTITLED)", r["outcome"] == "NOT_EXECUTED" and r["reason"] == "NOT_ENTITLED", r)
check("...and the card is still ACTIVE", one("SELECT status FROM cards WHERE card_id='CARD-4421'")["status"] == "ACTIVE")
r = call(INS, "request_limit_increase", account_id="ACC-1001", new_daily_limit="25000", justification="x")[0]
check("insight agent cannot request a limit change", r["outcome"] == "NOT_SUBMITTED" and r["reason"] == "NOT_ENTITLED", r)

# servicing agent: guarded write
r = call(SVC, "block_card", card_id="card-4421", reason="customer reported it lost")[0]
check("servicing agent blocks CARD-4421", r["outcome"] == "CARD_BLOCKED" and r["card_status"] == "BLOCKED"
      and r["blocked_by"] == SVC, r)
r = call(SVC, "block_card", card_id="CARD-4421", reason="again")[0]
check("block twice -> CARD_ALREADY_BLOCKED", r["outcome"] == "NOT_EXECUTED" and r["reason"] == "CARD_ALREADY_BLOCKED", r)
r = call(SVC, "block_card", card_id="CARD-0000", reason="?")[0]
check("unknown card -> NO_SUCH_CARD", r["reason"] == "NO_SUCH_CARD", r)

# privileged change -> human approval only
r = call(SVC, "request_limit_increase", account_id="ACC-1001", new_daily_limit="25000", justification="property deposit")[0]
check("limit request -> SUBMITTED_FOR_HUMAN_APPROVAL APR-1001", r["outcome"] == "SUBMITTED_FOR_HUMAN_APPROVAL"
      and r["request_id"] == "APR-1001" and r["request_status"] == "PENDING", r)
check("...and the limit has NOT changed", one("SELECT daily_transfer_limit AS l FROM accounts WHERE account_id='ACC-1001'")["l"] == "10000.00")
r = call(SVC, "request_limit_increase", account_id="ACC-1001", new_daily_limit="30000", justification="again")[0]
check("second request while one is pending -> REQUEST_ALREADY_PENDING", r["reason"] == "REQUEST_ALREADY_PENDING", r)
for amt, reason in [("500000", "ABOVE_POLICY_CAP_100000"), ("5000", "NOT_AN_INCREASE"), ("lots", "INVALID_AMOUNT")]:
    r = call(SVC, "request_limit_increase", account_id="ACC-1003", new_daily_limit=amt, justification="t")[0]
    check(f"limit {amt} on ACC-1003 -> {reason}", r["outcome"] == "NOT_SUBMITTED" and r["reason"] == reason, r)
r = call(SVC, "get_request_status", request_id="apr-1001")[0]
check("servicing agent sees APR-1001 PENDING", r["access"] == "GRANTED" and r["status"] == "PENDING", r)

def approve(req, who, ok=True):
    return one(f"SELECT * FROM approve_request({lit(req)}, {lit(who)}, {'true' if ok else 'false'}, 'checked with customer')")
r = approve("APR-1001", SVC)
check("an agent cannot approve (AGENTS_CANNOT_APPROVE)", r["outcome"] == "NOT_DECIDED" and r["reason"] == "AGENTS_CANNOT_APPROVE", r)
r = approve("APR-1001", "bob")
check("unknown person cannot approve", r["reason"] == "NOT_AN_AUTHORISED_APPROVER", r)
r = approve("APR-1001", "analyst.kumar")
check("approver above their authority cannot approve", r["reason"] == "ABOVE_APPROVER_AUTHORITY", r)
check("...limit still unchanged", one("SELECT daily_transfer_limit AS l FROM accounts WHERE account_id='ACC-1001'")["l"] == "10000.00")
r = approve("APR-1001", "supervisor.tan")
check("supervisor approves -> limit becomes 25000", r["outcome"] == "APPROVED" and r["new_daily_limit"] == "25000.00", r)
r = approve("APR-1001", "supervisor.tan")
check("decide twice -> ALREADY_APPROVED", r["reason"] == "ALREADY_APPROVED", r)
r = call(SVC, "get_request_status", request_id="APR-1001")[0]
check("status shows APPROVED by supervisor.tan", r["status"] == "APPROVED" and r["decided_by"] == "supervisor.tan", r)

# lifecycle: kill switch and expiry
psql(f"UPDATE agent_identities SET status='SUSPENDED' WHERE agent_id={lit(SVC)}")
r = call(SVC, "block_card", card_id="CARD-7788", reason="suspicious")[0]
check("kill switch: suspended servicing agent -> AGENT_SUSPENDED", r["outcome"] == "NOT_EXECUTED" and r["reason"] == "AGENT_SUSPENDED", r)
check("...and CARD-7788 is still ACTIVE", one("SELECT status FROM cards WHERE card_id='CARD-7788'")["status"] == "ACTIVE")
psql(f"UPDATE agent_identities SET valid_until = now() - interval '1 minute' WHERE agent_id={lit(INS)}")
r = call(INS, "get_account_summary", account_id="ACC-1001")[0]
check("expired identity -> AGENT_IDENTITY_EXPIRED", r["access"] == "DENIED" and r["reason"] == "AGENT_IDENTITY_EXPIRED", r)

# audit trail
a = psql("SELECT decision, count(*) AS n FROM agent_audit GROUP BY decision")
d = {x["decision"]: int(x["n"]) for x in a}
check("audit has ALLOWED, DENIED, PENDING_APPROVAL and APPROVED rows",
      all(d.get(k, 0) > 0 for k in ("ALLOWED", "DENIED", "PENDING_APPROVAL", "APPROVED")), d)
check("every audit row names a real or claimed agent (none blank)",
      one("SELECT count(*) AS n FROM agent_audit WHERE coalesce(agent_id,'') = ''")["n"] == "0")
check("all 4 refused approval attempts are audited (agent, unknown, over-authority, twice)",
      one("SELECT count(*) AS n FROM agent_audit WHERE tool='approve_request' AND decision='DENIED'")["n"] == "4")

reset()
print(f"\n{'ALL RULES HOLD' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
