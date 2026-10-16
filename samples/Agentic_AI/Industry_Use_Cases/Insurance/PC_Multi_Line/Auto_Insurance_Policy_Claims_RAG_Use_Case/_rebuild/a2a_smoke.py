#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of AutoInsuranceAgents one small, identity-free request over A2A JSON-RPC
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
PORTS = {"fnol_intake_agent": 9913, "coverage_interpreter_agent": 9914, "fraud_signal_agent": 9915}
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
    "fnol_intake_agent":
        "Today is 2026-10-13. Story: Last night around 11 pm someone broke into my car in the apartment parking lot and "
        "took my laptop bag from the back seat. The passenger window is smashed. I have not called the police yet.",
    "coverage_interpreter_agent":
        "Product tier: Full Coverage. Coverage names on the policy: Bodily Injury Liability, Property Damage Liability, "
        "Collision, Comprehensive, Medical Payments, Uninsured Motorist. FNOL fields: claim_type Weather; damage_areas "
        "engine; what happened: drove into a flooded underpass after heavy rain and the engine stalled and will not "
        "restart. Retrieved passages: [Copperleaf Personal Auto Policy - Full Coverage] 7. Exclusions - Water ingestion "
        "when driving into flood water: We do not pay for damage to the engine, transmission or electrical system "
        "caused by water ingestion when the covered auto is knowingly driven into standing or moving flood water, "
        "including a flooded road, ford or underpass. This exclusion applies even when the flooded road or underpass "
        "was open to traffic.",
    "fraud_signal_agent":
        "Narrative: At first I said it happened at 6 pm on the highway, but now I think it was around 2 am on a back "
        "road. A car in front braked hard for no reason and I hit it; the other driver said his passenger saw it all. "
        "My neck hurts. I need the money in cash this week. FNOL fields: claim_type Collision; incident_time 02:00; "
        "damage_areas front bumper, hood; injuries yes; police_report no. review_signals: prior_claims_12m=2; "
        "policy_age_days=20; report_delay_days=0; incident_hour=2; amount_to_value=0.69; repeat_repair_shop=yes; "
        "prior_same_type=yes; recent_coverage_change=no",
}
# A reply part that only the reference table can supply (the agent must have read it, not its prompt).
TABLE_ONLY = {
    "fnol_intake_agent": ("adjuster_follow_ups uses the checklist's Theft TYPE_DETAIL wording",
                          ["what was taken", "where the car was parked", "whether it was locked", "police report"]),
    "coverage_interpreter_agent": ("clause_ref is the clause index's pointer (Full Coverage wording s7)",
                                   ["full coverage wording s7"]),
    "fraud_signal_agent": ("indicators use the guide's INDICATOR names",
                           ["story changes between versions", "staged-accident pattern", "pressure for fast payment",
                            "soft-tissue-only injury claim"]),
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
