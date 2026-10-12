#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the mobile_billing DB and assert the
business rules on DB state. No Flogo needed. Re-loads reset_data.sql first and again at the end (re-runnable).

  python _rebuild/test_rules.py
Password: env PG_PWD, else PG_PASSWORD from the nearest skills-library/.claude/skills/config.md (never printed).
Env overrides: PSQL, PG_HOST, PG_PORT, PG_USER, PG_DB, CONFIG_MD.
"""
import csv, io, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS

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
    assert set(args) == {a for a, _ in t["args"]}, (tool, args)
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
check("13 MCP tools", len(TOOLS) == 13, [t["tool"] for t in TOOLS])
check("tool names unchanged", [t["tool"] for t in TOOLS] == [
    "verify_customer", "get_my_account", "get_my_bills", "get_bill_detail", "get_bill_comparison", "get_my_usage",
    "get_my_subscriptions", "get_my_payments", "get_eligible_plans", "propose_action", "confirm_action",
    "open_service_case", "email_action_confirmation"])
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
check("exactly 4 cases opened", n("SELECT count(*) n FROM service_cases") == 4)

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

# ---------------------------------------------------------------- customer-facing wording
texts = [str(row.get(k) or "") for _, rows in OUTPUTS for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the customer|the model|LLM|the assistant|the user)\b", t, re.I)]
check("every reason_text / summary / sla_text addresses the customer (never the model)", not bad, bad[:3])
blob = "\n".join(str(v) for _, rows in OUTPUTS for row in rows for v in row.values())
check("no old-locale leftovers in tool output (Rand amounts / VAT / POPIA)", not re.search(r"\bR\d|VAT|POPIA", blob))

# ---------------------------------------------------------------- hidden columns never leave the DB
secrets = [x["v"] for x in psql("SELECT internal_notes v FROM customers UNION ALL SELECT ssn FROM customers "
                                 "UNION ALL SELECT email FROM customers")]
leaked_cols = sorted({k for _, rows in OUTPUTS for row in rows for k in row} & HIDDEN_COLUMNS)
check("no tool output has a hidden column", not leaked_cols, leaked_cols)
check("no tool output contains internal notes, SSN-like numbers or e-mail addresses",
      not any(s and s in blob for s in secrets) and "INTERNAL" not in blob and "risk" not in blob.lower())
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

reset()
total = passes + fails
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} checks, DB reset)")
sys.exit(1 if fails else 0)
