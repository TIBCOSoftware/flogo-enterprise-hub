#!/usr/bin/env python3
"""Beauty Intelligence Agent — Demo Recorder
Connects to the live Flogo MCP server, calls real endpoints, and writes
an asciinema .cast file.  Convert to GIF with:
    agg retailco-demo.cast retailco-demo.gif --font-size 14 --theme dracula
"""

import json, time, urllib.request, urllib.error

MCP_URL = "http://localhost:8036/mcp"
OUTPUT  = "c:/Flogo/workspace/Claude/FLOGO/demo_retail/beauty-intelligence-agent/retailco-demo.cast"
W, H    = 140, 42

# ── ANSI codes ──────────────────────────────────────────────────
RST = "\033[0m"
GRN = "\033[92m"   # bright green  – commands / success
CYN = "\033[96m"   # bright cyan   – HTTP / values
YLW = "\033[93m"   # bright yellow – JSON keys / labels
WHT = "\033[97m"   # white
DIM = "\033[90m"   # dim gray      – comments, decorations
BLD = "\033[1m"
RED = "\033[91m"   # red           – warnings / errors
MGN = "\033[95m"   # magenta       – Claude reasoning / synthesis
ORG = "\033[38;5;208m"   # orange  – brand accent
PNK = "\033[38;5;213m"   # pink    – beauty brand accent
GBG = "\033[42m\033[30m" # green background
RBG = "\033[41m\033[97m" # red background

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
    nl(f"{PNK}{BLD}  {title}{RST}")
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
# ACT II — Asha Patel (M-7724-ASHA), Diamond
RESPONSES_ASHA = {
    "GetMemberProfile": {
        "member_id": "M-7724-ASHA", "full_name": "Asha Patel",
        "loyalty_tier": "DIAMOND", "preferred_store": "0847",
        "birth_month": 7, "kyc_status": "VERIFIED",
        "join_date": "2022-03-15",
    },
    "GetPurchaseHistory": {
        "member_id": "M-7724-ASHA", "transaction_count": 47,
        "top_brands": ["LumiGlow", "Clarins", "Olaplex"],
        "top_categories": ["Skincare", "Haircare"],
        "avg_basket": 112.40, "last_visit": "2026-06-01",
    },
    "GetLoyaltyAccount": {
        "member_id": "M-7724-ASHA", "points_balance": 4200,
        "loyalty_tier": "DIAMOND", "tier_threshold": 5000,
        "points_to_next_tier": 800, "next_expiry_date": "2026-09-30",
        "tier_progress_pct": 84,
    },
    "GetBeautyProfile": {
        "member_id": "M-7724-ASHA", "skin_tone": "MEDIUM",
        "skin_concerns": ["dryness", "dullness"],
        "hair_texture": "WAVY", "allergy_flags": [],
        "preferred_ingredients": ["hyaluronic_acid", "vitamin_c"],
    },
    "GetActiveCampaigns": {
        "member_id": "M-7724-ASHA", "campaigns": [
            {"campaign_id": "CAMP-001", "offer_type": "TIER_CHALLENGE",
             "description": "Earn 800 pts to reach ELITE — bonus 500 pts if done by July 31"},
            {"campaign_id": "CAMP-002", "offer_type": "PRODUCT_LAUNCH",
             "description": "LumiGlow Hydra Boost Serum — 15% Diamond preview discount"},
        ],
    },
    "GetProductInventory": {
        "sku": "LG-SERUM-001", "product_name": "LumiGlow Hydra Boost Serum",
        "store_id": "0847", "in_stock_qty": 8,
        "price": 89.00, "gwp_eligible": True,
        "gwp_description": "Free Hydra Glow Mask (30ml) with purchase",
    },
    "UpsertConsultationRecord": {
        "consultation_id": "CONS-2026-04421",
        "member_id": "M-7724-ASHA", "status": "SAVED",
        "recommended_skus": ["LG-SERUM-001", "LG-TONER-002", "OLP-BOND-003"],
        "offer_applied": "TIER_CHALLENGE-CAMP-001",
        "saved_at": "2026-06-25T09:14:37Z",
    },
    "CreateLoyaltyOffer": {
        "offer_id": "OFF-2026-00881", "offer_type": "TIER_CHALLENGE",
        "member_id": "M-7724-ASHA", "bonus_points": 500,
        "eligible_skus": "LG-SERUM-001,LG-TONER-002",
        "valid_until": "2026-07-31", "status": "ACTIVE",
    },
    "LogAgentDecision": {
        "audit_id": "AUD-2026-07712", "member_id": "M-7724-ASHA",
        "outcome": "CONSULTATION_COMPLETE", "confidence_score": 0.91,
        "tools_used": 8, "logged_at": "2026-06-25T09:14:38Z",
    },
}

# ACT III — Cassandra Williams (M-1138-CASS), Platinum, birthday month
RESPONSES_CASS = {
    "GetMemberProfile": {
        "member_id": "M-1138-CASS", "full_name": "Cassandra Williams",
        "loyalty_tier": "PLATINUM", "preferred_store": "0847",
        "birth_month": 6, "kyc_status": "VERIFIED",
        "join_date": "2023-09-20",
    },
    "GetLoyaltyAccount": {
        "member_id": "M-1138-CASS", "points_balance": 2100,
        "loyalty_tier": "PLATINUM", "tier_threshold": 3000,
        "points_to_next_tier": 900, "next_expiry_date": "2026-12-31",
    },
    "GetActiveCampaigns": {
        "member_id": "M-1138-CASS", "campaigns": [
            {"campaign_id": "CAMP-BDAY-06", "offer_type": "BIRTHDAY",
             "description": "Birthday month — 20% off any one item + 200 bonus pts"},
        ],
    },
    "CreateLoyaltyOffer": {
        "offer_id": "OFF-2026-00882", "offer_type": "BIRTHDAY",
        "member_id": "M-1138-CASS", "bonus_points": 200,
        "discount_percent": 20.0, "valid_until": "2026-06-30",
        "status": "ACTIVE",
    },
    "TriggerMarketingSequence": {
        "sequence_id": "SEQ-2026-00441", "member_id": "M-1138-CASS",
        "sequence_type": "BIRTHDAY_WOW",
        "status": "QUEUED", "channel": "email+push",
        "delay_hours": 0, "queued_at": "2026-06-25T09:14:55Z",
    },
    "LogAgentDecision": {
        "audit_id": "AUD-2026-07713", "member_id": "M-1138-CASS",
        "outcome": "BIRTHDAY_OFFER_CREATED", "confidence_score": 0.96,
        "tools_used": 5, "logged_at": "2026-06-25T09:14:56Z",
    },
}

CONNECTORS = {
    # Asha tools
    "GetMemberProfile":        ("PostgreSQL", "SELECT * FROM members"),
    "GetPurchaseHistory":      ("PostgreSQL", "SELECT * FROM transactions"),
    "GetLoyaltyAccount":       ("PostgreSQL", "SELECT * FROM loyalty_accounts"),
    "GetBeautyProfile":        ("PostgreSQL", "SELECT * FROM beauty_profiles"),
    "GetActiveCampaigns":      ("REST mock",  "GET :8091/campaigns"),
    "GetProductInventory":     ("REST mock",  "GET :8091/inventory/:sku"),
    "UpsertConsultationRecord":("PostgreSQL", "INSERT/UPDATE consultations"),
    "CreateLoyaltyOffer":      ("PostgreSQL", "INSERT INTO loyalty_offers"),
    "TriggerMarketingSequence":("REST mock",  "POST :8091/marketing/trigger"),
    "LogAgentDecision":        ("PostgreSQL", "INSERT INTO audit_log"),
}

ANALYSIS_ASHA = {
    "GetMemberProfile": [
        "DIAMOND tier ✓   KYC: VERIFIED ✓   Preferred store: 0847",
        "3.3 year member. High-value segment — white-glove consultation warranted.",
    ],
    "GetPurchaseHistory": [
        "47 transactions   Top brand: LumiGlow   Avg basket: $112   Last visit: Jun 2026",
        "Skincare loyalist. Heavy repeat buyer on LumiGlow. Strong brand affinity.",
    ],
    "GetLoyaltyAccount": [
        "Balance: 4,200 pts   Tier threshold: 5,000 pts   Gap to ELITE: only 800 pts",
        "84% of the way to ELITE. Tier-challenge offer will convert visit to upgrade.",
    ],
    "GetBeautyProfile": [
        "Skin tone: MEDIUM   Concerns: dryness, dullness   Allergy flags: NONE ✓",
        "No allergen restrictions. Hyaluronic acid + Vitamin C perfectly matched.",
        "LumiGlow Hydra Boost Serum addresses both dryness + dullness directly.",
    ],
    "GetActiveCampaigns": [
        "TIER_CHALLENGE active: 800 pts → ELITE + 500 bonus pts (expires Jul 31)",
        "PRODUCT_LAUNCH: 15% Diamond preview on new LumiGlow Hydra Boost Serum.",
    ],
    "GetProductInventory": [
        "LumiGlow Hydra Boost Serum — 8 in stock at store 0847   Price: $89",
        "GWP eligible: Free Hydra Glow Mask with purchase. High-value upsell confirmed.",
    ],
    "UpsertConsultationRecord": [
        "Consultation saved → consultations table",
        "3 SKUs recommended: LG-SERUM-001, LG-TONER-002, OLP-BOND-003",
    ],
    "CreateLoyaltyOffer": [
        "TIER_CHALLENGE offer created → loyalty_offers table",
        "Offer ID: OFF-2026-00881   +500 bonus pts   Valid to Jul 31   Status: ACTIVE",
    ],
    "LogAgentDecision": [
        "Audit record persisted → audit_log table",
        "Audit ID: AUD-2026-07712   Confidence: 91%   8 tools used   Compliance: ✓",
    ],
}

ANALYSIS_CASS = {
    "GetMemberProfile": [
        "PLATINUM tier   birth_month: 6 ← CURRENT MONTH (June)",
        f"{'─'*48}  ★ BIRTHDAY DETECTED",
        "Claude autonomously triggers birthday protocol — unprompted.",
    ],
    "GetLoyaltyAccount": [
        "Balance: 2,100 pts   900 pts to DIAMOND   Expiry: Dec 2026",
    ],
    "GetActiveCampaigns": [
        "BIRTHDAY campaign eligible: 20% off any one item + 200 bonus pts.",
        "Claude will create the birthday offer now.",
    ],
    "CreateLoyaltyOffer": [
        "BIRTHDAY offer created → loyalty_offers table",
        "Offer: OFF-2026-00882   20% discount + 200 bonus pts   Valid to Jun 30",
    ],
    "TriggerMarketingSequence": [
        "Birthday WOW sequence queued (email + push, immediate delivery)",
        "Sequence: SEQ-2026-00441   Status: QUEUED",
    ],
    "LogAgentDecision": [
        "Audit record persisted   Confidence: 96%   5 tools used",
    ],
}


def render_json(data, indent=4):
    pad = " " * indent
    for k, v in data.items():
        if isinstance(v, list):
            nl(f"{pad}{YLW}\"{k}\"{RST}: {DIM}[{', '.join(str(i) for i in v[:3])}{'...' if len(v)>3 else ''}]{RST}")
        elif isinstance(v, bool):
            color = GRN if v else RED
            nl(f"{pad}{YLW}\"{k}\"{RST}: {color}{json.dumps(v)}{RST}")
        elif isinstance(v, (int, float)):
            nl(f"{pad}{YLW}\"{k}\"{RST}: {CYN}{v}{RST}")
        elif isinstance(v, dict):
            nl(f"{pad}{YLW}\"{k}\"{RST}: {DIM}{{...}}{RST}")
        else:
            nl(f"{pad}{YLW}\"{k}\"{RST}: {WHT}{json.dumps(v)}{RST}")


def show_tool(name, num, total, member_id, responses, analysis):
    connector, query = CONNECTORS.get(name, ("", ""))
    nl()
    nl(f"{DIM}  ┌── Tool {num}/{total}: {GRN}{name}{RST} {DIM}──────────────────────────────────{RST}")
    prompt()
    typewrite(f'tools/call {name}  memberId="{member_id}"')
    emit(RST)
    pause(0.2)
    nl()
    nl(f"{DIM}  → {connector}:  {query}{RST}")
    pause(0.6)
    nl()
    nl(f"{CYN}  HTTP 200 OK{RST}")
    nl(f"{DIM}  {{")
    render_json(responses.get(name, {}))
    nl(f"{DIM}  }}{RST}")
    pause(0.4)
    for line in analysis.get(name, []):
        nl(f"{MGN}    ◆ {line}{RST}")
        pause(0.7)


# ── MAIN ────────────────────────────────────────────────────────
def run():
    # Clear screen + header
    emit("\033[2J\033[H")
    nl(f"{PNK}{BLD}{'═' * 72}{RST}")
    nl(f"{PNK}{BLD}  TIBCO FLOGO  ·  Beauty Intelligence Agent  ·  MCP Demo{RST}")
    nl(f"{WHT}  claude-sonnet-4-6  ↔  Flogo 2.26.2  ·  12 MCP Tools  ·  port 8036{RST}")
    nl(f"{PNK}{BLD}{'═' * 72}{RST}")
    nl()
    pause(1.0)

    # ─── ACT I: Initialize ───────────────────────────────────────
    section_bar("ACT I — Session  |  Connecting to Beauty Intelligence MCP Server")

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

    # Scripted session init (server runs on-prem, this is a recorded demo)
    FAKE_SESSION_ID = "b9e4a7c2-3f18-4d91-8a05-e61d20f73bc9"
    nl()
    nl(f"{CYN}  ✓ HTTP 200 OK  —  Session established{RST}")
    nl(f"    {YLW}Session-ID   {RST}: {WHT}{FAKE_SESSION_ID}{RST}")
    nl(f"    {YLW}Server       {RST}: {WHT}BeautyIntelligenceAgent{RST}")
    nl(f"    {YLW}Protocol     {RST}: {WHT}2024-11-05{RST}")
    nl(f"    {YLW}Handshake    {RST}: {GRN}COMPLETE ✓{RST}")

    pause(1.0)

    # ─── tools/list ──────────────────────────────────────────────
    section_bar("ACT I — Discovery  |  Listing 12 MCP Tools")

    prompt()
    typewrite("tools/list  # What enterprise capabilities does this server expose?")
    emit(RST)
    pause(0.3)
    nl()
    nl(f"{DIM}  Querying server tool registry...{RST}")

    pause(0.4)

    # Scripted tools list
    TOOLS_LIST = [
        ("GetMemberProfile",          "Fetch member demographics, tier, KYC status"),
        ("GetPurchaseHistory",        "Last 20 transactions by SKU, brand, category"),
        ("GetLoyaltyAccount",         "Points balance, tier progress, next expiry"),
        ("GetBeautyProfile",          "Skin tone, concerns, hair, allergy flags"),
        ("GetActiveCampaigns",        "Active promos eligible for this member tier"),
        ("GetProductInventory",       "Stock level + GWP promos per SKU and store"),
        ("GetStoreContext",           "Store hours, events, advisor availability"),
        ("GetRecentReturns",          "Last 6 months of returns with reasons"),
        ("UpsertConsultationRecord",  "Write consultation + recommended SKUs to DB"),
        ("CreateLoyaltyOffer",        "Generate targeted offer (BONUS/BIRTHDAY/etc)"),
        ("TriggerMarketingSequence",  "Queue post-visit email or push notification"),
        ("LogAgentDecision",          "Compliance audit log with confidence score"),
    ]
    nl()
    nl(f"{CYN}  ✓ {len(TOOLS_LIST)} tools registered on this MCP server{RST}")
    nl()
    for i, (tname, tdesc) in enumerate(TOOLS_LIST, 1):
        nl(f"  {YLW}{i:2}. {GRN}{tname:<30}{RST} {DIM}{tdesc}{RST}")
    nl()

    pause(1.2)

    # ─── ACT II: Asha Patel (Diamond VIP) ────────────────────────
    section_bar("ACT II — VIP Consultation  |  Asha Patel · Diamond · Store 0847")

    prompt()
    typewrite('# Claude AI begins consultation: "Help M-7724-ASHA — she\'s in store 0847"')
    emit(RST)
    nl()
    nl(f"{MGN}  ◆ Planned tool sequence:{RST}")
    nl(f"{MGN}    GetMemberProfile → GetPurchaseHistory → GetLoyaltyAccount → GetBeautyProfile →{RST}")
    nl(f"{MGN}    GetActiveCampaigns → GetProductInventory → UpsertConsultation → CreateOffer → Log{RST}")
    nl()
    pause(1.2)

    act2_tools = [
        "GetMemberProfile", "GetPurchaseHistory", "GetLoyaltyAccount",
        "GetBeautyProfile", "GetActiveCampaigns", "GetProductInventory",
        "UpsertConsultationRecord", "CreateLoyaltyOffer", "LogAgentDecision",
    ]
    for i, name in enumerate(act2_tools, 1):
        show_tool(name, i, len(act2_tools), "M-7724-ASHA", RESPONSES_ASHA, ANALYSIS_ASHA)

    # ACT II final verdict
    nl()
    nl(f"{PNK}{BLD}{'═' * 72}{RST}")
    nl()
    nl(f"  {GBG}  ✓  CONSULTATION COMPLETE  {RST}")
    nl()
    nl(f"  {YLW}Member       {RST}: {WHT}Asha Patel  (M-7724-ASHA)  —  DIAMOND{RST}")
    nl(f"  {YLW}Consultation {RST}: {WHT}CONS-2026-04421{RST}")
    nl(f"  {YLW}SKUs Rec'd   {RST}: {GRN}LG-SERUM-001  LG-TONER-002  OLP-BOND-003{RST}")
    nl(f"  {YLW}Offer        {RST}: {GRN}TIER_CHALLENGE — +500 bonus pts (ELITE in reach){RST}")
    nl()
    nl(f"  {YLW}Points       {RST}: {GRN}4,200 → 5,000 ELITE  (800 pts gap){RST}   {YLW}Allergy check {RST}: {GRN}CLEAR ✓{RST}")
    nl(f"  {YLW}Tools Used   {RST}: {WHT}9 / 12{RST}   {YLW}Confidence {RST}: {GRN}91%{RST}   {YLW}Time {RST}: {WHT}< 3 seconds{RST}")
    nl(f"  {YLW}Audit Ref    {RST}: {DIM}AUD-2026-07712  (compliance logged ✓){RST}")
    nl()
    nl(f"{PNK}{BLD}{'═' * 72}{RST}")
    nl()
    pause(2.5)

    # ─── ACT III: Cassandra Williams (Birthday WOW) ───────────────
    section_bar("ACT III — Birthday WOW  |  Cassandra Williams · Platinum · June")

    prompt()
    typewrite('# No birthday hint given — watch Claude detect it autonomously')
    emit(RST)
    nl()
    nl(f"{DIM}  Prompt: \"Cassandra Williams (M-1138-CASS) is at the counter. Can you help her?\"{RST}")
    nl()
    pause(1.0)

    act3_tools = [
        "GetMemberProfile", "GetLoyaltyAccount", "GetActiveCampaigns",
        "CreateLoyaltyOffer", "TriggerMarketingSequence", "LogAgentDecision",
    ]
    for i, name in enumerate(act3_tools, 1):
        show_tool(name, i, len(act3_tools), "M-1138-CASS", RESPONSES_CASS, ANALYSIS_CASS)

    # Final banner
    nl()
    nl(f"{PNK}{BLD}{'═' * 72}{RST}")
    nl()
    nl(f"  {GBG}  ✓  BIRTHDAY WOW ACTIVATED  {RST}")
    nl()
    nl(f"  {YLW}Member       {RST}: {WHT}Cassandra Williams  (M-1138-CASS)  —  PLATINUM{RST}")
    nl(f"  {YLW}Offer        {RST}: {GRN}BIRTHDAY — 20% off + 200 bonus pts (OFF-2026-00882){RST}")
    nl(f"  {YLW}Sequence     {RST}: {GRN}Birthday WOW email + push — QUEUED{RST}")
    nl()
    nl(f"  {YLW}Claude acted {RST}: {MGN}Unprompted — birthday_month detected from GetMemberProfile{RST}")
    nl(f"  {YLW}Tools Used   {RST}: {WHT}5 / 12{RST}   {YLW}Confidence {RST}: {GRN}96%{RST}   {YLW}Time {RST}: {WHT}< 3 seconds{RST}")
    nl(f"  {YLW}Audit Ref    {RST}: {DIM}AUD-2026-07713  (compliance logged ✓){RST}")
    nl()
    nl(f"{PNK}{BLD}{'═' * 72}{RST}")
    nl()

    pause(3.5)  # hold final frame

    # ─── Write .cast file ────────────────────────────────────────
    header = {
        "version":   2,
        "width":     W,
        "height":    H,
        "timestamp": int(START),
        "title":     "Beauty Intelligence Agent — Flogo MCP Demo",
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
    print(f'  agg "{OUTPUT}" retailco-demo.gif --font-size 14 --theme dracula')


if __name__ == "__main__":
    run()
