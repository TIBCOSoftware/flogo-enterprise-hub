#!/usr/bin/env python3
"""Step 1: run the EXACT tool SQL from tool_spec.py against the banking_jwt_auth DB and assert the business rules -
identity (the verified JWT subject: customers, active reviewers, unknown subjects, whoami), scoping, two-step card blocks / disputes / payments, the scam bands, the routed cases, the full reviewer loop
(every reason code, parked actions executed on approval), minimum-necessary outputs, and the A2A agents' read-only
reference tools. No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> PG_DB=banking_jwt_auth python _rebuild/test_rules.py     (PSQL env var overrides the psql path)

There are no tokens here: the MCP Server trigger verifies the JWT, and each tool flow binds the verified subject
($flow.tokenInfo.sub) to every SQL parameter whose source is SUB ("@sub"). This test binds the persona's subject the same
way (call(tool, sub=<customer or staff id>, ...)), so the SQL tested here is the SQL that ships.
"""
import os, re, subprocess, sys, csv, io, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import (TOOLS, LOOKUP_MERCHANT, AGENT_REF_TOOLS, GUIDE_TOOLS, REF_COLUMNS, HIDDEN_COLUMNS,
                       HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS, PUBLIC_TOOLS, SHARED_TOOLS, CUSTOMER_TOOLS, SUB, SUB_EXPR,
                       param_source, PERSONAS, CUSTOMER_FULL_SCOPES, CUSTOMER_VIEW_ONLY_SCOPES, REVIEWER_SCOPES,
                       tools_for_scopes)

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
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "banking_jwt_auth"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = passes = 0
OUTPUTS = []          # (tool, rows) for the hidden-column scans

def lit(v):
    return "'" + str(v).replace("'", "''") + "'"

def bind(sql, params, args):
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

def call(tool, sub="", **args):
    """Run the tool's exact SQL as the given verified subject (what $flow.tokenInfo.sub carries at runtime)."""
    t = T[tool]
    args[SUB] = sub
    if "write" in t:
        psql(bind(*t["write"], args))
    rows = psql(bind(*t["read"], args))
    OUTPUTS.append((tool, rows))
    return rows

def check(label, cond, detail=""):
    global fails, passes
    print((("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}")).encode("ascii", "replace").decode())
    fails += 0 if cond else 1
    passes += 1 if cond else 0

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

# ---- static contract of tool_spec (governance shape) ----
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
check("19 MCP tools (14 customer + whoami + find_branch + 3 reviewer)", len(TOOLS) == 19 and len(CUSTOMER_TOOLS) == 14
      and SHARED_TOOLS == {"whoami", "find_branch"} and REVIEWER_TOOLS <= set(T) and len(REVIEWER_TOOLS) == 3,
      [t["tool"] for t in TOOLS])
check("no verify tools any more (identity comes from the JWT)", not {"verify_customer", "verify_reviewer"} & set(T))
IDENTITY_ARGS = {"session_token", "token", "customer_id", "staff_id", "sub", "subject", "passcode", "code", "reviewer_id"}
check("no tool takes an identity argument (the caller is never a tool argument)",
      not any(a in IDENTITY_ARGS for t in TOOLS for a, _ in t["args"]),
      [(t["tool"], a) for t in TOOLS for a, _ in t["args"] if a in IDENTITY_ARGS])
check("find_branch is the only tool that does not bind the caller; its only arg is city",
      PUBLIC_TOOLS == {"find_branch"} and [a for a, _ in T["find_branch"]["args"]] == ["city"]
      and not any(src == SUB for part in ("write", "read") if part in T["find_branch"] for _, src in T["find_branch"][part][1]))
check("every other tool binds the verified subject (@sub) in EVERY statement, exactly once, as its first parameter",
      all(sum(src == SUB for _, src in t[part][1]) == 1 and t[part][1][0][1] == SUB
          for t in TOOLS if t["tool"] not in PUBLIC_TOOLS for part in ("write", "read") if part in t),
      [t["tool"] for t in TOOLS if t["tool"] not in PUBLIC_TOOLS for part in ("write", "read") if part in t
       and sum(src == SUB for _, src in t[part][1]) != 1])
check("every other SQL parameter is a declared argument of its tool",
      all(src in {a for a, _ in t["args"]} for t in TOOLS for part in ("write", "read") if part in t
          for _, src in t[part][1] if src != SUB))
check("@sub maps to $flow.tokenInfo.sub, arguments to $flow.arguments.<name>",
      param_source(SUB) == "=$flow.tokenInfo.sub" == SUB_EXPR and param_source("city") == "=$flow.arguments.city")
SCOPE_TABLE = {"whoami": "profile:read", "get_my_accounts": "accounts:read", "get_my_transactions": "transactions:read",
               "get_my_cards": "cards:read", "get_my_loans": "loans:read", "get_my_payees": "payees:read",
               "get_my_cases": "cases:read", "find_branch": "branches:read", "propose_card_block": "cards:block",
               "confirm_card_block": "cards:block", "propose_dispute": "disputes:write", "confirm_dispute": "disputes:write",
               "propose_payment": "payments:write", "confirm_payment": "payments:write", "open_service_case": "cases:write",
               "email_my_confirmation": "email:send", "get_review_queue": "reviews:read", "get_review_case": "reviews:read",
               "decide_review_case": "reviews:decide"}
check("every tool carries exactly the scope of auth.spec.md", {t["tool"]: t.get("scope") for t in TOOLS} == SCOPE_TABLE,
      {t["tool"]: t.get("scope") for t in TOOLS if t.get("scope") != SCOPE_TABLE.get(t["tool"])})
check("scope sets: full customer = view-only + cards:block disputes:write payments:write cases:write email:send",
      CUSTOMER_FULL_SCOPES == CUSTOMER_VIEW_ONLY_SCOPES + ["cards:block", "disputes:write", "payments:write", "cases:write", "email:send"]
      and CUSTOMER_VIEW_ONLY_SCOPES == ["profile:read", "accounts:read", "transactions:read", "cards:read", "loans:read",
                                        "payees:read", "cases:read", "branches:read"]
      and REVIEWER_SCOPES == ["profile:read", "reviews:read", "reviews:decide", "branches:read"])
check("full customer token -> the 14 customer tools + whoami + find_branch, no reviewer tool",
      tools_for_scopes(CUSTOMER_FULL_SCOPES) == CUSTOMER_TOOLS | SHARED_TOOLS)
check("view-only customer token -> reads only (no card block, dispute, payment, case or email tool)",
      tools_for_scopes(CUSTOMER_VIEW_ONLY_SCOPES) == {"whoami", "find_branch", "get_my_accounts", "get_my_transactions",
                                                      "get_my_cards", "get_my_loans", "get_my_payees", "get_my_cases"})
check("reviewer token -> the 3 reviewer tools + whoami + find_branch only", tools_for_scopes(REVIEWER_SCOPES) == REVIEWER_TOOLS | SHARED_TOOLS)
check("personas: the 8 seeded customers + view-only James + the 3 reviewers",
      sorted(p["sub"] for p in PERSONAS.values() if p["role"] == "CUSTOMER" and p["scp"] == CUSTOMER_FULL_SCOPES)
      == [f"CUST-2026-0010{i}" for i in range(1, 9)]
      and PERSONAS["james_view"]["sub"] == "CUST-2026-00101" and PERSONAS["james_view"]["scp"] == CUSTOMER_VIEW_ONLY_SCOPES
      and sorted(p["sub"] for p in PERSONAS.values() if p["role"] == "REVIEWER") == ["KST-7001", "KST-7002", "KST-7003"])
check("persona names match the database (what whoami returns)",
      all(PERSONAS[k]["name"] == one(f"SELECT display_name FROM whoami({lit(PERSONAS[k]['sub'])})") for k in PERSONAS))

# ---- identity: the subject is the verified JWT sub (no passcodes, sessions or lockouts in the database) ----
james, olivia, william, sophia = (PERSONAS[k]["sub"] for k in ("james", "olivia", "william", "sophia"))
benjamin, emma, michael, patricia = (PERSONAS[k]["sub"] for k in ("benjamin", "emma", "michael", "patricia"))
maya, daniel, priya = (PERSONAS[k]["sub"] for k in ("maya", "daniel", "priya"))
UNKNOWN_SUBS = ["CUST-2026-99999", "", "cust-2026-00101", " CUST-2026-00101", "KST-9999", "' OR '1'='1"]
check("no session / passcode / lockout tables, columns or functions are left",
      one("SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN "
          "('customer_sessions','verify_attempts','reviewer_verify_attempts')") == "0"
      and one("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND column_name IN "
              "('passcode_hash','one_time_code','session_token')") == "0"
      and one("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname='public' AND "
              "(p.proname LIKE 'verify%' OR p.proname LIKE '%locked_until' OR p.proname IN ('passcode_hash','session_customer',"
              "'session_reviewer','audit_session'))") == "0")

# whoami
w = call("whoami", sub=james)
check("whoami(James) -> CUSTOMER, James Miller, no team or limit", len(w) == 1 and w[0]["role"] == "CUSTOMER"
      and w[0]["subject"] == james and w[0]["display_name"] == "James Miller" and not w[0]["team"] and not w[0]["approval_limit"], w)
check("whoami columns: role, subject, display_name, team, approval_limit, reason (no email, phone or account data)",
      list(w[0]) == ["role", "subject", "display_name", "team", "approval_limit", "reason"])
w = call("whoami", sub=maya)[0]
check("whoami(Maya) -> REVIEWER, Maya Chen, Customer Care, limit 25.00", w["role"] == "REVIEWER" and w["display_name"] == "Maya Chen"
      and w["team"] == "Customer Care" and w["approval_limit"] == "25.00", w)
w = call("whoami", sub=priya)[0]
check("whoami(Priya) -> REVIEWER, Fraud Operations, limit 20000.00", w["role"] == "REVIEWER" and w["team"] == "Fraud Operations"
      and w["approval_limit"] == "20000.00", w)
for u in UNKNOWN_SUBS:
    w = call("whoami", sub=u)[0]
    check(f"whoami({u!r}) -> UNKNOWN, no name (exact match: no trimming or case folding)",
          w["role"] == "UNKNOWN" and not w["display_name"] and not w["team"] and w["subject"] == u, w)

# ---- UNKNOWN_CALLER on every customer tool for a subject that is not a customer; NOT_REVIEWER on every reviewer tool ----
WRITE_TABLES = ("pending_actions", "service_cases", "payment_requests", "email_log", "review_decisions", "decide_attempts",
                "agent_audit")
n_writes0 = [one(f"SELECT count(*) FROM {x}") for x in WRITE_TABLES]
for t in TOOLS:
    if t["tool"] in SHARED_TOOLS:
        continue
    args = {a: "x" for a, _ in t["args"]}
    if t["tool"] in REVIEWER_TOOLS:
        args.update(case_id="CASE-00004", decision="APPROVE", internal_note="unit test note")
        for who, s_ in (("customer sub (James)", james), ("unknown sub", "CUST-2026-99999"), ("empty sub", "")):
            row = call(t["tool"], sub=s_, **args)[0]
            check(f"{t['tool']} with a {who} -> NOT_REVIEWER", (row.get("status") or row.get("outcome")) == "NOT_REVIEWER", row)
        continue
    for who, s_ in (("unknown sub", "CUST-2026-99999"), ("reviewer sub (Maya)", maya), ("lower-case customer id", "cust-2026-00101")):
        row = call(t["tool"], sub=s_, **args)[0]
        code = row.get("caller_status") or row.get("reason_code")
        check(f"{t['tool']} with a {who} -> UNKNOWN_CALLER", code == "UNKNOWN_CALLER", row)
check("DB: calls by unknown / wrong-role subjects wrote nothing (no proposal, case, payment, email, decision or audit row)",
      [one(f"SELECT count(*) FROM {x}") for x in WRITE_TABLES] == n_writes0)

# ---- scoped reads ----
r = call("get_my_accounts", sub=james)
check("accounts = James's 2 accounts", sorted(x["account_id"] for x in r) == ["ACC-1001", "ACC-1002"]
      and r[0]["caller_status"] == "OK", r)
r = call("get_my_transactions", sub=james, search="")
ids = [x["transaction_id"] for x in r]
check("empty search: James's last-120-day txns, newest first", "TXN-50003" in ids and "TXN-50006" in ids
      and "TXN-50007" not in ids and ids[0] == "TXN-50006" and r[0]["caller_status"] == "OK", ids)
check("no other customer's txn in James's list", not ({"TXN-50009", "TXN-50014", "TXN-50008"} & set(ids)), ids)
r = call("get_my_transactions", sub=james, search="quickpay")
check("search QUICKPAY -> both XYZ charges", sorted(x["transaction_id"] for x in r) == ["TXN-50003", "TXN-50013"], r)
r = call("get_my_transactions", sub=james, search="$249.99")
check("search by amount -> TXN-50003", [x["transaction_id"] for x in r] == ["TXN-50003"], r)
r = call("get_my_transactions", sub=james, search="ELECTROWORLD")
check("search finds the 150-day-old charge", [x["transaction_id"] for x in r] == ["TXN-50007"], r)
r = call("get_my_transactions", sub=james, search="GLOBAL*DIGITAL")
check("James cannot see Sophia's txn (NO_MATCH)", r[0]["caller_status"] == "NO_MATCH" and not r[0]["transaction_id"], r)
r = call("get_my_transactions", sub=sophia, search="TXN-50009")
check("Sophia's disputed txn shows its open dispute", r[0]["open_dispute_id"] == "DSP-2026-0001", r)
r = call("get_my_cards", sub=benjamin)
check("Benjamin's card is BLOCKED", r[0]["card_id"] == "CARD-9005" and r[0]["status"] == "BLOCKED", r)
r = call("get_my_cards", sub=michael)
check("Michael's card is EXPIRED", r[0]["status"] == "EXPIRED", r)
r = call("get_my_loans", sub=benjamin)
check("Benjamin's loan = LOAN-3003 AUTO", r[0]["loan_id"] == "LOAN-3003" and r[0]["loan_type"] == "AUTO", r)
r = call("get_my_loans", sub=emma)
check("Emma has no loans (OK, empty)", r[0]["caller_status"] == "OK" and not r[0]["loan_id"], r)
r = call("find_branch", city="chicago")
check("find_branch Chicago -> BR-003", [x["branch_id"] for x in r] == ["BR-003"] and r[0]["lookup_status"] == "OK", r)
check("find_branch empty -> 5 branches", len(call("find_branch", city="")) == 5)
check("find_branch unknown -> NOT_FOUND", call("find_branch", city="Atlantis")[0]["lookup_status"] == "NOT_FOUND")

# ---- agent tool: lookup_merchant (descriptor only, no identity) ----
def merch(d):
    return psql(bind(*LOOKUP_MERCHANT["read"], {"descriptor": d}))
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
    return call("propose_card_block", sub=tok, card=card, reason=reason)[0]
def cblock(tok, act):
    return call("confirm_card_block", sub=tok, action_id=act)[0]
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
r = call("get_my_cards", sub=james)
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
    return call("propose_dispute", sub=tok, transaction_id=txn, reason_code=reason, customer_statement=stmt)[0]
def cdisp(tok, act):
    return call("confirm_dispute", sub=tok, action_id=act)[0]
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
    return call("open_service_case", sub=tok, request_type=ty, customer_statement=stmt, brief=brief)[0]
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
r = call("get_my_cases", sub=james)
refs = {x["reference_id"]: x for x in r}
check("James sees his dispute and the fraud-review case", "DSP-2026-0002" in refs and f1["fraud_case_id"] in refs
      and refs["DSP-2026-0002"]["case_type"] == "DISPUTE" and r[0]["caller_status"] == "OK", r)
check("James does not see Sophia's dispute", "DSP-2026-0001" not in refs, refs.keys())
r = call("get_my_cases", sub=sophia)
check("Sophia sees seeded DSP-2026-0001 OPEN", any(x["reference_id"] == "DSP-2026-0001" and x["status"] == "OPEN" for x in r), r)
r = call("get_my_cases", sub=michael)
check("Michael sees only his own seeded fee-refund case (CASE-00004, OPEN)",
      [(x["reference_id"], x["status"]) for x in r] == [("CASE-00004", "OPEN")] and r[0]["caller_status"] == "OK", r)

# ---- email confirmation (guarded) ----
def mail(tok, ref):
    return call("email_my_confirmation", sub=tok, reference_id=ref)[0]
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
check("email_log: exactly the 3 SEND requests were logged (guarded write)", one("SELECT count(*) FROM email_log") == "3")
N_EMAIL_SENT = int(one("SELECT count(*) FROM email_log"))

# ---- payees + payments to saved payees (scam protection: agent signals validated + banded in SQL) ----
check("Patricia (CUST-2026-00108) is a known customer", call("whoami", sub=patricia)[0]["display_name"] == "Patricia Wilson")
r = call("get_my_payees", sub=patricia)
check("Patricia sees only her 2 payees; the 'secure holding' payee is new, the landlord is not",
      {x["payee_id"]: x["is_new_payee"] for x in r} == {"PYE-0101": "f", "PYE-0102": "t"} and r[0]["caller_status"] == "OK", r)
r = call("get_my_payees", sub=james)
check("James has no saved payees (OK, empty)", r[0]["caller_status"] == "OK" and not r[0]["payee_id"], r)

def pay(tok, acct, payee, amt, story="", ind="NONE", score="0", notes=""):
    return call("propose_payment", sub=tok, from_account=acct, payee=payee, amount=amt, customer_story=story,
                scam_indicators=ind, narrative_score=score, agent_notes=notes)[0]
def cpay(tok, pid, ack="NO"):
    return call("confirm_payment", sub=tok, payment_id=pid, acknowledge_warning=ack)[0]
def bal(acct): return one(f"SELECT available_balance FROM accounts WHERE account_id = {lit(acct)}")

n_req = one("SELECT count(*) FROM payment_requests")
check("another customer's payee -> PAYEE_NOT_FOUND", pay(james, "ACC-1001", "PYE-0102", "100")["reason_code"] == "PAYEE_NOT_FOUND")
check("another customer's account -> ACCOUNT_NOT_FOUND", pay(patricia, "ACC-1001", "PYE-0101", "100")["reason_code"] == "ACCOUNT_NOT_FOUND")
check("a credit account cannot pay a payee -> ACCOUNT_NOT_FOUND", pay(olivia, "ACC-1004", "PYE-0101", "10")["reason_code"] == "ACCOUNT_NOT_FOUND")
check("negative amount -> BAD_AMOUNT", pay(patricia, "ACC-1013", "PYE-0101", "-5")["reason_code"] == "BAD_AMOUNT")
check("text amount -> BAD_AMOUNT", pay(patricia, "ACC-1013", "PYE-0101", "lots")["reason_code"] == "BAD_AMOUNT")
check("more than the available balance -> INSUFFICIENT_FUNDS", pay(patricia, "ACC-1013", "PYE-0101", "5000")["reason_code"] == "INSUFFICIENT_FUNDS")
check("'savings' resolves the account; $12,000 -> OVER_DAILY_LIMIT", pay(patricia, "savings", "PYE-0101", "12000")["reason_code"] == "OVER_DAILY_LIMIT")
check("no payment request written by any refused proposal", one("SELECT count(*) FROM payment_requests") == n_req)

# deterministic floor + validation, straight from the SQL (no request written)
fl = psql("SELECT * FROM scam_assessment('CUST-2026-00108', 'ACC-1014', 'PYE-0102', 9500, '', '0')")[0]
check("floor: with NO agent indicators and score 0, the safe-account payment is still MEDIUM (new payee, first PERSON payee, unusual amount)",
      fl["risk_band"] == "MEDIUM" and fl["signals"] == "NEW_PAYEE, FIRST_PAYEE_TYPE, AMOUNT_UNUSUAL", fl)
va = psql("SELECT * FROM scam_assessment('CUST-2026-00106', 'ACC-1009', 'PYE-0201', 100, 'TOTALLY_SAFE, safe_account; none', '250')")[0]
check("indicator names are validated against the guide (unknown recorded + ignored) and the score is clamped to 100",
      va["narrative_indicators"] == "SAFE_ACCOUNT" and va["ignored_indicators"] == "TOTALLY_SAFE" and va["narrative_score"] == "100", va)
check("a non-numeric narrative score counts as 0",
      psql("SELECT * FROM scam_assessment('CUST-2026-00106', 'ACC-1009', 'PYE-0201', 100, 'NONE', 'very high')")[0]["narrative_score"] == "0")

# MEDIUM: Emma, new crypto-exchange payee + an investment promise -> a warning she must acknowledge
m = pay(emma, "ACC-1009", "PYE-0202", "1500", "A friend showed me a crypto investment that returns 20 percent a month, so I want to put in 1,500.",
        "INVESTMENT_PROMISE", "55", "indicators: INVESTMENT_PROMISE")
check("new crypto payee + investment promise -> PROPOSED_WITH_WARNING with the SQL warning text",
      m["outcome"] == "PROPOSED_WITH_WARNING" and m["payment_id"] and "never ask you to move money" in (m["warning_text"] or ""), m)
row = psql(f"SELECT risk_band, risk_points, warning_required, status FROM payment_requests WHERE payment_id = {lit(m['payment_id'])}")[0]
check("DB: MEDIUM band (6 points), warning required, PROPOSED", row == {"risk_band": "MEDIUM", "risk_points": "6",
      "warning_required": "t", "status": "PROPOSED"}, row)
r = cpay(emma, m["payment_id"], "NO")
check("confirm without acknowledging the warning -> WARNING_NOT_ACKNOWLEDGED, nothing sent",
      r["outcome"] == "NOT_SENT" and r["reason_code"] == "WARNING_NOT_ACKNOWLEDGED"
      and one(f"SELECT count(*) FROM payment_sends WHERE payment_id = {lit(m['payment_id'])}") == "0", r)
r = cpay(emma, m["payment_id"], "yes")
check("confirm after acknowledging -> SENT", r["outcome"] == "SENT" and r["reason_code"] == "SENT", r)
check("DB: 1,500 debit posted to ACC-1009 (5,600 -> 4,100) and the payee's last-paid date set",
      bal("ACC-1009") == "4100.00" and one("SELECT count(*) FROM transactions WHERE account_id='ACC-1009' AND descriptor='PAYMENT TO APEX COIN EXCHANGE' "
                                           "AND txn_type='DEBIT' AND status='POSTED' AND amount=1500") == "1"
      and one("SELECT last_paid_at IS NOT NULL FROM payees WHERE payee_id='PYE-0202'") == "t")

# LOW: Emma's monthly rent to her known landlord -> plain two-step
e1 = pay(emma, "ACC-1009", "PYE-0201", "1850.00", "Paying my monthly rent to my landlord as usual.", "NONE", "5", "indicators: NONE")
check("rent to a known landlord -> PROPOSED (LOW), no warning", e1["outcome"] == "PROPOSED" and e1["payment_id"] and not e1["warning_text"], e1)
check("DB: LOW band, no deterministic signals", psql(f"SELECT risk_band, signals FROM payment_requests WHERE payment_id = {lit(e1['payment_id'])}")[0]
      == {"risk_band": "LOW", "signals": ""})
check("re-propose idempotent (same payment_id)", pay(emma, "ACC-1009", "PYE-0201", "1850")["payment_id"] == e1["payment_id"])
check("nothing sent before the confirm", one(f"SELECT count(*) FROM payment_sends WHERE payment_id = {lit(e1['payment_id'])}") == "0"
      and bal("ACC-1009") == "4100.00")
check("confirm by another customer -> NO_SUCH_PAYMENT", cpay(james, e1["payment_id"])["reason_code"] == "NO_SUCH_PAYMENT")
check("confirm a bogus id -> NO_SUCH_PAYMENT", cpay(emma, "PAY-99999")["reason_code"] == "NO_SUCH_PAYMENT")
c1 = cpay(emma, e1["payment_id"].lower())
check("confirm -> SENT, balance after 2,250.00", c1["outcome"] == "SENT" and c1["available_balance_after"] == "2250.00", c1)
c2 = cpay(emma, e1["payment_id"])
check("re-confirm -> ALREADY_SENT, one send row", c2["reason_code"] == "ALREADY_SENT"
      and one(f"SELECT count(*) FROM payment_sends WHERE payment_id = {lit(e1['payment_id'])}") == "1", c2)
e3 = pay(emma, "ACC-1009", "PYE-0201", "100", "Topping up the deposit.", "NONE", "0")
psql(f"UPDATE payment_requests SET expires_at = now() - interval '1 minute' WHERE payment_id = {lit(e3['payment_id'])}")
check("expired payment proposal -> EXPIRED, nothing sent", cpay(emma, e3["payment_id"])["reason_code"] == "EXPIRED"
      and bal("ACC-1009") == "2250.00")

# HIGH: Patricia's 'safe account' story -> HELD + a Fraud Operations case (the customer never sees the score)
STORY = ("Someone from Kestrel's fraud team called and said my account is compromised. He said to move my savings to a "
         "safe account they set up for me, and not to tell anyone at the branch because staff might be involved.")
NOTES = ("indicators: SAFE_ACCOUNT, IMPERSONATION, SECRECY, URGENCY\nnarrative_score: 90\nreviewer_steps: Call the customer "
         "back on the phone number on file, explain that no bank uses safe accounts, and ask whether anyone told them to move the money.")
h = pay(patricia, "ACC-1014", "PYE-0102", "9500", STORY, "SAFE_ACCOUNT, IMPERSONATION, SECRECY, URGENCY", "90", NOTES)
check("safe-account story -> HELD_FOR_REVIEW with case id, Fraud Operations and a reply date",
      h["outcome"] == "HELD_FOR_REVIEW" and re.fullmatch(r"CASE-\d{5}", h["case_id"] or "") and h["team"] == "Fraud Operations"
      and h["reply_by"], h)
check("the customer-facing hold message never mentions a score, band, points or indicators",
      not re.search(r"score|band|points|indicator", (h["reason"] or "").lower()) and "never ask you to move money" in h["reason"], h["reason"])
hr = psql(f"SELECT status, risk_band, risk_points, signals, narrative_indicators, case_id FROM payment_requests WHERE payment_id = {lit(h['payment_id'])}")[0]
check("DB: request HELD, HIGH (21 points), linked to the case", hr["status"] == "HELD" and hr["risk_band"] == "HIGH"
      and hr["risk_points"] == "21" and hr["case_id"] == h["case_id"], hr)
hc = psql(f"SELECT request_type, assigned_team, requested_amount, parked_action, agent_brief, status FROM service_cases WHERE case_id = {lit(h['case_id'])}")[0]
check("DB: PAYMENT_HOLD case -> Fraud Operations, parked RELEASE_PAYMENT, requested 9,500, brief carries indicators + signals + agent notes",
      hc["request_type"] == "PAYMENT_HOLD" and hc["assigned_team"] == "Fraud Operations" and hc["requested_amount"] == "9500.00"
      and hc["parked_action"] == "RELEASE_PAYMENT:" + h["payment_id"] and hc["status"] == "OPEN"
      and "SAFE_ACCOUNT" in hc["agent_brief"] and "NEW_PAYEE" in hc["agent_brief"] and "no bank uses safe accounts" in hc["agent_brief"], hc)
check("DB: nothing left the savings account (24,000.00), no send row", bal("ACC-1014") == "24000.00"
      and one(f"SELECT count(*) FROM payment_sends WHERE payment_id = {lit(h['payment_id'])}") == "0")
check("confirming a held payment -> HELD_FOR_REVIEW", cpay(patricia, h["payment_id"], "YES")["reason_code"] == "HELD_FOR_REVIEW")
h2 = pay(patricia, "ACC-1014", "PYE-0102", "9500", STORY, "NONE", "0")
check("re-proposing the held payment (even without indicators) -> the same HELD request, no second case",
      h2["payment_id"] == h["payment_id"] and h2["outcome"] == "HELD_FOR_REVIEW"
      and one("SELECT count(*) FROM service_cases WHERE customer_id='CUST-2026-00108'") == "1", h2)
h3 = pay(patricia, "ACC-1013", "PYE-0102", "200", "Just a small first payment.", "NONE", "0")
check("any other payment to a payee on hold is HELD too (PAYEE_ON_HOLD)", h3["outcome"] == "HELD_FOR_REVIEW"
      and "PAYEE_ON_HOLD" in one(f"SELECT signals FROM payment_requests WHERE payment_id = {lit(h3['payment_id'])}"), h3)
check("audit: PAYMENT_PROPOSED / PAYMENT_HELD / PAYMENT_SENT rows",
      int(one("SELECT count(*) FROM agent_audit WHERE action='PAYMENT_HELD'")) == 2
      and int(one("SELECT count(*) FROM agent_audit WHERE action='PAYMENT_SENT'")) == 2
      and int(one("SELECT count(*) FROM agent_audit WHERE action='PAYMENT_PROPOSED'")) >= 5)

# ---- open_service_case parks the action a person could approve (derived in SQL) ----
k = psql("SELECT requested_amount, parked_action FROM service_cases WHERE customer_id='CUST-2026-00102' AND request_type='FEE_REFUND'")
check("Olivia's FEE_REFUND (no reference) parked her latest unrefunded fee: FEE_REFUND:TXN-50010, $35",
      k == [{"requested_amount": "35.00", "parked_action": "FEE_REFUND:TXN-50010"}], k)
k = psql("SELECT requested_amount, parked_action FROM service_cases WHERE customer_id='CUST-2026-00105' AND request_type='LOAN_HARDSHIP'")
check("Benjamin's LOAN_HARDSHIP parked a 3-payment deferral of his only loan: LOAN_DEFERRAL:LOAN-3003, $2,436.99",
      k == [{"requested_amount": "2436.99", "parked_action": "LOAN_DEFERRAL:LOAN-3003"}], k)
r = call("open_service_case", sub=james, request_type="FEE_REFUND", customer_statement="Refund this.",
         brief="Fee refund request.", reference_id="TXN-50010")[0]
check("FEE_REFUND with another customer's fee -> NOT_OPENED BAD_REFERENCE", r["outcome"] == "NOT_OPENED" and r["reason_code"] == "BAD_REFERENCE", r)
r = call("open_service_case", sub=james, request_type="LOAN_HARDSHIP", customer_statement="I can't pay.",
         brief="Hardship.", reference_id="LOAN-3003")[0]
check("LOAN_HARDSHIP with another customer's loan -> BAD_REFERENCE", r["reason_code"] == "BAD_REFERENCE", r)
r = call("open_service_case", sub=james, request_type="FEE_REFUND", customer_statement="Refund my groceries.",
         brief="n/a", reference_id="TXN-50002")[0]
check("FEE_REFUND on a non-fee transaction -> BAD_REFERENCE", r["reason_code"] == "BAD_REFERENCE", r)
r = call("open_service_case", sub=james, request_type="PAYMENT_HOLD", customer_statement="Hold it.", brief="n/a")[0]
check("PAYMENT_HOLD is not customer-openable -> BAD_TYPE", r["reason_code"] == "BAD_TYPE", r)
r = call("open_service_case", sub=olivia, request_type="LOAN_HARDSHIP", customer_statement="Still on leave.",
         brief="Hardship follow-up.", reference_id="LOAN-3002")[0]
check("Olivia asks again about her seeded open hardship case -> ALREADY_OPEN (same case, no new one)",
      r["outcome"] == "ALREADY_OPEN" and r["case_id"] == "CASE-00003"
      and one("SELECT count(*) FROM service_cases WHERE customer_id='CUST-2026-00102' AND request_type='LOAN_HARDSHIP'") == "1", r)
check("every case has a reply-due time from the routing table", one("SELECT count(*) FROM service_cases WHERE sla_due_at IS NULL") == "0")

# ---- reviewer identity (the staff member's JWT sub; role checked in SQL on every call) ----
check("a reviewer subject is not a customer (get_my_accounts -> UNKNOWN_CALLER)",
      call("get_my_accounts", sub=maya)[0]["caller_status"] == "UNKNOWN_CALLER")
check("a customer subject is not a reviewer (queue -> NOT_REVIEWER)", call("get_review_queue", sub=james)[0]["status"] == "NOT_REVIEWER")
check("unknown subject on get_review_case -> NOT_REVIEWER", call("get_review_case", sub="x", case_id="CASE-00004")[0]["status"] == "NOT_REVIEWER")
check("staff ids match exactly (a loosely typed 'kst-7001' is not Maya)", call("get_review_queue", sub="kst-7001")[0]["status"] == "NOT_REVIEWER")
psql("UPDATE reviewers SET active = FALSE WHERE reviewer_id = 'KST-7002'")
check("a deactivated reviewer's still-valid token stops working at once (queue -> NOT_REVIEWER, whoami -> UNKNOWN)",
      call("get_review_queue", sub=daniel)[0]["status"] == "NOT_REVIEWER" and call("whoami", sub=daniel)[0]["role"] == "UNKNOWN")
psql("UPDATE reviewers SET active = TRUE WHERE reviewer_id = 'KST-7002'")
check("...and works again once reactivated", call("get_review_queue", sub=daniel)[0]["status"] == "OK")

# ---- queues are scoped to the reviewer's team, ordered by reply-due time ----
def queue(tok): return call("get_review_queue", sub=tok)
TEAM = {x["request_type"]: x["team"] for x in psql("SELECT request_type, team FROM service_teams")}
for who, tok, team in (("Maya", maya, "Customer Care"), ("Daniel", daniel, "Financial Support"), ("Priya", priya, "Fraud Operations")):
    qq = queue(tok)
    ids = [x["case_id"] for x in qq]
    db = [x["case_id"] for x in psql("SELECT s.case_id FROM service_cases s JOIN service_teams t USING (request_type) "
                                     f"WHERE t.team = {lit(team)} AND s.status = 'OPEN' ORDER BY s.sla_due_at, s.case_id")]
    check(f"{who}'s queue = exactly {team}'s OPEN cases, ordered by reply-due ({len(ids)})", ids == db and len(ids) >= 2 and qq[0]["status"] == "OK", (ids, db))
qm = {x["case_id"]: x for x in queue(maya)}
check("queue row: first name + last initial only, SLA status, requested amount",
      qm["CASE-00004"]["customer"] == "Michael B." and qm["CASE-00004"]["requested_amount"] == "29.00"
      and qm["CASE-00004"]["sla_status"] in ("ON_TRACK", "DUE_TODAY", "OVERDUE"), qm.get("CASE-00004"))
check("cross-team case is invisible: Maya opens a Financial Support case -> NOT_FOUND",
      call("get_review_case", sub=maya, case_id="CASE-00003")[0]["status"] == "NOT_FOUND")
rc = call("get_review_case", sub=maya, case_id="case-00004")[0]
check("get_review_case: statement, brief, max approvable $29, Maya's $25 limit, fee facts, options mention the senior reviewer",
      rc["status"] == "OK" and rc["max_approvable"] == "29.00" and rc["your_approval_limit"] == "25.00"
      and "TXN-50024" in rc["facts"] and "LATE PAYMENT FEE" in rc["facts"] and "senior reviewer" in rc["options"], rc)
rp = call("get_review_case", sub=priya, case_id=h["case_id"])[0]
check("Fraud reviewer sees the held payment's indicators, signals and band (the customer never does)",
      "SAFE_ACCOUNT" in rp["facts"] and "NEW_PAYEE" in rp["facts"] and "risk band HIGH" in rp["facts"]
      and "in full" in rp["options"], rp)

# ---- decide: every reason code, then the parked actions ----
def decide(tok, case, dec="APPROVE", amt="", note="Checked the account history.", msg="Your request was reviewed."):
    return call("decide_review_case", sub=tok, case_id=case, decision=dec, amount=amt, internal_note=note, customer_message=msg)[0]
n_dec = one("SELECT count(*) FROM review_decisions")
r = decide(michael, "CASE-00004")
check("a customer subject cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
r = decide(maya, "CASE-00003")
check("another team's case -> BLOCKED NOT_YOUR_TEAM", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_YOUR_TEAM" and not r["case_id"], r)
r = decide(maya, "CASE-99999")
check("unknown case -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = decide(maya, "CASE-00004", note="ok")
check("note under 5 characters -> NOTE_REQUIRED", r["reason_code"] == "NOTE_REQUIRED", r)
r = decide(maya, "CASE-00004", dec="MAYBE")
check("decision not APPROVE/REJECT -> INVALID_DECISION", r["reason_code"] == "INVALID_DECISION", r)
r = decide(maya, "CASE-00004", amt="40")
check("more than the $29 fee -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(maya, "CASE-00004", amt="-5")
check("negative amount -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(maya, "CASE-00004")
check("full $29 above Maya's $25 limit -> OVER_AUTHORITY, case stays OPEN", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"], r)
check("DB: no decision row and no refund after the blocked attempts", one("SELECT count(*) FROM review_decisions") == n_dec
      and one("SELECT count(*) FROM transactions WHERE descriptor = 'FEE REFUND TXN-50024'") == "0")
m_bal = one("SELECT balance FROM accounts WHERE account_id = 'ACC-1012'")
r = decide(maya, "CASE-00004", amt="$20", note="Holiday delay confirmed; goodwill refund within my limit.",
           msg="We have refunded $20.00 of the late fee as a goodwill gesture.")
check("approve $20 (within the limit) -> APPROVED, fee refunded", r["outcome"] == "APPROVED" and r["approved_amount"] == "20.00"
      and "refunded" in (r["executed_action"] or ""), r)
check("DB: refund credit posted ('FEE REFUND TXN-50024', $20) and balance -210.00 -> -190.00",
      one("SELECT count(*) FROM transactions WHERE descriptor = 'FEE REFUND TXN-50024' AND txn_type='CREDIT' AND amount=20 AND status='POSTED'") == "1"
      and m_bal == "-210.00" and one("SELECT balance FROM accounts WHERE account_id = 'ACC-1012'") == "-190.00")
check("DB: CASE_DECIDED audit row by KST-7001 for Michael's case",
      one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='CASE-00004' AND actor='KST-7001' AND customer_id='CUST-2026-00107'") == "1")
r = decide(maya, "CASE-00004", dec="REJECT")
check("a second decision -> ALREADY_DECIDED", r["reason_code"] == "ALREADY_DECIDED" and one("SELECT count(*) FROM review_decisions WHERE case_id='CASE-00004'") == "1", r)
oc = one("SELECT case_id FROM service_cases WHERE customer_id='CUST-2026-00102' AND request_type='FEE_REFUND'")
r = decide(maya, oc, dec="REJECT", note="Second overdraft this quarter; policy allows one goodwill refund.",
           msg="We are not able to refund this overdraft fee.")
check("reject Olivia's fee refund -> REJECTED, nothing executed", r["outcome"] == "REJECTED" and "nothing was executed" in r["executed_action"]
      and one("SELECT count(*) FROM transactions WHERE descriptor = 'FEE REFUND TXN-50010'") == "0", r)

bc = one("SELECT case_id FROM service_cases WHERE customer_id='CUST-2026-00105' AND request_type='LOAN_HARDSHIP'")
r = decide(daniel, bc, amt="100")
check("deferral below one monthly payment -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
due0 = one("SELECT next_due_date FROM loans WHERE loan_id='LOAN-3003'")
r = decide(daniel, bc, note="Job loss confirmed by layoff letter; standard 3-payment deferral.",
           msg="Your next 3 auto loan payments are deferred.")
check("approve Benjamin's hardship (full) -> APPROVED, 3 payments ($2,436.99) deferred",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "2436.99" and "3 monthly payment(s)" in (r["executed_action"] or ""), r)
check("DB: loan_deferrals row + LOAN-3003 next due date moved 3 months + LOAN_DEFERRED audit",
      one(f"SELECT count(*) FROM loan_deferrals WHERE case_id = {lit(bc)} AND payments_deferred = 3 AND deferred_amount = 2436.99") == "1"
      and one("SELECT next_due_date FROM loans WHERE loan_id='LOAN-3003'") == one(f"SELECT ({lit(due0)}::date + interval '3 months')::date")
      and one("SELECT count(*) FROM agent_audit WHERE action='LOAN_DEFERRED'") == "1")
r = decide(daniel, "CASE-00003", amt="1000", note="Medical leave letter received; two payments cover the leave.",
           msg="Your next 2 personal loan payments are deferred.")
check("partial deferral: $1,000 on a $490 loan -> 2 whole payments, approved $980.00",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "980.00"
      and one("SELECT payments_deferred FROM loan_deferrals WHERE case_id='CASE-00003'") == "2", r)

r = decide(priya, "CASE-00002", amt="6000")
check("a held payment is released in full or not at all -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(priya, h["case_id"], dec="REJECT", note="Customer confirmed a caller told her to move the money; textbook safe-account scam.",
           msg="We stopped this payment to protect you. Your savings are safe and no money left your account.")
check("reject Patricia's held payment -> REJECTED, payment CANCELLED, no money moved",
      r["outcome"] == "REJECTED" and "cancelled" in r["executed_action"]
      and one(f"SELECT status FROM payment_requests WHERE payment_id = {lit(h['payment_id'])}") == "CANCELLED"
      and bal("ACC-1014") == "24000.00", r)
check("Patricia's cancelled payment cannot be confirmed afterwards", cpay(patricia, h["payment_id"], "YES")["reason_code"] == "CANCELLED")
w_bal = bal("ACC-1005")
r = decide(priya, "CASE-00002", note="Customer met the payee in person and confirmed the investment independently.",
           msg="Your payment has been released.")
check("approve William's held payment (full) -> APPROVED, payment RELEASED and sent",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "6200.00" and "released" in r["executed_action"], r)
check("DB: release posted the $6,200 debit (6,420 -> 220) via REVIEWER, request RELEASED",
      w_bal == "6420.00" and bal("ACC-1005") == "220.00"
      and one("SELECT via FROM payment_sends WHERE payment_id='PAY-00001'") == "REVIEWER"
      and one("SELECT status FROM payment_requests WHERE payment_id='PAY-00001'") == "RELEASED")

# ---- the customer sees the outcome (status + customer_message), never the internals ----
r = {x["reference_id"]: x for x in call("get_my_cases", sub=michael)}
check("Michael sees CASE-00004 APPROVED, $20.00 and the team's message",
      r["CASE-00004"]["status"] == "APPROVED" and r["CASE-00004"]["approved_amount"] == "20.00"
      and "goodwill" in r["CASE-00004"]["customer_message"], r.get("CASE-00004"))
r = {x["reference_id"]: x for x in call("get_my_cases", sub=patricia)}
check("Patricia sees her payment-check case REJECTED with the customer message (no note, score or reviewer)",
      r[h["case_id"]]["status"] == "REJECTED" and "no money left your account" in r[h["case_id"]]["customer_message"]
      and "textbook" not in json.dumps(r) and "Priya" not in json.dumps(r), r.get(h["case_id"]))
e = call("email_my_confirmation", sub=michael, reference_id="CASE-00004")[0]
check("email a decided case -> SEND with the decision", e["send_status"] == "SEND" and "approved" in e["body"] and "goodwill" in e["body"], e)
e = call("email_my_confirmation", sub=patricia, reference_id=one("SELECT case_id FROM service_cases WHERE customer_id='CUST-2026-00108' AND status='OPEN'"))[0]
check("email an undecided case -> NOT_SENT", e["send_status"] == "NOT_SENT", e)
e = call("email_my_confirmation", sub=emma, reference_id=e1["payment_id"])[0]
check("email a sent payment -> SEND", e["send_status"] == "SEND" and "Harbor Property Management" in e["body"], e)
check("email_log holds exactly the SEND requests", one("SELECT count(*) FROM email_log") == str(N_EMAIL_SENT + 2))

# minimum necessary: hidden columns never reach customers; reviewers see no email/phone/full last name.
# whoami is shared by both personas (it returns the caller's OWN role / name / team / limit) and is checked on its own.
cust_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS and t != "whoami" for row in rows for k in row}
check("customer tool outputs carry none of the hidden columns", not (cust_cols & HIDDEN_COLUMNS), cust_cols & HIDDEN_COLUMNS)
rev_rows = [row for t, rows in OUTPUTS if t in REVIEWER_TOOLS for row in rows]
rev_cols = {k for row in rev_rows for k in row}
rblob = json.dumps(rev_rows)
check("reviewer tool outputs: no email, phone or full last name", not (rev_cols & HIDDEN_FROM_REVIEWER)
      and not re.search(r"@example\.com|555-01|Miller|Davis|Garcia|Martinez|Johnson|Wilson\b", rblob), (rev_cols & HIDDEN_FROM_REVIEWER))
cblob = json.dumps([row for t, rows in OUTPUTS if t not in REVIEWER_TOOLS and t != "whoami" for row in rows])
secrets = [x["v"] for x in psql("SELECT internal_note AS v FROM review_decisions UNION ALL SELECT display_name FROM reviewers")]
check("customer outputs never contain internal notes or reviewer names", not any(s in cblob for s in secrets),
      [s for s in secrets if s in cblob][:3])
wrows = [row for t, rows in OUTPUTS if t == "whoami" for row in rows]
check("whoami never returns an email, phone, account or another person's data",
      wrows and all(set(r) == {"role", "subject", "display_name", "team", "approval_limit", "reason"} for r in wrows)
      and not re.search(r"@example\.com|555-01|ACC-|CARD-", json.dumps(wrows)))
check("every MCP tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---- audit trail (OWASP traceability; written by triggers, no tool reads it) ----
na = lambda a: int(one(f"SELECT count(*) FROM agent_audit WHERE action={lit(a)}"))
check("no sign-in audit rows any more (identity is the IdP's job): no VERIFY / REVIEWER_VERIFY",
      na("VERIFY") == 0 and na("REVIEWER_VERIFY") == 0)
check("audit logged card-block proposals + blocks", na("CARD_BLOCK_PROPOSED") >= 1 and na("CARD_BLOCKED") == 2,
      (na("CARD_BLOCK_PROPOSED"), na("CARD_BLOCKED")))
check("audit logged dispute proposals + filings", na("DISPUTE_PROPOSED") >= 1 and na("DISPUTE_FILED") == 4,
      (na("DISPUTE_PROPOSED"), na("DISPUTE_FILED")))
check("audit logged service cases (incl. trigger fraud cases)", na("SERVICE_CASE_OPENED") >= 13, na("SERVICE_CASE_OPENED"))
check("every audit row carries the customer id (the verified subject the action was for)",
      one("SELECT count(*) FROM agent_audit WHERE customer_id IS NULL") == "0")
# ---- audit of the reviewer loop ----
check("audit: CASE_DECIDED rows carry the reviewer (their JWT sub) as actor and the customer as subject",
      one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND (actor NOT LIKE 'KST-%' OR actor IS NULL "
          "OR customer_id IS NULL)") == "0"
      and int(one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED'")) == int(one("SELECT count(*) FROM review_decisions")))

# ---------------------------------------------------------------- A2A agent reference tools
# dispute_triage_agent keeps lookup_merchant (checked above); the two new agents read section / term / meaning guides.
def ref_call(t, term):
    return psql(bind(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["dispute_triage_agent", "scam_signal_agent", "hardship_intake_agent"])
lm = AGENT_REF_TOOLS[0]
check("dispute_triage_agent keeps lookup_merchant: SELECT * FROM lookup_merchant(CAST(?dsc AS text)); one arg (descriptor)",
      lm["read"] == ("SELECT * FROM lookup_merchant(CAST(?dsc AS text));", [("dsc", "descriptor")]) and [a for a, _ in lm["args"]] == ["descriptor"])
ID_VALUES = [r["v"] for r in psql(
    "SELECT customer_id AS v FROM customers UNION SELECT first_name || ' ' || last_name FROM customers "
    "UNION SELECT last_name FROM customers UNION SELECT email FROM customers UNION SELECT phone FROM customers "
    "UNION SELECT account_id FROM accounts UNION SELECT account_number_masked FROM accounts UNION SELECT card_id FROM cards "
    "UNION SELECT card_number_masked FROM cards UNION SELECT loan_id FROM loans UNION SELECT payee_id FROM payees "
    "UNION SELECT payee_name FROM payees UNION SELECT account_masked FROM payees UNION SELECT reviewer_id FROM reviewers "
    "UNION SELECT display_name FROM reviewers UNION SELECT case_id FROM service_cases "
    "UNION SELECT payment_id FROM payment_requests UNION SELECT dispute_id FROM disputes UNION SELECT transaction_id FROM transactions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 60, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_scam_signal_guide": ("screen-sharing", "REMOTE_ACCESS", "review step", 6),
    "get_hardship_guide": ("laid off", "JOB_LOSS", "support line", 1),
}
for t in GUIDE_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)}, about 20-35)", 15 <= len(full) <= 35, len(full))
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
    check(f"{tool}: '%' and '_' are literal (the guide has no '%', so 0 rows; never a wildcard)",
          ref_call(t, "%") == [] and ref_call(t, "_%_") == [] and not any("%" in f"{r['term']} {r['meaning']}" for r in full))
    check(f"{tool}: SQL-looking input is just a string -> 0 rows, table intact",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and int(one(f"SELECT count(*) FROM {t['table']}")) > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no customer / account / card / loan / payee / reviewer / case / payment value in the rows",
          not leaked, leaked[:5])
    check(f"{tool}: no id, email or token pattern",
          not re.search(r"cust-\d|\bacc-\d|card-\d|txn-\d|case-\d|kst-\d|pye-\d|pay-\d|loan-\d|dsp-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

scam = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_scam_signals")
g = ref_call(scam, "")
hi = {r["term"] for r in g if r["section"] == "HIGH_RISK"}
ca = {r["term"] for r in g if r["section"] == "CAUTION"}
check("ref_scam_signals: several words in one call ('safe account, gift cards') -> both indicators",
      {"SAFE_ACCOUNT", "CRYPTO_OR_GIFT_CARDS"} <= {r["term"] for r in ref_call(scam, "safe, gift cards")})
acc = psql("SELECT * FROM scam_assessment('CUST-2026-00106', 'ACC-1009', 'PYE-0201', 100, "
           + lit(", ".join(sorted(hi | ca))) + ", '0')")[0]
check("ref_scam_signals: every HIGH_RISK / CAUTION term is an indicator scam_assessment() accepts (and nothing else is)",
      acc["narrative_indicators"] == ", ".join(sorted(hi | ca)) and not acc["ignored_indicators"] and len(hi) == 5 and len(ca) == 6, acc)
check("ref_scam_signals: every REVIEW_STEP is for a named indicator",
      {r["term"] for r in g if r["section"] == "REVIEW_STEP"} <= hi | ca)
pt = psql("SELECT pg_get_constraintdef(oid) AS v FROM pg_constraint WHERE conname = 'payees_payee_type_check'")[0]["v"]
check("ref_scam_signals: every payee type the payees table allows is explained (PAYEE_TYPE)",
      {r["term"] for r in g if r["section"] == "PAYEE_TYPE"} == set(re.findall(r"'([A-Z_]+)'", pt)), pt)
wd = ref_call(scam, "who decides")
check("ref_scam_signals: WHO_DECIDES comes from service_teams (PAYMENT_HOLD -> Fraud Operations)",
      len(wd) == 1 and "Fraud Operations" in wd[0]["meaning"] and wd[0]["term"] == one("SELECT label FROM service_teams WHERE request_type='PAYMENT_HOLD'"), wd)
psql("UPDATE service_teams SET label = label || ' (test)' WHERE request_type = 'PAYMENT_HOLD'")
check("ref_scam_signals: a service_teams edit shows up in WHO_DECIDES (no copy)", ref_call(scam, "who decides")[0]["term"].endswith("(test)"))
psql("UPDATE service_teams SET label = replace(label, ' (test)', '') WHERE request_type = 'PAYMENT_HOLD'")
check("ref_scam_signals: the standard reviewer step sentence lives in the table",
      any(r["meaning"].startswith("Call the customer back on the phone number on file, explain that no bank uses safe accounts")
          for r in ref_call(scam, "review step")))

hard = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_hardship_guide")
g = ref_call(hard, "")
prod = {r["term"] for r in g if r["section"] == "PRODUCT"}
codes = {r["v"] for r in psql("SELECT DISTINCT loan_type AS v FROM loans UNION SELECT DISTINCT account_type FROM accounts")}
check("ref_hardship_guide: every loan and account type the agent can be sent is explained (PRODUCT)", codes <= prod, codes - prod)
check("ref_hardship_guide: every CAUSE has its own DOCUMENT row",
      {r["term"] for r in g if r["section"] == "CAUSE"} == {r["term"] for r in g if r["section"] == "DOCUMENT"})
check("ref_hardship_guide: the 3-payment deferral program matches deferral_max_payments()",
      any(r["term"] == "PAYMENT_DEFERRAL_3M" and "up to 3 monthly payments" in r["meaning"] for r in g)
      and one("SELECT deferral_max_payments()") == "3")
check("ref_hardship_guide: several words in one call ('divorce, flood') -> both causes",
      {"SEPARATION_DIVORCE", "NATURAL_DISASTER"} <= {r["term"] for r in ref_call(hard, "divorce, flood")})
wd = ref_call(hard, "who decides")
check("ref_hardship_guide: WHO_DECIDES comes from service_teams (LOAN_HARDSHIP -> Financial Support)",
      len(wd) == 1 and "Financial Support" in wd[0]["meaning"], wd)
check("ref_hardship_guide: the standard support line lives in the table",
      [r["meaning"] for r in ref_call(hard, "support line")] ==
      ["You do not have to work this out alone: Kestrel's Financial Support team can also arrange a free, confidential talk "
       "with an independent credit counselor."])

# nothing from the design brief is lost: the facts each agent must work from are in its table
KEEP = {"get_scam_signal_guide": [
            "the bank, the police, a government agency", "spoofed", "\"safe\", \"secure\" or \"holding\" account",
            "screen-sharing", "keep the payment secret", "cover story", "one-time passcodes", "pay immediately",
            "guaranteed, very high or very fast returns", "never met in person", "new bank details", "unusually low price",
            "gift cards", "crypto exchange", "between 70 and 100", "between 30 and 69", "between 0 and 29",
            "quote the customer's own words", "no bank uses safe accounts", "registered with the financial regulator"],
        "get_hardship_guide": [
            "lost their job", "earns less", "surgery", "divorce", "death of a partner", "flood", "up to 3 months",
            "3 to 6 months", "does not know yet", "mortgage", "auto loan", "personal loan", "credit card", "defers up to 3 monthly payments",
            "interest keeps accruing", "lowers the monthly payment", "waives overdraft and late-payment fees",
            "independent non-profit credit counselor", "layoff letter", "death certificate", "fema", "no diagnosis details",
            "never guess a diagnosis", "a financial support specialist decides", "care note"]}
for t in GUIDE_TOOLS:
    blob = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k.lower() not in blob]
    check(f"{t['tool']}: every fact the agent needs is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args, "
           "p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang JOIN pg_namespace ns ON ns.oid = p.pronamespace "
           "WHERE ns.nspname = 'public' AND (p.proname LIKE 'ref\\_%' OR p.proname = 'lookup_merchant')")
names = {f["proname"] for f in fns}
check("agent read functions: ref_match + one ref_* per guide agent + lookup_merchant",
      names == {"ref_match", "lookup_merchant"} | {t["fn"] for t in GUIDE_TOOLS}, names)
for f in fns:
    check(f"{f['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          f["lanname"] == "sql" and f["provolatile"] in ("s", "i") and f["prosecdef"] == "f"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", f["prosrc"], re.I),
          {k: f[k] for k in ("lanname", "provolatile", "prosecdef")})
    if f["proname"] not in ("ref_match",):
        check(f"{f['proname']}: one optional, non-identity argument", f["args"] in ("p_term text", "p_descriptor text"), f["args"])

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
check("reset_data.sql reloads the agent reference tables, reviewers, payees and the seeded open cases",
      all(int(one(f"SELECT count(*) FROM {t['table']}")) > 0 for t in AGENT_REF_TOOLS)
      and one("SELECT count(*) FROM reviewers") == "3" and one("SELECT count(*) FROM payees") == "5"
      and one("SELECT count(*) FROM service_cases WHERE status='OPEN'") == "4"
      and one("SELECT count(*) FROM agent_audit") == "0")

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{passes + fails} checks, DB reset)")
sys.exit(1 if fails else 0)
