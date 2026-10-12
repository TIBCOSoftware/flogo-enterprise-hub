#!/usr/bin/env python3
"""Call the running AuthorServicesMCPServer's tools directly - no LLM - to prove the rules hold at the MCP edge.
Start AuthorServicesMCPServer first, load reset_data.sql, then:   python _rebuild/mcp_smoke.py
Leaves one executed transfer and one review case behind - re-load reset_data.sql afterwards."""
import json, os, sys, urllib.request

URL = os.environ.get("MCP_URL", "http://localhost:9842/author-services-mcp")
session, seq, fails = None, 0, 0

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

def call(tool, **args):
    res = rpc("tools/call", {"name": tool, "arguments": args})
    text = res["content"][0]["text"]
    body = json.loads(text)                                   # the runtime returns response.data as the text content
    return (json.loads(body["data"]) if "data" in body else body)["records"]

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    fails += 0 if cond else 1

rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
rpc("notifications/initialized", notify=True)
tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
check("8 tools listed", len(tools) == 8, sorted(tools))
check("read-only hint on reads", tools["get_my_manuscripts"].get("annotations", {}).get("readOnlyHint") is True, tools["get_my_manuscripts"])
check("arguments schema published", "session_token" in json.dumps(tools["propose_transfer"].get("inputSchema")), tools["propose_transfer"])

r = call("verify_author", orcid="0000-0002-1825-0097", verification_code="111111")
check("wrong code -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_author", orcid="0000-0002-1825-0097", verification_code="482913")
check("right code -> VERIFIED", r[0]["status"] == "VERIFIED", r)
tok = r[0]["session_token"]
r = call("get_my_manuscripts", session_token=tok)
check("scoped list = 3 manuscripts", len(r) == 3, r)
r = call("get_manuscript", session_token=tok, manuscript_id="MS-2026-0450")
check("other author's manuscript -> NOT_FOUND", r[0]["lookup_status"] == "NOT_FOUND", r)
r = call("check_apc_coverage", session_token=tok, journal_code="CHRR")
check("APC quote computed in SQL", r[0]["author_pays_usd"] in ("2900", "2900.00", 2900) or float(r[0]["author_pays_usd"]) == 2900, r)
r = call("propose_transfer", session_token=tok, manuscript_id="MS-2026-0412", journal_code="EDSR")
check("guard: over word limit", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("OVER_WORD_LIMIT"), r)
p = call("propose_transfer", session_token=tok, manuscript_id="MS-2026-0412", journal_code="HCRL")[0]
check("eligible -> PROPOSED", p["outcome"] == "PROPOSED" and p["action_id"], p)
c = call("confirm_transfer", session_token=tok, action_id=p["action_id"])[0]
check("confirm -> EXECUTED", c["outcome"] == "EXECUTED", c)
k = call("open_review_case", session_token=tok, manuscript_id="MS-2026-0301", request_type="DECISION_APPEAL",
         author_statement="I think reviewer 2 misread our method.", brief="Revision requested; author disputes one review.")[0]
check("review case opened", k["outcome"] == "CASE_OPENED" and k["case_id"], k)
r = call("get_my_cases", session_token=tok)
check("case visible to author", any(x["case_id"] == k["case_id"] for x in r), r)
r = call("get_my_manuscripts", session_token="forged")
check("forged token -> SESSION_INVALID", r[0]["session_status"] == "SESSION_INVALID", r)

print(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  - now re-load reset_data.sql")
sys.exit(1 if fails else 0)
