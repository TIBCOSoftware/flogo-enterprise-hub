-- Copperleaf Auto Insurance - Auto Policy & Claims Assistant "Riley" (GOVERNED, RAG) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: auto_insurance_governed
-- Load:  createdb auto_insurance_governed  &&  psql -v ON_ERROR_STOP=1 -d auto_insurance_governed -f database.sql
--
-- =====================================================================
-- Fictional US personal-auto insurer "Copperleaf Auto Insurance", assistant "Riley".
-- Facts come from this database; policy wording comes from the documents (search_policy_wording, RAG).
-- The rules live HERE, not in any prompt:
--   * session_customer() / session_reviewer()  identity: every tool is scoped by a session token; customer and
--                                              reviewer tokens are not interchangeable (role checked)
--   * verify_*_fn()                            identifier + one-time code -> session; 5 failures / 15 min -> LOCKED
--   * my_*()                                   scoped reads - only the caller's rows; another customer's id -> NOT_FOUND
--   * claim_eval()                             policy in force, claim type, incident date in period, coverage held,
--                                              amount, duplicate; deductible + claims-free-discount impact
--   * claim_signals()                          the auditable claim-signal points (S1..S8) + review_signals text
--   * propose_claim_fn() -> record_assessment_row() -> confirm_claim_row()
--                                              two-step first notice of loss; confirm re-checks, bands and routes
--   * trg_claim_filed                          opens the claim_review / special_investigation case + audit
--   * open_case_row()                          human-owned requests routed by case_routing (team + SLA)
--   * decide_case_row() + trg_review_decision  the reviewer loop: role/team/authority/amount checks, then the
--                                              parked claim payment runs through claim_payment_row()
--   * email_log_row()                          email only for the caller's filed claim / decided case
--   * ref_fnol_checklist() / ref_coverage_clauses() / ref_claim_indicators()
--                                              the A2A agents' ONLY database access: read-only reference tables
--                                              (claim types + FNOL fields, coverage clause index + exclusion
--                                              categories, narrative indicators + weights) with no policyholder,
--                                              staff, policy, claim, case or session data; one optional lookup
--                                              term, never an identity. Signal points and bands stay in SQL.
-- Hidden from customers: email, date_of_birth, one_time_code, internal_note, agent_brief, reviewer identity,
-- approval limits, parked actions, signal points, narrative / risk scores, risk band, indicators, payment hold.
-- Money: USD. All demo dates are relative to CURRENT_DATE (seed_data.sql).
-- document_index (the RAG vector-store handoff) is NEVER dropped here and never truncated by reset_data.sql.
-- =====================================================================

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid() on PostgreSQL < 13

-- Re-runnable: drop this use case's functions first (CREATE OR REPLACE cannot change a return type).
-- The two RAG handoff functions are kept (re-created verbatim below) so the ingestion app is never interrupted.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.prokind = 'f'
              AND p.proname NOT IN ('record_vector_store', 'latest_vector_store')
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END $$;

DROP TABLE IF EXISTS email_log CASCADE;
DROP TABLE IF EXISTS agent_audit CASCADE;
DROP TABLE IF EXISTS claim_payments CASCADE;
DROP TABLE IF EXISTS decide_attempts CASCADE;
DROP TABLE IF EXISTS review_decisions CASCADE;
DROP TABLE IF EXISTS case_requests CASCADE;
DROP TABLE IF EXISTS service_cases CASCADE;
DROP TABLE IF EXISTS confirm_attempts CASCADE;
DROP TABLE IF EXISTS assessment_attempts CASCADE;
DROP TABLE IF EXISTS claim_assessments CASCADE;
DROP TABLE IF EXISTS pending_claims CASCADE;
DROP TABLE IF EXISTS claims CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS coverages CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;
DROP TABLE IF EXISTS verify_attempts CASCADE;
DROP TABLE IF EXISTS sessions CASCADE;
DROP TABLE IF EXISTS policies CASCADE;
DROP TABLE IF EXISTS reviewers CASCADE;
DROP TABLE IF EXISTS policyholders CASCADE;
DROP TABLE IF EXISTS fnol_intake_guide CASCADE;
DROP TABLE IF EXISTS coverage_clause_index CASCADE;
DROP TABLE IF EXISTS claim_indicator_guide CASCADE;
DROP TABLE IF EXISTS case_routing CASCADE;
DROP SEQUENCE IF EXISTS claim_seq;

-- ---------------------------------------------------------------------
-- RAG handoff (owned by the ingestion app). Never dropped by database.sql, never truncated by reset_data.sql.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS document_index (
    index_id        SERIAL PRIMARY KEY,
    vector_store_id VARCHAR(80) NOT NULL,
    store_name      VARCHAR(80) NOT NULL,
    files_ingested  INTEGER     NOT NULL DEFAULT 0,
    ingested_at     TIMESTAMP   NOT NULL DEFAULT now()
);
-- Guarded insert used by AutoInsuranceRAGIngestion: 0 rows unless the id looks like an OpenAI vector store id.
CREATE OR REPLACE FUNCTION record_vector_store(p_vs TEXT, p_name TEXT, p_files TEXT)
RETURNS TABLE (vector_store_id VARCHAR, store_name VARCHAR, files_ingested INTEGER) AS $$
    SELECT trim(p_vs)::VARCHAR,
           COALESCE(NULLIF(trim(p_name), ''), 'CopperleafAutoPolicyKB')::VARCHAR,
           COALESCE(NULLIF(regexp_replace(COALESCE(p_files, ''), '[^0-9]', '', 'g'), '')::INTEGER, 0)
    WHERE trim(COALESCE(p_vs, '')) ~ '^vs_[A-Za-z0-9_]+$'
$$ LANGUAGE sql;
-- Scoped read used by the search_policy_wording MCP tool: the newest vector store id.
CREATE OR REPLACE FUNCTION latest_vector_store()
RETURNS TABLE (vector_store_id VARCHAR, store_name VARCHAR, ingested_at TEXT) AS $$
    SELECT d.vector_store_id, d.store_name, to_char(d.ingested_at, 'YYYY-MM-DD HH24:MI')
    FROM document_index d ORDER BY d.index_id DESC LIMIT 1
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Routing: human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
-- ---------------------------------------------------------------------
CREATE TABLE case_routing (
  request_type      VARCHAR(30) PRIMARY KEY,
  label             VARCHAR(40) NOT NULL,        -- customer-facing request name
  staff_label       VARCHAR(40) NOT NULL,        -- reviewer-facing request name
  team              VARCHAR(40) NOT NULL,        -- internal team (matches reviewers.team)
  customer_team     VARCHAR(40) NOT NULL,        -- customer-facing team name
  sla_business_days INTEGER NOT NULL,
  sla_text          VARCHAR(160) NOT NULL,       -- customer-facing
  customer_openable BOOLEAN NOT NULL DEFAULT TRUE -- claim_review / special_investigation are opened only by confirm_claim
);

-- ---------------------------------------------------------------------
-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO policyholder, staff, vehicle, policy, claim, case, session or contact
-- data, ever. The "who decides" rows are NOT copied here: the ref_* functions read them from case_routing (one
-- source of truth). The full policy wording stays in the documents (RAG search_policy_wording); the clause index
-- only points into it. Signal points, the combined risk score and the bands stay in claim_signals() / claim_route().
-- ---------------------------------------------------------------------
CREATE TABLE fnol_intake_guide (                 -- fnol_intake_agent: claim types, FNOL fields, per-type details
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('CLAIM_TYPE', 'FNOL_FIELD', 'TYPE_DETAIL', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- Glass / incident_date
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE coverage_clause_index (             -- coverage_interpreter_agent: coverages, tiers, exclusions, findings
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('COVERAGE', 'PRODUCT_TIER', 'EXCLUSION', 'TERM', 'FINDING')),
  term        VARCHAR(60) NOT NULL,              -- Full Glass / water ingestion in flood water
  meaning     VARCHAR(400) NOT NULL,             -- what it means + where the clause is in the wording
  UNIQUE (section, term)
);

CREATE TABLE claim_indicator_guide (             -- fraud_signal_agent: narrative indicators + weights, score bands
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('INDICATOR', 'SCORE_BAND', 'SIGNAL', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- staged-accident pattern / 50-80 / report_delay_days
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- People: policyholders and reviewers (staff)
-- ---------------------------------------------------------------------
CREATE TABLE policyholders (
  policyholder_id VARCHAR(10) PRIMARY KEY,       -- PH-0101
  first_name      VARCHAR(40) NOT NULL,
  last_name       VARCHAR(40) NOT NULL,
  email           VARCHAR(100) NOT NULL,         -- HIDDEN (emails go to the EMAIL_TO demo inbox)
  phone           VARCHAR(20) NOT NULL,          -- hidden from reviewers
  date_of_birth   DATE NOT NULL,                 -- HIDDEN
  street_address  VARCHAR(80) NOT NULL,          -- hidden from reviewers
  city            VARCHAR(40) NOT NULL,
  state           VARCHAR(2) NOT NULL,
  one_time_code   VARCHAR(6) NOT NULL,           -- HIDDEN: demo stand-in for the texted one-time code
  customer_since  DATE NOT NULL
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- CAS-3011 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,          -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN
  approval_limit  NUMERIC(12,2),                 -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- Policies, vehicles, coverages, premium payments
-- ---------------------------------------------------------------------
CREATE TABLE policies (
  policy_number      VARCHAR(12) PRIMARY KEY,    -- CAI-100101
  policyholder_id    VARCHAR(10) NOT NULL REFERENCES policyholders,
  product_tier       VARCHAR(30) NOT NULL CHECK (product_tier IN ('Full Coverage','Liability + Comprehensive','Liability Only')),
  status             VARCHAR(16) NOT NULL CHECK (status IN ('Active','Pending Renewal','Lapsed','Cancelled')),
  status_date        DATE,                       -- when it lapsed / was cancelled
  effective_date     DATE NOT NULL,
  renewal_date       DATE NOT NULL,              -- 12-month term
  annual_premium     NUMERIC(10,2) NOT NULL,
  payment_frequency  VARCHAR(12) NOT NULL CHECK (payment_frequency IN ('Monthly','Semi-annual','Annual')),
  claims_free_years  INTEGER NOT NULL DEFAULT 0,
  discount_protected BOOLEAN NOT NULL DEFAULT FALSE,
  coverage_changed_on DATE                       -- last coverage increase / reinstatement (claim signal S3)
);
CREATE INDEX ix_policies_holder ON policies (policyholder_id);

CREATE TABLE vehicles (
  vehicle_id     SERIAL PRIMARY KEY,
  policy_number  VARCHAR(12) NOT NULL REFERENCES policies,
  year           INTEGER NOT NULL,
  make           VARCHAR(30) NOT NULL,           -- fictional makes only
  model          VARCHAR(30) NOT NULL,
  body_type      VARCHAR(20) NOT NULL,
  license_plate  VARCHAR(12) NOT NULL,
  vin            VARCHAR(17) NOT NULL,
  market_value   NUMERIC(12,2) NOT NULL,         -- actual cash value used by claim signal S5
  usage          VARCHAR(12) NOT NULL CHECK (usage IN ('Commute','Pleasure','Business'))
);

CREATE TABLE coverages (
  policy_number  VARCHAR(12) NOT NULL REFERENCES policies,
  coverage       VARCHAR(30) NOT NULL CHECK (coverage IN ('Bodily Injury Liability','Property Damage Liability','Collision',
                   'Comprehensive','Medical Payments','Uninsured Motorist','Full Glass','Roadside Assistance',
                   'Rental Reimbursement','New Car Replacement')),
  limit_amount   NUMERIC(12,2),
  limit_basis    VARCHAR(60),
  deductible     NUMERIC(10,2),
  included       BOOLEAN NOT NULL DEFAULT TRUE,  -- FALSE = not on this policy (shown so the customer sees the gap)
  PRIMARY KEY (policy_number, coverage)
);

CREATE TABLE payments (
  payment_id     SERIAL PRIMARY KEY,
  policy_number  VARCHAR(12) NOT NULL REFERENCES policies,
  due_date       DATE NOT NULL,
  amount         NUMERIC(10,2) NOT NULL,
  status         VARCHAR(10) NOT NULL CHECK (status IN ('Paid','Due','Failed','Scheduled')),
  paid_date      DATE,
  method         VARCHAR(40) NOT NULL
);

-- ---------------------------------------------------------------------
-- Sessions (both roles) + verify throttle
-- ---------------------------------------------------------------------
CREATE TABLE sessions (
  session_token   TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role            VARCHAR(10) NOT NULL CHECK (role IN ('CUSTOMER','REVIEWER')),
  policyholder_id VARCHAR(10) REFERENCES policyholders,
  policy_number   VARCHAR(12) REFERENCES policies,  -- the verified ("current") policy, used for filing
  reviewer_id     VARCHAR(10) REFERENCES reviewers,
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'CUSTOMER' AND policyholder_id IS NOT NULL AND policy_number IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND policyholder_id IS NULL))
);

CREATE TABLE verify_attempts (
  attempt_id   BIGSERIAL PRIMARY KEY,
  role         VARCHAR(10) NOT NULL,
  identifier   VARCHAR(40) NOT NULL,             -- normalised as typed
  outcome      VARCHAR(14) NOT NULL CHECK (outcome IN ('VERIFIED','VERIFY_FAILED','LOCKED')),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_verify_attempts ON verify_attempts (role, identifier, created_at);

-- ---------------------------------------------------------------------
-- Claims (hidden assessment columns are never returned to the customer)
-- ---------------------------------------------------------------------
CREATE TABLE claims (
  claim_no           VARCHAR(16) PRIMARY KEY,    -- CLM-2026-0101
  policy_number      VARCHAR(12) NOT NULL REFERENCES policies,
  policyholder_id    VARCHAR(10) NOT NULL REFERENCES policyholders,
  claim_type         VARCHAR(12) NOT NULL CHECK (claim_type IN ('Collision','Glass','Theft','Weather','Vandalism','Animal')),
  incident_date      DATE NOT NULL,
  incident_hour      INTEGER CHECK (incident_hour BETWEEN 0 AND 23),
  description        TEXT,                       -- the customer's own words
  repair_shop        VARCHAR(120),
  estimated_amount   NUMERIC(12,2) NOT NULL,
  coverage_that_pays VARCHAR(30),
  deductible         NUMERIC(10,2),
  coverage_limit     NUMERIC(12,2),
  status             VARCHAR(14) NOT NULL CHECK (status IN ('Submitted','Under Review','Approved','Settled','Denied')),
  filed_date         DATE NOT NULL,
  source             VARCHAR(6) NOT NULL DEFAULT 'SEED' CHECK (source IN ('SEED','CHAT')),
  proposal_id        TEXT UNIQUE,                -- the confirmed proposal (chat claims)
  -- hidden assessment (AI advisory + SQL signals; auditable, reviewer-only)
  coverage_finding   VARCHAR(14),                -- COVERED / EXCLUDED / UNCLEAR / NOT_ASSESSED
  coverage_note      TEXT,
  signal_points      INTEGER,
  review_signals     TEXT,
  narrative_score    INTEGER,
  risk_indicators    TEXT,
  risk_score         INTEGER,
  risk_band          VARCHAR(10) CHECK (risk_band IN ('NORMAL','ADJUSTER','SIU')),
  route              VARCHAR(16) CHECK (route IN ('STANDARD','ADJUSTER_REVIEW','SIU_REVIEW')),
  payment_hold       BOOLEAN NOT NULL DEFAULT FALSE,
  approved_amount    NUMERIC(12,2),
  decided_at         TIMESTAMP
);
CREATE INDEX ix_claims_holder ON claims (policyholder_id, incident_date);
CREATE INDEX ix_claims_policy ON claims (policy_number, claim_type, incident_date);

-- ---------------------------------------------------------------------
-- Two-step filing: proposals -> assessments -> confirmed claims (the only path that files a claim in chat)
-- ---------------------------------------------------------------------
CREATE TABLE pending_claims (
  seq                BIGSERIAL UNIQUE,
  proposal_id        TEXT PRIMARY KEY DEFAULT 'CAI-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  policyholder_id    VARCHAR(10) NOT NULL REFERENCES policyholders,
  policy_number      VARCHAR(12) NOT NULL REFERENCES policies,
  target_key         TEXT NOT NULL,              -- normalised request, shared by the write-row and the readback
  claim_type         VARCHAR(12),
  incident_date      DATE,
  incident_hour      INTEGER,
  estimated_amount   NUMERIC(12,2),
  description        TEXT,
  repair_shop        VARCHAR(120),
  outcome            VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code        VARCHAR(24),
  reason_text        TEXT,
  coverage_that_pays VARCHAR(30),
  deductible         NUMERIC(10,2),
  coverage_limit     NUMERIC(12,2),
  discount_impact    TEXT,
  summary            TEXT,
  signal_points      INTEGER,                    -- HIDDEN
  review_signals     TEXT,                       -- internal: passed only to fraud_signal_agent
  created_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_holder ON pending_claims (policyholder_id, policy_number, target_key, seq);

-- Insert-only; the latest row per proposal wins.
CREATE TABLE claim_assessments (
  assessment_id    BIGSERIAL PRIMARY KEY,
  proposal_id      TEXT NOT NULL REFERENCES pending_claims,
  policyholder_id  VARCHAR(10) NOT NULL REFERENCES policyholders,
  coverage_finding VARCHAR(14) NOT NULL CHECK (coverage_finding IN ('COVERED','EXCLUDED','UNCLEAR')),
  coverage_note    TEXT,
  narrative_score  INTEGER NOT NULL CHECK (narrative_score BETWEEN 0 AND 100),
  risk_indicators  TEXT,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE assessment_attempts (               -- every record_claim_assessment call (readback)
  attempt_id      SERIAL PRIMARY KEY,
  policyholder_id VARCHAR(10) NOT NULL REFERENCES policyholders,
  proposal_ref    TEXT NOT NULL,
  outcome         VARCHAR(14) NOT NULL,          -- RECORDED / NOT_FOUND / EXPIRED / ALREADY_DONE
  reason_text     TEXT,
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (                  -- every confirm_claim call (readback)
  attempt_id      SERIAL PRIMARY KEY,
  policyholder_id VARCHAR(10) NOT NULL REFERENCES policyholders,
  proposal_ref    TEXT NOT NULL,
  outcome         VARCHAR(14) NOT NULL,          -- FILED / NOT_FOUND / ALREADY_DONE / EXPIRED / BLOCKED
  reason_code     VARCHAR(24),
  reason_text     TEXT,
  claim_no        VARCHAR(16),
  case_id         VARCHAR(16),
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, claim payments, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,  -- CAI-CASE-000101
  policyholder_id  VARCHAR(10) NOT NULL REFERENCES policyholders,
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  team             VARCHAR(40) NOT NULL,         -- copied from case_routing at open (internal team)
  summary          TEXT NOT NULL,                -- the customer's request / statement, in their words
  reference_id     VARCHAR(16),                  -- claim no (claim cases) or policy number
  requested_amount NUMERIC(12,2),
  parked_action    VARCHAR(40),                  -- what runs on approval: CLAIM_PAYMENT:<claim_no>
  agent_brief      TEXT,                         -- AI-prepared neutral brief for the reviewer (never shown to the customer)
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                         -- customer-safe outcome text, set by the decision
  approved_amount  NUMERIC(12,2),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_holder ON service_cases (policyholder_id, request_type, status);

CREATE TABLE case_requests (                     -- every open_service_case call (readback)
  request_id      SERIAL PRIMARY KEY,
  policyholder_id VARCHAR(10) NOT NULL REFERENCES policyholders,
  request_type    VARCHAR(40) NOT NULL,
  reference_id    VARCHAR(40),
  outcome         VARCHAR(16) NOT NULL,          -- OPENED / EXISTING / INVALID_TYPE / NOT_FOUND
  reason_code     VARCHAR(24),
  case_id         VARCHAR(16),
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Insert-only decision events. trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE REFERENCES service_cases (case_id),   -- one decision per case
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(12,2),
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
  reference    VARCHAR(16) NOT NULL UNIQUE,      -- CAI-PAY-000101
  claim_no     VARCHAR(16) NOT NULL UNIQUE REFERENCES claims,
  amount       NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  case_id      VARCHAR(16),
  paid_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE agent_audit (
  audit_id    BIGSERIAL PRIMARY KEY,
  event_type  VARCHAR(20) NOT NULL,              -- CLAIM_FILED / CASE_OPENED / CASE_DECIDED
  actor       VARCHAR(12) NOT NULL,              -- policyholder id or reviewer id
  subject_id  VARCHAR(16) NOT NULL,              -- claim no / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id        SERIAL PRIMARY KEY,
  policyholder_id VARCHAR(10) NOT NULL REFERENCES policyholders,
  reference       VARCHAR(16) NOT NULL,
  subject         TEXT NOT NULL,
  logged_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

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
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;

-- CAI-100101 / cai100101 / CAI 100101 / 100101 -> CAI-100101
CREATE OR REPLACE FUNCTION norm_policy_number(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{6}$' THEN 'CAI-' || x
              WHEN x ~ '^CAI[0-9]{6}$' THEN 'CAI-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- CAS-3011 / cas3011 / CAS 3011 / 3011 -> CAS-3011
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'CAS-' || x
              WHEN x ~ '^CAS[0-9]{4}$' THEN 'CAS-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ids typed by people or the model: ' clm-2026-0051 ' -> 'CLM-2026-0051'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- '$6,600' / '6600' / '6600.00' / '6,600 USD' -> '6600'; anything else -> upper text (-> AMOUNT_INVALID)
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN regexp_replace(trim(coalesce(p, '')), '[$,\s]|USD|dollars?', '', 'gi') ~ '^-?[0-9]+(\.[0-9]+)?$'
              THEN trim_scale(regexp_replace(trim(p), '[$,\s]|USD|dollars?', '', 'gi')::numeric)::text
              ELSE left(upper(trim(coalesce(p, ''))), 20) END
$$ LANGUAGE sql IMMUTABLE;
-- Free-text claim type -> Collision / Glass / Theft / Weather / Vandalism / Animal, else NULL (-> INVALID_TYPE).
CREATE OR REPLACE FUNCTION norm_claim_type(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x = '' THEN NULL
              WHEN x ~ '(glass|windshield|windscreen|window)' THEN 'Glass'
              WHEN x ~ '(deer|animal|elk|moose)' THEN 'Animal'
              WHEN x ~ '(theft|stolen|steal|burglary)' THEN 'Theft'
              WHEN x ~ '(vandal|keyed|graffiti)' THEN 'Vandalism'
              WHEN x ~ '(flood|hail|storm|weather|wind|tornado|hurricane)' THEN 'Weather'
              WHEN x ~ '(collision|accident|crash|collided)' THEN 'Collision'
              ELSE NULL END
    FROM (SELECT lower(trim(coalesce(p, ''))) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- 'YYYY-MM-DD' / 'today' / 'yesterday' (also M/D/YYYY) -> DATE; unparseable -> NULL (-> INVALID_DATE)
CREATE OR REPLACE FUNCTION parse_incident_date(p TEXT) RETURNS DATE AS $$
DECLARE x TEXT := lower(trim(coalesce(p, ''))); m TEXT[];
BEGIN
  IF x IN ('today', 'tonight', 'this morning', 'earlier today') THEN RETURN current_date; END IF;
  IF x IN ('yesterday', 'last night') THEN RETURN current_date - 1; END IF;
  BEGIN
    IF x ~ '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$' THEN
      m := regexp_match(x, '^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$');
      RETURN make_date(m[1]::int, m[2]::int, m[3]::int);
    ELSIF x ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN
      m := regexp_match(x, '^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})$');
      RETURN make_date(m[3]::int, m[1]::int, m[2]::int);
    END IF;
  EXCEPTION WHEN OTHERS THEN RETURN NULL;
  END;
  RETURN NULL;
END $$ LANGUAGE plpgsql STABLE;
-- 'HH:MM' / 'H:MM' / '2:30 am' / '02:30' / '14' / 'midnight' -> hour 0..23; empty or garbage -> NULL
CREATE OR REPLACE FUNCTION parse_incident_hour(p TEXT) RETURNS INTEGER AS $$
DECLARE x TEXT := lower(regexp_replace(trim(coalesce(p, '')), '[\s.]+', '', 'g')); m TEXT[]; h INTEGER;
BEGIN
  IF x = '' THEN RETURN NULL; END IF;
  IF x = 'midnight' THEN RETURN 0; END IF;
  IF x = 'noon' THEN RETURN 12; END IF;
  m := regexp_match(x, '^([0-9]{1,2})(?::([0-9]{2}))?(?::[0-9]{2})?(am|pm)?$');
  IF m IS NULL THEN RETURN NULL; END IF;
  h := m[1]::int;
  IF m[2] IS NOT NULL AND m[2]::int > 59 THEN RETURN NULL; END IF;
  IF m[3] = 'am' THEN IF h > 12 OR h = 0 THEN RETURN NULL; END IF; IF h = 12 THEN h := 0; END IF;
  ELSIF m[3] = 'pm' THEN IF h > 12 OR h = 0 THEN RETURN NULL; END IF; IF h < 12 THEN h := h + 12; END IF;
  END IF;
  IF h > 23 THEN RETURN NULL; END IF;
  RETURN h;
END $$ LANGUAGE plpgsql IMMUTABLE;

-- Customer-facing claim status (never "held" / internal routes).
CREATE OR REPLACE FUNCTION claim_status_label(p TEXT) RETURNS TEXT AS $$
  SELECT CASE p WHEN 'Under Review' THEN 'Under review' ELSE p END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION add_business_days(p_from TIMESTAMP, p_days INTEGER) RETURNS TIMESTAMP AS $$
DECLARE t TIMESTAMP := p_from; n INTEGER := 0;
BEGIN
  WHILE n < p_days LOOP
    t := t + INTERVAL '1 day';
    IF extract(isodow FROM t) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN t;
END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION vehicle_label(p_policy TEXT) RETURNS TEXT AS $$
  SELECT v.year || ' ' || v.make || ' ' || v.model || ' ' || lower(v.body_type) || ', plate ' || v.license_plate
    FROM vehicles v WHERE v.policy_number = p_policy ORDER BY v.vehicle_id LIMIT 1
$$ LANGUAGE sql STABLE;

-- Eligible maximum for a claim payment = LEAST(estimate, coverage limit) - deductible (>= 0).
CREATE OR REPLACE FUNCTION claim_eligible_max(p_claim TEXT) RETURNS NUMERIC AS $$
  SELECT greatest(least(c.estimated_amount, coalesce(c.coverage_limit, c.estimated_amount)) - coalesce(c.deductible, 0), 0)
    FROM claims c WHERE c.claim_no = p_claim
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;

-- =====================================================================
-- IDENTITY (policyholders and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the policyholder + verified policy for a valid CUSTOMER token, else NULLs -> SESSION_INVALID.
CREATE OR REPLACE FUNCTION session_customer(p_token TEXT)
RETURNS TABLE (policyholder_id VARCHAR, policy_number VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT h.policyholder_id, p.policy_number
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'CUSTOMER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN policyholders h ON h.policyholder_id = s.policyholder_id
      LEFT JOIN policies p ON p.policy_number = s.policy_number AND p.policyholder_id = h.policyholder_id;
END $$ LANGUAGE plpgsql STABLE;

-- Always exactly one row: the reviewer for a valid REVIEWER token of an active reviewer.
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

-- Guarded write-row for verify_policyholder: records the attempt (throttle) and returns the sessions row ONLY for a
-- matching policy number + the policyholder's one-time code while the identifier is not locked (5 failures / 15 min).
CREATE OR REPLACE FUNCTION verify_policyholder_fn(p_policy TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, policyholder_id VARCHAR, policy_number VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_policy_number(p_policy); v_holder TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'CUSTOMER' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('CUSTOMER', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT h.policyholder_id INTO v_holder FROM policies p JOIN policyholders h ON h.policyholder_id = p.policyholder_id
   WHERE p.policy_number = v_id AND h.one_time_code = trim(coalesce(p_code, ''));
  IF v_holder IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('CUSTOMER', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('CUSTOMER', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'CUSTOMER'::varchar, v_holder::varchar, v_id::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_policyholder_result(p_policy TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, first_name VARCHAR, policy_number VARCHAR, product_tier VARCHAR,
               today TEXT, expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.first_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.policy_number END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.product_tier END,
         d(current_date),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.expires_at END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'You are verified. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For your security, verification is paused for 15 minutes. Please try again later.'
              ELSE 'That policy number and one-time code do not match our records. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'CUSTOMER' AND a.identifier = norm_policy_number(p_policy)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, h.first_name, p.policy_number, p.product_tier, s.expires_at
                         FROM policies p JOIN policyholders h ON h.policyholder_id = p.policyholder_id
                         JOIN sessions s ON s.policyholder_id = h.policyholder_id AND s.policy_number = p.policy_number
                                        AND s.role = 'CUSTOMER' AND s.expires_at > clock_timestamp()
                        WHERE p.policy_number = norm_policy_number(p_policy) AND h.one_time_code = trim(coalesce(p_code, ''))
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
-- SCOPED READS (customer) - every function starts FROM session_customer(token)
-- A session belongs to the policyholder: policies, claims, payments and cases cover all their Copperleaf policies;
-- coverages are for the verified ("current") policy.
-- =====================================================================
CREATE OR REPLACE FUNCTION my_policy(p_token TEXT)
RETURNS TABLE (status TEXT, today TEXT, policy_number VARCHAR, verified_policy TEXT, policyholder_name TEXT, city VARCHAR,
               state VARCHAR, product_tier VARCHAR, policy_status VARCHAR, status_note TEXT, effective_date DATE,
               renewal_date DATE, annual_premium NUMERIC, payment_frequency VARCHAR, installment_amount NUMERIC,
               claims_free_years INTEGER, discount_protection TEXT, claims_free_discount TEXT, vehicle TEXT,
               license_plate VARCHAR, vin VARCHAR, vehicle_value NUMERIC, vehicle_usage VARCHAR) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         d(current_date),
         p.policy_number,
         CASE WHEN p.policy_number IS NULL THEN NULL WHEN p.policy_number = sm.policy_number THEN 'yes' ELSE 'no' END,
         h.first_name || ' ' || h.last_name, h.city, h.state,
         p.product_tier, p.status,
         CASE p.status WHEN 'Active' THEN 'In force.'
                       WHEN 'Pending Renewal' THEN 'In force; renews on ' || d(p.renewal_date) || '.'
                       WHEN 'Lapsed' THEN 'Lapsed on ' || d(p.status_date) || ' after a missed payment; coverage is not in force.'
                       WHEN 'Cancelled' THEN 'Cancelled on ' || d(p.status_date) || '; coverage is not in force.' END,
         p.effective_date, p.renewal_date, p.annual_premium, p.payment_frequency,
         CASE p.payment_frequency WHEN 'Monthly' THEN round(p.annual_premium / 12, 2)
                                  WHEN 'Semi-annual' THEN round(p.annual_premium / 2, 2) ELSE p.annual_premium END,
         p.claims_free_years,
         CASE WHEN p.policy_number IS NULL THEN NULL WHEN p.discount_protected THEN 'yes' ELSE 'no' END,
         CASE WHEN p.policy_number IS NULL THEN NULL
              ELSE p.claims_free_years || ' claims-free year' || CASE WHEN p.claims_free_years = 1 THEN '' ELSE 's' END
                   || CASE WHEN p.discount_protected THEN '; discount protection is on (up to 2 claims in 36 months keep the discount). Glass claims never affect it.'
                           ELSE '; no discount protection. Glass claims never affect the discount; other claims may reduce it at renewal.' END END,
         v.year || ' ' || v.make || ' ' || v.model || ' ' || v.body_type, v.license_plate, v.vin, v.market_value, v.usage
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN policyholders h ON h.policyholder_id = sm.policyholder_id
    LEFT JOIN policies p ON p.policyholder_id = sm.policyholder_id
    LEFT JOIN LATERAL (SELECT x.* FROM vehicles x WHERE x.policy_number = p.policy_number ORDER BY x.vehicle_id LIMIT 1) v ON TRUE
   ORDER BY (p.policy_number = sm.policy_number) DESC, p.effective_date DESC
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_coverages(p_token TEXT)
RETURNS TABLE (status TEXT, policy_number VARCHAR, product_tier VARCHAR, coverage VARCHAR, included TEXT,
               limit_amount NUMERIC, limit_basis VARCHAR, deductible NUMERIC, note TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         p.policy_number, p.product_tier, c.coverage,
         CASE WHEN c.coverage IS NULL THEN NULL WHEN c.included THEN 'yes' ELSE 'no' END,
         CASE WHEN c.included THEN c.limit_amount END, CASE WHEN c.included THEN c.limit_basis END,
         CASE WHEN c.included THEN c.deductible END,
         CASE WHEN c.coverage IS NULL THEN NULL
              WHEN NOT c.included THEN 'Not on this policy.'
              WHEN c.coverage = 'Collision' THEN 'Pays for damage to your vehicle from a collision.'
              WHEN c.coverage = 'Comprehensive' THEN 'Pays for theft, weather (flood, hail, wind), vandalism, animal strikes and glass (if no Full Glass).'
              WHEN c.coverage = 'Full Glass' THEN 'Pays for windshield and window repair or replacement.'
              ELSE NULL END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN policies p ON p.policy_number = sm.policy_number
    LEFT JOIN coverages c ON c.policy_number = p.policy_number
   ORDER BY c.included DESC, array_position(ARRAY['Bodily Injury Liability','Property Damage Liability','Collision','Comprehensive',
            'Medical Payments','Uninsured Motorist','Full Glass','Roadside Assistance','Rental Reimbursement','New Car Replacement']::varchar[], c.coverage)
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_claims(p_token TEXT)
RETURNS TABLE (status TEXT, claim_no VARCHAR, policy_number VARCHAR, claim_type VARCHAR, incident_date DATE, filed_date DATE,
               estimated_amount NUMERIC, deductible NUMERIC, claim_status TEXT, status_text TEXT, approved_amount NUMERIC,
               paid_amount NUMERIC, payment_reference VARCHAR, case_id VARCHAR, case_status VARCHAR, customer_message TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.claim_no, c.policy_number, c.claim_type, c.incident_date, c.filed_date, c.estimated_amount, c.deductible,
         claim_status_label(c.status),
         CASE c.status WHEN 'Submitted' THEN 'Received - an adjuster will contact you within 2 business days.'
                       WHEN 'Under Review' THEN 'Under review - a claims specialist is reviewing this claim'
                                                || coalesce(' (reference ' || sc.case_id || ')', '') || '.'
                       WHEN 'Approved' THEN 'Approved for ' || usd(c.approved_amount) || '.'
                       WHEN 'Settled' THEN 'Settled and paid.'
                       WHEN 'Denied' THEN 'Not approved.' || coalesce(' ' || sc.customer_message, '') END,
         c.approved_amount, cp.amount, cp.reference, sc.case_id, sc.status,
         CASE WHEN sc.status IN ('APPROVED','REJECTED') THEN sc.customer_message END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN claims c ON c.policyholder_id = sm.policyholder_id
    LEFT JOIN claim_payments cp ON cp.claim_no = c.claim_no
    LEFT JOIN LATERAL (SELECT s.case_id, s.status, s.customer_message FROM service_cases s
                        WHERE s.policyholder_id = sm.policyholder_id AND s.reference_id = c.claim_no
                        ORDER BY s.created_at DESC LIMIT 1) sc ON TRUE
   ORDER BY c.filed_date DESC, c.claim_no DESC
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_payments(p_token TEXT)
RETURNS TABLE (status TEXT, policy_number VARCHAR, due_date DATE, amount NUMERIC, payment_status VARCHAR, paid_date DATE,
               method VARCHAR, note TEXT) AS $$
  SELECT x.* FROM (
    SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END AS status,
           y.policy_number, y.due_date, y.amount, y.status AS payment_status, y.paid_date, y.method,
           CASE y.status WHEN 'Due' THEN 'Due on ' || d(y.due_date) || '.'
                         WHEN 'Failed' THEN 'The payment did not go through.'
                         WHEN 'Scheduled' THEN 'Scheduled for ' || d(y.due_date) || '.' WHEN 'Paid' THEN 'Paid.' END AS note
      FROM (SELECT * FROM session_customer(p_token)) sm
      LEFT JOIN LATERAL (SELECT pm.* FROM payments pm JOIN policies p ON p.policy_number = pm.policy_number
                          WHERE p.policyholder_id = sm.policyholder_id) y ON TRUE
     ORDER BY y.due_date DESC, y.payment_id DESC
     LIMIT 12) x
$$ LANGUAGE sql STABLE;

-- The customer's own cases: status + the customer-safe outcome. Never the internal note, brief, team or reviewer.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, about VARCHAR, team VARCHAR, case_status VARCHAR,
               opened_on DATE, reply_due DATE, outcome_amount NUMERIC, decided_on DATE, customer_message TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         s.case_id, r.label, s.reference_id, r.customer_team, s.status, s.created_at::date, s.sla_due_at::date,
         s.approved_amount, s.decided_at::date,
         CASE WHEN s.status = 'OPEN' THEN 'Open - our ' || r.customer_team
                                          || CASE WHEN r.customer_team LIKE '%Team' THEN '' ELSE ' team' END
                                          || ' will review it and reply by ' || d(s.sla_due_at::date) || '.'
              ELSE s.customer_message END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN service_cases s ON s.policyholder_id = sm.policyholder_id
    LEFT JOIN case_routing r ON r.request_type = s.request_type
   ORDER BY s.created_at DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- CLAIM RULES (first notice of loss)
-- =====================================================================
-- Every propose rule, in order. Re-run unchanged by confirm_claim_row (rule re-check).
CREATE OR REPLACE FUNCTION claim_eval(p_holder TEXT, p_policy TEXT, p_type TEXT, p_date TEXT, p_time TEXT, p_amount TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, claim_type TEXT, incident_date DATE, incident_hour INTEGER,
               amount NUMERIC, coverage_that_pays TEXT, deductible NUMERIC, coverage_limit NUMERIC, discount_impact TEXT,
               summary TEXT) AS $$
#variable_conflict use_column
DECLARE p policies; v_type TEXT := norm_claim_type(p_type); v_date DATE := parse_incident_date(p_date);
        v_hour INTEGER := parse_incident_hour(p_time); v_amt_txt TEXT := norm_amount(p_amount); v_amt NUMERIC;
        v_cov TEXT; c coverages; v_dup TEXT; v_n36 INTEGER; v_disc TEXT;
BEGIN
  SELECT * INTO p FROM policies x WHERE x.policy_number = p_policy AND x.policyholder_id = p_holder;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again (policy number and one-time code).',
      NULL::text, NULL::date, NULL::int, NULL::numeric, NULL::text, NULL::numeric, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  IF p.status NOT IN ('Active', 'Pending Renewal') THEN
    RETURN QUERY SELECT FALSE, 'POLICY_NOT_ACTIVE',
      'Your policy ' || p.policy_number || ' is ' || lower(p.status) || coalesce(' (since ' || d(p.status_date) || ')', '')
      || ', so its coverage is not in force and a claim cannot be filed on it here. I can open a policy reinstatement request for our Customer Care team.',
      v_type, v_date, v_hour, NULL::numeric, NULL::text, NULL::numeric, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  IF v_type IS NULL THEN
    RETURN QUERY SELECT FALSE, 'INVALID_TYPE',
      'The claim type must be one of: Collision, Glass, Theft, Weather (flood, hail, wind), Vandalism or Animal (for example hitting a deer).',
      NULL::text, v_date, v_hour, NULL::numeric, NULL::text, NULL::numeric, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  IF v_date IS NULL THEN
    RETURN QUERY SELECT FALSE, 'INVALID_DATE', 'Please give the incident date as YYYY-MM-DD, today or yesterday.',
      v_type, NULL::date, v_hour, NULL::numeric, NULL::text, NULL::numeric, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  IF v_date > current_date OR v_date < p.effective_date OR v_date > p.renewal_date THEN
    RETURN QUERY SELECT FALSE, 'INCIDENT_OUTSIDE_PERIOD',
      'The incident date ' || d(v_date) || CASE WHEN v_date > current_date THEN ' is in the future'
                                                ELSE ' is outside your policy period (' || d(p.effective_date) || ' to ' || d(p.renewal_date) || ')' END
      || ', so a claim cannot be filed for it on policy ' || p.policy_number || '.',
      v_type, v_date, v_hour, NULL::numeric, NULL::text, NULL::numeric, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  v_cov := CASE v_type WHEN 'Collision' THEN 'Collision'
                       WHEN 'Glass' THEN CASE WHEN EXISTS (SELECT 1 FROM coverages g WHERE g.policy_number = p.policy_number
                                                            AND g.coverage = 'Full Glass' AND g.included) THEN 'Full Glass' ELSE 'Comprehensive' END
                       ELSE 'Comprehensive' END;
  SELECT * INTO c FROM coverages x WHERE x.policy_number = p.policy_number AND x.coverage = v_cov AND x.included;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_COVERED',
      'Your ' || p.product_tier || ' policy does not include ' || v_cov || ' coverage, which is what pays for a ' || v_type
      || ' claim, so this damage is not covered by your policy and no claim was proposed. I can open a quote or coverage change request if you would like to add it.',
      v_type, v_date, v_hour, NULL::numeric, v_cov, NULL::numeric, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  IF v_amt_txt ~ '^[0-9]+(\.[0-9]+)?$' THEN v_amt := round(v_amt_txt::numeric, 2); END IF;
  IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 250000 THEN
    RETURN QUERY SELECT FALSE, 'AMOUNT_INVALID',
      'Please give an estimated amount in US dollars, more than $0 and up to $250,000 (for example 6600). A rough repair estimate is fine.',
      v_type, v_date, v_hour, NULL::numeric, v_cov, c.deductible, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  SELECT x.claim_no INTO v_dup FROM claims x
   WHERE x.policy_number = p.policy_number AND x.claim_type = v_type AND x.incident_date = v_date LIMIT 1;
  IF v_dup IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'DUPLICATE_CLAIM',
      'A ' || v_type || ' claim for ' || d(v_date) || ' is already filed on policy ' || p.policy_number || ' (' || v_dup
      || '), so no new claim was proposed.',
      v_type, v_date, v_hour, v_amt, v_cov, c.deductible, NULL::numeric, NULL::text, NULL::text; RETURN;
  END IF;
  SELECT count(*) INTO v_n36 FROM claims x WHERE x.policyholder_id = p_holder AND x.incident_date >= current_date - 1095;
  v_disc := CASE WHEN v_type = 'Glass' THEN 'Your claims-free discount is not affected (glass claims never affect it).'
                 WHEN p.discount_protected AND v_n36 + 1 <= 2 THEN 'Your claims-free discount is protected by your discount protection.'
                 ELSE 'Your claims-free discount may be affected at renewal.' END;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, v_type, v_date, v_hour, v_amt, v_cov, c.deductible, c.limit_amount, v_disc,
    v_type || ' claim on policy ' || p.policy_number || coalesce(' (' || vehicle_label(p.policy_number) || ')', '')
    || ' for an incident on ' || d(v_date) || coalesce(' at about ' || lpad(v_hour::text, 2, '0') || ':00', '')
    || ', estimated ' || usd(v_amt) || '. Your ' || v_cov || ' coverage would pay, after your ' || usd(c.deductible)
    || ' deductible. ' || v_disc;
END $$ LANGUAGE plpgsql STABLE;

-- Normalised request key shared by the write-row and the readback.
CREATE OR REPLACE FUNCTION claim_key(p_type TEXT, p_date TEXT, p_time TEXT, p_amount TEXT, p_desc TEXT, p_shop TEXT) RETURNS TEXT AS $$
  SELECT coalesce(norm_claim_type(p_type), 'X:' || left(upper(trim(coalesce(p_type, ''))), 30)) || '|'
         || coalesce(d(parse_incident_date(p_date)), 'X:' || left(upper(trim(coalesce(p_date, ''))), 20)) || '|'
         || coalesce(parse_incident_hour(p_time)::text, '') || '|' || norm_amount(p_amount) || '|'
         || md5(trim(coalesce(p_desc, '')) || '|' || lower(trim(coalesce(p_shop, ''))))
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- CLAIM SIGNALS (SPEC 4b) - auditable points + a non-identifying review_signals text. Never shown to the customer
-- as a score; review_signals is passed only to the fraud_signal_agent.
-- =====================================================================
CREATE OR REPLACE FUNCTION claim_signals(p_holder TEXT, p_policy TEXT, p_type TEXT, p_date DATE, p_hour INTEGER,
                                         p_amount NUMERIC, p_shop TEXT)
RETURNS TABLE (signal_points INTEGER, review_signals TEXT) AS $$
DECLARE p policies; v_value NUMERIC; n12 INTEGER; v_age INTEGER; chg BOOLEAN; delay INTEGER; ratio NUMERIC;
        shop BOOLEAN; same BOOLEAN; pts INTEGER; v_shop TEXT := lower(regexp_replace(trim(coalesce(p_shop, '')), '\s+', ' ', 'g'));
BEGIN
  SELECT * INTO p FROM policies x WHERE x.policy_number = p_policy;
  IF p_date IS NULL OR NOT FOUND THEN RETURN QUERY SELECT NULL::int, NULL::text; RETURN; END IF;
  SELECT v.market_value INTO v_value FROM vehicles v WHERE v.policy_number = p_policy ORDER BY v.vehicle_id LIMIT 1;
  SELECT count(*) INTO n12 FROM claims c                                                   -- S1 (any policy)
   WHERE c.policyholder_id = p_holder AND c.incident_date < p_date AND c.incident_date >= p_date - 365;
  v_age := p_date - p.effective_date;                                                      -- S2
  chg := p.coverage_changed_on IS NOT NULL AND p.coverage_changed_on <= p_date
         AND p.coverage_changed_on >= p_date - 30;                                         -- S3
  delay := current_date - p_date;                                                          -- S4
  ratio := CASE WHEN coalesce(v_value, 0) > 0 AND p_amount IS NOT NULL THEN p_amount / v_value END;   -- S5
  shop := v_shop <> '' AND EXISTS (SELECT 1 FROM claims c WHERE c.policyholder_id = p_holder         -- S7
            AND lower(regexp_replace(trim(coalesce(c.repair_shop, '')), '\s+', ' ', 'g')) = v_shop
            AND c.incident_date < p_date AND c.incident_date >= p_date - 730);
  same := EXISTS (SELECT 1 FROM claims c WHERE c.policyholder_id = p_holder AND c.claim_type = p_type  -- S8
            AND c.incident_date < p_date AND c.incident_date >= p_date - 730);
  pts := CASE WHEN n12 >= 2 THEN 25 WHEN n12 = 1 THEN 10 ELSE 0 END
       + CASE WHEN v_age < 30 THEN 20 WHEN v_age < 90 THEN 10 ELSE 0 END
       + CASE WHEN chg THEN 10 ELSE 0 END
       + CASE WHEN delay > 30 THEN 15 WHEN delay >= 15 THEN 10 ELSE 0 END
       + CASE WHEN ratio >= 0.9 THEN 15 WHEN ratio >= 0.6 THEN 10 ELSE 0 END
       + CASE WHEN p_hour BETWEEN 0 AND 4 THEN 10 ELSE 0 END
       + CASE WHEN shop THEN 10 ELSE 0 END
       + CASE WHEN same THEN 10 ELSE 0 END;
  RETURN QUERY SELECT least(pts, 100),
    'prior_claims_12m=' || n12 || '; policy_age_days=' || v_age || '; report_delay_days=' || delay
    || '; incident_hour=' || coalesce(p_hour::text, 'unknown') || '; amount_to_value=' || coalesce(round(ratio, 2)::text, 'unknown')
    || '; repeat_repair_shop=' || CASE WHEN shop THEN 'yes' ELSE 'no' END
    || '; prior_same_type=' || CASE WHEN same THEN 'yes' ELSE 'no' END
    || '; recent_coverage_change=' || CASE WHEN chg THEN 'yes' ELSE 'no' END;
END $$ LANGUAGE plpgsql STABLE;

-- narrative score from the fraud_signal_agent: integer 0..100 (clamped); missing / invalid -> 50
CREATE OR REPLACE FUNCTION norm_narrative_score(p TEXT) RETURNS INTEGER AS $$
  SELECT CASE WHEN trim(coalesce(p, '')) ~ '^-?[0-9]+(\.[0-9]+)?(\s*/\s*100)?$'
              THEN greatest(0, least(100, round(substring(trim(p) FROM '^-?[0-9]+(?:\.[0-9]+)?')::numeric)::int))
              ELSE 50 END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_finding(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('COVERED','EXCLUDED','UNCLEAR') THEN x WHEN x = 'NOT_COVERED' THEN 'EXCLUDED' ELSE 'UNCLEAR' END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;

-- Band + route (SPEC 4b). Signal-point floors make the band injection-proof.
CREATE OR REPLACE FUNCTION claim_route(p_points INTEGER, p_narrative INTEGER, p_amount NUMERIC, p_finding TEXT)
RETURNS TABLE (risk_score INTEGER, risk_band TEXT, route TEXT) AS $$
  SELECT x.rs, x.band,
         CASE WHEN x.band = 'SIU' THEN 'SIU_REVIEW'
              WHEN x.band = 'ADJUSTER' OR p_amount > 2500 OR p_finding = 'EXCLUDED' THEN 'ADJUSTER_REVIEW'
              ELSE 'STANDARD' END
    FROM (SELECT r.rs,
                 CASE WHEN r.rs >= 70 OR coalesce(p_points, 0) >= 80 THEN 'SIU'
                      WHEN r.rs >= 40 OR coalesce(p_points, 0) >= 50 THEN 'ADJUSTER' ELSE 'NORMAL' END AS band
            FROM (SELECT round(0.6 * coalesce(p_points, 0) + 0.4 * coalesce(p_narrative, 50))::int AS rs) r) x
$$ LANGUAGE sql IMMUTABLE;

-- =====================================================================
-- TWO-STEP FILING: propose (PROPOSED / BLOCKED, 15-minute expiry) -> record assessment -> confirm (re-check, band,
-- route) -> claims row + trg_claim_filed
-- =====================================================================
CREATE OR REPLACE FUNCTION propose_claim_fn(p_token TEXT, p_type TEXT, p_date TEXT, p_time TEXT, p_amount TEXT, p_desc TEXT, p_shop TEXT)
RETURNS TABLE (policyholder_id VARCHAR, policy_number VARCHAR, target_key TEXT, claim_type VARCHAR, incident_date DATE,
               incident_hour INTEGER, estimated_amount NUMERIC, description TEXT, repair_shop VARCHAR, outcome VARCHAR,
               reason_code VARCHAR, reason_text TEXT, coverage_that_pays VARCHAR, deductible NUMERIC, coverage_limit NUMERIC,
               discount_impact TEXT, summary TEXT, signal_points INTEGER, review_signals TEXT) AS $$
  SELECT sm.policyholder_id, sm.policy_number, claim_key(p_type, p_date, p_time, p_amount, p_desc, p_shop),
         e.claim_type::varchar, e.incident_date, e.incident_hour, e.amount,
         left(coalesce(nullif(trim(p_desc), ''), '(no description given)'), 2000), left(nullif(trim(p_shop), ''), 120)::varchar,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text,
         e.coverage_that_pays::varchar, e.deductible, e.coverage_limit, e.discount_impact, e.summary,
         s.signal_points, s.review_signals
    FROM session_customer(p_token) sm
    CROSS JOIN LATERAL claim_eval(sm.policyholder_id, sm.policy_number, p_type, p_date, p_time, p_amount) e
    LEFT JOIN LATERAL (SELECT * FROM claim_signals(sm.policyholder_id, sm.policy_number, e.claim_type, e.incident_date,
                                                   e.incident_hour, e.amount, p_shop) x WHERE e.ok) s ON TRUE
   WHERE sm.policyholder_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_claims pc
                      WHERE pc.policyholder_id = sm.policyholder_id AND pc.policy_number = sm.policy_number
                        AND pc.target_key = claim_key(p_type, p_date, p_time, p_amount, p_desc, p_shop)
                        AND pc.expires_at > clock_timestamp()
                        AND pc.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pc.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM claims c WHERE c.proposal_id = pc.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_claim_result(p_token TEXT, p_type TEXT, p_date TEXT, p_time TEXT, p_amount TEXT, p_desc TEXT, p_shop TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, reason_code VARCHAR, reason_text TEXT, claim_type VARCHAR, incident_date TEXT,
               estimated_amount NUMERIC, coverage_that_pays VARCHAR, deductible NUMERIC, discount_impact TEXT, summary TEXT,
               review_signals TEXT, expires_at TIMESTAMP, next_step TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pc.outcome, 'BLOCKED') END,
         CASE WHEN pc.outcome = 'PROPOSED' THEN pc.proposal_id END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE pc.reason_code END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'Please verify your identity again (policy number and one-time code).'
              WHEN pc.outcome = 'PROPOSED' THEN 'Nothing has been filed yet. Reply yes within 15 minutes to file this claim.'
              ELSE pc.reason_text END,
         pc.claim_type, d(pc.incident_date), pc.estimated_amount, pc.coverage_that_pays, pc.deductible,
         CASE WHEN pc.outcome = 'PROPOSED' THEN pc.discount_impact END,
         pc.summary,
         CASE WHEN pc.outcome = 'PROPOSED' THEN pc.review_signals END,
         CASE WHEN pc.outcome = 'PROPOSED' THEN pc.expires_at END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'Ask the customer to verify again.'
              WHEN pc.outcome = 'PROPOSED' THEN 'Nothing is filed yet. Get the coverage and claim-signal assessments, save them with record_claim_assessment, then read the summary to the customer and call confirm_claim only after they say yes. The proposal expires in 15 minutes.'
              ELSE 'Nothing was proposed. Explain the reason to the customer.' END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN LATERAL (SELECT x.* FROM pending_claims x
                        WHERE x.policyholder_id = sm.policyholder_id AND x.policy_number = sm.policy_number
                          AND x.target_key = claim_key(p_type, p_date, p_time, p_amount, p_desc, p_shop)
                        ORDER BY x.seq DESC LIMIT 1) pc ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded write-row for record_claim_assessment (insert-only; latest wins). 0 rows + a reason when blocked.
CREATE OR REPLACE FUNCTION record_assessment_row(p_token TEXT, p_proposal TEXT, p_finding TEXT, p_note TEXT, p_score TEXT, p_ind TEXT)
RETURNS TABLE (proposal_id TEXT, policyholder_id VARCHAR, coverage_finding VARCHAR, coverage_note TEXT, narrative_score INTEGER,
               risk_indicators TEXT) AS $$
#variable_conflict use_column
DECLARE v_holder TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pc pending_claims; v_claim TEXT;
BEGIN
  SELECT s.policyholder_id INTO v_holder FROM session_customer(p_token) s;
  IF v_holder IS NULL THEN RETURN; END IF;
  SELECT * INTO pc FROM pending_claims x WHERE x.proposal_id = v_ref AND x.policyholder_id = v_holder AND x.outcome = 'PROPOSED';
  IF NOT FOUND THEN
    INSERT INTO assessment_attempts (policyholder_id, proposal_ref, outcome, reason_text)
      VALUES (v_holder, v_ref, 'NOT_FOUND', 'There is no open claim proposal with that id on your policy.');
    RETURN;
  END IF;
  SELECT c.claim_no INTO v_claim FROM claims c WHERE c.proposal_id = pc.proposal_id;
  IF v_claim IS NOT NULL THEN
    INSERT INTO assessment_attempts (policyholder_id, proposal_ref, outcome, reason_text)
      VALUES (v_holder, v_ref, 'ALREADY_DONE', 'This claim was already filed (' || v_claim || '), so the assessment was not changed.');
    RETURN;
  END IF;
  IF pc.expires_at <= clock_timestamp() THEN
    INSERT INTO assessment_attempts (policyholder_id, proposal_ref, outcome, reason_text)
      VALUES (v_holder, v_ref, 'EXPIRED', 'This claim proposal expired after 15 minutes. Propose the claim again.');
    RETURN;
  END IF;
  INSERT INTO assessment_attempts (policyholder_id, proposal_ref, outcome, reason_text)
    VALUES (v_holder, v_ref, 'RECORDED', 'Assessment saved.');
  RETURN QUERY SELECT pc.proposal_id, v_holder::varchar, norm_finding(p_finding)::varchar, left(nullif(trim(p_note), ''), 2000),
                      norm_narrative_score(p_score), left(nullif(trim(p_ind), ''), 2000);
END $$ LANGUAGE plpgsql VOLATILE;

-- Never echoes the score, finding or indicators.
CREATE OR REPLACE FUNCTION record_assessment_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, reason_code TEXT, reason_text TEXT, next_step TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(aa.outcome, 'NOT_FOUND') END,
         CASE WHEN aa.outcome = 'RECORDED' THEN aa.proposal_ref END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' WHEN aa.outcome = 'RECORDED' THEN NULL
              ELSE coalesce(aa.outcome, 'NOT_FOUND') END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'Please verify your identity again (policy number and one-time code).'
              WHEN aa.attempt_id IS NULL THEN 'There is no open claim proposal with that id on your policy.'
              ELSE aa.reason_text END,
         CASE WHEN aa.outcome = 'RECORDED' THEN 'Read the claim summary (with the deductible and discount impact) to the customer and ask them to confirm. Call confirm_claim only after they say yes.'
              WHEN aa.outcome = 'EXPIRED' THEN 'Propose the claim again with propose_claim.'
              ELSE 'Nothing to do for this proposal.' END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN LATERAL (SELECT a.* FROM assessment_attempts a
                        WHERE a.policyholder_id = sm.policyholder_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) aa ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm_claim: re-checks EVERY propose rule, combines the signal points with the latest
-- narrative score, bands and routes the claim; returns the claims row only when it may be filed.
CREATE OR REPLACE FUNCTION confirm_claim_row(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (claim_no VARCHAR, policy_number VARCHAR, policyholder_id VARCHAR, claim_type VARCHAR, incident_date DATE,
               incident_hour INTEGER, description TEXT, repair_shop VARCHAR, estimated_amount NUMERIC, coverage_that_pays VARCHAR,
               deductible NUMERIC, coverage_limit NUMERIC, status VARCHAR, filed_date DATE, source VARCHAR, proposal_id TEXT,
               coverage_finding VARCHAR, coverage_note TEXT, signal_points INTEGER, review_signals TEXT, narrative_score INTEGER,
               risk_indicators TEXT, risk_score INTEGER, risk_band VARCHAR, route VARCHAR, payment_hold BOOLEAN) AS $$
#variable_conflict use_column
DECLARE v_holder TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pc pending_claims; e RECORD; a claim_assessments;
        sg RECORD; rt RECORD; v_done TEXT; v_claim TEXT; v_find TEXT; v_narr INTEGER;
BEGIN
  SELECT s.policyholder_id INTO v_holder FROM session_customer(p_token) s;
  IF v_holder IS NULL THEN RETURN; END IF;
  SELECT * INTO pc FROM pending_claims x WHERE x.proposal_id = v_ref AND x.policyholder_id = v_holder;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (policyholder_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_holder, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that claim proposal on your policy. Nothing was filed.');
    RETURN;
  END IF;
  SELECT c.claim_no INTO v_done FROM claims c WHERE c.proposal_id = pc.proposal_id;
  IF v_done IS NOT NULL THEN
    INSERT INTO confirm_attempts (policyholder_id, proposal_ref, outcome, reason_code, reason_text, claim_no, case_id)
      VALUES (v_holder, v_ref, 'ALREADY_DONE', 'ALREADY_DONE', 'This claim was already filed earlier (' || v_done || '). Nothing new was filed.',
              v_done, (SELECT s.case_id FROM service_cases s WHERE s.reference_id = v_done
                         AND s.request_type IN ('claim_review','special_investigation') LIMIT 1));
    RETURN;
  END IF;
  IF pc.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (policyholder_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_holder, v_ref, 'BLOCKED', pc.reason_code, pc.reason_text);
    RETURN;
  END IF;
  IF pc.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (policyholder_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_holder, v_ref, 'EXPIRED', 'EXPIRED', 'This claim proposal expired after 15 minutes, so nothing was filed. I can set it up again.');
    RETURN;
  END IF;
  SELECT * INTO e FROM claim_eval(v_holder, pc.policy_number, pc.claim_type, d(pc.incident_date), pc.incident_hour::text,
                                  pc.estimated_amount::text) x;
  IF NOT e.ok THEN
    INSERT INTO confirm_attempts (policyholder_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_holder, v_ref, 'BLOCKED', e.reason_code, e.reason_text);
    RETURN;
  END IF;
  SELECT * INTO a FROM claim_assessments x WHERE x.proposal_id = pc.proposal_id ORDER BY x.assessment_id DESC LIMIT 1;
  v_find := coalesce(a.coverage_finding, 'NOT_ASSESSED');
  v_narr := coalesce(a.narrative_score, 50);
  SELECT * INTO sg FROM claim_signals(v_holder, pc.policy_number, e.claim_type, e.incident_date, e.incident_hour, e.amount, pc.repair_shop) x;
  SELECT * INTO rt FROM claim_route(sg.signal_points, v_narr, e.amount, v_find) x;
  v_claim := 'CLM-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('claim_seq')::text, 4, '0');
  INSERT INTO confirm_attempts (policyholder_id, proposal_ref, outcome, reason_text, claim_no)
    VALUES (v_holder, v_ref, 'FILED', 'Your claim is filed.', v_claim);
  RETURN QUERY SELECT v_claim::varchar, pc.policy_number, v_holder::varchar, e.claim_type::varchar, e.incident_date, e.incident_hour,
                      pc.description, pc.repair_shop, e.amount, e.coverage_that_pays::varchar, e.deductible, e.coverage_limit,
                      (CASE WHEN rt.route = 'STANDARD' THEN 'Submitted' ELSE 'Under Review' END)::varchar, current_date,
                      'CHAT'::varchar, pc.proposal_id, v_find::varchar, a.coverage_note, sg.signal_points, sg.review_signals,
                      v_narr, a.risk_indicators, rt.risk_score, rt.risk_band::varchar, rt.route::varchar, rt.risk_band = 'SIU';
END $$ LANGUAGE plpgsql VOLATILE;

-- A routed chat claim opens the review case (team + SLA from case_routing) with the reviewer-only agent brief.
CREATE OR REPLACE FUNCTION apply_claim_filed() RETURNS TRIGGER AS $$
DECLARE r case_routing; v_type TEXT; v_no BIGINT; v_case TEXT; v_why TEXT;
BEGIN
  PERFORM audit('CLAIM_FILED', NEW.policyholder_id, NEW.claim_no,
                NEW.claim_type || ' claim on ' || NEW.policy_number || ', ' || usd(NEW.estimated_amount) || '; route ' || NEW.route
                || '; band ' || NEW.risk_band || '; risk ' || NEW.risk_score);
  IF NEW.route = 'STANDARD' THEN RETURN NEW; END IF;
  v_type := CASE WHEN NEW.route = 'SIU_REVIEW' THEN 'special_investigation' ELSE 'claim_review' END;
  SELECT * INTO r FROM case_routing WHERE request_type = v_type;
  v_why := CASE WHEN NEW.route = 'SIU_REVIEW' THEN 'claim-signal band SIU; payment held'
                ELSE concat_ws(', ', CASE WHEN NEW.risk_band = 'ADJUSTER' THEN 'claim-signal band ADJUSTER' END,
                               CASE WHEN NEW.estimated_amount > 2500 THEN 'estimate over $2,500' END,
                               CASE WHEN NEW.coverage_finding = 'EXCLUDED' THEN 'coverage finding EXCLUDED' END) END;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'CAI-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO service_cases (case_no, case_id, policyholder_id, request_type, team, summary, reference_id, requested_amount,
                             parked_action, agent_brief, sla_due_at)
    VALUES (v_no, v_case, NEW.policyholder_id, v_type, r.team, coalesce(NEW.description, '(no description given)'), NEW.claim_no,
            NEW.estimated_amount, 'CLAIM_PAYMENT:' || NEW.claim_no,
            'AI-prepared, unverified. Routed for ' || v_why || '. Coverage finding: ' || coalesce(NEW.coverage_finding, 'NOT_ASSESSED')
            || coalesce(' - ' || NEW.coverage_note, '') || '. Narrative indicators: ' || coalesce(NEW.risk_indicators, 'none recorded')
            || '. Claim signals (SQL): ' || coalesce(NEW.review_signals, 'n/a') || '. Signal points ' || coalesce(NEW.signal_points, 0)
            || '; narrative score ' || coalesce(NEW.narrative_score, 50) || '; risk score ' || NEW.risk_score || '; band ' || NEW.risk_band || '.',
            add_business_days(clock_timestamp()::timestamp, r.sla_business_days));
  UPDATE confirm_attempts SET case_id = v_case WHERE claim_no = NEW.claim_no AND outcome = 'FILED';
  PERFORM audit('CASE_OPENED', NEW.policyholder_id, v_case, v_type || ' for ' || NEW.claim_no);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_claim_filed AFTER INSERT ON claims FOR EACH ROW WHEN (NEW.source = 'CHAT') EXECUTE FUNCTION apply_claim_filed();

-- Customer-safe readback: never the band, score, route name or hold.
CREATE OR REPLACE FUNCTION confirm_claim_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, claim_no VARCHAR, claim_status TEXT, handling TEXT, case_id VARCHAR, reply_text TEXT,
               deductible NUMERIC, discount_impact TEXT, reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         ca.claim_no,
         claim_status_label(c.status),
         CASE WHEN c.route = 'STANDARD' THEN 'STANDARD' WHEN c.route IS NOT NULL THEN 'REVIEW' END,
         ca.case_id,
         CASE WHEN c.claim_no IS NULL THEN NULL
              WHEN c.route = 'STANDARD' THEN 'Your claim ' || c.claim_no || ' is filed. An adjuster will contact you within 2 business days to arrange an inspection and next steps.'
              ELSE 'Your claim ' || c.claim_no || ' is filed and is under review. A claims specialist will review your claim (reference '
                   || coalesce(ca.case_id, 'pending') || ') and reply within ' || coalesce(r.sla_business_days, 5) || ' business days.' END,
         CASE WHEN c.claim_no IS NOT NULL THEN c.deductible END,
         CASE WHEN c.claim_no IS NOT NULL THEN pc.discount_impact END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND'
              WHEN ca.outcome = 'FILED' THEN NULL ELSE ca.reason_code END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'Please verify your identity again (policy number and one-time code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that claim proposal on your policy. Nothing was filed.'
              ELSE ca.reason_text END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN LATERAL (SELECT x.* FROM confirm_attempts x
                        WHERE x.policyholder_id = sm.policyholder_id AND x.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY x.attempt_id DESC LIMIT 1) ca ON TRUE
    LEFT JOIN claims c ON c.claim_no = ca.claim_no AND ca.outcome IN ('FILED','ALREADY_DONE')
    LEFT JOIN pending_claims pc ON pc.proposal_id = c.proposal_id
    LEFT JOIN service_cases s ON s.case_id = ca.case_id
    LEFT JOIN case_routing r ON r.request_type = s.request_type
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_summary TEXT, p_ref TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, policyholder_id VARCHAR, request_type VARCHAR, team VARCHAR, summary TEXT,
               reference_id VARCHAR, requested_amount NUMERIC, parked_action VARCHAR, agent_brief TEXT, sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_holder TEXT; v_policy TEXT; v_type TEXT := norm_request_type(p_type); v_ref TEXT := nullif(norm_ref(p_ref), '');
        r case_routing; v_existing TEXT; v_no BIGINT; v_case TEXT;
BEGIN
  SELECT s.policyholder_id, s.policy_number INTO v_holder, v_policy FROM session_customer(p_token) s;
  IF v_holder IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM case_routing x WHERE x.request_type = v_type AND x.customer_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (policyholder_id, request_type, reference_id, outcome, reason_code)
      VALUES (v_holder, v_type, v_ref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  IF v_ref IS NOT NULL AND v_ref ~ '^[0-9]{6}$|^CAI[0-9]{6}$' THEN v_ref := norm_policy_number(v_ref); END IF;
  IF v_type IN ('settlement_dispute', 'liability_dispute') THEN
    -- about one of the caller's own claims
    IF v_ref IS NULL OR NOT EXISTS (SELECT 1 FROM claims c WHERE c.claim_no = v_ref AND c.policyholder_id = v_holder) THEN
      INSERT INTO case_requests (policyholder_id, request_type, reference_id, outcome, reason_code)
        VALUES (v_holder, v_type, v_ref, 'NOT_FOUND', 'NOT_FOUND');
      RETURN;
    END IF;
  ELSIF v_ref IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM claims c WHERE c.claim_no = v_ref AND c.policyholder_id = v_holder)
        AND NOT EXISTS (SELECT 1 FROM policies p WHERE p.policy_number = v_ref AND p.policyholder_id = v_holder) THEN
    INSERT INTO case_requests (policyholder_id, request_type, reference_id, outcome, reason_code)
      VALUES (v_holder, v_type, v_ref, 'NOT_FOUND', 'NOT_FOUND');
    RETURN;
  END IF;
  IF v_ref IS NULL AND v_type IN ('reinstatement', 'quote_or_plan_change') THEN v_ref := v_policy; END IF;
  SELECT s.case_id INTO v_existing FROM service_cases s
   WHERE s.policyholder_id = v_holder AND s.request_type = v_type AND s.status = 'OPEN'
     AND s.reference_id IS NOT DISTINCT FROM v_ref
   ORDER BY s.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (policyholder_id, request_type, reference_id, outcome, case_id)
      VALUES (v_holder, v_type, v_ref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'CAI-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (policyholder_id, request_type, reference_id, outcome, case_id)
    VALUES (v_holder, v_type, v_ref, 'OPENED', v_case);
  PERFORM audit('CASE_OPENED', v_holder, v_case, v_type || coalesce(' for ' || v_ref, ''));
  RETURN QUERY SELECT v_no, v_case::varchar, v_holder::varchar, v_type::varchar, r.team,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_ref::varchar, NULL::numeric,
                      NULL::varchar, NULL::text, add_business_days(clock_timestamp()::timestamp, r.sla_business_days);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due DATE,
               reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.customer_team, rt.sla_text, s.sla_due_at::date,
         CASE WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN sm.policyholder_id IS NULL THEN 'Please verify your identity again (policy number and one-time code).'
              WHEN cr.outcome = 'OPENED' THEN 'Your request is open. ' || rt.sla_text
              WHEN cr.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' request (' || cr.case_id || '), so no new one was opened.'
              WHEN cr.reason_code = 'NOT_FOUND' THEN 'I could not find that claim or policy on your account, so no request was opened. Settlement and fault disputes need one of your claim numbers.'
              ELSE 'That is not a request I can open here. A person can help with settlement or fault disputes on one of your claims, reinstating a lapsed policy, quotes or coverage changes, callbacks and complaints. New claims are filed with the claim steps.' END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.policyholder_id = sm.policyholder_id
                          AND q.request_type = norm_request_type(p_type)
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked claim payment
-- =====================================================================
CREATE OR REPLACE FUNCTION customer_display(p_holder TEXT) RETURNS TEXT AS $$
  SELECT h.first_name || ' ' || left(h.last_name, 1) || '.' FROM policyholders h WHERE h.policyholder_id = p_holder
$$ LANGUAGE sql STABLE;

-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN split_part(s.parked_action, ':', 1) = 'CLAIM_PAYMENT' THEN claim_eligible_max(split_part(s.parked_action, ':', 2))
              ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, customer VARCHAR, claim_no VARCHAR, opened_on DATE,
               age_days INTEGER, reply_due DATE, sla_status TEXT, requested_amount NUMERIC, eligible_max NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.staff_label, q.customer, q.claim_no, q.opened_on, q.age_days, q.reply_due, q.sla_status,
         q.requested_amount, q.eligible_max
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, r.staff_label, customer_display(s.policyholder_id)::varchar AS customer,
             (SELECT c.claim_no FROM claims c WHERE c.claim_no = s.reference_id) AS claim_no,
             s.created_at::date AS opened_on, (current_date - s.created_at::date)::int AS age_days, s.sla_due_at::date AS reply_due,
             CASE WHEN s.sla_due_at::date < current_date THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, case_eligible_max(s.case_id) AS eligible_max, s.sla_due_at
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND s.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at
$$ LANGUAGE sql STABLE;

-- One case, minimum necessary: first name + last initial, city/state; claim facts from SQL; the AI brief (unverified).
CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, customer VARCHAR, location TEXT,
               opened_on DATE, reply_due DATE, claim_no VARCHAR, claim_type VARCHAR, incident_date DATE, incident_hour INTEGER,
               product_tier VARCHAR, estimated_amount NUMERIC, deductible NUMERIC, coverage_limit NUMERIC, eligible_max NUMERIC,
               prior_claims_24m BIGINT, policy_age_days INTEGER, repair_shop VARCHAR, customer_statement TEXT, agent_brief TEXT,
               your_approval_limit NUMERIC, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.staff_label, s.status, customer_display(s.policyholder_id)::varchar,
         CASE WHEN s.case_id IS NOT NULL THEN h.city || ', ' || h.state END,
         s.created_at::date, s.sla_due_at::date,
         c.claim_no, c.claim_type, c.incident_date, c.incident_hour, p.product_tier, c.estimated_amount, c.deductible,
         c.coverage_limit, case_eligible_max(s.case_id),
         CASE WHEN c.claim_no IS NOT NULL THEN (SELECT count(*) FROM claims o WHERE o.policyholder_id = s.policyholder_id
                AND o.claim_no <> c.claim_no AND o.incident_date < c.incident_date AND o.incident_date >= c.incident_date - 730) END,
         CASE WHEN c.claim_no IS NOT NULL THEN c.incident_date - p.effective_date END,
         c.repair_shop, s.summary, s.agent_brief,
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
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
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.team = sr.team                                   -- another team's case is invisible
    LEFT JOIN case_routing r ON r.request_type = s.request_type
    LEFT JOIN policyholders h ON h.policyholder_id = s.policyholder_id
    LEFT JOIN claims c ON c.claim_no = s.reference_id
    LEFT JOIN policies p ON p.policy_number = c.policy_number
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
  IF s.team <> rv.team THEN
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
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The approved amount must be more than $0 and no more than '
                || usd(v_max) || ' (the eligible maximum after the deductible) for this case.');
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
                coalesce((SELECT 'Claim ' || cp.claim_no || ' approved; payment ' || cp.reference || ' of ' || usd(cp.amount) || ' posted.'
                            FROM claim_payments cp WHERE cp.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN
                CASE WHEN split_part(coalesce(s.parked_action, ''), ':', 1) = 'CLAIM_PAYMENT'
                     THEN 'Case rejected; claim ' || split_part(s.parked_action, ':', 2) || ' denied; nothing was paid.'
                     ELSE 'Case rejected; nothing was executed.' END END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded row the decision trigger uses to execute the parked claim payment (same checks every time).
CREATE OR REPLACE FUNCTION claim_payment_row(p_claim TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (reference VARCHAR, claim_no VARCHAR, amount NUMERIC, case_id VARCHAR) AS $$
  SELECT ('CAI-PAY-' || lpad(nextval(pg_get_serial_sequence('claim_payments', 'payment_id'))::text, 6, '0'))::varchar,
         c.claim_no, p_amount, p_case::varchar
    FROM claims c
   WHERE c.claim_no = p_claim AND c.status IN ('Submitted','Under Review')
     AND p_amount > 0 AND p_amount <= claim_eligible_max(c.claim_no)
     AND NOT EXISTS (SELECT 1 FROM claim_payments x WHERE x.claim_no = c.claim_no)
$$ LANGUAGE sql VOLATILE;

-- The decision event: case status + customer message, then the parked action through the guarded row, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF v_kind = 'CLAIM_PAYMENT' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO claim_payments (reference, claim_no, amount, case_id) SELECT * FROM claim_payment_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN
      UPDATE claims SET status = 'Approved', approved_amount = NEW.approved_amount, payment_hold = FALSE, decided_at = NEW.decided_at
       WHERE claim_no = v_ref;
      v_done := 'claim ' || v_ref || ' approved and paid ' || usd(NEW.approved_amount);
    END IF;
  ELSIF v_kind = 'CLAIM_PAYMENT' AND NEW.decision = 'REJECT' THEN
    UPDATE claims SET status = 'Denied', decided_at = NEW.decided_at WHERE claim_no = v_ref;
    v_done := 'claim ' || v_ref || ' denied';
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id, NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- =====================================================================
-- EMAIL - only for the caller's claim filed in chat (CLM-) or decided case (CAI-CASE-)
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_reference TEXT)
RETURNS TABLE (policyholder_id VARCHAR, reference VARCHAR, kind TEXT, subject TEXT, detail TEXT) AS $$
  SELECT sm.policyholder_id, x.reference::varchar, x.kind, x.subject, x.detail
    FROM session_customer(p_token) sm
    JOIN LATERAL (
      SELECT c.claim_no::text AS reference, 'claim' AS kind, 'Copperleaf claim received ' || c.claim_no AS subject,
             'We received your ' || c.claim_type || ' claim ' || c.claim_no || ' on policy ' || c.policy_number || ' for the incident on '
             || d(c.incident_date) || ' (filed ' || d(c.filed_date) || ', estimated ' || usd(c.estimated_amount) || ', deductible '
             || usd(c.deductible) || '). Status: ' || claim_status_label(c.status) || '. '
             || CASE WHEN c.route = 'STANDARD' THEN 'An adjuster will contact you within 2 business days.'
                     ELSE 'A claims specialist will review your claim' || coalesce(' (reference ' || sc.case_id || ')', '')
                          || ' and reply within ' || coalesce(r.sla_business_days, 5) || ' business days.' END AS detail
        FROM claims c
        LEFT JOIN service_cases sc ON sc.reference_id = c.claim_no AND sc.request_type IN ('claim_review','special_investigation')
        LEFT JOIN case_routing r ON r.request_type = sc.request_type
       WHERE c.policyholder_id = sm.policyholder_id AND c.claim_no = norm_ref(p_reference) AND c.source = 'CHAT'
      UNION ALL
      SELECT s.case_id, 'decision', 'Copperleaf decision on ' || s.case_id,
             'Our ' || r.customer_team || CASE WHEN r.customer_team LIKE '%Team' THEN '' ELSE ' team' END || ' has decided your '
             || r.label || ' (' || s.case_id || coalesce(', claim ' || c.claim_no, '') || '): ' || lower(s.status) || '. '
             || s.customer_message
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
        LEFT JOIN claims c ON c.claim_no = s.reference_id
       WHERE s.policyholder_id = sm.policyholder_id AND s.case_id = norm_ref(p_reference)
         AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = s.case_id)) x ON TRUE
   WHERE sm.policyholder_id IS NOT NULL
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (policyholder_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT e.policyholder_id, e.reference, e.subject FROM email_source(p_token, p_reference) e
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.reference IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.reference IS NOT NULL THEN NULL WHEN sm.policyholder_id IS NULL THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN e.reference IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN sm.policyholder_id IS NULL THEN 'Please verify your identity again (policy number and one-time code).'
              ELSE 'There is no claim filed in chat or decided request with that reference on your account, so no email was sent.' END,
         e.reference,
         coalesce(e.subject, 'Copperleaf confirmation - not sent'),
         CASE WHEN e.reference IS NOT NULL THEN
           'Hi ' || h.first_name || ',' || chr(10) || chr(10)
           || 'This is a confirmation from Riley, the Copperleaf Auto Insurance assistant.' || chr(10) || chr(10)
           || e.detail || chr(10) || chr(10)
           || 'Thank you for insuring with Copperleaf.'
           ELSE 'No confirmation email was sent for reference ' || norm_ref(p_reference) || '.' END
    FROM (SELECT * FROM session_customer(p_token)) sm
    LEFT JOIN policyholders h ON h.policyholder_id = sm.policyholder_id
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

CREATE OR REPLACE FUNCTION ref_fnol_checklist(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM fnol_intake_guide g
          UNION ALL                                 -- who decides a filed claim: case_routing is the source of truth
          SELECT 'WHO_DECIDES', c.label::text, c.team::text || ': ' || c.sla_text::text, 1000
            FROM case_routing c WHERE c.request_type = 'claim_review') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CLAIM_TYPE','FNOL_FIELD','TYPE_DETAIL','WHO_DECIDES','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_coverage_clauses(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM coverage_clause_index g
          UNION ALL                                 -- who decides an EXCLUDED / larger claim: case_routing
          SELECT 'WHO_DECIDES', c.label::text, c.team::text || ': ' || c.sla_text::text, 1000
            FROM case_routing c WHERE c.request_type = 'claim_review') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['COVERAGE','PRODUCT_TIER','EXCLUSION','TERM','FINDING','WHO_DECIDES'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_claim_indicators(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM claim_indicator_guide g
          UNION ALL                                 -- who decides a reviewed claim: case_routing (customer-facing
          SELECT 'WHO_DECIDES', c.customer_team::text, c.sla_text::text,   -- team names only - never the internal one)
                 1000 + c.sla_business_days
            FROM case_routing c WHERE c.request_type IN ('claim_review', 'special_investigation')) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['INDICATOR','SCORE_BAND','SIGNAL','RULE','WHO_DECIDES'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
