#!/usr/bin/env python3
"""Test ladder step 3: call the running PowerUtilityMCPServer tools directly - no LLM - to prove the rules hold at
the MCP edge (customer tools AND the reviewer loop), asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9942/powerutilitymcp), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (power_distribution_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Sends ONE real confirmation email (Laura's outage report) to the
EMAIL_TO app property."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, CUSTOMER_HIDDEN, CUSTOMER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9942/powerutilitymcp")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "power_distribution_governed"),
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
LAURA, GRACE, HENRY, OLIVIA, MARIA = "RPL-100101", "RPL-100106", "RPL-100107", "RPL-100108", "RPL-100116"

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 22 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 22,
          {"missing": sorted(set(SPEC) - set(tools)), "extra": sorted(set(tools) - set(SPEC))})
    ann = {k: tools[k].get("annotations", {}) for k in tools if k in SPEC}
    # The MCP connector omits readOnlyHint/idempotentHint when false (Go omitempty); absent = false per the MCP spec.
    # destructiveHint defaults to TRUE when absent, so it must be present and False on writes.
    check("readOnlyHint is a real boolean matching tool_spec on every tool (absent = false)",
          all(ann[k].get("readOnlyHint", False) is SPEC[k]["readonly"] for k in ann), ann)
    check("write tools: idempotentHint false, destructiveHint present and false",
          all(ann[k].get("idempotentHint", False) is False and ann[k].get("destructiveHint") is False
              for k in ann if not SPEC[k]["readonly"]), {k: ann[k] for k in ann if not SPEC[k]["readonly"]})
    bad_schema = [k for k in tools if k in SPEC
                  and not all(a in json.dumps(tools[k].get("inputSchema")) for a, _ in SPEC[k]["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- identity ----
    r = one("verify_customer", account_number="RPL-100101", code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_customer", account_number="100101", code="4821")
    check("Laura '100101' + code -> VERIFIED + token + first name",
          r["outcome"] == "VERIFIED" and r.get("session_token") and r.get("first_name") == "Laura",
          {k: v for k, v in r.items() if k != "session_token"})
    laura = s(r.get("session_token")) or "missing"
    grace = s(one("verify_customer", account_number="RPL 100106", code="9164").get("session_token")) or "missing"
    henry = s(one("verify_customer", account_number="RPL-100107", code="7305").get("session_token")) or "missing"
    olivia = s(one("verify_customer", account_number="RPL-100108", code="8150").get("session_token")) or "missing"
    maria = s(one("verify_customer", account_number="rpl-100116", code="2210").get("session_token")) or "missing"
    check("Grace, Henry, Olivia and Maria also verify", "missing" not in (grace, henry, olivia, maria))

    # ---- SESSION_INVALID / NOT_REVIEWER with a bogus token on every read tool ----
    for t in TOOLS:
        if not t["readonly"]:
            continue
        args = {a: (BAD if a == "session_token" else "X") for a, _ in t["args"]}
        r = one(t["tool"], **args)
        want = "SESSION_INVALID" if t["tool"] in CUSTOMER_TOOLS else "NOT_REVIEWER"
        check(f"{t['tool']}: forged token -> {want}", r.get("status") == want, r)

    # ---- scoped reads ----
    a = one("get_my_account", session_token=laura)
    check("account: Laura STANDARD, SMART, CONNECTED", a["plan_code"] == "STANDARD" and a["meter_type"] == "SMART"
          and a["connection_status"] == "CONNECTED", a)
    bills = call("get_my_bills", session_token=laura)
    check("bills: newest $125.19", num(bills[0]["total"]) == 125.19, bills[0])
    hb = call("get_my_bills", session_token=henry)
    r = call("get_bill_detail", session_token=laura, bill_id=hb[0]["bill_id"])
    check("SCOPE: Henry's bill via Laura -> NOT_FOUND", len(r) == 1 and r[0]["status"] == "NOT_FOUND", r)
    cmp_ = {x["category"]: x for x in call("get_bill_comparison", session_token=laura)}
    check("comparison: $105.92 -> $125.19, energy delta $13.95, +53% vs last year",
          num(cmp_["energy"]["latest_total"]) == 125.19 and num(cmp_["energy"]["delta"]) == 13.95
          and num(cmp_["energy"]["kwh_change_vs_last_year_pct"]) == 53, cmp_.get("energy"))
    check("usage: 3 months", len(call("get_my_usage", session_token=laura)) == 3)
    p = one("get_my_payments", session_token=henry)
    check("payments: Henry past due $142.48", num(p["past_due_amount"]) == 142.48 and p["past_due"] == "yes", p)
    po = {x["plan_code"]: x for x in call("get_plan_options", session_token=laura)}
    check("plan options: EV est $74.27 saves $5.88 eligible", num(po["EV"]["est_monthly_cost"]) == 74.27
          and num(po["EV"]["est_monthly_savings"]) == 5.88 and po["EV"]["eligible"] == "yes", po.get("EV"))
    o = one("get_area_outages", session_token=laura)
    check("outages: OUT-2026-0041 in Oak Hollow", o["outage_id"] == "OUT-2026-0041", o)
    check("activity: Laura none yet", one("get_my_service_activity", session_token=laura)["status"] == "NO_ACTIVITY")
    sl = call("get_appointment_slots", session_token=grace, appointment_type="METER_UPGRADE")
    check("slots: Grace can book an upgrade; full/past slots hidden", sl and all(x["allowed"] == "yes" for x in sl)
          and not {"SLOT-01", "SLOT-02"} & {x["slot_id"] for x in sl}, sl)

    # ---- two-step outage report: propose -> confirm (linked) ----
    r = one("propose_action", session_token=laura, action_type="REPORT_OUTAGE", target="NO_POWER")
    check("propose REPORT_OUTAGE -> PROPOSED, linked to OUT-2026-0041", r["outcome"] == "PROPOSED"
          and r.get("linked_outage_id") == "OUT-2026-0041", r)
    check("DB: nothing executed yet", n("SELECT count(*) FROM account_events") == 0 and n("SELECT count(*) FROM outage_tickets WHERE customer_id='RPL-100101'") == 0)
    r = one("confirm_action", session_token=laura, proposal_id=s(r.get("proposal_id")))
    check("confirm -> EXECUTED, ticket LINKED", r["outcome"] == "EXECUTED" and r.get("ticket_type") == "LINKED", r)
    ref_outage = s(r.get("reference"))
    check("DB: one LINKED ticket for Laura", n("SELECT count(*) FROM outage_tickets WHERE customer_id='RPL-100101' AND ticket_type='LINKED'") == 1)
    r = one("propose_action", session_token=grace, action_type="CHANGE_RATE_PLAN", target="TOU")
    check("guard: Grace TOU -> BLOCKED SMART_METER_REQUIRED", r["outcome"] == "BLOCKED" and r.get("reason_code") == "SMART_METER_REQUIRED", r)
    r = one("propose_action", session_token=laura, action_type="CHANGE_RATE_PLAN", target="EV")
    r = one("confirm_action", session_token=laura, proposal_id=s(r.get("proposal_id")))
    check("rate plan EV two-step -> EXECUTED, plan change SCHEDULED", r["outcome"] == "EXECUTED"
          and n("SELECT count(*) FROM plan_changes WHERE customer_id='RPL-100101' AND status='SCHEDULED'") == 1, r)

    # ---- single-step guarded writes ----
    r = one("book_appointment", session_token=grace, appointment_type="METER_UPGRADE", slot_id="SLOT-03")
    check("book upgrade -> BOOKED", r["outcome"] == "BOOKED" and s(r.get("appointment_id")).startswith("APPT-"), r)
    r = one("book_appointment", session_token=grace, appointment_type="METER_INSPECTION", slot_id="SLOT-02")
    check("full slot -> BLOCKED SLOT_FULL", r.get("reason_code") == "SLOT_FULL", r)
    r = one("request_reconnect", session_token=henry)
    check("Henry reconnect -> BLOCKED PAST_DUE $142.48", r["outcome"] == "BLOCKED" and r.get("reason_code") == "PAST_DUE"
          and num(r.get("amount_due")) == 142.48, r)
    check("DB: no service order for Henry", n("SELECT count(*) FROM service_orders WHERE customer_id='RPL-100107'") == 0)
    r = one("request_reconnect", session_token=maria)
    check("Maria reconnect -> RECONNECT_SCHEDULED", r["outcome"] == "RECONNECT_SCHEDULED", r)

    # ---- human-owned case + the reviewer loop ----
    r = one("open_service_case", session_token=grace, request_type="billing_dispute",
            summary="My meter was not read and the estimate is far too high.",
            agent_brief="Latest bill on an ESTIMATED read: 1,700 kWh vs 1,150 kWh last year.", requested_amount="")
    check("Grace billing_dispute -> OPENED, Billing Review", r["outcome"] == "OPENED" and r.get("team") == "Billing Review", r)
    gcase = s(r.get("case_id"))
    r = one("open_service_case", session_token=henry, request_type="payment_arrangement", summary="Need installments.",
            agent_brief="", requested_amount="")
    hcase = s(r.get("case_id"))
    check("Henry payment_arrangement -> OPENED, Credit & Collections", r.get("team") == "Credit & Collections", r)
    r = one("verify_reviewer", staff_id="RPL-S-201", code="0000")
    check("reviewer wrong code -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="RPL-S-201", code="5150")
    check("Avery -> VERIFIED REVIEWER Billing Review", r["outcome"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Billing Review", {k: v for k, v in r.items() if k != "session_token"})
    avery = s(r.get("session_token")) or "missing"
    jordan = s(one("verify_reviewer", staff_id="305", code="7720").get("session_token")) or "missing"
    check("customer token on the queue -> NOT_REVIEWER", one("get_review_queue", session_token=grace)["status"] == "NOT_REVIEWER")
    queue = call("get_review_queue", session_token=avery)
    check("Avery's queue has Grace's case, not Henry's", gcase in {x["case_id"] for x in queue} and hcase not in {x["case_id"] for x in queue}, queue)
    rc = one("get_review_case", session_token=avery, case_id=gcase)
    check("review case: eligible max $98.79, ESTIMATED in facts", num(rc.get("eligible_max_amount")) == 98.79 and "ESTIMATED" in s(rc.get("facts")), rc)
    check("cross-team case -> NOT_FOUND", one("get_review_case", session_token=avery, case_id=hcase)["status"] == "NOT_FOUND")
    d = one("decide_review_case", session_token=grace, case_id=gcase, decision="APPROVE", amount="98.79",
            internal_note="self approval", customer_message="ok")
    check("customer self-approve -> NOT_REVIEWER, no decision", d["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, d)
    d = one("decide_review_case", session_token=avery, case_id=gcase, decision="APPROVE", amount="30", internal_note="ok",
            customer_message="ok")
    check("short note -> NOTE_REQUIRED", d.get("reason_code") == "NOTE_REQUIRED", d)
    d = one("decide_review_case", session_token=jordan, case_id="RPL-CASE-000102", decision="APPROVE", amount="",
            internal_note="Hardship confirmed.", customer_message="Approved.")
    check("Jordan $210 over a $100 limit -> OVER_AUTHORITY, case OPEN", d.get("reason_code") == "OVER_AUTHORITY"
          and n("SELECT count(*) FROM service_cases WHERE case_id='RPL-CASE-000102' AND status='OPEN'") == 1, d)
    d = one("decide_review_case", session_token=avery, case_id=gcase, decision="APPROVE", amount="30",
            internal_note="Meter not read; estimate 48% above last year.", customer_message="We corrected your estimated bill.")
    check("Avery approves $30 -> DECIDED, APPROVED", d["outcome"] == "DECIDED" and d.get("case_status") == "APPROVED", d)
    check("DB: credit line + decision + audit", n(f"SELECT count(*) FROM bill_lines WHERE source_case_id='{gcase}' AND amount=-30") == 1
          and n(f"SELECT count(*) FROM review_decisions WHERE case_id='{gcase}'") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE case_id='{gcase}' AND event='CASE_DECIDED'") == 1)
    d = one("decide_review_case", session_token=avery, case_id=gcase, decision="REJECT", amount="", internal_note="second try",
            customer_message="no")
    check("double decision -> ALREADY_DECIDED", d.get("reason_code") == "ALREADY_DECIDED", d)
    mc = one("get_my_cases", session_token=grace)
    check("Grace sees APPROVED + message, no note", mc["case_status"] == "APPROVED" and "corrected" in s(mc.get("outcome_message"))
          and "48%" not in json.dumps(mc), mc)

    # ---- guarded email: NOT_SENT branch first (no SMTP), then ONE real send ----
    e = one("email_confirmation", session_token=henry, reference=ref_outage)
    check("SCOPE: Henry emails Laura's reference -> NOT_SENT NOT_FOUND (ReturnNotSent branch)",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    check("DB: refused email logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_confirmation", session_token=laura, reference=ref_outage)
        check("email own executed outage report -> SEND_OK", e["send_status"] == "SEND_OK" and ref_outage in s(e.get("subject")), e)
    except (RuntimeError, urllib.error.URLError) as ex:   # SendMail failure surfaces as a tool error
        check("email own executed action -> SEND_OK (SMTP send)", False, f"tool error - check Email_* / EMAIL_TO app properties: {ex}")
    check("DB: exactly one email_log row", n("SELECT count(*) FROM email_log") == 1)

    # ---- hidden columns never leave the DB ----
    leaked = sorted({(t, k) for t, rows in OUTPUTS for row in rows for k in row
                     if k in (CUSTOMER_HIDDEN if t in CUSTOMER_TOOLS else HIDDEN_COLUMNS)})
    check("no tool output carries a hidden column", not leaked, leaked)
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
