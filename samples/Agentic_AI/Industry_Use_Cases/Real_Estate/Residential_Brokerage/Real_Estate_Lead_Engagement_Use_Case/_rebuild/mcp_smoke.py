#!/usr/bin/env python3
"""Test ladder step 3: call the running RealEstateMCPServer tools directly - no LLM - to prove the rules hold
at the MCP edge, asserting on DB state with psql.
Start the MCP server exe first, then:   python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9962/realestatemcp), PG_PWD (else PG_PASSWORD from config.md, never
printed), PG_DB (realestate_governed), PG_HOST/PG_PORT/PG_USER, PSQL, CONFIG_MD.
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (Delia's showing) to
the EMAIL_TO app property; the SQL guard + email_log are asserted, SMTP delivery is reported separately."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, REVIEWER_TOOLS

URL = os.environ.get("MCP_URL", "http://localhost:9962/realestatemcp")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "realestate_governed"),
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


def day(k):
    return q(f"SELECT to_char(current_date + {int(k)}, 'YYYY-MM-DD') AS v")[0]["v"]



DELIA_E = "delia.sorensen@example.com"


reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    check("tools/list = exactly the 18 tools from tool_spec.py", set(tools) == set(SPEC) and len(SPEC) == 18,
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
    r = one("verify_lead", email=DELIA_E, code="0000")
    check("wrong code -> VERIFY_FAILED, no token", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM sessions") == 0)
    r = one("verify_lead", email=DELIA_E.upper(), code="5172")
    check("Delia (upper-case e-mail) -> VERIFIED + token + first name + today", r["outcome"] == "VERIFIED"
          and r.get("session_token") and r.get("first_name") == "Delia" and s(r.get("today")).startswith(day(0)),
          {k: v for k, v in r.items() if k != "session_token"})
    delia = s(r.get("session_token")) or "missing"
    marco = s(one("verify_lead", email="marco.sandoval@example.com", code="3846").get("session_token")) or "missing"
    kiran = s(one("verify_lead", email="kiran.bhatt@example.com", code="9021").get("session_token")) or "missing"
    russell = s(one("verify_lead", email="russell.thorne@example.com", code="6630").get("session_token")) or "missing"
    check("Marco, Kiran and Russell verify", "missing" not in (marco, kiran, russell))
    r = one("verify_reviewer", staff_id="BPR-7101", code="9999")
    check("reviewer wrong code -> VERIFY_FAILED", r["outcome"] == "VERIFY_FAILED" and not r.get("session_token"), r)
    r = one("verify_reviewer", staff_id="bpr-7101", code="2468")
    check("Marisol -> VERIFIED REVIEWER, Sales Agents", r["outcome"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Sales Agents", {k: v for k, v in r.items() if k != "session_token"})
    marisol = s(r.get("session_token")) or "missing"
    imani = s(one("verify_reviewer", staff_id="BPR-7201", code="8642").get("session_token")) or "missing"

    # ---- bogus token on every scoped tool ----
    for t in TOOLS:
        if t["tool"] in ("verify_lead", "verify_reviewer"):
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = BAD
        row = one(t["tool"], **args)
        code = row.get("reason_code") if t.get("email") else (row.get("status") or row.get("outcome"))
        want = "NOT_REVIEWER" if t["tool"] in REVIEWER_TOOLS else "SESSION_INVALID"
        check(f"{t['tool']} with bogus token -> {want}", code == want, row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM showing_events") == 0 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM follow_up_tasks") == 1 and n("SELECT count(*) FROM service_cases") == 3
          and n("SELECT count(*) FROM email_log") == 0)
    check("role separation: reviewer token on a lead tool -> SESSION_INVALID",
          one("get_my_profile", session_token=marisol)["status"] == "SESSION_INVALID")

    # ---- scoped reads (multi-row tools must return ALL rows) ----
    p = one("get_my_profile", session_token=delia)
    check("get_my_profile: Delia, Nurturing, agent Marisol", p.get("name") == "Delia Sorensen" and p.get("journey_stage") == "Nurturing"
          and s(p.get("assigned_agent")).startswith("Marisol Vance"), p)
    rows = call("search_listings", session_token=delia, area="Cedar Hollow", max_price="750000", min_bedrooms="3", property_type="single family")
    check("search_listings Cedar Hollow <= $750k 3+ bd: 4 rows incl. the Pending one", sorted(s(x.get("listing_id")) for x in rows)
          == ["LST-50001", "LST-50002", "LST-50003", "LST-50004"], [x.get("listing_id") for x in rows])
    check("search_listings all areas: 12 rows (Sold / Withdrawn never)", len(call("search_listings", session_token=delia)) == 12)
    d1 = one("get_listing_details", session_token=delia, listing_id="1418 Quillfeather Ln")
    check("get_listing_details by address -> LST-50001 $689,000 with open slots", d1.get("listing_id") == "LST-50001"
          and num(d1.get("price")) == 689000 and s(d1.get("next_open_slots")), d1)
    av = call("get_showing_availability", session_token=delia, listing_id="LST-50001", date=day(2))
    check("get_showing_availability day+2: 9 open slots, Miles's 11:00 excluded", len(av) == 9
          and f"{day(2)} 11:00" not in [s(x.get("slot")) for x in av], [x.get("slot") for x in av])
    check("get_my_showings: Delia's one past showing", [s(x.get("appointment_id")) for x in call("get_my_showings", session_token=delia)] == ["APT-70003"])
    check("get_my_agent: Marisol Vance", one("get_my_agent", session_token=delia).get("agent_name") == "Marisol Vance")
    check("get_market_stats empty: 4 areas", len(call("get_market_stats", session_token=delia, area="")) == 4)
    check("get_my_cases: NONE for Delia", one("get_my_cases", session_token=delia).get("status") == "NONE")

    # ---- two-step booking over MCP ----
    S3 = f"{day(3)} 14:00"
    r = one("propose_showing", session_token=marco, listing_id="LST-50001", slot=S3)
    check("Marco (Under Contract) -> BLOCKED LEAD_STAGE_BLOCKED", r["outcome"] == "BLOCKED" and r.get("reason_code") == "LEAD_STAGE_BLOCKED", r)
    r = one("propose_showing", session_token=kiran, listing_id="LST-50004", slot=S3)
    check("Kiran on the Pending listing -> BLOCKED LISTING_NOT_ACTIVE", r["outcome"] == "BLOCKED" and r.get("reason_code") == "LISTING_NOT_ACTIVE", r)
    r = one("propose_showing", session_token=delia, listing_id="LST-50001", slot=f"{day(2)} 11:00")
    check("Delia on Miles's slot -> BLOCKED SLOT_TAKEN", r.get("reason_code") == "SLOT_TAKEN", r)
    r = one("propose_showing", session_token=delia, listing_id="LST-50001", slot=S3)
    check("Delia proposes LST-50001 day+3 14:00 -> PROPOSED", r["outcome"] == "PROPOSED" and s(r.get("proposal_id")).startswith("BPR-PRP-"), r)
    pid = s(r.get("proposal_id"))
    check("DB: nothing booked before confirm", n("SELECT count(*) FROM appointments WHERE source='CHAT'") == 0)
    r = one("confirm_showing", session_token=kiran, proposal_id=pid)
    check("SCOPE: Kiran confirms Delia's proposal -> NOT_FOUND", r["outcome"] == "NOT_FOUND", r)
    r = one("confirm_showing", session_token=delia, proposal_id=pid)
    check("confirm -> EXECUTED APT-70101, journey_stage Active", r["outcome"] == "EXECUTED" and r.get("appointment_id") == "APT-70101"
          and r.get("journey_stage") == "Active", r)
    check("DB: appointment + SQL stage move Nurturing -> Active",
          n("SELECT count(*) FROM appointments WHERE appointment_id='APT-70101' AND lead_id='LEAD-2026-00101'") == 1
          and n("SELECT count(*) FROM lead_stage_events WHERE lead_id='LEAD-2026-00101' AND new_stage='Active' AND source='SYSTEM'") == 1)
    check("confirm again -> ALREADY_DONE", one("confirm_showing", session_token=delia, proposal_id=pid)["outcome"] == "ALREADY_DONE")

    # ---- follow-up (priority in SQL) ----
    r = one("request_agent_follow_up", session_token=kiran, message="Relocating in two months, pre-approved, please call me.",
            intent="BUY", timeline="0_3_MONTHS", pre_approved="YES", motivation="job relocation", agent_brief="intent: BUY")
    check("follow-up -> FOLLOW_UP_REQUESTED FUP-90101, no priority in the reply", r["outcome"] == "FOLLOW_UP_REQUESTED"
          and r.get("follow_up_id") == "FUP-90101" and "priority" not in r, r)
    check("DB: SQL set HOT", n("SELECT count(*) FROM follow_up_tasks WHERE task_id='FUP-90101' AND priority='HOT'") == 1)
    check("second follow-up -> EXISTING", one("request_agent_follow_up", session_token=kiran, message="again please")["outcome"] == "EXISTING")

    # ---- cases + reviewer loop ----
    r = one("open_service_case", session_token=russell, request_type="list_price_change", summary="Drop to $598,000.",
            reference_id="LST-50014", amount="598000", agent_brief="")
    check("Russell list-price change -> OPENED BPR-CASE-000101 Sales Agents", r["outcome"] == "OPENED"
          and r.get("case_id") == "BPR-CASE-000101" and r.get("team") == "Sales Agents", r)
    case = s(r.get("case_id"))
    r = one("open_service_case", session_token=delia, request_type="list_price_change", summary="x", reference_id="LST-50014",
            amount="598000", agent_brief="")
    check("Delia cannot change Russell's price -> BLOCKED NOT_FOUND", r.get("reason_code") == "NOT_FOUND", r)
    r = one("open_service_case", session_token=delia, request_type="fair_housing_review", summary="Asked if the area is safe for kids.",
            reference_id="SAFETY_CRIME", amount="", agent_brief="flagged: YES | category: SAFETY_CRIME")
    check("fair-housing case -> OPENED Brokerage Compliance", r["outcome"] == "OPENED" and r.get("team") == "Brokerage Compliance", r)
    queue = call("get_review_queue", session_token=marisol)
    check("get_review_queue (Marisol): Russell's case + 2 seeded Sales Agents cases, no Compliance case",
          sorted(s(x.get("case_id")) for x in queue) == ["BPR-CASE-000001", "BPR-CASE-000003", case], [x.get("case_id") for x in queue])
    rc = one("get_review_case", session_token=marisol, case_id=case)
    check("get_review_case: allowed range + Marisol's $15,000 limit", "$520,200" in s(rc.get("allowed_range"))
          and num(rc.get("your_approval_limit")) == 15000, rc)
    check("get_review_case cross-team -> NOT_FOUND", one("get_review_case", session_token=imani, case_id=case).get("status") == "NOT_FOUND")
    r = one("decide_review_case", session_token=delia, case_id=case, decision="APPROVE", amount="", internal_note="self approve",
            customer_message="ok")
    check("lead token cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER" and n("SELECT count(*) FROM review_decisions") == 0, r)
    r = one("decide_review_case", session_token=marisol, case_id="BPR-CASE-000001", decision="APPROVE", amount="",
            internal_note="Soft market.", customer_message="Approved.")
    check("Marisol on the $40,000 cut -> OVER_AUTHORITY, case OPEN", r.get("reason_code") == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    r = one("decide_review_case", session_token=marisol, case_id=case, decision="APPROVE", amount="ok", internal_note="ok",
            customer_message="x")
    check("short note -> NOTE_REQUIRED", r.get("reason_code") == "NOTE_REQUIRED", r)
    r = one("decide_review_case", session_token=marisol, case_id=case, decision="APPROVE", amount="",
            internal_note="Comparables support it.", customer_message="Your new list price of $598,000 is live.")
    check("Marisol approves Russell's $14,000 cut -> APPROVED, price changed", r["outcome"] == "APPROVED"
          and "$612,000 to $598,000" in s(r.get("executed_action")), r)
    check("DB: decision row, listing at $598,000, LPC row, CASE_DECIDED audit",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{case}' AND reviewer_id='BPR-7101'") == 1
          and n("SELECT count(*) FROM listings WHERE listing_id='LST-50014' AND price=598000") == 1
          and n(f"SELECT count(*) FROM listing_price_changes WHERE case_id='{case}'") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE event_type='CASE_DECIDED' AND subject_id='{case}'") == 1)
    mc = one("get_my_cases", session_token=russell)
    check("Russell sees APPROVED + the message, not the note", mc.get("case_status") == "APPROVED"
          and "598,000" in s(mc.get("customer_message")) and "Comparables" not in json.dumps(mc), mc)

    # ---- guarded email: refusals first, then one real send ----
    e = one("email_confirmation", session_token=kiran, reference="APT-70101")
    check("SCOPE: Kiran emails Delia's showing -> NOT_SENT NOT_FOUND", e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NOT_FOUND", e)
    check("DB: refused email logged nothing", n("SELECT count(*) FROM email_log") == 0)
    try:
        e = one("email_confirmation", session_token=delia, reference="APT-70101")
        check("email own showing -> SEND_OK (SMTP delivered)", e["send_status"] == "SEND_OK" and "APT-70101" in s(e.get("subject")), e)
    except (RuntimeError, urllib.error.URLError) as ex:
        out(f"NOTE SMTP send failed (expected with the portable dummy Email_App_Password): {str(ex)[:160]}")
    check("DB: the authorised email request logged exactly one row (SQL guard passed)",
          n("SELECT count(*) FROM email_log WHERE reference='APT-70101' AND lead_id='LEAD-2026-00101'") == 1)

    # ---- hidden data ----
    lead_out = [(t, rows) for t, rows in OUTPUTS if t not in REVIEWER_TOOLS]
    leaked = sorted({k for _, rows in lead_out for row in rows for k in row} & HIDDEN_COLUMNS)
    check("no lead tool output carries a hidden column", not leaked, leaked)
    rev_out = [(t, rows) for t, rows in OUTPUTS if t in REVIEWER_TOOLS]
    rleak = sorted({k for _, rows in rev_out for row in rows for k in row} & HIDDEN_FROM_REVIEWER)
    check("no reviewer tool output carries a lead e-mail, phone, code or last name column", not rleak, rleak)
    check("every tool was exercised over MCP", {t for t, _ in OUTPUTS} == set(SPEC), set(SPEC) - {t for t, _ in OUTPUTS})
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
