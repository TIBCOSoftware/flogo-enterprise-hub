#!/usr/bin/env python3
"""Step 3: quick WebSocket check of the CorporatePaymentsAIOrchestrator before the full chat e2e.
Start all three apps, then:   python _rebuild/ws_smoke.py
Env: WS_URL (default ws://localhost:9870/corporatepayments), REPLY_TIMEOUT (default 150 s). No DB state is changed."""
import os, re, sys, time
import websocket   # pip install websocket-client

WS = os.environ.get("WS_URL", "ws://localhost:9870/corporatepayments")
TIMEOUT = int(os.environ.get("REPLY_TIMEOUT", "150"))
fails = 0

def out(s):
    print(str(s).encode("ascii", "replace").decode())   # console is cp1252-safe

def check(label, cond, detail=""):
    global fails
    out(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {str(detail)[:300]}"))
    fails += 0 if cond else 1

try:
    ws = websocket.create_connection(WS, timeout=TIMEOUT)
except Exception as e:
    check(f"connect {WS}", False, f"{type(e).__name__}: {e}")
    sys.exit(1)
check(f"connect {WS}", True)
reply = ""
try:
    t = time.time()
    ws.send("Hello, are you an AI assistant?")
    reply = ws.recv()
    if isinstance(reply, bytes): reply = reply.decode("utf-8", errors="replace")
    out(f"  < ({time.time() - t:.0f}s) " + reply[:300].replace("\n", " "))
except websocket.WebSocketTimeoutException:
    out(f"  ! no reply within {TIMEOUT}s")
finally:
    ws.close()
check(f"non-empty reply within {TIMEOUT}s", bool(reply.strip()))
check("reply says it is an AI", re.search(r"\bai\b|artificial|virtual assistant|automated", reply.lower()) is not None, reply)
out(f"\n{'WEBSOCKET OK' if not fails else str(fails) + ' FAILURE(S)'}")
sys.exit(1 if fails else 0)
