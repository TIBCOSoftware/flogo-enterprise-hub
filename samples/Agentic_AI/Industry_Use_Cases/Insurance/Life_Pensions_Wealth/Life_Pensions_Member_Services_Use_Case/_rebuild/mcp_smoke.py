#!/usr/bin/env python3
"""Test ladder step 3: call the running LifePensionsMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9932/lifepensionsmcpserver), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (life_pensions_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (James's contribution change) to
the EMAIL_TO app property; the SQL guard + email_log are asserted, SMTP delivery is reported separately."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, REVIEWER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9932/lifepensionsmcpserver")
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
    sys.exit("set PG_PWD or PG_PASSWORD in config.md (PostgreSQL password; used to reset and inspect the DB)")
PSQL = (os.environ.get("PSQL") or _config_value("PSQL_PATH") or shutil.which("psql")
        or sys.exit("psql not found: install the PostgreSQL client and put psql on PATH, or set env PSQL / config.md "
                    "PSQL_PATH (see skills-library/AGENT.md -> Prerequisites and preflight)"))
ENV = dict(os.environ, PGPASSWORD=PWD)
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-p", os.environ.get("PG_PORT", "5432"),
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "life_pensions_governed"),
        "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0
OUTPUTS = []          # every tool result, for the hidden-column scan


def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe


# ---------------- DB helpers ----------------
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV, encoding="utf-8")
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))


def n(sql): return int(list(q(sql)[0].values())[0])
def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


# ---------------- MCP streamable-HTTP JSON-RPC ----------------
def rpc(method, params=None, notify=False):
    global session, seq
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if not notify:
        seq += 1; body["id"] = seq
    req = urllib.request.Request(URL, json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                                          **({"Mcp-Session-Id": session} if session else {})})
    with urllib.request.urlopen(req, timeout=60) as r:
        session = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode()
    if notify or not raw.strip(): return None
    data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
    msg = json.loads(data[-1])
    if "error" in msg: raise RuntimeError(msg["error"])
    return msg["result"]


def call(tool, **args):
    args = {a: args.get(a, "") for a, _ in SPEC_ARGS[tool]}
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
    body = json.loads(text)
    rows = (json.loads(body["data"]) if "data" in body else body)["records"]   # both result shapes (runtime-gotchas 6)
    OUTPUTS.append((tool, rows))
    return rows


def one(tool, **args): return call(tool, **args)[0]


# Flogo may hand numbers back as JSON numbers or strings, NULL as null - compare tolerantly
def num(v):
    try: return round(float(str(v).replace("$", "").replace(",", "").strip()), 2)
    except (TypeError, ValueError): return None
def s(v): return "" if v is None else str(v)


def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0


SPEC = {t["tool"]: t for t in TOOLS}
SPEC_ARGS = {t["tool"]: t["args"] for t in TOOLS}
BAD = "bogus-token-0000"
JAMES_M, LINDA_M, ROBERT_M = "HLR-100101", "HLR-100106", "HLR-100105"

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 20 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 20,
          {"missing": sorted(set(SPEC) - set(tools)), "extra": sorted(set(tools) - set(SPEC))})
    ann = {k: tools[k].get("annotations", {}) for k in tools if k in SPEC}
    # absent readOnlyHint/idempotentHint = false per the MCP spec (Go omitempty); destructiveHint must be present + false
    check("readOnlyHint matches tool_spec on every tool (absent = false)",
          all(ann[k].get("readOnlyHint", False) is SPEC[k]["readonly"] for k in ann), ann)
    check("write tools: idempotentHint false, destructiveHint present and false",
          all(ann[k].get("idempotentHint", False) is False and ann[k].get("destructiveHint") is False
              for k in ann if not SPEC[k]["readonly"]), {k: ann[k] for k in ann if not SPEC[k]["readonly"]})
    bad_schema = [k for k in tools if k in SPEC and not all(a in json.dumps(tools[k].get("inputSchema")) for a, _ in SPEC[k]["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- identity ----
    r = one("verify_member", member_id="HLR-100101", code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_member", member_id="hlr100101", code="4821")
    check("James 'hlr100101' -> VERIFIED + token + first name", r["outcome"] == "VERIFIED" and r.get("session_token")
          and r.get("first_name") == "James", {k: v for k, v in r.items() if k != "session_token"})
    james = s(r.get("session_token")) or "missing"
    linda = s(one("verify_member", member_id="HLR-100106", code="7316").get("session_token")) or "missing"
    susan = s(one("verify_member", member_id="100104", code="5530").get("session_token")) or "missing"
    robert = s(one("verify_member", member_id="HLR-100105", code="8642").get("session_token")) or "missing"
    check("Linda, Susan (bare digits) and Robert verify", "missing" not in (linda, susan, robert))
    r = one("verify_reviewer", staff_id="HLS-2041", code="9999")
    check("reviewer wrong code -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="HLS-2041", code="3141")
    check("Grace -> VERIFIED REVIEWER, Claims Examination", r["outcome"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Claims Examination", {k: v for k, v in r.items() if k != "session_token"})
    grace = s(r.get("session_token")) or "missing"
    marcus = s(one("verify_reviewer", staff_id="HLS-2057", code="2718").get("session_token")) or "missing"

    # ---- bogus token on every scoped tool ----
    for t in TOOLS:
        if t["tool"] in ("verify_member", "verify_reviewer"):
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = BAD
        row = one(t["tool"], **args)
        code = row.get("reason_code") if t.get("email") else (row.get("status") or row.get("outcome"))
        want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
        check(f"{t['tool']} with bogus token -> {want}", code == want, row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM account_events") == 0 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM service_cases") == 3 and n("SELECT count(*) FROM email_log") == 0)
    check("role separation: reviewer token on a member tool -> SESSION_INVALID",
          one("get_my_claims", session_token=grace)["status"] == "SESSION_INVALID")

    # ---- scoped reads (multi-row tools must return ALL rows) ----
    acc = {s(x.get("account_id")): x for x in call("get_my_retirement_accounts", session_token=james)}
    a = acc.get("RET-5001", {})
    check("get_my_retirement_accounts: 2 rows; 401(k) 3%, gap 3, $2,880 unclaimed",
          len(acc) == 2 and s(a.get("contribution_rate")) == "3% of pay" and num(a.get("match_gap_pct")) == 3
          and num(a.get("unclaimed_match_per_year")) == 2880, acc)
    h = call("get_my_holdings", session_token=james)
    check("get_my_holdings: 4 rows, FND-001 High risk $63,225", len(h) == 4
          and any(x.get("fund_id") == "FND-001" and num(x.get("value")) == 63225 and x.get("risk_level") == "High" for x in h), h)
    check("get_my_policies: 3 rows", len(call("get_my_policies", session_token=james)) == 3)
    check("get_my_beneficiaries: Emily Carter (Spouse) x2",
          [x.get("relationship") for x in call("get_my_beneficiaries", session_token=james)] == ["Spouse", "Spouse"])
    check("get_my_contributions: 12 rows", len(call("get_my_contributions", session_token=james)) == 12)
    check("get_fund_catalog: 11 rows", len(call("get_fund_catalog", session_token=james)) == 11)
    check("get_my_profile: Divorced", one("get_my_profile", session_token=james).get("marital_status") == "Divorced")
    cl = one("get_my_claims", session_token=linda)
    check("get_my_claims (Linda): CLM-2026-0004 Denied, waiting period", cl.get("claim_status") == "Denied"
          and "waiting period" in s(cl.get("decision_text")), cl)

    # ---- two-step: blocked, then propose -> confirm ----
    r = one("propose_contribution_change", session_token=james, new_rate_pct="20")
    check("propose 20% -> BLOCKED ABOVE_PLAN_MAX", r["outcome"] == "BLOCKED" and r.get("reason_code") == "ABOVE_PLAN_MAX", r)
    p = one("propose_contribution_change", session_token=james, new_rate_pct="6")
    check("propose 6% -> PROPOSED, nothing changed yet", p["outcome"] == "PROPOSED" and p.get("proposal_id")
          and q("SELECT contribution_rate::text AS v, account_id FROM retirement_accounts WHERE account_id='RET-5001'")[0]["v"] == "3.00", p)
    c = one("confirm_action", session_token=linda, proposal_id=s(p.get("proposal_id")))
    check("SCOPE: Linda confirms James's proposal -> NOT_FOUND", c["outcome"] == "NOT_FOUND", c)
    c = one("confirm_action", session_token=james, proposal_id=s(p.get("proposal_id")))
    ref_rate = s(c.get("reference"))
    check("confirm -> EXECUTED HLR-ACT-nnnnnn; DB rate 6%", c["outcome"] == "EXECUTED" and re.fullmatch(r"HLR-ACT-\d{6}", ref_rate)
          and q("SELECT contribution_rate::text AS v, account_id FROM retirement_accounts WHERE account_id='RET-5001'")[0]["v"] == "6.00", c)
    r = one("propose_fund_switch", session_token=james, account_id="RET-5001", from_fund_id="FND-001", to_fund_id="FND-011", amount="1000")
    check("fund switch into a closed fund -> BLOCKED INVALID_FUND", r["outcome"] == "BLOCKED" and r.get("reason_code") == "INVALID_FUND", r)
    p = one("propose_fund_switch", session_token=james, account_id="RET-5001", from_fund_id="FND-001", to_fund_id="FND-005", amount="ALL")
    c = one("confirm_action", session_token=james, proposal_id=s(p.get("proposal_id")))
    check("fund switch ALL FND-001 -> FND-005: PROPOSED -> EXECUTED; DB FND-001 units 0",
          p["outcome"] == "PROPOSED" and c["outcome"] == "EXECUTED"
          and num(q("SELECT units AS v, fund_id FROM holdings WHERE account_id='RET-5001' AND fund_id='FND-001'")[0]["v"]) == 0, (p, c))

    # ---- claims ----
    r = one("file_claim", session_token=susan, policy_id="POL-1008", claim_type="CriticalIllness", description="Diagnosed last month.")
    check("Susan: lapsed policy -> BLOCKED POLICY_NOT_ACTIVE, no claim", r["outcome"] == "BLOCKED" and r.get("reason_code") == "POLICY_NOT_ACTIVE"
          and n("SELECT count(*) FROM claims WHERE member_id='HLR-100104'") == 0, r)
    r = one("file_claim", session_token=james, policy_id="POL-1003", claim_type="IncomeProtection",
            description="Tore my ACL; signed off work for 8 weeks.", documents_needed="attending physician statement; employer statement")
    check("James: Income Protection claim -> FILED + claim-decision case (Claims Examination)", r["outcome"] == "FILED"
          and re.fullmatch(r"CLM-\d{4}-\d{4}", s(r.get("claim_id"))) and r.get("team") == "Claims Examination", r)

    # ---- human-owned cases ----
    k = one("open_service_case", session_token=linda, request_type="claim_appeal", reference_id="CLM-2026-0004",
            summary="Doctor's records show I stopped work earlier than the employer form says.",
            agent_brief="summary: denied for the waiting period. new_evidence: physician records")
    lcase = s(k.get("case_id"))
    check("Linda claim_appeal -> OPENED, Claims Examination", k["outcome"] == "OPENED" and k.get("team") == "Claims Examination", k)
    k = one("open_service_case", session_token=james, request_type="claim_appeal", reference_id="CLM-2026-0004", summary="x")
    check("SCOPE: James appeals Linda's claim -> NOT_APPEALABLE", k.get("reason_code") == "NOT_APPEALABLE", k)
    k = one("open_service_case", session_token=james, request_type="beneficiary_change", reference_id="POL-1001",
            summary="Divorced; wants to name his daughter instead of his former spouse.")
    check("James beneficiary_change -> OPENED, Policy & Retirement Services", k["outcome"] == "OPENED"
          and k.get("team") == "Policy & Retirement Services", k)
    check("get_my_cases (Linda): the appeal is OPEN", any(x.get("case_id") == lcase and x.get("case_status") == "OPEN"
                                                          for x in call("get_my_cases", session_token=linda)))

    # ---- reviewer loop: happy path + one blocked call per tool ----
    qids = [s(x.get("case_id")) for x in call("get_review_queue", session_token=grace)]
    check("get_review_queue (Grace): Linda's appeal + David's seeded case, not Robert's", lcase in qids
          and "HLR-CASE-000001" in qids and "HLR-CASE-000002" not in qids, qids)
    check("get_review_queue with a member token -> NOT_REVIEWER", one("get_review_queue", session_token=linda)["status"] == "NOT_REVIEWER")
    rc = one("get_review_case", session_token=grace, case_id=lcase)
    check("get_review_case: brief + facts + max $3,800", rc["status"] == "OK" and "physician" in s(rc.get("agent_brief"))
          and num(rc.get("max_approvable")) == 3800 and "WAITING_PERIOD_NOT_MET" in s(rc.get("facts")), rc)
    check("get_review_case on another team's case -> NOT_FOUND",
          one("get_review_case", session_token=grace, case_id="HLR-CASE-000002")["status"] == "NOT_FOUND")
    r = one("decide_review_case", session_token=linda, case_id=lcase, decision="APPROVE", amount="3800",
            internal_note="self approval", customer_message="approved")
    check("decide with the member's token -> NOT_REVIEWER, no decision", r["outcome"] == "NOT_REVIEWER"
          and n("SELECT count(*) FROM review_decisions") == 0, r)
    r = one("decide_review_case", session_token=grace, case_id=lcase, decision="APPROVE", amount="3800", internal_note="ok")
    check("decide with a 2-char note -> NOTE_REQUIRED", r.get("reason_code") == "NOTE_REQUIRED", r)
    r = one("decide_review_case", session_token=grace, case_id="HLR-CASE-000002", decision="APPROVE", amount="100",
            internal_note="Not my team.")
    check("decide another team's case -> NOT_YOUR_TEAM", r.get("reason_code") == "NOT_YOUR_TEAM", r)
    r = one("decide_review_case", session_token=marcus, case_id="HLR-CASE-000002", decision="APPROVE", amount="8000",
            internal_note="Roof repair invoice on file.")
    check("Marcus approves $8,000 over his $5,000 limit -> OVER_AUTHORITY, case still OPEN", r.get("reason_code") == "OVER_AUTHORITY"
          and q("SELECT status AS v, case_id FROM service_cases WHERE case_id='HLR-CASE-000002'")[0]["v"] == "OPEN", r)
    MSG = "Your appeal was approved and your $3,800 Income Protection benefit has been paid."
    r = one("decide_review_case", session_token=grace, case_id=lcase, decision="APPROVE", amount="3800",
            internal_note="Physician records confirm the waiting period was met.", customer_message=MSG)
    check("Grace approves the appeal -> APPROVED, payment executed", r["outcome"] == "APPROVED" and "HLR-PAY-" in s(r.get("executed_action")), r)
    check("DB: decision row, claim Approved, payment $3,800, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{lcase}'") == 1
          and q("SELECT status AS v, claim_id FROM claims WHERE claim_id='CLM-2026-0004'")[0]["v"] == "Approved"
          and num(q("SELECT amount AS v, claim_id FROM claim_payments WHERE claim_id='CLM-2026-0004'")[0]["v"]) == 3800
          and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{lcase}'") == 1)
    r = one("decide_review_case", session_token=grace, case_id=lcase, decision="REJECT", internal_note="Second decision.")
    check("second decision -> ALREADY_DECIDED", r.get("reason_code") == "ALREADY_DECIDED", r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=linda)}
    check("member sees the outcome: APPROVED + customer message, no internal note",
          mc.get(lcase, {}).get("case_status") == "APPROVED" and mc[lcase].get("customer_message") == MSG
          and "Physician records confirm" not in json.dumps(mc), mc.get(lcase))

    # ---- guarded email: refusals first, then one real send ----
    e = one("email_confirmation", session_token=linda, reference=ref_rate)
    check("SCOPE: Linda emails James's reference -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    check("DB: refused email logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_confirmation", session_token=james, reference=ref_rate)
        check("email own executed change -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK" and ref_rate in s(e.get("subject")), e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference='{ref_rate}' AND member_id='{JAMES_M}'") == 1)

    # ---- hidden data ----
    mem = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
    leaked = sorted({k for _, rows in mem for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no member tool output carries a hidden column", not leaked, leaked)
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
