#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the mobile_billing DB and assert the
business rules on DB state - including the human-in-the-loop reviewer loop (parked actions, every decide reason code,
execution through the guarded row, audit) and the three A2A agents' PostgreSQL reference tools (AGENT_REF_TOOLS).
No Flogo needed. Re-loads reset_data.sql first, again before the reviewer block, and at the end (re-runnable).

  python _rebuild/test_rules.py
Password: env PG_PWD, else PG_PASSWORD from the nearest skills-library/.claude/skills/config.md (never printed).
Env overrides: PSQL, PG_HOST, PG_PORT, PG_USER, PG_DB, CONFIG_MD.
"""
import csv, io, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import (TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS, AGENT_REF_TOOLS, GUIDE_TOOLS,
                       REF_COLUMNS)

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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "mobile_billing"),
        "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = 0
passes = 0
OUTPUTS = []          # every tool read result, for the hidden-column scan


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
        print(r.stderr.encode("ascii", "replace").decode()); sys.exit(1)
    return list(csv.DictReader(io.StringIO(r.stdout)))


def call(tool, **args):
    t = T[tool]
    assert set(args) <= {a for a, _ in t["args"]}, (tool, args)
    args = {a: args.get(a, "") for a, _ in t["args"]}          # like the MCP client: every spec arg, "" when not given
    if "write" in t:
        psql(sub(*t["write"], args))
    rows = psql(sub(*t["read"], args))
    OUTPUTS.append((tool, rows))
    return rows


def one(tool, **args):
    return call(tool, **args)[0]


def n(sql):
    return int(psql(sql)[0]["n"])


def val(sql):
    return psql(sql)[0]["v"]


def check(label, cond, detail=""):
    global fails, passes
    msg = ("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}")
    print(msg.encode("ascii", "replace").decode())
    if cond: passes += 1
    else: fails += 1


def reset():
    subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


reset()

# ---------------------------------------------------------------- contract shape
check("18 MCP tools (14 customer + 4 reviewer)", len(TOOLS) == 18 and len(REVIEWER_TOOLS) == 4, [t["tool"] for t in TOOLS])
check("tool names (the 13 original ones unchanged, then get_my_cases and the reviewer tools)", [t["tool"] for t in TOOLS] == [
    "verify_customer", "get_my_account", "get_my_bills", "get_bill_detail", "get_bill_comparison", "get_my_usage",
    "get_my_subscriptions", "get_my_payments", "get_eligible_plans", "propose_action", "confirm_action",
    "open_service_case", "email_action_confirmation", "get_my_cases", "verify_reviewer", "get_review_queue",
    "get_review_case", "decide_review_case"])
check("every write is INSERT ... SELECT (never VALUES)",
      all(re.match(r"INSERT INTO \w+ \([^)]*\) SELECT ", t["write"][0]) and "VALUES" not in t["write"][0].upper()
          for t in TOOLS if "write" in t))
check("write placeholders ?w_*, read placeholders not ?w_*",
      all(all(p.startswith("w_") for p, _ in t["write"][1]) for t in TOOLS if "write" in t)
      and all(not p.startswith("w_") for t in TOOLS for p, _ in t["read"][1]))
check("no ?p:: casts anywhere", not any(re.search(r"\?\w+::", t.get("write", ("",))[0] + t["read"][0]) for t in TOOLS))

# ---------------------------------------------------------------- identity
r = one("verify_customer", mobile_number="2125550101", otp="0000")
check("wrong OTP -> VERIFY_FAILED, no token, no hint", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "match" in r["reason_text"], r)
check("wrong OTP issues no session", n("SELECT count(*) n FROM customer_sessions") == 0)
r = one("verify_customer", mobile_number="(212) 555-0199", otp="4821")
check("unknown number -> VERIFY_FAILED (same text)", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_customer", mobile_number="2125550102", otp="4821")
check("Maria's OTP with James's number -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
toks = []
for fmt in ("2125550101", "212-555-0101", "(212) 555-0101", "+1 212 555 0101", "12125550101"):
    r = one("verify_customer", mobile_number=fmt, otp="4821")
    check(f"number format '{fmt}' -> VERIFIED + token", r["outcome"] == "VERIFIED" and r["session_token"]
          and r["first_name"] == "Maria", r)
    toks.append(r["session_token"])
maria = toks[-2]
james = one("verify_customer", mobile_number="212-555-0102", otp="7305")["session_token"]
priya = one("verify_customer", mobile_number="(212) 555-0103", otp="9164")["session_token"]
kevin = one("verify_customer", mobile_number="+1 212 555 0104", otp="2210")["session_token"]
dana = one("verify_customer", mobile_number="2125550105", otp="6634")["session_token"]
check("all 5 demo logins verify", all([maria, james, priya, kevin, dana]))

# ---------------------------------------------------------------- scoped reads
a = one("get_my_account", session_token=maria)
check("Maria account: ESS15 $45, 15 GB, ACTIVE, month-to-month, no limit, no TravelPass, no SIM swap",
      a["status"] == "OK" and a["plan_code"] == "ESS15" and a["monthly_price"] == "45.00" and a["data_gb"] == "15 GB"
      and a["mobile_number"] == "(212) 555-0101" and a["account_status"] == "ACTIVE"
      and a["contract_type"].startswith("No annual contract") and a["roaming_limit"] == "No limit set"
      and a["travel_pass"] == "Not enrolled" and a["last_sim_swap_date"] == "", a)
a = one("get_my_account", session_token=james)
check("James account: UNLPLUS, Unlimited data, $50 roaming limit", a["plan_code"] == "UNLPLUS"
      and a["data_gb"] == "Unlimited" and a["roaming_limit"].startswith("$50 "), a)
a = one("get_my_account", session_token=priya)
p_swap = a["last_sim_swap_date"]
check("Priya account: device installment ~30 months + last_sim_swap_date set", a["contract_type"] == "Device installment plan"
      and a["contract_end"] == val("SELECT (current_date + interval '30 months')::date::text v") and p_swap, a)
a = one("get_my_account", session_token=kevin)
check("Kevin account: TravelPass enrolled, $100 limit", a["travel_pass"].startswith("Enrolled")
      and a["roaming_limit"].startswith("$100 "), a)
a = one("get_my_account", session_token=dana)
check("Dana account shows ACCOUNT_HOLD (not the flag)", a["account_status"] == "ACCOUNT_HOLD", a)

bills = call("get_my_bills", session_token=maria)
check("Maria has 2 bills: latest $270.00 UNPAID (not overdue), previous $52.00 PAID", len(bills) == 2
      and bills[0]["total"] == "270.00" and bills[0]["bill_status"] == "UNPAID"
      and bills[1]["total"] == "52.00" and bills[1]["bill_status"] == "PAID", bills)
m_latest = bills[0]["bill_id"]
d = call("get_bill_detail", session_token=maria, bill_id=m_latest.lower())
cats = {x["category"] for x in d}
roam = [x for x in d if x["category"] == "ROAMING"]
mb = sum(int(re.search(r"(\d+) MB", x["description"]).group(1)) for x in roam if " MB " in x["description"])
mins = sum(int(re.search(r"(\d+) min", x["description"]).group(1)) for x in roam if " min " in x["description"])
check("Maria latest bill: plan + Mexico roaming + premium content + taxes & fees", d[0]["status"] == "OK"
      and cats == {"PLAN", "ROAMING", "PREMIUM_CONTENT", "TAXES_FEES"} and all("Mexico" in x["description"] for x in roam), d)
check("Maria roaming adds up: 85 MB x $2.05 = $174.25, 18 min x $1.79 = $32.22",
      mb == 85 and mins == 18
      and round(sum(float(x["amount"]) for x in roam if " MB " in x["description"]), 2) == round(85 * 2.05, 2)
      and round(sum(float(x["amount"]) for x in roam if " min " in x["description"]), 2) == round(18 * 1.79, 2), (mb, mins))
check("Maria line items sum to the bill total $270.00 (StarPlay $9.99, taxes $8.54)",
      round(sum(float(x["amount"]) for x in d), 2) == 270.00 and d[0]["bill_total"] == "270.00"
      and any("StarPlay" in x["description"] and x["amount"] == "9.99" for x in d)
      and any(x["category"] == "TAXES_FEES" and x["amount"] == "8.54" for x in d), d)
check("Maria's Mexico roaming dates match 4 recorded roaming days",
      sorted({x["charge_date"] for x in roam}) == [x["roam_date"] for x in psql(
          "SELECT roam_date FROM roaming_days WHERE customer_id='TW-C-0101' AND country='Mexico' ORDER BY 1")]
      and n("SELECT count(*) n FROM roaming_days WHERE customer_id='TW-C-0101'") == 4)
j_bills = call("get_my_bills", session_token=james)
j_bill = j_bills[0]["bill_id"]
check("James: 2 bills, the older $186.40 OVERDUE", len(j_bills) == 2
      and any(b["bill_status"] == "OVERDUE" and b["total"] == "186.40" for b in j_bills), j_bills)
d = call("get_bill_detail", session_token=maria, bill_id=j_bill)
check("SCOPE: Maria asks for James's bill -> NOT_FOUND, nothing leaked", len(d) == 1 and d[0]["status"] == "NOT_FOUND"
      and not d[0]["description"] and not d[0]["amount"] and not d[0]["bill_total"], d)
cmp_ = {x["category"]: x for x in call("get_bill_comparison", session_token=maria)}
check("comparison: 6 categories", set(cmp_) == {"plan", "roaming", "premium_content", "voice_sms", "taxes_fees", "other"},
      cmp_.keys())
check("comparison (Maria): roaming +206.47, premium_content +9.99, taxes_fees +1.54, plan 0, $52.00 -> $270.00",
      float(cmp_["roaming"]["delta"]) == 206.47 and float(cmp_["premium_content"]["delta"]) == 9.99
      and float(cmp_["taxes_fees"]["delta"]) == 1.54 and float(cmp_["plan"]["delta"]) == 0
      and cmp_["plan"]["latest_total"] == "270.00" and cmp_["plan"]["previous_total"] == "52.00", cmp_)
cmp_ = {x["category"]: x for x in call("get_bill_comparison", session_token=priya)}
check("comparison (Priya): roaming +96.32, $94.10 -> $190.42", float(cmp_["roaming"]["delta"]) == 96.32
      and cmp_["plan"]["latest_total"] == "190.42" and cmp_["plan"]["previous_total"] == "94.10", cmp_)
d = call("get_bill_detail", session_token=priya, bill_id=call("get_my_bills", session_token=priya)[0]["bill_id"])
p_roam = [x for x in d if x["category"] == "ROAMING"]
check("Priya: Canada roaming charge 2 days after the SIM swap, both inside the latest bill period",
      len(p_roam) == 2 and all("Canada" in x["description"] for x in p_roam)
      and all(x["charge_date"] == val(f"SELECT ({lit(p_swap)}::date + 2)::text v") for x in p_roam)
      and val(f"SELECT ({lit(p_swap)}::date >= (date_trunc('month', current_date) - interval '1 month')::date)::text v") == "true",
      (p_swap, p_roam))
check("Priya: ZERO roaming days on record (fraud signal)", n("SELECT count(*) n FROM roaming_days WHERE customer_id='TW-C-0103'") == 0)

u = one("get_my_usage", session_token=maria)
check("usage (Maria): 15 GB allowance, 5.2 used, no roaming this cycle, no limit, not enrolled",
      u["data_allowance_gb"] == "15 GB" and u["data_used_gb"] == "5.20" and u["roaming_days_this_cycle"] == "0"
      and float(u["roaming_charges_this_cycle"]) == 0 and u["roaming_limit"] == "No limit set"
      and u["travel_pass"] == "Not enrolled" and u["voice_allowance_min"] == "Unlimited", u)
check("usage (Maria): last 3 cycles 13.9/12.6/11.8 GB and 'Mexico 4 days' last cycle",
      u["data_gb_last_3_cycles"].count("GB") == 3 and u["data_gb_last_3_cycles"].split(",")[0].endswith("13.9 GB")
      and u["roaming_days_last_3_cycles"].split(";")[0].endswith("Mexico 4 days"), u)
u = one("get_my_usage", session_token=priya)
check("usage (Priya): no days abroad in any of the last 3 cycles", u["roaming_days_last_3_cycles"].count("no days abroad") == 3
      and "Canada" not in u["roaming_days_last_3_cycles"], u)
u = one("get_my_usage", session_token=kevin)
check("usage (Kevin): 1 TravelPass day in Canada this cycle = $10, limit $100", u["roaming_days_this_cycle"] == "1"
      and float(u["roaming_charges_this_cycle"]) == 10 and u["travel_pass"].startswith("Enrolled")
      and u["roaming_limit"].startswith("$100"), u)
subs = call("get_my_subscriptions", session_token=maria)
st = {x["item_id"]: x for x in subs}
check("subscriptions (Maria): StarPlay ACTIVE $9.99/month, Horoscope CANCELLED, TravelPass NOT_ENROLLED",
      st.get("SUB-1001", {}).get("item_status") == "ACTIVE" and st["SUB-1001"]["monthly_price"] == "9.99"
      and "StarPlay" in st["SUB-1001"]["name"] and st.get("SUB-1002", {}).get("item_status") == "CANCELLED"
      and st.get("TRAVELPASS", {}).get("item_status") == "NOT_ENROLLED" and "$10 per day" in st["TRAVELPASS"]["price_text"], subs)
st = {x["item_id"]: x["item_status"] for x in call("get_my_subscriptions", session_token=kevin)}
check("subscriptions (Kevin): only the TravelPass row, ENROLLED", st == {"TRAVELPASS": "ENROLLED"}, st)
p = call("get_my_payments", session_token=james)
check("James payments: $186.40 past due 45 days, balance $268.70, overdue yes", p[0]["past_due_amount"] == "186.40"
      and p[0]["balance_due"] == "268.70" and p[0]["overdue"] == "yes" and p[0]["days_overdue"] == "45", p)
p = call("get_my_payments", session_token=maria)
check("Maria payments: overdue no, past due 0, balance $270 (latest not due yet), AutoPay", p[0]["overdue"] == "no"
      and float(p[0]["past_due_amount"]) == 0 and p[0]["balance_due"] == "270.00" and p[0]["method"] == "AutoPay", p)
ep = {x["plan_code"]: x for x in call("get_eligible_plans", session_token=maria)}
check("eligible plans (Maria): 4 others, all allowed; UNLPREM UPGRADE +$40 today w/ Mexico & Canada roaming",
      len(ep) == 4 and all(x["allowed"] == "yes" for x in ep.values()) and ep["UNLPREM"]["change_type"] == "UPGRADE"
      and float(ep["UNLPREM"]["price_diff"]) == 40 and "Mexico" in ep["UNLPREM"]["roaming_included"]
      and ep["UNLPREM"]["effective_date"] == val("SELECT current_date::text v") and ep["UNLPREM"]["data_gb"] == "Unlimited", ep)
check("eligible plans (Maria): BASIC5 DOWNGRADE effective the 1st of next month", ep["BASIC5"]["change_type"] == "DOWNGRADE"
      and ep["BASIC5"]["effective_date"] == val("SELECT next_cycle_start()::text v"), ep["BASIC5"])
ep = {x["plan_code"]: x for x in call("get_eligible_plans", session_token=priya)}
check("eligible plans (Priya): every option LOCKED_IN while the device installment is open",
      set(ep) == {"BASIC5", "ESS15", "UNLPLUS", "UNLPREM"} and all(x["reason_code"] == "LOCKED_IN" and x["allowed"] == "no"
                                                                  for x in ep.values()), ep)
ep = {x["plan_code"]: x for x in call("get_eligible_plans", session_token=james)}
check("eligible plans (James): upgrades ARREARS, ESS15/BASIC5 allowed", ep["UNLPREM"]["reason_code"] == "ARREARS"
      and ep["UNLPLUSD"]["reason_code"] == "ARREARS" and ep["ESS15"]["allowed"] == "yes" and ep["BASIC5"]["allowed"] == "yes", ep)
ep = {x["plan_code"]: x for x in call("get_eligible_plans", session_token=kevin)}
check("eligible plans (Kevin): all CHANGE_PENDING", all(x["reason_code"] == "CHANGE_PENDING" for x in ep.values()), ep)
ep = {x["plan_code"]: x for x in call("get_eligible_plans", session_token=dana)}
check("eligible plans (Dana): all ACCOUNT_HOLD", all(x["reason_code"] == "ACCOUNT_HOLD" for x in ep.values()), ep)

# ---------------------------------------------------------------- SESSION_INVALID everywhere
BAD = "not-a-token"
for tool in ["get_my_account", "get_my_bills", "get_bill_comparison", "get_my_usage", "get_my_subscriptions",
             "get_my_payments", "get_eligible_plans"]:
    r = call(tool, session_token=BAD)
    check(f"SESSION_INVALID: {tool}", len(r) == 1 and r[0]["status"] == "SESSION_INVALID", r)
check("SESSION_INVALID: get_bill_detail", one("get_bill_detail", session_token=BAD, bill_id=m_latest)["status"] == "SESSION_INVALID")
before = n("SELECT count(*) n FROM pending_actions")
check("SESSION_INVALID: propose_action (no row written)",
      one("propose_action", session_token=BAD, action_type="ADD_TRAVEL_PASS", target="ON")["outcome"] == "SESSION_INVALID"
      and n("SELECT count(*) n FROM pending_actions") == before)
check("SESSION_INVALID: confirm_action", one("confirm_action", session_token=BAD, proposal_id="TW-PRP-00000000")["outcome"] == "SESSION_INVALID")
check("SESSION_INVALID: open_service_case", one("open_service_case", session_token=BAD, request_type="port_out",
                                                summary="x")["outcome"] == "SESSION_INVALID")
check("SESSION_INVALID: email_action_confirmation", one("email_action_confirmation", session_token=BAD,
                                                        reference="TW-ACT-000101")["reason_code"] == "SESSION_INVALID")


# ---------------------------------------------------------------- reason codes (propose)
def prop(tok, action, target):
    return one("propose_action", session_token=tok, action_type=action, target=target)


def blocked(label, tok, action, target, code):
    r = prop(tok, action, target)
    check(f"{label} -> {code}", r["outcome"] == "BLOCKED" and r["reason_code"] == code and r["reason_text"]
          and not r["proposal_id"], r)
    return r


# ADD_TRAVEL_PASS
blocked("James adds TravelPass (past due)", james, "ADD_TRAVEL_PASS", "ON", "ARREARS")
blocked("Kevin adds TravelPass (already enrolled)", kevin, "ADD_TRAVEL_PASS", "ON", "NO_CHANGE")
blocked("Maria TravelPass target OFF", maria, "ADD_TRAVEL_PASS", "OFF", "INVALID_TARGET")
# SET_ROAMING_LIMIT
blocked("James raises roaming limit $50 -> $200 (past due)", james, "SET_ROAMING_LIMIT", "200", "ARREARS")
blocked("James 'removes' the roaming limit", james, "SET_ROAMING_LIMIT", "none", "INVALID_CAP")
r = prop(james, "SET_ROAMING_LIMIT", "0")
check("James lowers roaming limit $50 -> $0: allowed even when past due", r["outcome"] == "PROPOSED" and r["proposal_id"], r)
j_lower = r["proposal_id"]
blocked("Maria roaming limit $75", maria, "SET_ROAMING_LIMIT", "75", "INVALID_CAP")
blocked("Maria roaming limit 'unlimited'", maria, "SET_ROAMING_LIMIT", "unlimited", "INVALID_CAP")
r = blocked("Kevin sets limit to his current '$100.00'", kevin, "SET_ROAMING_LIMIT", "$100.00", "NO_CHANGE")
check("roaming limit target normalised ($100.00 -> 100)", r["target"] == "100", r)
# CANCEL_SUBSCRIPTION
blocked("Maria cancels James's subscription", maria, "CANCEL_SUBSCRIPTION", "SUB-2001", "NOT_FOUND")
blocked("Maria cancels unknown subscription", maria, "CANCEL_SUBSCRIPTION", "SUB-9999", "NOT_FOUND")
blocked("Maria cancels Daily Horoscope again", maria, "CANCEL_SUBSCRIPTION", "SUB-1002", "ALREADY_CANCELLED")
# CHANGE_PLAN
blocked("James upgrades to UNLPREM (past due)", james, "CHANGE_PLAN", "UNLPREM", "ARREARS")
blocked("Priya downgrades below Unlimited Plus (device installment)", priya, "CHANGE_PLAN", "ESS15", "LOCKED_IN")
blocked("Priya drops the device installment (UNLPLUS)", priya, "CHANGE_PLAN", "UNLPLUS", "LOCKED_IN")
blocked("Kevin changes plan again this cycle", kevin, "CHANGE_PLAN", "UNLPREM", "CHANGE_PENDING")
blocked("Maria changes to her own plan", maria, "CHANGE_PLAN", "ESS15", "NO_CHANGE")
blocked("Maria changes to unknown plan", maria, "CHANGE_PLAN", "GOLD", "INVALID_TARGET")
# ACCOUNT_HOLD on everything
for act, tgt in [("ADD_TRAVEL_PASS", "ON"), ("SET_ROAMING_LIMIT", "0"), ("CANCEL_SUBSCRIPTION", "SUB-1001"),
                 ("CHANGE_PLAN", "UNLPREM")]:
    blocked(f"Dana (held) {act}", dana, act, tgt, "ACCOUNT_HOLD")
# INVALID_ACTION (incl. the removed bundle action)
blocked("Maria BUY_BUNDLE (no longer an action)", maria, "BUY_BUNDLE", "DATA5", "INVALID_ACTION")
blocked("Maria 'issue refund'", maria, "issue refund", "270", "INVALID_ACTION")
check("blocked proposals are recorded", n("SELECT count(*) n FROM pending_actions WHERE outcome='BLOCKED'") >= 20)
codes = {x["reason_code"] for x in psql("SELECT DISTINCT reason_code FROM pending_actions WHERE outcome='BLOCKED'")}
check("every reason code was produced", codes >= {"ARREARS", "ACCOUNT_HOLD", "NO_CHANGE", "INVALID_TARGET", "INVALID_CAP",
                                                   "NOT_FOUND", "ALREADY_CANCELLED", "LOCKED_IN", "CHANGE_PENDING",
                                                   "INVALID_ACTION"}, codes)
blk = psql("SELECT proposal_id FROM pending_actions WHERE outcome='BLOCKED' AND customer_id='TW-C-0105' LIMIT 1")[0]["proposal_id"]
c = one("confirm_action", session_token=dana, proposal_id=blk)
check("a BLOCKED proposal cannot be confirmed", c["outcome"] == "BLOCKED" and c["reason_code"] == "ACCOUNT_HOLD"
      and n("SELECT count(*) n FROM account_events") == 0, c)

# ---------------------------------------------------------------- injection (SPEC 7b): James "turn on TravelPass + remove the limit"
check("INJECTION: James has no account_events, no TravelPass, roaming limit still $50",
      n("SELECT count(*) n FROM account_events WHERE customer_id='TW-C-0102'") == 0
      and val("SELECT coalesce(travel_pass_since::text, 'none') v FROM customers WHERE customer_id='TW-C-0102'") == "none"
      and val("SELECT roaming_limit::text v FROM customers WHERE customer_id='TW-C-0102'") == "50.00")

# ---------------------------------------------------------------- happy path 1: CANCEL_SUBSCRIPTION
p1 = prop(maria, "CANCEL_SUBSCRIPTION", "sub-1001")
p2 = prop(maria, "CANCEL_SUBSCRIPTION", "SUB-1001")
check("cancel StarPlay -> PROPOSED with summary + expiry + customer-facing 'reply yes' text", p1["outcome"] == "PROPOSED"
      and p1["proposal_id"] and "StarPlay" in p1["summary"] and "$9.99/month" in p1["summary"] and p1["expires_at"]
      and p1["reason_text"] == "Nothing has changed yet. Reply yes within 15 minutes to go ahead.", p1)
check("re-propose is idempotent (same proposal)", p1["proposal_id"] == p2["proposal_id"], (p1, p2))
c = one("confirm_action", session_token=james, proposal_id=p1["proposal_id"])
check("SCOPE: James confirms Maria's proposal -> NOT_FOUND, no summary", c["outcome"] == "NOT_FOUND" and not c["summary"]
      and n("SELECT count(*) n FROM account_events") == 0, c)
c = one("confirm_action", session_token=maria, proposal_id="TW-PRP-00000000")
check("confirm unknown proposal -> NOT_FOUND", c["outcome"] == "NOT_FOUND", c)
c1 = one("confirm_action", session_token=maria, proposal_id=p1["proposal_id"].lower())
check("confirm -> EXECUTED with TW-ACT reference", c1["outcome"] == "EXECUTED" and re.match(r"TW-ACT-\d{6}$", c1["reference"] or ""), c1)
ref_cancel = c1["reference"]
check("trigger: StarPlay subscription CANCELLED",
      val("SELECT status v FROM content_subscriptions WHERE subscription_id='SUB-1001'") == "CANCELLED")
c2 = one("confirm_action", session_token=maria, proposal_id=p1["proposal_id"])
check("re-confirm -> ALREADY_DONE, same reference, still one event", c2["outcome"] == "ALREADY_DONE"
      and c2["reference"] == ref_cancel and n("SELECT count(*) n FROM account_events") == 1, c2)
blocked("re-propose cancel after it is done", maria, "CANCEL_SUBSCRIPTION", "SUB-1001", "ALREADY_CANCELLED")

# ---------------------------------------------------------------- happy path 2: ADD_TRAVEL_PASS
p = prop(maria, "ADD_TRAVEL_PASS", "on")
check("TravelPass -> PROPOSED, $10 per day, only on days abroad", p["outcome"] == "PROPOSED" and p["price"] == "10.00"
      and "$10 per day" in p["summary"] and "abroad" in p["summary"], p)
c = one("confirm_action", session_token=maria, proposal_id=p["proposal_id"])
check("TravelPass confirm -> EXECUTED", c["outcome"] == "EXECUTED", c)
check("trigger: travel_pass_since set", val("SELECT (travel_pass_since IS NOT NULL)::text v FROM customers WHERE customer_id='TW-C-0101'") == "true")
st = {x["item_id"]: x["item_status"] for x in call("get_my_subscriptions", session_token=maria)}
check("subscriptions now show TravelPass ENROLLED", st.get("TRAVELPASS") == "ENROLLED", st)
check("account now shows TravelPass enrolled", one("get_my_account", session_token=maria)["travel_pass"].startswith("Enrolled"))
blocked("TravelPass again", maria, "ADD_TRAVEL_PASS", "ON", "NO_CHANGE")

# ---------------------------------------------------------------- happy path 3: SET_ROAMING_LIMIT
p = prop(maria, "SET_ROAMING_LIMIT", "$100")
check("roaming limit $100 -> PROPOSED (target normalised to 100)", p["outcome"] == "PROPOSED" and p["target"] == "100"
      and "$100 limit" in p["summary"], p)
c = one("confirm_action", session_token=maria, proposal_id=p["proposal_id"])
check("limit confirm -> EXECUTED", c["outcome"] == "EXECUTED", c)
check("trigger: roaming_limit = 100", val("SELECT roaming_limit::text v FROM customers WHERE customer_id='TW-C-0101'") == "100.00")
check("usage now shows the $100 limit", one("get_my_usage", session_token=maria)["roaming_limit"].startswith("$100 "))
p = prop(maria, "SET_ROAMING_LIMIT", "200")
c = one("confirm_action", session_token=maria, proposal_id=p["proposal_id"])
check("raise $100 -> $200 in good standing -> EXECUTED", p["outcome"] == "PROPOSED" and c["outcome"] == "EXECUTED"
      and val("SELECT roaming_limit::text v FROM customers WHERE customer_id='TW-C-0101'") == "200.00", (p, c))
blocked("limit $200 again", maria, "SET_ROAMING_LIMIT", "200", "NO_CHANGE")
c = one("confirm_action", session_token=james, proposal_id=j_lower)
check("James lowers to $0 -> EXECUTED, pay-per-use roaming blocked", c["outcome"] == "EXECUTED"
      and val("SELECT roaming_limit::text v FROM customers WHERE customer_id='TW-C-0102'") == "0.00"
      and "blocked" in one("get_my_account", session_token=james)["roaming_limit"], c)

# ---------------------------------------------------------------- happy path 4: CHANGE_PLAN (upgrade now)
p = prop(maria, "CHANGE_PLAN", "unlprem")
check("upgrade UNLPREM -> PROPOSED effective today, +$40", p["outcome"] == "PROPOSED" and "Upgrade" in p["summary"]
      and "+$40" in p["summary"] and p["effective_date"] == val("SELECT current_date::text v"), p)
c = one("confirm_action", session_token=maria, proposal_id=p["proposal_id"])
check("upgrade confirm -> EXECUTED", c["outcome"] == "EXECUTED", c)
check("trigger: plan now UNLPREM + APPLIED change",
      val("SELECT plan_code v FROM customers WHERE customer_id='TW-C-0101'") == "UNLPREM"
      and n("SELECT count(*) n FROM plan_changes WHERE customer_id='TW-C-0101' AND status='APPLIED'") == 1)
check("account now includes Mexico & Canada roaming", "Mexico" in one("get_my_account", session_token=maria)["roaming_included"])
blocked("second plan change this cycle", maria, "CHANGE_PLAN", "UNLPLUS", "CHANGE_PENDING")

# downgrade (James, allowed while past due) -> scheduled for the 1st of next month
p = prop(james, "CHANGE_PLAN", "ESS15")
check("James downgrade ESS15 -> PROPOSED, effective 1st of next month", p["outcome"] == "PROPOSED"
      and p["effective_date"] == val("SELECT next_cycle_start()::text v"), p)
c = one("confirm_action", session_token=james, proposal_id=p["proposal_id"])
check("downgrade confirm -> EXECUTED", c["outcome"] == "EXECUTED", c)
check("trigger: SCHEDULED change, plan unchanged until then",
      val("SELECT plan_code v FROM customers WHERE customer_id='TW-C-0102'") == "UNLPLUS"
      and n("SELECT count(*) n FROM plan_changes WHERE customer_id='TW-C-0102' AND status='SCHEDULED'") == 1)
check("account shows the scheduled change", "Essential" in (one("get_my_account", session_token=james)["scheduled_plan_change"] or ""))

# ---------------------------------------------------------------- expiry
p = prop(maria, "SET_ROAMING_LIMIT", "0")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE proposal_id = {lit(p['proposal_id'])}")
ev = n("SELECT count(*) n FROM account_events")
c = one("confirm_action", session_token=maria, proposal_id=p["proposal_id"])
check("proposal older than 15 min -> EXPIRED, nothing changed", c["outcome"] == "EXPIRED"
      and n("SELECT count(*) n FROM account_events") == ev
      and val("SELECT roaming_limit::text v FROM customers WHERE customer_id='TW-C-0101'") == "200.00", c)
p2 = prop(maria, "SET_ROAMING_LIMIT", "0")
check("re-propose after expiry -> a NEW proposal", p2["outcome"] == "PROPOSED" and p2["proposal_id"] != p["proposal_id"], p2)

# ---------------------------------------------------------------- confirm re-checks every rule
p = prop(priya, "ADD_TRAVEL_PASS", "ON")
check("Priya TravelPass -> PROPOSED", p["outcome"] == "PROPOSED", p)
psql("UPDATE customers SET fraud_flag = TRUE WHERE customer_id = 'TW-C-0103'")      # world changes after propose
c = one("confirm_action", session_token=priya, proposal_id=p["proposal_id"])
check("confirm re-checks: hold placed after propose -> BLOCKED ACCOUNT_HOLD, no event", c["outcome"] == "BLOCKED"
      and c["reason_code"] == "ACCOUNT_HOLD" and n("SELECT count(*) n FROM account_events WHERE customer_id='TW-C-0103'") == 0, c)
psql("UPDATE customers SET fraud_flag = FALSE WHERE customer_id = 'TW-C-0103'")
psql("INSERT INTO bills (bill_id, customer_id, period_start, period_end, issue_date, due_date) "
     "VALUES ('TWB-0103-TEST', 'TW-C-0103', current_date - 40, current_date - 11, current_date - 10, current_date - 3); "
     "INSERT INTO bill_lines (bill_id, category, description, amount, charge_date) "
     "VALUES ('TWB-0103-TEST', 'OTHER', 'test: unpaid charge', 40, current_date - 10)")
c = one("confirm_action", session_token=priya, proposal_id=p["proposal_id"])
check("confirm re-checks: balance went past due after propose -> BLOCKED ARREARS, no TravelPass", c["outcome"] == "BLOCKED"
      and c["reason_code"] == "ARREARS"
      and val("SELECT coalesce(travel_pass_since::text, 'none') v FROM customers WHERE customer_id='TW-C-0103'") == "none", c)


# ---------------------------------------------------------------- human-owned cases
def case(tok, ty, summary="Customer request, routed for a person to decide."):
    return one("open_service_case", session_token=tok, request_type=ty, summary=summary)


CASE_TEXTS = []
k = case(priya, "suspected_fraud", "Does not recognise a Canada roaming charge; has not travelled; SIM was swapped 2 days earlier.")
CASE_TEXTS.append(k)
check("suspected_fraud -> OPENED, Fraud Team, 1 business day", k["outcome"] == "OPENED" and k["team"] == "Fraud Team"
      and "1 business day" in k["sla_text"] and re.match(r"TW-CASE-\d{6}$", k["case_id"] or ""), k)
k2 = case(priya, "Suspected Fraud")
CASE_TEXTS.append(k2)
check("repeat -> EXISTING with the same case_id, customer-facing label", k2["outcome"] == "EXISTING"
      and k2["case_id"] == k["case_id"] and "suspected fraud" in k2["reason_text"], k2)
k = case(priya, "port_out", "Wants to move her number to another provider.")
CASE_TEXTS.append(k)
check("port_out -> OPENED, Retention, 1 business day", k["outcome"] == "OPENED" and k["team"] == "Retention"
      and "1 business day" in k["sla_text"], k)
k = case(maria, "billing_dispute", "Asks for the $206.47 Mexico roaming charges and the $9.99 StarPlay charge to be credited.")
CASE_TEXTS.append(k)
check("credits -> billing_dispute OPENED, Billing Disputes, 5 business days", k["outcome"] == "OPENED"
      and k["team"] == "Billing Disputes" and "5 business days" in k["sla_text"], k)
check("credit request never creates a credit row (no negative unbilled/bill lines)",
      n("SELECT count(*) n FROM unbilled_charges WHERE amount < 0") == 0 and n("SELECT count(*) n FROM bill_lines WHERE amount < 0") == 0)
k = case(maria, "contract_cancellation")
CASE_TEXTS.append(k)
check("contract_cancellation -> OPENED, Retention", k["outcome"] == "OPENED" and k["team"] == "Retention", k)
k = case(maria, "refund_now")
CASE_TEXTS.append(k)
check("unknown type -> INVALID_TYPE, no team", k["outcome"] == "INVALID_TYPE" and not k["team"] and not k["case_id"], k)
check("case texts are customer-facing (no internal codes)", all("_" not in x["reason_text"] and "_" not in (x["sla_text"] or "")
                                                               for x in CASE_TEXTS), CASE_TEXTS)
check("exactly 4 cases opened (plus the 3 seeded queue cases)", n("SELECT count(*) n FROM service_cases") == 4 + 3)

# ---------------------------------------------------------------- email guard
e = one("email_action_confirmation", session_token=maria, reference=ref_cancel.lower())
check("email for own EXECUTED action -> SEND_OK with subject/body", e["send_status"] == "SEND_OK"
      and ref_cancel in e["subject"] and ref_cancel in e["body"] and "StarPlay" in e["body"]
      and "Nova" in e["body"] and "Tidewell Mobile" in e["subject"], e)
check("email logged", n(f"SELECT count(*) n FROM email_log WHERE reference = {lit(ref_cancel)}") == 1)
e = one("email_action_confirmation", session_token=james, reference=ref_cancel)
check("SCOPE: James emails Maria's reference -> NOT_FOUND, no body details", e["send_status"] == "NOT_SENT"
      and e["reason_code"] == "NOT_FOUND" and "StarPlay" not in e["body"], e)
e = one("email_action_confirmation", session_token=maria, reference="TW-ACT-999999")
check("email for unknown reference -> NOT_FOUND", e["reason_code"] == "NOT_FOUND", e)
e = one("email_action_confirmation", session_token=maria, reference=p2["proposal_id"])
check("email for a proposal that was never executed -> NOT_FOUND", e["reason_code"] == "NOT_FOUND", e)
check("no email logged for refused requests", n("SELECT count(*) n FROM email_log") == 1)

# ---------------------------------------------------------------- session expiry
psql(f"UPDATE customer_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(maria)}")
check("expired token -> SESSION_INVALID", one("get_my_account", session_token=maria)["status"] == "SESSION_INVALID")
check("expired token cannot confirm", one("confirm_action", session_token=maria, proposal_id=p2["proposal_id"])["outcome"] == "SESSION_INVALID")

# ================================================================ HUMAN-IN-THE-LOOP: cases park an action, a reviewer decides
reset()                                                     # fresh seeds: the 3 OPEN queue cases TW-CASE-000041..43
maria = one("verify_customer", mobile_number="2125550101", otp="4821")["session_token"]
james = one("verify_customer", mobile_number="2125550102", otp="7305")["session_token"]
priya = one("verify_customer", mobile_number="2125550103", otp="9164")["session_token"]
grace = one("verify_customer", mobile_number="2125550106", otp="5512")["session_token"]
dana = one("verify_customer", mobile_number="2125550105", otp="6634")["session_token"]
check("queue personas Grace (0106) and Luis (0107) verify too",
      bool(grace) and one("verify_customer", mobile_number="2125550107", otp="3378")["outcome"] == "VERIFIED")
m_bill = call("get_my_bills", session_token=maria)[0]["bill_id"]
p_bill = call("get_my_bills", session_token=priya)[0]["bill_id"]
g_bill = call("get_my_bills", session_token=grace)[0]["bill_id"]


def caserow(cid):
    return psql(f"SELECT case_id, customer_id, request_type, assigned_team, requested_amount, parked_action, status, "
                f"agent_brief, sla_due_at::text AS sla FROM service_cases WHERE case_id = {lit(cid)}")[0]


seeded = {r["case_id"]: r for r in psql("SELECT case_id, customer_id, assigned_team, requested_amount, parked_action, status "
                                        "FROM service_cases ORDER BY case_id")}
check("seeds: one OPEN case per reviewer team (Billing Disputes / Fraud Team / Retention)",
      [(r["case_id"], r["assigned_team"], r["status"]) for r in seeded.values()] ==
      [("TW-CASE-000041", "Billing Disputes", "OPEN"), ("TW-CASE-000042", "Fraud Team", "OPEN"), ("TW-CASE-000043", "Retention", "OPEN")],
      seeded)
check("seeds parked through case_parking(): Grace BILL_CREDIT $69.98, Dana PREMIUM_BLOCK $6.99, Luis nothing",
      seeded["TW-CASE-000041"]["parked_action"] == "BILL_CREDIT:" + g_bill and seeded["TW-CASE-000041"]["requested_amount"] == "69.98"
      and seeded["TW-CASE-000042"]["parked_action"].startswith("PREMIUM_BLOCK:") and seeded["TW-CASE-000042"]["requested_amount"] == "6.99"
      and seeded["TW-CASE-000043"]["parked_action"] == "" and seeded["TW-CASE-000043"]["requested_amount"] == "", seeded)
check("every case has its team and reply-due time from case_routing (trigger)",
      n("SELECT count(*) n FROM service_cases s JOIN case_routing r USING (request_type) "
        "WHERE s.assigned_team IS DISTINCT FROM r.team OR s.sla_due_at IS NULL") == 0)

FRAUD_BRIEF = ("category: SUSPECTED_FRAUD\nnext_path: open_fraud_case\nrationale: Pay-per-use roaming data, Canada, 40 MB "
               "($82.00) and calls, 8 min ($14.32) with zero days abroad on record, two days after a SIM swap.\n"
               "customer_line: Charges you did not make are checked by a person on our Fraud Team, who can reverse a SIM "
               "swap or block premium content.")
k = one("open_service_case", session_token=priya, request_type="suspected_fraud",
        summary="Does not recognise the Canada roaming charges; has not travelled; had a SIM swap shortly before.",
        brief=FRAUD_BRIEF, reference="")
PCASE = k["case_id"]
check("Priya suspected_fraud -> OPENED TW-CASE-000044, Fraud Team, requested $96.32, if_approved names the SIM-swap reversal",
      k["outcome"] == "OPENED" and PCASE == "TW-CASE-000044" and k["team"] == "Fraud Team" and k["requested_amount"] == "96.32"
      and "SIM swap is reversed" in (k["if_approved"] or "") and "$96.32" in (k["if_approved"] or "") and k["case_status"] == "OPEN", k)
row = caserow(PCASE)
check("DB: SQL parked SIM_SWAP_REVERSAL on her latest bill (recent SIM swap; only the roaming on no-roaming-record days)",
      row["parked_action"] == "SIM_SWAP_REVERSAL:" + p_bill and row["requested_amount"] == "96.32", row)
check("DB: the ChargeClassifier answer is stored as the agent brief", row["agent_brief"] == FRAUD_BRIEF)
k = one("open_service_case", session_token=maria, request_type="billing_dispute",
        summary="Asks for the Mexico roaming and StarPlay Games charges to be credited.", brief="", reference=m_bill.lower())
MCASE = k["case_id"]
check("Maria billing_dispute on her latest bill (lower-case id) -> OPENED, Billing Disputes, requested $216.46 (roaming + StarPlay)",
      k["outcome"] == "OPENED" and k["team"] == "Billing Disputes" and k["requested_amount"] == "216.46"
      and caserow(MCASE)["parked_action"] == "BILL_CREDIT:" + m_bill and "credit of up to $216.46" in (k["if_approved"] or ""), k)
k = one("open_service_case", session_token=james, request_type="billing_dispute", summary="Dispute that bill.", brief="",
        reference=m_bill)
check("SCOPE: James disputes Maria's bill -> BAD_REFERENCE, no case, customer-facing text",
      k["outcome"] == "BAD_REFERENCE" and not k["case_id"] and "could not find that bill" in k["reason_text"]
      and n("SELECT count(*) n FROM service_cases WHERE customer_id='TW-C-0102'") == 0, k)
k = one("open_service_case", session_token=priya, request_type="port_out", summary="Wants to move her number.", brief="", reference="")
RCASE = k["case_id"]
check("Priya port_out -> Retention, nothing parked (the team completes it)", k["outcome"] == "OPENED" and k["team"] == "Retention"
      and not k["requested_amount"] and caserow(RCASE)["parked_action"] == "" and "contact you" in (k["if_approved"] or ""), k)
check("CASE_OPENED audit row for every case (seeded ones too)", n("SELECT count(*) n FROM agent_audit WHERE action='CASE_OPENED'")
      == n("SELECT count(*) n FROM service_cases"))

# ---- reviewer identity (same token mechanism, role checked everywhere) ----
def vrev(staff, code): return one("verify_reviewer", staff_id=staff, code=code)


r = vrev("TWS-7001", "000000")
check("reviewer wrong code -> VERIFY_FAILED, no token, no hint", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "match" in r["reason_text"], r)
r = vrev("TWS-9999", "318274")
check("unknown staff id -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
check("a customer's mobile number + OTP is not a staff login", vrev("2125550101", "4821")["outcome"] == "VERIFY_FAILED")
r = vrev("TWS-7001", "318274")
alex = r["session_token"]
check("Alex (TWS-7001) -> VERIFIED, role REVIEWER, team Billing Disputes", r["outcome"] == "VERIFIED" and alex
      and r["role"] == "REVIEWER" and r["team"] == "Billing Disputes" and r["display_name"] == "Alex Rivera", r)
jordan = vrev(" tws-7002 ", "562039")["session_token"]
morgan = vrev("TWS-7004", "925148")["session_token"]
check("staff id is normalised (' tws-7002 ' works); Morgan verifies", bool(jordan) and bool(morgan))
for _ in range(5):
    vrev("TWS-7003", "111111")
r = vrev("TWS-7003", "740615")
check("5 wrong codes in 15 minutes -> LOCKED even with the right code, no session", r["outcome"] == "LOCKED" and not r["session_token"]
      and n("SELECT count(*) n FROM customer_sessions WHERE reviewer_id='TWS-7003'") == 0, r)
psql("DELETE FROM reviewer_verify_attempts WHERE reviewer_id = 'TWS-7003'")
sam = vrev("TWS-7003", "740615")["session_token"]
check("after the lockout window Sam (Retention) verifies", bool(sam))
check("DB: reviewer sessions carry role REVIEWER and no customer", n("SELECT count(*) n FROM customer_sessions WHERE role='REVIEWER' "
                                                                    "AND customer_id IS NULL AND reviewer_id IS NOT NULL") == 4)
check("a reviewer token is not a customer token (get_my_account -> SESSION_INVALID)",
      one("get_my_account", session_token=alex)["status"] == "SESSION_INVALID")
check("a reviewer token cannot propose a customer action", one("propose_action", session_token=alex, action_type="ADD_TRAVEL_PASS",
                                                               target="ON")["outcome"] == "SESSION_INVALID")
check("a customer token is not a reviewer token (queue -> NOT_REVIEWER)",
      one("get_review_queue", session_token=maria)["status"] == "NOT_REVIEWER")
check("bogus token on get_review_case -> NOT_REVIEWER", one("get_review_case", session_token="x", case_id="TW-CASE-000041")["status"] == "NOT_REVIEWER")

# ---- queues are scoped to the reviewer's team, ordered by reply-due time ----
qa = call("get_review_queue", session_token=alex)
check("Alex's queue: Billing Disputes only (Grace's seeded case + Maria's new one), ordered by reply-due",
      [x["case_id"] for x in qa] == ["TW-CASE-000041", MCASE] and all(x["team"] == "Billing Disputes" for x in qa)
      and qa[0]["reply_due"] <= qa[1]["reply_due"], qa)
check("queue shows first name + last initial only", qa[0]["customer"] == "Grace K." and qa[1]["customer"] == "Maria L.", qa)
qj = {x["case_id"] for x in call("get_review_queue", session_token=jordan)}
qs = {x["case_id"] for x in call("get_review_queue", session_token=sam)}
check("Fraud Team queue = Dana's seeded case + Priya's fraud case; Retention = Luis + Priya's port-out",
      qj == {"TW-CASE-000042", PCASE} and qs == {"TW-CASE-000043", RCASE}, (qj, qs))
check("another team's case is invisible (Alex opens Priya's fraud case -> NOT_FOUND, nothing shown)",
      one("get_review_case", session_token=alex, case_id=PCASE)["status"] == "NOT_FOUND"
      and not one("get_review_case", session_token=alex, case_id=PCASE)["customer_statement"])
rc = one("get_review_case", session_token=alex, case_id="tw-case-000041")
check("get_review_case (Grace): statement, brief, max $69.98, Alex's $60 limit, bill facts, options name the senior reviewer",
      rc["status"] == "OK" and "VidMax" in rc["customer_statement"] and "duplicate" in rc["agent_brief"]
      and rc["max_approvable"] == "69.98" and rc["your_approval_limit"] == "60.00" and "premium content $69.98" in rc["facts"]
      and "senior reviewer" in rc["options"] and "bill credit" in rc["if_approved"], rc)
rj = one("get_review_case", session_token=jordan, case_id=PCASE)
check("get_review_case (Priya fraud): SIM swap date, $96.32 on days with no roaming record, 0 days abroad, the agent brief",
      "SIM swap on" in rj["facts"] and "NO network roaming record: $96.32" in rj["facts"]
      and "days abroad on record in the bill period: 0" in rj["facts"] and rj["agent_brief"] == FRAUD_BRIEF
      and "reverses the recent SIM swap" in rj["if_approved"], rj)
rr = one("get_review_case", session_token=sam, case_id="TW-CASE-000043")
check("get_review_case (Luis, Retention): plan facts, no amount", rr["status"] == "OK" and "Unlimited Plus" in rr["facts"]
      and not rr["max_approvable"] and "No automatic action" in rr["if_approved"], rr)


# ---- decide: every reason code, then the parked actions ----
def decide(tok, case_id, dec="APPROVE", amt="", note="Checked the bill and the account history.", msg="Your request was reviewed."):
    return one("decide_review_case", session_token=tok, case_id=case_id, decision=dec, amount=amt, internal_note=note,
               customer_message=msg)


r = decide(grace, "TW-CASE-000041")
check("a customer token cannot decide (her own case) -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
r = decide(alex, PCASE)
check("another team's case -> BLOCKED NOT_YOUR_TEAM (no case details back)", r["outcome"] == "BLOCKED"
      and r["reason_code"] == "NOT_YOUR_TEAM" and not r["case_id"] and not r["case_status"], r)
r = decide(alex, "TW-CASE-999999")
check("unknown case -> BLOCKED NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = decide(alex, "TW-CASE-000041", note="ok")
check("note under 5 characters -> NOTE_REQUIRED", r["reason_code"] == "NOTE_REQUIRED", r)
r = decide(alex, "TW-CASE-000041", dec="MAYBE")
check("decision other than APPROVE/REJECT -> INVALID_DECISION", r["reason_code"] == "INVALID_DECISION", r)
r = decide(alex, "TW-CASE-000041", amt="80")
check("more than the $69.98 eligible -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(alex, "TW-CASE-000041", amt="-5")
check("negative amount -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(alex, "TW-CASE-000041")
check("full $69.98 above Alex's $60 limit -> OVER_AUTHORITY, case stays OPEN", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"], r)
check("blocked decisions wrote no decision, no action, no credit", n("SELECT count(*) n FROM review_decisions") == 0
      and n("SELECT count(*) n FROM case_actions") == 0 and n("SELECT count(*) n FROM unbilled_charges WHERE amount < 0") == 0)
r = decide(alex, "TW-CASE-000041", amt="$34.99", note="Duplicate VidMax line confirmed; credit one of the two.",
           msg="We found the duplicate VidMax Plus charge and credited $34.99 to your next bill.")
check("approve $34.99 (within the limit) -> APPROVED, executed bill credit", r["outcome"] == "APPROVED" and r["decision"] == "APPROVE"
      and r["approved_amount"] == "34.99" and "Bill credit TW-ADJ-" in (r["executed_action"] or "") and "$34.99" in r["executed_action"], r)
check("DB: case APPROVED $34.99 with the customer message; one decision row by TWS-7001",
      psql("SELECT status, approved_amount::text a, customer_message FROM service_cases WHERE case_id='TW-CASE-000041'")[0]
      == {"status": "APPROVED", "a": "34.99", "customer_message": "We found the duplicate VidMax Plus charge and credited $34.99 to your next bill."}
      and n("SELECT count(*) n FROM review_decisions WHERE case_id='TW-CASE-000041' AND reviewer_id='TWS-7001'") == 1)
check("DB: parked action executed - BILL_CREDIT case_actions row and a -$34.99 credit on Grace's next bill",
      n(f"SELECT count(*) n FROM case_actions WHERE case_id='TW-CASE-000041' AND kind='BILL_CREDIT' AND credit_amount=34.99 "
        f"AND bill_id={lit(g_bill)}") == 1
      and n("SELECT count(*) n FROM unbilled_charges WHERE customer_id='TW-C-0106' AND category='CREDIT' AND amount=-34.99") == 1)
check("DB: CASE_DECIDED (actor TWS-7001) and BILL_CREDITED audit rows",
      n("SELECT count(*) n FROM agent_audit WHERE action='CASE_DECIDED' AND ref='TW-CASE-000041' AND actor='TWS-7001' "
        "AND customer_id='TW-C-0106'") == 1 and n("SELECT count(*) n FROM agent_audit WHERE action='BILL_CREDITED'") == 1)
r = decide(morgan, "TW-CASE-000041", dec="REJECT")
check("a second decision (even by the senior reviewer) -> ALREADY_DECIDED, still one decision", r["reason_code"] == "ALREADY_DECIDED"
      and n("SELECT count(*) n FROM review_decisions WHERE case_id='TW-CASE-000041'") == 1, r)
check("the guarded action row refuses a second execution and an undecided case",
      n("SELECT count(*) n FROM case_action_row('TW-CASE-000041', 10)") == 0 and n(f"SELECT count(*) n FROM case_action_row({lit(MCASE)}, 10)") == 0)
r = decide(alex, MCASE, dec="REJECT", note="Roaming was used on a real trip; StarPlay was cancelled the same day.",
           msg="We reviewed your request. The roaming charges match your trip, so they stay on the bill.")
check("reject Maria's dispute -> REJECTED, nothing executed", r["outcome"] == "REJECTED" and "nothing was executed" in r["executed_action"]
      and n(f"SELECT count(*) n FROM case_actions WHERE case_id={lit(MCASE)}") == 0
      and n("SELECT count(*) n FROM unbilled_charges WHERE customer_id='TW-C-0101' AND amount < 0") == 0, r)
r = decide(jordan, PCASE, note="Network shows no days abroad; SIM swap done at a partner store without ID check.",
           msg="We reversed the SIM swap on your line and credited the $96.32 Canada roaming charges to your next bill.")
check("Fraud Team approves Priya's case in full -> APPROVED, SIM swap reversed + $96.32 credited",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "96.32" and "SIM swap reversed" in r["executed_action"]
      and "$96.32" in r["executed_action"], r)
check("DB: SIM_SWAP_REVERSAL executed - sim_swap_reversed_at set, -$96.32 credit, audit SIM_SWAP_REVERSED",
      val("SELECT (sim_swap_reversed_at IS NOT NULL)::text v FROM customers WHERE customer_id='TW-C-0103'") == "true"
      and n("SELECT count(*) n FROM unbilled_charges WHERE customer_id='TW-C-0103' AND category='CREDIT' AND amount=-96.32") == 1
      and n("SELECT count(*) n FROM agent_audit WHERE action='SIM_SWAP_REVERSED' AND customer_id='TW-C-0103'") == 1)
k = one("open_service_case", session_token=priya, request_type="billing_dispute", summary="Also refund the roaming.", brief="",
        reference="")
check("a credit is never paid twice: Priya's dispute on the same bill parks no further credit",
      k["outcome"] == "OPENED" and not k["requested_amount"] and caserow(k["case_id"])["parked_action"] == "", k)
r = decide(jordan, "TW-CASE-000042", note="Dana did not sign up; block premium content while the hold is reviewed.",
           msg="We blocked premium content on your line, cancelled Ringtone Vault and credited $6.99.")
check("Fraud Team approves Dana's seeded case -> PREMIUM_BLOCK executed: blocked, SUB-5001 cancelled, $6.99 credited",
      r["outcome"] == "APPROVED" and "Premium content blocked" in r["executed_action"]
      and val("SELECT premium_content_blocked::text v FROM customers WHERE customer_id='TW-C-0105'") == "true"
      and val("SELECT status v FROM content_subscriptions WHERE subscription_id='SUB-5001'") == "CANCELLED"
      and n("SELECT count(*) n FROM unbilled_charges WHERE customer_id='TW-C-0105' AND amount=-6.99") == 1, r)
r = decide(sam, "TW-CASE-000043", note="Moving abroad; cancellation at month end agreed, no fees.",
           msg="Your line will be cancelled at the end of this month as you asked.")
check("Retention approves Luis's cancellation -> APPROVED, no automatic action, no case_actions row",
      r["outcome"] == "APPROVED" and "no automatic action" in r["executed_action"]
      and n("SELECT count(*) n FROM case_actions WHERE case_id='TW-CASE-000043'") == 0, r)
check("audit: every decision has a CASE_DECIDED row with the reviewer as actor and the customer as subject",
      n("SELECT count(*) n FROM review_decisions") == 5
      and n("SELECT count(*) n FROM agent_audit WHERE action='CASE_DECIDED' AND actor LIKE 'TWS-%' AND customer_id IS NOT NULL") == 5)
check("audit: REVIEWER_VERIFY rows carry the reviewer id", n("SELECT count(*) n FROM agent_audit WHERE action='REVIEWER_VERIFY' "
                                                            "AND actor LIKE 'TWS-%'") == 4)

# ---- the customer sees the outcome (status + customer_message only) ----
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=grace)}
check("Grace sees her case APPROVED $34.99 with the reviewer's customer message (no note, no reviewer)",
      mc["TW-CASE-000041"]["case_status"] == "APPROVED" and mc["TW-CASE-000041"]["approved_amount"] == "34.99"
      and "credited $34.99" in mc["TW-CASE-000041"]["customer_message"] and mc["TW-CASE-000041"]["request"] == "billing dispute", mc)
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=maria)}
check("Maria sees her dispute REJECTED with the customer message", mc[MCASE]["case_status"] == "REJECTED"
      and "match your trip" in mc[MCASE]["customer_message"], mc)
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=priya)}
check("Priya sees fraud APPROVED, port-out still OPEN (no message yet)", mc[PCASE]["case_status"] == "APPROVED"
      and mc[RCASE]["case_status"] == "OPEN" and not mc[RCASE]["customer_message"], mc)
check("get_my_cases: bad token / reviewer token -> SESSION_INVALID",
      one("get_my_cases", session_token="bogus")["status"] == "SESSION_INVALID"
      and one("get_my_cases", session_token=alex)["status"] == "SESSION_INVALID")
e = one("email_action_confirmation", session_token=grace, reference="tw-case-000041")
check("email a decided case -> SEND_OK with the outcome and message (no note, no reviewer name)", e["send_status"] == "SEND_OK"
      and "TW-CASE-000041" in e["subject"] and "approved" in e["body"] and "credited $34.99" in e["body"]
      and "Duplicate VidMax line confirmed" not in e["body"] and "Alex" not in e["body"], e)
e = one("email_action_confirmation", session_token=priya, reference=RCASE)
check("email an undecided case -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
e = one("email_action_confirmation", session_token=james, reference="TW-CASE-000041")
check("SCOPE: James emails Grace's decided case -> NOT_FOUND", e["reason_code"] == "NOT_FOUND" and "VidMax" not in e["body"], e)
check("email_log: exactly one row, for Grace's decided case",
      psql("SELECT customer_id, reference FROM email_log") == [{"customer_id": "TW-C-0106", "reference": "TW-CASE-000041"}])

# ---- minimum necessary ----
rev_rows = [row for t, rows in OUTPUTS if t in REVIEWER_TOOLS for row in rows]
rev_cols = {k for row in rev_rows for k in row}
check("reviewer tool outputs: no mobile number, email, SSN, OTP, last name or customer id column",
      not (rev_cols & HIDDEN_FROM_REVIEWER), rev_cols & HIDDEN_FROM_REVIEWER)
rblob = "\n".join(str(v) for row in rev_rows for v in row.values())
pii = [x["v"] for x in psql("SELECT mobile_number v FROM customers UNION ALL SELECT email FROM customers "
                            "UNION ALL SELECT ssn FROM customers UNION ALL SELECT last_name FROM customers WHERE length(last_name) > 3 "
                            "UNION ALL SELECT customer_id FROM customers")]
check("reviewer tool outputs carry no mobile number, email, SSN, full last name or customer id",
      not any(p and p in rblob for p in pii), [p for p in pii if p and p in rblob][:3])
cblob = "\n".join(str(v) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for v in row.values())
secrets_r = [x["v"] for x in psql("SELECT internal_note AS v FROM review_decisions UNION ALL SELECT display_name FROM reviewers "
                                  "UNION ALL SELECT reviewer_id FROM reviewers")]
check("customer outputs never contain internal notes, reviewer names or staff ids", not any(s in cblob for s in secrets_r),
      [s for s in secrets_r if s in cblob][:3])

# ================================================================ A2A agent reference tools (PostgreSQL, read-only)
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))


def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()


check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["PlanRecommender", "ChargeClassifier", "BillExplainer"] and len(GUIDE_TOOLS) == 3)
ID_VALUES = [r["v"] for r in psql(
    "SELECT customer_id AS v FROM customers UNION SELECT first_name || ' ' || last_name FROM customers "
    "UNION SELECT last_name FROM customers UNION SELECT email FROM customers UNION SELECT mobile_number FROM customers "
    "UNION SELECT fmt_mobile(mobile_number) FROM customers UNION SELECT ssn FROM customers UNION SELECT otp_code FROM customers "
    "UNION SELECT bill_id FROM bills UNION SELECT subscription_id FROM content_subscriptions "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM service_cases UNION SELECT session_token FROM customer_sessions "
    "UNION SELECT proposal_id FROM pending_actions UNION SELECT reference FROM account_events")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 60, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_plan_guide": ("mexico", "TRAVELS_MEXICO_CANADA", "standard line", 1),
    "get_charge_taxonomy": ("sim swap", "RECENT_SIM_SWAP", "customer line", 5),
    "get_bill_glossary": ("megabyte", "PAY_PER_USE_ROAMING_DATA", "standard line", 1),
}
for t in GUIDE_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)}, about 20-30)", 15 <= len(full) <= 35, len(full))
    check(f"{tool}: returns only the reference columns {REF_COLUMNS}", bool(full) and list(full[0]) == REF_COLUMNS,
          list(full[0]) if full else None)
    check(f"{tool}: every section is present, in order",
          list(dict.fromkeys(r["section"] for r in full)) == t["sections"], list(dict.fromkeys(r["section"] for r in full)))
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
    check(f"{tool}: '%' and '_%_' are literal (the guide has no '%', so 0 rows; never a wildcard)",
          ref_call(t, "%") == [] and ref_call(t, "_%_") == [] and not any("%" in f"{r['term']} {r['meaning']}" for r in full))
    check(f"{tool}: SQL-looking input is just a string -> 0 rows, table intact",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) n FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no customer / bill / subscription / reviewer / case / session / proposal value in the rows",
          not leaked, leaked[:5])
    check(f"{tool}: no id, email, phone or token pattern",
          not re.search(r"tw-c-\d|twb-\d|tw-case|tw-act|tw-prp|tw-adj|tws-\d|sub-\d|@|\(?212\)?[ .-]?555|"
                        r"[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

# PlanRecommender: the plan rows are the plans table (one source of truth) + every reason code it can be shown
plan = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_plan_guide")
g = ref_call(plan, "")
codes = {r["v"] for r in psql("SELECT plan_code AS v FROM plans")}
check("ref_plan_guide: one PLAN row per plans row, read from plans (with price and included roaming)",
      {r["term"] for r in g if r["section"] == "PLAN"} == codes
      and any(r["term"] == "UNLPREM" and "$85 a month" in r["meaning"] and "Mexico & Canada included" in r["meaning"] for r in g))
psql("UPDATE plans SET plan_name = plan_name || ' (test)' WHERE plan_code = 'BASIC5'")
check("ref_plan_guide: a plans edit shows up in the guide (no copy)", "(test)" in ref_call(plan, "basic5")[0]["meaning"])
psql("UPDATE plans SET plan_name = replace(plan_name, ' (test)', '') WHERE plan_code = 'BASIC5'")
rc_codes = {"ARREARS", "LOCKED_IN", "CHANGE_PENDING", "NO_CHANGE", "INVALID_TARGET", "ACCOUNT_HOLD"}
fn_src = val("SELECT prosrc v FROM pg_proc WHERE proname = 'action_eval'")
check("ref_plan_guide: every CHANGE_PLAN reason code action_eval() can return is explained (REASON_CODE)",
      {r["term"] for r in g if r["section"] == "REASON_CODE"} == rc_codes and all(f"'{c}'" in fn_src for c in rc_codes))
check("ref_plan_guide: the eligible-plan columns the agent is sent are explained (COLUMN)",
      {"data_gb", "roaming_included", "change_type", "effective_date", "price_diff", "allowed"}
      <= {r["term"] for r in g if r["section"] == "COLUMN"})
check("ref_plan_guide: the standard closing line lives in the table",
      [r["meaning"] for r in ref_call(plan, "standard line")] ==
      ["Nothing has been changed yet: a plan change happens only after you say yes to the exact change Nova proposes."])
check("ref_plan_guide: the Mexico/Canada fit note matches the plan that includes that roaming",
      any(r["term"] == "TRAVELS_MEXICO_CANADA" and "Unlimited Premium" in r["meaning"] for r in g)
      and "Mexico" in val("SELECT roaming_included v FROM plans WHERE plan_name = 'Tidewell Unlimited Premium'"))

# ChargeClassifier: categories / next paths match what the orchestrator acts on; who decides comes from case_routing
chg = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_charge_taxonomy")
g = ref_call(chg, "")
cats = {r["term"] for r in g if r["section"] == "CATEGORY"}
paths = {r["term"] for r in g if r["section"] == "NEXT_PATH"}
check("ref_charge_taxonomy: the 8 categories and 5 next paths of the SPEC",
      cats == {"ROAMING", "PREMIUM_CONTENT", "DATA_OVERAGE", "DUPLICATE_CHARGE", "LATE_FEE", "SUSPECTED_FRAUD", "BILLING_ERROR", "UNCLEAR"}
      and paths == {"offer_cancel_subscription", "offer_roaming_options", "open_billing_dispute", "open_fraud_case", "explain_only"})
check("ref_charge_taxonomy: one CUSTOMER_LINE per next path", {r["term"] for r in g if r["section"] == "CUSTOMER_LINE"} == paths)
check("ref_charge_taxonomy: every SIGNAL names a category and a next path",
      all(any(c in r["meaning"] for c in cats) and any(p in r["meaning"] for p in paths) for r in g if r["section"] == "SIGNAL"))
wd = ref_call(chg, "who decides")
check("ref_charge_taxonomy: WHO_DECIDES comes from case_routing (Billing Disputes 5 days, Fraud Team 1 day)",
      len(wd) == 2 and any("Billing Disputes" in r["meaning"] and "5 business days" in r["meaning"] for r in wd)
      and any("Fraud Team" in r["meaning"] and "1 business day" in r["meaning"] for r in wd), wd)
psql("UPDATE case_routing SET label = label || ' (test)' WHERE request_type = 'suspected_fraud'")
check("ref_charge_taxonomy: a case_routing edit shows up in WHO_DECIDES (no copy)",
      any(r["term"].endswith("(test)") for r in ref_call(chg, "who decides")))
psql("UPDATE case_routing SET label = replace(label, ' (test)', '') WHERE request_type = 'suspected_fraud'")
check("ref_charge_taxonomy: the fraud customer line lives in the table",
      any(r["meaning"] == "Charges you did not make are checked by a person on our Fraud Team, who can reverse a SIM swap or block "
          "premium content." for r in ref_call(chg, "customer line")))
check("ref_charge_taxonomy: several words in one call ('days abroad, sim swap') -> both fraud signals",
      {"NO_DAYS_ABROAD", "RECENT_SIM_SWAP"} <= {r["term"] for r in ref_call(chg, "days abroad, sim swap")})

# BillExplainer: categories = the comparison buckets; rates match the seeded line descriptions
bill = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_bill_glossary")
g = ref_call(bill, "")
buckets = {r["v"] for r in psql("SELECT DISTINCT compare_bucket(c) AS v FROM unnest(ARRAY['PLAN','ROAMING','TRAVEL_PASS',"
                                "'PREMIUM_CONTENT','VOICE_SMS','TAXES_FEES','LATE_FEE','OTHER']) c")}
check("ref_bill_glossary: CATEGORY rows = the 6 comparison buckets of bill_comparison()",
      {r["term"] for r in g if r["section"] == "CATEGORY"} == buckets and len(buckets) == 6, buckets)
check("ref_bill_glossary: the pay-per-use rates match the seeded roaming line descriptions ($2.05/MB, $1.79/min)",
      any("$2.05 per MB" in r["meaning"] for r in g) and any("$1.79 per minute" in r["meaning"] for r in g)
      and n("SELECT count(*) n FROM bill_lines WHERE description LIKE '%@ $2.05/MB'") > 0
      and n("SELECT count(*) n FROM bill_lines WHERE description LIKE '%@ $1.79/min'") > 0)
check("ref_bill_glossary: the standard closing line lives in the table",
      [r["meaning"] for r in ref_call(bill, "standard line")] ==
      ["These amounts come straight from your last two bills; Nova can help stop a charge from repeating, and a person "
       "reviews any refund request."])

# nothing from the old static glossaries is lost: the facts each agent works from are in its table
KEEP = {"get_plan_guide": ["unlimited talk and text", "mexico and canada", "upgrade", "downgrade", "positive number costs more",
                           "past-due balance", "device installment", "already changed this bill cycle", "on hold",
                           "$10 for each day", "only on those days", "not offered"],
        "get_charge_taxonomy": ["days abroad on record", "premium content subscription", "beyond the plan's allowance",
                                "more than once", "after its due date", "right after a sim swap", "no sign of fraud",
                                "not enough information", "travelpass or a roaming spend limit", "refund, credit or waiver",
                                "fraud team investigates", "only wants explained", "billing disputes"],
        "get_bill_glossary": ["previous bill", "computed by tidewell's systems", "positive = higher now", "the monthly plan price",
                              "travelpass days", "calls and texts charged outside the plan", "taxes, surcharges and fees",
                              "late fees", "$2.05 per mb", "$1.79 per minute", "two bill totals"]}
for t in GUIDE_TOOLS:
    blob = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k.lower() not in blob]
    check(f"{t['tool']}: every fact the agent needs is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args, "
           "p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang JOIN pg_namespace ns ON ns.oid = p.pronamespace "
           "WHERE ns.nspname = 'public' AND p.proname LIKE 'ref\\_%'")
names = {f["proname"] for f in fns}
check("agent read functions: ref_match + one ref_* per agent", names == {"ref_match"} | {t["fn"] for t in GUIDE_TOOLS}, names)
for f in fns:
    check(f"{f['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          f["lanname"] == "sql" and f["provolatile"] in ("s", "i") and f["prosecdef"] == "f"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", f["prosrc"], re.I),
          {k: f[k] for k in ("lanname", "provolatile", "prosecdef")})
    if f["proname"] != "ref_match":
        check(f"{f['proname']}: one optional, non-identity argument", f["args"] == "p_term text", f["args"])

# ---------------------------------------------------------------- customer-facing wording
texts = [str(row.get(k) or "") for _, rows in OUTPUTS for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the customer|the model|LLM|the assistant|the user)\b", t, re.I)]
check("every reason_text / summary / sla_text addresses the customer (never the model)", not bad, bad[:3])
blob = "\n".join(str(v) for _, rows in OUTPUTS for row in rows for v in row.values())
check("no old-locale leftovers in tool output (Rand amounts / VAT / POPIA)", not re.search(r"\bR\d|VAT|POPIA", blob))

# ---------------------------------------------------------------- hidden columns never leave the DB
secrets = [x["v"] for x in psql("SELECT internal_notes v FROM customers UNION ALL SELECT ssn FROM customers "
                                 "UNION ALL SELECT email FROM customers")]
leaked_cols = sorted({k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row} & HIDDEN_COLUMNS)
check("no customer tool output has a hidden column", not leaked_cols, leaked_cols)
check("no tool output contains internal notes, SSN-like numbers or e-mail addresses",
      not any(s and s in blob for s in secrets) and "INTERNAL" not in blob and "risk" not in blob.lower())
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

reset()
total = passes + fails
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} checks, DB reset)")
sys.exit(1 if fails else 0)
