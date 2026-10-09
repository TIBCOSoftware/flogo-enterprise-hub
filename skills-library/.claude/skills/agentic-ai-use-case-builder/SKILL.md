---
name: agentic-ai-use-case-builder
description: Build ANY Agentic AI use case, demo, or chatbot on TIBCO Flogo Enterprise — a real-time WebSocket chatbot backed by three apps: an MCP Server (read tools), an A2A Agents app (reasoning/action agents), and a WebSocket AI Orchestrator, all PostgreSQL-backed. This is THE canonical builder for any vertical (telecom, airline, hospital, banking, retail, insurance, logistics, utilities, scholarly publishing, …). Governed by default: it first runs the Agentic AI decision framework (human-owned vs. agent vs. deterministic), then enforces identity, scoping, prices and state changes in PostgreSQL — not in prompts — with scoped reads (FROM rule_fn(token)), guarded writes (INSERT … SELECT rule_fn → 0 rows when blocked), two-step propose/confirm for state changes, routed human-review cases, session-token identity, per-connection conversation memory, minimised read-only A2A agents, and a four-step test ladder (SQL rules → static validator → MCP smoke → chat e2e with prompt injection). TWO build methods, and the skill ASKS which: the Flogo Design CLI (`fda`) built from scratch (the RECOMMENDED DEFAULT), or cloning a governed reference `.flogo` and swapping fields. Use when the user asks to build/create/scaffold an agentic AI use case, demo, chatbot, or "MCP + A2A + orchestrator" solution for any domain, or when an agent must act on a user's own records, money or state.
user-invocable: true
metadata:
  author: Flogo Skills Author <author@example.com>
  version: "1.0.0"
  last-updated-date: "2026-10-10"
---

# Agentic AI Use Case Builder (governed by default)

Builds an agentic AI demo that would survive a customer's architecture review: **agentic in the
middle, deterministic at the edges**. The LLM handles the conversation and the one genuinely semantic
step. The database decides identity, eligibility, prices and state changes. People decide anything
they must answer for.

This is the single, self-contained, canonical skill for building agentic AI on TIBCO Flogo. It carries
all its own build machinery (the fda recipes, the PostgreSQL activity contract, the base validator, the
manual-config gap) and depends on no other skill. **Governance is the default style**, and you build it
with either of two methods (Phase 0a asks which): **FDA-CLI from scratch (recommended)** or
**clone-and-adapt** from a governed reference app. The table below shows what governance adds over a
plain, ungoverned demo:

| | plain ungoverned demo | **this builder (governed default)** |
|---|---|---|
| Starting point | a domain | a domain **+ the decision-framework gate** (every operation classified first) |
| Reads | one tool per table | **scoped** by a session token through a rule function |
| Writes | A2A agents write with LLM-chosen values | **guarded** MCP tools: `INSERT … SELECT rule_fn()`, plus readback of outcome and reason |
| State changes | one call | **two-step** propose → user yes → confirm (15-minute expiry, rules rechecked) |
| Exceptions | the model decides | **human-owned** `open_review_case`, routed by a table |
| A2A agents | action agents | reasoning agents with **minimised, read-only** input |
| Identity | none / trust the chat | `verify_*` → session token; per-connection `conversationId` |
| Done means | design-time validation | **4-step test ladder**, including prompt injection |

**Worked example:** `samples/Agentic_AI/Industry_Use_Cases/Scholarly_Publishing_Author_Services_Use_Case/`. Read its
`database.sql`, `_rebuild/tool_spec.py` and `README.md` before building a new one.

## What gets built

Three Flogo apps plus a PostgreSQL database, wired into one chat system. A person chats in natural
language with a web client; the orchestrator runs the conversation, calls the MCP tools for everything
the database decides, and hands the one fuzzy judgment to a reasoning agent.

```
Chat UI --WebSocket--> <Prefix>AIOrchestrator --MCP(HTTP streamable)--> <Prefix>MCPServer --\
                              |                                                               +--> PostgreSQL
                              \----------------A2A(HTTP)----------> <Prefix>Agents -----------/
```

| App | Trigger | Port / path | What it holds |
|---|---|---|---|
| `<Prefix>AIOrchestrator` | `#wsserver` (WebSocket) | e.g. `7001`, path `/<usecase>` | the chat brain: an AI Agent that routes to MCP tools and the A2A agent, with per-connection memory |
| `<Prefix>MCPServer` | `#mcpserver` (HTTP streamable) | e.g. `9091`, path `/<usecase>mcpserver` | the governed tools — scoped reads, guarded writes, two-step actions, human-review routing |
| `<Prefix>Agents` | `#agent` / `tr_agent` (A2A, HTTP) | e.g. `8081`, its own `agentUrl` | one reasoning agent, read-only, given minimised input (no identity) |

**Where the apps live** is named by `<Prefix>` after the persona/vertical (`PassengerServices*`,
`AuthorServices*`) — no `Gov` suffix (Phase 0 naming rule).

**A concrete tool + agent inventory** (model yours on the Airline / Scholarly Publishing samples — names
are illustrative, not fixed):

- **Identity (MCP):** `verify_<principal>` — an identifier + a one-time code returns a session token; every
  other tool takes that token.
- **Scoped reads (MCP):** `get_my_<records>`, `get_<record>_detail(token, id)` — the function resolves the
  caller from the token and returns only their rows (another user's id gets a `NOT_FOUND` row, not an error).
- **Guarded writes, two-step (MCP):** `propose_<action>` then `confirm_<action>` — `propose_*` quotes the
  outcome into a `pending_actions` row with a 15-minute expiry; `confirm_*` re-checks every rule and writes
  the event row only when still eligible.
- **Human-owned routing (MCP):** `open_service_case` / `open_review_case` — files the request, a table routes
  it to a team with an SLA, and the model never decides the outcome.
- **Email (MCP, optional):** `email_<confirmation>` — a guarded tool that only emails an action already
  executed for the verified session.
- **Reasoning agent (A2A):** exactly one — e.g. rank options against the user's free-text preferences. It gets
  only the fields it needs (title/abstract/keywords, or the candidate flights), never the user's identity, and
  has no write tool.

## Hard rules

The base build hard rules apply to **both methods**: never regenerate — or re-clone — a designer-touched
`.flogo`, never write to one that is open in the designer (have the user Discard + close it first), and in
FDA mode put every structural change through `fda`. In clone mode, carry the `contrib` blobs and every
`SECRET:` value verbatim from the cloned app, and write a real `""` (never the literal `New_value`) for an
empty OpenAI base URL. On top of that:

1. **Gate first.** No design until every operation has an owner from
   [decision-framework-gate.md](references/decision-framework-gate.md). If you can't write the "Why an
   agent here?" paragraph, tell the user the use case doesn't need an agent.
2. **No rule in a prompt.** Filtering, arithmetic, eligibility, routing and "only show their own" are
   SQL. Prompts may *explain* outcomes. They never *produce* them.
3. **Every write is guarded.** Use `INSERT … SELECT * FROM <rule_fn>(…)`, never `VALUES`. Use an event
   row plus a trigger rather than an UPDATE. Always read back the outcome.
4. **The model never decides human-owned requests.** Open a case, give the case id and team, and say
   a person will decide.
5. **Honest AI.** The assistant says it is an AI when asked. Never write a prompt that hides it.
6. **Tests assert on DB state.** Text checks stay loose, because the wording varies (temperature 0 =
   provider default).
7. **Secrets.** Builds read secrets at run time (env or config.md). Never print config.md unredacted.
   Scrub the `.flogo` files before handing them over (Phase 6). Executables and their copies live
   outside the repo.
8. **Report honestly.** Report pass counts, retries and the known limitations every time. Never
   report a green run you didn't see.

## Reference files

| File | Read when |
|---|---|
| [references/decision-framework-gate.md](references/decision-framework-gate.md) | Phase 1: classify operations, write "Why an agent here?" |
| [references/governed-patterns.md](references/governed-patterns.md) | Phases 2–4: SQL shapes and the fda recipes that differ |
| [references/runtime-gotchas.md](references/runtime-gotchas.md) | Phases 4–5: wsserver headers, temperature, guardrails, LLM timeout, flogobuild context |
| [references/testing-ladder.md](references/testing-ladder.md) | Phase 5: the four steps and how to run the apps |
| [references/spec-and-readme-template.md](references/spec-and-readme-template.md) | Phases 2 and 6: spec additions, README template |
| [references/validate_governed_apps.py](references/validate_governed_apps.py) | Phase 5: runs the base validator, then G1–G9 |
| [templates/_rebuild/fda_common.py](templates/_rebuild/fda_common.py) | Phase 4: `App` helper (`bake_pg`, `conn_ref`, `cap_empty`, connections) |
| Local build references (self-contained): [fda-build-recipes](references/fda-build-recipes.md), [postgres-activity-patterns](references/postgres-activity-patterns.md), [fda-limitations](references/fda-limitations.md), [manual-config-gap](references/manual-config-gap.md), [connector-prereqs](references/connector-prereqs.md) | Phase 4A: the FDA recipes, PostgreSQL activity contract, Tech-Preview limits, manual-config gap, connector prerequisites |
| [references/flogo-app-templates.md](references/flogo-app-templates.md) | Phase 4B: exact JSON shape of all 3 apps — the clone-and-adapt reference |
| [references/use-case-spec-template.md](references/use-case-spec-template.md) | Phase 2: the base spec the governed additions extend |
| [references/data-and-docs.md](references/data-and-docs.md) | Phase 4/6: conventions for `database.sql`, `reset_data.sql`, `prompts.md`, README |
| [references/chatbot-test.md](references/chatbot-test.md) | Phase 6: bring up the shared chatbot and connect it (the ↻ step people miss) |

## Workflow

### Phase 0a: choose the build method ⛔
Both methods build the same governed 3-app pattern, and **the user chooses which — always ASK
(AskUserQuestion), never silently pick**, even when the request looks just like a past build:
- **FDA-CLI from scratch — the RECOMMENDED DEFAULT.** Every app is constructed by `fda` commands: a clean,
  auditable, from-scratch build with no leftover UUIDs/secrets/`contrib` blobs, and no hand-assembled
  trigger/reply JSON to get subtly wrong. Recommend this.
- **Clone-and-adapt.** Clone a **governed** reference `.flogo` from
  `samples/Agentic_AI/Industry_Use_Cases/` (e.g. the Airline or Scholarly Publishing apps) and swap fields.
  Legitimately better when a near-identical governed reference app exists, **or when the app needs
  custom-extension activities the FDA recipes don't cover** (e.g. the `extensions/openAI` vector/RAG
  activities — `vectorStoreCreate`/`fileUpload`/`fileList`/`vectorSearch` have no `fda` recipe, so cloning a
  proven sample is the reliable path).

Present the choice, recommend FDA-CLI (default), and note the clone exception. **Either way the governance
layer is non-negotiable** — the governance SQL, the static validator, and the full 4-step test ladder apply
to a cloned build exactly as to an FDA build. Then follow **Phase 4A** (FDA) or **Phase 4B** (clone)
accordingly. (Do not silently pick a method — a build cloned without asking once shipped a hand-built
trigger with designer-only errors.)

### Phase 0: environment
Read `skills-library/.claude/skills/config.md` for the fda path, psql, PostgreSQL, LLM provider and
model. **Redact** passwords and keys before echoing anything. Run `flogobuild list-context` and record
the real context name; config.md's value can be stale (runtime-gotchas.md §7). Pick the output folder:
`samples/Agentic_AI/Industry_Use_Cases/<UseCase>_Use_Case/` for a catalogue demo — this is the canonical
home for governed use cases. When migrating an existing non-governed demo, build the governed version
here and leave the original untouched under `samples/Agentic_AI/Industry_Use_Cases_old/`.

**Naming — no `Gov` suffix.** Name the apps `<Vertical>MCPServer` / `<Vertical>Agents` /
`<Vertical>AIOrchestrator` after the persona/vertical (e.g. `AuthorServices*`, `PassengerServices*`). Do
**not** add a `Gov`/`Governed` suffix to app, trigger, connection, folder or endpoint names — governance
is the default style of these samples, not a label. Only the **database** name may stay distinct (e.g.
`<vertical>_governed`) while a same-named non-governed original still exists in `Industry_Use_Cases_old/`,
to avoid a collision; drop the suffix once that original is retired.

**Decide the runtime model now** (it is baked into the apps — getting it wrong means a rebuild): the
orchestrator needs a capable tool-calling model that will delegate to the A2A agent. `gpt-5-nano` is
too weak (drops tool calls, won't delegate); use **`gpt-5.5`** or a Sonnet-/Opus-class or Gemini 2.5
Pro-class model. If config.md's `LLM_Model` is a tiny model, override it (env `LLM_MODEL=gpt-5.5` or set
it in config.md) before Phase 4. See [cost-and-efficiency](#cost--efficiency); ideally run the whole
build in a **fresh session**.

### Phase 1: frame and gate
Name the persona and the vertical. Use fictional organisations, and never a customer's name on
screen. List the operations and classify each one (Q1 human? Q2 semantic?). Check that the catalogue
doesn't already cover the vertical (`samples/Agentic_AI/README.md`).

### Phase 2: spec
Fill in the spec with the governed additions: identity and scope, the classification, rules with
reason codes and a seed row per code, two-step actions, request types → teams, adversarial acceptance.

### Phase 3: plan, then gate on approval ⛔
Present the classification table, tools, agent, rules, ports and the demo script. Build nothing until
the user approves.

### Phase 4: build (only after approval)
Do the shared data + contract + step-1 steps first — **the governance lives here, not in the app graph** —
then build the three apps with **Phase 4A (FDA)** or **Phase 4B (clone)** per the Phase 0a choice, then
write `prompts.md`.

**Shared steps (both methods):**
1. `database.sql` (schema + rule functions + seeds) and `reset_data.sql`. Load them.
2. `_rebuild/tool_spec.py`: every tool's description, args, and guarded write + read SQL. This is the
   single source of truth for both methods.
3. `_rebuild/test_rules.py`: **run it and make it pass before generating or cloning any app** (step 1).

#### Phase 4A — build (FDA mode)
4. `_rebuild/build_mcp.py`, `build_agents.py`, `build_orchestrator.py` drive `fda` through
   `fda_common.App`, following the sample's drivers. Each driver refuses to overwrite an existing app. The
   governed recipes (scoped read, guarded write + readback, two-step, WebSocket headers, MCP hint booleans,
   per-connection memory) are in [references/governed-patterns.md](references/governed-patterns.md) on top of
   the base [references/fda-build-recipes.md](references/fda-build-recipes.md).

#### Phase 4B — build (clone-and-adapt)
4. Clone a **GOVERNED** reference app set from `samples/Agentic_AI/Industry_Use_Cases/` (match on shape — the
   number of guarded-write tools, whether there is an email tool, and the A2A agent) and swap in this use
   case's fields: app/tool/agent names, ports, the governed SQL from `tool_spec.py`, system prompts, and the
   PostgreSQL `Database_Name`. See [references/flogo-app-templates.md](references/flogo-app-templates.md) for
   the exact JSON shape. Clone mechanics:
   - **Carry the `contrib` base64 blobs and every `SECRET:` value verbatim** — they are environment/version
     boilerplate; regenerating them by hand breaks import.
   - Swap fields **surgically** (name, SQL text, prompt, port). **Never regenerate — or re-clone — a `.flogo`
     once it has been opened in the designer** (that mints new connection UUIDs which orphan every `conn://`
     ref and reverts secrets to placeholders); patch only the broken field(s) on the existing file.
   - Mint fresh, unique connection UUIDs per app; every `conn://<uuid>` must resolve to a key in that app's
     `connections` map. Write a real `""` (never the literal `New_value`) for an empty OpenAI base URL, and
     set `temperature` to the number `0` on every agent and the orchestrator.
   - **Keep the governance intact:** the cloned reference is already governed, so preserve its scoped-read /
     guarded-write / two-step / review-routing SQL shape and change only the domain specifics.

**Both methods then:**
5. `prompts.md`.

The governance guarantees do not depend on the method — the scoped reads, guarded writes, two-step confirm,
human routing and session identity come from the SQL in `database.sql` / `tool_spec.py`, which both methods
load, and Phase 5 runs the same 4-step ladder regardless.

### Phase 5: verify (the testing ladder, all four steps)
Step 1 `test_rules.py` → step 2 `validate_governed_apps.py --local` + `fda cm -f` for each app →
build the exes in a scratch folder outside the repo → step 3 `mcp_smoke.py` → reset the DB → step 4
`chat_e2e.py` with `A2A_LOG` set. The user asking for an end-to-end test counts as the explicit
request to build binaries. Otherwise, stop at step 2 and say so.

**Run the cheap steps first and fix everything there, then run the expensive e2e once.** Steps 1–2 use
no LLM and no binaries — make them fully green (and confirm the runtime model from Phase 0) before you
build exes or touch the chat e2e. The e2e is the slowest, most token- and OpenAI-expensive step; a weak
runtime model, a wrong assertion, or a non-ASCII console crash each force a full re-run. Getting steps
1–3 right makes the e2e a single pass.

### Phase 6: hand over
1. Stop the exes. Reset the DB.
2. **Scrub the secrets** in the sample's `.flogo` files with surgical text replacement. Never
   round-trip through `json.dump`, because that reorders keys and rewrites unicode. API key →
   `sk-REPLACE-WITH-YOUR-OPENAI-KEY`, DB password → `SET_YOUR_DB_PASSWORD`.
3. Delete the scratch exes and `.flogo` copies.
4. Run `validate_governed_apps.py` **without** `--local` (G9 is now an error), plus a grep secret scan
   over the sample and the skill folders.
5. Write the README from the template. It is for customers and partners who want to **run** the demo:
   "Why an agent here?", architecture, prerequisites, numbered steps to run (database, the ⚠️ app
   properties per app, start order, chat client, demo logins and script, reset), troubleshooting.
   Keep test results, negative tests, limitations and file lists **out** of the README; they go in the
   report (step 7). Add a sanitized `chat_e2e_transcript.md`.
6. Add a catalogue row in `samples/Agentic_AI/README.md` and `samples/README.md`.
7. Report: what passed (with counts), retries, the limitations, and anything skipped. **End the report
   with "Test it in the chatbot"** from
   [chatbot-test.md](references/chatbot-test.md), filled in with this use case's
   `ws://localhost:<port><path>`. Include the ↻ click next to the URL box, which people miss. Don't commit
   unless asked.

## Cost & efficiency

A governed build is cheap when done well (single-digit to low-double-digit dollars of agent tokens) and
expensive when done in a bloated session with avoidable re-runs. The cost is driven by **turns × context
size** (cache reads dominate), not by app size. Levers, highest-impact first:

1. **Build in a fresh session.** Don't chain a build onto a long prior task — every turn re-reads the
   whole accumulated context. A clean session is the single biggest saving (often 6–10×).
2. **Front-load the spec in one prompt** (vertical, persona, tools, the semantic step, human-owned list,
   email yes/no, runtime model, ports, "run the test ladder", "I'll approve the plan in one pass").
   Every clarification round-trip re-reads the context.
3. **Pick the runtime model up front** (Phase 0) so you never rebuild to swap it.
4. **Cheap steps first, e2e once** (Phase 5).
5. **Delegate heavy reads to a subagent** (Explore/fork, on a cheaper model): reading the reference
   sample and templates into the main context is costly — have a subagent read and summarise them.
6. **Keep tool output out of context:** pipe long output through `grep`/`tail`, read only the file
   slices you need, never dump a whole `.flogo` or log.

**Which dev model for which phase** (switch with `/model`, or run a step as a subagent with a model
override):

| Phase | Model | Why |
|---|---|---|
| Frame + decision-framework gate + spec + plan (1–3) | **Opus** | judgment/architecture — the classification is the whole game |
| Write drivers + SQL, write tests (4) | **Sonnet** | structured codegen following the templates |
| Debug a hard failure (e.g. a SQL planner surprise) | **Opus** | deep reasoning |
| Run the ladder, read logs, triage | **Sonnet** | mechanical; escalate to Opus only when stuck |
| README, prompts.md, catalogue rows, secret scrub | **Haiku** (or Sonnet) | pure mechanical text |

Rule of thumb: **Opus for design & debugging, Sonnet for the bulk build/tests, Haiku for docs/scrub.**

## Top gotchas (full list in runtime-gotchas.md)

- **wsserver headers `schema://` → no headers at runtime.** Set them inline, and map `conversationId`
  from `Sec-Websocket-Key`, or every client shares one conversation and one verified token.
- **Temperature 0 = omitted**, not deterministic. Non-zero values break gpt-5.x and Claude 4.7+.
- **`redactSensitiveData=true` on the orchestrator masks the ORCID/code**, so no one can verify.
- **MCP hints need `--jsonValue`**, because `--type boolean` stores strings.
- **No LLM timeout in the AI Agent.** One hung call blocks that socket. The test retries once and
  reports it.
- **`fda` without `-f`** creates `flogo-project.flogo` in the current folder.
- **Placeholders can't repeat within one statement.** The write uses `?w_*` and the read uses `?r_*`.
