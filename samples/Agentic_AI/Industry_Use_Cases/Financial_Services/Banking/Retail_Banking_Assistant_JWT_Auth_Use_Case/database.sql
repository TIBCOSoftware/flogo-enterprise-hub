-- Kestrel Bank Retail Banking Assistant (JWT AUTH variant) - schema, business rules and demo data.
-- Load:  createdb banking_jwt_auth  &&  psql -d banking_jwt_auth -f database.sql
--
-- =====================================================================
-- Retail Banking Assistant - Governed Agentic AI, identity from a verified JWT
-- WHO is calling is not decided here: the user signs in to the bank's identity provider and arrives with a JWT.
-- The MCP Server trigger verifies it (signature, expiry, per-tool scope) and hands each tool flow the verified
-- subject ($flow.tokenInfo.sub). Every rule function takes that subject as p_sub - never model input, never a
-- tool argument - and resolves it here. No passcodes, sessions or lockouts live in this database.
-- The rules live HERE, not in any prompt:
--   * caller_customer()      identity: every customer read/write is scoped to the customer whose id is the JWT sub
--   * caller_reviewer()      the same for staff: the sub must be an ACTIVE reviewer (role checked on every call)
--   * whoami()               what the bank knows about the signed-in subject (role, display name, team, limit)
--   * card_block_eval()      card-block eligibility (ownership, not already blocked, not expired, valid reason)
--   * dispute_eval()         dispute eligibility, provisional credit, fraud review and decision date - ARITHMETIC
--   * trg_card_block_apply   a confirmed block sets the card BLOCKED and orders the replacement atomically
--   * trg_dispute_apply      a filed dispute posts the provisional credit and opens the FRAUD_REVIEW case atomically
--   * lookup_merchant()      descriptor decoding for the A2A dispute_triage_agent - NO customer identity
--   * payment_eval() + scam_assessment()  payments to saved payees: the scam_signal_agent's indicators + narrative
--                            score are VALIDATED against scam_signal_guide and COMBINED in SQL with deterministic
--                            signals (new payee, unusual amount, first payee type, share of balance) into a band:
--                            LOW -> two-step confirm, MEDIUM -> warning the customer must acknowledge, HIGH -> the
--                            payment is HELD and a PAYMENT_HOLD case goes to Fraud Operations (never the customer's call)
--   * case_parking()         a human-owned case parks a typed action (FEE_REFUND:<txn> / LOAN_DEFERRAL:<loan> /
--                            RELEASE_PAYMENT:<payment>) that runs ONLY when a reviewer approves it
--   * service_teams          human-owned requests (fee refund, hardship, limit increase...) routed by a table
--   * reviewers + decide_case_row()  the human-in-the-loop: a staff reviewer (JWT sub = staff id, own team only,
--                            approval limit) decides; review_decisions + trg_review_decision execute the parked action
--                            through the same guarded row functions, and audit it (CASE_DECIDED)
--   * ref_scam_signals() / ref_hardship_guide()  the agents' read-only reference tables - NO customer identity
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The genuinely semantic steps are the three A2A agents: dispute_triage_agent (which charge, which merchant),
-- scam_signal_agent (authorised-push-payment scam signs in the customer's story) and hardship_intake_agent
-- (free-text hardship story -> a structured brief for the Financial Support reviewer).
-- Kestrel Bank, its customers, staff, accounts, payees and merchants are fictional.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid() on PostgreSQL < 13

-- Re-runnable: drop this use case's functions first (CREATE OR REPLACE cannot change a return type).
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

DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, loan_deferrals, payment_sends,
  payment_requests, payees, service_cases, service_teams, disputes, card_replacements, card_blocks,
  pending_actions, reviewers, merchant_directory,
  scam_signal_guide, hardship_guide, branches, loans, transactions, cards, accounts, customers CASCADE;
DROP SEQUENCE IF EXISTS txn_seq, blk_seq, dsp_seq, case_seq, pay_seq, def_seq;

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
  customer_id    VARCHAR(20) PRIMARY KEY,           -- CUST-2026-NNNNN (= the JWT sub the identity provider issues)
  first_name     VARCHAR(50) NOT NULL,
  last_name      VARCHAR(50) NOT NULL,
  phone          VARCHAR(30),
  email          VARCHAR(100) NOT NULL,
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

-- Agent reference tables: what the scam_signal_agent and hardship_intake_agent may read (through ref_* functions
-- only). Same shape for both - section / term / meaning - and NO customer, account, payee, staff, case, session or
-- contact data, ever. The "who decides" rows are NOT copied here: the ref_* functions read them from service_teams
-- (one source of truth).
CREATE TABLE scam_signal_guide (                 -- scam_signal_agent: APP-scam indicators, payee types, score rules
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('HIGH_RISK', 'CAUTION', 'PAYEE_TYPE', 'SCORE_RULE', 'REVIEW_STEP')),
  term        VARCHAR(60) NOT NULL,              -- SAFE_ACCOUNT
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE hardship_guide (                    -- hardship_intake_agent: causes, durations, programs, documents
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CAUSE', 'DURATION', 'PRODUCT', 'PROGRAM', 'DOCUMENT',
                                                      'SUPPORT_LINE', 'BRIEF_RULE')),
  term        VARCHAR(60) NOT NULL,              -- PAYMENT_DEFERRAL_3M
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- Staff reviewers (the human in the loop). team matches service_teams.team.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- KST-7001 (staff id = the JWT sub of the staff member's token)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(60) NOT NULL,
  approval_limit  NUMERIC(12,2),                 -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
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

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE service_teams (
  request_type         VARCHAR(24) PRIMARY KEY,
  label                VARCHAR(40) NOT NULL,          -- customer-facing name
  team                 VARCHAR(60) NOT NULL,
  reply_business_days  INTEGER NOT NULL,
  customer_openable    BOOLEAN NOT NULL DEFAULT TRUE  -- PAYMENT_HOLD is opened only by the payment rules
);

CREATE SEQUENCE case_seq START 1;
CREATE TABLE service_cases (
  case_id             VARCHAR(12) PRIMARY KEY DEFAULT 'CASE-' || lpad(nextval('case_seq')::text, 5, '0'),
  customer_id         VARCHAR(20) NOT NULL REFERENCES customers,
  request_type        VARCHAR(24) NOT NULL REFERENCES service_teams,
  customer_statement  TEXT NOT NULL,
  agent_brief         TEXT NOT NULL,            -- neutral summary written by the assistant / an A2A agent / the system; never a decision
  assigned_team       VARCHAR(60) NOT NULL,
  dispute_id          VARCHAR(16) REFERENCES disputes,   -- set for FRAUD_REVIEW cases opened by trg_dispute_apply
  requested_amount    NUMERIC(12,2),            -- the fee, the deferred payments or the held payment (NULL = no amount)
  parked_action       VARCHAR(40),              -- runs ONLY on approval: FEE_REFUND:<txn> / LOAN_DEFERRAL:<loan> / RELEASE_PAYMENT:<payment>
  status              VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at          TIMESTAMP,                -- set by trg_case_defaults from service_teams
  customer_message    TEXT,                     -- customer-safe outcome text, set by the reviewer's decision
  approved_amount     NUMERIC(12,2),
  decided_at          TIMESTAMP,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE case_seq OWNED BY service_cases.case_id;

-- Insert-only decision events (one per case). trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          VARCHAR(12) NOT NULL UNIQUE REFERENCES service_cases,
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(12,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from customers
  customer_message TEXT NOT NULL,
  decided_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every decide call by an active reviewer (readback of the outcome and reason). A CONFIRM_REQUIRED row is a decision
-- awaiting the reviewer's yes: the same decision and amount again within 15 minutes records it.
CREATE TABLE decide_attempts (
  attempt_id       SERIAL PRIMARY KEY,
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  case_ref         VARCHAR(40) NOT NULL,
  outcome          VARCHAR(16) NOT NULL,         -- CONFIRM_REQUIRED / APPROVED / REJECTED / BLOCKED
  reason_code      VARCHAR(24),
  reason_text      TEXT,
  decision         VARCHAR(8),                   -- CONFIRM_REQUIRED: the pending decision, amount and customer message
  approved_amount  NUMERIC(12,2),
  customer_message TEXT,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- A reviewer-approved hardship deferral (event row; trg_loan_deferral moves the loan's next due date).
CREATE SEQUENCE def_seq START 1;
CREATE TABLE loan_deferrals (
  deferral_id        VARCHAR(12) PRIMARY KEY,    -- DEF-00001
  loan_id            VARCHAR(20) NOT NULL REFERENCES loans,
  case_id            VARCHAR(12) NOT NULL UNIQUE REFERENCES service_cases,
  payments_deferred  INTEGER NOT NULL CHECK (payments_deferred BETWEEN 1 AND 3),
  deferred_amount    NUMERIC(12,2) NOT NULL CHECK (deferred_amount > 0),
  old_due_date       DATE NOT NULL,
  new_due_date       DATE NOT NULL,
  created_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Saved payees. New payees are added in the Kestrel app, never by the assistant.
CREATE TABLE payees (
  payee_id        VARCHAR(10) PRIMARY KEY,       -- PYE-0101
  customer_id     VARCHAR(20) NOT NULL REFERENCES customers,
  payee_name      VARCHAR(60) NOT NULL,
  bank_name       VARCHAR(60) NOT NULL,
  account_masked  VARCHAR(12) NOT NULL,
  payee_type      VARCHAR(20) NOT NULL CHECK (payee_type IN ('PERSON','BUSINESS','INVESTMENT_PLATFORM','CRYPTO_EXCHANGE')),
  added_at        TIMESTAMP NOT NULL,
  last_paid_at    TIMESTAMP
);

-- Every evaluated payment request = the recorded scam assessment (record of what the agent said and what SQL decided).
CREATE SEQUENCE pay_seq START 1;
CREATE TABLE payment_requests (
  payment_id           VARCHAR(12) PRIMARY KEY DEFAULT 'PAY-' || lpad(nextval('pay_seq')::text, 5, '0'),
  customer_id          VARCHAR(20) NOT NULL REFERENCES customers,
  account_id           VARCHAR(20) NOT NULL REFERENCES accounts,
  payee_id             VARCHAR(10) NOT NULL REFERENCES payees,
  amount               NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  customer_story       TEXT,                     -- the customer's own words about the payment
  agent_notes          TEXT,                     -- HIDDEN: the scam_signal_agent's full answer (reviewers only)
  narrative_indicators TEXT,                     -- HIDDEN: agent indicators that exist in scam_signal_guide (validated)
  ignored_indicators   TEXT,                     -- HIDDEN: anything else the model sent (recorded, never scored)
  narrative_score      INTEGER NOT NULL DEFAULT 0 CHECK (narrative_score BETWEEN 0 AND 100),   -- HIDDEN
  signals              TEXT,                     -- HIDDEN: deterministic signals computed in SQL
  risk_points          INTEGER NOT NULL,         -- HIDDEN
  risk_band            VARCHAR(6) NOT NULL CHECK (risk_band IN ('LOW','MEDIUM','HIGH')),   -- HIDDEN
  status               VARCHAR(10) NOT NULL CHECK (status IN ('PROPOSED','HELD','SENT','RELEASED','CANCELLED')),
  warning_required     BOOLEAN NOT NULL DEFAULT FALSE,
  case_id              VARCHAR(12),              -- the PAYMENT_HOLD case (HIGH band)
  confirm_count        INTEGER NOT NULL DEFAULT 0,
  executed_confirm_no  INTEGER,
  created_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

-- A payment that actually leaves the account (event row; trg_payment_send posts the debit atomically).
CREATE TABLE payment_sends (
  payment_id  VARCHAR(12) PRIMARY KEY REFERENCES payment_requests,
  via         VARCHAR(10) NOT NULL CHECK (via IN ('CUSTOMER','REVIEWER')),
  case_id     VARCHAR(12),
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  sent_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; no MCP tool exposes it.
CREATE TABLE agent_audit (
  id           SERIAL PRIMARY KEY,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  customer_id  VARCHAR(20),
  actor        VARCHAR(20),            -- reviewer id (the reviewer's JWT sub) for CASE_DECIDED
  action       VARCHAR(30) NOT NULL,   -- CARD_BLOCK_PROPOSED, CARD_BLOCKED, DISPUTE_PROPOSED, DISPUTE_FILED,
                                       -- SERVICE_CASE_OPENED, PAYMENT_PROPOSED, PAYMENT_HELD, PAYMENT_SENT, LOAN_DEFERRED, CASE_DECIDED
  ref          TEXT,
  detail       TEXT
);

-- Guarded email requests that passed the SQL check (the flow then sends to To_Email).
CREATE TABLE email_log (
  email_id     SERIAL PRIMARY KEY,
  customer_id  VARCHAR(20) NOT NULL REFERENCES customers,
  reference_id VARCHAR(20) NOT NULL,
  subject      TEXT NOT NULL,
  logged_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- RULES
-- =====================================================================

-- Identity: the caller is the VERIFIED JWT subject (tokenInfo.sub, checked by the MCP Server trigger before any
-- flow runs). ALWAYS returns exactly one row - the customer whose customer_id is the subject, or (null,null) when the
-- subject is not a Kestrel Bank customer (e.g. a staff token) - so dependent reads can emit UNKNOWN_CALLER.
-- plpgsql (NOT sql) on purpose: an inlinable SQL function here merges into the caller's LEFT JOINs
-- and can mis-bind rows. plpgsql is opaque to the planner, so callers see a clean one-row relation.
-- The subject is matched exactly (no trimming or case folding): it comes from a signed token, never from a person.
CREATE OR REPLACE FUNCTION caller_customer(p_sub TEXT)
RETURNS TABLE (customer_id TEXT, customer_name TEXT) AS $$
BEGIN
  RETURN QUERY
    SELECT c.customer_id::text, (c.first_name || ' ' || c.last_name)::text
      FROM (SELECT 1) one
      LEFT JOIN customers c ON c.customer_id = coalesce(p_sub, '');
END $$ LANGUAGE plpgsql STABLE;

-- Reviewer identity: one row always - the reviewer when the subject is an ACTIVE staff reviewer (a customer's subject,
-- an unknown or a deactivated staff id -> nulls -> NOT_REVIEWER).
CREATE OR REPLACE FUNCTION caller_reviewer(p_sub TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN reviewers r ON r.reviewer_id = coalesce(p_sub, '') AND r.active;
END $$ LANGUAGE plpgsql STABLE;

-- whoami: what the bank knows about the signed-in subject. role CUSTOMER / REVIEWER / UNKNOWN, a display name and,
-- for a reviewer, the team and approval limit. Never an email, phone, account or anything secret.
CREATE OR REPLACE FUNCTION whoami(p_sub TEXT)
RETURNS TABLE (role TEXT, subject TEXT, display_name TEXT, team TEXT, approval_limit NUMERIC, reason TEXT) AS $$
  SELECT CASE WHEN cc.customer_id IS NOT NULL THEN 'CUSTOMER' WHEN cr.reviewer_id IS NOT NULL THEN 'REVIEWER' ELSE 'UNKNOWN' END,
         coalesce(p_sub, ''),
         coalesce(cc.customer_name, cr.display_name::text),
         CASE WHEN cc.customer_id IS NULL THEN cr.team::text END,
         CASE WHEN cc.customer_id IS NULL THEN cr.approval_limit END,
         CASE WHEN cc.customer_id IS NOT NULL
                THEN 'CUSTOMER: signed in as a Kestrel Bank customer. Customer tools act on this customer''s own accounts only.'
              WHEN cr.reviewer_id IS NOT NULL
                THEN 'REVIEWER: signed in as a Kestrel staff reviewer (' || cr.team || '). Review tools show this team''s queue only.'
              ELSE 'UNKNOWN: the signed-in identity is not a Kestrel Bank customer or an active staff reviewer. '
                   || 'No customer or reviewer tool will act for it.' END
    FROM caller_customer(p_sub) cc CROSS JOIN caller_reviewer(p_sub) cr;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Helpers (formatting, normalisation) used by the rules below.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$ SELECT upper(trim(coalesce(p, ''))) $$ LANGUAGE sql IMMUTABLE;

-- '$1,234.50' / '1234.5' / ' 35 ' -> '1234.50'-style text ('' when empty); 'ALL' stays 'ALL'.
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(coalesce(p, ''), '[[:space:]$,]', '', 'g'))
$$ LANGUAGE sql IMMUTABLE;

-- What a reviewer sees instead of the full name (minimum necessary).
CREATE OR REPLACE FUNCTION customer_display(p_customer TEXT) RETURNS TEXT AS $$
  SELECT c.first_name || ' ' || left(c.last_name, 1) || '.' FROM customers c WHERE c.customer_id = p_customer
$$ LANGUAGE sql STABLE;

-- The standard hardship deferral is up to 3 monthly payments (PAYMENT_DEFERRAL_3M).
CREATE OR REPLACE FUNCTION deferral_max_payments() RETURNS INTEGER AS $$ SELECT 3 $$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------------
-- Scoped reads: only the caller's rows; one UNKNOWN_CALLER row when the subject is not a customer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_accounts(p_sub TEXT)
RETURNS TABLE (caller_status TEXT, customer_name TEXT, account_id VARCHAR, account_number_masked VARCHAR,
               account_type VARCHAR, balance NUMERIC, available_balance NUMERIC, currency VARCHAR, status VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' ELSE 'OK' END, sc.customer_name,
         a.account_id, a.account_number_masked, a.account_type, a.balance, a.available_balance, a.currency, a.status
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN accounts a ON a.customer_id = sc.customer_id
   ORDER BY a.account_id;
$$ LANGUAGE sql STABLE;

-- Transactions: empty search = everything in the last 120 days; a search term (descriptor/category text,
-- an amount like 249.99, or a TXN- id) looks back 13 months so an old charge is still found and
-- propose_dispute can explain OUTSIDE_WINDOW. Newest first, max 25. NO_MATCH when nothing matches.
CREATE OR REPLACE FUNCTION my_transactions(p_sub TEXT, p_search TEXT)
RETURNS TABLE (caller_status TEXT, transaction_id VARCHAR, txn_date DATE, descriptor VARCHAR, amount NUMERIC,
               txn_type VARCHAR, category VARCHAR, status VARCHAR, account_id VARCHAR, card_last4 VARCHAR,
               open_dispute_id VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' WHEN t.transaction_id IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         t.transaction_id, t.txn_date, t.descriptor, t.amount, t.txn_type, t.category, t.status, t.account_id,
         t.last4, t.dispute_id
    FROM (SELECT * FROM caller_customer(p_sub)) sc
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

CREATE OR REPLACE FUNCTION my_cards(p_sub TEXT)
RETURNS TABLE (caller_status TEXT, card_id VARCHAR, last4 VARCHAR, card_number_masked VARCHAR, card_type VARCHAR,
               network VARCHAR, status VARCHAR, expiry DATE, credit_limit NUMERIC, account_id VARCHAR,
               replacement_expected_delivery DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' ELSE 'OK' END,
         k.card_id, k.last4, k.card_number_masked, k.card_type, k.network,
         CASE WHEN k.status = 'ACTIVE' AND k.expiry < current_date THEN 'EXPIRED' ELSE k.status END::varchar,
         k.expiry, k.credit_limit, k.account_id, r.expected_delivery
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN cards k ON k.customer_id = sc.customer_id
    LEFT JOIN LATERAL (SELECT cr.expected_delivery FROM card_replacements cr
                        WHERE cr.card_id = k.card_id ORDER BY cr.ordered_at DESC LIMIT 1) r ON TRUE
   ORDER BY k.card_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_loans(p_sub TEXT)
RETURNS TABLE (caller_status TEXT, loan_id VARCHAR, loan_type VARCHAR, principal NUMERIC, outstanding_balance NUMERIC,
               interest_rate NUMERIC, monthly_payment NUMERIC, next_due_date DATE, status VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' ELSE 'OK' END,
         l.loan_id, l.loan_type, l.principal, l.outstanding_balance, l.interest_rate, l.monthly_payment,
         l.next_due_date, l.status
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN loans l ON l.customer_id = sc.customer_id
   ORDER BY l.loan_id;
$$ LANGUAGE sql STABLE;

-- Public data: no caller identity. Empty city = all branches.
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

-- The customer's saved payees. is_new_payee = never paid and added in the last 30 days (a deterministic scam signal).
CREATE OR REPLACE FUNCTION my_payees(p_sub TEXT)
RETURNS TABLE (caller_status TEXT, payee_id VARCHAR, payee_name VARCHAR, bank_name VARCHAR, account_masked VARCHAR,
               payee_type VARCHAR, added_on DATE, last_paid_on DATE, is_new_payee BOOLEAN) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' ELSE 'OK' END,
         p.payee_id, p.payee_name, p.bank_name, p.account_masked, p.payee_type, p.added_at::date, p.last_paid_at::date,
         CASE WHEN p.payee_id IS NOT NULL THEN p.last_paid_at IS NULL AND p.added_at > clock_timestamp() - INTERVAL '30 days' END
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN payees p ON p.customer_id = sc.customer_id
   ORDER BY p.payee_id;
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
CREATE OR REPLACE FUNCTION card_block_eval(p_sub TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, card_id TEXT, last4 TEXT, card_type TEXT, block_reason TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; k cards;
        v_reason TEXT := upper(regexp_replace(trim(coalesce(p_reason,'')), '[\s-]+', '_', 'g'));
BEGIN
  ok := FALSE; block_reason := v_reason;
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN
    reason_code := 'UNKNOWN_CALLER'; reason := 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.';
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
CREATE OR REPLACE FUNCTION card_block_proposal_row(p_sub TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (action_type TEXT, customer_id TEXT, card_id TEXT, reason_code TEXT) AS $$
  SELECT 'CARD_BLOCK', sc.customer_id, e.card_id, e.block_reason
    FROM caller_customer(p_sub) sc
    CROSS JOIN LATERAL card_block_eval(p_sub, p_card, p_reason) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.customer_id = sc.customer_id AND pa.action_type = 'CARD_BLOCK'
                        AND pa.card_id = e.card_id AND pa.reason_code = e.block_reason
                        AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_card_block_result(p_sub TEXT, p_card TEXT, p_reason TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, card_id TEXT, last4 TEXT, card_type TEXT,
               block_reason TEXT, replacement_expected_delivery DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; pa pending_actions; v_cid TEXT;
BEGIN
  SELECT * INTO e FROM card_block_eval(p_sub, p_card, p_reason);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  card_id := e.card_id; last4 := e.last4; card_type := e.card_type; block_reason := e.block_reason;
  IF e.ok THEN
    SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
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
CREATE OR REPLACE FUNCTION card_block_confirmation_row(p_sub TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, card_id TEXT, reason TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; e RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.customer_id = v_cid AND p.action_type = 'CARD_BLOCK';
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE pending_actions p SET confirm_count = p.confirm_count + 1 WHERE p.action_id = pa.action_id;
  IF pa.status <> 'PENDING' OR pa.expires_at <= clock_timestamp() THEN RETURN; END IF;
  SELECT * INTO e FROM card_block_eval(p_sub, pa.card_id, pa.reason_code);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT pa.action_id::text, pa.card_id::text, pa.reason_code::text;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_card_block_result(p_sub TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, block_id TEXT, card_id TEXT, last4 TEXT, block_reason TEXT,
               card_status TEXT, replacement_expected_delivery DATE, blocked_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; b card_blocks; k cards; e RECORD; v_delivery DATE;
BEGIN
  outcome := 'NOT_EXECUTED';
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN
    reason_code := 'UNKNOWN_CALLER'; reason := 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.';
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
  SELECT * INTO e FROM card_block_eval(p_sub, pa.card_id, pa.reason_code);
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
CREATE OR REPLACE FUNCTION dispute_eval(p_sub TEXT, p_txn TEXT, p_reason TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, transaction_id TEXT, account_id TEXT, descriptor TEXT,
               txn_date DATE, amount NUMERIC, dispute_reason TEXT, provisional_credit NUMERIC, fraud_review BOOLEAN,
               est_decision_date DATE) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; t transactions; v_reason TEXT := norm_dispute_reason(p_reason); v_dsp TEXT; v_dup TEXT;
BEGIN
  ok := FALSE; dispute_reason := v_reason;
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN
    reason_code := 'UNKNOWN_CALLER'; reason := 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.';
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
CREATE OR REPLACE FUNCTION dispute_proposal_row(p_sub TEXT, p_txn TEXT, p_reason TEXT, p_statement TEXT)
RETURNS TABLE (action_type TEXT, customer_id TEXT, transaction_id TEXT, reason_code TEXT, customer_statement TEXT,
               amount NUMERIC, provisional_credit NUMERIC, fraud_review BOOLEAN) AS $$
  SELECT 'DISPUTE', sc.customer_id, e.transaction_id, e.dispute_reason, left(coalesce(p_statement,''), 4000),
         e.amount, e.provisional_credit, e.fraud_review
    FROM caller_customer(p_sub) sc
    CROSS JOIN LATERAL dispute_eval(p_sub, p_txn, p_reason) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.customer_id = sc.customer_id AND pa.action_type = 'DISPUTE'
                        AND pa.transaction_id = e.transaction_id AND pa.reason_code = e.dispute_reason
                        AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_dispute_result(p_sub TEXT, p_txn TEXT, p_reason TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, transaction_id TEXT, descriptor TEXT,
               merchant TEXT, txn_date DATE, amount NUMERIC, dispute_reason TEXT, provisional_credit NUMERIC,
               fraud_review BOOLEAN, est_decision_date DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; pa pending_actions; v_cid TEXT;
BEGIN
  SELECT * INTO e FROM dispute_eval(p_sub, p_txn, p_reason);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  transaction_id := e.transaction_id; descriptor := e.descriptor; txn_date := e.txn_date; amount := e.amount;
  dispute_reason := e.dispute_reason;
  SELECT lm.merchant_name INTO merchant FROM lookup_merchant(e.descriptor) lm WHERE lm.match_type = 'PREFIX_MATCH' LIMIT 1;
  merchant := coalesce(merchant, e.descriptor);
  IF e.ok THEN
    SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
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

CREATE OR REPLACE FUNCTION dispute_confirmation_row(p_sub TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, customer_id TEXT, transaction_id TEXT, reason_code TEXT, customer_statement TEXT,
               amount NUMERIC, provisional_credit NUMERIC, fraud_review BOOLEAN, est_decision_date DATE) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; e RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p
   WHERE p.action_id = upper(trim(coalesce(p_action,''))) AND p.customer_id = v_cid AND p.action_type = 'DISPUTE';
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE pending_actions p SET confirm_count = p.confirm_count + 1 WHERE p.action_id = pa.action_id;
  IF pa.status <> 'PENDING' OR pa.expires_at <= clock_timestamp() THEN RETURN; END IF;
  SELECT * INTO e FROM dispute_eval(p_sub, pa.transaction_id, pa.reason_code);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT pa.action_id::text, pa.customer_id::text, pa.transaction_id::text, pa.reason_code::text,
                      pa.customer_statement, pa.amount, pa.provisional_credit, pa.fraud_review,
                      add_business_days(current_date, 10);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_dispute_result(p_sub TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, dispute_id TEXT, transaction_id TEXT, dispute_reason TEXT,
               amount NUMERIC, provisional_credit NUMERIC, provisional_credit_txn TEXT, fraud_review BOOLEAN,
               fraud_case_id TEXT, est_decision_date DATE, status TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; pa pending_actions; d disputes; e RECORD;
BEGIN
  outcome := 'NOT_FILED';
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN
    reason_code := 'UNKNOWN_CALLER'; reason := 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.';
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
  SELECT * INTO e FROM dispute_eval(p_sub, pa.transaction_id, pa.reason_code);
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
-- Human-owned requests -> routed to a team by the table, never decided by the LLM. A case may PARK an action
-- (fee refund, loan deferral, payment release) that runs only when a reviewer of that team approves it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION norm_request_type(p_type TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p_type,'')), '[\s-]+', '_', 'g'));
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fee_refunded(p_txn TEXT) RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM transactions r WHERE r.descriptor = 'FEE REFUND ' || p_txn AND r.txn_type = 'CREDIT')
$$ LANGUAGE sql STABLE;

-- What a new case parks for approval (derived in SQL, never chosen by the model):
--   FEE_REFUND    + reference = one of the customer's posted, unrefunded FEES debits (empty -> the latest one in 120 days)
--   LOAN_HARDSHIP + reference = one of the customer's ACTIVE loans (empty -> the only active loan, if exactly one)
--                   -> LOAN_DEFERRAL:<loan>, requested = deferral_max_payments() x the monthly payment
--   anything else -> no parked action (the team completes it). A reference that is not the customer's -> BAD_REFERENCE.
CREATE OR REPLACE FUNCTION case_parking(p_customer TEXT, p_type TEXT, p_reference TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, parked_action TEXT, requested_amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_type TEXT := norm_request_type(p_type); v_ref TEXT := norm_ref(p_reference); t transactions; l loans; n INTEGER;
BEGIN
  ok := TRUE; reason_code := 'OK';
  IF v_type = 'FEE_REFUND' THEN
    IF v_ref <> '' THEN
      SELECT * INTO t FROM transactions x WHERE x.transaction_id = v_ref AND x.customer_id = p_customer;
      IF NOT FOUND OR t.txn_type <> 'DEBIT' OR coalesce(t.category, '') <> 'FEES' OR t.status <> 'POSTED'
         OR fee_refunded(t.transaction_id) THEN
        ok := FALSE; reason_code := 'BAD_REFERENCE'; RETURN NEXT; RETURN;
      END IF;
    ELSE
      SELECT * INTO t FROM transactions x
       WHERE x.customer_id = p_customer AND x.txn_type = 'DEBIT' AND x.category = 'FEES' AND x.status = 'POSTED'
         AND x.txn_date >= current_date - 120 AND NOT fee_refunded(x.transaction_id)
       ORDER BY x.txn_date DESC, x.transaction_id DESC LIMIT 1;
    END IF;
    IF t.transaction_id IS NOT NULL THEN
      parked_action := 'FEE_REFUND:' || t.transaction_id; requested_amount := t.amount;
    END IF;
  ELSIF v_type = 'LOAN_HARDSHIP' THEN
    IF v_ref <> '' THEN
      SELECT * INTO l FROM loans x WHERE x.loan_id = v_ref AND x.customer_id = p_customer;
      IF NOT FOUND OR l.status <> 'ACTIVE' THEN
        ok := FALSE; reason_code := 'BAD_REFERENCE'; RETURN NEXT; RETURN;
      END IF;
    ELSE
      SELECT count(*) INTO n FROM loans x WHERE x.customer_id = p_customer AND x.status = 'ACTIVE';
      IF n = 1 THEN SELECT * INTO l FROM loans x WHERE x.customer_id = p_customer AND x.status = 'ACTIVE'; END IF;
    END IF;
    IF l.loan_id IS NOT NULL THEN
      parked_action := 'LOAN_DEFERRAL:' || l.loan_id; requested_amount := deferral_max_payments() * l.monthly_payment;
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Every case gets its reply-due time from the routing table (also cases opened by triggers and seeds).
CREATE OR REPLACE FUNCTION case_defaults() RETURNS TRIGGER AS $$
DECLARE t service_teams;
BEGIN
  SELECT * INTO t FROM service_teams WHERE request_type = NEW.request_type;
  NEW.sla_due_at := coalesce(NEW.sla_due_at, add_business_days(NEW.created_at::date, t.reply_business_days) + NEW.created_at::time);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION case_defaults();

CREATE OR REPLACE FUNCTION service_case_row(p_sub TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT, p_reference TEXT)
RETURNS TABLE (customer_id TEXT, request_type VARCHAR, customer_statement TEXT, agent_brief TEXT, assigned_team VARCHAR,
               requested_amount NUMERIC, parked_action TEXT) AS $$
  SELECT sc.customer_id, t.request_type, left(coalesce(p_statement,''), 4000), left(coalesce(p_brief,''), 4000), t.team,
         pk.requested_amount, pk.parked_action
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    JOIN service_teams t ON t.request_type = norm_request_type(p_type) AND t.customer_openable
    CROSS JOIN LATERAL case_parking(sc.customer_id, p_type, p_reference) pk
   WHERE sc.customer_id IS NOT NULL AND pk.ok
     -- the SAME request repeated within 10 minutes (an AI retry) is not opened twice; a different request of the same
     -- type is a new case
     AND NOT EXISTS (SELECT 1 FROM service_cases c
                      WHERE c.customer_id = sc.customer_id AND c.request_type = t.request_type
                        AND c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                        AND lower(regexp_replace(btrim(c.customer_statement), '\s+', ' ', 'g'))
                            = lower(regexp_replace(btrim(left(coalesce(p_statement, ''), 4000)), '\s+', ' ', 'g')))
     AND NOT EXISTS (SELECT 1 FROM service_cases c
                      WHERE pk.parked_action IS NOT NULL AND c.parked_action = pk.parked_action AND c.status = 'OPEN');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_sub TEXT, p_type TEXT, p_reference TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, case_id VARCHAR, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, reply_by DATE, status VARCHAR, requested_amount NUMERIC,
               if_approved TEXT, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NULL THEN 'NOT_OPENED'
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CASE_OPENED' ELSE 'ALREADY_OPEN' END,
         CASE WHEN c.case_id IS NOT NULL THEN
                CASE WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CASE_OPENED' ELSE 'ALREADY_OPEN' END
              WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER'
              WHEN t0.request_type IS NULL THEN 'BAD_TYPE'
              WHEN NOT pk.ok THEN 'BAD_REFERENCE' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL AND c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                THEN 'A person on the assigned team will review and decide. The assistant has not decided or promised anything.'
              WHEN c.case_id IS NOT NULL
                THEN 'This request is already open with the assigned team, so no new case was opened. A person will decide.'
              WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.'
              WHEN t0.request_type IS NULL THEN 'BAD_TYPE: use FEE_REFUND, LOAN_HARDSHIP, CREDIT_LIMIT_INCREASE, COMPLAINT, '
                   || 'PERSONAL_DETAILS_CHANGE, ACCOUNT_CLOSURE, BEREAVEMENT, FRAUD_REVIEW or OTHER.'
              WHEN NOT pk.ok THEN 'BAD_REFERENCE: that reference is not one of this customer''s posted, unrefunded fees '
                   || '(FEE_REFUND) or active loans (LOAN_HARDSHIP). Use get_my_transactions or get_my_loans, or leave it empty.'
              ELSE 'NOT_OPENED: the case could not be recorded. Try again.' END,
         c.case_id, c.request_type, t.team, t.reply_business_days, c.sla_due_at::date, c.status, c.requested_amount,
         CASE split_part(coalesce(c.parked_action, ''), ':', 1)
              WHEN 'FEE_REFUND' THEN 'If a person approves it, the fee is refunded to the account it was charged to.'
              WHEN 'LOAN_DEFERRAL' THEN 'If a person approves it, up to ' || deferral_max_payments() || ' monthly payments on loan '
                   || split_part(c.parked_action, ':', 2) || ' are deferred.' END,
         c.created_at
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN service_teams t0 ON t0.request_type = norm_request_type(p_type) AND t0.customer_openable
    LEFT JOIN LATERAL (SELECT * FROM case_parking(sc.customer_id, p_type, p_reference)) pk ON TRUE
    LEFT JOIN LATERAL (
      SELECT x.* FROM service_cases x
       WHERE x.customer_id = sc.customer_id AND x.request_type = norm_request_type(p_type) AND t0.request_type IS NOT NULL
         AND (x.created_at > clock_timestamp() - INTERVAL '10 minutes'
              OR (x.status = 'OPEN' AND pk.parked_action IS NOT NULL AND x.parked_action = pk.parked_action))
       ORDER BY x.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The customer's disputes and service cases in one list: status + the customer-safe outcome message once a person
-- decided. Never the internal note, the AI brief, risk details or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_sub TEXT)
RETURNS TABLE (caller_status TEXT, case_type TEXT, reference_id TEXT, topic TEXT, transaction_id TEXT,
               assigned_team TEXT, status TEXT, amount NUMERIC, provisional_credit NUMERIC, expected_by DATE,
               related_dispute_id TEXT, approved_amount NUMERIC, customer_message TEXT, decided_on DATE,
               created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' ELSE 'OK' END,
         c.case_type, c.reference_id, c.topic, c.transaction_id, c.assigned_team, c.status, c.amount,
         c.provisional_credit, c.expected_by, c.related_dispute_id, c.approved_amount, c.customer_message, c.decided_on,
         c.created_at
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN LATERAL (
      SELECT 'DISPUTE'::text AS case_type, d.dispute_id::text AS reference_id, d.reason_code::text AS topic,
             d.transaction_id::text AS transaction_id, 'Card Disputes'::text AS assigned_team, d.status::text AS status,
             d.amount, d.provisional_credit, d.est_decision_date AS expected_by, NULL::text AS related_dispute_id,
             NULL::numeric AS approved_amount, NULL::text AS customer_message, NULL::date AS decided_on, d.created_at
        FROM disputes d WHERE d.customer_id = sc.customer_id
      UNION ALL
      SELECT 'SERVICE_CASE', s.case_id, s.request_type, NULL, s.assigned_team, s.status, s.requested_amount, NULL,
             s.sla_due_at::date, s.dispute_id, s.approved_amount, s.customer_message, s.decided_at::date, s.created_at
        FROM service_cases s
       WHERE s.customer_id = sc.customer_id) c ON TRUE
   ORDER BY c.created_at DESC, c.reference_id DESC;
$$ LANGUAGE sql STABLE;

-- Email confirmation: validated payload for the guarded email tool. Returns SEND + subject/body ONLY when the
-- reference is a dispute (DSP-), card block (BLK-), decided case (CASE-, a review_decisions row exists) or sent
-- payment (PAY-) of THIS customer; otherwise NOT_SENT + reason. The flow sends to the configured To_Email; the body
-- never contains full card or account numbers, internal notes or risk details.
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_sub TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason TEXT, reference_id TEXT, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN x.ok THEN 'SEND' ELSE 'NOT_SENT' END,
         CASE WHEN x.ok THEN 'SEND' WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER' ELSE 'NO_SUCH_REFERENCE' END,
         CASE WHEN x.ok THEN 'Confirmation email prepared.'
              WHEN sc.customer_id IS NULL THEN 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer.'
              ELSE 'NO_SUCH_REFERENCE: no dispute (DSP-), card block (BLK-), decided case (CASE-) or sent payment (PAY-) '
                   || 'with that reference for this customer.' END,
         norm_ref(p_reference),
         CASE WHEN d.dispute_id IS NOT NULL THEN 'Kestrel Bank - your dispute ' || d.dispute_id || ' has been filed'
              WHEN k.card_id IS NOT NULL THEN 'Kestrel Bank - your card ending ' || k.last4 || ' is blocked (' || b.block_id || ')'
              WHEN sv.case_id IS NOT NULL THEN 'Kestrel Bank - decision on your ' || st.label || ' (' || sv.case_id || ')'
              WHEN pr.payment_id IS NOT NULL THEN 'Kestrel Bank - your payment ' || pr.payment_id || ' has been sent'
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
              WHEN sv.case_id IS NOT NULL THEN
           'Dear ' || c.first_name || ',' || chr(10) || chr(10)
           || 'Our ' || sv.assigned_team || ' team has reviewed your ' || st.label || ' (case ' || sv.case_id || '): '
           || CASE WHEN sv.status = 'APPROVED' THEN 'approved' ELSE 'not approved' END || '.' || chr(10)
           || coalesce(sv.customer_message, '') || chr(10) || chr(10)
           || 'Thank you for banking with Kestrel Bank.'
              WHEN pr.payment_id IS NOT NULL THEN
           'Dear ' || c.first_name || ',' || chr(10) || chr(10)
           || 'Your payment ' || pr.payment_id || ' of ' || usd(pr.amount) || ' to ' || py.payee_name || ' (' || py.bank_name
           || ' ' || py.account_masked || ') was sent on ' || to_char(ps.sent_at, 'YYYY-MM-DD') || '.' || chr(10) || chr(10)
           || 'Thank you for banking with Kestrel Bank.'
              ELSE 'No confirmation email was sent for reference ' || norm_ref(p_reference) || '.' END
    FROM (SELECT * FROM caller_customer(p_sub)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN disputes d ON d.dispute_id = norm_ref(p_reference) AND d.customer_id = sc.customer_id
    LEFT JOIN transactions t ON t.transaction_id = d.transaction_id
    LEFT JOIN card_blocks b ON b.block_id = norm_ref(p_reference)
    LEFT JOIN cards k ON k.card_id = b.card_id AND k.customer_id = sc.customer_id
    LEFT JOIN LATERAL (SELECT cr.expected_delivery FROM card_replacements cr WHERE cr.block_id = b.block_id
                        ORDER BY cr.ordered_at DESC LIMIT 1) r ON TRUE
    LEFT JOIN service_cases sv ON sv.case_id = norm_ref(p_reference) AND sv.customer_id = sc.customer_id
                              AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = sv.case_id)
    LEFT JOIN service_teams st ON st.request_type = sv.request_type
    LEFT JOIN payment_requests pr ON pr.payment_id = norm_ref(p_reference) AND pr.customer_id = sc.customer_id
                                 AND pr.status IN ('SENT','RELEASED')
    LEFT JOIN payment_sends ps ON ps.payment_id = pr.payment_id
    LEFT JOIN payees py ON py.payee_id = pr.payee_id
    CROSS JOIN LATERAL (SELECT (d.dispute_id IS NOT NULL OR k.card_id IS NOT NULL OR sv.case_id IS NOT NULL
                                OR pr.payment_id IS NOT NULL) AS ok) x;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for the email tool: the request is logged ONLY when the payload says SEND (then the flow sends).
CREATE OR REPLACE FUNCTION email_log_row(p_sub TEXT, p_reference TEXT)
RETURNS TABLE (customer_id TEXT, reference_id TEXT, subject TEXT) AS $$
  SELECT sc.customer_id, e.reference_id, e.subject
    FROM caller_customer(p_sub) sc
    CROSS JOIN LATERAL email_confirmation_payload(p_sub, p_reference) e
   WHERE sc.customer_id IS NOT NULL AND e.send_status = 'SEND';
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change. Cannot be bypassed
-- by the LLM because they fire in the database, not the app.
-- ---------------------------------------------------------------------
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

-- =====================================================================
-- PAYMENTS TO SAVED PAYEES with authorised-push-payment (APP) scam protection.
-- The scam_signal_agent reads the customer's story and returns indicators + a narrative score. SQL validates the
-- indicators against scam_signal_guide (unknown names are recorded and ignored), adds deterministic signals and bands
-- the result. LOW -> two-step confirm; MEDIUM -> a warning the customer must acknowledge before confirm;
-- HIGH -> HELD + a PAYMENT_HOLD case for Fraud Operations (a person decides; the customer never sees the score).
-- =====================================================================

-- A checking or savings account of THIS customer from an account_id (ACC-1014), a type word (savings) or last 4 digits.
CREATE OR REPLACE FUNCTION find_my_account(p_customer TEXT, p_account TEXT) RETURNS SETOF accounts AS $$
  SELECT a.* FROM accounts a
   CROSS JOIN (SELECT regexp_replace(upper(trim(coalesce(p_account, ''))), '[[:space:]]*ACCOUNT$', '') AS q) s
   WHERE a.customer_id = p_customer AND a.account_type IN ('CHECKING','SAVINGS') AND a.status = 'ACTIVE'
     AND (a.account_id = s.q OR a.account_type = s.q
          OR (regexp_replace(s.q, '\D', '', 'g') ~ '^[0-9]{4}$' AND s.q NOT LIKE 'ACC%'
              AND right(a.account_number_masked, 4) = regexp_replace(s.q, '\D', '', 'g')))
   ORDER BY a.account_id;
$$ LANGUAGE sql STABLE;

-- A saved payee of THIS customer from a payee_id (PYE-0102) or part of its name (at least 3 characters).
CREATE OR REPLACE FUNCTION find_my_payee(p_customer TEXT, p_payee TEXT) RETURNS SETOF payees AS $$
  SELECT p.* FROM payees p
   WHERE p.customer_id = p_customer
     AND (p.payee_id = norm_ref(p_payee)
          OR (length(trim(coalesce(p_payee, ''))) >= 3 AND norm_ref(p_payee) NOT LIKE 'PYE-%'
              AND position(norm_ref(p_payee) IN upper(p.payee_name)) > 0))
   ORDER BY p.payee_id;
$$ LANGUAGE sql STABLE;

-- Rule: may this customer pay this saved payee this amount from this account? (no risk logic here)
-- The daily limit on payments to payees, and what a customer has already sent today (customer confirms and reviewer
-- releases alike), so every path that sends money checks the same total.
CREATE OR REPLACE FUNCTION payment_daily_limit() RETURNS NUMERIC AS $$ SELECT 10000::numeric $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION sent_today(p_customer TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(ps.amount), 0) FROM payment_sends ps JOIN payment_requests pr ON pr.payment_id = ps.payment_id
   WHERE pr.customer_id = p_customer AND ps.sent_at::date = current_date
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION payment_eval(p_sub TEXT, p_account TEXT, p_payee TEXT, p_amount TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, customer_id TEXT, account_id TEXT, account_masked TEXT,
               account_type TEXT, payee_id TEXT, payee_name TEXT, payee_type TEXT, amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; a accounts; p payees; n INTEGER; v_txt TEXT := norm_amount(p_amount); v_amt NUMERIC; v_today NUMERIC; v_bad BOOLEAN;
BEGIN
  ok := FALSE;
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN
    reason_code := 'UNKNOWN_CALLER'; reason := 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.';
    RETURN NEXT; RETURN;
  END IF;
  customer_id := v_cid;
  SELECT count(*) INTO n FROM find_my_account(v_cid, p_account);
  IF n <> 1 THEN
    reason_code := 'ACCOUNT_NOT_FOUND';
    reason := 'ACCOUNT_NOT_FOUND: no single active checking or savings account of this customer matches '
              || coalesce(nullif(trim(p_account), ''), '(blank)') || '. Use get_my_accounts and pass the account_id.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO a FROM find_my_account(v_cid, p_account);
  account_id := a.account_id; account_masked := a.account_number_masked; account_type := a.account_type;
  SELECT count(*) INTO n FROM find_my_payee(v_cid, p_payee);
  IF n <> 1 THEN
    reason_code := 'PAYEE_NOT_FOUND';
    reason := 'PAYEE_NOT_FOUND: no single saved payee of this customer matches ' || coalesce(nullif(trim(p_payee), ''), '(blank)')
              || '. Payments go only to saved payees (get_my_payees); new payees are added in the Kestrel app.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO p FROM find_my_payee(v_cid, p_payee);
  payee_id := p.payee_id; payee_name := p.payee_name; payee_type := p.payee_type;
  v_bad := CASE WHEN v_txt ~ '^[0-9]+(\.[0-9]{1,2})?$' THEN v_txt::numeric <= 0 ELSE TRUE END;
  IF v_bad THEN
    reason_code := 'BAD_AMOUNT'; reason := 'BAD_AMOUNT: the amount must be a positive dollar amount, e.g. 1850 or 1850.00.';
    RETURN NEXT; RETURN;
  END IF;
  v_amt := v_txt::numeric; amount := v_amt;
  IF v_amt > a.available_balance THEN
    reason_code := 'INSUFFICIENT_FUNDS';
    reason := 'INSUFFICIENT_FUNDS: the amount is more than the available balance of that account (' || usd(a.available_balance) || ').';
    RETURN NEXT; RETURN;
  END IF;
  v_today := sent_today(v_cid);
  IF v_today + v_amt > payment_daily_limit() THEN
    reason_code := 'OVER_DAILY_LIMIT';
    reason := 'OVER_DAILY_LIMIT: payments to payees are limited to ' || usd(payment_daily_limit()) || ' per day; '
              || usd(greatest(0, payment_daily_limit() - v_today)) || ' is left today.';
    RETURN NEXT; RETURN;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE'; reason := 'ELIGIBLE';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Scam assessment: the agent's narrative (validated) + deterministic signals -> points -> band. The weights live here,
-- not in any prompt. HIGH_RISK indicator 4, CAUTION indicator 1, narrative score 0-4 (score / 25), NEW_PAYEE 2,
-- FIRST_PAYEE_TYPE 1, AMOUNT_UNUSUAL 2, LARGE_SHARE_OF_BALANCE 1, PAYEE_ON_HOLD 7, HIGH_RISK_PROFILE 2 (new payee + first
-- payee of its kind + unusual amount: HIGH from the bank's own data alone, whatever the agent's indicators say).
-- >= 7 HIGH, >= 4 MEDIUM, else LOW.
CREATE OR REPLACE FUNCTION scam_assessment(p_customer TEXT, p_account TEXT, p_payee TEXT, p_amount NUMERIC,
                                           p_indicators TEXT, p_score TEXT)
RETURNS TABLE (narrative_indicators TEXT, ignored_indicators TEXT, narrative_score INTEGER, signals TEXT,
               risk_points INTEGER, risk_band TEXT) AS $$
#variable_conflict use_column
DECLARE v_high INTEGER; v_caution INTEGER; v_valid TEXT; v_ignored TEXT; v_score INTEGER; v_sig TEXT[] := ARRAY[]::text[];
        v_pts INTEGER; p payees; a accounts; v_max NUMERIC; v_s TEXT := btrim(coalesce(p_score, ''));
BEGIN
  WITH w AS (SELECT DISTINCT upper(regexp_replace(btrim(x), '[^A-Za-z_]', '', 'g')) AS code
               FROM regexp_split_to_table(coalesce(p_indicators, ''), '[,;[:space:]]+') x),
       v AS (SELECT w.code, g.section FROM w
               LEFT JOIN scam_signal_guide g ON g.term = w.code AND g.section IN ('HIGH_RISK', 'CAUTION')
              WHERE w.code NOT IN ('', 'NONE', 'NA', 'N_A'))
  SELECT count(*) FILTER (WHERE v.section = 'HIGH_RISK'), count(*) FILTER (WHERE v.section = 'CAUTION'),
         string_agg(v.code, ', ' ORDER BY v.code) FILTER (WHERE v.section IS NOT NULL),
         string_agg(v.code, ', ' ORDER BY v.code) FILTER (WHERE v.section IS NULL)
    INTO v_high, v_caution, v_valid, v_ignored FROM v;
  v_score := CASE WHEN v_s ~ '^[0-9]{1,3}(\.[0-9]+)?$' THEN least(100, greatest(0, round(v_s::numeric)))::int ELSE 0 END;
  SELECT * INTO p FROM payees x WHERE x.payee_id = p_payee;
  SELECT * INTO a FROM accounts x WHERE x.account_id = p_account;
  IF p.last_paid_at IS NULL AND p.added_at > clock_timestamp() - INTERVAL '30 days' THEN v_sig := v_sig || 'NEW_PAYEE'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM payees o WHERE o.customer_id = p_customer AND o.payee_type = p.payee_type
                                         AND o.last_paid_at IS NOT NULL) THEN
    v_sig := v_sig || 'FIRST_PAYEE_TYPE'::text;
  END IF;
  SELECT max(t.amount) INTO v_max FROM transactions t
   WHERE t.customer_id = p_customer AND t.txn_type = 'DEBIT' AND t.txn_date >= current_date - 90;
  IF p_amount > 500 AND p_amount > 3 * coalesce(v_max, 0) THEN v_sig := v_sig || 'AMOUNT_UNUSUAL'::text; END IF;
  IF p_amount >= 0.5 * a.available_balance THEN v_sig := v_sig || 'LARGE_SHARE_OF_BALANCE'::text; END IF;
  IF EXISTS (SELECT 1 FROM payment_requests r WHERE r.payee_id = p_payee AND r.status = 'HELD') THEN
    v_sig := v_sig || 'PAYEE_ON_HOLD'::text;
  END IF;
  IF 'NEW_PAYEE' = ANY (v_sig) AND 'FIRST_PAYEE_TYPE' = ANY (v_sig) AND 'AMOUNT_UNUSUAL' = ANY (v_sig) THEN
    v_sig := v_sig || 'HIGH_RISK_PROFILE'::text;
  END IF;
  v_pts := 4 * v_high + v_caution + v_score / 25
         + CASE WHEN 'NEW_PAYEE' = ANY (v_sig) THEN 2 ELSE 0 END
         + CASE WHEN 'FIRST_PAYEE_TYPE' = ANY (v_sig) THEN 1 ELSE 0 END
         + CASE WHEN 'AMOUNT_UNUSUAL' = ANY (v_sig) THEN 2 ELSE 0 END
         + CASE WHEN 'LARGE_SHARE_OF_BALANCE' = ANY (v_sig) THEN 1 ELSE 0 END
         + CASE WHEN 'PAYEE_ON_HOLD' = ANY (v_sig) THEN 7 ELSE 0 END
         + CASE WHEN 'HIGH_RISK_PROFILE' = ANY (v_sig) THEN 2 ELSE 0 END;
  narrative_indicators := v_valid; ignored_indicators := v_ignored; narrative_score := v_score;
  signals := nullif(array_to_string(v_sig, ', '), ''); risk_points := v_pts;
  risk_band := CASE WHEN v_pts >= 7 THEN 'HIGH' WHEN v_pts >= 4 THEN 'MEDIUM' ELSE 'LOW' END;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row for propose_payment: the assessed request is written ONLY when every payment rule passes, and not
-- twice (an unexpired PROPOSED or a HELD request for the same account / payee / amount is reused).
CREATE OR REPLACE FUNCTION payment_request_row(p_sub TEXT, p_account TEXT, p_payee TEXT, p_amount TEXT, p_story TEXT,
                                               p_indicators TEXT, p_score TEXT, p_notes TEXT)
RETURNS TABLE (customer_id TEXT, account_id TEXT, payee_id TEXT, amount NUMERIC, customer_story TEXT, agent_notes TEXT,
               narrative_indicators TEXT, ignored_indicators TEXT, narrative_score INTEGER, signals TEXT,
               risk_points INTEGER, risk_band TEXT, status TEXT, warning_required BOOLEAN) AS $$
  SELECT e.customer_id, e.account_id, e.payee_id, e.amount, left(coalesce(p_story, ''), 4000), left(coalesce(p_notes, ''), 4000),
         s.narrative_indicators, s.ignored_indicators, s.narrative_score, s.signals, s.risk_points, s.risk_band,
         CASE WHEN s.risk_band = 'HIGH' THEN 'HELD' ELSE 'PROPOSED' END, s.risk_band = 'MEDIUM'
    FROM payment_eval(p_sub, p_account, p_payee, p_amount) e
    CROSS JOIN LATERAL scam_assessment(e.customer_id, e.account_id, e.payee_id, e.amount, p_indicators, p_score) s
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM payment_requests r
                      WHERE r.customer_id = e.customer_id AND r.account_id = e.account_id AND r.payee_id = e.payee_id
                        AND r.amount = e.amount
                        AND ((r.status = 'PROPOSED' AND r.expires_at > clock_timestamp()) OR r.status = 'HELD'));
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION payment_warning_text() RETURNS TEXT AS $$
  SELECT 'Stop and check before you send this payment. Kestrel Bank, the police and government agencies will never ask you '
         || 'to move money to keep it safe, to pay for an investment that promises guaranteed or very high returns, or to '
         || 'keep a payment secret. A payment to another bank may not be recoverable once it is sent. If anyone contacted '
         || 'you about this payment, stop now and call Kestrel Bank on the number on the back of your card.'
$$ LANGUAGE sql IMMUTABLE;

-- Readback for propose_payment. The customer-facing outcome never carries the score, band or indicators.
CREATE OR REPLACE FUNCTION propose_payment_result(p_sub TEXT, p_account TEXT, p_payee TEXT, p_amount TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, payment_id TEXT, from_account TEXT, payee_name TEXT,
               amount NUMERIC, warning_text TEXT, case_id TEXT, team TEXT, reply_by DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; r payment_requests; c service_cases;
BEGIN
  SELECT * INTO e FROM payment_eval(p_sub, p_account, p_payee, p_amount);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  from_account := e.account_masked; payee_name := e.payee_name; amount := e.amount;
  IF NOT e.ok THEN RETURN NEXT; RETURN; END IF;
  SELECT * INTO r FROM payment_requests x
   WHERE x.customer_id = e.customer_id AND x.account_id = e.account_id AND x.payee_id = e.payee_id AND x.amount = e.amount
     AND ((x.status = 'PROPOSED' AND x.expires_at > clock_timestamp()) OR x.status = 'HELD')
   ORDER BY x.created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the payment could not be recorded. Try again.';
    RETURN NEXT; RETURN;
  END IF;
  payment_id := r.payment_id;
  IF r.status = 'HELD' THEN
    SELECT * INTO c FROM service_cases s WHERE s.case_id = r.case_id;
    outcome := 'HELD_FOR_REVIEW'; reason_code := 'HELD_FOR_REVIEW';
    reason := 'For your protection this payment is paused for a security check, and no money has left your account. '
              || 'A Kestrel fraud specialist will review it and contact you by ' || to_char(c.sla_due_at, 'YYYY-MM-DD')
              || '. Kestrel Bank will never ask you to move money to keep it safe. Please do not send this money another '
              || 'way in the meantime.';
    case_id := c.case_id; team := c.assigned_team; reply_by := c.sla_due_at::date;
  ELSIF r.warning_required THEN
    outcome := 'PROPOSED_WITH_WARNING'; reason_code := 'WARNING_REQUIRED';
    reason := 'Nothing has been sent. Read the warning_text to the customer word for word; send only if they then say they '
              || 'have read it and still want to go ahead (confirm_payment with acknowledge_warning YES).';
    warning_text := payment_warning_text(); expires_at := r.expires_at;
  ELSE
    outcome := 'PROPOSED'; reason_code := 'PROPOSED';
    reason := 'Awaiting the customer''s explicit yes. Nothing has been sent yet.'; expires_at := r.expires_at;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION ack_yes(p TEXT) RETURNS BOOLEAN AS $$
  SELECT upper(trim(coalesce(p, ''))) IN ('YES', 'Y', 'TRUE', 'ACKNOWLEDGED', 'I ACKNOWLEDGE', 'CONFIRMED', 'I UNDERSTAND')
$$ LANGUAGE sql IMMUTABLE;

-- Confirm row: VOLATILE because it counts confirm calls (so a repeat confirm reads ALREADY_SENT). Returns the
-- payment_sends row ONLY for this customer's PROPOSED, unexpired request whose rules still pass (and, for a MEDIUM
-- request, only when the customer acknowledged the warning).
CREATE OR REPLACE FUNCTION payment_confirmation_row(p_sub TEXT, p_payment TEXT, p_ack TEXT)
RETURNS TABLE (payment_id TEXT, via TEXT, case_id TEXT, amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; r payment_requests; e RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM payment_requests x WHERE x.payment_id = norm_ref(p_payment) AND x.customer_id = v_cid;
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE payment_requests x SET confirm_count = x.confirm_count + 1 WHERE x.payment_id = r.payment_id;
  IF r.status <> 'PROPOSED' OR r.expires_at <= clock_timestamp() THEN RETURN; END IF;
  IF r.warning_required AND NOT ack_yes(p_ack) THEN RETURN; END IF;
  SELECT * INTO e FROM payment_eval(p_sub, r.account_id, r.payee_id, r.amount::text);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT r.payment_id::text, 'CUSTOMER'::text, NULL::text, r.amount;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_payment_result(p_sub TEXT, p_payment TEXT, p_ack TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, payment_id TEXT, payee_name TEXT, amount NUMERIC,
               from_account TEXT, sent_at TIMESTAMP, available_balance_after NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; r payment_requests; s payment_sends; e RECORD;
BEGIN
  outcome := 'NOT_SENT';
  SELECT sc.customer_id INTO v_cid FROM caller_customer(p_sub) sc;
  IF v_cid IS NULL THEN
    reason_code := 'UNKNOWN_CALLER'; reason := 'UNKNOWN_CALLER: the signed-in identity is not a Kestrel Bank customer. Nothing was read or changed.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO r FROM payment_requests x WHERE x.payment_id = norm_ref(p_payment) AND x.customer_id = v_cid;
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_PAYMENT'; reason := 'NO_SUCH_PAYMENT: no payment with that id for this customer. Call propose_payment first.';
    RETURN NEXT; RETURN;
  END IF;
  payment_id := r.payment_id; amount := r.amount;
  SELECT p.payee_name INTO payee_name FROM payees p WHERE p.payee_id = r.payee_id;
  SELECT a.account_number_masked, a.available_balance INTO from_account, available_balance_after FROM accounts a WHERE a.account_id = r.account_id;
  SELECT * INTO s FROM payment_sends x WHERE x.payment_id = r.payment_id;
  IF FOUND THEN
    sent_at := s.sent_at;
    IF s.via = 'CUSTOMER' AND r.executed_confirm_no = r.confirm_count THEN
      outcome := 'SENT'; reason_code := 'SENT'; reason := 'Payment sent.';
    ELSE
      reason_code := 'ALREADY_SENT'; reason := 'ALREADY_SENT: this payment was already sent. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  available_balance_after := NULL;
  IF r.status = 'HELD' THEN
    reason_code := 'HELD_FOR_REVIEW';
    reason := 'HELD_FOR_REVIEW: this payment is paused for a security check by the fraud team. It cannot be sent from here.';
  ELSIF r.status = 'CANCELLED' THEN
    reason_code := 'CANCELLED'; reason := 'CANCELLED: this payment was stopped after a security review. No money moved.';
  ELSIF r.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the payment proposal expired after 15 minutes. Propose it again.';
  ELSIF r.warning_required AND NOT ack_yes(p_ack) THEN
    reason_code := 'WARNING_NOT_ACKNOWLEDGED';
    reason := 'WARNING_NOT_ACKNOWLEDGED: this payment can only be sent after the customer has read the warning and says '
              || 'they still want to go ahead.';
  ELSE
    SELECT * INTO e FROM payment_eval(p_sub, r.account_id, r.payee_id, r.amount::text);
    reason_code := e.reason_code; reason := e.reason;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- A HIGH request is HELD: open the PAYMENT_HOLD case for Fraud Operations (routing from service_teams), with a brief
-- built from the validated indicators, the deterministic signals and the agent's notes (reviewer-only).
CREATE OR REPLACE FUNCTION apply_payment_request() RETURNS TRIGGER AS $$
DECLARE p payees; t service_teams; v_case TEXT;
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (NEW.customer_id, 'PAYMENT_PROPOSED', NEW.payment_id,
            usd(NEW.amount) || ' to ' || NEW.payee_id || ' from ' || NEW.account_id || ': band ' || NEW.risk_band
            || ' (' || NEW.risk_points || ' points), status ' || NEW.status);
  IF NEW.status = 'HELD' THEN
    SELECT * INTO p FROM payees WHERE payee_id = NEW.payee_id;
    SELECT * INTO t FROM service_teams WHERE request_type = 'PAYMENT_HOLD';
    INSERT INTO service_cases (customer_id, request_type, customer_statement, agent_brief, assigned_team, requested_amount,
                               parked_action, created_at)
      VALUES (NEW.customer_id, 'PAYMENT_HOLD', coalesce(nullif(NEW.customer_story, ''), '(no statement)'),
              'SYSTEM: payment ' || NEW.payment_id || ' of ' || usd(NEW.amount) || ' to ' || p.payee_name || ' (' || p.payee_type
              || ') was HELD: risk band HIGH, ' || NEW.risk_points || ' points.' || chr(10)
              || 'Scam indicators from the AI agent (validated against the guide): ' || coalesce(NEW.narrative_indicators, 'none')
              || '; narrative score ' || NEW.narrative_score || '.' || chr(10)
              || 'Deterministic signals: ' || coalesce(NEW.signals, 'none') || '.' || chr(10)
              || 'Agent notes (AI-prepared, unverified): ' || coalesce(nullif(NEW.agent_notes, ''), '(none)'),
              t.team, NEW.amount, 'RELEASE_PAYMENT:' || NEW.payment_id, NEW.created_at)
      RETURNING case_id INTO v_case;
    UPDATE payment_requests SET case_id = v_case WHERE payment_id = NEW.payment_id;
    INSERT INTO agent_audit (customer_id, action, ref, detail)
      VALUES (NEW.customer_id, 'PAYMENT_HELD', NEW.payment_id, 'held for review in ' || v_case);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_payment_request AFTER INSERT ON payment_requests FOR EACH ROW EXECUTE FUNCTION apply_payment_request();

-- Side effects of a sent payment, atomically: the POSTED debit, the balance, the payee's last-paid date, the status.
CREATE OR REPLACE FUNCTION apply_payment_send() RETURNS TRIGGER AS $$
DECLARE r payment_requests; p payees;
BEGIN
  SELECT * INTO r FROM payment_requests WHERE payment_id = NEW.payment_id;
  SELECT * INTO p FROM payees WHERE payee_id = r.payee_id;
  INSERT INTO transactions (account_id, customer_id, card_id, txn_date, descriptor, amount, txn_type, category, status)
    VALUES (r.account_id, r.customer_id, NULL, NEW.sent_at::date, left('PAYMENT TO ' || upper(p.payee_name), 80), NEW.amount,
            'DEBIT', 'TRANSFER', 'POSTED');
  UPDATE accounts SET balance = balance - NEW.amount, available_balance = available_balance - NEW.amount
   WHERE account_id = r.account_id;
  UPDATE payees SET last_paid_at = NEW.sent_at WHERE payee_id = r.payee_id;
  UPDATE payment_requests SET status = CASE WHEN NEW.via = 'REVIEWER' THEN 'RELEASED' ELSE 'SENT' END,
         executed_confirm_no = CASE WHEN NEW.via = 'CUSTOMER' THEN confirm_count END
   WHERE payment_id = NEW.payment_id;
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (r.customer_id, 'PAYMENT_SENT', NEW.payment_id,
            usd(NEW.amount) || ' to ' || r.payee_id || ' via ' || NEW.via || coalesce(' (case ' || NEW.case_id || ')', ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_payment_send AFTER INSERT ON payment_sends FOR EACH ROW EXECUTE FUNCTION apply_payment_send();

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================

-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE split_part(coalesce(s.parked_action, ''), ':', 1)
           WHEN 'FEE_REFUND' THEN (SELECT t.amount FROM transactions t WHERE t.transaction_id = split_part(s.parked_action, ':', 2))
           WHEN 'LOAN_DEFERRAL' THEN (SELECT deferral_max_payments() * l.monthly_payment FROM loans l
                                       WHERE l.loan_id = split_part(s.parked_action, ':', 2))
           WHEN 'RELEASE_PAYMENT' THEN (SELECT r.amount FROM payment_requests r WHERE r.payment_id = split_part(s.parked_action, ':', 2))
           ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no email, phone or full last name).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE split_part(coalesce(s.parked_action, ''), ':', 1)
    WHEN 'FEE_REFUND' THEN
      'Fee ' || t.transaction_id || ' "' || t.descriptor || '" on ' || to_char(t.txn_date, 'YYYY-MM-DD') || ' for ' || usd(t.amount)
      || ' on ' || a.account_type || ' account ' || a.account_number_masked
      || '; fees charged to this customer in the last 12 months: '
      || (SELECT count(*) FROM transactions f WHERE f.customer_id = s.customer_id AND f.category = 'FEES' AND f.txn_date > current_date - 365)
      || '; fees refunded in the last 12 months: '
      || (SELECT count(*) FROM transactions f WHERE f.customer_id = s.customer_id AND f.category = 'FEE_REFUND' AND f.txn_date > current_date - 365)
    WHEN 'LOAN_DEFERRAL' THEN
      l.loan_type || ' loan ' || l.loan_id || ': monthly payment ' || usd(l.monthly_payment) || ', outstanding '
      || usd(l.outstanding_balance) || ', rate ' || l.interest_rate || ' percent, next due ' || to_char(l.next_due_date, 'YYYY-MM-DD')
      || ', status ' || l.status || '; the standard deferral is up to ' || deferral_max_payments() || ' payments ('
      || usd(deferral_max_payments() * l.monthly_payment) || '); deferrals on this loan in the last 12 months: '
      || (SELECT count(*) FROM loan_deferrals x WHERE x.loan_id = l.loan_id AND x.created_at > clock_timestamp() - INTERVAL '365 days')
    WHEN 'RELEASE_PAYMENT' THEN
      'Payment ' || r.payment_id || ' of ' || usd(r.amount) || ' from ' || ra.account_type || ' ' || ra.account_number_masked
      || ' to ' || p.payee_name || ' (' || p.payee_type || ', ' || p.bank_name || ' ' || p.account_masked || '), payee added '
      || to_char(p.added_at, 'YYYY-MM-DD HH24:MI')
      || CASE WHEN p.last_paid_at IS NULL THEN ', never paid before' ELSE ', last paid ' || to_char(p.last_paid_at, 'YYYY-MM-DD') END
      || '; risk band ' || r.risk_band || ' (' || r.risk_points || ' points); scam indicators: ' || coalesce(r.narrative_indicators, 'none')
      || '; deterministic signals: ' || coalesce(r.signals, 'none') || '; payment status ' || r.status
    ELSE
      CASE WHEN d.dispute_id IS NOT NULL THEN
        'Dispute ' || d.dispute_id || ' on ' || d.transaction_id || ' (' || dt.descriptor || ', ' || usd(d.amount) || ', reason '
        || d.reason_code || ', provisional credit ' || usd(d.provisional_credit) || ', status ' || d.status || ')'
      ELSE 'No linked record.' END
    END
    FROM service_cases s
    LEFT JOIN transactions t ON t.transaction_id = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'FEE\_REFUND:%'
    LEFT JOIN accounts a ON a.account_id = t.account_id
    LEFT JOIN loans l ON l.loan_id = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'LOAN\_DEFERRAL:%'
    LEFT JOIN payment_requests r ON r.payment_id = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'RELEASE\_PAYMENT:%'
    LEFT JOIN accounts ra ON ra.account_id = r.account_id
    LEFT JOIN payees p ON p.payee_id = r.payee_id
    LEFT JOIN disputes d ON d.dispute_id = s.dispute_id
    LEFT JOIN transactions dt ON dt.transaction_id = d.transaction_id
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue: OPEN cases ordered by reply-due time. Another team's cases never appear.
CREATE OR REPLACE FUNCTION review_queue(p_sub TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, customer TEXT, opened_on DATE, age_days INTEGER,
               reply_due DATE, sla_status TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.customer, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested_amount
    FROM (SELECT * FROM caller_reviewer(p_sub)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, t.label, customer_display(s.customer_id) AS customer, s.created_at::date AS opened_on,
             (current_date - s.created_at::date)::int AS age_days, s.sla_due_at::date AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.sla_due_at
        FROM service_cases s JOIN service_teams t ON t.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND t.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at, q.case_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_sub TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, customer TEXT, opened_on DATE,
               reply_due DATE, customer_statement TEXT, agent_brief TEXT, requested_amount NUMERIC, max_approvable NUMERIC,
               your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, t.label, s.status, customer_display(s.customer_id), s.created_at::date, s.sla_due_at::date,
         s.customer_statement, s.agent_brief, s.requested_amount, case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.parked_action LIKE 'RELEASE\_PAYMENT:%' THEN 'APPROVE releases the held payment in full ('
                   || usd(case_eligible_max(s.case_id)) || ')'
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN ' - above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer' ELSE '' END
                   || '; REJECT cancels it (no money moves). Give an internal note and a message for the customer.'
              WHEN case_eligible_max(s.case_id) IS NOT NULL THEN 'APPROVE (any amount up to ' || usd(case_eligible_max(s.case_id))
                   || CASE WHEN s.parked_action LIKE 'LOAN\_DEFERRAL:%' THEN ', in whole monthly payments' ELSE '' END
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN '; above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer' ELSE '' END
                   || ') or REJECT, with an internal note and a message for the customer.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the customer.' END,
         s.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM caller_reviewer(p_sub)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT x.request_type FROM service_teams x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN service_teams t ON t.request_type = s.request_type;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked. Two steps, like the
-- customer's propose / confirm: a valid decision is first only recorded as CONFIRM_REQUIRED; the same decision and
-- amount again within 15 minutes (after the reviewer said yes) writes the decision row.
CREATE OR REPLACE FUNCTION decide_case_row(p_sub TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT,
               customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; t service_teams; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_txt TEXT := norm_amount(p_amount); v_msg TEXT; v_pay NUMERIC; v_n INTEGER; v_problem TEXT; pa decide_attempts;
BEGIN
  SELECT * INTO rv FROM caller_reviewer(p_sub) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM service_cases x WHERE x.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT * INTO t FROM service_teams x WHERE x.request_type = s.request_type;
  IF t.team <> rv.team THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_YOUR_TEAM', 'That case is not in your team''s queue, so you cannot decide it.');
    RETURN;
  END IF;
  IF s.status <> 'OPEN' THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ALREADY_DECIDED', 'This case was already decided (' || s.status || '). Nothing was changed.');
    RETURN;
  END IF;
  v_dec := CASE upper(trim(coalesce(p_decision, ''))) WHEN 'APPROVE' THEN 'APPROVE' WHEN 'APPROVED' THEN 'APPROVE'
                WHEN 'REJECT' THEN 'REJECT' WHEN 'REJECTED' THEN 'REJECT' WHEN 'DENY' THEN 'REJECT' WHEN 'DENIED' THEN 'REJECT' END;
  IF v_dec IS NULL THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'INVALID_DECISION', 'The decision must be APPROVE or REJECT.');
    RETURN;
  END IF;
  IF length(trim(coalesce(p_note, ''))) < 5 THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOTE_REQUIRED', 'An internal note of at least 5 characters is required for every decision.');
    RETURN;
  END IF;
  v_max := case_eligible_max(s.case_id);
  IF v_dec = 'APPROVE' AND v_max IS NOT NULL THEN
    v_amt := CASE WHEN v_txt = '' OR v_txt = 'ALL' OR v_txt = 'FULL' THEN v_max
                  WHEN v_txt ~ '^-?[0-9]+(\.[0-9]+)?$' THEN round(v_txt::numeric, 2) END;
    IF s.parked_action LIKE 'LOAN\_DEFERRAL:%' AND v_amt IS NOT NULL THEN              -- whole monthly payments only
      SELECT l.monthly_payment INTO v_pay FROM loans l WHERE l.loan_id = split_part(s.parked_action, ':', 2);
      v_n := least(deferral_max_payments(), floor(v_amt / v_pay + 0.000001))::int;
      v_amt := CASE WHEN v_n >= 1 THEN v_n * v_pay ELSE 0 END;
    END IF;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max
       OR (s.parked_action LIKE 'RELEASE\_PAYMENT:%' AND v_amt <> v_max) THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID',
                CASE WHEN s.parked_action LIKE 'RELEASE\_PAYMENT:%'
                     THEN 'A held payment is released in full (' || usd(v_max) || ') or rejected.'
                     WHEN s.parked_action LIKE 'LOAN\_DEFERRAL:%'
                     THEN 'The approved amount must cover at least one monthly payment and no more than ' || usd(v_max) || '.'
                     ELSE 'The approved amount must be more than $0 and no more than ' || usd(v_max) || ' for this case.' END);
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', usd(v_amt) || ' is above your approval limit of '
                || usd(rv.approval_limit) || '. The case stays open and needs a senior reviewer.');
      RETURN;
    END IF;
  END IF;
  IF v_dec = 'APPROVE' THEN
    v_problem := parked_action_problem(s.case_id, v_amt);
    IF v_problem IS NOT NULL THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ACTION_NOT_EXECUTABLE', v_problem);
      RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || t.label || ' has been approved' || coalesce(' for ' || usd(v_amt), '') || '.'
                  ELSE 'After review, your ' || t.label || ' was not approved. We will send you a letter that explains the decision.' END);
  SELECT * INTO pa FROM decide_attempts x
   WHERE x.reviewer_id = rv.reviewer_id AND x.case_ref = v_ref AND x.outcome = 'CONFIRM_REQUIRED'
   ORDER BY x.attempt_id DESC LIMIT 1;
  IF pa.attempt_id IS NULL OR pa.created_at < clock_timestamp() - INTERVAL '15 minutes'
     OR pa.decision IS DISTINCT FROM v_dec OR pa.approved_amount IS DISTINCT FROM v_amt THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text, decision, approved_amount, customer_message)
      VALUES (rv.reviewer_id, v_ref, 'CONFIRM_REQUIRED', 'CONFIRM_REQUIRED',
              'Nothing is recorded yet. Read this decision back to the reviewer and ask them to confirm: ' || v_dec
              || coalesce(' ' || usd(v_amt), '') || ' on ' || v_ref || '. Only after they confirm, call decide_review_case '
              || 'again with the same decision and amount (within 15 minutes).',
              v_dec, v_amt, left(v_msg, 2000));
    RETURN;
  END IF;
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_sub TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED','CONFIRM_REQUIRED')
                   OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION',
                                         'ACTION_NOT_EXECUTABLE')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision WHEN da.outcome = 'CONFIRM_REQUIRED' THEN da.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.approved_amount
              WHEN da.outcome = 'CONFIRM_REQUIRED' THEN da.approved_amount END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only an active Kestrel staff reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND'
                   AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'Fee ' || split_part(s.parked_action, ':', 2) || ' refunded: ' || usd(f.amount) || ' credited ('
                                 || f.transaction_id || ').'
                            FROM transactions f
                           WHERE s.parked_action LIKE 'FEE\_REFUND:%' AND f.descriptor = 'FEE REFUND ' || split_part(s.parked_action, ':', 2)
                           LIMIT 1),
                         (SELECT 'Loan ' || x.loan_id || ': ' || x.payments_deferred || ' monthly payment(s) (' || usd(x.deferred_amount)
                                 || ') deferred; next due date moved from ' || to_char(x.old_due_date, 'YYYY-MM-DD') || ' to '
                                 || to_char(x.new_due_date, 'YYYY-MM-DD') || ' (' || x.deferral_id || ').'
                            FROM loan_deferrals x WHERE x.case_id = s.case_id),
                         (SELECT 'Payment ' || ps.payment_id || ' of ' || usd(ps.amount) || ' released and sent.'
                            FROM payment_sends ps WHERE ps.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN
                CASE WHEN s.parked_action LIKE 'RELEASE\_PAYMENT:%' THEN 'Case rejected; the held payment was cancelled and no money moved.'
                     ELSE 'Case rejected; nothing was executed.' END END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message
              WHEN da.outcome = 'CONFIRM_REQUIRED' THEN da.customer_message END
    FROM (SELECT * FROM caller_reviewer(p_sub)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id;
$$ LANGUAGE sql STABLE;

-- Guarded rows the decision trigger uses to execute the parked action (the same checks every time).
CREATE OR REPLACE FUNCTION fee_refund_row(p_txn TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (account_id VARCHAR, customer_id VARCHAR, card_id VARCHAR, txn_date DATE, descriptor VARCHAR, amount NUMERIC,
               txn_type VARCHAR, category VARCHAR, status VARCHAR) AS $$
  SELECT t.account_id, t.customer_id, NULL::varchar, current_date, ('FEE REFUND ' || t.transaction_id)::varchar, p_amount,
         'CREDIT'::varchar, 'FEE_REFUND'::varchar, 'POSTED'::varchar
    FROM transactions t
   WHERE t.transaction_id = p_txn AND t.txn_type = 'DEBIT' AND t.category = 'FEES' AND t.status = 'POSTED'
     AND p_amount > 0 AND p_amount <= t.amount AND NOT fee_refunded(t.transaction_id)
     AND EXISTS (SELECT 1 FROM service_cases s WHERE s.case_id = p_case AND s.parked_action = 'FEE_REFUND:' || t.transaction_id);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION loan_deferral_row(p_loan TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (deferral_id TEXT, loan_id TEXT, case_id TEXT, payments_deferred INTEGER, deferred_amount NUMERIC,
               old_due_date DATE, new_due_date DATE) AS $$
  SELECT 'DEF-' || lpad(nextval('def_seq')::text, 5, '0'), l.loan_id::text, p_case, x.n, x.n * l.monthly_payment,
         l.next_due_date, (l.next_due_date + make_interval(months => x.n))::date
    FROM loans l
    CROSS JOIN LATERAL (SELECT least(deferral_max_payments(), floor(p_amount / l.monthly_payment + 0.000001))::int AS n) x
   WHERE l.loan_id = p_loan AND l.status = 'ACTIVE' AND x.n >= 1
     AND NOT EXISTS (SELECT 1 FROM loan_deferrals d WHERE d.case_id = p_case)
     AND EXISTS (SELECT 1 FROM service_cases s WHERE s.case_id = p_case AND s.parked_action = 'LOAN_DEFERRAL:' || l.loan_id);
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION payment_release_row(p_payment TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (payment_id TEXT, via TEXT, case_id TEXT, amount NUMERIC) AS $$
  SELECT r.payment_id::text, 'REVIEWER'::text, p_case, r.amount
    FROM payment_requests r JOIN accounts a ON a.account_id = r.account_id
   WHERE r.payment_id = p_payment AND r.status = 'HELD' AND r.case_id = p_case AND p_amount = r.amount
     AND a.status = 'ACTIVE' AND a.available_balance >= r.amount
     AND sent_today(r.customer_id) + r.amount <= payment_daily_limit()      -- a release counts toward the daily limit
     AND NOT EXISTS (SELECT 1 FROM payment_sends s WHERE s.payment_id = r.payment_id);
$$ LANGUAGE sql STABLE;

-- Why the parked action of an approval cannot run right now (NULL = it can). Checked before a decision is recorded, so
-- a case is never marked APPROVED (and the customer never told so) while its action silently does nothing.
CREATE OR REPLACE FUNCTION parked_action_problem(p_case TEXT, p_amount NUMERIC) RETURNS TEXT AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; r payment_requests; a accounts; v_today NUMERIC;
BEGIN
  SELECT * INTO s FROM service_cases x WHERE x.case_id = p_case;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF v_kind = 'FEE_REFUND' AND NOT EXISTS (SELECT 1 FROM fee_refund_row(v_ref, p_amount, p_case)) THEN
    RETURN 'Fee ' || v_ref || ' can no longer be refunded: it was already refunded or is no longer a posted fee.';
  ELSIF v_kind = 'LOAN_DEFERRAL' AND NOT EXISTS (
          SELECT 1 FROM loans l
           WHERE l.loan_id = v_ref AND l.status = 'ACTIVE' AND floor(p_amount / l.monthly_payment + 0.000001) >= 1
             AND NOT EXISTS (SELECT 1 FROM loan_deferrals d WHERE d.case_id = p_case)) THEN
    RETURN 'Loan ' || v_ref || ' can no longer be deferred: it is not active, or this case already deferred it.';
  ELSIF v_kind = 'RELEASE_PAYMENT' AND NOT EXISTS (SELECT 1 FROM payment_release_row(v_ref, p_amount, p_case)) THEN
    SELECT * INTO r FROM payment_requests x WHERE x.payment_id = v_ref;
    SELECT * INTO a FROM accounts x WHERE x.account_id = r.account_id;
    v_today := sent_today(r.customer_id);
    RETURN 'Payment ' || v_ref || ' cannot be released right now: '
        || CASE WHEN r.status IS DISTINCT FROM 'HELD' THEN 'it is no longer held (' || coalesce(r.status, 'not found') || ')'
                WHEN a.status IS DISTINCT FROM 'ACTIVE' THEN 'the account is not active'
                WHEN a.available_balance < r.amount
                  THEN 'the available balance (' || usd(a.available_balance) || ') no longer covers ' || usd(r.amount)
                WHEN v_today + r.amount > payment_daily_limit()
                  THEN 'it would take today''s payments over the ' || usd(payment_daily_limit()) || ' daily limit ('
                       || usd(v_today) || ' already sent today)'
                ELSE 'its checks did not pass' END
        || '. The case stays open: reject it, or approve it again once that changes.';
  END IF;
  RETURN NULL;
END $$ LANGUAGE plpgsql STABLE;

-- The decision event: case status + customer message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'nothing'; v_acct TEXT;
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF NEW.decision = 'APPROVE' AND v_kind = 'FEE_REFUND' THEN
    INSERT INTO transactions (account_id, customer_id, card_id, txn_date, descriptor, amount, txn_type, category, status)
      SELECT * FROM fee_refund_row(v_ref, NEW.approved_amount, NEW.case_id) RETURNING account_id INTO v_acct;
    IF v_acct IS NOT NULL THEN
      UPDATE accounts SET balance = balance + NEW.approved_amount, available_balance = available_balance + NEW.approved_amount
       WHERE account_id = v_acct;
      v_done := 'fee ' || v_ref || ' refunded ' || usd(NEW.approved_amount);
    END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'LOAN_DEFERRAL' THEN
    INSERT INTO loan_deferrals (deferral_id, loan_id, case_id, payments_deferred, deferred_amount, old_due_date, new_due_date)
      SELECT * FROM loan_deferral_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'loan ' || v_ref || ' deferral of ' || usd(NEW.approved_amount); END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'RELEASE_PAYMENT' THEN
    INSERT INTO payment_sends (payment_id, via, case_id, amount)
      SELECT * FROM payment_release_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'payment ' || v_ref || ' released ' || usd(NEW.approved_amount); END IF;
  ELSIF NEW.decision = 'REJECT' AND v_kind = 'RELEASE_PAYMENT' THEN
    UPDATE payment_requests SET status = 'CANCELLED' WHERE payment_id = v_ref AND status = 'HELD';
    v_done := 'payment ' || v_ref || ' cancelled (no money moved)';
  END IF;
  INSERT INTO agent_audit (customer_id, actor, action, ref, detail)
    VALUES (s.customer_id, NEW.reviewer_id, 'CASE_DECIDED', NEW.case_id,
            NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- An approved deferral moves the loan's next due date (event row + trigger, never an UPDATE from a tool).
CREATE OR REPLACE FUNCTION apply_loan_deferral() RETURNS TRIGGER AS $$
BEGIN
  UPDATE loans SET next_due_date = NEW.new_due_date WHERE loan_id = NEW.loan_id;
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    SELECT l.customer_id, 'LOAN_DEFERRED', NEW.deferral_id,
           NEW.loan_id || ': ' || NEW.payments_deferred || ' payment(s) ' || usd(NEW.deferred_amount) || ', due '
           || to_char(NEW.old_due_date, 'YYYY-MM-DD') || ' -> ' || to_char(NEW.new_due_date, 'YYYY-MM-DD') || ' (case ' || NEW.case_id || ')'
      FROM loans l WHERE l.loan_id = NEW.loan_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_loan_deferral AFTER INSERT ON loan_deferrals FOR EACH ROW EXECUTE FUNCTION apply_loan_deferral();

-- =====================================================================
-- AGENT REFERENCE READS - the only SQL the scam_signal_agent and hardship_intake_agent tools run
-- (SELECT * FROM ref_<topic>(CAST(?lookup AS text))). SELECT-only, STABLE, no identity argument. p_term is the one
-- value the model may supply: empty / NULL -> the whole guide; otherwise one or more words separated by , or ; - a row
-- matches when a word equals its section (spaces = underscores) or appears in its term or meaning (plain substring, no
-- wildcards). Unknown words -> 0 rows (never an error). (The dispute_triage_agent keeps its lookup_merchant() read.)
-- =====================================================================
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION ref_scam_signals(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM scam_signal_guide g
          UNION ALL                                 -- who reviews a held payment: service_teams is the source of truth
          SELECT 'WHO_DECIDES', t.label::text,
                 t.team::text || ' reviews it and replies within ' || t.reply_business_days || ' business day(s); '
                 || 'the payment does not move until a person decides.', 1000
            FROM service_teams t WHERE t.request_type = 'PAYMENT_HOLD') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['HIGH_RISK','CAUTION','PAYEE_TYPE','SCORE_RULE','REVIEW_STEP','WHO_DECIDES'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_hardship_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM hardship_guide g
          UNION ALL                                 -- who decides a hardship request: service_teams is the source of truth
          SELECT 'WHO_DECIDES', t.label::text,
                 t.team::text || ' decides it and replies within ' || t.reply_business_days || ' business day(s).', 1000
            FROM service_teams t WHERE t.request_type = 'LOAN_HARDSHIP') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CAUSE','DURATION','PRODUCT','PROGRAM','DOCUMENT','SUPPORT_LINE','BRIEF_RULE','WHO_DECIDES'],
                           r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
