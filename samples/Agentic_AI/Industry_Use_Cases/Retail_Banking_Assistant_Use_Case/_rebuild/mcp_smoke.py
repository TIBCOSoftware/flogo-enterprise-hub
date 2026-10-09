#!/usr/bin/env python3
"""Step 3: call the running RetailBankingMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, then:   PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9862/retail-banking-mcp), PG_DB (banking_governed), PG_HOST/PG_PORT/PG_USER, PSQL.
The DB is reset (reset_data.sql) before and after. Sends ONE real confirmation email (James's dispute) to To_Email."""
import csv, io, json, os, re, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9862/retail-banking-mcp")
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
if not os.environ.get("PG_PWD"):
    sys.exit("PG_PWD is required (PostgreSQL password; used to reset and inspect the DB)")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "banking_governed"),
        "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

# ---------------- DB helpers ----------------
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def n(sql): return int(list(q(sql)[0].values())[0])
def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

# ---------------- MCP streamable-HTTP JSON-RPC ----------------
def rpc(method, params=None, notify=False):
    global session, seq
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if not notify:
        seq += 1; body["id"] = seq
    req = urllib.request.Request(URL, json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                                          **({"Mcp-Session-Id": session} if session else {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        session = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode()
    if notify or not raw.strip(): return None
    data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
    msg = json.loads(data[-1])
    if "error" in msg: raise RuntimeError(msg["error"])
    return msg["result"]

def call(tool, **args):
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    body = json.loads(text)
    return (json.loads(body["data"]) if "data" in body else body)["records"]

# Flogo may hand numbers/booleans back as JSON numbers/bools or as strings - compare tolerantly
def num(v):
    try: return round(float(v), 2)
    except (TypeError, ValueError): return None
def yes(v): return v is True or str(v).strip().lower() in ("true", "t", "1", "yes")
def s(v): return "" if v is None else str(v)

def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0

JAMES, JAMES_CODE = "CUST-2026-00101", "482913"
# transactions that belong to OTHER customers - must never appear in James's lists
FOREIGN_TXNS = {"TXN-50008", "TXN-50009", "TXN-50010", "TXN-50011", "TXN-50012", "TXN-50014", "TXN-50015",
                "TXN-50016", "TXN-50017", "TXN-50018", "TXN-50019", "TXN-50020", "TXN-50021", "TXN-50022", "TXN-50023"}

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    expected = {t["tool"] for t in TOOLS}
    check("tools/list = exactly the 13 tools from tool_spec.py", set(tools) == expected and len(expected) == 13,
          {"missing": sorted(expected - set(tools)), "extra": sorted(set(tools) - expected)})
    reads = [t["tool"] for t in TOOLS if t.get("readonly") and t["tool"] in tools]
    check("readOnlyHint on every read tool", all(tools[r].get("annotations", {}).get("readOnlyHint") is True for r in reads),
          {r: tools[r].get("annotations") for r in reads})
    bad_schema = [t["tool"] for t in TOOLS if t["tool"] in tools
                  and not all(a in json.dumps(tools[t["tool"]].get("inputSchema")) for a, _ in t["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- identity ----
    r = call("verify_customer", customer_id=JAMES, passcode="000000")
    check("wrong passcode -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0].get("session_token"), r)
    check("DB: wrong passcode created no session", n("SELECT count(*) FROM customer_sessions") == 0)
    r = call("verify_customer", customer_id=JAMES, passcode=JAMES_CODE)
    check("James right passcode -> VERIFIED + token + name", r[0]["status"] == "VERIFIED" and r[0].get("session_token")
          and r[0].get("customer_name") == "James Miller", {k: v for k, v in r[0].items() if k != "session_token"})
    tok = r[0].get("session_token") or "missing"
    check("DB: exactly one session, for James",
          n(f"SELECT count(*) FROM customer_sessions WHERE customer_id='{JAMES}'") == 1
          and n("SELECT count(*) FROM customer_sessions") == 1)

    # ---- SESSION_INVALID on every scoped tool (no writes, no email with a bogus token) ----
    for t in TOOLS:
        if t["tool"] in ("verify_customer", "find_branch"):
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = "bogus-token-0000"
        row = call(t["tool"], **args)[0]
        code = row.get("session_status") or row.get("reason_code")
        check(f"{t['tool']} with bogus token -> SESSION_INVALID", code == "SESSION_INVALID", row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM service_cases WHERE request_type <> 'FRAUD_REVIEW'") == 0)

    # ---- scoped reads ----
    r = call("get_my_accounts", session_token=tok)
    check("get_my_accounts = James's ACC-1001 + ACC-1002 only",
          sorted(s(x["account_id"]) for x in r) == ["ACC-1001", "ACC-1002"] and r[0]["session_status"] == "OK", r)
    r = call("get_my_transactions", session_token=tok, search="")
    ids = {s(x["transaction_id"]) for x in r}
    check("get_my_transactions '' -> James's recent txns incl. TXN-50003", "TXN-50003" in ids and r[0]["session_status"] == "OK", ids)
    check("no other customer's transaction in James's list", not (ids & FOREIGN_TXNS), ids & FOREIGN_TXNS)
    r = call("get_my_transactions", session_token=tok, search="QUICKPAY")
    check("search QUICKPAY -> TXN-50003 + TXN-50013", sorted(s(x["transaction_id"]) for x in r) == ["TXN-50003", "TXN-50013"], r)
    r = call("get_my_transactions", session_token=tok, search="GLOBAL*DIGITAL")
    check("James searching Sophia's descriptor -> NO_MATCH", r[0]["session_status"] == "NO_MATCH" and not r[0].get("transaction_id"), r)
    r = call("get_my_cards", session_token=tok)
    check("get_my_cards = CARD-9001 ACTIVE ending 1123", [s(x["card_id"]) for x in r] == ["CARD-9001"]
          and r[0]["status"] == "ACTIVE" and s(r[0]["last4"]) == "1123", r)
    r = call("get_my_loans", session_token=tok)
    check("get_my_loans = LOAN-3001 HOME", [s(x["loan_id"]) for x in r] == ["LOAN-3001"] and r[0]["loan_type"] == "HOME", r)
    r = call("get_my_cases", session_token=tok)
    check("get_my_cases: James has none yet (Sophia's DSP-2026-0001 not visible)",
          r[0]["session_status"] == "OK" and not any(x.get("reference_id") for x in r), r)
    r = call("find_branch", city="Chicago")
    check("find_branch Chicago -> BR-003 The Loop", [s(x["branch_id"]) for x in r] == ["BR-003"] and r[0]["lookup_status"] == "OK", r)
    r = call("find_branch", city="Atlantis")
    check("find_branch unknown city -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND", r)

    # ---- card block: guards, two-step ----
    r = call("propose_card_block", session_token=tok, card="1123", reason="BORED")[0]
    check("propose_card_block bad reason -> BAD_REASON", r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == "BAD_REASON", r)
    r = call("propose_card_block", session_token=tok, card="4410", reason="LOST")[0]
    check("propose_card_block on Sophia's card (last4 4410) -> CARD_NOT_FOUND", r["reason_code"] == "CARD_NOT_FOUND", r)
    check("DB: refused proposals wrote no pending action", n("SELECT count(*) FROM pending_actions") == 0)
    b = call("propose_card_block", session_token=tok, card="1123", reason="LOST")[0]
    check("propose_card_block 1123 LOST -> PROPOSED with action_id + delivery date",
          b["outcome"] == "PROPOSED" and b.get("action_id") and s(b.get("card_id")) == "CARD-9001"
          and b.get("replacement_expected_delivery"), b)
    check("DB: one pending CARD_BLOCK, card still ACTIVE",
          n("SELECT count(*) FROM pending_actions WHERE action_type='CARD_BLOCK' AND card_id='CARD-9001'") == 1
          and q("SELECT status FROM cards WHERE card_id='CARD-9001'")[0]["status"] == "ACTIVE")
    r = call("confirm_card_block", session_token=tok, action_id="ACT-00000000")[0]
    check("confirm_card_block bogus action -> NOT_EXECUTED NO_SUCH_PROPOSAL",
          r["outcome"] == "NOT_EXECUTED" and r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    c = call("confirm_card_block", session_token=tok, action_id=s(b.get("action_id")))[0]
    check("confirm_card_block -> EXECUTED with BLK-NNNNN", c["outcome"] == "EXECUTED"
          and re.fullmatch(r"BLK-\d{5}", s(c.get("block_id"))), c)
    check("DB: CARD-9001 BLOCKED + one card_replacements row",
          q("SELECT status FROM cards WHERE card_id='CARD-9001'")[0]["status"] == "BLOCKED"
          and n("SELECT count(*) FROM card_replacements WHERE card_id='CARD-9001'") == 1)

    # ---- dispute: cross-customer guard, quote, two-step, triggers ----
    r = call("propose_dispute", session_token=tok, transaction_id="TXN-50009", reason_code="FRAUD",
             customer_statement="I want to dispute this.")[0]
    check("propose_dispute on Sophia's TXN-50009 -> NOT_YOUR_TRANSACTION",
          r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == "NOT_YOUR_TRANSACTION", r)
    check("DB: no pending DISPUTE written for TXN-50009", n("SELECT count(*) FROM pending_actions WHERE transaction_id='TXN-50009'") == 0)
    p = call("propose_dispute", session_token=tok, transaction_id="TXN-50003", reason_code="UNRECOGNISED",
             customer_statement="I never bought anything from QUICKPAY XYZ.")[0]
    check("propose_dispute TXN-50003 UNRECOGNISED -> PROPOSED, credit 249.99, fraud review, XYZ Gadgets",
          p["outcome"] == "PROPOSED" and p.get("action_id") and num(p.get("amount")) == 249.99
          and num(p.get("provisional_credit")) == 249.99 and yes(p.get("fraud_review"))
          and s(p.get("merchant")) == "XYZ Gadgets Online" and p.get("est_decision_date"), p)
    r = call("confirm_dispute", session_token=tok, action_id=s(b.get("action_id")))[0]
    check("confirm_dispute with the card-block action -> NO_SUCH_PROPOSAL", r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    check("DB: nothing filed before confirm", n("SELECT count(*) FROM disputes WHERE transaction_id='TXN-50003'") == 0)
    f = call("confirm_dispute", session_token=tok, action_id=s(p.get("action_id")))[0]
    dsp = s(f.get("dispute_id"))
    check("confirm_dispute -> FILED DSP-2026-0002 with credit txn + fraud case",
          f["outcome"] == "FILED" and dsp == "DSP-2026-0002" and num(f.get("provisional_credit")) == 249.99
          and f.get("provisional_credit_txn") and f.get("fraud_case_id"), f)
    check("DB: disputes row for TXN-50003 (James, 249.99)",
          n(f"SELECT count(*) FROM disputes WHERE transaction_id='TXN-50003' AND customer_id='{JAMES}' "
            "AND provisional_credit=249.99") == 1)
    check("DB: trigger posted PENDING CREDIT 'PROVISIONAL CREDIT <dsp>' on ACC-1001",
          n(f"SELECT count(*) FROM transactions WHERE descriptor='PROVISIONAL CREDIT {dsp}' AND account_id='ACC-1001' "
            "AND txn_type='CREDIT' AND status='PENDING' AND amount=249.99") == 1)
    check("DB: trigger opened FRAUD_REVIEW case -> Fraud Operations",
          n(f"SELECT count(*) FROM service_cases WHERE request_type='FRAUD_REVIEW' AND dispute_id='{dsp}' "
            f"AND customer_id='{JAMES}' AND assigned_team='Fraud Operations'") == 1)
    r = call("get_my_cases", session_token=tok)
    refs = {s(x.get("reference_id")) for x in r}
    check("get_my_cases now shows the dispute + fraud case, not Sophia's DSP-2026-0001",
          dsp in refs and s(f.get("fraud_case_id")) in refs and "DSP-2026-0001" not in refs, refs)

    # ---- guarded email (ONE real send) ----
    e = call("email_my_confirmation", session_token=tok, reference_id=dsp)[0]
    check(f"email_my_confirmation {dsp} -> SEND", s(e.get("send_status")).upper().startswith("SEND"), e)
    e = call("email_my_confirmation", session_token=tok, reference_id="DSP-2026-9999")[0]
    check("email bogus reference -> NOT_SENT NO_SUCH_REFERENCE",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NO_SUCH_REFERENCE", e)
    e = call("email_my_confirmation", session_token=tok, reference_id="DSP-2026-0001")[0]
    check("email Sophia's DSP-2026-0001 from James -> NOT_SENT", e["send_status"] == "NOT_SENT", e)

    # ---- human-owned request ----
    k = call("open_service_case", session_token=tok, request_type="FEE_REFUND",
             customer_statement="Please refund the monthly maintenance fee.",
             brief="Customer asks for a fee refund; routed for a human to decide.")[0]
    check("open_service_case FEE_REFUND -> CASE_OPENED, Customer Care",
          k["outcome"] == "CASE_OPENED" and re.fullmatch(r"CASE-\d{5}", s(k.get("case_id")))
          and k.get("assigned_team") == "Customer Care", k)
    check("DB: FEE_REFUND case row for James",
          n(f"SELECT count(*) FROM service_cases WHERE request_type='FEE_REFUND' AND customer_id='{JAMES}'") == 1)
    k = call("open_service_case", session_token=tok, request_type="LOAN_APPROVAL",
             customer_statement="Approve my loan.", brief="n/a")[0]
    check("open_service_case bad type -> NOT_OPENED BAD_TYPE", k["outcome"] == "NOT_OPENED" and k["reason_code"] == "BAD_TYPE", k)

    # ---- audit trail written by triggers ----
    au = {x["action"]: int(x["n"]) for x in q("SELECT action, count(*) AS n FROM agent_audit GROUP BY action")}
    check("DB: audit rows for VERIFY, CARD_BLOCKED, DISPUTE_FILED, SERVICE_CASE_OPENED",
          au.get("VERIFY", 0) >= 1 and au.get("CARD_BLOCKED") == 1 and au.get("DISPUTE_FILED") == 1
          and au.get("SERVICE_CASE_OPENED", 0) >= 2, au)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
