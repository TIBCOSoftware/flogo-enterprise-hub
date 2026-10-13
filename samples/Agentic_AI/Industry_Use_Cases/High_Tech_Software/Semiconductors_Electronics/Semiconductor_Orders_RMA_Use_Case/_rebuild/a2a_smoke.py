#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of SemiOrdersAgents one small, identity-free request over A2A JSON-RPC
(message/send) - no orchestrator - and prove from the Agents log that the agent answered, that its reference tool flow
(<tool>_flow) ran, and that the PostgreSQL query in it executed without error and returned rows - and that the answer carries text
that only the reference table holds (so the agent really used it).
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
PORTS = {"part_finder_agent": 9823, "rma_triage_agent": 9824, "pcn_impact_agent": 9825}
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
    "part_finder_agent":
        "BOM line in the customer's words: 'N-ch MOSFET 650V 8A TO-220, PV boost stage'. Application: solar inverter. "
        "Candidate catalog rows: AW-MF-6508 | MOSFET | N-channel power MOSFET, 650 V | 650 V, 8 A, 0.42 Ohm RDS(on), "
        "avalanche rated | TO-220 | aec_grade none | ACTIVE | ltb_date none | qty_available 42000; AW-MF-6515 | MOSFET | "
        "N-channel power MOSFET, 650 V | 650 V, 15 A, 0.19 Ohm RDS(on), avalanche rated | TO-247 | aec_grade none | "
        "ACTIVE | ltb_date none | qty_available 9500; AW-MF-6008 | MOSFET | N-channel power MOSFET, 600 V | 600 V, 8 A, "
        "0.45 Ohm RDS(on) | TO-220 | aec_grade none | ACTIVE | ltb_date none | qty_available 30000.",
    "rma_triage_agent":
        "Customer's description: 'About 40 of these failed in our solar inverters after a few weeks in the field - gate "
        "shorted, and one scorched the board.' Part: MOSFET - N-channel power MOSFET, 650 V. Quantity affected: 40.",
    "pcn_impact_agent":
        "Notice: type PCN; title 'Assembly site transfer and mold compound change: AW-MC-3204'; description 'Assembly and "
        "final test of AW-MC-3204 move from the current subcontract site to a second qualified site, and the mold "
        "compound changes to a halogen-free equivalent. Form, fit and function are unchanged and the moisture "
        "sensitivity level stays MSL 3. Parts built at the new site carry date codes from the effective date onward and "
        "may ship mixed with old-site parts for up to 8 weeks. A qualification report is available on request, and "
        "customers may request samples during the 90-day review window.'; published 2026-09-23; effective 2026-12-22; "
        "last-time-buy date none; replacement part none. Open lines on that part: 2,500 pieces promised 2026-11-03; "
        "1,000 pieces promised 2027-01-12.",
}
# Text that ONLY the agent's reference table holds - proves the answer used the rows (not the prompt).
TABLE_ONLY = {
    "part_finder_agent": ["RATING_BELOW", "your engineers must confirm the part for your design"],
    "rma_triage_agent": ["ESD-safe packaging", "heat, smoke or fire"],
    "pcn_impact_agent": ["built the current way", "may contain changed parts"],
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
        miss = [k for k in TABLE_ONLY[agent] if k.lower() not in answer.lower()]
        check(f"{agent}: the answer carries table-only text {TABLE_ONLY[agent]}", not miss, miss)
        print(f"   lookup term(s) the model sent: {[r['lookup'] for r in runs]}")
        print("   answer:", answer.strip().replace("\n", " | ")[:400].encode("ascii", "replace").decode())

    p, f_ = res_["passes"], res_["fails"]
    print(f"\n{'A2A SMOKE OK' if not f_ else str(f_) + ' FAILURE(S)'}  ({p} passed, {f_} failed)")
    sys.exit(1 if f_ else 0)


if __name__ == "__main__":
    main()
