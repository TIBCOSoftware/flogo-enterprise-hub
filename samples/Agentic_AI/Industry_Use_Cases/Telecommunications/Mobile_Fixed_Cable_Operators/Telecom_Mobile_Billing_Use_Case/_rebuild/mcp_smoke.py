#!/usr/bin/env python3
"""Test ladder step 3: call the running MobileBillingMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9902/mobilebillingmcpserver), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (mobile_billing), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
Covers the 14 customer tools and the 4 reviewer tools (happy path + one blocked call each: verify, queue, case view,
decide incl. OVER_AUTHORITY, then the parked SIM-swap reversal executed and the customer's view of the outcome).
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (Maria's cancelled StarPlay Games
subscription) to the EMAIL_TO app property: the SQL guard + email_log are asserted, SMTP delivery is reported separately
(the shipped Email_App_Password is a portable placeholder)."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS, PUBLIC_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9902/mobilebillingmcpserver")
DIR = os.path.dirname(HERE)


def _config_value(key):
    path = os.environ.get("CONFIG_MD")
    if not path:
        d = HERE
        while True:
            p = os.path.join(d, "skills-library", ".claude", "skills", "config.md")
            if os.path.exists(p):
                path = p; break
            if os.path.dirname(d) == d:
                break
            d = os.path.dirname(d)
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            m = re.match(r"\|\s*" + key + r"\s*\|\s*`([^`]*)`", line)
            if m:
                v = m.group(1).strip()
                return None if re.fullmatch(r"<[^>]*>", v) else v
    return None


PWD = os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or _config_value("PG_PASSWORD")
if not PWD:
    sys.exit("set PG_PWD or PG_PASSWORD in config.md (PostgreSQL password; used to reset and inspect the DB)")
PSQL = (os.environ.get("PSQL") or _config_value("PSQL_PATH") or shutil.which("psql")
        or sys.exit("psql not found: install the PostgreSQL client and put psql on PATH, or set env PSQL / config.md "
                    "PSQL_PATH (see skills-library/AGENT.md -> Prerequisites and preflight)"))
ENV = dict(os.environ, PGPASSWORD=PWD)
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "mobile_billing"),
        "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0
OUTPUTS = []          # every tool result, for the hidden-column scan


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
    with urllib.request.urlopen(req, timeout=60) as r:
        session = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode()
    if notify or not raw.strip(): return None
    data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
    msg = json.loads(data[-1])
    if "error" in msg: raise RuntimeError(msg["error"])
    return msg["result"]


def call(tool, **args):
    args = {a: args.get(a, "") for a, _ in SPEC[tool]["args"]}        # like the orchestrator: every spec arg
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
    body = json.loads(text)
    rows = (json.loads(body["data"]) if "data" in body else body)["records"]   # both result shapes (runtime-gotchas 6)
    OUTPUTS.append((tool, rows))
    return rows


def one(tool, **args): return call(tool, **args)[0]


# Flogo may hand numbers back as JSON numbers or strings, NULL as null - compare tolerantly
def num(v):
    try: return round(float(str(v).replace("R", "").strip()), 2)
    except (TypeError, ValueError): return None
def s(v): return "" if v is None else str(v)


def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0


SPEC = {t["tool"]: t for t in TOOLS}
BAD = "bogus-token-0000"

MARIA_C, JAMES_C, PRIYA_C, DANA_C = "TW-C-0101", "TW-C-0102", "TW-C-0103", "TW-C-0105"

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 18 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 18,
          {"missing": sorted(set(SPEC) - set(tools)), "extra": sorted(set(tools) - set(SPEC))})
    ann = {k: tools[k].get("annotations", {}) for k in tools if k in SPEC}
    # The MCP connector omits readOnlyHint/idempotentHint when false (Go omitempty); per the MCP spec an absent
    # readOnlyHint/idempotentHint means false, so absent == False here. destructiveHint defaults to TRUE when
    # absent, so it must be present and False.
    check("readOnlyHint is a real boolean matching tool_spec on every tool (absent = false per MCP spec)",
          all(ann[k].get("readOnlyHint", False) is SPEC[k]["readonly"] for k in ann), ann)
    check("write tools: idempotentHint false (absent = false), destructiveHint present and false",
          all(ann[k].get("idempotentHint", False) is False and ann[k].get("destructiveHint") is False
              for k in ann if not SPEC[k]["readonly"]), {k: ann[k] for k in ann if not SPEC[k]["readonly"]})
    bad_schema = [k for k in tools if k in SPEC
                  and not all(a in json.dumps(tools[k].get("inputSchema")) for a, _ in SPEC[k]["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- identity ----
    r = one("verify_customer", mobile_number="2125550101", otp="0000")
    check("wrong OTP -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong OTP created no session", n("SELECT count(*) FROM customer_sessions") == 0)
    r = one("verify_customer", mobile_number="(212) 555-0101", otp="4821")
    check("Maria '(212) 555-0101' + OTP -> VERIFIED + token + first name",
          r["outcome"] == "VERIFIED" and r.get("session_token") and r.get("first_name") == "Maria",
          {k: v for k, v in r.items() if k != "session_token"})
    maria = s(r.get("session_token")) or "missing"
    check("DB: exactly one session, for Maria", n("SELECT count(*) FROM customer_sessions") == 1
          and n(f"SELECT count(*) FROM customer_sessions WHERE customer_id='{MARIA_C}'") == 1)
    james = s(one("verify_customer", mobile_number="+1 212 555 0102", otp="7305").get("session_token")) or "missing"
    priya = s(one("verify_customer", mobile_number="212-555-0103", otp="9164").get("session_token")) or "missing"
    dana = s(one("verify_customer", mobile_number="2125550105", otp="6634").get("session_token")) or "missing"
    check("James (+1 form), Priya (dashes) and Dana also verify", "missing" not in (james, priya, dana))

    # ---- SESSION_INVALID on every scoped tool (no writes, no email with a bogus token) ----
    for t in TOOLS:
        if t["tool"] in PUBLIC_TOOLS:
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = BAD
        row = one(t["tool"], **args)
        code = row.get("reason_code") if t.get("email") else (row.get("status") or row.get("outcome"))
        want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
        check(f"{t['tool']} with bogus token -> {want}", code == want, row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM account_events") == 0 and n("SELECT count(*) FROM service_cases WHERE case_no > 43") == 0
          and n("SELECT count(*) FROM email_log") == 0 and n("SELECT count(*) FROM review_decisions") == 0)

    # ---- scoped reads (Maria); multi-row tools must return ALL rows ----
    a = one("get_my_account", session_token=maria)
    check("get_my_account: ESS15 $45, ACTIVE, no roaming limit, TravelPass not enrolled, AutoPay day present",
          a["status"] == "OK" and a["plan_code"] == "ESS15" and num(a["monthly_price"]) == 45
          and a["account_status"] == "ACTIVE" and s(a.get("roaming_limit")) == "No limit set"
          and s(a.get("travel_pass")) == "Not enrolled" and s(a.get("autopay_day")) != "", a)
    bills = call("get_my_bills", session_token=maria)
    check("get_my_bills: 2 rows, newest $270.00, previous $52.00", len(bills) == 2
          and num(bills[0]["total"]) == 270.00 and num(bills[1]["total"]) == 52.00, bills)
    latest = s(bills[0].get("bill_id"))
    d = call("get_bill_detail", session_token=maria, bill_id=latest)
    cats = {s(x.get("category")) for x in d}
    check("get_bill_detail: PLAN + Mexico ROAMING + PREMIUM_CONTENT (StarPlay $9.99) + TAXES_FEES",
          d[0]["status"] == "OK" and {"PLAN", "ROAMING", "PREMIUM_CONTENT", "TAXES_FEES"} <= cats
          and any("Mexico" in s(x.get("description")) for x in d if x.get("category") == "ROAMING")
          and any("StarPlay" in s(x.get("description")) and num(x.get("amount")) == 9.99 for x in d), d)
    j_bill = s(call("get_my_bills", session_token=james)[0].get("bill_id"))
    d = call("get_bill_detail", session_token=maria, bill_id=j_bill)
    check("SCOPE: Maria asks for James's bill -> one NOT_FOUND row, nothing leaked",
          len(d) == 1 and d[0]["status"] == "NOT_FOUND" and not d[0].get("description") and not d[0].get("amount"), d)
    cmp_ = {s(x.get("category")): x for x in call("get_bill_comparison", session_token=maria)}
    check("get_bill_comparison: 6 category rows", set(cmp_) == {"plan", "roaming", "premium_content", "voice_sms",
                                                                  "taxes_fees", "other"}, list(cmp_))
    check("comparison deltas from SQL: roaming +206.47, premium_content +9.99, plan 0",
          num(cmp_.get("roaming", {}).get("delta")) == 206.47
          and num(cmp_.get("premium_content", {}).get("delta")) == 9.99
          and num(cmp_.get("plan", {}).get("delta")) == 0, cmp_)
    u = one("get_my_usage", session_token=maria)
    check("get_my_usage: 15 GB allowance, 0 roaming days this cycle, last cycles incl. 'Mexico 4 days'",
          u["status"] == "OK" and s(u.get("data_allowance_gb")) == "15 GB" and num(u.get("roaming_days_this_cycle")) == 0
          and s(u.get("data_gb_last_3_cycles")).count("GB") == 3 and "Mexico 4 days" in s(u.get("roaming_days_last_3_cycles")), u)
    subs = {s(x.get("item_id")): s(x.get("item_status")) for x in call("get_my_subscriptions", session_token=maria)}
    check("get_my_subscriptions: SUB-1001 ACTIVE, SUB-1002 CANCELLED, TRAVELPASS NOT_ENROLLED",
          subs.get("SUB-1001") == "ACTIVE" and subs.get("SUB-1002") == "CANCELLED"
          and subs.get("TRAVELPASS") == "NOT_ENROLLED", subs)
    p = call("get_my_payments", session_token=james)
    check("get_my_payments (James): past due $186.40, balance $268.70, overdue yes, 45 days",
          num(p[0]["past_due_amount"]) == 186.40 and num(p[0]["balance_due"]) == 268.70
          and p[0]["overdue"] == "yes" and num(p[0]["days_overdue"]) == 45, p)
    ep = {s(x.get("plan_code")): x for x in call("get_eligible_plans", session_token=maria)}
    check("get_eligible_plans (Maria): 4 rows, UNLPREM UPGRADE +$40 allowed, roaming_included mentions Mexico",
          len(ep) == 4 and ep.get("UNLPREM", {}).get("change_type") == "UPGRADE"
          and num(ep.get("UNLPREM", {}).get("price_diff")) == 40 and ep["UNLPREM"].get("allowed") == "yes"
          and "Mexico" in s(ep["UNLPREM"].get("roaming_included")), ep)
    ep = {s(x.get("plan_code")): x for x in call("get_eligible_plans", session_token=priya)}
    check("get_eligible_plans (Priya): every option LOCKED_IN", ep and all(x.get("reason_code") == "LOCKED_IN" for x in ep.values()), ep)

    # ---- BLOCKED path: James (past due) asks for TravelPass ----
    r = one("propose_action", session_token=james, action_type="ADD_TRAVEL_PASS", target="ON")
    check("propose ADD_TRAVEL_PASS ON for James -> BLOCKED ARREARS, no proposal_id",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "ARREARS" and r.get("reason_text") and not r.get("proposal_id"), r)
    blk = q(f"SELECT proposal_id FROM pending_actions WHERE customer_id='{JAMES_C}' AND outcome='BLOCKED' LIMIT 1")
    check("DB: blocked proposal recorded with outcome BLOCKED", len(blk) == 1, blk)
    if blk:
        c = one("confirm_action", session_token=james, proposal_id=blk[0]["proposal_id"])
        check("confirming the BLOCKED proposal -> BLOCKED", c["outcome"] == "BLOCKED", c)
    r = one("propose_action", session_token=james, action_type="SET_ROAMING_LIMIT", target="unlimited")
    check("James 'remove' the roaming limit (unlimited) -> BLOCKED INVALID_CAP", r["outcome"] == "BLOCKED"
          and r["reason_code"] == "INVALID_CAP", r)
    check("DB: James has no account_events, no TravelPass, roaming limit still $50",
          n(f"SELECT count(*) FROM account_events WHERE customer_id='{JAMES_C}'") == 0
          and q(f"SELECT coalesce(travel_pass_since::text, 'none') AS v, customer_id FROM customers WHERE customer_id='{JAMES_C}'")[0]["v"] == "none"
          and num(q(f"SELECT roaming_limit AS v, customer_id FROM customers WHERE customer_id='{JAMES_C}'")[0]["v"]) == 50)
    r = one("propose_action", session_token=dana, action_type="SET_ROAMING_LIMIT", target="0")
    check("propose for held account (Dana) -> BLOCKED ACCOUNT_HOLD", r["outcome"] == "BLOCKED"
          and r["reason_code"] == "ACCOUNT_HOLD", r)
    r = one("propose_action", session_token=priya, action_type="CHANGE_PLAN", target="BASIC5")
    check("Priya downgrade to BASIC5 -> BLOCKED LOCKED_IN", r["outcome"] == "BLOCKED" and r["reason_code"] == "LOCKED_IN", r)

    # ---- happy path: propose -> confirm (cancel StarPlay, TravelPass, roaming limit $100) ----
    p1 = one("propose_action", session_token=maria, action_type="CANCEL_SUBSCRIPTION", target="SUB-1001")
    check("propose CANCEL_SUBSCRIPTION SUB-1001 -> PROPOSED with summary + expiry + customer-facing text",
          p1["outcome"] == "PROPOSED" and p1.get("proposal_id") and "StarPlay" in s(p1.get("summary")) and p1.get("expires_at")
          and s(p1.get("reason_text")) == "Nothing has changed yet. Reply yes within 15 minutes to go ahead.", p1)
    check("DB: nothing changed before confirm (SUB-1001 still ACTIVE, no events)",
          q("SELECT status FROM content_subscriptions WHERE subscription_id='SUB-1001'")[0]["status"] == "ACTIVE"
          and n("SELECT count(*) FROM account_events") == 0)
    c = one("confirm_action", session_token=james, proposal_id=s(p1.get("proposal_id")))
    check("SCOPE: James confirms Maria's proposal -> NOT_FOUND", c["outcome"] == "NOT_FOUND"
          and n("SELECT count(*) FROM account_events") == 0, c)
    c1 = one("confirm_action", session_token=maria, proposal_id=s(p1.get("proposal_id")))
    ref_cancel = s(c1.get("reference"))
    check("confirm -> EXECUTED with TW-ACT-nnnnnn reference", c1["outcome"] == "EXECUTED"
          and re.fullmatch(r"TW-ACT-\d{6}", ref_cancel), c1)
    check("DB: one account_events row, SUB-1001 CANCELLED by trigger",
          n(f"SELECT count(*) FROM account_events WHERE reference='{ref_cancel}' AND customer_id='{MARIA_C}'") == 1
          and q("SELECT status FROM content_subscriptions WHERE subscription_id='SUB-1001'")[0]["status"] == "CANCELLED")
    c2 = one("confirm_action", session_token=maria, proposal_id=s(p1.get("proposal_id")))
    check("re-confirm -> ALREADY_DONE, same reference, still one event", c2["outcome"] == "ALREADY_DONE"
          and s(c2.get("reference")) == ref_cancel and n("SELECT count(*) FROM account_events") == 1, c2)
    pt = one("propose_action", session_token=maria, action_type="ADD_TRAVEL_PASS", target="ON")
    ct = one("confirm_action", session_token=maria, proposal_id=s(pt.get("proposal_id")))
    check("ADD_TRAVEL_PASS ON: PROPOSED ($10 per day) -> EXECUTED", pt["outcome"] == "PROPOSED"
          and "$10 per day" in s(pt.get("summary")) and ct["outcome"] == "EXECUTED", (pt, ct))
    check("DB: Maria's travel_pass_since set by trigger",
          q(f"SELECT (travel_pass_since IS NOT NULL)::text AS v, customer_id FROM customers WHERE customer_id='{MARIA_C}'")[0]["v"] == "true")
    pl = one("propose_action", session_token=maria, action_type="SET_ROAMING_LIMIT", target="100")
    cl = one("confirm_action", session_token=maria, proposal_id=s(pl.get("proposal_id")))
    check("SET_ROAMING_LIMIT 100: PROPOSED -> EXECUTED", pl["outcome"] == "PROPOSED" and cl["outcome"] == "EXECUTED", (pl, cl))
    check("DB: Maria's roaming_limit = 100",
          num(q(f"SELECT roaming_limit AS v, customer_id FROM customers WHERE customer_id='{MARIA_C}'")[0]["v"]) == 100)

    # ---- human-owned request ----
    k = one("open_service_case", session_token=maria, request_type="billing_dispute",
            summary="Customer asks for the $9.99 StarPlay Games charge to be refunded.")
    check("open_service_case billing_dispute -> OPENED, Billing Disputes, 5 business days",
          k["outcome"] == "OPENED" and k.get("team") == "Billing Disputes" and "5 business days" in s(k.get("sla_text"))
          and re.fullmatch(r"TW-CASE-\d{6}", s(k.get("case_id"))), k)
    k2 = one("open_service_case", session_token=maria, request_type="billing_dispute", summary="Again.")
    check("repeat -> EXISTING, same case_id", k2["outcome"] == "EXISTING" and s(k2.get("case_id")) == s(k.get("case_id")), k2)
    k3 = one("open_service_case", session_token=maria, request_type="refund_now", summary="Just refund it.")
    check("unknown type -> INVALID_TYPE, no team, customer-facing text (no internal codes)",
          k3["outcome"] == "INVALID_TYPE" and not k3.get("team") and "billing_dispute" not in s(k3.get("reason_text")), k3)
    kf = one("open_service_case", session_token=priya, request_type="suspected_fraud",
             summary="Does not recognise a Canada roaming charge; never left the US; recent SIM swap.",
             brief="category: SUSPECTED_FRAUD\nnext_path: open_fraud_case", reference="")
    check("Priya suspected_fraud -> OPENED, Fraud Team, requested $96.32, if_approved names the SIM-swap reversal",
          kf["outcome"] == "OPENED" and kf.get("team") == "Fraud Team" and num(kf.get("requested_amount")) == 96.32
          and "SIM swap" in s(kf.get("if_approved")), kf)
    PCASE = s(kf.get("case_id"))
    check("DB: SQL parked SIM_SWAP_REVERSAL on Priya's latest bill with the brief stored",
          n(f"SELECT count(*) FROM service_cases WHERE case_id='{PCASE}' AND parked_action LIKE 'SIM_SWAP_REVERSAL:TWB-0103-%' "
            f"AND requested_amount=96.32 AND agent_brief LIKE 'category: SUSPECTED_FRAUD%'") == 1)
    kb = one("open_service_case", session_token=james, request_type="billing_dispute", summary="x", brief="",
             reference=latest)
    check("SCOPE: James disputes Maria's bill id -> BAD_REFERENCE, no case", kb["outcome"] == "BAD_REFERENCE"
          and not kb.get("case_id"), kb)
    check("DB: two new service cases (Maria billing_dispute, Priya suspected_fraud) + 3 seeded; no credit rows",
          n("SELECT count(*) FROM service_cases WHERE case_no > 43") == 2
          and n(f"SELECT count(*) FROM service_cases WHERE customer_id='{MARIA_C}' AND request_type='billing_dispute'") == 1
          and n(f"SELECT count(*) FROM service_cases WHERE customer_id='{PRIYA_C}' AND request_type='suspected_fraud'") == 1
          and n("SELECT count(*) FROM bill_lines WHERE amount < 0") == 0)

    # ---- guarded email: NOT_SENT branch first (no SMTP), then ONE real send ----
    e = one("email_action_confirmation", session_token=james, reference=ref_cancel)
    check("SCOPE: James emails Maria's reference -> NOT_SENT NOT_FOUND, no details (ReturnNotSent branch)",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND" and "StarPlay" not in s(e.get("body")), e)
    e = one("email_action_confirmation", session_token=maria, reference="TW-ACT-999999")
    check("email unknown reference -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    check("DB: refused email requests logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_action_confirmation", session_token=maria, reference=ref_cancel)
        check("email own EXECUTED action -> SEND_OK, readback row returned after SendMail (SMTP delivered)",
              e["send_status"] == "SEND_OK" and ref_cancel in s(e.get("subject")) and "StarPlay" in s(e.get("body")), e)
    except (RuntimeError, urllib.error.URLError) as ex:   # SendMail failure surfaces as a tool error
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request was logged (SQL guard passed): exactly one email_log row, for that reference",
          n("SELECT count(*) FROM email_log") == 1 and n(f"SELECT count(*) FROM email_log WHERE reference='{ref_cancel}'") == 1)

    # ---- reviewer loop over MCP: verify -> queue -> case -> decide (one blocked call each) -> executed -> customer view
    r = one("verify_reviewer", staff_id="TWS-7002", code="000000")
    check("verify_reviewer wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="TWS-7002", code="562039")
    jordan = s(r.get("session_token")) or "missing"
    check("verify_reviewer Jordan (Fraud Team) -> VERIFIED, role REVIEWER", r["outcome"] == "VERIFIED"
          and r.get("role") == "REVIEWER" and r.get("team") == "Fraud Team", {k: v for k, v in r.items() if k != "session_token"})
    alex = s(one("verify_reviewer", staff_id="TWS-7001", code="318274").get("session_token")) or "missing"
    check("DB: two REVIEWER sessions + REVIEWER_VERIFY audit rows",
          n("SELECT count(*) FROM customer_sessions WHERE role='REVIEWER'") == 2
          and n("SELECT count(*) FROM agent_audit WHERE action='REVIEWER_VERIFY'") == 2)
    check("customer token on get_review_queue -> NOT_REVIEWER", one("get_review_queue", session_token=maria)["status"] == "NOT_REVIEWER")
    qj = {s(x.get("case_id")) for x in call("get_review_queue", session_token=jordan)}
    check("Fraud Team queue: Dana's seeded case + Priya's new case (multi-row)", qj == {"TW-CASE-000042", PCASE}, qj)
    rc = one("get_review_case", session_token=jordan, case_id=PCASE)
    check("get_review_case: brief, $96.32 eligible, SIM-swap + no-roaming-record facts", rc["status"] == "OK"
          and num(rc.get("max_approvable")) == 96.32 and "SIM swap on" in s(rc.get("facts"))
          and "SUSPECTED_FRAUD" in s(rc.get("agent_brief")), rc)
    check("another team's case is invisible to Alex -> NOT_FOUND",
          one("get_review_case", session_token=alex, case_id=PCASE)["status"] == "NOT_FOUND")
    d = one("decide_review_case", session_token=alex, case_id="TW-CASE-000041", decision="APPROVE", amount="",
            internal_note="Duplicate confirmed on the bill.", customer_message="Credited.")
    check("decide: Alex approves Grace's full $69.98 above his $60 limit -> BLOCKED OVER_AUTHORITY, case stays OPEN",
          d["outcome"] == "BLOCKED" and d.get("reason_code") == "OVER_AUTHORITY" and d.get("case_status") == "OPEN", d)
    check("DB: blocked decision wrote nothing", n("SELECT count(*) FROM review_decisions") == 0 and n("SELECT count(*) FROM case_actions") == 0)
    d = one("decide_review_case", session_token=jordan, case_id=PCASE, decision="APPROVE", amount="",
            internal_note="No days abroad on record; SIM swap without ID check.",
            customer_message="We reversed the SIM swap and credited the Canada roaming charges.")
    check("decide: Jordan approves Priya's case -> APPROVED, SIM swap reversed + $96.32 credited (executed_action)",
          d["outcome"] == "APPROVED" and num(d.get("approved_amount")) == 96.32 and "SIM swap reversed" in s(d.get("executed_action")), d)
    check("DB: decision row, case_actions SIM_SWAP_REVERSAL $96.32, sim_swap_reversed_at set, -$96.32 credit, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{PCASE}' AND reviewer_id='TWS-7002'") == 1
          and n(f"SELECT count(*) FROM case_actions WHERE case_id='{PCASE}' AND kind='SIM_SWAP_REVERSAL' AND credit_amount=96.32") == 1
          and n(f"SELECT count(*) FROM customers WHERE customer_id='{PRIYA_C}' AND sim_swap_reversed_at IS NOT NULL") == 1
          and n(f"SELECT count(*) FROM unbilled_charges WHERE customer_id='{PRIYA_C}' AND amount=-96.32") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='{PCASE}' AND actor='TWS-7002'") == 1)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=priya)}
    check("get_my_cases (Priya): APPROVED with the customer message, no internal note column",
          mc.get(PCASE, {}).get("case_status") == "APPROVED" and "reversed the SIM swap" in s(mc[PCASE].get("customer_message"))
          and "internal_note" not in mc[PCASE], mc)
    try:
        e = one("email_action_confirmation", session_token=priya, reference=PCASE)
        check("email the decided case -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK", e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check("DB: the decided-case email request was logged (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference='{PCASE}' AND customer_id='{PRIYA_C}'") == 1)
    rev_cols = {k for t, rows in OUTPUTS if t in REVIEWER_TOOLS for row in rows for k in row}
    check("reviewer tool outputs carry no mobile number / email / SSN / OTP / last name / customer id column",
          not (rev_cols & HIDDEN_FROM_REVIEWER), rev_cols & HIDDEN_FROM_REVIEWER)

    # ---- hidden columns never leave the DB ----
    leaked = sorted({k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no customer tool output carries a hidden column", not leaked, leaked)
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
