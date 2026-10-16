#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the realestate_governed DB and assert the
business rules on DB state - identity, scoped reads, the two-step showing booking (and the Nurturing -> Active stage
move), follow-ups, cases and the full reviewer loop, plus the A2A agents' read-only reference tools (ref_* functions:
filtering, unknown input, no personal data, SELECT-only). No Flogo needed. Re-loads reset_data.sql first and again at the
end (re-runnable).

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
ENV = dict(os.environ, PGPASSWORD=PWD, PGCLIENTENCODING="UTF8")
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "realestate_governed"),
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
    msg = ("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:500]}")
    print(msg.encode("ascii", "replace").decode())
    if cond: passes += 1
    else: fails += 1


def reset():
    subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


def f2(v):
    return round(float(v), 2) if v not in (None, "") else None


def day(k):
    """CURRENT_DATE + k days as YYYY-MM-DD (from the DB clock)."""
    return val(f"SELECT to_char(current_date + {int(k)}, 'YYYY-MM-DD') AS v")


def login(email, code):
    r = one("verify_lead", email=email, code=code)
    return r.get("session_token") or "missing"


def rlogin(sid, code):
    r = one("verify_reviewer", staff_id=sid, code=code)
    return r.get("session_token") or "missing"


def ps(tok, listing, slot):
    return one("propose_showing", session_token=tok, listing_id=listing, slot=slot)


def cs(tok, pid):
    return one("confirm_showing", session_token=tok, proposal_id=pid)


def oc(tok, typ, summary="", ref="", amount="", brief=""):
    return one("open_service_case", session_token=tok, request_type=typ, summary=summary, reference_id=ref, amount=amount,
               agent_brief=brief)


def dc(tok, case, decision, amount, note, msg):
    return one("decide_review_case", session_token=tok, case_id=case, decision=decision, amount=amount, internal_note=note,
               customer_message=msg)


reset()
TODAY = day(0)

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
check("every read of a lead tool starts with the session token", all(t["args"][0][0] == "session_token"
      for t in TOOLS if t["tool"] not in ("verify_lead", "verify_reviewer")))

# ---------------------------------------------------------------- lead identity
DELIA_E, MARCO_E, KIRAN_E = "delia.sorensen@example.com", "marco.sandoval@example.com", "kiran.bhatt@example.com"
RUSSELL_E, LENA_E, MILES_E, ELISE_E = ("russell.thorne@example.com", "lena.marchetti@example.com", "miles.hargrove@example.com",
                                       "elise.navarro@example.com")
r = one("verify_lead", email=DELIA_E, code="0000")
check("wrong code -> VERIFY_FAILED, no token, no hint", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "do not match" in r["reason_text"], r)
check("wrong code issues no session", n("SELECT count(*) FROM sessions") == 0)
r = one("verify_lead", email="nobody@example.com", code="5172")
check("unknown e-mail -> VERIFY_FAILED (same text)", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "do not match" in r["reason_text"], r)
r = one("verify_lead", email="  Delia.Sorensen@EXAMPLE.com ", code="5172")
check("e-mail is case-insensitive -> VERIFIED with token, first name and today", r["outcome"] == "VERIFIED" and r["session_token"]
      and r["first_name"] == "Delia" and r["today"].startswith(TODAY), r)
delia = r["session_token"]
check("one LEAD session for Delia", n("SELECT count(*) FROM sessions WHERE role='LEAD' AND lead_id='LEAD-2026-00101'") == 1)
marco, kiran, russell = login(MARCO_E, "3846"), login(KIRAN_E, "9021"), login(RUSSELL_E, "6630")
lena, miles, elise = login(LENA_E, "4419"), login(MILES_E, "7305"), login(ELISE_E, "2287")
check("all seven demo leads verify", "missing" not in (delia, marco, kiran, russell, lena, miles, elise))
BAD = "bogus-token-0000"

# throttle (Elise is Lost - her login is not needed again)
for _ in range(5):
    one("verify_lead", email=ELISE_E, code="1111")
r = one("verify_lead", email=ELISE_E, code="2287")
check("THROTTLE: 5 failures in 15 min -> LOCKED even with the right code, no new session", r["outcome"] == "LOCKED"
      and not r["session_token"] and n("SELECT count(*) FROM sessions WHERE lead_id='LEAD-2026-00107'") == 1, r)
check("LOCKED text says paused 15 minutes", "15 minutes" in r["reason_text"], r)

# ---------------------------------------------------------------- scoped reads
p = one("get_my_profile", session_token=delia)
check("profile: Delia, Buyer, Nurturing, Cedar Hollow, pre-approval on file, agent Marisol, today",
      p["status"] == "OK" and p["name"] == "Delia Sorensen" and p["journey_stage"] == "Nurturing" and p["preferred_area"] == "Cedar Hollow"
      and "725,000" in p["financing"] and p["assigned_agent"].startswith("Marisol Vance") and p["today"].startswith(TODAY)
      and p["budget"] == "$500,000 - $750,000", p)
p = one("get_my_profile", session_token=russell)
check("seller profile lists his own listing LST-50014 at $612,000", "LST-50014" in (p["my_listings"] or "") and "$612,000" in p["my_listings"], p)
check("bad token -> SESSION_INVALID (profile)", one("get_my_profile", session_token=BAD)["status"] == "SESSION_INVALID")
rows = call("search_listings", session_token=delia, area="Cedar Hollow", max_price="750000", min_bedrooms="3", property_type="single family")
ids = [x["listing_id"] for x in rows]
check("search: Cedar Hollow <= $750k, 3+ bd, single family -> LST-50001/50002/50003 + Pending 50004, not 50005/50006",
      {"LST-50001", "LST-50002", "LST-50003", "LST-50004"} == set(ids), ids)
check("search: Active rows first, Pending shown with its status", rows[-1]["listing_id"] == "LST-50004" and rows[-1]["listing_status"] == "Pending", rows[-1])
rows = call("search_listings", session_token=delia, area="", max_price="$1.2M")
ids = [x["listing_id"] for x in rows]
check("search never returns Sold or Withdrawn listings", "LST-50022" not in ids and "LST-50033" not in ids and len(ids) == 12, ids)
rows = call("search_listings", session_token=delia, area="willow", keywords="office")
check("search keywords: 'office' in Willow Bend -> LST-50016 only", [x["listing_id"] for x in rows] == ["LST-50016"], rows)
rows = call("search_listings", session_token=delia, area="downtown", min_price="500k", property_type="townhome")
check("search: price parsing ('500k') + type synonym ('townhome') -> LST-50032", [x["listing_id"] for x in rows] == ["LST-50032"], rows)
check("search NO_MATCH for an unknown area", one("search_listings", session_token=delia, area="Atlantis")["status"] == "NO_MATCH")
check("search with a bad token -> SESSION_INVALID", one("search_listings", session_token=BAD)["status"] == "SESSION_INVALID")
d1 = one("get_listing_details", session_token=delia, listing_id="1418 Quillfeather Lane")
check("details by street address -> LST-50001 with features, agent, open slots, not her listing",
      d1["status"] == "OK" and d1["listing_id"] == "LST-50001" and "home office" in d1["features"]
      and d1["listing_agent"] == "Marisol Vance" and d1["your_listing"] == "no" and d1["next_open_slots"], d1)
d2 = one("get_listing_details", session_token=lena, listing_id="lst50020")
check("details: price history shows the seeded $895,000 -> $865,000 cut; Lena's own listing", "$895,000 -> $865,000" in d2["price_history"]
      and d2["your_listing"] == "yes", d2)
check("details: Withdrawn listing -> NOT_FOUND", one("get_listing_details", session_token=delia, listing_id="LST-50033")["status"] == "NOT_FOUND")
check("details: Pending listing shows no slots", "Pending" in one("get_listing_details", session_token=delia, listing_id="LST-50004")["next_open_slots"])
av = call("get_showing_availability", session_token=delia, listing_id="LST-50001", date=day(2))
slots = [x["slot"] for x in av]
check("availability day+2: open slots on the hour 09:00-18:00, Miles's 11:00 excluded", av[0]["status"] == "OK"
      and f"{day(2)} 11:00" not in slots and f"{day(2)} 10:00" in slots and f"{day(2)} 18:00" in slots and len(slots) == 9, slots)
check("availability: Pending listing -> LISTING_NOT_ACTIVE",
      one("get_showing_availability", session_token=delia, listing_id="LST-50004", date=day(2))["status"] == "LISTING_NOT_ACTIVE")
check("availability: bad date -> INVALID_DATE",
      one("get_showing_availability", session_token=delia, listing_id="LST-50001", date="next Saturday")["status"] == "INVALID_DATE")
check("availability: past date -> NO_SLOTS",
      one("get_showing_availability", session_token=delia, listing_id="LST-50001", date=day(-2))["status"] == "NO_SLOTS")
check("availability: empty date -> next 3 days, up to 12 slots",
      0 < len(call("get_showing_availability", session_token=delia, listing_id="LST-50002", date="")) <= 12)
sh = call("get_my_showings", session_token=delia)
check("my showings: Delia sees only her own (APT-70003 past), never Miles's APT-70001",
      [x["appointment_id"] for x in sh] == ["APT-70003"] and sh[0]["timing"] == "past", sh)
check("my showings: NONE for Kiran", one("get_my_showings", session_token=kiran)["status"] == "NONE")
ag = one("get_my_agent", session_token=kiran)
check("my agent: Kiran -> Gabriela Fenwick with business contact", ag["agent_name"] == "Gabriela Fenwick" and "@brightpathrealty" in ag["agent_email"], ag)
ms = one("get_market_stats", session_token=delia, area="northgate")
check("market stats: Northgate 6.4 months -> buyer-leaning (computed in SQL)", ms["area"] == "Northgate" and "Buyer-leaning" in ms["market_note"], ms)
check("market stats: empty area -> all four areas", len(call("get_market_stats", session_token=delia, area="")) == 4)
check("market stats: Cedar Hollow 2.8 months -> seller-leaning",
      "Seller-leaning" in one("get_market_stats", session_token=delia, area="Cedar Hollow")["market_note"])
check("my cases: NONE for Delia; Miles sees his 2 seeded cases",
      one("get_my_cases", session_token=delia)["status"] == "NONE" and len(call("get_my_cases", session_token=miles)) == 2)

# ---------------------------------------------------------------- showing rules (every reason code)
S3 = f"{day(3)} 14:00"
def blocked(tok, listing, slot, code, label):
    r = ps(tok, listing, slot)
    check(label, r["outcome"] == "BLOCKED" and r["reason_code"] == code and not r["proposal_id"], r)
    return r
blocked(marco, "LST-50001", S3, "LEAD_STAGE_BLOCKED", "Marco (Under Contract) -> LEAD_STAGE_BLOCKED")
blocked(elise, "LST-50030", S3, "LEAD_STAGE_BLOCKED", "Elise (Lost) -> LEAD_STAGE_BLOCKED")
blocked(delia, "LST-59999", S3, "LISTING_NOT_FOUND", "unknown listing -> LISTING_NOT_FOUND")
blocked(delia, "LST-50033", S3, "LISTING_NOT_FOUND", "withdrawn listing -> LISTING_NOT_FOUND")
r = blocked(kiran, "77 Halcyon Ct", S3, "LISTING_NOT_ACTIVE", "Pending listing (by address) -> LISTING_NOT_ACTIVE")
check("LISTING_NOT_ACTIVE text says an offer was accepted", "accepted an offer" in r["reason_text"], r)
blocked(delia, "LST-50022", S3, "LISTING_NOT_ACTIVE", "Sold listing -> LISTING_NOT_ACTIVE")
blocked(delia, "LST-50001", "next Saturday at 2", "INVALID_SLOT", "unparseable time -> INVALID_SLOT")
blocked(delia, "LST-50001", f"{day(-1)} 10:00", "SLOT_IN_PAST", "yesterday -> SLOT_IN_PAST")
soon = val("SELECT to_char(date_trunc('hour', localtimestamp) + interval '1 hour', 'YYYY-MM-DD HH24:MI') AS v")
blocked(delia, "LST-50001", soon, "TOO_SOON", "start within 2 hours -> TOO_SOON")
blocked(delia, "LST-50001", f"{day(40)} 10:00", "TOO_FAR_AHEAD", "40 days out -> TOO_FAR_AHEAD")
blocked(delia, "LST-50001", f"{day(3)} 20:00", "OUTSIDE_SHOWING_HOURS", "20:00 -> OUTSIDE_SHOWING_HOURS")
blocked(delia, "LST-50001", f"{day(3)} 14:30", "OUTSIDE_SHOWING_HOURS", "14:30 (not on the hour) -> OUTSIDE_SHOWING_HOURS")
r = blocked(delia, "LST-50001", f"{day(2)} 11:00", "SLOT_TAKEN", "Miles holds LST-50001 day+2 11:00 -> SLOT_TAKEN")
check("SLOT_TAKEN offers nearby open times", f"{day(2)} 12:00" in r["reason_text"], r)
blocked(miles, "LST-50002", f"{day(2)} 11:00", "LEAD_DOUBLE_BOOKED", "Miles already has a showing at day+2 11:00 -> LEAD_DOUBLE_BOOKED")
check("blocked proposals created no appointment", n("SELECT count(*) FROM appointments WHERE source='CHAT'") == 0)

# ---------------------------------------------------------------- two-step booking + Nurturing -> Active
r = ps(delia, "LST-50001", "%s 2pm" % day(3))
check("Delia proposes LST-50001 day+3 2pm -> PROPOSED with summary (time parsed to 14:00)", r["outcome"] == "PROPOSED"
      and r["proposal_id"].startswith("BPR-PRP-") and r["slot"] == S3 and "1418 Quillfeather Ln" in r["summary"]
      and "Marisol Vance" in r["summary"] and "$689,000" in r["summary"], r)
P1 = r["proposal_id"]
check("nothing booked before confirm; stage still Nurturing", n("SELECT count(*) FROM appointments WHERE lead_id='LEAD-2026-00101' AND source='CHAT'") == 0
      and val("SELECT stage AS v FROM leads WHERE lead_id='LEAD-2026-00101'") == "Nurturing")
r2 = ps(delia, "LST-50001", S3)
check("re-proposing the same request reuses the open proposal (no duplicate row)", r2["proposal_id"] == P1
      and n("SELECT count(*) FROM pending_actions WHERE lead_id='LEAD-2026-00101' AND outcome='PROPOSED'") == 1, r2)
r = cs(kiran, P1)
check("SCOPE: Kiran confirms Delia's proposal -> NOT_FOUND, nothing booked", r["outcome"] == "NOT_FOUND"
      and n("SELECT count(*) FROM showing_events") == 0, r)
r = cs(delia, P1)
check("confirm -> EXECUTED APT-70101 at day+3 14:00 with agent; journey_stage Active", r["outcome"] == "EXECUTED"
      and r["appointment_id"] == "APT-70101" and r["scheduled_for"] == S3 and r["agent_name"] == "Marisol Vance"
      and r["journey_stage"] == "Active", r)
check("DB: appointment Confirmed (CHAT) for LST-50001 at day+3 14:00",
      n(f"SELECT count(*) FROM appointments WHERE appointment_id='APT-70101' AND lead_id='LEAD-2026-00101' AND listing_id='LST-50001' "
        f"AND status='Confirmed' AND source='CHAT' AND to_char(scheduled_for,'YYYY-MM-DD HH24:MI')='{S3}'") == 1)
check("DB: SQL moved Delia Nurturing -> Active (SYSTEM stage event + STAGE_CHANGED audit)",
      val("SELECT stage AS v FROM leads WHERE lead_id='LEAD-2026-00101'") == "Active"
      and n("SELECT count(*) FROM lead_stage_events WHERE lead_id='LEAD-2026-00101' AND old_stage='Nurturing' AND new_stage='Active' "
            "AND source='SYSTEM' AND reference='APT-70101'") == 1
      and n("SELECT count(*) FROM agent_audit WHERE event_type='STAGE_CHANGED' AND subject_id='LEAD-2026-00101'") == 1)
check("DB: SHOWING_BOOKED audit + lead activity", n("SELECT count(*) FROM agent_audit WHERE event_type='SHOWING_BOOKED' AND subject_id='APT-70101'") == 1
      and n("SELECT count(*) FROM lead_activity WHERE lead_id='LEAD-2026-00101' AND activity_type='Showing Booked'") == 1)
r = cs(delia, P1)
check("confirm twice -> ALREADY_DONE, still one appointment", r["outcome"] == "ALREADY_DONE"
      and n("SELECT count(*) FROM appointments WHERE source='CHAT'") == 1, r)
check("availability now excludes Delia's booked slot", f"{S3}" not in [x["slot"] for x in
      call("get_showing_availability", session_token=kiran, listing_id="LST-50001", date=day(3))])
r = ps(delia, "LST-50002", f"{day(4)} 10:00")
P2 = r["proposal_id"]
check("second booking (already Active) -> EXECUTED, no second stage event", cs(delia, P2)["outcome"] == "EXECUTED"
      and n("SELECT count(*) FROM lead_stage_events WHERE lead_id='LEAD-2026-00101'") == 1)
r = ps(delia, "LST-50003", f"{day(5)} 10:00")
cs(delia, r["proposal_id"])
check("Delia now holds 3 upcoming showings", n("SELECT count(*) FROM appointments WHERE lead_id='LEAD-2026-00101' AND scheduled_for > now()") == 3)
blocked(delia, "LST-50005", f"{day(6)} 10:00", "SHOWING_LIMIT", "4th upcoming showing -> SHOWING_LIMIT")
# confirm re-check: Kiran proposes, Miles books the same slot first, Kiran's confirm is BLOCKED
rk = ps(kiran, "LST-50015", f"{day(3)} 15:00")
rm = ps(miles, "LST-50015", f"{day(3)} 15:00")
check("two leads may hold proposals for the same slot", rk["outcome"] == "PROPOSED" and rm["outcome"] == "PROPOSED")
cs(miles, rm["proposal_id"])
r = cs(kiran, rk["proposal_id"])
check("RE-CHECK: slot booked by someone else before confirm -> BLOCKED SLOT_TAKEN, no appointment for Kiran",
      r["outcome"] == "BLOCKED" and r["reason_code"] == "SLOT_TAKEN"
      and n("SELECT count(*) FROM appointments WHERE lead_id='LEAD-2026-00103'") == 0, r)
check("Kiran (New) stays New after a blocked confirm", val("SELECT stage AS v FROM leads WHERE lead_id='LEAD-2026-00103'") == "New")
rk = ps(kiran, "LST-50016", f"{day(3)} 16:00")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE proposal_id = {lit(rk['proposal_id'])}")
r = cs(kiran, rk["proposal_id"])
check("confirm after 15 minutes -> EXPIRED, nothing booked", r["outcome"] == "EXPIRED"
      and n("SELECT count(*) FROM appointments WHERE lead_id='LEAD-2026-00103'") == 0, r)
bid = val("SELECT proposal_id AS v FROM pending_actions WHERE lead_id='LEAD-2026-00103' AND outcome='BLOCKED' LIMIT 1")
r = cs(kiran, bid)
check("confirming a BLOCKED proposal -> BLOCKED with its reason", r["outcome"] == "BLOCKED" and r["reason_code"] == "LISTING_NOT_ACTIVE", r)
check("confirm an unknown proposal -> NOT_FOUND", cs(kiran, "BPR-PRP-00000000")["outcome"] == "NOT_FOUND")
check("bad token cannot propose or confirm", ps(BAD, "LST-50001", S3)["outcome"] == "SESSION_INVALID"
      and cs(BAD, P1)["outcome"] == "SESSION_INVALID")
check("reviewer-free: Delia's showings list now shows 3 upcoming + 1 past", len(call("get_my_showings", session_token=delia)) == 4)

# ---------------------------------------------------------------- agent follow-up (priority from the intent agent, in SQL)
def fu(tok, msg, intent="", timeline="", pre="", motivation="", brief=""):
    return one("request_agent_follow_up", session_token=tok, message=msg, intent=intent, timeline=timeline, pre_approved=pre,
               motivation=motivation, agent_brief=brief)
r = fu(kiran, "Relocating for a new job in about two months, already pre-approved for $600k - please have an agent call me.",
       "BUY", "0_3_MONTHS", "YES", "job relocation", "intent: BUY | timeline: 0_3_MONTHS | pre_approved: YES")
check("Kiran follow-up -> FOLLOW_UP_REQUESTED FUP-90101 with his agent and a contact-by time", r["outcome"] == "FOLLOW_UP_REQUESTED"
      and r["follow_up_id"] == "FUP-90101" and r["agent_name"] == "Gabriela Fenwick" and r["contact_by"], r)
check("DB: SQL priority HOT (buy, 0-3 months, pre-approved), due = follow_up_due('HOT'), brief stored",
      n("SELECT count(*) FROM follow_up_tasks WHERE task_id='FUP-90101' AND priority='HOT' AND intent='BUY' AND timeline='0_3_MONTHS' "
        "AND pre_approved='YES' AND due_at = follow_up_due('HOT') AND agent_brief LIKE 'intent: BUY%'") == 1)
check("follow-up readback never shows the priority", "priority" not in r and "HOT" not in str(r), r)
r = fu(kiran, "Call me please", "BUY", "0_3_MONTHS", "YES")
check("second follow-up while one is open -> EXISTING, nothing added", r["outcome"] == "EXISTING" and r["follow_up_id"] == "FUP-90101"
      and n("SELECT count(*) FROM follow_up_tasks WHERE lead_id='LEAD-2026-00103'") == 1, r)
check("empty message -> MESSAGE_REQUIRED", fu(miles, "  ")["outcome"] == "MESSAGE_REQUIRED")
r = fu(miles, "We might buy in spring, would like to talk through the process.", "buyer", "3-6 months", "unknown")
check("Miles: 'buyer' / '3-6 months' normalised; pre-approval on file counts -> WARM, next business day 17:00",
      r["outcome"] == "FOLLOW_UP_REQUESTED" and n("SELECT count(*) FROM follow_up_tasks WHERE lead_id='LEAD-2026-00106' AND priority='WARM' "
        "AND intent='BUY' AND timeline='3_6_MONTHS' AND pre_approved='YES' AND due_at = add_business_days(current_date, 1) + time '17:00'") == 1, r)
r = fu(lena, "Just curious what homes like mine go for, no plans yet.", "browsing", "12+", "no")
check("Lena: browsing / 12+ -> NURTURE (3 business days)", r["outcome"] == "FOLLOW_UP_REQUESTED"
      and n("SELECT count(*) FROM follow_up_tasks WHERE lead_id='LEAD-2026-00105' AND priority='NURTURE' AND timeline='12_PLUS'") == 1, r)
check("SQL priority rule table", val("SELECT follow_up_priority('SELL','0_3_MONTHS','NO') AS v") == "HOT"
      and val("SELECT follow_up_priority('BUY','0_3_MONTHS','NO') AS v") == "WARM"
      and val("SELECT follow_up_priority('RENT','0_3_MONTHS','YES') AS v") == "NURTURE")
check("profile shows Kiran's open follow-up", "your agent will reach out" in (one("get_my_profile", session_token=kiran)["open_follow_up"] or ""))
check("bad token cannot request a follow-up", fu(BAD, "hello there")["outcome"] == "SESSION_INVALID")

# ---------------------------------------------------------------- human-owned cases
r = oc(russell, "list_price_change", "Wants to drop the price of 2210 Thistledown Rd to $598,000.", "LST-50014", "$598,000")
check("Russell list-price change -> OPENED BPR-CASE-000101, Sales Agents, reply time", r["outcome"] == "OPENED"
      and r["case_id"] == "BPR-CASE-000101" and r["team"] == "Sales Agents" and r["reply_due"]
      and "$612,000 to $598,000" in r["requested"], r)
RCASE = r["case_id"]
check("DB: case parks LIST_PRICE:LST-50014 with current $612,000 and requested $598,000",
      n("SELECT count(*) FROM service_cases WHERE case_id='BPR-CASE-000101' AND parked_action='LIST_PRICE:LST-50014' "
        "AND current_amount=612000 AND requested_amount=598000 AND status='OPEN'") == 1)
check("listing price unchanged until a person decides", f2(val("SELECT price AS v FROM listings WHERE listing_id='LST-50014'")) == 612000)
r = oc(russell, "list_price_change", "again", "LST-50014", "595000")
check("second open price change on the same listing -> EXISTING", r["outcome"] == "EXISTING" and r["case_id"] == RCASE, r)
r = oc(delia, "list_price_change", "Lower it", "LST-50014", "598000")
check("SCOPE: Delia cannot change Russell's listing price -> BLOCKED NOT_FOUND", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_FOUND", r)
r = oc(lena, "list_price_change", "Big cut", "LST-50020", "600000")
check("price change beyond +/-15% -> AMOUNT_INVALID with the allowed range", r["reason_code"] == "AMOUNT_INVALID"
      and "within" in r["reason_text"], r)
check("price change to the same price -> AMOUNT_INVALID", oc(lena, "list_price_change", "x", "LST-50020", "865000")["reason_code"] == "AMOUNT_INVALID")
psql("UPDATE listings SET status='Pending' WHERE listing_id='LST-50020'")
check("price change on a non-Active own listing -> NOT_ELIGIBLE", oc(lena, "list_price_change", "x", "LST-50020", "850000")["reason_code"] == "NOT_ELIGIBLE")
psql("UPDATE listings SET status='Active' WHERE listing_id='LST-50020'")
r = oc(delia, "offer_request", "Would the sellers take $670,000 for 1418 Quillfeather Ln?", "LST-50001", "670k")
check("offer question -> OPENED for Sales Agents, offer idea + list price recorded", r["outcome"] == "OPENED" and r["team"] == "Sales Agents"
      and "$670,000" in r["requested"] and "$689,000" in r["requested"], r)
OCASE = r["case_id"]
check("offer question twice on the same listing -> EXISTING", oc(delia, "offer_request", "again", "LST-50001")["outcome"] == "EXISTING")
check("offer on an unknown listing -> NOT_FOUND", oc(delia, "offer_request", "x", "LST-59999")["reason_code"] == "NOT_FOUND")
check("offer with a negative amount -> AMOUNT_INVALID", oc(delia, "offer_request", "x", "LST-50002", "-5")["reason_code"] == "AMOUNT_INVALID")
r = oc(marco, "stage_change", "Our offer was accepted on the Marigold house - please mark me under contract.", "Under Contract")
check("Marco already Under Contract -> stage_change NOT_ELIGIBLE", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_ELIGIBLE", r)
r = oc(marco, "stage_change", "We closed yesterday!", "closed")
check("Marco -> Closed: OPENED (parks STAGE)", r["outcome"] == "OPENED" and r["team"] == "Sales Agents", r)
SCASE = r["case_id"]
check("stage_change with an unknown stage -> NOT_ELIGIBLE", oc(delia, "stage_change", "x", "Happy")["reason_code"] == "NOT_ELIGIBLE")
r = oc(delia, "stage_change", "We had an offer accepted on another home.", "under contract")
UCASE = r["case_id"]
check("Delia -> Under Contract: OPENED", r["outcome"] == "OPENED", r)
FHB = ("flagged: YES | category: SCHOOLS | neutral_answer: Brightpath agents don't rate schools; the Larkspur Valley school "
       "district publishes boundaries and reports. | brief: Lead asked whether schools near a listing are good.")
r = oc(delia, "fair_housing_review", "Asked whether the schools near 1418 Quillfeather Ln are good and if it is a safe area for kids.",
       "schools", "", FHB)
check("fair-housing question -> OPENED for Brokerage Compliance", r["outcome"] == "OPENED" and r["team"] == "Brokerage Compliance", r)
FCASE = r["case_id"]
check("DB: category normalised SCHOOLS, NORMAL priority, agent brief stored for the reviewer",
      n(f"SELECT count(*) FROM service_cases WHERE case_id='{FCASE}' AND category='SCHOOLS' AND priority='NORMAL' AND agent_brief LIKE 'flagged: YES%'") == 1)
r = oc(kiran, "fair_housing_review", "Asked which neighborhoods have people like him.", "Demographics")
check("demographics question -> HIGH priority (SQL thresholds the agent's category)",
      n(f"SELECT count(*) FROM service_cases WHERE case_id='{r['case_id']}' AND priority='HIGH' AND category='DEMOGRAPHICS'") == 1, r)
r = oc(kiran, "advice_referral", "Asks whether he should lock his mortgage rate now.", "mortgage rate")
check("mortgage question -> advice_referral OPENED for Brokerage Compliance", r["outcome"] == "OPENED" and r["team"] == "Brokerage Compliance", r)
r = oc(kiran, "discount", "Wants a commission discount")
check("unknown request type -> INVALID_TYPE with the list of what a person can help with", r["outcome"] == "INVALID_TYPE"
      and "offers" in r["reason_text"], r)
check("bad token cannot open a case", oc(BAD, "offer_request", "x")["outcome"] == "SESSION_INVALID")
check("case open logged CASE_OPENED audit rows", n("SELECT count(*) FROM agent_audit WHERE event_type='CASE_OPENED'") == 7)

# ---------------------------------------------------------------- reviewer identity + role separation
r = one("verify_reviewer", staff_id="BPR-7101", code="9999")
check("reviewer wrong code -> VERIFY_FAILED, no session", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and n("SELECT count(*) FROM sessions WHERE role='REVIEWER'") == 0, r)
r = one("verify_reviewer", staff_id="bpr7101", code="2468")
check("Marisol verifies (staff id normalised) -> REVIEWER, Sales Agents", r["outcome"] == "VERIFIED" and r["role"] == "REVIEWER"
      and r["team"] == "Sales Agents" and r["display_name"] == "Marisol Vance", r)
marisol = r["session_token"]
theo, imani = rlogin("BPR-7102", "1357"), rlogin("7201", "8642")
check("Theodore and Imani verify", "missing" not in (theo, imani))
check("a lead's code does not verify as reviewer", one("verify_reviewer", staff_id="BPR-7101", code="5172")["outcome"] == "VERIFY_FAILED")
check("ROLE: lead token on the reviewer queue -> NOT_REVIEWER", one("get_review_queue", session_token=delia)["status"] == "NOT_REVIEWER")
check("ROLE: reviewer token on a lead tool -> SESSION_INVALID", one("get_my_profile", session_token=marisol)["status"] == "SESSION_INVALID"
      and ps(marisol, "LST-50001", S3)["outcome"] == "SESSION_INVALID")
q = call("get_review_queue", session_token=marisol)
qids = [x["case_id"] for x in q]
check("Marisol's queue = Sales Agents OPEN cases only (seeded 1 + 3, Russell's, offer, both stage updates)",
      set(qids) == {"BPR-CASE-000001", "BPR-CASE-000003", RCASE, OCASE, SCASE, UCASE}, qids)
check("queue never shows Compliance cases", "BPR-CASE-000002" not in qids and FCASE not in qids)
check("queue customer is first name + last initial only", any(x["customer"].startswith("Russell T.") for x in q)
      and not any("Thorne" in x["customer"] for x in q), [x["customer"] for x in q])
qi = call("get_review_queue", session_token=imani)
check("Imani's queue: Compliance cases, HIGH priority first", qi[0]["priority"] == "HIGH"
      and {"BPR-CASE-000002", FCASE} <= {x["case_id"] for x in qi}, qi)
check("Imani's queue has 4 cases (2 fair-housing seeded+new, demographics, referral)", len(qi) == 4, [x["case_id"] for x in qi])
rc = one("get_review_case", session_token=marisol, case_id=RCASE)
check("review case: statement, allowed range, Marisol's $15,000 limit, facts with days on market + area median",
      rc["status"] == "OK" and "598,000" in rc["customer_statement"] and "$520,200 - $703,800" in rc["allowed_range"]
      and f2(rc["your_approval_limit"]) == 15000 and "days on market" in rc["facts"] and "area median" in rc["facts"], rc)
check("review case: cross-team case -> NOT_FOUND", one("get_review_case", session_token=marisol, case_id="BPR-CASE-000002")["status"] == "NOT_FOUND")
rc = one("get_review_case", session_token=imani, case_id=FCASE)
check("Imani sees the fair-housing brief and the compliance guidance", "flagged: YES" in rc["agent_brief"]
      and "public sources" in rc["facts"], rc)
check("lead token cannot open a review case", one("get_review_case", session_token=delia, case_id=RCASE)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- decisions: every reason code
NOTE = "Comparable sales support the lower price."
MSG = "Your list price change to $598,000 is approved and live on the listing."
r = dc(delia, RCASE, "APPROVE", "", NOTE, MSG)
check("a LEAD token cannot decide -> NOT_REVIEWER, no decision row", r["outcome"] == "NOT_REVIEWER"
      and n("SELECT count(*) FROM review_decisions") == 0, r)
r = dc(marisol, "BPR-CASE-000002", "APPROVE", "", NOTE, MSG)
check("Marisol on a Compliance case -> NOT_YOUR_TEAM", r["reason_code"] == "NOT_YOUR_TEAM" and not r["case_id"], r)
check("unknown case -> NOT_FOUND", dc(marisol, "BPR-CASE-999999", "APPROVE", "", NOTE, MSG)["reason_code"] == "NOT_FOUND")
check("note 'ok' -> NOTE_REQUIRED", dc(marisol, RCASE, "APPROVE", "", "ok", MSG)["reason_code"] == "NOTE_REQUIRED")
check("decision 'maybe' -> INVALID_DECISION", dc(marisol, RCASE, "maybe", "", NOTE, MSG)["reason_code"] == "INVALID_DECISION")
check("amended price out of range -> AMOUNT_INVALID", dc(marisol, RCASE, "APPROVE", "450000", NOTE, MSG)["reason_code"] == "AMOUNT_INVALID")
r = dc(marisol, "BPR-CASE-000001", "APPROVE", "", "Market has softened in Northgate.", "Approved.")
check("Marisol approves Lena's $40,000 cut -> OVER_AUTHORITY, case stays OPEN, price unchanged", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"]
      and f2(val("SELECT price AS v FROM listings WHERE listing_id='LST-50020'")) == 865000, r)
r = dc(theo, "BPR-CASE-000001", "APPROVE", "$835,000", "Meet in the middle; 8% cut is too steep this early.",
       "We approved a new list price of $835,000.")
check("Theodore (managing broker) approves an AMENDED $835,000 -> APPROVED, price changed", r["outcome"] == "APPROVED"
      and "$865,000 to $835,000" in r["executed_action"] and f2(val("SELECT price AS v FROM listings WHERE listing_id='LST-50020'")) == 835000, r)
check("DB: LPC row by the decision + PRICE_CHANGED and CASE_DECIDED audit",
      n("SELECT count(*) FROM listing_price_changes WHERE case_id='BPR-CASE-000001' AND old_price=865000 AND new_price=835000 AND source='REVIEWER'") == 1
      and n("SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='BPR-CASE-000001' AND actor='BPR-7102'") == 1
      and n("SELECT count(*) FROM agent_audit WHERE event_type='PRICE_CHANGED' AND detail LIKE 'LST-50020%'") == 1)
check("decide again -> ALREADY_DECIDED", dc(theo, "BPR-CASE-000001", "REJECT", "", NOTE, "x")["reason_code"] == "ALREADY_DECIDED")
r = dc(marisol, RCASE, "APPROVE", "", NOTE, MSG)
check("Marisol approves Russell's $14,000 cut (within her limit) -> APPROVED, price $598,000", r["outcome"] == "APPROVED"
      and r["approved"] == "new list price $598,000" and f2(val("SELECT price AS v FROM listings WHERE listing_id='LST-50014'")) == 598000, r)
check("DB: decision row with note + message, case APPROVED with the customer message",
      n(f"SELECT count(*) FROM review_decisions WHERE case_id='{RCASE}' AND reviewer_id='BPR-7101' AND decision='APPROVE' AND approved_amount=598000") == 1
      and val(f"SELECT customer_message AS v FROM service_cases WHERE case_id='{RCASE}'") == MSG)
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=russell)}
check("Russell sees APPROVED + the team's message, never the internal note or reviewer", mc[RCASE]["case_status"] == "APPROVED"
      and mc[RCASE]["customer_message"] == MSG and "$598,000" in mc[RCASE]["outcome"]
      and NOTE not in str(mc) and "Marisol" not in str(mc), mc)
r = dc(marisol, OCASE, "REJECT", "", "Offer far below recent comparables.", "Your agent will call you to talk through pricing.")
check("reject the offer question -> REJECTED, nothing executed", r["outcome"] == "REJECTED"
      and r["executed_action"] == "Case rejected; nothing was executed.", r)
r = dc(theo, SCASE, "APPROVE", "", "Closing statement received.", "Congratulations - your purchase is marked closed.")
check("approve Marco's closing -> stage Closed via a REVIEWER stage event", r["outcome"] == "APPROVED"
      and "Under Contract to Closed" in r["executed_action"] and val("SELECT stage AS v FROM leads WHERE lead_id='LEAD-2026-00102'") == "Closed"
      and n(f"SELECT count(*) FROM lead_stage_events WHERE lead_id='LEAD-2026-00102' AND source='REVIEWER' AND reference='{SCASE}'") == 1, r)
psql("UPDATE leads SET stage='Lost' WHERE lead_id='LEAD-2026-00101'")
r = dc(theo, UCASE, "APPROVE", "", "Contract seen in the file.", "Marked under contract.")
check("ACTION_BLOCKED: stage no longer allows Under Contract -> case stays OPEN, no stage event", r["reason_code"] == "ACTION_BLOCKED"
      and r["case_status"] == "OPEN" and n(f"SELECT count(*) FROM lead_stage_events WHERE reference='{UCASE}'") == 0, r)
psql("UPDATE leads SET stage='Active' WHERE lead_id='LEAD-2026-00101'")
r = oc(russell, "list_price_change", "One more small cut", "LST-50014", "590000")
LCASE2 = r["case_id"]
psql("UPDATE listings SET status='Pending' WHERE listing_id='LST-50014'")
r = dc(theo, LCASE2, "APPROVE", "", "Small cut approved.", "Approved.")
check("ACTION_BLOCKED: listing went Pending before approval -> case OPEN, price unchanged", r["reason_code"] == "ACTION_BLOCKED"
      and f2(val("SELECT price AS v FROM listings WHERE listing_id='LST-50014'")) == 598000, r)
psql("UPDATE listings SET status='Active' WHERE listing_id='LST-50014'")
r = dc(imani, FCASE, "APPROVE", "", "Neutral reply with public sources; no characterisation.",
       "Brightpath agents don't rate schools or neighborhoods. The Larkspur Valley school district and the city publish school "
       "boundaries, reports and public safety data on their websites.")
check("Imani approves the fair-housing reply -> APPROVED, decision recorded (no automatic action)", r["outcome"] == "APPROVED"
      and "no automatic action" in r["executed_action"], r)
check("Delia sees the compliance reply as the outcome", "school district" in
      {x["case_id"]: x for x in call("get_my_cases", session_token=delia)}[FCASE]["customer_message"])

# ---------------------------------------------------------------- guarded email
e = one("email_confirmation", session_token=delia, reference="apt-70101")
check("email own showing -> SEND_OK with the SQL-built body", e["send_status"] == "SEND_OK" and "APT-70101" in e["subject"]
      and "1418 Quillfeather Ln" in e["body"] and "Harper, the Brightpath Realty AI assistant" in e["body"], e)
e = one("email_confirmation", session_token=russell, reference=RCASE)
check("email own decided case -> SEND_OK with the customer message, never the internal note",
      e["send_status"] == "SEND_OK" and MSG in e["body"] and NOTE not in e["body"], e)
check("email own follow-up -> SEND_OK", one("email_confirmation", session_token=kiran, reference="FUP-90101")["send_status"] == "SEND_OK")
e = one("email_confirmation", session_token=delia, reference="APT-70001")
check("SCOPE: Delia emails Miles's showing -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
check("email an undecided case -> NOT_FOUND", one("email_confirmation", session_token=delia, reference=UCASE)["reason_code"] == "NOT_FOUND")
check("email with a bad token -> SESSION_INVALID", one("email_confirmation", session_token=BAD, reference="APT-70101")["reason_code"] == "SESSION_INVALID")
check("exactly 3 emails logged (the authorised ones)", n("SELECT count(*) FROM email_log") == 3)

# ---------------------------------------------------------------- reviewer throttle + session expiry
for _ in range(5):
    one("verify_reviewer", staff_id="BPR-7201", code="0000")
check("reviewer THROTTLE -> LOCKED even with the right code", one("verify_reviewer", staff_id="BPR-7201", code="8642")["outcome"] == "LOCKED")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(delia)}")
check("expired lead token -> SESSION_INVALID", one("get_my_profile", session_token=delia)["status"] == "SESSION_INVALID")
check("expired token cannot propose", ps(delia, "LST-50006", f"{day(7)} 10:00")["outcome"] == "SESSION_INVALID")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(marisol)}")
check("expired reviewer token -> NOT_REVIEWER", one("get_review_queue", session_token=marisol)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- hidden data never leaves the DB
lead_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
leaked = sorted({k for _, rows in lead_out for row in rows for k in row} & HIDDEN_COLUMNS)
check("no lead tool output has a hidden column", not leaked, leaked)
lblob = "\n".join(str(v) for _, rows in lead_out for row in rows for v in row.values())
secrets = [x["v"] for x in psql("SELECT otp_code v FROM leads UNION ALL SELECT internal_note FROM review_decisions "
                                "UNION ALL SELECT display_name FROM reviewers WHERE reviewer_id <> 'BPR-7101' "
                                "UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL "
                                "UNION ALL SELECT agent_brief FROM follow_up_tasks WHERE agent_brief IS NOT NULL")]
check("lead outputs never contain codes, internal notes, reviewer names or agent briefs",
      not any(s and len(s) > 4 and s in lblob for s in secrets), [s for s in secrets if s and len(s) > 4 and s in lblob][:3])
check("lead outputs never contain any lead's e-mail address", not re.search(r"@example\.com", lblob))
rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
rblob = "\n".join(str(v) for _, rows in rev_out for row in rows for v in row.values())
check("reviewer outputs: no lead e-mail, phone, code or full last name", not rleak
      and not re.search(r"@example\.com|Sorensen|Sandoval|Bhatt|Thorne|Marchetti|Hargrove|\(555\) 010-11", rblob), (rleak, rblob[:200]))
texts = [str(row.get(k) or "") for _, rows in lead_out for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the lead|the model|LLM|the assistant|the user)\b", t, re.I)]
check("lead-facing texts address the person (never the model)", not bad, bad[:3])
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT lead_id AS v FROM leads UNION SELECT first_name || ' ' || last_name FROM leads UNION SELECT last_name FROM leads "
    "UNION SELECT email FROM leads UNION SELECT phone FROM leads UNION SELECT otp_code FROM leads "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT agent_id FROM agents UNION SELECT full_name FROM agents UNION SELECT email FROM agents UNION SELECT phone FROM agents "
    "UNION SELECT case_id FROM service_cases UNION SELECT summary FROM service_cases UNION SELECT appointment_id FROM appointments "
    "UNION SELECT listing_id FROM listings UNION SELECT address FROM listings "
    "UNION SELECT session_token::text FROM sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 30, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_listing_match_guide": ("fenced", "fenced yard / yard / patio", "note line", 2),
    "get_intent_glossary": ("relocation", "0_3_MONTHS", "first call", 6),
    "get_fair_housing_guide": ("crime map", "SAFETY_CRIME", "neutral answer", 7),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["listing_match_agent", "lead_intent_agent", "fair_housing_agent"])
for t in AGENT_REF_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)}, about 20-30)", 15 <= len(full) <= 30, len(full))
    check(f"{tool}: returns only the reference columns {REF_COLUMNS}", bool(full) and list(full[0]) == REF_COLUMNS,
          list(full[0]) if full else None)
    check(f"{tool}: every section is present", {r["section"] for r in full} == set(t["sections"]),
          sorted({r["section"] for r in full} ^ set(t["sections"])))
    check(f"{tool}: rows come back in section order", [r["section"] for r in full] == sorted(
          [r["section"] for r in full], key=t["sections"].index))
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
    pct = ref_call(t, "%")      # '%' is matched literally (only rows that contain '%'), never as a wildcard
    check(f"{tool}: '%' and '_' are literal (no wildcard expansion)",
          len(pct) < len(full) and all("%" in f"{r['term']} {r['meaning']}" for r in pct) and ref_call(t, "_%_") == [],
          [r["term"] for r in pct])
    check(f"{tool}: SQL-looking input is just a string -> 0 rows",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no lead / agent / reviewer / case / showing / listing / session value in the reference rows",
          not leaked, leaked[:5])
    check(f"{tool}: no lead id, staff id, case / showing / follow-up id, listing id, email, phone or token pattern",
          not re.search(r"lead-\d|\bagt-\d|\bbpr-\d|\bcase-\d|\bapt-\d|\bfup-\d|\blst-\d|@|\(555\)|[0-9a-f]{8}-[0-9a-f]{4}-",
                        blob), blob[:200])
    check(f"{tool}: no school rating, crime figure or demographic statistic (Fair Housing)",
          not re.search(r"\b(rated \d|\d+/10|crime rate|percent|median income|white|black|hispanic|asian|christian|"
                        r"muslim|jewish)\b", blob), re.findall(r"\b(rated \d|crime rate|median income)\b", blob))

lm = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_listing_match")
g = ref_call(lm, "")
both = ref_call(lm, "OVER_BUDGET, office with a door")
check("ref_listing_match: several words in one call ('OVER_BUDGET, office with a door') -> both found",
      {"OVER_BUDGET", "office with a door"} <= {r["term"] for r in both}, [r["term"] for r in both])
check("ref_listing_match: the standard and no-match note lines are in the table (and no longer in any prompt)",
      {r["term"] for r in g if r["section"] == "NOTE_LINE"} == {"STANDARD", "NO_MATCH"}
      and all(r["meaning"].endswith(".") and r["meaning"][0].isupper() for r in g if r["section"] == "NOTE_LINE"))
check("ref_listing_match: every exclusion code is a single UPPER_CASE word with a meaning",
      all(re.fullmatch(r"[A-Z_]+", r["term"]) and len(r["meaning"]) > 10 for r in g if r["section"] == "EXCLUDE")
      and "PENDING" in {r["term"] for r in g if r["section"] == "EXCLUDE"})
st = {r["v"] for r in psql("SELECT DISTINCT status AS v FROM listings")}
check("ref_listing_match: the listing_status row explains every status the listings table holds",
      all(s_ in next(r["meaning"] for r in g if r["term"] == "listing_status") for s_ in st), st)
check("ref_listing_match: no listing facts are copied in (the orchestrator passes the candidates)",
      not any(v.lower() in ref_blob(g) for v in [r["v"] for r in psql("SELECT address AS v FROM listings")]))
check("ref_listing_match: walk-score bands cover 0-100 with no gap (70+, 50-69, below 50)",
      [r["term"] for r in g if r["section"] == "WALK_SCORE"] == ["70 and above", "50 to 69", "below 50"])

li = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_lead_intent")
g = ref_call(li, "")
canon_i = sorted({r["v"] for r in psql("SELECT DISTINCT norm_intent(x) AS v FROM unnest(ARRAY['BUY','SELL','BUY_AND_SELL',"
                                       "'RENT','BROWSING','OTHER','gibberish']) x")})
canon_t = sorted({r["v"] for r in psql("SELECT DISTINCT norm_timeline(x) AS v FROM unnest(ARRAY['0_3_MONTHS','3_6_MONTHS',"
                                       "'6_12_MONTHS','12_PLUS','UNKNOWN','gibberish']) x")})
canon_p = sorted({r["v"] for r in psql("SELECT DISTINCT norm_tri(x) AS v FROM unnest(ARRAY['YES','NO','UNKNOWN','x']) x")})
sec_terms = lambda s_: sorted(r["term"] for r in g if r["section"] == s_)
check("ref_lead_intent: every intent norm_intent() can store is explained (INTENT) and has a FIRST_CALL row",
      sec_terms("INTENT") == canon_i == sec_terms("FIRST_CALL") and len(canon_i) == 6, (sec_terms("INTENT"), canon_i))
check("ref_lead_intent: every timeline norm_timeline() can store is explained", sec_terms("TIMELINE") == canon_t == sorted(
      ["0_3_MONTHS", "3_6_MONTHS", "6_12_MONTHS", "12_PLUS", "UNKNOWN"]), (sec_terms("TIMELINE"), canon_t))
check("ref_lead_intent: every pre-approval value norm_tri() can store is explained", sec_terms("PRE_APPROVAL") == canon_p,
      (sec_terms("PRE_APPROVAL"), canon_p))
check("ref_lead_intent: each code maps to itself in SQL (norm_intent / norm_timeline / norm_tri)",
      all(val(f"SELECT norm_intent({lit(x)}) AS v") == x for x in canon_i)
      and all(val(f"SELECT norm_timeline({lit(x)}) AS v") == x for x in canon_t)
      and all(val(f"SELECT norm_tri({lit(x)}) AS v") == x for x in canon_p))
check("ref_lead_intent: the follow-up priority is NOT in the guide (it stays in SQL)",
      not re.search(r"\b(hot|warm|nurture|priority|score)\b", ref_blob(g)), re.findall(r"\b(hot|warm|nurture|priority)\b", ref_blob(g)))
fc = ref_call(li, "first call")
check("ref_lead_intent: FIRST_CALL rows are full sentences (the table-only part of the agent's reply)",
      len(fc) == 6 and all(r["meaning"].endswith(".") and len(r["meaning"]) > 60 for r in fc), [r["term"] for r in fc])
check("ref_lead_intent: 'cash' finds the pre-approval YES row", any(r["section"] == "PRE_APPROVAL" and r["term"] == "YES"
                                                                   for r in ref_call(li, "cash")))

fh = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_fair_housing")
g = ref_call(fh, "")
rt = ref_call(fh, "routing")
check("ref_fair_housing: ROUTING row (who reviews) comes from case_routing (Brokerage Compliance + its SLA text)",
      len(rt) == 1 and rt[0]["section"] == "ROUTING" and "Brokerage Compliance" in rt[0]["meaning"]
      and val("SELECT sla_text AS v FROM case_routing WHERE request_type='fair_housing_review'") in rt[0]["meaning"], rt)
psql("UPDATE case_routing SET sla_text = sla_text || ' (test)' WHERE request_type = 'fair_housing_review'")
check("ref_fair_housing: a case_routing edit shows up in the ROUTING row (no copy)",
      ref_call(fh, "routing")[0]["meaning"].endswith("(test)"))
psql("UPDATE case_routing SET sla_text = replace(sla_text, ' (test)', '') WHERE request_type = 'fair_housing_review'")
check("ref_fair_housing: the seven US Fair Housing Act protected classes are listed",
      sorted(r["term"] for r in g if r["section"] == "PROTECTED")
      == sorted(["race", "color", "religion", "national origin", "sex", "disability", "familial status"]))
cats = [r["term"] for r in g if r["section"] == "CATEGORY"]
canon_c = sorted({r["v"] for r in psql("SELECT DISTINCT norm_fh_category(x) AS v FROM unnest(ARRAY['SCHOOLS','SAFETY_CRIME',"
                                       "'DEMOGRAPHICS','FAMILY_STATUS','RELIGION','DISABILITY','OTHER_PROTECTED']) x")})
check("ref_fair_housing: every category norm_fh_category() can store is explained (+ NONE), each maps to itself",
      sorted(c for c in cats if c != "NONE") == canon_c and "NONE" in cats
      and all(val(f"SELECT norm_fh_category({lit(c)}) AS v") == c for c in canon_c), (cats, canon_c))
na = {r["term"]: r["meaning"] for r in g if r["section"] == "NEUTRAL_ANSWER"}
check("ref_fair_housing: one approved neutral answer per flaggable category (all but NONE)",
      sorted(na) == canon_c, sorted(na))
check("ref_fair_housing: every neutral answer states the equal-information reason and offers listing facts or "
      "listing features, never a claim", all("same information" in m and "listing" in m for m in na.values())
      and not any(re.search(r"\b(is safe|are good|good schools|family-friendly area|low crime)\b", m, re.I) for m in na.values()))
check("ref_fair_housing: schools / safety / demographics answers point to an objective public source",
      "School District" in na["SCHOOLS"] and "Police Department" in na["SAFETY_CRIME"] and "Census Bureau" in na["DEMOGRAPHICS"])
two = ref_call(fh, "familial status, crime map")
check("ref_fair_housing: several words in one call ('familial status, crime map') -> both found",
      {"familial status", "SAFETY_CRIME"} <= {r["term"] for r in two}, [r["term"] for r in two])

# nothing from the old static reference text was lost
KEEP = {"get_listing_match_guide": [
            "active = can be shown and offered on", "pending = the sellers accepted an offer", "never ranked",
            "us dollars", "homeowners-association dues per month", "empty = no hoa", "interior square feet",
            "days since the listing went live", "facts written by the listing agent", "very walkable",
            "somewhat walkable", "car-dependent", "office with a door", "den / loft / flex room", "no office space",
            "a fenced yard beats a yard, a yard beats a patio, and a patio beats no yard", "only active rows",
            "every stated hard limit (budget, minimum bedrooms, area", "how many of the stated wishes",
            "break ties by the lower price within budget", "den, not a dedicated office", "schools, safety, crime",
            "family-friendly", "for kids", "places of worship", "who lives nearby", "public sources",
            "never use it to call a home a good deal", "sell fast"],
        "get_intent_glossary": [
            "wants to purchase a home", "wants to sell a home", "selling one home and buying another",
            "brightpath does not handle rentals", "just looking", "a complaint, a vendor", "asap", "in a few weeks",
            "about two months", "relocation start date within 3 months", "this spring", "later this year",
            "next year or later", "someday", "no timing is stated", "pre-approved them", "pre-qualified them with a letter",
            "paying cash also counts as yes", "have not started financing", "still need a lender", "not mentioned",
            "job relocation", "downsizing", "investment", "first home", "closer to work", "never guess personal details",
            "race, color, religion, national origin, sex, disability, family status"],
        "get_fair_housing_guide": [
            "race", "color", "religion", "national origin", "sex", "disability", "familial status",
            "children under 18", "pregnancy", "school quality or ratings", "good school district", "is it safe",
            "good area or a bad area", "people like me", "diverse", "what kind of people live there", "family-friendly",
            "lots of kids", "young families", "retirees only", "quiet for a couple without kids", "church community",
            "walkability, commute times, lot size, hoa rules", "do not rate schools", "school district",
            "police department", "census bureau", "same information", "walk score, commute and lot size",
            "never answer the question itself", "you will love it there", "never refuse rudely"]}
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
cols = psql("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ("
            + ", ".join(lit(t["table"]) for t in AGENT_REF_TOOLS) + ")")
check("reference tables have only entry_id / section / term / meaning (no person, contact or case column)",
      {c["column_name"] for c in cols} == {"entry_id", "section", "term", "meaning"}, sorted({c["column_name"] for c in cols}))

reset()
check("reset_data.sql reloads the agent reference tables",
      all(n(f"SELECT count(*) FROM {t['table']}") > 0 for t in AGENT_REF_TOOLS))

reset()
total = passes + fails
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} checks, DB reset)")
sys.exit(1 if fails else 0)
