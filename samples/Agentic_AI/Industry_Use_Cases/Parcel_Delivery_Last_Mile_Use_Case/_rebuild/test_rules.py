#!/usr/bin/env python3
"""Run the EXACT tool SQL from tool_spec.py against the parcel_delivery DB and assert the business rules.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> python _rebuild/test_rules.py          (PSQL env var overrides the psql path)
"""
import os, re, subprocess, sys, csv, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, SEARCH_DELIVERY_OPTIONS

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "parcel_delivery"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = 0

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
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    fails += 0 if cond else 1

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

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  (DB reset)")
sys.exit(1 if fails else 0)
