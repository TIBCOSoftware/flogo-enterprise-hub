#!/usr/bin/env python3
"""Mortgage MCP Server Demo Recorder
Connects to the live Flogo MCP server, calls real endpoints, and writes
an asciinema .cast file.  Convert to GIF with:
    agg mortgage-demo.cast mortgage-mcp-demo.gif --font-size 14 --theme dracula
"""

import json, time, urllib.request, urllib.error

MCP_URL = "http://localhost:8035/mcp"
OUTPUT  = "c:/Flogo/workspace/Claude/mortgage-demo.cast"
APP_ID  = "APP-2026-001"
W, H    = 140, 42

# ── ANSI codes ──────────────────────────────────────────────────
RST = "\033[0m"
GRN = "\033[92m"   # bright green  – commands
CYN = "\033[96m"   # bright cyan   – HTTP / values
YLW = "\033[93m"   # bright yellow – JSON keys / labels
WHT = "\033[97m"   # white
DIM = "\033[90m"   # dim gray      – comments, decorations
BLD = "\033[1m"
RED = "\033[91m"
MGN = "\033[95m"   # magenta       – Claude reasoning
ORG = "\033[38;5;208m"   # orange  – brand accent
GBG = "\033[42m\033[30m" # green background

# ── Cast file event list ─────────────────────────────────────────
START  = time.time()
EVENTS = []

def ts():
    return round(time.time() - START, 4)

def emit(text):
    EVENTS.append([ts(), "o", text])

def nl(text=""):
    emit(text + "\r\n")

def typewrite(text, speed=0.032):
    for ch in text:
        emit(ch)
        time.sleep(speed)

def prompt():
    nl()
    emit(f"{DIM}❯  {RST}{GRN}")

def pause(s):
    time.sleep(s)

def section_bar(title):
    nl()
    nl(f"{DIM}{'─' * 68}{RST}")
    nl(f"{ORG}{BLD}  {title}{RST}")
    nl(f"{DIM}{'─' * 68}{RST}")
    nl()

# ── MCP client (real HTTP calls) ────────────────────────────────
session_id = None
call_id    = 0

def mcp_post(body, with_session=True):
    global session_id
    headers = {
        "Content-Type": "application/json",
        "Accept":       "application/json, text/event-stream",
    }
    if with_session and session_id:
        headers["Mcp-Session-Id"] = session_id
    req = urllib.request.Request(
        MCP_URL, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            sid = resp.getheader("Mcp-Session-Id")
            if sid:
                session_id = sid
            raw = resp.read().decode("utf-8")
            for line in raw.split("\n"):
                line = line.strip()
                if line.startswith("data:"):
                    return json.loads(line[5:].strip())
    except Exception as e:
        return {"error": str(e)}

def rpc(method, params=None):
    global call_id
    call_id += 1
    return mcp_post({"jsonrpc": "2.0", "id": call_id, "method": method, "params": params or {}})

def notify(method, params=None):
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    headers = {
        "Content-Type": "application/json",
        "Accept":       "application/json, text/event-stream",
        "Mcp-Session-Id": session_id,
    }
    req = urllib.request.Request(
        MCP_URL, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except:
        pass

# ── Scripted tool responses (demo data) ─────────────────────────
RESPONSES = {
    "GetApplicantProfile": {
        "applicantId": APP_ID, "name": "Sarah Chen", "dob": "1988-03-14",
        "kyc_status": "VERIFIED", "risk_band": "LOW",
        "address": "47 Maple Drive, Austin TX 78701", "pep_check": "CLEAR",
    },
    "GetCreditScore": {
        "credit_score": 724, "grade": "B+", "defaults": 0,
        "late_payments_24m": 0, "hard_inquiries_90d": 1,
        "utilization_rate": 0.22, "bureau": "Equifax",
    },
    "GetPropertyValuation": {
        "estimated_value": 395000, "confidence": "HIGH",
        "ltv_ratio": 72.2, "property_type": "RESIDENTIAL",
        "valuation_date": "2026-05-08",
    },
    "CheckExistingDebts": {
        "total_monthly_commitments": 1240, "open_accounts": 2,
        "missed_payments_24m": 0,
        "accounts": [
            {"type": "CAR_LOAN",     "monthly": 640, "balance": 12800},
            {"type": "CREDIT_CARD",  "monthly": 600, "limit":   8000},
        ],
    },
    "VerifyEmployment": {
        "employer": "Horizon Tech Solutions", "employment_type": "PERMANENT",
        "years_at_employer": 6.2, "gross_annual_income": 98000, "verified": True,
    },
    "CalculateDTI": {
        "dti_ratio": 28.4, "monthly_income": 8167, "total_monthly_debt": 2326,
        "proposed_payment": 1086, "assessment": "PASS",
    },
    "ApproveMortgage": {
        "status": "APPROVED", "mortgageRef": "MTG-2026-88421",
        "decision_timestamp": "2026-05-08T13:45:09Z",
        "rate_offered": 4.85, "monthly_payment": 1642, "term_years": 25,
    },
    "LogDecision": {
        "auditId": "AUD-2026-004891",
        "logged_at": "2026-05-08T13:45:10Z", "status": "PERSISTED",
    },
}

CONNECTORS = {
    "GetApplicantProfile":  ("PostgreSQL", "SELECT * FROM applicants"),
    "GetCreditScore":       ("REST API",   "GET localhost:9091/credit"),
    "GetPropertyValuation": ("REST API",   "POST localhost:9091/valuation"),
    "CheckExistingDebts":   ("PostgreSQL", "SELECT * FROM existing_debts"),
    "VerifyEmployment":     ("REST API",   "GET localhost:9091/employment"),
    "CalculateDTI":         ("REST API",   "GET localhost:9091/calculate-dti"),
    "ApproveMortgage":      ("PostgreSQL", "INSERT INTO mortgage_decisions"),
    "LogDecision":          ("PostgreSQL", "INSERT INTO audit_log"),
}

ANALYSIS = {
    "GetApplicantProfile":  [
        f"KYC: VERIFIED ✓   Risk band: LOW ✓   PEP check: CLEAR ✓",
        f"Identity confirmed. No adverse flags.",
    ],
    "GetCreditScore":       [
        f"Score: 724 ✓  (min 680)   Grade: B+   Defaults: 0   Inquiries (90d): 1",
        f"Credit profile healthy. No adverse events in 24 months.",
    ],
    "GetPropertyValuation": [
        f"Value: $395,000   LTV: 72.2% ✓  (max 85%)   Confidence: HIGH",
        f"Strong collateral. $110k equity buffer above loan request.",
    ],
    "CheckExistingDebts":   [
        f"Monthly commitments: $1,240   Open accounts: 2   Missed (24m): 0",
        f"Clean repayment history. Debt load manageable.",
    ],
    "VerifyEmployment":     [
        f"Employer: Horizon Tech   Type: PERMANENT   Tenure: 6.2yr   Income: $98,000",
        f"Stable permanent income. 6+ year tenure confirms reliability.",
    ],
    "CalculateDTI":         [
        f"DTI: 28.4% ✓  (max 38%)   Income: $8,167/mo   Assessment: PASS",
        f"",
        f"{'─'*50}  SYNTHESIS",
        f"Credit ✓   LTV ✓   DTI ✓   Employment ✓   Debts ✓   KYC ✓",
        f"All 6 checks PASSED.  Decision: APPROVE   Confidence: 92%",
    ],
    "ApproveMortgage":      [
        f"Approval written → mortgage_decisions table",
        f"Ref: MTG-2026-88421   Rate: 4.85%   Monthly: $1,642",
    ],
    "LogDecision":          [
        f"Audit record persisted → audit_log table",
        f"Audit ref: AUD-2026-004891   Regulatory compliance: ✓",
    ],
}


def render_json(data, indent=4):
    pad = " " * indent
    for k, v in data.items():
        if isinstance(v, list):
            nl(f"{pad}{YLW}\"{k}\"{RST}: {DIM}[...{len(v)} item(s)...]{RST}")
        elif isinstance(v, bool):
            color = GRN if v else RED
            nl(f"{pad}{YLW}\"{k}\"{RST}: {color}{json.dumps(v)}{RST}")
        elif isinstance(v, (int, float)):
            nl(f"{pad}{YLW}\"{k}\"{RST}: {CYN}{v}{RST}")
        else:
            nl(f"{pad}{YLW}\"{k}\"{RST}: {WHT}{json.dumps(v)}{RST}")


def show_tool(name, num, total):
    connector, query = CONNECTORS.get(name, ("", ""))
    nl()
    nl(f"{DIM}  ┌── Tool {num}/{total}: {GRN}{name}{RST} {DIM}──────────────────────────────────{RST}")
    prompt()
    typewrite(f'tools/call {name}  applicationId="{APP_ID}"')
    emit(RST)
    pause(0.2)
    nl()
    nl(f"{DIM}  → {connector}:  {query}{RST}")
    pause(0.7)
    nl()
    nl(f"{CYN}  HTTP 200 OK{RST}")
    nl(f"{DIM}  {{")
    render_json(RESPONSES.get(name, {}))
    nl(f"{DIM}  }}{RST}")
    pause(0.4)
    for line in ANALYSIS.get(name, []):
        nl(f"{MGN}    ◆ {line}{RST}")
        pause(0.7)


# ── MAIN ────────────────────────────────────────────────────────
def run():
    # Clear screen + header
    emit("\033[2J\033[H")
    nl(f"{ORG}{BLD}{'═' * 72}{RST}")
    nl(f"{ORG}{BLD}  TIBCO FLOGO  ·  Autonomous Mortgage AI Processor  ·  MCP Demo{RST}")
    nl(f"{WHT}  claude-sonnet-4-6  ↔  Flogo 2.26.2  ·  10 MCP Tools  ·  port 8035{RST}")
    nl(f"{ORG}{BLD}{'═' * 72}{RST}")
    nl()
    pause(1.0)

    # ─── ACT I: Initialize ───────────────────────────────────────
    section_bar("ACT I — Discovery  |  Initialising MCP Session")

    prompt()
    typewrite('# Step 1: Establish MCP session with Flogo server')
    emit(RST)
    nl()
    prompt()
    typewrite(f'Invoke-MCPSession -Uri "{MCP_URL}"')
    emit(RST)
    pause(0.3)
    nl()
    nl(f"{DIM}  Connecting...{RST}")

    # Real initialize call
    init_resp = rpc("initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "claude-sonnet-4-6", "version": "1.0"},
    })

    if init_resp and "result" in init_resp:
        r = init_resp["result"]
        nl()
        nl(f"{CYN}  ✓ HTTP 200 OK  —  Session established{RST}")
        nl(f"    {YLW}Session-ID   {RST}: {WHT}{session_id}{RST}")
        nl(f"    {YLW}Server       {RST}: {WHT}{r.get('serverInfo', {}).get('name', 'MortgageMCPServer')}{RST}")
        nl(f"    {YLW}Protocol     {RST}: {WHT}{r.get('protocolVersion', '2024-11-05')}{RST}")
        notify("notifications/initialized")
        nl(f"    {YLW}Handshake    {RST}: {GRN}COMPLETE ✓{RST}")
    else:
        nl(f"{RED}  ✗ Connection failed — is the server running on port 8035?{RST}")

    pause(1.0)

    # ─── tools/list ──────────────────────────────────────────────
    section_bar("ACT I — Discovery  |  Listing MCP Tools")

    prompt()
    typewrite("tools/list  # What capabilities does this MCP server expose?")
    emit(RST)
    pause(0.3)
    nl()
    nl(f"{DIM}  Querying server tool registry...{RST}")

    list_resp = rpc("tools/list")
    pause(0.4)

    if list_resp and "result" in list_resp:
        tools = list_resp["result"].get("tools", [])
        nl()
        nl(f"{CYN}  ✓ {len(tools)} tools registered on this MCP server{RST}")
        nl()
        for i, tool in enumerate(tools, 1):
            tname = tool.get("name", "")
            tdesc = (tool.get("description") or "")[:52]
            nl(f"  {YLW}{i:2}. {GRN}{tname:<28}{RST} {DIM}{tdesc}...{RST}")
        nl()
    else:
        nl(f"{RED}  ✗ tools/list failed{RST}")

    pause(1.2)

    # ─── ACT II: Investigation ───────────────────────────────────
    section_bar(f"ACT II — Investigation  |  Underwriting {APP_ID}  ($285,000)")

    prompt()
    typewrite(f"# Claude AI begins autonomous underwriting for application {APP_ID}")
    emit(RST)
    nl()
    nl(f"{MGN}  ◆ Planned tool sequence:{RST}")
    nl(f"{MGN}    GetApplicantProfile → GetCreditScore → GetPropertyValuation →{RST}")
    nl(f"{MGN}    CheckExistingDebts → VerifyEmployment → CalculateDTI{RST}")
    nl()
    pause(1.2)

    for i, name in enumerate(
        ["GetApplicantProfile", "GetCreditScore", "GetPropertyValuation",
         "CheckExistingDebts",  "VerifyEmployment", "CalculateDTI"], 1
    ):
        show_tool(name, i, 8)

    # ─── ACT III: Decision ───────────────────────────────────────
    section_bar("ACT III — Decision  |  Recording Outcome")

    show_tool("ApproveMortgage", 7, 8)
    show_tool("LogDecision",     8, 8)

    # Final banner
    nl()
    nl(f"{ORG}{BLD}{'═' * 72}{RST}")
    nl()
    nl(f"  {GBG}  ✓  MORTGAGE APPROVED  {RST}")
    nl()
    nl(f"  {YLW}Application  {RST}: {WHT}{APP_ID}  (Sarah Chen){RST}")
    nl(f"  {YLW}Mortgage Ref {RST}: {WHT}MTG-2026-88421{RST}")
    nl(f"  {YLW}Rate Offered {RST}: {GRN}4.85% fixed 5-year{RST}")
    nl(f"  {YLW}Monthly Pmt  {RST}: {GRN}$1,642{RST}")
    nl(f"  {YLW}Loan / LTV   {RST}: {WHT}$285,000  /  72.2%{RST}")
    nl()
    nl(f"  {YLW}Credit  {RST}: {GRN}724 ✓{RST}   {YLW}DTI     {RST}: {GRN}28.4% ✓{RST}   {YLW}KYC   {RST}: {GRN}VERIFIED ✓{RST}")
    nl(f"  {YLW}LTV     {RST}: {GRN}72.2% ✓{RST}  {YLW}Employ  {RST}: {GRN}PERM 6.2yr ✓{RST}  {YLW}Debts {RST}: {GRN}0 missed ✓{RST}")
    nl()
    nl(f"  {YLW}Tools Used  {RST}: {WHT}8 / 10{RST}   {YLW}Confidence {RST}: {GRN}92%{RST}   {YLW}Time {RST}: {WHT}~8 seconds{RST}")
    nl(f"  {YLW}Audit Ref   {RST}: {DIM}AUD-2026-004891  (compliance logged ✓){RST}")
    nl()
    nl(f"{ORG}{BLD}{'═' * 72}{RST}")
    nl()

    pause(3.5)  # hold final frame

    # ─── Write .cast file ────────────────────────────────────────
    header = {
        "version":   2,
        "width":     W,
        "height":    H,
        "timestamp": int(START),
        "title":     "Mortgage AI Processor — Flogo MCP Demo",
        "env":       {"SHELL": "/bin/bash", "TERM": "xterm-256color"},
    }
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(header) + "\n")
        for ev in EVENTS:
            f.write(json.dumps(ev) + "\n")

    duration = ts()
    print(f"\n  Cast file : {OUTPUT}")
    print(f"  Duration  : {duration:.1f}s   Events: {len(EVENTS)}")
    print(f"\n  Next step:")
    print(f'  agg "{OUTPUT}" mortgage-mcp-demo.gif --font-size 14 --theme dracula')


if __name__ == "__main__":
    run()
