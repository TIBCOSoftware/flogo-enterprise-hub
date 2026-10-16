#!/usr/bin/env python3
"""Step 3: call the running AuthorServicesMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, then:   PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: MCP_URL (default http://localhost:9842/author-services-mcp), PG_DB (author_services), PG_HOST/PG_PORT/PG_USER, PSQL.
Covers the 10 author tools (scoped reads, review comments, submission check gate, two-step transfer, routed cases) and
the 4 reviewer tools (happy path + one blocked call each, parked APC waiver executed).
The DB is reset (reset_data.sql) before and after."""
import csv, io, json, os, re, shutil, subprocess, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, REVIEWER_TOOLS, PUBLIC_TOOLS, HIDDEN_COLUMNS

URL = os.environ.get("MCP_URL", "http://localhost:9842/author-services-mcp")
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# psql + password lookup (cross-platform): env PSQL > config.md PSQL_PATH > psql on PATH;
# password: env PG_PWD / PG_PASSWORD > config.md PG_PASSWORD (never printed). Install hints: skills-library/AGENT.md
# -> "Prerequisites and preflight".
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "author_services"),
        "-v", "ON_ERROR_STOP=1", "-q"]
session, seq, fails, passes = None, 0, 0, 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

# ---------------- DB helpers ----------------
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
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
    with urllib.request.urlopen(req, timeout=30) as r:
        session = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode()
    if notify or not raw.strip(): return None
    data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
    msg = json.loads(data[-1])
    if "error" in msg: raise RuntimeError(msg["error"])
    return msg["result"]

SPEC_ARGS = {t["tool"]: [a for a, _ in t["args"]] for t in TOOLS}
OUTPUTS = []

def call(tool, **args):
    args = {a: args.get(a, "") for a in SPEC_ARGS[tool]}          # every spec arg is sent (required in the schema)
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
    body = json.loads(text)
    rows = (json.loads(body["data"]) if "data" in body else body)["records"]
    OUTPUTS.append((tool, rows))
    return rows

# Flogo may hand numbers back as JSON numbers or as strings - compare tolerantly
def num(v):
    try: return round(float(v), 2)
    except (TypeError, ValueError): return None
def s(v): return "" if v is None else str(v)

def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0

reset()
try:
    # ---- handshake + tool contract ----
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
    expected = {t["tool"] for t in TOOLS}
    check("tools/list = exactly the 14 tools from tool_spec.py", set(tools) == expected and len(expected) == 14,
          {"missing": sorted(expected - set(tools)), "extra": sorted(set(tools) - expected)})
    reads = [t["tool"] for t in TOOLS if t.get("readonly") and t["tool"] in tools]
    check("readOnlyHint on every read tool", all(tools[r].get("annotations", {}).get("readOnlyHint") is True for r in reads),
          {r: tools[r].get("annotations") for r in reads})
    bad_schema = [t["tool"] for t in TOOLS if t["tool"] in tools
                  and not all(a in json.dumps(tools[t["tool"]].get("inputSchema")) for a, _ in t["args"])]
    check("every tool publishes its argument schema", not bad_schema, bad_schema)
    ann = tools["decide_review_case"].get("annotations", {})
    check("decide_review_case hints: not read-only, not destructive, not idempotent",
          ann.get("readOnlyHint") is not True and ann.get("destructiveHint") is not True and ann.get("idempotentHint") is not True, ann)
    # (the runtime omits false hints from tools/list; the .flogo holds real JSON booleans - validator G8)

    # ---- identity ----
    r = call("verify_author", orcid="0000-0002-1825-0097", verification_code="000000")
    check("wrong code -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0].get("session_token"), r)
    check("DB: wrong code created no session", n("SELECT count(*) FROM author_sessions") == 0)
    r = call("verify_author", orcid="0000-0002-1825-0097", verification_code="482913")
    check("Maya right code -> VERIFIED + token + name", r[0]["status"] == "VERIFIED" and r[0].get("session_token")
          and r[0].get("author_name") == "Dr. Maya Okafor", {k: v for k, v in r[0].items() if k != "session_token"})
    maya = r[0].get("session_token") or "missing"
    check("DB: exactly one AUTHOR session, for Maya",
          n("SELECT count(*) FROM author_sessions WHERE author_id='AUT-1001' AND role='AUTHOR'") == 1
          and n("SELECT count(*) FROM author_sessions") == 1)

    # ---- SESSION_INVALID on every scoped author tool, NOT_REVIEWER on every reviewer tool (no writes) ----
    n_cases0 = n("SELECT count(*) FROM review_cases")
    for t in TOOLS:
        if t["tool"] in PUBLIC_TOOLS:
            continue
        if t["tool"] in REVIEWER_TOOLS:
            row = call(t["tool"], session_token="bogus-token-0000", case_id="RC-S0A1F1", decision="APPROVE",
                       internal_note="smoke test note", customer_message="x")[0]
            check(f"{t['tool']} with bogus token -> NOT_REVIEWER", (row.get("status") or row.get("outcome")) == "NOT_REVIEWER", row)
            continue
        args = {a: "x" for a, _ in t["args"]}
        args["session_token"] = "bogus-token-0000"
        row = call(t["tool"], **args)[0]
        check(f"{t['tool']} with bogus token -> SESSION_INVALID", "SESSION_INVALID" in json.dumps(row), row)
    check("DB: bogus-token calls wrote nothing", n("SELECT count(*) FROM pending_actions") == 0
          and n("SELECT count(*) FROM review_cases") == n_cases0 and n("SELECT count(*) FROM review_decisions") == 0
          and n("SELECT count(*) FROM submission_checks") == 0)

    # ---- scoped reads ----
    r = call("get_my_manuscripts", session_token=maya)
    check("get_my_manuscripts = Maya's 3 only", sorted(s(x["manuscript_id"]) for x in r) == ["MS-2026-0301", "MS-2026-0388", "MS-2026-0412"], r)
    r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0450")
    check("another author's manuscript -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND" and not r[0].get("title"), r)
    r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0412")[0]
    check("get_manuscript 0412 -> declarations on file", "Zenodo" in s(r.get("declarations")), r)
    r = call("get_review_comments", session_token=maya, manuscript_id="MS-2026-0301")
    check("get_review_comments 0301 -> E.1 + 6 reviewer comments with sources",
          [s(x["comment_ref"]) for x in r] == ["E.1", "R1.1", "R1.2", "R1.3", "R2.1", "R2.2", "R2.3"]
          and s(r[3].get("source")) == "Reviewer 1" and s(r[4].get("source")) == "Reviewer 2", [s(x.get("comment_ref")) for x in r])
    r = call("get_review_comments", session_token=maya, manuscript_id="MS-2026-0388")
    check("get_review_comments without comments -> NO_COMMENTS", r[0]["lookup_status"] == "NO_COMMENTS", r)
    r = call("check_apc_coverage", session_token=maya, journal_code="HCRL")[0]
    check("check_apc_coverage HCRL -> covered 100%, pays 0", num(r.get("coverage_pct")) == 100 and num(r.get("author_pays_usd")) == 0, r)

    # ---- the statements gate + two-step transfer ----
    r = call("propose_transfer", session_token=maya, manuscript_id="MS-2026-0412", journal_code="EDSR")[0]
    check("propose_transfer over the word limit -> NOT_PROPOSED OVER_WORD_LIMIT", s(r.get("reason")).startswith("OVER_WORD_LIMIT"), r)
    r = call("propose_transfer", session_token=maya, manuscript_id="MS-2026-0412", journal_code="HCRL")[0]
    check("propose_transfer before any check -> CHECK_REQUIRED", r["outcome"] == "NOT_PROPOSED" and s(r.get("reason")).startswith("CHECK_REQUIRED"), r)
    c = call("record_submission_check", session_token=maya, manuscript_id="MS-2026-0412", journal_code="CHRR", statements="",
             missing_items="NONE", agent_notes="journal: CHRR\nmissing_items: NONE")[0]
    check("record_submission_check 0412 -> CHRR: presence check -> INCOMPLETE (AUTHOR_CONTRIBUTIONS) with the policy wording",
          c["outcome"] == "RECORDED" and c["result"] == "INCOMPLETE" and c.get("mandatory_missing") == "AUTHOR_CONTRIBUTIONS"
          and "CRediT" in s(c.get("policy_wording")), c)
    r = call("propose_transfer", session_token=maya, manuscript_id="MS-2026-0412", journal_code="CHRR")[0]
    check("propose_transfer to CHRR -> STATEMENTS_INCOMPLETE, nothing written",
          s(r.get("reason")).startswith("STATEMENTS_INCOMPLETE") and n("SELECT count(*) FROM pending_actions") == 0, r)
    c = call("record_submission_check", session_token=maya, manuscript_id="MS-2026-0412", journal_code="HCRL", statements="",
             missing_items="AUTHOR_CONTRIBUTIONS", agent_notes="journal: HCRL\nmissing_items: AUTHOR_CONTRIBUTIONS")[0]
    check("record_submission_check 0412 -> HCRL: COMPLETE (author contributions only recommended)",
          c["result"] == "COMPLETE" and c.get("recommended_missing") == "AUTHOR_CONTRIBUTIONS" and not c.get("mandatory_missing"), c)
    r = call("record_submission_check", session_token=maya, manuscript_id="MS-2026-0466", journal_code="EDSR", statements="",
             missing_items="NONE", agent_notes="x")[0]
    check("record_submission_check on another author's manuscript -> NOT_RECORDED NOT_FOUND",
          r["outcome"] == "NOT_RECORDED" and r["reason_code"] == "NOT_FOUND", r)
    check("DB: exactly 2 checks recorded for Maya, with the agent answer stored",
          n("SELECT count(*) FROM submission_checks WHERE author_id='AUT-1001'") == 2
          and n("SELECT count(*) FROM submission_checks WHERE agent_notes LIKE 'journal: HCRL%'") == 1)
    p = call("propose_transfer", session_token=maya, manuscript_id="MS-2026-0412", journal_code="HCRL")[0]
    check("propose_transfer HCRL -> PROPOSED, pays 0", p["outcome"] == "PROPOSED" and p.get("action_id") and num(p.get("author_pays_usd")) == 0, p)
    r = call("confirm_transfer", session_token=maya, action_id="ACT-00000000")[0]
    check("confirm_transfer bogus id -> ACTION_NOT_FOUND", s(r.get("reason")).startswith("ACTION_NOT_FOUND"), r)
    cf = call("confirm_transfer", session_token=maya, action_id=s(p.get("action_id")))[0]
    check("confirm_transfer -> EXECUTED", cf["outcome"] == "EXECUTED", cf)
    check("DB: transfer row + manuscript at HCRL", n("SELECT count(*) FROM transfers WHERE manuscript_id='MS-2026-0412'") == 1
          and q("SELECT journal_code FROM manuscripts WHERE manuscript_id='MS-2026-0412'")[0]["journal_code"] == "HCRL")

    # ---- human-owned requests: a parked APC waiver (Lars) ----
    lars = call("verify_author", orcid="0000-0004-7316-2588", verification_code="771204")[0]["session_token"]
    k = call("open_review_case", session_token=lars, manuscript_id="MS-2026-0450", request_type="APC_WAIVER",
             author_statement="Our agreement budget is used up and I have no grant left. Can the fee be waived?",
             brief="Accepted article at CHRR; agreement budget exhausted; author asks for a waiver.")[0]
    check("open_review_case APC_WAIVER -> CASE_OPENED, Open Access Office, requested $2,900",
          k["outcome"] == "CASE_OPENED" and s(k.get("assigned_team")) == "Open Access Office" and num(k.get("requested_amount")) == 2900, k)
    lars_case = s(k.get("case_id"))
    check("DB: the case parks APC_WAIVER:MS-2026-0450",
          n(f"SELECT count(*) FROM review_cases WHERE case_id='{lars_case}' AND parked_action='APC_WAIVER:MS-2026-0450'") == 1)
    k = call("open_review_case", session_token=lars, manuscript_id="MS-2026-0450", request_type="REFUND",
             author_statement="x", brief="x")[0]
    check("open_review_case bad type -> NOT_OPENED BAD_REQUEST_TYPE", k["outcome"] == "NOT_OPENED" and s(k.get("reason")).startswith("BAD_REQUEST_TYPE"), k)

    # ---- reviewer tools: happy path + one blocked call each ----
    r = call("verify_reviewer", staff_id="PUB-7001", code="000000")[0]
    check("verify_reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r.get("session_token"), r)
    r = call("verify_reviewer", staff_id="PUB-7001", code="246810")[0]
    check("verify_reviewer Grace -> VERIFIED, REVIEWER, Open Access Office", r["status"] == "VERIFIED" and r.get("role") == "REVIEWER"
          and r.get("team") == "Open Access Office", {k_: v for k_, v in r.items() if k_ != "session_token"})
    grace = s(r.get("session_token"))
    r = call("get_review_queue", session_token=lars)
    check("get_review_queue with an author token -> NOT_REVIEWER", r[0]["status"] == "NOT_REVIEWER", r)
    r = call("get_review_queue", session_token=grace)
    ids = [s(x.get("case_id")) for x in r]
    check("get_review_queue = Open Access Office OPEN cases: seeded RC-S0A1F1 + Lars's new waiver",
          sorted(ids) == sorted(["RC-S0A1F1", lars_case]) and all(s(x.get("team")) == "Open Access Office" for x in r), r)
    r = call("get_review_case", session_token=grace, case_id="RC-S0B2E2")[0]
    check("get_review_case on an Editorial Office case -> NOT_FOUND (cross-team invisible)", r["status"] == "NOT_FOUND", r)
    r = call("get_review_case", session_token=grace, case_id=lars_case)[0]
    check("get_review_case Lars -> max $2,900, Grace's $1,500 limit, APC facts", r["status"] == "OK" and num(r.get("max_approvable")) == 2900
          and num(r.get("your_approval_limit")) == 1500 and "budget" in s(r.get("facts")), r)
    r = call("decide_review_case", session_token=grace, case_id=lars_case, decision="APPROVE", amount="",
             internal_note="Budget exhausted, verified.", customer_message="Your fee has been waived.")[0]
    check("decide_review_case full $2,900 > $1,500 limit -> BLOCKED OVER_AUTHORITY, case stays OPEN",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    r = call("decide_review_case", session_token=grace, case_id=lars_case, decision="APPROVE", amount="1200",
             internal_note="Budget exhausted, verified; partial waiver within my limit.",
             customer_message="We have waived $1,200.00 of your article processing charge.")[0]
    check("decide_review_case approve $1,200 -> APPROVED, APC reduced (author pays $1,700)",
          r["outcome"] == "APPROVED" and num(r.get("approved_amount")) == 1200 and "$1,700.00" in s(r.get("executed_action")), r)
    check("DB: decision row + apc_reductions row + CASE_DECIDED + APC_REDUCED audit by PUB-7001",
          n(f"SELECT count(*) FROM review_decisions WHERE case_id='{lars_case}' AND reviewer_id='PUB-7001' AND approved_amount=1200") == 1
          and n(f"SELECT count(*) FROM apc_reductions WHERE case_id='{lars_case}' AND waived_usd=1200 AND author_pays_usd=1700") == 1
          and n(f"SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='{lars_case}' AND actor='PUB-7001'") == 1
          and n("SELECT count(*) FROM agent_audit WHERE action='APC_REDUCED'") == 1)
    r = call("decide_review_case", session_token=grace, case_id=lars_case, decision="REJECT", amount="",
             internal_note="second try", customer_message="x")[0]
    check("a second decision -> BLOCKED ALREADY_DECIDED", r["reason_code"] == "ALREADY_DECIDED", r)
    r = {s(x.get("case_id")): x for x in call("get_my_cases", session_token=lars)}
    check("the author sees APPROVED + $1,200 + the message (never the note or reviewer)",
          s(r[lars_case].get("status")) == "APPROVED" and num(r[lars_case].get("approved_amount")) == 1200
          and "waived" in s(r[lars_case].get("customer_message"))
          and "verified" not in json.dumps(r) and "Grace" not in json.dumps(r), r.get(lars_case))
    r = call("get_manuscript", session_token=lars, manuscript_id="MS-2026-0450")[0]
    check("get_manuscript shows $1,200 waived and $1,700 due", num(r.get("apc_waived_usd")) == 1200 and num(r.get("apc_due_usd")) == 1700, r)
    auth_cols = {k_ for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k_ in row}
    check("author tool outputs carry no hidden column", not (auth_cols & HIDDEN_COLUMNS), auth_cols & HIDDEN_COLUMNS)

    # ---- audit trail written by triggers ----
    au = {x["action"]: int(x["n"]) for x in q("SELECT action, count(*) AS n FROM agent_audit GROUP BY action")}
    check("DB: audit rows for VERIFY, SUBMISSION_CHECKED, TRANSFER_PROPOSED, TRANSFERRED, CASE_OPENED, REVIEWER_VERIFY, CASE_DECIDED, APC_REDUCED",
          au.get("VERIFY", 0) >= 2 and au.get("SUBMISSION_CHECKED") == 2 and au.get("TRANSFER_PROPOSED") == 1
          and au.get("TRANSFERRED") == 1 and au.get("CASE_OPENED", 0) == 5 and au.get("REVIEWER_VERIFY") == 1
          and au.get("CASE_DECIDED") == 1 and au.get("APC_REDUCED") == 1, au)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
