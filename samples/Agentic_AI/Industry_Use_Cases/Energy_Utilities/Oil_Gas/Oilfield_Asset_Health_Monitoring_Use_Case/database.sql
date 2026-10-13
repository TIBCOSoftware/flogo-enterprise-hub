-- Mesa Ridge Energy - Oilfield Asset Health Monitoring (GOVERNED) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: predictive_maintenance_governed
-- Load:  createdb predictive_maintenance_governed  &&  psql -d predictive_maintenance_governed -f database.sql
--
-- =====================================================================
-- Fictional US upstream operator "Mesa Ridge Energy", assistant "Asset Health Assistant". Real basin and town names
-- (Permian Basin / Midland TX, Bakken / Williston ND, Eagle Ford / Karnes City TX); no real company, OEM or supplier.
-- US units: degrees F, psi, bbl/h, g RMS, kW.
-- The rules live HERE, not in any prompt:
--   * classify_asset()                           deterministic health: threshold table, worst sensor wins, confidence
--                                                lookup, days-to-failure band, failure-mode rule table (no LLM classifier)
--   * session_operator() / session_reviewer()    identity: every tool is scoped by a session token; operator and
--                                                reviewer tokens are not interchangeable (role checked)
--   * verify_*_fn()                              staff id + one-time code -> session; 5 failures / 15 min -> LOCKED
--   * region_* / asset_health() / ...            scoped reads - only the operator's site; another site -> NOT_FOUND
--   * field_note_row() + trg_field_note          validates the triage agent's output, reconciles it with the sensor
--                                                status and opens the HSE safety case itself on safety language
--   * work_order_eval()                          not in MAINTENANCE / SHUT_IN, no open work order, health >= WARNING,
--                                                failure mode valid for the asset type, estimate vs the operator limit
--   * propose_work_order_fn() / confirm_action_fn()  two-step: PROPOSED/BLOCKED with 15-minute expiry; confirm re-checks;
--                                                estimate above the limit -> a Production Engineering case
--   * alert_row()                                severity from SQL, health >= WARNING, one alert per asset per day
--   * open_case_row()                            human-owned requests routed by case_routing (team + SLA hours)
--   * decide_case_row() + trg_review_decision    the reviewer loop: role/team/authority/budget checks, then the parked
--                                                action (work order / shut-in / safety inspection / alert close) runs
--                                                through guarded rows
--   * email_log_row()                            asset summary email only for an asset in the region with an executed action
--   * ref_field_note_guide() / ref_failure_matching() / ref_handover_guide()
--                                                the A2A agents' ONLY database access: read-only reference tables
--                                                (safety-language signs + crew checks + the failure-mode codes read
--                                                from failure_modes, failure-matching criteria + glossary, shift-
--                                                handover guide) with no staff, crew-member, case, session, asset,
--                                                work-order or alert data; one optional lookup term, never an
--                                                identity. The safety keyword backstop and the HSE trigger stay here.
-- The AI agents get no identity at all (no staff names or ids, no tokens); they read reference tables only.
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

DROP TABLE IF EXISTS field_note_guide, failure_match_guide, handover_guide CASCADE;
DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, case_requests, service_cases, alert_events,
  asset_events, confirm_attempts, action_events, pending_actions, field_notes, alert_attempts, alerts, work_orders,
  sensor_readings, assets, failure_modes, failure_horizon, confidence_lookup, sensor_thresholds, verify_attempts, sessions,
  reviewers, operators, case_routing, sites CASCADE;
DROP SEQUENCE IF EXISTS wo_seq, alert_seq, note_seq, sht_seq;
CREATE SEQUENCE wo_seq START 1101;               -- work orders MRE-WO-1101 ... (reset in seed_data.sql)
CREATE SEQUENCE alert_seq START 101;             -- alerts ALR-000101 ...
CREATE SEQUENCE note_seq START 101;              -- field notes FN-000101 ...
CREATE SEQUENCE sht_seq START 101;               -- shut-in references MRE-SHT-000101 ...

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE sites (
  site_id        VARCHAR(4) PRIMARY KEY,          -- PB
  site_name      VARCHAR(60) NOT NULL,            -- Permian Basin Site Alpha
  basin          VARCHAR(30) NOT NULL,            -- Permian Basin
  town           VARCHAR(40) NOT NULL,            -- Midland, TX
  field_crew     VARCHAR(40) NOT NULL,            -- Permian Field Crew A (a crew, not a person)
  control_phone  VARCHAR(20) NOT NULL             -- control room desk (555-01xx)
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type       VARCHAR(30) PRIMARY KEY,
  label              VARCHAR(50) NOT NULL,        -- operator-facing name
  team               VARCHAR(40) NOT NULL,
  sla_hours          INTEGER NOT NULL,
  sla_text           VARCHAR(160) NOT NULL,
  operator_openable  BOOLEAN NOT NULL DEFAULT TRUE  -- supervisor_approval is opened only by confirm_action
);

-- ---------------------------------------------------------------------
-- Staff: control-room operators (scoped to a site/region) and reviewers (scoped to a team)
-- ---------------------------------------------------------------------
CREATE TABLE operators (
  staff_id       VARCHAR(10) PRIMARY KEY,         -- MRE-4101
  display_name   VARCHAR(60) NOT NULL,
  site_id        VARCHAR(4) NOT NULL REFERENCES sites,
  one_time_code  VARCHAR(6) NOT NULL,             -- HIDDEN: demo stand-in for the badge / authenticator code
  spend_limit    NUMERIC(12,2) NOT NULL DEFAULT 25000,   -- work-order estimate an operator may commit alone
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,        -- MRE-7101 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  title           VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,           -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,           -- HIDDEN
  approval_limit  NUMERIC(12,2),                  -- USD budget authority per decision; NULL = no limit / no spend cases
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(12) NOT NULL CHECK (role IN ('OPERATOR','REVIEWER')),
  operator_id    VARCHAR(10) REFERENCES operators,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'OPERATOR' AND operator_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND operator_id IS NULL))
);

-- Every verify call (throttle + readback).
CREATE TABLE verify_attempts (
  attempt_id   BIGSERIAL PRIMARY KEY,
  role         VARCHAR(12) NOT NULL,
  identifier   VARCHAR(40) NOT NULL,              -- normalised as typed
  outcome      VARCHAR(14) NOT NULL CHECK (outcome IN ('VERIFIED','VERIFY_FAILED','LOCKED')),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_verify_attempts ON verify_attempts (role, identifier, created_at);

-- ---------------------------------------------------------------------
-- The deterministic health model (rule tables). Threshold changes are human-owned (threshold_change case).
-- ---------------------------------------------------------------------
CREATE TABLE sensor_thresholds (
  sensor      VARCHAR(12) PRIMARY KEY CHECK (sensor IN ('vibration','temperature','pressure','flow')),
  label       VARCHAR(30) NOT NULL,
  unit        VARCHAR(10) NOT NULL,
  sort_order  INTEGER NOT NULL,
  warn_low    NUMERIC(8,2),                       -- WARNING when value < warn_low
  crit_low    NUMERIC(8,2),                       -- CRITICAL when value < crit_low
  warn_high   NUMERIC(8,2),                       -- WARNING when value > warn_high
  crit_high   NUMERIC(8,2),                       -- CRITICAL when value > crit_high
  mode_low    VARCHAR(20),                        -- failure mode when the sensor is out of range LOW
  mode_high   VARCHAR(20)                         -- failure mode when the sensor is out of range HIGH
);

CREATE TABLE confidence_lookup (
  anomalous_sensors INTEGER PRIMARY KEY,
  confidence        NUMERIC(3,2) NOT NULL
);

CREATE TABLE failure_horizon (
  health_status  VARCHAR(10) PRIMARY KEY CHECK (health_status IN ('NORMAL','WARNING','CRITICAL')),
  min_days       INTEGER NOT NULL,
  max_days       INTEGER,                         -- NULL = open-ended (90+)
  wo_priority    VARCHAR(10),                     -- work-order priority for this status (NULL = no work order)
  schedule_days  INTEGER                          -- scheduled date = today + schedule_days
);

CREATE TABLE failure_modes (
  asset_type          VARCHAR(16) NOT NULL CHECK (asset_type IN ('ROD_PUMP','ESP','COMPRESSOR','WELLHEAD_VALVE')),
  failure_mode        VARCHAR(20) NOT NULL CHECK (failure_mode IN ('bearing_wear','overheating','seal_leak',
                                                                  'pressure_anomaly','flow_blockage','electrical_fault')),
  label               VARCHAR(60) NOT NULL,
  recommended_action  TEXT NOT NULL,
  typical_parts       TEXT NOT NULL,
  est_cost_usd        NUMERIC(12,2) NOT NULL,       -- repair estimate used for the work order
  est_downtime_hours  INTEGER NOT NULL,
  PRIMARY KEY (asset_type, failure_mode)
);

-- ---------------------------------------------------------------------
-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO operator, reviewer, crew-member, case, session, asset, work-order, alert or
-- contact data, ever. Lists that already live in another table are NOT copied here: ref_field_note_guide() reads the
-- failure-mode codes from failure_modes and who decides a safety signal from case_routing (one source of truth).
-- classify_asset(), safety_keyword() and the HSE case trigger stay deterministic SQL; these tables only explain words.
-- ---------------------------------------------------------------------
CREATE TABLE field_note_guide (                  -- field_note_triage_agent: safety language, crew checks, shorthand
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('SAFETY_SIGN', 'NOT_SAFETY', 'CREW_CHECK', 'SHORTHAND', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- H2S / sour gas / bearing_wear / SPM
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE failure_match_guide (               -- similar_failure_agent: match levels + standard notes, glossary
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('MATCH_LEVEL', 'EXAMPLE', 'TERM', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- STRONG / fluid pound
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE handover_guide (                    -- shift_handover_agent: sections, status words, standard lines
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('SECTION', 'STATUS', 'STANDARD_LINE', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- 1 Safety / SCHEDULED / closing line
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- Assets, readings, work orders, alerts, field notes
-- ---------------------------------------------------------------------
CREATE TABLE assets (
  asset_id      VARCHAR(16) PRIMARY KEY,          -- PUMP-PB-W47 (type-site-well/station; always matches site_id)
  asset_type    VARCHAR(16) NOT NULL CHECK (asset_type IN ('ROD_PUMP','ESP','COMPRESSOR','WELLHEAD_VALVE')),
  site_id       VARCHAR(4) NOT NULL REFERENCES sites,
  description   VARCHAR(80) NOT NULL,
  install_date  DATE NOT NULL,
  status        VARCHAR(12) NOT NULL DEFAULT 'OPERATIONAL' CHECK (status IN ('OPERATIONAL','MAINTENANCE','SHUT_IN')),
  CHECK (split_part(asset_id, '-', 2) = site_id)
);

CREATE TABLE sensor_readings (
  reading_id     BIGSERIAL PRIMARY KEY,
  asset_id       VARCHAR(16) NOT NULL REFERENCES assets,
  reading_at     TIMESTAMP NOT NULL,
  vibration_g    NUMERIC(5,2) NOT NULL,           -- g RMS
  temperature_f  NUMERIC(6,1) NOT NULL,           -- degrees F
  pressure_psi   NUMERIC(7,1) NOT NULL,
  flow_bbl_h     NUMERIC(6,1) NOT NULL,
  power_kw       NUMERIC(6,1) NOT NULL
);
CREATE INDEX ix_readings ON sensor_readings (asset_id, reading_at DESC);

CREATE TABLE work_orders (
  wo_number           VARCHAR(14) PRIMARY KEY,    -- MRE-WO-1101
  asset_id            VARCHAR(16) NOT NULL REFERENCES assets,
  wo_type             VARCHAR(18) NOT NULL CHECK (wo_type IN ('CORRECTIVE','PREVENTIVE','SAFETY_INSPECTION')),
  failure_mode        VARCHAR(20),
  symptom             TEXT NOT NULL,
  priority            VARCHAR(10) NOT NULL CHECK (priority IN ('EMERGENCY','URGENT','HIGH','ROUTINE')),
  status              VARCHAR(12) NOT NULL CHECK (status IN ('OPEN','SCHEDULED','IN_PROGRESS','CLOSED')),
  crew                VARCHAR(40) NOT NULL,
  scheduled_date      DATE,
  estimate_usd        NUMERIC(12,2) NOT NULL DEFAULT 0,
  approved_budget_usd NUMERIC(12,2),             -- supervisor-approved budget (supervisor_approval case)
  opened_at           TIMESTAMP NOT NULL,
  closed_at           TIMESTAMP,
  fix_applied         TEXT,                       -- closed work orders: what fixed it (reliability library)
  parts_used          TEXT,
  downtime_hours      NUMERIC(6,1),
  created_by          VARCHAR(10),                -- operator staff id (NULL for seeded history)
  approved_by         VARCHAR(10),                -- reviewer staff id when a supervisor / HSE approved it
  case_id             VARCHAR(16),
  proposal_id         TEXT UNIQUE
);

CREATE TABLE alerts (
  alert_id       VARCHAR(12) PRIMARY KEY,         -- ALR-000101
  asset_id       VARCHAR(16) NOT NULL REFERENCES assets,
  severity       VARCHAR(10) NOT NULL CHECK (severity IN ('WARNING','CRITICAL')),
  failure_mode   VARCHAR(20),
  message        TEXT NOT NULL,
  logged_date    DATE NOT NULL DEFAULT current_date,
  logged_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  logged_by      VARCHAR(10),                     -- operator staff id (NULL = monitoring system)
  status         VARCHAR(14) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','CLOSED')),
  closed_at      TIMESTAMP,
  UNIQUE (asset_id, logged_date)                  -- one alert per asset per day (backstop for alert_row)
);

CREATE TABLE alert_attempts (                     -- every log_alert call by a verified operator (readback)
  attempt_id   SERIAL PRIMARY KEY,
  operator_id  VARCHAR(10) NOT NULL REFERENCES operators,
  asset_ref    VARCHAR(40) NOT NULL,
  outcome      VARCHAR(22) NOT NULL,
  alert_id     VARCHAR(12),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- A technician's free-text note, the triage agent's reading of it, and SQL's reconciliation with the sensors.
CREATE TABLE field_notes (
  note_id             VARCHAR(12) PRIMARY KEY,    -- FN-000101
  asset_id            VARCHAR(16) NOT NULL REFERENCES assets,
  operator_id         VARCHAR(10) NOT NULL REFERENCES operators,
  note_text           TEXT NOT NULL,
  agent_failure_mode  VARCHAR(20),                -- validated against failure_modes (NULL if not recognised)
  agent_urgency       VARCHAR(10),
  agent_safety        BOOLEAN NOT NULL DEFAULT FALSE,
  agent_summary       TEXT,
  health_status       VARCHAR(10) NOT NULL,       -- classify_asset() at the time of the note
  sql_failure_mode    VARCHAR(20),
  agreement           VARCHAR(20) NOT NULL CHECK (agreement IN ('AGREE','DIFFERENT','NO_SENSOR_ANOMALY','AGENT_MODE_INVALID')),
  safety_source       VARCHAR(8) NOT NULL CHECK (safety_source IN ('AGENT','KEYWORD','BOTH','NONE')),
  safety_phrase       TEXT,
  reconciled_action   VARCHAR(20) NOT NULL CHECK (reconciled_action IN ('SAFETY_CASE','WORK_ORDER_ELIGIBLE','MONITOR')),
  case_id             VARCHAR(16),                -- the safety_signal case (new or existing)
  new_case            BOOLEAN NOT NULL DEFAULT FALSE,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Two-step action (work order)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'MRE-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  operator_id    VARCHAR(10) NOT NULL REFERENCES operators,
  action_type    VARCHAR(12) NOT NULL CHECK (action_type IN ('WORK_ORDER')),
  target_key     TEXT NOT NULL,                   -- normalised request, shared by write-row and readback
  asset_id       VARCHAR(16),
  failure_mode   VARCHAR(20),
  note           TEXT,
  priority       VARCHAR(10),
  estimate_usd   NUMERIC(12,2),
  needs_approval BOOLEAN NOT NULL DEFAULT FALSE,  -- estimate above the operator's limit -> Production Engineering case
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_op ON pending_actions (operator_id, action_type, target_key, created_at);

-- Insert-only confirmed actions. trg_action_event applies them (work order / supervisor case).
CREATE TABLE action_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(20) NOT NULL UNIQUE,     -- MRE-WO-1101 / MRE-CASE-000104
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  operator_id    VARCHAR(10) NOT NULL REFERENCES operators,
  action_type    VARCHAR(20) NOT NULL CHECK (action_type IN ('WORK_ORDER','SUPERVISOR_APPROVAL')),
  asset_id       VARCHAR(16) NOT NULL REFERENCES assets,
  failure_mode   VARCHAR(20),
  priority       VARCHAR(10),
  estimate_usd   NUMERIC(12,2),
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  operator_id    VARCHAR(10) NOT NULL REFERENCES operators,
  proposal_ref   TEXT NOT NULL,
  outcome        VARCHAR(20) NOT NULL,
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  reference      VARCHAR(20),
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Shut-in events (only from an approved shut_in case). trg_asset_event applies them.
CREATE TABLE asset_events (
  event_id     BIGSERIAL PRIMARY KEY,
  reference    VARCHAR(16) NOT NULL UNIQUE,       -- MRE-SHT-000101
  asset_id     VARCHAR(16) NOT NULL REFERENCES assets,
  event_type   VARCHAR(12) NOT NULL CHECK (event_type IN ('SHUT_IN')),
  actor        VARCHAR(10) NOT NULL,              -- reviewer staff id
  case_id      VARCHAR(16) NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Alert closures (only from an approved alert_closure case). trg_alert_event applies them.
CREATE TABLE alert_events (
  event_id     BIGSERIAL PRIMARY KEY,
  alert_id     VARCHAR(12) NOT NULL REFERENCES alerts,
  event_type   VARCHAR(8) NOT NULL CHECK (event_type IN ('CLOSE')),
  actor        VARCHAR(10) NOT NULL,
  case_id      VARCHAR(16) NOT NULL UNIQUE,
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,   -- MRE-CASE-000101
  site_id          VARCHAR(4) NOT NULL REFERENCES sites,
  asset_id         VARCHAR(16) NOT NULL REFERENCES assets,
  opened_by        VARCHAR(10) NOT NULL,          -- operator staff id
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary          TEXT NOT NULL,                 -- the request, neutral, in the operator's words
  reference_id     VARCHAR(20),                   -- asset / alert / field note the case is about
  requested_amount NUMERIC(12,2),                 -- USD estimate (supervisor approval), else NULL
  parked_action    VARCHAR(40),                   -- WORK_ORDER:<proposal> / SHUT_IN:<asset> / SAFETY_WO:<asset> / ALERT_CLOSE:<alert>
  agent_brief      TEXT,                          -- AI-prepared neutral brief; never shown to the operator
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                          -- operator-safe outcome text, set by the decision
  approved_amount  NUMERIC(12,2),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_asset ON service_cases (asset_id, request_type, status);

CREATE TABLE case_requests (                      -- every open_service_case call (readback)
  request_id      SERIAL PRIMARY KEY,
  operator_id     VARCHAR(10) NOT NULL REFERENCES operators,
  request_type    VARCHAR(40) NOT NULL,
  asset_ref       VARCHAR(40),
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
  approved_amount  NUMERIC(12,2),
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
  event_type  VARCHAR(20) NOT NULL,               -- WO_CREATED / ALERT_LOGGED / FIELD_NOTE / CASE_OPENED / CASE_DECIDED / SHUT_IN / ALERT_CLOSED
  actor       VARCHAR(10) NOT NULL,               -- operator or reviewer staff id
  subject_id  VARCHAR(20) NOT NULL,               -- reference / work order / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id      SERIAL PRIMARY KEY,
  asset_id      VARCHAR(16) NOT NULL REFERENCES assets,
  operator_id   VARCHAR(10) NOT NULL REFERENCES operators,
  subject       TEXT NOT NULL,
  logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- HELPERS (dates and money are returned as text everywhere)
-- =====================================================================
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION dt(p TIMESTAMP) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD HH24:MI') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION wday(p DATE) RETURNS TEXT AS $$ SELECT trim(to_char(p, 'Day')) $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION num_txt(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE trim_scale(n)::text END
$$ LANGUAGE sql IMMUTABLE;

-- MRE-4101 / mre4101 / MRE 4101 / 4101 -> MRE-4101
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'MRE-' || x
              WHEN x ~ '^MRE[0-9]{4}$' THEN 'MRE-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ids typed by people or the model: ' mre-case-000101 ' -> 'MRE-CASE-000101'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- 'Bearing wear' / 'bearing-wear' / 'BEARING_WEAR' -> 'bearing_wear'; '' -> ''
CREATE OR REPLACE FUNCTION norm_mode(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 30)
$$ LANGUAGE sql IMMUTABLE;
-- USD as typed: '$68,000' / '68000.00' / '60k' / '60 K' -> '68000' / '60000'; '' -> ''; anything else -> upper text (AMOUNT_INVALID)
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x = '' THEN ''
              WHEN x ~ '^-?[0-9]+(\.[0-9]{1,2})?$' THEN x
              WHEN x ~ '^-?[0-9]+(\.[0-9]+)?K$' THEN trim_scale(substr(x, 1, length(x) - 1)::numeric * 1000)::text
              ELSE left(x, 20) END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p, '')), '[\s,$]|USD', '', 'gi')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- An asset as typed: 'PUMP-PB-W47' / 'pump pb w47' / 'PUMPPBW47' / the short well or station tag 'W47' -> asset_id or NULL
CREATE OR REPLACE FUNCTION asset_lookup(p TEXT) RETURNS TEXT AS $$
  SELECT coalesce(
    (SELECT a.asset_id FROM assets a
      WHERE regexp_replace(upper(a.asset_id), '[^A-Z0-9]', '', 'g') = regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g')),
    (SELECT min(a.asset_id) FROM assets a
      WHERE regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g') ~ '^[WS][0-9]{2}$'
        AND split_part(a.asset_id, '-', 3) = regexp_replace(upper(p), '[^A-Z0-9]', '', 'g')
     HAVING count(*) = 1))
$$ LANGUAGE sql STABLE;
-- The operator's asset: only when it is at the operator's site.
CREATE OR REPLACE FUNCTION site_asset(p_site TEXT, p_asset TEXT) RETURNS TEXT AS $$
  SELECT a.asset_id FROM assets a WHERE a.asset_id = asset_lookup(p_asset) AND a.site_id = p_site
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;
CREATE OR REPLACE FUNCTION type_label(p_type TEXT) RETURNS TEXT AS $$
  SELECT CASE p_type WHEN 'ROD_PUMP' THEN 'rod pump' WHEN 'ESP' THEN 'electric submersible pump'
                     WHEN 'COMPRESSOR' THEN 'gas compressor' WHEN 'WELLHEAD_VALVE' THEN 'wellhead valve' ELSE lower(p_type) END
$$ LANGUAGE sql IMMUTABLE;

-- =====================================================================
-- THE HEALTH CLASSIFIER (deterministic - replaces the legacy LLM-as-classifier)
-- Latest reading per asset; each sensor NORMAL / WARNING / CRITICAL against sensor_thresholds; the worst sensor wins
-- (ties: the larger normalised exceedance = how far past the warning line relative to the warning->critical span);
-- confidence from confidence_lookup by number of anomalous sensors; days to failure from failure_horizon; failure mode =
-- the worst sensor's mode; recommended action + repair estimate from failure_modes.
-- =====================================================================
CREATE OR REPLACE FUNCTION sensor_eval(p_asset TEXT)
RETURNS TABLE (sensor VARCHAR, label VARCHAR, unit VARCHAR, sort_order INTEGER, val NUMERIC, sensor_status TEXT, sev INTEGER,
               score NUMERIC, mode VARCHAR, limits TEXT, reading_at TIMESTAMP) AS $$
  SELECT t.sensor, t.label, t.unit, t.sort_order, v.val,
         CASE WHEN v.lvl = 2 THEN 'CRITICAL' WHEN v.lvl = 1 THEN 'WARNING' ELSE 'NORMAL' END, v.lvl,
         CASE WHEN t.warn_high IS NOT NULL AND v.val > t.warn_high THEN (v.val - t.warn_high) / (t.crit_high - t.warn_high)
              WHEN t.warn_low IS NOT NULL AND v.val < t.warn_low THEN (t.warn_low - v.val) / (t.warn_low - t.crit_low)
              ELSE 0 END,
         (CASE WHEN t.warn_high IS NOT NULL AND v.val > t.warn_high THEN t.mode_high
               WHEN t.warn_low IS NOT NULL AND v.val < t.warn_low THEN t.mode_low END)::varchar,
         concat_ws(', ',
           CASE WHEN t.warn_low IS NOT NULL THEN 'warning below ' || num_txt(t.warn_low) || ', critical below ' || num_txt(t.crit_low) END,
           CASE WHEN t.warn_high IS NOT NULL THEN 'warning above ' || num_txt(t.warn_high) || ', critical above ' || num_txt(t.crit_high) END),
         l.reading_at
    FROM (SELECT r.* FROM sensor_readings r WHERE r.asset_id = p_asset ORDER BY r.reading_at DESC LIMIT 1) l
    CROSS JOIN sensor_thresholds t
    CROSS JOIN LATERAL (
      SELECT x.val,
             CASE WHEN (t.crit_high IS NOT NULL AND x.val > t.crit_high) OR (t.crit_low IS NOT NULL AND x.val < t.crit_low) THEN 2
                  WHEN (t.warn_high IS NOT NULL AND x.val > t.warn_high) OR (t.warn_low IS NOT NULL AND x.val < t.warn_low) THEN 1
                  ELSE 0 END AS lvl
        FROM (SELECT CASE t.sensor WHEN 'vibration' THEN l.vibration_g WHEN 'temperature' THEN l.temperature_f
                                   WHEN 'pressure' THEN l.pressure_psi WHEN 'flow' THEN l.flow_bbl_h END AS val) x) v
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION classify_asset(p_asset TEXT)
RETURNS TABLE (asset_id VARCHAR, health_status TEXT, worst_sensor VARCHAR, anomalous_sensors INTEGER, failure_mode VARCHAR,
               confidence NUMERIC, days_to_failure TEXT, min_days INTEGER, max_days INTEGER, anomalies TEXT,
               recommended_action TEXT, repair_estimate NUMERIC, reading_at TIMESTAMP) AS $$
  SELECT a.asset_id,
         coalesce(w.sensor_status, 'NO_DATA'),
         CASE WHEN w.sev > 0 THEN w.sensor END,
         coalesce(n.cnt, 0),
         CASE WHEN w.sev > 0 THEN w.mode END,
         cl.confidence,
         CASE WHEN fh.health_status IS NULL THEN NULL WHEN fh.max_days IS NULL THEN fh.min_days || '+ days'
              ELSE fh.min_days || '-' || fh.max_days || ' days' END,
         fh.min_days, fh.max_days,
         coalesce(n.txt, 'No anomalies: every sensor is within its normal range.'),
         CASE WHEN w.sev > 0 THEN fm.recommended_action ELSE 'No action required. Continue routine monitoring.' END,
         CASE WHEN w.sev > 0 THEN fm.est_cost_usd END,
         w.reading_at
    FROM assets a
    LEFT JOIN LATERAL (SELECT e.* FROM sensor_eval(a.asset_id) e ORDER BY e.sev DESC, e.score DESC, e.sort_order LIMIT 1) w ON TRUE
    LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE e.sev > 0)::int AS cnt,
                              string_agg(e.label || ' ' || num_txt(e.val) || ' ' || e.unit || ' ' || e.sensor_status
                                         || ' (' || e.limits || ')', '; ' ORDER BY e.sev DESC, e.score DESC, e.sort_order)
                                FILTER (WHERE e.sev > 0) AS txt
                         FROM sensor_eval(a.asset_id) e) n ON TRUE
    LEFT JOIN confidence_lookup cl ON cl.anomalous_sensors = coalesce(n.cnt, 0) AND w.sensor IS NOT NULL
    LEFT JOIN failure_horizon fh ON fh.health_status = w.sensor_status
    LEFT JOIN failure_modes fm ON fm.asset_type = a.asset_type AND fm.failure_mode = w.mode
   WHERE a.asset_id = p_asset
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION health_rank(p TEXT) RETURNS INTEGER AS $$
  SELECT CASE p WHEN 'CRITICAL' THEN 2 WHEN 'WARNING' THEN 1 ELSE 0 END
$$ LANGUAGE sql IMMUTABLE;

-- One line the triage agent can be given (equipment data only).
CREATE OR REPLACE FUNCTION health_line(p_asset TEXT) RETURNS TEXT AS $$
  SELECT c.health_status || coalesce(' (' || c.worst_sensor || ' -> ' || c.failure_mode || ')', '') || ': ' || c.anomalies
    FROM classify_asset(p_asset) c
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- IDENTITY (operators and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the operator + site when the token is a valid OPERATOR token, else NULLs.
CREATE OR REPLACE FUNCTION session_operator(p_token TEXT)
RETURNS TABLE (staff_id VARCHAR, site_id VARCHAR, display_name VARCHAR, spend_limit NUMERIC) AS $$
BEGIN
  RETURN QUERY
    SELECT o.staff_id, o.site_id, o.display_name, o.spend_limit
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'OPERATOR'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN operators o ON o.staff_id = s.operator_id AND o.active;
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

-- Guarded write-row for verify_operator: records the attempt (throttle); returns the sessions row ONLY for a matching
-- staff id + code while the id is not locked (5 failures in 15 minutes).
CREATE OR REPLACE FUNCTION verify_operator_fn(p_staff TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, operator_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_staff_id(p_staff); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'OPERATOR' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('OPERATOR', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT o.staff_id INTO v_match FROM operators o
   WHERE o.staff_id = v_id AND o.one_time_code = trim(coalesce(p_code, '')) AND o.active;
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('OPERATOR', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('OPERATOR', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'OPERATOR'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_operator_result(p_staff TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, role TEXT, display_name VARCHAR, region TEXT, spend_limit_usd TEXT,
               expires_at TEXT, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'OPERATOR' END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.display_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.region END,
         CASE WHEN va.outcome = 'VERIFIED' THEN usd(se.spend_limit) END,
         CASE WHEN va.outcome = 'VERIFIED' THEN dt(se.expires_at) END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL
                THEN 'You are verified as the control-room operator for ' || se.region || '. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For security, verification is paused for 15 minutes. Please try again later.'
              ELSE 'That staff ID and code do not match our records. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'OPERATOR' AND a.identifier = norm_staff_id(p_staff)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, o.display_name, st.site_name || ' (' || st.basin || ', ' || st.town || ')' AS region,
                              o.spend_limit, s.expires_at
                         FROM operators o JOIN sites st ON st.site_id = o.site_id
                         JOIN sessions s ON s.operator_id = o.staff_id AND s.role = 'OPERATOR' AND s.expires_at > clock_timestamp()
                        WHERE o.staff_id = norm_staff_id(p_staff) AND o.one_time_code = trim(coalesce(p_code, '')) AND o.active
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
         CASE WHEN va.outcome = 'VERIFIED' THEN dt(se.expires_at) END,
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
-- SCOPED READS (operator) - every function starts FROM session_operator(token) and stays on that site
-- =====================================================================
CREATE OR REPLACE FUNCTION region_assets(p_token TEXT)
RETURNS TABLE (status TEXT, region VARCHAR, asset_id VARCHAR, asset_type TEXT, description VARCHAR, asset_status VARCHAR,
               health_status TEXT, worst_sensor VARCHAR, failure_mode VARCHAR, confidence NUMERIC, days_to_failure TEXT,
               open_work_order VARCHAR, open_alerts INTEGER, latest_reading_at TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         st.site_name, a.asset_id, type_label(a.asset_type), a.description, a.status,
         c.health_status, c.worst_sensor, c.failure_mode, c.confidence, c.days_to_failure,
         (SELECT w.wo_number FROM work_orders w WHERE w.asset_id = a.asset_id AND w.status <> 'CLOSED' ORDER BY w.opened_at DESC LIMIT 1),
         (SELECT count(*)::int FROM alerts al WHERE al.asset_id = a.asset_id AND al.status <> 'CLOSED'),
         dt(c.reading_at)
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN sites st ON st.site_id = so.site_id
    LEFT JOIN assets a ON a.site_id = so.site_id
    LEFT JOIN LATERAL classify_asset(a.asset_id) c ON TRUE
   ORDER BY health_rank(c.health_status) DESC, a.asset_id
$$ LANGUAGE sql STABLE;

-- One asset's health, computed by the classifier (not by the model), plus whether a work order may be raised.
CREATE OR REPLACE FUNCTION asset_health(p_token TEXT, p_asset TEXT)
RETURNS TABLE (status TEXT, asset_id VARCHAR, asset_type TEXT, description VARCHAR, region VARCHAR, asset_status VARCHAR,
               health_status TEXT, worst_sensor VARCHAR, anomalous_sensors INTEGER, failure_mode VARCHAR, failure_mode_label VARCHAR,
               confidence NUMERIC, days_to_failure TEXT, anomalies TEXT, recommended_action TEXT, repair_estimate_usd TEXT,
               latest_reading_at TEXT, vibration_g NUMERIC, temperature_f NUMERIC, pressure_psi NUMERIC, flow_bbl_h NUMERIC,
               power_kw NUMERIC, open_work_order VARCHAR, work_order_allowed TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN sa.aid IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         a.asset_id, type_label(a.asset_type), a.description, st.site_name, a.status,
         c.health_status, c.worst_sensor, c.anomalous_sensors, c.failure_mode, fm.label, c.confidence, c.days_to_failure, c.anomalies,
         c.recommended_action, usd(c.repair_estimate), dt(c.reading_at),
         r.vibration_g, r.temperature_f, r.pressure_psi, r.flow_bbl_h, r.power_kw, ow.wo_number,
         CASE WHEN a.asset_id IS NULL THEN NULL
              WHEN a.status = 'MAINTENANCE' THEN 'no - the asset is in MAINTENANCE'
              WHEN a.status = 'SHUT_IN' THEN 'no - the asset is SHUT_IN'
              WHEN ow.wo_number IS NOT NULL THEN 'no - work order ' || ow.wo_number || ' is already open'
              WHEN health_rank(c.health_status) = 0 THEN 'no - health is ' || c.health_status || ' (a work order needs WARNING or CRITICAL)'
              ELSE 'yes' END
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT site_asset(so.site_id, p_asset) AS aid) sa
    LEFT JOIN assets a ON a.asset_id = sa.aid
    LEFT JOIN sites st ON st.site_id = a.site_id
    LEFT JOIN LATERAL classify_asset(a.asset_id) c ON TRUE
    LEFT JOIN failure_modes fm ON fm.asset_type = a.asset_type AND fm.failure_mode = c.failure_mode
    LEFT JOIN LATERAL (SELECT x.* FROM sensor_readings x WHERE x.asset_id = a.asset_id ORDER BY x.reading_at DESC LIMIT 1) r ON TRUE
    LEFT JOIN LATERAL (SELECT w.wo_number FROM work_orders w WHERE w.asset_id = a.asset_id AND w.status <> 'CLOSED'
                        ORDER BY w.opened_at DESC LIMIT 1) ow ON TRUE
$$ LANGUAGE sql STABLE;

-- The last 24 hours of readings for one asset (oldest first) with the reading's own classification.
CREATE OR REPLACE FUNCTION sensor_readings_at(p_token TEXT, p_asset TEXT)
RETURNS TABLE (status TEXT, asset_id VARCHAR, reading_at TEXT, vibration_g NUMERIC, temperature_f NUMERIC, pressure_psi NUMERIC,
               flow_bbl_h NUMERIC, power_kw NUMERIC) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN sa.aid IS NULL THEN 'NOT_FOUND'
              WHEN r.reading_id IS NULL THEN 'NONE' ELSE 'OK' END,
         sa.aid::varchar, dt(r.reading_at), r.vibration_g, r.temperature_f, r.pressure_psi, r.flow_bbl_h, r.power_kw
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT site_asset(so.site_id, p_asset) AS aid) sa
    LEFT JOIN sensor_readings r ON r.asset_id = sa.aid AND r.reading_at > clock_timestamp() - INTERVAL '25 hours'
   ORDER BY r.reading_at
$$ LANGUAGE sql STABLE;

-- Work orders in the region (asset = '' / ALL for every asset): open ones, plus those closed in the last 90 days.
CREATE OR REPLACE FUNCTION work_orders_at(p_token TEXT, p_asset TEXT)
RETURNS TABLE (status TEXT, wo_number VARCHAR, asset_id VARCHAR, wo_type VARCHAR, failure_mode VARCHAR, symptom TEXT,
               priority VARCHAR, wo_status VARCHAR, crew VARCHAR, scheduled TEXT, estimate_usd TEXT, approved_budget_usd TEXT,
               opened TEXT, closed TEXT, supervisor_approved TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID'
              WHEN f.all_assets = FALSE AND f.aid IS NULL THEN 'NOT_FOUND'
              WHEN w.wo_number IS NULL THEN 'NONE' ELSE 'OK' END,
         w.wo_number, w.asset_id, w.wo_type, w.failure_mode, w.symptom, w.priority, w.status, w.crew, d(w.scheduled_date),
         usd(w.estimate_usd), usd(w.approved_budget_usd), dt(w.opened_at), dt(w.closed_at),
         CASE WHEN w.wo_number IS NULL THEN NULL WHEN w.case_id IS NOT NULL THEN 'yes (' || w.case_id || ')' ELSE 'no' END
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT upper(trim(coalesce(p_asset, ''))) IN ('', 'ALL', '*') AS all_assets,
                               site_asset(so.site_id, p_asset) AS aid) f
    LEFT JOIN work_orders w ON so.staff_id IS NOT NULL
         AND w.asset_id IN (SELECT a.asset_id FROM assets a WHERE a.site_id = so.site_id)
         AND (f.all_assets OR w.asset_id = f.aid)
         AND (w.status <> 'CLOSED' OR w.closed_at > clock_timestamp() - INTERVAL '90 days')
   ORDER BY CASE WHEN w.status = 'CLOSED' THEN 1 ELSE 0 END,
            CASE w.priority WHEN 'EMERGENCY' THEN 0 WHEN 'URGENT' THEN 1 WHEN 'HIGH' THEN 2 ELSE 3 END, w.opened_at DESC
$$ LANGUAGE sql STABLE;

-- Alerts in the region (asset = '' / ALL): open or acknowledged ones, plus everything from the last 30 days.
CREATE OR REPLACE FUNCTION alerts_at(p_token TEXT, p_asset TEXT)
RETURNS TABLE (status TEXT, alert_id VARCHAR, asset_id VARCHAR, severity VARCHAR, failure_mode VARCHAR, message TEXT,
               alert_status VARCHAR, logged_at TEXT, logged_by TEXT, closed_at TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID'
              WHEN f.all_assets = FALSE AND f.aid IS NULL THEN 'NOT_FOUND'
              WHEN al.alert_id IS NULL THEN 'NONE' ELSE 'OK' END,
         al.alert_id, al.asset_id, al.severity, al.failure_mode, al.message, al.status, dt(al.logged_at),
         CASE WHEN al.alert_id IS NULL THEN NULL WHEN al.logged_by IS NULL THEN 'monitoring system' ELSE 'control room' END,
         dt(al.closed_at)
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT upper(trim(coalesce(p_asset, ''))) IN ('', 'ALL', '*') AS all_assets,
                               site_asset(so.site_id, p_asset) AS aid) f
    LEFT JOIN alerts al ON so.staff_id IS NOT NULL
         AND al.asset_id IN (SELECT a.asset_id FROM assets a WHERE a.site_id = so.site_id)
         AND (f.all_assets OR al.asset_id = f.aid)
         AND (al.status <> 'CLOSED' OR al.logged_at > clock_timestamp() - INTERVAL '30 days')
   ORDER BY al.logged_at DESC
$$ LANGUAGE sql STABLE;

-- The failure modes that apply to an asset's type (the list the triage agent must pick from).
CREATE OR REPLACE FUNCTION failure_modes_for(p_token TEXT, p_asset TEXT)
RETURNS TABLE (status TEXT, asset_id VARCHAR, asset_type TEXT, failure_mode VARCHAR, label VARCHAR, recommended_action TEXT,
               typical_parts TEXT, repair_estimate_usd TEXT, est_downtime_hours INTEGER, current_health TEXT,
               matches_sensor_classification TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN sa.aid IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         a.asset_id, type_label(a.asset_type), fm.failure_mode, fm.label, fm.recommended_action, fm.typical_parts,
         usd(fm.est_cost_usd), fm.est_downtime_hours, health_line(a.asset_id),
         CASE WHEN fm.failure_mode IS NULL THEN NULL WHEN fm.failure_mode = c.failure_mode THEN 'yes' ELSE 'no' END
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT site_asset(so.site_id, p_asset) AS aid) sa
    LEFT JOIN assets a ON a.asset_id = sa.aid
    LEFT JOIN LATERAL classify_asset(a.asset_id) c ON TRUE
    LEFT JOIN failure_modes fm ON fm.asset_type = a.asset_type
   ORDER BY CASE WHEN fm.failure_mode = c.failure_mode THEN 0 ELSE 1 END, fm.failure_mode
$$ LANGUAGE sql STABLE;

-- The company-wide reliability library for the asset's TYPE: closed work orders (equipment data only, no people).
CREATE OR REPLACE FUNCTION failure_history(p_token TEXT, p_asset TEXT)
RETURNS TABLE (status TEXT, asset_type TEXT, wo_number VARCHAR, past_asset VARCHAR, basin VARCHAR, closed TEXT, failure_mode VARCHAR,
               symptom TEXT, fix_applied TEXT, parts_used TEXT, downtime_hours NUMERIC) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN sa.aid IS NULL THEN 'NOT_FOUND'
              WHEN w.wo_number IS NULL THEN 'NONE' ELSE 'OK' END,
         type_label(a.asset_type), w.wo_number, w.asset_id, st.basin, d(w.closed_at::date), w.failure_mode, w.symptom, w.fix_applied,
         w.parts_used, w.downtime_hours
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT site_asset(so.site_id, p_asset) AS aid) sa
    LEFT JOIN assets a ON a.asset_id = sa.aid
    LEFT JOIN work_orders w ON w.status = 'CLOSED' AND w.fix_applied IS NOT NULL
         AND w.asset_id IN (SELECT x.asset_id FROM assets x WHERE x.asset_type = a.asset_type)
         AND w.closed_at > clock_timestamp() - INTERVAL '730 days'
    LEFT JOIN assets wa ON wa.asset_id = w.asset_id
    LEFT JOIN sites st ON st.site_id = wa.site_id
   ORDER BY w.closed_at DESC
$$ LANGUAGE sql STABLE;

-- The region's shift-handover snapshot. Equipment data only - no operator, reviewer or crew-member names and no case
-- ids (it goes to the handover agent as is).
CREATE OR REPLACE FUNCTION region_handover(p_token TEXT)
RETURNS TABLE (status TEXT, region VARCHAR, item_type TEXT, ref VARCHAR, asset_id VARCHAR, item_status TEXT, detail TEXT,
               due_or_when TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN h.ref IS NULL THEN 'NONE' ELSE 'OK' END,
         st.site_name, h.item_type, h.ref, h.aid, h.st, h.detail, h.due
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN sites st ON st.site_id = so.site_id
    LEFT JOIN LATERAL (
      SELECT 1 AS ord, 'OPEN_CASE'::text AS item_type, r.label::varchar AS ref, c.asset_id::varchar AS aid, c.status::text AS st,
             'waiting for ' || r.team || CASE WHEN c.request_type = 'safety_signal' THEN ' (SAFETY)' ELSE '' END AS detail,
             'reply due ' || dt(c.sla_due_at) AS due
        FROM service_cases c JOIN case_routing r ON r.request_type = c.request_type
       WHERE c.site_id = so.site_id AND c.status = 'OPEN'
      UNION ALL
      SELECT 2, 'ASSET_HEALTH', a.asset_id, a.asset_id, c.health_status,
             type_label(a.asset_type) || ' (' || a.status || ') - ' || c.anomalies || ' | likely ' || coalesce(c.failure_mode, '-')
             || ', confidence ' || c.confidence || ', ' || c.days_to_failure || ' to failure',
             'reading ' || dt(c.reading_at)
        FROM assets a CROSS JOIN LATERAL classify_asset(a.asset_id) c
       WHERE a.site_id = so.site_id AND health_rank(c.health_status) > 0
      UNION ALL
      SELECT 3, 'WORK_ORDER', w.wo_number, w.asset_id, w.status,
             w.priority || ' ' || w.wo_type || ' - ' || coalesce(w.failure_mode || ': ', '') || w.symptom || ' | ' || w.crew,
             'scheduled ' || coalesce(d(w.scheduled_date), '-')
        FROM work_orders w JOIN assets a ON a.asset_id = w.asset_id
       WHERE a.site_id = so.site_id AND w.status <> 'CLOSED'
      UNION ALL
      SELECT 4, 'ALERT', al.alert_id, al.asset_id, al.status, al.severity || ' - ' || al.message, 'logged ' || dt(al.logged_at)
        FROM alerts al JOIN assets a ON a.asset_id = al.asset_id
       WHERE a.site_id = so.site_id AND al.status <> 'CLOSED'
      UNION ALL
      SELECT 5, 'FIELD_NOTE', fn.note_id, fn.asset_id, fn.reconciled_action,
             'note: "' || left(fn.note_text, 200) || '" | triage: ' || coalesce(fn.agent_summary, '-'), 'noted ' || dt(fn.created_at)
        FROM field_notes fn JOIN assets a ON a.asset_id = fn.asset_id
       WHERE a.site_id = so.site_id AND fn.created_at > clock_timestamp() - INTERVAL '12 hours'
      UNION ALL
      SELECT 6, 'DECISION', r.label::varchar, c.asset_id, c.status, coalesce(c.customer_message, ''), 'decided ' || dt(c.decided_at)
        FROM service_cases c JOIN case_routing r ON r.request_type = c.request_type
       WHERE c.site_id = so.site_id AND c.status <> 'OPEN' AND c.decided_at > clock_timestamp() - INTERVAL '24 hours'
    ) h ON so.staff_id IS NOT NULL
   ORDER BY h.ord, h.ref
$$ LANGUAGE sql STABLE;

-- The region's cases. Never the internal note, the agent brief or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, asset_id VARCHAR, about VARCHAR, team VARCHAR, case_status VARCHAR,
               opened_at TEXT, reply_due TEXT, requested_budget_usd TEXT, approved_budget_usd TEXT, decided_at TEXT,
               customer_message TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN c.case_id IS NULL THEN 'NONE' ELSE 'OK' END,
         c.case_id, r.label, c.asset_id, c.reference_id, r.team, c.status, dt(c.created_at), dt(c.sla_due_at),
         usd(c.requested_amount), usd(c.approved_amount), dt(c.decided_at),
         CASE WHEN c.case_id IS NULL THEN NULL
              WHEN c.status = 'OPEN' THEN 'Open - a person on the ' || r.team || ' team will decide.' ELSE c.customer_message END
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN service_cases c ON c.site_id = so.site_id
    LEFT JOIN case_routing r ON r.request_type = c.request_type
   ORDER BY c.created_at DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- FIELD NOTE (the fuzzy step, governed): the triage agent reads the technician's text; this function validates the
-- agent's output, RECONCILES it with the sensor classification and decides the next step in SQL. Safety language -
-- flagged by the agent OR matched by the keyword backstop - always opens (or joins) an HSE safety_signal case.
-- =====================================================================
CREATE OR REPLACE FUNCTION norm_urgency(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('LOW','MINOR','ROUTINE') THEN 'LOW' WHEN x IN ('MEDIUM','MODERATE','NORMAL') THEN 'MEDIUM'
              WHEN x IN ('HIGH','URGENT','SOON') THEN 'HIGH' WHEN x IN ('IMMEDIATE','CRITICAL','EMERGENCY','NOW') THEN 'IMMEDIATE' END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION is_yes(p TEXT) RETURNS BOOLEAN AS $$
  SELECT upper(trim(coalesce(p, ''))) IN ('YES','Y','TRUE','1','SAFETY','DETECTED')
$$ LANGUAGE sql IMMUTABLE;

-- Deterministic backstop: literal safety words. Paraphrases ("rotten-egg smell", "the monitor chirped") are the agent's job.
CREATE OR REPLACE FUNCTION safety_keyword(p TEXT) RETURNS TEXT AS $$
  SELECT substring(lower(coalesce(p, '')) FROM
    '\m(gas odou?rs?|smell(s|ed|ing)? (of )?gas|h2s|hydrogen sulfide|spill(s|ed|ing)?|fire|flames?|smoke|injur(y|ed|ies)|explosion|blowout|uncontrolled release)\M')
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION field_note_row(p_token TEXT, p_asset TEXT, p_text TEXT, p_mode TEXT, p_urgency TEXT, p_safety TEXT, p_summary TEXT)
RETURNS TABLE (note_id VARCHAR, asset_id VARCHAR, operator_id VARCHAR, note_text TEXT, agent_failure_mode VARCHAR, agent_urgency VARCHAR,
               agent_safety BOOLEAN, agent_summary TEXT, health_status VARCHAR, sql_failure_mode VARCHAR, agreement VARCHAR,
               safety_source VARCHAR, safety_phrase TEXT, reconciled_action VARCHAR, case_id VARCHAR, new_case BOOLEAN) AS $$
#variable_conflict use_column
DECLARE so RECORD; a assets; c RECORD; v_aid TEXT; v_text TEXT := left(trim(coalesce(p_text, '')), 4000);
        v_mode TEXT := norm_mode(p_mode); v_valid BOOLEAN; v_kw TEXT; v_agent BOOLEAN := is_yes(p_safety); v_src TEXT;
        v_agree TEXT; v_action TEXT; v_case TEXT; v_new BOOLEAN := FALSE; v_open_wo BOOLEAN;
BEGIN
  SELECT * INTO so FROM session_operator(p_token) s;
  IF so.staff_id IS NULL THEN RETURN; END IF;
  v_aid := site_asset(so.site_id, p_asset);
  IF v_aid IS NULL OR v_text = '' THEN RETURN; END IF;                    -- readback: NOT_FOUND / NOTE_EMPTY
  SELECT * INTO a FROM assets x WHERE x.asset_id = v_aid;
  SELECT * INTO c FROM classify_asset(v_aid) x;
  IF v_mode IN ('', 'none', 'unknown', 'n/a', 'na', 'null') THEN v_mode := NULL; END IF;
  v_valid := v_mode IS NULL OR EXISTS (SELECT 1 FROM failure_modes fm WHERE fm.asset_type = a.asset_type AND fm.failure_mode = v_mode);
  v_kw := safety_keyword(v_text);
  v_src := CASE WHEN v_agent AND v_kw IS NOT NULL THEN 'BOTH' WHEN v_agent THEN 'AGENT' WHEN v_kw IS NOT NULL THEN 'KEYWORD' ELSE 'NONE' END;
  v_agree := CASE WHEN NOT v_valid THEN 'AGENT_MODE_INVALID'
                  WHEN health_rank(c.health_status) = 0 THEN 'NO_SENSOR_ANOMALY'
                  WHEN v_mode IS NOT NULL AND v_mode IN (SELECT e.mode FROM sensor_eval(v_aid) e WHERE e.sev > 0) THEN 'AGREE'
                  ELSE 'DIFFERENT' END;
  v_open_wo := EXISTS (SELECT 1 FROM work_orders w WHERE w.asset_id = v_aid AND w.status <> 'CLOSED');
  v_action := CASE WHEN v_src <> 'NONE' THEN 'SAFETY_CASE'
                   WHEN health_rank(c.health_status) > 0 AND a.status = 'OPERATIONAL' AND NOT v_open_wo THEN 'WORK_ORDER_ELIGIBLE'
                   ELSE 'MONITOR' END;
  IF v_action = 'SAFETY_CASE' THEN
    SELECT s.case_id INTO v_case FROM service_cases s
     WHERE s.asset_id = v_aid AND s.request_type = 'safety_signal' AND s.status = 'OPEN' ORDER BY s.created_at DESC LIMIT 1;
    IF v_case IS NULL THEN
      v_case := 'MRE-CASE-' || lpad(nextval(pg_get_serial_sequence('service_cases', 'case_no'))::text, 6, '0');
      v_new := TRUE;
    END IF;
  END IF;
  RETURN QUERY SELECT ('FN-' || lpad(nextval('note_seq')::text, 6, '0'))::varchar, v_aid::varchar, so.staff_id, v_text,
                      (CASE WHEN v_valid THEN v_mode END)::varchar, norm_urgency(p_urgency)::varchar, v_agent,
                      left(nullif(trim(coalesce(p_summary, '')), ''), 2000), c.health_status::varchar, c.failure_mode,
                      v_agree::varchar, v_src::varchar,
                      coalesce(v_kw, CASE WHEN v_agent THEN '(flagged by the triage agent)' END), v_action::varchar,
                      v_case::varchar, v_new;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION apply_field_note() RETURNS TRIGGER AS $$
DECLARE r case_routing;
BEGIN
  PERFORM audit('FIELD_NOTE', NEW.operator_id, NEW.note_id, NEW.asset_id || ' -> ' || NEW.reconciled_action || ' (' || NEW.agreement
                || ', safety ' || NEW.safety_source || ')');
  IF NEW.new_case THEN
    SELECT * INTO r FROM case_routing WHERE request_type = 'safety_signal';
    INSERT INTO service_cases (case_no, case_id, site_id, asset_id, opened_by, request_type, summary, reference_id, requested_amount,
                               parked_action, agent_brief, sla_due_at)
      SELECT substring(NEW.case_id FROM '[0-9]+$')::bigint, NEW.case_id, a.site_id, NEW.asset_id, NEW.operator_id, 'safety_signal',
             'Field note on ' || NEW.asset_id || ': "' || left(NEW.note_text, 1500) || '"', NEW.note_id, NULL,
             'SAFETY_WO:' || NEW.asset_id,
             'Triage agent: ' || coalesce(NEW.agent_summary, '(no summary)') || ' | safety language: ' || coalesce(NEW.safety_phrase, '-')
             || ' (source ' || NEW.safety_source || ') | sensors: ' || health_line(NEW.asset_id),
             clock_timestamp()::timestamp + r.sla_hours * INTERVAL '1 hour'
        FROM assets a WHERE a.asset_id = NEW.asset_id;
    PERFORM audit('CASE_OPENED', NEW.operator_id, NEW.case_id, 'safety_signal for ' || NEW.asset_id || ' from ' || NEW.note_id);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_field_note AFTER INSERT ON field_notes FOR EACH ROW EXECUTE FUNCTION apply_field_note();

CREATE OR REPLACE FUNCTION field_note_result(p_token TEXT, p_asset TEXT, p_text TEXT)
RETURNS TABLE (outcome TEXT, note_id VARCHAR, asset_id VARCHAR, health_status VARCHAR, sql_failure_mode VARCHAR,
               agent_failure_mode VARCHAR, agreement VARCHAR, safety_detected TEXT, safety_source VARCHAR, safety_phrase TEXT,
               case_id VARCHAR, team VARCHAR, reply_due TEXT, reason_text TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN sa.aid IS NULL THEN 'NOT_FOUND'
              WHEN trim(coalesce(p_text, '')) = '' THEN 'NOTE_EMPTY' ELSE coalesce(fn.reconciled_action, 'NOT_FOUND') END,
         fn.note_id, fn.asset_id, fn.health_status, fn.sql_failure_mode, fn.agent_failure_mode, fn.agreement,
         CASE WHEN fn.note_id IS NULL THEN NULL WHEN fn.safety_source <> 'NONE' THEN 'yes' ELSE 'no' END,
         fn.safety_source, fn.safety_phrase, fn.case_id,
         CASE WHEN fn.case_id IS NOT NULL THEN 'HSE' END::varchar,
         dt(sc.sla_due_at),
         CASE WHEN so.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN sa.aid IS NULL THEN 'I could not find that asset in your region, so the note was not logged.'
              WHEN trim(coalesce(p_text, '')) = '' THEN 'The note text is empty, so nothing was logged.'
              WHEN fn.reconciled_action = 'SAFETY_CASE' THEN
                CASE WHEN fn.new_case THEN 'Safety language in the note (' || fn.safety_phrase || '), so case ' || fn.case_id
                          || ' is now with HSE (reply due ' || dt(sc.sla_due_at) || '). HSE decides what happens next; no work order is raised from this note.'
                     ELSE 'Safety language in the note (' || fn.safety_phrase || '). HSE case ' || fn.case_id
                          || ' is already open for this asset, so the note was added to it. HSE decides what happens next.' END
              WHEN fn.reconciled_action = 'WORK_ORDER_ELIGIBLE' THEN
                'Sensors say ' || fn.health_status || ' (' || fn.sql_failure_mode || ')'
                || CASE fn.agreement WHEN 'AGREE' THEN ' and the triage agrees.' WHEN 'AGENT_MODE_INVALID' THEN '; the triage named a failure mode that does not apply to this asset type, so it was ignored.'
                                     ELSE '; the triage points to ' || coalesce(fn.agent_failure_mode, 'no clear failure mode') || ', which differs - check before choosing.' END
                || ' A work order can be proposed.'
              WHEN fn.reconciled_action = 'MONITOR' THEN
                CASE WHEN fn.health_status NOT IN ('WARNING','CRITICAL') THEN 'Sensors are ' || fn.health_status
                          || ', so the note is logged for monitoring. A work order needs WARNING or CRITICAL health.'
                     ELSE 'Logged for monitoring: the asset is in maintenance, shut in, or already has an open work order.' END
              ELSE 'The note was not logged.' END
    FROM (SELECT * FROM session_operator(p_token)) so
    CROSS JOIN LATERAL (SELECT site_asset(so.site_id, p_asset) AS aid) sa
    LEFT JOIN LATERAL (SELECT f.* FROM field_notes f
                        WHERE f.operator_id = so.staff_id AND f.asset_id = sa.aid AND f.note_text = left(trim(coalesce(p_text, '')), 4000)
                        ORDER BY f.created_at DESC LIMIT 1) fn ON TRUE
    LEFT JOIN service_cases sc ON sc.case_id = fn.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- WORK ORDER (two-step): rules -> propose (PROPOSED / BLOCKED, 15 minutes) -> confirm (re-check)
-- -> action event + trigger (work order created, or a Production Engineering case when the estimate is above the limit)
-- =====================================================================
CREATE OR REPLACE FUNCTION work_order_key(p_asset TEXT, p_mode TEXT) RETURNS TEXT AS $$
  SELECT 'WO|' || coalesce(asset_lookup(p_asset), norm_ref(p_asset)) || '|'
         || CASE WHEN norm_mode(p_mode) IN ('', 'none', 'unknown') THEN '' ELSE norm_mode(p_mode) END
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION work_order_eval(p_site TEXT, p_limit NUMERIC, p_asset TEXT, p_mode TEXT, p_note TEXT)
RETURNS TABLE (ok BOOLEAN, needs_approval BOOLEAN, reason_code TEXT, reason_text TEXT, asset_id VARCHAR, failure_mode VARCHAR,
               priority VARCHAR, estimate_usd NUMERIC, scheduled_date DATE, summary TEXT) AS $$
  SELECT x.code = 'OK', (x.code = 'OK' AND fm.est_cost_usd > p_limit), nullif(x.code, 'OK'),
         CASE x.code
           WHEN 'OK' THEN NULL
           WHEN 'NOT_FOUND' THEN 'I could not find asset ' || norm_ref(p_asset) || ' in your region. No work order was created.'
           WHEN 'ASSET_SHUT_IN' THEN a.asset_id || ' is SHUT_IN. No work order was created; restarting it is a Production Engineering decision.'
           WHEN 'ASSET_IN_MAINTENANCE' THEN a.asset_id || ' is already in MAINTENANCE' || coalesce(' (' || x.open_wo || ')', '')
                || '. No new work order was created.'
           WHEN 'OPEN_WO_EXISTS' THEN a.asset_id || ' already has ' || x.open_wo || '. No new work order was created.'
           WHEN 'HEALTH_NORMAL' THEN a.asset_id || ' is ' || c.health_status || ' on every sensor. A work order needs WARNING or CRITICAL health, '
                || 'so none was created. A safety concern goes to HSE instead.'
           WHEN 'FAILURE_MODE_INVALID' THEN '"' || norm_mode(p_mode) || '" is not a failure mode for a ' || type_label(a.asset_type)
                || '. Valid: ' || (SELECT string_agg(f2.failure_mode, ', ' ORDER BY f2.failure_mode) FROM failure_modes f2 WHERE f2.asset_type = a.asset_type)
                || '. No work order was created.'
         END,
         a.asset_id, x.mode::varchar, fh.wo_priority, fm.est_cost_usd, current_date + fh.schedule_days,
         CASE WHEN x.code = 'OK' THEN
           'Create a ' || fh.wo_priority || ' corrective work order for ' || a.asset_id || ' (' || type_label(a.asset_type) || ', ' || st.site_name
           || '): ' || fm.label || ' - ' || fm.recommended_action || ' Health ' || c.health_status || ': ' || c.anomalies || '. Crew: ' || st.field_crew
           || ', scheduled ' || wday(current_date + fh.schedule_days) || ' ' || d(current_date + fh.schedule_days) || '. Estimate '
           || usd(fm.est_cost_usd) || ' (typical parts: ' || fm.typical_parts || ').'
           || CASE WHEN x.mode IS DISTINCT FROM c.failure_mode THEN ' Note: the sensor classification points to ' || c.failure_mode || '.' ELSE '' END
           || CASE WHEN fm.est_cost_usd > p_limit THEN ' This is above your ' || usd(p_limit) || ' limit, so confirming sends it to Production '
                   || 'Engineering for approval; no work order is created until a supervisor approves.' ELSE '' END
         END
    FROM (SELECT 1) one
    LEFT JOIN assets a ON a.asset_id = site_asset(p_site, p_asset)
    LEFT JOIN sites st ON st.site_id = a.site_id
    LEFT JOIN LATERAL classify_asset(a.asset_id) c ON TRUE
    LEFT JOIN failure_horizon fh ON fh.health_status = c.health_status
    CROSS JOIN LATERAL (
      SELECT m.mode, ow.open_wo,
             CASE WHEN a.asset_id IS NULL THEN 'NOT_FOUND'
                  WHEN a.status = 'SHUT_IN' THEN 'ASSET_SHUT_IN'
                  WHEN a.status = 'MAINTENANCE' THEN 'ASSET_IN_MAINTENANCE'
                  WHEN ow.open_wo IS NOT NULL THEN 'OPEN_WO_EXISTS'
                  WHEN health_rank(c.health_status) = 0 THEN 'HEALTH_NORMAL'
                  WHEN NOT EXISTS (SELECT 1 FROM failure_modes f1 WHERE f1.asset_type = a.asset_type AND f1.failure_mode = m.mode) THEN 'FAILURE_MODE_INVALID'
                  ELSE 'OK' END AS code
        FROM (SELECT coalesce(CASE WHEN norm_mode(p_mode) IN ('', 'none', 'unknown') THEN NULL ELSE norm_mode(p_mode) END, c.failure_mode) AS mode) m
        LEFT JOIN LATERAL (
          SELECT coalesce(
                   (SELECT 'work order ' || w.wo_number || ' (' || w.status || ')' FROM work_orders w
                     WHERE w.asset_id = a.asset_id AND w.status <> 'CLOSED' ORDER BY w.opened_at DESC LIMIT 1),
                   (SELECT 'a work order waiting for supervisor approval in ' || s2.case_id FROM service_cases s2
                     WHERE s2.asset_id = a.asset_id AND s2.request_type = 'supervisor_approval' AND s2.status = 'OPEN' LIMIT 1)) AS open_wo
        ) ow ON TRUE
    ) x
    LEFT JOIN failure_modes fm ON fm.asset_type = a.asset_type AND fm.failure_mode = x.mode
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_work_order_fn(p_token TEXT, p_asset TEXT, p_mode TEXT, p_note TEXT)
RETURNS TABLE (operator_id VARCHAR, action_type VARCHAR, target_key TEXT, asset_id VARCHAR, failure_mode VARCHAR, note TEXT,
               priority VARCHAR, estimate_usd NUMERIC, needs_approval BOOLEAN, outcome VARCHAR, reason_code VARCHAR, reason_text TEXT,
               summary TEXT) AS $$
  SELECT so.staff_id, 'WORK_ORDER'::varchar, work_order_key(p_asset, p_mode), e.asset_id, e.failure_mode,
         left(nullif(trim(coalesce(p_note, '')), ''), 2000), e.priority, e.estimate_usd, coalesce(e.needs_approval, FALSE),
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary
    FROM session_operator(p_token) so
    CROSS JOIN LATERAL work_order_eval(so.site_id, so.spend_limit, p_asset, p_mode, p_note) e
   WHERE so.staff_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.operator_id = so.staff_id AND pa.action_type = 'WORK_ORDER'
                        AND pa.target_key = work_order_key(p_asset, p_mode) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM action_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_work_order_result(p_token TEXT, p_asset TEXT, p_mode TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, needs_supervisor_approval TEXT, estimate_usd TEXT, priority VARCHAR, reason_code VARCHAR,
               reason_text TEXT, summary TEXT, expires_at TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN CASE WHEN pa.needs_approval THEN 'yes' ELSE 'no' END END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN usd(pa.estimate_usd) END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.priority END,
         CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN so.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN pa.outcome = 'PROPOSED' AND pa.needs_approval THEN 'Nothing is created yet. Reply yes within 15 minutes to send it to Production Engineering for approval.'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing is created yet. Reply yes within 15 minutes to create the work order.'
              ELSE pa.reason_text END,
         pa.summary, CASE WHEN pa.outcome = 'PROPOSED' THEN dt(pa.expires_at) END
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.operator_id = so.staff_id AND p.action_type = 'WORK_ORDER'
                          AND p.target_key = work_order_key(p_asset, p_mode)
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- CONFIRM (step 2): re-checks EVERY rule; returns the action_events row only when still allowed. An estimate above the
-- operator's limit becomes a SUPERVISOR_APPROVAL event (-> Production Engineering case).
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, operator_id VARCHAR, action_type VARCHAR, asset_id VARCHAR,
               failure_mode VARCHAR, priority VARCHAR, estimate_usd NUMERIC, summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  so RECORD; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev action_events; we RECORD;
  v_id BIGINT; v_reference TEXT; v_type TEXT; v_outcome TEXT; v_text TEXT;
BEGIN
  SELECT * INTO so FROM session_operator(p_token) s;
  IF so.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.operator_id = so.staff_id;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (operator_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (so.staff_id, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal. Nothing was done.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM action_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (operator_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (so.staff_id, v_ref, 'ALREADY_DONE', 'This was already confirmed earlier (reference ' || ev.reference || '). Nothing new was done.',
              ev.reference, ev.summary);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (operator_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (so.staff_id, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (operator_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (so.staff_id, v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was done. I can propose it again.', pa.summary);
    RETURN;
  END IF;
  SELECT * INTO we FROM work_order_eval(so.site_id, so.spend_limit, pa.asset_id, pa.failure_mode, pa.note) x;
  IF NOT we.ok THEN
    INSERT INTO confirm_attempts (operator_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (so.staff_id, v_ref, 'BLOCKED', we.reason_code, we.reason_text, pa.summary);
    RETURN;
  END IF;
  IF we.needs_approval THEN
    v_id := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
    v_reference := 'MRE-CASE-' || lpad(v_id::text, 6, '0');
    v_type := 'SUPERVISOR_APPROVAL'; v_outcome := 'SUPERVISOR_APPROVAL';
    v_text := 'Above your ' || usd(so.spend_limit) || ' limit, so no work order was created yet: case ' || v_reference
              || ' is with Production Engineering, who will approve or reject the budget (reply due within 4 hours).';
  ELSE
    v_reference := 'MRE-WO-' || nextval('wo_seq');
    v_type := 'WORK_ORDER'; v_outcome := 'EXECUTED';
    v_text := 'Work order created, ' || we.priority || ', scheduled ' || wday(we.scheduled_date) || ' ' || d(we.scheduled_date) || '.';
  END IF;
  INSERT INTO confirm_attempts (operator_id, proposal_ref, outcome, reason_text, reference, summary)
    VALUES (so.staff_id, v_ref, v_outcome, v_text, v_reference, we.summary);
  RETURN QUERY SELECT nextval(pg_get_serial_sequence('action_events', 'event_id')), v_reference::varchar, pa.proposal_id,
                      so.staff_id::varchar, v_type::varchar, we.asset_id, we.failure_mode, we.priority, we.estimate_usd, we.summary;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, work_order VARCHAR, case_id VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         CASE WHEN ca.outcome <> 'SUPERVISOR_APPROVAL' THEN ca.reference END,
         CASE WHEN ca.outcome = 'SUPERVISOR_APPROVAL' THEN ca.reference END,
         CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN so.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that proposal. Nothing was done.'
              ELSE ca.reason_text END,
         ca.summary
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN LATERAL (SELECT a.* FROM confirm_attempts a
                        WHERE a.operator_id = so.staff_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) ca ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded row that creates a work order for a proposal (chat confirm, or a supervisor's approval with a budget <= the
-- estimate). Same checks every time: asset operational, no open work order, budget valid, proposal not executed already.
CREATE OR REPLACE FUNCTION work_order_exec_row(p_proposal TEXT, p_budget NUMERIC, p_actor TEXT, p_case TEXT, p_wo TEXT)
RETURNS TABLE (wo_number VARCHAR, asset_id VARCHAR, wo_type VARCHAR, failure_mode VARCHAR, symptom TEXT, priority VARCHAR, status VARCHAR,
               crew VARCHAR, scheduled_date DATE, estimate_usd NUMERIC, approved_budget_usd NUMERIC, opened_at TIMESTAMP,
               created_by VARCHAR, approved_by VARCHAR, case_id VARCHAR, proposal_id TEXT) AS $$
  SELECT coalesce(p_wo, 'MRE-WO-' || nextval('wo_seq'))::varchar, a.asset_id, 'CORRECTIVE'::varchar, pa.failure_mode,
         coalesce(pa.note || ' | ', '') || fm.label || ' | sensors at request: ' || health_line(a.asset_id),
         pa.priority, 'SCHEDULED'::varchar, st.field_crew,
         current_date + coalesce((SELECT fh.schedule_days FROM failure_horizon fh WHERE fh.wo_priority = pa.priority LIMIT 1), 3),
         pa.estimate_usd, CASE WHEN p_case IS NOT NULL THEN p_budget END, clock_timestamp()::timestamp,
         pa.operator_id, CASE WHEN p_case IS NOT NULL THEN p_actor END::varchar, p_case::varchar, pa.proposal_id
    FROM pending_actions pa
    JOIN assets a ON a.asset_id = pa.asset_id
    JOIN sites st ON st.site_id = a.site_id
    JOIN failure_modes fm ON fm.asset_type = a.asset_type AND fm.failure_mode = pa.failure_mode
   WHERE pa.proposal_id = p_proposal AND pa.action_type = 'WORK_ORDER' AND pa.outcome = 'PROPOSED'
     AND a.status = 'OPERATIONAL'
     AND NOT EXISTS (SELECT 1 FROM work_orders w WHERE w.asset_id = a.asset_id AND w.status <> 'CLOSED')
     AND p_budget > 0 AND p_budget <= pa.estimate_usd
     AND NOT EXISTS (SELECT 1 FROM work_orders w WHERE w.proposal_id = pa.proposal_id)
$$ LANGUAGE sql VOLATILE;

-- The confirmed action itself - atomic with the event row. Never an UPDATE from a tool.
CREATE OR REPLACE FUNCTION apply_action_event() RETURNS TRIGGER AS $$
DECLARE r case_routing;
BEGIN
  IF NEW.action_type = 'WORK_ORDER' THEN
    INSERT INTO work_orders (wo_number, asset_id, wo_type, failure_mode, symptom, priority, status, crew, scheduled_date, estimate_usd,
                             approved_budget_usd, opened_at, created_by, approved_by, case_id, proposal_id)
      SELECT * FROM work_order_exec_row(NEW.proposal_id, NEW.estimate_usd, NEW.operator_id, NULL, NEW.reference);
  ELSIF NEW.action_type = 'SUPERVISOR_APPROVAL' THEN
    SELECT * INTO r FROM case_routing WHERE request_type = 'supervisor_approval';
    INSERT INTO service_cases (case_no, case_id, site_id, asset_id, opened_by, request_type, summary, reference_id, requested_amount,
                               parked_action, agent_brief, sla_due_at)
      SELECT substring(NEW.reference FROM '[0-9]+$')::bigint, NEW.reference, a.site_id, NEW.asset_id, NEW.operator_id, 'supervisor_approval',
             NEW.summary, NEW.asset_id, NEW.estimate_usd, 'WORK_ORDER:' || NEW.proposal_id, NULL,
             clock_timestamp()::timestamp + r.sla_hours * INTERVAL '1 hour'
        FROM assets a WHERE a.asset_id = NEW.asset_id;
    PERFORM audit('CASE_OPENED', NEW.operator_id, NEW.reference, 'supervisor_approval ' || NEW.asset_id || ' ' || NEW.failure_mode || ' ' || usd(NEW.estimate_usd));
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_action_event AFTER INSERT ON action_events FOR EACH ROW EXECUTE FUNCTION apply_action_event();

-- Every created work order (chat confirm, supervisor approval, HSE approval): audit row.
CREATE OR REPLACE FUNCTION apply_work_order() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.proposal_id IS NOT NULL OR NEW.case_id IS NOT NULL THEN
    PERFORM audit('WO_CREATED', coalesce(NEW.approved_by, NEW.created_by), NEW.wo_number,
                  NEW.asset_id || ' ' || NEW.wo_type || ' ' || NEW.priority || coalesce(' ' || NEW.failure_mode, '') || ' est. ' || usd(NEW.estimate_usd)
                  || coalesce(' budget ' || usd(NEW.approved_budget_usd), '') || coalesce(' (approved in ' || NEW.case_id || ')', ''));
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_work_order AFTER INSERT ON work_orders FOR EACH ROW EXECUTE FUNCTION apply_work_order();

-- =====================================================================
-- ALERT LOG - severity from the SQL classification, health >= WARNING, one per asset per day (deduped)
-- =====================================================================
CREATE OR REPLACE FUNCTION alert_row(p_token TEXT, p_asset TEXT)
RETURNS TABLE (alert_id VARCHAR, asset_id VARCHAR, severity VARCHAR, failure_mode VARCHAR, message TEXT, logged_by VARCHAR) AS $$
#variable_conflict use_column
DECLARE so RECORD; v_aid TEXT; v_ref TEXT := coalesce(asset_lookup(p_asset), norm_ref(p_asset)); c RECORD; v_existing TEXT; v_id TEXT;
BEGIN
  SELECT * INTO so FROM session_operator(p_token) s;
  IF so.staff_id IS NULL THEN RETURN; END IF;
  v_aid := site_asset(so.site_id, p_asset);
  IF v_aid IS NULL THEN
    INSERT INTO alert_attempts (operator_id, asset_ref, outcome) VALUES (so.staff_id, v_ref, 'NOT_FOUND');
    RETURN;
  END IF;
  SELECT * INTO c FROM classify_asset(v_aid) x;
  IF health_rank(c.health_status) = 0 THEN
    INSERT INTO alert_attempts (operator_id, asset_ref, outcome) VALUES (so.staff_id, v_ref, 'HEALTH_NORMAL');
    RETURN;
  END IF;
  SELECT al.alert_id INTO v_existing FROM alerts al WHERE al.asset_id = v_aid AND al.logged_date = current_date;
  IF v_existing IS NOT NULL THEN
    INSERT INTO alert_attempts (operator_id, asset_ref, outcome, alert_id) VALUES (so.staff_id, v_ref, 'ALREADY_LOGGED_TODAY', v_existing);
    RETURN;
  END IF;
  v_id := 'ALR-' || lpad(nextval('alert_seq')::text, 6, '0');
  INSERT INTO alert_attempts (operator_id, asset_ref, outcome, alert_id) VALUES (so.staff_id, v_ref, 'LOGGED', v_id);
  RETURN QUERY SELECT v_id::varchar, v_aid::varchar, c.health_status::varchar, c.failure_mode,
                      c.health_status || ' - ' || v_aid || ' | ' || coalesce((SELECT fm.label FROM failure_modes fm JOIN assets a ON a.asset_type = fm.asset_type
                                                                              WHERE a.asset_id = v_aid AND fm.failure_mode = c.failure_mode), c.failure_mode)
                      || ' | ' || c.anomalies || ' | est. ' || c.days_to_failure || ' to failure | confidence ' || round(c.confidence * 100) || '%',
                      so.staff_id;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION apply_alert() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.logged_by IS NOT NULL THEN PERFORM audit('ALERT_LOGGED', NEW.logged_by, NEW.alert_id, NEW.asset_id || ' ' || NEW.severity); END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_alert AFTER INSERT ON alerts FOR EACH ROW EXECUTE FUNCTION apply_alert();

CREATE OR REPLACE FUNCTION alert_result(p_token TEXT, p_asset TEXT)
RETURNS TABLE (outcome TEXT, alert_id VARCHAR, asset_id VARCHAR, severity VARCHAR, message TEXT, logged_at TEXT, reason_code TEXT,
               reason_text TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(aa.outcome, 'NOT_FOUND') END,
         al.alert_id, al.asset_id, al.severity, al.message, dt(al.logged_at),
         CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN aa.outcome = 'LOGGED' THEN NULL ELSE coalesce(aa.outcome, 'NOT_FOUND') END,
         CASE WHEN so.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN aa.outcome = 'LOGGED' THEN 'Alert logged.'
              WHEN aa.outcome = 'ALREADY_LOGGED_TODAY' THEN 'An alert for this asset was already logged today (' || al.alert_id || ', ' || al.status
                   || '), so no duplicate was logged.'
              WHEN aa.outcome = 'HEALTH_NORMAL' THEN 'The asset is NORMAL on every sensor, so no alert was logged. A safety concern goes to HSE instead.'
              ELSE 'I could not find that asset in your region, so no alert was logged.' END
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN LATERAL (SELECT a.* FROM alert_attempts a
                        WHERE a.operator_id = so.staff_id AND a.asset_ref = coalesce(asset_lookup(p_asset), norm_ref(p_asset))
                        ORDER BY a.attempt_id DESC LIMIT 1) aa ON TRUE
    LEFT JOIN alerts al ON al.alert_id = aa.alert_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_asset TEXT, p_summary TEXT, p_brief TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, site_id VARCHAR, asset_id VARCHAR, opened_by VARCHAR, request_type VARCHAR,
               summary TEXT, reference_id VARCHAR, requested_amount NUMERIC, parked_action VARCHAR, agent_brief TEXT,
               sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE so RECORD; v_type TEXT := norm_request_type(p_type); v_aref TEXT := coalesce(asset_lookup(p_asset), norm_ref(p_asset));
        r case_routing; v_aid TEXT; v_parked TEXT; v_refid TEXT; v_existing TEXT; v_no BIGINT; v_case TEXT;
BEGIN
  SELECT * INTO so FROM session_operator(p_token) s;
  IF so.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM case_routing cr WHERE cr.request_type = v_type AND cr.operator_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (operator_id, request_type, asset_ref, outcome, reason_code) VALUES (so.staff_id, v_type, v_aref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  v_aid := site_asset(so.site_id, p_asset);
  IF v_aid IS NULL THEN
    INSERT INTO case_requests (operator_id, request_type, asset_ref, outcome, reason_code) VALUES (so.staff_id, v_type, v_aref, 'BLOCKED', 'NOT_FOUND');
    RETURN;
  END IF;
  v_refid := v_aid;
  IF v_type = 'shut_in' THEN v_parked := 'SHUT_IN:' || v_aid;
  ELSIF v_type = 'safety_signal' THEN v_parked := 'SAFETY_WO:' || v_aid;
  ELSIF v_type = 'alert_closure' THEN
    SELECT al.alert_id INTO v_refid FROM alerts al WHERE al.asset_id = v_aid AND al.status <> 'CLOSED' ORDER BY al.logged_at DESC LIMIT 1;
    IF v_refid IS NULL THEN
      INSERT INTO case_requests (operator_id, request_type, asset_ref, outcome, reason_code) VALUES (so.staff_id, v_type, v_aref, 'BLOCKED', 'NO_OPEN_ALERT');
      RETURN;
    END IF;
    v_parked := 'ALERT_CLOSE:' || v_refid;
  END IF;
  SELECT c.case_id INTO v_existing FROM service_cases c
   WHERE c.asset_id = v_aid AND c.request_type = v_type AND c.status = 'OPEN' ORDER BY c.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (operator_id, request_type, asset_ref, outcome, case_id) VALUES (so.staff_id, v_type, v_aref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'MRE-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (operator_id, request_type, asset_ref, outcome, case_id) VALUES (so.staff_id, v_type, v_aref, 'OPENED', v_case);
  PERFORM audit('CASE_OPENED', so.staff_id, v_case, v_type || ' for ' || v_aid);
  RETURN QUERY SELECT v_no, v_case::varchar, so.site_id, v_aid::varchar, so.staff_id, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_refid::varchar, NULL::numeric,
                      v_parked::varchar, left(nullif(trim(p_brief), ''), 4000),
                      clock_timestamp()::timestamp + r.sla_hours * INTERVAL '1 hour';
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT, p_asset TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due TEXT, reason_code VARCHAR,
               reason_text TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.team, rt.sla_text, dt(s.sla_due_at),
         CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN so.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN cr.outcome = 'OPENED' THEN 'The case is open. A person on the ' || rt.team || ' team will review it and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'There is already an open ' || rt.label || ' case for this asset, so no new case was opened. The ' || rt.team || ' team is on it.'
              WHEN cr.reason_code = 'NOT_FOUND' THEN 'I could not find that asset in your region, so no case was opened.'
              WHEN cr.reason_code = 'NO_OPEN_ALERT' THEN 'There is no open alert on that asset, so there is nothing to close.'
              ELSE 'That is not a request I can open a case for here. A person can help with a shut-in or emergency shutdown, a safety signal, a sensor threshold change, or closing an alert.' END
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.operator_id = so.staff_id AND q.request_type = norm_request_type(p_type)
                          AND q.asset_ref = coalesce(asset_lookup(p_asset), norm_ref(p_asset))
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
CREATE OR REPLACE FUNCTION parked_kind(p TEXT) RETURNS TEXT AS $$ SELECT split_part(coalesce(p, ''), ':', 1) $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION parked_ref(p TEXT) RETURNS TEXT AS $$
  SELECT substr(coalesce(p, ''), length(split_part(coalesce(p, ''), ':', 1)) + 2)
$$ LANGUAGE sql IMMUTABLE;

-- The largest budget a reviewer may approve (NULL = the case carries no amount): never more than the estimate.
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN parked_kind(s.parked_action) = 'WORK_ORDER'
                THEN (SELECT pa.estimate_usd FROM pending_actions pa WHERE pa.proposal_id = parked_ref(s.parked_action))
              ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Can the parked action still run? (NULL reason = yes)
CREATE OR REPLACE FUNCTION parked_not_ready(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE parked_kind(s.parked_action)
           WHEN 'WORK_ORDER' THEN
             CASE WHEN a.status <> 'OPERATIONAL' THEN s.asset_id || ' is ' || a.status || ', so no work order can be created now.'
                  WHEN EXISTS (SELECT 1 FROM work_orders w WHERE w.asset_id = s.asset_id AND w.status <> 'CLOSED')
                    THEN s.asset_id || ' already has an open work order.' END
           WHEN 'SHUT_IN' THEN CASE WHEN a.status = 'SHUT_IN' THEN s.asset_id || ' is already SHUT_IN.' END
           WHEN 'SAFETY_WO' THEN
             CASE WHEN EXISTS (SELECT 1 FROM work_orders w WHERE w.asset_id = s.asset_id AND w.wo_type = 'SAFETY_INSPECTION' AND w.status <> 'CLOSED')
                    THEN s.asset_id || ' already has an open safety-inspection work order.' END
           WHEN 'ALERT_CLOSE' THEN
             CASE WHEN (SELECT al.status FROM alerts al WHERE al.alert_id = parked_ref(s.parked_action)) = 'CLOSED'
                    THEN 'Alert ' || parked_ref(s.parked_action) || ' is already closed.' END
         END
    FROM service_cases s JOIN assets a ON a.asset_id = s.asset_id
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL.
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT 'Asset ' || a.asset_id || ' (' || type_label(a.asset_type) || ', ' || st.site_name || ') is ' || a.status
         || '; sensor health ' || c.health_status || coalesce(' (' || c.worst_sensor || ' -> ' || c.failure_mode || ', confidence '
         || c.confidence || ', ' || c.days_to_failure || ' to failure)', '') || ': ' || c.anomalies
         || '; open work orders: ' || coalesce((SELECT string_agg(w.wo_number || ' ' || w.wo_type || ' ' || w.status, ', ')
                                                 FROM work_orders w WHERE w.asset_id = a.asset_id AND w.status <> 'CLOSED'), 'none')
         || '; open alerts: ' || coalesce((SELECT string_agg(al.alert_id || ' ' || al.severity || ' ' || al.status, ', ')
                                             FROM alerts al WHERE al.asset_id = a.asset_id AND al.status <> 'CLOSED'), 'none')
         || '; closed work orders on this asset in 12 months: ' || (SELECT count(*) FROM work_orders w WHERE w.asset_id = a.asset_id
                                                                     AND w.status = 'CLOSED' AND w.closed_at > clock_timestamp() - INTERVAL '365 days')
         || CASE parked_kind(s.parked_action)
              WHEN 'WORK_ORDER' THEN '; requested work: ' || pa.priority || ' ' || fm.label || ' - ' || fm.recommended_action || ' Estimate '
                   || usd(pa.estimate_usd) || ' (typical parts: ' || fm.typical_parts || '; about ' || fm.est_downtime_hours || ' h downtime); '
                   || 'operator limit ' || usd((SELECT o.spend_limit FROM operators o WHERE o.staff_id = s.opened_by))
                   || '; approving creates the work order with the approved budget'
              WHEN 'SHUT_IN' THEN '; approving records the shut-in: the asset goes SHUT_IN (the field crew executes it)'
              WHEN 'SAFETY_WO' THEN '; field notes on this asset in 24 h: ' || coalesce((SELECT string_agg('"' || left(fn.note_text, 160) || '" (safety '
                   || fn.safety_source || ')', '; ') FROM field_notes fn WHERE fn.asset_id = a.asset_id
                   AND fn.created_at > clock_timestamp() - INTERVAL '24 hours'), 'none in the system')
                   || '; approving creates an EMERGENCY safety-inspection work order for the ' || st.field_crew
              WHEN 'ALERT_CLOSE' THEN '; alert ' || parked_ref(s.parked_action) || ': ' || coalesce((SELECT al.message || ' (' || al.status || ', logged '
                   || dt(al.logged_at) || ')' FROM alerts al WHERE al.alert_id = parked_ref(s.parked_action)), 'not found')
                   || '; approving closes the alert'
              ELSE CASE WHEN s.request_type = 'threshold_change' THEN '; current thresholds: ' || (SELECT string_agg(t.label || ' '
                   || concat_ws(' / ', 'warn < ' || num_txt(t.warn_low), 'crit < ' || num_txt(t.crit_low), 'warn > ' || num_txt(t.warn_high),
                   'crit > ' || num_txt(t.crit_high)) || ' ' || t.unit, '; ' ORDER BY t.sort_order) FROM sensor_thresholds t)
                   || '; approving records the decision only - engineering updates the threshold table' ELSE '' END
            END
         || coalesce(' (not possible right now: ' || parked_not_ready(s.case_id) || ')', '') || '.'
    FROM service_cases s
    JOIN assets a ON a.asset_id = s.asset_id
    JOIN sites st ON st.site_id = a.site_id
    LEFT JOIN LATERAL classify_asset(a.asset_id) c ON TRUE
    LEFT JOIN pending_actions pa ON parked_kind(s.parked_action) = 'WORK_ORDER' AND pa.proposal_id = parked_ref(s.parked_action)
    LEFT JOIN failure_modes fm ON fm.asset_type = a.asset_type AND fm.failure_mode = pa.failure_mode
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, asset_id VARCHAR, region VARCHAR, opened_at TEXT,
               age_hours INTEGER, reply_due TEXT, sla_status TEXT, requested_budget_usd TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.asset_id, q.site_name, q.opened_at, q.age_hours, q.reply_due, q.sla_status, usd(q.requested_amount)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, r.label, s.asset_id, st.site_name, dt(s.created_at) AS opened_at,
             (extract(epoch FROM clock_timestamp()::timestamp - s.created_at) / 3600)::int AS age_hours, dt(s.sla_due_at) AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at < clock_timestamp() + INTERVAL '1 hour' THEN 'DUE_SOON'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.sla_due_at
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type JOIN sites st ON st.site_id = s.site_id
       WHERE sr.reviewer_id IS NOT NULL AND r.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, asset_id VARCHAR, region VARCHAR, opened_at TEXT,
               reply_due TEXT, operator_statement TEXT, agent_brief TEXT, requested_budget_usd TEXT, max_approvable_usd TEXT,
               your_budget_authority_usd TEXT, facts TEXT, options TEXT, decided_at TEXT, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.label, s.status, s.asset_id, st.site_name, dt(s.created_at), dt(s.sla_due_at), s.summary,
         CASE WHEN s.agent_brief IS NOT NULL THEN 'AI-prepared, not verified: ' || s.agent_brief END,
         usd(s.requested_amount), usd(case_eligible_max(s.case_id)),
         CASE WHEN s.case_id IS NOT NULL AND s.requested_amount IS NOT NULL THEN coalesce(usd(sr.approval_limit), 'no limit') END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.requested_amount IS NOT NULL THEN 'APPROVE (a budget up to ' || usd(case_eligible_max(s.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN '; above your ' || usd(sr.approval_limit) || ' authority it needs a senior supervisor' ELSE '' END
                   || ') or REJECT, with an internal note and a message for the operator.'
              WHEN parked_kind(s.parked_action) = 'SHUT_IN' THEN 'APPROVE (records the shut-in: asset SHUT_IN) or REJECT, with an internal note and a message for the operator.'
              WHEN parked_kind(s.parked_action) = 'SAFETY_WO' THEN 'APPROVE (creates an EMERGENCY safety-inspection work order) or REJECT (no action), with an internal note and a message for the operator.'
              WHEN parked_kind(s.parked_action) = 'ALERT_CLOSE' THEN 'APPROVE (closes the alert) or REJECT, with an internal note and a message for the operator.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the operator.' END,
         dt(s.decided_at),
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT cr.request_type FROM case_routing cr WHERE cr.team = sr.team)   -- another team's case is invisible
    LEFT JOIN case_routing r ON r.request_type = s.request_type
    LEFT JOIN sites st ON st.site_id = s.site_id
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; r case_routing; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_amt_txt TEXT := norm_amount(p_amount); v_msg TEXT; v_nr TEXT;
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
    v_amt := CASE WHEN v_amt_txt = '' THEN v_max WHEN v_amt_txt ~ '^-?[0-9]{1,9}(\.[0-9]{1,2})?$' THEN v_amt_txt::numeric END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The approved budget must be more than $0 and at most ' || usd(v_max)
                || ' (the estimate) for this case.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', 'A budget of ' || usd(v_amt) || ' is above your approval authority of '
                || usd(rv.approval_limit) || '. The case stays open and needs a senior supervisor.');
      RETURN;
    END IF;
  END IF;
  IF v_dec = 'APPROVE' THEN
    v_nr := parked_not_ready(s.case_id);
    IF v_nr IS NOT NULL THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_READY', 'The approved action cannot run right now: ' || v_nr || ' The case stays open.');
      RETURN;
    END IF;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'The ' || r.label || ' was approved' || coalesce(' with a budget of ' || usd(v_amt), '') || '.'
                  ELSE 'After review, the ' || r.label || ' was not approved. The ' || r.team || ' team will follow up.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, CASE WHEN v_dec = 'APPROVE' THEN v_amt END,
                      left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_budget_usd TEXT, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION','NOT_READY')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN usd(rd.approved_amount) END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND' AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'Work order created: ' || w.wo_number || ' - ' || w.wo_type || ' ' || w.priority || ' for ' || w.asset_id
                                 || coalesce(', budget ' || usd(w.approved_budget_usd), '') || ', ' || w.crew || ', scheduled ' || d(w.scheduled_date) || '.'
                            FROM work_orders w WHERE w.case_id = s.case_id),
                         (SELECT 'Shut-in recorded (' || ae.reference || '): ' || ae.asset_id || ' is SHUT_IN.'
                            FROM asset_events ae WHERE ae.case_id = s.case_id),
                         (SELECT 'Alert ' || ev.alert_id || ' closed.' FROM alert_events ev WHERE ev.case_id = s.case_id),
                         'Case approved; no automatic action - the ' || r.team || ' team completes it.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN case_routing r ON r.request_type = s.request_type
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded rows for the other parked actions (only from an approved case, only while still possible).
CREATE OR REPLACE FUNCTION shut_in_exec_row(p_asset TEXT, p_actor TEXT, p_case TEXT)
RETURNS TABLE (reference VARCHAR, asset_id VARCHAR, event_type VARCHAR, actor VARCHAR, case_id VARCHAR) AS $$
  SELECT ('MRE-SHT-' || lpad(nextval('sht_seq')::text, 6, '0'))::varchar, a.asset_id, 'SHUT_IN'::varchar, p_actor::varchar, p_case::varchar
    FROM assets a
   WHERE a.asset_id = p_asset AND a.status <> 'SHUT_IN'
     AND NOT EXISTS (SELECT 1 FROM asset_events ae WHERE ae.case_id = p_case)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION safety_wo_exec_row(p_asset TEXT, p_actor TEXT, p_case TEXT)
RETURNS TABLE (wo_number VARCHAR, asset_id VARCHAR, wo_type VARCHAR, failure_mode VARCHAR, symptom TEXT, priority VARCHAR, status VARCHAR,
               crew VARCHAR, scheduled_date DATE, estimate_usd NUMERIC, approved_budget_usd NUMERIC, opened_at TIMESTAMP,
               created_by VARCHAR, approved_by VARCHAR, case_id VARCHAR, proposal_id TEXT) AS $$
  SELECT ('MRE-WO-' || nextval('wo_seq'))::varchar, a.asset_id, 'SAFETY_INSPECTION'::varchar, NULL::varchar,
         'HSE-approved safety inspection: ' || left(s.summary, 1500), 'EMERGENCY'::varchar, 'SCHEDULED'::varchar, st.field_crew,
         current_date, 0::numeric, NULL::numeric, clock_timestamp()::timestamp, s.opened_by, p_actor::varchar, p_case::varchar, NULL::text
    FROM assets a JOIN sites st ON st.site_id = a.site_id JOIN service_cases s ON s.case_id = p_case
   WHERE a.asset_id = p_asset
     AND NOT EXISTS (SELECT 1 FROM work_orders w WHERE w.asset_id = a.asset_id AND w.wo_type = 'SAFETY_INSPECTION' AND w.status <> 'CLOSED')
     AND NOT EXISTS (SELECT 1 FROM work_orders w WHERE w.case_id = p_case)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION alert_close_row(p_alert TEXT, p_actor TEXT, p_case TEXT)
RETURNS TABLE (alert_id VARCHAR, event_type VARCHAR, actor VARCHAR, case_id VARCHAR) AS $$
  SELECT al.alert_id, 'CLOSE'::varchar, p_actor::varchar, p_case::varchar
    FROM alerts al WHERE al.alert_id = p_alert AND al.status <> 'CLOSED'
     AND NOT EXISTS (SELECT 1 FROM alert_events ev WHERE ev.case_id = p_case)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION apply_asset_event() RETURNS TRIGGER AS $$
BEGIN
  UPDATE assets SET status = 'SHUT_IN' WHERE asset_id = NEW.asset_id;
  PERFORM audit('SHUT_IN', NEW.actor, NEW.reference, NEW.asset_id || ' (' || NEW.case_id || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_asset_event AFTER INSERT ON asset_events FOR EACH ROW EXECUTE FUNCTION apply_asset_event();

CREATE OR REPLACE FUNCTION apply_alert_event() RETURNS TRIGGER AS $$
BEGIN
  UPDATE alerts SET status = 'CLOSED', closed_at = clock_timestamp() WHERE alert_id = NEW.alert_id;
  PERFORM audit('ALERT_CLOSED', NEW.actor, NEW.alert_id, 'closed in ' || NEW.case_id);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_alert_event AFTER INSERT ON alert_events FOR EACH ROW EXECUTE FUNCTION apply_alert_event();

-- The decision event: case status + operator message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := parked_kind(s.parked_action);
  v_ref := parked_ref(s.parked_action);
  IF NEW.decision = 'APPROVE' THEN
    IF v_kind = 'WORK_ORDER' THEN
      INSERT INTO work_orders (wo_number, asset_id, wo_type, failure_mode, symptom, priority, status, crew, scheduled_date, estimate_usd,
                               approved_budget_usd, opened_at, created_by, approved_by, case_id, proposal_id)
        SELECT * FROM work_order_exec_row(v_ref, NEW.approved_amount, NEW.reviewer_id, NEW.case_id, NULL);
      IF FOUND THEN v_done := 'work order for ' || s.asset_id || ' budget ' || usd(NEW.approved_amount); END IF;
    ELSIF v_kind = 'SHUT_IN' THEN
      INSERT INTO asset_events (reference, asset_id, event_type, actor, case_id) SELECT * FROM shut_in_exec_row(v_ref, NEW.reviewer_id, NEW.case_id);
      IF FOUND THEN v_done := v_ref || ' shut in'; END IF;
    ELSIF v_kind = 'SAFETY_WO' THEN
      INSERT INTO work_orders (wo_number, asset_id, wo_type, failure_mode, symptom, priority, status, crew, scheduled_date, estimate_usd,
                               approved_budget_usd, opened_at, created_by, approved_by, case_id, proposal_id)
        SELECT * FROM safety_wo_exec_row(v_ref, NEW.reviewer_id, NEW.case_id);
      IF FOUND THEN v_done := 'safety inspection work order for ' || v_ref; END IF;
    ELSIF v_kind = 'ALERT_CLOSE' THEN
      INSERT INTO alert_events (alert_id, event_type, actor, case_id) SELECT * FROM alert_close_row(v_ref, NEW.reviewer_id, NEW.case_id);
      IF FOUND THEN v_done := 'alert ' || v_ref || ' closed'; END IF;
    END IF;
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id, NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- =====================================================================
-- EMAIL - the asset summary, only for an asset in the operator's region with an executed action (a work order created
-- here, an alert logged by the control room, a field note or a decided case in the last 7 days). SQL builds the text from
-- what actually happened; it goes to the EMAIL_TO control-room mailbox.
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_asset TEXT)
RETURNS TABLE (code TEXT, operator_id VARCHAR, asset_id VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN so.staff_id IS NULL THEN 'SESSION_INVALID' WHEN sa.aid IS NULL THEN 'NOT_FOUND'
              WHEN NOT (EXISTS (SELECT 1 FROM work_orders w WHERE w.asset_id = sa.aid AND (w.proposal_id IS NOT NULL OR w.case_id IS NOT NULL)
                                   AND w.opened_at > clock_timestamp() - INTERVAL '7 days')
                     OR EXISTS (SELECT 1 FROM alerts al WHERE al.asset_id = sa.aid AND al.logged_by IS NOT NULL
                                   AND al.logged_at > clock_timestamp() - INTERVAL '7 days')
                     OR EXISTS (SELECT 1 FROM field_notes fn WHERE fn.asset_id = sa.aid AND fn.created_at > clock_timestamp() - INTERVAL '7 days')
                     OR EXISTS (SELECT 1 FROM service_cases c WHERE c.asset_id = sa.aid AND c.status <> 'OPEN'
                                   AND c.decided_at > clock_timestamp() - INTERVAL '7 days'))
                THEN 'NOTHING_TO_SEND'
              ELSE 'SEND_OK' END,
         so.staff_id, sa.aid::varchar,
         'Mesa Ridge asset summary - ' || coalesce(sa.aid, '') || ' (' || coalesce(type_label(a.asset_type), '') || ')',
         'Mesa Ridge Energy - control room, ' || st.site_name || ' (' || st.basin || ')' || chr(10) || chr(10)
         || 'Asset ' || sa.aid || ' (' || type_label(a.asset_type) || ', ' || a.description || ') status: ' || a.status || chr(10)
         || 'Sensor health: ' || health_line(sa.aid) || chr(10)
         || chr(10) || 'Work orders:' || chr(10)
         || coalesce((SELECT string_agg('- ' || w.wo_number || ': ' || w.wo_type || ' ' || w.priority || coalesce(' ' || w.failure_mode, '') || ', '
                                        || w.status || ', ' || w.crew || ', scheduled ' || coalesce(d(w.scheduled_date), '-')
                                        || coalesce(', budget ' || usd(w.approved_budget_usd), ', estimate ' || usd(w.estimate_usd))
                                        || coalesce(' - approved in ' || w.case_id, ''), chr(10) ORDER BY w.opened_at)
                        FROM work_orders w WHERE w.asset_id = sa.aid AND w.status <> 'CLOSED'), '- none open')
         || chr(10) || chr(10) || 'Alerts:' || chr(10)
         || coalesce((SELECT string_agg('- ' || al.alert_id || ' ' || al.severity || ' (' || al.status || ', ' || dt(al.logged_at) || '): ' || al.message,
                                        chr(10) ORDER BY al.logged_at)
                        FROM alerts al WHERE al.asset_id = sa.aid AND (al.status <> 'CLOSED' OR al.logged_at > clock_timestamp() - INTERVAL '7 days')), '- none')
         || chr(10) || chr(10) || 'Cases:' || chr(10)
         || coalesce((SELECT string_agg('- ' || c.case_id || ' ' || r.label || ': ' || c.status
                                        || CASE WHEN c.status = 'OPEN' THEN ' (with ' || r.team || ', reply due ' || dt(c.sla_due_at) || ')'
                                                ELSE coalesce(' - ' || c.customer_message, '') END, chr(10) ORDER BY c.case_no)
                        FROM service_cases c JOIN case_routing r ON r.request_type = c.request_type
                       WHERE c.asset_id = sa.aid AND (c.status = 'OPEN' OR c.decided_at > clock_timestamp() - INTERVAL '7 days')), '- none')
         || chr(10) || chr(10)
         || 'Shut-ins, safety signals, threshold changes and alert closures stay with Production Engineering and HSE. This summary '
         || 'lists what was recorded in the asset system; it is not a safety clearance.' || chr(10) || chr(10)
         || 'Mesa Ridge Asset Health Assistant (an AI assistant), on behalf of ' || so.display_name
    FROM (SELECT * FROM session_operator(p_token)) so
    LEFT JOIN LATERAL (SELECT site_asset(so.site_id, p_asset) AS aid) sa ON TRUE
    LEFT JOIN assets a ON a.asset_id = sa.aid
    LEFT JOIN sites st ON st.site_id = so.site_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_asset TEXT)
RETURNS TABLE (asset_id VARCHAR, operator_id VARCHAR, subject TEXT) AS $$
  SELECT e.asset_id, e.operator_id, e.subject FROM email_source(p_token, p_asset) e WHERE e.code = 'SEND_OK'
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_payload(p_token TEXT, p_asset TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, asset_id VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.code = 'SEND_OK' THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.code = 'SEND_OK' THEN NULL ELSE e.code END,
         CASE e.code WHEN 'SEND_OK' THEN 'The asset summary email is on its way to the control-room mailbox.'
                     WHEN 'SESSION_INVALID' THEN 'Please verify again (staff ID and code).'
                     WHEN 'NOT_FOUND' THEN 'I could not find that asset in your region, so no email was sent.'
                     ELSE 'Nothing has been done on this asset yet (no work order, alert, field note or decided case), so no email was sent.' END,
         CASE WHEN e.code = 'SEND_OK' THEN e.asset_id END,
         CASE WHEN e.code = 'SEND_OK' THEN e.subject ELSE 'Mesa Ridge asset summary - not sent' END,
         CASE WHEN e.code = 'SEND_OK' THEN e.body ELSE 'No email was sent.' END
    FROM email_source(p_token, p_asset) e
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

CREATE OR REPLACE FUNCTION ref_field_note_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM field_note_guide g
          UNION ALL                                 -- failure-mode codes: failure_modes is the source of truth
          SELECT 'FAILURE_MODE', fm.failure_mode::text,
                 'What the code means per asset type: '
                 || string_agg(type_label(fm.asset_type::text) || ' - ' || fm.label::text, '; ' ORDER BY fm.asset_type) || '.',
                 1000
            FROM failure_modes fm GROUP BY fm.failure_mode
          UNION ALL                                 -- who decides a safety signal: case_routing is the source of truth
          SELECT 'WHO_DECIDES', c.label::text, c.team::text || ': ' || c.sla_text::text, 2000
            FROM case_routing c WHERE c.request_type = 'safety_signal') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['SAFETY_SIGN','NOT_SAFETY','CREW_CHECK','FAILURE_MODE','SHORTHAND','WHO_DECIDES','RULE'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_failure_matching(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM failure_match_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['MATCH_LEVEL','EXAMPLE','TERM','RULE'], g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_handover_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM handover_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['SECTION','STATUS','STANDARD_LINE','RULE'], g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
