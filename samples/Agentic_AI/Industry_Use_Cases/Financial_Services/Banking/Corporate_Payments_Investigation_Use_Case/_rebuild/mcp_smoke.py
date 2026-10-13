#!/usr/bin/env python3
"""Step 3: call the running CorporatePaymentsMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, then:   PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9872/corporate-payments-mcp), PG_DB (payments_governed), PG_HOST/PG_PORT/PG_USER, PSQL.
Covers the 18 client tools (scoped reads, two-step trace / recall / cash application / payment incl. a NO_MATCH payee
hold, routed cases) and the 4 reviewer tools (happy path + one blocked call each, parked action executed).
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (Northwind's investigation) to
To_Email; the SQL guard + email_log are asserted, SMTP delivery is reported separately (the shipped password is a
placeholder)."""
import csv, io, json, os, re, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, REVIEWER_TOOLS, PUBLIC_TOOLS, HIDDEN_COLUMNS

URL = os.environ.get("MCP_URL", "http://localhost:9872/corporate-payments-mcp")
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# psql + password lookup (cross-platform): env PSQL > config.md PSQL_PATH > psql on PATH;
# password: env PG_PWD / PG_PASSWORD > config.md PG_PASSWORD (never printed). Install hints: skills-library/AGENT.md
# -> "Prerequisites and preflight".
import re, shutil
def _config_md_value(key):
    """First backticked value of the `| KEY | `value` |` row in the nearest skills-library/.claude/skills/config.md."""
    path, d = os.environ.get("CONFIG_MD", ""), os.path.dirname(os.path.abspath(__file__))
    while not path:
        hits = [p for p in (os.path.join(d, "skills-library", ".claude", "skills", "config.md"),
                            os.path.join(d, ".claude", "skills", "config.md")) if os.path.exists(p)]
        if hits: path = hits[0]
        elif os.path.dirname(d) == d: return ""
        else: d = os.path.dirname(d)
    if not os.path.exists(path): return ""
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\|\s*([A-Za-z][A-Za-z0-9_ ]*?)\s*\|\s*`([^`]*)`", line)
        if m and re.sub(r"\s+", "_", m.group(1)).upper() == key.upper():
            v = m.group(2).strip()
            return "" if re.fullmatch(r"<[^>]*>", v) else v
    return ""
PSQL = (os.environ.get("PSQL") or _config_md_value("PSQL_PATH") or shutil.which("psql")
        or sys.exit("psql not found: install the PostgreSQL client and put psql on PATH, or set env PSQL / config.md "
                    "PSQL_PATH (see skills-library/AGENT.md -> Prerequisites and preflight)"))
ENV = dict(os.environ, PGPASSWORD=os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or _config_md_value("PG_PASSWORD")
           or sys.exit("PostgreSQL password not set: export PG_PWD (or PG_PASSWORD), or fill PG_PASSWORD in config.md"))
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "payments_governed"),
        "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

# ---------------- DB helpers ----------------
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV, encoding="utf-8")
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

SPEC_ARGS = {t["tool"]: [a for a, _ in t["args"]] for t in TOOLS}
OUTPUTS = []

def call(tool, **args):
    args = {a: args.get(a, "") for a in SPEC_ARGS[tool]}          # every spec arg is sent (as the LLM must)
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
    body = json.loads(text)
    rows = (json.loads(body["data"]) if "data" in body else body)["records"]
    OUTPUTS.append((tool, rows))
    return rows

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
BRAMWELL, BA_CODE  = "CLI-2026-00104", "904177"
# payments that belong to OTHER clients - must never appear in Northwind's lists
FOREIGN_PMTS = {"PMT-2026-000006", "PMT-2026-000007", "PMT-2026-000008", "PMT-2026-000009",
                "PMT-2026-000010", "PMT-2026-000011", "PMT-2026-000012", "PMT-2026-000015"}
REMIT = "INV 4417/4425 less 2% early pay + freight dispute $312"
REMIT_NOTES = ("invoices: 4417, 4425\ndeductions: EARLY_PAY_DISCOUNT; FREIGHT 312.00\nconfidence: HIGH\n"
               "explanation: The note names invoices 4417 and 4425, the 2 percent early-payment discount and a 312.00 freight deduction.\n"
               "review_note: Deductions stay recorded as claims against the buyer until Aurelia Client Servicing accepts or rejects "
               "them; the invoice remains open for the disputed amount in the meantime.")

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    expected = {t["tool"] for t in TOOLS}
    check("tools/list = exactly the 22 tools from tool_spec.py", set(tools) == expected and len(expected) == 22,
          {"missing": sorted(expected - set(tools)), "extra": sorted(set(tools) - expected)})
    reads = [t["tool"] for t in TOOLS if t.get("readonly") and t["tool"] in tools]
    check("readOnlyHint on every read tool", all(tools[r].get("annotations", {}).get("readOnlyHint") is True for r in reads),
          {r: tools[r].get("annotations") for r in reads})
    bad_schema = [t["tool"] for t in TOOLS if t["tool"] in tools
                  and not all(a in json.dumps(tools[t["tool"]].get("inputSchema")) for a, _ in t["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)
    ann = tools["decide_review_case"].get("annotations", {})
    check("decide_review_case hints: not read-only, not destructive, not idempotent",
          ann.get("readOnlyHint") is not True and ann.get("destructiveHint") is not True and ann.get("idempotentHint") is not True, ann)
    # (the runtime omits false hints from tools/list; the .flogo holds real JSON booleans - validator G8)

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
    ba = call("verify_client", client_id=BRAMWELL, passcode=BA_CODE)[0].get("session_token") or "missing"
    check("Helios, Veridian and Bramwell also verify", "missing" not in (he, ve, ba))

    # ---- SESSION_INVALID on every scoped client tool, NOT_REVIEWER on every reviewer tool (no writes) ----
    for t in TOOLS:
        if t["tool"] in PUBLIC_TOOLS:
            continue
        if t["tool"] in REVIEWER_TOOLS:
            row = call(t["tool"], session_token="bogus-token-0000", case_id="CASE-00004", decision="APPROVE",
                       internal_note="smoke test note", customer_message="x")[0]
            check(f"{t['tool']} with bogus token -> NOT_REVIEWER", (row.get("status") or row.get("outcome")) == "NOT_REVIEWER", row)
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = "bogus-token-0000"
        row = call(t["tool"], **args)[0]
        code = (row.get("session_status") or row.get("lookup_status") or row.get("reason_code")
                or row.get("send_status") or row.get("outcome"))
        check(f"{t['tool']} with bogus token -> SESSION_INVALID", code == "SESSION_INVALID", row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM investigations WHERE action_id IS NOT NULL") == 0
          and n("SELECT count(*) FROM review_cases") == 4 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM cash_applications") == 1 and n("SELECT count(*) FROM payment_requests") == 1
          and n("SELECT count(*) FROM email_log") == 0)

    # ---- scoped reads (Northwind) ----
    r = call("get_my_payments", session_token=nw, search="")
    ids = {s(x["payment_ref"]) for x in r}
    check("get_my_payments '' -> Northwind's payments incl. PMT-...01, PMT-...02 and the incoming PMT-...13",
          {"PMT-2026-000001", "PMT-2026-000002", "PMT-2026-000013"} <= ids and r[0]["session_status"] == "OK", ids)
    check("no other client's payment in Northwind's list", not (ids & FOREIGN_PMTS), ids & FOREIGN_PMTS)
    r = call("get_my_payments", session_token=nw, search="Pacific Components")
    check("search by beneficiary -> PMT-2026-000001", [s(x["payment_ref"]) for x in r] == ["PMT-2026-000001"], r)
    r = call("get_my_payments", session_token=nw, search="Rotterdam Shipping")
    check("Northwind searching Bramwell's beneficiary -> NO_MATCH",
          r[0]["session_status"] == "NO_MATCH" and not r[0].get("payment_ref"), r)
    r = call("get_payment_status", session_token=nw, payment_ref="PMT-2026-000002")
    check("get_payment_status PMT-...02 -> RETURNED, AC04 decoded (account closed)",
          r[0]["status"] == "RETURNED" and s(r[0]["return_reason_code"]) == "AC04"
          and "closed" in s(r[0].get("return_reason_plain")).lower(), r)
    r = call("get_payment_status", session_token=nw, payment_ref="PMT-2026-000012")
    check("get_payment_status on Bramwell's PMT-...12 (cross-client) -> NOT_YOUR_PAYMENT",
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
    refs = {s(x.get("reference_id")) for x in r}
    check("get_my_cases: Northwind sees only its seeded recall case (Helios's INV-2026-0001 not visible)",
          r[0]["session_status"] == "OK" and refs == {"CASE-00001"}, r)

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

    # ---- recall: cross-client guard, two-step, triggers (the case parks the recall) ----
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
    check("DB: PMT-...06 RECALL_REQUESTED + Payment Operations RECALL case parking RECALL:PMT-...06 + audit",
          q("SELECT status FROM payments WHERE payment_ref='PMT-2026-000006'")[0]["status"] == "RECALL_REQUESTED"
          and n("SELECT count(*) FROM review_cases WHERE request_type='RECALL' AND payment_ref='PMT-2026-000006' "
                f"AND client_id='{HELIOS}' AND assigned_team='Payment Operations' AND parked_action='RECALL:PMT-2026-000006' "
                "AND requested_amount=780000") == 1
          and n("SELECT count(*) FROM agent_audit WHERE action='RECALL_SUBMITTED'") == 1)

    # ---- human-owned request (parks the fee refund) ----
    k = call("open_review_case", session_token=ve, request_type="FEE_WAIVER",
             client_statement="There is an unexpected 45 USD fee on my ACH payment.",
             brief="Client asks for a fee waiver; routed for a human to decide.", reference_id="PMT-2026-000010")[0]
    check("open_review_case FEE_WAIVER -> CASE_OPENED, Client Servicing, requested $45",
          k["outcome"] == "CASE_OPENED" and re.fullmatch(r"CASE-\d{5}", s(k.get("case_id")))
          and s(k.get("assigned_team")) == "Client Servicing" and num(k.get("requested_amount")) == 45.0, k)
    check("DB: FEE_WAIVER case for Veridian parks FEE_REFUND:PMT-2026-000010",
          n(f"SELECT count(*) FROM review_cases WHERE request_type='FEE_WAIVER' AND client_id='{VERIDIAN}' "
            "AND parked_action='FEE_REFUND:PMT-2026-000010'") == 1)
    fee_case = s(k.get("case_id"))
    k = call("open_review_case", session_token=ve, request_type="RECALL", client_statement="Recall it.", brief="n/a")[0]
    check("open_review_case RECALL -> NOT_OPENED BAD_TYPE (recalls go through propose/confirm)",
          k["outcome"] == "NOT_OPENED" and k["reason_code"] == "BAD_TYPE", k)

    # ---- cash application (two-step; the deduction goes to a Client Servicing case) ----
    r = call("get_open_invoices", session_token=nw, search="Harbor")
    check("get_open_invoices 'Harbor' -> Northwind's 4 Harbor Retail invoices", sorted(s(x["invoice_no"]) for x in r)
          == ["4398", "4417", "4425", "4431"] and r[0]["session_status"] == "OK", r)
    r = call("propose_cash_application", session_token=nw, payment_ref="PMT-2026-000013", remittance_text=REMIT,
             invoice_numbers="4417, 7702", deductions="FREIGHT 312", confidence="HIGH", agent_notes="x")[0]
    check("propose_cash_application with another client's invoice -> NOT_PROPOSED INVOICE_NOT_OPEN",
          r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == "INVOICE_NOT_OPEN", r)
    pc = call("propose_cash_application", session_token=nw, payment_ref="PMT-2026-000013", remittance_text=REMIT,
              invoice_numbers="4417, 4425", deductions="EARLY_PAY_DISCOUNT; FREIGHT 312.00", confidence="HIGH",
              agent_notes=REMIT_NOTES)[0]
    check("propose_cash_application -> PROPOSED: $48,000 of invoices, $960 discount earned, $312 for review",
          pc["outcome"] == "PROPOSED" and num(pc.get("invoices_total")) == 48000.0
          and num(pc.get("early_pay_discount_earned")) == 960.0 and num(pc.get("sent_for_review")) == 312.0, pc)
    ca = call("confirm_cash_application", session_token=nw, application_id=s(pc.get("application_id")))[0]
    check("confirm_cash_application -> APPLIED, Client Servicing case for the $312 deduction",
          ca["outcome"] == "APPLIED" and re.fullmatch(r"CASE-\d{5}", s(ca.get("case_id"))) and s(ca.get("team")) == "Client Servicing"
          and "4425 SHORT_PAID" in s(ca.get("invoice_status")), ca)
    ded_case = s(ca.get("case_id"))
    check("DB: invoices posted (4417 PAID, 4425 $312 open) and the case parks the write-off",
          q("SELECT string_agg(invoice_no || ' ' || status || ' ' || open_amount, ', ' ORDER BY invoice_no) AS v FROM open_invoices "
            "WHERE client_id='CLI-2026-00101' AND invoice_no IN ('4417','4425')")[0]["v"] == "4417 PAID 0.00, 4425 SHORT_PAID 312.00"
          and n(f"SELECT count(*) FROM review_cases WHERE case_id='{ded_case}' AND parked_action LIKE 'DEDUCTION_WRITE_OFF:CAP-%'") == 1)
    r = call("confirm_cash_application", session_token=nw, application_id=s(pc.get("application_id")))[0]
    check("re-confirm -> ALREADY_APPLIED", r["reason_code"] == "ALREADY_APPLIED", r)

    # ---- payment with a payee name check: MATCH sent, NO_MATCH held ----
    r = call("check_payee_account", session_token=ba, beneficiary_account="4410028811", typed_name="ACME Corp")[0]
    check("check_payee_account -> OK, name on file Acme Corporation Ltd", r["lookup_status"] == "OK"
          and s(r.get("name_on_file")) == "Acme Corporation Ltd", r)
    pp = call("propose_payment", session_token=ba, from_account="USD", beneficiary_account="4410028811", typed_name="ACME Corp",
              amount="185000", purpose="Quarterly equipment invoice.", name_verdict="MATCH", name_reasons="SUFFIX_ONLY",
              agent_notes="verdict: MATCH")[0]
    check("propose_payment ACME Corp $185,000 -> PROPOSED, name check MATCH", pp["outcome"] == "PROPOSED"
          and s(pp.get("name_check")) == "MATCH" and pp.get("request_id"), pp)
    cp = call("confirm_payment", session_token=ba, request_id=s(pp.get("request_id")), acknowledge_warning="NO")[0]
    check("confirm_payment -> SENT as a new PMT- reference", cp["outcome"] == "SENT"
          and re.fullmatch(r"PMT-2026-\d{6}", s(cp.get("payment_ref"))), cp)
    check("DB: the payment row exists (INITIATED, Bramwell, Acme Corporation Ltd)",
          n(f"SELECT count(*) FROM payments WHERE payment_ref='{s(cp.get('payment_ref'))}' AND client_id='{BRAMWELL}' "
            "AND status='INITIATED' AND beneficiary_name='Acme Corporation Ltd'") == 1)
    hp = call("propose_payment", session_token=ba, from_account="7750", beneficiary_account="7781200456",
              typed_name="Rotterdam Shipping BV", amount="96500", purpose="New bank details from Rotterdam Shipping.",
              name_verdict="NO_MATCH", name_reasons="DIFFERENT_NAME", agent_notes="verdict: NO_MATCH")[0]
    check("propose_payment to a different company's account -> HELD_FOR_REVIEW (Payment Operations), no score shown",
          hp["outcome"] == "HELD_FOR_REVIEW" and s(hp.get("team")) == "Payment Operations"
          and re.fullmatch(r"CASE-\d{5}", s(hp.get("case_id"))) and "score" not in json.dumps(hp).lower(), hp)
    r = call("confirm_payment", session_token=ba, request_id=s(hp.get("request_id")), acknowledge_warning="YES")[0]
    check("confirm_payment on the held request -> NOT_SENT HELD_FOR_REVIEW", r["reason_code"] == "HELD_FOR_REVIEW", r)
    check("DB: held request + PAYEE_VERIFICATION case, nothing paid to RD Global Trading",
          n(f"SELECT count(*) FROM payment_requests WHERE request_id='{s(hp.get('request_id'))}' AND status='HELD' "
            "AND name_check='NO_MATCH'") == 1
          and n(f"SELECT count(*) FROM review_cases WHERE case_id='{s(hp.get('case_id'))}' AND request_type='PAYEE_VERIFICATION'") == 1
          and n("SELECT count(*) FROM payments WHERE beneficiary_name='RD Global Trading LLC'") == 0)

    # ---- guarded email (ONE real send attempt) ----
    try:
        e = call("email_my_confirmation", session_token=nw, reference_id="INV-2026-0002")[0]
        check("email_my_confirmation INV-2026-0002 -> SEND (SMTP delivered)", s(e.get("send_status")).upper() == "SEND", e)
    except RuntimeError as ex:
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request for INV-2026-0002 was logged (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference_id='INV-2026-0002' AND client_id='{NORTHWIND}'") == 1)
    e = call("email_my_confirmation", session_token=nw, reference_id="INV-2026-9999")[0]
    check("email bogus reference -> NOT_SENT NO_SUCH_REFERENCE",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NO_SUCH_REFERENCE", e)
    e = call("email_my_confirmation", session_token=nw, reference_id="INV-2026-0001")[0]
    check("email Helios's INV-2026-0001 from Northwind -> NOT_SENT", e["send_status"] == "NOT_SENT", e)
    check("DB: NOT_SENT requests are never logged", n("SELECT count(*) FROM email_log") == 1)

    # ---- reviewer tools: happy path + one blocked call each ----
    r = call("verify_reviewer", staff_id="AGB-5003", code="000000")[0]
    check("verify_reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r.get("session_token"), r)
    r = call("verify_reviewer", staff_id="AGB-5003", code="615920")[0]
    check("verify_reviewer Sofia -> VERIFIED, REVIEWER, Client Servicing", r["status"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Client Servicing", {k: v for k, v in r.items() if k != "session_token"})
    sofia = s(r.get("session_token"))
    r = call("get_review_queue", session_token=nw)
    check("get_review_queue with a client token -> NOT_REVIEWER", r[0]["status"] == "NOT_REVIEWER", r)
    r = call("get_review_queue", session_token=sofia)
    ids = [s(x.get("case_id")) for x in r]
    check("get_review_queue = Client Servicing OPEN cases incl. seeded CASE-00003/00004, the new fee waiver and deduction",
          {"CASE-00003", "CASE-00004", fee_case or "x", ded_case} <= set(ids) and r[0]["status"] == "OK"
          and all(s(x.get("team")) == "Client Servicing" for x in r), r)
    r = call("get_review_case", session_token=sofia, case_id="CASE-00001")[0]
    check("get_review_case on a Payment Operations case -> NOT_FOUND (cross-team invisible)", r["status"] == "NOT_FOUND", r)
    r = call("get_review_case", session_token=sofia, case_id="CASE-00004")[0]
    check("get_review_case CASE-00004 -> facts, max $3,150, Sofia's $2,500 limit", r["status"] == "OK"
          and num(r.get("max_approvable")) == 3150.0 and num(r.get("your_approval_limit")) == 2500.0
          and "7702" in s(r.get("facts")), r)
    r = call("decide_review_case", session_token=sofia, case_id="CASE-00004", decision="APPROVE", amount="",
             internal_note="Damage photos received.", customer_message="Your deduction was accepted.")[0]
    check("decide_review_case full $3,150 > $2,500 limit -> BLOCKED OVER_AUTHORITY, case stays OPEN",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    r = call("decide_review_case", session_token=sofia, case_id=ded_case, decision="APPROVE", amount="",
             internal_note="Freight was billed on a prepaid order; accept the deduction.",
             customer_message="We accepted the $312.00 freight deduction; invoice 4425 is now closed.")[0]
    check("decide_review_case approve Northwind's $312 deduction -> APPROVED, written off", r["outcome"] == "APPROVED"
          and num(r.get("approved_amount")) == 312.0 and "written off" in s(r.get("executed_action")), r)
    check("DB: decision row + write-off + invoice 4425 PAID + CASE_DECIDED audit by AGB-5003",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{ded_case}' AND reviewer_id='AGB-5003' AND approved_amount=312") == 1
          and n(f"SELECT count(*) FROM deduction_writeoffs WHERE case_id='{ded_case}' AND amount=312") == 1
          and q("SELECT status FROM open_invoices WHERE client_id='CLI-2026-00101' AND invoice_no='4425'")[0]["status"] == "PAID"
          and n(f"SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='{ded_case}' AND actor='AGB-5003'") == 1)
    r = {s(x.get("reference_id")): x for x in call("get_my_cases", session_token=nw)}
    check("the client sees APPROVED + the client message (never the note or the reviewer)",
          s(r[ded_case].get("status")) == "APPROVED" and "invoice 4425 is now closed" in s(r[ded_case].get("customer_message"))
          and "prepaid order" not in json.dumps(r) and "Sofia" not in json.dumps(r), r.get(ded_case))
    cli_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row}
    check("client tool outputs carry no hidden column", not (cli_cols & HIDDEN_COLUMNS), cli_cols & HIDDEN_COLUMNS)
    check("every MCP tool was called at the edge", {t for t, _ in OUTPUTS} == expected, expected - {t for t, _ in OUTPUTS})

    # ---- audit trail written by triggers ----
    au = {x["action"]: int(x["n"]) for x in q("SELECT action, count(*) AS n FROM agent_audit GROUP BY action")}
    check("DB: audit rows for VERIFY, TRACE_OPENED, RECALL_SUBMITTED, REVIEW_CASE_OPENED, CASH_APPLIED, PAYMENT_SENT/HELD, "
          "REVIEWER_VERIFY, CASE_DECIDED",
          au.get("VERIFY", 0) >= 4 and au.get("TRACE_OPENED") == 1 and au.get("RECALL_SUBMITTED") == 1
          and au.get("REVIEW_CASE_OPENED", 0) >= 3 and au.get("CASH_APPLIED") == 1 and au.get("PAYMENT_SENT") == 1
          and au.get("PAYMENT_HELD") == 1 and au.get("REVIEWER_VERIFY") == 1 and au.get("CASE_DECIDED") == 1, au)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
