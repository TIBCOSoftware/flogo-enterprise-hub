#!/usr/bin/env python3
"""Test ladder step 3: call the running HospitalCareMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9922/hospitalcaremcp), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (hospital_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Attempts ONE real discharge-plan email (John's) to the EMAIL_TO app
property; the SQL guard + email_log are asserted, SMTP delivery is reported separately."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, REVIEWER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9922/hospitalcaremcp")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "hospital_governed"),
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
    args = {a: args.get(a, "") for a, _ in SPEC_ARGS[tool]}
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
    try: return round(float(str(v).replace("$", "").replace(",", "").strip()), 2)
    except (TypeError, ValueError): return None
def s(v): return "" if v is None else str(v)


def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0


SPEC = {t["tool"]: t for t in TOOLS}
SPEC_ARGS = {t["tool"]: t["args"] for t in TOOLS}
BAD = "bogus-token-0000"


def v(sql): return list(q(sql)[0].values())[0] if q(sql) else None


reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 18 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 18,
          {"missing": sorted(set(SPEC) - set(tools)), "extra": sorted(set(tools) - set(SPEC))})
    ann = {k: tools[k].get("annotations", {}) for k in tools if k in SPEC}
    # absent readOnlyHint/idempotentHint = false per the MCP spec (Go omitempty); destructiveHint must be present + false
    check("readOnlyHint matches tool_spec on every tool (absent = false)",
          all(ann[k].get("readOnlyHint", False) is SPEC[k]["readonly"] for k in ann), ann)
    check("write tools: idempotentHint false, destructiveHint present and false",
          all(ann[k].get("idempotentHint", False) is False and ann[k].get("destructiveHint") is False
              for k in ann if not SPEC[k]["readonly"]), {k: ann[k] for k in ann if not SPEC[k]["readonly"]})
    bad_schema = [k for k in tools if k in SPEC and not all(a in json.dumps(tools[k].get("inputSchema")) for a, _ in SPEC[k]["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- identity ----
    r = one("verify_coordinator", staff_id="BMC-4101", code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_coordinator", staff_id="bmc4101", code="4826")
    check("Rachel 'bmc4101' -> VERIFIED COORDINATOR, Ward 4A", r["outcome"] == "VERIFIED" and r.get("session_token")
          and r.get("role") == "COORDINATOR" and "4A" in s(r.get("ward")), {k: x for k, x in r.items() if k != "session_token"})
    rachel = s(r.get("session_token")) or "missing"
    daniel = s(one("verify_coordinator", staff_id="3201", code="7391").get("session_token")) or "missing"
    check("Daniel (bare digits) verifies", daniel != "missing")
    r = one("verify_reviewer", staff_id="BMC-7701", code="9999")
    check("reviewer wrong code -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="BMC-7701", code="3141")
    check("Priya -> VERIFIED REVIEWER, Pharmacy", r["outcome"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Pharmacy", {k: x for k, x in r.items() if k != "session_token"})
    priya = s(r.get("session_token")) or "missing"
    owen = s(one("verify_reviewer", staff_id="BMC-7702", code="2718").get("session_token")) or "missing"
    maya = s(one("verify_reviewer", staff_id="BMC-5501", code="1618").get("session_token")) or "missing"
    check("Owen and Maya verify", "missing" not in (owen, maya))

    # ---- bogus token on every scoped tool ----
    for t in TOOLS:
        if t["tool"] in ("verify_coordinator", "verify_reviewer"):
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = BAD
        row = one(t["tool"], **args)
        code = row.get("reason_code") if t.get("email") else (row.get("status") or row.get("outcome"))
        want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
        check(f"{t['tool']} with bogus token -> {want}", code == want, row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM pharmacy_orders") == 1 and n("SELECT count(*) FROM bed_events") == 0
          and n("SELECT count(*) FROM review_decisions") == 0 and n("SELECT count(*) FROM service_cases") == 3
          and n("SELECT count(*) FROM email_log") == 0)
    check("role separation: reviewer token on a coordinator tool -> SESSION_INVALID",
          one("get_ward_discharges", session_token=priya)["status"] == "SESSION_INVALID")
    check("role separation: coordinator token on a reviewer tool -> NOT_REVIEWER",
          one("get_review_queue", session_token=rachel)["status"] == "NOT_REVIEWER")

    # ---- scoped reads (multi-row tools must return ALL rows) ----
    wd = call("get_ward_discharges", session_token=rachel)
    check("Rachel's ward list: all 5 Ward 4A patients", len(wd) == 5 and all(s(x.get("ward")).startswith("Ward 4A") for x in wd), wd)
    ds = call("get_discharge_summary", session_token=rachel, patient_id="MRN-4012")
    check("John's summary: 3 medicine rows, prescribed instructions verbatim", len(ds) == 3
          and ds[0].get("instructions") == "1 tablet by mouth once daily", ds)
    check("SCOPE: Rachel reads Thomas (3B) -> NOT_FOUND",
          one("get_discharge_summary", session_token=rachel, patient_id="MRN-3204")["status"] == "NOT_FOUND")
    sl = call("get_followup_slots", session_token=rachel, patient_id="MRN-4012")
    check("John's eligible slots: 7 open Cardiology slots in the window", len(sl) == 7
          and {s(x.get("slot_id")) for x in sl} == {f"SLOT-C10{i}" for i in range(1, 8)}, [x.get("slot_id") for x in sl])
    check("John's appointments: the echocardiogram",
          one("get_patient_appointments", session_token=rachel, patient_id="MRN-4012").get("appointment_type") == "Echocardiogram")
    check("beds: 7 on Ward 4A", len(call("get_ward_beds", session_token=rachel)) == 7)

    # ---- two-step follow-up ----
    r = one("propose_followup", session_token=rachel, patient_id="MRN-4012", slot_id="SLOT-C108")
    check("propose outside the window -> BLOCKED OUTSIDE_WINDOW", r["outcome"] == "BLOCKED" and r.get("reason_code") == "OUTSIDE_WINDOW", r)
    r = one("propose_followup", session_token=rachel, patient_id="MRN-4012", slot_id="SLOT-C105")
    check("propose SLOT-C105 -> PROPOSED with a summary", r["outcome"] == "PROPOSED" and s(r.get("proposal_id")).startswith("BMC-PRP-")
          and "13:30" in s(r.get("summary")), r)
    pid = s(r.get("proposal_id"))
    check("DB: nothing booked before confirm", n("SELECT count(*) FROM appointments WHERE source='CHAT'") == 0)
    r = one("confirm_action", session_token=rachel, proposal_id=pid)
    check("confirm -> EXECUTED BMC-APT-...", r["outcome"] == "EXECUTED" and s(r.get("reference")).startswith("BMC-APT-"), r)
    check("DB: appointment created + slot BOOKED", n("SELECT count(*) FROM appointments WHERE source='CHAT' AND slot_id='SLOT-C105'") == 1
          and v("SELECT status FROM clinic_slots WHERE slot_id='SLOT-C105'") == "BOOKED")
    check("confirm twice -> ALREADY_DONE", one("confirm_action", session_token=rachel, proposal_id=pid)["outcome"] == "ALREADY_DONE")

    # ---- medicine orders ----
    o = call("order_discharge_meds", session_token=rachel, patient_id="MRN-4012", medication="ALL", pharmacist_brief="")
    check("John ALL -> 3 ORDERED", len(o) == 3 and all(x["outcome"] == "ORDERED" for x in o), o)
    o = one("order_discharge_meds", session_token=rachel, patient_id="MRN-4012", medication="oxycodone", pharmacist_brief="")
    check("oxycodone not on John's list -> BLOCKED NOT_ON_DISCHARGE_LIST", o.get("reason_code") == "NOT_ON_DISCHARGE_LIST", o)
    BRIEF = "INTERACTION: home low-dose aspirin vs warfarin - bleeding risk - for the pharmacist to review"
    o = {s(x.get("medication")).split()[0]: x for x in
         call("order_discharge_meds", session_token=rachel, patient_id="MRN-4015", medication="ALL", pharmacist_brief=BRIEF)}
    check("Margaret ALL -> 2 ORDERED + warfarin PHARMACIST_REVIEW", o.get("Warfarin", {}).get("outcome") == "PHARMACIST_REVIEW"
          and o.get("Metoprolol", {}).get("outcome") == "ORDERED" and o.get("Omeprazole", {}).get("outcome") == "ORDERED", o)
    wcase = s(o.get("Warfarin", {}).get("case_id"))
    check("DB: warfarin parked in a Pharmacy case with the brief, not dispensed",
          n(f"SELECT count(*) FROM service_cases WHERE case_id='{wcase}' AND status='OPEN' AND agent_brief LIKE 'INTERACTION%'") == 1
          and n("SELECT count(*) FROM pharmacy_orders WHERE medication_code='MED-105'") == 0)

    # ---- bed turnover ----
    r = one("request_bed_turnover", session_token=rachel, bed_id="4A-12")
    check("Robert's bed (not yet left) -> BLOCKED PATIENT_NOT_DISCHARGED", r.get("reason_code") == "PATIENT_NOT_DISCHARGED"
          and v("SELECT status FROM beds WHERE bed_id='4A-12'") == "OCCUPIED", r)
    r = one("request_bed_turnover", session_token=rachel, bed_id="4A-10")
    check("John's bed -> REQUESTED, bed CLEANING_REQUESTED", r["outcome"] == "REQUESTED"
          and v("SELECT status FROM beds WHERE bed_id='4A-10'") == "CLEANING_REQUESTED", r)

    # ---- human-owned case ----
    r = one("open_service_case", session_token=rachel, request_type="clinical_question", patient_id="MRN-4012",
            summary="Can John take an extra metoprolol if his heart races?", reference_id="", agent_brief="")
    check("dosage question -> OPENED for Hospitalist Service", r["outcome"] == "OPENED" and r.get("team") == "Hospitalist Service", r)
    check("SCOPE: case for a 3B patient -> NOT_FOUND",
          one("open_service_case", session_token=rachel, request_type="clinical_question", patient_id="MRN-3207",
              summary="x", reference_id="", agent_brief="").get("reason_code") == "NOT_FOUND")

    # ---- reviewer loop ----
    q_ids = {s(x.get("case_id")) for x in call("get_review_queue", session_token=priya)}
    check("Priya's queue has the warfarin case and seeded oxycodone case, not the Nursing case",
          wcase in q_ids and "BMC-CASE-000001" in q_ids and "BMC-CASE-000002" not in q_ids, q_ids)
    rc = one("get_review_case", session_token=priya, case_id=wcase)
    check("Priya opens the warfarin case: facts + AI brief + max 30 days", rc["status"] == "OK" and "Warfarin" in s(rc.get("facts"))
          and s(rc.get("agent_brief")).startswith("AI-prepared") and num(rc.get("max_approvable_days")) == 30, rc)
    check("another team's case -> NOT_FOUND", one("get_review_case", session_token=priya, case_id="BMC-CASE-000002")["status"] == "NOT_FOUND")
    r = one("decide_review_case", session_token=rachel, case_id=wcase, decision="APPROVE", amount="30",
            internal_note="Self-approval attempt.", customer_message="")
    check("coordinator token cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, r)
    r = one("decide_review_case", session_token=priya, case_id="BMC-CASE-000002", decision="APPROVE", amount="",
            internal_note="Wrong team test.", customer_message="")
    check("NOT_YOUR_TEAM", r.get("reason_code") == "NOT_YOUR_TEAM", r)
    r = one("decide_review_case", session_token=priya, case_id=wcase, decision="APPROVE", amount="14", internal_note="ok", customer_message="")
    check("NOTE_REQUIRED", r.get("reason_code") == "NOTE_REQUIRED", r)
    r = one("decide_review_case", session_token=priya, case_id=wcase, decision="APPROVE", amount="45",
            internal_note="Longer supply requested.", customer_message="")
    check("AMOUNT_INVALID (45 > 30 prescribed)", r.get("reason_code") == "AMOUNT_INVALID", r)
    r = one("decide_review_case", session_token=owen, case_id="BMC-CASE-000001", decision="APPROVE", amount="10",
            internal_note="Post-op pain plan reviewed.", customer_message="")
    check("Owen approves 10 days over his 7-day limit -> OVER_AUTHORITY, case still OPEN", r.get("reason_code") == "OVER_AUTHORITY"
          and v("SELECT status FROM service_cases WHERE case_id='BMC-CASE-000001'") == "OPEN", r)
    MSG = "Warfarin approved for a 14-day supply; the anticoagulation clinic manages the dose after that."
    r = one("decide_review_case", session_token=priya, case_id=wcase, decision="APPROVE", amount="14",
            internal_note="INR baseline reviewed; 14-day bridge to the clinic.", customer_message=MSG)
    check("Priya approves 14 days -> APPROVED, dispensed", r["outcome"] == "APPROVED" and s(r.get("executed_action")).startswith("Dispensed"), r)
    check("DB: decision row, warfarin order 14 days, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{wcase}' AND approved_amount=14") == 1
          and n(f"SELECT count(*) FROM pharmacy_orders WHERE medication_code='MED-105' AND days_supply=14 AND case_id='{wcase}'") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{wcase}' AND actor='BMC-7701'") == 1)
    check("second decision -> ALREADY_DECIDED", one("decide_review_case", session_token=priya, case_id=wcase, decision="REJECT",
                                                    amount="", internal_note="Second decision.", customer_message="").get("reason_code") == "ALREADY_DECIDED")
    r = one("decide_review_case", session_token=maya, case_id="BMC-CASE-000002", decision="APPROVE", amount="",
            internal_note="Patient confirmed in the lounge.", customer_message="")
    check("Maya approves Angela's early turnover -> bed 3B-07 to housekeeping", r["outcome"] == "APPROVED"
          and v("SELECT status FROM beds WHERE bed_id='3B-07'") == "CLEANING_REQUESTED", r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=rachel)}
    check("coordinator sees the outcome: APPROVED + message, no internal note",
          mc.get(wcase, {}).get("case_status") == "APPROVED" and mc[wcase].get("customer_message") == MSG
          and "INR baseline" not in json.dumps(mc), mc.get(wcase))
    check("get_pharmacy_orders shows the released warfarin",
          any(s(x.get("released")).startswith("after pharmacist review") for x in
              call("get_pharmacy_orders", session_token=rachel, patient_id="MRN-4015")))

    # ---- guarded email: refusals first, then one real send ----
    e = one("email_patient_summary", session_token=rachel, patient_id="MRN-3204")
    check("SCOPE: Rachel emails a 3B patient -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    e = one("email_patient_summary", session_token=daniel, patient_id="MRN-3211")
    check("nothing arranged for Kevin -> NOT_SENT NOTHING_TO_SEND", e.get("reason_code") == "NOTHING_TO_SEND", e)
    check("DB: refused emails logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_patient_summary", session_token=rachel, patient_id="MRN-4012")
        check("email John's plan -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK", e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the portable dummy Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n("SELECT count(*) FROM email_log WHERE patient_id='MRN-4012' AND coordinator_id='BMC-4101'") == 1)

    # ---- hidden data ----
    co = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
    leaked = sorted({k for _, rows in co for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no coordinator tool output carries a hidden column", not leaked, leaked)
    rv = json.dumps([rows for t, rows in OUTPUTS if t in REVIEWER_TOOLS])
    check("reviewer outputs carry no MRN or patient surname", not re.search(r"MRN-\d|Harper|Ellis|Reed|Morris", rv),
          re.findall(r"MRN-\d+|Harper|Ellis|Reed|Morris", rv)[:5])
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
