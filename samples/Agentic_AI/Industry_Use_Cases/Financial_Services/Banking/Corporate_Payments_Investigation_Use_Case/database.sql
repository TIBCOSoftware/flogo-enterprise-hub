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
--                              that PARKS the recall (RECALL:<payment>) for a reviewer to decide
--   * lookup_reason_code()     return/reason-code decoding for the A2A payment_triage_agent - NO client identity
--   * cash_assessment()        cash application: the remittance_match_agent's invoice matches and deductions are
--                              VALIDATED against the client's open invoices and the deduction list; SQL computes the
--                              earned early-pay discount, the residual and what is disputed. Small disputed amounts are
--                              written off under the tolerance; larger ones park a DEDUCTION_WRITE_OFF for Client Servicing
--   * payee_assessment()       verification of payee: the payee_name_match_agent's verdict and reasons are VALIDATED and
--                              combined with a deterministic name score (normalised with the guide's own suffix,
--                              abbreviation and transliteration rows) into MATCH / CLOSE_MATCH / NO_MATCH. MATCH -> two-step
--                              confirm; CLOSE_MATCH up to the threshold -> a warning the client must acknowledge;
--                              CLOSE_MATCH over it or NO_MATCH -> HELD + a PAYEE_VERIFICATION case for Payment Operations
--   * case_parking()           a human-owned case parks a typed action (FEE_REFUND:<payment> / RECALL:<payment> /
--                              RELEASE_PAYMENT:<request> / DEDUCTION_WRITE_OFF:<application>) that runs ONLY on approval
--   * service_teams            human-owned requests (recall, fee waiver, fraud, sanctions...) routed by a table
--   * reviewers + decide_case_row()  the human-in-the-loop: a staff reviewer (role REVIEWER, own team only, approval
--                              limit) decides; review_decisions + trg_review_decision execute the parked action through
--                              the same guarded row functions, and audit it (CASE_DECIDED)
--   * ref_remittance_guide() / ref_payee_name_rules()  the new agents' read-only reference tables - NO client identity
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The genuinely semantic steps are the three A2A agents: payment_triage_agent (which payment, what the return code
-- means), remittance_match_agent (free-text remittance / short-pay note -> invoices + deduction reasons) and
-- payee_name_match_agent (typed beneficiary name vs the account name on file).
-- Aurelia Global Bank, its clients, staff, accounts, buyers, beneficiaries and payments are fictional.
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

DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, deduction_writeoffs, fee_refunds,
  payment_recalls, payment_releases, payment_requests, payee_register, cash_postings, cash_applications, open_invoices,
  review_cases, service_teams, investigations, pending_actions, reviewer_verify_attempts, verify_attempts,
  client_sessions, reviewers, payment_events, payments, cutoff_rules, reason_codes, remittance_guide, payee_name_guide,
  accounts, clients CASCADE;
DROP SEQUENCE IF EXISTS inv_seq, case_seq, pmt_seq, cap_seq, prq_seq, wo_seq;

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

CREATE SEQUENCE pmt_seq START 101;   -- seeded payments are PMT-2026-000001..; payments submitted in chat start at 000101
CREATE TABLE payments (
  payment_ref          VARCHAR(20) PRIMARY KEY DEFAULT 'PMT-2026-' || lpad(nextval('pmt_seq')::text, 6, '0'),
  client_id            VARCHAR(20) NOT NULL REFERENCES clients,
  debtor_account       VARCHAR(20) REFERENCES accounts,
  direction            VARCHAR(10) NOT NULL CHECK (direction IN ('OUTGOING','INCOMING')),
  rail                 VARCHAR(16) NOT NULL CHECK (rail IN ('SWIFT','SEPA','FEDWIRE','FASTER_PAYMENTS','ACH')),
  amount               NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency             VARCHAR(3) NOT NULL,
  fx_rate              NUMERIC(12,6),                 -- NULL when no conversion
  fees                 NUMERIC(10,2) NOT NULL DEFAULT 0,
  beneficiary_name     VARCHAR(80) NOT NULL,          -- INCOMING: the client itself
  beneficiary_bank_bic VARCHAR(16) NOT NULL,
  ordering_party       VARCHAR(80),                   -- INCOMING: who paid the client (the buyer)
  remittance_info      VARCHAR(200),                  -- INCOMING: the remittance text the payer sent with the funds
  status               VARCHAR(20) NOT NULL DEFAULT 'INITIATED'
                         CHECK (status IN ('INITIATED','IN_TRANSIT','COMPLETED','RETURNED','HELD','RECALL_REQUESTED','RECALLED')),
  status_before_recall VARCHAR(20),                   -- restored if Payment Operations declines the recall
  return_reason_code   VARCHAR(8) REFERENCES reason_codes,   -- set only when RETURNED
  value_date           DATE NOT NULL,
  created_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE pmt_seq OWNED BY payments.payment_ref;

-- GPI-style event timeline for a payment (one row per processing step).
CREATE TABLE payment_events (
  id           SERIAL PRIMARY KEY,
  payment_ref  VARCHAR(20) NOT NULL REFERENCES payments,
  event_time   TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  actor        VARCHAR(60) NOT NULL,                 -- agent/correspondent bank or 'Aurelia Global Bank'
  action       VARCHAR(40) NOT NULL,
  detail       VARCHAR(200)
);

-- Agent reference tables: what the remittance_match_agent and payee_name_match_agent may read (through ref_*
-- functions only). Same shape for both - section / term / meaning - and NO client, account, payment, invoice, buyer,
-- staff, case, session or contact data, ever. The "who decides" rows are NOT copied here: the ref_* functions read
-- them from service_teams (one source of truth). SQL itself uses payee_name_guide's LEGAL_SUFFIX / ABBREVIATION /
-- TRANSLITERATION rows to normalise names, so the agent and the deterministic check share one rule set.
CREATE TABLE remittance_guide (                  -- remittance_match_agent: deduction reasons, note patterns, rules
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('DEDUCTION', 'NOTE_PATTERN', 'MATCH_RULE', 'CONFIDENCE',
                                                      'REVIEW_LINE')),
  term        VARCHAR(60) NOT NULL,              -- FREIGHT
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE payee_name_guide (                  -- payee_name_match_agent: suffixes, abbreviations, verdicts, reasons
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('LEGAL_SUFFIX', 'ABBREVIATION', 'TRANSLITERATION', 'REASON',
                                                      'VERDICT')),
  term        VARCHAR(60) NOT NULL,              -- LTD  /  INTL = INTERNATIONAL  /  Ü = U  /  MISSING_WORD
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- Staff reviewers (the human in the loop). team matches service_teams.team.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- AGB-5001 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(60) NOT NULL,
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN: demo stand-in for the staff sign-in code
  approval_limit  NUMERIC(14,2),                 -- NULL = no limit (compared with the case amount, case currency)
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role (client and reviewer tokens are not
-- interchangeable).
CREATE TABLE client_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL DEFAULT 'CLIENT' CHECK (role IN ('CLIENT','REVIEWER')),
  client_id      VARCHAR(20) REFERENCES clients,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes',
  CHECK ((role = 'CLIENT' AND client_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND client_id IS NULL))
);

-- Brute-force throttle for the passcode step: one row per attempt on a REAL client id.
CREATE TABLE verify_attempts (
  attempt_id  SERIAL PRIMARY KEY,
  client_id   VARCHAR(20) NOT NULL REFERENCES clients,
  ok          BOOLEAN NOT NULL,
  at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Same throttle for the staff code step (5 wrong codes in 15 minutes -> locked).
CREATE TABLE reviewer_verify_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  ok           BOOLEAN NOT NULL,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
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

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE service_teams (
  request_type         VARCHAR(24) PRIMARY KEY,
  label                VARCHAR(40) NOT NULL,          -- client-facing name
  team                 VARCHAR(60) NOT NULL,
  reply_business_days  INTEGER NOT NULL,
  client_openable      BOOLEAN NOT NULL DEFAULT TRUE  -- RECALL / PAYEE_VERIFICATION / DEDUCTION_REVIEW come only from the rules
);

CREATE SEQUENCE case_seq START 1;
CREATE TABLE review_cases (
  case_id           VARCHAR(12) PRIMARY KEY DEFAULT 'CASE-' || lpad(nextval('case_seq')::text, 5, '0'),
  action_id         TEXT UNIQUE REFERENCES pending_actions,     -- set for recall confirmations; NULL for other cases
  client_id         VARCHAR(20) NOT NULL REFERENCES clients,
  request_type      VARCHAR(24) NOT NULL REFERENCES service_teams,
  payment_ref       VARCHAR(20) REFERENCES payments,
  client_statement  TEXT NOT NULL,
  agent_brief       TEXT NOT NULL,            -- neutral summary by the assistant / an A2A agent / the system; never a decision
  assigned_team     VARCHAR(60) NOT NULL,
  currency          VARCHAR(3),               -- currency of requested_amount
  requested_amount  NUMERIC(14,2),            -- the fee, the recalled or held payment, the disputed deduction (NULL = none)
  parked_action     VARCHAR(40),              -- runs ONLY on approval: FEE_REFUND:<pmt> / RECALL:<pmt> /
                                              -- RELEASE_PAYMENT:<request> / DEDUCTION_WRITE_OFF:<application>
  status            VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at        TIMESTAMP,                -- set by trg_case_defaults from service_teams
  customer_message  TEXT,                     -- client-safe outcome text, set by the reviewer's decision
  approved_amount   NUMERIC(14,2),
  decided_at        TIMESTAMP,
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE case_seq OWNED BY review_cases.case_id;

-- Insert-only decision events (one per case). trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          VARCHAR(12) NOT NULL UNIQUE REFERENCES review_cases,
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(14,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from clients
  customer_message TEXT NOT NULL,
  decided_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every decide call by a verified reviewer (readback of the outcome and reason).
CREATE TABLE decide_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  case_ref     VARCHAR(40) NOT NULL,
  outcome      VARCHAR(10) NOT NULL,             -- APPROVED / REJECTED / BLOCKED
  reason_code  VARCHAR(24),
  reason_text  TEXT,
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Cash application (receivables): the client's open invoices, the assessed applications, the posting event.
-- ---------------------------------------------------------------------
CREATE TABLE open_invoices (
  client_id      VARCHAR(20) NOT NULL REFERENCES clients,
  invoice_no     VARCHAR(20) NOT NULL,           -- the client's own invoice number, e.g. 4471
  buyer_name     VARCHAR(80) NOT NULL,           -- the client's customer (a company)
  invoice_date   DATE NOT NULL,
  due_date       DATE NOT NULL,
  currency       VARCHAR(3) NOT NULL,
  amount         NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  terms          VARCHAR(20) NOT NULL,           -- 2/10 NET 30 = 2 percent off when paid within 10 days, else net 30
  discount_pct   NUMERIC(4,2) NOT NULL DEFAULT 0,
  discount_days  INTEGER NOT NULL DEFAULT 0,
  open_amount    NUMERIC(14,2) NOT NULL,
  status         VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','SHORT_PAID','PAID')),
  PRIMARY KEY (client_id, invoice_no)
);

-- One row per proposed cash application = the recorded assessment (what the agent said and what SQL decided).
CREATE SEQUENCE cap_seq START 1;
CREATE TABLE cash_applications (
  application_id      VARCHAR(12) PRIMARY KEY DEFAULT 'CAP-' || lpad(nextval('cap_seq')::text, 5, '0'),
  client_id           VARCHAR(20) NOT NULL REFERENCES clients,
  payment_ref         VARCHAR(20) NOT NULL REFERENCES payments,
  remittance_text     TEXT,                      -- the remittance / short-pay note as the client gave it
  currency            VARCHAR(3) NOT NULL,
  invoice_list       TEXT NOT NULL,             -- validated invoice numbers, comma-separated
  invoices_total      NUMERIC(14,2) NOT NULL,
  payment_amount      NUMERIC(14,2) NOT NULL,
  discount_allowed    NUMERIC(14,2) NOT NULL,    -- early-pay discount the terms allow on the payment's value date
  discount_accepted   NUMERIC(14,2) NOT NULL,
  deductions          TEXT,                      -- validated deductions: CODE amount; ...
  ignored_items       TEXT,                      -- HIDDEN: anything the model sent that is not a known deduction
  disputed_amount     NUMERIC(14,2) NOT NULL,    -- claimed deductions + unearned discount + unexplained short pay
  auto_write_off      NUMERIC(14,2) NOT NULL,    -- disputed amount within the small-balance tolerance
  review_amount       NUMERIC(14,2) NOT NULL,    -- disputed amount over the tolerance -> DEDUCTION_REVIEW case
  agent_confidence    VARCHAR(8) NOT NULL,
  agent_notes         TEXT,                      -- HIDDEN: the remittance_match_agent's full answer (reviewers only)
  status              VARCHAR(10) NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','APPLIED')),
  case_id             VARCHAR(12),
  confirm_count       INTEGER NOT NULL DEFAULT 0,
  executed_confirm_no INTEGER,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE UNIQUE INDEX cash_applications_one_applied ON cash_applications (payment_ref) WHERE status = 'APPLIED';

-- The confirmed posting (event row; trg_cash_posting allocates it to the invoices atomically).
CREATE TABLE cash_postings (
  application_id  VARCHAR(12) PRIMARY KEY REFERENCES cash_applications,
  posted_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- A reviewer-accepted deduction (event row; trg_deduction_writeoff closes the invoice balance).
CREATE SEQUENCE wo_seq START 1;
CREATE TABLE deduction_writeoffs (
  writeoff_id     VARCHAR(12) PRIMARY KEY DEFAULT 'WO-' || lpad(nextval('wo_seq')::text, 5, '0'),
  application_id  VARCHAR(12) NOT NULL REFERENCES cash_applications,
  case_id         VARCHAR(12) NOT NULL UNIQUE REFERENCES review_cases,
  amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Verification of payee: the account-name register (scheme stand-in), assessed payment requests, the release event.
-- ---------------------------------------------------------------------
CREATE TABLE payee_register (
  account_ref      VARCHAR(34) PRIMARY KEY,      -- beneficiary account number / IBAN
  bank_bic         VARCHAR(16) NOT NULL,
  registered_name  VARCHAR(80) NOT NULL,         -- the account name on file at the beneficiary bank
  currency         VARCHAR(3) NOT NULL,
  rail             VARCHAR(16) NOT NULL CHECK (rail IN ('SWIFT','SEPA','FEDWIRE','FASTER_PAYMENTS','ACH'))
);

CREATE SEQUENCE prq_seq START 1;
CREATE TABLE payment_requests (
  request_id          VARCHAR(12) PRIMARY KEY DEFAULT 'PRQ-' || lpad(nextval('prq_seq')::text, 5, '0'),
  client_id           VARCHAR(20) NOT NULL REFERENCES clients,
  account_id          VARCHAR(20) NOT NULL REFERENCES accounts,
  beneficiary_account VARCHAR(34) NOT NULL REFERENCES payee_register,
  typed_name          VARCHAR(120) NOT NULL,     -- the beneficiary name the client typed
  registered_name     VARCHAR(80) NOT NULL,
  amount              NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency            VARCHAR(3) NOT NULL,
  rail                VARCHAR(16) NOT NULL,
  purpose             TEXT,                      -- the client's own words about the payment
  agent_verdict       VARCHAR(12),               -- HIDDEN: the agent's verdict if it is one of the three
  agent_reasons       TEXT,                      -- HIDDEN: agent reasons that exist in payee_name_guide (validated)
  ignored_reasons     TEXT,                      -- HIDDEN: anything else the model sent (recorded, never used)
  agent_notes         TEXT,                      -- HIDDEN: the payee_name_match_agent's full answer (reviewers only)
  name_score          INTEGER NOT NULL CHECK (name_score BETWEEN 0 AND 100),   -- HIDDEN: deterministic similarity
  name_check          VARCHAR(12) NOT NULL CHECK (name_check IN ('MATCH','CLOSE_MATCH','NO_MATCH')),
  status              VARCHAR(10) NOT NULL CHECK (status IN ('PROPOSED','HELD','SENT','RELEASED','CANCELLED')),
  warning_required    BOOLEAN NOT NULL DEFAULT FALSE,
  case_id             VARCHAR(12),               -- the PAYEE_VERIFICATION case (held requests)
  payment_ref         VARCHAR(20),               -- the payment created when it is sent / released
  confirm_count       INTEGER NOT NULL DEFAULT 0,
  executed_confirm_no INTEGER,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

-- A payment request that is actually submitted (event row; trg_payment_release creates the payment atomically).
CREATE TABLE payment_releases (
  request_id   VARCHAR(12) PRIMARY KEY REFERENCES payment_requests,
  via          VARCHAR(10) NOT NULL CHECK (via IN ('CLIENT','REVIEWER')),
  case_id      VARCHAR(12),
  amount       NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  released_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- A reviewer-approved recall (event row; trg_payment_recall sets the payment RECALLED).
CREATE TABLE payment_recalls (
  payment_ref  VARCHAR(20) PRIMARY KEY REFERENCES payments,
  case_id      VARCHAR(12) NOT NULL UNIQUE REFERENCES review_cases,
  amount       NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  recalled_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- A reviewer-approved fee refund (event row; trg_fee_refund writes the payment event).
CREATE TABLE fee_refunds (
  payment_ref  VARCHAR(20) PRIMARY KEY REFERENCES payments,
  case_id      VARCHAR(12) NOT NULL UNIQUE REFERENCES review_cases,
  amount       NUMERIC(10,2) NOT NULL CHECK (amount > 0),
  refunded_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; no MCP tool exposes it.
CREATE TABLE agent_audit (
  id         SERIAL PRIMARY KEY,
  at         TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  client_id  VARCHAR(20),
  actor      VARCHAR(20),            -- reviewer id for REVIEWER_VERIFY / CASE_DECIDED
  action     VARCHAR(30) NOT NULL,   -- VERIFY, REVIEWER_VERIFY, TRACE_PROPOSED, TRACE_OPENED, RECALL_PROPOSED,
                                     -- RECALL_SUBMITTED, REVIEW_CASE_OPENED, CASH_APPLICATION_PROPOSED, CASH_APPLIED,
                                     -- PAYMENT_PROPOSED, PAYMENT_HELD, PAYMENT_SENT, CASE_DECIDED, PAYMENT_RECALLED,
                                     -- FEE_REFUNDED, DEDUCTION_WRITTEN_OFF
  ref        TEXT,
  detail     TEXT
);

-- Guarded email requests that passed the SQL check (the flow then sends to To_Email).
CREATE TABLE email_log (
  email_id     SERIAL PRIMARY KEY,
  client_id    VARCHAR(20) NOT NULL REFERENCES clients,
  reference_id VARCHAR(20) NOT NULL,
  subject      TEXT NOT NULL,
  logged_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
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
      LEFT JOIN client_sessions s ON s.session_token = p_token AND s.role = 'CLIENT' AND s.expires_at > clock_timestamp()
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
        JOIN client_sessions se ON se.client_id = c.client_id AND se.role = 'CLIENT' AND se.expires_at > clock_timestamp()
       WHERE c.client_id = upper(trim(coalesce(p_client,''))) AND c.passcode_hash = passcode_hash(p_client, p_code)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- Reviewer identity: one row always - the reviewer when the token is a valid REVIEWER token of an active reviewer.
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN client_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
                                 AND s.expires_at > clock_timestamp()
      LEFT JOIN reviewers r ON r.reviewer_id = s.reviewer_id AND r.active;
END $$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Helpers (formatting, normalisation) used by the rules below.
-- ---------------------------------------------------------------------
-- Amount in its own currency: $1,234.56 for USD, EUR 1,234.56 / GBP 1,234.56 otherwise.
CREATE OR REPLACE FUNCTION money(n NUMERIC, cur TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL
              WHEN coalesce(cur, 'USD') = 'USD' THEN '$' || to_char(n, 'FM999,999,999,990.00')
              ELSE cur || ' ' || to_char(n, 'FM999,999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$ SELECT upper(trim(coalesce(p, ''))) $$ LANGUAGE sql IMMUTABLE;

-- '$1,234.50' / 'USD 1234.5' / ' 35 ' -> '1234.50'-style text ('' when empty); 'ALL' stays 'ALL'.
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT regexp_replace(upper(regexp_replace(coalesce(p, ''), '[[:space:]$,]', '', 'g')), '^(USD|EUR|GBP)', '')
$$ LANGUAGE sql IMMUTABLE;

-- AGB-5001 / agb5001 / AGB 5001 / 5001 -> AGB-5001
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^[0-9]{4}$' THEN 'AGB-' || d ELSE upper(trim(coalesce(p, ''))) END
    FROM (SELECT regexp_replace(upper(trim(coalesce(p, ''))), '^AGB[[:space:]-]*', '') AS d) x
$$ LANGUAGE sql IMMUTABLE;

-- What a reviewer sees of the client (minimum necessary: the company name, never the contact email or client id).
CREATE OR REPLACE FUNCTION client_display(p_client TEXT) RETURNS TEXT AS $$
  SELECT c.legal_name::text FROM clients c WHERE c.client_id = p_client
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Reviewer identity: staff id + staff code -> REVIEWER session (same token mechanism, role checked everywhere).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reviewer_locked_until(p_staff TEXT) RETURNS TIMESTAMP AS $$
  SELECT CASE WHEN count(*) >= 5 THEN min(f.at) + INTERVAL '15 minutes' END
    FROM (SELECT va.at FROM reviewer_verify_attempts va
           WHERE va.reviewer_id = norm_staff_id(p_staff) AND NOT va.ok
             AND va.at > clock_timestamp() - INTERVAL '15 minutes'
             AND va.at > coalesce((SELECT max(v2.at) FROM reviewer_verify_attempts v2
                                    WHERE v2.reviewer_id = va.reviewer_id AND v2.ok), '-infinity'::timestamp)
           ORDER BY va.at DESC LIMIT 5) f;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for verify_reviewer: records the attempt and returns the session row ONLY for a matching,
-- active, non-locked staff id + code.
CREATE OR REPLACE FUNCTION verify_reviewer_fn(p_staff TEXT, p_code TEXT)
RETURNS TABLE (role TEXT, reviewer_id TEXT) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_staff_id(p_staff); r reviewers;
BEGIN
  IF reviewer_locked_until(v_id) IS NOT NULL THEN RETURN; END IF;
  SELECT * INTO r FROM reviewers x WHERE x.reviewer_id = v_id AND x.active;
  IF NOT FOUND THEN RETURN; END IF;                    -- unknown staff ids are not tracked
  IF r.one_time_code = trim(coalesce(p_code, '')) THEN
    INSERT INTO reviewer_verify_attempts (reviewer_id, ok) VALUES (v_id, TRUE);
    RETURN QUERY SELECT 'REVIEWER'::text, r.reviewer_id::text; RETURN;
  END IF;
  INSERT INTO reviewer_verify_attempts (reviewer_id, ok) VALUES (v_id, FALSE);
  RETURN;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_reviewer_result(p_staff TEXT, p_code TEXT)
RETURNS TABLE (status TEXT, reason TEXT, session_token TEXT, role TEXT, display_name TEXT, team TEXT, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN lk.until IS NOT NULL THEN 'LOCKED' WHEN s.session_token IS NULL THEN 'NOT_VERIFIED' ELSE 'VERIFIED' END,
         CASE WHEN lk.until IS NOT NULL THEN 'LOCKED: too many failed attempts. Staff verification is locked until '
                                             || to_char(lk.until, 'HH24:MI') || '.'
              WHEN s.session_token IS NULL THEN 'NOT_VERIFIED: the staff ID and code do not match. Nothing is revealed about which one is wrong.'
              ELSE 'VERIFIED: reviewer session valid for 30 minutes.' END,
         CASE WHEN lk.until IS NULL THEN s.session_token END,
         CASE WHEN lk.until IS NULL AND s.session_token IS NOT NULL THEN 'REVIEWER' END,
         CASE WHEN lk.until IS NULL THEN s.display_name END,
         CASE WHEN lk.until IS NULL THEN s.team END,
         CASE WHEN lk.until IS NULL THEN s.expires_at END
    FROM (SELECT reviewer_locked_until(p_staff) AS until) lk
    LEFT JOIN LATERAL (
      SELECT se.session_token, r.display_name::text AS display_name, r.team::text AS team, se.expires_at
        FROM reviewers r
        JOIN client_sessions se ON se.reviewer_id = r.reviewer_id AND se.role = 'REVIEWER' AND se.expires_at > clock_timestamp()
       WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Scoped reads: only the caller's rows; one SESSION_INVALID row for a bad token.
-- ---------------------------------------------------------------------

-- Payments: empty search = last 90 days (newest first, max 25); a search term (payment ref, beneficiary or payer text,
-- or an amount like 48500) looks back 18 months so an older payment is still found. NO_MATCH when nothing matches.
-- INCOMING rows carry the payer (ordering_party), the remittance text the payer sent and any applied cash application.
CREATE OR REPLACE FUNCTION my_payments(p_token TEXT, p_search TEXT)
RETURNS TABLE (session_status TEXT, payment_ref VARCHAR, direction VARCHAR, rail VARCHAR, amount NUMERIC,
               currency VARCHAR, fx_rate NUMERIC, fees NUMERIC, beneficiary_name VARCHAR, beneficiary_bank_bic VARCHAR,
               ordering_party VARCHAR, remittance_info VARCHAR, status VARCHAR, return_reason_code VARCHAR,
               value_date DATE, created_at TIMESTAMP, open_investigation_id VARCHAR, cash_application_id VARCHAR) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' WHEN p.payment_ref IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         p.payment_ref, p.direction, p.rail, p.amount, p.currency, p.fx_rate, p.fees,
         (CASE WHEN p.direction = 'INCOMING' THEN 'own account' ELSE p.beneficiary_name END)::varchar,
         p.beneficiary_bank_bic, p.ordering_party, p.remittance_info, p.status, p.return_reason_code, p.value_date,
         p.created_at, p.open_investigation_id, p.cash_application_id
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT x.payment_ref, x.direction, x.rail, x.amount, x.currency, x.fx_rate, x.fees, x.beneficiary_name,
             x.beneficiary_bank_bic, x.ordering_party, x.remittance_info, x.status, x.return_reason_code, x.value_date,
             x.created_at, i.investigation_id AS open_investigation_id, ca.application_id AS cash_application_id
        FROM payments x
        LEFT JOIN investigations i ON i.payment_ref = x.payment_ref AND i.status IN ('OPEN','UNDER_REVIEW')
        LEFT JOIN cash_applications ca ON ca.payment_ref = x.payment_ref AND ca.status = 'APPLIED'
        CROSS JOIN (SELECT upper(trim(coalesce(p_search,''))) AS q) s
       WHERE x.client_id = sc.client_id
         AND CASE WHEN s.q = '' THEN x.created_at >= clock_timestamp() - INTERVAL '90 days'
                  ELSE x.created_at >= clock_timestamp() - INTERVAL '18 months'
                       AND (position(s.q IN upper(x.payment_ref)) > 0
                            OR position(s.q IN upper(x.beneficiary_name)) > 0
                            OR position(s.q IN upper(x.beneficiary_bank_bic)) > 0
                            OR position(s.q IN upper(coalesce(x.ordering_party, ''))) > 0
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
         p.payment_ref, p.direction, p.rail, p.amount, p.currency, p.fx_rate, p.fees,
         (CASE WHEN p.direction = 'INCOMING' THEN 'own account' ELSE p.beneficiary_name END)::varchar,
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
               agent_brief TEXT, assigned_team TEXT, currency TEXT, requested_amount NUMERIC, parked_action TEXT) AS $$
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
                       || money(p.amount, p.currency) || ' to ' || p.beneficiary_name || '), reason ' || pa.reason_code
                       || '. Funds are not auto-reversed; Payment Operations decides whether to send the recall to the '
                       || 'beneficiary bank.')::text,
                      tm.team::text, p.currency::text, p.amount, ('RECALL:' || p.payment_ref)::text;
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
    UPDATE payments SET status_before_recall = status, status = 'RECALL_REQUESTED' WHERE payment_ref = NEW.payment_ref;
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
-- Human-owned requests -> routed to a team by the table, never decided by the LLM. A case may PARK an action
-- (fee refund, recall, payment release, deduction write-off) that runs only when a reviewer of that team approves it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION norm_request_type(p_type TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p_type,'')), '[\s-]+', '_', 'g'));
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fee_refunded(p_ref TEXT) RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM fee_refunds f WHERE f.payment_ref = p_ref)
$$ LANGUAGE sql STABLE;

-- What a new client-opened case parks for approval (derived in SQL, never chosen by the model):
--   FEE_WAIVER + reference = one of the client's payments with a fee that is not refunded yet (empty -> the most recent
--                one in 90 days) -> FEE_REFUND:<payment>, requested = that fee, in the payment's currency
--   any other type: no parked action (the team completes it); a reference must be one of the client's payments.
--   A reference that is not the client's -> BAD_REFERENCE.
CREATE OR REPLACE FUNCTION case_parking(p_client TEXT, p_type TEXT, p_reference TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, payment_ref TEXT, parked_action TEXT, requested_amount NUMERIC, currency TEXT) AS $$
#variable_conflict use_column
DECLARE v_type TEXT := norm_request_type(p_type); v_ref TEXT := norm_ref(p_reference); p payments;
BEGIN
  ok := TRUE; reason_code := 'OK';
  IF v_ref <> '' THEN
    SELECT * INTO p FROM payments x WHERE x.payment_ref = v_ref AND x.client_id = p_client;
    IF NOT FOUND THEN ok := FALSE; reason_code := 'BAD_REFERENCE'; RETURN NEXT; RETURN; END IF;
  END IF;
  IF v_type = 'FEE_WAIVER' THEN
    IF v_ref <> '' THEN
      IF p.fees <= 0 OR fee_refunded(p.payment_ref) THEN ok := FALSE; reason_code := 'BAD_REFERENCE'; RETURN NEXT; RETURN; END IF;
    ELSE
      SELECT * INTO p FROM payments x
       WHERE x.client_id = p_client AND x.fees > 0 AND x.created_at >= clock_timestamp() - INTERVAL '90 days'
         AND NOT fee_refunded(x.payment_ref)
       ORDER BY x.created_at DESC, x.payment_ref DESC LIMIT 1;
    END IF;
    IF p.payment_ref IS NOT NULL THEN
      parked_action := 'FEE_REFUND:' || p.payment_ref; requested_amount := p.fees; currency := p.currency;
    END IF;
  END IF;
  payment_ref := p.payment_ref;
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
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON review_cases FOR EACH ROW EXECUTE FUNCTION case_defaults();

CREATE OR REPLACE FUNCTION service_case_row(p_token TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT, p_reference TEXT)
RETURNS TABLE (client_id TEXT, request_type VARCHAR, client_statement TEXT, agent_brief TEXT, assigned_team VARCHAR,
               payment_ref TEXT, currency TEXT, requested_amount NUMERIC, parked_action TEXT) AS $$
  SELECT sc.client_id, t.request_type, left(coalesce(p_statement,''), 4000), left(coalesce(p_brief,''), 4000), t.team,
         pk.payment_ref, pk.currency, pk.requested_amount, pk.parked_action
    FROM (SELECT * FROM session_client(p_token)) sc
    JOIN service_teams t ON t.request_type = norm_request_type(p_type) AND t.client_openable
    CROSS JOIN LATERAL case_parking(sc.client_id, p_type, p_reference) pk
   WHERE sc.client_id IS NOT NULL AND pk.ok
     AND NOT EXISTS (SELECT 1 FROM review_cases c
                      WHERE c.client_id = sc.client_id AND c.request_type = t.request_type AND c.action_id IS NULL
                        AND c.created_at > clock_timestamp() - INTERVAL '10 minutes')
     AND NOT EXISTS (SELECT 1 FROM review_cases c
                      WHERE pk.parked_action IS NOT NULL AND c.parked_action = pk.parked_action AND c.status = 'OPEN');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_token TEXT, p_type TEXT, p_reference TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, case_id VARCHAR, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, reply_by DATE, status VARCHAR, payment_ref VARCHAR,
               requested_amount NUMERIC, currency VARCHAR, if_approved TEXT, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NULL THEN 'NOT_OPENED'
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CASE_OPENED' ELSE 'ALREADY_OPEN' END,
         CASE WHEN c.case_id IS NOT NULL THEN
                CASE WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CASE_OPENED' ELSE 'ALREADY_OPEN' END
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID'
              WHEN t0.request_type IS NULL THEN 'BAD_TYPE'
              WHEN NOT pk.ok THEN 'BAD_REFERENCE' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL AND c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                THEN 'A person on the assigned team will review and decide. The assistant has not decided or promised anything.'
              WHEN c.case_id IS NOT NULL
                THEN 'This request is already open with the assigned team, so no new case was opened. A person will decide.'
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN t0.request_type IS NULL THEN 'BAD_TYPE: use PAYMENT_REPAIR, FEE_WAIVER, COMPENSATION, FRAUD, SANCTIONS_QUERY '
                   || 'or OTHER. A recall goes through propose_recall and confirm_recall.'
              WHEN NOT pk.ok THEN 'BAD_REFERENCE: that reference is not one of this client''s payments (for FEE_WAIVER: a '
                   || 'payment with a fee that has not been refunded). Use get_my_payments, or leave it empty.'
              ELSE 'NOT_OPENED: the case could not be recorded. Try again.' END,
         c.case_id, c.request_type, t.team, t.reply_business_days, c.sla_due_at::date, c.status, c.payment_ref,
         c.requested_amount, c.currency,
         CASE split_part(coalesce(c.parked_action, ''), ':', 1)
              WHEN 'FEE_REFUND' THEN 'If a person approves it, the fee on payment ' || split_part(c.parked_action, ':', 2)
                   || ' is refunded.' END,
         c.created_at
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN service_teams t0 ON t0.request_type = norm_request_type(p_type) AND t0.client_openable
    LEFT JOIN LATERAL (SELECT * FROM case_parking(sc.client_id, p_type, p_reference)) pk ON TRUE
    LEFT JOIN LATERAL (
      SELECT x.* FROM review_cases x
       WHERE x.client_id = sc.client_id AND x.request_type = norm_request_type(p_type) AND t0.request_type IS NOT NULL
         AND x.action_id IS NULL
         AND (x.created_at > clock_timestamp() - INTERVAL '10 minutes'
              OR (x.status = 'OPEN' AND pk.parked_action IS NOT NULL AND x.parked_action = pk.parked_action))
       ORDER BY x.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The client's investigations (INV-) and review cases (CASE-) in one list: status + the client-safe outcome message once
-- a person decided. Never the internal note, the AI brief, name scores or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_type TEXT, reference_id TEXT, topic TEXT, payment_ref TEXT,
               assigned_team TEXT, status TEXT, expected_by DATE, requested_amount NUMERIC, currency TEXT,
               approved_amount NUMERIC, customer_message TEXT, decided_on DATE, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_type, c.reference_id, c.topic, c.payment_ref, c.assigned_team, c.status, c.expected_by,
         c.requested_amount, c.currency, c.approved_amount, c.customer_message, c.decided_on, c.created_at
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT 'INVESTIGATION'::text AS case_type, i.investigation_id::text AS reference_id, i.reason_code::text AS topic,
             i.payment_ref::text AS payment_ref, 'Payment Investigations'::text AS assigned_team, i.status::text AS status,
             i.est_response_date AS expected_by, NULL::numeric AS requested_amount, NULL::text AS currency,
             NULL::numeric AS approved_amount, NULL::text AS customer_message, NULL::date AS decided_on, i.created_at
        FROM investigations i WHERE i.client_id = sc.client_id
      UNION ALL
      SELECT 'REVIEW_CASE', r.case_id, r.request_type, r.payment_ref, r.assigned_team, r.status, r.sla_due_at::date,
             r.requested_amount, r.currency, r.approved_amount, r.customer_message, r.decided_at::date, r.created_at
        FROM review_cases r
       WHERE r.client_id = sc.client_id) c ON TRUE
   ORDER BY c.created_at DESC, c.reference_id DESC;
$$ LANGUAGE sql STABLE;

-- Email confirmation: validated payload for the guarded email tool. Returns SEND + subject/body ONLY when the
-- reference is an investigation (INV-), review case (CASE-), applied cash application (CAP-) or a payment submitted
-- through the assistant (PMT- from a sent / released payment request) of THIS client; otherwise NOT_SENT + reason.
-- The flow sends to the configured To_Email (ops inbox); the body never contains account numbers, internal notes,
-- name scores or agent output.
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason TEXT, reference_id TEXT, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN x.ok THEN 'SEND' ELSE 'NOT_SENT' END,
         CASE WHEN x.ok THEN 'SEND' WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' ELSE 'NO_SUCH_REFERENCE' END,
         CASE WHEN x.ok THEN 'Confirmation email prepared.'
              WHEN sc.client_id IS NULL THEN 'SESSION_INVALID: verify again.'
              ELSE 'NO_SUCH_REFERENCE: no investigation (INV-), review case (CASE-), cash application (CAP-) or payment '
                   || 'submitted through the assistant (PMT-) with that reference for this client.' END,
         norm_ref(p_reference),
         CASE WHEN i.investigation_id IS NOT NULL THEN 'Aurelia Global Bank - investigation ' || i.investigation_id || ' opened'
              WHEN rc.case_id IS NOT NULL AND rc.status <> 'OPEN' THEN 'Aurelia Global Bank - decision on review case '
                   || rc.case_id || ' (' || st.label || ')'
              WHEN rc.case_id IS NOT NULL THEN 'Aurelia Global Bank - review case ' || rc.case_id || ' (' || rc.request_type || ')'
              WHEN ca.application_id IS NOT NULL THEN 'Aurelia Global Bank - cash application ' || ca.application_id || ' posted'
              WHEN pr.request_id IS NOT NULL THEN 'Aurelia Global Bank - payment ' || pr.payment_ref || ' submitted'
              ELSE 'Aurelia Global Bank confirmation - not sent' END,
         CASE WHEN i.investigation_id IS NOT NULL THEN
           'Dear ' || c.legal_name || ' team,' || chr(10) || chr(10)
           || 'We have opened investigation ' || i.investigation_id || ' on payment ' || i.payment_ref
           || ' (reason ' || i.reason_code || ').' || chr(10)
           || 'The agent bank is expected to respond by ' || to_char(i.est_response_date,'YYYY-MM-DD') || '.' || chr(10) || chr(10)
           || 'Thank you for banking with Aurelia Global Bank.'
              WHEN rc.case_id IS NOT NULL AND rc.status <> 'OPEN' THEN
           'Dear ' || c.legal_name || ' team,' || chr(10) || chr(10)
           || 'Our ' || rc.assigned_team || ' team has reviewed case ' || rc.case_id || ' (' || st.label || ')'
           || coalesce(' regarding payment ' || rc.payment_ref, '') || ': '
           || CASE WHEN rc.status = 'APPROVED' THEN 'approved' ELSE 'not approved' END || '.' || chr(10)
           || coalesce(rc.customer_message, '') || chr(10) || chr(10)
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
              WHEN ca.application_id IS NOT NULL THEN
           'Dear ' || c.legal_name || ' team,' || chr(10) || chr(10)
           || 'We have applied incoming payment ' || ca.payment_ref || ' (' || money(ca.payment_amount, ca.currency)
           || ') to invoices ' || ca.invoice_list || ' as cash application ' || ca.application_id || '.' || chr(10)
           || CASE WHEN ca.review_amount > 0 THEN 'A disputed deduction of ' || money(ca.review_amount, ca.currency)
                   || ' is with Client Servicing for review (case ' || ca.case_id || ').' || chr(10) ELSE '' END
           || chr(10) || 'Thank you for banking with Aurelia Global Bank.'
              WHEN pr.request_id IS NOT NULL THEN
           'Dear ' || c.legal_name || ' team,' || chr(10) || chr(10)
           || 'Payment ' || pr.payment_ref || ' of ' || money(pr.amount, pr.currency) || ' to ' || pr.registered_name
           || ' has been submitted on the ' || pr.rail || ' rail.' || chr(10) || chr(10)
           || 'Thank you for banking with Aurelia Global Bank.'
              ELSE 'No confirmation email was sent for reference ' || norm_ref(p_reference) || '.' END
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN clients c ON c.client_id = sc.client_id
    LEFT JOIN investigations i ON i.investigation_id = norm_ref(p_reference) AND i.client_id = sc.client_id
    LEFT JOIN review_cases rc ON rc.case_id = norm_ref(p_reference) AND rc.client_id = sc.client_id
    LEFT JOIN service_teams st ON st.request_type = rc.request_type
    LEFT JOIN cash_applications ca ON ca.application_id = norm_ref(p_reference) AND ca.client_id = sc.client_id
                                  AND ca.status = 'APPLIED'
    LEFT JOIN payment_requests pr ON pr.payment_ref = norm_ref(p_reference) AND pr.client_id = sc.client_id
                                 AND pr.status IN ('SENT','RELEASED')
    CROSS JOIN LATERAL (SELECT (i.investigation_id IS NOT NULL OR rc.case_id IS NOT NULL OR ca.application_id IS NOT NULL
                                OR pr.request_id IS NOT NULL) AS ok) x;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for the email tool: the request is logged ONLY when the payload says SEND (then the flow sends).
CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (client_id TEXT, reference_id TEXT, subject TEXT) AS $$
  SELECT sc.client_id, e.reference_id, e.subject
    FROM session_client(p_token) sc
    CROSS JOIN LATERAL email_confirmation_payload(p_token, p_reference) e
   WHERE sc.client_id IS NOT NULL AND e.send_status = 'SEND';
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change. Cannot be bypassed
-- by the LLM because they fire in the database, not the app. (TRACE_OPENED / RECALL_SUBMITTED /
-- REVIEW_CASE_OPENED are written by the apply triggers above.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'REVIEWER' THEN
    INSERT INTO agent_audit (client_id, actor, action, ref, detail)
      VALUES (NULL, NEW.reviewer_id, 'REVIEWER_VERIFY', NEW.reviewer_id,
              'reviewer session issued, expires ' || to_char(NEW.expires_at,'YYYY-MM-DD HH24:MI'));
  ELSE
    INSERT INTO agent_audit (client_id, action, ref, detail)
      VALUES (NEW.client_id, 'VERIFY', NEW.client_id, 'session issued, expires ' || to_char(NEW.expires_at,'YYYY-MM-DD HH24:MI'));
  END IF;
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

-- =====================================================================
-- CASH APPLICATION (receivables). The client pastes a remittance or short-pay note ("INV 4471/4475 less 2% early pay
-- + freight dispute $312"). The remittance_match_agent matches it to the client's own open invoices and names the
-- deduction reasons from remittance_guide. SQL VALIDATES the invoice numbers (open invoices of THIS client, same
-- currency) and the deduction codes (unknown ones are recorded and never used), works out the early-pay discount the
-- terms actually allow, and computes what is disputed. Disputed amounts up to the small-balance tolerance are written
-- off; anything over it parks a DEDUCTION_WRITE_OFF that Client Servicing decides. Two steps: propose -> confirm.
-- =====================================================================
CREATE OR REPLACE FUNCTION small_balance_tolerance() RETURNS NUMERIC AS $$ SELECT 250.00::numeric $$ LANGUAGE sql IMMUTABLE;

-- '4471, 4475' / 'INV 4471/4475' / 'invoice #4471 and 4475' -> {4471,4475} (distinct, sorted).
CREATE OR REPLACE FUNCTION norm_invoice_list(p TEXT) RETURNS TEXT[] AS $$
  SELECT coalesce(array_agg(DISTINCT t.x ORDER BY t.x), ARRAY[]::text[])
    FROM (SELECT regexp_replace(upper(btrim(w)), '^(INVOICE|INV)[#.:-]*', '') AS x
            FROM regexp_split_to_table(coalesce(p, ''), '[,;/&+[:space:]]+') w) t
   WHERE t.x ~ '^[A-Z0-9][A-Z0-9-]{0,19}$' AND t.x NOT IN ('AND', 'NONE', 'NO', 'NOS', 'N')
$$ LANGUAGE sql IMMUTABLE;

-- The client's OPEN invoices (the candidates the orchestrator gives the agent). Empty search = all open, oldest first.
CREATE OR REPLACE FUNCTION my_open_invoices(p_token TEXT, p_search TEXT)
RETURNS TABLE (session_status TEXT, invoice_no VARCHAR, buyer_name VARCHAR, invoice_date DATE, due_date DATE,
               currency VARCHAR, amount NUMERIC, open_amount NUMERIC, terms VARCHAR, early_pay_until DATE) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' WHEN i.invoice_no IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         i.invoice_no, i.buyer_name, i.invoice_date, i.due_date, i.currency, i.amount, i.open_amount, i.terms,
         i.early_pay_until
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT x.invoice_no, x.buyer_name, x.invoice_date, x.due_date, x.currency, x.amount, x.open_amount, x.terms,
             CASE WHEN x.discount_pct > 0 THEN x.invoice_date + x.discount_days END AS early_pay_until
        FROM open_invoices x CROSS JOIN (SELECT upper(trim(coalesce(p_search, ''))) AS q) s
       WHERE x.client_id = sc.client_id AND x.status = 'OPEN'
         AND (s.q = '' OR position(s.q IN upper(x.invoice_no)) > 0 OR position(s.q IN upper(x.buyer_name)) > 0
              OR (replace(replace(s.q, ',', ''), '$', '') ~ '^[0-9]+(\.[0-9]{1,2})?$'
                  AND x.open_amount = replace(replace(s.q, ',', ''), '$', '')::numeric))
       ORDER BY x.invoice_date, x.invoice_no
       LIMIT 25) i ON sc.client_id IS NOT NULL
   ORDER BY i.invoice_date, i.invoice_no;
$$ LANGUAGE sql STABLE;

-- The assessment (no session: the seeds use it too). Validates the agent's matches and deductions and computes the
-- split. Deduction items are "CODE amount" separated by ";" (EARLY_PAY_DISCOUNT needs no amount: SQL computes it).
CREATE OR REPLACE FUNCTION cash_assessment(p_client TEXT, p_payment TEXT, p_invoices TEXT, p_deductions TEXT, p_confidence TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, payment_ref TEXT, payer TEXT, currency TEXT,
               payment_amount NUMERIC, invoice_list TEXT, invoices_total NUMERIC, discount_allowed NUMERIC,
               discount_accepted NUMERIC, deductions TEXT, ignored_items TEXT, disputed_amount NUMERIC,
               auto_write_off NUMERIC, review_amount NUMERIC, confidence TEXT) AS $$
#variable_conflict use_column
DECLARE p payments; v_inv TEXT[]; v_bad TEXT; v_total NUMERIC; v_allowed NUMERIC; v_conf TEXT; it TEXT; v_code TEXT;
        v_amt NUMERIC; v_valid TEXT[] := ARRAY[]::text[]; v_ignored TEXT[] := ARRAY[]::text[]; v_other NUMERIC := 0;
        v_disc BOOLEAN := FALSE; v_short NUMERIC; v_taken NUMERIC := 0; v_unearned NUMERIC := 0; v_unexpl NUMERIC := 0;
BEGIN
  ok := FALSE;
  SELECT * INTO p FROM payments x WHERE x.client_id = p_client AND x.payment_ref = norm_ref(p_payment);
  IF NOT FOUND THEN
    reason_code := 'NOT_YOUR_PAYMENT';
    reason := 'NOT_YOUR_PAYMENT: no payment ' || coalesce(nullif(trim(p_payment), ''), '(blank)')
              || ' on this client''s accounts. Use get_my_payments.';
    RETURN NEXT; RETURN;
  END IF;
  payment_ref := p.payment_ref; payer := p.ordering_party; currency := p.currency; payment_amount := p.amount;
  IF p.direction <> 'INCOMING' THEN
    reason_code := 'NOT_INCOMING';
    reason := 'NOT_INCOMING: ' || p.payment_ref || ' is an outgoing payment; cash is applied only from incoming payments.';
    RETURN NEXT; RETURN;
  END IF;
  IF p.status <> 'COMPLETED' THEN
    reason_code := 'FUNDS_NOT_RECEIVED';
    reason := 'FUNDS_NOT_RECEIVED: ' || p.payment_ref || ' is ' || p.status || '; cash can be applied once the funds have arrived.';
    RETURN NEXT; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cash_applications c WHERE c.payment_ref = p.payment_ref AND c.status = 'APPLIED') THEN
    reason_code := 'ALREADY_APPLIED';
    reason := 'ALREADY_APPLIED: ' || p.payment_ref || ' has already been applied to invoices. Nothing new was done.';
    RETURN NEXT; RETURN;
  END IF;
  v_inv := norm_invoice_list(p_invoices);
  IF cardinality(v_inv) = 0 THEN
    reason_code := 'NO_INVOICES'; reason := 'NO_INVOICES: no invoice numbers were given. Use get_open_invoices.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM unnest(v_inv) x
   WHERE NOT EXISTS (SELECT 1 FROM open_invoices o WHERE o.client_id = p_client AND o.invoice_no = x
                                                     AND o.status = 'OPEN' AND o.currency = p.currency);
  IF v_bad IS NOT NULL THEN
    reason_code := 'INVOICE_NOT_OPEN';
    reason := 'INVOICE_NOT_OPEN: ' || v_bad || ' is not an open ' || p.currency || ' invoice of this client. Use get_open_invoices.';
    RETURN NEXT; RETURN;
  END IF;
  invoice_list := array_to_string(v_inv, ', ');
  v_conf := upper(btrim(coalesce(p_confidence, ''))); confidence := v_conf;
  IF v_conf NOT IN ('HIGH', 'MEDIUM') THEN
    reason_code := 'LOW_CONFIDENCE';
    reason := 'LOW_CONFIDENCE: the match is not certain enough to apply cash. Ask the client to confirm the invoice numbers.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT sum(o.open_amount),
         sum(CASE WHEN o.discount_pct > 0 AND p.value_date <= o.invoice_date + o.discount_days
                  THEN round(o.open_amount * o.discount_pct / 100, 2) ELSE 0 END)
    INTO v_total, v_allowed
    FROM open_invoices o WHERE o.client_id = p_client AND o.invoice_no = ANY (v_inv);
  invoices_total := v_total; discount_allowed := v_allowed;
  IF p.amount > v_total + 0.005 THEN
    reason_code := 'OVERPAYMENT';
    reason := 'OVERPAYMENT: the payment (' || money(p.amount, p.currency) || ') is more than the invoices ('
              || money(v_total, p.currency) || '). A person must apply the excess: open a review case (OTHER).';
    RETURN NEXT; RETURN;
  END IF;
  FOR it IN SELECT btrim(x) FROM regexp_split_to_table(coalesce(p_deductions, ''), '[;\n]|,(?=[[:space:]]*[A-Za-z])') x LOOP
    CONTINUE WHEN it = '' OR upper(it) IN ('NONE', 'N/A', 'NA', '-');
    v_code := upper(coalesce(substring(it FROM '^[A-Za-z_]+'), ''));
    v_amt := nullif(replace(coalesce(substring(it FROM '([0-9][0-9,]*(?:\.[0-9]+)?)'), ''), ',', ''), '')::numeric;
    IF EXISTS (SELECT 1 FROM remittance_guide g WHERE g.section = 'DEDUCTION' AND g.term = v_code) THEN
      IF v_code = 'EARLY_PAY_DISCOUNT' THEN
        v_disc := TRUE;
      ELSIF v_amt IS NULL OR v_amt <= 0 THEN
        v_ignored := v_ignored || it;                         -- a deduction without an amount cannot be used
      ELSE
        v_other := v_other + v_amt;
        v_valid := v_valid || (v_code || ' ' || money(v_amt, p.currency));
      END IF;
    ELSE
      v_ignored := v_ignored || it;                           -- not a deduction in the guide: recorded, never used
    END IF;
  END LOOP;
  v_short := v_total - p.amount;
  IF v_other > v_short + 0.005 THEN
    reason_code := 'DEDUCTIONS_EXCEED_SHORT_PAY';
    reason := 'DEDUCTIONS_EXCEED_SHORT_PAY: the stated deductions (' || money(v_other, p.currency)
              || ') are more than the short payment (' || money(v_short, p.currency) || '). Ask the client to check the remittance.';
    RETURN NEXT; RETURN;
  END IF;
  IF v_disc THEN
    v_taken := v_short - v_other;
    discount_accepted := greatest(0, least(v_taken, v_allowed));
    v_unearned := v_taken - discount_accepted;
    v_valid := ARRAY['EARLY_PAY_DISCOUNT ' || money(discount_accepted, p.currency) || ' (earned)'] || v_valid;
    IF v_unearned > 0.004 THEN
      v_valid := v_valid || ('EARLY_PAY_DISCOUNT ' || money(v_unearned, p.currency) || ' (not earned under the terms)');
    END IF;
  ELSE
    discount_accepted := 0;
    v_unexpl := v_short - v_other;
    IF v_unexpl > 0.004 THEN
      v_valid := v_valid || ('UNAPPLIED ' || money(v_unexpl, p.currency) || ' (no stated reason)');
    END IF;
  END IF;
  deductions := nullif(array_to_string(v_valid, '; '), '');
  ignored_items := nullif(array_to_string(v_ignored, '; '), '');
  disputed_amount := round(v_other + v_unearned + v_unexpl, 2);
  IF disputed_amount <= small_balance_tolerance() THEN
    auto_write_off := disputed_amount; review_amount := 0;
  ELSE
    auto_write_off := 0; review_amount := disputed_amount;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE'; reason := 'ELIGIBLE';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION cash_eval(p_token TEXT, p_payment TEXT, p_invoices TEXT, p_deductions TEXT, p_confidence TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, client_id TEXT, payment_ref TEXT, payer TEXT, currency TEXT,
               payment_amount NUMERIC, invoice_list TEXT, invoices_total NUMERIC, discount_allowed NUMERIC,
               discount_accepted NUMERIC, deductions TEXT, ignored_items TEXT, disputed_amount NUMERIC,
               auto_write_off NUMERIC, review_amount NUMERIC, confidence TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; a RECORD;
BEGIN
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    ok := FALSE; reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO a FROM cash_assessment(v_cid, p_payment, p_invoices, p_deductions, p_confidence);
  ok := a.ok; reason_code := a.reason_code; reason := a.reason; client_id := v_cid; payment_ref := a.payment_ref;
  payer := a.payer; currency := a.currency; payment_amount := a.payment_amount; invoice_list := a.invoice_list;
  invoices_total := a.invoices_total; discount_allowed := a.discount_allowed; discount_accepted := a.discount_accepted;
  deductions := a.deductions; ignored_items := a.ignored_items; disputed_amount := a.disputed_amount;
  auto_write_off := a.auto_write_off; review_amount := a.review_amount; confidence := a.confidence;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row for propose_cash_application: the assessed application is written ONLY when every rule passes,
-- and not twice (an unexpired PROPOSED application for the same payment is reused).
CREATE OR REPLACE FUNCTION cash_application_row(p_token TEXT, p_payment TEXT, p_remittance TEXT, p_invoices TEXT,
                                                p_deductions TEXT, p_confidence TEXT, p_notes TEXT)
RETURNS TABLE (client_id TEXT, payment_ref TEXT, remittance_text TEXT, currency TEXT, invoice_list TEXT,
               invoices_total NUMERIC, payment_amount NUMERIC, discount_allowed NUMERIC, discount_accepted NUMERIC,
               deductions TEXT, ignored_items TEXT, disputed_amount NUMERIC, auto_write_off NUMERIC,
               review_amount NUMERIC, agent_confidence TEXT, agent_notes TEXT) AS $$
  SELECT e.client_id, e.payment_ref, left(coalesce(p_remittance, ''), 2000), e.currency, e.invoice_list, e.invoices_total,
         e.payment_amount, e.discount_allowed, e.discount_accepted, e.deductions, e.ignored_items, e.disputed_amount,
         e.auto_write_off, e.review_amount, e.confidence, left(coalesce(p_notes, ''), 4000)
    FROM cash_eval(p_token, p_payment, p_invoices, p_deductions, p_confidence) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM cash_applications c
                      WHERE c.client_id = e.client_id AND c.payment_ref = e.payment_ref
                        AND c.status = 'PROPOSED' AND c.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_cash_application_result(p_token TEXT, p_payment TEXT, p_invoices TEXT,
                                                           p_deductions TEXT, p_confidence TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, application_id TEXT, payment_ref TEXT, payer TEXT,
               currency TEXT, payment_amount NUMERIC, invoices TEXT, invoices_total NUMERIC,
               early_pay_discount_earned NUMERIC, deductions TEXT, disputed_amount NUMERIC,
               written_off_within_tolerance NUMERIC, sent_for_review NUMERIC, if_confirmed TEXT, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; c cash_applications;
BEGIN
  SELECT * INTO e FROM cash_eval(p_token, p_payment, p_invoices, p_deductions, p_confidence);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason; payment_ref := e.payment_ref;
  payer := e.payer; currency := e.currency; payment_amount := e.payment_amount;
  IF NOT e.ok THEN RETURN NEXT; RETURN; END IF;
  SELECT * INTO c FROM cash_applications x
   WHERE x.client_id = e.client_id AND x.payment_ref = e.payment_ref AND x.status = 'PROPOSED'
     AND x.expires_at > clock_timestamp()
   ORDER BY x.created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the cash application could not be recorded. Try again.';
    RETURN NEXT; RETURN;
  END IF;
  outcome := 'PROPOSED'; reason_code := 'PROPOSED';
  reason := 'Awaiting the client''s explicit yes. Nothing has been posted yet. Read back the invoices, the early-pay '
            || 'discount, the deductions and what goes to review exactly as given.';
  application_id := c.application_id; invoices := c.invoice_list; invoices_total := c.invoices_total;
  early_pay_discount_earned := c.discount_accepted; deductions := c.deductions; disputed_amount := c.disputed_amount;
  written_off_within_tolerance := c.auto_write_off; sent_for_review := c.review_amount; expires_at := c.expires_at;
  if_confirmed := 'On confirm, ' || money(c.payment_amount, c.currency) || ' is applied to invoice(s) ' || c.invoice_list
                  || CASE WHEN c.discount_accepted > 0 THEN ', the earned early-pay discount of '
                          || money(c.discount_accepted, c.currency) || ' is allowed' ELSE '' END
                  || CASE WHEN c.auto_write_off > 0 THEN ', ' || money(c.auto_write_off, c.currency)
                          || ' of deductions is written off (within the ' || money(small_balance_tolerance(), c.currency)
                          || ' small-balance tolerance)' ELSE '' END
                  || CASE WHEN c.review_amount > 0 THEN ', and the disputed ' || money(c.review_amount, c.currency)
                          || ' stays open on the invoice while Client Servicing reviews the deduction (a person decides)'
                          ELSE '' END || '.';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Confirm row: VOLATILE because it counts confirm calls (so a repeat confirm reads ALREADY_APPLIED). Returns the
-- cash_postings row ONLY for this client's PROPOSED, unexpired application whose invoices are still open as assessed.
CREATE OR REPLACE FUNCTION cash_confirmation_row(p_token TEXT, p_application TEXT)
RETURNS TABLE (application_id TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; c cash_applications; v_open NUMERIC;
BEGIN
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO c FROM cash_applications x WHERE x.application_id = norm_ref(p_application) AND x.client_id = v_cid;
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE cash_applications x SET confirm_count = x.confirm_count + 1 WHERE x.application_id = c.application_id;
  IF c.status <> 'PROPOSED' OR c.expires_at <= clock_timestamp() THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM cash_applications o WHERE o.payment_ref = c.payment_ref AND o.status = 'APPLIED') THEN RETURN; END IF;
  SELECT sum(o.open_amount) INTO v_open FROM open_invoices o
   WHERE o.client_id = v_cid AND o.invoice_no = ANY (norm_invoice_list(c.invoice_list)) AND o.status = 'OPEN';
  IF v_open IS DISTINCT FROM c.invoices_total THEN RETURN; END IF;
  RETURN QUERY SELECT c.application_id::text;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_cash_application_result(p_token TEXT, p_application TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, application_id TEXT, payment_ref TEXT, invoices TEXT,
               currency TEXT, applied_amount NUMERIC, early_pay_discount_earned NUMERIC, written_off_within_tolerance NUMERIC,
               sent_for_review NUMERIC, case_id TEXT, team TEXT, reply_by DATE, invoice_status TEXT) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; c cash_applications; k review_cases; v_open NUMERIC;
BEGIN
  outcome := 'NOT_APPLIED';
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO c FROM cash_applications x WHERE x.application_id = norm_ref(p_application) AND x.client_id = v_cid;
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_APPLICATION';
    reason := 'NO_SUCH_APPLICATION: no cash application with that id for this client. Call propose_cash_application first.';
    RETURN NEXT; RETURN;
  END IF;
  application_id := c.application_id; payment_ref := c.payment_ref; invoices := c.invoice_list; currency := c.currency;
  IF c.status = 'APPLIED' THEN
    applied_amount := c.payment_amount; early_pay_discount_earned := c.discount_accepted;
    written_off_within_tolerance := c.auto_write_off; sent_for_review := c.review_amount; case_id := c.case_id;
    SELECT * INTO k FROM review_cases x WHERE x.case_id = c.case_id;
    team := k.assigned_team; reply_by := k.sla_due_at::date;
    SELECT string_agg('invoice ' || o.invoice_no || ' ' || o.status
                      || CASE WHEN o.open_amount > 0 THEN ' (' || money(o.open_amount, o.currency) || ' open)' ELSE '' END,
                      '; ' ORDER BY o.invoice_no)
      INTO invoice_status FROM open_invoices o
     WHERE o.client_id = v_cid AND o.invoice_no = ANY (norm_invoice_list(c.invoice_list));
    IF c.executed_confirm_no = c.confirm_count THEN
      outcome := 'APPLIED'; reason_code := 'APPLIED';
      reason := 'Cash application ' || c.application_id || ' posted.'
                || CASE WHEN c.review_amount > 0 THEN ' The disputed deduction of ' || money(c.review_amount, c.currency)
                        || ' is with ' || k.assigned_team || ' (case ' || c.case_id || '); a person decides.' ELSE '' END;
    ELSE
      reason_code := 'ALREADY_APPLIED';
      reason := 'ALREADY_APPLIED: this cash application was already posted. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cash_applications o WHERE o.payment_ref = c.payment_ref AND o.status = 'APPLIED') THEN
    reason_code := 'ALREADY_APPLIED'; reason := 'ALREADY_APPLIED: this payment was already applied to invoices.';
  ELSIF c.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the proposal expired after 15 minutes. Propose the cash application again.';
  ELSE
    SELECT sum(o.open_amount) INTO v_open FROM open_invoices o
     WHERE o.client_id = v_cid AND o.invoice_no = ANY (norm_invoice_list(c.invoice_list)) AND o.status = 'OPEN';
    IF v_open IS DISTINCT FROM c.invoices_total THEN
      reason_code := 'INVOICES_CHANGED';
      reason := 'INVOICES_CHANGED: one of the invoices changed since the proposal. Propose the cash application again.';
    ELSE
      reason_code := 'NOT_APPLIED'; reason := 'NOT_APPLIED: the cash application could not be posted. Try again.';
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION audit_cash_application() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (NEW.client_id, 'CASH_APPLICATION_PROPOSED', NEW.application_id,
            NEW.payment_ref || ' -> invoices ' || NEW.invoice_list || '; disputed ' || money(NEW.disputed_amount, NEW.currency)
            || ', for review ' || money(NEW.review_amount, NEW.currency) || ' (confidence ' || NEW.agent_confidence || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_cash_application AFTER INSERT ON cash_applications FOR EACH ROW EXECUTE FUNCTION audit_cash_application();

-- Side effects of a confirmed posting, atomically: allocate payment + earned discount + tolerance write-off to the
-- invoices (oldest first; the disputed amount stays open on the newest), mark the application APPLIED, and park any
-- disputed amount over the tolerance as a DEDUCTION_REVIEW case for Client Servicing (routing from service_teams).
CREATE OR REPLACE FUNCTION apply_cash_posting() RETURNS TRIGGER AS $$
DECLARE a cash_applications; p payments; t service_teams; r RECORD; v_credit NUMERIC; v_take NUMERIC; v_case TEXT;
BEGIN
  SELECT * INTO a FROM cash_applications WHERE application_id = NEW.application_id;
  SELECT * INTO p FROM payments WHERE payment_ref = a.payment_ref;
  v_credit := a.invoices_total - a.review_amount;
  FOR r IN SELECT o.* FROM open_invoices o
            WHERE o.client_id = a.client_id AND o.invoice_no = ANY (norm_invoice_list(a.invoice_list))
            ORDER BY o.invoice_date, o.invoice_no LOOP
    v_take := least(r.open_amount, v_credit);
    UPDATE open_invoices SET open_amount = open_amount - v_take,
           status = CASE WHEN open_amount - v_take <= 0.004 THEN 'PAID' ELSE 'SHORT_PAID' END
     WHERE client_id = r.client_id AND invoice_no = r.invoice_no;
    v_credit := v_credit - v_take;
  END LOOP;
  UPDATE cash_applications SET status = 'APPLIED', executed_confirm_no = confirm_count WHERE application_id = a.application_id;
  INSERT INTO payment_events (payment_ref, actor, action, detail)
    VALUES (a.payment_ref, 'Aurelia Global Bank', 'CASH APPLIED',
            left('Applied to invoices ' || a.invoice_list || ' as ' || a.application_id || '.', 200));
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (a.client_id, 'CASH_APPLIED', a.application_id,
            a.payment_ref || ' ' || money(a.payment_amount, a.currency) || ' -> invoices ' || a.invoice_list
            || '; discount ' || money(a.discount_accepted, a.currency) || ', written off ' || money(a.auto_write_off, a.currency)
            || ', for review ' || money(a.review_amount, a.currency));
  IF a.review_amount > 0 THEN
    SELECT * INTO t FROM service_teams WHERE request_type = 'DEDUCTION_REVIEW';
    INSERT INTO review_cases (client_id, request_type, payment_ref, client_statement, agent_brief, assigned_team, currency,
                              requested_amount, parked_action, created_at)
      VALUES (a.client_id, 'DEDUCTION_REVIEW', a.payment_ref,
              coalesce(nullif(a.remittance_text, ''), coalesce(p.remittance_info, '(no remittance text)')),
              'SYSTEM: cash application ' || a.application_id || ' applied incoming ' || a.payment_ref || ' of '
              || money(a.payment_amount, a.currency) || ' from ' || coalesce(p.ordering_party, 'the payer') || ' to invoice(s) '
              || a.invoice_list || ' (total ' || money(a.invoices_total, a.currency) || '). Early-pay discount earned: '
              || money(a.discount_accepted, a.currency) || '. Deductions (validated): ' || coalesce(a.deductions, 'none')
              || '. Disputed ' || money(a.review_amount, a.currency) || ' is over the ' || money(small_balance_tolerance(), a.currency)
              || ' small-balance tolerance.' || chr(10)
              || 'Agent notes (AI-prepared, unverified): ' || coalesce(nullif(a.agent_notes, ''), '(none)'),
              t.team, a.currency, a.review_amount, 'DEDUCTION_WRITE_OFF:' || a.application_id, NEW.posted_at)
      RETURNING case_id INTO v_case;
    UPDATE cash_applications SET case_id = v_case WHERE application_id = a.application_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_cash_posting AFTER INSERT ON cash_postings FOR EACH ROW EXECUTE FUNCTION apply_cash_posting();

-- =====================================================================
-- PAYMENTS WITH VERIFICATION OF PAYEE (business email compromise defence).
-- The client gives a beneficiary account and the name they believe is on it. check_payee_account returns the account
-- name on file (payee_register, a stand-in for the scheme's name-check service). The payee_name_match_agent compares the
-- two names with the rules in payee_name_guide and returns MATCH / CLOSE_MATCH / NO_MATCH with reasons. SQL validates
-- the verdict and reasons, computes its own name score (normalised with the SAME guide rows) and decides the band:
--   MATCH -> two-step confirm; CLOSE_MATCH up to the hold threshold -> a warning the client must acknowledge;
--   CLOSE_MATCH over it, or NO_MATCH -> HELD + a PAYEE_VERIFICATION case for Payment Operations (a person decides).
-- =====================================================================
CREATE OR REPLACE FUNCTION payee_hold_threshold() RETURNS NUMERIC AS $$ SELECT 10000.00::numeric $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION chat_payment_limit() RETURNS NUMERIC AS $$ SELECT 1000000.00::numeric $$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_account_ref(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$ LANGUAGE sql IMMUTABLE;

-- Company name -> comparable tokens, using payee_name_guide (one rule set for the agent and for SQL):
-- transliterate (Ü = U ...), & -> AND, punctuation -> space, expand abbreviations (INTL = INTERNATIONAL ...),
-- drop legal-form words (LTD, CORP, GMBH ...).
CREATE OR REPLACE FUNCTION payee_name_norm(p TEXT) RETURNS TEXT AS $$
DECLARE v TEXT := upper(coalesce(p, '')); r RECORD; w TEXT; v_map TEXT; v_out TEXT[] := ARRAY[]::text[];
BEGIN
  FOR r IN SELECT split_part(g.term, ' = ', 1) AS f, split_part(g.term, ' = ', 2) AS t
             FROM payee_name_guide g WHERE g.section = 'TRANSLITERATION' LOOP
    v := replace(v, upper(r.f), upper(r.t));
  END LOOP;
  v := replace(v, '&', ' AND ');
  v := btrim(regexp_replace(regexp_replace(v, '[^A-Z0-9 ]', ' ', 'g'), ' +', ' ', 'g'));
  IF v = '' THEN RETURN ''; END IF;
  FOREACH w IN ARRAY string_to_array(v, ' ') LOOP
    v_map := NULL;
    SELECT split_part(g.term, ' = ', 2) INTO v_map FROM payee_name_guide g
     WHERE g.section = 'ABBREVIATION' AND split_part(g.term, ' = ', 1) = w;
    IF coalesce(v_map, '') <> '' THEN w := v_map; END IF;
    CONTINUE WHEN EXISTS (SELECT 1 FROM payee_name_guide g WHERE g.section = 'LEGAL_SUFFIX' AND g.term = w);
    v_out := v_out || w;
  END LOOP;
  RETURN array_to_string(v_out, ' ');
END $$ LANGUAGE plpgsql STABLE;

-- Deterministic name score 0-100: 100 when the normalised names are identical, else the Dice coefficient of their
-- character pairs (spaces removed), capped at 99.
CREATE OR REPLACE FUNCTION name_similarity(p_a TEXT, p_b TEXT) RETURNS INTEGER AS $$
DECLARE na TEXT := payee_name_norm(p_a); nb TEXT := payee_name_norm(p_b); a TEXT; b TEXT; v_common INTEGER;
BEGIN
  a := replace(na, ' ', ''); b := replace(nb, ' ', '');
  IF a = '' OR b = '' THEN RETURN 0; END IF;
  IF na = nb THEN RETURN 100; END IF;
  IF length(a) < 2 OR length(b) < 2 THEN RETURN 0; END IF;
  WITH ga AS (SELECT substr(a, i, 2) AS g, count(*) AS c FROM generate_series(1, length(a) - 1) i GROUP BY 1),
       gb AS (SELECT substr(b, i, 2) AS g, count(*) AS c FROM generate_series(1, length(b) - 1) i GROUP BY 1)
  SELECT coalesce(sum(least(ga.c, gb.c)), 0) INTO v_common FROM ga JOIN gb ON ga.g = gb.g;
  RETURN least(99, round(200.0 * v_common / ((length(a) - 1) + (length(b) - 1))))::int;
END $$ LANGUAGE plpgsql STABLE;

-- The assessment (no session: the seeds use it too). Weights and bands live here, not in any prompt.
CREATE OR REPLACE FUNCTION payee_assessment(p_typed TEXT, p_registered TEXT, p_amount NUMERIC, p_verdict TEXT, p_reasons TEXT)
RETURNS TABLE (agent_verdict TEXT, agent_reasons TEXT, ignored_reasons TEXT, name_score INTEGER, name_check TEXT,
               status TEXT, warning_required BOOLEAN) AS $$
#variable_conflict use_column
DECLARE v_ver TEXT := upper(regexp_replace(btrim(coalesce(p_verdict, '')), '[[:space:]-]+', '_', 'g'));
        v_valid TEXT; v_ignored TEXT; v_score INTEGER; v_check TEXT;
BEGIN
  IF v_ver NOT IN ('MATCH', 'CLOSE_MATCH', 'NO_MATCH') THEN v_ver := NULL; END IF;
  WITH w AS (SELECT DISTINCT upper(regexp_replace(btrim(x), '[^A-Za-z_]', '', 'g')) AS code
               FROM regexp_split_to_table(coalesce(p_reasons, ''), '[,;[:space:]]+') x),
       v AS (SELECT w.code, g.term FROM w
               LEFT JOIN payee_name_guide g ON g.term = w.code AND g.section = 'REASON'
              WHERE w.code NOT IN ('', 'NONE', 'NA', 'N_A'))
  SELECT string_agg(v.code, ', ' ORDER BY v.code) FILTER (WHERE v.term IS NOT NULL),
         string_agg(v.code, ', ' ORDER BY v.code) FILTER (WHERE v.term IS NULL)
    INTO v_valid, v_ignored FROM v;
  v_score := name_similarity(p_typed, p_registered);
  v_check := CASE WHEN v_score = 100 THEN 'MATCH'
                  WHEN v_ver = 'MATCH' AND v_score >= 75 THEN 'MATCH'
                  WHEN v_ver = 'NO_MATCH' OR v_score < 40 THEN 'NO_MATCH'
                  ELSE 'CLOSE_MATCH' END;
  agent_verdict := v_ver; agent_reasons := v_valid; ignored_reasons := v_ignored; name_score := v_score; name_check := v_check;
  status := CASE WHEN v_check = 'NO_MATCH' OR (v_check = 'CLOSE_MATCH' AND p_amount > payee_hold_threshold())
                 THEN 'HELD' ELSE 'PROPOSED' END;
  warning_required := (v_check = 'CLOSE_MATCH' AND status = 'PROPOSED');
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- An account of THIS client from an account_id (ACC-1008), a currency (USD) or the last 4 digits (7750).
CREATE OR REPLACE FUNCTION find_my_account(p_client TEXT, p_account TEXT) RETURNS SETOF accounts AS $$
  SELECT a.* FROM accounts a
   CROSS JOIN (SELECT regexp_replace(upper(trim(coalesce(p_account, ''))), '[[:space:]]*ACCOUNT$', '') AS q) s
   WHERE a.client_id = p_client
     AND (a.account_id = s.q OR a.currency = s.q
          OR (regexp_replace(s.q, '\D', '', 'g') ~ '^[0-9]{4}$' AND s.q NOT LIKE 'ACC%'
              AND right(a.account_number_masked, 4) = regexp_replace(s.q, '\D', '', 'g')))
   ORDER BY a.account_id;
$$ LANGUAGE sql STABLE;

-- Read tool: the account name on file for a beneficiary account (verified clients only).
CREATE OR REPLACE FUNCTION payee_account_check(p_token TEXT, p_account TEXT, p_typed TEXT)
RETURNS TABLE (lookup_status TEXT, reason TEXT, beneficiary_account TEXT, bank_bic TEXT, currency TEXT, rail TEXT,
               name_on_file TEXT, typed_name TEXT) AS $$
  SELECT CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID' WHEN r.account_ref IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         CASE WHEN sc.client_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN r.account_ref IS NULL THEN 'NOT_FOUND: the name-check service has no account ' || norm_account_ref(p_account)
                   || '. Ask the client to check the account number with the payee on a number they already know.'
              ELSE 'Name on file returned. Compare it with the name the client gave before proposing the payment.' END,
         CASE WHEN sc.client_id IS NOT NULL THEN norm_account_ref(p_account) END,
         CASE WHEN sc.client_id IS NOT NULL THEN r.bank_bic::text END,
         CASE WHEN sc.client_id IS NOT NULL THEN r.currency::text END,
         CASE WHEN sc.client_id IS NOT NULL THEN r.rail::text END,
         CASE WHEN sc.client_id IS NOT NULL THEN r.registered_name::text END,
         CASE WHEN sc.client_id IS NOT NULL THEN left(trim(coalesce(p_typed, '')), 120) END
    FROM (SELECT * FROM session_client(p_token)) sc
    LEFT JOIN payee_register r ON r.account_ref = norm_account_ref(p_account) AND sc.client_id IS NOT NULL;
$$ LANGUAGE sql STABLE;

-- Rule: may this client pay this beneficiary account this amount from this account? (no name logic here)
CREATE OR REPLACE FUNCTION payment_eval(p_token TEXT, p_account TEXT, p_beneficiary TEXT, p_typed TEXT, p_amount TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, client_id TEXT, account_id TEXT, account_masked TEXT,
               beneficiary_account TEXT, registered_name TEXT, bank_bic TEXT, currency TEXT, rail TEXT, amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; a accounts; r payee_register; n INTEGER; v_txt TEXT := norm_amount(p_amount); v_amt NUMERIC;
        v_amt_bad BOOLEAN;
BEGIN
  ok := FALSE;
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  client_id := v_cid;
  SELECT count(*) INTO n FROM find_my_account(v_cid, p_account);
  IF n <> 1 THEN
    reason_code := 'ACCOUNT_NOT_FOUND';
    reason := 'ACCOUNT_NOT_FOUND: no single account of this client matches ' || coalesce(nullif(trim(p_account), ''), '(blank)')
              || '. Ask which account to pay from (its currency or last 4 digits).';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO a FROM find_my_account(v_cid, p_account);
  account_id := a.account_id; account_masked := a.account_number_masked;
  SELECT * INTO r FROM payee_register x WHERE x.account_ref = norm_account_ref(p_beneficiary);
  IF NOT FOUND THEN
    reason_code := 'BENEFICIARY_NOT_FOUND';
    reason := 'BENEFICIARY_NOT_FOUND: the name-check service has no account ' || norm_account_ref(p_beneficiary) || '.';
    RETURN NEXT; RETURN;
  END IF;
  beneficiary_account := r.account_ref; registered_name := r.registered_name; bank_bic := r.bank_bic;
  currency := r.currency; rail := r.rail;
  IF trim(coalesce(p_typed, '')) = '' THEN
    reason_code := 'NAME_REQUIRED'; reason := 'NAME_REQUIRED: ask the client for the beneficiary name they expect on the account.';
    RETURN NEXT; RETURN;
  END IF;
  IF a.currency <> r.currency THEN
    reason_code := 'CURRENCY_MISMATCH';
    reason := 'CURRENCY_MISMATCH: account ' || a.account_number_masked || ' is in ' || a.currency || ' but the beneficiary account '
              || 'is in ' || r.currency || '. Pay from an account in ' || r.currency || '.';
    RETURN NEXT; RETURN;
  END IF;
  v_amt_bad := CASE WHEN v_txt ~ '^[0-9]+(\.[0-9]{1,2})?$' THEN v_txt::numeric <= 0 ELSE TRUE END;
  IF v_amt_bad THEN
    reason_code := 'BAD_AMOUNT'; reason := 'BAD_AMOUNT: the amount must be a positive amount, e.g. 185000 or 185000.00.';
    RETURN NEXT; RETURN;
  END IF;
  v_amt := v_txt::numeric; amount := v_amt;
  IF v_amt > chat_payment_limit() THEN
    reason_code := 'OVER_CHANNEL_LIMIT';
    reason := 'OVER_CHANNEL_LIMIT: payments over ' || money(chat_payment_limit(), r.currency)
              || ' cannot be submitted through the assistant; use the corporate portal with dual authorisation.';
    RETURN NEXT; RETURN;
  END IF;
  ok := TRUE; reason_code := 'ELIGIBLE'; reason := 'ELIGIBLE';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row for propose_payment: the assessed request is written ONLY when every payment rule passes, and not
-- twice (an unexpired PROPOSED or a HELD request for the same account / beneficiary / amount is reused).
CREATE OR REPLACE FUNCTION payment_request_row(p_token TEXT, p_account TEXT, p_beneficiary TEXT, p_typed TEXT,
                                               p_amount TEXT, p_purpose TEXT, p_verdict TEXT, p_reasons TEXT, p_notes TEXT)
RETURNS TABLE (client_id TEXT, account_id TEXT, beneficiary_account TEXT, typed_name TEXT, registered_name TEXT,
               amount NUMERIC, currency TEXT, rail TEXT, purpose TEXT, agent_verdict TEXT, agent_reasons TEXT,
               ignored_reasons TEXT, agent_notes TEXT, name_score INTEGER, name_check TEXT, status TEXT,
               warning_required BOOLEAN) AS $$
  SELECT e.client_id, e.account_id, e.beneficiary_account, left(trim(p_typed), 120), e.registered_name, e.amount,
         e.currency, e.rail, left(coalesce(p_purpose, ''), 2000), s.agent_verdict, s.agent_reasons, s.ignored_reasons,
         left(coalesce(p_notes, ''), 4000), s.name_score, s.name_check, s.status, s.warning_required
    FROM payment_eval(p_token, p_account, p_beneficiary, p_typed, p_amount) e
    CROSS JOIN LATERAL payee_assessment(p_typed, e.registered_name, e.amount, p_verdict, p_reasons) s
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM payment_requests r
                      WHERE r.client_id = e.client_id AND r.account_id = e.account_id
                        AND r.beneficiary_account = e.beneficiary_account AND r.amount = e.amount
                        AND ((r.status = 'PROPOSED' AND r.expires_at > clock_timestamp()) OR r.status = 'HELD'));
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION payee_warning_text(p_registered TEXT) RETURNS TEXT AS $$
  SELECT 'The name you gave does not exactly match the name on this account. The account is held in the name of '
         || p_registered || '. If you are not sure this is the company you mean to pay, do not send the payment: call '
         || 'the payee on a phone number you already know (not one from the email or invoice) and confirm their account '
         || 'details. A payment sent to the wrong account may not be recoverable.'
$$ LANGUAGE sql IMMUTABLE;

-- Readback for propose_payment. The client sees the name check result and the name on file, never the score or the
-- agent's reasons.
CREATE OR REPLACE FUNCTION propose_payment_result(p_token TEXT, p_account TEXT, p_beneficiary TEXT, p_typed TEXT, p_amount TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, request_id TEXT, from_account TEXT, beneficiary_account TEXT,
               name_on_file TEXT, name_check TEXT, amount NUMERIC, currency TEXT, rail TEXT, warning_text TEXT,
               case_id TEXT, team TEXT, reply_by DATE, expires_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE e RECORD; r payment_requests; c review_cases;
BEGIN
  SELECT * INTO e FROM payment_eval(p_token, p_account, p_beneficiary, p_typed, p_amount);
  outcome := 'NOT_PROPOSED'; reason_code := e.reason_code; reason := e.reason;
  from_account := e.account_masked; beneficiary_account := e.beneficiary_account; amount := e.amount;
  currency := e.currency; rail := e.rail;
  IF NOT e.ok THEN RETURN NEXT; RETURN; END IF;
  SELECT * INTO r FROM payment_requests x
   WHERE x.client_id = e.client_id AND x.account_id = e.account_id AND x.beneficiary_account = e.beneficiary_account
     AND x.amount = e.amount AND ((x.status = 'PROPOSED' AND x.expires_at > clock_timestamp()) OR x.status = 'HELD')
   ORDER BY x.created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    reason_code := 'NOT_PROPOSED'; reason := 'NOT_PROPOSED: the payment could not be recorded. Try again.';
    RETURN NEXT; RETURN;
  END IF;
  request_id := r.request_id; name_on_file := r.registered_name; name_check := r.name_check;
  IF r.status = 'HELD' THEN
    SELECT * INTO c FROM review_cases s WHERE s.case_id = r.case_id;
    outcome := 'HELD_FOR_REVIEW'; reason_code := 'HELD_FOR_REVIEW';
    reason := 'For your protection this payment is paused and no money has left your account: the name you gave does not '
              || 'match the name on the account closely enough. Aurelia''s Payment Operations team will verify the payee with '
              || 'your company''s authorised contact by ' || to_char(c.sla_due_at, 'YYYY-MM-DD') || '. Changed bank details '
              || 'sent by email are a common fraud, so please do not send this money another way in the meantime.';
    case_id := c.case_id; team := c.assigned_team; reply_by := c.sla_due_at::date;
  ELSIF r.warning_required THEN
    outcome := 'PROPOSED_WITH_WARNING'; reason_code := 'WARNING_REQUIRED';
    reason := 'Nothing has been sent. Read the warning_text to the client word for word; send only if they then say they '
              || 'have checked the payee and still want to go ahead (confirm_payment with acknowledge_warning YES).';
    warning_text := payee_warning_text(r.registered_name); expires_at := r.expires_at;
  ELSE
    outcome := 'PROPOSED'; reason_code := 'PROPOSED';
    reason := 'Awaiting the client''s explicit yes. Nothing has been sent yet.'; expires_at := r.expires_at;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION ack_yes(p TEXT) RETURNS BOOLEAN AS $$
  SELECT upper(trim(coalesce(p, ''))) IN ('YES', 'Y', 'TRUE', 'ACKNOWLEDGED', 'I ACKNOWLEDGE', 'CONFIRMED', 'I UNDERSTAND')
$$ LANGUAGE sql IMMUTABLE;

-- Confirm row: VOLATILE because it counts confirm calls (so a repeat confirm reads ALREADY_SENT). Returns the
-- payment_releases row ONLY for this client's PROPOSED, unexpired request whose rules still pass (and, for a
-- CLOSE_MATCH request, only when the client acknowledged the warning).
CREATE OR REPLACE FUNCTION payment_confirmation_row(p_token TEXT, p_request TEXT, p_ack TEXT)
RETURNS TABLE (request_id TEXT, via TEXT, case_id TEXT, amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; r payment_requests; e RECORD;
BEGIN
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM payment_requests x WHERE x.request_id = norm_ref(p_request) AND x.client_id = v_cid;
  IF NOT FOUND THEN RETURN; END IF;
  UPDATE payment_requests x SET confirm_count = x.confirm_count + 1 WHERE x.request_id = r.request_id;
  IF r.status <> 'PROPOSED' OR r.expires_at <= clock_timestamp() THEN RETURN; END IF;
  IF r.warning_required AND NOT ack_yes(p_ack) THEN RETURN; END IF;
  SELECT * INTO e FROM payment_eval(p_token, r.account_id, r.beneficiary_account, r.typed_name, r.amount::text);
  IF NOT e.ok THEN RETURN; END IF;
  RETURN QUERY SELECT r.request_id::text, 'CLIENT'::text, NULL::text, r.amount;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_payment_result(p_token TEXT, p_request TEXT, p_ack TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, request_id TEXT, payment_ref TEXT, beneficiary_name TEXT,
               amount NUMERIC, currency TEXT, rail TEXT, value_date DATE, submitted_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cid TEXT; r payment_requests; s payment_releases; p payments; e RECORD;
BEGIN
  outcome := 'NOT_SENT';
  SELECT sc.client_id INTO v_cid FROM session_client(p_token) sc;
  IF v_cid IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO r FROM payment_requests x WHERE x.request_id = norm_ref(p_request) AND x.client_id = v_cid;
  IF NOT FOUND THEN
    reason_code := 'NO_SUCH_REQUEST'; reason := 'NO_SUCH_REQUEST: no payment request with that id for this client. Call propose_payment first.';
    RETURN NEXT; RETURN;
  END IF;
  request_id := r.request_id; amount := r.amount; currency := r.currency; rail := r.rail; beneficiary_name := r.registered_name;
  SELECT * INTO s FROM payment_releases x WHERE x.request_id = r.request_id;
  IF FOUND THEN
    SELECT * INTO p FROM payments x WHERE x.payment_ref = r.payment_ref;
    payment_ref := r.payment_ref; value_date := p.value_date; submitted_at := s.released_at;
    IF s.via = 'CLIENT' AND r.executed_confirm_no = r.confirm_count THEN
      outcome := 'SENT'; reason_code := 'SENT';
      reason := 'Payment ' || r.payment_ref || ' submitted on the ' || r.rail || ' rail.';
    ELSE
      reason_code := 'ALREADY_SENT'; reason := 'ALREADY_SENT: this payment was already submitted as ' || r.payment_ref || '. Nothing new was done.';
    END IF;
    RETURN NEXT; RETURN;
  END IF;
  IF r.status = 'HELD' THEN
    reason_code := 'HELD_FOR_REVIEW';
    reason := 'HELD_FOR_REVIEW: this payment is paused while Payment Operations verifies the payee. It cannot be sent from here.';
  ELSIF r.status = 'CANCELLED' THEN
    reason_code := 'CANCELLED'; reason := 'CANCELLED: this payment was stopped after the payee check. No money moved.';
  ELSIF r.expires_at <= clock_timestamp() THEN
    reason_code := 'EXPIRED'; reason := 'EXPIRED: the payment proposal expired after 15 minutes. Propose it again.';
  ELSIF r.warning_required AND NOT ack_yes(p_ack) THEN
    reason_code := 'WARNING_NOT_ACKNOWLEDGED';
    reason := 'WARNING_NOT_ACKNOWLEDGED: this payment can only be sent after the client has read the name-check warning and '
              || 'says they still want to go ahead.';
  ELSE
    SELECT * INTO e FROM payment_eval(p_token, r.account_id, r.beneficiary_account, r.typed_name, r.amount::text);
    reason_code := e.reason_code; reason := e.reason;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- A HELD request: open the PAYEE_VERIFICATION case for Payment Operations (routing from service_teams), with a brief
-- built from the name check, the validated agent verdict and the agent's notes (reviewer-only).
CREATE OR REPLACE FUNCTION apply_payment_request() RETURNS TRIGGER AS $$
DECLARE t service_teams; v_case TEXT;
BEGIN
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (NEW.client_id, 'PAYMENT_PROPOSED', NEW.request_id,
            money(NEW.amount, NEW.currency) || ' to account ' || NEW.beneficiary_account || ' from ' || NEW.account_id
            || ': name check ' || NEW.name_check || ' (score ' || NEW.name_score || '), status ' || NEW.status);
  IF NEW.status = 'HELD' THEN
    SELECT * INTO t FROM service_teams WHERE request_type = 'PAYEE_VERIFICATION';
    INSERT INTO review_cases (client_id, request_type, client_statement, agent_brief, assigned_team, currency,
                              requested_amount, parked_action, created_at)
      VALUES (NEW.client_id, 'PAYEE_VERIFICATION', coalesce(nullif(NEW.purpose, ''), '(no statement)'),
              'SYSTEM: payment request ' || NEW.request_id || ' of ' || money(NEW.amount, NEW.currency) || ' to account '
              || NEW.beneficiary_account || ' was HELD. Name given: "' || NEW.typed_name || '"; name on file: "'
              || NEW.registered_name || '"; name check ' || NEW.name_check || ' (deterministic score ' || NEW.name_score
              || ' of 100).' || chr(10)
              || 'Agent verdict (validated): ' || coalesce(NEW.agent_verdict, 'none') || '; reasons: '
              || coalesce(NEW.agent_reasons, 'none') || '.' || chr(10)
              || 'Agent notes (AI-prepared, unverified): ' || coalesce(nullif(NEW.agent_notes, ''), '(none)'),
              t.team, NEW.currency, NEW.amount, 'RELEASE_PAYMENT:' || NEW.request_id, NEW.created_at)
      RETURNING case_id INTO v_case;
    UPDATE payment_requests SET case_id = v_case WHERE request_id = NEW.request_id;
    INSERT INTO agent_audit (client_id, action, ref, detail)
      VALUES (NEW.client_id, 'PAYMENT_HELD', NEW.request_id, 'held for payee verification in ' || v_case);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_payment_request AFTER INSERT ON payment_requests FOR EACH ROW EXECUTE FUNCTION apply_payment_request();

-- Side effects of a submitted payment, atomically: the new payment row (INITIATED, value date from cutoff_rules),
-- its first timeline event, the request status, the audit row.
CREATE OR REPLACE FUNCTION apply_payment_release() RETURNS TRIGGER AS $$
DECLARE r payment_requests; g payee_register; cr cutoff_rules; v_ref TEXT;
BEGIN
  SELECT * INTO r FROM payment_requests WHERE request_id = NEW.request_id;
  SELECT * INTO g FROM payee_register WHERE account_ref = r.beneficiary_account;
  SELECT * INTO cr FROM cutoff_rules x WHERE x.rail = r.rail AND x.currency = r.currency;
  INSERT INTO payments (client_id, debtor_account, direction, rail, amount, currency, fx_rate, fees, beneficiary_name,
                        beneficiary_bank_bic, status, value_date, created_at)
    VALUES (r.client_id, r.account_id, 'OUTGOING', r.rail, NEW.amount, r.currency, NULL, 0, r.registered_name, g.bank_bic,
            'INITIATED', add_business_days(current_date, coalesce(cr.settlement_days, 0)), NEW.released_at)
    RETURNING payment_ref INTO v_ref;
  INSERT INTO payment_events (payment_ref, event_time, actor, action, detail)
    VALUES (v_ref, NEW.released_at, 'Aurelia Global Bank', 'INITIATED',
            left('Payment instruction received (request ' || r.request_id || ', name check ' || r.name_check
                 || CASE WHEN NEW.via = 'REVIEWER' THEN ', released by Payment Operations' ELSE '' END || ').', 200));
  UPDATE payment_requests SET status = CASE WHEN NEW.via = 'REVIEWER' THEN 'RELEASED' ELSE 'SENT' END, payment_ref = v_ref,
         executed_confirm_no = CASE WHEN NEW.via = 'CLIENT' THEN confirm_count END
   WHERE request_id = NEW.request_id;
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (r.client_id, 'PAYMENT_SENT', NEW.request_id,
            v_ref || ' ' || money(NEW.amount, r.currency) || ' to ' || r.beneficiary_account || ' via ' || NEW.via
            || coalesce(' (case ' || NEW.case_id || ')', ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_payment_release AFTER INSERT ON payment_releases FOR EACH ROW EXECUTE FUNCTION apply_payment_release();

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================

-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE split_part(coalesce(s.parked_action, ''), ':', 1)
           WHEN 'FEE_REFUND' THEN (SELECT p.fees FROM payments p WHERE p.payment_ref = split_part(s.parked_action, ':', 2))
           WHEN 'RECALL' THEN (SELECT p.amount FROM payments p WHERE p.payment_ref = split_part(s.parked_action, ':', 2))
           WHEN 'RELEASE_PAYMENT' THEN (SELECT r.amount FROM payment_requests r WHERE r.request_id = split_part(s.parked_action, ':', 2))
           WHEN 'DEDUCTION_WRITE_OFF' THEN (SELECT c.review_amount FROM cash_applications c
                                             WHERE c.application_id = split_part(s.parked_action, ':', 2))
           ELSE s.requested_amount END
    FROM review_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: the company name, no contact email, client id or passcode).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE split_part(coalesce(s.parked_action, ''), ':', 1)
    WHEN 'FEE_REFUND' THEN
      'Fee of ' || money(fp.fees, fp.currency) || ' on payment ' || fp.payment_ref || ' (' || fp.direction || ' ' || fp.rail || ' '
      || money(fp.amount, fp.currency) || ' to ' || fp.beneficiary_name || ', created ' || to_char(fp.created_at, 'YYYY-MM-DD')
      || '); fee refunds for this client in the last 12 months: '
      || (SELECT count(*) FROM fee_refunds f JOIN payments x ON x.payment_ref = f.payment_ref
           WHERE x.client_id = s.client_id AND f.refunded_at > clock_timestamp() - INTERVAL '365 days')
    WHEN 'RECALL' THEN
      'Payment ' || rp.payment_ref || ': ' || rp.direction || ' ' || rp.rail || ' ' || money(rp.amount, rp.currency) || ' to '
      || rp.beneficiary_name || ' (' || rp.beneficiary_bank_bic || '), value date ' || to_char(rp.value_date, 'YYYY-MM-DD')
      || ', status ' || rp.status || coalesce(' (was ' || rp.status_before_recall || ')', '')
      || coalesce('; recall reason ' || pa.reason_code || ' - ' || rc.plain_language, '')
      || '; approving sends the recall to the beneficiary bank and returns the funds to the client''s account (demo); '
      || 'rejecting puts the payment back to ' || coalesce(rp.status_before_recall, 'its previous status')
    WHEN 'RELEASE_PAYMENT' THEN
      'Payment request ' || pr.request_id || ' of ' || money(pr.amount, pr.currency) || ' from account '
      || pa2.account_number_masked || ' to account ' || pr.beneficiary_account || ' (' || pg.bank_bic || ', ' || pr.rail
      || '); name given "' || pr.typed_name || '", name on file "' || pr.registered_name || '"; name check ' || pr.name_check
      || ' (deterministic score ' || pr.name_score || ' of 100); agent verdict ' || coalesce(pr.agent_verdict, 'none')
      || ', reasons ' || coalesce(pr.agent_reasons, 'none') || '; request status ' || pr.status
    WHEN 'DEDUCTION_WRITE_OFF' THEN
      'Cash application ' || ca.application_id || ': incoming ' || ca.payment_ref || ' of ' || money(ca.payment_amount, ca.currency)
      || ' from ' || coalesce(cp.ordering_party, 'the payer') || ' applied to invoice(s) ' || ca.invoice_list || ' (total '
      || money(ca.invoices_total, ca.currency) || '); early-pay discount earned ' || money(ca.discount_accepted, ca.currency)
      || '; deductions ' || coalesce(ca.deductions, 'none') || '; disputed ' || money(ca.review_amount, ca.currency)
      || ' (small-balance tolerance ' || money(small_balance_tolerance(), ca.currency) || '); still open: '
      || coalesce((SELECT string_agg('invoice ' || o.invoice_no || ' ' || money(o.open_amount, o.currency), ', ' ORDER BY o.invoice_no)
                     FROM open_invoices o WHERE o.client_id = ca.client_id
                      AND o.invoice_no = ANY (norm_invoice_list(ca.invoice_list)) AND o.open_amount > 0), 'nothing')
    ELSE
      CASE WHEN s.payment_ref IS NOT NULL THEN
        'Payment ' || op.payment_ref || ': ' || op.direction || ' ' || op.rail || ' ' || money(op.amount, op.currency) || ' to '
        || op.beneficiary_name || ', status ' || op.status
      ELSE 'No linked record.' END
    END
    FROM review_cases s
    LEFT JOIN payments fp ON fp.payment_ref = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'FEE\_REFUND:%'
    LEFT JOIN payments rp ON rp.payment_ref = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'RECALL:%'
    LEFT JOIN pending_actions pa ON pa.action_id = s.action_id
    LEFT JOIN reason_codes rc ON rc.code = pa.reason_code
    LEFT JOIN payment_requests pr ON pr.request_id = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'RELEASE\_PAYMENT:%'
    LEFT JOIN accounts pa2 ON pa2.account_id = pr.account_id
    LEFT JOIN payee_register pg ON pg.account_ref = pr.beneficiary_account
    LEFT JOIN cash_applications ca ON ca.application_id = split_part(s.parked_action, ':', 2)
                                  AND s.parked_action LIKE 'DEDUCTION\_WRITE\_OFF:%'
    LEFT JOIN payments cp ON cp.payment_ref = ca.payment_ref
    LEFT JOIN payments op ON op.payment_ref = s.payment_ref
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue: OPEN cases ordered by reply-due time. Another team's cases never appear.
CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, client TEXT, opened_on DATE, age_days INTEGER,
               reply_due DATE, sla_status TEXT, requested_amount NUMERIC, currency VARCHAR) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.client, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested_amount,
         q.currency
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, t.label, client_display(s.client_id) AS client, s.created_at::date AS opened_on,
             (current_date - s.created_at::date)::int AS age_days, s.sla_due_at::date AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.currency, s.sla_due_at
        FROM review_cases s JOIN service_teams t ON t.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND t.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at, q.case_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, client TEXT, opened_on DATE,
               reply_due DATE, client_statement TEXT, agent_brief TEXT, currency VARCHAR, requested_amount NUMERIC,
               max_approvable NUMERIC, your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on DATE,
               decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, t.label, s.status, client_display(s.client_id), s.created_at::date, s.sla_due_at::date,
         s.client_statement, s.agent_brief, s.currency, s.requested_amount, case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.parked_action LIKE 'RECALL:%' OR s.parked_action LIKE 'RELEASE\_PAYMENT:%' THEN
                   CASE WHEN s.parked_action LIKE 'RECALL:%' THEN 'APPROVE sends the recall for the full amount ('
                        ELSE 'APPROVE releases the held payment in full (' END
                   || money(case_eligible_max(s.case_id), s.currency) || ')'
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN ' - above your ' || money(sr.approval_limit, s.currency) || ' limit it needs a senior reviewer'
                           ELSE '' END
                   || CASE WHEN s.parked_action LIKE 'RECALL:%' THEN '; REJECT declines the recall (the payment goes on).'
                           ELSE '; REJECT cancels it (no money moves).' END
                   || ' Give an internal note and a message for the client.'
              WHEN case_eligible_max(s.case_id) IS NOT NULL THEN 'APPROVE (any amount up to '
                   || money(case_eligible_max(s.case_id), s.currency)
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN '; above your ' || money(sr.approval_limit, s.currency) || ' limit it needs a senior reviewer'
                           ELSE '' END
                   || ') or REJECT, with an internal note and a message for the client.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the client.' END,
         s.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || money(rd.approved_amount, s.currency), '') FROM review_decisions rd
           WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN review_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT x.request_type FROM service_teams x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN service_teams t ON t.request_type = s.request_type;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT,
               customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s review_cases; t service_teams; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_txt TEXT := norm_amount(p_amount); v_msg TEXT; v_full BOOLEAN;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM review_cases x WHERE x.case_id = v_ref;
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
                WHEN 'REJECT' THEN 'REJECT' WHEN 'REJECTED' THEN 'REJECT' WHEN 'DENY' THEN 'REJECT' WHEN 'DENIED' THEN 'REJECT'
                WHEN 'DECLINE' THEN 'REJECT' WHEN 'DECLINED' THEN 'REJECT' END;
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
  v_full := s.parked_action LIKE 'RECALL:%' OR s.parked_action LIKE 'RELEASE\_PAYMENT:%';
  IF v_dec = 'APPROVE' AND v_max IS NOT NULL THEN
    v_amt := CASE WHEN v_txt = '' OR v_txt = 'ALL' OR v_txt = 'FULL' THEN v_max
                  WHEN v_txt ~ '^-?[0-9]+(\.[0-9]+)?$' THEN round(v_txt::numeric, 2) END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max OR (v_full AND v_amt <> v_max) THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID',
                CASE WHEN s.parked_action LIKE 'RECALL:%'
                     THEN 'A recall is approved for the full payment (' || money(v_max, s.currency) || ') or rejected.'
                     WHEN s.parked_action LIKE 'RELEASE\_PAYMENT:%'
                     THEN 'A held payment is released in full (' || money(v_max, s.currency) || ') or rejected.'
                     ELSE 'The approved amount must be more than 0 and no more than ' || money(v_max, s.currency)
                          || ' for this case.' END);
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', money(v_amt, s.currency) || ' is above your approval limit of '
                || money(rv.approval_limit, s.currency) || '. The case stays open and needs a senior reviewer.');
      RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || t.label || ' has been approved'
                       || coalesce(' for ' || money(v_amt, s.currency), '') || '.'
                  ELSE 'After review, your ' || t.label || ' was not approved. Your relationship manager will explain the decision.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, currency VARCHAR, reason_code VARCHAR,
               reason_text TEXT, case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED')
                   OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.approved_amount END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN s.currency END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND'
                   AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'Fee on ' || f.payment_ref || ' refunded: ' || money(f.amount, s.currency) || ' credited.'
                            FROM fee_refunds f WHERE f.case_id = s.case_id),
                         (SELECT 'Recall of ' || r.payment_ref || ' (' || money(r.amount, s.currency) || ') sent to the beneficiary '
                                 || 'bank; payment is RECALLED and the funds are returned to the client''s account.'
                            FROM payment_recalls r WHERE r.case_id = s.case_id),
                         (SELECT 'Payment request ' || x.request_id || ' released and submitted as ' || q.payment_ref || ' ('
                                 || money(x.amount, s.currency) || ').'
                            FROM payment_releases x JOIN payment_requests q ON q.request_id = x.request_id WHERE x.case_id = s.case_id),
                         (SELECT 'Deduction of ' || money(w.amount, s.currency) || ' accepted and written off (' || w.writeoff_id
                                 || '); the invoice balance is closed by that amount.'
                            FROM deduction_writeoffs w WHERE w.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN
                CASE WHEN s.parked_action LIKE 'RELEASE\_PAYMENT:%' THEN 'Case rejected; the held payment was cancelled and no money moved.'
                     WHEN s.parked_action LIKE 'RECALL:%' THEN 'Case rejected; the recall was declined and the payment status restored.'
                     WHEN s.parked_action LIKE 'DEDUCTION\_WRITE\_OFF:%' THEN 'Case rejected; the deduction is not accepted and '
                          || 'the disputed amount stays open on the invoice for collection.'
                     ELSE 'Case rejected; nothing was executed.' END END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN review_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id;
$$ LANGUAGE sql STABLE;

-- Guarded rows the decision trigger uses to execute the parked action (the same checks every time).
CREATE OR REPLACE FUNCTION fee_refund_row(p_ref TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (payment_ref VARCHAR, case_id TEXT, amount NUMERIC) AS $$
  SELECT p.payment_ref, p_case, p_amount
    FROM payments p
   WHERE p.payment_ref = p_ref AND p.fees > 0 AND p_amount > 0 AND p_amount <= p.fees AND NOT fee_refunded(p.payment_ref)
     AND EXISTS (SELECT 1 FROM review_cases s WHERE s.case_id = p_case AND s.parked_action = 'FEE_REFUND:' || p.payment_ref);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION recall_execute_row(p_ref TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (payment_ref VARCHAR, case_id TEXT, amount NUMERIC) AS $$
  SELECT p.payment_ref, p_case, p.amount
    FROM payments p
   WHERE p.payment_ref = p_ref AND p.status = 'RECALL_REQUESTED' AND p_amount = p.amount
     AND NOT EXISTS (SELECT 1 FROM payment_recalls r WHERE r.payment_ref = p.payment_ref)
     AND EXISTS (SELECT 1 FROM review_cases s WHERE s.case_id = p_case AND s.parked_action = 'RECALL:' || p.payment_ref);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION payment_release_row(p_request TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (request_id TEXT, via TEXT, case_id TEXT, amount NUMERIC) AS $$
  SELECT r.request_id::text, 'REVIEWER'::text, p_case, r.amount
    FROM payment_requests r
   WHERE r.request_id = p_request AND r.status = 'HELD' AND r.case_id = p_case AND p_amount = r.amount
     AND NOT EXISTS (SELECT 1 FROM payment_releases x WHERE x.request_id = r.request_id);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION deduction_writeoff_row(p_application TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (application_id VARCHAR, case_id TEXT, amount NUMERIC) AS $$
  SELECT c.application_id, p_case, p_amount
    FROM cash_applications c
   WHERE c.application_id = p_application AND c.status = 'APPLIED' AND p_amount > 0 AND p_amount <= c.review_amount
     AND NOT EXISTS (SELECT 1 FROM deduction_writeoffs w WHERE w.application_id = c.application_id)
     AND EXISTS (SELECT 1 FROM review_cases s WHERE s.case_id = p_case AND s.parked_action = 'DEDUCTION_WRITE_OFF:' || c.application_id);
$$ LANGUAGE sql STABLE;

-- The decision event: case status + client message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s review_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'nothing';
BEGIN
  SELECT * INTO s FROM review_cases WHERE case_id = NEW.case_id;
  UPDATE review_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF NEW.decision = 'APPROVE' AND v_kind = 'FEE_REFUND' THEN
    INSERT INTO fee_refunds (payment_ref, case_id, amount) SELECT * FROM fee_refund_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'fee on ' || v_ref || ' refunded ' || money(NEW.approved_amount, s.currency); END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'RECALL' THEN
    INSERT INTO payment_recalls (payment_ref, case_id, amount) SELECT * FROM recall_execute_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'recall of ' || v_ref || ' executed ' || money(NEW.approved_amount, s.currency); END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'RELEASE_PAYMENT' THEN
    INSERT INTO payment_releases (request_id, via, case_id, amount)
      SELECT * FROM payment_release_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'payment request ' || v_ref || ' released ' || money(NEW.approved_amount, s.currency); END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'DEDUCTION_WRITE_OFF' THEN
    INSERT INTO deduction_writeoffs (application_id, case_id, amount)
      SELECT * FROM deduction_writeoff_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'deduction on ' || v_ref || ' written off ' || money(NEW.approved_amount, s.currency); END IF;
  ELSIF NEW.decision = 'REJECT' AND v_kind = 'RELEASE_PAYMENT' THEN
    UPDATE payment_requests SET status = 'CANCELLED' WHERE request_id = v_ref AND status = 'HELD';
    v_done := 'payment request ' || v_ref || ' cancelled (no money moved)';
  ELSIF NEW.decision = 'REJECT' AND v_kind = 'RECALL' THEN
    UPDATE payments SET status = coalesce(status_before_recall, 'IN_TRANSIT'), status_before_recall = NULL
     WHERE payment_ref = v_ref AND status = 'RECALL_REQUESTED';
    INSERT INTO payment_events (payment_ref, actor, action, detail)
      VALUES (v_ref, 'Aurelia Global Bank', 'RECALL DECLINED', left('Payment Operations declined recall case ' || NEW.case_id || '.', 200));
    v_done := 'recall of ' || v_ref || ' declined (status restored)';
  END IF;
  INSERT INTO agent_audit (client_id, actor, action, ref, detail)
    VALUES (s.client_id, NEW.reviewer_id, 'CASE_DECIDED', NEW.case_id,
            NEW.decision || coalesce(' ' || money(NEW.approved_amount, s.currency), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- An approved recall (event row + trigger, never an UPDATE from a tool).
CREATE OR REPLACE FUNCTION apply_payment_recall() RETURNS TRIGGER AS $$
BEGIN
  UPDATE payments SET status = 'RECALLED' WHERE payment_ref = NEW.payment_ref;
  INSERT INTO payment_events (payment_ref, actor, action, detail)
    VALUES (NEW.payment_ref, 'Aurelia Global Bank', 'RECALLED',
            left('Recall approved in case ' || NEW.case_id || '; recall sent to the beneficiary bank and funds returned.', 200));
  INSERT INTO agent_audit (client_id, action, ref, detail)
    SELECT p.client_id, 'PAYMENT_RECALLED', NEW.payment_ref, money(NEW.amount, p.currency) || ' (case ' || NEW.case_id || ')'
      FROM payments p WHERE p.payment_ref = NEW.payment_ref;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_payment_recall AFTER INSERT ON payment_recalls FOR EACH ROW EXECUTE FUNCTION apply_payment_recall();

-- An approved fee refund.
CREATE OR REPLACE FUNCTION apply_fee_refund() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO payment_events (payment_ref, actor, action, detail)
    SELECT NEW.payment_ref, 'Aurelia Global Bank', 'FEE REFUNDED',
           left('Fee of ' || money(NEW.amount, p.currency) || ' refunded (case ' || NEW.case_id || ').', 200)
      FROM payments p WHERE p.payment_ref = NEW.payment_ref;
  INSERT INTO agent_audit (client_id, action, ref, detail)
    SELECT p.client_id, 'FEE_REFUNDED', NEW.payment_ref, money(NEW.amount, p.currency) || ' (case ' || NEW.case_id || ')'
      FROM payments p WHERE p.payment_ref = NEW.payment_ref;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_fee_refund AFTER INSERT ON fee_refunds FOR EACH ROW EXECUTE FUNCTION apply_fee_refund();

-- An accepted deduction closes the open invoice balance by that amount (newest invoice first).
CREATE OR REPLACE FUNCTION apply_deduction_writeoff() RETURNS TRIGGER AS $$
DECLARE a cash_applications; r RECORD; v_left NUMERIC := NEW.amount; v_take NUMERIC;
BEGIN
  SELECT * INTO a FROM cash_applications WHERE application_id = NEW.application_id;
  FOR r IN SELECT o.* FROM open_invoices o
            WHERE o.client_id = a.client_id AND o.invoice_no = ANY (norm_invoice_list(a.invoice_list)) AND o.open_amount > 0
            ORDER BY o.invoice_date DESC, o.invoice_no DESC LOOP
    EXIT WHEN v_left <= 0;
    v_take := least(r.open_amount, v_left);
    UPDATE open_invoices SET open_amount = open_amount - v_take,
           status = CASE WHEN open_amount - v_take <= 0.004 THEN 'PAID' ELSE 'SHORT_PAID' END
     WHERE client_id = r.client_id AND invoice_no = r.invoice_no;
    v_left := v_left - v_take;
  END LOOP;
  INSERT INTO agent_audit (client_id, action, ref, detail)
    VALUES (a.client_id, 'DEDUCTION_WRITTEN_OFF', NEW.writeoff_id,
            money(NEW.amount, a.currency) || ' on ' || a.application_id || ' (case ' || NEW.case_id || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_deduction_writeoff AFTER INSERT ON deduction_writeoffs FOR EACH ROW EXECUTE FUNCTION apply_deduction_writeoff();

-- =====================================================================
-- AGENT REFERENCE READS - the only SQL the remittance_match_agent and payee_name_match_agent tools run
-- (SELECT * FROM ref_<topic>(CAST(?lookup AS text))). SELECT-only, STABLE, no identity argument. p_term is the one
-- value the model may supply: empty / NULL -> the whole guide; otherwise one or more words separated by , or ; - a row
-- matches when a word equals its section (spaces = underscores) or appears in its term or meaning (plain substring, no
-- wildcards). Unknown words -> 0 rows (never an error). (The payment_triage_agent keeps its lookup_reason_code() read.)
-- =====================================================================
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION ref_remittance_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM remittance_guide g
          UNION ALL                                 -- who decides a disputed deduction: service_teams is the source of truth
          SELECT 'WHO_DECIDES', t.label::text,
                 t.team::text || ' decides disputed deductions over the ' || money(small_balance_tolerance(), 'USD')
                 || ' small-balance tolerance and replies within ' || t.reply_business_days || ' business day(s).', 1000
            FROM service_teams t WHERE t.request_type = 'DEDUCTION_REVIEW') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['DEDUCTION','NOTE_PATTERN','MATCH_RULE','CONFIDENCE','REVIEW_LINE','WHO_DECIDES'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_payee_name_rules(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM payee_name_guide g
          UNION ALL                                 -- who decides a held payment: service_teams is the source of truth
          SELECT 'WHO_DECIDES', t.label::text,
                 t.team::text || ' verifies the payee with the client''s authorised contact and decides within '
                 || t.reply_business_days || ' business day(s); the payment does not move until a person decides.', 1000
            FROM service_teams t WHERE t.request_type = 'PAYEE_VERIFICATION') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['VERDICT','REASON','LEGAL_SUFFIX','ABBREVIATION','TRANSLITERATION','WHO_DECIDES'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
