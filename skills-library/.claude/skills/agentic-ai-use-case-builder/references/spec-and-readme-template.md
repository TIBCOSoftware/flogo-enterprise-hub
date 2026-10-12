# Spec additions and README template for a governed use case

Start from this skill's base spec template,
[use-case-spec-template.md](use-case-spec-template.md), and add
the sections below. They are the governed parts: without them, the build falls back to "tools for
everything, rules in the prompt".

## Spec: add these sections

### 2b. Identity & scope
- Principal: <who the user is: author, customer, member …>
- Proof of identity (demo): <identifier> + <one-time code>. Production: <OAuth2/JWT claim in tokenInfo>
- Every read and write is scoped by the session token. List any record the user must **not** see even
  when it is theirs, such as internal holds, reviewer identities, or fraud flags.

### 3b. Decision-framework classification
The table from [decision-framework-gate.md](decision-framework-gate.md): every operation, Q1, Q2, owner.
There must be at least one **Agent** row, and normally at least one **Human** row.

### 4c. Rules (→ SQL functions)
| Rule | Inputs | Outcome codes | Seed row that triggers each code |
|---|---|---|---|
| <eligibility rule> | … | `OK`, `<REASON_1>`, `<REASON_2>` | … |

### 4d. Two-step actions
Name every state change the user might regret, and give each one a propose/confirm pair, an expiry,
and the quote shown to the user.

### 4e. Human-owned request types → teams
| request_type | team | reply time | examples |
|---|---|---|---|

### 7b. Adversarial acceptance
The chat e2e (testing-ladder.md step 4) must cover: an unverified visitor, a wrong code, another
user's record, a new connection, a human-owned request, and one prompt-injection attempt aimed at the
most valuable rule.

---

## README template

The README is for **customers and partners who want to run the demo**, so it explains what the demo is, why
it uses an agent, and how to run it. Keep build evidence out of it: test commands and results, retry counts,
negative tests, limitations, and a file inventory go into **your report to the user** (SKILL.md Phase 6),
not into the README. Fill in every port, path, property name and demo login from the built apps; never
leave a value the reader has to guess.

**Title and voice.** Title style is `# <Industry> — <What it does> Assistant` (e.g. `# Telecom — Mobile
Billing & Spend Control Assistant`). Put **no** assistant name and **no** "(Governed Agentic AI)" in the title;
introduce the assistant by name in the **first sentence** instead ("**Nova** is a chat assistant for …"). Use
US spelling throughout (organization, authorized, center, traveler, color).

```markdown
# <Industry> — <What it does> Assistant

**<Assistant name>** is a chat assistant for <who> (fictional **<Org>**). <1–2 more sentences: what they can
do. Name the human-owned requests and say the assistant never decides them.>

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation and <the fuzzy
step>. PostgreSQL decides <identity, eligibility, prices, every change>. People decide the exceptions.

> All <companies, people …> in this sample are fictional.

## Why an agent here?
<4-row table from decision-framework-gate.md: the fuzzy step (AI agent), the conversation (AI agent),
the rules (database), the exceptions (people); then the "without the AI …" sentence>

## Architecture
<diagram: Chat UI → WS :<port> Orchestrator → MCP :<port> → PostgreSQL; └→ A2A :<port> <agent>>

| App | Port / path | What it does |
|---|---|---|
<one row per app; describe tools in plain words, not SQL; say what the A2A agent never sees>

## Prerequisites
- TIBCO Flogo VS Code extension 2.26.7+ · PostgreSQL 14+ · an LLM API key · Node.js 16+ for ../Chatbot
- Connector prerequisites (install before opening the apps in the designer): PostgreSQL ODBC driver <+ any other connector detected per connector-prereqs.md> — VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…**, then reload VS Code

## Steps to run

### 1. Create the database
`createdb -U postgres <db>` then `psql -U postgres -d <db> -f database.sql`

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files
<one property table per app: DB host/port/user/password/database, LLM key/provider/base URL/model
(state what the model ships as); then "click Connect/Test on each connection; if a trigger shows a red ✗,
click Sync"; then a note on which port property AND connection URL to change together>

### 3. Start the apps in this order
**MCP Server (<port>) → Agents (<port>) → Orchestrator (<port>).**

### 4. Open the chat client and connect
<the filled-in steps from chatbot-test.md: where the client lives
(samples/Agentic_AI/Chatbot = ../Chatbot), npm install / npm start, http://localhost:3000, enter
ws://localhost:<port><path>, **click ↻ next to the URL box**, Connect → "● Connected", and the
"won't connect?" line>


### 5. Run the demo
<demo-login table: identifier, code, what each one shows; one sentence on how a real portal would sign
them in>
<numbered happy-path turns, ending with the human-owned request>
More prompts are in [prompts.md](prompts.md).
**Reset between demos:** `psql -U postgres -d <db> -f reset_data.sql`

## Troubleshooting
| Symptom | Fix |
|---|---|
<verification never succeeds (redaction on the orchestrator), can't reach tools (start order / URLs),
LLM 401 / model not found, new tab must verify again (expected), stale demo data (reset)>

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).
```

## `_rebuild/README.md` template

The main README stays run-only, so the file inventory and the test ladder go in a separate developer guide
at `_rebuild/README.md`. Worked example:
`samples/Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/_rebuild/README.md`.
Copy its sections and fill every value from **this** sample's scripts (never copy the example's values):

1. **Intro**: "You don't need this folder to run the demo", plus what the folder is for.
2. **What's in this folder**: one row per `_rebuild/*.py` (and any extra script or spec), then the related
   use-case files (`database.sql`, `seed_data.sql`, `reset_data.sql`, `prompts.md`, transcript).
3. **Before you start**: prerequisites, and the settings table (env var / `config.md` key / default) built
   from what the scripts actually read. Note any script that ignores `config.md`, a DB name or port.
4. **Regenerate the apps**: `OUT_DIR=rebuilt python _rebuild/build_*.py`, plus both ⚠️ warnings (never
   regenerate a designer-saved `.flogo`; generated apps hold real credentials, so scrub before commit).
5. **Test ladder**: command, what it checks and what must be running, for each step. Give only commands,
   **no** results or counts.
6. **This sample's values**: DB, ports, paths, tool names, agent names.
7. **Changing the use case**: edit SQL + `tool_spec.py`, then `test_rules.py`, then rebuild, then steps 2–4.

Check that every relative link resolves: `_rebuild/` is one level deeper than the use-case folder.
