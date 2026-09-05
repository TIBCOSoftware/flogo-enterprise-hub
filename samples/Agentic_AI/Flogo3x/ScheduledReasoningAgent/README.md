# Scheduled Reasoning Agent — Timer-Triggered LLM Pipeline with Report Generation & Delivery

## Overview

This sample demonstrates a **scheduled, autonomous reasoning agent** using the **TIBCO Flogo® 3 Agentic AI Connector**. A timer trigger fires every Monday at 8am, kicking off a multi-step LLM pipeline that fetches sales data from an MCP Server, generates a comprehensive analysis, converts it to a professional HTML report, saves it to disk, and emails it to stakeholders — all with no human interaction required.

A REST trigger is also provided for manual testing on demand.

| Pattern | Component | What It Shows |
|---|---|---|
| **Timer-triggered LLM** | `WeeklySalesAnalyzer` | Cron-scheduled LLM Client Activity — first Agentic AI sample using the Timer trigger |
| **Sequential LLM chaining** | `WeeklySalesAnalyzer` | Three chained LLM Client calls: data fetch, analysis, HTML formatting |
| **LLM Client + MCP** | `WeeklySalesAnalyzer` | LLM Client Activity calls MCP tools for data retrieval |
| **File Write** | `WeeklySalesAnalyzer` | Save generated HTML report to filesystem |
| **Send Mail** | `WeeklySalesAnalyzer` | Email HTML report with attachment to stakeholders |
| **MCP Server** | `SalesDataMCPServer` | Stateless MCP Server with 4 no-argument read-only tools |

---

## Real-World Scenario

**Persona**: Maria, VP of Sales, receives an automated performance report via email every Monday morning.

```
Monday 8:00 AM — Timer fires automatically

Step 1 — Data Fetch (LLMClient + MCP):
  [Calls get_weekly_sales_summary → SalesDataMCPServer]
  [Calls get_team_performance → SalesDataMCPServer]
  [Calls get_product_revenue → SalesDataMCPServer]
  [Calls get_regional_breakdown → SalesDataMCPServer]
  Combined data: revenue $2.85M, 1,823 orders, 8 reps...

Step 2 — Analysis (LLMClient, no MCP):
  [Reads Step 1 output, generates structured markdown report]
  Executive Summary, Key Metrics, Team Performance,
  Product Revenue, Regional Analysis, Recommendations, Risk Flags

Step 3 — HTML Formatting (LLMClient, no MCP):
  [Converts markdown → professional HTML with inline CSS]
  Styled tables, color-coded metrics (green/red/blue),
  print-friendly layout, responsive design

Step 4 — Save Report (File Write):
  [Saves HTML to ./reports/weekly-sales-report.html]

Step 5 — Email Delivery (Send Mail):
  [Sends HTML email with report attached to stakeholders]
  To: maria@company.com, sales-team@company.com
```

**No human trigger. No manual data pull. The timer fires, the LLM reasons over fresh data, and the report reaches stakeholders automatically.**

---

## Architecture

```
 Timer Trigger (cron: 0 0 8 ? * MON — every Monday at 8am)
      |
      v
 +--------------------------------------------------------------------------------+
 |  WeeklySalesAnalyzer                                                            |
 |                                                                                  |
 |  === scheduled_analysis_flow (timer-triggered) ================================ |
 |                                                                                  |
 |  Step 1: FetchSalesData         Step 2: AnalyzeAndReport                        |
 |  (LLMClient + MCP, temp 0.2)    (LLMClient, no MCP, temp 0.5)                  |
 |  +------------------------+     +---------------------------+                   |
 |  | Retrieve all sales data|---->| Generate markdown report  |------+            |
 |  | via 4 MCP tools        |     | with 7 analytical sections|      |            |
 |  +------------------------+     +---------------------------+      |            |
 |         |                                                          |            |
 |         +---------> SalesDataMCPServer (port 9620)                 |            |
 |                     +- get_weekly_sales_summary                    |            |
 |                     +- get_team_performance                        |            |
 |                     +- get_product_revenue                         |            |
 |                     +- get_regional_breakdown                      |            |
 |                                                                    v            |
 |  Step 3: FormatHTMLReport       Step 4: SaveReport                              |
 |  (LLMClient, temp 0.3)          (File Write)                                   |
 |  +---------------------------+  +----------------------------+                  |
 |  | Convert markdown to       |->| Save HTML to disk          |                  |
 |  | styled HTML with CSS      |  | ./reports/weekly-sales-    |                  |
 |  | tables, colors, layout    |  |   report.html              |                  |
 |  +---------------------------+  +----------------------------+                  |
 |                                        |                                        |
 |  Step 5: EmailReport                   |                                        |
 |  (Send Mail)                           |                                        |
 |  +---------------------------+         |                                        |
 |  | Send HTML email with      |---------+-----> LogReport                        |
 |  | report file attached      |                                                  |
 |  | via SMTP/TLS              |                                                  |
 |  +---------------------------+                                                  |
 |                                                                                  |
 |  === manual_analysis_flow (REST-triggered, port 9196) ========================= |
 |                                                                                  |
 |  Same 5-step pipeline, ends with ReturnReport (actreturn) instead of LogReport  |
 |  POST http://localhost:9196/run-analysis                                        |
 |  → { report, html_report, report_file, triggered_by }                          |
 +--------------------------------------------------------------------------------+

 +----------------------------------+
 | SalesDataMCPServer               |
 | Port 9620 — 4 tools (no args)   |
 |                                  |
 | get_weekly_sales_summary         |
 | get_team_performance             |
 | get_product_revenue              |
 | get_regional_breakdown           |
 +----------------------------------+
```

---

## Apps in This Sample

| Project Folder | Description |
|---|---|
| `WeeklySalesAnalyzer` | **Orchestrator** — Timer trigger (every Monday 8am) + REST trigger (port 9196). Five-step pipeline: fetch data via MCP, analyze, format HTML, save file, email. |
| `SalesDataMCPServer` | **MCP Server** — Port 9620. 4 no-argument read-only tools returning realistic mock sales data: weekly summary, team performance, product revenue, and regional breakdown. |

Each project folder contains an `app.fgmd` and is detected automatically by the TIBCO Flogo® 3 VS Code extension.

---

## Five-Step LLM Pipeline — How It Works

### Step 1 — FetchSalesData (LLMClient + MCP, temp 0.2)

Connects to the SalesDataMCPServer and calls all 4 tools to retrieve raw data. Low temperature (0.2) ensures deterministic tool calling.

### Step 2 — AnalyzeAndReport (LLMClient, no MCP, temp 0.5)

Receives Step 1's output via sequential chaining:

```
userPrompt: string.concat(
  "Here is the latest weekly sales data. Generate the Weekly Sales Performance Report.\n\nData:\n",
  coerce.toString($activity[FetchSalesData].response)
)
```

Higher temperature (0.5) allows the LLM to produce more natural analytical writing while staying grounded in the actual data. Generates a structured markdown report with 7 sections: Executive Summary, Key Metrics, Team Performance, Product Revenue, Regional Analysis, Recommendations, and Risk Flags.

### Step 3 — FormatHTMLReport (LLMClient, no MCP, temp 0.3)

Converts the markdown analysis into a professional, styled HTML document:

```
userPrompt: string.concat(
  "Convert the following sales analysis report into a professional HTML document:\n\n",
  coerce.toString($activity[AnalyzeAndReport].response)
)
```

The system prompt instructs the LLM to produce a complete HTML5 document with:
- Inline CSS (no external dependencies)
- Professional color scheme (navy headers, white content cards)
- Color-coded metrics (green for growth, red for decline, blue for neutral)
- Styled HTML tables with alternating row colors
- Print-friendly layout (suitable for "Save as PDF" in any browser)
- Responsive design

### Step 4 — SaveReport (File Write)

Writes the HTML report to the local filesystem:
- **Path**: `$property["Report.outputDir"]/weekly-sales-report.html` (default: `./reports/`)
- **Creates directories** if they don't exist
- **Overwrites** the previous report each week

### Step 5 — EmailReport (Send Mail)

Sends the report via SMTP:
- **HTML body**: The full styled HTML report rendered inline in the email
- **Attachment**: The HTML report content attached as `weekly-sales-report.html`
- **Content type**: `text/html`
- **Connection**: TLS (configurable to SSL or None)

### Why Three LLM Steps Instead of One?

Splitting data retrieval, analysis, and formatting into separate LLM calls provides:

- **Different temperatures per step** — 0.2 for factual tool calling, 0.5 for analytical reasoning, 0.3 for deterministic formatting
- **Different system prompts** — each step has a focused instruction set
- **Debuggability** — inspect each step's output independently
- **Reusability** — the same MCP data fetch could feed different analysis prompts; the same formatting step could convert any markdown report to HTML

---

## Tool Reference

### SalesDataMCPServer (port 9620 — 4 tools)

All tools take no arguments and return pre-populated mock data.

| Tool | Returns |
|---|---|
| `get_weekly_sales_summary` | Total revenue ($2.85M), total orders (1,823), average order value ($1,562), revenue change vs. prior week (+8.3%), day-by-day breakdown |
| `get_team_performance` | Per-rep revenue, deals closed, pipeline value, quota attainment %, week-over-week trend for 8 sales reps |
| `get_product_revenue` | Revenue by product category (Enterprise Platform License, Professional Services, Cloud Infrastructure, Support & Maintenance, Training & Certification, Add-on Modules), units sold, growth % |
| `get_regional_breakdown` | Revenue by region (North America, Europe, Asia Pacific, Latin America, Middle East & Africa), order count, average deal size, Q/Q growth trend |

---

## Prerequisites

- **TIBCO Flogo® 3.0.0 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic, Gemini, Ollama, or vLLM in the app properties)
- A REST client for testing: [Postman](https://www.postman.com/) or curl
- *Optional*: SMTP credentials (Gmail, Outlook, or any SMTP server) for email delivery

---

## Setup & Run

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `SalesDataMCPServer`, `WeeklySalesAnalyzer`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties) below) — LLM provider/API key, MCP server URL, schedule, ports.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal. Start `SalesDataMCPServer` first, then `WeeklySalesAnalyzer`.
5. Invoke and verify:

   **Start order** — Run `SalesDataMCPServer` first. It needs no API keys or special configuration — it uses mock data and no authentication, and starts the MCP Server on port **9620** at endpoint `/mcp`. Then run `WeeklySalesAnalyzer`, which starts the REST API on port **9196** and the timer schedule.

   **Test manually with curl**:
   ```bash
   curl -X POST http://localhost:9196/run-analysis \
     -H "Content-Type: application/json" \
     -d '{}'
   ```

   **Postman**: Create a POST request to `http://localhost:9196/run-analysis` with an empty JSON body `{}`.

   The response includes the full analysis report and delivery status:

   ```json
   {
     "report": "# WEEKLY SALES PERFORMANCE REPORT\n\n## Executive Summary\n...",
     "html_report": "<!DOCTYPE html><html>...",
     "report_file": "./reports/weekly-sales-report.html",
     "triggered_by": "manual"
   }
   ```

   **Verify the timer (optional)**: The timer is configured with cron expression `0 0 8 ? * MON` (every Monday at 8am). When the timer fires, the same pipeline runs and the report is logged, saved to `Report.outputDir`, and emailed. To test the timer sooner, temporarily change the cron expression to `0 */2 * ? * *` (every 2 minutes) and check the application logs.

---

## App Properties

Set these in each app's `.fgprops` file before running.

### WeeklySalesAnalyzer

| Property | Type | Default | What to Set |
|---|---|---|---|
| `LLMClient.dataFetchPrompt` | string | *(pre-filled)* | System prompt for Step 1 — instructs the LLM to call all 4 MCP tools and combine the data. Usually left as-is. |
| `LLMClient.analysisPrompt` | string | *(pre-filled)* | System prompt for Step 2 — instructs the LLM to produce a structured report with 7 sections. Edit to change report content. |
| `LLMClient.htmlFormatPrompt` | string | *(pre-filled)* | System prompt for Step 3 — instructs the LLM to convert markdown to styled HTML. Edit to change styling. |
| `LLMClient.openai.LLM_Provider` | string | `OpenAI` | LLM provider: OpenAI, Anthropic, Gemini, Ollama, vLLM. |
| `LLMClient.openai.LLM_Model` | string | `gpt-4o` | Model name (e.g., `gpt-4o`, `claude-sonnet-4-5`). |
| `LLMClient.APIKey` | string (password) | *(secret — empty)* | API key for the LLM provider. |
| `Report.outputDir` | string | `./reports` | Directory for saved HTML reports. |
| `Email.SMTP.Server` | string | `smtp.gmail.com` | SMTP server hostname. |
| `Email.SMTP.Port` | float64 | `587` | SMTP port. |
| `Email.SMTP.Username` | string | `test@gmail.com` | SMTP authentication username. |
| `Email.SMTP.Password` | string (password) | *(secret — empty)* | SMTP authentication password. |
| `Email.sender` | string | `test@gmail.com` | Sender email address. |
| `Email.recipients` | string | `test@gmail.com` | Comma-separated recipient email addresses. |

> **Gmail users**: Use an [App Password](https://support.google.com/accounts/answer/185833), not your regular password.

The MCP connection used by `WeeklySalesAnalyzer` (the **SalesDataMCPServer** connection) points at `http://localhost:9620/mcp` by default. If you change the MCP server's port, update this connection's server URL to match.

### SalesDataMCPServer

| Property | Type | Default | What to Set |
|---|---|---|---|
| `FlogoMcpServer.PORT` | string | `9620` | Port the MCP Server listens on (endpoint `/mcp`). Must match the server URL in `WeeklySalesAnalyzer`'s MCP connection. |

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Connect to a real sales database | Tool flows in `SalesDataMCPServer` | Replace `actreturn` with JDBC queries or REST calls to your CRM/ERP (Salesforce, SAP, HubSpot) |
| Change the schedule | Timer trigger settings | Modify the cron expression — e.g., `0 0 9 ? * MON-FRI` for daily at 9am |
| Customize the report format | `LLMClient.analysisPrompt` property | Edit the system prompt to add/remove sections, change formatting, or focus on specific KPIs |
| Change the HTML styling | `LLMClient.htmlFormatPrompt` property | Modify the system prompt to change colors, layout, add company logo, or change the design |
| Generate PDF instead of HTML | After FormatHTMLReport | Add a headless browser step or use a PDF generation API to convert HTML to PDF |
| Add Slack/Teams notification | After EmailReport | Add a REST Invoke activity to POST to a [Slack webhook](https://api.slack.com/messaging/webhooks) or [Teams webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook) |
| Use Anthropic Claude | App properties | Change `LLMClient.openai.LLM_Provider` to `Anthropic` and `LLMClient.openai.LLM_Model` to `claude-sonnet-4-5` |
| Use a local model | App properties + LLM connection | Change `LLMClient.openai.LLM_Provider` to `Ollama` and set the provider base URL in the LLM connection to your Ollama endpoint |
| Add tool arguments | MCP Server tool handlers | Add argument schemas (e.g., `date_range`, `team_id`) for parameterized queries |
| Skip email | Remove EmailReport activity | Delete EmailReport activity and its links if email delivery is not needed |

---

## Extending to Production

1. **Replace mock data** in each MCP Server tool flow with live API calls to your sales platform (Salesforce, HubSpot, SAP)
2. **Add error handling** — wrap the LLM calls in error branches to handle API failures gracefully and send alerts
3. **Add parameterized date ranges** — modify the MCP tools to accept `start_date` and `end_date` arguments for flexible reporting periods
4. **Create multiple report types** — duplicate the flow with different analysis prompts for monthly, quarterly, or executive board reports
5. **Add a comparison step** — store previous reports and add another LLM step that compares this week's data with last week's for trend analysis
6. **Archive reports** — use the File Write activity with timestamps in the filename to keep a history of all generated reports

See the [Insurance Claims Processor](../InsuranceClaimsProcessor/) sample for the LLM Client Activity chaining pattern with A2A integration, and the [Dynamic Semantic Tool Selection at Scale](../DynamicSemanticToolSelectionAtScale/) sample for scaling to 150+ tools with `filteredToolNames`.
