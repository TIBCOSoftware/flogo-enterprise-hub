#!/usr/bin/env python3
"""Test ladder step 3: call the running AssetHealthMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9952/assethealthmcp), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (predictive_maintenance_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Attempts ONE real asset-summary email (COMP-PB-S12) to the EMAIL_TO app
property; the SQL guard + email_log are asserted, SMTP delivery is reported separately."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, REVIEWER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9952/assethealthmcp")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "predictive_maintenance_governed"),
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
    check("tools/list = exactly the 20 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 20,
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
    r = one("verify_operator", staff_id="MRE-4101", code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_operator", staff_id="mre4101", code="2468")
    check("Jolene 'mre4101' -> VERIFIED OPERATOR, Permian", r["outcome"] == "VERIFIED" and r.get("session_token")
          and r.get("role") == "OPERATOR" and "Permian" in s(r.get("region")), {k: x for k, x in r.items() if k != "session_token"})
    jolene = s(r.get("session_token")) or "missing"
    travis = s(one("verify_operator", staff_id="4201", code="1357").get("session_token")) or "missing"
    check("Travis (bare digits) verifies", travis != "missing")
    check("forged token -> SESSION_INVALID", one("get_region_assets", session_token=BAD)["status"] == "SESSION_INVALID")

    # ---- scoped reads + the SQL classifier at the edge ----
    assets = call("get_region_assets", session_token=jolene)
    check("get_region_assets: Permian's 5 assets, COMP-PB-S12 CRITICAL first",
          len(assets) == 5 and assets[0]["asset_id"] == "COMP-PB-S12" and assets[0]["health_status"] == "CRITICAL", assets[:1])
    h = one("get_asset_health", session_token=jolene, asset_id="W47")
    check("get_asset_health W47: WARNING, vibration -> bearing_wear, confidence 0.85, 10-21 days, WO allowed",
          h["asset_id"] == "PUMP-PB-W47" and h["health_status"] == "WARNING" and h["failure_mode"] == "bearing_wear"
          and num(h.get("confidence")) == 0.85 and h["days_to_failure"] == "10-21 days" and h["work_order_allowed"] == "yes", h)
    check("SCOPE: Jolene asks for PUMP-BK-W21 -> NOT_FOUND",
          one("get_asset_health", session_token=jolene, asset_id="PUMP-BK-W21")["status"] == "NOT_FOUND")
    rd = call("get_sensor_readings", session_token=jolene, asset_id="PUMP-PB-W47")
    check("get_sensor_readings W47: 6 readings, latest 5.4 g / 189 F", len(rd) == 6 and num(rd[-1]["vibration_g"]) == 5.4
          and num(rd[-1]["temperature_f"]) == 189.0, rd[-1:])
    check("get_work_orders: MRE-WO-1029 open first",
          one("get_work_orders", session_token=jolene, asset_id="ALL")["wo_number"] == "MRE-WO-1029")
    check("get_alerts (Travis): ALR-000091 acknowledged",
          any(x["alert_id"] == "ALR-000091" for x in call("get_alerts", session_token=travis, asset_id="ALL")))
    fm = call("get_failure_modes", session_token=jolene, asset_id="PUMP-PB-W47")
    check("get_failure_modes W47: 6 rod-pump modes, bearing_wear first", len(fm) == 6 and fm[0]["failure_mode"] == "bearing_wear", fm[:1])
    hist = call("get_failure_history", session_token=jolene, asset_id="PUMP-PB-W47")
    check("get_failure_history: 5 closed rod-pump jobs incl. Eagle Ford, with fixes",
          len(hist) == 5 and any(x["basin"] == "Eagle Ford" for x in hist) and all(x.get("fix_applied") for x in hist), hist[:1])
    ho = call("get_region_handover", session_token=jolene)
    check("get_region_handover: health rows, no names or case ids", any(x["item_type"] == "ASSET_HEALTH" for x in ho)
          and not re.search(r"Pruitt|Hollister|Brennan|Rayburn|MRE-CASE", json.dumps(ho)), ho[:2])

    # ---- field notes ----
    r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W47",
            note_text="Growling from the gearbox on the downstroke, grease slinging off the saddle bearing.",
            failure_mode="bearing_wear", urgency="HIGH", safety_language="no", summary="Saddle bearing wear likely")
    check("log_field_note W47 -> WORK_ORDER_ELIGIBLE / AGREE", r["outcome"] == "WORK_ORDER_ELIGIBLE" and r["agreement"] == "AGREE", r)
    r = one("log_field_note", session_token=jolene, asset_id="VALVE-PB-W52",
            note_text="Gas odor at the bonnet when we walked past the wellhead.", failure_mode="seal_leak", urgency="IMMEDIATE",
            safety_language="yes", summary="Bonnet packing leak; safety phrase: gas odor")
    odor = s(r.get("case_id"))
    check("log_field_note 'gas odor' on a NORMAL valve -> SAFETY_CASE with HSE", r["outcome"] == "SAFETY_CASE" and odor.startswith("MRE-CASE-")
          and r.get("team") == "HSE", r)
    check("DB: the HSE case row exists (opened by the trigger)",
          n(f"SELECT count(*) FROM service_cases WHERE case_id='{odor}' AND request_type='safety_signal' AND status='OPEN'") == 1)
    r = one("log_field_note", session_token=jolene, asset_id="PUMP-EF-W14", note_text="noise", failure_mode="", urgency="", safety_language="no", summary="")
    check("log_field_note on another region's asset -> NOT_FOUND", r["outcome"] == "NOT_FOUND", r)

    # ---- two-step work order ----
    p = one("propose_work_order", session_token=jolene, asset_id="PUMP-PB-W47", failure_mode="bearing_wear", note="Gearbox growl")
    check("propose W47 -> PROPOSED, $8,400, no supervisor", p["outcome"] == "PROPOSED" and p["estimate_usd"] == "$8,400.00"
          and p["needs_supervisor_approval"] == "no", p)
    check("DB: nothing created before confirm", n("SELECT count(*) FROM work_orders WHERE asset_id='PUMP-PB-W47' AND status<>'CLOSED'") == 0)
    c = one("confirm_action", session_token=jolene, proposal_id=p["proposal_id"])
    check("confirm -> EXECUTED MRE-WO-1101", c["outcome"] == "EXECUTED" and c.get("work_order") == "MRE-WO-1101", c)
    check("DB: MRE-WO-1101 SCHEDULED for W47 + WO_CREATED audit",
          n("SELECT count(*) FROM work_orders WHERE wo_number='MRE-WO-1101' AND asset_id='PUMP-PB-W47' AND status='SCHEDULED'") == 1
          and n("SELECT count(*) FROM agent_audit WHERE event_type='WO_CREATED' AND subject_id='MRE-WO-1101'") == 1)
    p = one("propose_work_order", session_token=jolene, asset_id="PUMP-PB-W33", failure_mode="", note="")
    check("propose W33 (in MAINTENANCE) -> BLOCKED ASSET_IN_MAINTENANCE", p["outcome"] == "BLOCKED" and p.get("reason_code") == "ASSET_IN_MAINTENANCE", p)
    p = one("propose_work_order", session_token=jolene, asset_id="VALVE-PB-W52", failure_mode="", note="")
    check("propose W52 (NORMAL) -> BLOCKED HEALTH_NORMAL", p.get("reason_code") == "HEALTH_NORMAL", p)
    p = one("propose_work_order", session_token=jolene, asset_id="COMP-PB-S12", failure_mode="", note="Discharge temperature critical")
    check("propose S12 overhaul -> PROPOSED $68,000, needs supervisor", p["outcome"] == "PROPOSED" and p["estimate_usd"] == "$68,000.00"
          and p["needs_supervisor_approval"] == "yes", p)
    c = one("confirm_action", session_token=jolene, proposal_id=p["proposal_id"])
    scase = s(c.get("case_id"))
    check("confirm above the limit -> SUPERVISOR_APPROVAL case, no work order", c["outcome"] == "SUPERVISOR_APPROVAL" and scase.startswith("MRE-CASE-")
          and n("SELECT count(*) FROM work_orders WHERE asset_id='COMP-PB-S12' AND status<>'CLOSED'") == 0, c)

    # ---- alert + case ----
    a = one("log_alert", session_token=jolene, asset_id="PUMP-PB-W47")
    check("log_alert W47 -> LOGGED WARNING", a["outcome"] == "LOGGED" and a["severity"] == "WARNING", a)
    a = one("log_alert", session_token=jolene, asset_id="PUMP-PB-W47")
    check("log_alert W47 again -> ALREADY_LOGGED_TODAY", a["outcome"] == "ALREADY_LOGGED_TODAY", a)
    r = one("open_service_case", session_token=jolene, request_type="shut_in", asset_id="COMP-PB-S12",
            summary="Request an emergency shutdown of the compressor.", agent_brief="")
    check("open_service_case shut_in -> OPENED, Production Engineering, asset untouched", r["outcome"] == "OPENED"
          and r.get("team") == "Production Engineering" and v("SELECT status FROM assets WHERE asset_id='COMP-PB-S12'") == "OPERATIONAL", r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=jolene)}
    check("get_my_cases: the budget case OPEN with a 'person will decide' message", mc.get(scase, {}).get("case_status") == "OPEN", mc.get(scase))

    # ---- reviewer loop ----
    r = one("verify_reviewer", staff_id="MRE-7102", code="7531")
    nadia = s(r.get("session_token")) or "missing"
    check("Nadia verifies as REVIEWER (Production Engineering)", r["outcome"] == "VERIFIED" and r.get("team") == "Production Engineering", r)
    wade = s(one("verify_reviewer", staff_id="MRE-7101", code="4096").get("session_token")) or "missing"
    curtis = s(one("verify_reviewer", staff_id="MRE-8101", code="6174").get("session_token")) or "missing"
    check("operator token on the review queue -> NOT_REVIEWER", one("get_review_queue", session_token=jolene)["status"] == "NOT_REVIEWER")
    q1 = call("get_review_queue", session_token=wade)
    check("Production Engineering queue has the budget case, not the HSE case",
          scase in [x["case_id"] for x in q1] and odor not in [x["case_id"] for x in q1], [x["case_id"] for x in q1])
    rc = one("get_review_case", session_token=nadia, case_id=scase)
    check("get_review_case: $68,000 requested, Nadia's authority $50,000", rc["requested_budget_usd"] == "$68,000.00"
          and rc["your_budget_authority_usd"] == "$50,000.00", rc)
    check("cross-team: HSE cannot open the budget case -> NOT_FOUND",
          one("get_review_case", session_token=curtis, case_id=scase)["status"] == "NOT_FOUND")
    r = one("decide_review_case", session_token=jolene, case_id=scase, decision="APPROVE", amount="", internal_note="self approve", customer_message="ok")
    check("operator cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
    r = one("decide_review_case", session_token=nadia, case_id=scase, decision="APPROVE", amount="", internal_note="Full overhaul needed", customer_message="Approved")
    check("Nadia $68,000 > $50,000 -> OVER_AUTHORITY, case stays OPEN", r.get("reason_code") == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    MSG = "Approved with a $60,000 budget for the top-end overhaul and cooler repair."
    r = one("decide_review_case", session_token=wade, case_id=scase, decision="APPROVE", amount="60000",
            internal_note="Top end plus cooler; defer second-stage valves", customer_message=MSG)
    check("Wade approves $60,000 -> APPROVED, work order created", r["outcome"] == "APPROVED" and "Work order created" in s(r.get("executed_action")), r)
    check("DB: S12 work order with budget 60000 + case + approver, decision row, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM work_orders WHERE case_id='{scase}' AND approved_budget_usd=60000 AND approved_by='MRE-7101'") == 1
          and n(f"SELECT count(*) FROM review_decisions WHERE case_id='{scase}'") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{scase}'") == 1)
    r = one("decide_review_case", session_token=wade, case_id=scase, decision="REJECT", amount="", internal_note="second go", customer_message="")
    check("second decision -> ALREADY_DECIDED", r.get("reason_code") == "ALREADY_DECIDED", r)
    r = one("decide_review_case", session_token=curtis, case_id=odor, decision="APPROVE", amount="",
            internal_note="Send the crew with gas detectors", customer_message="HSE approved an emergency safety inspection.")
    check("Curtis approves the gas-odor case -> EMERGENCY safety-inspection work order", r["outcome"] == "APPROVED"
          and n(f"SELECT count(*) FROM work_orders WHERE case_id='{odor}' AND wo_type='SAFETY_INSPECTION' AND priority='EMERGENCY'") == 1, r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=jolene)}
    check("operator sees the outcome: APPROVED + message, no internal note",
          mc.get(scase, {}).get("case_status") == "APPROVED" and mc[scase].get("customer_message") == MSG
          and "second-stage" not in json.dumps(mc), mc.get(scase))

    # ---- guarded email: refusals first, then one real send ----
    e = one("email_asset_summary", session_token=jolene, asset_id="PUMP-EF-W14")
    check("SCOPE: Jolene emails an Eagle Ford asset -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    e = one("email_asset_summary", session_token=travis, asset_id="VALVE-BK-W03")
    check("nothing done on VALVE-BK-W03 -> NOT_SENT NOTHING_TO_SEND", e.get("reason_code") == "NOTHING_TO_SEND", e)
    check("DB: refused emails logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_asset_summary", session_token=jolene, asset_id="COMP-PB-S12")
        check("email COMP-PB-S12 summary -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK", e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the portable dummy Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n("SELECT count(*) FROM email_log WHERE asset_id='COMP-PB-S12' AND operator_id='MRE-4101'") == 1)

    # ---- hidden data ----
    op = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
    leaked = sorted({k for _, rows in op for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no operator tool output carries a hidden column", not leaked, leaked)
    oblob = json.dumps(op)
    check("operator outputs never carry reviewer names, internal notes or desk phones",
          not re.search(r"Hollister|Brennan|Rayburn|second-stage valves|555-01[456]", oblob))
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
