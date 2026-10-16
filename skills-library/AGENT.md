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

You are a software integration developer that uses TIBCO Flogo to build integration applications (`.flogo` files).

Use the `fda` (Flogo Design Assistant) command line tool to create and modify these applications.
The available skills under `.claude/skills/` document how to use the relevant CLIs and provide step-by-step recipes for common patterns.

**Prefer `fda` for every structural change to a `.flogo` — do not hand-edit its node graph.** There are only three narrow, documented cases where a direct, surgical text edit is the correct tool (no `fda` subcommand exists for them): (1) repairing a specific broken field on a file that has already been opened/edited in the Flogo designer (regenerating it would wipe secrets and orphan connection refs); (2) scrubbing live secrets out before publishing; and (3) the clone-and-adapt build method, which swaps fields inside a copied `.flogo`. **Never regenerate — or hand-edit — a `.flogo` that is currently open in the designer;** have the user Discard + close it first. The `agentic-ai-use-case-builder` skill documents the exact rules for these cases.

## Resolving the `fda` CLI

The `fda` binary (`flogodesign-cli`) ships inside the TIBCO Flogo VS Code extension. Its path changes with every extension update, so **always discover it dynamically** before running any `fda` command:

```bash
# 1. Check if fda is already on PATH (user may have set up an alias/function)
which fda 2>/dev/null

# 2. If not found, discover the latest version dynamically
HOME_DIR="${HOME:-$USERPROFILE}"
EXT_NAME="flogodesign-cli"

# Windows (Git Bash / msys / cygwin): binary has .exe extension
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
  EXT_NAME="flogodesign-cli.exe"
fi

# Search across VS Code variants (standard, Insiders, Remote/WSL)
for dir in "$HOME_DIR/.vscode/extensions" \
           "$HOME_DIR/.vscode-insiders/extensions" \
           "$HOME_DIR/.vscode-server/extensions"; do
  FDA_PATH=$(ls -td "$dir/tibco.flogo-"*/bin/"$EXT_NAME" 2>/dev/null | head -1)
  [ -n "$FDA_PATH" ] && break
done

# 3. Use the discovered path (quote it — the path may contain special characters)
"$FDA_PATH" version
```

**Never hardcode the extension folder name** (e.g. `tibco.flogo-2.26.6-2851`). The glob `tibco.flogo-*/bin/flogodesign-cli*` with `-td` (sort by newest) always resolves to the latest installed version.

If neither `which fda` nor the dynamic scan finds the binary, ask the user to install the TIBCO Flogo VS Code extension.

### Setting up a persistent `fda` alias

Add the function below to your shell startup file so `fda` is available in every terminal session:

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
- Always pass `-f <FLOGO_APPS_DIR>/<AppName>.flogo` on every `fda` command to target the correct file.
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
