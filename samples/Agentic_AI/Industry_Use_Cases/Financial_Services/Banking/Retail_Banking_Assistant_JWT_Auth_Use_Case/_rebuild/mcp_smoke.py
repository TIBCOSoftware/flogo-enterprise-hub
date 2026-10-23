#!/usr/bin/env python3
"""Step 3: call the running RetailBankingSecureMCPServer with real JWTs - no LLM - and prove every layer holds at the
MCP edge in the Flogo runtime:
  layer 1  the MCP Server trigger (JWT Token auth): no / forged / expired token -> HTTP 401; a tool whose scope is not
           in the token is not listed and cannot be called (view-only James, reviewers vs customers)
  layer 2  identity comes from the token: whoami returns the token's sub; a tool argument can never change who is asking
  layer 3  SQL: the verified sub is resolved in PostgreSQL - an unknown subject gets UNKNOWN_CALLER, a customer gets
           NOT_REVIEWER on reviewer tools (even with forged-on-purpose scopes), rows are scoped to the caller
plus the business rules end to end: two-step card block / dispute / payment (incl. a HIGH scam hold), the guarded email,
a routed case and the reviewer loop (queue, cross-team invisibility, OVER_AUTHORITY, approve -> parked action executed).

Start the MCP server first (its MCP.JWT_Secret must equal JWT_SECRET), then:
    JWT_SECRET=<secret> PG_PWD=<pwd> python _rebuild/mcp_smoke.py
Env: JWT_SECRET (required; tokens are minted in-process with mint_user_tokens.mint), MCP_URL (default
http://localhost:9972/retail-banking-mcp), PG_DB (banking_jwt_auth), PG_HOST/PG_PORT/PG_USER, PSQL.
The DB is reset (reset_data.sql) before and after. Attempts ONE real confirmation email (James's dispute) to To_Email;
the SQL guard + email_log are asserted, SMTP delivery is reported separately (the shipped password is a placeholder)."""
import csv, io, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import (TOOLS, REVIEWER_TOOLS, SHARED_TOOLS, CUSTOMER_TOOLS, HIDDEN_COLUMNS, PERSONAS,
                       CUSTOMER_FULL_SCOPES, CUSTOMER_VIEW_ONLY_SCOPES, REVIEWER_SCOPES, tools_for_scopes)
from mint_user_tokens import mint, sign, claims_for, WRONG_SECRET

URL = os.environ.get("MCP_URL", "http://localhost:9972/retail-banking-mcp")
SECRET = os.environ.get("JWT_SECRET") or sys.exit("set JWT_SECRET (the same HS256 secret as the app's MCP.JWT_Secret)")
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
        "-U", os.environ.get("PG_USER", "postgres"), "-d", os.environ.get("PG_DB", "banking_jwt_auth"),
        "-v", "ON_ERROR_STOP=1", "-q"]
fails = passes = 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

# ---------------- DB helpers ----------------
def q(sql):
    r = subprocess.run(BASE + ["--csv", "-c", sql], capture_output=True, text=True, env=ENV)
    if r.returncode: sys.exit(r.stderr)
    return list(csv.DictReader(io.StringIO(r.stdout)))

def n(sql): return int(list(q(sql)[0].values())[0])
def reset(): subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)

# ---------------- MCP streamable-HTTP JSON-RPC with Authorization: Bearer <jwt> ----------------
SPEC_ARGS = {t["tool"]: [a for a, _ in t["args"]] for t in TOOLS}
OUTPUTS = []

class ToolDenied(RuntimeError):
    """A JSON-RPC error from the MCP trigger (e.g. a tool outside the token's scopes)."""

class Client:
    def __init__(self, token):
        self.token, self.session, self.seq = token, None, 0

    def rpc(self, method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notify:
            self.seq += 1; body["id"] = self.seq
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token is not None: h["Authorization"] = "Bearer " + self.token
        if self.session: h["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(URL, json.dumps(body).encode(), method="POST", headers=h)
        with urllib.request.urlopen(req, timeout=60) as r:
            self.session = r.headers.get("Mcp-Session-Id") or self.session
            raw = r.read().decode()
        if notify or not raw.strip(): return None
        data = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")] or [raw]
        msg = json.loads(data[-1])
        if "error" in msg: raise ToolDenied(json.dumps(msg["error"]))
        return msg["result"]

    def open(self):
        self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
        self.rpc("notifications/initialized", notify=True)
        return self

    def tools(self): return {t["name"]: t for t in self.rpc("tools/list")["tools"]}

    def call(self, tool, extra=None, **args):
        args = {a: args.get(a, "") for a in SPEC_ARGS[tool]}
        args.update(extra or {})
        res = self.rpc("tools/call", {"name": tool, "arguments": args})
        text = res["content"][0]["text"]
        if res.get("isError"): raise RuntimeError(f"{tool} returned isError: {text[:300]}")
        body = json.loads(text)
        rows = (json.loads(body["data"]) if "data" in body else body)["records"]
        OUTPUTS.append((tool, rows))
        return rows

def http_status(token):
    """HTTP status of the MCP initialize call with this bearer token (None = no Authorization header)."""
    try:
        Client(token).open(); return 200, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace").strip()

# Flogo may hand numbers/booleans back as JSON numbers/bools or as strings - compare tolerantly
def num(v):
    try: return round(float(v), 2)
    except (TypeError, ValueError): return None
def yes(v): return v is True or str(v).strip().lower() in ("true", "t", "1", "yes")
def s(v): return "" if v is None else str(v)

def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0

def tok(persona, **kw): return mint(persona, SECRET, **kw)
JAMES = PERSONAS["james"]["sub"]
# transactions that belong to OTHER customers - must never appear in James's lists
FOREIGN_TXNS = {"TXN-50008", "TXN-50009", "TXN-50010", "TXN-50011", "TXN-50012", "TXN-50014", "TXN-50015",
                "TXN-50016", "TXN-50017", "TXN-50018", "TXN-50019", "TXN-50020", "TXN-50021", "TXN-50022", "TXN-50023"}
WRITE_TABLES = ("pending_actions", "service_cases", "payment_requests", "email_log", "review_decisions", "decide_attempts",
                "agent_audit")
def write_counts(): return [n(f"SELECT count(*) FROM {x}") for x in WRITE_TABLES]

reset()
try:
    # ================= layer 1: the Flogo MCP Server trigger validates the JWT =================
    st, msg = http_status(None)
    check("no Authorization header -> HTTP 401", st == 401, (st, msg))
    st, msg = http_status(mint("james", WRONG_SECRET))
    check("token signed with the wrong secret -> HTTP 401", st == 401 and "signature" in msg, (st, msg))
    st, msg = http_status(tok("james", hours=-1))
    check("expired token -> HTTP 401", st == 401 and "expired" in msg, (st, msg))
    st, msg = http_status(tok("james", nbf=int(time.time()) + 3600))
    check("token not valid yet (nbf in the future) -> HTTP 401", st == 401, (st, msg))
    st, msg = http_status("not.a.jwt")
    check("malformed token -> HTTP 401", st == 401, (st, msg))

    james = Client(tok("james")).open()
    tl = james.tools()
    expect_cust = tools_for_scopes(CUSTOMER_FULL_SCOPES)
    check("full customer token: tools/list = exactly the 14 customer tools + whoami + find_branch (16)",
          set(tl) == expect_cust == CUSTOMER_TOOLS | SHARED_TOOLS and len(tl) == 16,
          {"missing": sorted(expect_cust - set(tl)), "extra": sorted(set(tl) - expect_cust)})
    check("...and NO reviewer tool", not (set(tl) & REVIEWER_TOOLS), set(tl) & REVIEWER_TOOLS)
    reads = [t["tool"] for t in TOOLS if t.get("readonly") and t["tool"] in tl]
    check("readOnlyHint on every read tool", all(tl[r].get("annotations", {}).get("readOnlyHint") is True for r in reads),
          {r: tl[r].get("annotations") for r in reads})
    bad_schema = [t["tool"] for t in TOOLS if t["tool"] in tl
                  and not all(a in json.dumps(tl[t["tool"]].get("inputSchema")) for a, _ in t["args"])]
    check("every listed tool publishes its argument schema", not bad_schema, bad_schema)
    leaks = [name for name, t in tl.items() if re.search(r"session_token|passcode|customer_id|\"sub\"", json.dumps(t.get("inputSchema")))]
    check("no tool asks for an identity argument (no session_token / passcode / customer_id / sub)", not leaks, leaks)

    view = Client(tok("james_view")).open()
    vl = set(view.tools())
    check("view-only James: tools/list = whoami, find_branch and the 6 read tools only",
          vl == tools_for_scopes(CUSTOMER_VIEW_ONLY_SCOPES) and len(vl) == 8, sorted(vl))
    hidden = {"propose_card_block", "confirm_card_block", "propose_dispute", "confirm_dispute", "propose_payment",
              "confirm_payment", "open_service_case", "email_my_confirmation"}
    check("view-only James does NOT see card block / dispute / payment / case / email tools", not (vl & hidden), vl & hidden)
    w0 = write_counts()
    try:
        r = view.call("propose_card_block", card="1123", reason="LOST")
        denied, detail = False, r
    except ToolDenied as e:
        denied, detail = True, str(e)
    check("view-only James calling the hidden propose_card_block directly is refused by the trigger "
          "(JSON-RPC error 'token missing required scope')", denied and "missing required scope" in detail, detail)
    try:
        view.call("email_my_confirmation", reference_id="DSP-2026-0001"); denied = False
    except ToolDenied:
        denied = True
    check("...and so is the hidden email_my_confirmation", denied)
    check("DB: the refused calls never reached a flow (nothing written, CARD-9001 still ACTIVE)",
          write_counts() == w0 and q("SELECT status FROM cards WHERE card_id='CARD-9001'")[0]["status"] == "ACTIVE")
    r = view.call("get_my_accounts")
    check("view-only James can still read his own accounts", sorted(s(x["account_id"]) for x in r) == ["ACC-1001", "ACC-1002"], r)

    maya = Client(tok("maya")).open()
    ml = maya.tools()
    check("reviewer token (Maya): tools/list = the 3 reviewer tools + whoami + find_branch only",
          set(ml) == REVIEWER_TOOLS | SHARED_TOOLS == tools_for_scopes(REVIEWER_SCOPES), sorted(ml))
    ann = ml["decide_review_case"].get("annotations", {})
    check("decide_review_case hints: not read-only, not destructive, not idempotent",
          ann.get("readOnlyHint") is not True and ann.get("destructiveHint") is False and ann.get("idempotentHint") is not True, ann)
    try:
        maya.call("get_my_accounts"); denied = False
    except ToolDenied:
        denied = True
    check("a reviewer token cannot call a customer tool (not in its scopes)", denied)
    try:
        james.call("get_review_queue"); denied = False
    except ToolDenied:
        denied = True
    check("a customer token cannot call a reviewer tool (not in its scopes)", denied)

    # ================= layer 2: identity comes from the token, never from arguments =================
    w = james.call("whoami")[0]
    check("whoami(James's token) -> CUSTOMER, sub CUST-2026-00101, James Miller (= the token's sub + name)",
          w["role"] == "CUSTOMER" and w["subject"] == PERSONAS["james"]["sub"] and w["display_name"] == PERSONAS["james"]["name"]
          and not w.get("team"), w)
    w = maya.call("whoami")[0]
    check("whoami(Maya's token) -> REVIEWER, KST-7001, Maya Chen, Customer Care, limit 25",
          w["role"] == "REVIEWER" and w["subject"] == "KST-7001" and w["display_name"] == PERSONAS["maya"]["name"]
          and w["team"] == "Customer Care" and num(w["approval_limit"]) == 25.0, w)
    w = Client(tok("view-probe", sub="KST-7003", name="Priya Nair", scopes=["profile:read"])).open().call("whoami")[0]
    check("whoami(Priya, profile:read only) -> REVIEWER, Fraud Operations", w["role"] == "REVIEWER" and w["team"] == "Fraud Operations", w)
    ghost = Client(tok("ghost", sub="CUST-2026-99999", name="Nobody", scopes=CUSTOMER_FULL_SCOPES)).open()
    w = ghost.call("whoami")[0]
    check("validly signed token for an unknown subject -> whoami UNKNOWN", w["role"] == "UNKNOWN" and not w.get("display_name"), w)
    r = james.call("get_my_accounts", extra={"sub": "CUST-2026-00104", "customer_id": "CUST-2026-00104",
                                             "session_token": "CUST-2026-00104"})
    check("injected identity arguments (sub / customer_id / session_token = Sophia) are ignored: still James's accounts",
          sorted(s(x["account_id"]) for x in r) == ["ACC-1001", "ACC-1002"], r)

    # ================= layer 3: SQL resolves the verified subject (defence in depth) =================
    w0 = write_counts()
    for t in TOOLS:
        if t["tool"] in SHARED_TOOLS or t["tool"] in REVIEWER_TOOLS:
            continue
        args = {a: "x" for a, _ in t["args"]}
        row = ghost.call(t["tool"], **args)[0]
        code = row.get("caller_status") or row.get("reason_code")
        check(f"{t['tool']} with a valid token for an unknown subject -> UNKNOWN_CALLER", code == "UNKNOWN_CALLER", row)
    rev_as_cust = Client(tok("maya", scopes=CUSTOMER_FULL_SCOPES)).open()
    row = rev_as_cust.call("get_my_accounts")[0]
    check("a staff subject even with customer scopes is not a customer in SQL -> UNKNOWN_CALLER",
          row.get("caller_status") == "UNKNOWN_CALLER", row)
    cust_as_rev = Client(tok("michael", scopes=REVIEWER_SCOPES)).open()
    for t in sorted(REVIEWER_TOOLS):
        row = cust_as_rev.call(t, case_id="CASE-00004", decision="APPROVE", amount="", internal_note="smoke test note",
                               customer_message="x")[0]
        check(f"{t} by a customer subject even with reviewer scopes -> NOT_REVIEWER",
              (row.get("status") or row.get("outcome")) == "NOT_REVIEWER", row)
    check("DB: unknown / wrong-role subjects wrote nothing", write_counts() == w0, (w0, write_counts()))

    # ================= scoped reads =================
    r = james.call("get_my_accounts")
    check("get_my_accounts = James's ACC-1001 + ACC-1002 only",
          sorted(s(x["account_id"]) for x in r) == ["ACC-1001", "ACC-1002"] and r[0]["caller_status"] == "OK", r)
    r = james.call("get_my_transactions", search="")
    ids = {s(x["transaction_id"]) for x in r}
    check("get_my_transactions '' -> James's recent txns incl. TXN-50003", "TXN-50003" in ids and r[0]["caller_status"] == "OK", ids)
    check("no other customer's transaction in James's list", not (ids & FOREIGN_TXNS), ids & FOREIGN_TXNS)
    r = james.call("get_my_transactions", search="QUICKPAY")
    check("search QUICKPAY -> TXN-50003 + TXN-50013", sorted(s(x["transaction_id"]) for x in r) == ["TXN-50003", "TXN-50013"], r)
    r = james.call("get_my_transactions", search="GLOBAL*DIGITAL")
    check("James searching Sophia's descriptor -> NO_MATCH (cannot see her transaction)",
          r[0]["caller_status"] == "NO_MATCH" and not r[0].get("transaction_id"), r)
    r = james.call("get_my_transactions", search="TXN-50009")
    check("James searching Sophia's TXN-50009 by id -> NO_MATCH", r[0]["caller_status"] == "NO_MATCH", r)
    r = james.call("get_my_cards")
    check("get_my_cards = CARD-9001 ACTIVE ending 1123", [s(x["card_id"]) for x in r] == ["CARD-9001"]
          and r[0]["status"] == "ACTIVE" and s(r[0]["last4"]) == "1123", r)
    r = james.call("get_my_loans")
    check("get_my_loans = LOAN-3001 HOME", [s(x["loan_id"]) for x in r] == ["LOAN-3001"] and r[0]["loan_type"] == "HOME", r)
    r = james.call("get_my_cases")
    check("get_my_cases: James has none yet (Sophia's DSP-2026-0001 not visible)",
          r[0]["caller_status"] == "OK" and not any(x.get("reference_id") for x in r), r)
    r = james.call("find_branch", city="Chicago")
    check("find_branch Chicago -> BR-003", [s(x["branch_id"]) for x in r] == ["BR-003"] and r[0]["lookup_status"] == "OK", r)
    r = maya.call("find_branch", city="Atlantis")
    check("find_branch (reviewer token) unknown city -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND", r)

    # ================= card block: guards, two-step =================
    r = james.call("propose_card_block", card="1123", reason="BORED")[0]
    check("propose_card_block bad reason -> BAD_REASON", r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == "BAD_REASON", r)
    r = james.call("propose_card_block", card="4410", reason="LOST")[0]
    check("propose_card_block on Sophia's card (last4 4410) -> CARD_NOT_FOUND", r["reason_code"] == "CARD_NOT_FOUND", r)
    check("DB: refused proposals wrote no pending action", n("SELECT count(*) FROM pending_actions") == 0)
    b = james.call("propose_card_block", card="1123", reason="LOST")[0]
    check("propose_card_block 1123 LOST -> PROPOSED with action_id + delivery date",
          b["outcome"] == "PROPOSED" and b.get("action_id") and s(b.get("card_id")) == "CARD-9001"
          and b.get("replacement_expected_delivery"), b)
    check("DB: one pending CARD_BLOCK, card still ACTIVE (two-step: nothing changes before confirm)",
          n("SELECT count(*) FROM pending_actions WHERE action_type='CARD_BLOCK' AND card_id='CARD-9001'") == 1
          and q("SELECT status FROM cards WHERE card_id='CARD-9001'")[0]["status"] == "ACTIVE")
    sophia = Client(tok("sophia")).open()
    r = sophia.call("confirm_card_block", action_id=s(b.get("action_id")))[0]
    check("Sophia's token confirming James's proposal -> NO_SUCH_PROPOSAL", r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    r = james.call("confirm_card_block", action_id="ACT-00000000")[0]
    check("confirm_card_block bogus action -> NOT_EXECUTED NO_SUCH_PROPOSAL",
          r["outcome"] == "NOT_EXECUTED" and r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    c = james.call("confirm_card_block", action_id=s(b.get("action_id")))[0]
    check("confirm_card_block -> EXECUTED with BLK-NNNNN", c["outcome"] == "EXECUTED"
          and re.fullmatch(r"BLK-\d{5}", s(c.get("block_id"))), c)
    c2 = james.call("confirm_card_block", action_id=s(b.get("action_id")))[0]
    check("re-confirm -> ALREADY_EXECUTED (same block)", c2["reason_code"] == "ALREADY_EXECUTED" and c2.get("block_id") == c.get("block_id"), c2)
    check("DB: CARD-9001 BLOCKED + one card_replacements row",
          q("SELECT status FROM cards WHERE card_id='CARD-9001'")[0]["status"] == "BLOCKED"
          and n("SELECT count(*) FROM card_replacements WHERE card_id='CARD-9001'") == 1)

    # ================= dispute: cross-customer guard, quote, two-step, triggers =================
    r = james.call("propose_dispute", transaction_id="TXN-50009", reason_code="FRAUD",
                   customer_statement="I want to dispute this.")[0]
    check("James cannot dispute Sophia's TXN-50009 -> NOT_YOUR_TRANSACTION",
          r["outcome"] == "NOT_PROPOSED" and r["reason_code"] == "NOT_YOUR_TRANSACTION", r)
    check("DB: no pending DISPUTE written for TXN-50009", n("SELECT count(*) FROM pending_actions WHERE transaction_id='TXN-50009'") == 0)
    p = james.call("propose_dispute", transaction_id="TXN-50003", reason_code="UNRECOGNISED",
                   customer_statement="I never bought anything from QUICKPAY XYZ.")[0]
    check("propose_dispute TXN-50003 UNRECOGNISED -> PROPOSED, credit 249.99, fraud review, XYZ Gadgets",
          p["outcome"] == "PROPOSED" and p.get("action_id") and num(p.get("amount")) == 249.99
          and num(p.get("provisional_credit")) == 249.99 and yes(p.get("fraud_review"))
          and s(p.get("merchant")) == "XYZ Gadgets Online" and p.get("est_decision_date"), p)
    r = james.call("confirm_dispute", action_id=s(b.get("action_id")))[0]
    check("confirm_dispute with the card-block action -> NO_SUCH_PROPOSAL", r["reason_code"] == "NO_SUCH_PROPOSAL", r)
    check("DB: nothing filed before confirm", n("SELECT count(*) FROM disputes WHERE transaction_id='TXN-50003'") == 0)
    f = james.call("confirm_dispute", action_id=s(p.get("action_id")))[0]
    dsp = s(f.get("dispute_id"))
    check("confirm_dispute -> FILED DSP-2026-0002 with credit txn + fraud case",
          f["outcome"] == "FILED" and dsp == "DSP-2026-0002" and num(f.get("provisional_credit")) == 249.99
          and f.get("provisional_credit_txn") and f.get("fraud_case_id"), f)
    check("DB: disputes row for TXN-50003 (James, 249.99)",
          n(f"SELECT count(*) FROM disputes WHERE transaction_id='TXN-50003' AND customer_id='{JAMES}' "
            "AND provisional_credit=249.99") == 1)
    check("DB: trigger posted PENDING CREDIT 'PROVISIONAL CREDIT <dsp>' on ACC-1001",
          n(f"SELECT count(*) FROM transactions WHERE descriptor='PROVISIONAL CREDIT {dsp}' AND account_id='ACC-1001' "
            "AND txn_type='CREDIT' AND status='PENDING' AND amount=249.99") == 1)
    check("DB: trigger opened FRAUD_REVIEW case -> Fraud Operations",
          n(f"SELECT count(*) FROM service_cases WHERE request_type='FRAUD_REVIEW' AND dispute_id='{dsp}' "
            f"AND customer_id='{JAMES}' AND assigned_team='Fraud Operations'") == 1)
    r = james.call("get_my_cases")
    refs = {s(x.get("reference_id")) for x in r}
    check("get_my_cases now shows the dispute + fraud case, not Sophia's DSP-2026-0001",
          dsp in refs and s(f.get("fraud_case_id")) in refs and "DSP-2026-0001" not in refs, refs)
    r = view.call("get_my_cases")
    check("view-only James (same sub) sees the same dispute (data follows the sub, actions follow the scopes)",
          dsp in {s(x.get("reference_id")) for x in r}, r)

    # ================= guarded email (ONE real send attempt) =================
    try:
        e = james.call("email_my_confirmation", reference_id=dsp)[0]
        check(f"email_my_confirmation {dsp} -> SEND (SMTP delivered)", s(e.get("send_status")).upper() == "SEND", e)
    except Exception as ex:                       # noqa: BLE001 - the SQL guard is asserted below either way
        out(f"NOTE SMTP send failed (expected with the placeholder Email_App_Password): {str(ex)[:160]}")
    check(f"DB: the authorised email request for {dsp} was logged (SQL guard passed)",
          n(f"SELECT count(*) FROM email_log WHERE reference_id='{dsp}' AND customer_id='{JAMES}'") == 1)
    e = james.call("email_my_confirmation", reference_id="DSP-2026-9999")[0]
    check("email bogus reference -> NOT_SENT NO_SUCH_REFERENCE",
          e["send_status"] == "NOT_SENT" and e.get("reason_code") == "NO_SUCH_REFERENCE", e)
    e = james.call("email_my_confirmation", reference_id="DSP-2026-0001")[0]
    check("email Sophia's DSP-2026-0001 from James -> NOT_SENT", e["send_status"] == "NOT_SENT", e)

    # ================= human-owned request =================
    k0 = k = james.call("open_service_case", request_type="FEE_REFUND",
                        customer_statement="Please refund the monthly maintenance fee.",
                        brief="Customer asks for a fee refund; routed for a human to decide.")[0]
    check("open_service_case FEE_REFUND -> CASE_OPENED, Customer Care",
          k["outcome"] == "CASE_OPENED" and re.fullmatch(r"CASE-\d{5}", s(k.get("case_id")))
          and k.get("assigned_team") == "Customer Care", k)
    check("DB: FEE_REFUND case row for James",
          n(f"SELECT count(*) FROM service_cases WHERE request_type='FEE_REFUND' AND customer_id='{JAMES}'") == 1)
    k = james.call("open_service_case", request_type="LOAN_APPROVAL", customer_statement="Approve my loan.", brief="n/a")[0]
    check("open_service_case bad type -> NOT_OPENED BAD_TYPE", k["outcome"] == "NOT_OPENED" and k["reason_code"] == "BAD_TYPE", k)

    # ================= payments to saved payees: LOW two-step (Emma) and a HIGH scam hold (Patricia) =================
    emma = Client(tok("emma")).open()
    r = emma.call("get_my_payees")
    check("get_my_payees = Emma's 2 payees only", sorted(s(x["payee_id"]) for x in r) == ["PYE-0201", "PYE-0202"], r)
    pp = emma.call("propose_payment", from_account="ACC-1009", payee="PYE-0201", amount="1850.00",
                   customer_story="Monthly rent to my landlord.", scam_indicators="NONE", narrative_score="5",
                   agent_notes="indicators: NONE")[0]
    check("propose_payment rent to a known landlord -> PROPOSED", pp["outcome"] == "PROPOSED" and pp.get("payment_id"), pp)
    check("DB: nothing sent before confirm", n("SELECT count(*) FROM payment_sends") == 0)
    r = james.call("confirm_payment", payment_id=s(pp.get("payment_id")), acknowledge_warning="NO")[0]
    check("James's token confirming Emma's payment -> NO_SUCH_PAYMENT", r["reason_code"] == "NO_SUCH_PAYMENT", r)
    cp = emma.call("confirm_payment", payment_id=s(pp.get("payment_id")), acknowledge_warning="NO")[0]
    check("confirm_payment -> SENT, balance 5,600 -> 3,750", cp["outcome"] == "SENT" and num(cp.get("available_balance_after")) == 3750.0, cp)
    check("DB: POSTED debit for the rent + payment_sends row",
          n("SELECT count(*) FROM transactions WHERE account_id='ACC-1009' AND descriptor='PAYMENT TO HARBOR PROPERTY MANAGEMENT'") == 1
          and n("SELECT count(*) FROM payment_sends WHERE via='CUSTOMER'") == 1)
    pat = Client(tok("patricia")).open()
    h = pat.call("propose_payment", from_account="ACC-1014", payee="PYE-0102", amount="9500",
                 customer_story="A man from the bank's fraud team told me to move my savings to a safe account and not to tell the branch.",
                 scam_indicators="SAFE_ACCOUNT, IMPERSONATION, SECRECY", narrative_score="90",
                 agent_notes="indicators: SAFE_ACCOUNT, IMPERSONATION, SECRECY")[0]
    check("propose_payment safe-account story -> HELD_FOR_REVIEW with case id (no score in the reply)",
          h["outcome"] == "HELD_FOR_REVIEW" and re.fullmatch(r"CASE-\d{5}", s(h.get("case_id")))
          and "score" not in json.dumps(h).lower(), h)
    check("DB: request HELD (HIGH), PAYMENT_HOLD case for Fraud Operations, savings untouched",
          n(f"SELECT count(*) FROM payment_requests WHERE payment_id='{s(h.get('payment_id'))}' AND status='HELD' AND risk_band='HIGH'") == 1
          and n(f"SELECT count(*) FROM service_cases WHERE case_id='{s(h.get('case_id'))}' AND request_type='PAYMENT_HOLD' "
                "AND assigned_team='Fraud Operations'") == 1
          and q("SELECT available_balance FROM accounts WHERE account_id='ACC-1014'")[0]["available_balance"] == "24000.00")
    r = pat.call("confirm_payment", payment_id=s(h.get("payment_id")), acknowledge_warning="YES")[0]
    check("confirm_payment on a held payment -> NOT_SENT HELD_FOR_REVIEW", r["reason_code"] == "HELD_FOR_REVIEW", r)

    # ================= reviewer loop: queue, cross-team invisibility, decide =================
    r = maya.call("get_review_queue")
    ids = [s(x.get("case_id")) for x in r]
    check("get_review_queue (Maya) = Customer Care OPEN cases incl. seeded CASE-00004 and James's new fee refund",
          "CASE-00004" in ids and s(k0.get("case_id")) in ids and r[0]["status"] == "OK"
          and all(s(x.get("team")) == "Customer Care" for x in r), r)
    r = maya.call("get_review_case", case_id=s(h.get("case_id")))[0]
    check("get_review_case on a Fraud Operations case -> NOT_FOUND (cross-team invisible)", r["status"] == "NOT_FOUND", r)
    r = maya.call("get_review_case", case_id="CASE-00004")[0]
    check("get_review_case CASE-00004 -> facts, max $29, Maya's $25 limit", r["status"] == "OK" and num(r.get("max_approvable")) == 29.0
          and num(r.get("your_approval_limit")) == 25.0 and "LATE PAYMENT FEE" in s(r.get("facts")), r)
    r = maya.call("decide_review_case", case_id="CASE-00004", decision="APPROVE", amount="",
                  internal_note="Holiday delay confirmed.", customer_message="Your late fee has been refunded.")[0]
    check("decide_review_case full $29 > $25 limit -> BLOCKED OVER_AUTHORITY, case stays OPEN",
          r["outcome"] == "BLOCKED" and r["reason_code"] == "OVER_AUTHORITY" and r.get("case_status") == "OPEN", r)
    r = maya.call("decide_review_case", case_id="CASE-00004", decision="APPROVE", amount="20",
                  internal_note="Holiday delay confirmed; goodwill within my limit.", customer_message="We refunded $20.00 of the late fee.")[0]
    check("decide_review_case approve $20 -> APPROVED, fee refunded", r["outcome"] == "APPROVED" and num(r.get("approved_amount")) == 20.0
          and "refunded" in s(r.get("executed_action")), r)
    check("DB: decision row + FEE REFUND credit + CASE_DECIDED audit by KST-7001 (the reviewer's JWT sub)",
          n("SELECT count(*) FROM review_decisions WHERE case_id='CASE-00004' AND reviewer_id='KST-7001' AND approved_amount=20") == 1
          and n("SELECT count(*) FROM transactions WHERE descriptor='FEE REFUND TXN-50024' AND amount=20 AND txn_type='CREDIT'") == 1
          and n("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='CASE-00004' AND actor='KST-7001'") == 1)
    priya = Client(tok("priya")).open()
    r = priya.call("decide_review_case", case_id=s(h.get("case_id")), decision="REJECT", amount="",
                   internal_note="Caller told her to move the money; safe-account scam.",
                   customer_message="We stopped this payment to protect you. No money left your account.")[0]
    check("Priya (Fraud Operations) rejects Patricia's held payment -> REJECTED, payment cancelled",
          r["outcome"] == "REJECTED" and "cancelled" in s(r.get("executed_action"))
          and q(f"SELECT status FROM payment_requests WHERE payment_id='{s(h.get('payment_id'))}'")[0]["status"] == "CANCELLED", r)
    mike = Client(tok("michael")).open()
    r = {s(x.get("reference_id")): x for x in mike.call("get_my_cases")}
    check("the customer sees APPROVED + the customer message (never the note or reviewer)",
          s(r["CASE-00004"].get("status")) == "APPROVED" and "refunded" in s(r["CASE-00004"].get("customer_message"))
          and "goodwill" not in json.dumps(r) and "Maya" not in json.dumps(r), r.get("CASE-00004"))
    cust_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS and t != "whoami" for row in rows for k in row}
    check("customer tool outputs carry no hidden column", not (cust_cols & HIDDEN_COLUMNS), cust_cols & HIDDEN_COLUMNS)
    check("every MCP tool was called through the Flogo runtime", {t for t, _ in OUTPUTS} == {t["tool"] for t in TOOLS},
          {t["tool"] for t in TOOLS} - {t for t, _ in OUTPUTS})

    # ================= audit trail written by triggers =================
    au = {x["action"]: int(x["n"]) for x in q("SELECT action, count(*) AS n FROM agent_audit GROUP BY action")}
    check("DB: audit rows for CARD_BLOCKED, DISPUTE_FILED, SERVICE_CASE_OPENED, PAYMENT_SENT/HELD, CASE_DECIDED - "
          "and no sign-in rows (VERIFY / REVIEWER_VERIFY: identity is the IdP's job)",
          au.get("CARD_BLOCKED") == 1 and au.get("DISPUTE_FILED") == 1 and au.get("SERVICE_CASE_OPENED", 0) >= 3
          and au.get("PAYMENT_SENT") == 1 and au.get("PAYMENT_HELD") == 1 and au.get("CASE_DECIDED") == 2
          and "VERIFY" not in au and "REVIEWER_VERIFY" not in au, au)
    check("DB: every audit row carries the customer id", n("SELECT count(*) FROM agent_audit WHERE customer_id IS NULL") == 0)
finally:
    reset()

out(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; DB reset)")
sys.exit(1 if fails else 0)
