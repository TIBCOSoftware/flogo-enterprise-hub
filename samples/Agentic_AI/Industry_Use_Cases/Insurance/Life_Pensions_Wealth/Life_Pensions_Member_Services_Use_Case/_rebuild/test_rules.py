#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the life_pensions_governed DB and assert the
business rules on DB state - member rules, the two-step changes, claims, cases, the full reviewer loop, and the A2A
agents' read-only reference tools (ref_* functions: filtering, unknown input, no personal data, SELECT-only). No Flogo
needed. Re-loads reset_data.sql first and again at the end (re-runnable).

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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "life_pensions_governed"),
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
    return list(psql(sql)[0].values())[0]


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


reset()

# ---------------------------------------------------------------- contract shape
check("20 MCP tools", len(TOOLS) == 20, [t["tool"] for t in TOOLS])
check("every write is INSERT ... SELECT (never VALUES)",
      all(re.match(r"INSERT INTO \w+ \([^)]*\) SELECT ", t["write"][0]) and "VALUES" not in t["write"][0].upper()
          for t in TOOLS if "write" in t))
check("write placeholders ?w_*, read placeholders never ?w_*",
      all(all(p.startswith("w_") for p, _ in t["write"][1]) for t in TOOLS if "write" in t)
      and all(not p.startswith("w_") for t in TOOLS for p, _ in t["read"][1]))
check("no ?p:: casts anywhere", not any(re.search(r"\?\w+::", t.get("write", ("",))[0] + t["read"][0]) for t in TOOLS))
check("reads are readonly, writes are not", all(t["readonly"] == ("write" not in t) for t in TOOLS))

# ---------------------------------------------------------------- member identity + throttle
r = one("verify_member", member_id="HLR-100101", code="0000")
check("wrong code -> VERIFY_FAILED, no token, no hint", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "match" in r["reason_text"], r)
check("wrong code issues no session", n("SELECT count(*) FROM sessions") == 0)
r = one("verify_member", member_id="HLR-999999", code="4821")
check("unknown member -> VERIFY_FAILED (same text)", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_member", member_id="HLR-100102", code="4821")
check("James's code with Maria's id -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
toks = []
for fmt in ("HLR-100101", "hlr100101", "HLR 100101", "100101"):
    r = one("verify_member", member_id=fmt, code="4821")
    check(f"member id format '{fmt}' -> VERIFIED + token", r["outcome"] == "VERIFIED" and r["session_token"]
          and r["first_name"] == "James", r)
    toks.append(r["session_token"])
james = toks[-1]
tok = lambda mid, code: one("verify_member", member_id=mid, code=code)["session_token"]
maria, david, susan = tok("HLR-100102", "2468"), tok("HLR-100103", "1357"), tok("HLR-100104", "5530")
robert, linda, michael = tok("HLR-100105", "8642"), tok("HLR-100106", "7316"), tok("HLR-100107", "9753")
jennifer, patricia = tok("HLR-100108", "3690"), tok("HLR-100110", "1122")
check("all 9 member logins verify", all([james, maria, david, susan, robert, linda, michael, jennifer, patricia]))
for i in range(5):
    one("verify_member", member_id="HLR-100110", code="9999")
r = one("verify_member", member_id="HLR-100110", code="1122")
check("THROTTLE: 5 wrong codes -> LOCKED even with the right code, no new session",
      r["outcome"] == "LOCKED" and not r["session_token"]
      and n("SELECT count(*) FROM sessions WHERE member_id='HLR-100110'") == 1, r)

# ---------------------------------------------------------------- reviewer identity + role separation
r = one("verify_reviewer", staff_id="HLS-2041", code="0000")
check("reviewer wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_reviewer", staff_id="HLR-100101", code="4821")
check("member credentials on verify_reviewer -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
r = one("verify_reviewer", staff_id="hls 2041", code="3141")
check("Grace verifies as REVIEWER, team Claims Examination", r["outcome"] == "VERIFIED" and r["role"] == "REVIEWER"
      and r["team"] == "Claims Examination" and r["display_name"] == "Grace Okafor", r)
grace = r["session_token"]
r = one("verify_reviewer", staff_id="2057", code="2718")
marcus = r["session_token"]
check("Marcus verifies, team Policy & Retirement Services", r["team"] == "Policy & Retirement Services", r)
check("reviewer token on a member tool -> SESSION_INVALID", one("get_my_profile", session_token=grace)["status"] == "SESSION_INVALID")
check("member token on a reviewer tool -> NOT_REVIEWER", one("get_review_queue", session_token=linda)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- scoped reads
p = one("get_my_profile", session_token=james)
check("James profile: Divorced, CA, salary 96000, 3 policies, 2 accounts", p["status"] == "OK" and p["marital_status"] == "Divorced"
      and f2(p["annual_salary"]) == 96000 and p["policies_held"] == "3" and p["retirement_accounts"] == "2", p)
pol = {x["policy_id"]: x for x in call("get_my_policies", session_token=james)}
check("James policies: POL-1001/1002/1003 Active; IP = monthly benefit $4,000, 90-day wait",
      set(pol) == {"POL-1001", "POL-1002", "POL-1003"} and all(x["policy_status"] == "Active" for x in pol.values())
      and pol["POL-1003"]["coverage_basis"] == "monthly benefit" and f2(pol["POL-1003"]["coverage_amount"]) == 4000
      and pol["POL-1003"]["waiting_period_days"] == "90", pol)
check("Susan's policy shows Lapsed with a note", "Lapsed on" in one("get_my_policies", session_token=susan)["status_note"])
ben = call("get_my_beneficiaries", session_token=james)
check("James beneficiaries: ex-spouse Emily (Spouse 100%) on POL-1001 and POL-1002",
      len(ben) == 2 and all(b["beneficiary_name"] == "Emily Carter" and b["relationship"] == "Spouse" for b in ben), ben)
acc = {x["account_id"]: x for x in call("get_my_retirement_accounts", session_token=james)}
a = acc["RET-5001"]
check("James 401(k): $181,685, 3% of pay, match to 6%, gap 3, $2,880/yr unclaimed, max allowed 15%, limit $23,500",
      f2(a["balance"]) == 181685 and a["contribution_rate"] == "3% of pay" and f2(a["match_gap_pct"]) == 3
      and f2(a["unclaimed_match_per_year"]) == 2880 and a["max_rate_allowed"] == "15%"
      and f2(a["annual_deferral_limit"]) == 23500 and "$2,880" in a["match_text"], a)
check("James Roth IRA: no payroll rate", acc["RET-5002"]["contribution_rate"].startswith("n/a"), acc["RET-5002"])
m = one("get_my_retirement_accounts", session_token=maria)
check("Maria (salary $260,000): max allowed 9% (IRS limit)", m["max_rate_allowed"] == "9%", m)
check("Robert (64): deferral limit includes the catch-up ($31,000)",
      f2(one("get_my_retirement_accounts", session_token=robert)["annual_deferral_limit"]) == 31000)
h = {x["fund_id"]: x for x in call("get_my_holdings", session_token=james) if x["account_id"] == "RET-5001"}
check("James holdings: FND-001 Aggressive Growth High risk $63,225 = 34.80%",
      h["FND-001"]["risk_level"] == "High" and f2(h["FND-001"]["value"]) == 63225 and f2(h["FND-001"]["allocation_pct"]) == 34.80, h)
c = call("get_my_contributions", session_token=james)
check("James contributions: 12 most recent, employee payroll $120.00", len(c) == 12
      and any(x["contribution_type"] == "Employee" and f2(x["amount"]) == 120 for x in c), c[:3])
cl = one("get_my_claims", session_token=linda)
check("Linda claim CLM-2026-0004 Denied, waiting period reason", cl["claim_id"] == "CLM-2026-0004" and cl["claim_status"] == "Denied"
      and "waiting period" in cl["decision_text"], cl)
check("James has no claims (one empty OK row)", one("get_my_claims", session_token=james)["claim_id"] == "")
fc = call("get_fund_catalog", session_token=james)
check("fund catalog: 11 funds, FND-011 closed to new money", len(fc) == 11
      and next(x for x in fc if x["fund_id"] == "FND-011")["open_to_new_money"] == "no")
check("Jennifer sees her open beneficiary case", one("get_my_cases", session_token=jennifer)["case_status"] == "OPEN")

# ---------------------------------------------------------------- contribution change rules
def prc(tk, rate):
    return one("propose_contribution_change", session_token=tk, new_rate_pct=rate)


def blocked(label, row, code):
    check(f"{label} -> BLOCKED {code}, no proposal_id", row["outcome"] == "BLOCKED" and row["reason_code"] == code
          and not row["proposal_id"] and row["reason_text"], row)


blocked("rate 'abc'", prc(james, "abc"), "INVALID_RATE")
blocked("rate 6.5 (whole percent only)", prc(james, "6.5"), "INVALID_RATE")
blocked("rate 3 (current)", prc(james, "3%"), "NO_CHANGE")
blocked("rate 20 (> plan max 15)", prc(james, "20"), "ABOVE_PLAN_MAX")
r = prc(maria, "12")
blocked("Maria 12% of $260,000 (> IRS limit)", r, "IRS_LIMIT")
check("IRS_LIMIT text names the limit and the max rate", "$23,500" in r["reason_text"] and "9%" in r["reason_text"], r)
blocked("Michael has only an IRA", prc(michael, "5"), "NO_401K")
p6 = prc(james, "6 percent")
check("James 6% -> PROPOSED, full match, next payroll", p6["outcome"] == "PROPOSED" and p6["proposal_id"]
      and "full employer match" in p6["summary"] and "$240" in p6["summary"]
      and p6["effective_date"] == val("SELECT next_payroll_date()::text"), p6)
check("re-propose while live -> same proposal (idempotent)", prc(james, "6")["proposal_id"] == p6["proposal_id"])
check("nothing changed before confirm", val("SELECT contribution_rate::text FROM retirement_accounts WHERE account_id='RET-5001'") == "3.00"
      and n("SELECT count(*) FROM account_events") == 0)
check("SCOPE: Maria confirms James's proposal -> NOT_FOUND",
      one("confirm_action", session_token=maria, proposal_id=p6["proposal_id"])["outcome"] == "NOT_FOUND"
      and n("SELECT count(*) FROM account_events") == 0)
c6 = one("confirm_action", session_token=james, proposal_id=p6["proposal_id"].lower())
ref_rate = c6["reference"]
check("confirm -> EXECUTED HLR-ACT-000101", c6["outcome"] == "EXECUTED" and ref_rate == "HLR-ACT-000101", c6)
check("trigger: rate now 6%, rate_changes 3->6, ACTION_EXECUTED audit",
      val("SELECT contribution_rate::text FROM retirement_accounts WHERE account_id='RET-5001'") == "6.00"
      and n("SELECT count(*) FROM rate_changes WHERE account_id='RET-5001' AND from_rate=3 AND to_rate=6") == 1
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='ACTION_EXECUTED' AND subject_id='{ref_rate}'") == 1)
check("match gap now 0", f2(one("get_my_retirement_accounts", session_token=james)["match_gap_pct"]) == 0)
c = one("confirm_action", session_token=james, proposal_id=p6["proposal_id"])
check("re-confirm -> ALREADY_DONE, same reference", c["outcome"] == "ALREADY_DONE" and c["reference"] == ref_rate, c)
check("confirm a bogus id -> NOT_FOUND", one("confirm_action", session_token=james, proposal_id="HLR-PRP-00000000")["outcome"] == "NOT_FOUND")

# confirm re-checks the rules (world changes between propose and confirm)
p10 = prc(james, "10")
psql("UPDATE plan_limits SET plan_max_rate = 8")
c = one("confirm_action", session_token=james, proposal_id=p10["proposal_id"])
check("confirm re-checks: plan max lowered after propose -> BLOCKED ABOVE_PLAN_MAX, rate unchanged",
      c["outcome"] == "BLOCKED" and c["reason_code"] == "ABOVE_PLAN_MAX"
      and val("SELECT contribution_rate::text FROM retirement_accounts WHERE account_id='RET-5001'") == "6.00", c)
psql("UPDATE plan_limits SET plan_max_rate = 15")
p = prc(james, "7")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE proposal_id = {lit(p['proposal_id'])}")
c = one("confirm_action", session_token=james, proposal_id=p["proposal_id"])
check("proposal older than 15 min -> EXPIRED, nothing changed", c["outcome"] == "EXPIRED"
      and val("SELECT contribution_rate::text FROM retirement_accounts WHERE account_id='RET-5001'") == "6.00", c)
check("re-propose after expiry -> a NEW proposal", prc(james, "7")["proposal_id"] not in ("", p["proposal_id"]))

# ---------------------------------------------------------------- fund switch rules
def psw(tk, acct, frm, to, amt):
    return one("propose_fund_switch", session_token=tk, account_id=acct, from_fund_id=frm, to_fund_id=to, amount=amt)


blocked("SCOPE: James switches in Maria's account", psw(james, "RET-5003", "FND-002", "FND-005", "100"), "NOT_FOUND")
blocked("into a fund closed to new money", psw(james, "RET-5001", "FND-001", "FND-011", "100"), "INVALID_FUND")
blocked("into an unknown fund", psw(james, "RET-5001", "FND-001", "FND-999", "100"), "INVALID_FUND")
blocked("same fund", psw(james, "RET-5001", "FND-001", "FND-001", "100"), "SAME_FUND")
blocked("out of a fund not held", psw(james, "RET-5001", "FND-007", "FND-005", "100"), "FUND_NOT_HELD")
blocked("negative amount", psw(james, "RET-5001", "FND-001", "FND-005", "-5"), "AMOUNT_INVALID")
blocked("amount 'lots'", psw(james, "RET-5001", "FND-001", "FND-005", "lots"), "AMOUNT_INVALID")
blocked("more than the holding", psw(james, "RET-5001", "FND-001", "FND-005", "$70,000"), "INSUFFICIENT_HOLDING")
ps = psw(james, "ret-5001", "fnd-001", "FND-005", "all")
check("switch ALL Aggressive Growth -> Target 2045: PROPOSED, entire holding $63,225", ps["outcome"] == "PROPOSED"
      and "entire Aggressive Growth" in ps["summary"] and "$63,225" in ps["summary"], ps)
bal0 = f2(val("SELECT account_balance('RET-5001')"))
cs = one("confirm_action", session_token=james, proposal_id=ps["proposal_id"])
check("switch confirm -> EXECUTED", cs["outcome"] == "EXECUTED", cs)
check("trigger: FND-001 units 0, FND-005 = 1904.3675 units, balance unchanged (+/- $0.01)",
      f2(val("SELECT units FROM holdings WHERE account_id='RET-5001' AND fund_id='FND-001'")) == 0
      and val("SELECT units::text FROM holdings WHERE account_id='RET-5001' AND fund_id='FND-005'") == "1904.3675"
      and abs(f2(val("SELECT account_balance('RET-5001')")) - bal0) <= 0.01)
hold = {x["fund_id"] for x in call("get_my_holdings", session_token=james) if x["account_id"] == "RET-5001"}
check("holdings no longer list FND-001; list FND-005", "FND-001" not in hold and "FND-005" in hold, hold)
ps2 = psw(james, "RET-5001", "FND-002", "FND-003", "20000")
cs2 = one("confirm_action", session_token=james, proposal_id=ps2["proposal_id"])
check("partial switch $20,000 FND-002 -> FND-003 executed; FND-002 value down by ~$20,000",
      cs2["outcome"] == "EXECUTED" and abs(f2(val("SELECT holding_value('RET-5001','FND-002')")) - 50720) < 1, cs2)

# ---------------------------------------------------------------- file a claim
def fcl(tk, pol, ty, desc="Member's own words.", docs=""):
    return one("file_claim", session_token=tk, policy_id=pol, claim_type=ty, description=desc, documents_needed=docs)


r = fcl(susan, "POL-1008", "CriticalIllness")
check("Susan: claim on the LAPSED policy -> BLOCKED POLICY_NOT_ACTIVE, no claim", r["outcome"] == "BLOCKED"
      and r["reason_code"] == "POLICY_NOT_ACTIVE" and "lapsed" in r["reason_text"]
      and n("SELECT count(*) FROM claims WHERE member_id='HLR-100104'") == 0, r)
r = fcl(patricia, "POL-1017", "CriticalIllness")
check("Patricia: Pending policy -> POLICY_NOT_ACTIVE", r["reason_code"] == "POLICY_NOT_ACTIVE" and "underwriting" in r["reason_text"], r)
r = fcl(james, "POL-1001", "Life")
check("James: life policy -> CLAIM_TYPE_MISMATCH (beneficiary claims a life benefit)", r["reason_code"] == "CLAIM_TYPE_MISMATCH"
      and "beneficiary" in r["reason_text"], r)
r = fcl(michael, "POL-1019", "Critical Illness")
check("Michael: CI claim on an Income Protection policy -> CLAIM_TYPE_MISMATCH", r["reason_code"] == "CLAIM_TYPE_MISMATCH", r)
r = fcl(david, "POL-1006", "IncomeProtection")
check("David: open claim on the policy -> DUPLICATE_OPEN_CLAIM", r["reason_code"] == "DUPLICATE_OPEN_CLAIM"
      and "CLM-2026-0001" in r["reason_text"], r)
r = fcl(james, "POL-1006", "IncomeProtection")
check("SCOPE: James files on David's policy -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = fcl(michael, "POL-1018", "critical_illness", "I was diagnosed with stage 2 breast... (test) and start treatment next week.",
        "attending physician statement; pathology report; completed claim form")
year = val("SELECT to_char(current_date, 'YYYY')")
check("Michael: CI claim FILED with a server-generated claim id + claim-decision case, Claims Examination",
      r["outcome"] == "FILED" and r["claim_id"] == f"CLM-{year}-0101" and r["case_id"] == "HLR-CASE-000101"
      and r["team"] == "Claims Examination" and f2(r["benefit_amount"]) == 120000, r)
mcase = r["case_id"]
check("claim row Submitted + case parked CLAIM_DECISION with the intake brief + audit",
      val(f"SELECT status FROM claims WHERE claim_id='CLM-{year}-0101'") == "Submitted"
      and val(f"SELECT parked_action FROM service_cases WHERE case_id='{mcase}'") == f"CLAIM_DECISION:CLM-{year}-0101"
      and "pathology report" in val(f"SELECT agent_brief FROM service_cases WHERE case_id='{mcase}'")
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CLAIM_FILED' AND subject_id='CLM-{year}-0101'") == 1)
r = fcl(michael, "POL-1018", "CriticalIllness")
check("filing again on the same policy -> DUPLICATE_OPEN_CLAIM", r["reason_code"] == "DUPLICATE_OPEN_CLAIM", r)

# ---------------------------------------------------------------- human-owned cases
def case(tk, ty, summary="Member request.", ref="", amount="", brief=""):
    return one("open_service_case", session_token=tk, request_type=ty, summary=summary, reference_id=ref, amount=amount, agent_brief=brief)


CASES = []
k = case(james, "beneficiary_change", "Recently divorced; wants to replace his former spouse with his daughter.", "POL-1001")
CASES.append(k)
check("James beneficiary_change -> OPENED, Policy & Retirement Services", k["outcome"] == "OPENED"
      and k["team"] == "Policy & Retirement Services" and re.fullmatch(r"HLR-CASE-\d{6}", k["case_id"] or ""), k)
jcase = k["case_id"]
k2 = case(james, "Beneficiary Change", "again", "POL-1001")
check("repeat -> EXISTING, same case", k2["outcome"] == "EXISTING" and k2["case_id"] == jcase, k2)
check("no beneficiary row was changed", n("SELECT count(*) FROM beneficiaries WHERE beneficiary_name='Emily Carter'") == 2)
k = case(james, "refund_now")
check("unknown type -> INVALID_TYPE", k["outcome"] == "INVALID_TYPE" and not k["case_id"], k)
k = case(james, "claim_decision")
check("claim_decision is not member-openable -> INVALID_TYPE", k["outcome"] == "INVALID_TYPE", k)
BRIEF = ("summary: Income Protection claim denied for the waiting period; member says she stopped work earlier. "
         "new_evidence: physician records; points_to_verify: physician-certified date stopped work")
k = case(linda, "claim_appeal", "My doctor's records show I stopped work much earlier than the employer form says.",
         "clm-2026-0004", "", BRIEF)
CASES.append(k)
check("Linda claim_appeal -> OPENED, Claims Examination, requested $3,800", k["outcome"] == "OPENED"
      and k["team"] == "Claims Examination" and f2(k["requested_amount"]) == 3800, k)
lcase = k["case_id"]
check("appeal case parks CLAIM_APPEAL and stores the agent brief",
      val(f"SELECT parked_action FROM service_cases WHERE case_id='{lcase}'") == "CLAIM_APPEAL:CLM-2026-0004"
      and "physician records" in val(f"SELECT agent_brief FROM service_cases WHERE case_id='{lcase}'"))
k = case(linda, "claim_appeal", "Appeal this one too.", "CLM-2026-0002")
check("SCOPE: appeal someone else's claim -> NOT_APPEALABLE", k["reason_code"] == "NOT_APPEALABLE" and not k["case_id"], k)
k = case(david, "claim_appeal", "Appeal.", "CLM-2026-0001")
check("appeal a claim that is not Denied -> NOT_APPEALABLE", k["reason_code"] == "NOT_APPEALABLE", k)
k = case(robert, "withdrawal_rollover", "Wants it all now.", "RET-5005", "9999999")
check("withdrawal above vested balance -> AMOUNT_INVALID", k["reason_code"] == "AMOUNT_INVALID", k)
k = case(james, "withdrawal_rollover", "Withdraw.", "RET-5005", "100")
check("withdrawal from someone else's account -> NOT_FOUND", k["reason_code"] == "NOT_FOUND", k)
k = case(maria, "investment_advice", "Wants advice on her allocation.")
CASES.append(k)
check("investment_advice -> Member Care", k["outcome"] == "OPENED" and k["team"] == "Member Care", k)
check("case texts are member-facing (no internal codes)", all("_" not in x["reason_text"] for x in CASES), CASES)

# ---------------------------------------------------------------- reviewer loop
q = call("get_review_queue", session_token=grace)
qids = [x["case_id"] for x in q]
check("Grace's queue: Claims Examination only - David's seeded case, Michael's new claim, Linda's appeal",
      set(qids) == {"HLR-CASE-000001", mcase, lcase} and all(x["status"] == "OK" for x in q), q)
check("queue is ordered by reply-due date", [x["reply_due"] for x in q] == sorted(x["reply_due"] for x in q), q)
check("queue shows first name + last initial only", any(x["member"] == "Linda W." for x in q), q)
mq = {x["case_id"] for x in call("get_review_queue", session_token=marcus)}
check("Marcus's queue: Robert's rollover, Jennifer's and James's beneficiary changes (not claims)",
      mq == {"HLR-CASE-000002", "HLR-CASE-000003", jcase}, mq)
rc = one("get_review_case", session_token=grace, case_id=lcase.lower())
check("Grace opens Linda's appeal: brief, statement, max $3,800, facts with the denial reason",
      rc["status"] == "OK" and "physician records" in rc["agent_brief"] and "doctor" in rc["member_statement"]
      and f2(rc["max_approvable"]) == 3800 and "WAITING_PERIOD_NOT_MET" in rc["facts"] and "waiting period 90 days" in rc["facts"], rc)
check("Grace cannot open Robert's case (another team) -> NOT_FOUND",
      one("get_review_case", session_token=grace, case_id="HLR-CASE-000002")["status"] == "NOT_FOUND")
check("member token cannot open a case -> NOT_REVIEWER",
      one("get_review_case", session_token=linda, case_id=lcase)["status"] == "NOT_REVIEWER")


def decide(tk, cid, dec, amt="", note="Reviewed the file.", msg=""):
    return one("decide_review_case", session_token=tk, case_id=cid, decision=dec, amount=amt, internal_note=note, customer_message=msg)


def no_decision(cid):
    return n(f"SELECT count(*) FROM review_decisions WHERE case_id='{cid}'") == 0 \
        and val(f"SELECT status FROM service_cases WHERE case_id='{cid}'") == "OPEN"


r = decide(linda, lcase, "APPROVE", "3800", "self-approval attempt")
check("INJECTION: the member's own token cannot decide -> NOT_REVIEWER, no decision row", r["outcome"] == "NOT_REVIEWER"
      and no_decision(lcase), r)
r = decide(grace, "HLR-CASE-000002", "APPROVE", "8000")
check("Grace decides Robert's case -> NOT_YOUR_TEAM, nothing executed", r["reason_code"] == "NOT_YOUR_TEAM"
      and no_decision("HLR-CASE-000002") and n("SELECT count(*) FROM withdrawals") == 0, r)
check("decide an unknown case -> NOT_FOUND", decide(grace, "HLR-CASE-999999", "APPROVE")["reason_code"] == "NOT_FOUND")
check("note 'ok' -> NOTE_REQUIRED", decide(grace, lcase, "APPROVE", "3800", "ok")["reason_code"] == "NOTE_REQUIRED" and no_decision(lcase))
check("decision 'maybe' -> INVALID_DECISION", decide(grace, lcase, "maybe")["reason_code"] == "INVALID_DECISION")
check("amount above the claim -> AMOUNT_INVALID", decide(grace, lcase, "APPROVE", "5000")["reason_code"] == "AMOUNT_INVALID")
check("negative amount -> AMOUNT_INVALID", decide(grace, lcase, "APPROVE", "-1")["reason_code"] == "AMOUNT_INVALID" and no_decision(lcase))
NOTE = "Physician records confirm 120+ days off work; waiting period met. Overturn."
MSG = "Good news: your appeal was approved and your Income Protection benefit of $3,800 has been paid."
r = decide(grace, lcase, "approve", "$3,800", NOTE, MSG)
check("Grace APPROVES the appeal -> APPROVED, payment executed", r["outcome"] == "APPROVED" and f2(r["approved_amount"]) == 3800
      and "HLR-PAY-000101" in r["executed_action"] and r["case_status"] == "APPROVED", r)
check("DB: decision row, claim Approved, payment $3,800, case APPROVED + message, CASE_DECIDED audit",
      n(f"SELECT count(*) FROM review_decisions WHERE case_id='{lcase}' AND reviewer_id='HLS-2041'") == 1
      and val("SELECT status FROM claims WHERE claim_id='CLM-2026-0004'") == "Approved"
      and f2(val("SELECT amount FROM claim_payments WHERE claim_id='CLM-2026-0004'")) == 3800
      and val(f"SELECT customer_message FROM service_cases WHERE case_id='{lcase}'") == MSG
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{lcase}' AND actor='HLS-2041'") == 1)
r = decide(grace, lcase, "REJECT", "", "Second try.")
check("double decision -> ALREADY_DECIDED, still one decision + one payment", r["reason_code"] == "ALREADY_DECIDED"
      and n(f"SELECT count(*) FROM review_decisions WHERE case_id='{lcase}'") == 1
      and n("SELECT count(*) FROM claim_payments WHERE claim_id='CLM-2026-0004'") == 1, r)
r = decide(grace, "HLR-CASE-000001", "REJECT", "", "Medical evidence does not support total disability.",
           "After review, your claim was not approved. We will send you a letter explaining why.")
check("Grace REJECTS David's claim decision -> claim Denied, no payment", r["outcome"] == "REJECTED"
      and val("SELECT status FROM claims WHERE claim_id='CLM-2026-0001'") == "Denied"
      and n("SELECT count(*) FROM claim_payments WHERE claim_id='CLM-2026-0001'") == 0, r)
bal = f2(val("SELECT account_balance('RET-5005')"))
r = decide(marcus, "HLR-CASE-000002", "APPROVE", "8000", "Hardship documented; roof repair invoice on file.")
check("Marcus approves $8,000 (> his $5,000 limit) -> OVER_AUTHORITY, case stays OPEN, no withdrawal",
      r["reason_code"] == "OVER_AUTHORITY" and "senior reviewer" in r["reason_text"] and no_decision("HLR-CASE-000002")
      and n("SELECT count(*) FROM withdrawals") == 0, r)
r = decide(marcus, "HLR-CASE-000002", "APPROVE", "", "Default amount = full $8,000.")
check("blank amount defaults to the full $8,000 -> also OVER_AUTHORITY", r["reason_code"] == "OVER_AUTHORITY", r)
r = decide(marcus, "HLR-CASE-000002", "APPROVE", "4000", "Approve the portion within my authority; member agreed.")
check("Marcus approves $4,000 -> APPROVED, withdrawal executed, balance down $4,000",
      r["outcome"] == "APPROVED" and "HLR-WDR-000101" in r["executed_action"]
      and abs(f2(val("SELECT account_balance('RET-5005')")) - (bal - 4000)) < 1, r)
r = decide(marcus, "HLR-CASE-000003", "APPROVE", "", "Form received with signatures.", "")
check("beneficiary change approved -> no automatic action, default member message", r["outcome"] == "APPROVED"
      and "no automatic action" in r["executed_action"] and "approved" in r["customer_message"], r)
check("every decision has an audit row", n("SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED'")
      == n("SELECT count(*) FROM review_decisions") == 4)

# ---------------------------------------------------------------- the member sees the outcome
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=linda)}
check("Linda's cases: appeal APPROVED with the customer message and $3,800", mc[lcase]["case_status"] == "APPROVED"
      and mc[lcase]["customer_message"] == MSG and f2(mc[lcase]["outcome_amount"]) == 3800, mc)
cl = one("get_my_claims", session_token=linda)
check("Linda's claim: Approved, payment reference shown", cl["claim_status"] == "Approved" and cl["payment_reference"] == "HLR-PAY-000101"
      and cl["related_case_status"] == "APPROVED", cl)
check("Robert's case shows the $4,000 outcome", f2(one("get_my_cases", session_token=robert)["outcome_amount"]) == 4000)

# ---------------------------------------------------------------- email guard
e = one("email_confirmation", session_token=james, reference=ref_rate.lower())
check("email own executed change -> SEND_OK, mentions 6% and Ella", e["send_status"] == "SEND_OK" and ref_rate in e["subject"]
      and "6%" in e["body"] and "Ella" in e["body"], e)
e = one("email_confirmation", session_token=linda, reference=lcase)
check("email own decided case -> SEND_OK with the member message, never the internal note",
      e["send_status"] == "SEND_OK" and MSG in e["body"] and NOTE not in e["body"], e)
e = one("email_confirmation", session_token=michael, reference=f"CLM-{year}-0101")
check("email own claim filed in chat -> SEND_OK", e["send_status"] == "SEND_OK" and "pathology" in e["body"], e)
e = one("email_confirmation", session_token=james, reference=lcase)
check("SCOPE: James emails Linda's case -> NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
e = one("email_confirmation", session_token=james, reference=jcase)
check("email an undecided case -> NOT_FOUND", e["reason_code"] == "NOT_FOUND", e)
check("exactly 3 emails logged", n("SELECT count(*) FROM email_log") == 3)

# ---------------------------------------------------------------- session expiry
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(james)}")
check("expired member token -> SESSION_INVALID", one("get_my_profile", session_token=james)["status"] == "SESSION_INVALID")
check("expired token cannot propose", prc(james, "8")["outcome"] == "SESSION_INVALID")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(marcus)}")
check("expired reviewer token -> NOT_REVIEWER", one("get_review_queue", session_token=marcus)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- hidden data never leaves the DB
mem_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
leaked = sorted({k for _, rows in mem_out for row in rows for k in row} & HIDDEN_COLUMNS)
check("no member tool output has a hidden column", not leaked, leaked)
mblob = "\n".join(str(v) for _, rows in mem_out for row in rows for v in row.values())
secrets = [x["v"] for x in psql("SELECT ssn v FROM members UNION ALL SELECT email FROM members UNION ALL SELECT internal_note FROM review_decisions "
                                "UNION ALL SELECT display_name FROM reviewers UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL")]
check("member outputs never contain SSNs, emails, internal notes, reviewer names or agent briefs",
      not any(s and s in mblob for s in secrets), [s for s in secrets if s and s in mblob][:3])
rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
rblob = "\n".join(str(v) for _, rows in rev_out for row in rows for v in row.values())
check("reviewer outputs: no SSN / email / date of birth / full last name",
      not rleak and not re.search(r"900-11-|@example\.com|Williams|Johnson", rblob), (rleak, rblob[:200]))
texts = [str(row.get(k) or "") for _, rows in mem_out for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the member|the model|LLM|the assistant|the user)\b", t, re.I)]
check("member-facing texts address the member (never the model)", not bad, bad[:3])
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT v FROM (SELECT (json_each_text(row_to_json(m))).* FROM members m) x(k, v) "
    "  WHERE k IN ('member_id','otp_code','last_name','email','ssn','employer') "
    "UNION SELECT first_name || ' ' || last_name FROM members "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT beneficiary_name FROM beneficiaries UNION SELECT policy_id FROM policies UNION SELECT claim_id FROM claims "
    "UNION SELECT account_id FROM retirement_accounts UNION SELECT case_id FROM service_cases "
    "UNION SELECT session_token FROM sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 30, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_claim_document_checklist": ("pay stub", "IncomeProtection - last pay stub", "waiting period", 1),
    "get_life_event_checklist": ("divorce", "divorce", "spousal consent", 1),
    "get_appeal_review_guide": ("lapsed", "POLICY_LAPSED", "denial reason", 6),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["claim_intake_agent", "life_event_agent", "appeal_summary_agent"])
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
    check(f"{tool}: no member / beneficiary / reviewer / policy / claim / case / session value in the reference rows",
          not leaked, leaked[:5])
    check(f"{tool}: no member id, staff id, policy, claim, account or case id, email or token pattern",
          not re.search(r"hlr-\d|hls-\d|hlr-case|hlr-prp|pol-\d|clm-\d|ret-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-|\d{3}-\d{2}-\d{4}", blob),
          blob[:200])

REFT = {t["agent"]: t for t in AGENT_REF_TOOLS}
both = ref_call(REFT["life_event_agent"], "divorce, retirement")
check("ref_life_event: several words in one call ('divorce, retirement') -> both found",
      {"divorce", "retirement"} <= {r["term"] for r in both}, [r["term"] for r in both])
route = {r["request_type"]: r for r in psql("SELECT request_type, label, team, sla_text FROM case_routing")}
for agent, sec, types in (("claim_intake_agent", "who decides", ["claim_decision"]),
                          ("life_event_agent", "who helps", ["beneficiary_change", "withdrawal_rollover", "investment_advice"]),
                          ("appeal_summary_agent", "who decides", ["claim_appeal"])):
    rows = [r for r in ref_call(REFT[agent], "") if r["section"] == sec.upper().replace(" ", "_")]
    check(f"{REFT[agent]['fn']}: {sec.upper().replace(' ', '_')} rows come from case_routing (one source of truth)",
          sorted((r["term"], r["meaning"]) for r in rows)
          == sorted((route[x]["label"], f"{route[x]['team']}: {route[x]['sla_text']}") for x in types), rows)
codes = {r["c"] for r in psql("SELECT DISTINCT denial_reason_code c FROM claims WHERE denial_reason_code IS NOT NULL")}
check("ref_appeal_guide: every denial reason code used on a claim is explained",
      bool(codes) and codes <= {r["term"] for r in ref_call(REFT["appeal_summary_agent"], "denial reason")}, codes)
rels = {r["r"] for r in psql("SELECT DISTINCT relationship r FROM beneficiaries")}
check("ref_life_event: every beneficiary relationship value on file is explained",
      bool(rels) and rels <= {r["term"] for r in ref_call(REFT["life_event_agent"], "relationship")}, rels)
ctypes = {r["term"] for r in ref_call(REFT["claim_intake_agent"], "claim type") if r["section"] == "CLAIM_TYPE"}
check("ref_claim_checklist: every claim_type the claims table accepts (plus NotClaimableHere) is defined",
      ctypes == {"CriticalIllness", "IncomeProtection", "NotClaimableHere"}, ctypes)
# nothing from the old static glossary text was lost
KEEP = {"get_claim_document_checklist": ["cancer, heart attack, stroke or major organ failure", "signed off by a doctor",
                                         "made by the beneficiary, not the member", "date of diagnosis", "pathology",
                                         "hospital discharge summary", "expected return date",
                                         "employer statement of absence and earnings", "last pay stub before the absence",
                                         "90 consecutive days", "certified death certificate",
                                         "a claims examiner decides every claim"],
        "get_life_event_checklist": ["no longer reflect", "consent otherwise", "trust for a minor", "roll it over",
                                     "take a distribution", "survivor claim", "withdrawal and income options",
                                     "husband or wife", "son or daughter", "mother or father", "brother or sister",
                                     "paid only if no primary beneficiary survives", "add up to 100",
                                     "written, witnessed consent", "signed form", "policy & retirement services",
                                     "licensed adviser", "member care"],
        "get_appeal_review_guide": ["waiting_period_not_met", "insufficient_medical_evidence", "pre_existing_condition",
                                    "policy_lapsed", "not_a_covered_condition", "elimination period", "90 days",
                                    "not in the claim file", "restatement of the original claim is not new evidence",
                                    "employer records of the absence",
                                    "different person from the one who made the original decision",
                                    "never predicts the outcome"]}
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
