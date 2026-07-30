# BeautyCo — Demo 1 Trigger Script
# Fires scripted Claude prompts against the Beauty Intelligence Agent (MCP server on port 8036)
# Usage: .\demo-trigger.ps1 [-Scenario <1|2|3>] [-Interactive]

param(
    [ValidateSet(1,2,3,"all")]
    [string]$Scenario = "all",
    [switch]$Interactive,
    [string]$MCPEndpoint = "http://localhost:8036/mcp"
)

$ErrorActionPreference = "Stop"

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Header($msg) {
    Write-Host ""
    Write-Host ("═" * 72) -ForegroundColor DarkMagenta
    Write-Host "  $msg" -ForegroundColor Magenta
    Write-Host ("═" * 72) -ForegroundColor DarkMagenta
}
function Write-Step($msg)   { Write-Host "  ► $msg" -ForegroundColor Cyan }
function Write-Prompt($msg) { Write-Host "" ; Write-Host "  💬 PROMPT: $msg" -ForegroundColor Yellow }
function Write-Info($msg)   { Write-Host "     $msg" -ForegroundColor Gray }
function Write-OK($msg)     { Write-Host "  ✓  $msg" -ForegroundColor Green }

# ── Health check ───────────────────────────────────────────────────────────────
function Test-MCPHealth {
    Write-Step "Checking MCP server at $MCPEndpoint ..."
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:8091/health" -TimeoutSec 5 -UseBasicParsing
        Write-OK "Mock API (port 8091): OK"
    } catch {
        Write-Host "  ✗  Mock API (port 8091): NOT REACHABLE — start beauty-mock-apis.flogo first" -ForegroundColor Red
        exit 1
    }
    Write-OK "MCP server endpoint configured: $MCPEndpoint"
    Write-Info "Connect Claude Desktop to: $MCPEndpoint"
}

# ── Prompt display and pause ───────────────────────────────────────────────────
function Invoke-Prompt($title, $prompt) {
    Write-Prompt $prompt
    Write-Host ""
    Write-Host "  Paste this prompt into Claude Desktop (connected to $MCPEndpoint)" -ForegroundColor DarkCyan
    Write-Host ""

    if ($Interactive) {
        Write-Host "  Press ENTER when Claude has finished responding..." -ForegroundColor DarkYellow -NoNewline
        Read-Host | Out-Null
    } else {
        Write-Host "  (Running non-interactive — pausing 3s)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
}

# ── Scenario 1: Asha Patel — Diamond skincare buyer ───────────────────────────
function Run-Scenario1 {
    Write-Header "SCENARIO 1 — Asha Patel (DIAMOND) · Store 0847"
    Write-Info "Member M-7724-ASHA | 4,200 GlowRewards points | Heavy skincare buyer"
    Write-Info "Expected: Claude calls 6+ tools, generates personalized consultation,"
    Write-Info "          creates BONUS_POINTS offer, queues replenishment email"

    Invoke-Prompt "Asha — Full Consultation" `
        "A Diamond member Asha Patel (member ID M-7724-ASHA) has just walked into store 0847. She's browsing the skincare aisle. Please look up her full profile, purchase history, beauty profile, active campaigns, and check the loyalty account. Then give me a hyper-personalized consultation with 3 specific product recommendations and create a loyalty offer for her."

    Write-OK "Scenario 1 complete — check dashboard for tool chain and consultation record"
}

# ── Scenario 2: Cassandra Williams — Birthday WOW ─────────────────────────────
function Run-Scenario2 {
    Write-Header "SCENARIO 2 — Cassandra Williams (PLATINUM) · Birthday Month"
    Write-Info "Member M-1138-CASS | birth_month = current month"
    Write-Info "Expected: Claude autonomously identifies birthday, creates BIRTHDAY offer,"
    Write-Info "          WOW moment: offer created without being explicitly asked"

    Invoke-Prompt "Cassandra — In-Store Visit" `
        "Cassandra Williams (M-1138-CASS) is at store 0847. She's a Platinum member interested in makeup for a special occasion. Look up her profile and give her a consultation. Make it special."

    Write-OK "Scenario 2 complete — verify BIRTHDAY offer type in loyalty_offers table"
}

# ── Scenario 3: June Chen — New member, paraben allergy ───────────────────────
function Run-Scenario3 {
    Write-Header "SCENARIO 3 — June Chen (MEMBER) · New Member + Allergy"
    Write-Info "Member M-0042-JUNE | 90-day member | paraben allergy | 320 points"
    Write-Info "Expected: Claude detects allergy flag, avoids paraben products,"
    Write-Info "          encourages first redemption threshold (500 pts)"

    Invoke-Prompt "June — First In-Store Visit" `
        "June Chen (M-0042-JUNE) is a new member visiting store 1204 for the first time. She has sensitive skin and is looking for a basic skincare routine. Help her out — check her profile and suggest products. She mentioned she's conscious about ingredients."

    Write-OK "Scenario 3 complete — verify paraben-free recommendations and points nudge"
}

# ── Inventory stockout demo ────────────────────────────────────────────────────
function Run-StockoutDemo {
    Write-Header "BONUS — Inventory Stockout Detection"
    Write-Info "OLP-007-100ML has 0 stock in the mock API"
    Write-Info "Expected: Claude detects stockout, recommends alternative, triggers restock sequence"

    Invoke-Prompt "Inventory Check" `
        "Asha Patel (M-7724-ASHA) wants to repurchase her Olaplex No.7 Bonding Oil (SKU: OLP-007-100ML) from store 0847. Check if it's in stock and advise accordingly."

    Write-OK "Stockout demo complete"
}

# ── Main ───────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  BeautyCo Beauty Intelligence Agent — Demo Trigger" -ForegroundColor Magenta
Write-Host "  Demo 1 · TIBCO Flogo 2.26.2 MCP Server · Port 8036" -ForegroundColor Gray
Write-Host ""

Test-MCPHealth

switch ($Scenario) {
    "1"   { Run-Scenario1 }
    "2"   { Run-Scenario2 }
    "3"   { Run-Scenario3 }
    "all" {
        Run-Scenario1
        if ($Interactive) { Write-Host "`n  Press ENTER for Scenario 2..." -NoNewline; Read-Host | Out-Null }
        Run-Scenario2
        if ($Interactive) { Write-Host "`n  Press ENTER for Scenario 3..." -NoNewline; Read-Host | Out-Null }
        Run-Scenario3
        if ($Interactive) { Write-Host "`n  Press ENTER for Bonus stockout demo..." -NoNewline; Read-Host | Out-Null }
        Run-StockoutDemo
    }
}

Write-Host ""
Write-Header "Demo Complete"
Write-Info "Open dashboard: demo_retail\demo1\dashboard\index.html"
Write-Info "Check DB: psql -U postgres -d beauty_db -c 'SELECT * FROM consultations ORDER BY created_at DESC LIMIT 5;'"
Write-Host ""
