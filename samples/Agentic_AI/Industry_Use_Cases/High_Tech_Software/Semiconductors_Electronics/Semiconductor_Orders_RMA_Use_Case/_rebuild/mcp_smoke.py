#!/usr/bin/env python3
"""Test ladder step 3: call the running SemiOrdersMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9822/semiordersmcp), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (semiconductor_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (Tessa's order) to
the EMAIL_TO app property; the SQL guard + email_log are asserted, SMTP delivery is reported separately."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, REVIEWER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9822/semiordersmcp")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "semiconductor_governed"),
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
TESSA_E = "tessa.brandt@northfieldpower.example.com"


def day(k):
    return q(f"SELECT to_char(current_date + {int(k)}, 'YYYY-MM-DD') AS v")[0]["v"]


reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 21 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 21,
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
    r = one("verify_buyer", account_id="AC-10021", email=TESSA_E, code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_buyer", account_id="ac10021", email=TESSA_E.upper(), code="4827")
    check("Tessa 'ac10021' + upper-case e-mail -> VERIFIED + token + first name + company", r["outcome"] == "VERIFIED"
          and r.get("session_token") and r.get("first_name") == "Tessa" and r.get("company") == "Northfield Power Systems",
          {k: v for k, v in r.items() if k != "session_token"})
    tessa = s(r.get("session_token")) or "missing"
    hannah = s(one("verify_buyer", account_id="10047", email="hannah.cole@pinecrestauto.example.com", code="3390").get("session_token")) or "missing"
    luis = s(one("verify_buyer", account_id="AC-10034", email="luis.romero@bluegatemed.example.com", code="6153").get("session_token")) or "missing"
    check("Hannah (bare digits) and Luis verify", "missing" not in (hannah, luis))
    r = one("verify_reviewer", staff_id="ACS-5101", code="9999")
    check("reviewer wrong code -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="acs-5101", code="3141")
    check("Rosa -> VERIFIED REVIEWER, Quality Engineering", r["outcome"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Quality Engineering", {k: v for k, v in r.items() if k != "session_token"})
    rosa = s(r.get("session_token")) or "missing"
    abigail = s(one("verify_reviewer", staff_id="ACS-5303", code="1618").get("session_token")) or "missing"

    # ---- bogus token on every scoped tool ----
    for t in TOOLS:
        if t["tool"] in ("verify_buyer", "verify_reviewer"):
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = BAD
        row = one(t["tool"], **args)
        code = row.get("reason_code") if t.get("email") else (row.get("status") or row.get("outcome"))
        want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
        check(f"{t['tool']} with bogus token -> {want}", code == want, row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM account_events") == 0 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM expedite_events") == 0 and n("SELECT count(*) FROM service_cases") == 3
          and n("SELECT count(*) FROM email_log") == 0)
    check("role separation: reviewer token on a buyer tool -> SESSION_INVALID",
          one("get_my_orders", session_token=rosa)["status"] == "SESSION_INVALID")

    # ---- scoped reads (multi-row tools must return ALL rows) ----
    a = one("get_my_account", session_token=tessa)
    check("get_my_account: Northfield, Good standing, available credit $211,500", a.get("company") == "Northfield Power Systems"
          and a.get("credit_status") == "Good standing" and num(a.get("available_credit")) == 211500, a)
    check("search_catalog 'MOSFET 650V': 2 rows", sorted(s(x.get("part_number")) for x in call("search_catalog", session_token=tessa, query="MOSFET 650V"))
          == ["AW-MF-6508", "AW-MF-6515"])
    check("search_catalog empty: 17 rows", len(call("search_catalog", session_token=tessa, query="")) == 17)
    p = one("get_part_details", session_token=tessa, part_number="AW-SD-2010")
    check("get_part_details AW-SD-2010: EOL, LTB date as plain text, replacement", p.get("lifecycle") == "EOL"
          and s(p.get("ltb_date")) == day(30) and p.get("replacement_part") == "AW-SD-2011", p)
    ps = one("get_price_and_stock", session_token=tessa, part_number="AW-MF-4012", quantity="5000")
    check("get_price_and_stock 5,000 x AW-MF-4012: $0.81, $4,050.00 (computed in SQL)", num(ps.get("unit_price")) == 0.81
          and num(ps.get("extended_price")) == 4050 and ps.get("price_break") == "5,000+ tier", ps)
    check("get_cross_references AW-MF-6508: 2 rows", len(call("get_cross_references", session_token=tessa, part_number="AW-MF-6508")) == 2)
    check("get_lifecycle_notices (Hannah, empty part): 2 rows", len(call("get_lifecycle_notices", session_token=hannah, part_number="")) == 2)
    o = call("get_my_orders", session_token=tessa)
    check("get_my_orders (Tessa): 5 lines incl. SO-2026-0014/2", len(o) == 5 and any(x.get("line_ref") == "SO-2026-0014/2" for x in o), o)
    check("get_my_rmas (Luis): RMA-2026-0002 APPROVED", one("get_my_rmas", session_token=luis).get("rma_status") == "APPROVED")
    check("get_my_cases (Hannah): 2 rows", len(call("get_my_cases", session_token=hannah)) == 2)

    # ---- order two-step: blocked, then propose -> confirm ----
    r = one("propose_order", session_token=luis, part_number="AW-OP-2201", quantity="1000", po_number="BMD-2290")
    check("Luis (credit hold) -> BLOCKED CREDIT_HOLD", r["outcome"] == "BLOCKED" and r.get("reason_code") == "CREDIT_HOLD", r)
    r = one("propose_order", session_token=hannah, part_number="AW-SD-4030", quantity="5000", po_number="PA-1")
    check("Hannah past last-time-buy -> BLOCKED PAST_LAST_TIME_BUY", r.get("reason_code") == "PAST_LAST_TIME_BUY", r)
    p = one("propose_order", session_token=tessa, part_number="AW-MF-4012", quantity="5,000", po_number="NPS-PO-8120")
    check("propose 5,000 x AW-MF-4012 -> PROPOSED $4,050.00, nothing ordered yet", p["outcome"] == "PROPOSED" and p.get("proposal_id")
          and num(p.get("extended")) == 4050 and n("SELECT count(*) FROM sales_orders WHERE source='CHAT'") == 0, p)
    c = one("confirm_action", session_token=hannah, proposal_id=s(p.get("proposal_id")))
    check("SCOPE: Hannah confirms Tessa's proposal -> NOT_FOUND", c["outcome"] == "NOT_FOUND", c)
    c = one("confirm_action", session_token=tessa, proposal_id=s(p.get("proposal_id")))
    so = s(c.get("reference"))
    check("confirm -> EXECUTED SO-nnnn-0101; DB order line 5,000 @ $0.81", c["outcome"] == "EXECUTED" and re.fullmatch(r"SO-\d{4}-0101", so)
          and n(f"SELECT count(*) FROM order_lines WHERE order_number='{so}' AND quantity=5000 AND unit_price=0.81") == 1, c)

    # ---- RMA two-step -> Quality Engineering case ----
    r = one("propose_rma", session_token=tessa, order_number="SO-2026-0009", part_number="AW-VR-3350", quantity="10",
            failure_description="x", defect_type="OTHER", safety_relevant="NO")
    check("RMA on parts shipped 14 months ago -> BLOCKED OUT_OF_WARRANTY", r.get("reason_code") == "OUT_OF_WARRANTY", r)
    p = one("propose_rma", session_token=tessa, order_number="SO-2026-0011", part_number="AW-MF-6508", quantity="40",
            failure_description="40 MOSFETs failed in our solar inverters after a few weeks; gate shorted.",
            defect_type="ELECTRICAL_FAILURE", safety_relevant="YES", triage_brief="defect_type: ELECTRICAL_FAILURE; safety_relevant: YES")
    c = one("confirm_action", session_token=tessa, proposal_id=s(p.get("proposal_id")))
    rma, rcase = s(c.get("reference")), s(c.get("case_id"))
    check("RMA PROPOSED -> EXECUTED RMA-nnnn-0101 + Quality Engineering case (SAFETY priority)", p["outcome"] == "PROPOSED"
          and c["outcome"] == "EXECUTED" and re.fullmatch(r"RMA-\d{4}-0101", rma) and c.get("team") == "Quality Engineering"
          and n(f"SELECT count(*) FROM service_cases WHERE case_id='{rcase}' AND priority='SAFETY' AND requested_amount=54.40") == 1, (p, c))

    # ---- expedite + alerts ----
    r = one("request_expedite", session_token=tessa, line_ref="SO-2026-0014/1", new_date=day(7))
    check("expedite in-stock line to +7 -> EXPEDITED, DB promised date moved", r["outcome"] == "EXPEDITED"
          and q("SELECT d(promised_date) AS v FROM order_lines WHERE order_number='SO-2026-0014' AND line_no=1")[0]["v"] == day(7), r)
    r = one("request_expedite", session_token=tessa, line_ref="SO-2026-0014/2", new_date=day(14))
    check("expedite backordered line to +14 -> BLOCKED FACTORY_EXPEDITE_REQUIRED", r.get("reason_code") == "FACTORY_EXPEDITE_REQUIRED", r)
    r1 = one("subscribe_pcn_alerts", session_token=tessa, part_number="AW-MF-6508")
    r2 = one("subscribe_pcn_alerts", session_token=tessa, part_number="AW-MF-6508")
    check("subscribe -> SUBSCRIBED, again -> ALREADY_SUBSCRIBED (one row)", r1["outcome"] == "SUBSCRIBED"
          and r2["outcome"] == "ALREADY_SUBSCRIBED" and n("SELECT count(*) FROM pcn_subscriptions WHERE account_id='AC-10021'") == 1)

    # ---- human-owned cases ----
    k = one("open_service_case", session_token=tessa, request_type="factory_expedite", summary="Need the AW-MC-3204 line in two weeks.",
            reference_id="SO-2026-0014/2", requested_date=day(14))
    check("factory_expedite -> OPENED, Sales & Pricing", k["outcome"] == "OPENED" and k.get("team") == "Sales & Pricing", k)
    k = one("open_service_case", session_token=luis, request_type="credit_review", summary="Please release our credit hold.")
    check("credit_review (hold release) -> OPENED, Credit", k["outcome"] == "OPENED" and k.get("team") == "Credit", k)
    check("open_service_case INVALID_TYPE for rma_disposition", one("open_service_case", session_token=tessa,
          request_type="rma_disposition", summary="x")["outcome"] == "INVALID_TYPE")

    # ---- reviewer loop: happy path + one blocked call per tool ----
    qids = [s(x.get("case_id")) for x in call("get_review_queue", session_token=rosa)]
    check("get_review_queue (Rosa): the new SAFETY RMA case first + the seeded RMA case, nothing else", qids == [rcase, "ARC-CASE-000001"], qids)
    check("get_review_queue with a buyer token -> NOT_REVIEWER", one("get_review_queue", session_token=tessa)["status"] == "NOT_REVIEWER")
    rc = one("get_review_case", session_token=rosa, case_id=rcase)
    check("get_review_case: brief + facts + max $54.40 USD credit", rc["status"] == "OK" and "ELECTRICAL_FAILURE" in s(rc.get("agent_brief"))
          and num(rc.get("max_approvable")) == 54.40 and rc.get("amount_unit") == "USD credit" and "safety-relevant yes" in s(rc.get("facts")), rc)
    check("get_review_case on another team's case -> NOT_FOUND",
          one("get_review_case", session_token=rosa, case_id="ARC-CASE-000003")["status"] == "NOT_FOUND")
    r = one("decide_review_case", session_token=tessa, case_id=rcase, decision="APPROVE", amount="54.40",
            internal_note="self approval", customer_message="approved")
    check("decide with the buyer's token -> NOT_REVIEWER, no decision", r["outcome"] == "NOT_REVIEWER"
          and n("SELECT count(*) FROM review_decisions") == 0, r)
    r = one("decide_review_case", session_token=rosa, case_id=rcase, decision="APPROVE", amount="54.40", internal_note="ok")
    check("decide with a 2-char note -> NOTE_REQUIRED", r.get("reason_code") == "NOTE_REQUIRED", r)
    r = one("decide_review_case", session_token=rosa, case_id="ARC-CASE-000003", decision="APPROVE", amount="100", internal_note="Not my team.")
    check("decide another team's case -> NOT_YOUR_TEAM", r.get("reason_code") == "NOT_YOUR_TEAM", r)
    r = one("decide_review_case", session_token=abigail, case_id="ARC-CASE-000003", decision="APPROVE", amount="90000",
            internal_note="Program confirmed by the customer.")
    check("Abigail approves a $90,000 limit over her $75,000 authority -> OVER_AUTHORITY, case still OPEN",
          r.get("reason_code") == "OVER_AUTHORITY"
          and q("SELECT status AS v FROM service_cases WHERE case_id='ARC-CASE-000003'")[0]["v"] == "OPEN", r)
    MSG = "Your RMA is approved and a $54.40 credit has been issued."
    r = one("decide_review_case", session_token=rosa, case_id=rcase, decision="APPROVE", amount="54.40",
            internal_note="Failure analysis confirms gate damage; full credit.", customer_message=MSG)
    check("Rosa approves the RMA -> APPROVED, credit memo executed", r["outcome"] == "APPROVED" and "CM-" in s(r.get("executed_action")), r)
    check("DB: decision row, RMA APPROVED, credit memo $54.40, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{rcase}'") == 1
          and q(f"SELECT status AS v FROM rmas WHERE rma_id='{rma}'")[0]["v"] == "APPROVED"
          and num(q(f"SELECT amount AS v FROM credit_memos WHERE rma_id='{rma}'")[0]["v"]) == 54.40
          and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{rcase}'") == 1)
    r = one("decide_review_case", session_token=rosa, case_id=rcase, decision="REJECT", internal_note="Second decision.")
    check("second decision -> ALREADY_DECIDED", r.get("reason_code") == "ALREADY_DECIDED", r)
    mc = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=tessa)}
    check("buyer sees the outcome: APPROVED + customer message, no internal note",
          mc.get(rcase, {}).get("case_status") == "APPROVED" and mc[rcase].get("customer_message") == MSG
          and "Failure analysis confirms" not in json.dumps(mc), mc.get(rcase))

    # ---- guarded email: refusals first, then one real send ----
    e = one("email_confirmation", session_token=hannah, reference=so)
    check("SCOPE: Hannah emails Tessa's order -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    check("DB: refused email logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_confirmation", session_token=tessa, reference=so)
        check("email own order -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK" and so in s(e.get("subject")), e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the portable dummy Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference='{so}' AND account_id='AC-10021'") == 1)

    # ---- hidden data ----
    buy = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
    leaked = sorted({k for _, rows in buy for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no buyer tool output carries a hidden column", not leaked, leaked)
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
