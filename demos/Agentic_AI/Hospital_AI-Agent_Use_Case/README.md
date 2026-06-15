# Hospital AI-Agent Use Case

An agentic AI system built on TIBCO Flogo that automates hospital post-discharge workflows. An orchestrator agent coordinates specialized sub-agents to retrieve discharge summaries, book follow-up appointments, process medication orders, manage bed turnover, and send patient notifications -- all driven by natural language requests via a chat interface.

---

## Architecture Overview

```
                        ┌──────────────────────────┐
                        │   Agentic Chatbot UI     │
                        │  (agentic-chatbot.html)  │
                        └────────┬─────────────────┘
                                 │ WebSocket /ws/chat
                                 ▼
                    ┌────────────────────────────┐
                    │   Orchestrator Agent        │
                    │   (post-discharge-agent)    │
                    │   Port 8082                 │
                    └──┬────────┬────────┬────┬──┘
                       │        │        │    │
          ┌────────────┘   ┌────┘   ┌────┘    └──────────┐
          ▼                ▼        ▼                     ▼
  ┌───────────────┐ ┌──────────┐ ┌──────────┐   ┌────────────┐
  │ Post-Discharge│ │ Pharmacy │ │   Bed    │   │  SendEmail │
  │ Coordinator   │ │Fulfillment│ │ Turnover │   │   Agent    │
  └───────┬───────┘ └────┬─────┘ └────┬─────┘   └────────────┘
          │              │            │
          └──────────┬───┴────────────┘
                     ▼
          ┌────────────────────┐      ┌──────────────────────┐
          │   endevour-api     │      │  Hospital MCP Server │
          │   (REST APIs)      │      │  (Data Provider)     │
          │   Port: configurable│      │  Port 9092           │
          └────────┬───────────┘      └──────────┬───────────┘
                   │                             │
                   └──────────┬──────────────────┘
                              ▼
                   ┌─────────────────────┐
                   │    PostgreSQL DB    │
                   └─────────────────────┘
```

---

## Flogo Apps

This use case contains 4 Flogo applications:

### 1. `post-discharge-agent.flogo` -- Orchestrator Agent (Port 8082)

The main agentic AI app. Exposes a WebSocket endpoint (`/ws/chat`) that accepts natural language requests and coordinates 4 specialized sub-agents:

| Sub-Agent | Role |
|-----------|------|
| **post_discharge_coordinator** | Retrieves discharge summaries from the EMR and books follow-up appointments |
| **pharmacy_fulfillment_agent** | Processes medication orders for each prescribed drug |
| **bed_turnover_agent** | Initiates bed cleaning and updates bed availability |
| **SendEmail** | Sends discharge confirmation email to the patient |

### 2. `endevour-api.flogo` -- Hospital REST API (Port: configurable)

The backend REST API layer that the agents call. Backed by PostgreSQL. Exposes these endpoints:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/v1/patients/{patient_id}/discharge-summary` | Retrieve discharge info with medications |
| POST | `/api/v1/appointments` | Book a follow-up appointment |
| POST | `/api/v1/pharmacy/orders` | Create a medication order |
| POST | `/api/v1/beds/actions` | Request bed cleaning |
| POST | `/api/v1/beds/update-status` | Mark bed as available |

### 3. `Hospital_MCP_Server.flogo` -- MCP Server (Port 9092)

A Model Context Protocol (MCP) server that exposes hospital data as tools for AI agents. Provides read access to patients, beds, appointments, medications, discharges, pharmacy orders, and specialties -- all backed by PostgreSQL queries.

### 4. `eai-api.flogo` -- Simple API (Port 9999)

A lightweight supplementary API with a single `GET /appointments` endpoint.

---

## Supporting Files

| File | Description |
|------|-------------|
| `agentic-chatbot.html` | Browser-based chat UI that connects to the orchestrator via WebSocket |
| `swagger.json` | OpenAPI 3.0 spec for the Hospital Management API |
| `database.sql` | PostgreSQL DDL (table creation) + initial sample data |
| `reset_data.sql` | Resets all tables to a clean baseline with 10 patients and realistic test data |
| `agents.md` | Detailed agent definitions, system prompts, and handover context schemas |
| `hospital-poc.md` | Full POC document with architecture, scenarios, and demo script |
| `prompts.md` | 19 test prompts covering single-agent, multi-agent, full workflow, and edge cases |
| `api-endpoints.txt` | Quick reference for all API endpoints with request/response examples |

---

## Database Setup

The system uses PostgreSQL with 8 tables:

| Table | Purpose |
|-------|---------|
| `patients` | Patient records (10 sample patients) |
| `patient_discharges` | Discharge records with ward/bed/specialty info |
| `discharge_medications` | Medications prescribed at discharge |
| `appointments` | Follow-up appointment bookings |
| `medication_catalog` | Drug reference catalog (10 medications) |
| `pharmacy_orders` | Medication dispensing orders |
| `beds` | Bed status tracking across wards |
| `specialties` | Medical specialty reference data |

### Initialize the database

```sql
-- Run database.sql to create tables and insert initial data
psql -U <user> -d <database> -f database.sql

-- Or to reset to a clean test baseline:
psql -U <user> -d <database> -f reset_data.sql
```

---

## How to Run the Demo

### Prerequisites

- TIBCO Flogo Enterprise (v2.26+) to build and deploy the `.flogo` apps
- PostgreSQL database instance
- A configured LLM connection (Claude) for the orchestrator agent

### Step 1: Set up the database

Run `database.sql` to create the schema and seed data. Use `reset_data.sql` to reset to a clean baseline before each demo run.

### Step 2: Deploy the Flogo apps

Import and deploy the apps in this order:

1. **`endevour-api.flogo`** -- Configure the PostgreSQL connection and the REST port, then start. This is the backend that all agents call.
2. **`Hospital_MCP_Server.flogo`** -- Configure the PostgreSQL connection. Starts on port 9092.
3. **`eai-api.flogo`** -- Starts on port 9999.
4. **`post-discharge-agent.flogo`** -- Configure the LLM connection (Claude) and the URLs for the endevour-api endpoints. Starts on port 8082.

### Step 3: Start the chatbot UI

```bash
cd demos/Agentic_AI/Chatbot
npm install
npm start
```

Then open http://localhost:3000 in your browser. To connect to the Hospital agent, paste its WebSocket URL in the input field at the top-right:

```
ws://localhost:8082/ws/chat
```

Click **Connect** to start the session.

### Step 4: Run the demo

Use natural language to trigger workflows. Example prompts:

**Single agent -- discharge summary:**
```
Get the discharge summary for patient P-2024-00123
```

**Full workflow -- discharge + appointment + meds + bed + email:**
```
Complete the full discharge process for patient P-2024-00123 including
follow-up appointment, all medication orders, bed cleanup, and send
appointment confirmation email with all the details
```

**Bed management only:**
```
Patient has been discharged from BED-2A-002 in WARD-2A, please initiate bed cleaning
```

See [prompts.md](prompts.md) for the full set of 19 test scenarios with expected results.

---

## Demo Workflow

The primary demo scenario -- **Post-Discharge Coordination** -- follows this flow:

1. User requests discharge processing for a patient via the chatbot
2. **Orchestrator** routes to the **Post-Discharge Coordinator** agent
3. Agent calls `GET /api/v1/patients/{id}/discharge-summary` to retrieve discharge info
4. If follow-up is required, agent calls `POST /api/v1/appointments` to book an appointment (7 days from discharge, with the appropriate specialty)
5. If medications are prescribed, **Pharmacy Fulfillment** agent calls `POST /api/v1/pharmacy/orders` for each medication
6. **Bed Turnover** agent calls `POST /api/v1/beds/actions` to request bed cleaning
7. **SendEmail** agent sends a confirmation email to the patient with appointment and medication details
8. Orchestrator returns a consolidated summary to the chatbot

---

## Sample Test Patients

| Patient ID | Name | Discharge | Follow-Up | Specialty | Medications | Bed |
|------------|------|-----------|-----------|-----------|-------------|-----|
| P-2024-00122 | Bob Tan | Today | Yes | Orthopedics | 1 (Paracetamol) | BED-3B-001 |
| P-2024-00123 | John Tan | Today | Yes | Cardiology | 3 (Aspirin, Metoprolol, Atorvastatin) | BED-4A-010 |
| P-2024-00125 | David Wong | Today | No | General | 1 (Amoxicillin) | BED-2A-002 |
| P-2024-00124 | Mary Lim | Tomorrow | Yes | Orthopedics | 2 (Paracetamol, Omeprazole) | BED-3B-002 |
| P-2024-00126 | Sarah Chen | Day after tomorrow | Yes | Neurology | 2 (Gabapentin, Paracetamol) | BED-5C-001 |
| P-2024-00128 | Emily Goh | Future | Yes | General | None | BED-1A-001 |
| P-2024-00121 | Alice Ng | Past | No | General | None | BED-2A-001 |
