# Flogo Skill Library

A library of **skills for AI coding agents** (such as **Claude Code**) to design, build, test, and deploy TIBCO Flogo integration applications. Drop these skills into the `.claude/skills/` directory of any project and the agent will use them to drive the Flogo, build, and platform CLIs end-to-end.

---

## What's a Skill?

A **skill** is a Markdown file with frontmatter that documents a specific capability for an AI coding agent. The agent reads the skill on demand when the user's request matches its description. Skills make the agent reliable and repeatable on domain-specific tasks (like building a Flogo flow) — without you having to explain the same patterns over and over.

Each skill in this library lives in `.claude/skills/<skill-name>/SKILL.md` and follows this shape:

```markdown
---
name: <skill-name>
description: <when the agent should use this skill>
user-invocable: true
---

# Step-by-step instructions, command references, and recipes...
```

![Skills folder structure and SKILL.md preview](./images/coding-agents-skills.png)

---

## What's in this Library

The library contains **9 skills** that cover the full Flogo development lifecycle — from designing a flow, to mapping and testing it, to building an executable, to deploying it on the TIBCO Platform, and up to scaffolding complete Agentic AI use cases.

| Skill | Type | Purpose |
|---|---|---|
| **fda** | CLI reference | Full reference for the **Flogo Design Assistant** CLI — every task to create or modify a `.flogo` file (flows, activities, triggers, schemas, properties, tests). |
| **fda-mapping** | CLI reference | Focused reference for **building, inspecting, and validating Flogo mappings** with `fda` — the `input.mapping` shape, the four source kinds (`$flowctx` / `$property` / `$activity` / `$loop`), function calls, and `@foreach` loops. |
| **flogobuild** | CLI reference | Reference for **building executables** and TIBCO Platform deployment artifacts from `.flogo` files. |
| **tibcop** | CLI reference | Reference for the **TIBCO Platform CLI** — manage builds, deploy, scale, and inspect Flogo applications on a dataplane. |
| **flogo-deploy** | Recipe | End-to-end recipe to **deploy a `.flogo` app to a TIBCO Platform dataplane** (build → values → deploy → scale). |
| **flogo-unit-testing** | Recipe | Recipe to **create and run unit tests for Flogo apps** — test files, test cases with flow inputs, assertions on flow outputs, and test execution with result verification. |
| **mapping-from-excel** | Recipe | Recipe to **build a Flogo flow from an Excel mapping spec** — input fields, output fields, and per-field mapping rules. |
| **rest-to-database-app** | Recipe | Recipe to **scaffold a REST API Flogo app that queries a database** (REST trigger → log → DB query → reply). |
| **agentic-ai-use-case-builder** | Use-case builder | Build a **governed-by-default Agentic AI use case for any vertical** — an MCP Server (read-only DB tools) + A2A Agents app (write-workflow agents) + WebSocket AI Orchestrator, backed by PostgreSQL, modeled on the reference use cases under `samples/Agentic_AI/`. It passes the **decision framework** first (agent vs. deterministic vs. human-owned), enforces identity, scoping, prices and state changes **in SQL** (scoped reads, guarded writes, two-step confirm, routed review cases), supports **two build methods** (**from scratch via the `fda` CLI** — recommended default — or **cloning an existing reference app**), and proves it with a **4-step test ladder** ending in a real chat that includes a **prompt-injection attempt** (a user message that tries to talk the agent past its rules — e.g. "ignore your rules and do X" — which fails because the rules live in SQL, not the prompt). Worked examples: `samples/Agentic_AI/Industry_Use_Cases/Airline_Passenger_Services_Use_Case/` and `.../Scholarly_Publishing_Author_Services_Use_Case/`. |

---

## The Skills in Detail

Each skill below lists **what it does**, **how to invoke it**, a **template prompt** (fill in the `<placeholders>`), and a couple of **example prompts** you can paste as-is. You rarely have to name a skill — describing the task in plain language is enough for the agent to pick the right one (see [Do the skills load automatically?](#do-the-skills-load-automatically)).

### CLI references

These are the command references the agent leans on. You'll usually trigger them indirectly (a recipe skill defers to them), but you can also ask for a single CLI action directly.

#### `fda` — Flogo Design Assistant CLI &nbsp;<sub>(skill identifier: `flogo-design-assistant`)</sub>

- **What it does:** The full command reference for creating and modifying `.flogo` files — projects, flows, triggers, activities, connections, schemas, app properties, and mappings. Almost every other skill defers to this one for the underlying `fda` commands.
- **How to invoke it:** Describe a `.flogo` structural change in natural language and the agent pulls this reference in automatically. You rarely call it on its own.
- **Template prompt:**
  > *"Using `fda`, add a `<activity type>` activity to the `<FlowName>` flow in `<app>.flogo` and wire `<source>` into `<target field>`."*
- **Example prompts:**
  > *"Add a PostgreSQL query activity to the `getOrders` flow in `orders-api.flogo` and connect it to the `OrdersDB` connection."*
  >
  > *"Add an app property `LLM.ApiKey` of type password to `assistant.flogo`."*

#### `fda-mapping` — Flogo mapping reference

- **What it does:** Focused reference for building, inspecting, and validating Flogo mappings — the `input.mapping` shape, the four source kinds (`$flowctx` / `$property` / `$activity` / `$loop`), qualified function calls, and `@foreach` loops — plus the `mm` / `sms` / `cm` commands and the "check before build" gate.
- **How to invoke it:** Ask to map, fix, or validate fields in an app.
- **Template prompt:**
  > *"Map `<source field>` to `<target field>` in the `<MapperName>` mapper of `<app>.flogo`, then validate all mappings."*
- **Example prompts:**
  > *"Validate the mappings in `customer-api.flogo` and fix any unresolved mapper fields."*
  >
  > *"In `orders.flogo`, map each item of `$activity[Query].output.records` into the response array with a `@foreach` loop."*

#### `flogobuild` — Flogo build CLI reference

- **What it does:** Reference for building runnable executables (and TIBCO Platform deployment artifacts) from `.flogo` files, plus running a built app locally to inspect its logs.
- **How to invoke it:** Ask to build an app or run it locally.
- **Template prompt:**
  > *"Build `<app>.flogo` with the configured build context and run it locally for 5 seconds, then show me the logs."*
- **Example prompts:**
  > *"Build `customer-api.flogo` and run it locally for 5 seconds."*
  >
  > *"Compile `orders-api.flogo` to an executable in the `bin/` folder."*

#### `tibcop` — TIBCO Platform CLI reference &nbsp;<sub>(skill identifier: `tibco-platform-cli`)</sub>

- **What it does:** Reference for the TIBCO Platform CLI — list dataplanes and apps, create builds, deploy, scale, and inspect Flogo applications on a dataplane. The `flogo-deploy` recipe builds on it.
- **How to invoke it:** Ask about platform state or a platform action.
- **Template prompt:**
  > *"Using `tibcop`, list the apps on dataplane `<DATAPLANE_NAME>` and show their status."*
- **Example prompts:**
  > *"List my TIBCO Platform dataplanes."*
  >
  > *"Scale the `customer-api` app on `<DATAPLANE_NAME>` to 2 replicas."*

### Recipes

Step-by-step workflows that chain several CLI steps into one outcome.

#### `flogo-deploy` — deploy to the TIBCO Platform

- **What it does:** End-to-end recipe to deploy a `.flogo` app to a dataplane — pick a Flogo version, create a build, generate values, deploy the release (`flogo:deploy-app-release`), and scale it up.
- **How to invoke it:** Ask to deploy an app to a dataplane (provide the app file and the target dataplane).
- **Template prompt:**
  > *"Deploy `<app>.flogo` to dataplane `<DATAPLANE_NAME>` and start it."*
- **Example prompts:**
  > *"Deploy `Flogo_Apps/customer-api.flogo` to dataplane `MyDataPlane` and start it."*
  >
  > *"Push `orders-api.flogo` to the `prod-dp` dataplane and scale it to 2 instances."*

#### `flogo-unit-testing` — create & run unit tests

- **What it does:** Creates unit test files, test cases with flow inputs, and assertions on flow outputs, then runs them with `flogobuild test-app` and verifies every assertion passes.
- **How to invoke it:** Ask to test the flows in an app (name the flows and the expected outputs, or let it derive them).
- **Template prompt:**
  > *"Create and run unit tests for `<app>.flogo` covering `<flow(s)>`, with assertions on `<expected outputs>`."*
- **Example prompts:**
  > *"Create and run unit tests for `books-api.flogo` — one case per flow, asserting the response code and body."*
  >
  > *"Add a unit test to `customer-api.flogo` that sends `id=42` and asserts the returned name is `Ada`."*

#### `mapping-from-excel` — build a flow from an Excel mapping spec

- **What it does:** Reads an Excel workbook that describes field mappings (one sheet per mapper) and builds a Flogo app that performs them — one mapper activity per sheet, chained in order, feeding a log activity behind a timer trigger.
- **How to invoke it:** Point it at an `.xlsx` mapping file.
- **Template prompt:**
  > *"Read `<file>.xlsx` and create a Flogo flow that performs the mapping defined in the spreadsheet."*
- **Example prompts:**
  > *"Read `ExcelWithMapping.xlsx`, create the Flogo flow, then build and run it locally for 5 seconds and show me the logs."*
  >
  > *"Turn the mappings in `order-transform.xlsx` into a multi-mapper Flogo flow called `order-mapper`."*

#### `rest-to-database-app` — REST API over a database

- **What it does:** Scaffolds a REST API Flogo app that queries a database and returns the result — a `tr_rest` trigger → log → DB query (MySQL / PostgreSQL / SQL Server / Oracle) → reply, with the DB connection wired to app properties.
- **How to invoke it:** Describe the endpoint and the target database.
- **Template prompt:**
  > *"Create a Flogo app named `<name>` that exposes `<METHOD /path>` and queries a `<database>` database, returning the result."*
- **Example prompts:**
  > *"Create a Flogo app `customer-api` that exposes `GET /customers/{id}` and queries a MySQL database."*
  >
  > *"Scaffold a PostgreSQL-backed REST app with `GET /orders` and `GET /orders/{id}`."*

### Use-case builder

#### `agentic-ai-use-case-builder` — a governed-by-default Agentic AI use case for any vertical (decision framework + rules in SQL)

- **What it does:** Builds a complete, runnable, **governed-by-default** Agentic AI use case — an **MCP Server** (read-only DB tools) + an **A2A Agents** app (write-workflow agents) + a **WebSocket AI Orchestrator**, backed by PostgreSQL — modeled on the reference use cases under `samples/Agentic_AI/`. It also produces `database.sql`, `reset_data.sql`, `prompts.md`, and a README. It first classifies every operation with the Agentic AI decision framework: **human-owned** (routed review case), **agent** (semantic reasoning, minimised read-only input) or **deterministic** (a SQL rule function). Reads are scoped by a session token, writes are `INSERT … SELECT rule_fn()` (0 rows when blocked), state changes are two-step propose → confirm, and each WebSocket connection gets its own conversation. It supports **two build methods** and asks which to use up front: **from scratch via the `fda` CLI** (recommended default) or **cloning an existing reference app**. It ships `validate_governed_apps.py` (G1–G9 governance checks) and a **4-step test ladder**: SQL rules → static → MCP edge → chat end to end (including a prompt-injection attempt), asserting on DB state.
- **How to invoke it:** Describe the vertical, the persona, and the read + action capabilities you want. Explicit: `/agentic-ai-use-case-builder`. It shows the classification table and plan and builds nothing until you approve.
- **Template prompt:**
  > *"Build a governed `<vertical>` Agentic AI use case for `<persona>` (MCP Server + A2A Agents + WebSocket orchestrator) backed by PostgreSQL. The agent should `<the semantic step>`; the system must enforce `<rules>`; people decide `<exceptions>`. Ask me whether to use the FDA CLI or the clone method first, then test it end to end."*
- **Example prompts:**
  > *"Build a governed airline passenger-services assistant: travellers verify with a PNR + PIN, check flight status and connection risk (computed in SQL), get agent-ranked rebooking options for a missed connection, rebook in two confirmed steps, and email the confirmation; compensation, baggage and name-change requests go to people. Test it end to end."*
  >
  > *"Build a governed author-services assistant for a scholarly publisher: authors verify with ORCID, get journal suggestions for a transfer, see APC coverage, and transfer in two steps; waivers and appeals go to people."*

---

## Do the skills load automatically?

**Yes.** Every skill in this library is marked `user-invocable: true`, and the coding agent discovers them on its own:

- **Auto-discovery.** The agent always keeps each skill's `name` and `description` in context. When your request matches a skill's description, the agent opens and follows that skill automatically — you don't have to name it. (Ask *"deploy this app to my dataplane"* and it reaches for `flogo-deploy`.)
- **When they apply.** The skills live under `.claude/skills/` and apply whenever that folder is on the path from your open workspace. In a Marketplace-seeded project the skills sit at the repo root, so they apply everywhere. In **this hub repo** they live under `skills-library/.claude/skills/`, so they apply when you're working on files under `skills-library/` — open `skills-library/` as your workspace to have them apply repo-wide. The project conventions in `AGENT.md` / `CLAUDE.md` load the same way.
- **Explicit invocation.** Because they're all user-invocable, you can also trigger one deliberately: type `/` in Claude Code to see the list and select a skill, or just name it in your prompt (*"use the fda-mapping skill to …"*). The identifier shown is the skill's `name` from its frontmatter — which matches the folder name for every skill **except two**: the `fda/` folder's skill is named **`flogo-design-assistant`**, and the `tibcop/` folder's skill is named **`tibco-platform-cli`**.
- **What they need.** A skill only runs its CLI steps once the tools and `config.md` are set up (see [Required Tools](#required-tools) and [Configurable Defaults](#configurable-defaults)). Without `config.md`, the agent will ask you to create it from the template first.

---

## Architecture: Coding Agent + Flogo

The skills work alongside the rest of the Flogo developer toolkit. The coding agent uses **VS Code with the Flogo Design Assistant** for design-time editing, **flogobuild** for local builds, and the **TIBCO Platform CLI (`tibcop`)** to deploy applications to a dataplane on the TIBCO Platform.

![Architecture: VS Code + Skills + Design Assistant + builders + dataplane](./images/architecture.png)

---

## Example: Excel-to-Flogo Mapping

Using the `mapping-from-excel` skill, the agent can read an Excel mapping spec — input fields in column A, output fields in column B, and a mapping expression in column C — and turn it into a fully wired Flogo flow with two mappers, a logger, and a timer trigger.

![Excel mapping spec turned into a Flogo flow](./images/excel-to-flogo-mapping.png)

A typical prompt:

> *"Read `ExcelWithMapping.xlsx` and create a Flogo flow that performs the mapping defined in the spreadsheet. Then build it and run it locally for 5 seconds and show me the logs."*

---

## Example: Design, Build, Run, and Deploy

The `flogo-deploy` skill chains together the build (`flogobuild`), values generation, deployment (`tibcop flogo:deploy-app-release`), and scale-up (`tibcop flogo:scale-app`) steps. The agent can take an app from source to a running instance on the TIBCO Platform in a single conversation.

![Deployment success with build ID, app ID, and live logs in the platform](./images/deployed-app.png)

A typical prompt:

> *"Deploy the `Flogo_Apps/customer-api.flogo` app to dataplane `<DATAPLANE_NAME>` and start it."*

---

## Getting Started

### Option 1: Install via the Marketplace template

1. Open the **Flogo Skill Library** entry in the TIBCO Developer Hub Marketplace.
2. Click **Get** to install the documentation.
3. Click the **Run Flogo Skill Library Template** button to generate a new project pre-seeded with the skills.
4. Open the generated GitHub repo in **VS Code with Claude Code** installed.
5. Copy `.claude/skills/config.example.md` to `.claude/skills/config.md` and fill in the values for your environment (build context, platform token, dataplane, database, LLM key). Agent conventions live in `AGENT.md`.
6. Start asking the agent to design, build, run, or deploy Flogo apps.

### Option 2: Add skills to an existing project

If you already have a project, copy the `.claude/skills/` folder from the seed repo into your project root, and add the conventions to your project's `AGENT.md`.

---

## Required Tools

The skills drive the following tools. **`fda` and `flogobuild` ship inside the TIBCO Flogo VS Code extension** — they are not on your `PATH` by default, so set up the `fda` alias (see [Setting up the `fda` alias](#setting-up-the-fda-alias)) to run them from any terminal. **`tibcop`** is installed separately and should be on your `PATH`.

| Tool | Purpose | Documentation |
|---|---|---|
| **fda** (Flogo Design Assistant) | Design-time edits to `.flogo` files (ships inside the Flogo VS Code extension) | [Flogo](https://docs.tibco.com/products/tibco-flogo-enterprise) |
| **flogobuild** | Build executables and Platform deployment artifacts (ships inside the Flogo VS Code extension) | [Flogo](https://docs.tibco.com/products/tibco-flogo-enterprise) |
| **tibcop** (TIBCO Platform CLI) | Deploy and manage applications on the TIBCO Platform | [TIBCO Platform](https://www.tibco.com/platform) |
| **TIBCO Flogo VS Code extension** | Provides `fda` + `flogobuild`, plus the visual designer for `.flogo` files | [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=tibco.flogo) |
| **Claude Code** (or another coding agent) | Reads and applies the skills | [Claude Code](https://www.anthropic.com/claude-code) |

---

## Setting up the `fda` alias

The Flogo Design Assistant CLI (`flogodesign-cli`) ships inside the [**TIBCO Flogo VS Code extension**](https://marketplace.visualstudio.com/items?itemName=tibco.flogo) at a long, versioned path like `<vscode-extensions-dir>/tibco.flogo-<VERSION>/bin/flogodesign-cli`. Because that path **changes with every extension update**, don't hardcode it — set up an `fda` alias that **discovers the latest installed version dynamically**, so you (and the coding agent) can simply run `fda <task>` from any terminal.

> **Never hardcode the extension folder name** (e.g. `tibco.flogo-2.26.6-2851`). The glob `tibco.flogo-*/bin/flogodesign-cli*` sorted by newest always resolves to the latest installed version. If the binary can't be found, install the TIBCO Flogo VS Code extension.

Add the function below to your shell startup file so `fda` is available in every terminal session:

| OS | Shell | Startup file |
|---|---|---|
| Windows | Git Bash | `~/.bashrc` |
| Windows | PowerShell | `$PROFILE` |
| macOS | zsh (default) | `~/.zshrc` |
| Linux | bash | `~/.bashrc` |

### macOS / Linux / Windows (Git Bash) — Bash or Zsh function

Add to `~/.bashrc` (bash / Git Bash) or `~/.zshrc` (macOS zsh):

```bash
fda() {
  local cmd="" home_dir="${HOME:-$USERPROFILE}" ext_name="flogodesign-cli"
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    ext_name="flogodesign-cli.exe"
  fi
  for dir in "$home_dir/.vscode/extensions" \
             "$home_dir/.vscode-insiders/extensions" \
             "$home_dir/.vscode-server/extensions"; do
    cmd=$(ls -td "$dir/tibco.flogo-"*/bin/"$ext_name" 2>/dev/null | head -1)
    [ -n "$cmd" ] && break
  done
  if [ -z "$cmd" ]; then
    echo "Error: flogodesign-cli not found. Install the TIBCO Flogo VS Code extension." >&2
    return 1
  fi
  "$cmd" "$@"
}
```

Reload the shell so the function takes effect:

```bash
source ~/.zshrc   # or: source ~/.bashrc
```

### Windows — PowerShell function

PowerShell aliases cannot accept arguments, so define `fda` as a **function**. Add to your PowerShell profile (`$PROFILE`):

```powershell
function fda {
  $cli = Get-ChildItem "$env:USERPROFILE\.vscode\extensions\tibco.flogo-*\bin\flogodesign-cli.exe" -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $cli) {
    $cli = Get-ChildItem "$env:USERPROFILE\.vscode-insiders\extensions\tibco.flogo-*\bin\flogodesign-cli.exe" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  if (-not $cli) { Write-Error "flogodesign-cli not found. Install the TIBCO Flogo VS Code extension."; return }
  & $cli.FullName @args
}
```

If `$PROFILE` doesn't exist yet, create it first, then reload it:

```powershell
New-Item -Type File -Path $PROFILE -Force   # only if it doesn't exist yet
. $PROFILE
```

### Verify

```bash
fda version
```

---

## Configurable Defaults

All environment-specific values live in a **single source of truth**: `config.md`, next to the skills. Copy the template and fill in your values (the file is git-ignored, so real credentials are never committed). The skills folder lives at `.claude/skills/` in a Marketplace-seeded project, or at `skills-library/.claude/skills/` in this hub repo — run the copy from your repo root accordingly:

```bash
# Marketplace-seeded project (skills at the repo root):
cp .claude/skills/config.example.md .claude/skills/config.md

# this hub repo:
cp skills-library/.claude/skills/config.example.md skills-library/.claude/skills/config.md
```

Key values the skills rely on:

| Key (in `config.md`) | What to set it to | How to find the value |
|---|---|---|
| `FLOGOBUILD_CONTEXT_NAME` | Build context name for `flogobuild` (e.g. `flogo-vscode-2.26.5-ENGR-001`) | `flogobuild list-context` |
| `DATAPLANE_NAME` | Default dataplane to deploy to | `tibcop tplatform:list-data-planes` |
| `CP_URL` / `TIBCOP_TOKEN` | TIBCO Platform control-plane URL and API token | TIBCO Platform console |
| PostgreSQL / LLM / email | Connection settings for the database, LLM provider, and SMTP | your environment |
| `AGENTIC_USE_CASES_DIR` | *(optional)* folder of reference Agentic AI use-case apps the `agentic-ai-use-case-builder` skill clones/studies | leave unset to default to `samples/Agentic_AI/`; set only if the skill is installed standalone away from that folder |

---

## Layout

```
.
├── .claude/
│   └── skills/                       # Skill definitions consumed by the AI coding agent
│       ├── fda/                      # Flogo Design Assistant CLI reference
│       ├── fda-mapping/              # Flogo mapping reference for the fda CLI
│       ├── flogobuild/               # Flogo build CLI reference
│       ├── tibcop/                   # TIBCO Platform CLI reference
│       ├── flogo-deploy/             # End-to-end deployment recipe
│       ├── flogo-unit-testing/       # Create and run Flogo unit tests
│       ├── mapping-from-excel/       # Build a Flogo flow from an Excel mapping spec
│       ├── rest-to-database-app/     # Scaffold a REST -> DB Flogo app
│       ├── agentic-ai-use-case-builder/  # Governed-by-default Agentic AI use case (MCP + A2A + orchestrator); decision-framework gate, rules in SQL, fda-CLI or clone method, 4-step test ladder
│       ├── config.example.md         # Template for environment-specific values (copy to config.md)
│       └── config.md                 # Your environment values (git-ignored; not committed)
├── AGENT.md                          # Project-level instructions for the agent
└── Flogo_Apps/                       # Place your .flogo applications here
```

## Example prompts

- *"Create a Flogo app under `Flogo_Apps/` that exposes a REST endpoint `GET /customers/{id}` and queries a MySQL database. Call the app `customer-api`."* (`rest-to-database-app`)
- *"Read `mapping.xlsx` and create a Flogo flow that performs the mapping defined in the spreadsheet."* (`mapping-from-excel`)
- *"Inspect and validate the mappings in `Flogo_Apps/customer-api.flogo` and fix any unresolved mapper fields."* (`fda-mapping`)
- *"Build the `Flogo_Apps/customer-api.flogo` app and run it locally for 5 seconds, then show me the logs."* (`flogobuild`)
- *"Create and run unit tests for `Flogo_Apps/customer-api.flogo` with assertions on the response."* (`flogo-unit-testing`)
- *"List my TIBCO Platform dataplanes and show the status of the apps running on `MyDataPlane`."* (`tibcop`)
- *"Deploy the `Flogo_Apps/customer-api.flogo` app to dataplane `MyDataPlane`."* (`flogo-deploy`)
- *"Build a governed Agentic AI use case for a transit agency's rider-refund desk (MCP Server + A2A Agents + WebSocket orchestrator) backed by PostgreSQL — rules in SQL, refunds over the limit go to a person. Ask me whether to use the FDA CLI or the clone method first, then test it end to end."* (`/agentic-ai-use-case-builder`)

> **Note:** For more sample prompts, see [skills-library/SamplePrompts/README.md](SamplePrompts/README.md).

---

## Tips for Working with the Agent

- **Be explicit about file paths.** The agent works best when you tell it where to put the `.flogo` file (e.g. `Flogo_Apps/customer-api.flogo`).
- **Iterate in small steps.** Ask for a flow first, then add activities, then add the trigger, then build & test.
- **Always run a local test before deploying.** The `mapping-from-excel` and `rest-to-database-app` recipes both include a build + 5-second-run step.
- **Check the agent's commands.** The `fda` and `tibcop` commands are well-documented in the skills — if the agent does something unexpected, ask it to explain which skill it used and which command it ran.

---

<!-- SEO Keywords: TIBCO Flogo, AI Coding Agent, Claude Code, AI Skills, Flogo Design Assistant, FDA CLI, Flogobuild, TIBCO Platform CLI, Low-Code, No-Code, iPaaS, Integration Automation, Excel to Flogo, REST API Scaffolding, Flogo Deployment, AI-Powered Development, Visual Flow Designer, Enterprise Integration, GoLang, VS Code Extension -->

**Topics:** `AI Coding Agent` · `Claude Code` · `Flogo Skills` · `Low-Code` · `iPaaS` · `Enterprise Integration`
