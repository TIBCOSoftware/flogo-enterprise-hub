# LLM Client Dynamic Auth — Authenticated MCP and A2A Servers Injected at Runtime

*Use case: a Pharmacovigilance Safety Intake Advisor.*

## Overview

**Nothing in this sample is configured through a connection resource.** The LLM provider, both backend URLs, both auth types and both bearer tokens are activity **inputs** resolved from App Properties — so the same flow runs against dev, staging and production, and rotating a credential never touches a flow.

It is the companion to the [IT Help Desk Advisor](../LLMClient-Dynamic-Config-And-Memory/), which shows dynamic MCP/A2A config with `authType: "None"`. This sample answers the question that one leaves open: *what does the same pattern look like when the backends actually require credentials?*

Three things are injected into a single **LLM Client Activity** at runtime:

1. **The LLM provider** — `llmConfiguration` supplies provider, model and API key as a mapping. Swap OpenAI for Anthropic, Gemini, Ollama or vLLM by editing properties; no LLM connection resource exists in the app.
2. **A token-protected MCP Server** — `authType: "Token"` on the client, `API Key` bearer validation on the server. Read-only safety reference data.
3. **A token-protected A2A Server** — `authType: "Static Token"` on both the client and the agent trigger. Guarded writes to the safety database and health-authority gateways.

Plus a **Memory Conversation Store** so a drug safety associate can work one case across many turns without re-stating it.

Three independent Flogo applications work together:

- **DrugSafetyAdvisor.flogo** — A **WebSocket server** whose LLM Client Activity triages an adverse event and carries a bearer token to each backend.
- **SafetySignalMCPServer.flogo** — An **authenticated MCP Server** exposing product labeling, prior case history, and expectedness checks.
- **RegulatoryReportingA2A.flogo** — An **authenticated A2A Server** that opens Individual Case Safety Reports (ICSRs) and files E2B(R3) expedited reports.

| Pattern | Component | What It Shows |
|---|---|---|
| **Dynamic LLM configuration** | `DrugSafetyAdvisor.flogo` | `llmConfiguration` mapping supplies `provider`, `model`, `apiKey` and `temperature` from App Properties — the app has **no LLM provider connection resource** |
| **Authenticated MCP (client)** | `DrugSafetyAdvisor.flogo` | `mcpServerConfigs` with `authType: "Token"` + property-resolved `authToken` |
| **Authenticated MCP (server)** | `SafetySignalMCPServer.flogo` | MCP Server trigger with `authType: "API Key"` + `authToken`, per-tool `scope` values |
| **Authenticated A2A (client)** | `DrugSafetyAdvisor.flogo` | `a2aServerConfigs` with `authType: "Static Token"` + property-resolved `authToken` |
| **Authenticated A2A (server)** | `RegulatoryReportingA2A.flogo` | Agent Trigger with `agentAuthMode: "Static Token"` + `agentToken` |
| **Memory Conversation Store** | `DrugSafetyAdvisor.flogo` | `conversationStoreType: "Memory"` + `memoryMaxSize: 24` + `conversationId` from query param |
| **Dynamic backend config** | `DrugSafetyAdvisor.flogo` | Every field of both server configs — name, URL, auth type and token — resolved from App Properties |

### How This Differs from the IT Help Desk Advisor Sample

| Aspect | IT Help Desk Advisor | This Sample |
|---|---|---|
| MCP `authType` (client) | `None` | `Token` |
| MCP `authType` (server trigger) | `None` | `API Key` (switchable to `JWT Token`) |
| A2A `authType` (client) | `None` | `Static Token` |
| A2A `agentAuthMode` (server trigger) | `None` | `Static Token` |
| Per-tool MCP `scope` | not set | `product:read` / `cases:read` / `labeling:read` |
| Vertical | IT Operations | Pharmaceutical & Life Sciences |
| Consequence of a wrong answer | A reopened ticket | A missed regulatory deadline |

---

## Real-World Scenario

**Persona**: Dana, a drug safety associate at Northwind Therapeutics, receives a phone call from an investigator site running the Phase III study **VEL-301** for **Velcaridine** (IMP-4471), an anti-IL-6R monoclonal antibody for rheumatoid arthritis. A subject has been hospitalised with liver failure.

Dana has to answer one question fast: **is this a SUSAR?** Under ICH E2A, a Suspected Unexpected Serious Adverse Reaction is a case that is *serious*, *unexpected* against the Reference Safety Information, and has *at least a reasonable possibility of causal relationship*. If it is, the sponsor has **15 calendar days** to file with health authorities — **7 days** if the event is fatal or life-threatening. The clock starts the moment the sponsor receives the four minimum criteria.

```
Connect via WebSocket:
  ws://localhost:9220/drugsafety?caseId=VEL-301-0442

Turn 1 — Dana reports the call:
  > Site 0044 just called. Subject VEL-301-0442 on IMP-4471 was hospitalised
  > yesterday with acute hepatic failure. Investigator says probable causality.

  System:
    [Calls lookup_investigational_product → SafetySignalMCPServer, Bearer token]
    [Calls check_label_expectedness    → SafetySignalMCPServer, Bearer token]

    "Confirmed: IMP-4471 (Velcaridine), protocol VEL-301, Phase III.
     The Reference Safety Information in force is Investigator's Brochure v6.0
     (effective 2026-02-01).

     Hepatic failure is UNLISTED. Section 6.3 lists only asymptomatic
     transaminase elevation, which is not of the same nature or severity.

     Triage so far:
       Serious       — yes, hospitalisation
       Unexpected    — yes, unlisted against IB v6.0
       Causality     — probable, per the investigator

     That is all three ICH E2A criteria, so this is a SUSAR on a 15-day clock.
     Before I open the case, do you have all four minimum criteria — an
     identifiable patient, an identifiable reporter, the suspect product,
     and the suspect reaction?"

Turn 2 — Dana confirms (same caseId = conversation memory kicks in):
  > Yes, all four. Anything else we already know about hepatic events on this product?

  System (remembers the product and term — does NOT re-ask):
    [Calls search_case_history → SafetySignalMCPServer, Bearer token]

    "Three prior hepatic cases across 1,240 exposed subjects: ICSR-2026-00874 (DE),
     ICSR-2026-01133 (US), and ICSR-2026-01402 (JP, life-threatening). All three
     had positive dechallenge. Observed rate 2.42 per 1,000 against a background
     rate of 0.14 — roughly 17-fold.

     A signal is already open: SIG-2026-0033, with the Hepatology Signal Team
     since 2026-04-11. This case should go to them in parallel with the
     expedited report.

     Shall I open the ICSR now? I'll record: IMP-4471, hepatic failure,
     serious (hospitalisation), unexpected, probable causality,
     subject reference VEL-301-0442."

Turn 3 — Dana approves the write:
  > Yes, open it and file with FDA.

  System (remembers all triage facts from Turns 1 and 2):
    [Calls create_safety_case        → RegulatoryReportingA2A, Static Token]
    [Calls submit_expedited_report   → RegulatoryReportingA2A, Static Token]

    "Case ICSR-2026-01588 created and classified as a SUSAR.
     Clock started 2026-09-25, due 2026-10-10 (15 calendar days).
     Assigned to Dr. Priya Raman, Medical Safety Physician.
     Signal team notified under SIG-2026-0033.

     Expedited E2B(R3) report filed with FDA — submission SUB-2026-FDA-004417,
     acknowledgement AA, authority case FAERS-29104778. EudraVigilance
     transmission is queued for the next gateway window.

     Submitted 15 days ahead of the deadline."
```

**Same `caseId` across all turns.** The advisor never re-asks the product, the reaction term, or the causality assessment — and it never writes to the safety database without Dana's explicit confirmation.

---

## Architecture

```
 Drug Safety Associate (WebSocket client — Chatbot, Postman, websocat)
      |
      |  ws://localhost:9220/drugsafety?caseId=VEL-301-0442
      v
 +--------------------------------------------------------------------+
 |  DrugSafetyAdvisor.flogo (port 9220)                               |
 |                                                                     |
 |  WebSocket Trigger --> SafetyIntakeFlow                             |
 |                                                                     |
 |  +----------------------------------------------------------+      |
 |  | SafetyIntakeLLMClient (LLM Client Activity)              |      |
 |  |                                                          |      |
 |  |  conversationStoreType = "Memory"                        |      |
 |  |  memoryMaxSize         = 24                              |      |
 |  |  conversationId        = caseId from query param         |      |
 |  |                                                          |      |
 |  |  mcpServerConfigs (input-level)                          |      |
 |  |    serverUrl : App Property                              |      |
 |  |    authType  : "Token"          <-- AUTH ENABLED         |------+--> SafetySignalMCPServer.flogo
 |  |    authToken : App Property                              |      |    (MCP on 9221/mcp, authType: API Key)
 |  |                      |                                   |      |    +- lookup_investigational_product  [product:read]
 |  |         Authorization: Bearer pv-mcp-...                 |      |    +- search_case_history             [cases:read]
 |  |                                                          |      |    +- check_label_expectedness        [labeling:read]
 |  |  a2aServerConfigs (input-level)                          |      |
 |  |    serverUrl : App Property                              |      |
 |  |    authType  : "Static Token"   <-- AUTH ENABLED         |------+--> RegulatoryReportingA2A.flogo
 |  |    authToken : App Property                              |      |    (A2A on 9222, agentAuthMode: Static Token)
 |  |                      |                                   |      |    +- create_safety_case
 |  |         Authorization: Bearer pv-a2a-...                 |      |    +- submit_expedited_report
 |  |                                                          |      |    +- get_case_status
 |  |  LLM: OpenAI (dynamic config, temperature 0)             |      |
 |  +-----------------------------+----------------------------+      |
 |                                |                                    |
 |                  $activity[SafetyIntakeLLMClient].response          |
 |                                |                                    |
 |  +-----------------------------v----------------------------+      |
 |  | Log --> WebSocket Write Data                             |      |
 |  +----------------------------------------------------------+      |
 +--------------------------------------------------------------------+
```

---

## Files in This Sample

| File | Description |
|---|---|
| `DrugSafetyAdvisor.flogo` | **Orchestrator** — WebSocket server on port 9220. LLM Client Activity with a Memory Conversation Store (`memoryMaxSize: 24`) and `mcpServerConfigs` / `a2aServerConfigs` injected as inputs, both carrying bearer tokens from App Properties. |
| `SafetySignalMCPServer.flogo` | **Authenticated MCP Server** — Stateless MCP Server on port 9221 with `authType: "API Key"`. Three read-only tools with per-tool `scope` values, backed by mock pharmacovigilance data. |
| `RegulatoryReportingA2A.flogo` | **Authenticated A2A Server** — Regulatory reporting agent on port 9222 with `agentAuthMode: "Static Token"`. Three write/lookup tools with mock ICSR and E2B(R3) submission data. |

---

## Dynamic LLM Provider Configuration

The LLM Client Activity can take its provider either from a **connection resource** (designed once, fixed at build time) or from the **`llmConfiguration` input** (resolved per execution). This sample uses the input form exclusively — open the app and you will find no LLM provider connection at all.

```json
{
  "input": {
    "llmConfiguration": {
      "mapping": {
        "provider": "=$property[\"LLMClient.LLM_Provider\"]",
        "apiKey": "=$property[\"LLMClient.API_Key\"]",
        "model": "=$property[\"LLMClient.LLM_Model\"]",
        "providerBaseUrl": "",
        "temperature": 0
      }
    }
  }
}
```

| Field | Source | Notes |
|---|---|---|
| `provider` | `LLMClient.LLM_Provider` | `OpenAI`, `Anthropic`, `Gemini`, `Ollama`, `vLLM`, … |
| `apiKey` | `LLMClient.API_Key` | Store as an encrypted `SECRET:...` property outside of local development |
| `model` | `LLMClient.LLM_Model` | Defaults to `gpt-5-nano` |
| `providerBaseUrl` | literal `""` | Set this for self-hosted or gateway endpoints; leave empty for the provider default |
| `temperature` | literal `0` | Zero on purpose — regulatory triage rewards consistency over creativity |

**Why it matters here.** Case narratives can contain patient data, and which model is allowed to see them is a deployment decision, not a design decision. Switching this app from OpenAI to an on-premises Ollama endpoint is two property edits (`LLM_Provider`, `providerBaseUrl`) against an unchanged flow — the same lever that lets one artifact promote from dev to validated production.

`RegulatoryReportingA2A.flogo` deliberately makes the **opposite** choice: its Agent Trigger uses an `#llmprovider` connection resource. Between the two apps you can see both styles side by side.

---

## Authentication — How It Works

Auth in this sample is **symmetric**: each server validates a bearer token, and the LLM Client Activity presents that token as part of the config it injects at runtime. Because both halves read from App Properties, rotating a credential is a property change on two apps — no flow edits.

### The Two Hops

| Hop | Client side (`DrugSafetyAdvisor`) | Server side | HTTP header sent |
|---|---|---|---|
| **MCP** | `mcpServerConfigs[].authType = "Token"` | `authType = "API Key"` on the MCP Server trigger | `Authorization: Bearer <FlogoMcpServer.AUTH_TOKEN>` |
| **A2A** | `a2aServerConfigs[].authType = "Static Token"` | `agentAuthMode = "Static Token"` on the Agent trigger | `Authorization: Bearer <A2A.AuthToken>` |

> **Why the names differ.** The two connectors use different vocabulary for the same bearer-token exchange. On the LLM Client the MCP option is called **`Token`**; the MCP Server trigger calls the matching mode **`API Key`**. For A2A both sides agree on **`Static Token`**. These are the only non-`None` values the LLM Client's injected configs accept — the full enums are `["None", "Token"]` for MCP and `["None", "Static Token"]` for A2A.

### MCP Server — `API Key`

```json
{
  "settings": {
    "serverName": "SafetySignalMCPServer",
    "serverPort": "=$property[\"FlogoMcpServer.PORT\"]",
    "serverEndpointPath": "/mcp",
    "authType": "=$property[\"FlogoMcpServer.AUTH_TYPE\"]",
    "authToken": "=$property[\"FlogoMcpServer.AUTH_TOKEN\"]"
  }
}
```

The server compares the `Authorization: Bearer <token>` header against `authToken`. A missing or wrong token gets **HTTP 401** before any flow runs.

### LLM Client — injecting the MCP token

```json
{
  "input": {
    "mcpServerConfigs": {
      "mapping": [
        {
          "name": "=$property[\"LLMClient.MCP.Safety.Server_Name\"]",
          "serverType": "http",
          "serverUrl": "=$property[\"LLMClient.MCP.Safety.Server_URL\"]",
          "httpTransportType": "streamable",
          "authType": "=$property[\"LLMClient.MCP.Safety.Auth_Type\"]",
          "authToken": "=$property[\"LLMClient.MCP.Safety.Auth_Token\"]"
        }
      ]
    }
  }
}
```

### A2A Server — `Static Token`

```json
{
  "settings": {
    "agentType": "A2A Server",
    "agentPort": "=$property[\"A2A.port\"]",
    "agentUrl": "=$property[\"A2A.AgentUrl\"]",
    "agentAuthMode": "=$property[\"A2A.AuthMode\"]",
    "agentToken": "=$property[\"A2A.AuthToken\"]"
  }
}
```

### LLM Client — injecting the A2A token

```json
{
  "input": {
    "a2aServerConfigs": {
      "mapping": [
        {
          "name": "=$property[\"LLMClient.A2A.Regulatory.Server_Name\"]",
          "serverUrl": "=$property[\"LLMClient.A2A.Regulatory.Server_URL\"]",
          "authType": "=$property[\"LLMClient.A2A.Regulatory.Auth_Type\"]",
          "authToken": "=$property[\"LLMClient.A2A.Regulatory.Auth_Token\"]"
        }
      ]
    }
  }
}
```

### Upgrading the MCP Server to JWT with Scopes

Each MCP tool already carries a `scope` value, so scope enforcement is one property away:

| Tool | Scope |
|---|---|
| `lookup_investigational_product` | `product:read` |
| `search_case_history` | `cases:read` |
| `check_label_expectedness` | `labeling:read` |

In `API Key` mode these `scope` values are **ignored** — any caller with the right token reaches every tool. Set `FlogoMcpServer.AUTH_TYPE` to `JWT Token`, put the HMAC signing secret in `FlogoMcpServer.AUTH_TOKEN`, and put a signed JWT carrying the required scopes in `LLMClient.MCP.Safety.Auth_Token`; the server then rejects per tool and populates `tokenInfo` for the flows. See [Patient Records with Scoped Access (JWT)](../../Model_Context_Protocol\(MCP\)/MCP_JWT_Scope_Access_Control/) for a worked example, and the [MCP Server Security Guide](../../Model_Context_Protocol\(MCP\)/MCP_Server_Authentication/) for all four auth types.

> **Tokens in this sample are plaintext so it runs as shipped.** In any real deployment store them as encrypted app properties (`SECRET:...`) or inject them from your platform's secret store, and put TLS on both servers — a bearer token on plain HTTP is only as private as the network.

---

## Memory Conversation Store

`conversationStoreType: "Memory"` with `memoryMaxSize: 24` gives the LLM Client multi-turn memory keyed on `conversationId`, which this sample maps from the `caseId` query parameter:

```json
{
  "settings": { "conversationStoreType": "Memory", "memoryMaxSize": 24 },
  "input":    { "conversationId": "=coerce.toString($flow.queryParams.caseId)" }
}
```

One case per `caseId` means concurrent intakes never bleed into each other:

```
ws://localhost:9220/drugsafety?caseId=VEL-301-0442   # hepatic failure
ws://localhost:9220/drugsafety?caseId=VEL-301-0518   # independent case
```

24 messages is roughly a dozen turns — enough for a full triage plus follow-up questions. Raise it for longer case discussions, at the cost of prompt length on every call.

> Memory is **in-process and not durable**: restarting the app clears every conversation. That is fine for a triage aid where the ICSR itself is the system of record, but if you need an auditable transcript under 21 CFR Part 11, move to the AI Agent Trigger with a **Custom Conversation Store** — see [Healthcare Patient Support Agent](../Healthcare-Compliance-Agent/).

---

## Tool Reference

### MCP Server Tools (SafetySignalMCPServer.flogo — port 9221, bearer token required)

| Tool | Scope | Parameters | Returns |
|---|---|---|---|
| `lookup_investigational_product` | `product:read` | `product_code` (required) — e.g. `IMP-4471` | INN, sponsor, protocol, phase, indication, route, subjects exposed, the Reference Safety Information in force with its listed reactions, and any active safety concerns |
| `search_case_history` | `cases:read` | `product_code`, `reaction_term` (both required) | Matching ICSRs with onset date, country, seriousness, outcome, causality and dechallenge; observed vs background rate; open signal status and owner |
| `check_label_expectedness` | `labeling:read` | `product_code`, `reaction_term` (both required) | `listed` true/false, `expectedness` LISTED/UNEXPECTED, rationale, nearest listed term, the regulatory consequence, and the 7-day / 15-day reporting clocks |

### A2A Server Tools (RegulatoryReportingA2A.flogo — port 9222, static token required)

| Tool | Parameters | Returns |
|---|---|---|
| `create_safety_case` | `product_code`, `reaction_term`, `seriousness`, `expectedness`, `causality`, `patient_reference`, `narrative` | Case number, SUSAR determination and rationale, clock start, reporting clock, submission due date, assigned physician, signal-team notification |
| `submit_expedited_report` | `case_number`, `destination` (FDA or EMA) | Submission ID, E2B(R3) message type, transmission timestamp, acknowledgement code and authority case ID, days remaining, per-recipient distribution status |
| `get_case_status` | `case_number` | Case state, owner, clock and days remaining, submission history per authority, outstanding follow-up requests with due dates, DSUR impact |

---

## Sample Data

All backend data is mocked with `#actreturn` — no database required. The mock responses are written around one coherent case so a full triage reads correctly end to end.

### Investigational Product

| Field | Value |
|---|---|
| Product code | IMP-4471 |
| INN | Velcaridine (anti-IL-6R monoclonal antibody) |
| Protocol / Phase | VEL-301 / Phase III, double-blind, placebo-controlled |
| Indication | Moderate-to-severe rheumatoid arthritis |
| Subjects exposed | 1,240 |
| Reference Safety Information | Investigator's Brochure v6.0, Section 6.3 (effective 2026-02-01) |
| Listed reactions | Injection site reaction · Headache · URTI · Nausea · Neutropenia · Hypercholesterolaemia |

### The Reported Event

| Field | Value |
|---|---|
| Reaction term | Hepatic failure (MedDRA SOC: Hepatobiliary disorders) |
| Expectedness | **UNEXPECTED** — not listed in IB v6.0 |
| Prior cases | 3 across 1,240 subjects (DE, US, JP), all positive dechallenge |
| Observed vs background rate | 2.42 vs 0.14 per 1,000 (~17×) |
| Open signal | SIG-2026-0033, Hepatology Signal Team, since 2026-04-11 |

### The Resulting Case

| Field | Value |
|---|---|
| Case number | ICSR-2026-01588 |
| SUSAR | Yes — serious + unexpected + probable causality |
| Clock | 15 calendar days, started 2026-09-25, due 2026-10-10 |
| Owner | Dr. Priya Raman, Medical Safety Physician |
| FDA submission | SUB-2026-FDA-004417, ack `AA`, FAERS-29104778 |

---

## Prerequisites

- **TIBCO Flogo 2.26.5 or later**. For more information, please refer to the [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic, Gemini, Ollama, or vLLM in the LLM configuration properties)
- A WebSocket client: the browser [Flogo Chatbot](../Chatbot/), [Postman](https://www.postman.com/), or [websocat](https://github.com/vi/websocat)

---

## Setup & Configuration

The two backends must be running before the advisor, otherwise the LLM Client has nothing to authenticate against.

### Step 1 — Start the Safety Signal MCP Server

Open `SafetySignalMCPServer.flogo` in the Flogo VS Code extension and run it. It listens on **9221** at `/mcp` and requires a bearer token out of the box:

| Property | Default |
|---|---|
| `FlogoMcpServer.PORT` | `9221` |
| `FlogoMcpServer.AUTH_TYPE` | `API Key` |
| `FlogoMcpServer.AUTH_TOKEN` | `pv-mcp-a7f3c9e24b814d6e9c052f8a1b3d7e64` |

Confirm auth is actually being enforced — the first call must fail and the second must succeed:

```bash
# No token -> 401 Unauthorized
curl -i -X POST http://localhost:9221/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# With the token -> 200 and the three tools
curl -s -X POST http://localhost:9221/mcp \
  -H "Authorization: Bearer pv-mcp-a7f3c9e24b814d6e9c052f8a1b3d7e64" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

### Step 2 — Configure and Start the Regulatory Reporting A2A Server

Open `RegulatoryReportingA2A.flogo` and set your API key in **App Properties**:

```
AgenticAI.openai.API_Key = sk-your-key-here
```

Run it. The agent listens on **9222** with `A2A.AuthMode = Static Token` and `A2A.AuthToken = pv-a2a-5d90b7c14e2f48a3b6e17c09d24f8a51`.

Verify the agent card is served and the token is enforced:

```bash
curl -s http://localhost:9222/.well-known/agent-card.json

curl -i -X POST http://localhost:9222/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"message/send","id":1,"params":{}}'   # expect 401

curl -s -X POST http://localhost:9222/ \
  -H "Authorization: Bearer pv-a2a-5d90b7c14e2f48a3b6e17c09d24f8a51" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"message/send","id":1,"params":{}}'
```

### Step 3 — Configure and Start the Drug Safety Advisor

Open `DrugSafetyAdvisor.flogo` and set:

```
LLMClient.LLM_Provider = OpenAI
LLMClient.API_Key      = sk-your-key-here
LLMClient.LLM_Model    = gpt-5-nano
```

The backend URLs and tokens default to the values above. **If you change a token on a backend, change it here too** — the pairs must match:

```
LLMClient.MCP.Safety.Auth_Token      <-->  FlogoMcpServer.AUTH_TOKEN
LLMClient.A2A.Regulatory.Auth_Token  <-->  A2A.AuthToken
```

Run it. The WebSocket server starts on **9220**.

### Step 4 — Connect and Triage a Case

**Flogo Chatbot**: start the browser client in [`Chatbot/`](../Chatbot/) and point it at `ws://localhost:9220/drugsafety?caseId=VEL-301-0442`.

**websocat**:
```bash
websocat "ws://localhost:9220/drugsafety?caseId=VEL-301-0442"
```

**Postman**: new WebSocket request to the same URL, then Connect.

The `caseId` query parameter becomes the `conversationId`. Every message on the same `caseId` shares history.

### Example Multi-Turn Conversation

```
> Site 0044 called. Subject VEL-301-0442 on IMP-4471 was hospitalised yesterday
  with acute hepatic failure. Investigator assessed causality as probable.
< Confirmed IMP-4471 (Velcaridine), protocol VEL-301, Phase III. The RSI in force
  is Investigator's Brochure v6.0. Hepatic failure is UNLISTED — Section 6.3 lists
  only asymptomatic transaminase elevation.
  Serious (hospitalisation) + unexpected + probable causality = SUSAR, 15-day clock.
  Do you have all four minimum criteria?

> Yes. What do we already know about hepatic events on this product?
< Three prior cases across 1,240 exposed subjects, all with positive dechallenge.
  Observed rate 2.42 per 1,000 vs a 0.14 background rate. Signal SIG-2026-0033
  has been open with the Hepatology Signal Team since 2026-04-11.
  Shall I open the ICSR?

> Yes, open it and file with FDA.
< Case ICSR-2026-01588 created — SUSAR, clock started 2026-09-25, due 2026-10-10.
  Filed with FDA: SUB-2026-FDA-004417, ack AA, FAERS-29104778.
  EudraVigilance queued for the next gateway window.
```

Notice that the advisor calls `check_label_expectedness` rather than judging expectedness itself, and asks before writing.

**Start an independent case:**
```bash
websocat "ws://localhost:9220/drugsafety?caseId=VEL-301-0518"
```

### Seeing Auth Fail

To prove the tokens are load-bearing, break one and watch the tool call fail while the conversation keeps working:

1. In `DrugSafetyAdvisor.flogo`, change `LLMClient.MCP.Safety.Auth_Token` to `wrong-token`.
2. Restart the advisor and ask about IMP-4471.
3. The MCP server returns **401**, the LLM reports that it cannot reach the safety database, and the app log shows the failed tool call. The A2A hop is unaffected — its token is separate.

---

## App Properties Reference

### DrugSafetyAdvisor.flogo

| Property | Default | Description |
|---|---|---|
| `WebSocket_Port` | `9220` | WebSocket server listening port |
| `LLMClient.LLM_Provider` | `OpenAI` | LLM provider name |
| `LLMClient.API_Key` | `sk-REPLACE-WITH-YOUR-OPENAI-KEY` | LLM provider API key |
| `LLMClient.LLM_Model` | `gpt-5-nano` | LLM model name |
| `LLMClient.SystemPrompt` | *(ICH E2A triage instructions)* | System prompt for the LLM |
| `LLMClient.MCP.Safety.Server_Name` | `SafetySignalMCP` | Display name for the Safety Signal MCP Server |
| `LLMClient.MCP.Safety.Server_URL` | `http://localhost:9221/mcp` | Safety Signal MCP Server endpoint |
| `LLMClient.MCP.Safety.Auth_Type` | `Token` | MCP client auth type (`None`, `Token`) |
| `LLMClient.MCP.Safety.Auth_Token` | `pv-mcp-a7f3…` | Bearer token sent to the MCP Server |
| `LLMClient.A2A.Regulatory.Server_Name` | `RegulatoryReporting` | Display name for the Regulatory Reporting A2A Server |
| `LLMClient.A2A.Regulatory.Server_URL` | `http://localhost:9222` | Regulatory Reporting A2A Server endpoint |
| `LLMClient.A2A.Regulatory.Auth_Type` | `Static Token` | A2A client auth type (`None`, `Static Token`) |
| `LLMClient.A2A.Regulatory.Auth_Token` | `pv-a2a-5d90…` | Bearer token sent to the A2A Server |

### SafetySignalMCPServer.flogo

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9221` | MCP Server listening port |
| `FlogoMcpServer.AUTH_TYPE` | `API Key` | MCP Server auth type (`None`, `API Key`, `JWT Token`, `OAuth 2.0`) |
| `FlogoMcpServer.AUTH_TOKEN` | `pv-mcp-a7f3…` | Expected bearer token, or the HMAC signing secret in `JWT Token` mode |

### RegulatoryReportingA2A.flogo

| Property | Default | Description |
|---|---|---|
| `A2A.port` | `9222` | A2A Server listening port |
| `A2A.AgentUrl` | `http://localhost:9222` | Agent URL published in the agent card |
| `A2A.AuthMode` | `Static Token` | Authentication mode (`None`, `Static Token`) |
| `A2A.AuthToken` | `pv-a2a-5d90…` | Expected bearer token |
| `AgenticAI.openai.API_Key` | `sk-REPLACE-WITH-YOUR-OPENAI-KEY` | OpenAI API key for the A2A agent's LLM |
| `AgenticAI.openai.LLM_Provider` | `OpenAI` | LLM provider for the A2A agent |
| `AgenticAI.openai.LLM_Base_URL` | *(empty)* | Override base URL for self-hosted providers |
| `Trigger_Settings.AgentName` | `RegulatoryReportingAgent` | Agent name in the agent card |
| `Trigger_Settings.AgentDescription` | *(see file)* | Agent description in the agent card |
| `Trigger_Settings.LLM_Model` | `gpt-5-nano` | Model used by the A2A agent |
| `Trigger_Settings.LLM_temperature` | `0` | Sampling temperature (deterministic — regulatory work) |
| `Trigger_Settings.Token_Limit` | `4096` | Per-request token limit |
| `Trigger_Settings.Rate_Limit` | `25` | Requests per minute |

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Rotate the MCP token | Both apps | Change `FlogoMcpServer.AUTH_TOKEN` and `LLMClient.MCP.Safety.Auth_Token` to the same new value |
| Rotate the A2A token | Both apps | Change `A2A.AuthToken` and `LLMClient.A2A.Regulatory.Auth_Token` to the same new value |
| Encrypt the tokens | App Properties | Replace the plaintext values with encrypted `SECRET:...` properties |
| Enforce per-tool scopes | MCP Server | Set `FlogoMcpServer.AUTH_TYPE` to `JWT Token` and supply a signed JWT as the client token — the `scope` values are already on every tool |
| External IdP (Keycloak, Auth0, Entra ID) | MCP Server | Set `authType` to `OAuth 2.0` and fill in `oauthIssuer`, `oauthJWKSURL`, `oauthAudience`, `oauthRequiredScopes` |
| Add TLS | Both servers | Set `enableTLS: true` with `serverCertificate` / `serverPrivateKey`, then switch the client URLs to `https://` |
| Connect a real safety database | Flows in `SafetySignalMCPServer.flogo` | Replace `#actreturn` with queries against Argus Safety, ArisGlobal LifeSphere, or Veeva Vault Safety |
| Real E2B(R3) submission | `submit_expedited_report_flow` | Replace `#actreturn` with a call to your gateway (FDA ESG / EMA EudraVigilance) |
| Add a second MCP server | `mcpServerConfigs` mapping | Add another entry — e.g. a MedDRA coding server — each with its own `authType` and `authToken` |
| Use Anthropic Claude | App properties | Set `LLM_Provider` to `Anthropic` and `LLM_Model` to a Claude model |
| Keep data on-premises | App properties | Set `LLM_Provider` to `Ollama` or `vLLM` and point `providerBaseUrl` at your endpoint — relevant when case narratives contain patient data |
| Durable, auditable memory | LLM Client Activity | Move to the AI Agent Trigger with a Custom Conversation Store for a 21 CFR Part 11 transcript |

---

## A Note on Scope

This sample is a **triage aid**, not a regulatory decision system. The system prompt deliberately makes the LLM defer expectedness to the labeling tool, defer causality to the investigator, ask before every write, and flag ambiguity to the medical safety physician. Any real deployment needs qualified person oversight, validation under GxP, and an audit trail — all of which sit outside what this sample demonstrates. The pharmacovigilance data here is fictional.
