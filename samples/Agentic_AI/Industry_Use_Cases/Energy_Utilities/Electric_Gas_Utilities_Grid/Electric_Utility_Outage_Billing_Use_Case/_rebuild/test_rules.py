#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the power_distribution_governed DB and
assert the business rules on DB state, plus the A2A agents' read-only reference tools (ref_* functions:
filtering, unknown input, no personal data, SELECT-only). No Flogo needed. Re-loads reset_data.sql first and again at the end.

  python _rebuild/test_rules.py
Password: env PG_PWD, else PG_PASSWORD from the nearest skills-library/.claude/skills/config.md (never printed).
Env overrides: PSQL, PG_HOST, PG_PORT, PG_USER, PG_DB, CONFIG_MD.
"""
import csv, io, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, CUSTOMER_HIDDEN, CUSTOMER_TOOLS, AGENT_REF_TOOLS, REF_COLUMNS

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
        or sys.exit("psql not found: install the PostgreSQL client and put psql on PATH, or set env PSQL / config.md PSQL_PATH"))
ENV = dict(os.environ, PGPASSWORD=PWD)
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "power_distribution_governed"),
        "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = passes = 0
OUTPUTS = []          # every tool read result, for the hidden-column scan


def lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def sub(sql, params, args):
    """Substitute ?name exactly like the Flogo wi-postgres activity: only when followed by ` ;),<>+-*%/`."""
    assert sorted(re.findall(r"\?(\w+)", sql)) == sorted(p for p, _ in params), sql
    for ph, arg in params:
        sql, k = re.subn(r"\?" + ph + r"(?=[\s;),<>+\-*%/])", lambda _m: lit(args.get(arg, "")), sql)
        assert k == 1, f"placeholder ?{ph} used {k} times"
    return sql


def psql(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV, encoding="utf-8")
    if r.returncode:
        print(r.stderr.encode("ascii", "replace").decode()); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))


def call(tool, **args):
    t = T[tool]
    assert set(args) == {a for a, _ in t["args"]}, (tool, args)
    if "write" in t:
        psql(sub(*t["write"], args))
    rows = psql(sub(*t["read"], args))
    OUTPUTS.append((tool, rows))
    return rows


def one(tool, **args):
    return call(tool, **args)[0]


def n(sql):
    return int(list(psql(sql)[0].values())[0])


def val(sql):
    return list(psql(sql)[0].values())[0]


def check(label, cond, detail=""):
    global fails, passes
    msg = ("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:600]}")
    print(msg.encode("ascii", "replace").decode())
    if cond: passes += 1
    else: fails += 1


def reset():
    subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


def f2(v):
    try: return round(float(v), 2)
    except (TypeError, ValueError): return None


BAD = "bogus-token-0000"
LAURA, MARCUS, PRIYA, GRACE, HENRY, OLIVIA, SAMUEL, NATHAN, ETHAN, MARIA, DIANE = (
    "RPL-100101", "RPL-100102", "RPL-100103", "RPL-100106", "RPL-100107", "RPL-100108", "RPL-100109", "RPL-100113",
    "RPL-100115", "RPL-100116", "RPL-100104")

reset()
try:
    # ------------------------------------------------------------ contract shape
    check("22 MCP tools", len(TOOLS) == 22, [t["tool"] for t in TOOLS])
    check("tool names unique", len({t["tool"] for t in TOOLS}) == 22)
    check("every write is INSERT ... SELECT (never VALUES)",
          all(re.match(r"INSERT INTO \w+ \([^)]*\) SELECT ", t["write"][0]) and "VALUES" not in t["write"][0].upper()
              for t in TOOLS if "write" in t))
    check("write placeholders ?w_*, read placeholders not ?w_*",
          all(all(p.startswith("w_") for p, _ in t["write"][1]) for t in TOOLS if "write" in t)
          and all(not p.startswith("w_") for t in TOOLS for p, _ in t["read"][1]))
    check("no ?param::type casts (wi-postgres tokenizer trap)",
          not any(re.search(r"\?\w+::", t.get("write", ("", []))[0] + t["read"][0]) for t in TOOLS))
    check("reads are readOnly, writes are not", all(t["readonly"] == ("write" not in t) for t in TOOLS),
          [t["tool"] for t in TOOLS if t["readonly"] != ("write" not in t)])

    # ------------------------------------------------------------ identity
    r = one("verify_customer", account_number="RPL-100101", code="1111")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
    check("wrong code -> no session row", n(f"SELECT count(*) FROM sessions WHERE principal_id='{LAURA}'") == 0)
    tok = {}
    for who, acct, code in [(LAURA, "100101", "4821"), (MARCUS, "RPL 100102", "6634"), (PRIYA, "rpl-100103", "5577"),
                            (GRACE, "RPL-100106", "9164"), (HENRY, "Account RPL-100107", "7305"),
                            (OLIVIA, "RPL-100108", "8150"), (ETHAN, "RPL-100115", "3388"), (MARIA, "RPL-100116", "2210")]:
        r = one("verify_customer", account_number=acct, code=code)
        tok[who] = r["session_token"]
        check(f"verify {acct!r} -> VERIFIED", r["outcome"] == "VERIFIED" and len(r["session_token"] or "") > 20, r)
    TL, TM, TP, TG, TH, TO, TE, TMA = (tok[x] for x in (LAURA, MARCUS, PRIYA, GRACE, HENRY, OLIVIA, ETHAN, MARIA))
    check("verify returns the first name", one("verify_customer", account_number="100101", code="4821")["first_name"] == "Laura")
    for _ in range(5):
        one("verify_customer", account_number="RPL-100109", code="0000")
    r = one("verify_customer", account_number="RPL-100109", code="6021")
    check("throttle: 5 failures then the right code -> VERIFY_LOCKED, no token", r["outcome"] == "VERIFY_LOCKED" and not r["session_token"], r)
    check("throttle: no session for the locked account", n(f"SELECT count(*) FROM sessions WHERE principal_id='{SAMUEL}'") == 0)

    for t in TOOLS:
        if t["tool"] in CUSTOMER_TOOLS and t["readonly"]:
            args = {a: (BAD if a == "session_token" else "X") for a, _ in t["args"]}
            r = call(t["tool"], **args)
            check(f"{t['tool']}: forged token -> SESSION_INVALID", r and r[0].get("status") == "SESSION_INVALID", r[:1])

    # ------------------------------------------------------------ scoped reads
    r = one("get_my_account", session_token=TL)
    check("account: Laura, STANDARD, SMART, CONNECTED, no past due",
          r["account_number"] == LAURA and r["plan_code"] == "STANDARD" and r["meter_type"] == "SMART"
          and r["connection_status"] == "CONNECTED" and f2(r["past_due_amount"]) == 0, r)
    r = one("get_my_account", session_token=TH)
    check("account: Henry DISCONNECTED, $142.48 past due, 43+ days",
          r["connection_status"] == "DISCONNECTED" and f2(r["past_due_amount"]) == 142.48 and int(r["days_past_due"]) >= 30, r)
    bills = call("get_my_bills", session_token=TL)
    check("bills: Laura has 3, newest $125.19 UNPAID", len(bills) == 3 and f2(bills[0]["total"]) == 125.19
          and bills[0]["bill_status"] == "UNPAID", bills)
    LB = bills[0]["bill_id"]
    hb = call("get_my_bills", session_token=TH)
    check("bills: Henry's oldest bill PAST_DUE", hb[-1]["bill_status"] == "PAST_DUE", hb)
    r = call("get_bill_detail", session_token=TL, bill_id=LB)
    check("bill detail: Laura's lines sum to the total",
          r[0]["status"] == "OK" and round(sum(float(x["amount"]) for x in r), 2) == 125.19, r)
    r = call("get_bill_detail", session_token=TL, bill_id=hb[0]["bill_id"])
    check("SCOPE: Henry's bill via Laura's token -> NOT_FOUND, no lines", len(r) == 1 and r[0]["status"] == "NOT_FOUND"
          and not r[0]["amount"], r)
    cmp_ = {x["category"]: x for x in call("get_bill_comparison", session_token=TL)}
    e = cmp_.get("energy", {})
    check("comparison: totals 105.92 -> 125.19, energy +13.95, kWh +53% vs last year, CDD 610 vs 455",
          f2(e.get("previous_total")) == 105.92 and f2(e.get("latest_total")) == 125.19 and f2(e.get("delta")) == 13.95
          and e.get("kwh_change_vs_last_year_pct") == "53" and e.get("cooling_degree_days") == "610"
          and e.get("cooling_degree_days_last_year") == "455", e)
    check("comparison: 6 categories", len(cmp_) == 6, list(cmp_))
    g = call("get_bill_comparison", session_token=TG)
    check("comparison: Grace's latest read is ESTIMATED, 1,700 kWh vs 1,150", g[0]["latest_read_type"] == "ESTIMATED"
          and g[0]["latest_kwh"] == "1700" and g[0]["same_month_last_year_kwh"] == "1150", g[0])
    u = call("get_my_usage", session_token=TL)
    check("usage: Laura 3 months, on-peak share 25%", len(u) == 3 and u[0]["on_peak_share_pct"] == "25", u[0])
    u = call("get_my_usage", session_token=TG)
    check("usage: analog meter has no on/off-peak split", u[0]["on_peak_kwh"] == "" and u[0]["read_type"] == "ESTIMATED", u[0])
    p = call("get_my_payments", session_token=TH)
    check("payments: Henry past_due yes $142.48", p[0]["past_due"] == "yes" and f2(p[0]["past_due_amount"]) == 142.48, p[0])
    po = {x["plan_code"]: x for x in call("get_plan_options", session_token=TL)}
    check("plan options: Laura EV est $74.27, saves $5.88, eligible; current STANDARD $80.15",
          f2(po["EV"]["est_monthly_cost"]) == 74.27 and f2(po["EV"]["est_monthly_savings"]) == 5.88
          and po["EV"]["eligible"] == "yes" and po["STANDARD"]["is_current"] == "yes"
          and f2(po["STANDARD"]["est_monthly_cost"]) == 80.15, po.get("EV"))
    check("plan options: Laura SOLAR -> NO_SOLAR, STANDARD -> NO_CHANGE",
          po["SOLAR"]["reason_code"] == "NO_SOLAR" and po["STANDARD"]["reason_code"] == "NO_CHANGE", po)
    po = {x["plan_code"]: x for x in call("get_plan_options", session_token=TG)}
    check("plan options: Grace (analog) TOU/EV -> SMART_METER_REQUIRED", po["TOU"]["reason_code"] == "SMART_METER_REQUIRED"
          and po["EV"]["reason_code"] == "SMART_METER_REQUIRED" and po["TOU"]["eligible"] == "no", po["TOU"])
    po = {x["plan_code"]: x for x in call("get_plan_options", session_token=TM)}
    check("plan options: Marcus (change scheduled) -> CHANGE_PENDING", po["STANDARD"]["reason_code"] == "CHANGE_PENDING", po["STANDARD"])
    o = call("get_area_outages", session_token=TL)
    check("outages: Oak Hollow storm OUT-2026-0041 restoring", o[0]["outage_id"] == "OUT-2026-0041"
          and o[0]["outage_status"] == "RESTORING", o)
    check("outages: Olivia (Cedar Bluff) -> NO_KNOWN_OUTAGE", one("get_area_outages", session_token=TO)["status"] == "NO_KNOWN_OUTAGE")
    check("outages: a RESTORED outage is not listed (Grace)", one("get_area_outages", session_token=TG)["status"] == "NO_KNOWN_OUTAGE")
    check("outages: planned outage listed for Mesa Verde", one("get_area_outages", session_token=TM)["cause"] == "PLANNED")
    check("outages: Ethan sees his own open ticket", one("get_area_outages", session_token=TE)["my_open_ticket"] == "OTK-000090")
    a = call("get_my_service_activity", session_token=TE)
    check("activity: Ethan's ticket listed", any(x["reference"] == "OTK-000090" for x in a), a)
    check("activity: Laura has none", one("get_my_service_activity", session_token=TL)["status"] == "NO_ACTIVITY")
    s = call("get_appointment_slots", session_token=TG, appointment_type="METER_UPGRADE")
    ids = {x["slot_id"] for x in s}
    check("slots: past SLOT-01 and full SLOT-02 hidden, open slots listed, upgrade allowed for Grace",
          "SLOT-01" not in ids and "SLOT-02" not in ids and "SLOT-03" in ids and all(x["allowed"] == "yes" for x in s), s)
    s = call("get_appointment_slots", session_token=TL, appointment_type="METER_UPGRADE")
    check("slots: Laura (smart) upgrade -> allowed no, ALREADY_SMART", s[0]["allowed"] == "no" and s[0]["reason_code"] == "ALREADY_SMART", s[0])
    check("slots: unknown type -> INVALID_TYPE", one("get_appointment_slots", session_token=TL, appointment_type="TREE_TRIM")["status"] == "INVALID_TYPE")

    # ------------------------------------------------------------ two-step: REPORT_OUTAGE
    r = one("propose_action", session_token=TL, action_type="REPORT_OUTAGE", target="NO_POWER")
    check("Laura report outage -> PROPOSED, links to OUT-2026-0041", r["outcome"] == "PROPOSED" and r["linked_outage_id"] == "OUT-2026-0041"
          and "OUT-2026-0041" in r["summary"], r)
    pid = r["proposal_id"]
    check("propose writes nothing yet (0 tickets, 0 events)",
          n(f"SELECT count(*) FROM outage_tickets WHERE customer_id='{LAURA}'") == 0 and n("SELECT count(*) FROM account_events") == 0)
    r2 = one("propose_action", session_token=TL, action_type="report outage", target="no power")
    check("re-propose is idempotent (same proposal, 1 row)", r2["proposal_id"] == pid
          and n(f"SELECT count(*) FROM pending_actions WHERE customer_id='{LAURA}'") == 1, r2)
    reported = n("SELECT customers_reported FROM outages WHERE outage_id='OUT-2026-0041'")
    r = one("confirm_action", session_token=TL, proposal_id=pid)
    check("confirm -> EXECUTED, ticket LINKED to OUT-2026-0041 with the outage ETR",
          r["outcome"] == "EXECUTED" and r["ticket_type"] == "LINKED" and r["linked_outage_id"] == "OUT-2026-0041"
          and r["estimated_restoration"], r)
    L_REF = r["reference"]
    check("DB: one LINKED ticket, no new crew ticket, outage report count +1",
          n(f"SELECT count(*) FROM outage_tickets WHERE customer_id='{LAURA}' AND ticket_type='LINKED'") == 1
          and n(f"SELECT count(*) FROM outage_tickets WHERE customer_id='{LAURA}' AND ticket_type='NEW'") == 0
          and n("SELECT customers_reported FROM outages WHERE outage_id='OUT-2026-0041'") == reported + 1)
    check("confirm twice -> ALREADY_DONE, still one event",
          one("confirm_action", session_token=TL, proposal_id=pid)["outcome"] == "ALREADY_DONE"
          and n(f"SELECT count(*) FROM account_events WHERE customer_id='{LAURA}'") == 1)
    r = one("propose_action", session_token=TL, action_type="REPORT_OUTAGE", target="FLICKERING")
    check("second report -> BLOCKED ALREADY_REPORTED", r["outcome"] == "BLOCKED" and r["reason_code"] == "ALREADY_REPORTED"
          and not r["proposal_id"], r)
    r = one("propose_action", session_token=TO, action_type="REPORT_OUTAGE", target="PARTIAL_POWER")
    check("Olivia (no area outage) -> PROPOSED new ticket", r["outcome"] == "PROPOSED" and not r["linked_outage_id"]
          and "new outage ticket" in r["summary"], r)
    r = one("confirm_action", session_token=TO, proposal_id=r["proposal_id"])
    check("Olivia confirm -> NEW ticket, crew dispatched", r["outcome"] == "EXECUTED" and r["ticket_type"] == "NEW"
          and n(f"SELECT count(*) FROM outage_tickets WHERE customer_id='{OLIVIA}' AND status='CREW_DISPATCHED'") == 1, r)
    r = one("propose_action", session_token=TH, action_type="REPORT_OUTAGE", target="NO_POWER")
    check("Henry (disconnected) report -> SERVICE_DISCONNECTED", r["reason_code"] == "SERVICE_DISCONNECTED", r)
    r = one("propose_action", session_token=TE, action_type="REPORT_OUTAGE", target="NO_POWER")
    check("Ethan (open ticket) -> ALREADY_REPORTED citing OTK-000090", r["reason_code"] == "ALREADY_REPORTED" and "OTK-000090" in r["reason_text"], r)
    r = one("propose_action", session_token=TG, action_type="REPORT_OUTAGE", target="SPARKS")
    check("unknown outage target -> INVALID_TARGET", r["reason_code"] == "INVALID_TARGET", r)

    # ------------------------------------------------------------ two-step: CHANGE_RATE_PLAN
    r = one("propose_action", session_token=TL, action_type="CHANGE_RATE_PLAN", target="EV")
    check("Laura EV -> PROPOSED, price $74.27, effective the 1st of next month",
          r["outcome"] == "PROPOSED" and f2(r["price"]) == 74.27
          and r["effective_date"] == val("SELECT next_cycle_start()::text AS v"), r)
    pid = r["proposal_id"]
    r = one("confirm_action", session_token=TG, proposal_id=pid)
    check("SCOPE: Grace confirming Laura's proposal -> NOT_FOUND", r["outcome"] == "NOT_FOUND", r)
    check("bogus proposal id -> NOT_FOUND", one("confirm_action", session_token=TL, proposal_id="RPL-PRP-NOPE")["outcome"] == "NOT_FOUND")
    check("forged token confirm -> SESSION_INVALID", one("confirm_action", session_token=BAD, proposal_id=pid)["outcome"] == "SESSION_INVALID")
    r = one("confirm_action", session_token=TL, proposal_id=pid)
    check("Laura confirm -> EXECUTED; plan change SCHEDULED, current plan unchanged until then",
          r["outcome"] == "EXECUTED" and n(f"SELECT count(*) FROM plan_changes WHERE customer_id='{LAURA}' AND to_plan='EV' AND status='SCHEDULED'") == 1
          and val(f"SELECT plan_code AS v FROM customers WHERE customer_id='{LAURA}'") == "STANDARD", r)
    L_PLAN_REF = r["reference"]
    check("then TOU -> CHANGE_PENDING", one("propose_action", session_token=TL, action_type="CHANGE_RATE_PLAN", target="TOU")["reason_code"] == "CHANGE_PENDING")
    r = one("propose_action", session_token=TG, action_type="CHANGE_RATE_PLAN", target="TOU")
    check("Grace (analog) TOU -> BLOCKED SMART_METER_REQUIRED", r["outcome"] == "BLOCKED" and r["reason_code"] == "SMART_METER_REQUIRED", r)
    bpid = val(f"SELECT proposal_id AS v FROM pending_actions WHERE customer_id='{GRACE}' AND outcome='BLOCKED' LIMIT 1")
    check("confirming a BLOCKED proposal -> BLOCKED, no event",
          one("confirm_action", session_token=TG, proposal_id=bpid)["outcome"] == "BLOCKED"
          and n(f"SELECT count(*) FROM account_events WHERE customer_id='{GRACE}'") == 0)
    check("Olivia SOLAR -> NO_SOLAR", one("propose_action", session_token=TO, action_type="CHANGE_RATE_PLAN", target="SOLAR")["reason_code"] == "NO_SOLAR")
    check("Priya SOLAR -> NO_CHANGE", one("propose_action", session_token=TP, action_type="CHANGE_RATE_PLAN", target="SOLAR")["reason_code"] == "NO_CHANGE")
    check("unknown plan -> INVALID_TARGET", one("propose_action", session_token=TO, action_type="CHANGE_RATE_PLAN", target="GOLD")["reason_code"] == "INVALID_TARGET")
    for act in ("DISCONNECT", "TRANSFER", "RECONNECT"):
        check(f"{act} via propose_action -> INVALID_ACTION",
              one("propose_action", session_token=TO, action_type=act, target="NOW")["reason_code"] == "INVALID_ACTION")
    r = one("propose_action", session_token=TO, action_type="CHANGE_RATE_PLAN", target="TOU")
    psql(f"UPDATE pending_actions SET expires_at = now() - INTERVAL '1 minute' WHERE proposal_id = {lit(r['proposal_id'])}")
    r = one("confirm_action", session_token=TO, proposal_id=r["proposal_id"])
    check("expired proposal -> EXPIRED, no plan change", r["outcome"] == "EXPIRED"
          and n(f"SELECT count(*) FROM plan_changes WHERE customer_id='{OLIVIA}'") == 0, r)
    r = one("propose_action", session_token=TP, action_type="CHANGE_RATE_PLAN", target="EV")
    psql(f"UPDATE customers SET meter_type='ANALOG' WHERE customer_id='{PRIYA}'")
    r = one("confirm_action", session_token=TP, proposal_id=r["proposal_id"])
    psql(f"UPDATE customers SET meter_type='SMART' WHERE customer_id='{PRIYA}'")
    check("confirm re-checks the rules (meter changed after propose) -> BLOCKED SMART_METER_REQUIRED",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "SMART_METER_REQUIRED", r)

    # ------------------------------------------------------------ appointments
    r = one("book_appointment", session_token=TG, appointment_type="METER_UPGRADE", slot_id="SLOT-03")
    check("Grace meter upgrade SLOT-03 -> BOOKED", r["outcome"] == "BOOKED" and (r["appointment_id"] or "").startswith("APPT-"), r)
    G_APPT = r["appointment_id"]
    check("DB: appointment row + slot booked 1", n(f"SELECT count(*) FROM appointments WHERE customer_id='{GRACE}'") == 1
          and n("SELECT booked FROM appointment_slots WHERE slot_id='SLOT-03'") == 1)
    check("second upgrade -> ALREADY_BOOKED", one("book_appointment", session_token=TG, appointment_type="METER_UPGRADE", slot_id="SLOT-04")["reason_code"] == "ALREADY_BOOKED")
    check("full slot -> SLOT_FULL", one("book_appointment", session_token=TG, appointment_type="METER_INSPECTION", slot_id="SLOT-02")["reason_code"] == "SLOT_FULL")
    check("past slot -> SLOT_PAST", one("book_appointment", session_token=TG, appointment_type="METER_INSPECTION", slot_id="SLOT-01")["reason_code"] == "SLOT_PAST")
    check("unknown slot -> SLOT_NOT_FOUND", one("book_appointment", session_token=TG, appointment_type="METER_INSPECTION", slot_id="SLOT-99")["reason_code"] == "SLOT_NOT_FOUND")
    check("smart meter upgrade -> ALREADY_SMART", one("book_appointment", session_token=TL, appointment_type="METER_UPGRADE", slot_id="SLOT-05")["reason_code"] == "ALREADY_SMART")
    check("tree trim -> INVALID_TYPE", one("book_appointment", session_token=TL, appointment_type="TREE_TRIM", slot_id="SLOT-05")["reason_code"] == "INVALID_TYPE")
    check("Olivia inspection fills SLOT-03 (2/2)", one("book_appointment", session_token=TO, appointment_type="METER_INSPECTION", slot_id="SLOT-03")["outcome"] == "BOOKED")
    r = one("book_appointment", session_token=TL, appointment_type="METER_INSPECTION", slot_id="SLOT-03")
    check("capacity: third booking in SLOT-03 -> SLOT_FULL, no row", r["reason_code"] == "SLOT_FULL"
          and n(f"SELECT count(*) FROM appointments WHERE customer_id='{LAURA}'") == 0, r)
    check("book with forged token -> SESSION_INVALID",
          one("book_appointment", session_token=BAD, appointment_type="METER_INSPECTION", slot_id="SLOT-05")["outcome"] == "SESSION_INVALID")

    # ------------------------------------------------------------ reconnect
    r = one("request_reconnect", session_token=TH)
    check("Henry reconnect -> BLOCKED PAST_DUE, amount_due $142.48, text cites it",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "PAST_DUE" and f2(r["amount_due"]) == 142.48 and "$142.48" in r["reason_text"], r)
    check("DB: no service order, Henry still DISCONNECTED", n(f"SELECT count(*) FROM service_orders WHERE customer_id='{HENRY}'") == 0
          and val(f"SELECT connection_status AS v FROM customers WHERE customer_id='{HENRY}'") == "DISCONNECTED")
    check("Laura reconnect -> NOT_DISCONNECTED", one("request_reconnect", session_token=TL)["reason_code"] == "NOT_DISCONNECTED")
    r = one("request_reconnect", session_token=TMA)
    check("Maria (paid) reconnect -> RECONNECT_SCHEDULED", r["outcome"] == "RECONNECT_SCHEDULED" and (r["order_id"] or "").startswith("SO-"), r)
    M_SO = r["order_id"]
    check("DB: order row + Maria RECONNECT_PENDING", n(f"SELECT count(*) FROM service_orders WHERE customer_id='{MARIA}'") == 1
          and val(f"SELECT connection_status AS v FROM customers WHERE customer_id='{MARIA}'") == "RECONNECT_PENDING")
    check("Maria again -> ALREADY_REQUESTED", one("request_reconnect", session_token=TMA)["reason_code"] == "ALREADY_REQUESTED")
    check("reconnect forged token -> SESSION_INVALID", one("request_reconnect", session_token=BAD)["outcome"] == "SESSION_INVALID")

    # ------------------------------------------------------------ human-owned cases
    r = one("open_service_case", session_token=TG, request_type="billing_dispute",
            summary="My meter was not read; the estimate is far above last year and I want it corrected.",
            agent_brief="Latest bill is on an ESTIMATED read of 1,700 kWh vs 1,150 kWh last year.", requested_amount="")
    check("Grace billing_dispute -> OPENED, Billing Review", r["outcome"] == "OPENED" and r["team"] == "Billing Review"
          and r["case_id"].startswith("RPL-CASE-"), r)
    G_CASE = r["case_id"]
    check("DB: case parked BILL_CREDIT on Grace's latest bill, SLA set, OPEN",
          n(f"SELECT count(*) FROM service_cases WHERE case_id='{G_CASE}' AND parked_action='BILL_CREDIT' AND status='OPEN' "
            f"AND parked_ref=latest_bill('{GRACE}') AND sla_due_at > now() + INTERVAL '70 hours'") == 1)
    check("same type again -> EXISTING", one("open_service_case", session_token=TG, request_type="billing dispute", summary="again",
                                             agent_brief="", requested_amount="")["outcome"] == "EXISTING")
    r = one("open_service_case", session_token=TH, request_type="payment_arrangement",
            summary="I cannot pay the overdue amount at once.", agent_brief="", requested_amount="")
    H_CASE = r["case_id"]
    check("Henry payment_arrangement -> OPENED, Credit & Collections, requested = past due $142.48",
          r["team"] == "Credit & Collections" and f2(val(f"SELECT requested_amount AS v FROM service_cases WHERE case_id='{H_CASE}'")) == 142.48, r)
    r = one("open_service_case", session_token=TL, request_type="hazardous_condition",
            summary="A power line is down and sparking across my driveway.", agent_brief="Triage: HAZARD", requested_amount="")
    check("hazard -> OPENED, Emergency Dispatch, text says call 911", r["team"] == "Emergency Dispatch" and "911" in r["reason_text"], r)
    L_HAZ = r["case_id"]
    check("unknown request type -> INVALID_TYPE", one("open_service_case", session_token=TL, request_type="refund_me", summary="x",
                                                      agent_brief="", requested_amount="")["outcome"] == "INVALID_TYPE")
    r = call("get_my_cases", session_token=TG)
    check("Grace sees her OPEN case", r[0]["case_id"] == G_CASE and r[0]["case_status"] == "OPEN", r)

    # ------------------------------------------------------------ reviewer loop
    check("reviewer wrong code -> VERIFY_FAILED", one("verify_reviewer", staff_id="RPL-S-201", code="0000")["outcome"] == "VERIFY_FAILED")
    r = one("verify_reviewer", staff_id="S-201", code="5150")
    check("Avery verified as REVIEWER, Billing Review, limit $200", r["outcome"] == "VERIFIED" and r["role"] == "REVIEWER"
          and r["team"] == "Billing Review" and f2(r["approval_limit"]) == 200, r)
    TA = r["session_token"]
    TJ = one("verify_reviewer", staff_id="201".replace("201", "305"), code="7720")["session_token"]
    check("customer code cannot verify a reviewer", one("verify_reviewer", staff_id="RPL-S-305", code="4821")["outcome"] == "VERIFY_FAILED")
    check("customer token on a reviewer tool -> NOT_REVIEWER", one("get_review_queue", session_token=TG)["status"] == "NOT_REVIEWER")
    check("reviewer token on a customer tool -> SESSION_INVALID", one("get_my_account", session_token=TA)["status"] == "SESSION_INVALID")
    q = call("get_review_queue", session_token=TA)
    qids = [x["case_id"] for x in q]
    check("Avery's queue: Samuel's + Grace's billing cases only, by SLA", set(qids) == {"RPL-CASE-000101", G_CASE}
          and qids == sorted(qids, key=lambda c: next(x["sla_due_at"] for x in q if x["case_id"] == c)), q)
    check("queue shows a masked account + first name only", all(x["customer_ref"].startswith("****") for x in q) and "customer_name" not in q[0], q[0])
    r = one("get_review_case", session_token=TA, case_id=G_CASE)
    check("review case: eligible max $98.79, facts name the ESTIMATED read", r["status"] == "OK"
          and f2(r["eligible_max_amount"]) == 98.79 and "ESTIMATED" in r["facts"] and "1,700 kWh" in r["facts"], r)
    check("CROSS-TEAM: Avery opening Henry's case -> NOT_FOUND", one("get_review_case", session_token=TA, case_id=H_CASE)["status"] == "NOT_FOUND")
    check("CROSS-TEAM: Diane's Customer Care case invisible -> NOT_FOUND", one("get_review_case", session_token=TA, case_id="RPL-CASE-000103")["status"] == "NOT_FOUND")

    def decide(tk, case, dec, amt, note, msg="Thank you for your patience."):
        return one("decide_review_case", session_token=tk, case_id=case, decision=dec, amount=amt, internal_note=note, customer_message=msg)

    r = decide(TG, G_CASE, "APPROVE", "98.79", "self approval attempt")
    check("customer token cannot decide (self-approve) -> NOT_REVIEWER, no decision row",
          r["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, r)
    check("Avery deciding Henry's case -> NOT_YOUR_TEAM", decide(TA, H_CASE, "APPROVE", "50", "looks fine")["reason_code"] == "NOT_YOUR_TEAM")
    check("unknown case -> NOT_FOUND", decide(TA, "RPL-CASE-999999", "APPROVE", "5", "looks fine")["reason_code"] == "NOT_FOUND")
    check("short note -> NOTE_REQUIRED", decide(TA, G_CASE, "APPROVE", "30", "ok")["reason_code"] == "NOTE_REQUIRED")
    check("decision MAYBE -> INVALID_DECISION", decide(TA, G_CASE, "MAYBE", "30", "not sure yet")["reason_code"] == "INVALID_DECISION")
    check("amount above the SQL maximum -> AMOUNT_INVALID", decide(TA, G_CASE, "APPROVE", "120", "estimate too high")["reason_code"] == "AMOUNT_INVALID")
    check("negative amount -> AMOUNT_INVALID", decide(TA, G_CASE, "APPROVE", "-5", "estimate too high")["reason_code"] == "AMOUNT_INVALID")
    check("blocked attempts left the case OPEN, nothing executed",
          val(f"SELECT status AS v FROM service_cases WHERE case_id='{G_CASE}'") == "OPEN"
          and n("SELECT count(*) FROM bill_lines WHERE category='BILL_CREDIT'") == 0)
    owed = f2(val(f"SELECT bill_outstanding(latest_bill('{GRACE}')) AS v"))
    r = decide(TA, G_CASE, "APPROVE", "$30", "Meter not read; estimate 48% above last year.",
               "We corrected your estimated bill.")
    check("Avery approves $30.00 -> DECIDED, case APPROVED, executed text names the credit",
          r["outcome"] == "DECIDED" and r["case_status"] == "APPROVED" and f2(r["approved_amount"]) == 30 and "$30.00" in (r["executed"] or ""), r)
    check("DB: parked action executed (-$30.00 BILL_CREDIT on the latest bill), outstanding down by $30",
          n(f"SELECT count(*) FROM bill_lines WHERE bill_id=latest_bill('{GRACE}') AND category='BILL_CREDIT' AND amount=-30 AND source_case_id='{G_CASE}'") == 1
          and f2(val(f"SELECT bill_outstanding(latest_bill('{GRACE}')) AS v")) == round(owed - 30, 2))
    check("DB: decision row + CASE_DECIDED audit row",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{G_CASE}' AND reviewer_id='RPL-S-201' AND decision='APPROVE'") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE case_id='{G_CASE}' AND event='CASE_DECIDED' AND actor='RPL-S-201'") == 1)
    check("double decision -> ALREADY_DECIDED, still one decision", decide(TA, G_CASE, "REJECT", "", "changed my mind")["reason_code"] == "ALREADY_DECIDED"
          and n(f"SELECT count(*) FROM review_decisions WHERE case_id='{G_CASE}'") == 1)
    r = one("get_my_cases", session_token=TG)
    check("Grace sees APPROVED + the customer message + the credit, never the note or reviewer",
          r["case_status"] == "APPROVED" and "corrected your estimated bill" in r["outcome_message"] and "$30.00" in r["outcome_message"]
          and "48%" not in r["outcome_message"] and "Avery" not in r["outcome_message"] and "reviewer_id" not in r, r)
    r = decide(TJ, "RPL-CASE-000102", "APPROVE", "", "Hardship confirmed by phone.")
    check("Jordan approving Nathan's $210.00 (limit $100) -> OVER_AUTHORITY, case stays OPEN, no arrangement",
          r["reason_code"] == "OVER_AUTHORITY" and val("SELECT status AS v FROM service_cases WHERE case_id='RPL-CASE-000102'") == "OPEN"
          and n(f"SELECT count(*) FROM payment_arrangements WHERE customer_id='{NATHAN}'") == 0, r)
    r = decide(TJ, H_CASE, "APPROVE", "90", "Partial arrangement within my limit.", "Your arrangement is set up.")
    check("Jordan approves Henry $90 -> arrangement 3 x $30.00 executed",
          r["outcome"] == "DECIDED" and n(f"SELECT count(*) FROM payment_arrangements WHERE customer_id='{HENRY}' AND total_amount=90 "
                                          f"AND installments=3 AND installment_amount=30") == 1, r)
    check("the arrangement does not reconnect Henry (past due unchanged)", one("request_reconnect", session_token=TH)["reason_code"] == "PAST_DUE")
    r = decide(TJ, "RPL-CASE-000102", "REJECT", "", "Income not verified yet.", "We need proof of income first.")
    check("Jordan rejects Nathan -> REJECTED, nothing executed", r["case_status"] == "REJECTED"
          and n(f"SELECT count(*) FROM payment_arrangements WHERE customer_id='{NATHAN}'") == 0, r)
    sam_bill = val(f"SELECT latest_bill('{SAMUEL}') AS v")
    r = decide(TA, "RPL-CASE-000101", "REJECT", "", "Rider charged once only.", "The rider appears once on your bill.")
    check("Avery rejects Samuel -> REJECTED, no credit line", r["case_status"] == "REJECTED"
          and n(f"SELECT count(*) FROM bill_lines WHERE bill_id='{sam_bill}' AND category='BILL_CREDIT'") == 0, r)
    check("decided cases leave the queue", one("get_review_queue", session_token=TA)["status"] == "QUEUE_EMPTY")
    check("forged token decide -> NOT_REVIEWER", decide(BAD, H_CASE, "APPROVE", "1", "forged token")["outcome"] == "NOT_REVIEWER")

    # ------------------------------------------------------------ email guard
    r = one("email_confirmation", session_token=TL, reference=L_REF)
    check("Laura email for her executed outage report -> SEND_OK + log row", r["send_status"] == "SEND_OK"
          and n(f"SELECT count(*) FROM email_log WHERE principal_id='{LAURA}' AND reference='{L_REF}'") == 1, r)
    olivia_ref = val(f"SELECT reference AS v FROM account_events WHERE customer_id='{OLIVIA}'")
    r = one("email_confirmation", session_token=TL, reference=olivia_ref)
    check("Laura email for Olivia's reference -> NOT_SENT NOT_FOUND, no log", r["send_status"] == "NOT_SENT" and r["reason_code"] == "NOT_FOUND"
          and n(f"SELECT count(*) FROM email_log WHERE reference='{olivia_ref}'") == 0, r)
    check("Laura email for her OPEN hazard case -> NOT_SENT", one("email_confirmation", session_token=TL, reference=L_HAZ)["send_status"] == "NOT_SENT")
    check("Grace email for her appointment -> SEND_OK", one("email_confirmation", session_token=TG, reference=G_APPT)["send_status"] == "SEND_OK")
    check("Grace email for her decided case -> SEND_OK", one("email_confirmation", session_token=TG, reference=G_CASE)["send_status"] == "SEND_OK")
    check("Maria email for her reconnect order -> SEND_OK", one("email_confirmation", session_token=TMA, reference=M_SO)["send_status"] == "SEND_OK")
    check("Avery email for the decided Grace case -> SEND_OK", one("email_confirmation", session_token=TA, reference=G_CASE)["send_status"] == "SEND_OK")
    check("Avery email for Henry's case (other team) -> NOT_SENT", one("email_confirmation", session_token=TA, reference=H_CASE)["send_status"] == "NOT_SENT")
    r = one("email_confirmation", session_token=BAD, reference=L_REF)
    check("forged token email -> NOT_SENT SESSION_INVALID", r["send_status"] == "NOT_SENT" and r["reason_code"] == "SESSION_INVALID", r)

    # ------------------------------------------------------------ hidden columns
    leaks = [(t, k) for t, rows in OUTPUTS for row in rows for k in row
             if k in (CUSTOMER_HIDDEN if t in CUSTOMER_TOOLS else HIDDEN_COLUMNS)]
    check(f"hidden-column scan over {len(OUTPUTS)} tool results: none of {sorted(CUSTOMER_HIDDEN)}", not leaks, leaks[:5])
    vals = [str(v) for t, rows in OUTPUTS if t in CUSTOMER_TOOLS for row in rows for v in row.values()]
    check("no one-time code, email address or internal note text in customer outputs",
          not any(re.search(r"@example\.com|Meter not read|Hardship confirmed|5150|7720", v) for v in vals))
finally:
    reset()

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT v FROM (SELECT (json_each_text(row_to_json(c))).* FROM customers c) x(k, v) "
    "  WHERE k IN ('customer_id','otp_code','last_name','email','service_address','meter_number','internal_notes') "
    "UNION SELECT first_name || ' ' || last_name FROM customers "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM service_cases UNION SELECT ticket_id FROM outage_tickets UNION SELECT outage_id FROM outages "
    "UNION SELECT bill_id FROM bills UNION SELECT session_token FROM sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 30, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_bill_glossary": ("rider", "power_cost_rider", "read type", 2),
    "get_outage_triage_guide": ("sparking", "sparking or arcing", "safety line", 3),
    "get_rate_plan_glossary": ("smart meter", "SMART_METER_REQUIRED", "reason code", 4),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["bill_explainer_agent", "outage_triage_agent", "rate_plan_agent"])
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
    pct = ref_call(t, "%")      # '%' is matched literally ('7% of the other charges'), never as a wildcard
    check(f"{tool}: '%' and '_' are literal (no wildcard expansion)",
          len(pct) < len(full) and all("%" in f"{r['term']} {r['meaning']}" for r in pct) and ref_call(t, "_%_") == [],
          [r["term"] for r in pct])
    check(f"{tool}: SQL-looking input is just a string -> 0 rows",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no customer / reviewer / case / ticket / bill / session value in the reference rows", not leaked, leaked[:5])
    check(f"{tool}: no account number, staff id, case id, email or token pattern",
          not re.search(r"rpl-\d|rpl-s-\d|case-\d|otk-\d|out-\d|bl-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

bill = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_bill_glossary")
both = ref_call(bill, "estimated, taxes")
check("ref_bill_glossary: several words in one call ('estimated, taxes') -> both found",
      {"ESTIMATED", "taxes_fees", "TAXES_FEES"} <= {r["term"] for r in both}, [r["term"] for r in both])
rate = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_rate_plans")
check("ref_rate_plans: PLAN rows come from rate_plans (one source of truth, UNION)",
      sorted(r["term"].split(" - ")[0] for r in ref_call(rate, "") if r["section"] == "PLAN")
      == sorted(r["plan_code"] for r in psql("SELECT plan_code FROM rate_plans")))
ev = [r for r in ref_call(rate, "EV - EV Time-of-Use") if r["section"] == "PLAN"]
check("ref_rate_plans: EV row carries the exact rate_plans prices and needs",
      len(ev) == 1 and "on-peak $0.09/kWh, off-peak $0.025/kWh" in ev[0]["meaning"]
      and "needs: smart meter." in ev[0]["meaning"], ev)
out = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_outage_triage")
rt = ref_call(out, "routing")
check("ref_outage_triage: hazard ROUTING row comes from case_routing (Emergency Dispatch + call 911)",
      len(rt) == 1 and rt[0]["section"] == "ROUTING" and "Emergency Dispatch" in rt[0]["meaning"]
      and val("SELECT sla_text AS v FROM case_routing WHERE request_type='hazardous_condition'") in rt[0]["meaning"], rt)
r911 = ref_call(out, "911")
check("ref_outage_triage: the 'call 911' safety rule is kept (HAZARD safety line + RULE)",
      any(r["section"] == "SAFETY_LINE" and r["term"] == "HAZARD" and "call 911 now" in r["meaning"] for r in r911)
      and any(r["section"] == "RULE" and "911" in r["meaning"] for r in r911), r911)
# nothing from the old static glossary text was lost
KEEP = {"get_bill_glossary": ["base_charge", "fixed monthly charge", "on-peak", "weekdays 2 pm - 8 pm", "power_cost_rider",
                              "fuel and purchased power", "the same on every plan", "solar export credits",
                              "approved bill credits", "7% of the other charges", "positive = higher now",
                              "same_month_last_year_kwh", "kwh_change_vs_last_year_pct", "cooling_degree_days",
                              "more air conditioning", "the meter was read", "corrected after the next actual read"],
        "get_outage_triage_guide": ["downed", "low-hanging", "sparking", "arcing", "smok", "burning", "transformer fire",
                                    "tree", "water near live equipment", "shocked", "even if the power is also out",
                                    "no power at all", "some lights or circuits work", "very dim", "non-payment",
                                    "emergency dispatch must act now", "links it to a known area outage",
                                    "opens a crew ticket", "meter inspection", "disconnected service", "35 feet",
                                    "call 911 now", "unplug sensitive electronics", "never use a generator indoors",
                                    "switch off the main breaker", "choose hazard"],
        "get_rate_plan_glossary": ["standard", "one flat", "time-of-use", "overnight ev charging", "net metering",
                                   "credit for every kwh", "weekdays 2 pm - 8 pm", "a smart meter; solar panels on file",
                                   "last 3 bills", "riders and taxes are the same on every plan", "positive = cheaper",
                                   "negative = dearer", "yes for the current plan", "no_change", "smart_meter_required",
                                   "free smart-meter upgrade", "no_solar", "change_pending", "next bill cycle",
                                   "describe them in words only"]}
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

print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
