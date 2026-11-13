# AGENT.md

**What this is:** `skills-library` is a collection of skills for AI coding agents (such as Claude Code) that automate designing, building, testing, and deploying TIBCO Flogo integration applications. This `AGENT.md` holds the project-level conventions the agent follows on every task; the individual capabilities live under `.claude/skills/`.

**Prerequisites:** see [Prerequisites and preflight](#prerequisites-and-preflight) below. In short: **designing** Flogo apps needs only **VS Code + the TIBCO Flogo VS Code extension 2.26.7 or later** (it ships `fda` = `flogodesign-cli`; nothing separate to install). The **Flogo App Build CLI** (`flogobuild`) and the **Go runtime** are needed only when you ask to **build** (executables, Platform zips, unit tests); `tibcop` plus a **TIBCO Platform account** and profile only when you ask to **deploy** (stored in `.claude/skills/config.md`: `CP_URL`, `TIBCOP_TOKEN`, `DATAPLANE_NAME`, `TIBCOP_PROFILE`). The agentic use-case builder additionally needs PostgreSQL + `psql`, Python 3.9+ and an LLM API key.

## Prerequisites and preflight

**Run the preflight first** (from the repo root; stdlib-only, Windows/macOS/Linux). It checks only the tiers you ask for:

```bash
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py                    # Tier 1: design only (fda)
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need db          # + Tier 2: agentic use case (PostgreSQL, Python)
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need build,chat  # + Tier 3: build executables / chat e2e
python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need deploy      # + Tier 4: deploy to TIBCO Platform
```

It prints the exact install hint for anything missing and exits non-zero if a blocking check fails. `fda` always blocks; everything else blocks only when its tier is requested (`--need db` / `build` / `chat` / `deploy`) and is otherwise shown as INFO "not needed for design".

**Downloads:** the latest **TIBCO Flogo® Extension for Visual Studio Code** and the **Flogo App Build CLI (`flogobuild`)** are both on the [TIBCO downloads page](https://www.tibco.com/downloads/11810).

**Tier 1 — Design (always).** This is all you need to design Flogo apps.

| What | Why / needed for | Version floor | Install (Windows / macOS / Linux) |
|---|---|---|---|
| **VS Code + [TIBCO Flogo VS Code extension](https://marketplace.visualstudio.com/items?itemName=tibco.flogo)** | Visual designer; ships `fda` (`flogodesign-cli`) used by every skill — **nothing separate to install** | extension **2.26.7** (the 2.26.7 extension declares VS Code 1.83+; the installation guide names no VS Code version) | [TIBCO downloads page](https://www.tibco.com/downloads/11810) or the VS Code Marketplace (all OSes) |

**Tier 2 — Agentic use cases (`agentic-ai-use-case-builder`).** Design + SQL rule tests (`preflight.py --need db`).

| What | Why / needed for | Version floor | Install (Windows / macOS / Linux) |
|---|---|---|---|
| **PostgreSQL server + `psql`** | Demo databases; the test scripts call `psql` | 14+ | Win: [EDB installer](https://www.postgresql.org/download/windows/) · macOS: `brew install postgresql@16` or Postgres.app · Linux: `apt install postgresql postgresql-client` (or distro equivalent). Scripts find `psql` via env `PSQL` → `config.md` `PSQL_PATH` → `PATH` |
| **Python** | Build drivers, SQL rule tests, static validator, preflight | 3.9+ | [python.org](https://www.python.org/downloads/) / `brew install python` / distro package. (`pip install openpyxl` only for `mapping-from-excel`) |
| **LLM API key + capable model** | Agentic apps (AI Agent / orchestrator) | tool-calling model, `gpt-5.5` class | Your provider console. **Nano-class models drop tool calls** and fail to delegate — don't use them for orchestrators. Set `API_Key` / `LLM_Model` in `config.md` |

**Tier 3 — Build (only when you ask to build / run / test the apps).** `preflight.py --need build` (add `chat` for the chat end-to-end test).

| What | Why / needed for | Version floor | Install (Windows / macOS / Linux) |
|---|---|---|---|
| **`flogobuild`** (TIBCO Flogo App Build CLI) | Build local executables (`build-exe`), Platform zips, run unit tests (`test-app`) | 1.0.6 (use `-f <app>.flogo`; works on 1.0.6 and 1.1.x) | Download from the [TIBCO downloads page](https://www.tibco.com/downloads/11810) (not bundled in the VS Code extension). Unzip, put `<os>_<arch>/flogobuild[.exe]` on `PATH` or set `FLOGOBUILD_PATH` in `config.md` |
| **flogobuild build context** | Tells `flogobuild` which Flogo runtime/connectors to compile against | — | `flogobuild create-context -n <name-without-dots> -v <path-to-flogo-vsix> --set-default` (the extension `.vsix` from the TIBCO downloads page / Marketplace). Names: letters, digits, `_`, `-`; 3–30 chars; **no dots**. Check with `flogobuild list-context`; set `FLOGOBUILD_CONTEXT_NAME` in `config.md` |
| **Go runtime** | Building Flogo apps requires Go (`go version`); production-licensed binaries also need the **GCC** compiler on the build machine / container | **1.25.7+** (Flogo 2.26.8 installation guide) | [go.dev/dl](https://go.dev/dl/) (all OSes) / `brew install go` / distro package. The extension's **Install Prerequisites for Flogo Connectors** can also install Go |
| **Flogo licence file** | Production-licensed local builds | — | Optional for local non-prod builds. Without one, local builds on non-Linux hosts run as **non-prod and stop after 24 h**. Set `LICENSE_FILE_PATH` if you have one |
| **Node.js** | Chat e2e only — shared browser chatbot (`samples/Agentic_AI/Chatbot`) | 16+ | [nodejs.org](https://nodejs.org/) / `brew install node` / distro package or nvm |
| **`websocket-client`** (Python package) | Chat e2e only — the scripted WebSocket chat test | — | `pip install websocket-client` |

**Tier 4 — Deploy (only when you ask to deploy to TIBCO Platform).** `preflight.py --need deploy`.

| What | Why / needed for | Version floor | Install (Windows / macOS / Linux) |
|---|---|---|---|
| **`tibcop`** (TIBCO Platform CLI) + a profile | Deploy / scale on TIBCO Platform | 1.7+ (tested 1.7, 1.20) | Download from the [TIBCO Platform CLI download page](https://www.tibco.com/downloads/12464). Then `tibcop add-profile --name "<profile>" --cpurl https://<SUBSCRIPTION>.<REGION>.my.tibco.com` (optional `--software-statement <software_statement>`; alias `tibcop ap`) and check with `tibcop list-profiles`; put the profile name in `config.md` `TIBCOP_PROFILE` |

**Connector prerequisites (design time).** If an app uses a connector that needs a native driver or client library — the database connectors (PostgreSQL / Redshift, MySQL, SQL Server, Oracle, IBM DB2, Snowflake, SAP HANA, TIBCO Data Virtualization), SAP Solutions (NW RFC SDK), IBM MQ, TIBCO EMS / FTL / ActiveSpaces — install it **before** opening the app in the designer or fetching metadata (VS Code: **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…**, then reload). Oracle, DB2, EMS, FTL, ActiveSpaces, IBM MQ and SAP Solutions also need it to build and run. Per-connector install steps, env vars, OS limits and doc pages: [connector-prereqs.md](.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md).

**Notes**
- **Git Bash (Windows only):** the skills' shell snippets are bash — install [Git for Windows](https://git-scm.com/download/win). MSYS rewrites `/x` arguments into Windows paths — prefix `fda`/`flogobuild` calls with `MSYS_NO_PATHCONV=1` (or drive them from Python `subprocess`).
- **SMTP account:** only for samples with email tools — e.g. Gmail SMTP with an [app password](https://support.google.com/accounts/answer/185833) (requires 2-Step Verification).
- **Apple Silicon (M-series) Macs:** expected to work; not yet verified by the maintainers. The installation guide doesn't state macOS ARM support for the VS Code extension. It does ship a `darwin_arm64` Flogo App Build CLI, and on ARM64 Macs a Dev Container must run as `linux/amd64` with Rosetta emulation. The connector guide says TIBCO EMS is not supported on ARM machines.
- Use native paths in `config.md` (`C:\…` on Windows) — the Python scripts pass them straight to `subprocess`.

You are a software integration developer that uses TIBCO Flogo to build integration applications (`.flogo` files for Flogo 2.x, `<AppName>/app.fgmd` project folders for Flogo 3.x).

Use the `fda` (Flogo Design Assistant) command line tool to create and modify these applications.
The available skills under `.claude/skills/` document how to use the relevant CLIs and provide step-by-step recipes for common patterns.

**Prefer `fda` for every structural change to a `.flogo` — do not hand-edit its node graph.** There are only three narrow, documented cases where a direct, surgical text edit is the correct tool (no `fda` subcommand exists for them): (1) repairing a specific broken field on a file that has already been opened/edited in the Flogo designer (regenerating it would wipe secrets and orphan connection refs); (2) scrubbing live secrets out before publishing; and (3) the clone-and-adapt build method, which swaps fields inside a copied `.flogo`. **Never regenerate — or hand-edit — a `.flogo` that is currently open in the designer;** have the user Discard + close it first. The `agentic-ai-use-case-builder` skill documents the exact rules for these cases.

## Resolving the `fda` CLI

When the user says **`fda`**, **`flogodesign-cli`**, **"the Flogo CLI"** or **"the design CLI"**, they mean the `flogodesign-cli` binary bundled inside a TIBCO Flogo VS Code extension (`flogodesign-cli.exe` on Windows). `fda` is only shorthand; there is no `fda` binary on disk. Use a bundled binary — do not install or download another copy.

Two extension families can be installed side by side, any number of each:

| Flogo version | Extension folder | App on disk |
|---|---|---|
| **2.x** | `tibco.flogo-2.<minor>.<patch>-<build>…` | a single `<AppName>.flogo` file |
| **3.x** | `tibco.flogo3-<version>…` | a folder `<AppName>/` containing `app.fgmd` |

**Never hardcode an extension folder name** (e.g. `tibco.flogo-2.26.6-2851`) — it changes on every update. Discover the candidates at the time of use; never reuse a path baked into a document or an earlier conversation.

### Step 1: Discover the installed CLIs

```bash
HOME_DIR="${HOME:-$USERPROFILE}"
EXT_NAME="flogodesign-cli"
# Windows (Git Bash / msys / cygwin): binary has .exe extension
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
  EXT_NAME="flogodesign-cli.exe"
fi

# Search across VS Code variants (standard, Insiders, Remote/WSL); label each candidate 2.x or 3.x
for dir in "$HOME_DIR/.vscode/extensions" \
           "$HOME_DIR/.vscode-insiders/extensions" \
           "$HOME_DIR/.vscode-server/extensions"; do
  for p in "$dir"/tibco.flogo-2.*/bin/"$EXT_NAME"; do if [ -e "$p" ]; then echo "2.x  $p"; fi; done
  for p in "$dir"/tibco.flogo3-*/bin/"$EXT_NAME";  do if [ -e "$p" ]; then echo "3.x  $p"; fi; done
done
```

**Nothing found** → fall back to an `fda` already on `PATH` (`which fda`) or `FLOGODESIGN_CLI_PATH` in `config.md`. If neither exists, tell the user no Flogo extension was found and ask them to install the TIBCO Flogo VS Code extension. Do not invent a path.

### Step 2: Decide the Flogo version (2.x or 3.x)

- **The user names the version** ("Flogo 2.x app", "Flogo3 app") → use it. Do not ask.
- **Modifying an existing app** → detect it from the files: a `<name>.flogo` file is 2.x; a folder containing `app.fgmd` is 3.x. Do not ask.
- **The user has set a standing default** ("always use Flogo 3") → follow it until they change it.
- **New app, version not stated:**
  - Only **2.x** extensions installed → use **2.x**. Do not ask.
  - Only **3.x** extensions installed → use **3.x**. Do not ask.
  - **Both** installed → **ask the user: "Flogo 2.x or Flogo 3.x?"** before running any `fda` command. Ask for every new app that doesn't state it — an earlier app's version is not a default for the next one.

If the chosen version has **no** installed extension, don't fall back silently. Tell the user and offer the cross-type option: the other version's CLI can create the app with `--flogo-type` (`-T 2x`/`-T 2` for 2.x, `-T 3x`/`-T 3` for 3.x). Use it only if they agree.

### Step 3: Choose among candidates of that version

- **Exactly one** → use it, and mention which one you picked.
- **More than one** → **ask the user to choose.** List each candidate with its extension folder name (the version/build is the distinguishing part) and full path. Do not silently pick the newest by mtime — a newer folder is not necessarily the one the user is working against.

Once chosen, reuse that path (`$FDA`) for the rest of the session **for that Flogo version** without re-asking. If a later command fails because the path no longer exists, re-run discovery.

### Step 4: Report the resolved CLI version

Before any other work, run the `version` task and show the result together with the extension folder it came from (quote the path — it may contain special characters):

```bash
"$FDA" version     # e.g. "Flogo Design CLI Version: 0.9.x"
```

Do this once per Flogo version per session, not before every command.

**Don't confuse it with its siblings.** The same `bin` folder ships `flogo-vscode-cli`, `flogo-dbservice-cli` and `flogo-sap-cli` (each with a `.exe` build on Windows). They are **not** interchangeable with `flogodesign-cli`.

Once `$FDA` is resolved, use the **`fda`** skill ([.claude/skills/fda/SKILL.md](.claude/skills/fda/SKILL.md)) for the actual work — creating or modifying a 2.x or 3.x app, flow, trigger, activity, connection, schema or mapping. Order: **discover → decide version → choose + report CLI version → `fda` skill.**

### Setting up a persistent `fda` alias

Add the function below to your shell startup file so `fda` is available in every terminal session.

> These aliases are a **convenience for interactive use**: they always run the newest **Flogo 2.x** install (`tibco.flogo-*` does not match `tibco.flogo3-*`). For Flogo 3.x, or to target a specific install, use the discovery steps above. **Agents must not use this function** — always invoke the resolved binary as `"$FDA" …`; a bare `fda` in a skill example is shorthand for `"$FDA"`.

| OS | Shell | File |
|---|---|---|
| Windows | Git Bash | `~/.bashrc` |
| Windows | PowerShell | `$PROFILE` |
| macOS | zsh (default) | `~/.zshrc` |
| Linux | bash | `~/.bashrc` |

**Bash / Zsh function** (add to `~/.bashrc` or `~/.zshrc`):

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

**PowerShell function** (add to `$PROFILE`):

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

## Project conventions

- Always work with Flogo applications inside the apps folder named by `FLOGO_APPS_DIR` in `config.md` — resolved **relative to `config.md`** (default `../../Flogo_Apps` → `skills-library/Flogo_Apps/`, the one physical folder that is identical whether the repo root or `skills-library/` is the open workspace). Do not create apps at the `skills-library/` root or the repo root.
- Always pass `-f` on every `fda` command except `create-project`: `-f <FLOGO_APPS_DIR>/<AppName>.flogo` for Flogo 2.x, `-f <FLOGO_APPS_DIR>/<AppName>` (the project folder) for Flogo 3.x.
- Run `create-project` from **inside** the `FLOGO_APPS_DIR` folder: it takes no `-f` and creates the project in the current directory, so running it from the repo root puts the app outside the apps folder. `mkdir -p "<FLOGO_APPS_DIR>" && cd "<FLOGO_APPS_DIR>" && "$FDA" cp <AppName> "<description>"`.
- To build applications, use the `flogobuild` CLI with the build context configured in `config.md` (`FLOGOBUILD_CONTEXT_NAME`).
- To deploy applications, use the `tibcop` (TIBCO Platform CLI) with the `flogo` topic and the platform credentials configured in `config.md` (`CP_URL`, `TIBCOP_TOKEN`, `DATAPLANE_NAME`).

## Configurable values for this project

All environment-specific values — build context, platform credentials, dataplane, database, LLM keys, and CLI paths — live in a **single source of truth**: [`.claude/skills/config.md`](.claude/skills/config.example.md). Read that file first; never duplicate these values across skills or in this document.

If `config.md` does not exist yet, copy the template and fill in your values:

```bash
cp .claude/skills/config.example.md .claude/skills/config.md
```

`config.md` is git-ignored, so your real credentials are never committed. Key values include `FLOGOBUILD_CONTEXT_NAME` (build context), `DATAPLANE_NAME`, `CP_URL` / `TIBCOP_TOKEN` / `TIBCOP_PROFILE` (platform), plus the PostgreSQL, LLM, and email settings.

To list available `flogobuild` contexts: `flogobuild list-context`
To list configured `tibcop` profiles: `tibcop list-profiles`

## Testing locally

To run and test an application locally:

1. Add a timer trigger to a flow that executes the flow on startup.
2. Use log activities to log output to the console.
3. Build with `flogobuild build-exe -f <FLOGO_APPS_DIR>/<AppName>.flogo -c <FLOGOBUILD_CONTEXT_NAME> -o <FLOGO_APPS_DIR>/../bin` (use the `FLOGOBUILD_CONTEXT_NAME` value from `config.md`; the `bin/` folder sits beside the apps folder, i.e. `skills-library/bin/`).
4. Run the executable for ~5 seconds and read the output logs:
   - **Git Bash (Windows) / Linux:** `timeout 5 <FLOGO_APPS_DIR>/../bin/<AppName> 2>&1 || true`
   - **macOS:** `timeout` is not built in — use `gtimeout 5 …` (from `brew install coreutils`), or start the exe, wait, and stop it with Ctrl+C / `kill <pid>`.
   - **Stopping a long-running exe on Windows:** bash `kill` does not stop native Windows processes. Find the PID by its port and kill it: `netstat -ano | grep :<port>` then `taskkill //PID <pid> //F` (double slashes in Git Bash; single `/PID` in cmd/PowerShell).
