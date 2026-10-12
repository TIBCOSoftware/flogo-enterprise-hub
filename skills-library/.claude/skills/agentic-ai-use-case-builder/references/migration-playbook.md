# Migration playbook: rebuild a legacy sample in the governed style

Use this when the input is one of the legacy samples in `samples/Agentic_AI/Industry_Use_Cases_old/`. It
replaces most of the Phase 1 discovery (the legacy files already answer it), fixes the target folder, port
block and database name per sample, and says how to retire the original. Everything else — the decision
gate, the governed SQL, the validator, the 4-step ladder, the README rules — is the normal workflow.

## 1. Discovery from the legacy files

1. **Read the legacy sample as the discovery input:** `README.md`, `database.sql`, `prompts.md` and any
   `*.spec.md` (delegate the reading to a subagent; never load its `.flogo` files whole). Take from them:
   persona, identifier, reads, actions, rules (often hidden in prompts), demo personas and storyline.
2. **Strip what must not carry over.** POC and working notes (`*-poc.md`, `manual-steps.md`,
   `agents.md`, `api-endpoints.txt`, `swagger.json`, slide builders), internal or third-party API and app
   names (REST-backend apps named after a system or a prospect), and any prospect or customer name. None of
   it goes into the new sample's files, prompts, seed rows, transcript or commit message.
3. **Play back** what you took, one line per item, under "What I took from the legacy sample".
4. **Ask ONE `AskUserQuestion` round** (max 4 questions; put the rest under **Assumptions**):
   - **Keep / drop features** (multiSelect over the legacy capabilities; recommend dropping thin ones).
   - **The fuzzy step(s)** — which semantic step(s) stay with an A2A agent (usually one, max 3).
   - **Human-owned requests** — which legacy write-agent actions a person must decide instead.
   - **Locale, runtime model and verification depth** — default **USD/USA** (convert currency, phone
     numbers, addresses, regulations), **`gpt-5.5`**, full 4-step ladder.
   Also ask Phase 0a's build method in the same call when it isn't preset by the mapping table below.

## 2. Feature mapping (legacy → governed)

| Legacy feature | Governed replacement |
|---|---|
| A2A **write agent** (agent INSERTs with LLM-chosen values) | guarded MCP tool `INSERT … SELECT rule_fn(…)` + readback; **two-step** `propose_*`/`confirm_*` if the user could regret it |
| **Email agent** | guarded MCP email tool that only mails an action already executed for the verified session |
| LLM decides a **threshold / eligibility / price / "only theirs"** in the prompt | SQL rule function with reason codes (and a seed row per code) |
| **REST tier** (separate REST backend app, `act_general_rest`, swagger) | **dropped** — its data moves into PostgreSQL tables behind scoped-read functions |
| A2A agents in general | stay **only** for genuinely semantic steps: read-only, minimised input, no identity, one harmless reference tool each (runtime-gotchas.md §10) |
| Unscoped MCP reads (`SELECT … FROM table WHERE id = ?`) | scoped reads `FROM rule_fn(token)` behind `verify_*` → session token |
| Shared conversation memory (empty `conversationId`) | per-connection memory from `Sec-Websocket-Key` (G7) |
| Exceptions the model "handles" (waivers, disputes, complaints) | `open_service_case` routed by a table to a team with an SLA |
| **BW6** apps | out of scope — `fda` can't build BusinessWorks |
| **RAG** (`extensions/openAI` vector activities) | **hybrid clone** — SKILL.md Phase 4B "RAG (hybrid clone)" |

## 3. Naming, locale and collision rules

- **Folder:** `samples/Agentic_AI/Industry_Use_Cases/<Industry>/<Sub_Category>/<New_Folder>` from the table
  below — `<New_Folder>` ≤ 48 characters, `A-Z a-z 0-9 _` only, every repo-relative path ≤ 160
  ([industry-taxonomy.md](industry-taxonomy.md)). The table's "file budget" is what is left for
  `<file>` / `_rebuild/<file>` — keep app prefixes short where it is tight.
- **Apps:** `<Prefix>MCPServer` / `<Prefix>Agents` / `<Prefix>AIOrchestrator` — no `Gov`, no legacy
  `*A2AServers` name (SKILL.md Phase 0).
- **Locale:** convert to **USD/USA** unless the user asks otherwise (prices, `+1 xxx 555-01xx` numbers, US
  addresses, US regulations such as HIPAA instead of GDPR/POPIA).
- **Org names never collide.** No two samples (governed or legacy-while-it-exists) share a fictional
  organisation name. Check the READMEs first: e.g. legacy Aerospace "Meridian" collides with the governed
  Airline's "Meridian", so the Aerospace rebuild gets a new name. Taken so far: Meridian (airline), Kestrel
  Bank, Aurelia Global Bank, Tidewell Mobile, Swiftbound.
- **Database:** `<legacy_db>_governed` while the original still exists in `_old` (the suffix avoids a
  collision on a shared PostgreSQL); a different name needs no suffix.
- **README** (customer-facing, [spec-and-readme-template.md](spec-and-readme-template.md)) gets one line
  after the intro: *"The original non-governed version is kept under
  [Industry_Use_Cases_old/<folder>](../../../../Industry_Use_Cases_old/<folder>/) for reference."*
- **Ports:** the block from the table; move its row from "reserved" to "governed" in
  [port-registry.md](port-registry.md) in the same change.

## 4. Mapping table — all 13 legacy samples

| # | Legacy folder | New location `<Industry>/<Sub_Category>/<New_Folder>` | File budget | Method | Special handling | Ports (WS/MCP/A2A) | DB | Priority |
|---|---|---|---|---|---|---|---|---|
| 1 | `Life_And_Pensions_Use_Case` | `Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case` | 52 | FDA | 5 write agents (beneficiary, contribution, fund switch, claim, adviser callback) → guarded tools, two-step for beneficiary/fund switch; claims → human-owned case; email agent → MCP email tool; already USD/401(k) | 9930 / 9932 / 9933 | `life_pensions_governed` | P1 |
| 2 | `Power_Distribution_Use_Case` | `Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case` | 36 | FDA | past-due reconnect guardrail → SQL rule; 3 write agents (outage dispatch, appointment, service change) → guarded tools, two-step for service change; tight file budget | 9940 / 9942 / 9943 | `power_distribution_governed` | P1 |
| 3 | `Auto_Insurance_Assistant_RAG_Use_Case` | `Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case` | 56 | **hybrid clone** | transplant `vectorSearch` + import + contrib; separate ingestion app on 9919; drop `.platform.flogo`; needs `-u <repo>/extensions` build context | 9910 / 9912 / 9913 (+9919) | `auto_insurance_governed` | P1 |
| 4 | `Hospital_AI-Agent_Use_Case` | `Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case` | **34** | FDA | **drop the REST tier** (2 REST apps + swagger → PostgreSQL); strip POC notes and internal API names; convert EUR → USD; HIPAA-style "never see" list; app prefix ≤ 17 chars | 9920 / 9922 / 9923 | `hospital_governed` | P2 |
| 5 | `Semiconductor_Customer_Use_Case` | `High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case` | 42 | FDA | RMA eligibility / lead-time rules → SQL; 5 write agents (order, expedite, RMA, sample, alert) + email agent collapse to guarded tools / MCP email tool | 9820 / 9822 / 9823 | `semiconductor_governed` | P2 |
| 6 | `Aerospace_Defense_MRO_Use_Case` | `Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case` | 52 | FDA | **rename the org** ("Meridian" collides with the governed Airline); 3 write agents (schedule, order part, dispatch) → guarded two-step tools; email agent → MCP email tool | 9810 / 9812 / 9813 | `aerospace_mro_governed` | P2 |
| 7 | `Real_Estate_Lead_Assistant_Use_Case` | `Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case` | 51 | FDA | new `Real_Estate` industry folder; legacy `build_*.py` are ungoverned — don't reuse them or copy their `schema://` headers / empty `conversationId` (runtime-gotchas §1) | 9960 / 9962 / 9963 | `realestate_governed` | P3 |
| 8 | `Predictive_Maintenance_Use_Case` | `Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case` | 55 | FDA | REST tier dropped; **decision gate may cut it** (threshold alerts are deterministic — if no genuine fuzzy step, tell the user it doesn't need an agent) | 9950 / 9952 / 9953 | `predictive_maintenance_governed` | P3 |
| 9 | `Airline_Passenger_Services_Use_Case` | superseded by `Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case` | — | — | stays in `_old`, marked superseded | 9850 block (done) | `airline_governed` | done |
| 10 | `Retail_Banking_Assistant_Use_Case` | superseded by `Financial_Services/Banking/Retail_Banking_Assistant_Use_Case` | — | — | stays in `_old`, marked superseded | 9860 block (done) | `banking_governed` | done |
| 11 | `Logistics_Transport_Use_Case` | superseded by `Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case` | — | — | stays in `_old`, marked superseded | 9890 block (done) | `parcel_delivery` | done |
| 12 | `Telecom_Invoice_Chatbot_Use_Case` | superseded by `Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case` | — | — | stays in `_old`, marked superseded | 9900 block (done) | `mobile_billing` | done |
| 13 | `Retail_AI_BW_Flogo` | **moved to `samples/Agentic_AI/BW6_Flogo_Samples/Retail_AI_BW_Flogo`; not migrated** — kept as-is as the "Better Together" (BW6 + Flogo REST) showcase | — | — | `fda` can't build BW6 | 9500/18000/18085 (permanent) | (inside BW6) | done (moved) |

Ports were checked free across the repo on 2026-10-12 ([port-registry.md](port-registry.md)). Re-check
before building — something may have landed since.

## 5. Retiring the originals

1. When a governed rebuild lands, fill the **Superseded by** column of its legacy row in
   `samples/Agentic_AI/README.md` (and `samples/README.md` if listed). The original stays in `_old`.
2. **Delete `_old` only when every migration is done** (rows 1–8 built, or explicitly cut at the decision
   gate). (`Retail_AI_BW_Flogo` has already been moved out to `samples/Agentic_AI/BW6_Flogo_Samples/`.)
3. Then **drop the `_governed` DB suffixes** in one change per sample: the `Database_Name` app property
   (surgical text edit, designer closed), `database.sql`/`reset_data.sql` headers, the README `createdb`
   line, `_rebuild/*.py` `PG_DB`, and the catalogue row. Remove the "original … kept under
   Industry_Use_Cases_old" README line and the legacy ranges from [port-registry.md](port-registry.md).

## 6. Batching

- **One sample per fresh session** — cheapest, and no context bleeds between verticals (or fictional orgs).
- Within a session, shared steps 1–2 (`database.sql` + `seed_data.sql`, `tool_spec.py`) and the reading of
  the legacy files **may use parallel subagents**.
- **Rung-4 chat e2e runs serially**, one sample at a time: the samples share one PostgreSQL server and one
  LLM key (spend and rate limits), and the reset scripts truncate tables mid-run.
- Order: P1 → P2 → P3 as in the table; the RAG hybrid (row 3) is the riskiest build — don't batch it with
  another sample.
