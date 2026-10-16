-- Bellmont Regional Medical Center - Hospital Post-Discharge Care (GOVERNED) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: hospital_governed
-- Load:  createdb hospital_governed  &&  psql -d hospital_governed -f database.sql
--
-- =====================================================================
-- Fictional US hospital "Bellmont Regional Medical Center", assistant "Bellmont Discharge Assistant".
-- The rules live HERE, not in any prompt:
--   * session_coordinator() / session_reviewer()  identity: every tool is scoped by a session token; coordinator
--                                              and reviewer tokens are not interchangeable (role checked)
--   * verify_*_fn()                            staff id + one-time code -> session; 5 failures / 15 min -> LOCKED
--   * ward_* / discharge_summary() / ...       scoped reads - only the coordinator's ward; another ward -> NOT_FOUND
--   * followup_eval()                          follow-up booking rules (required, specialty, window, open slot)
--   * propose_followup_fn() / confirm_action_fn()  two-step: PROPOSED/BLOCKED with 15-minute expiry; confirm re-checks
--   * med_order_rows()                         only medicines on the discharge list; high-alert -> pharmacist case
--   * bed_turnover_row()                       only a bed on the ward whose patient has actually left
--   * open_case_row()                          human-owned requests routed by case_routing (team + SLA hours)
--   * decide_case_row() + trg_review_decision  the reviewer loop: role/team/authority/amount checks, then the
--                                              parked action (dispense / bed turnover) runs through guarded rows
--   * email_log_row()                          email only for a patient on the ward with an executed action
--   * ref_plain_language() / ref_med_rec() / ref_slot_guide()  the A2A agents' ONLY database access: read-only
--                                              reference tables (glossaries, drug classes, slot rules) with no
--                                              patient or staff data; one optional lookup term, never an identity
-- HIPAA minimum necessary: coordinators never get date of birth, address, phone, email or insurance id;
-- reviewers never get the MRN or full last name; the AI agents get no identity at all.
-- All demo dates are relative to CURRENT_DATE / now() (seed_data.sql).
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

DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, case_requests, service_cases,
  bed_attempts, bed_events, med_order_attempts, pharmacy_orders, confirm_attempts, appointment_events, pending_actions,
  appointments, clinic_slots, discharge_medications, discharges, beds, patients, verify_attempts, sessions, reviewers,
  coordinators, case_routing, medication_catalog, specialties, wards, plain_language_guide, med_rec_reference,
  slot_ranking_guide CASCADE;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE wards (
  ward_id     VARCHAR(4) PRIMARY KEY,            -- 4A
  ward_name   VARCHAR(60) NOT NULL
);

CREATE TABLE specialties (
  specialty_code VARCHAR(16) PRIMARY KEY,        -- CARDIOLOGY
  specialty_name VARCHAR(60) NOT NULL
);

CREATE TABLE medication_catalog (
  medication_code VARCHAR(10) PRIMARY KEY,       -- MED-101
  generic_name    VARCHAR(40) NOT NULL,          -- warfarin
  strength        VARCHAR(20) NOT NULL,          -- 5 mg
  form            VARCHAR(20) NOT NULL,          -- tablet
  also_known_as   VARCHAR(80),                   -- brand / common names, used only to match what people type
  high_alert      BOOLEAN NOT NULL DEFAULT FALSE,-- ISMP-style high-alert class -> pharmacist review before dispensing
  prep_minutes    INTEGER NOT NULL               -- pharmacy preparation time
);

-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO patient, staff, case, session or contact data, ever.
CREATE TABLE plain_language_guide (               -- discharge_instructions_agent: medical words -> plain words
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('PRESCRIPTION_WORD', 'PICKUP', 'APPOINTMENT_TYPE', 'PENDING',
                                                      'READING_LEVEL', 'SAFETY_NET')),
  term        VARCHAR(60) NOT NULL,               -- by mouth
  meaning     VARCHAR(300) NOT NULL,              -- swallow it
  UNIQUE (section, term)
);

CREATE TABLE med_rec_reference (                  -- med_reconciliation_agent: common names, drug classes, flag rules
  entry_id    SERIAL PRIMARY KEY,                 -- (the high-alert list comes from medication_catalog.high_alert)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('COMMON_NAME', 'DRUG_CLASS', 'FLAG_TYPE', 'ALWAYS_FLAG', 'RULE')),
  term        VARCHAR(60) NOT NULL,               -- baby aspirin
  meaning     VARCHAR(300) NOT NULL,              -- aspirin 81 mg (antiplatelet)
  UNIQUE (section, term)
);

CREATE TABLE slot_ranking_guide (                 -- followup_slot_agent: slot codes and ranking rules
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('PART_OF_DAY', 'ACCESS_CODE', 'TRANSPORT_CODE', 'CONSTRAINT',
                                                      'SEQUENCE', 'RANKING')),
  term        VARCHAR(60) NOT NULL,               -- morning
  meaning     VARCHAR(300) NOT NULL,              -- starts before 12:00
  UNIQUE (section, term)
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type         VARCHAR(30) PRIMARY KEY,
  label                VARCHAR(50) NOT NULL,     -- coordinator-facing name
  team                 VARCHAR(40) NOT NULL,
  sla_hours            INTEGER NOT NULL,
  sla_text             VARCHAR(160) NOT NULL,
  coordinator_openable BOOLEAN NOT NULL DEFAULT TRUE   -- high_alert_med is opened only by order_discharge_meds
);

-- ---------------------------------------------------------------------
-- Staff: discharge coordinators (scoped to a ward) and reviewers (scoped to a team)
-- ---------------------------------------------------------------------
CREATE TABLE coordinators (
  staff_id       VARCHAR(10) PRIMARY KEY,        -- BMC-4101
  display_name   VARCHAR(60) NOT NULL,
  ward_id        VARCHAR(4) NOT NULL REFERENCES wards,
  one_time_code  VARCHAR(6) NOT NULL,            -- HIDDEN: demo stand-in for the badge-tap / authenticator code
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- BMC-7701 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,          -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN
  approval_limit  NUMERIC(6,0),                  -- max days' supply of a high-alert medicine they may approve; NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(12) NOT NULL CHECK (role IN ('COORDINATOR','REVIEWER')),
  coordinator_id VARCHAR(10) REFERENCES coordinators,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'COORDINATOR' AND coordinator_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND coordinator_id IS NULL))
);

-- Every verify call (throttle + readback).
CREATE TABLE verify_attempts (
  attempt_id   BIGSERIAL PRIMARY KEY,
  role         VARCHAR(12) NOT NULL,
  identifier   VARCHAR(40) NOT NULL,             -- normalised as typed
  outcome      VARCHAR(14) NOT NULL CHECK (outcome IN ('VERIFIED','VERIFY_FAILED','LOCKED')),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_verify_attempts ON verify_attempts (role, identifier, created_at);

-- ---------------------------------------------------------------------
-- Patients, beds, discharges, medicines, clinic slots, appointments
-- ---------------------------------------------------------------------
CREATE TABLE patients (
  patient_id      VARCHAR(10) PRIMARY KEY,       -- MRN-4012 (medical record number)
  first_name      VARCHAR(40) NOT NULL,
  last_name       VARCHAR(40) NOT NULL,
  date_of_birth   DATE NOT NULL,                 -- HIDDEN (age is derived in SQL for the pharmacist)
  phone           VARCHAR(20) NOT NULL,          -- HIDDEN
  email           VARCHAR(100) NOT NULL,         -- HIDDEN (emails go to the EMAIL_TO demo inbox)
  home_address    VARCHAR(120) NOT NULL,         -- HIDDEN
  insurance_id    VARCHAR(20) NOT NULL           -- HIDDEN
);

CREATE TABLE beds (
  bed_id          VARCHAR(8) PRIMARY KEY,        -- 4A-10
  ward_id         VARCHAR(4) NOT NULL REFERENCES wards,
  patient_id      VARCHAR(10) REFERENCES patients,
  status          VARCHAR(22) NOT NULL CHECK (status IN ('OCCUPIED','AVAILABLE','CLEANING_REQUESTED','CLEANING_IN_PROGRESS')),
  updated_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  estimated_ready TIMESTAMP
);

CREATE TABLE discharges (
  discharge_id      SERIAL PRIMARY KEY,
  patient_id        VARCHAR(10) NOT NULL UNIQUE REFERENCES patients,
  ward_id           VARCHAR(4) NOT NULL REFERENCES wards,
  bed_id            VARCHAR(8) NOT NULL REFERENCES beds,
  service           VARCHAR(40) NOT NULL,         -- admitting service (no diagnosis: minimum necessary)
  attending         VARCHAR(60) NOT NULL,
  status            VARCHAR(12) NOT NULL CHECK (status IN ('PENDING','ORDERED','DISCHARGED')),
  planned_date      DATE,                         -- set when the attending signs the discharge order
  discharge_date    DATE,                         -- the day the patient actually left
  discharged_at     TIMESTAMP,
  followup_required BOOLEAN NOT NULL DEFAULT FALSE,
  followup_specialty VARCHAR(16) REFERENCES specialties,
  followup_min_days INTEGER,                      -- follow-up window, days after the discharge date
  followup_max_days INTEGER,
  isolation         BOOLEAN NOT NULL DEFAULT FALSE  -- contact isolation -> terminal (90-minute) bed clean
);

CREATE TABLE discharge_medications (
  dm_id            SERIAL PRIMARY KEY,
  discharge_id     INTEGER NOT NULL REFERENCES discharges,
  medication_code  VARCHAR(10) NOT NULL REFERENCES medication_catalog,
  instructions     VARCHAR(120) NOT NULL,         -- as prescribed (copied exactly, never changed by the AI)
  days_supply      INTEGER NOT NULL CHECK (days_supply > 0),
  indication       VARCHAR(80) NOT NULL,          -- for the pharmacist's review
  UNIQUE (discharge_id, medication_code)
);

CREATE TABLE clinic_slots (
  slot_id               VARCHAR(10) PRIMARY KEY,  -- SLOT-C105
  specialty_code        VARCHAR(16) NOT NULL REFERENCES specialties,
  clinician             VARCHAR(60) NOT NULL,
  starts_at             TIMESTAMP NOT NULL,
  location              VARCHAR(60) NOT NULL,
  wheelchair_accessible BOOLEAN NOT NULL,
  transport_available   BOOLEAN NOT NULL,         -- Bellmont patient transport (wheelchair van) runs to this slot
  status                VARCHAR(8) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','BOOKED'))
);

CREATE TABLE appointments (
  appointment_id  VARCHAR(16) PRIMARY KEY,        -- APT-0001 (seed) / BMC-APT-000101 (booked in chat)
  patient_id      VARCHAR(10) NOT NULL REFERENCES patients,
  appt_type       VARCHAR(30) NOT NULL,           -- Follow-up visit, Echocardiogram, ...
  specialty_code  VARCHAR(16) REFERENCES specialties,
  slot_id         VARCHAR(10) REFERENCES clinic_slots,
  starts_at       TIMESTAMP NOT NULL,
  location        VARCHAR(60) NOT NULL,
  clinician       VARCHAR(60),
  status          VARCHAR(10) NOT NULL DEFAULT 'SCHEDULED' CHECK (status IN ('SCHEDULED','COMPLETED','CANCELLED')),
  source          VARCHAR(6) NOT NULL DEFAULT 'SEED' CHECK (source IN ('SEED','CHAT')),
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Two-step follow-up booking
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'BMC-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  coordinator_id VARCHAR(10) NOT NULL REFERENCES coordinators,
  action_type    VARCHAR(20) NOT NULL CHECK (action_type IN ('BOOK_FOLLOWUP')),
  target_key     TEXT NOT NULL,                   -- normalised request (patient|slot), shared by write-row and readback
  patient_id     VARCHAR(10),
  slot_id        VARCHAR(10),
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_coord ON pending_actions (coordinator_id, action_type, target_key, created_at);

CREATE TABLE appointment_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(16) NOT NULL UNIQUE,     -- BMC-APT-000101
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  coordinator_id VARCHAR(10) NOT NULL REFERENCES coordinators,
  patient_id     VARCHAR(10) NOT NULL REFERENCES patients,
  slot_id        VARCHAR(10) NOT NULL REFERENCES clinic_slots,
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  coordinator_id VARCHAR(10) NOT NULL REFERENCES coordinators,
  proposal_ref   TEXT NOT NULL,
  outcome        VARCHAR(14) NOT NULL,
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  reference      VARCHAR(16),
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Pharmacy orders and bed turnover (guarded single-step writes)
-- ---------------------------------------------------------------------
CREATE TABLE pharmacy_orders (
  order_no        BIGSERIAL PRIMARY KEY,
  order_id        VARCHAR(12) NOT NULL UNIQUE,    -- RX-000101
  dm_id           INTEGER NOT NULL UNIQUE REFERENCES discharge_medications,   -- one order per prescribed medicine
  patient_id      VARCHAR(10) NOT NULL REFERENCES patients,
  medication_code VARCHAR(10) NOT NULL REFERENCES medication_catalog,
  days_supply     INTEGER NOT NULL CHECK (days_supply > 0),
  pickup_location VARCHAR(60) NOT NULL,
  ready_by        TIMESTAMP NOT NULL,
  status          VARCHAR(12) NOT NULL DEFAULT 'PROCESSING' CHECK (status IN ('PROCESSING','READY','PICKED_UP')),
  ordered_by      VARCHAR(10) NOT NULL,           -- coordinator or reviewer staff id
  case_id         VARCHAR(16),                    -- the pharmacist case that released it (high-alert)
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE med_order_attempts (                 -- every order_discharge_meds call, one row per medicine (readback)
  attempt_id      BIGSERIAL PRIMARY KEY,
  batch_id        BIGINT NOT NULL,                -- txid of the write; the readback shows the latest batch
  coordinator_id  VARCHAR(10) NOT NULL REFERENCES coordinators,
  patient_ref     VARCHAR(40) NOT NULL,
  medication_ref  VARCHAR(60),
  medication_code VARCHAR(10),
  days_supply     INTEGER,
  outcome         VARCHAR(24) NOT NULL,
  reason_code     VARCHAR(24),
  reason_text     TEXT,
  order_id        VARCHAR(12),
  pickup_location VARCHAR(60),
  ready_by        TIMESTAMP,
  case_id         VARCHAR(16),
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE bed_events (
  event_no        BIGSERIAL PRIMARY KEY,
  reference       VARCHAR(16) NOT NULL UNIQUE,    -- BMC-BED-000101
  bed_id          VARCHAR(8) NOT NULL REFERENCES beds,
  ward_id         VARCHAR(4) NOT NULL,
  patient_id      VARCHAR(10) NOT NULL,
  override        BOOLEAN NOT NULL DEFAULT FALSE, -- TRUE only when a charge nurse approved an early turnover
  requested_by    VARCHAR(10) NOT NULL,
  case_id         VARCHAR(16),
  estimated_ready TIMESTAMP NOT NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE bed_attempts (                       -- every request_bed_turnover call (readback)
  attempt_id      SERIAL PRIMARY KEY,
  coordinator_id  VARCHAR(10) NOT NULL REFERENCES coordinators,
  bed_ref         VARCHAR(40) NOT NULL,
  outcome         VARCHAR(12) NOT NULL,
  reason_code     VARCHAR(24),
  reason_text     TEXT,
  reference       VARCHAR(16),
  estimated_ready TIMESTAMP,
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,   -- BMC-CASE-000101
  patient_id       VARCHAR(10) NOT NULL REFERENCES patients,
  ward_id          VARCHAR(4) NOT NULL REFERENCES wards,
  opened_by        VARCHAR(10) NOT NULL,          -- coordinator staff id
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary          TEXT NOT NULL,                 -- the request, neutral, in the coordinator's words
  reference_id     VARCHAR(16),                   -- medicine / bed the case is about
  requested_amount NUMERIC(6,0),                  -- days' supply asked for (high-alert medicine), else NULL
  parked_action    VARCHAR(40),                   -- what runs on approval: MED_ORDER:<dm_id> / BED_TURNOVER:<bed>
  agent_brief      TEXT,                          -- AI-prepared neutral brief (med-rec flags); never shown to the coordinator
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                          -- coordinator-safe outcome text, set by the decision
  approved_amount  NUMERIC(6,0),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_patient ON service_cases (patient_id, request_type, status);

CREATE TABLE case_requests (                      -- every open_service_case call (readback)
  request_id      SERIAL PRIMARY KEY,
  coordinator_id  VARCHAR(10) NOT NULL REFERENCES coordinators,
  request_type    VARCHAR(40) NOT NULL,
  patient_ref     VARCHAR(40),
  outcome         VARCHAR(16) NOT NULL,
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
  approved_amount  NUMERIC(6,0),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),
  customer_message TEXT NOT NULL,
  decided_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE decide_attempts (                    -- every decide call by a verified reviewer (readback)
  attempt_id    SERIAL PRIMARY KEY,
  reviewer_id   VARCHAR(10) NOT NULL REFERENCES reviewers,
  case_ref      VARCHAR(40) NOT NULL,
  outcome       VARCHAR(10) NOT NULL,             -- APPROVED / REJECTED / BLOCKED
  reason_code   VARCHAR(24),
  reason_text   TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE agent_audit (
  audit_id    BIGSERIAL PRIMARY KEY,
  event_type  VARCHAR(20) NOT NULL,               -- FOLLOWUP_BOOKED / ORDER_PLACED / BED_TURNOVER / CASE_OPENED / CASE_DECIDED
  actor       VARCHAR(10) NOT NULL,               -- coordinator or reviewer staff id
  subject_id  VARCHAR(16) NOT NULL,               -- reference / order id / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id       SERIAL PRIMARY KEY,
  patient_id     VARCHAR(10) NOT NULL REFERENCES patients,
  coordinator_id VARCHAR(10) NOT NULL REFERENCES coordinators,
  subject        TEXT NOT NULL,
  logged_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- HELPERS
-- =====================================================================
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION dt(p TIMESTAMP) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD HH24:MI') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION wday(p TIMESTAMP) RETURNS TEXT AS $$ SELECT trim(to_char(p, 'Day')) $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION yn(b BOOLEAN) RETURNS TEXT AS $$ SELECT CASE WHEN b IS NULL THEN NULL WHEN b THEN 'yes' ELSE 'no' END $$ LANGUAGE sql IMMUTABLE;

-- BMC-4101 / bmc4101 / BMC 4101 / 4101 -> BMC-4101
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'BMC-' || x
              WHEN x ~ '^BMC[0-9]{4}$' THEN 'BMC-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- MRN-4012 / mrn4012 / MRN 4012 / 4012 -> MRN-4012
CREATE OR REPLACE FUNCTION norm_mrn(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'MRN-' || x
              WHEN x ~ '^MRN[0-9]{4}$' THEN 'MRN-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- 4A-10 / BED-4A-010 / bed 4a10 / 4A 10 -> 4A-10
CREATE OR REPLACE FUNCTION norm_bed(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9][A-Z][0-9]{1,4}$'
              THEN substr(x, 1, 2) || '-' || lpad((substring(x FROM 3))::int::text, 2, '0')
              ELSE left(x, 40) END
    FROM (SELECT regexp_replace(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '^BED', '') AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ids typed by people or the model: ' slot-c105 ' -> 'SLOT-C105'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- '14', '14 days', '14-day supply' -> '14'; '' -> ''; anything else -> upper text (-> AMOUNT_INVALID)
CREATE OR REPLACE FUNCTION norm_days(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN trim(coalesce(p, '')) = '' THEN ''
              WHEN trim(p) ~* '^-?[0-9]+(\.0+)?\s*(-?\s*days?(\s+supply)?|d)?$'
              THEN substring(trim(p) FROM '^-?[0-9]+')
              ELSE left(upper(trim(p)), 20) END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION days_txt(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL WHEN n = 1 THEN '1 day' ELSE trim_scale(n)::text || ' days' END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION age_years(p DATE) RETURNS INTEGER AS $$
  SELECT extract(year FROM age(current_date, p))::int
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION add_business_days(p_from DATE, p_days INTEGER) RETURNS DATE AS $$
DECLARE t DATE := p_from; n INTEGER := 0;
BEGIN
  WHILE n < p_days LOOP
    t := t + 1;
    IF extract(isodow FROM t) < 6 THEN n := n + 1; END IF;
  END LOOP;
  RETURN t;
END $$ LANGUAGE plpgsql IMMUTABLE;
CREATE OR REPLACE FUNCTION med_label(p_code TEXT) RETURNS TEXT AS $$
  SELECT initcap(m.generic_name) || ' ' || m.strength || ' ' || m.form FROM medication_catalog m WHERE m.medication_code = p_code
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION patient_name(p TEXT) RETURNS TEXT AS $$
  SELECT x.first_name || ' ' || x.last_name FROM patients x WHERE x.patient_id = p
$$ LANGUAGE sql STABLE;
-- Reviewer view (minimum necessary): first name + last initial
CREATE OR REPLACE FUNCTION patient_display(p TEXT) RETURNS TEXT AS $$
  SELECT x.first_name || ' ' || left(x.last_name, 1) || '.' FROM patients x WHERE x.patient_id = p
$$ LANGUAGE sql STABLE;
-- Pickup depends on where the patient is: still on the unit -> delivered to the bedside; left -> outpatient pharmacy
CREATE OR REPLACE FUNCTION pickup_for(p_status TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN p_status = 'DISCHARGED' THEN 'Bellmont Outpatient Pharmacy, Main Lobby' ELSE 'Meds-to-Beds bedside delivery' END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;
-- The coordinator's patient: only when the patient's discharge belongs to the coordinator's ward.
CREATE OR REPLACE FUNCTION ward_patient(p_ward TEXT, p_patient TEXT) RETURNS TEXT AS $$
  SELECT x.patient_id FROM discharges x WHERE x.patient_id = norm_mrn(p_patient) AND x.ward_id = p_ward
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- IDENTITY (coordinators and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the coordinator + ward when the token is a valid COORDINATOR token, else NULLs.
CREATE OR REPLACE FUNCTION session_coordinator(p_token TEXT)
RETURNS TABLE (staff_id VARCHAR, ward_id VARCHAR, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT c.staff_id, c.ward_id, c.display_name
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'COORDINATOR'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN coordinators c ON c.staff_id = s.coordinator_id AND c.active;
END $$ LANGUAGE plpgsql STABLE;

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

-- Guarded write-row for verify_coordinator: records the attempt (throttle); returns the sessions row ONLY for a
-- matching staff id + code while the id is not locked (5 failures in 15 minutes).
CREATE OR REPLACE FUNCTION verify_coordinator_fn(p_staff TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, coordinator_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_staff_id(p_staff); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'COORDINATOR' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('COORDINATOR', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT c.staff_id INTO v_match FROM coordinators c
   WHERE c.staff_id = v_id AND c.one_time_code = trim(coalesce(p_code, '')) AND c.active;
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('COORDINATOR', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('COORDINATOR', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'COORDINATOR'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_coordinator_result(p_staff TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, role TEXT, display_name VARCHAR, ward TEXT, expires_at TIMESTAMP, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'COORDINATOR' END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.display_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.ward END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.expires_at END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL
                THEN 'You are verified as the discharge coordinator for ' || se.ward || '. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For security, verification is paused for 15 minutes. Please try again later.'
              ELSE 'That staff ID and code do not match our records. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'COORDINATOR' AND a.identifier = norm_staff_id(p_staff)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, c.display_name, 'Ward ' || w.ward_id || ' ' || w.ward_name AS ward, s.expires_at
                         FROM coordinators c JOIN wards w ON w.ward_id = c.ward_id
                         JOIN sessions s ON s.coordinator_id = c.staff_id AND s.role = 'COORDINATOR' AND s.expires_at > clock_timestamp()
                        WHERE c.staff_id = norm_staff_id(p_staff) AND c.one_time_code = trim(coalesce(p_code, '')) AND c.active
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
                        WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active
                        ORDER BY s.created_at DESC LIMIT 1) se ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- SCOPED READS (coordinator) - every function starts FROM session_coordinator(token) and stays on that ward
-- =====================================================================
CREATE OR REPLACE FUNCTION ward_discharges(p_token TEXT)
RETURNS TABLE (status TEXT, ward TEXT, patient_id VARCHAR, patient_name TEXT, bed_id VARCHAR, discharge_status VARCHAR,
               planned_date DATE, discharged_at TEXT, follow_up TEXT, follow_up_booked TEXT, meds_on_list BIGINT,
               meds_ordered BIGINT, meds_in_pharmacist_review BIGINT, bed_status VARCHAR) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         CASE WHEN sc.staff_id IS NOT NULL THEN 'Ward ' || w.ward_id || ' ' || w.ward_name END,
         x.patient_id, patient_name(x.patient_id), x.bed_id, x.status, x.planned_date, dt(x.discharged_at),
         CASE WHEN x.discharge_id IS NULL THEN NULL WHEN x.followup_required
              THEN s.specialty_name || ' within ' || x.followup_min_days || '-' || x.followup_max_days || ' days' ELSE 'not required' END,
         (SELECT 'yes - ' || dt(a.starts_at) FROM appointments a WHERE a.patient_id = x.patient_id AND a.appt_type = 'Follow-up visit'
             AND a.status = 'SCHEDULED' ORDER BY a.starts_at LIMIT 1),
         (SELECT count(*) FROM discharge_medications dm WHERE dm.discharge_id = x.discharge_id),
         (SELECT count(*) FROM discharge_medications dm JOIN pharmacy_orders po ON po.dm_id = dm.dm_id WHERE dm.discharge_id = x.discharge_id),
         (SELECT count(*) FROM service_cases c WHERE c.patient_id = x.patient_id AND c.request_type = 'high_alert_med' AND c.status = 'OPEN'),
         b.status
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN wards w ON w.ward_id = sc.ward_id
    LEFT JOIN discharges x ON x.ward_id = sc.ward_id
    LEFT JOIN specialties s ON s.specialty_code = x.followup_specialty
    LEFT JOIN beds b ON b.bed_id = x.bed_id
   ORDER BY CASE x.status WHEN 'DISCHARGED' THEN 1 WHEN 'ORDERED' THEN 2 ELSE 3 END, x.bed_id
$$ LANGUAGE sql STABLE;

-- One row per discharge medicine (header fields repeated); another ward's patient -> NOT_FOUND.
CREATE OR REPLACE FUNCTION discharge_summary(p_token TEXT, p_patient TEXT)
RETURNS TABLE (status TEXT, patient_id VARCHAR, patient_name TEXT, bed_id VARCHAR, service VARCHAR, attending VARCHAR,
               discharge_status VARCHAR, planned_date DATE, discharged_at TEXT, follow_up_required TEXT, follow_up_specialty VARCHAR,
               follow_up_window TEXT, isolation TEXT, medication_code VARCHAR, medication TEXT, high_alert TEXT,
               instructions VARCHAR, days_supply INTEGER, order_status TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN x.discharge_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         x.patient_id, patient_name(x.patient_id), x.bed_id, x.service, x.attending, x.status, x.planned_date, dt(x.discharged_at),
         yn(x.followup_required), s.specialty_name,
         CASE WHEN x.discharge_id IS NULL OR NOT x.followup_required THEN NULL
              WHEN coalesce(x.discharge_date, x.planned_date) IS NULL THEN 'set once the discharge order is signed'
              ELSE 'between ' || d(coalesce(x.discharge_date, x.planned_date) + x.followup_min_days) || ' and '
                   || d(coalesce(x.discharge_date, x.planned_date) + x.followup_max_days) END,
         yn(x.isolation), dm.medication_code, med_label(dm.medication_code), yn(m.high_alert), dm.instructions, dm.days_supply,
         CASE WHEN dm.dm_id IS NULL THEN NULL
              WHEN po.order_id IS NOT NULL THEN 'ORDERED ' || po.order_id || ' (' || days_txt(po.days_supply) || ', ready by '
                   || dt(po.ready_by) || ', ' || po.pickup_location || ')'
              WHEN hc.case_id IS NOT NULL THEN 'PHARMACIST REVIEW ' || hc.case_id || ' (' || hc.status || ')'
              ELSE 'NOT ORDERED' END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN discharges x ON x.patient_id = norm_mrn(p_patient) AND x.ward_id = sc.ward_id
    LEFT JOIN specialties s ON s.specialty_code = x.followup_specialty
    LEFT JOIN discharge_medications dm ON dm.discharge_id = x.discharge_id
    LEFT JOIN medication_catalog m ON m.medication_code = dm.medication_code
    LEFT JOIN pharmacy_orders po ON po.dm_id = dm.dm_id
    LEFT JOIN LATERAL (SELECT c.case_id, c.status FROM service_cases c WHERE c.parked_action = 'MED_ORDER:' || dm.dm_id
                        ORDER BY c.created_at DESC LIMIT 1) hc ON TRUE
   ORDER BY dm.dm_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION patient_appointments(p_token TEXT, p_patient TEXT)
RETURNS TABLE (status TEXT, appointment_id VARCHAR, appointment_type VARCHAR, specialty VARCHAR, starts_at TEXT, weekday TEXT,
               location VARCHAR, clinician VARCHAR, appointment_status VARCHAR) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN wp.pid IS NULL THEN 'NOT_FOUND'
              WHEN a.appointment_id IS NULL THEN 'NONE' ELSE 'OK' END,
         a.appointment_id, a.appt_type, s.specialty_name, dt(a.starts_at), wday(a.starts_at), a.location, a.clinician, a.status
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT ward_patient(sc.ward_id, p_patient) AS pid) wp ON TRUE
    LEFT JOIN appointments a ON a.patient_id = wp.pid
    LEFT JOIN specialties s ON s.specialty_code = a.specialty_code
   ORDER BY a.starts_at
$$ LANGUAGE sql STABLE;

-- Patient-level follow-up rules (shared by the slot list, propose and confirm).
CREATE OR REPLACE FUNCTION followup_patient_check(p_ward TEXT, p_patient TEXT)
RETURNS TABLE (code TEXT, reason_text TEXT, patient_id VARCHAR, pname TEXT, specialty_code VARCHAR, specialty_name VARCHAR,
               win_from DATE, win_to DATE) AS $$
  SELECT CASE WHEN x.discharge_id IS NULL THEN 'NOT_FOUND'
              WHEN x.status = 'PENDING' THEN 'DISCHARGE_NOT_ORDERED'
              WHEN NOT x.followup_required THEN 'NO_FOLLOWUP_REQUIRED'
              WHEN bk.appointment_id IS NOT NULL THEN 'ALREADY_BOOKED'
              ELSE 'OK' END,
         CASE WHEN x.discharge_id IS NULL THEN 'I could not find that patient on your ward.'
              WHEN x.status = 'PENDING' THEN patient_name(x.patient_id) || ' has no signed discharge order yet, so a follow-up cannot be booked. The attending decides the discharge.'
              WHEN NOT x.followup_required THEN 'The discharge order for ' || patient_name(x.patient_id) || ' does not ask for a follow-up visit, so none can be booked here.'
              WHEN bk.appointment_id IS NOT NULL THEN patient_name(x.patient_id) || ' already has a ' || s.specialty_name || ' follow-up on ' || dt(bk.starts_at) || ' (' || bk.appointment_id || ').'
              ELSE NULL END,
         x.patient_id, patient_name(x.patient_id), x.followup_specialty, s.specialty_name,
         coalesce(x.discharge_date, x.planned_date) + x.followup_min_days,
         coalesce(x.discharge_date, x.planned_date) + x.followup_max_days
    FROM (SELECT 1) one
    LEFT JOIN discharges x ON x.patient_id = norm_mrn(p_patient) AND x.ward_id = p_ward
    LEFT JOIN specialties s ON s.specialty_code = x.followup_specialty
    LEFT JOIN LATERAL (SELECT a.appointment_id, a.starts_at FROM appointments a
                        WHERE a.patient_id = x.patient_id AND a.appt_type = 'Follow-up visit' AND a.status = 'SCHEDULED'
                          AND a.specialty_code = x.followup_specialty ORDER BY a.starts_at LIMIT 1) bk ON TRUE
$$ LANGUAGE sql STABLE;

-- Eligible follow-up slots only: OPEN, the discharge's specialty, inside the follow-up window.
CREATE OR REPLACE FUNCTION followup_slots(p_token TEXT, p_patient TEXT)
RETURNS TABLE (status TEXT, patient_name TEXT, specialty VARCHAR, window_from DATE, window_to DATE, slot_id VARCHAR, weekday TEXT,
               slot_date DATE, slot_time TEXT, part_of_day TEXT, location VARCHAR, clinician VARCHAR, wheelchair_accessible TEXT,
               transport_available TEXT, reason_text TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN fc.code <> 'OK' THEN fc.code
              WHEN cs.slot_id IS NULL THEN 'NONE_AVAILABLE' ELSE 'OK' END,
         fc.pname, fc.specialty_name, fc.win_from, fc.win_to, cs.slot_id, wday(cs.starts_at), cs.starts_at::date,
         to_char(cs.starts_at, 'HH24:MI'),
         CASE WHEN cs.slot_id IS NULL THEN NULL WHEN extract(hour FROM cs.starts_at) < 12 THEN 'morning'
              WHEN extract(hour FROM cs.starts_at) < 17 THEN 'afternoon' ELSE 'evening' END,
         cs.location, cs.clinician, yn(cs.wheelchair_accessible), yn(cs.transport_available),
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN fc.code <> 'OK' THEN fc.reason_text
              WHEN cs.slot_id IS NULL THEN 'There are no open ' || fc.specialty_name || ' slots in the follow-up window. A scheduler can add one.'
              ELSE NULL END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT * FROM followup_patient_check(sc.ward_id, p_patient)) fc ON sc.staff_id IS NOT NULL
    LEFT JOIN clinic_slots cs ON fc.code = 'OK' AND cs.specialty_code = fc.specialty_code AND cs.status = 'OPEN'
         AND cs.starts_at::date BETWEEN fc.win_from AND fc.win_to AND cs.starts_at > clock_timestamp()
   ORDER BY cs.starts_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION patient_pharmacy_orders(p_token TEXT, p_patient TEXT)
RETURNS TABLE (status TEXT, order_id VARCHAR, medication TEXT, days_supply INTEGER, pickup_location VARCHAR, ready_by TEXT,
               order_status VARCHAR, released TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN wp.pid IS NULL THEN 'NOT_FOUND'
              WHEN po.order_id IS NULL THEN 'NONE' ELSE 'OK' END,
         po.order_id, med_label(po.medication_code), po.days_supply, po.pickup_location, dt(po.ready_by), po.status,
         CASE WHEN po.order_id IS NULL THEN NULL WHEN po.case_id IS NOT NULL THEN 'after pharmacist review (' || po.case_id || ')'
              ELSE 'ordered from the discharge list' END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT ward_patient(sc.ward_id, p_patient) AS pid) wp ON TRUE
    LEFT JOIN pharmacy_orders po ON po.patient_id = wp.pid
   ORDER BY po.order_no
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ward_beds(p_token TEXT)
RETURNS TABLE (status TEXT, bed_id VARCHAR, bed_status VARCHAR, patient_name TEXT, patient_discharge_status VARCHAR,
               estimated_ready TEXT, updated_at TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         b.bed_id, b.status, patient_name(b.patient_id), x.status, dt(b.estimated_ready), dt(b.updated_at)
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN beds b ON b.ward_id = sc.ward_id
    LEFT JOIN discharges x ON x.patient_id = b.patient_id
   ORDER BY b.bed_id
$$ LANGUAGE sql STABLE;

-- The ward's cases (shift hand-over friendly). Never the internal note, the agent brief or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, patient_name TEXT, about VARCHAR, team VARCHAR, case_status VARCHAR,
               opened_at TEXT, reply_due TEXT, requested_days NUMERIC, approved_days NUMERIC, decided_at TEXT,
               customer_message TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN c.case_id IS NULL THEN 'NONE' ELSE 'OK' END,
         c.case_id, r.label, patient_name(c.patient_id), c.reference_id, r.team, c.status, dt(c.created_at), dt(c.sla_due_at),
         c.requested_amount, c.approved_amount, dt(c.decided_at),
         CASE WHEN c.case_id IS NULL THEN NULL
              WHEN c.status = 'OPEN' THEN 'Open - a person on the ' || r.team || ' team will decide.' ELSE c.customer_message END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN service_cases c ON c.ward_id = sc.ward_id
    LEFT JOIN case_routing r ON r.request_type = c.request_type
   ORDER BY c.created_at DESC
$$ LANGUAGE sql STABLE;

DROP SEQUENCE IF EXISTS rx_seq;
CREATE SEQUENCE rx_seq START 101;                 -- pharmacy order ids RX-000101 ... (reset in seed_data.sql)
DROP SEQUENCE IF EXISTS bed_seq;
CREATE SEQUENCE bed_seq START 101;                -- bed turnover references BMC-BED-000101 ...

-- SLOT-C105 / slot c105 / C105 -> SLOT-C105
CREATE OR REPLACE FUNCTION norm_slot(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[A-Z][0-9]{3}$' THEN 'SLOT-' || x
              WHEN x ~ '^SLOT[A-Z][0-9]{3}$' THEN 'SLOT-' || substr(x, 5)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;

-- =====================================================================
-- FOLLOW-UP BOOKING (two-step): rules -> propose (PROPOSED / BLOCKED, 15 minutes) -> confirm (re-check) -> event + trigger
-- =====================================================================
CREATE OR REPLACE FUNCTION followup_eval(p_ward TEXT, p_patient TEXT, p_slot TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, patient_id VARCHAR, slot_id VARCHAR, summary TEXT) AS $$
  SELECT (fc.code = 'OK' AND cs.slot_id IS NOT NULL AND cs.specialty_code = fc.specialty_code
          AND cs.starts_at::date BETWEEN fc.win_from AND fc.win_to AND cs.status = 'OPEN' AND cs.starts_at > clock_timestamp()),
         CASE WHEN fc.code <> 'OK' THEN fc.code
              WHEN cs.slot_id IS NULL THEN 'SLOT_NOT_FOUND'
              WHEN cs.specialty_code <> fc.specialty_code THEN 'WRONG_SPECIALTY'
              WHEN cs.starts_at::date NOT BETWEEN fc.win_from AND fc.win_to THEN 'OUTSIDE_WINDOW'
              WHEN cs.status <> 'OPEN' OR cs.starts_at <= clock_timestamp() THEN 'SLOT_TAKEN'
              ELSE NULL END,
         CASE WHEN fc.code <> 'OK' THEN fc.reason_text
              WHEN cs.slot_id IS NULL THEN 'I could not find clinic slot ' || norm_slot(p_slot) || '. Nothing was booked.'
              WHEN cs.specialty_code <> fc.specialty_code THEN 'Slot ' || cs.slot_id || ' is a ' || sp.specialty_name
                   || ' slot, but the discharge order asks for a ' || fc.specialty_name || ' follow-up. Nothing was booked.'
              WHEN cs.starts_at::date NOT BETWEEN fc.win_from AND fc.win_to THEN 'Slot ' || cs.slot_id || ' on ' || d(cs.starts_at::date)
                   || ' is outside the follow-up window (' || d(fc.win_from) || ' to ' || d(fc.win_to) || '). Nothing was booked.'
              WHEN cs.status <> 'OPEN' OR cs.starts_at <= clock_timestamp() THEN 'Slot ' || cs.slot_id || ' is no longer available. Nothing was booked.'
              ELSE NULL END,
         fc.patient_id, cs.slot_id,
         CASE WHEN cs.slot_id IS NOT NULL AND fc.code = 'OK' THEN
           'Book a ' || fc.specialty_name || ' follow-up for ' || fc.pname || ' with ' || cs.clinician || ' on ' || wday(cs.starts_at)
           || ' ' || dt(cs.starts_at) || ' at ' || cs.location || ' (wheelchair accessible: ' || yn(cs.wheelchair_accessible)
           || ', hospital transport: ' || yn(cs.transport_available) || ').' END
    FROM followup_patient_check(p_ward, p_patient) fc
    LEFT JOIN clinic_slots cs ON cs.slot_id = norm_slot(p_slot)
    LEFT JOIN specialties sp ON sp.specialty_code = cs.specialty_code
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION followup_key(p_patient TEXT, p_slot TEXT) RETURNS TEXT AS $$
  SELECT norm_mrn(p_patient) || '|' || norm_slot(p_slot)
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION propose_followup_fn(p_token TEXT, p_patient TEXT, p_slot TEXT)
RETURNS TABLE (coordinator_id VARCHAR, action_type VARCHAR, target_key TEXT, patient_id VARCHAR, slot_id VARCHAR, outcome VARCHAR,
               reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT sc.staff_id, 'BOOK_FOLLOWUP'::varchar, followup_key(p_patient, p_slot), e.patient_id, e.slot_id,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary
    FROM session_coordinator(p_token) sc
    CROSS JOIN LATERAL followup_eval(sc.ward_id, p_patient, p_slot) e
   WHERE sc.staff_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.coordinator_id = sc.staff_id AND pa.action_type = 'BOOK_FOLLOWUP'
                        AND pa.target_key = followup_key(p_patient, p_slot) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM appointment_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_followup_result(p_token TEXT, p_patient TEXT, p_slot TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, reason_code VARCHAR, reason_text TEXT, summary TEXT, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing is booked yet. Reply yes within 15 minutes to book it.'
              ELSE pa.reason_text END,
         pa.summary, CASE WHEN pa.outcome = 'PROPOSED' THEN pa.expires_at END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.coordinator_id = sc.staff_id AND p.action_type = 'BOOK_FOLLOWUP'
                          AND p.target_key = followup_key(p_patient, p_slot)
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm: re-checks EVERY rule; returns the appointment_events row only when still bookable.
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, coordinator_id VARCHAR, patient_id VARCHAR, slot_id VARCHAR,
               summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  sc RECORD; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev appointment_events; e RECORD;
  v_id BIGINT; v_reference TEXT;
BEGIN
  SELECT * INTO sc FROM session_coordinator(p_token) s;
  IF sc.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.coordinator_id = sc.staff_id;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (coordinator_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (sc.staff_id, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal. Nothing was booked.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM appointment_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (coordinator_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (sc.staff_id, v_ref, 'ALREADY_DONE', 'This was already booked earlier (reference ' || ev.reference || '). Nothing new was booked.',
              ev.reference, ev.summary);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (coordinator_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (sc.staff_id, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (coordinator_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (sc.staff_id, v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was booked. I can propose it again.', pa.summary);
    RETURN;
  END IF;
  SELECT * INTO e FROM followup_eval(sc.ward_id, pa.patient_id, pa.slot_id) x;
  IF NOT e.ok THEN
    INSERT INTO confirm_attempts (coordinator_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (sc.staff_id, v_ref, 'BLOCKED', e.reason_code, e.reason_text, pa.summary);
    RETURN;
  END IF;
  v_id := nextval(pg_get_serial_sequence('appointment_events', 'event_id'));
  v_reference := 'BMC-APT-' || lpad(v_id::text, 6, '0');
  INSERT INTO confirm_attempts (coordinator_id, proposal_ref, outcome, reason_text, reference, summary)
    VALUES (sc.staff_id, v_ref, 'EXECUTED', 'Booked.', v_reference, e.summary);
  RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, sc.staff_id::varchar, pa.patient_id, pa.slot_id, e.summary;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         ca.reference,
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that proposal. Nothing was booked.'
              ELSE ca.reason_text END,
         ca.summary
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT a.* FROM confirm_attempts a
                        WHERE a.coordinator_id = sc.staff_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) ca ON TRUE
$$ LANGUAGE sql STABLE;

-- The booking itself - atomic with the event row. Never an UPDATE from a tool.
CREATE OR REPLACE FUNCTION apply_appointment_event() RETURNS TRIGGER AS $$
DECLARE cs clinic_slots;
BEGIN
  SELECT * INTO cs FROM clinic_slots WHERE slot_id = NEW.slot_id;
  INSERT INTO appointments (appointment_id, patient_id, appt_type, specialty_code, slot_id, starts_at, location, clinician, source)
    VALUES (NEW.reference, NEW.patient_id, 'Follow-up visit', cs.specialty_code, cs.slot_id, cs.starts_at, cs.location, cs.clinician, 'CHAT');
  UPDATE clinic_slots SET status = 'BOOKED' WHERE slot_id = NEW.slot_id;
  PERFORM audit('FOLLOWUP_BOOKED', NEW.coordinator_id, NEW.reference, NEW.summary);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_appointment_event AFTER INSERT ON appointment_events FOR EACH ROW EXECUTE FUNCTION apply_appointment_event();

-- =====================================================================
-- DISCHARGE MEDICINE ORDERS - only medicines on the discharge list; high-alert -> pharmacist case (parked order)
-- =====================================================================
-- Does what someone typed ('warfarin', 'water pill', 'MED-105', 'aspirin 81 mg') name this catalogue medicine?
CREATE OR REPLACE FUNCTION med_matches(p_tok TEXT, p_code TEXT) RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM medication_catalog m WHERE m.medication_code = p_code AND length(p_tok) >= 3 AND (
           m.medication_code = norm_ref(p_tok)
        OR upper(m.generic_name) LIKE '%' || p_tok || '%'
        OR p_tok LIKE '%' || upper(m.generic_name) || '%'
        OR (length(p_tok) >= 4 AND upper(coalesce(m.also_known_as, '')) LIKE '%' || p_tok || '%')
        OR EXISTS (SELECT 1 FROM regexp_split_to_table(upper(coalesce(m.also_known_as, '')), '\s*,\s*') aka
                    WHERE length(aka) >= 4 AND p_tok LIKE '%' || aka || '%')))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION med_order_rows(p_token TEXT, p_patient TEXT, p_med TEXT, p_brief TEXT)
RETURNS TABLE (order_id VARCHAR, dm_id INTEGER, patient_id VARCHAR, medication_code VARCHAR, days_supply INTEGER,
               pickup_location VARCHAR, ready_by TIMESTAMP, ordered_by VARCHAR, case_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE
  sc RECORD; v_pid TEXT; x discharges; v_batch BIGINT := txid_current(); v_ref TEXT := norm_mrn(p_patient);
  v_med TEXT := upper(trim(coalesce(p_med, ''))); v_all BOOLEAN; v_dms INTEGER[] := '{}'; tok TEXT; v_hit INTEGER[];
  r RECORD; v_case RECORD; v_no BIGINT; v_case_id TEXT; v_order TEXT; v_ready TIMESTAMP; v_label TEXT;
BEGIN
  SELECT * INTO sc FROM session_coordinator(p_token) s;
  IF sc.staff_id IS NULL THEN RETURN; END IF;
  v_pid := ward_patient(sc.ward_id, p_patient);
  IF v_pid IS NULL THEN
    INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, outcome, reason_code, reason_text)
      VALUES (v_batch, sc.staff_id, v_ref, left(p_med, 60), 'BLOCKED', 'NOT_FOUND', 'I could not find that patient on your ward. Nothing was ordered.');
    RETURN;
  END IF;
  SELECT * INTO x FROM discharges d0 WHERE d0.patient_id = v_pid;
  IF x.status = 'PENDING' THEN
    INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, outcome, reason_code, reason_text)
      VALUES (v_batch, sc.staff_id, v_ref, left(p_med, 60), 'BLOCKED', 'DISCHARGE_NOT_ORDERED',
              patient_name(v_pid) || ' has no signed discharge order yet, so discharge medicines cannot be ordered. The attending decides the discharge.');
    RETURN;
  END IF;
  v_all := v_med = '' OR v_med ~ '^(ALL|EVERYTHING|ALL OF THEM)\M';
  IF v_all THEN
    SELECT coalesce(array_agg(dm.dm_id ORDER BY dm.dm_id), '{}') INTO v_dms FROM discharge_medications dm WHERE dm.discharge_id = x.discharge_id;
  ELSE
    FOREACH tok IN ARRAY regexp_split_to_array(v_med, '\s*(,|;|&|\+|\mAND\M)\s*') LOOP
      tok := trim(tok);
      CONTINUE WHEN tok = '';
      SELECT coalesce(array_agg(dm.dm_id), '{}') INTO v_hit FROM discharge_medications dm
       WHERE dm.discharge_id = x.discharge_id AND med_matches(tok, dm.medication_code);
      IF cardinality(v_hit) = 0 THEN
        SELECT med_label(m.medication_code) INTO v_label FROM medication_catalog m WHERE med_matches(tok, m.medication_code) LIMIT 1;
        INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, outcome, reason_code, reason_text)
          VALUES (v_batch, sc.staff_id, v_ref, left(coalesce(v_label, tok), 60), 'BLOCKED', 'NOT_ON_DISCHARGE_LIST',
                  coalesce(v_label, initcap(lower(tok))) || ' is not on ' || patient_name(v_pid)
                  || '''s discharge medicine list, so it was not ordered. Adding a medicine is a prescription change for the attending.');
      ELSE
        v_dms := v_dms || (SELECT coalesce(array_agg(h), '{}') FROM unnest(v_hit) h WHERE NOT h = ANY (v_dms));
      END IF;
    END LOOP;
  END IF;
  FOR r IN SELECT dm.*, m.high_alert, m.prep_minutes FROM discharge_medications dm JOIN medication_catalog m USING (medication_code)
            WHERE dm.dm_id = ANY (v_dms) ORDER BY dm.dm_id LOOP
    IF EXISTS (SELECT 1 FROM pharmacy_orders po WHERE po.dm_id = r.dm_id) THEN
      INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, medication_code, days_supply, outcome,
                                      reason_code, reason_text, order_id, pickup_location, ready_by)
        SELECT v_batch, sc.staff_id, v_ref, med_label(r.medication_code), r.medication_code, po.days_supply, 'ALREADY_ORDERED', 'ALREADY_ORDERED',
               'Already ordered earlier (' || po.order_id || '). Nothing new was ordered.', po.order_id, po.pickup_location, po.ready_by
          FROM pharmacy_orders po WHERE po.dm_id = r.dm_id;
    ELSIF r.high_alert THEN
      SELECT c.case_id, c.status INTO v_case FROM service_cases c WHERE c.parked_action = 'MED_ORDER:' || r.dm_id ORDER BY c.created_at DESC LIMIT 1;
      IF v_case.case_id IS NULL THEN
        v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
        v_case_id := 'BMC-CASE-' || lpad(v_no::text, 6, '0');
        INSERT INTO service_cases (case_no, case_id, patient_id, ward_id, opened_by, request_type, summary, reference_id,
                                   requested_amount, parked_action, agent_brief, sla_due_at)
          VALUES (v_no, v_case_id, v_pid, sc.ward_id, sc.staff_id, 'high_alert_med',
                  'High-alert medicine on the discharge list: ' || med_label(r.medication_code) || ', ' || r.instructions || ', '
                  || days_txt(r.days_supply) || ' (indication: ' || r.indication || '). Dispensing needs a pharmacist''s review.',
                  r.medication_code, r.days_supply, 'MED_ORDER:' || r.dm_id, left(nullif(trim(p_brief), ''), 4000),
                  clock_timestamp()::timestamp + INTERVAL '2 hours');
        PERFORM audit('CASE_OPENED', sc.staff_id, v_case_id, 'high_alert_med for ' || r.medication_code);
        INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, medication_code, days_supply, outcome,
                                        reason_code, reason_text, case_id)
          VALUES (v_batch, sc.staff_id, v_ref, med_label(r.medication_code), r.medication_code, r.days_supply, 'PHARMACIST_REVIEW', 'HIGH_ALERT',
                  med_label(r.medication_code) || ' is a high-alert medicine, so it was not dispensed yet. A pharmacist reviews it first (case '
                  || v_case_id || ', Pharmacy team, reply within 2 hours).', v_case_id);
      ELSE
        INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, medication_code, days_supply, outcome,
                                        reason_code, reason_text, case_id)
          VALUES (v_batch, sc.staff_id, v_ref, med_label(r.medication_code), r.medication_code, r.days_supply, 'PHARMACIST_REVIEW', 'HIGH_ALERT',
                  med_label(r.medication_code) || ' is already with the pharmacist (case ' || v_case.case_id || ', '
                  || lower(v_case.status) || '). Nothing new was ordered.', v_case.case_id);
      END IF;
    ELSE
      v_order := 'RX-' || lpad(nextval('rx_seq')::text, 6, '0');
      v_ready := date_trunc('minute', clock_timestamp()::timestamp) + r.prep_minutes * INTERVAL '1 minute';
      INSERT INTO med_order_attempts (batch_id, coordinator_id, patient_ref, medication_ref, medication_code, days_supply, outcome,
                                      reason_text, order_id, pickup_location, ready_by)
        VALUES (v_batch, sc.staff_id, v_ref, med_label(r.medication_code), r.medication_code, r.days_supply, 'ORDERED',
                'Ordered as prescribed.', v_order, pickup_for(x.status), v_ready);
      RETURN QUERY SELECT v_order::varchar, r.dm_id, v_pid::varchar, r.medication_code, r.days_supply, pickup_for(x.status)::varchar,
                          v_ready, sc.staff_id::varchar, NULL::varchar;
    END IF;
  END LOOP;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION order_meds_result(p_token TEXT, p_patient TEXT)
RETURNS TABLE (outcome TEXT, medication VARCHAR, days_supply INTEGER, order_id VARCHAR, pickup_location VARCHAR, ready_by TEXT,
               case_id VARCHAR, team TEXT, reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(a.outcome, 'NOT_FOUND') END,
         a.medication_ref, a.days_supply, a.order_id, a.pickup_location, dt(a.ready_by), a.case_id,
         CASE WHEN a.case_id IS NOT NULL THEN 'Pharmacy' END,
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN a.attempt_id IS NULL THEN 'NOT_FOUND' ELSE a.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN a.attempt_id IS NULL THEN 'I could not find that patient on your ward. Nothing was ordered.'
              ELSE a.reason_text END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT max(m.batch_id) AS b FROM med_order_attempts m
                        WHERE m.coordinator_id = sc.staff_id AND m.patient_ref = norm_mrn(p_patient)) lb ON TRUE
    LEFT JOIN med_order_attempts a ON a.batch_id = lb.b AND a.coordinator_id = sc.staff_id AND a.patient_ref = norm_mrn(p_patient)
   ORDER BY a.attempt_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_pharmacy_order() RETURNS TRIGGER AS $$
BEGIN
  PERFORM audit('ORDER_PLACED', NEW.ordered_by, NEW.order_id,
                med_label(NEW.medication_code) || ', ' || days_txt(NEW.days_supply) || coalesce(' (released by case ' || NEW.case_id || ')', ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_pharmacy_order AFTER INSERT ON pharmacy_orders FOR EACH ROW EXECUTE FUNCTION apply_pharmacy_order();

-- =====================================================================
-- BED TURNOVER - only a bed on the ward whose patient has actually left (or a charge nurse's approved override)
-- =====================================================================
-- Guarded row shared by the coordinator tool and the decision trigger.
CREATE OR REPLACE FUNCTION bed_turnover_exec_row(p_bed TEXT, p_override BOOLEAN, p_actor TEXT, p_case TEXT)
RETURNS TABLE (reference VARCHAR, bed_id VARCHAR, ward_id VARCHAR, patient_id VARCHAR, override BOOLEAN, requested_by VARCHAR,
               case_id VARCHAR, estimated_ready TIMESTAMP) AS $$
  SELECT ('BMC-BED-' || lpad(nextval('bed_seq')::text, 6, '0'))::varchar, b.bed_id, b.ward_id, b.patient_id, p_override,
         p_actor::varchar, p_case::varchar,
         date_trunc('minute', clock_timestamp()::timestamp) + (CASE WHEN x.isolation THEN 90 ELSE 45 END) * INTERVAL '1 minute'
    FROM beds b JOIN discharges x ON x.patient_id = b.patient_id
   WHERE b.bed_id = norm_bed(p_bed) AND b.status = 'OCCUPIED' AND (x.status = 'DISCHARGED' OR p_override)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION bed_turnover_row(p_token TEXT, p_bed TEXT)
RETURNS TABLE (reference VARCHAR, bed_id VARCHAR, ward_id VARCHAR, patient_id VARCHAR, override BOOLEAN, requested_by VARCHAR,
               case_id VARCHAR, estimated_ready TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE sc RECORD; v_bed TEXT := norm_bed(p_bed); b beds; x discharges; r RECORD; v_code TEXT; v_text TEXT;
BEGIN
  SELECT * INTO sc FROM session_coordinator(p_token) s;
  IF sc.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO b FROM beds b0 WHERE b0.bed_id = v_bed AND b0.ward_id = sc.ward_id;
  IF NOT FOUND THEN
    v_code := 'NOT_FOUND'; v_text := 'I could not find bed ' || v_bed || ' on your ward. Nothing was requested.';
  ELSIF b.status IN ('CLEANING_REQUESTED','CLEANING_IN_PROGRESS') THEN
    v_code := 'ALREADY_REQUESTED'; v_text := 'Bed ' || v_bed || ' is already with housekeeping (' || lower(replace(b.status, '_', ' '))
                                              || coalesce(', ready about ' || dt(b.estimated_ready), '') || '). Nothing new was requested.';
  ELSIF b.patient_id IS NULL OR b.status = 'AVAILABLE' THEN
    v_code := 'BED_EMPTY'; v_text := 'Bed ' || v_bed || ' is already clean and available. Nothing was requested.';
  ELSE
    SELECT * INTO x FROM discharges x0 WHERE x0.patient_id = b.patient_id;
    IF x.status <> 'DISCHARGED' THEN
      v_code := 'PATIENT_NOT_DISCHARGED';
      v_text := 'The patient in bed ' || v_bed || ' has not left yet (discharge ' || lower(x.status)
                || coalesce(' for ' || d(x.planned_date), '') || '), so the bed cannot be turned over. An early turnover needs the charge nurse.';
    END IF;
  END IF;
  IF v_code IS NOT NULL THEN
    INSERT INTO bed_attempts (coordinator_id, bed_ref, outcome, reason_code, reason_text) VALUES (sc.staff_id, v_bed, 'BLOCKED', v_code, v_text);
    RETURN;
  END IF;
  SELECT * INTO r FROM bed_turnover_exec_row(v_bed, FALSE, sc.staff_id, NULL) t;
  INSERT INTO bed_attempts (coordinator_id, bed_ref, outcome, reason_text, reference, estimated_ready)
    VALUES (sc.staff_id, v_bed, 'REQUESTED',
            'Housekeeping has the bed (' || CASE WHEN x.isolation THEN 'isolation terminal clean, 90 minutes' ELSE 'standard clean, 45 minutes' END || ').',
            r.reference, r.estimated_ready);
  RETURN QUERY SELECT r.reference, r.bed_id, r.ward_id, r.patient_id, r.override, r.requested_by, r.case_id, r.estimated_ready;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION bed_turnover_result(p_token TEXT, p_bed TEXT)
RETURNS TABLE (outcome TEXT, bed_id TEXT, reference VARCHAR, estimated_ready TEXT, reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ba.outcome, 'NOT_FOUND') END,
         norm_bed(p_bed), ba.reference, dt(ba.estimated_ready),
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN ba.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ba.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN ba.attempt_id IS NULL THEN 'I could not find that bed on your ward. Nothing was requested.'
              ELSE ba.reason_text END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT a.* FROM bed_attempts a WHERE a.coordinator_id = sc.staff_id AND a.bed_ref = norm_bed(p_bed)
                        ORDER BY a.attempt_id DESC LIMIT 1) ba ON TRUE
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_bed_event() RETURNS TRIGGER AS $$
BEGIN
  UPDATE beds SET status = 'CLEANING_REQUESTED', patient_id = NULL, updated_at = clock_timestamp(), estimated_ready = NEW.estimated_ready
   WHERE bed_id = NEW.bed_id;
  PERFORM audit('BED_TURNOVER', NEW.requested_by, NEW.reference,
                'bed ' || NEW.bed_id || CASE WHEN NEW.override THEN ' (charge-nurse override, case ' || NEW.case_id || ')' ELSE '' END);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_bed_event AFTER INSERT ON bed_events FOR EACH ROW EXECUTE FUNCTION apply_bed_event();

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_patient TEXT, p_summary TEXT, p_ref TEXT, p_brief TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, patient_id VARCHAR, ward_id VARCHAR, opened_by VARCHAR, request_type VARCHAR,
               summary TEXT, reference_id VARCHAR, requested_amount NUMERIC, parked_action VARCHAR, agent_brief TEXT,
               sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE sc RECORD; v_type TEXT := norm_request_type(p_type); v_pref TEXT := norm_mrn(p_patient); r case_routing; v_pid TEXT;
        x discharges; v_bed TEXT; b beds; v_parked TEXT; v_refid TEXT; v_existing TEXT; v_no BIGINT; v_case TEXT;
BEGIN
  SELECT * INTO sc FROM session_coordinator(p_token) s;
  IF sc.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM case_routing cr WHERE cr.request_type = v_type AND cr.coordinator_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (coordinator_id, request_type, patient_ref, outcome, reason_code) VALUES (sc.staff_id, v_type, v_pref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  v_pid := ward_patient(sc.ward_id, p_patient);
  IF v_pid IS NULL THEN
    INSERT INTO case_requests (coordinator_id, request_type, patient_ref, outcome, reason_code) VALUES (sc.staff_id, v_type, v_pref, 'BLOCKED', 'NOT_FOUND');
    RETURN;
  END IF;
  SELECT * INTO x FROM discharges x0 WHERE x0.patient_id = v_pid;
  IF v_type = 'bed_override' THEN
    v_bed := coalesce(nullif(norm_bed(p_ref), ''), x.bed_id);
    SELECT * INTO b FROM beds b0 WHERE b0.bed_id = v_bed AND b0.ward_id = sc.ward_id;
    IF NOT FOUND OR b.patient_id IS DISTINCT FROM v_pid OR b.status <> 'OCCUPIED' OR x.status = 'DISCHARGED' THEN
      INSERT INTO case_requests (coordinator_id, request_type, patient_ref, outcome, reason_code) VALUES (sc.staff_id, v_type, v_pref, 'BLOCKED', 'BED_NOT_ELIGIBLE');
      RETURN;
    END IF;
    v_parked := 'BED_TURNOVER:' || v_bed; v_refid := v_bed;
  END IF;
  SELECT c.case_id INTO v_existing FROM service_cases c
   WHERE c.patient_id = v_pid AND c.request_type = v_type AND c.status = 'OPEN' ORDER BY c.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (coordinator_id, request_type, patient_ref, outcome, case_id) VALUES (sc.staff_id, v_type, v_pref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'BMC-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (coordinator_id, request_type, patient_ref, outcome, case_id) VALUES (sc.staff_id, v_type, v_pref, 'OPENED', v_case);
  PERFORM audit('CASE_OPENED', sc.staff_id, v_case, v_type || ' for ' || v_pid);
  RETURN QUERY SELECT v_no, v_case::varchar, v_pid::varchar, sc.ward_id, sc.staff_id, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_refid::varchar, NULL::numeric,
                      v_parked::varchar, left(nullif(trim(p_brief), ''), 4000),
                      clock_timestamp()::timestamp + r.sla_hours * INTERVAL '1 hour';
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT, p_patient TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due TEXT, reason_code VARCHAR,
               reason_text TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.team, rt.sla_text, dt(s.sla_due_at),
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN cr.outcome = 'OPENED' THEN 'The case is open. A person on the ' || rt.team || ' team will review it and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'There is already an open ' || rt.label || ' case for this patient, so no new case was opened. The ' || rt.team || ' team is on it.'
              WHEN cr.reason_code = 'NOT_FOUND' THEN 'I could not find that patient on your ward, so no case was opened.'
              WHEN cr.reason_code = 'BED_NOT_ELIGIBLE' THEN 'An early bed turnover can only be requested for the bed of a patient on your ward who has not left yet. If the patient has left, request a normal turnover instead. No case was opened.'
              ELSE 'That is not a request I can open a case for here. A person can help with medication reconciliation reviews, early bed turnover, clinical or dosage questions, prescription changes and discharge decisions.' END
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.coordinator_id = sc.staff_id AND q.request_type = norm_request_type(p_type)
                          AND q.patient_ref = norm_mrn(p_patient)
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
CREATE OR REPLACE FUNCTION discharge_med_list(p_discharge INTEGER, p_except INTEGER) RETURNS TEXT AS $$
  SELECT coalesce(string_agg(med_label(dm.medication_code) || ' (' || dm.instructions || ', ' || days_txt(dm.days_supply) || ')', '; ' ORDER BY dm.dm_id), 'none')
    FROM discharge_medications dm WHERE dm.discharge_id = p_discharge AND dm.dm_id IS DISTINCT FROM p_except
$$ LANGUAGE sql STABLE;

-- The most a reviewer may approve on a case (NULL = the case carries no amount): never more than prescribed.
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN split_part(s.parked_action, ':', 1) = 'MED_ORDER'
                THEN (SELECT dm.days_supply FROM discharge_medications dm WHERE dm.dm_id::text = split_part(s.parked_action, ':', 2))
              ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no MRN, full last name, date of birth or contact details).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE
    WHEN split_part(s.parked_action, ':', 1) = 'MED_ORDER' THEN
      med_label(dm.medication_code) || ' (high-alert) - prescribed: ' || dm.instructions || ', ' || days_txt(dm.days_supply)
      || '; indication: ' || dm.indication || '; patient age ' || age_years(p.date_of_birth)
      || '; other discharge medicines: ' || discharge_med_list(x.discharge_id, dm.dm_id)
      || '; follow-up: ' || coalesce((SELECT sp.specialty_name || ' booked ' || dt(a.starts_at) FROM appointments a
                                         JOIN specialties sp ON sp.specialty_code = a.specialty_code
                                        WHERE a.patient_id = x.patient_id AND a.appt_type = 'Follow-up visit' AND a.status = 'SCHEDULED'
                                        ORDER BY a.starts_at LIMIT 1),
                                      CASE WHEN x.followup_required THEN 'required, not booked yet' ELSE 'not required' END)
      || '; discharge ' || lower(x.status) || coalesce(' (left ' || dt(x.discharged_at) || ')', '')
    WHEN split_part(s.parked_action, ':', 1) = 'BED_TURNOVER' THEN
      'Bed ' || b.bed_id || ' on Ward ' || b.ward_id || ' - ' || lower(b.status) || coalesce(', occupied by ' || patient_display(b.patient_id), '')
      || '; discharge ' || lower(x.status) || coalesce(' for ' || d(x.planned_date), '') || '; isolation: ' || yn(x.isolation)
      || CASE WHEN x.isolation THEN ' (terminal clean, 90 minutes)' ELSE ' (standard clean, 45 minutes)' END
      || '. Approving sends the bed to housekeeping now.'
    ELSE
      'Ward ' || x.ward_id || ' bed ' || x.bed_id || '; service ' || x.service || '; attending ' || x.attending || '; discharge '
      || lower(x.status) || coalesce(' for ' || d(x.planned_date), '') || '; patient age ' || age_years(p.date_of_birth)
      || '; discharge medicines: ' || discharge_med_list(x.discharge_id, NULL) || '.'
    END
    FROM service_cases s
    JOIN discharges x ON x.patient_id = s.patient_id
    JOIN patients p ON p.patient_id = s.patient_id
    LEFT JOIN discharge_medications dm ON split_part(s.parked_action, ':', 1) = 'MED_ORDER' AND dm.dm_id::text = split_part(s.parked_action, ':', 2)
    LEFT JOIN beds b ON split_part(s.parked_action, ':', 1) = 'BED_TURNOVER' AND b.bed_id = split_part(s.parked_action, ':', 2)
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, patient TEXT, ward VARCHAR, opened_at TEXT, age_hours INTEGER,
               reply_due TEXT, sla_status TEXT, requested_days NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.patient, q.ward_id, q.opened_at, q.age_hours, q.reply_due, q.sla_status, q.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, r.label, patient_display(s.patient_id) AS patient, s.ward_id, dt(s.created_at) AS opened_at,
             (extract(epoch FROM clock_timestamp()::timestamp - s.created_at) / 3600)::int AS age_hours, dt(s.sla_due_at) AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at < clock_timestamp() + INTERVAL '1 hour' THEN 'DUE_SOON'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.sla_due_at
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND r.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, patient TEXT, ward_bed TEXT, opened_at TEXT,
               reply_due TEXT, coordinator_statement TEXT, agent_brief TEXT, requested_days NUMERIC, max_approvable_days NUMERIC,
               your_approval_limit_days NUMERIC, facts TEXT, options TEXT, decided_at TEXT, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.label, s.status, patient_display(s.patient_id),
         CASE WHEN s.case_id IS NOT NULL THEN 'Ward ' || x.ward_id || ', bed ' || x.bed_id END,
         dt(s.created_at), dt(s.sla_due_at), s.summary,
         CASE WHEN s.agent_brief IS NOT NULL THEN 'AI-prepared, not verified: ' || s.agent_brief END,
         s.requested_amount, case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.requested_amount IS NOT NULL THEN 'APPROVE (a supply of 1 to ' || days_txt(case_eligible_max(s.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN '; above your ' || days_txt(sr.approval_limit) || ' limit it needs a senior pharmacist' ELSE '' END
                   || ') or REJECT, with an internal note and a message for the coordinator.'
              WHEN split_part(s.parked_action, ':', 1) = 'BED_TURNOVER' THEN 'APPROVE (sends the bed to housekeeping now) or REJECT, with an internal note and a message for the coordinator.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the coordinator.' END,
         dt(s.decided_at),
         (SELECT rd.decision || coalesce(' ' || days_txt(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT cr.request_type FROM case_routing cr WHERE cr.team = sr.team)   -- another team's case is invisible
    LEFT JOIN case_routing r ON r.request_type = s.request_type
    LEFT JOIN discharges x ON x.patient_id = s.patient_id
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; r case_routing; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_amt_txt TEXT := norm_days(p_amount); v_msg TEXT;
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
  IF v_dec = 'APPROVE' AND s.requested_amount IS NOT NULL THEN
    v_max := case_eligible_max(s.case_id);
    v_amt := CASE WHEN v_amt_txt = '' THEN v_max WHEN v_amt_txt ~ '^-?[0-9]+$' THEN v_amt_txt::numeric END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The approved supply must be a whole number of days from 1 to ' || days_txt(v_max)
                || ' (the prescribed supply) for this case.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', 'A ' || days_txt(v_amt) || ' supply is above your approval limit of '
                || days_txt(rv.approval_limit) || '. The case stays open and needs a senior pharmacist.');
      RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'The ' || r.label || ' was approved' || coalesce(' for a ' || days_txt(v_amt) || ' supply', '') || '.'
                  ELSE 'After review, the ' || r.label || ' was not approved. The ' || r.team || ' team will follow up with the care team.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_days NUMERIC, reason_code VARCHAR, reason_text TEXT,
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
                coalesce((SELECT 'Dispensed: order ' || po.order_id || ' for ' || med_label(po.medication_code) || ', ' || days_txt(po.days_supply)
                                 || ', ready by ' || dt(po.ready_by) || ' (' || po.pickup_location || ').'
                            FROM pharmacy_orders po WHERE po.case_id = s.case_id),
                         (SELECT 'Bed ' || be.bed_id || ' sent to housekeeping (' || be.reference || '), ready about ' || dt(be.estimated_ready) || '.'
                            FROM bed_events be WHERE be.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it in the patient record.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded row the decision trigger uses to dispense a parked high-alert medicine (same checks every time).
CREATE OR REPLACE FUNCTION pharmacy_order_row(p_dm INTEGER, p_days NUMERIC, p_actor TEXT, p_case TEXT)
RETURNS TABLE (order_id VARCHAR, dm_id INTEGER, patient_id VARCHAR, medication_code VARCHAR, days_supply INTEGER,
               pickup_location VARCHAR, ready_by TIMESTAMP, ordered_by VARCHAR, case_id VARCHAR) AS $$
  SELECT ('RX-' || lpad(nextval('rx_seq')::text, 6, '0'))::varchar, dm.dm_id, x.patient_id, dm.medication_code, p_days::int,
         pickup_for(x.status)::varchar, date_trunc('minute', clock_timestamp()::timestamp) + m.prep_minutes * INTERVAL '1 minute',
         p_actor::varchar, p_case::varchar
    FROM discharge_medications dm
    JOIN discharges x ON x.discharge_id = dm.discharge_id
    JOIN medication_catalog m ON m.medication_code = dm.medication_code
   WHERE dm.dm_id = p_dm AND x.status <> 'PENDING' AND p_days > 0 AND p_days <= dm.days_supply AND p_days = trunc(p_days)
     AND NOT EXISTS (SELECT 1 FROM pharmacy_orders po WHERE po.dm_id = dm.dm_id)
$$ LANGUAGE sql VOLATILE;

-- The decision event: case status + coordinator message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF v_kind = 'MED_ORDER' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO pharmacy_orders (order_id, dm_id, patient_id, medication_code, days_supply, pickup_location, ready_by, ordered_by, case_id)
      SELECT * FROM pharmacy_order_row(v_ref::int, NEW.approved_amount, NEW.reviewer_id, NEW.case_id);
    IF FOUND THEN v_done := 'dispensed ' || s.reference_id || ' for ' || days_txt(NEW.approved_amount); END IF;
  ELSIF v_kind = 'BED_TURNOVER' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO bed_events (reference, bed_id, ward_id, patient_id, override, requested_by, case_id, estimated_ready)
      SELECT * FROM bed_turnover_exec_row(v_ref, TRUE, NEW.reviewer_id, NEW.case_id);
    IF FOUND THEN v_done := 'bed ' || v_ref || ' sent to housekeeping (override)'; END IF;
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id, NEW.decision || coalesce(' ' || days_txt(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- =====================================================================
-- EMAIL - the patient's plan, only for a patient on the coordinator's ward with an executed action.
-- SQL builds the text from what was actually arranged; it goes to the EMAIL_TO demo inbox (the patient's
-- real email never leaves the database) and carries no MRN or diagnosis.
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_patient TEXT)
RETURNS TABLE (code TEXT, coordinator_id VARCHAR, patient_id VARCHAR, first_name VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN wp.pid IS NULL THEN 'NOT_FOUND'
              WHEN NOT (EXISTS (SELECT 1 FROM appointments a WHERE a.patient_id = wp.pid AND a.source = 'CHAT')
                     OR EXISTS (SELECT 1 FROM pharmacy_orders po WHERE po.patient_id = wp.pid)
                     OR EXISTS (SELECT 1 FROM review_decisions rd JOIN service_cases c USING (case_id) WHERE c.patient_id = wp.pid))
                THEN 'NOTHING_TO_SEND'
              ELSE 'SEND_OK' END,
         sc.staff_id, wp.pid::varchar, p.first_name,
         'Bellmont Regional Medical Center - your discharge plan',
         'Dear ' || p.first_name || ',' || chr(10) || chr(10)
         || 'Here is the plan your care team arranged for after you leave Bellmont Regional Medical Center.' || chr(10) || chr(10)
         || 'Your appointments:' || chr(10)
         || coalesce((SELECT string_agg('- ' || a.appt_type || coalesce(' (' || sp.specialty_name || ')', '') || ' on ' || wday(a.starts_at) || ' '
                                        || dt(a.starts_at) || ' at ' || a.location || coalesce(' with ' || a.clinician, ''), chr(10) ORDER BY a.starts_at)
                        FROM appointments a LEFT JOIN specialties sp ON sp.specialty_code = a.specialty_code
                       WHERE a.patient_id = wp.pid AND a.status = 'SCHEDULED' AND a.starts_at > clock_timestamp()), '- None scheduled yet.')
         || chr(10) || chr(10) || 'Your medicines:' || chr(10)
         || coalesce((SELECT string_agg('- ' || med_label(dm.medication_code) || ': ' || dm.instructions || ' (' || days_txt(coalesce(po.days_supply, dm.days_supply)) || ')'
                                        || CASE WHEN po.order_id IS NOT NULL THEN ' - ready by ' || dt(po.ready_by) || ', ' || po.pickup_location
                                                WHEN hc.status = 'OPEN' THEN ' - our pharmacist is reviewing this medicine; we will tell you when it is ready'
                                                WHEN hc.status = 'REJECTED' THEN ' - your care team will contact you about this medicine'
                                                ELSE ' - not ordered yet' END, chr(10) ORDER BY dm.dm_id)
                        FROM discharges x JOIN discharge_medications dm ON dm.discharge_id = x.discharge_id
                        LEFT JOIN pharmacy_orders po ON po.dm_id = dm.dm_id
                        LEFT JOIN LATERAL (SELECT c.status FROM service_cases c WHERE c.parked_action = 'MED_ORDER:' || dm.dm_id
                                            ORDER BY c.created_at DESC LIMIT 1) hc ON TRUE
                       WHERE x.patient_id = wp.pid), '- No discharge medicines.')
         || chr(10) || chr(10)
         || 'Take your medicines exactly as prescribed. This message lists what your care team arranged; it is not medical advice. '
         || 'Questions about your medicines: Bellmont Pharmacy, (555) 010-4400. In an emergency, call 911.' || chr(10) || chr(10)
         || 'Bellmont Discharge Assistant (an AI assistant), on behalf of your care team'
    FROM (SELECT * FROM session_coordinator(p_token)) sc
    LEFT JOIN LATERAL (SELECT ward_patient(sc.ward_id, p_patient) AS pid) wp ON TRUE
    LEFT JOIN patients p ON p.patient_id = wp.pid
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_patient TEXT)
RETURNS TABLE (patient_id VARCHAR, coordinator_id VARCHAR, subject TEXT) AS $$
  SELECT e.patient_id, e.coordinator_id, e.subject FROM email_source(p_token, p_patient) e WHERE e.code = 'SEND_OK'
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_payload(p_token TEXT, p_patient TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, patient_first_name VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.code = 'SEND_OK' THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.code = 'SEND_OK' THEN NULL ELSE e.code END,
         CASE e.code WHEN 'SEND_OK' THEN 'The discharge plan email is on its way to the patient''s email on file.'
                     WHEN 'SESSION_INVALID' THEN 'Please verify again (staff ID and code).'
                     WHEN 'NOT_FOUND' THEN 'I could not find that patient on your ward, so no email was sent.'
                     ELSE 'Nothing has been arranged for this patient yet (no booked follow-up, medicine order or decided case), so no email was sent.' END,
         CASE WHEN e.code = 'SEND_OK' THEN e.first_name END,
         CASE WHEN e.code = 'SEND_OK' THEN e.subject ELSE 'Bellmont discharge plan - not sent' END,
         CASE WHEN e.code = 'SEND_OK' THEN e.body ELSE 'No email was sent.' END
    FROM email_source(p_token, p_patient) e
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

CREATE OR REPLACE FUNCTION ref_plain_language(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM plain_language_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['PRESCRIPTION_WORD','PICKUP','APPOINTMENT_TYPE','PENDING','READING_LEVEL','SAFETY_NET'],
                           g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_med_rec(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT m.section::text AS sec, m.term::text AS trm, m.meaning::text AS mng, m.entry_id AS ord
            FROM med_rec_reference m
          UNION ALL                                 -- the high-alert list has ONE source of truth: medication_catalog
          SELECT 'HIGH_ALERT', c.generic_name::text,
                 'high-alert medicine (ISMP-style list): a Bellmont pharmacist reviews it before it is dispensed', 1000
            FROM medication_catalog c WHERE c.high_alert) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['COMMON_NAME','DRUG_CLASS','FLAG_TYPE','ALWAYS_FLAG','HIGH_ALERT','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_slot_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM slot_ranking_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['PART_OF_DAY','ACCESS_CODE','TRANSPORT_CODE','CONSTRAINT','SEQUENCE','RANKING'],
                           g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
