#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the predictive_maintenance_governed DB and assert the
business rules on DB state - the deterministic health classifier, operator scope, the field-note reconciliation (incl. the
SQL safety backstop and the automatic HSE case), the two-step work order (incl. an estimate above the operator's limit ->
Production Engineering case), the deduped alert log, cases, the full reviewer loop (team, budget authority, amended budget,
the parked work order / shut-in / safety inspection / alert closure, audit), the guarded email and the A2A agents'
read-only reference tools (ref_* functions). No Flogo needed. Re-loads
reset_data.sql first and again at the end (re-runnable).

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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "predictive_maintenance_governed"),
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




PB_ASSETS = ["COMP-PB-S12", "PUMP-PB-W33", "PUMP-PB-W47", "PUMP-PB-W48", "VALVE-PB-W52"]
reset()

# ---------------------------------------------------------------- identity, throttle, role separation
r = one("verify_operator", staff_id="MRE-4101", code="0000")
check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_operator", staff_id="mre4101", code="2468")
check("lowercase id + right code -> VERIFIED for the Permian region, limit $25,000",
      r["outcome"] == "VERIFIED" and r["session_token"] and "Permian" in r["region"] and r["spend_limit_usd"] == "$25,000.00", r)
jolene = r["session_token"]
travis = one("verify_operator", staff_id="4201", code="1357")["session_token"]
check("short staff id 4201 verifies Travis", bool(travis))
elena = one("verify_operator", staff_id="MRE-4301", code="8642")["session_token"]
for _ in range(5):
    one("verify_operator", staff_id="MRE-4301", code="1111")
r = one("verify_operator", staff_id="MRE-4301", code="8642")
check("5 failures in 15 minutes -> LOCKED even with the right code", r["outcome"] == "LOCKED" and not r["session_token"], r)
check("LOCKED creates no new session", n("SELECT count(*) FROM sessions WHERE operator_id = 'MRE-4301'") == 1)
wade = one("verify_reviewer", staff_id="MRE-7101", code="4096")["session_token"]
nadia = one("verify_reviewer", staff_id="mre-7102", code="7531")["session_token"]
r = one("verify_reviewer", staff_id="8101", code="6174")
curtis = r["session_token"]
check("reviewers verify with role REVIEWER and their team", bool(wade and nadia) and r["role"] == "REVIEWER" and r["team"] == "HSE", r)
check("an operator's id + code does not verify as a reviewer",
      one("verify_reviewer", staff_id="MRE-4101", code="2468")["outcome"] == "VERIFY_FAILED")
check("a reviewer's id + code does not verify as an operator",
      one("verify_operator", staff_id="MRE-7101", code="4096")["outcome"] == "VERIFY_FAILED")
check("operator token on the review queue -> NOT_REVIEWER", one("get_review_queue", session_token=jolene)["status"] == "NOT_REVIEWER")
check("reviewer token on an operator read -> SESSION_INVALID", one("get_region_assets", session_token=wade)["status"] == "SESSION_INVALID")
check("forged token -> SESSION_INVALID",
      one("get_region_assets", session_token="00000000-0000-0000-0000-000000000000")["status"] == "SESSION_INVALID")

# ---------------------------------------------------------------- the deterministic classifier, through the tools
rows = call("get_region_assets", session_token=jolene)
check("Jolene sees exactly her 5 Permian assets", sorted(x["asset_id"] for x in rows) == PB_ASSETS, [x["asset_id"] for x in rows])
check("worst health first: COMP-PB-S12 CRITICAL", rows[0]["asset_id"] == "COMP-PB-S12" and rows[0]["health_status"] == "CRITICAL", rows[0])
h = one("get_asset_health", session_token=jolene, asset_id="w47")
check("short tag w47 -> PUMP-PB-W47: WARNING, vibration worst, bearing_wear, 2 anomalous, 0.85, 10-21 days",
      h["asset_id"] == "PUMP-PB-W47" and h["health_status"] == "WARNING" and h["worst_sensor"] == "vibration"
      and h["failure_mode"] == "bearing_wear" and h["anomalous_sensors"] == "2" and h["confidence"] == "0.85"
      and h["days_to_failure"] == "10-21 days", h)
check("W47: temperature 189 F is a WARNING against the 185 F line (degrees F, from the threshold table)",
      "temperature 189 F WARNING" in h["anomalies"] and "warning above 185" in h["anomalies"], h["anomalies"])
check("W47: work order allowed, estimate $8,400 from the failure-mode table",
      h["work_order_allowed"] == "yes" and h["repair_estimate_usd"] == "$8,400.00", h)
h = one("get_asset_health", session_token=jolene, asset_id="COMP-PB-S12")
check("S12: CRITICAL; temperature beats vibration on the normalised exceedance tie-break; overheating, 3 anomalous, 0.92, 3-7 days, $68,000",
      h["health_status"] == "CRITICAL" and h["worst_sensor"] == "temperature" and h["failure_mode"] == "overheating"
      and h["anomalous_sensors"] == "3" and h["confidence"] == "0.92" and h["days_to_failure"] == "3-7 days"
      and h["repair_estimate_usd"] == "$68,000.00", h)
h = one("get_asset_health", session_token=jolene, asset_id="VALVE-PB-W52")
check("W52: NORMAL, confidence 0.95, 90+ days, no failure mode, no work order allowed",
      h["health_status"] == "NORMAL" and h["confidence"] == "0.95" and h["days_to_failure"] == "90+ days"
      and not h["failure_mode"] and h["work_order_allowed"].startswith("no - health is NORMAL"), h)
h = one("get_asset_health", session_token=jolene, asset_id="PUMP-PB-W33")
check("W33: in MAINTENANCE -> work order not allowed", h["asset_status"] == "MAINTENANCE"
      and h["work_order_allowed"] == "no - the asset is in MAINTENANCE" and h["open_work_order"] == "MRE-WO-1029", h)
check("SCOPE: Jolene asks for a Bakken asset -> NOT_FOUND",
      one("get_asset_health", session_token=jolene, asset_id="PUMP-BK-W21")["status"] == "NOT_FOUND")
h = one("get_asset_health", session_token=travis, asset_id="PUMP-BK-W21")
check("Travis: BK-W21 WARNING seal_leak (pressure low worst), 4 anomalous -> 0.97",
      h["health_status"] == "WARNING" and h["failure_mode"] == "seal_leak" and h["worst_sensor"] == "pressure"
      and h["confidence"] == "0.97", h)
h = one("get_asset_health", session_token=elena, asset_id="PUMP-EF-W14")
check("Elena: EF-W14 CRITICAL bearing_wear, 4 anomalous -> 0.97", h["health_status"] == "CRITICAL"
      and h["failure_mode"] == "bearing_wear" and h["anomalous_sensors"] == "4" and h["confidence"] == "0.97", h)
rd = call("get_sensor_readings", session_token=jolene, asset_id="PUMP-PB-W47")
check("W47 readings: 6 in 24 h, oldest first, vibration 3.2 -> 5.4 g, temperature in F",
      len(rd) == 6 and rd[0]["vibration_g"] == "3.20" and rd[-1]["vibration_g"] == "5.40" and rd[-1]["temperature_f"] == "189.0", rd[-1])
check("readings in another region -> NOT_FOUND",
      one("get_sensor_readings", session_token=jolene, asset_id="PUMP-EF-W14")["status"] == "NOT_FOUND")
wo = call("get_work_orders", session_token=jolene, asset_id="ALL")
nums = [x["wo_number"] for x in wo]
check("work orders: Permian only, open first (MRE-WO-1029), recent closed included (1001), older closed not (1003)",
      nums and nums[0] == "MRE-WO-1029" and "MRE-WO-1001" in nums and "MRE-WO-1003" not in nums and "MRE-WO-1028" not in nums, nums)
check("work orders for another region's asset -> NOT_FOUND",
      one("get_work_orders", session_token=jolene, asset_id="PUMP-BK-W21")["status"] == "NOT_FOUND")
al = call("get_alerts", session_token=elena, asset_id="ALL")
check("Elena's alerts: today's CRITICAL ALR-000092 from the monitoring system",
      any(x["alert_id"] == "ALR-000092" and x["alert_status"] == "OPEN" and x["logged_by"] == "monitoring system" for x in al), al)
check("Jolene has no alerts yet -> NONE", one("get_alerts", session_token=jolene, asset_id="")["status"] == "NONE")
fm = call("get_failure_modes", session_token=jolene, asset_id="PUMP-PB-W47")
check("failure modes for a rod pump: 6, the sensor-matching one first",
      len(fm) == 6 and fm[0]["failure_mode"] == "bearing_wear" and fm[0]["matches_sensor_classification"] == "yes", fm[0])
hist = call("get_failure_history", session_token=jolene, asset_id="PUMP-PB-W47")
check("reliability library: closed rod-pump jobs company-wide (incl. Eagle Ford), newest first, with the fix",
      {x["wo_number"] for x in hist} == {"MRE-WO-1001", "MRE-WO-1002", "MRE-WO-1003", "MRE-WO-1004", "MRE-WO-1005"}
      and any(x["basin"] == "Eagle Ford" for x in hist) and hist[0]["wo_number"] == "MRE-WO-1001" and hist[0]["fix_applied"], hist[:2])
check("reliability library has no crew or people columns", not ({"crew", "created_by", "approved_by"} & set(hist[0])), list(hist[0]))
ho = call("get_region_handover", session_token=jolene)
types = {x["item_type"] for x in ho}
blob = str(ho)
check("handover: open cases? none yet; health items for S12/W47/W33 and open work order 1029",
      {"ASSET_HEALTH", "WORK_ORDER"} <= types and {x["ref"] for x in ho if x["item_type"] == "ASSET_HEALTH"} == {"COMP-PB-S12", "PUMP-PB-W47", "PUMP-PB-W33"}, types)
check("handover has no names and no case ids", not re.search(r"Pruitt|Okafor|Varga|Hollister|Brennan|Rayburn|MRE-CASE|MRE-4|MRE-7|MRE-8", blob))

# ---------------------------------------------------------------- field notes: validate + reconcile the triage output in SQL
GEAR = "Growling from the gearbox on the downstroke, grease slinging off the saddle bearing, vibration feels worse than last week."
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W47", note_text=GEAR, failure_mode="Bearing wear", urgency="high",
        safety_language="no", summary="Saddle / wrist-pin bearing wear likely; parts: saddle bearing assembly, wrist-pin bearing kit")
check("W47 note: WORK_ORDER_ELIGIBLE, agent AGREEs with the sensors, no safety, no case",
      r["outcome"] == "WORK_ORDER_ELIGIBLE" and r["agreement"] == "AGREE" and r["safety_detected"] == "no" and not r["case_id"], r)
check("agent output normalised: 'Bearing wear' -> bearing_wear, 'high' -> HIGH",
      val(f"SELECT agent_failure_mode || '/' || agent_urgency FROM field_notes WHERE note_id = {lit(r['note_id'])}") == "bearing_wear/HIGH")
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W48", note_text="Unit sounds smooth, polished rod clean, no leaks.",
        failure_mode="", urgency="low", safety_language="no", summary="No issue found")
check("normal asset, no safety -> MONITOR / NO_SENSOR_ANOMALY", r["outcome"] == "MONITOR" and r["agreement"] == "NO_SENSOR_ANOMALY", r)
ODOR = "Gas odor at the bonnet when we walked past the wellhead this morning."
r = one("log_field_note", session_token=jolene, asset_id="VALVE-PB-W52", note_text=ODOR, failure_mode="seal_leak", urgency="IMMEDIATE",
        safety_language="yes", summary="Possible bonnet / stem packing leak; safety phrase: gas odor at the bonnet")
odor_case = r["case_id"] or ""
check("'gas odor at the bonnet' on a NORMAL valve -> SAFETY_CASE, new HSE case, source BOTH",
      r["outcome"] == "SAFETY_CASE" and odor_case.startswith("MRE-CASE-") and r["team"] == "HSE" and r["safety_source"] == "BOTH"
      and r["agreement"] == "NO_SENSOR_ANOMALY" and "HSE" in r["reason_text"], r)
c = psql(f"SELECT * FROM service_cases WHERE case_id = {lit(odor_case)}")[0]
check("the safety case was opened by the trigger: safety_signal, OPEN, parked SAFETY_WO, brief with the phrase, SLA 1 h",
      c["request_type"] == "safety_signal" and c["status"] == "OPEN" and c["parked_action"] == "SAFETY_WO:VALVE-PB-W52"
      and "gas odor" in c["agent_brief"] and c["opened_by"] == "MRE-4101"
      and n(f"SELECT count(*) FROM service_cases WHERE case_id = {lit(odor_case)} AND sla_due_at BETWEEN now() + interval '55 minutes' AND now() + interval '65 minutes'") == 1, c)
check("no work order from a safety note", n("SELECT count(*) FROM work_orders WHERE asset_id = 'VALVE-PB-W52'") == 0)
r = one("log_field_note", session_token=jolene, asset_id="VALVE-PB-W52", note_text="Still smell gas at the bonnet on the second round.",
        failure_mode="", urgency="high", safety_language="yes", summary="Gas smell persists at the bonnet")
check("second safety note on the same asset joins the open case (no duplicate)",
      r["case_id"] == odor_case and n("SELECT count(*) FROM service_cases WHERE asset_id = 'VALVE-PB-W52' AND request_type = 'safety_signal'") == 1, r)
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W48",
        note_text="Faint rotten-egg smell near the wellhead and my personal monitor chirped twice.", failure_mode="", urgency="IMMEDIATE",
        safety_language="yes", summary="Possible sour gas (H2S) exposure: rotten-egg smell, personal monitor alarm")
egg_case = r["case_id"] or ""
check("paraphrase only the agent catches ('rotten-egg smell') -> SAFETY_CASE, source AGENT",
      r["outcome"] == "SAFETY_CASE" and r["safety_source"] == "AGENT" and egg_case and egg_case != odor_case, r)
r = one("log_field_note", session_token=jolene, asset_id="COMP-PB-S12", note_text="Small oil spill under the scrubber dump line, about a gallon.",
        failure_mode="flow_blockage", urgency="medium", safety_language="no", summary="Scrubber dump line leak")
spill_case = r["case_id"] or ""
check("keyword backstop: 'spill' opens a SAFETY_CASE even when the agent said no (source KEYWORD)",
      r["outcome"] == "SAFETY_CASE" and r["safety_source"] == "KEYWORD" and r["safety_phrase"] == "spill" and spill_case, r)
r = one("log_field_note", session_token=jolene, asset_id="COMP-PB-S12", note_text="Belt squeal from the cooler fan and the discharge feels hot.",
        failure_mode="seal_leak", urgency="high", safety_language="no", summary="Rod packing leak?")
check("agent mode not among the anomalous sensors' modes -> DIFFERENT (still WORK_ORDER_ELIGIBLE)",
      r["outcome"] == "WORK_ORDER_ELIGIBLE" and r["agreement"] == "DIFFERENT" and "differs" in r["reason_text"], r)
r = one("log_field_note", session_token=jolene, asset_id="COMP-PB-S12", note_text="Misfire alarm cleared itself, discharge still hot.",
        failure_mode="overheating", urgency="high", safety_language="no", summary="Overheating")
check("'misfire' is not the safety word 'fire' (word boundaries) -> no safety case", r["safety_detected"] == "no" and r["agreement"] == "AGREE", r)
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W47", note_text="New noise from the horsehead.",
        failure_mode="corrosion", urgency="whenever", safety_language="maybe", summary="?")
check("invalid agent failure mode -> AGENT_MODE_INVALID, stored as NULL; unknown urgency -> NULL",
      r["agreement"] == "AGENT_MODE_INVALID" and r["agent_failure_mode"] == ""
      and val(f"SELECT coalesce(agent_urgency, 'NULL') FROM field_notes WHERE note_id = {lit(r['note_id'])}") == "NULL", r)
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W33", note_text="Amps still cycling a bit after the cleanout started.",
        failure_mode="flow_blockage", urgency="low", safety_language="no", summary="Flow blockage, cleanout under way")
check("asset in maintenance -> MONITOR", r["outcome"] == "MONITOR" and r["agreement"] == "AGREE", r)
before = n("SELECT count(*) FROM field_notes")
r = one("log_field_note", session_token=jolene, asset_id="PUMP-EF-W14", note_text="Gearbox noise", failure_mode="bearing_wear",
        urgency="high", safety_language="no", summary="x")
check("SCOPE: a note on another region's asset -> NOT_FOUND, nothing logged",
      r["outcome"] == "NOT_FOUND" and n("SELECT count(*) FROM field_notes") == before, r)
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W47", note_text="   ", failure_mode="", urgency="", safety_language="no", summary="")
check("empty note -> NOTE_EMPTY, nothing logged", r["outcome"] == "NOTE_EMPTY" and n("SELECT count(*) FROM field_notes") == before, r)
r = one("log_field_note", session_token=jolene, asset_id="PUMP-PB-W47", note_text="Robert'); DROP TABLE assets;--",
        failure_mode="", urgency="", safety_language="no", summary="")
check("SQL-looking note text is stored as data", r["note_id"] and n("SELECT count(*) FROM assets") == 10, r)
check("every logged note has a FIELD_NOTE audit row",
      n("SELECT count(*) FROM agent_audit WHERE event_type = 'FIELD_NOTE'") == n("SELECT count(*) FROM field_notes"))

# ---------------------------------------------------------------- work order: two-step, every guard
def propose(tok, asset, mode="", note=""):
    return one("propose_work_order", session_token=tok, asset_id=asset, failure_mode=mode, note=note)


def confirm(tok, pid):
    return one("confirm_action", session_token=tok, proposal_id=pid)


p = propose(jolene, "PUMP-PB-W47", "bearing_wear", "Gearbox growl on the downstroke; similar to MRE-WO-1001 (bearings replaced)")
check("W47 -> PROPOSED: HIGH, $8,400, no supervisor needed, crew + parts in the summary",
      p["outcome"] == "PROPOSED" and p["proposal_id"] and p["needs_supervisor_approval"] == "no" and p["estimate_usd"] == "$8,400.00"
      and p["priority"] == "HIGH" and "Permian Field Crew A" in p["summary"] and "saddle bearing" in p["summary"], p)
check("nothing is created before the confirm", n("SELECT count(*) FROM work_orders WHERE asset_id = 'PUMP-PB-W47' AND status <> 'CLOSED'") == 0)
p2 = propose(jolene, "PUMP-PB-W47", "bearing_wear", "again")
check("re-proposing the same work order reuses the open proposal",
      p2["proposal_id"] == p["proposal_id"] and n("SELECT count(*) FROM pending_actions WHERE asset_id = 'PUMP-PB-W47'") == 1, p2)
check("Travis cannot confirm Jolene's proposal -> NOT_FOUND", confirm(travis, p["proposal_id"])["outcome"] == "NOT_FOUND")
c = confirm(jolene, p["proposal_id"])
w47_wo = c["work_order"] or ""
check("confirm -> EXECUTED with work order MRE-WO-1101", c["outcome"] == "EXECUTED" and w47_wo == "MRE-WO-1101", c)
w = psql(f"SELECT *, scheduled_date = current_date + 3 AS sched_ok FROM work_orders WHERE wo_number = {lit(w47_wo)}")[0]
check("DB: work order SCHEDULED, HIGH, bearing_wear, crew A, estimate 8400, no budget, scheduled today + 3, created by Jolene",
      w["status"] == "SCHEDULED" and w["priority"] == "HIGH" and w["failure_mode"] == "bearing_wear" and w["crew"] == "Permian Field Crew A"
      and w["estimate_usd"] == "8400.00" and not w["approved_budget_usd"] and w["sched_ok"] == "t" and w["created_by"] == "MRE-4101"
      and "MRE-WO-1001" in w["symptom"], w)
check("audit WO_CREATED for MRE-WO-1101", n(f"SELECT count(*) FROM agent_audit WHERE event_type = 'WO_CREATED' AND subject_id = {lit(w47_wo)}") == 1)
c = confirm(jolene, p["proposal_id"])
check("confirming twice -> ALREADY_DONE, still one work order",
      c["outcome"] == "ALREADY_DONE" and n("SELECT count(*) FROM work_orders WHERE asset_id = 'PUMP-PB-W47' AND status <> 'CLOSED'") == 1, c)
p = propose(jolene, "PUMP-PB-W47")
check("W47 again -> BLOCKED OPEN_WO_EXISTS", p["outcome"] == "BLOCKED" and p["reason_code"] == "OPEN_WO_EXISTS" and w47_wo in p["reason_text"], p)
p = propose(jolene, "PUMP-PB-W33", "", "")
check("asset in MAINTENANCE -> BLOCKED ASSET_IN_MAINTENANCE (mentions its work order)",
      p["outcome"] == "BLOCKED" and p["reason_code"] == "ASSET_IN_MAINTENANCE" and "MRE-WO-1029" in p["reason_text"] and not p["proposal_id"], p)
blocked_pid = val("SELECT proposal_id FROM pending_actions WHERE asset_id = 'PUMP-PB-W33'")
c = confirm(jolene, blocked_pid)
check("confirming a BLOCKED proposal -> BLOCKED, nothing created",
      c["outcome"] == "BLOCKED" and c["reason_code"] == "ASSET_IN_MAINTENANCE" and n("SELECT count(*) FROM work_orders WHERE asset_id = 'PUMP-PB-W33'") == 2, c)
p = propose(jolene, "VALVE-PB-W52")
check("NORMAL asset -> BLOCKED HEALTH_NORMAL", p["outcome"] == "BLOCKED" and p["reason_code"] == "HEALTH_NORMAL", p)
p = propose(jolene, "COMP-PB-S12", "corrosion")
check("unknown failure mode -> FAILURE_MODE_INVALID listing the valid ones",
      p["reason_code"] == "FAILURE_MODE_INVALID" and "bearing_wear" in p["reason_text"], p)
p = propose(jolene, "PUMP-EF-W14")
check("SCOPE: another region's asset -> NOT_FOUND", p["reason_code"] == "NOT_FOUND", p)
p = propose(travis, "PUMP-BK-W21")
check("BK-W21 already has MRE-WO-1028 -> OPEN_WO_EXISTS", p["reason_code"] == "OPEN_WO_EXISTS" and "MRE-WO-1028" in p["reason_text"], p)
p = propose(jolene, "COMP-PB-S12", "", "Discharge temperature critical, vibration rising")
check("S12 overhaul -> PROPOSED, URGENT, $68,000, needs supervisor approval, says so",
      p["outcome"] == "PROPOSED" and p["needs_supervisor_approval"] == "yes" and p["estimate_usd"] == "$68,000.00" and p["priority"] == "URGENT"
      and "Production Engineering" in p["summary"], p)
c = confirm(jolene, p["proposal_id"])
s12_case = c["case_id"] or ""
check("confirm above the $25,000 limit -> SUPERVISOR_APPROVAL with a case, no work order",
      c["outcome"] == "SUPERVISOR_APPROVAL" and s12_case.startswith("MRE-CASE-") and not c["work_order"]
      and n("SELECT count(*) FROM work_orders WHERE asset_id = 'COMP-PB-S12' AND status <> 'CLOSED'") == 0, c)
sc = psql(f"SELECT * FROM service_cases WHERE case_id = {lit(s12_case)}")[0]
check("DB: supervisor_approval case, requested 68000, parked WORK_ORDER:<proposal>, opened by Jolene",
      sc["request_type"] == "supervisor_approval" and sc["requested_amount"] == "68000.00"
      and sc["parked_action"] == "WORK_ORDER:" + p["proposal_id"] and sc["opened_by"] == "MRE-4101", sc)
p = propose(jolene, "COMP-PB-S12")
check("S12 while the budget case is open -> OPEN_WO_EXISTS (waiting for supervisor approval)",
      p["reason_code"] == "OPEN_WO_EXISTS" and s12_case in p["reason_text"], p)
p = propose(elena, "PUMP-EF-W14", "bearing_wear", "Saddle bearing squeal")
check("EF-W14 CRITICAL -> PROPOSED URGENT $8,400", p["outcome"] == "PROPOSED" and p["priority"] == "URGENT", p)
psql("UPDATE assets SET status = 'MAINTENANCE' WHERE asset_id = 'PUMP-EF-W14'")
c = confirm(elena, p["proposal_id"])
check("confirm re-checks: asset went into MAINTENANCE meanwhile -> BLOCKED", c["outcome"] == "BLOCKED" and c["reason_code"] == "ASSET_IN_MAINTENANCE", c)
psql("UPDATE assets SET status = 'OPERATIONAL' WHERE asset_id = 'PUMP-EF-W14'")
psql("UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE asset_id = 'PUMP-EF-W14'")
c = confirm(elena, p["proposal_id"])
check("proposal older than 15 minutes -> EXPIRED, nothing created",
      c["outcome"] == "EXPIRED" and n("SELECT count(*) FROM work_orders WHERE asset_id = 'PUMP-EF-W14' AND status <> 'CLOSED'") == 0, c)
p = propose(elena, "PUMP-EF-W14", "bearing_wear", "Saddle bearing squeal")
c = confirm(elena, p["proposal_id"])
check("fresh proposal after expiry -> EXECUTED", p["proposal_id"] and c["outcome"] == "EXECUTED", c)

# ---------------------------------------------------------------- alert log (dedupe per asset per day)
a = one("log_alert", session_token=jolene, asset_id="PUMP-PB-W47")
w47_alert = a["alert_id"] or ""
check("W47 -> LOGGED, severity WARNING from SQL, message from the classifier",
      a["outcome"] == "LOGGED" and a["severity"] == "WARNING" and "bearing" in a["message"].lower() and "85%" in a["message"], a)
a = one("log_alert", session_token=jolene, asset_id="PUMP-PB-W47")
check("same asset same day -> ALREADY_LOGGED_TODAY, the same alert, no duplicate",
      a["outcome"] == "ALREADY_LOGGED_TODAY" and a["alert_id"] == w47_alert and n("SELECT count(*) FROM alerts WHERE asset_id = 'PUMP-PB-W47'") == 1, a)
a = one("log_alert", session_token=jolene, asset_id="VALVE-PB-W52")
check("NORMAL asset -> HEALTH_NORMAL, no alert", a["outcome"] == "HEALTH_NORMAL" and n("SELECT count(*) FROM alerts WHERE asset_id = 'VALVE-PB-W52'") == 0, a)
a = one("log_alert", session_token=elena, asset_id="PUMP-EF-W14")
check("the monitoring system already alerted EF-W14 today -> ALREADY_LOGGED_TODAY ALR-000092",
      a["outcome"] == "ALREADY_LOGGED_TODAY" and a["alert_id"] == "ALR-000092", a)
check("SCOPE: alert on another region's asset -> NOT_FOUND", one("log_alert", session_token=jolene, asset_id="PUMP-EF-W14")["outcome"] == "NOT_FOUND")
a = one("log_alert", session_token=jolene, asset_id="COMP-PB-S12")
check("S12 -> LOGGED CRITICAL", a["outcome"] == "LOGGED" and a["severity"] == "CRITICAL", a)
check("audit ALERT_LOGGED for the 2 control-room alerts", n("SELECT count(*) FROM agent_audit WHERE event_type = 'ALERT_LOGGED'") == 2)

# ---------------------------------------------------------------- human-owned cases
def open_case(tok, typ, asset, summary="Neutral summary from the operator.", brief=""):
    return one("open_service_case", session_token=tok, request_type=typ, asset_id=asset, summary=summary, agent_brief=brief)


r = open_case(jolene, "shut_in", "COMP-PB-S12", "Discharge temperature critical; requesting an emergency shutdown of the compressor.")
shut_case = r["case_id"] or ""
check("shut-in -> OPENED with Production Engineering, the asset is NOT shut in by the model",
      r["outcome"] == "OPENED" and r["team"] == "Production Engineering" and shut_case
      and val("SELECT status FROM assets WHERE asset_id = 'COMP-PB-S12'") == "OPERATIONAL"
      and val(f"SELECT parked_action FROM service_cases WHERE case_id = {lit(shut_case)}") == "SHUT_IN:COMP-PB-S12", r)
r = open_case(jolene, "Shut-in", "COMP-PB-S12")
check("same request again -> EXISTING (same case)", r["outcome"] == "EXISTING" and r["case_id"] == shut_case, r)
check("unknown request type -> INVALID_TYPE", open_case(jolene, "restart_well", "COMP-PB-S12")["outcome"] == "INVALID_TYPE")
check("supervisor_approval cannot be opened directly -> INVALID_TYPE",
      open_case(jolene, "supervisor_approval", "PUMP-PB-W47")["outcome"] == "INVALID_TYPE")
r = open_case(jolene, "alert_closure", "PUMP-PB-W47", "Close the W47 alert: the bearing work order is scheduled.")
close_case = r["case_id"] or ""
check("alert closure -> OPENED, parked on the asset's open alert",
      r["outcome"] == "OPENED" and val(f"SELECT parked_action FROM service_cases WHERE case_id = {lit(close_case)}") == "ALERT_CLOSE:" + w47_alert, r)
r = open_case(jolene, "alert_closure", "PUMP-PB-W48")
check("alert closure with no open alert -> BLOCKED NO_OPEN_ALERT", r["outcome"] == "BLOCKED" and r["reason_code"] == "NO_OPEN_ALERT", r)
r = open_case(jolene, "threshold-change", "PUMP-PB-W47", "Vibration warning line feels low for this older unit.")
thr_case = r["case_id"] or ""
check("'threshold-change' normalises -> OPENED", r["outcome"] == "OPENED" and thr_case, r)
check("SCOPE: case on another region's asset -> NOT_FOUND", open_case(jolene, "shut_in", "PUMP-BK-W21")["reason_code"] == "NOT_FOUND")
my = call("get_my_cases", session_token=jolene)
ids = {x["case_id"] for x in my}
check("Jolene's cases: her region only (incl. the budget case and the safety case), not the seeded Bakken/Eagle Ford ones",
      {s12_case, odor_case, shut_case} <= ids and not ({"MRE-CASE-000101", "MRE-CASE-000102", "MRE-CASE-000103"} & ids), ids)
row = next(x for x in my if x["case_id"] == s12_case)
check("open budget case: requested $68,000, message says a person will decide",
      row["requested_budget_usd"] == "$68,000.00" and "Production Engineering" in row["customer_message"] and row["case_status"] == "OPEN", row)
check("Travis sees the seeded Bakken cases", {"MRE-CASE-000101", "MRE-CASE-000102"} <= {x["case_id"] for x in call("get_my_cases", session_token=travis)})

# ---------------------------------------------------------------- the reviewer loop
q = call("get_review_queue", session_token=wade)
qids = [x["case_id"] for x in q]
check("Production Engineering queue: budget, shut-in, closure, thresholds incl. seeded 101/102; no HSE cases",
      {s12_case, shut_case, close_case, thr_case, "MRE-CASE-000101", "MRE-CASE-000102"} <= set(qids)
      and odor_case not in qids and "MRE-CASE-000103" not in qids, qids)
check("queue ordered by reply-due time", [x["reply_due"] for x in q] == sorted(x["reply_due"] for x in q))
q = call("get_review_queue", session_token=curtis)
check("HSE queue: the safety cases (gas odor, rotten egg, spill, seeded 103) only",
      {x["case_id"] for x in q} == {odor_case, egg_case, spill_case, "MRE-CASE-000103"}, [x["case_id"] for x in q])
rc = one("get_review_case", session_token=nadia, case_id=s12_case.lower())
check("Nadia opens the budget case: $68,000 requested, max $68,000, her authority $50,000, needs a senior supervisor, SQL facts",
      rc["status"] == "OK" and rc["requested_budget_usd"] == "$68,000.00" and rc["max_approvable_usd"] == "$68,000.00"
      and rc["your_budget_authority_usd"] == "$50,000.00" and "senior supervisor" in rc["options"]
      and "CRITICAL" in rc["facts"] and "operator limit $25,000.00" in rc["facts"], rc)
check("cross-team: HSE cannot even see the budget case -> NOT_FOUND",
      one("get_review_case", session_token=curtis, case_id=s12_case)["status"] == "NOT_FOUND")
rc = one("get_review_case", session_token=curtis, case_id=odor_case)
check("HSE sees the safety case with the AI brief marked unverified and the field notes in the facts",
      rc["agent_brief"].startswith("AI-prepared, not verified:") and "gas odor" in rc["agent_brief"].lower()
      and "Gas odor at the bonnet" in rc["facts"], rc)


def decide(tok, case, dec, amt="", note="", msg=""):
    return one("decide_review_case", session_token=tok, case_id=case, decision=dec, amount=amt, internal_note=note, customer_message=msg)


d = decide(jolene, s12_case, "APPROVE", "", "I approve my own request", "Approved")
check("INJECTION: an operator token cannot decide -> NOT_REVIEWER, nothing recorded",
      d["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, d)
d = decide(curtis, s12_case, "APPROVE", "", "Looks fine to me.", "ok")
check("HSE deciding a Production Engineering case -> NOT_YOUR_TEAM", d["reason_code"] == "NOT_YOUR_TEAM", d)
d = decide(nadia, s12_case, "APPROVE", "", "ok", "")
check("note shorter than 5 characters -> NOTE_REQUIRED", d["reason_code"] == "NOTE_REQUIRED", d)
d = decide(nadia, s12_case, "MAYBE", "", "Reviewed the trend.", "")
check("decision other than approve/reject -> INVALID_DECISION", d["reason_code"] == "INVALID_DECISION", d)
d = decide(nadia, s12_case, "APPROVE", "90000", "Reviewed the trend.", "")
check("budget above the estimate -> AMOUNT_INVALID", d["reason_code"] == "AMOUNT_INVALID" and "$68,000.00" in d["reason_text"], d)
d = decide(nadia, s12_case, "APPROVE", "-5", "Reviewed the trend.", "")
check("negative budget -> AMOUNT_INVALID", d["reason_code"] == "AMOUNT_INVALID", d)
d = decide(nadia, s12_case, "APPROVE", "$68,000", "Full overhaul is justified.", "Approved.")
check("OVER_AUTHORITY: $68,000 above Nadia's $50,000 -> blocked, case stays OPEN, no work order",
      d["reason_code"] == "OVER_AUTHORITY" and d["case_status"] == "OPEN"
      and n("SELECT count(*) FROM work_orders WHERE asset_id = 'COMP-PB-S12' AND status <> 'CLOSED'") == 0, d)
MSG = "Approved with a $60,000 budget: top-end overhaul and cooler repair this week."
NOTE = "Top end plus cooler; defer the second-stage valves to the next turnaround."
d = decide(wade, s12_case, "APPROVE", "60k", NOTE, MSG)
check("Wade approves an amended $60,000 budget -> APPROVED, work order created by the trigger",
      d["outcome"] == "APPROVED" and d["approved_budget_usd"] == "$60,000.00" and "Work order created: MRE-WO-" in d["executed_action"]
      and "budget $60,000.00" in d["executed_action"], d)
w = psql(f"SELECT * FROM work_orders WHERE case_id = {lit(s12_case)}")
check("DB: S12 work order: budget 60000, estimate 68000, URGENT, approved by Wade, opened by Jolene, linked to the case",
      len(w) == 1 and w[0]["approved_budget_usd"] == "60000.00" and w[0]["estimate_usd"] == "68000.00" and w[0]["priority"] == "URGENT"
      and w[0]["approved_by"] == "MRE-7101" and w[0]["created_by"] == "MRE-4101" and w[0]["asset_id"] == "COMP-PB-S12", w)
s12_wo = w[0]["wo_number"] if w else ""
check("DB: decision row + CASE_DECIDED audit naming the executed work order",
      n(f"SELECT count(*) FROM review_decisions WHERE case_id = {lit(s12_case)} AND reviewer_id = 'MRE-7101' AND decision = 'APPROVE' AND approved_amount = 60000") == 1
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type = 'CASE_DECIDED' AND subject_id = {lit(s12_case)} AND detail LIKE '%executed: work order%'") == 1)
d = decide(wade, s12_case, "APPROVE", "", "Second try at it.", "x")
check("deciding twice -> ALREADY_DECIDED, still one work order",
      d["reason_code"] == "ALREADY_DECIDED" and n(f"SELECT count(*) FROM work_orders WHERE case_id = {lit(s12_case)}") == 1, d)
row = next(x for x in call("get_my_cases", session_token=jolene) if x["case_id"] == s12_case)
check("Jolene sees APPROVED, $60,000 and the reviewer's message (no note, no reviewer name)",
      row["case_status"] == "APPROVED" and row["approved_budget_usd"] == "$60,000.00" and row["customer_message"] == MSG
      and NOTE not in str(row) and "Hollister" not in str(row), row)
d = decide(wade, shut_case, "REJECT", "", "The overhaul work order covers the temperature.", "Not shut in: the overhaul addresses the temperature.")
check("REJECT executes nothing: S12 stays OPERATIONAL, no shut-in event",
      d["outcome"] == "REJECTED" and d["executed_action"] == "Case rejected; nothing was executed."
      and val("SELECT status FROM assets WHERE asset_id = 'COMP-PB-S12'") == "OPERATIONAL" and n("SELECT count(*) FROM asset_events") == 0, d)
d = decide(curtis, odor_case, "APPROVE", "", "Send the crew with gas detectors; isolate if confirmed.",
           "HSE approved an emergency safety inspection of VALVE-PB-W52 today.")
w = psql("SELECT * FROM work_orders WHERE asset_id = 'VALVE-PB-W52' AND wo_type = 'SAFETY_INSPECTION'")
check("HSE approves the gas-odor case -> EMERGENCY safety-inspection work order (approved by Curtis, $0 estimate)",
      d["outcome"] == "APPROVED" and len(w) == 1 and w[0]["priority"] == "EMERGENCY" and w[0]["approved_by"] == "MRE-8101"
      and w[0]["case_id"] == odor_case and "SAFETY_INSPECTION" in d["executed_action"], (d, w))
d = decide(curtis, egg_case, "APPROVE", "500", "Sour gas check with the H2S team.", "HSE is sending a sour-gas inspection.")
check("amount is ignored on a case without a budget", d["outcome"] == "APPROVED" and not d["approved_budget_usd"], d)
r = open_case(jolene, "safety_signal", "VALVE-PB-W52", "Crew reports the odor again after the inspection was booked.")
again_case = r["case_id"] or ""
d = decide(curtis, again_case, "APPROVE", "", "Duplicate of the open inspection.", "x")
check("NOT_READY: a safety inspection is already open on W52 -> blocked, case stays OPEN",
      r["outcome"] == "OPENED" and d["reason_code"] == "NOT_READY" and d["case_status"] == "OPEN", (r, d))
r = open_case(travis, "shut_in", "PUMP-BK-W21", "Seal leak worsening; request shut-in until the seal job.")
bk_shut = r["case_id"] or ""
d = decide(wade, bk_shut, "APPROVE", "", "Shut in until MRE-WO-1028 completes.", "Approved: PUMP-BK-W21 is shut in until the seal job is done.")
check("approved shut-in executes: BK-W21 SHUT_IN, asset event, SHUT_IN audit",
      d["outcome"] == "APPROVED" and "SHUT_IN" in d["executed_action"] and val("SELECT status FROM assets WHERE asset_id = 'PUMP-BK-W21'") == "SHUT_IN"
      and n(f"SELECT count(*) FROM asset_events WHERE case_id = {lit(bk_shut)}") == 1
      and n("SELECT count(*) FROM agent_audit WHERE event_type = 'SHUT_IN'") == 1, d)
check("a SHUT_IN asset -> work order BLOCKED ASSET_SHUT_IN", propose(travis, "PUMP-BK-W21")["reason_code"] == "ASSET_SHUT_IN")
bk_shut2 = open_case(travis, "shut_in", "PUMP-BK-W21", "Shut in again?")["case_id"] or ""
d = decide(wade, bk_shut2, "APPROVE", "", "Checking a duplicate.", "x")
check("shut-in of an asset already SHUT_IN -> NOT_READY", d["reason_code"] == "NOT_READY", d)
d = decide(wade, close_case, "APPROVE", "", "Bearing job scheduled; alert no longer needed.", "The W47 alert is closed.")
check("approved alert closure closes the alert (event + audit)",
      d["outcome"] == "APPROVED" and val(f"SELECT status FROM alerts WHERE alert_id = {lit(w47_alert)}") == "CLOSED"
      and n("SELECT count(*) FROM agent_audit WHERE event_type = 'ALERT_CLOSED'") == 1, d)
d = decide(nadia, "MRE-CASE-000102", "APPROVE", "", "Acknowledged and the seal job is under way.", "ALR-000091 is closed.")
check("seeded alert-closure case approved by Nadia -> ALR-000091 CLOSED",
      d["outcome"] == "APPROVED" and val("SELECT status FROM alerts WHERE alert_id = 'ALR-000091'") == "CLOSED", d)
d = decide(wade, "MRE-CASE-000101", "APPROVE", "", "OK for the new skid mount; engineering will update the table.", "Approved; the threshold table will be updated by engineering.")
check("threshold change approved -> recorded only, the threshold table is unchanged",
      d["outcome"] == "APPROVED" and "no automatic action" in d["executed_action"]
      and val("SELECT warn_high FROM sensor_thresholds WHERE sensor = 'vibration'") == "3.50", d)
check("decide on an unknown case -> NOT_FOUND", decide(wade, "MRE-CASE-999999", "APPROVE", "", "Some note here.", "")["reason_code"] == "NOT_FOUND")

# ---------------------------------------------------------------- guarded email
e = one("email_asset_summary", session_token=jolene, asset_id="COMP-PB-S12")
check("email for S12 -> SEND_OK, body from SQL: the work order, the $60,000 budget, the case, AI disclosure, no internal note",
      e["send_status"] == "SEND_OK" and s12_wo in e["body"] and "$60,000.00" in e["body"] and s12_case in e["body"]
      and "AI assistant" in e["body"] and NOTE not in e["body"], e)
e = one("email_asset_summary", session_token=travis, asset_id="VALVE-BK-W03")
check("nothing done on BK-W03 -> NOT_SENT NOTHING_TO_SEND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOTHING_TO_SEND", e)
e = one("email_asset_summary", session_token=jolene, asset_id="PUMP-EF-W14")
check("SCOPE: email for another region's asset -> NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
check("exactly 1 email logged", n("SELECT count(*) FROM email_log") == 1)

# ---------------------------------------------------------------- session expiry
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(jolene)}")
check("expired operator token -> SESSION_INVALID", one("get_region_assets", session_token=jolene)["status"] == "SESSION_INVALID")
check("expired token cannot propose", propose(jolene, "PUMP-PB-W48")["outcome"] == "SESSION_INVALID")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(curtis)}")
check("expired reviewer token -> NOT_REVIEWER", one("get_review_queue", session_token=curtis)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- hidden data never leaves the DB
op_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
leaked = sorted({k for _, rows in op_out for row in rows for k in row} & HIDDEN_COLUMNS)
check("no operator tool output has a hidden column", not leaked, leaked)
oblob = "\n".join(str(v) for _, rows in op_out for row in rows for v in row.values())
secrets = [x["v"] for x in psql("SELECT internal_note v FROM review_decisions UNION ALL SELECT display_name FROM reviewers "
                                "UNION ALL SELECT one_time_code FROM operators UNION ALL SELECT one_time_code FROM reviewers "
                                "UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL "
                                "UNION ALL SELECT control_phone FROM sites")]
check("operator outputs never contain internal notes, reviewer names, codes, agent briefs or desk phones",
      not any(s and s in oblob for s in secrets), [s for s in secrets if s and s in oblob][:3])
rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
check("reviewer outputs: no one-time codes", not rleak, rleak)
texts = [str(row.get(k) or "") for _, rows in op_out for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the model|LLM|the assistant|the user)\b", t, re.I)]
check("operator-facing texts address the operator (never the model)", not bad, bad[:3])
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT staff_id v FROM operators UNION SELECT display_name FROM operators UNION SELECT one_time_code FROM operators "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT control_phone FROM sites UNION SELECT case_id FROM service_cases UNION SELECT session_token FROM sessions "
    "UNION SELECT asset_id FROM assets UNION SELECT wo_number FROM work_orders UNION SELECT alert_id FROM alerts "
    "UNION SELECT note_id FROM field_notes "
    "UNION SELECT unnest(string_to_array(display_name, ' ')) FROM operators "
    "UNION SELECT unnest(string_to_array(display_name, ' ')) FROM reviewers")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity / equipment value list for the leak scan is non-trivial", len(ID_VALUES) > 40, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_field_note_guide": ("rotten-egg", "H2S / sour gas", "shorthand", 6),
    "get_failure_matching_guide": ("megger", "megger", "match level", 4),
    "get_handover_format_guide": ("acknowledged", "ACKNOWLEDGED", "standard line", 5),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["field_note_triage_agent", "similar_failure_agent", "shift_handover_agent"])
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
    check(f"{tool}: no staff / reviewer / code / phone / case / session / asset / work-order / alert / note value in the rows",
          not leaked, leaked[:5])
    check(f"{tool}: no staff, case, proposal, asset, work-order, alert, note, email, phone or token pattern",
          not re.search(r"mre-\d|mre-case|mre-prp|mre-sht|mre-wo-\d|alr-\d|fn-\d|\b(pump|comp|valve)-(pb|bk|ef)-|@|555|"
                        r"[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])
    check(f"{tool}: guide stays compact (<= 40 rows, agents usually read it whole)", len(full) <= 40, len(full))

REFT = {t["agent"]: t for t in AGENT_REF_TOOLS}
both = ref_call(REFT["similar_failure_agent"], "megger, gas lock")
check("ref_failure_matching: several words in one call ('megger, gas lock') -> both found",
      {"megger", "gas lock"} <= {r["term"] for r in both}, [r["term"] for r in both])


def check_values(table, col):
    """Values allowed by the CHECK constraint on table.col (the one whose definition starts with that column)."""
    defs = [r["d"] for r in psql(f"SELECT pg_get_constraintdef(c.oid) AS d FROM pg_constraint c "
                                 f"WHERE c.conrelid = '{table}'::regclass AND c.contype = 'c'")]
    d = next((x for x in defs if re.match(r"CHECK \(+" + col + r"\b", x)), "")
    return set(re.findall(r"'([^']+)'::", d))


# --- field_note_triage_agent: field-note guide
fg = ref_call(REFT["field_note_triage_agent"], "")
modes = check_values("failure_modes", "failure_mode")
crew = {r["term"]: r["meaning"] for r in fg if r["section"] == "CREW_CHECK"}
check("ref_field_note_guide: a standard crew check for every failure mode, for 'none' and for safety language",
      len(modes) == 6 and set(crew) == modes | {"none", "safety language"}, sorted(set(crew) ^ (modes | {"none", "safety language"})))
check("ref_field_note_guide: the crew checks are distinct sentences", len(set(crew.values())) == len(crew))
fmr = {r["term"]: r["meaning"] for r in fg if r["section"] == "FAILURE_MODE"}
fms = psql("SELECT asset_type, failure_mode, label FROM failure_modes")
check("ref_field_note_guide: FAILURE_MODE rows come from failure_modes (one per code, every asset type's label listed)",
      set(fmr) == modes and all(f["label"] in fmr[f["failure_mode"]] for f in fms), sorted(fmr))
route = {r["request_type"]: r for r in psql("SELECT request_type, label, team, sla_text FROM case_routing")}
who = [(r["term"], r["meaning"]) for r in fg if r["section"] == "WHO_DECIDES"]
check("ref_field_note_guide: WHO_DECIDES row comes from case_routing safety_signal (one source of truth)",
      who == [(route["safety_signal"]["label"], f"{route['safety_signal']['team']}: {route['safety_signal']['sla_text']}")], who)
bk = next((r["meaning"] for r in fg if r["term"] == "asset system backstop"), "")
words = [w.strip() for w in re.search(r"literal words: (.*?)\. ", bk).group(1).split(",")] if bk else []
alts = val("SELECT pg_get_functiondef('safety_keyword(text)'::regprocedure)")
alts = re.search(r"\\m\((.*)\)\\M", alts).group(1)
depth, top, cur = 0, [], ""
for ch in alts:
    depth += ch == "("; depth -= ch == ")"
    if ch == "|" and depth == 0:
        top.append(cur); cur = ""
    else:
        cur += ch
top.append(cur)
kw_hits = {w: val(f"SELECT safety_keyword({lit(w)})") for w in words}
check("ref_field_note_guide: the backstop row lists one word per SQL keyword alternative and SQL matches every one of them",
      len(words) == len(top) == 12 and all(kw_hits.values()), (len(words), len(top), [w for w, h in kw_hits.items() if not h]))
not_safe = [r["term"] for r in fg if r["section"] == "NOT_SAFETY"]
check("ref_field_note_guide: the NOT_SAFETY words do not trip the SQL keyword backstop by themselves",
      len(not_safe) == 4 and not any(val(f"SELECT safety_keyword({lit(w)})") for w in not_safe), not_safe)
check("classify_asset and its 4 rule tables are untouched by the agent guides (still the health source of truth)",
      n("SELECT count(*) FROM pg_proc WHERE proname = 'classify_asset'") == 1
      and "field_note_guide" not in val("SELECT pg_get_functiondef('classify_asset(text)'::regprocedure)"))

# --- similar_failure_agent: matching criteria
mg = ref_call(REFT["similar_failure_agent"], "")
lv = {r["term"]: r["meaning"] for r in mg if r["section"] == "MATCH_LEVEL"}
check("ref_failure_matching: the four match levels, each with its standard note",
      set(lv) == {"STRONG", "MODERATE", "WEAK", "NO_MATCH"} and all("Standard note: " in m for m in lv.values()), lv)
terms = {r["term"] for r in mg if r["section"] == "TERM"}
check("ref_failure_matching: the glossary explains at least 8 oilfield failure terms", len(terms) >= 8, sorted(terms))
named = {c for r in mg if r["section"] == "TERM" for c in re.findall(r"\b[a-z]+_[a-z]+\b", r["meaning"])}
check("ref_failure_matching: the failure-mode codes the glossary names are real failure_modes codes",
      bool(named) and named <= modes, sorted(named - modes))

# --- shift_handover_agent: guide
hg = ref_call(REFT["shift_handover_agent"], "")
secs = [r["term"] for r in hg if r["section"] == "SECTION"]
check("ref_handover_guide: 6 handover sections in order",
      secs == ["1 Safety", "2 Asset health", "3 Open work", "4 Alerts", "5 Waiting on people / decisions", "6 Watch items"], secs)
codes = set()
for tb, col in (("service_cases", "status"), ("work_orders", "status"), ("alerts", "status"),
                ("field_notes", "reconciled_action"), ("failure_horizon", "health_status"), ("assets", "status")):
    codes |= check_values(tb, col)
stat = {r["term"] for r in hg if r["section"] == "STATUS"}
check("ref_handover_guide: every status code the handover snapshot can carry is explained in plain words",
      len(codes) == 16 and stat == codes, (sorted(codes), sorted(stat ^ codes)))
prio = check_values("work_orders", "priority")
open_work = next((r["meaning"] for r in hg if r["term"] == "3 Open work"), "")
check("ref_handover_guide: the open-work section orders every work-order priority",
      len(prio) == 4 and all(p in open_work for p in prio), (sorted(prio), open_work))
check("ref_handover_guide: the standard closing line is in the guide",
      any(r["term"] == "closing line" and "statuses as recorded" in r["meaning"] for r in hg))

# nothing from the old static reference text was lost
KEEP = {"get_field_note_guide": ["gas odor", "smell of gas", "h2s", "hydrogen sulfide", "sour gas", "rotten-egg smell",
                                 "gas monitor alarming, beeping or chirping", "burning eyes or throat near equipment",
                                 "a spill", "pooling fluid", "a sheen on water or ground", "a stain spreading under a flange",
                                 "fluid spraying or misting|well fluid or oil spraying or misting", "fire, flames, smoke, scorching or an electrical arc",
                                 "an injury", "dizzy or sick", "a near miss", "an uncontrolled release",
                                 "a hissing leak that is getting louder", "a blowout",
                                 "a pressure release that will not stop", "when in doubt, say yes - hse decides",
                                 "a false alarm costs little", "misfire", "hot or running hot",
                                 "weeping or seeping packing with no fluid on the ground", "strokes per minute",
                                 "fluid pound / pump-off", "low fillage", "horsehead, walking beam, saddle bearing, wrist pin, gearbox",
                                 "stuffing box and polished rod are its wellhead seal", "electric submersible pump",
                                 "seal or protector section, gas separator, intake, drive",
                                 "scrubber, rod packing, cooler / fin fan, throw", "bonnet, stem packing, gate, seat, actuator"],
        "get_failure_matching_guide": ["match on the failing component and the way it fails, not on wording",
                                       "'growl from the gearbox on every downstroke'",
                                       "'high-pitched squeal from the saddle bearing'", "both rod-pump bearing wear",
                                       "'polished rod running hot, oil weeping at the stuffing box' is a seal leak",
                                       "even though both mention heat", "the same failure mode and the same component",
                                       "the same failure mode on a different component of the same machine",
                                       "a shared symptom only (noise, heat)", "only when nothing better exists",
                                       "rank strong first", "the most recent first",
                                       "copy the fix and the parts exactly as recorded", "never improve or combine them",
                                       "a past fix is a reference for the crew, not an instruction"],
        "get_handover_format_guide": ["safety first", "open case waiting for hse", "status is safety_case",
                                      "critical assets, then warning assets", "the worst sensor",
                                      "the likely failure mode and the days to failure as given",
                                      "emergency, then urgent, then high, then routine", "with the crew and the scheduled date",
                                      "alerts that are not closed", "team and reply-due time",
                                      "decisions made in the last 24 hours", "a case is named by its request type, e.g. shut-in",
                                      "at most 3 things the next shift must chase", "mre-wo-...", "alr-...",
                                      "no people's names", "each line one sentence", "at most 20 lines in total",
                                      "never state that an asset or a site is safe", "only report statuses as given"]}
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
