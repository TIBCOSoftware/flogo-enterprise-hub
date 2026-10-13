-- Tidewell Mobile - Mobile Billing & Spend Control (GOVERNED) - schema, business rules and demo data.
-- PostgreSQL 14+.  Database: mobile_billing
-- Load:  createdb mobile_billing  &&  psql -d mobile_billing -f database.sql
--
-- =====================================================================
-- Telecom Mobile Billing & Spend Control - Governed Agentic AI (fictional operator "Tidewell Mobile", assistant "Nova")
-- The rules live HERE, not in any prompt:
--   * session_customer()        identity: every read/write is scoped by a session token (mobile number + OTP)
--   * my_*() / bill_*()         scoped reads - only the caller's rows; another customer's id -> NOT_FOUND row
--   * bill_comparison()         bill-to-bill deltas by category are computed in SQL, never by the LLM
--   * action_eval()             ONE rule function for all four actions (TravelPass, roaming limit, cancel, plan change)
--   * propose_action_fn()       guarded write-row for pending_actions (PROPOSED or BLOCKED, 15-minute expiry)
--   * confirm_action_fn()       re-checks every rule; returns the account_events row ONLY when executable
--   * trg_account_event         the side effects (TravelPass, limit, cancel, plan change) happen atomically in the DB
--   * open_case_fn()            human-owned requests routed by the case_routing table; one open case per type
--   * email_log_row()           the confirmation email is authorised only for the caller's EXECUTED events or decided cases
--   * case_parking()            what a case PARKS for a person to approve (bill credit, SIM-swap reversal, premium block),
--                               derived in SQL from the bill / SIM-swap facts - never chosen by the model
--   * session_reviewer()        staff reviewers (Billing Disputes, Fraud Team, Retention) use the same session-token
--                               mechanism with role REVIEWER; customer and reviewer tokens are not interchangeable
--   * decide_case_row()         guarded decision write-row (NOT_YOUR_TEAM / ALREADY_DECIDED / NOTE_REQUIRED /
--                               AMOUNT_INVALID / OVER_AUTHORITY); trg_review_decision executes the parked action
--                               through case_action_row() and writes the CASE_DECIDED audit row
--   * ref_plan_guide() / ref_charge_taxonomy() / ref_bill_glossary()  the A2A agents' ONLY database access: read-only
--                               reference rows (section / term / meaning), no customer data, no identity argument
-- Hidden from every tool: customers.fraud_flag, risk_score, internal_notes, ssn, email, otp_code.
-- A held account surfaces only as the reason code ACCOUNT_HOLD. Data minimisation (CCPA-style).
-- Money: USD. Billing cycle = calendar month, bills issued on the 1st. All demo dates are relative to
-- CURRENT_DATE (seed_data.sql).
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid() on PostgreSQL < 13

-- Re-runnable: drop this use case's functions first (CREATE OR REPLACE cannot change a return type).
-- Extension-owned functions (pgcrypto) are left alone. Use a dedicated database (mobile_billing).
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

DROP TABLE IF EXISTS email_log, agent_audit, case_actions, decide_attempts, review_decisions, case_requests,
  service_cases, confirm_attempts, account_events, pending_actions,
  plan_changes, content_subscriptions, roaming_days, usage_cycles, unbilled_charges, payments, bill_lines,
  bills, reviewer_verify_attempts, customer_sessions, reviewers, customers, case_routing,
  plan_guide, charge_taxonomy, bill_glossary, plans CASCADE;
-- Tables from an earlier version of this sample (once-off bundles), removed cleanly if present.
DROP TABLE IF EXISTS customer_bundles, bundle_catalogue CASCADE;

-- ---------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------
CREATE TABLE plans (
  plan_code        VARCHAR(10) PRIMARY KEY,
  plan_name        VARCHAR(60) NOT NULL,
  data_gb          NUMERIC(6,2),                   -- NULL = unlimited
  monthly_price    NUMERIC(10,2) NOT NULL,         -- USD per month, before taxes & fees
  roaming_included VARCHAR(80) NOT NULL,           -- customer-facing
  is_device        BOOLEAN NOT NULL DEFAULT FALSE,
  device_months    INTEGER NOT NULL DEFAULT 0      -- device installment length; 0 = no device
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type      VARCHAR(30) PRIMARY KEY,
  label             VARCHAR(40) NOT NULL,          -- customer-facing name of the request type
  team              VARCHAR(40) NOT NULL,
  sla_business_days INTEGER NOT NULL,
  sla_text          VARCHAR(160) NOT NULL
);

-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO customer, bill, case, staff, session or contact data, ever. The plan rows
-- (ref_plan_guide) are read from plans and the "who decides" rows (ref_charge_taxonomy) from case_routing - one
-- source of truth, never copied here.
CREATE TABLE plan_guide (                         -- PlanRecommender: comparison columns, reason codes, habits
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('COLUMN','REASON_CODE','ELIGIBILITY','HABIT','ADD_ON','STANDARD_LINE')),
  term        VARCHAR(60) NOT NULL,
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE charge_taxonomy (                    -- ChargeClassifier: categories, next paths, signals, customer lines
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CATEGORY','NEXT_PATH','SIGNAL','CUSTOMER_LINE')),
  term        VARCHAR(60) NOT NULL,
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE bill_glossary (                      -- BillExplainer: comparison categories, bill line items, rates
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CATEGORY','LINE_ITEM','RATE','COLUMN','STANDARD_LINE')),
  term        VARCHAR(60) NOT NULL,
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- Customers (the login identity: mobile number + one-time code)
-- ---------------------------------------------------------------------
CREATE TABLE customers (
  customer_id      VARCHAR(12) PRIMARY KEY,          -- TW-C-0101
  mobile_number    VARCHAR(10) NOT NULL UNIQUE,      -- normalised 10 digits, 2125550101
  otp_code         VARCHAR(6)  NOT NULL,             -- HIDDEN: demo stand-in for the SMS one-time code
  first_name       VARCHAR(40) NOT NULL,
  last_name        VARCHAR(40) NOT NULL,
  email            VARCHAR(100) NOT NULL,            -- HIDDEN (emails go to the EMAIL_TO demo inbox)
  ssn              VARCHAR(11) NOT NULL,             -- HIDDEN: fictional 900-series SSN-like number
  plan_code        VARCHAR(10) NOT NULL REFERENCES plans,
  device_installment_end DATE,                       -- NULL = no open device installment
  roaming_limit    NUMERIC(10,2),                    -- USD per bill cycle on pay-per-use roaming; NULL = no limit
  travel_pass_since TIMESTAMP,                       -- NULL = not enrolled in TravelPass
  autopay_day      INTEGER NOT NULL DEFAULT 21,
  last_sim_swap_at TIMESTAMP,
  fraud_flag       BOOLEAN NOT NULL DEFAULT FALSE,   -- HIDDEN: surfaces only as ACCOUNT_HOLD
  risk_score       INTEGER NOT NULL DEFAULT 10,      -- HIDDEN
  internal_notes   TEXT,                             -- HIDDEN
  account_opened   DATE NOT NULL,
  sim_swap_reversed_at TIMESTAMP,                    -- set only by a Fraud Team reviewer's approved SIM_SWAP_REVERSAL
  premium_content_blocked BOOLEAN NOT NULL DEFAULT FALSE   -- set only by an approved PREMIUM_BLOCK
);

-- Staff reviewers (the human in the loop). team matches case_routing.team.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,           -- TWS-7001 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,
  one_time_code   VARCHAR(6)  NOT NULL,              -- HIDDEN: demo stand-in for the staff sign-in code
  approval_limit  NUMERIC(10,2),                     -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role (customer and reviewer tokens are
-- not interchangeable).
CREATE TABLE customer_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL DEFAULT 'CUSTOMER' CHECK (role IN ('CUSTOMER','REVIEWER')),
  customer_id    VARCHAR(12) REFERENCES customers,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes',
  CHECK ((role = 'CUSTOMER' AND customer_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND customer_id IS NULL))
);

-- Brute-force throttle for the staff code step (5 wrong codes in 15 minutes -> locked).
CREATE TABLE reviewer_verify_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  ok           BOOLEAN NOT NULL,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Bills, line items, payments, unbilled charges, usage, roaming days
-- ---------------------------------------------------------------------
CREATE TABLE bills (
  bill_id       VARCHAR(16) PRIMARY KEY,             -- TWB-0101-2609
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,
  issue_date    DATE NOT NULL,
  due_date      DATE NOT NULL
);
CREATE INDEX ix_bills_customer ON bills (customer_id, issue_date);

CREATE TABLE bill_lines (
  line_id       SERIAL PRIMARY KEY,
  bill_id       VARCHAR(16) NOT NULL REFERENCES bills,
  category      VARCHAR(30) NOT NULL CHECK (category IN ('PLAN','ROAMING','TRAVEL_PASS','PREMIUM_CONTENT',
                  'VOICE_SMS','TAXES_FEES','LATE_FEE','OTHER')),
  description   VARCHAR(120) NOT NULL,
  amount        NUMERIC(10,2) NOT NULL,
  charge_date   DATE NOT NULL
);
CREATE INDEX ix_bill_lines_bill ON bill_lines (bill_id);

CREATE TABLE payments (
  payment_id    SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  bill_id       VARCHAR(16) REFERENCES bills,
  payment_date  DATE NOT NULL,
  amount        NUMERIC(10,2) NOT NULL,
  method        VARCHAR(20) NOT NULL,
  reference     VARCHAR(30) NOT NULL
);

-- Charges in the current cycle that are not on a bill yet (roaming, TravelPass days, ...).
CREATE TABLE unbilled_charges (
  charge_id     SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  charge_date   DATE NOT NULL,
  category      VARCHAR(30) NOT NULL,
  description   VARCHAR(120) NOT NULL,
  amount        NUMERIC(10,2) NOT NULL
);

CREATE TABLE usage_cycles (
  customer_id    VARCHAR(12) NOT NULL REFERENCES customers,
  cycle_start    DATE NOT NULL,                      -- 1st of the calendar month
  data_used_gb   NUMERIC(6,2) NOT NULL,
  voice_used_min INTEGER NOT NULL,
  sms_used       INTEGER NOT NULL,
  PRIMARY KEY (customer_id, cycle_start)
);

-- One row per day the phone was used abroad (from the network's roaming records).
CREATE TABLE roaming_days (
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  roam_date     DATE NOT NULL,
  country       VARCHAR(40) NOT NULL,
  data_mb       INTEGER NOT NULL DEFAULT 0,
  voice_min     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (customer_id, roam_date)
);

-- ---------------------------------------------------------------------
-- Premium content subscriptions and plan changes
-- ---------------------------------------------------------------------
CREATE TABLE content_subscriptions (
  subscription_id VARCHAR(10) PRIMARY KEY,           -- SUB-1001
  customer_id     VARCHAR(12) NOT NULL REFERENCES customers,
  service_name    VARCHAR(60) NOT NULL,
  provider        VARCHAR(60) NOT NULL,
  monthly_price   NUMERIC(10,2) NOT NULL,
  start_date      DATE NOT NULL,
  status          VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CANCELLED')),
  cancelled_at    TIMESTAMP
);

CREATE TABLE plan_changes (
  change_id     SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  from_plan     VARCHAR(10) NOT NULL REFERENCES plans,
  to_plan       VARCHAR(10) NOT NULL REFERENCES plans,
  change_type   VARCHAR(10) NOT NULL CHECK (change_type IN ('UPGRADE','DOWNGRADE')),
  requested_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  effective_date DATE NOT NULL,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('APPLIED','SCHEDULED')),
  source_reference VARCHAR(16)
);

-- ---------------------------------------------------------------------
-- Two-step actions: proposals -> confirmed events (the only state-changing path)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'TW-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  customer_id    VARCHAR(12) NOT NULL REFERENCES customers,
  action_type    VARCHAR(30) NOT NULL,
  target         VARCHAR(40) NOT NULL,
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(20),
  reason_text    TEXT,
  summary        TEXT,
  price          NUMERIC(10,2),
  effective_date DATE,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_customer ON pending_actions (customer_id, action_type, target, created_at);

-- One row per EXECUTED action. Written only by INSERT ... SELECT * FROM confirm_action_fn(); the trigger
-- trg_account_event applies the effect. A blocked/expired confirm writes NO row here.
CREATE TABLE account_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(16) NOT NULL UNIQUE,        -- TW-ACT-000101
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  customer_id    VARCHAR(12) NOT NULL REFERENCES customers,
  action_type    VARCHAR(30) NOT NULL,
  target         VARCHAR(40) NOT NULL,
  price          NUMERIC(10,2),
  effective_date DATE,
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every confirm call by a verified customer (EXECUTED / BLOCKED / EXPIRED / NOT_FOUND / ALREADY_DONE).
-- Written by confirm_action_fn as a side effect so the readback reports exactly what this call did.
CREATE TABLE confirm_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  customer_id  VARCHAR(12) NOT NULL REFERENCES customers,
  proposal_ref TEXT NOT NULL,                         -- as typed (normalised), may not exist / be someone else's
  outcome      VARCHAR(14) NOT NULL,
  reason_code  VARCHAR(20),
  reason_text  TEXT,
  reference    VARCHAR(16),
  summary      TEXT,
  effective_date DATE,
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases and the email log
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no       BIGSERIAL PRIMARY KEY,
  case_id       VARCHAR(16) NOT NULL UNIQUE,         -- TW-CASE-000045
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  request_type  VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary       TEXT NOT NULL,                       -- the customer's request, summarised neutrally
  agent_brief   TEXT NOT NULL DEFAULT '',            -- neutral brief by the assistant / ChargeClassifier; never a decision
  assigned_team VARCHAR(40),                         -- set by trg_case_defaults from case_routing
  requested_amount NUMERIC(10,2),                    -- what the parked action could credit (NULL = no amount)
  parked_action VARCHAR(40),                         -- runs ONLY on approval: BILL_CREDIT:<bill> / SIM_SWAP_REVERSAL:<bill> /
                                                     -- PREMIUM_BLOCK:<bill>; NULL = the team completes it (Retention)
  status        VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at    TIMESTAMP,                           -- set by trg_case_defaults from case_routing
  customer_message TEXT,                             -- customer-safe outcome text, set by the reviewer's decision
  approved_amount NUMERIC(10,2),
  decided_at    TIMESTAMP,
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every open_service_case call by a verified customer (OPENED / EXISTING / INVALID_TYPE / BAD_REFERENCE).
CREATE TABLE case_requests (
  request_id    SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  request_type  VARCHAR(40) NOT NULL,                 -- normalised as given
  outcome       VARCHAR(14) NOT NULL,
  case_id       VARCHAR(16),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Insert-only decision events (one per case). trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE REFERENCES service_cases (case_id),
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(10,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from customers
  customer_message TEXT NOT NULL,
  decided_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every decide call by a verified reviewer (readback of the outcome and reason).
CREATE TABLE decide_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  case_ref     VARCHAR(40) NOT NULL,
  outcome      VARCHAR(10) NOT NULL,                 -- APPROVED / REJECTED / BLOCKED
  reason_code  VARCHAR(24),
  reason_text  TEXT,
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- The executed parked action of an approved case (event row; trg_case_action applies the credit / SIM-swap
-- reversal / premium block). Written only by apply_review_decision through case_action_row().
CREATE TABLE case_actions (
  action_no     BIGSERIAL PRIMARY KEY,
  reference     VARCHAR(16) NOT NULL UNIQUE,         -- TW-ADJ-000001
  case_id       VARCHAR(16) NOT NULL UNIQUE REFERENCES service_cases (case_id),
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  kind          VARCHAR(20) NOT NULL CHECK (kind IN ('BILL_CREDIT','SIM_SWAP_REVERSAL','PREMIUM_BLOCK')),
  bill_id       VARCHAR(16) NOT NULL REFERENCES bills,
  credit_amount NUMERIC(10,2),                       -- NULL / 0 = no credit
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail (OWASP: repudiation): one row per consequential state change, written by triggers so it cannot be
-- bypassed. Back-office reads it by SQL; no MCP tool exposes it.
CREATE TABLE agent_audit (
  id           SERIAL PRIMARY KEY,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  customer_id  VARCHAR(12),
  actor        VARCHAR(12),                          -- reviewer id for REVIEWER_VERIFY / CASE_DECIDED
  action       VARCHAR(30) NOT NULL,                 -- REVIEWER_VERIFY, CASE_OPENED, CASE_DECIDED, BILL_CREDITED,
                                                     -- SIM_SWAP_REVERSED, PREMIUM_BLOCKED
  ref          TEXT,
  detail       TEXT
);

-- Guarded email requests that passed the SQL check: an EXECUTED action (TW-ACT-) or a decided case (TW-CASE-).
CREATE TABLE email_log (
  email_id      SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  reference     VARCHAR(16) NOT NULL,
  subject       TEXT NOT NULL,
  logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- HELPERS
-- =====================================================================
CREATE OR REPLACE FUNCTION cycle_start() RETURNS DATE AS $$ SELECT date_trunc('month', current_date)::date $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION next_cycle_start() RETURNS DATE AS $$ SELECT (date_trunc('month', current_date) + INTERVAL '1 month')::date $$ LANGUAGE sql STABLE;
-- $45 / $9.99 / $1,234.50 (locale-independent separators)
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT '$' || CASE WHEN n = trunc(n) THEN to_char(n, 'FM999,999,990') ELSE to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION data_txt(gb NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN gb IS NULL THEN 'Unlimited' ELSE to_char(gb, 'FM990') || ' GB' END
$$ LANGUAGE sql IMMUTABLE;

-- 2125550101 / 212-555-0101 / (212) 555-0101 / +1 212 555 0101 / 12125550101 -> 2125550101
CREATE OR REPLACE FUNCTION norm_mobile(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^1[0-9]{10}$' THEN substr(d, 2) ELSE d END
    FROM (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS d) x
$$ LANGUAGE sql IMMUTABLE;
-- 2125550101 -> (212) 555-0101
CREATE OR REPLACE FUNCTION fmt_mobile(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN p ~ '^[0-9]{10}$' THEN '(' || substr(p, 1, 3) || ') ' || substr(p, 4, 3) || '-' || substr(p, 7, 4) ELSE p END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_action(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g'))
$$ LANGUAGE sql IMMUTABLE;

-- Target normalisation shared by the write-row and the readback (they must agree).
-- SET_ROAMING_LIMIT: '$50', '50.00', '50 dollars' -> '50'; anything without a number stays as typed (-> INVALID_CAP).
CREATE OR REPLACE FUNCTION norm_target(p_action TEXT, p_target TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN norm_action(p_action) = 'SET_ROAMING_LIMIT' AND p_target ~ '[0-9]'
              THEN trim_scale(substring(p_target FROM '[0-9]+(?:\.[0-9]+)?')::numeric)::text
              ELSE left(upper(trim(coalesce(p_target, ''))), 40) END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;

-- Money position.
CREATE OR REPLACE FUNCTION bill_total(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(amount), 0) FROM bill_lines WHERE bill_id = p_bill
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION bill_paid(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(amount), 0) FROM payments WHERE bill_id = p_bill
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION balance_due(p_cust TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(greatest(bill_total(b.bill_id) - bill_paid(b.bill_id), 0)), 0) FROM bills b WHERE b.customer_id = p_cust
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION overdue_amount(p_cust TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(greatest(bill_total(b.bill_id) - bill_paid(b.bill_id), 0)), 0)
    FROM bills b WHERE b.customer_id = p_cust AND b.due_date < current_date
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION days_overdue(p_cust TEXT) RETURNS INTEGER AS $$
  SELECT coalesce(max(current_date - b.due_date), 0)::int
    FROM bills b WHERE b.customer_id = p_cust AND b.due_date < current_date
     AND bill_total(b.bill_id) - bill_paid(b.bill_id) > 0
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION roaming_limit_txt(p NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN p IS NULL THEN 'No limit set'
              WHEN p = 0 THEN '$0 - pay-per-use roaming is blocked'
              ELSE usd(p) || ' per bill cycle on pay-per-use roaming' END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION travel_pass_txt(p TIMESTAMP) RETURNS TEXT AS $$
  SELECT CASE WHEN p IS NULL THEN 'Not enrolled'
              ELSE 'Enrolled since ' || to_char(p, 'YYYY-MM-DD') || ' ($10 per day, only on days used abroad)' END
$$ LANGUAGE sql IMMUTABLE;

-- =====================================================================
-- IDENTITY
-- =====================================================================
-- Always exactly one row: the customer when the token is valid, else NULL -> callers emit SESSION_INVALID.
-- plpgsql on purpose (opaque to the planner; see the Parcel sample's note on inlined LEFT JOINs).
CREATE OR REPLACE FUNCTION session_customer(p_token TEXT)
RETURNS TABLE (customer_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT c.customer_id
      FROM (SELECT 1) one
      LEFT JOIN customer_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'CUSTOMER'
                                   AND s.expires_at > clock_timestamp()
      LEFT JOIN customers c ON c.customer_id = s.customer_id;
END $$ LANGUAGE plpgsql STABLE;

-- Reviewer identity: one row always - the reviewer when the token is a valid REVIEWER token of an active reviewer.
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN customer_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
                                   AND s.expires_at > clock_timestamp()
      LEFT JOIN reviewers r ON r.reviewer_id = s.reviewer_id AND r.active;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row for verify: a session is issued ONLY for a matching mobile number + one-time code.
CREATE OR REPLACE FUNCTION verify_customer_fn(p_mobile TEXT, p_otp TEXT)
RETURNS TABLE (customer_id VARCHAR) AS $$
  SELECT c.customer_id FROM customers c
   WHERE c.mobile_number = norm_mobile(p_mobile) AND c.otp_code = trim(coalesce(p_otp, ''))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION verify_result(p_mobile TEXT, p_otp TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, first_name VARCHAR, expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT CASE WHEN s.session_token IS NULL THEN 'VERIFY_FAILED' ELSE 'VERIFIED' END,
         s.session_token, s.first_name, s.expires_at,
         CASE WHEN s.session_token IS NULL
              THEN 'That mobile number and one-time code do not match our records. Please check both and try again.'
              ELSE 'You are verified. This session is valid for 30 minutes.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (
      SELECT se.session_token, c.first_name, se.expires_at
        FROM customers c
        JOIN customer_sessions se ON se.customer_id = c.customer_id AND se.role = 'CUSTOMER' AND se.expires_at > clock_timestamp()
       WHERE c.mobile_number = norm_mobile(p_mobile) AND c.otp_code = trim(coalesce(p_otp, ''))
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Reviewer identity: staff id + staff code -> REVIEWER session (same token mechanism, role checked everywhere).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g'))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION reviewer_locked_until(p_staff TEXT) RETURNS TIMESTAMP AS $$
  SELECT CASE WHEN count(*) >= 5 THEN min(f.at) + INTERVAL '15 minutes' END
    FROM (SELECT va.at FROM reviewer_verify_attempts va
           WHERE va.reviewer_id = norm_staff_id(p_staff) AND NOT va.ok
             AND va.at > clock_timestamp() - INTERVAL '15 minutes'
             AND va.at > coalesce((SELECT max(v2.at) FROM reviewer_verify_attempts v2
                                    WHERE v2.reviewer_id = va.reviewer_id AND v2.ok), '-infinity'::timestamp)
           ORDER BY va.at DESC LIMIT 5) f
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
RETURNS TABLE (outcome TEXT, reason_text TEXT, session_token TEXT, role TEXT, display_name TEXT, team TEXT, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN lk.until IS NOT NULL THEN 'LOCKED' WHEN s.session_token IS NULL THEN 'VERIFY_FAILED' ELSE 'VERIFIED' END,
         CASE WHEN lk.until IS NOT NULL THEN 'Staff sign-in is locked after too many wrong codes. Try again after '
                                             || to_char(lk.until, 'HH24:MI') || '.'
              WHEN s.session_token IS NULL THEN 'That staff ID and code do not match. Please check both and try again.'
              ELSE 'You are signed in as a reviewer. This session is valid for 30 minutes.' END,
         CASE WHEN lk.until IS NULL THEN s.session_token END,
         CASE WHEN lk.until IS NULL AND s.session_token IS NOT NULL THEN 'REVIEWER' END,
         CASE WHEN lk.until IS NULL THEN s.display_name END,
         CASE WHEN lk.until IS NULL THEN s.team END,
         CASE WHEN lk.until IS NULL THEN s.expires_at END
    FROM (SELECT reviewer_locked_until(p_staff) AS until) lk
    LEFT JOIN LATERAL (
      SELECT se.session_token, r.display_name::text AS display_name, r.team::text AS team, se.expires_at
        FROM reviewers r
        JOIN customer_sessions se ON se.reviewer_id = r.reviewer_id AND se.role = 'REVIEWER' AND se.expires_at > clock_timestamp()
       WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- SCOPED READS
-- =====================================================================
CREATE OR REPLACE FUNCTION my_account(p_token TEXT)
RETURNS TABLE (status TEXT, customer_name TEXT, mobile_number TEXT, plan_code VARCHAR, plan_name VARCHAR,
               monthly_price NUMERIC, data_gb TEXT, voice_min TEXT, sms TEXT, roaming_included VARCHAR,
               contract_type TEXT, contract_end DATE, account_status TEXT, account_status_text TEXT,
               roaming_limit TEXT, travel_pass TEXT, autopay_day INTEGER, scheduled_plan_change TEXT,
               last_sim_swap_date DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.first_name || ' ' || c.last_name, fmt_mobile(c.mobile_number), p.plan_code, p.plan_name, p.monthly_price,
         CASE WHEN c.customer_id IS NOT NULL THEN data_txt(p.data_gb) END,
         CASE WHEN c.customer_id IS NOT NULL THEN 'Unlimited' END,
         CASE WHEN c.customer_id IS NOT NULL THEN 'Unlimited' END,
         p.roaming_included,
         CASE WHEN c.customer_id IS NULL THEN NULL
              WHEN c.device_installment_end > current_date THEN 'Device installment plan'
              ELSE 'No annual contract, month-to-month' END,
         CASE WHEN c.device_installment_end > current_date THEN c.device_installment_end END,
         CASE WHEN c.customer_id IS NULL THEN NULL WHEN c.fraud_flag THEN 'ACCOUNT_HOLD' ELSE 'ACTIVE' END,
         CASE WHEN c.customer_id IS NULL THEN NULL
              WHEN c.fraud_flag THEN 'Your account is on hold for a security review, so changes cannot be made in chat. Our Fraud Team can help.'
              ELSE 'Your account is active.' END,
         CASE WHEN c.customer_id IS NOT NULL THEN roaming_limit_txt(c.roaming_limit) END,
         CASE WHEN c.customer_id IS NOT NULL THEN travel_pass_txt(c.travel_pass_since) END,
         c.autopay_day,
         (SELECT 'Change to ' || tp.plan_name || ' scheduled for ' || to_char(pc.effective_date, 'YYYY-MM-DD')
            FROM plan_changes pc JOIN plans tp ON tp.plan_code = pc.to_plan
           WHERE pc.customer_id = c.customer_id AND pc.status = 'SCHEDULED' AND pc.effective_date > current_date
           ORDER BY pc.requested_at DESC LIMIT 1),
         c.last_sim_swap_at::date
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN plans p ON p.plan_code = c.plan_code
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_bills(p_token TEXT)
RETURNS TABLE (status TEXT, bill_id VARCHAR, period TEXT, issue_date DATE, due_date DATE, total NUMERIC,
               amount_paid NUMERIC, outstanding NUMERIC, bill_status TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         b.bill_id, to_char(b.period_start, 'YYYY-MM-DD') || ' to ' || to_char(b.period_end, 'YYYY-MM-DD'),
         b.issue_date, b.due_date, bill_total(b.bill_id), bill_paid(b.bill_id),
         greatest(bill_total(b.bill_id) - bill_paid(b.bill_id), 0),
         CASE WHEN b.bill_id IS NULL THEN NULL
              WHEN bill_paid(b.bill_id) >= bill_total(b.bill_id) THEN 'PAID'
              WHEN b.due_date < current_date THEN 'OVERDUE' ELSE 'UNPAID' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN bills b ON b.customer_id = sc.customer_id
   ORDER BY b.issue_date DESC
$$ LANGUAGE sql STABLE;

-- One bill the caller owns, with its line items. Someone else's (or unknown) bill -> one NOT_FOUND row.
CREATE OR REPLACE FUNCTION bill_detail(p_token TEXT, p_bill TEXT)
RETURNS TABLE (status TEXT, bill_id VARCHAR, period TEXT, bill_total NUMERIC, category VARCHAR,
               description VARCHAR, amount NUMERIC, charge_date DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' WHEN b.bill_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         b.bill_id,
         CASE WHEN b.bill_id IS NOT NULL THEN to_char(b.period_start, 'YYYY-MM-DD') || ' to ' || to_char(b.period_end, 'YYYY-MM-DD') END,
         CASE WHEN b.bill_id IS NOT NULL THEN bill_total(b.bill_id) END,
         l.category, l.description, l.amount, l.charge_date
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN bills b ON b.customer_id = sc.customer_id AND b.bill_id = upper(trim(coalesce(p_bill, '')))
    LEFT JOIN bill_lines l ON l.bill_id = b.bill_id
   ORDER BY l.charge_date, l.line_id
$$ LANGUAGE sql STABLE;

-- Category map shared by the comparison (6 customer-facing buckets).
CREATE OR REPLACE FUNCTION compare_bucket(p_category TEXT) RETURNS TEXT AS $$
  SELECT CASE p_category WHEN 'PLAN' THEN 'plan' WHEN 'ROAMING' THEN 'roaming' WHEN 'TRAVEL_PASS' THEN 'roaming'
                         WHEN 'PREMIUM_CONTENT' THEN 'premium_content' WHEN 'VOICE_SMS' THEN 'voice_sms'
                         WHEN 'TAXES_FEES' THEN 'taxes_fees' ELSE 'other' END
$$ LANGUAGE sql IMMUTABLE;

-- Latest vs previous bill by category; the deltas are computed here, never by the model.
CREATE OR REPLACE FUNCTION bill_comparison(p_token TEXT)
RETURNS TABLE (status TEXT, category TEXT, previous_amount NUMERIC, latest_amount NUMERIC, delta NUMERIC,
               previous_bill_id VARCHAR, latest_bill_id VARCHAR, previous_total NUMERIC, latest_total NUMERIC) AS $$
  SELECT * FROM (
  WITH sc AS (SELECT * FROM session_customer(p_token)),
       ranked AS (SELECT b.bill_id, row_number() OVER (ORDER BY b.issue_date DESC) rn
                    FROM bills b JOIN sc ON b.customer_id = sc.customer_id),
       lb AS (SELECT bill_id FROM ranked WHERE rn = 1),
       pb AS (SELECT bill_id FROM ranked WHERE rn = 2),
       cats AS (SELECT * FROM (VALUES (1,'plan'),(2,'roaming'),(3,'premium_content'),
                                      (4,'voice_sms'),(5,'taxes_fees'),(6,'other')) v(ord, cat))
  SELECT 'OK' AS status, cats.cat AS category,
         coalesce((SELECT sum(l.amount) FROM bill_lines l WHERE l.bill_id = (SELECT bill_id FROM pb) AND compare_bucket(l.category) = cats.cat), 0),
         coalesce((SELECT sum(l.amount) FROM bill_lines l WHERE l.bill_id = (SELECT bill_id FROM lb) AND compare_bucket(l.category) = cats.cat), 0),
         coalesce((SELECT sum(l.amount) FROM bill_lines l WHERE l.bill_id = (SELECT bill_id FROM lb) AND compare_bucket(l.category) = cats.cat), 0)
           - coalesce((SELECT sum(l.amount) FROM bill_lines l WHERE l.bill_id = (SELECT bill_id FROM pb) AND compare_bucket(l.category) = cats.cat), 0),
         (SELECT bill_id FROM pb)::varchar, (SELECT bill_id FROM lb)::varchar,
         bill_total((SELECT bill_id FROM pb)), bill_total((SELECT bill_id FROM lb))
    FROM cats
   WHERE EXISTS (SELECT 1 FROM sc WHERE sc.customer_id IS NOT NULL)
  UNION ALL
  SELECT 'SESSION_INVALID', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
   WHERE NOT EXISTS (SELECT 1 FROM sc WHERE sc.customer_id IS NOT NULL)
  ) u
  ORDER BY array_position(ARRAY['plan','roaming','premium_content','voice_sms','taxes_fees','other'], u.category) NULLS FIRST
$$ LANGUAGE sql STABLE;

-- Current cycle usage + roaming spend control (days abroad, roaming charges so far, limit, TravelPass).
CREATE OR REPLACE FUNCTION my_usage(p_token TEXT)
RETURNS TABLE (status TEXT, cycle_start DATE, cycle_end DATE, days_left INTEGER,
               data_used_gb NUMERIC, data_allowance_gb TEXT, voice_used_min INTEGER, voice_allowance_min TEXT,
               sms_used INTEGER, sms_allowance TEXT, roaming_days_this_cycle INTEGER, roaming_charges_this_cycle NUMERIC,
               roaming_limit TEXT, travel_pass TEXT, data_gb_last_3_cycles TEXT, roaming_days_last_3_cycles TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         CASE WHEN c.customer_id IS NOT NULL THEN cycle_start() END,
         CASE WHEN c.customer_id IS NOT NULL THEN next_cycle_start() - 1 END,
         CASE WHEN c.customer_id IS NOT NULL THEN next_cycle_start() - current_date END,
         u.data_used_gb,
         CASE WHEN c.customer_id IS NOT NULL THEN data_txt(p.data_gb) END,
         u.voice_used_min,
         CASE WHEN c.customer_id IS NOT NULL THEN 'Unlimited' END,
         u.sms_used,
         CASE WHEN c.customer_id IS NOT NULL THEN 'Unlimited' END,
         CASE WHEN c.customer_id IS NOT NULL THEN
           (SELECT count(*)::int FROM roaming_days r WHERE r.customer_id = c.customer_id AND r.roam_date >= cycle_start()) END,
         CASE WHEN c.customer_id IS NOT NULL THEN
           (SELECT coalesce(sum(uc.amount), 0) FROM unbilled_charges uc
             WHERE uc.customer_id = c.customer_id AND uc.category IN ('ROAMING','TRAVEL_PASS')) END,
         CASE WHEN c.customer_id IS NOT NULL THEN roaming_limit_txt(c.roaming_limit) END,
         CASE WHEN c.customer_id IS NOT NULL THEN travel_pass_txt(c.travel_pass_since) END,
         (SELECT string_agg(to_char(h.cycle_start, 'Mon YYYY') || ': ' || to_char(h.data_used_gb, 'FM990.0') || ' GB', ', ' ORDER BY h.cycle_start DESC)
            FROM (SELECT * FROM usage_cycles x WHERE x.customer_id = c.customer_id AND x.cycle_start < cycle_start()
                   ORDER BY x.cycle_start DESC LIMIT 3) h),
         CASE WHEN c.customer_id IS NOT NULL THEN
           (SELECT string_agg(to_char(m.ms, 'Mon YYYY') || ': ' ||
                     coalesce((SELECT string_agg(z.country || ' ' || z.n || CASE WHEN z.n = 1 THEN ' day' ELSE ' days' END, ', ' ORDER BY z.country)
                                 FROM (SELECT r.country, count(*) n FROM roaming_days r
                                        WHERE r.customer_id = c.customer_id
                                          AND r.roam_date >= m.ms AND r.roam_date < m.ms + INTERVAL '1 month'
                                        GROUP BY r.country) z), 'no days abroad'),
                     '; ' ORDER BY m.ms DESC)
              FROM (SELECT (cycle_start() - make_interval(months => g))::date AS ms FROM generate_series(1, 3) g) m) END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN plans p ON p.plan_code = c.plan_code
    LEFT JOIN usage_cycles u ON u.customer_id = c.customer_id AND u.cycle_start = cycle_start()
$$ LANGUAGE sql STABLE;

-- Premium content subscriptions (active and cancelled) + the TravelPass enrolment row (always present).
CREATE OR REPLACE FUNCTION my_subscriptions(p_token TEXT)
RETURNS TABLE (status TEXT, item_type TEXT, item_id TEXT, name TEXT, item_status TEXT, monthly_price NUMERIC,
               price_text TEXT, start_date DATE, end_date DATE) AS $$
  WITH sc AS (SELECT * FROM session_customer(p_token))
  SELECT 'OK', 'PREMIUM_CONTENT', cs.subscription_id::text, cs.service_name || ' (' || cs.provider || ')', cs.status::text,
         cs.monthly_price, usd(cs.monthly_price) || ' per month', cs.start_date, cs.cancelled_at::date
    FROM sc JOIN content_subscriptions cs ON cs.customer_id = sc.customer_id
  UNION ALL
  SELECT 'OK', 'TRAVEL_PASS', 'TRAVELPASS', 'TravelPass (international roaming)',
         CASE WHEN c.travel_pass_since IS NULL THEN 'NOT_ENROLLED' ELSE 'ENROLLED' END,
         NULL::numeric, '$10 per day, charged only on days you use your phone abroad', c.travel_pass_since::date, NULL::date
    FROM sc JOIN customers c ON c.customer_id = sc.customer_id
  UNION ALL
  SELECT 'SESSION_INVALID', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM sc WHERE sc.customer_id IS NULL
  ORDER BY 2 NULLS FIRST, 5, 8
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_payments(p_token TEXT)
RETURNS TABLE (status TEXT, payment_date DATE, amount NUMERIC, method VARCHAR, reference VARCHAR, bill_id VARCHAR,
               balance_due NUMERIC, past_due_amount NUMERIC, overdue TEXT, days_overdue INTEGER, autopay_day INTEGER) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         pm.payment_date, pm.amount, pm.method, pm.reference, pm.bill_id,
         CASE WHEN c.customer_id IS NOT NULL THEN balance_due(c.customer_id) END,
         CASE WHEN c.customer_id IS NOT NULL THEN overdue_amount(c.customer_id) END,
         CASE WHEN c.customer_id IS NULL THEN NULL WHEN overdue_amount(c.customer_id) > 0 THEN 'yes' ELSE 'no' END,
         CASE WHEN c.customer_id IS NOT NULL THEN days_overdue(c.customer_id) END,
         c.autopay_day
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN payments pm ON pm.customer_id = c.customer_id
   ORDER BY pm.payment_date DESC NULLS LAST
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- RULES - one evaluator for all four actions. Reason codes + customer-safe reason_text written here.
-- =====================================================================
CREATE OR REPLACE FUNCTION action_eval(p_cust TEXT, p_action TEXT, p_target TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, summary TEXT, price NUMERIC, effective_date DATE) AS $$
DECLARE
  c customers; cp plans; tp plans; cs content_subscriptions; floor_price NUMERIC;
  v_action TEXT := norm_action(p_action);
  v_target TEXT := norm_target(p_action, p_target);
  v_lim NUMERIC; v_cur NUMERIC; v_locked BOOLEAN;
BEGIN
  SELECT * INTO c FROM customers WHERE customer_id = p_cust;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again.', NULL::text, NULL::numeric, NULL::date; RETURN;
  END IF;
  IF c.fraud_flag THEN
    RETURN QUERY SELECT FALSE, 'ACCOUNT_HOLD',
      'Your account is on hold for a security review, so no changes can be made in chat. Our Fraud Team can help - I can open a case for you.',
      NULL::text, NULL::numeric, NULL::date; RETURN;
  END IF;
  SELECT * INTO cp FROM plans WHERE plan_code = c.plan_code;

  IF v_action = 'ADD_TRAVEL_PASS' THEN
    IF v_target <> 'ON' THEN
      RETURN QUERY SELECT FALSE, 'INVALID_TARGET', 'TravelPass can only be turned on here (target ON).',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    IF c.travel_pass_since IS NOT NULL THEN
      RETURN QUERY SELECT FALSE, 'NO_CHANGE', 'Your line is already enrolled in TravelPass (since '
        || to_char(c.travel_pass_since, 'YYYY-MM-DD') || '), so there is nothing to change.', NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    IF overdue_amount(c.customer_id) > 0 THEN
      RETURN QUERY SELECT FALSE, 'ARREARS', 'Your account has a past-due balance, so TravelPass cannot be added until it is paid.',
        NULL::text, 10::numeric, NULL::date; RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
      'Turn on TravelPass for your future trips: $10 per day, charged only on days you use your phone abroad, instead of pay-per-use roaming rates. Starts today; nothing is charged until you travel',
      10::numeric, current_date; RETURN;

  ELSIF v_action = 'SET_ROAMING_LIMIT' THEN
    IF v_target !~ '^[0-9]+$' OR v_target::numeric NOT IN (0, 50, 100, 200) THEN
      RETURN QUERY SELECT FALSE, 'INVALID_CAP', 'The roaming limit can be set to $0 (block pay-per-use roaming), $50, $100 or $200 per bill cycle.',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    v_lim := v_target::numeric;
    v_cur := c.roaming_limit;                              -- NULL = no limit = the highest possible
    IF v_cur IS NOT DISTINCT FROM v_lim THEN
      RETURN QUERY SELECT FALSE, 'NO_CHANGE', 'Your roaming limit is already ' || usd(v_lim) || ', so there is nothing to change.',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    IF v_cur IS NOT NULL AND v_lim > v_cur AND overdue_amount(c.customer_id) > 0 THEN
      RETURN QUERY SELECT FALSE, 'ARREARS', 'Your account has a past-due balance, so your roaming limit can only be lowered until it is paid.',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
      CASE WHEN v_lim = 0 THEN 'Block pay-per-use roaming ($0 limit): your phone will not use pay-per-use roaming data or calls abroad, from today. TravelPass days are not affected'
           ELSE 'Set a ' || usd(v_lim) || ' limit on pay-per-use roaming charges per bill cycle: once it is reached, pay-per-use roaming stops until the next cycle, from today. TravelPass days are not affected' END,
      0::numeric, current_date; RETURN;

  ELSIF v_action = 'CANCEL_SUBSCRIPTION' THEN
    SELECT * INTO cs FROM content_subscriptions s WHERE s.subscription_id = v_target AND s.customer_id = c.customer_id;
    IF NOT FOUND THEN
      RETURN QUERY SELECT FALSE, 'NOT_FOUND', 'I could not find that subscription on your account.',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    IF cs.status = 'CANCELLED' THEN
      RETURN QUERY SELECT FALSE, 'ALREADY_CANCELLED', cs.service_name || ' is already cancelled' ||
        coalesce(' (since ' || to_char(cs.cancelled_at, 'YYYY-MM-DD') || ')', '') || ', so there is nothing to change.',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
      'Cancel ' || cs.service_name || ' (' || usd(cs.monthly_price) || '/month) today, so it is not charged again. Charges already billed are not refunded automatically - you can ask for a refund through a billing dispute case',
      0::numeric, current_date; RETURN;

  ELSIF v_action = 'CHANGE_PLAN' THEN
    SELECT * INTO tp FROM plans WHERE plan_code = v_target;
    IF NOT FOUND THEN
      RETURN QUERY SELECT FALSE, 'INVALID_TARGET', 'That is not a Tidewell plan. Plans: BASIC5 ($30), ESS15 ($45), UNLPLUS ($65), UNLPREM ($85), UNLPLUSD ($85 with a device installment).',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    IF tp.plan_code = cp.plan_code THEN
      RETURN QUERY SELECT FALSE, 'NO_CHANGE', 'You are already on ' || tp.plan_name || ', so there is nothing to change.',
        NULL::text, NULL::numeric, NULL::date; RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM plan_changes pc WHERE pc.customer_id = c.customer_id AND pc.requested_at >= cycle_start()) THEN
      RETURN QUERY SELECT FALSE, 'CHANGE_PENDING', 'Your plan was already changed this bill cycle. Another change is possible from '
        || to_char(next_cycle_start(), 'YYYY-MM-DD') || '.', NULL::text, tp.monthly_price, NULL::date; RETURN;
    END IF;
    -- Device installment open: stay at Unlimited Plus level or above, and keep the device installment.
    SELECT p.monthly_price INTO floor_price FROM plans p WHERE p.plan_code = 'UNLPLUS';
    v_locked := c.device_installment_end IS NOT NULL AND c.device_installment_end > current_date;
    IF v_locked AND (tp.monthly_price < floor_price OR tp.is_device <> cp.is_device) THEN
      RETURN QUERY SELECT FALSE, 'LOCKED_IN', 'Your device installment plan runs until ' || to_char(c.device_installment_end, 'YYYY-MM-DD')
        || '. Until then you cannot move below Unlimited Plus or to a plan without your device installment.',
        NULL::text, tp.monthly_price, NULL::date; RETURN;
    END IF;
    IF tp.monthly_price >= cp.monthly_price AND overdue_amount(c.customer_id) > 0 THEN
      RETURN QUERY SELECT FALSE, 'ARREARS', 'Your account has a past-due balance, so upgrades are not possible until it is paid. Moving to a cheaper plan is still possible.',
        NULL::text, tp.monthly_price, NULL::date; RETURN;
    END IF;
    IF tp.monthly_price >= cp.monthly_price THEN
      RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
        'Upgrade from ' || cp.plan_name || ' (' || usd(cp.monthly_price) || ') to ' || tp.plan_name || ' (' || usd(tp.monthly_price)
        || '/month, +' || usd(tp.monthly_price - cp.monthly_price) || '), effective today'
        || CASE WHEN tp.is_device AND NOT cp.is_device THEN ' - starts a ' || tp.device_months || '-month device installment plan' ELSE '' END,
        tp.monthly_price, current_date; RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
      'Move from ' || cp.plan_name || ' (' || usd(cp.monthly_price) || ') to ' || tp.plan_name || ' (' || usd(tp.monthly_price)
      || '/month, -' || usd(cp.monthly_price - tp.monthly_price) || '), effective ' || to_char(next_cycle_start(), 'YYYY-MM-DD'),
      tp.monthly_price, next_cycle_start(); RETURN;
  END IF;

  RETURN QUERY SELECT FALSE, 'INVALID_ACTION', 'I can turn on TravelPass, set a roaming spending limit, cancel a premium content subscription or change your plan.',
    NULL::text, NULL::numeric, NULL::date;
END $$ LANGUAGE plpgsql STABLE;

-- Plans the caller may switch to (every plan except the current one) with the rule outcome per plan.
CREATE OR REPLACE FUNCTION eligible_plans(p_token TEXT)
RETURNS TABLE (status TEXT, plan_code VARCHAR, plan_name VARCHAR, data_gb TEXT, voice_min TEXT, sms TEXT,
               monthly_price NUMERIC, device_plan TEXT, roaming_included VARCHAR, change_type TEXT, effective_date DATE,
               price_diff NUMERIC, allowed TEXT, reason_code TEXT, reason_text TEXT) AS $$
  WITH sc AS (SELECT * FROM session_customer(p_token)),
       me AS (SELECT c.customer_id, cp.monthly_price AS cur_price, cp.plan_code AS cur_plan
                FROM sc JOIN customers c ON c.customer_id = sc.customer_id JOIN plans cp ON cp.plan_code = c.plan_code)
  SELECT 'OK', p.plan_code, p.plan_name, data_txt(p.data_gb), 'Unlimited', 'Unlimited', p.monthly_price,
         CASE WHEN p.is_device THEN 'yes (' || p.device_months || '-month device installment)' ELSE 'no' END,
         p.roaming_included,
         CASE WHEN p.monthly_price >= me.cur_price THEN 'UPGRADE' ELSE 'DOWNGRADE' END,
         CASE WHEN e.ok THEN e.effective_date
              WHEN p.monthly_price >= me.cur_price THEN current_date ELSE next_cycle_start() END,
         p.monthly_price - me.cur_price,
         CASE WHEN e.ok THEN 'yes' ELSE 'no' END, e.reason_code, e.reason_text
    FROM me JOIN plans p ON p.plan_code <> me.cur_plan
    CROSS JOIN LATERAL action_eval(me.customer_id, 'CHANGE_PLAN', p.plan_code) e
  UNION ALL
  SELECT 'SESSION_INVALID', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
   WHERE NOT EXISTS (SELECT 1 FROM sc WHERE sc.customer_id IS NOT NULL)
  ORDER BY 7, 2
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- TWO-STEP ACTIONS
-- =====================================================================
-- Guarded write-row: ONE pending_actions row (PROPOSED or BLOCKED) for a verified caller; 0 rows for a bad
-- session, or when an identical live, unconfirmed proposal with the same outcome already exists.
CREATE OR REPLACE FUNCTION propose_action_fn(p_token TEXT, p_action TEXT, p_target TEXT)
RETURNS TABLE (customer_id VARCHAR, action_type VARCHAR, target VARCHAR, outcome VARCHAR, reason_code VARCHAR,
               reason_text TEXT, summary TEXT, price NUMERIC, effective_date DATE) AS $$
  SELECT sc.customer_id, left(norm_action(p_action), 30)::varchar, norm_target(p_action, p_target)::varchar,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text,
         e.summary, e.price, e.effective_date
    FROM session_customer(p_token) sc
    CROSS JOIN LATERAL action_eval(sc.customer_id, p_action, p_target) e
   WHERE sc.customer_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.customer_id = sc.customer_id AND pa.action_type = left(norm_action(p_action), 30)
                        AND pa.target = norm_target(p_action, p_target) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM account_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

-- Readback: the caller's latest proposal for this action + target. A BLOCKED proposal has no proposal_id to confirm.
CREATE OR REPLACE FUNCTION propose_action_result(p_token TEXT, p_action TEXT, p_target TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, target VARCHAR, reason_code VARCHAR, reason_text TEXT,
               summary TEXT, price NUMERIC, effective_date DATE, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         pa.action_type, pa.target,
         CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (mobile number and one-time code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing has changed yet. Reply yes within 15 minutes to go ahead.'
              ELSE pa.reason_text END,
         pa.summary, pa.price, pa.effective_date,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.expires_at END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT p.* FROM pending_actions p
       WHERE p.customer_id = sc.customer_id AND p.action_type = left(norm_action(p_action), 30)
         AND p.target = norm_target(p_action, p_target)
       ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm: re-checks EVERY rule and returns the account_events row only when the
-- proposal is the caller's, PROPOSED, unexpired, not yet executed and still allowed. VOLATILE: it records
-- the attempt (with its outcome) in confirm_attempts so the readback can report exactly what happened.
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, customer_id VARCHAR, action_type VARCHAR,
               target VARCHAR, price NUMERIC, effective_date DATE, summary TEXT) AS $$
DECLARE
  v_cust TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev account_events;
  e RECORD; v_id BIGINT; v_reference TEXT;
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NULL THEN RETURN; END IF;                       -- readback reports SESSION_INVALID
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.customer_id = v_cust;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (customer_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_cust, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal on your account. Nothing was changed.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM account_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (customer_id, proposal_ref, outcome, reason_code, reason_text, reference, summary, effective_date)
      VALUES (v_cust, v_ref, 'ALREADY_DONE', NULL, 'This was already done earlier (reference ' || ev.reference || '). Nothing new was changed.',
              ev.reference, ev.summary, ev.effective_date);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (customer_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_cust, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (customer_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_cust, v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was changed. I can set it up again.', pa.summary);
    RETURN;
  END IF;
  SELECT * INTO e FROM action_eval(v_cust, pa.action_type, pa.target);
  IF NOT e.ok THEN
    INSERT INTO confirm_attempts (customer_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_cust, v_ref, 'BLOCKED', e.reason_code, e.reason_text, pa.summary);
    RETURN;
  END IF;
  v_id := nextval(pg_get_serial_sequence('account_events', 'event_id'));
  v_reference := 'TW-ACT-' || lpad(v_id::text, 6, '0');
  INSERT INTO confirm_attempts (customer_id, proposal_ref, outcome, reason_code, reason_text, reference, summary, effective_date)
    VALUES (v_cust, v_ref, 'EXECUTED', NULL, 'Done.', v_reference, e.summary, e.effective_date);
  RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, v_cust::varchar, pa.action_type, pa.target,
                      e.price, e.effective_date, e.summary;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT, effective_date DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         ca.reference,
         CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (mobile number and one-time code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that proposal on your account. Nothing was changed.'
              ELSE ca.reason_text END,
         ca.summary, ca.effective_date
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT a.* FROM confirm_attempts a
       WHERE a.customer_id = sc.customer_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
       ORDER BY a.attempt_id DESC LIMIT 1) ca ON TRUE
$$ LANGUAGE sql STABLE;

-- Side effects of an executed action - atomic with the event row. Never an UPDATE from a tool.
CREATE OR REPLACE FUNCTION apply_account_event() RETURNS TRIGGER AS $$
DECLARE c customers; cp plans; tp plans;
BEGIN
  SELECT * INTO c FROM customers WHERE customer_id = NEW.customer_id;
  IF NEW.action_type = 'ADD_TRAVEL_PASS' THEN
    UPDATE customers SET travel_pass_since = clock_timestamp() WHERE customer_id = NEW.customer_id;
  ELSIF NEW.action_type = 'SET_ROAMING_LIMIT' THEN
    UPDATE customers SET roaming_limit = NEW.target::numeric WHERE customer_id = NEW.customer_id;
  ELSIF NEW.action_type = 'CANCEL_SUBSCRIPTION' THEN
    UPDATE content_subscriptions SET status = 'CANCELLED', cancelled_at = clock_timestamp()
     WHERE subscription_id = NEW.target AND customer_id = NEW.customer_id;
  ELSIF NEW.action_type = 'CHANGE_PLAN' THEN
    SELECT * INTO cp FROM plans WHERE plan_code = c.plan_code;
    SELECT * INTO tp FROM plans WHERE plan_code = NEW.target;
    IF tp.monthly_price >= cp.monthly_price THEN
      INSERT INTO plan_changes (customer_id, from_plan, to_plan, change_type, effective_date, status, source_reference)
        VALUES (NEW.customer_id, cp.plan_code, tp.plan_code, 'UPGRADE', current_date, 'APPLIED', NEW.reference);
      UPDATE customers SET plan_code = tp.plan_code,
             device_installment_end = CASE WHEN tp.is_device AND NOT cp.is_device
                                 THEN (current_date + make_interval(months => tp.device_months))::date ELSE device_installment_end END
       WHERE customer_id = NEW.customer_id;
    ELSE
      INSERT INTO plan_changes (customer_id, from_plan, to_plan, change_type, effective_date, status, source_reference)
        VALUES (NEW.customer_id, cp.plan_code, tp.plan_code, 'DOWNGRADE', next_cycle_start(), 'SCHEDULED', NEW.reference);
    END IF;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_account_event AFTER INSERT ON account_events FOR EACH ROW EXECUTE FUNCTION apply_account_event();

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; one open case per (customer, request_type). A case may PARK an action
-- (bill credit, SIM-swap reversal, premium content block) that runs only when a reviewer of that team approves it.
-- =====================================================================
CREATE OR REPLACE FUNCTION add_business_days(p_start DATE, p_days INTEGER) RETURNS DATE AS $$
  SELECT d FROM (SELECT p_start + g AS d, row_number() OVER (ORDER BY g) AS n
                   FROM generate_series(1, p_days * 2 + 7) g
                  WHERE extract(isodow FROM p_start + g) < 6) x
   WHERE n = p_days
$$ LANGUAGE sql IMMUTABLE;

-- First name + last initial: the most a reviewer needs to see (minimum necessary).
CREATE OR REPLACE FUNCTION customer_display(p_customer TEXT) RETURNS TEXT AS $$
  SELECT c.first_name || ' ' || left(c.last_name, 1) || '.' FROM customers c WHERE c.customer_id = p_customer
$$ LANGUAGE sql STABLE;

-- Bill facts the parking rules and the reviewer use (all from bill_lines / roaming_days / case_actions).
-- Disputable = everything except the plan price and taxes & fees.
CREATE OR REPLACE FUNCTION bill_disputable(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(l.amount), 0) FROM bill_lines l
   WHERE l.bill_id = p_bill AND l.category IN ('ROAMING','TRAVEL_PASS','PREMIUM_CONTENT','VOICE_SMS','LATE_FEE','OTHER')
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION bill_credited(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(a.credit_amount), 0) FROM case_actions a WHERE a.bill_id = p_bill
$$ LANGUAGE sql STABLE;
-- Roaming charges on days with NO network roaming record for that customer (the fraud signal).
CREATE OR REPLACE FUNCTION bill_unmatched_roaming(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(l.amount), 0) FROM bill_lines l JOIN bills b ON b.bill_id = l.bill_id
   WHERE l.bill_id = p_bill AND l.category = 'ROAMING'
     AND NOT EXISTS (SELECT 1 FROM roaming_days r WHERE r.customer_id = b.customer_id AND r.roam_date = l.charge_date)
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION bill_premium(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(l.amount), 0) FROM bill_lines l WHERE l.bill_id = p_bill AND l.category = 'PREMIUM_CONTENT'
$$ LANGUAGE sql STABLE;

-- What a new case parks for approval (derived in SQL, never chosen by the model). The bill is the reference the
-- customer names (one of THEIR bills) or, when empty, their latest bill. A reference that is not theirs -> BAD_REFERENCE.
--   billing_dispute -> BILL_CREDIT:<bill>, requested = the bill's disputable charges not yet credited
--   suspected_fraud -> SIM_SWAP_REVERSAL:<bill> when the line had a SIM swap in the last 60 days (not yet reversed),
--                      requested = roaming charges on days with no roaming record; otherwise
--                      PREMIUM_BLOCK:<bill>, requested = the bill's premium content charges
--   contract_cancellation / port_out -> no parked action (Retention completes it)
-- A requested amount of $0 is stored as NULL (the action runs without a credit).
CREATE OR REPLACE FUNCTION case_parking(p_customer TEXT, p_type TEXT, p_reference TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, parked_action TEXT, requested_amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_type TEXT := norm_request_type(p_type); v_ref TEXT := upper(trim(coalesce(p_reference, ''))); b bills;
        c customers; v_left NUMERIC;
BEGIN
  ok := TRUE; reason_code := 'OK';
  IF v_type NOT IN ('billing_dispute', 'suspected_fraud') THEN RETURN NEXT; RETURN; END IF;
  IF v_ref <> '' THEN
    SELECT * INTO b FROM bills x WHERE x.bill_id = v_ref AND x.customer_id = p_customer;
    IF NOT FOUND THEN ok := FALSE; reason_code := 'BAD_REFERENCE'; RETURN NEXT; RETURN; END IF;
  ELSE
    SELECT * INTO b FROM bills x WHERE x.customer_id = p_customer ORDER BY x.issue_date DESC, x.bill_id DESC LIMIT 1;
  END IF;
  IF b.bill_id IS NULL THEN RETURN NEXT; RETURN; END IF;
  v_left := greatest(bill_disputable(b.bill_id) - bill_credited(b.bill_id), 0);
  SELECT * INTO c FROM customers x WHERE x.customer_id = p_customer;
  IF v_type = 'billing_dispute' THEN
    IF v_left > 0 THEN parked_action := 'BILL_CREDIT:' || b.bill_id; requested_amount := v_left; END IF;
  ELSIF c.last_sim_swap_at IS NOT NULL AND c.last_sim_swap_at > clock_timestamp() - INTERVAL '60 days'
        AND c.sim_swap_reversed_at IS NULL THEN
    parked_action := 'SIM_SWAP_REVERSAL:' || b.bill_id;
    requested_amount := nullif(least(bill_unmatched_roaming(b.bill_id), v_left), 0);
  ELSE
    parked_action := 'PREMIUM_BLOCK:' || b.bill_id;
    requested_amount := nullif(least(bill_premium(b.bill_id), v_left), 0);
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Every case gets its team and reply-due time from the routing table (also cases opened by seeds).
CREATE OR REPLACE FUNCTION case_defaults() RETURNS TRIGGER AS $$
DECLARE t case_routing;
BEGIN
  SELECT * INTO t FROM case_routing WHERE request_type = NEW.request_type;
  NEW.assigned_team := t.team;
  NEW.sla_due_at := coalesce(NEW.sla_due_at, add_business_days(NEW.created_at::date, t.sla_business_days) + NEW.created_at::time);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION case_defaults();

-- Guarded write-row (VOLATILE: records the attempt in case_requests): returns the service_cases row only for a
-- verified caller, a known request type, a reference that is one of their bills (or empty) and no open case of that type.
CREATE OR REPLACE FUNCTION open_case_fn(p_token TEXT, p_type TEXT, p_summary TEXT, p_brief TEXT, p_reference TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, customer_id VARCHAR, request_type VARCHAR, summary TEXT, agent_brief TEXT,
               requested_amount NUMERIC, parked_action VARCHAR) AS $$
DECLARE v_cust TEXT; v_type TEXT := norm_request_type(p_type); v_existing TEXT; v_no BIGINT; v_case TEXT; pk RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM case_routing r WHERE r.request_type = v_type) THEN
    INSERT INTO case_requests (customer_id, request_type, outcome) VALUES (v_cust, v_type, 'INVALID_TYPE');
    RETURN;
  END IF;
  SELECT s.case_id INTO v_existing FROM service_cases s
   WHERE s.customer_id = v_cust AND s.request_type = v_type AND s.status = 'OPEN' ORDER BY s.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (customer_id, request_type, outcome, case_id) VALUES (v_cust, v_type, 'EXISTING', v_existing);
    RETURN;
  END IF;
  SELECT * INTO pk FROM case_parking(v_cust, v_type, p_reference);
  IF NOT pk.ok THEN
    INSERT INTO case_requests (customer_id, request_type, outcome) VALUES (v_cust, v_type, 'BAD_REFERENCE');
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'TW-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (customer_id, request_type, outcome, case_id) VALUES (v_cust, v_type, 'OPENED', v_case);
  RETURN QUERY SELECT v_no, v_case::varchar, v_cust::varchar, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000),
                      left(coalesce(trim(p_brief), ''), 4000), pk.requested_amount, pk.parked_action::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request_type VARCHAR, team VARCHAR, sla_text VARCHAR, reason_text TEXT,
               requested_amount NUMERIC, if_approved TEXT, case_status VARCHAR) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, cr.request_type::varchar, rt.team, rt.sla_text,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (mobile number and one-time code).'
              WHEN cr.outcome = 'OPENED' THEN 'Your case is open. A person on our ' || rt.team || CASE WHEN rt.team ILIKE '% team' THEN '' ELSE ' team' END || ' will look at your request and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' case, so no new case was opened. Our ' || rt.team || ' team is on it.'
              WHEN cr.outcome = 'BAD_REFERENCE' THEN 'I could not find that bill on your account, so no case was opened. Ask about your bills first, or leave the bill out to use your latest bill.'
              ELSE 'That is not a request we can open a case for here. A person can help with cancelling your service, moving your number to another provider, billing disputes and suspected fraud.' END,
         CASE WHEN cr.outcome IN ('OPENED','EXISTING') THEN s.requested_amount END,
         CASE WHEN cr.outcome NOT IN ('OPENED','EXISTING') THEN NULL
              WHEN s.parked_action LIKE 'BILL\_CREDIT:%' THEN 'If a person approves it, a credit of up to ' || usd(s.requested_amount)
                   || ' for charges on bill ' || split_part(s.parked_action, ':', 2) || ' is added to your next bill.'
              WHEN s.parked_action LIKE 'SIM\_SWAP\_REVERSAL:%' THEN 'If a person approves it, the recent SIM swap is reversed'
                   || coalesce(' and up to ' || usd(s.requested_amount) || ' of charges is credited to your next bill', '') || '.'
              WHEN s.parked_action LIKE 'PREMIUM\_BLOCK:%' THEN 'If a person approves it, premium content is blocked on your line'
                   || coalesce(' and up to ' || usd(s.requested_amount) || ' of premium content charges is credited to your next bill', '') || '.'
              ELSE 'A person on the team will contact you and complete it.' END,
         CASE WHEN cr.outcome IN ('OPENED','EXISTING') THEN s.status END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT r.* FROM case_requests r
       WHERE r.customer_id = sc.customer_id AND r.request_type = norm_request_type(p_type)
       ORDER BY r.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- The customer's own cases: status + the customer-safe outcome message once a person decided. Never the internal
-- note, the AI brief, the parked action or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request TEXT, team VARCHAR, case_status VARCHAR, opened_on DATE,
               reply_by DATE, requested_amount NUMERIC, approved_amount NUMERIC, customer_message TEXT, decided_on DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         s.case_id, rt.label::text, s.assigned_team, s.status, s.created_at::date, s.sla_due_at::date,
         s.requested_amount, s.approved_amount, s.customer_message, s.decided_at::date
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN service_cases s ON s.customer_id = sc.customer_id
    LEFT JOIN case_routing rt ON rt.request_type = s.request_type
   ORDER BY s.created_at DESC NULLS LAST, s.case_id DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- EMAIL - authorised only for the caller's own EXECUTED action events (TW-ACT-) or decided cases (TW-CASE-)
-- =====================================================================
CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (customer_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT ae.customer_id, ae.reference, 'Tidewell Mobile confirmation ' || ae.reference
    FROM session_customer(p_token) sc
    JOIN account_events ae ON ae.customer_id = sc.customer_id AND ae.reference = upper(trim(coalesce(p_reference, '')))
  UNION ALL
  SELECT s.customer_id, s.case_id, 'Tidewell Mobile case update ' || s.case_id
    FROM session_customer(p_token) sc
    JOIN service_cases s ON s.customer_id = sc.customer_id AND s.case_id = upper(trim(coalesce(p_reference, '')))
   WHERE EXISTS (SELECT 1 FROM review_decisions d WHERE d.case_id = s.case_id)
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN ae.event_id IS NOT NULL OR dc.case_id IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN ae.event_id IS NOT NULL OR dc.case_id IS NOT NULL THEN NULL
              WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN ae.event_id IS NOT NULL OR dc.case_id IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (mobile number and one-time code).'
              ELSE 'There is no completed change or decided case with that reference on your account, so no email was sent.' END,
         coalesce(ae.reference, dc.case_id),
         CASE WHEN ae.event_id IS NOT NULL THEN 'Tidewell Mobile confirmation ' || ae.reference
              WHEN dc.case_id IS NOT NULL THEN 'Tidewell Mobile case update ' || dc.case_id
              ELSE 'Tidewell Mobile confirmation - not sent' END,
         CASE WHEN ae.event_id IS NOT NULL THEN
           'Hi ' || c.first_name || ',' || chr(10) || chr(10)
           || 'This confirms the change you asked Nova, the Tidewell Mobile assistant, to make:' || chr(10)
           || ae.summary || '.' || chr(10)
           || 'Reference: ' || ae.reference || chr(10)
           || 'Done on: ' || to_char(ae.created_at, 'YYYY-MM-DD HH24:MI') || chr(10)
           || coalesce('Effective: ' || to_char(ae.effective_date, 'YYYY-MM-DD') || chr(10), '')
           || chr(10) || 'Thank you for being with Tidewell Mobile.'
              WHEN dc.case_id IS NOT NULL THEN
           'Hi ' || c.first_name || ',' || chr(10) || chr(10)
           || 'A person on our ' || dc.assigned_team || ' team reviewed your ' || dc.label || ' case ' || dc.case_id
           || ' and it was ' || lower(dc.status) || '.' || chr(10)
           || dc.customer_message || chr(10)
           || coalesce('Amount: ' || usd(dc.approved_amount) || chr(10), '')
           || 'Decided on: ' || to_char(dc.decided_at, 'YYYY-MM-DD') || chr(10)
           || chr(10) || 'Thank you for being with Tidewell Mobile.'
           ELSE 'No confirmation email was sent for reference ' || upper(trim(coalesce(p_reference, ''))) || '.' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN account_events ae ON ae.customer_id = sc.customer_id AND ae.reference = upper(trim(coalesce(p_reference, '')))
    LEFT JOIN LATERAL (
      SELECT s.case_id, s.assigned_team, s.status, s.customer_message, s.approved_amount, s.decided_at, rt.label
        FROM service_cases s JOIN case_routing rt ON rt.request_type = s.request_type
       WHERE s.customer_id = sc.customer_id AND s.case_id = upper(trim(coalesce(p_reference, '')))
         AND EXISTS (SELECT 1 FROM review_decisions d WHERE d.case_id = s.case_id)) dc ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================

-- The most a reviewer may approve on a case (NULL = the case carries no amount). Recomputed at decision time from the
-- bill, so a credit granted on another case of the same bill is never paid twice.
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT nullif(CASE split_part(coalesce(s.parked_action, ''), ':', 1)
           WHEN 'BILL_CREDIT' THEN greatest(bill_disputable(x.bill) - bill_credited(x.bill), 0)
           WHEN 'SIM_SWAP_REVERSAL' THEN least(bill_unmatched_roaming(x.bill), greatest(bill_disputable(x.bill) - bill_credited(x.bill), 0))
           WHEN 'PREMIUM_BLOCK' THEN least(bill_premium(x.bill), greatest(bill_disputable(x.bill) - bill_credited(x.bill), 0))
         END, 0)
    FROM service_cases s CROSS JOIN LATERAL (SELECT split_part(coalesce(s.parked_action, ''), ':', 2) AS bill) x
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no mobile number, email, SSN or full last name).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE
    WHEN s.parked_action IS NOT NULL THEN
      'Bill ' || b.bill_id || ' (' || to_char(b.period_start, 'YYYY-MM-DD') || ' to ' || to_char(b.period_end, 'YYYY-MM-DD')
      || '), total ' || usd(bill_total(b.bill_id)) || '; charges on it: '
      || coalesce((SELECT string_agg(lower(replace(z.category, '_', ' ')) || ' ' || usd(z.amt), ', ' ORDER BY z.category)
                     FROM (SELECT l.category, sum(l.amount) amt FROM bill_lines l WHERE l.bill_id = b.bill_id GROUP BY l.category) z), 'none')
      || '; credits already granted on this bill: ' || usd(bill_credited(b.bill_id))
      || CASE WHEN s.parked_action LIKE 'SIM\_SWAP\_REVERSAL:%' THEN
           '; SIM swap on ' || to_char(c.last_sim_swap_at, 'YYYY-MM-DD') || '; roaming charges on days with NO network roaming record: '
           || usd(bill_unmatched_roaming(b.bill_id)) || '; days abroad on record in the bill period: '
           || (SELECT count(*) FROM roaming_days r WHERE r.customer_id = s.customer_id AND r.roam_date BETWEEN b.period_start AND b.period_end)
         WHEN s.parked_action LIKE 'PREMIUM\_BLOCK:%' THEN
           '; premium content on this bill: ' || usd(bill_premium(b.bill_id)) || '; active premium subscriptions: '
           || (SELECT count(*) FROM content_subscriptions cs WHERE cs.customer_id = s.customer_id AND cs.status = 'ACTIVE')
         ELSE '' END
      || '; account on hold: ' || CASE WHEN c.fraud_flag THEN 'yes' ELSE 'no' END
    ELSE
      'Plan ' || p.plan_name || ' (' || usd(p.monthly_price) || ' a month); '
      || CASE WHEN c.device_installment_end > current_date THEN 'device installment until ' || to_char(c.device_installment_end, 'YYYY-MM-DD')
              ELSE 'no device installment' END
      || '; customer since ' || to_char(c.account_opened, 'YYYY') || '; past-due balance ' || usd(overdue_amount(c.customer_id))
    END
    FROM service_cases s
    JOIN customers c ON c.customer_id = s.customer_id
    JOIN plans p ON p.plan_code = c.plan_code
    LEFT JOIN bills b ON b.bill_id = split_part(coalesce(s.parked_action, ''), ':', 2)
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue: OPEN cases ordered by reply-due time. Another team's cases never appear.
CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, customer TEXT, opened_on DATE, age_days INTEGER,
               reply_due DATE, sla_status TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.customer, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, t.label, customer_display(s.customer_id) AS customer, s.created_at::date AS opened_on,
             (current_date - s.created_at::date)::int AS age_days, s.sla_due_at::date AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.sla_due_at
        FROM service_cases s JOIN case_routing t ON t.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND t.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at, q.case_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, customer TEXT, opened_on DATE,
               reply_due DATE, customer_statement TEXT, agent_brief TEXT, requested_amount NUMERIC, max_approvable NUMERIC,
               your_approval_limit NUMERIC, facts TEXT, if_approved TEXT, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, t.label, s.status, customer_display(s.customer_id), s.created_at::date, s.sla_due_at::date,
         s.summary, s.agent_brief, s.requested_amount, case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE split_part(coalesce(s.parked_action, ''), ':', 1)
              WHEN 'BILL_CREDIT' THEN 'APPROVE adds a bill credit of the approved amount to the next bill.'
              WHEN 'SIM_SWAP_REVERSAL' THEN 'APPROVE reverses the recent SIM swap and credits the approved amount to the next bill.'
              WHEN 'PREMIUM_BLOCK' THEN 'APPROVE blocks premium content on the line, cancels active premium subscriptions and credits the approved amount.'
              ELSE CASE WHEN s.case_id IS NOT NULL THEN 'No automatic action: the team completes the request after approval.' END END,
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN case_eligible_max(s.case_id) IS NOT NULL THEN 'APPROVE (any amount up to ' || usd(case_eligible_max(s.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN '; above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer' ELSE '' END
                   || ') or REJECT, with an internal note and a message for the customer.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the customer.' END,
         s.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = upper(trim(coalesce(p_case, ''))) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT x.request_type FROM case_routing x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN case_routing t ON t.request_type = s.request_type
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT,
               customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; t case_routing; v_ref TEXT := upper(trim(coalesce(p_case, ''))); v_dec TEXT;
        v_amt NUMERIC; v_max NUMERIC; v_txt TEXT := upper(regexp_replace(coalesce(p_amount, ''), '[\s$,]', '', 'g'));
        v_msg TEXT;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM service_cases x WHERE x.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT * INTO t FROM case_routing x WHERE x.request_type = s.request_type;
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
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID',
                'The approved amount must be more than $0 and no more than ' || usd(v_max) || ' for this case.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', usd(v_amt) || ' is above your approval limit of '
                || usd(rv.approval_limit) || '. The case stays open and needs a senior reviewer.');
      RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || t.label || ' request has been approved' || coalesce(' for ' || usd(v_amt), '') || '.'
                  ELSE 'After review, your ' || t.label || ' request was not approved.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED')
                   OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.approved_amount END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND'
                   AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT CASE a.kind WHEN 'BILL_CREDIT' THEN 'Bill credit ' || a.reference || ' of ' || usd(a.credit_amount)
                                                  || ' for bill ' || a.bill_id || ' added to the next bill.'
                                             WHEN 'SIM_SWAP_REVERSAL' THEN 'SIM swap reversed (' || a.reference || ')'
                                                  || coalesce('; ' || usd(nullif(a.credit_amount, 0)) || ' credited to the next bill', '') || '.'
                                             ELSE 'Premium content blocked and active premium subscriptions cancelled (' || a.reference || ')'
                                                  || coalesce('; ' || usd(nullif(a.credit_amount, 0)) || ' credited to the next bill', '') || '.' END
                            FROM case_actions a WHERE a.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id
                          AND a.case_ref = upper(trim(coalesce(p_case, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = upper(trim(coalesce(p_case, '')))
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded row the decision trigger uses to execute the parked action (the same checks every time): the case must be
-- APPROVED with exactly this parked action, have no executed action yet, and the credit must fit what is still eligible.
CREATE OR REPLACE FUNCTION case_action_row(p_case TEXT, p_amount NUMERIC)
RETURNS TABLE (reference VARCHAR, case_id VARCHAR, customer_id VARCHAR, kind VARCHAR, bill_id VARCHAR, credit_amount NUMERIC) AS $$
  SELECT ('TW-ADJ-' || lpad(nextval(pg_get_serial_sequence('case_actions', 'action_no'))::text, 6, '0'))::varchar,
         s.case_id, s.customer_id, split_part(s.parked_action, ':', 1)::varchar, b.bill_id,
         CASE WHEN case_eligible_max(s.case_id) IS NULL THEN NULL ELSE p_amount END
    FROM service_cases s
    JOIN bills b ON b.bill_id = split_part(s.parked_action, ':', 2) AND b.customer_id = s.customer_id
   WHERE s.case_id = p_case AND s.status = 'APPROVED'
     AND split_part(s.parked_action, ':', 1) IN ('BILL_CREDIT','SIM_SWAP_REVERSAL','PREMIUM_BLOCK')
     AND NOT EXISTS (SELECT 1 FROM case_actions a WHERE a.case_id = s.case_id)
     AND (case_eligible_max(s.case_id) IS NULL OR (p_amount > 0 AND p_amount <= case_eligible_max(s.case_id)))
$$ LANGUAGE sql VOLATILE;

-- The decision event: case status + customer message, then the parked action through the guarded row, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_done TEXT := 'nothing'; v_ref TEXT;
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  IF NEW.decision = 'APPROVE' AND s.parked_action IS NOT NULL THEN
    INSERT INTO case_actions (reference, case_id, customer_id, kind, bill_id, credit_amount)
      SELECT * FROM case_action_row(NEW.case_id, NEW.approved_amount) RETURNING reference INTO v_ref;
    IF v_ref IS NOT NULL THEN v_done := s.parked_action || ' (' || v_ref || ')'; END IF;
  END IF;
  INSERT INTO agent_audit (customer_id, actor, action, ref, detail)
    VALUES (s.customer_id, NEW.reviewer_id, 'CASE_DECIDED', NEW.case_id,
            NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- The executed action's effects (event row + trigger, never an UPDATE from a tool): the credit goes on the next bill
-- as a negative unbilled charge; a SIM-swap reversal / premium block changes the line.
CREATE OR REPLACE FUNCTION apply_case_action() RETURNS TRIGGER AS $$
BEGIN
  IF coalesce(NEW.credit_amount, 0) > 0 THEN
    INSERT INTO unbilled_charges (customer_id, charge_date, category, description, amount)
      VALUES (NEW.customer_id, current_date, 'CREDIT',
              'Bill credit ' || NEW.reference || ' (case ' || NEW.case_id || ', bill ' || NEW.bill_id || ')', -NEW.credit_amount);
    INSERT INTO agent_audit (customer_id, action, ref, detail)
      VALUES (NEW.customer_id, 'BILL_CREDITED', NEW.reference, usd(NEW.credit_amount) || ' for bill ' || NEW.bill_id || ' (case ' || NEW.case_id || ')');
  END IF;
  IF NEW.kind = 'SIM_SWAP_REVERSAL' THEN
    UPDATE customers SET sim_swap_reversed_at = clock_timestamp() WHERE customer_id = NEW.customer_id;
    INSERT INTO agent_audit (customer_id, action, ref, detail)
      VALUES (NEW.customer_id, 'SIM_SWAP_REVERSED', NEW.reference, 'case ' || NEW.case_id);
  ELSIF NEW.kind = 'PREMIUM_BLOCK' THEN
    UPDATE customers SET premium_content_blocked = TRUE WHERE customer_id = NEW.customer_id;
    UPDATE content_subscriptions SET status = 'CANCELLED', cancelled_at = clock_timestamp()
     WHERE customer_id = NEW.customer_id AND status = 'ACTIVE';
    INSERT INTO agent_audit (customer_id, action, ref, detail)
      VALUES (NEW.customer_id, 'PREMIUM_BLOCKED', NEW.reference, 'case ' || NEW.case_id);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_action AFTER INSERT ON case_actions FOR EACH ROW EXECUTE FUNCTION apply_case_action();

-- Audit: reviewer sign-ins and new cases (written by triggers, so they cannot be bypassed).
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'REVIEWER' THEN
    INSERT INTO agent_audit (actor, action, ref, detail) VALUES (NEW.reviewer_id, 'REVIEWER_VERIFY', NULL, 'reviewer session issued');
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON customer_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (customer_id, action, ref, detail)
    VALUES (NEW.customer_id, 'CASE_OPENED', NEW.case_id, NEW.request_type || ' -> ' || coalesce(NEW.assigned_team, '?')
            || coalesce('; parked ' || NEW.parked_action, ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_case AFTER INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION audit_case();

-- =====================================================================
-- AGENT REFERENCE READS - the only SQL the three A2A agents' tools run (SELECT * FROM ref_<topic>(CAST(?lookup AS text))).
-- SELECT-only, STABLE, no identity argument. p_term is the one value the model may supply: empty / NULL -> the whole
-- guide; otherwise one or more words separated by , or ; - a row matches when a word equals its section (spaces =
-- underscores) or appears in its term or meaning (plain substring, no wildcards). Unknown words -> 0 rows (never an error).
-- =====================================================================
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

-- PlanRecommender: the plan rows come from plans (one source of truth), the rest from plan_guide.
CREATE OR REPLACE FUNCTION ref_plan_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT 'PLAN'::text AS sec, p.plan_code::text AS trm,
                 p.plan_name || ': ' || data_txt(p.data_gb) || ' data, unlimited talk and text, ' || usd(p.monthly_price)
                 || ' a month before taxes and fees; roaming: ' || p.roaming_included
                 || CASE WHEN p.is_device THEN '; includes a ' || p.device_months || '-month device installment' ELSE '' END || '.' AS mng,
                 (p.monthly_price * 10)::int AS ord
            FROM plans p
          UNION ALL
          SELECT g.section::text, g.term::text, g.meaning::text, g.entry_id FROM plan_guide g) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['PLAN','COLUMN','REASON_CODE','ELIGIBILITY','HABIT','ADD_ON','STANDARD_LINE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

-- ChargeClassifier: who decides a dispute or a fraud case is read from case_routing (one source of truth).
CREATE OR REPLACE FUNCTION ref_charge_taxonomy(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM charge_taxonomy g
          UNION ALL
          SELECT 'WHO_DECIDES', t.label::text,
                 'A person on the ' || t.team || CASE WHEN t.team ILIKE '% team' THEN '' ELSE ' team' END
                 || ' decides it: ' || t.sla_text, 1000 + t.sla_business_days
            FROM case_routing t WHERE t.request_type IN ('billing_dispute', 'suspected_fraud')) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CATEGORY','NEXT_PATH','SIGNAL','CUSTOMER_LINE','WHO_DECIDES'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_bill_glossary(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM bill_glossary g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['CATEGORY','LINE_ITEM','RATE','COLUMN','STANDARD_LINE'], g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
