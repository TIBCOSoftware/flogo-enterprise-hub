# Data & Docs Conventions

How to write `database.sql`, `reset_data.sql`, `prompts.md`, and the combined `README.md`.

---

## database.sql

- Header comment (use case name, `PostgreSQL 14+`, DB name).
- `DROP TABLE IF EXISTS ... CASCADE;` in reverse-dependency order, then `CREATE TABLE`s.
- One master/CRM table keyed by a natural identifier the chatbot will use (mobile number, PNR,
  patient id, account number …) — this is how the end user is recognized in chat.
- Lookup tables for each MCP read tool (profile, transactions/invoices, line items, usage, catalog,
  history, …) and **write-target tables** for each A2A agent (e.g. a `disputes`/`tickets`/`orders`
  table the agent inserts into; a log table).
- Money → `NUMERIC(10,2)`; measures → `NUMERIC(6,2)`; use `CHECK` constraints for enums; add indexes
  on the identifier + foreign keys.
- **Engineer the demo data around the scenarios.** For each capability create at least:
  - a **clean/normal** record (happy path), and
  - the **exception** record a write-agent acts on (e.g. a charge with no matching usage → dispute;
    a near-limit balance → upsell/recharge; a due item → the action).
  Pre-seed a couple of rows in write-target tables so read tools have something to show (e.g. an
  existing ticket with a status), and leave pure activation/log tables **empty** (the agent fills them).
- Give ~6–10 personas with realistic, locale-appropriate names/currency so the demo feels real.
- Keep table/column names **exactly** what the `.flogo` queries use.

## reset_data.sql

- Purpose: restore a clean demo state and undo agent writes between runs.
- `TRUNCATE <all tables> RESTART IDENTITY CASCADE;` then re-insert the same seed data.
- Make **volatile** dates relative to today (`CURRENT_DATE + INTERVAL '7 days'`, `CURRENT_DATE - INTERVAL '3 days'`)
  so the demo always looks current; keep stable facts (amounts, names, historical "active since") fixed.
- Re-seed the pre-seeded write-target rows; leave the agent-filled log/activation tables empty.

## Verify the data layer

Using paths/creds from `config.md`:
```
createdb / CREATE DATABASE <db>;  psql -d <db> -f database.sql   # check row counts
psql -d <db> -f reset_data.sql                                   # reloads clean
```
Then run the **exact** SQL of every MCP tool and every A2A query/insert (substituting demo values for
`?params`) to prove all table/column names resolve.

---

## prompts.md

Group demo prompts by scenario, each in a fenced block, matching the seeded data:
- Read-only scenarios (one per MCP capability).
- Write scenarios (multi-turn: ask → agent explains → user confirms → agent acts), naming the exact
  persona/record that triggers the exception (so it demonstrably fires the A2A agent).
- Status/history lookups of things a write-agent created (uses a pre-seeded row).
- A full end-to-end flow (read → write → optional email confirmation).
- Edge cases + out-of-scope prompts (to show the orchestrator declining politely).

## README.md (single file — fold the manual/setup steps in)

Sections, in order:
1. **Title + one-paragraph summary** — who chats, over what channel, to solve what.
2. **Architecture** — the ASCII diagram (Chatbot UI → WebSocket → Orchestrator → MCP/A2A → PostgreSQL).
3. **Flogo Apps** — three subsections (MCP tools table; A2A agents table with ports; orchestrator settings).
4. **Database** — table summary (table → purpose → row count).
5. **Prerequisites** — Flogo Enterprise version, PostgreSQL, OpenAI key (model default `gpt-5-nano`;
   base URL empty for OpenAI), Gmail App Password (if email), chatbot UI location, and **install the
   connector prerequisites** for every connector detected per [connector-prereqs.md](connector-prereqs.md):
   VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…**,
   then reload VS Code — required for design-time metadata fetching (schemas/tables/columns and
   connection validation in the designer).
6. **Setup & Run (manual steps folded in)** — create DB + load SQL; import the 3 apps; the app-property
   table per app (DB creds, LLM key/model, ports, email); **start order MCP → A2A → Orchestrator**;
   connect the chatbot UI to `ws://<host>:<wsPort>/<path>`; run the demo; reset with `reset_data.sql`.
7. **Configure before running end to end** — a compact checklist, tailored to the use case:
   (1) OpenAI API key — the only required LLM value; confirm the model (default `gpt-5-nano`) is
   available to the key; base URL stays empty unless Azure OpenAI / a gateway / another provider;
   (2) connector prerequisites installed (item 5); (3) PostgreSQL DB created, `database.sql` loaded,
   credentials set; (4) SMTP username/app password + recipient (if email agent); (5) ports free and the
   orchestrator's MCP/A2A URLs match; (6) in the designer, open each connection and click **Connect**,
   and re-enter secrets (the repo holds dummy `SECRET:` blobs / placeholders); (7) start MCP → A2A →
   Orchestrator, then point a WebSocket client at `ws://<host>:<port>/<path>`; (8) at deploy, inject
   secrets as platform app properties; (9) if RAG, keep `OPENAI_API_ENDPOINT_URL` =
   `https://api.openai.com/v1` and run ingestion first. Add the runtime note: all chat clients share
   **one** conversation memory (the orchestrator's `conversationId` is empty → a constant), up to
   `memoryMaxSize` messages until restart — restart the orchestrator between demos; simultaneous users
   see each other's context.
8. **Demo scenarios** — the headline chat walkthroughs.
9. **Ports table** and **Troubleshooting** table.
10. Optional **security/production notes** (TLS, bearer auth, on-prem LLM, swap DB for real backend APIs).

Keep names, ports, currency, and the WebSocket path consistent with the actual `.flogo` files.
