# Telecom Invoice Chatbot Use Case

An AI-powered billing chatbot for telecom subscribers, built on TIBCO Flogo Enterprise. Subscribers ask natural-language questions ("Why is my bill so high?", "Get me a data pack", "Dispute this charge") over a WebSocket streaming chat. The system uses a 3-tier agentic architecture — an AI Orchestrator, an MCP Server for read-only BSS lookups, and A2A Servers for write workflows — all communicating via standard protocols (MCP, A2A, WebSocket).

---

## Architecture Overview

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (WebSocket Client)     │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ ws://localhost:9500/telecom
                            ▼
               ┌────────────────────────────────┐
               │  Telecom Invoice               │
               │  AI Orchestrator               │
               │  (TelecomInvoiceAIOrch.)       │
               │  Port 9500 (WebSocket)         │
               │  LLM: OpenAI GPT               │
               └───────┬───────────┬────────────┘
                       │           │
          MCP (HTTP)   │           │  A2A Protocol
                       ▼           ▼
    ┌──────────────────────┐   ┌──────────────────────────────────┐
    │  Telecom Invoice     │   │  Telecom Invoice                 │
    │  MCP Server          │   │  A2A Servers                     │
    │  Port 9882           │   │                                  │
    │  /telecom-bss        │   │  billing_dispute_agent    :9883  │
    │                      │   │  recharge_agent           :9884  │
    │  Tools (read-only):  │   │  send_confirmation_email  :9885  │
    │  - GetCustomerProfile│   │                                  │
    │  - GetInvoiceDetails │   │  Uses PostgreSQL for             │
    │  - GetUsageBreakdown │   │  data validation & writes        │
    │  - GetActivePlans    │   │  + Gmail SMTP for email          │
    │  - GetPaymentHistory │   │                                  │
    │  - CheckRechargeOffers│  │                                  │
    │  - GetDisputes       │   │                                  │
    └──────────┬───────────┘   └──────────────┬───────────────────┘
               │                              │
               └──────────────┬───────────────┘
                              ▼
               ┌────────────────────────────┐
               │  PostgreSQL Database       │
               │  Database: telecom         │
               │  9 Tables                  │
               └────────────────────────────┘
```

---

## Flogo Apps

### 1. `TelecomInvoiceMCPServer.flogo` — MCP Server (Port 9882)

Exposes 7 read-only BSS lookup tools via the Model Context Protocol over Streamable HTTP (endpoint `/telecom-bss`). Each tool queries the PostgreSQL `telecom` database and returns the full result set as a string; the LLM filters by mobile number / customer ID.

| Tool | Description | SQL |
|------|-------------|-----|
| **GetCustomerProfile** | CRM profile: mobile, name, segment, account type, active since | `SELECT * FROM customers` |
| **GetInvoiceDetails** | Invoice header + line items (PLAN/IDD/ADDON/ROAMING/TAX) | `invoices JOIN invoice_line_items` |
| **GetUsageBreakdown** | Data/voice/SMS/roaming usage vs limits | `SELECT * FROM usage_records` |
| **GetActivePlans** | Current base plan + add-ons with expiry | `SELECT * FROM plans` |
| **GetPaymentHistory** | Recent payments with method and status | `SELECT * FROM payments` |
| **CheckRechargeOffers** | Catalog of data/IDD/roaming/combo packs | `SELECT * FROM recharge_offers` |
| **GetDisputes** | Dispute tickets with status and resolution | `SELECT * FROM disputes` |

### 2. `TelecomInvoiceA2AServers.flogo` — A2A Servers (Ports 9883–9885)

Three A2A agents that handle write workflows. Each agent has its own LLM, system prompt, and tool handler.

| Agent | Port | Description |
|-------|------|-------------|
| **billing_dispute_agent** | 9883 | Validates a disputed invoice by cross-checking line items against usage records, then inserts a dispute ticket (status OPEN, 5-day estimated resolution) into `disputes`. |
| **recharge_agent** | 9884 | Applies a chosen recharge pack: inserts an ACTIVE recharge with 30-day validity into `recharges` and confirms activation. |
| **send_confirmation_email** | 9885 | Sends a confirmation email (dispute filed / recharge applied) via Gmail SMTP. Invoked only once, after the billing action, when the user requests it. |

### 3. `TelecomInvoiceAIOrchestrator.flogo` — AI Orchestrator (Port 9500)

The main orchestration app. Exposes a WebSocket endpoint for natural-language chat. An AI Agent activity classifies intent and routes to either MCP tools (data lookups) or A2A agents (write workflows).

| Setting | Value |
|---------|-------|
| WebSocket Path | `/telecom` |
| LLM | OpenAI GPT |
| MCP Server | `http://localhost:9882/telecom-bss` |
| A2A Agents | billing_dispute (9883), recharge (9884), email (9885) |

---

## Database

9 tables in the PostgreSQL `telecom` database:

| Table | Purpose | Records |
|-------|---------|---------|
| `customers` | CRM master records (mobile = subscriber id) | 8 subscribers |
| `invoices` | Monthly invoice headers | 6 (June 2026) |
| `invoice_line_items` | Charges per invoice | 19 line items |
| `usage_records` | Metered usage vs limits | 8 (one per subscriber) |
| `plans` | Base plans + add-ons | 11 |
| `payments` | Payment / top-up history | 19 |
| `recharge_offers` | Global recharge catalog | 6 offers |
| `disputes` | Dispute tickets (pre-seeded + written by agent) | 2 seeded |
| `recharges` | Recharge activation log (written by agent) | starts empty |

```bash
# Initialize schema and demo data
psql -U postgres -d telecom -f database.sql

# Reset with today-relative due/payment/dispute dates (for live demos)
psql -U postgres -d telecom -f reset_data.sql
```

---

## Demo Scenarios

### Scenario 1: "Why is my bill so high?" (MCP only)

Ahmed Al Rashid (+971-50-123-4567, Premium) has a June 2026 bill of **AED 487.50**. The agent looks up his profile, invoice, and usage and explains each line item — Plan AED 299, IDD India AED 85, Data Add-on 10GB AED 49, Roaming Saudi Arabia AED 54.50 — confirming the roaming is valid (3 roaming days recorded).

```
You:   Why is my bill so high this month? My number is +971-50-123-4567.
Agent: Your June bill is AED 487.50, made up of: Plan Premium 500 (AED 299),
       International Calls to India (AED 85), a 10GB Data Add-on (AED 49), and
       Roaming Saudi Arabia for 3 days (AED 54.50). Your usage shows 3 roaming
       days in Saudi Arabia, so the roaming charge is valid.
```

### Scenario 2: "I was charged for roaming but I didn't travel" (MCP + A2A dispute)

Fatima Al Zaabi (+971-50-234-5678) is billed **AED 120 Roaming Europe**, but her usage shows **0 roaming days**. The agent detects the discrepancy and, on confirmation, files a dispute via `billing_dispute_agent`.

```
You:   I was charged for roaming in Europe but I never left the country.
       My number is +971-50-234-5678.
Agent: I checked invoice INV-2026-06-872: it has a Roaming Europe charge of
       AED 120, but your usage shows 0 roaming days. That's a clear discrepancy.
       Would you like me to file a dispute?
You:   Yes please.
Agent: Done. Dispute DSP-2026-XXXX is now OPEN, estimated resolution within
       5 business days.
```

### Scenario 3: "I need more data" (MCP + A2A recharge)

Mohammed Hassan (+971-55-345-6789) has used 14.8 of 15 GB. The agent shows recharge offers and, on confirmation, applies one via `recharge_agent`.

```
You:   I'm almost out of data. My number is +971-55-345-6789.
Agent: You've used 14.8 of your 15 GB. Here are recharge packs: Data Booster 5GB
       (AED 29), Data Booster 10GB (AED 49), Data Max 20GB (AED 79).
You:   Give me the 10GB one.
Agent: Applied! Recharge RCG-2026-XXXX — Data Booster 10GB (AED 49), 10 GB added,
       active for 30 days.
```

### Scenario 4: "Show my last 3 payments" (MCP only)

Omar Khalil (+971-52-567-8901, Business) — the agent returns his most recent Auto-Debit payments.

### Scenario 5: "What plan am I on?" (MCP only)

Any subscriber — the agent summarizes the base plan and any active add-ons with expiry dates.

### Scenario 6: "What's the status of my dispute?" (MCP only)

Layla Ibrahim (+971-50-678-9012, VIP) has a pre-seeded dispute (DSP-2026-0001, UNDER_REVIEW). The agent looks it up via `GetDisputes`.

---

## Sample Data Summary

### Subscribers

| Customer ID | Name | Mobile | Segment | Type | Demo role |
|-------------|------|--------|---------|------|-----------|
| CUST-10042871 | Ahmed Al Rashid | +971-50-123-4567 | Premium | Postpaid | "Why is my bill high" (roaming valid) |
| CUST-10042872 | Fatima Al Zaabi | +971-50-234-5678 | Consumer | Postpaid | Dispute (roaming charged, 0 roaming days) |
| CUST-10042873 | Mohammed Hassan | +971-55-345-6789 | Consumer | Postpaid | Recharge (14.8/15 GB) |
| CUST-10042874 | Sara Abdullah | +971-56-456-7890 | Consumer | Prepaid | Plan lookup |
| CUST-10042875 | Omar Khalil | +971-52-567-8901 | Business | Postpaid | Payment history |
| CUST-10042876 | Layla Ibrahim | +971-50-678-9012 | VIP | Postpaid | Dispute status (pre-seeded) |
| CUST-10042877 | Yusuf Ahmed | +971-54-789-0123 | Consumer | Prepaid | Prepaid / general |
| CUST-10042878 | Noura Saeed | +971-58-890-1234 | Premium | Postpaid | Clean bill |

### Flagship Invoice — Ahmed Al Rashid (INV-2026-06-871)

| Line item | Category | Amount (AED) |
|-----------|----------|--------------|
| Postpaid Plan Premium 500 (monthly) | PLAN | 299.00 |
| International Calls (India) | IDD | 85.00 |
| Data Add-on 10GB | ADDON | 49.00 |
| Roaming Saudi Arabia (3 days) | ROAMING | 54.50 |
| **Total** | | **487.50** |

Usage: Data 38.7 / 50 GB · Local 342 min · International 47 min · SMS 12 · Roaming 3 days (Saudi Arabia)

---

## Port Summary

| App | Port | Protocol |
|-----|------|----------|
| TelecomInvoiceMCPServer | 9882 | HTTP (MCP), `/telecom-bss` |
| TelecomInvoiceA2AServers — billing_dispute | 9883 | HTTP (A2A) |
| TelecomInvoiceA2AServers — recharge | 9884 | HTTP (A2A) |
| TelecomInvoiceA2AServers — send_email | 9885 | HTTP (A2A) |
| TelecomInvoiceAIOrchestrator | 9500 | WebSocket |

---

## Supporting Files

| File | Description |
|------|-------------|
| `database.sql` | PostgreSQL schema with 9 tables and demo data |
| `reset_data.sql` | Data reset script (today-relative dates; clears agent-written rows) |
| `prompts.md` | Demo prompts organized by scenario |
| `manual-steps.md` | Step-by-step setup and deployment instructions |

---

## Security & Production Notes (from the design)

This is the Phase-1 working demo. For production the design calls for: TLS on all endpoints (WebSocket + MCP + A2A), Bearer-token auth on the MCP Server, API-gateway rate limiting, an on-premises LLM for data residency, and swapping the PostgreSQL-backed tools for real BSS API calls (Billing, CRM, Product Catalog, Payment Gateway). See the source deck `Telecom-Invoice-Chatbot-Flogo-Agentic-AI-v2.pdf`.
