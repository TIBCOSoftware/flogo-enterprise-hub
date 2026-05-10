# Healthcare Patient Support Agent with HIPAA Compliance Guardrails

## Overview

This sample demonstrates an **AI-powered patient support assistant** built with the **TIBCO Flogo® Agentic AI Connector** and designed for **HIPAA compliance** from the ground up. It uses **OpenAI GPT-5.4** and showcases three advanced Agent Trigger features working together:

1. **Custom PHI Guardrail** — intercepts every LLM input and output to redact Protected Health Information (SSN, Date of Birth, Medical Record Numbers)
2. **Custom Conversation Store** — persists conversation history to the file system for audit trails (replace with a database in production)
3. **Custom Tool Handlers** — exposes appointment scheduling, clinic finding, and medication guidance as agent-callable Flogo flows

---

## Real-World Scenario

**Persona**: Maria, a patient who calls her healthcare provider's patient portal to ask about her upcoming appointment and a new prescription.

**Without this agent**: Maria must navigate a phone tree, wait on hold, and speak to three different departments.

**With this agent**:
```
Maria: "Hi, I need to know if Dr. Johnson has any open slots next Tuesday for cardiology."

Agent: [Calls CheckAppointmentSlots] "Dr. Johnson has openings at 9:00 AM, 11:30 AM, 
        and 2:00 PM next Tuesday in the Cardiology department. Would you like me to 
        reserve one of those times?"

Maria: "Also, my SSN is 123-45-6789 — do I need it to verify my identity?"

Agent: [PHI Guardrail REDACTS SSN before it reaches the LLM]
       "I want to make sure your sensitive information stays secure — please don't 
        share your Social Security Number in this chat. To verify your identity, 
        I'll ask for your date of birth and patient ID instead."
```

---

## Why This Architecture Matters for Healthcare

| Risk | Without Guardrails | With This Sample |
|---|---|---|
| Patient shares SSN in chat | SSN sent to LLM provider's servers | SSN **redacted** before leaving your environment |
| Patient shares DOB | DOB logged in LLM audit trail | DOB **masked** (****-**-**) in all logs |
| MRN leaked in LLM response | MRN visible in response | MRN **replaced** with `MRN-XXXXXXXX` |
| Conversation lost on restart | No session history | Persisted to file, survives restarts |
| No audit trail | No record of AI interactions | Every turn saved with timestamp |

---

## Architecture

```
Patient (WebSocket client)
         │  ws://localhost:9998/patient-support?sessionId=<id>
         ▼
┌─────────────────────────────────────────────────────┐
│  WebSocket Server Trigger  (port 9998)              │
│         │                                           │
│         ▼                                           │
│  callHealthcareAgent_flow                           │
│    └─ CallAgent Activity → HealthcarePatientAgent   │
│              │                                      │
│    ┌─────────┴──────────────────────────────┐       │
│    │       Agent Trigger Handlers           │       │
│    │  ① STORE   store_conversation_flow    │       │
│    │  ② GUARDRAIL  phi_guardrail_flow      │       │
│    │  ③ FETCH   fetch_conversation_flow    │       │
│    │  ④ OpenAI GPT-5.4 + Tool calls       │       │
│    │  ⑤ GUARDRAIL  phi_guardrail_flow      │       │
│    │  ⑥ STORE   store_conversation_flow    │       │
│    └────────────────────────────────────────┘       │
│         │                                           │
│         ▼                                           │
│  WebSocket Write Data → response to patient         │
└─────────────────────────────────────────────────────┘
         │
         ▼  conversations/{sessionId}.json  (per-session file)
```

---

## Per-Request Execution Sequence

Each patient message triggers handlers in this exact order (observed from runtime logs):

```
Patient sends message via WebSocket
         │
         ▼ (1) store_conversation_flow      STORE — user message
         │
         ▼ (2) phi_guardrail_flow           INPUT direction (isRequest = true)
                                              SSN/DOB/MRN redacted BEFORE message reaches LLM
         │
         ▼ (3) fetch_conversation_flow      FETCH — full session history supplied as LLM context
         │
         ▼ (4) OpenAI GPT-5.4              LLM processes, may invoke tools:
                  │
                  ├─ tool call → CheckAppointmentSlots_flow (or other tools)
                  ├─ store_conversation_flow  STORE — role=assistant (tool-call decision)
                  └─ store_conversation_flow  STORE — role=tool     (tool result)
                       (repeats for each tool the LLM calls)
         │
         ▼ (5) phi_guardrail_flow           OUTPUT direction (isRequest = false)
                                              SSN/DOB/MRN redacted from LLM response BEFORE sending to patient
         │
         ▼ (6) store_conversation_flow      STORE — final assistant response
         │
         ▼
Patient receives response via WebSocket
```

**Key takeaways from this sequence:**
- The **guardrail fires twice per turn** — once for the patient's outgoing message (INPUT), once for the LLM's incoming response (OUTPUT)
- The **conversation STORE fires at minimum twice per turn** (user message + final assistant response). When tools are called, it fires additional times — once for the LLM's tool-call decision (role=assistant) and once per tool result (role=tool). In a single-turn with 3 tools this is typically 4+ STORE calls.
- The **FETCH fires once per turn** — between the first STORE and the LLM call, supplying complete prior conversation as context
- On a **brand-new session**, the first STORE call's `ReadSessionFile` fails (file not yet created) and the error path automatically writes a new `{conversationId}.json`

---

## Features Demonstrated

| Feature | Detail |
|---|---|
| **Agent Trigger** | Hosts the patient support agent with full configuration |
| **OpenAI GPT-5.4** | Precise, nuanced responses suited to healthcare compliance scenarios |
| **Custom Guardrail** | Detects and redacts PHI on both LLM input AND output |
| **Custom Conversation Store STORE** | Reads existing per-session JSON, appends new message with HIPAA metadata via `array.append()`, writes back |
| **Custom Conversation Store FETCH** | Reads per-session JSON, returns full `messages[]` array for multi-turn context — no ID filter needed (per-session isolation) |
| **Custom Tool: CheckAppointmentSlots** | Returns available appointment times for a given doctor/department |
| **Custom Tool: FindNearestClinic** | Finds nearest clinics by ZIP code and specialty |
| **Custom Tool: GetMedicationGuide** | Returns safe, non-diagnostic medication guidance |
| **Default PII Guardrails** | Additional built-in protection layer (enabled alongside custom guardrail) |

---

## PHI Guardrail — How It Works

The custom guardrail handler intercepts **every** message going into and coming out of the LLM:

```
Patient → "My SSN is 123-45-6789 and my DOB is 1985-03-21"
                    ↓  [handler @conditional — SSN redacted before entering flow]
                    ↓  [phi_guardrail_flow — INPUT direction  (isRequest=true)  ← fires at step 2]
LLM receives      → "My SSN is XXX-XX-XXXX and my DOB is ****-**-**"

LLM responds      → "Based on DOB 1985-03-21, you are eligible for..."
                    ↓  [handler @conditional — SSN redacted before entering flow]
                    ↓  [phi_guardrail_flow — OUTPUT direction (isRequest=false) ← fires at step 5]
Patient sees      → "Based on DOB ****-**-**, you are eligible for..."
```

**Patterns redacted:**
| PHI Type | Pattern | Replacement |
|---|---|---|
| SSN | `\d{3}-\d{2}-\d{4}` | `XXX-XX-XXXX` |
| Date of Birth | `\d{4}-\d{2}-\d{2}` | `****-**-**` |
| Medical Record Number | `MRN-\d{6,10}` | `MRN-XXXXXXXX` |

---

## Custom Conversation Store — How It Works

This sample follows the **`AIAgentTrigger-custstore` reference pattern** — a per-session JSON file with `array.append()` for incremental growth. Each patient session gets its own isolated file:

```
conversations/
  demo.json         ← demo session (pre-seeded with 2 messages for testing)
  maria.json        ← auto-created on first message from sessionId=maria
```

Each file holds the full conversation as a structured JSON document:
```json
{
  "conversationId": "maria",
  "messages": [
    {
      "role": "user",
      "content": "Do you have cardiology slots Tuesday?",
      "metadata": {
        "sessionId": "maria",
        "channel": "websocket",
        "phiHandled": true,
        "dataClassification": "PHI_PROTECTED",
        "patientPortalVersion": "2.0"
      }
    },
    {
      "role": "assistant",
      "content": "Yes, Dr Johnson has openings at 9AM...",
      "metadata": { "sessionId": "maria", "channel": "websocket", "phiHandled": true, "dataClassification": "PHI_PROTECTED", "patientPortalVersion": "2.0" }
    }
  ]
}
```

### STORE flow (`store_conversation_flow`)
Pattern: **Read → ParseJSON → `array.append()` → Write**

> **Called multiple times per turn**: once to save the user message (before the LLM call), once for the final assistant response, and additionally for each tool-call decision (role=assistant) and tool result (role=tool) when the LLM invokes tools. See the [Per-Request Execution Sequence](#per-request-execution-sequence) above.

1. **ReadSessionFile** — reads `{ConversationDir}/{conversationId}.json`
2. **ParseSessionJSON** — parses existing `messages[]` array into a typed object
3. **WriteUpdatedSession** — writes `{conversationId, messages: array.append(existingMessages, newMessage)}` back to the same file (`overwrite: true`, dir auto-created)

The HIPAA metadata fields (`phiHandled`, `dataClassification`, etc.) are **enriched at the handler mapping level** before the message reaches the flow — ensuring every stored turn carries compliance context.

### FETCH flow (`fetch_conversation_flow`)
Pattern: **Read → ParseJSON → Return `messages[]`**

> **Called once per turn**: after the first STORE (user message) and before the LLM call — supplying the full prior conversation as context.

1. **ReadSessionFile** — reads the same per-session file
2. **ParseSessionJSON** — parses the messages array
3. **ReturnMessages** — returns the full `messages[]` array via `@foreach` — **no conversationId filter needed** because each file IS exactly one patient's conversation

> **Key improvement over single-file approach**: A single shared JSON file (like the reference `AI_CustSore.json`) stores all sessions and requires filtering by `conversationId` in the FETCH return expression. Per-session files eliminate that filter entirely — simpler, faster, and fully isolated for multi-patient environments.

### Starting a New Session
Each new `conversationId` is **fully automatic** — no seed file required. When the first message arrives for a new `sessionId`, the STORE flow's error path (`ReadSessionFile` fails → `WriteNewSession`) creates the `{sessionId}.json` file automatically. The `conversations/` directory is also auto-created on first write.

**In production**, replace the File Read/Write activities with:
- **JDBC** → read/write a PostgreSQL/MySQL `patient_sessions` table
- **InvokeRestService** → call a secure session storage API
- **Kafka** → publish to a compliance event stream

---

## Custom Tool Schemas

### CheckAppointmentSlots
```json
{
  "department": "string — e.g. Cardiology, Radiology, General Practice",
  "preferredDate": "string — ISO 8601 date, e.g. 2026-04-08",
  "doctorName": "string (optional) — e.g. Dr. Sarah Johnson"
}
```

### FindNearestClinic
```json
{
  "zipCode": "string — 5-digit ZIP code",
  "specialty": "string — e.g. Cardiology, Dermatology, Urgent Care",
  "maxDistanceMiles": "number (optional) — default 25"
}
```

### GetMedicationGuide
```json
{
  "medicationName": "string — medication name, e.g. Metformin, Lisinopril",
  "infoType": "string — SideEffects | Interactions | Dosage | Storage"
}
```

---

## Prerequisites

- **TIBCO Flogo® 2.26.2 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- OpenAI API key
- A `conversations/` directory writable by the Flogo app process

## Import the Sample

1. Open your Flogo workspace in VS Code.
2. Click on `HealthcarePatientAgent.flogo` in the Explorer to import it.

## Configure the LLM Connection

1. In the Flogo VS Code extension, open the **Connections** panel.
2. Find the `OpenAI_LLMProvider` connection and click **Edit**.
3. Enter your **OpenAI API Key**.
4. Save the connection.

## Understanding the Configuration

### Agent Trigger Settings
| Setting | Value | Notes |
|---|---|---|
| Agent Name | `HealthcarePatientAgent` | Referenced by the callagent activity |
| LLM Model | `gpt-5.4` | Accurate, policy-aware responses for healthcare interactions |
| Temperature | `0.4` | Balanced — creative enough for natural language, consistent for medical accuracy |
| Token Limit | `4096` | Handles complex medical conversations |
| Guardrails | `enabled` | Both default and custom PHI guardrail |
| Conversation Store | `Custom Store` | File-based for this sample; swap for DB in production |

### App Properties to Configure
| Property | Description |
|---|---|
| `AgenticAI.OpenAI_LLMProvider.API_Key` | Your OpenAI API key |
| `HealthcareAgent.ConversationDir` | Directory path for per-session conversation JSON files (default: `./conversations`). Each session creates `{conversationId}.json` here. Auto-created on first write. |

---

## Run the Application

### Start the App
Run `HealthcarePatientAgent` from VS Code. The WebSocket server starts on port `9998`.

### Connect and Chat

Use any WebSocket client to connect. Two popular options:

**Postman**: Create a new WebSocket request, set the URL to `ws://localhost:9998/patient-support?sessionId=maria`, and click Connect. Type messages in the message box and send.

**websocat** (command line):
```bash
# New session (auto-created on first message)
websocat "ws://localhost:9998/patient-support?sessionId=maria"

# Resume the included demo session (pre-seeded with 2 messages about chest discomfort)
websocat "ws://localhost:9998/patient-support?sessionId=demo"
```

The `sessionId` query parameter becomes the `conversationId` — it names both the in-memory conversation context and the per-session JSON file (`conversations/{sessionId}.json`).

> **`?sessionId=` is required.** If omitted, the Flogo Agent framework falls back to an internal event ID as the conversationId, producing a file with an unrecognizable name like `callhealthcareagent_flow_callhealthcareagent.json`.

> **Note on file location**: Flogo runs with the VS Code workspace root as its working directory, so `conversations/` resolves relative to that — not to the sample folder. This is expected runtime behavior.

### Example Session
```
> Hello, I need to book a cardiology appointment for next week.
< Hello! I'd be happy to help you schedule a cardiology appointment. 
  Let me check the available slots for next week...
  [CheckAppointmentSlots called]
  I found the following openings in our Cardiology department:
  - Tuesday, April 8: 9:00 AM, 11:30 AM, 2:00 PM
  - Wednesday, April 9: 10:00 AM, 3:30 PM
  Which time works best for you?

> My SSN is 123-45-6789, will you need that?
< I want to ensure your personal information stays secure. Please do not 
  share your Social Security Number in this chat. For appointment scheduling,
  I only need your patient ID and date of birth to verify your account.
```

---

## Extending This Sample

| Extension | How |
|---|---|
| Database conversation store | Replace File Read/Write with a JDBC activity connecting to a `patient_sessions` PostgreSQL table |
| Redis session store | Replace File Read/Write with InvokeRestService calling a Redis REST API (GET/SET by conversationId) |
| Add appointment booking | Add a `BookAppointment` tool that calls your EHR system's HL7 FHIR API |
| Integrate with Epic/Cerner | Replace mock Return activities in tool flows with InvokeRestService to FHIR R4 endpoints |
| Session auto-provisioning | Add a REST endpoint that pre-seeds a named `{conversationId}.json` with a system message or patient context on patient login |
| Multi-language support | Add a language detection step in the guardrail flow and inject `language` into the system prompt |
| Consent audit trail | Add a `RecordConsent` tool that appends a consent event to `{conversationId}.json` with a `consentGranted` metadata flag |
