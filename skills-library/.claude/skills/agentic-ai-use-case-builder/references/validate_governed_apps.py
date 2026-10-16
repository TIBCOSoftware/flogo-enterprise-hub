#!/usr/bin/env python3
"""Pre-ship validator for GOVERNED Agentic AI .flogo apps (agentic-ai-use-case-builder skill).

Runs the base validator from the co-located ./validate_flogo_apps.py (PostgreSQL mapping
integrity, password fields, A2A toolParams) and then the governance checks this skill adds:

  G1 SCOPED READS    every PostgreSQL #query reads FROM a rule function  (FROM fn(...)), never a bare table.
                     A bare `SELECT ... FROM <table>` hands the LLM rows it was supposed to filter itself.
  G2 GUARDED WRITES  every PostgreSQL #insert is `INSERT ... SELECT ...` (0 rows when a rule blocks it),
                     never `INSERT ... VALUES` (the LLM's arguments would be written unchecked).
                     #update/#delete are flagged: express them as an INSERT the DB applies (trigger) instead.
  G3 PROMPTS         no prompt tells the model to filter/compute/decide what SQL owns, or to hide being an AI.
  G4 TEMPERATURE     0 (= parameter omitted, provider default). A non-zero value is sent to the provider and is
                     rejected by gpt-5.x / Claude 4.7+; determinism belongs in SQL, not in sampling.
  G5 CONN REFS       every conn://<id> anywhere in the app resolves to a connection in the same app.
  G6 NO New_value    the literal fda placeholder text never survives into an app.
  G7 WEBSOCKET       tr_wsserver handler headers schema is INLINE {"type":"json","value":...}; a schema:// ref
                     yields no headers at runtime. Its fe_metadata is the designer's [{"parameterName":...}] list
                     (a JSON-schema copy makes the designer's Sync rewrite value to zero headers). Every AI Agent
                     activity behind a WebSocket maps conversationId (else every client shares one conversation -
                     and one verified identity), and any $flow.headers["X"] it reads is declared in the schema.
  G8 MCP HINTS       MCP tool hints (readOnly/destructive/idempotent/openWorld) are real JSON booleans, and
                     readOnlyToolHint=true never sits on a tool whose flow writes.
  G9 SECRETS         no real-looking API key (sk-...) and no non-placeholder DB password in app properties.
                     Pass --local to downgrade G9 to a warning for a scratch build that needs real values.
  G10 A2A SERVERS    every AI Agent trigger (#agent / #tr_agent) with agentType "A2A Server" has >= 1 Tool handler,
                     and the agent ports (resolved from their app properties) are unique within the app. With ZERO
                     Tool handlers the runtime silently starts it as a Local Agent and never opens its port, so the
                     orchestrator can't reach it. Every Tool handler's flow must READ POSTGRESQL: it contains a
                     PostgreSQL query activity whose SQL starts with SELECT and calls a ref_<topic>() function (or
                     another non-identity read function), with no session/token placeholder and no write activity.
                     A static #noop -> #actreturn reference text is an ERROR - give each reasoning agent one
                     identity-free PostgreSQL reference tool, SELECT * FROM ref_<topic>(CAST(?lookup AS text))
                     (governed-patterns.md "Agent reference tools (PostgreSQL)"; template: the Hospital sample's
                     _rebuild/build_agents.py).
  G11 REVIEWER LOOP  human-owned cases are decided by a staff reviewer in the same chatbot (governed-patterns.md
                     section 9). If the MCP app has a decide_review_case tool, its flow must write
                     INSERT ... SELECT ... FROM decide_case_row(...) (guarded, never VALUES) and then read the
                     outcome back with a PostgreSQL query; verify_reviewer, get_review_queue and get_review_case must
                     exist next to it, and the two reviewer reads must pass the session token. decide_review_case's
                     destructive/idempotent hints should be false. WARNINGS (not errors, so legacy samples still
                     validate): an app that routes human-owned cases (open_*case tool, or an INSERT into a *cases
                     table) but has no reviewer tools; a partial reviewer tool set without decide_review_case; no
                     get_my_cases outcome view for the customer; an orchestrator prompt that mentions
                     decide_review_case but never asks for an explicit "confirm".

Usage:  python validate_governed_apps.py [--local] A.flogo [B.flogo ...]      exit 1 on any error
"""
import json, os, re, subprocess, sys

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "validate_flogo_apps.py")
PASSWORD_PLACEHOLDERS = {"", "SET_YOUR_DB_PASSWORD"}
BAD_PROMPT = [
    (r"filter (the )?(results|rows|records) (yourself|by)", "tells the model to filter rows - scope them in SQL"),
    (r"only (show|return|mention) (the )?(rows|records|results) (for|belonging|where)", "model-side row filtering"),
    (r"(never|do not|don't) (say|reveal|admit|mention) (that )?(you are|you're) (an? )?(ai|bot|assistant)",
     "hides that it is an AI"),
    (r"(?<!never )(?<!not )(?<!n't )\b(pretend|claim) (to be|you are) (a )?(human|person)", "impersonates a person"),
    (r"calculate (the )?(fee|price|amount|refund|apc|total)", "model does arithmetic SQL should own"),
]

def pg_alias_refs(d):
    """alias (#query/#insert/...) -> kind, from imports of the wi-postgres activities."""
    out = {}
    for imp in d.get("imports", []):
        m = re.match(r"(?:(\w+)\s+)?\S*postgres\S*/activity/(\w+)", imp)
        if m: out["#" + (m.group(1) or m.group(2))] = m.group(2)
    return out

def tasks(d):
    for r in d.get("resources", []):
        for t in r.get("data", {}).get("tasks", []):
            yield r["id"].split(":", 1)[-1], t

def walk(o):
    if isinstance(o, dict):
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
    elif isinstance(o, str): yield o

def check(path, local):
    errs, warns = [], []
    d = json.load(open(path, encoding="utf-8"))
    kinds = pg_alias_refs(d)
    writing_flows = set()

    for flow, t in tasks(d):
        a = t.get("activity", {}); kind = kinds.get(a.get("ref"))
        where = f"{flow}.{t['id']}"
        if kind:
            q = re.sub(r"\s+", " ", (a.get("input") or {}).get("Query", "")).strip()
            if kind == "query":
                bare = [m.group(1) for m in re.finditer(r"\bFROM\s+([A-Za-z_][\w.]*)\b(?!\s*\()", q, re.I)]
                if bare: errs.append(f"G1 {where}: reads bare table(s) {bare} - use FROM <rule_fn>(CAST(?p AS text))")
            elif kind == "insert":
                writing_flows.add(flow)
                if re.search(r"\bVALUES\b", q, re.I) or not re.search(r"\bINSERT\b.+\bSELECT\b", q, re.I):
                    errs.append(f"G2 {where}: INSERT without a guarding SELECT - use INSERT ... SELECT * FROM <rule_fn>(...)")
            else:
                writing_flows.add(flow)
                warns.append(f"G2 {where}: #{kind} - prefer an INSERT the DB applies via trigger, so the rule is re-checked")
        s = a.get("settings", {})
        if "systemPrompt" in s: check_agent(where, s, errs, warns, user_facing=True)

    for tr in d.get("triggers", []):
        s = tr.get("settings", {})
        if "systemPrompt" in s: check_agent(tr["id"], s, errs, warns)
        for h in tr.get("handlers", []):
            hs, flow = h.get("settings", {}), h.get("action", {}).get("settings", {}).get("flowURI", "").split(":")[-1]
            if "readOnlyToolHint" in hs:
                name = hs.get("handlerName", flow)
                for k in ("readOnlyToolHint", "destructiveToolHint", "idempotentToolHint", "openWorldToolHint"):
                    if k in hs and not isinstance(hs[k], bool):
                        errs.append(f"G8 {name}: {k}={hs[k]!r} is not a boolean - set it with fda sa ... --jsonValue true|false")
                if hs.get("readOnlyToolHint") is True and flow in writing_flows:
                    errs.append(f"G8 {name}: readOnlyToolHint=true but its flow writes")
            if tr.get("ref", "").endswith("tr_wsserver") or "wsserver" in tr.get("ref", ""):
                hdr = h.get("schemas", {}).get("output", {}).get("headers")
                hdr_keys = set()
                if isinstance(hdr, str) and hdr.startswith("schema://"):
                    errs.append(f"G7 {tr['id']}: headers schema is {hdr} - must be inline {{type:json,value:...}} or no header reaches $flow.headers")
                elif isinstance(hdr, dict):
                    try: hdr_keys = set(json.loads(hdr.get("value") or "{}").get("properties", {}))
                    except ValueError: errs.append(f"G7 {tr['id']}: headers value is not JSON")
                    try: fe = json.loads(hdr.get("fe_metadata") or "[]")
                    except ValueError: fe = None
                    if not isinstance(fe, list):
                        errs.append(f"G7 {tr['id']}: headers fe_metadata must be the designer's parameter list "
                                    f"[{{\"parameterName\":...}}] - a JSON-schema copy of value makes Sync rewrite value to zero headers")
                ws_flows = {flow}
                for f2, t in tasks(d):
                    if f2 in ws_flows and "systemPrompt" in t.get("activity", {}).get("settings", {}):
                        cid = (t["activity"].get("input") or {}).get("conversationId")
                        if not cid:
                            errs.append(f"G7 {f2}.{t['id']}: conversationId not mapped - all WebSocket clients share one conversation")
                        for key in re.findall(r"\$flow\.headers\[\"([^\"]+)\"\]", str(cid or "")):
                            if isinstance(hdr, dict) and key not in hdr_keys:
                                errs.append(f"G7 {f2}.{t['id']}: conversationId reads header {key!r} but the handler headers "
                                            f"schema does not declare it - the designer flags it and the runtime never passes it")

    conn_ids = {c.get("id") for c in (d.get("connections", {}).values() if isinstance(d.get("connections"), dict)
                                      else d.get("connections", []))}
    for sval in walk({k: v for k, v in d.items() if k != "connections"}):
        for cid in re.findall(r"conn://([\w-]+)", sval):
            if cid not in conn_ids: errs.append(f"G5 conn://{cid} does not resolve to a connection in this app")
        if "New_value" in sval: errs.append(f"G6 literal 'New_value' found: {sval[:80]!r}")

    # G10: an A2A Server agent trigger needs >= 1 Tool handler (else it runs as a Local Agent, no port), unique ports.
    agent_aliases = {"#" + (m.group(1) or "agent") for imp in d.get("imports", [])
                     for m in [re.match(r"(?:(\w+)\s+)?\S*/trigger/agent$", imp)] if m} | {"#agent", "#tr_agent"}
    props = {p.get("name"): p.get("value") for p in d.get("properties", [])}
    seen_ports = {}
    for tr in d.get("triggers", []):
        s = tr.get("settings", {})
        if tr.get("ref") not in agent_aliases or str(s.get("agentType", "")).strip() != "A2A Server": continue
        tools = [h for h in tr.get("handlers", []) if (h.get("settings") or {}).get("handlerType", "Tool") == "Tool"]
        if not tools:
            errs.append(f"G10 {tr['id']}: A2A Server agent has no Tool handler - it starts as a Local Agent and never "
                        f"opens its port; add one identity-free PostgreSQL reference tool "
                        f"(SELECT * FROM ref_<topic>(CAST(?lookup AS text)))")
        for h in tools:
            check_ref_tool(tr["id"], h, d, kinds, errs)
        raw = str(s.get("agentPort", "")).strip()
        m = re.fullmatch(r'=\$property\["([^"]+)"\]', raw)
        port = str(props.get(m.group(1), "")) if m else raw
        if port and port in seen_ports:
            errs.append(f"G10 {tr['id']}: agent port {port} is also used by {seen_ports[port]} - one port per A2A agent")
        elif port: seen_ports[port] = tr["id"]

    check_reviewer_loop(d, kinds, errs, warns)

    sec = warns if local else errs
    for p in d.get("properties", []):
        v = str(p.get("value", ""))
        if re.search(r"sk-(?!REPLACE)[A-Za-z0-9_-]{20,}", v):
            sec.append(f"G9 property {p['name']}: real-looking API key - scrub to sk-REPLACE-WITH-YOUR-OPENAI-KEY")
        if p["name"].lower().endswith("password") and v not in PASSWORD_PLACEHOLDERS and not v.startswith("SECRET:"):
            sec.append(f"G9 property {p['name']}: non-placeholder password - scrub to SET_YOUR_DB_PASSWORD")
    return errs, warns

# Names that mark a read as identity/customer-scoped - an A2A agent never gets those (minimised input, no identity).
IDENTITY_READ = re.compile(r"session|token|verify|(?:^|_)my_|customer|member|patient|account|subscriber|traveler|traveller|"
                           r"passenger|buyer|author|contact|person|people|employee|staff|user", re.I)

def check_ref_tool(agent, h, d, kinds, errs):
    """G10: an A2A agent's Tool handler flow reads reference data from PostgreSQL (never static text, never identity)."""
    tool = (h.get("settings") or {}).get("agentToolName") or "?"
    flow = h.get("action", {}).get("settings", {}).get("flowURI", "").split(":")[-1]
    where = f"{agent}/{tool} ({flow})"
    acts = [(t["id"], kinds.get(t.get("activity", {}).get("ref")), t.get("activity", {})) for f, t in tasks(d) if f == flow]
    for tid, kind, _ in acts:
        if kind and kind != "query":
            errs.append(f"G10 {where}: task {tid} is a PostgreSQL #{kind} - an A2A agent's reference tool is read-only")
    queries = [(tid, a) for tid, kind, a in acts if kind == "query"]
    if not queries:
        errs.append(f"G10 {where}: the tool flow has no PostgreSQL query activity - a static #noop -> #actreturn reference "
                    f"text is not allowed. Read a reference table instead: #act_postgresql_query "
                    f"SELECT * FROM ref_<topic>(CAST(?lookup AS text)) -> #actreturn (governed-patterns.md "
                    f"'Agent reference tools (PostgreSQL)')")
        return
    for tid, a in queries:
        inp = a.get("input") or {}
        q = re.sub(r"\s+", " ", inp.get("Query", "")).strip()
        if not re.match(r"SELECT\b", q, re.I):
            errs.append(f"G10 {where}.{tid}: reference query must start with SELECT, got {q[:60]!r}")
            continue
        srcs = re.findall(r"\bFROM\s+([A-Za-z_][\w.]*)", q, re.I)
        bad = [s for s in srcs if not s.split(".")[-1].lower().startswith("ref_") and IDENTITY_READ.search(s)]
        if not srcs or bad:
            errs.append(f"G10 {where}.{tid}: reads {bad or 'nothing'} - an agent's tool reads a ref_<topic>() function "
                        f"or another non-identity table, never identity/customer-scoped data")
        params = (inp.get("input") or {}).get("mapping", {}).get("parameters", {}) if isinstance(inp.get("input"), dict) else {}
        idp = [p for p in set(re.findall(r"\?(\w+)", q)) | set(params) if re.search(r"tok|session", p, re.I)]
        idp += [v for v in params.values() if re.search(r"tok|session", str(v), re.I)]
        if idp:
            errs.append(f"G10 {where}.{tid}: identity parameter(s) {idp} - an A2A agent never gets a session token")

REVIEWER_READS = ("verify_reviewer", "get_review_queue", "get_review_case")
REVIEWER_TOOLS = REVIEWER_READS + ("decide_review_case",)

def check_reviewer_loop(d, kinds, errs, warns):
    """G11: the human-in-the-loop reviewer loop on the MCP app (and the confirm step in an orchestrator prompt)."""
    # orchestrator side: a prompt that drives decide_review_case must restate + ask for an explicit confirm
    prompts = [str((t.get("activity", {}).get("settings") or {}).get("systemPrompt", "")) for _, t in tasks(d)]
    for pr in prompts:
        if "decide_review_case" in pr and not re.search(r"\bconfirm", pr, re.I):
            warns.append("G11 orchestrator prompt calls decide_review_case but never asks the reviewer for an explicit "
                         "\"confirm\" - restate the decision, wait for confirm, then always submit it (SQL decides OVER_AUTHORITY)")
    mcp_aliases = {"#" + (m.group(1) or "mcpserver") for imp in d.get("imports", [])
                   for m in [re.match(r"(?:(\w+)\s+)?\S*/trigger/mcpserver$", imp)] if m}
    tools = {}                                                  # MCP tool name -> (flow id, handler settings)
    for tr in d.get("triggers", []):
        if tr.get("ref") not in mcp_aliases and not str(tr.get("ref", "")).endswith("mcpserver"): continue
        for h in tr.get("handlers", []):
            hs = h.get("settings") or {}
            name = hs.get("handlerName") or hs.get("name") or hs.get("toolName")
            if name: tools[name] = (h.get("action", {}).get("settings", {}).get("flowURI", "").split(":")[-1], hs)
    if not tools: return                                        # not an MCP server app
    flow_pg = {}                                                # flow id -> [(task id, kind, normalised Query, params)]
    for flow, t in tasks(d):
        a = t.get("activity", {}); kind = kinds.get(a.get("ref"))
        if not kind: continue
        inp = a.get("input") or {}
        params = (inp.get("input") or {}).get("mapping", {}).get("parameters", {}) if isinstance(inp.get("input"), dict) else {}
        flow_pg.setdefault(flow, []).append((t["id"], kind, re.sub(r"\s+", " ", inp.get("Query", "")).strip(), params))
    present = [n for n in REVIEWER_TOOLS if n in tools]
    if "decide_review_case" not in tools:
        if present:
            warns.append(f"G11 partial reviewer loop {present} without decide_review_case - add the guarded decision tool "
                         f"(INSERT INTO review_decisions ... SELECT * FROM decide_case_row(...)) or remove the reviewer tools")
            return
        routes = [n for n in tools if re.fullmatch(r"open_\w*case", n)]
        routes += [f"{f}.{tid}" for f, acts in flow_pg.items() for tid, kind, q, _ in acts
                   if kind == "insert" and re.search(r"\bINSERT\s+INTO\s+\w*cases\b", q, re.I)]
        if routes:
            warns.append(f"G11 human-owned cases are routed ({sorted(set(routes))[:3]}) but there is no reviewer loop - "
                         f"add verify_reviewer, get_review_queue, get_review_case and decide_review_case so a staff "
                         f"reviewer decides them in the chatbot (governed-patterns.md section 9)")
        return
    flow, hs = tools["decide_review_case"]
    acts = flow_pg.get(flow, [])
    inserts = [(tid, q) for tid, kind, q, _ in acts if kind == "insert"]
    others = [(tid, kind) for tid, kind, _, _ in acts if kind not in ("insert", "query")]
    if not inserts:
        errs.append(f"G11 decide_review_case ({flow}): no PostgreSQL insert - the decision must be a guarded "
                    f"INSERT INTO review_decisions ... SELECT * FROM decide_case_row(...)")
    for tid, q in inserts:
        if re.search(r"\bVALUES\b", q, re.I) or not re.search(r"\bINSERT\s+INTO\s+[\w.]+.*\bSELECT\b.+\bFROM\s+decide_case_row\s*\(", q, re.I):
            errs.append(f"G11 decide_review_case ({flow}.{tid}): the write must be INSERT ... SELECT ... FROM decide_case_row(...) "
                        f"(guarded: 0 rows when blocked), got {q[:90]!r}")
    for tid, kind in others:
        errs.append(f"G11 decide_review_case ({flow}.{tid}): PostgreSQL #{kind} - record the decision as an insert-only "
                    f"event row; the trigger applies it")
    if not any(kind == "query" for _, kind, _, _ in acts):
        errs.append(f"G11 decide_review_case ({flow}): no readback query - read the outcome and reason with "
                    f"SELECT * FROM decide_case_result(...)")
    for k in ("destructiveToolHint", "idempotentToolHint"):
        if hs.get(k) is True:
            warns.append(f"G11 decide_review_case: {k}=true - a decision is neither destructive nor idempotent (set false)")
    missing = [n for n in REVIEWER_READS if n not in tools]
    if missing:
        errs.append(f"G11 decide_review_case without {missing} - the reviewer must verify (role from SQL), see the team "
                    f"queue and open the case in the same chatbot")
    for n in ("get_review_queue", "get_review_case"):
        if n not in tools: continue
        qs = [(q, params) for _, kind, q, params in flow_pg.get(tools[n][0], []) if kind == "query"]
        if not any(re.search(r"\?\w*(tok|session)", q, re.I) or any(re.search(r"tok|session", str(k) + str(v), re.I)
                                                                     for k, v in params.items()) for q, params in qs):
            errs.append(f"G11 {n} ({tools[n][0]}): no PostgreSQL query that passes the reviewer's session token - "
                        f"the team scope must come from SQL (FROM review_queue(CAST(?tok AS text)))")
    if "get_my_cases" not in tools:
        warns.append("G11 no get_my_cases tool - the customer cannot see the reviewer's outcome (status + customer_message)")

def check_agent(where, s, errs, warns, user_facing=False):
    prompt = str(s.get("systemPrompt", ""))
    for pat, why in BAD_PROMPT:
        if re.search(pat, prompt, re.I): errs.append(f"G3 {where}: prompt {why} (/{pat}/)")
    if user_facing and not re.search(r"\bAI\b", prompt): warns.append(f"G3 {where}: prompt never says it is an AI - add 'say so if asked'")
    temp = str(s.get("temperature", "0")).strip()
    if temp not in ("0", "0.0", ""):
        errs.append(f"G4 {where}: temperature={temp} is sent to the provider (gpt-5.x / Claude 4.7+ reject it); use 0 = omitted")

def main():
    args = sys.argv[1:]
    local = "--local" in args
    files = [a for a in args if a != "--local"]
    if not files: sys.exit(__doc__)
    rc = 0
    if os.path.exists(BASE):
        rc = subprocess.run([sys.executable, BASE, *files]).returncode
    else:
        print(f"WARN base validator not found at {BASE} - governance checks only")
    total = 0
    for f in files:
        errs, warns = check(f, local)
        for w in warns: print(f"WARN  {os.path.basename(f)}: {w}")
        for e in errs: print(f"ERROR {os.path.basename(f)}: {e}")
        total += len(errs)
    print(f"{'OK - governance checks pass' if not total else str(total) + ' governance error(s)'} across {len(files)} file(s)")
    sys.exit(1 if (total or rc) else 0)

if __name__ == "__main__":
    main()
