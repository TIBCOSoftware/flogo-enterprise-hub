#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of AerospaceMROAgents one small, identity-free request over A2A JSON-RPC
(message/send) - no orchestrator - and prove from the Agents log that the agent answered, that its reference tool flow
(<tool>_flow) ran, and that the PostgreSQL query in it executed without error and returned rows.
Start the Agents exe with FLOGO_LOG_LEVEL=DEBUG and its output in a file, then:
    A2A_LOG=<agents log> python _rebuild/a2a_smoke.py
Env: A2A_LOG (required), A2A_HOST (default http://localhost), REPLY_TIMEOUT (seconds per agent, default 240).
Uses the LLM (3 agent calls). Reads no database itself and writes nothing.
ref_tool_runs() is also imported by chat_e2e.py for the same evidence during the chat run."""
import json, os, re, sys, time, urllib.request, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import AGENT_REF_TOOLS

ANSI = re.compile(r"\x1b\[[0-9;]*m")
PORTS = {"fault_triage_agent": 9813, "repeat_defect_agent": 9814, "shift_handover_agent": 9815}
ERROR_LINE = re.compile(r"\tERROR\t|query execution failed|missing substitution")
LOOKUP = re.compile(r'input arguments data: \{"parameters":\{"lookup":("(?:[^"\\]|\\.)*"|null)')


def ref_tool_runs(seg, t):
    """Every call of reference tool t in a DEBUG-log segment of the Agents app, with the evidence that its PostgreSQL
    query ran: [{event, query, done, rows, error, lookup}]. The window is the handler's start/complete lines (same
    event id), so calls of different agents in one segment are told apart."""
    flow, fn = t["tool"] + "_flow", t["fn"]
    start = re.compile(r"Executing handler \[" + re.escape(flow) + r"\] for event Id \[([^\]]+)\]")
    lines, runs = seg.splitlines(), []
    for i, line in enumerate(lines):
        m = start.search(line)
        if not m:
            continue
        end = next((j for j in range(i + 1, len(lines))
                    if f"Handler [{flow}] for event id [{m.group(1)}] completed" in lines[j]), len(lines) - 1)
        w = lines[i:end + 1]
        resp = next((l for l in w if "SetAttr - name: response, value:" in l), "")
        lk = next((LOOKUP.search(l) for l in w if LOOKUP.search(l)), None)
        runs.append(dict(event=m.group(1),
                         query=any(f"Prepared Query Statement is : SELECT * FROM {fn}(CAST($1 AS text));" in l for l in w),
                         done=any("Activity [ReadReference] for instance" in l and "completed" in l for l in w),
                         rows=resp.count('"section":'),          # the response line is truncated: a lower bound
                         error=any(ERROR_LINE.search(l) for l in w),
                         lookup=json.loads(lk.group(1)) if lk else None))
    return runs


# Each request is shaped like the orchestrator's minimised A2A message and contains words the agent's guide defines.
REQUESTS = {
    "fault_triage_agent":
        "Defect write-up: 'HYD 2 press fluct in climb, weeping at the pump case drain, reservoir low on walkaround.' "
        "Aircraft type: NV-450 tactical airlifter. Candidate parts: NV29-4471-P - Hydraulic pump assembly, No.2 system - "
        "ATA 29; NV29-4471-SK - Hydraulic pump seal kit - ATA 29; NV29-1180-F - Hydraulic pressure line fitting kit - ATA 29.",
    "repeat_defect_agent":
        "New defect write-up: 'HYD 2 press fluctuating in climb, fluid weeping at the pump case drain line, reservoir low.' "
        "Past work orders for this aircraft (most recent first): "
        "WO-2026-00101 | opened 2026-10-12 | not closed | ATA 29 | No.2 hydraulic system pressure fluctuation with fluid "
        "leak at the pump case drain line; aircraft AOG | AWAITING_PARTS; "
        "WO-2026-00096 | opened 2026-10-03 | closed 2026-10-04 | ATA 29 | Crew report: HYD 2 LO PRESS caution in climb, "
        "cleared after landing; pressure line fitting O-ring replaced, leak check good | CLOSED; "
        "WO-2026-00088 | opened 2026-09-15 | closed 2026-09-16 | ATA 32 | Left main landing gear brake wear check - within "
        "limits | CLOSED; "
        "WO-2026-00091 | opened 2026-09-20 | closed 2026-09-21 | ATA 29 | Fluid found pooled under the left main gear well "
        "after landing; No.2 system reservoir serviced and return-line B-nut re-torqued | CLOSED; "
        "WO-2026-00084 | opened 2026-09-02 | closed 2026-09-03 | ATA 33 | Cargo bay flood light inoperative - lamp "
        "replaced | CLOSED.",
    "shift_handover_agent":
        "Handover snapshot rows (item_type | ref | tail_number | item_status | detail | due_or_eta): "
        "AOG | AOG-2026-012 | N078NV | RESOLVING | NV-35 ISR turboprop - Main landing gear actuator leak found on phase "
        "inspection; technician assigned, replacement actuator awaiting spend approval | on ground 72 h; "
        "WORK_ORDER | WO-2026-00201 | N078NV | AWAITING_PARTS | URGENT ATA 32 - main landing gear actuator replacement | "
        "needs LANDING GEAR | technician assigned | due 2026-10-20; "
        "WORK_ORDER | WO-2026-00202 | N055NV | OPEN | URGENT ATA 57 - wing spar inspection required before next flight | "
        "needs STRUCTURES | unassigned | due 2026-10-20; "
        "WORK_ORDER | WO-2026-00203 | N034NV | AWAITING_PARTS | ROUTINE ATA 32 - No.3 wheel brake assembly worn to limit | "
        "needs LANDING GEAR | unassigned | due 2026-10-19; "
        "PART_ORDER | PO-2026-0001 | N034NV | IN_TRANSIT | 1 x NV32-1002-B Wheel brake assembly (ROUTINE) for "
        "WO-2026-00203 | ETA 2026-10-16; "
        "OPEN_CASE | part spend approval | N078NV | OPEN | waiting for Maintenance Management | reply due 2026-10-13 16:30; "
        "OPEN_CASE | airworthiness directive compliance | N055NV | OPEN | waiting for Quality & Airworthiness | reply due "
        "2026-10-13 22:00.",
}
# A reply part that only the reference table can supply (the agent must have read it, not its prompt).
TABLE_ONLY = {
    "fault_triage_agent": ("triage note is the ATA 29 row's standard note (table only)",
                           ["case drain flow before calling for a pump change", "record the leak rate on the work order"]),
    "repeat_defect_agent": ("reliability note is the guide's standard note for the flag (table only)",
                            ["repeat-defect criteria", "no similar event on this aircraft in the last 90 days"]),
    "shift_handover_agent": ("closing line / status words come from the handover guide (table only)",
                             ["statuses as recorded", "on hold for parts", "shipped, on its way"]),
}


def send(host, port, text, timeout):
    body = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "message/send",
            "params": {"message": {"role": "user", "kind": "message", "messageId": str(uuid.uuid4()),
                                   "parts": [{"kind": "text", "text": text}]}}}
    req = urllib.request.Request(f"{host}:{port}", json.dumps(body).encode(), {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8"))


def texts(o):
    """Text parts of the agent's answer (task artifacts / status message / direct message) - not the echoed history."""
    if isinstance(o, dict):
        own = [o["text"]] if o.get("kind") == "text" and isinstance(o.get("text"), str) else []
        return own + [t for k, v in o.items() if k != "history" for t in texts(v)]
    return [t for v in o for t in texts(v)] if isinstance(o, list) else []


def main():
    log = os.environ.get("A2A_LOG") or sys.exit("set A2A_LOG to the Agents app's log file (FLOGO_LOG_LEVEL=DEBUG)")
    host = os.environ.get("A2A_HOST", "http://localhost")
    timeout = int(os.environ.get("REPLY_TIMEOUT", "240"))
    res_ = {"passes": 0, "fails": 0}

    def check(label, cond, detail=""):
        print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:500]}"))
        res_["passes" if cond else "fails"] += 1

    for t in AGENT_REF_TOOLS:
        agent, tool, flow = t["agent"], t["tool"], t["tool"] + "_flow"
        pos, t0 = os.path.getsize(log), time.time()
        try:
            res = send(host, PORTS[agent], REQUESTS[agent], timeout)
        except Exception as e:                    # noqa: BLE001 - report and continue with the next agent
            check(f"{agent}: A2A message/send answered", False, e)
            continue
        answer = "\n".join(texts(res.get("result", {})))
        check(f"{agent}: A2A message/send answered in {time.time() - t0:.0f}s", bool(answer.strip()) and "error" not in res,
              res.get("error") or res)
        time.sleep(1)
        with open(log, "rb") as f:
            f.seek(pos)
            seg = ANSI.sub("", f.read().decode("utf-8", "ignore"))
        runs = ref_tool_runs(seg, t)
        check(f"{agent}: tool {tool} was called (Executing toolmap[toolName:{tool}])",
              f"Executing toolmap[toolName:{tool}]" in seg)
        check(f"{agent}: handler [{flow}] ran", bool(runs))
        check(f"{agent}: PostgreSQL ran SELECT * FROM {t['fn']}(...) and ReadReference completed",
              bool(runs) and all(r["query"] and r["done"] for r in runs), runs)
        check(f"{agent}: the query returned reference rows", bool(runs) and all(r["rows"] > 0 for r in runs), runs)
        check(f"{agent}: no ERROR / query failure in the tool flow", bool(runs) and not any(r["error"] for r in runs), runs)
        label, words = TABLE_ONLY[agent]
        check(f"{agent}: {label}", any(w in answer.lower() for w in words), answer[:300])
        print(f"   lookup term(s) the model sent: {[r['lookup'] for r in runs]}")
        print("   answer:", answer.strip().replace("\n", " | ")[:400].encode("ascii", "replace").decode())

    p, f_ = res_["passes"], res_["fails"]
    print(f"\n{'A2A SMOKE OK' if not f_ else str(f_) + ' FAILURE(S)'}  ({p} passed, {f_} failed)")
    sys.exit(1 if f_ else 0)


if __name__ == "__main__":
    main()
