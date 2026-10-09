#!/usr/bin/env python3
"""Step 1: run the EXACT tool SQL from tool_spec.py against the banking_governed DB and assert the business rules.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> PG_DB=banking_governed python _rebuild/test_rules.py     (PSQL env var overrides the psql path)
"""
import os, re, subprocess, sys, csv, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, LOOKUP_MERCHANT

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "banking_governed"), "-v", "ON_ERROR_STOP=1", "-q"]
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

def one(sql):
    return list(psql(sql)[0].values())[0]

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

# ---- static contract of tool_spec (governance shape) ----
check("13 MCP tools", len(TOOLS) == 13, [t["tool"] for t in TOOLS])
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
            ok = ok and re.match(r"INSERT INTO \w+ \([^)]*\) SELECT (\*|customer_id) FROM \w+\(", sql) is not None
        check(f"{t['tool']}.{part}: CAST-wrapped unique placeholders, no VALUES, no audit", ok, sql)
check("find_branch takes no session_token", [a for a, _ in T["find_branch"]["args"]] == ["city"])
check("every other tool except verify takes session_token",
      all(t["args"][0][0] == "session_token" for t in TOOLS if t["tool"] not in ("verify_customer", "find_branch")))

# ---- identity ----
r = call("verify_customer", customer_id="CUST-2026-00101", passcode="000000")
check("wrong passcode -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_customer", customer_id=" cust-2026-00101 ", passcode="482913")
check("right id+passcode -> VERIFIED + token + name", r[0]["status"] == "VERIFIED" and r[0]["session_token"]
      and r[0]["customer_name"] == "James Miller", r)
james = r[0]["session_token"]
olivia = call("verify_customer", customer_id="CUST-2026-00102", passcode="730516")[0]["session_token"]
william = call("verify_customer", customer_id="CUST-2026-00103", passcode="615204")[0]["session_token"]
sophia = call("verify_customer", customer_id="CUST-2026-00104", passcode="559371")[0]["session_token"]
benjamin = call("verify_customer", customer_id="CUST-2026-00105", passcode="204867")[0]["session_token"]
emma = call("verify_customer", customer_id="CUST-2026-00106", passcode="918342")[0]["session_token"]
michael = call("verify_customer", customer_id="CUST-2026-00107", passcode="377150")[0]["session_token"]
check("all 7 seeded passcodes verify", all([james, olivia, william, sophia, benjamin, emma, michael]))
r = call("verify_customer", customer_id="CUST-2026-99999", passcode="482913")
check("unknown customer id -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
check("unknown id is not tracked in verify_attempts",
      one("SELECT count(*) FROM verify_attempts WHERE customer_id='CUST-2026-99999'") == "0")
r = call("verify_customer", customer_id="CUST-2026-00104", passcode="482913")
check("James's passcode does not open Sophia", r[0]["status"] == "NOT_VERIFIED", r)

# ---- SESSION_INVALID on every scoped tool ----
for t in TOOLS:
    if t["tool"] in ("verify_customer", "find_branch"):
        continue
    args = {a: "x" for a, _ in t["args"]}
    args["session_token"] = "not-a-token"
    row = call(t["tool"], **args)[0]
    code = row.get("session_status") or row.get("reason_code")
    check(f"{t['tool']} with bad token -> SESSION_INVALID", code == "SESSION_INVALID", row)

# ---- scoped reads ----
r = call("get_my_accounts", session_token=james)
check("accounts = James's 2 accounts", sorted(x["account_id"] for x in r) == ["ACC-1001", "ACC-1002"]
      and r[0]["session_status"] == "OK", r)
r = call("get_my_transactions", session_token=james, search="")
ids = [x["transaction_id"] for x in r]
check("empty search: James's last-120-day txns, newest first", "TXN-50003" in ids and "TXN-50006" in ids
      and "TXN-50007" not in ids and ids[0] == "TXN-50006" and r[0]["session_status"] == "OK", ids)
check("no other customer's txn in James's list", not ({"TXN-50009", "TXN-50014", "TXN-50008"} & set(ids)), ids)
r = call("get_my_transactions", session_token=james, search="quickpay")
check("search QUICKPAY -> both XYZ charges", sorted(x["transaction_id"] for x in r) == ["TXN-50003", "TXN-50013"], r)
r = call("get_my_transactions", session_token=james, search="$249.99")
check("search by amount -> TXN-50003", [x["transaction_id"] for x in r] == ["TXN-50003"], r)
r = call("get_my_transactions", session_token=james, search="ELECTROWORLD")
check("search finds the 150-day-old charge", [x["transaction_id"] for x in r] == ["TXN-50007"], r)
r = call("get_my_transactions", session_token=james, search="GLOBAL*DIGITAL")
check("James cannot see Sophia's txn (NO_MATCH)", r[0]["session_status"] == "NO_MATCH" and not r[0]["transaction_id"], r)
r = call("get_my_transactions", session_token=sophia, search="TXN-50009")
check("Sophia's disputed txn shows its open dispute", r[0]["open_dispute_id"] == "DSP-2026-0001", r)
r = call("get_my_cards", session_token=benjamin)
check("Benjamin's card is BLOCKED", r[0]["card_id"] == "CARD-9005" and r[0]["status"] == "BLOCKED", r)
r = call("get_my_cards", session_token=michael)
check("Michael's card is EXPIRED", r[0]["status"] == "EXPIRED", r)
r = call("get_my_loans", session_token=benjamin)
check("Benjamin's loan = LOAN-3003 AUTO", r[0]["loan_id"] == "LOAN-3003" and r[0]["loan_type"] == "AUTO", r)
r = call("get_my_loans", session_token=emma)
check("Emma has no loans (OK, empty)", r[0]["session_status"] == "OK" and not r[0]["loan_id"], r)
r = call("find_branch", city="chicago")
check("find_branch Chicago -> BR-003", [x["branch_id"] for x in r] == ["BR-003"] and r[0]["lookup_status"] == "OK", r)
check("find_branch empty -> 5 branches", len(call("find_branch", city="")) == 5)
check("find_branch unknown -> NOT_FOUND", call("find_branch", city="Atlantis")[0]["lookup_status"] == "NOT_FOUND")

# ---- agent tool: lookup_merchant (descriptor only, no identity) ----
def merch(d):
    return psql(sub(*LOOKUP_MERCHANT["read"], {"descriptor": d}))
m = merch("QUICKPAY*XYZ 872-555")
check("QUICKPAY*XYZ -> XYZ Gadgets Online, ONE_OFF (most specific first)",
      m[0]["merchant_name"] == "XYZ Gadgets Online" and m[0]["billing_model"] == "ONE_OFF"
      and m[0]["match_type"] == "PREFIX_MATCH", m)
m = merch("STRMPLS*MEMBERSHIP 888-555")
check("STRMPLS* -> StreamPlus, RECURRING", m[0]["merchant_name"] == "StreamPlus" and m[0]["billing_model"] == "RECURRING", m)
check("LUXEJET decodes", merch("LUXEJET TRAVEL 800-555")[0]["merchant_name"] == "LuxeJet Travel")
check("GLOBAL*DIGITAL decodes", merch("GLOBAL*DIGITAL 900-555")[0]["merchant_name"] == "Global Digital Media")
check("partial fragment QUICKPAY -> processor rows", merch("quickpay")[0]["match_type"] == "PARTIAL_MATCH")
check("unknown descriptor -> NO_MATCH", merch("ZZZQ UNKNOWN 000")[0]["match_type"] == "NO_MATCH")
check("lookup_merchant takes only a descriptor", [a for a, _ in LOOKUP_MERCHANT["args"]] == ["descriptor"])

# ---- card block guards ----
def pblock(tok, card, reason="LOST"):
    return call("propose_card_block", session_token=tok, card=card, reason=reason)[0]
def cblock(tok, act):
    return call("confirm_card_block", session_token=tok, action_id=act)[0]
check("unknown card -> CARD_NOT_FOUND", pblock(james, "CARD-0000")["reason_code"] == "CARD_NOT_FOUND")
check("Sophia's last4 from James -> CARD_NOT_FOUND", pblock(james, "4410")["reason_code"] == "CARD_NOT_FOUND")
check("Sophia's card_id from James -> CARD_NOT_FOUND", pblock(james, "CARD-9004")["reason_code"] == "CARD_NOT_FOUND")
check("Benjamin CARD-9005 -> ALREADY_BLOCKED", pblock(benjamin, "CARD-9005")["reason_code"] == "ALREADY_BLOCKED")
check("Michael CARD-9007 -> CARD_EXPIRED", pblock(michael, "8857", "STOLEN")["reason_code"] == "CARD_EXPIRED")
check("bad reason -> BAD_REASON", pblock(james, "1123", "BORED")["reason_code"] == "BAD_REASON")
check("no pending action written by any refused proposal", one("SELECT count(*) FROM pending_actions") == "0")

# ---- card block happy path (James by last 4 digits) ----
b1 = pblock(james, "ending 1123", "lost")
b2 = pblock(james, "CARD-9001", "LOST")
exp5 = one("SELECT add_business_days(current_date, 5)")
check("eligible -> PROPOSED, action + delivery date", b1["outcome"] == "PROPOSED" and b1["reason_code"] == "PROPOSED"
      and b1["action_id"] and b1["card_id"] == "CARD-9001" and b1["replacement_expected_delivery"] == exp5, b1)
check("re-propose idempotent (same action)", b1["action_id"] == b2["action_id"], (b1, b2))
check("card still ACTIVE before confirm", one("SELECT status FROM cards WHERE card_id='CARD-9001'") == "ACTIVE")
blk_act = b1["action_id"]
check("confirm bogus id -> NO_SUCH_PROPOSAL", cblock(james, "ACT-00000000")["reason_code"] == "NO_SUCH_PROPOSAL")
check("confirm by another customer -> NO_SUCH_PROPOSAL", cblock(sophia, blk_act)["reason_code"] == "NO_SUCH_PROPOSAL")
c1 = cblock(james, blk_act.lower())
check("confirm -> EXECUTED with BLK-NNNNN", c1["outcome"] == "EXECUTED" and re.fullmatch(r"BLK-\d{5}", c1["block_id"] or "")
      and c1["replacement_expected_delivery"] == exp5, c1)
c2 = cblock(james, blk_act)
check("re-confirm -> ALREADY_EXECUTED, same block, one row", c2["reason_code"] == "ALREADY_EXECUTED"
      and c2["block_id"] == c1["block_id"] and one("SELECT count(*) FROM card_blocks") == "1", c2)
check("trigger: card BLOCKED", one("SELECT status FROM cards WHERE card_id='CARD-9001'") == "BLOCKED")
rep = psql("SELECT card_id, block_id, expected_delivery FROM card_replacements")
check("trigger: one replacement row, delivery +5 business days",
      len(rep) == 1 and rep[0]["card_id"] == "CARD-9001" and rep[0]["expected_delivery"] == exp5, rep)
check("blocked card cannot be blocked again", pblock(james, "1123", "STOLEN")["reason_code"] == "ALREADY_BLOCKED")
r = call("get_my_cards", session_token=james)
check("get_my_cards shows replacement date", r[0]["replacement_expected_delivery"] == exp5, r)

# rules re-checked at confirm: two proposals on Emma's card, the second can no longer execute
e1 = pblock(emma, "6602", "LOST"); e2 = pblock(emma, "6602", "STOLEN")
check("two different proposals on one card", e1["action_id"] != e2["action_id"] and e2["outcome"] == "PROPOSED", (e1, e2))
check("confirm first -> EXECUTED", cblock(emma, e1["action_id"])["outcome"] == "EXECUTED")
r = cblock(emma, e2["action_id"])
check("confirm second -> NOT_EXECUTED ALREADY_BLOCKED (rule re-check)",
      r["outcome"] == "NOT_EXECUTED" and r["reason_code"] == "ALREADY_BLOCKED", r)

# expiry
p = pblock(olivia, "CARD-9002", "DAMAGED")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p['action_id'])}")
r = cblock(olivia, p["action_id"])
check("expired card-block proposal -> EXPIRED, card untouched", r["reason_code"] == "EXPIRED"
      and one("SELECT status FROM cards WHERE card_id='CARD-9002'") == "ACTIVE", r)

# ---- dispute guards ----
def pdisp(tok, txn, reason, stmt="I want to dispute this charge."):
    return call("propose_dispute", session_token=tok, transaction_id=txn, reason_code=reason, customer_statement=stmt)[0]
def cdisp(tok, act):
    return call("confirm_dispute", session_token=tok, action_id=act)[0]
n_pa = one("SELECT count(*) FROM pending_actions")
check("James disputes Sophia's txn -> NOT_YOUR_TRANSACTION", pdisp(james, "TXN-50009", "FRAUD")["reason_code"] == "NOT_YOUR_TRANSACTION")
check("unknown txn -> NOT_YOUR_TRANSACTION", pdisp(james, "TXN-99999", "FRAUD")["reason_code"] == "NOT_YOUR_TRANSACTION")
check("payroll credit -> NOT_A_DEBIT", pdisp(james, "TXN-50001", "UNRECOGNISED")["reason_code"] == "NOT_A_DEBIT")
check("pending charge -> PENDING_NOT_POSTED", pdisp(james, "TXN-50006", "WRONG_AMOUNT")["reason_code"] == "PENDING_NOT_POSTED")
check("150-day-old charge -> OUTSIDE_WINDOW", pdisp(james, "TXN-50007", "NOT_RECEIVED")["reason_code"] == "OUTSIDE_WINDOW")
check("Sophia TXN-50009 -> ALREADY_DISPUTED (DSP-2026-0001)",
      "DSP-2026-0001" in pdisp(sophia, "TXN-50009", "UNRECOGNISED")["reason"])
check("bad reason -> BAD_REASON", pdisp(james, "TXN-50003", "CHANGED_MY_MIND")["reason_code"] == "BAD_REASON")
check("single cafe charge as DUPLICATE -> NOT_DUPLICATE", pdisp(sophia, "TXN-50016", "DUPLICATE")["reason_code"] == "NOT_DUPLICATE")
check("different-amount QUICKPAY as DUPLICATE -> NOT_DUPLICATE", pdisp(james, "TXN-50003", "DUPLICATE")["reason_code"] == "NOT_DUPLICATE")
check("no pending action written by any refused dispute", one("SELECT count(*) FROM pending_actions") == n_pa)

# ---- quotes (computed in SQL) ----
exp10 = one("SELECT add_business_days(current_date, 10)")
q = pdisp(james, "TXN-50003", "UNRECOGNIZED", "I never bought anything from QUICKPAY XYZ.")
check("James UNRECOGNISED 249.99 -> PROPOSED, credit 249.99, fraud review, +10 bd, merchant decoded",
      q["outcome"] == "PROPOSED" and q["amount"] == "249.99" and q["provisional_credit"] == "249.99"
      and q["fraud_review"] == "t" and q["est_decision_date"] == exp10 and q["merchant"] == "XYZ Gadgets Online"
      and q["dispute_reason"] == "UNRECOGNISED", q)
check("re-propose idempotent", pdisp(james, "TXN-50003", "UNRECOGNISED")["action_id"] == q["action_id"])
w = pdisp(william, "TXN-50014", "UNRECOGNISED", "I did not book any LuxeJet trip.")
check("William 1,850 UNRECOGNISED -> credit 0 (> 500), fraud review (> 1,000)",
      w["outcome"] == "PROPOSED" and w["provisional_credit"] == "0.00" and w["fraud_review"] == "t", w)
w2 = pdisp(william, "TXN-50014", "NOT_AS_DESCRIBED")
check("1,850 NOT_AS_DESCRIBED -> credit 0, fraud review by amount", w2["provisional_credit"] == "0.00" and w2["fraud_review"] == "t", w2)
o = pdisp(olivia, "TXN-50008", "CANCELLED_RECURRING", "I cancelled StreamPlus last month.")
check("Olivia CANCELLED_RECURRING -> credit 0, no fraud review, merchant StreamPlus",
      o["outcome"] == "PROPOSED" and o["provisional_credit"] == "0.00" and o["fraud_review"] == "f"
      and o["merchant"] == "StreamPlus", o)
s = pdisp(sophia, "TXN-50018", "DUPLICATE", "Acme charged me twice for the same purchase.")
check("Sophia ACME duplicate -> PROPOSED, credit 64.10, no fraud review",
      s["outcome"] == "PROPOSED" and s["provisional_credit"] == "64.10" and s["fraud_review"] == "f", s)

# ---- confirm dispute ----
check("confirm bogus id -> NO_SUCH_PROPOSAL", cdisp(james, "ACT-00000000")["reason_code"] == "NO_SUCH_PROPOSAL")
check("Sophia confirms James's dispute -> NO_SUCH_PROPOSAL", cdisp(sophia, q["action_id"])["reason_code"] == "NO_SUCH_PROPOSAL")
check("card-block action to confirm_dispute -> NO_SUCH_PROPOSAL", cdisp(james, blk_act)["reason_code"] == "NO_SUCH_PROPOSAL")
check("dispute action to confirm_card_block -> NO_SUCH_PROPOSAL", cblock(james, q["action_id"])["reason_code"] == "NO_SUCH_PROPOSAL")
f1 = cdisp(james, q["action_id"])
check("confirm -> FILED DSP-2026-0002 (sequence continues after seeded 0001)",
      f1["outcome"] == "FILED" and f1["dispute_id"] == "DSP-2026-0002" and f1["provisional_credit"] == "249.99"
      and f1["fraud_case_id"] and f1["provisional_credit_txn"] and f1["est_decision_date"] == exp10, f1)
f2 = cdisp(james, q["action_id"])
check("re-confirm -> ALREADY_EXECUTED, one dispute row", f2["reason_code"] == "ALREADY_EXECUTED"
      and f2["dispute_id"] == "DSP-2026-0002"
      and one("SELECT count(*) FROM disputes WHERE transaction_id='TXN-50003'") == "1", f2)
pc = psql("SELECT account_id, txn_type, status, amount FROM transactions WHERE descriptor='PROVISIONAL CREDIT DSP-2026-0002'")
check("trigger: provisional credit = PENDING CREDIT 249.99 on ACC-1001",
      pc == [{"account_id": "ACC-1001", "txn_type": "CREDIT", "status": "PENDING", "amount": "249.99"}], pc)
fc = psql("SELECT assigned_team, customer_statement, agent_brief, customer_id FROM service_cases "
          "WHERE dispute_id='DSP-2026-0002' AND request_type='FRAUD_REVIEW'")
check("trigger: FRAUD_REVIEW case -> Fraud Operations, customer's own words, system brief",
      len(fc) == 1 and fc[0]["assigned_team"] == "Fraud Operations" and fc[0]["customer_id"] == "CUST-2026-00101"
      and fc[0]["customer_statement"] == "I never bought anything from QUICKPAY XYZ."
      and "DSP-2026-0002" in fc[0]["agent_brief"] and "249.99" in fc[0]["agent_brief"], fc)
check("now TXN-50003 -> ALREADY_DISPUTED", pdisp(james, "TXN-50003", "FRAUD")["reason_code"] == "ALREADY_DISPUTED")
check("provisional credit itself is not disputable (NOT_A_DEBIT)",
      pdisp(james, f1["provisional_credit_txn"], "FRAUD")["reason_code"] == "NOT_A_DEBIT")

fw = cdisp(william, w["action_id"])
check("William FILED, no provisional credit", fw["outcome"] == "FILED" and fw["provisional_credit"] == "0.00"
      and not fw["provisional_credit_txn"], fw)
check("William: no provisional-credit transaction",
      one(f"SELECT count(*) FROM transactions WHERE descriptor = 'PROVISIONAL CREDIT ' || {lit(fw['dispute_id'])}") == "0")
check("William: FRAUD_REVIEW case (amount > 1,000)",
      one(f"SELECT count(*) FROM service_cases WHERE request_type='FRAUD_REVIEW' AND dispute_id={lit(fw['dispute_id'])} "
          "AND assigned_team='Fraud Operations'") == "1")
r = cdisp(william, w2["action_id"])
check("second proposal on same txn -> NOT_FILED ALREADY_DISPUTED (rule re-check)",
      r["outcome"] == "NOT_FILED" and r["reason_code"] == "ALREADY_DISPUTED", r)

fo = cdisp(olivia, o["action_id"])
check("Olivia FILED: no credit, no fraud case", fo["outcome"] == "FILED" and not fo["provisional_credit_txn"]
      and not fo["fraud_case_id"], fo)
fs = cdisp(sophia, s["action_id"])
check("Sophia duplicate FILED: credit txn, no fraud case", fs["outcome"] == "FILED" and fs["provisional_credit_txn"]
      and not fs["fraud_case_id"], fs)

# dispute expiry
x = pdisp(sophia, "TXN-50017", "WRONG_AMOUNT")
check("Sophia TXN-50017 WRONG_AMOUNT -> PROPOSED", x["outcome"] == "PROPOSED", x)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(x['action_id'])}")
r = cdisp(sophia, x["action_id"])
check("expired dispute proposal -> EXPIRED, nothing filed", r["reason_code"] == "EXPIRED"
      and one("SELECT count(*) FROM disputes WHERE transaction_id='TXN-50017'") == "0", r)

# ---- human-owned requests ----
def case(tok, ty, stmt="Please help with this.", brief="Customer request; routed for a human to decide."):
    return call("open_service_case", session_token=tok, request_type=ty, customer_statement=stmt, brief=brief)[0]
k = case(olivia, "fee refund", "Please refund the 35 dollar overdraft fee.")
check("Olivia FEE_REFUND -> CASE_OPENED, Customer Care, 2 days", k["outcome"] == "CASE_OPENED"
      and re.fullmatch(r"CASE-\d{5}", k["case_id"] or "") and k["assigned_team"] == "Customer Care"
      and k["reply_within_business_days"] == "2", k)
check("duplicate case suppressed (same case id)", case(olivia, "FEE_REFUND")["case_id"] == k["case_id"])
k = case(benjamin, "LOAN_HARDSHIP", "I lost my job and need to pause my car loan payments.")
check("Benjamin LOAN_HARDSHIP -> Financial Support, 1 day", k["assigned_team"] == "Financial Support"
      and k["reply_within_business_days"] == "1", k)
ROUTING = {"FEE_REFUND": ("Customer Care", "2"), "LOAN_HARDSHIP": ("Financial Support", "1"),
           "CREDIT_LIMIT_INCREASE": ("Credit Risk", "3"), "COMPLAINT": ("Complaints Resolution", "2"),
           "PERSONAL_DETAILS_CHANGE": ("Identity & Account Servicing", "2"),
           "ACCOUNT_CLOSURE": ("Identity & Account Servicing", "2"), "BEREAVEMENT": ("Bereavement Support", "1"),
           "FRAUD_REVIEW": ("Fraud Operations", "1"), "OTHER": ("Customer Care", "3")}
for ty, (team, days) in ROUTING.items():
    k = case(emma, ty)
    check(f"{ty} -> {team}, {days} business days", k["outcome"] == "CASE_OPENED" and k["assigned_team"] == team
          and k["reply_within_business_days"] == days, k)
r = case(emma, "LOAN_APPROVAL")
check("bad request type -> BAD_TYPE", r["outcome"] == "NOT_OPENED" and r["reason_code"] == "BAD_TYPE", r)

# ---- my cases (disputes + service cases) ----
r = call("get_my_cases", session_token=james)
refs = {x["reference_id"]: x for x in r}
check("James sees his dispute and the fraud-review case", "DSP-2026-0002" in refs and f1["fraud_case_id"] in refs
      and refs["DSP-2026-0002"]["case_type"] == "DISPUTE" and r[0]["session_status"] == "OK", r)
check("James does not see Sophia's dispute", "DSP-2026-0001" not in refs, refs.keys())
r = call("get_my_cases", session_token=sophia)
check("Sophia sees seeded DSP-2026-0001 OPEN", any(x["reference_id"] == "DSP-2026-0001" and x["status"] == "OPEN" for x in r), r)
r = call("get_my_cases", session_token=michael)
check("Michael has no cases (OK, empty)", r[0]["session_status"] == "OK" and not r[0]["reference_id"], r)

# ---- email confirmation (guarded) ----
def mail(tok, ref):
    return call("email_my_confirmation", session_token=tok, reference_id=ref)[0]
e = mail(james, "DSP-2026-0002")
check("email SEND for James's dispute", e["send_status"] == "SEND" and "DSP-2026-0002" in e["subject"]
      and "249.99" in e["body"] and "1123" not in e["body"], e)
e = mail(james, c1["block_id"].lower())
check("email SEND for James's card block", e["send_status"] == "SEND" and "1123" in e["subject"]
      and exp5 in e["body"], e)
e = mail(james, "DSP-2026-0001")
check("email NOT_SENT for Sophia's dispute (NO_SUCH_REFERENCE)", e["send_status"] == "NOT_SENT"
      and e["reason_code"] == "NO_SUCH_REFERENCE", e)
e = mail(sophia, c1["block_id"])
check("email NOT_SENT for James's block from Sophia", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NO_SUCH_REFERENCE", e)
e = mail(james, "ACT-00000000")
check("email NOT_SENT for a non-reference", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NO_SUCH_REFERENCE", e)
check("email SEND for Sophia's seeded dispute", mail(sophia, "DSP-2026-0001")["send_status"] == "SEND")

# ---- session expiry ----
psql(f"UPDATE customer_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(james)}")
check("expired token -> SESSION_INVALID", call("get_my_accounts", session_token=james)[0]["session_status"] == "SESSION_INVALID")

# ---- passcode brute-force lockout ----
n_sess = one("SELECT count(*) FROM customer_sessions WHERE customer_id='CUST-2026-00107'")
last = None
for _ in range(5):
    last = call("verify_customer", customer_id="CUST-2026-00107", passcode="111111")[0]   # 5 wrong codes
check("5th wrong passcode -> LOCKED", last["status"] == "LOCKED" and not last["session_token"], last)
r = call("verify_customer", customer_id="CUST-2026-00107", passcode="377150")              # right code, but locked
check("5 wrong -> LOCKED even with the right passcode, no token", r[0]["status"] == "LOCKED" and not r[0]["session_token"], r)
check("no session issued while locked",
      one("SELECT count(*) FROM customer_sessions WHERE customer_id='CUST-2026-00107'") == n_sess)
psql("UPDATE verify_attempts SET at = at - interval '16 minutes' WHERE customer_id='CUST-2026-00107'")
r = call("verify_customer", customer_id="CUST-2026-00107", passcode="377150")
check("lock lifts after 15 minutes", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
for _ in range(4):
    call("verify_customer", customer_id="CUST-2026-00106", passcode="000000")
r = call("verify_customer", customer_id="CUST-2026-00106", passcode="918342")
check("4 wrong then right -> VERIFIED (threshold is 5)", r[0]["status"] == "VERIFIED", r)

# ---- audit trail (OWASP traceability; written by triggers, no tool reads it) ----
na = lambda a: int(one(f"SELECT count(*) FROM agent_audit WHERE action={lit(a)}"))
check("audit logged verify sessions", na("VERIFY") >= 7, na("VERIFY"))
check("audit logged card-block proposals + blocks", na("CARD_BLOCK_PROPOSED") >= 1 and na("CARD_BLOCKED") == 2,
      (na("CARD_BLOCK_PROPOSED"), na("CARD_BLOCKED")))
check("audit logged dispute proposals + filings", na("DISPUTE_PROPOSED") >= 1 and na("DISPUTE_FILED") == 4,
      (na("DISPUTE_PROPOSED"), na("DISPUTE_FILED")))
check("audit logged service cases (incl. trigger fraud cases)", na("SERVICE_CASE_OPENED") >= 13, na("SERVICE_CASE_OPENED"))
check("audit rows carry the customer id", one("SELECT count(*) FROM agent_audit WHERE customer_id IS NULL") == "0")

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  (DB reset)")
sys.exit(1 if fails else 0)
