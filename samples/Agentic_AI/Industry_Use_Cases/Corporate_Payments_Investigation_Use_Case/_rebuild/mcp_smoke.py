#!/usr/bin/env python3
"""Step 3: call the running CorporatePaymentsMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, then:   PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9872/corporate-payments-mcp), PG_DB (payments_governed), PG_HOST/PG_PORT/PG_USER, PSQL.
The DB is reset (reset_data.sql) before and after. Sends ONE real confirmation email (Northwind's investigation) to To_Email."""
import csv, io, json, os, re, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9872/corporate-payments-mcp")
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
if not os.environ.get("PG_PWD"):
    sys.exit("PG_PWD is required (PostgreSQL password; used to reset and inspect the DB)")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "payments_governed"),
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
def s(v): return "" if v is None else str(v)

def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0

NORTHWIND, NW_CODE = "CLI-2026-00101", "486201"
HELIOS,   HE_CODE  = "CLI-2026-00102", "730955"
VERIDIAN, VE_CODE  = "CLI-2026-00103", "615338"
BARCO,    BA_CODE  = "CLI-2026-00104", "904177"
# payments that belong to OTHER clients - must never appear in Northwind's lists
FOREIGN_PMTS = {"PMT-2026-000006", "PMT-2026-000007", "PMT-2026-000008", "PMT-2026-000009",
                "PMT-2026-000010", "PMT-2026-000011", "PMT-2026-000012"}

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    expected = {t["tool"] for t in TOOLS}
    check("tools/list = exactly the 12 tools from tool_spec.py", set(tools) == expected and len(expected) == 12,
          {"missing": sorted(expected - set(tools)), "extra": sorted(set(tools) - expected)})
    reads = [t["tool"] for t in TOOLS if t.get("readonly") and t["tool"] in tools]
    check("readOnlyHint on every read tool", all(tools[r].get("annotations", {}).get("readOnlyHint") is True for r in reads),
          {r: tools[r].get("annotations") for r in reads})
    bad_schema = [t["tool"] for t in TOOLS if t["tool"] in tools
                  and not all(a in json.dumps(tools[t["tool"]].get("inputSchema")) for a, _ in t["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- identity ----
    r = call("verify_client", client_id=NORTHWIND, passcode="000000")
    check("wrong passcode -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0].get("session_token"), r)
    check("DB: wrong passcode created no session", n("SELECT count(*) FROM client_sessions") == 0)
    r = call("verify_client", client_id=NORTHWIND, passcode=NW_CODE)
    check("Northwind right passcode -> VERIFIED + token + name", r[0]["status"] == "VERIFIED" and r[0].get("session_token")
          and r[0].get("legal_name") == "Northwind Manufacturing", {k: v for k, v in r[0].items() if k != "session_token"})
    nw = r[0].get("session_token") or "missing"
    check("DB: exactly one session, for Northwind",
          n(f"SELECT count(*) FROM client_sessions WHERE client_id='{NORTHWIND}'") == 1
          and n("SELECT count(*) FROM client_sessions") == 1)
    he = call("verify_client", client_id=HELIOS, passcode=HE_CODE)[0].get("session_token") or "missing"
    ve = call("verify_client", client_id=VERIDIAN, passcode=VE_CODE)[0].get("session_token") or "missing"
    check("Helios + Veridian also verify", he != "missing" and ve != "missing")

    # ---- SESSION_INVALID on every scoped tool (no writes, no email with a bogus token) ----
    for t in TOOLS:
        if t["tool"] == "verify_client":
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = "bogus-token-0000"
        row = call(t["tool"], **args)[0]
        code = (row.get("session_status") or row.get("lookup_status") or row.get("reason_code")
                or row.get("send_status") or row.get("outcome"))
        check(f"{t['tool']} with bogus token -> SESSION_INVALID", code == "SESSION_INVALID", row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM investigations WHERE action_id IS NOT NULL") == 0
          and n("SELECT count(*) FROM review_cases") == 0)

    # ---- scoped reads (Northwind) ----
    r = call("get_my_payments", session_token=nw, search="")
    ids = {s(x["payment_ref"]) for x in r}
    check("get_my_payments '' -> Northwind's payments incl. PMT-...01 + PMT-...02",
          {"PMT-2026-000001", "PMT-2026-000002"} <= ids and r[0]["session_status"] == "OK", ids)
    check("no other client's payment in Northwind's list", not (ids & FOREIGN_PMTS), ids & FOREIGN_PMTS)
    r = call("get_my_payments", session_token=nw, search="Pacific Components")
    check("search by beneficiary -> PMT-2026-000001", [s(x["payment_ref"]) for x in r] == ["PMT-2026-000001"], r)
    r = call("get_my_payments", session_token=nw, search="Rotterdam Shipping")
    check("Northwind searching Barco's beneficiary -> NO_MATCH",
          r[0]["session_status"] == "NO_MATCH" and not r[0].get("payment_ref"), r)
    r = call("get_payment_status", session_token=nw, payment_ref="PMT-2026-000002")
    check("get_payment_status PMT-...02 -> RETURNED, AC04 decoded (account closed)",
          r[0]["status"] == "RETURNED" and s(r[0]["return_reason_code"]) == "AC04"
          and "closed" in s(r[0].get("return_reason_plain")).lower(), r)
    r = call("get_payment_status", session_token=nw, payment_ref="PMT-2026-000012")
    check("get_payment_status on Barco's PMT-...12 (cross-client) -> NOT_YOUR_PAYMENT",
          r[0]["lookup_status"] == "NOT_YOUR_PAYMENT" and not r[0].get("beneficiary_name"), r)
    r = call("get_payment_timeline", session_token=nw, payment_ref="PMT-2026-000001")
    check("get_payment_timeline PMT-...01 -> ordered events (INITIATED first)",
          r[0]["lookup_status"] == "OK" and [s(x["action"]) for x in r][:2] == ["INITIATED", "DEBITED"], r)
    r = call("get_payment_timeline", session_token=nw, payment_ref="PMT-2026-000012")
    check("timeline cross-client -> NOT_YOUR_PAYMENT", r[0]["lookup_status"] == "NOT_YOUR_PAYMENT", r)
    r = call("check_delivery_estimate", session_token=nw, payment_ref="PMT-2026-000003")
    check("check_delivery_estimate PMT-...03 (COMPLETED) -> SETTLED (arithmetic)", r[0]["outcome"] == "SETTLED", r)
    r = call("check_delivery_estimate", session_token=nw, payment_ref="PMT-2026-000005")
    check("check_delivery_estimate PMT-...05 -> PAST_CUTOFF (arithmetic)", r[0]["outcome"] == "PAST_CUTOFF", r)
    r = call("check_delivery_estimate", session_token=nw, payment_ref="PMT-2026-000012")
    check("delivery estimate cross-client -> NOT_YOUR_PAYMENT", r[0]["outcome"] == "NOT_YOUR_PAYMENT", r)
    r = call("get_my_cases", session_token=nw)
    check("get_my_cases: Northwind has none yet (Helios's INV-2026-0001 not visible)",
          r[0]["session_status"] == "OK" and not any(s(x.get("reference_id")) for x in r), r)

    # ---- trace: guards, two-step ----
    r = call("propose_trace", session_token=nw, payment_ref="PMT-2026-000001", reason_code="ZZ99",
             client_statement="Where is my payment?")[0]
    check("propose_trace bad reason -> BAD_REASON", r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == "BAD_REASON", r)
    r = call("propose_trace", session_token=nw, payment_ref="PMT-2026-000004", reason_code="MS03",
             client_statement="Where is my GBP payment?")[0]
    check("propose_trace on the <2h INITIATED PMT-...04 -> NOT_TRACEABLE", r["reason_code"] == "NOT_TRACEABLE", r)
    check("DB: refused proposals wrote no pending action", n("SELECT count(*) FROM pending_actions") == 0)
    p = call("propose_trace", session_token=nw, payment_ref="PMT-2026-000001", reason_code="MS03",
             client_statement="My 250k USD payment to Pacific Components has not arrived.")[0]
    check("propose_trace PMT-...01 MS03 -> PROPOSED with action_id, amount, beneficiary, response date",
          p["outcome"] == "PROPOSED" and p.get("action_id") and num(p.get("amount")) == 250000.0
          and s(p.get("beneficiary_name")) == "Pacific Components Ltd" and p.get("est_response_date"), p)
    check("DB: one pending TRACE, payment still IN_TRANSIT",
          n("SELECT count(*) FROM pending_actions WHERE action_type='TRACE' AND payment_ref='PMT-2026-000001'") == 1
          and q("SELECT status FROM payments WHERE payment_ref='PMT-2026-000001'")[0]["status"] == "IN_TRANSIT")
    r = call("confirm_trace", session_token=nw, action_id="ACT-00000000")[0]
    check("confirm_trace bogus action -> NOT_EXECUTED NO_SUCH_PROPOSAL",
          r["outcome"] == "NOT_EXECUTED" and r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    c = call("confirm_trace", session_token=nw, action_id=s(p.get("action_id")))[0]
    check("confirm_trace -> OPENED INV-2026-0002", c["outcome"] == "OPENED" and s(c.get("investigation_id")) == "INV-2026-0002", c)
    check("DB: investigation row + payment_event + audit for INV-2026-0002",
          n("SELECT count(*) FROM investigations WHERE payment_ref='PMT-2026-000001' AND investigation_id='INV-2026-0002'") == 1
          and n("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000001' AND action='INVESTIGATION OPENED'") == 1
          and n("SELECT count(*) FROM agent_audit WHERE action='TRACE_OPENED' AND ref='INV-2026-0002'") == 1)
    r = call("get_my_cases", session_token=nw)
    refs = {s(x.get("reference_id")) for x in r}
    check("get_my_cases now shows INV-2026-0002, not Helios's INV-2026-0001",
          "INV-2026-0002" in refs and "INV-2026-0001" not in refs, refs)

    # ---- recall: cross-client guard, two-step, triggers ----
    r = call("propose_recall", session_token=ve, payment_ref="PMT-2026-000009", reason_code="MS03",
             client_statement="Please recall this.")[0]
    check("propose_recall on INCOMING PMT-...09 -> NOT_RECALLABLE", r["reason_code"] == "NOT_RECALLABLE", r)
    pr = call("propose_recall", session_token=he, payment_ref="PMT-2026-000006", reason_code="BE01",
              client_statement="We sent 780k USD to the wrong beneficiary.")[0]
    check("propose_recall PMT-...06 BE01 -> PROPOSED with action_id + amount",
          pr["outcome"] == "PROPOSED" and pr.get("action_id") and num(pr.get("amount")) == 780000.0, pr)
    check("DB: one pending RECALL, payment still IN_TRANSIT",
          n("SELECT count(*) FROM pending_actions WHERE action_type='RECALL' AND payment_ref='PMT-2026-000006'") == 1
          and q("SELECT status FROM payments WHERE payment_ref='PMT-2026-000006'")[0]["status"] == "IN_TRANSIT")
    r = call("confirm_recall", session_token=he, action_id="ACT-00000000")[0]
    check("confirm_recall bogus action -> NO_SUCH_PROPOSAL", r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    r = call("confirm_recall", session_token=nw, action_id=s(pr.get("action_id")))[0]
    check("confirm_recall by another client (Northwind on Helios's action) -> NO_SUCH_PROPOSAL",
          r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    cr = call("confirm_recall", session_token=he, action_id=s(pr.get("action_id")))[0]
    check("confirm_recall -> SUBMITTED with CASE- id, Payment Operations",
          cr["outcome"] == "SUBMITTED" and re.fullmatch(r"CASE-\d{5}", s(cr.get("case_id")))
          and s(cr.get("assigned_team")) == "Payment Operations", cr)
    check("DB: PMT-...06 RECALL_REQUESTED + Payment Operations RECALL review case + audit",
          q("SELECT status FROM payments WHERE payment_ref='PMT-2026-000006'")[0]["status"] == "RECALL_REQUESTED"
          and n("SELECT count(*) FROM review_cases WHERE request_type='RECALL' AND payment_ref='PMT-2026-000006' "
                f"AND client_id='{HELIOS}' AND assigned_team='Payment Operations'") == 1
          and n("SELECT count(*) FROM agent_audit WHERE action='RECALL_SUBMITTED'") == 1)

    # ---- human-owned request ----
    k = call("open_review_case", session_token=ve, request_type="FEE_WAIVER",
             client_statement="There is an unexpected 45 USD fee on my ACH payment.",
             brief="Client asks for a fee waiver; routed for a human to decide.")[0]
    check("open_review_case FEE_WAIVER -> CASE_OPENED, Client Servicing",
          k["outcome"] == "CASE_OPENED" and re.fullmatch(r"CASE-\d{5}", s(k.get("case_id")))
          and s(k.get("assigned_team")) == "Client Servicing", k)
    check("DB: FEE_WAIVER case row for Veridian",
          n(f"SELECT count(*) FROM review_cases WHERE request_type='FEE_WAIVER' AND client_id='{VERIDIAN}'") == 1)
    k = call("open_review_case", session_token=ve, request_type="REFUND",
             client_statement="Just refund it.", brief="n/a")[0]
    check("open_review_case bad type -> NOT_OPENED BAD_TYPE", k["outcome"] == "NOT_OPENED" and k["reason_code"] == "BAD_TYPE", k)

    # ---- guarded email (ONE real send) ----
    e = call("email_my_confirmation", session_token=nw, reference_id="INV-2026-0002")[0]
    check("email_my_confirmation INV-2026-0002 -> SEND", s(e.get("send_status")).upper().startswith("SEND"), e)
    e = call("email_my_confirmation", session_token=nw, reference_id="INV-2026-9999")[0]
    check("email bogus reference -> NOT_SENT NO_SUCH_REFERENCE",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NO_SUCH_REFERENCE", e)
    e = call("email_my_confirmation", session_token=nw, reference_id="INV-2026-0001")[0]
    check("email Helios's INV-2026-0001 from Northwind -> NOT_SENT", e["send_status"] == "NOT_SENT", e)

    # ---- audit trail written by triggers ----
    au = {x["action"]: int(x["n"]) for x in q("SELECT action, count(*) AS n FROM agent_audit GROUP BY action")}
    check("DB: audit rows for VERIFY, TRACE_OPENED, RECALL_SUBMITTED, REVIEW_CASE_OPENED",
          au.get("VERIFY", 0) >= 3 and au.get("TRACE_OPENED") == 1 and au.get("RECALL_SUBMITTED") == 1
          and au.get("REVIEW_CASE_OPENED", 0) >= 1, au)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
