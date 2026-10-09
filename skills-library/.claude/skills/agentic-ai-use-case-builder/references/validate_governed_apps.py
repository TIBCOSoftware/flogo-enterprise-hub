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
    (r"(?<!never )(?<!not )(?<!n't )(pretend|claim) (to be|you are) (a )?(human|person)", "impersonates a person"),
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

    sec = warns if local else errs
    for p in d.get("properties", []):
        v = str(p.get("value", ""))
        if re.search(r"sk-(?!REPLACE)[A-Za-z0-9_-]{20,}", v):
            sec.append(f"G9 property {p['name']}: real-looking API key - scrub to sk-REPLACE-WITH-YOUR-OPENAI-KEY")
        if p["name"].lower().endswith("password") and v not in PASSWORD_PLACEHOLDERS and not v.startswith("SECRET:"):
            sec.append(f"G9 property {p['name']}: non-placeholder password - scrub to SET_YOUR_DB_PASSWORD")
    return errs, warns

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
