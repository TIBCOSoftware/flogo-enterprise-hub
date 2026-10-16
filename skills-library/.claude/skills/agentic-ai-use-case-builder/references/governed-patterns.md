# Governed patterns: SQL shapes and the fda recipes that build them

The worked example for everything here is
`samples/Agentic_AI/Industry_Use_Cases/Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/`: `database.sql` (the rules),
`_rebuild/tool_spec.py` (the tool/SQL contract), `_rebuild/build_*.py` (the fda drivers).

The base PostgreSQL activity contract is in this skill's
[postgres-activity-patterns.md](postgres-activity-patterns.md).
That covers parameters mode, `?placeholder` substitution and `CAST(?p AS text)`, and it still applies.
This file adds the governance layer on top of it.

> **Build method is independent of governance.** The governance guarantees — scoped reads, guarded writes,
> two-step propose/confirm, human-owned routing and the reviewer loop, and session-token identity — live in the SQL functions in
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
and never predicts the outcome. A staff reviewer then decides the case in the same chatbot, and an approval
runs the action SQL parked on the case: §9.

## 6. Identity

The demo path is a `verify_*` tool: an identifier plus a one-time code gives a session token
(60 minutes), and every other tool takes the token. The token lives in the conversation memory, so
**each WebSocket connection must have its own conversationId** (see runtime-gotchas.md §1).
Otherwise one verified user's token is shared with every client.

The production path is to put OAuth2/JWT on the MCP trigger (`authType`, `oauthJWKSURL`,
`oauthRequiredScopes`) and resolve the principal from `tokenInfo` rather than from a code the user
types.

> **Brute-force throttle (required).** Record every verify attempt in a `<principal>_verify_attempts` table.
> After 5 wrong codes in 15 minutes, `verify_result()` returns `VERIFY_LOCKED` and issues no token, even for the
> right code. The reviewer verify uses the same lockout (`reviewer_verify_attempts`, §9). Test both in rung 1.
> The one-time code is still a demo identity: put real SSO (OAuth/JWT) in front before using real data.

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

## 9. Human-in-the-loop reviewer loop

Every build includes the full loop, not just the hand-off: **the AI proposes → a staff reviewer decides →
the system executes**, all in the same chatbot. The reviewer is a second persona of the same orchestrator and
MCP server. It uses the same governed shapes: identity in SQL, team scope in SQL, a guarded write
(`INSERT … SELECT rule_fn(…)`), an insert-only event row plus a trigger instead of an UPDATE, a readback, and
an audit row. Rename the domain words (claim, re-bill, RMA …) but keep this shape. Template:
`Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/database.sql` (the "THE REVIEWER LOOP" block),
`_rebuild/tool_spec.py` (`REVIEWER_TOOLS`) and `_rebuild/test_rules.py` (the reviewer block). The first
migration with it was `Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/`.

**The tools** (MCP, added to the governed set; templates in `templates/_rebuild/tool_spec.py`):

| Tool | Kind | SQL |
|---|---|---|
| `verify_reviewer(staff_id, code)` | identity (throttled like the customer verify) | `INSERT INTO <sessions> (role, reviewer_id) SELECT * FROM verify_reviewer_fn(…)` + `verify_reviewer_result(…)` |
| `get_review_queue(token)` | scoped read | `SELECT * FROM review_queue(CAST(?tok AS text))` |
| `get_review_case(token, case_id)` | scoped read | `SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text))` |
| `decide_review_case(token, case_id, decision, amount, internal_note, customer_message)` | guarded write | `INSERT INTO review_decisions (…) SELECT * FROM decide_case_row(…)` + `decide_case_result(…)` |
| `get_my_cases(token)` (customer) | scoped read | `SELECT * FROM my_cases(CAST(?tok AS text))`: status + `customer_message` once decided |

Hints: the reads get `readOnlyToolHint=true`; `decide_review_case` gets `readOnlyToolHint=false`,
`destructiveToolHint=false`, `idempotentToolHint=false` (validator G8 + G11). The email tool may send a
decision confirmation, but only for a case that has a `review_decisions` row.

### 9a. Data model

```sql
-- Staff reviewers. team must match the routing table's team values.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(12) PRIMARY KEY,         -- <STAFF-PREFIX>-NNNN
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(60) NOT NULL,            -- = <routing_table>.team
  one_time_code   VARCHAR(6)  NOT NULL,            -- HIDDEN: demo stand-in for the staff sign-in
  approval_limit  NUMERIC(12,2),                   -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);
-- ONE session table for both roles; every rule function checks the role, so tokens are not interchangeable.
CREATE TABLE <principal>_sessions (
  session_token   TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role            VARCHAR(10) NOT NULL DEFAULT '<PRINCIPAL>' CHECK (role IN ('<PRINCIPAL>','REVIEWER')),
  <principal>_id  VARCHAR(20) REFERENCES <principals>,
  reviewer_id     VARCHAR(12) REFERENCES reviewers,
  expires_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes',
  CHECK ((role = '<PRINCIPAL>' AND <principal>_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND <principal>_id IS NULL))
);
CREATE TABLE reviewer_verify_attempts (          -- same lockout as the customer verify (5 wrong in 15 min)
  attempt_id SERIAL PRIMARY KEY, reviewer_id VARCHAR(12) NOT NULL REFERENCES reviewers,
  ok BOOLEAN NOT NULL, at TIMESTAMP NOT NULL DEFAULT clock_timestamp());

-- The case table gains:
--   status            VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED'))
--   requested_amount  NUMERIC(12,2)    -- NULL = the case carries no amount
--   parked_action     VARCHAR(40)      -- '<KIND>:<id>', runs ONLY on approval; derived by case_parking()
--   sla_due_at        TIMESTAMP        -- set by trg_case_defaults from the routing table
--   customer_message  TEXT             -- customer-safe outcome text, set by the decision
--   approved_amount   NUMERIC(12,2), decided_at TIMESTAMP
--   agent_brief       TEXT NOT NULL    -- neutral summary / the A2A agent's answer; never a decision

-- Insert-only decision events, one per case. trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE REFERENCES <cases>,
  reviewer_id      VARCHAR(12) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8)  NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(12,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from customers
  customer_message TEXT NOT NULL,
  decided_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
-- Every decide call by a verified reviewer: the readback's source for the outcome and reason code.
CREATE TABLE decide_attempts (
  attempt_id SERIAL PRIMARY KEY, reviewer_id VARCHAR(12) NOT NULL REFERENCES reviewers,
  case_ref VARCHAR(40) NOT NULL, outcome VARCHAR(10) NOT NULL,        -- APPROVED / REJECTED / BLOCKED
  reason_code VARCHAR(24), reason_text TEXT, created_at TIMESTAMP NOT NULL DEFAULT clock_timestamp());
```

Add every new table to the `DROP TABLE` list in `database.sql` and to the `TRUNCATE` in `reset_data.sql`.

**Reviewer identity.** `session_reviewer(token)` always returns exactly one row: the reviewer (id, team, limit,
display name) for a valid REVIEWER token of an active reviewer, or NULLs. Write it in **plpgsql**, like
`session_<principal>()`: an inlinable SQL function merges into the caller's LEFT JOINs and can mis-bind rows.
`verify_reviewer_fn(staff, code)` is the write-row for the session insert. It returns `('REVIEWER', reviewer_id)`
only for an active, non-locked staff id with the right code, records every attempt on a real staff id, and
normalises loosely typed ids (`kst 7001` → `KST-7001`). `verify_reviewer_result()` returns
`VERIFIED` / `NOT_VERIFIED` / `LOCKED` plus the token, role, display name and team. It never says which part was
wrong.

### 9b. The parked-action pattern

An approval may execute exactly one thing, and **SQL decides what that is when the case opens**. The model
never chooses it.

```sql
-- What a new case parks for approval: derived from the request type + the caller's own record.
CREATE OR REPLACE FUNCTION case_parking(p_principal TEXT, p_type TEXT, p_reference TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, parked_action TEXT, requested_amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_type TEXT := norm_request_type(p_type); v_ref TEXT := norm_ref(p_reference); r <records>;
BEGIN
  ok := TRUE; reason_code := 'OK';
  IF v_type = '<REQUEST_TYPE_A>' THEN
    SELECT * INTO r FROM <records> x
     WHERE x.<record_id> = v_ref AND x.<principal>_id = p_principal AND <eligible for KIND_A>;
    IF v_ref <> '' AND NOT FOUND THEN                      -- not the caller's record, or not eligible
      ok := FALSE; reason_code := 'BAD_REFERENCE'; RETURN NEXT; RETURN;
    END IF;
    IF r.<record_id> IS NOT NULL THEN
      parked_action := '<KIND_A>:' || r.<record_id>; requested_amount := r.<amount>;
    END IF;
  END IF;                                                  -- other types: nothing parked, the team completes it
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;
```
- The case write-row joins `CROSS JOIN LATERAL case_parking(…) pk WHERE pk.ok` and inserts `pk.parked_action`
  and `pk.requested_amount`. It also refuses a second OPEN case with the same `parked_action`.
- The open-case readback tells the customer what an approval would do (`if_approved`), never whether it will happen.
- `case_eligible_max(case_id)` derives the most a reviewer may approve **from the parked record**, not from
  `requested_amount` alone. It returns NULL when the case carries no amount.
- `case_facts(case_id)` assembles the facts the reviewer needs from SQL (record details, counts in the last
  12 months, a risk band). Use minimum-necessary data: no email, phone, code or full last name.
- **Every execute row requires the parking.** The guarded row the trigger uses to execute an action re-checks
  the record's own rules **and** that the case parked exactly this action:

```sql
CREATE OR REPLACE FUNCTION <kind_a>_row(p_ref TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (<target columns>) AS $$
  SELECT <columns built from the record and p_amount>
    FROM <records> r
   WHERE r.<record_id> = p_ref AND <still eligible> AND p_amount > 0 AND p_amount <= r.<amount>
     AND NOT EXISTS (SELECT 1 FROM <target_table> t WHERE t.case_id = p_case)            -- once only
     AND EXISTS (SELECT 1 FROM <cases> s WHERE s.case_id = p_case
                  AND s.parked_action = '<KIND_A>:' || r.<record_id>);
$$ LANGUAGE sql STABLE;      -- VOLATILE if it calls nextval()
```

### 9c. The guard: `decide_case_row` and its reason codes

`decide_case_row(p_token, p_case, p_decision, p_amount, p_note, p_message)` returns **one row shaped like
`review_decisions`** when the decision may be recorded, and **0 rows** otherwise. Each block writes a
`decide_attempts` row with the reason first, so the readback can say why. The checks run in this order:

| Reason code | When | Effect |
|---|---|---|
| `NOT_REVIEWER` | token missing, expired, or a customer token | 0 rows, no attempt row (there is no reviewer id); the readback reports it from `session_reviewer()` |
| `NOT_FOUND` | no case with that id | 0 rows |
| `NOT_YOUR_TEAM` | the case is routed to another team (it is also invisible in that reviewer's queue and case view) | 0 rows |
| `ALREADY_DECIDED` | the case is not `OPEN` | 0 rows; the existing decision stands |
| `INVALID_DECISION` | the decision is not APPROVE or REJECT (after normalising `approved`, `deny` …) | 0 rows |
| `NOTE_REQUIRED` | the internal note is shorter than 5 characters | 0 rows |
| `AMOUNT_INVALID` | APPROVE with an amount ≤ 0, not a number, or above `case_eligible_max()` (empty / `ALL` / `FULL` = the max) | 0 rows |
| `OVER_AUTHORITY` | APPROVE with an amount above the reviewer's `approval_limit` | 0 rows; **the case stays OPEN** and the text says a senior reviewer must decide |

```sql
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT,
                                           p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC,
               internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s <cases>; v_team TEXT; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_txt TEXT := upper(regexp_replace(coalesce(p_amount, ''), '[$,[:space:]]', '', 'g'));
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                                  -- NOT_REVIEWER
  SELECT * INTO s FROM <cases> x WHERE x.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT t.team INTO v_team FROM <routing_table> t WHERE t.request_type = s.request_type;
  IF v_team <> rv.team THEN   /* NOT_YOUR_TEAM: same INSERT INTO decide_attempts ... ; RETURN; */ END IF;
  IF s.status <> 'OPEN' THEN  /* ALREADY_DECIDED */ END IF;
  v_dec := CASE upper(trim(coalesce(p_decision, ''))) WHEN 'APPROVE' THEN 'APPROVE' WHEN 'APPROVED' THEN 'APPROVE'
                WHEN 'REJECT' THEN 'REJECT' WHEN 'REJECTED' THEN 'REJECT' WHEN 'DENY' THEN 'REJECT' END;
  IF v_dec IS NULL THEN       /* INVALID_DECISION */ END IF;
  IF length(trim(coalesce(p_note, ''))) < 5 THEN /* NOTE_REQUIRED */ END IF;
  v_max := case_eligible_max(s.case_id);
  IF v_dec = 'APPROVE' AND v_max IS NOT NULL THEN
    v_amt := CASE WHEN v_txt IN ('', 'ALL', 'FULL') THEN v_max
                  WHEN v_txt ~ '^-?[0-9]+(\.[0-9]+)?$' THEN round(v_txt::numeric, 2) END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN /* AMOUNT_INVALID */ END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', '<amount> is above your approval limit of '
                || '<limit>. The case stays open and needs a senior reviewer.');
      RETURN;
    END IF;
  END IF;
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000),
                      left(coalesce(nullif(trim(p_message), ''), '<default customer message>'), 2000);
END $$ LANGUAGE plpgsql VOLATILE;
```
- The tool's write is `INSERT INTO review_decisions (case_id, reviewer_id, decision, approved_amount,
  internal_note, customer_message) SELECT * FROM decide_case_row(CAST(?w_tok AS text), …)`, never `VALUES`
  (validator G2 + G11).
- `decide_case_result(p_token, p_case)` is the readback. It reads the reviewer's latest `decide_attempts` row
  for that case and returns `outcome` (`APPROVED` / `REJECTED` / `BLOCKED` / `NOT_REVIEWER`), `reason_code`,
  `reason_text`, `case_status`, `executed_action` (built from the rows the trigger wrote, e.g. "fee refunded:
  $20.00 credited") and `customer_message`. It returns the case id and status only when the reviewer may see
  them: not for `NOT_FOUND` / `NOT_YOUR_TEAM`.
- Domain rules on the amount belong here too (whole units only, release in full or not at all). Each rule gets
  its own `AMOUNT_INVALID` text.

### 9d. The decision trigger executes the parked action

```sql
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s <cases>; v_kind TEXT; v_ref TEXT; v_done TEXT := 'nothing';
BEGIN
  SELECT * INTO s FROM <cases> WHERE case_id = NEW.case_id;
  UPDATE <cases> SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref  := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF NEW.decision = 'APPROVE' AND v_kind = '<KIND_A>' THEN
    INSERT INTO <target_table_a> (<target columns>) SELECT * FROM <kind_a>_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := '<what ran>'; END IF;
  ELSIF NEW.decision = 'REJECT' AND v_kind = '<KIND_HELD>' THEN
    v_done := '<what a rejection undoes, e.g. a held item is cancelled>';   -- most rejections execute nothing
  END IF;
  INSERT INTO <audit_table> (<principal>_id, actor, action, ref, detail)
    VALUES (s.<principal>_id, NEW.reviewer_id, 'CASE_DECIDED', NEW.case_id, NEW.decision || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();
```
The action runs through **the same guarded row functions** a customer action would use, so every rule is
rechecked at execution time. A row function that returns 0 rows executes nothing, and the readback reports it.
Side effects of the action (a balance, a due date) come from that event table's own trigger, never from the tool.

### 9e. Minimum-necessary views

| View | Shows | Never shows |
|---|---|---|
| `review_queue(token)` (reviewer) | the team's OPEN cases ordered by `sla_due_at`: case id, request label, customer as first name + last initial (`customer_display()`), opened date, age, reply-due date, `sla_status` (`ON_TRACK` / `DUE_TODAY` / `OVERDUE`), requested amount; status `NOT_REVIEWER` / `EMPTY` / `OK` | another team's cases, email, phone, codes, the full last name |
| `review_case(token, case_id)` (reviewer) | statement, the AI `agent_brief` (presented as unverified), requested amount, `max_approvable`, the reviewer's own `your_approval_limit`, `case_facts()`, the decision `options` (which name the senior reviewer when the max is above the limit), the decision once made | another team's case: a `NOT_FOUND` row |
| `my_cases(token)` (customer) | case id, type, team, status, reply-due date, approved amount and `customer_message` once decided | the internal note, the AI brief, scores or flags, the reviewer's name or id, `parked_action` |

`tool_spec.py` lists `HIDDEN_COLUMNS` (never in a customer tool's output) and `HIDDEN_FROM_REVIEWER` (never in a
reviewer tool's output). `test_rules.py` asserts both, and that no internal note or reviewer name appears in any
customer output.

### 9f. The SLA comes from the routing table

```sql
CREATE OR REPLACE FUNCTION case_defaults() RETURNS TRIGGER AS $$
DECLARE t <routing_table>;
BEGIN
  SELECT * INTO t FROM <routing_table> WHERE request_type = NEW.request_type;
  NEW.sla_due_at := coalesce(NEW.sla_due_at, add_business_days(NEW.created_at::date, t.reply_business_days)
                                             + NEW.created_at::time);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON <cases> FOR EACH ROW EXECUTE FUNCTION case_defaults();
```
It is a BEFORE INSERT trigger, not a column the tool fills, so cases opened by other triggers and by
`seed_data.sql` get their SLA too. `test_rules.py` asserts that no case has a NULL `sla_due_at`.

### 9g. Seeds and SQL pitfalls

- **Seeds:** two or more reviewers in different teams; one or two OPEN cases per reviewer team, so the queue
  is never empty in a demo; and **one reviewer whose `approval_limit` sits just below a seeded case's amount**
  (e.g. a $25 limit on a $29 fee), for the `OVER_AUTHORITY` demo. Make the "recent" timestamps relative to `now()`.
- **`IF CASE … END THEN` is a plpgsql syntax error.** Assign the CASE to a boolean first:
  `v_ok := CASE WHEN … THEN TRUE ELSE FALSE END; IF v_ok THEN …`.
- **Reloads must survive return-type changes.** `CREATE OR REPLACE FUNCTION` cannot change a return type, so
  `database.sql` starts with a block that drops this schema's own functions (and skips extension functions):

```sql
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.prokind = 'f'
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END $$;
```
- **`#variable_conflict use_column`** in every plpgsql function whose `RETURNS TABLE` names match column
  names (`case_id`, `reviewer_id`, `status` …).
- **The orchestrator submits, SQL decides.** The prompt restates the decision, waits for an explicit "confirm",
  then calls `decide_review_case` with exactly that decision, even when the amount looks above the limit. The
  model never refuses or lowers it on its own; `OVER_AUTHORITY` comes from SQL and is audited.

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
