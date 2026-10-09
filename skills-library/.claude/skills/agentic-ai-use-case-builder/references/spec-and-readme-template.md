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

```markdown
# <Use Case Name> — <Assistant name> (Governed Agentic AI)

<2–3 sentences: who uses it and what they can do. Name the human-owned requests and say the assistant
never decides them.>

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
- TIBCO Flogo VS Code extension <version>+ · PostgreSQL 14+ · an LLM API key · Node.js 16+ for ../Chatbot

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
```
