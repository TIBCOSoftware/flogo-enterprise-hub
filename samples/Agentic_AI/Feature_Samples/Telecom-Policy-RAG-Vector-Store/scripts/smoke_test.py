#!/usr/bin/env python3
"""End-to-end smoke test for TelecomPolicyKnowledgeHub.

Walks the full document lifecycle against a running app and checks each step:

  1. ingest the 5 policy PDFs            POST   /policy/ingest/files      (ChunkAndEmbed File Paths + Vector Upsert)
  2. semantic search                     GET    /policy/search            (ChunkAndEmbed Text + Vector Search)
  3. publish a Markdown policy update    POST   /policy/ingest/text       (ChunkAndEmbed Markdown + Vector Upsert)
  4. ask the AI agent (RAG over chat)    ws://.../policy-assistant         (AI Agent tool -> Vector Search)
  5. retire the update                   DELETE /policy/documents/{id}    (Vector Delete by Filter)
  6. reject an unsafe document id        DELETE /policy/documents/...     (validation before the filter)
  7. delete a single chunk by key        POST   /policy/chunks/delete     (Vector Delete by Key)

Usage:  python scripts/smoke_test.py [--rest http://localhost:9740] [--ws ws://localhost:9741/policy-assistant] [--no-chat]
The chat step needs `pip install websocket-client`; it is skipped with --no-chat.
Re-runnable: ingestion uses Replace mode and the test retires what it publishes.
"""
import argparse, glob, json, os, sys, time, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
UPDATE_ID = "TC-POL-006"
UPDATE_MD = os.path.join(ROOT, "policy_updates", "TC-POL-006_eSIM_Activation_and_Transfer_Policy.md")

passed, failed = 0, 0


def check(name, ok, detail=""):
    global passed, failed
    passed, failed = passed + bool(ok), failed + (not ok)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  - {detail}" if detail else ""))


def call(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def search(rest, q):
    _, d = call("GET", f"{rest}/policy/search?" + urllib.parse.urlencode({"q": q}))
    return d.get("matches") or []


def chat(ws_url, questions):
    import websocket  # pip install websocket-client
    ws = websocket.create_connection(ws_url, timeout=180)
    try:
        answers = []
        for q in questions:
            ws.send(q)
            answers.append(ws.recv())
        return answers
    finally:
        ws.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rest", default="http://localhost:9740")
    ap.add_argument("--ws", default="ws://localhost:9741/policy-assistant")
    ap.add_argument("--no-chat", action="store_true")
    a = ap.parse_args()

    print("1. Ingest policy PDFs (ChunkAndEmbed File Paths -> Vector Upsert)")
    pdfs = sorted(glob.glob(os.path.join(ROOT, "policy_docs", "*.pdf")))
    code, d = call("POST", f"{a.rest}/policy/ingest/files", {"filePaths": pdfs})
    check("5 PDFs ingested", code == 200 and d.get("status") == "INGESTED" and d.get("chunksEmbedded", 0) > 0
          and not d.get("skippedFiles"), f"{d.get('chunksEmbedded')} chunks, {d.get('totalTokens')} tokens")

    print("2. Semantic search (ChunkAndEmbed Text -> Vector Search)")
    for q, doc in [("How much does roaming data cost per GB in Japan?", "TC-POL-001"),
                   ("How long must an outage last before I get a bill credit?", "TC-POL-005"),
                   ("What is the early termination fee if I upgrade my phone early?", "TC-POL-004")]:
        m = search(a.rest, q)
        top = m[0]["source"] if m else ""
        check(f"top match for '{q[:45]}...' is {doc}", doc in top, f"score {m[0]['score']:.3f}" if m else "no matches")

    print(f"3. Publish {UPDATE_ID} as Markdown (ChunkAndEmbed Markdown -> Vector Upsert)")
    code, d = call("POST", f"{a.rest}/policy/ingest/text",
                   {"documentId": UPDATE_ID, "text": open(UPDATE_MD, encoding="utf-8").read()})
    check(f"{UPDATE_ID} ingested", code == 200 and d.get("chunksEmbedded", 0) > 0, f"{d.get('chunksEmbedded')} chunks")
    m = search(a.rest, "How many free eSIM transfers do I get per month?")
    check(f"eSIM question now finds {UPDATE_ID}", bool(m) and UPDATE_ID in m[0]["source"],
          m[0]["source"] if m else "no matches")

    if not a.no_chat:
        print("4. Ask the AI agent over WebSocket (agent tool -> Vector Search)")
        try:
            ans = chat(a.ws, ["What does roaming data cost per GB in Japan?",
                              "How many free eSIM transfers do I get in 30 days, and what does the next one cost?"])
            for i, x in enumerate(ans, 1):
                print(f"     A{i}: {x[:300].replace(chr(10), ' ')}")
            check("roaming answer cites TC-POL-001 and quotes a rate", "TC-POL-001" in ans[0] and "45" in ans[0])
            check(f"eSIM answer cites {UPDATE_ID} (3 free, 10.00 USD)", UPDATE_ID in ans[1] and "3" in ans[1] and "10" in ans[1])
        except ImportError:
            check("chat step", False, "pip install websocket-client (or run with --no-chat)")

    print(f"5. Retire {UPDATE_ID} (Vector Delete by Filter)")
    code, d = call("DELETE", f"{a.rest}/policy/documents/{UPDATE_ID}")
    check(f"{UPDATE_ID} retired", code == 200 and d.get("rowsDeleted", 0) > 0, f"{d.get('rowsDeleted')} rows deleted")
    m = search(a.rest, "How many free eSIM transfers do I get per month?")
    check(f"no {UPDATE_ID} chunk is returned any more", all(UPDATE_ID not in x["source"] for x in m))
    code, d = call("DELETE", f"{a.rest}/policy/documents/{UPDATE_ID}")
    check("retiring again deletes nothing", code == 200 and d.get("rowsDeleted") == 0)
    if not a.no_chat:
        try:
            ans = chat(a.ws, ["How many free eSIM transfers do I get in 30 days?"])[0]
            print(f"     A: {ans[:300].replace(chr(10), ' ')}")
            check(f"agent no longer cites the retired {UPDATE_ID}", UPDATE_ID not in ans)
        except ImportError:
            pass

    print("6. Reject an unsafe document id before it reaches the filter")
    code, d = call("DELETE", f"{a.rest}/policy/documents/" + urllib.parse.quote("x' OR 'a'='a", safe=""))
    check("filter-injection attempt rejected with 400", code == 400 and d.get("status") == "REJECTED")

    print("7. Delete one chunk by key (Vector Delete by Key)")
    m = search(a.rest, "SIM swap cooling-off period")
    if m:
        key = m[0]["key"]
        code, d = call("POST", f"{a.rest}/policy/chunks/delete", {"keys": [key]})
        check(f"key '{key}' submitted", code == 200 and d.get("keysSubmitted") == 1)
        check("deleted chunk no longer returned", all(x["key"] != key for x in search(a.rest, "SIM swap cooling-off period")))
        print("     (re-run step 1 to restore it)")
        call("POST", f"{a.rest}/policy/ingest/files", {"filePaths": pdfs})
    else:
        check("search returned a chunk to delete", False)

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
