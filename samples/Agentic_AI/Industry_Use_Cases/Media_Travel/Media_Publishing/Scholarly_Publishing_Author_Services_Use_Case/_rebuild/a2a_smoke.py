#!/usr/bin/env python3
"""Test ladder step 3b: send each A2A agent of AuthorServicesAgents one small, identity-free request over A2A JSON-RPC
(message/send) - no orchestrator - and prove from the Agents log that the agent answered, that its reference tool flow
ran, that the PostgreSQL query in it executed without error and returned rows, and that the answer carries text that
only the reference table holds (so the agent really used it).
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
PORTS = {"journal_match_agent": 9843, "review_summary_agent": 9844, "submission_check_agent": 9845}
# flow + activity names (journal_match_agent keeps the names it was built with)
FLOWS = {"journal_match_agent": ("journal_match_agent_flow", "SearchJournals")}
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


COMMENTS_0301 = (
    "Manuscript title: Sentinel-1 flood extent mapping with uncertainty bands.\n"
    "E.1 | Editor | Both reviewers find the method promising. Please address every comment, in particular the calibration "
    "dataset (Reviewer 1) and the comparison with optical imagery (Reviewer 2). The revised manuscript is due in 21 days.\n"
    "R1.1 | Reviewer 1 | The calibration dataset is described only briefly. Please state which flood events were used for "
    "calibration, how many SAR scenes, and how they were kept separate from the validation events; the reported accuracy "
    "depends on this.\n"
    "R1.2 | Reviewer 1 | The uncertainty bands in Figure 4 are hard to read. Please use a colour-blind-safe palette and label "
    "the 5th and 95th percentiles.\n"
    "R1.3 | Reviewer 1 | Table 2 gives only point values for the F1 scores. Please report confidence intervals as well.\n"
    "R2.1 | Reviewer 2 | I am not convinced the method generalises. Please add a comparison with flood extents derived from "
    "optical imagery for at least one event where cloud-free scenes exist.\n"
    "R2.2 | Reviewer 2 | The introduction misses recent work on Bayesian change detection for SAR flood mapping; please "
    "discuss it.\n"
    "R2.3 | Reviewer 2 | Optional: a short note on the computing time per scene would help practitioners.")
REFS_0301 = ["E.1", "R1.1", "R1.2", "R1.3", "R2.1", "R2.2", "R2.3"]

# Each request is shaped like the orchestrator's minimised A2A message (no name, ORCID, ids or tokens).
REQUESTS = {
    "journal_match_agent":
        "Title: Machine-learning downscaling of compound coastal flood risk for small island states. Abstract: We present a "
        "gradient-boosted downscaling model that combines storm-surge hindcasts, tide-gauge records and rainfall reanalysis "
        "to estimate compound coastal flood risk at 250 m resolution for twelve small island states. Validated against "
        "surveyed flood extents, the model reduces error by 31% versus dynamical downscaling. Keywords: coastal flooding, "
        "compound flood risk, machine learning, downscaling, storm surge, small island states. Article type: Research "
        "Article. Word count: 7800. Current journal: JACI.",
    "review_summary_agent": "Please turn these comments into a revision checklist.\n" + COMMENTS_0301,
    "submission_check_agent":
        "Target journal: EDSR. The author's statements as written:\n"
        "Data availability: Data are available from the corresponding author on reasonable request.\n"
        "Ethics: Not applicable.\n"
        "Funding: Supported by the Southwest Fire Science Consortium (grant SFSC-2026-07).\n"
        "Author contributions: Conceptualization and methodology by the first author; data curation and software by the "
        "second author; writing by both authors.",
}
# Text that ONLY the agent's reference table holds - proves the answer used the rows (not the prompt). Each entry is a
# group of acceptable alternatives (a legitimate model choice must not fail the check).
TABLE_ONLY = {
    "journal_match_agent": [("Coastal Hazards and Risk Review", "Hydrology and Climate Resilience Letters",
                             "Geospatial Analytics Quarterly"), ("Gold OA", "Hybrid")],   # a catalogue title + its OA model
    "review_summary_agent": [("answer every item point by point in the same order",), ("METHODS",), ("STATISTICS", "DATA"),
                             ("OPTIONAL",)],
    "submission_check_agent": [("COMPETING_INTERESTS",), ("The authors declare no competing interests.",),
                               ("deposit the data and code behind your results in a public repository",)],
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
        if agent == "review_summary_agent":
            cited = set(re.findall(r"\b(E\.\d+|R\d+\.\d+)\b", answer))
            check("review_summary_agent: one item per comment - every reference is cited, none invented",
                  cited == set(REFS_0301), sorted(cited ^ set(REFS_0301)))
            check("review_summary_agent: R2.3 (marked optional by the reviewer) is OPTIONAL",
                  bool(re.search(r"OPTIONAL[^\n]*R2\.3|R2\.3[^\n]*OPTIONAL", answer)), answer[-600:])
        if agent == "submission_check_agent":
            mi = re.search(r"missing_items:\s*(.+)", answer)
            check("submission_check_agent: missing_items flags DATA_AVAILABILITY and COMPETING_INTERESTS",
                  bool(mi) and "DATA_AVAILABILITY" in mi.group(1) and "COMPETING_INTERESTS" in mi.group(1), mi.group(1) if mi else answer[:300])
            check("submission_check_agent: it looked up the target journal (EDSR) or the whole policy",
                  bool(runs) and all(str(r["lookup"] or "").upper() in ("EDSR", "") for r in runs), [r["lookup"] for r in runs])
        print(f"   lookup term(s) the model sent: {[r['lookup'] for r in runs]}")
        print("   answer:", answer.strip().replace("\n", " | ")[:700].encode("ascii", "replace").decode())

    p, f_ = res_["passes"], res_["fails"]
    print(f"\n{'A2A SMOKE OK' if not f_ else str(f_) + ' FAILURE(S)'}  ({p} passed, {f_} failed)")
    sys.exit(1 if f_ else 0)


if __name__ == "__main__":
    main()
