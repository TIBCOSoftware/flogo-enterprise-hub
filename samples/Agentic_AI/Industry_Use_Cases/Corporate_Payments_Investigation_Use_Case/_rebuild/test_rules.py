#!/usr/bin/env python3
"""Step 1: run the EXACT tool SQL from tool_spec.py against the payments_governed DB and assert the business
rules. No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> PG_DB=payments_governed python _rebuild/test_rules.py   (PSQL env var overrides the psql path)
"""
import os, re, subprocess, sys, csv, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, LOOKUP_REASON_CODE

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = os.environ.get("PSQL", r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
ENV = dict(os.environ, PGPASSWORD=os.environ["PG_PWD"])
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "payments_governed"), "-v", "ON_ERROR_STOP=1", "-q"]
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
check("12 MCP tools", len(TOOLS) == 12, [t["tool"] for t in TOOLS])
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
check("every other tool takes session_token first",
      all(t["args"][0][0] == "session_token" for t in TOOLS if t["tool"] != "verify_client"))
check("status/timeline/delivery take session_token + payment_ref",
      all([a for a, _ in T[x]["args"]] == ["session_token", "payment_ref"]
          for x in ("get_payment_status", "get_payment_timeline", "check_delivery_estimate")))

# ---- identity ----
r = call("verify_client", client_id="CLI-2026-00101", passcode="000000")
check("wrong passcode -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_client", client_id=" cli-2026-00101 ", passcode="486201")
check("right id+passcode -> VERIFIED + token + name", r[0]["status"] == "VERIFIED" and r[0]["session_token"]
      and r[0]["legal_name"] == "Northwind Manufacturing", r)
northwind = r[0]["session_token"]
helios = call("verify_client", client_id="CLI-2026-00102", passcode="730955")[0]["session_token"]
veridian = call("verify_client", client_id="CLI-2026-00103", passcode="615338")[0]["session_token"]
barco = call("verify_client", client_id="CLI-2026-00104", passcode="904177")[0]["session_token"]
check("all 4 seeded passcodes verify", all([northwind, helios, veridian, barco]))
r = call("verify_client", client_id="CLI-2026-99999", passcode="486201")
check("unknown client id -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
check("unknown id is not tracked in verify_attempts",
      one("SELECT count(*) FROM verify_attempts WHERE client_id='CLI-2026-99999'") == "0")
r = call("verify_client", client_id="CLI-2026-00104", passcode="486201")
check("Northwind's passcode does not open Barco", r[0]["status"] == "NOT_VERIFIED", r)

# ---- SESSION_INVALID on every scoped tool ----
for t in TOOLS:
    if t["tool"] == "verify_client":
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
      "PMT-2026-000003", "PMT-2026-000004", "PMT-2026-000005"} <= set(ids) and r[0]["session_status"] == "OK", ids)
check("no other client's payment in Northwind's list",
      not ({"PMT-2026-000006", "PMT-2026-000009", "PMT-2026-000012"} & set(ids)), ids)
r = call("get_my_payments", session_token=northwind, search="Pacific Components")
check("search by beneficiary -> PMT-2026-000001", [x["payment_ref"] for x in r] == ["PMT-2026-000001"], r)
r = call("get_my_payments", session_token=northwind, search="48500")
check("search by amount -> PMT-2026-000002", [x["payment_ref"] for x in r] == ["PMT-2026-000002"], r)
r = call("get_my_payments", session_token=northwind, search="Rotterdam Shipping")
check("Northwind cannot find Barco's beneficiary (NO_MATCH)",
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
check("trace cross-client (Northwind on Barco) -> NOT_YOUR_PAYMENT",
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
check("recall cross-client (Northwind on Barco) -> NOT_YOUR_PAYMENT",
      precall(northwind, "PMT-2026-000012")["reason_code"] == "NOT_YOUR_PAYMENT")
check("recall an INCOMING payment -> NOT_RECALLABLE", precall(veridian, "PMT-2026-000009")["reason_code"] == "NOT_RECALLABLE")
check("recall a payment completed > 5 business days ago -> NOT_RECALLABLE",
      precall(veridian, "PMT-2026-000011")["reason_code"] == "NOT_RECALLABLE")
check("recall with unknown reason -> BAD_REASON", precall(helios, "PMT-2026-000006", "ZZ99")["reason_code"] == "BAD_REASON")
check("no pending recall written by any refused proposal",
      one("SELECT count(*) FROM pending_actions WHERE action_type='RECALL'") == "0")

# ---- recall happy path (Helios PMT-...06, wrong beneficiary) ----
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
check("trigger: payment set RECALL_REQUESTED", one("SELECT status FROM payments WHERE payment_ref='PMT-2026-000006'") == "RECALL_REQUESTED")
rvc = psql(f"SELECT request_type, assigned_team, client_id, payment_ref FROM review_cases WHERE case_id={lit(helios_case)}")
check("trigger: RECALL case -> Payment Operations, Helios, PMT-...06",
      len(rvc) == 1 and rvc[0]["request_type"] == "RECALL" and rvc[0]["assigned_team"] == "Payment Operations"
      and rvc[0]["client_id"] == "CLI-2026-00102" and rvc[0]["payment_ref"] == "PMT-2026-000006", rvc)
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
def case(tok, ty, stmt="Please help with this.", brief="Client request; routed for a human to decide."):
    return call("open_review_case", session_token=tok, request_type=ty, client_statement=stmt, brief=brief)[0]
ROUTING = {"RECALL": ("Payment Operations", "1"), "PAYMENT_REPAIR": ("Payment Operations", "1"),
           "FEE_WAIVER": ("Client Servicing", "2"), "COMPENSATION": ("Client Servicing", "2"),
           "FRAUD": ("Financial Crime", "1"), "SANCTIONS_QUERY": ("Sanctions & Compliance", "2"),
           "OTHER": ("Client Servicing", "3")}
for ty, (team, days) in ROUTING.items():
    k = case(barco, ty)
    check(f"open_review_case {ty} -> {team}, {days} business days", k["outcome"] == "CASE_OPENED"
          and re.fullmatch(r"CASE-\d{5}", k["case_id"] or "") and k["assigned_team"] == team
          and k["reply_within_business_days"] == days, k)
k = case(veridian, "fee waiver", "There is an unexpected 45 USD fee on my ACH payment.")
check("Veridian FEE_WAIVER (normalised) -> Client Servicing, 2 days", k["outcome"] == "CASE_OPENED"
      and k["assigned_team"] == "Client Servicing" and k["reply_within_business_days"] == "2", k)
check("duplicate case suppressed (same case id)", case(veridian, "FEE_WAIVER")["case_id"] == k["case_id"])
k = case(helios, "SANCTIONS_QUERY", "Why is my payment held for sanctions screening?")
check("Helios SANCTIONS_QUERY -> Sanctions & Compliance", k["assigned_team"] == "Sanctions & Compliance", k)
r = case(barco, "REFUND")
check("bad request type -> BAD_TYPE", r["outcome"] == "NOT_OPENED" and r["reason_code"] == "BAD_TYPE", r)

# ---- my cases (investigations + review cases) ----
r = call("get_my_cases", session_token=northwind)
refs = {x["reference_id"]: x for x in r}
check("Northwind sees its investigation INV-2026-0002", "INV-2026-0002" in refs
      and refs["INV-2026-0002"]["case_type"] == "INVESTIGATION" and r[0]["session_status"] == "OK", r)
check("Northwind does not see Helios's seeded investigation", "INV-2026-0001" not in refs, refs.keys())
r = call("get_my_cases", session_token=helios)
refs = {x["reference_id"]: x for x in r}
check("Helios sees seeded INV-2026-0001 and its recall case", "INV-2026-0001" in refs and helios_case in refs
      and refs[helios_case]["case_type"] == "REVIEW_CASE", r)
r = call("get_my_cases", session_token=barco)
check("Barco has review cases but no investigation", all(x["case_type"] == "REVIEW_CASE" for x in r if x["reference_id"])
      and r[0]["session_status"] == "OK", r)

# ---- email confirmation (guarded) ----
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

# ---- session expiry ----
psql(f"UPDATE client_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(northwind)}")
check("expired token -> SESSION_INVALID", call("get_my_payments", session_token=northwind, search="")[0]["session_status"] == "SESSION_INVALID")

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

# ---- audit trail (OWASP traceability; written by triggers, no tool reads it) ----
na = lambda a: int(one(f"SELECT count(*) FROM agent_audit WHERE action={lit(a)}"))
check("audit logged verify sessions", na("VERIFY") >= 4, na("VERIFY"))
check("audit logged trace proposals + opened", na("TRACE_PROPOSED") >= 1 and na("TRACE_OPENED") == 1,
      (na("TRACE_PROPOSED"), na("TRACE_OPENED")))
check("audit logged recall proposals + submitted", na("RECALL_PROPOSED") >= 1 and na("RECALL_SUBMITTED") == 1,
      (na("RECALL_PROPOSED"), na("RECALL_SUBMITTED")))
check("audit logged human review cases", na("REVIEW_CASE_OPENED") >= 7, na("REVIEW_CASE_OPENED"))
check("audit rows carry the client id", one("SELECT count(*) FROM agent_audit WHERE client_id IS NULL") == "0")

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  (DB reset)")
sys.exit(1 if fails else 0)
