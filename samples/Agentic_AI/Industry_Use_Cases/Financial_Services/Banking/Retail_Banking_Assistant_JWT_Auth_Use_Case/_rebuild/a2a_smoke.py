#!/usr/bin/env python3
"""Test ladder step 3b: call each A2A agent of RetailBankingSecureAgents directly over A2A JSON-RPC (no orchestrator).

Per agent it checks the Static Token auth first, then the original functional check:
  1. the agent card (GET /.well-known/agent-card.json) is served WITHOUT a token and advertises the Bearer scheme
     (Flogo 2.26.7 keeps the card public; only message calls are protected);
  2. message/send with no Authorization header      -> rejected;
  3. message/send with a wrong token                -> rejected;
  4. message/send with ANOTHER agent's token        -> rejected (one token per agent);
  5. message/send with the agent's own token        -> answered, and the Agents log proves that its reference tool flow
     (<tool>_flow) ran, that the PostgreSQL query in it executed without error and returned rows, and that the answer
     carries text only the reference table holds (so the agent really used it).
A rejected call never reaches the agent: no tool runs and no LLM call is made (checked in the log).

HOW FLOGO 2.26.7 REJECTS (A2A trigger, agentAuthMode "Static Token"): NOT with HTTP 401/403. The token is checked inside
the A2A executor, so the HTTP status is 200 and the JSON-RPC result is a Task whose status.state is "failed", with the
status message text "no authentication token provided in the request" (no Authorization header) or "authentication
token provided in the request is incorrect" (a wrong token, or a header without the "Bearer " prefix). message/stream behaves the same (a final "failed"
status-update). The Agents log shows: ERR A2A executor: agent completed with error error="<that text>".

Start the Agents exe with FLOGO_LOG_LEVEL=DEBUG, its output in a file, and the three real tokens supplied at run time
(e.g. FLOGO_APP_PROPS_JSON=<path of a JSON file with {"A2A.<agent>.AuthToken": "...", ...}>), then:
    A2A_LOG=<agents log> A2A_TOKEN_DISPUTE=... A2A_TOKEN_SCAM=... A2A_TOKEN_HARDSHIP=... python _rebuild/a2a_smoke.py
Env: A2A_LOG (required), A2A_TOKEN_DISPUTE / A2A_TOKEN_SCAM / A2A_TOKEN_HARDSHIP (required; the values of
A2A.dispute_triage_agent.AuthToken / A2A.scam_signal_agent.AuthToken / A2A.hardship_intake_agent.AuthToken),
A2A_HOST (default http://localhost), REPLY_TIMEOUT (seconds per agent, default 240).
Uses the LLM (3 agent calls; the rejected calls use none). Reads no database itself and writes nothing. Never prints a token.
ref_tool_runs() is also imported by chat_e2e.py for the same evidence during the chat run."""
import json, os, re, sys, time, urllib.error, urllib.request, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tool_spec import AGENT_REF_TOOLS

ANSI = re.compile(r"\x1b\[[0-9;]*m")
PORTS = {"dispute_triage_agent": 9973, "scam_signal_agent": 9974, "hardship_intake_agent": 9975}
TOKEN_ENV = {"dispute_triage_agent": "A2A_TOKEN_DISPUTE", "scam_signal_agent": "A2A_TOKEN_SCAM",
             "hardship_intake_agent": "A2A_TOKEN_HARDSHIP"}
NO_TOKEN = "no authentication token provided in the request"
BAD_TOKEN = "authentication token provided in the request is incorrect"
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


# Each request is shaped like the orchestrator's minimised A2A message (no name, ids, account numbers or tokens).
REQUESTS = {
    "dispute_triage_agent":
        "Customer's words: 'I don't recognise a $249.99 charge from QUICKPAY last week, I never ordered anything.' "
        "Candidate transactions: TXN-50003 | QUICKPAY*XYZ 872-555 | 249.99 | 6 days ago; TXN-50013 | QUICKPAY*XYZ 872-555 | "
        "18.75 | 20 days ago; TXN-50002 | FRESHMART GROCERY #44 | 86.42 | 8 days ago.",
    "scam_signal_agent":
        "Customer's words about the payment: 'Someone from the bank's fraud team called and said my account is compromised. "
        "He told me to move my savings to a safe account they set up for me today, and not to tell anyone at the branch "
        "because staff might be involved.' Payment facts: amount $9,500.00; payee type PERSON; new payee: yes; from a "
        "savings account.",
    "hardship_intake_agent":
        "Customer's words: 'I was laid off three weeks ago. I start a new job in about two months, but until then I can't "
        "make my car loan payments.' Affected products: AUTO loan - monthly payment $812.33, next due in 14 days.",
}
# Text that ONLY the agent's reference table holds - proves the answer used the rows (not the prompt).
TABLE_ONLY = {
    "dispute_triage_agent": ["XYZ Gadgets Online"],
    "scam_signal_agent": ["SAFE_ACCOUNT", "no bank uses safe accounts"],
    "hardship_intake_agent": ["JOB_LOSS", "work this out alone"],
}


def http(method, url, body=None, token=None, timeout=60):
    """(HTTP status, parsed JSON or raw text). Never raises on an HTTP error status."""
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, json.dumps(body).encode() if body is not None else None, headers, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        status, raw = r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read().decode("utf-8", "replace")
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, raw


def send(host, port, text, timeout, token=None):
    body = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "message/send",
            "params": {"message": {"role": "user", "kind": "message", "messageId": str(uuid.uuid4()),
                                   "parts": [{"kind": "text", "text": text}]}}}
    return http("POST", f"{host}:{port}", body, token, timeout)


def texts(o):
    """Text parts of the agent's answer (task artifacts / status message / direct message) - not the echoed history."""
    if isinstance(o, dict):
        own = [o["text"]] if o.get("kind") == "text" and isinstance(o.get("text"), str) else []
        return own + [t for k, v in o.items() if k != "history" for t in texts(v)]
    return [t for v in o for t in texts(v)] if isinstance(o, list) else []


def rejection(status, res):
    """The auth error text when the call was rejected (HTTP 401/403, or Flogo's HTTP 200 + failed Task), else None."""
    if status in (401, 403):
        return f"HTTP {status}"
    if not isinstance(res, dict):
        return None
    if "error" in res:
        return str(res["error"])
    r = res.get("result") or {}
    st = r.get("status") or {}
    if st.get("state") == "failed" and not r.get("artifacts"):
        return " ".join(texts(st.get("message") or {})) or "failed"
    return None


def log_pos(log): return os.path.getsize(log)


def log_since(log, pos):
    with open(log, "rb") as f:
        f.seek(pos)
        return ANSI.sub("", f.read().decode("utf-8", "ignore"))


def main():
    log = os.environ.get("A2A_LOG") or sys.exit("set A2A_LOG to the Agents app's log file (FLOGO_LOG_LEVEL=DEBUG)")
    missing = [v for v in TOKEN_ENV.values() if not os.environ.get(v)]
    if missing:
        sys.exit(f"set {', '.join(missing)} (the values of the A2A.<agent>.AuthToken properties the Agents app runs with)")
    tokens = {a: os.environ[v] for a, v in TOKEN_ENV.items()}
    host = os.environ.get("A2A_HOST", "http://localhost")
    timeout = int(os.environ.get("REPLY_TIMEOUT", "240"))
    res_ = {"passes": 0, "fails": 0}

    def check(label, cond, detail=""):
        msg = ("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:500]}")
        for tok in tokens.values():
            msg = msg.replace(tok, "<token>")
        print(msg.encode("ascii", "replace").decode())
        res_["passes" if cond else "fails"] += 1

    agents = [t["agent"] for t in AGENT_REF_TOOLS]
    for t in AGENT_REF_TOOLS:
        agent, tool, flow = t["agent"], t["tool"], t["tool"] + "_flow"
        port, own = PORTS[agent], tokens[agent]
        other = tokens[agents[(agents.index(agent) + 1) % len(agents)]]
        print(f"== {agent} ({host}:{port}) ==")

        # 1. agent card: public in Flogo 2.26.7, advertises the Bearer scheme
        s0, card0 = http("GET", f"{host}:{port}/.well-known/agent-card.json")
        s1, card1 = http("GET", f"{host}:{port}/.well-known/agent-card.json", token=own)
        schemes = json.dumps((card0 if isinstance(card0, dict) else {}).get("securitySchemes") or {})
        check(f"{agent}: agent card served without a token (HTTP {s0}) and names the agent",
              s0 == 200 and isinstance(card0, dict) and card0.get("name") == agent, (s0, str(card0)[:200]))
        check(f"{agent}: agent card advertises the static Bearer token scheme", '"scheme": "Bearer"' in schemes, schemes)
        check(f"{agent}: agent card with the token is the same card (HTTP {s1})", s1 == 200 and card1 == card0, s1)

        # 2-4. rejected calls: no token, wrong token, another agent's token
        for label, tok, want in [("no Authorization header", None, NO_TOKEN),
                                 ("a wrong token", "wrong-" + uuid.uuid4().hex, BAD_TOKEN),
                                 ("another agent's token", other, BAD_TOKEN)]:
            pos = log_pos(log)
            try:
                status, res = send(host, port, REQUESTS[agent], 60, tok)
            except Exception as e:                    # noqa: BLE001 - report and continue
                check(f"{agent}: message/send with {label} rejected", False, e)
                continue
            why = rejection(status, res)
            check(f"{agent}: message/send with {label} rejected (HTTP {status}, {why!r})",
                  why is not None and want in why, (status, res))
            time.sleep(0.5)
            seg = log_since(log, pos)
            check(f"{agent}: ... the agent never ran (no tool call, no {flow})",
                  f'error="{want}"' in seg and "Executing toolmap" not in seg and f"Executing handler [{flow}]" not in seg,
                  seg[-400:])

        # 5. the agent's own token: the original functional check
        pos, t0 = log_pos(log), time.time()
        try:
            status, res = send(host, port, REQUESTS[agent], timeout, own)
        except Exception as e:                        # noqa: BLE001 - report and continue with the next agent
            check(f"{agent}: A2A message/send with its token answered", False, e)
            continue
        res = res if isinstance(res, dict) else {"error": res}
        answer = "\n".join(texts(res.get("result", {})))
        check(f"{agent}: A2A message/send with its token answered in {time.time() - t0:.0f}s (HTTP {status})",
              status == 200 and bool(answer.strip()) and "error" not in res and rejection(status, res) is None,
              res.get("error") or res)
        time.sleep(1)
        seg = log_since(log, pos)
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
