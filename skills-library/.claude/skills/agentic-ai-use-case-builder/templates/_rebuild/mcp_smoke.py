#!/usr/bin/env python3
# =============================================================================
# WORKED-EXAMPLE TEMPLATE - Airline Passenger Services (Meridian) governed use case.
#
# This is a proven, runnable reference test from the Airline Passenger Services
# worked example. To build your own governed use case, copy the whole _rebuild/
# folder into <YourUseCase>/_rebuild/ and ADAPT it (keep the logic - the value is a
# working reference - just change):
#   - app names / prefix       (PassengerServices... -> <YourUseCase>...)
#   - the tool_spec.py entries  (tools, args, SQL: scoped reads + guarded writes)
#   - ports / endpoint paths    (9850 / 9852 / 9853, /passenger-services-gov-mcp, ...)
#   - the test assertions       below (tool count, PNRs/PINs, expected outcomes)
#
# References (relative to this file):
#   ..\..\references\fda-build-recipes.md  - the fda-only build driver pattern
#   ..\..\references\governed-patterns.md  - scoped reads / guarded writes / safe prompts
#   ..\..\references\testing-ladder.md     - the SQL -> MCP -> chat test ladder
#
# No secrets here: credentials are read at RUN time from config.md / env (see fda_common.py).
# =============================================================================
"""Call the running PassengerServicesMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, load reset_data.sql, then:   python _rebuild/mcp_smoke.py
Leaves one executed rebooking + one service case + one reviewer decision behind - re-load reset_data.sql afterwards.
The reviewer block's DB checks run when PG_DB (+ PG_PWD / PG_PASSWORD, optional PSQL) is set; otherwise they are skipped."""
import csv, io, json, os, shutil, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, HIDDEN_COLUMNS, reviewer_tools_filled
if not reviewer_tools_filled():
    sys.exit("fill in tool_spec.REVIEWER_TOOL_SPECS / HIDDEN_COLUMNS and the REVIEW block below first")

URL = os.environ.get("MCP_URL", "http://localhost:9852/passenger-services-gov-mcp")
session, seq, fails = None, 0, 0

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

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    fails += 0 if cond else 1

rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
rpc("notifications/initialized", notify=True)
tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
check(f"tools/list = exactly the {len(TOOLS)} tools from tool_spec.py", set(tools) == {t["tool"] for t in TOOLS}, sorted(tools))
check("read-only hint on reads", tools["get_my_itinerary"].get("annotations", {}).get("readOnlyHint") is True, tools["get_my_itinerary"])
check("arguments schema published", "session_token" in json.dumps(tools["propose_rebook"].get("inputSchema")), tools["propose_rebook"])

r = call("verify_traveller", pnr="ABCDE1", pin="0000")
check("wrong PIN -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_traveller", pnr="ABCDE1", pin="4821")
check("right PNR+PIN -> VERIFIED", r[0]["status"] == "VERIFIED", r)
tok = r[0]["session_token"]
r = call("get_my_itinerary", session_token=tok)
check("scoped itinerary = 2 legs", len([x for x in r if x["flight_number"]]) == 2, r)
r = call("check_connection_risk", session_token=tok)
check("connection risk computed -> MISSED", any(x["risk"] == "MISSED" for x in r), r)
earliest = [x for x in r if x["risk"] == "MISSED"][0]["earliest_rebook_departure"]
r = call("propose_rebook", session_token=tok, current_flight="FL445", new_flight="FL445")
check("guard: same flight", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SAME_FLIGHT"), r)
p = call("propose_rebook", session_token=tok, current_flight="FL445", new_flight="FL447")[0]
check("eligible -> PROPOSED", p["outcome"] == "PROPOSED" and p["action_id"], p)
c = call("confirm_rebook", session_token=tok, action_id=p["action_id"])[0]
check("confirm -> EXECUTED on FL447", c["outcome"] == "EXECUTED" and c["to_flight"] == "FL447", c)
e = call("email_my_confirmation", session_token=tok, action_id=p["action_id"])[0]
check("email authorised -> SEND_OK", e["send_status"] == "SEND_OK", e)
k = call("open_service_case", session_token=tok, request_type="COMPENSATION_CLAIM",
         traveler_statement="FL801 delayed 90 minutes; I want compensation.",
         brief="90-minute inbound delay caused a missed connection; traveller requests compensation.")[0]
check("service case opened -> Customer Care", k["outcome"] == "CASE_OPENED" and "Customer Care" in k["assigned_team"], k)
r = call("get_my_itinerary", session_token="forged")
check("forged token -> SESSION_INVALID", r[0]["session_status"] == "SESSION_INVALID", r)

# ---- reviewer tools: happy path + one blocked call each (generic; testing-ladder.md step 3) ----
# Fill REVIEW from seed_data.sql: the LOW reviewer's limit sits just below LOW_CASE's eligible max (OVER_AUTHORITY).
REVIEW = {
    "low": ("<STAFF-0001>", "<code>", "<Team A>"),
    "low_case": "<CASE-0000A>",                    # Team A's seeded OPEN case with a parked action
    "low_ok_amount": "<an amount within the LOW reviewer's limit>",
    "other_team_case": "<CASE-0000B>",             # a case routed to another team
    "case_customer": {"pnr": "<PNR>", "pin": "<PIN>"},   # verify_traveller args of LOW_CASE's customer
    "executed_sql": "SELECT count(*) AS n FROM <target_table> WHERE case_id = '{case}'",   # rows the parked action writes
}
if any("<" in str(v) for v in REVIEW.values()):
    sys.exit("fill in the REVIEW block (reviewer loop placeholders) in mcp_smoke.py first")
PSQL = os.environ.get("PSQL") or shutil.which("psql")
PG = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
      "-d", os.environ.get("PG_DB", ""), "-q", "--csv", "-c"] if PSQL and os.environ.get("PG_DB") else None
def n(sql):
    r = subprocess.run(PG + [sql], capture_output=True, text=True, env=dict(
        os.environ, PGPASSWORD=os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or ""))
    if r.returncode: sys.exit(r.stderr)
    return int(list(next(csv.DictReader(io.StringIO(r.stdout))).values())[0])
def num(v): return float(v) if v not in (None, "") else None
LOW_ID, LOW_CODE, LOW_TEAM = REVIEW["low"]
LCASE = REVIEW["low_case"]
ann = tools["decide_review_case"].get("annotations", {})
check("decide_review_case hints: not read-only, not destructive, not idempotent (false hints are omitted from tools/list)",
      ann.get("readOnlyHint") is not True and ann.get("destructiveHint") is not True and ann.get("idempotentHint") is not True, ann)
r = call("verify_reviewer", staff_id=LOW_ID, code="000000")[0]
check("verify_reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r.get("session_token"), r)
r = call("verify_reviewer", staff_id=LOW_ID, code=LOW_CODE)[0]
check("verify_reviewer -> VERIFIED, role REVIEWER, own team", r["status"] == "VERIFIED" and r.get("role") == "REVIEWER"
      and r.get("team") == LOW_TEAM, {k: v for k, v in r.items() if k != "session_token"})
rtok = r.get("session_token") or "missing"
r = call("get_review_queue", session_token=tok)
check("get_review_queue with a customer token -> NOT_REVIEWER", r[0]["status"] == "NOT_REVIEWER", r)
r = call("get_review_queue", session_token=rtok)
check("get_review_queue = the team's OPEN cases incl. the seeded case", r[0]["status"] == "OK"
      and LCASE in [x.get("case_id") for x in r] and all(x.get("team") == LOW_TEAM for x in r), r)
r = call("get_review_case", session_token=rtok, case_id=REVIEW["other_team_case"])[0]
check("get_review_case on another team's case -> NOT_FOUND (cross-team invisible)", r["status"] == "NOT_FOUND", r)
rc = call("get_review_case", session_token=rtok, case_id=LCASE)[0]
check("get_review_case -> facts, max approvable above the reviewer's limit", rc["status"] == "OK" and rc.get("facts")
      and num(rc.get("max_approvable")) > num(rc.get("your_approval_limit")), rc)
r = call("decide_review_case", session_token=rtok, case_id=LCASE, decision="APPROVE", amount="",
         internal_note="Record checked.", customer_message="Your request was approved.")[0]
check("decide_review_case full amount above the limit -> BLOCKED OVER_AUTHORITY, case stays OPEN",
      r["outcome"] == "BLOCKED" and r["reason_code"] == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
r = call("decide_review_case", session_token=rtok, case_id=LCASE, decision="APPROVE", amount=REVIEW["low_ok_amount"],
         internal_note="Record checked; goodwill within my limit.", customer_message="Your request was approved.")[0]
check("decide_review_case within the limit -> APPROVED with executed_action", r["outcome"] == "APPROVED"
      and r.get("executed_action"), r)
if PG:
    check("DB: decision row + parked action executed + CASE_DECIDED audit by the reviewer",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id = '{LCASE}' AND reviewer_id = '{LOW_ID}'") == 1
          and n(REVIEW["executed_sql"].format(case=LCASE)) == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE action = 'CASE_DECIDED' AND ref = '{LCASE}' AND actor = '{LOW_ID}'") == 1)
else:
    print("SKIP reviewer DB checks (set PG_DB and PG_PWD to run them)")
ctok = call("verify_traveller", **REVIEW["case_customer"])[0].get("session_token") or "missing"
mine = [x for x in call("get_my_cases", session_token=ctok) if LCASE in x.values()]
check("the customer sees APPROVED + the customer message, never the internal note",
      bool(mine) and "APPROVED" in mine[0].values() and "goodwill" not in json.dumps(mine)
      and not (set(mine[0]) & HIDDEN_COLUMNS), mine)

print(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  - now re-load reset_data.sql")
sys.exit(1 if fails else 0)
