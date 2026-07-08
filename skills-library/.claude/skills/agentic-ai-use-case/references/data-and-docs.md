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
5. **Prerequisites** — Flogo Enterprise version, PostgreSQL, OpenAI (or on-prem LLM) key, Gmail App
   Password (if email), chatbot UI location.
6. **Setup & Run (manual steps folded in)** — create DB + load SQL; import the 3 apps; the app-property
   table per app (DB creds, LLM key/model, ports, email); **start order MCP → A2A → Orchestrator**;
   connect the chatbot UI to `ws://<host>:<wsPort>/<path>`; run the demo; reset with `reset_data.sql`.
7. **Demo scenarios** — the headline chat walkthroughs.
8. **Ports table** and **Troubleshooting** table.
9. Optional **security/production notes** (TLS, bearer auth, on-prem LLM, swap DB for real backend APIs).

Keep names, ports, currency, and the WebSocket path consistent with the actual `.flogo` files.
