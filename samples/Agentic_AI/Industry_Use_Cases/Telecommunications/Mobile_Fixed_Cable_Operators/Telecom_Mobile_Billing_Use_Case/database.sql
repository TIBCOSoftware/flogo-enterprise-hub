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
--   * email_log_row()           the confirmation email is authorised only for the caller's EXECUTED events
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

DROP TABLE IF EXISTS email_log, case_requests, service_cases, confirm_attempts, account_events, pending_actions,
  plan_changes, content_subscriptions, roaming_days, usage_cycles, unbilled_charges, payments, bill_lines,
  bills, customer_sessions, customers, case_routing, plans CASCADE;
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
  account_opened   DATE NOT NULL
);

CREATE TABLE customer_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  customer_id    VARCHAR(12) NOT NULL REFERENCES customers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes'
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
  status        VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every open_service_case call by a verified customer (OPENED / EXISTING / INVALID_TYPE).
CREATE TABLE case_requests (
  request_id    SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  request_type  VARCHAR(40) NOT NULL,                 -- normalised as given
  outcome       VARCHAR(14) NOT NULL,
  case_id       VARCHAR(16),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id      SERIAL PRIMARY KEY,
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  reference     VARCHAR(16) NOT NULL REFERENCES account_events (reference),
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
      LEFT JOIN customer_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.expires_at > clock_timestamp()
      LEFT JOIN customers c ON c.customer_id = s.customer_id;
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
        JOIN customer_sessions se ON se.customer_id = c.customer_id AND se.expires_at > clock_timestamp()
       WHERE c.mobile_number = norm_mobile(p_mobile) AND c.otp_code = trim(coalesce(p_otp, ''))
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
-- HUMAN-OWNED CASES - routed by case_routing; one open case per (customer, request_type)
-- =====================================================================
-- Guarded write-row (VOLATILE: records the attempt in case_requests): returns the service_cases row
-- only for a verified caller, a known request type and no open case of that type.
CREATE OR REPLACE FUNCTION open_case_fn(p_token TEXT, p_type TEXT, p_summary TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, customer_id VARCHAR, request_type VARCHAR, summary TEXT) AS $$
DECLARE v_cust TEXT; v_type TEXT := norm_request_type(p_type); v_existing TEXT; v_no BIGINT; v_case TEXT;
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
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'TW-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (customer_id, request_type, outcome, case_id) VALUES (v_cust, v_type, 'OPENED', v_case);
  RETURN QUERY SELECT v_no, v_case::varchar, v_cust::varchar, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request_type VARCHAR, team VARCHAR, sla_text VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, cr.request_type::varchar, rt.team, rt.sla_text,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (mobile number and one-time code).'
              WHEN cr.outcome = 'OPENED' THEN 'Your case is open. A person on our ' || rt.team || CASE WHEN rt.team ILIKE '% team' THEN '' ELSE ' team' END || ' will look at your request and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' case, so no new case was opened. Our ' || rt.team || ' team is on it.'
              ELSE 'That is not a request we can open a case for here. A person can help with cancelling your service, moving your number to another provider, billing disputes and suspected fraud.' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT r.* FROM case_requests r
       WHERE r.customer_id = sc.customer_id AND r.request_type = norm_request_type(p_type)
       ORDER BY r.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- EMAIL - authorised only for the caller's own EXECUTED action events
-- =====================================================================
CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (customer_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT ae.customer_id, ae.reference, 'Tidewell Mobile confirmation ' || ae.reference
    FROM session_customer(p_token) sc
    JOIN account_events ae ON ae.customer_id = sc.customer_id AND ae.reference = upper(trim(coalesce(p_reference, '')))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN ae.event_id IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN ae.event_id IS NOT NULL THEN NULL WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN ae.event_id IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (mobile number and one-time code).'
              ELSE 'There is no completed change with that reference on your account, so no email was sent.' END,
         ae.reference,
         CASE WHEN ae.event_id IS NOT NULL THEN 'Tidewell Mobile confirmation ' || ae.reference
              ELSE 'Tidewell Mobile confirmation - not sent' END,
         CASE WHEN ae.event_id IS NOT NULL THEN
           'Hi ' || c.first_name || ',' || chr(10) || chr(10)
           || 'This confirms the change you asked Nova, the Tidewell Mobile assistant, to make:' || chr(10)
           || ae.summary || '.' || chr(10)
           || 'Reference: ' || ae.reference || chr(10)
           || 'Done on: ' || to_char(ae.created_at, 'YYYY-MM-DD HH24:MI') || chr(10)
           || coalesce('Effective: ' || to_char(ae.effective_date, 'YYYY-MM-DD') || chr(10), '')
           || chr(10) || 'Thank you for being with Tidewell Mobile.'
           ELSE 'No confirmation email was sent for reference ' || upper(trim(coalesce(p_reference, ''))) || '.' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN account_events ae ON ae.customer_id = sc.customer_id AND ae.reference = upper(trim(coalesce(p_reference, '')))
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
