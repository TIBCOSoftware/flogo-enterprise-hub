# Predictive Maintenance & Asset Monitoring — Agentic AI Demo

AI-driven sensor intelligence for oilfield operations powered by TIBCO Flogo Agentic AI Connector.

---

## Demo Overview

An oilfield operations control room operator interacts with an AI-powered assistant via a **WebSocket chat interface**. The assistant coordinates multiple specialized agents to:

- Analyze real-time sensor readings from pumps, compressors, and wellhead valves
- Classify asset health status (NORMAL / WARNING / CRITICAL)
- Predict remaining useful life (days to failure)
- Create maintenance work orders for at-risk equipment
- Send alert notifications for critical/warning conditions
- Query historical predictions and maintenance records

The operator can ask natural language questions like:
- *"Analyze the latest sensor readings for pump PUMP-W47-TX"*
- *"What assets are in critical condition right now?"*
- *"Create a work order for compressor COMP-W12-OK"*
- *"Send an alert for all warning/critical assets at well site WS-PERMIAN-001"*
- *"Show me the prediction history for valve VALVE-W03-NM"*
- *"Run a full health check on PUMP-W47-TX — analyze sensors, store prediction, create work order if needed, and send alert"*

---

## Architecture — 3 Flogo Apps

```
┌─────────────────────────────────────────────────────────────────────┐
│  App 1: MCP Server (port 9093)                                      │
│  Exposes read-only MCP tools for AI agent to query data             │
│  Tools: GetAssets, GetSensorReadings, GetPredictions,               │
│         GetWorkOrders, GetAlertHistory, GetWellSites                │
│  Connection: PostgreSQL → predictive_maintenance DB                 │
└─────────────────────────────┬───────────────────────────────────────┘
                              │ MCP Server Connection
┌─────────────────────────────▼───────────────────────────────────────┐
│  App 3: Agentic AI Orchestration (WebSocket port 8083)              │
│                                                                     │
│  WebSocket Trigger /ws/chat → Orchestrator Flow                     │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │  AI Agent Activity (Orchestrator)                        │       │
│  │  - MCP tools for read-only data queries                  │       │
│  │  - agentHandoffs → 4 sub-agents                          │       │
│  │  - Intent analysis → invoke only needed agents           │       │
│  └────────┬──────────┬──────────┬──────────┬───────────────┘       │
│           │          │          │          │                         │
│  ┌────────▼──┐ ┌─────▼────┐ ┌──▼───────┐ ┌▼──────────┐            │
│  │ sensor_   │ │prediction│ │work_order│ │alert_     │            │
│  │ analysis  │ │_agent    │ │_agent    │ │notification│            │
│  │ _agent    │ │          │ │          │ │_agent     │            │
│  └────────┬──┘ └─────┬────┘ └──┬───────┘ └┬──────────┘            │
│           │          │          │          │                         │
└───────────┼──────────┼──────────┼──────────┼────────────────────────┘
            │          │          │          │ REST API calls
┌───────────▼──────────▼──────────▼──────────▼────────────────────────┐
│  App 2: REST API Service (port 9095)                                │
│  Write operations via REST endpoints                                │
│  GET  /api/v1/assets/{asset_id}/sensor-data                         │
│  POST /api/v1/predictions                                           │
│  POST /api/v1/work-orders                                           │
│  POST /api/v1/alerts                                                │
│  Connection: PostgreSQL → predictive_maintenance DB                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Sub-Agents (4 agents)

### 1. sensor_analysis_agent

**Purpose:** Retrieves the latest sensor readings and asset details for a given asset.

**API Calls:**
- `GET /api/v1/assets/{asset_id}/sensor-data` — Returns asset info + latest sensor readings (vibration, temperature, pressure, flow rate)

**Input (toolParams):**
```json
{ "asset_id": "PUMP-W47-TX" }
```

**Returns to orchestrator:** Asset details and latest sensor readings. The orchestrator's system prompt instructs Claude to analyze these readings and classify health status.

**System Prompt:** Retrieve sensor data for the given asset. Return the raw sensor readings and asset details to the orchestrator. Do not analyze or classify — that is the orchestrator's responsibility using its AI reasoning.

---

### 2. prediction_agent

**Purpose:** Stores an AI-generated health prediction for an asset in the database.

**API Calls:**
- `POST /api/v1/predictions` — Stores prediction with status, confidence, days_to_failure, failure_mode, recommended_action, sensor_anomalies

**Input (toolParams):**
```json
{
  "asset_id": "PUMP-W47-TX",
  "status": "WARNING",
  "confidence": "0.91",
  "days_to_failure": "12",
  "failure_mode": "bearing_wear",
  "recommended_action": "Schedule inspection within 72h",
  "sensor_anomalies": "vibration_rms: 4.8g (threshold 3.5g), temp_delta: +18C above baseline"
}
```

**Returns to orchestrator:** Prediction ID and confirmation.

**System Prompt:** Store the prediction using the provided parameters. Return the prediction_id and confirmation to the orchestrator. Do not invoke any other agents.

---

### 3. work_order_agent

**Purpose:** Creates a maintenance work order for an asset that needs attention.

**API Calls:**
- `POST /api/v1/work-orders` — Creates work order with priority, description, assigned technician, scheduled date

**Input (toolParams):**
```json
{
  "asset_id": "PUMP-W47-TX",
  "priority": "HIGH",
  "description": "Bearing wear detected. Schedule inspection within 72h.",
  "assigned_to": "Field Tech Team A",
  "scheduled_date": "2026-04-20"
}
```

**Returns to orchestrator:** Work order ID and confirmation.

**System Prompt:** Create a work order using the provided parameters. Return the work_order_id and confirmation to the orchestrator. Do not invoke any other agents.

---

### 4. alert_notification_agent

**Purpose:** Sends alert notifications for WARNING or CRITICAL assets. Logs the alert and optionally sends email.

**API Calls:**
- `POST /api/v1/alerts` — Logs alert with severity, message, asset details

**Input (toolParams):**
```json
{
  "asset_id": "PUMP-W47-TX",
  "severity": "WARNING",
  "message": "Bearing wear detected on PUMP-W47-TX. Est. 12 days to failure. Confidence: 91%. Action: Schedule inspection within 72h."
}
```

**Returns to orchestrator:** Alert ID and confirmation.

**System Prompt:** Log the alert using the provided parameters. Return the alert_id and confirmation to the orchestrator. Do not invoke any other agents. Send exactly once.

---

## Orchestrator Agent

**Role:** Central coordinator that receives operator queries via WebSocket, analyzes intent, and invokes the appropriate sub-agents.

**Has access to:**
- **MCP Tools** (read-only): GetAssets, GetSensorReadings, GetPredictions, GetWorkOrders, GetAlertHistory, GetWellSites — for querying current data
- **4 Sub-agents** (write operations): sensor_analysis_agent, prediction_agent, work_order_agent, alert_notification_agent

**Intent Analysis:**

| User Request | Agents Invoked |
|---|---|
| "Show sensor readings for X" | sensor_analysis_agent only |
| "What's the status of asset X?" | MCP tools only (read-only query) |
| "Analyze and predict health of X" | sensor_analysis_agent → prediction_agent |
| "Create work order for X" | work_order_agent only |
| "Send alert for X" | alert_notification_agent only |
| "Full health check for X" | sensor_analysis_agent → prediction_agent → work_order_agent → alert_notification_agent |
| "Show prediction history for X" | MCP tools only (GetPredictions) |
| "List all critical assets" | MCP tools only (GetPredictions) |

**AI Analysis (by the orchestrator, not a sub-agent):**

When the orchestrator receives sensor readings from sensor_analysis_agent, Claude itself performs the analysis:
- Classifies status: NORMAL / WARNING / CRITICAL
- Estimates remaining useful life (days to failure)
- Identifies failure mode (bearing_wear, overheating, seal_leak, pressure_anomaly, etc.)
- Recommends action
- Then invokes prediction_agent to store the result

**Sensor Thresholds (in orchestrator system prompt):**

| Sensor | Normal | Warning | Critical |
|---|---|---|---|
| Vibration RMS | < 3.5g | 3.5g – 6.0g | > 6.0g |
| Temperature | < 85°C | 85°C – 105°C | > 105°C |
| Pressure (PSI) | 800 – 1200 | 600–800 or 1200–1500 | < 600 or > 1500 |
| Flow Rate (bbl/hr) | 80 – 120 | 60–80 or 120–140 | < 60 or > 140 |

---

## Database Schema

### Tables (PostgreSQL — database: `predictive_maintenance`)

#### 1. well_sites
```sql
CREATE TABLE well_sites (
    well_site_id VARCHAR(30) PRIMARY KEY,
    site_name VARCHAR(100),
    location VARCHAR(200),
    region VARCHAR(50)
);
```

#### 2. assets
```sql
CREATE TABLE assets (
    asset_id VARCHAR(30) PRIMARY KEY,
    asset_type VARCHAR(20),        -- PUMP, COMPRESSOR, VALVE
    well_site_id VARCHAR(30),
    description VARCHAR(200),
    install_date VARCHAR(20),
    status VARCHAR(20) DEFAULT 'OPERATIONAL'  -- OPERATIONAL, MAINTENANCE, OFFLINE
);
```

#### 3. sensor_readings
```sql
CREATE TABLE sensor_readings (
    id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    reading_timestamp VARCHAR(30),
    vibration_rms DECIMAL(5,2),     -- in g-force
    temperature_c DECIMAL(5,1),     -- in Celsius
    pressure_psi DECIMAL(7,1),      -- in PSI
    flow_rate DECIMAL(6,1),         -- in bbl/hr
    power_consumption DECIMAL(6,1)  -- in kW
);
```

#### 4. predictions
```sql
CREATE TABLE predictions (
    prediction_id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    predicted_at VARCHAR(30),
    status VARCHAR(20),            -- NORMAL, WARNING, CRITICAL
    confidence DECIMAL(4,2),
    days_to_failure INTEGER,
    failure_mode VARCHAR(50),
    recommended_action VARCHAR(500),
    sensor_anomalies VARCHAR(500)
);
```

#### 5. work_orders
```sql
CREATE TABLE work_orders (
    work_order_id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    prediction_id INTEGER,
    priority VARCHAR(10),          -- LOW, MEDIUM, HIGH, URGENT
    description VARCHAR(500),
    assigned_to VARCHAR(100),
    scheduled_date VARCHAR(20),
    status VARCHAR(20) DEFAULT 'OPEN',  -- OPEN, IN_PROGRESS, COMPLETED, CANCELLED
    created_at VARCHAR(30)
);
```

#### 6. alert_history
```sql
CREATE TABLE alert_history (
    alert_id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    prediction_id INTEGER,
    severity VARCHAR(20),          -- INFO, WARNING, CRITICAL
    message VARCHAR(500),
    sent_at VARCHAR(30),
    status VARCHAR(20) DEFAULT 'SENT'  -- SENT, ACKNOWLEDGED, RESOLVED
);
```

---

## Dummy Data

### Well Sites (3 sites)
| well_site_id | site_name | location | region |
|---|---|---|---|
| WS-PERMIAN-001 | Permian Basin Site Alpha | Midland, TX | Permian Basin |
| WS-BAKKEN-002 | Bakken Field Site Bravo | Williston, ND | Bakken |
| WS-EAGLE-003 | Eagle Ford Site Charlie | Karnes City, TX | Eagle Ford |

### Assets (8 assets across 3 sites)
| asset_id | type | well_site | status |
|---|---|---|---|
| PUMP-W47-TX | PUMP | WS-PERMIAN-001 | OPERATIONAL |
| PUMP-W48-TX | PUMP | WS-PERMIAN-001 | OPERATIONAL |
| COMP-W12-OK | COMPRESSOR | WS-PERMIAN-001 | OPERATIONAL |
| VALVE-W03-NM | VALVE | WS-BAKKEN-002 | OPERATIONAL |
| PUMP-B21-ND | PUMP | WS-BAKKEN-002 | MAINTENANCE |
| COMP-B05-ND | COMPRESSOR | WS-BAKKEN-002 | OPERATIONAL |
| PUMP-E14-TX | PUMP | WS-EAGLE-003 | OPERATIONAL |
| VALVE-E07-TX | VALVE | WS-EAGLE-003 | OPERATIONAL |

### Sensor Readings (latest readings per asset — seeded with various health states)

| asset_id | vibration_rms | temp_c | pressure_psi | flow_rate | Health |
|---|---|---|---|---|---|
| PUMP-W47-TX | 4.8 | 98.5 | 1150.0 | 95.2 | WARNING (high vibration + temp) |
| PUMP-W48-TX | 2.1 | 72.3 | 1050.0 | 102.5 | NORMAL |
| COMP-W12-OK | 6.5 | 112.0 | 1480.0 | 88.0 | CRITICAL (all sensors elevated) |
| VALVE-W03-NM | 1.8 | 68.0 | 980.0 | 105.0 | NORMAL |
| PUMP-B21-ND | 5.2 | 91.0 | 750.0 | 72.0 | WARNING (vibration + low pressure + low flow) |
| COMP-B05-ND | 3.0 | 78.5 | 1100.0 | 98.0 | NORMAL |
| PUMP-E14-TX | 7.1 | 108.0 | 580.0 | 55.0 | CRITICAL (vibration + temp + low pressure + low flow) |
| VALVE-E07-TX | 2.5 | 75.0 | 1020.0 | 110.0 | NORMAL |

Multiple historical readings per asset will be seeded (every 2 hours over the past 24h) to show trends. The latest reading reflects the health state above.

### Existing Predictions (historical — 4 entries)
Past predictions for assets that have already been analyzed. Test assets left clean for demo.

### Existing Work Orders (historical — 2 entries)
Past work orders for PUMP-B21-ND (currently in MAINTENANCE status).

### Alert History (historical — 2 entries)
Past alerts that have been acknowledged/resolved.

---

## REST API Specification

### API 1: GET /api/v1/assets/{asset_id}/sensor-data

Returns asset details joined with latest sensor readings.

**SQL:**
```sql
SELECT a.asset_id, a.asset_type, a.well_site_id, a.description, a.status,
       sr.reading_timestamp, sr.vibration_rms, sr.temperature_c,
       sr.pressure_psi, sr.flow_rate, sr.power_consumption
FROM assets a
LEFT JOIN sensor_readings sr ON a.asset_id = sr.asset_id
WHERE a.asset_id = '{asset_id}'
ORDER BY sr.id DESC LIMIT 1;
```

**Response:**
```json
{
  "asset_id": "PUMP-W47-TX",
  "asset_type": "PUMP",
  "well_site_id": "WS-PERMIAN-001",
  "description": "Rod Pump Unit - Well #47",
  "status": "OPERATIONAL",
  "reading_timestamp": "2026-04-17T14:00:00Z",
  "vibration_rms": 4.8,
  "temperature_c": 98.5,
  "pressure_psi": 1150.0,
  "flow_rate": 95.2,
  "power_consumption": 45.3
}
```

---

### API 2: POST /api/v1/predictions

Stores a new AI-generated prediction.

**Request:**
```json
{
  "asset_id": "PUMP-W47-TX",
  "status": "WARNING",
  "confidence": "0.91",
  "days_to_failure": "12",
  "failure_mode": "bearing_wear",
  "recommended_action": "Schedule inspection within 72h. Monitor vibration trend.",
  "sensor_anomalies": "vibration_rms: 4.8g (threshold 3.5g), temp_delta: +18C above baseline"
}
```

**SQL:**
```sql
INSERT INTO predictions (asset_id, predicted_at, status, confidence, days_to_failure,
                         failure_mode, recommended_action, sensor_anomalies)
VALUES ('{asset_id}', NOW(), '{status}', {confidence}, {days_to_failure},
        '{failure_mode}', '{recommended_action}', '{sensor_anomalies}')
RETURNING prediction_id, asset_id, predicted_at, status, confidence, days_to_failure;
```

**Response:**
```json
{
  "prediction_id": 5,
  "asset_id": "PUMP-W47-TX",
  "predicted_at": "2026-04-17 14:22",
  "status": "WARNING",
  "confidence": 0.91,
  "days_to_failure": 12
}
```

---

### API 3: POST /api/v1/work-orders

Creates a maintenance work order.

**Request:**
```json
{
  "asset_id": "PUMP-W47-TX",
  "priority": "HIGH",
  "description": "Bearing wear detected. Schedule inspection within 72h.",
  "assigned_to": "Field Tech Team A",
  "scheduled_date": "2026-04-20"
}
```

**SQL:**
```sql
INSERT INTO work_orders (asset_id, priority, description, assigned_to, scheduled_date, created_at)
VALUES ('{asset_id}', '{priority}', '{description}', '{assigned_to}', '{scheduled_date}', NOW())
RETURNING work_order_id, asset_id, priority, assigned_to, scheduled_date, status;
```

**Response:**
```json
{
  "work_order_id": 3,
  "asset_id": "PUMP-W47-TX",
  "priority": "HIGH",
  "assigned_to": "Field Tech Team A",
  "scheduled_date": "2026-04-20",
  "status": "OPEN"
}
```

---

### API 4: POST /api/v1/alerts

Logs an alert notification.

**Request:**
```json
{
  "asset_id": "PUMP-W47-TX",
  "severity": "WARNING",
  "message": "Bearing wear detected on PUMP-W47-TX. Est. 12 days to failure. Confidence: 91%."
}
```

**SQL:**
```sql
INSERT INTO alert_history (asset_id, severity, message, sent_at)
VALUES ('{asset_id}', '{severity}', '{message}', NOW())
RETURNING alert_id, asset_id, severity, sent_at, status;
```

**Response:**
```json
{
  "alert_id": 3,
  "asset_id": "PUMP-W47-TX",
  "severity": "WARNING",
  "sent_at": "2026-04-17 14:22",
  "status": "SENT"
}
```

---

## MCP Server Tools (Read-Only — 6 tools)

| Tool Name | Description | SQL |
|---|---|---|
| GetAssets | Get all assets with type, well site, and status | `SELECT * FROM assets` |
| GetSensorReadings | Get all sensor readings with timestamps | `SELECT * FROM sensor_readings ORDER BY id DESC` |
| GetPredictions | Get all AI predictions with status and confidence | `SELECT * FROM predictions ORDER BY prediction_id DESC` |
| GetWorkOrders | Get all work orders with priority and status | `SELECT * FROM work_orders ORDER BY work_order_id DESC` |
| GetAlertHistory | Get all alert notifications with severity | `SELECT * FROM alert_history ORDER BY alert_id DESC` |
| GetWellSites | Get all well sites with location and region | `SELECT * FROM well_sites` |

---

## Demo Test Prompts

### Single Agent Tests

**1. Sensor data retrieval only:**
```
Show me the latest sensor readings for pump PUMP-W47-TX
```
Expected: Invokes sensor_analysis_agent → returns vibration 4.8g, temp 98.5°C, etc.

**2. Read-only query (MCP tools only):**
```
List all assets and their current status
```
Expected: Uses MCP GetAssets tool, no sub-agents invoked.

**3. Work order only:**
```
Create a HIGH priority work order for COMP-W12-OK — compressor overheating, assign to Field Tech Team B, schedule for 2026-04-19
```
Expected: Invokes work_order_agent only.

### Multi-Agent Tests

**4. Analyze + Predict:**
```
Analyze the sensor readings for PUMP-W47-TX and generate a health prediction
```
Expected: sensor_analysis_agent → orchestrator analyzes (WARNING, bearing_wear) → prediction_agent stores result.

**5. Full health check:**
```
Run a full health check on COMP-W12-OK — analyze sensors, store prediction, create work order if critical, and send alert
```
Expected: sensor_analysis_agent → prediction_agent (CRITICAL) → work_order_agent (URGENT) → alert_notification_agent.

**6. Full check on healthy asset:**
```
Run a full health check on VALVE-W03-NM
```
Expected: sensor_analysis_agent → prediction_agent (NORMAL) → NO work order → NO alert. Agent should state no action needed.

### Edge Cases

**7. Asset not found:**
```
Analyze sensor readings for PUMP-X99-UNKNOWN
```
Expected: Gracefully reports asset not found.

**8. Out of scope:**
```
What is the current oil price per barrel?
```
Expected: Politely declines — outside scope of predictive maintenance.

---

## Orchestrator System Prompt (Draft)

```
You are the Predictive Maintenance Orchestrator Agent for oilfield operations.
You coordinate asset health monitoring across distributed well sites with pumps,
compressors, and wellhead valves.

You manage four sub-agents:
- sensor_analysis_agent: retrieves latest sensor readings for an asset
- prediction_agent: stores AI health predictions
- work_order_agent: creates maintenance work orders
- alert_notification_agent: sends alert notifications

INTENT ANALYSIS:
Before invoking any sub-agent, analyze the operator's request:
- "Show sensor readings for X" → invoke sensor_analysis_agent only
- "List all assets / predictions / work orders" → use MCP tools only (read-only)
- "Analyze and predict health of X" → sensor_analysis_agent → you analyze → prediction_agent
- "Create work order for X" → work_order_agent only
- "Send alert for X" → alert_notification_agent only
- "Full health check for X" → sensor_analysis_agent → analyze → prediction_agent → work_order_agent (if WARNING/CRITICAL) → alert_notification_agent (if WARNING/CRITICAL)

SENSOR ANALYSIS (your AI reasoning):
When you receive sensor readings from sensor_analysis_agent, YOU must analyze them:

Thresholds:
- Vibration RMS: NORMAL < 3.5g, WARNING 3.5-6.0g, CRITICAL > 6.0g
- Temperature: NORMAL < 85°C, WARNING 85-105°C, CRITICAL > 105°C
- Pressure PSI: NORMAL 800-1200, WARNING 600-800 or 1200-1500, CRITICAL < 600 or > 1500
- Flow Rate: NORMAL 80-120 bbl/hr, WARNING 60-80 or 120-140, CRITICAL < 60 or > 140

Classification: Use the WORST single sensor reading to determine overall status.
Confidence: Base on how many sensors are anomalous (1=0.75, 2=0.85, 3=0.92, 4=0.97).
Days to failure: CRITICAL=3-7 days, WARNING=10-21 days, NORMAL=90+ days.
Failure modes: bearing_wear, overheating, seal_leak, pressure_anomaly, flow_blockage, electrical_fault.

WORKFLOW FOR FULL HEALTH CHECK:
Step 1: Invoke sensor_analysis_agent with asset_id. Wait for completion.
Step 2: Analyze the returned sensor data using the thresholds above.
Step 3: Invoke prediction_agent to store your analysis. Wait for completion.
Step 4: If status is WARNING or CRITICAL, invoke work_order_agent. Set priority=URGENT for CRITICAL, HIGH for WARNING. Schedule 1-3 days for CRITICAL, 3-7 days for WARNING. Assign to "Field Tech Team A" for Permian, "Field Tech Team B" for Bakken, "Field Tech Team C" for Eagle Ford. Wait for completion.
Step 5: If status is WARNING or CRITICAL, invoke alert_notification_agent with severity and detailed message. Wait for completion.

CRITICAL RULES:
- Never invoke alert_notification_agent for NORMAL status assets
- Never invoke work_order_agent for NORMAL status assets
- Invoke alert_notification_agent at most ONCE per conversation
- Always store a prediction via prediction_agent after analyzing sensors

MCP TOOLS:
Use MCP tools for read-only queries: listing assets, viewing sensor history, checking existing predictions/work orders. Never use MCP tools for creating or modifying records.

RESPONSE FORMATTING:
Structure your response with clear section headers:

**Asset Sensor Data** — Asset ID, type, well site, latest readings
**Health Analysis** — Status classification, confidence, days to failure, failure mode, anomalies detected
**Prediction Stored** — Prediction ID, confirmation
**Work Order Created** — Work order ID, priority, assigned technician, scheduled date (only if WARNING/CRITICAL)
**Alert Sent** — Alert ID, severity, confirmation (only if WARNING/CRITICAL)

Use professional, concise language suitable for field operations. Include specific numbers and thresholds in the analysis.

SCOPE:
You only handle predictive maintenance — sensor analysis, health predictions, work orders, and alerts. Politely decline requests about oil prices, billing, HR, production quotas, or anything outside asset health monitoring.
```

---

## Files to Create

| File | Description |
|---|---|
| `database.sql` | DDL: CREATE tables |
| `reset_data.sql` | Seed data: well sites, assets, sensor readings, historical predictions/work orders/alerts |
| `api-spec.json` | OpenAPI 3.0 spec for the 4 REST API endpoints |
| `predictive-maintenance-mcp-server.flogo` | MCP Server app with 6 read-only tools |
| `predictive-maintenance-api.flogo` | REST API service with 4 endpoints |
| `predictive-maintenance-agent.flogo` | Agentic AI orchestration app with 4 sub-agents |
| `agentic-chatbot.html` | WebSocket chat UI (copy from Hospital use case) |
| `prompts.md` | Test prompts for demo |

---

## Startup Order

1. Start PostgreSQL, create `predictive_maintenance` database, run `database.sql` then `reset_data.sql`
2. Start **MCP Server** (port 9093) — `predictive-maintenance-mcp-server.flogo`
3. Start **REST API Service** (port 9095) — `predictive-maintenance-api.flogo`
4. Start **Agentic AI Orchestration** (port 8083) — `predictive-maintenance-agent.flogo`
5. Start the chatbot UI:
   ```bash
   cd demos/Agentic_AI/Chatbot
   npm install
   npm start
   ```
   Open http://localhost:3000, paste `ws://localhost:8083/ws/chat` in the WebSocket URL field, and click **Connect**

---

## Key Differences from Hospital Use Case

| Aspect | Hospital | Predictive Maintenance |
|---|---|---|
| Domain | Patient discharge coordination | Oilfield asset health monitoring |
| AI Role | Route and coordinate | **Analyze sensor data + classify + predict** |
| Data Source | Static discharge records | Time-series sensor readings |
| Orchestrator Analysis | Passes data between agents | **Performs sensor threshold analysis itself** |
| Write Operations | Book appointments, order meds, clean beds | Store predictions, create work orders, send alerts |
| Entry Point | WebSocket chat | WebSocket chat (+ future Kafka consumer) |
