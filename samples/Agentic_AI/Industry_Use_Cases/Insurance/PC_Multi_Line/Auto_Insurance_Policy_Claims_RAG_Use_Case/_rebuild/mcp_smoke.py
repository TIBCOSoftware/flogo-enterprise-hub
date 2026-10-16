#!/usr/bin/env python3
"""Test ladder step 3: call the running AutoInsuranceMCPServer tools directly - no LLM - to prove the rules hold at the
MCP edge (16 tools, incl. the RAG search over the live OpenAI vector store), asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9912/autoinsurancemcpserver), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (auto_insurance_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql - it keeps document_index, so the vector store is NOT re-ingested) before and after.
Attempts ONE real confirmation email (Michael's filed claim) to the EMAIL_TO app property; the SQL guard + email_log
are asserted, SMTP delivery is reported separately (the portable app ships a dummy email password)."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import (TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS, CUSTOMER_TOOLS,
                       FORBIDDEN_CUSTOMER_STRINGS)

URL = os.environ.get("MCP_URL", "http://localhost:9912/autoinsurancemcpserver")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "auto_insurance_governed"),
        "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0
OUTPUTS = []          # every tool result (tool, rows), for the hidden-column / forbidden-string scans
NOTES = []


def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe


# ---------------- DB helpers ----------------
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV, encoding="utf-8")
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))


def n(sql): return int(list(q(sql)[0].values())[0])
def val(sql):
    rows = q(sql)
    return list(rows[0].values())[0] if rows else None
def lit(v): return "'" + str(v).replace("'", "''") + "'"
def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)


# ---------------- MCP streamable-HTTP JSON-RPC ----------------
def rpc(method, params=None, notify=False, timeout=90):
    global session, seq
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if not notify:
        seq += 1; body["id"] = seq
    req = urllib.request.Request(URL, json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                                          **({"Mcp-Session-Id": session} if session else {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        session = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode("utf-8")
    if notify or not raw.strip(): return None
    data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
    msg = json.loads(data[-1])
    if "error" in msg: raise RuntimeError(msg["error"])
    return msg["result"]


def call(tool, timeout=90, **args):
    args = {a: args.get(a, "") for a, _ in SPEC_ARGS[tool]}
    res = rpc("tools/call", {"name": tool, "arguments": args}, timeout=timeout)
    text = res["content"][0]["text"]
    if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
    body = json.loads(text)
    if isinstance(body, dict) and body.get("error") and not body.get("data"):
        raise RuntimeError(f"{tool} returned error: {str(body['error'])[:300]}")
    payload = json.loads(body["data"]) if isinstance(body, dict) and "data" in body else body
    rows = payload["records"] if isinstance(payload, dict) and "records" in payload else payload   # RAG: plain array
    if rows is None: rows = []
    OUTPUTS.append((tool, rows))
    return rows


def one(tool, **args):
    rows = call(tool, **args)
    return rows[0] if rows else {}


# Flogo may hand numbers back as JSON numbers or strings, NULL as null - compare tolerantly
def num(v):
    try: return round(float(str(v).replace("$", "").replace(",", "").strip()), 2)
    except (TypeError, ValueError): return None
def s(v): return "" if v is None else str(v)
def oc(r): return s(r.get("outcome") or r.get("status"))
def safe(r): return {k: v for k, v in r.items() if k != "session_token"}


def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0


SPEC = {t["tool"]: t for t in TOOLS}
SPEC_ARGS = {t["tool"]: t["args"] for t in TOOLS}
BAD = "bogus-token-0000"
FC_PDF = "Full_Coverage_Auto_Policy_Wording.pdf"


def rag_text(rows):
    """All passage text of a search_policy_wording result, whitespace-normalised, lower-case."""
    parts = []
    for r in rows:
        for c in (r.get("content") or []):
            parts.append(s(c.get("text") if isinstance(c, dict) else c))
    return re.sub(r"\s+", " ", " ".join(parts)).lower()


def rag_shape_ok(rows):
    return 0 < len(rows) <= 3 and all(r.get("filename") and num(r.get("score")) is not None
                                      and isinstance(r.get("content"), list) and r["content"]
                                      and s(r["content"][0].get("text")) for r in rows)


reset()
YEAR = val("SELECT to_char(current_date, 'YYYY')")
TODAY = val("SELECT to_char(current_date, 'YYYY-MM-DD')")
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 16 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 16,
          {"missing": sorted(set(SPEC) - set(tools)), "extra": sorted(set(tools) - set(SPEC))})
    ann = {k: tools[k].get("annotations", {}) for k in tools if k in SPEC}
    # absent readOnlyHint/idempotentHint = false per the MCP spec (Go omitempty); destructiveHint must be present + false
    check("readOnlyHint true on every read, false/absent on every write",
          all(ann[k].get("readOnlyHint", False) is SPEC[k]["readonly"] for k in ann), ann)
    check("write tools: idempotentHint false, destructiveHint present and false",
          all(ann[k].get("idempotentHint", False) is False and ann[k].get("destructiveHint") is False
              for k in ann if not SPEC[k]["readonly"]), {k: ann[k] for k in ann if not SPEC[k]["readonly"]})
    d = ann.get("decide_review_case", {})
    check("decide_review_case: destructiveHint false, idempotentHint false, not read-only",
          d.get("destructiveHint") is False and d.get("idempotentHint", False) is False and not d.get("readOnlyHint", False), d)
    bad_schema = [k for k in tools if k in SPEC and not all(a in json.dumps(tools[k].get("inputSchema")) for a, _ in SPEC[k]["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)

    # ---- RAG: search_policy_wording through the transplanted vectorSearch (live vector store, no re-ingest) ----
    vs = val("SELECT vector_store_id FROM latest_vector_store()")
    check("document_index holds a live vector store id (kept by reset_data.sql)", s(vs).startswith("vs_"), vs)
    r = call("search_policy_wording", query="Full Coverage: is flood damage covered if I drove into a flooded underpass "
                                            "and water got into the engine?")
    t = rag_text([x for x in r if s(x.get("filename")) == FC_PDF])
    check("RAG flood query: <= 3 rows of filename/score/content[].text", rag_shape_ok(r), r)
    check(f"RAG flood query: a {FC_PDF} passage carries the water-ingestion exclusion ('knowingly driven')",
          "knowingly driven" in t, [(x.get("filename"), num(x.get("score"))) for x in r])
    r = call("search_policy_wording", query="Full Coverage: am I covered if I drive my car to Canada? What is the policy territory?")
    check("RAG territory query: passage text mentions Canada", rag_shape_ok(r) and "canada" in rag_text(r),
          [(x.get("filename"), num(x.get("score"))) for x in r])
    r = call("search_policy_wording", query="Full Coverage: does a windshield glass claim affect my claims-free discount?")
    check("RAG glass query: passage text mentions the claims-free discount", rag_shape_ok(r) and "claims-free discount" in rag_text(r),
          [(x.get("filename"), num(x.get("score"))) for x in r])

    # ---- identity ----
    r = one("verify_policyholder", policy_number="CAI-100101", code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r.get("outcome") == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_policyholder", policy_number="cai100101", code="4821")
    check("Michael 'cai100101' -> VERIFIED + token + first name + CAI-100101 + today",
          r.get("outcome") == "VERIFIED" and r.get("session_token") and r.get("first_name") == "Michael"
          and r.get("policy_number") == "CAI-100101" and s(r.get("today")) == TODAY, safe(r))
    michael = s(r.get("session_token")) or "missing"
    tok = lambda pol, code: s(one("verify_policyholder", policy_number=pol, code=code).get("session_token")) or "missing"
    sarah, olivia, tyler = tok("CAI-100102", "2468"), tok("100106", "5530"), tok("CAI 100108", "7316")
    check("Sarah, Olivia (bare digits) and Tyler ('CAI 100108') verify", "missing" not in (sarah, olivia, tyler))
    r = one("verify_reviewer", staff_id="CAS-3011", code="9999")
    check("reviewer wrong code -> VERIFY_FAILED, no token", r.get("outcome") == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="CAS-3011", code="6021")
    check("Dana -> VERIFIED REVIEWER, Claims Adjusting", r.get("outcome") == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Claims Adjusting", safe(r))
    dana = s(r.get("session_token")) or "missing"
    r = one("verify_reviewer", staff_id="CAS-3027", code="8350")
    priya = s(r.get("session_token")) or "missing"
    check("Priya -> VERIFIED, Special Investigations", r.get("team") == "Special Investigations", safe(r))

    # ---- bogus token on every scoped tool ----
    BOGUS_ARGS = {"claim_type": "Glass", "incident_date": "today", "estimated_amount": "300", "request_type": "callback",
                  "proposal_id": "CAI-PRP-00000000", "case_id": "CAI-CASE-000001", "decision": "APPROVE",
                  "internal_note": "bogus token test", "reference": "CAI-CASE-000001"}
    for t in TOOLS:
        if "session_token" not in [a for a, _ in t["args"]]:
            continue
        args = {a: BOGUS_ARGS.get(a, "x") for a, _ in t["args"]}
        args["session_token"] = BAD
        row = one(t["tool"], **args)
        code = row.get("reason_code") if t.get("email") else oc(row)
        want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
        check(f"{t['tool']} with bogus token -> {want}", code == want, row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_claims") == 0
          and n("SELECT count(*) FROM claim_assessments") == 0 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM service_cases") == 4 and n("SELECT count(*) FROM email_log") == 0)
    check("role separation: reviewer token on a customer tool -> SESSION_INVALID",
          oc(one("get_my_claims", session_token=dana)) == "SESSION_INVALID")

    # ---- scoped reads ----
    p = call("get_my_policy", session_token=michael)
    check("get_my_policy (Michael): CAI-100101 Full Coverage Active, 2021 Halden Crest, plate 7HDC123, has today",
          len(p) == 1 and p[0].get("policy_number") == "CAI-100101" and p[0].get("product_tier") == "Full Coverage"
          and p[0].get("policy_status") == "Active" and p[0].get("vehicle") == "2021 Halden Crest Sedan"
          and p[0].get("license_plate") == "7HDC123" and s(p[0].get("today")) == TODAY, p)
    p = call("get_my_policy", session_token=tyler)
    check("get_my_policy (Tyler): verified policy first, then the cancelled CAI-100098 (multi-row)",
          [x.get("policy_number") for x in p] == ["CAI-100108", "CAI-100098"] and p[1].get("policy_status") == "Cancelled", p)
    cv = {x.get("coverage"): x for x in call("get_my_coverages", session_token=michael)}
    check("get_my_coverages (Michael): Full Glass $100, Collision / Comprehensive $500",
          cv.get("Full Glass", {}).get("included") == "yes" and num(cv["Full Glass"].get("deductible")) == 100
          and num(cv.get("Collision", {}).get("deductible")) == 500 and num(cv.get("Comprehensive", {}).get("deductible")) == 500, cv)
    cl = {x.get("claim_no"): x for x in call("get_my_claims", session_token=tyler)}
    check("get_my_claims (Tyler): both prior claims on his cancelled policy", set(cl) == {"CLM-2025-0091", "CLM-2026-0044"}, cl)
    cl = one("get_my_claims", session_token=sarah)
    check("get_my_claims (Sarah): CLM-2026-0051 Under review + CAI-CASE-000001", cl.get("claim_no") == "CLM-2026-0051"
          and cl.get("claim_status") == "Under review" and cl.get("case_id") == "CAI-CASE-000001", cl)
    check("get_my_claims (Michael): no claims yet (one empty OK row)", s(one("get_my_claims", session_token=michael).get("claim_no")) == "")
    pm = call("get_my_payments", session_token=sarah)
    check("get_my_payments (Sarah): >= 6 monthly rows, one Due", len(pm) >= 6 and any(x.get("payment_status") == "Due" for x in pm), pm[:2])
    check("get_my_payments (Olivia): a Failed payment",
          any(x.get("payment_status") == "Failed" for x in call("get_my_payments", session_token=olivia)))
    mc = {x.get("case_id"): x for x in call("get_my_cases", session_token=sarah)}
    check("get_my_cases (Sarah): CAI-CASE-000001 OPEN claim review", mc.get("CAI-CASE-000001", {}).get("case_status") == "OPEN"
          and mc["CAI-CASE-000001"].get("request") == "claim review", mc)

    # ---- two-step claim filing: Michael's glass claim -> STANDARD ----
    r = one("propose_claim", session_token=olivia, claim_type="Collision", incident_date="yesterday", incident_time="",
            estimated_amount="2000", description="Rear-ended at a stop light.", repair_shop="")
    check("Olivia (Lapsed) propose -> BLOCKED POLICY_NOT_ACTIVE, no proposal_id", r.get("outcome") == "BLOCKED"
          and r.get("reason_code") == "POLICY_NOT_ACTIVE" and not r.get("proposal_id") and r.get("reason_text"), r)
    GLASS_DESC = "A stone hit the windshield on the highway and left a chip the size of a quarter."
    pm1 = one("propose_claim", session_token=michael, claim_type="windshield", incident_date="today", incident_time="08:15",
              estimated_amount="$350", description=GLASS_DESC, repair_shop="")
    mpid = s(pm1.get("proposal_id"))
    check("Michael Glass $350 -> PROPOSED, Full Glass, $100 deductible, discount not affected",
          pm1.get("outcome") == "PROPOSED" and re.fullmatch(r"CAI-PRP-[0-9A-F]{8}", mpid) and pm1.get("claim_type") == "Glass"
          and pm1.get("coverage_that_pays") == "Full Glass" and num(pm1.get("deductible")) == 100
          and "not affected" in s(pm1.get("discount_impact")), pm1)
    check("DB: nothing filed before confirm", n("SELECT count(*) FROM claims WHERE policyholder_id='PH-0101'") == 0)
    a = one("record_claim_assessment", session_token=michael, proposal_id=mpid, coverage_finding="COVERED",
            coverage_note="Full Glass endorsement covers windshield repair.", narrative_risk_score="5", risk_indicators="none")
    check("record_claim_assessment -> RECORDED", a.get("outcome") == "RECORDED", a)
    c = one("confirm_claim", session_token=sarah, proposal_id=mpid)
    check("SCOPE: Sarah confirms Michael's proposal -> NOT_FOUND", c.get("outcome") == "NOT_FOUND", c)
    c = one("confirm_claim", session_token=michael, proposal_id=mpid)
    mclaim = s(c.get("claim_no"))
    check("Michael confirm -> FILED CLM-<year>-0101, Submitted, STANDARD, no case",
          c.get("outcome") == "FILED" and mclaim == f"CLM-{YEAR}-0101" and c.get("claim_status") == "Submitted"
          and c.get("handling") == "STANDARD" and not c.get("case_id") and "2 business days" in s(c.get("reply_text")), c)
    row = (q(f"SELECT status, risk_band, route, payment_hold FROM claims WHERE claim_no={lit(mclaim)}") or [{}])[0]
    check("DB: Michael's claim Submitted, NORMAL / STANDARD, no hold, no case",
          row == {"status": "Submitted", "risk_band": "NORMAL", "route": "STANDARD", "payment_hold": "f"}
          and n(f"SELECT count(*) FROM service_cases WHERE reference_id={lit(mclaim)}") == 0, row)
    c = one("confirm_claim", session_token=michael, proposal_id=mpid)
    check("re-confirm -> ALREADY_DONE (blocked confirm), same claim", c.get("outcome") == "ALREADY_DONE"
          and s(c.get("claim_no")) == mclaim and n("SELECT count(*) FROM claims WHERE policyholder_id='PH-0101'") == 1, c)

    # ---- Tyler: SIU path ----
    TYLER_DESC = "Driving home late I swerved on an empty road and hit a light pole; the front end and the airbags are damaged."
    pt = one("propose_claim", session_token=tyler, claim_type="Collision", incident_date="today", incident_time="02:30",
             estimated_amount="$6,600", description=TYLER_DESC, repair_shop="Northgate Auto Body")
    tpid = s(pt.get("proposal_id"))
    check("Tyler propose -> PROPOSED, discount may be affected", pt.get("outcome") == "PROPOSED" and tpid
          and "may be affected" in s(pt.get("discount_impact")), pt)
    a = one("record_claim_assessment", session_token=tyler, proposal_id=tpid, coverage_finding="COVERED",
            coverage_note="Collision coverage applies to impact with an object.", narrative_risk_score="75",
            risk_indicators="story changed between accounts; late-night single-vehicle; third collision at the same shop")
    check("Tyler record_claim_assessment (narrative 75) -> RECORDED", a.get("outcome") == "RECORDED", a)
    c = one("confirm_claim", session_token=tyler, proposal_id=tpid)
    tclaim, tcase = s(c.get("claim_no")), s(c.get("case_id"))
    check("Tyler confirm -> FILED REVIEW, Under review, claims specialist, 10 business days",
          c.get("outcome") == "FILED" and c.get("claim_status") == "Under review" and c.get("handling") == "REVIEW"
          and tcase and "claims specialist" in s(c.get("reply_text")) and "10 business days" in s(c.get("reply_text")), c)
    row = (q(f"SELECT signal_points, narrative_score, risk_score, risk_band, payment_hold FROM claims WHERE claim_no={lit(tclaim)}") or [{}])[0]
    check("DB: Tyler signal 85, narrative 75 -> risk 81, band SIU, payment_hold true",
          row == {"signal_points": "85", "narrative_score": "75", "risk_score": "81", "risk_band": "SIU", "payment_hold": "t"}, row)
    check("DB: Tyler's case is special_investigation in Special Investigations",
          (q(f"SELECT request_type, team FROM service_cases WHERE case_id={lit(tcase)}") or [{}])[0]
          == {"request_type": "special_investigation", "team": "Special Investigations"})
    tc = {x.get("case_id"): x for x in call("get_my_cases", session_token=tyler)}
    check("Tyler sees 'claim review' / 'Claims Specialist Team', OPEN", tc.get(tcase, {}).get("request") == "claim review"
          and tc[tcase].get("team") == "Claims Specialist Team" and tc[tcase].get("case_status") == "OPEN", tc.get(tcase))
    call("get_my_claims", session_token=tyler)          # post-SIU customer read, scanned below

    # ---- human-owned cases ----
    k = one("open_service_case", session_token=olivia, request_type="reinstatement",
            summary="My policy lapsed after a failed payment; I want it back.", reference_id="")
    ocase = s(k.get("case_id"))
    check("Olivia reinstatement -> OPENED, Customer Care", k.get("outcome") == "OPENED" and k.get("team") == "Customer Care"
          and re.fullmatch(r"CAI-CASE-0001\d\d", ocase), k)
    k = one("open_service_case", session_token=olivia, request_type="Reinstatement", summary="again", reference_id="")
    check("repeat -> EXISTING, same case", k.get("outcome") == "EXISTING" and s(k.get("case_id")) == ocase, k)

    # ---- reviewer loop: happy path + one blocked call per tool ----
    rq = call("get_review_queue", session_token=dana)
    qids = [s(x.get("case_id")) for x in rq]
    teams = {x["case_id"]: x["team"] for x in q("SELECT case_id, team FROM service_cases")}
    check("get_review_queue (Dana): Sarah's + Daniel's seeded cases, Claims Adjusting only (no SIU / Customer Care)",
          {"CAI-CASE-000001", "CAI-CASE-000002"} <= set(qids) and all(teams.get(c) == "Claims Adjusting" for c in qids)
          and not {"CAI-CASE-000003", "CAI-CASE-000004", tcase, ocase} & set(qids), qids)
    check("get_review_queue (Dana): first name + last initial, eligible max Sarah $700 / Daniel $6,900",
          any(x.get("customer") == "Sarah J." for x in rq)
          and {s(x.get("case_id")): num(x.get("eligible_max")) for x in rq if s(x.get("case_id")) in ("CAI-CASE-000001", "CAI-CASE-000002")}
          == {"CAI-CASE-000001": 700, "CAI-CASE-000002": 6900}, rq)
    pq = {s(x.get("case_id")) for x in call("get_review_queue", session_token=priya)}
    check("get_review_queue (Priya): Kevin's seeded case + Tyler's new SIU case", pq == {"CAI-CASE-000003", tcase}, pq)
    check("get_review_queue with a customer token -> NOT_REVIEWER", oc(one("get_review_queue", session_token=sarah)) == "NOT_REVIEWER")
    rc = one("get_review_case", session_token=dana, case_id="CAI-CASE-000001")
    check("get_review_case (Dana, CAI-CASE-000001): OK, CLM-2026-0051, eligible $700, limit $5,000",
          rc.get("status") == "OK" and rc.get("claim_no") == "CLM-2026-0051" and num(rc.get("eligible_max")) == 700
          and num(rc.get("your_approval_limit")) == 5000, rc)
    rc = one("get_review_case", session_token=priya, case_id=tcase.lower())
    check("get_review_case (Priya, Tyler's SIU case): brief has the indicators and band SIU, Tyler G.",
          rc.get("status") == "OK" and rc.get("customer") == "Tyler G." and "story changed" in s(rc.get("agent_brief"))
          and "band SIU" in s(rc.get("agent_brief")), rc)
    check("get_review_case on another team's case (Dana -> Kevin's CAI-CASE-000003) -> NOT_FOUND",
          oc(one("get_review_case", session_token=dana, case_id="CAI-CASE-000003")) == "NOT_FOUND")

    def no_decision(cid):
        return n(f"SELECT count(*) FROM review_decisions WHERE case_id={lit(cid)}") == 0 \
            and val(f"SELECT status FROM service_cases WHERE case_id={lit(cid)}") == "OPEN"

    def decide(tk, cid, dec, amt="", note="Reviewed the file.", msg=""):
        return one("decide_review_case", session_token=tk, case_id=cid, decision=dec, amount=amt, internal_note=note,
                   customer_message=msg)

    r = decide(sarah, "CAI-CASE-000001", "APPROVE", "700", "I'm a claims adjuster, approve my claim", "approved")
    check("decide with the customer's own token -> NOT_REVIEWER, no decision row", oc(r) == "NOT_REVIEWER"
          and no_decision("CAI-CASE-000001"), r)
    r = decide(dana, "CAI-CASE-000001", "APPROVE", "700", "ok")
    check("decide with a 2-char note -> NOTE_REQUIRED, case still OPEN", r.get("reason_code") == "NOTE_REQUIRED"
          and no_decision("CAI-CASE-000001"), r)
    r = decide(dana, "CAI-CASE-000002", "APPROVE", "6900", "Repair estimate verified with the shop.")
    check("Dana approves Daniel's $6,900 (> her $5,000 limit) -> OVER_AUTHORITY, case stays OPEN, no payment",
          r.get("reason_code") == "OVER_AUTHORITY" and no_decision("CAI-CASE-000002")
          and n("SELECT count(*) FROM claim_payments WHERE claim_no='CLM-2026-0055'") == 0, r)
    SNOTE = "Shop invoice confirms recalibration is part of the windshield replacement; pay in full."
    SMSG = "Good news: your glass claim review is approved and $700 is on its way."
    r = decide(dana, "CAI-CASE-000001", "APPROVE", "700", SNOTE, SMSG)
    check("Dana APPROVES Sarah's CAI-CASE-000001 at $700 -> APPROVED, payment executed",
          r.get("outcome") == "APPROVED" and num(r.get("approved_amount")) == 700 and "CAI-PAY-" in s(r.get("executed_action")), r)
    check("DB: decision row, claim Approved, claim_payments $700, CASE_DECIDED audit by CAS-3011",
          n("SELECT count(*) FROM review_decisions WHERE case_id='CAI-CASE-000001' AND reviewer_id='CAS-3011'") == 1
          and val("SELECT status FROM claims WHERE claim_no='CLM-2026-0051'") == "Approved"
          and num(val("SELECT amount FROM claim_payments WHERE claim_no='CLM-2026-0051'")) == 700
          and n("SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='CAI-CASE-000001'") == 1)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=sarah)}
    check("Sarah sees the outcome: APPROVED + customer message, never the internal note",
          mc.get("CAI-CASE-000001", {}).get("case_status") == "APPROVED" and mc["CAI-CASE-000001"].get("customer_message") == SMSG
          and SNOTE not in json.dumps(mc), mc.get("CAI-CASE-000001"))
    call("get_my_claims", session_token=sarah)

    # ---- guarded email: refusal first, then one real send ----
    before = n("SELECT count(*) FROM email_log")
    e = one("email_confirmation", session_token=sarah, reference=mclaim)
    check("SCOPE: Sarah emails Michael's claim -> NOT_SENT NOT_FOUND (normal readback)", e.get("send_status") == "NOT_SENT"
          and e.get("reason_code") == "NOT_FOUND", e)
    check("DB: refused email logged nothing", n("SELECT count(*) FROM email_log") == before)
    smtp = "not attempted"
    try:
        e = one("email_confirmation", timeout=180, session_token=michael, reference=mclaim)
        smtp = "SMTP send succeeded (tool returned normally)"
        check("email own filed claim -> SEND_OK payload over MCP", e.get("send_status") == "SEND_OK" and mclaim in s(e.get("subject")), e)
    except (RuntimeError, urllib.error.URLError, OSError) as ex:
        smtp = f"SMTP send failed (expected with the portable dummy email password): {str(ex)[:220]}"
        tsql = SPEC["email_confirmation"]["read"][0].replace("?r_tok", lit(michael)).replace("?r_ref", lit(mclaim))
        e = (q(tsql) or [{}])[0]
        check("email own filed claim -> payload SEND_OK (SQL side, read directly after the SMTP failure)",
              e.get("send_status") == "SEND_OK" and mclaim in s(e.get("subject")), e)
    NOTES.append(smtp)
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference={lit(mclaim)} AND policyholder_id='PH-0101'") == 1
          and n("SELECT count(*) FROM email_log") == before + 1)

    # ---- hidden data ----
    cust = [(t, rows) for t, rows in OUTPUTS if t in CUSTOMER_TOOLS]
    leaked = sorted({k for _, rows in cust for row in rows if isinstance(row, dict) for k in row} & HIDDEN_COLUMNS)
    check("no customer tool output carries a hidden column (SPEC 2b)", not leaked, leaked)
    # includes the policy-wording passages returned by search_policy_wording (the PDFs carry none of these strings)
    cvals = [(t, json.dumps(v) if isinstance(v, (dict, list)) else s(v)) for t, rows in cust
             for row in rows for v in row.values()]
    bad = [(t, v) for t, v in cvals if any(w in v.lower() for w in FORBIDDEN_CUSTOMER_STRINGS)]
    check("no customer tool output value contains fraud / SIU / Special Investigations / investigat (incl. Tyler after SIU)",
          not bad, bad[:3])
    cblob = "\n".join(v for _, v in cvals)
    secrets = [x["v"] for x in q("SELECT email v FROM policyholders UNION ALL SELECT internal_note FROM review_decisions "
                                 "UNION ALL SELECT agent_brief FROM service_cases WHERE agent_brief IS NOT NULL "
                                 "UNION ALL SELECT risk_indicators FROM claims WHERE risk_indicators IS NOT NULL")]
    check("customer outputs never contain emails, internal notes, briefs or indicators",
          not any(x and x in cblob for x in secrets), [x for x in secrets if x and x in cblob][:3])
    check("customer outputs never contain a band / score / route value",
          not re.search(r"SIU_REVIEW|ADJUSTER_REVIEW|risk score|signal points|narrative score", cblob, re.I))
    rev = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
    rleak = sorted({k for _, rows in rev for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
    check("no reviewer tool output carries a customer-private column", not rleak, rleak)
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

for x in NOTES:
    out("NOTE " + x)
total = passes + fails
out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{total} passed; DB reset)")
sys.exit(1 if fails else 0)
