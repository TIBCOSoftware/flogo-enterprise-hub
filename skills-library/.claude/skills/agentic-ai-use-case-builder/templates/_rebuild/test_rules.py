#!/usr/bin/env python3
# =============================================================================
# WORKED-EXAMPLE TEMPLATE - Airline Passenger Services (Meridian) governed use case.
#
# This is a proven, runnable reference test from the Airline Passenger Services
# worked example. To build your own governed use case, copy the whole _rebuild/
# folder into <YourUseCase>/_rebuild/ and ADAPT it (keep the logic - the value is a
# working reference - just change):
#   - app names / prefix       (PassengerServices... -> <YourUseCase>...)
#   - the tool_spec.py entries  (tools, args, SQL: scoped reads + guarded writes)
#   - ports / endpoint paths    (9850 / 9852 / 9853, /passenger-services-gov-mcp, ...)
#   - the test assertions       below (PNRs/PINs, expected outcomes) for your own data
#   - the reference-tool block  at the end (ID_SQL / LOOKUPS / KEEP / ID_PATTERN placeholders, codes explained)
#
# References (relative to this file):
#   ..\..\references\fda-build-recipes.md  - the fda-only build driver pattern
#   ..\..\references\governed-patterns.md  - scoped reads / guarded writes / safe prompts
#   ..\..\references\testing-ladder.md     - the SQL -> MCP -> chat test ladder
#
# No secrets here: credentials are read at RUN time from config.md / env (see fda_common.py).
# =============================================================================
"""Run the EXACT tool SQL from tool_spec.py against the airline_governed DB and assert the business rules,
then the A2A agents' reference tools (AGENT_REF_TOOLS: generic block with placeholders at the end).
No Flogo needed. Re-loads reset_data.sql first and again at the end.

  PG_DB=<database> PG_PWD=<password> python _rebuild/test_rules.py   (PSQL env var overrides the psql path;
  PG_PWD may also come from env PG_PASSWORD or config.md PG_PASSWORD)
"""
import os, re, subprocess, sys, csv, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tool_spec import TOOLS, AGENT_REF_TOOLS, REF_COLUMNS, ref_tools_filled
if not ref_tools_filled():
    sys.exit("fill in tool_spec.AGENT_REF_TOOLS and the reference-tool block (LOOKUPS / KEEP / ID query) first")

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
PG_DB = os.environ.get("PG_DB") or sys.exit("set PG_DB to the use case's database name (worked example: PG_DB=airline_governed)")
ENV = dict(os.environ, PGPASSWORD=os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or _config_md_value("PG_PASSWORD")
           or sys.exit("PostgreSQL password not set: export PG_PWD (or PG_PASSWORD), or fill PG_PASSWORD in config.md"))
BASE = [PSQL, "-h", os.environ.get("PG_HOST", "localhost"), "-U", os.environ.get("PG_USER", "postgres"),
        "-d", PG_DB, "-v", "ON_ERROR_STOP=1", "-q"]
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

# ---- identity ----
r = call("verify_traveller", pnr="ABCDE1", pin="0000")
check("wrong PIN -> NOT_VERIFIED, no token", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_traveller", pnr=" abcde1 ", pin="4821")
check("right PNR+PIN -> VERIFIED + token", r[0]["status"] == "VERIFIED" and r[0]["session_token"], r)
carlos = r[0]["session_token"]
maria = call("verify_traveller", pnr="PQRST4", pin="7310")[0]["session_token"]
roberto = call("verify_traveller", pnr="KLMNO3", pin="9205")[0]["session_token"]
daniel = call("verify_traveller", pnr="NPQRS5", pin="6677")[0]["session_token"]
sofia = call("verify_traveller", pnr="MNOPQ0", pin="5533")[0]["session_token"]
ana = call("verify_traveller", pnr="FGHIJ2", pin="1188")[0]["session_token"]

# ---- scoped reads ----
r = call("get_my_itinerary", session_token=carlos)
check("itinerary = Carlos's 2 legs", len([x for x in r if x["flight_number"]]) == 2 and r[0]["session_status"] == "OK", r)
r = call("get_my_itinerary", session_token="not-a-token")
check("bad token -> SESSION_INVALID, no legs", r[0]["session_status"] == "SESSION_INVALID" and not r[0]["flight_number"], r)
r = call("get_flight_status", session_token=carlos, flight_number="FL801")
check("Carlos sees FL801 DELAYED 90", r[0]["status"] == "DELAYED" and r[0]["delay_minutes"] == "90", r)
r = call("get_flight_status", session_token=carlos, flight_number="FL302")
check("flight not on itinerary -> NOT_ON_ITINERARY", r[0]["lookup_status"] == "NOT_ON_ITINERARY", r)
r = call("get_my_loyalty", session_token=carlos)
check("loyalty = Gold", r[0]["tier"] == "Gold" and r[0]["session_status"] == "OK", r)

# ---- connection risk (ARITHMETIC in SQL) ----
risk = {x["pnr"]: x for tok in [carlos, maria, roberto, daniel, sofia, ana]
        for x in call("check_connection_risk", session_token=tok)}
check("Carlos MISSED (FL801->FL445)", risk["ABCDE1"]["risk"] == "MISSED", risk["ABCDE1"])
check("Maria AT_RISK (~50 min)", risk["PQRST4"]["risk"] == "AT_RISK" and risk["PQRST4"]["connection_minutes"] == "50", risk["PQRST4"])
check("Roberto direct -> NO_CONNECTION", risk["KLMNO3"]["risk"] == "NO_CONNECTION", risk["KLMNO3"])
check("Daniel cancelled inbound -> MISSED", risk["NPQRS5"]["risk"] == "MISSED", risk["NPQRS5"])
check("Sofia MISSED", risk["MNOPQ0"]["risk"] == "MISSED", risk["MNOPQ0"])
check("Ana SAFE (90 min)", risk["FGHIJ2"]["risk"] == "SAFE", risk["FGHIJ2"])

# ---- rebook guards ----
def prop(tok, cur, new): return call("propose_rebook", session_token=tok, current_flight=cur, new_flight=new)[0]
check("wrong route", prop(carlos, "FL445", "FL614")["reason"].startswith("WRONG_ROUTE"))
check("no seats on target", prop(carlos, "FL445", "FL445")["reason"].startswith("SAME_FLIGHT"))
check("unknown target flight", prop(carlos, "FL445", "FL999")["reason"].startswith("FLIGHT_UNKNOWN"))
check("no such leg on booking", prop(carlos, "FL999", "FL447")["reason"].startswith("NOT_FOUND"))
check("another traveller's leg", prop(maria, "FL445", "FL447")["reason"].startswith("NOT_FOUND"))
check("departs too early (before connection)", prop(sofia, "FL717", "FL715")["reason"].startswith("DEPARTS_TOO_EARLY"))
check("target with zero seats -> NO_SEATS", prop(maria, "FL612", "FL612")["reason"].startswith("SAME_FLIGHT"))

# ---- two-step rebook happy path (Carlos FL445 -> FL447) ----
p1 = prop(carlos, "FL445", "FL447")
p2 = prop(carlos, "FL445", "FL447")
check("eligible -> PROPOSED with action + seat", p1["outcome"] == "PROPOSED" and p1["action_id"] and p1["new_seat"], p1)
check("re-propose idempotent (same action)", p1["action_id"] == p2["action_id"], (p1, p2))
act = p1["action_id"]
check("exactly one pending action", psql("SELECT count(*) n FROM pending_actions")[0]["n"] == "1")

def conf(tok, a): return call("confirm_rebook", session_token=tok, action_id=a)[0]
check("confirm bogus id", conf(carlos, "ACT-00000000")["reason"].startswith("ACTION_NOT_FOUND"))
check("confirm by another traveller", conf(maria, act)["reason"].startswith("ACTION_NOT_FOUND"))
c1 = conf(carlos, act.lower())
check("confirm -> EXECUTED on FL447", c1["outcome"] == "EXECUTED" and c1["to_flight"] == "FL447", c1)
c2 = conf(carlos, act)
n = psql("SELECT count(*) n FROM rebookings")[0]["n"]
check("re-confirm idempotent, one rebooking row", c2["outcome"] == "EXECUTED" and n == "1", (c2, n))
r = [x for x in call("get_my_itinerary", session_token=carlos) if x["destination"] == "MIA"][0]
check("itinerary now on FL447, REBOOKED", r["flight_number"] == "FL447" and r["segment_status"] == "REBOOKED", r)
check("seats decremented on FL447", psql("SELECT seats_available s FROM flights WHERE flight_number='FL447'")[0]["s"] == "8")
check("rebooked leg cannot rebook again", prop(carlos, "FL447", "FL449")["reason"].startswith("ALREADY_REBOOKED"))

# ---- email confirmation (guarded) ----
e = call("email_my_confirmation", session_token=carlos, action_id=act)[0]
check("email authorised for executed rebooking", e["send_status"] == "SEND_OK" and "@" in (e["to_email"] or ""), e)
e = call("email_my_confirmation", session_token=carlos, action_id="ACT-00000000")[0]
check("email refused for unknown action", e["send_status"] == "NOT_SENT", e)
e = call("email_my_confirmation", session_token=maria, action_id=act)[0]
check("email refused for another traveller's action", e["send_status"] == "NOT_SENT", e)

# ---- expiry ----
p = prop(maria, "FL612", "FL614")
check("Maria eligible -> PROPOSED", p["outcome"] == "PROPOSED", p)
psql(f"UPDATE pending_actions SET expires_at = now() - interval '1 minute' WHERE action_id = {lit(p['action_id'])}")
check("expired proposal cannot confirm", conf(maria, p["action_id"])["reason"].startswith("EXPIRED"))

# ---- human-owned requests ----
def case(tok, ty, stmt="Please help with this.", brief="Traveller request; routed for a human to decide."):
    return call("open_service_case", session_token=tok, request_type=ty, traveler_statement=stmt, brief=brief)[0]
k = case(carlos, "compensation_claim", "My FL801 was delayed 90 minutes and I want compensation.")
check("compensation -> CASE_OPENED, Customer Care", k["outcome"] == "CASE_OPENED" and "Customer Care" in k["assigned_team"], k)
check("duplicate case suppressed", case(carlos, "COMPENSATION_CLAIM")["case_id"] == k["case_id"])
check("baggage -> Baggage Services", case(carlos, "BAGGAGE_CLAIM")["assigned_team"] == "Baggage Services")
check("bad request type", case(carlos, "REFUND")["reason"].startswith("BAD_REQUEST_TYPE"))
check("case without session", case("x", "OTHER")["reason"].startswith("SESSION_INVALID"))
r = call("get_my_cases", session_token=carlos)
check("Carlos sees his cases", len([x for x in r if x["case_id"]]) >= 2 and r[0]["session_status"] == "OK", r)

# ---- session expiry ----
psql(f"UPDATE traveler_sessions SET expires_at = now() - interval '1 minute' WHERE session_token = {lit(carlos)}")
check("expired token -> SESSION_INVALID", call("get_my_itinerary", session_token=carlos)[0]["session_status"] == "SESSION_INVALID")

# ---- PIN brute-force throttle ----
for _ in range(5):
    call("verify_traveller", pnr="KLMNO3", pin="0000")              # 5 wrong PINs
r = call("verify_traveller", pnr="KLMNO3", pin="9205")              # correct PIN, but now locked
check("5 wrong PINs -> LOCKED even with the right PIN", r[0]["status"] == "LOCKED" and not r[0]["session_token"], r)
check("wrong PIN on an unknown PNR is not tracked", psql("SELECT count(*) n FROM verify_attempts WHERE pnr='ZZZZZ9'")[0]["n"] == "0")

# ---- audit trail (OWASP traceability) ----
na = lambda a: int(psql(f"SELECT count(*) n FROM agent_audit WHERE action={lit(a)}")[0]["n"])
check("audit logged verify sessions", na("VERIFY_SESSION_ISSUED") >= 6, na("VERIFY_SESSION_ISSUED"))
check("audit logged a rebook proposal + execution", na("REBOOK_PROPOSED") >= 1 and na("REBOOK_EXECUTED") >= 1)
check("audit logged a service case", na("SERVICE_CASE_OPENED") >= 1)

# ---------------------------------------------------------------- A2A agent reference tools (ref_* functions)
# GENERIC BLOCK (from the Hospital / Semiconductor samples; testing-ladder.md step 1). Each A2A agent's one tool runs
#   SELECT * FROM ref_<topic>(CAST(?lookup AS text))   - reference data only, no identity.
# Sample-specific: ID_SQL, LOOKUPS, KEEP, ID_PATTERN and the "every code is explained" checks. Run this block AFTER
# the scenario tests above, so every code the runtime wrote (reason codes, statuses, categories) is in the database.
def n(sql): return int(list(psql(sql)[0].values())[0])

def ref_call(t, term):
    return psql(sub(*t["read"], {"term": term}))

def ref_blob(rows):
    return "\n".join(f"{r['section']}|{r['term']}|{r['meaning']}" for r in rows).lower()

# every identity value in the database (names, people / account ids, emails, one-time codes, case ids, tokens)
ID_SQL = ("SELECT <name_col> AS v FROM <people_table> UNION SELECT <id_col> FROM <people_table> "
          "UNION SELECT email FROM <people_table> UNION SELECT case_id FROM <case_table> "
          "UNION SELECT session_token::text FROM <session_table>")
ID_VALUES = [v for v in (r["v"] for r in psql(ID_SQL)) if v and len(v) >= 4]
check("identity value list for the leak scan is non-trivial", len(ID_VALUES) > 10, len(ID_VALUES))
ID_PATTERN = r"<id-prefix>-\d|case-\d|@|[0-9a-f]{8}-[0-9a-f]{4}-"     # your id formats, emails, UUID tokens
ROW_RANGE = (10, 40)   # rows of the whole guide (term=""): agents read it whole almost every time - aim for ~20-35
LOOKUPS = {   # tool -> (single lookup word, expected term, section lookup word, rows in that section)
    "get_<topic_a>_guide": ("<word>", "<term it finds>", "<section words>", 3),
}
for t in AGENT_REF_TOOLS:
    tool, fn = t["tool"], t["fn"]
    check(f"{tool}: SQL is exactly SELECT * FROM {fn}(CAST(?lookup AS text)); with one model-supplied arg (term)",
          t["read"][0] == f"SELECT * FROM {fn}(CAST(?lookup AS text));" and t["read"][1] == [("lookup", "term")]
          and [a for a, _ in t["args"]] == ["term"])
    full = ref_call(t, "")
    check(f"{tool}: whole guide returns rows ({len(full)}, aim for about 20-35)", ROW_RANGE[0] <= len(full) <= ROW_RANGE[1],
          len(full))
    check(f"{tool}: returns only the reference columns {REF_COLUMNS}", bool(full) and list(full[0]) == REF_COLUMNS,
          list(full[0]) if full else None)
    check(f"{tool}: every section is present", {r["section"] for r in full} == set(t["sections"]),
          sorted({r["section"] for r in full} ^ set(t["sections"])))
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
    pct = ref_call(t, "%")      # '%' is matched literally (only rows that contain '%'), never as a wildcard
    check(f"{tool}: '%' and '_' are literal (no wildcard expansion)",
          len(pct) < len(full) and all("%" in f"{r['term']} {r['meaning']}" for r in pct) and ref_call(t, "_%_") == [],
          [r["term"] for r in pct])
    check(f"{tool}: SQL-looking input is just a string -> 0 rows",
          ref_call(t, "x'); DELETE FROM " + t["table"] + "; --") == [] and n(f"SELECT count(*) FROM {t['table']}") > 0)
    blob = ref_blob(full)
    leaked = [v for v in ID_VALUES if v.lower() in blob]
    check(f"{tool}: no identity value from the database in the reference rows", not leaked, leaked[:5])
    check(f"{tool}: no id, case id, email or token pattern", not re.search(ID_PATTERN, blob), blob[:200])
    check(f"{tool}: several words in one call find each of them",
          {expect} <= {r["term"] for r in ref_call(t, f"{word}, zzqx-unknown-term")})

# every code the runtime writes that reaches an agent is explained in its guide (one row per code), e.g.:
# codes = {r["c"] for r in psql("SELECT DISTINCT reason_code c FROM <table> WHERE reason_code IS NOT NULL")}
# check("ref_<topic_a>: every reason code the runtime wrote is explained", bool(codes) and codes <= {terms of that section})
# rows UNIONed from an existing table match it (single source of truth), e.g. the case_routing team + SLA text.

# nothing from the old prompt / static reference text was lost
KEEP = {"get_<topic_a>_guide": ["<fact 1, lower case>", "<fact 2>"]}
for t in AGENT_REF_TOOLS:
    blob = ref_blob(ref_call(t, ""))
    miss = [k for k in KEEP[t["tool"]] if k not in blob]
    check(f"{t['tool']}: every fact from the old reference text is in the table", not miss, miss)

fns = psql("SELECT p.proname, l.lanname, p.provolatile, p.prosecdef, "
           "pg_get_function_identity_arguments(p.oid) AS args, p.prosrc FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang "
           "JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname LIKE 'ref\\_%'")
names = {x["proname"] for x in fns}
check("ref_* functions exist: ref_match + one per agent", names == {"ref_match"} | {t["fn"] for t in AGENT_REF_TOOLS}, names)
for x in fns:
    check(f"{x['proname']}: LANGUAGE sql, STABLE/IMMUTABLE, not SECURITY DEFINER, SELECT-only body",
          x["lanname"] == "sql" and x["provolatile"] in ("s", "i") and x["prosecdef"] in ("f", "false")
          and not re.search(r"\b(insert|update|delete|truncate|drop|alter|create|grant|copy|execute|perform)\b", x["prosrc"], re.I),
          {k: x[k] for k in ("lanname", "provolatile", "prosecdef")})
    if x["proname"] != "ref_match":
        check(f"{x['proname']}: one optional, non-identity argument (p_term text)", x["args"] == "p_term text", x["args"])

subprocess.run(BASE + ["-f", os.path.join(DIR, "reset_data.sql")], check=True, env=ENV, capture_output=True)
check("reset_data.sql reloads the agent reference tables",
      all(n(f"SELECT count(*) FROM {t['table']}") > 0 for t in AGENT_REF_TOOLS))
print(f"\n{'ALL RULES PASS' if not fails else str(fails) + ' FAILURE(S)'}  (DB reset)")
sys.exit(1 if fails else 0)
