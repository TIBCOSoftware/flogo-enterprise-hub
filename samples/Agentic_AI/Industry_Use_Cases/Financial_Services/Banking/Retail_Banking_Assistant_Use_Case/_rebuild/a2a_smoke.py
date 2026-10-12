#!/usr/bin/env python3
"""Step 3: call the running RetailBankingAgents A2A server directly (no orchestrator) and prove the
dispute_triage_agent decodes a cryptic descriptor and suggests a reason code.
Start the agents app first, then:   python _rebuild/a2a_smoke.py
Env: A2A_URL (default http://localhost:9863), A2A_TIMEOUT (default 180 s). Read-only: no DB state is changed.
The agent's wording varies run to run, so the text checks are loose."""
import json, os, re, sys, urllib.error, urllib.request, uuid
from datetime import date, timedelta

A2A_URL = os.environ.get("A2A_URL", "http://localhost:9863").rstrip("/")
TIMEOUT = int(os.environ.get("A2A_TIMEOUT", "180"))
fails, passes = 0, 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

def check(label, cond, detail=""):
    global fails, passes
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1
    passes += 1 if cond else 0

def http(url, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data, method="POST" if body is not None else "GET",
                                 headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode("utf-8", errors="replace")
    lines = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")]   # tolerate an SSE-framed reply
    return json.loads(lines[-1] if lines else raw)

def norm(x): return re.sub(r"[\s\-]+", "_", str(x or "").strip().lower())

# ---------------- 1. agent card ----------------
card, card_path = None, None
# current A2A path first; the legacy agent.json path answers 200 with a JSON-RPC error on the Flogo runtime
for path in ("/.well-known/agent-card.json", "/.well-known/agent.json"):
    try:
        got = http(A2A_URL + path)
        if not (isinstance(got, dict) and got.get("name")):
            out(f"  (GET {path} returned no agent card: {str(got)[:120]})")
            continue
        card, card_path = got, path
        break
    except Exception as e:   # 404 / refused / timeout / not JSON
        out(f"  (GET {path} failed: {e})")
check("agent card served", card is not None, f"neither card path answered at {A2A_URL}")
if card is None:
    out(f"\n1 FAILURE(S) - is RetailBankingAgents running on {A2A_URL}?")
    sys.exit(1)
out(f"  card at {card_path}: name={card.get('name')!r} url={card.get('url')!r} skills="
    f"{[sk.get('name') or sk.get('id') for sk in card.get('skills', [])]}")
names = {norm(card.get("name"))} | {norm(sk.get(k)) for sk in card.get("skills", []) for k in ("id", "name")}
check("card names dispute_triage_agent (agent or skill)", "dispute_triage_agent" in names, names)

# ---------------- 2. message/send ----------------
today = date.today()
PROMPT = ("Customer's own words: \"I don't recognise this charge, I never bought anything from them.\"\n"
          "Candidate transactions:\n"
          f"- TXN-50003 | QUICKPAY*XYZ 872-555 | 249.99 USD | {today - timedelta(days=6)}\n"
          f"- TXN-50013 | QUICKPAY*XYZ 872-555 | 18.75 USD | {today - timedelta(days=20)}\n"
          "The customer mentioned the 249.99 charge. Which transaction is it, who is the merchant really, how does it "
          "bill, and which dispute reason code do you recommend?")

def payload(method):
    msg = {"role": "user", "kind": "message", "messageId": str(uuid.uuid4()),
           "parts": [{"kind": "text", "text": PROMPT}]}
    params = {"message": msg}
    if method == "tasks/send":   # pre-0.2 A2A shape: task id + parts typed with "type"
        msg["parts"][0]["type"] = "text"
        params["id"] = str(uuid.uuid4())
    return {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}

def texts(node):
    """All text parts below a node (parts[].text, also parts[].data / parts[].root.text)."""
    found = []
    if isinstance(node, dict):
        for p in node.get("parts", []) or []:
            if isinstance(p, dict):
                p = p.get("root", p)
                if isinstance(p.get("text"), str): found.append(p["text"])
                elif p.get("data") is not None: found.append(json.dumps(p["data"]))
    return found

def reply_text(result):
    if isinstance(result, str): return result
    if not isinstance(result, dict): return json.dumps(result)
    parts = []
    parts += texts(result)                                              # result is a Message
    parts += texts((result.get("status") or {}).get("message") or {})   # Task.status.message
    for a in result.get("artifacts", []) or []:                         # Task.artifacts[]
        parts += texts(a)
    if not parts:   # last resort: agent messages in history (skip the user's own turn)
        for m in result.get("history", []) or []:
            if isinstance(m, dict) and m.get("role") != "user": parts += texts(m)
    return "\n".join(parts)

rpc_urls = [A2A_URL]
if card.get("url") and card["url"].rstrip("/") != A2A_URL:
    rpc_urls.append(card["url"].rstrip("/"))
result, used, errors = None, None, []
for url in rpc_urls:
    for method in ("message/send", "tasks/send"):
        out(f"  POST {url} method={method} (timeout {TIMEOUT}s) ...")
        try:
            resp = http(url, payload(method), timeout=TIMEOUT)
        except urllib.error.HTTPError as e:
            errors.append(f"{url} {method}: HTTP {e.code} {e.read()[:200]!r}"); continue
        except Exception as e:   # timeout / refused / bad JSON
            errors.append(f"{url} {method}: {type(e).__name__}: {e}"); continue
        if "error" in resp:
            errors.append(f"{url} {method}: JSON-RPC error {resp['error']}")
            continue   # -32601 method not found -> try the older method name
        result, used = resp.get("result"), (url, method)
        break
    if result is not None:
        break

for e in errors: out("  ! " + e)
check("A2A JSON-RPC call answered", result is not None, errors)
if result is None:
    out(f"\n{fails} FAILURE(S)")
    sys.exit(1)
out(f"  method that worked: {used[1]} at {used[0]}")
reply = reply_text(result)
out("  raw reply: " + (reply[:600].replace("\n", " ") + ("..." if len(reply) > 600 else "")))
low = reply.lower()
check("reply is non-empty", bool(reply.strip()), json.dumps(result)[:400])
check("decodes the merchant (mentions XYZ)", "xyz" in low, reply[:300])
check("picks the right charge (TXN-50003 or 249.99)", "txn-50003" in low or "249.99" in low, reply[:300])
check("recommends UNRECOGNISED/UNRECOGNIZED/FRAUD", re.search(r"unrecogni[sz]ed|fraud", low) is not None, reply[:300])

out(f"\n{'A2A AGENT OK' if not fails else str(fails) + ' FAILURE(S)'}  ({passes} passed, {fails} failed; method={used[1]})")
sys.exit(1 if fails else 0)
