#!/usr/bin/env python3
"""Run the EXACT tool SQL from tool_spec.py against the author_services DB and assert the business rules.
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_PWD=<password> python _rebuild/test_rules.py          (PSQL env var overrides the psql path)
"""
import os, re, subprocess, sys, csv, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, SEARCH_JOURNALS

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
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", os.environ.get("PG_DB", "author_services"), "-v", "ON_ERROR_STOP=1", "-q"]
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

# identity
r = call("verify_author", orcid="0000-0002-1825-0097", verification_code="000000")
check("wrong code -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_author", orcid=" 0000-0002-1825-0097 ", verification_code="482913")
check("right code -> VERIFIED + token", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
maya = r[0]["session_token"]
lars = call("verify_author", orcid="0000-0004-7316-2588", verification_code="771204")[0]["session_token"]
ana = call("verify_author", orcid="0000-0003-1415-9269", verification_code="305118")[0]["session_token"]

# scoped reads
r = call("get_my_manuscripts", session_token=maya)
check("my manuscripts = only Maya's 3", len(r) == 3 and r[0]["session_status"] == "OK", len(r))
r = call("get_my_manuscripts", session_token="not-a-token")
check("bad token -> SESSION_INVALID, no rows of data", r[0]["session_status"] == "SESSION_INVALID" and not r[0]["manuscript_id"], r)
r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0450")
check("another author's manuscript -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND" and not r[0]["title"], r)
r = call("get_manuscript", session_token=ana, manuscript_id="ms-2026-0419")
check("integrity hold masked", r[0]["status_detail"] == "With the editorial office." and not r[0]["decision_summary"], r)

# journal search (agent tool) - keywords only
t = SEARCH_JOURNALS
r = psql(sub(*t["read"], {"keywords": "coastal flooding, machine learning, storm surge, downscaling", "subject_area": "Earth"}))
codes = [x["journal_code"] for x in r]
check("search finds CHRR/EDSR, excludes NEUR (closed) and RETR", "CHRR" in codes and "EDSR" in codes and "NEUR" not in codes and "RETR" not in codes, codes)

# APC arithmetic in SQL
r = call("check_apc_coverage", session_token=maya, journal_code="chrr")
check("CHRR not in Maya's agreement -> pays 2900", r[0]["coverage_pct"] == "0" and r[0]["author_pays_usd"] == "2900.00", r)
r = call("check_apc_coverage", session_token=maya, journal_code="HCRL")
check("HCRL covered 100% -> pays 0", r[0]["coverage_pct"] == "100" and r[0]["author_pays_usd"] == "0.00", r)
r = call("check_apc_coverage", session_token=lars, journal_code="CHRR")
check("Lars budget exhausted -> 0% + note", r[0]["coverage_pct"] == "0" and "used up" in r[0]["coverage_note"], r)

# transfer guards
def prop(tok, ms, jc): return call("propose_transfer", session_token=tok, manuscript_id=ms, journal_code=jc)[0]
check("over word limit", prop(maya, "MS-2026-0412", "EDSR")["reason"].startswith("OVER_WORD_LIMIT"))
check("not transfer-eligible", prop(maya, "MS-2026-0388", "GEOS")["reason"].startswith("NOT_ELIGIBLE"))
check("closed to transfers", prop(maya, "MS-2026-0412", "NEUR")["reason"].startswith("CLOSED_TO_TRANSFERS"))
check("same journal", prop(maya, "MS-2026-0412", "JACI")["reason"].startswith("SAME_JOURNAL"))
check("unknown/retired journal", prop(maya, "MS-2026-0412", "RETR")["reason"].startswith("JOURNAL_UNKNOWN"))
check("someone else's manuscript", prop(lars, "MS-2026-0412", "HCRL")["reason"].startswith("NOT_FOUND"))
check("integrity hold blocks", prop(ana, "MS-2026-0419", "UPIS")["reason"].startswith("ON_HOLD"))
check("Lars long article over every limit", prop(lars, "MS-2026-0433", "UPIS")["reason"].startswith("OVER_WORD_LIMIT"))
p0 = prop(maya, "MS-2026-0412", "GEOS")
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p0['action_id'])}")
e = call("confirm_transfer", session_token=maya, action_id=p0["action_id"])[0]
check("expired proposal cannot be confirmed", e["reason"].startswith("EXPIRED"), e)
psql("DELETE FROM pending_actions")
p1 = prop(maya, "MS-2026-0412", "HCRL")
p2 = prop(maya, "MS-2026-0412", "HCRL")
check("eligible -> PROPOSED with quote", p1["outcome"] == "PROPOSED" and p1["action_id"] and p1["author_pays_usd"] == "0.00", p1)
check("re-propose is idempotent (same action)", p2["action_id"] == p1["action_id"], (p1, p2))
act = p1["action_id"]
cnt = psql("SELECT count(*) AS n FROM pending_actions")[0]["n"]
check("exactly one pending action written", cnt == "1", cnt)

def conf(tok, a): return call("confirm_transfer", session_token=tok, action_id=a)[0]
check("confirm bogus id", conf(maya, "ACT-00000000")["reason"].startswith("ACTION_NOT_FOUND"))
check("confirm by another author", conf(lars, act)["reason"].startswith("ACTION_NOT_FOUND"))
c1 = conf(maya, act.lower())
check("confirm -> EXECUTED, moved to HCRL", c1["outcome"] == "EXECUTED" and c1["new_status"] == "SUBMITTED", c1)
c2 = conf(maya, act)
n = psql("SELECT count(*) AS n FROM transfers")[0]["n"]
check("re-confirm idempotent, one transfer row", c2["outcome"] == "EXECUTED" and n == "1", (c2, n))
r = call("get_manuscript", session_token=maya, manuscript_id="MS-2026-0412")[0]
check("manuscript now at HCRL, from JACI", r["journal_code"] == "HCRL" and r["transferred_from"] == "JACI", r)
check("transferred manuscript cannot transfer again", prop(maya, "MS-2026-0412", "GEOS")["reason"].startswith("NOT_ELIGIBLE"))

# expired proposal
p = prop(lars, "MS-2026-0450", "OCEN")
check("accepted manuscript not transferable", p["reason"].startswith("NOT_ELIGIBLE"), p)

# human-owned requests
def case(tok, ms, ty): return call("open_review_case", session_token=tok, manuscript_id=ms, request_type=ty,
                                   author_statement="Our lab has no grant funding left; can the fee be waived?",
                                   brief="Accepted article; institution agreement budget exhausted; author requests a waiver.")[0]
c = case(lars, "MS-2026-0450", "apc_waiver")
check("APC waiver -> CASE_OPENED, OA office", c["outcome"] == "CASE_OPENED" and c["assigned_team"] == "Open Access Office", c)
check("duplicate case suppressed", case(lars, "MS-2026-0450", "APC_WAIVER")["case_id"] == c["case_id"])
check("bad request type", case(lars, "MS-2026-0450", "REFUND")["reason"].startswith("BAD_REQUEST_TYPE"))
check("case on someone else's manuscript", case(lars, "MS-2026-0412", "DECISION_APPEAL")["reason"].startswith("NOT_FOUND"))
check("case with no manuscript", case(maya, "", "OTHER")["outcome"] == "CASE_OPENED")
check("case without session", case("x", "", "OTHER")["reason"].startswith("SESSION_INVALID"))
r = call("get_my_cases", session_token=lars)
check("Lars sees 1 case", len(r) == 1 and r[0]["case_id"] == c["case_id"], r)

# expiry
psql(f"UPDATE author_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(maya)}")
r = call("get_my_manuscripts", session_token=maya)
check("expired token -> SESSION_INVALID", r[0]["session_status"] == "SESSION_INVALID", r)

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  (DB reset)")
sys.exit(1 if fails else 0)
