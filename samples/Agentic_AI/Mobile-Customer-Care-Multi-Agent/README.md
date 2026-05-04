# Mobile Customer Care Multi-Agent Hub

## Overview

This sample demonstrates the **"List of Agents for Handoff"** capability of the **TIBCO Flogo® AI Agent Activity** using a real-world Mobile customer care scenario. A single Flogo application hosts four cooperating AI agents: a **CustomerSupportDispatcher** (AI Agent Activity) that uses the `agentHandoffs` list to let the LLM autonomously route customer messages to three specialist **Agent Triggers** (Billing, Technical, Upgrade) — delivering a seamless, intelligent support experience with no manual routing logic in the flow.

The sample also contrasts two routing styles side by side:

| Routing Style | Component Used | Pattern | Best For |
|---|---|---|---|
| **AI-driven (non-deterministic)** | **AIAgent Activity** with `agentHandoffs` list | LLM reads the message and routes to the right specialist | Main chat interface — the user just describes their problem |
| **Deterministic** | **Invoke AI Agent Trigger** (`callagent`) | Code explicitly calls a named Agent Trigger | When the user has already selected a department (e.g., billing menu option) |

---

## Real-World Scenario

**Persona**: Sarah, a Mobile customer, connects to live support via the company's web chat.

```
Sarah: "Hi — I got my March bill and there's a $12 international roaming charge
        that I don't recognise. Also, my 5G signal has been terrible this week."

CustomerSupportDispatcher: "Hi Sarah! I understand how frustrating that must be —
        let me sort both issues out for you. I'll start with the billing question..."

[Dispatcher → hands off to BillingSpecialistAgent for the charge dispute]

BillingSpecialistAgent: [Calls GetBillDetails]
        "I can see the £12 charge from your trip to the UK on March 2–4.
         As a goodwill gesture, I've applied a $12.00 credit..."
        [Calls ApplyBillCredit → confirmed]
        "Credit confirmed! Your new balance is $97.98, due April 15.
         Now let me hand you over to our Tech team about the 5G issue..."

[BillingSpecialist → conversation returns to Dispatcher → hands off to TechnicalSupportAgent]

TechnicalSupportAgent: [Calls RunLineDiagnostics]
        "I've run a diagnostic on your line. Your iPhone 12 is 5G-capable,
         but 5G isn't available at your registered address yet — nearest
         tower is 3.2km away. Your SIM also hasn't been refreshed in 847
         days, which may be causing the LTE drops. Want me to push a SIM
         refresh now? It takes about 2 minutes..."

Sarah: "Yes please — and actually, if 5G won't be at my address for a while,
        maybe it's time to look at what plans are available?"

[TechnicalSupportAgent → hands off to UpgradeAdvisorAgent]

UpgradeAdvisorAgent: [Calls GetEligibleUpgrades]
        "Great timing! As a loyal customer you qualify for early upgrade.
         Our Unlimited Premium 5G+ at $109.99/mo includes priority data,
         international calling to 50 countries, and a $150 bill credit.
         Want me to confirm that upgrade?"

Sarah: "Yes, let's do it."

UpgradeAdvisorAgent: [Calls SubmitUpgradeOrder → confirmed]
        "Done! Order ORD-2026-04-9921 confirmed. Your new plan activates
         April 8, and your $150 credit covers most of the first month."
```

**One conversation. Three specialist agents. Six tool calls. Zero manual routing logic in the Flogo flow.**

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         MobileCustomerCareHub (port 9998)                   │
│                                                                              │
│  WebSocket /customer-care                WebSocket /billing                  │
│  ┌────────────────────────┐              ┌─────────────────────────────┐    │
│  │   customerCare_flow    │              │    directBilling_flow        │    │
│  │                        │              │                              │    │
│  │  ┌─────────────────┐   │              │  ┌────────────────────────┐  │    │
│  │  │ CustomerSupport │   │              │  │  InvokeAIAgentTrigger  │  │    │
│  │  │  Dispatcher     │   │              │  │  (callagent)           │  │    │
│  │  │                 │   │              │  │  agentName:            │  │    │
│  │  │ [AIAgent        │   │              │  │  "BillingSpecialist    │  │    │
│  │  │  Activity]      │   │              │  │   Agent"               │  │    │
│  │  │                 │   │              │  └──────────┬─────────────┘  │    │
│  │  │ agentHandoffs:  │   │              └─────────────│───────────────┘    │
│  │  │  Billing,       │   │                            │ (deterministic)    │
│  │  │  Technical,     │   │                            │                    │
│  │  │  Upgrade        │   │              ┌─────────────▼──────────────────┐ │
│  │  └────────┬────────┘   │              │  Agent Trigger:                 │ │
│  └───────────│────────────┘              │  BillingSpecialistAgent         │ │
│              │ (non-deterministic)       │  port: 8081                     │ │
│              │                           │                                  │ │
│              │ ┌────────── LLM decides ──┤  Tools:                         │ │
│              │ │                         │   • GetBillDetails               │ │
│              │ │                         │   • ApplyBillCredit              │ │
│              │ │                         └─────────────────────────────────┘ │
│              │ │                                                              │
│              │ ├──────────────────────────────────────────────────────────┐  │
│              │ │                  Agent Trigger:                           │  │
│              │ │                  TechnicalSupportAgent                    │  │
│              │ │                  port: 8082                               │  │
│              │ │                  agentHandoffs: "UpgradeAdvisorAgent"     │  │
│              │ │                                                            │  │
│              │ │                  Tools:                                   │  │
│              │ │                   • RunLineDiagnostics                    │  │
│              │ │                   • ScheduleTechnicianVisit               │  │
│              │ │                  └─────────────────────────────────────┐ │  │
│              │ │  (multi-hop handoff when device upgrade needed)         │ │  │
│              │ │                                                          │ │  │
│              │ └──────────────────────────────────────────────────────┐  │ │  │
│              │                    Agent Trigger:                       │  │ │  │
│              └──────────────────► UpgradeAdvisorAgent  ◄──────────────┘  │ │  │
│                                   port: 8083                              │ │  │
│                                                                            │ │  │
│                                   Tools:                                  │ │  │
│                                    • GetEligibleUpgrades                  │ │  │
│                                    • SubmitUpgradeOrder                   │ │  │
└───────────────────────────────────────────────────────────────────────────┘ │
                                                                              │
```

---

## The "List of Agents for Handoff" Feature — How It Works

### Configuration (AIAgent Activity)

The key is the `agentHandoffs` setting on the **CustomerSupportDispatcher** AI Agent Activity in `customerCare_flow`:

```
agentHandoffs: "BillingSpecialistAgent,TechnicalSupportAgent,UpgradeAdvisorAgent"
```

This comma-separated list tells the AI Agent Activity's LLM which Agent Triggers it can autonomously route to. The LLM:
1. Reads the customer's message
2. Consults the agent names and descriptions in the handoff list
3. Decides which specialist (or itself) should handle the request
4. Transfers execution to that Agent Trigger — seamlessly, within the same Flogo app

**No if/else branching. No keyword matching. No routing rules to maintain.**

### Configuration (Agent Trigger — multi-hop)

`TechnicalSupportAgent` also has `agentHandoffs` set to `"UpgradeAdvisorAgent"`. This enables **multi-hop handoff**:

```
CustomerSupportDispatcher → TechnicalSupportAgent → UpgradeAdvisorAgent
```

When the TechnicalSupportAgent's LLM determines a device upgrade would solve the connectivity problem, it hands off to UpgradeAdvisorAgent — all transparently within the same conversation.

### The Deterministic Counterpart (InvokeAIAgentTrigger)

`directBilling_flow` uses the **Invoke AI Agent Trigger activity** (`callagent`) to call `BillingSpecialistAgent` directly:

```json
{
  "ref": "#callagent",
  "input": {
    "agentName": "BillingSpecialistAgent",
    "prompt": "=coerce.toString($flow.content)",
    "conversationId": "=string.concat(\"billing-direct-\", ...)"
  }
}
```

This is the **deterministic path** — the Flogo flow code decides the routing, not the LLM. Use this when the customer has already selected a department from a menu, or when you need guaranteed routing for SLA purposes.

---

## The Four Agents

### CustomerSupportDispatcher (AIAgent Activity)
- **Type**: AI Agent Activity in a flow (NOT an Agent Trigger)
- **Role**: Intelligent triage — greets the customer and routes to the right specialist
- **Handoffs to**: `BillingSpecialistAgent`, `TechnicalSupportAgent`, `UpgradeAdvisorAgent`
- **Port**: N/A (embedded in the flow, not a standalone agent server)
- **Key setting**: `agentHandoffs: "BillingSpecialistAgent,TechnicalSupportAgent,UpgradeAdvisorAgent"`

### BillingSpecialistAgent (Agent Trigger)
- **Role**: Billing, payments, charge disputes, credits
- **Port**: 8081
- **LLM guardrails**: Enabled + PII redaction (`redactSensitiveData: true`)
- **Tools**:
  - `GetBillDetails` — full itemized bill retrieval
  - `ApplyBillCredit` — applies goodwill or dispute credits

### TechnicalSupportAgent (Agent Trigger)
- **Role**: Connectivity, diagnostics, device issues, technician scheduling
- **Port**: 8082
- **Handoffs to**: `UpgradeAdvisorAgent` (when device upgrade is the solution)
- **Tools**:
  - `RunLineDiagnostics` — real-time network and line diagnostics
  - `ScheduleTechnicianVisit` — books field technician home visits

### UpgradeAdvisorAgent (Agent Trigger)
- **Role**: Plan upgrades, device upgrades, promotions, order processing
- **Port**: 8083
- **Reachable from**: `CustomerSupportDispatcher` (direct) AND `TechnicalSupportAgent` (multi-hop)
- **Tools**:
  - `GetEligibleUpgrades` — retrieves all eligible upgrade options
  - `SubmitUpgradeOrder` — places the confirmed upgrade order

---

## Features Demonstrated

| Feature | Where | Detail |
|---|---|---|
| **List of Agents for Handoff** | `customerCare_flow` → `CustomerSupportDispatcher` | `agentHandoffs: "BillingSpecialistAgent,TechnicalSupportAgent,UpgradeAdvisorAgent"` — LLM routes autonomously |
| **Multi-hop Agent Handoff** | `TechnicalSupportAgent` trigger | `agentHandoffs: "UpgradeAdvisorAgent"` — 3-level deep routing |
| **Invoke AI Agent Trigger (callagent)** | `directBilling_flow` | Deterministic direct call to `BillingSpecialistAgent` by name |
| **AIAgent Activity** | `customerCare_flow` | Agent Activity (not trigger) as intelligent orchestrator |
| **AIAgent Trigger × 3** | BillingSpecialist, TechnicalSupport, UpgradeAdvisor | Each a focused specialist with its own system prompt and tools |
| **6 Custom Tool Handlers** | All three Agent Triggers | Typed JSON schemas, log + return pattern, ready for REST replacement |
| **PII Guardrails** | BillingSpecialistAgent | `enableGuardrails: true` + `redactSensitiveData: true` |
| **In-Memory Conversation Store** | All agents | `conversationStoreType: Memory` — multi-turn context retained |
| **Session-scoped conversation IDs** | Both entry flows | `string.concat("care-session-", $flow.queryParams.sessionId)` |

---

## Tool Schemas

### GetBillDetails (BillingSpecialistAgent)
```json
{
  "accountId": "string — Mobile account ID, e.g. ACC-10045",
  "billingPeriod": "string (optional) — e.g. 'March 2026', defaults to current period"
}
```

### ApplyBillCredit (BillingSpecialistAgent)
```json
{
  "accountId": "string — Mobile account ID",
  "creditAmount": "number — Dollar amount of credit to apply, e.g. 12.00",
  "creditReason": "string — Reason for credit, e.g. 'International roaming charge dispute'"
}
```

### RunLineDiagnostics (TechnicalSupportAgent)
```json
{
  "accountId": "string — Mobile account ID",
  "serviceType": "string (optional) — e.g. 'Mobile 5G', 'Home Fiber', defaults to primary service"
}
```

### ScheduleTechnicianVisit (TechnicalSupportAgent)
```json
{
  "accountId": "string — Mobile account ID",
  "preferredDate": "string — Preferred date for visit, e.g. '2026-04-08'",
  "issueDescription": "string — Description of the technical issue for the technician"
}
```

### GetEligibleUpgrades (UpgradeAdvisorAgent)
```json
{
  "accountId": "string — Mobile account ID",
  "currentPlan": "string (optional) — Current plan name, e.g. 'Unlimited Pro 5G'"
}
```

### SubmitUpgradeOrder (UpgradeAdvisorAgent)
```json
{
  "accountId": "string — Mobile account ID",
  "newPlan": "string — Selected plan name exactly as returned by GetEligibleUpgrades",
  "effectiveDate": "string (optional) — Activation date, defaults to next billing cycle"
}
```

---

## Prerequisites

- **TIBCO Flogo® 2.26.2 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or configure a different LLM provider — see below)
- A WebSocket client for testing: [Postman](https://www.postman.com/) or [websocat](https://github.com/vi/websocat)

---

## Quick Start

### 1. Open the App

Open `MobileCustomerCareHub.flogo` in VS Code with the Flogo extension.

### 2. Configure Your LLM Provider

In the **App Properties**, set your API key:
```
AgenticAI.openai.API_Key = sk-your-key-here
```

Or change `AgenticAI.openai.LLM_Provider` to `Anthropic` or `Google` and update the connection accordingly.

### 3. Run the App

Click **Run** in the Flogo VS Code extension. The app starts a WebSocket server on port 9998.

### 4. Test — AI-Driven Routing (non-deterministic)

Connect to the main customer care endpoint with your session ID.

**Postman**: Create a new WebSocket request with URL `ws://localhost:9998/customer-care?sessionId=sess-001` and click Connect.

**websocat** (command line):
```bash
websocat "ws://localhost:9998/customer-care?sessionId=sess-001"
```

Try these messages to see the LLM route to different specialists:

**Billing scenario:**
```
I got a strange charge on my March bill for $12. Can you look into it?
```

**Technical scenario:**
```
My 5G connection keeps dropping every few minutes and the speeds are terrible.
```

**Upgrade scenario:**
```
I'm thinking about upgrading my plan. What options do I have?
```

**Multi-domain scenario (watch the multi-hop handoff):**
```
My internet is slow AND I want to know if upgrading my plan would help.
```

### 5. Test — Deterministic Direct Billing

Connect directly to the billing endpoint.

**Postman**: Use URL `ws://localhost:9998/billing?sessionId=sess-002`.

**websocat** (command line):
```bash
websocat "ws://localhost:9998/billing?sessionId=sess-002"
```

The Flogo flow bypasses AI routing and calls `BillingSpecialistAgent` directly every time.

---

## Adapting to Production

The tool handler flows (`get_bill_details_flow`, `apply_bill_credit_flow`, etc.) each contain:
1. A **Log activity** — logs the incoming tool parameters
2. A **Return activity** — returns mock JSON data

To connect to real systems, **replace the Return activity** in each tool flow with an **Invoke REST Service** activity pointing to your backend APIs:

| Tool Flow | Real-World Backend |
|---|---|
| `get_bill_details_flow` | BSS / Billing API |
| `apply_bill_credit_flow` | CRM / Billing adjustment service |
| `run_line_diagnostics_flow` | OSS / Network management platform |
| `schedule_tech_visit_flow` | Field service management (e.g., ServiceNow, Salesforce Field Service) |
| `get_eligible_upgrades_flow` | Product catalog / CRM (e.g., Salesforce, SAP) |
| `submit_upgrade_order_flow` | Order management / provisioning platform |

---

## Design Patterns Illustrated

### Why AIAgent Activity as the Dispatcher?

The `CustomerSupportDispatcher` uses an **AI Agent Activity** (not an Agent Trigger) as the entry point. This is intentional:
- It is invoked by the **WebSocket trigger** — a standard Flogo trigger
- It embeds LLM intelligence directly in the entry flow
- The `agentHandoffs` list is configured right in the activity settings — no separate agent server port needed for the dispatcher itself

This lets any Flogo trigger (REST, Kafka, WebSocket, Timer) serve as the customer-facing entry point, with the AI acting as a smart router in-flow.

### Deterministic vs. Non-Deterministic — When to Use Each

```
Customer presses "Billing Help" button → directBilling_flow → callagent("BillingSpecialistAgent")
                                         ↑ Deterministic — guaranteed routing

Customer types free-form message → customerCare_flow → agentHandoffs list
                                   ↑ Non-deterministic — LLM decides
```

Use **deterministic** (`callagent`) when:
- The user has made an explicit menu selection
- SLA requires a guaranteed agent assignment
- Compliance mandates certain query types go to specific teams

Use **non-deterministic** (`agentHandoffs`) when:
- The user types free-form text
- Issues span multiple domains and need intelligent triage
- You want a conversational, natural routing experience

### Multi-Hop Handoff

The `TechnicalSupportAgent → UpgradeAdvisorAgent` chain shows that Agent Triggers can themselves have `agentHandoffs` configured, enabling arbitrarily deep specialist chains. The conversation state is preserved across all hops — the customer never has to repeat themselves.

---

## Sample Conversation Flows

### Flow 1: Pure Billing (2 agents)
```
Customer → CustomerSupportDispatcher → BillingSpecialistAgent
```

### Flow 2: Pure Technical (2 agents)
```
Customer → CustomerSupportDispatcher → TechnicalSupportAgent
```

### Flow 3: Technical + Upgrade (3 agents — multi-hop)
```
Customer → CustomerSupportDispatcher → TechnicalSupportAgent → UpgradeAdvisorAgent
```

### Flow 4: Direct Billing (1 agent — deterministic)
```
Customer → directBilling_flow (callagent) → BillingSpecialistAgent
```
