# Governed patterns: SQL shapes and the fda recipes that build them

The worked example for everything here is
`samples/Agentic_AI/Industry_Use_Cases/Scholarly_Publishing_Author_Services_Use_Case/`: `database.sql` (the rules),
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
keywords, type and word count, and never the author. Its own tool is a scoped read (`search_*`) and it
has no write tool. Say this in the orchestrator prompt ("nothing that identifies the user") and in the
agent's prompt ("you are never given the user's identity").

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
| Temperature | `sa … temperature 0 --type number` | 0 = omitted; see runtime-gotchas.md §2 |
| redactSensitiveData | `false` on the orchestrator, `true` on sub-agents | the PII filter masks the identifier and code the user must send |
| Empty property | `app.cap_empty(name)` | `cap ""` writes the literal `New_value` |

`templates/_rebuild/fda_common.py` has the `App` helper, with `bake_pg`, `conn_ref`, `assert_conn`,
`cap_empty`, `postgres_connection` and `llm_connection`. Copy it into `<UseCase>/_rebuild/` and set
`PG_DB`.
