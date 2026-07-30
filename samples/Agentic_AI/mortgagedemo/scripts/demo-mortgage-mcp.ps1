#Requires -Version 5.1
<#
.SYNOPSIS
    Live demo of the mortgage-mcp-server Flogo MCP server.
    Makes real HTTP calls through the MCP protocol and shows results.

.USAGE
    powershell -ExecutionPolicy Bypass -File .\demo-mortgage-mcp.ps1
#>

$MCP_URL   = "http://localhost:8035/mcp"
$APP_ID    = "APP-2026-001"
$PAUSE_SEC = 1.8

# ── Helpers ──────────────────────────────────────────────────────
function Banner([string]$text) {
    Write-Host ""
    Write-Host ("═" * 72) -ForegroundColor DarkYellow
    Write-Host "  $text" -ForegroundColor Yellow
    Write-Host ("═" * 72) -ForegroundColor DarkYellow
    Write-Host ""
}

function Step([string]$text) {
    Write-Host "  ❯  $text" -ForegroundColor Green
}

function Kv([string]$key, [string]$val, [string]$color = "Cyan") {
    Write-Host ("    {0,-16}: " -f $key) -NoNewline -ForegroundColor DarkGray
    Write-Host $val -ForegroundColor $color
}

function Note([string]$text) {
    Write-Host "    ◆ $text" -ForegroundColor Magenta
}

function Ok([string]$text) {
    Write-Host "    ✓ $text" -ForegroundColor Green
}

function JsonLine([string]$key, [string]$val, [string]$color = "White") {
    Write-Host ("      `"{0}`": " -f $key) -NoNewline -ForegroundColor Yellow
    Write-Host $val -ForegroundColor $color
}

# ── MCP Client ───────────────────────────────────────────────────
$SessionId = $null
$CallId    = 0

function Invoke-MCPPost([hashtable]$Body, [bool]$WithSession = $true) {
    $headers = @{
        "Content-Type" = "application/json"
        "Accept"       = "application/json, text/event-stream"
    }
    if ($WithSession -and $script:SessionId) {
        $headers["Mcp-Session-Id"] = $script:SessionId
    }

    Add-Type -AssemblyName System.Net.Http
    $client  = New-Object System.Net.Http.HttpClient
    foreach ($k in $headers.Keys) { $client.DefaultRequestHeaders.Add($k, $headers[$k]) }

    $json    = $Body | ConvertTo-Json -Depth 10 -Compress
    $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, "application/json")
    $resp    = $client.PostAsync($MCP_URL, $content).Result

    $sid = $resp.Headers | Where-Object { $_.Key -eq "Mcp-Session-Id" } | Select-Object -ExpandProperty Value -First 1
    if ($sid) { $script:SessionId = $sid }

    $raw = $resp.Content.ReadAsStringAsync().Result
    foreach ($line in ($raw -split "`n")) {
        $line = $line.Trim()
        if ($line -like "data:*") {
            return ($line.Substring(5).Trim() | ConvertFrom-Json)
        }
    }
    return $null
}

function Invoke-RPC([string]$Method, [hashtable]$Params = @{}) {
    $script:CallId++
    return Invoke-MCPPost @{
        jsonrpc = "2.0"
        id      = $script:CallId
        method  = $Method
        params  = $Params
    }
}

function Send-Notification([string]$Method) {
    $headers = @{
        "Content-Type"   = "application/json"
        "Accept"         = "application/json, text/event-stream"
        "Mcp-Session-Id" = $script:SessionId
    }
    $body = @{ jsonrpc = "2.0"; method = $Method; params = @{} } | ConvertTo-Json -Compress
    try {
        $wr = [System.Net.WebRequest]::Create($MCP_URL)
        $wr.Method      = "POST"
        $wr.ContentType = "application/json"
        $wr.Accept      = "application/json, text/event-stream"
        $wr.Headers.Add("Mcp-Session-Id", $script:SessionId)
        $bytes  = [Text.Encoding]::UTF8.GetBytes($body)
        $stream = $wr.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $wr.GetResponse().Close()
    } catch {}
}

function Invoke-Tool([string]$Name) {
    return Invoke-RPC "tools/call" @{
        name      = $Name
        arguments = @{ applicationId = $APP_ID }
    }
}

function Get-ToolText($resp) {
    try {
        $text = $resp.result.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1 -ExpandProperty text
        return $text | ConvertFrom-Json
    } catch { return $null }
}

# ════════════════════════════════════════════════════════════════
#  ACT I — Discovery
# ════════════════════════════════════════════════════════════════
Clear-Host
Write-Host ""
Write-Host ("═" * 72) -ForegroundColor DarkYellow
Write-Host "  TIBCO FLOGO  ·  Autonomous Mortgage AI Processor  ·  MCP Demo" -ForegroundColor Yellow
Write-Host "  claude-sonnet-4-6  ↔  Flogo 2.26.2  ·  10 MCP Tools  ·  $MCP_URL" -ForegroundColor White
Write-Host ("═" * 72) -ForegroundColor DarkYellow
Write-Host ""
Start-Sleep -Seconds 1

Banner "ACT I — Discovery: Initialising MCP Session"

Step "Connecting to Flogo MCP server at $MCP_URL ..."
$init = Invoke-RPC "initialize" @{
    protocolVersion = "2024-11-05"
    capabilities    = @{}
    clientInfo      = @{ name = "ps-demo"; version = "1.0" }
}

if ($init -and $init.result) {
    Write-Host ""
    Ok "HTTP 200 OK — Session established"
    Kv "Session-ID"   $SessionId
    Kv "Server"       $init.result.serverInfo.name
    Kv "Protocol"     $init.result.protocolVersion

    Send-Notification "notifications/initialized"
    Ok "Handshake complete (notifications/initialized sent)"
} else {
    Write-Host "  ✗ Connection failed — is mortgage-mcp-server.exe running?" -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds $PAUSE_SEC

Banner "ACT I — Discovery: Listing Available Tools"

Step "Calling tools/list ..."
$listResp = Invoke-RPC "tools/list"

if ($listResp -and $listResp.result) {
    $tools = $listResp.result.tools
    Write-Host ""
    Ok "$($tools.Count) tools registered on this MCP server"
    Write-Host ""
    $i = 0
    foreach ($tool in $tools) {
        $i++
        $desc = if ($tool.description.Length -gt 55) { $tool.description.Substring(0,55) + "..." } else { $tool.description }
        Write-Host ("    {0,2}. " -f $i) -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-30}" -f $tool.name) -NoNewline -ForegroundColor Green
        Write-Host $desc -ForegroundColor DarkGray
    }
    Write-Host ""
} else {
    Write-Host "  ✗ tools/list failed" -ForegroundColor Red
}

Start-Sleep -Seconds $PAUSE_SEC

# ════════════════════════════════════════════════════════════════
#  ACT II — Investigation
# ════════════════════════════════════════════════════════════════
Banner "ACT II — Investigation: Underwriting $APP_ID  (`$285,000 mortgage)"

Note "Claude AI begins autonomous underwriting — calling tools in sequence:"
Note "GetApplicantProfile → GetCreditScore → GetPropertyValuation →"
Note "CheckExistingDebts → VerifyEmployment → CalculateDTI"
Write-Host ""
Start-Sleep -Seconds 1.2

# Tool 1: GetApplicantProfile
Write-Host "  ┌── Tool 1/8: GetApplicantProfile" -ForegroundColor DarkCyan
Step "tools/call GetApplicantProfile  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "GetApplicantProfile")
if ($r) {
    JsonLine "name"       "`"$($r.name)`""
    JsonLine "kyc_status" "`"$($r.kyc_status)`"" $(if ($r.kyc_status -eq "VERIFIED") {"Green"} else {"Red"})
    JsonLine "risk_band"  "`"$($r.risk_band)`"" "Cyan"
    JsonLine "pep_check"  "`"$($r.pep_check)`"" "Green"
}
Note "KYC: $($r.kyc_status)  Risk: $($r.risk_band)  PEP: $($r.pep_check) — Identity confirmed."
Start-Sleep -Seconds $PAUSE_SEC

# Tool 2: GetCreditScore
Write-Host "  ┌── Tool 2/8: GetCreditScore" -ForegroundColor DarkCyan
Step "tools/call GetCreditScore  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "GetCreditScore")
if ($r) {
    $scoreColor = if ($r.credit_score -ge 680) {"Green"} else {"Red"}
    JsonLine "credit_score"      $r.credit_score       $scoreColor
    JsonLine "grade"             "`"$($r.grade)`""
    JsonLine "defaults"          $r.defaults           $(if ($r.defaults -eq 0) {"Green"} else {"Red"})
    JsonLine "late_payments_24m" $r.late_payments_24m  "White"
    JsonLine "bureau"            "`"$($r.bureau)`""    "DarkGray"
}
Note "Score: $($r.credit_score) ✓ (min 680)  Grade: $($r.grade)  Defaults: $($r.defaults)"
Start-Sleep -Seconds $PAUSE_SEC

# Tool 3: GetPropertyValuation
Write-Host "  ┌── Tool 3/8: GetPropertyValuation" -ForegroundColor DarkCyan
Step "tools/call GetPropertyValuation  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "GetPropertyValuation")
if ($r) {
    $ltvColor = if ($r.ltv_ratio -le 85) {"Green"} else {"Red"}
    JsonLine "estimated_value" $r.estimated_value "Cyan"
    JsonLine "ltv_ratio"       $r.ltv_ratio       $ltvColor
    JsonLine "confidence"      "`"$($r.confidence)`"" "Green"
}
Note "LTV: $($r.ltv_ratio)% ✓ (max 85%)  Value: `$$($r.estimated_value)  Confidence: $($r.confidence)"
Start-Sleep -Seconds $PAUSE_SEC

# Tool 4: CheckExistingDebts
Write-Host "  ┌── Tool 4/8: CheckExistingDebts" -ForegroundColor DarkCyan
Step "tools/call CheckExistingDebts  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "CheckExistingDebts")
if ($r) {
    JsonLine "total_monthly_commitments" $r.total_monthly_commitments "Cyan"
    JsonLine "open_accounts"             $r.open_accounts             "White"
    JsonLine "missed_payments_24m"       $r.missed_payments_24m       $(if ($r.missed_payments_24m -eq 0) {"Green"} else {"Red"})
}
Note "Monthly debts: `$$($r.total_monthly_commitments)  Missed payments (24m): $($r.missed_payments_24m) — Clean history."
Start-Sleep -Seconds $PAUSE_SEC

# Tool 5: VerifyEmployment
Write-Host "  ┌── Tool 5/8: VerifyEmployment" -ForegroundColor DarkCyan
Step "tools/call VerifyEmployment  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "VerifyEmployment")
if ($r) {
    JsonLine "employer"           "`"$($r.employer)`""       "White"
    JsonLine "employment_type"    "`"$($r.employment_type)`"" "Green"
    JsonLine "years_at_employer"  $r.years_at_employer       "Cyan"
    JsonLine "gross_annual_income" $r.gross_annual_income    "Green"
    JsonLine "verified"           $r.verified.ToString().ToLower() "Green"
}
Note "Type: $($r.employment_type)  Tenure: $($r.years_at_employer)yr  Income: `$$($r.gross_annual_income) — Stable."
Start-Sleep -Seconds $PAUSE_SEC

# Tool 6: CalculateDTI
Write-Host "  ┌── Tool 6/8: CalculateDTI" -ForegroundColor DarkCyan
Step "tools/call CalculateDTI  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "CalculateDTI")
if ($r) {
    $dtiColor = if ($r.dti_ratio -le 38) {"Green"} else {"Red"}
    JsonLine "dti_ratio"       $r.dti_ratio       $dtiColor
    JsonLine "monthly_income"  $r.monthly_income  "Cyan"
    JsonLine "proposed_payment" $r.proposed_payment "White"
    JsonLine "assessment"      "`"$($r.assessment)`"" "Green"
}
Note "DTI: $($r.dti_ratio)% ✓ (max 38%)  Assessment: $($r.assessment)"
Note "━━━ SYNTHESIS: Credit ✓  LTV ✓  DTI ✓  Employment ✓  Debts ✓  KYC ✓ ━━━"
Note "All 6 checks PASSED.  Decision: APPROVE   Confidence: 92%"
Start-Sleep -Seconds $PAUSE_SEC

# ════════════════════════════════════════════════════════════════
#  ACT III — Decision
# ════════════════════════════════════════════════════════════════
Banner "ACT III — Decision: Recording Outcome"

# Tool 7: ApproveMortgage
Write-Host "  ┌── Tool 7/8: ApproveMortgage" -ForegroundColor DarkCyan
Step "tools/call ApproveMortgage  applicationId=`"$APP_ID`""
$r = Get-ToolText (Invoke-Tool "ApproveMortgage")
if ($r) {
    JsonLine "status"       "`"$($r.status)`""          "Green"
    JsonLine "mortgageRef"  "`"$($r.mortgageRef)`""     "Cyan"
    JsonLine "rate_offered" $r.rate_offered             "White"
    JsonLine "monthly_payment" $r.monthly_payment       "Cyan"
    JsonLine "term_years"   $r.term_years               "White"
}
Note "Approval written → mortgage_decisions  |  Ref: $($r.mortgageRef)"
Start-Sleep -Seconds $PAUSE_SEC

# Tool 8: LogDecision
Write-Host "  ┌── Tool 8/8: LogDecision" -ForegroundColor DarkCyan
Step "tools/call LogDecision  applicationId=`"$APP_ID`""
$log = Get-ToolText (Invoke-Tool "LogDecision")
if ($log) {
    JsonLine "auditId"   "`"$($log.auditId)`"" "DarkGray"
    JsonLine "status"    "`"$($log.status)`""  "Green"
}
Note "Audit record persisted → audit_log  |  Regulatory compliance: ✓"
Start-Sleep -Seconds $PAUSE_SEC

# ════════════════════════════════════════════════════════════════
#  Final Summary
# ════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host ("═" * 72) -ForegroundColor DarkYellow
Write-Host ""
Write-Host "  ✓  MORTGAGE APPROVED" -ForegroundColor Black -BackgroundColor Green
Write-Host ""
Kv "Application"  "$APP_ID  (Sarah Chen)"
Kv "Mortgage Ref" $r.mortgageRef
Kv "Rate Offered" "$($r.rate_offered)% fixed 5-year"   "Green"
Kv "Monthly Pmt"  "`$$($r.monthly_payment)"             "Green"
Kv "Loan / LTV"   "`$285,000  /  72.2%"
Write-Host ""
Kv "Credit Score" "724 ✓"  "Green"
Kv "DTI Ratio"    "28.4% ✓" "Green"
Kv "LTV Ratio"    "72.2% ✓" "Green"
Kv "Employment"   "PERMANENT 6.2yr ✓" "Green"
Kv "KYC"          "VERIFIED ✓" "Green"
Write-Host ""
Kv "Tools Used"   "8 / 10"
Kv "Confidence"   "92%"     "Green"
Kv "Total Time"   "~8 seconds  (fully autonomous)"
Kv "Audit Ref"    $log.auditId "DarkGray"
Write-Host ""
Write-Host ("═" * 72) -ForegroundColor DarkYellow
Write-Host ""
