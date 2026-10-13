-- Ridgeline Power & Light - Electric Outage & Billing (GOVERNED) - schema, business rules and demo data.
-- PostgreSQL 14+.  Database: power_distribution_governed
-- Load:  createdb power_distribution_governed  &&  psql -d power_distribution_governed -f database.sql
--
-- =====================================================================
-- Fictional Texas electric utility "Ridgeline Power & Light", assistant "Sage".
-- The rules live HERE, not in any prompt:
--   * session_customer() / session_reviewer()  identity: every read/write is scoped by a session token
--   * verify_*_fn()            one-time-code check + throttle (5 failures in 15 minutes -> locked)
--   * my_*() / bill_*()        scoped reads - only the caller's rows; another account's bill -> NOT_FOUND row
--   * bill_comparison()        bill-to-bill deltas, kWh vs last year and weather are computed in SQL
--   * plan_cost()              estimated monthly cost per rate plan from the customer's real usage
--   * action_eval()            ONE rule function for the two-step actions (REPORT_OUTAGE, CHANGE_RATE_PLAN)
--   * confirm_action_fn()      re-checks every rule; the trigger links the report to a known area outage
--   * appointment_eval()       slot capacity, slot date, meter type, one open appointment per type
--   * reconnect_eval()         reconnect only when disconnected and the past-due balance is cleared
--   * open_case_fn()           human-owned requests routed by case_routing; one open case per type
--   * decide_case_row()        the reviewer guard (role, team, authority limit, amount, note)
--   * trg_review_decision      executes the parked action through the guarded rule functions + audit
--   * email_ref()              the email is authorised only for a reference the session may see
--   * ref_bill_glossary() / ref_outage_triage() / ref_rate_plans()  the A2A agents' ONLY database access: read-only
--                              reference tables (bill glossary, triage guide, rate plans + notes) with no customer
--                              or staff data; one optional lookup term, never an identity
-- Hidden from every tool: otp_code, one_time_code, email, internal_notes, credit_risk_score, internal_note.
-- Money: USD. Billing cycle = calendar month, bills issued on the 1st, due the last day of that month.
-- All demo dates are relative to CURRENT_DATE / now() (seed_data.sql).
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid() on PostgreSQL < 13

-- Re-runnable: drop this use case's functions first (CREATE OR REPLACE cannot change a return type).
-- Extension-owned functions (pgcrypto) are left alone. Use a dedicated database.
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

DROP TABLE IF EXISTS email_log, agent_audit, payment_arrangements, review_decisions, service_cases, tool_attempts,
  account_events, pending_actions, plan_changes, service_orders, appointments, appointment_slots, outage_tickets,
  outages, payments, bill_lines, bills, verify_attempts, sessions, reviewers, customers, case_routing, rate_plans,
  bill_glossary, outage_triage_guide, rate_plan_notes CASCADE;

-- ---------------------------------------------------------------------
-- Catalogue and routing
-- ---------------------------------------------------------------------
CREATE TABLE rate_plans (
  plan_code          VARCHAR(10) PRIMARY KEY,
  plan_name          VARCHAR(60) NOT NULL,
  description        VARCHAR(240) NOT NULL,
  base_charge        NUMERIC(10,2) NOT NULL,         -- USD per month
  energy_rate        NUMERIC(8,4),                   -- flat USD/kWh; NULL on time-of-use plans
  on_peak_rate       NUMERIC(8,4),                   -- weekdays 2 PM - 8 PM
  off_peak_rate      NUMERIC(8,4),
  export_credit_rate NUMERIC(8,4) NOT NULL DEFAULT 0,  -- USD/kWh credited for solar export
  needs_smart_meter  BOOLEAN NOT NULL DEFAULT FALSE,
  needs_solar        BOOLEAN NOT NULL DEFAULT FALSE
);

-- Human-owned request types -> team + SLA + the action that runs if a reviewer approves.
CREATE TABLE case_routing (
  request_type   VARCHAR(30) PRIMARY KEY,
  label          VARCHAR(50) NOT NULL,               -- customer-facing name
  team           VARCHAR(40) NOT NULL,
  sla_hours      INTEGER NOT NULL,
  sla_text       VARCHAR(160) NOT NULL,
  parked_action  VARCHAR(20)                         -- BILL_CREDIT | PAYMENT_PLAN | MEDICAL_BASELINE | NULL
);

-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO customer, staff, case, session or contact data, ever.
CREATE TABLE bill_glossary (                      -- bill_explainer_agent: bill categories, line items, columns
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CATEGORY', 'LINE_ITEM', 'TOU_PERIOD', 'COLUMN', 'WEATHER',
                                                      'READ_TYPE')),
  term        VARCHAR(60) NOT NULL,               -- power_cost_rider
  meaning     VARCHAR(300) NOT NULL,              -- a per-kWh charge for fuel and purchased power ...
  UNIQUE (section, term)
);

CREATE TABLE outage_triage_guide (                -- outage_triage_agent: categories, hazard signs, paths, safety lines
  entry_id    SERIAL PRIMARY KEY,                 -- (the hazard ROUTING row comes from case_routing)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CATEGORY', 'HAZARD_SIGN', 'CONNECTION', 'NEXT_PATH',
                                                      'SAFETY_LINE', 'RULE')),
  term        VARCHAR(60) NOT NULL,               -- downed power line
  meaning     VARCHAR(300) NOT NULL,              -- HAZARD: a power line on the ground ...
  UNIQUE (section, term)
);

CREATE TABLE rate_plan_notes (                    -- rate_plan_agent: comparison columns, reason codes, eligibility
  entry_id    SERIAL PRIMARY KEY,                 -- (the PLAN rows come from rate_plans)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('TOU_PERIOD', 'COLUMN', 'REASON_CODE', 'ELIGIBILITY', 'HABIT')),
  term        VARCHAR(60) NOT NULL,               -- SMART_METER_REQUIRED
  meaning     VARCHAR(300) NOT NULL,              -- needs a smart meter first ...
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- People: customers (account number + one-time code) and reviewers (staff id + one-time code)
-- ---------------------------------------------------------------------
CREATE TABLE customers (
  customer_id       VARCHAR(12) PRIMARY KEY,         -- the account number, RPL-100101
  otp_code          VARCHAR(6)  NOT NULL,            -- HIDDEN: demo stand-in for the texted one-time code
  first_name        VARCHAR(40) NOT NULL,
  last_name         VARCHAR(40) NOT NULL,
  email             VARCHAR(100) NOT NULL,           -- HIDDEN (emails go to the EMAIL_TO demo inbox)
  service_address   VARCHAR(120) NOT NULL,
  service_area      VARCHAR(40) NOT NULL,            -- outages are tracked per service area
  meter_number      VARCHAR(12) NOT NULL,
  meter_type        VARCHAR(6)  NOT NULL CHECK (meter_type IN ('SMART','ANALOG')),
  connection_status VARCHAR(20) NOT NULL CHECK (connection_status IN ('CONNECTED','DISCONNECTED','RECONNECT_PENDING')),
  disconnected_on   DATE,
  plan_code         VARCHAR(10) NOT NULL REFERENCES rate_plans,
  solar_installed   BOOLEAN NOT NULL DEFAULT FALSE,
  medical_baseline  BOOLEAN NOT NULL DEFAULT FALSE,
  autopay           BOOLEAN NOT NULL DEFAULT FALSE,
  credit_risk_score INTEGER NOT NULL DEFAULT 10,     -- HIDDEN
  internal_notes    TEXT,                            -- HIDDEN
  customer_since    DATE NOT NULL
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(12) PRIMARY KEY,           -- RPL-S-201
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,              -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,              -- HIDDEN
  approval_limit  NUMERIC(10,2),                     -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL CHECK (role IN ('CUSTOMER','REVIEWER')),
  principal_id   VARCHAR(12) NOT NULL,
  team           VARCHAR(40),
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '30 minutes'
);

-- Every verify call (throttle + readback).
CREATE TABLE verify_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  role           VARCHAR(10) NOT NULL,
  principal_ref  VARCHAR(40) NOT NULL,               -- normalised identifier as typed
  outcome        VARCHAR(16) NOT NULL,               -- VERIFIED | VERIFY_FAILED | VERIFY_LOCKED
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Bills (one per calendar month, with that month's metered usage), line items, payments
-- ---------------------------------------------------------------------
CREATE TABLE bills (
  bill_id             VARCHAR(20) PRIMARY KEY,       -- BL-100101-2609
  customer_id         VARCHAR(12) NOT NULL REFERENCES customers,
  period_start        DATE NOT NULL,
  period_end          DATE NOT NULL,
  issue_date          DATE NOT NULL,
  due_date            DATE NOT NULL,
  read_type           VARCHAR(10) NOT NULL CHECK (read_type IN ('ACTUAL','ESTIMATED')),
  kwh                 NUMERIC(8,0) NOT NULL,
  on_peak_kwh         NUMERIC(8,0),                  -- NULL on analog meters (no time-of-day data)
  off_peak_kwh        NUMERIC(8,0),
  solar_export_kwh    NUMERIC(8,0) NOT NULL DEFAULT 0,
  prior_year_kwh      NUMERIC(8,0),                  -- same month last year
  cooling_degree_days INTEGER,                       -- weather: higher = hotter month
  prior_year_cdd      INTEGER
);
CREATE INDEX ix_bills_customer ON bills (customer_id, period_start);

CREATE TABLE bill_lines (
  line_id         SERIAL PRIMARY KEY,
  bill_id         VARCHAR(20) NOT NULL REFERENCES bills,
  category        VARCHAR(20) NOT NULL CHECK (category IN ('BASE_CHARGE','ENERGY','ENERGY_ON_PEAK','ENERGY_OFF_PEAK',
                    'POWER_COST_RIDER','SOLAR_CREDIT','TAXES_FEES','LATE_FEE','BILL_CREDIT')),
  description     VARCHAR(140) NOT NULL,
  amount          NUMERIC(10,2) NOT NULL,
  source_case_id  VARCHAR(16)                        -- BILL_CREDIT lines: the approved case
);

CREATE TABLE payments (
  payment_id   SERIAL PRIMARY KEY,
  reference    VARCHAR(16) NOT NULL UNIQUE,          -- PAY-260901
  customer_id  VARCHAR(12) NOT NULL REFERENCES customers,
  bill_id      VARCHAR(20) NOT NULL REFERENCES bills,
  paid_on      DATE NOT NULL,
  amount       NUMERIC(10,2) NOT NULL,
  method       VARCHAR(20) NOT NULL
);

-- ---------------------------------------------------------------------
-- Outages, tickets, appointments, reconnect orders, plan changes
-- ---------------------------------------------------------------------
CREATE TABLE outages (
  outage_id           VARCHAR(16) PRIMARY KEY,       -- OUT-2026-0041
  service_area        VARCHAR(40) NOT NULL,
  cause               VARCHAR(12) NOT NULL CHECK (cause IN ('STORM','EQUIPMENT','VEGETATION','PLANNED')),
  status              VARCHAR(14) NOT NULL CHECK (status IN ('INVESTIGATING','CREW_ASSIGNED','RESTORING','RESTORED')),
  started_at          TIMESTAMP NOT NULL,
  etr                 TIMESTAMP,                     -- estimated restoration
  customers_affected  INTEGER NOT NULL,
  customers_reported  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE outage_tickets (
  ticket_no         BIGSERIAL PRIMARY KEY,
  ticket_id         VARCHAR(16) NOT NULL UNIQUE,     -- OTK-000101
  customer_id       VARCHAR(12) NOT NULL REFERENCES customers,
  outage_id         VARCHAR(16) REFERENCES outages,  -- set when linked to a known area outage
  ticket_type       VARCHAR(8)  NOT NULL CHECK (ticket_type IN ('NEW','LINKED')),
  symptom           VARCHAR(20) NOT NULL,
  status            VARCHAR(16) NOT NULL CHECK (status IN ('OPEN','CREW_DISPATCHED','LINKED','RESTORED')),
  eta               TIMESTAMP,
  source_reference  VARCHAR(16),                     -- the account_events reference
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE appointment_slots (
  slot_id      VARCHAR(10) PRIMARY KEY,              -- SLOT-04
  slot_date    DATE NOT NULL,
  time_window  VARCHAR(20) NOT NULL,                 -- 8 AM - 12 PM / 1 PM - 5 PM
  capacity     INTEGER NOT NULL,
  booked       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE appointments (
  appt_no           BIGSERIAL PRIMARY KEY,
  appointment_id    VARCHAR(16) NOT NULL UNIQUE,     -- APPT-000101
  customer_id       VARCHAR(12) NOT NULL REFERENCES customers,
  appointment_type  VARCHAR(20) NOT NULL CHECK (appointment_type IN ('METER_UPGRADE','METER_INSPECTION')),
  slot_id           VARCHAR(10) NOT NULL REFERENCES appointment_slots,
  status            VARCHAR(10) NOT NULL DEFAULT 'SCHEDULED' CHECK (status IN ('SCHEDULED','COMPLETED','CANCELLED')),
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE service_orders (
  order_no      BIGSERIAL PRIMARY KEY,
  order_id      VARCHAR(16) NOT NULL UNIQUE,         -- SO-000101
  customer_id   VARCHAR(12) NOT NULL REFERENCES customers,
  order_type    VARCHAR(12) NOT NULL CHECK (order_type IN ('RECONNECT')),
  scheduled_by  TIMESTAMP NOT NULL,
  status        VARCHAR(10) NOT NULL DEFAULT 'SCHEDULED' CHECK (status IN ('SCHEDULED','COMPLETED')),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE plan_changes (
  change_id         SERIAL PRIMARY KEY,
  customer_id       VARCHAR(12) NOT NULL REFERENCES customers,
  from_plan         VARCHAR(10) NOT NULL REFERENCES rate_plans,
  to_plan           VARCHAR(10) NOT NULL REFERENCES rate_plans,
  effective_date    DATE NOT NULL,
  status            VARCHAR(10) NOT NULL CHECK (status IN ('SCHEDULED','APPLIED')),
  source_reference  VARCHAR(16)
);

-- ---------------------------------------------------------------------
-- Two-step actions: proposals -> confirmed events (the only path for REPORT_OUTAGE / CHANGE_RATE_PLAN)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'RPL-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  customer_id    VARCHAR(12) NOT NULL REFERENCES customers,
  action_type    VARCHAR(30) NOT NULL,
  target         VARCHAR(40) NOT NULL,
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  price          NUMERIC(10,2),                      -- CHANGE_RATE_PLAN: estimated monthly base + energy cost
  effective_date DATE,
  outage_id      VARCHAR(16),                        -- REPORT_OUTAGE: the known outage it would link to
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_customer ON pending_actions (customer_id, action_type, target, created_at);

CREATE TABLE account_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(16) NOT NULL UNIQUE,        -- RPL-ACT-000101
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  customer_id    VARCHAR(12) NOT NULL REFERENCES customers,
  action_type    VARCHAR(30) NOT NULL,
  target         VARCHAR(40) NOT NULL,
  price          NUMERIC(10,2),
  effective_date DATE,
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every confirm / book / reconnect / open-case / decide call, written by the guarded row functions so each
-- readback reports exactly what that call did (outcome + reason).
CREATE TABLE tool_attempts (
  attempt_id    SERIAL PRIMARY KEY,
  principal_id  VARCHAR(12) NOT NULL,                -- customer or reviewer
  tool          VARCHAR(30) NOT NULL,
  ref_key       TEXT NOT NULL,
  outcome       VARCHAR(20) NOT NULL,
  reason_code   VARCHAR(24),
  reason_text   TEXT,
  reference     VARCHAR(20),
  summary       TEXT,
  amount        NUMERIC(10,2),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_attempts ON tool_attempts (principal_id, tool, ref_key, attempt_id);

-- ---------------------------------------------------------------------
-- Human-owned cases, reviewer decisions (insert-only), audit, arrangements, email log
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no           BIGSERIAL PRIMARY KEY,
  case_id           VARCHAR(16) NOT NULL UNIQUE,     -- RPL-CASE-000141
  customer_id       VARCHAR(12) NOT NULL REFERENCES customers,
  request_type      VARCHAR(30) NOT NULL REFERENCES case_routing,
  team              VARCHAR(40) NOT NULL,
  summary           TEXT NOT NULL,                   -- the customer's request in their words
  agent_brief       TEXT,                            -- neutral brief from the assistant / A2A agent output
  requested_amount  NUMERIC(10,2),
  parked_action     VARCHAR(20),                     -- what runs on approval
  parked_ref        VARCHAR(20),                     -- e.g. the bill to credit
  sla_due_at        TIMESTAMP NOT NULL,
  status            VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  customer_message  TEXT,                            -- customer-safe outcome text (set by the decision)
  outcome_summary   TEXT,                            -- what the system executed on approval
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  decided_at        TIMESTAMP
);

CREATE TABLE review_decisions (
  decision_id       BIGSERIAL PRIMARY KEY,
  case_id           VARCHAR(16) NOT NULL UNIQUE REFERENCES service_cases (case_id),   -- one decision per case
  reviewer_id       VARCHAR(12) NOT NULL REFERENCES reviewers,
  decision          VARCHAR(8)  NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount   NUMERIC(10,2),
  internal_note     TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),          -- HIDDEN from customers
  customer_message  TEXT NOT NULL,
  decided_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE agent_audit (
  audit_id    SERIAL PRIMARY KEY,
  event       VARCHAR(20) NOT NULL,                  -- CASE_DECIDED
  case_id     VARCHAR(16),
  actor       VARCHAR(12) NOT NULL,
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE payment_arrangements (
  arrangement_no      BIGSERIAL PRIMARY KEY,
  arrangement_id      VARCHAR(16) NOT NULL UNIQUE,   -- PA-000101
  customer_id         VARCHAR(12) NOT NULL REFERENCES customers,
  case_id             VARCHAR(16) NOT NULL UNIQUE,
  total_amount        NUMERIC(10,2) NOT NULL,
  installments        INTEGER NOT NULL,
  installment_amount  NUMERIC(10,2) NOT NULL,
  first_due           DATE NOT NULL,
  status              VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
);

CREATE TABLE email_log (
  email_id      SERIAL PRIMARY KEY,
  principal_id  VARCHAR(12) NOT NULL,
  reference     VARCHAR(20) NOT NULL,
  subject       TEXT NOT NULL,
  logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- HELPERS
-- =====================================================================
CREATE OR REPLACE FUNCTION next_cycle_start() RETURNS DATE AS $$
  SELECT (date_trunc('month', current_date) + INTERVAL '1 month')::date $$ LANGUAGE sql STABLE;
-- $45.00 / $9.99 / $1,234.50
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL
              WHEN n < 0 THEN '-$' || to_char(-n, 'FM999,999,990.00')
              ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION kwh_txt(n NUMERIC) RETURNS TEXT AS $$
  SELECT to_char(n, 'FM999,999,990') || ' kWh' $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION ts_txt(t TIMESTAMP) RETURNS TEXT AS $$
  SELECT to_char(t, 'Mon FMDD "at" FMHH12:MI AM') $$ LANGUAGE sql IMMUTABLE;

-- RPL-100101 / rpl 100101 / 100101 / "account 100101" -> RPL-100101
CREATE OR REPLACE FUNCTION norm_account(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^[0-9]{6}$' THEN 'RPL-' || d ELSE left(upper(trim(coalesce(p, ''))), 40) END
    FROM (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS d) x
$$ LANGUAGE sql IMMUTABLE;
-- RPL-S-201 / S-201 / 201 -> RPL-S-201
CREATE OR REPLACE FUNCTION norm_staff(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^[0-9]{3}$' THEN 'RPL-S-' || d ELSE left(upper(trim(coalesce(p, ''))), 40) END
    FROM (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS d) x
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_action(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 30) $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_target(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40) $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40) $$ LANGUAGE sql IMMUTABLE;
-- '$30', '30.00', '30 dollars' -> 30.00; a negative amount -> -1; no number -> NULL
CREATE OR REPLACE FUNCTION parse_amount(p TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN replace(coalesce(p, ''), ',', '') ~ '-\s*\$?\s*[0-9]' THEN -1
              ELSE round(substring(replace(coalesce(p, ''), ',', '') FROM '[0-9]+(?:\.[0-9]+)?')::numeric, 2) END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION mask_account(p TEXT) RETURNS TEXT AS $$ SELECT '****' || right(p, 4) $$ LANGUAGE sql IMMUTABLE;

-- Money position
CREATE OR REPLACE FUNCTION bill_total(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(amount), 0) FROM bill_lines WHERE bill_id = p_bill $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION bill_paid(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(amount), 0) FROM payments WHERE bill_id = p_bill $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION bill_credits(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(amount), 0) FROM bill_lines WHERE bill_id = p_bill AND category = 'BILL_CREDIT' $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION bill_outstanding(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT greatest(bill_total(p_bill) - bill_paid(p_bill), 0) $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION balance_due(p_cust TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(bill_outstanding(b.bill_id)), 0) FROM bills b WHERE b.customer_id = p_cust $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION past_due_amount(p_cust TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(bill_outstanding(b.bill_id)), 0) FROM bills b
   WHERE b.customer_id = p_cust AND b.due_date < current_date $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION days_past_due(p_cust TEXT) RETURNS INTEGER AS $$
  SELECT coalesce(max(current_date - b.due_date), 0)::int FROM bills b
   WHERE b.customer_id = p_cust AND b.due_date < current_date AND bill_outstanding(b.bill_id) > 0 $$ LANGUAGE sql STABLE;
-- usage-based charges of a bill (what a corrected meter read can change)
CREATE OR REPLACE FUNCTION bill_usage_charges(p_bill TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(amount), 0) FROM bill_lines
   WHERE bill_id = p_bill AND category IN ('ENERGY','ENERGY_ON_PEAK','ENERGY_OFF_PEAK','POWER_COST_RIDER') $$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION latest_bill(p_cust TEXT) RETURNS TEXT AS $$
  SELECT bill_id FROM bills WHERE customer_id = p_cust ORDER BY period_start DESC LIMIT 1 $$ LANGUAGE sql STABLE;

-- Estimated monthly base + energy cost of a plan on the customer's last 3 billed periods (riders and taxes are the
-- same on every plan and left out). NULL when there is no usage history.
CREATE OR REPLACE FUNCTION plan_cost(p_cust TEXT, p_plan TEXT) RETURNS NUMERIC AS $$
  SELECT round(rp.base_charge
               + CASE WHEN rp.energy_rate IS NOT NULL THEN u.kwh * rp.energy_rate
                      ELSE u.on_kwh * rp.on_peak_rate + u.off_kwh * rp.off_peak_rate END
               - u.export_kwh * rp.export_credit_rate, 2)
    FROM rate_plans rp,
         (SELECT avg(kwh) AS kwh, avg(on_peak_kwh) AS on_kwh, avg(off_peak_kwh) AS off_kwh,
                 avg(solar_export_kwh) AS export_kwh, count(*) AS n
            FROM (SELECT * FROM bills WHERE customer_id = p_cust ORDER BY period_start DESC LIMIT 3) b) u
   WHERE rp.plan_code = p_plan AND u.n > 0
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- IDENTITY (customers and reviewers; tokens are not interchangeable)
-- =====================================================================
-- Always exactly one row: the customer for a live CUSTOMER token, else NULL.
CREATE OR REPLACE FUNCTION session_customer(p_token TEXT)
RETURNS TABLE (customer_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT c.customer_id
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'CUSTOMER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN customers c ON c.customer_id = s.principal_id;
END $$ LANGUAGE plpgsql STABLE;

-- Always exactly one row: the active reviewer for a live REVIEWER token, else NULLs.
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, display_name VARCHAR, team VARCHAR, approval_limit NUMERIC) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.display_name, r.team, r.approval_limit
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN reviewers r ON r.reviewer_id = s.principal_id AND r.active;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row for verify (VOLATILE: logs the attempt). A session is issued ONLY for a matching account +
-- one-time code, and never while the account is throttled (5 failed attempts in 15 minutes).
CREATE OR REPLACE FUNCTION verify_customer_fn(p_account TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, principal_id VARCHAR, team VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_ref TEXT := norm_account(p_account); v_cust TEXT; v_fails INT;
BEGIN
  SELECT count(*) INTO v_fails FROM verify_attempts a
   WHERE a.role = 'CUSTOMER' AND a.principal_ref = v_ref AND a.outcome = 'VERIFY_FAILED'
     AND a.created_at > clock_timestamp() - INTERVAL '15 minutes';
  IF v_fails >= 5 THEN
    INSERT INTO verify_attempts (role, principal_ref, outcome) VALUES ('CUSTOMER', v_ref, 'VERIFY_LOCKED'); RETURN;
  END IF;
  SELECT c.customer_id INTO v_cust FROM customers c WHERE c.customer_id = v_ref AND c.otp_code = trim(coalesce(p_code, ''));
  IF v_cust IS NULL THEN
    INSERT INTO verify_attempts (role, principal_ref, outcome) VALUES ('CUSTOMER', v_ref, 'VERIFY_FAILED'); RETURN;
  END IF;
  INSERT INTO verify_attempts (role, principal_ref, outcome) VALUES ('CUSTOMER', v_ref, 'VERIFIED');
  RETURN QUERY SELECT 'CUSTOMER'::varchar, v_cust::varchar, NULL::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_result(p_account TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, first_name VARCHAR, expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT CASE WHEN s.session_token IS NOT NULL THEN 'VERIFIED'
              WHEN va.outcome = 'VERIFY_LOCKED' THEN 'VERIFY_LOCKED' ELSE 'VERIFY_FAILED' END,
         s.session_token, s.first_name, s.expires_at,
         CASE WHEN s.session_token IS NOT NULL THEN 'You are verified. This session is valid for 30 minutes.'
              WHEN va.outcome = 'VERIFY_LOCKED' THEN 'Too many attempts. For your security, please wait 15 minutes and try again.'
              ELSE 'That account number and one-time code do not match our records. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a
                        WHERE a.role = 'CUSTOMER' AND a.principal_ref = norm_account(p_account)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (
      SELECT se.session_token, c.first_name, se.expires_at
        FROM customers c JOIN sessions se ON se.principal_id = c.customer_id AND se.role = 'CUSTOMER'
                                         AND se.expires_at > clock_timestamp()
       WHERE va.outcome = 'VERIFIED' AND c.customer_id = norm_account(p_account) AND c.otp_code = trim(coalesce(p_code, ''))
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION verify_reviewer_fn(p_staff TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, principal_id VARCHAR, team VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_ref TEXT := norm_staff(p_staff); r reviewers; v_fails INT;
BEGIN
  SELECT count(*) INTO v_fails FROM verify_attempts a
   WHERE a.role = 'REVIEWER' AND a.principal_ref = v_ref AND a.outcome = 'VERIFY_FAILED'
     AND a.created_at > clock_timestamp() - INTERVAL '15 minutes';
  IF v_fails >= 5 THEN
    INSERT INTO verify_attempts (role, principal_ref, outcome) VALUES ('REVIEWER', v_ref, 'VERIFY_LOCKED'); RETURN;
  END IF;
  SELECT * INTO r FROM reviewers x WHERE x.reviewer_id = v_ref AND x.one_time_code = trim(coalesce(p_code, '')) AND x.active;
  IF NOT FOUND THEN
    INSERT INTO verify_attempts (role, principal_ref, outcome) VALUES ('REVIEWER', v_ref, 'VERIFY_FAILED'); RETURN;
  END IF;
  INSERT INTO verify_attempts (role, principal_ref, outcome) VALUES ('REVIEWER', v_ref, 'VERIFIED');
  RETURN QUERY SELECT 'REVIEWER'::varchar, r.reviewer_id, r.team;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_reviewer_result(p_staff TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, role TEXT, display_name VARCHAR, team VARCHAR, approval_limit NUMERIC,
               expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT CASE WHEN s.session_token IS NOT NULL THEN 'VERIFIED'
              WHEN va.outcome = 'VERIFY_LOCKED' THEN 'VERIFY_LOCKED' ELSE 'VERIFY_FAILED' END,
         s.session_token, CASE WHEN s.session_token IS NOT NULL THEN 'REVIEWER' END,
         s.display_name, s.team, s.approval_limit, s.expires_at,
         CASE WHEN s.session_token IS NOT NULL THEN 'Staff verified. You can review the ' || s.team || ' queue for 30 minutes.'
              WHEN va.outcome = 'VERIFY_LOCKED' THEN 'Too many attempts. Please wait 15 minutes and try again.'
              ELSE 'That staff ID and code do not match. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a
                        WHERE a.role = 'REVIEWER' AND a.principal_ref = norm_staff(p_staff)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (
      SELECT se.session_token, r.display_name, r.team, r.approval_limit, se.expires_at
        FROM reviewers r JOIN sessions se ON se.principal_id = r.reviewer_id AND se.role = 'REVIEWER'
                                         AND se.expires_at > clock_timestamp()
       WHERE va.outcome = 'VERIFIED' AND r.reviewer_id = norm_staff(p_staff) AND r.one_time_code = trim(coalesce(p_code, ''))
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- RULE FUNCTIONS (deterministic; every reason code has customer-safe wording)
-- =====================================================================
-- The two-step actions: REPORT_OUTAGE and CHANGE_RATE_PLAN. Anything else (incl. the retired DISCONNECT and
-- TRANSFER) -> INVALID_ACTION.
CREATE OR REPLACE FUNCTION action_eval(p_cust TEXT, p_action TEXT, p_target TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, summary TEXT, price NUMERIC, effective_date DATE,
               outage_id TEXT) AS $$
#variable_conflict use_column
DECLARE c customers; v_act TEXT := norm_action(p_action); v_tgt TEXT := norm_target(p_target);
        o outages; t outage_tickets; cp rate_plans; tp rate_plans; v_new NUMERIC; v_cur NUMERIC; v_sym TEXT;
BEGIN
  SELECT * INTO c FROM customers x WHERE x.customer_id = p_cust;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_act = 'REPORT_OUTAGE' THEN
    v_sym := CASE v_tgt WHEN 'NO_POWER' THEN 'no power' WHEN 'PARTIAL_POWER' THEN 'partial power'
                        WHEN 'FLICKERING' THEN 'flickering lights' END;
    IF v_sym IS NULL THEN
      RETURN QUERY SELECT FALSE, 'INVALID_TARGET',
        'I can report no power at all (NO_POWER), partial power (PARTIAL_POWER) or flickering lights (FLICKERING).',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    IF c.connection_status <> 'CONNECTED' THEN
      RETURN QUERY SELECT FALSE, 'SERVICE_DISCONNECTED',
        'Your power service is currently disconnected, so this is not an outage on our network. I can check what is needed to reconnect it.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    SELECT * INTO t FROM outage_tickets x WHERE x.customer_id = p_cust AND x.status IN ('OPEN','CREW_DISPATCHED','LINKED')
     ORDER BY x.created_at DESC LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT FALSE, 'ALREADY_REPORTED',
        'You already have an open outage report (' || t.ticket_id || ', ' || lower(replace(t.status, '_', ' '))
          || coalesce(', estimate ' || ts_txt(t.eta), '') || '), so no second report is needed.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    SELECT * INTO o FROM outages x WHERE x.service_area = c.service_area AND x.status IN ('INVESTIGATING','CREW_ASSIGNED','RESTORING')
       AND x.started_at <= clock_timestamp() ORDER BY x.started_at LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
        'Report ' || v_sym || ' at ' || c.service_address || ' and link it to the known ' || lower(o.cause) || ' outage '
          || o.outage_id || ' in ' || c.service_area || ' (crews ' || lower(replace(o.status, '_', ' ')) || ', estimated restoration '
          || ts_txt(o.etr) || '). No separate crew ticket is needed; you will get the same restoration updates.',
        NULL::numeric, NULL::date, o.outage_id::text; RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
      'Report ' || v_sym || ' at ' || c.service_address || ' and open a new outage ticket. There is no known outage in '
        || c.service_area || ', so a crew will be dispatched; the first restoration estimate is within 3 hours.',
      NULL::numeric, NULL::date, NULL::text; RETURN;
  ELSIF v_act = 'CHANGE_RATE_PLAN' THEN
    SELECT * INTO tp FROM rate_plans x WHERE x.plan_code = v_tgt;
    IF NOT FOUND THEN
      RETURN QUERY SELECT FALSE, 'INVALID_TARGET', 'That is not one of our rate plans. The plans are STANDARD, TOU, EV and SOLAR.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    SELECT * INTO cp FROM rate_plans x WHERE x.plan_code = c.plan_code;
    IF tp.plan_code = c.plan_code THEN
      RETURN QUERY SELECT FALSE, 'NO_CHANGE', 'You are already on ' || tp.plan_name || '.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM plan_changes x WHERE x.customer_id = p_cust AND x.status = 'SCHEDULED') THEN
      RETURN QUERY SELECT FALSE, 'CHANGE_PENDING',
        'A rate plan change is already scheduled on your account; only one change can be pending at a time.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    IF tp.needs_smart_meter AND c.meter_type <> 'SMART' THEN
      RETURN QUERY SELECT FALSE, 'SMART_METER_REQUIRED',
        tp.plan_name || ' bills by time of day, so it needs a smart meter. You have an analog meter; I can book a free smart-meter upgrade.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    IF tp.needs_solar AND NOT c.solar_installed THEN
      RETURN QUERY SELECT FALSE, 'NO_SOLAR', tp.plan_name || ' is for homes with solar panels on file, and there are none on your account.',
        NULL::text, NULL::numeric, NULL::date, NULL::text; RETURN;
    END IF;
    v_new := plan_cost(p_cust, tp.plan_code); v_cur := plan_cost(p_cust, cp.plan_code);
    RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
      'Switch from ' || cp.plan_name || ' to ' || tp.plan_name || ' from ' || to_char(next_cycle_start(), 'FMMonth FMDD, YYYY')
        || ' (the start of your next bill cycle). Estimated base + energy charges on your recent usage: '
        || coalesce(usd(v_new), 'n/a') || ' a month (now ' || coalesce(usd(v_cur), 'n/a') || ').',
      v_new, next_cycle_start(), NULL::text; RETURN;
  END IF;
  RETURN QUERY SELECT FALSE, 'INVALID_ACTION',
    'I can report an outage or change your rate plan here. Disconnecting or transferring service needs our customer care team.',
    NULL::text, NULL::numeric, NULL::date, NULL::text;
END $$ LANGUAGE plpgsql STABLE;

-- Appointments: METER_UPGRADE (analog meters only) or METER_INSPECTION, in a future slot with capacity left.
CREATE OR REPLACE FUNCTION appointment_eval(p_cust TEXT, p_type TEXT, p_slot TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, summary TEXT) AS $$
#variable_conflict use_column
DECLARE c customers; s appointment_slots; v_type TEXT := norm_target(p_type); a appointments;
BEGIN
  SELECT * INTO c FROM customers x WHERE x.customer_id = p_cust;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_type NOT IN ('METER_UPGRADE','METER_INSPECTION') THEN
    RETURN QUERY SELECT FALSE, 'INVALID_TYPE', 'I can book a smart-meter upgrade (METER_UPGRADE) or a meter inspection (METER_INSPECTION).', NULL::text; RETURN;
  END IF;
  IF v_type = 'METER_UPGRADE' AND c.meter_type = 'SMART' THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_SMART', 'You already have a smart meter, so no upgrade is needed.', NULL::text; RETURN;
  END IF;
  SELECT * INTO a FROM appointments x WHERE x.customer_id = p_cust AND x.appointment_type = v_type AND x.status = 'SCHEDULED' LIMIT 1;
  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_BOOKED', 'You already have a ' || lower(replace(v_type, '_', ' ')) || ' booked (' || a.appointment_id || ').', NULL::text; RETURN;
  END IF;
  SELECT * INTO s FROM appointment_slots x WHERE x.slot_id = upper(trim(coalesce(p_slot, '')));
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SLOT_NOT_FOUND', 'I could not find that appointment slot. Please pick one from the open slots.', NULL::text; RETURN;
  END IF;
  IF s.slot_date <= current_date THEN
    RETURN QUERY SELECT FALSE, 'SLOT_PAST', 'That slot is no longer available. Appointments can be booked from tomorrow onward.', NULL::text; RETURN;
  END IF;
  IF s.booked >= s.capacity THEN
    RETURN QUERY SELECT FALSE, 'SLOT_FULL', 'That slot is fully booked. Please pick another open slot.', NULL::text; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text,
    initcap(lower(replace(v_type, '_', ' '))) || ' at ' || c.service_address || ' on ' || to_char(s.slot_date, 'FMDay, FMMonth FMDD')
      || ', ' || s.time_window || '. A technician will need access to the meter.';
END $$ LANGUAGE plpgsql STABLE;

-- Reconnect: only when disconnected, the past-due balance is cleared and no reconnect order is open.
CREATE OR REPLACE FUNCTION reconnect_eval(p_cust TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, amount_due NUMERIC) AS $$
#variable_conflict use_column
DECLARE c customers; v_due NUMERIC; v_days INT; o service_orders;
BEGIN
  SELECT * INTO c FROM customers x WHERE x.customer_id = p_cust;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO o FROM service_orders x WHERE x.customer_id = p_cust AND x.order_type = 'RECONNECT' AND x.status = 'SCHEDULED' LIMIT 1;
  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_REQUESTED', 'A reconnection is already scheduled (' || o.order_id || ', by ' || ts_txt(o.scheduled_by) || ').', 0::numeric; RETURN;
  END IF;
  IF c.connection_status <> 'DISCONNECTED' THEN
    RETURN QUERY SELECT FALSE, 'NOT_DISCONNECTED', 'Your power service is not disconnected, so there is nothing to reconnect. If your power is out, I can check for outages.', 0::numeric; RETURN;
  END IF;
  v_due := past_due_amount(p_cust); v_days := days_past_due(p_cust);
  IF v_due > 0 THEN
    RETURN QUERY SELECT FALSE, 'PAST_DUE',
      'Your account has a past-due balance of ' || usd(v_due) || ' (' || v_days || ' days past due), so we cannot reconnect yet. '
        || 'Once it is paid, I can schedule the reconnection right away. If you need help paying, I can ask our Credit & Collections team about a payment arrangement.',
      v_due; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, 0::numeric;
END $$ LANGUAGE plpgsql STABLE;

-- =====================================================================
-- SCOPED READS (customer token). An invalid token -> one SESSION_INVALID row.
-- =====================================================================
CREATE OR REPLACE FUNCTION my_account(p_token TEXT)
RETURNS TABLE (status TEXT, customer_name TEXT, account_number VARCHAR, service_address VARCHAR, service_area VARCHAR,
               meter_type VARCHAR, connection_status VARCHAR, connection_text TEXT, disconnected_on DATE,
               plan_code VARCHAR, plan_name VARCHAR, scheduled_plan_change TEXT, balance_due NUMERIC,
               past_due_amount NUMERIC, days_past_due INTEGER, autopay TEXT, solar_on_file TEXT,
               medical_baseline_protection TEXT, customer_since DATE) AS $$
  SELECT CASE WHEN c.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.first_name || ' ' || c.last_name, c.customer_id, c.service_address, c.service_area,
         c.meter_type, c.connection_status,
         CASE c.connection_status WHEN 'CONNECTED' THEN 'Your power service is connected.'
              WHEN 'DISCONNECTED' THEN 'Your power service is disconnected (since ' || to_char(c.disconnected_on, 'YYYY-MM-DD') || ').'
              WHEN 'RECONNECT_PENDING' THEN 'A reconnection is scheduled.' END,
         c.disconnected_on, c.plan_code, rp.plan_name,
         (SELECT 'Switching to ' || tp.plan_name || ' on ' || to_char(pc.effective_date, 'YYYY-MM-DD')
            FROM plan_changes pc JOIN rate_plans tp ON tp.plan_code = pc.to_plan
           WHERE pc.customer_id = c.customer_id AND pc.status = 'SCHEDULED' ORDER BY pc.change_id DESC LIMIT 1),
         balance_due(c.customer_id), past_due_amount(c.customer_id), days_past_due(c.customer_id),
         CASE WHEN c.autopay THEN 'yes' WHEN c.customer_id IS NOT NULL THEN 'no' END,
         CASE WHEN c.solar_installed THEN 'yes' WHEN c.customer_id IS NOT NULL THEN 'no' END,
         CASE WHEN c.medical_baseline THEN 'enrolled' WHEN c.customer_id IS NOT NULL THEN 'not enrolled' END,
         c.customer_since
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN rate_plans rp ON rp.plan_code = c.plan_code
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_bills(p_token TEXT)
RETURNS TABLE (status TEXT, bill_id VARCHAR, billing_month TEXT, period_start DATE, period_end DATE, issue_date DATE,
               due_date DATE, read_type VARCHAR, kwh NUMERIC, total NUMERIC, credits NUMERIC, paid NUMERIC,
               outstanding NUMERIC, bill_status TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         b.bill_id, to_char(b.period_start, 'FMMonth YYYY'), b.period_start, b.period_end, b.issue_date, b.due_date,
         b.read_type, b.kwh, bill_total(b.bill_id), bill_credits(b.bill_id), bill_paid(b.bill_id), bill_outstanding(b.bill_id),
         CASE WHEN b.bill_id IS NULL THEN NULL WHEN bill_outstanding(b.bill_id) = 0 THEN 'PAID'
              WHEN b.due_date < current_date THEN 'PAST_DUE' ELSE 'UNPAID' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN bills b ON b.customer_id = sc.customer_id
   ORDER BY b.period_start DESC
$$ LANGUAGE sql STABLE;

-- Line items of one bill on the caller's account; anything else -> one NOT_FOUND row.
CREATE OR REPLACE FUNCTION bill_detail(p_token TEXT, p_bill TEXT)
RETURNS TABLE (status TEXT, bill_id VARCHAR, billing_month TEXT, read_type VARCHAR, kwh NUMERIC, category VARCHAR,
               description VARCHAR, amount NUMERIC, bill_total NUMERIC, due_date DATE) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' WHEN b.bill_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         b.bill_id, to_char(b.period_start, 'FMMonth YYYY'), b.read_type, b.kwh, l.category, l.description, l.amount,
         bill_total(b.bill_id), b.due_date
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN bills b ON b.customer_id = sc.customer_id AND b.bill_id = upper(trim(coalesce(p_bill, '')))
    LEFT JOIN bill_lines l ON l.bill_id = b.bill_id
   ORDER BY l.line_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION compare_bucket(p_category TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN p_category = 'BASE_CHARGE' THEN 'base_charge'
              WHEN p_category IN ('ENERGY','ENERGY_ON_PEAK','ENERGY_OFF_PEAK') THEN 'energy'
              WHEN p_category = 'POWER_COST_RIDER' THEN 'power_cost_rider'
              WHEN p_category IN ('SOLAR_CREDIT','BILL_CREDIT') THEN 'credits'
              WHEN p_category = 'TAXES_FEES' THEN 'taxes_fees' ELSE 'other' END $$ LANGUAGE sql IMMUTABLE;

-- Latest vs previous bill by category, plus the usage and weather facts behind it (all computed here).
CREATE OR REPLACE FUNCTION bill_comparison(p_token TEXT)
RETURNS TABLE (status TEXT, category TEXT, previous_amount NUMERIC, latest_amount NUMERIC, delta NUMERIC,
               previous_total NUMERIC, latest_total NUMERIC, latest_bill_id VARCHAR, latest_month TEXT,
               latest_read_type VARCHAR, latest_kwh NUMERIC, previous_kwh NUMERIC, same_month_last_year_kwh NUMERIC,
               kwh_change_vs_last_year_pct NUMERIC, cooling_degree_days INTEGER, cooling_degree_days_last_year INTEGER) AS $$
  WITH sc AS (SELECT * FROM session_customer(p_token)),
       bl AS (SELECT b.*, row_number() OVER (ORDER BY b.period_start DESC) AS rn
                FROM bills b JOIN sc ON b.customer_id = sc.customer_id),
       lat AS (SELECT * FROM bl WHERE rn = 1), prv AS (SELECT * FROM bl WHERE rn = 2),
       cats AS (SELECT unnest(ARRAY['base_charge','energy','power_cost_rider','credits','taxes_fees','other']) AS category,
                       generate_series(1, 6) AS ord),
       amt AS (SELECT bl.rn, compare_bucket(x.category) AS category, sum(x.amount) AS amount
                 FROM bl JOIN bill_lines x ON x.bill_id = bl.bill_id WHERE bl.rn <= 2 GROUP BY 1, 2)
  SELECT CASE WHEN (SELECT customer_id FROM sc) IS NULL THEN 'SESSION_INVALID'
              WHEN (SELECT count(*) FROM bl) < 2 THEN 'NOT_ENOUGH_BILLS' ELSE 'OK' END,
         c.category, coalesce(p.amount, 0), coalesce(a.amount, 0), coalesce(a.amount, 0) - coalesce(p.amount, 0),
         bill_total((SELECT bill_id FROM prv)), bill_total((SELECT bill_id FROM lat)),
         (SELECT bill_id FROM lat), (SELECT to_char(period_start, 'FMMonth YYYY') FROM lat),
         (SELECT read_type FROM lat), (SELECT kwh FROM lat), (SELECT kwh FROM prv), (SELECT prior_year_kwh FROM lat),
         (SELECT round(100.0 * (kwh - prior_year_kwh) / nullif(prior_year_kwh, 0), 0) FROM lat),
         (SELECT cooling_degree_days FROM lat), (SELECT prior_year_cdd FROM lat)
    FROM cats c
    LEFT JOIN amt a ON a.rn = 1 AND a.category = c.category
    LEFT JOIN amt p ON p.rn = 2 AND p.category = c.category
   WHERE (SELECT customer_id FROM sc) IS NOT NULL OR c.ord = 1
   ORDER BY c.ord
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_usage(p_token TEXT)
RETURNS TABLE (status TEXT, billing_month TEXT, read_type VARCHAR, kwh NUMERIC, on_peak_kwh NUMERIC, off_peak_kwh NUMERIC,
               on_peak_share_pct NUMERIC, solar_export_kwh NUMERIC, avg_daily_kwh NUMERIC, same_month_last_year_kwh NUMERIC,
               change_vs_last_year_pct NUMERIC, cooling_degree_days INTEGER, cooling_degree_days_last_year INTEGER) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         to_char(b.period_start, 'FMMonth YYYY'), b.read_type, b.kwh, b.on_peak_kwh, b.off_peak_kwh,
         round(100.0 * b.on_peak_kwh / nullif(b.kwh, 0), 0), b.solar_export_kwh,
         round(b.kwh / nullif(b.period_end - b.period_start + 1, 0), 1), b.prior_year_kwh,
         round(100.0 * (b.kwh - b.prior_year_kwh) / nullif(b.prior_year_kwh, 0), 0),
         b.cooling_degree_days, b.prior_year_cdd
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (SELECT * FROM bills x WHERE x.customer_id = sc.customer_id ORDER BY x.period_start DESC LIMIT 3) b ON TRUE
   ORDER BY b.period_start DESC
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_payments(p_token TEXT)
RETURNS TABLE (status TEXT, paid_on DATE, amount NUMERIC, method VARCHAR, reference VARCHAR, bill_id VARCHAR,
               balance_due NUMERIC, past_due_amount NUMERIC, past_due TEXT, days_past_due INTEGER, autopay TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         p.paid_on, p.amount, p.method, p.reference, p.bill_id,
         balance_due(sc.customer_id), past_due_amount(sc.customer_id),
         CASE WHEN sc.customer_id IS NULL THEN NULL WHEN past_due_amount(sc.customer_id) > 0 THEN 'yes' ELSE 'no' END,
         days_past_due(sc.customer_id),
         (SELECT CASE WHEN c.autopay THEN 'yes' ELSE 'no' END FROM customers c WHERE c.customer_id = sc.customer_id)
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN payments p ON p.customer_id = sc.customer_id
   ORDER BY p.paid_on DESC NULLS LAST
$$ LANGUAGE sql STABLE;

-- Every rate plan with its estimated monthly cost on THIS customer's usage, savings vs the current plan and eligibility.
CREATE OR REPLACE FUNCTION plan_options(p_token TEXT)
RETURNS TABLE (status TEXT, plan_code VARCHAR, plan_name VARCHAR, description VARCHAR, base_charge NUMERIC,
               rates TEXT, needs TEXT, est_monthly_cost NUMERIC, current_plan_est_cost NUMERIC,
               est_monthly_savings NUMERIC, is_current TEXT, eligible TEXT, reason_code TEXT, reason_text TEXT,
               effective_date DATE, basis TEXT) AS $$
  SELECT CASE WHEN c.customer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         rp.plan_code, rp.plan_name, rp.description, rp.base_charge,
         CASE WHEN rp.energy_rate IS NOT NULL THEN usd(rp.energy_rate) || '/kWh'
              ELSE 'on-peak ' || usd(rp.on_peak_rate) || '/kWh, off-peak ' || usd(rp.off_peak_rate) || '/kWh' END
           || CASE WHEN rp.export_credit_rate > 0 THEN ', solar export credit ' || usd(rp.export_credit_rate) || '/kWh' ELSE '' END,
         CASE WHEN rp.needs_solar THEN 'smart meter + solar on file' WHEN rp.needs_smart_meter THEN 'smart meter' ELSE 'none' END,
         plan_cost(c.customer_id, rp.plan_code), plan_cost(c.customer_id, c.plan_code),
         plan_cost(c.customer_id, c.plan_code) - plan_cost(c.customer_id, rp.plan_code),
         CASE WHEN rp.plan_code = c.plan_code THEN 'yes' ELSE 'no' END,
         CASE WHEN e.ok THEN 'yes' ELSE 'no' END,
         CASE WHEN NOT e.ok THEN e.reason_code END, CASE WHEN NOT e.ok THEN e.reason_text END,
         CASE WHEN e.ok THEN next_cycle_start() END,
         'Estimated base + energy charges on your last 3 bills (average); the power-cost rider and taxes are the same on every plan.'
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN rate_plans rp ON c.customer_id IS NOT NULL
    LEFT JOIN LATERAL action_eval(c.customer_id, 'CHANGE_RATE_PLAN', rp.plan_code) e ON c.customer_id IS NOT NULL
   ORDER BY rp.plan_code = c.plan_code DESC, plan_cost(c.customer_id, rp.plan_code)
$$ LANGUAGE sql STABLE;

-- Known outages in the caller's service area (not restored) + the caller's own open ticket. Never another area's
-- customers. No outage -> one NO_KNOWN_OUTAGE row.
CREATE OR REPLACE FUNCTION area_outages(p_token TEXT)
RETURNS TABLE (status TEXT, service_area VARCHAR, outage_id VARCHAR, cause VARCHAR, outage_status VARCHAR,
               started_at TIMESTAMP, estimated_restoration TIMESTAMP, customers_affected INTEGER, summary TEXT,
               my_open_ticket VARCHAR, my_ticket_status VARCHAR, my_ticket_eta TIMESTAMP) AS $$
  SELECT CASE WHEN c.customer_id IS NULL THEN 'SESSION_INVALID' WHEN o.outage_id IS NULL THEN 'NO_KNOWN_OUTAGE' ELSE 'OK' END,
         c.service_area, o.outage_id, o.cause, o.status, o.started_at, o.etr, o.customers_affected,
         CASE WHEN c.customer_id IS NULL THEN NULL
              WHEN o.outage_id IS NULL THEN 'There is no known outage in ' || c.service_area || ' right now.'
              WHEN o.started_at > clock_timestamp() THEN 'Planned outage in ' || c.service_area || ' starting ' || ts_txt(o.started_at)
                     || ', expected back by ' || ts_txt(o.etr) || '.'
              ELSE initcap(lower(o.cause)) || ' outage in ' || c.service_area || ' (' || lower(replace(o.status, '_', ' '))
                     || '), about ' || o.customers_affected || ' customers affected, estimated restoration ' || ts_txt(o.etr) || '.' END,
         t.ticket_id, t.status, t.eta
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN outages o ON o.service_area = c.service_area AND o.status <> 'RESTORED'
    LEFT JOIN LATERAL (SELECT ot.ticket_id, ot.status, ot.eta FROM outage_tickets ot
                        WHERE ot.customer_id = c.customer_id AND ot.status IN ('OPEN','CREW_DISPATCHED','LINKED')
                        ORDER BY ot.created_at DESC LIMIT 1) t ON TRUE
   ORDER BY o.started_at
$$ LANGUAGE sql STABLE;

-- The caller's outage tickets, appointments, reconnect orders and plan changes, newest first.
CREATE OR REPLACE FUNCTION my_service_activity(p_token TEXT)
RETURNS TABLE (status TEXT, kind TEXT, reference VARCHAR, detail TEXT, item_status VARCHAR, scheduled_for TEXT,
               created_at TIMESTAMP) AS $$
  WITH sc AS (SELECT * FROM session_customer(p_token)),
  items AS (
    SELECT 'outage_ticket' AS kind, t.ticket_id AS reference,
           CASE WHEN t.ticket_type = 'LINKED' THEN 'Linked to known outage ' || t.outage_id ELSE 'Crew ticket' END
             || ' (' || lower(replace(t.symptom, '_', ' ')) || ')' AS detail,
           t.status AS item_status, CASE WHEN t.eta IS NOT NULL THEN 'estimate ' || ts_txt(t.eta) END AS scheduled_for, t.created_at
      FROM outage_tickets t JOIN sc ON t.customer_id = sc.customer_id
    UNION ALL
    SELECT 'appointment', a.appointment_id, initcap(lower(replace(a.appointment_type, '_', ' '))), a.status,
           to_char(s.slot_date, 'YYYY-MM-DD') || ' ' || s.time_window, a.created_at
      FROM appointments a JOIN sc ON a.customer_id = sc.customer_id JOIN appointment_slots s ON s.slot_id = a.slot_id
    UNION ALL
    SELECT 'reconnect_order', o.order_id, 'Reconnection of power service', o.status, 'by ' || ts_txt(o.scheduled_by), o.created_at
      FROM service_orders o JOIN sc ON o.customer_id = sc.customer_id
    UNION ALL
    SELECT 'rate_plan_change', coalesce(pc.source_reference, 'PLAN-' || pc.change_id), pc.from_plan || ' to ' || pc.to_plan,
           pc.status, 'effective ' || to_char(pc.effective_date, 'YYYY-MM-DD'), NULL
      FROM plan_changes pc JOIN sc ON pc.customer_id = sc.customer_id)
  SELECT CASE WHEN (SELECT customer_id FROM sc) IS NULL THEN 'SESSION_INVALID'
              WHEN i.reference IS NULL THEN 'NO_ACTIVITY' ELSE 'OK' END,
         i.kind, i.reference::varchar, i.detail, i.item_status::varchar, i.scheduled_for, i.created_at
    FROM (SELECT 1) one LEFT JOIN items i ON (SELECT customer_id FROM sc) IS NOT NULL
   ORDER BY i.created_at DESC NULLS LAST
$$ LANGUAGE sql STABLE;

-- Open slots (tomorrow onward, capacity left) and whether this appointment type is allowed for the caller.
CREATE OR REPLACE FUNCTION appointment_slots_for(p_token TEXT, p_type TEXT)
RETURNS TABLE (status TEXT, appointment_type TEXT, slot_id VARCHAR, slot_date DATE, time_window VARCHAR,
               spots_left INTEGER, allowed TEXT, reason_code TEXT, reason_text TEXT) AS $$
  SELECT CASE WHEN c.customer_id IS NULL THEN 'SESSION_INVALID'
              WHEN norm_target(p_type) NOT IN ('METER_UPGRADE','METER_INSPECTION') THEN 'INVALID_TYPE' ELSE 'OK' END,
         norm_target(p_type), s.slot_id, s.slot_date, s.time_window, s.capacity - s.booked,
         CASE WHEN c.customer_id IS NULL OR s.slot_id IS NULL THEN NULL WHEN e.ok THEN 'yes' ELSE 'no' END,
         CASE WHEN NOT e.ok THEN e.reason_code END, CASE WHEN NOT e.ok THEN e.reason_text END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN customers c ON c.customer_id = sc.customer_id
    LEFT JOIN appointment_slots s ON c.customer_id IS NOT NULL AND norm_target(p_type) IN ('METER_UPGRADE','METER_INSPECTION')
                                 AND s.slot_date > current_date AND s.booked < s.capacity
    LEFT JOIN LATERAL appointment_eval(c.customer_id, p_type, s.slot_id) e ON s.slot_id IS NOT NULL
   ORDER BY s.slot_date, s.time_window
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- TWO-STEP ACTIONS (REPORT_OUTAGE, CHANGE_RATE_PLAN)
-- =====================================================================
-- Guarded write-row: ONE pending_actions row (PROPOSED or BLOCKED) for a verified caller; 0 rows for a bad session
-- or when an identical live, unconfirmed proposal with the same outcome already exists.
CREATE OR REPLACE FUNCTION propose_action_fn(p_token TEXT, p_action TEXT, p_target TEXT)
RETURNS TABLE (customer_id VARCHAR, action_type VARCHAR, target VARCHAR, outcome VARCHAR, reason_code VARCHAR,
               reason_text TEXT, summary TEXT, price NUMERIC, effective_date DATE, outage_id VARCHAR) AS $$
  SELECT sc.customer_id, norm_action(p_action)::varchar, norm_target(p_target)::varchar,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text,
         e.summary, e.price, e.effective_date, e.outage_id::varchar
    FROM session_customer(p_token) sc
    CROSS JOIN LATERAL action_eval(sc.customer_id, p_action, p_target) e
   WHERE sc.customer_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.customer_id = sc.customer_id AND pa.action_type = norm_action(p_action)
                        AND pa.target = norm_target(p_target) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM account_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

-- Readback: the caller's latest proposal for this action + target. A BLOCKED proposal has no proposal_id.
CREATE OR REPLACE FUNCTION propose_action_result(p_token TEXT, p_action TEXT, p_target TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, target VARCHAR, reason_code VARCHAR, reason_text TEXT,
               summary TEXT, price NUMERIC, effective_date DATE, linked_outage_id VARCHAR, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         pa.action_type, pa.target,
         CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (account number and one-time code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing has changed yet. Reply yes within 15 minutes to go ahead.'
              ELSE pa.reason_text END,
         pa.summary, pa.price, pa.effective_date, pa.outage_id,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.expires_at END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT p.* FROM pending_actions p
       WHERE p.customer_id = sc.customer_id AND p.action_type = norm_action(p_action) AND p.target = norm_target(p_target)
       ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm: re-checks EVERY rule and returns the account_events row only when the proposal is
-- the caller's, PROPOSED, unexpired, not yet executed and still allowed. Records the attempt for the readback.
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, customer_id VARCHAR, action_type VARCHAR,
               target VARCHAR, price NUMERIC, effective_date DATE, summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  v_cust TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev account_events;
  e RECORD; v_id BIGINT; v_reference TEXT;
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.customer_id = v_cust;
  IF NOT FOUND THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (v_cust, 'confirm_action', v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal on your account. Nothing was changed.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM account_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_text, reference, summary)
      VALUES (v_cust, 'confirm_action', v_ref, 'ALREADY_DONE', 'This was already done earlier (reference ' || ev.reference || '). Nothing new was changed.',
              ev.reference, ev.summary);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (v_cust, 'confirm_action', v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text, summary)
      VALUES (v_cust, 'confirm_action', v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was changed. I can set it up again.', pa.summary);
    RETURN;
  END IF;
  SELECT * INTO e FROM action_eval(v_cust, pa.action_type, pa.target);
  IF NOT e.ok THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text, summary)
      VALUES (v_cust, 'confirm_action', v_ref, 'BLOCKED', e.reason_code, e.reason_text, pa.summary);
    RETURN;
  END IF;
  v_id := nextval(pg_get_serial_sequence('account_events', 'event_id'));
  v_reference := 'RPL-ACT-' || lpad(v_id::text, 6, '0');
  INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_text, reference, summary)
    VALUES (v_cust, 'confirm_action', v_ref, 'EXECUTED', 'Done.', v_reference, e.summary);
  RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, v_cust::varchar, pa.action_type, pa.target,
                      e.price, e.effective_date, e.summary;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT, effective_date DATE,
               ticket_id VARCHAR, ticket_type VARCHAR, linked_outage_id VARCHAR, estimated_restoration TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ta.outcome, 'NOT_FOUND') END,
         ta.reference,
         CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' WHEN ta.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ta.reason_code END,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (account number and one-time code).'
              WHEN ta.attempt_id IS NULL THEN 'I could not find that proposal on your account. Nothing was changed.'
              ELSE ta.reason_text END,
         ta.summary, ae.effective_date, t.ticket_id, t.ticket_type, t.outage_id, t.eta
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT a.* FROM tool_attempts a
       WHERE a.principal_id = sc.customer_id AND a.tool = 'confirm_action' AND a.ref_key = upper(trim(coalesce(p_proposal, '')))
       ORDER BY a.attempt_id DESC LIMIT 1) ta ON TRUE
    LEFT JOIN account_events ae ON ae.reference = ta.reference
    LEFT JOIN outage_tickets t ON t.source_reference = ta.reference
$$ LANGUAGE sql STABLE;

-- Side effects of an executed action - atomic with the event row. Never an UPDATE from a tool.
-- REPORT_OUTAGE links to a known active outage in the customer's area (no duplicate crew ticket), else opens one.
CREATE OR REPLACE FUNCTION apply_account_event() RETURNS TRIGGER AS $$
DECLARE c customers; o outages; v_no BIGINT; cp rate_plans;
BEGIN
  SELECT * INTO c FROM customers WHERE customer_id = NEW.customer_id;
  IF NEW.action_type = 'REPORT_OUTAGE' THEN
    v_no := nextval(pg_get_serial_sequence('outage_tickets', 'ticket_no'));
    SELECT * INTO o FROM outages x WHERE x.service_area = c.service_area AND x.status IN ('INVESTIGATING','CREW_ASSIGNED','RESTORING')
       AND x.started_at <= clock_timestamp() ORDER BY x.started_at LIMIT 1;
    IF FOUND THEN
      INSERT INTO outage_tickets (ticket_no, ticket_id, customer_id, outage_id, ticket_type, symptom, status, eta, source_reference)
        VALUES (v_no, 'OTK-' || lpad(v_no::text, 6, '0'), NEW.customer_id, o.outage_id, 'LINKED', NEW.target, 'LINKED', o.etr, NEW.reference);
      UPDATE outages SET customers_reported = customers_reported + 1 WHERE outage_id = o.outage_id;
    ELSE
      INSERT INTO outage_tickets (ticket_no, ticket_id, customer_id, outage_id, ticket_type, symptom, status, eta, source_reference)
        VALUES (v_no, 'OTK-' || lpad(v_no::text, 6, '0'), NEW.customer_id, NULL, 'NEW', NEW.target, 'CREW_DISPATCHED',
                clock_timestamp() + INTERVAL '3 hours', NEW.reference);
    END IF;
  ELSIF NEW.action_type = 'CHANGE_RATE_PLAN' THEN
    INSERT INTO plan_changes (customer_id, from_plan, to_plan, effective_date, status, source_reference)
      VALUES (NEW.customer_id, c.plan_code, NEW.target, NEW.effective_date, 'SCHEDULED', NEW.reference);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_account_event AFTER INSERT ON account_events FOR EACH ROW EXECUTE FUNCTION apply_account_event();

-- =====================================================================
-- APPOINTMENTS (single-step guarded write)
-- =====================================================================
CREATE OR REPLACE FUNCTION book_appointment_row(p_token TEXT, p_type TEXT, p_slot TEXT)
RETURNS TABLE (appt_no BIGINT, appointment_id VARCHAR, customer_id VARCHAR, appointment_type VARCHAR, slot_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_cust TEXT; e RECORD; v_no BIGINT; v_id TEXT;
        v_key TEXT := norm_target(p_type) || '|' || upper(trim(coalesce(p_slot, '')));
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NULL THEN RETURN; END IF;
  SELECT * INTO e FROM appointment_eval(v_cust, p_type, p_slot);
  IF NOT e.ok THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (v_cust, 'book_appointment', v_key, 'BLOCKED', e.reason_code, e.reason_text);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('appointments', 'appt_no'));
  v_id := 'APPT-' || lpad(v_no::text, 6, '0');
  INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_text, reference, summary)
    VALUES (v_cust, 'book_appointment', v_key, 'BOOKED', 'Your appointment is booked.', v_id, e.summary);
  RETURN QUERY SELECT v_no, v_id::varchar, v_cust::varchar, norm_target(p_type)::varchar, upper(trim(p_slot))::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION book_appointment_result(p_token TEXT, p_type TEXT, p_slot TEXT)
RETURNS TABLE (outcome TEXT, appointment_id VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ta.outcome, 'BLOCKED') END,
         ta.reference,
         CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE ta.reason_code END,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (account number and one-time code).' ELSE ta.reason_text END,
         ta.summary
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT a.* FROM tool_attempts a
       WHERE a.principal_id = sc.customer_id AND a.tool = 'book_appointment'
         AND a.ref_key = norm_target(p_type) || '|' || upper(trim(coalesce(p_slot, '')))
       ORDER BY a.attempt_id DESC LIMIT 1) ta ON TRUE
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_appointment() RETURNS TRIGGER AS $$
BEGIN
  UPDATE appointment_slots SET booked = booked + 1 WHERE slot_id = NEW.slot_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_appointment AFTER INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION apply_appointment();

-- =====================================================================
-- RECONNECT (single-step guarded write: past-due -> 0 rows + the amount due in the readback)
-- =====================================================================
CREATE OR REPLACE FUNCTION reconnect_row(p_token TEXT)
RETURNS TABLE (order_no BIGINT, order_id VARCHAR, customer_id VARCHAR, order_type VARCHAR, scheduled_by TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cust TEXT; e RECORD; v_no BIGINT; v_id TEXT; v_by TIMESTAMP := (current_date + 1) + TIME '17:00';
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NULL THEN RETURN; END IF;
  SELECT * INTO e FROM reconnect_eval(v_cust);
  IF NOT e.ok THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text, amount)
      VALUES (v_cust, 'request_reconnect', '', 'BLOCKED', e.reason_code, e.reason_text, e.amount_due);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_orders', 'order_no'));
  v_id := 'SO-' || lpad(v_no::text, 6, '0');
  INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_text, reference, summary, amount)
    VALUES (v_cust, 'request_reconnect', '', 'RECONNECT_SCHEDULED',
            'Your reconnection is scheduled. Power will be restored by ' || ts_txt(v_by) || '. Please make sure the main breaker is off until then.',
            v_id, 'Reconnection order ' || v_id || ', power restored by ' || ts_txt(v_by), 0);
  RETURN QUERY SELECT v_no, v_id::varchar, v_cust::varchar, 'RECONNECT'::varchar, v_by;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION reconnect_result(p_token TEXT)
RETURNS TABLE (outcome TEXT, order_id VARCHAR, reason_code VARCHAR, reason_text TEXT, amount_due NUMERIC, scheduled_by TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ta.outcome, 'BLOCKED') END,
         ta.reference,
         CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE ta.reason_code END,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (account number and one-time code).' ELSE ta.reason_text END,
         ta.amount, so.scheduled_by
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT a.* FROM tool_attempts a
       WHERE a.principal_id = sc.customer_id AND a.tool = 'request_reconnect' ORDER BY a.attempt_id DESC LIMIT 1) ta ON TRUE
    LEFT JOIN service_orders so ON so.order_id = ta.reference
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_service_order() RETURNS TRIGGER AS $$
BEGIN
  UPDATE customers SET connection_status = 'RECONNECT_PENDING' WHERE customer_id = NEW.customer_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_service_order AFTER INSERT ON service_orders FOR EACH ROW EXECUTE FUNCTION apply_service_order();

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; one open case per (customer, request_type)
-- =====================================================================
-- Guarded write-row (VOLATILE: records the attempt): the service_cases row only for a verified customer, a known
-- request type and no open case of that type. The table decides the team, the SLA and the parked action.
CREATE OR REPLACE FUNCTION open_case_fn(p_token TEXT, p_type TEXT, p_summary TEXT, p_brief TEXT, p_amount TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, customer_id VARCHAR, request_type VARCHAR, team VARCHAR, summary TEXT,
               agent_brief TEXT, requested_amount NUMERIC, parked_action VARCHAR, parked_ref VARCHAR, sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_cust TEXT; v_type TEXT := norm_request_type(p_type); rt case_routing; v_existing TEXT; v_no BIGINT; v_case TEXT;
        v_amt NUMERIC := parse_amount(p_amount); v_ref TEXT;
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NULL THEN RETURN; END IF;
  SELECT * INTO rt FROM case_routing r WHERE r.request_type = v_type;
  IF NOT FOUND THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code) VALUES (v_cust, 'open_service_case', v_type, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  SELECT s.case_id INTO v_existing FROM service_cases s
   WHERE s.customer_id = v_cust AND s.request_type = v_type AND s.status = 'OPEN' ORDER BY s.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reference) VALUES (v_cust, 'open_service_case', v_type, 'EXISTING', v_existing);
    RETURN;
  END IF;
  IF v_amt IS NOT NULL AND v_amt <= 0 THEN v_amt := NULL; END IF;
  IF rt.parked_action = 'BILL_CREDIT' THEN v_ref := latest_bill(v_cust);
  ELSIF rt.parked_action = 'PAYMENT_PLAN' THEN v_amt := coalesce(v_amt, nullif(past_due_amount(v_cust), 0));
  ELSIF rt.parked_action IS NULL OR rt.parked_action = 'MEDICAL_BASELINE' THEN v_amt := NULL;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'RPL-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reference) VALUES (v_cust, 'open_service_case', v_type, 'OPENED', v_case);
  RETURN QUERY SELECT v_no, v_case::varchar, v_cust::varchar, v_type::varchar, rt.team,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000),
                      left(nullif(trim(coalesce(p_brief, '')), ''), 4000), v_amt, rt.parked_action, v_ref::varchar,
                      clock_timestamp()::timestamp + make_interval(hours => rt.sla_hours);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request_type VARCHAR, team VARCHAR, sla_text VARCHAR, sla_due_at TIMESTAMP,
               reason_text TEXT) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ta.outcome, 'INVALID_TYPE') END,
         ta.reference, rt.request_type, rt.team, rt.sla_text, s.sla_due_at,
         CASE WHEN sc.customer_id IS NULL THEN 'Please verify your identity again (account number and one-time code).'
              WHEN ta.outcome = 'OPENED' AND rt.request_type = 'hazardous_condition'
                THEN 'Your report is with our Emergency Dispatch team. If anyone is in danger, or a line is down or sparking, call 911 now and stay at least 35 feet away.'
              WHEN ta.outcome = 'OPENED' THEN 'Your case is open. A person on our ' || rt.team || ' team will review your request and decide.'
              WHEN ta.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' case, so no new case was opened. Our ' || rt.team || ' team is on it.'
              ELSE 'That is not a request I can open a case for. A person can help with billing disputes and re-bills, payment arrangements, medical-baseline protection and hazardous conditions.' END
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN LATERAL (
      SELECT a.* FROM tool_attempts a
       WHERE a.principal_id = sc.customer_id AND a.tool = 'open_service_case' AND a.ref_key = norm_request_type(p_type)
       ORDER BY a.attempt_id DESC LIMIT 1) ta ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = ta.ref_key AND ta.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = ta.reference
$$ LANGUAGE sql STABLE;

-- The customer's own cases: status and the customer-safe outcome. Never the internal note or the reviewer.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, case_status VARCHAR, opened_at TIMESTAMP,
               reply_due_by TIMESTAMP, requested_amount NUMERIC, outcome_message TEXT, decided_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.customer_id IS NULL THEN 'SESSION_INVALID' WHEN s.case_id IS NULL THEN 'NO_CASES' ELSE 'OK' END,
         s.case_id, rt.label, s.team, s.status, s.created_at, s.sla_due_at, s.requested_amount,
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status = 'OPEN' THEN 'Open - a person on our ' || s.team || ' team will review it and decide.'
              ELSE s.status || ': ' || coalesce(s.customer_message, '') || coalesce(' ' || s.outcome_summary, '') END,
         s.decided_at
    FROM (SELECT * FROM session_customer(p_token)) sc
    LEFT JOIN service_cases s ON s.customer_id = sc.customer_id
    LEFT JOIN case_routing rt ON rt.request_type = s.request_type
   ORDER BY s.created_at DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- REVIEWER LOOP (human-in-the-loop): queue -> case -> decision -> the parked action runs through the guards
-- =====================================================================
-- The most a reviewer may approve, computed here (never by the model or the reviewer).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE s.parked_action
           WHEN 'BILL_CREDIT' THEN greatest(bill_usage_charges(s.parked_ref) + bill_credits(s.parked_ref), 0)
           WHEN 'PAYMENT_PLAN' THEN past_due_amount(s.customer_id) END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts from SQL for the reviewer (minimum necessary).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.parked_action
    WHEN 'BILL_CREDIT' THEN
      'Bill ' || b.bill_id || ' (' || to_char(b.period_start, 'FMMonth YYYY') || '): total ' || usd(bill_total(b.bill_id))
      || ', ' || b.read_type || ' read of ' || kwh_txt(b.kwh) || ' vs ' || coalesce(kwh_txt(b.prior_year_kwh), 'n/a')
      || ' in the same month last year; usage charges (energy + rider) ' || usd(bill_usage_charges(b.bill_id))
      || '; credits already applied ' || usd(-bill_credits(b.bill_id)) || '; meter type ' || c.meter_type
      || '; billing disputes by this customer in the last 12 months: '
      || (SELECT count(*) FROM service_cases x WHERE x.customer_id = s.customer_id AND x.request_type = 'billing_dispute'
             AND x.case_id <> s.case_id AND x.created_at > now() - INTERVAL '12 months') || '.'
    WHEN 'PAYMENT_PLAN' THEN
      'Past-due balance ' || usd(past_due_amount(s.customer_id)) || ' (' || days_past_due(s.customer_id) || ' days past due); '
      || 'total balance ' || usd(balance_due(s.customer_id)) || '; service ' || lower(c.connection_status)
      || '; payment arrangements in the last 12 months: '
      || (SELECT count(*) FROM payment_arrangements p WHERE p.customer_id = s.customer_id) || '.'
    WHEN 'MEDICAL_BASELINE' THEN
      'Medical-baseline protection currently ' || CASE WHEN c.medical_baseline THEN 'enrolled' ELSE 'not enrolled' END
      || '; service ' || lower(c.connection_status) || '.'
    ELSE 'Service area ' || c.service_area || '; service ' || lower(c.connection_status) || '.' END
    FROM service_cases s JOIN customers c ON c.customer_id = s.customer_id
    LEFT JOIN bills b ON b.bill_id = s.parked_ref
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue (OPEN, by SLA). Masked account + first name only.
CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, customer_ref TEXT, customer_first_name VARCHAR,
               age_hours NUMERIC, sla_due_at TIMESTAMP, past_sla TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN r.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'QUEUE_EMPTY' ELSE 'OK' END,
         r.team, s.case_id, rt.label, mask_account(s.customer_id), c.first_name,
         round(extract(epoch FROM clock_timestamp() - s.created_at)::numeric / 3600, 1), s.sla_due_at,
         CASE WHEN s.case_id IS NULL THEN NULL WHEN s.sla_due_at < clock_timestamp() THEN 'yes' ELSE 'no' END,
         s.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) r
    LEFT JOIN service_cases s ON s.team = r.team AND s.status = 'OPEN'
    LEFT JOIN case_routing rt ON rt.request_type = s.request_type
    LEFT JOIN customers c ON c.customer_id = s.customer_id
   ORDER BY s.sla_due_at
$$ LANGUAGE sql STABLE;

-- One case for the reviewer: statement, agent brief, SQL facts, the eligible maximum and the options.
-- Another team's (or an unknown) case -> NOT_FOUND row.
CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, customer_ref TEXT, customer_first_name VARCHAR,
               opened_at TIMESTAMP, sla_due_at TIMESTAMP, customer_statement TEXT, agent_brief TEXT, requested_amount NUMERIC,
               eligible_max_amount NUMERIC, facts TEXT, options TEXT, your_approval_limit NUMERIC) AS $$
  SELECT CASE WHEN r.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, rt.label, s.status, mask_account(s.customer_id), c.first_name, s.created_at, s.sla_due_at,
         s.summary, s.agent_brief, s.requested_amount, case_eligible_max(s.case_id), case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.parked_action = 'BILL_CREDIT' THEN 'APPROVE (bill credit up to ' || usd(case_eligible_max(s.case_id))
                   || '; leave the amount empty to use the requested amount or that maximum), APPROVE with an amended amount, or REJECT. A note of at least 5 characters is required.'
              WHEN s.parked_action = 'PAYMENT_PLAN' THEN 'APPROVE (3 monthly installments, up to the past-due balance '
                   || usd(case_eligible_max(s.case_id)) || '), APPROVE with an amended amount, or REJECT. A note of at least 5 characters is required.'
              ELSE 'APPROVE or REJECT. A note of at least 5 characters is required.' END,
         r.approval_limit
    FROM (SELECT * FROM session_reviewer(p_token)) r
    LEFT JOIN service_cases s ON s.case_id = upper(trim(coalesce(p_case, ''))) AND s.team = r.team
    LEFT JOIN case_routing rt ON rt.request_type = s.request_type
    LEFT JOIN customers c ON c.customer_id = s.customer_id
$$ LANGUAGE sql STABLE;

-- Guard: the review_decisions row only when every rule passes; otherwise 0 rows + the reason in tool_attempts.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (decision_id BIGINT, case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC,
               internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE r RECORD; s service_cases; v_case TEXT := upper(trim(coalesce(p_case, ''))); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_msg TEXT; v_id BIGINT;
BEGIN
  SELECT * INTO r FROM session_reviewer(p_token);
  IF r.reviewer_id IS NULL THEN RETURN; END IF;                  -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM service_cases x WHERE x.case_id = v_case;
  IF NOT FOUND THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'NOT_FOUND', 'There is no case with that id.'); RETURN;
  END IF;
  IF s.team <> r.team THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'NOT_YOUR_TEAM', 'This case is not in your team''s queue, so you cannot decide it.'); RETURN;
  END IF;
  IF s.status <> 'OPEN' THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'ALREADY_DECIDED', 'This case was already decided (' || s.status || '). Nothing was changed.'); RETURN;
  END IF;
  v_dec := CASE upper(trim(coalesce(p_decision, ''))) WHEN 'APPROVE' THEN 'APPROVE' WHEN 'APPROVED' THEN 'APPROVE'
                WHEN 'REJECT' THEN 'REJECT' WHEN 'REJECTED' THEN 'REJECT' END;
  IF v_dec IS NULL THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'INVALID_DECISION', 'The decision must be APPROVE or REJECT.'); RETURN;
  END IF;
  IF length(trim(coalesce(p_note, ''))) < 5 THEN
    INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text)
      VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'NOTE_REQUIRED', 'An internal note of at least 5 characters is required for every decision.'); RETURN;
  END IF;
  IF v_dec = 'APPROVE' AND s.parked_action IN ('BILL_CREDIT','PAYMENT_PLAN') THEN
    v_max := case_eligible_max(v_case);
    v_amt := coalesce(parse_amount(p_amount), s.requested_amount, v_max);
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > coalesce(v_max, 0) THEN
      INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text, amount)
        VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'AMOUNT_INVALID',
                'The amount must be more than $0.00 and at most ' || coalesce(usd(v_max), '$0.00') || ' for this case.', v_amt); RETURN;
    END IF;
    IF r.approval_limit IS NOT NULL AND v_amt > r.approval_limit THEN
      INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_code, reason_text, amount)
        VALUES (r.reviewer_id, 'decide_review_case', v_case, 'BLOCKED', 'OVER_AUTHORITY',
                usd(v_amt) || ' is above your approval limit of ' || usd(r.approval_limit) || '. The case stays open for a senior reviewer.', v_amt); RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(coalesce(p_message, '')), ''),
                    CASE WHEN v_dec = 'APPROVE' THEN 'Your request has been approved.'
                         ELSE 'After review, we could not approve this request.' END);
  v_id := nextval(pg_get_serial_sequence('review_decisions', 'decision_id'));
  INSERT INTO tool_attempts (principal_id, tool, ref_key, outcome, reason_text, reference, amount)
    VALUES (r.reviewer_id, 'decide_review_case', v_case, 'DECIDED', 'Decision recorded.', v_case, v_amt);
  RETURN QUERY SELECT v_id, v_case::varchar, r.reviewer_id, v_dec::varchar, v_amt, trim(p_note), v_msg;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, reason_code VARCHAR, reason_text TEXT, decision VARCHAR, approved_amount NUMERIC,
               case_status VARCHAR, executed TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN r.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN ta.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ta.outcome END,
         upper(trim(coalesce(p_case, '')))::varchar,
         CASE WHEN r.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN ta.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ta.reason_code END,
         CASE WHEN r.reviewer_id IS NULL THEN 'Only verified staff reviewers can decide cases. Please verify with your staff ID and code.'
              WHEN ta.attempt_id IS NULL THEN 'There is no decision attempt for that case in this session.'
              ELSE ta.reason_text END,
         CASE WHEN ta.outcome = 'DECIDED' THEN d.decision END,
         CASE WHEN ta.outcome = 'DECIDED' THEN d.approved_amount END,
         s.status,
         CASE WHEN ta.outcome = 'DECIDED' THEN s.outcome_summary END,
         CASE WHEN ta.outcome = 'DECIDED' THEN s.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) r
    LEFT JOIN LATERAL (
      SELECT a.* FROM tool_attempts a
       WHERE a.principal_id = r.reviewer_id AND a.tool = 'decide_review_case' AND a.ref_key = upper(trim(coalesce(p_case, '')))
       ORDER BY a.attempt_id DESC LIMIT 1) ta ON TRUE
    LEFT JOIN service_cases s ON s.case_id = upper(trim(coalesce(p_case, ''))) AND s.team = r.team
    LEFT JOIN review_decisions d ON d.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Parked actions, each guarded: only for an OPEN case of the right kind and an amount within the SQL maximum.
CREATE OR REPLACE FUNCTION bill_credit_row(p_case TEXT, p_amount NUMERIC)
RETURNS TABLE (bill_id VARCHAR, category VARCHAR, description VARCHAR, amount NUMERIC, source_case_id VARCHAR) AS $$
  SELECT s.parked_ref, 'BILL_CREDIT'::varchar, ('Bill credit - approved review ' || s.case_id)::varchar, -p_amount, s.case_id
    FROM service_cases s
   WHERE s.case_id = p_case AND s.status = 'OPEN' AND s.parked_action = 'BILL_CREDIT' AND s.parked_ref IS NOT NULL
     AND p_amount > 0 AND p_amount <= case_eligible_max(s.case_id)
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION payment_plan_row(p_case TEXT, p_amount NUMERIC)
RETURNS TABLE (arrangement_no BIGINT, arrangement_id VARCHAR, customer_id VARCHAR, case_id VARCHAR, total_amount NUMERIC,
               installments INTEGER, installment_amount NUMERIC, first_due DATE) AS $$
#variable_conflict use_column
DECLARE s service_cases; v_no BIGINT;
BEGIN
  SELECT * INTO s FROM service_cases x WHERE x.case_id = p_case AND x.status = 'OPEN' AND x.parked_action = 'PAYMENT_PLAN';
  IF NOT FOUND OR p_amount IS NULL OR p_amount <= 0 OR p_amount > case_eligible_max(p_case) THEN RETURN; END IF;
  v_no := nextval(pg_get_serial_sequence('payment_arrangements', 'arrangement_no'));
  RETURN QUERY SELECT v_no, ('PA-' || lpad(v_no::text, 6, '0'))::varchar, s.customer_id, s.case_id, p_amount, 3,
                      round(p_amount / 3, 2), (current_date + 14);
END $$ LANGUAGE plpgsql VOLATILE;

-- The decision event: sets the case status, executes the parked action through the guarded rows, writes the audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_sum TEXT; v_rows INT := 0; v_bill TEXT;
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id FOR UPDATE;
  IF NEW.decision = 'APPROVE' THEN
    IF s.parked_action = 'BILL_CREDIT' THEN
      INSERT INTO bill_lines (bill_id, category, description, amount, source_case_id)
        SELECT * FROM bill_credit_row(s.case_id, NEW.approved_amount);
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_sum := CASE WHEN v_rows = 1 THEN 'A credit of ' || usd(NEW.approved_amount) || ' was applied to bill ' || s.parked_ref || '.'
                    ELSE 'The credit could not be applied; a specialist will follow up.' END;
    ELSIF s.parked_action = 'PAYMENT_PLAN' THEN
      INSERT INTO payment_arrangements (arrangement_no, arrangement_id, customer_id, case_id, total_amount, installments, installment_amount, first_due)
        SELECT * FROM payment_plan_row(s.case_id, NEW.approved_amount);
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_sum := CASE WHEN v_rows = 1 THEN 'A payment arrangement for ' || usd(NEW.approved_amount) || ' in 3 monthly installments of '
                                         || usd(round(NEW.approved_amount / 3, 2)) || ', the first due ' || to_char(current_date + 14, 'FMMonth FMDD') || '.'
                    ELSE 'The arrangement could not be set up; a specialist will follow up.' END;
    ELSIF s.parked_action = 'MEDICAL_BASELINE' THEN
      UPDATE customers SET medical_baseline = TRUE WHERE customer_id = s.customer_id;
      v_sum := 'Medical-baseline protection is now on your account.';
    ELSE
      v_sum := 'Approved.';
    END IF;
    UPDATE service_cases SET status = 'APPROVED', customer_message = NEW.customer_message, outcome_summary = v_sum,
           decided_at = NEW.decided_at WHERE case_id = s.case_id;
  ELSE
    v_sum := 'Not approved. Nothing was changed on your account.';
    UPDATE service_cases SET status = 'REJECTED', customer_message = NEW.customer_message, outcome_summary = v_sum,
           decided_at = NEW.decided_at WHERE case_id = s.case_id;
  END IF;
  INSERT INTO agent_audit (event, case_id, actor, detail)
    VALUES ('CASE_DECIDED', s.case_id, NEW.reviewer_id, NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || ': ' || v_sum);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- =====================================================================
-- EMAIL - authorised only for a reference the session may see
-- =====================================================================
-- customer: own executed action (RPL-ACT-), appointment (APPT-), reconnect order (SO-), decided case (RPL-CASE-)
-- reviewer: a decided case in their team (the decision confirmation)
CREATE OR REPLACE FUNCTION email_ref(p_token TEXT, p_ref TEXT)
RETURNS TABLE (principal_id VARCHAR, first_name VARCHAR, reference VARCHAR, summary TEXT) AS $$
#variable_conflict use_column
DECLARE v_ref TEXT := upper(trim(coalesce(p_ref, ''))); v_cust TEXT; r RECORD;
BEGIN
  SELECT sc.customer_id INTO v_cust FROM session_customer(p_token) sc;
  IF v_cust IS NOT NULL THEN
    RETURN QUERY
      SELECT c.customer_id, c.first_name, x.ref::varchar, x.summary FROM customers c
      JOIN (SELECT ae.reference AS ref, ae.summary FROM account_events ae WHERE ae.customer_id = v_cust AND ae.reference = v_ref
            UNION ALL
            SELECT a.appointment_id, initcap(lower(replace(a.appointment_type, '_', ' '))) || ' on ' || to_char(s.slot_date, 'FMMonth FMDD')
                   || ', ' || s.time_window FROM appointments a JOIN appointment_slots s ON s.slot_id = a.slot_id
             WHERE a.customer_id = v_cust AND a.appointment_id = v_ref
            UNION ALL
            SELECT o.order_id, 'Reconnection of your power service, by ' || ts_txt(o.scheduled_by) FROM service_orders o
             WHERE o.customer_id = v_cust AND o.order_id = v_ref
            UNION ALL
            SELECT sc2.case_id, 'Your request ' || sc2.case_id || ' was ' || lower(sc2.status) || '. ' || coalesce(sc2.customer_message, '')
                   || coalesce(' ' || sc2.outcome_summary, '') FROM service_cases sc2
             WHERE sc2.customer_id = v_cust AND sc2.case_id = v_ref AND sc2.status <> 'OPEN') x ON TRUE
      WHERE c.customer_id = v_cust LIMIT 1;
    RETURN;
  END IF;
  SELECT * INTO r FROM session_reviewer(p_token);
  IF r.reviewer_id IS NOT NULL THEN
    RETURN QUERY
      SELECT r.reviewer_id, split_part(r.display_name, ' ', 1)::varchar, s.case_id,
             'Decision recorded for case ' || s.case_id || ': ' || s.status || '. ' || coalesce(s.outcome_summary, '')
        FROM service_cases s WHERE s.case_id = v_ref AND s.team = r.team AND s.status <> 'OPEN';
  END IF;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_ref TEXT)
RETURNS TABLE (principal_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT e.principal_id, e.reference, 'Ridgeline Power & Light confirmation ' || e.reference FROM email_ref(p_token, p_ref) e
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_payload(p_token TEXT, p_ref TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.reference IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.reference IS NOT NULL THEN NULL
              WHEN (SELECT customer_id FROM session_customer(p_token)) IS NULL AND (SELECT reviewer_id FROM session_reviewer(p_token)) IS NULL
                THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN e.reference IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN (SELECT customer_id FROM session_customer(p_token)) IS NULL AND (SELECT reviewer_id FROM session_reviewer(p_token)) IS NULL
                THEN 'Please verify your identity again.'
              ELSE 'There is no completed item with that reference that I can confirm, so no email was sent.' END,
         e.reference,
         CASE WHEN e.reference IS NOT NULL THEN 'Ridgeline Power & Light confirmation ' || e.reference
              ELSE 'Ridgeline Power & Light confirmation - not sent' END,
         CASE WHEN e.reference IS NOT NULL THEN
           'Hi ' || e.first_name || ',' || chr(10) || chr(10)
           || 'This confirms the following, handled with Sage, the Ridgeline Power & Light assistant:' || chr(10)
           || e.summary || chr(10) || 'Reference: ' || e.reference || chr(10)
           || 'Sent: ' || to_char(clock_timestamp(), 'YYYY-MM-DD HH24:MI') || chr(10) || chr(10)
           || 'If you smell gas, see a downed line or anyone is in danger, call 911.' || chr(10)
           || 'Thank you for being a Ridgeline Power & Light customer.'
           ELSE 'No confirmation email was sent for reference ' || upper(trim(coalesce(p_ref, ''))) || '.' END
    FROM (SELECT 1) one LEFT JOIN email_ref(p_token, p_ref) e ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- AGENT REFERENCE READS - the only SQL the A2A agents' tools run (SELECT * FROM ref_<topic>(CAST(?lookup AS text))).
-- SELECT-only, STABLE, no identity argument. p_term is the one value the model may supply:
--   empty / NULL -> the whole guide;  otherwise one or more words separated by , or ; - a row matches when a word
--   equals its section (spaces = underscores) or appears in its term or meaning (plain substring, no wildcards).
--   Unknown words -> 0 rows (never an error).
-- =====================================================================
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION ref_bill_glossary(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM bill_glossary g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['CATEGORY','LINE_ITEM','TOU_PERIOD','COLUMN','WEATHER','READ_TYPE'], g.section::text),
            g.entry_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_outage_triage(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT o.section::text AS sec, o.term::text AS trm, o.meaning::text AS mng, o.entry_id AS ord
            FROM outage_triage_guide o
          UNION ALL                                 -- who acts on a hazard has ONE source of truth: case_routing
          SELECT 'ROUTING', cr.label::text, 'open_hazard_case goes to ' || cr.team || ': ' || cr.sla_text, 1000
            FROM case_routing cr WHERE cr.request_type = 'hazardous_condition') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CATEGORY','HAZARD_SIGN','CONNECTION','NEXT_PATH','ROUTING','SAFETY_LINE','RULE'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

-- exact per-kWh price for the reference rows: 0.0250 -> $0.025 (usd() rounds to cents)
CREATE OR REPLACE FUNCTION rate_txt(n NUMERIC) RETURNS TEXT AS $$
  SELECT '$' || rtrim(to_char(n, 'FM990.0000'), '0') $$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION ref_rate_plans(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT 'PLAN' AS sec, (rp.plan_code || ' - ' || rp.plan_name)::text AS trm,
                 rp.description || ' Base charge ' || usd(rp.base_charge) || ' a month; '
                   || CASE WHEN rp.energy_rate IS NOT NULL THEN rate_txt(rp.energy_rate) || '/kWh'
                           ELSE 'on-peak ' || rate_txt(rp.on_peak_rate) || '/kWh, off-peak ' || rate_txt(rp.off_peak_rate) || '/kWh' END
                   || CASE WHEN rp.export_credit_rate > 0 THEN ', solar export credit ' || rate_txt(rp.export_credit_rate) || '/kWh'
                           ELSE '' END
                   || '; needs: ' || CASE WHEN rp.needs_solar THEN 'smart meter + solar on file'
                                          WHEN rp.needs_smart_meter THEN 'smart meter' ELSE 'none' END || '.' AS mng,
                 0 AS ord
            FROM rate_plans rp                      -- the plan list has ONE source of truth: rate_plans
          UNION ALL
          SELECT n.section::text, n.term::text, n.meaning::text, n.entry_id
            FROM rate_plan_notes n) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['PLAN','TOU_PERIOD','COLUMN','REASON_CODE','ELIGIBILITY','HABIT'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
