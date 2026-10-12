# Environment Configuration

All skills reference this file for environment-specific values.

**This is a TEMPLATE. Copy it to `config.md` and fill in your own values:**

```
cp config.example.md config.md
```

`config.md` is git-ignored so your real credentials are never committed.
Never put real secrets in this template.

> **Format rules (the scripts parse this file):**
> - Table rows are read as `| KEY | `value` | …` — only the **first backticked value** in a row is used,
>   so put exactly one value per row. Anything still shown as `<placeholder>` is treated as **unset**.
> - The LLM / email sections use `Key: value` lines. Keys match case-insensitively and a space equals an
>   underscore (`API Key:` == `API_Key:`), but prefer the underscore form shown here.
> - Use **native paths** for your OS (`C:\…\psql.exe` on Windows, `/usr/bin/psql` on Linux/macOS).
>   Leave a CLI path as its placeholder if the tool is already on your `PATH`.
> - Prerequisites (what to install, versions, where from) and the preflight checker are described in
>   [`../../AGENT.md` → Prerequisites and preflight](../../AGENT.md#prerequisites-and-preflight).

---

## PostgreSQL

| Key | Value | Read by |
|---|---|---|
| PSQL_PATH | `<path-to-psql>` | agentic-ai-use-case-builder test scripts, preflight |
| PG_HOST | `localhost` | agentic-ai-use-case-builder (apps + tests), preflight |
| PG_PORT | `5432` | same as above |
| PG_USER | `postgres` | same as above |
| PG_PASSWORD | `<your-postgres-password>` | same as above (env `PG_PWD` / `PG_PASSWORD` wins) |

> `PSQL_PATH` — full path to the `psql` client, one value only. Examples:
> - Windows: `C:\Program Files\PostgreSQL\<version>\bin\psql.exe`
> - macOS (Homebrew): `/opt/homebrew/bin/psql` (Apple Silicon prefix) or `/usr/local/bin/psql`
> - Linux: `/usr/bin/psql`
>
> If you leave the placeholder, the scripts use env `PSQL`, then `psql` on your `PATH`.

---

## LLM Provider Connection or LLM Client Activity Configuration

*Read by: agentic-ai-use-case-builder (baked into the AI Agent / LLM connections), preflight.*

LLM_Provider: OpenAI

API_Key: <your-openai-api-key>

LLM_Base_URL:

LLM_Model: gpt-5.5

LLM_Temperature: 0

> Leave `LLM_Base_URL` **empty** for OpenAI (the connector uses the OpenAI default endpoint).
> Set it only for Azure OpenAI, a gateway/proxy, or a non-OpenAI provider.
>
> **`LLM_Model` defaults to `gpt-5.5`** — the AI **Orchestrator** must do multi-step tool-calling and
> hand off to the A2A agent, and nano-class models (e.g. `gpt-5-nano`) drop tool calls and fail to
> delegate. Use a capable tool-calling model (`gpt-5.5`, or a Claude Sonnet-/Opus-class or
> Gemini 2.5 Pro-class model). Because all rules live in SQL, a cheaper runtime model only lowers
> conversation quality, never safety — pick the cheapest model that still delegates reliably (confirm
> at test step 4). Set this **before** building so the apps are baked with the right model.

---

## Email Server, Username and app password

*Read by: agentic-ai-use-case-builder — only for use cases with an email tool; preflight warns if unset.*

Server: smtp.gmail.com
Username: <your-email-address>
Port: 465
Password: <your-app-password>

> For Gmail, `Password` must be an **app password**, not your account password — create one at
> https://support.google.com/accounts/answer/185833 (requires 2-Step Verification).

---

## Agentic AI Use Cases (skill: `agentic-ai-use-case-builder`)

| Key | Value | Read by |
|---|---|---|
| AGENTIC_USE_CASES_DIR | *(optional — leave unset)* | agentic-ai-use-case-builder |

Optional override — a path **relative to the repo root** (or an absolute path) to the
folder holding the reference Agentic AI use-case apps that the agentic skill
clones/studies. **Leave this unset** to use the built-in default `samples/Agentic_AI/`,
which is correct when the skills ship inside `flogo-enterprise-hub`. Set it only if
your reference apps live elsewhere — e.g. `skills-library/` is installed standalone in
another project. If the folder can't be found, the skills will ask you to point to it.

## Flogo VSCode Extension

| Key | Value | Read by |
|---|---|---|
| VSIX_FILE_PATH | `<path-to-flogo-vscode-extension.vsix>` | flogobuild (`create-context -v`) |
| FLOGOBUILD_CONTEXT_NAME | `<your-build-context-name>` | flogobuild, mapping-from-excel, flogo-unit-testing, agentic-ai-use-case-builder |
| FLOGO_VERSION | `<extension-version, e.g. 2.26.6>` | reference only |

> - `VSIX_FILE_PATH` — the Flogo VS Code extension `.vsix` you downloaded (Marketplace / TIBCO); used only to create a build context.
> - `FLOGOBUILD_CONTEXT_NAME` — create it with `flogobuild create-context -n <name> -v <VSIX_FILE_PATH> --set-default`;
>   names allow letters, digits, `_`, `-` (3–30 chars, **no dots**). List existing ones with `flogobuild list-context`.
> - `FLOGO_VERSION` — minimum supported VS Code extension is **2.26.6**.

---

## Flogo Design CLI (flogodesign-cli)

| Key | Value | Read by |
|---|---|---|
| FLOGODESIGN_CLI_PATH | `<path-to-flogodesign-cli>` | fallback only — fda is discovered dynamically |
| FLOGODESIGN_CLI_VERSION | `<output of fda version>` | reference only |

> The extension folder name is **version-specific** — do not hardcode it. The scripts and the `fda`
> alias in [../../README.md](../../README.md) discover the newest
> `~/.vscode*/extensions/tibco.flogo-*/bin/flogodesign-cli[.exe]` automatically; set this row only if
> discovery fails (e.g. a non-standard VS Code install).

---

## Flogobuild CLI

| Key | Value | Read by |
|---|---|---|
| FLOGOBUILD_PATH | `<path-to-flogobuild>` | flogobuild, flogo-unit-testing, agentic-ai-use-case-builder, preflight |
| FLOGOBUILD_VERSION | `<output of flogobuild version>` | reference only |

> `flogobuild` (Flogo App Build CLI) is needed **only when building** — download it from the
> [TIBCO downloads page](https://www.tibco.com/downloads/11810) (it is **not bundled in the VS Code extension**). Building Flogo apps also
> requires the **Go runtime** ([go.dev/dl](https://go.dev/dl/); check with `go version`). Point this at
> `<unzip-dir>/<os>_<arch>/flogobuild[.exe]`, or leave the placeholder if `flogobuild` is on your `PATH`.

---

## TIBCO Platform CLI (tibcop)

| Key | Value | Read by |
|---|---|---|
| TIBCOP_PATH | `<path-to-tibcop>` | tibcop, flogo-deploy |
| TIBCOP_VERSION | `<output of tibcop --version>` | reference only |
| TIBCOP_PROFILE | `<your-tibcop-profile-name>` | flogo-deploy, tibcop (`--profile`) |
| CP_URL | `https://<your-subscription>.<region>.my.tibco.com` | tibcop, flogo-deploy |
| DATAPLANE_NAME | `<your-dataplane-name>` | tibcop, flogo-deploy |
| TIBCOP_TOKEN | `<your-platform-token>` | tibcop, flogo-deploy |

> - `TIBCOP_PATH` — leave the placeholder if `tibcop` is on your `PATH`.
> - `tibcop` is needed **only when deploying** to TIBCO Platform.
> - `TIBCOP_PROFILE` — create with `tibcop add-profile --name "<profile>" --cpurl https://<SUBSCRIPTION>.<REGION>.my.tibco.com` (optional `--software-statement <software_statement>`); list with `tibcop list-profiles`.

---

## Flogo License

| Key | Value | Read by |
|---|---|---|
| LICENSE_FILE_PATH | `<path-to-flogo-license.bin>` | flogobuild (`build-exe -l`, optional) |

> Optional for local non-production builds — without a licence, local builds on non-Linux hosts run as
> non-prod and stop after 24 hours.

---

## Output Directory

| Key | Value | Read by |
|---|---|---|
| FLOGO_APPS_DIR | `../../Flogo_Apps` | all skills that create `.flogo` apps |

> Path is **relative to this `config.md`** (which lives at
> `skills-library/.claude/skills/`), so `../../Flogo_Apps` resolves to
> `skills-library/Flogo_Apps/` — the one physical folder that is the same
> whether you open the repo root or `skills-library/` as your workspace. Use an
> absolute path if you prefer. *(The old `../../../Flogo_Apps` pointed at a
> `Flogo_Apps/` at the repo root, which only exists in the hub layout.)*
