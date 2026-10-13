#!/usr/bin/env python3
"""Test ladder step 3: call the running ParcelDeliveryMCPServer tools directly - no LLM - to prove the rules hold at the
MCP edge: identity, scoping, the two-step reschedule, claims, delivery instructions, the guarded email and the reviewer
loop (happy path + one blocked call each).
Start the MCP server first, then:   python _rebuild/mcp_smoke.py
The DB is reset (reset_data.sql) before and after. Attempts real confirmation emails to To_Email; the SQL guard and
email_log are asserted, SMTP delivery is reported separately (the shipped Email_App_Password is a placeholder)."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, REVIEWER_TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER

URL = os.environ.get("MCP_URL", "http://localhost:9892/parcel-delivery-mcp")
DIR = os.path.dirname(HERE)
SPEC = {t["tool"]: t for t in TOOLS}


def _config_md_value(key):
    path, d = os.environ.get("CONFIG_MD", ""), HERE
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
        or sys.exit("psql not found: install the PostgreSQL client and put psql on PATH, or set env PSQL / config.md PSQL_PATH"))
ENV = dict(os.environ, PGPASSWORD=os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or _config_md_value("PG_PASSWORD")
           or sys.exit("PostgreSQL password not set: export PG_PWD (or PG_PASSWORD), or fill PG_PASSWORD in config.md"))
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "parcel_delivery"), "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0


def out(s): print(str(s).encode("ascii", "replace").decode(), flush=True)
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))
def num(v): return float(v) if v not in (None, "") else None   # MCP returns JSON numbers
def n(sql): return int(list(q(sql)[0].values())[0])
def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


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
    """Sends EVERY argument of the tool spec (empty string when not given), like the orchestrator's LLM does."""
    full = {a: args.get(a, "") for a, _ in SPEC[tool]["args"]}
    res = rpc("tools/call", {"name": tool, "arguments": full})
    text = res["content"][0]["text"]
    body = json.loads(text)
    if body.get("error"): raise RuntimeError(body["error"])
    return (json.loads(body["data"]) if "data" in body else body)["records"]


def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0


reset()
try:
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("18 tools listed", len(tools) == 18 and set(tools) == set(SPEC), sorted(tools))
    ann = lambda t: tools[t].get("annotations", {})
    check("readOnlyHint true on every read", all(ann(t).get("readOnlyHint") is True for t in SPEC if SPEC[t]["readonly"]),
          [t for t in SPEC if SPEC[t]["readonly"] and ann(t).get("readOnlyHint") is not True])
    check("writes are not read-only, never destructive", all(ann(t).get("readOnlyHint") is not True and ann(t).get("destructiveHint") is not True
                                                             for t in SPEC if not SPEC[t]["readonly"]))
    check("decide_review_case not idempotent", ann("decide_review_case").get("idempotentHint") is not True, ann("decide_review_case"))
    check("arguments schema published", "session_token" in json.dumps(tools["propose_reschedule"].get("inputSchema"))
          and "agent_notes" in json.dumps(tools["open_damage_claim"].get("inputSchema")), tools["open_damage_claim"])

    # ---- identity + scoped reads + two-step reschedule (kept) ----
    r = call("verify_recipient", account_ref="K4R2QX", pin="0000")
    check("wrong PIN -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
    r = call("verify_recipient", account_ref="K4R2QX", pin="4021")
    check("right ref+PIN -> VERIFIED", r[0]["status"] == "VERIFIED", r)
    tok = r[0]["session_token"]
    r = call("get_my_parcels", session_token=tok)
    check("scoped parcels = 3", len([x for x in r if x["tracking_number"]]) == 3, r)
    r = call("get_parcel_detail", session_token=tok, tracking_number="SB100000000001")
    check("exception decoded, NEEDS_ATTENTION", r[0]["delivery_health"] == "NEEDS_ATTENTION" and r[0]["exception_label"], r)
    r = call("get_parcel_detail", session_token=tok, tracking_number="SB100000000011")
    check("another recipient's parcel -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND", r)
    r = call("propose_reschedule", session_token=tok, tracking_number="SB100000000001", slot_id="SLOT-W1")
    check("guard: wrong area slot", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SLOT_WRONG_AREA"), r)
    p = call("propose_reschedule", session_token=tok, tracking_number="SB100000000001", slot_id="SLOT-N1")[0]
    check("eligible -> PROPOSED", p["outcome"] == "PROPOSED" and p["action_id"], p)
    c = call("confirm_reschedule", session_token=tok, action_id=p["action_id"])[0]
    check("confirm -> EXECUTED on SLOT-N1", c["outcome"] == "EXECUTED" and c["target"] == "SLOT-N1", c)
    # guarded email: ONE real send attempt, asserted on the SQL guard + email_log
    try:
        e = call("email_confirmation", session_token=tok, action_id=p["action_id"])[0]
        check("email authorised -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK", e)
    except Exception as ex:                                      # noqa: BLE001
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request was logged (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference_id='{p['action_id']}'") == 1)
    e = call("email_confirmation", session_token=tok, action_id="ACT-00000000")[0]
    check("email bogus action -> NOT_SENT, nothing logged", e["send_status"] == "NOT_SENT" and n("SELECT count(*) FROM email_log") == 1, e)
    r = call("propose_redirect", session_token=tok, tracking_number="SB100000000002", pickup_id="PU-N-LOCK1")
    check("guard: signature parcel -> locker refused", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SIGNATURE_REQUIRED"), r)
    k = call("open_service_case", session_token=tok, request_type="DELIVERY_COMPLAINT", tracking_number="SB100000000001",
             recipient_statement="Repeated failed delivery attempts.",
             brief="Parcel had a failed delivery attempt; recipient is unhappy with the service.")[0]
    check("service case opened -> Customer Relations", k["outcome"] == "CASE_OPENED" and "Customer Relations" in k["assigned_team"], k)
    r = call("get_parcel_detail", session_token="forged", tracking_number="SB100000000001")
    check("forged token -> SESSION_INVALID", r[0]["lookup_status"] == "SESSION_INVALID", r)

    # ---- claim (damage_claim_agent output) ----
    olivia = call("verify_recipient", account_ref="M2P7VB", pin="6150")[0]["session_token"]
    notes = ("claim_type: DAMAGED\npackaging_condition: CRUSHED\nlikely_cause: CRUSHING_LOAD\nclaim_line: Keep the item and every "
             "piece of its packaging until a Swiftbound claims specialist has decided the claim, because it may be inspected.")
    c1 = call("open_damage_claim", session_token=olivia, tracking_number="SB100000000011", claim_type="DAMAGED",
              packaging_condition="CRUSHED", likely_cause="CRUSHING_LOAD", claimed_amount="",
              recipient_statement="Box crushed on one corner, laptop screen cracked, outer tape intact.", agent_notes=notes)[0]
    check("laptop claim -> CLAIM_OPENED, 1000 under review (coverage cap), evidence listed",
          c1["outcome"] == "CLAIM_OPENED" and float(c1["amount_under_review"]) == 1000 and "shipping label" in c1["evidence_to_send"], c1)
    check("claim readback carries no hidden columns", not (set(c1) & HIDDEN_COLUMNS), set(c1) & HIDDEN_COLUMNS)
    r = call("open_damage_claim", session_token=olivia, tracking_number="SB100000000001", claim_type="DAMAGED")[0]
    check("claim on another recipient's parcel -> NOT_OPENED NOT_FOUND", r["outcome"] == "NOT_OPENED" and r["reason_code"] == "NOT_FOUND", r)
    OCASE = c1["case_id"]

    # ---- delivery instructions (delivery_instructions_agent output) ----
    sofia = call("verify_recipient", account_ref="T8J4NC", pin="2468")[0]["session_token"]
    txt = "leave behind the blue side gate, code 4521, dog in the yard, not on the porch"
    ip = call("propose_delivery_instructions", session_token=sofia, tracking_number="SB100000000009", safe_place="SIDE_GATE",
              access_code_present="yes", hazards="DOG", risk_flags="NONE", instructions_text=txt,
              agent_notes="safe_place: SIDE_GATE\ndriver_note: behind the side gate, code [code withheld]")[0]
    check("instructions -> PROPOSED, code masked", ip["outcome"] == "PROPOSED" and "4521" not in ip["driver_note"], ip)
    ic = call("confirm_delivery_instructions", session_token=sofia, action_id=ip["action_id"])[0]
    check("confirm -> EXECUTED, SIDE_GATE saved, code stored nowhere", ic["outcome"] == "EXECUTED"
          and n("SELECT count(*) FROM delivery_instructions WHERE notes_masked LIKE '%4521%'") == 0
          and n("SELECT count(*) FROM pending_actions WHERE notes_masked LIKE '%4521%' OR agent_notes LIKE '%4521%'") == 0, ic)
    r = call("propose_delivery_instructions", session_token=sofia, tracking_number="SB100000000009", safe_place="FRONT_DOOR",
             access_code_present="no", hazards="NONE", risk_flags="NONE", instructions_text="just leave it on the street")[0]
    check("guard: risky instruction (SQL phrase scan) -> RISKY_INSTRUCTION", r["reason_code"] == "RISKY_INSTRUCTION", r)
    r = call("propose_delivery_instructions", session_token=sofia, tracking_number="SB100000000010", safe_place="PORCH",
             access_code_present="no", hazards="NONE", risk_flags="NONE", instructions_text="porch is fine")[0]
    check("guard: signature parcel + porch -> SIGNATURE_REQUIRED", r["reason_code"] == "SIGNATURE_REQUIRED", r)

    # ---- reviewer loop ----
    r = call("verify_reviewer", staff_id="SWB-4101", code="000000")[0]
    check("reviewer wrong code -> NOT_VERIFIED", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
    hannah = call("verify_reviewer", staff_id="SWB-4101", code="418302")[0]
    check("reviewer -> VERIFIED, REVIEWER, Claims (damaged parcels)", hannah["status"] == "VERIFIED" and hannah["role"] == "REVIEWER"
          and hannah["team"] == "Claims (damaged parcels)", hannah)
    ht = hannah["session_token"]
    qh = call("get_review_queue", session_token=ht)
    check("queue: own team's cases only (lens SC-00001 + the new laptop case)",
          {"SC-00001", OCASE} <= {x["case_id"] for x in qh} and "SC-00002" not in {x["case_id"] for x in qh}, qh)
    check("queue: minimum necessary", not (set(qh[0]) & HIDDEN_FROM_REVIEWER), set(qh[0]) & HIDDEN_FROM_REVIEWER)
    r = call("get_review_queue", session_token=olivia)[0]
    check("blocked: recipient token on the queue -> NOT_REVIEWER", r["status"] == "NOT_REVIEWER", r)
    rc = call("get_review_case", session_token=ht, case_id=OCASE)[0]
    check("case view: facts + AI brief + limit", rc["status"] == "OK" and "coverage limit" in rc["facts"] and rc["agent_brief"] == notes
          and float(rc["your_approval_limit"]) == 500, rc)
    r = call("get_review_case", session_token=ht, case_id="SC-00002")[0]
    check("blocked: another team's case -> NOT_FOUND", r["status"] == "NOT_FOUND", r)
    r = call("decide_review_case", session_token=ht, case_id=OCASE, decision="APPROVE", amount="",
             internal_note="Damage matches the photos.", customer_message="Approved.")[0]
    check("blocked: 1000 above Hannah's 500 limit -> OVER_AUTHORITY, case OPEN", r["reason_code"] == "OVER_AUTHORITY" and r["case_status"] == "OPEN", r)
    r = call("decide_review_case", session_token=olivia, case_id=OCASE, decision="APPROVE", amount="",
             internal_note="I approve my own claim.", customer_message="Approved.")[0]
    check("blocked: recipient token cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
    victor = call("verify_reviewer", staff_id="SWB-4102", code="905127")[0]["session_token"]
    r = call("decide_review_case", session_token=victor, case_id=OCASE, decision="APPROVE", amount="",
             internal_note="Senior approval: screen damage consistent with crushing.",
             customer_message="Your laptop claim is approved for $1,000.00.")[0]
    check("Victor approves -> APPROVED, compensation paid", r["outcome"] == "APPROVED" and "CMP-" in (r["executed_action"] or ""), r)
    check("DB: decision row + payment 1000 + CASE_DECIDED audit",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{OCASE}' AND reviewer_id='SWB-4102'") == 1
          and n(f"SELECT count(*) FROM compensation_payments WHERE case_id='{OCASE}' AND amount=1000") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='{OCASE}'") == 1)
    r = call("decide_review_case", session_token=victor, case_id=OCASE, decision="REJECT", amount="",
             internal_note="Second try.", customer_message="x")[0]
    check("blocked: decided twice -> ALREADY_DECIDED", r["reason_code"] == "ALREADY_DECIDED", r)
    mc = [x for x in call("get_my_cases", session_token=olivia) if x["case_id"] == OCASE]
    check("recipient sees APPROVED + compensation + message, no hidden columns",
          mc and mc[0]["status"] == "APPROVED" and float(mc[0]["compensation_paid"]) == 1000 and not (set(mc[0]) & HIDDEN_COLUMNS), mc)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
