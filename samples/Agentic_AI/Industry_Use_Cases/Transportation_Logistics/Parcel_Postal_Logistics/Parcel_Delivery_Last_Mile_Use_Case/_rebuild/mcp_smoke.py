#!/usr/bin/env python3
"""Call the running ParcelDeliveryMCPServer tools directly - no LLM - to prove the rules hold at the MCP edge.
Start the MCP server first, load reset_data.sql, then:   python _rebuild/mcp_smoke.py
Leaves one executed reschedule + one service case behind - re-load reset_data.sql afterwards."""
import json, os, sys, urllib.request

URL = os.environ.get("MCP_URL", "http://localhost:9892/parcel-delivery-mcp")
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
check("11 tools listed", len(tools) == 11, sorted(tools))
check("read-only hint on reads", tools["get_my_parcels"].get("annotations", {}).get("readOnlyHint") is True, tools["get_my_parcels"])
check("arguments schema published", "session_token" in json.dumps(tools["propose_reschedule"].get("inputSchema")), tools["propose_reschedule"])

r = call("verify_recipient", account_ref="K4R2QX", pin="0000")
check("wrong PIN -> NOT_VERIFIED", r[0]["status"] == "NOT_VERIFIED" and not r[0]["session_token"], r)
r = call("verify_recipient", account_ref="K4R2QX", pin="4021")
check("right ref+PIN -> VERIFIED", r[0]["status"] == "VERIFIED", r)
tok = r[0]["session_token"]
r = call("get_my_parcels", session_token=tok)
check("scoped parcels = 3", len([x for x in r if x["tracking_number"]]) == 3, r)
r = call("get_parcel_detail", session_token=tok, tracking_number="SB100000000001")
check("exception decoded, NEEDS_ATTENTION", r[0]["delivery_health"] == "NEEDS_ATTENTION" and r[0]["exception_label"], r)
r = call("propose_reschedule", session_token=tok, tracking_number="SB100000000001", slot_id="SLOT-W1")
check("guard: wrong area slot", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SLOT_WRONG_AREA"), r)
p = call("propose_reschedule", session_token=tok, tracking_number="SB100000000001", slot_id="SLOT-N1")[0]
check("eligible -> PROPOSED", p["outcome"] == "PROPOSED" and p["action_id"], p)
c = call("confirm_reschedule", session_token=tok, action_id=p["action_id"])[0]
check("confirm -> EXECUTED on SLOT-N1", c["outcome"] == "EXECUTED" and c["target"] == "SLOT-N1", c)
e = call("email_confirmation", session_token=tok, action_id=p["action_id"])[0]
check("email authorised -> SEND_OK", e["send_status"] == "SEND_OK", e)
r = call("propose_redirect", session_token=tok, tracking_number="SB100000000002", pickup_id="PU-N-LOCK1")
check("guard: signature parcel -> locker refused", r[0]["outcome"] == "NOT_PROPOSED" and r[0]["reason"].startswith("SIGNATURE_REQUIRED"), r)
k = call("open_service_case", session_token=tok, request_type="DELIVERY_COMPLAINT", tracking_number="SB100000000001",
         recipient_statement="Repeated failed delivery attempts.",
         brief="Parcel SB100000000001 had a failed delivery attempt; recipient is unhappy with the service.")[0]
check("service case opened -> Customer Relations", k["outcome"] == "CASE_OPENED" and "Customer Relations" in k["assigned_team"], k)
r = call("get_parcel_detail", session_token="forged", tracking_number="SB100000000001")
check("forged token -> SESSION_INVALID", r[0]["lookup_status"] == "SESSION_INVALID", r)

print(f"\n{'MCP EDGE OK' if not fails else str(fails) + ' FAILURE(S)'}  - now re-load reset_data.sql")
sys.exit(1 if fails else 0)
