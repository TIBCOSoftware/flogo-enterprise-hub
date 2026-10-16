#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of MobileBillingAgents one small, identity-free request over A2A JSON-RPC
(message/send) - no orchestrator - and prove from the Agents log that the agent answered, that its reference tool flow
(<tool>_flow) ran, that the PostgreSQL query in it executed without error and returned rows, and that the answer carries
text that only the reference table holds (so the agent really used it).
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
PORTS = {"PlanRecommender": 9903, "ChargeClassifier": 9904, "BillExplainer": 9905}
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


_today = datetime.date.today()
_next1 = (_today.replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
_m = [(_today.replace(day=1) - datetime.timedelta(days=1 + 31 * k)).strftime("%b %Y") for k in range(3)]   # last 3 cycles
# Each request is shaped like the orchestrator's minimised A2A message (no name, number, ids or tokens) and worded so it
# lands in the storyline's category (Maria's plan advice, Priya's fraud signal, Maria's bill jump).
REQUESTS = {
    "PlanRecommender":
        f"Data use, last three cycles: {_m[0]} 13.9 GB, {_m[1]} 12.6 GB, {_m[2]} 11.8 GB. Days abroad: {_m[0]}: Mexico 4 days; "
        f"{_m[1]}: no days abroad; {_m[2]}: Mexico 3 days. Customer's words: 'I travel to Mexico a lot - which plan suits me?' "
        "Plan rows (plan_code | plan_name | data_gb | monthly_price | device_plan | roaming_included | change_type | "
        "effective_date | price_diff | allowed | reason_code): "
        f"BASIC5 | Tidewell Basic 5GB | 5 GB | 30.00 | no | Not included - TravelPass $10/day or pay-per-use | DOWNGRADE | {_next1} | -15.00 | yes | ; "
        f"UNLPLUS | Tidewell Unlimited Plus | Unlimited | 65.00 | no | Not included - TravelPass $10/day or pay-per-use | UPGRADE | {_today} | 20.00 | yes | ; "
        f"UNLPLUSD | Tidewell Unlimited Plus + device | Unlimited | 85.00 | yes (36-month device installment) | Not included - TravelPass $10/day or pay-per-use | UPGRADE | {_today} | 40.00 | yes | ; "
        f"UNLPREM | Tidewell Unlimited Premium | Unlimited | 85.00 | no | Mexico & Canada included; elsewhere TravelPass $10/day or pay-per-use | UPGRADE | {_today} | 40.00 | yes | .",
    "ChargeClassifier":
        "Customer's words: 'I was charged for roaming in Canada but I never left the US - and I had a SIM swap recently.' "
        "Line items (description | amount | date | category): Pay-per-use roaming data, Canada, 40 MB @ $2.05/MB | 82.00 | "
        f"{_today.replace(day=1) - datetime.timedelta(days=4)} | ROAMING; Pay-per-use roaming calls, Canada, 8 min @ $1.79/min | "
        f"14.32 | {_today.replace(day=1) - datetime.timedelta(days=4)} | ROAMING. Days abroad in that bill period: 0. "
        f"Last SIM swap date: {_today.replace(day=1) - datetime.timedelta(days=6)}.",
    "BillExplainer":
        "Bill comparison (category | previous_amount | latest_amount | delta): plan | 45.00 | 45.00 | 0.00; roaming | 0.00 | "
        "206.47 | 206.47; premium_content | 0.00 | 9.99 | 9.99; voice_sms | 0.00 | 0.00 | 0.00; taxes_fees | 7.00 | 8.54 | 1.54; "
        "other | 0.00 | 0.00 | 0.00. previous_total 52.00, latest_total 270.00. Latest bill line items (description | amount | "
        "category): Tidewell Essential 15GB - monthly plan | 45.00 | PLAN; StarPlay Games (Pixelridge Media) - monthly "
        "subscription | 9.99 | PREMIUM_CONTENT; Pay-per-use roaming data, Mexico, 20 MB @ $2.05/MB | 41.00 | ROAMING; "
        "Pay-per-use roaming calls, Mexico, 10 min @ $1.79/min | 17.90 | ROAMING; Pay-per-use roaming data, Mexico, 25 MB @ "
        "$2.05/MB | 51.25 | ROAMING; Pay-per-use roaming data, Mexico, 22 MB @ $2.05/MB | 45.10 | ROAMING; Pay-per-use roaming "
        "calls, Mexico, 8 min @ $1.79/min | 14.32 | ROAMING; Pay-per-use roaming data, Mexico, 18 MB @ $2.05/MB | 36.90 | "
        "ROAMING; Taxes, surcharges & fees | 8.54 | TAXES_FEES.",
}
# Text that ONLY the agent's reference table holds - proves the answer used the rows (not the prompt). Each entry is a
# required item; a tuple means "any one of these" (a legitimate model choice between two table rows).
TABLE_ONLY = {
    "PlanRecommender": ["say yes to the exact change Nova proposes", ("cost nothing extra", "headroom")],
    "ChargeClassifier": ["SUSPECTED_FRAUD", "checked by a person on our Fraud Team"],
    "BillExplainer": ["come straight from your last two bills",
                      ("by the megabyte", "by the minute", "until it is cancelled", "outside content company")],
}


def table_only_missing(agent, answer):
    low = answer.lower()
    return [k for k in TABLE_ONLY[agent]
            if not any(x.lower() in low for x in (k if isinstance(k, tuple) else (k,)))]


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
        check(f"{agent}: called its reference tool at most once ({len(runs)})", len(runs) <= 1, runs)
        miss = table_only_missing(agent, answer)
        check(f"{agent}: the answer carries table-only text {TABLE_ONLY[agent]}", not miss, miss)
        print(f"   lookup term(s) the model sent: {[r['lookup'] for r in runs]}")
        print("   answer:", answer.strip().replace("\n", " | ")[:600].encode("ascii", "replace").decode())

    p, f_ = res_["passes"], res_["fails"]
    print(f"\n{'A2A SMOKE OK' if not f_ else str(f_) + ' FAILURE(S)'}  ({p} passed, {f_} failed)")
    sys.exit(1 if f_ else 0)


if __name__ == "__main__":
    main()
