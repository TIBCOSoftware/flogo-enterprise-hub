#!/usr/bin/env python3
"""Test ladder step 1: run the EXACT tool SQL from tool_spec.py against the semiconductor_governed DB and assert the
business rules on DB state - identity, scoped reads, the order and RMA two-step actions, expedites, alerts, cases and
the full reviewer loop, plus the A2A agents' read-only reference tools (ref_* functions: filtering, unknown
input, no personal data, SELECT-only). No Flogo needed. Re-loads reset_data.sql first and again at the end (re-runnable).

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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "semiconductor_governed"),
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


reset()
YEAR = val("SELECT to_char(current_date, 'YYYY') AS v")
SHIP = val("SELECT d(stock_ship_date()) AS v")

# ---------------------------------------------------------------- contract shape
check("21 MCP tools", len(TOOLS) == 21, [t["tool"] for t in TOOLS])
check("every write is INSERT ... SELECT (never VALUES)",
      all(re.match(r"INSERT INTO \w+ \([^)]*\) SELECT ", t["write"][0]) and "VALUES" not in t["write"][0].upper()
          for t in TOOLS if "write" in t))
check("write placeholders ?w_*, read placeholders never ?w_*",
      all(all(p.startswith("w_") for p, _ in t["write"][1]) for t in TOOLS if "write" in t)
      and all(not p.startswith("w_") for t in TOOLS for p, _ in t["read"][1]))
check("no ?p:: casts anywhere", not any(re.search(r"\?\w+::", t.get("write", ("",))[0] + t["read"][0]) for t in TOOLS))
check("reads are readonly, writes are not", all(t["readonly"] == ("write" not in t) for t in TOOLS))

# ---------------------------------------------------------------- buyer identity + throttle
TESSA_E = "tessa.brandt@northfieldpower.example.com"
r = one("verify_buyer", account_id="AC-10021", email=TESSA_E, code="0000")
check("wrong code -> VERIFY_FAILED, no token, no hint", r["outcome"] == "VERIFY_FAILED" and not r["session_token"]
      and "do not match" in r["reason_text"], r)
check("wrong code issues no session", n("SELECT count(*) FROM sessions") == 0)
r = one("verify_buyer", account_id="AC-99999", email=TESSA_E, code="4827")
check("unknown account -> VERIFY_FAILED (same text)", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_buyer", account_id="AC-10021", email="caleb.monroe@northfieldpower.example.com", code="4827")
check("Tessa's code with Caleb's e-mail -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
r = one("verify_buyer", account_id="AC-10047", email=TESSA_E, code="4827")
check("Tessa's e-mail + code on another account -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
toks = []
for fmt, em in (("AC-10021", TESSA_E), ("ac10021", TESSA_E.upper()), ("AC 10021", " " + TESSA_E), ("10021", TESSA_E)):
    r = one("verify_buyer", account_id=fmt, email=em, code="4827")
    check(f"account format '{fmt}' (e-mail case/space-insensitive) -> VERIFIED + token", r["outcome"] == "VERIFIED"
          and r["session_token"] and r["first_name"] == "Tessa" and r["company"] == "Northfield Power Systems", r)
    toks.append(r["session_token"])
tessa = toks[-1]
tok = lambda acct, em, code: one("verify_buyer", account_id=acct, email=em, code=code)["session_token"]
caleb = tok("AC-10021", "caleb.monroe@northfieldpower.example.com", "1950")
luis = tok("AC-10034", "luis.romero@bluegatemed.example.com", "6153")
hannah = tok("AC-10047", "hannah.cole@pinecrestauto.example.com", "3390")
check("Caleb, Luis and Hannah verify", all([caleb, luis, hannah]))
for i in range(5):
    one("verify_buyer", account_id="AC-10058", email="omar.haddad@redlinemotor.example.com", code="9999")
r = one("verify_buyer", account_id="AC-10058", email="omar.haddad@redlinemotor.example.com", code="7712")
check("THROTTLE: 5 wrong codes -> LOCKED even with the right code, no session", r["outcome"] == "LOCKED"
      and not r["session_token"] and n("SELECT count(*) FROM sessions WHERE buyer_id='B-5801'") == 0, r)
psql("DELETE FROM verify_attempts WHERE identifier = 'AC-10058'")      # the 15-minute window passes
omar = tok("AC-10058", "omar.haddad@redlinemotor.example.com", "7712")
check("after the window Omar verifies", bool(omar))

# ---------------------------------------------------------------- reviewer identity + role separation
r = one("verify_reviewer", staff_id="ACS-5101", code="0000")
check("reviewer wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r["session_token"], r)
r = one("verify_reviewer", staff_id="AC-10021", code="4827")
check("buyer credentials on verify_reviewer -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED", r)
r = one("verify_reviewer", staff_id="acs 5101", code="3141")
check("Rosa verifies as REVIEWER, Quality Engineering", r["outcome"] == "VERIFIED" and r["role"] == "REVIEWER"
      and r["team"] == "Quality Engineering" and r["display_name"] == "Rosa Delgado", r)
rosa = r["session_token"]
kenji = one("verify_reviewer", staff_id="5202", code="2718")["session_token"]
abigail = one("verify_reviewer", staff_id="ACS-5303", code="1618")["session_token"]
r = one("verify_reviewer", staff_id="ACS-5304", code="5772")
victor = r["session_token"]
check("Kenji, Abigail and Victor verify; Victor is Credit", all([kenji, abigail, victor]) and r["team"] == "Credit", r)
check("reviewer token on a buyer tool -> SESSION_INVALID", one("get_my_account", session_token=rosa)["status"] == "SESSION_INVALID")
check("buyer token on a reviewer tool -> NOT_REVIEWER", one("get_review_queue", session_token=tessa)["status"] == "NOT_REVIEWER")
for t in TOOLS:
    if t["tool"] in ("verify_buyer", "verify_reviewer"):
        continue
    args = {a: "x" for a, _ in t["args"]}
    args["session_token"] = "forged-token-0000"
    row = one(t["tool"], **args)
    code = row.get("reason_code") if t.get("email") else (row.get("status") or row.get("outcome"))
    want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
    check(f"forged token on {t['tool']} -> {want}", code == want, row)
check("forged-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") + n("SELECT count(*) FROM account_events")
      + n("SELECT count(*) FROM expedite_events") + n("SELECT count(*) FROM pcn_subscriptions WHERE account_id <> 'AC-10047'")
      + n("SELECT count(*) FROM review_decisions") + n("SELECT count(*) FROM email_log") == 0
      and n("SELECT count(*) FROM service_cases") == 3)

# ---------------------------------------------------------------- scoped reads
a = one("get_my_account", session_token=tessa)
check("Tessa account: Northfield, Good standing, limit $250,000, available $211,500, 2 open lines",
      a["status"] == "OK" and a["company"] == "Northfield Power Systems" and a["credit_status"] == "Good standing"
      and f2(a["credit_limit"]) == 250000 and f2(a["available_credit"]) == 211500 and a["open_order_lines"] == "2", a)
check("Luis account: ON CREDIT HOLD with the reason", one("get_my_account", session_token=luis)["credit_status"].startswith("ON CREDIT HOLD: Invoice"))
s = call("search_catalog", session_token=tessa, query="MOSFET 650V")
check("search 'MOSFET 650V' -> AW-MF-6508 + AW-MF-6515 only", sorted(x["part_number"] for x in s) == ["AW-MF-6508", "AW-MF-6515"], s)
check("search 'n-ch 650 v to-220' -> AW-MF-6508", [x["part_number"] for x in call("search_catalog", session_token=tessa, query="n-ch 650 v to-220")] == ["AW-MF-6508"])
check("search nonsense -> NO_MATCH", one("search_catalog", session_token=tessa, query="flux capacitor 1.21GW")["status"] == "NO_MATCH")
check("empty search lists the 17-part catalog", len(call("search_catalog", session_token=tessa, query="")) == 17)
p = one("get_part_details", session_token=tessa, part_number="aw sd 2010")
check("part details (normalised 'aw sd 2010'): EOL, LTB in 30 days, replacement AW-SD-2011, price table",
      p["status"] == "OK" and p["lifecycle"] == "EOL" and p["ltb_date"] == day(30) and p["replacement_part"] == "AW-SD-2011"
      and "100,000+: $0.12" in p["price_breaks"] and "Last-time-buy orders are accepted until" in p["lifecycle_note"], p)
check("part details unknown part -> NOT_FOUND", one("get_part_details", session_token=tessa, part_number="AW-ZZ-9999")["status"] == "NOT_FOUND")
ps = one("get_price_and_stock", session_token=tessa, part_number="AW-MF-4012", quantity="5,000")
check("price 5,000 x AW-MF-4012 = $0.81 (5,000+ tier) = $4,050.00, next break 25,000+ at $0.72, ships from stock",
      ps["status"] == "OK" and f2(ps["unit_price"]) == 0.81 and f2(ps["extended_price"]) == 4050 and ps["price_break"] == "5,000+ tier"
      and ps["next_break"] == "25,000+ at $0.72" and ps["in_stock_for_quantity"] == "yes" and ps["ship_date_if_ordered_today"] == SHIP, ps)
check("price 4,999 -> $0.96 tier", f2(one("get_price_and_stock", session_token=tessa, part_number="AW-MF-4012", quantity="4999")["unit_price"]) == 0.96)
check("price '5k' -> 5000 pcs", one("get_price_and_stock", session_token=tessa, part_number="AW-MF-4012", quantity="5k")["quantity"] == "5000")
check("price 'lots' -> INVALID_QUANTITY", one("get_price_and_stock", session_token=tessa, part_number="AW-MF-4012", quantity="lots")["status"] == "INVALID_QUANTITY")
x = call("get_cross_references", session_token=tessa, part_number="AW-MF-6508")
check("cross-refs AW-MF-6508: AW-MF-6515 HIGHER_RATED + AW-MF-6008 FUNCTIONAL_EQUIVALENT",
      {(r["alt_part"], r["relation"]) for r in x} == {("AW-MF-6515", "HIGHER_RATED"), ("AW-MF-6008", "FUNCTIONAL_EQUIVALENT")}, x)
check("cross-refs AW-GD-0450 -> NONE", one("get_cross_references", session_token=tessa, part_number="AW-GD-0450")["status"] == "NONE")
ln = {r["pcn_id"]: r for r in call("get_lifecycle_notices", session_token=hannah, part_number="")}
check("Hannah's notices (empty part): MC-3204 PCN + SD-2010 EOL, with her open lines and subscription",
      set(ln) == {"PCN-2026-0007", "PCN-2026-0004"} and "2,500 pcs promised" in ln["PCN-2026-0007"]["my_open_lines"]
      and ln["PCN-2026-0004"]["subscribed"] == "yes" and ln["PCN-2026-0007"]["subscribed"] == "no", ln)
check("Tessa's notices (empty part): only the MC-3204 PCN", [r["pcn_id"] for r in call("get_lifecycle_notices", session_token=tessa, part_number="")] == ["PCN-2026-0007"])
check("notices for one part (AW-SD-4030): the closed EOL", one("get_lifecycle_notices", session_token=tessa, part_number="AW-SD-4030")["pcn_id"] == "PCN-2026-0002")
o = call("get_my_orders", session_token=tessa)
check("Tessa's orders: 5 lines on SO-2026-0009/0011/0014; SO-2026-0014/2 OPEN promised +45; SO-2026-0011/1 SHIPPED with warranty date",
      len(o) == 5 and {r["order_number"] for r in o} == {"SO-2026-0009", "SO-2026-0011", "SO-2026-0014"}
      and any(r["line_ref"] == "SO-2026-0014/2" and r["line_status"] == "OPEN" and r["promised_date"] == day(45) for r in o)
      and any(r["line_ref"] == "SO-2026-0011/1" and r["line_status"] == "SHIPPED" and r["warranty_until"] for r in o), o)
check("SCOPE: Hannah's orders never include Tessa's", not any(r["order_number"] in ("SO-2026-0011", "SO-2026-0014") for r in call("get_my_orders", session_token=hannah)))
rm = one("get_my_rmas", session_token=luis)
check("Luis's RMAs: RMA-2026-0002 APPROVED with credit memo CM-000001 for $52.00", rm["rma_id"] == "RMA-2026-0002"
      and rm["rma_status"] == "APPROVED" and rm["credit_memo"] == "CM-000001 for $52.00", rm)
check("Tessa has no RMAs yet (NONE)", one("get_my_rmas", session_token=tessa)["status"] == "NONE")
check("Hannah's cases: the seeded RMA + special pricing, both OPEN", sorted(r["case_status"] + r["request"] for r in call("get_my_cases", session_token=hannah))
      == ["OPENRMA disposition", "OPENspecial pricing"])

# ---------------------------------------------------------------- order rules (each reason code)
def po(tk, part, qty, ponum="TEST-PO-1"):
    return one("propose_order", session_token=tk, part_number=part, quantity=qty, po_number=ponum)
for label, tk, part, qty, ponum, code in (
        ("unknown part", tessa, "AW-ZZ-9999", "100", "P1", "PART_NOT_FOUND"),
        ("quantity 'lots'", tessa, "AW-MF-4012", "lots", "P1", "INVALID_QUANTITY"),
        ("no PO number", tessa, "AW-MF-4012", "5000", "", "PO_REQUIRED"),
        ("obsolete part", tessa, "AW-LG-0208", "3000", "P1", "PART_OBSOLETE"),
        ("EOL part past its last-time-buy date", hannah, "AW-SD-4030", "5000", "P1", "PAST_LAST_TIME_BUY"),
        ("below MOQ (1,000 < 3,000)", tessa, "AW-SD-2011", "1000", "P1", "BELOW_MOQ"),
        ("more than stock (20,000 > 9,500)", tessa, "AW-MF-6515", "20000", "P1", "INSUFFICIENT_STOCK"),
        ("account on credit hold", luis, "AW-OP-2201", "1000", "P1", "CREDIT_HOLD"),
        ("over the credit limit ($72,000 > $59,000 available)", hannah, "AW-MF-4012", "100000", "P1", "OVER_CREDIT_LIMIT")):
    r = po(tk, part, qty, ponum)
    check(f"propose_order {label} -> BLOCKED {code}, no proposal_id", r["outcome"] == "BLOCKED" and r["reason_code"] == code
          and not r["proposal_id"] and r["reason_text"], r)
check("PAST_LAST_TIME_BUY text names the replacement AW-SD-4031", "AW-SD-4031" in po(hannah, "AW-SD-4030", "5000")["reason_text"])
LTB = po(hannah, "AW-SD-2010", "200,000", "PA-45100")
check("200,000 x EOL AW-SD-2010 = $24,000 > $10,000 -> BLOCKED LARGE_LAST_TIME_BUY WITH a proposal_id (case reference)",
      LTB["outcome"] == "BLOCKED" and LTB["reason_code"] == "LARGE_LAST_TIME_BUY" and LTB["proposal_id"].startswith("ARC-PRP-")
      and f2(LTB["extended"]) == 24000, LTB)
r = po(hannah, "AW-SD-2010", "30000", "PA-45101")
check("small last-time-buy ($3,900) -> PROPOSED with the non-cancellable note", r["outcome"] == "PROPOSED"
      and "non-cancellable" in r["summary"], r)
check("no order was created by any blocked proposal", n("SELECT count(*) FROM sales_orders WHERE source <> 'SEED'") == 0)

P = po(tessa, "AW-MF-4012", "5,000", "NPS-PO-8120")
check("Tessa 5,000 x AW-MF-4012 on NPS-PO-8120 -> PROPOSED $0.81 = $4,050.00, ships " + SHIP, P["outcome"] == "PROPOSED"
      and f2(P["unit_price"]) == 0.81 and f2(P["extended"]) == 4050 and P["ship_date"] == SHIP and "$4,050.00" in P["summary"]
      and "5,000+ price break" in P["summary"], P)
P2 = po(tessa, "aw-mf-4012", "5000", "nps-po-8120")
check("re-propose the same order (other spelling) -> same proposal, one pending row (idempotent)",
      P2["proposal_id"] == P["proposal_id"] and n("SELECT count(*) FROM pending_actions WHERE account_id='AC-10021' AND action_type='PLACE_ORDER' AND outcome='PROPOSED'") == 1, P2)
check("nothing ordered before confirm", n("SELECT count(*) FROM sales_orders WHERE account_id='AC-10021'") == 3)
r = one("confirm_action", session_token=hannah, proposal_id=P["proposal_id"])
check("SCOPE: Hannah confirms Tessa's proposal -> NOT_FOUND, nothing placed", r["outcome"] == "NOT_FOUND"
      and n("SELECT count(*) FROM account_events") == 0, r)
r = one("confirm_action", session_token=tessa, proposal_id=P["proposal_id"].lower())
SO1 = r["reference"]
check(f"confirm -> EXECUTED SO-{YEAR}-0101", r["outcome"] == "EXECUTED" and SO1 == f"SO-{YEAR}-0101", r)
check("DB: order + line (5,000 @ $0.81, promised ship date), stock 175,000, balance +$4,050, audit ORDER_PLACED",
      n(f"SELECT count(*) FROM sales_orders WHERE order_number='{SO1}' AND source='CHAT' AND po_number='NPS-PO-8120'") == 1
      and n(f"SELECT count(*) FROM order_lines WHERE order_number='{SO1}' AND quantity=5000 AND unit_price=0.81 AND promised_date=stock_ship_date()") == 1
      and n("SELECT qty_available FROM inventory WHERE part_number='AW-MF-4012'") == 175000
      and f2(val("SELECT open_balance AS v FROM accounts WHERE account_id='AC-10021'")) == 42550
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='ORDER_PLACED' AND subject_id='{SO1}' AND actor='B-2101'") == 1)
r = one("confirm_action", session_token=tessa, proposal_id=P["proposal_id"])
check("confirm twice -> ALREADY_DONE, still one order", r["outcome"] == "ALREADY_DONE" and SO1 in r["reason_text"]
      and n("SELECT count(*) FROM account_events") == 1, r)
check("confirm a bogus id -> NOT_FOUND", one("confirm_action", session_token=tessa, proposal_id="ARC-PRP-FFFFFFFF")["outcome"] == "NOT_FOUND")
blocked_id = val("SELECT proposal_id AS v FROM pending_actions WHERE account_id='AC-10034' AND reason_code='CREDIT_HOLD'")
r = one("confirm_action", session_token=luis, proposal_id=blocked_id)
check("confirm a BLOCKED proposal (credit hold) -> BLOCKED CREDIT_HOLD", r["outcome"] == "BLOCKED" and r["reason_code"] == "CREDIT_HOLD", r)
r = one("confirm_action", session_token=hannah, proposal_id=LTB["proposal_id"])
check("confirm the LARGE_LAST_TIME_BUY proposal -> BLOCKED (a person must approve it)", r["outcome"] == "BLOCKED"
      and r["reason_code"] == "LARGE_LAST_TIME_BUY", r)
E = po(tessa, "AW-TV-0524", "3000", "NPS-PO-8121")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE proposal_id = {lit(E['proposal_id'])}")
r = one("confirm_action", session_token=tessa, proposal_id=E["proposal_id"])
check("confirm after 15 minutes -> EXPIRED, nothing placed", r["outcome"] == "EXPIRED" and n("SELECT count(*) FROM account_events") == 1, r)
R = po(tessa, "AW-MF-6515", "9500", "NPS-PO-8122")
check("9,500 x AW-MF-6515 (all the stock) -> PROPOSED", R["outcome"] == "PROPOSED", R)
psql("UPDATE inventory SET qty_available = 9000 WHERE part_number = 'AW-MF-6515'")     # stock sold meanwhile
r = one("confirm_action", session_token=tessa, proposal_id=R["proposal_id"])
check("RE-CHECK: stock fell to 9,000 before confirm -> BLOCKED INSUFFICIENT_STOCK", r["outcome"] == "BLOCKED"
      and r["reason_code"] == "INSUFFICIENT_STOCK", r)
psql("UPDATE inventory SET qty_available = 9500 WHERE part_number = 'AW-MF-6515'")

# ---------------------------------------------------------------- RMA rules (each reason code) + two-step
def pr(tk, order, part, qty, defect="ELECTRICAL_FAILURE", safety="YES", desc="Units fail after a few weeks in the field.", brief=""):
    return one("propose_rma", session_token=tk, order_number=order, part_number=part, quantity=qty, failure_description=desc,
               defect_type=defect, safety_relevant=safety, triage_brief=brief)
for label, tk, order, part, qty, code in (
        ("another account's order", hannah, "SO-2026-0011", "AW-MF-6508", "40", "NOT_FOUND"),
        ("a part not on the order", tessa, "SO-2026-0011", "AW-VR-3350", "40", "NOT_FOUND"),
        ("an unshipped line", tessa, "SO-2026-0014", "AW-GD-0450", "10", "NOT_SHIPPED"),
        ("quantity 'some'", tessa, "SO-2026-0011", "AW-MF-6508", "some", "INVALID_QUANTITY"),
        ("more than shipped (2,500 > 2,000)", tessa, "SO-2026-0011", "AW-MF-6508", "2500", "QTY_EXCEEDS_SHIPPED"),
        ("parts shipped 14 months ago (12-month warranty)", tessa, "SO-2026-0009", "AW-VR-3350", "10", "OUT_OF_WARRANTY")):
    r = pr(tk, order, part, qty)
    check(f"propose_rma {label} -> BLOCKED {code}", r["outcome"] == "BLOCKED" and r["reason_code"] == code and not r["proposal_id"], r)
BRIEF = "defect_type: ELECTRICAL_FAILURE; safety_relevant: YES; rationale: gate-source short after field hours in a PV inverter."
RP = pr(tessa, "so-2026-0011", "AW-MF-6508", "40", "electrical", "yes",
        "About 40 of the 650 V MOSFETs from this order died in our solar inverters after a few weeks; the gate is shorted.", BRIEF)
check("Tessa RMA 40 x AW-MF-6508 -> PROPOSED: ELECTRICAL_FAILURE (normalised), safety yes, up to $54.40, 1 business day",
      RP["outcome"] == "PROPOSED" and "ELECTRICAL_FAILURE" in RP["summary"] and "safety-relevant: yes" in RP["summary"]
      and "$54.40" in RP["summary"] and "within 1 business day" in RP["summary"], RP)
r = pr(tessa, "SO-2026-0011", "AW-GD-0450", "10", "banana", "maybe")
check("unknown defect type -> OTHER, unclear safety -> no (SQL, not the agent, sets the class)", r["outcome"] == "PROPOSED"
      and "classified as OTHER" in r["summary"] and "safety-relevant: no" in r["summary"], r)
check("nothing opened before confirm", n("SELECT count(*) FROM rmas WHERE source='CHAT'") == 0)
r = one("confirm_action", session_token=tessa, proposal_id=RP["proposal_id"])
RMA1, RCASE = r["reference"], r["case_id"]
check(f"confirm -> EXECUTED RMA-{YEAR}-0101 + Quality Engineering case ARC-CASE-000101 due in 1 business day",
      r["outcome"] == "EXECUTED" and RMA1 == f"RMA-{YEAR}-0101" and RCASE == "ARC-CASE-000101" and r["team"] == "Quality Engineering"
      and r["reply_due"] == val("SELECT d(add_business_days(current_date, 1)) AS v"), r)
check("DB: RMA UNDER_REVIEW; case SAFETY priority, requested $54.40, parked RMA_CREDIT, brief carries the triage; audits",
      n(f"SELECT count(*) FROM rmas WHERE rma_id='{RMA1}' AND status='UNDER_REVIEW' AND quantity=40 AND safety_relevant") == 1
      and n(f"SELECT count(*) FROM service_cases WHERE case_id='{RCASE}' AND priority='SAFETY' AND requested_amount=54.40 "
            f"AND parked_action='RMA_CREDIT:{RMA1}' AND agent_brief LIKE '%gate-source short%'") == 1
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type IN ('RMA_OPENED','CASE_OPENED') AND actor='B-2101'") == 2)
r = pr(tessa, "SO-2026-0011", "AW-MF-6508", "1970")
check("after the RMA, at most 1,960 more can be returned -> QTY_EXCEEDS_SHIPPED", r["reason_code"] == "QTY_EXCEEDS_SHIPPED"
      and "1,960" in r["reason_text"], r)
check("Tessa sees her RMA UNDER_REVIEW with an open case", (lambda x: x["rma_id"] == RMA1 and x["rma_status"] == "UNDER_REVIEW"
      and x["case_status"] == "OPEN")(one("get_my_rmas", session_token=tessa)))

# ---------------------------------------------------------------- expedite
def ex(tk, line, date):
    return one("request_expedite", session_token=tk, line_ref=line, new_date=date)
r = ex(tessa, "SO-2026-0014/1", day(7))
check("pull in SO-2026-0014/1 (in stock) to +7 -> EXPEDITED EXP-000101, promised date moved", r["outcome"] == "EXPEDITED"
      and r["reference"] == "EXP-000101" and r["new_promised_date"] == day(7) and r["previous_promised_date"] == day(21)
      and val("SELECT d(promised_date) AS v FROM order_lines WHERE order_number='SO-2026-0014' AND line_no=1") == day(7), r)
r = ex(tessa, "so-2026-0014 line 1", day(5))
check("line ref 'so-2026-0014 line 1' works; +5 -> EXPEDITED", r["outcome"] == "EXPEDITED" and r["new_promised_date"] == day(5), r)
r = ex(tessa, "SO-2026-0014/1", day(30))
check("a later date -> BLOCKED NOT_EARLIER", r["reason_code"] == "NOT_EARLIER", r)
r = ex(tessa, "SO-2026-0014/1", "next week")
check("not a date -> BLOCKED INVALID_DATE", r["reason_code"] == "INVALID_DATE", r)
r = ex(tessa, "SO-2026-0014/1", day(-1))
check("a past date -> BLOCKED INVALID_DATE", r["reason_code"] == "INVALID_DATE", r)
r = ex(tessa, "SO-2026-0014/2", day(14))
check("AW-MC-3204 (no stock, receipt in 30 days) to +14 -> BLOCKED FACTORY_EXPEDITE_REQUIRED with the earliest date",
      r["reason_code"] == "FACTORY_EXPEDITE_REQUIRED" and r["earliest_without_factory_expedite"] == val("SELECT d(add_business_days(current_date + 30, 1)) AS v")
      and val("SELECT d(promised_date) AS v FROM order_lines WHERE order_number='SO-2026-0014' AND line_no=2") == day(45), r)
r = ex(tessa, "SO-2026-0011/1", day(3))
check("a shipped line -> BLOCKED ALREADY_SHIPPED", r["reason_code"] == "ALREADY_SHIPPED", r)
r = ex(hannah, "SO-2026-0014/1", day(4))
check("SCOPE: Hannah expedites Tessa's line -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
check("an order with one open line needs no line number", val("SELECT find_line('AC-10058', 'SO-2026-0013') IS NOT NULL AS v") == "t")
check("DB: exactly 2 expedite events, both BUYER", n("SELECT count(*) FROM expedite_events WHERE source='BUYER'") == 2
      and n("SELECT count(*) FROM expedite_events") == 2)

# ---------------------------------------------------------------- change-notice alerts
r = one("subscribe_pcn_alerts", session_token=tessa, part_number="AW-MF-6508")
check("subscribe AW-MF-6508 -> SUBSCRIBED", r["outcome"] == "SUBSCRIBED" and r["notices_on_file"] == "0", r)
r = one("subscribe_pcn_alerts", session_token=tessa, part_number="aw-mf-6508")
check("subscribe again -> ALREADY_SUBSCRIBED, one row", r["outcome"] == "ALREADY_SUBSCRIBED"
      and n("SELECT count(*) FROM pcn_subscriptions WHERE account_id='AC-10021'") == 1, r)
check("Caleb (same account) -> ALREADY_SUBSCRIBED (dedupe per account)",
      one("subscribe_pcn_alerts", session_token=caleb, part_number="AW-MF-6508")["outcome"] == "ALREADY_SUBSCRIBED")
check("unknown part -> PART_NOT_FOUND", one("subscribe_pcn_alerts", session_token=tessa, part_number="AW-ZZ-0000")["outcome"] == "PART_NOT_FOUND")
check("get_my_account lists the alert", one("get_my_account", session_token=tessa)["pcn_alerts"] == "AW-MF-6508")

# ---------------------------------------------------------------- human-owned cases
def oc(tk, rtype, ref="", date="", amount="", summary="Please review."):
    return one("open_service_case", session_token=tk, request_type=rtype, summary=summary, reference_id=ref, requested_date=date, amount=amount)
check("unknown request type -> INVALID_TYPE", oc(tessa, "refund")["outcome"] == "INVALID_TYPE")
check("rma_disposition is not buyer-openable -> INVALID_TYPE", oc(tessa, "rma_disposition", RMA1)["outcome"] == "INVALID_TYPE")
k = oc(hannah, "last_time_buy", LTB["proposal_id"], summary="Last-time buy of 200,000 AW-SD-2010 before the EOL date, PO PA-45100.")
LCASE = k["case_id"]
check("Hannah last_time_buy with her LARGE_LAST_TIME_BUY proposal -> OPENED, Sales & Pricing, 200,000 pcs ($24,000.00)",
      k["outcome"] == "OPENED" and k["team"] == "Sales & Pricing" and "200,000 pcs of AW-SD-2010" in k["requested"]
      and "$24,000.00" in k["requested"], k)
check("same request again -> EXISTING", oc(hannah, "last_time_buy", LTB["proposal_id"])["outcome"] == "EXISTING")
r = oc(tessa, "last_time_buy", P["proposal_id"])
check("last_time_buy with a normal (confirmable) proposal -> NOT_ELIGIBLE", r["reason_code"] == "NOT_ELIGIBLE", r)
check("last_time_buy with another account's proposal -> NOT_FOUND", oc(tessa, "last_time_buy", LTB["proposal_id"])["reason_code"] == "NOT_FOUND")
k = oc(tessa, "factory_expedite", "SO-2026-0014/2", day(14), summary="Need the 500 AW-MC-3204 two weeks from now for a pilot build.")
FCASE = k["case_id"]
check("Tessa factory_expedite SO-2026-0014/2 by +14 -> OPENED, Sales & Pricing", k["outcome"] == "OPENED"
      and k["team"] == "Sales & Pricing" and day(14) in k["requested"], k)
r = oc(tessa, "factory_expedite", "SO-2026-0014/1", day(4))
check("factory_expedite for a date stock can meet -> NOT_ELIGIBLE (pull it in directly)", r["reason_code"] == "NOT_ELIGIBLE"
      and "directly" in r["reason_text"], r)
check("factory_expedite on another account's line -> NOT_FOUND", oc(hannah, "factory_expedite", "SO-2026-0014/2", day(14))["reason_code"] == "NOT_FOUND")
k = oc(luis, "credit_review", summary="Please release our credit hold; the overdue invoice is being paid this week.")
LUCASE = k["case_id"]
check("Luis credit_review (hold release, empty amount) -> OPENED, Credit, at the current $60,000 limit", k["outcome"] == "OPENED"
      and k["team"] == "Credit" and "$60,000.00" in k["requested"], k)
check("Omar credit_review -> EXISTING (seeded case)", oc(omar, "credit_review", amount="90000")["outcome"] == "EXISTING")
check("credit_review for $2,000,000 -> AMOUNT_INVALID", oc(tessa, "credit_review", amount="$2,000,000")["reason_code"] == "AMOUNT_INVALID")
k = oc(tessa, "special_pricing", "AW-MF-6508", summary="Asks for a better price on 20,000 AW-MF-6508 a year.")
SCASE = k["case_id"]
check("Tessa special_pricing AW-MF-6508 -> OPENED", k["outcome"] == "OPENED" and k["team"] == "Sales & Pricing", k)
check("special_pricing for an unknown part -> NOT_FOUND", oc(tessa, "special_pricing", "AW-ZZ-1111")["reason_code"] == "NOT_FOUND")
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=tessa)}
check("Tessa's cases: RMA disposition + factory expedite + special pricing, all OPEN with the team text",
      set(mc) == {RCASE, FCASE, SCASE} and all(x["case_status"] == "OPEN" and "will decide" in x["customer_message"] for x in mc.values()), mc)

# ---------------------------------------------------------------- reviewer loop
q = call("get_review_queue", session_token=rosa)
check("Rosa's queue (Quality Engineering): the SAFETY RMA case first, then the seeded one; no other team's cases",
      [x["case_id"] for x in q] == [RCASE, "ARC-CASE-000001"] and q[0]["priority"] == "SAFETY"
      and q[0]["customer"] == "Northfield Power Systems (buyer Tessa B.)", q)
kq = {x["case_id"] for x in call("get_review_queue", session_token=kenji)}
check("Kenji's queue (Sales & Pricing): LTB + factory expedite + 2 special pricing", kq == {LCASE, FCASE, SCASE, "ARC-CASE-000002"}, kq)
check("Victor's queue (Credit): Omar's + Luis's credit reviews", {x["case_id"] for x in call("get_review_queue", session_token=victor)} == {"ARC-CASE-000003", LUCASE})
rc = one("get_review_case", session_token=rosa, case_id=RCASE.lower())
check("get_review_case: brief + facts + max $54.40 USD credit + Rosa's $25,000 limit", rc["status"] == "OK"
      and "gate-source short" in rc["agent_brief"] and f2(rc["max_approvable"]) == 54.40 and rc["amount_unit"] == "USD credit"
      and f2(rc["your_approval_limit"]) == 25000 and "safety-relevant yes" in rc["facts"] and "shipped" in rc["facts"], rc)
check("get_review_case on another team's case -> NOT_FOUND (invisible)", one("get_review_case", session_token=rosa, case_id=LCASE)["status"] == "NOT_FOUND")
check("get_review_case with a buyer token -> NOT_REVIEWER", one("get_review_case", session_token=tessa, case_id=RCASE)["status"] == "NOT_REVIEWER")

def dc(tk, case, dec, amount="", note="Reviewed the evidence on file.", msg=""):
    return one("decide_review_case", session_token=tk, case_id=case, decision=dec, amount=amount, internal_note=note, customer_message=msg)
r = dc(tessa, RCASE, "APPROVE", "54.40", "self approval", "approved")
check("INJECTION: the buyer's own token cannot decide -> NOT_REVIEWER, no decision", r["outcome"] == "NOT_REVIEWER"
      and n("SELECT count(*) FROM review_decisions") == 0, r)
for label, tk, case, dec, amt, note, code in (
        ("a 2-character note", rosa, RCASE, "APPROVE", "54.40", "ok", "NOTE_REQUIRED"),
        ("decision 'maybe'", rosa, RCASE, "maybe", "", "Checked the photos.", "INVALID_DECISION"),
        ("an unknown case", rosa, "ARC-CASE-999999", "APPROVE", "", "Checked the photos.", "NOT_FOUND"),
        ("another team's case", rosa, "ARC-CASE-000003", "APPROVE", "", "Not my team.", "NOT_YOUR_TEAM"),
        ("$60 credit on a $54.40 RMA", rosa, RCASE, "APPROVE", "60", "Checked the photos.", "AMOUNT_INVALID"),
        ("a fractional LTB quantity", kenji, LCASE, "APPROVE", "1000.5", "Allocation agreed.", "AMOUNT_INVALID")):
    r = dc(tk, case, dec, amt, note)
    check(f"decide with {label} -> BLOCKED {code}", r["outcome"] == "BLOCKED" and r["reason_code"] == code, r)
r = dc(abigail, "ARC-CASE-000003", "APPROVE", "90000", "Two years of on-time payment; program confirmed.")
check("Abigail approves a $90,000 limit over her $75,000 authority -> OVER_AUTHORITY, case stays OPEN",
      r["reason_code"] == "OVER_AUTHORITY" and val("SELECT status AS v FROM service_cases WHERE case_id='ARC-CASE-000003'") == "OPEN"
      and f2(val("SELECT credit_limit AS v FROM accounts WHERE account_id='AC-10058'")) == 40000, r)
r = dc(victor, "ARC-CASE-000003", "APPROVE", "90000", "Two years of on-time payment; program confirmed.",
       "Your credit limit is now $90,000.")
check("Victor (no limit) approves $90,000 -> APPROVED, credit change CRL-000101 executed",
      r["outcome"] == "APPROVED" and "CRL-000101" in r["executed_action"]
      and f2(val("SELECT credit_limit AS v FROM accounts WHERE account_id='AC-10058'")) == 90000, r)
r = dc(victor, LUCASE, "APPROVE", "", "Payment for INV-55120 received today.", "Your credit hold is released.")
check("Victor releases Luis's credit hold (full requested = current limit) -> hold off, Luis can order again",
      r["outcome"] == "APPROVED" and val("SELECT credit_hold::text AS v FROM accounts WHERE account_id='AC-10034'") == "false"
      and po(luis, "AW-OP-2201", "1000", "BMD-2290")["outcome"] == "PROPOSED", r)
MSG = "Your RMA is approved. A credit of $54.40 has been issued to your account; please scrap the parts."
NOTE = "Failure analysis matches gate oxide damage from the reported lot; full credit."
r = dc(rosa, RCASE, "APPROVE", "54.40", NOTE, MSG)
check("Rosa approves the RMA for $54.40 -> APPROVED, credit memo CM-000101", r["outcome"] == "APPROVED"
      and "CM-000101" in r["executed_action"] and r["customer_message"] == MSG, r)
check("DB: decision row, RMA APPROVED with credit, memo $54.40, balance -$54.40, CASE_DECIDED audit by Rosa",
      n(f"SELECT count(*) FROM review_decisions WHERE case_id='{RCASE}' AND reviewer_id='ACS-5101' AND decision='APPROVE' AND approved_amount=54.40") == 1
      and n(f"SELECT count(*) FROM rmas WHERE rma_id='{RMA1}' AND status='APPROVED' AND credit_amount=54.40") == 1
      and n(f"SELECT count(*) FROM credit_memos WHERE rma_id='{RMA1}' AND amount=54.40 AND case_id='{RCASE}'") == 1
      and f2(val("SELECT open_balance AS v FROM accounts WHERE account_id='AC-10021'")) == round(42550 - 54.40, 2)
      and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{RCASE}' AND actor='ACS-5101'") == 1)
check("second decision -> ALREADY_DECIDED", dc(rosa, RCASE, "REJECT")["reason_code"] == "ALREADY_DECIDED")
r = dc(rosa, "ARC-CASE-000001", "REJECT", "", "Oscillation reproduced only with the customer's output capacitor; parts in spec.",
       "Our tests show the regulators meet specification; please check the output capacitor against the datasheet.")
check("Rosa rejects the seeded RMA -> REJECTED, RMA REJECTED, no credit memo", r["outcome"] == "REJECTED"
      and val("SELECT status AS v FROM rmas WHERE rma_id='RMA-2026-0003'") == "REJECTED"
      and n("SELECT count(*) FROM credit_memos WHERE rma_id='RMA-2026-0003'") == 0, r)
psql("UPDATE accounts SET credit_hold = TRUE, hold_reason = 'test' WHERE account_id = 'AC-10047'")
r = dc(kenji, LCASE, "APPROVE", "150000", "Allocation agreed with the factory.")
check("approval re-checks the parked order: account on hold -> ACTION_BLOCKED, case OPEN, no order", r["reason_code"] == "ACTION_BLOCKED"
      and val(f"SELECT status AS v FROM service_cases WHERE case_id='{LCASE}'") == "OPEN"
      and n(f"SELECT count(*) FROM account_events WHERE case_id='{LCASE}'") == 0, r)
psql("UPDATE accounts SET credit_hold = FALSE, hold_reason = NULL WHERE account_id = 'AC-10047'")
r = dc(kenji, LCASE, "APPROVE", "150000", "Allocation agreed with the factory; 150k covers the forecast.",
       "Approved for 150,000 pieces; order placed.")
SO2 = val(f"SELECT reference AS v FROM account_events WHERE case_id='{LCASE}'")
check("Kenji approves 150,000 of 200,000 -> APPROVED; LTB order placed at the 100,000+ price ($18,000.00)",
      r["outcome"] == "APPROVED" and SO2 and SO2 in r["executed_action"] and "$18,000.00" in r["executed_action"]
      and n(f"SELECT count(*) FROM order_lines WHERE order_number='{SO2}' AND quantity=150000 AND unit_price=0.12") == 1
      and n(f"SELECT count(*) FROM sales_orders WHERE order_number='{SO2}' AND source='REVIEW' AND po_number='PA-45100'") == 1, r)
r = dc(kenji, FCASE, "APPROVE", "", "Factory confirmed a priority wafer lot.", "The factory can meet your date.")
check("Kenji approves the factory expedite -> line promised date moved to +14 (REVIEWER expedite event)",
      r["outcome"] == "APPROVED" and "EXP-" in r["executed_action"]
      and val("SELECT d(promised_date) AS v FROM order_lines WHERE order_number='SO-2026-0014' AND line_no=2") == day(14)
      and n(f"SELECT count(*) FROM expedite_events WHERE case_id='{FCASE}' AND source='REVIEWER'") == 1, r)
r = dc(kenji, SCASE, "REJECT", "", "Volume below the special-pricing threshold.", "We cannot offer a lower price at this volume.")
check("Kenji rejects special pricing -> REJECTED, nothing executed", r["outcome"] == "REJECTED"
      and r["executed_action"] == "Case rejected; nothing was executed.", r)
mc = {x["case_id"]: x for x in call("get_my_cases", session_token=tessa)}
check("Tessa sees the outcomes: RMA APPROVED ($54.40 credit) with the team's message, expedite APPROVED, pricing REJECTED",
      mc[RCASE]["case_status"] == "APPROVED" and mc[RCASE]["customer_message"] == MSG and "$54.40 credit" in mc[RCASE]["outcome"]
      and mc[FCASE]["case_status"] == "APPROVED" and mc[SCASE]["case_status"] == "REJECTED", mc)
rm = one("get_my_rmas", session_token=tessa)
check("Tessa's RMA shows APPROVED with credit memo CM-000101", rm["rma_status"] == "APPROVED" and rm["credit_memo"] == "CM-000101 for $54.40", rm)
check("Hannah sees the last-time-buy approved and the new order", any(x["case_id"] == LCASE and x["case_status"] == "APPROVED"
      for x in call("get_my_cases", session_token=hannah)) and any(x["order_number"] == SO2 for x in call("get_my_orders", session_token=hannah)))

# ---------------------------------------------------------------- guarded email
e = one("email_confirmation", session_token=tessa, reference=SO1)
check("email own order -> SEND_OK with the SQL-built body", e["send_status"] == "SEND_OK" and SO1 in e["subject"]
      and "$4,050.00" in e["body"] and "Arc, the Arcwell Components AI assistant" in e["body"], e)
e = one("email_confirmation", session_token=tessa, reference=RCASE)
check("email own decided case -> SEND_OK with the customer message, never the internal note",
      e["send_status"] == "SEND_OK" and MSG in e["body"] and NOTE not in e["body"], e)
check("email own RMA and expedite -> SEND_OK", one("email_confirmation", session_token=tessa, reference=RMA1)["send_status"] == "SEND_OK"
      and one("email_confirmation", session_token=tessa, reference="EXP-000101")["send_status"] == "SEND_OK")
e = one("email_confirmation", session_token=hannah, reference=SO1)
check("SCOPE: Hannah emails Tessa's order -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NOT_FOUND", e)
check("email an undecided case -> NOT_FOUND", one("email_confirmation", session_token=hannah, reference="ARC-CASE-000002")["reason_code"] == "NOT_FOUND")
check("exactly 4 emails logged, all Tessa's", n("SELECT count(*) FROM email_log") == 4 and n("SELECT count(*) FROM email_log WHERE account_id='AC-10021'") == 4)

# ---------------------------------------------------------------- session expiry
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(tessa)}")
check("expired buyer token -> SESSION_INVALID", one("get_my_account", session_token=tessa)["status"] == "SESSION_INVALID")
check("expired token cannot propose", po(tessa, "AW-MF-4012", "5000", "X")["outcome"] == "SESSION_INVALID")
psql(f"UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(kenji)}")
check("expired reviewer token -> NOT_REVIEWER", one("get_review_queue", session_token=kenji)["status"] == "NOT_REVIEWER")

# ---------------------------------------------------------------- hidden data never leaves the DB
buy_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
leaked = sorted({k for _, rows in buy_out for row in rows for k in row} & HIDDEN_COLUMNS)
check("no buyer tool output has a hidden column", not leaked, leaked)
bblob = "\n".join(str(v) for _, rows in buy_out for row in rows for v in row.values())
secrets = [x["v"] for x in psql("SELECT email v FROM buyers UNION ALL SELECT internal_note FROM review_decisions "
                                "UNION ALL SELECT display_name FROM reviewers UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL")]
check("buyer outputs never contain buyer e-mails, internal notes, reviewer names or agent briefs",
      not any(s and s in bblob for s in secrets), [s for s in secrets if s and s in bblob][:3])
rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
rblob = "\n".join(str(v) for _, rows in rev_out for row in rows for v in row.values())
check("reviewer outputs: no buyer e-mail, code or full last name", not rleak and not re.search(r"@\w+\.example\.com|Brandt|Romero|Haddad", rblob),
      (rleak, rblob[:200]))
texts = [str(row.get(k) or "") for _, rows in buy_out for row in rows for k in ("reason_text", "summary", "sla_text")]
bad = [t for t in texts if re.search(r"\b(the buyer|the model|LLM|the assistant|the user)\b", t, re.I)]
check("buyer-facing texts address the buyer (never the model)", not bad, bad[:3])
check("every tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# Each A2A agent's one tool runs SELECT * FROM ref_<topic>(CAST(?lookup AS text)) - reference data only.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

ID_VALUES = [r["v"] for r in psql(
    "SELECT account_id AS v FROM accounts UNION SELECT company FROM accounts UNION SELECT hold_reason FROM accounts "
    "UNION SELECT buyer_id FROM buyers UNION SELECT first_name || ' ' || last_name FROM buyers UNION SELECT last_name FROM buyers "
    "UNION SELECT email FROM buyers UNION SELECT otp_code FROM buyers "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM service_cases UNION SELECT summary FROM service_cases UNION SELECT rma_id FROM rmas "
    "UNION SELECT description FROM rmas UNION SELECT order_number FROM sales_orders UNION SELECT po_number FROM sales_orders "
    "UNION SELECT session_token::text FROM sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 30, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_part_selection_guide": ("footprint", "2 footprint", "note line", 3),
    "get_defect_taxonomy": ("scorching", "heat, smoke or fire", "safety sign", 6),
    "get_pcn_glossary": ("dry pack", "MSL", "line status", 3),
}
check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["part_finder_agent", "rma_triage_agent", "pcn_impact_agent"])
for t in AGENT_REF_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)}, about 20-30)", 15 <= len(full) <= 32, len(full))
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
    pct = ref_call(t, "%")      # '%' is matched literally (only rows that contain '%'), never as a wildcard
    check(f"{tool}: '%' and '_' are literal (no wildcard expansion)",
          len(pct) < len(full) and all("%" in f"{r['term']} {r['meaning']}" for r in pct) and ref_call(t, "_%_") == [],
          [r["term"] for r in pct])
    check(f"{tool}: SQL-looking input is just a string -> 0 rows",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no account / buyer / reviewer / case / RMA / order / PO / session value in the reference rows",
          not leaked, leaked[:5])
    check(f"{tool}: no account number, staff id, case / RMA / order id, email or token pattern",
          not re.search(r"\bac-\d|\bacs-\d|\bb-\d{4}|arc-case|\brma-\d|\bso-\d|-po-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

part = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_part_selection")
both = ref_call(part, "PAST_LTB, Rds(on)")
check("ref_part_selection: several words in one call ('PAST_LTB, Rds(on)') -> both found",
      {"PAST_LTB", "Rds(on) / Vf"} <= {r["term"] for r in both}, [r["term"] for r in both])
repl = [r for r in ref_call(part, "") if r["section"] == "REPLACEMENT"]
cat = psql("SELECT part_number, lifecycle, replacement_part FROM parts WHERE replacement_part IS NOT NULL")
check("ref_part_selection: REPLACEMENT rows come from parts (one source of truth, UNION) - one per replaced part",
      sorted(r["term"] for r in repl) == sorted(f"{c['part_number']} ({c['lifecycle']})" for c in cat)
      and all(any(r["term"].startswith(c["part_number"]) and c["replacement_part"] in r["meaning"] for r in repl) for c in cat),
      [r["term"] for r in repl])
sd = [r for r in ref_call(part, "AW-SD-2010") if r["section"] == "REPLACEMENT"]
check("ref_part_selection: AW-SD-2010 row carries AW-SD-2011, the cross-reference relation and the exact LTB date",
      len(sd) == 1 and "AW-SD-2011 (drop in replacement)" in sd[0]["meaning"]
      and f"Last-time-buy date {day(30)}." in sd[0]["meaning"], sd)
check("ref_part_selection: the standard note line is in the table (and no longer only in the prompt)",
      any(r["term"] == "STANDARD" and r["meaning"].endswith("your engineers must confirm the part for your design.")
          for r in ref_call(part, "note line")))

rma = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_defect_taxonomy")
rt = ref_call(rma, "routing")
check("ref_defect_taxonomy: ROUTING row (who decides) comes from case_routing (Quality Engineering + its SLA text)",
      len(rt) == 1 and rt[0]["section"] == "ROUTING" and "Quality Engineering" in rt[0]["meaning"]
      and val("SELECT sla_text AS v FROM case_routing WHERE request_type='rma_disposition'") in rt[0]["meaning"], rt)
psql("UPDATE case_routing SET sla_text = sla_text || ' (test)' WHERE request_type = 'rma_disposition'")
check("ref_defect_taxonomy: a case_routing edit shows up in the ROUTING row (no copy)",
      ref_call(rma, "routing")[0]["meaning"].endswith("(test)"))
psql("UPDATE case_routing SET sla_text = replace(sla_text, ' (test)', '') WHERE request_type = 'rma_disposition'")
tax = ref_call(rma, "")
types = [r["term"] for r in tax if r["section"] == "DEFECT_TYPE"]
ev = [r["term"] for r in tax if r["section"] == "EVIDENCE"]
canon = [r["v"] for r in psql("SELECT DISTINCT norm_defect(x) AS v FROM unnest(ARRAY['ELECTRICAL_FAILURE','PARAMETRIC_DRIFT',"
                              "'MECHANICAL_DAMAGE','SOLDERABILITY','WRONG_PART','OTHER','gibberish']) x")]
check("ref_defect_taxonomy: every defect type norm_defect() can store is explained, with its own EVIDENCE row",
      sorted(types) == sorted(canon) == sorted(ev) and len(types) == 6, (types, ev, canon))
check("ref_defect_taxonomy: each type maps to itself in SQL (norm_defect(term) = term)",
      all(val(f"SELECT norm_defect({lit(x)}) AS v") == x for x in types))
pv = ref_call(rma, "pv inverters")
check("ref_defect_taxonomy: 'pv inverters' finds the mains / high-voltage safety sign (YES)",
      any(r["section"] == "SAFETY_SIGN" and "YES" in r["meaning"] for r in pv), pv)
check("ref_defect_taxonomy: 'when unsure say YES' safety rule is kept",
      any("when unsure say yes" in r["meaning"].lower() for r in tax))

pcn = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_pcn_guide")
g = ref_call(pcn, "")
ct = [r for r in g if r["section"] == "CHANGE_TYPE"]
check("ref_pcn_guide: every change type says what a buyer checks", len(ct) >= 5 and all("Buyer checks:" in r["meaning"] for r in ct),
      [r["term"] for r in ct if "Buyer checks:" not in r["meaning"]])
two = ref_call(pcn, "msl, date code")
check("ref_pcn_guide: several words in one call ('msl, date code') -> both terms",
      {"MSL", "date code"} <= {r["term"] for r in two}, [r["term"] for r in two])
check("ref_pcn_guide: the seeded notice's change types are covered (assembly site + mold compound)",
      {"assembly site transfer", "mold compound change"} <= {r["term"] for r in ref_call(pcn, "assembly site, mold compound")})

# nothing from the old static reference text was lost
KEEP = {"get_part_selection_guide": [
            "n-channel", "p-channel", "drain-source voltage", "continuous drain current", "on-resistance", "lower is better",
            "schottky barrier diode", "forward voltage", "low-dropout regulator", "multilayer ceramic capacitor",
            "transient voltage suppressor", "microcontroller", "photovoltaic inverter boost stage", "electric vehicle",
            "recommended for new designs", "not recommended for new designs", "orderable only until its last-time-buy date",
            "not orderable", "aec-q100", "aec-q101", "aec-q200", "automotive qualified", "commercial / industrial",
            "generic jedec-style outlines", "different pcb footprint", "rating is below the bom line",
            "a higher rating than needed is allowed but say it is higher", "prefer the same package (drop-in)",
            "prefer active over nrnd", "automotive applications need an aec grade", "if none of the candidates has one, say so",
            "prefer parts with stock", "last-time-buy date has passed", "cannot be ordered", "your engineers must confirm"],
        "get_defect_taxonomy": [
            "electrical_failure", "gate shorted", "blew up", "no output", "fails after some weeks in the field",
            "parametric_drift", "out of specification", "oscillation", "leakage", "runs hot", "mechanical_damage",
            "cracked body", "bent leads", "crushed reel", "damaged packaging", "solderability", "poor wetting",
            "oxidised terminations", "wrong_part", "mislabeled reel", "fits none", "overheating", "smoke", "fire",
            "arcing", "short circuit in a power path", "solar / pv inverters", "ev chargers", "motor drives",
            "power supplies", "medical device", "automotive safety system", "when unsure say yes",
            "quality engineering decides", "how many failed out of how many installed", "date codes or lot numbers",
            "operating voltage, current and temperature", "photos", "failure analysis", "root cause as fact",
            "never suggest a credit, replacement or disposition"],
        "get_pcn_glossary": [
            "keeps its part number", "being discontinued", "effective date", "no longer made",
            "last day an order is accepted", "non-cancellable and non-returnable", "same size, same pins and same electrical behaviour",
            "different factory", "plastic body material", "moisture sensitivity level", "dry pack",
            "unchanged msl means handling stays the same", "build week", "mixed date codes", "both old and new parts",
            "test data proving the change", "samples or object before the change applies",
            "whether their own customer needs to be told", "samples or the qualification report", "place a last-time-buy",
            "replacement part"]}
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

reset()
total = passes + fails
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} checks, DB reset)")
sys.exit(1 if fails else 0)
