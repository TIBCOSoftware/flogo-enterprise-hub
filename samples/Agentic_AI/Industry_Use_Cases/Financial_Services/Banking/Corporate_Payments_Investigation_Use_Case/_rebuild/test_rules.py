#!/usr/bin/env python3
"""Step 1: run the EXACT tool SQL from tool_spec.py against the payments_governed DB and assert the business rules -
identity, scoping, two-step traces / recalls / cash applications / payments, the delivery-estimate arithmetic, the
cash-application split and the payee name-check bands, the routed cases, the full reviewer loop (every reason code,
parked actions executed on approval), minimum-necessary outputs, and the A2A agents' read-only reference tools.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> PG_DB=payments_governed python _rebuild/test_rules.py   (PSQL env var overrides the psql path)
"""
import os, re, subprocess, sys, csv, io, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import (TOOLS, LOOKUP_REASON_CODE, AGENT_REF_TOOLS, GUIDE_TOOLS, REF_COLUMNS, HIDDEN_COLUMNS,
                       HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS, PUBLIC_TOOLS)

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
        "-d", os.environ.get("PG_DB", "payments_governed"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = passes = 0
OUTPUTS = []          # (tool, rows) of every call - minimum-necessary checks at the end

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
check("22 MCP tools (18 client + 4 reviewer)", len(TOOLS) == 22 and len(REVIEWER_TOOLS & set(T)) == 4, [t["tool"] for t in TOOLS])
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
            ok = ok and re.match(r"INSERT INTO \w+ \([^)]*\) SELECT (\*|client_id) FROM \w+\(", sql) is not None
        check(f"{t['tool']}.{part}: CAST-wrapped unique placeholders, no VALUES, no audit", ok, sql)
check("verify_client takes client_id first", T["verify_client"]["args"][0][0] == "client_id")
check("every other tool except the two verify tools takes session_token first",
      all(t["args"][0][0] == "session_token" for t in TOOLS if t["tool"] not in PUBLIC_TOOLS))
check("status/timeline/delivery take session_token + payment_ref",
      all([a for a, _ in T[x]["args"]] == ["session_token", "payment_ref"]
          for x in ("get_payment_status", "get_payment_timeline", "check_delivery_estimate")))
check("MCP hints: reads readOnly, decide_review_case not idempotent / not destructive",
      all(T[x]["readonly"] for x in ("get_my_payments", "get_review_queue", "get_review_case", "get_open_invoices",
                                     "check_payee_account", "get_my_cases"))
      and T["decide_review_case"]["readonly"] is False and T["decide_review_case"].get("idempotent") is False
      and not T["decide_review_case"].get("destructive", False))

# ---- identity ----
r = call("verify_client", client_id="CLI-2026-00101", passcode="000000")
check("wrong passcode -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_client", client_id=" cli-2026-00101 ", passcode="486201")
check("right id+passcode -> VERIFIED + token + name", r[0]["status"] == "VERIFIED" and r[0]["session_token"]
      and r[0]["legal_name"] == "Northwind Manufacturing", r)
northwind = r[0]["session_token"]
helios = call("verify_client", client_id="CLI-2026-00102", passcode="730955")[0]["session_token"]
veridian = call("verify_client", client_id="CLI-2026-00103", passcode="615338")[0]["session_token"]
bramwell = call("verify_client", client_id="CLI-2026-00104", passcode="904177")[0]["session_token"]
check("all 4 seeded passcodes verify", all([northwind, helios, veridian, bramwell]))
r = call("verify_client", client_id="CLI-2026-99999", passcode="486201")
check("unknown client id -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
check("unknown id is not tracked in verify_attempts",
      one("SELECT count(*) FROM verify_attempts WHERE client_id='CLI-2026-99999'") == "0")
r = call("verify_client", client_id="CLI-2026-00104", passcode="486201")
check("Northwind's passcode does not open Bramwell", r[0]["status"] == "NOT_VERIFIED", r)

# ---- SESSION_INVALID on every scoped client tool ----
for t in TOOLS:
    if t["tool"] in PUBLIC_TOOLS or t["tool"] in REVIEWER_TOOLS:
        continue
    args = {a: "x" for a, _ in t["args"]}
    args["session_token"] = "not-a-token"
    row = call(t["tool"], **args)[0]
    code = (row.get("session_status") or row.get("lookup_status") or row.get("reason_code")
            or row.get("send_status") or row.get("outcome"))
    check(f"{t['tool']} with bad token -> SESSION_INVALID", code == "SESSION_INVALID", row)

# ---- scoped reads ----
r = call("get_my_payments", session_token=northwind, search="")
ids = [x["payment_ref"] for x in r]
check("empty search: Northwind's recent payments, newest first", {"PMT-2026-000001", "PMT-2026-000002",
      "PMT-2026-000003", "PMT-2026-000004", "PMT-2026-000005", "PMT-2026-000013"} <= set(ids) and r[0]["session_status"] == "OK", ids)
check("no other client's payment in Northwind's list",
      not ({"PMT-2026-000006", "PMT-2026-000009", "PMT-2026-000012", "PMT-2026-000015"} & set(ids)), ids)
r = call("get_my_payments", session_token=northwind, search="Pacific Components")
check("search by beneficiary -> PMT-2026-000001", [x["payment_ref"] for x in r] == ["PMT-2026-000001"], r)
r = call("get_my_payments", session_token=northwind, search="48500")
check("search by amount -> PMT-2026-000002", [x["payment_ref"] for x in r] == ["PMT-2026-000002"], r)
r = call("get_my_payments", session_token=northwind, search="Harbor Retail")
check("search by payer -> the incoming PMT-2026-000013 with its remittance text and payer",
      [x["payment_ref"] for x in r] == ["PMT-2026-000013"] and r[0]["direction"] == "INCOMING"
      and r[0]["ordering_party"] == "Harbor Retail Group" and "4417/4425" in r[0]["remittance_info"]
      and r[0]["beneficiary_name"] == "own account"
      and not r[0]["cash_application_id"], r)
r = call("get_my_payments", session_token=northwind, search="Rotterdam Shipping")
check("Northwind cannot find Bramwell's beneficiary (NO_MATCH)",
      r[0]["session_status"] == "NO_MATCH" and not r[0]["payment_ref"], r)

r = call("get_payment_status", session_token=northwind, payment_ref="PMT-2026-000002")
check("returned payment decodes AC04", r[0]["status"] == "RETURNED" and r[0]["return_reason_code"] == "AC04"
      and "closed" in (r[0]["return_reason_plain"] or "").lower(), r)
r = call("get_payment_status", session_token=northwind, payment_ref="PMT-2026-000012")
check("cross-client status -> NOT_YOUR_PAYMENT", r[0]["lookup_status"] == "NOT_YOUR_PAYMENT", r)
r = call("get_payment_timeline", session_token=northwind, payment_ref="PMT-2026-000001")
check("timeline lists events in order", [x["action"] for x in r][:2] == ["INITIATED", "DEBITED"]
      and r[0]["lookup_status"] == "OK", r)
r = call("get_payment_timeline", session_token=northwind, payment_ref="PMT-2026-000012")
check("cross-client timeline -> NOT_YOUR_PAYMENT", r[0]["lookup_status"] == "NOT_YOUR_PAYMENT", r)

# ---- delivery estimate (ARITHMETIC in SQL): all four outcomes ----
def est(tok, ref):
    return call("check_delivery_estimate", session_token=tok, payment_ref=ref)[0]
check("Veridian PMT-...10 -> ON_TRACK", est(veridian, "PMT-2026-000010")["outcome"] == "ON_TRACK",
      est(veridian, "PMT-2026-000010"))
check("Northwind PMT-...05 -> PAST_CUTOFF", est(northwind, "PMT-2026-000005")["outcome"] == "PAST_CUTOFF",
      est(northwind, "PMT-2026-000005"))
check("Helios PMT-...08 -> DELAYED", est(helios, "PMT-2026-000008")["outcome"] == "DELAYED",
      est(helios, "PMT-2026-000008"))
check("Northwind PMT-...03 -> SETTLED", est(northwind, "PMT-2026-000003")["outcome"] == "SETTLED",
      est(northwind, "PMT-2026-000003"))
check("delivery estimate is cross-client scoped -> NOT_YOUR_PAYMENT",
      est(northwind, "PMT-2026-000012")["outcome"] == "NOT_YOUR_PAYMENT", est(northwind, "PMT-2026-000012"))

# ---- agent tool: lookup_reason_code (code only, no identity) ----
def rc(code):
    return psql(sub(*LOOKUP_REASON_CODE["read"], {"code": code}))
ALL_CODES = ["AC04", "AC06", "BE01", "AM05", "RR04", "MS03", "RC01"]
for code in ALL_CODES:
    m = rc(code)[0]
    check(f"lookup_reason_code decodes {code}", m["match_status"] == "OK" and m["code"] == code
          and m["plain_language"] and m["category"], m)
check("AC04 -> account closed, ACCOUNT", "closed" in rc("ac04")[0]["plain_language"].lower()
      and rc("AC04")[0]["category"] == "ACCOUNT", rc("AC04"))
check("BE01 -> beneficiary mismatch, BENEFICIARY", "beneficiary" in rc("be01")[0]["plain_language"].lower()
      and rc("BE01")[0]["category"] == "BENEFICIARY", rc("BE01"))
check("unknown code -> NO_MATCH", rc("ZZ99")[0]["match_status"] == "NO_MATCH", rc("ZZ99"))
check("lookup_reason_code takes only a code", [a for a, _ in LOOKUP_REASON_CODE["args"]] == ["code"])

# ---- trace guards ----
def ptrace(tok, ref, reason="MS03", stmt="Where is my payment?"):
    return call("propose_trace", session_token=tok, payment_ref=ref, reason_code=reason, client_statement=stmt)[0]
def ctrace(tok, act):
    return call("confirm_trace", session_token=tok, action_id=act)[0]
check("trace cross-client (Northwind on Bramwell) -> NOT_YOUR_PAYMENT",
      ptrace(northwind, "PMT-2026-000012")["reason_code"] == "NOT_YOUR_PAYMENT")
check("trace INITIATED payment -> NOT_TRACEABLE", ptrace(northwind, "PMT-2026-000004")["reason_code"] == "NOT_TRACEABLE")
check("trace a payment already under investigation -> ALREADY_UNDER_INVESTIGATION",
      "INV-2026-0001" in ptrace(helios, "PMT-2026-000008")["reason"])
check("trace with unknown reason -> BAD_REASON", ptrace(northwind, "PMT-2026-000001", "ZZ99")["reason_code"] == "BAD_REASON")
check("no pending action written by any refused trace", one("SELECT count(*) FROM pending_actions") == "0")

# ---- trace happy path (Northwind PMT-...01, the delayed IN_TRANSIT payment) ----
exp3 = one("SELECT add_business_days(current_date, 3)")
t1 = ptrace(northwind, "PMT-2026-000001", "MS03", "My 250k USD payment to Pacific Components has not arrived.")
t2 = ptrace(northwind, "PMT-2026-000001", "MS03")
check("eligible -> PROPOSED with action + amount + decoded reason + response date", t1["outcome"] == "PROPOSED"
      and t1["action_id"] and t1["amount"] == "250000.00" and t1["beneficiary_name"] == "Pacific Components Ltd"
      and t1["decoded_reason"] and t1["est_response_date"] == exp3, t1)
check("re-propose idempotent (same action)", t1["action_id"] == t2["action_id"], (t1, t2))
check("payment still IN_TRANSIT before confirm", one("SELECT status FROM payments WHERE payment_ref='PMT-2026-000001'") == "IN_TRANSIT")
tr_act = t1["action_id"]
check("confirm bogus id -> NO_SUCH_PROPOSAL", ctrace(northwind, "ACT-00000000")["reason_code"] == "NO_SUCH_PROPOSAL")
check("confirm by another client -> NO_SUCH_PROPOSAL", ctrace(helios, tr_act)["reason_code"] == "NO_SUCH_PROPOSAL")
c1 = ctrace(northwind, tr_act.lower())
check("confirm -> OPENED INV-2026-0002 (sequence continues after seeded 0001)", c1["outcome"] == "OPENED"
      and c1["investigation_id"] == "INV-2026-0002" and c1["est_response_date"] == exp3, c1)
c2 = ctrace(northwind, tr_act)
check("re-confirm -> ALREADY_EXECUTED, one investigation row", c2["reason_code"] == "ALREADY_EXECUTED"
      and c2["investigation_id"] == "INV-2026-0002"
      and one("SELECT count(*) FROM investigations WHERE payment_ref='PMT-2026-000001'") == "1", c2)
check("trigger: payment_event INVESTIGATION OPENED written",
      one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000001' AND action='INVESTIGATION OPENED'") == "1")
check("trigger: audit TRACE_OPENED for INV-2026-0002",
      one("SELECT count(*) FROM agent_audit WHERE action='TRACE_OPENED' AND ref='INV-2026-0002'") == "1")
check("now PMT-...01 -> ALREADY_UNDER_INVESTIGATION", ptrace(northwind, "PMT-2026-000001")["reason_code"] == "ALREADY_UNDER_INVESTIGATION")

# trace expiry
tx = ptrace(veridian, "PMT-2026-000010", "AM05", "I think we paid this twice.")
check("Veridian trace -> PROPOSED", tx["outcome"] == "PROPOSED", tx)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(tx['action_id'])}")
r = ctrace(veridian, tx["action_id"])
check("expired trace proposal -> EXPIRED, nothing opened", r["reason_code"] == "EXPIRED"
      and one("SELECT count(*) FROM investigations WHERE payment_ref='PMT-2026-000010'") == "0", r)

# ---- recall guards ----
def precall(tok, ref, reason="BE01", stmt="This went to the wrong company."):
    return call("propose_recall", session_token=tok, payment_ref=ref, reason_code=reason, client_statement=stmt)[0]
def crecall(tok, act):
    return call("confirm_recall", session_token=tok, action_id=act)[0]
check("recall cross-client (Northwind on Bramwell) -> NOT_YOUR_PAYMENT",
      precall(northwind, "PMT-2026-000012")["reason_code"] == "NOT_YOUR_PAYMENT")
check("recall an INCOMING payment -> NOT_RECALLABLE", precall(veridian, "PMT-2026-000009")["reason_code"] == "NOT_RECALLABLE")
check("recall a payment completed > 5 business days ago -> NOT_RECALLABLE",
      precall(veridian, "PMT-2026-000011")["reason_code"] == "NOT_RECALLABLE")
check("recall with unknown reason -> BAD_REASON", precall(helios, "PMT-2026-000006", "ZZ99")["reason_code"] == "BAD_REASON")
check("recall a payment already RECALL_REQUESTED (seeded PMT-...14) -> ALREADY_RECALL_REQUESTED",
      precall(northwind, "PMT-2026-000014", "AM05")["reason_code"] == "ALREADY_RECALL_REQUESTED")
check("no pending recall written by any refused proposal",
      one("SELECT count(*) FROM pending_actions WHERE action_type='RECALL'") == "0")

# ---- recall happy path (Helios PMT-...06, wrong beneficiary) -> a Payment Operations case that PARKS the recall ----
rr1 = precall(helios, "PMT-2026-000006", "BE01", "We sent 780k USD to the wrong beneficiary.")
rr2 = precall(helios, "PMT-2026-000006", "BE01")
check("eligible -> PROPOSED, recall is a request (not auto-reversed)", rr1["outcome"] == "PROPOSED"
      and rr1["action_id"] and rr1["amount"] == "780000.00" and "not" in rr1["reason"].lower(), rr1)
check("re-propose idempotent (same action)", rr1["action_id"] == rr2["action_id"], (rr1, rr2))
check("payment still IN_TRANSIT before confirm", one("SELECT status FROM payments WHERE payment_ref='PMT-2026-000006'") == "IN_TRANSIT")
rc_act = rr1["action_id"]
check("confirm bogus recall id -> NO_SUCH_PROPOSAL", crecall(helios, "ACT-00000000")["reason_code"] == "NO_SUCH_PROPOSAL")
check("confirm recall by another client -> NO_SUCH_PROPOSAL", crecall(northwind, rc_act)["reason_code"] == "NO_SUCH_PROPOSAL")
s1 = crecall(helios, rc_act.lower())
check("confirm -> SUBMITTED with a CASE- id, Payment Operations", s1["outcome"] == "SUBMITTED"
      and re.fullmatch(r"CASE-\d{5}", s1["case_id"] or "") and s1["assigned_team"] == "Payment Operations", s1)
helios_case = s1["case_id"]
s2 = crecall(helios, rc_act)
check("re-confirm -> ALREADY_EXECUTED, one review case for the action", s2["reason_code"] == "ALREADY_EXECUTED"
      and s2["case_id"] == helios_case
      and one(f"SELECT count(*) FROM review_cases WHERE action_id={lit(rc_act)}") == "1", s2)
check("trigger: payment set RECALL_REQUESTED (and remembers it was IN_TRANSIT)",
      psql("SELECT status, status_before_recall FROM payments WHERE payment_ref='PMT-2026-000006'")
      == [{"status": "RECALL_REQUESTED", "status_before_recall": "IN_TRANSIT"}])
rvc = psql(f"SELECT request_type, assigned_team, client_id, payment_ref, currency, requested_amount, parked_action, status "
           f"FROM review_cases WHERE case_id={lit(helios_case)}")
check("trigger: RECALL case -> Payment Operations, Helios, PMT-...06, parks RECALL:PMT-...06 for USD 780,000",
      len(rvc) == 1 and rvc[0] == {"request_type": "RECALL", "assigned_team": "Payment Operations", "client_id": "CLI-2026-00102",
                                    "payment_ref": "PMT-2026-000006", "currency": "USD", "requested_amount": "780000.00",
                                    "parked_action": "RECALL:PMT-2026-000006", "status": "OPEN"}, rvc)
check("trigger: payment_event RECALL REQUESTED written",
      one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000006' AND action='RECALL REQUESTED'") == "1")
check("trigger: audit RECALL_SUBMITTED for the case",
      one(f"SELECT count(*) FROM agent_audit WHERE action='RECALL_SUBMITTED' AND ref={lit(helios_case)}") == "1")
check("now PMT-...06 -> ALREADY_RECALL_REQUESTED", precall(helios, "PMT-2026-000006")["reason_code"] == "ALREADY_RECALL_REQUESTED")

# recall expiry
rx = precall(helios, "PMT-2026-000007", "RR04", "Please recall the held payment.")
check("Helios recall on HELD payment -> PROPOSED", rx["outcome"] == "PROPOSED", rx)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(rx['action_id'])}")
r = crecall(helios, rx["action_id"])
check("expired recall proposal -> EXPIRED, payment untouched", r["reason_code"] == "EXPIRED"
      and one("SELECT status FROM payments WHERE payment_ref='PMT-2026-000007'") == "HELD", r)

# ---- human-owned requests (open_review_case) ----
def case(tok, ty, stmt="Please help with this.", brief="Client request; routed for a human to decide.", ref=""):
    return call("open_review_case", session_token=tok, request_type=ty, client_statement=stmt, brief=brief, reference_id=ref)[0]
r = case(helios, "COMPENSATION", ref="PMT-2026-000012")
check("a reference that is another client's payment -> BAD_REFERENCE", r["outcome"] == "NOT_OPENED"
      and r["reason_code"] == "BAD_REFERENCE", r)
r = case(helios, "FEE_WAIVER", ref="PMT-2026-000007")
check("FEE_WAIVER on a payment with no fee -> BAD_REFERENCE", r["reason_code"] == "BAD_REFERENCE", r)
r = case(bramwell, "RECALL")
check("RECALL is not opened here (it goes through propose/confirm_recall) -> BAD_TYPE",
      r["outcome"] == "NOT_OPENED" and r["reason_code"] == "BAD_TYPE" and "propose_recall" in r["reason"], r)
ROUTING = {"PAYMENT_REPAIR": ("Payment Operations", "1"), "COMPENSATION": ("Client Servicing", "2"),
           "FRAUD": ("Financial Crime", "1"), "SANCTIONS_QUERY": ("Sanctions & Compliance", "2"),
           "OTHER": ("Client Servicing", "3")}
for ty, (team, days) in ROUTING.items():
    k = case(bramwell, ty)
    check(f"open_review_case {ty} -> {team}, {days} business days, nothing parked", k["outcome"] == "CASE_OPENED"
          and re.fullmatch(r"CASE-\d{5}", k["case_id"] or "") and k["assigned_team"] == team
          and k["reply_within_business_days"] == days and not k["requested_amount"], k)
bramwell_comp = one("SELECT case_id FROM review_cases WHERE client_id='CLI-2026-00104' AND request_type='COMPENSATION'")
k = case(bramwell, "FEE_WAIVER", "Please refund the SWIFT fee.")
check("Bramwell FEE_WAIVER: the seeded CASE-00003 already parks that fee -> ALREADY_OPEN, no second case",
      k["outcome"] == "ALREADY_OPEN" and k["case_id"] == "CASE-00003"
      and one("SELECT count(*) FROM review_cases WHERE client_id='CLI-2026-00104' AND request_type='FEE_WAIVER'") == "1", k)
k = case(veridian, "fee waiver", "There is an unexpected 45 USD fee on my ACH payment.")
check("Veridian FEE_WAIVER (normalised, no reference) -> Client Servicing, parks the latest fee: PMT-...10 $45",
      k["outcome"] == "CASE_OPENED" and k["assigned_team"] == "Client Servicing" and k["reply_within_business_days"] == "2"
      and k["payment_ref"] == "PMT-2026-000010" and k["requested_amount"] == "45.00" and k["currency"] == "USD"
      and "refunded" in (k["if_approved"] or ""), k)
veridian_fee_case = k["case_id"]
check("DB: Veridian's case parks FEE_REFUND:PMT-2026-000010",
      one(f"SELECT parked_action FROM review_cases WHERE case_id = {lit(veridian_fee_case)}") == "FEE_REFUND:PMT-2026-000010")
check("duplicate case suppressed (same case id)", case(veridian, "FEE_WAIVER")["case_id"] == veridian_fee_case)
k = case(helios, "SANCTIONS_QUERY", "Why is my payment held for sanctions screening?", ref="PMT-2026-000007")
check("Helios SANCTIONS_QUERY -> Sanctions & Compliance, linked to PMT-...07", k["assigned_team"] == "Sanctions & Compliance"
      and k["payment_ref"] == "PMT-2026-000007", k)
r = case(bramwell, "REFUND")
check("bad request type -> BAD_TYPE", r["outcome"] == "NOT_OPENED" and r["reason_code"] == "BAD_TYPE", r)
check("every case has a reply-due time from the routing table",
      one("SELECT count(*) FROM review_cases WHERE sla_due_at IS NULL") == "0")

# ---- my cases (investigations + review cases) ----
r = call("get_my_cases", session_token=northwind)
refs = {x["reference_id"]: x for x in r}
check("Northwind sees its investigation INV-2026-0002 and the seeded recall CASE-00001", "INV-2026-0002" in refs
      and refs["INV-2026-0002"]["case_type"] == "INVESTIGATION" and r[0]["session_status"] == "OK"
      and refs.get("CASE-00001", {}).get("status") == "OPEN", r)
check("Northwind does not see Helios's seeded investigation", "INV-2026-0001" not in refs, refs.keys())
r = call("get_my_cases", session_token=helios)
refs = {x["reference_id"]: x for x in r}
check("Helios sees seeded INV-2026-0001, its recall case and the seeded deduction case", "INV-2026-0001" in refs
      and helios_case in refs and refs[helios_case]["case_type"] == "REVIEW_CASE" and "CASE-00004" in refs, r)
r = call("get_my_cases", session_token=bramwell)
check("Bramwell has review cases but no investigation", all(x["case_type"] == "REVIEW_CASE" for x in r if x["reference_id"])
      and r[0]["session_status"] == "OK", r)

# ---- email confirmation (guarded; every SEND is logged, NOT_SENT never is) ----
def mail(tok, ref):
    return call("email_my_confirmation", session_token=tok, reference_id=ref)[0]
e = mail(northwind, "INV-2026-0002")
check("email SEND for Northwind's investigation", e["send_status"] == "SEND" and "INV-2026-0002" in e["subject"]
      and "INV-2026-0002" in e["body"], e)
e = mail(helios, helios_case.lower())
check("email SEND for Helios's recall case", e["send_status"] == "SEND" and helios_case in e["subject"], e)
e = mail(northwind, "INV-2026-0001")
check("email NOT_SENT for Helios's investigation (NO_SUCH_REFERENCE)", e["send_status"] == "NOT_SENT"
      and e["reason_code"] == "NO_SUCH_REFERENCE", e)
e = mail(northwind, helios_case)
check("email NOT_SENT for Helios's case from Northwind", e["send_status"] == "NOT_SENT"
      and e["reason_code"] == "NO_SUCH_REFERENCE", e)
e = mail(northwind, "ACT-00000000")
check("email NOT_SENT for a non-reference", e["send_status"] == "NOT_SENT" and e["reason_code"] == "NO_SUCH_REFERENCE", e)
check("email_log holds exactly the 2 SEND requests", one("SELECT count(*) FROM email_log") == "2")

# ---- cash application (remittance_match_agent output validated + split in SQL; two steps) ----
def invoices(tok, q=""):
    return call("get_open_invoices", session_token=tok, search=q)
r = invoices(northwind)
check("Northwind's open invoices, oldest first (5), none of Helios's",
      [x["invoice_no"] for x in r] == ["4398", "4433", "4417", "4425", "4431"] and r[0]["session_status"] == "OK", [x["invoice_no"] for x in r])
check("an invoice row carries terms and the early-pay date (2/10 NET 30 -> invoice date + 10)",
      next(x for x in r if x["invoice_no"] == "4417")["terms"] == "2/10 NET 30"
      and next(x for x in r if x["invoice_no"] == "4417")["early_pay_until"] == one("SELECT current_date + 3")
      and not next(x for x in r if x["invoice_no"] == "4433")["early_pay_until"])
check("search by buyer -> Summit's invoice only", [x["invoice_no"] for x in invoices(northwind, "summit")] == ["4433"])
check("Helios sees only its OPEN invoice 7715 (7702 is SHORT_PAID after the seeded application)",
      [x["invoice_no"] for x in invoices(helios)] == ["7715"])
REMIT = "INV 4417/4425 less 2% early pay + freight dispute $312"
NOTES = ("invoices: 4417, 4425\ndeductions: EARLY_PAY_DISCOUNT; FREIGHT 312.00\nconfidence: HIGH\n"
         "explanation: The note names invoices 4417 and 4425, takes the 2 percent early-payment discount and deducts 312.00 freight.\n"
         "review_note: Deductions stay recorded as claims against the buyer until Aurelia Client Servicing accepts or rejects them; "
         "the invoice remains open for the disputed amount in the meantime.")
def pcash(tok, ref, inv="4417, 4425", ded="EARLY_PAY_DISCOUNT; FREIGHT 312.00", conf="HIGH", rem=REMIT, notes=NOTES):
    return call("propose_cash_application", session_token=tok, payment_ref=ref, remittance_text=rem, invoice_numbers=inv,
                deductions=ded, confidence=conf, agent_notes=notes)[0]
def ccash(tok, app):
    return call("confirm_cash_application", session_token=tok, application_id=app)[0]
n_cap = one("SELECT count(*) FROM cash_applications")
r = psql("SELECT * FROM cash_assessment('CLI-2026-00101', 'PMT-2026-000013', '4417, 4425', 'FREIGHT 312', 'HIGH')")[0]
check("cash_assessment: a discount the note does not claim is never granted (the gap is UNAPPLIED and disputed)",
      r["discount_accepted"] == "0" and "UNAPPLIED $960.00" in r["deductions"] and r["review_amount"] == "1272.00", r)
r = psql("SELECT * FROM cash_assessment('CLI-2026-00101', 'PMT-2026-000013', '4417, 4425', 'EARLY_PAY_DISCOUNT', 'HIGH')")[0]
check("cash_assessment: a claimed discount above what the terms allow -> only $960 earned, the rest disputed as not earned",
      r["discount_accepted"] == "960.00" and "not earned" in r["deductions"] and r["disputed_amount"] == "312.00", r)
for label, args, code in (
        ("another client's payment", dict(tok=northwind, ref="PMT-2026-000012"), "NOT_YOUR_PAYMENT"),
        ("an outgoing payment", dict(tok=northwind, ref="PMT-2026-000001"), "NOT_INCOMING"),
        ("an incoming payment still in transit", dict(tok=veridian, ref="PMT-2026-000009", inv="9999"), "FUNDS_NOT_RECEIVED"),
        ("a payment already applied (seeded CAP-00001)", dict(tok=helios, ref="PMT-2026-000015", inv="7715"), "ALREADY_APPLIED"),
        ("no invoice numbers", dict(tok=northwind, ref="PMT-2026-000013", inv="NONE"), "NO_INVOICES"),
        ("an invoice that is not this client's open invoice", dict(tok=northwind, ref="PMT-2026-000013", inv="4417, 7702"), "INVOICE_NOT_OPEN"),
        ("LOW confidence", dict(tok=northwind, ref="PMT-2026-000013", conf="LOW"), "LOW_CONFIDENCE"),
        ("payment larger than the invoices", dict(tok=northwind, ref="PMT-2026-000013", inv="4417"), "OVERPAYMENT"),
        ("deductions larger than the short payment", dict(tok=northwind, ref="PMT-2026-000013", ded="FREIGHT 5000"),
         "DEDUCTIONS_EXCEED_SHORT_PAY")):
    r = pcash(**args)
    check(f"cash application on {label} -> NOT_PROPOSED {code}", r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == code, r)
check("no cash application written by any refused proposal", one("SELECT count(*) FROM cash_applications") == n_cap)
p1 = pcash(northwind, "PMT-2026-000013", inv="INV 4417/4425", ded="EARLY_PAY_DISCOUNT; FREIGHT 312.00; MYSTERY_CODE 10")
p2 = pcash(northwind, "PMT-2026-000013", inv="INV 4417/4425", ded="EARLY_PAY_DISCOUNT; FREIGHT 312.00; MYSTERY_CODE 10")
check("Harbor Retail's $46,728 -> PROPOSED: invoices 4417, 4425 ($48,000), earned discount $960, disputed freight $312 for review",
      p1["outcome"] == "PROPOSED" and p1["application_id"] == "CAP-00002" and p1["invoices"] == "4417, 4425"
      and p1["invoices_total"] == "48000.00" and p1["payment_amount"] == "46728.00" and p1["early_pay_discount_earned"] == "960.00"
      and p1["disputed_amount"] == "312.00" and p1["sent_for_review"] == "312.00" and p1["written_off_within_tolerance"] == "0.00"
      and "Client Servicing" in p1["if_confirmed"], p1)
check("re-propose idempotent (same application)", p1["application_id"] == p2["application_id"], (p1, p2))
check("DB: an unknown deduction code is recorded as ignored and never counted",
      psql("SELECT ignored_items, deductions FROM cash_applications WHERE application_id='CAP-00002'")
      == [{"ignored_items": "MYSTERY_CODE 10", "deductions": "EARLY_PAY_DISCOUNT $960.00 (earned); FREIGHT $312.00"}])
check("invoices still OPEN before confirm", one("SELECT string_agg(status, ',' ORDER BY invoice_no) FROM open_invoices "
                                                 "WHERE client_id='CLI-2026-00101' AND invoice_no IN ('4417','4425')") == "OPEN,OPEN")
check("confirm bogus application -> NO_SUCH_APPLICATION", ccash(northwind, "CAP-99999")["reason_code"] == "NO_SUCH_APPLICATION")
check("confirm by another client -> NO_SUCH_APPLICATION", ccash(helios, "CAP-00002")["reason_code"] == "NO_SUCH_APPLICATION")
a1 = ccash(northwind, "cap-00002")
check("confirm -> APPLIED: 4417 PAID, 4425 SHORT_PAID with $312 open, a Client Servicing case for the deduction",
      a1["outcome"] == "APPLIED" and re.fullmatch(r"CASE-\d{5}", a1["case_id"] or "") and a1["team"] == "Client Servicing"
      and a1["invoice_status"] == "invoice 4417 PAID; invoice 4425 SHORT_PAID ($312.00 open)", a1)
ded_case = a1["case_id"]
a2 = ccash(northwind, "CAP-00002")
check("re-confirm -> ALREADY_APPLIED, one posting", a2["reason_code"] == "ALREADY_APPLIED"
      and one("SELECT count(*) FROM cash_postings WHERE application_id='CAP-00002'") == "1", a2)
dc = psql(f"SELECT request_type, assigned_team, currency, requested_amount, parked_action, client_statement, agent_brief "
          f"FROM review_cases WHERE case_id = {lit(ded_case)}")[0]
check("trigger: DEDUCTION_REVIEW case parks DEDUCTION_WRITE_OFF:CAP-00002 for USD 312, statement = the client's note",
      dc["request_type"] == "DEDUCTION_REVIEW" and dc["assigned_team"] == "Client Servicing" and dc["currency"] == "USD"
      and dc["requested_amount"] == "312.00" and dc["parked_action"] == "DEDUCTION_WRITE_OFF:CAP-00002"
      and dc["client_statement"] == REMIT, dc)
check("trigger: the case brief carries SQL facts and the agent's notes (incl. the guide's review line)",
      "earned: $960.00" in dc["agent_brief"] and "FREIGHT $312.00" in dc["agent_brief"]
      and "Agent notes (AI-prepared, unverified)" in dc["agent_brief"] and "remains open for the disputed amount" in dc["agent_brief"], dc)
check("trigger: payment_event CASH APPLIED + audit CASH_APPLIED; payment lists the application",
      one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000013' AND action='CASH APPLIED'") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='CASH_APPLIED' AND ref='CAP-00002'") == "1"
      and call("get_my_payments", session_token=northwind, search="Harbor")[0]["cash_application_id"] == "CAP-00002")
check("the same payment cannot be applied twice -> ALREADY_APPLIED", pcash(northwind, "PMT-2026-000013")["reason_code"] == "ALREADY_APPLIED")
# within the small-balance tolerance: a test-only incoming payment of $22,220 for Helios's $22,400 invoice ($180 freight)
psql("INSERT INTO payments (payment_ref, client_id, debtor_account, direction, rail, amount, currency, fees, beneficiary_name, "
     "beneficiary_bank_bic, ordering_party, remittance_info, status, value_date, created_at) VALUES ('PMT-2026-000090', "
     "'CLI-2026-00102', 'ACC-1004', 'INCOMING', 'ACH', 22220.00, 'USD', 0, 'Helios Trading', 'CITIUS33XXX', 'Coastal Grocers Inc', "
     "'INV 7715 FRT 180', 'COMPLETED', current_date, now())")
x1 = pcash(helios, "PMT-2026-000090", inv="7715", ded="FREIGHT 180", rem="INV 7715 FRT 180")
check("$180 freight is within the $250 tolerance -> PROPOSED with $180 written off, nothing for review",
      x1["outcome"] == "PROPOSED" and x1["written_off_within_tolerance"] == "180.00" and x1["sent_for_review"] == "0.00", x1)
psql(f"UPDATE cash_applications SET expires_at = now() - interval '1 minute' WHERE application_id = {lit(x1['application_id'])}")
check("expired cash application -> EXPIRED, invoice untouched", ccash(helios, x1["application_id"])["reason_code"] == "EXPIRED"
      and one("SELECT status FROM open_invoices WHERE invoice_no='7715'") == "OPEN")
x2 = pcash(helios, "PMT-2026-000090", inv="7715", ded="FREIGHT 180", rem="INV 7715 FRT 180")
x3 = ccash(helios, x2["application_id"])
check("re-propose after expiry -> new application; confirm -> APPLIED, invoice PAID, no review case",
      x2["application_id"] != x1["application_id"] and x3["outcome"] == "APPLIED" and not x3["case_id"]
      and one("SELECT status || ' ' || open_amount FROM open_invoices WHERE invoice_no='7715'") == "PAID 0.00", x3)
u = psql("SELECT * FROM cash_assessment('CLI-2026-00102', 'PMT-2026-000090', '7715', 'NONE', 'MEDIUM')")
check("cash_assessment: an applied payment is refused even through the assessment function (ALREADY_APPLIED)",
      u[0]["reason_code"] == "ALREADY_APPLIED", u)
v = psql("SELECT * FROM cash_assessment('CLI-2026-00101', 'PMT-2026-000013', '4398', 'NONE', 'HIGH')")
check("cash_assessment: a closed application blocks re-use of the payment for other invoices", v[0]["reason_code"] == "ALREADY_APPLIED", v)

# ---- payments with verification of payee (payee_name_match_agent verdict validated + banded in SQL) ----
def chk(tok, acct, name):
    return call("check_payee_account", session_token=tok, beneficiary_account=acct, typed_name=name)[0]
r = chk(bramwell, "4410 0288 11", "ACME Corp")
check("check_payee_account -> OK with the name on file, bank, currency, rail",
      r["lookup_status"] == "OK" and r["name_on_file"] == "Acme Corporation Ltd" and r["currency"] == "USD"
      and r["rail"] == "FEDWIRE" and r["beneficiary_account"] == "4410028811", r)
r = chk(bramwell, "999999", "Someone")
check("unknown beneficiary account -> NOT_FOUND, no name", r["lookup_status"] == "NOT_FOUND" and not r["name_on_file"], r)
def ppay(tok, frm, acct, name, amt, verdict="MATCH", reasons="SUFFIX_ONLY", purpose="Invoice payment for this month.",
         notes="verdict: MATCH\nreasons: SUFFIX_ONLY\nexplanation: Only the legal-form words differ.\nverdict_note: The names are the same company."):
    return call("propose_payment", session_token=tok, from_account=frm, beneficiary_account=acct, typed_name=name, amount=amt,
                purpose=purpose, name_verdict=verdict, name_reasons=reasons, agent_notes=notes)[0]
def cpay(tok, req, ack="NO"):
    return call("confirm_payment", session_token=tok, request_id=req, acknowledge_warning=ack)[0]
n_prq = one("SELECT count(*) FROM payment_requests")
for label, args, code in (
        ("a from-account the client does not hold", (bramwell, "EUR", "4410028811", "ACME Corp", "1000"), "ACCOUNT_NOT_FOUND"),
        ("an unknown beneficiary account", (bramwell, "USD", "000111", "ACME Corp", "1000"), "BENEFICIARY_NOT_FOUND"),
        ("no beneficiary name", (bramwell, "USD", "4410028811", " ", "1000"), "NAME_REQUIRED"),
        ("a USD account to a EUR beneficiary account", (northwind, "USD", "DE44500105175407324931", "Mueller Logistik", "1000"),
         "CURRENCY_MISMATCH"),
        ("a negative amount", (bramwell, "USD", "4410028811", "ACME Corp", "-5"), "BAD_AMOUNT"),
        ("a non-numeric amount", (bramwell, "USD", "4410028811", "ACME Corp", "lots"), "BAD_AMOUNT"),
        ("more than the chat channel limit", (bramwell, "USD", "4410028811", "ACME Corp", "1500000"), "OVER_CHANNEL_LIMIT")):
    r = ppay(*args)
    check(f"payment with {label} -> NOT_PROPOSED {code}", r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == code, r)
check("no payment request written by any refused proposal", one("SELECT count(*) FROM payment_requests") == n_prq)
# the matrix (assessment only, no rows)
def pa(typed, reg_sql, amt, verdict, reasons):
    return psql(f"SELECT * FROM payee_assessment({lit(typed)}, {reg_sql}, {amt}, {lit(verdict)}, {lit(reasons)})")[0]
MULLER = "(SELECT registered_name FROM payee_register WHERE account_ref='DE44500105175407324931')"
m = pa("ACME Corp", "'Acme Corporation Ltd'", 185000, "CLOSE_MATCH", "")
check("names identical after the guide's suffix rules -> MATCH even if the agent is cautious", m["name_check"] == "MATCH"
      and m["name_score"] == "100" and m["status"] == "PROPOSED", m)
m = pa("Rotterdam Shipping BV", "'RD Global Trading LLC'", 500, "MATCH", "SUFFIX_ONLY")
check("agent says MATCH but the names are different (score < 40) -> NO_MATCH, HELD at any amount", m["name_check"] == "NO_MATCH"
      and m["status"] == "HELD", m)
m = pa("Mueller Logistik", MULLER, 5000, "MATCH", "TRANSLITERATION")
check("transliteration (Mueller vs the name on file with u-umlaut), agent MATCH, score >= 75 -> MATCH", m["name_check"] == "MATCH"
      and int(m["name_score"]) >= 75, m)
m = pa("Mueller Logistik", MULLER, 5000, "", "")
check("same names without an agent verdict -> CLOSE_MATCH with a warning (never an automatic MATCH)",
      m["name_check"] == "CLOSE_MATCH" and m["warning_required"] == "t", m)
m = pa("Atlas Freight", "'Atlas Freight Forwarding Inc'", 4800, "CLOSE_MATCH", "MISSING_WORD, MADE_UP")
check("missing word, $4,800 -> CLOSE_MATCH + warning; an unknown reason is recorded as ignored",
      m["name_check"] == "CLOSE_MATCH" and m["status"] == "PROPOSED" and m["warning_required"] == "t"
      and m["agent_reasons"] == "MISSING_WORD" and m["ignored_reasons"] == "MADE_UP", m)
m = pa("Atlas Freight", "'Atlas Freight Forwarding Inc'", 12000, "CLOSE_MATCH", "MISSING_WORD")
check("CLOSE_MATCH over the $10,000 hold threshold -> HELD", m["status"] == "HELD", m)
m = pa("Atlas Freight", "'Atlas Freight Forwarding Inc'", 4800, "MATCH", "MISSING_WORD")
check("the agent cannot upgrade a CLOSE_MATCH to MATCH (score 69 < 75)", m["name_check"] == "CLOSE_MATCH", m)
# MATCH -> two-step
y1 = ppay(bramwell, "USD", "4410028811", "ACME Corp", "185,000.00", purpose="Quarterly equipment invoice from Acme.")
y2 = ppay(bramwell, "usd", "4410028811", "ACME Corp", "185000")
check("Bramwell pays ACME Corp $185,000 -> PROPOSED, name check MATCH, name on file returned", y1["outcome"] == "PROPOSED"
      and y1["name_check"] == "MATCH" and y1["name_on_file"] == "Acme Corporation Ltd" and y1["amount"] == "185000.00"
      and y1["request_id"] == "PRQ-00002" and not y1["warning_text"], y1)
check("re-propose idempotent (same request)", y1["request_id"] == y2["request_id"], (y1, y2))
check("nothing submitted before confirm", one("SELECT count(*) FROM payments WHERE beneficiary_name='Acme Corporation Ltd'") == "0")
check("confirm bogus request -> NO_SUCH_REQUEST", cpay(bramwell, "PRQ-99999")["reason_code"] == "NO_SUCH_REQUEST")
check("confirm by another client -> NO_SUCH_REQUEST", cpay(northwind, "PRQ-00002")["reason_code"] == "NO_SUCH_REQUEST")
s = cpay(bramwell, "prq-00002")
check("confirm -> SENT as PMT-2026-000101 on FEDWIRE", s["outcome"] == "SENT" and s["payment_ref"] == "PMT-2026-000101"
      and s["rail"] == "FEDWIRE" and s["beneficiary_name"] == "Acme Corporation Ltd", s)
check("trigger: the payment row (INITIATED, Bramwell, $185,000 to the name on file) + INITIATED event + PAYMENT_SENT audit",
      psql("SELECT client_id, status, amount, beneficiary_name, direction FROM payments WHERE payment_ref='PMT-2026-000101'")
      == [{"client_id": "CLI-2026-00104", "status": "INITIATED", "amount": "185000.00", "beneficiary_name": "Acme Corporation Ltd",
           "direction": "OUTGOING"}]
      and one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000101' AND action='INITIATED'") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='PAYMENT_SENT' AND ref='PRQ-00002'") == "1")
check("re-confirm -> ALREADY_SENT, one payment", cpay(bramwell, "PRQ-00002")["reason_code"] == "ALREADY_SENT"
      and one("SELECT count(*) FROM payments WHERE beneficiary_name='Acme Corporation Ltd'") == "1")
check("the new payment is the client's own and has a delivery estimate",
      est(bramwell, "PMT-2026-000101")["lookup_status"] == "OK" and est(northwind, "PMT-2026-000101")["outcome"] == "NOT_YOUR_PAYMENT")
# NO_MATCH (business email compromise) -> HELD + Payment Operations case
BEC_NOTES = ("verdict: NO_MATCH\nreasons: DIFFERENT_NAME\nexplanation: The account belongs to RD Global Trading, not Rotterdam Shipping.\n"
             "verdict_note: The names belong to different companies. The payment must not go to this account until a person has "
             "verified the payee with the client.")
h1 = ppay(bramwell, "USD", "7781200456", "Rotterdam Shipping BV", "96500", verdict="NO_MATCH", reasons="DIFFERENT_NAME",
          purpose="Rotterdam Shipping emailed new bank details for their invoice; please pay the new account.", notes=BEC_NOTES)
check("BEC: Rotterdam Shipping BV vs RD Global Trading LLC -> HELD_FOR_REVIEW, Payment Operations, reply date, no score shown",
      h1["outcome"] == "HELD_FOR_REVIEW" and h1["name_check"] == "NO_MATCH" and h1["team"] == "Payment Operations"
      and re.fullmatch(r"CASE-\d{5}", h1["case_id"] or "") and h1["reply_by"] and "not send this money another way" in h1["reason"]
      and "score" not in json.dumps(h1).lower(), h1)
bec_case, bec_req = h1["case_id"], h1["request_id"]
bc = psql(f"SELECT request_type, parked_action, requested_amount, agent_brief FROM review_cases WHERE case_id = {lit(bec_case)}")[0]
check("trigger: PAYEE_VERIFICATION case parks RELEASE_PAYMENT:<request>, brief has both names, the score and the agent notes",
      bc["request_type"] == "PAYEE_VERIFICATION" and bc["parked_action"] == f"RELEASE_PAYMENT:{bec_req}"
      and bc["requested_amount"] == "96500.00" and "RD Global Trading LLC" in bc["agent_brief"]
      and "deterministic score" in bc["agent_brief"] and "must not go to this account" in bc["agent_brief"], bc)
check("a held payment cannot be confirmed -> HELD_FOR_REVIEW, no payment created",
      cpay(bramwell, bec_req, "YES")["reason_code"] == "HELD_FOR_REVIEW"
      and one("SELECT count(*) FROM payments WHERE beneficiary_name='RD Global Trading LLC'") == "0")
check("re-proposing the held payment returns the same held request (no second case)",
      ppay(bramwell, "USD", "7781200456", "Rotterdam Shipping BV", "96500", verdict="MATCH")["request_id"] == bec_req
      and one("SELECT count(*) FROM review_cases WHERE request_type='PAYEE_VERIFICATION' AND client_id='CLI-2026-00104'") == "1")
# CLOSE_MATCH under the threshold -> warning + acknowledgement
w1 = ppay(bramwell, "USD", "3390044127", "Atlas Freight", "4800", verdict="CLOSE_MATCH", reasons="MISSING_WORD")
check("Atlas Freight vs Atlas Freight Forwarding Inc, $4,800 -> PROPOSED_WITH_WARNING naming the account holder",
      w1["outcome"] == "PROPOSED_WITH_WARNING" and "Atlas Freight Forwarding Inc" in (w1["warning_text"] or ""), w1)
check("confirm without acknowledging -> WARNING_NOT_ACKNOWLEDGED", cpay(bramwell, w1["request_id"], "NO")["reason_code"] == "WARNING_NOT_ACKNOWLEDGED")
w2 = cpay(bramwell, w1["request_id"], "yes")
check("confirm with the acknowledgement -> SENT", w2["outcome"] == "SENT" and w2["payment_ref"] == "PMT-2026-000102", w2)
z1 = ppay(northwind, "EUR", "DE44500105175407324931", "Mueller Logistik", "15000", verdict="MATCH", reasons="TRANSLITERATION")
check("Northwind EUR to the umlaut name (agent MATCH, transliteration) -> PROPOSED", z1["outcome"] == "PROPOSED"
      and z1["currency"] == "EUR" and z1["rail"] == "SEPA", z1)
psql(f"UPDATE payment_requests SET expires_at = now() - interval '1 minute' WHERE request_id = {lit(z1['request_id'])}")
check("expired payment proposal -> EXPIRED, nothing sent", cpay(northwind, z1["request_id"])["reason_code"] == "EXPIRED"
      and one(f"SELECT payment_ref IS NULL FROM payment_requests WHERE request_id = {lit(z1['request_id'])}") == "t")

# ---- reviewer identity (same token mechanism, role checked everywhere) ----
def vrev(sid, code):
    return call("verify_reviewer", staff_id=sid, code=code)[0]
r = vrev("AGB-5001", "000000")
check("wrong staff code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = vrev("AGB-9999", "482615")
check("unknown staff id -> NOT_VERIFIED, not tracked", r["status"] == "NOT_VERIFIED"
      and one("SELECT count(*) FROM reviewer_verify_attempts WHERE reviewer_id='AGB-9999'") == "0", r)
r = vrev("agb 5001", "482615")
check("Elena (staff id typed loosely) -> VERIFIED, role REVIEWER, Payment Operations", r["status"] == "VERIFIED"
      and r["role"] == "REVIEWER" and r["team"] == "Payment Operations" and r["display_name"] == "Elena Park" and r["session_token"], r)
elena = r["session_token"]
marcus = vrev("5002", "739104")["session_token"]
sofia = vrev("AGB-5003", "615920")["session_token"]
check("Marcus and Sofia verify", bool(marcus) and bool(sofia))
check("a reviewer token is not a client token (get_my_payments -> SESSION_INVALID)",
      call("get_my_payments", session_token=elena, search="")[0]["session_status"] == "SESSION_INVALID")
check("a client token is not a reviewer token (queue -> NOT_REVIEWER)", call("get_review_queue", session_token=northwind)[0]["status"] == "NOT_REVIEWER")
check("bogus token on get_review_case -> NOT_REVIEWER", call("get_review_case", session_token="x", case_id="CASE-00001")[0]["status"] == "NOT_REVIEWER")
check("a client cannot verify as staff with their passcode", vrev("CLI-2026-00101", "486201")["status"] == "NOT_VERIFIED")

# ---- queues are scoped to the reviewer's team, ordered by reply-due time ----
def queue(tok): return call("get_review_queue", session_token=tok)
for who, tok, team in (("Elena", elena, "Payment Operations"), ("Marcus", marcus, "Payment Operations"),
                       ("Sofia", sofia, "Client Servicing")):
    qq = queue(tok)
    ids = [x["case_id"] for x in qq]
    db = [x["case_id"] for x in psql("SELECT s.case_id FROM review_cases s JOIN service_teams t USING (request_type) "
                                     f"WHERE t.team = {lit(team)} AND s.status = 'OPEN' ORDER BY s.sla_due_at, s.case_id")]
    check(f"{who}'s queue = exactly {team}'s OPEN cases, ordered by reply-due ({len(ids)})", ids == db and len(ids) >= 2
          and qq[0]["status"] == "OK", (ids, db))
qe = {x["case_id"]: x for x in queue(elena)}
check("queue row: client company, SLA status, requested amount + currency",
      qe["CASE-00001"]["client"] == "Northwind Manufacturing" and qe["CASE-00001"]["requested_amount"] == "310000.00"
      and qe["CASE-00001"]["currency"] == "USD" and qe["CASE-00001"]["sla_status"] in ("ON_TRACK", "DUE_TODAY", "OVERDUE"), qe.get("CASE-00001"))
check("Financial Crime / Sanctions cases are in no reviewer's queue here", not any(
      x["request"] in ("suspected fraud report", "sanctions screening query") for t in (elena, sofia) for x in queue(t)))
check("cross-team case is invisible: Sofia opens a Payment Operations case -> NOT_FOUND",
      call("get_review_case", session_token=sofia, case_id="CASE-00001")[0]["status"] == "NOT_FOUND")
rc1 = call("get_review_case", session_token=elena, case_id="case-00001")[0]
check("get_review_case: statement, brief, max approvable $310,000, Elena's $250,000 limit, recall facts, options name the senior reviewer",
      rc1["status"] == "OK" and rc1["max_approvable"] == "310000.00" and rc1["your_approval_limit"] == "250000.00"
      and "PMT-2026-000014" in rc1["facts"] and "Baltic Timber OU" in rc1["facts"] and "was IN_TRANSIT" in rc1["facts"]
      and "senior reviewer" in rc1["options"] and "full amount" in rc1["options"], rc1)
rh = call("get_review_case", session_token=marcus, case_id=bec_case)[0]
check("Payment Ops reviewer sees the held payment's name check, both names and the agent verdict (the client never does)",
      "NO_MATCH" in rh["facts"] and "RD Global Trading LLC" in rh["facts"] and "Rotterdam Shipping BV" in rh["facts"]
      and "deterministic score" in rh["facts"] and "in full" in rh["options"], rh)
rd4 = call("get_review_case", session_token=sofia, case_id="CASE-00004")[0]
check("Client Servicing reviewer sees the deduction facts (invoice 7702, $3,150 disputed, tolerance, open balance)",
      "7702" in rd4["facts"] and "$3,150.00" in rd4["facts"] and "tolerance" in rd4["facts"] and rd4["max_approvable"] == "3150.00", rd4)

# ---- decide: every reason code, then the parked actions ----
def decide(tok, case, dec="APPROVE", amt="", note="Checked the payment history.", msg="Your request was reviewed."):
    return call("decide_review_case", session_token=tok, case_id=case, decision=dec, amount=amt, internal_note=note,
                customer_message=msg)[0]
n_dec = one("SELECT count(*) FROM review_decisions")
r = decide(northwind, "CASE-00001")
check("a client token cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
r = decide(sofia, "CASE-00001")
check("another team's case -> BLOCKED NOT_YOUR_TEAM", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_YOUR_TEAM" and not r["case_id"], r)
r = decide(elena, "CASE-99999")
check("unknown case -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = decide(elena, "CASE-00001", note="ok")
check("note under 5 characters -> NOTE_REQUIRED", r["reason_code"] == "NOTE_REQUIRED", r)
r = decide(elena, "CASE-00001", dec="MAYBE")
check("decision not APPROVE/REJECT -> INVALID_DECISION", r["reason_code"] == "INVALID_DECISION", r)
r = decide(elena, "CASE-00001", amt="100000")
check("a recall is approved in full or not at all -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(elena, "CASE-00001")
check("full $310,000 above Elena's $250,000 limit -> OVER_AUTHORITY, case stays OPEN", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"], r)
check("DB: no decision row and the payment still RECALL_REQUESTED after the blocked attempts",
      one("SELECT count(*) FROM review_decisions") == n_dec
      and one("SELECT status FROM payments WHERE payment_ref='PMT-2026-000014'") == "RECALL_REQUESTED")
r = decide(marcus, "CASE-00001", note="Duplicate confirmed against the first Baltic Timber payment; recall sent.",
           msg="We have recalled the duplicate $310,000 payment and returned the funds to your account.")
check("Marcus approves the recall (full) -> APPROVED, recall executed", r["outcome"] == "APPROVED"
      and r["approved_amount"] == "310000.00" and "RECALLED" in (r["executed_action"] or ""), r)
check("DB: payment_recalls row, PMT-...14 RECALLED, RECALLED event, CASE_DECIDED by AGB-5002 + PAYMENT_RECALLED audit",
      one("SELECT count(*) FROM payment_recalls WHERE case_id='CASE-00001' AND amount=310000") == "1"
      and one("SELECT status FROM payments WHERE payment_ref='PMT-2026-000014'") == "RECALLED"
      and one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000014' AND action='RECALLED'") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='CASE-00001' AND actor='AGB-5002' "
              "AND client_id='CLI-2026-00101'") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='PAYMENT_RECALLED'") == "1")
r = decide(marcus, "CASE-00001", dec="REJECT")
check("a second decision -> ALREADY_DECIDED", r["reason_code"] == "ALREADY_DECIDED"
      and one("SELECT count(*) FROM review_decisions WHERE case_id='CASE-00001'") == "1", r)
r = decide(elena, helios_case, dec="REJECT", note="Beneficiary bank confirms Quantum Metals is the intended payee.",
           msg="After checking with the beneficiary bank we did not recall this payment; it is being delivered.")
check("Elena rejects Helios's $780,000 recall (no authority needed to reject) -> REJECTED, status restored",
      r["outcome"] == "REJECTED" and "restored" in r["executed_action"]
      and psql("SELECT status, status_before_recall FROM payments WHERE payment_ref='PMT-2026-000006'")
      == [{"status": "IN_TRANSIT", "status_before_recall": ""}]
      and one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000006' AND action='RECALL DECLINED'") == "1", r)
r = decide(marcus, "CASE-00002", amt="1000")
check("a held payment is released in full or not at all -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(marcus, "CASE-00002", note="Called Veridian's treasurer on the number on file; new account confirmed by the supplier.",
           msg="We verified the payee with your treasurer and released the payment.")
check("Marcus releases Veridian's held payment (full) -> APPROVED, payment submitted via REVIEWER",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "42500.00" and "released" in r["executed_action"], r)
check("DB: release created the payment (INITIATED, $42,500, name on file), request RELEASED",
      one("SELECT via FROM payment_releases WHERE request_id='PRQ-00001'") == "REVIEWER"
      and one("SELECT status FROM payment_requests WHERE request_id='PRQ-00001'") == "RELEASED"
      and one("SELECT count(*) FROM payments p JOIN payment_requests r ON r.payment_ref = p.payment_ref "
              "WHERE r.request_id='PRQ-00001' AND p.status='INITIATED' AND p.amount=42500 "
              "AND p.beneficiary_name='Pacific Rim Imports & Export LLC'") == "1")
r = decide(marcus, bec_case, dec="REJECT", note="Called Bramwell on the number on file: the new bank details email was fake.",
           msg="We stopped this payment: the account does not belong to Rotterdam Shipping. No money left your account.")
check("Marcus rejects Bramwell's BEC payment -> REJECTED, request CANCELLED, no money moved",
      r["outcome"] == "REJECTED" and "cancelled" in r["executed_action"]
      and one(f"SELECT status FROM payment_requests WHERE request_id = {lit(bec_req)}") == "CANCELLED"
      and one("SELECT count(*) FROM payments WHERE beneficiary_name='RD Global Trading LLC'") == "0", r)
check("the cancelled payment cannot be confirmed afterwards", cpay(bramwell, bec_req, "YES")["reason_code"] == "CANCELLED")
r = decide(sofia, "CASE-00004", amt="4000")
check("more than the $3,150 disputed -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(sofia, "CASE-00004", amt="-5")
check("negative amount -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(sofia, "CASE-00004")
check("full $3,150 deduction above Sofia's $2,500 limit -> OVER_AUTHORITY, case stays OPEN", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN", r)
r = decide(sofia, ded_case, amt="$200", note="Freight was prepaid; accepting part of the claim as goodwill.",
           msg="We accepted $200.00 of the freight deduction; the remaining $112.00 is still due on invoice 4425.")
check("Sofia accepts $200 of Northwind's $312 freight deduction -> APPROVED, written off", r["outcome"] == "APPROVED"
      and r["approved_amount"] == "200.00" and "written off" in (r["executed_action"] or ""), r)
check("DB: deduction_writeoffs row; invoice 4425 open $312 -> $112, still SHORT_PAID; DEDUCTION_WRITTEN_OFF audit",
      one(f"SELECT count(*) FROM deduction_writeoffs WHERE case_id = {lit(ded_case)} AND amount = 200") == "1"
      and one("SELECT status || ' ' || open_amount FROM open_invoices WHERE client_id='CLI-2026-00101' AND invoice_no='4425'")
      == "SHORT_PAID 112.00"
      and one("SELECT count(*) FROM agent_audit WHERE action='DEDUCTION_WRITTEN_OFF'") == "1")
r = decide(sofia, "CASE-00003", amt="50")
check("more than the $40 fee -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(sofia, "CASE-00003", note="Agreement clause 4.2 waives SWIFT fees for Bramwell.",
           msg="We have refunded the $40.00 SWIFT fee.")
check("Sofia approves Bramwell's $40 fee waiver -> APPROVED, fee refunded", r["outcome"] == "APPROVED"
      and r["approved_amount"] == "40.00" and "refunded" in r["executed_action"], r)
check("DB: fee_refunds row + FEE REFUNDED event + FEE_REFUNDED audit",
      one("SELECT count(*) FROM fee_refunds WHERE payment_ref='PMT-2026-000012' AND amount=40") == "1"
      and one("SELECT count(*) FROM payment_events WHERE payment_ref='PMT-2026-000012' AND action='FEE REFUNDED'") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='FEE_REFUNDED'") == "1")
r = decide(sofia, veridian_fee_case, dec="REJECT", note="ACH same-day fee applies under the current price schedule.",
           msg="We are not able to waive this fee; it is part of your agreed price schedule.")
check("Sofia rejects Veridian's fee waiver -> REJECTED, nothing executed", r["outcome"] == "REJECTED"
      and "nothing was executed" in r["executed_action"]
      and one("SELECT count(*) FROM fee_refunds WHERE payment_ref='PMT-2026-000010'") == "0", r)
r = decide(sofia, bramwell_comp, amt="999", note="Delay compensation agreed with the relationship manager.",
           msg="Your relationship manager will contact you about compensation.")
check("a case with nothing parked -> APPROVED, no amount, the team completes it", r["outcome"] == "APPROVED"
      and not r["approved_amount"] and "no automatic action" in r["executed_action"], r)

# ---- the client sees the outcome (status + customer_message), never the internals ----
r = {x["reference_id"]: x for x in call("get_my_cases", session_token=northwind)}
check("Northwind sees CASE-00001 APPROVED with the team's message and its deduction case APPROVED for $200",
      r["CASE-00001"]["status"] == "APPROVED" and "recalled the duplicate" in r["CASE-00001"]["customer_message"]
      and r[ded_case]["status"] == "APPROVED" and r[ded_case]["approved_amount"] == "200.00", r.get(ded_case))
r = {x["reference_id"]: x for x in call("get_my_cases", session_token=bramwell)}
check("Bramwell sees its held-payment case REJECTED with the client message (no note, score or reviewer)",
      r[bec_case]["status"] == "REJECTED" and "No money left your account" in r[bec_case]["customer_message"]
      and "fake" not in json.dumps(r) and "Marcus" not in json.dumps(r), r.get(bec_case))
e = mail(northwind, "CASE-00001")
check("email a decided case -> SEND with the decision", e["send_status"] == "SEND" and "approved" in e["body"]
      and "recalled the duplicate" in e["body"], e)
e = mail(northwind, "CAP-00002")
check("email a posted cash application -> SEND", e["send_status"] == "SEND" and "4417, 4425" in e["body"]
      and "$312.00" in e["body"], e)
e = mail(bramwell, "PMT-2026-000101")
check("email a payment submitted through the assistant -> SEND", e["send_status"] == "SEND" and "Acme Corporation Ltd" in e["body"], e)
e = mail(bramwell, bec_req)
check("email a payment request id (not a submitted payment) -> NOT_SENT", e["send_status"] == "NOT_SENT", e)
e = mail(northwind, "PMT-2026-000001")
check("email a payment not submitted through the assistant -> NOT_SENT", e["send_status"] == "NOT_SENT", e)
check("email_log holds exactly the 5 SEND requests", one("SELECT count(*) FROM email_log") == "5")

# minimum necessary: hidden columns never reach clients; reviewers see no contact email, client id or codes
cli_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row}
check("client tool outputs carry none of the hidden columns", not (cli_cols & HIDDEN_COLUMNS), cli_cols & HIDDEN_COLUMNS)
rev_rows = [row for t, rows in OUTPUTS if t in REVIEWER_TOOLS for row in rows]
rev_cols = {k for row in rev_rows for k in row}
rblob = json.dumps(rev_rows)
check("reviewer tool outputs: no contact email, client id, passcode or staff code", not (rev_cols & HIDDEN_FROM_REVIEWER)
      and not re.search(r"@[a-z]+\.example|CLI-2026-\d", rblob), (rev_cols & HIDDEN_FROM_REVIEWER))
cblob = json.dumps([row for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows])
secrets = [x["v"] for x in psql("SELECT internal_note AS v FROM review_decisions UNION ALL SELECT display_name FROM reviewers")]
check("client outputs never contain internal notes or reviewer names", not any(s in cblob for s in secrets),
      [s for s in secrets if s in cblob][:3])
check("client outputs never contain a name score or the agent's notes",
      "deterministic score" not in cblob and "Agent notes" not in cblob)
check("every MCP tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---- session expiry ----
psql(f"UPDATE client_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(northwind)}")
check("expired token -> SESSION_INVALID", call("get_my_payments", session_token=northwind, search="")[0]["session_status"] == "SESSION_INVALID")
psql(f"UPDATE client_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(sofia)}")
check("expired reviewer token -> NOT_REVIEWER", queue(sofia)[0]["status"] == "NOT_REVIEWER")

# ---- passcode brute-force lockout ----
n_sess = one("SELECT count(*) FROM client_sessions WHERE client_id='CLI-2026-00104'")
last = None
for _ in range(5):
    last = call("verify_client", client_id="CLI-2026-00104", passcode="111111")[0]   # 5 wrong codes
check("5th wrong passcode -> LOCKED", last["status"] == "LOCKED" and not last["session_token"], last)
r = call("verify_client", client_id="CLI-2026-00104", passcode="904177")             # right code, but locked
check("5 wrong -> LOCKED even with the right passcode, no token", r[0]["status"] == "LOCKED" and not r[0]["session_token"], r)
check("no session issued while locked",
      one("SELECT count(*) FROM client_sessions WHERE client_id='CLI-2026-00104'") == n_sess)
psql("UPDATE verify_attempts SET at = at - interval '16 minutes' WHERE client_id='CLI-2026-00104'")
r = call("verify_client", client_id="CLI-2026-00104", passcode="904177")
check("lock lifts after 15 minutes", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
for _ in range(4):
    call("verify_client", client_id="CLI-2026-00103", passcode="000000")
r = call("verify_client", client_id="CLI-2026-00103", passcode="615338")
check("4 wrong then right -> VERIFIED (threshold is 5)", r[0]["status"] == "VERIFIED", r)
for _ in range(5):
    last = vrev("AGB-5002", "111111")
check("staff code: 5 wrong -> LOCKED", last["status"] == "LOCKED", last)
check("staff code locked even with the right code", vrev("AGB-5002", "739104")["status"] == "LOCKED")

# ---- audit trail (OWASP traceability; written by triggers, no tool reads it) ----
na = lambda a: int(one(f"SELECT count(*) FROM agent_audit WHERE action={lit(a)}"))
check("audit logged verify sessions", na("VERIFY") >= 4, na("VERIFY"))
check("audit logged trace proposals + opened", na("TRACE_PROPOSED") >= 1 and na("TRACE_OPENED") == 1,
      (na("TRACE_PROPOSED"), na("TRACE_OPENED")))
check("audit logged recall proposals + submitted", na("RECALL_PROPOSED") >= 1 and na("RECALL_SUBMITTED") == 1,
      (na("RECALL_PROPOSED"), na("RECALL_SUBMITTED")))
check("audit logged human review cases (incl. trigger-opened deduction / payee cases)", na("REVIEW_CASE_OPENED") >= 9,
      na("REVIEW_CASE_OPENED"))
check("audit logged cash applications (proposed + applied)", na("CASH_APPLICATION_PROPOSED") >= 3 and na("CASH_APPLIED") == 2,
      (na("CASH_APPLICATION_PROPOSED"), na("CASH_APPLIED")))
check("audit logged payments (proposed, held, sent)", na("PAYMENT_PROPOSED") >= 4 and na("PAYMENT_HELD") == 1
      and na("PAYMENT_SENT") == 3, (na("PAYMENT_PROPOSED"), na("PAYMENT_HELD"), na("PAYMENT_SENT")))
check("audit rows carry the client id (reviewer sign-ins carry the reviewer id instead)",
      one("SELECT count(*) FROM agent_audit WHERE client_id IS NULL AND action <> 'REVIEWER_VERIFY'") == "0")
check("audit: CASE_DECIDED rows carry the reviewer as actor and the client as subject",
      one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND (actor IS NULL OR client_id IS NULL)") == "0"
      and int(one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED'")) == int(one("SELECT count(*) FROM review_decisions")))
check("audit: REVIEWER_VERIFY rows carry the reviewer id", int(one("SELECT count(*) FROM agent_audit WHERE action='REVIEWER_VERIFY' "
                                                                  "AND actor LIKE 'AGB-%'")) >= 3)

# ---------------------------------------------------------------- A2A agent reference tools
# payment_triage_agent keeps lookup_reason_code (checked above); the two new agents read section / term / meaning guides.
def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["payment_triage_agent", "remittance_match_agent", "payee_name_match_agent"])
lr = AGENT_REF_TOOLS[0]
check("payment_triage_agent keeps lookup_reason_code: SELECT * FROM lookup_reason_code(CAST(?code AS text)); one arg (code)",
      lr["read"] == ("SELECT * FROM lookup_reason_code(CAST(?code AS text));", [("code", "code")])
      and [a for a, _ in lr["args"]] == ["code"])
ID_VALUES = [r["v"] for r in psql(
    "SELECT client_id AS v FROM clients UNION SELECT legal_name FROM clients UNION SELECT contact_email FROM clients "
    "UNION SELECT account_id FROM accounts UNION SELECT account_number_masked FROM accounts "
    "UNION SELECT payment_ref FROM payments UNION SELECT beneficiary_name FROM payments "
    "UNION SELECT ordering_party FROM payments WHERE ordering_party IS NOT NULL "
    "UNION SELECT invoice_no FROM open_invoices UNION SELECT buyer_name FROM open_invoices "
    "UNION SELECT account_ref FROM payee_register UNION SELECT registered_name FROM payee_register "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM review_cases UNION SELECT request_id FROM payment_requests "
    "UNION SELECT application_id FROM cash_applications UNION SELECT investigation_id FROM investigations "
    "UNION SELECT session_token FROM client_sessions")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 60, len(ID_VALUES))
LOOKUPS = {   # tool -> (single word, expected term, section-name lookup, rows in that section)
    "get_remittance_guide": ("damaged", "DAMAGED_GOODS", "review line", 1),
    "get_payee_name_rules": ("umlaut", "Ü = U", "verdict", 3),
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
    check(f"{tool}: no client / account / payment / invoice / buyer / payee / reviewer / case / session value in the rows",
          not leaked, leaked[:5])
    check(f"{tool}: no id, email or token pattern",
          not re.search(r"cli-\d|\bacc-\d|pmt-\d|case-\d|agb-\d|prq-\d|cap-\d|inv-\d|act-[0-9a-f]|@|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])

rem = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_remittance_guide")
g = ref_call(rem, "")
ded = [r["term"] for r in g if r["section"] == "DEDUCTION"]
check("ref_remittance_guide: the deductions are the brief's reasons (early-pay discount, freight, damaged goods, pricing, "
      "unapplied) plus shortage", set(ded) == {"EARLY_PAY_DISCOUNT", "FREIGHT", "DAMAGED_GOODS", "PRICING", "SHORTAGE", "UNAPPLIED"}, ded)
acc = psql("SELECT * FROM cash_assessment('CLI-2026-00101', 'PMT-2026-000013', '4398', "
           + lit("; ".join(f"{d} 1" for d in ded)) + ", 'HIGH')")[0]
check("ref_remittance_guide: no DEDUCTION term is unknown to cash_assessment() (PMT-...13 is applied, so it stops early; "
      "re-checked on a fresh payment below)", acc["reason_code"] == "ALREADY_APPLIED", acc)
psql("INSERT INTO payments (payment_ref, client_id, debtor_account, direction, rail, amount, currency, fees, beneficiary_name, "
     "beneficiary_bank_bic, status, value_date, created_at) VALUES ('PMT-2026-000091', 'CLI-2026-00101', 'ACC-1001', 'INCOMING', "
     "'ACH', 12000.00, 'USD', 0, 'Northwind Manufacturing', 'CITIUS33XXX', 'COMPLETED', current_date, now())")
acc = psql("SELECT * FROM cash_assessment('CLI-2026-00101', 'PMT-2026-000091', '4398', "
           + lit("; ".join(f"{d} 1" for d in ded)) + ", 'HIGH')")[0]
check("ref_remittance_guide: every DEDUCTION term is a code cash_assessment() accepts (nothing ignored)",
      acc["ok"] == "t" and not acc["ignored_items"], acc)
acc = psql("SELECT * FROM cash_assessment('CLI-2026-00101', 'PMT-2026-000091', '4398', 'GOODWILL 1; FRT 2', 'HIGH')")[0]
check("ref_remittance_guide: a word that is not a DEDUCTION term is ignored by SQL", acc["ignored_items"] == "GOODWILL 1; FRT 2", acc)
check("ref_remittance_guide: several words in one call ('freight, shortage') -> both deductions",
      {"FREIGHT", "SHORTAGE"} <= {r["term"] for r in ref_call(rem, "freight, shortage")})
wd = ref_call(rem, "who decides")
check("ref_remittance_guide: WHO_DECIDES comes from service_teams (DEDUCTION_REVIEW -> Client Servicing, tolerance)",
      len(wd) == 1 and "Client Servicing" in wd[0]["meaning"] and "$250.00" in wd[0]["meaning"]
      and wd[0]["term"] == one("SELECT label FROM service_teams WHERE request_type='DEDUCTION_REVIEW'"), wd)
psql("UPDATE service_teams SET label = label || ' (test)' WHERE request_type = 'DEDUCTION_REVIEW'")
check("ref_remittance_guide: a service_teams edit shows up in WHO_DECIDES (no copy)", ref_call(rem, "who decides")[0]["term"].endswith("(test)"))
psql("UPDATE service_teams SET label = replace(label, ' (test)', '') WHERE request_type = 'DEDUCTION_REVIEW'")
check("ref_remittance_guide: the standard review line lives in the table",
      [r["meaning"] for r in ref_call(rem, "review line")] ==
      ["Deductions stay recorded as claims against the buyer until Aurelia Client Servicing accepts or rejects them; "
       "the invoice remains open for the disputed amount in the meantime."])
check("ref_remittance_guide: the confidence levels are exactly the ones cash_assessment() knows (HIGH, MEDIUM, LOW)",
      [r["term"] for r in g if r["section"] == "CONFIDENCE"] == ["HIGH", "MEDIUM", "LOW"])

pay = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_payee_name_rules")
g = ref_call(pay, "")
verdicts = [r["term"] for r in g if r["section"] == "VERDICT"]
cc = psql("SELECT pg_get_constraintdef(oid) AS v FROM pg_constraint WHERE conname = 'payment_requests_name_check_check'")[0]["v"]
check("ref_payee_name_rules: the VERDICT rows are exactly the name_check values the table allows",
      set(verdicts) == set(re.findall(r"'([A-Z_]+)'", cc)) and len(verdicts) == 3, (verdicts, cc))
reasons = [r["term"] for r in g if r["section"] == "REASON"]
m = psql(f"SELECT * FROM payee_assessment('A', 'B', 1, 'CLOSE_MATCH', {lit(', '.join(reasons))})")[0]
check("ref_payee_name_rules: every REASON term is accepted by payee_assessment() (nothing ignored)",
      m["agent_reasons"] == ", ".join(sorted(reasons)) and not m["ignored_reasons"] and len(reasons) == 7, m)
suffixes = [r["term"] for r in g if r["section"] == "LEGAL_SUFFIX"]
bad = [s for s in suffixes if one(f"SELECT payee_name_norm({lit('Acme ' + s)})") != "ACME"]
check("ref_payee_name_rules: every LEGAL_SUFFIX row is dropped by SQL's own name normaliser", not bad and len(suffixes) == 12, bad)
abbr = [r["term"] for r in g if r["section"] == "ABBREVIATION"]
bad = [a for a in abbr if one(f"SELECT payee_name_norm({lit(a.split(' = ')[0])})") != a.split(" = ")[1]]
check("ref_payee_name_rules: every ABBREVIATION row is expanded by SQL's normaliser", not bad and len(abbr) == 5, bad)
check("ref_payee_name_rules: TRANSLITERATION rows are used by SQL (M + u-umlaut + LLER -> MULLER)",
      one("SELECT payee_name_norm('M' || chr(220) || 'LLER Logistik GmbH')") == "MULLER LOGISTIK"
      and one("SELECT payee_name_norm('Stra' || chr(223) || 'e AG')") == "STRASSE")
wd = ref_call(pay, "who decides")
check("ref_payee_name_rules: WHO_DECIDES comes from service_teams (PAYEE_VERIFICATION -> Payment Operations)",
      len(wd) == 1 and "Payment Operations" in wd[0]["meaning"], wd)
check("ref_payee_name_rules: the VERDICT meaning text (copied into verdict_note) lives in the table",
      any(r["meaning"].startswith("The names belong to different companies. The payment must not go to this account")
          for r in ref_call(pay, "verdict")))

# nothing from the design brief is lost: the facts each agent must work from are in its table
KEEP = {"get_remittance_guide": [
            "2/10 net 30", "within 10 days", "the system works out how much was earned", "freight", "late-delivery penalty",
            "damaged or defective", "price dispute", "promotional allowance", "fewer units", "never guess a reason",
            "less 2pct", "ded, dedn", "frt", "short pay", "debit memo", "it is not an invoice number",
            "use amounts and the buyer name only to break a tie", "never invented", "except the early-payment discount",
            "reconcile to the cent", "had to be inferred", "fit more than one set", "remains open for the disputed amount"],
        "get_payee_name_rules": [
            "legal-form words", "standard abbreviations", "accents", "a word is missing or extra", "trading name",
            "different companies", "verified the payee", "ltd against limited", "intl for international", "mueller",
            "one or two letters", "forwarding, trading", "brand or trading name", "distinctive words", "limited liability",
            "public limited company", "german or austrian", "manufacturing", "brothers", "sharp s", "stroke"]}
for t in GUIDE_TOOLS:
    blob = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k.lower() not in blob]
    check(f"{t['tool']}: every fact the agent needs is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args, "
           "p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang JOIN pg_namespace ns ON ns.oid = p.pronamespace "
           "WHERE ns.nspname = 'public' AND (p.proname LIKE 'ref\\_%' OR p.proname = 'lookup_reason_code')")
names = {f["proname"] for f in fns}
check("agent read functions: ref_match + one ref_* per guide agent + lookup_reason_code",
      names == {"ref_match", "lookup_reason_code"} | {t["fn"] for t in GUIDE_TOOLS}, names)
for f in fns:
    check(f"{f['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          f["lanname"] == "sql" and f["provolatile"] in ("s", "i") and f["prosecdef"] == "f"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", f["prosrc"], re.I),
          {k: f[k] for k in ("lanname", "provolatile", "prosecdef")})
    if f["proname"] not in ("ref_match",):
        check(f"{f['proname']}: one optional, non-identity argument", f["args"] in ("p_term text", "p_code text"), f["args"])

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
check("reset_data.sql reloads the agent reference tables, reviewers, payee register, invoices and the seeded open cases",
      all(int(one(f"SELECT count(*) FROM {t['table']}")) > 0 for t in AGENT_REF_TOOLS)
      and one("SELECT count(*) FROM reviewers") == "3" and one("SELECT count(*) FROM payee_register") == "5"
      and one("SELECT count(*) FROM open_invoices WHERE status='OPEN'") == "6"
      and one("SELECT string_agg(case_id, ',' ORDER BY case_id) FROM review_cases WHERE status='OPEN'")
      == "CASE-00001,CASE-00002,CASE-00003,CASE-00004"
      and one("SELECT count(*) FROM agent_audit") == "0" and one("SELECT count(*) FROM payments") == "15")

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{passes + fails} checks, DB reset)")
sys.exit(1 if fails else 0)
