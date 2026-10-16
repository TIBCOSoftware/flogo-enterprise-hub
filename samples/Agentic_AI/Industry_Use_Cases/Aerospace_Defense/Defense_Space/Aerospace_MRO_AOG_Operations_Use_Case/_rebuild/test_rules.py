#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the aerospace_mro_governed DB and assert the
business rules on DB state - controller scope, the two-step part order (incl. spend above the controller's limit ->
maintenance-manager case) and technician dispatch, cases, the full reviewer loop (team, spend authority, quantity, the
parked part order and return to service, audit), the guarded email and the A2A agents' read-only reference tools
(ref_* functions). No Flogo needed. Re-loads reset_data.sql first and
again at the end (re-runnable).

  python _rebuild/test_rules.py
Password: env PG_PWD, else PG_PASSWORD from the nearest skills-library/.claude/skills/config.md (never printed).
Env overrides: PSQL, PG_HOST, PG_PORT, PG_USER, PG_DB, CONFIG_MD.
"""
import csv, io, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS, AGENT_REF_TOOLS, REF_COLUMNS

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
    sys.exit("set PG_PWD or PG_PASSWORD in config.md")
PSQL = (os.environ.get("PSQL") or _config_value("PSQL_PATH") or shutil.which("psql")
        or sys.exit("psql not found: install the PostgreSQL client and put psql on PATH, or set env PSQL / config.md "
                    "PSQL_PATH (see skills-library/AGENT.md -> Prerequisites and preflight)"))
ENV = dict(os.environ, PGPASSWORD=PWD)
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "aerospace_mro_governed"),
        "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = passes = 0
OUTPUTS = []          # (tool, rows) for the hidden-column scans


def lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def sub(sql, params, args):
    """Substitute ?name exactly like the Flogo wi-postgres activity: only when followed by ` ;),<>+-*%/`."""
    assert sorted(re.findall(r"\?(\w+)", sql)) == sorted(p for p, _ in params), sql
    for ph, arg in params:
        sql, n = re.subn(r"\?" + ph + r"(?=[\s;),<>+\-*%/])", lambda _m: lit(args.get(arg, "")), sql)
        assert n == 1, f"placeholder ?{ph} used {n} times"
    return sql


def psql(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV, encoding="utf-8")
    if r.returncode:
        print(r.stderr.encode("ascii", "replace").decode()); print(sql[:400]); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))


def call(tool, **args):
    t = T[tool]
    full = {a: args.get(a, "") for a, _ in t["args"]}          # empty string for args the model leaves blank
    assert set(args) <= set(full), (tool, args)
    if "write" in t:
        psql(sub(*t["write"], full))
    rows = psql(sub(*t["read"], full))
    OUTPUTS.append((tool, rows))
    return rows


def one(tool, **args):
    return call(tool, **args)[0]


def n(sql):
    return int(list(psql(sql)[0].values())[0])


def val(sql):
    rows = psql(sql)
    return list(rows[0].values())[0] if rows else None


def check(label, cond, detail=""):
    global fails, passes
    msg = ("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:600]}")
    print(msg.encode("ascii", "replace").decode())
    if cond: passes += 1
    else: fails += 1


def reset():
    subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


def i0(v):
    return int(float(v)) if v not in (None, "") else None


reset()

# ---------------------------------------------------------------- contract shape
check("19 MCP tools", len(TOOLS) == 19, [t["tool"] for t in TOOLS])
check("every write is INSERT ... SELECT (never VALUES)",
      all(re.match(r"INSERT INTO \w+ \([^)]*\) SELECT ", t["write"][0]) and "VALUES" not in t["write"][0].upper()
          for t in TOOLS if "write" in t))
check("write placeholders ?w_*, read placeholders never ?w_*",
      all(all(p.startswith("w_") for p, _ in t["write"][1]) for t in TOOLS if "write" in t)
      and all(not p.startswith("w_") for t in TOOLS for p, _ in t["read"][1]))
check("no ?p:: casts anywhere", not any(re.search(r"\?\w+::", t.get("write", ("",))[0] + t["read"][0]) for t in TOOLS))
check("reads are readonly, writes are not", all(t["readonly"] == ("write" not in t) for t in TOOLS))
check("exactly one email tool", sum(1 for t in TOOLS if t.get("email")) == 1)

# ---------------------------------------------------------------- identity
v = one("verify_controller", staff_id="2101", code="0000")
check("wrong code -> VERIFY_FAILED, no token", v["outcome"] == "VERIFY_FAILED" and not v["session_token"], v)
v = one("verify_controller", staff_id="nva-2101", code="3852")
teresa = v["session_token"]
check("Teresa verifies (nva-2101 normalised) -> VERIFIED, Granite Mesa, $25,000 limit",
      v["outcome"] == "VERIFIED" and teresa and "Granite Mesa" in v["base"] and v["spend_limit_usd"] == "$25,000.00", v)
kenji = one("verify_controller", staff_id="NVA 3101", code="9174")["session_token"]
check("Kenji verifies (Harbor Point)", bool(kenji))
v = one("verify_controller", staff_id="NVA-7101", code="4417")
check("a reviewer's id + code cannot verify as a controller", v["outcome"] == "VERIFY_FAILED" and not v["session_token"], v)
for _ in range(5):
    one("verify_controller", staff_id="NVA-3101", code="1111")
v = one("verify_controller", staff_id="NVA-3101", code="9174")
check("5 failures in 15 minutes -> LOCKED even with the right code", v["outcome"] == "LOCKED" and not v["session_token"], v)
psql("DELETE FROM verify_attempts WHERE identifier = 'NVA-3101' AND outcome <> 'VERIFIED'")
check("forged token -> SESSION_INVALID", one("get_base_fleet", session_token="not-a-token")["status"] == "SESSION_INVALID")
check("empty token -> SESSION_INVALID", one("get_work_orders", session_token="", tail_number="ALL")["status"] == "SESSION_INVALID")

# ---------------------------------------------------------------- scoped reads
fleet = call("get_base_fleet", session_token=teresa)
check("Teresa's fleet = the 4 Granite Mesa aircraft, AOG first",
      [r["tail_number"] for r in fleet][0] == "N042NV" and {r["tail_number"] for r in fleet} == {"N042NV", "N047NV", "N021NV", "N063NV"}, fleet)
check("N042NV shows AOG-2026-014 OPEN", fleet[0]["open_aog"] == "AOG-2026-014 (OPEN)" and fleet[0]["aircraft_status"] == "AOG", fleet[0])
check("Kenji's fleet = the 4 Harbor Point aircraft",
      {r["tail_number"] for r in call("get_base_fleet", session_token=kenji)} == {"N034NV", "N055NV", "N078NV", "N089NV"})
wos = call("get_work_orders", session_token=teresa, tail_number="n042nv")
check("N042NV open work orders: WO-2026-00101 (AOG, unassigned) first, then 00102",
      [r["wo_number"] for r in wos] == ["WO-2026-00101", "WO-2026-00102"] and wos[0]["assigned_technician"] == "unassigned"
      and wos[0]["required_certification"] == "HYDRAULICS", wos)
check("all open work at Granite Mesa = 5 work orders", len(call("get_work_orders", session_token=teresa, tail_number="ALL")) == 5)
check("SCOPE: Teresa asks for N078NV (Harbor Point) -> NOT_FOUND",
      one("get_work_orders", session_token=teresa, tail_number="N078NV")["status"] == "NOT_FOUND")
check("N063NV with no AOG work -> OK rows only for its own WOs",
      [r["wo_number"] for r in call("get_work_orders", session_token=teresa, tail_number="N063NV")] == ["WO-2026-00103"])
hist = call("get_tail_history", session_token=teresa, tail_number="N042NV")
h29 = [r for r in hist if r["ata_chapter"] == "29"]
check("N042NV history: 3 ATA 29 work orders in 30 days (the repeat-defect signal), closed history included",
      len(h29) == 3 and all(i0(r["same_ata_last_30_days"]) == 3 for r in h29) and any(r["wo_status"] == "CLOSED" for r in h29), hist)
check("SCOPE: Kenji asks for N042NV history -> NOT_FOUND",
      one("get_tail_history", session_token=kenji, tail_number="N042NV")["status"] == "NOT_FOUND")
parts = call("get_parts", session_token=teresa, search="hydraulic NV-450")
check("parts search 'hydraulic NV-450' -> pump, seal kit, fitting kit with Granite Mesa stock",
      {r["part_number"] for r in parts} == {"NV29-4471-P", "NV29-4471-SK", "NV29-1180-F"}
      and next(r for r in parts if r["part_number"] == "NV29-4471-SK")["on_hand_at_your_base"] == "1"
      and next(r for r in parts if r["part_number"] == "NV29-4471-P")["unit_price_usd"] == "$48,750.00", parts)
check("parts search by number without dashes works", one("get_parts", session_token=teresa, search="nv294471sk")["part_number"] == "NV29-4471-SK")
check("parts ALL = 10 catalogue items", len(call("get_parts", session_token=teresa, search="ALL")) == 10)
check("parts search with no match -> NONE", one("get_parts", session_token=teresa, search="wing flap motor")["status"] == "NONE")
techs = call("get_technicians", session_token=teresa, certification="hydraulics")
check("hydraulics technicians at Granite Mesa: Rosa (AVAILABLE) first, Samir (OFF); never Grace (Harbor Point)",
      [r["tech_id"] for r in techs] == ["TECH-201", "TECH-203"] and techs[0]["availability"] == "AVAILABLE", techs)
check("all technicians at Granite Mesa = 5", len(call("get_technicians", session_token=teresa, certification="ALL")) == 5)
po = call("get_part_orders", session_token=teresa)
check("Granite Mesa part orders: only PO-2026-0002", [r["order_id"] for r in po] == ["PO-2026-0002"], po)
aogs = call("get_aog_incidents", session_token=teresa)
check("Granite Mesa AOGs: AOG-2026-014 OPEN first, AOG-2026-009 resolved; never Harbor Point's",
      [r["aog_id"] for r in aogs] == ["AOG-2026-014", "AOG-2026-009"] and aogs[0]["aog_status"] == "OPEN", aogs)
ho = call("get_base_handover", session_token=teresa)
check("handover snapshot: AOG first, work orders, part orders, the open MEL case; no people's names",
      ho[0]["item_type"] == "AOG" and {r["item_type"] for r in ho} >= {"AOG", "WORK_ORDER", "PART_ORDER", "OPEN_CASE"}
      and not re.search(r"Delgado|Brandt|Haddad|Cole|Pierce|Lindqvist|Mendez|Castellanos|TECH-", " ".join(str(v) for r in ho for v in r.values())), ho)
mc = call("get_my_cases", session_token=teresa)
check("Teresa's cases: the seeded MEL deferral only (not Kenji's)", [r["case_id"] for r in mc] == ["NVA-CASE-000103"], mc)


# ---------------------------------------------------------------- part order: propose rules (one code each)
def propose_part(tok, wo, part, qty, prio):
    return one("propose_part_order", session_token=tok, wo_number=wo, part_number=part, quantity=qty, priority=prio)


def blocked(r, code):
    return r["outcome"] == "BLOCKED" and r["reason_code"] == code and not r["proposal_id"]


check("PART: WO at another base -> NOT_FOUND", blocked(propose_part(teresa, "WO-2026-00201", "NV32-8830-A", "1", "EXPEDITE"), "NOT_FOUND"))
check("PART: closed WO -> WO_CLOSED", blocked(propose_part(teresa, "WO-2026-00091", "NV29-4471-SK", "1", "ROUTINE"), "WO_CLOSED"))
check("PART: unknown part -> PART_NOT_FOUND", blocked(propose_part(teresa, "WO-2026-00101", "NV99-0000-X", "1", "ROUTINE"), "PART_NOT_FOUND"))
r = propose_part(teresa, "WO-2026-00101", "NV32-1002-B", "1", "ROUTINE")
check("PART: an NV-200 brake for the NV-450 -> PART_NOT_APPLICABLE (names both types)",
      blocked(r, "PART_NOT_APPLICABLE") and "NV-200" in r["reason_text"] and "NV-450" in r["reason_text"], r)
check("PART: quantity 0 -> QTY_INVALID", blocked(propose_part(teresa, "WO-2026-00101", "NV29-4471-SK", "0", "ROUTINE"), "QTY_INVALID"))
check("PART: quantity 11 -> QTY_INVALID", blocked(propose_part(teresa, "WO-2026-00101", "NV29-4471-SK", "11", "ROUTINE"), "QTY_INVALID"))
check("PART: quantity 'a few' -> QTY_INVALID", blocked(propose_part(teresa, "WO-2026-00101", "NV29-4471-SK", "a few", "ROUTINE"), "QTY_INVALID"))
check("PART: priority 'overnight please' -> INVALID_PRIORITY",
      blocked(propose_part(teresa, "WO-2026-00101", "NV29-4471-SK", "1", "overnight please"), "INVALID_PRIORITY"))
check("PART: cabin pressure controller already on order for WO-2026-00104 -> ALREADY_ORDERED",
      blocked(propose_part(teresa, "WO-2026-00104", "NV21-6621-C", "1", "ROUTINE"), "ALREADY_ORDERED"))
psql("DELETE FROM pending_actions WHERE outcome = 'BLOCKED'")

# ---------------------------------------------------------------- part order: seal kit (under the limit) end to end
r = propose_part(teresa, "101", "nv29 4471 sk", "2 kits", "expedited")
seal_pid = r["proposal_id"]
check("PART: 2 seal kits EXPEDITE -> PROPOSED, $1,700.00, no manager approval, delivery tomorrow",
      r["outcome"] == "PROPOSED" and seal_pid and r["total_usd"] == "$1,700.00" and r["needs_manager_approval"] == "no"
      and val("SELECT d(current_date + 1)") in r["summary"], r)
r2 = propose_part(teresa, "WO-2026-00101", "NV29-4471-SK", "2", "EXPEDITE")
check("PART: the same proposal again (normalised) -> the same proposal_id, no duplicate row",
      r2["proposal_id"] == seal_pid and n("SELECT count(*) FROM pending_actions WHERE action_type='PART_ORDER' AND outcome='PROPOSED' AND controller_id='NVA-2101'") == 1, r2)
check("PROPOSE writes nothing yet", n("SELECT count(*) FROM part_orders WHERE proposal_id IS NOT NULL") == 0)
check("CONFIRM: Kenji cannot confirm Teresa's proposal -> NOT_FOUND",
      one("confirm_action", session_token=kenji, proposal_id=seal_pid)["outcome"] == "NOT_FOUND")
c = one("confirm_action", session_token=teresa, proposal_id=seal_pid.lower())
check("CONFIRM seal kits -> EXECUTED with PO-2026-0101", c["outcome"] == "EXECUTED" and c["reference"] == "PO-2026-0101" and not c["case_id"], c)
o = psql("SELECT * FROM part_orders WHERE order_id = 'PO-2026-0101'")
check("DB: PO-2026-0101 = 2 x NV29-4471-SK, $1,700, EXPEDITE, delivery tomorrow, ordered by Teresa, no case",
      len(o) == 1 and o[0]["quantity"] == "2" and o[0]["total_usd"] == "1700.00" and o[0]["priority"] == "EXPEDITE"
      and o[0]["expected_delivery"] == val("SELECT current_date + 1") and o[0]["ordered_by"] == "NVA-2101" and not o[0]["case_id"], o)
check("DB: PART_ORDERED audit row", n("SELECT count(*) FROM agent_audit WHERE event_type='PART_ORDERED' AND subject_id='PO-2026-0101'") == 1)
c = one("confirm_action", session_token=teresa, proposal_id=seal_pid)
check("CONFIRM twice -> ALREADY_DONE, still one order", c["outcome"] == "ALREADY_DONE" and n("SELECT count(*) FROM part_orders WHERE proposal_id IS NOT NULL") == 1, c)
check("PART: seal kits again -> ALREADY_ORDERED (order PO-2026-0101)",
      "PO-2026-0101" in propose_part(teresa, "WO-2026-00101", "NV29-4471-SK", "1", "ROUTINE")["reason_text"])
check("CONFIRM unknown proposal -> NOT_FOUND", one("confirm_action", session_token=teresa, proposal_id="NVA-PRP-NOPE")["outcome"] == "NOT_FOUND")

# ---------------------------------------------------------------- part order: expiry
r = propose_part(teresa, "WO-2026-00102", "NV29-1180-F", "1", "ROUTINE")
exp_pid = r["proposal_id"]
check("PART: a fitting kit for WO-2026-00102 -> PROPOSED", r["outcome"] == "PROPOSED" and exp_pid, r)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE proposal_id = {lit(exp_pid)}")
c = one("confirm_action", session_token=teresa, proposal_id=exp_pid)
check("CONFIRM after 15 minutes -> EXPIRED, nothing ordered", c["outcome"] == "EXPIRED"
      and n(f"SELECT count(*) FROM part_orders WHERE proposal_id = {lit(exp_pid)}") == 0, c)

# ---------------------------------------------------------------- part order: re-check at confirm
r = propose_part(teresa, "WO-2026-00105", "NV29-1180-F", "1", "ROUTINE")
check("PART: an NV-450 fitting kit for N021NV (NV-200) -> PART_NOT_APPLICABLE", blocked(r, "PART_NOT_APPLICABLE"), r)
r = propose_part(teresa, "WO-2026-00103", "NV65-5540-R", "1", "ROUTINE")
blade_pid = r["proposal_id"]
check("PART: a rotor blade for WO-2026-00103 -> PROPOSED ($38,900 > $25,000 -> needs approval)",
      r["outcome"] == "PROPOSED" and r["needs_manager_approval"] == "yes", r)
psql("UPDATE work_orders SET status = 'CLOSED', closed_date = current_date WHERE wo_number = 'WO-2026-00103'")
c = one("confirm_action", session_token=teresa, proposal_id=blade_pid)
check("CONFIRM re-checks: the WO was closed meanwhile -> BLOCKED WO_CLOSED, no case, no order",
      c["outcome"] == "BLOCKED" and c["reason_code"] == "WO_CLOSED"
      and n("SELECT count(*) FROM service_cases WHERE request_type='spend_approval' AND opened_by='NVA-2101'") == 0, c)
psql("UPDATE work_orders SET status = 'OPEN', closed_date = NULL WHERE wo_number = 'WO-2026-00103'")

# ---------------------------------------------------------------- technician dispatch (one code each, then the happy path)
def propose_dsp(tok, wo, tech):
    return one("propose_dispatch", session_token=tok, wo_number=wo, tech_id=tech)


check("DISPATCH: WO at another base -> NOT_FOUND", blocked(propose_dsp(teresa, "WO-2026-00202", "TECH-303"), "NOT_FOUND"))
check("DISPATCH: closed WO -> WO_CLOSED", blocked(propose_dsp(teresa, "WO-2026-00096", "TECH-201"), "WO_CLOSED"))
r = propose_dsp(teresa, "WO-2026-00104", "TECH-202")
check("DISPATCH: WO-2026-00104 already has Nolan -> ALREADY_ASSIGNED", blocked(r, "ALREADY_ASSIGNED") and "Nolan Pierce" in r["reason_text"], r)
check("DISPATCH: unknown technician -> TECH_NOT_FOUND", blocked(propose_dsp(teresa, "WO-2026-00101", "TECH-999"), "TECH_NOT_FOUND"))
r = propose_dsp(teresa, "WO-2026-00101", "Grace Whitaker")
check("DISPATCH: Grace (Harbor Point, certified) -> WRONG_BASE", blocked(r, "WRONG_BASE") and "Harbor Point" in r["reason_text"], r)
r = propose_dsp(teresa, "WO-2026-00101", "Caleb Brandt")
check("DISPATCH: Caleb (NV-450 rated but AVIONICS/STRUCTURES, no HYDRAULICS) -> NOT_CERTIFIED",
      blocked(r, "NOT_CERTIFIED") and "HYDRAULICS" in r["reason_text"], r)
r = propose_dsp(teresa, "WO-2026-00103", "TECH-201")
check("DISPATCH: Rosa to the rotor 100-hour (needs ROTOR SYSTEMS + NV-60) -> NOT_CERTIFIED", blocked(r, "NOT_CERTIFIED"), r)
r = propose_dsp(teresa, "WO-2026-00101", "tech203")
check("DISPATCH: Samir (certified, OFF shift) -> TECH_UNAVAILABLE", blocked(r, "TECH_UNAVAILABLE") and "off shift" in r["reason_text"], r)
check("DISPATCH blocks write nothing", n("SELECT count(*) FROM action_events WHERE action_type='DISPATCH'") == 0)
r = propose_dsp(teresa, "wo-2026-00101", "Rosa Delgado")
rosa_pid = r["proposal_id"]
check("DISPATCH: Rosa (HYDRAULICS + NV-450, AVAILABLE) -> PROPOSED; summary says AOG-2026-014 moves to RESOLVING",
      r["outcome"] == "PROPOSED" and rosa_pid and "AOG-2026-014" in r["summary"] and "TECH-201" in r["summary"], r)
check("DISPATCH proposal writes nothing yet",
      val("SELECT assigned_tech FROM work_orders WHERE wo_number='WO-2026-00101'") in (None, ""))
c = one("confirm_action", session_token=teresa, proposal_id=rosa_pid)
check("CONFIRM dispatch -> EXECUTED NVA-DSP-000101", c["outcome"] == "EXECUTED" and c["reference"] == "NVA-DSP-000101", c)
w = psql("SELECT status, assigned_tech FROM work_orders WHERE wo_number = 'WO-2026-00101'")[0]
check("DB: WO-2026-00101 IN_PROGRESS with TECH-201", w["status"] == "IN_PROGRESS" and w["assigned_tech"] == "TECH-201", w)
check("DB: Rosa now ON_TASK", val("SELECT availability FROM technicians WHERE tech_id='TECH-201'") == "ON_TASK")
check("DB: AOG-2026-014 RESOLVING; aircraft still AOG (only an inspector returns it to service)",
      val("SELECT status FROM aog_incidents WHERE aog_id='AOG-2026-014'") == "RESOLVING"
      and val("SELECT status FROM aircraft WHERE tail_number='N042NV'") == "AOG")
check("DB: TECH_DISPATCHED audit row", n("SELECT count(*) FROM agent_audit WHERE event_type='TECH_DISPATCHED' AND subject_id='NVA-DSP-000101'") == 1)
r = propose_dsp(teresa, "WO-2026-00101", "TECH-201")
check("DISPATCH: again -> ALREADY_ASSIGNED", blocked(r, "ALREADY_ASSIGNED"), r)
r = propose_dsp(teresa, "WO-2026-00102", "TECH-202")
dsp2 = r["proposal_id"]
check("DISPATCH: Caleb to the phase inspection (STRUCTURES + NV-450) -> PROPOSED", r["outcome"] == "PROPOSED", r)
psql("UPDATE technicians SET availability = 'OFF' WHERE tech_id = 'TECH-202'")
c = one("confirm_action", session_token=teresa, proposal_id=dsp2)
check("CONFIRM re-checks: Caleb went off shift -> BLOCKED TECH_UNAVAILABLE", c["outcome"] == "BLOCKED" and c["reason_code"] == "TECH_UNAVAILABLE", c)
psql("UPDATE technicians SET availability = 'AVAILABLE' WHERE tech_id = 'TECH-202'")

# ---------------------------------------------------------------- part spend above the limit -> maintenance-manager case
r = propose_part(teresa, "WO-2026-00101", "NV29-4471-P", "2", "EXPEDITE")
pump_pid = r["proposal_id"]
check("PART: 2 pumps EXPEDITE -> PROPOSED, $97,500.00, needs manager approval (summary says so)",
      r["outcome"] == "PROPOSED" and r["total_usd"] == "$97,500.00" and r["needs_manager_approval"] == "yes"
      and "maintenance manager" in r["summary"], r)
c = one("confirm_action", session_token=teresa, proposal_id=pump_pid)
pump_case = c["case_id"]
check("CONFIRM pumps -> MANAGER_APPROVAL with case NVA-CASE-000104, nothing ordered",
      c["outcome"] == "MANAGER_APPROVAL" and pump_case == "NVA-CASE-000104" and not c["reference"]
      and n("SELECT count(*) FROM part_orders WHERE part_number='NV29-4471-P'") == 0, c)
s = psql(f"SELECT * FROM service_cases WHERE case_id = {lit(pump_case)}")[0]
check("DB: case = spend_approval, OPEN, 2 units at $48,750, parked PART_ORDER:<proposal>, SLA 2 h",
      s["request_type"] == "spend_approval" and s["status"] == "OPEN" and s["requested_amount"] == "2"
      and s["unit_price"] == "48750.00" and s["parked_action"] == "PART_ORDER:" + pump_pid
      and n(f"SELECT count(*) FROM service_cases WHERE case_id = {lit(pump_case)} AND sla_due_at BETWEEN now() + interval '119 minutes' AND now() + interval '121 minutes'") == 1, s)
check("DB: CASE_OPENED audit row for the spend approval", n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_OPENED' AND subject_id={lit(pump_case)}") == 1)
r = propose_part(teresa, "WO-2026-00101", "NV29-4471-P", "1", "ROUTINE")
check("PART: pumps again while the case is open -> ALREADY_ORDERED (waiting for manager approval)",
      blocked(r, "ALREADY_ORDERED") and pump_case in r["reason_text"], r)
mc = {r["case_id"]: r for r in call("get_my_cases", session_token=teresa)}
check("get_my_cases: the pump case is OPEN with Maintenance Management, 2 units requested",
      mc[pump_case]["case_status"] == "OPEN" and mc[pump_case]["team"] == "Maintenance Management" and mc[pump_case]["requested_units"] == "2", mc)

# ---------------------------------------------------------------- human-owned cases
def open_case(tok, rtype, tail, summary="Controller request", brief=""):
    return one("open_service_case", session_token=tok, request_type=rtype, tail_number=tail, summary=summary, agent_brief=brief)


r = open_case(teresa, "spend_approval", "N042NV")
check("CASE: spend_approval cannot be opened by hand -> INVALID_TYPE", r["outcome"] == "INVALID_TYPE", r)
check("CASE: unknown type -> INVALID_TYPE", open_case(teresa, "fly it anyway", "N042NV")["outcome"] == "INVALID_TYPE")
r = open_case(teresa, "return_to_service", "N078NV")
check("CASE: tail at another base -> BLOCKED NOT_FOUND", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_FOUND", r)
BRIEF = "REPEAT: third No.2 hydraulic system leak/low-pressure event on this tail in 30 days (WO-2026-00091, WO-2026-00096)."
r = open_case(teresa, "reliability review", "N042NV", "Repeat hydraulic defect on N042NV", BRIEF)
rel_case = r["case_id"]
check("CASE: reliability_review (normalised) -> OPENED with Quality & Airworthiness, 24 h",
      r["outcome"] == "OPENED" and r["team"] == "Quality & Airworthiness" and "24 hours" in r["sla_text"], r)
check("DB: the agent brief is stored on the case", val(f"SELECT agent_brief FROM service_cases WHERE case_id = {lit(rel_case)}") == BRIEF)
r = open_case(teresa, "return_to_service", "N042NV", "Seal kit fitted and leak check done; please sign off N042NV for return to service.")
rts_case = r["case_id"]
check("CASE: return_to_service -> OPENED, parked RTS:N042NV",
      r["outcome"] == "OPENED" and val(f"SELECT parked_action FROM service_cases WHERE case_id = {lit(rts_case)}") == "RTS:N042NV", r)
r = open_case(teresa, "return_to_service", "N042NV")
check("CASE: the same again -> EXISTING (no duplicate)", r["outcome"] == "EXISTING" and r["case_id"] == rts_case, r)
r = open_case(teresa, "mel_deferral", "N021NV")
check("CASE: MEL deferral for N021NV -> EXISTING (seeded NVA-CASE-000103)", r["outcome"] == "EXISTING" and r["case_id"] == "NVA-CASE-000103", r)

# ---------------------------------------------------------------- the reviewer loop
v = one("verify_reviewer", staff_id="NVA-7101", code="9999")
check("reviewer wrong code -> VERIFY_FAILED", v["outcome"] == "VERIFY_FAILED" and not v["session_token"], v)
v = one("verify_reviewer", staff_id="2101", code="3852")
check("a controller's id + code cannot verify as a reviewer", v["outcome"] == "VERIFY_FAILED", v)
v = one("verify_reviewer", staff_id="7101", code="4417")
gloria = v["session_token"]
check("Gloria verifies -> REVIEWER, Maintenance Management", v["outcome"] == "VERIFIED" and v["team"] == "Maintenance Management", v)
victor = one("verify_reviewer", staff_id="NVA-7102", code="5823")["session_token"]
ingrid = one("verify_reviewer", staff_id="NVA-8101", code="6390")["session_token"]
check("Victor and Ingrid verify", bool(victor and ingrid))
check("a controller token on a reviewer tool -> NOT_REVIEWER", one("get_review_queue", session_token=teresa)["status"] == "NOT_REVIEWER")
check("a reviewer token on a controller tool -> SESSION_INVALID", one("get_base_fleet", session_token=gloria)["status"] == "SESSION_INVALID")
q = call("get_review_queue", session_token=gloria)
check("Gloria's queue = the two spend approvals (Kenji's actuator due first, then the pumps), with spend",
      [r["case_id"] for r in q] == ["NVA-CASE-000101", pump_case]
      and next(r for r in q if r["case_id"] == pump_case)["requested_spend_usd"] == "$97,500.00", q)
qi = call("get_review_queue", session_token=ingrid)
check("Ingrid's queue = Quality & Airworthiness cases only (MEL, AD, reliability, return to service)",
      {r["case_id"] for r in qi} == {"NVA-CASE-000102", "NVA-CASE-000103", rel_case, rts_case}, qi)
rc = one("get_review_case", session_token=gloria, case_id=pump_case.lower())
check("Gloria opens the pump case: statement, $97,500, max 2 units, authority $100,000, facts with the AOG",
      rc["status"] == "OK" and rc["requested_spend_usd"] == "$97,500.00" and rc["max_approvable_units"] == "2"
      and rc["your_spend_authority_usd"] == "$100,000.00" and "AOG-2026-014" in rc["facts"] and "NV29-4471-P" in rc["facts"], rc)
check("CROSS-TEAM: Gloria cannot open a Quality case -> NOT_FOUND", one("get_review_case", session_token=gloria, case_id=rts_case)["status"] == "NOT_FOUND")
rc = one("get_review_case", session_token=ingrid, case_id=rel_case)
check("Ingrid sees the reliability case with the AI brief marked unverified and the SQL repeat threshold",
      rc["agent_brief"].startswith("AI-prepared, not verified:") and "repeat-defect threshold met" in rc["facts"], rc)


def decide(tok, case, dec, amt="", note="Reviewed against the AOG plan", msg="Decision recorded."):
    return one("decide_review_case", session_token=tok, case_id=case, decision=dec, amount=amt, internal_note=note, customer_message=msg)


r = decide(teresa, pump_case, "APPROVE")
check("DECIDE: a controller token -> NOT_REVIEWER, nothing changes",
      r["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, r)
r = decide(gloria, "NVA-CASE-999999", "APPROVE")
check("DECIDE: unknown case -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = decide(gloria, rts_case, "APPROVE")
check("DECIDE: Gloria on a Quality case -> NOT_YOUR_TEAM", r["reason_code"] == "NOT_YOUR_TEAM", r)
r = decide(gloria, pump_case, "maybe")
check("DECIDE: 'maybe' -> INVALID_DECISION", r["reason_code"] == "INVALID_DECISION", r)
r = decide(gloria, pump_case, "APPROVE", note="ok")
check("DECIDE: a 2-character note -> NOTE_REQUIRED", r["reason_code"] == "NOTE_REQUIRED", r)
r = decide(gloria, pump_case, "APPROVE", amt="3")
check("DECIDE: 3 units (more than asked) -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(gloria, pump_case, "APPROVE", amt="-1")
check("DECIDE: -1 units -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(victor, pump_case, "APPROVE", amt="2")
check("DECIDE: Victor 2 pumps ($97,500 > his $50,000) -> OVER_AUTHORITY, case stays OPEN",
      r["reason_code"] == "OVER_AUTHORITY" and r["case_status"] == "OPEN" and "$50,000.00" in r["reason_text"]
      and val(f"SELECT status FROM service_cases WHERE case_id = {lit(pump_case)}") == "OPEN", r)
check("DECIDE blocks wrote no decision and no order",
      n("SELECT count(*) FROM review_decisions") == 0 and n("SELECT count(*) FROM part_orders WHERE part_number='NV29-4471-P'") == 0)
NOTE = "AOG recovery: approve both pumps, the second restores the reorder level"
MSG = "Approved: both No.2 hydraulic pumps are on expedite for N042NV."
r = decide(gloria, pump_case, "approve", amt="2 pumps", note=NOTE, msg=MSG)
check("DECIDE: Gloria approves 2 pumps -> APPROVED, executed: ordered", r["outcome"] == "APPROVED" and r["approved_units"] == "2"
      and r["executed_action"].startswith("Ordered: PO-2026-") and "$97,500.00" in r["executed_action"], r)
o = psql("SELECT * FROM part_orders WHERE part_number = 'NV29-4471-P'")
check("DB: pump order = 2 units, $97,500, EXPEDITE (delivery in 5 days), ordered by Teresa, approved by Gloria, case set",
      len(o) == 1 and o[0]["quantity"] == "2" and o[0]["total_usd"] == "97500.00" and o[0]["approved_by"] == "NVA-7101"
      and o[0]["ordered_by"] == "NVA-2101" and o[0]["case_id"] == pump_case and o[0]["expected_delivery"] == val("SELECT current_date + 5"), o)
d = psql(f"SELECT * FROM review_decisions WHERE case_id = {lit(pump_case)}")
check("DB: decision row (APPROVE, 2, note, message)", len(d) == 1 and d[0]["decision"] == "APPROVE" and d[0]["approved_amount"] == "2"
      and d[0]["internal_note"] == NOTE, d)
check("DB: CASE_DECIDED audit row", n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id={lit(pump_case)} AND actor='NVA-7101'") == 1)
r = decide(gloria, pump_case, "REJECT")
check("DECIDE twice -> ALREADY_DECIDED", r["reason_code"] == "ALREADY_DECIDED", r)
mc = {r["case_id"]: r for r in call("get_my_cases", session_token=teresa)}
check("Teresa sees APPROVED + the manager's message, 2 units approved (never the note or who decided)",
      mc[pump_case]["case_status"] == "APPROVED" and mc[pump_case]["customer_message"] == MSG and mc[pump_case]["approved_units"] == "2", mc[pump_case])
po = call("get_part_orders", session_token=teresa)
check("Teresa's part orders show the pump order as manager-approved", any(r["part_number"] == "NV29-4471-P" and pump_case in r["manager_approved"] for r in po), po)

# amended quantity: Victor approves Kenji's actuator? ($63,400 > $50,000 -> OVER_AUTHORITY), Gloria amends nothing - reject path
r = decide(victor, "NVA-CASE-000101", "APPROVE")
check("DECIDE: Victor approves the $63,400 actuator (empty amount = all) -> OVER_AUTHORITY", r["reason_code"] == "OVER_AUTHORITY", r)
r = decide(gloria, "NVA-CASE-000101", "REJECT", note="Hold: an exchange unit is cheaper", msg="Not approved yet - we are sourcing an exchange actuator.")
check("DECIDE: Gloria rejects the actuator -> REJECTED, nothing executed",
      r["outcome"] == "REJECTED" and r["executed_action"] == "Case rejected; nothing was executed."
      and n("SELECT count(*) FROM part_orders WHERE part_number='NV32-8830-A'") == 0, r)

# amended quantity on a fresh spend case: Kenji orders 2 display units ($44,200 > $25,000), Victor approves 1 ($22,100)
r = propose_part(kenji, "WO-2026-00201", "NV31-2210-D", "2", "ROUTINE")
check("PART: Kenji's 2 display units for N078NV -> PROPOSED, needs approval ($44,200)",
      r["outcome"] == "PROPOSED" and r["needs_manager_approval"] == "yes", r)
c = one("confirm_action", session_token=kenji, proposal_id=r["proposal_id"])
disp_case = c["case_id"]
r = decide(victor, disp_case, "APPROVE", amt="1", note="One unit now, the spare later", msg="Approved for 1 unit.")
check("DECIDE: Victor approves an amended 1 unit ($22,100) -> APPROVED, ordered 1",
      r["outcome"] == "APPROVED" and r["approved_units"] == "1"
      and val(f"SELECT quantity FROM part_orders WHERE case_id = {lit(disp_case)}") == "1", r)

# return to service: blocked while an AOG is OPEN, executes once RESOLVING
psql("UPDATE aog_incidents SET status = 'OPEN' WHERE aog_id = 'AOG-2026-014'")
r = decide(ingrid, rts_case, "APPROVE", note="Leak check witnessed, paperwork complete")
check("DECIDE: return to service while AOG-2026-014 is OPEN -> NOT_READY, case stays OPEN",
      r["reason_code"] == "NOT_READY" and val(f"SELECT status FROM service_cases WHERE case_id = {lit(rts_case)}") == "OPEN", r)
psql("UPDATE aog_incidents SET status = 'RESOLVING' WHERE aog_id = 'AOG-2026-014'")
r = decide(ingrid, rts_case, "APPROVE", note="Leak check witnessed, paperwork complete", msg="N042NV is signed off and back in service.")
check("DECIDE: Ingrid approves return to service -> APPROVED, executed: return to service recorded",
      r["outcome"] == "APPROVED" and r["executed_action"].startswith("Return to service recorded (NVA-RTS-000101)"), r)
check("DB: N042NV IN_SERVICE, AOG-2026-014 RESOLVED, WO-2026-00101 CLOSED, Rosa AVAILABLE again",
      val("SELECT status FROM aircraft WHERE tail_number='N042NV'") == "IN_SERVICE"
      and val("SELECT status FROM aog_incidents WHERE aog_id='AOG-2026-014'") == "RESOLVED"
      and val("SELECT status FROM work_orders WHERE wo_number='WO-2026-00101'") == "CLOSED"
      and val("SELECT availability FROM technicians WHERE tech_id='TECH-201'") == "AVAILABLE")
check("DB: RETURNED_TO_SERVICE + CASE_DECIDED audit rows",
      n("SELECT count(*) FROM agent_audit WHERE event_type='RETURNED_TO_SERVICE' AND subject_id='NVA-RTS-000101'") == 1
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id={lit(rts_case)}") == 1)
r = decide(ingrid, "NVA-CASE-000103", "REJECT", note="Light is required for this cabin layout", msg="MEL deferral not approved; fix before next flight.")
check("DECIDE: Ingrid rejects the MEL deferral -> REJECTED, nothing executed", r["outcome"] == "REJECTED", r)
r = decide(ingrid, rel_case, "APPROVE", note="Open a reliability investigation on the No.2 system")
check("DECIDE: reliability review approved -> no automatic action", r["outcome"] == "APPROVED" and "no automatic action" in r["executed_action"], r)

# ---------------------------------------------------------------- email (guarded)
e = one("email_ops_summary", session_token=teresa, tail_number="N042NV")
check("email N042NV -> SEND_OK, lists the seal kit + pump orders, Rosa's dispatch and the cases; never the internal note",
      e["send_status"] == "SEND_OK" and "PO-2026-0101" in e["body"] and "NV29-4471-P" in e["body"] and "NVA-DSP-000101" in e["body"]
      and pump_case in e["body"] and NOTE not in e["body"] and "AI assistant" in e["body"], e)
e = one("email_ops_summary", session_token=teresa, tail_number="N063NV")
check("nothing done on N063NV -> NOT_SENT NOTHING_TO_SEND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOTHING_TO_SEND", e)
e = one("email_ops_summary", session_token=teresa, tail_number="N078NV")
check("SCOPE: Teresa emails a Harbor Point tail -> NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
check("exactly 1 email logged", n("SELECT count(*) FROM email_log") == 1)

# ---------------------------------------------------------------- session expiry
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(teresa)}")
check("expired controller token -> SESSION_INVALID", one("get_base_fleet", session_token=teresa)["status"] == "SESSION_INVALID")
check("expired token cannot propose", propose_part(teresa, "WO-2026-00102", "NV29-1180-F", "1", "ROUTINE")["outcome"] == "SESSION_INVALID")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(ingrid)}")
check("expired reviewer token -> NOT_REVIEWER", one("get_review_queue", session_token=ingrid)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- hidden data never leaves the DB
co_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
leaked = sorted({k for _, rows in co_out for row in rows for k in row} & HIDDEN_COLUMNS)
check("no controller tool output has a hidden column", not leaked, leaked)
cblob = "\n".join(str(v) for _, rows in co_out for row in rows for v in row.values())
secrets = [x["v"] for x in psql("SELECT email v FROM technicians UNION ALL SELECT phone FROM technicians "
                                "UNION ALL SELECT internal_note FROM review_decisions UNION ALL SELECT display_name FROM reviewers "
                                "UNION ALL SELECT one_time_code FROM controllers UNION ALL SELECT one_time_code FROM reviewers "
                                "UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL")]
check("controller outputs never contain technician contacts, internal notes, reviewer names, codes or agent briefs",
      not any(s and s in cblob for s in secrets), [s for s in secrets if s and s in cblob][:3])
rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
rblob = "\n".join(str(v) for _, rows in rev_out for row in rows for v in row.values())
check("reviewer outputs: no technician contact details or codes",
      not rleak and not re.search(r"@|\(555\) 010-2|\(555\) 010-3", rblob), rleak)
texts = [str(row.get(k) or "") for _, rows in co_out for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the model|LLM|the assistant|the user)\b", t, re.I)]
check("controller-facing texts address the controller (never the model)", not bad, bad[:3])
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT staff_id v FROM controllers UNION SELECT display_name FROM controllers UNION SELECT one_time_code FROM controllers "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT tech_id FROM technicians UNION SELECT name FROM technicians UNION SELECT email FROM technicians "
    "UNION SELECT phone FROM technicians UNION SELECT ops_phone FROM bases UNION SELECT case_id FROM service_cases "
    "UNION SELECT session_token FROM sessions UNION SELECT tail_number FROM aircraft UNION SELECT wo_number FROM work_orders "
    "UNION SELECT order_id FROM part_orders UNION SELECT aog_id FROM aog_incidents UNION SELECT part_number FROM parts "
    "UNION SELECT unnest(string_to_array(display_name, ' ')) FROM controllers "
    "UNION SELECT unnest(string_to_array(display_name, ' ')) FROM reviewers "
    "UNION SELECT unnest(string_to_array(name, ' ')) FROM technicians")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity / equipment value list for the leak scan is non-trivial", len(ID_VALUES) > 60, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_ata_chapter_guide": ("hydraulic", "ATA 29 - Hydraulic power", "shorthand", 10),
    "get_repeat_defect_guide": ("pirep", "PIREP", "different system", 3),
    "get_handover_format_guide": ("awaiting", "AWAITING_PARTS", "standard line", 5),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["fault_triage_agent", "repeat_defect_agent", "shift_handover_agent"])
for t in AGENT_REF_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)})", len(full) >= 10, len(full))
    check(f"{tool}: returns only the reference columns {REF_COLUMNS}", bool(full) and list(full[0]) == REF_COLUMNS,
          list(full[0]) if full else None)
    check(f"{tool}: every section is present", {r["section"] for r in full} == set(t["sections"]),
          sorted({r["section"] for r in full} ^ set(t["sections"])))
    check(f"{tool}: rows come back in section order", [r["section"] for r in full]
          == sorted((r["section"] for r in full), key=t["sections"].index))
    check(f"{tool}: whitespace / separators only = whole guide", len(ref_call(t, " , ")) == len(full))
    check(f"{tool}: NULL term = whole guide (SQL NULL)", n(f"SELECT count(*) FROM {fn}(NULL)") == len(full))
    word, expect, sec_word, sec_n = LOOKUPS[tool]
    hit = ref_call(t, word)
    check(f"{tool}: lookup '{word}' narrows the guide and finds '{expect}'",
          0 < len(hit) < len(full) and any(r["term"] == expect for r in hit)
          and all(word in f"{r['term']} {r['meaning']}".lower() for r in hit), [r["term"] for r in hit])
    check(f"{tool}: lookup is case-insensitive", len(ref_call(t, word.upper())) == len(hit))
    sec = ref_call(t, sec_word)
    check(f"{tool}: section lookup '{sec_word}' returns that section ({sec_n} rows)",
          len(sec) == sec_n and {r["section"] for r in sec} == {sec_word.upper().replace(" ", "_")}, [r["term"] for r in sec])
    check(f"{tool}: unknown term -> 0 rows, no error", ref_call(t, "zzqx-unknown-term") == [])
    check(f"{tool}: the guide holds no literal '%' and '%' / '_' are literal (no wildcard expansion)",
          "%" not in ref_blob(full) and ref_call(t, "%") == [] and ref_call(t, "_%_") == [])
    check(f"{tool}: SQL-looking input is just a string -> 0 rows",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no staff / reviewer / technician / case / session / tail / work-order / order / part-number value in the rows",
          not leaked, leaked[:5])
    check(f"{tool}: no staff, case, technician, tail, work-order, order, part-number, email, phone or token pattern",
          not re.search(r"nva-\d|nva-case|nva-prp|nva-dsp|tech-\d|n0\d\dnv|wo-20|po-20|aog-20|nv\d\d-\d|@|555|"
                        r"[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])
    check(f"{tool}: guide stays compact (<= 40 rows, agents usually read it whole)", len(full) <= 40, len(full))

REFT = {t["agent"]: t for t in AGENT_REF_TOOLS}
both = ref_call(REFT["repeat_defect_agent"], "nff, pirep")
check("ref_repeat_defect_criteria: several words in one call ('nff, pirep') -> both found",
      {"NFF", "PIREP"} <= {r["term"] for r in both}, [r["term"] for r in both])


def check_values(table, col):
    """Values allowed by the CHECK constraint on table.col (the one whose definition starts with that column)."""
    defs = [r["d"] for r in psql(f"SELECT pg_get_constraintdef(c.oid) AS d FROM pg_constraint c "
                                 f"WHERE c.conrelid = '{table}'::regclass AND c.contype = 'c'")]
    d = next((x for x in defs if re.match(r"CHECK \(+" + col + r"\b", x)), "")
    return set(re.findall(r"'([^']+)'::", d))


# --- fault_triage_agent: ATA chapter guide
ata = [r for r in ref_call(REFT["fault_triage_agent"], "") if r["section"] == "ATA_CHAPTER"]
chap = {re.match(r"ATA (\d\d) - ", r["term"]).group(1): r for r in ata if re.match(r"ATA (\d\d) - ", r["term"])}
check("ref_ata_chapters: every ATA_CHAPTER term is 'ATA nn - <name>'", len(chap) == len(ata), [r["term"] for r in ata])
used = {r["c"] for r in psql("SELECT ata_chapter c FROM work_orders UNION SELECT ata_chapter FROM parts")}
check("ref_ata_chapters: every ATA chapter a work order or part uses has a chapter row", used <= set(chap), used - set(chap))
def cert_of(meaning):
    m = re.search(r"Certification: ([A-Z ]+)\.", meaning)
    return m.group(1) if m else None
cert = {k: cert_of(r["meaning"]) for k, r in chap.items()}
OLD_MAP = {"05": "STRUCTURES", "21": "AVIONICS", "24": "ELECTRICAL", "27": "STRUCTURES", "28": "POWERPLANT",
           "29": "HYDRAULICS", "31": "AVIONICS", "32": "LANDING GEAR", "33": "ELECTRICAL", "34": "AVIONICS",
           "49": "POWERPLANT", "57": "STRUCTURES", "65": "ROTOR SYSTEMS", "73": "POWERPLANT"}
check("ref_ata_chapters: chapter -> certification map is exactly the old guide's map", cert == OLD_MAP,
      {k: (cert.get(k), OLD_MAP.get(k)) for k in set(cert) | set(OLD_MAP) if cert.get(k) != OLD_MAP.get(k)})
certs = {r["c"] for r in psql("SELECT required_cert c FROM work_orders UNION SELECT unnest(certifications) FROM technicians")}
check("ref_ata_chapters: the certifications named are exactly the ones work orders and technicians use",
      set(cert.values()) == certs, set(cert.values()) ^ certs)
check("ref_ata_chapters: every chapter row carries Northvale's standard triage note",
      all(re.search(r"Triage note: [A-Z].{20,}\.$", r["meaning"]) for r in ata),
      [r["term"] for r in ata if not re.search(r"Triage note: [A-Z].{20,}\.$", r["meaning"])])
fam = [r for r in ref_call(REFT["fault_triage_agent"], "part family")]
parts = psql("SELECT ata_chapter, description, type_code FROM parts")
check("ref_ata_chapters: PART_FAMILY rows come from parts (one row per catalogue chapter, every part listed with its type)",
      {r["term"] for r in fam} == {f"ATA {p['ata_chapter']} catalogue parts" for p in parts}
      and all(f"{p['description']} ({p['type_code']})" in next(r["meaning"] for r in fam
              if r["term"] == f"ATA {p['ata_chapter']} catalogue parts") for p in parts), [r["term"] for r in fam])

# --- repeat_defect_agent: criteria
rg = ref_call(REFT["repeat_defect_agent"], "")
flags = {r["term"]: r["meaning"] for r in rg if r["section"] == "FLAG"}
check("ref_repeat_defect_criteria: the three flags, each with its standard reliability note",
      set(flags) == {"REPEAT", "POSSIBLE_REPEAT", "NO_REPEAT"} and all("Standard note: " in m for m in flags.values()), flags)
route = {r["request_type"]: r for r in psql("SELECT request_type, label, team, sla_text FROM case_routing")}
who = [r for r in rg if r["section"] == "WHO_DECIDES"]
check("ref_repeat_defect_criteria: WHO_DECIDES row comes from case_routing reliability_review (one source of truth)",
      [(r["term"], r["meaning"]) for r in who]
      == [(route["reliability_review"]["label"], f"{route['reliability_review']['team']}: {route['reliability_review']['sla_text']}")], who)
check("the 30-day same-chapter count stays computed in SQL (tail_history returns same_ata_last_30_days)",
      "same_ata_last_30_days" in val("SELECT pg_get_function_result('tail_history(text,text)'::regprocedure)")
      and any("same_ata_last_30_days" in r["meaning"] for r in rg if r["section"] == "WINDOW"))

# --- shift_handover_agent: guide
hg = ref_call(REFT["shift_handover_agent"], "")
secs = [r["term"] for r in hg if r["section"] == "SECTION"]
check("ref_handover_guide: 5 handover sections in order",
      secs == ["1 AOG", "2 Open work", "3 Parts on order", "4 Waiting on people / decisions", "5 Watch items"], secs)
codes = set()
for tb in ("aog_incidents", "work_orders", "part_orders", "service_cases"):
    codes |= check_values(tb, "status")
stat = {r["term"] for r in hg if r["section"] == "STATUS"}
check("ref_handover_guide: every status code the handover snapshot can carry is explained in plain words",
      len(codes) == 11 and stat == codes, (sorted(codes), sorted(stat ^ codes)))
check("ref_handover_guide: the standard closing line is in the guide",
      any(r["term"] == "closing line" and "statuses as recorded" in r["meaning"] for r in hg))

# nothing from the old static reference text was lost
KEEP = {"get_ata_chapter_guide": ["time limits / maintenance checks", "inspections", "air conditioning and pressurization",
                                  "electrical power", "flight controls", "- fuel", "hydraulic power",
                                  "pumps, reservoirs, pressure and return lines, fittings, accumulators",
                                  "indicating and recording systems", "displays", "landing gear", "actuators, brakes, wheels",
                                  "lights", "navigation", "auxiliary power unit", "wings", "tail rotor and main rotor",
                                  "engine fuel and control", "hyd|hydraulic", "the no.2 hydraulic system",
                                  "low pressure caution", "pressure fluctuating", "case drain line", "pump seals",
                                  "or at the pump itself if pressure is also fluctuating", "slow leak", "a tube fitting nut",
                                  "main landing gear", "inoperative", "circuit breaker",
                                  "holds the certification and a type rating for that aircraft type",
                                  "the maintenance system checks both"],
        "get_repeat_defect_guide": ["the same system failing in the same way again on the same aircraft",
                                    "the same ata chapter and the same subsystem", "no.2 hydraulic system",
                                    "even when the words differ", "'fluid pooled under the gear well'",
                                    "'hyd 2 lo press caution'", "'pressure fluctuation with leak at the pump case drain'",
                                    "brake wear check (ata 32) is not a hydraulic leak",
                                    "even though brakes use hydraulic fluid", "a light or display fault is never a hydraulic event",
                                    "30 days before the new write-up", "2 or more earlier events",
                                    "the new write-up makes 3 or more", "reliability review recommended",
                                    "1 earlier event", "similar events 31-90 days ago", "nothing similar",
                                    "goes to quality & airworthiness, who decide", "never say the aircraft is safe or unsafe"],
        "get_handover_format_guide": ["most hours on ground first", "what is being done and what it is waiting for",
                                      "by priority", "aog (aircraft on ground), then urgent", "then routine",
                                      "which are unassigned and which wait for parts", "parts on order with eta",
                                      "flagging anything expedited", "team and reply-due time",
                                      "decisions made in the last 24 hours", "at most 3 things the next shift must chase",
                                      "(aog-..., wo-..., po-...)", "a case is named by its request type, e.g. mel deferral",
                                      "no people's names", "each line one sentence", "at most 20 lines in total",
                                      "never state that an aircraft is airworthy or released",
                                      "only report statuses as given"]}
for t in AGENT_REF_TOOLS:
    blob = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if not any(x in blob for x in k.split("|"))]
    check(f"{t['tool']}: every fact from the old static reference text is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, p.pronargs, "
           "pg_get_function_identity_arguments(p.oid) AS args, p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang "
           "JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname LIKE 'ref\\_%'")
names = {f["proname"] for f in fns}
check("ref_* functions exist: ref_match + one per agent", names == {"ref_match"} | {t["fn"] for t in AGENT_REF_TOOLS}, names)
for f in fns:
    check(f"{f['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          f["lanname"] == "sql" and f["provolatile"] in ("s", "i") and f["prosecdef"] == "f"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", f["prosrc"], re.I),
          {k: f[k] for k in ("lanname", "provolatile", "prosecdef")})
    if f["proname"] != "ref_match":
        check(f"{f['proname']}: one optional, non-identity argument (p_term text)", f["args"] == "p_term text", f["args"])
check("reset_data.sql truncates and reloads the reference tables",
      all(x in open(os.path.join(DIR, "reset_data.sql"), encoding="utf-8").read() for x in (t["table"] for t in AGENT_REF_TOOLS)))

reset()
total = passes + fails
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} checks, DB reset)")
sys.exit(1 if fails else 0)
