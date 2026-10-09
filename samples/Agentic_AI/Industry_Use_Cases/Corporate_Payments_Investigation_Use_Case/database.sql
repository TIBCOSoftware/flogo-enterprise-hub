-- Aurelia Global Bank Corporate Payment Investigation & Status (GOVERNED) - schema, business rules and demo data.
-- Load:  createdb payments_governed  &&  psql -v ON_ERROR_STOP=1 -f database.sql
--
-- =====================================================================
-- Corporate Payment Investigation & Status - Governed Agentic AI
-- The rules live HERE, not in any prompt:
--   * session_client()         identity: every read/write is scoped by a session token (client id + passcode)
--   * verify_and_record()      5 wrong passcodes in 15 minutes -> LOCKED, no token even with the right code
--   * delivery_estimate()      ON_TRACK / PAST_CUTOFF / DELAYED / SETTLED is ARITHMETIC from cutoff_rules, never guessed
--   * trace_eval()             trace eligibility (ownership, traceable, not already investigated, valid reason)
--   * recall_eval()            recall eligibility (ownership, recallable direction/status/age, valid reason)
--   * trg_investigation_apply  a confirmed trace opens the investigation, writes a payment_event and audits atomically
--   * trg_review_case_apply    a confirmed recall sets the payment RECALL_REQUESTED and opens a Payment Ops review case
--   * lookup_reason_code()     return/reason-code decoding for the A2A payment_triage_agent - NO client identity
--   * service_teams            human-owned requests (recall, fee waiver, fraud, sanctions...) routed by a table
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The one genuinely semantic step is the A2A payment_triage_agent matching the client's words to a payment
-- and decoding the cryptic return/reason code into plain language.
-- Aurelia Global Bank, its clients, accounts, beneficiaries and payments are fictional.
-- =====================================================================

DROP TABLE IF EXISTS agent_audit, review_cases, service_teams, investigations, pending_actions,
  verify_attempts, client_sessions, payment_events, payments, cutoff_rules, reason_codes,
  accounts, clients CASCADE;
DROP SEQUENCE IF EXISTS inv_seq, case_seq;

-- Demo stand-in for a salted passcode hash (production: OIDC/OAuth on the MCP trigger, or bcrypt).
CREATE OR REPLACE FUNCTION passcode_hash(p_client TEXT, p_code TEXT) RETURNS TEXT AS $$
  SELECT encode(sha256(convert_to(upper(trim(coalesce(p_client,''))) || ':' || trim(coalesce(p_code,'')), 'UTF8')), 'hex')
$$ LANGUAGE sql IMMUTABLE;

-- Helper: add N business days (skips Saturday and Sunday).
CREATE OR REPLACE FUNCTION add_business_days(p_start DATE, p_days INTEGER) RETURNS DATE AS $$
DECLARE d DATE := p_start; n INTEGER := 0;
BEGIN
  WHILE n < coalesce(p_days, 0) LOOP
    d := d + 1;
    IF extract(isodow FROM d) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN d;
END $$ LANGUAGE plpgsql IMMUTABLE;

-- Helper: count business days strictly after p_from up to and including p_to (0 if p_to <= p_from).
CREATE OR REPLACE FUNCTION business_days_between(p_from DATE, p_to DATE) RETURNS INTEGER AS $$
DECLARE d DATE := p_from; n INTEGER := 0;
BEGIN
  WHILE d < p_to LOOP
    d := d + 1;
    IF extract(isodow FROM d) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE TABLE clients (
  client_id      VARCHAR(20) PRIMARY KEY,            -- CLI-2026-NNNNN (the login id)
  legal_name     VARCHAR(80) NOT NULL,
  contact_email  VARCHAR(100) NOT NULL,
  passcode_hash  TEXT NOT NULL,                      -- passcode_hash(client_id, 6-digit passcode)
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE accounts (
  account_id             VARCHAR(20) PRIMARY KEY,    -- ACC-NNNN
  client_id              VARCHAR(20) NOT NULL REFERENCES clients,
  account_number_masked  VARCHAR(20) NOT NULL,
  currency               VARCHAR(3) NOT NULL DEFAULT 'USD'
);

-- Return/reason-code directory. Read by the A2A payment_triage_agent (lookup_reason_code). NO client data.
CREATE TABLE reason_codes (
  code            VARCHAR(8) PRIMARY KEY,            -- AC04, BE01, ...
  rail            VARCHAR(16) NOT NULL,              -- SWIFT | SEPA | ANY
  plain_language  VARCHAR(200) NOT NULL,            -- what it means in plain English
  category        VARCHAR(16) NOT NULL CHECK (category IN ('BENEFICIARY','COMPLIANCE','TECHNICAL','ACCOUNT','OTHER')),
  typical_action  VARCHAR(200) NOT NULL             -- what usually resolves it
);

-- Deterministic settlement rules: rail+currency -> cutoff hour (local, 24h) and settlement days (T+n).
CREATE TABLE cutoff_rules (
  rail            VARCHAR(16) NOT NULL,
  currency        VARCHAR(3) NOT NULL,
  cutoff_hour     INTEGER NOT NULL,                  -- 24 = no same-day cutoff (immediate rails)
  settlement_days INTEGER NOT NULL,                  -- T+n business days
  PRIMARY KEY (rail, currency)
);

CREATE TABLE payments (
  payment_ref          VARCHAR(20) PRIMARY KEY,      -- PMT-2026-NNNNNN
  client_id            VARCHAR(20) NOT NULL REFERENCES clients,
  debtor_account       VARCHAR(20) REFERENCES accounts,
  direction            VARCHAR(10) NOT NULL CHECK (direction IN ('OUTGOING','INCOMING')),
  rail                 VARCHAR(16) NOT NULL CHECK (rail IN ('SWIFT','SEPA','FEDWIRE','FASTER_PAYMENTS','ACH')),
  amount               NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency             VARCHAR(3) NOT NULL,
  fx_rate              NUMERIC(12,6),                 -- NULL when no conversion
  fees                 NUMERIC(10,2) NOT NULL DEFAULT 0,
  beneficiary_name     VARCHAR(80) NOT NULL,
  beneficiary_bank_bic VARCHAR(16) NOT NULL,
  status               VARCHAR(20) NOT NULL DEFAULT 'INITIATED'
                         CHECK (status IN ('INITIATED','IN_TRANSIT','COMPLETED','RETURNED','HELD','RECALL_REQUESTED','RECALLED')),
  return_reason_code   VARCHAR(8) REFERENCES reason_codes,   -- set only when RETURNED
  value_date           DATE NOT NULL,
  created_at           TIMESTAMP NOT NULL
);

-- GPI-style event timeline for a payment (one row per processing step).
CREATE TABLE payment_events (
  id           SERIAL PRIMARY KEY,
  payment_ref  VARCHAR(20) NOT NULL REFERENCES payments,
  event_time   TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  actor        VARCHAR(60) NOT NULL,                 -- agent/correspondent bank or 'Aurelia Global Bank'
  action       VARCHAR(40) NOT NULL,
  detail       VARCHAR(200)
);

CREATE TABLE client_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  client_id      VARCHAR(20) NOT NULL REFERENCES clients,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes'
);

-- Brute-force throttle for the passcode step: one row per attempt on a REAL client id.
CREATE TABLE verify_attempts (
  attempt_id  SERIAL PRIMARY KEY,
  client_id   VARCHAR(20) NOT NULL REFERENCES clients,
  ok          BOOLEAN NOT NULL,
  at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pending_actions (
  action_id          TEXT PRIMARY KEY DEFAULT 'ACT-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  action_type        VARCHAR(8) NOT NULL CHECK (action_type IN ('TRACE','RECALL')),
  client_id          VARCHAR(20) NOT NULL REFERENCES clients,
  payment_ref        VARCHAR(20) NOT NULL REFERENCES payments,
  reason_code        VARCHAR(8) NOT NULL,
  client_statement   TEXT,
  est_response_date  DATE,                           -- frozen trace response date (NULL for recall)
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','EXECUTED')),
  confirm_count      INTEGER NOT NULL DEFAULT 0,     -- confirm calls seen (distinguishes EXECUTED vs ALREADY_EXECUTED)
  executed_no        INTEGER,                        -- which confirm call executed it
  created_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

CREATE SEQUENCE inv_seq START 2;   -- INV-2026-0001 is seeded (already-open investigation); live traces continue at 0002
CREATE TABLE investigations (
  investigation_id   VARCHAR(16) PRIMARY KEY DEFAULT 'INV-2026-' || lpad(nextval('inv_seq')::text, 4, '0'),
  action_id          TEXT UNIQUE REFERENCES pending_actions,   -- NULL only for seeded history
  client_id          VARCHAR(20) NOT NULL REFERENCES clients,
  payment_ref        VARCHAR(20) NOT NULL REFERENCES payments,
  reason_code        VARCHAR(8) NOT NULL,
  client_statement   TEXT,
  status             VARCHAR(14) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','UNDER_REVIEW','RESOLVED')),
  est_response_date  DATE NOT NULL,
  created_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE inv_seq OWNED BY investigations.investigation_id;
-- Defence in depth: never two live investigations on one payment.
CREATE UNIQUE INDEX investigations_one_live_per_payment ON investigations (payment_ref) WHERE status IN ('OPEN','UNDER_REVIEW');

CREATE TABLE service_teams (
  request_type         VARCHAR(24) PRIMARY KEY,
  team                 VARCHAR(60) NOT NULL,
  reply_business_days  INTEGER NOT NULL
);

CREATE SEQUENCE case_seq START 1;
CREATE TABLE review_cases (
  case_id           VARCHAR(12) PRIMARY KEY DEFAULT 'CASE-' || lpad(nextval('case_seq')::text, 5, '0'),
  action_id         TEXT UNIQUE REFERENCES pending_actions,     -- set for recall confirmations; NULL for human cases
  client_id         VARCHAR(20) NOT NULL REFERENCES clients,
  request_type      VARCHAR(24) NOT NULL REFERENCES service_teams,
  payment_ref       VARCHAR(20) REFERENCES payments,
  client_statement  TEXT NOT NULL,
  agent_brief       TEXT NOT NULL,            -- neutral summary written by the assistant (or the system); never a decision
  assigned_team     VARCHAR(60) NOT NULL,
  status            VARCHAR(12) NOT NULL DEFAULT 'OPEN',
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE case_seq OWNED BY review_cases.case_id;

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; no MCP tool exposes it.
CREATE TABLE agent_audit (
  id         SERIAL PRIMARY KEY,
  at         TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  client_id  VARCHAR(20),
  action     VARCHAR(30) NOT NULL,   -- VERIFY, TRACE_PROPOSED, TRACE_OPENED, RECALL_PROPOSED, RECALL_SUBMITTED, REVIEW_CASE_OPENED
  ref        TEXT,
  detail     TEXT
);

-- =====================================================================
-- RULES
-- =====================================================================

-- Identity: a token is valid for its client until it expires. ALWAYS returns exactly one row -
-- the client when valid, or (null,null) when not - so dependent reads can emit SESSION_INVALID.
-- plpgsql (NOT sql) on purpose: an inlinable SQL function here merges into the caller's LEFT JOINs
-- and can mis-bind rows. plpgsql is opaque to the planner, so callers see a clean one-row relation.
CREATE OR REPLACE FUNCTION session_client(p_token TEXT)
RETURNS TABLE (client_id TEXT, legal_name TEXT) AS $$
BEGIN
  RETURN QUERY
    SELECT c.client_id::text, c.legal_name::text
      FROM (SELECT 1) one
      LEFT JOIN client_sessions s ON s.session_token = p_token AND s.expires_at > clock_timestamp()
      LEFT JOIN clients c ON c.client_id = s.client_id;
END $$ LANGUAGE plpgsql STABLE;

-- Lockout rule: 5 failed passcodes within 15 minutes (since the last success) -> locked.
CREATE OR REPLACE FUNCTION client_locked_until(p_client TEXT) RETURNS TIMESTAMP AS $$
  SELECT CASE WHEN count(*) >= 5 THEN min(f.at) + INTERVAL '15 minutes' END
    FROM (SELECT va.at FROM verify_attempts va
           WHERE va.client_id = upper(trim(coalesce(p_client,''))) AND NOT va.ok
             AND va.at > clock_timestamp() - INTERVAL '15 minutes'
             AND va.at > coalesce((SELECT max(v2.at) FROM verify_attempts v2
                                    WHERE v2.client_id = va.client_id AND v2.ok), '-infinity'::timestamp)
           ORDER BY va.at DESC LIMIT 5) f;
$$ LANGUAGE sql STABLE;

-- Throttle: record a verify attempt and return the client_id ONLY on a correct, non-locked attempt.
-- Side-effecting (VOLATILE). Used inside the verify tool's INSERT ... SELECT, so a session is created
-- only when it returns a row.
CREATE OR REPLACE FUNCTION verify_and_record(p_client TEXT, p_code TEXT)
RETURNS TABLE (client_id TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT := upper(trim(coalesce(p_client,''))); c clients;
BEGIN
  IF client_locked_until(v_cid) IS NOT NULL THEN
    RETURN;                                            -- locked: no session, even if the passcode is right
  END IF;
  SELECT * INTO c FROM clients cu WHERE cu.client_id = v_cid;
  IF NOT FOUND THEN RETURN; END IF;                    -- unknown ids are not tracked (bounds the table)
  IF c.passcode_hash = passcode_hash(v_cid, p_code) THEN
    INSERT INTO verify_attempts (client_id, ok) VALUES (v_cid, TRUE);
    RETURN QUERY SELECT c.client_id::text; RETURN;
  END IF;
  INSERT INTO verify_attempts (client_id, ok) VALUES (v_cid, FALSE);
  RETURN;                                              -- no session
END $$ LANGUAGE plpgsql VOLATILE;

-- Verify: client id + 6-digit passcode -> VERIFIED + token, LOCKED after too many wrong codes, else NOT_VERIFIED.
CREATE OR REPLACE FUNCTION verify_result(p_client TEXT, p_code TEXT)
RETURNS TABLE (status TEXT, reason TEXT, session_token TEXT, legal_name TEXT, client_id TEXT, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN lk.until IS NOT NULL THEN 'LOCKED' WHEN s.session_token IS NULL THEN 'NOT_VERIFIED' ELSE 'VERIFIED' END,
         CASE WHEN lk.until IS NOT NULL THEN 'LOCKED: too many failed attempts. Verification is locked until '
                                             || to_char(lk.until, 'HH24:MI') || '. The client can retry then or call Aurelia Global Bank.'
              WHEN s.session_token IS NULL THEN 'NOT_VERIFIED: the client id and passcode do not match. Nothing is revealed about which one is wrong.'
              ELSE 'VERIFIED: session valid for 30 minutes.' END,
         CASE WHEN lk.until IS NULL THEN s.session_token END,
         CASE WHEN lk.until IS NULL THEN s.legal_name END,
         upper(trim(coalesce(p_client,''))),
         CASE WHEN lk.until IS NULL THEN s.expires_at END
    FROM (SELECT client_locked_until(p_client) AS until) lk
    LEFT JOIN LATERAL (
      SELECT se.session_token, c.legal_name, se.expires_at
        FROM clients c
        JOIN client_sessions se ON se.client_id = c.client_id AND se.expires_at > clock_timestamp()
       WHERE c.client_id = upper(trim(coalesce(p_client,''))) AND c.passcode_hash = passcode_hash(p_client, p_code)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Scoped reads: only the caller's rows; one SESSION_INVALID row for a bad token.
-- ---------------------------------------------------------------------

-- Payments: empty search = last 90 days (newest first, max 25); a search term (payment ref, beneficiary text,
-- or an amount like 48500) looks back 18 months so an older payment is still found. NO_MATCH when nothing matches.
CREATE OR REPLACE FUNCTION my_payments(p_token TEXT, p_search TEXT)
RETURNS TABLE (session_status TEXT, payment_ref VARCHAR, direction VARCHAR, rail VARCHAR, amount NUMERIC,
               currency VARCHAR, fx_rate NUMERIC, fees NUMERIC, beneficiary_name VARCHAR, beneficiary_bank_bic VARCHAR,
               status VARCHAR, return_reason_code VARCHAR, value_date DATE, created_at TIMESTAMP,
               open_investigation_id VARCHAR) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' WHEN p.payment_ref IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         p.payment_ref, p.direction, p.rail, p.amount, p.currency, p.fx_rate, p.fees, p.beneficiary_name,
         p.beneficiary_bank_bic, p.status, p.return_reason_code, p.value_date, p.created_at, p.open_investigation_id
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT x.payment_ref, x.direction, x.rail, x.amount, x.currency, x.fx_rate, x.fees, x.beneficiary_name,
             x.beneficiary_bank_bic, x.status, x.return_reason_code, x.value_date, x.created_at,
             i.investigation_id AS open_investigation_id
        FROM payments x
        LEFT JOIN investigations i ON i.payment_ref = x.payment_ref AND i.status IN ('OPEN','UNDER_REVIEW')
        CROSS JOIN (SELECT upper(trim(coalesce(p_search,''))) AS q) s
       WHERE x.client_id = sc.client_id
         AND CASE WHEN s.q = '' THEN x.created_at >= clock_timestamp() - INTERVAL '90 days'
                  ELSE x.created_at >= clock_timestamp() - INTERVAL '18 months'
                       AND (position(s.q IN upper(x.payment_ref)) > 0
                            OR position(s.q IN upper(x.beneficiary_name)) > 0
                            OR position(s.q IN upper(x.beneficiary_bank_bic)) > 0
                            OR (replace(replace(s.q,',',''),'$','') ~ '^[0-9]+(\.[0-9]{1,2})?$'
                                AND x.amount = replace(replace(s.q,',',''),'$','')::numeric)) END
       ORDER BY x.created_at DESC
       LIMIT 25) p ON sc.client_id IS NOT NULL
   ORDER BY p.created_at DESC;
$$ LANGUAGE sql STABLE;

-- One payment of THIS client: full status, with the return reason decoded when RETURNED. NOT_YOUR_PAYMENT otherwise.
CREATE OR REPLACE FUNCTION payment_status_for_session(p_token TEXT, p_ref TEXT)
RETURNS TABLE (lookup_status TEXT, payment_ref VARCHAR, direction VARCHAR, rail VARCHAR, amount NUMERIC,
               currency VARCHAR, fx_rate NUMERIC, fees NUMERIC, beneficiary_name VARCHAR, beneficiary_bank VARCHAR,
               status VARCHAR, return_reason_code VARCHAR, return_reason_plain VARCHAR, value_date DATE,
               created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' WHEN p.payment_ref IS NULL THEN 'NOT_YOUR_PAYMENT' ELSE 'OK' END,
         p.payment_ref, p.direction, p.rail, p.amount, p.currency, p.fx_rate, p.fees, p.beneficiary_name,
         p.beneficiary_bank_bic, p.status, p.return_reason_code, rc.plain_language, p.value_date, p.created_at
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN payments p ON p.client_id = sc.client_id AND p.payment_ref = upper(trim(coalesce(p_ref,'')))
    LEFT JOIN reason_codes rc ON rc.code = p.return_reason_code;
$$ LANGUAGE sql STABLE;

-- GPI-style event timeline for one payment of THIS client. One SESSION_INVALID/NOT_YOUR_PAYMENT row otherwise.
CREATE OR REPLACE FUNCTION payment_timeline(p_token TEXT, p_ref TEXT)
RETURNS TABLE (lookup_status TEXT, payment_ref VARCHAR, event_time TIMESTAMP, actor VARCHAR, action VARCHAR, detail VARCHAR) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' WHEN p.payment_ref IS NULL THEN 'NOT_YOUR_PAYMENT' ELSE 'OK' END,
         upper(trim(coalesce(p_ref,'')))::varchar, ev.event_time, ev.actor, ev.action, ev.detail
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN payments p ON p.client_id = sc.client_id AND p.payment_ref = upper(trim(coalesce(p_ref,'')))
    LEFT JOIN payment_events ev ON ev.payment_ref = p.payment_ref
   ORDER BY ev.event_time;
$$ LANGUAGE sql STABLE;

-- Rule: delivery estimate for one payment of THIS client. Pure ARITHMETIC from cutoff_rules + business days.
-- COMPLETED -> SETTLED; else compute the expected settlement date and classify:
--   DELAYED (past the expected date, not settled) / PAST_CUTOFF (created today after the cutoff hour) / ON_TRACK.
-- RETURNED/HELD/RECALL_REQUESTED/RECALLED -> NOT_APPLICABLE (a delivery estimate does not apply).
CREATE OR REPLACE FUNCTION delivery_estimate(p_token TEXT, p_ref TEXT)
RETURNS TABLE (lookup_status TEXT, payment_ref VARCHAR, rail VARCHAR, currency VARCHAR, outcome TEXT,
               cutoff_hour INTEGER, settlement_days INTEGER, expected_settlement_date DATE, detail TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; p payments; cr cutoff_rules; v_missed BOOLEAN; v_extra INTEGER; v_expected DATE;
BEGIN
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    lookup_status := 'SESSION_INVALID'; outcome := 'SESSION_INVALID';
    detail := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO p FROM payments x WHERE x.client_id = v_cid AND x.payment_ref = upper(trim(coalesce(p_ref,'')));
  IF NOT FOUND THEN
    lookup_status := 'NOT_YOUR_PAYMENT'; outcome := 'NOT_YOUR_PAYMENT';
    detail := 'NOT_YOUR_PAYMENT: no payment ' || coalesce(nullif(trim(p_ref),''),'(blank)') || ' on this client''s accounts. Use get_my_payments.';
    RETURN NEXT; RETURN;
  END IF;
  lookup_status := 'OK'; payment_ref := p.payment_ref; rail := p.rail; currency := p.currency;
  SELECT * INTO cr FROM cutoff_rules x WHERE x.rail = p.rail AND x.currency = p.currency;
  cutoff_hour := cr.cutoff_hour; settlement_days := cr.settlement_days;
  IF p.status = 'COMPLETED' THEN
    outcome := 'SETTLED';
    expected_settlement_date := p.value_date;
    detail := 'SETTLED: the payment completed and settled on ' || to_char(p.value_date,'YYYY-MM-DD') || '.';
    RETURN NEXT; RETURN;
  END IF;
  IF p.status IN ('RETURNED','HELD','RECALL_REQUESTED','RECALLED') THEN
    outcome := 'NOT_APPLICABLE';
    detail := 'NOT_APPLICABLE: the payment is ' || p.status || '; a delivery estimate does not apply. See get_payment_status.';
    RETURN NEXT; RETURN;
  END IF;
  IF cr.rail IS NULL THEN
    outcome := 'NO_ESTIMATE';
    detail := 'NO_ESTIMATE: no settlement rule is on file for ' || p.rail || '/' || p.currency || '.';
    RETURN NEXT; RETURN;
  END IF;
  v_missed := extract(hour FROM p.created_at) >= cr.cutoff_hour;
  v_extra := CASE WHEN v_missed THEN 1 ELSE 0 END;
  v_expected := add_business_days(p.created_at::date, cr.settlement_days + v_extra);
  expected_settlement_date := v_expected;
  IF v_expected < current_date THEN
    outcome := 'DELAYED';
    detail := 'DELAYED: expected to settle by ' || to_char(v_expected,'YYYY-MM-DD') || ' (' || p.rail || '/' || p.currency
              || ', T+' || cr.settlement_days || '), but it is past that date and the payment is still ' || p.status || '.';
  ELSIF p.created_at::date = current_date AND v_missed THEN
    outcome := 'PAST_CUTOFF';
    detail := 'PAST_CUTOFF: submitted after today''s ' || cr.cutoff_hour || ':00 ' || p.rail || ' cutoff, so it processes the next business day; expected to settle by '
              || to_char(v_expected,'YYYY-MM-DD') || '.';
  ELSE
    outcome := 'ON_TRACK';
    detail := 'ON_TRACK: expected to settle by ' || to_char(v_expected,'YYYY-MM-DD') || ' (' || p.rail || '/' || p.currency
              || ', T+' || cr.settlement_days || ').';
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Agent tool: decode a return/reason code. NO client identity is passed in or returned.
CREATE OR REPLACE FUNCTION lookup_reason_code(p_code TEXT)
RETURNS TABLE (match_status TEXT, code VARCHAR, rail VARCHAR, plain_language VARCHAR, category VARCHAR, typical_action VARCHAR) AS $$
  SELECT CASE WHEN rc.code IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         rc.code, rc.rail, rc.plain_language, rc.category, rc.typical_action
    FROM (SELECT upper(trim(coalesce(p_code,''))) AS q) s
    LEFT JOIN reason_codes rc ON rc.code = s.q
   ORDER BY rc.code;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Trace / investigation (two-step)
-- ---------------------------------------------------------------------

-- Rule: may this client raise a trace on this payment for this reason? ok + a reason code to explain verbatim.
CREATE OR REPLACE FUNCTION trace_eval(p_token TEXT, p_ref TEXT, p_reason TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, payment_ref TEXT, amount NUMERIC, currency TEXT,
               beneficiary_name TEXT, decoded_reason TEXT, est_response_date DATE) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; p payments; v_reason TEXT := upper(trim(coalesce(p_reason,''))); v_inv TEXT; v_plain TEXT;
BEGIN
  ok := FALSE;
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO p FROM payments x WHERE x.client_id = v_cid AND x.payment_ref = upper(trim(coalesce(p_ref,'')));
  IF NOT FOUND THEN
    reason_code := 'NOT_YOUR_PAYMENT';
    reason := 'NOT_YOUR_PAYMENT: no payment ' || coalesce(nullif(trim(p_ref),''),'(blank)') || ' on this client''s accounts. Use get_my_payments.';
    RETURN NEXT; RETURN;
  END IF;
  payment_ref := p.payment_ref; amount := p.amount; currency := p.currency; beneficiary_name := p.beneficiary_name;
  SELECT rc.plain_language INTO v_plain FROM reason_codes rc WHERE rc.code = v_reason;
  decoded_reason := v_plain;
  IF p.status = 'INITIATED' OR p.created_at > clock_timestamp() - INTERVAL '2 hours' THEN
    reason_code := 'NOT_TRACEABLE';
    reason := 'NOT_TRACEABLE: ' || p.payment_ref || ' is ' || p.status
              || ' and was submitted less than 2 hours ago; a trace can only be raised once it has had time to move. Check back later.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT i.investigation_id INTO v_inv FROM investigations i
   WHERE i.payment_ref = p.payment_ref AND i.status IN ('OPEN','UNDER_REVIEW') LIMIT 1;
  IF v_inv IS NOT NULL THEN
    reason_code := 'ALREADY_UNDER_INVESTIGATION';
    reason := 'ALREADY_UNDER_INVESTIGATION: ' || p.payment_ref || ' already has an open investigation, ' || v_inv || '.';
    RETURN NEXT; RETURN;
  END IF;
  IF v_plain IS NULL THEN
    reason_code := 'BAD_REASON';
    reason := 'BAD_REASON: ' || coalesce(nullif(v_reason,''),'(blank)') || ' is not a known return/reason code. Use lookup_reason_code or MS03 (reason not specified).';
    RETURN NEXT; RETURN;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE'; reason := 'ELIGIBLE';
  est_response_date := add_business_days(current_date, 3);
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write row: a pending trace is written ONLY when every rule passes (and not twice).
CREATE OR REPLACE FUNCTION trace_proposal_row(p_token TEXT, p_ref TEXT, p_reason TEXT, p_statement TEXT)
RETURNS TABLE (action_type TEXT, client_id TEXT, payment_ref TEXT, reason_code TEXT, client_statement TEXT, est_response_date DATE) AS $$
  SELECT 'TRACE', sc.client_id, e.payment_ref, upper(trim(coalesce(p_reason,''))), left(coalesce(p_statement,''), 4000), e.est_response_date
    FROM session_client(p_token) sc
    CROSS JOIN LATERAL trace_eval(p_token, p_ref, p_reason) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.client_id = sc.client_id AND pa.action_type = 'TRACE'
                        AND pa.payment_ref = e.payment_ref AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_trace_result(p_token TEXT, p_ref TEXT, p_reason TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, payment_ref TEXT, amount NUMERIC,
               currency TEXT, beneficiary_name TEXT, decoded_reason TEXT, est_response_date DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; pa pending_actions; v_cid TEXT;
BEGIN
  SELECT * INTO e FROM trace_eval(p_token, p_ref, p_reason);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  payment_ref := e.payment_ref; amount := e.amount; currency := e.currency; beneficiary_name := e.beneficiary_name;
  decoded_reason := e.decoded_reason;
  IF e.ok THEN
    SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
    SELECT * INTO pa FROM pending_actions p
     WHERE p.client_id = v_cid AND p.action_type = 'TRACE' AND p.payment_ref = e.payment_ref
       AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
     ORDER BY p.created_at DESC LIMIT 1;
    IF FOUND THEN
      outcome := 'PROPOSED'; reason_code := 'PROPOSED';
      reason := 'Awaiting the client''s explicit yes. Nothing has changed yet. On confirm, an investigation is opened with the agent bank. '
                || 'Read back the amount, beneficiary, decoded reason and estimated response date exactly as given.';
      action_id := pa.action_id; expires_at := pa.expires_at; est_response_date := pa.est_response_date;
    ELSE
      reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the proposal could not be recorded. Try again.';
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Confirm row: VOLATILE because it counts confirm calls (so a repeat confirm reads ALREADY_EXECUTED).
CREATE OR REPLACE FUNCTION trace_confirmation_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, client_id TEXT, payment_ref TEXT, reason_code TEXT, client_statement TEXT, est_response_date DATE) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; e RECORD;
BEGIN
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.client_id = v_cid AND p.action_type = 'TRACE';
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE pending_actions p SET confirm_count = p.confirm_count + 1 WHERE p.action_id = pa.action_id;
  IF pa.status <> 'PENDING' OR pa.expires_at <= clock_timestamp() THEN RETURN; END IF;
  SELECT * INTO e FROM trace_eval(p_token, pa.payment_ref, pa.reason_code);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT pa.action_id::text, pa.client_id::text, pa.payment_ref::text, pa.reason_code::text,
                      pa.client_statement, add_business_days(current_date, 3);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_trace_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, investigation_id TEXT, payment_ref TEXT,
               status TEXT, est_response_date DATE, created_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; inv investigations; e RECORD;
BEGIN
  outcome := 'NOT_EXECUTED';
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.client_id = v_cid AND p.action_type = 'TRACE';
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_PROPOSAL'; reason := 'NO_SUCH_PROPOSAL: no trace proposal with that id for this client. Call propose_trace first.';
    RETURN NEXT; RETURN;
  END IF;
  payment_ref := pa.payment_ref;
  SELECT * INTO inv FROM investigations x WHERE x.action_id = pa.action_id;
  IF FOUND THEN
    investigation_id := inv.investigation_id; status := inv.status;
    est_response_date := inv.est_response_date; created_at := inv.created_at;
    IF pa.executed_no = pa.confirm_count THEN
      outcome := 'OPENED'; reason_code := 'OPENED';
      reason := 'Investigation ' || inv.investigation_id || ' opened with the agent bank. The team will respond by '
                || to_char(inv.est_response_date,'YYYY-MM-DD') || '.';
    ELSE
      reason_code := 'ALREADY_EXECUTED';
      reason := 'ALREADY_EXECUTED: this trace was already opened as ' || inv.investigation_id || '. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the proposal expired after 15 minutes. Propose the trace again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO e FROM trace_eval(p_token, pa.payment_ref, pa.reason_code);
  reason_code := e.reason_code; reason := e.reason;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Side effect: a confirmed trace opens the investigation, writes a payment_event and audits, atomically.
CREATE OR REPLACE FUNCTION apply_investigation() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO payment_events (payment_ref, actor, action, detail)
    VALUES (NEW.payment_ref, 'Aurelia Global Bank', 'INVESTIGATION OPENED',
            'Trace ' || NEW.investigation_id || ' raised (reason ' || NEW.reason_code || '); response expected by '
            || to_char(NEW.est_response_date,'YYYY-MM-DD') || '.');
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (NEW.client_id, 'TRACE_OPENED', NEW.investigation_id,
            NEW.payment_ref || ' reason ' || NEW.reason_code || coalesce(' (action ' || NEW.action_id || ')', ' (seeded)'));
  IF NEW.action_id IS NOT NULL THEN
    UPDATE pending_actions SET status = 'EXECUTED', executed_no = confirm_count WHERE action_id = NEW.action_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_investigation_apply AFTER INSERT ON investigations FOR EACH ROW EXECUTE FUNCTION apply_investigation();

-- ---------------------------------------------------------------------
-- Recall / return (two-step; money reversal is a human-owned request)
-- ---------------------------------------------------------------------

-- Rule: may this client request a recall of this payment for this reason? ok + a reason code to explain verbatim.
CREATE OR REPLACE FUNCTION recall_eval(p_token TEXT, p_ref TEXT, p_reason TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, payment_ref TEXT, amount NUMERIC, currency TEXT,
               beneficiary_name TEXT, decoded_reason TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; p payments; v_reason TEXT := upper(trim(coalesce(p_reason,''))); v_plain TEXT;
BEGIN
  ok := FALSE;
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO p FROM payments x WHERE x.client_id = v_cid AND x.payment_ref = upper(trim(coalesce(p_ref,'')));
  IF NOT FOUND THEN
    reason_code := 'NOT_YOUR_PAYMENT';
    reason := 'NOT_YOUR_PAYMENT: no payment ' || coalesce(nullif(trim(p_ref),''),'(blank)') || ' on this client''s accounts. Use get_my_payments.';
    RETURN NEXT; RETURN;
  END IF;
  payment_ref := p.payment_ref; amount := p.amount; currency := p.currency; beneficiary_name := p.beneficiary_name;
  SELECT rc.plain_language INTO v_plain FROM reason_codes rc WHERE rc.code = v_reason;
  decoded_reason := v_plain;
  IF p.status = 'RECALL_REQUESTED' THEN
    reason_code := 'ALREADY_RECALL_REQUESTED';
    reason := 'ALREADY_RECALL_REQUESTED: a recall has already been requested on ' || p.payment_ref || ' and is with Payment Operations.';
    RETURN NEXT; RETURN;
  END IF;
  IF p.direction = 'INCOMING' THEN
    reason_code := 'NOT_RECALLABLE';
    reason := 'NOT_RECALLABLE: ' || p.payment_ref || ' is an INCOMING payment to this client; only the sending party can recall it.';
    RETURN NEXT; RETURN;
  END IF;
  IF p.status IN ('RETURNED','RECALLED') THEN
    reason_code := 'NOT_RECALLABLE';
    reason := 'NOT_RECALLABLE: ' || p.payment_ref || ' is ' || p.status || ', so there are no funds in transit to recall.';
    RETURN NEXT; RETURN;
  END IF;
  IF p.status = 'COMPLETED' AND add_business_days(p.value_date, 5) < current_date THEN
    reason_code := 'NOT_RECALLABLE';
    reason := 'NOT_RECALLABLE: ' || p.payment_ref || ' completed on ' || to_char(p.value_date,'YYYY-MM-DD')
              || ', more than 5 business days ago; a recall request can no longer be raised here. Open a human review case instead.';
    RETURN NEXT; RETURN;
  END IF;
  IF v_plain IS NULL THEN
    reason_code := 'BAD_REASON';
    reason := 'BAD_REASON: ' || coalesce(nullif(v_reason,''),'(blank)') || ' is not a known return/reason code. Use lookup_reason_code (e.g. BE01 wrong beneficiary).';
    RETURN NEXT; RETURN;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE';
  reason := 'ELIGIBLE: a recall is a REQUEST to the beneficiary bank, decided by a person at Payment Operations. '
            || 'It is not guaranteed and does NOT reverse the funds automatically.';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write row: a pending recall is written ONLY when every rule passes (and not twice).
CREATE OR REPLACE FUNCTION recall_proposal_row(p_token TEXT, p_ref TEXT, p_reason TEXT, p_statement TEXT)
RETURNS TABLE (action_type TEXT, client_id TEXT, payment_ref TEXT, reason_code TEXT, client_statement TEXT) AS $$
  SELECT 'RECALL', sc.client_id, e.payment_ref, upper(trim(coalesce(p_reason,''))), left(coalesce(p_statement,''), 4000)
    FROM session_client(p_token) sc
    CROSS JOIN LATERAL recall_eval(p_token, p_ref, p_reason) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.client_id = sc.client_id AND pa.action_type = 'RECALL'
                        AND pa.payment_ref = e.payment_ref AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_recall_result(p_token TEXT, p_ref TEXT, p_reason TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, payment_ref TEXT, amount NUMERIC,
               currency TEXT, beneficiary_name TEXT, decoded_reason TEXT, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; pa pending_actions; v_cid TEXT;
BEGIN
  SELECT * INTO e FROM recall_eval(p_token, p_ref, p_reason);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  payment_ref := e.payment_ref; amount := e.amount; currency := e.currency; beneficiary_name := e.beneficiary_name;
  decoded_reason := e.decoded_reason;
  IF e.ok THEN
    SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
    SELECT * INTO pa FROM pending_actions p
     WHERE p.client_id = v_cid AND p.action_type = 'RECALL' AND p.payment_ref = e.payment_ref
       AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
     ORDER BY p.created_at DESC LIMIT 1;
    IF FOUND THEN
      outcome := 'PROPOSED'; reason_code := 'PROPOSED';
      reason := 'Awaiting the client''s explicit yes. Nothing has changed yet. A recall is a REQUEST a person at Payment Operations decides; '
                || 'it is not guaranteed and does NOT reverse the funds automatically. On confirm, a review case is opened.';
      action_id := pa.action_id; expires_at := pa.expires_at;
    ELSE
      reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the proposal could not be recorded. Try again.';
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION recall_confirmation_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, client_id TEXT, request_type TEXT, payment_ref TEXT, client_statement TEXT,
               agent_brief TEXT, assigned_team TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; e RECORD; p payments; tm service_teams;
BEGIN
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions pp
   WHERE pp.action_id = upper(trim(coalesce(p_action,''))) AND pp.client_id = v_cid AND pp.action_type = 'RECALL';
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE pending_actions pp SET confirm_count = pp.confirm_count + 1 WHERE pp.action_id = pa.action_id;
  IF pa.status <> 'PENDING' OR pa.expires_at <= clock_timestamp() THEN RETURN; END IF;
  SELECT * INTO e FROM recall_eval(p_token, pa.payment_ref, pa.reason_code);
  IF NOT e.ok THEN RETURN; END IF;
  SELECT * INTO p FROM payments x WHERE x.payment_ref = pa.payment_ref;
  SELECT * INTO tm FROM service_teams WHERE request_type = 'RECALL';
  RETURN QUERY SELECT pa.action_id::text, pa.client_id::text, 'RECALL'::text, pa.payment_ref::text,
                      coalesce(nullif(pa.client_statement,''),'(no statement)')::text,
                      ('SYSTEM: recall requested on ' || p.payment_ref || ' (' || p.direction || ' ' || p.rail || ' '
                       || p.amount || ' ' || p.currency || ' to ' || p.beneficiary_name || '), reason ' || pa.reason_code
                       || '. Funds are not auto-reversed; Payment Operations to contact the beneficiary bank.')::text,
                      tm.team::text;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_recall_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, case_id TEXT, payment_ref TEXT, payment_status TEXT,
               assigned_team TEXT, created_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; rvc review_cases; e RECORD; p payments;
BEGIN
  outcome := 'NOT_EXECUTED';
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO pa FROM pending_actions pp
   WHERE pp.action_id = upper(trim(coalesce(p_action,''))) AND pp.client_id = v_cid AND pp.action_type = 'RECALL';
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_PROPOSAL'; reason := 'NO_SUCH_PROPOSAL: no recall proposal with that id for this client. Call propose_recall first.';
    RETURN NEXT; RETURN;
  END IF;
  payment_ref := pa.payment_ref;
  SELECT * INTO rvc FROM review_cases x WHERE x.action_id = pa.action_id;
  IF FOUND THEN
    SELECT * INTO p FROM payments x WHERE x.payment_ref = pa.payment_ref;
    case_id := rvc.case_id; assigned_team := rvc.assigned_team; created_at := rvc.created_at; payment_status := p.status;
    IF pa.executed_no = pa.confirm_count THEN
      outcome := 'SUBMITTED'; reason_code := 'SUBMITTED';
      reason := 'Recall request ' || rvc.case_id || ' submitted to ' || rvc.assigned_team || '. The payment is now RECALL_REQUESTED. '
                || 'A person will decide; funds are not reversed automatically and the recall is not guaranteed.';
    ELSE
      reason_code := 'ALREADY_EXECUTED';
      reason := 'ALREADY_EXECUTED: this recall was already submitted as ' || rvc.case_id || '. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the proposal expired after 15 minutes. Propose the recall again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO e FROM recall_eval(p_token, pa.payment_ref, pa.reason_code);
  reason_code := e.reason_code; reason := e.reason;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Side effect: a confirmed recall sets the payment RECALL_REQUESTED, writes a payment_event and marks the
-- action executed, atomically; and ALWAYS audits. Human-owned (open_review_case) rows carry no action_id.
CREATE OR REPLACE FUNCTION apply_review_case() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.action_id IS NOT NULL AND NEW.request_type = 'RECALL' AND NEW.payment_ref IS NOT NULL THEN
    UPDATE payments SET status = 'RECALL_REQUESTED' WHERE payment_ref = NEW.payment_ref;
    INSERT INTO payment_events (payment_ref, actor, action, detail)
      VALUES (NEW.payment_ref, 'Aurelia Global Bank', 'RECALL REQUESTED',
              'Recall request ' || NEW.case_id || ' submitted to ' || NEW.assigned_team || '. Funds not auto-reversed.');
    UPDATE pending_actions SET status = 'EXECUTED', executed_no = confirm_count WHERE action_id = NEW.action_id;
    INSERT INTO agent_audit (client_id, action, ref, detail)
      VALUES (NEW.client_id, 'RECALL_SUBMITTED', NEW.case_id,
              NEW.payment_ref || ' -> ' || NEW.assigned_team || ' (action ' || NEW.action_id || ')');
  ELSE
    INSERT INTO agent_audit (client_id, action, ref, detail)
      VALUES (NEW.client_id, 'REVIEW_CASE_OPENED', NEW.case_id,
              NEW.request_type || ' -> ' || NEW.assigned_team || coalesce(' (' || NEW.payment_ref || ')', ''));
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_case_apply AFTER INSERT ON review_cases FOR EACH ROW EXECUTE FUNCTION apply_review_case();

-- ---------------------------------------------------------------------
-- Human-owned requests -> routed to a team by the table, never decided by the LLM.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION norm_request_type(p_type TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p_type,'')), '[\s-]+', '_', 'g'));
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION service_case_row(p_token TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT)
RETURNS TABLE (client_id TEXT, request_type VARCHAR, client_statement TEXT, agent_brief TEXT, assigned_team VARCHAR) AS $$
  SELECT sc.client_id, t.request_type, left(coalesce(p_statement,''), 4000), left(coalesce(p_brief,''), 4000), t.team
    FROM (SELECT * FROM session_client(p_token)) sc
    JOIN service_teams t ON t.request_type = norm_request_type(p_type)
   WHERE sc.client_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM review_cases c
                      WHERE c.client_id = sc.client_id AND c.request_type = t.request_type AND c.action_id IS NULL
                        AND c.created_at > clock_timestamp() - INTERVAL '10 minutes');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, case_id VARCHAR, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, reply_by DATE, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED'
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' ELSE 'BAD_TYPE' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'A person on the assigned team will review and reply. The assistant has not decided or promised anything.'
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              ELSE 'BAD_TYPE: use RECALL, PAYMENT_REPAIR, FEE_WAIVER, COMPENSATION, FRAUD, SANCTIONS_QUERY or OTHER.' END,
         c.case_id, c.request_type, t.team, t.reply_business_days,
         add_business_days(c.created_at::date, t.reply_business_days), c.status, c.created_at
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT x.* FROM review_cases x
       WHERE x.client_id = sc.client_id AND x.request_type = norm_request_type(p_type) AND x.action_id IS NULL
         AND x.created_at > clock_timestamp() - INTERVAL '10 minutes'
       ORDER BY x.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The client's investigations (INV-) and review cases (CASE-) in one list.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_type TEXT, reference_id TEXT, topic TEXT, payment_ref TEXT,
               assigned_team TEXT, status TEXT, expected_by DATE, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_type, c.reference_id, c.topic, c.payment_ref, c.assigned_team, c.status, c.expected_by, c.created_at
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT 'INVESTIGATION'::text AS case_type, i.investigation_id::text AS reference_id, i.reason_code::text AS topic,
             i.payment_ref::text AS payment_ref, 'Payment Investigations'::text AS assigned_team, i.status::text AS status,
             i.est_response_date AS expected_by, i.created_at
        FROM investigations i WHERE i.client_id = sc.client_id
      UNION ALL
      SELECT 'REVIEW_CASE', r.case_id, r.request_type, r.payment_ref, r.assigned_team, r.status,
             add_business_days(r.created_at::date, t.reply_business_days), r.created_at
        FROM review_cases r JOIN service_teams t ON t.request_type = r.request_type
       WHERE r.client_id = sc.client_id) c ON TRUE
   ORDER BY c.created_at DESC, c.reference_id DESC;
$$ LANGUAGE sql STABLE;

-- Email confirmation: validated payload for the guarded email tool. Returns SEND + subject/body ONLY when the
-- reference is an investigation (INV-) or review case (CASE-) of THIS client; otherwise NOT_SENT + reason.
-- The flow sends to the configured To_Email (ops inbox); the body never contains account numbers.
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason TEXT, reference_id TEXT, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN i.investigation_id IS NOT NULL OR rc.case_id IS NOT NULL THEN 'SEND' ELSE 'NOT_SENT' END,
         CASE WHEN i.investigation_id IS NOT NULL OR rc.case_id IS NOT NULL THEN 'SEND'
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' ELSE 'NO_SUCH_REFERENCE' END,
         CASE WHEN i.investigation_id IS NOT NULL OR rc.case_id IS NOT NULL THEN 'Confirmation email prepared.'
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID: verify again.'
              ELSE 'NO_SUCH_REFERENCE: no investigation (INV-) or review case (CASE-) with that reference for this client.' END,
         upper(trim(coalesce(p_reference,''))),
         CASE WHEN i.investigation_id IS NOT NULL THEN 'Aurelia Global Bank - investigation ' || i.investigation_id || ' opened'
              WHEN rc.case_id IS NOT NULL THEN 'Aurelia Global Bank - review case ' || rc.case_id || ' (' || rc.request_type || ')'
              ELSE 'Aurelia Global Bank confirmation - not sent' END,
         CASE WHEN i.investigation_id IS NOT NULL THEN
           'Dear ' || c.legal_name || ' team,' || chr(10) || chr(10)
           || 'We have opened investigation ' || i.investigation_id || ' on payment ' || i.payment_ref
           || ' (reason ' || i.reason_code || ').' || chr(10)
           || 'The agent bank is expected to respond by ' || to_char(i.est_response_date,'YYYY-MM-DD') || '.' || chr(10) || chr(10)
           || 'Thank you for banking with Aurelia Global Bank.'
              WHEN rc.case_id IS NOT NULL THEN
           'Dear ' || c.legal_name || ' team,' || chr(10) || chr(10)
           || 'We have opened review case ' || rc.case_id || ' (' || rc.request_type || ') with ' || rc.assigned_team
           || coalesce(' regarding payment ' || rc.payment_ref, '') || '.' || chr(10)
           || CASE WHEN rc.request_type = 'RECALL'
                   THEN 'A recall is a request a person decides; funds are not reversed automatically and the outcome is not guaranteed.' || chr(10)
                   ELSE '' END
           || 'A person on that team will review and reply.' || chr(10) || chr(10)
           || 'Thank you for banking with Aurelia Global Bank.'
              ELSE 'No confirmation email was sent for reference ' || upper(trim(coalesce(p_reference,''))) || '.' END
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN clients c ON c.client_id = sc.client_id
    LEFT JOIN investigations i ON i.investigation_id = upper(trim(coalesce(p_reference,''))) AND i.client_id = sc.client_id
    LEFT JOIN review_cases rc ON rc.case_id = upper(trim(coalesce(p_reference,''))) AND rc.client_id = sc.client_id;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change. Cannot be bypassed
-- by the LLM because they fire in the database, not the app. (TRACE_OPENED / RECALL_SUBMITTED /
-- REVIEW_CASE_OPENED are written by the apply triggers above.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (NEW.client_id, 'VERIFY', NEW.client_id, 'session issued, expires ' || to_char(NEW.expires_at,'YYYY-MM-DD HH24:MI'));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON client_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_proposal() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (NEW.client_id,
            CASE NEW.action_type WHEN 'TRACE' THEN 'TRACE_PROPOSED' ELSE 'RECALL_PROPOSED' END,
            NEW.action_id, NEW.payment_ref || ' reason ' || NEW.reason_code);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_proposal AFTER INSERT ON pending_actions FOR EACH ROW EXECUTE FUNCTION audit_proposal();

\ir seed_data.sql
