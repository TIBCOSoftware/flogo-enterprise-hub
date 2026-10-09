# Manual-config gap — the "below things are not configured…" section

`fda` builds the whole app graph, but a few things depend on **your** environment, **your** secrets, or a **running backend** — they can't be baked into a portable, secret-free app. Paste the block below (edited to the actual use case) at the **end of the generated `README.md`**, and tell the user the same thing when you hand off.

Keep the heading verbatim so it's unmistakable.

---

## ⚠️ Below things are NOT configured — please configure them manually before running the app end to end

The apps were generated with the Flogo Design CLI and build to `.exe`, but the following are intentionally **not** set (environment-, secret-, or backend-specific). Configure each before an end-to-end run:

1. **LLM credentials & endpoint.**
   - `API_Key` — **the only required LLM value.** Set your real provider key (kept out of the repo; inject as an app property / env at deploy).
   - `LLM_Model` — confirm the model (default `gpt-5-nano`) is available to your key.
   - `LLM_Base_URL` — **leave it empty for OpenAI** (the connector uses the OpenAI default). Set it only for Azure OpenAI, a gateway/proxy, or another provider. (It must never contain the text `New_value` — that makes the LLM call fail with `unsupported protocol scheme`.)
   - *(RAG apps only)* `OPENAI_API_ENDPOINT_URL` (OpenAI vector extension) must stay `https://api.openai.com/v1` — it rejects an empty value.

2. **PostgreSQL database & credentials.**
   - Create the database and load `database.sql` (then `reset_data.sql` to reset between demos).
   - Set `PostgreSQL.PostgresConn.Host/Port/Database_Name/User/Password` to your instance. The `Password` should be a real secret, not committed in plaintext.
   - Verify connectivity: run each MCP tool's `SELECT` and each A2A write's SQL against the DB.

3. **Ports must be free & consistent.**
   - MCP `<mcpPort>`, each A2A `<agentPort>`, and the orchestrator `<wsPort>` must be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match the MCP/A2A ports. If you change a port, change it in the property **and** in the corresponding orchestrator connection URL.

4. **Backend REST services for A2A action agents** *(NOT created by default — only present if the user explicitly asked for a REST backend).*
   - By default the A2A action agents write **directly to PostgreSQL** and no separate REST/backend app exists, so this item usually does not apply — **omit it from the README unless the build actually includes a REST agent.**
   - If a REST agent *was* requested: agents that `InvokeRESTService` need the target API **running and reachable** at the configured `<Backend>_URL` (including any `{pathParams}`). Stand up the real backend (or a mock) before invoking those agents. Without it, the agent's REST step fails even though the app is otherwise correct.

5. **Email / SMTP** *(only if an email agent is included).*
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, not the account password), and the recipient property.
   - Confirm outbound SMTP (Gmail: `smtp.gmail.com:465`, SSL) is allowed from the host/network.
   - **Re-enter `Email_App_Password` in the designer's App Properties panel so it is stored as a `SECRET:` value — do NOT change its type.** FDA `cap` writes the password as a plaintext `string`, but the `#sendmail` `Password` field only binds cleanly to a **secret-valued** property; a plaintext one shows *"Type of field 'Password' (password) differs from bound app property (string)"*. Fix it by opening App Properties and re-typing the password value once — the designer encrypts it to `SECRET:…`, which clears the ✗. ⚠️ **Leave the property's type as `string`.** There is no `password` app-property type; setting one makes the designer *silently drop the property on save*, turning the warning into a hard error: *"'Password' is bound to app property 'Email_App_Password' which does not exist."* It builds/runs as a string either way — this only clears designer validation.

6. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:<wsPort>/<usecase>`. Test it with the shared web client in `samples/Agentic_AI/Chatbot` (`npm install`, `npm start`, open http://localhost:3000). Enter the URL, **click the ↻ icon next to the URL box** (typing alone doesn't apply it), then **Connect**. Full steps: [chatbot-test.md](chatbot-test.md).
   - **All chat clients share ONE conversation memory.** The orchestrator's `conversationId` is empty, which the connector turns into a constant, so every client shares one history (up to `memoryMaxSize` messages) until the app restarts: simultaneous users see each other's context, and the growing history is the main runtime-token driver. **Restart the orchestrator between demos.** (Cost figures, on request: `build-cost-and-time.md`.)

7. **Deploy-time secret injection** *(if deploying to TIBCO Platform / Control Plane rather than running the local `.exe`).*
   - Provide `API_Key`, DB `Password`, and `Email_App_Password` as platform secrets / app properties at deploy time; do not ship them inside the app.
   - Ensure the build context / runtime version matches your target environment.

8. **Flogo Design Assistant (FDA) manual steps** *(Tech-Preview limitations — the apps still build/run as `.exe`; these clear designer validation and cover things FDA cannot configure). Full list + rationale in the skill's `fda-limitations.md`.*
   - **Sync every trigger.** FDA-built triggers are non-OpenAPI (`tr_mcpserver`, `tr_agent`, `tr_wsserver`), so some trigger/flow-input fields don't render and the `toolParams`/input mappings show a red ✗ until you click **"Sync"** once on each trigger. *(Documented limitation: "Manual Sync for Non-OpenAPI Triggers".)*
   - **Validate every connection.** FDA creates connections **without validating** them. Open each (PostgreSQL, LLM provider, MCP, A2A) and click **Connect / Test** to establish and verify it before running.
   - **Set the email password as a secret.** Re-enter `Email_App_Password` in **App Properties** so it is stored as `SECRET:` (see item 5). FDA app properties support only string/boolean/number — **never set the type to `password`** (it's invalid and gets dropped → *"property … does not exist"*).
   - **Certificates (if any).** FDA cannot add certificates. If a connection/trigger/activity needs one (secure DB/TLS, HTTPS or SMTP **Server Certificate**), add it manually.
   - **Branches / activity loops / error handlers (only if the use case uses them).** FDA cannot create or modify branches (success↔error, conditional links — these need direct `.flogo` edits), configure activity loops, or add activities to an error handler. Configure these manually in the designer.
   - **Don't corrupt the apps.** Never regenerate a `.flogo` (re-run the `_rebuild/` driver) once it has been opened in the designer — that wipes secrets and orphans connection refs; patch only the broken field. Don't patch a `.flogo` that is open in the designer — Discard + close it first.

9. **Install connector prerequisites** *(before opening the apps in the designer).*
   - This use case uses: **<PostgreSQL, …detected connectors>**.
   - VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…**, select the connectors above, finish the install, then **reload VS Code**.
   - Why: The designer needs them to fetch connector metadata at design time (schemas, tables and columns for the activities) and to validate the connections.

**Quick pre-flight checklist**

- [ ] Connector prerequisites installed (Flogo sidebar → Help And Feedback) and VS Code reloaded
- [ ] DB created, `database.sql` loaded, row counts sane
- [ ] LLM `API_Key` set; `LLM_Model` available to the key; `LLM_Base_URL` empty for OpenAI (set only for Azure/gateway/other)
- [ ] All ports free; orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] REST backends running (if any REST agent) / SMTP reachable (if email agent)
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:<wsPort>/<usecase>` and gets a reply; orchestrator restarted between demos (shared memory)

---

### Note for the skill author (not for the README)

Everything else — including the `mcpServers` / `remoteAgents` `conn://` arrays, tool/handler schemas, the wsserver headers schema, and the `wsconnection:any` typing — **is** configured automatically by the `fda` recipes. Do **not** list those as manual steps; they were common failure points precisely because people set them by hand, and the recipes now handle them. List the environment/secret/backend items 1–7 (trimmed to the ones this use case actually uses), **item 9 (connector prerequisites — list exactly the connectors the [detection grep](connector-prereqs.md) found)**, **plus item 8 (the FDA Tech-Preview limitations)** — item 8 is *not* a recipe gap; those steps (Sync triggers, validate connections, password-as-secret, and any certs/branches/loops/error-handlers) are manual because the product documents them as unsupported. See `fda-limitations.md`.
