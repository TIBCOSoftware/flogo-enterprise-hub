-- Harborline Life & Retirement - Life & Retirement Member Services (GOVERNED) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: life_pensions_governed
-- Load:  createdb life_pensions_governed  &&  psql -d life_pensions_governed -f database.sql
--
-- =====================================================================
-- Fictional US life insurer + 401(k)/IRA plan provider "Harborline Life & Retirement", assistant "Ella".
-- The rules live HERE, not in any prompt:
--   * session_member() / session_reviewer()  identity: every tool is scoped by a session token; member and
--                                            reviewer tokens are not interchangeable (role checked)
--   * verify_*_fn()                          identifier + one-time code -> session; 5 failures / 15 min -> LOCKED
--   * my_*()                                 scoped reads - only the caller's rows; another member's id -> NOT_FOUND
--   * contribution_eval() / fund_switch_eval()  the 401(k) deferral and fund-switch rules (plan max, IRS limit, holding)
--   * propose_*_fn() / confirm_action_fn()   two-step: PROPOSED/BLOCKED with 15-minute expiry; confirm re-checks
--   * trg_account_event                      the deferral change / fund exchange happens atomically in the DB
--   * file_claim_row()                       policy Active, type matches the product, no duplicate open claim
--   * open_case_row()                        human-owned requests routed by case_routing (team + SLA)
--   * decide_case_row() + trg_review_decision  the reviewer loop: role/team/authority/amount checks, then the
--                                            parked action (claim payment / withdrawal) runs through guarded rows
--   * email_log_row()                        email only for the caller's executed action / filed claim / decided case
--   * ref_claim_checklist() / ref_life_event() / ref_appeal_guide()  the A2A agents' ONLY database access:
--                                            read-only reference tables (claim types + documents, life-event
--                                            checklists, denial reasons + evidence rules) with no member or staff
--                                            data; one optional lookup term, never an identity
-- Hidden from members: ssn, email, date_of_birth, otp_code, internal_note, agent_brief, reviewer identity.
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

DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, case_requests, file_claim_attempts,
  withdrawals, claim_payments, service_cases, confirm_attempts, account_events, pending_actions, rate_changes,
  claims, contributions, holdings, retirement_accounts, beneficiaries, policies, verify_attempts, sessions,
  reviewers, members, case_routing, funds, plan_limits, claim_intake_guide, life_event_guide, appeal_review_guide
  CASCADE;

-- ---------------------------------------------------------------------
-- Plan rules and catalogue
-- ---------------------------------------------------------------------
CREATE TABLE plan_limits (                       -- exactly one row; edit here when the IRS figures change
  id                   INTEGER PRIMARY KEY CHECK (id = 1),
  irs_deferral_limit   NUMERIC(10,2) NOT NULL,   -- annual elective-deferral limit (demo value)
  catchup_limit        NUMERIC(10,2) NOT NULL,   -- extra deferral allowed from catchup_age
  catchup_age          INTEGER NOT NULL,
  plan_max_rate        NUMERIC(5,2) NOT NULL     -- plan document maximum deferral, % of pay
);

CREATE TABLE funds (
  fund_id         VARCHAR(10) PRIMARY KEY,       -- FND-001
  fund_name       VARCHAR(80) NOT NULL,
  category        VARCHAR(16) NOT NULL CHECK (category IN ('Equity','Bond','Balanced','Money Market','Target Date','Index')),
  risk_level      VARCHAR(8)  NOT NULL CHECK (risk_level IN ('Low','Medium','High')),
  ytd_return      NUMERIC(6,2) NOT NULL,
  one_yr_return   NUMERIC(6,2) NOT NULL,
  three_yr_return NUMERIC(6,2) NOT NULL,
  expense_ratio   NUMERIC(5,3) NOT NULL,
  nav             NUMERIC(10,2) NOT NULL,        -- USD per unit
  open_to_new_money BOOLEAN NOT NULL DEFAULT TRUE
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type      VARCHAR(30) PRIMARY KEY,
  label             VARCHAR(40) NOT NULL,        -- member-facing name
  team              VARCHAR(40) NOT NULL,
  sla_business_days INTEGER NOT NULL,
  sla_text          VARCHAR(160) NOT NULL,
  member_openable   BOOLEAN NOT NULL DEFAULT TRUE -- claim_decision is opened only by file_claim
);

-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO member, beneficiary, staff, policy, claim, case, session or contact
-- data, ever. The "who decides / who helps" rows are NOT copied here: the ref_* functions read them from
-- case_routing (one source of truth).
CREATE TABLE claim_intake_guide (                -- claim_intake_agent: claim types, products, documents needed
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CLAIM_TYPE', 'PRODUCT', 'DOCUMENT', 'WAITING_PERIOD', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- CriticalIllness - completed claim form
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE life_event_guide (                  -- life_event_agent: what to review after each life event
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('LIFE_EVENT', 'RELATIONSHIP', 'DESIGNATION', 'SPOUSAL_CONSENT', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- divorce
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE appeal_review_guide (               -- appeal_summary_agent: denial reasons, new evidence, brief rules
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('DENIAL_REASON', 'WAITING_PERIOD', 'NEW_EVIDENCE', 'FAIR_REVIEW',
                                                      'BRIEF_RULE')),
  term        VARCHAR(60) NOT NULL,              -- WAITING_PERIOD_NOT_MET
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- People: members (plan participants / policyholders) and reviewers (staff)
-- ---------------------------------------------------------------------
CREATE TABLE members (
  member_id       VARCHAR(12) PRIMARY KEY,       -- HLR-100101
  otp_code        VARCHAR(6)  NOT NULL,          -- HIDDEN: demo stand-in for the texted one-time code
  first_name      VARCHAR(40) NOT NULL,
  last_name       VARCHAR(40) NOT NULL,
  email           VARCHAR(100) NOT NULL,         -- HIDDEN (emails go to the EMAIL_TO demo inbox)
  ssn             VARCHAR(11) NOT NULL,          -- HIDDEN: fictional 900-series SSN-like number
  date_of_birth   DATE NOT NULL,                 -- HIDDEN (age is derived in SQL where a rule needs it)
  state           VARCHAR(2) NOT NULL,
  marital_status  VARCHAR(12) NOT NULL CHECK (marital_status IN ('Single','Married','Divorced','Widowed')),
  employer        VARCHAR(60),
  annual_salary   NUMERIC(12,2),
  member_since    DATE NOT NULL
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- HLS-2041 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,          -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN
  approval_limit  NUMERIC(12,2),                 -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL CHECK (role IN ('MEMBER','REVIEWER')),
  member_id      VARCHAR(12) REFERENCES members,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'MEMBER' AND member_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND member_id IS NULL))
);

-- Every verify call (throttle + readback).
CREATE TABLE verify_attempts (
  attempt_id   BIGSERIAL PRIMARY KEY,
  role         VARCHAR(10) NOT NULL,
  identifier   VARCHAR(40) NOT NULL,             -- normalised as typed
  outcome      VARCHAR(14) NOT NULL CHECK (outcome IN ('VERIFIED','VERIFY_FAILED','LOCKED')),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_verify_attempts ON verify_attempts (role, identifier, created_at);

-- ---------------------------------------------------------------------
-- Policies, beneficiaries, retirement accounts, holdings, contributions, claims
-- ---------------------------------------------------------------------
CREATE TABLE policies (
  policy_id         VARCHAR(10) PRIMARY KEY,     -- POL-1001
  member_id         VARCHAR(12) NOT NULL REFERENCES members,
  product_type      VARCHAR(20) NOT NULL CHECK (product_type IN ('TermLife','WholeLife','CriticalIllness','IncomeProtection')),
  product_name      VARCHAR(60) NOT NULL,
  status            VARCHAR(12) NOT NULL CHECK (status IN ('Active','Lapsed','Pending','Cancelled')),
  status_date       DATE,                        -- when it lapsed / was applied for
  coverage_amount   NUMERIC(12,2) NOT NULL,      -- lump sum, or the monthly benefit for IncomeProtection
  premium           NUMERIC(10,2) NOT NULL,      -- USD per month
  waiting_period_days INTEGER,                   -- IncomeProtection only
  start_date        DATE NOT NULL,
  renewal_date      DATE
);
CREATE INDEX ix_policies_member ON policies (member_id);

CREATE TABLE beneficiaries (
  beneficiary_id   VARCHAR(10) PRIMARY KEY,
  policy_id        VARCHAR(10) NOT NULL REFERENCES policies,
  beneficiary_name VARCHAR(80) NOT NULL,
  relationship     VARCHAR(10) NOT NULL CHECK (relationship IN ('Spouse','Child','Parent','Sibling','Trust','Other')),
  share_pct        NUMERIC(5,2) NOT NULL,
  designation      VARCHAR(10) NOT NULL DEFAULT 'Primary' CHECK (designation IN ('Primary','Contingent')),
  date_added       DATE NOT NULL
);

CREATE TABLE retirement_accounts (
  account_id          VARCHAR(10) PRIMARY KEY,   -- RET-5001
  member_id           VARCHAR(12) NOT NULL REFERENCES members,
  account_type        VARCHAR(16) NOT NULL CHECK (account_type IN ('401(k)','Traditional IRA','Roth IRA')),
  contribution_rate   NUMERIC(5,2),              -- % of pay, 401(k) only
  employer_match_rate NUMERIC(5,2),              -- employer matches 100% up to this % of pay, 401(k) only
  vested_pct          NUMERIC(5,2) NOT NULL DEFAULT 100,
  ytd_employee        NUMERIC(12,2) NOT NULL DEFAULT 0,
  ytd_employer        NUMERIC(12,2) NOT NULL DEFAULT 0,
  opened_date         DATE NOT NULL
);
CREATE INDEX ix_accounts_member ON retirement_accounts (member_id);

-- Balance = sum(units x NAV); never stored, so it can never drift.
CREATE TABLE holdings (
  account_id  VARCHAR(10) NOT NULL REFERENCES retirement_accounts,
  fund_id     VARCHAR(10) NOT NULL REFERENCES funds,
  units       NUMERIC(16,4) NOT NULL CHECK (units >= 0),
  PRIMARY KEY (account_id, fund_id)
);

CREATE TABLE contributions (
  contribution_id   SERIAL PRIMARY KEY,
  member_id         VARCHAR(12) NOT NULL REFERENCES members,
  account_id        VARCHAR(10) REFERENCES retirement_accounts,
  policy_id         VARCHAR(10) REFERENCES policies,
  amount            NUMERIC(12,2) NOT NULL,
  contribution_type VARCHAR(12) NOT NULL CHECK (contribution_type IN ('Employee','Employer','Premium','Rollover')),
  contribution_date DATE NOT NULL
);
CREATE INDEX ix_contributions_member ON contributions (member_id, contribution_date);

CREATE TABLE rate_changes (                      -- history of executed deferral changes
  change_id        SERIAL PRIMARY KEY,
  account_id       VARCHAR(10) NOT NULL REFERENCES retirement_accounts,
  from_rate        NUMERIC(5,2) NOT NULL,
  to_rate          NUMERIC(5,2) NOT NULL,
  effective_date   DATE NOT NULL,
  source_reference VARCHAR(16) NOT NULL,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE claims (
  claim_id           VARCHAR(16) PRIMARY KEY,    -- CLM-2026-0004
  policy_id          VARCHAR(10) NOT NULL REFERENCES policies,
  member_id          VARCHAR(12) NOT NULL REFERENCES members,
  claim_type         VARCHAR(20) NOT NULL CHECK (claim_type IN ('CriticalIllness','IncomeProtection')),
  amount             NUMERIC(12,2) NOT NULL,     -- benefit claimed (lump sum or monthly benefit), set by SQL
  status             VARCHAR(12) NOT NULL CHECK (status IN ('Submitted','UnderReview','Approved','Paid','Denied')),
  filed_date         DATE NOT NULL,
  incident_date      DATE,                       -- date stopped work / diagnosed, as recorded
  description        TEXT,                       -- the member's own words
  documents_needed   TEXT,                       -- from the claim intake step (AI, unverified)
  denial_reason_code VARCHAR(30),
  denial_reason_text TEXT,
  approved_amount    NUMERIC(12,2),
  decided_at         TIMESTAMP,
  source             VARCHAR(6) NOT NULL DEFAULT 'SEED' CHECK (source IN ('SEED','CHAT'))
);
CREATE INDEX ix_claims_member ON claims (member_id);

-- ---------------------------------------------------------------------
-- Two-step actions: proposals -> confirmed events (the only path that changes a rate or a holding)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'HLR-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  member_id      VARCHAR(12) NOT NULL REFERENCES members,
  action_type    VARCHAR(30) NOT NULL CHECK (action_type IN ('CHANGE_CONTRIBUTION_RATE','FUND_SWITCH')),
  target_key     TEXT NOT NULL,                  -- normalised request, shared by the write-row and the readback
  account_id     VARCHAR(10),
  new_rate       NUMERIC(5,2),
  from_fund      VARCHAR(10),
  to_fund        VARCHAR(10),
  amount         NUMERIC(14,2),
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  effective_date DATE,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_member ON pending_actions (member_id, action_type, target_key, created_at);

CREATE TABLE account_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(16) NOT NULL UNIQUE,    -- HLR-ACT-000101
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  member_id      VARCHAR(12) NOT NULL REFERENCES members,
  action_type    VARCHAR(30) NOT NULL,
  account_id     VARCHAR(10) NOT NULL REFERENCES retirement_accounts,
  new_rate       NUMERIC(5,2),
  from_fund      VARCHAR(10),
  to_fund        VARCHAR(10),
  amount         NUMERIC(14,2),
  effective_date DATE,
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  member_id      VARCHAR(12) NOT NULL REFERENCES members,
  proposal_ref   TEXT NOT NULL,
  outcome        VARCHAR(14) NOT NULL,
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  reference      VARCHAR(16),
  summary        TEXT,
  effective_date DATE,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, payments, withdrawals, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,  -- HLR-CASE-000101
  member_id        VARCHAR(12) NOT NULL REFERENCES members,
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary          TEXT NOT NULL,                -- the member's request, in their words (neutral)
  reference_id     VARCHAR(16),                  -- claim / account / policy the case is about
  requested_amount NUMERIC(14,2),
  parked_action    VARCHAR(40),                  -- what runs on approval: CLAIM_DECISION:<claim> / CLAIM_APPEAL:<claim> / WITHDRAWAL:<account>
  agent_brief      TEXT,                         -- AI-prepared neutral brief for the reviewer (never shown to the member)
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                         -- member-safe outcome text, set by the decision
  approved_amount  NUMERIC(14,2),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_member ON service_cases (member_id, request_type, status);

CREATE TABLE case_requests (                     -- every open_service_case call (readback)
  request_id    SERIAL PRIMARY KEY,
  member_id     VARCHAR(12) NOT NULL REFERENCES members,
  request_type  VARCHAR(40) NOT NULL,
  reference_id  VARCHAR(40),
  outcome       VARCHAR(16) NOT NULL,
  reason_code   VARCHAR(24),
  case_id       VARCHAR(16),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE file_claim_attempts (               -- every file_claim call (readback)
  attempt_id    SERIAL PRIMARY KEY,
  member_id     VARCHAR(12) NOT NULL REFERENCES members,
  policy_ref    VARCHAR(40) NOT NULL,
  outcome       VARCHAR(12) NOT NULL,
  reason_code   VARCHAR(24),
  reason_text   TEXT,
  claim_id      VARCHAR(16),
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

CREATE TABLE claim_payments (
  payment_id   BIGSERIAL PRIMARY KEY,
  reference    VARCHAR(16) NOT NULL UNIQUE,      -- HLR-PAY-000101
  claim_id     VARCHAR(16) NOT NULL UNIQUE REFERENCES claims,
  amount       NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  case_id      VARCHAR(16),
  paid_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE withdrawals (
  withdrawal_id BIGSERIAL PRIMARY KEY,
  reference     VARCHAR(16) NOT NULL UNIQUE,     -- HLR-WDR-000101
  account_id    VARCHAR(10) NOT NULL REFERENCES retirement_accounts,
  amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  case_id       VARCHAR(16),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE agent_audit (
  audit_id    BIGSERIAL PRIMARY KEY,
  event_type  VARCHAR(20) NOT NULL,              -- ACTION_EXECUTED / CLAIM_FILED / CASE_OPENED / CASE_DECIDED
  actor       VARCHAR(12) NOT NULL,              -- member id or reviewer id
  subject_id  VARCHAR(16) NOT NULL,              -- reference / claim id / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id    SERIAL PRIMARY KEY,
  member_id   VARCHAR(12) NOT NULL REFERENCES members,
  reference   VARCHAR(16) NOT NULL,
  subject     TEXT NOT NULL,
  logged_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

DROP SEQUENCE IF EXISTS claim_seq;
CREATE SEQUENCE claim_seq START 101;             -- claims filed in chat: CLM-<year>-0101, ... (reset in seed_data.sql)

-- =====================================================================
-- HELPERS
-- =====================================================================
-- $45 / $9.99 / $1,234.50 (locale-independent separators)
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL
              WHEN n = trunc(n) THEN '$' || to_char(n, 'FM999,999,990')
              ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION pct(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE trim_scale(n)::text || '%' END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;

-- HLR-100101 / hlr100101 / HLR 100101 / 100101 -> HLR-100101
CREATE OR REPLACE FUNCTION norm_member_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{6}$' THEN 'HLR-' || x
              WHEN x ~ '^HLR[0-9]{6}$' THEN 'HLR-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- HLS-2041 / hls2041 / 2041 -> HLS-2041
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'HLS-' || x
              WHEN x ~ '^HLS[0-9]{4}$' THEN 'HLS-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ids typed by people or the model: ' pol-1001 ' -> 'POL-1001'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- '6', '6%', '6 percent', ' 6.0 ' -> '6'; anything else -> upper text (-> INVALID_RATE)
CREATE OR REPLACE FUNCTION norm_rate(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN trim(coalesce(p, '')) ~ '^-?[0-9]+(\.[0-9]+)?\s*(%|percent|pct)?$'
              THEN trim_scale(substring(trim(p) FROM '^-?[0-9]+(?:\.[0-9]+)?')::numeric)::text
              ELSE left(upper(trim(coalesce(p, ''))), 20) END
$$ LANGUAGE sql IMMUTABLE;
-- '$63,225.00' / '63225' -> '63225'; 'all' / 'everything' / 'entire holding' -> 'ALL'; else upper text
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN upper(trim(coalesce(p, ''))) IN ('ALL','EVERYTHING','ENTIRE','ENTIRE HOLDING','ALL OF IT','100%') THEN 'ALL'
              WHEN regexp_replace(trim(coalesce(p, '')), '[$,\s]|USD', '', 'gi') ~ '^-?[0-9]+(\.[0-9]+)?$'
              THEN trim_scale(regexp_replace(trim(p), '[$,\s]|USD', '', 'gi')::numeric)::text
              ELSE left(upper(trim(coalesce(p, ''))), 20) END
$$ LANGUAGE sql IMMUTABLE;
-- 'Critical Illness' / 'critical_illness' / 'CI' -> CriticalIllness; 'income protection' / 'disability' -> IncomeProtection
CREATE OR REPLACE FUNCTION norm_claim_type(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('CRITICALILLNESS','CI') THEN 'CriticalIllness'
              WHEN x IN ('INCOMEPROTECTION','IP','DISABILITY','DISABILITYINCOME') THEN 'IncomeProtection'
              WHEN x IN ('TERMLIFE','WHOLELIFE','LIFE','DEATH') THEN 'Life'
              ELSE left(x, 20) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION product_label(p TEXT) RETURNS TEXT AS $$
  SELECT CASE p WHEN 'TermLife' THEN 'Term Life' WHEN 'WholeLife' THEN 'Whole Life'
                WHEN 'CriticalIllness' THEN 'Critical Illness' WHEN 'IncomeProtection' THEN 'Income Protection' ELSE p END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION age_years(p DATE) RETURNS INTEGER AS $$
  SELECT extract(year FROM age(current_date, p))::int
$$ LANGUAGE sql STABLE;
-- semi-monthly payroll on the 1st and 15th: the next one after today
CREATE OR REPLACE FUNCTION next_payroll_date() RETURNS DATE AS $$
  SELECT CASE WHEN extract(day FROM current_date) < 15 THEN (date_trunc('month', current_date) + INTERVAL '14 days')::date
              ELSE (date_trunc('month', current_date) + INTERVAL '1 month')::date END
$$ LANGUAGE sql STABLE;
-- fund exchanges trade at the next market close (weekdays)
CREATE OR REPLACE FUNCTION next_trade_date() RETURNS DATE AS $$
  SELECT CASE extract(isodow FROM current_date) WHEN 6 THEN current_date + 2 WHEN 7 THEN current_date + 1 ELSE current_date END
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION add_business_days(p_from TIMESTAMP, p_days INTEGER) RETURNS TIMESTAMP AS $$
DECLARE t TIMESTAMP := p_from; n INTEGER := 0;
BEGIN
  WHILE n < p_days LOOP
    t := t + INTERVAL '1 day';
    IF extract(isodow FROM t) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN t;
END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION holding_value(p_account TEXT, p_fund TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(round(sum(h.units * f.nav), 2), 0) FROM holdings h JOIN funds f ON f.fund_id = h.fund_id
   WHERE h.account_id = p_account AND h.fund_id = p_fund
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION account_balance(p_account TEXT) RETURNS NUMERIC AS $$
  SELECT coalesce(sum(round(h.units * f.nav, 2)), 0) FROM holdings h JOIN funds f ON f.fund_id = h.fund_id
   WHERE h.account_id = p_account
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION vested_balance(p_account TEXT) RETURNS NUMERIC AS $$
  SELECT round(account_balance(a.account_id) * a.vested_pct / 100, 2) FROM retirement_accounts a WHERE a.account_id = p_account
$$ LANGUAGE sql STABLE;
-- annual deferral limit for one member: IRS limit + catch-up from catchup_age
CREATE OR REPLACE FUNCTION deferral_limit(p_member TEXT) RETURNS NUMERIC AS $$
  SELECT l.irs_deferral_limit + CASE WHEN age_years(m.date_of_birth) >= l.catchup_age THEN l.catchup_limit ELSE 0 END
    FROM members m CROSS JOIN plan_limits l WHERE m.member_id = p_member
$$ LANGUAGE sql STABLE;
-- highest whole-percent rate allowed by the plan maximum AND the IRS limit
CREATE OR REPLACE FUNCTION max_allowed_rate(p_member TEXT) RETURNS NUMERIC AS $$
  SELECT least(l.plan_max_rate, floor(deferral_limit(m.member_id) * 100 / nullif(m.annual_salary, 0)))
    FROM members m CROSS JOIN plan_limits l WHERE m.member_id = p_member
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;

-- =====================================================================
-- IDENTITY (members and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the member when the token is a valid MEMBER token, else NULL -> SESSION_INVALID.
CREATE OR REPLACE FUNCTION session_member(p_token TEXT)
RETURNS TABLE (member_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT m.member_id
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'MEMBER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN members m ON m.member_id = s.member_id;
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

-- Guarded write-row for verify_member: records the attempt (throttle) and returns the sessions row ONLY for a
-- matching member id + one-time code while the identifier is not locked (5 failures in 15 minutes).
CREATE OR REPLACE FUNCTION verify_member_fn(p_member TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, member_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_member_id(p_member); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'MEMBER' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('MEMBER', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT m.member_id INTO v_match FROM members m WHERE m.member_id = v_id AND m.otp_code = trim(coalesce(p_code, ''));
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('MEMBER', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('MEMBER', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'MEMBER'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_member_result(p_member TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, first_name VARCHAR, expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.first_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.expires_at END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'You are verified. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For your security, verification is paused for 15 minutes. Please try again later.'
              ELSE 'That member ID and one-time code do not match our records. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'MEMBER' AND a.identifier = norm_member_id(p_member)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, m.first_name, s.expires_at
                         FROM members m JOIN sessions s ON s.member_id = m.member_id AND s.role = 'MEMBER'
                                                       AND s.expires_at > clock_timestamp()
                        WHERE m.member_id = norm_member_id(p_member) AND m.otp_code = trim(coalesce(p_code, ''))
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
RETURNS TABLE (outcome TEXT, session_token TEXT, role TEXT, display_name VARCHAR, team VARCHAR, expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'REVIEWER' END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.display_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.team END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.expires_at END,
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
-- SCOPED READS (member) - every function starts FROM session_member(token)
-- =====================================================================
CREATE OR REPLACE FUNCTION my_profile(p_token TEXT)
RETURNS TABLE (status TEXT, member_id VARCHAR, member_name TEXT, marital_status VARCHAR, state VARCHAR,
               employer VARCHAR, annual_salary NUMERIC, member_since DATE, policies_held BIGINT, retirement_accounts BIGINT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         m.member_id, m.first_name || ' ' || m.last_name, m.marital_status, m.state, m.employer, m.annual_salary, m.member_since,
         (SELECT count(*) FROM policies p WHERE p.member_id = m.member_id),
         (SELECT count(*) FROM retirement_accounts a WHERE a.member_id = m.member_id)
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN members m ON m.member_id = sm.member_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_policies(p_token TEXT)
RETURNS TABLE (status TEXT, policy_id VARCHAR, product_type VARCHAR, product_name VARCHAR, policy_status VARCHAR,
               status_note TEXT, coverage_amount NUMERIC, coverage_basis TEXT, monthly_premium NUMERIC,
               waiting_period_days INTEGER, start_date DATE, renewal_date DATE, beneficiaries BIGINT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         p.policy_id, p.product_type, p.product_name, p.status,
         CASE p.status WHEN 'Lapsed' THEN 'Lapsed on ' || d(p.status_date) || ' after missed premiums; cover is not in force.'
                       WHEN 'Pending' THEN 'Application received ' || d(p.status_date) || '; underwriting in progress, cover not yet in force.'
                       WHEN 'Active' THEN 'In force.' WHEN 'Cancelled' THEN 'Cancelled.' END,
         p.coverage_amount,
         CASE WHEN p.policy_id IS NULL THEN NULL WHEN p.product_type = 'IncomeProtection' THEN 'monthly benefit' ELSE 'lump sum' END,
         p.premium, p.waiting_period_days, p.start_date, p.renewal_date,
         (SELECT count(*) FROM beneficiaries b WHERE b.policy_id = p.policy_id)
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN policies p ON p.member_id = sm.member_id
   ORDER BY p.policy_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_beneficiaries(p_token TEXT)
RETURNS TABLE (status TEXT, policy_id VARCHAR, product_name VARCHAR, beneficiary_name VARCHAR, relationship VARCHAR,
               share_pct NUMERIC, designation VARCHAR, date_added DATE) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         p.policy_id, p.product_name, b.beneficiary_name, b.relationship, b.share_pct, b.designation, b.date_added
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN policies p ON p.member_id = sm.member_id
    LEFT JOIN beneficiaries b ON b.policy_id = p.policy_id
   WHERE sm.member_id IS NULL OR b.beneficiary_id IS NOT NULL
   ORDER BY p.policy_id, b.designation, b.beneficiary_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_retirement_accounts(p_token TEXT)
RETURNS TABLE (status TEXT, account_id VARCHAR, account_type VARCHAR, balance NUMERIC, vested_balance NUMERIC,
               contribution_rate TEXT, employer_match TEXT, match_gap_pct NUMERIC, unclaimed_match_per_year NUMERIC,
               annual_salary NUMERIC, annual_deferral_limit NUMERIC, plan_max_rate TEXT, max_rate_allowed TEXT,
               ytd_employee NUMERIC, ytd_employer NUMERIC, next_payroll_date DATE, match_text TEXT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         a.account_id, a.account_type, account_balance(a.account_id), vested_balance(a.account_id),
         CASE WHEN a.account_type = '401(k)' THEN pct(a.contribution_rate) || ' of pay'
              WHEN a.account_id IS NOT NULL THEN 'n/a (IRA - not funded through payroll)' END,
         CASE WHEN a.account_type = '401(k)' THEN 'Harborline plan: employer matches 100% of the first ' || pct(a.employer_match_rate) || ' of pay' END,
         CASE WHEN a.account_type = '401(k)' THEN greatest(a.employer_match_rate - a.contribution_rate, 0) END,
         CASE WHEN a.account_type = '401(k)' THEN round(m.annual_salary * greatest(a.employer_match_rate - a.contribution_rate, 0) / 100, 2) END,
         CASE WHEN a.account_type = '401(k)' THEN m.annual_salary END,
         CASE WHEN a.account_type = '401(k)' THEN deferral_limit(m.member_id) END,
         CASE WHEN a.account_type = '401(k)' THEN pct(l.plan_max_rate) END,
         CASE WHEN a.account_type = '401(k)' THEN pct(max_allowed_rate(m.member_id)) END,
         a.ytd_employee, a.ytd_employer,
         CASE WHEN a.account_type = '401(k)' THEN next_payroll_date() END,
         CASE WHEN a.account_type <> '401(k)' OR a.account_id IS NULL THEN NULL
              WHEN a.contribution_rate >= a.employer_match_rate
                THEN 'You are contributing enough to receive the full employer match.'
              ELSE 'You are contributing ' || pct(a.contribution_rate) || '; contributing ' || pct(a.employer_match_rate)
                   || ' would add ' || usd(round(m.annual_salary * (a.employer_match_rate - a.contribution_rate) / 100, 2))
                   || ' a year in employer match that you are not receiving now.' END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN members m ON m.member_id = sm.member_id
    LEFT JOIN retirement_accounts a ON a.member_id = sm.member_id
    CROSS JOIN plan_limits l
   ORDER BY a.account_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_holdings(p_token TEXT)
RETURNS TABLE (status TEXT, account_id VARCHAR, account_type VARCHAR, fund_id VARCHAR, fund_name VARCHAR, category VARCHAR,
               risk_level VARCHAR, units NUMERIC, nav NUMERIC, value NUMERIC, allocation_pct NUMERIC) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         a.account_id, a.account_type, f.fund_id, f.fund_name, f.category, f.risk_level, h.units, f.nav,
         round(h.units * f.nav, 2),
         CASE WHEN h.units IS NOT NULL THEN round(100 * round(h.units * f.nav, 2) / nullif(account_balance(a.account_id), 0), 2) END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN retirement_accounts a ON a.member_id = sm.member_id
    LEFT JOIN holdings h ON h.account_id = a.account_id AND h.units > 0
    LEFT JOIN funds f ON f.fund_id = h.fund_id
   WHERE sm.member_id IS NULL OR h.units IS NOT NULL
   ORDER BY a.account_id, round(h.units * f.nav, 2) DESC
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_contributions(p_token TEXT)
RETURNS TABLE (status TEXT, contribution_date DATE, paid_into TEXT, contribution_type VARCHAR, amount NUMERIC) AS $$
  SELECT x.* FROM (
    SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END AS status,
           c.contribution_date,
           CASE WHEN c.account_id IS NOT NULL THEN a.account_type || ' ' || c.account_id
                WHEN c.policy_id IS NOT NULL THEN p.product_name || ' ' || c.policy_id END AS paid_into,
           c.contribution_type, c.amount
      FROM (SELECT * FROM session_member(p_token)) sm
      LEFT JOIN contributions c ON c.member_id = sm.member_id
      LEFT JOIN retirement_accounts a ON a.account_id = c.account_id
      LEFT JOIN policies p ON p.policy_id = c.policy_id
     ORDER BY c.contribution_date DESC, c.contribution_id DESC
     LIMIT 12) x
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_claims(p_token TEXT)
RETURNS TABLE (status TEXT, claim_id VARCHAR, policy_id VARCHAR, product_name VARCHAR, claim_type VARCHAR, amount NUMERIC,
               claim_status VARCHAR, filed_date DATE, incident_date DATE, decision_text TEXT, approved_amount NUMERIC,
               payment_reference VARCHAR, paid_amount NUMERIC, related_case_id VARCHAR, related_case_status VARCHAR) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.claim_id, c.policy_id, p.product_name, c.claim_type, c.amount, c.status, c.filed_date, c.incident_date,
         CASE c.status WHEN 'Denied' THEN 'Denied: ' || coalesce(c.denial_reason_text, 'see your decision letter.')
                       WHEN 'Approved' THEN 'Approved for ' || usd(c.approved_amount) || '.'
                       WHEN 'Paid' THEN 'Paid.'
                       WHEN 'UnderReview' THEN 'A claims examiner is reviewing this claim.'
                       WHEN 'Submitted' THEN 'Received; waiting for a claims examiner.' END,
         c.approved_amount, cp.reference, cp.amount, sc.case_id, sc.status
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN claims c ON c.member_id = sm.member_id
    LEFT JOIN policies p ON p.policy_id = c.policy_id
    LEFT JOIN claim_payments cp ON cp.claim_id = c.claim_id
    LEFT JOIN LATERAL (SELECT s.case_id, s.status FROM service_cases s
                        WHERE s.member_id = sm.member_id AND s.reference_id = c.claim_id
                        ORDER BY s.created_at DESC LIMIT 1) sc ON TRUE
   ORDER BY c.filed_date DESC
$$ LANGUAGE sql STABLE;

-- The member's own cases: status + the member-safe outcome. Never the internal note, brief or reviewer.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, about VARCHAR, team VARCHAR, case_status VARCHAR,
               opened_on DATE, reply_due DATE, requested_amount NUMERIC, outcome_amount NUMERIC, decided_on DATE,
               customer_message TEXT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         s.case_id, r.label, s.reference_id, r.team, s.status, s.created_at::date, s.sla_due_at::date,
         s.requested_amount, s.approved_amount, s.decided_at::date,
         CASE WHEN s.status = 'OPEN' THEN 'Open - a person on our ' || r.team || ' team will decide.' ELSE s.customer_message END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN service_cases s ON s.member_id = sm.member_id
    LEFT JOIN case_routing r ON r.request_type = s.request_type
   ORDER BY s.created_at DESC
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION fund_catalog(p_token TEXT)
RETURNS TABLE (status TEXT, fund_id VARCHAR, fund_name VARCHAR, category VARCHAR, risk_level VARCHAR, ytd_return NUMERIC,
               one_yr_return NUMERIC, three_yr_return NUMERIC, expense_ratio NUMERIC, nav NUMERIC, open_to_new_money TEXT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         f.fund_id, f.fund_name, f.category, f.risk_level, f.ytd_return, f.one_yr_return, f.three_yr_return,
         f.expense_ratio, f.nav, CASE WHEN f.fund_id IS NULL THEN NULL WHEN f.open_to_new_money THEN 'yes' ELSE 'no' END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN funds f ON sm.member_id IS NOT NULL
   ORDER BY f.fund_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- RULES for the two-step actions
-- =====================================================================
CREATE OR REPLACE FUNCTION contribution_eval(p_member TEXT, p_rate TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, account_id VARCHAR, new_rate NUMERIC, summary TEXT, effective_date DATE) AS $$
#variable_conflict use_column
DECLARE m members; a retirement_accounts; l plan_limits; v_txt TEXT := norm_rate(p_rate); v_rate NUMERIC; v_lim NUMERIC;
BEGIN
  SELECT * INTO m FROM members x WHERE x.member_id = p_member;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again.', NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  SELECT * INTO l FROM plan_limits;
  SELECT * INTO a FROM retirement_accounts x WHERE x.member_id = p_member AND x.account_type = '401(k)' ORDER BY x.account_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NO_401K', 'You do not have a Harborline 401(k), so there is no payroll contribution rate to change. IRA contributions are made directly, not through payroll.',
      NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  IF v_txt !~ '^[0-9]+$' OR v_txt::numeric > 100 THEN
    RETURN QUERY SELECT FALSE, 'INVALID_RATE', 'Please give the new contribution rate as a whole percentage of pay, from 0% to ' || pct(l.plan_max_rate) || '.',
      a.account_id, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  v_rate := v_txt::numeric;
  IF v_rate = a.contribution_rate THEN
    RETURN QUERY SELECT FALSE, 'NO_CHANGE', 'You are already contributing ' || pct(v_rate) || ' of pay, so there is nothing to change.',
      a.account_id, v_rate, NULL::text, NULL::date; RETURN;
  END IF;
  IF v_rate > l.plan_max_rate THEN
    RETURN QUERY SELECT FALSE, 'ABOVE_PLAN_MAX', 'The Harborline 401(k) plan allows contributions of up to ' || pct(l.plan_max_rate)
      || ' of pay. The highest rate you can choose is ' || pct(max_allowed_rate(m.member_id)) || '.',
      a.account_id, v_rate, NULL::text, NULL::date; RETURN;
  END IF;
  v_lim := deferral_limit(m.member_id);
  IF m.annual_salary * v_rate / 100 > v_lim THEN
    RETURN QUERY SELECT FALSE, 'IRS_LIMIT', pct(v_rate) || ' of your pay would be ' || usd(round(m.annual_salary * v_rate / 100, 2))
      || ' a year, which is over the IRS annual limit of ' || usd(v_lim) || ' for your contributions. The highest rate you can choose is '
      || pct(max_allowed_rate(m.member_id)) || '.', a.account_id, v_rate, NULL::text, NULL::date; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, a.account_id, v_rate,
    'Change your 401(k) contribution (' || a.account_id || ') from ' || pct(a.contribution_rate) || ' to ' || pct(v_rate)
    || ' of pay, starting with the payroll on ' || d(next_payroll_date()) || ' (about ' || usd(round(m.annual_salary * v_rate / 100 / 24, 2))
    || ' per paycheck before taxes). '
    || CASE WHEN v_rate >= a.employer_match_rate THEN 'At ' || pct(v_rate) || ' you receive the full employer match.'
            ELSE 'At ' || pct(v_rate) || ' you would still miss ' || usd(round(m.annual_salary * (a.employer_match_rate - v_rate) / 100, 2))
                 || ' a year of employer match.' END,
    next_payroll_date();
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION switch_key(p_account TEXT, p_from TEXT, p_to TEXT, p_amount TEXT) RETURNS TEXT AS $$
  SELECT norm_ref(p_account) || '|' || norm_ref(p_from) || '|' || norm_ref(p_to) || '|' || norm_amount(p_amount)
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fund_switch_eval(p_member TEXT, p_account TEXT, p_from TEXT, p_to TEXT, p_amount TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, account_id VARCHAR, from_fund VARCHAR, to_fund VARCHAR,
               amount NUMERIC, summary TEXT, effective_date DATE) AS $$
#variable_conflict use_column
DECLARE a retirement_accounts; ff funds; tf funds; v_held NUMERIC; v_amt_txt TEXT := norm_amount(p_amount); v_amt NUMERIC;
        v_acct TEXT := norm_ref(p_account); v_from TEXT := norm_ref(p_from); v_to TEXT := norm_ref(p_to);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM members x WHERE x.member_id = p_member) THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again.', NULL::varchar, NULL::varchar, NULL::varchar,
      NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  SELECT * INTO a FROM retirement_accounts x WHERE x.account_id = v_acct AND x.member_id = p_member;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_FOUND', 'I could not find that account among your Harborline retirement accounts.',
      NULL::varchar, NULL::varchar, NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  SELECT * INTO tf FROM funds x WHERE x.fund_id = v_to;
  IF NOT FOUND OR NOT tf.open_to_new_money THEN
    RETURN QUERY SELECT FALSE, 'INVALID_FUND', 'That destination fund is not available for new money in the Harborline lineup. Please choose a fund from the fund lineup that is open to new money.',
      a.account_id, NULL::varchar, NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  IF v_from = v_to THEN
    RETURN QUERY SELECT FALSE, 'SAME_FUND', 'The fund you are moving from and the fund you are moving to are the same.',
      a.account_id, NULL::varchar, NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  SELECT * INTO ff FROM funds x WHERE x.fund_id = v_from;
  v_held := holding_value(a.account_id, v_from);
  IF ff.fund_id IS NULL OR v_held <= 0 THEN
    RETURN QUERY SELECT FALSE, 'FUND_NOT_HELD', 'You do not hold that fund in account ' || a.account_id || ', so there is nothing to move out of it.',
      a.account_id, NULL::varchar, NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  IF v_amt_txt = 'ALL' THEN v_amt := v_held;
  ELSIF v_amt_txt ~ '^[0-9]+(\.[0-9]+)?$' AND v_amt_txt::numeric > 0 THEN v_amt := round(v_amt_txt::numeric, 2);
  ELSE
    RETURN QUERY SELECT FALSE, 'AMOUNT_INVALID', 'Please give the amount to move as a dollar amount greater than $0, or say all of the holding.',
      a.account_id, NULL::varchar, NULL::varchar, NULL::numeric, NULL::text, NULL::date; RETURN;
  END IF;
  IF v_amt > v_held THEN
    RETURN QUERY SELECT FALSE, 'INSUFFICIENT_HOLDING', 'You hold ' || usd(v_held) || ' in ' || ff.fund_name || ', so you cannot move ' || usd(v_amt) || '.',
      a.account_id, ff.fund_id, tf.fund_id, v_amt, NULL::text, NULL::date; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, a.account_id, ff.fund_id, tf.fund_id, v_amt,
    CASE WHEN v_amt = v_held THEN 'Move your entire ' || ff.fund_name || ' (' || ff.fund_id || ', ' || ff.risk_level || ' risk) holding, '
                                  || usd(v_amt) || ' at today''s price,'
         ELSE 'Move ' || usd(v_amt) || ' from ' || ff.fund_name || ' (' || ff.fund_id || ', ' || ff.risk_level || ' risk)' END
    || ' into ' || tf.fund_name || ' (' || tf.fund_id || ', ' || tf.risk_level || ' risk) in your ' || a.account_type || ' ' || a.account_id
    || ', at the market close on ' || d(next_trade_date()) || '. The final amount depends on that day''s prices.',
    next_trade_date();
END $$ LANGUAGE plpgsql STABLE;

-- =====================================================================
-- TWO-STEP ACTIONS: propose (PROPOSED or BLOCKED, 15-minute expiry) -> confirm (re-check) -> event + trigger
-- =====================================================================
CREATE OR REPLACE FUNCTION propose_contribution_fn(p_token TEXT, p_rate TEXT)
RETURNS TABLE (member_id VARCHAR, action_type VARCHAR, target_key TEXT, account_id VARCHAR, new_rate NUMERIC, outcome VARCHAR,
               reason_code VARCHAR, reason_text TEXT, summary TEXT, effective_date DATE) AS $$
  SELECT sm.member_id, 'CHANGE_CONTRIBUTION_RATE'::varchar, norm_rate(p_rate), e.account_id, e.new_rate,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary, e.effective_date
    FROM session_member(p_token) sm
    CROSS JOIN LATERAL contribution_eval(sm.member_id, p_rate) e
   WHERE sm.member_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.member_id = sm.member_id AND pa.action_type = 'CHANGE_CONTRIBUTION_RATE'
                        AND pa.target_key = norm_rate(p_rate) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM account_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_switch_fn(p_token TEXT, p_account TEXT, p_from TEXT, p_to TEXT, p_amount TEXT)
RETURNS TABLE (member_id VARCHAR, action_type VARCHAR, target_key TEXT, account_id VARCHAR, from_fund VARCHAR, to_fund VARCHAR,
               amount NUMERIC, outcome VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT, effective_date DATE) AS $$
  SELECT sm.member_id, 'FUND_SWITCH'::varchar, switch_key(p_account, p_from, p_to, p_amount), e.account_id, e.from_fund, e.to_fund,
         e.amount, (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary, e.effective_date
    FROM session_member(p_token) sm
    CROSS JOIN LATERAL fund_switch_eval(sm.member_id, p_account, p_from, p_to, p_amount) e
   WHERE sm.member_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.member_id = sm.member_id AND pa.action_type = 'FUND_SWITCH'
                        AND pa.target_key = switch_key(p_account, p_from, p_to, p_amount) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM account_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

-- Shared readback: the caller's latest proposal for this action + normalised request.
CREATE OR REPLACE FUNCTION proposal_result(p_token TEXT, p_action TEXT, p_key TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT,
               effective_date DATE, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         pa.action_type,
         CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sm.member_id IS NULL THEN 'Please verify your identity again (member ID and one-time code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing has changed yet. Reply yes within 15 minutes to go ahead.'
              ELSE pa.reason_text END,
         pa.summary, pa.effective_date, CASE WHEN pa.outcome = 'PROPOSED' THEN pa.expires_at END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.member_id = sm.member_id AND p.action_type = p_action AND p.target_key = p_key
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_contribution_result(p_token TEXT, p_rate TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT,
               effective_date DATE, expires_at TIMESTAMP) AS $$
  SELECT * FROM proposal_result(p_token, 'CHANGE_CONTRIBUTION_RATE', norm_rate(p_rate))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_switch_result(p_token TEXT, p_account TEXT, p_from TEXT, p_to TEXT, p_amount TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, action_type VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT,
               effective_date DATE, expires_at TIMESTAMP) AS $$
  SELECT * FROM proposal_result(p_token, 'FUND_SWITCH', switch_key(p_account, p_from, p_to, p_amount))
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm: re-checks EVERY rule; returns the account_events row only when executable.
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, member_id VARCHAR, action_type VARCHAR, account_id VARCHAR,
               new_rate NUMERIC, from_fund VARCHAR, to_fund VARCHAR, amount NUMERIC, effective_date DATE, summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  v_mem TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev account_events;
  ok BOOLEAN; rc TEXT; rt TEXT; sm TEXT; ed DATE; v_id BIGINT; v_reference TEXT;
BEGIN
  SELECT s.member_id INTO v_mem FROM session_member(p_token) s;
  IF v_mem IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.member_id = v_mem;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (member_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_mem, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal on your account. Nothing was changed.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM account_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (member_id, proposal_ref, outcome, reason_text, reference, summary, effective_date)
      VALUES (v_mem, v_ref, 'ALREADY_DONE', 'This was already done earlier (reference ' || ev.reference || '). Nothing new was changed.',
              ev.reference, ev.summary, ev.effective_date);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (member_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_mem, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (member_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_mem, v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was changed. I can set it up again.', pa.summary);
    RETURN;
  END IF;
  IF pa.action_type = 'CHANGE_CONTRIBUTION_RATE' THEN
    SELECT e.ok, e.reason_code, e.reason_text, e.summary, e.effective_date INTO ok, rc, rt, sm, ed
      FROM contribution_eval(v_mem, pa.new_rate::text) e;
  ELSE
    SELECT e.ok, e.reason_code, e.reason_text, e.summary, e.effective_date INTO ok, rc, rt, sm, ed
      FROM fund_switch_eval(v_mem, pa.account_id, pa.from_fund, pa.to_fund, pa.amount::text) e;
  END IF;
  IF NOT ok THEN
    INSERT INTO confirm_attempts (member_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_mem, v_ref, 'BLOCKED', rc, rt, pa.summary);
    RETURN;
  END IF;
  v_id := nextval(pg_get_serial_sequence('account_events', 'event_id'));
  v_reference := 'HLR-ACT-' || lpad(v_id::text, 6, '0');
  INSERT INTO confirm_attempts (member_id, proposal_ref, outcome, reason_text, reference, summary, effective_date)
    VALUES (v_mem, v_ref, 'EXECUTED', 'Done.', v_reference, sm, ed);
  RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, v_mem::varchar, pa.action_type, pa.account_id,
                      pa.new_rate, pa.from_fund, pa.to_fund, pa.amount, ed, sm;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT, effective_date DATE) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         ca.reference,
         CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN sm.member_id IS NULL THEN 'Please verify your identity again (member ID and one-time code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that proposal on your account. Nothing was changed.'
              ELSE ca.reason_text END,
         ca.summary, ca.effective_date
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN LATERAL (SELECT a.* FROM confirm_attempts a
                        WHERE a.member_id = sm.member_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) ca ON TRUE
$$ LANGUAGE sql STABLE;

-- Side effects of an executed action - atomic with the event row. Never an UPDATE from a tool.
CREATE OR REPLACE FUNCTION apply_account_event() RETURNS TRIGGER AS $$
DECLARE a retirement_accounts; ff funds; tf funds; v_units NUMERIC; v_held NUMERIC;
BEGIN
  SELECT * INTO a FROM retirement_accounts x WHERE x.account_id = NEW.account_id;
  IF NEW.action_type = 'CHANGE_CONTRIBUTION_RATE' THEN
    INSERT INTO rate_changes (account_id, from_rate, to_rate, effective_date, source_reference)
      VALUES (a.account_id, a.contribution_rate, NEW.new_rate, NEW.effective_date, NEW.reference);
    UPDATE retirement_accounts SET contribution_rate = NEW.new_rate WHERE account_id = NEW.account_id;
  ELSIF NEW.action_type = 'FUND_SWITCH' THEN
    SELECT * INTO ff FROM funds WHERE fund_id = NEW.from_fund;
    SELECT * INTO tf FROM funds WHERE fund_id = NEW.to_fund;
    v_held := holding_value(NEW.account_id, NEW.from_fund);
    SELECT h.units INTO v_units FROM holdings h WHERE h.account_id = NEW.account_id AND h.fund_id = NEW.from_fund;
    IF NEW.amount < v_held THEN v_units := round(NEW.amount / ff.nav, 4); END IF;     -- whole holding: move every unit
    UPDATE holdings SET units = greatest(units - v_units, 0) WHERE account_id = NEW.account_id AND fund_id = NEW.from_fund;
    INSERT INTO holdings (account_id, fund_id, units) VALUES (NEW.account_id, NEW.to_fund, round(NEW.amount / tf.nav, 4))
      ON CONFLICT (account_id, fund_id) DO UPDATE SET units = holdings.units + EXCLUDED.units;
  END IF;
  PERFORM audit('ACTION_EXECUTED', NEW.member_id, NEW.reference, NEW.summary);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_account_event AFTER INSERT ON account_events FOR EACH ROW EXECUTE FUNCTION apply_account_event();

-- =====================================================================
-- FILE A CLAIM - the filing is deterministic; paying it is a claims examiner's decision (claim_decision case)
-- =====================================================================
CREATE OR REPLACE FUNCTION file_claim_row(p_token TEXT, p_policy TEXT, p_type TEXT, p_description TEXT, p_documents TEXT)
RETURNS TABLE (claim_id VARCHAR, policy_id VARCHAR, member_id VARCHAR, claim_type VARCHAR, amount NUMERIC, status VARCHAR,
               filed_date DATE, description TEXT, documents_needed TEXT, source VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_mem TEXT; v_ref TEXT := norm_ref(p_policy); v_type TEXT := norm_claim_type(p_type); p policies; v_open TEXT; v_claim TEXT;
BEGIN
  SELECT s.member_id INTO v_mem FROM session_member(p_token) s;
  IF v_mem IS NULL THEN RETURN; END IF;
  SELECT * INTO p FROM policies x WHERE x.policy_id = v_ref AND x.member_id = v_mem;
  IF NOT FOUND THEN
    INSERT INTO file_claim_attempts (member_id, policy_ref, outcome, reason_code, reason_text)
      VALUES (v_mem, v_ref, 'BLOCKED', 'NOT_FOUND', 'I could not find that policy among your Harborline policies, so no claim was filed.');
    RETURN;
  END IF;
  IF p.status <> 'Active' THEN
    INSERT INTO file_claim_attempts (member_id, policy_ref, outcome, reason_code, reason_text)
      VALUES (v_mem, v_ref, 'BLOCKED', 'POLICY_NOT_ACTIVE',
              'Your ' || p.product_name || ' policy ' || p.policy_id || ' is ' || lower(p.status)
              || CASE p.status WHEN 'Lapsed' THEN ' (since ' || d(p.status_date) || ', after missed premiums)'
                               WHEN 'Pending' THEN ' (underwriting is not finished)' ELSE '' END
              || ', so its cover is not in force and a claim cannot be filed on it in chat. A person can talk you through your options - I can open a complaint or a request for a call back.');
    RETURN;
  END IF;
  IF p.product_type IN ('TermLife','WholeLife') OR v_type <> p.product_type THEN
    INSERT INTO file_claim_attempts (member_id, policy_ref, outcome, reason_code, reason_text)
      VALUES (v_mem, v_ref, 'BLOCKED', 'CLAIM_TYPE_MISMATCH',
              CASE WHEN p.product_type IN ('TermLife','WholeLife')
                   THEN 'Life insurance claims are made by the beneficiary after a death, with a certified death certificate. They are not filed in this chat; our Claims Examination team can help the family directly.'
                   ELSE 'Policy ' || p.policy_id || ' is ' || product_label(p.product_type) || ' cover, so it cannot pay a '
                        || coalesce(product_label(nullif(v_type, '')), 'claim of that') || ' claim. No claim was filed.' END);
    RETURN;
  END IF;
  SELECT c.claim_id INTO v_open FROM claims c WHERE c.policy_id = p.policy_id AND c.status IN ('Submitted','UnderReview') LIMIT 1;
  IF v_open IS NOT NULL THEN
    INSERT INTO file_claim_attempts (member_id, policy_ref, outcome, reason_code, reason_text, claim_id)
      VALUES (v_mem, v_ref, 'BLOCKED', 'DUPLICATE_OPEN_CLAIM',
              'You already have an open claim (' || v_open || ') on policy ' || p.policy_id || ', so no new claim was filed. A claims examiner is working on it.', v_open);
    RETURN;
  END IF;
  v_claim := 'CLM-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('claim_seq')::text, 4, '0');
  INSERT INTO file_claim_attempts (member_id, policy_ref, outcome, reason_text, claim_id)
    VALUES (v_mem, v_ref, 'FILED', 'Your claim is filed. A claims examiner will review it and decide; I cannot predict the outcome.', v_claim);
  RETURN QUERY SELECT v_claim::varchar, p.policy_id, v_mem::varchar, p.product_type, p.coverage_amount, 'Submitted'::varchar,
                      current_date, left(coalesce(nullif(trim(p_description), ''), '(no description given)'), 2000),
                      left(nullif(trim(p_documents), ''), 1000), 'CHAT'::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

-- A claim filed in chat opens the claim_decision case for Claims Examination (routing + SLA from case_routing).
CREATE OR REPLACE FUNCTION apply_claim_filed() RETURNS TRIGGER AS $$
DECLARE r case_routing; v_no BIGINT; v_case TEXT;
BEGIN
  SELECT * INTO r FROM case_routing WHERE request_type = 'claim_decision';
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'HLR-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO service_cases (case_no, case_id, member_id, request_type, summary, reference_id, requested_amount, parked_action,
                             agent_brief, sla_due_at)
    VALUES (v_no, v_case, NEW.member_id, 'claim_decision', NEW.description, NEW.claim_id, NEW.amount, 'CLAIM_DECISION:' || NEW.claim_id,
            'Claim intake (AI-prepared, not verified): claim type ' || product_label(NEW.claim_type)
            || coalesce('. Documents to request: ' || NEW.documents_needed, '') || '.',
            add_business_days(clock_timestamp()::timestamp, r.sla_business_days));
  UPDATE file_claim_attempts SET case_id = v_case WHERE claim_id = NEW.claim_id AND outcome = 'FILED';
  PERFORM audit('CLAIM_FILED', NEW.member_id, NEW.claim_id, product_label(NEW.claim_type) || ' claim on ' || NEW.policy_id || ', ' || usd(NEW.amount));
  PERFORM audit('CASE_OPENED', NEW.member_id, v_case, 'claim_decision for ' || NEW.claim_id);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_claim_filed AFTER INSERT ON claims FOR EACH ROW WHEN (NEW.source = 'CHAT') EXECUTE FUNCTION apply_claim_filed();

CREATE OR REPLACE FUNCTION file_claim_result(p_token TEXT, p_policy TEXT)
RETURNS TABLE (outcome TEXT, claim_id VARCHAR, case_id VARCHAR, claim_type VARCHAR, benefit_amount NUMERIC, team VARCHAR,
               sla_text VARCHAR, reply_due DATE, reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(fa.outcome, 'BLOCKED') END,
         CASE WHEN fa.outcome = 'FILED' THEN fa.claim_id END,
         CASE WHEN fa.outcome = 'FILED' THEN fa.case_id END,
         CASE WHEN fa.outcome = 'FILED' THEN c.claim_type END,
         CASE WHEN fa.outcome = 'FILED' THEN c.amount END,
         CASE WHEN fa.outcome = 'FILED' THEN r.team END,
         CASE WHEN fa.outcome = 'FILED' THEN r.sla_text END,
         CASE WHEN fa.outcome = 'FILED' THEN s.sla_due_at::date END,
         CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' WHEN fa.attempt_id IS NULL THEN 'NOT_FOUND' ELSE fa.reason_code END,
         CASE WHEN sm.member_id IS NULL THEN 'Please verify your identity again (member ID and one-time code).'
              WHEN fa.attempt_id IS NULL THEN 'No claim was filed.' ELSE fa.reason_text END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN LATERAL (SELECT a.* FROM file_claim_attempts a WHERE a.member_id = sm.member_id AND a.policy_ref = norm_ref(p_policy)
                        ORDER BY a.attempt_id DESC LIMIT 1) fa ON TRUE
    LEFT JOIN claims c ON c.claim_id = fa.claim_id
    LEFT JOIN service_cases s ON s.case_id = fa.case_id
    LEFT JOIN case_routing r ON r.request_type = 'claim_decision'
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_summary TEXT, p_ref TEXT, p_amount TEXT, p_brief TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, member_id VARCHAR, request_type VARCHAR, summary TEXT, reference_id VARCHAR,
               requested_amount NUMERIC, parked_action VARCHAR, agent_brief TEXT, sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_mem TEXT; v_type TEXT := norm_request_type(p_type); v_ref TEXT := nullif(norm_ref(p_ref), ''); r case_routing;
        v_amt NUMERIC; v_amt_txt TEXT := norm_amount(p_amount); v_parked TEXT; v_existing TEXT; v_no BIGINT; v_case TEXT; v_vested NUMERIC;
        c claims;
BEGIN
  SELECT s.member_id INTO v_mem FROM session_member(p_token) s;
  IF v_mem IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM case_routing x WHERE x.request_type = v_type AND x.member_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (member_id, request_type, reference_id, outcome, reason_code) VALUES (v_mem, v_type, v_ref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  IF v_type = 'claim_appeal' THEN
    SELECT * INTO c FROM claims x WHERE x.claim_id = v_ref AND x.member_id = v_mem;
    IF NOT FOUND OR c.status <> 'Denied' THEN
      INSERT INTO case_requests (member_id, request_type, reference_id, outcome, reason_code) VALUES (v_mem, v_type, v_ref, 'BLOCKED', 'NOT_APPEALABLE');
      RETURN;
    END IF;
    v_amt := c.amount; v_parked := 'CLAIM_APPEAL:' || c.claim_id;
  ELSIF v_type = 'withdrawal_rollover' THEN
    IF NOT EXISTS (SELECT 1 FROM retirement_accounts x WHERE x.account_id = v_ref AND x.member_id = v_mem) THEN
      INSERT INTO case_requests (member_id, request_type, reference_id, outcome, reason_code) VALUES (v_mem, v_type, v_ref, 'BLOCKED', 'NOT_FOUND');
      RETURN;
    END IF;
    v_vested := vested_balance(v_ref);
    v_amt := CASE WHEN v_amt_txt = 'ALL' THEN v_vested WHEN v_amt_txt ~ '^[0-9]+(\.[0-9]+)?$' THEN round(v_amt_txt::numeric, 2) END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_vested THEN
      INSERT INTO case_requests (member_id, request_type, reference_id, outcome, reason_code) VALUES (v_mem, v_type, v_ref, 'BLOCKED', 'AMOUNT_INVALID');
      RETURN;
    END IF;
    v_parked := 'WITHDRAWAL:' || v_ref;
  ELSIF v_type = 'beneficiary_change' AND v_ref IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM policies x WHERE x.policy_id = v_ref AND x.member_id = v_mem) THEN
    INSERT INTO case_requests (member_id, request_type, reference_id, outcome, reason_code) VALUES (v_mem, v_type, v_ref, 'BLOCKED', 'NOT_FOUND');
    RETURN;
  END IF;
  IF v_type NOT IN ('claim_appeal','withdrawal_rollover','beneficiary_change') THEN v_ref := NULL; END IF;
  SELECT s.case_id INTO v_existing FROM service_cases s
   WHERE s.member_id = v_mem AND s.request_type = v_type AND s.status = 'OPEN'
     AND (v_type NOT IN ('claim_appeal','withdrawal_rollover') OR s.reference_id = v_ref)
   ORDER BY s.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (member_id, request_type, reference_id, outcome, case_id) VALUES (v_mem, v_type, v_ref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'HLR-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (member_id, request_type, reference_id, outcome, case_id) VALUES (v_mem, v_type, v_ref, 'OPENED', v_case);
  PERFORM audit('CASE_OPENED', v_mem, v_case, v_type || coalesce(' for ' || v_ref, ''));
  RETURN QUERY SELECT v_no, v_case::varchar, v_mem::varchar, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_ref::varchar, v_amt,
                      v_parked::varchar, left(nullif(trim(p_brief), ''), 4000),
                      add_business_days(clock_timestamp()::timestamp, r.sla_business_days);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due DATE,
               requested_amount NUMERIC, reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.team, rt.sla_text, s.sla_due_at::date, s.requested_amount,
         CASE WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN sm.member_id IS NULL THEN 'Please verify your identity again (member ID and one-time code).'
              WHEN cr.outcome = 'OPENED' THEN 'Your case is open. A person on our ' || rt.team || ' team will review your request and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' case, so no new case was opened. Our ' || rt.team || ' team is on it.'
              WHEN cr.reason_code = 'NOT_APPEALABLE' THEN 'Only one of your own claims that was denied can be appealed. I could not find a denied claim with that number on your account.'
              WHEN cr.reason_code = 'NOT_FOUND' THEN 'I could not find that account or policy on your membership, so no case was opened.'
              WHEN cr.reason_code = 'AMOUNT_INVALID' THEN 'The amount must be more than $0 and no more than the vested balance of that account. No case was opened.'
              ELSE 'That is not a request I can open a case for here. A person can help with beneficiary changes, claim appeals, withdrawals and rollovers, investment advice and complaints.' END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.member_id = sm.member_id AND q.request_type = norm_request_type(p_type)
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
CREATE OR REPLACE FUNCTION member_display(p_member TEXT) RETURNS TEXT AS $$
  SELECT m.first_name || ' ' || left(m.last_name, 1) || '.' FROM members m WHERE m.member_id = p_member
$$ LANGUAGE sql STABLE;

-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN split_part(s.parked_action, ':', 1) IN ('CLAIM_DECISION','CLAIM_APPEAL')
                THEN (SELECT c.amount FROM claims c WHERE c.claim_id = split_part(s.parked_action, ':', 2))
              WHEN split_part(s.parked_action, ':', 1) = 'WITHDRAWAL'
                THEN least(s.requested_amount, vested_balance(split_part(s.parked_action, ':', 2)))
              ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no SSN, email, date of birth or full last name).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE
    WHEN split_part(s.parked_action, ':', 1) IN ('CLAIM_DECISION','CLAIM_APPEAL') THEN
      'Claim ' || c.claim_id || ' - ' || product_label(c.claim_type) || ' on ' || p.product_name || ' ' || p.policy_id
      || ' (policy ' || lower(p.status) || ', in force since ' || d(p.start_date) || ')'
      || '; benefit claimed ' || usd(c.amount) || CASE WHEN c.claim_type = 'IncomeProtection' THEN ' per month' ELSE ' lump sum' END
      || '; filed ' || d(c.filed_date) || coalesce('; recorded date stopped work / diagnosed ' || d(c.incident_date), '')
      || coalesce('; waiting period ' || p.waiting_period_days || ' days', '')
      || '; claim status ' || c.status || coalesce(' (' || c.denial_reason_code || ': ' || c.denial_reason_text || ')', '')
      || '; other claims by this member on file: ' || (SELECT count(*) FROM claims o WHERE o.member_id = s.member_id AND o.claim_id <> c.claim_id)
    WHEN split_part(s.parked_action, ':', 1) = 'WITHDRAWAL' THEN
      a.account_type || ' ' || a.account_id || ' - balance ' || usd(account_balance(a.account_id)) || ', vested ' || usd(vested_balance(a.account_id))
      || ' (' || pct(a.vested_pct) || ' vested); member age ' || age_years(m.date_of_birth)
      || CASE WHEN age_years(m.date_of_birth) >= 60 THEN ' (over 59 1/2: no IRS early-withdrawal penalty)' ELSE ' (under 59 1/2: a 10% IRS early-withdrawal penalty may apply)' END
    WHEN s.request_type = 'beneficiary_change' THEN
      coalesce('Policy ' || bp.policy_id || ' - ' || bp.product_name || '; current beneficiaries: '
               || (SELECT string_agg(b.beneficiary_name || ' (' || b.relationship || ', ' || pct(b.share_pct) || ', ' || b.designation || ')', '; ')
                     FROM beneficiaries b WHERE b.policy_id = bp.policy_id), 'No policy given')
      || '; member marital status on file: ' || m.marital_status || '. A signed beneficiary form is required.'
    ELSE 'No linked record.' END
    FROM service_cases s
    JOIN members m ON m.member_id = s.member_id
    LEFT JOIN claims c ON c.claim_id = split_part(s.parked_action, ':', 2) AND split_part(s.parked_action, ':', 1) LIKE 'CLAIM%'
    LEFT JOIN policies p ON p.policy_id = c.policy_id
    LEFT JOIN retirement_accounts a ON a.account_id = split_part(s.parked_action, ':', 2) AND split_part(s.parked_action, ':', 1) = 'WITHDRAWAL'
    LEFT JOIN policies bp ON bp.policy_id = s.reference_id AND s.request_type = 'beneficiary_change'
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, member VARCHAR, opened_on DATE, age_days INTEGER,
               reply_due DATE, sla_status TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.member, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, r.label, member_display(s.member_id)::varchar AS member, s.created_at::date AS opened_on,
             (current_date - s.created_at::date)::int AS age_days, s.sla_due_at::date AS reply_due,
             CASE WHEN s.sla_due_at::date < current_date THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.sla_due_at
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND r.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, member VARCHAR, opened_on DATE, reply_due DATE,
               member_statement TEXT, agent_brief TEXT, requested_amount NUMERIC, max_approvable NUMERIC, your_approval_limit NUMERIC,
               facts TEXT, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.label, s.status, member_display(s.member_id)::varchar, s.created_at::date, s.sla_due_at::date,
         s.summary, s.agent_brief, s.requested_amount, case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.requested_amount IS NOT NULL THEN 'APPROVE (any amount up to ' || usd(case_eligible_max(s.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN '; above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer' ELSE '' END
                   || ') or REJECT, with an internal note and a message for the member.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the member.' END,
         s.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
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
        v_amt_txt TEXT := norm_amount(p_amount); v_msg TEXT;
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
  IF v_dec = 'APPROVE' AND s.requested_amount IS NOT NULL THEN
    v_max := case_eligible_max(s.case_id);
    v_amt := CASE WHEN v_amt_txt = '' THEN v_max WHEN v_amt_txt ~ '^-?[0-9]+(\.[0-9]+)?$' THEN round(v_amt_txt::numeric, 2) END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The approved amount must be more than $0 and no more than ' || usd(v_max) || ' for this case.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', usd(v_amt) || ' is above your approval limit of ' || usd(rv.approval_limit)
                || '. The case stays open and needs a senior reviewer.');
      RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || r.label || ' has been approved' || coalesce(' for ' || usd(v_amt), '') || '.'
                  ELSE 'After review, your ' || r.label || ' was not approved. We will send you a letter that explains the decision.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.approved_amount END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND' AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'Claim ' || cp.claim_id || ' approved; payment ' || cp.reference || ' of ' || usd(cp.amount) || ' posted.'
                            FROM claim_payments cp WHERE cp.case_id = s.case_id),
                         (SELECT 'Withdrawal ' || w.reference || ' of ' || usd(w.amount) || ' from ' || w.account_id || ' processed.'
                            FROM withdrawals w WHERE w.case_id = s.case_id),
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
CREATE OR REPLACE FUNCTION claim_payment_row(p_claim TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (reference VARCHAR, claim_id VARCHAR, amount NUMERIC, case_id VARCHAR) AS $$
  SELECT ('HLR-PAY-' || lpad(nextval(pg_get_serial_sequence('claim_payments', 'payment_id'))::text, 6, '0'))::varchar,
         c.claim_id, p_amount, p_case::varchar
    FROM claims c
   WHERE c.claim_id = p_claim AND c.status IN ('Submitted','UnderReview','Denied')
     AND p_amount > 0 AND p_amount <= c.amount
     AND NOT EXISTS (SELECT 1 FROM claim_payments x WHERE x.claim_id = c.claim_id)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION withdrawal_row(p_account TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (reference VARCHAR, account_id VARCHAR, amount NUMERIC, case_id VARCHAR) AS $$
  SELECT ('HLR-WDR-' || lpad(nextval(pg_get_serial_sequence('withdrawals', 'withdrawal_id'))::text, 6, '0'))::varchar,
         a.account_id, p_amount, p_case::varchar
    FROM retirement_accounts a
   WHERE a.account_id = p_account AND p_amount > 0 AND p_amount <= vested_balance(a.account_id)
$$ LANGUAGE sql VOLATILE;

-- The decision event: case status + member message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF v_kind IN ('CLAIM_DECISION','CLAIM_APPEAL') AND NEW.decision = 'APPROVE' THEN
    INSERT INTO claim_payments (reference, claim_id, amount, case_id) SELECT * FROM claim_payment_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN
      UPDATE claims SET status = 'Approved', approved_amount = NEW.approved_amount, decided_at = NEW.decided_at WHERE claim_id = v_ref;
      v_done := 'claim ' || v_ref || ' approved and paid ' || usd(NEW.approved_amount);
    END IF;
  ELSIF v_kind = 'CLAIM_DECISION' AND NEW.decision = 'REJECT' THEN
    UPDATE claims SET status = 'Denied', denial_reason_code = 'EXAMINER_DECISION', denial_reason_text = NEW.customer_message,
           decided_at = NEW.decided_at WHERE claim_id = v_ref;
    v_done := 'claim ' || v_ref || ' denied';
  ELSIF v_kind = 'WITHDRAWAL' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO withdrawals (reference, account_id, amount, case_id) SELECT * FROM withdrawal_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'withdrawal of ' || usd(NEW.approved_amount) || ' from ' || v_ref; END IF;
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id, NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- A withdrawal reduces every holding in the account pro rata (balance = units x NAV).
CREATE OR REPLACE FUNCTION apply_withdrawal() RETURNS TRIGGER AS $$
DECLARE v_bal NUMERIC := account_balance(NEW.account_id);
BEGIN
  IF v_bal > 0 THEN
    UPDATE holdings SET units = round(units * (1 - NEW.amount / v_bal), 4) WHERE account_id = NEW.account_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_withdrawal AFTER INSERT ON withdrawals FOR EACH ROW EXECUTE FUNCTION apply_withdrawal();

-- =====================================================================
-- EMAIL - only for the caller's executed action (HLR-ACT-), claim filed in chat (CLM-) or decided case (HLR-CASE-)
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_reference TEXT)
RETURNS TABLE (member_id VARCHAR, reference VARCHAR, kind TEXT, subject TEXT, detail TEXT) AS $$
  SELECT sm.member_id, x.reference::varchar, x.kind, x.subject, x.detail
    FROM session_member(p_token) sm
    JOIN LATERAL (
      SELECT ae.reference::text AS reference, 'action' AS kind, 'Harborline confirmation ' || ae.reference AS subject,
             ae.summary || ' Reference: ' || ae.reference || '. Done on ' || to_char(ae.created_at, 'YYYY-MM-DD HH24:MI') || '.' AS detail
        FROM account_events ae WHERE ae.member_id = sm.member_id AND ae.reference = norm_ref(p_reference)
      UNION ALL
      SELECT c.claim_id, 'claim', 'Harborline claim received ' || c.claim_id,
             'We received your ' || product_label(c.claim_type) || ' claim ' || c.claim_id || ' on policy ' || c.policy_id || ' on '
             || d(c.filed_date) || '. A claims examiner will review it and decide.'
             || coalesce(' Documents we may ask for: ' || c.documents_needed || '.', '')
        FROM claims c WHERE c.member_id = sm.member_id AND c.claim_id = norm_ref(p_reference) AND c.source = 'CHAT'
      UNION ALL
      SELECT s.case_id, 'decision', 'Harborline decision on case ' || s.case_id,
             'Our ' || r.team || ' team has decided your ' || r.label || ' (case ' || s.case_id || '): ' || lower(s.status) || '. '
             || s.customer_message
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE s.member_id = sm.member_id AND s.case_id = norm_ref(p_reference)
         AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = s.case_id)) x ON TRUE
   WHERE sm.member_id IS NOT NULL
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (member_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT e.member_id, e.reference, e.subject FROM email_source(p_token, p_reference) e
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.reference IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.reference IS NOT NULL THEN NULL WHEN sm.member_id IS NULL THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN e.reference IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN sm.member_id IS NULL THEN 'Please verify your identity again (member ID and one-time code).'
              ELSE 'There is no completed change, filed claim or decided case with that reference on your account, so no email was sent.' END,
         e.reference,
         coalesce(e.subject, 'Harborline confirmation - not sent'),
         CASE WHEN e.reference IS NOT NULL THEN
           'Hi ' || m.first_name || ',' || chr(10) || chr(10)
           || 'This is a confirmation from Ella, the Harborline Life & Retirement assistant.' || chr(10) || chr(10)
           || e.detail || chr(10) || chr(10)
           || 'Thank you for being a Harborline member.'
           ELSE 'No confirmation email was sent for reference ' || norm_ref(p_reference) || '.' END
    FROM (SELECT * FROM session_member(p_token)) sm
    LEFT JOIN members m ON m.member_id = sm.member_id
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

CREATE OR REPLACE FUNCTION ref_claim_checklist(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM claim_intake_guide g
          UNION ALL                                 -- who decides a filed claim: case_routing is the source of truth
          SELECT 'WHO_DECIDES', c.label::text, c.team::text || ': ' || c.sla_text::text, 1000
            FROM case_routing c WHERE c.request_type = 'claim_decision') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CLAIM_TYPE','PRODUCT','DOCUMENT','WAITING_PERIOD','WHO_DECIDES','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_life_event(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM life_event_guide g
          UNION ALL                                 -- who helps with what: case_routing is the source of truth
          SELECT 'WHO_HELPS', c.label::text, c.team::text || ': ' || c.sla_text::text, 1000
            FROM case_routing c WHERE c.request_type IN ('beneficiary_change', 'withdrawal_rollover', 'investment_advice')) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['LIFE_EVENT','RELATIONSHIP','DESIGNATION','SPOUSAL_CONSENT','WHO_HELPS','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_appeal_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM appeal_review_guide g
          UNION ALL                                 -- who reviews an appeal: case_routing is the source of truth
          SELECT 'WHO_DECIDES', c.label::text, c.team::text || ': ' || c.sla_text::text, 1000
            FROM case_routing c WHERE c.request_type = 'claim_appeal') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['DENIAL_REASON','WAITING_PERIOD','NEW_EVIDENCE','FAIR_REVIEW','WHO_DECIDES','BRIEF_RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
