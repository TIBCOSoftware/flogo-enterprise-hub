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

It starts by asking you about your domain, but only about what you haven't already told it. That way
the demo reflects your business, not a generic guess. Expect up to three short rounds:

| Round | What it asks |
|---|---|
| 1. Context | the business problem and what success looks like; the audience and region (language, currency, regulations); who chats (customer, employee agent-assist, partner, technician); your product/service vocabulary; the organisation and assistant name |
| 2. Who and what | the persona; how they prove who they are; what they look up; what they can change; the one fuzzy judgment the AI agent makes; which requests a person must decide |
| 3. Rules, demo and runtime | the rules, limits and prices behind each action; multi-step requests; the demo storyline and logins; data the user must never see; the rule a prompt injection should attack; email yes/no; the runtime LLM; how far to test |

Answer "you decide" to anything you'd rather it draft. Those answers show up as **Assumptions** in the
plan, so you can still correct them. If you name a real customer or prospect to tailor the demo, the
skill uses a fictional organisation and never writes that name into any file.

It then shows you "What I heard", the assumptions, the classification table and the plan. **It builds
nothing until you approve.**

### Answering up front (optional)

To skip most of the questions, put the answers in your first message:

```
Use the agentic-ai-use-case-builder skill to build a use case.
Business problem / audience / region: <what it should solve, who watches, country>
Persona and identity: <who chats; identifier + one-time code>
Reads: <what they look up>
Actions and their rules: <what they can change; limits, prices, what blocks it>
The one fuzzy step (the A2A agent): <the genuinely semantic judgment>
Human-owned requests: <what a person must decide, and which team>
Demo storyline: <the happy path and the "wow" moment>
Email: <yes / no>
Runtime model: gpt-5.5            # capable tool-calling model; NOT gpt-5-nano
Run the full test ladder through the chat e2e.
```

Approve the plan with *"Approved — build it."* When it's done, it scrubs the secrets, writes the
customer-facing README and gives you the test results plus the chatbot steps. It doesn't commit unless
you ask.

## What you get

`samples/Agentic_AI/Industry_Use_Cases/<UseCase>_Use_Case/` (or your apps folder) containing:

| File | Purpose |
|---|---|
| `database.sql` / `reset_data.sql` | schema, **rule functions**, seeds (one row per reason code) / reset |
| `<Prefix>MCPServer.flogo` | scoped-read, guarded-write, two-step and review-case tools |
| `<Prefix>Agents.flogo` | the reasoning agent(s): read-only, minimised input (no identity), one PostgreSQL reference tool each (reference tables only, no personal data) |
| `<Prefix>AIOrchestrator.flogo` | WebSocket chat, AI Agent, per-connection memory |
| `README.md` | customer-facing: **"Why an agent here?"**, architecture, prerequisites, numbered steps to run, demo logins and script, troubleshooting |
| `prompts.md` | demo and adversarial prompts |
| `chat_e2e_transcript.md` | sanitized evidence from the last end-to-end run |
| `_rebuild/` | `tool_spec.py` (single source of truth), fda drivers, `test_rules.py`, `mcp_smoke.py`, `a2a_smoke.py`, `chat_e2e.py` |
| `_rebuild/README.md` | developer guide: what each artifact does, settings, how to regenerate the apps, test-ladder commands |

## The test ladder

| Step | What it proves |
|---|---|
| 1 `test_rules.py` | every SQL rule and reason code, using the exact tool SQL, plus the agents' reference tables (no personal data, lookups, every code explained) |
| 2 `validate_governed_apps.py` | wiring + governance: scoped reads, guarded writes, prompt hygiene, temperature, conn refs, WebSocket headers/conversationId, MCP hint booleans, secrets, A2A agents with a PostgreSQL reference tool |
| 3 `mcp_smoke.py` | the rules hold at the MCP edge in the real Flogo runtime, no LLM |
| 3b `a2a_smoke.py` | each A2A agent answers on its port, queries its reference table, and uses its text |
| 4 `chat_e2e.py` | the whole system through a real chat, with assertions on DB state |

## Prerequisites

**Design + SQL rule tests (steps 1–2)** need the Flogo Design CLI (`fda` — it ships inside the TIBCO
Flogo VS Code extension 2.26.7+, downloadable from the [TIBCO downloads page](https://www.tibco.com/downloads/11810);
nothing separate to install), PostgreSQL 14+ and `psql`, Python 3.9+, an LLM API key for a capable
tool-calling model (`gpt-5.5` class — nano-class models drop tool calls), and
`skills-library/.claude/skills/config.md`. **Only when you ask for the build / e2e steps (3–4)** you also
need `flogobuild` (the Flogo App Build CLI — from the same [TIBCO downloads page](https://www.tibco.com/downloads/11810),
not bundled in the VS Code extension; run `flogobuild list-context` for the context name) and the
[Go runtime](https://go.dev/dl/) (building Flogo apps requires Go); the chat e2e also needs Node.js 16+
(shared chatbot) and `pip install websocket-client`. `tibcop` is needed only if you deploy. For the
clone-and-adapt method you also need a governed reference app to clone from `samples/Agentic_AI/Industry_Use_Cases/`.

The full tiered table (versions, install sources, build-context creation, licence, Git Bash, `tibcop`,
SMTP) is in [AGENT.md → Prerequisites and preflight](../../../AGENT.md#prerequisites-and-preflight).
**Run the preflight first** (from the repo root):

```bash
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need db           # design + SQL rule tests
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need build,chat   # before steps 3-4
```

## Worked examples

- [Scholarly Publishing — Author Services](../../../../samples/Agentic_AI/Industry_Use_Cases/Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/README.md):
  authors verify with ORCID + a code, check status, get journal suggestions from an agent, see APC
  coverage computed in SQL, transfer a manuscript in two steps, and have fee waivers and appeals routed
  to people.
- [Airline Passenger Services — Meridian](../../../../samples/Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/README.md):
  travellers verify with PNR + a PIN, check flight status and **connection risk (computed in SQL, not
  guessed)**, get agent-ranked rebooking options, rebook in two confirmed steps, email the confirmation,
  and have compensation / baggage / name-change requests routed to people. Converted from the
  (ungoverned) Part-2 Airline demo without touching it.

### Sample prompt (the airline example)

This is the one-message spec that produces the Meridian airline sample:

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
Run the full test ladder through the chat e2e.
```
