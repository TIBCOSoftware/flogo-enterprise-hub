> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# Publishing — Author Services Assistant

The **Author Services Assistant** is a chat assistant for the authors of a fictional scholarly publisher. An
author verifies who they are, checks where their manuscripts stand, turns the reviewer comments on a revision
into a checklist, gets suggestions for better-suited journals when a manuscript is declined with a transfer
offer, sees what they would pay under their institution's open-access agreement, has their submission
statements checked against the target journal's policy, and moves the manuscript in two confirmed steps. Fee
waivers, appeals, authorship changes, integrity questions and exceptions to a journal's statement policy go
to the right team, and **staff reviewers decide them in the same chatbot**. The assistant never decides those.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation, the journal matching,
the revision checklist and the statements check. PostgreSQL decides identity, eligibility, prices and every
change. People decide the exceptions.

> All publishers, journals, institutions, staff and people in this sample are fictional.

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Matching a manuscript's abstract to journals whose aims & scope fit, and explaining why | **AI agent** (`journal_match_agent`) | Free text against free text, with trade-offs (topic, method, word limit). A keyword filter misses "compound coastal flood risk" ↔ "storm surge and flood risk models". |
| Turning an editor's letter and reviewer comments into a revision checklist (MAJOR / MINOR / OPTIONAL, by comment type) | **AI agent** (`review_summary_agent`) | Reading free-text comments and judging what each asks for. The agent cites every comment and never invents one. |
| Comparing the author's data, ethics, funding, competing-interest and contribution statements with the target journal's policy | **AI agent** (`submission_check_agent`) | "Available on request" vs. "deposit with a DOI" is a judgment about wording. SQL adds its own presence check and records the result. |
| Understanding the request and chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning. |
| Identity, which manuscripts an author can see, transfer eligibility, fees, whether the statements block a transfer, moving the manuscript | **Database rules** | A model must not be able to talk its way into someone else's record, a different price or past a journal's policy. |
| Fee waivers, decision appeals, authorship changes, integrity questions, statements exceptions | **People** (staff reviewers) | Discretion and accountability. The reviewer decides in the chatbot; the database then applies the decision. |

Without the AI, status, fees and transfers would still work through a form. What you would lose is reading an
abstract, a set of reviewer comments or an author's statements and knowing what they mean.

## Architecture

```
Chat UI ──WebSocket :9840 /authorservices──► AuthorServicesAIOrchestrator  (AI Agent: authors + staff reviewers)
                                               │
                  MCP :9842 ◄──────────────────┤──────────────► A2A :9843 journal_match_agent
                  AuthorServicesMCPServer       │               A2A :9844 review_summary_agent
                  14 governed tools             │               A2A :9845 submission_check_agent
                          │                     │               AuthorServicesAgents (reference tables only)
                          └─────────────► PostgreSQL `author_services` ◄──┘
                                          rule functions · triggers · review teams · reviewers
```

| App | Port / path | What it does |
|---|---|---|
| `AuthorServicesAIOrchestrator.flogo` | WebSocket `9840` `/authorservices` | The assistant authors and staff reviewers chat with. Each browser connection is its own conversation. |
| `AuthorServicesMCPServer.flogo` | MCP `9842` `/author-services-mcp` | 14 governed tools: verify the author, list and show manuscripts, reviewer comments, check fees, record a submission check, propose and confirm a transfer, open and list review cases, and the reviewer tools (verify reviewer, review queue, review case, decide case). |
| `AuthorServicesAgents.flogo` | A2A `9843`, `9844`, `9845` | Three read-only agents: `journal_match_agent` (journals that fit an abstract), `review_summary_agent` (revision checklist) and `submission_check_agent` (statements vs. journal policy). Each reads **reference tables only** in PostgreSQL (the journal catalog, the peer-review guide, the journal statement policies), never sees who the author is and never changes anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (ORCID iD + fixed one-time code; staff ID + staff code). Before building anything like it for real
> authors or data, review and follow your own organization's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity | ORCID iD + one-time code → a session token valid for 60 minutes; a wrong code just returns `NOT_VERIFIED`. Staff reviewers sign in with a staff ID + code (5 wrong codes lock it for 15 minutes). Author and reviewer tokens are not interchangeable. |
| Rules in the database, not the prompt | transfer eligibility (`transfer_eval`), the statements gate, the APC quote (`apc_quote`) and what a reviewer may approve are computed in SQL; writes are guarded `INSERT … SELECT` |
| Per-author scoping | every read and write resolves the author from the session token; another author's manuscript or comments are "not found" |
| Data minimization | an integrity hold is never disclosed; the agents get the manuscript's title, abstract, keywords, comments or statements, never the author's identity or any id; reviewers see a first name and surname initial only |
| Statements checked before a transfer | the target journal's policy decides which statements are mandatory; SQL validates the agent's findings, adds its own presence check and records every check; an incomplete check blocks the transfer until the author fixes it or the editorial office grants an exception |
| Two-step confirm for state changes | `propose_transfer` → explicit yes → `confirm_transfer` (re-checks every rule; proposals expire after 15 minutes); reviewers restate and confirm every decision |
| Human-in-the-loop for discretion | fee waivers, appeals, authorship changes, integrity questions and statements exceptions → routed `review_cases`; a reviewer of that team decides within their approval limit, and approval runs the parked action (APC reduction, statements exception) through the same rules |
| Audit | sign-ins, proposals, transfers, submission checks, cases, decisions, APC reductions and exceptions are written to an audit table by database triggers |
| Resource limits | `rateLimit` + `tokenLimit` on every AI agent |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | claiming to be an editor or a reviewer changes nothing, because the rules and roles are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (or another provider the AI Agent supports).
- **Node.js** 16 or later, for the shared [Chatbot](../../../../Chatbot/) web client.

## Steps to run

### 1. Create the database

Run from this folder (`database.sql` loads `seed_data.sql` next to it):

```bash
createdb -U postgres author_services
psql -U postgres -d author_services -f database.sql
```

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files

Open each `.flogo` in VS Code and set these **App Properties**:

**`AuthorServicesMCPServer.flogo`**

| Property | Set to |
|---|---|
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` | your PostgreSQL server (default `localhost` / `5432` / `postgres`) |
| `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| `PostgreSQL.PostgresConn.Database_Name` | `author_services` |

**`AuthorServicesAgents.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your LLM API key |
| `AgenticAI.OpenAIConn.LLM_Provider` / `LLM_Base_URL` | `OpenAI` / leave empty for OpenAI, or your provider's endpoint |
| `LLM_Model` | a model your key can use (ships as `gpt-5.5`) |
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` / `Password` | ⚠️ the same values as the MCP Server (the agents only read the reference tables) |
| `PostgreSQL.PostgresConn.Database_Name` | ⚠️ `author_services` |

**`AuthorServicesAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? In the Agents app set `<agent>_PORT` together with `<agent>_URL` (`journal_match_agent`,
> `review_summary_agent`, `submission_check_agent`); in the MCP app `MCP_SERVER_PORT`; in the orchestrator
> `WebSocket_PORT` and the matching URL properties `AuthorServicesMCPServer_URL`
> (`http://localhost:9842/author-services-mcp`) and `journal_match_agent_URL` / `review_summary_agent_URL` /
> `submission_check_agent_URL` (`http://localhost:9843` / `9844` / `9845`).

### 3. Start the apps in this order

> **How to build and start these apps** (the same for every sample in this folder): see
> **[Running the Industry Use-Case samples »](../../../RUNNING_THE_SAMPLES.md#start-the-apps)** — the run
> prerequisites (Flogo App Build CLI + Go, or deploy to TIBCO Platform) and the exact build/run commands.
>
> Then start them in the order below, each in its own terminal:

**MCP Server (9842) → Agents (9843–9845) → Orchestrator (9840).** Wait for each one to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../../../Chatbot/). It needs
Node.js 16+.

```bash
cd ../../../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box at the top right, replace the default with **`ws://localhost:9840/authorservices`**.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it, and
   an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect** (↻ is refused while connected), check the URL, click **↻** again,
then **Connect**. Make sure the orchestrator is running on port 9840. The chatbot remembers the last URL
you applied, so a URL left over from another demo is a common cause.

### 5. Run the demo

Sign in as one of the demo authors. In a real portal the author would already be signed in; here they
type their ORCID iD and the code from a "verification email".

| Author | ORCID iD | Code | What they show |
|---|---|---|---|
| Dr. Maya Okafor | `0000-0002-1825-0097` | `482913` | 3 manuscripts; reviewer comments on MS-2026-0301 → revision checklist; MS-2026-0412 has a transfer offer and her agreement covers HCRL in full |
| Prof. Lars Eriksen | `0000-0004-7316-2588` | `771204` | an accepted paper whose agreement budget is used up, so a fee waiver goes to the Open Access Office |
| Dr. Elena Vasquez | `0000-0001-5109-3700` | `615204` | a transfer to EDSR blocked by the statements check (open data + competing interests); an exception goes to the editorial office |
| Dr. Ana Ribeiro | `0000-0003-1415-9269` | `305118` | a manuscript under an editorial hold: details hidden, transfer blocked |

The main walkthrough, as Maya:

1. *"Hi, I'd like help with my submissions. ORCID 0000-0002-1825-0097, code 482913."*
2. *"What manuscripts do I have and where are they?"*
3. *"Can you turn the reviewer comments on MS-2026-0301 into a revision checklist?"* — the review-summary agent
   groups the 7 comments by reviewer with MAJOR / MINOR / OPTIONAL and a comment type, and adds the publisher's
   response-letter advice.
4. *"MS-2026-0412 got a transfer offer. Which journals would fit it better?"* — the journal-match agent runs.
5. *"What would I pay to publish in HCRL?"* — covered in full, so she pays 0.
6. *"OK, please transfer MS-2026-0412 to HCRL."* — the submission-check agent compares her statements with HCRL's
   policy (complete), then the assistant shows the quote and asks for a yes.
7. *"Yes, I confirm."* — the transfer is made.
8. *"For MS-2026-0301 I think reviewer 2 misunderstood our method. I want to appeal."* — an appeal case goes to
   the Editorial Office.

The statements walkthrough, as Elena (new tab):

1. *"My ORCID iD is 0000-0001-5109-3700 and my code is 615204."*
2. *"MS-2026-0466 got a transfer offer. Please transfer it to EDSR."* — EDSR requires open data and a
   competing-interests statement: the check is **incomplete**, the assistant gives the policy's standard wording
   for each missing statement, and nothing moves.
3. Either add the statements (*"Our data and code are on Zenodo, DOI 10.5281/zenodo.8812466, and we declare no
   competing interests."*) and the transfer goes ahead, or *"Our data come from a commercial provider and cannot be
   deposited. Please ask the editorial office for an exception."* — a case goes to the Editorial Office.

### 6. Reviewer (human-in-the-loop)

Open a new tab and sign in as a staff reviewer: *"I'm publisher staff - a reviewer in the Open Access Office. My
staff ID is PUB-7001 and my code is 246810."*

| Reviewer | Staff ID | Code | Team | Approval limit | Try |
|---|---|---|---|---|---|
| Grace Whitfield | `PUB-7001` | `246810` | Open Access Office | $1,500.00 | Lars's $2,900 waiver (or Elena's seeded $1,850 one) → approving the full amount is **above her limit** (the case stays open for a senior reviewer); approving $1,200 reduces the APC by $1,200 |
| Samuel Osei | `PUB-7002` | `135790` | Open Access Office | $5,000.00 | approve Lars's waiver in full → he pays $0 |
| Helen Marsh | `PUB-7003` | `864209` | Editorial Office (handling editor) | — | Elena's statements exception → approve → the transfer to EDSR can go ahead; Lars's seeded appeal |
| Tom Becker | `PUB-7004` | `502468` | Editorial Office (authorship) | — | Elena's seeded authorship change |
| Rafael Duarte | `PUB-7005` | `719350` | Research Integrity Team | — | Ana's seeded integrity query |

The flow: *"Show me my queue."* → *"Open case RC-…"* → the assistant shows the author's statement, the facts from
the publisher's records and the AI-prepared brief (marked as unverified) → *"Approve the full waiver of $2,900.
Internal note: … . Message to the author: … ."* → the assistant restates the decision and asks you to
**confirm** → *"Confirm."* → the decision is recorded and the parked action runs (or, above your limit, the case
stays open for a senior reviewer). Then switch back to the author (new tab, sign in again) and ask *"What's the
status of my fee waiver request?"* — they see the outcome and your message, never your internal note or name. A
reviewer only ever sees their own team's queue; an author who claims to be a reviewer gets nothing without the
staff code.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos** (run from this folder):

```bash
psql -U postgres -d author_services -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the author or reviewer | Use the exact ORCID iD / staff ID and code from the tables. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it masks the ORCID and the codes. |
| "I can't reach the tools" or no journal suggestions / checklist | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's URL properties match their ports. |
| A checklist without the publisher's priorities, or a statements check without the standard wording | Check the Agents app's `PostgreSQL.PostgresConn.*` properties: the agents read their reference tables from `author_services`. |
| A transfer keeps saying the statements must be checked | Expected the first time for each target journal; the assistant runs the check and proposes again. A check is valid for 24 hours. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For providers other than OpenAI, set `LLM_Base_URL`. |
| A new browser tab asks to verify again | Expected: each connection is a separate conversation. |
| Transfer offer or dates look wrong | Reload `reset_data.sql`. Demo dates are relative to today. |
| Staff verification keeps failing with "locked" | After 5 wrong codes a staff ID is locked for 15 minutes. Wait, or reload `reset_data.sql` in dev. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).


---

<!-- SEO Keywords: Agentic AI Use Cases, MCP Use Cases, Build MCP Server, Zero-Code MCP Server, No-Code MCP Server, No-Code Agent Builder, Zero-Code Agent Builder, Best Integration Tool, Fastest Integration Tool, Most Performant Integration Tool, High-Performance Integration, Low-Code Integration, No-Code Integration, Agentic AI, AI Agents, MCP, MCP Server, Model Context Protocol, TIBCO Flogo, Governed AI, PostgreSQL, WebSocket, Enterprise Integration -->

**Hashtags:** #AgenticAI #AgenticAIUseCases #AIAgents #NoCodeAgentBuilder #MCP #MCPServer #ModelContextProtocol #ZeroCodeMCP #BuildMCPServer #LLMOrchestration #EnterpriseIntegration #TIBCOFlogo
