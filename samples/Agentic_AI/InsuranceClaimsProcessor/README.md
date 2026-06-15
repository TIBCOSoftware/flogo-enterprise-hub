# Insurance Claims Processor — LLM Client Activity with MCP Server and A2A Server

## Overview

This sample demonstrates the **LLM Client Activity** (`llmclientactivity`) of the **TIBCO Flogo Agentic AI Connector** using a real-world insurance claims processing scenario. Three independent Flogo applications work together:

- **InsuranceClaimsProcessor.flogo** — A **REST API** that chains two LLM Client Activity calls: one for policy verification (via MCP) and one for fraud assessment (via A2A).
- **PolicyLookupMCPServer.flogo** — A **stateless MCP Server** exposing insurance policy lookup and coverage check tools.
- **FraudDetectionA2A.flogo** — An **A2A Server** agent that analyzes claim patterns and calculates fraud risk scores.

This architecture shows how to use the **LLM Client Activity** for lightweight, stateless, one-shot LLM inference — where each call dynamically configures the LLM provider, model, and API key as activity inputs rather than requiring a pre-configured LLM Provider Connection.

| Pattern | Component | What It Shows |
|---|---|---|
| **LLM Client + MCP** | `InsuranceClaimsProcessor.flogo` | LLM Client Activity calling MCP tools for policy lookup |
| **LLM Client + A2A** | `InsuranceClaimsProcessor.flogo` | LLM Client Activity delegating to a remote A2A agent for fraud detection |
| **Sequential chaining** | `InsuranceClaimsProcessor.flogo` | Output of LLMClient step 1 feeds into the prompt of LLMClient step 2 |
| **MCP Server** | `PolicyLookupMCPServer.flogo` | Stateless MCP Server with tool annotations |
| **A2A Server** | `FraudDetectionA2A.flogo` | Agent Trigger with `agentType: "A2A Server"`, PII redaction, conversation memory |

---

## Real-World Scenario

**Persona**: A claims adjuster receives a new claim and submits it to the automated claims processor.

```
Adjuster submits:
  Policy: POL-2026-001234
  Type:   collision
  Amount: $4,500
  Date:   2026-06-10
  Desc:   "Vehicle struck in grocery store parking lot"

System (Step 1 — Policy Verification via MCP):
  [Calls lookup_policy → PolicyLookupMCPServer]
  [Calls check_coverage → PolicyLookupMCPServer]

  "Policy POL-2026-001234 is ACTIVE.
   Holder: James Morrison
   Vehicle: 2025 Honda CR-V
   Coverage: Collision up to $50,000, deductible $500
   Status: COVERED — claim amount $4,500 is within limits."

System (Step 2 — Fraud Assessment via A2A):
  [Delegates to FraudDetectionA2A agent]
  [Agent calls AnalyzeClaimPatterns → LOW_RISK, 1 claim in 5 years]
  [Agent calls CalculateRiskScore → composite score 15, APPROVE]

  "RECOMMENDATION: APPROVE

   Policy Verification: ACTIVE, collision COVERED, $50,000 limit
   Fraud Risk Score: 15/100 (LOW)
     - Claim Frequency: 8 (1 claim in 5 years)
     - Amount Anomaly: 12 (within normal range)
     - Document Consistency: 5 (all consistent)
     - Behavioral Pattern: 10 (no unusual indicators)

   Recommendation: APPROVE — clean claims history, low fraud risk,
   8-year customer with safe driver discount."
```

**One REST call. Two LLM Client steps. MCP tools for data lookup + A2A agent for fraud intelligence — chained in a simple Flogo flow.**

The system supports **5 demo policies** with different outcomes — see [Demo Scenarios](#demo-scenarios) below.

---

## Architecture

```
 User (REST Client — Postman, curl, etc.)
      |  POST http://localhost:9194/process-claim
      |  Body: { policy_number, claim_type, claim_amount,
      |          incident_description, incident_date }
      v
 +--------------------------------------------------------------------+
 |  InsuranceClaimsProcessor.flogo (port 9194)                        |
 |                                                                     |
 |  REST Trigger --> process_claim_flow                                |
 |                                                                     |
 |  +----------------------------------------------------------+      |
 |  | Step 1: LookupPolicy (LLM Client Activity)               |      |
 |  |   systemPrompt: "Verify policy and check coverage..."    |      |
 |  |   userPrompt: policy_number + claim_type + claim_amount  |      |
 |  |   mcpServers: [PolicyLookupMCPServer]                    |------+----> PolicyLookupMCPServer.flogo
 |  |   LLM: OpenAI gpt-4o, temp 0.3 (dynamic config)         |      |      (MCP on port 9603/mcp)
 |  +-----------------------------+----------------------------+      |      +- lookup_policy
 |                                |                                    |      +- check_coverage
 |                    $activity[LookupPolicy].response                |
 |                                |                                    |
 |  +-----------------------------v----------------------------+      |
 |  | Step 2: AssessFraud (LLM Client Activity)                |      |
 |  |   systemPrompt: "Combine policy + fraud results..."     |      |
 |  |   userPrompt: claim details + Step 1 output             |------+----> FraudDetectionA2A.flogo
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

## Files in This Sample

| File | Description |
|---|---|
| `InsuranceClaimsProcessor.flogo` | **Orchestrator** — REST API on port 9194 with two chained LLM Client Activity calls. Step 1 verifies policy via MCP, Step 2 assesses fraud via A2A. Returns a final APPROVE/REVIEW/DENY recommendation. |
| `PolicyLookupMCPServer.flogo` | **MCP Server** — Stateless MCP Server on port 9603. Exposes two read-only tools (`lookup_policy`, `check_coverage`) with realistic mock data for a Comprehensive Auto policy. |
| `FraudDetectionA2A.flogo` | **A2A Server** — Fraud detection agent on port 9604 with Static Token auth, PII redaction enabled. Exposes two tools (`AnalyzeClaimPatterns`, `CalculateRiskScore`) with multi-dimensional fraud scoring mock data. |

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

### MCP Server Tools (PolicyLookupMCPServer.flogo — port 9603)

| Tool | Parameters | Returns |
|---|---|---|
| `lookup_policy` | `policy_number` (required) | Full policy details: holder info, vehicle, coverage limits, deductible, premium, claim history, discounts |
| `check_coverage` | `policy_number`, `claim_type` (both required) | Coverage status (COVERED/NOT_COVERED/PARTIALLY_COVERED), limit, deductible, co-pay %, exclusions, conditions, processing time |

Both tools are annotated with `readOnlyToolHint: true` to signal they do not modify state.

### A2A Server Tools (FraudDetectionA2A.flogo — port 9604)

| Tool | Parameters | Returns |
|---|---|---|
| `AnalyzeClaimPatterns` | `claimantName`, `policyNumber` (required), `claimType`, `claimAmount`, `incidentDate`, `incidentDescription` | Analysis ID, detected patterns with severity, suspicious indicators, overall risk assessment (LOW/MEDIUM/HIGH) |
| `CalculateRiskScore` | `claimantName`, `policyNumber` (required), `patternAnalysisId`, `claimAmount` | Risk score ID, composite score (0-100), breakdown by dimension, recommendation (APPROVE/FLAG_FOR_REVIEW/DENY), confidence |

---

## Demo Scenarios

The system includes **5 hardcoded policies** that produce different outcomes, plus a bonus uncovered claim type scenario:

| # | Policy | Holder | Vehicle | Claim Type | Amount | Fraud Score | Expected Outcome |
|---|--------|--------|---------|------------|--------|-------------|-----------------|
| 1 | POL-2026-001234 | James Morrison | Honda CR-V 2025 | Collision | $4,500 | 15 (LOW) | **APPROVE** |
| 2 | POL-2026-005678 | Sarah Mitchell | BMW X5 2024 | Collision | $18,500 | 58 (MEDIUM) | **FLAG_FOR_REVIEW** |
| 3 | POL-2026-009012 | Marcus Webb | Mercedes GLE 2025 | Theft | $62,000 | 87 (HIGH) | **DENY** |
| 4 | POL-2026-003456 | Elena Rodriguez | Toyota RAV4 2023 | Medical | $12,000 | 22 (LOW) | **REVIEW** (coverage limit) |
| 5 | POL-2026-007890 | David Park | Hyundai Tucson 2022 | Collision | $8,500 | 10 | **DENY** (expired policy) |
| 6 | POL-2026-001234 | James Morrison | Honda CR-V 2025 | Flood | $15,000 | 15 (LOW) | **DENY** (uncovered type) |

### Why Each Scenario Is Interesting

- **Scenario 1 (APPROVE):** Clean 8-year customer, low-value claim, witness corroboration — the "happy path"
- **Scenario 2 (FLAG_FOR_REVIEW):** Coverage limits were increased 60 days before this claim. Suspicious timing + amount near adjuster threshold
- **Scenario 3 (DENY):** New customer, 4 claims in 10 months (5x average), $62K theft with no evidence — staged-loss indicators
- **Scenario 4 (REVIEW):** Fraud score is LOW/APPROVE, but $12K medical claim exceeds $10K coverage limit — the LLM should flag the coverage gap
- **Scenario 5 (DENY):** Policy expired April 2026 — claim cannot be processed regardless of fraud score
- **Scenario 6 (DENY):** Valid policy but flood is not a covered claim type — tests the coverage check logic

---

## Prerequisites

- **TIBCO Flogo 2.26.4 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic, Gemini, Ollama, or vLLM in the LLM configuration properties)
- A REST client for testing: [Postman](https://www.postman.com/) or curl

---

## Setup & Configuration

### Step 1 — Configure and Start the MCP Server

Open `PolicyLookupMCPServer.flogo` in the Flogo VS Code extension. The default port is **9603** (configurable via `FlogoMcpServer.PORT` in App Properties).

Run `PolicyLookupMCPServer.flogo`. This starts the MCP Server on port **9603** at endpoint `/mcp`.

### Step 2 — Configure and Start the A2A Server

Open `FraudDetectionA2A.flogo`. In the **App Properties**, set your API key:

```
AgenticAI.openai.API_Key = sk-your-key-here
```

Optionally update `A2A.AuthToken` if you want a custom authentication token.

Run `FraudDetectionA2A.flogo`. This starts the A2A Server agent on port **9604**.

Verify it is running:
```bash
curl http://localhost:9604/.well-known/agent.json
```

### Step 3 — Configure and Start the Claims Processor

Open `InsuranceClaimsProcessor.flogo`. In the **App Properties**, set:

```
LLMClient.openai.API_Key      = sk-your-key-here
LLMClient.openai.LLM_Model    = gpt-4o
LLMClient.openai.LLM_Provider = OpenAI
LLMClient.A2A.Fraud.Server_URL  = http://localhost:9604
LLMClient.A2A.Fraud.Auth_Token  = (same token configured on the A2A Server)
```

Run `InsuranceClaimsProcessor.flogo`. This starts the REST API on port **9194**.

### Step 4 — Submit a Claim

Pick any scenario from below and run the curl command. Start with **Scenario 1** for the happy path, then try **Scenario 3** for the high-fraud deny.

---

## Demo Prompts (Copy-Paste Ready)

### Scenario 1 — APPROVE (Clean Claim, Low Risk)

```bash
curl -s -X POST http://localhost:9194/process-claim \
  -H "Content-Type: application/json" \
  -d '{"policy_number":"POL-2026-001234","claim_type":"collision","claim_amount":4500,"incident_description":"Vehicle was struck by another car while parked in a grocery store parking lot. Damage to rear bumper and tailgate. Other driver left a note with insurance information.","incident_date":"2026-06-10"}'
```

**What happens:** Policy lookup finds James Morrison, 8-year customer with Honda CR-V 2025, $500 deductible, 1 claim in 5 years. Collision is COVERED up to $50K. Fraud score 15 (LOW) → **APPROVE**.

---

### Scenario 2 — FLAG_FOR_REVIEW (Suspicious Timing)

```bash
curl -s -X POST http://localhost:9194/process-claim \
  -H "Content-Type: application/json" \
  -d '{"policy_number":"POL-2026-005678","claim_type":"collision","claim_amount":18500,"incident_description":"Highway collision during heavy rain on I-70. Vehicle hydroplaned into median barrier. Significant front-end and side panel damage. Police report filed.","incident_date":"2026-06-08"}'
```

**What happens:** Sarah Mitchell, BMW X5 2024. Coverage limits were increased from $50K to $75K just 60 days before this claim. 2 claims in 18 months. Fraud score 58 (MEDIUM) → **FLAG_FOR_REVIEW**.

---

### Scenario 3 — DENY (High Fraud Risk)

```bash
curl -s -X POST http://localhost:9194/process-claim \
  -H "Content-Type: application/json" \
  -d '{"policy_number":"POL-2026-009012","claim_type":"theft","claim_amount":62000,"incident_description":"Vehicle reported stolen from residential driveway overnight. No security camera footage available. Noticed missing when leaving for work in the morning.","incident_date":"2026-06-12"}'
```

**What happens:** Marcus Webb, Mercedes GLE 2025. New customer (< 12 months), 4 claims in 10 months (5x average), $62K theft with no evidence. Staged-loss pattern detected. Fraud score 87 (HIGH) → **DENY**.

---

### Scenario 4 — REVIEW (Exceeds Coverage Limit)

```bash
curl -s -X POST http://localhost:9194/process-claim \
  -H "Content-Type: application/json" \
  -d '{"policy_number":"POL-2026-003456","claim_type":"medical","claim_amount":12000,"incident_description":"Rear-ended at stoplight. Passenger sustained whiplash and minor back injuries requiring emergency room visit and follow-up physical therapy sessions.","incident_date":"2026-06-05"}'
```

**What happens:** Elena Rodriguez, Toyota RAV4 2023, 5-year customer. Fraud score is 22 (LOW) / APPROVE. But medical coverage is only $10K with 20% co-pay — the $12K claim exceeds the limit. The LLM should flag this coverage gap and recommend **REVIEW**.

---

### Scenario 5 — DENY (Expired Policy)

```bash
curl -s -X POST http://localhost:9194/process-claim \
  -H "Content-Type: application/json" \
  -d '{"policy_number":"POL-2026-007890","claim_type":"collision","claim_amount":8500,"incident_description":"Side collision at intersection. Other driver ran red light. Moderate damage to driver side doors and quarter panel.","incident_date":"2026-06-11"}'
```

**What happens:** David Park, Hyundai Tucson 2022. Policy **EXPIRED** on April 1, 2026. Coverage check returns NOT_COVERED (POLICY_EXPIRED). Fraud score 10 → **DENY** — claim cannot be processed on an expired policy.

---

### Scenario 6 (Bonus) — DENY (Uncovered Claim Type)

```bash
curl -s -X POST http://localhost:9194/process-claim \
  -H "Content-Type: application/json" \
  -d '{"policy_number":"POL-2026-001234","claim_type":"flood","claim_amount":15000,"incident_description":"Vehicle submerged in flash flood waters in underground parking garage. Total water damage to engine and interior.","incident_date":"2026-06-13"}'
```

**What happens:** James Morrison's policy is ACTIVE and valid, but flood damage is NOT a covered claim type under standard auto policies. Coverage check returns NOT_COVERED. The LLM should **DENY** based on coverage, not fraud.

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
