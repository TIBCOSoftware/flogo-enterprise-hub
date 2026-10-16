-- Arcwell Components - Semiconductor Orders & RMA (GOVERNED) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: semiconductor_governed
-- Load:  createdb semiconductor_governed  &&  psql -d semiconductor_governed -f database.sql
--
-- =====================================================================
-- Fictional US electronic-components distributor "Arcwell Components", assistant "Arc".
-- The rules live HERE, not in any prompt:
--   * session_buyer() / session_reviewer()   identity: every tool is scoped by a session token; buyer and reviewer
--                                            tokens are not interchangeable (role checked)
--   * verify_*_fn()                          account + e-mail + one-time code (staff id + code) -> session;
--                                            5 failures / 15 min -> LOCKED
--   * catalog_* / my_*()                     scoped reads - only the caller's account; another account's id -> NOT_FOUND
--   * unit_price_for()                       the price-break price for a quantity (never the model)
--   * order_eval() / rma_eval()              MOQ, stock, credit hold + limit, EOL last-time-buy; shipped, quantity, warranty
--   * propose_*_fn() / confirm_action_fn()   two-step: PROPOSED/BLOCKED with 15-minute expiry; confirm re-checks
--   * trg_account_event                      the sales order / RMA (+ its Quality Engineering case) is created in the DB
--   * expedite_eval() + trg_expedite_event   pull-in within stock / lead time; beyond it -> factory_expedite case
--   * open_case_row()                        human-owned requests routed by case_routing (team + SLA)
--   * decide_case_row() + trg_review_decision  the reviewer loop: role/team/authority/amount checks, then the parked
--                                            action (credit memo / LTB order / factory expedite / credit limit) runs
--                                            through guarded rows
--   * email_log_row()                        email only for the caller's order / RMA / expedite / decided case
--   * ref_part_selection() / ref_defect_taxonomy() / ref_pcn_guide()  the A2A agents' ONLY database access:
--                                            read-only reference tables (part-selection guide + recommended
--                                            replacements, defect taxonomy + who decides, change-notice guide) with no
--                                            customer, staff or case data; one optional lookup term, never an identity
-- Hidden from buyers: e-mail addresses, otp_code, internal_note, agent_brief, reviewer identity, approval limits.
-- Money: USD. All demo dates are relative to CURRENT_DATE (seed_data.sql).
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

DROP TABLE IF EXISTS email_log, agent_audit, credit_changes, credit_memos, decide_attempts, review_decisions,
  case_requests, service_cases, subscribe_attempts, pcn_subscriptions, expedite_events, expedite_attempts, rmas,
  confirm_attempts, account_events, pending_actions, order_lines, sales_orders, verify_attempts, sessions, reviewers,
  buyers, accounts, case_routing, pcn_notices, cross_references, inventory, price_breaks, parts, order_policy,
  part_selection_guide, defect_taxonomy, pcn_change_guide CASCADE;

-- ---------------------------------------------------------------------
-- Commercial policy and catalog
-- ---------------------------------------------------------------------
CREATE TABLE order_policy (                      -- exactly one row; edit here to change the thresholds
  id                 INTEGER PRIMARY KEY CHECK (id = 1),
  handling_days      INTEGER NOT NULL,           -- in-stock orders ship this many business days after the order
  ltb_review_value   NUMERIC(12,2) NOT NULL,     -- an EOL last-time-buy worth more than this needs Sales & Pricing
  rma_sla_safety     INTEGER NOT NULL,           -- business days for a safety-relevant RMA case
  rma_sla_standard   INTEGER NOT NULL,
  max_credit_limit   NUMERIC(12,2) NOT NULL      -- the most anyone may request in a credit review
);

CREATE TABLE parts (
  part_number      VARCHAR(16) PRIMARY KEY,      -- AW-MF-4012 (Arcwell house scheme)
  family           VARCHAR(24) NOT NULL,         -- MOSFET, Schottky diode, Gate driver, ...
  description      VARCHAR(120) NOT NULL,
  key_specs        VARCHAR(200) NOT NULL,
  package          VARCHAR(16) NOT NULL,         -- generic JEDEC-style outline
  aec_grade        VARCHAR(10),                  -- AEC-Q100 / AEC-Q101 / AEC-Q200, NULL = commercial / industrial
  rohs             BOOLEAN NOT NULL DEFAULT TRUE,
  lifecycle        VARCHAR(10) NOT NULL CHECK (lifecycle IN ('ACTIVE','NRND','EOL','OBSOLETE')),
  moq              INTEGER NOT NULL,             -- minimum order quantity
  warranty_months  INTEGER NOT NULL DEFAULT 12,
  ltb_date         DATE,                         -- EOL parts: last day an order is accepted
  replacement_part VARCHAR(16),
  datasheet_url    VARCHAR(120) NOT NULL
);

CREATE TABLE price_breaks (
  part_number  VARCHAR(16) NOT NULL REFERENCES parts,
  min_qty      INTEGER NOT NULL,
  unit_price   NUMERIC(10,4) NOT NULL CHECK (unit_price > 0),
  PRIMARY KEY (part_number, min_qty)
);

CREATE TABLE inventory (
  part_number       VARCHAR(16) PRIMARY KEY REFERENCES parts,
  warehouse         VARCHAR(40) NOT NULL,
  qty_available     INTEGER NOT NULL CHECK (qty_available >= 0),
  lead_time_weeks   INTEGER NOT NULL,            -- factory lead time for new stock
  next_receipt_date DATE,
  next_receipt_qty  INTEGER
);

CREATE TABLE cross_references (
  part_number  VARCHAR(16) NOT NULL REFERENCES parts,
  alt_part     VARCHAR(16) NOT NULL REFERENCES parts,
  relation     VARCHAR(24) NOT NULL CHECK (relation IN ('DROP_IN_REPLACEMENT','PIN_COMPATIBLE','HIGHER_RATED','FUNCTIONAL_EQUIVALENT')),
  notes        VARCHAR(200) NOT NULL,
  PRIMARY KEY (part_number, alt_part)
);

CREATE TABLE pcn_notices (
  pcn_id           VARCHAR(16) PRIMARY KEY,      -- PCN-2026-0007
  part_number      VARCHAR(16) NOT NULL REFERENCES parts,
  notice_type      VARCHAR(4) NOT NULL CHECK (notice_type IN ('PCN','EOL')),
  title            VARCHAR(120) NOT NULL,
  description      TEXT NOT NULL,
  published_date   DATE NOT NULL,
  effective_date   DATE NOT NULL,
  ltb_date         DATE,
  replacement_part VARCHAR(16)
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type      VARCHAR(30) PRIMARY KEY,
  label             VARCHAR(40) NOT NULL,        -- buyer-facing name
  team              VARCHAR(40) NOT NULL,
  sla_business_days INTEGER NOT NULL,
  sla_text          VARCHAR(160) NOT NULL,
  buyer_openable    BOOLEAN NOT NULL DEFAULT TRUE -- rma_disposition is opened only by confirm_action
);

-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO customer, staff, case, session or contact data, ever.
CREATE TABLE part_selection_guide (               -- part_finder_agent: abbreviations, columns, packages, ranking
  entry_id    SERIAL PRIMARY KEY,                 -- (the REPLACEMENT rows come from parts + cross_references)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('ABBREVIATION', 'COLUMN', 'PACKAGE', 'RANKING', 'EXCLUDE',
                                                      'NOTE_LINE')),
  term        VARCHAR(60) NOT NULL,               -- RATING_BELOW
  meaning     VARCHAR(300) NOT NULL,              -- a voltage or current rating is below ...
  UNIQUE (section, term)
);

CREATE TABLE defect_taxonomy (                    -- rma_triage_agent: defect types, safety signs, evidence per type
  entry_id    SERIAL PRIMARY KEY,                 -- (the ROUTING row - who decides - comes from case_routing)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('DEFECT_TYPE', 'SAFETY_SIGN', 'EVIDENCE', 'RULE')),
  term        VARCHAR(60) NOT NULL,               -- ELECTRICAL_FAILURE
  meaning     VARCHAR(300) NOT NULL,              -- the part is dead, shorted or open ...
  UNIQUE (section, term)
);

CREATE TABLE pcn_change_guide (                   -- pcn_impact_agent: notice types, change types + buyer checks, terms
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('NOTICE_TYPE', 'CHANGE_TYPE', 'TERM', 'LINE_STATUS', 'RULE')),
  term        VARCHAR(60) NOT NULL,               -- assembly site transfer
  meaning     VARCHAR(300) NOT NULL,              -- the part is packaged and tested in a different factory ...
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- People: customer accounts + their buyers, and Arcwell reviewers (staff)
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
  account_id     VARCHAR(10) PRIMARY KEY,        -- AC-10021
  company        VARCHAR(60) NOT NULL,
  industry       VARCHAR(40) NOT NULL,
  city           VARCHAR(40) NOT NULL,
  state          VARCHAR(2) NOT NULL,
  payment_terms  VARCHAR(10) NOT NULL,
  credit_limit   NUMERIC(12,2) NOT NULL,
  open_balance   NUMERIC(12,2) NOT NULL,         -- unpaid invoices + open orders
  credit_hold    BOOLEAN NOT NULL DEFAULT FALSE,
  hold_reason    VARCHAR(160),
  customer_since DATE NOT NULL
);

CREATE TABLE buyers (
  buyer_id     VARCHAR(10) PRIMARY KEY,          -- B-2101
  account_id   VARCHAR(10) NOT NULL REFERENCES accounts,
  first_name   VARCHAR(40) NOT NULL,
  last_name    VARCHAR(40) NOT NULL,
  email        VARCHAR(100) NOT NULL UNIQUE,     -- HIDDEN (login factor; confirmations go to the EMAIL_TO demo inbox)
  otp_code     VARCHAR(6) NOT NULL,              -- HIDDEN: demo stand-in for the e-mailed one-time code
  job_title    VARCHAR(40) NOT NULL,
  active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- ACS-5101 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,          -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN
  approval_limit  NUMERIC(12,2),                 -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL CHECK (role IN ('BUYER','REVIEWER')),
  buyer_id       VARCHAR(10) REFERENCES buyers,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'BUYER' AND buyer_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND buyer_id IS NULL))
);

-- Every verify call (throttle + readback).
CREATE TABLE verify_attempts (
  attempt_id   BIGSERIAL PRIMARY KEY,
  role         VARCHAR(10) NOT NULL,
  identifier   VARCHAR(40) NOT NULL,             -- normalised account id / staff id
  outcome      VARCHAR(14) NOT NULL CHECK (outcome IN ('VERIFIED','VERIFY_FAILED','LOCKED')),
  buyer_id     VARCHAR(10),                      -- which buyer verified (VERIFIED only)
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_verify_attempts ON verify_attempts (role, identifier, created_at);

-- ---------------------------------------------------------------------
-- Orders and lines
-- ---------------------------------------------------------------------
CREATE TABLE sales_orders (
  order_number  VARCHAR(16) PRIMARY KEY,         -- SO-2026-0014
  account_id    VARCHAR(10) NOT NULL REFERENCES accounts,
  buyer_id      VARCHAR(10) REFERENCES buyers,
  po_number     VARCHAR(30) NOT NULL,
  order_date    DATE NOT NULL,
  source        VARCHAR(6) NOT NULL DEFAULT 'SEED' CHECK (source IN ('SEED','CHAT','REVIEW'))
);
CREATE INDEX ix_orders_account ON sales_orders (account_id);

CREATE TABLE order_lines (
  line_id        BIGSERIAL PRIMARY KEY,
  order_number   VARCHAR(16) NOT NULL REFERENCES sales_orders,
  line_no        INTEGER NOT NULL,
  part_number    VARCHAR(16) NOT NULL REFERENCES parts,
  quantity       INTEGER NOT NULL CHECK (quantity > 0),
  unit_price     NUMERIC(10,4) NOT NULL,
  requested_date DATE,
  promised_date  DATE NOT NULL,                  -- ship date Arcwell committed to
  shipped_qty    INTEGER NOT NULL DEFAULT 0,
  shipped_date   DATE,
  UNIQUE (order_number, line_no)
);

-- ---------------------------------------------------------------------
-- Two-step actions: proposals -> confirmed events (the only path that creates an order or an RMA)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'ARC-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  buyer_id       VARCHAR(10) NOT NULL REFERENCES buyers,
  action_type    VARCHAR(12) NOT NULL CHECK (action_type IN ('PLACE_ORDER','OPEN_RMA')),
  target_key     TEXT NOT NULL,                  -- normalised request, shared by the write-row and the readback
  part_number    VARCHAR(16),
  quantity       INTEGER,
  unit_price     NUMERIC(10,4),
  extended       NUMERIC(14,2),
  po_number      VARCHAR(30),
  order_number   VARCHAR(16),                    -- OPEN_RMA: the order the parts came from
  line_id        BIGINT,
  failure_description TEXT,
  defect_type    VARCHAR(20),
  safety_relevant BOOLEAN,
  triage_brief   TEXT,
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  ship_date      DATE,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_account ON pending_actions (account_id, action_type, target_key, created_at);

CREATE TABLE account_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(16) NOT NULL UNIQUE,    -- SO-2026-0101 / RMA-2026-0101
  proposal_id    TEXT UNIQUE REFERENCES pending_actions,   -- NULL when a reviewer's approval placed the order
  case_id        VARCHAR(16),                    -- the last_time_buy case that placed it (reviewer path)
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  buyer_id       VARCHAR(10) REFERENCES buyers,
  action_type    VARCHAR(12) NOT NULL,
  part_number    VARCHAR(16) NOT NULL,
  quantity       INTEGER NOT NULL,
  unit_price     NUMERIC(10,4) NOT NULL,
  extended       NUMERIC(14,2) NOT NULL,
  po_number      VARCHAR(30),
  order_number   VARCHAR(16),
  line_id        BIGINT,
  failure_description TEXT,
  defect_type    VARCHAR(20),
  safety_relevant BOOLEAN,
  triage_brief   TEXT,
  ship_date      DATE,
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  proposal_ref   TEXT NOT NULL,
  outcome        VARCHAR(14) NOT NULL,
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  reference      VARCHAR(16),
  case_id        VARCHAR(16),
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE rmas (
  rma_id         VARCHAR(16) PRIMARY KEY,        -- RMA-2026-0101
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  order_number   VARCHAR(16) NOT NULL REFERENCES sales_orders,
  line_id        BIGINT NOT NULL REFERENCES order_lines,
  part_number    VARCHAR(16) NOT NULL REFERENCES parts,
  quantity       INTEGER NOT NULL CHECK (quantity > 0),
  unit_price     NUMERIC(10,4) NOT NULL,
  defect_type    VARCHAR(20) NOT NULL,
  safety_relevant BOOLEAN NOT NULL DEFAULT FALSE,
  description    TEXT NOT NULL,                  -- the buyer's own words
  status         VARCHAR(12) NOT NULL CHECK (status IN ('UNDER_REVIEW','APPROVED','REJECTED')),
  credit_amount  NUMERIC(12,2),
  opened_date    DATE NOT NULL,
  decided_at     TIMESTAMP,
  source         VARCHAR(6) NOT NULL DEFAULT 'SEED' CHECK (source IN ('SEED','CHAT'))
);

-- ---------------------------------------------------------------------
-- Expedites, change-notice alerts
-- ---------------------------------------------------------------------
CREATE TABLE expedite_attempts (                 -- every request_expedite call (readback)
  attempt_id     SERIAL PRIMARY KEY,
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  line_ref       VARCHAR(40) NOT NULL,
  outcome        VARCHAR(10) NOT NULL,           -- EXPEDITED / BLOCKED
  reason_code    VARCHAR(28),
  reason_text    TEXT,
  reference      VARCHAR(16),
  old_date       DATE,
  new_date       DATE,
  earliest_date  DATE,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE expedite_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(16) NOT NULL UNIQUE,    -- EXP-000101
  line_id        BIGINT NOT NULL REFERENCES order_lines,
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  old_date       DATE NOT NULL,
  new_date       DATE NOT NULL,
  source         VARCHAR(8) NOT NULL CHECK (source IN ('BUYER','REVIEWER')),
  case_id        VARCHAR(16),
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pcn_subscriptions (
  subscription_id SERIAL PRIMARY KEY,
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  buyer_id       VARCHAR(10) NOT NULL REFERENCES buyers,
  part_number    VARCHAR(16) NOT NULL REFERENCES parts,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (account_id, part_number)
);

CREATE TABLE subscribe_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  account_id     VARCHAR(10) NOT NULL REFERENCES accounts,
  part_ref       VARCHAR(40) NOT NULL,
  outcome        VARCHAR(20) NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, credit memos, credit changes, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,  -- ARC-CASE-000101
  account_id       VARCHAR(10) NOT NULL REFERENCES accounts,
  buyer_id         VARCHAR(10) REFERENCES buyers,
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary          TEXT NOT NULL,                -- the buyer's request, in their words (neutral)
  reference_id     VARCHAR(40),                  -- RMA / line / part / proposal the case is about
  part_number      VARCHAR(16),
  quantity         INTEGER,
  unit_price       NUMERIC(10,4),
  po_number        VARCHAR(30),
  line_id          BIGINT,
  requested_date   DATE,
  requested_amount NUMERIC(14,2),                -- credit USD / order quantity (units) / new credit limit USD
  parked_action    VARCHAR(40),                  -- RMA_CREDIT:<rma> / LTB_ORDER:<case> / EXPEDITE:<line> / CREDIT_LIMIT:<account>
  agent_brief      TEXT,                         -- AI-prepared neutral brief for the reviewer (never shown to the buyer)
  priority         VARCHAR(8) NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('NORMAL','SAFETY')),
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                         -- buyer-safe outcome text, set by the decision
  approved_amount  NUMERIC(14,2),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_account ON service_cases (account_id, request_type, status);

CREATE TABLE case_requests (                     -- every open_service_case call (readback)
  request_id    SERIAL PRIMARY KEY,
  account_id    VARCHAR(10) NOT NULL REFERENCES accounts,
  request_type  VARCHAR(40) NOT NULL,
  reference_id  VARCHAR(40),
  outcome       VARCHAR(16) NOT NULL,
  reason_code   VARCHAR(24),
  reason_text   TEXT,
  case_id       VARCHAR(16),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Insert-only decision events. trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE REFERENCES service_cases (case_id),   -- one decision per case
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(14,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),
  customer_message TEXT NOT NULL,
  decided_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE decide_attempts (                   -- every decide call by a verified reviewer (readback)
  attempt_id    SERIAL PRIMARY KEY,
  reviewer_id   VARCHAR(10) NOT NULL REFERENCES reviewers,
  case_ref      VARCHAR(40) NOT NULL,
  outcome       VARCHAR(10) NOT NULL,            -- APPROVED / REJECTED / BLOCKED
  reason_code   VARCHAR(24),
  reason_text   TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE credit_memos (
  memo_id      BIGSERIAL PRIMARY KEY,
  reference    VARCHAR(16) NOT NULL UNIQUE,      -- CM-000101
  rma_id       VARCHAR(16) NOT NULL UNIQUE REFERENCES rmas,
  account_id   VARCHAR(10) NOT NULL REFERENCES accounts,
  amount       NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  case_id      VARCHAR(16),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE credit_changes (
  change_id     BIGSERIAL PRIMARY KEY,
  reference     VARCHAR(16) NOT NULL UNIQUE,     -- CRL-000101
  account_id    VARCHAR(10) NOT NULL REFERENCES accounts,
  old_limit     NUMERIC(12,2) NOT NULL,
  new_limit     NUMERIC(12,2) NOT NULL CHECK (new_limit > 0),
  hold_released BOOLEAN NOT NULL,
  case_id       VARCHAR(16),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE agent_audit (
  audit_id    BIGSERIAL PRIMARY KEY,
  event_type  VARCHAR(20) NOT NULL,              -- ORDER_PLACED / RMA_OPENED / EXPEDITED / CASE_OPENED / CASE_DECIDED / ...
  actor       VARCHAR(16) NOT NULL,              -- buyer id, reviewer id, or the case that acted
  subject_id  VARCHAR(40) NOT NULL,              -- reference / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id    SERIAL PRIMARY KEY,
  account_id  VARCHAR(10) NOT NULL REFERENCES accounts,
  reference   VARCHAR(16) NOT NULL,
  subject     TEXT NOT NULL,
  logged_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

DROP SEQUENCE IF EXISTS so_seq;
DROP SEQUENCE IF EXISTS rma_seq;
CREATE SEQUENCE so_seq START 101;                -- orders placed in chat: SO-<year>-0101, ... (reset in seed_data.sql)
CREATE SEQUENCE rma_seq START 101;               -- RMAs opened in chat:  RMA-<year>-0101, ...

-- =====================================================================
-- HELPERS
-- =====================================================================
-- $45 / $4,050.00 (locale-independent separators); money always 2 decimals
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE '$' || to_char(round(n, 2), 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
-- unit prices: $0.81 / $0.1250 (2-4 decimals)
CREATE OR REPLACE FUNCTION usd_unit(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL
              WHEN round(n, 2) = n THEN '$' || to_char(n, 'FM999,990.00')
              ELSE '$' || rtrim(to_char(n, 'FM999,990.0000'), '0') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION qty_txt(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE to_char(n, 'FM999,999,999,990') END
$$ LANGUAGE sql IMMUTABLE;
-- dates go out as text so every client shows 2026-10-13, never an RFC3339 timestamp
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;

-- AC-10021 / ac10021 / AC 10021 / 10021 -> AC-10021
CREATE OR REPLACE FUNCTION norm_account_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{5}$' THEN 'AC-' || x
              WHEN x ~ '^AC[0-9]{5}$' THEN 'AC-' || substr(x, 3)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ACS-5101 / acs5101 / 5101 -> ACS-5101
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'ACS-' || x
              WHEN x ~ '^ACS[0-9]{4}$' THEN 'ACS-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- AW-MF-4012 / aw mf 4012 / awmf4012 -> AW-MF-4012
CREATE OR REPLACE FUNCTION norm_part(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^AW[A-Z]{2}[0-9]{4}$' THEN 'AW-' || substr(x, 3, 2) || '-' || substr(x, 5)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ids typed by people or the model: ' so-2026-0014 ' -> 'SO-2026-0014'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- '5,000' / '5000 pcs' / '5k' -> '5000'; anything else -> upper text (-> INVALID_QUANTITY)
CREATE OR REPLACE FUNCTION norm_qty(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{1,9}$' THEN ltrim(x, '0')
              WHEN x ~ '^[0-9]{1,6}K$' THEN (substr(x, 1, length(x) - 1)::bigint * 1000)::text
              ELSE left(x, 20) END
    FROM (SELECT upper(regexp_replace(regexp_replace(trim(coalesce(p, '')), '\s*(pcs|pieces|piece|units|unit|ea|parts)\.?$', '', 'i'),
                                      '[,\s]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION qty_or_null(p TEXT) RETURNS INTEGER AS $$
  SELECT CASE WHEN norm_qty(p) ~ '^[0-9]{1,9}$' AND norm_qty(p)::bigint BETWEEN 1 AND 100000000 THEN norm_qty(p)::int END
$$ LANGUAGE sql IMMUTABLE;
-- '2026-10-20' (also 2026/10/20) -> date; anything else -> NULL
CREATE OR REPLACE FUNCTION date_or_null(p TEXT) RETURNS DATE AS $$
BEGIN
  IF trim(coalesce(p, '')) ~ '^\d{4}[-/]\d{1,2}[-/]\d{1,2}' THEN
    RETURN to_date(substring(trim(p) FROM '^\d{4}[-/]\d{1,2}[-/]\d{1,2}'), 'YYYY-MM-DD');
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN NULL;
END $$ LANGUAGE plpgsql IMMUTABLE;
-- '$90,000' / '90000' / '90k' -> '90000'; else upper text
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^-?[0-9]+(\.[0-9]+)?$' THEN trim_scale(x::numeric)::text
              WHEN x ~ '^[0-9]+(\.[0-9]+)?K$' THEN trim_scale(substr(x, 1, length(x) - 1)::numeric * 1000)::text
              ELSE left(x, 20) END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p, '')), '[$,\s]|USD', '', 'gi')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION yes_no(b BOOLEAN) RETURNS TEXT AS $$ SELECT CASE WHEN b THEN 'yes' WHEN NOT b THEN 'no' END $$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION add_business_days(p_from DATE, p_days INTEGER) RETURNS DATE AS $$
DECLARE t DATE := p_from; n INTEGER := 0;
BEGIN
  WHILE n < p_days LOOP
    t := t + 1;
    IF extract(isodow FROM t) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN t;
END $$ LANGUAGE plpgsql IMMUTABLE;
CREATE OR REPLACE FUNCTION add_business_days_ts(p_from TIMESTAMP, p_days INTEGER) RETURNS TIMESTAMP AS $$
  SELECT add_business_days(p_from::date, p_days) + p_from::time
$$ LANGUAGE sql IMMUTABLE;

-- The price-break price for a quantity: the highest tier whose min_qty <= quantity. NULL = unknown part / bad qty.
CREATE OR REPLACE FUNCTION unit_price_for(p_part TEXT, p_qty INTEGER) RETURNS NUMERIC AS $$
  SELECT pb.unit_price FROM price_breaks pb
   WHERE pb.part_number = p_part AND p_qty IS NOT NULL AND pb.min_qty <= p_qty
   ORDER BY pb.min_qty DESC LIMIT 1
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION break_applied(p_part TEXT, p_qty INTEGER) RETURNS INTEGER AS $$
  SELECT pb.min_qty FROM price_breaks pb
   WHERE pb.part_number = p_part AND p_qty IS NOT NULL AND pb.min_qty <= p_qty
   ORDER BY pb.min_qty DESC LIMIT 1
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION price_table(p_part TEXT) RETURNS TEXT AS $$
  SELECT string_agg(qty_txt(pb.min_qty) || '+: ' || usd_unit(pb.unit_price), ' | ' ORDER BY pb.min_qty)
    FROM price_breaks pb WHERE pb.part_number = p_part
$$ LANGUAGE sql STABLE;
-- in-stock orders ship handling_days business days from today
CREATE OR REPLACE FUNCTION stock_ship_date() RETURNS DATE AS $$
  SELECT add_business_days(current_date, (SELECT handling_days FROM order_policy))
$$ LANGUAGE sql STABLE;
-- Earliest date Arcwell can ship p_qty of a part without a factory expedite.
CREATE OR REPLACE FUNCTION earliest_ship_date(p_part TEXT, p_qty INTEGER) RETURNS DATE AS $$
  SELECT CASE WHEN i.qty_available >= p_qty THEN stock_ship_date()
              WHEN i.next_receipt_date IS NOT NULL AND i.qty_available + coalesce(i.next_receipt_qty, 0) >= p_qty
                THEN greatest(add_business_days(i.next_receipt_date, 1), stock_ship_date())
              ELSE current_date + i.lead_time_weeks * 7 END
    FROM inventory i WHERE i.part_number = p_part
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;

-- =====================================================================
-- IDENTITY (buyers and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the buyer + account when the token is a valid BUYER token, else NULLs -> SESSION_INVALID.
CREATE OR REPLACE FUNCTION session_buyer(p_token TEXT)
RETURNS TABLE (buyer_id VARCHAR, account_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT b.buyer_id, b.account_id
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'BUYER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN buyers b ON b.buyer_id = s.buyer_id AND b.active;
END $$ LANGUAGE plpgsql STABLE;

-- Always exactly one row: the reviewer when the token is a valid REVIEWER token of an active reviewer.
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN reviewers r ON r.reviewer_id = s.reviewer_id AND r.active;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row for verify_buyer: records the attempt (throttle per account) and returns the sessions row ONLY
-- for a matching account + buyer e-mail + one-time code while the account is not locked (5 failures in 15 minutes).
CREATE OR REPLACE FUNCTION verify_buyer_fn(p_account TEXT, p_email TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, buyer_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_account_id(p_account); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'BUYER' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('BUYER', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT b.buyer_id INTO v_match FROM buyers b
   WHERE b.account_id = v_id AND lower(b.email) = lower(trim(coalesce(p_email, ''))) AND b.otp_code = trim(coalesce(p_code, ''))
     AND b.active;
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('BUYER', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome, buyer_id) VALUES ('BUYER', v_id, 'VERIFIED', v_match);
  RETURN QUERY SELECT 'BUYER'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_buyer_result(p_account TEXT, p_email TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, first_name VARCHAR, company VARCHAR, expires_at TEXT, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.first_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.company END,
         CASE WHEN va.outcome = 'VERIFIED' THEN to_char(se.expires_at, 'YYYY-MM-DD HH24:MI') END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'You are verified. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For your security, verification for this account is paused for 15 minutes. Please try again later.'
              ELSE 'That account number, e-mail and one-time code do not match our records. Please check them and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome, a.buyer_id FROM verify_attempts a WHERE a.role = 'BUYER' AND a.identifier = norm_account_id(p_account)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, b.first_name, ac.company, s.expires_at
                         FROM buyers b JOIN accounts ac ON ac.account_id = b.account_id
                         JOIN sessions s ON s.buyer_id = b.buyer_id AND s.role = 'BUYER' AND s.expires_at > clock_timestamp()
                        WHERE b.buyer_id = va.buyer_id AND b.account_id = norm_account_id(p_account)
                          AND lower(b.email) = lower(trim(coalesce(p_email, ''))) AND b.otp_code = trim(coalesce(p_code, ''))
                        ORDER BY s.created_at DESC LIMIT 1) se ON TRUE
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION verify_reviewer_fn(p_staff TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, reviewer_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_staff_id(p_staff); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'REVIEWER' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('REVIEWER', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT r.reviewer_id INTO v_match FROM reviewers r
   WHERE r.reviewer_id = v_id AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active;
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('REVIEWER', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('REVIEWER', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'REVIEWER'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_reviewer_result(p_staff TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, role TEXT, display_name VARCHAR, team VARCHAR, expires_at TEXT, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'REVIEWER' END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.display_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.team END,
         CASE WHEN va.outcome = 'VERIFIED' THEN to_char(se.expires_at, 'YYYY-MM-DD HH24:MI') END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'Reviewer verified. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. Reviewer verification is paused for 15 minutes.'
              ELSE 'That staff ID and code do not match our records.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'REVIEWER' AND a.identifier = norm_staff_id(p_staff)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, r.display_name, r.team, s.expires_at
                         FROM reviewers r JOIN sessions s ON s.reviewer_id = r.reviewer_id AND s.role = 'REVIEWER'
                                                         AND s.expires_at > clock_timestamp()
                        WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, ''))
                        ORDER BY s.created_at DESC LIMIT 1) se ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- SCOPED READS (buyer) - every function starts FROM session_buyer(token)
-- =====================================================================
CREATE OR REPLACE FUNCTION my_account(p_token TEXT)
RETURNS TABLE (status TEXT, account_id VARCHAR, company VARCHAR, buyer_name TEXT, job_title VARCHAR, industry VARCHAR,
               location TEXT, payment_terms VARCHAR, credit_limit NUMERIC, open_balance NUMERIC, available_credit NUMERIC,
               credit_status TEXT, customer_since TEXT, open_order_lines BIGINT, pcn_alerts TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         a.account_id, a.company, b.first_name || ' ' || b.last_name, b.job_title, a.industry, a.city || ', ' || a.state,
         a.payment_terms, a.credit_limit, a.open_balance, greatest(a.credit_limit - a.open_balance, 0),
         CASE WHEN a.account_id IS NULL THEN NULL
              WHEN a.credit_hold THEN 'ON CREDIT HOLD: ' || coalesce(a.hold_reason, 'contact our Credit team')
              ELSE 'Good standing' END,
         d(a.customer_since),
         (SELECT count(*) FROM order_lines l JOIN sales_orders o USING (order_number)
           WHERE o.account_id = a.account_id AND l.shipped_qty < l.quantity),
         (SELECT string_agg(ps.part_number, ', ' ORDER BY ps.part_number) FROM pcn_subscriptions ps WHERE ps.account_id = a.account_id)
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN accounts a ON a.account_id = sb.account_id
    LEFT JOIN buyers b ON b.buyer_id = sb.buyer_id
$$ LANGUAGE sql STABLE;

-- Keyword search over part number, family, description, specs and package. Every word must match (spaces and
-- punctuation ignored: '650V' matches '650 V'); empty query lists the whole catalog.
CREATE OR REPLACE FUNCTION catalog_search(p_token TEXT, p_query TEXT)
RETURNS TABLE (status TEXT, part_number VARCHAR, family VARCHAR, description VARCHAR, key_specs VARCHAR, package VARCHAR,
               aec_grade TEXT, lifecycle VARCHAR, ltb_date TEXT, qty_available INTEGER, lead_time_weeks INTEGER, moq INTEGER,
               price_from TEXT) AS $$
  WITH w AS (SELECT array_remove(array_agg(lower(regexp_replace(t, '[^A-Za-z0-9]', '', 'g'))), '') AS words
               FROM regexp_split_to_table(trim(coalesce(p_query, '')), '[\s,;/]+') t),
       hits AS (SELECT p.*, i.qty_available, i.lead_time_weeks
                  FROM parts p JOIN inventory i ON i.part_number = p.part_number, w
                 WHERE coalesce(cardinality(w.words), 0) = 0
                    OR NOT EXISTS (SELECT 1 FROM unnest(w.words) x
                                    WHERE position(x IN lower(regexp_replace(p.part_number || p.family || p.description || p.key_specs
                                                   || p.package || coalesce(p.aec_grade, '') || p.lifecycle, '[^A-Za-z0-9]', '', 'g'))) = 0))
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN h.part_number IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         h.part_number, h.family, h.description, h.key_specs, h.package, coalesce(h.aec_grade, 'commercial/industrial'),
         h.lifecycle, d(h.ltb_date), h.qty_available, h.lead_time_weeks, h.moq,
         CASE WHEN h.part_number IS NOT NULL THEN usd_unit((SELECT min(pb.unit_price) FROM price_breaks pb WHERE pb.part_number = h.part_number))
                                                  || ' at volume' END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN hits h ON sb.buyer_id IS NOT NULL
   ORDER BY h.family, h.part_number
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION part_details(p_token TEXT, p_part TEXT)
RETURNS TABLE (status TEXT, part_number VARCHAR, family VARCHAR, description VARCHAR, key_specs VARCHAR, package VARCHAR,
               aec_grade TEXT, rohs TEXT, lifecycle VARCHAR, lifecycle_note TEXT, ltb_date TEXT, replacement_part VARCHAR,
               moq INTEGER, warranty_months INTEGER, price_breaks TEXT, qty_available INTEGER, lead_time_weeks INTEGER,
               next_receipt TEXT, open_notices BIGINT, datasheet_url VARCHAR) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN p.part_number IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         p.part_number, p.family, p.description, p.key_specs, p.package,
         CASE WHEN p.part_number IS NOT NULL THEN coalesce(p.aec_grade, 'commercial/industrial') END,
         yes_no(p.rohs), p.lifecycle,
         CASE p.lifecycle WHEN 'ACTIVE' THEN 'Active - recommended for new designs.'
              WHEN 'NRND' THEN 'Not recommended for new designs; still orderable.'
              WHEN 'EOL' THEN CASE WHEN p.ltb_date >= current_date
                                   THEN 'End of life. Last-time-buy orders are accepted until ' || d(p.ltb_date) || '.'
                                   ELSE 'End of life. The last-time-buy date (' || d(p.ltb_date) || ') has passed; no new orders.' END
                              || coalesce(' Replacement: ' || p.replacement_part || '.', '')
              WHEN 'OBSOLETE' THEN 'Obsolete - no longer orderable.' || coalesce(' Replacement: ' || p.replacement_part || '.', '') END,
         d(p.ltb_date), p.replacement_part, p.moq, p.warranty_months, price_table(p.part_number),
         i.qty_available, i.lead_time_weeks,
         CASE WHEN i.next_receipt_date IS NOT NULL THEN qty_txt(i.next_receipt_qty) || ' pcs due ' || d(i.next_receipt_date) END,
         (SELECT count(*) FROM pcn_notices n WHERE n.part_number = p.part_number AND n.effective_date >= current_date - 30),
         p.datasheet_url
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN parts p ON p.part_number = norm_part(p_part) AND sb.buyer_id IS NOT NULL
    LEFT JOIN inventory i ON i.part_number = p.part_number
$$ LANGUAGE sql STABLE;

-- The price for a quantity comes from the price-break table, here and in order_eval - never from the model.
CREATE OR REPLACE FUNCTION price_and_stock(p_token TEXT, p_part TEXT, p_qty TEXT)
RETURNS TABLE (status TEXT, part_number VARCHAR, quantity INTEGER, unit_price NUMERIC, price_break TEXT, extended_price NUMERIC,
               next_break TEXT, moq INTEGER, meets_moq TEXT, qty_available INTEGER, in_stock_for_quantity TEXT,
               ship_date_if_ordered_today TEXT, lead_time_weeks INTEGER, next_receipt TEXT, lifecycle VARCHAR, ltb_date TEXT,
               note TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN p.part_number IS NULL THEN 'NOT_FOUND'
              WHEN qty_or_null(p_qty) IS NULL THEN 'INVALID_QUANTITY' ELSE 'OK' END,
         p.part_number, qty_or_null(p_qty),
         unit_price_for(p.part_number, qty_or_null(p_qty)),
         CASE WHEN break_applied(p.part_number, qty_or_null(p_qty)) IS NOT NULL
              THEN qty_txt(break_applied(p.part_number, qty_or_null(p_qty))) || '+ tier' END,
         round(unit_price_for(p.part_number, qty_or_null(p_qty)) * qty_or_null(p_qty), 2),
         (SELECT qty_txt(pb.min_qty) || '+ at ' || usd_unit(pb.unit_price) FROM price_breaks pb
           WHERE pb.part_number = p.part_number AND pb.min_qty > coalesce(qty_or_null(p_qty), 0) ORDER BY pb.min_qty LIMIT 1),
         p.moq, CASE WHEN qty_or_null(p_qty) IS NOT NULL THEN yes_no(qty_or_null(p_qty) >= p.moq) END,
         i.qty_available, CASE WHEN qty_or_null(p_qty) IS NOT NULL THEN yes_no(i.qty_available >= qty_or_null(p_qty)) END,
         CASE WHEN qty_or_null(p_qty) IS NOT NULL AND i.qty_available >= qty_or_null(p_qty) THEN d(stock_ship_date()) END,
         i.lead_time_weeks,
         CASE WHEN i.next_receipt_date IS NOT NULL THEN qty_txt(i.next_receipt_qty) || ' pcs due ' || d(i.next_receipt_date) END,
         p.lifecycle, d(p.ltb_date),
         CASE WHEN p.part_number IS NULL THEN 'I could not find that part number in the Arcwell catalog.'
              WHEN qty_or_null(p_qty) IS NULL THEN 'Please give the quantity as a whole number of pieces.'
              WHEN p.lifecycle = 'OBSOLETE' THEN 'This part is obsolete and cannot be ordered.'
              WHEN p.lifecycle = 'EOL' AND p.ltb_date < current_date THEN 'This part is end of life and its last-time-buy date has passed; it cannot be ordered.'
              WHEN qty_or_null(p_qty) < p.moq THEN 'Below the minimum order quantity of ' || qty_txt(p.moq) || '.'
              WHEN i.qty_available < qty_or_null(p_qty) THEN 'Only ' || qty_txt(i.qty_available) || ' in stock; factory lead time is '
                   || i.lead_time_weeks || ' weeks.'
              ELSE 'Price and availability as of today; an order re-checks everything.' END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN parts p ON p.part_number = norm_part(p_part) AND sb.buyer_id IS NOT NULL
    LEFT JOIN inventory i ON i.part_number = p.part_number
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION cross_refs(p_token TEXT, p_part TEXT)
RETURNS TABLE (status TEXT, part_number VARCHAR, alt_part VARCHAR, relation VARCHAR, notes VARCHAR, alt_description VARCHAR,
               alt_package VARCHAR, alt_lifecycle VARCHAR, alt_qty_available INTEGER, alt_price_from TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN p.part_number IS NULL THEN 'NOT_FOUND'
              WHEN x.alt_part IS NULL THEN 'NONE' ELSE 'OK' END,
         p.part_number, x.alt_part, x.relation, x.notes, a.description, a.package, a.lifecycle, i.qty_available,
         CASE WHEN x.alt_part IS NOT NULL THEN usd_unit((SELECT min(pb.unit_price) FROM price_breaks pb WHERE pb.part_number = x.alt_part)) || ' at volume' END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN parts p ON p.part_number = norm_part(p_part) AND sb.buyer_id IS NOT NULL
    LEFT JOIN cross_references x ON x.part_number = p.part_number
    LEFT JOIN parts a ON a.part_number = x.alt_part
    LEFT JOIN inventory i ON i.part_number = x.alt_part
   ORDER BY x.relation, x.alt_part
$$ LANGUAGE sql STABLE;

-- Change notices for one part, or (empty part) for every part on the account's open lines or alert subscriptions.
CREATE OR REPLACE FUNCTION lifecycle_notices(p_token TEXT, p_part TEXT)
RETURNS TABLE (status TEXT, pcn_id VARCHAR, part_number VARCHAR, notice_type VARCHAR, title VARCHAR, description TEXT,
               published_date TEXT, effective_date TEXT, ltb_date TEXT, replacement_part VARCHAR, my_open_lines TEXT,
               subscribed TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN n.pcn_id IS NULL THEN 'NONE' ELSE 'OK' END,
         n.pcn_id, n.part_number, n.notice_type, n.title, n.description, d(n.published_date), d(n.effective_date),
         d(n.ltb_date), n.replacement_part,
         CASE WHEN n.pcn_id IS NOT NULL THEN
           coalesce((SELECT string_agg(qty_txt(l.quantity - l.shipped_qty) || ' pcs promised ' || d(l.promised_date), '; ' ORDER BY l.promised_date)
                       FROM order_lines l JOIN sales_orders o USING (order_number)
                      WHERE o.account_id = sb.account_id AND l.part_number = n.part_number AND l.shipped_qty < l.quantity), 'none') END,
         CASE WHEN n.pcn_id IS NOT NULL THEN yes_no(EXISTS (SELECT 1 FROM pcn_subscriptions ps WHERE ps.account_id = sb.account_id
                                                            AND ps.part_number = n.part_number)) END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN pcn_notices n ON sb.buyer_id IS NOT NULL AND (
           (norm_part(p_part) <> '' AND n.part_number = norm_part(p_part))
        OR (norm_part(p_part) = '' AND (n.part_number IN (SELECT l.part_number FROM order_lines l JOIN sales_orders o USING (order_number)
                                                          WHERE o.account_id = sb.account_id AND l.shipped_qty < l.quantity)
                                     OR n.part_number IN (SELECT ps.part_number FROM pcn_subscriptions ps WHERE ps.account_id = sb.account_id))))
   ORDER BY n.published_date DESC
$$ LANGUAGE sql STABLE;

-- One row per order line of the caller's account. line_ref (SO-2026-0014/2) is what request_expedite takes.
CREATE OR REPLACE FUNCTION my_orders(p_token TEXT)
RETURNS TABLE (status TEXT, order_number VARCHAR, po_number VARCHAR, order_date TEXT, line_ref TEXT, part_number VARCHAR,
               description VARCHAR, quantity INTEGER, unit_price NUMERIC, extended_price NUMERIC, requested_date TEXT,
               promised_date TEXT, line_status TEXT, shipped_qty INTEGER, shipped_date TEXT, warranty_until TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN o.order_number IS NULL THEN 'NONE' ELSE 'OK' END,
         o.order_number, o.po_number, d(o.order_date), o.order_number || '/' || l.line_no, l.part_number, p.description,
         l.quantity, l.unit_price, round(l.quantity * l.unit_price, 2), d(l.requested_date), d(l.promised_date),
         CASE WHEN l.line_id IS NULL THEN NULL WHEN l.shipped_qty >= l.quantity THEN 'SHIPPED'
              WHEN l.shipped_qty > 0 THEN 'PARTIALLY_SHIPPED' ELSE 'OPEN' END,
         l.shipped_qty, d(l.shipped_date),
         CASE WHEN l.shipped_date IS NOT NULL THEN d((l.shipped_date + make_interval(months => p.warranty_months))::date) END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN sales_orders o ON o.account_id = sb.account_id
    LEFT JOIN order_lines l ON l.order_number = o.order_number
    LEFT JOIN parts p ON p.part_number = l.part_number
   ORDER BY o.order_date DESC, o.order_number DESC, l.line_no
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_rmas(p_token TEXT)
RETURNS TABLE (status TEXT, rma_id VARCHAR, order_number VARCHAR, part_number VARCHAR, quantity INTEGER, defect_type VARCHAR,
               rma_status VARCHAR, opened_date TEXT, credit_memo TEXT, case_id VARCHAR, case_status VARCHAR,
               customer_message TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN r.rma_id IS NULL THEN 'NONE' ELSE 'OK' END,
         r.rma_id, r.order_number, r.part_number, r.quantity, r.defect_type, r.status, d(r.opened_date),
         (SELECT cm.reference || ' for ' || usd(cm.amount) FROM credit_memos cm WHERE cm.rma_id = r.rma_id),
         sc.case_id, sc.status,
         CASE WHEN sc.status = 'OPEN' THEN 'Open - our Quality Engineering team will decide the disposition.' ELSE sc.customer_message END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN rmas r ON r.account_id = sb.account_id
    LEFT JOIN service_cases sc ON sc.parked_action = 'RMA_CREDIT:' || r.rma_id
   ORDER BY r.opened_date DESC, r.rma_id DESC
$$ LANGUAGE sql STABLE;

-- What the case asks for / what was approved, in words (the unit depends on the case type).
CREATE OR REPLACE FUNCTION case_amount_text(p_case TEXT, p_amount NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN p_amount IS NULL THEN NULL
              WHEN s.request_type = 'rma_disposition' THEN usd(p_amount) || ' credit'
              WHEN s.request_type = 'last_time_buy' THEN qty_txt(p_amount) || ' pcs of ' || s.part_number
                   || ' (' || usd(p_amount * s.unit_price) || ')'
              WHEN s.request_type = 'credit_review' THEN usd(p_amount) || ' credit limit'
              ELSE NULL END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION case_requested_text(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.request_type
           WHEN 'rma_disposition' THEN 'up to ' || usd(s.requested_amount) || ' credit for ' || qty_txt(s.quantity) || ' pcs of ' || s.part_number
           WHEN 'last_time_buy' THEN qty_txt(s.quantity) || ' pcs of ' || s.part_number || ' at ' || usd_unit(s.unit_price)
                || ' (' || usd(s.quantity * s.unit_price) || ')'
           WHEN 'factory_expedite' THEN 'ship ' || coalesce(s.part_number, '') || ' line ' || coalesce(s.reference_id, '') || ' by ' || d(s.requested_date)
           WHEN 'credit_review' THEN 'credit limit ' || usd(s.requested_amount) || ' (hold release if on hold)'
           WHEN 'special_pricing' THEN coalesce('pricing on ' || s.part_number, 'special pricing')
           ELSE NULL END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The account's own cases: status + the buyer-safe outcome. Never the internal note, brief or reviewer.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, about VARCHAR, team VARCHAR, case_status VARCHAR,
               opened_on TEXT, reply_due TEXT, requested TEXT, outcome TEXT, decided_on TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN s.case_id IS NULL THEN 'NONE' ELSE 'OK' END,
         s.case_id, r.label, s.reference_id, r.team, s.status, d(s.created_at::date), d(s.sla_due_at::date),
         case_requested_text(s.case_id),
         CASE WHEN s.status = 'APPROVED' THEN 'Approved' || coalesce(' - ' || case_amount_text(s.case_id, s.approved_amount), '')
              WHEN s.status = 'REJECTED' THEN 'Not approved' END,
         d(s.decided_at::date),
         CASE WHEN s.status = 'OPEN' THEN 'Open - a person on our ' || r.team || ' team will decide.' ELSE s.customer_message END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN service_cases s ON s.account_id = sb.account_id
    LEFT JOIN case_routing r ON r.request_type = s.request_type
   ORDER BY s.created_at DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- RULES for the two-step actions
-- =====================================================================
-- Order rules, in this order: part, quantity, PO, lifecycle / last-time-buy, MOQ, stock, credit hold, credit limit,
-- large last-time-buy (Sales & Pricing). The price is the price-break row for the quantity.
CREATE OR REPLACE FUNCTION order_eval(p_account TEXT, p_part TEXT, p_qty TEXT, p_po TEXT, p_ltb_approved BOOLEAN DEFAULT FALSE)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, part_number VARCHAR, quantity INTEGER, unit_price NUMERIC,
               extended NUMERIC, po_number VARCHAR, ship_date DATE, summary TEXT) AS $$
#variable_conflict use_column
DECLARE a accounts; p parts; i inventory; pol order_policy; v_qty INTEGER := qty_or_null(p_qty);
        v_po TEXT := left(trim(coalesce(p_po, '')), 30); v_price NUMERIC; v_ext NUMERIC; v_break INTEGER; v_ship DATE;
BEGIN
  SELECT * INTO a FROM accounts x WHERE x.account_id = p_account;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again.', NULL::varchar, NULL::int, NULL::numeric,
      NULL::numeric, NULL::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  SELECT * INTO pol FROM order_policy;
  SELECT * INTO p FROM parts x WHERE x.part_number = norm_part(p_part);
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'PART_NOT_FOUND', 'I could not find part ' || norm_part(p_part) || ' in the Arcwell catalog, so nothing can be ordered.',
      NULL::varchar, v_qty, NULL::numeric, NULL::numeric, NULL::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  SELECT * INTO i FROM inventory x WHERE x.part_number = p.part_number;
  IF v_qty IS NULL THEN
    RETURN QUERY SELECT FALSE, 'INVALID_QUANTITY', 'Please give the quantity as a whole number of pieces (for example 5000).',
      p.part_number, NULL::int, NULL::numeric, NULL::numeric, NULL::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF v_po = '' THEN
    RETURN QUERY SELECT FALSE, 'PO_REQUIRED', 'Every Arcwell order needs your purchase order (PO) number. Please give the PO number for this order.',
      p.part_number, v_qty, NULL::numeric, NULL::numeric, NULL::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF p.lifecycle = 'OBSOLETE' THEN
    RETURN QUERY SELECT FALSE, 'PART_OBSOLETE', p.part_number || ' is obsolete and can no longer be ordered.'
      || coalesce(' The recommended replacement is ' || p.replacement_part || '.', ''),
      p.part_number, v_qty, NULL::numeric, NULL::numeric, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF p.lifecycle = 'EOL' AND p.ltb_date < current_date THEN
    RETURN QUERY SELECT FALSE, 'PAST_LAST_TIME_BUY', p.part_number || ' is end of life and its last-time-buy date was ' || d(p.ltb_date)
      || ', so it can no longer be ordered.' || coalesce(' The recommended replacement is ' || p.replacement_part || '.', ''),
      p.part_number, v_qty, NULL::numeric, NULL::numeric, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF v_qty < p.moq THEN
    RETURN QUERY SELECT FALSE, 'BELOW_MOQ', 'The minimum order quantity for ' || p.part_number || ' is ' || qty_txt(p.moq) || ' pieces.',
      p.part_number, v_qty, NULL::numeric, NULL::numeric, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  v_price := unit_price_for(p.part_number, v_qty);
  v_break := break_applied(p.part_number, v_qty);
  v_ext := round(v_price * v_qty, 2);
  IF i.qty_available < v_qty THEN
    RETURN QUERY SELECT FALSE, 'INSUFFICIENT_STOCK', 'We have ' || qty_txt(i.qty_available) || ' pieces of ' || p.part_number
      || ' in stock, so ' || qty_txt(v_qty) || ' cannot ship from stock. You can order up to ' || qty_txt(i.qty_available)
      || ' now; the factory lead time for more is ' || i.lead_time_weeks || ' weeks'
      || coalesce(' (next receipt: ' || qty_txt(i.next_receipt_qty) || ' pcs due ' || d(i.next_receipt_date) || ')', '') || '.',
      p.part_number, v_qty, v_price, v_ext, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF a.credit_hold THEN
    RETURN QUERY SELECT FALSE, 'CREDIT_HOLD', 'Your account is on credit hold, so new orders cannot be placed right now. Our Credit team can review it - I can open a credit review request for you.',
      p.part_number, v_qty, v_price, v_ext, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF a.open_balance + v_ext > a.credit_limit THEN
    RETURN QUERY SELECT FALSE, 'OVER_CREDIT_LIMIT', 'This order (' || usd(v_ext) || ') is more than your available credit of '
      || usd(greatest(a.credit_limit - a.open_balance, 0)) || '. You can order less, or I can open a credit review request for our Credit team.',
      p.part_number, v_qty, v_price, v_ext, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  IF p.lifecycle = 'EOL' AND v_ext > pol.ltb_review_value AND NOT coalesce(p_ltb_approved, FALSE) THEN
    RETURN QUERY SELECT FALSE, 'LARGE_LAST_TIME_BUY', 'This is a last-time-buy of an end-of-life part worth ' || usd(v_ext)
      || ', which is more than ' || usd(pol.ltb_review_value) || ', so our Sales & Pricing team must approve it. I can open a last-time-buy request with these details (part, quantity, price and PO).',
      p.part_number, v_qty, v_price, v_ext, v_po::varchar, NULL::date, NULL::text; RETURN;
  END IF;
  v_ship := stock_ship_date();
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, p.part_number, v_qty, v_price, v_ext, v_po::varchar, v_ship,
    'Order ' || qty_txt(v_qty) || ' pcs of ' || p.part_number || ' (' || p.description || ') at ' || usd_unit(v_price)
    || ' each (' || qty_txt(v_break) || '+ price break) = ' || usd(v_ext) || ' on PO ' || v_po
    || ', shipping from the Arcwell DC on ' || d(v_ship) || '.'
    || CASE WHEN p.lifecycle = 'EOL' THEN ' This is a last-time-buy of an end-of-life part: it is non-cancellable and non-returnable.'
            WHEN p.lifecycle = 'NRND' THEN ' Note: this part is not recommended for new designs.' ELSE '' END;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION order_key(p_part TEXT, p_qty TEXT, p_po TEXT) RETURNS TEXT AS $$
  SELECT norm_part(p_part) || '|' || norm_qty(p_qty) || '|' || upper(left(trim(coalesce(p_po, '')), 30))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_defect(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('ELECTRICALFAILURE','ELECTRICAL','SHORT','OPEN','FAILEDSHORT','DEAD') THEN 'ELECTRICAL_FAILURE'
              WHEN x IN ('PARAMETRICDRIFT','PARAMETRIC','OUTOFSPEC','DRIFT') THEN 'PARAMETRIC_DRIFT'
              WHEN x IN ('MECHANICALDAMAGE','MECHANICAL','DAMAGE','CRACKED','BENTLEADS') THEN 'MECHANICAL_DAMAGE'
              WHEN x IN ('SOLDERABILITY','SOLDER','WETTING') THEN 'SOLDERABILITY'
              WHEN x IN ('WRONGPART','WRONGPARTSHIPPED','MISLABELED','MISLABELLED') THEN 'WRONG_PART'
              ELSE 'OTHER' END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_yes(p TEXT) RETURNS BOOLEAN AS $$
  SELECT upper(trim(coalesce(p, ''))) IN ('YES','Y','TRUE','1','SAFETY','SAFETYRELEVANT','SAFETY-RELEVANT')
$$ LANGUAGE sql IMMUTABLE;

-- RMA rules: the buyer's own order line of that part, shipped, quantity <= shipped minus quantities already on
-- open / approved RMAs, inside the part's warranty.
CREATE OR REPLACE FUNCTION rma_eval(p_account TEXT, p_order TEXT, p_part TEXT, p_qty TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, order_number VARCHAR, line_id BIGINT, part_number VARCHAR,
               quantity INTEGER, unit_price NUMERIC, extended NUMERIC, shipped_date DATE, warranty_until DATE) AS $$
#variable_conflict use_column
DECLARE l order_lines; p parts; v_qty INTEGER := qty_or_null(p_qty); v_open INTEGER; v_until DATE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM accounts x WHERE x.account_id = p_account) THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again.', NULL::varchar, NULL::bigint, NULL::varchar,
      NULL::int, NULL::numeric, NULL::numeric, NULL::date, NULL::date; RETURN;
  END IF;
  SELECT x.* INTO l FROM order_lines x JOIN sales_orders o ON o.order_number = x.order_number
   WHERE o.order_number = norm_ref(p_order) AND o.account_id = p_account AND x.part_number = norm_part(p_part)
   ORDER BY x.shipped_qty DESC, x.line_no LIMIT 1;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_FOUND', 'I could not find ' || norm_part(p_part) || ' on order ' || norm_ref(p_order)
      || ' for your account, so no return can be opened for it.',
      NULL::varchar, NULL::bigint, NULL::varchar, v_qty, NULL::numeric, NULL::numeric, NULL::date, NULL::date; RETURN;
  END IF;
  SELECT * INTO p FROM parts x WHERE x.part_number = l.part_number;
  IF l.shipped_qty = 0 OR l.shipped_date IS NULL THEN
    RETURN QUERY SELECT FALSE, 'NOT_SHIPPED', 'That line has not shipped yet, so there is nothing to return. If you no longer need it, a person can help with changes to the order.',
      l.order_number, l.line_id, l.part_number, v_qty, l.unit_price, NULL::numeric, NULL::date, NULL::date; RETURN;
  END IF;
  IF v_qty IS NULL THEN
    RETURN QUERY SELECT FALSE, 'INVALID_QUANTITY', 'Please give the number of pieces to return as a whole number.',
      l.order_number, l.line_id, l.part_number, NULL::int, l.unit_price, NULL::numeric, l.shipped_date, NULL::date; RETURN;
  END IF;
  SELECT coalesce(sum(r.quantity), 0) INTO v_open FROM rmas r WHERE r.line_id = l.line_id AND r.status IN ('UNDER_REVIEW','APPROVED');
  IF v_qty > l.shipped_qty - v_open THEN
    RETURN QUERY SELECT FALSE, 'QTY_EXCEEDS_SHIPPED', 'We shipped ' || qty_txt(l.shipped_qty) || ' pieces on that line'
      || CASE WHEN v_open > 0 THEN ' and ' || qty_txt(v_open) || ' are already on a return' ELSE '' END
      || ', so at most ' || qty_txt(greatest(l.shipped_qty - v_open, 0)) || ' can be returned.',
      l.order_number, l.line_id, l.part_number, v_qty, l.unit_price, NULL::numeric, l.shipped_date, NULL::date; RETURN;
  END IF;
  v_until := (l.shipped_date + make_interval(months => p.warranty_months))::date;
  IF v_until < current_date THEN
    RETURN QUERY SELECT FALSE, 'OUT_OF_WARRANTY', 'Those parts shipped on ' || d(l.shipped_date) || ' and the ' || p.warranty_months
      || '-month warranty ended on ' || d(v_until) || ', so a warranty return cannot be opened. A person can still look at the failure - I can open a request for our team.',
      l.order_number, l.line_id, l.part_number, v_qty, l.unit_price, NULL::numeric, l.shipped_date, v_until; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, l.order_number, l.line_id, l.part_number, v_qty, l.unit_price,
    round(v_qty * l.unit_price, 2), l.shipped_date, v_until;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION rma_key(p_order TEXT, p_part TEXT, p_qty TEXT) RETURNS TEXT AS $$
  SELECT norm_ref(p_order) || '|' || norm_part(p_part) || '|' || norm_qty(p_qty)
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION rma_summary(p_qty INTEGER, p_part TEXT, p_order TEXT, p_shipped DATE, p_defect TEXT, p_safety BOOLEAN,
                                       p_ext NUMERIC) RETURNS TEXT AS $$
  SELECT 'Open a return (RMA) for ' || qty_txt(p_qty) || ' pcs of ' || p_part || ' from order ' || p_order || ' (shipped ' || d(p_shipped)
         || '). Reported problem classified as ' || p_defect || '; safety-relevant: ' || yes_no(p_safety)
         || '. Our Quality Engineering team decides the disposition (credit or not) within '
         || (SELECT CASE WHEN p_safety THEN rma_sla_safety ELSE rma_sla_standard END FROM order_policy)
         || ' business day(s); the most it could credit is ' || usd(p_ext) || '. Please keep the parts until you receive return instructions.'
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- TWO-STEP ACTIONS: propose (PROPOSED or BLOCKED, 15-minute expiry) -> confirm (re-check) -> event + trigger
-- =====================================================================
CREATE OR REPLACE FUNCTION propose_order_fn(p_token TEXT, p_part TEXT, p_qty TEXT, p_po TEXT)
RETURNS TABLE (account_id VARCHAR, buyer_id VARCHAR, action_type VARCHAR, target_key TEXT, part_number VARCHAR, quantity INTEGER,
               unit_price NUMERIC, extended NUMERIC, po_number VARCHAR, outcome VARCHAR, reason_code VARCHAR, reason_text TEXT,
               summary TEXT, ship_date DATE) AS $$
  SELECT sb.account_id, sb.buyer_id, 'PLACE_ORDER'::varchar, order_key(p_part, p_qty, p_po), e.part_number, e.quantity,
         e.unit_price, e.extended, coalesce(e.po_number, nullif(left(trim(coalesce(p_po, '')), 30), ''))::varchar,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary, e.ship_date
    FROM session_buyer(p_token) sb
    CROSS JOIN LATERAL order_eval(sb.account_id, p_part, p_qty, p_po) e
   WHERE sb.buyer_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.account_id = sb.account_id AND pa.action_type = 'PLACE_ORDER'
                        AND pa.target_key = order_key(p_part, p_qty, p_po) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM account_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_rma_fn(p_token TEXT, p_order TEXT, p_part TEXT, p_qty TEXT, p_desc TEXT, p_defect TEXT,
                                          p_safety TEXT, p_brief TEXT)
RETURNS TABLE (account_id VARCHAR, buyer_id VARCHAR, action_type VARCHAR, target_key TEXT, part_number VARCHAR, quantity INTEGER,
               unit_price NUMERIC, extended NUMERIC, order_number VARCHAR, line_id BIGINT, failure_description TEXT,
               defect_type VARCHAR, safety_relevant BOOLEAN, triage_brief TEXT, outcome VARCHAR, reason_code VARCHAR,
               reason_text TEXT, summary TEXT) AS $$
  SELECT sb.account_id, sb.buyer_id, 'OPEN_RMA'::varchar, rma_key(p_order, p_part, p_qty), e.part_number, e.quantity,
         e.unit_price, e.extended, e.order_number, e.line_id,
         left(coalesce(nullif(trim(p_desc), ''), '(no description given)'), 2000),
         norm_defect(p_defect)::varchar, norm_yes(p_safety), left(nullif(trim(p_brief), ''), 3000),
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text,
         CASE WHEN e.ok THEN rma_summary(e.quantity, e.part_number, e.order_number, e.shipped_date, norm_defect(p_defect),
                                         norm_yes(p_safety), e.extended) END
    FROM session_buyer(p_token) sb
    CROSS JOIN LATERAL rma_eval(sb.account_id, p_order, p_part, p_qty) e
   WHERE sb.buyer_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.account_id = sb.account_id AND pa.action_type = 'OPEN_RMA'
                        AND pa.target_key = rma_key(p_order, p_part, p_qty) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND pa.defect_type IS NOT DISTINCT FROM norm_defect(p_defect)
                        AND pa.safety_relevant IS NOT DISTINCT FROM norm_yes(p_safety)
                        AND NOT EXISTS (SELECT 1 FROM account_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

-- Shared readback: the caller's latest proposal for this action + normalised request. A LARGE_LAST_TIME_BUY block
-- also returns its proposal_id: that is the reference for the last_time_buy case (open_service_case).
CREATE OR REPLACE FUNCTION proposal_result(p_token TEXT, p_action TEXT, p_key TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT,
               unit_price NUMERIC, extended NUMERIC, ship_date TEXT, expires_at TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' OR pa.reason_code = 'LARGE_LAST_TIME_BUY' THEN pa.proposal_id END,
         pa.action_type,
         CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sb.buyer_id IS NULL THEN 'Please verify your identity again (account number, e-mail and one-time code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing has been placed yet. Reply yes within 15 minutes to go ahead.'
              ELSE pa.reason_text END,
         pa.summary, pa.unit_price, pa.extended, d(pa.ship_date),
         CASE WHEN pa.outcome = 'PROPOSED' THEN to_char(pa.expires_at, 'YYYY-MM-DD HH24:MI') END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.account_id = sb.account_id AND p.action_type = p_action AND p.target_key = p_key
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_order_result(p_token TEXT, p_part TEXT, p_qty TEXT, p_po TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT,
               unit_price NUMERIC, extended NUMERIC, ship_date TEXT, expires_at TEXT) AS $$
  SELECT * FROM proposal_result(p_token, 'PLACE_ORDER', order_key(p_part, p_qty, p_po))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_rma_result(p_token TEXT, p_order TEXT, p_part TEXT, p_qty TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT,
               unit_price NUMERIC, extended NUMERIC, ship_date TEXT, expires_at TEXT) AS $$
  SELECT * FROM proposal_result(p_token, 'OPEN_RMA', rma_key(p_order, p_part, p_qty))
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm: re-checks EVERY rule; returns the account_events row only when executable.
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, account_id VARCHAR, buyer_id VARCHAR, action_type VARCHAR,
               part_number VARCHAR, quantity INTEGER, unit_price NUMERIC, extended NUMERIC, po_number VARCHAR, order_number VARCHAR,
               line_id BIGINT, failure_description TEXT, defect_type VARCHAR, safety_relevant BOOLEAN, triage_brief TEXT,
               ship_date DATE, summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  v_acct TEXT; v_buyer TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev account_events;
  o RECORD; r RECORD; v_id BIGINT; v_reference TEXT; v_sum TEXT;
BEGIN
  SELECT s.account_id, s.buyer_id INTO v_acct, v_buyer FROM session_buyer(p_token) s;
  IF v_acct IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.account_id = v_acct;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_acct, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal on your account. Nothing was placed or opened.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM account_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (v_acct, v_ref, 'ALREADY_DONE', 'This was already done earlier (reference ' || ev.reference || '). Nothing new was placed or opened.',
              ev.reference, ev.summary);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_acct, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_acct, v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was placed or opened. I can set it up again.', pa.summary);
    RETURN;
  END IF;
  IF pa.action_type = 'PLACE_ORDER' THEN
    SELECT * INTO o FROM order_eval(v_acct, pa.part_number, pa.quantity::text, pa.po_number) e;
    IF NOT o.ok THEN
      INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_code, reason_text, summary)
        VALUES (v_acct, v_ref, 'BLOCKED', o.reason_code, o.reason_text, pa.summary);
      RETURN;
    END IF;
    v_id := nextval(pg_get_serial_sequence('account_events', 'event_id'));
    v_reference := 'SO-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('so_seq')::text, 4, '0');
    INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (v_acct, v_ref, 'EXECUTED', 'Your order is placed.', v_reference, o.summary);
    RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, v_acct::varchar, v_buyer::varchar, pa.action_type,
                        o.part_number, o.quantity, o.unit_price, o.extended, o.po_number, NULL::varchar, NULL::bigint,
                        NULL::text, NULL::varchar, NULL::boolean, NULL::text, o.ship_date, o.summary;
  ELSE
    SELECT * INTO r FROM rma_eval(v_acct, pa.order_number, pa.part_number, pa.quantity::text) e;
    IF NOT r.ok THEN
      INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_code, reason_text, summary)
        VALUES (v_acct, v_ref, 'BLOCKED', r.reason_code, r.reason_text, pa.summary);
      RETURN;
    END IF;
    v_id := nextval(pg_get_serial_sequence('account_events', 'event_id'));
    v_reference := 'RMA-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('rma_seq')::text, 4, '0');
    v_sum := rma_summary(r.quantity, r.part_number, r.order_number, r.shipped_date, pa.defect_type, pa.safety_relevant, r.extended);
    INSERT INTO confirm_attempts (account_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (v_acct, v_ref, 'EXECUTED', 'Your return is open. Our Quality Engineering team will decide the disposition; I cannot predict the outcome.',
              v_reference, v_sum);
    RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, v_acct::varchar, v_buyer::varchar, pa.action_type,
                        r.part_number, r.quantity, r.unit_price, r.extended, NULL::varchar, r.order_number, r.line_id,
                        pa.failure_description, pa.defect_type, pa.safety_relevant, pa.triage_brief, NULL::date, v_sum;
  END IF;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, case_id VARCHAR, team VARCHAR, reply_due TEXT, reason_code VARCHAR, reason_text TEXT,
               summary TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         ca.reference, ca.case_id,
         CASE WHEN ca.case_id IS NOT NULL THEN r.team END,
         CASE WHEN ca.case_id IS NOT NULL THEN d(s.sla_due_at::date) END,
         CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN sb.buyer_id IS NULL THEN 'Please verify your identity again (account number, e-mail and one-time code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that proposal on your account. Nothing was placed or opened.'
              ELSE ca.reason_text END,
         ca.summary
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN LATERAL (SELECT a.* FROM confirm_attempts a
                        WHERE a.account_id = sb.account_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) ca ON TRUE
    LEFT JOIN service_cases s ON s.case_id = ca.case_id
    LEFT JOIN case_routing r ON r.request_type = s.request_type
$$ LANGUAGE sql STABLE;

-- Side effects of an executed action - atomic with the event row. Never an UPDATE from a tool.
--   PLACE_ORDER: sales order + line, stock allocated, open balance up.
--   OPEN_RMA:    RMA row + the rma_disposition case for Quality Engineering (SLA from the agent's safety flag, in SQL).
CREATE OR REPLACE FUNCTION apply_account_event() RETURNS TRIGGER AS $$
DECLARE pol order_policy; r case_routing; v_no BIGINT; v_case TEXT; v_actor TEXT := coalesce(NEW.buyer_id, 'SYSTEM');
BEGIN
  SELECT * INTO pol FROM order_policy;
  IF NEW.action_type = 'PLACE_ORDER' THEN
    INSERT INTO sales_orders (order_number, account_id, buyer_id, po_number, order_date, source)
      VALUES (NEW.reference, NEW.account_id, NEW.buyer_id, NEW.po_number, current_date, CASE WHEN NEW.case_id IS NULL THEN 'CHAT' ELSE 'REVIEW' END);
    INSERT INTO order_lines (order_number, line_no, part_number, quantity, unit_price, promised_date)
      VALUES (NEW.reference, 1, NEW.part_number, NEW.quantity, NEW.unit_price, NEW.ship_date);
    UPDATE inventory SET qty_available = qty_available - NEW.quantity WHERE part_number = NEW.part_number;
    UPDATE accounts SET open_balance = open_balance + NEW.extended WHERE account_id = NEW.account_id;
    PERFORM audit('ORDER_PLACED', v_actor, NEW.reference, NEW.summary);
  ELSIF NEW.action_type = 'OPEN_RMA' THEN
    INSERT INTO rmas (rma_id, account_id, order_number, line_id, part_number, quantity, unit_price, defect_type, safety_relevant,
                      description, status, opened_date, source)
      VALUES (NEW.reference, NEW.account_id, NEW.order_number, NEW.line_id, NEW.part_number, NEW.quantity, NEW.unit_price,
              NEW.defect_type, coalesce(NEW.safety_relevant, FALSE), NEW.failure_description, 'UNDER_REVIEW', current_date, 'CHAT');
    SELECT * INTO r FROM case_routing WHERE request_type = 'rma_disposition';
    v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
    v_case := 'ARC-CASE-' || lpad(v_no::text, 6, '0');
    INSERT INTO service_cases (case_no, case_id, account_id, buyer_id, request_type, summary, reference_id, part_number, quantity,
                               unit_price, line_id, requested_amount, parked_action, agent_brief, priority, sla_due_at)
      VALUES (v_no, v_case, NEW.account_id, NEW.buyer_id, 'rma_disposition', NEW.failure_description, NEW.reference, NEW.part_number,
              NEW.quantity, NEW.unit_price, NEW.line_id, NEW.extended, 'RMA_CREDIT:' || NEW.reference,
              'RMA triage (AI-prepared, not verified): defect type ' || NEW.defect_type || '; safety-relevant: '
              || yes_no(coalesce(NEW.safety_relevant, FALSE)) || '.' || coalesce(' ' || NEW.triage_brief, ''),
              CASE WHEN NEW.safety_relevant THEN 'SAFETY' ELSE 'NORMAL' END,
              add_business_days_ts(clock_timestamp()::timestamp, CASE WHEN NEW.safety_relevant THEN pol.rma_sla_safety ELSE pol.rma_sla_standard END));
    UPDATE confirm_attempts SET case_id = v_case WHERE reference = NEW.reference AND outcome = 'EXECUTED';
    PERFORM audit('RMA_OPENED', v_actor, NEW.reference, NEW.summary);
    PERFORM audit('CASE_OPENED', v_actor, v_case, 'rma_disposition for ' || NEW.reference);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_account_event AFTER INSERT ON account_events FOR EACH ROW EXECUTE FUNCTION apply_account_event();

-- =====================================================================
-- EXPEDITE - own unshipped line, earlier date; within stock / lead time it is done, beyond it a person decides
-- =====================================================================
-- 'SO-2026-0014/2' (also 'SO-2026-0014 line 2' / 'SO-2026-0014-2'); an order with a single open line needs no line no.
CREATE OR REPLACE FUNCTION find_line(p_account TEXT, p_line_ref TEXT) RETURNS BIGINT AS $$
  WITH x AS (SELECT upper(regexp_replace(trim(coalesce(p_line_ref, '')), '\s*(/|LINE|#)\s*', '/', 'gi')) AS r),
       y AS (SELECT CASE WHEN r ~ '^SO-\d{4}-\d{4}/\d+$' THEN split_part(r, '/', 1)
                         WHEN r ~ '^SO-\d{4}-\d{4}-\d+$' THEN substr(r, 1, 12) ELSE r END AS ord,
                    CASE WHEN r ~ '^SO-\d{4}-\d{4}/\d+$' THEN split_part(r, '/', 2)::int
                         WHEN r ~ '^SO-\d{4}-\d{4}-\d+$' THEN substr(r, 14)::int END AS ln
               FROM x)
  SELECT l.line_id FROM y JOIN sales_orders o ON o.order_number = y.ord AND o.account_id = p_account
    JOIN order_lines l ON l.order_number = o.order_number
   WHERE (y.ln IS NOT NULL AND l.line_no = y.ln)
      OR (y.ln IS NULL AND (SELECT count(*) FROM order_lines z WHERE z.order_number = o.order_number AND z.shipped_qty < z.quantity) = 1
          AND l.shipped_qty < l.quantity)
   LIMIT 1
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION expedite_eval(p_account TEXT, p_line_ref TEXT, p_date TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, line_id BIGINT, part_number VARCHAR, old_date DATE, new_date DATE,
               earliest DATE) AS $$
#variable_conflict use_column
DECLARE l order_lines; v_line BIGINT := find_line(p_account, p_line_ref); v_new DATE := date_or_null(p_date); v_earliest DATE;
BEGIN
  SELECT * INTO l FROM order_lines x WHERE x.line_id = v_line;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_FOUND', 'I could not find that order line on your account. Please give the order number and line (for example SO-2026-0014/2).',
      NULL::bigint, NULL::varchar, NULL::date, v_new, NULL::date; RETURN;
  END IF;
  IF l.shipped_qty >= l.quantity THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_SHIPPED', 'That line already shipped on ' || coalesce(d(l.shipped_date), 'an earlier date') || ', so it cannot be expedited.',
      l.line_id, l.part_number, l.promised_date, v_new, NULL::date; RETURN;
  END IF;
  IF v_new IS NULL OR v_new <= current_date THEN
    RETURN QUERY SELECT FALSE, 'INVALID_DATE', 'Please give the new ship date as a future date (YYYY-MM-DD).',
      l.line_id, l.part_number, l.promised_date, v_new, NULL::date; RETURN;
  END IF;
  IF v_new >= l.promised_date THEN
    RETURN QUERY SELECT FALSE, 'NOT_EARLIER', 'That line is already promised for ' || d(l.promised_date) || ', which is not later than ' || d(v_new) || ', so there is nothing to pull in.',
      l.line_id, l.part_number, l.promised_date, v_new, NULL::date; RETURN;
  END IF;
  v_earliest := earliest_ship_date(l.part_number, l.quantity - l.shipped_qty);
  IF v_new < v_earliest THEN
    RETURN QUERY SELECT FALSE, 'FACTORY_EXPEDITE_REQUIRED', 'The earliest we can ship ' || qty_txt(l.quantity - l.shipped_qty) || ' pcs of '
      || l.part_number || ' from stock or confirmed supply is ' || d(v_earliest) || '. Anything earlier needs a factory expedite, which our Sales & Pricing team must request and approve - I can open that request.',
      l.line_id, l.part_number, l.promised_date, v_new, v_earliest; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, l.line_id, l.part_number, l.promised_date, v_new, v_earliest;
END $$ LANGUAGE plpgsql STABLE;

-- Guarded write-row: records the attempt (readback) and returns the expedite_events row only when allowed.
CREATE OR REPLACE FUNCTION expedite_row(p_token TEXT, p_line_ref TEXT, p_date TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, line_id BIGINT, account_id VARCHAR, old_date DATE, new_date DATE,
               source VARCHAR, case_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_acct TEXT; e RECORD; v_id BIGINT; v_ref TEXT;
BEGIN
  SELECT s.account_id INTO v_acct FROM session_buyer(p_token) s;
  IF v_acct IS NULL THEN RETURN; END IF;
  SELECT * INTO e FROM expedite_eval(v_acct, p_line_ref, p_date) x;
  IF NOT e.ok THEN
    INSERT INTO expedite_attempts (account_id, line_ref, outcome, reason_code, reason_text, old_date, new_date, earliest_date)
      VALUES (v_acct, norm_ref(p_line_ref), 'BLOCKED', e.reason_code, e.reason_text, e.old_date, e.new_date, e.earliest);
    RETURN;
  END IF;
  v_id := nextval(pg_get_serial_sequence('expedite_events', 'event_id'));
  v_ref := 'EXP-' || lpad(v_id::text, 6, '0');
  INSERT INTO expedite_attempts (account_id, line_ref, outcome, reason_text, reference, old_date, new_date, earliest_date)
    VALUES (v_acct, norm_ref(p_line_ref), 'EXPEDITED', 'Done. The line is now promised for ' || d(e.new_date) || '.', v_ref, e.old_date, e.new_date, e.earliest);
  RETURN QUERY SELECT v_id, v_ref::varchar, e.line_id, v_acct::varchar, e.old_date, e.new_date, 'BUYER'::varchar, NULL::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION expedite_result(p_token TEXT, p_line_ref TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, part_number VARCHAR, previous_promised_date TEXT, new_promised_date TEXT,
               earliest_without_factory_expedite TEXT, reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ea.outcome, 'BLOCKED') END,
         ea.reference, l.part_number, d(ea.old_date), CASE WHEN ea.outcome = 'EXPEDITED' THEN d(ea.new_date) END,
         d(ea.earliest_date),
         CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' WHEN ea.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ea.reason_code END,
         CASE WHEN sb.buyer_id IS NULL THEN 'Please verify your identity again (account number, e-mail and one-time code).'
              WHEN ea.attempt_id IS NULL THEN 'I could not find that order line on your account.'
              ELSE ea.reason_text END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN LATERAL (SELECT a.* FROM expedite_attempts a WHERE a.account_id = sb.account_id AND a.line_ref = norm_ref(p_line_ref)
                        ORDER BY a.attempt_id DESC LIMIT 1) ea ON TRUE
    LEFT JOIN order_lines l ON l.line_id = find_line(sb.account_id, p_line_ref)
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_expedite_event() RETURNS TRIGGER AS $$
BEGIN
  UPDATE order_lines SET promised_date = NEW.new_date WHERE line_id = NEW.line_id;
  PERFORM audit('EXPEDITED', coalesce(NEW.case_id, NEW.account_id), NEW.reference,
                'line ' || NEW.line_id || ' ' || d(NEW.old_date) || ' -> ' || d(NEW.new_date) || ' (' || NEW.source || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_expedite_event AFTER INSERT ON expedite_events FOR EACH ROW EXECUTE FUNCTION apply_expedite_event();

-- =====================================================================
-- CHANGE-NOTICE ALERTS - one subscription per account and part (dedupe in SQL)
-- =====================================================================
CREATE OR REPLACE FUNCTION subscribe_row(p_token TEXT, p_part TEXT)
RETURNS TABLE (account_id VARCHAR, buyer_id VARCHAR, part_number VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_acct TEXT; v_buyer TEXT; v_part TEXT := norm_part(p_part);
BEGIN
  SELECT s.account_id, s.buyer_id INTO v_acct, v_buyer FROM session_buyer(p_token) s;
  IF v_acct IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM parts x WHERE x.part_number = v_part) THEN
    INSERT INTO subscribe_attempts (account_id, part_ref, outcome) VALUES (v_acct, v_part, 'PART_NOT_FOUND');
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM pcn_subscriptions x WHERE x.account_id = v_acct AND x.part_number = v_part) THEN
    INSERT INTO subscribe_attempts (account_id, part_ref, outcome) VALUES (v_acct, v_part, 'ALREADY_SUBSCRIBED');
    RETURN;
  END IF;
  INSERT INTO subscribe_attempts (account_id, part_ref, outcome) VALUES (v_acct, v_part, 'SUBSCRIBED');
  PERFORM audit('PCN_SUBSCRIBED', v_buyer, v_part, v_acct);
  RETURN QUERY SELECT v_acct::varchar, v_buyer::varchar, v_part::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION subscribe_result(p_token TEXT, p_part TEXT)
RETURNS TABLE (outcome TEXT, part_number TEXT, reason_text TEXT, notices_on_file BIGINT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(sa.outcome, 'PART_NOT_FOUND') END,
         norm_part(p_part),
         CASE WHEN sb.buyer_id IS NULL THEN 'Please verify your identity again (account number, e-mail and one-time code).'
              WHEN sa.outcome = 'SUBSCRIBED' THEN 'Your account will now receive Arcwell change notices (PCN / EOL) for ' || norm_part(p_part) || ' by e-mail.'
              WHEN sa.outcome = 'ALREADY_SUBSCRIBED' THEN 'Your account is already subscribed to change notices for ' || norm_part(p_part) || '; nothing was added.'
              ELSE 'I could not find part ' || norm_part(p_part) || ' in the Arcwell catalog, so no alert was set up.' END,
         CASE WHEN sa.outcome IN ('SUBSCRIBED','ALREADY_SUBSCRIBED') THEN (SELECT count(*) FROM pcn_notices n WHERE n.part_number = norm_part(p_part)) END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN LATERAL (SELECT a.outcome FROM subscribe_attempts a WHERE a.account_id = sb.account_id AND a.part_ref = norm_part(p_part)
                        ORDER BY a.attempt_id DESC LIMIT 1) sa ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
-- reference_id per type: last_time_buy = the proposal_id of the LARGE_LAST_TIME_BUY propose_order result;
-- factory_expedite = the line_ref (SO-2026-0014/2) + requested_date; credit_review = (none) + amount = the new credit
-- limit asked for (empty = release the hold at the current limit); special_pricing = the part number (optional).
CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_summary TEXT, p_ref TEXT, p_date TEXT, p_amount TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, account_id VARCHAR, buyer_id VARCHAR, request_type VARCHAR, summary TEXT,
               reference_id VARCHAR, part_number VARCHAR, quantity INTEGER, unit_price NUMERIC, po_number VARCHAR, line_id BIGINT,
               requested_date DATE, requested_amount NUMERIC, parked_action VARCHAR, sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_acct TEXT; v_buyer TEXT; v_type TEXT := norm_request_type(p_type); v_ref TEXT := nullif(norm_ref(p_ref), ''); r case_routing;
        pa pending_actions; a accounts; e RECORD; l order_lines; v_part TEXT; v_qty INTEGER; v_price NUMERIC; v_po TEXT;
        v_line BIGINT; v_date DATE; v_amt NUMERIC; v_amt_txt TEXT := norm_amount(p_amount); v_parked TEXT; v_existing TEXT;
        v_no BIGINT; v_case TEXT;
BEGIN
  SELECT s.account_id, s.buyer_id INTO v_acct, v_buyer FROM session_buyer(p_token) s;
  IF v_acct IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM case_routing x WHERE x.request_type = v_type AND x.buyer_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code) VALUES (v_acct, v_type, v_ref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  IF v_type = 'last_time_buy' THEN
    SELECT * INTO pa FROM pending_actions x WHERE x.proposal_id = v_ref AND x.account_id = v_acct AND x.action_type = 'PLACE_ORDER';
    IF NOT FOUND THEN
      INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_acct, v_type, v_ref, 'BLOCKED', 'NOT_FOUND', 'I could not find that order proposal on your account. Please ask for the order again so I can check it.');
      RETURN;
    END IF;
    IF pa.reason_code IS DISTINCT FROM 'LARGE_LAST_TIME_BUY' THEN
      INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_acct, v_type, v_ref, 'BLOCKED', 'NOT_ELIGIBLE', 'That order does not need a last-time-buy approval'
                || CASE WHEN pa.outcome = 'PROPOSED' THEN ' - it can be confirmed directly.' ELSE ': ' || coalesce(pa.reason_text, 'it was blocked.') END);
      RETURN;
    END IF;
    v_part := pa.part_number; v_qty := pa.quantity; v_price := pa.unit_price; v_po := pa.po_number;
    v_amt := pa.quantity; v_parked := 'LTB_ORDER:' || pa.proposal_id;
  ELSIF v_type = 'factory_expedite' THEN
    v_line := find_line(v_acct, p_ref);
    IF v_line IS NULL THEN
      INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_acct, v_type, v_ref, 'BLOCKED', 'NOT_FOUND', 'I could not find that order line on your account, so no request was opened.');
      RETURN;
    END IF;
    SELECT * INTO e FROM expedite_eval(v_acct, p_ref, p_date) x;
    IF e.reason_code IS DISTINCT FROM 'FACTORY_EXPEDITE_REQUIRED' THEN
      INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_acct, v_type, v_ref, 'BLOCKED', 'NOT_ELIGIBLE',
                CASE WHEN e.ok THEN 'That date is possible without a factory expedite - I can pull the line in directly.'
                     ELSE coalesce(e.reason_text, 'That line cannot be expedited.') END);
      RETURN;
    END IF;
    SELECT * INTO l FROM order_lines x WHERE x.line_id = v_line;
    v_part := l.part_number; v_qty := l.quantity - l.shipped_qty; v_price := l.unit_price; v_date := e.new_date;
    v_ref := l.order_number || '/' || l.line_no; v_parked := 'EXPEDITE:' || l.line_id;
  ELSIF v_type = 'credit_review' THEN
    SELECT * INTO a FROM accounts x WHERE x.account_id = v_acct;
    v_amt := CASE WHEN v_amt_txt = '' THEN a.credit_limit WHEN v_amt_txt ~ '^[0-9]+(\.[0-9]+)?$' THEN round(v_amt_txt::numeric, 2) END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > (SELECT max_credit_limit FROM order_policy) THEN
      INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_acct, v_type, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The credit limit you ask for must be a dollar amount above $0 and no more than '
                || usd((SELECT max_credit_limit FROM order_policy)) || '. No request was opened.');
      RETURN;
    END IF;
    v_ref := v_acct; v_parked := 'CREDIT_LIMIT:' || v_acct;
  ELSIF v_type = 'special_pricing' THEN
    IF v_ref IS NOT NULL THEN
      v_part := norm_part(p_ref);
      IF NOT EXISTS (SELECT 1 FROM parts x WHERE x.part_number = v_part) THEN
        INSERT INTO case_requests (account_id, request_type, reference_id, outcome, reason_code, reason_text)
          VALUES (v_acct, v_type, v_ref, 'BLOCKED', 'NOT_FOUND', 'I could not find that part in the Arcwell catalog, so no request was opened.');
        RETURN;
      END IF;
      v_ref := v_part;
    END IF;
  END IF;
  SELECT s.case_id INTO v_existing FROM service_cases s
   WHERE s.account_id = v_acct AND s.request_type = v_type AND s.status = 'OPEN'
     AND (v_type = 'credit_review' OR s.reference_id IS NOT DISTINCT FROM v_ref)
   ORDER BY s.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (account_id, request_type, reference_id, outcome, case_id) VALUES (v_acct, v_type, v_ref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'ARC-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (account_id, request_type, reference_id, outcome, case_id) VALUES (v_acct, v_type, v_ref, 'OPENED', v_case);
  PERFORM audit('CASE_OPENED', v_buyer, v_case, v_type || coalesce(' for ' || v_ref, ''));
  RETURN QUERY SELECT v_no, v_case::varchar, v_acct::varchar, v_buyer::varchar, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_ref::varchar, v_part::varchar,
                      v_qty, v_price, v_po::varchar, v_line, v_date, v_amt, v_parked::varchar,
                      add_business_days_ts(clock_timestamp()::timestamp, r.sla_business_days);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due TEXT, requested TEXT,
               reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.team, rt.sla_text, d(s.sla_due_at::date), case_requested_text(s.case_id),
         CASE WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN sb.buyer_id IS NULL THEN 'Please verify your identity again (account number, e-mail and one-time code).'
              WHEN cr.outcome = 'OPENED' THEN 'Your request is open. A person on our ' || rt.team || ' team will review it and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' request, so no new one was opened. Our ' || rt.team || ' team is on it.'
              WHEN cr.reason_text IS NOT NULL THEN cr.reason_text
              ELSE 'That is not a request I can open here. A person can help with special pricing or price matches, credit reviews, factory expedites and large last-time-buys; RMAs are opened through the return process.' END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.account_id = sb.account_id AND q.request_type = norm_request_type(p_type)
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
CREATE OR REPLACE FUNCTION customer_display(p_case TEXT) RETURNS TEXT AS $$
  SELECT a.company || coalesce(' (buyer ' || b.first_name || ' ' || left(b.last_name, 1) || '.)', '')
    FROM service_cases s JOIN accounts a ON a.account_id = s.account_id LEFT JOIN buyers b ON b.buyer_id = s.buyer_id
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The most a reviewer may approve (NULL = the case carries no amount): credit USD, LTB units, credit limit USD.
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE s.request_type
           WHEN 'rma_disposition' THEN (SELECT round(r.quantity * r.unit_price, 2) FROM rmas r WHERE 'RMA_CREDIT:' || r.rma_id = s.parked_action)
           WHEN 'last_time_buy' THEN s.quantity
           WHEN 'credit_review' THEN s.requested_amount
           ELSE NULL END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION case_amount_unit(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.request_type WHEN 'rma_disposition' THEN 'USD credit' WHEN 'last_time_buy' THEN 'units (pieces)'
                             WHEN 'credit_review' THEN 'USD credit limit' ELSE 'no amount' END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;
-- USD value of an approval, compared with the reviewer's approval_limit.
CREATE OR REPLACE FUNCTION case_value(p_case TEXT, p_amount NUMERIC) RETURNS NUMERIC AS $$
  SELECT CASE WHEN s.request_type = 'last_time_buy' THEN round(p_amount * s.unit_price, 2) ELSE p_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no buyer e-mail or code).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.request_type
    WHEN 'rma_disposition' THEN
      'RMA ' || r.rma_id || ': ' || qty_txt(r.quantity) || ' pcs of ' || r.part_number || ' (' || p.description || ') from order '
      || r.order_number || ', shipped ' || d(l.shipped_date) || ' (' || qty_txt(l.shipped_qty) || ' pcs on that line) at ' || usd_unit(r.unit_price)
      || ' each; warranty until ' || d((l.shipped_date + make_interval(months => p.warranty_months))::date)
      || '; defect type ' || r.defect_type || '; safety-relevant ' || yes_no(r.safety_relevant) || '; priority ' || s.priority
      || '; other RMAs from this account in the last 12 months: '
      || (SELECT count(*) FROM rmas o WHERE o.account_id = s.account_id AND o.rma_id <> r.rma_id AND o.opened_date > current_date - 365)
    WHEN 'last_time_buy' THEN
      qty_txt(s.quantity) || ' pcs of ' || s.part_number || ' (' || p.description || ', ' || p.lifecycle || ', last-time-buy date '
      || coalesce(d(p.ltb_date), 'n/a') || ') at ' || usd_unit(s.unit_price) || ' = ' || usd(s.quantity * s.unit_price) || ' on PO ' || coalesce(s.po_number, '?')
      || '; in stock now ' || qty_txt(i.qty_available) || '; account available credit ' || usd(greatest(a.credit_limit - a.open_balance, 0))
      || CASE WHEN a.credit_hold THEN ' (ON CREDIT HOLD)' ELSE '' END || '; last-time-buy orders are non-cancellable and non-returnable'
    WHEN 'factory_expedite' THEN
      'Line ' || s.reference_id || ': ' || qty_txt(s.quantity) || ' pcs of ' || s.part_number || ' promised ' || d(l.promised_date)
      || ', customer asks for ' || d(s.requested_date) || '; earliest without a factory expedite '
      || d(earliest_ship_date(s.part_number, s.quantity)) || '; in stock ' || qty_txt(i.qty_available) || ', factory lead time '
      || i.lead_time_weeks || ' weeks' || coalesce(', next receipt ' || qty_txt(i.next_receipt_qty) || ' pcs due ' || d(i.next_receipt_date), '')
    WHEN 'credit_review' THEN
      a.company || ' (' || a.industry || ', customer since ' || d(a.customer_since) || ', terms ' || a.payment_terms || '): credit limit '
      || usd(a.credit_limit) || ', open balance ' || usd(a.open_balance)
      || CASE WHEN a.credit_hold THEN ', ON CREDIT HOLD (' || coalesce(a.hold_reason, 'no reason recorded') || ')' ELSE ', not on hold' END
      || '; requested limit ' || usd(s.requested_amount)
    WHEN 'special_pricing' THEN
      coalesce('Part ' || s.part_number || ' (' || p.description || '); price breaks ' || price_table(s.part_number)
               || '; in stock ' || qty_txt(i.qty_available), 'No part given') || '. Approval records the decision; the team sends the quote.'
    ELSE 'No linked record.' END
    FROM service_cases s
    JOIN accounts a ON a.account_id = s.account_id
    LEFT JOIN rmas r ON 'RMA_CREDIT:' || r.rma_id = s.parked_action
    LEFT JOIN parts p ON p.part_number = s.part_number
    LEFT JOIN inventory i ON i.part_number = s.part_number
    LEFT JOIN order_lines l ON l.line_id = coalesce(r.line_id, s.line_id)
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, priority VARCHAR, customer TEXT, opened_on TEXT,
               age_days INTEGER, reply_due TEXT, sla_status TEXT, requested TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.priority, q.customer, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, r.label, s.priority, customer_display(s.case_id) AS customer, d(s.created_at::date) AS opened_on,
             (current_date - s.created_at::date)::int AS age_days, d(s.sla_due_at::date) AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             case_requested_text(s.case_id) AS requested, s.sla_due_at
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND r.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.priority DESC, q.sla_due_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, priority VARCHAR, customer TEXT, opened_on TEXT,
               reply_due TEXT, customer_statement TEXT, agent_brief TEXT, requested TEXT, max_approvable NUMERIC, amount_unit TEXT,
               your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on TEXT, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.label, s.status, s.priority, customer_display(s.case_id), d(s.created_at::date), d(s.sla_due_at::date),
         s.summary, s.agent_brief, case_requested_text(s.case_id), case_eligible_max(s.case_id), case_amount_unit(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN case_eligible_max(s.case_id) IS NOT NULL THEN
                'APPROVE (amount in ' || case_amount_unit(s.case_id) || ', up to ' || CASE WHEN s.request_type = 'last_time_buy'
                     THEN qty_txt(case_eligible_max(s.case_id)) ELSE usd(case_eligible_max(s.case_id)) END
                || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_value(s.case_id, case_eligible_max(s.case_id))
                        THEN '; anything worth more than your ' || usd(sr.approval_limit) || ' limit needs a senior reviewer' ELSE '' END
                || ') or REJECT, with an internal note and a message for the customer.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the customer.'
                   || CASE s.request_type WHEN 'factory_expedite' THEN ' Approval moves the line''s promised date to the requested date.'
                                          WHEN 'special_pricing' THEN ' Approval records the decision; your team sends the quote.' ELSE '' END END,
         d(s.decided_at::date),
         (SELECT rd.decision || coalesce(' ' || case_amount_text(rd.case_id, rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT x.request_type FROM case_routing x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN case_routing r ON r.request_type = s.request_type
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; r case_routing; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_amt_txt TEXT := norm_amount(p_amount); v_msg TEXT; o RECORD; l order_lines;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM service_cases x WHERE x.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT * INTO r FROM case_routing x WHERE x.request_type = s.request_type;
  IF r.team <> rv.team THEN
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
    v_amt := CASE WHEN v_amt_txt = '' THEN v_max WHEN v_amt_txt ~ '^-?[0-9]+(\.[0-9]+)?$' THEN round(v_amt_txt::numeric, 2) END;
    IF s.request_type = 'last_time_buy' AND v_amt IS NOT NULL AND v_amt <> trunc(v_amt) THEN v_amt := NULL; END IF;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The approved amount must be more than 0 and no more than '
                || CASE WHEN s.request_type = 'last_time_buy' THEN qty_txt(v_max) || ' pieces' ELSE usd(v_max) END || ' for this case.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND case_value(s.case_id, v_amt) > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', usd(case_value(s.case_id, v_amt)) || ' is above your approval limit of '
                || usd(rv.approval_limit) || '. The case stays open and needs a senior reviewer.');
      RETURN;
    END IF;
  END IF;
  -- An approval must be executable now: the parked action is re-checked by the same rules before the decision is taken.
  IF v_dec = 'APPROVE' AND s.request_type = 'last_time_buy' THEN
    SELECT * INTO o FROM order_eval(s.account_id, s.part_number, v_amt::int::text, s.po_number, TRUE) x;
    IF NOT o.ok THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ACTION_BLOCKED', 'The order cannot be placed as approved: ' || o.reason_text || ' The case stays open.');
      RETURN;
    END IF;
  ELSIF v_dec = 'APPROVE' AND s.request_type = 'factory_expedite' THEN
    SELECT * INTO l FROM order_lines x WHERE x.line_id = s.line_id;
    IF l.shipped_qty >= l.quantity OR s.requested_date <= current_date THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ACTION_BLOCKED', 'The line has shipped or the requested date has passed, so the expedite cannot be applied. The case stays open.');
      RETURN;
    END IF;
  END IF;
  IF v_dec = 'REJECT' THEN v_amt := NULL; END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || r.label || ' request has been approved' || coalesce(' (' || case_amount_text(s.case_id, v_amt) || ')', '') || '.'
                  ELSE 'After review, your ' || r.label || ' request was not approved. Your Arcwell account team will follow up.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved TEXT, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION','ACTION_BLOCKED')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN case_amount_text(rd.case_id, rd.approved_amount) END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND' AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'RMA ' || cm.rma_id || ' approved; credit memo ' || cm.reference || ' of ' || usd(cm.amount) || ' issued.'
                            FROM credit_memos cm WHERE cm.case_id = s.case_id),
                         (SELECT 'Last-time-buy order ' || ae.reference || ' placed: ' || qty_txt(ae.quantity) || ' pcs of ' || ae.part_number
                                 || ' for ' || usd(ae.extended) || ', shipping ' || d(ae.ship_date) || '.'
                            FROM account_events ae WHERE ae.case_id = s.case_id),
                         (SELECT 'Factory expedite ' || ee.reference || ': line promised date moved from ' || d(ee.old_date) || ' to ' || d(ee.new_date) || '.'
                            FROM expedite_events ee WHERE ee.case_id = s.case_id),
                         (SELECT 'Credit change ' || cc.reference || ': limit ' || usd(cc.old_limit) || ' -> ' || usd(cc.new_limit)
                                 || CASE WHEN cc.hold_released THEN ', credit hold released.' ELSE '.' END
                            FROM credit_changes cc WHERE cc.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded rows the decision trigger uses to execute the parked action (same checks every time).
CREATE OR REPLACE FUNCTION credit_memo_row(p_rma TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (reference VARCHAR, rma_id VARCHAR, account_id VARCHAR, amount NUMERIC, case_id VARCHAR) AS $$
  SELECT ('CM-' || lpad(nextval(pg_get_serial_sequence('credit_memos', 'memo_id'))::text, 6, '0'))::varchar,
         r.rma_id, r.account_id, p_amount, p_case::varchar
    FROM rmas r
   WHERE r.rma_id = p_rma AND r.status = 'UNDER_REVIEW'
     AND p_amount > 0 AND p_amount <= round(r.quantity * r.unit_price, 2)
     AND NOT EXISTS (SELECT 1 FROM credit_memos x WHERE x.rma_id = r.rma_id)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION ltb_order_row(p_case TEXT, p_qty NUMERIC)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, case_id VARCHAR, account_id VARCHAR, buyer_id VARCHAR, action_type VARCHAR,
               part_number VARCHAR, quantity INTEGER, unit_price NUMERIC, extended NUMERIC, po_number VARCHAR, ship_date DATE,
               summary TEXT) AS $$
  SELECT nextval(pg_get_serial_sequence('account_events', 'event_id')),
         ('SO-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('so_seq')::text, 4, '0'))::varchar,
         s.case_id, s.account_id, s.buyer_id, 'PLACE_ORDER'::varchar, o.part_number, o.quantity, o.unit_price, o.extended,
         o.po_number, o.ship_date, o.summary || ' Approved by Arcwell Sales & Pricing (case ' || s.case_id || ').'
    FROM service_cases s
    CROSS JOIN LATERAL order_eval(s.account_id, s.part_number, p_qty::int::text, s.po_number, TRUE) o
   WHERE s.case_id = p_case AND s.request_type = 'last_time_buy' AND o.ok
     AND NOT EXISTS (SELECT 1 FROM account_events x WHERE x.case_id = s.case_id)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION expedite_override_row(p_case TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, line_id BIGINT, account_id VARCHAR, old_date DATE, new_date DATE,
               source VARCHAR, case_id VARCHAR) AS $$
  SELECT x.id, ('EXP-' || lpad(x.id::text, 6, '0'))::varchar, l.line_id, s.account_id, l.promised_date, s.requested_date,
         'REVIEWER'::varchar, s.case_id
    FROM service_cases s JOIN order_lines l ON l.line_id = s.line_id
    CROSS JOIN LATERAL (SELECT nextval(pg_get_serial_sequence('expedite_events', 'event_id')) AS id) x
   WHERE s.case_id = p_case AND s.request_type = 'factory_expedite' AND l.shipped_qty < l.quantity
     AND s.requested_date > current_date AND s.requested_date < l.promised_date
     AND NOT EXISTS (SELECT 1 FROM expedite_events e WHERE e.case_id = s.case_id)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION credit_change_row(p_account TEXT, p_limit NUMERIC, p_case TEXT)
RETURNS TABLE (reference VARCHAR, account_id VARCHAR, old_limit NUMERIC, new_limit NUMERIC, hold_released BOOLEAN, case_id VARCHAR) AS $$
  SELECT ('CRL-' || lpad(nextval(pg_get_serial_sequence('credit_changes', 'change_id'))::text, 6, '0'))::varchar,
         a.account_id, a.credit_limit, p_limit, a.credit_hold, p_case::varchar
    FROM accounts a
   WHERE a.account_id = p_account AND p_limit > 0 AND p_limit <= (SELECT max_credit_limit FROM order_policy)
     AND NOT EXISTS (SELECT 1 FROM credit_changes x WHERE x.case_id = p_case)
$$ LANGUAGE sql VOLATILE;

-- The decision event: case status + customer message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF v_kind = 'RMA_CREDIT' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO credit_memos (reference, rma_id, account_id, amount, case_id) SELECT * FROM credit_memo_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN
      UPDATE rmas SET status = 'APPROVED', credit_amount = NEW.approved_amount, decided_at = NEW.decided_at WHERE rma_id = v_ref;
      v_done := 'RMA ' || v_ref || ' approved, credit ' || usd(NEW.approved_amount);
    END IF;
  ELSIF v_kind = 'RMA_CREDIT' AND NEW.decision = 'REJECT' THEN
    UPDATE rmas SET status = 'REJECTED', decided_at = NEW.decided_at WHERE rma_id = v_ref;
    v_done := 'RMA ' || v_ref || ' rejected';
  ELSIF v_kind = 'LTB_ORDER' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO account_events (event_id, reference, case_id, account_id, buyer_id, action_type, part_number, quantity, unit_price,
                                extended, po_number, ship_date, summary)
      SELECT * FROM ltb_order_row(NEW.case_id, NEW.approved_amount);
    IF FOUND THEN v_done := 'last-time-buy order placed for ' || qty_txt(NEW.approved_amount) || ' pcs'; END IF;
  ELSIF v_kind = 'EXPEDITE' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO expedite_events (event_id, reference, line_id, account_id, old_date, new_date, source, case_id)
      SELECT * FROM expedite_override_row(NEW.case_id);
    IF FOUND THEN v_done := 'line ' || v_ref || ' promised date moved to ' || d(s.requested_date); END IF;
  ELSIF v_kind = 'CREDIT_LIMIT' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO credit_changes (reference, account_id, old_limit, new_limit, hold_released, case_id)
      SELECT * FROM credit_change_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'credit limit set to ' || usd(NEW.approved_amount) || ', hold released'; END IF;
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id,
                NEW.decision || coalesce(' ' || case_amount_text(NEW.case_id, NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- A credit memo reduces what the account owes.
CREATE OR REPLACE FUNCTION apply_credit_memo() RETURNS TRIGGER AS $$
BEGIN
  UPDATE accounts SET open_balance = greatest(open_balance - NEW.amount, 0) WHERE account_id = NEW.account_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_credit_memo AFTER INSERT ON credit_memos FOR EACH ROW EXECUTE FUNCTION apply_credit_memo();

-- A credit change sets the new limit and releases any credit hold.
CREATE OR REPLACE FUNCTION apply_credit_change() RETURNS TRIGGER AS $$
BEGIN
  UPDATE accounts SET credit_limit = NEW.new_limit, credit_hold = FALSE, hold_reason = NULL WHERE account_id = NEW.account_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_credit_change AFTER INSERT ON credit_changes FOR EACH ROW EXECUTE FUNCTION apply_credit_change();

-- =====================================================================
-- EMAIL - only for the caller's order (SO-), RMA (RMA-), expedite (EXP-) or decided case (ARC-CASE-)
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_reference TEXT)
RETURNS TABLE (account_id VARCHAR, reference VARCHAR, kind TEXT, subject TEXT, detail TEXT) AS $$
  SELECT sb.account_id, x.reference::varchar, x.kind, x.subject, x.detail
    FROM session_buyer(p_token) sb
    JOIN LATERAL (
      SELECT ae.reference::text AS reference, lower(ae.action_type) AS kind,
             CASE WHEN ae.action_type = 'PLACE_ORDER' THEN 'Arcwell order confirmation ' ELSE 'Arcwell return (RMA) opened ' END || ae.reference AS subject,
             ae.summary || ' Reference: ' || ae.reference || '. Recorded on ' || to_char(ae.created_at, 'YYYY-MM-DD HH24:MI') || '.' AS detail
        FROM account_events ae WHERE ae.account_id = sb.account_id AND ae.reference = norm_ref(p_reference)
      UNION ALL
      SELECT ee.reference, 'expedite', 'Arcwell expedite confirmation ' || ee.reference,
             'Order line ' || l.order_number || '/' || l.line_no || ' (' || qty_txt(l.quantity) || ' pcs of ' || l.part_number
             || ') is now promised for ' || d(ee.new_date) || ' (was ' || d(ee.old_date) || '). Reference: ' || ee.reference || '.'
        FROM expedite_events ee JOIN order_lines l ON l.line_id = ee.line_id
       WHERE ee.account_id = sb.account_id AND ee.reference = norm_ref(p_reference)
      UNION ALL
      SELECT s.case_id, 'decision', 'Arcwell decision on request ' || s.case_id,
             'Our ' || r.team || ' team has decided your ' || r.label || ' request (' || s.case_id || '): ' || lower(s.status) || '. '
             || s.customer_message
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE s.account_id = sb.account_id AND s.case_id = norm_ref(p_reference)
         AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = s.case_id)) x ON TRUE
   WHERE sb.buyer_id IS NOT NULL
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (account_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT e.account_id, e.reference, e.subject FROM email_source(p_token, p_reference) e
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.reference IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.reference IS NOT NULL THEN NULL WHEN sb.buyer_id IS NULL THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN e.reference IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN sb.buyer_id IS NULL THEN 'Please verify your identity again (account number, e-mail and one-time code).'
              ELSE 'There is no order, return, expedite or decided request with that reference on your account, so no email was sent.' END,
         e.reference,
         coalesce(e.subject, 'Arcwell confirmation - not sent'),
         CASE WHEN e.reference IS NOT NULL THEN
           'Hello ' || b.first_name || ',' || chr(10) || chr(10)
           || 'This is a confirmation from Arc, the Arcwell Components AI assistant, for ' || a.company || '.' || chr(10) || chr(10)
           || e.detail || chr(10) || chr(10)
           || 'Questions? Reply to this email or call Arcwell customer service at (555) 010-2200.' || chr(10)
           || 'Thank you for choosing Arcwell Components.'
           ELSE 'No confirmation email was sent for reference ' || norm_ref(p_reference) || '.' END
    FROM (SELECT * FROM session_buyer(p_token)) sb
    LEFT JOIN buyers b ON b.buyer_id = sb.buyer_id
    LEFT JOIN accounts a ON a.account_id = sb.account_id
    LEFT JOIN LATERAL (SELECT * FROM email_source(p_token, p_reference) LIMIT 1) e ON TRUE
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

CREATE OR REPLACE FUNCTION ref_part_selection(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM part_selection_guide g
          UNION ALL                                 -- recommended replacements have ONE source of truth: the catalog
          SELECT 'REPLACEMENT', (p.part_number || ' (' || p.lifecycle || ')')::text,
                 ('Arcwell''s recommended replacement is ' || p.replacement_part
                   || coalesce(' (' || lower(replace(x.relation, '_', ' ')) || '): ' || x.notes, '.')
                   || coalesce(' Last-time-buy date ' || d(p.ltb_date) || '.', ''))::text, 1000
            FROM parts p
            LEFT JOIN cross_references x ON x.part_number = p.part_number AND x.alt_part = p.replacement_part
           WHERE p.replacement_part IS NOT NULL) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['ABBREVIATION','COLUMN','PACKAGE','RANKING','EXCLUDE','REPLACEMENT','NOTE_LINE'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_defect_taxonomy(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT t.section::text AS sec, t.term::text AS trm, t.meaning::text AS mng, t.entry_id AS ord
            FROM defect_taxonomy t
          UNION ALL                                 -- who decides an RMA has ONE source of truth: case_routing
          SELECT 'ROUTING', cr.label::text, ('decided by ' || cr.team || ': ' || cr.sla_text)::text, 1000
            FROM case_routing cr WHERE cr.request_type = 'rma_disposition') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['DEFECT_TYPE','SAFETY_SIGN','EVIDENCE','ROUTING','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_pcn_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM pcn_change_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['NOTICE_TYPE','CHANGE_TYPE','TERM','LINE_STATUS','RULE'], g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
