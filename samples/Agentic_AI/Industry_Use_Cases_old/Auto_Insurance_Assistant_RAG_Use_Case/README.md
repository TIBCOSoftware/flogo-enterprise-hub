# Auto Insurance Policyholder Assistant — Agentic AI + RAG on TIBCO Flogo

A customer-facing (policyholder self-service) agentic AI demo for the **auto / motor insurance**
vertical, built on TIBCO Flogo Enterprise. It follows the proven 3-app agentic pattern used across
`samples/Agentic_AI/*` (MCP read tools + A2A write agents + a WebSocket AI orchestrator) and
**extends it with a real RAG pipeline** (a 4th ingestion app + a RAG search tool) over generated
policy-wording PDFs.

## The idea (why this demo exists)

A policyholder chats in natural language. The assistant answers from two very different sources:

- **Structured facts** — *my premium, my excess/deductible amount, my claim status, my car, my
  payments* — come from **PostgreSQL** via read-only **MCP** tools.
- **Policy language** — *"does my policy cover X?", exclusions, definitions, conditions, the
  windshield excess rule, the flood exclusion, driving other cars, territorial limits, NCD
  protection* — comes from **RAG** (OpenAI Vector Store) over the **policy-wording PDFs**.

That split is the whole point: numbers/status from the database, wording from the documents.

## Architecture

```
 Policyholder (chat UI)
        | WebSocket  ws://localhost:9700/auto-insurance
        v
 AutoInsuranceAIOrchestrator.flogo   (AI Agent activity: intent routing)
        |  MCP (HTTP streamable)            \  A2A (HTTP)
        v                                    v
 AutoInsuranceMCPServer.flogo         AutoInsuranceA2AServers.flogo
   :9701 /auto-insurance-mcp            :9711  file_claim            \
   read tools:                          :9712  request_callback       }-> PostgreSQL (auto_insurance)
    - get_policyholder_profile          :9713  update_contact_details/
    - get_policy_details                :9714  send_confirmation_email --> SMTP (Gmail SSL)
    - get_vehicles
    - get_coverages       ------------> PostgreSQL (auto_insurance)
    - get_claims
    - get_payments
    - search_policy_wording --------->  OpenAI Vector Store (vectorSearch)   [RAG]
                                              ^
 AutoInsuranceRAGIngestion.flogo               | records vector_store_id
   :9720  POST /ingest   -- vectorStoreCreate -> fileUpload x4 -> fileList
                            -> INSERT document_index -> return           policy_docs/*.pdf
```

**Automated vector-store handoff:** the ingestion app writes the created `vector_store_id` into the
`document_index` table; the MCP `search_policy_wording` tool reads the latest id from that table and
passes it to `vectorSearch`. No manual copying of the id.
*(Alternative: expose a `VECTOR_STORE_ID` app property on the MCP app and skip the DB lookup.)*

## Ports & apps

| App | File | Trigger / Port | Connections |
|---|---|---|---|
| MCP Server | `AutoInsuranceMCPServer.flogo` | `#mcpserver` HTTP `:9701` `/auto-insurance-mcp` | PostgreSQL + OpenAI (properties) |
| A2A Servers / Agents | `AutoInsuranceA2AServers.flogo` | 4× `#agent` `:9711`–`:9714` | OpenAI (LLM) + PostgreSQL |
| RAG Ingestion | `AutoInsuranceRAGIngestion.flogo` | `#rest` POST `:9720` `/ingest` | OpenAI (properties) + PostgreSQL |
| Orchestrator | `AutoInsuranceAIOrchestrator.flogo` | `#wsserver` `:9700` `/auto-insurance` | OpenAI (LLM) + MCP + 4× A2A |

Ports sit in a free `9700` block to avoid clashing with the other use cases.

## Files

```
Auto_Insurance_Assistant_Use_Case/
  database.sql                     schema + demo data (DB: auto_insurance)
  reset_data.sql                   restore demo state (undo agent writes; keep vector-store id)
  generate_policy_pdfs.py          fpdf2 generator for the RAG corpus
  policy_docs/                     the 4 generated policy-wording PDFs (RAG corpus)
  AutoInsuranceMCPServer.flogo
  AutoInsuranceA2AServers.flogo
  AutoInsuranceRAGIngestion.flogo
  AutoInsuranceAIOrchestrator.flogo
  prompts.md                       demo chat script (facts vs language, all agents)
  README.md
```

## Data model (DB `auto_insurance`)

`policyholders, policies, vehicles, coverages, claims, payments, callbacks, contact_change_log,
document_index`. Natural key given in chat = **`policy_number`** (e.g. `POL-AUTO-100001`); the write
agents derive internal ids (`policyholder_id`) from it in SQL — the user is never asked for them.
`coverages` holds the per-coverage **limit** and **excess (deductible)** amounts. `document_index`
holds the RAG vector-store id. 7 personas; see `prompts.md`.

---

## Setup & Run

### 0. Prerequisites
- TIBCO Flogo Enterprise (VS Code Flogo extension) 2.26.7 or later (the apps were saved with `flogoVersion` **2.26.6**).
- PostgreSQL reachable on `localhost:5432` (user `postgres`).
- PostgreSQL ODBC driver (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- Python 3 with **fpdf2** (`pip install fpdf2`) to regenerate PDFs (they are already generated).
- An **OpenAI API key** with Files + Vector Stores access.
- The local **`extensions/openAI`** extension (Tech Preview) registered in the Flogo VS Code
  extension — see step 3.

### 1. Database
```bash
psql -h localhost -p 5432 -U postgres -d postgres -c "CREATE DATABASE auto_insurance;"
psql -h localhost -p 5432 -U postgres -d auto_insurance -f database.sql
# between demo runs, to undo agent writes (keeps the ingested vector-store id):
psql -h localhost -p 5432 -U postgres -d auto_insurance -f reset_data.sql
```

### 2. Policy PDFs (RAG corpus)
Already generated in `policy_docs/`. To regenerate:
```bash
pip install fpdf2
python generate_policy_pdfs.py
```

### 3. Register the openAI local extension (hard prerequisite for RAG)
In VS Code settings (`flogo.extensions.local`) add the path to `extensions/openAI` so the Flogo
extension loads the `vectorStoreCreate` / `fileUpload` / `fileList` / `vectorSearch` activities
(Tech Preview). Without this, the MCP and Ingestion apps won't open with those activities.

### 4. Import the apps & set secrets/properties
Import the four `.flogo` files. Then in **App Properties** set (values are placeholders/encrypted in
the committed files):
- `AutoInsuranceMCPServer` & `AutoInsuranceRAGIngestion`: `OPENAI_API_KEY` (real key),
  `OPENAI_API_ENDPOINT_URL` (default `https://api.openai.com/v1`), and on Ingestion set
  `POLICY_DOCS_DIR` to the absolute path of `policy_docs/` (the `#fileUpload` activity reads local
  file paths relative to the engine's working directory — an absolute path is safest).
- `AutoInsuranceA2AServers` & `AutoInsuranceAIOrchestrator`: the OpenAI LLM connection `API_Key`
  and (A2A) the `Email_App_Password`, `Email_Username`, `To_Email`, and the PostgreSQL `Password`.
- All Postgres-using apps: confirm `PostgreSQL.PostgresConn.*` (host/port/db `auto_insurance`/user).

> **Secrets:** the committed `.flogo` files carry no live plaintext key — `OPENAI_API_KEY` is the
> placeholder `<YOUR_OPENAI_API_KEY>`; other credentials are Flogo `SECRET:` values. Set your own in
> App Properties. **Scan for secrets before committing** any locally-saved variants of these apps.

### 5. Run order
Click **Sync** on each non-OpenAPI trigger after import, then start in this order:
1. **`AutoInsuranceRAGIngestion`** — once. `POST http://localhost:9720/ingest`. It creates the
   `AutoPolicyKnowledgeBase` vector store, uploads the 4 PDFs (OpenAI chunks + embeds them), waits
   for vectorization, and records the id in `document_index`. (Re-running creates a new store; the
   MCP tool always uses the most recent id. You can stop this app after a successful run.)
2. **`AutoInsuranceMCPServer`** (`:9701`).
3. **`AutoInsuranceA2AServers`** (`:9711`–`:9714`).
4. **`AutoInsuranceAIOrchestrator`** (`:9700`).

Then open the shared chatbot in `samples/Agentic_AI/Chatbot` and connect:

```bash
cd samples/Agentic_AI/Chatbot
npm install    # first time only
npm start
```

Open **http://localhost:3000**, then:

1. In the URL box at the top right, enter **`ws://localhost:9700/auto-insurance`**.
2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
3. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
last URL you applied, so a URL from another demo is a common cause.

Use the prompts in `prompts.md`.

---

## RAG scoping note
A single shared vector store (`AutoPolicyKnowledgeBase`) holds the standard auto policy wordings —
exactly like a real insurer's published booklets, which apply by product tier. The orchestrator adds
the policyholder's product tier (from `get_policy_details`) to the search query so the right wording
is surfaced. `vectorSearch` has no server-side metadata filter, so one shared store + query context
is the simplest correct design. For genuinely per-policyholder private documents you would create one
vector store per policy and store its id per row in `document_index`.

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

`fda` wires the full app graph, but a few things depend on **your** environment, **your** secrets, and a
**running engine with the openAI extension** — they can't be baked into a portable, secret-free app. Set the
app properties listed below with your own values at import time; never commit real secrets.

1. **OpenAI credentials & endpoint.**
   - On `AutoInsuranceMCPServer` and `AutoInsuranceRAGIngestion` set `OPENAI_API_KEY` (a real key — the
     committed value is the placeholder `<YOUR_OPENAI_API_KEY>`) and `OPENAI_API_ENDPOINT_URL` (default
     `https://api.openai.com/v1`). The key needs **Files + Vector Stores** access for RAG.
   - On `AutoInsuranceA2AServers` and `AutoInsuranceAIOrchestrator` set the OpenAI LLM connection
     `API_Key`, a real `LLM_Base_URL`, and an `LLM_Model` your key can access.

2. **openAI local extension.** Register `extensions/openAI` in the Flogo VS Code extension
   (`flogo.extensions.local`) so `vectorStoreCreate` / `fileUpload` / `fileList` / `vectorSearch` load
   (see Setup step 3). Without it the MCP and Ingestion apps won't open.

3. **RAG corpus path.** On `AutoInsuranceRAGIngestion` set `POLICY_DOCS_DIR` to the **absolute** path of
   `policy_docs/` (the `#fileUpload` activity reads local file paths).

4. **PostgreSQL database & credentials.** Create the **`auto_insurance`** database, load `database.sql`
   (reset between demos with `reset_data.sql`), and set `PostgreSQL.PostgresConn.*`
   (host / port / db / user / `Password`) on every Postgres-using app. `Password` is a `SECRET:` app
   property — set the real secret in App Properties, not in plaintext.

5. **Email / SMTP** (the `send_confirmation_email` agent). On `AutoInsuranceA2AServers` set
   `Email_Username`, `To_Email`, and re-enter `Email_App_Password` in App Properties so it stores as a
   `SECRET:` value (keep the type `string`). Confirm outbound SMTP (SSL:465) is allowed from the host.

6. **Ports free & consistent.** `:9700` (orchestrator WebSocket), `:9701` (MCP), `:9711`–`:9714` (A2A),
   and `:9720` (ingestion) must be free; the orchestrator's MCP/A2A `serverUrl`s must match those ports.

7. **Flogo designer steps.** Click **Sync** on each non-OpenAPI trigger after import, then open each
   connection (PostgreSQL, OpenAI, MCP, all four A2A) and **Connect / Test** before running.

8. **Run the ingestion once.** Start `AutoInsuranceRAGIngestion` and `POST
   http://localhost:9720/ingest` to build the vector store **before** starting the other apps (see Setup
   step 5). Re-running creates a new store; the MCP tool always uses the most recent id.

9. **Chatbot / WebSocket client.** Use the shared `samples/Agentic_AI/Chatbot/` UI: enter
   `ws://localhost:9700/auto-insurance`, **click the ↻ icon next to the URL box**, then **Connect**.
   See `prompts.md` for ready-to-paste demo prompts.

> **No binary is built here.** Live OpenAI ingestion/search and the end-to-end chat require a running
> Flogo Enterprise engine with the openAI extension registered and a valid API key.
