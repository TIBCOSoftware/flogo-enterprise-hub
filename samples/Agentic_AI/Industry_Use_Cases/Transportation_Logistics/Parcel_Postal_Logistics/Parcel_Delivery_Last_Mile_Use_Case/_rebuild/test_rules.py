#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the parcel_delivery DB and assert the business
rules - identity, scoping, the two-step reschedule/redirect, claims (damage_claim_agent), delivery instructions
(delivery_instructions_agent), the reviewer loop (every reason code) and the agents' PostgreSQL reference tools.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> python _rebuild/test_rules.py          (PSQL env var overrides the psql path)
"""
import os, re, subprocess, sys, csv, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, SEARCH_DELIVERY_OPTIONS

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# psql + password lookup (cross-platform): env PSQL > config.md PSQL_PATH > psql on PATH;
# password: env PG_PWD / PG_PASSWORD > config.md PG_PASSWORD (never printed). Install hints: skills-library/AGENT.md
# -> "Prerequisites and preflight".
import re, shutil
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
        "-d", os.environ.get("PG_DB", "parcel_delivery"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails, passes = 0, 0

def lit(v):
    return "'" + str(v).replace("'", "''") + "'"

def sub(sql, params, args):
    assert sorted(re.findall(r"\?(\w+)", sql)) == sorted(p for p, _ in params), sql
    for ph, arg in params:
        sql, n = re.subn(r"\?" + ph + r"(?=[\s;),<>+\-*%/])", lambda _m: lit(args.get(arg, "")), sql)
        assert n == 1, f"placeholder ?{ph} used {n} times"
    return sql

def psql(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode:
        print(r.stderr); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def call(tool, **args):
    t = T[tool]
    if "write" in t:
        psql(sub(*t["write"], args))
    return psql(sub(*t["read"], args))

def check(label, cond, detail=""):
    global fails, passes
    print((("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:600]}")).encode("ascii", "replace").decode())
    fails += 0 if cond else 1
    passes += 1 if cond else 0

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

# ---- identity ----
r = call("verify_recipient", account_ref="K4R2QX", pin="0000")
check("wrong PIN -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_recipient", account_ref=" k4r2qx ", pin="4021")
check("right ref+PIN -> VERIFIED + token", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
emma = r[0]["session_token"]
liam = call("verify_recipient", account_ref="W7M9PL", pin="7788")[0]["session_token"]
noah = call("verify_recipient", account_ref="D3H8TN", pin="5590")[0]["session_token"]
ava = call("verify_recipient", account_ref="A6L3HK", pin="3344")[0]["session_token"]

# ---- scoped reads ----
r = call("get_my_parcels", session_token=emma)
check("Emma's parcels = 3", len([x for x in r if x["tracking_number"]]) == 3 and r[0]["session_status"] == "OK", r)
r = call("get_my_parcels", session_token="not-a-token")
check("bad token -> SESSION_INVALID, no parcels", r[0]["session_status"] == "SESSION_INVALID" and not r[0]["tracking_number"], r)
r = call("get_parcel_detail", session_token=emma, tracking_number="SB100000000001")
check("flagship detail OK, NEEDS_ATTENTION, NSH decoded", r[0]["lookup_status"] == "OK" and r[0]["delivery_health"] == "NEEDS_ATTENTION"
      and "nobody" in (r[0]["exception_label"] or "").lower(), r)
r = call("get_parcel_detail", session_token=ava, tracking_number="SB100000000001")
check("another recipient's parcel -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND", r)
r = call("get_parcel_detail", session_token=noah, tracking_number="SB100000000005")
check("delivered parcel -> delivery_health DELIVERED", r[0]["delivery_health"] == "DELIVERED", r)
r = call("get_tracking_history", session_token=emma, tracking_number="SB100000000001")
check("tracking history = 4 scans ending NSH", len([x for x in r if x["scan_code"]]) == 4 and r[-1]["scan_code"] == "NSH", r)
r = call("get_tracking_history", session_token=ava, tracking_number="SB100000000001")
check("tracking history scoped -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND", r)

# ---- agent tool: search_delivery_options (area + size + flags only, no identity) ----
def opts(area, size, sig="false", hv="false", after=""):
    return psql(sub(*SEARCH_DELIVERY_OPTIONS["read"],
                {"area": area, "parcel_size": size, "needs_signature": sig, "high_value": hv, "after_date": after}))
o = opts("NORTHSIDE", "SMALL")
ids = {x["option_id"] for x in o}
check("Northside small: SLOT-N1/N2 + both pickups, not full/past", {"SLOT-N1", "SLOT-N2", "PU-N-LOCK1", "PU-N-SHOP1"} <= ids
      and "SLOT-N0" not in ids and "SLOT-N3" not in ids, ids)
o = opts("NORTHSIDE", "SMALL", sig="true", hv="true")
ids = {x["option_id"] for x in o}
check("sig+high-value: locker excluded, shop kept", "PU-N-LOCK1" not in ids and "PU-N-SHOP1" in ids, ids)
o = opts("WESTEND", "LARGE")
ids = {x["option_id"] for x in o}
check("large parcel: locker too small excluded, shop kept", "PU-W-LOCK1" not in ids and "PU-W-SHOP1" in ids, ids)

# ---- reschedule guards ----
def rprop(tok, trk, slot): return call("propose_reschedule", session_token=tok, tracking_number=trk, slot_id=slot)[0]
check("wrong area slot", rprop(emma, "SB100000000001", "SLOT-W1")["reason"].startswith("SLOT_WRONG_AREA"))
check("full slot", rprop(emma, "SB100000000001", "SLOT-N3")["reason"].startswith("SLOT_FULL"))
check("past slot", rprop(emma, "SB100000000001", "SLOT-N0")["reason"].startswith("SLOT_IN_PAST"))
check("unknown slot", rprop(emma, "SB100000000001", "SLOT-X9")["reason"].startswith("SLOT_UNKNOWN"))
check("parcel not on account", rprop(emma, "SB100000000005", "SLOT-N1")["reason"].startswith("NOT_FOUND"))
check("another recipient's parcel", rprop(ava, "SB100000000001", "SLOT-N1")["reason"].startswith("NOT_FOUND"))
check("delivered -> ALREADY_DELIVERED", rprop(noah, "SB100000000005", "SLOT-D1")["reason"].startswith("ALREADY_DELIVERED"))
check("out for delivery -> OUT_FOR_FINAL", rprop(liam, "SB100000000004", "SLOT-W1")["reason"].startswith("OUT_FOR_FINAL"))

# ---- redirect guards ----
def dprop(tok, trk, pick): return call("propose_redirect", session_token=tok, tracking_number=trk, pickup_id=pick)[0]
check("signature parcel -> locker SIGNATURE_REQUIRED", dprop(emma, "SB100000000002", "PU-N-LOCK1")["reason"].startswith("SIGNATURE_REQUIRED"))
check("high-value parcel -> locker HIGH_VALUE_LOCKER", dprop(emma, "SB100000000008", "PU-N-LOCK1")["reason"].startswith("HIGH_VALUE_LOCKER"))
check("large parcel -> locker OVERSIZE_FOR_LOCKER", dprop(liam, "SB100000000003", "PU-W-LOCK1")["reason"].startswith("OVERSIZE_FOR_LOCKER"))
check("pickup out of area", dprop(emma, "SB100000000001", "PU-W-LOCK1")["reason"].startswith("PICKUP_OUT_OF_AREA"))
check("unknown pickup", dprop(emma, "SB100000000001", "PU-Z-NONE")["reason"].startswith("PICKUP_UNKNOWN"))
check("out for delivery -> ALREADY_OUT", dprop(liam, "SB100000000004", "PU-W-SHOP1")["reason"].startswith("ALREADY_OUT"))

# ---- two-step reschedule happy path (Emma SB...001 -> SLOT-N1) ----
p1 = rprop(emma, "SB100000000001", "SLOT-N1")
p2 = rprop(emma, "SB100000000001", "SLOT-N1")
check("eligible -> PROPOSED with action + slot", p1["outcome"] == "PROPOSED" and p1["action_id"] and p1["slot_id"] == "SLOT-N1", p1)
check("re-propose idempotent (same action)", p1["action_id"] == p2["action_id"], (p1, p2))
act = p1["action_id"]
check("exactly one pending action", psql("SELECT count(*) n FROM pending_actions")[0]["n"] == "1")

def rconf(tok, a): return call("confirm_reschedule", session_token=tok, action_id=a)[0]
check("confirm bogus id", rconf(emma, "ACT-00000000")["reason"].startswith("ACTION_NOT_FOUND"))
check("confirm by another recipient", rconf(ava, act)["reason"].startswith("ACTION_NOT_FOUND"))
c1 = rconf(emma, act.lower())
check("confirm -> EXECUTED on SLOT-N1", c1["outcome"] == "EXECUTED" and c1["target"] == "SLOT-N1", c1)
c2 = rconf(emma, act)
n = psql("SELECT count(*) n FROM delivery_changes")[0]["n"]
check("re-confirm idempotent, one change row", c2["outcome"] == "EXECUTED" and n == "1", (c2, n))
d = call("get_parcel_detail", session_token=emma, tracking_number="SB100000000001")[0]
check("parcel now RESCHEDULED on SLOT-N1", d["current_status"] == "RESCHEDULED" and d["current_slot"].startswith("SLOT-N1"), d)
check("slot booked_count incremented to 3", psql("SELECT booked_count b FROM delivery_slots WHERE slot_id='SLOT-N1'")[0]["b"] == "3")
check("rescheduled parcel: same slot -> SAME_SLOT", rprop(emma, "SB100000000001", "SLOT-N1")["reason"].startswith("SAME_SLOT"))

# ---- two-step redirect happy path (Emma watch SB...002 -> PU-N-SHOP1 staffed shop) ----
dp = dprop(emma, "SB100000000002", "PU-N-SHOP1")
check("redirect to shop eligible -> PROPOSED", dp["outcome"] == "PROPOSED" and dp["action_id"], dp)
dc = call("confirm_redirect", session_token=emma, action_id=dp["action_id"])[0]
check("confirm redirect -> EXECUTED at PU-N-SHOP1", dc["outcome"] == "EXECUTED" and dc["target"] == "PU-N-SHOP1", dc)
d = call("get_parcel_detail", session_token=emma, tracking_number="SB100000000002")[0]
check("watch now REDIRECTED to the shop", d["current_status"] == "REDIRECTED" and "Corner Mart" in (d["current_pickup"] or ""), d)

# ---- email confirmation (guarded) ----
e = call("email_confirmation", session_token=emma, action_id=act)[0]
check("email authorised for executed change", e["send_status"] == "SEND_OK" and "@" in (e["to_email"] or ""), e)
e = call("email_confirmation", session_token=emma, action_id="ACT-00000000")[0]
check("email refused for unknown action", e["send_status"] == "NOT_SENT", e)
e = call("email_confirmation", session_token=ava, action_id=act)[0]
check("email refused for another recipient's action", e["send_status"] == "NOT_SENT", e)

# ---- expiry ----
p = dprop(liam, "SB100000000003", "PU-W-SHOP1")
check("Liam redirect eligible -> PROPOSED", p["outcome"] == "PROPOSED", p)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p['action_id'])}")
check("expired proposal cannot confirm", call("confirm_redirect", session_token=liam, action_id=p["action_id"])[0]["reason"].startswith("EXPIRED"))

# ---- human-owned requests ----
def case(tok, ty, trk="", stmt="Please help with this.", brief="Recipient request; routed for a human to decide."):
    return call("open_service_case", session_token=tok, request_type=ty, tracking_number=trk, recipient_statement=stmt, brief=brief)[0]
k = case(noah, "damaged_parcel", "SB100000000006", "My ceramic vase arrived smashed.")
check("damaged -> CASE_OPENED, Claims (damaged)", k["outcome"] == "CASE_OPENED" and "damaged" in k["assigned_team"].lower(), k)
check("duplicate case suppressed", case(noah, "DAMAGED_PARCEL", "SB100000000006")["case_id"] == k["case_id"])
check("lost -> Claims (lost parcels)", case(noah, "LOST_PARCEL")["assigned_team"] == "Claims (lost parcels)")
check("bad request type", case(noah, "REFUND")["reason"].startswith("BAD_REQUEST_TYPE"))
check("case without session", case("x", "OTHER")["reason"].startswith("SESSION_INVALID"))
r = call("get_my_cases", session_token=noah)
check("Noah sees his cases", len([x for x in r if x["case_id"]]) >= 2 and r[0]["session_status"] == "OK", r)

# ---- session expiry ----
psql(f"UPDATE recipient_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(emma)}")
check("expired token -> SESSION_INVALID", call("get_my_parcels", session_token=emma)[0]["session_status"] == "SESSION_INVALID")

# ---- PIN brute-force throttle ----
for _ in range(5):
    call("verify_recipient", account_ref="A6L3HK", pin="0000")              # 5 wrong PINs
r = call("verify_recipient", account_ref="A6L3HK", pin="3344")              # correct PIN, but now locked
check("5 wrong PINs -> LOCKED even with the right PIN", r[0]["status"] == "LOCKED" and not r[0]["session_token"], r)
check("wrong PIN on an unknown ref is not tracked", psql("SELECT count(*) n FROM verify_attempts WHERE account_ref='ZZZZZZ'")[0]["n"] == "0")

# ---- audit trail (OWASP traceability) ----
na = lambda a: int(psql(f"SELECT count(*) n FROM agent_audit WHERE action={lit(a)}")[0]["n"])
check("audit logged verify sessions", na("VERIFY_SESSION_ISSUED") >= 4, na("VERIFY_SESSION_ISSUED"))
check("audit logged a proposal + an executed change", na("RESCHEDULE_PROPOSED") >= 1 and na("DELIVERY_CHANGE_EXECUTED") >= 2)
check("audit logged a service case", na("SERVICE_CASE_OPENED") >= 1)

# =====================================================================================================================
# UPGRADE (2026-10-13): claims (damage_claim_agent), delivery instructions (delivery_instructions_agent), the reviewer
# loop (human in the loop) and the agents' PostgreSQL reference tools.
# =====================================================================================================================
from tool_spec import AGENT_REF_TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS
n_ = lambda sql: int(list(psql(sql)[0].values())[0])
v_ = lambda sql: (list(psql(sql)[0].values())[0] if psql(sql) else "")
def tok(ref, pin): return call("verify_recipient", account_ref=ref, pin=pin)[0]["session_token"]
def no_hidden(label, rows, hidden=HIDDEN_COLUMNS):
    cols = set(rows[0].keys()) if rows else set()
    check(label, not (cols & hidden), cols & hidden)

olivia, sofia, noah2, emma2 = tok("M2P7VB", "6150"), tok("T8J4NC", "2468"), tok("D3H8TN", "5590"), tok("K4R2QX", "4021")
check("new personas verify (Olivia, Sofia)", bool(olivia) and bool(sofia))

# ---- claims: rules in SQL, amounts capped in SQL, one open claim per parcel ----
NOTES = ("claim_type: DAMAGED\npackaging_condition: CRUSHED\nlikely_cause: CRUSHING_LOAD\nevidence_to_send: Photos of the "
         "outer box from all sides, a close-up photo of the shipping label, photos of the damaged item, and the box and "
         "packing materials kept for inspection.\nclaim_line: Keep the item and every piece of its packaging until a "
         "Swiftbound claims specialist has decided the claim, because it may be inspected.\nsummary: Box crushed on one "
         "corner; the laptop screen is cracked.")
def claim(t, trk, ty, pack="CRUSHED", cause="CRUSHING_LOAD", amt="", stmt="Box crushed, screen cracked.", notes=NOTES):
    return call("open_damage_claim", session_token=t, tracking_number=trk, claim_type=ty, packaging_condition=pack,
                likely_cause=cause, claimed_amount=amt, recipient_statement=stmt, agent_notes=notes)[0]
c1 = claim(olivia, "SB100000000011", "damaged", stmt="Box crushed on one corner, laptop screen cracked, outer tape intact.")
check("laptop claim -> CLAIM_OPENED", c1["outcome"] == "CLAIM_OPENED" and c1["claim_id"] and c1["case_id"], c1)
check("claimable amount capped at the 1000 coverage limit (declared 1180)",
      c1["amount_under_review"] == "1000.00" and c1["claimed_amount"] == "1180.00" and "coverage limit" in c1["amount_note"], c1)
check("evidence to send comes from the claim guide EVIDENCE row",
      c1["evidence_to_send"] == v_("SELECT meaning FROM claim_guide WHERE section='EVIDENCE' AND term='DAMAGED'"), c1)
check("claim routed to Claims (damaged parcels) with a reply date", c1["assigned_team"] == "Claims (damaged parcels)" and c1["reply_by"], c1)
no_hidden("claim readback carries no hidden columns", [c1])
OCASE = c1["case_id"]
k = psql(f"SELECT request_type, requested_amount, parked_action, status, agent_brief FROM service_cases WHERE case_id={lit(OCASE)}")[0]
check("case parks COMPENSATION:<claim> for 1000, OPEN, brief = the agent's answer",
      k["request_type"] == "DAMAGED_PARCEL" and k["requested_amount"] == "1000.00"
      and k["parked_action"] == "COMPENSATION:" + c1["claim_id"] and k["status"] == "OPEN" and k["agent_brief"] == NOTES, k)
check("audit CLAIM_OPENED", n_(f"SELECT count(*) FROM agent_audit WHERE action='CLAIM_OPENED' AND ref={lit(c1['claim_id'])}") == 1)
c2 = claim(olivia, "SB100000000011", "DAMAGED")
check("second claim on the same parcel -> same claim, no new row",
      c2["claim_id"] == c1["claim_id"] and n_("SELECT count(*) FROM damage_claims WHERE parcel_id=(SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000011')") == 1, c2)
c = claim(noah2, "SB100000000006", "DAMAGED", amt="$200")
check("damaged in transit (DMG) -> opened, capped at the 85 declared value",
      c["outcome"] == "CLAIM_OPENED" and c["amount_under_review"] == "85.00" and "declared value" in c["amount_note"], c)
check("BAD_AMOUNT (text)", claim(noah2, "SB100000000005", "MISSING_CONTENTS", amt="lots")["reason_code"] == "BAD_AMOUNT")
check("BAD_AMOUNT (negative)", claim(noah2, "SB100000000005", "MISSING_CONTENTS", amt="-5")["reason_code"] == "BAD_AMOUNT")
check("delivered parcel claimed LOST -> DELIVERED_NOT_LOST", claim(noah2, "SB100000000005", "LOST")["reason_code"] == "DELIVERED_NOT_LOST")
check("not overdue -> NOT_YET_LOST", claim(emma2, "SB100000000001", "LOST")["reason_code"] == "NOT_YET_LOST")
check("not delivered, no DMG -> NOT_DELIVERED_YET (damaged)", claim(emma2, "SB100000000001", "DAMAGED")["reason_code"] == "NOT_DELIVERED_YET")
check("not delivered -> NOT_DELIVERED_YET (missing)", claim(emma2, "SB100000000001", "MISSING_CONTENTS")["reason_code"] == "NOT_DELIVERED_YET")
check("another recipient's parcel -> NOT_FOUND", claim(olivia, "SB100000000001", "DAMAGED")["reason_code"] == "NOT_FOUND")
check("unknown claim type -> BAD_CLAIM_TYPE", claim(emma2, "SB100000000001", "BROKEN")["reason_code"] == "BAD_CLAIM_TYPE")
check("no session -> SESSION_INVALID", claim("forged", "SB100000000011", "DAMAGED")["reason_code"] == "SESSION_INVALID")
check("seeded lost claim -> ALREADY_OPEN (not a second claim)",
      claim(tok("H5R8WD", "9137"), "SB100000000013", "LOST", pack="", cause="")["outcome"] == "ALREADY_OPEN")
c = claim(noah2, "SB100000000005", "MISSING_CONTENTS", pack="squashed a bit", cause="gremlins", amt="20")
row = psql("SELECT packaging_condition p, cause_category c, ignored_terms i FROM damage_claims WHERE claim_id=" + lit(c["claim_id"] or ""))
check("terms not in the claim guide are recorded as NOT_STATED / UNKNOWN and listed as ignored",
      c["outcome"] == "CLAIM_OPENED" and row and row[0]["p"] == "NOT_STATED" and row[0]["c"] == "UNKNOWN"
      and "packaging=SQUASHED_A_BIT" in row[0]["i"] and "cause=GREMLINS" in row[0]["i"], (c, row))
psql("UPDATE parcels SET expected_delivery = now() - interval '45 days' WHERE tracking_number='SB100000000015'")
check("delivered 45 days ago -> CLAIM_WINDOW_CLOSED",
      claim(tok("P9Q2ZE", "8064"), "SB100000000015", "DAMAGED")["reason_code"] == "CLAIM_WINDOW_CLOSED")

# ---- delivery instructions: safe place from a table, risky flags block, codes never stored, two steps ----
TXT = "leave behind the blue side gate, code 4521, dog in the yard, not on the porch"
AGN = ("safe_place: SIDE_GATE\naccess_code_present: yes\nhazards: DOG\nrisk_flags: NONE\ndriver_note: Leave behind the "
       "blue side gate (gate code [code withheld]); dog in the yard; not on the porch.\ndriver_line: If the safe place is "
       "not safe, not dry or not accessible, keep the parcel, leave a delivery card and try again the next working day.")
def iprop(t, trk, place="SIDE_GATE", code="yes", haz="DOG", flags="NONE", text=TXT, notes=AGN):
    return call("propose_delivery_instructions", session_token=t, tracking_number=trk, safe_place=place,
                access_code_present=code, hazards=haz, risk_flags=flags, instructions_text=text, agent_notes=notes)[0]
p1 = iprop(sofia, "SB100000000009")
check("side gate + code + dog -> PROPOSED", p1["outcome"] == "PROPOSED" and p1["action_id"] and p1["safe_place"] == "SIDE_GATE", p1)
check("access code flagged, never repeated", p1["access_code_present"] == "t" and "4521" not in p1["driver_note"]
      and "[code withheld]" in p1["driver_note"], p1)
check("hazard DOG kept (validated against the guide)", p1["hazards"] == "DOG", p1)
check("the code is stored nowhere (pending notes + agent notes)",
      n_("SELECT count(*) FROM pending_actions WHERE notes_masked LIKE '%4521%' OR agent_notes LIKE '%4521%'") == 0)
check("re-propose is idempotent (same action)", iprop(sofia, "SB100000000009")["action_id"] == p1["action_id"])
def iconf(t, a): return call("confirm_delivery_instructions", session_token=t, action_id=a)[0]
check("confirm bogus id -> ACTION_NOT_FOUND", iconf(sofia, "ACT-00000000")["reason_code"] == "ACTION_NOT_FOUND")
check("confirm by another recipient -> ACTION_NOT_FOUND", iconf(olivia, p1["action_id"])["reason_code"] == "ACTION_NOT_FOUND")
ic = iconf(sofia, p1["action_id"].lower())
check("confirm -> EXECUTED, SIDE_GATE saved", ic["outcome"] == "EXECUTED" and ic["safe_place"] == "SIDE_GATE", ic)
iconf(sofia, p1["action_id"])
check("re-confirm idempotent: one saved row", n_("SELECT count(*) FROM delivery_instructions") == 1)
d = call("get_parcel_detail", session_token=sofia, tracking_number="SB100000000009")[0]
check("parcel detail shows the saved safe place + hazard", (d["saved_safe_place"] or "").startswith("SIDE_GATE") and "DOG" in d["saved_safe_place"], d)
check("audit INSTRUCTIONS_PROPOSED + INSTRUCTIONS_SAVED",
      n_("SELECT count(*) FROM agent_audit WHERE action IN ('INSTRUCTIONS_PROPOSED','INSTRUCTIONS_SAVED')") == 2)
check("a stored code is impossible (CHECK constraint)", "notes_masked" in open(os.path.join(DIR, "database.sql"), encoding="utf-8").read()
      and n_("SELECT count(*) FROM pg_constraint WHERE conrelid='delivery_instructions'::regclass AND contype='c'") >= 1)
e = call("email_confirmation", session_token=sofia, action_id=p1["action_id"])[0]
check("email for saved instructions -> SEND_OK, logged, no code in the body",
      e["send_status"] == "SEND_OK" and "4521" not in e["body"] and n_(f"SELECT count(*) FROM email_log WHERE reference_id={lit(p1['action_id'])}") == 1, e)
r = iprop(sofia, "SB100000000009", place="FRONT_DOOR", flags="NONE", text="just leave it on the street by the mailbox", notes="")
check("agent missed it, SQL phrase scan blocks 'on the street' -> RISKY_INSTRUCTION", r["reason_code"] == "RISKY_INSTRUCTION", r)
r = iprop(sofia, "SB100000000009", place="PORCH", flags="ANY_NEIGHBOUR", text="porch, or someone nearby", notes="")
check("agent flag ANY_NEIGHBOUR blocks -> RISKY_INSTRUCTION", r["reason_code"] == "RISKY_INSTRUCTION" and "neighbour" in r["reason"].lower(), r)
r = iprop(sofia, "SB100000000009", place="PORCH", code="no", haz="NONE", flags="MADE_UP_FLAG", text="the porch is fine", notes="")
check("unknown agent flag is ignored -> PROPOSED", r["outcome"] == "PROPOSED", r)
check("safe place not in the table -> SAFE_PLACE_UNKNOWN", iprop(sofia, "SB100000000009", place="ROOF")["reason_code"] == "SAFE_PLACE_UNKNOWN")
check("signature parcel + unattended place -> SIGNATURE_REQUIRED",
      iprop(sofia, "SB100000000010", place="FRONT_DOOR", text="front door please", code="no", haz="NONE")["reason_code"] == "SIGNATURE_REQUIRED")
check("signature parcel + HAND_TO_RECIPIENT -> PROPOSED",
      iprop(sofia, "SB100000000010", place="HAND_TO_RECIPIENT", text="hand it to me", code="no", haz="NONE")["outcome"] == "PROPOSED")
check("high value + unattended -> HIGH_VALUE_SAFE_PLACE",
      iprop(emma2, "SB100000000008", place="PORCH", text="porch", code="no", haz="NONE")["reason_code"] == "HIGH_VALUE_SAFE_PLACE")
check("high value + BUILDING_RECEPTION (attended) -> PROPOSED",
      iprop(emma2, "SB100000000008", place="BUILDING_RECEPTION", text="reception desk", code="no", haz="NONE")["outcome"] == "PROPOSED")
check("redirected parcel -> REDIRECTED_TO_PICKUP", iprop(emma2, "SB100000000002", place="FRONT_DOOR")["reason_code"] == "REDIRECTED_TO_PICKUP")
check("delivered parcel -> ALREADY_DELIVERED", iprop(noah2, "SB100000000005", place="FRONT_DOOR")["reason_code"] == "ALREADY_DELIVERED")
check("another recipient's parcel -> NOT_FOUND", iprop(olivia, "SB100000000009")["reason_code"] == "NOT_FOUND")
p = iprop(sofia, "SB100000000010", place="HAND_TO_RECIPIENT", text="hand it to me", code="no", haz="NONE")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p['action_id'])}")
check("expired instructions proposal -> EXPIRED", iconf(sofia, p["action_id"])["reason_code"] == "EXPIRED")

# ---- the reviewer loop (human in the loop) ----
def rv(sid, code): return call("verify_reviewer", staff_id=sid, code=code)[0]
r = rv("SWB-4101", "000000")
check("reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = rv("swb 4101", "418302")
check("reviewer right code -> VERIFIED, REVIEWER, team", r["status"] == "VERIFIED" and r["role"] == "REVIEWER"
      and r["team"] == "Claims (damaged parcels)", r)
hannah = r["session_token"]
victor, mei, grace = rv("SWB-4102", "905127")["session_token"], rv("SWB-4103", "336914")["session_token"], rv("SWB-4105", "260581")["session_token"]
check("reviewer token is not a recipient token", call("get_my_parcels", session_token=hannah)[0]["session_status"] == "SESSION_INVALID")
check("recipient token is not a reviewer token", call("get_review_queue", session_token=olivia)[0]["status"] == "NOT_REVIEWER")
qh = call("get_review_queue", session_token=hannah)
ids = [x["case_id"] for x in qh]
check("Hannah's queue: the lens case + Olivia's laptop case, no other team's cases",
      "SC-00001" in ids and OCASE in ids and "SC-00002" not in ids and "SC-00003" not in ids and "SC-00004" not in ids, ids)
no_hidden("queue shows no recipient PII", qh, HIDDEN_FROM_REVIEWER)
check("queue never shows a full last name", not any("Grant" in (x["recipient"] or "") for x in qh), qh)
check("another team's case is invisible -> NOT_FOUND", call("get_review_case", session_token=hannah, case_id="SC-00002")[0]["status"] == "NOT_FOUND")
rc = call("get_review_case", session_token=hannah, case_id=OCASE)[0]
check("case view: facts (declared value, coverage limit, packaging), AI brief, max 1000, limit 500",
      rc["status"] == "OK" and "coverage limit" in rc["facts"] and "CRUSHED" in rc["facts"] and rc["agent_brief"] == NOTES
      and rc["max_approvable"] == "1000.00" and rc["your_approval_limit"] == "500.00" and "senior reviewer" in rc["options"], rc)
no_hidden("case view minimum necessary", [rc], HIDDEN_FROM_REVIEWER)
def decide(t, cid, dec="APPROVE", amt="", note="Photos match the description.", msg="We have approved your claim."):
    return call("decide_review_case", session_token=t, case_id=cid, decision=dec, amount=amt, internal_note=note, customer_message=msg)[0]
check("recipient cannot decide -> NOT_REVIEWER, nothing written",
      decide(olivia, OCASE)["outcome"] == "NOT_REVIEWER" and n_("SELECT count(*) FROM review_decisions") == 0)
check("other team's case -> NOT_YOUR_TEAM", decide(hannah, "SC-00002")["reason_code"] == "NOT_YOUR_TEAM")
check("unknown case -> NOT_FOUND", decide(hannah, "SC-99999")["reason_code"] == "NOT_FOUND")
check("note too short -> NOTE_REQUIRED", decide(hannah, OCASE, note="ok")["reason_code"] == "NOTE_REQUIRED")
check("bad decision -> INVALID_DECISION", decide(hannah, OCASE, dec="maybe")["reason_code"] == "INVALID_DECISION")
check("amount above the claimable -> AMOUNT_INVALID", decide(victor, OCASE, amt="2000")["reason_code"] == "AMOUNT_INVALID")
check("negative amount -> AMOUNT_INVALID", decide(victor, OCASE, amt="-5")["reason_code"] == "AMOUNT_INVALID")
r = decide(hannah, OCASE)
check("1000 above Hannah's 500 limit -> OVER_AUTHORITY, case stays OPEN, nothing paid",
      r["reason_code"] == "OVER_AUTHORITY" and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"]
      and n_("SELECT count(*) FROM compensation_payments") == 0 and n_("SELECT count(*) FROM review_decisions") == 0, r)
r = decide(hannah, "SC-00001", amt="400", note="Lens hood and glass damage match the photos; partial for the hood.",
           msg="We approved $400.00 compensation for your camera lens.")
check("Hannah approves the lens case at 400 (within her limit) -> APPROVED, compensation paid",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "400.00" and "CMP-" in (r["executed_action"] or ""), r)
check("DB: payment row 400 + case APPROVED + CASE_DECIDED audit by SWB-4101 + COMPENSATION_PAID",
      n_("SELECT count(*) FROM compensation_payments WHERE case_id='SC-00001' AND amount=400") == 1
      and v_("SELECT status FROM service_cases WHERE case_id='SC-00001'") == "APPROVED"
      and n_("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='SC-00001' AND actor='SWB-4101'") == 1
      and n_("SELECT count(*) FROM agent_audit WHERE action='COMPENSATION_PAID'") == 1)
check("double decision -> ALREADY_DECIDED", decide(victor, "SC-00001")["reason_code"] == "ALREADY_DECIDED")
r = decide(victor, OCASE, note="Senior approval: screen damage consistent with crushing.", msg="Your laptop claim is approved for $1,000.00.")
check("Victor (senior) approves the full 1000 -> APPROVED, paid", r["outcome"] == "APPROVED"
      and n_(f"SELECT count(*) FROM compensation_payments WHERE case_id={lit(OCASE)} AND amount=1000") == 1, r)
r = decide(mei, "SC-00003", dec="REJECT", note="Seal photos show the box was intact at delivery.", msg="We could not approve this claim.")
check("reject executes nothing", r["outcome"] == "REJECTED" and n_("SELECT count(*) FROM compensation_payments WHERE case_id='SC-00003'") == 0
      and v_("SELECT status FROM service_cases WHERE case_id='SC-00003'") == "REJECTED", r)
r = decide(grace, "SC-00004", note="Driver photo shows number 15; parcel recovered.", msg="We found your lamp and will deliver it tomorrow.")
check("case without an amount: approve -> no automatic action, no payment",
      r["outcome"] == "APPROVED" and "no automatic action" in r["executed_action"] and n_("SELECT count(*) FROM compensation_payments WHERE case_id='SC-00004'") == 0, r)
check("compensation row refuses an unparked case", n_("SELECT count(*) FROM compensation_payment_row('CLM-00002', 10, 'SC-00004')") == 0)
mc = [x for x in call("get_my_cases", session_token=olivia) if x["case_id"] == OCASE]
check("recipient sees APPROVED + message + compensation, never the note or the reviewer",
      mc and mc[0]["status"] == "APPROVED" and mc[0]["compensation_paid"] == "1000.00" and "approved" in mc[0]["customer_message"].lower(), mc)
no_hidden("my_cases carries no hidden columns", mc)
e = call("email_confirmation", session_token=olivia, action_id=OCASE)[0]
check("email for a decided case -> SEND_OK with the compensation line", e["send_status"] == "SEND_OK" and "1,000.00" in e["body"]
      and "Senior approval" not in e["body"], e)
ncase = v_("SELECT case_id FROM service_cases WHERE tracking_number='SB100000000006' AND parked_action LIKE 'COMPENSATION:%'")
e = call("email_confirmation", session_token=noah2, action_id=ncase)[0]
check("email for an undecided case -> NOT_SENT NOT_DECIDED", e["send_status"] == "NOT_SENT" and e["reason"].startswith("NOT_DECIDED"), e)
e = call("email_confirmation", session_token=noah2, action_id=OCASE)[0]
check("email for another recipient's case -> NOT_SENT", e["send_status"] == "NOT_SENT", e)
for _ in range(5):
    rv("SWB-4106", "000000")
r = rv("SWB-4106", "649273")
check("5 wrong staff codes -> LOCKED even with the right code", r["status"] == "LOCKED" and not r["session_token"], r)
check("audit REVIEWER_VERIFY rows", n_("SELECT count(*) FROM agent_audit WHERE action='REVIEWER_VERIFY'") >= 4)

# ---- agent reference tools (PostgreSQL, identity-free) ----
FORBIDDEN = re.compile(r"@|RCP-|SC-\d|CLM-|CMP-|SB1\d{11}|SWB-|\b(Emma|Liam|Noah|Ava|Olivia|Sofia|Lucas|Chloe|Hannah|Victor|"
                       r"Mei|Daniel|Grace|Owen|Carter|Walsh|Reyes|Thompson|Grant|Ramirez|Bennett|Nguyen)\b|K4R2QX|M2P7VB|T8J4NC")
for t in AGENT_REF_TOOLS:
    sql, params = t["read"]
    if t["sections"]:
        allr = psql(sub(sql, params, {"term": ""}))
        secs = {x["section"] for x in allr}
        check(f"{t['fn']}('') returns the whole guide ({len(allr)} rows, every section)", set(t["sections"]) <= secs and 15 <= len(allr) <= 40, secs)
        check(f"{t['fn']}: columns are exactly section/term/meaning", set(allr[0].keys()) == {"section", "term", "meaning"})
        check(f"{t['fn']}: no personal data in any row", not any(FORBIDDEN.search(" ".join(x.values())) for x in allr),
              [x for x in allr if FORBIDDEN.search(" ".join(x.values()))][:2])
        check(f"{t['fn']}('zzqx unknown') -> 0 rows, no error", psql(sub(sql, params, {"term": "zzqx unknown"})) == [])
        check(f"{t['fn']}: a NULL-ish separator-only term returns the whole guide",
              len(psql(sub(sql, params, {"term": " , ; "}))) == len(allr))
    pr = psql(f"SELECT p.provolatile v, p.prosrc s FROM pg_proc p WHERE p.proname = {lit(t['fn'])}")
    check(f"{t['fn']}: STABLE and SELECT-only", pr and pr[0]["v"] == "s"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter)\b", pr[0]["s"], re.I), pr)
    check(f"{t['agent']}: tool args carry no identity", not any(a in ("session_token", "account_ref", "pin", "tracking_number")
                                                                 for a, _ in t["args"]))
cg = lambda term: psql(sub(AGENT_REF_TOOLS[1]["read"][0], AGENT_REF_TOOLS[1]["read"][1], {"term": term}))
check("claim guide lookup 'crushed' finds the CRUSHED packaging row", any(x["term"] == "CRUSHED" for x in cg("crushed")))
check("claim guide section lookup 'claim_line' -> the standard line", any(x["section"] == "CLAIM_LINE" for x in cg("claim_line")))
check("claim guide WHO_DECIDES rows come from service_teams (3 claim teams)",
      len([x for x in cg("") if x["section"] == "WHO_DECIDES"]) == n_("SELECT count(*) FROM service_teams WHERE claim_type IS NOT NULL"))
check("claim guide CLAIM_TYPE terms = the claim types routed in service_teams",
      {x["term"] for x in cg("") if x["section"] == "CLAIM_TYPE"} == {x["claim_type"] for x in psql("SELECT claim_type FROM service_teams WHERE claim_type IS NOT NULL")})
ig = lambda term: psql(sub(AGENT_REF_TOOLS[2]["read"][0], AGENT_REF_TOOLS[2]["read"][1], {"term": term}))
check("instructions guide SAFE_PLACE rows = the safe_places table SQL checks",
      {x["term"] for x in ig("") if x["section"] == "SAFE_PLACE"} == {x["place_code"] for x in psql("SELECT place_code FROM safe_places")})
check("instructions guide RISK_FLAG rows = instruction_risk_flags",
      {x["term"] for x in ig("") if x["section"] == "RISK_FLAG"} == {x["flag_code"] for x in psql("SELECT flag_code FROM instruction_risk_flags")})
check("instructions guide lookup 'side gate' finds SIDE_GATE", any(x["term"] == "SIDE_GATE" for x in ig("side gate")))
check("instructions guide lookup 'dog, steps' finds both hazards", {"DOG", "STEPS"} <= {x["term"] for x in ig("dog, steps")})
check("no '%' in reference text (literal-match safe)", not any("%" in x["meaning"] for x in cg("") + ig("")))
o = psql(sub(*AGENT_REF_TOOLS[0]["read"], {"area": "WESTEND", "parcel_size": "SMALL", "needs_signature": "false", "high_value": "false", "after_date": ""}))
check("delivery options tool (kept) still returns identity-free options", o and set(o[0].keys()) == {"option_type", "option_id", "title", "detail", "when_available"})

# ---- every MCP tool's SQL substitutes cleanly; recipient tools never leak hidden columns ----
check("18 MCP tools in the spec, 4 reviewer tools", len(TOOLS) == 18 and REVIEWER_TOOLS <= set(T))

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
