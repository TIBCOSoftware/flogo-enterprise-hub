#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the hospital_governed DB and assert the
business rules on DB state - coordinator scope, the two-step follow-up booking, medicine orders (incl. high-alert
parking), bed turnover, cases, the full reviewer loop, and the A2A agents' read-only reference tools (ref_* functions:
filtering, unknown input, no personal data, SELECT-only). No Flogo needed. Re-loads reset_data.sql first and again at
the end (re-runnable).

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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "hospital_governed"),
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
check("18 MCP tools", len(TOOLS) == 18, [t["tool"] for t in TOOLS])
check("every write is INSERT ... SELECT (never VALUES)",
      all(re.match(r"INSERT INTO \w+ \([^)]*\) SELECT ", t["write"][0]) and "VALUES" not in t["write"][0].upper()
          for t in TOOLS if "write" in t))
check("write placeholders ?w_*, read placeholders never ?w_*",
      all(all(p.startswith("w_") for p, _ in t["write"][1]) for t in TOOLS if "write" in t)
      and all(not p.startswith("w_") for t in TOOLS for p, _ in t["read"][1]))
check("no ?p:: casts anywhere", not any(re.search(r"\?\w+::", t.get("write", ("",))[0] + t["read"][0]) for t in TOOLS))
check("reads are readonly, writes are not", all(t["readonly"] == ("write" not in t) for t in TOOLS))
check("tool names are unique and flows end in _flow", len({t["tool"] for t in TOOLS}) == 18
      and all(t["flow"] == t["tool"] + "_flow" for t in TOOLS))

# ---------------------------------------------------------------- coordinator identity + throttle
r = one("verify_coordinator", staff_id="BMC-4101", code="0000")
check("wrong code -> VERIFY_FAILED, no token, no hint", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "match" in r["reason_text"], r)
check("wrong code issues no session", n("SELECT count(*) FROM sessions") == 0)
r = one("verify_coordinator", staff_id="BMC-9999", code="4826")
check("unknown staff id -> VERIFY_FAILED (same text)", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_coordinator", staff_id="BMC-3201", code="4826")
check("Rachel's code with Daniel's id -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
r = one("verify_coordinator", staff_id="BMC-7701", code="3141")
check("a reviewer's credentials on verify_coordinator -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
toks = []
for fmt in ("BMC-4101", "bmc4101", "BMC 4101", "4101"):
    r = one("verify_coordinator", staff_id=fmt, code="4826")
    check(f"staff id format '{fmt}' -> VERIFIED + token, ward 4A", r["outcome"] == "VERIFIED" and r["session_token"]
          and r["role"] == "COORDINATOR" and r["display_name"] == "Rachel Moore" and "4A" in r["ward"], r)
    toks.append(r["session_token"])
rachel = toks[-1]
daniel = one("verify_coordinator", staff_id="BMC-3201", code="7391")["session_token"]
check("Daniel verifies (ward 3B)", bool(daniel))
for i in range(5):
    one("verify_coordinator", staff_id="BMC-3201", code="1111")
r = one("verify_coordinator", staff_id="BMC-3201", code="7391")
check("THROTTLE: 5 wrong codes -> LOCKED even with the right code, no new session",
      r["outcome"] == "LOCKED" and not r["session_token"]
      and n("SELECT count(*) FROM sessions WHERE coordinator_id='BMC-3201'") == 1 and "15 minutes" in r["reason_text"], r)

# ---------------------------------------------------------------- reviewer identity + role separation
r = one("verify_reviewer", staff_id="BMC-7701", code="0000")
check("reviewer wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_reviewer", staff_id="BMC-4101", code="4826")
check("coordinator credentials on verify_reviewer -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
r = one("verify_reviewer", staff_id="bmc 7701", code="3141")
check("Priya verifies as REVIEWER, team Pharmacy", r["outcome"] == "VERIFIED" and r["role"] == "REVIEWER"
      and r["team"] == "Pharmacy" and r["display_name"] == "Priya Raman, PharmD", r)
priya = r["session_token"]
owen = one("verify_reviewer", staff_id="7702", code="2718")["session_token"]
r = one("verify_reviewer", staff_id="BMC-5501", code="1618")
maya = r["session_token"]
check("Maya verifies, team Nursing Operations", r["team"] == "Nursing Operations", r)
r = one("verify_reviewer", staff_id="BMC-6601", code="5772")
elena = r["session_token"]
check("Dr. Torres verifies, team Hospitalist Service", r["team"] == "Hospitalist Service", r)
check("reviewer token on a coordinator tool -> SESSION_INVALID", one("get_ward_discharges", session_token=priya)["status"] == "SESSION_INVALID")
check("coordinator token on a reviewer tool -> NOT_REVIEWER", one("get_review_queue", session_token=rachel)["status"] == "NOT_REVIEWER")
BAD = "bogus-token-0000"
for t in TOOLS:
    if t["tool"] in ("verify_coordinator", "verify_reviewer") or t["tool"] in REVIEWER_TOOLS:
        continue
    sample = dict(session_token=BAD, patient_id="MRN-4012", slot_id="SLOT-C105", proposal_id="BMC-PRP-00000000",
                  medication="ALL", bed_id="4A-10", request_type="clinical_question", summary="x")
    rows = call(t["tool"], **{a: v for a, v in sample.items() if a in dict(t["args"])})
    first = rows[0] if rows else {}
    st = first.get("status") or first.get("outcome") or first.get("send_status")
    check(f"forged token on {t['tool']} -> SESSION_INVALID (nothing written)",
          st in ("SESSION_INVALID", "NOT_SENT") and (first.get("reason_code") in (None, "", "SESSION_INVALID")), first)
check("forged tokens wrote nothing", n("SELECT (SELECT count(*) FROM pending_actions) + (SELECT count(*) FROM med_order_attempts) "
                                       "+ (SELECT count(*) FROM bed_attempts) + (SELECT count(*) FROM case_requests) "
                                       "+ (SELECT count(*) FROM email_log)") == 0)

# ---------------------------------------------------------------- scoped reads
wd = call("get_ward_discharges", session_token=rachel)
check("Rachel's ward list: 5 patients, all Ward 4A", len(wd) == 5 and all(x["ward"].startswith("Ward 4A") for x in wd)
      and {x["patient_id"] for x in wd} == {"MRN-4012", "MRN-4015", "MRN-4018", "MRN-4021", "MRN-4009"}, wd)
john = next(x for x in wd if x["patient_id"] == "MRN-4012")
check("John: DISCHARGED, Cardiology 7-14 days, 3 medicines, 0 ordered, bed OCCUPIED", john["discharge_status"] == "DISCHARGED"
      and john["follow_up"] == "Cardiology within 7-14 days" and john["meds_on_list"] == "3" and john["meds_ordered"] == "0"
      and john["bed_status"] == "OCCUPIED", john)
check("Daniel's ward list: 3 patients on 3B", len(call("get_ward_discharges", session_token=daniel)) == 3)
ds = call("get_discharge_summary", session_token=rachel, patient_id="4012")
check("John's summary: 3 medicine rows (aspirin, metoprolol, atorvastatin), instructions as prescribed, NOT ORDERED",
      len(ds) == 3 and [x["medication_code"] for x in ds] == ["MED-101", "MED-102", "MED-103"]
      and ds[0]["instructions"] == "1 tablet by mouth once daily" and all(x["order_status"] == "NOT ORDERED" for x in ds)
      and ds[0]["follow_up_specialty"] == "Cardiology" and ds[0]["follow_up_window"].startswith("between "), ds)
ms = call("get_discharge_summary", session_token=rachel, patient_id="MRN-4015")
check("Margaret's warfarin is flagged high_alert", any(x["medication_code"] == "MED-105" and x["high_alert"] == "yes" for x in ms), ms)
check("SCOPE: Rachel cannot read Thomas (ward 3B) -> NOT_FOUND",
      one("get_discharge_summary", session_token=rachel, patient_id="MRN-3204")["status"] == "NOT_FOUND")
ap = call("get_patient_appointments", session_token=rachel, patient_id="MRN-4012")
check("John's appointments: the echocardiogram", len(ap) == 1 and ap[0]["appointment_type"] == "Echocardiogram", ap)
check("SCOPE: appointments for another ward's patient -> NOT_FOUND",
      one("get_patient_appointments", session_token=rachel, patient_id="MRN-3207")["status"] == "NOT_FOUND")
check("Margaret has no appointments -> NONE", one("get_patient_appointments", session_token=rachel, patient_id="MRN-4015")["status"] == "NONE")
sl = call("get_followup_slots", session_token=rachel, patient_id="MRN-4012")
ids = [x["slot_id"] for x in sl]
check("John's eligible slots: open Cardiology slots inside the window only (C101-C107, not C108 outside / C109 booked)",
      ids == sorted(ids, key=lambda s: [x["slot_date"] + x["slot_time"] for x in sl if x["slot_id"] == s][0])
      and set(ids) == {"SLOT-C101", "SLOT-C102", "SLOT-C103", "SLOT-C104", "SLOT-C105", "SLOT-C106", "SLOT-C107"}
      and all(x["specialty"] == "Cardiology" and x["status"] == "OK" for x in sl), sl)
c105 = next(x for x in sl if x["slot_id"] == "SLOT-C105")
check("slot facts: part_of_day, wheelchair access and transport are SQL facts", c105["part_of_day"] == "afternoon"
      and c105["wheelchair_accessible"] == "yes" and c105["transport_available"] == "yes", c105)
for pid, code in (("MRN-4018", "ALREADY_BOOKED"), ("MRN-4009", "NO_FOLLOWUP_REQUIRED"), ("MRN-4021", "DISCHARGE_NOT_ORDERED"),
                  ("MRN-3204", "NOT_FOUND")):
    r = one("get_followup_slots", session_token=rachel, patient_id=pid)
    check(f"slot list for {pid} -> {code} with a reason", r["status"] == code and r["reason_text"] and not r["slot_id"], r)
po = call("get_pharmacy_orders", session_token=rachel, patient_id="MRN-4009")
check("William's antibiotic order RX-000011 (picked up)", len(po) == 1 and po[0]["order_id"] == "RX-000011"
      and po[0]["order_status"] == "PICKED_UP", po)
check("John has no orders yet -> NONE", one("get_pharmacy_orders", session_token=rachel, patient_id="MRN-4012")["status"] == "NONE")
beds = {x["bed_id"]: x for x in call("get_ward_beds", session_token=rachel)}
check("Rachel's beds: 7 beds on 4A; 4A-10 OCCUPIED by John (DISCHARGED)", len(beds) == 7 and all(b.startswith("4A-") for b in beds)
      and beds["4A-10"]["patient_name"] == "John Harper" and beds["4A-10"]["patient_discharge_status"] == "DISCHARGED", beds)

# ---------------------------------------------------------------- follow-up booking (two-step)
def prop(tok, pid, slot): return one("propose_followup", session_token=tok, patient_id=pid, slot_id=slot)
for pid, slot, code in (("MRN-4012", "SLOT-C108", "OUTSIDE_WINDOW"), ("MRN-4012", "SLOT-C109", "SLOT_TAKEN"),
                        ("MRN-4012", "SLOT-A301", "WRONG_SPECIALTY"), ("MRN-4012", "SLOT-Z999", "SLOT_NOT_FOUND"),
                        ("MRN-4009", "SLOT-C105", "NO_FOLLOWUP_REQUIRED"), ("MRN-4018", "SLOT-C106", "ALREADY_BOOKED"),
                        ("MRN-4021", "SLOT-G401", "DISCHARGE_NOT_ORDERED"), ("MRN-3204", "SLOT-O201", "NOT_FOUND")):
    r = prop(rachel, pid, slot)
    check(f"propose {pid} {slot} -> BLOCKED {code}", r["outcome"] == "BLOCKED" and r["reason_code"] == code
          and not r["proposal_id"] and r["reason_text"], r)
check("blocked proposals booked nothing", n("SELECT count(*) FROM appointment_events") == 0)
r = prop(rachel, "mrn 4012", "c105")
check("propose John SLOT-C105 -> PROPOSED with a summary (Cardiology, 13:30, transport yes)", r["outcome"] == "PROPOSED"
      and r["proposal_id"].startswith("BMC-PRP-") and "Cardiology" in r["summary"] and "13:30" in r["summary"]
      and "hospital transport: yes" in r["summary"] and "Reply yes" in r["reason_text"], r)
pid1 = r["proposal_id"]
r2 = prop(rachel, "MRN-4012", "SLOT-C105")
check("re-propose the same -> same proposal (idempotent)", r2["proposal_id"] == pid1
      and n("SELECT count(*) FROM pending_actions WHERE outcome='PROPOSED'") == 1, r2)
check("PROPOSED books nothing", n("SELECT count(*) FROM appointments WHERE source='CHAT'") == 0
      and val("SELECT status FROM clinic_slots WHERE slot_id='SLOT-C105'") == "OPEN")
r = one("confirm_action", session_token=daniel, proposal_id=pid1)
check("SCOPE: Daniel confirms Rachel's proposal -> NOT_FOUND", r["outcome"] == "NOT_FOUND", r)
r = one("confirm_action", session_token=rachel, proposal_id="BMC-PRP-DEADBEEF")
check("bogus proposal -> NOT_FOUND", r["outcome"] == "NOT_FOUND", r)
r = one("confirm_action", session_token=rachel, proposal_id=pid1.lower())
check("confirm -> EXECUTED with a BMC-APT reference", r["outcome"] == "EXECUTED" and r["reference"].startswith("BMC-APT-"), r)
apt_ref = r["reference"]
check("DB: follow-up appointment created (CHAT), slot BOOKED, FOLLOWUP_BOOKED audit",
      n(f"SELECT count(*) FROM appointments WHERE appointment_id='{apt_ref}' AND patient_id='MRN-4012' AND slot_id='SLOT-C105' "
        f"AND appt_type='Follow-up visit' AND source='CHAT'") == 1
      and val("SELECT status FROM clinic_slots WHERE slot_id='SLOT-C105'") == "BOOKED"
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='FOLLOWUP_BOOKED' AND subject_id='{apt_ref}' AND actor='BMC-4101'") == 1)
r = one("confirm_action", session_token=rachel, proposal_id=pid1)
check("confirm twice -> ALREADY_DONE, still one booking", r["outcome"] == "ALREADY_DONE"
      and n("SELECT count(*) FROM appointment_events") == 1, r)
r = prop(rachel, "MRN-4012", "SLOT-C106")
check("John now has a follow-up -> ALREADY_BOOKED", r["reason_code"] == "ALREADY_BOOKED", r)
check("slot list now says ALREADY_BOOKED", one("get_followup_slots", session_token=rachel, patient_id="MRN-4012")["status"] == "ALREADY_BOOKED")
r = prop(rachel, "MRN-4015", "SLOT-A301")
check("propose Margaret's anticoagulation visit -> PROPOSED", r["outcome"] == "PROPOSED", r)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE proposal_id = {lit(r['proposal_id'])}")
r = one("confirm_action", session_token=rachel, proposal_id=r["proposal_id"])
check("confirm after 15 minutes -> EXPIRED, nothing booked", r["outcome"] == "EXPIRED"
      and val("SELECT status FROM clinic_slots WHERE slot_id='SLOT-A301'") == "OPEN", r)
r = prop(rachel, "MRN-4015", "SLOT-A302")
psql("UPDATE clinic_slots SET status='BOOKED' WHERE slot_id='SLOT-A302'")       # someone else took it in the meantime
r = one("confirm_action", session_token=rachel, proposal_id=r["proposal_id"])
check("confirm re-checks: slot taken since the proposal -> BLOCKED SLOT_TAKEN", r["outcome"] == "BLOCKED"
      and r["reason_code"] == "SLOT_TAKEN" and n("SELECT count(*) FROM appointments WHERE patient_id='MRN-4015'") == 0, r)
psql("UPDATE clinic_slots SET status='OPEN' WHERE slot_id='SLOT-A302'")

# ---------------------------------------------------------------- discharge medicine orders
def order(tok, pid, med="ALL", brief=""):
    return call("order_discharge_meds", session_token=tok, patient_id=pid, medication=med, pharmacist_brief=brief)
o = order(rachel, "MRN-4012")
check("John ALL -> 3 ORDERED, outpatient pickup (he has left), ready_by set", len(o) == 3 and all(x["outcome"] == "ORDERED" for x in o)
      and all(x["pickup_location"] == "Bellmont Outpatient Pharmacy, Main Lobby" and x["ready_by"] and x["order_id"].startswith("RX-") for x in o), o)
check("DB: 3 pharmacy orders for John + 3 ORDER_PLACED audit rows", n("SELECT count(*) FROM pharmacy_orders WHERE patient_id='MRN-4012'") == 3
      and n("SELECT count(*) FROM agent_audit a JOIN pharmacy_orders po ON po.order_id = a.subject_id "
            "WHERE a.event_type='ORDER_PLACED' AND a.actor='BMC-4101' AND po.patient_id='MRN-4012'") == 3)
o = order(rachel, "MRN-4012")
check("John ALL again -> 3 ALREADY_ORDERED, still 3 orders", [x["outcome"] for x in o] == ["ALREADY_ORDERED"] * 3
      and n("SELECT count(*) FROM pharmacy_orders WHERE patient_id='MRN-4012'") == 3, o)
o = order(rachel, "MRN-4012", "oxycodone")
check("NOT ON THE LIST: oxycodone for John -> BLOCKED NOT_ON_DISCHARGE_LIST, nothing ordered", len(o) == 1
      and o[0]["outcome"] == "BLOCKED" and o[0]["reason_code"] == "NOT_ON_DISCHARGE_LIST" and "attending" in o[0]["reason_text"]
      and n("SELECT count(*) FROM pharmacy_orders WHERE patient_id='MRN-4012'") == 3, o)
o = order(rachel, "MRN-4012", "aspirin and oxycodone")
check("mixed request: aspirin ALREADY_ORDERED, oxycodone NOT_ON_DISCHARGE_LIST",
      sorted(x["outcome"] for x in o) == ["ALREADY_ORDERED", "BLOCKED"], o)
o = order(rachel, "MRN-4012", "ibuprofen")
check("unknown medicine -> NOT_ON_DISCHARGE_LIST", o[0]["reason_code"] == "NOT_ON_DISCHARGE_LIST", o)
BRIEF = ("INTERACTION: home low-dose aspirin + discharge warfarin (bleeding risk); INTERACTION: home ibuprofen (NSAID) + "
         "warfarin (bleeding risk); OMISSION: home water pill not on the discharge list")
o = {x["medication"]: x for x in order(rachel, "MRN-4015", "", BRIEF)}
w = next(x for k, x in o.items() if k.startswith("Warfarin"))
check("Margaret ALL -> metoprolol + omeprazole ORDERED (Meds-to-Beds, still on the unit), warfarin PHARMACIST_REVIEW",
      len(o) == 3 and w["outcome"] == "PHARMACIST_REVIEW" and w["case_id"].startswith("BMC-CASE-") and w["team"] == "Pharmacy"
      and all(x["outcome"] == "ORDERED" and x["pickup_location"] == "Meds-to-Beds bedside delivery" for k, x in o.items() if k != w["medication"]), o)
wcase = w["case_id"]
check("DB: high_alert_med case OPEN for Pharmacy, 30 days requested, parked MED_ORDER, brief attached, no warfarin order",
      n(f"SELECT count(*) FROM service_cases WHERE case_id='{wcase}' AND request_type='high_alert_med' AND status='OPEN' "
        f"AND requested_amount=30 AND parked_action LIKE 'MED_ORDER:%' AND agent_brief LIKE 'INTERACTION:%'") == 1
      and n("SELECT count(*) FROM pharmacy_orders WHERE medication_code='MED-105'") == 0)
o = order(rachel, "MRN-4015", "warfarin")
check("warfarin again -> PHARMACIST_REVIEW on the same case, no second case", o[0]["outcome"] == "PHARMACIST_REVIEW"
      and o[0]["case_id"] == wcase and n("SELECT count(*) FROM service_cases WHERE request_type='high_alert_med' AND patient_id='MRN-4015'") == 1, o)
o = order(rachel, "MRN-4021")
check("Dorothy (no discharge order) -> DISCHARGE_NOT_ORDERED", o[0]["reason_code"] == "DISCHARGE_NOT_ORDERED"
      and n("SELECT count(*) FROM pharmacy_orders WHERE patient_id='MRN-4021'") == 0, o)
o = order(rachel, "MRN-3204")
check("SCOPE: Rachel orders for Thomas (3B) -> NOT_FOUND", o[0]["reason_code"] == "NOT_FOUND"
      and n("SELECT count(*) FROM pharmacy_orders WHERE patient_id='MRN-3204'") == 0, o)
o = order(rachel, "MRN-4009", "amoxicillin")
check("William's antibiotic -> ALREADY_ORDERED (RX-000011)", o[0]["outcome"] == "ALREADY_ORDERED" and o[0]["order_id"] == "RX-000011", o)
o = order(rachel, "MRN-4018", "the water pill")
check("common name 'water pill' -> Robert's furosemide ORDERED", len(o) == 1 and o[0]["outcome"] == "ORDERED"
      and o[0]["medication"].startswith("Furosemide"), o)
o = {x["medication"].split()[0]: x for x in order(daniel, "MRN-3204")}
check("Thomas ALL -> acetaminophen ORDERED, oxycodone on seeded case 000001, enoxaparin parked in a new case",
      o["Acetaminophen"]["outcome"] == "ORDERED" and o["Oxycodone"]["outcome"] == "PHARMACIST_REVIEW"
      and o["Oxycodone"]["case_id"] == "BMC-CASE-000001" and o["Enoxaparin"]["outcome"] == "PHARMACIST_REVIEW"
      and o["Enoxaparin"]["case_id"] not in ("", "BMC-CASE-000001"), o)
ecase = o["Enoxaparin"]["case_id"]
ms = {x["medication_code"]: x for x in call("get_discharge_summary", session_token=rachel, patient_id="MRN-4015")}
check("Margaret's summary shows ORDERED and PHARMACIST REVIEW statuses", ms["MED-102"]["order_status"].startswith("ORDERED RX-")
      and ms["MED-105"]["order_status"].startswith("PHARMACIST REVIEW " + wcase), ms)

# ---------------------------------------------------------------- bed turnover
def bed(tok, b): return one("request_bed_turnover", session_token=tok, bed_id=b)
r = bed(rachel, "4A-12")
check("NOT YET LEFT: Robert's bed 4A-12 -> BLOCKED PATIENT_NOT_DISCHARGED, bed unchanged", r["outcome"] == "BLOCKED"
      and r["reason_code"] == "PATIENT_NOT_DISCHARGED" and "charge nurse" in r["reason_text"]
      and val("SELECT status FROM beds WHERE bed_id='4A-12'") == "OCCUPIED", r)
for b, code in (("4A-09", "BED_EMPTY"), ("4A-15", "ALREADY_REQUESTED"), ("3B-04", "NOT_FOUND"), ("9Z-99", "NOT_FOUND")):
    r = bed(rachel, b)
    check(f"bed {b} -> BLOCKED {code}", r["outcome"] == "BLOCKED" and r["reason_code"] == code, r)
r = bed(rachel, "BED-4A-010")
check("John's bed (typed BED-4A-010) -> REQUESTED, standard 45-minute clean", r["outcome"] == "REQUESTED" and r["bed_id"] == "4A-10"
      and r["reference"].startswith("BMC-BED-") and "45 minutes" in r["reason_text"] and r["estimated_ready"], r)
check("DB: bed 4A-10 CLEANING_REQUESTED, patient cleared, BED_TURNOVER audit",
      val("SELECT status FROM beds WHERE bed_id='4A-10'") == "CLEANING_REQUESTED"
      and val("SELECT coalesce(patient_id,'-') FROM beds WHERE bed_id='4A-10'") == "-"
      and n("SELECT count(*) FROM agent_audit WHERE event_type='BED_TURNOVER' AND actor='BMC-4101'") == 1)
r = bed(rachel, "4A-10")
check("again -> ALREADY_REQUESTED, one bed event", r["reason_code"] == "ALREADY_REQUESTED" and n("SELECT count(*) FROM bed_events") == 1, r)
r = bed(daniel, "3B-04")
check("Thomas's isolation bed -> REQUESTED, 90-minute terminal clean", r["outcome"] == "REQUESTED" and "90 minutes" in r["reason_text"], r)

# ---------------------------------------------------------------- human-owned cases
def case(tok, rtype, pid, summary="Neutral summary of the request.", ref="", brief=""):
    return one("open_service_case", session_token=tok, request_type=rtype, patient_id=pid, summary=summary,
               reference_id=ref, agent_brief=brief)
check("unknown request type -> INVALID_TYPE", case(rachel, "refund", "MRN-4012")["outcome"] == "INVALID_TYPE")
check("high_alert_med cannot be opened directly -> INVALID_TYPE", case(rachel, "high_alert_med", "MRN-4012")["outcome"] == "INVALID_TYPE")
r = case(rachel, "clinical question", "MRN-4012", "The coordinator asks whether John should take an extra metoprolol if his heart races.")
check("dosage question -> OPENED for Hospitalist Service, 2-hour SLA", r["outcome"] == "OPENED" and r["team"] == "Hospitalist Service"
      and r["case_id"].startswith("BMC-CASE-0001") and "2 hours" in r["sla_text"], r)
qcase = r["case_id"]
r = case(rachel, "clinical_question", "MRN-4012")
check("same request again -> EXISTING (no duplicate)", r["outcome"] == "EXISTING" and r["case_id"] == qcase, r)
r = case(rachel, "prescription_change", "MRN-4012", "The coordinator asks whether oxycodone can be added for John's back pain.")
check("prescription change -> OPENED for Hospitalist Service", r["outcome"] == "OPENED" and r["team"] == "Hospitalist Service", r)
r = case(rachel, "bed_override", "MRN-4018", "Robert is dressed and waiting for his ride in the discharge lounge.")
check("early turnover for Robert -> OPENED for Nursing Operations, parked BED_TURNOVER:4A-12", r["outcome"] == "OPENED"
      and r["team"] == "Nursing Operations" and n(f"SELECT count(*) FROM service_cases WHERE case_id='{r['case_id']}' AND parked_action='BED_TURNOVER:4A-12'") == 1, r)
rcase = r["case_id"]
r = case(rachel, "bed_override", "MRN-4009", ref="4A-09")
check("bed override for a patient who has left -> BED_NOT_ELIGIBLE", r["outcome"] == "BLOCKED" and r["reason_code"] == "BED_NOT_ELIGIBLE", r)
r = case(rachel, "bed_override", "MRN-4015", ref="4A-12")
check("bed override naming someone else's bed -> BED_NOT_ELIGIBLE", r["reason_code"] == "BED_NOT_ELIGIBLE", r)
check("SCOPE: case for a 3B patient -> NOT_FOUND", case(rachel, "clinical_question", "MRN-3207")["reason_code"] == "NOT_FOUND")
r = case(rachel, "med_rec_review", "MRN-4009", "William's wife listed his home medicines.", brief="DUPLICATE: none; UNCLEAR: 'the heart pill'")
check("med rec review -> OPENED for Pharmacy with the brief", r["outcome"] == "OPENED" and r["team"] == "Pharmacy"
      and val(f"SELECT agent_brief FROM service_cases WHERE case_id='{r['case_id']}'").startswith("DUPLICATE"), r)
mrcase = r["case_id"]
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=rachel)}
check("Rachel's ward cases: the open ones, team + 'a person will decide', never 3B cases", qcase in mc and wcase in mc
      and "BMC-CASE-000003" in mc and "BMC-CASE-000001" not in mc and "will decide" in mc[qcase]["customer_message"], mc.keys())

# ---------------------------------------------------------------- the reviewer loop
def ids(tok): return [x["case_id"] for x in call("get_review_queue", session_token=tok)]
q = ids(priya)
check("Priya's Pharmacy queue: oxycodone (000001), warfarin, enoxaparin, med rec - nothing from other teams",
      set(q) == {"BMC-CASE-000001", wcase, ecase, mrcase}, q)
check("Maya's Nursing queue: Angela's seeded override + Robert's", set(ids(maya)) == {"BMC-CASE-000002", rcase})
check("Dr. Torres's queue: Dorothy's discharge decision + John's two questions", len(ids(elena)) == 3 and "BMC-CASE-000003" in ids(elena))
rq = call("get_review_queue", session_token=priya)
check("queue rows: first name + last initial, sla_status, requested days", any(x["patient"] == "Margaret E." for x in rq)
      and all(x["sla_status"] in ("ON_TRACK", "DUE_SOON", "OVERDUE") for x in rq), rq)
rc = one("get_review_case", session_token=priya, case_id=wcase.lower())
check("Priya opens the warfarin case: max 30 days, her limit 30, facts + AI brief labelled unverified",
      rc["status"] == "OK" and i0(rc["max_approvable_days"]) == 30 and i0(rc["your_approval_limit_days"]) == 30
      and "Warfarin 5 mg" in rc["facts"] and "patient age" in rc["facts"] and rc["agent_brief"].startswith("AI-prepared, not verified")
      and rc["patient"] == "Margaret E.", rc)
check("SCOPE: Priya opens a Nursing case -> NOT_FOUND", one("get_review_case", session_token=priya, case_id="BMC-CASE-000002")["status"] == "NOT_FOUND")
check("coordinator token opens a case -> NOT_REVIEWER", one("get_review_case", session_token=rachel, case_id=wcase)["status"] == "NOT_REVIEWER")

def decide(tok, cid, dec, amt="", note="Reviewed against the chart.", msg=""):
    return one("decide_review_case", session_token=tok, case_id=cid, decision=dec, amount=amt, internal_note=note, customer_message=msg)
r = decide(rachel, wcase, "APPROVE", "30")
check("CUSTOMER CAN'T DECIDE: coordinator token -> NOT_REVIEWER, no decision", r["outcome"] == "NOT_REVIEWER"
      and n("SELECT count(*) FROM review_decisions") == 0, r)
r = decide(priya, "BMC-CASE-000002", "APPROVE")
check("NOT_YOUR_TEAM: Priya decides a Nursing case", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_YOUR_TEAM", r)
check("NOT_FOUND: unknown case", decide(priya, "BMC-CASE-999999", "APPROVE")["reason_code"] == "NOT_FOUND")
check("INVALID_DECISION", decide(priya, wcase, "maybe")["reason_code"] == "INVALID_DECISION")
check("NOTE_REQUIRED", decide(priya, wcase, "APPROVE", "14", note="ok")["reason_code"] == "NOTE_REQUIRED")
for amt in ("45", "-3", "0", "lots"):
    r = decide(priya, wcase, "APPROVE", amt)
    check(f"AMOUNT_INVALID: {amt!r} days", r["reason_code"] == "AMOUNT_INVALID" and "30 days" in r["reason_text"], r)
r = decide(owen, "BMC-CASE-000001", "APPROVE", "10")
check("OVER_AUTHORITY: Owen (7-day limit) approves 10 days of oxycodone -> case stays OPEN, nothing dispensed",
      r["reason_code"] == "OVER_AUTHORITY" and r["case_status"] == "OPEN" and "senior pharmacist" in r["reason_text"]
      and n("SELECT count(*) FROM pharmacy_orders WHERE medication_code='MED-107'") == 0, r)
r = decide(owen, "BMC-CASE-000001", "approve", "5 days", msg="Oxycodone approved for 5 days; pain follow-up at the orthopedic visit.")
check("Owen approves 5 days (within his limit) -> APPROVED, dispensed", r["outcome"] == "APPROVED" and i0(r["approved_days"]) == 5
      and r["executed_action"].startswith("Dispensed: order RX-") and "5 days" in r["executed_action"], r)
NOTE = "INR baseline 1.1; 14-day bridge until the anticoagulation clinic visit; counselled on aspirin and NSAIDs."
MSG = "Warfarin approved for a 14-day supply. The anticoagulation clinic will manage the dose after that."
r = decide(priya, wcase, "APPROVE", "14", note=NOTE, msg=MSG)
check("Priya approves warfarin for 14 days (amended amount) -> APPROVED, dispensed 14 days", r["outcome"] == "APPROVED"
      and i0(r["approved_days"]) == 14 and "Warfarin" in r["executed_action"] and r["customer_message"] == MSG, r)
check("DB: decision row + warfarin order 14 days released by the case (Meds-to-Beds) + CASE_DECIDED audit",
      n(f"SELECT count(*) FROM review_decisions WHERE case_id='{wcase}' AND reviewer_id='BMC-7701' AND decision='APPROVE' AND approved_amount=14") == 1
      and n(f"SELECT count(*) FROM pharmacy_orders WHERE medication_code='MED-105' AND days_supply=14 AND case_id='{wcase}' "
            f"AND ordered_by='BMC-7701' AND pickup_location='Meds-to-Beds bedside delivery'") == 1
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{wcase}' AND actor='BMC-7701'") == 1)
r = decide(priya, wcase, "REJECT")
check("ALREADY_DECIDED: second decision blocked", r["reason_code"] == "ALREADY_DECIDED" and n(f"SELECT count(*) FROM review_decisions WHERE case_id='{wcase}'") == 1, r)
r = decide(priya, ecase, "REJECT", note="Duplicate anticoagulation with the planned regimen; attending to review.")
check("REJECT enoxaparin -> REJECTED, nothing executed", r["outcome"] == "REJECTED" and "nothing was executed" in r["executed_action"]
      and n("SELECT count(*) FROM pharmacy_orders WHERE medication_code='MED-112'") == 0, r)
r = decide(priya, mrcase, "APPROVE", "99", note="Home list matches; heart pill is the metoprolol.")
check("approve med rec (no supply on the case; amount ignored) -> APPROVED, no automatic action", r["outcome"] == "APPROVED"
      and "no automatic action" in r["executed_action"], r)
r = decide(maya, "BMC-CASE-000002", "APPROVE", note="Patient confirmed in the discharge lounge; ED admission waiting.")
check("Maya approves Angela's early turnover -> bed 3B-07 sent to housekeeping (override)", r["outcome"] == "APPROVED"
      and "3B-07" in r["executed_action"] and val("SELECT status FROM beds WHERE bed_id='3B-07'") == "CLEANING_REQUESTED"
      and n("SELECT count(*) FROM bed_events WHERE bed_id='3B-07' AND override AND case_id='BMC-CASE-000002' AND requested_by='BMC-5501'") == 1, r)
r = decide(maya, rcase, "REJECT", note="Robert still needs his final vitals at 15:00.", msg="Keep the bed until Robert leaves tomorrow.")
check("Maya rejects Robert's override -> bed 4A-12 still OCCUPIED", r["outcome"] == "REJECTED"
      and val("SELECT status FROM beds WHERE bed_id='4A-12'") == "OCCUPIED", r)
r = decide(elena, "BMC-CASE-000003", "APPROVE", note="Seen on rounds; discharge order will be signed today.")
check("Dr. Torres approves the discharge decision -> recorded, no automatic action (discharge still PENDING in the record)",
      r["outcome"] == "APPROVED" and "no automatic action" in r["executed_action"]
      and val("SELECT status FROM discharges WHERE patient_id='MRN-4021'") == "PENDING", r)
check("every decision has an audit row", n("SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED'")
      == n("SELECT count(*) FROM review_decisions") == 7)
check("decided cases leave the queue", wcase not in ids(priya) and "BMC-CASE-000001" not in ids(priya))

# ---------------------------------------------------------------- the coordinator sees the outcome
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=rachel)}
check("Rachel sees the warfarin case APPROVED, 14 days, with the reviewer's message",
      mc[wcase]["case_status"] == "APPROVED" and i0(mc[wcase]["approved_days"]) == 14 and mc[wcase]["customer_message"] == MSG, mc[wcase])
ms = {x["medication_code"]: x for x in call("get_discharge_summary", session_token=rachel, patient_id="MRN-4015")}
check("Margaret's summary: warfarin now ORDERED (14 days)", ms["MED-105"]["order_status"].startswith("ORDERED RX-")
      and "14 days" in ms["MED-105"]["order_status"], ms["MED-105"])
po = {x["medication"].split()[0]: x for x in call("get_pharmacy_orders", session_token=rachel, patient_id="MRN-4015")}
check("Margaret's orders: warfarin released after pharmacist review", po["Warfarin"]["released"].startswith("after pharmacist review"), po)

# ---------------------------------------------------------------- email guard
e = one("email_patient_summary", session_token=rachel, patient_id="MRN-4012")
check("email John's plan -> SEND_OK: follow-up + 3 medicines with pickup, as prescribed, AI sign-off, no MRN / surname",
      e["send_status"] == "SEND_OK" and e["patient_first_name"] == "John" and "Follow-up visit (Cardiology)" in e["body"]
      and "Echocardiogram" in e["body"] and "Aspirin 81 mg tablet: 1 tablet by mouth once daily" in e["body"]
      and "Outpatient Pharmacy" in e["body"] and "AI assistant" in e["body"] and "MRN" not in e["body"]
      and "Harper" not in e["body"], e)
e = one("email_patient_summary", session_token=rachel, patient_id="MRN-4015")
check("email Margaret's plan -> SEND_OK with the 14-day warfarin, never the internal note", e["send_status"] == "SEND_OK"
      and "Warfarin 5 mg tablet" in e["body"] and "(14 days)" in e["body"] and NOTE not in e["body"], e)
e = one("email_patient_summary", session_token=daniel, patient_id="MRN-3211")
check("nothing arranged for Kevin -> NOT_SENT NOTHING_TO_SEND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOTHING_TO_SEND", e)
e = one("email_patient_summary", session_token=rachel, patient_id="MRN-3204")
check("SCOPE: Rachel emails a 3B patient -> NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
check("exactly 2 emails logged", n("SELECT count(*) FROM email_log") == 2)

# ---------------------------------------------------------------- session expiry
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(rachel)}")
check("expired coordinator token -> SESSION_INVALID", one("get_ward_discharges", session_token=rachel)["status"] == "SESSION_INVALID")
check("expired token cannot order", order(rachel, "MRN-4018", "lisinopril")[0]["outcome"] == "SESSION_INVALID")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(maya)}")
check("expired reviewer token -> NOT_REVIEWER", one("get_review_queue", session_token=maya)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- hidden data never leaves the DB
co_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
leaked = sorted({k for _, rows in co_out for row in rows for k in row} & HIDDEN_COLUMNS)
check("no coordinator tool output has a hidden column", not leaked, leaked)
cblob = "\n".join(str(v) for _, rows in co_out for row in rows for v in row.values())
secrets = [x["v"] for x in psql("SELECT to_char(date_of_birth,'YYYY-MM-DD') v FROM patients UNION ALL SELECT phone FROM patients "
                                "UNION ALL SELECT email FROM patients UNION ALL SELECT insurance_id FROM patients "
                                "UNION ALL SELECT home_address FROM patients UNION ALL SELECT internal_note FROM review_decisions "
                                "UNION ALL SELECT display_name FROM reviewers UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL")]
check("coordinator outputs never contain DOB, phone, email, address, insurance id, internal notes, reviewer names or agent briefs",
      not any(s and s in cblob for s in secrets), [s for s in secrets if s and s in cblob][:3])
rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
rblob = "\n".join(str(v) for _, rows in rev_out for row in rows for v in row.values())
check("reviewer outputs: no MRN / DOB / contact details / full last name",
      not rleak and not re.search(r"MRN-\d|@example\.com|\(555\)|INS-|Harper|Ellis|Reed|Morris|Nguyen|Evans|Foster|Shaw", rblob),
      (rleak, re.findall(r"MRN-\d+|Harper|Ellis|Reed|Morris|Nguyen|Evans|Foster|Shaw", rblob)[:5]))
texts = [str(row.get(k) or "") for _, rows in co_out for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the model|LLM|the assistant|the user)\b", t, re.I)]
check("coordinator-facing texts address the coordinator (never the model)", not bad, bad[:3])
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT v FROM (SELECT (json_each_text(row_to_json(p))).* FROM patients p) x(k, v) "
    "  WHERE k IN ('patient_id','last_name','phone','email','home_address','insurance_id') "
    "UNION SELECT first_name || ' ' || last_name FROM patients "
    "UNION SELECT staff_id FROM coordinators UNION SELECT display_name FROM coordinators UNION SELECT one_time_code FROM coordinators "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM service_cases UNION SELECT clinician FROM clinic_slots "
    "UNION SELECT session_token FROM sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 30, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_plain_language_guide": ("by mouth", "by mouth", "safety net", 1),
    "get_med_rec_reference": ("baby aspirin", "baby aspirin", "high alert", n("SELECT count(*) FROM medication_catalog WHERE high_alert")),
    "get_slot_ranking_guide": ("wheelchair", "needs wheelchair transport", "part of day", 3),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["discharge_instructions_agent", "med_reconciliation_agent", "followup_slot_agent"])
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
    check(f"{tool}: whitespace / separators only = whole guide", len(ref_call(t, " , ")) == len(full))
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
    check(f"{tool}: '%' and '_' are literal (no wildcard expansion)", ref_call(t, "%") == [] and ref_call(t, "_%_") == [])
    check(f"{tool}: SQL-looking input is just a string -> 0 rows",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no patient / staff / reviewer / case / session / clinician value in the reference rows", not leaked, leaked[:5])
    check(f"{tool}: no MRN, staff id, case id, email or token pattern",
          not re.search(r"mrn-\d|bmc-\d|case-\d|apt-\d|rx-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

med = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_med_rec")
both = ref_call(med, "baby aspirin, ibuprofen")
check("ref_med_rec: several words in one call ('baby aspirin, ibuprofen') -> both found",
      {"baby aspirin", "ibuprofen"} <= {r["term"] for r in both}, [r["term"] for r in both])
check("ref_med_rec: HIGH_ALERT rows come from medication_catalog.high_alert (one source of truth)",
      sorted(r["term"] for r in ref_call(med, "high alert"))
      == sorted(r["generic_name"] for r in psql("SELECT generic_name FROM medication_catalog WHERE high_alert")))
# nothing from the old static glossary text was lost
KEEP = {"get_plain_language_guide": ["swallow whole, do not crush", "dose per inr result", "(555) 010-4400", "911",
                                     "6th-grade", "meds-to-beds", "echocardiogram", "extended-release"],
        "get_med_rec_reference": ["baby aspirin", "water pill", "paracetamol", "fish oil", "my heart pill", "duplicate",
                                  "interaction", "omission", "unclear", "anticoagulant + nsaid",
                                  "acetaminophen from more than one source", "the pharmacist decides"],
        "get_slot_ranking_guide": ["starts before 12:00", "12:00 to 16:59", "17:00 or later", "step-free",
                                   "wheelchair-accessible van", "both wheelchair_accessible yes and transport_available yes",
                                   "the same day is not enough", "prefer the earliest", "not in the list"]}
for t in AGENT_REF_TOOLS:
    blob = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k not in blob]
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

reset()
check("reset_data.sql reloads the agent reference tables",
      all(n(f"SELECT count(*) FROM {t['table']}") > 0 for t in AGENT_REF_TOOLS))
total = passes + fails
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} checks, DB reset)")
sys.exit(1 if fails else 0)
