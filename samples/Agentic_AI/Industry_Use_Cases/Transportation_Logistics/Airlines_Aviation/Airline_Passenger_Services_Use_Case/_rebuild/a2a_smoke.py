#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of PassengerServicesAgents one small, identity-free request over A2A JSON-RPC
(message/send) - no orchestrator - and prove from the Agents log that the agent answered, that its reference tool flow
ran, that the PostgreSQL query in it executed without error and returned rows, and that the answer carries text that
only the reference table holds (so the agent really used it).
Start the Agents exe with FLOGO_LOG_LEVEL=DEBUG and its output in a file, then:
    A2A_LOG=<agents log> python _rebuild/a2a_smoke.py
Env: A2A_LOG (required), A2A_HOST (default http://localhost), REPLY_TIMEOUT (seconds per agent, default 240).
Uses the LLM (3 agent calls). Reads no database itself and writes nothing.
ref_tool_runs() is also imported by chat_e2e.py for the same evidence during the chat run."""
import datetime, json, os, re, sys, time, urllib.request, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import AGENT_REF_TOOLS

ANSI = re.compile(r"\x1b\[[0-9;]*m")
PORTS = {"rebooking_options_agent": 9853, "baggage_claim_agent": 9854, "special_assistance_agent": 9855}
# flow + activity names (rebooking_options_agent keeps the names it was built with)
FLOWS = {"rebooking_options_agent": ("rebooking_options_agent_flow", "SearchAlternatives")}
ERROR_LINE = re.compile(r"\tERROR\t|query execution failed|missing substitution")
LOOKUP = re.compile(r'input arguments data: \{"parameters":\{"\w+":("(?:[^"\\]|\\.)*"|null)')


def flow_of(t):
    return FLOWS.get(t["agent"], (t["tool"] + "_flow", "ReadReference"))


def prepared(t):
    """The statement the PostgreSQL activity logs: ?placeholders become $1, $2 ... in order."""
    sql, k = t["read"][0], [0]
    def rep(_m):
        k[0] += 1
        return f"${k[0]}"
    return re.sub(r"\?\w+", rep, sql)


def ref_tool_runs(seg, t):
    """Every call of reference tool t in a DEBUG-log segment of the Agents app, with the evidence that its PostgreSQL
    query ran: [{event, query, done, rows, error, lookup}]. The window is the handler's start/complete lines (same
    event id), so calls of different agents in one segment are told apart. rows counts t["row_key"] keys in the
    (truncated) response line - a lower bound."""
    flow, act = flow_of(t)
    stmt = prepared(t)
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
                         query=any(f"Prepared Query Statement is : {stmt}" in l for l in w),
                         done=any(f"Activity [{act}] for instance" in l and "completed" in l for l in w),
                         rows=resp.count(f'"{t.get("row_key") or "section"}":'),
                         error=any(ERROR_LINE.search(l) for l in w),
                         lookup=json.loads(lk.group(1)) if lk else None))
    return runs


TODAY = datetime.date.today().isoformat()
# Each request is shaped like the orchestrator's minimised A2A message (no name, PNR, flight booking, ids or tokens).
REQUESTS = {
    "rebooking_options_agent":
        f"Route: ATL to MIA. earliest_departure: {TODAY}T13:30:00. Preferred cabin: Business. Traveller's preferences, in "
        "their own words: I need to arrive in Miami before 8pm, and I would like a window seat.",
    "baggage_claim_agent":
        "Traveller's description: My checked bag did not come off the belt after my flight yesterday. It is a blue fabric "
        "suitcase that stands upright on wheels, medium size. Inside are a suit, a few shirts, my laptop charger and my "
        "toiletries.",
    "special_assistance_agent":
        "Traveller's needs, in their own words: My mother is flying with me. She cannot manage the stairs up to the plane, "
        "but she can walk from the aircraft door to her seat. She is also hard of hearing.",
}
# Text that ONLY the agent's reference table holds - proves the answer used the rows (not the prompt). Each entry is a
# group of acceptable alternatives (a legitimate model choice must not fail the check).
TABLE_ONLY = {
    "rebooking_options_agent": [("FL447",), ("19:45", "7:45")],                 # the schedule's flight and its arrival
    "baggage_claim_agent": [("bag_type: 22",), ("colour: BU",),                  # Meridian's bag-type chart + colour codes
                            ("Meridian Baggage Services decides any reimbursement",)],
    "special_assistance_agent": [("WCHS",), ("cannot climb aircraft steps; needs a wheelchair and a lift or jet bridge to board",),
                                 ("Assistance stays pending until the Meridian Accessibility Desk confirms it",)],
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
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    res_ = {"passes": 0, "fails": 0}

    def check(label, cond, detail=""):
        print((("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:500]}")).encode("ascii", "replace").decode())
        res_["passes" if cond else "fails"] += 1

    for t in AGENT_REF_TOOLS:
        agent, tool = t["agent"], t["tool"]
        if only and agent not in only:
            continue
        flow = flow_of(t)[0]
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
        check(f"{agent}: PostgreSQL ran SELECT * FROM {t['fn']}(...) and the query activity completed",
              bool(runs) and all(r["query"] and r["done"] for r in runs), runs)
        check(f"{agent}: the query returned reference rows", bool(runs) and all(r["rows"] > 0 for r in runs), runs)
        check(f"{agent}: no ERROR / query failure in the tool flow", bool(runs) and not any(r["error"] for r in runs), runs)
        miss = [g for g in TABLE_ONLY[agent] if not any(k.lower() in answer.lower() for k in g)]
        check(f"{agent}: the answer carries table-only text", not miss, miss)
        if agent == "baggage_claim_agent":
            ct = re.search(r"claim_type:\s*\**\s*([A-Z_]+)", answer)
            mf = re.search(r"missing_fields:\s*(.+)", answer)
            check("baggage_claim_agent: claim_type DELAYED (bag did not arrive yesterday)", bool(ct) and ct.group(1) == "DELAYED",
                  ct.group(1) if ct else answer[:300])
            check("baggage_claim_agent: contents use the guide's CONTENT terms (CLOTHING, ELECTRONICS, TOILETRIES)",
                  all(k in answer for k in ("CLOTHING", "ELECTRONICS", "TOILETRIES")), answer[:400])
            check("baggage_claim_agent: missing_fields flags BAG_TAG (no tag number given)",
                  bool(mf) and "BAG_TAG" in mf.group(1), mf.group(1) if mf else answer[:300])
        if agent == "special_assistance_agent":
            sc = re.search(r"ssr_codes:\s*(.+)", answer)
            codes = set(re.findall(r"\b[A-Z]{4}\b", sc.group(1))) if sc else set()
            check("special_assistance_agent: ssr_codes = WCHS + DEAF (one wheelchair code, no WCHR / WCHC)",
                  {"WCHS", "DEAF"} <= codes and not ({"WCHR", "WCHC"} & codes), sc.group(1) if sc else answer[:300])
        if agent == "rebooking_options_agent":
            check("rebooking_options_agent: never offers FL445 (no seats) or a flight the schedule does not have",
                  "FL445" not in answer and not re.search(r"\bFL(?!447|449)\d{3}\b", answer), answer[:400])
        print(f"   lookup term(s) the model sent: {[r['lookup'] for r in runs]}")
        print("   answer:", answer.strip().replace("\n", " | ")[:700].encode("ascii", "replace").decode())

    p, f_ = res_["passes"], res_["fails"]
    print(f"\n{'A2A SMOKE OK' if not f_ else str(f_) + ' FAILURE(S)'}  ({p} passed, {f_} failed)")
    sys.exit(1 if f_ else 0)


if __name__ == "__main__":
    main()
