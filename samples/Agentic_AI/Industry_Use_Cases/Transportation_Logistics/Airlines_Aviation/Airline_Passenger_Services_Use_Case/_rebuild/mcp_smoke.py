#!/usr/bin/env python3
"""Call the running PassengerServicesMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, load reset_data.sql, then:   python _rebuild/mcp_smoke.py
Leaves one executed rebooking + one service case behind - re-load reset_data.sql afterwards."""
import json, os, sys, urllib.request

URL = os.environ.get("MCP_URL", "http://localhost:9852/passenger-services-gov-mcp")
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
    body = json.loads(text)
    return (json.loads(body["data"]) if "data" in body else body)["records"]

def check(label, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    fails += 0 if cond else 1

rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
rpc("notifications/initialized", notify=True)
tools = {t["name"]: t for t in rpc("tools/list")["tools"]}
check("10 tools listed", len(tools) == 10, sorted(tools))
check("read-only hint on reads", tools["get_my_itinerary"].get("annotations", {}).get("readOnlyHint") is True, tools["get_my_itinerary"])
check("arguments schema published", "session_token" in json.dumps(tools["propose_rebook"].get("inputSchema")), tools["propose_rebook"])

r = call("verify_traveller", pnr="ABCDE1", pin="0000")
check("wrong PIN -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_traveller", pnr="ABCDE1", pin="4821")
check("right PNR+PIN -> VERIFIED", r[0]["status"] == "VERIFIED", r)
tok = r[0]["session_token"]
r = call("get_my_itinerary", session_token=tok)
check("scoped itinerary = 2 legs", len([x for x in r if x["flight_number"]]) == 2, r)
r = call("check_connection_risk", session_token=tok)
check("connection risk computed -> MISSED", any(x["risk"] == "MISSED" for x in r), r)
earliest = [x for x in r if x["risk"] == "MISSED"][0]["earliest_rebook_departure"]
r = call("propose_rebook", session_token=tok, current_flight="FL445", new_flight="FL445")
check("guard: same flight", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SAME_FLIGHT"), r)
p = call("propose_rebook", session_token=tok, current_flight="FL445", new_flight="FL447")[0]
check("eligible -> PROPOSED", p["outcome"] == "PROPOSED" and p["action_id"], p)
c = call("confirm_rebook", session_token=tok, action_id=p["action_id"])[0]
check("confirm -> EXECUTED on FL447", c["outcome"] == "EXECUTED" and c["to_flight"] == "FL447", c)
e = call("email_my_confirmation", session_token=tok, action_id=p["action_id"])[0]
check("email authorised -> SEND_OK", e["send_status"] == "SEND_OK", e)
k = call("open_service_case", session_token=tok, request_type="COMPENSATION_CLAIM",
         traveler_statement="FL801 delayed 90 minutes; I want compensation.",
         brief="90-minute inbound delay caused a missed connection; traveller requests compensation.")[0]
check("service case opened -> Customer Care", k["outcome"] == "CASE_OPENED" and "Customer Care" in k["assigned_team"], k)
r = call("get_my_itinerary", session_token="forged")
check("forged token -> SESSION_INVALID", r[0]["session_status"] == "SESSION_INVALID", r)

print(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  - now re-load reset_data.sql")
sys.exit(1 if fails else 0)
