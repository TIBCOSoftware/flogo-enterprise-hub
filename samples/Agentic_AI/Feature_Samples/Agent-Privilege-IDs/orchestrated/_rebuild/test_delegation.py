#!/usr/bin/env python3
"""Rung 1 (orchestrated variant): the delegation SQL the specialist tools run, against bankops_agents. No Flogo, no LLM.
  PG_PWD=<password> python orchestrated/_rebuild/test_delegation.py
Resets the DB before and after (../../reset_data.sql)."""
import csv, io, os, subprocess, sys
from orch_common import SAMPLE_DIR

PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", "bankops_agents", "-v", "ON_ERROR_STOP=1", "-q"]
fails = 0

def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: print(r.stderr); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    fails += 0 if cond else 1

def reset(): subprocess.run(BASE + ["-f", os.path.join(SAMPLE_DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

def delegate(caller, tool, req="block card CARD-4421"):
    """Exactly what a specialist tool flow runs: audit row, then the gate."""
    q(f"INSERT INTO agent_audit (agent_id, tool, target, decision, reason, detail) SELECT * FROM "
      f"delegation_audit_row('{caller}', '{tool}', '{req}')")
    return q(f"SELECT * FROM delegation_gate('{caller}', '{tool}')")[0]

reset()
ORCH = "agt-orchestrator-01"
r = q(f"SELECT * FROM whoami('{ORCH}', '[]')")[0]
check("orchestrator is a registered identity with an accountable owner", r["status"] == "ACTIVE" and "maria" in r["owner"], r)
check("orchestrator is entitled to delegate only", r["entitled_tools"] == "ask_insight_agent, ask_servicing_agent", r)
for tool in ("ask_insight_agent", "ask_servicing_agent"):
    r = delegate(ORCH, tool)
    check(f"orchestrator may delegate via {tool}", r["decision"] == "ALLOWED", r)
for tool in ("get_account_summary", "block_card", "request_limit_increase"):
    r = q(f"SELECT * FROM agent_check('{ORCH}', '{tool}')")[0]
    check(f"orchestrator has NO direct bank privilege: {tool}", r["ok"] == "f" and r["reason"] == "NOT_ENTITLED", r)
r = delegate("agt-insight-01", "ask_servicing_agent")
check("a specialist cannot use the delegation tools (NOT_ENTITLED)", r["decision"] == "DENIED" and r["reason"] == "NOT_ENTITLED", r)
r = delegate("agt-rogue-77", "ask_servicing_agent")
check("unknown caller -> UNKNOWN_AGENT", r["reason"] == "UNKNOWN_AGENT", r)
q(f"UPDATE agent_identities SET status='SUSPENDED' WHERE agent_id='{ORCH}'")
r = delegate(ORCH, "ask_servicing_agent")
check("kill switch: suspended orchestrator -> AGENT_SUSPENDED", r["decision"] == "DENIED" and r["reason"] == "AGENT_SUSPENDED", r)
a = q(f"SELECT decision, count(*) AS n FROM agent_audit WHERE agent_id='{ORCH}' GROUP BY decision ORDER BY decision")
check("every delegation attempt is audited under the orchestrator's ID (2 allowed, 1 denied)",
      {x["decision"]: x["n"] for x in a} == {"ALLOWED": "2", "DENIED": "1"}, a)
d = q(f"SELECT detail FROM agent_audit WHERE agent_id='{ORCH}' ORDER BY audit_id LIMIT 1")[0]["detail"]
check("the delegated request text is kept in the audit detail", d == "block card CARD-4421", d)
reset()
print(f"\n{'DELEGATION RULES HOLD' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
