# Governed patterns: SQL shapes and the fda recipes that build them

The worked example for everything here is
`samples/Agentic_AI/Industry_Use_Cases/Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/`: `database.sql` (the rules),
`_rebuild/tool_spec.py` (the tool/SQL contract), `_rebuild/build_*.py` (the fda drivers).

The base PostgreSQL activity contract is in this skill's
[postgres-activity-patterns.md](postgres-activity-patterns.md).
That covers parameters mode, `?placeholder` substitution and `CAST(?p AS text)`, and it still applies.
This file adds the governance layer on top of it.

> **Build method is independent of governance.** The governance guarantees — scoped reads, guarded writes,
> two-step propose/confirm, human-owned routing, and session-token identity — live in the SQL functions in
> `database.sql` and the tool contract in `_rebuild/tool_spec.py`, which **both** build methods load. They
> hold whether the apps were built with FDA-CLI from scratch (Phase 4A) or cloned from a governed reference
> app and adapted (Phase 4B), and Phase 5 runs the same 4-step test ladder either way.

## 1. Rules live in the database

Every rule gets its own PL/pgSQL or SQL function. A tool's SQL does nothing except call one:

| Function kind | Returns | Example |
|---|---|---|
| identity | the principal id for a token, or NULL | `session_author(token)`: checks expiry |
| scoped read | only the caller's rows | `my_manuscripts(token)`, `manuscript_detail(token, id)` |
| rule / eval | `(ok bool, reason text, …computed fields)` | `transfer_eval(author, ms, journal)`, `apc_quote(author, journal)` |
| write-row | 0 or 1 row shaped like the target table | `transfer_proposal_row(token, ms, journal)` |
| outcome | one row: `outcome`, `reason`, ids, amounts | `propose_transfer_result(token, ms, journal)` |

Seed at least one row per reason code. The acceptance tests exercise those rows.

## 2. Scoped read (MCP tool, read-only)

```sql
SELECT * FROM my_manuscripts(CAST(?tok AS text));
```
- Never `SELECT … FROM <table> WHERE owner = ?id`. The LLM would supply the id. Pass the **token**
  and let the function resolve the principal.
- For another user's id, the function returns a `NOT_FOUND` row rather than zero rows, so the model has
  something truthful to say.
- Hints: `readOnlyToolHint=true`, `idempotentToolHint=true`.

## 3. Guarded write + readback (MCP tool)

Two activities in one flow. Both use the same arguments, and each uses its own placeholder names,
because a placeholder can't be reused within one statement.

```sql
-- GuardedWrite (#insert): writes 0 rows when any rule fails
INSERT INTO pending_actions (action_type, author_id, manuscript_id, target_journal_code, apc_usd, coverage_pct, author_pays_usd)
SELECT * FROM transfer_proposal_row(CAST(?w_tok AS text), CAST(?w_ms AS text), CAST(?w_jc AS text));
-- ReadOutcome (#query): says what happened and why
SELECT * FROM propose_transfer_result(CAST(?r_tok AS text), CAST(?r_ms AS text), CAST(?r_jc AS text));
```
- Never use `INSERT … VALUES (?a, ?b)`. Those values would be the LLM's arguments, written unchecked
  (validator G2).
- Updates and deletes: INSERT an event row and let an `AFTER INSERT` trigger apply the side effects,
  as `trg_transfer_apply` does. The state change is then atomic, and every rule is rechecked in the
  write-row function.

## 4. Two-step propose / confirm (anything the user would want to undo)

`propose_*` inserts into `pending_actions`: a random `action_id`, a 15-minute expiry, the quote frozen
in the row. It returns `PROPOSED` plus the quote. A duplicate PENDING proposal is not created twice.
`confirm_*` takes the `action_id` and re-runs every rule (the world may have changed). It writes the
event row only when the action is still PENDING, unexpired and eligible. Anything else returns
`NOT_EXECUTED` with a reason: `SESSION_INVALID`, `ACTION_NOT_FOUND`, `EXPIRED`, or the rule's own reason.

> **Honest limit.** The user's "yes" between the two steps is enforced by the prompt. In production,
> put the confirm on a UI button that calls `confirm_*` directly, so a model cannot skip it.

## 5. Human-owned routing

```sql
INSERT INTO review_cases (author_id, manuscript_id, request_type, author_statement, agent_brief)
SELECT * FROM review_case_row(CAST(?w_tok AS text), …);
```
`review_teams(request_type → team, reply_days)` routes the case. The model supplies `request_type`,
the user's own words and a neutral brief, and nothing else. The model never picks the team or the SLA,
and never predicts the outcome.

## 6. Identity

The demo path is a `verify_*` tool: an identifier plus a one-time code gives a session token
(60 minutes), and every other tool takes the token. The token lives in the conversation memory, so
**each WebSocket connection must have its own conversationId** (see runtime-gotchas.md §1).
Otherwise one verified user's token is shared with every client.

The production path is to put OAuth2/JWT on the MCP trigger (`authType`, `oauthJWKSURL`,
`oauthRequiredScopes`) and resolve the principal from `tokenInfo` rather than from a code the user
types.

> **Honest limit.** The demo verify tool has no brute-force throttle. Add attempt counting in
> `verify_result()` (or a lockout table) before anyone points it at real data.

## 7. Agent input minimisation

An A2A agent gets **only** the fields its reasoning needs. The journal matcher gets title, abstract,
keywords, type and word count, and never the author. Its one tool is an identity-free read (a
`ref_<topic>()` reference function, §8) and it has no write tool. Say this in the orchestrator prompt
("nothing that identifies the user") and in the agent's prompt ("you are never given the user's identity").

## 8. Agent reference tools (PostgreSQL)

Every A2A reasoning agent has exactly **one** tool, and it reads **reference data** from PostgreSQL. It
needs a tool because an A2A Server with zero Tool handlers runs as a Local Agent and never opens its port
(runtime-gotchas.md §10). Validator G10 rejects a static `#noop` → `#actreturn` text. The template is the
Hospital sample
(`samples/Agentic_AI/Industry_Use_Cases/Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/`:
`database.sql`, `seed_data.sql`, `_rebuild/tool_spec.py`, `_rebuild/build_agents.py`). The Semiconductor sample
(`High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case/`) is the cleanest later
version, with the `TABLE_ONLY` check in `_rebuild/a2a_smoke.py`.

**Table shape.** One table per agent, all with the same shape, holding **no personal data**: no names,
ids of people or accounts, emails, phones, tokens, case ids or customer free text.

```sql
CREATE TABLE <topic>_guide (                       -- <agent>: what the words and codes in its input mean
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('<SECTION_A>', '<SECTION_B>', '<SECTION_C>')),
  term        VARCHAR(60) NOT NULL,
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);
```
- Seed it in `seed_data.sql`. Add it to the `DROP TABLE` list in `database.sql` and to the `TRUNCATE` in
  `reset_data.sql`.
- Keep each guide to about 20–35 rows, because agents send `term=""` (the whole guide) almost every time.
- Seed a row for **every code the runtime writes** that reaches the agent: reason codes, normalised
  categories, statuses. Grep `database.sql` for `_reason_code = '` and the `norm_*()` functions.
- Write each meaning as plain-language **meaning text, not a code**.
- Choose section lookup words (`safety net`, `note line`) that appear in no other row, so a section lookup
  returns exactly that section.
- Don't write `%` into reference text unless the literal-`%` test allows it (testing-ladder.md step 1), and
  don't format per-unit prices with a cents formatter.

**The shared matcher `ref_match`.** Copy it verbatim from the Hospital `database.sql`:

```sql
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;
```
An empty or NULL term, or one with only separators, matches every row. Otherwise the term is split on `,` /
`;`, and a row matches when a word equals its section (spaces = underscores) or is a plain substring of its
term or meaning. It uses `strpos`, not `LIKE`, so `%` and `_` are literal. Unknown words give 0 rows, never an
error.

**The `ref_<topic>` function.** It is `LANGUAGE sql STABLE` and SELECT-only, takes a single `p_term text`
argument (never an identity), alias-qualifies every column (otherwise they clash with the `RETURNS TABLE`
names), and orders sections with `array_position`:

```sql
CREATE OR REPLACE FUNCTION ref_<topic>(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM <topic>_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['<SECTION_A>','<SECTION_B>','<SECTION_C>'], g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;
```

**UNION from an existing table (single source of truth).** When a list already lives in a table, derive it
instead of copying it. Hospital's high-alert list comes from `medication_catalog`, and Life & Pensions reads
"who decides" from `case_routing`:

```sql
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT m.section::text AS sec, m.term::text AS trm, m.meaning::text AS mng, m.entry_id AS ord
            FROM <topic>_guide m
          UNION ALL                                 -- one source of truth: the existing table
          SELECT 'HIGH_ALERT', c.generic_name::text, '<plain-language meaning>', 1000
            FROM medication_catalog c WHERE c.high_alert) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['<SECTION_A>', …, 'HIGH_ALERT'], r.sec), r.ord, r.trm
```
UNION only the public facts the agent needs. Don't UNION a large catalogue the agent must not rank from.

**`tool_spec.py`.**
```python
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (...), or an empty string for the whole "
                 "guide. Never put <customer> details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [{"agent": "<agent>", "tool": "get_<topic>_guide", "fn": "ref_<topic>", "table": "<topic>_guide",
                    "sections": ["<SECTION_A>", ...], "desc": "<what the guide holds; no customer data>",
                    "args": [("term", REF_TERM_DESC)],
                    "read": ("SELECT * FROM ref_<topic>(CAST(?lookup AS text));", [("lookup", "term")])}, ...]
```
The placeholder **must** be `?lookup`, never `?term`: a placeholder named like a result column gives duplicate
`Fields`.

**fda recipe**, per agent, in `build_agents.py` after `app.llm_connection(); app.postgres_connection()`:

| Step | Command |
|---|---|
| Tool flow | `cf <tool>_flow "<desc>"` |
| Query | `ca <tool>_flow ReadReference act_postgresql_query "PostgreSQL Query" -C PostgresConn` |
| Return | `ca <tool>_flow Return act_default_actreturn "Simple Return"` |
| Bake the query | `app.bake_pg(FLOW, "ReadReference", "act_postgresql_query", sql, [("lookup", "=$flow.toolParams.term")], result_columns(sql))`: parameters mode, all 3 parts of the contract, and it re-asserts `Connection == PostgresConn` |
| Reply | `mm <tool>_flow.Return.input.mappings.response.mapping.data =coerce.toString($activity[ReadReference].Output)` |
| Handler | `cth`, `agentToolName`, `agentToolDescription`, then `wth … --input toolParams:object --output response:object` |
| toolParams schema | **inline**: `sa handler <agent>.<tool>_flow.schemas.output.toolParams --jsonValue '{"type":"json","value":<tp>,"fe_metadata":<tp>}' --force`, with `tp = {"type":"object","properties":{"term":{…}},"required":["term"]}`. `term` is required so the model always sends it; `""` = the whole guide |
| Flow input | `sa flow <tool>_flow.metadata.input` = `[{"name":"toolParams","type":"object","schema":{"type":"json","value":"{\"term\":{\"type\":\"string\"}}"}}]`, and the same properties in `metadata.fe_metadata.input` |
| Prompt | one paragraph per agent (`tool_rule()` in Hospital): what the guide holds; "call it at most once, and only when your input needs it: …"; "pass term "" for the whole guide"; "never put <customer> details in term" |

After the build, self-check each tool flow: the Query, `Connection == conn_ref("PostgresConn")`, the parameters
`{"lookup": "=$flow.toolParams.term"}`, and the connection refs `#con_llmprovider` and `#con_postgresql`. Expect
the Agents app's `fda cm` mapping count to rise (about 7 per agent). The Agents README's ⚠️ app-properties table
then lists the `PostgreSQL.PostgresConn.*` properties next to the LLM ones.

**Why this stays governed.**
- The agent still gets no identity, no session token and no scoped customer data. The orchestrator passes
  it minimised input, and its one tool reaches reference tables only.
- The SQL is fixed at build time. The model can supply only the optional lookup word, and `ref_match`
  treats it as a plain string.
- The function is `STABLE` and SELECT-only, has no identity argument, and isn't `SECURITY DEFINER`.
- Moving the reference text from a static flow into a table makes it one reviewable, testable source of
  truth. `test_rules.py` proves that it carries no personal data, that it explains every code the runtime
  writes, and that nothing from the old text was lost.

## fda recipes that differ from the base recipes

Everything else is identical to this skill's
[fda-build-recipes.md](fda-build-recipes.md).

| Need | Recipe | Why |
|---|---|---|
| MCP tool hints | `fda sa handler <T>.<flow>.settings.readOnlyToolHint --jsonValue true` (same for destructive / idempotent / openWorld) | `--type boolean` stores the string `"true"` |
| Guarded-write tool | `ca GuardedWrite act_postgresql_insert -C PostgresConn` + `ca ReadOutcome act_postgresql_query -C PostgresConn` + `ca Return`; `app.bake_pg(...)` for each | the 3-part PG contract, baked in parameters mode |
| Tool response | `mm <flow>.Return.input.mappings.response.mapping.data =coerce.toString($activity[ReadOutcome].Output)` | the MCP runtime returns `response.data` as `content[0].text`, i.e. the Output JSON `{"records":[…]}` |
| WebSocket headers | `sa handler WebsocketServer.<flow>.schemas.output.headers --jsonValue '{"type":"json","value":"<schema>","fe_metadata":"<parameter list>"}' --force`, plus the same properties on the flow input (`sa flow <flow>.metadata.input` and `<flow>.metadata.fe_metadata`); copy the sample's `build_orchestrator.py` | a `schema://` ref yields no headers at runtime; a JSON-schema `fe_metadata` makes the designer's Sync wipe them (runtime-gotchas.md §1) |
| Per-connection memory | `mm <flow>.AIAgent.input.conversationId '=$flow.headers["Sec-Websocket-Key"]'` | one conversation per socket |
| Reasoning agent's tool | one `cf`/`cth`/`wth` flow per `tr_agent`: `ca ReadReference act_postgresql_query -C PostgresConn` + `bake_pg` (`SELECT * FROM ref_<topic>(CAST(?lookup AS text))`, `lookup = $flow.toolParams.term`) + `Return`; inline toolParams schema with `term` required; the prompt says "call it at most once"; one `<Agent>_PORT` each. Copy the Hospital sample's `build_agents.py` (§8) | an A2A Server with zero Tool handlers runs as a Local Agent and never opens its port, and G10 rejects a static-text tool (runtime-gotchas.md §10) |
| Temperature | `sa … temperature 0 --type number` | 0 = omitted; see runtime-gotchas.md §2 |
| redactSensitiveData | `false` on the orchestrator, `true` on sub-agents | the PII filter masks the identifier and code the user must send |
| Empty property | `app.cap_empty(name)` | `cap ""` writes the literal `New_value` |

`templates/_rebuild/fda_common.py` has the `App` helper, with `bake_pg`, `conn_ref`, `assert_conn`,
`cap_empty`, `postgres_connection` and `llm_connection`. Copy it into `<UseCase>/_rebuild/` and set
`PG_DB`.
