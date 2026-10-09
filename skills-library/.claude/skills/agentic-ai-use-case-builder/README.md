# Agentic AI Use Case Builder for Flogo (governed by default) — User Guide

> Build an agentic AI demo where **the database decides and the agent reasons**. The skill first puts
> each operation through the Agentic AI decision framework, then builds the familiar three Flogo apps
> (WebSocket AI Orchestrator, MCP Server, A2A Agents). Identity, eligibility, prices and state changes
> are enforced in PostgreSQL. It proves all of that with a four-step test ladder that ends in a real
> chat, including a prompt-injection attempt.

## What it builds

This is the single, canonical skill for building agentic AI on Flogo — use it for **any** vertical
(telecom, airline, hospital, banking, retail, insurance, logistics, utilities, scholarly publishing, …).
It builds the familiar three Flogo apps (WebSocket AI Orchestrator + MCP Server + A2A Agents), backed by
PostgreSQL, with two build methods it **asks** you to choose between:

| | **FDA-CLI (recommended default)** | **Clone-and-adapt** |
|---|---|---|
| How apps are built | Built from scratch, command by command, with the Flogo Design CLI (`fda`) | Clone a **governed** reference `.flogo` and swap in your domain fields |
| Best when | you want a clean, auditable, from-scratch build | a near-identical governed reference app exists, or you need a custom-extension activity the FDA recipes don't cover (e.g. OpenAI vector/RAG) |

Governance is on by default either way: identity, eligibility, prices and state changes are enforced in
PostgreSQL, not in prompts, and proven by a four-step test ladder that ends in a real chat — including a
prompt-injection attempt.

## How to invoke it

- Slash command: `/agentic-ai-use-case-builder`, then describe the domain.
- Natural language: *"build a governed / production-grade / decision-framework agentic AI use case for
  &lt;vertical&gt;"*.

It will ask clarifying questions and show you the classification table and plan. **It builds nothing
until you approve.**

### Prompt templates (for a cheap, reliable build)

A governed build costs single-digit to low-double-digit dollars of agent tokens **when done in a fresh
session with the spec front-loaded and the e2e run once**; it balloons when done in a long session with
avoidable re-runs. See [SKILL.md → Cost & efficiency](SKILL.md#cost--efficiency). Give these four prompts:

**1. Start clean, then one message with the whole spec.** First `/clear` (or open a new session), then:

```
Use the agentic-ai-use-case-builder skill to build a governed use case.
Vertical / persona: <who the end user is>
Tools (reads + actions): <list>
The one semantic step (the A2A agent): <the genuinely fuzzy judgment>
Human-owned requests: <what a person must decide>
Email: <yes / no>
Runtime model: gpt-5.5            # capable tool-calling model; NOT gpt-5-nano
Ports: pick free ones
Run the full test ladder through the chat e2e.
Plan first; I'll approve in one pass — don't stop for small confirmations.
Use a subagent to read the reference sample/templates, and keep large command output out of context.
```

**2. Approve the plan** (when the classification table + plan appear):

```
Approved — build it. Cheap steps first; run the chat e2e once at the end.
```

**3. (optional) Drive the dev-model per phase** — or just toggle `/model` yourself:

```
Use Sonnet for the build and tests; Opus only for a hard bug; Haiku for the README/docs/scrub.
```

**4. Finish:**

```
Scrub secrets, write the customer-facing README, add the catalogue rows, and give me the test results
+ chatbot steps. Don't commit yet.
```

## What you get

`samples/Agentic_AI/Industry_Use_Cases/<UseCase>_Use_Case/` (or your apps folder) containing:

| File | Purpose |
|---|---|
| `database.sql` / `reset_data.sql` | schema, **rule functions**, seeds (one row per reason code) / reset |
| `<Prefix>MCPServer.flogo` | scoped-read, guarded-write, two-step and review-case tools |
| `<Prefix>Agents.flogo` | the reasoning agent(s): read-only, minimised input |
| `<Prefix>AIOrchestrator.flogo` | WebSocket chat, AI Agent, per-connection memory |
| `README.md` | customer-facing: **"Why an agent here?"**, architecture, prerequisites, numbered steps to run, demo logins and script, troubleshooting |
| `prompts.md` | demo and adversarial prompts |
| `chat_e2e_transcript.md` | sanitized evidence from the last end-to-end run |
| `_rebuild/` | `tool_spec.py` (single source of truth), fda drivers, `test_rules.py`, `mcp_smoke.py`, `chat_e2e.py` |

## The test ladder

| Step | What it proves |
|---|---|
| 1 `test_rules.py` | every SQL rule and reason code, using the exact tool SQL |
| 2 `validate_governed_apps.py` | wiring + governance: scoped reads, guarded writes, prompt hygiene, temperature, conn refs, WebSocket headers/conversationId, MCP hint booleans, secrets |
| 3 `mcp_smoke.py` | the rules hold at the MCP edge in the real Flogo runtime, no LLM |
| 4 `chat_e2e.py` | the whole system through a real chat, with assertions on DB state |

## Prerequisites

You need the Flogo Design CLI (`fda`), PostgreSQL + `psql`, an LLM API key, and
`skills-library/.claude/skills/config.md`. For steps 3–4 you also need `flogobuild` (run
`flogobuild list-context` for the context name) and `pip install websocket-client`. For the
clone-and-adapt method you also need a governed reference app to clone from
`samples/Agentic_AI/Industry_Use_Cases/`.

## Worked examples

- [Scholarly Publishing — Author Services](../../../../samples/Agentic_AI/Industry_Use_Cases/Scholarly_Publishing_Author_Services_Use_Case/README.md):
  authors verify with ORCID + a code, check status, get journal suggestions from an agent, see APC
  coverage computed in SQL, transfer a manuscript in two steps, and have fee waivers and appeals routed
  to people.
- [Airline Passenger Services — Meridian](../../../../samples/Agentic_AI/Industry_Use_Cases/Airline_Passenger_Services_Use_Case/README.md):
  travellers verify with PNR + a PIN, check flight status and **connection risk (computed in SQL, not
  guessed)**, get agent-ranked rebooking options, rebook in two confirmed steps, email the confirmation,
  and have compensation / baggage / name-change requests routed to people. Converted from the
  (ungoverned) Part-2 Airline demo without touching it.

### Sample prompt (the airline example)

This is the one-message spec (prompt 1 above) that produces the Meridian airline sample:

```
Use the agentic-ai-use-case-builder skill. Convert the Part-2 Airline Passenger Services demo into a
governed use case WITHOUT touching the original app, SQL or DB — new folder under Industry_Use_Cases/
and a new database.

Vertical / persona: airline traveller caught in a disruption (fictional carrier, ATL hub).
Identity: PNR + a 4-digit PIN -> session token; every read/write scoped to that booking.
Reads: my itinerary, a specific flight's status, loyalty standing.
Deterministic (SQL): connection risk (SAFE / AT_RISK / MISSED by arithmetic), rebooking eligibility
(route, seats, departs-after-inbound+min-connection), APC-style seat assignment.
Two-step action: rebook a disrupted leg (propose -> explicit yes -> confirm; event row + trigger).
The one semantic step (A2A agent): rank replacement flights against the traveller's free-text
preferences ("arrive before 8pm, window seat, no red-eye") — identity never passed to it.
Human-owned: compensation claims, baggage claims, special assistance, complaints, name changes.
Email: yes — a guarded tool that only emails an executed rebooking for the verified session.
Runtime model: gpt-5.5.  Ports: pick free ones.
Run the full test ladder through the chat e2e. Plan first; I'll approve in one pass.
```
