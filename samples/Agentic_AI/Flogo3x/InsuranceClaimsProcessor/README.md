# Insurance Claims Processor — LLM Client Activity with MCP Server and A2A Server

## Overview

This sample demonstrates the **LLM Client Activity** (`llmclientactivity`) of the **TIBCO Flogo Agentic AI Connector** using a real-world insurance claims processing scenario. Three independent TIBCO Flogo® 3 applications work together:

- **InsuranceClaimsProcessor** — A **REST API** that chains two LLM Client Activity calls: one for policy verification (via MCP) and one for fraud assessment (via A2A).
- **PolicyLookupMCPServer** — A **stateless MCP Server** exposing insurance policy lookup and coverage check tools.
- **FraudDetectionA2A** — An **A2A Server** agent that analyzes claim patterns and calculates fraud risk scores.

This architecture shows how to use the **LLM Client Activity** for lightweight, stateless, one-shot LLM inference — where each call dynamically configures the LLM provider, model, and API key as activity inputs rather than requiring a pre-configured LLM Provider Connection.

| Pattern | Component | What It Shows |
|---|---|---|
| **LLM Client + MCP** | `InsuranceClaimsProcessor` | LLM Client Activity calling MCP tools for policy lookup |
| **LLM Client + A2A** | `InsuranceClaimsProcessor` | LLM Client Activity delegating to a remote A2A agent for fraud detection |
| **Sequential chaining** | `InsuranceClaimsProcessor` | Output of LLMClient step 1 feeds into the prompt of LLMClient step 2 |
| **MCP Server** | `PolicyLookupMCPServer` | Stateless MCP Server with tool annotations |
| **A2A Server** | `FraudDetectionA2A` | Agent Trigger with `agentType: "A2A Server"`, PII redaction, conversation memory |

---

## Real-World Scenario

**Persona**: Sarah, a claims adjuster at Pacific Coast Insurance, receives a new claim and submits it to the automated claims processor.

```
Sarah submits:
  Policy: POL-2026-001234
  Type:   collision
  Amount: $15,000
  Date:   2026-05-28
  Desc:   "Rear-ended at intersection during evening commute"

System (Step 1 — Policy Verification via MCP):
  [Calls lookup_policy → PolicyLookupMCPServer]
  [Calls check_coverage → PolicyLookupMCPServer]

  "Policy POL-2026-001234 is ACTIVE.
   Holder: Robert Chen
   Vehicle: 2024 Toyota Camry
   Coverage: Collision up to $50,000, deductible $1,000
   Status: COVERED — claim amount $15,000 is within limits.
   Note: 1 prior settled claim (CLM-2026-8891, $3,200 collision, March 2026)."

System (Step 2 — Fraud Assessment via A2A):
  [Delegates to FraudDetectionA2A agent]
  [Agent calls AnalyzeClaimPatterns → 3 patterns found, MEDIUM_RISK]
  [Agent calls CalculateRiskScore → composite score 62, FLAG_FOR_REVIEW]

  "RECOMMENDATION: REVIEW

   Policy Verification: ACTIVE, collision COVERED, $50,000 limit
   Fraud Risk Score: 62/100 (MEDIUM)
     - Claim Frequency: 58 (3 claims in 12 months, above average)
     - Amount Anomaly: 74 (2.4x typical for this coverage tier)
     - Document Consistency: 45 (minor timeline inconsistencies)
     - Behavioral Pattern: 68 (filed near policy renewal)

   Recommendation: FLAG_FOR_REVIEW — coverage confirmed but elevated
   fraud indicators warrant manual adjuster review before approval.

   Mitigating factors: 5+ year customer, no prior fraud flags."
```

**One REST call. Two LLM Client steps. MCP tools for data lookup + A2A agent for fraud intelligence — chained in a simple Flogo flow.**

---

## Architecture

```
 User (REST Client — Postman, curl, etc.)
      |  POST http://localhost:9194/process-claim
      |  Body: { policy_number, claim_type, claim_amount,
      |          incident_description, incident_date }
      v
 +--------------------------------------------------------------------+
 |  InsuranceClaimsProcessor (port 9194)                              |
 |                                                                     |
 |  REST Trigger --> process_claim_flow                                |
 |                                                                     |
 |  +----------------------------------------------------------+      |
 |  | Step 1: LookupPolicy (LLM Client Activity)               |      |
 |  |   systemPrompt: "Verify policy and check coverage..."    |      |
 |  |   userPrompt: policy_number + claim_type + claim_amount  |      |
 |  |   mcpServers: [PolicyLookupMCPServer]                    |------+----> PolicyLookupMCPServer
 |  |   LLM: OpenAI gpt-4o, temp 0.3 (dynamic config)         |      |      (MCP on port 9603/mcp)
 |  +-----------------------------+----------------------------+      |      +- lookup_policy
 |                                |                                    |      +- check_coverage
 |                    $activity[LookupPolicy].response                |
 |                                |                                    |
 |  +-----------------------------v----------------------------+      |
 |  | Step 2: AssessFraud (LLM Client Activity)                |      |
 |  |   systemPrompt: "Combine policy + fraud results..."     |      |
 |  |   userPrompt: claim details + Step 1 output             |------+----> FraudDetectionA2A
 |  |   remoteAgents: [FraudDetectionA2A]                     |      |      (A2A on port 9604)
 |  |   LLM: OpenAI gpt-4o, temp 0.3 (dynamic config)         |      |      +- AnalyzeClaimPatterns
 |  +-----------------------------+----------------------------+      |      +- CalculateRiskScore
 |                                |                                    |
 |                    $activity[AssessFraud].response                  |
 |                                |                                    |
 |  +-----------------------------v----------------------------+      |
 |  | ReturnDecision (actreturn)                               |      |
 |  |   code: 200                                              |      |
 |  |   data.result: AssessFraud response                      |      |
 |  +----------------------------------------------------------+      |
 +--------------------------------------------------------------------+
```

---

## Apps in This Sample

Each app is a Flogo 3 project folder containing `app.fgmd` (plus `app.fgprops`, `flows/`, `triggers/`, `connections/`).

| App (project folder) | Description |
|---|---|
| `InsuranceClaimsProcessor` | **Orchestrator** — REST API on port 9194 with two chained LLM Client Activity calls. Step 1 verifies policy via MCP, Step 2 assesses fraud via A2A. Returns a final APPROVE/REVIEW/DENY recommendation. |
| `PolicyLookupMCPServer` | **MCP Server** — Stateless MCP Server on port 9603. Exposes two read-only tools (`lookup_policy`, `check_coverage`) with realistic mock data for a Comprehensive Auto policy. |
| `FraudDetectionA2A` | **A2A Server** — Fraud detection agent on port 9604 with Static Token auth, PII redaction enabled. Exposes two tools (`AnalyzeClaimPatterns`, `CalculateRiskScore`) with multi-dimensional fraud scoring mock data. |

---

## The LLM Client Activity — How It Works

The **LLM Client Activity** is a lightweight alternative to the AI Agent Activity for scenarios where you need one-shot LLM inference without conversation memory, guardrails, or agent infrastructure.

### Key Differentiator: Dynamic LLM Configuration

Unlike the AI Agent Activity (which requires a pre-configured LLM Provider Connection), the LLM Client Activity configures the LLM **dynamically as activity inputs**:

```json
{
  "ref": "#llmclientactivity",
  "settings": {
    "responseType": "Text",
    "mcpServers": ["conn://488cd44d-..."]
  },
  "input": {
    "systemPrompt": "=$property[\"LLMClient.policyLookupPrompt\"]",
    "userPrompt": "=string.concat(\"Policy Number: \", ...)",
    "llmConfiguration": {
      "mapping": {
        "provider": "=$property[\"LLMClient.openai.LLM_Provider\"]",
        "apiKey": "=$property[\"LLMClient.openai.API_Key\"]",
        "model": "=$property[\"LLMClient.openai.LLM_Model\"]",
        "providerBaseUrl": "",
        "temparature": 0.3
      }
    }
  }
}
```

This means you can:
- **Switch LLM providers at runtime** — route different steps to different models
- **Use different temperatures per step** — low for factual lookup, higher for creative synthesis
- **Avoid LLM Provider Connection overhead** — no connector configuration needed for quick integrations

### MCP Server Integration

The LLM Client Activity supports a `mcpServers` list in settings, connecting it to one or more MCP Servers. In Step 1 (`LookupPolicy`), the LLM automatically discovers and calls the `lookup_policy` and `check_coverage` tools from the PolicyLookupMCPServer.

### A2A Remote Agent Integration

The `remoteAgents` setting connects the LLM Client Activity to A2A Server agents. In Step 2 (`AssessFraud`), the LLM delegates fraud analysis to the FraudDetectionA2A agent, which runs its own tools and returns structured results.

### Sequential Chaining Pattern

The second LLMClient call passes the first call's output directly in its user prompt:

```
userPrompt: string.concat(
  "Claim Details:\n...",
  "\n\nPolicy Verification and Coverage Result from Step 1:\n",
  coerce.toString($activity[LookupPolicy].response)
)
```

This is the simplest pattern for multi-step LLM pipelines in Flogo — no conversation memory or agent handoff needed, just flow-level data passing.

---

## Tool Reference

### MCP Server Tools (PolicyLookupMCPServer — port 9603)

| Tool | Parameters | Returns |
|---|---|---|
| `lookup_policy` | `policy_number` (required) | Full policy details: holder info, vehicle, coverage limits, deductible, premium, claim history, discounts |
| `check_coverage` | `policy_number`, `claim_type` (both required) | Coverage status (COVERED/NOT_COVERED/PARTIALLY_COVERED), limit, deductible, co-pay %, exclusions, conditions, processing time |

Both tools are annotated with `readOnlyToolHint: true` to signal they do not modify state.

### A2A Server Tools (FraudDetectionA2A — port 9604)

| Tool | Parameters | Returns |
|---|---|---|
| `AnalyzeClaimPatterns` | `claimantName`, `policyNumber` (required), `claimType`, `claimAmount`, `incidentDate`, `incidentDescription` | Analysis ID, detected patterns with severity, suspicious indicators, overall risk assessment (LOW/MEDIUM/HIGH) |
| `CalculateRiskScore` | `claimantName`, `policyNumber` (required), `patternAnalysisId`, `claimAmount` | Risk score ID, composite score (0-100), breakdown by dimension, recommendation (APPROVE/FLAG_FOR_REVIEW/DENY), confidence |

---

## Sample Data

### Policy: POL-2026-001234 (Robert Chen)

| Field | Value |
|---|---|
| Policy Type | Comprehensive Auto |
| Status | ACTIVE |
| Vehicle | 2024 Toyota Camry |
| Effective | Jan 15, 2026 |
| Expiration | Jan 15, 2027 |
| Deductible | $1,000 |
| Monthly Premium | $185 |
| Collision Limit | $50,000 |
| Comprehensive Limit | $50,000 |
| Liability Limit | $100,000 |
| Medical Limit | $10,000 |
| Prior Claims | 1 settled (CLM-2026-8891, collision, $3,200, Mar 2026) |
| Discounts | Safe driver, Multi-policy, Anti-theft device |

### Coverage Check (collision)

| Field | Value |
|---|---|
| Status | COVERED |
| Coverage Limit | $50,000 |
| Deductible | $1,000 |
| Co-Pay | 20% |
| Exclusions | Intentional damage, racing, commercial use |
| Conditions | Police report for >$2K, photos within 72h, rental car max 30 days |

### Fraud Analysis

| Dimension | Score | Weight | Detail |
|---|---|---|---|
| Claim Frequency | 58 | 25% | 3 claims in 12 months, above average |
| Amount Anomaly | 74 | 30% | 2.4x typical for this coverage tier |
| Document Consistency | 45 | 25% | Minor timeline inconsistencies |
| Behavioral Pattern | 68 | 20% | Filed near policy renewal period |
| **Composite** | **62** | | **FLAG_FOR_REVIEW** (confidence: 0.78) |

---

## Prerequisites

- **TIBCO Flogo® 3.0.0 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic, Gemini, Ollama, or vLLM in the LLM configuration properties)
- A REST client for testing: [Postman](https://www.postman.com/) or curl

---

## App Properties

Set these in each app's `.fgprops` file (Flogo 3 App Properties) before running.

### InsuranceClaimsProcessor (orchestrator — REST API on port 9194)

| Property | Value |
|---|---|
| `LLMClient.openai.LLM_Provider` | `OpenAI` |
| `LLMClient.openai.API_Key` | `sk-your-key-here` |
| `LLMClient.openai.LLM_Model` | `gpt-4o` |
| `LLMClient.A2A.Fraud.Server_Name` | `FraudDetection` |
| `LLMClient.A2A.Fraud.Server_URL` | `http://localhost:9604` |
| `LLMClient.A2A.Fraud.Auth_Token` | (same token configured on the A2A Server) |
| `LLMClient.policyLookupPrompt` | System prompt for Step 1 (policy verification via MCP) |
| `LLMClient.fraudAssessmentPrompt` | System prompt for Step 2 (fraud assessment via A2A) |

### PolicyLookupMCPServer (MCP Server on port 9603)

| Property | Value |
|---|---|
| `FlogoMcpServer.PORT` | `9603` |

### FraudDetectionA2A (A2A Server on port 9604)

| Property | Value |
|---|---|
| `AgenticAI.openai.LLM_Provider` | `OpenAI` |
| `AgenticAI.openai.API_Key` | `sk-your-key-here` |
| `AgenticAI.openai.LLM_Base_URL` | (blank — set for Ollama/vLLM) |
| `A2A.AgentUrl` | `http://localhost:9604` |
| `A2A.AuthToken` | Static token clients must present (must match `LLMClient.A2A.Fraud.Auth_Token`) |
| `A2A.ServerPort` | `9604` |
| `Trigger_Settings.AgentName` | `FraudDetectionAgent` |
| `Trigger_Settings.AgentDescription` | Fraud detection specialist agent description |
| `Trigger_Settings.LLM_Model` | `gpt-4o` |
| `Trigger_Settings.LLM_temperature` | `0.2` |
| `Trigger_Settings.Rate_Limit` | `20` |
| `Trigger_Settings.Token_Limit` | `8192` |

---

## Setup & Run

Start order matters: bring up the **PolicyLookupMCPServer** (MCP) and **FraudDetectionA2A** (A2A) server apps first, then the **InsuranceClaimsProcessor** orchestrator app that calls them.

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `InsuranceClaimsProcessor`, `PolicyLookupMCPServer`, and `FraudDetectionA2A`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (LLM provider/API key, server URLs, ports) — see the App Properties section. Make sure `FraudDetectionA2A`'s `A2A.AuthToken` matches `InsuranceClaimsProcessor`'s `LLMClient.A2A.Fraud.Auth_Token`.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal. Run the apps in this order:
   - **PolicyLookupMCPServer** — starts the MCP Server on port **9603** at endpoint `/mcp`.
   - **FraudDetectionA2A** — starts the A2A Server agent on port **9604**. Verify it is running:
     ```bash
     curl http://localhost:9604/.well-known/agent.json
     ```
   - **InsuranceClaimsProcessor** — starts the REST API on port **9194**.
5. Submit a claim to the orchestrator and verify the response:

   **curl**:
   ```bash
   curl -X POST http://localhost:9194/process-claim \
     -H "Content-Type: application/json" \
     -d '{
       "policy_number": "POL-2026-001234",
       "claim_type": "collision",
       "claim_amount": 15000,
       "incident_description": "Rear-ended at intersection during evening commute",
       "incident_date": "2026-05-28"
     }'
   ```

   **Postman**: Create a POST request to `http://localhost:9194/process-claim` with the JSON body above.

   The response returns a final APPROVE/REVIEW/DENY recommendation combining the policy verification (Step 1, via MCP) and the fraud risk assessment (Step 2, via A2A) — see the Real-World Scenario section for a sample decision.

---

## Sample Queries

### Standard Claim

```json
{
  "policy_number": "POL-2026-001234",
  "claim_type": "collision",
  "claim_amount": 15000,
  "incident_description": "Rear-ended at intersection during evening commute",
  "incident_date": "2026-05-28"
}
```

### High-Value Claim (likely triggers REVIEW or DENY)

```json
{
  "policy_number": "POL-2026-001234",
  "claim_type": "comprehensive",
  "claim_amount": 48000,
  "incident_description": "Vehicle stolen from parking garage",
  "incident_date": "2026-06-01"
}
```

### Medical Claim

```json
{
  "policy_number": "POL-2026-001234",
  "claim_type": "medical",
  "claim_amount": 5200,
  "incident_description": "Whiplash and back pain from rear-end collision",
  "incident_date": "2026-05-28"
}
```

---

## LLM Client Activity vs. AI Agent Activity

| Feature | LLM Client Activity (this sample) | AI Agent Activity |
|---|---|---|
| LLM configuration | **Dynamic** — provider, model, apiKey as activity inputs | **Static** — pre-configured LLM Provider Connection |
| Conversation memory | No (stateless, one-shot) | Yes (in-memory or custom store) |
| Guardrails | No | Yes (default PII + custom) |
| MCP Server support | Yes (`mcpServers` list) | Yes (`mcpServers` list) |
| A2A Remote Agent support | Yes (`remoteAgents` list) | Yes (`remoteAgents` list) |
| Agent handoff | No | Yes (`agentHandoffs` list) |
| Best for | Pipeline steps, stateless inference, quick integrations | Full-featured conversational agents |

**Use the LLM Client Activity when** you need to embed LLM calls in a Flogo flow without the overhead of agent infrastructure — e.g., data enrichment, classification, summarization, or multi-step pipelines like this sample.

**Use the AI Agent Activity when** you need conversation continuity, guardrails, or agent handoff across multiple user turns.

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Connect to a real policy database | `lookup_policy_flow` in MCP Server | Replace `actreturn` with a JDBC query or REST call to your policy management system |
| Real-time coverage checks | `check_coverage_flow` in MCP Server | Replace `actreturn` with a call to your underwriting API |
| Live fraud detection | Tool flows in A2A Server | Replace `actreturn` with calls to fraud detection APIs (SAS, FICO, or custom ML models) |
| Add more MCP tools | MCP Server trigger | Add new tool handlers — e.g., `get_claim_history`, `check_deductible_status` |
| Use Anthropic Claude | App properties | Change `LLM_Provider` to `Anthropic` and `LLM_Model` to `claude-sonnet-4-5` |
| Use a local model | App properties | Change `LLM_Provider` to `Ollama` and set `providerBaseUrl` to your Ollama endpoint |
| Add a third pipeline step | `process_claim_flow` in Orchestrator | Add another LLM Client Activity — e.g., for compliance review or automated correspondence drafting |
| Switch to AI Agent Activity | Orchestrator | Replace LLM Client Activities with AI Agent Activities for conversation memory across claims |
| Add custom guardrails | A2A Server | Add a Custom Guardrail handler for additional PII detection beyond the built-in `redactSensitiveData` |

---

## Extending to Production

1. **Replace mock data** in each tool flow's `actreturn` with live API calls to your policy management system, underwriting engine, and fraud detection service
2. **Add authentication** to the REST endpoint and MCP Server — configure JWT or Token auth on the REST trigger, MCP Server trigger, and MCP Server connection
3. **Add a compliance review step** — insert a third LLM Client Activity that checks the claim against regulatory requirements before final decision
4. **Connect the A2A Server to real fraud models** — integrate with SAS Fraud Management, FICO Falcon, or custom ML pipelines
5. **Add logging and audit trails** — insert Flogo logging activities between steps to create a reviewable decision record
6. **Deploy the MCP and A2A servers independently** — they can serve multiple orchestrator apps (e.g., auto claims, property claims, health claims) simultaneously

See the [Travel Itinerary Planner](../Travel-Itinerary-Planner/) sample for the complementary A2A architecture pattern using the AI Agent Trigger, and the [Healthcare Compliance Agent](../Healthcare-Compliance-Agent/) for custom guardrails and durable conversation stores.
