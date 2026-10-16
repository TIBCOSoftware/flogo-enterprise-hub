# Running the Industry Use-Case samples

A shared run guide for every governed agentic sample under `Industry_Use_Cases/`. Each sample is three
PostgreSQL-backed Flogo apps — an **MCP Server** (scoped reads + guarded two-step writes), a read-only
**A2A Agents** app (reasoning agents), and a **WebSocket AI Orchestrator** — driven from the shared browser
[Chatbot](../Chatbot/).

Each sample's own README covers the **sample-specific** details: its database name, ports, the app-property
credentials table, demo logins and prompts. This guide covers the parts that are the **same for every
sample**: the run prerequisites, how to build and start the three apps, and how to connect the chat client.

---

## Quick setup (optional helper)

[`setup.py`](setup.py) (in this folder) does the one-time setup for a sample so you don't have to run the
steps below by hand. It checks prerequisites, validates your PostgreSQL connection and LLM key/model, ensures
a build context, creates and loads the database, and builds the apps' executables. Your credentials from
`config.md` are injected only into the git-ignored `./bin` build copies — the committed `.flogo` files stay
untouched.

```bash
python setup.py --list                           # list the samples
python setup.py <Sample_Use_Case folder name>    # runs: check -> config -> validate -> context -> db -> build
```

It does **not** start the apps. When it finishes, start them yourself (next section) and connect the Chatbot.
Prefer to do everything by hand? The rest of this guide is the full manual path.

---

## Prerequisites to *run* (beyond designing)

Opening and editing the apps needs only **VS Code + the TIBCO Flogo extension**. To actually **run** a
sample locally you also need:

- **Flogo App Build CLI (`flogobuild`) + the Go runtime** — to build a runnable executable from a `.flogo`.
- a **flogobuild build context** (created once, from the Flogo extension `.vsix`).
- **PostgreSQL 14+** and the PostgreSQL ODBC driver (a Flogo connector prerequisite).
- **Node.js 16+** — for the shared [Chatbot](../Chatbot/) web client.
- an **LLM API key** (e.g. OpenAI) and, for samples with the email tool, SMTP credentials.

Install steps and exact versions are in
[skills-library/AGENT.md → Prerequisites and preflight](../../../skills-library/AGENT.md#prerequisites-and-preflight).

> Prefer not to build locally? You can instead **deploy the apps to the TIBCO Platform** (`tibcop`) — see the
> deploy guidance in [AGENT.md](../../../skills-library/AGENT.md) — or use the **Run** action in the VS Code
> Flogo extension. The build-and-run steps below are the self-contained local path used by each sample's
> `_rebuild/` test ladder.

---

## One-time: create a build context

```bash
flogobuild create-context -n flogo-ctx -v <path-to-flogo-extension.vsix> --set-default
flogobuild list-context
```

Use the Flogo extension `.vsix` from the [TIBCO downloads page](https://www.tibco.com/downloads/11810) or the
VS Code Marketplace. Context names allow letters, digits, `_` and `-` (no dots).

> **RAG sample only** (Auto Insurance Policy & Claims): its MCP app uses the `extensions/openAI` vectorSearch
> activity, so build it with a context that *also* includes the repo extensions:
> `flogobuild create-context -n flogo-ctx-openai -v <vsix> -u <repo>/extensions --set-default`.

---

## Start the apps  <a id="start-the-apps"></a>

Run everything **from the sample's own folder**. Build each of the sample's `.flogo` apps into an executable:

```bash
flogobuild build-exe -f <AppName>.flogo -c <your-context> -o ./bin
```

Then run them, each in its **own terminal**, **in the order the sample README gives**
(**MCP Server → Agents → Orchestrator**):

- **Windows:** `./bin/<AppName>.exe`
- **macOS / Linux:** `./bin/<AppName>`

Wait for each app to log a clean start before starting the next. The **orchestrator must start last** — it
connects to the MCP server and the A2A agents at startup. (`./bin/` is git-ignored, so built executables stay
out of the repo.)

**Stop an app:**

- macOS / Linux: `Ctrl+C`.
- Windows: `Ctrl+C`, or find the PID by its port and kill it —
  `netstat -ano | findstr <port>` then `taskkill /PID <pid> /F`.

---

## Connect the chat client

The browser client is the shared app in [`samples/Agentic_AI/Chatbot`](../Chatbot/) (needs Node.js 16+). From
a sample folder:

```bash
cd ../../../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box (top right) enter the sample's orchestrator URL, e.g. `ws://localhost:<WS_PORT>/<path>`
   (the exact URL is in the sample's README).
3. **Click the ↻ (refresh) icon** next to the URL box. Typing the URL alone does nothing — ↻ applies it, and
   an alert confirms it.
4. Click **Connect**. The status turns green.

**Won't connect?** Click **Disconnect** (↻ is refused while connected), re-check the URL, click **↻**, then
**Connect**. The client remembers the last URL you applied, so a URL left over from another demo is a common
cause. Make sure the orchestrator is actually running on its port.

---

## Database and reset

- **First run:** loading `database.sql` already seeds the demo data (it `\ir`-includes `seed_data.sql`), so
  you do **not** need to run `reset_data.sql` before the first run — `reset_data.sql` is only for resetting
  the data **between** demos.
- Run `createdb` / `psql` **from the sample folder** — its `database.sql` pulls in `seed_data.sql` by a
  relative path, and `reset_data.sql` expects the same working directory.
- If `psql` / `createdb` aren't on your `PATH` (common on Windows), use the full path to the PostgreSQL `bin`
  directory, and set `PGPASSWORD` (or enter the password when prompted).
- Re-running `createdb` on an existing database errors with *"already exists"* — `dropdb <name>` first for a
  clean reload.
- Reset the demo data between runs with the sample's `reset_data.sql`, then reconnect the chatbot
  (**Disconnect** → **Connect**) so the next demo starts a fresh conversation.

---

## Rebuilding and automated tests

Each sample's `_rebuild/README.md` documents regenerating the apps from code and running the automated test
ladder (SQL rule tests, static validation, and the MCP / A2A / chat checks).
