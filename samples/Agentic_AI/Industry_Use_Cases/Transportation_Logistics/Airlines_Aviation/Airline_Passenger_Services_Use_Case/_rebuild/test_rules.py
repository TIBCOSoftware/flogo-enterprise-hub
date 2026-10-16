#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the airline_governed DB and assert the business
rules - identity, scoping, rebooking, compensation / baggage / assistance parking, the human-in-the-loop reviewer loop
(every reason code), the email guard, the audit trail and the three agents' read-only reference tools.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> python _rebuild/test_rules.py          (PSQL env var overrides the psql path)
"""
import json, os, re, subprocess, sys, csv, io, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import (TOOLS, SEARCH_ALTERNATIVES, AGENT_REF_TOOLS, GUIDE_TOOLS, REF_COLUMNS, REVIEWER_TOOLS, PUBLIC_TOOLS,
                       HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER)

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
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "airline_governed"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails, passes, OUTPUTS = 0, 0, []

def lit(v):
    return "'" + str(v).replace("'", "''") + "'"

def sub(sql, params, args):
    assert sorted(re.findall(r"\?(\w+)", sql)) == sorted(p for p, _ in params), sql
    for ph, arg in params:
        sql, n = re.subn(r"\?" + ph + r"(?=[\s;),<>+\-*%/])", lambda _m: lit(args.get(arg, "")), sql)
        assert n == 1, f"placeholder ?{ph} used {n} times"
    return sql

def psql(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV, encoding="utf-8")
    if r.returncode:
        print(r.stderr); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def one(sql):
    return list(psql(sql)[0].values())[0]

def call(tool, **args):
    t = T[tool]
    if "write" in t:
        psql(sub(*t["write"], args))
    rows = psql(sub(*t["read"], args))
    OUTPUTS.append((tool, rows))
    return rows

def check(label, cond, detail=""):
    global fails, passes
    print((("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}")).encode("ascii", "replace").decode())
    fails += 0 if cond else 1
    passes += 1 if cond else 0

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

# ---- static contract of tool_spec (governance shape) ----
check("16 MCP tools (12 traveller + 4 reviewer)", len(TOOLS) == 16 and len(REVIEWER_TOOLS & set(T)) == 4, [t["tool"] for t in TOOLS])
for t in TOOLS:
    for part in ("write", "read"):
        if part not in t:
            continue
        sql, params = t[part]
        phs = re.findall(r"\?(\w+)", sql)
        ok = (len(phs) == len(set(phs))
              and all(re.search(r"CAST\(\?" + p + r" AS text\)", sql) for p in phs)
              and "agent_audit" not in sql and " VALUES" not in sql.upper())
        if part == "write":
            ok = ok and re.match(r"INSERT INTO \w+ \([^)]*\) SELECT (\*|booking_id) FROM \w+", sql) is not None
        check(f"{t['tool']}.{part}: CAST-wrapped unique placeholders, no VALUES, no audit", ok, sql)
check("every tool except the two verify tools takes session_token first",
      all(t["args"][0][0] == "session_token" for t in TOOLS if t["tool"] not in PUBLIC_TOOLS))

# ---- identity ----
r = call("verify_traveller", pnr="ABCDE1", pin="0000")
check("wrong PIN -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_traveller", pnr=" abcde1 ", pin="4821")
check("right PNR+PIN -> VERIFIED + token", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
carlos = r[0]["session_token"]
maria = call("verify_traveller", pnr="PQRST4", pin="7310")[0]["session_token"]
roberto = call("verify_traveller", pnr="KLMNO3", pin="9205")[0]["session_token"]
daniel = call("verify_traveller", pnr="NPQRS5", pin="6677")[0]["session_token"]
sofia = call("verify_traveller", pnr="MNOPQ0", pin="5533")[0]["session_token"]
ana = call("verify_traveller", pnr="FGHIJ2", pin="1188")[0]["session_token"]
linda = call("verify_traveller", pnr="WXYZA7", pin="3046")[0]["session_token"]
kevin = call("verify_traveller", pnr="TUVWX9", pin="8152")[0]["session_token"]
rosa = call("verify_traveller", pnr="HJKLM8", pin="2468")[0]["session_token"]
check("Linda, Kevin and Rosa verify", all([linda, kevin, rosa]))

# ---- scoped reads ----
r = call("get_my_itinerary", session_token=carlos)
check("itinerary = Carlos's 2 legs", len([x for x in r if x["flight_number"]]) == 2 and r[0]["session_status"] == "OK", r)
r = call("get_my_itinerary", session_token="not-a-token")
check("bad token -> SESSION_INVALID, no legs", r[0]["session_status"] == "SESSION_INVALID" and not r[0]["flight_number"], r)
r = call("get_flight_status", session_token=carlos, flight_number="FL801")
check("Carlos sees FL801 DELAYED 90", r[0]["status"] == "DELAYED" and r[0]["delay_minutes"] == "90", r)
r = call("get_flight_status", session_token=carlos, flight_number="FL302")
check("flight not on itinerary -> NOT_ON_ITINERARY", r[0]["lookup_status"] == "NOT_ON_ITINERARY", r)
r = call("get_my_loyalty", session_token=carlos)
check("loyalty = Gold", r[0]["tier"] == "Gold" and r[0]["session_status"] == "OK", r)
r = call("get_my_itinerary", session_token=kevin)
check("Kevin's itinerary shows the seeded WCHR pending on FL305",
      [x["assistance"] for x in r if x["flight_number"] == "FL305"] == ["WCHR PENDING_CONFIRMATION"], r)

# ---- connection risk (ARITHMETIC in SQL) ----
risk = {x["pnr"]: x for tok in [carlos, maria, roberto, daniel, sofia, ana]
        for x in call("check_connection_risk", session_token=tok)}
check("Carlos MISSED (FL801->FL445)", risk["ABCDE1"]["risk"] == "MISSED", risk["ABCDE1"])
check("Maria AT_RISK (~50 min)", risk["PQRST4"]["risk"] == "AT_RISK" and risk["PQRST4"]["connection_minutes"] == "50", risk["PQRST4"])
check("Roberto direct -> NO_CONNECTION", risk["KLMNO3"]["risk"] == "NO_CONNECTION", risk["KLMNO3"])
check("Daniel cancelled inbound -> MISSED", risk["NPQRS5"]["risk"] == "MISSED", risk["NPQRS5"])
check("Sofia MISSED", risk["MNOPQ0"]["risk"] == "MISSED", risk["MNOPQ0"])
check("Ana SAFE (90 min)", risk["FGHIJ2"]["risk"] == "SAFE", risk["FGHIJ2"])

# ---- agent tool: search_alternatives (route + time only, no identity) ----
def alts(org, dst, after, cab="Economy"):
    return [x["flight_number"] for x in psql(sub(*SEARCH_ALTERNATIVES["read"],
            {"origin": org, "destination": dst, "earliest_departure": after, "cabin": cab}))]
carlos_earliest = risk["ABCDE1"]["earliest_rebook_departure"]
a = alts("ATL", "MIA", carlos_earliest)
check("Carlos alternatives = FL447, FL449 (not FL445, no seats)", a == ["FL447", "FL449"], a)
a = alts("ATL", "SEA", risk["MNOPQ0"]["earliest_rebook_departure"], "Business")
check("Sofia -> no same-day SEA alternative", a == [], a)

# ---- rebook guards ----
def prop(tok, cur, new): return call("propose_rebook", session_token=tok, current_flight=cur, new_flight=new)[0]
check("wrong route", prop(carlos, "FL445", "FL614")["reason"].startswith("WRONG_ROUTE"))
check("no seats on target", prop(carlos, "FL445", "FL445")["reason"].startswith("SAME_FLIGHT"))
check("unknown target flight", prop(carlos, "FL445", "FL999")["reason"].startswith("FLIGHT_UNKNOWN"))
check("no such leg on booking", prop(carlos, "FL999", "FL447")["reason"].startswith("NOT_FOUND"))
check("another traveller's leg", prop(maria, "FL445", "FL447")["reason"].startswith("NOT_FOUND"))
check("departs too early (before connection)", prop(sofia, "FL717", "FL715")["reason"].startswith("DEPARTS_TOO_EARLY"))
check("target with zero seats -> NO_SEATS", prop(maria, "FL612", "FL612")["reason"].startswith("SAME_FLIGHT"))

# ---- two-step rebook happy path (Carlos FL445 -> FL447) ----
p1 = prop(carlos, "FL445", "FL447")
p2 = prop(carlos, "FL445", "FL447")
check("eligible -> PROPOSED with action + seat", p1["outcome"] == "PROPOSED" and p1["action_id"] and p1["new_seat"], p1)
check("re-propose idempotent (same action)", p1["action_id"] == p2["action_id"], (p1, p2))
act = p1["action_id"]
check("exactly one pending action", psql("SELECT count(*) n FROM pending_actions")[0]["n"] == "1")

def conf(tok, a): return call("confirm_rebook", session_token=tok, action_id=a)[0]
check("confirm bogus id", conf(carlos, "ACT-00000000")["reason"].startswith("ACTION_NOT_FOUND"))
check("confirm by another traveller", conf(maria, act)["reason"].startswith("ACTION_NOT_FOUND"))
c1 = conf(carlos, act.lower())
check("confirm -> EXECUTED on FL447", c1["outcome"] == "EXECUTED" and c1["to_flight"] == "FL447", c1)
c2 = conf(carlos, act)
n = psql("SELECT count(*) n FROM rebookings")[0]["n"]
check("re-confirm idempotent, one rebooking row", c2["outcome"] == "EXECUTED" and n == "1", (c2, n))
r = [x for x in call("get_my_itinerary", session_token=carlos) if x["destination"] == "MIA"][0]
check("itinerary now on FL447, REBOOKED", r["flight_number"] == "FL447" and r["segment_status"] == "REBOOKED", r)
check("seats decremented on FL447", psql("SELECT seats_available s FROM flights WHERE flight_number='FL447'")[0]["s"] == "8")
check("rebooked leg cannot rebook again", prop(carlos, "FL447", "FL449")["reason"].startswith("ALREADY_REBOOKED"))

# ---- email confirmation (guarded; logged only when authorised) ----
def email(tok, ref): return call("email_my_confirmation", session_token=tok, action_id=ref)[0]
e = email(carlos, act)
check("email authorised for executed rebooking", e["send_status"] == "SEND_OK" and "@" in (e["to_email"] or ""), e)
check("DB: the authorised email is logged once (email_log + EMAIL_LOGGED audit)",
      one(f"SELECT count(*) FROM email_log WHERE reference_id = {lit(act)}") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='EMAIL_LOGGED'") == "1")
e = email(carlos, "ACT-00000000")
check("email refused for unknown action", e["send_status"] == "NOT_SENT" and not e["to_email"], e)
e = email(maria, act)
check("email refused for another traveller's action", e["send_status"] == "NOT_SENT", e)
check("DB: refused emails are not logged", one("SELECT count(*) FROM email_log") == "1")

# ---- expiry ----
p = prop(maria, "FL612", "FL614")
check("Maria eligible -> PROPOSED", p["outcome"] == "PROPOSED", p)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p['action_id'])}")
check("expired proposal cannot confirm", conf(maria, p["action_id"])["reason"].startswith("EXPIRED"))

# ---- human-owned requests (routing + compensation parking in SQL) ----
def case(tok, ty, stmt="Please help with this.", brief="Traveller request; routed for a human to decide.", amt=""):
    return call("open_service_case", session_token=tok, request_type=ty, traveler_statement=stmt, brief=brief, amount=amt)[0]
k = case(carlos, "compensation_claim", "My FL801 was delayed 90 minutes and I want compensation.")
check("compensation -> CASE_OPENED, Customer Care", k["outcome"] == "CASE_OPENED" and "Customer Care" in k["assigned_team"], k)
check("compensation parks COMPENSATION:FL801 with the DELAY_60 band maximum ($100) as the requested amount",
      one(f"SELECT parked_action || ' ' || requested_amount FROM service_cases WHERE case_id = {lit(k['case_id'])}") == "COMPENSATION:FL801 100.00"
      and k["requested_amount"] == "100.00" and "travel credit" in (k["if_approved"] or ""), k)
carlos_comp = k["case_id"]
check("duplicate case suppressed", case(carlos, "COMPENSATION_CLAIM")["case_id"] == k["case_id"])
check("baggage -> Baggage Services", case(carlos, "BAGGAGE_CLAIM")["assigned_team"] == "Baggage Services")
check("bad request type", case(carlos, "REFUND")["reason"].startswith("BAD_REQUEST_TYPE"))
check("case without session", case("x", "OTHER")["reason"].startswith("SESSION_INVALID"))
r = call("get_my_cases", session_token=carlos)
check("Carlos sees his cases", len([x for x in r if x["case_id"]]) >= 2 and r[0]["session_status"] == "OK", r)
k = case(daniel, "COMPENSATION_CLAIM", "My Chicago flight was cancelled.", amt="$500")
check("Daniel's cancelled inbound -> CANCELLED band: $500 asked is capped at $300",
      k["requested_amount"] == "300.00" and one(f"SELECT parked_action FROM service_cases WHERE case_id = {lit(k['case_id'])}") == "COMPENSATION:FL932", k)
daniel_comp = k["case_id"]
k = case(ana, "COMPENSATION_CLAIM", "I want compensation.", amt="50")
check("Ana has no disrupted leg -> case opened, nothing parked, no amount",
      k["outcome"] == "CASE_OPENED" and not k["requested_amount"]
      and one(f"SELECT coalesce(parked_action, 'none') FROM service_cases WHERE case_id = {lit(k['case_id'])}") == "none", k)
k = case(sofia, "COMPENSATION_CLAIM", "Still waiting on my compensation.")
check("Sofia's seeded open compensation case -> ALREADY_OPEN, same case, no duplicate",
      k["outcome"] == "ALREADY_OPEN" and k["case_id"] == "SC-S0B2C2"
      and one("SELECT count(*) FROM service_cases WHERE request_type='COMPENSATION_CLAIM' AND pnr='MNOPQ0'") == "1", k)

# ---- baggage claim: the agent's answer is validated in SQL, recorded, and opens a Baggage Services case ----
NOTE_LINE = ("claim_note: Keep the receipts for any essentials you buy while you wait; Meridian Baggage Services decides "
             "any reimbursement and replies by the date on your case.")
ANS = ("claim_type: DELAYED\nbag_type: 22 - Upright suitcase, soft-sided\ncolour: BU\n"
       "contents: CLOTHING, ELECTRONICS, TOILETRIES, JEWELS\nmissing_fields: BRAND, DELIVERY_ADDRESS, DAMAGE_PHOTO\n" + NOTE_LINE)
DESC = "Blue soft-sided upright suitcase, did not come off the belt. Inside: a suit, my laptop charger and toiletries."
def bag(tok, fl="FL721", desc=DESC, amt="", ans=ANS):
    return call("record_baggage_claim", session_token=tok, flight_number=fl, description=desc, interim_amount=amt, agent_answer=ans)[0]
check("baggage: no session -> SESSION_INVALID", bag("x")["reason_code"] == "SESSION_INVALID")
check("baggage: flight not on the booking -> NOT_FOUND", bag(linda, fl="FL801")["reason_code"] == "NOT_FOUND")
check("baggage: flight not arrived yet -> NOT_ARRIVED", bag(rosa, fl="FL305")["reason_code"] == "NOT_ARRIVED")
check("baggage: empty description -> DESCRIPTION_MISSING", bag(linda, desc=" ")["reason_code"] == "DESCRIPTION_MISSING")
check("baggage: agent answer without a valid claim type -> CLAIM_TYPE_UNKNOWN",
      bag(linda, ans="claim_type: MISPLACED\nbag_type: 22")["reason_code"] == "CLAIM_TYPE_UNKNOWN"
      and bag(linda, ans="")["reason_code"] == "CLAIM_TYPE_UNKNOWN")
check("DB: no claim and no case written by the blocked calls",
      one("SELECT count(*) FROM baggage_claims WHERE pnr='WXYZA7'") == "0" and one("SELECT count(*) FROM service_cases WHERE pnr='WXYZA7'") == "0")
lb = one("SELECT booking_id FROM bookings WHERE pnr='WXYZA7'")
r = psql(f"SELECT * FROM baggage_assessment({lb}, 'FL721', 'x', '', 'claim_type: LOST')")[0]
check("rule: LOST one day after arrival -> recorded as DELAYED (LOST_TOO_EARLY)",
      r["ok"] == "t" and r["claim_type"] == "DELAYED" and r["agent_claim_type"] == "LOST" and "LOST_TOO_EARLY" in r["rule_note"], r)
kb = one("SELECT booking_id FROM bookings WHERE pnr='TUVWX9'")
check("rule: LOST eight days after arrival stays LOST (Kevin's seeded claim)",
      one("SELECT claim_type FROM baggage_claims WHERE case_id='SC-S0A1B1'") == "LOST"
      and psql(f"SELECT * FROM baggage_assessment({kb}, 'FL719', 'x', '', 'claim_type: LOST')")[0]["reason_code"] == "ALREADY_RECORDED")
b = bag(linda, amt="$400")
check("Linda's delayed bag -> RECORDED with claim id, case id, Baggage Services, reply-by date",
      b["outcome"] == "RECORDED" and b["claim_id"].startswith("BAG-") and b["case_id"].startswith("SC-")
      and b["assigned_team"] == "Baggage Services" and b["reply_by"] and b["claim_type"] == "DELAYED", b)
check("SQL kept only valid codes: bag type 22, colour BU, contents CLOTHING/ELECTRONICS/TOILETRIES (JEWELS ignored)",
      b["bag_type"].startswith("22 Upright suitcase, soft-sided") and b["colour"].startswith("BU")
      and b["contents"] == "CLOTHING, ELECTRONICS, TOILETRIES", b)
check("missing fields: BRAND + DELIVERY_ADDRESS kept, DAMAGE_PHOTO dropped (not for DELAYED), BAG_TAG added by the rule",
      b["missing_fields"] == "BAG_TAG, BRAND, DELIVERY_ADDRESS" and "two letters and six digits" in (b["what_to_send"] or ""), b)
check("interim expenses: $400 asked -> capped at the DELAYED cap of $300 (INTERIM_CAPPED note)",
      b["interim_requested"] == "300.00" and "INTERIM_CAPPED" in (b["rule_note"] or ""), b)
lclaim, lcase = b["claim_id"], b["case_id"]
row = psql(f"SELECT * FROM service_cases WHERE case_id = {lit(lcase)}")[0]
check("DB: the claim opened an OPEN BAGGAGE_CLAIM case parked INTERIM_EXPENSE:<claim>, $300, brief = the agent's answer",
      row["request_type"] == "BAGGAGE_CLAIM" and row["parked_action"] == "INTERIM_EXPENSE:" + lclaim
      and row["requested_amount"] == "300.00" and row["status"] == "OPEN" and "claim_note:" in row["agent_brief"]
      and row["traveler_statement"] == DESC, row)
check("DB: ignored items recorded (JEWELS, DAMAGE_PHOTO), never used",
      one(f"SELECT ignored_items FROM baggage_claims WHERE claim_id = {lit(lclaim)}") == "JEWELS, DAMAGE_PHOTO")
b2 = bag(linda, amt="300")
check("record again -> same claim, still one claim and one case for the flight",
      b2["claim_id"] == lclaim and one("SELECT count(*) FROM baggage_claims WHERE pnr='WXYZA7'") == "1"
      and one("SELECT count(*) FROM service_cases WHERE pnr='WXYZA7'") == "1", b2)
k = case(linda, "BAGGAGE_CLAIM", "Where is my bag?")
check("open_service_case BAGGAGE_CLAIM right after -> the claim's case (no duplicate)", k["case_id"] == lcase, k)
r = {x["case_id"]: x for x in call("get_my_cases", session_token=linda)}
check("Linda sees her baggage case OPEN with $300 requested", r[lcase]["status"] == "OPEN" and r[lcase]["requested_amount"] == "300.00", r)
r = psql(f"SELECT * FROM baggage_assessment({lb}, 'FL721', 'Tag MR555123 blue bag', '', 'claim_type: DAMAGED\nmissing_fields: DAMAGE_PHOTO')")[0]
check("rule: a tag number in the description satisfies BAG_TAG; DAMAGED needs DAMAGE_PHOTO",
      r["missing_fields"] == "DAMAGE_PHOTO" and r["reason_code"] == "ALREADY_RECORDED", r)

# ---- special assistance: validated SSR codes on the traveller's own segment, PENDING_CONFIRMATION + a case ----
SANS = ("ssr_codes: WCHR, WCHS, BLND, XXXX, STCR\ncodes:\n- WCHS: Wheelchair, no steps: Can walk to and from the seat on board, "
        "but cannot climb aircraft steps; needs a wheelchair and a lift or jet bridge to board.\nmedical_clearance: NO\n"
        "follow_up: none\nstandard_line: Assistance stays pending until the Meridian Accessibility Desk confirms it, and you "
        "will hear from them before you fly.")
NEEDS = "I can walk to my seat but I cannot climb the stairs to the plane, and I am partially sighted."
def ast(tok, fl="FL305", needs=NEEDS, ans=SANS):
    return call("request_assistance", session_token=tok, flight_number=fl, needs=needs, agent_answer=ans)[0]
check("assistance: no session -> SESSION_INVALID", ast("x")["reason_code"] == "SESSION_INVALID")
check("assistance: flight not on the booking -> NOT_FOUND", ast(rosa, fl="FL801")["reason_code"] == "NOT_FOUND")
check("assistance: a flight already flown -> NOT_UPCOMING", ast(linda, fl="FL721")["reason_code"] == "NOT_UPCOMING")
check("assistance: empty needs -> NEEDS_MISSING", ast(rosa, needs="")["reason_code"] == "NEEDS_MISSING")
check("assistance: no usable code -> NO_VALID_CODES", ast(rosa, ans="ssr_codes: NONE")["reason_code"] == "NO_VALID_CODES"
      and ast(rosa, ans="ssr_codes: STCR, ZZZZ")["reason_code"] == "NO_VALID_CODES")
check("DB: nothing written by the blocked calls", one("SELECT count(*) FROM assistance_requests WHERE pnr='HJKLM8'") == "0")
a1 = ast(rosa)
check("Rosa -> REQUESTED: WCHS + BLND pending confirmation, Accessibility Desk case, reply-by date",
      a1["outcome"] == "REQUESTED" and a1["request_id"].startswith("AST-") and a1["assigned_team"] == "Accessibility Desk"
      and a1["requested_codes"] == "WCHS (Wheelchair, no steps) - PENDING_CONFIRMATION; BLND (Blind or low vision) - PENDING_CONFIRMATION"
      and a1["medical_clearance"] == "f" and a1["reply_by"], a1)
rreq, rcase = a1["request_id"], a1["case_id"]
check("SQL kept one wheelchair code (WCHS beats WCHR) and dropped the unknown and the desk-only code",
      one(f"SELECT ignored_codes FROM assistance_requests WHERE request_id = {lit(rreq)}") == "WCHR (one wheelchair code), XXXX, STCR")
row = psql(f"SELECT * FROM service_cases WHERE case_id = {lit(rcase)}")[0]
check("DB: SPECIAL_ASSISTANCE case parked CONFIRM_SSR:<request>, no amount, brief = the agent's answer",
      row["request_type"] == "SPECIAL_ASSISTANCE" and row["parked_action"] == "CONFIRM_SSR:" + rreq and not row["requested_amount"]
      and "standard_line:" in row["agent_brief"], row)
r = [x for x in call("get_my_itinerary", session_token=rosa) if x["flight_number"] == "FL305"][0]
check("Rosa's itinerary shows WCHS + BLND PENDING_CONFIRMATION", r["assistance"] == "WCHS PENDING_CONFIRMATION, BLND PENDING_CONFIRMATION", r)
a2 = ast(rosa)
check("the same request again -> same request, no new rows",
      a2["request_id"] == rreq and one("SELECT count(*) FROM assistance_requests WHERE pnr='HJKLM8'") == "1"
      and one("SELECT count(*) FROM segment_ssrs ss JOIN assistance_requests ar USING (request_id) WHERE ar.pnr='HJKLM8'") == "2", a2)
rb = one("SELECT booking_id FROM bookings WHERE pnr='HJKLM8'")
r = psql(f"SELECT * FROM assistance_assessment({rb}, 'FL305', 'x', 'ssr_codes: WCHC')")[0]
check("rule: a second wheelchair code on the flight -> ALREADY_REQUESTED", r["reason_code"] == "ALREADY_REQUESTED", r)
r = psql(f"SELECT * FROM assistance_assessment({rb}, 'FL305', 'x', 'ssr_codes: OXYG')")[0]
check("rule: a medical need (OXYG) adds MEDA and needs medical clearance",
      r["ok"] == "t" and r["codes"] == "OXYG, MEDA" and r["medical_clearance"] == "t", r)

# ---- reviewer identity (same token mechanism, role checked everywhere) ----
def vrev(staff, code): return call("verify_reviewer", staff_id=staff, code=code)[0]
r = vrev("MER-7001", "000000")
check("reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = vrev("MER-7001", "3046")
check("a traveller PIN is not a staff code -> NOT_VERIFIED", r["status"] == "NOT_VERIFIED", r)
r = vrev("WXYZA7", "246810")
check("a PNR cannot verify as staff -> NOT_VERIFIED", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = vrev("mer 7001", "246810")
check("Dana (staff id typed loosely) -> VERIFIED, role REVIEWER, Baggage Services", r["status"] == "VERIFIED"
      and r["role"] == "REVIEWER" and r["team"] == "Baggage Services" and r["display_name"] == "Dana Brooks" and r["session_token"], r)
dana = r["session_token"]
victor = vrev("MER-7002", "135790")["session_token"]
marcus = vrev("7003", "864209")["session_token"]
elena = vrev("MER-7004", "502468")["session_token"]
nadia = vrev("MER-7005", "719350")["session_token"]
owen = vrev("MER-7006", "357911")["session_token"]
check("Victor, Marcus, Elena, Nadia and Owen verify", all([victor, marcus, elena, nadia, owen]))
check("a reviewer token is not a traveller token (get_my_itinerary -> SESSION_INVALID)",
      call("get_my_itinerary", session_token=dana)[0]["session_status"] == "SESSION_INVALID")
check("a reviewer token cannot open a traveller case", case(dana, "OTHER")["reason"].startswith("SESSION_INVALID"))
check("a reviewer token cannot record a baggage claim", bag(dana)["reason_code"] == "SESSION_INVALID")
check("a traveller token is not a reviewer token (queue -> NOT_REVIEWER)", call("get_review_queue", session_token=linda)[0]["status"] == "NOT_REVIEWER")
check("bogus token on get_review_case -> NOT_REVIEWER", call("get_review_case", session_token="x", case_id="SC-S0A1B1")[0]["status"] == "NOT_REVIEWER")

# ---- queues are scoped to the reviewer's team, ordered by reply-due time ----
def queue(tok): return call("get_review_queue", session_token=tok)
for who, tok, team, n_min in (("Dana", dana, "Baggage Services", 2), ("Marcus", marcus, "Accessibility Desk", 2),
                              ("Elena", elena, "Customer Care (compensation)", 3), ("Nadia", nadia, "Customer Relations", 1),
                              ("Owen", owen, "Ticketing", 1)):
    qq = queue(tok)
    ids = [x["case_id"] for x in qq]
    db = [x["case_id"] for x in psql("SELECT c.case_id FROM service_cases c JOIN service_teams t USING (request_type) "
                                     f"WHERE t.team = {lit(team)} AND c.status = 'OPEN' ORDER BY c.sla_due_at, c.case_id")]
    check(f"{who}'s queue = exactly {team}'s OPEN cases, ordered by reply-due ({len(ids)})",
          ids == db and len(ids) >= n_min and qq[0]["status"] == "OK", (ids, db))
qd = {x["case_id"]: x for x in queue(dana)}
check("queue row: first name + surname initial only, SLA status, requested amount",
      qd["SC-S0A1B1"]["traveller"] == "Kevin W." and qd["SC-S0A1B1"]["requested_amount"] == "450.00"
      and qd["SC-S0A1B1"]["sla_status"] in ("ON_TRACK", "DUE_TODAY", "OVERDUE") and qd[lcase]["traveller"] == "Linda P.", qd.get("SC-S0A1B1"))
check("both Baggage Services reviewers see the same team queue", [x["case_id"] for x in queue(victor)] == [x["case_id"] for x in queue(dana)])
check("cross-team case is invisible: Dana opens an Accessibility Desk case -> NOT_FOUND",
      call("get_review_case", session_token=dana, case_id="SC-S0C3A3")[0]["status"] == "NOT_FOUND")
rc = call("get_review_case", session_token=dana, case_id="sc-s0a1b1")[0]
check("get_review_case: Kevin's LOST claim, max approvable $450, Dana's $250 limit, the claim facts, senior-reviewer option",
      rc["status"] == "OK" and rc["max_approvable"] == "450.00" and rc["your_approval_limit"] == "250.00"
      and "BAG-00001 (LOST)" in rc["facts"] and "cap for LOST: $500.00" in rc["facts"] and "senior reviewer" in rc["options"]
      and "claim_type: LOST" in rc["agent_brief"], rc)
rm = call("get_review_case", session_token=marcus, case_id=rcase)[0]
check("Marcus sees Rosa's assistance request: codes + status, no amount, confirm option",
      rm["status"] == "OK" and "WCHS (Wheelchair, no steps) PENDING_CONFIRMATION" in rm["facts"] and not rm["max_approvable"]
      and "confirms the requested assistance" in rm["options"], rm)
re_ = call("get_review_case", session_token=elena, case_id=carlos_comp)[0]
check("Elena sees Carlos's compensation: FL801 90 minutes late, DELAY_60 band up to $100",
      re_["status"] == "OK" and "FL801" in re_["facts"] and "up to $100.00" in re_["facts"] and re_["max_approvable"] == "100.00", re_)

# ---- decide: every reason code, then the parked actions ----
def decide(tok, case_id, dec="APPROVE", amt="", note="Checked the claim against the records.", msg="Your request was reviewed."):
    return call("decide_review_case", session_token=tok, case_id=case_id, decision=dec, amount=amt, internal_note=note, customer_message=msg)[0]
n_dec = one("SELECT count(*) FROM review_decisions")
r = decide(linda, lcase)
check("a traveller token cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
r = decide(dana, "SC-S0C3A3")
check("another team's case -> BLOCKED NOT_YOUR_TEAM", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_YOUR_TEAM" and not r["case_id"], r)
r = decide(dana, "SC-ZZZZZZ")
check("unknown case -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = decide(dana, "SC-S0A1B1", note="ok")
check("note under 5 characters -> NOTE_REQUIRED", r["reason_code"] == "NOTE_REQUIRED", r)
r = decide(dana, "SC-S0A1B1", dec="MAYBE")
check("decision not APPROVE/REJECT -> INVALID_DECISION", r["reason_code"] == "INVALID_DECISION", r)
r = decide(dana, "SC-S0A1B1", amt="500")
check("more than the $450 requested -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(dana, "SC-S0A1B1", amt="-5")
check("negative amount -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(dana, "SC-S0A1B1")
check("full $450 above Dana's $250 limit -> OVER_AUTHORITY, case stays OPEN", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"], r)
r = decide(dana, lcase, amt="300")
check("Linda's $300 also above Dana's limit -> OVER_AUTHORITY", r["reason_code"] == "OVER_AUTHORITY", r)
check("DB: no decision row and no payment after the blocked attempts",
      one("SELECT count(*) FROM review_decisions") == n_dec and one("SELECT count(*) FROM service_payments") == "0")
r = decide(dana, lcase, amt="$200", note="Receipts for a suit and toiletries seen; within my limit.",
           msg="We have approved $200.00 toward the essentials you bought while your bag is traced.")
check("Dana approves $200 on Linda's claim -> APPROVED, interim payment executed",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "200.00" and "interim expenses for baggage claim " + lclaim in (r["executed_action"] or ""), r)
check("DB: service_payments INTERIM_EXPENSE $200 for the claim + PAYMENT_ISSUED + CASE_DECIDED audit by MER-7001",
      one(f"SELECT count(*) FROM service_payments WHERE case_id = {lit(lcase)} AND kind='INTERIM_EXPENSE' AND ref = {lit(lclaim)} AND amount_usd=200") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='PAYMENT_ISSUED' AND pnr='WXYZA7'") == "1"
      and one(f"SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND actor='MER-7001' AND pnr='WXYZA7' AND detail LIKE {lit(lcase + '%')}") == "1")
r = decide(victor, lcase, dec="REJECT")
check("a second decision (even by a colleague) -> ALREADY_DECIDED",
      r["reason_code"] == "ALREADY_DECIDED" and one(f"SELECT count(*) FROM review_decisions WHERE case_id = {lit(lcase)}") == "1", r)
r = decide(victor, "SC-S0A1B1", note="Lost-bag interim approved in full by senior reviewer.", msg="Your interim expenses of $450.00 are approved.")
check("Victor ($2,000 limit) approves Kevin's full $450 -> APPROVED, payment executed",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "450.00" and "$450.00" in r["executed_action"], r)
r = decide(marcus, rcase, note="Lift and wheelchair booked with the ground handler.", msg="Your wheelchair and guidance assistance are confirmed for FL305.")
check("Marcus confirms Rosa's assistance -> APPROVED, assistance confirmed", r["outcome"] == "APPROVED" and "Assistance confirmed" in r["executed_action"], r)
check("DB: ssr_confirmations row + Rosa's SSRs CONFIRMED + SSR_CONFIRMED audit",
      one(f"SELECT count(*) FROM ssr_confirmations WHERE request_id = {lit(rreq)}") == "1"
      and one(f"SELECT count(*) FROM segment_ssrs WHERE request_id = {lit(rreq)} AND status='CONFIRMED'") == "2"
      and one("SELECT count(*) FROM agent_audit WHERE action='SSR_CONFIRMED'") == "1")
r = [x for x in call("get_my_itinerary", session_token=rosa) if x["flight_number"] == "FL305"][0]
check("Rosa's itinerary now shows WCHS + BLND CONFIRMED", r["assistance"] == "WCHS CONFIRMED, BLND CONFIRMED", r)
r = decide(marcus, "SC-S0C3A3", dec="REJECT", note="Needs a call to confirm the knee condition first.", msg="Please call the Accessibility Desk so we can arrange the right help.")
check("Marcus rejects Kevin's WCHR -> REJECTED, nothing executed, SSR stays unconfirmed",
      r["outcome"] == "REJECTED" and "nothing was executed" in r["executed_action"]
      and one("SELECT status FROM segment_ssrs WHERE request_id='AST-00001'") == "PENDING_CONFIRMATION", r)
r = [x for x in call("get_my_itinerary", session_token=kevin) if x["flight_number"] == "FL305"][0]
check("Kevin's itinerary shows WCHR NOT_CONFIRMED after the rejection", r["assistance"] == "WCHR NOT_CONFIRMED", r)
r = decide(elena, carlos_comp, note="90-minute delay, DELAY_60 band.", msg="We have issued a $100.00 travel credit for the delay.")
check("Elena approves Carlos's compensation (empty amount = the full $100) -> travel credit payment",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "100.00" and "travel credit for the disruption on FL801" in r["executed_action"], r)
check("after a compensation payment nothing more is parked for the booking",
      one("SELECT coalesce((SELECT parked_action FROM case_parking((SELECT booking_id FROM bookings WHERE pnr='ABCDE1'), 'COMPENSATION_CLAIM', '')), 'none')") == "none")
r = decide(elena, daniel_comp, dec="REJECT", note="Cancellation already reimbursed by rebooking.", msg="Your request was not approved.")
check("Elena rejects Daniel's compensation -> REJECTED, no payment",
      r["outcome"] == "REJECTED" and one(f"SELECT count(*) FROM service_payments WHERE case_id = {lit(daniel_comp)}") == "0", r)
r = decide(nadia, "SC-S0D4C4", note="Gate staff briefing scheduled.", msg="Thank you; we have shared your feedback with the gate team.")
check("approve the complaint (no parked action) -> APPROVED, the team completes it",
      r["outcome"] == "APPROVED" and "the team completes it" in r["executed_action"] and not r["approved_amount"], r)
r = decide(owen, "SC-S0E5N5", note="Passport copy checked.", msg="Your name has been corrected on the ticket.")
check("Owen decides his team's case", r["outcome"] == "APPROVED", r)

# ---- the traveller sees the outcome (status + customer_message), never the internals ----
r = {x["case_id"]: x for x in call("get_my_cases", session_token=linda)}
check("Linda sees her baggage case APPROVED, $200 and the team's message",
      r[lcase]["status"] == "APPROVED" and r[lcase]["approved_amount"] == "200.00" and "$200.00" in r[lcase]["customer_message"], r.get(lcase))
check("Linda never sees the internal note or the reviewer", "Receipts for a suit" not in json.dumps(r) and "Dana" not in json.dumps(r))
e = email(linda, lcase.lower())
check("email for a decided case -> SEND_OK with the outcome", e["send_status"] == "SEND_OK" and "approved for $200.00" in e["body"], e)
e = email(maria, "SC-S0D4C4")
check("email for Maria's decided complaint works for Maria", e["send_status"] == "SEND_OK", e)
e = email(maria, lcase)
check("email for another traveller's case -> NOT_SENT CASE_NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason"].startswith("CASE_NOT_FOUND"), e)
e = email(sofia, "SC-S0B2C2")
check("email for an undecided case -> NOT_SENT NOT_DECIDED", e["send_status"] == "NOT_SENT" and e["reason"].startswith("NOT_DECIDED"), e)
check("DB: exactly the 3 authorised emails are logged", one("SELECT count(*) FROM email_log") == "3")

# minimum necessary: hidden columns never reach travellers; reviewers see no email/phone/full surname
trav_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row}
check("traveller tool outputs carry none of the hidden columns", not (trav_cols & HIDDEN_COLUMNS), trav_cols & HIDDEN_COLUMNS)
rev_rows = [row for t, rows in OUTPUTS if t in REVIEWER_TOOLS for row in rows]
rev_cols = {k for row in rev_rows for k in row}
rblob = json.dumps(rev_rows)
check("reviewer tool outputs: no email, phone, PIN or full surname", not (rev_cols & HIDDEN_FROM_REVIEWER)
      and not re.search(r"@example|\+1-\d|\b(Martinez|Fernandez|Gonzalez|Ortiz|Castro|Silva|Park|Wright|Delgado)\b", rblob),
      (rev_cols & HIDDEN_FROM_REVIEWER, re.findall(r"\b(Martinez|Fernandez|Gonzalez|Ortiz|Castro|Silva|Park|Wright|Delgado)\b", rblob)[:3]))
tblob = json.dumps([row for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows])
secrets = [x["v"] for x in psql("SELECT internal_note AS v FROM review_decisions UNION ALL SELECT display_name FROM reviewers")]
check("traveller outputs never contain internal notes or reviewer names", not any(s in tblob for s in secrets),
      [s for s in secrets if s in tblob][:3])
check("every MCP tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---- session expiry ----
psql(f"UPDATE traveler_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(carlos)}")
check("expired token -> SESSION_INVALID", call("get_my_itinerary", session_token=carlos)[0]["session_status"] == "SESSION_INVALID")
psql(f"UPDATE traveler_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(dana)}")
check("expired reviewer token -> NOT_REVIEWER", call("get_review_queue", session_token=dana)[0]["status"] == "NOT_REVIEWER")

# ---- PIN brute-force throttle ----
for _ in range(5):
    call("verify_traveller", pnr="KLMNO3", pin="0000")              # 5 wrong PINs
r = call("verify_traveller", pnr="KLMNO3", pin="9205")              # correct PIN, but now locked
check("5 wrong PINs -> LOCKED even with the right PIN", r[0]["status"] == "LOCKED" and not r[0]["session_token"], r)
check("wrong PIN on an unknown PNR is not tracked", psql("SELECT count(*) n FROM verify_attempts WHERE pnr='ZZZZZ9'")[0]["n"] == "0")

# ---- staff code brute-force lockout ----
n_sess = one("SELECT count(*) FROM traveler_sessions WHERE reviewer_id='MER-7006'")
last = None
for _ in range(5):
    last = vrev("MER-7006", "111111")
check("5th wrong staff code -> LOCKED", last["status"] == "LOCKED" and not last["session_token"], last)
r = vrev("MER-7006", "357911")
check("LOCKED even with the right code, no session", r["status"] == "LOCKED" and not r["session_token"]
      and one("SELECT count(*) FROM traveler_sessions WHERE reviewer_id='MER-7006'") == n_sess, r)
psql("UPDATE reviewer_verify_attempts SET at = at - interval '16 minutes' WHERE reviewer_id='MER-7006'")
check("lock lifts after 15 minutes", vrev("MER-7006", "357911")["status"] == "VERIFIED")

# ---- audit trail (OWASP traceability; written by triggers, no tool reads it) ----
na = lambda a: int(one(f"SELECT count(*) FROM agent_audit WHERE action={lit(a)}"))
check("audit logged verify sessions", na("VERIFY_SESSION_ISSUED") >= 9, na("VERIFY_SESSION_ISSUED"))
check("audit logged a rebook proposal + execution", na("REBOOK_PROPOSED") >= 1 and na("REBOOK_EXECUTED") >= 1)
check("audit logged every case (seeded + opened)", na("SERVICE_CASE_OPENED") == int(one("SELECT count(*) FROM service_cases")), na("SERVICE_CASE_OPENED"))
check("audit logged every baggage claim and assistance request",
      na("BAGGAGE_CLAIM_RECORDED") == int(one("SELECT count(*) FROM baggage_claims"))
      and na("ASSISTANCE_REQUESTED") == int(one("SELECT count(*) FROM assistance_requests")))
check("audit: CASE_DECIDED rows carry the reviewer as actor and the PNR, one per decision",
      one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND (actor IS NULL OR pnr IS NULL)") == "0"
      and na("CASE_DECIDED") == int(one("SELECT count(*) FROM review_decisions")))
check("audit: one PAYMENT_ISSUED per payment", na("PAYMENT_ISSUED") == int(one("SELECT count(*) FROM service_payments")) == 3)
check("audit: REVIEWER_VERIFY rows carry the reviewer id", int(one("SELECT count(*) FROM agent_audit WHERE action='REVIEWER_VERIFY' "
                                                                  "AND actor LIKE 'MER-%'")) >= 6)
check("audit rows carry the PNR (reviewer sign-ins carry the reviewer id instead)",
      one("SELECT count(*) FROM agent_audit WHERE pnr IS NULL AND action <> 'REVIEWER_VERIFY'") == "0")

# ---------------------------------------------------------------- A2A agent reference tools
# rebooking_options_agent keeps search_alternatives (checked above); baggage_claim_agent and special_assistance_agent read
# a section / term / meaning guide.
def ref_call(t, term):
    return psql(sub(*t["read"], {t["read"][1][0][1]: term}))

def ref_blob(rows):
    return "\n".join("|".join(str(v) for v in r.values()) for r in rows).lower()

check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["rebooking_options_agent", "baggage_claim_agent", "special_assistance_agent"])
rk = AGENT_REF_TOOLS[0]
check("rebooking_options_agent keeps search_alternatives (route + time + cabin, no identity)",
      rk["read"] == SEARCH_ALTERNATIVES["read"] and [a for a, _ in rk["args"]] == ["origin", "destination", "earliest_departure", "cabin"])
ID_VALUES = [r["v"] for r in psql(
    "SELECT passenger_id AS v FROM passengers UNION SELECT first_name FROM passengers UNION SELECT last_name FROM passengers "
    "UNION SELECT email FROM passengers UNION SELECT phone FROM passengers UNION SELECT pnr FROM bookings "
    "UNION SELECT verification_pin FROM bookings UNION SELECT frequentflyer_number FROM frequentflyer "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM service_cases UNION SELECT claim_id FROM baggage_claims UNION SELECT request_id FROM assistance_requests "
    "UNION SELECT session_token FROM traveler_sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 40, len(ID_VALUES))

for t in GUIDE_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)}, about 15-35)", 15 <= len(full) <= 36, len(full))
    check(f"{tool}: returns only the reference columns {REF_COLUMNS}", bool(full) and list(full[0]) == REF_COLUMNS, list(full[0]) if full else None)
    check(f"{tool}: every section is present, in order",
          list(dict.fromkeys(r["section"] for r in full)) == t["sections"], list(dict.fromkeys(r["section"] for r in full)))
    check(f"{tool}: whitespace / separators only = whole guide", len(ref_call(t, " , ")) == len(full))
    check(f"{tool}: unknown term -> 0 rows, no error", ref_call(t, "zzqx-unknown-term") == [])
    check(f"{tool}: '%' and '_' are literal (never a wildcard)",
          ref_call(t, "%") == [] and ref_call(t, "_%_") == [] and not any("%" in f"{r['term']} {r['meaning']}" for r in full))
    check(f"{tool}: SQL-looking input is just a string -> 0 rows, table intact",
          ref_call(t, f"x'); DELETE FROM {t['table']}; --") == [] and int(one(f"SELECT count(*) FROM {t['table']}")) > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no traveller / booking / reviewer / case / claim / session value in the rows", not leaked, leaked[:5])
    check(f"{tool}: no id, email, phone or token pattern",
          not re.search(r"pax-\d|sc-[0-9a-z]{6}|mer-\d|bag-\d|ast-\d|@|\+1-|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

bg = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_baggage_guide")
full = ref_call(bg, "")
hit = ref_call(bg, "charger")
check("get_baggage_guide: lookup 'charger' narrows the guide to ELECTRONICS",
      0 < len(hit) < len(full) and [r["term"] for r in hit] == ["ELECTRONICS"], [r["term"] for r in hit])
check("get_baggage_guide: lookup is case-insensitive", len(ref_call(bg, "CHARGER")) == len(hit))
check("get_baggage_guide: section lookup 'colour' returns exactly the 7 colour codes",
      [r["term"] for r in ref_call(bg, "colour")] == ["BK", "BU", "GY", "RD", "GN", "BN", "MC"])
check("get_baggage_guide: section lookup 'claim note' returns the one standard line",
      [r["meaning"] for r in ref_call(bg, "claim note")] ==
      ["Keep the receipts for any essentials you buy while you wait; Meridian Baggage Services decides any reimbursement "
       "and replies by the date on your case."])
ctr = {r["term"]: r["meaning"] for r in full if r["section"] == "CLAIM_TYPE"}
check("get_baggage_guide: CLAIM_TYPE comes from baggage_claim_types (DELAYED / LOST / DAMAGED / PILFERED) with the 5-day LOST rule",
      list(ctr) == ["DELAYED", "LOST", "DAMAGED", "PILFERED"] and "5 or more days after the flight arrived" in ctr["LOST"], ctr)
psql("UPDATE baggage_claim_types SET meaning = meaning || ' (test)' WHERE claim_type = 'PILFERED'")
check("get_baggage_guide: a baggage_claim_types edit shows up (no copy)",
      [r["meaning"] for r in ref_call(bg, "claim type") if r["term"] == "PILFERED"][0].endswith("(test)"))
psql("UPDATE baggage_claim_types SET meaning = replace(meaning, ' (test)', '') WHERE claim_type = 'PILFERED'")
rfr = {r["term"]: r["meaning"] for r in full if r["section"] == "REPORT_FIELD"}
check("get_baggage_guide: REPORT_FIELD rows come from baggage_report_fields with the claim types each is needed for",
      set(rfr) == {"BAG_TAG", "BRAND", "DELIVERY_ADDRESS", "CONTACT_PHONE", "ITEM_LIST", "DAMAGE_PHOTO"}
      and rfr["DAMAGE_PHOTO"].endswith("Needed for: DAMAGED."), rfr)
check("get_baggage_guide: the interim caps (a reviewer's limit, not the agent's business) are never returned",
      not any(x in ref_blob(full) for x in ("300.00", "500.00", "250.00", "interim_cap")))
check("get_baggage_guide: the bag-type chart and colour codes are the codes the SQL validation accepts",
      {r["term"] for r in full if r["section"] == "BAG_TYPE"} == {x["term"] for x in psql("SELECT term FROM baggage_guide WHERE section='BAG_TYPE'")})

sa = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_assistance_codes")
fa = ref_call(sa, "")
codes = {r["term"]: r["meaning"] for r in fa if r["section"] == "SSR_CODE"}
check("get_assistance_codes: SSR_CODE rows come from ssr_codes (13 IATA codes, in order)",
      list(codes) == ["WCHR", "WCHS", "WCHC", "WCMP", "WCLB", "BLND", "DEAF", "DPNA", "SVAN", "MAAS", "OXYG", "MEDA", "STCR"], list(codes))
check("get_assistance_codes: the plain-words meaning of WCHS lives in the table (table-only text for the agent)",
      codes["WCHS"] == "Wheelchair, no steps: Can walk to and from the seat on board, but cannot climb aircraft steps; needs a "
                       "wheelchair and a lift or jet bridge to board.", codes["WCHS"])
check("get_assistance_codes: OXYG / MEDA say they need medical clearance; STCR is desk-only",
      "Needs medical clearance (MEDA)" in codes["OXYG"] and "Needs medical clearance (MEDA)" in codes["MEDA"]
      and "Arranged by the Accessibility Desk only." in codes["STCR"])
wh = ref_call(sa, "wheelchair")
check("get_assistance_codes: lookup 'wheelchair' -> the wheelchair codes and rules only",
      {"WCHR", "WCHS", "WCHC", "WCMP", "WCLB", "ONE_WHEELCHAIR_CODE", "OWN_WHEELCHAIR"} <= {r["term"] for r in wh} and len(wh) < len(fa),
      [r["term"] for r in wh])
check("get_assistance_codes: section lookup 'standard line' returns the one standard line",
      [r["meaning"] for r in ref_call(sa, "standard line")] ==
      ["Assistance stays pending until the Meridian Accessibility Desk confirms it, and you will hear from them before you fly."])
check("get_assistance_codes: HOW_TO_CHOOSE carries the one-wheelchair-code rule",
      any(r["term"] == "ONE_WHEELCHAIR_CODE" and "at most one of WCHR, WCHS or WCHC" in r["meaning"] for r in fa))

# nothing from the design brief is lost: the facts each agent must work from are in its table
KEEP = {"get_baggage_guide": ["delayed", "lost", "damaged", "pilfered", "hard shell", "soft-sided", "duffel", "backpack",
                              "black", "blue", "clothing", "electronics", "charger", "toiletries", "valuables", "bag tag",
                              "delivery", "photo", "receipts"],
        "get_assistance_codes": ["wchr", "wchs", "wchc", "blnd", "deaf", "dpna", "svan", "meda", "steps", "seat", "service animal",
                                 "medical clearance", "accessibility desk", "pending"]}
for t in GUIDE_TOOLS:
    b = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k.lower() not in b]
    check(f"{t['tool']}: every fact the agent needs is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args, "
           "p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang JOIN pg_namespace ns ON ns.oid = p.pronamespace "
           "WHERE ns.nspname = 'public' AND (p.proname LIKE 'ref\\_%' OR p.proname = 'search_alternatives')")
names = {f["proname"] for f in fns}
check("agent read functions: ref_match + ref_baggage_guide + ref_assistance_codes + search_alternatives",
      names == {"ref_match", "ref_baggage_guide", "ref_assistance_codes", "search_alternatives"}, names)
for f in fns:
    check(f"{f['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          f["lanname"] == "sql" and f["provolatile"] in ("s", "i") and f["prosecdef"] == "f"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", f["prosrc"], re.I),
          {k: f[k] for k in ("lanname", "provolatile", "prosecdef")})
    if f["proname"] in ("ref_baggage_guide", "ref_assistance_codes"):
        check(f"{f['proname']}: one optional, non-identity argument", f["args"] == "p_term text", f["args"])

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
check("reset_data.sql reloads the reference tables, reviewers and the seeded open cases, and clears what was written",
      all(int(one(f"SELECT count(*) FROM {t['table']}")) > 0 for t in AGENT_REF_TOOLS)
      and one("SELECT count(*) FROM reviewers") == "6" and one("SELECT count(*) FROM service_cases WHERE status='OPEN'") == "5"
      and one("SELECT count(*) FROM baggage_claims") == "1" and one("SELECT count(*) FROM assistance_requests") == "1"
      and one("SELECT count(*) FROM service_payments") == "0" and one("SELECT count(*) FROM review_decisions") == "0"
      and one("SELECT count(*) FROM email_log") == "0" and one("SELECT count(*) FROM traveler_sessions") == "0"
      and one("SELECT count(*) FROM agent_audit WHERE action NOT IN ('SERVICE_CASE_OPENED','BAGGAGE_CLAIM_RECORDED','ASSISTANCE_REQUESTED')") == "0")

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{passes + fails} checks, DB reset)")
sys.exit(1 if fails else 0)
