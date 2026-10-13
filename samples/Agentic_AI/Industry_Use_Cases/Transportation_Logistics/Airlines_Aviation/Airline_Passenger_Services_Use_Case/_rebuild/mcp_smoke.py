#!/usr/bin/env python3
"""Step 3: call the running PassengerServicesMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, then:   PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9852/passenger-services-gov-mcp), PG_DB (airline_governed), PG_HOST/PG_PORT/PG_USER,
PSQL. Covers the 12 traveller tools (verify, scoped reads, two-step rebook, guarded email, routed cases, baggage claim,
assistance request) and the 4 reviewer tools (happy path + one blocked call each, parked actions executed).
The DB is reset (reset_data.sql) before and after."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, REVIEWER_TOOLS, PUBLIC_TOOLS, HIDDEN_COLUMNS

URL = os.environ.get("MCP_URL", "http://localhost:9852/passenger-services-gov-mcp")
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# psql + password lookup (cross-platform): env PSQL > config.md PSQL_PATH > psql on PATH;
# password: env PG_PWD / PG_PASSWORD > config.md PG_PASSWORD (never printed). Install hints: skills-library/AGENT.md
# -> "Prerequisites and preflight".
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "airline_governed"),
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
    args = {a: args.get(a, "") for a in SPEC_ARGS[tool]}          # every spec arg is sent (required in the schema)
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
    body = json.loads(text)
    rows = (json.loads(body["data"]) if "data" in body else body)["records"]
    OUTPUTS.append((tool, rows))
    return rows

# Flogo may hand numbers back as JSON numbers or as strings - compare tolerantly
def num(v):
    try: return round(float(v), 2)
    except (TypeError, ValueError): return None
def s(v): return "" if v is None else str(v)

def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0

def truthy(v): return v is True or str(v).lower() in ("true", "t")

def email_send(tok, ref):
    """An AUTHORISED email: the SQL guard logs it, then the flow sends via SMTP. With the shipped dummy Email_App_Password
    the SMTP step fails and the tool returns an error - reported as a NOTE; the email_log guard row is asserted instead."""
    try:
        e = call("email_my_confirmation", session_token=tok, action_id=ref)[0]
        out(f"NOTE email {ref}: SMTP delivered ({e.get('send_status')})")
    except Exception as ex:                       # noqa: BLE001 - the SQL guard is asserted by the caller either way
        out(f"NOTE email {ref}: SMTP send failed (expected with the dummy Email_App_Password): {str(ex)[:120]}")

reset()
rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
rpc("notifications/initialized", notify=True)
tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
check(f"{len(TOOLS)} tools listed, names match tool_spec", set(tools) == {t["tool"] for t in TOOLS}, sorted(tools))
hints = lambda name: tools[name].get("annotations", {}) or {}
check("readOnlyHint=true on every read tool, never on a write tool",
      all((hints(t["tool"]).get("readOnlyHint") is True) == t["readonly"] for t in TOOLS),
      {t["tool"]: hints(t["tool"]).get("readOnlyHint") for t in TOOLS})
check("decide_review_case: destructiveHint / idempotentHint not true (false hints are omitted from tools/list)",
      hints("decide_review_case").get("destructiveHint") is not True and hints("decide_review_case").get("idempotentHint") is not True,
      hints("decide_review_case"))
check("arguments schema published (record_baggage_claim has agent_answer)",
      "agent_answer" in json.dumps(tools["record_baggage_claim"].get("inputSchema")), tools["record_baggage_claim"])

# ---- the original traveller path ----
r = call("verify_traveller", pnr="ABCDE1", pin="0000")
check("wrong PIN -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_traveller", pnr="ABCDE1", pin="4821")
check("right PNR+PIN -> VERIFIED", r[0]["status"] == "VERIFIED", r)
tok = r[0]["session_token"]
r = call("get_my_itinerary", session_token=tok)
check("scoped itinerary = 2 legs", len([x for x in r if x["flight_number"]]) == 2, r)
r = call("get_flight_status", session_token=tok, flight_number="FL302")
check("flight not on the itinerary -> NOT_ON_ITINERARY", r[0]["lookup_status"] == "NOT_ON_ITINERARY", r)
r = call("get_my_loyalty", session_token=tok)
check("loyalty = Gold", r[0]["tier"] == "Gold", r)
r = call("check_connection_risk", session_token=tok)
check("connection risk computed -> MISSED", any(x["risk"] == "MISSED" for x in r), r)
r = call("propose_rebook", session_token=tok, current_flight="FL445", new_flight="FL445")
check("guard: same flight", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SAME_FLIGHT"), r)
p = call("propose_rebook", session_token=tok, current_flight="FL445", new_flight="FL447")[0]
check("eligible -> PROPOSED", p["outcome"] == "PROPOSED" and p["action_id"], p)
c = call("confirm_rebook", session_token=tok, action_id=p["action_id"])[0]
check("confirm -> EXECUTED on FL447", c["outcome"] == "EXECUTED" and c["to_flight"] == "FL447", c)
email_send(tok, p["action_id"])
check("email authorised -> the SQL guard passed: logged once in email_log",
      n(f"SELECT count(*) FROM email_log WHERE reference_id = '{p['action_id']}'") == 1)
e = call("email_my_confirmation", session_token=tok, action_id="ACT-00000000")[0]
check("email unauthorised -> NOT_SENT, nothing logged", e["send_status"] == "NOT_SENT" and n("SELECT count(*) FROM email_log") == 1, e)
k = call("open_service_case", session_token=tok, request_type="COMPENSATION_CLAIM",
         traveler_statement="FL801 delayed 90 minutes; I want compensation.",
         brief="90-minute inbound delay caused a missed connection; traveller requests compensation.", amount="")[0]
check("compensation case -> Customer Care, parked with the $100 band maximum",
      k["outcome"] == "CASE_OPENED" and "Customer Care" in k["assigned_team"] and num(k["requested_amount"]) == 100, k)
ccase = k["case_id"]
r = call("get_my_itinerary", session_token="forged")
check("forged token -> SESSION_INVALID", r[0]["session_status"] == "SESSION_INVALID", r)

# ---- baggage claim (agent answer validated in SQL) ----
linda = call("verify_traveller", pnr="WXYZA7", pin="3046")[0]["session_token"]
ANS = ("claim_type: DELAYED\nbag_type: 22 - Upright suitcase, soft-sided\ncolour: BU\ncontents: CLOTHING, ELECTRONICS\n"
       "missing_fields: BRAND, DELIVERY_ADDRESS\nclaim_note: Keep the receipts for any essentials you buy while you wait; "
       "Meridian Baggage Services decides any reimbursement and replies by the date on your case.")
b = call("record_baggage_claim", session_token=linda, flight_number="FL801", description="Blue bag.", interim_amount="", agent_answer=ANS)[0]
check("baggage: flight not on the booking -> NOT_RECORDED NOT_FOUND", b["outcome"] == "NOT_RECORDED" and b["reason_code"] == "NOT_FOUND", b)
b = call("record_baggage_claim", session_token=linda, flight_number="FL721",
         description="Blue soft-sided upright suitcase, a suit and a laptop charger inside.", interim_amount="300", agent_answer=ANS)[0]
check("baggage: RECORDED DELAYED, Baggage Services case, BAG_TAG flagged by the rule, $300 interim",
      b["outcome"] == "RECORDED" and b["claim_type"] == "DELAYED" and b["assigned_team"] == "Baggage Services"
      and s(b["missing_fields"]).startswith("BAG_TAG") and num(b["interim_requested"]) == 300, b)
lcase = b["case_id"]
check("DB: Linda's case parked INTERIM_EXPENSE:<claim>",
      n(f"SELECT count(*) FROM service_cases WHERE case_id = '{lcase}' AND parked_action = 'INTERIM_EXPENSE:{b['claim_id']}'") == 1)

# ---- special assistance ----
rosa = call("verify_traveller", pnr="HJKLM8", pin="2468")[0]["session_token"]
a = call("request_assistance", session_token=rosa, flight_number="FL305", needs="I can walk to my seat but not up the stairs.",
         agent_answer="ssr_codes: NONE")[0]
check("assistance: no usable code -> NOT_RECORDED NO_VALID_CODES", a["outcome"] == "NOT_RECORDED" and a["reason_code"] == "NO_VALID_CODES", a)
a = call("request_assistance", session_token=rosa, flight_number="FL305", needs="I can walk to my seat but not up the stairs.",
         agent_answer="ssr_codes: WCHS\ncodes:\n- WCHS: ...\nmedical_clearance: NO")[0]
check("assistance: WCHS -> REQUESTED, PENDING_CONFIRMATION, Accessibility Desk",
      a["outcome"] == "REQUESTED" and "WCHS" in s(a["requested_codes"]) and "PENDING_CONFIRMATION" in s(a["requested_codes"])
      and a["assigned_team"] == "Accessibility Desk", a)
rcase = a["case_id"]

# ---- reviewer tools: happy path + one blocked call each ----
r = call("verify_reviewer", staff_id="MER-7001", code="000000")[0]
check("verify_reviewer blocked: wrong code -> NOT_VERIFIED", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = call("verify_reviewer", staff_id="MER-7001", code="246810")[0]
check("verify_reviewer: Dana -> VERIFIED REVIEWER, Baggage Services", r["status"] == "VERIFIED" and r["role"] == "REVIEWER"
      and r["team"] == "Baggage Services", r)
dana = r["session_token"]
qq = call("get_review_queue", session_token=dana)
check("get_review_queue: Baggage Services queue has Linda's new case and the seeded one",
      {lcase, "SC-S0A1B1"} <= {x["case_id"] for x in qq}, [x["case_id"] for x in qq])
check("get_review_queue blocked: a traveller token -> NOT_REVIEWER", call("get_review_queue", session_token=linda)[0]["status"] == "NOT_REVIEWER")
rc = call("get_review_case", session_token=dana, case_id=lcase)[0]
check("get_review_case: facts + agent brief + Dana's $250 limit", rc["status"] == "OK" and num(rc["your_approval_limit"]) == 250
      and "claim_type: DELAYED" in s(rc["agent_brief"]) and "DELAYED" in s(rc["facts"]), rc)
check("get_review_case blocked: another team's case -> NOT_FOUND",
      call("get_review_case", session_token=dana, case_id=rcase)[0]["status"] == "NOT_FOUND")
d = call("decide_review_case", session_token=dana, case_id=lcase, decision="APPROVE", amount="300",
         internal_note="Receipts seen for essentials.", customer_message="Approved.")[0]
check("decide_review_case blocked: $300 above Dana's limit -> OVER_AUTHORITY, case OPEN",
      d["outcome"] == "BLOCKED" and d["reason_code"] == "OVER_AUTHORITY" and d["case_status"] == "OPEN", d)
d = call("decide_review_case", session_token=dana, case_id=lcase, decision="APPROVE", amount="200",
         internal_note="Receipts seen for essentials; partial.", customer_message="We have approved $200.00 toward your essentials.")[0]
check("decide_review_case: approve $200 -> APPROVED, interim payment executed", d["outcome"] == "APPROVED"
      and num(d["approved_amount"]) == 200 and "interim expenses" in s(d["executed_action"]), d)
check("DB: payment + CASE_DECIDED audit", n(f"SELECT count(*) FROM service_payments WHERE case_id = '{lcase}' AND amount_usd = 200") == 1
      and n(f"SELECT count(*) FROM agent_audit WHERE action = 'CASE_DECIDED' AND actor = 'MER-7001'") == 1)
marcus = call("verify_reviewer", staff_id="MER-7003", code="864209")[0]["session_token"]
d = call("decide_review_case", session_token=marcus, case_id=rcase, decision="APPROVE", amount="",
         internal_note="Lift booked with the ground handler.", customer_message="Your assistance is confirmed.")[0]
check("Marcus confirms Rosa's assistance -> SSR CONFIRMED", d["outcome"] == "APPROVED"
      and n("SELECT count(*) FROM segment_ssrs ss JOIN assistance_requests ar USING (request_id) WHERE ar.pnr = 'HJKLM8' AND ss.status = 'CONFIRMED'") == 1, d)
d = call("decide_review_case", session_token=tok, case_id=ccase, decision="APPROVE", amount="",
         internal_note="Self-approval attempt.", customer_message="x")[0]
check("decide_review_case blocked: a traveller token -> NOT_REVIEWER", d["outcome"] == "NOT_REVIEWER", d)

# ---- the traveller sees the outcome; the decided case can be emailed ----
r = {x["case_id"]: x for x in call("get_my_cases", session_token=linda)}
check("Linda sees APPROVED $200 and the message, never the note", r[lcase]["status"] == "APPROVED" and num(r[lcase]["approved_amount"]) == 200
      and "Receipts seen" not in json.dumps(r), r.get(lcase))
email_send(linda, lcase)
check("email for the decided case -> the SQL guard passed: logged in email_log",
      n(f"SELECT count(*) FROM email_log WHERE reference_id = '{lcase}'") == 1)

trav_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row}
check("traveller tool outputs carry none of the hidden columns", not (trav_cols & HIDDEN_COLUMNS), trav_cols & HIDDEN_COLUMNS)
check("every MCP tool was called at the MCP edge", {t for t, _ in OUTPUTS} == {t["tool"] for t in TOOLS},
      {t["tool"] for t in TOOLS} - {t for t, _ in OUTPUTS})

reset()
out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
