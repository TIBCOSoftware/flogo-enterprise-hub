# Agentic AI Use Case Builder for Flogo — User Guide

> Build a working agentic AI chatbot demo for your industry on TIBCO Flogo, end to end: three Flogo apps,
> a PostgreSQL database, sample data, tests and a customer-facing README.
>
> The business rules live in the database, not in the AI's instructions:
> - who the user is and what they may see;
> - what an action costs, and whether it's allowed;
> - every change to a record.
>
> So the assistant can't be talked into breaking them. The AI agents do the work that genuinely needs AI:
> understanding free text, ranking options, classifying a request and explaining a result.

## What it builds

This is the skill for building agentic AI on Flogo, for **any** industry: banking, insurance, telecom,
utilities, healthcare, airlines, logistics, retail, high tech, real estate and so on. Every use case has
the same three Flogo apps, backed by PostgreSQL:

| App | What it does |
|---|---|
| `<Prefix>AIOrchestrator` | The chat: a WebSocket endpoint and an AI Agent that understands the request and calls the tools and agents. Customers and staff reviewers use the same chat |
| `<Prefix>MCPServer` | The tools. Each one runs a SQL function that checks the user's identity and the rules before it reads or changes anything. It includes the staff reviewer tools: a reviewer signs in, sees their team's queue, opens a case and approves or rejects it |
| `<Prefix>Agents` | One to three A2A reasoning agents, each doing one fuzzy job (for example "rank these flights against my preferences"). They never see who the user is, never write data, and read only reference tables with no personal data |

It **asks** you to choose between two build methods:

| | **FDA-CLI (recommended default)** | **Clone-and-adapt** |
|---|---|---|
| How apps are built | From scratch, command by command, with the Flogo Design CLI (`fda`) | Clone an existing sample's `.flogo` and swap in your domain |
| Best when | You want a clean, auditable build | A near-identical sample exists, or you need an activity the `fda` recipes don't cover (e.g. the OpenAI vector/RAG activities) |

Either way, the rules are enforced in the database and checked by [four test steps](#how-it-is-tested).
The last step is a real chat that includes a prompt-injection attempt.

## How to invoke it

- **Slash command:** `/agentic-ai-use-case-builder`, then describe your industry and use case.
- **Natural language:** *"build an agentic AI use case for &lt;industry&gt;"*.

It starts by asking about your domain, but only about what you haven't already told it, so the demo
reflects your business rather than a generic guess. Expect up to three short rounds:

| Round | What it asks |
|---|---|
| 1. Context | The business problem and what success looks like; the audience and region (language, currency, regulations); who chats (customer, employee, partner, technician); your product/service vocabulary; the organisation and assistant name |
| 2. Who and what | The persona; how they prove who they are; what they look up; what they can change; the fuzzy judgments the AI agents make; which requests a person must decide, which staff team decides them, how much each team may approve, and what an approval does |
| 3. Rules, demo and runtime | The rules, limits and prices behind each action; multi-step requests; the demo storyline and logins; data the user must never see; the rule a prompt injection should attack; email yes/no; the runtime LLM; how far to test |

**Ways to answer:**
- **"You decide":** it drafts the answer and lists it under **Assumptions** in the plan, so you can still correct it.
- **Naming a real customer or prospect:** if you name one to tailor the demo, it uses a fictional
  organisation and never writes the real name into any file.

**Before it builds,** it shows you "What I heard", the assumptions, which steps are done by the AI vs. the
database vs. a person, and the plan. **It builds nothing until you approve.**

### Answering up front (optional)

To skip most of the questions, put the answers in your first message:

```
Use the agentic-ai-use-case-builder skill to build a use case.
Business problem / audience / region: <what it should solve, who watches, country>
Persona and identity: <who chats; identifier + one-time code>
Reads: <what they look up>
Actions and their rules: <what they can change; limits, prices, what blocks it>
Fuzzy steps (1-3 A2A agents): <the genuinely semantic judgments, e.g. rank, classify, explain>
Human-owned requests: <what a person must decide, and which team>
Demo storyline: <the happy path and the "wow" moment>
Email: <yes / no>
Runtime model: gpt-5.5            # a capable tool-calling model; NOT gpt-5-nano
Run all four test steps, including the chat test.
```

Approve the plan with *"Approved — build it."* When the build finishes:
- **Results:** you get the test results and the steps to try it in the chatbot.
- **Credentials:** your live credentials stay in the apps so you can run them locally. They are replaced
  with placeholders only when you ask it to commit.
- **Commits:** it never commits unless you ask.

## What you get

A new folder at `samples/Agentic_AI/Industry_Use_Cases/<Industry>/<Sub_Category>/<UseCase>_Use_Case/`. The
industry and sub-category come from the skill's [industry list](references/industry-taxonomy.md); the
folder is created if it doesn't exist yet. It contains:

| File | Purpose |
|---|---|
| `database.sql` / `seed_data.sql` / `reset_data.sql` | Schema and the **rule functions** / demo data / reset between demos |
| `<Prefix>MCPServer.flogo` | The governed tools: scoped reads, checked writes, two-step changes (propose, then confirm), and cases that a staff reviewer decides in the same chat, within their team and approval limit. An approval runs the action, and the customer sees the outcome |
| `<Prefix>Agents.flogo` | The A2A reasoning agents, each with one read-only PostgreSQL reference tool |
| `<Prefix>AIOrchestrator.flogo` | The WebSocket chat, with a separate conversation memory per connection |
| `README.md` | Customer-facing: why an agent here, architecture, prerequisites, numbered steps to run, demo logins and script, the staff reviewer logins, troubleshooting |
| `prompts.md` | Demo prompts, including the ones that must be refused |
| `chat_e2e_transcript.md` | A sanitized transcript of the last chat test |
| `_rebuild/` | The scripts that build the apps and run the tests (see `_rebuild/README.md`) |

## How it is tested

The skill tests every build in four steps. The cheap ones run first, so the expensive chat test usually passes
in one go:

| Step | Script | What it proves |
|---|---|---|
| 1. SQL rules | `test_rules.py` | Every rule and reason code works on the real database: blocked actions write nothing, users only see their own data, a reviewer can only decide their own team's cases within their approval limit, and the agents' reference tables hold no personal data |
| 2. Static checks | `validate_governed_apps.py` | The three apps are wired correctly and follow the governance rules (no rules in prompts, scoped reads, checked writes, a complete reviewer loop, no live secrets at commit time) |
| 3. Smoke tests | `mcp_smoke.py`, `a2a_smoke.py` | The real Flogo apps enforce the same rules at the MCP edge (the reviewer tools too), and each A2A agent answers and reads its reference table. No chat yet |
| 4. Chat test | `chat_e2e.py` | A real end-to-end conversation through the chatbot, checking the database afterwards, including a prompt-injection attempt. A customer opens a case, a staff reviewer decides it in a separate chat, and the customer then sees the outcome |

Steps 1–2 need no LLM and no executables. Steps 3–4 build the apps as local executables and call your
LLM, so they run only when you ask for them.

## Prerequisites

**Run the preflight first.** It checks only what the step you choose needs, and tells you exactly what's
missing (run it from the repo root):

```bash
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need db           # design + test steps 1-2
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need build,chat   # test steps 3-4
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need deploy       # deploy to TIBCO Platform
```

| You want to | You need | Where to get it |
|---|---|---|
| **Design + test steps 1–2** | VS Code + TIBCO Flogo extension **2.26.7+** (includes `fda`, nothing separate to install) | [TIBCO downloads page](https://www.tibco.com/downloads/11810) or the VS Code Marketplace |
| | PostgreSQL **14+** and `psql` | [postgresql.org](https://www.postgresql.org/download/) |
| | Python **3.9+** | [python.org](https://www.python.org/downloads/) |
| | An LLM API key for a capable tool-calling model (`gpt-5.5` class; nano-class models drop tool calls) | your LLM provider |
| | Your settings in `skills-library/.claude/skills/config.md` | copy `config.example.md` and fill it in |
| **Test steps 3–4** (build + chat) | `flogobuild`, the Flogo App Build CLI (not in the VS Code extension), plus a build context (`flogobuild list-context`) | [TIBCO downloads page](https://www.tibco.com/downloads/11810) |
| | Go **1.25.7+** (building Flogo apps requires Go) | [go.dev/dl](https://go.dev/dl/) |
| | Node.js **16+** (for the shared chatbot) | [nodejs.org](https://nodejs.org/) |
| | `websocket-client` | `pip install websocket-client` |
| **Deploy** (optional) | `tibcop`, the TIBCO Platform CLI, plus a profile (`tibcop add-profile …`) | [TIBCO Platform CLI download page](https://www.tibco.com/downloads/12464); see the `flogo-deploy` skill |
| **Clone-and-adapt method** | A sample to clone from | `samples/Agentic_AI/Industry_Use_Cases/` |

Versions, build-context creation, the licence file, Git Bash on Windows and SMTP are covered in
[AGENT.md → Prerequisites and preflight](../../../AGENT.md#prerequisites-and-preflight).

## Worked examples

Fourteen finished use cases, all built with this skill, each with three AI agents, one-time-code sign-in
and a staff reviewer who decides what a person must decide:

| Industry | Sample | What the AI agents do |
|---|---|---|
| Banking | [Retail Banking Assistant](../../../../samples/Agentic_AI/Industry_Use_Cases/Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/README.md) | decode an unrecognized card charge; spot scam signs in a payment story; turn a hardship story into a brief |
| Banking | [Corporate Payments Investigation](../../../../samples/Agentic_AI/Industry_Use_Cases/Financial_Services/Banking/Corporate_Payments_Investigation_Use_Case/README.md) | explain a return code; match remittance notes to invoices; compare a payee name with the account name |
| Telecom | [Mobile Billing & Spend Control](../../../../samples/Agentic_AI/Industry_Use_Cases/Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case/README.md) | explain a bill jump; classify a charge; recommend a plan |
| Utilities | [Electric Outage & Billing](../../../../samples/Agentic_AI/Industry_Use_Cases/Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case/README.md) | explain a high bill; triage an outage report (hazard vs. routine); rank rate plans |
| Oil & Gas | [Oilfield Asset Health Monitoring](../../../../samples/Agentic_AI/Industry_Use_Cases/Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case/README.md) | triage a technician's field note; find similar past failures; write the shift handover |
| Healthcare | [Hospital Post-Discharge Care](../../../../samples/Agentic_AI/Industry_Use_Cases/Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/README.md) | write plain-language discharge instructions; flag home-medication conflicts for a pharmacist; rank follow-up slots |
| Airline | [Passenger Services](../../../../samples/Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/README.md) | rank rebooking options; turn a bag description into a claim; map assistance needs to standard codes |
| Logistics | [Parcel Delivery](../../../../samples/Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case/README.md) | rank delivery options; classify a damage claim; structure delivery instructions |
| High Tech | [Semiconductor Orders & RMA](../../../../samples/Agentic_AI/Industry_Use_Cases/High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case/README.md) | match a free-text part description; triage a failure report; explain a product change notice |
| Insurance | [Auto Policy & Claims (RAG)](../../../../samples/Agentic_AI/Industry_Use_Cases/Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case/README.md) | take a first notice of loss; check coverage against the policy wording; score a claim story for fraud signs |
| Insurance | [Life & Retirement Member Services](../../../../samples/Agentic_AI/Industry_Use_Cases/Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/README.md) | classify a claim story; build a life-event checklist; summarise an appeal for the examiner |
| Publishing | [Author Services](../../../../samples/Agentic_AI/Industry_Use_Cases/Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/README.md) | suggest better-suited journals; turn reviewer comments into a checklist; check submission statements against policy |
| Aerospace & Defense | [MRO AOG Operations](../../../../samples/Agentic_AI/Industry_Use_Cases/Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case/README.md) | triage a crew fault write-up; spot repeat defects; write the shift handover |
| Real Estate | [Lead Engagement](../../../../samples/Agentic_AI/Industry_Use_Cases/Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case/README.md) | rank listings against free-text wishes; read a lead's intent; screen Fair Housing-sensitive questions |

### Sample prompts

Plain-language prompts — no technical terms needed:

> *"Build a retail banking chat assistant. After a customer signs in, they can see their recent transactions, freeze a lost or stolen card, and dispute a charge they don't recognise. Anything that needs a person — a refund, a complaint, or a hardship request — should go to a staff member to approve. Make sure each customer can only ever see their own account. Then test it end to end."*
>
> *"Build a mobile phone customer-service chatbot. After a customer signs in, they can ask why this month's bill went up, cancel an add-on they didn't want, and set a monthly spending limit. Bigger things — a refund, closing the account, or a suspected-fraud case — should be handed to a support agent to decide. One customer must never be able to see another customer's account. Then test it end to end."*

Or hand it a fuller, more detailed spec in one message:

```
Use the agentic-ai-use-case-builder skill to build a use case.

Persona: an airline traveller caught in a disruption (fictional carrier, ATL hub), USA, USD.
Identity: booking reference (PNR) + a 4-digit PIN -> session; every read and write scoped to that booking.
Reads: my itinerary, a flight's status, my loyalty standing.
Rules in SQL: connection risk (SAFE / AT_RISK / MISSED, by arithmetic); rebooking eligibility (same route,
seats left, departs after the inbound arrives plus the minimum connection time).
Two-step action: rebook a disrupted leg (propose -> explicit yes -> confirm).
Fuzzy steps (A2A agents):
  1. rank replacement flights against the traveller's free-text preferences ("arrive before 8pm, no red-eye")
  2. turn a lost or damaged bag description into a structured claim
  3. map free-text assistance needs ("can't manage stairs") to standard assistance codes
Human-owned: compensation, baggage settlements, special-assistance confirmation, complaints, name changes.
Email: yes, for an executed rebooking only.
Runtime model: gpt-5.5.  Ports: pick free ones.
Run all four test steps, including the chat test.
```
