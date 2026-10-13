#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of CorporatePaymentsAgents one small, identity-free request over A2A JSON-RPC
(message/send) - no orchestrator - and prove from the Agents log that the agent answered, that its reference tool flow
(<tool>_flow) ran, that the PostgreSQL query in it executed without error and returned rows, and that the answer carries
text that only the reference table holds (so the agent really used it).
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
PORTS = {"payment_triage_agent": 9873, "remittance_match_agent": 9874, "payee_name_match_agent": 9875}
ERROR_LINE = re.compile(r"\tERROR\t|query execution failed|missing substitution")
LOOKUP = re.compile(r'input arguments data: \{"parameters":\{"\w+":("(?:[^"\\]|\\.)*"|null)')


def ref_tool_runs(seg, t):
    """Every call of reference tool t in a DEBUG-log segment of the Agents app, with the evidence that its PostgreSQL
    query ran: [{event, query, done, rows, error, lookup}]. The window is the handler's start/complete lines (same
    event id), so calls of different agents in one segment are told apart. rows counts t["row_key"] keys in the
    (truncated) response line - a lower bound."""
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
                         rows=resp.count(f'"{t.get("row_key") or "section"}":'),
                         error=any(ERROR_LINE.search(l) for l in w),
                         lookup=json.loads(lk.group(1)) if lk else None))
    return runs


# Each request is shaped like the orchestrator's minimised A2A message (no legal name, client id, account numbers or tokens).
REQUESTS = {
    "payment_triage_agent":
        "Client's words: 'Why was our EUR 48,500 SEPA payment to our supplier returned?' Candidate payments: "
        "PMT-2026-000002 | OUTGOING | SEPA | 48500.00 | EUR | Lyon Textiles SARL | RETURNED | return code AC04 | value date 1 day ago; "
        "PMT-2026-000001 | OUTGOING | SWIFT | 250000.00 | USD | Pacific Components Ltd | IN_TRANSIT | no return code | 3 days ago; "
        "PMT-2026-000003 | OUTGOING | FEDWIRE | 12000.00 | USD | Atlas Freight Inc | COMPLETED | no return code | 4 days ago.",
    "remittance_match_agent":
        "Remittance note: 'INV 4417/4425 less 2% early pay + freight dispute $312'. Incoming payment: 46728.00 USD, value date "
        "yesterday. Candidate open invoices: 4398 | Harbor Retail Group | invoice date 40 days ago | open 12500.00 USD | 2/10 NET 30; "
        "4417 | Harbor Retail Group | 7 days ago | open 30000.00 USD | 2/10 NET 30; 4425 | Harbor Retail Group | 7 days ago | "
        "open 18000.00 USD | 2/10 NET 30; 4431 | Harbor Retail Group | 3 days ago | open 18000.00 USD | 2/10 NET 30; "
        "4433 | Summit Outdoor Supply | 12 days ago | open 9750.00 USD | NET 30.",
    "payee_name_match_agent":
        "Name the client typed for the payment: 'Rotterdam Shipping BV'. Name on file for the beneficiary account: "
        "'RD Global Trading LLC'.",
}
# Text that ONLY the agent's reference table holds - proves the answer used the rows (not the prompt). The kept
# payment_triage_agent decodes codes from the reason-code directory (its log evidence is the main proof).
TABLE_ONLY = {
    "payment_triage_agent": ["PMT-2026-000002", "closed"],
    "remittance_match_agent": ["4417", "4425", "EARLY_PAY_DISCOUNT", "FREIGHT", "remains open for the disputed amount"],
    "payee_name_match_agent": ["NO_MATCH", "DIFFERENT_NAME", "must not go to this account"],
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
        print((("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:500]}")).encode("ascii", "replace").decode())
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
        print("   answer:", answer.strip().replace("\n", " | ")[:500].encode("ascii", "replace").decode())

    p, f_ = res_["passes"], res_["fails"]
    print(f"\n{'A2A SMOKE OK' if not f_ else str(f_) + ' FAILURE(S)'}  ({p} passed, {f_} failed)")
    sys.exit(1 if f_ else 0)


if __name__ == "__main__":
    main()
