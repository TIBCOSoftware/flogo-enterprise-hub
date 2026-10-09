-- Kestrel Bank Retail Banking Assistant (GOVERNED) - schema, business rules and demo data.
-- Load:  createdb banking_governed  &&  psql -d banking_governed -f database.sql
--
-- =====================================================================
-- Retail Banking Assistant - Governed Agentic AI
-- The rules live HERE, not in any prompt:
--   * session_customer()     identity: every read/write is scoped by a session token (customer id + passcode)
--   * verify_and_record()    5 wrong passcodes in 15 minutes -> LOCKED, no token even with the right code
--   * card_block_eval()      card-block eligibility (ownership, not already blocked, not expired, valid reason)
--   * dispute_eval()         dispute eligibility, provisional credit, fraud review and decision date - ARITHMETIC
--   * trg_card_block_apply   a confirmed block sets the card BLOCKED and orders the replacement atomically
--   * trg_dispute_apply      a filed dispute posts the provisional credit and opens the FRAUD_REVIEW case atomically
--   * lookup_merchant()      descriptor decoding for the A2A agent - NO customer identity
--   * service_teams          human-owned requests (fee refund, hardship, limit increase...) routed by a table
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The one genuinely semantic step is the A2A dispute_triage_agent matching the customer's words to a
-- transaction and decoding who the merchant really is.
-- Kestrel Bank, its customers, accounts and merchants are fictional.
-- =====================================================================

DROP TABLE IF EXISTS agent_audit, service_cases, service_teams, disputes, card_replacements, card_blocks,
  pending_actions, verify_attempts, customer_sessions, merchant_directory, branches, loans, transactions,
  cards, accounts, customers CASCADE;
DROP SEQUENCE IF EXISTS txn_seq, blk_seq, dsp_seq, case_seq;

-- Demo stand-in for a salted passcode hash (production: OIDC/OAuth on the MCP trigger, or bcrypt).
CREATE OR REPLACE FUNCTION passcode_hash(p_customer TEXT, p_code TEXT) RETURNS TEXT AS $$
  SELECT encode(sha256(convert_to(upper(trim(coalesce(p_customer,''))) || ':' || trim(coalesce(p_code,'')), 'UTF8')), 'hex')
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

CREATE TABLE customers (
  customer_id    VARCHAR(20) PRIMARY KEY,           -- CUST-2026-NNNNN (the login id)
  first_name     VARCHAR(50) NOT NULL,
  last_name      VARCHAR(50) NOT NULL,
  phone          VARCHAR(30),
  email          VARCHAR(100) NOT NULL,
  passcode_hash  TEXT NOT NULL,                     -- passcode_hash(customer_id, 6-digit passcode)
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE accounts (
  account_id             VARCHAR(20) PRIMARY KEY,   -- ACC-NNNN
  customer_id            VARCHAR(20) NOT NULL REFERENCES customers,
  account_number_masked  VARCHAR(20) NOT NULL,
  account_type           VARCHAR(10) NOT NULL CHECK (account_type IN ('CHECKING','SAVINGS','CREDIT')),
  balance                NUMERIC(12,2) NOT NULL DEFAULT 0,   -- CREDIT: negative = amount owed
  available_balance      NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency               VARCHAR(3) NOT NULL DEFAULT 'USD',
  status                 VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED'))
);

CREATE TABLE cards (
  card_id             VARCHAR(20) PRIMARY KEY,      -- CARD-NNNN
  customer_id         VARCHAR(20) NOT NULL REFERENCES customers,
  account_id          VARCHAR(20) NOT NULL REFERENCES accounts,
  last4               VARCHAR(4) NOT NULL,
  card_number_masked  VARCHAR(25) NOT NULL,
  card_type           VARCHAR(10) NOT NULL CHECK (card_type IN ('DEBIT','CREDIT')),
  network             VARCHAR(20) NOT NULL,
  status              VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','BLOCKED','EXPIRED')),
  expiry              DATE NOT NULL,
  credit_limit        NUMERIC(12,2)
);

CREATE SEQUENCE txn_seq START 60001;   -- system-generated transactions (provisional credits); seed uses TXN-5xxxx
CREATE TABLE transactions (
  transaction_id  VARCHAR(20) PRIMARY KEY DEFAULT 'TXN-' || nextval('txn_seq')::text,
  account_id      VARCHAR(20) NOT NULL REFERENCES accounts,
  customer_id     VARCHAR(20) NOT NULL REFERENCES customers,
  card_id         VARCHAR(20) REFERENCES cards,
  txn_date        DATE NOT NULL,
  descriptor      VARCHAR(80) NOT NULL,             -- exactly as printed on the statement
  amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  txn_type        VARCHAR(6) NOT NULL CHECK (txn_type IN ('DEBIT','CREDIT')),
  category        VARCHAR(30),
  status          VARCHAR(8) NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','PENDING'))
);
ALTER SEQUENCE txn_seq OWNED BY transactions.transaction_id;

CREATE TABLE loans (
  loan_id              VARCHAR(20) PRIMARY KEY,     -- LOAN-NNNN
  customer_id          VARCHAR(20) NOT NULL REFERENCES customers,
  loan_type            VARCHAR(10) NOT NULL CHECK (loan_type IN ('HOME','AUTO','PERSONAL')),
  principal            NUMERIC(12,2) NOT NULL,
  outstanding_balance  NUMERIC(12,2) NOT NULL,
  interest_rate        NUMERIC(5,2) NOT NULL,
  monthly_payment      NUMERIC(12,2) NOT NULL,
  next_due_date        DATE NOT NULL,
  status               VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAID_OFF','DELINQUENT'))
);

CREATE TABLE branches (
  branch_id    VARCHAR(10) PRIMARY KEY,
  branch_name  VARCHAR(60) NOT NULL,
  address      VARCHAR(100) NOT NULL,
  city         VARCHAR(50) NOT NULL,
  state        VARCHAR(2) NOT NULL,
  zip          VARCHAR(10) NOT NULL,
  phone        VARCHAR(30) NOT NULL,
  hours        VARCHAR(60) NOT NULL
);

-- Read by the A2A dispute_triage_agent only (lookup_merchant). Contains no customer data.
CREATE TABLE merchant_directory (
  descriptor_prefix  VARCHAR(30) PRIMARY KEY,       -- how the merchant appears on a statement
  merchant_name      VARCHAR(60) NOT NULL,
  category           VARCHAR(60) NOT NULL,
  billing_model      VARCHAR(10) NOT NULL CHECK (billing_model IN ('ONE_OFF','RECURRING')),
  support_contact    VARCHAR(80),
  notes              TEXT
);

CREATE TABLE customer_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  customer_id    VARCHAR(20) NOT NULL REFERENCES customers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes'
);

-- Brute-force throttle for the passcode step: one row per attempt on a REAL customer id.
CREATE TABLE verify_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  customer_id  VARCHAR(20) NOT NULL REFERENCES customers,
  ok           BOOLEAN NOT NULL,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pending_actions (
  action_id            TEXT PRIMARY KEY DEFAULT 'ACT-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  action_type          VARCHAR(12) NOT NULL CHECK (action_type IN ('CARD_BLOCK','DISPUTE')),
  customer_id          VARCHAR(20) NOT NULL REFERENCES customers,
  card_id              VARCHAR(20) REFERENCES cards,
  transaction_id       VARCHAR(20) REFERENCES transactions,
  reason_code          VARCHAR(24) NOT NULL,
  customer_statement   TEXT,
  amount               NUMERIC(12,2),                -- dispute quote, frozen at proposal time
  provisional_credit   NUMERIC(12,2),
  fraud_review         BOOLEAN,
  status               VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','EXECUTED')),
  confirm_count        INTEGER NOT NULL DEFAULT 0,   -- confirm calls seen (distinguishes EXECUTED vs ALREADY_EXECUTED)
  executed_confirm_no  INTEGER,                      -- which confirm call executed it
  created_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

CREATE SEQUENCE blk_seq START 1;
CREATE TABLE card_blocks (
  block_id    VARCHAR(12) PRIMARY KEY DEFAULT 'BLK-' || lpad(nextval('blk_seq')::text, 5, '0'),
  action_id   TEXT UNIQUE NOT NULL REFERENCES pending_actions,
  card_id     VARCHAR(20) NOT NULL REFERENCES cards,
  reason      VARCHAR(24) NOT NULL,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE blk_seq OWNED BY card_blocks.block_id;

CREATE TABLE card_replacements (
  replacement_id     SERIAL PRIMARY KEY,
  card_id            VARCHAR(20) NOT NULL REFERENCES cards,
  block_id           VARCHAR(12) REFERENCES card_blocks,
  ordered_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expected_delivery  DATE NOT NULL
);

CREATE SEQUENCE dsp_seq START 2;       -- DSP-2026-0001 is seeded; filed disputes continue at 0002
CREATE TABLE disputes (
  dispute_id          VARCHAR(16) PRIMARY KEY DEFAULT 'DSP-2026-' || lpad(nextval('dsp_seq')::text, 4, '0'),
  action_id           TEXT UNIQUE REFERENCES pending_actions,   -- NULL only for seeded history
  customer_id         VARCHAR(20) NOT NULL REFERENCES customers,
  transaction_id      VARCHAR(20) NOT NULL REFERENCES transactions,
  reason_code         VARCHAR(24) NOT NULL,
  customer_statement  TEXT,
  amount              NUMERIC(12,2) NOT NULL,
  provisional_credit  NUMERIC(12,2) NOT NULL DEFAULT 0,
  fraud_review        BOOLEAN NOT NULL DEFAULT FALSE,
  status              VARCHAR(14) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','UNDER_REVIEW','RESOLVED')),
  est_decision_date   DATE NOT NULL,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE dsp_seq OWNED BY disputes.dispute_id;
-- Defence in depth: never two live disputes on one transaction.
CREATE UNIQUE INDEX disputes_one_live_per_txn ON disputes (transaction_id) WHERE status IN ('OPEN','UNDER_REVIEW');

CREATE TABLE service_teams (
  request_type         VARCHAR(24) PRIMARY KEY,
  team                 VARCHAR(60) NOT NULL,
  reply_business_days  INTEGER NOT NULL
);

CREATE SEQUENCE case_seq START 1;
CREATE TABLE service_cases (
  case_id             VARCHAR(12) PRIMARY KEY DEFAULT 'CASE-' || lpad(nextval('case_seq')::text, 5, '0'),
  customer_id         VARCHAR(20) NOT NULL REFERENCES customers,
  request_type        VARCHAR(24) NOT NULL REFERENCES service_teams,
  customer_statement  TEXT NOT NULL,
  agent_brief         TEXT NOT NULL,            -- neutral summary written by the assistant (or the system); never a decision
  assigned_team       VARCHAR(60) NOT NULL,
  dispute_id          VARCHAR(16) REFERENCES disputes,   -- set for FRAUD_REVIEW cases opened by trg_dispute_apply
  status              VARCHAR(12) NOT NULL DEFAULT 'OPEN',
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE case_seq OWNED BY service_cases.case_id;

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; no MCP tool exposes it.
CREATE TABLE agent_audit (
  id           SERIAL PRIMARY KEY,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  customer_id  VARCHAR(20),
  action       VARCHAR(30) NOT NULL,   -- VERIFY, CARD_BLOCK_PROPOSED, CARD_BLOCKED, DISPUTE_PROPOSED, DISPUTE_FILED, SERVICE_CASE_OPENED
  ref          TEXT,
  detail       TEXT
);

-- =====================================================================
-- RULES
-- =====================================================================

-- Identity: a token is valid for its customer until it expires. ALWAYS returns exactly one row -
-- the customer when valid, or (null,null) when not - so dependent reads can emit SESSION_INVALID.
-- plpgsql (NOT sql) on purpose: an inlinable SQL function here merges into the caller's LEFT JOINs
-- and can mis-bind rows. plpgsql is opaque to the planner, so callers see a clean one-row relation.
CREATE OR REPLACE FUNCTION session_customer(p_token TEXT)
RETURNS TABLE (customer_id TEXT, customer_name TEXT) AS $$
BEGIN
  RETURN QUERY
    SELECT c.customer_id::text, (c.first_name || ' ' || c.last_name)::text
      FROM (SELECT 1) one
      LEFT JOIN customer_sessions s ON s.session_token = p_token AND s.expires_at > clock_timestamp()
      LEFT JOIN customers c ON c.customer_id = s.customer_id;
END $$ LANGUAGE plpgsql STABLE;

-- Lockout rule: 5 failed passcodes within 15 minutes (since the last success) -> locked.
CREATE OR REPLACE FUNCTION customer_locked_until(p_customer TEXT) RETURNS TIMESTAMP AS $$
  SELECT CASE WHEN count(*) >= 5 THEN min(f.at) + INTERVAL '15 minutes' END
    FROM (SELECT va.at FROM verify_attempts va
           WHERE va.customer_id = upper(trim(coalesce(p_customer,''))) AND NOT va.ok
             AND va.at > clock_timestamp() - INTERVAL '15 minutes'
             AND va.at > coalesce((SELECT max(v2.at) FROM verify_attempts v2
                                    WHERE v2.customer_id = va.customer_id AND v2.ok), '-infinity'::timestamp)
           ORDER BY va.at DESC LIMIT 5) f;
$$ LANGUAGE sql STABLE;

-- Throttle: record a verify attempt and return the customer_id ONLY on a correct, non-locked attempt.
-- Side-effecting (VOLATILE). Used inside the verify tool's INSERT ... SELECT, so a session is created
-- only when it returns a row.
CREATE OR REPLACE FUNCTION verify_and_record(p_customer TEXT, p_code TEXT)
RETURNS TABLE (customer_id TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT := upper(trim(coalesce(p_customer,''))); c customers;
BEGIN
  IF customer_locked_until(v_cid) IS NOT NULL THEN
    RETURN;                                            -- locked: no session, even if the passcode is right
  END IF;
  SELECT * INTO c FROM customers cu WHERE cu.customer_id = v_cid;
  IF NOT FOUND THEN RETURN; END IF;                    -- unknown ids are not tracked (bounds the table)
  IF c.passcode_hash = passcode_hash(v_cid, p_code) THEN
    INSERT INTO verify_attempts (customer_id, ok) VALUES (v_cid, TRUE);
    RETURN QUERY SELECT c.customer_id::text; RETURN;
  END IF;
  INSERT INTO verify_attempts (customer_id, ok) VALUES (v_cid, FALSE);
  RETURN;                                              -- no session
END $$ LANGUAGE plpgsql VOLATILE;

-- Verify: customer id + 6-digit passcode -> VERIFIED + token, LOCKED after too many wrong codes, else NOT_VERIFIED.
CREATE OR REPLACE FUNCTION verify_result(p_customer TEXT, p_code TEXT)
RETURNS TABLE (status TEXT, reason TEXT, session_token TEXT, customer_name TEXT, customer_id TEXT, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN lk.until IS NOT NULL THEN 'LOCKED' WHEN s.session_token IS NULL THEN 'NOT_VERIFIED' ELSE 'VERIFIED' END,
         CASE WHEN lk.until IS NOT NULL THEN 'LOCKED: too many failed attempts. Verification is locked until '
                                             || to_char(lk.until, 'HH24:MI') || '. The customer can retry then or call Kestrel Bank.'
              WHEN s.session_token IS NULL THEN 'NOT_VERIFIED: the customer id and passcode do not match. Nothing is revealed about which one is wrong.'
              ELSE 'VERIFIED: session valid for 30 minutes.' END,
         CASE WHEN lk.until IS NULL THEN s.session_token END,
         CASE WHEN lk.until IS NULL THEN s.customer_name END,
         upper(trim(coalesce(p_customer,''))),
         CASE WHEN lk.until IS NULL THEN s.expires_at END
    FROM (SELECT customer_locked_until(p_customer) AS until) lk
    LEFT JOIN LATERAL (
      SELECT se.session_token, (c.first_name || ' ' || c.last_name) AS customer_name, se.expires_at
        FROM customers c
        JOIN customer_sessions se ON se.customer_id = c.customer_id AND se.expires_at > clock_timestamp()
       WHERE c.customer_id = upper(trim(coalesce(p_customer,''))) AND c.passcode_hash = passcode_hash(p_customer, p_code)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Scoped reads: only the caller's rows; one SESSION_INVALID row for a bad token.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_accounts(p_token TEXT)
RETURNS TABLE (session_status TEXT, customer_name TEXT, account_id VARCHAR, account_number_masked VARCHAR,
               account_type VARCHAR, balance NUMERIC, available_balance NUMERIC, currency VARCHAR, status VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END, sc.customer_name,
         a.account_id, a.account_number_masked, a.account_type, a.balance, a.available_balance, a.currency, a.status
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN accounts a ON a.customer_id = sc.customer_id
   ORDER BY a.account_id;
$$ LANGUAGE sql STABLE;

-- Transactions: empty search = everything in the last 120 days; a search term (descriptor/category text,
-- an amount like 249.99, or a TXN- id) looks back 13 months so an old charge is still found and
-- propose_dispute can explain OUTSIDE_WINDOW. Newest first, max 25. NO_MATCH when nothing matches.
CREATE OR REPLACE FUNCTION my_transactions(p_token TEXT, p_search TEXT)
RETURNS TABLE (session_status TEXT, transaction_id VARCHAR, txn_date DATE, descriptor VARCHAR, amount NUMERIC,
               txn_type VARCHAR, category VARCHAR, status VARCHAR, account_id VARCHAR, card_last4 VARCHAR,
               open_dispute_id VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' WHEN t.transaction_id IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         t.transaction_id, t.txn_date, t.descriptor, t.amount, t.txn_type, t.category, t.status, t.account_id,
         t.last4, t.dispute_id
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT x.transaction_id, x.txn_date, x.descriptor, x.amount, x.txn_type, x.category, x.status, x.account_id,
             k.last4, d.dispute_id
        FROM transactions x
        LEFT JOIN cards k ON k.card_id = x.card_id
        LEFT JOIN disputes d ON d.transaction_id = x.transaction_id AND d.status IN ('OPEN','UNDER_REVIEW')
        CROSS JOIN (SELECT upper(trim(coalesce(p_search,''))) AS q) s
       WHERE x.customer_id = sc.customer_id
         AND CASE WHEN s.q = '' THEN x.txn_date >= current_date - 120
                  ELSE x.txn_date >= current_date - 395
                       AND (position(s.q IN upper(x.descriptor)) > 0
                            OR position(s.q IN upper(coalesce(x.category,''))) > 0
                            OR x.transaction_id = s.q
                            OR (replace(s.q,'$','') ~ '^[0-9]+(\.[0-9]{1,2})?$'
                                AND x.amount = replace(s.q,'$','')::numeric)) END
       ORDER BY x.txn_date DESC, x.transaction_id DESC
       LIMIT 25) t ON sc.customer_id IS NOT NULL
   ORDER BY t.txn_date DESC, t.transaction_id DESC;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_cards(p_token TEXT)
RETURNS TABLE (session_status TEXT, card_id VARCHAR, last4 VARCHAR, card_number_masked VARCHAR, card_type VARCHAR,
               network VARCHAR, status VARCHAR, expiry DATE, credit_limit NUMERIC, account_id VARCHAR,
               replacement_expected_delivery DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         k.card_id, k.last4, k.card_number_masked, k.card_type, k.network,
         CASE WHEN k.status = 'ACTIVE' AND k.expiry < current_date THEN 'EXPIRED' ELSE k.status END::varchar,
         k.expiry, k.credit_limit, k.account_id, r.expected_delivery
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN cards k ON k.customer_id = sc.customer_id
    LEFT JOIN LATERAL (SELECT cr.expected_delivery FROM card_replacements cr
                        WHERE cr.card_id = k.card_id ORDER BY cr.ordered_at DESC LIMIT 1) r ON TRUE
   ORDER BY k.card_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_loans(p_token TEXT)
RETURNS TABLE (session_status TEXT, loan_id VARCHAR, loan_type VARCHAR, principal NUMERIC, outstanding_balance NUMERIC,
               interest_rate NUMERIC, monthly_payment NUMERIC, next_due_date DATE, status VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         l.loan_id, l.loan_type, l.principal, l.outstanding_balance, l.interest_rate, l.monthly_payment,
         l.next_due_date, l.status
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN loans l ON l.customer_id = sc.customer_id
   ORDER BY l.loan_id;
$$ LANGUAGE sql STABLE;

-- Public data: no session token. Empty city = all branches.
CREATE OR REPLACE FUNCTION find_branch(p_city TEXT)
RETURNS TABLE (lookup_status TEXT, branch_id VARCHAR, branch_name VARCHAR, address VARCHAR, city VARCHAR,
               state VARCHAR, zip VARCHAR, phone VARCHAR, hours VARCHAR) AS $$
  SELECT CASE WHEN b.branch_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         b.branch_id, b.branch_name, b.address, b.city, b.state, b.zip, b.phone, b.hours
    FROM (SELECT upper(trim(coalesce(p_city,''))) AS q) s
    LEFT JOIN branches b ON s.q = '' OR position(s.q IN upper(b.city)) > 0
                         OR position(s.q IN upper(b.branch_name)) > 0 OR b.zip = s.q OR upper(b.state) = s.q
   ORDER BY b.branch_id;
$$ LANGUAGE sql STABLE;

-- Agent tool: decode a statement descriptor. NO customer identity is passed in or returned.
CREATE OR REPLACE FUNCTION lookup_merchant(p_descriptor TEXT)
RETURNS TABLE (match_type TEXT, descriptor_prefix VARCHAR, merchant_name VARCHAR, category VARCHAR,
               billing_model VARCHAR, support_contact VARCHAR, notes TEXT) AS $$
  WITH q AS (SELECT upper(regexp_replace(trim(coalesce(p_descriptor,'')), '\s+', ' ', 'g')) AS d),
  m AS (
    SELECT CASE WHEN q.d <> '' AND position(upper(md.descriptor_prefix) IN q.d) = 1 THEN 'PREFIX_MATCH'
                WHEN length(q.d) >= 3 AND position(q.d IN upper(md.descriptor_prefix)) = 1 THEN 'PARTIAL_MATCH'
                WHEN length(q.d) >= 3 AND (position(q.d IN upper(md.merchant_name)) > 0
                                           OR position(q.d IN upper(md.category)) > 0) THEN 'KEYWORD_MATCH' END AS mt,
           md.descriptor_prefix, md.merchant_name, md.category, md.billing_model, md.support_contact, md.notes
      FROM merchant_directory md CROSS JOIN q),
  hits AS (
    SELECT m.*, CASE m.mt WHEN 'PREFIX_MATCH' THEN 1 WHEN 'PARTIAL_MATCH' THEN 2 ELSE 3 END AS rnk
      FROM m WHERE m.mt IS NOT NULL
     ORDER BY rnk, length(m.descriptor_prefix) DESC LIMIT 5)
  SELECT coalesce(h.mt, 'NO_MATCH'), h.descriptor_prefix, h.merchant_name, h.category, h.billing_model,
         h.support_contact, h.notes
    FROM (SELECT 1) one LEFT JOIN hits h ON TRUE
   ORDER BY h.rnk, length(h.descriptor_prefix) DESC;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Card block (two-step)
-- ---------------------------------------------------------------------

-- Resolve a card of THIS customer from a card_id (CARD-9001) or the last 4 digits (1123, "ending 1123", "**1123").
CREATE OR REPLACE FUNCTION find_my_card(p_customer TEXT, p_card TEXT) RETURNS SETOF cards AS $$
  SELECT k.* FROM cards k
   WHERE k.customer_id = p_customer
     AND (k.card_id = upper(trim(coalesce(p_card,'')))
          OR (upper(trim(coalesce(p_card,''))) NOT LIKE 'CARD%'
              AND regexp_replace(coalesce(p_card,''), '\D', '', 'g') ~ '^[0-9]{4}$'
              AND k.last4 = regexp_replace(coalesce(p_card,''), '\D', '', 'g')))
   ORDER BY k.card_id LIMIT 1;
$$ LANGUAGE sql STABLE;

-- Rule: may this customer block this card for this reason? ok + a reason code to explain verbatim.
CREATE OR REPLACE FUNCTION card_block_eval(p_token TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, card_id TEXT, last4 TEXT, card_type TEXT, block_reason TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; k cards;
        v_reason TEXT := upper(regexp_replace(trim(coalesce(p_reason,'')), '[\s-]+', '_', 'g'));
BEGIN
  ok := FALSE; block_reason := v_reason;
  SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO k FROM find_my_card(v_cid, p_card);
  IF k.card_id IS NULL THEN
    reason_code := 'CARD_NOT_FOUND';
    reason := 'CARD_NOT_FOUND: no card of this customer matches ' || coalesce(nullif(trim(p_card),''),'(blank)') || '. Use get_my_cards.';
    RETURN NEXT; RETURN;
  END IF;
  card_id := k.card_id; last4 := k.last4; card_type := k.card_type;
  IF k.status = 'BLOCKED' THEN
    reason_code := 'ALREADY_BLOCKED'; reason := 'ALREADY_BLOCKED: the card ending ' || k.last4 || ' is already blocked.';
    RETURN NEXT; RETURN;
  END IF;
  IF k.status = 'EXPIRED' OR k.expiry < current_date THEN
    reason_code := 'CARD_EXPIRED';
    reason := 'CARD_EXPIRED: the card ending ' || k.last4 || ' expired on ' || to_char(k.expiry, 'YYYY-MM-DD') || ' and cannot be used, so it does not need blocking.';
    RETURN NEXT; RETURN;
  END IF;
  IF v_reason NOT IN ('LOST','STOLEN','DAMAGED','SUSPECTED_FRAUD') THEN
    reason_code := 'BAD_REASON'; reason := 'BAD_REASON: the reason must be LOST, STOLEN, DAMAGED or SUSPECTED_FRAUD.';
    RETURN NEXT; RETURN;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE'; reason := 'ELIGIBLE';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write row: a pending card block is written ONLY when every rule passes (and not twice).
CREATE OR REPLACE FUNCTION card_block_proposal_row(p_token TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (action_type TEXT, customer_id TEXT, card_id TEXT, reason_code TEXT) AS $$
  SELECT 'CARD_BLOCK', sc.customer_id, e.card_id, e.block_reason
    FROM session_customer(p_token) sc
    CROSS JOIN LATERAL card_block_eval(p_token, p_card, p_reason) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.customer_id = sc.customer_id AND pa.action_type = 'CARD_BLOCK'
                        AND pa.card_id = e.card_id AND pa.reason_code = e.block_reason
                        AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_card_block_result(p_token TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, card_id TEXT, last4 TEXT, card_type TEXT,
               block_reason TEXT, replacement_expected_delivery DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; pa pending_actions; v_cid TEXT;
BEGIN
  SELECT * INTO e FROM card_block_eval(p_token, p_card, p_reason);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  card_id := e.card_id; last4 := e.last4; card_type := e.card_type; block_reason := e.block_reason;
  IF e.ok THEN
    SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
    SELECT * INTO pa FROM pending_actions p
     WHERE p.customer_id = v_cid AND p.action_type = 'CARD_BLOCK' AND p.card_id = e.card_id
       AND p.reason_code = e.block_reason AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
     ORDER BY p.created_at DESC LIMIT 1;
    IF FOUND THEN
      outcome := 'PROPOSED'; reason_code := 'PROPOSED';
      reason := 'Awaiting the customer''s explicit yes. Nothing has changed yet. On confirm the card ending ' || e.last4
                || ' is blocked immediately and a replacement is ordered.';
      action_id := pa.action_id; expires_at := pa.expires_at;
      replacement_expected_delivery := add_business_days(current_date, 5);
    ELSE
      reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the proposal could not be recorded. Try again.';
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Confirm row: VOLATILE because it counts confirm calls (so a repeat confirm reads ALREADY_EXECUTED).
-- Returns the card_blocks row ONLY for this customer's PENDING, unexpired CARD_BLOCK whose rules still pass.
CREATE OR REPLACE FUNCTION card_block_confirmation_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, card_id TEXT, reason TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; e RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.customer_id = v_cid AND p.action_type = 'CARD_BLOCK';
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE pending_actions p SET confirm_count = p.confirm_count + 1 WHERE p.action_id = pa.action_id;
  IF pa.status <> 'PENDING' OR pa.expires_at <= clock_timestamp() THEN RETURN; END IF;
  SELECT * INTO e FROM card_block_eval(p_token, pa.card_id, pa.reason_code);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT pa.action_id::text, pa.card_id::text, pa.reason_code::text;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_card_block_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, block_id TEXT, card_id TEXT, last4 TEXT, block_reason TEXT,
               card_status TEXT, replacement_expected_delivery DATE, blocked_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; b card_blocks; k cards; e RECORD; v_delivery DATE;
BEGIN
  outcome := 'NOT_EXECUTED';
  SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.customer_id = v_cid AND p.action_type = 'CARD_BLOCK';
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_PROPOSAL'; reason := 'NO_SUCH_PROPOSAL: no card-block proposal with that id for this customer. Call propose_card_block first.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO k FROM cards c WHERE c.card_id = pa.card_id;
  card_id := k.card_id; last4 := k.last4; block_reason := pa.reason_code; card_status := k.status;
  SELECT * INTO b FROM card_blocks cb WHERE cb.action_id = pa.action_id;
  IF FOUND THEN
    SELECT cr.expected_delivery INTO v_delivery FROM card_replacements cr WHERE cr.block_id = b.block_id
     ORDER BY cr.ordered_at DESC LIMIT 1;
    block_id := b.block_id; blocked_at := b.created_at; replacement_expected_delivery := v_delivery;
    IF pa.executed_confirm_no = pa.confirm_count THEN
      outcome := 'EXECUTED'; reason_code := 'EXECUTED';
      reason := 'Card blocked. A replacement card has been ordered.';
    ELSE
      reason_code := 'ALREADY_EXECUTED';
      reason := 'ALREADY_EXECUTED: this block was already carried out as ' || b.block_id || '. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the proposal expired after 15 minutes. Propose the card block again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO e FROM card_block_eval(p_token, pa.card_id, pa.reason_code);
  reason_code := e.reason_code; reason := e.reason;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Side effect: a confirmed block sets the card BLOCKED and orders the replacement, atomically.
CREATE OR REPLACE FUNCTION apply_card_block() RETURNS TRIGGER AS $$
BEGIN
  UPDATE cards SET status = 'BLOCKED' WHERE card_id = NEW.card_id;
  INSERT INTO card_replacements (card_id, block_id, expected_delivery)
    VALUES (NEW.card_id, NEW.block_id, add_business_days(current_date, 5));
  UPDATE pending_actions SET status = 'EXECUTED', executed_confirm_no = confirm_count WHERE action_id = NEW.action_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_card_block_apply AFTER INSERT ON card_blocks FOR EACH ROW EXECUTE FUNCTION apply_card_block();

-- ---------------------------------------------------------------------
-- Disputes (two-step)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION norm_dispute_reason(p_reason TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN r = 'UNRECOGNIZED' THEN 'UNRECOGNISED' ELSE r END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p_reason,'')), '[\s-]+', '_', 'g')) AS r) x;
$$ LANGUAGE sql IMMUTABLE;

-- Rule: may this customer dispute this transaction for this reason? Also computes the quote:
-- provisional credit (= amount for UNRECOGNISED/FRAUD/NOT_RECEIVED/DUPLICATE up to $500.00, else 0),
-- fraud review (UNRECOGNISED/FRAUD or amount > $1,000) and the decision date (+10 business days).
CREATE OR REPLACE FUNCTION dispute_eval(p_token TEXT, p_txn TEXT, p_reason TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, transaction_id TEXT, account_id TEXT, descriptor TEXT,
               txn_date DATE, amount NUMERIC, dispute_reason TEXT, provisional_credit NUMERIC, fraud_review BOOLEAN,
               est_decision_date DATE) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; t transactions; v_reason TEXT := norm_dispute_reason(p_reason); v_dsp TEXT; v_dup TEXT;
BEGIN
  ok := FALSE; dispute_reason := v_reason;
  SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO t FROM transactions x WHERE x.transaction_id = upper(trim(coalesce(p_txn,''))) AND x.customer_id = v_cid;
  IF NOT FOUND THEN
    reason_code := 'NOT_YOUR_TRANSACTION';
    reason := 'NOT_YOUR_TRANSACTION: no transaction ' || coalesce(nullif(trim(p_txn),''),'(blank)') || ' on this customer''s accounts. Use get_my_transactions.';
    RETURN NEXT; RETURN;
  END IF;
  transaction_id := t.transaction_id; account_id := t.account_id; descriptor := t.descriptor;
  txn_date := t.txn_date; amount := t.amount;
  IF t.txn_type <> 'DEBIT' THEN
    reason_code := 'NOT_A_DEBIT'; reason := 'NOT_A_DEBIT: ' || t.transaction_id || ' is a credit to the account, not a charge, so it cannot be disputed.';
    RETURN NEXT; RETURN;
  END IF;
  IF t.status <> 'POSTED' THEN
    reason_code := 'PENDING_NOT_POSTED';
    reason := 'PENDING_NOT_POSTED: ' || t.transaction_id || ' is still pending. A charge can be disputed once it has posted (usually 1-3 business days).';
    RETURN NEXT; RETURN;
  END IF;
  IF t.txn_date < current_date - 120 THEN
    reason_code := 'OUTSIDE_WINDOW';
    reason := 'OUTSIDE_WINDOW: ' || t.transaction_id || ' is dated ' || to_char(t.txn_date,'YYYY-MM-DD')
              || '; card disputes must be raised within 120 days of the transaction date.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT d.dispute_id INTO v_dsp FROM disputes d
   WHERE d.transaction_id = t.transaction_id AND d.status IN ('OPEN','UNDER_REVIEW') LIMIT 1;
  IF v_dsp IS NOT NULL THEN
    reason_code := 'ALREADY_DISPUTED'; reason := 'ALREADY_DISPUTED: ' || t.transaction_id || ' already has an open dispute, ' || v_dsp || '.';
    RETURN NEXT; RETURN;
  END IF;
  IF v_reason NOT IN ('UNRECOGNISED','FRAUD','DUPLICATE','NOT_RECEIVED','NOT_AS_DESCRIBED','CANCELLED_RECURRING','WRONG_AMOUNT') THEN
    reason_code := 'BAD_REASON';
    reason := 'BAD_REASON: the reason code must be UNRECOGNISED, FRAUD, DUPLICATE, NOT_RECEIVED, NOT_AS_DESCRIBED, CANCELLED_RECURRING or WRONG_AMOUNT.';
    RETURN NEXT; RETURN;
  END IF;
  IF v_reason = 'DUPLICATE' THEN
    SELECT o.transaction_id INTO v_dup FROM transactions o
     WHERE o.customer_id = v_cid AND o.transaction_id <> t.transaction_id AND o.txn_type = 'DEBIT' AND o.status = 'POSTED'
       AND upper(trim(o.descriptor)) = upper(trim(t.descriptor)) AND o.amount = t.amount
       AND abs(o.txn_date - t.txn_date) <= 3
     ORDER BY o.transaction_id LIMIT 1;
    IF v_dup IS NULL THEN
      reason_code := 'NOT_DUPLICATE';
      reason := 'NOT_DUPLICATE: there is no other posted charge from ' || t.descriptor || ' for the same amount within 3 days, so this is not a duplicate.';
      RETURN NEXT; RETURN;
    END IF;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE';
  reason := CASE WHEN v_dup IS NOT NULL THEN 'ELIGIBLE: duplicate of ' || v_dup || '.' ELSE 'ELIGIBLE' END;
  provisional_credit := CASE WHEN v_reason IN ('UNRECOGNISED','FRAUD','NOT_RECEIVED','DUPLICATE') AND t.amount <= 500.00
                             THEN t.amount ELSE 0 END;
  fraud_review := v_reason IN ('UNRECOGNISED','FRAUD') OR t.amount > 1000.00;
  est_decision_date := add_business_days(current_date, 10);
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write row: a pending dispute (with its frozen quote) is written ONLY when every rule passes.
CREATE OR REPLACE FUNCTION dispute_proposal_row(p_token TEXT, p_txn TEXT, p_reason TEXT, p_statement TEXT)
RETURNS TABLE (action_type TEXT, customer_id TEXT, transaction_id TEXT, reason_code TEXT, customer_statement TEXT,
               amount NUMERIC, provisional_credit NUMERIC, fraud_review BOOLEAN) AS $$
  SELECT 'DISPUTE', sc.customer_id, e.transaction_id, e.dispute_reason, left(coalesce(p_statement,''), 4000),
         e.amount, e.provisional_credit, e.fraud_review
    FROM session_customer(p_token) sc
    CROSS JOIN LATERAL dispute_eval(p_token, p_txn, p_reason) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.customer_id = sc.customer_id AND pa.action_type = 'DISPUTE'
                        AND pa.transaction_id = e.transaction_id AND pa.reason_code = e.dispute_reason
                        AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_dispute_result(p_token TEXT, p_txn TEXT, p_reason TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, transaction_id TEXT, descriptor TEXT,
               merchant TEXT, txn_date DATE, amount NUMERIC, dispute_reason TEXT, provisional_credit NUMERIC,
               fraud_review BOOLEAN, est_decision_date DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; pa pending_actions; v_cid TEXT;
BEGIN
  SELECT * INTO e FROM dispute_eval(p_token, p_txn, p_reason);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  transaction_id := e.transaction_id; descriptor := e.descriptor; txn_date := e.txn_date; amount := e.amount;
  dispute_reason := e.dispute_reason;
  SELECT lm.merchant_name INTO merchant FROM lookup_merchant(e.descriptor) lm WHERE lm.match_type = 'PREFIX_MATCH' LIMIT 1;
  merchant := coalesce(merchant, e.descriptor);
  IF e.ok THEN
    SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
    SELECT * INTO pa FROM pending_actions p
     WHERE p.customer_id = v_cid AND p.action_type = 'DISPUTE' AND p.transaction_id = e.transaction_id
       AND p.reason_code = e.dispute_reason AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
     ORDER BY p.created_at DESC LIMIT 1;
    IF FOUND THEN
      outcome := 'PROPOSED'; reason_code := 'PROPOSED';
      reason := 'Awaiting the customer''s explicit yes. Nothing has been filed yet. Read back the amount, provisional credit and decision date exactly as given.';
      action_id := pa.action_id; expires_at := pa.expires_at;
      provisional_credit := pa.provisional_credit; fraud_review := pa.fraud_review;
      est_decision_date := add_business_days(current_date, 10);
    ELSE
      reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the proposal could not be recorded. Try again.';
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION dispute_confirmation_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, customer_id TEXT, transaction_id TEXT, reason_code TEXT, customer_statement TEXT,
               amount NUMERIC, provisional_credit NUMERIC, fraud_review BOOLEAN, est_decision_date DATE) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; e RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.customer_id = v_cid AND p.action_type = 'DISPUTE';
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE pending_actions p SET confirm_count = p.confirm_count + 1 WHERE p.action_id = pa.action_id;
  IF pa.status <> 'PENDING' OR pa.expires_at <= clock_timestamp() THEN RETURN; END IF;
  SELECT * INTO e FROM dispute_eval(p_token, pa.transaction_id, pa.reason_code);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT pa.action_id::text, pa.customer_id::text, pa.transaction_id::text, pa.reason_code::text,
                      pa.customer_statement, pa.amount, pa.provisional_credit, pa.fraud_review,
                      add_business_days(current_date, 10);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_dispute_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, dispute_id TEXT, transaction_id TEXT, dispute_reason TEXT,
               amount NUMERIC, provisional_credit NUMERIC, provisional_credit_txn TEXT, fraud_review BOOLEAN,
               fraud_case_id TEXT, est_decision_date DATE, status TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; d disputes; e RECORD;
BEGIN
  outcome := 'NOT_FILED';
  SELECT sc.customer_id INTO v_cid FROM session_customer(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.customer_id = v_cid AND p.action_type = 'DISPUTE';
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_PROPOSAL'; reason := 'NO_SUCH_PROPOSAL: no dispute proposal with that id for this customer. Call propose_dispute first.';
    RETURN NEXT; RETURN;
  END IF;
  transaction_id := pa.transaction_id; dispute_reason := pa.reason_code; amount := pa.amount;
  SELECT * INTO d FROM disputes x WHERE x.action_id = pa.action_id;
  IF FOUND THEN
    dispute_id := d.dispute_id; provisional_credit := d.provisional_credit; fraud_review := d.fraud_review;
    est_decision_date := d.est_decision_date; status := d.status;
    SELECT x.transaction_id INTO provisional_credit_txn FROM transactions x
     WHERE x.descriptor = 'PROVISIONAL CREDIT ' || d.dispute_id LIMIT 1;
    SELECT c.case_id INTO fraud_case_id FROM service_cases c WHERE c.dispute_id = d.dispute_id AND c.request_type = 'FRAUD_REVIEW' LIMIT 1;
    IF pa.executed_confirm_no = pa.confirm_count THEN
      outcome := 'FILED'; reason_code := 'FILED';
      reason := 'Dispute filed. ' || CASE WHEN d.provisional_credit > 0
                  THEN 'A provisional credit of ' || d.provisional_credit || ' USD is pending on the account. '
                  ELSE 'No provisional credit applies. ' END
                || CASE WHEN d.fraud_review THEN 'Fraud Operations will review it. ' ELSE '' END
                || 'A decision is expected by ' || to_char(d.est_decision_date,'YYYY-MM-DD') || '.';
    ELSE
      reason_code := 'ALREADY_EXECUTED';
      reason := 'ALREADY_EXECUTED: this dispute was already filed as ' || d.dispute_id || '. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the proposal expired after 15 minutes. Propose the dispute again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO e FROM dispute_eval(p_token, pa.transaction_id, pa.reason_code);
  reason_code := e.reason_code; reason := e.reason;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Side effects of a filed dispute, atomically: provisional credit (PENDING CREDIT on the same account)
-- and the FRAUD_REVIEW human case routed to Fraud Operations.
CREATE OR REPLACE FUNCTION apply_dispute() RETURNS TRIGGER AS $$
DECLARE t transactions; tm service_teams;
BEGIN
  SELECT * INTO t FROM transactions WHERE transaction_id = NEW.transaction_id;
  IF NEW.provisional_credit > 0 THEN
    INSERT INTO transactions (account_id, customer_id, card_id, txn_date, descriptor, amount, txn_type, category, status)
      VALUES (t.account_id, NEW.customer_id, NULL, NEW.created_at::date, 'PROVISIONAL CREDIT ' || NEW.dispute_id,
              NEW.provisional_credit, 'CREDIT', 'DISPUTE_CREDIT', 'PENDING');
  END IF;
  IF NEW.fraud_review THEN
    SELECT * INTO tm FROM service_teams WHERE request_type = 'FRAUD_REVIEW';
    INSERT INTO service_cases (customer_id, request_type, customer_statement, agent_brief, assigned_team, dispute_id, created_at)
      VALUES (NEW.customer_id, 'FRAUD_REVIEW', coalesce(nullif(NEW.customer_statement,''), '(no statement)'),
              'SYSTEM: dispute ' || NEW.dispute_id || ' on ' || NEW.transaction_id || ' (' || t.descriptor || ', '
              || to_char(t.txn_date,'YYYY-MM-DD') || ') for ' || NEW.amount || ' USD, reason ' || NEW.reason_code
              || '. Auto-routed for fraud review (reason UNRECOGNISED/FRAUD or amount over 1000 USD).',
              tm.team, NEW.dispute_id, NEW.created_at);
  END IF;
  IF NEW.action_id IS NOT NULL THEN
    UPDATE pending_actions SET status = 'EXECUTED', executed_confirm_no = confirm_count WHERE action_id = NEW.action_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_dispute_apply AFTER INSERT ON disputes FOR EACH ROW EXECUTE FUNCTION apply_dispute();

-- ---------------------------------------------------------------------
-- Human-owned requests -> routed to a team by the table, never decided by the LLM.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION norm_request_type(p_type TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p_type,'')), '[\s-]+', '_', 'g'));
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION service_case_row(p_token TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT)
RETURNS TABLE (customer_id TEXT, request_type VARCHAR, customer_statement TEXT, agent_brief TEXT, assigned_team VARCHAR) AS $$
  SELECT sc.customer_id, t.request_type, left(coalesce(p_statement,''), 4000), left(coalesce(p_brief,''), 4000), t.team
    FROM (SELECT * FROM session_customer(p_token)) sc
    JOIN service_teams t ON t.request_type = norm_request_type(p_type)
   WHERE sc.customer_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM service_cases c
                      WHERE c.customer_id = sc.customer_id AND c.request_type = t.request_type
                        AND c.created_at > clock_timestamp() - INTERVAL '10 minutes');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, case_id VARCHAR, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, reply_by DATE, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED'
              WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'BAD_TYPE' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'A person on the assigned team will review and reply. The assistant has not decided or promised anything.'
              WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              ELSE 'BAD_TYPE: use FEE_REFUND, LOAN_HARDSHIP, CREDIT_LIMIT_INCREASE, COMPLAINT, PERSONAL_DETAILS_CHANGE, '
                   || 'ACCOUNT_CLOSURE, BEREAVEMENT, FRAUD_REVIEW or OTHER.' END,
         c.case_id, c.request_type, t.team, t.reply_business_days,
         add_business_days(c.created_at::date, t.reply_business_days), c.status, c.created_at
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT x.* FROM service_cases x
       WHERE x.customer_id = sc.customer_id AND x.request_type = norm_request_type(p_type)
         AND x.created_at > clock_timestamp() - INTERVAL '10 minutes'
       ORDER BY x.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The customer's disputes and service cases in one list.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_type TEXT, reference_id TEXT, topic TEXT, transaction_id TEXT,
               assigned_team TEXT, status TEXT, amount NUMERIC, provisional_credit NUMERIC, expected_by DATE,
               related_dispute_id TEXT, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_type, c.reference_id, c.topic, c.transaction_id, c.assigned_team, c.status, c.amount,
         c.provisional_credit, c.expected_by, c.related_dispute_id, c.created_at
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT 'DISPUTE'::text AS case_type, d.dispute_id::text AS reference_id, d.reason_code::text AS topic,
             d.transaction_id::text AS transaction_id, 'Card Disputes'::text AS assigned_team, d.status::text AS status,
             d.amount, d.provisional_credit, d.est_decision_date AS expected_by, NULL::text AS related_dispute_id,
             d.created_at
        FROM disputes d WHERE d.customer_id = sc.customer_id
      UNION ALL
      SELECT 'SERVICE_CASE', s.case_id, s.request_type, NULL, s.assigned_team, s.status, NULL, NULL,
             add_business_days(s.created_at::date, t.reply_business_days), s.dispute_id, s.created_at
        FROM service_cases s JOIN service_teams t ON t.request_type = s.request_type
       WHERE s.customer_id = sc.customer_id) c ON TRUE
   ORDER BY c.created_at DESC, c.reference_id DESC;
$$ LANGUAGE sql STABLE;

-- Email confirmation: validated payload for the guarded email tool. Returns SEND + subject/body ONLY when
-- the reference is a dispute (DSP-) or card block (BLK-) of THIS customer; otherwise NOT_SENT + reason.
-- The flow sends to the configured To_Email; the body never contains full card or account numbers.
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason TEXT, reference_id TEXT, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN d.dispute_id IS NOT NULL OR k.card_id IS NOT NULL THEN 'SEND' ELSE 'NOT_SENT' END,
         CASE WHEN d.dispute_id IS NOT NULL OR k.card_id IS NOT NULL THEN 'SEND'
              WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'NO_SUCH_REFERENCE' END,
         CASE WHEN d.dispute_id IS NOT NULL OR k.card_id IS NOT NULL THEN 'Confirmation email prepared.'
              WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID: verify again.'
              ELSE 'NO_SUCH_REFERENCE: no dispute (DSP-) or card block (BLK-) with that reference for this customer.' END,
         upper(trim(coalesce(p_reference,''))),
         CASE WHEN d.dispute_id IS NOT NULL THEN 'Kestrel Bank - your dispute ' || d.dispute_id || ' has been filed'
              WHEN k.card_id IS NOT NULL THEN 'Kestrel Bank - your card ending ' || k.last4 || ' is blocked (' || b.block_id || ')'
              ELSE 'Kestrel Bank confirmation - not sent' END,
         CASE WHEN d.dispute_id IS NOT NULL THEN
           'Dear ' || c.first_name || ',' || chr(10) || chr(10)
           || 'We have filed your dispute ' || d.dispute_id || ' for the transaction ' || t.descriptor
           || ' on ' || to_char(t.txn_date,'YYYY-MM-DD') || ' for ' || d.amount || ' USD (reason: ' || d.reason_code || ').' || chr(10)
           || CASE WHEN d.provisional_credit > 0
                   THEN 'A provisional credit of ' || d.provisional_credit || ' USD has been added to your account while we investigate.'
                   ELSE 'No provisional credit applies to this dispute.' END || chr(10)
           || CASE WHEN d.fraud_review THEN 'Our Fraud Operations team is also reviewing this transaction.' || chr(10) ELSE '' END
           || 'We expect to reach a decision by ' || to_char(d.est_decision_date,'YYYY-MM-DD') || '.' || chr(10) || chr(10)
           || 'Thank you for banking with Kestrel Bank.'
              WHEN k.card_id IS NOT NULL THEN
           'Dear ' || c.first_name || ',' || chr(10) || chr(10)
           || 'Your ' || k.network || ' ' || lower(k.card_type) || ' card ending ' || k.last4 || ' was blocked on '
           || to_char(b.created_at,'YYYY-MM-DD HH24:MI') || ' (reason: ' || b.reason || '), reference ' || b.block_id || '.' || chr(10)
           || 'A replacement card is on its way and should arrive by ' || coalesce(to_char(r.expected_delivery,'YYYY-MM-DD'),'(date pending)') || '.' || chr(10) || chr(10)
           || 'Thank you for banking with Kestrel Bank.'
              ELSE 'No confirmation email was sent for reference ' || upper(trim(coalesce(p_reference,''))) || '.' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN disputes d ON d.dispute_id = upper(trim(coalesce(p_reference,''))) AND d.customer_id = sc.customer_id
    LEFT JOIN transactions t ON t.transaction_id = d.transaction_id
    LEFT JOIN card_blocks b ON b.block_id = upper(trim(coalesce(p_reference,'')))
    LEFT JOIN cards k ON k.card_id = b.card_id AND k.customer_id = sc.customer_id
    LEFT JOIN LATERAL (SELECT cr.expected_delivery FROM card_replacements cr WHERE cr.block_id = b.block_id
                        ORDER BY cr.ordered_at DESC LIMIT 1) r ON TRUE;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change. Cannot be bypassed
-- by the LLM because they fire in the database, not the app.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (NEW.customer_id, 'VERIFY', NEW.customer_id, 'session issued, expires ' || to_char(NEW.expires_at,'YYYY-MM-DD HH24:MI'));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON customer_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_proposal() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (NEW.customer_id,
            CASE NEW.action_type WHEN 'CARD_BLOCK' THEN 'CARD_BLOCK_PROPOSED' ELSE 'DISPUTE_PROPOSED' END,
            NEW.action_id,
            CASE NEW.action_type WHEN 'CARD_BLOCK' THEN NEW.card_id || ' reason ' || NEW.reason_code
                 ELSE NEW.transaction_id || ' ' || NEW.reason_code || ' amount ' || NEW.amount
                      || ' provisional ' || NEW.provisional_credit || ' fraud_review ' || NEW.fraud_review END);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_proposal AFTER INSERT ON pending_actions FOR EACH ROW EXECUTE FUNCTION audit_proposal();

CREATE OR REPLACE FUNCTION audit_card_block() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    SELECT k.customer_id, 'CARD_BLOCKED', NEW.block_id, NEW.card_id || ' reason ' || NEW.reason || ' (action ' || NEW.action_id || ')'
      FROM cards k WHERE k.card_id = NEW.card_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_card_block AFTER INSERT ON card_blocks FOR EACH ROW EXECUTE FUNCTION audit_card_block();

CREATE OR REPLACE FUNCTION audit_dispute() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (NEW.customer_id, 'DISPUTE_FILED', NEW.dispute_id,
            NEW.transaction_id || ' ' || NEW.reason_code || ' amount ' || NEW.amount || ' provisional ' || NEW.provisional_credit
            || ' fraud_review ' || NEW.fraud_review || coalesce(' (action ' || NEW.action_id || ')', ' (seeded)'));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_dispute AFTER INSERT ON disputes FOR EACH ROW EXECUTE FUNCTION audit_dispute();

CREATE OR REPLACE FUNCTION audit_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (NEW.customer_id, 'SERVICE_CASE_OPENED', NEW.case_id,
            NEW.request_type || ' -> ' || NEW.assigned_team || coalesce(' (dispute ' || NEW.dispute_id || ')', ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_case AFTER INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION audit_case();

\ir seed_data.sql
