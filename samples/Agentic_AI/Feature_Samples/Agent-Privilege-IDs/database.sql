-- =============================================================================
-- Agent Privilege IDs - Harbor Bank (fictional) back-office demo
-- Database: bankops_agents
--
-- Every AI agent has its OWN privilege ID (the JWT `sub` it presents to the MCP
-- server). Two layers decide what an agent may do:
--   1. the token's scopes  -> the Flogo MCP Server trigger hides/blocks tools
--   2. this registry       -> status, expiry and entitlements, checked on EVERY call
-- Privileged changes never execute on an agent's say-so: they become approval
-- requests that only a named human approver can decide (approve_request()).
-- Every call - allowed or denied - is written to agent_audit.
--
-- Load:  createdb -U postgres bankops_agents
--        psql -U postgres -d bankops_agents -f database.sql
-- =============================================================================

DROP TABLE IF EXISTS agent_audit, approval_requests, transactions, cards, accounts,
                     agent_entitlements, agent_identities, human_approvers CASCADE;
DROP SEQUENCE IF EXISTS approval_seq;

-- ---------------------------------------------------------------- identities
CREATE TABLE agent_identities (
    agent_id        TEXT PRIMARY KEY,                 -- = JWT sub: the agent's privilege ID
    display_name    TEXT NOT NULL,
    purpose         TEXT NOT NULL,
    owner           TEXT NOT NULL,                    -- the accountable human
    status          TEXT NOT NULL CHECK (status IN ('ACTIVE', 'SUSPENDED', 'RETIRED')),
    valid_until     TIMESTAMP NOT NULL,
    recertified_on  DATE,
    recertified_by  TEXT
);

CREATE TABLE agent_entitlements (
    agent_id  TEXT REFERENCES agent_identities(agent_id),
    tool      TEXT NOT NULL,
    PRIMARY KEY (agent_id, tool)
);

CREATE TABLE human_approvers (
    approver_id  TEXT PRIMARY KEY,
    full_name    TEXT NOT NULL,
    role         TEXT NOT NULL,
    max_limit    NUMERIC(12,2) NOT NULL              -- highest daily limit this person may approve
);

-- ---------------------------------------------------------------- business data
CREATE TABLE accounts (
    account_id            TEXT PRIMARY KEY,
    customer_name         TEXT NOT NULL,
    account_type          TEXT NOT NULL,
    balance               NUMERIC(14,2) NOT NULL,
    daily_transfer_limit  NUMERIC(12,2) NOT NULL,
    status                TEXT NOT NULL
);

CREATE TABLE cards (
    card_id      TEXT PRIMARY KEY,
    account_id   TEXT REFERENCES accounts(account_id),
    last4        TEXT NOT NULL,
    card_type    TEXT NOT NULL,
    status       TEXT NOT NULL CHECK (status IN ('ACTIVE', 'BLOCKED')),
    blocked_by   TEXT,
    blocked_at   TIMESTAMP,
    block_reason TEXT
);

CREATE TABLE transactions (
    txn_id      TEXT PRIMARY KEY,
    account_id  TEXT REFERENCES accounts(account_id),
    posted_on   DATE NOT NULL,
    description TEXT NOT NULL,
    amount      NUMERIC(12,2) NOT NULL
);

CREATE SEQUENCE approval_seq START 1001;
CREATE TABLE approval_requests (
    request_id       TEXT PRIMARY KEY DEFAULT 'APR-' || nextval('approval_seq'),
    requested_by     TEXT NOT NULL REFERENCES agent_identities(agent_id),
    account_id       TEXT NOT NULL REFERENCES accounts(account_id),
    current_limit    NUMERIC(12,2) NOT NULL,
    requested_limit  NUMERIC(12,2) NOT NULL,
    justification    TEXT,
    status           TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    requested_at     TIMESTAMP NOT NULL DEFAULT now(),
    decided_by       TEXT,
    decided_at       TIMESTAMP,
    decision_note    TEXT
);

CREATE TABLE agent_audit (
    audit_id    BIGSERIAL PRIMARY KEY,
    at          TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
    agent_id    TEXT NOT NULL,                       -- from the verified JWT, never from the model
    tool        TEXT NOT NULL,
    target      TEXT,
    decision    TEXT NOT NULL,                       -- ALLOWED | DENIED | PENDING_APPROVAL | APPROVED | REJECTED
    reason      TEXT NOT NULL,
    detail      TEXT
);
CREATE INDEX agent_audit_recent ON agent_audit (agent_id, tool, target, audit_id DESC);

-- ---------------------------------------------------------------- the privilege check
-- One place decides whether an agent identity may use a tool right now.
CREATE OR REPLACE FUNCTION agent_check(p_agent TEXT, p_tool TEXT)
RETURNS TABLE (ok BOOLEAN, reason TEXT) AS $$
    SELECT CASE
             WHEN a.agent_id IS NULL              THEN FALSE
             WHEN a.status <> 'ACTIVE'            THEN FALSE
             WHEN a.valid_until < now()           THEN FALSE
             WHEN e.tool IS NULL                  THEN FALSE
             ELSE TRUE END,
           CASE
             WHEN a.agent_id IS NULL              THEN 'UNKNOWN_AGENT'
             WHEN a.status <> 'ACTIVE'            THEN 'AGENT_' || a.status
             WHEN a.valid_until < now()           THEN 'AGENT_IDENTITY_EXPIRED'
             WHEN e.tool IS NULL                  THEN 'NOT_ENTITLED'
             ELSE 'OK' END
    FROM (SELECT 1) one
    LEFT JOIN agent_identities a ON a.agent_id = p_agent
    LEFT JOIN agent_entitlements e ON e.agent_id = a.agent_id AND e.tool = p_tool;
$$ LANGUAGE sql STABLE;

-- Audit row for a read-only tool: always one row, ALLOWED or DENIED.
CREATE OR REPLACE FUNCTION read_audit_row(p_agent TEXT, p_tool TEXT, p_target TEXT)
RETURNS TABLE (agent_id TEXT, tool TEXT, target TEXT, decision TEXT, reason TEXT, detail TEXT) AS $$
    SELECT coalesce(nullif(p_agent, ''), 'ANONYMOUS'), p_tool, nullif(p_target, ''),
           CASE WHEN c.ok THEN 'ALLOWED' ELSE 'DENIED' END, c.reason, NULL::text
    FROM agent_check(p_agent, p_tool) c;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- whoami
CREATE OR REPLACE FUNCTION whoami(p_agent TEXT, p_token_scopes TEXT)
RETURNS TABLE (agent_id TEXT, display_name TEXT, owner TEXT, status TEXT, valid_until TEXT,
               token_scopes TEXT, entitled_tools TEXT, registry_check TEXT) AS $$
    SELECT coalesce(a.agent_id, p_agent), a.display_name, a.owner, coalesce(a.status, 'UNKNOWN'),
           to_char(a.valid_until, 'YYYY-MM-DD'), p_token_scopes,
           (SELECT string_agg(e.tool, ', ' ORDER BY e.tool) FROM agent_entitlements e WHERE e.agent_id = a.agent_id),
           (SELECT c.reason FROM agent_check(p_agent, 'whoami') c)
    FROM (SELECT 1) one LEFT JOIN agent_identities a ON a.agent_id = p_agent;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- reads (re-check on every call)
CREATE OR REPLACE FUNCTION account_summary(p_agent TEXT, p_account TEXT)
RETURNS TABLE (access TEXT, reason TEXT, account_id TEXT, customer_name TEXT, account_type TEXT,
               balance TEXT, daily_transfer_limit TEXT, account_status TEXT, cards TEXT) AS $$
    SELECT CASE WHEN NOT c.ok THEN 'DENIED' WHEN a.account_id IS NULL THEN 'NOT_FOUND' ELSE 'GRANTED' END,
           CASE WHEN NOT c.ok THEN c.reason WHEN a.account_id IS NULL THEN 'NO_SUCH_ACCOUNT' ELSE 'OK' END,
           CASE WHEN c.ok THEN a.account_id END, CASE WHEN c.ok THEN a.customer_name END,
           CASE WHEN c.ok THEN a.account_type END, CASE WHEN c.ok THEN a.balance::text END,
           CASE WHEN c.ok THEN a.daily_transfer_limit::text END, CASE WHEN c.ok THEN a.status END,
           CASE WHEN c.ok THEN (SELECT string_agg(k.card_id || ' (' || k.card_type || ' ****' || k.last4 || ', ' || k.status || ')',
                                                 '; ' ORDER BY k.card_id)
                                FROM cards k WHERE k.account_id = a.account_id) END
    FROM agent_check(p_agent, 'get_account_summary') c
    LEFT JOIN accounts a ON a.account_id = upper(trim(p_account));
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION recent_transactions(p_agent TEXT, p_account TEXT)
RETURNS TABLE (access TEXT, reason TEXT, txn_id TEXT, posted_on TEXT, description TEXT, amount TEXT) AS $$
    WITH c AS (SELECT * FROM agent_check(p_agent, 'list_recent_transactions')),
         acct AS (SELECT account_id FROM accounts WHERE account_id = upper(trim(p_account)))
    SELECT 'GRANTED', 'OK', t.txn_id, t.posted_on::text, t.description, t.amount::text
    FROM c, transactions t JOIN acct USING (account_id)
    WHERE c.ok
    UNION ALL
    SELECT CASE WHEN NOT c.ok THEN 'DENIED' ELSE 'NOT_FOUND' END,
           CASE WHEN NOT c.ok THEN c.reason ELSE 'NO_SUCH_ACCOUNT' END, NULL, NULL, NULL, NULL
    FROM c WHERE NOT c.ok OR NOT EXISTS (SELECT 1 FROM acct)
    ORDER BY 4 DESC NULLS LAST;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- guarded write: block a card
-- Always returns ONE audit row; the trigger blocks the card only when decision = ALLOWED.
CREATE OR REPLACE FUNCTION card_block_audit_row(p_agent TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (agent_id TEXT, tool TEXT, target TEXT, decision TEXT, reason TEXT, detail TEXT) AS $$
    SELECT coalesce(nullif(p_agent, ''), 'ANONYMOUS'), 'block_card', upper(trim(p_card)),
           CASE WHEN c.ok AND k.status = 'ACTIVE' THEN 'ALLOWED' ELSE 'DENIED' END,
           CASE WHEN NOT c.ok THEN c.reason
                WHEN k.card_id IS NULL THEN 'NO_SUCH_CARD'
                WHEN k.status <> 'ACTIVE' THEN 'CARD_ALREADY_' || k.status
                ELSE 'OK' END,
           left(coalesce(nullif(trim(p_reason), ''), 'not given'), 200)
    FROM agent_check(p_agent, 'block_card') c
    LEFT JOIN cards k ON k.card_id = upper(trim(p_card));
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- guarded write: limit change -> human approval
-- An agent can only REQUEST a limit change. The request is policy-checked here and queued for a person.
CREATE OR REPLACE FUNCTION limit_request_audit_row(p_agent TEXT, p_account TEXT, p_new_limit TEXT, p_justification TEXT)
RETURNS TABLE (agent_id TEXT, tool TEXT, target TEXT, decision TEXT, reason TEXT, detail TEXT) AS $$
    WITH req AS (SELECT CASE WHEN trim(p_new_limit) ~ '^[0-9]+(\.[0-9]{1,2})?$'
                             THEN trim(p_new_limit)::numeric END AS amt)
    SELECT coalesce(nullif(p_agent, ''), 'ANONYMOUS'), 'request_limit_increase', upper(trim(p_account)),
           CASE WHEN c.ok AND a.account_id IS NOT NULL AND req.amt IS NOT NULL
                     AND req.amt > a.daily_transfer_limit AND req.amt <= 100000
                     AND NOT EXISTS (SELECT 1 FROM approval_requests r
                                     WHERE r.account_id = a.account_id AND r.status = 'PENDING')
                THEN 'PENDING_APPROVAL' ELSE 'DENIED' END,
           CASE WHEN NOT c.ok THEN c.reason
                WHEN a.account_id IS NULL THEN 'NO_SUCH_ACCOUNT'
                WHEN req.amt IS NULL THEN 'INVALID_AMOUNT'
                WHEN req.amt <= a.daily_transfer_limit THEN 'NOT_AN_INCREASE'
                WHEN req.amt > 100000 THEN 'ABOVE_POLICY_CAP_100000'
                WHEN EXISTS (SELECT 1 FROM approval_requests r WHERE r.account_id = a.account_id AND r.status = 'PENDING')
                     THEN 'REQUEST_ALREADY_PENDING'
                ELSE 'AWAITING_HUMAN_APPROVER' END,
           req.amt::text || '|' || left(coalesce(nullif(trim(p_justification), ''), 'not given'), 200)
    FROM agent_check(p_agent, 'request_limit_increase') c CROSS JOIN req
    LEFT JOIN accounts a ON a.account_id = upper(trim(p_account));
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- side effects of audited decisions
CREATE OR REPLACE FUNCTION apply_audited_action() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.tool = 'block_card' AND NEW.decision = 'ALLOWED' THEN
        UPDATE cards SET status = 'BLOCKED', blocked_by = NEW.agent_id, blocked_at = NEW.at, block_reason = NEW.detail
        WHERE card_id = NEW.target AND status = 'ACTIVE';
    ELSIF NEW.tool = 'request_limit_increase' AND NEW.decision = 'PENDING_APPROVAL' THEN
        INSERT INTO approval_requests (requested_by, account_id, current_limit, requested_limit, justification)
        SELECT NEW.agent_id, a.account_id, a.daily_transfer_limit, split_part(NEW.detail, '|', 1)::numeric,
               substr(NEW.detail, strpos(NEW.detail, '|') + 1)
        FROM accounts a WHERE a.account_id = NEW.target;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_audited_action AFTER INSERT ON agent_audit
    FOR EACH ROW EXECUTE FUNCTION apply_audited_action();

-- ---------------------------------------------------------------- outcomes (read back what happened)
CREATE OR REPLACE FUNCTION last_decision(p_agent TEXT, p_tool TEXT, p_target TEXT)
RETURNS TABLE (decision TEXT, reason TEXT, at TIMESTAMP) AS $$
    SELECT a.decision, a.reason, a.at FROM agent_audit a
    WHERE a.agent_id = coalesce(nullif(p_agent, ''), 'ANONYMOUS') AND a.tool = p_tool
      AND a.target IS NOT DISTINCT FROM upper(trim(p_target))
      AND a.at > clock_timestamp() - interval '2 minutes'
    ORDER BY a.audit_id DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION block_card_result(p_agent TEXT, p_card TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, card_id TEXT, card_status TEXT, blocked_by TEXT, blocked_at TEXT) AS $$
    SELECT CASE WHEN d.decision = 'ALLOWED' THEN 'CARD_BLOCKED' ELSE 'NOT_EXECUTED' END,
           coalesce(d.reason, 'NO_DECISION'), upper(trim(p_card)),
           k.status, k.blocked_by, to_char(k.blocked_at, 'YYYY-MM-DD HH24:MI:SS')
    FROM (SELECT 1) one
    LEFT JOIN last_decision(p_agent, 'block_card', p_card) d ON TRUE
    LEFT JOIN cards k ON k.card_id = upper(trim(p_card)) AND d.decision = 'ALLOWED';
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION limit_request_result(p_agent TEXT, p_account TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, request_id TEXT, account_id TEXT, current_limit TEXT,
               requested_limit TEXT, request_status TEXT, next_step TEXT) AS $$
    SELECT CASE WHEN d.decision = 'PENDING_APPROVAL' THEN 'SUBMITTED_FOR_HUMAN_APPROVAL' ELSE 'NOT_SUBMITTED' END,
           coalesce(d.reason, 'NO_DECISION'), r.request_id, upper(trim(p_account)),
           r.current_limit::text, r.requested_limit::text, r.status,
           CASE WHEN d.decision = 'PENDING_APPROVAL'
                THEN 'A human approver must decide. The limit has NOT changed.' END
    FROM (SELECT 1) one
    LEFT JOIN last_decision(p_agent, 'request_limit_increase', p_account) d ON TRUE
    LEFT JOIN LATERAL (SELECT * FROM approval_requests x
                       WHERE x.account_id = upper(trim(p_account)) AND x.requested_by = p_agent
                         AND d.decision = 'PENDING_APPROVAL'
                       ORDER BY x.requested_at DESC LIMIT 1) r ON TRUE;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION request_status(p_agent TEXT, p_request TEXT)
RETURNS TABLE (access TEXT, reason TEXT, request_id TEXT, account_id TEXT, requested_limit TEXT,
               status TEXT, decided_by TEXT, decided_at TEXT, decision_note TEXT) AS $$
    SELECT CASE WHEN NOT c.ok THEN 'DENIED' WHEN r.request_id IS NULL THEN 'NOT_FOUND' ELSE 'GRANTED' END,
           CASE WHEN NOT c.ok THEN c.reason WHEN r.request_id IS NULL THEN 'NO_SUCH_REQUEST' ELSE 'OK' END,
           r.request_id, r.account_id, r.requested_limit::text, r.status, r.decided_by,
           to_char(r.decided_at, 'YYYY-MM-DD HH24:MI'), r.decision_note
    FROM agent_check(p_agent, 'get_request_status') c
    LEFT JOIN approval_requests r ON r.request_id = upper(trim(p_request)) AND c.ok;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- HUMAN ONLY: decide an approval
-- Not exposed as an MCP tool and no token scope grants it. Run by a supervisor (psql here; an ops
-- console or ITSM workflow in production). Separation of duties is enforced here, not in a prompt.
CREATE OR REPLACE FUNCTION approve_request(p_request TEXT, p_approver TEXT, p_approve BOOLEAN, p_note TEXT DEFAULT NULL)
RETURNS TABLE (outcome TEXT, reason TEXT, request_id TEXT, account_id TEXT, new_daily_limit TEXT) AS $$
DECLARE
    r approval_requests%ROWTYPE;
    h human_approvers%ROWTYPE;
    why TEXT;
BEGIN
    SELECT * INTO r FROM approval_requests WHERE approval_requests.request_id = upper(trim(p_request)) FOR UPDATE;
    SELECT * INTO h FROM human_approvers WHERE approver_id = p_approver;
    why := CASE
             WHEN r.request_id IS NULL THEN 'NO_SUCH_REQUEST'
             WHEN r.status <> 'PENDING' THEN 'ALREADY_' || r.status
             WHEN EXISTS (SELECT 1 FROM agent_identities WHERE agent_id = p_approver) THEN 'AGENTS_CANNOT_APPROVE'
             WHEN h.approver_id IS NULL THEN 'NOT_AN_AUTHORISED_APPROVER'
             WHEN p_approve AND r.requested_limit > h.max_limit THEN 'ABOVE_APPROVER_AUTHORITY'
             ELSE NULL END;
    IF why IS NOT NULL THEN
        INSERT INTO agent_audit (agent_id, tool, target, decision, reason, detail)
        VALUES (coalesce(r.requested_by, 'n/a'), 'approve_request', upper(trim(p_request)), 'DENIED', why,
                'attempted by ' || coalesce(p_approver, 'unknown'));
        RETURN QUERY SELECT 'NOT_DECIDED', why, upper(trim(p_request)), r.account_id, NULL::text;
        RETURN;
    END IF;
    UPDATE approval_requests SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
           decided_by = p_approver, decided_at = now(), decision_note = p_note
     WHERE approval_requests.request_id = r.request_id;
    IF p_approve THEN
        UPDATE accounts SET daily_transfer_limit = r.requested_limit WHERE accounts.account_id = r.account_id;
    END IF;
    INSERT INTO agent_audit (agent_id, tool, target, decision, reason, detail)
    VALUES (r.requested_by, 'approve_request', r.request_id, CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
            'DECIDED_BY_HUMAN', p_approver || coalesce(': ' || p_note, ''));
    RETURN QUERY SELECT CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, 'DECIDED_BY_HUMAN',
                        r.request_id, r.account_id,
                        (SELECT daily_transfer_limit::text FROM accounts WHERE accounts.account_id = r.account_id);
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- delegation (orchestrated variant)
-- The orchestrator agent has its own privilege ID and may only DELEGATE to specialist agents. Each delegation is
-- gated by the same registry (status, expiry, entitlement) and audited under the orchestrator's ID; the specialist
-- then acts under its OWN privilege ID, so a hand-off never transfers rights.
CREATE OR REPLACE FUNCTION delegation_audit_row(p_caller TEXT, p_tool TEXT, p_request TEXT)
RETURNS TABLE (agent_id TEXT, tool TEXT, target TEXT, decision TEXT, reason TEXT, detail TEXT) AS $$
    SELECT coalesce(nullif(p_caller, ''), 'ANONYMOUS'), p_tool, NULL::text,
           CASE WHEN c.ok THEN 'ALLOWED' ELSE 'DENIED' END, c.reason,
           left(coalesce(nullif(trim(p_request), ''), '(empty request)'), 200)
    FROM agent_check(p_caller, p_tool) c;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION delegation_gate(p_caller TEXT, p_tool TEXT)
RETURNS TABLE (decision TEXT, reason TEXT) AS $$
    SELECT CASE WHEN c.ok THEN 'ALLOWED' ELSE 'DENIED' END, c.reason FROM agent_check(p_caller, p_tool) c;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- no-MCP variant: identity provider + API gateway
-- Each agent is an OAuth 2.0 client (client_id = its privilege ID). Only a SHA-256 hash of the secret is stored.
-- Deliberately not foreign-keyed to agent_identities, so reset_data.sql (TRUNCATE ... CASCADE) keeps registrations.
CREATE TABLE IF NOT EXISTS oauth_clients (
    client_id    TEXT PRIMARY KEY,
    secret_hash  TEXT NOT NULL,
    scopes       TEXT NOT NULL                      -- space-separated scopes this client may be granted
);

CREATE OR REPLACE FUNCTION sha256_hex(p TEXT) RETURNS TEXT AS $$
    SELECT encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex');
$$ LANGUAGE sql IMMUTABLE;

-- Register (or rotate) an agent's client secret. Returns the new secret ONCE - only its hash is kept.
CREATE OR REPLACE FUNCTION register_agent_client(p_client TEXT, p_scopes TEXT)
RETURNS TABLE (client_id TEXT, client_secret TEXT, scopes TEXT) AS $$
DECLARE s TEXT := md5(random()::text || clock_timestamp()::text) || md5(random()::text);
BEGIN
    INSERT INTO oauth_clients VALUES (p_client, sha256_hex(s), p_scopes)
    ON CONFLICT ON CONSTRAINT oauth_clients_pkey DO UPDATE SET secret_hash = EXCLUDED.secret_hash, scopes = EXCLUDED.scopes;
    RETURN QUERY SELECT p_client, s, p_scopes;
END $$ LANGUAGE plpgsql;

-- POST /oauth/token (client credentials). Client authentication: HTTP Basic header, or client_id/client_secret fields.
-- Returns the HTTP status, an OAuth error code, and - when 200 - the JWT claims to sign.
CREATE OR REPLACE FUNCTION token_request(p_auth TEXT, p_grant TEXT, p_client TEXT, p_secret TEXT, p_scope TEXT,
                                         p_ttl TEXT)
RETURNS TABLE (status INTEGER, error TEXT, client_id TEXT, scope TEXT, expires_in INTEGER, claims TEXT) AS $$
    WITH basic AS (
        SELECT CASE WHEN coalesce(p_auth, '') ILIKE 'basic %'
                    THEN convert_from(decode(trim(substr(p_auth, 7)), 'base64'), 'UTF8') END AS pair),
    cred AS (
        SELECT coalesce(nullif(split_part(b.pair, ':', 1), ''), p_client) AS cid,
               coalesce(CASE WHEN b.pair LIKE '%:%' THEN substr(b.pair, strpos(b.pair, ':') + 1) END, p_secret) AS sec
        FROM basic b),
    chk AS (
        SELECT c.cid, (o.client_id IS NOT NULL AND o.secret_hash = sha256_hex(c.sec)) AS ok, o.scopes,
               coalesce(nullif(trim(coalesce(p_ttl, '')), '')::int, 600) AS ttl
        FROM cred c LEFT JOIN oauth_clients o ON o.client_id = c.cid),
    granted AS (
        SELECT chk.*, (SELECT string_agg(x, ' ' ORDER BY x) FROM unnest(string_to_array(chk.scopes, ' ')) x
                       WHERE ' ' || coalesce(nullif(trim(coalesce(p_scope, '')), ''), chk.scopes) || ' '
                             LIKE '% ' || x || ' %') AS g
        FROM chk)
    SELECT CASE WHEN coalesce(p_grant, '') <> 'client_credentials' THEN 400 WHEN NOT coalesce(ok, false) THEN 401 ELSE 200 END,
           CASE WHEN coalesce(p_grant, '') <> 'client_credentials' THEN 'unsupported_grant_type'
                WHEN NOT coalesce(ok, false) THEN 'invalid_client' ELSE '' END,
           coalesce(cid, ''), coalesce(g, ''), ttl,
           CASE WHEN coalesce(ok, false) AND p_grant = 'client_credentials' THEN json_build_object(
               'iss', 'harbor-bank-idp', 'sub', cid, 'aud', json_build_array('harbor-bank-api'),
               'scp', to_json(string_to_array(coalesce(g, ''), ' ')),
               'iat', floor(extract(epoch FROM now()))::bigint - 2,           -- truncate (::bigint rounds up) + 2s skew
               'exp', floor(extract(epoch FROM now()))::bigint + ttl)::text
                ELSE '' END
    FROM granted;
$$ LANGUAGE sql STABLE;

-- API gateway decision for one call: token valid (signature + exp are checked by the Flogo JWT activity), issuer,
-- audience and the endpoint's scope -> 401 / 403 / 200. The registry (status, expiry, entitlement) is then checked by
-- the tool SQL on every call, exactly as in the base sample.
CREATE OR REPLACE FUNCTION api_gate(p_valid TEXT, p_claims TEXT, p_required_scope TEXT)
RETURNS TABLE (status INTEGER, error TEXT, agent_id TEXT, required_scope TEXT) AS $$
    WITH c AS (SELECT CASE WHEN p_valid = 'true' AND coalesce(p_claims, '') LIKE '{%' THEN p_claims::json END AS j),
    d AS (SELECT j->>'sub' AS sub,
                 coalesce(j->>'iss' = 'harbor-bank-idp'
                          AND (j->'aud')::text LIKE '%"harbor-bank-api"%', false) AS token_ok,
                 coalesce(p_required_scope, '') = ''
                   OR coalesce((j->'scp')::text LIKE '%"' || p_required_scope || '"%', false) AS scope_ok
          FROM c)
    SELECT CASE WHEN NOT token_ok OR coalesce(sub, '') = '' THEN 401 WHEN NOT scope_ok THEN 403 ELSE 200 END,
           CASE WHEN NOT token_ok OR coalesce(sub, '') = '' THEN 'invalid_token' WHEN NOT scope_ok THEN 'insufficient_scope'
                ELSE '' END,
           coalesce(sub, ''), coalesce(p_required_scope, '')
    FROM d;
$$ LANGUAGE sql STABLE;

-- Audit row for a call the gateway refuses for a missing scope (0 rows otherwise).
CREATE OR REPLACE FUNCTION api_denial_row(p_valid TEXT, p_claims TEXT, p_required_scope TEXT, p_tool TEXT, p_target TEXT)
RETURNS TABLE (agent_id TEXT, tool TEXT, target TEXT, decision TEXT, reason TEXT, detail TEXT) AS $$
    SELECT g.agent_id, p_tool, nullif(upper(trim(coalesce(p_target, ''))), ''), 'DENIED',
           'MISSING_SCOPE_' || p_required_scope, 'refused at the API gateway'
    FROM api_gate(p_valid, p_claims, p_required_scope) g WHERE g.status = 403;
$$ LANGUAGE sql STABLE;

\ir reset_data.sql
