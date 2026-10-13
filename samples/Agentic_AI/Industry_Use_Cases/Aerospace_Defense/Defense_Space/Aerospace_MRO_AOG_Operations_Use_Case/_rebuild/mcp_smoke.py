#!/usr/bin/env python3
"""Test ladder step 3: call the running AerospaceMROMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9812/aerospacemromcp), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (aerospace_mro_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Attempts ONE real ops-summary email (N042NV) to the EMAIL_TO app
property; the SQL guard + email_log are asserted, SMTP delivery is reported separately."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, REVIEWER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9812/aerospacemromcp")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "aerospace_mro_governed"),
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
    check("tools/list = exactly the 19 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 19,
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
    r = one("verify_controller", staff_id="NVA-2101", code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_controller", staff_id="nva2101", code="3852")
    check("Teresa 'nva2101' -> VERIFIED CONTROLLER, Granite Mesa", r["outcome"] == "VERIFIED" and r.get("session_token")
          and r.get("role") == "CONTROLLER" and "Granite Mesa" in s(r.get("base")), {k: x for k, x in r.items() if k != "session_token"})
    teresa = s(r.get("session_token")) or "missing"
    kenji = s(one("verify_controller", staff_id="3101", code="9174").get("session_token")) or "missing"
    check("Kenji (bare digits) verifies", kenji != "missing")
    check("forged token -> SESSION_INVALID", one("get_base_fleet", session_token=BAD)["status"] == "SESSION_INVALID")

    # ---- scoped reads ----
    fleet = call("get_base_fleet", session_token=teresa)
    check("get_base_fleet: Granite Mesa's 4 aircraft, N042NV AOG first",
          len(fleet) == 4 and fleet[0]["tail_number"] == "N042NV" and fleet[0]["aircraft_status"] == "AOG", fleet[:1])
    check("SCOPE: Teresa's work orders for N078NV -> NOT_FOUND",
          one("get_work_orders", session_token=teresa, tail_number="N078NV")["status"] == "NOT_FOUND")
    wos = call("get_work_orders", session_token=teresa, tail_number="N042NV")
    check("get_work_orders N042NV: WO-2026-00101 AOG unassigned, needs HYDRAULICS",
          s(wos[0].get("wo_number")) == "WO-2026-00101" and wos[0].get("required_certification") == "HYDRAULICS", wos[:1])
    hist = call("get_tail_history", session_token=teresa, tail_number="N042NV")
    check("get_tail_history N042NV: 3 ATA 29 work orders in 30 days",
          sum(1 for x in hist if s(x.get("ata_chapter")) == "29") == 3
          and all(num(x.get("same_ata_last_30_days")) == 3 for x in hist if s(x.get("ata_chapter")) == "29"), hist)
    parts = call("get_parts", session_token=teresa, search="NV-450")
    check("get_parts NV-450: pump $48,750, seal kit $850 (1 on hand), fitting kit",
          {x["part_number"] for x in parts} == {"NV29-4471-P", "NV29-4471-SK", "NV29-1180-F"}
          and any(x["part_number"] == "NV29-4471-SK" and num(x.get("on_hand_at_your_base")) == 1 for x in parts), parts)
    techs = call("get_technicians", session_token=teresa, certification="HYDRAULICS")
    check("get_technicians HYDRAULICS: Rosa AVAILABLE, Samir OFF", [x["tech_id"] for x in techs] == ["TECH-201", "TECH-203"], techs)
    check("get_aog_incidents: AOG-2026-014 OPEN first", one("get_aog_incidents", session_token=teresa)["aog_id"] == "AOG-2026-014")
    check("get_part_orders: PO-2026-0002", one("get_part_orders", session_token=teresa)["order_id"] == "PO-2026-0002")
    ho = call("get_base_handover", session_token=teresa)
    check("get_base_handover: AOG row first, no technician names", ho[0]["item_type"] == "AOG"
          and not re.search(r"Delgado|Brandt|Haddad|TECH-", json.dumps(ho)), ho[:2])

    # ---- two-step part order (under the limit) ----
    r = one("propose_part_order", session_token=teresa, wo_number="WO-2026-00101", part_number="NV32-1002-B", quantity="1", priority="ROUTINE")
    check("propose an NV-200 brake for the NV-450 -> BLOCKED PART_NOT_APPLICABLE", r["outcome"] == "BLOCKED" and r.get("reason_code") == "PART_NOT_APPLICABLE", r)
    r = one("propose_part_order", session_token=teresa, wo_number="WO-2026-00101", part_number="NV29-4471-SK", quantity="2", priority="EXPEDITE")
    check("propose 2 seal kits EXPEDITE -> PROPOSED $1,700.00, no manager approval",
          r["outcome"] == "PROPOSED" and r.get("proposal_id") and s(r.get("total_usd")) == "$1,700.00" and r.get("needs_manager_approval") == "no", r)
    check("DB: proposal ordered nothing", n("SELECT count(*) FROM part_orders WHERE proposal_id IS NOT NULL") == 0)
    c = one("confirm_action", session_token=teresa, proposal_id=s(r.get("proposal_id")))
    check("confirm -> EXECUTED PO-2026-0101", c["outcome"] == "EXECUTED" and c.get("reference") == "PO-2026-0101", c)
    check("DB: 2 seal kits on order, $1,700", n("SELECT count(*) FROM part_orders WHERE order_id='PO-2026-0101' AND quantity=2 AND total_usd=1700") == 1)
    c = one("confirm_action", session_token=kenji, proposal_id=s(r.get("proposal_id")))
    check("Kenji confirming Teresa's proposal -> NOT_FOUND", c["outcome"] == "NOT_FOUND", c)

    # ---- two-step dispatch ----
    r = one("propose_dispatch", session_token=teresa, wo_number="WO-2026-00101", tech_id="TECH-202")
    check("propose Caleb -> BLOCKED NOT_CERTIFIED", r["outcome"] == "BLOCKED" and r.get("reason_code") == "NOT_CERTIFIED", r)
    r = one("propose_dispatch", session_token=teresa, wo_number="WO-2026-00101", tech_id="TECH-302")
    check("propose Grace (Harbor Point) -> BLOCKED WRONG_BASE", r.get("reason_code") == "WRONG_BASE", r)
    r = one("propose_dispatch", session_token=teresa, wo_number="WO-2026-00101", tech_id="TECH-201")
    check("propose Rosa -> PROPOSED", r["outcome"] == "PROPOSED" and r.get("proposal_id"), r)
    c = one("confirm_action", session_token=teresa, proposal_id=s(r.get("proposal_id")))
    check("confirm -> EXECUTED NVA-DSP-000101", c["outcome"] == "EXECUTED" and c.get("reference") == "NVA-DSP-000101", c)
    check("DB: WO IN_PROGRESS with Rosa, AOG-2026-014 RESOLVING",
          v("SELECT status || '/' || assigned_tech FROM work_orders WHERE wo_number='WO-2026-00101'") == "IN_PROGRESS/TECH-201"
          and v("SELECT status FROM aog_incidents WHERE aog_id='AOG-2026-014'") == "RESOLVING")

    # ---- spend above the limit -> manager case ----
    r = one("propose_part_order", session_token=teresa, wo_number="WO-2026-00101", part_number="NV29-4471-P", quantity="2", priority="EXPEDITE")
    check("propose 2 pumps -> PROPOSED $97,500.00, needs manager approval", r["outcome"] == "PROPOSED"
          and s(r.get("total_usd")) == "$97,500.00" and r.get("needs_manager_approval") == "yes", r)
    c = one("confirm_action", session_token=teresa, proposal_id=s(r.get("proposal_id")))
    pcase = s(c.get("case_id"))
    check("confirm -> MANAGER_APPROVAL with a case, nothing ordered", c["outcome"] == "MANAGER_APPROVAL" and pcase.startswith("NVA-CASE-")
          and n("SELECT count(*) FROM part_orders WHERE part_number='NV29-4471-P'") == 0, c)

    # ---- human-owned cases ----
    r = one("open_service_case", session_token=teresa, request_type="return_to_service", tail_number="N042NV",
            summary="Seal kit fitted and leak check done; please sign off.", agent_brief="")
    check("open_service_case return_to_service -> OPENED with Quality & Airworthiness", r["outcome"] == "OPENED"
          and r.get("team") == "Quality & Airworthiness", r)
    rts = s(r.get("case_id"))
    r = one("open_service_case", session_token=teresa, request_type="return_to_service", tail_number="N078NV", summary="x", agent_brief="")
    check("open_service_case for a Harbor Point tail -> BLOCKED NOT_FOUND", r.get("reason_code") == "NOT_FOUND", r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=teresa)}
    check("get_my_cases: pump case OPEN, RTS case OPEN", mc.get(pcase, {}).get("case_status") == "OPEN" and rts in mc, list(mc))

    # ---- reviewer loop ----
    r = one("verify_reviewer", staff_id="NVA-7101", code="9999")
    check("reviewer wrong code -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
    gloria = s(one("verify_reviewer", staff_id="NVA-7101", code="4417").get("session_token")) or "missing"
    victor = s(one("verify_reviewer", staff_id="7102", code="5823").get("session_token")) or "missing"
    ingrid = s(one("verify_reviewer", staff_id="NVA-8101", code="6390").get("session_token")) or "missing"
    check("Gloria, Victor and Ingrid verify as reviewers", "missing" not in (gloria, victor, ingrid))
    check("controller token on get_review_queue -> NOT_REVIEWER", one("get_review_queue", session_token=teresa)["status"] == "NOT_REVIEWER")
    q_ = call("get_review_queue", session_token=gloria)
    check("Gloria's queue: actuator case + pump case", [x["case_id"] for x in q_] == ["NVA-CASE-000101", pcase], q_)
    rc = one("get_review_case", session_token=gloria, case_id=pcase)
    check("get_review_case: $97,500, max 2 units, authority $100,000", rc["status"] == "OK" and s(rc.get("requested_spend_usd")) == "$97,500.00"
          and num(rc.get("max_approvable_units")) == 2 and s(rc.get("your_spend_authority_usd")) == "$100,000.00", rc)
    check("get_review_case: Gloria opens a Quality case -> NOT_FOUND", one("get_review_case", session_token=gloria, case_id=rts)["status"] == "NOT_FOUND")
    r = one("decide_review_case", session_token=teresa, case_id=pcase, decision="APPROVE", amount="2", internal_note="self approve", customer_message="")
    check("decide with a controller token -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, r)
    r = one("decide_review_case", session_token=victor, case_id=pcase, decision="APPROVE", amount="2", internal_note="AOG recovery", customer_message="")
    check("Victor 2 pumps -> OVER_AUTHORITY, case stays OPEN", r.get("reason_code") == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    r = one("decide_review_case", session_token=gloria, case_id=rts, decision="APPROVE", amount="", internal_note="not mine", customer_message="")
    check("Gloria decides a Quality case -> NOT_YOUR_TEAM", r.get("reason_code") == "NOT_YOUR_TEAM", r)
    r = one("decide_review_case", session_token=gloria, case_id=pcase, decision="APPROVE", amount="2", internal_note="ok", customer_message="")
    check("2-character note -> NOTE_REQUIRED", r.get("reason_code") == "NOTE_REQUIRED", r)
    MSG = "Approved: both pumps are on expedite for N042NV."
    r = one("decide_review_case", session_token=gloria, case_id=pcase, decision="APPROVE", amount="2",
            internal_note="AOG recovery, second pump restores the reorder level", customer_message=MSG)
    check("Gloria approves 2 pumps -> APPROVED, ordered", r["outcome"] == "APPROVED" and s(r.get("executed_action")).startswith("Ordered: PO-2026-"), r)
    check("DB: pump order with case + approver, decision row, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM part_orders WHERE case_id='{pcase}' AND quantity=2 AND approved_by='NVA-7101'") == 1
          and n(f"SELECT count(*) FROM review_decisions WHERE case_id='{pcase}'") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{pcase}'") == 1)
    r = one("decide_review_case", session_token=gloria, case_id=pcase, decision="REJECT", amount="", internal_note="second go", customer_message="")
    check("second decision -> ALREADY_DECIDED", r.get("reason_code") == "ALREADY_DECIDED", r)
    r = one("decide_review_case", session_token=ingrid, case_id=rts, decision="APPROVE", amount="",
            internal_note="Leak check witnessed, paperwork complete", customer_message="N042NV is back in service.")
    check("Ingrid approves return to service -> N042NV IN_SERVICE, AOG resolved", r["outcome"] == "APPROVED"
          and v("SELECT status FROM aircraft WHERE tail_number='N042NV'") == "IN_SERVICE"
          and v("SELECT status FROM aog_incidents WHERE aog_id='AOG-2026-014'") == "RESOLVED", r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=teresa)}
    check("controller sees the outcome: APPROVED + message, no internal note",
          mc.get(pcase, {}).get("case_status") == "APPROVED" and mc[pcase].get("customer_message") == MSG
          and "reorder level" not in json.dumps(mc), mc.get(pcase))

    # ---- guarded email: refusals first, then one real send ----
    e = one("email_ops_summary", session_token=teresa, tail_number="N078NV")
    check("SCOPE: Teresa emails a Harbor Point tail -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    e = one("email_ops_summary", session_token=teresa, tail_number="N063NV")
    check("nothing done on N063NV -> NOT_SENT NOTHING_TO_SEND", e.get("reason_code") == "NOTHING_TO_SEND", e)
    check("DB: refused emails logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_ops_summary", session_token=teresa, tail_number="N042NV")
        check("email N042NV ops summary -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK", e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the portable dummy Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n("SELECT count(*) FROM email_log WHERE tail_number='N042NV' AND controller_id='NVA-2101'") == 1)

    # ---- hidden data ----
    co = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
    leaked = sorted({k for _, rows in co for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no controller tool output carries a hidden column", not leaked, leaked)
    blob = json.dumps(OUTPUTS)
    check("no tool output carries technician emails or phones or reviewer internal notes",
          not re.search(r"northvale-aero\.example\.com|\(555\) 010-2141|reorder level\"", blob), re.findall(r"\S+@\S+", blob)[:3])
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
