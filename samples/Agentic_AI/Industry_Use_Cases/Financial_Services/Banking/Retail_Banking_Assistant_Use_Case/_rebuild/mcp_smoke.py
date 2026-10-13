#!/usr/bin/env python3
"""Step 3: call the running RetailBankingMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, then:   PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9862/retail-banking-mcp), PG_DB (banking_governed), PG_HOST/PG_PORT/PG_USER, PSQL.
Covers the 16 customer tools (scoped reads, two-step card block / dispute / payment incl. a HIGH scam hold, routed
cases) and the 4 reviewer tools (happy path + one blocked call each, parked action executed).
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (James's dispute) to To_Email;
the SQL guard + email_log are asserted, SMTP delivery is reported separately (the shipped password is a placeholder)."""
import csv, io, json, os, re, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, REVIEWER_TOOLS, PUBLIC_TOOLS, HIDDEN_COLUMNS

URL = os.environ.get("MCP_URL", "http://localhost:9862/retail-banking-mcp")
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

SPEC_ARGS = {t["tool"]: [a for a, _ in t["args"]] for t in TOOLS}
OUTPUTS = []

def call(tool, **args):
    args = {a: args.get(a, "") for a in SPEC_ARGS[tool]}
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
    check("tools/list = exactly the 20 tools from tool_spec.py", set(tools) == expected and len(expected) == 20,
          {"missing": sorted(expected - set(tools)), "extra": sorted(set(tools) - expected)})
    reads = [t["tool"] for t in TOOLS if t.get("readonly") and t["tool"] in tools]
    check("readOnlyHint on every read tool", all(tools[r].get("annotations", {}).get("readOnlyHint") is True for r in reads),
          {r: tools[r].get("annotations") for r in reads})
    bad_schema = [t["tool"] for t in TOOLS if t["tool"] in tools
                  and not all(a in json.dumps(tools[t["tool"]].get("inputSchema")) for a, _ in t["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)
    ann = tools["decide_review_case"].get("annotations", {})
    check("decide_review_case hints: not read-only, not destructive, not idempotent",
          ann.get("readOnlyHint") is not True and ann.get("destructiveHint") is False and ann.get("idempotentHint") is not True, ann)
    # (the runtime omits false readOnly/idempotent hints from tools/list; the .flogo holds real JSON booleans - validator G8)

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

    # ---- SESSION_INVALID on every scoped customer tool, NOT_REVIEWER on every reviewer tool (no writes) ----
    n_cases0 = n("SELECT count(*) FROM service_cases")
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
        code = row.get("session_status") or row.get("reason_code")
        check(f"{t['tool']} with bogus token -> SESSION_INVALID", code == "SESSION_INVALID", row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM service_cases") == n_cases0 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM payment_requests") == 1 and n("SELECT count(*) FROM email_log") == 0)

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

    # ---- guarded email (ONE real send attempt) ----
    try:
        e = call("email_my_confirmation", session_token=tok, reference_id=dsp)[0]
        check(f"email_my_confirmation {dsp} -> SEND (SMTP delivered)", s(e.get("send_status")).upper() == "SEND", e)
    except Exception as ex:                       # noqa: BLE001 - the SQL guard is asserted below either way
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check(f"DB: the authorised email request for {dsp} was logged (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference_id='{dsp}' AND customer_id='{JAMES}'") == 1)
    e = call("email_my_confirmation", session_token=tok, reference_id="DSP-2026-9999")[0]
    check("email bogus reference -> NOT_SENT NO_SUCH_REFERENCE",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NO_SUCH_REFERENCE", e)
    e = call("email_my_confirmation", session_token=tok, reference_id="DSP-2026-0001")[0]
    check("email Sophia's DSP-2026-0001 from James -> NOT_SENT", e["send_status"] == "NOT_SENT", e)

    # ---- human-owned request ----
    k0 = k = call("open_service_case", session_token=tok, request_type="FEE_REFUND",
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

    # ---- payments to saved payees: LOW two-step (Emma) and a HIGH scam hold (Patricia) ----
    emma = call("verify_customer", customer_id="CUST-2026-00106", passcode="918342")[0]["session_token"]
    r = call("get_my_payees", session_token=emma)
    check("get_my_payees = Emma's 2 payees only", sorted(s(x["payee_id"]) for x in r) == ["PYE-0201", "PYE-0202"], r)
    pp = call("propose_payment", session_token=emma, from_account="ACC-1009", payee="PYE-0201", amount="1850.00",
              customer_story="Monthly rent to my landlord.", scam_indicators="NONE", narrative_score="5",
              agent_notes="indicators: NONE")[0]
    check("propose_payment rent to a known landlord -> PROPOSED", pp["outcome"] == "PROPOSED" and pp.get("payment_id"), pp)
    check("DB: nothing sent before confirm", n("SELECT count(*) FROM payment_sends") == 0)
    cp = call("confirm_payment", session_token=emma, payment_id=s(pp.get("payment_id")), acknowledge_warning="NO")[0]
    check("confirm_payment -> SENT, balance 5,600 -> 3,750", cp["outcome"] == "SENT" and num(cp.get("available_balance_after")) == 3750.0, cp)
    check("DB: POSTED debit for the rent + payment_sends row",
          n("SELECT count(*) FROM transactions WHERE account_id='ACC-1009' AND descriptor='PAYMENT TO HARBOR PROPERTY MANAGEMENT'") == 1
          and n("SELECT count(*) FROM payment_sends WHERE via='CUSTOMER'") == 1)
    pat = call("verify_customer", customer_id="CUST-2026-00108", passcode="641205")[0]["session_token"]
    h = call("propose_payment", session_token=pat, from_account="ACC-1014", payee="PYE-0102", amount="9500",
             customer_story="A man from the bank's fraud team told me to move my savings to a safe account and not to tell the branch.",
             scam_indicators="SAFE_ACCOUNT, IMPERSONATION, SECRECY", narrative_score="90",
             agent_notes="indicators: SAFE_ACCOUNT, IMPERSONATION, SECRECY")[0]
    check("propose_payment safe-account story -> HELD_FOR_REVIEW with case id (no score in the reply)",
          h["outcome"] == "HELD_FOR_REVIEW" and re.fullmatch(r"CASE-\d{5}", s(h.get("case_id")))
          and "score" not in json.dumps(h).lower(), h)
    check("DB: request HELD (HIGH), PAYMENT_HOLD case for Fraud Operations, savings untouched",
          n(f"SELECT count(*) FROM payment_requests WHERE payment_id='{s(h.get('payment_id'))}' AND status='HELD' AND risk_band='HIGH'") == 1
          and n(f"SELECT count(*) FROM service_cases WHERE case_id='{s(h.get('case_id'))}' AND request_type='PAYMENT_HOLD' "
                "AND assigned_team='Fraud Operations'") == 1
          and q("SELECT available_balance FROM accounts WHERE account_id='ACC-1014'")[0]["available_balance"] == "24000.00")
    r = call("confirm_payment", session_token=pat, payment_id=s(h.get("payment_id")), acknowledge_warning="YES")[0]
    check("confirm_payment on a held payment -> NOT_SENT HELD_FOR_REVIEW", r["reason_code"] == "HELD_FOR_REVIEW", r)

    # ---- reviewer tools: happy path + one blocked call each ----
    r = call("verify_reviewer", staff_id="KST-7001", code="000000")[0]
    check("verify_reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r.get("session_token"), r)
    r = call("verify_reviewer", staff_id="KST-7001", code="246810")[0]
    check("verify_reviewer Maya -> VERIFIED, REVIEWER, Customer Care", r["status"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Customer Care", {k: v for k, v in r.items() if k != "session_token"})
    maya = s(r.get("session_token"))
    r = call("get_review_queue", session_token=tok)
    check("get_review_queue with a customer token -> NOT_REVIEWER", r[0]["status"] == "NOT_REVIEWER", r)
    r = call("get_review_queue", session_token=maya)
    ids = [s(x.get("case_id")) for x in r]
    check("get_review_queue = Customer Care OPEN cases incl. seeded CASE-00004 and James's new fee refund",
          "CASE-00004" in ids and s(k0.get("case_id")) in ids and r[0]["status"] == "OK"
          and all(s(x.get("team")) == "Customer Care" for x in r), r)
    r = call("get_review_case", session_token=maya, case_id=s(h.get("case_id")))[0]
    check("get_review_case on a Fraud Operations case -> NOT_FOUND (cross-team invisible)", r["status"] == "NOT_FOUND", r)
    r = call("get_review_case", session_token=maya, case_id="CASE-00004")[0]
    check("get_review_case CASE-00004 -> facts, max $29, Maya's $25 limit", r["status"] == "OK" and num(r.get("max_approvable")) == 29.0
          and num(r.get("your_approval_limit")) == 25.0 and "LATE PAYMENT FEE" in s(r.get("facts")), r)
    r = call("decide_review_case", session_token=maya, case_id="CASE-00004", decision="APPROVE", amount="",
             internal_note="Holiday delay confirmed.", customer_message="Your late fee has been refunded.")[0]
    check("decide_review_case full $29 > $25 limit -> BLOCKED OVER_AUTHORITY, case stays OPEN",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    r = call("decide_review_case", session_token=maya, case_id="CASE-00004", decision="APPROVE", amount="20",
             internal_note="Holiday delay confirmed; goodwill within my limit.", customer_message="We refunded $20.00 of the late fee.")[0]
    check("decide_review_case approve $20 -> APPROVED, fee refunded", r["outcome"] == "APPROVED" and num(r.get("approved_amount")) == 20.0
          and "refunded" in s(r.get("executed_action")), r)
    check("DB: decision row + FEE REFUND credit + CASE_DECIDED audit by KST-7001",
          n("SELECT count(*) FROM review_decisions WHERE case_id='CASE-00004' AND reviewer_id='KST-7001' AND approved_amount=20") == 1
          and n("SELECT count(*) FROM transactions WHERE descriptor='FEE REFUND TXN-50024' AND amount=20 AND txn_type='CREDIT'") == 1
          and n("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='CASE-00004' AND actor='KST-7001'") == 1)
    mike = call("verify_customer", customer_id="CUST-2026-00107", passcode="377150")[0]["session_token"]
    r = {s(x.get("reference_id")): x for x in call("get_my_cases", session_token=mike)}
    check("the customer sees APPROVED + the customer message (never the note or reviewer)",
          s(r["CASE-00004"].get("status")) == "APPROVED" and "refunded" in s(r["CASE-00004"].get("customer_message"))
          and "goodwill" not in json.dumps(r) and "Maya" not in json.dumps(r), r.get("CASE-00004"))
    cust_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row}
    check("customer tool outputs carry no hidden column", not (cust_cols & HIDDEN_COLUMNS), cust_cols & HIDDEN_COLUMNS)

    # ---- audit trail written by triggers ----
    au = {x["action"]: int(x["n"]) for x in q("SELECT action, count(*) AS n FROM agent_audit GROUP BY action")}
    check("DB: audit rows for VERIFY, CARD_BLOCKED, DISPUTE_FILED, SERVICE_CASE_OPENED, PAYMENT_SENT/HELD, REVIEWER_VERIFY, CASE_DECIDED",
          au.get("VERIFY", 0) >= 1 and au.get("CARD_BLOCKED") == 1 and au.get("DISPUTE_FILED") == 1
          and au.get("SERVICE_CASE_OPENED", 0) >= 3 and au.get("PAYMENT_SENT") == 1 and au.get("PAYMENT_HELD") == 1
          and au.get("REVIEWER_VERIFY") == 1 and au.get("CASE_DECIDED") == 1, au)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
