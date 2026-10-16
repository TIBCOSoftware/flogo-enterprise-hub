#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of AssetHealthAgents one small, identity-free request over A2A JSON-RPC
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
PORTS = {"field_note_triage_agent": 9953, "similar_failure_agent": 9954, "shift_handover_agent": 9955}
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
    "field_note_triage_agent":
        "Asset type: rod pump\n"
        "Current health line: WARNING (vibration -> bearing_wear): vibration 5.4 g RMS WARNING (warning above 3.5, "
        "critical above 6)\n"
        "Technician note exactly as written: 'Growling from the gearbox on the downstroke, grease slinging off the saddle "
        "bearing, SPM steady.'\n"
        "Failure modes to choose from only:\n"
        "- failure_mode: bearing_wear; label: Rod pump bearing wear (gearbox, saddle or wrist pin); typical_parts: saddle "
        "bearing assembly, wrist-pin bearing kit, gearbox oil\n"
        "- failure_mode: overheating; label: Gearbox or motor overheating; typical_parts: gearbox oil, V-belt set, motor "
        "cooling fan\n"
        "- failure_mode: seal_leak; label: Stuffing box / polished rod seal leak; typical_parts: stuffing box packing set, "
        "polished rod liner\n"
        "- failure_mode: flow_blockage; label: Fluid pound, gas lock or low fillage; typical_parts: gas anchor, pump barrel "
        "cleanout kit",
    "similar_failure_agent":
        "Asset type: rod pump\n"
        "New symptom text: Growling from the gearbox on the downstroke, grease slinging off the saddle bearing.\n"
        "Reliability library rows:\n"
        "- wo_number: MRE-WO-1001; past_asset: PUMP-PB-W48; basin: Permian Basin; closed: 2026-07-20; failure_mode: "
        "bearing_wear; symptom: Growl from the gearbox on every downstroke, vibration climbing for a week, grease purging at "
        "the wrist pin.; fix_applied: Replaced both wrist-pin bearings and the saddle bearing, realigned the walking beam, "
        "changed the gearbox oil.; parts_used: wrist-pin bearing kit, saddle bearing assembly, gearbox oil; downtime_hours: 14\n"
        "- wo_number: MRE-WO-1003; past_asset: PUMP-PB-W47; basin: Permian Basin; closed: 2026-03-17; failure_mode: "
        "seal_leak; symptom: Polished rod running hot, oil weeping at the stuffing box.; fix_applied: Repacked the stuffing "
        "box and replaced the polished rod liner.; parts_used: stuffing box packing set, polished rod liner; downtime_hours: 5",
    "shift_handover_agent": '[{"item_type": "OPEN_CASE", "ref": "sensor threshold change", "asset_id": "COMP-BK-S05", "item_status": "OPEN", "detail": "waiting for Production Engineering", "due_or_when": "reply due 2026-10-14 07:37"}, {"item_type": "ASSET_HEALTH", "ref": "PUMP-BK-W21", "asset_id": "PUMP-BK-W21", "item_status": "WARNING", "detail": "electric submersible pump (OPERATIONAL) - pressure 690 psi WARNING (warning below 800); flow 72 bbl/h WARNING (warning below 80) | likely seal_leak, confidence 0.85, 10-21 days to failure", "due_or_when": "reading 2026-10-13 12:00"}, {"item_type": "WORK_ORDER", "ref": "MRE-WO-1028", "asset_id": "PUMP-BK-W21", "item_status": "IN_PROGRESS", "detail": "HIGH CORRECTIVE - seal_leak: Seal degradation progressing - pull the ESP and replace the seal section. | Bakken Field Crew B", "due_or_when": "scheduled 2026-10-15"}, {"item_type": "WORK_ORDER", "ref": "MRE-WO-1031", "asset_id": "VALVE-BK-W03", "item_status": "SCHEDULED", "detail": "ROUTINE PREVENTIVE - Stem packing service. | Bakken Field Crew B", "due_or_when": "scheduled 2026-10-17"}, {"item_type": "ALERT", "ref": "ALR-000098", "asset_id": "PUMP-BK-W21", "item_status": "ACKNOWLEDGED", "detail": "WARNING - Pressure and flow below the warning limits.", "due_or_when": "logged 2026-10-13 06:10"}]',
}
# A reply part that only the reference table can supply (the agent must have read it, not its prompt).
TABLE_ONLY = {
    "field_note_triage_agent": ("crew check is the meaning text of the guide's bearing_wear CREW_CHECK row (table only)",
                                ["before any bearing is ordered", "oil or grease condition"]),
    "similar_failure_agent": ("reference note is the guide's standard note for the best match level (table only)",
                              ["first reference for the crew to confirm on site", "use the recorded fix as background only"]),
    "shift_handover_agent": ("closing line / status words come from the handover guide (table only)",
                             ["statuses as recorded", "crew and date booked", "seen by the control room"]),
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
