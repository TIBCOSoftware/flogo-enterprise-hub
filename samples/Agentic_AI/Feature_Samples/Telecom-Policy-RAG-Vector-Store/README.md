# Telecom Policy Knowledge Hub — ChunkAndEmbedDocuments + ActiveSpaces Vector Upsert / Search / Delete

*Use case: a telecom customer-care policy assistant built on Retrieval-Augmented Generation (RAG).*

## Overview

Care agents at a mobile operator answer the same questions all day: *what does roaming cost in Japan?*,
*how long must an outage last before I get a credit?*, *can I transfer my eSIM again?* The answers live
in policy documents that change every quarter. This sample keeps those documents in a **vector store**
and lets an **AI Agent** answer from them, with a citation for each fact. It covers the full
document lifecycle that a real knowledge base needs:

| Lifecycle step | Endpoint | Flogo activities |
|---|---|---|
| **Bulk-load** the policy library (PDF, DOCX, MD, TXT files) | `POST /policy/ingest/files` | **ChunkAndEmbedDocuments** (*File Paths*, Recursive) → **Vector Upsert** |
| **Publish** a new or revised policy as Markdown text | `POST /policy/ingest/text` | **ChunkAndEmbedDocuments** (*Text*, Markdown) → **Vector Upsert** |
| **Search** semantically | `GET /policy/search?q=…` | **ChunkAndEmbedDocuments** (embed the question) → **Vector Search** |
| **Answer** in natural language (RAG) | `ws://localhost:9741/policy-assistant` | **AI Agent Trigger** + tool flow (**ChunkAndEmbedDocuments** → **Vector Search**) + **Invoke AI Agent** |
| **Retire** a superseded policy | `DELETE /policy/documents/{documentId}` | **Vector Delete** (*Filter*) |
| **Remove** individual chunks | `POST /policy/chunks/delete` | **Vector Delete** (*Key*) |

Everything is in one app, `TelecomPolicyKnowledgeHub.flogo`. The vector store is a **TIBCO
ActiveSpaces® 5.2** table, and embeddings and chat use **OpenAI**.

The policies belong to **TeleCore Communications**, a fictional operator. The five PDFs in
[`policy_docs/`](policy_docs/) are the library, and the Markdown file in
[`policy_updates/`](policy_updates/) is a new policy published mid-demo.

## Architecture

```
                          TelecomPolicyKnowledgeHub.flogo
 ┌──────────────────────────────────────────────────────────────────────────────────────┐
 │ REST :9740  (knowledge-base admin API)                                                 │
 │   POST   /policy/ingest/files ── ChunkAndEmbed(File Paths) ──► Vector Upsert ─┐        │
 │   POST   /policy/ingest/text  ── ChunkAndEmbed(Text/Markdown) ► Vector Upsert ─┤        │
 │   GET    /policy/search       ── ChunkAndEmbed(question) ────► Vector Search ──┤        │
 │   DELETE /policy/documents/{id} ── validate id ──────────────► Vector Delete(Filter) ─┤ │
 │   POST   /policy/chunks/delete ──────────────────────────────► Vector Delete(Key) ────┤ │
 │                                                                                │      │
 │ WebSocket :9741 /policy-assistant                                              ▼      │
 │   chat msg ─► Invoke AI Agent ─► AI Agent Trigger "TelecomPolicyAssistant"   ActiveSpaces 5.2
 │                                   └─ tool SearchTelecomPolicies               table telecore_policy_kb
 │                                        ChunkAndEmbed(question) ► Vector Search ─►  (key, content,
 │                                                                                    metadata, embedding[1536])
 └──────────────────────────────────────────────────────────────────────────────────────┘
          OpenAI: text-embedding-3-small (embeddings) · gpt-5.5 (agent)
```

### Why an agent here?

Retrieval alone returns *passages*, and a care agent still has to read five of them to find the
answer. The AI Agent turns the customer's question into a search query, calls the vector search tool,
and writes a short answer from only the passages it got back, with the policy ID cited for every
figure. If nothing relevant comes back (`NO_MATCHING_POLICY`), it says no published policy covers the
question instead of guessing. The deterministic parts stay deterministic: chunking, embedding, storage,
deletion and input validation are all flow logic, not prompts.

## What each activity is configured to do

| Activity | Where | Key settings |
|---|---|---|
| **ChunkAndEmbedDocuments** | `IngestPolicyFiles` | Content Source `File Paths` · strategy `Recursive` · chunk size `1500`, overlap `250`, min `200` · on file error `Skip` (a bad file is reported in `skippedFiles`, the rest still load) · model `text-embedding-3-small` |
| **ChunkAndEmbedDocuments** | `IngestPolicyText` | Content Source `Text` · strategy `Markdown` at heading level `2`, so each `## section` is a chunk and its heading path lands in the chunk's `headings` · `documentId` from the request body |
| **ChunkAndEmbedDocuments** | `SearchPolicies`, `SearchTelecomPolicies` | Content Source `Text`: embeds the question with the **same model** as ingestion, giving one chunk and one vector |
| **Vector Upsert** | both ingest flows | Iterates `embeddings[]` · write mode `Replace`, so re-ingesting a document overwrites its chunks · `key` = chunk id (file name + `#index`) · `metadata` = `source=<document> \| chunk=<n>` (Markdown adds `section=[…]`) |
| **Vector Search** | both search flows | Vector column `embedding` · similarity `Cosine` · `maxResults` and `minScore` from App Properties (`Search.Max_Results` = 5, `Search.Min_Score` = 0.25) |
| **Vector Delete** (*Filter*) | `RetirePolicyDocument` | `metadata LIKE '%<documentId>%'`. The `documentId` path parameter must match `^[A-Za-z0-9-]{3,40}$` **before** it goes into the filter; anything else gets HTTP 400, so a caller can't widen the delete with `'`, `%` or `OR` |
| **Vector Delete** (*Key*) | `DeleteChunksByKey` | Deletes the primary keys listed in the body (copy them from a `/policy/search` result). `keysSubmitted` counts keys sent, not rows that existed |
| **AI Agent Trigger** | `TelecomPolicyAssistant` | Local agent · one Tool handler `SearchTelecomPolicies` · Memory conversation store (20 messages) · temperature `0` (provider default) · system prompt: answer only from tool results, cite the policy ID |
| **Invoke AI Agent** | `ChatWithPolicyAssistant` | `conversationId` = the WebSocket `Sec-Websocket-Key`, so each chat window keeps its own memory |

## Prerequisites

| What | Notes |
|---|---|
| **TIBCO Flogo® 2.26.9** or later | Ships the Agentic AI connector **0.9.5** (`ChunkAndEmbedDocuments`) and the ActiveSpaces connector **1.1.0** (Vector Upsert / Search / Delete) |
| **OpenAI API key** | Used for embeddings (`text-embedding-3-small`, 1536 dimensions) and the agent model (`gpt-5.5`) |
| Python 3.9+ | Only for `scripts/smoke_test.py` (`pip install websocket-client` for its chat step) |
| Node.js 16+ | Only for the shared browser [Chatbot](../../Chatbot/) |

## Run it

### 1. Create the vector table

```bash
./scripts/create_vector_table.sh            # creates telecore_policy_kb (key, content, metadata, embedding[1536])
```

The script uses the `tibdg` CLI (`TIBDG_ROOT` defaults to `/opt/tibco/as/5.2`; set `AS_GRID_URL` if your
grid isn't on `localhost:52080`). If you change the embedding model or `dimensions`, set `AS_VECTOR_DIM`
to match.

### 2. Set the App Properties

Open `TelecomPolicyKnowledgeHub.flogo` in VS Code. Under **App Properties**, set:

| Property | Value |
|---|---|
| ⚠️ `AgenticAI.OpenAI_LLMProvider.API_Key` | Your OpenAI API key (used by the agent **and** by every ChunkAndEmbedDocuments activity) |
| `ActiveSpaces.PolicyVectorStore.Grid_URL` | `http://localhost:52080` |
| `ActiveSpaces.PolicyVectorStore.Grid_Name` | `_default` |
| `ActiveSpaces.PolicyVectorStore.Username` / `Password` | Leave empty unless your realm has authentication enabled |
| `AgenticAI.OpenAI_LLMProvider.Embedding_Base_URL` | Empty = `https://api.openai.com/v1`; set it for an OpenAI-compatible gateway |
| `Trigger_Settings.LLM_Model` | `gpt-5.5` (use a capable tool-calling model; nano-class models skip the tool call) |
| `Search.Max_Results` / `Search.Min_Score` | `5` / `0.25` |

You can also leave the file unchanged and supply the values at run time as environment variables (step 3).

### 3. Build and start the app

Run it from VS Code (**Run** ▶), or build an executable with the Flogo App Build CLI:

```bash
flogobuild build-exe -a TelecomPolicyKnowledgeHub.flogo -c <your-2.26.9-build-context> -o bin
env FLOGO_APP_PROPS_ENV=auto \
    "AgenticAI.OpenAI_LLMProvider.API_Key=$OPENAI_API_KEY" \
    ./bin/TelecomPolicyKnowledgeHub
```

(Use `env`, not `export`, because the property names contain dots.) Wait for
`Successfully connected to ActiveSpaces DataGrid`, then for the REST trigger on **9740** and the
WebSocket trigger on **9741**.

### 4. Load the policy library

```bash
cd samples/Agentic_AI/Feature_Samples/Telecom-Policy-RAG-Vector-Store
curl -s -X POST localhost:9740/policy/ingest/files -H 'Content-Type: application/json' \
  -d "{\"filePaths\": [$(ls "$PWD"/policy_docs/*.pdf | sed 's/.*/"&"/' | paste -sd,)]}"
# {"chunksEmbedded":26,"embeddingModel":"text-embedding-3-small","skippedFiles":[],"status":"INGESTED","totalTokens":8018}
```

File paths are read **by the Flogo app**, so they must be absolute paths on the machine the app runs on.

### 5. Search

```bash
curl -s -G localhost:9740/policy/search --data-urlencode 'q=How much does roaming data cost per GB in Japan?'
```

Each match returns `key`, `content`, `source` (the metadata string) and a cosine `score`.

### 6. Chat with the assistant

Start the shared [Chatbot](../../Chatbot/) (`npm install && npm start`, then open http://localhost:3000).
Enter `ws://localhost:9741/policy-assistant` in the URL box, **click ↻ next to it**, then click
**Connect**. Try:

1. *What does roaming data cost per GB in Japan?* → Zone 3, **45.00 USD/GB** (TC-POL-001)
2. *My service was down for 6 hours yesterday. Do I get a credit?* → the qualifying-outage rule and credit formula (TC-POL-005)
3. *Can I upgrade my phone early, and what would it cost?* → the 80%-elapsed rule and early-termination formula (TC-POL-004)
4. *How many free eSIM transfers do I get?* → before step 7, no policy covers this specifically, so the
   assistant says so or falls back to TC-POL-003

### 7. Publish a policy update, then retire it

```bash
# publish TC-POL-006 (Markdown, chunked per ## section)
python3 -c "import json;print(json.dumps({'documentId':'TC-POL-006','text':open('policy_updates/TC-POL-006_eSIM_Activation_and_Transfer_Policy.md').read()}))" \
  | curl -s -X POST localhost:9740/policy/ingest/text -H 'Content-Type: application/json' -d @-
```

Ask the eSIM question again: the assistant now answers **3 free transfers per rolling 30 days, then
10.00 USD each (TC-POL-006)**. To withdraw the policy:

```bash
curl -s -X DELETE localhost:9740/policy/documents/TC-POL-006
# {"documentId":"TC-POL-006","message":"All chunks for this document were removed ...","rowsDeleted":7,"status":"RETIRED"}
curl -s -X DELETE "localhost:9740/policy/documents/x'%20OR%20'a'='a"
# HTTP 400 {"status":"REJECTED", ...}: the id never reaches the filter
```

Remove a single chunk by key (copy `key` from a search result):

```bash
curl -s -X POST localhost:9740/policy/chunks/delete -H 'Content-Type: application/json' \
  -d '{"keys": ["TC-POL-003_SIM_Swap_and_Account_Security_Policy.pdf#3"]}'
```

Re-running step 4 restores anything you deleted, because Upsert uses `Replace` mode.

### 8. Run the whole story as a test

```bash
pip install websocket-client
python scripts/smoke_test.py            # add --no-chat to skip the agent questions
```

It runs steps 4–7 against the running app and checks the results: the right top match for each
question, the agent citing the right policy, retire counts, rejection of the unsafe id, and
delete-by-key. It is safe to re-run.

### Reset

```bash
./scripts/create_vector_table.sh --drop && ./scripts/create_vector_table.sh
```

## Adapting it

- **Your own documents:** point `/policy/ingest/files` at any `.pdf`, `.docx`, `.md`, `.txt`, `.csv` or
  `.json` files. For Markdown-heavy sources, switch the file flow's strategy to `Markdown` too.
- **Chunk sizing:** start with 1500/250 for policy prose. Raise the chunk size if a table (a rate card,
  say) is being split away from the heading that explains it.
- **A different embedding model or size:** change it in **every** ChunkAndEmbedDocuments activity, and
  recreate the table with the matching `AS_VECTOR_DIM`. Vectors from different models can't be compared.
- **Metadata filters:** `metadata` is a plain string column, so filters use `LIKE`. For precise filtering
  (for example by product line or effective date), add typed columns to the table and the Upsert mapping,
  then filter on those in Vector Search or Vector Delete.
- **Expose search to other agents:** the `SearchTelecomPolicies` flow can become an MCP Server tool
  unchanged, so other AI agents can share the same knowledge base.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `skippedFiles` lists every file | The paths aren't absolute, or they don't exist on the machine running the app |
| Search returns `matchCount: 0` | Nothing ingested yet, or `Search.Min_Score` is too high for short questions. Try `0.2` |
| Upsert fails with a vector dimension error | The table's `embedding` size doesn't match the model's output. Recreate it with the right `AS_VECTOR_DIM` |
| App exits with `libtib.so.1: cannot open shared object file` | The ActiveSpaces / FTL `lib` directories aren't on `LD_LIBRARY_PATH` |
| The assistant answers without citing a policy | The model is too small to use tools reliably. Use `gpt-5.5` or a similar model |
| Chatbot won't connect | Click **Disconnect**, click **↻** next to the URL, then **Connect** |
