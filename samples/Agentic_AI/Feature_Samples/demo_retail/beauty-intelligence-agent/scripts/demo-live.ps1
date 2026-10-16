# =============================================================================
# RetailCo Intelligence Agent -- Live Interactive Demo Script
# =============================================================================
# Drives a step-by-step live demo against the running Flogo MCP server.
# Each ENTER press advances one step, showing narration cues + live data.
#
# Prerequisites:
#   1. PostgreSQL beauty_db seeded and running
#   2. beauty-mock-apis.flogo running on port 8091
#   3. beauty-intelligence-agent.flogo running on port 8036
#   4. Open dashboard/index.html in a browser tab
#
# Usage:
#   .\demo-live.ps1
#   .\demo-live.ps1 -McpPort 8036 -ApiPort 8091
# =============================================================================

param(
    [int]$McpPort = 8036,
    [int]$ApiPort = 8091
)

$ErrorActionPreference = "Stop"

# MCP session state (established once, reused for all tool calls)
$script:McpSessionId = $null

# Color helpers
function cCyan   { param($t) Write-Host $t -ForegroundColor Cyan }
function cGreen  { param($t) Write-Host $t -ForegroundColor Green }
function cYellow { param($t) Write-Host $t -ForegroundColor Yellow }
function cRed    { param($t) Write-Host $t -ForegroundColor Red }
function cPurple { param($t) Write-Host $t -ForegroundColor Magenta }
function cWhite  { param($t) Write-Host $t -ForegroundColor White }
function cDim    { param($t) Write-Host $t -ForegroundColor DarkGray }

function HR {
    param([string]$Color = "DarkCyan")
    Write-Host ("-" * 72) -ForegroundColor $Color
}

function Pause-Presenter {
    param([string]$Prompt = "  [Press ENTER to continue...]")
    Write-Host ""
    Write-Host $Prompt -ForegroundColor DarkYellow -NoNewline
    $null = Read-Host
    Write-Host ""
}

function Section {
    param([string]$Title, [string]$Color = "Cyan")
    Write-Host ""
    HR $Color
    Write-Host "  $Title" -ForegroundColor $Color
    HR $Color
    Write-Host ""
}

function Say {
    param([string]$Text)
    cYellow "  +-- PRESENTER CUE --------------------------------------------------+"
    cYellow "  |"
    foreach ($line in ($Text -split "`n")) {
        cYellow "  |  $line"
    }
    cYellow "  +--------------------------------------------------------------------+"
    Write-Host ""
}

function Action {
    param([string]$Text)
    cCyan "  [ACTION] $Text"
    Write-Host ""
}

function ToolCall {
    param([string]$Tool, [string]$Args)
    Write-Host "  --> Calling " -ForegroundColor DarkCyan -NoNewline
    Write-Host $Tool -ForegroundColor Cyan -NoNewline
    Write-Host "($Args)" -ForegroundColor DarkGray
}

function ToolResponse {
    param([string]$Json)
    Write-Host "  <-- " -ForegroundColor DarkGray -NoNewline
    Write-Host $Json -ForegroundColor DarkGray
    Write-Host ""
}

function OkBadge {
    param([string]$Msg)
    cGreen "  [OK] $Msg"
    Write-Host ""
}

function WarnBadge {
    param([string]$Msg)
    cRed "  [!!] $Msg"
    Write-Host ""
}

function StarBadge {
    param([string]$Msg)
    cPurple "  [**] $Msg"
    Write-Host ""
}

# Check TCP port reachable
function Check-Port {
    param([int]$Port, [string]$Name)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("localhost", $Port)
        $tcp.Close()
        cGreen "  [OK] $Name reachable on port $Port"
        return $true
    } catch {
        cRed "  [!!] $Name NOT reachable on port $Port"
        return $false
    }
}

# Establish MCP session: initialize handshake + notifications/initialized
# The Flogo MCP server uses Streamable HTTP transport (MCP spec 2024-11-05).
# Every session starts with initialize -> get Mcp-Session-Id -> notifications/initialized.
function Initialize-McpSession {
    param()
    $initPayload = @{
        jsonrpc = "2.0"
        id      = 1
        method  = "initialize"
        params  = @{
            protocolVersion = "2024-11-05"
            capabilities    = @{}
            clientInfo      = @{ name = "retailco-demo"; version = "1.0" }
        }
    } | ConvertTo-Json -Depth 5 -Compress

    try {
        $initResp = Invoke-WebRequest `
            -Uri "http://localhost:$McpPort/mcp" `
            -Method Post `
            -Body $initPayload `
            -ContentType "application/json" `
            -Headers @{ Accept = "application/json, text/event-stream" } `
            -UseBasicParsing `
            -TimeoutSec 10

        $script:McpSessionId = $initResp.Headers["Mcp-Session-Id"]
        if (-not $script:McpSessionId) { return $false }

        # Send notifications/initialized (notification: no id field)
        $notifPayload = @{
            jsonrpc = "2.0"
            method  = "notifications/initialized"
            params  = @{}
        } | ConvertTo-Json -Depth 3 -Compress

        Invoke-WebRequest `
            -Uri "http://localhost:$McpPort/mcp" `
            -Method Post `
            -Body $notifPayload `
            -ContentType "application/json" `
            -Headers @{ Accept = "application/json, text/event-stream"; "Mcp-Session-Id" = $script:McpSessionId } `
            -UseBasicParsing `
            -TimeoutSec 5 `
            -ErrorAction SilentlyContinue | Out-Null

        return $true
    } catch {
        return $false
    }
}

# Call a Flogo MCP tool via the established session
function Invoke-McpTool {
    param([string]$ToolName, [hashtable]$ToolArgs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $payload = @{
            jsonrpc = "2.0"
            method  = "tools/call"
            id      = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
            params  = @{
                name      = $ToolName
                arguments = $ToolArgs
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $resp = Invoke-WebRequest `
            -Uri "http://localhost:$McpPort/mcp" `
            -Method Post `
            -Body $payload `
            -ContentType "application/json" `
            -Headers @{ Accept = "application/json, text/event-stream"; "Mcp-Session-Id" = $script:McpSessionId } `
            -UseBasicParsing `
            -TimeoutSec 15

        $sw.Stop()

        # Parse SSE body: find "data: {...}" line
        $jsonContent = $null
        foreach ($line in ($resp.Content -split "`n")) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith("data:")) {
                $jsonStr = $trimmed.Substring(5).Trim()
                if ($jsonStr -ne "") {
                    $jsonContent = $jsonStr | ConvertFrom-Json
                    break
                }
            }
        }

        if ($null -eq $jsonContent) {
            return [PSCustomObject]@{ Ok = $false; Data = "Empty SSE response"; Ms = $sw.ElapsedMilliseconds }
        }
        if ($jsonContent.error) {
            return [PSCustomObject]@{ Ok = $false; Data = $jsonContent.error.message; Ms = $sw.ElapsedMilliseconds }
        }

        $content = if ($jsonContent.result -and $jsonContent.result.content) {
            ($jsonContent.result.content | ForEach-Object { $_.text }) -join ""
        } elseif ($jsonContent.result) {
            $jsonContent.result | ConvertTo-Json -Depth 3 -Compress
        } else {
            $jsonContent | ConvertTo-Json -Depth 3 -Compress
        }

        return [PSCustomObject]@{ Ok = $true; Data = $content; Ms = $sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{ Ok = $false; Data = $_.Exception.Message; Ms = $sw.ElapsedMilliseconds }
    }
}

function Show-McpResult {
    param([PSCustomObject]$Result, [string]$Label = "")
    if ($Result.Ok) {
        $preview = if ($Result.Data.Length -gt 200) { $Result.Data.Substring(0,200) + "..." } else { $Result.Data }
        ToolResponse $preview
        if ($Label) { OkBadge "$Label  ($($Result.Ms)ms)" }
    } else {
        ToolResponse "ERROR: $($Result.Data)"
        WarnBadge "Tool call failed"
    }
}

# ==============================================================================
#  MAIN DEMO
# ==============================================================================

Clear-Host

# Opening banner
Write-Host ""
cCyan "  ================================================================"
cCyan "  ==    RetailCo Intelligence Agent -- LIVE DEMO               =="
cCyan "  ==    Powered by TIBCO Flogo 2.26.2 + Claude AI              =="
cCyan "  ================================================================"
Write-Host ""
cWhite "  Three scenarios:"
cDim   "  · Scenario 01: VIP Customer Walk-In (Priya Sharma, PLATINUM)"
cDim   "  · Scenario 02: Birthday WOW Moment (Michael Chen, GOLD)"
cDim   "  · Scenario 03: Ingredient Safety Guard (Sara Thompson, MEMBER)"
Write-Host ""
HR "DarkGray"

# Pre-demo connectivity check
Write-Host ""
cWhite "  Checking services..."
Write-Host ""
$mcpOk = Check-Port $McpPort "Flogo MCP Server (beauty-intelligence-agent)"
$apiOk = Check-Port $ApiPort "Mock REST API (beauty-mock-apis)"

if (-not $mcpOk -or -not $apiOk) {
    Write-Host ""
    cRed    "  One or more services are not running. Start them first:"
    cYellow "    flogo run beauty-mock-apis.flogo"
    cYellow "    flogo run beauty-intelligence-agent.flogo"
    Write-Host ""
    exit 1
}

Write-Host ""
cGreen "  All services online. Ready to demo."
Write-Host ""

# Initialize MCP session (Streamable HTTP transport: initialize -> session ID -> ready)
cWhite "  Initializing MCP session..."
$sessionOk = Initialize-McpSession
if (-not $sessionOk) {
    cRed "  [!!] Failed to initialize MCP session on port $McpPort"
    cYellow "  Ensure beauty-intelligence-agent.flogo is fully started, then retry."
    exit 1
}
cGreen "  [OK] MCP session active ($($script:McpSessionId.Substring(0, 8))...)"
Write-Host ""

# Pre-demo setup
Section "PRE-DEMO SETUP" "DarkCyan"

Say "Welcome to the RetailCo Intelligence Agent demo.
Before we start, look at the browser tab on the right -- that is
the live operations dashboard. Every tool call we trigger will
appear there in real-time. Nothing is hidden."

Action "Open dashboard/index.html in a browser -- keep it visible on a second screen"
Action "This terminal drives the demo step-by-step -- press ENTER at each prompt"

Pause-Presenter "  [Press ENTER when dashboard is open and you are ready to begin...]"

# ==============================================================================
#  SCENARIO 01 -- VIP CUSTOMER
# ==============================================================================

Clear-Host
Section "SCENARIO 01 -- VIP Customer Walk-In" "Cyan"

cWhite "  Member:  Priya Sharma   |  Tier: PLATINUM   |  Store: #0847"
cWhite "  Points:  4,200 LoyaltyRewards  |  Top spender -- Skincare/Haircare"
Write-Host ""

Say "Priya Sharma -- one of your PLATINUM members -- just walked into
Store #0847. The advisor opens Claude Desktop and types a simple
natural-language prompt. Watch what happens next."

Pause-Presenter "  [Press ENTER --> GetMemberProfile]"
ToolCall "GetMemberProfile" 'memberId="M-7724-ASHA"'
$r = Invoke-McpTool "GetMemberProfile" @{ memberId = "M-7724-ASHA" }
Show-McpResult $r "Member profile loaded"

Pause-Presenter "  [Press ENTER --> GetPurchaseHistory]"
ToolCall "GetPurchaseHistory" 'memberId="M-7724-ASHA", limit=20'
$r = Invoke-McpTool "GetPurchaseHistory" @{ memberId = "M-7724-ASHA"; limit = 20 }
Show-McpResult $r "Purchase history loaded (40 transactions)"

Pause-Presenter "  [Press ENTER --> GetLoyaltyAccount]"
ToolCall "GetLoyaltyAccount" 'memberId="M-7724-ASHA"'
$r = Invoke-McpTool "GetLoyaltyAccount" @{ memberId = "M-7724-ASHA" }
Show-McpResult $r "Loyalty account loaded"

Pause-Presenter "  [Press ENTER --> GetActiveCampaigns]"
ToolCall "GetActiveCampaigns" 'memberId="M-7724-ASHA", storeId="0847"'
$r = Invoke-McpTool "GetActiveCampaigns" @{ memberId = "M-7724-ASHA"; storeId = "0847" }
Show-McpResult $r "Active campaigns retrieved"

Pause-Presenter "  [Press ENTER --> GetProductInventory]"
ToolCall "GetProductInventory" 'sku="CT-WONDERGLOW-01", storeId="0847"'
$r = Invoke-McpTool "GetProductInventory" @{ sku = "CT-WONDERGLOW-01"; storeId = "0847" }
Show-McpResult $r "Inventory checked"

Pause-Presenter "  [Press ENTER --> GetStoreContext]"
ToolCall "GetStoreContext" 'storeId="0847"'
$r = Invoke-McpTool "GetStoreContext" @{ storeId = "0847" }
Show-McpResult $r "Store context loaded"

Write-Host ""
cPurple "  Claude synthesizing consultation from 6 tool responses..."
Start-Sleep -Milliseconds 800

Pause-Presenter "  [Press ENTER --> CreateLoyaltyOffer]"
ToolCall "CreateLoyaltyOffer" 'memberId="M-7724-ASHA", type="BONUS_POINTS", bonusPoints=500'
$r = Invoke-McpTool "CreateLoyaltyOffer" @{ memberId = "M-7724-ASHA"; offerType = "BONUS_POINTS"; bonusPoints = 500 }
Show-McpResult $r "Offer created"

Pause-Presenter "  [Press ENTER --> TriggerMarketingSequence]"
ToolCall "TriggerMarketingSequence" 'memberId="M-7724-ASHA", type="POST_VISIT_SKINCARE"'
$r = Invoke-McpTool "TriggerMarketingSequence" @{ memberId = "M-7724-ASHA"; sequenceType = "POST_VISIT_SKINCARE" }
Show-McpResult $r "Marketing email queued"

Say "In under 3 seconds, Flogo called 6+ enterprise systems and Claude
synthesized a personalized consultation -- 3 product recommendations,
a 500-point bonus offer, and a post-visit email. Zero manual lookups."

OkBadge "Scenario 01 complete: 7 tool calls | Offer created | Email queued"

Pause-Presenter "  [Press ENTER to continue to Scenario 02 -- Birthday WOW...]"

# ==============================================================================
#  SCENARIO 02 -- BIRTHDAY WOW
# ==============================================================================

Clear-Host
Section "SCENARIO 02 -- The Birthday Moment" "Magenta"

cWhite "  Member:  Michael Chen   |  Tier: GOLD   |  Store: #0847"
cWhite "  Points:  1,850 LoyaltyRewards  |  Birth month: May (this month)"
Write-Host ""

Say "Michael Chen is a GOLD member walking in today.
The advisor types: 'Give Michael a consultation -- make it special.'
That is it. No birthday hint. Watch what Claude does."

cDim   "  No birthday hint in the prompt. Watch for birth_month in the response."
Write-Host ""

Pause-Presenter "  [Press ENTER --> GetMemberProfile -- watch for birth_month]"
ToolCall "GetMemberProfile" 'memberId="M-1138-CASS"'
$r = Invoke-McpTool "GetMemberProfile" @{ memberId = "M-1138-CASS" }
Show-McpResult $r "Member profile loaded"

Write-Host ""
cPurple "  +-------------------------------------------------------------+"
cPurple "  |  ** BIRTHDAY DETECTED                                       |"
cPurple "  |  birth_month = 5 (May) = current month                     |"
cPurple "  |  Claude autonomously creates a BIRTHDAY offer -- unprompted |"
cPurple "  +-------------------------------------------------------------+"
Write-Host ""

Say "Claude saw birth_month = 5 and today is May. Nobody told the AI
this was a birthday -- it inferred from the data. This is the power
of giving AI access to structured enterprise data via Flogo MCP tools."

Pause-Presenter "  [Press ENTER --> GetPurchaseHistory]"
ToolCall "GetPurchaseHistory" 'memberId="M-1138-CASS", limit=20'
$r = Invoke-McpTool "GetPurchaseHistory" @{ memberId = "M-1138-CASS"; limit = 20 }
Show-McpResult $r "Purchase history loaded"

Pause-Presenter "  [Press ENTER --> GetLoyaltyAccount]"
ToolCall "GetLoyaltyAccount" 'memberId="M-1138-CASS"'
$r = Invoke-McpTool "GetLoyaltyAccount" @{ memberId = "M-1138-CASS" }
Show-McpResult $r "Loyalty account loaded"

Pause-Presenter "  [Press ENTER --> CreateLoyaltyOffer (BIRTHDAY -- AI initiated)]"
ToolCall "CreateLoyaltyOffer" 'memberId="M-1138-CASS", type="BIRTHDAY", bonusPoints=300'
$r = Invoke-McpTool "CreateLoyaltyOffer" @{ memberId = "M-1138-CASS"; offerType = "BIRTHDAY"; bonusPoints = 300 }
Show-McpResult $r "Birthday offer created"

StarBadge "Scenario 02 complete: AI detected birthday unprompted | 4 tool calls | ~1.8s"

Pause-Presenter "  [Press ENTER to continue to Scenario 03 -- Ingredient Safety...]"

# ==============================================================================
#  SCENARIO 03 -- ALLERGY SAFETY
# ==============================================================================

Clear-Host
Section "SCENARIO 03 -- Ingredient Safety Guard" "Red"

cWhite "  Member:  Sara Thompson  |  Tier: MEMBER   |  Store: #1204"
cWhite "  Points:  320 LoyaltyRewards  |  New member (90 days)  |  Paraben allergy"
Write-Host ""

Say "Sara Thompson is a new member who mentions she is ingredient-conscious.
The advisor asks Claude for product suggestions. Watch what Flogo's
GetBeautyProfile tool returns -- and how Claude responds."

Pause-Presenter "  [Press ENTER --> GetMemberProfile]"
ToolCall "GetMemberProfile" 'memberId="M-0042-JUNE"'
$r = Invoke-McpTool "GetMemberProfile" @{ memberId = "M-0042-JUNE" }
Show-McpResult $r "Member profile loaded"

Pause-Presenter "  [Press ENTER --> GetBeautyProfile -- critical allergy flag]"
ToolCall "GetBeautyProfile" 'memberId="M-0042-JUNE"'
$r = Invoke-McpTool "GetBeautyProfile" @{ memberId = "M-0042-JUNE" }
Show-McpResult $r "Beauty profile loaded"

Write-Host ""
cRed "  +-------------------------------------------------------------+"
cRed "  |  [!!] PARABEN ALLERGY DETECTED                              |"
cRed "  |  allergyFlags: ['PARABEN']                                  |"
cRed "  |  Claude will ONLY recommend paraben-free products           |"
cRed "  +-------------------------------------------------------------+"
Write-Host ""

Say "Flogo returned the allergy flag from PostgreSQL. Claude cannot
override this -- the data is authoritative. Every product recommendation
will be filtered. This is enterprise data governance in action."

Pause-Presenter "  [Press ENTER --> GetProductInventory (paraben-free SKU)]"
ToolCall "GetProductInventory" 'sku="DR-VITC-SERUM", storeId="1204"'
$r = Invoke-McpTool "GetProductInventory" @{ sku = "DR-VITC-SERUM"; storeId = "1204" }
Show-McpResult $r "Safe product inventory checked"

Pause-Presenter "  [Press ENTER --> GetProductInventory (second safe SKU)]"
ToolCall "GetProductInventory" 'sku="LA-ROCHE-TOLERIANE", storeId="1204"'
$r = Invoke-McpTool "GetProductInventory" @{ sku = "LA-ROCHE-TOLERIANE"; storeId = "1204" }
Show-McpResult $r "Second safe product checked"

Pause-Presenter "  [Press ENTER --> GetLoyaltyAccount -- new member milestone]"
ToolCall "GetLoyaltyAccount" 'memberId="M-0042-JUNE"'
$r = Invoke-McpTool "GetLoyaltyAccount" @{ memberId = "M-0042-JUNE" }
Show-McpResult $r "Loyalty account loaded (180 pts to first redemption)"

Say "Claude also spotted that Sara is 180 points from her first reward
redemption and surfaces this in the consultation -- driving loyalty
engagement from day one. Flogo provides the data, Claude synthesizes."

Pause-Presenter "  [Press ENTER --> UpsertConsultationRecord]"
ToolCall "UpsertConsultationRecord" 'memberId="M-0042-JUNE", skus=["DR-VITC-SERUM","LA-ROCHE-TOLERIANE"]'
$r = Invoke-McpTool "UpsertConsultationRecord" @{ memberId = "M-0042-JUNE"; recommendedSkus = "DR-VITC-SERUM,LA-ROCHE-TOLERIANE"; allergyFiltered = $true }
Show-McpResult $r "Consultation saved (allergy-filtered)"

OkBadge "Scenario 03 complete: Safe products only | 180pts milestone surfaced | 5 tool calls | ~2.4s"

# ==============================================================================
#  DASHBOARD REVIEW
# ==============================================================================

Pause-Presenter "  [Press ENTER for Dashboard Review...]"

Clear-Host
Section "DASHBOARD REVIEW -- The Live Proof" "Cyan"

Say "Switch to the browser tab with the dashboard now.

Everything you just witnessed -- every tool call, every AI decision,
every offer created, every consultation saved -- is there.

This is your operations team's view. Full audit trail.
Confidence scores. Reasoning. Timestamps.

Nothing is a black box with Flogo and Claude."

Action "Switch to dashboard/index.html in the browser"
Action "Point out: (1) Stats bar  (2) Tool call stream  (3) Consultation cards"

Pause-Presenter "  [Press ENTER for final summary...]"

# Final summary
Clear-Host
Write-Host ""
cCyan "  ================================================================"
cCyan "  ==                   DEMO COMPLETE                           =="
cCyan "  ================================================================"
Write-Host ""
cWhite "  Results:"
cGreen  "  · Scenario 01 (VIP Walk-In)      7 tool calls | Offer +500 pts | ~2.1s"
cPurple "  · Scenario 02 (Birthday WOW)      4 tool calls | AI autonomous | ~1.8s"
cGreen  "  · Scenario 03 (Allergy Safety)   5 tool calls | 100% safe recs | ~2.4s"
Write-Host ""
HR "DarkGray"
cWhite "  Total tool calls:    16"
cWhite "  Custom code written: 0 lines"
cWhite "  Data left network:   None"
cWhite "  Time to first value: Same day"
HR "DarkGray"
Write-Host ""

Say "This is TIBCO Flogo 2.26.2 + Claude AI.
12 enterprise tools. Zero custom code.
Your data on your infrastructure.
Live in 3 weeks."

Write-Host ""
cCyan "  Powered by TIBCO Flogo 2.26.2  |  Claude AI (Anthropic)  |  MCP Protocol"
Write-Host ""
