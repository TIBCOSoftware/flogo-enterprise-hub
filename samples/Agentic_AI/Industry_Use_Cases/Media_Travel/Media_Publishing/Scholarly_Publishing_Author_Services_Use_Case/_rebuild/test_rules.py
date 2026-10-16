#!/usr/bin/env python3
"""Run the EXACT tool SQL from tool_spec.py against the author_services DB and assert the business rules.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> python _rebuild/test_rules.py          (PSQL env var overrides the psql path)
"""
import csv, io, json, os, re, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import (TOOLS, REVIEWER_TOOLS, PUBLIC_TOOLS, HIDDEN_COLUMNS, HIDDEN_FROM_REVIEWER, SEARCH_JOURNALS,
                       AGENT_REF_TOOLS, GUIDE_TOOLS, REF_COLUMNS, POLICY_COLUMNS)

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
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "author_services"), "-v", "ON_ERROR_STOP=1", "-q"]
T = {t["tool"]: t for t in TOOLS}
fails = passes = 0
OUTPUTS = []          # (tool, rows) for the hidden-column scans

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
check("14 MCP tools (10 author + 4 reviewer)", len(TOOLS) == 14 and len(REVIEWER_TOOLS & set(T)) == 4, [t["tool"] for t in TOOLS])
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
            ok = ok and re.match(r"INSERT INTO \w+ \([^)]*\) SELECT (\*|a\.author_id) FROM \w+", sql) is not None
        check(f"{t['tool']}.{part}: CAST-wrapped unique placeholders, no VALUES, no audit", ok, sql)
check("every tool except the two verify tools takes session_token first",
      all(t["args"][0][0] == "session_token" for t in TOOLS if t["tool"] not in PUBLIC_TOOLS))

# ---- identity ----
r = call("verify_author", orcid="0000-0002-1825-0097", verification_code="000000")
check("wrong code -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_author", orcid=" 0000-0002-1825-0097 ", verification_code="482913")
check("right code -> VERIFIED + token", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
maya = r[0]["session_token"]
lars = call("verify_author", orcid="0000-0004-7316-2588", verification_code="771204")[0]["session_token"]
ana = call("verify_author", orcid="0000-0003-1415-9269", verification_code="305118")[0]["session_token"]
elena = call("verify_author", orcid="0000-0001-5109-3700", verification_code="615204")[0]["session_token"]
check("all 4 seeded authors verify", all([maya, lars, ana, elena]))

# ---- SESSION_INVALID on every scoped author tool ----
for t in TOOLS:
    if t["tool"] in PUBLIC_TOOLS or t["tool"] in REVIEWER_TOOLS:
        continue
    args = {a: "x" for a, _ in t["args"]}
    args["session_token"] = "not-a-token"
    rows = call(t["tool"], **args)
    blob = json.dumps(rows)
    check(f"{t['tool']}: bad token -> SESSION_INVALID and no data", "SESSION_INVALID" in blob and "MS-2026" not in blob, rows)

# ---- scoped reads ----
r = call("get_my_manuscripts", session_token=maya)
check("my manuscripts = only Maya's 3", len(r) == 3 and r[0]["session_status"] == "OK", len(r))
r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0450")
check("another author's manuscript -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND" and not r[0]["title"], r)
r = call("get_manuscript", session_token=ana, manuscript_id="ms-2026-0419")
check("integrity hold masked (status, decision, declarations)", r[0]["status_detail"] == "With the editorial office."
      and not r[0]["decision_summary"] and not r[0]["declarations"], r)
r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0412")[0]
check("get_manuscript returns the declarations on file (no author contributions line for 0412)",
      "Zenodo" in r["declarations"] and "competing interests" in r["declarations"].lower()
      and "contribution" not in r["declarations"].lower() and not r["apc_due_usd"], r)
r = call("get_manuscript", session_token=lars, manuscript_id="MS-2026-0450")[0]
check("accepted manuscript shows the APC still due ($2,900, nothing waived)", r["apc_due_usd"] == "2900.00" and r["apc_waived_usd"] == "0", r)

# ---- review comments (scoped; anonymous reviewers) ----
r = call("get_review_comments", session_token=maya, manuscript_id="ms-2026-0301")
check("Maya's MS-2026-0301: decision letter + 6 reviewer comments, editor first",
      len(r) == 7 and r[0]["lookup_status"] == "OK" and r[0]["comment_ref"] == "E.1" and r[0]["source"] == "Editor"
      and [x["comment_ref"] for x in r][1:] == ["R1.1", "R1.2", "R1.3", "R2.1", "R2.2", "R2.3"], [x["comment_ref"] for x in r])
check("comments carry no names or emails", not re.search(r"Okafor|@|Dr\.|Prof\.", json.dumps(r)))
r = call("get_review_comments", session_token=lars, manuscript_id="MS-2026-0301")
check("another author's comments -> NOT_FOUND, no text", r[0]["lookup_status"] == "NOT_FOUND" and not r[0]["comment_text"], r)
r = call("get_review_comments", session_token=maya, manuscript_id="MS-2026-0412")
check("a manuscript without comments -> NO_COMMENTS", r[0]["lookup_status"] == "NO_COMMENTS" and len(r) == 1, r)
psql("INSERT INTO review_comments (manuscript_id, comment_ref, source, comment_text) VALUES ('MS-2026-0419','R1.1','REVIEWER_1','Test')")
r = call("get_review_comments", session_token=ana, manuscript_id="MS-2026-0419")
check("editorial hold: comments are not disclosed (NO_COMMENTS)", r[0]["lookup_status"] == "NO_COMMENTS" and not r[0]["comment_text"], r)
psql("DELETE FROM review_comments WHERE manuscript_id = 'MS-2026-0419'")

# ---- journal search (agent tool) - keywords only ----
t = SEARCH_JOURNALS
r = psql(sub(*t["read"], {"keywords": "coastal flooding, machine learning, storm surge, downscaling", "subject_area": "Earth"}))
codes = [x["journal_code"] for x in r]
check("search finds CHRR/EDSR, excludes NEUR (closed) and RETR", "CHRR" in codes and "EDSR" in codes and "NEUR" not in codes and "RETR" not in codes, codes)

# ---- APC arithmetic in SQL ----
r = call("check_apc_coverage", session_token=maya, journal_code="chrr")
check("CHRR not in Maya's agreement -> pays 2900", r[0]["coverage_pct"] == "0" and r[0]["author_pays_usd"] == "2900.00", r)
r = call("check_apc_coverage", session_token=maya, journal_code="HCRL")
check("HCRL covered 100% -> pays 0", r[0]["coverage_pct"] == "100" and r[0]["author_pays_usd"] == "0.00", r)
r = call("check_apc_coverage", session_token=lars, journal_code="CHRR")
check("Lars budget exhausted -> 0% + note", r[0]["coverage_pct"] == "0" and "used up" in r[0]["coverage_note"], r)

# ---- transfer guards (eligibility rules come before the statements gate) ----
def prop(tok, ms, jc): return call("propose_transfer", session_token=tok, manuscript_id=ms, journal_code=jc)[0]
check("over word limit", prop(maya, "MS-2026-0412", "EDSR")["reason"].startswith("OVER_WORD_LIMIT"))
check("not transfer-eligible", prop(maya, "MS-2026-0388", "GEOS")["reason"].startswith("NOT_ELIGIBLE"))
check("closed to transfers", prop(maya, "MS-2026-0412", "NEUR")["reason"].startswith("CLOSED_TO_TRANSFERS"))
check("same journal", prop(maya, "MS-2026-0412", "JACI")["reason"].startswith("SAME_JOURNAL"))
check("unknown/retired journal", prop(maya, "MS-2026-0412", "RETR")["reason"].startswith("JOURNAL_UNKNOWN"))
check("someone else's manuscript", prop(lars, "MS-2026-0412", "HCRL")["reason"].startswith("NOT_FOUND"))
check("integrity hold blocks", prop(ana, "MS-2026-0419", "UPIS")["reason"].startswith("ON_HOLD"))
check("Lars long article over every limit", prop(lars, "MS-2026-0433", "UPIS")["reason"].startswith("OVER_WORD_LIMIT"))
p = prop(maya, "MS-2026-0412", "HCRL")
check("eligible but no submission check yet -> CHECK_REQUIRED, nothing written",
      p["outcome"] == "NOT_PROPOSED" and p["reason"].startswith("CHECK_REQUIRED") and one("SELECT count(*) FROM pending_actions") == "0", p)

# ---- submission check: agent items validated + deterministic presence check (recorded in SQL) ----
def chk(tok, ms, jc, items="NONE", stmt="", notes="journal: X\nmissing_items: NONE"):
    return call("record_submission_check", session_token=tok, manuscript_id=ms, journal_code=jc, statements=stmt,
                missing_items=items, agent_notes=notes)[0]
r = psql("SELECT * FROM submission_assessment('EDSR', 'nothing useful here', 'missing_items: Data availability (incomplete), "
         "conflict of interest; Ethics; MADE_UP_ITEM')")[0]
check("norm + validation: aliases map to policy statements, unknown items are recorded as ignored",
      r["agent_items"] == "DATA_AVAILABILITY, ETHICS_APPROVAL, COMPETING_INTERESTS" and r["ignored_items"] == "MADE_UP_ITEM", r)
check("presence check: an empty text misses every MANDATORY statement of an OPEN_DATA journal",
      r["rule_items"] == "DATA_AVAILABILITY, FUNDING, COMPETING_INTERESTS, AUTHOR_CONTRIBUTIONS" and r["result"] == "INCOMPLETE"
      and r["recommended_missing"] == "ETHICS_APPROVAL", r)
check("submission_assessment: unknown / inactive journal -> no row",
      psql("SELECT count(*) AS n FROM submission_assessment('RETR', 'x', 'NONE')")[0]["n"] == "0")
c = chk(maya, "MS-2026-0412", "HCRL", items="AUTHOR_CONTRIBUTIONS")
check("Maya 0412 -> HCRL (STANDARD): COMPLETE; author contributions only RECOMMENDED",
      c["outcome"] == "RECORDED" and c["result"] == "COMPLETE" and not c["mandatory_missing"]
      and c["recommended_missing"] == "AUTHOR_CONTRIBUTIONS" and "propose_transfer" in c["next_step"], c)
check("readback carries the policy's standard wording for the recommended item",
      "AUTHOR_CONTRIBUTIONS (RECOMMENDED): We recommend an Author Contributions statement" in (c["policy_wording"] or ""), c)
c2 = chk(maya, "MS-2026-0412", "CHRR", items="NONE")
check("Maya 0412 -> CHRR (OPEN_DATA): the presence check alone makes it INCOMPLETE (author contributions mandatory), "
      "even when the agent flagged nothing", c2["result"] == "INCOMPLETE" and c2["mandatory_missing"] == "AUTHOR_CONTRIBUTIONS"
      and one(f"SELECT rule_items FROM submission_checks WHERE check_id = {lit(c2['check_id'])}") == "AUTHOR_CONTRIBUTIONS", c2)
e1 = chk(elena, "MS-2026-0466", "EDSR", items="DATA_AVAILABILITY, COMPETING_INTERESTS",
         notes="journal: EDSR\nmissing_items: DATA_AVAILABILITY, COMPETING_INTERESTS")
check("Elena 0466 -> EDSR: INCOMPLETE (data on request flagged by the agent + competing interests absent)",
      e1["result"] == "INCOMPLETE" and e1["mandatory_missing"] == "DATA_AVAILABILITY, COMPETING_INTERESTS"
      and "deposit the data and code" in e1["policy_wording"] and "The authors declare no competing interests." in e1["policy_wording"]
      and "STATEMENTS_EXCEPTION" in e1["next_step"], e1)
row = psql(f"SELECT agent_items, rule_items, statements, agent_notes FROM submission_checks WHERE check_id = {lit(e1['check_id'])}")[0]
check("DB: the check records the agent items, the presence-check items, the statements and the agent's answer",
      row["agent_items"] == "DATA_AVAILABILITY, COMPETING_INTERESTS" and row["rule_items"] == "COMPETING_INTERESTS"
      and "reasonable request" in row["statements"] and "missing_items" in row["agent_notes"], row)
p = prop(elena, "MS-2026-0466", "EDSR")
check("INCOMPLETE check blocks the transfer -> STATEMENTS_INCOMPLETE listing the items, nothing written",
      p["outcome"] == "NOT_PROPOSED" and p["reason"].startswith("STATEMENTS_INCOMPLETE")
      and "DATA_AVAILABILITY, COMPETING_INTERESTS" in p["reason"]
      and one("SELECT count(*) FROM pending_actions WHERE manuscript_id='MS-2026-0466'") == "0", p)
check("a check for another author's manuscript -> NOT_RECORDED NOT_FOUND",
      chk(lars, "MS-2026-0466", "EDSR")["reason_code"] == "NOT_FOUND")
check("a check on a manuscript under editorial hold -> NOT_RECORDED ON_HOLD",
      chk(ana, "MS-2026-0419", "UPIS")["reason_code"] == "ON_HOLD")
check("a check against a retired journal -> NOT_RECORDED JOURNAL_UNKNOWN",
      chk(maya, "MS-2026-0412", "RETR")["reason_code"] == "JOURNAL_UNKNOWN")
check("a check without a session -> SESSION_INVALID", chk("x", "MS-2026-0412", "HCRL")["reason_code"] == "SESSION_INVALID")
n_chk = one("SELECT count(*) FROM submission_checks")
check("blocked checks wrote nothing (3 recorded so far)", n_chk == "3", n_chk)

# ---- transfer happy path (Maya, HCRL: COMPLETE check) ----
p0 = prop(maya, "MS-2026-0412", "GEOS")
check("a COMPLETE check is per journal: GEOS still needs its own check", p0["reason"].startswith("CHECK_REQUIRED"), p0)
chk(maya, "MS-2026-0412", "GEOS")
p0 = prop(maya, "MS-2026-0412", "GEOS")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p0['action_id'])}")
e = call("confirm_transfer", session_token=maya, action_id=p0["action_id"])[0]
check("expired proposal cannot be confirmed", e["reason"].startswith("EXPIRED"), e)
psql("DELETE FROM pending_actions")
p1 = prop(maya, "MS-2026-0412", "HCRL")
p2 = prop(maya, "MS-2026-0412", "HCRL")
check("eligible + COMPLETE check -> PROPOSED with quote", p1["outcome"] == "PROPOSED" and p1["action_id"] and p1["author_pays_usd"] == "0.00", p1)
check("re-propose is idempotent (same action)", p2["action_id"] == p1["action_id"], (p1, p2))
act = p1["action_id"]
cnt = one("SELECT count(*) FROM pending_actions")
check("exactly one pending action written", cnt == "1", cnt)
psql("UPDATE submission_checks SET created_at = created_at - interval '25 hours' WHERE manuscript_id='MS-2026-0412' AND journal_code='HCRL'")
e = call("confirm_transfer", session_token=maya, action_id=act)[0]
check("confirm re-checks the statements gate: a check older than 24 hours -> CHECK_REQUIRED, not executed",
      e["outcome"] == "NOT_EXECUTED" and e["reason"].startswith("CHECK_REQUIRED"), e)
psql("UPDATE submission_checks SET created_at = created_at + interval '25 hours' WHERE manuscript_id='MS-2026-0412' AND journal_code='HCRL'")

def conf(tok, a): return call("confirm_transfer", session_token=tok, action_id=a)[0]
check("confirm bogus id", conf(maya, "ACT-00000000")["reason"].startswith("ACTION_NOT_FOUND"))
check("confirm by another author", conf(lars, act)["reason"].startswith("ACTION_NOT_FOUND"))
c1 = conf(maya, act.lower())
check("confirm -> EXECUTED, moved to HCRL", c1["outcome"] == "EXECUTED" and c1["new_status"] == "SUBMITTED", c1)
c2 = conf(maya, act)
n = one("SELECT count(*) FROM transfers")
check("re-confirm idempotent, one transfer row", c2["outcome"] == "EXECUTED" and n == "1", (c2, n))
r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0412")[0]
check("manuscript now at HCRL, from JACI", r["journal_code"] == "HCRL" and r["transferred_from"] == "JACI", r)
check("transferred manuscript cannot transfer again", prop(maya, "MS-2026-0412", "GEOS")["reason"].startswith("NOT_ELIGIBLE"))
p = prop(lars, "MS-2026-0450", "OCEN")
check("accepted manuscript not transferable", p["reason"].startswith("NOT_ELIGIBLE"), p)

# ---- Elena adds the missing statements -> a new COMPLETE check unblocks the transfer ----
e2 = chk(elena, "MS-2026-0466", "EDSR", items="NONE",
         stmt="Data availability: The data and code are openly available on Zenodo (https://doi.org/10.5281/zenodo.8812466).\n"
              "Competing interests: The authors declare no competing interests.")
check("the added statements count: new check COMPLETE", e2["result"] == "COMPLETE" and e2["check_id"] != e1["check_id"], e2)
p = prop(elena, "MS-2026-0466", "EDSR")
check("Elena 0466 -> EDSR now PROPOSED; she pays the full $1,850 (no agreement)",
      p["outcome"] == "PROPOSED" and p["author_pays_usd"] == "1850.00", p)
psql("DELETE FROM pending_actions WHERE manuscript_id='MS-2026-0466'")
psql("DELETE FROM submission_checks WHERE check_id = " + lit(e2["check_id"]))
check("with the COMPLETE check gone, the INCOMPLETE one governs again",
      prop(elena, "MS-2026-0466", "EDSR")["reason"].startswith("STATEMENTS_INCOMPLETE"))

# ---- human-owned requests (routing + parking derived in SQL) ----
def case(tok, ms, ty, stmt="Our lab has no grant funding left; can the fee be waived?",
         brief="Accepted article; institution agreement budget exhausted; author requests a waiver."):
    return call("open_review_case", session_token=tok, manuscript_id=ms, request_type=ty, author_statement=stmt, brief=brief)[0]
c = case(lars, "MS-2026-0450", "apc_waiver")
check("APC waiver -> CASE_OPENED, Open Access Office, requested = what he pays ($2,900)",
      c["outcome"] == "CASE_OPENED" and c["assigned_team"] == "Open Access Office" and c["requested_amount"] == "2900.00"
      and "reduced by the approved amount" in (c["if_approved"] or "") and c["reply_by"], c)
lars_case = c["case_id"]
check("DB: Lars's case parks APC_WAIVER:MS-2026-0450 and has a reply-due time",
      one(f"SELECT parked_action FROM review_cases WHERE case_id = {lit(lars_case)}") == "APC_WAIVER:MS-2026-0450"
      and one(f"SELECT sla_due_at IS NOT NULL FROM review_cases WHERE case_id = {lit(lars_case)}") == "t")
check("duplicate case suppressed", case(lars, "MS-2026-0450", "APC_WAIVER")["case_id"] == lars_case)
c = case(elena, "MS-2026-0458", "APC_WAIVER")
check("a second waiver on a manuscript that already has an OPEN parked waiver -> ALREADY_OPEN (the seeded case)",
      c["outcome"] == "ALREADY_OPEN" and c["case_id"] == "RC-S0A1F1"
      and one("SELECT count(*) FROM review_cases WHERE parked_action = 'APC_WAIVER:MS-2026-0458'") == "1", c)
c = case(maya, "MS-2026-0388", "APC_WAIVER")
check("waiver on a manuscript that is not accepted -> case opens without a parked action",
      c["outcome"] == "CASE_OPENED" and not c["requested_amount"]
      and one(f"SELECT parked_action IS NULL FROM review_cases WHERE case_id = {lit(c['case_id'])}") == "t", c)
check("bad request type", case(lars, "MS-2026-0450", "REFUND")["reason"].startswith("BAD_REQUEST_TYPE"))
check("case on someone else's manuscript", case(lars, "MS-2026-0412", "DECISION_APPEAL")["reason"].startswith("NOT_FOUND"))
check("case with no manuscript", case(maya, "", "OTHER")["outcome"] == "CASE_OPENED")
check("case without session", case("x", "", "OTHER")["reason"].startswith("SESSION_INVALID"))
c = case(maya, "MS-2026-0301", "STATEMENTS_EXCEPTION")
check("statements exception without an INCOMPLETE check -> NOT_OPENED NO_INCOMPLETE_CHECK",
      c["outcome"] == "NOT_OPENED" and c["reason"].startswith("NO_INCOMPLETE_CHECK"), c)
ex = case(elena, "MS-2026-0466", "STATEMENTS_EXCEPTION",
          stmt="Our soil-moisture data come from a commercial provider and cannot be deposited.",
          brief="journal: EDSR\nmissing_items: DATA_AVAILABILITY, COMPETING_INTERESTS\n(agent answer)")
check("statements exception after the INCOMPLETE check -> CASE_OPENED, Editorial Office (handling editor)",
      ex["outcome"] == "CASE_OPENED" and ex["assigned_team"] == "Editorial Office (handling editor)"
      and "transfer can go ahead" in (ex["if_approved"] or ""), ex)
check("DB: it parks ACCEPT_STATEMENTS:<the INCOMPLETE check> with the agent answer as brief",
      one(f"SELECT parked_action FROM review_cases WHERE case_id = {lit(ex['case_id'])}") == "ACCEPT_STATEMENTS:" + e1["check_id"]
      and "missing_items" in one(f"SELECT agent_brief FROM review_cases WHERE case_id = {lit(ex['case_id'])}"))
r = call("get_my_cases", session_token=lars)
check("Lars sees his 2 cases (seeded appeal + new waiver), OPEN, no internals",
      len(r) == 2 and {x["case_id"] for x in r} == {lars_case, "RC-S0B2E2"} and all(x["status"] == "OPEN" for x in r), r)
check("every case has a reply-due time from the routing table", one("SELECT count(*) FROM review_cases WHERE sla_due_at IS NULL") == "0")

# ---- reviewer identity (same token mechanism, role checked everywhere) ----
def vrev(staff, code): return call("verify_reviewer", staff_id=staff, code=code)[0]
r = vrev("PUB-7001", "000000")
check("reviewer wrong code -> NOT_VERIFIED, no token", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = vrev("PUB-7001", "482913")
check("an author code is not a staff code -> NOT_VERIFIED", r["status"] == "NOT_VERIFIED", r)
r = vrev("0000-0002-1825-0097", "482913")
check("an ORCID cannot verify as staff -> NOT_VERIFIED", r["status"] == "NOT_VERIFIED" and not r["session_token"], r)
r = vrev("pub 7001", "246810")
check("Grace (staff id typed loosely) -> VERIFIED, role REVIEWER, Open Access Office", r["status"] == "VERIFIED"
      and r["role"] == "REVIEWER" and r["team"] == "Open Access Office" and r["display_name"] == "Grace Whitfield" and r["session_token"], r)
grace = r["session_token"]
samuel = vrev("PUB-7002", "135790")["session_token"]
helen = vrev("7003", "864209")["session_token"]
tom = vrev("PUB-7004", "502468")["session_token"]
rafael = vrev("PUB-7005", "719350")["session_token"]
check("Samuel, Helen, Tom and Rafael verify", all([samuel, helen, tom, rafael]))
check("a reviewer token is not an author token (get_my_manuscripts -> SESSION_INVALID)",
      call("get_my_manuscripts", session_token=grace)[0]["session_status"] == "SESSION_INVALID")
check("a reviewer token cannot open an author case", case(grace, "", "OTHER")["reason"].startswith("SESSION_INVALID"))
check("an author token is not a reviewer token (queue -> NOT_REVIEWER)", call("get_review_queue", session_token=lars)[0]["status"] == "NOT_REVIEWER")
check("bogus token on get_review_case -> NOT_REVIEWER", call("get_review_case", session_token="x", case_id="RC-S0A1F1")[0]["status"] == "NOT_REVIEWER")

# ---- queues are scoped to the reviewer's team, ordered by reply-due time ----
def queue(tok): return call("get_review_queue", session_token=tok)
for who, tok, team, n_min in (("Grace", grace, "Open Access Office", 2), ("Helen", helen, "Editorial Office (handling editor)", 2),
                              ("Tom", tom, "Editorial Office (authorship)", 1), ("Rafael", rafael, "Research Integrity Team", 1)):
    qq = queue(tok)
    ids = [x["case_id"] for x in qq]
    db = [x["case_id"] for x in psql("SELECT c.case_id FROM review_cases c JOIN review_teams t USING (request_type) "
                                     f"WHERE t.team = {lit(team)} AND c.status = 'OPEN' ORDER BY c.sla_due_at, c.case_id")]
    check(f"{who}'s queue = exactly {team}'s OPEN cases, ordered by reply-due ({len(ids)})",
          ids == db and len(ids) >= n_min and qq[0]["status"] == "OK", (ids, db))
qg = {x["case_id"]: x for x in queue(grace)}
check("queue row: first name + surname initial only, manuscript, SLA status, requested amount",
      qg["RC-S0A1F1"]["author"] == "Dr. Elena V." and qg["RC-S0A1F1"]["requested_amount"] == "1850.00"
      and qg["RC-S0A1F1"]["manuscript_id"] == "MS-2026-0458"
      and qg["RC-S0A1F1"]["sla_status"] in ("ON_TRACK", "DUE_TODAY", "OVERDUE"), qg.get("RC-S0A1F1"))
check("both OA reviewers see the same team queue", [x["case_id"] for x in queue(samuel)] == [x["case_id"] for x in queue(grace)])
check("cross-team case is invisible: Grace opens an Editorial Office case -> NOT_FOUND",
      call("get_review_case", session_token=grace, case_id="RC-S0B2E2")[0]["status"] == "NOT_FOUND")
rc = call("get_review_case", session_token=grace, case_id="rc-s0a1f1")[0]
check("get_review_case: statement, brief, max approvable $1,850, Grace's $1,500 limit, APC facts, senior-reviewer option",
      rc["status"] == "OK" and rc["max_approvable"] == "1850.00" and rc["your_approval_limit"] == "1500.00"
      and "EDSR" in rc["facts"] or "Environmental Data Science Reports" in rc["facts"], rc)
check("... the facts say no agreement, the APC and what the author pays; options mention the senior reviewer",
      "agreement: none" in rc["facts"] and "$1,850.00" in rc["facts"] and "senior reviewer" in rc["options"], rc)
rh = call("get_review_case", session_token=helen, case_id=ex["case_id"])[0]
check("Helen sees the statements exception: the check facts and the agent brief (the author never does)",
      rh["status"] == "OK" and e1["check_id"] in rh["facts"] and "DATA_AVAILABILITY, COMPETING_INTERESTS" in rh["facts"]
      and "missing_items" in rh["agent_brief"] and "accepts the statements" in rh["options"] and not rh["max_approvable"], rh)

# ---- decide: every reason code, then the parked actions ----
def decide(tok, case_id, dec="APPROVE", amt="", note="Checked the agreement and the funding situation.", msg="Your request was reviewed."):
    return call("decide_review_case", session_token=tok, case_id=case_id, decision=dec, amount=amt, internal_note=note, customer_message=msg)[0]
n_dec = one("SELECT count(*) FROM review_decisions")
r = decide(elena, "RC-S0A1F1")
check("an author token cannot decide -> NOT_REVIEWER", r["outcome"] == "NOT_REVIEWER", r)
r = decide(grace, "RC-S0B2E2")
check("another team's case -> BLOCKED NOT_YOUR_TEAM", r["outcome"] == "BLOCKED" and r["reason_code"] == "NOT_YOUR_TEAM" and not r["case_id"], r)
r = decide(grace, "RC-ZZZZZZ")
check("unknown case -> NOT_FOUND", r["reason_code"] == "NOT_FOUND", r)
r = decide(grace, "RC-S0A1F1", note="ok")
check("note under 5 characters -> NOTE_REQUIRED", r["reason_code"] == "NOTE_REQUIRED", r)
r = decide(grace, "RC-S0A1F1", dec="MAYBE")
check("decision not APPROVE/REJECT -> INVALID_DECISION", r["reason_code"] == "INVALID_DECISION", r)
r = decide(grace, "RC-S0A1F1", amt="2000")
check("more than the $1,850 the author pays -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(grace, "RC-S0A1F1", amt="-5")
check("negative amount -> AMOUNT_INVALID", r["reason_code"] == "AMOUNT_INVALID", r)
r = decide(grace, "RC-S0A1F1")
check("full $1,850 above Grace's $1,500 limit -> OVER_AUTHORITY, case stays OPEN", r["reason_code"] == "OVER_AUTHORITY"
      and r["case_status"] == "OPEN" and "senior reviewer" in r["reason_text"], r)
check("DB: no decision row and no APC reduction after the blocked attempts",
      one("SELECT count(*) FROM review_decisions") == n_dec and one("SELECT count(*) FROM apc_reductions") == "0")
r = decide(grace, "RC-S0A1F1", amt="$1,000", note="No grant funds left; partial waiver within my limit.",
           msg="We have waived $1,000.00 of your article processing charge.")
check("approve $1,000 (within the limit) -> APPROVED, APC reduced", r["outcome"] == "APPROVED" and r["approved_amount"] == "1000.00"
      and "waived on MS-2026-0458" in (r["executed_action"] or "") and "$850.00" in (r["executed_action"] or ""), r)
check("DB: apc_reductions row (APC $1,850, waived $1,000, author pays $850) + APC_REDUCED + CASE_DECIDED audit by PUB-7001",
      one("SELECT count(*) FROM apc_reductions WHERE case_id='RC-S0A1F1' AND waived_usd=1000 AND author_pays_usd=850 AND apc_usd=1850") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='APC_REDUCED' AND author_id='AUT-1004'") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND ref='RC-S0A1F1' AND actor='PUB-7001' AND author_id='AUT-1004'") == "1")
r = call("get_manuscript", session_token=elena, manuscript_id="MS-2026-0458")[0]
check("Elena's manuscript now shows $1,000 waived and $850 due", r["apc_waived_usd"] == "1000.00" and r["apc_due_usd"] == "850.00", r)
r = decide(samuel, "RC-S0A1F1", dec="REJECT")
check("a second decision (even by a colleague) -> ALREADY_DECIDED",
      r["reason_code"] == "ALREADY_DECIDED" and one("SELECT count(*) FROM review_decisions WHERE case_id='RC-S0A1F1'") == "1", r)
r = decide(samuel, lars_case, amt="", note="Agreement budget exhausted; full waiver approved by senior reviewer.",
           msg="Your article processing charge has been waived in full.")
check("Samuel ($5,000 limit) approves Lars's full $2,900 -> APPROVED, author pays $0",
      r["outcome"] == "APPROVED" and r["approved_amount"] == "2900.00" and "$0.00" in r["executed_action"], r)
check("DB: Lars's APC due is now 0", one("SELECT manuscript_apc_due('MS-2026-0450')") == "0.00")
r = decide(helen, "RC-S0B2E2", dec="REJECT", note="Length limit is firm; the transfer offer stands.",
           msg="After review, the editor confirms the decision. The transfer offer remains open.")
check("reject Lars's appeal -> REJECTED, nothing executed", r["outcome"] == "REJECTED" and "nothing was executed" in r["executed_action"], r)
r = decide(tom, "RC-S0C3D3", note="All authors confirmed by email.", msg="The new co-author has been added.")
check("approve the authorship change (no parked action) -> APPROVED, the team completes it",
      r["outcome"] == "APPROVED" and "the team completes it" in r["executed_action"] and not r["approved_amount"], r)
r = decide(helen, ex["case_id"], note="Commercial data licence confirmed; code is open.",
           msg="The editorial office accepts your data statement as it is. You can go ahead with the transfer.")
check("Helen approves Elena's statements exception -> APPROVED, exception executed",
      r["outcome"] == "APPROVED" and "Statements exception" in r["executed_action"], r)
check("DB: statement_exceptions row for the INCOMPLETE check + STATEMENTS_EXCEPTION audit",
      one(f"SELECT count(*) FROM statement_exceptions WHERE check_id = {lit(e1['check_id'])} AND case_id = {lit(ex['case_id'])}") == "1"
      and one("SELECT count(*) FROM agent_audit WHERE action='STATEMENTS_EXCEPTION'") == "1")
p = prop(elena, "MS-2026-0466", "EDSR")
check("with the editor's exception, Elena's transfer can now be PROPOSED", p["outcome"] == "PROPOSED", p)
r = decide(rafael, "RC-S0D4C4", dec="REJECT", note="Needs a formal correction request, not a query.",
           msg="Please send a formal correction request; the integrity team will guide you.")
check("Rafael decides his team's case", r["outcome"] == "REJECTED", r)

# ---- the author sees the outcome (status + customer_message), never the internals ----
r = {x["case_id"]: x for x in call("get_my_cases", session_token=elena)}
check("Elena sees RC-S0A1F1 APPROVED, $1,000 and the team's message",
      r["RC-S0A1F1"]["status"] == "APPROVED" and r["RC-S0A1F1"]["approved_amount"] == "1000.00"
      and "$1,000.00" in r["RC-S0A1F1"]["customer_message"], r.get("RC-S0A1F1"))
r = {x["case_id"]: x for x in call("get_my_cases", session_token=lars)}
check("Lars sees his waiver APPROVED in full and the appeal REJECTED with the messages (no note or reviewer)",
      r[lars_case]["status"] == "APPROVED" and r["RC-S0B2E2"]["status"] == "REJECTED"
      and "Length limit is firm" not in json.dumps(r) and "Helen" not in json.dumps(r) and "Samuel" not in json.dumps(r), r)

# minimum necessary: hidden columns never reach authors; reviewers see no email/ORCID/full surname
auth_cols = {k for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows for k in row}
check("author tool outputs carry none of the hidden columns", not (auth_cols & HIDDEN_COLUMNS), auth_cols & HIDDEN_COLUMNS)
rev_rows = [row for t, rows in OUTPUTS if t in REVIEWER_TOOLS for row in rows]
rev_cols = {k for row in rev_rows for k in row}
rblob = json.dumps(rev_rows)
check("reviewer tool outputs: no email, ORCID, code or full surname", not (rev_cols & HIDDEN_FROM_REVIEWER)
      and not re.search(r"\.example|0000-000|Okafor|Eriksen|Ribeiro|Vasquez", rblob), (rev_cols & HIDDEN_FROM_REVIEWER))
ablob = json.dumps([row for t, rows in OUTPUTS if t not in REVIEWER_TOOLS for row in rows])
secrets = [x["v"] for x in psql("SELECT internal_note AS v FROM review_decisions UNION ALL SELECT display_name FROM reviewers")]
check("author outputs never contain internal notes or reviewer names", not any(s in ablob for s in secrets),
      [s for s in secrets if s in ablob][:3])
check("every MCP tool was exercised", {t for t, _ in OUTPUTS} == set(T), set(T) - {t for t, _ in OUTPUTS})

# ---- session expiry ----
psql(f"UPDATE author_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(maya)}")
check("expired token -> SESSION_INVALID", call("get_my_manuscripts", session_token=maya)[0]["session_status"] == "SESSION_INVALID")
psql(f"UPDATE author_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(grace)}")
check("expired reviewer token -> NOT_REVIEWER", call("get_review_queue", session_token=grace)[0]["status"] == "NOT_REVIEWER")

# ---- staff code brute-force lockout ----
n_sess = one("SELECT count(*) FROM author_sessions WHERE reviewer_id='PUB-7004'")
last = None
for _ in range(5):
    last = vrev("PUB-7004", "111111")
check("5th wrong staff code -> LOCKED", last["status"] == "LOCKED" and not last["session_token"], last)
r = vrev("PUB-7004", "502468")
check("LOCKED even with the right code, no session", r["status"] == "LOCKED" and not r["session_token"]
      and one("SELECT count(*) FROM author_sessions WHERE reviewer_id='PUB-7004'") == n_sess, r)
psql("UPDATE reviewer_verify_attempts SET at = at - interval '16 minutes' WHERE reviewer_id='PUB-7004'")
check("lock lifts after 15 minutes", vrev("PUB-7004", "502468")["status"] == "VERIFIED")

# ---- audit trail (traceability; written by triggers, no tool reads it) ----
na = lambda a: int(one(f"SELECT count(*) FROM agent_audit WHERE action={lit(a)}"))
check("audit logged author verify sessions", na("VERIFY") >= 4, na("VERIFY"))
check("audit logged transfer proposals + the transfer", na("TRANSFER_PROPOSED") >= 2 and na("TRANSFERRED") == 1,
      (na("TRANSFER_PROPOSED"), na("TRANSFERRED")))
check("audit logged every recorded submission check", na("SUBMISSION_CHECKED") == int(one("SELECT count(*) FROM submission_checks")) + 1,
      na("SUBMISSION_CHECKED"))   # +1: the COMPLETE check deleted above stays in the audit trail
check("audit logged every case (seeded + opened)", na("CASE_OPENED") == int(one("SELECT count(*) FROM review_cases")), na("CASE_OPENED"))
check("audit: CASE_DECIDED rows carry the reviewer as actor and the author as subject, one per decision",
      one("SELECT count(*) FROM agent_audit WHERE action='CASE_DECIDED' AND (actor IS NULL OR author_id IS NULL)") == "0"
      and na("CASE_DECIDED") == int(one("SELECT count(*) FROM review_decisions")))
check("audit: REVIEWER_VERIFY rows carry the reviewer id", int(one("SELECT count(*) FROM agent_audit WHERE action='REVIEWER_VERIFY' "
                                                                  "AND actor LIKE 'PUB-%'")) >= 5)
check("audit rows carry the author id (reviewer sign-ins carry the reviewer id instead)",
      one("SELECT count(*) FROM agent_audit WHERE author_id IS NULL AND action <> 'REVIEWER_VERIFY'") == "0")

# ---------------------------------------------------------------- A2A agent reference tools
# journal_match_agent keeps search_journals (checked above); review_summary_agent reads a section / term / meaning guide;
# submission_check_agent reads the journal policy rows.
def ref_call(t, term):
    return psql(sub(*t["read"], {t["read"][1][0][1]: term}))

def ref_blob(rows):
    return "\n".join("|".join(str(v) for v in r.values()) for r in rows).lower()

check("3 agent reference tools, one per A2A agent",
      [t["agent"] for t in AGENT_REF_TOOLS] == ["journal_match_agent", "review_summary_agent", "submission_check_agent"])
jm = AGENT_REF_TOOLS[0]
check("journal_match_agent keeps search_journals: SELECT * FROM search_journals(CAST(?kw AS text), CAST(?area AS text));",
      jm["read"] == SEARCH_JOURNALS["read"] and [a for a, _ in jm["args"]] == ["keywords", "subject_area"])
ID_VALUES = [r["v"] for r in psql(
    "SELECT author_id AS v FROM authors UNION SELECT full_name FROM authors UNION SELECT orcid FROM authors "
    "UNION SELECT email FROM authors UNION SELECT verification_code FROM authors UNION SELECT manuscript_id FROM manuscripts "
    "UNION SELECT reviewer_id FROM reviewers UNION SELECT display_name FROM reviewers UNION SELECT one_time_code FROM reviewers "
    "UNION SELECT case_id FROM review_cases UNION SELECT check_id FROM submission_checks UNION SELECT session_token FROM author_sessions "
    "UNION SELECT split_part(full_name, ' ', 3) FROM authors")]
ID_VALUES = [v for v in ID_VALUES if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 30, len(ID_VALUES))

rg = next(t for t in GUIDE_TOOLS if t["fn"] == "ref_review_guide")
tool, fn = rg["tool"], rg["fn"]
check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
      rg["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and rg["read"][1] == [("lookup", "term")]
      and [a for a, _ in rg["args"]] == ["term"])
full = ref_call(rg, "")
check(f"{tool}: whole guide returns rows ({len(full)}, about 15-25)", 12 <= len(full) <= 25, len(full))
check(f"{tool}: returns only the reference columns {REF_COLUMNS}", bool(full) and list(full[0]) == REF_COLUMNS, list(full[0]) if full else None)
check(f"{tool}: every section is present, in order",
      list(dict.fromkeys(r["section"] for r in full)) == rg["sections"], list(dict.fromkeys(r["section"] for r in full)))
check(f"{tool}: whitespace / separators only = whole guide", len(ref_call(rg, " , ")) == len(full))
hit = ref_call(rg, "confidence intervals")
check(f"{tool}: lookup 'confidence intervals' narrows the guide and finds STATISTICS",
      0 < len(hit) < len(full) and any(r["term"] == "STATISTICS" for r in hit)
      and all("confidence intervals" in f"{r['term']} {r['meaning']}".lower() for r in hit), [r["term"] for r in hit])
check(f"{tool}: lookup is case-insensitive", len(ref_call(rg, "CONFIDENCE INTERVALS")) == len(hit))
sec = ref_call(rg, "priority")
check(f"{tool}: section lookup 'priority' returns exactly MAJOR / MINOR / OPTIONAL",
      [r["term"] for r in sec] == ["MAJOR", "MINOR", "OPTIONAL"] and {r["section"] for r in sec} == {"PRIORITY"}, [r["term"] for r in sec])
check(f"{tool}: section lookup 'comment type' returns the 6 comment types",
      [r["term"] for r in ref_call(rg, "comment type")] == ["METHODS", "STATISTICS", "DATA", "CLARITY", "LITERATURE", "ETHICS"])
check(f"{tool}: several words in one call ('response letter, optional') -> both rows",
      {"POINT_BY_POINT", "OPTIONAL"} <= {r["term"] for r in ref_call(rg, "response letter, optional")})
check(f"{tool}: unknown term -> 0 rows, no error", ref_call(rg, "zzqx-unknown-term") == [])
check(f"{tool}: '%' and '_' are literal (the guide has no '%', so 0 rows; never a wildcard)",
      ref_call(rg, "%") == [] and ref_call(rg, "_%_") == [] and not any("%" in f"{r['term']} {r['meaning']}" for r in full))
check(f"{tool}: SQL-looking input is just a string -> 0 rows, table intact",
      ref_call(rg, "x'); DELETE FROM review_guide; --") == [] and int(one("SELECT count(*) FROM review_guide")) > 0)
blob = ref_blob(full)
leaked = [v for v in ID_VALUES if v.lower() in blob]
check(f"{tool}: no author / manuscript / reviewer / case / check / session value in the rows", not leaked, leaked[:5])
check(f"{tool}: no id, email or token pattern",
      not re.search(r"aut-\d|ms-20\d\d|rc-[0-9a-z]{6}|pub-\d|sck-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-", blob), blob[:200])
wd = ref_call(rg, "who decides")
check(f"{tool}: WHO_DECIDES comes from review_teams (DECISION_APPEAL -> Editorial Office (handling editor), 10 days)",
      len(wd) == 1 and "Editorial Office (handling editor)" in wd[0]["meaning"] and "10 business days" in wd[0]["meaning"]
      and wd[0]["term"] == one("SELECT label FROM review_teams WHERE request_type='DECISION_APPEAL'"), wd)
psql("UPDATE review_teams SET label = label || ' (test)' WHERE request_type = 'DECISION_APPEAL'")
check(f"{tool}: a review_teams edit shows up in WHO_DECIDES (no copy)", ref_call(rg, "who decides")[0]["term"].endswith("(test)"))
psql("UPDATE review_teams SET label = replace(label, ' (test)', '') WHERE request_type = 'DECISION_APPEAL'")
check(f"{tool}: the standard response-letter line lives in the table",
      [r["meaning"] for r in ref_call(rg, "point by point")] ==
      ["In your response letter, answer every item point by point in the same order, quote its reference, and say exactly "
       "where in the revised manuscript you made each change."])
check(f"{tool}: the comment types are exactly the taxonomy (methods, statistics, clarity, literature, data, ethics)",
      {r["term"] for r in full if r["section"] == "COMMENT_TYPE"} == {"METHODS", "STATISTICS", "CLARITY", "LITERATURE", "DATA", "ETHICS"})
check(f"{tool}: the guide never contains the comments themselves",
      not any(c["v"][:40].lower() in blob for c in psql("SELECT comment_text AS v FROM review_comments")))

pt = next(t for t in AGENT_REF_TOOLS if t["fn"] == "ref_journal_policy")
check("get_journal_policy: SQL is exactly SELECT * FROM ref_journal_policy(CAST(?lookup AS text)); one arg (journal)",
      pt["read"] == ("SELECT * FROM ref_journal_policy(CAST(?lookup AS text));", [("lookup", "journal")])
      and [a for a, _ in pt["args"]] == ["journal"])
allp = ref_call(pt, "")
check("get_journal_policy: empty -> every policy set (3 x 5 = 15 rows) with the journals each applies to",
      len(allp) == 15 and list(allp[0]) == POLICY_COLUMNS and "EDSR" in allp[5]["applies_to"] and "RETR" not in ref_blob(allp).upper(), len(allp))
hc = ref_call(pt, "hcrl")
check("get_journal_policy: a journal code -> that journal's 5 policy rows (STANDARD for HCRL)",
      len(hc) == 5 and {r["policy_set"] for r in hc} == {"STANDARD"} and {r["applies_to"] for r in hc} == {"HCRL"}, hc[:1])
ed = {r["statement"]: r for r in ref_call(pt, "EDSR")}
check("get_journal_policy: EDSR (OPEN_DATA) makes data availability + author contributions MANDATORY",
      ed["DATA_AVAILABILITY"]["requirement"] == "MANDATORY" and ed["AUTHOR_CONTRIBUTIONS"]["requirement"] == "MANDATORY"
      and "not accepted" in ed["DATA_AVAILABILITY"]["must_include"], ed.get("DATA_AVAILABILITY"))
check("get_journal_policy: a statement code -> that statement in every set", len(ref_call(pt, "competing_interests")) == 3)
check("get_journal_policy: a policy set name -> its 5 rows", len(ref_call(pt, "HUMAN_SUBJECTS")) == 5)
check("get_journal_policy: unknown / retired journal -> 0 rows, no error", ref_call(pt, "ZZZZ") == [] and ref_call(pt, "RETR") == [])
check("get_journal_policy: SQL-looking input is just a string -> 0 rows, table intact",
      ref_call(pt, "x'); DELETE FROM submission_policies; --") == [] and one("SELECT count(*) FROM submission_policies") == "15")
check("get_journal_policy: the deterministic keyword_pattern is never returned to the agent", "keyword_pattern" not in allp[0])
pblob = ref_blob(allp)
check("get_journal_policy: no author / manuscript / reviewer / case / session value in the rows",
      not [v for v in ID_VALUES if v.lower() in pblob], [v for v in ID_VALUES if v.lower() in pblob][:5])
check("get_journal_policy: every active journal follows exactly one policy set that has all 5 statements",
      one("SELECT count(*) FROM journals j WHERE j.is_active AND (SELECT count(*) FROM submission_policies p WHERE p.policy_set = j.policy_set) <> 5") == "0")
check("get_journal_policy: the standard wording sentences live in the table (table-only text for the agent)",
      "The authors declare no competing interests." in pblob.replace("the authors", "The authors")
      and "deposit the data and code behind your results in a public repository" in pblob)

# nothing from the design brief is lost: the facts each agent must work from are in its table
KEEP = {"get_review_guide": ["methods", "statistics", "clarity", "literature", "data", "ethics", "major", "minor", "optional",
                             "new analysis", "never add a request", "editor's items first", "point by point", "decision appeal"],
        "get_journal_policy": ["data_availability", "ethics_approval", "funding", "competing_interests", "author_contributions",
                               "mandatory", "recommended", "persistent identifier", "available on request", "credit terms",
                               "grant number", "approval number"]}
for t in (rg, pt):
    b = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k.lower() not in b]
    check(f"{t['tool']}: every fact the agent needs is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args, "
           "p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang JOIN pg_namespace ns ON ns.oid = p.pronamespace "
           "WHERE ns.nspname = 'public' AND (p.proname LIKE 'ref\\_%' OR p.proname = 'search_journals')")
names = {f["proname"] for f in fns}
check("agent read functions: ref_match + ref_review_guide + ref_journal_policy + search_journals",
      names == {"ref_match", "ref_review_guide", "ref_journal_policy", "search_journals"}, names)
for f in fns:
    check(f"{f['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          f["lanname"] == "sql" and f["provolatile"] in ("s", "i") and f["prosecdef"] == "f"
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", f["prosrc"], re.I),
          {k: f[k] for k in ("lanname", "provolatile", "prosecdef")})
    if f["proname"] in ("ref_review_guide", "ref_journal_policy"):
        check(f"{f['proname']}: one optional, non-identity argument", f["args"] in ("p_term text", "p_journal text"), f["args"])

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
check("reset_data.sql reloads the agent reference tables, reviewers, comments and the seeded open cases",
      all(int(one(f"SELECT count(*) FROM {t['table']}")) > 0 for t in AGENT_REF_TOOLS)
      and one("SELECT count(*) FROM reviewers") == "5" and one("SELECT count(*) FROM review_comments") == "7"
      and one("SELECT count(*) FROM review_cases WHERE status='OPEN'") == "4"
      and one("SELECT count(*) FROM submission_checks") == "0" and one("SELECT count(*) FROM apc_reductions") == "0"
      and one("SELECT count(*) FROM agent_audit WHERE action <> 'CASE_OPENED'") == "0")

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  ({passes}/{passes + fails} checks, DB reset)")
sys.exit(1 if fails else 0)
