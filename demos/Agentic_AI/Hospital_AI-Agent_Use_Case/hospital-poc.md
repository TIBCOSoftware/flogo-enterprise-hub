#  Hospital Agentic AI POC
## Intelligent Post-Discharge & Bed Management System

**Version:** 1.0  
**Date:** January 2026  
**Platform:** TIBCO Platform with Claude AI Integration

---

## 1. Executive Summary

This POC demonstrates an agentic AI system that automates two critical hospital workflows:
- **Post-Discharge Coordination**: Automatically schedules follow-ups, processes prescriptions, and notifies patients
- **Bed Availability Optimization**: Orchestrates housekeeping and bed turnover to maximize capacity

The system showcases TIBCO's integration capabilities combined with AI-driven decision making.

---

## 2. Architecture Overview

### 2.1 Text-Based Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            HOSPITAL SYSTEM                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                     ORCHESTRATOR AGENT                                │  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Event Router: Discharge Event → Post-Discharge Agent          │  │  │
│  │  │                Bed Vacated Event → Bed Readiness Agent         │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                              │                                              │
│         ┌────────────────────┼────────────────────┐                        │
│         ▼                    ▼                    ▼                        │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐                  │
│  │ POST-       │     │ BED         │     │ NOTIFICATION│                  │
│  │ DISCHARGE   │     │ READINESS   │     │ AGENT       │                  │
│  │ AGENT       │     │ AGENT       │     │             │                  │
│  │             │     │             │     │ • Patient   │                  │
│  │ • Appt      │     │ • Housekeep │     │ • Staff     │                  │
│  │ • Meds      │     │ • Bed Mgmt  │     │ • Admission │                  │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘                  │
│         │                   │                   │                          │
│  └──────┴───────────────────┴───────────────────┴──────────────────────┘  │
│                              │                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        MCP TOOL LAYER                                 │  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │  │   get_discharge_summary                                        │  │  │
│  │  │   Maps to: GET /api/v1/patients/{id}/discharge-summary         │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                              │                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                      REST API LAYER (TIBCO)                          │  │
│  │                                                                       │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │  │
│  │  │ Discharge    │  │ Appointment  │  │ Pharmacy     │  │ Bed      │ │  │
│  │  │ Summary API  │  │ Booking API  │  │ Order API    │  │ Mgmt API │ │  │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘ │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                              │                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    BACKEND SYSTEMS                                    │  │
│  │   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐          │  │
│  │   │  EMR    │    │ Appt    │    │ Pharmacy│    │  Bed    │          │  │
│  │   │ System  │    │ System  │    │ System  │    │ System  │          │  │
│  │   └─────────┘    └─────────┘    └─────────┘    └─────────┘          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Component Summary

| Component | Count | Purpose |
|-----------|-------|---------|
| Orchestrator Agent | 1 | Routes events to appropriate sub-agents |
| Sub-Agents | 3 | Execute domain-specific workflows |
| MCP Tools | 1 | Abstracts EMR data access |
| REST APIs | 4 | Backend system integration |

---

## 3. Agent Definitions

### 3.1 Orchestrator Agent

```yaml
Agent: Orchestrator
Role: Central coordinator that receives hospital events and routes to appropriate sub-agents

Input:
  event_type: string  # "PATIENT_DISCHARGED" | "BED_VACATED"
  event_payload: object

Logic:
  IF event_type == "PATIENT_DISCHARGED":
    1. Extract patient_id from payload
    2. Call get_discharge_summary MCP tool
    3. Route to Post-Discharge Agent with discharge data
    4. Await completion, then trigger Notification Agent
  
  IF event_type == "BED_VACATED":
    1. Extract bed_id, ward_id from payload
    2. Route to Bed Readiness Agent
    3. Await completion, then trigger Notification Agent

Output:
  workflow_id: string
  status: "COMPLETED" | "FAILED"
  actions_taken: array
```

### 3.2 Post-Discharge Agent

```yaml
Agent: Post-Discharge Agent
Role: Coordinates follow-up appointments and medication refills after patient discharge

Input:
  patient_id: string
  discharge_summary:
    follow_up_required: boolean
    specialty: string
    medications: array
    discharge_date: string

Logic:
  Step 1 - Check Follow-Up Needs:
    IF follow_up_required == true:
      - Calculate preferred_date (discharge_date + 7 days)
      - Call Appointment Booking API
      - Store appointment_id
    ELSE:
      - Skip appointment booking
  
  Step 2 - Check Medication Needs:
    IF medications.length > 0:
      - Call Pharmacy Order API for each medication
      - Store order_ids
    ELSE:
      - Skip pharmacy processing
  
  Step 3 - Return Results:
    - Compile all booking/order confirmations
    - Return to Orchestrator

Output:
  patient_id: string
  appointment_booked: boolean
  appointment_id: string | null
  medications_ordered: boolean
  order_ids: array
```

### 3.3 Bed Readiness Agent

```yaml
Agent: Bed Readiness Agent
Role: Manages bed turnover workflow from vacancy to availability

Input:
  bed_id: string
  ward_id: string
  vacated_time: string

Logic:
  Step 1 - Notify Housekeeping:
    - Call Bed Management API (action: "REQUEST_CLEANING")
    - Store cleaning_request_id
    - Set bed status to "CLEANING_REQUESTED"
  
  Step 2 - Wait for Confirmation:
    - Poll Bed Management API every 30 seconds (max 5 attempts)
    - Check for status == "CLEANING_COMPLETE"
    - IF timeout: escalate to supervisor
  
  Step 3 - Update Bed Status:
    - Call Bed Management API (action: "MARK_AVAILABLE")
    - Confirm status == "AVAILABLE"
  
  Step 4 - Return Results:
    - Return bed availability confirmation

Output:
  bed_id: string
  ward_id: string
  status: "AVAILABLE" | "CLEANING" | "ESCALATED"
  ready_time: string
```

### 3.4 Notification Agent

```yaml
Agent: Notification Agent
Role: Sends appropriate notifications to patients, staff, and admission team

Input:
  notification_type: string  # "DISCHARGE_COMPLETE" | "BED_READY"
  recipient_type: string     # "PATIENT" | "STAFF" | "ADMISSION_TEAM"
  payload: object

Logic:
  IF notification_type == "DISCHARGE_COMPLETE":
    - Format patient-friendly message with:
      - Appointment date/time (if booked)
      - Medication pickup instructions
    - Send via  App push notification
  
  IF notification_type == "BED_READY":
    - Format staff notification with:
      - Bed ID and Ward
      - Available since timestamp
    - Send to Admission Team dashboard
    - Log notification for audit

Output:
  notification_id: string
  delivered: boolean
  channel: string
  timestamp: string
```

---

## 4. MCP Tool Specification

### 4.1 get_discharge_summary

This MCP tool abstracts access to the EMR system, providing a clean interface for agents to retrieve patient discharge information.

```yaml
Tool Name: get_discharge_summary
Description: Retrieves the discharge summary for a patient from the EMR system
Maps To: GET /api/v1/patients/{patient_id}/discharge-summary

Request Schema:
  patient_id:
    type: string
    required: true
    description: Unique patient identifier
    example: "P-2024-00123"

Response Schema:
  patient_id:
    type: string
    description: Patient identifier (echoed back)
  
  follow_up_required:
    type: boolean
    description: Whether specialist follow-up is needed
  
  specialty:
    type: string
    description: Specialist department for follow-up
    enum: ["CARDIOLOGY", "NEUROLOGY", "ORTHOPEDICS", "GENERAL", "ONCOLOGY"]
  
  medications:
    type: array
    items:
      medication_code: string
      days_supply: integer
    description: List of medications to be dispensed
  
  discharge_date:
    type: string
    format: date
    description: Date of patient discharge

Example Request:
  {
    "patient_id": "P-2024-00123"
  }

Example Response:
  {
    "patient_id": "P-2024-00123",
    "follow_up_required": true,
    "specialty": "CARDIOLOGY",
    "medications": [
      {"medication_code": "MED001", "days_supply": 30},
      {"medication_code": "MED002", "days_supply": 14}
    ],
    "discharge_date": "2026-01-20"
  }

Error Handling:
  404: Patient not found
  400: Invalid patient_id format
```

#### MCP Tool Implementation (Pseudocode)

```python
@mcp_tool(name="get_discharge_summary")
def get_discharge_summary(patient_id: str) -> dict:
    """
    MCP tool that wraps the Discharge Summary REST API.
    Provides EMR access abstraction for AI agents.
    """
    # Validate input
    if not patient_id or not patient_id.startswith("P-"):
        raise ValueError("Invalid patient_id format")
    
    # Call REST API via TIBCO integration
    response = http_client.get(
        url=f"{EMR_BASE_URL}/api/v1/patients/{patient_id}/discharge-summary",
        headers={"Authorization": f"Bearer {get_service_token()}"}
    )
    
    # Transform response for agent consumption
    return {
        "patient_id": response["patient_id"],
        "follow_up_required": response["follow_up_required"],
        "specialty": response["specialty"],
        "medications": response["medications"],
        "discharge_date": response["discharge_date"]
    }
```

---

## 5. REST API Specifications

### 5.1 API 1: Discharge Summary API

```yaml
Endpoint: GET /api/v1/patients/{patient_id}/discharge-summary
Purpose: Retrieve patient discharge information from EMR
System: EMR Integration Layer

Request:
  Path Parameters:
    patient_id: string (required)
      description: Patient identifier
      example: "P-2024-00123"
      max_length: 20

Response (5 fields):
  {
    "patient_id": "P-2024-00123",
    "follow_up_required": true,
    "specialty": "CARDIOLOGY",
    "medications": [
      {"medication_code": "MED001", "days_supply": 30}
    ],
    "discharge_date": "2026-01-20"
  }

Field Definitions:
  | Field | Type | Description |
  |-------|------|-------------|
  | patient_id | string | Unique patient identifier |
  | follow_up_required | boolean | Follow-up appointment needed |
  | specialty | string | Department for follow-up |
  | medications | array | Prescribed medications |
  | discharge_date | string | ISO date of discharge |

MCP Mapping:
  Tool: get_discharge_summary
  Mapping: 1:1 direct pass-through
  Transform: None required
```

### 5.2 API 2: Appointment Booking API

```yaml
Endpoint: POST /api/v1/appointments
Purpose: Book specialist follow-up appointments
System: Appointment Management System

Request (4 fields):
  {
    "patient_id": "P-2024-00123",
    "specialty": "CARDIOLOGY",
    "preferred_date": "2026-01-27",
    "urgency": "ROUTINE"
  }

Field Definitions:
  | Field | Type | Required | Description |
  |-------|------|----------|-------------|
  | patient_id | string | Yes | Patient identifier |
  | specialty | string | Yes | Department code |
  | preferred_date | string | Yes | ISO date format |
  | urgency | string | No | ROUTINE/URGENT (default: ROUTINE) |

Response (5 fields):
  {
    "appointment_id": "APT-2026-00456",
    "patient_id": "P-2024-00123",
    "scheduled_date": "2026-01-28",
    "scheduled_time": "10:30",
    "status": "CONFIRMED"
  }

Field Definitions:
  | Field | Type | Description |
  |-------|------|-------------|
  | appointment_id | string | Unique appointment reference |
  | patient_id | string | Patient identifier |
  | scheduled_date | string | Actual booked date |
  | scheduled_time | string | Appointment time (HH:MM) |
  | status | string | CONFIRMED/PENDING/WAITLISTED |

Business Rules:
  - If preferred_date unavailable, book next available slot
  - Weekend dates auto-adjust to Monday
  - Maximum booking window: 30 days
```

### 5.3 API 3: Pharmacy Order API

```yaml
Endpoint: POST /api/v1/pharmacy/orders
Purpose: Process medication refill requests
System: Pharmacy Management System

Request (4 fields):
  {
    "patient_id": "P-2024-00123",
    "medication_code": "MED001",
    "days_supply": 30,
    "pickup_location": "PHARMACY_A"
  }

Field Definitions:
  | Field | Type | Required | Description |
  |-------|------|----------|-------------|
  | patient_id | string | Yes | Patient identifier |
  | medication_code | string | Yes | Medication reference |
  | days_supply | integer | Yes | Days of supply (7-90) |
  | pickup_location | string | No | Pharmacy location code |

Response (5 fields):
  {
    "order_id": "RX-2026-00789",
    "patient_id": "P-2024-00123",
    "medication_name": "Aspirin 100mg",
    "ready_by": "2026-01-21T14:00:00",
    "status": "PROCESSING"
  }

Field Definitions:
  | Field | Type | Description |
  |-------|------|-------------|
  | order_id | string | Prescription order reference |
  | patient_id | string | Patient identifier |
  | medication_name | string | Human-readable drug name |
  | ready_by | string | ISO datetime for pickup |
  | status | string | PROCESSING/READY/DISPENSED |

Business Rules:
  - Standard processing: 4 hours
  - Controlled substances: Additional verification required
  - Insurance validation automatic
```

### 5.4 API 4: Bed Management API

```yaml
Endpoint: POST /api/v1/beds/actions
Purpose: Manage bed status and housekeeping workflow
System: Bed Management System

Request (4 fields):
  {
    "bed_id": "BED-4A-012",
    "ward_id": "WARD-4A",
    "action": "REQUEST_CLEANING",
    "requested_by": "SYSTEM"
  }

Field Definitions:
  | Field | Type | Required | Description |
  |-------|------|----------|-------------|
  | bed_id | string | Yes | Unique bed identifier |
  | ward_id | string | Yes | Ward location code |
  | action | string | Yes | REQUEST_CLEANING/MARK_AVAILABLE/GET_STATUS |
  | requested_by | string | No | Requester ID (default: SYSTEM) |

Response (5 fields):
  {
    "bed_id": "BED-4A-012",
    "ward_id": "WARD-4A",
    "status": "CLEANING_IN_PROGRESS",
    "updated_at": "2026-01-20T15:30:00",
    "estimated_ready": "2026-01-20T16:00:00"
  }

Field Definitions:
  | Field | Type | Description |
  |-------|------|-------------|
  | bed_id | string | Bed identifier |
  | ward_id | string | Ward location |
  | status | string | OCCUPIED/VACANT/CLEANING_REQUESTED/CLEANING_IN_PROGRESS/AVAILABLE |
  | updated_at | string | Last status change timestamp |
  | estimated_ready | string | Projected availability time |

Status Flow:
  OCCUPIED → VACANT → CLEANING_REQUESTED → CLEANING_IN_PROGRESS → AVAILABLE
```

---

## 6. End-to-End Scenarios

### 6.1 Scenario 1: Post-Discharge Coordination

**Trigger:** Patient P-2024-00123 is discharged from Ward 4A

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ TIMELINE: Post-Discharge Workflow                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│ 15:00:00  ┌─────────────────────────────────────────────────────────────┐  │
│           │ EVENT: PATIENT_DISCHARGED                                    │  │
│           │ {"patient_id": "P-2024-00123", "ward_id": "WARD-4A"}        │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:01  ┌─────────────────────────────────────────────────────────────┐  │
│           │ ORCHESTRATOR: Receives discharge event                       │  │
│           │ Action: Route to Post-Discharge Agent                        │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:02  ┌─────────────────────────────────────────────────────────────┐  │
│           │ MCP TOOL: get_discharge_summary("P-2024-00123")             │  │
│           │ API Call: GET /api/v1/patients/P-2024-00123/discharge-summary│  │
│           │ Response: {                                                  │  │
│           │   "follow_up_required": true,                                │  │
│           │   "specialty": "CARDIOLOGY",                                 │  │
│           │   "medications": [{"medication_code": "MED001", ...}],      │  │
│           │   "discharge_date": "2026-01-20"                            │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:03  ┌─────────────────────────────────────────────────────────────┐  │
│           │ POST-DISCHARGE AGENT: Analyze discharge summary              │  │
│           │ Decision: Follow-up required = YES                           │  │
│           │ Decision: Medications to order = 1                           │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:04  ┌─────────────────────────────────────────────────────────────┐  │
│           │ API CALL: POST /api/v1/appointments                         │  │
│           │ Request: {                                                   │  │
│           │   "patient_id": "P-2024-00123",                             │  │
│           │   "specialty": "CARDIOLOGY",                                 │  │
│           │   "preferred_date": "2026-01-27",                           │  │
│           │   "urgency": "ROUTINE"                                       │  │
│           │ }                                                            │  │
│           │ Response: {                                                  │  │
│           │   "appointment_id": "APT-2026-00456",                        │  │
│           │   "scheduled_date": "2026-01-28",                           │  │
│           │   "scheduled_time": "10:30",                                 │  │
│           │   "status": "CONFIRMED"                                      │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:05  ┌─────────────────────────────────────────────────────────────┐  │
│           │ API CALL: POST /api/v1/pharmacy/orders                      │  │
│           │ Request: {                                                   │  │
│           │   "patient_id": "P-2024-00123",                             │  │
│           │   "medication_code": "MED001",                               │  │
│           │   "days_supply": 30,                                         │  │
│           │   "pickup_location": "PHARMACY_A"                            │  │
│           │ }                                                            │  │
│           │ Response: {                                                  │  │
│           │   "order_id": "RX-2026-00789",                               │  │
│           │   "medication_name": "Aspirin 100mg",                        │  │
│           │   "ready_by": "2026-01-21T14:00:00",                         │  │
│           │   "status": "PROCESSING"                                     │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:06  ┌─────────────────────────────────────────────────────────────┐  │
│           │ NOTIFICATION AGENT: Send patient confirmation               │  │
│           │ Channel:  App Push Notification                          │  │
│           │ Message:                                                     │  │
│           │ ┌─────────────────────────────────────────────────────────┐ │  │
│           │ │ 🏥  Discharge Summary                               │ │  │
│           │ │                                                         │ │  │
│           │ │ Your follow-up appointment:                             │ │  │
│           │ │ 📅 28 Jan 2026 at 10:30 AM                              │ │  │
│           │ │ 🏢 Cardiology Department                                │ │  │
│           │ │                                                         │ │  │
│           │ │ Your medication:                                        │ │  │
│           │ │ 💊 Aspirin 100mg (30 days supply)                       │ │  │
│           │ │ 📍 Ready for pickup at Pharmacy A                       │ │  │
│           │ │    by 21 Jan 2026, 2:00 PM                              │ │  │
│           │ └─────────────────────────────────────────────────────────┘ │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:00:07  ┌─────────────────────────────────────────────────────────────┐  │
│           │ ORCHESTRATOR: Workflow Complete                              │  │
│           │ Summary: {                                                   │  │
│           │   "workflow_id": "WF-2026-00123",                            │  │
│           │   "status": "COMPLETED",                                     │  │
│           │   "actions_taken": [                                         │  │
│           │     "DISCHARGE_SUMMARY_RETRIEVED",                           │  │
│           │     "APPOINTMENT_BOOKED",                                    │  │
│           │     "MEDICATION_ORDERED",                                    │  │
│           │     "PATIENT_NOTIFIED"                                       │  │
│           │   ]                                                          │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Outcome:** Patient receives complete discharge coordination within 7 seconds, with appointment booked and medication ordered automatically.

---

### 6.2 Scenario 2: Bed Availability Optimization

**Trigger:** Patient vacates Bed BED-4A-012 in Ward 4A

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ TIMELINE: Bed Readiness Workflow                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│ 15:30:00  ┌─────────────────────────────────────────────────────────────┐  │
│           │ EVENT: BED_VACATED                                           │  │
│           │ {"bed_id": "BED-4A-012", "ward_id": "WARD-4A"}              │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:30:01  ┌─────────────────────────────────────────────────────────────┐  │
│           │ ORCHESTRATOR: Receives bed vacated event                     │  │
│           │ Action: Route to Bed Readiness Agent                         │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:30:02  ┌─────────────────────────────────────────────────────────────┐  │
│           │ BED READINESS AGENT: Request housekeeping                    │  │
│           │ API CALL: POST /api/v1/beds/actions                         │  │
│           │ Request: {                                                   │  │
│           │   "bed_id": "BED-4A-012",                                    │  │
│           │   "ward_id": "WARD-4A",                                      │  │
│           │   "action": "REQUEST_CLEANING",                              │  │
│           │   "requested_by": "SYSTEM"                                   │  │
│           │ }                                                            │  │
│           │ Response: {                                                  │  │
│           │   "status": "CLEANING_REQUESTED",                            │  │
│           │   "estimated_ready": "2026-01-20T16:00:00"                   │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:30:03  ┌─────────────────────────────────────────────────────────────┐  │
│           │ NOTIFICATION AGENT: Alert housekeeping                       │  │
│           │ Channel: Staff Pager / Dashboard                             │  │
│           │ Message:                                                     │  │
│           │ ┌─────────────────────────────────────────────────────────┐ │  │
│           │ │ 🛏️ CLEANING REQUEST                                     │ │  │
│           │ │ Bed: BED-4A-012 | Ward: 4A                              │ │  │
│           │ │ Priority: STANDARD                                      │ │  │
│           │ │ Requested: 15:30                                        │ │  │
│           │ └─────────────────────────────────────────────────────────┘ │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:30:30  ┌─────────────────────────────────────────────────────────────┐  │
│  (Poll 1) │ BED READINESS AGENT: Check status                           │  │
│           │ API CALL: POST /api/v1/beds/actions (action: "GET_STATUS")  │  │
│           │ Response: {"status": "CLEANING_IN_PROGRESS"}                │  │
│           │ Decision: Continue waiting                                   │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:45:00  ┌─────────────────────────────────────────────────────────────┐  │
│           │ HOUSEKEEPING: Marks cleaning complete (external action)      │  │
│           │ Bed status updated to: CLEANING_COMPLETE                     │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:45:30  ┌─────────────────────────────────────────────────────────────┐  │
│  (Poll 2) │ BED READINESS AGENT: Check status                           │  │
│           │ API CALL: POST /api/v1/beds/actions (action: "GET_STATUS")  │  │
│           │ Response: {"status": "CLEANING_COMPLETE"}                   │  │
│           │ Decision: Proceed to mark available                          │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:45:31  ┌─────────────────────────────────────────────────────────────┐  │
│           │ BED READINESS AGENT: Update bed status                       │  │
│           │ API CALL: POST /api/v1/beds/actions                         │  │
│           │ Request: {                                                   │  │
│           │   "bed_id": "BED-4A-012",                                    │  │
│           │   "ward_id": "WARD-4A",                                      │  │
│           │   "action": "MARK_AVAILABLE",                                │  │
│           │   "requested_by": "SYSTEM"                                   │  │
│           │ }                                                            │  │
│           │ Response: {                                                  │  │
│           │   "status": "AVAILABLE",                                     │  │
│           │   "updated_at": "2026-01-20T15:45:31"                        │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:45:32  ┌─────────────────────────────────────────────────────────────┐  │
│           │ NOTIFICATION AGENT: Alert admission team                     │  │
│           │ Channel: Admission Dashboard                                 │  │
│           │ Message:                                                     │  │
│           │ ┌─────────────────────────────────────────────────────────┐ │  │
│           │ │ ✅ BED NOW AVAILABLE                                    │ │  │
│           │ │ Bed: BED-4A-012 | Ward: 4A                              │ │  │
│           │ │ Ready since: 15:45                                      │ │  │
│           │ │ Turnaround time: 15 minutes                             │ │  │
│           │ └─────────────────────────────────────────────────────────┘ │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│ 15:45:33  ┌─────────────────────────────────────────────────────────────┐  │
│           │ ORCHESTRATOR: Workflow Complete                              │  │
│           │ Summary: {                                                   │  │
│           │   "workflow_id": "WF-2026-00124",                            │  │
│           │   "status": "COMPLETED",                                     │  │
│           │   "actions_taken": [                                         │  │
│           │     "HOUSEKEEPING_NOTIFIED",                                 │  │
│           │     "CLEANING_CONFIRMED",                                    │  │
│           │     "BED_MARKED_AVAILABLE",                                  │  │
│           │     "ADMISSION_TEAM_NOTIFIED"                                │  │
│           │   ],                                                         │  │
│           │   "turnaround_minutes": 15                                   │  │
│           │ }                                                            │  │
│           └─────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Outcome:** Bed turnaround completed in 15 minutes with full automation, admission team immediately notified of availability.

---

## 7. Quick Reference Tables

### 7.1 Agent Quick Reference

| Agent | Trigger | Key Actions | Output |
|-------|---------|-------------|--------|
| **Orchestrator** | PATIENT_DISCHARGED, BED_VACATED | Route to sub-agents, track workflow | workflow_id, status |
| **Post-Discharge** | Discharge summary received | Book appointment, order meds | appointment_id, order_ids |
| **Bed Readiness** | Bed vacated event | Request cleaning, update status | bed status, ready_time |
| **Notification** | Workflow completion | Send push/dashboard alerts | notification_id |

### 7.2 API Quick Reference

| API | Method | Endpoint | Request Fields | Response Fields |
|-----|--------|----------|----------------|-----------------|
| Discharge Summary | GET | `/api/v1/patients/{id}/discharge-summary` | 1 (path param) | 5 |
| Appointment Booking | POST | `/api/v1/appointments` | 4 | 5 |
| Pharmacy Order | POST | `/api/v1/pharmacy/orders` | 4 | 5 |
| Bed Management | POST | `/api/v1/beds/actions` | 4 | 5 |

### 7.3 MCP Tool Quick Reference

| Tool Name | Maps To | Input | Output | Purpose |
|-----------|---------|-------|--------|---------|
| `get_discharge_summary` | GET /api/v1/patients/{id}/discharge-summary | patient_id | 5 fields | EMR access abstraction |

### 7.4 Event Types

| Event | Source | Payload | Triggers |
|-------|--------|---------|----------|
| PATIENT_DISCHARGED | EMR System | patient_id, ward_id | Post-Discharge workflow |
| BED_VACATED | Bed Management | bed_id, ward_id, vacated_time | Bed Readiness workflow |

### 7.5 Status Codes

| Domain | Statuses |
|--------|----------|
| Appointment | CONFIRMED, PENDING, WAITLISTED |
| Pharmacy | PROCESSING, READY, DISPENSED |
| Bed | OCCUPIED, VACANT, CLEANING_REQUESTED, CLEANING_IN_PROGRESS, AVAILABLE |
| Workflow | COMPLETED, FAILED, IN_PROGRESS |

---

## 8. TIBCO Integration Points

### 8.1 TIBCO Platform Components Used

| Component | Usage |
|-----------|-------|
| **TIBCO BusinessWorks** | API orchestration and backend integration |
| **TIBCO Cloud Integration** | REST API hosting and management |
| **TIBCO Messaging** | Event-driven triggers (PATIENT_DISCHARGED, BED_VACATED) |
| **TIBCO Data Virtualization** | EMR data access layer |

### 8.2 Integration Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    TIBCO PLATFORM                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐       │
│  │   TIBCO     │     │   TIBCO     │     │   TIBCO     │       │
│  │  Messaging  │────▶│ BusinessWorks│────▶│   Cloud     │       │
│  │  (Events)   │     │   (Logic)   │     │Integration  │       │
│  └─────────────┘     └─────────────┘     │  (APIs)     │       │
│                                          └──────┬──────┘       │
│                                                 │               │
│  ┌─────────────────────────────────────────────┴─────────────┐ │
│  │                    AI Agent Layer                          │ │
│  │   Claude AI + MCP Tools                                    │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 9. Demo Script

### 9.1 Demo Setup (5 minutes)
1. Show architecture diagram
2. Explain agent roles
3. Show API specifications

### 9.2 Demo 1: Post-Discharge (3 minutes)
1. Trigger PATIENT_DISCHARGED event
2. Watch orchestrator route to Post-Discharge Agent
3. Show MCP tool calling Discharge Summary API
4. Show appointment booking API call
5. Show pharmacy order API call
6. Display patient notification on mock  App

### 9.3 Demo 2: Bed Management (3 minutes)
1. Trigger BED_VACATED event
2. Watch orchestrator route to Bed Readiness Agent
3. Show housekeeping notification
4. Simulate housekeeping confirmation
5. Show bed status update
6. Display admission team notification

### 9.4 Wrap-up (2 minutes)
1. Highlight TIBCO integration value
2. Discuss scalability potential
3. Q&A

---

## 10. Appendix: Sample JSON Payloads

### 10.1 Event Payloads

```json
// PATIENT_DISCHARGED Event
{
  "event_type": "PATIENT_DISCHARGED",
  "timestamp": "2026-01-20T15:00:00Z",
  "payload": {
    "patient_id": "P-2024-00123",
    "ward_id": "WARD-4A",
    "discharge_type": "ROUTINE"
  }
}

// BED_VACATED Event
{
  "event_type": "BED_VACATED",
  "timestamp": "2026-01-20T15:30:00Z",
  "payload": {
    "bed_id": "BED-4A-012",
    "ward_id": "WARD-4A",
    "vacated_time": "2026-01-20T15:30:00Z"
  }
}
```

### 10.2 Complete API Request/Response Examples

```json
// Discharge Summary API - Response
{
  "patient_id": "P-2024-00123",
  "follow_up_required": true,
  "specialty": "CARDIOLOGY",
  "medications": [
    {"medication_code": "MED001", "days_supply": 30},
    {"medication_code": "MED002", "days_supply": 14}
  ],
  "discharge_date": "2026-01-20"
}

// Appointment Booking API - Request
{
  "patient_id": "P-2024-00123",
  "specialty": "CARDIOLOGY",
  "preferred_date": "2026-01-27",
  "urgency": "ROUTINE"
}

// Appointment Booking API - Response
{
  "appointment_id": "APT-2026-00456",
  "patient_id": "P-2024-00123",
  "scheduled_date": "2026-01-28",
  "scheduled_time": "10:30",
  "status": "CONFIRMED"
}

// Pharmacy Order API - Request
{
  "patient_id": "P-2024-00123",
  "medication_code": "MED001",
  "days_supply": 30,
  "pickup_location": "PHARMACY_A"
}

// Pharmacy Order API - Response
{
  "order_id": "RX-2026-00789",
  "patient_id": "P-2024-00123",
  "medication_name": "Aspirin 100mg",
  "ready_by": "2026-01-21T14:00:00",
  "status": "PROCESSING"
}

// Bed Management API - Request (Cleaning)
{
  "bed_id": "BED-4A-012",
  "ward_id": "WARD-4A",
  "action": "REQUEST_CLEANING",
  "requested_by": "SYSTEM"
}

// Bed Management API - Response
{
  "bed_id": "BED-4A-012",
  "ward_id": "WARD-4A",
  "status": "CLEANING_REQUESTED",
  "updated_at": "2026-01-20T15:30:02",
  "estimated_ready": "2026-01-20T16:00:00"
}
```

---

**Document Version:** 1.0  
**Last Updated:** January 2026  
**Author:** TIBCO AI Solutions Team
