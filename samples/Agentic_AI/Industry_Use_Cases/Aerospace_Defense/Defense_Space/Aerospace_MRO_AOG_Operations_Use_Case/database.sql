-- Northvale Aero Services - Aerospace MRO AOG Operations (GOVERNED) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: aerospace_mro_governed
-- Load:  createdb aerospace_mro_governed  &&  psql -d aerospace_mro_governed -f database.sql
--
-- =====================================================================
-- Fictional US MRO provider "Northvale Aero Services", assistant "Northvale MRO Ops Assistant".
-- Fictional aircraft types (NV-450 tactical airlifter, NV-200 regional jet, ...), fictional bases (Granite Mesa,
-- Harbor Point), obviously fictional tails (N0xxNV - a real US registration never starts with 0). ATA chapters are
-- the public industry standard.
-- The rules live HERE, not in any prompt:
--   * session_controller() / session_reviewer()  identity: every tool is scoped by a session token; controller and
--                                                reviewer tokens are not interchangeable (role checked)
--   * verify_*_fn()                              staff id + one-time code -> session; 5 failures / 15 min -> LOCKED
--   * base_* / work_orders_at() / ...            scoped reads - only the controller's base; another base -> NOT_FOUND
--   * part_order_eval()                          part fits the aircraft, WO open at the base, quantity, priority,
--                                                delivery from lead time, spend vs the controller's limit
--   * dispatch_eval()                            technician certified + type-rated, same base, AVAILABLE, WO open
--   * propose_*_fn() / confirm_action_fn()       two-step: PROPOSED/BLOCKED with 15-minute expiry; confirm re-checks;
--                                                spend above the limit -> a maintenance-manager case instead of an order
--   * open_case_row()                            human-owned requests routed by case_routing (team + SLA hours)
--   * decide_case_row() + trg_review_decision    the reviewer loop: role/team/authority/quantity checks, then the parked
--                                                action (part order / return to service) runs through guarded rows
--   * email_log_row()                            ops email only for a tail at the base with an executed action
--   * ref_ata_chapters() / ref_repeat_defect_criteria() / ref_handover_guide()
--                                                the A2A agents' ONLY database access: read-only reference tables
--                                                (ATA chapter guide + catalogue part families, repeat-defect
--                                                criteria, shift-handover guide) with no staff, technician, case,
--                                                session, tail or work-order data; one optional lookup term, never
--                                                an identity. The same-chapter 30-day count stays in tail_history().
-- The AI agents get no identity at all (no staff or technician names/ids, no tokens); they read reference tables only.
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

DROP TABLE IF EXISTS ata_chapter_guide, repeat_defect_guide, handover_guide CASCADE;
DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, case_requests, service_cases, fleet_events,
  confirm_attempts, action_events, pending_actions, part_orders, aog_incidents, part_stock, parts, work_orders, technicians,
  aircraft, verify_attempts, sessions, reviewers, controllers, case_routing, aircraft_types, bases CASCADE;
DROP SEQUENCE IF EXISTS po_seq, dsp_seq, rts_seq;
CREATE SEQUENCE po_seq START 101;                 -- part orders PO-2026-0101 ... (reset in seed_data.sql)
CREATE SEQUENCE dsp_seq START 101;                -- dispatch references NVA-DSP-000101 ...
CREATE SEQUENCE rts_seq START 101;                -- return-to-service references NVA-RTS-000101 ...

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE bases (
  base_id     VARCHAR(4) PRIMARY KEY,           -- GM
  base_name   VARCHAR(60) NOT NULL,             -- Granite Mesa
  ops_phone   VARCHAR(20) NOT NULL              -- maintenance control desk (555-01xx)
);

CREATE TABLE aircraft_types (
  type_code   VARCHAR(10) PRIMARY KEY,          -- NV-450
  type_name   VARCHAR(60) NOT NULL,             -- NV-450 tactical airlifter
  platform    VARCHAR(12) NOT NULL CHECK (platform IN ('Commercial','Defense'))
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type        VARCHAR(30) PRIMARY KEY,
  label               VARCHAR(50) NOT NULL,     -- controller-facing name
  team                VARCHAR(40) NOT NULL,
  sla_hours           INTEGER NOT NULL,
  sla_text            VARCHAR(160) NOT NULL,
  controller_openable BOOLEAN NOT NULL DEFAULT TRUE   -- spend_approval is opened only by confirm_action
);

-- ---------------------------------------------------------------------
-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO staff, technician, reviewer, case, session, tail, work-order or contact
-- data, ever. Lists that already live in another table are NOT copied here: ref_ata_chapters() reads the catalogue
-- part families from parts, ref_repeat_defect_criteria() reads who decides from case_routing (one source of truth).
-- The same-chapter count in the last 30 days stays computed in SQL (tail_history.same_ata_last_30_days).
-- ---------------------------------------------------------------------
CREATE TABLE ata_chapter_guide (                 -- fault_triage_agent: ATA chapters, symptoms, shorthand, rules
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('ATA_CHAPTER', 'SYMPTOM', 'SHORTHAND', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- ATA 29 - Hydraulic power / HYD 2
  meaning     VARCHAR(400) NOT NULL,             -- scope + certification + Northvale triage note
  UNIQUE (section, term)
);

CREATE TABLE repeat_defect_guide (               -- repeat_defect_agent: flags + standard notes, window, system match
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('FLAG', 'WINDOW', 'SAME_SYSTEM', 'DIFFERENT_SYSTEM', 'TERM', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- REPEAT / 30 days / PIREP
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

CREATE TABLE handover_guide (                    -- shift_handover_agent: sections, status words, standard lines
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('SECTION', 'STATUS', 'STANDARD_LINE', 'RULE')),
  term        VARCHAR(60) NOT NULL,              -- 1 AOG / AWAITING_PARTS / closing line
  meaning     VARCHAR(400) NOT NULL,
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- Staff: MRO controllers (scoped to a base) and reviewers (scoped to a team)
-- ---------------------------------------------------------------------
CREATE TABLE controllers (
  staff_id       VARCHAR(10) PRIMARY KEY,         -- NVA-2101
  display_name   VARCHAR(60) NOT NULL,
  base_id        VARCHAR(4) NOT NULL REFERENCES bases,
  one_time_code  VARCHAR(6) NOT NULL,             -- HIDDEN: demo stand-in for the badge / authenticator code
  spend_limit    NUMERIC(10,2) NOT NULL DEFAULT 25000,   -- per-order part spend a controller may commit alone
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,        -- NVA-7101 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,           -- matches case_routing.team
  one_time_code   VARCHAR(6)  NOT NULL,           -- HIDDEN
  approval_limit  NUMERIC(10,2),                  -- USD spend authority per decision; NULL = no spend authority limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(12) NOT NULL CHECK (role IN ('CONTROLLER','REVIEWER')),
  controller_id  VARCHAR(10) REFERENCES controllers,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'CONTROLLER' AND controller_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND controller_id IS NULL))
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
-- Fleet, technicians, work orders, parts, orders, AOG incidents
-- ---------------------------------------------------------------------
CREATE TABLE aircraft (
  tail_number     VARCHAR(8) PRIMARY KEY,         -- N042NV (fictional scheme)
  type_code       VARCHAR(10) NOT NULL REFERENCES aircraft_types,
  base_id         VARCHAR(4) NOT NULL REFERENCES bases,
  flight_hours    INTEGER NOT NULL,
  cycles          INTEGER NOT NULL,
  status          VARCHAR(16) NOT NULL CHECK (status IN ('IN_SERVICE','IN_MAINTENANCE','AOG','GROUNDED')),
  next_check_type VARCHAR(30),
  next_check_due  DATE
);

CREATE TABLE technicians (
  tech_id         VARCHAR(10) PRIMARY KEY,        -- TECH-201
  name            VARCHAR(60) NOT NULL,
  base_id         VARCHAR(4) NOT NULL REFERENCES bases,
  certifications  TEXT[] NOT NULL,                -- HYDRAULICS, AVIONICS, ...
  type_ratings    TEXT[] NOT NULL,                -- NV-450, ...
  shift           VARCHAR(8) NOT NULL,
  availability    VARCHAR(10) NOT NULL CHECK (availability IN ('AVAILABLE','ON_TASK','OFF')),
  email           VARCHAR(80),                    -- HIDDEN from every tool
  phone           VARCHAR(20)                     -- HIDDEN from every tool
);

CREATE TABLE work_orders (
  wo_number       VARCHAR(16) PRIMARY KEY,        -- WO-2026-00101
  tail_number     VARCHAR(8) NOT NULL REFERENCES aircraft,
  wo_type         VARCHAR(12) NOT NULL CHECK (wo_type IN ('Scheduled','Unscheduled','AOG','Inspection')),
  ata_chapter     VARCHAR(2) NOT NULL,            -- ATA iSpec 2200 chapter (public standard)
  description     TEXT NOT NULL,
  priority        VARCHAR(8) NOT NULL CHECK (priority IN ('ROUTINE','URGENT','AOG')),
  status          VARCHAR(16) NOT NULL CHECK (status IN ('OPEN','AWAITING_PARTS','IN_PROGRESS','CLOSED')),
  required_cert   VARCHAR(20) NOT NULL,           -- certification the job needs
  opened_date     DATE NOT NULL,
  due_date        DATE,
  assigned_tech   VARCHAR(10) REFERENCES technicians,
  closed_date     DATE
);

CREATE TABLE parts (
  part_number     VARCHAR(16) PRIMARY KEY,        -- NV29-4471-SK (cc = ATA chapter)
  description     VARCHAR(80) NOT NULL,
  ata_chapter     VARCHAR(2) NOT NULL,
  type_code       VARCHAR(10) NOT NULL REFERENCES aircraft_types,   -- the aircraft type it fits
  unit_price      NUMERIC(10,2) NOT NULL,
  lead_days       INTEGER NOT NULL,               -- standard delivery
  expedite_days   INTEGER NOT NULL,               -- expedited delivery
  reorder_level   INTEGER NOT NULL
);

CREATE TABLE part_stock (
  part_number     VARCHAR(16) NOT NULL REFERENCES parts,
  base_id         VARCHAR(4) NOT NULL REFERENCES bases,
  on_hand         INTEGER NOT NULL,
  PRIMARY KEY (part_number, base_id)
);

CREATE TABLE aog_incidents (
  aog_id          VARCHAR(14) PRIMARY KEY,        -- AOG-2026-014
  tail_number     VARCHAR(8) NOT NULL REFERENCES aircraft,
  base_id         VARCHAR(4) NOT NULL REFERENCES bases,
  reported_at     TIMESTAMP NOT NULL,
  reason          TEXT NOT NULL,
  severity        VARCHAR(10) NOT NULL CHECK (severity IN ('CRITICAL','HIGH','MEDIUM')),
  status          VARCHAR(10) NOT NULL CHECK (status IN ('OPEN','RESOLVING','RESOLVED')),
  resolution      TEXT,
  resolved_at     TIMESTAMP
);

-- ---------------------------------------------------------------------
-- Two-step actions (part order / expedite, technician dispatch)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'NVA-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  controller_id  VARCHAR(10) NOT NULL REFERENCES controllers,
  action_type    VARCHAR(12) NOT NULL CHECK (action_type IN ('PART_ORDER','DISPATCH')),
  target_key     TEXT NOT NULL,                   -- normalised request, shared by write-row and readback
  wo_number      VARCHAR(16),
  part_number    VARCHAR(16),
  quantity       INTEGER,
  priority       VARCHAR(10),
  tech_id        VARCHAR(10),
  total_usd      NUMERIC(12,2),
  needs_approval BOOLEAN NOT NULL DEFAULT FALSE,  -- spend above the controller's limit -> maintenance-manager case
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_ctrl ON pending_actions (controller_id, action_type, target_key, created_at);

-- Insert-only confirmed actions. trg_action_event applies them (order / approval case / dispatch).
CREATE TABLE action_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(20) NOT NULL UNIQUE,     -- PO-2026-0101 / NVA-CASE-000104 / NVA-DSP-000101
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  controller_id  VARCHAR(10) NOT NULL REFERENCES controllers,
  action_type    VARCHAR(16) NOT NULL CHECK (action_type IN ('PART_ORDER','SPEND_APPROVAL','DISPATCH')),
  wo_number      VARCHAR(16) NOT NULL REFERENCES work_orders,
  part_number    VARCHAR(16) REFERENCES parts,
  quantity       INTEGER,
  priority       VARCHAR(10),
  tech_id        VARCHAR(10) REFERENCES technicians,
  total_usd      NUMERIC(12,2),
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  controller_id  VARCHAR(10) NOT NULL REFERENCES controllers,
  proposal_ref   TEXT NOT NULL,
  outcome        VARCHAR(16) NOT NULL,
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  reference      VARCHAR(20),
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE part_orders (
  order_id          VARCHAR(14) PRIMARY KEY,      -- PO-2026-0101
  proposal_id       TEXT UNIQUE,                  -- the confirmed proposal (NULL for seeded history)
  part_number       VARCHAR(16) NOT NULL REFERENCES parts,
  base_id           VARCHAR(4) NOT NULL REFERENCES bases,
  quantity          INTEGER NOT NULL CHECK (quantity BETWEEN 1 AND 10),
  wo_number         VARCHAR(16) NOT NULL REFERENCES work_orders,
  tail_number       VARCHAR(8) NOT NULL REFERENCES aircraft,
  priority          VARCHAR(10) NOT NULL CHECK (priority IN ('ROUTINE','EXPEDITE')),
  unit_price        NUMERIC(10,2) NOT NULL,
  total_usd         NUMERIC(12,2) NOT NULL,
  status            VARCHAR(12) NOT NULL DEFAULT 'ORDERED' CHECK (status IN ('ORDERED','IN_TRANSIT','RECEIVED')),
  ordered_date      DATE NOT NULL,
  expected_delivery DATE NOT NULL,
  ordered_by        VARCHAR(10) NOT NULL,         -- controller staff id
  approved_by       VARCHAR(10),                  -- reviewer staff id when a manager approved the spend
  case_id           VARCHAR(16),                  -- the spend_approval case, if any
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Return-to-service events (only from an approved return_to_service case). trg_fleet_event applies them.
CREATE TABLE fleet_events (
  event_id     BIGSERIAL PRIMARY KEY,
  reference    VARCHAR(16) NOT NULL UNIQUE,       -- NVA-RTS-000101
  tail_number  VARCHAR(8) NOT NULL REFERENCES aircraft,
  event_type   VARCHAR(20) NOT NULL CHECK (event_type IN ('RETURN_TO_SERVICE')),
  actor        VARCHAR(10) NOT NULL,              -- reviewer staff id (the inspector)
  case_id      VARCHAR(16) NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,   -- NVA-CASE-000101
  base_id          VARCHAR(4) NOT NULL REFERENCES bases,
  tail_number      VARCHAR(8) NOT NULL REFERENCES aircraft,
  opened_by        VARCHAR(10) NOT NULL,          -- controller staff id
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary          TEXT NOT NULL,                 -- the request, neutral, in the controller's words
  reference_id     VARCHAR(20),                   -- WO / part the case is about
  requested_amount NUMERIC(4,0),                  -- units asked for (spend approval), else NULL
  unit_price       NUMERIC(10,2),                 -- spend approval: price per unit
  parked_action    VARCHAR(40),                   -- what runs on approval: PART_ORDER:<proposal_id> / RTS:<tail>
  agent_brief      TEXT,                          -- AI-prepared neutral brief; never shown to the controller
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                          -- controller-safe outcome text, set by the decision
  approved_amount  NUMERIC(4,0),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_tail ON service_cases (tail_number, request_type, status);

CREATE TABLE case_requests (                      -- every open_service_case call (readback)
  request_id      SERIAL PRIMARY KEY,
  controller_id   VARCHAR(10) NOT NULL REFERENCES controllers,
  request_type    VARCHAR(40) NOT NULL,
  tail_ref        VARCHAR(40),
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
  approved_amount  NUMERIC(4,0),
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
  event_type  VARCHAR(20) NOT NULL,               -- PART_ORDERED / TECH_DISPATCHED / CASE_OPENED / CASE_DECIDED / RETURNED_TO_SERVICE
  actor       VARCHAR(10) NOT NULL,               -- controller or reviewer staff id
  subject_id  VARCHAR(20) NOT NULL,               -- reference / order id / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id       SERIAL PRIMARY KEY,
  tail_number    VARCHAR(8) NOT NULL REFERENCES aircraft,
  controller_id  VARCHAR(10) NOT NULL REFERENCES controllers,
  subject        TEXT NOT NULL,
  logged_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- HELPERS
-- =====================================================================
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION dt(p TIMESTAMP) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD HH24:MI') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION wday(p DATE) RETURNS TEXT AS $$ SELECT trim(to_char(p, 'Day')) $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION units_txt(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL WHEN n = 1 THEN '1 unit' ELSE trim_scale(n)::text || ' units' END
$$ LANGUAGE sql IMMUTABLE;

-- NVA-2101 / nva2101 / NVA 2101 / 2101 -> NVA-2101
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'NVA-' || x
              WHEN x ~ '^NVA[0-9]{4}$' THEN 'NVA-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- N042NV / n042nv / N-042-NV / 042NV -> N042NV
CREATE OR REPLACE FUNCTION norm_tail(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^0[0-9]{2}NV$' THEN 'N' || x ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- WO-2026-00101 / wo 2026 00101 / WO202600101 / 00101 / 101 -> WO-2026-00101
CREATE OR REPLACE FUNCTION norm_wo(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{1,5}$' THEN 'WO-2026-' || lpad(x, 5, '0')
              WHEN x ~ '^(WO)?2026[0-9]{5}$' THEN 'WO-2026-' || right(x, 5)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- TECH-201 / tech201 / 201 -> TECH-201
CREATE OR REPLACE FUNCTION norm_tech(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{3}$' THEN 'TECH-' || x
              WHEN x ~ '^TECH[0-9]{3}$' THEN 'TECH-' || substr(x, 5)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- ids typed by people or the model: ' nva-case-000101 ' -> 'NVA-CASE-000101'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- '2', '2 units', '2 pumps', '2.0' -> '2'; '' -> ''; anything else -> upper text (-> QTY_INVALID / AMOUNT_INVALID)
CREATE OR REPLACE FUNCTION norm_qty(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN trim(coalesce(p, '')) = '' THEN ''
              WHEN trim(p) ~* '^-?[0-9]+(\.0+)?(\s*(x|units?|ea|each|pcs?|pieces?|kits?|pumps?|sets?))?$'
              THEN substring(trim(p) FROM '^-?[0-9]+')
              ELSE left(upper(trim(p)), 20) END
$$ LANGUAGE sql IMMUTABLE;
-- EXPEDITE / expedited / AOG / urgent -> EXPEDITE; ROUTINE / standard / normal / '' -> ROUTINE; else the text (-> INVALID_PRIORITY)
CREATE OR REPLACE FUNCTION norm_priority(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('EXPEDITE','EXPEDITED','EXPEDITING','AOG','URGENT','RUSH','PRIORITY') THEN 'EXPEDITE'
              WHEN x IN ('', 'ROUTINE','STANDARD','NORMAL','REGULAR') THEN 'ROUTINE'
              ELSE left(x, 20) END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- A part as typed ('nv29 4471 sk', 'NV29-4471-SK') -> the catalogue part number, or NULL
CREATE OR REPLACE FUNCTION part_lookup(p TEXT) RETURNS TEXT AS $$
  SELECT x.part_number FROM parts x
   WHERE regexp_replace(upper(x.part_number), '[^A-Z0-9]', '', 'g') = regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g')
$$ LANGUAGE sql STABLE;
-- A technician as typed: TECH-201 / 201 / the full name 'Rosa Delgado' -> tech_id, or NULL
CREATE OR REPLACE FUNCTION tech_lookup(p TEXT) RETURNS TEXT AS $$
  SELECT coalesce((SELECT t.tech_id FROM technicians t WHERE t.tech_id = norm_tech(p)),
                  (SELECT min(t.tech_id) FROM technicians t WHERE lower(t.name) = lower(trim(coalesce(p, ''))) HAVING count(*) = 1))
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION type_name_of(p_tail TEXT) RETURNS TEXT AS $$
  SELECT t.type_name FROM aircraft a JOIN aircraft_types t ON t.type_code = a.type_code WHERE a.tail_number = p_tail
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;
-- The controller's tail: only when the aircraft is assigned to the controller's base.
CREATE OR REPLACE FUNCTION base_tail(p_base TEXT, p_tail TEXT) RETURNS TEXT AS $$
  SELECT a.tail_number FROM aircraft a WHERE a.tail_number = norm_tail(p_tail) AND a.base_id = p_base
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- IDENTITY (controllers and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the controller + base when the token is a valid CONTROLLER token, else NULLs.
CREATE OR REPLACE FUNCTION session_controller(p_token TEXT)
RETURNS TABLE (staff_id VARCHAR, base_id VARCHAR, display_name VARCHAR, spend_limit NUMERIC) AS $$
BEGIN
  RETURN QUERY
    SELECT c.staff_id, c.base_id, c.display_name, c.spend_limit
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'CONTROLLER'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN controllers c ON c.staff_id = s.controller_id AND c.active;
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

-- Guarded write-row for verify_controller: records the attempt (throttle); returns the sessions row ONLY for a
-- matching staff id + code while the id is not locked (5 failures in 15 minutes).
CREATE OR REPLACE FUNCTION verify_controller_fn(p_staff TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, controller_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_staff_id(p_staff); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'CONTROLLER' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('CONTROLLER', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT c.staff_id INTO v_match FROM controllers c
   WHERE c.staff_id = v_id AND c.one_time_code = trim(coalesce(p_code, '')) AND c.active;
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('CONTROLLER', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('CONTROLLER', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'CONTROLLER'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_controller_result(p_staff TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, role TEXT, display_name VARCHAR, base TEXT, spend_limit_usd TEXT,
               expires_at TEXT, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'CONTROLLER' END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.display_name END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.base END,
         CASE WHEN va.outcome = 'VERIFIED' THEN usd(se.spend_limit) END,
         CASE WHEN va.outcome = 'VERIFIED' THEN dt(se.expires_at) END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL
                THEN 'You are verified as the MRO controller for ' || se.base || '. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For security, verification is paused for 15 minutes. Please try again later.'
              ELSE 'That staff ID and code do not match our records. Please check both and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'CONTROLLER' AND a.identifier = norm_staff_id(p_staff)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, c.display_name, b.base_name || ' (' || b.base_id || ')' AS base, c.spend_limit, s.expires_at
                         FROM controllers c JOIN bases b ON b.base_id = c.base_id
                         JOIN sessions s ON s.controller_id = c.staff_id AND s.role = 'CONTROLLER' AND s.expires_at > clock_timestamp()
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
-- SCOPED READS (controller) - every function starts FROM session_controller(token) and stays on that base
-- =====================================================================
CREATE OR REPLACE FUNCTION base_fleet(p_token TEXT)
RETURNS TABLE (status TEXT, base VARCHAR, tail_number VARCHAR, aircraft_type VARCHAR, platform VARCHAR, aircraft_status VARCHAR,
               flight_hours INTEGER, cycles INTEGER, next_check TEXT, open_work_orders INTEGER, open_aog VARCHAR) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         b.base_name, a.tail_number, t.type_name, t.platform, a.status, a.flight_hours, a.cycles,
         a.next_check_type || ' due ' || d(a.next_check_due),
         (SELECT count(*)::int FROM work_orders w WHERE w.tail_number = a.tail_number AND w.status <> 'CLOSED'),
         (SELECT g.aog_id || ' (' || g.status || ')' FROM aog_incidents g WHERE g.tail_number = a.tail_number AND g.status <> 'RESOLVED'
           ORDER BY g.reported_at DESC LIMIT 1)::varchar
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN bases b ON b.base_id = sc.base_id
    LEFT JOIN aircraft a ON a.base_id = sc.base_id
    LEFT JOIN aircraft_types t ON t.type_code = a.type_code
   ORDER BY CASE a.status WHEN 'AOG' THEN 0 WHEN 'GROUNDED' THEN 1 WHEN 'IN_MAINTENANCE' THEN 2 ELSE 3 END, a.tail_number
$$ LANGUAGE sql STABLE;

-- Open work at the base (tail = '' / ALL for every tail), or one tail's open work orders.
CREATE OR REPLACE FUNCTION work_orders_at(p_token TEXT, p_tail TEXT)
RETURNS TABLE (status TEXT, wo_number VARCHAR, tail_number VARCHAR, aircraft_type VARCHAR, wo_type VARCHAR, ata_chapter VARCHAR,
               description TEXT, priority VARCHAR, wo_status VARCHAR, required_certification VARCHAR, assigned_technician TEXT,
               opened TEXT, due TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID'
              WHEN f.all_tails = FALSE AND f.tail IS NULL THEN 'NOT_FOUND'
              WHEN w.wo_number IS NULL THEN 'NONE' ELSE 'OK' END,
         w.wo_number, w.tail_number, t.type_name, w.wo_type, w.ata_chapter, w.description, w.priority, w.status, w.required_cert,
         CASE WHEN w.assigned_tech IS NULL THEN CASE WHEN w.wo_number IS NOT NULL THEN 'unassigned' END
              ELSE tc.name || ' (' || tc.tech_id || ')' END,
         d(w.opened_date), d(w.due_date)
    FROM (SELECT * FROM session_controller(p_token)) sc
    CROSS JOIN LATERAL (SELECT upper(trim(coalesce(p_tail, ''))) IN ('', 'ALL', '*') AS all_tails,
                               base_tail(sc.base_id, p_tail) AS tail) f
    LEFT JOIN work_orders w ON sc.staff_id IS NOT NULL AND w.status <> 'CLOSED'
         AND w.tail_number IN (SELECT a.tail_number FROM aircraft a WHERE a.base_id = sc.base_id)
         AND (f.all_tails OR w.tail_number = f.tail)
    LEFT JOIN aircraft a ON a.tail_number = w.tail_number
    LEFT JOIN aircraft_types t ON t.type_code = a.type_code
    LEFT JOIN technicians tc ON tc.tech_id = w.assigned_tech
   ORDER BY CASE w.priority WHEN 'AOG' THEN 0 WHEN 'URGENT' THEN 1 ELSE 2 END, w.wo_number
$$ LANGUAGE sql STABLE;

-- One tail's maintenance history (last 180 days, open and closed) - the input for the repeat-defect check.
CREATE OR REPLACE FUNCTION tail_history(p_token TEXT, p_tail TEXT)
RETURNS TABLE (status TEXT, tail_number VARCHAR, aircraft_type TEXT, wo_number VARCHAR, opened TEXT, closed TEXT, ata_chapter VARCHAR,
               wo_type VARCHAR, description TEXT, wo_status VARCHAR, same_ata_last_30_days INTEGER) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN bt.tail IS NULL THEN 'NOT_FOUND'
              WHEN w.wo_number IS NULL THEN 'NONE' ELSE 'OK' END,
         bt.tail::varchar, type_name_of(bt.tail), w.wo_number, d(w.opened_date), d(w.closed_date), w.ata_chapter, w.wo_type,
         w.description, w.status,
         (SELECT count(*)::int FROM work_orders w2 WHERE w2.tail_number = w.tail_number AND w2.ata_chapter = w.ata_chapter
             AND w2.opened_date > current_date - 30)
    FROM (SELECT * FROM session_controller(p_token)) sc
    CROSS JOIN LATERAL (SELECT base_tail(sc.base_id, p_tail) AS tail) bt
    LEFT JOIN work_orders w ON w.tail_number = bt.tail AND w.opened_date > current_date - 180
   ORDER BY w.opened_date DESC, w.wo_number DESC
$$ LANGUAGE sql STABLE;

-- Parts catalogue with stock at the controller's base. search = '' / ALL for everything; otherwise every word must match
-- the part number, description, ATA chapter or aircraft type.
CREATE OR REPLACE FUNCTION parts_at(p_token TEXT, p_search TEXT)
RETURNS TABLE (status TEXT, part_number VARCHAR, description VARCHAR, ata_chapter VARCHAR, fits_aircraft_type VARCHAR,
               unit_price_usd TEXT, on_hand_at_your_base INTEGER, reorder_level INTEGER, below_reorder TEXT,
               standard_lead_days INTEGER, expedite_days INTEGER, on_order_at_your_base INTEGER) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN p.part_number IS NULL THEN 'NONE' ELSE 'OK' END,
         p.part_number, p.description, p.ata_chapter, t.type_name, usd(p.unit_price), coalesce(ps.on_hand, 0), p.reorder_level,
         CASE WHEN p.part_number IS NULL THEN NULL WHEN coalesce(ps.on_hand, 0) <= p.reorder_level THEN 'yes' ELSE 'no' END,
         p.lead_days, p.expedite_days,
         (SELECT coalesce(sum(o.quantity), 0)::int FROM part_orders o WHERE o.part_number = p.part_number AND o.base_id = sc.base_id
             AND o.status <> 'RECEIVED')
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN parts p ON sc.staff_id IS NOT NULL AND (
            upper(trim(coalesce(p_search, ''))) IN ('', 'ALL', '*')
         OR NOT EXISTS (SELECT 1 FROM regexp_split_to_table(lower(trim(p_search)), '[\s,]+') w
                         WHERE w <> '' AND position(w IN lower(p.part_number || ' ' || regexp_replace(p.part_number, '[^A-Za-z0-9]', '', 'g')
                                 || ' ' || p.description || ' ata ' || p.ata_chapter || ' ' || p.type_code
                                 || ' ' || (SELECT t2.type_name FROM aircraft_types t2 WHERE t2.type_code = p.type_code))) = 0))
    LEFT JOIN aircraft_types t ON t.type_code = p.type_code
    LEFT JOIN part_stock ps ON ps.part_number = p.part_number AND ps.base_id = sc.base_id
   ORDER BY p.part_number
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION part_orders_at(p_token TEXT)
RETURNS TABLE (status TEXT, order_id VARCHAR, part_number VARCHAR, description VARCHAR, quantity INTEGER, tail_number VARCHAR,
               wo_number VARCHAR, priority VARCHAR, total_usd TEXT, order_status VARCHAR, ordered TEXT, expected_delivery TEXT,
               manager_approved TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN o.order_id IS NULL THEN 'NONE' ELSE 'OK' END,
         o.order_id, o.part_number, p.description, o.quantity, o.tail_number, o.wo_number, o.priority, usd(o.total_usd), o.status,
         d(o.ordered_date), d(o.expected_delivery),
         CASE WHEN o.order_id IS NULL THEN NULL WHEN o.case_id IS NOT NULL THEN 'yes (' || o.case_id || ')' ELSE 'no' END
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN part_orders o ON o.base_id = sc.base_id
    LEFT JOIN parts p ON p.part_number = o.part_number
   ORDER BY o.created_at DESC, o.order_id DESC
$$ LANGUAGE sql STABLE;

-- Technicians at the base (certification = '' for all). Never their email or phone.
CREATE OR REPLACE FUNCTION technicians_at(p_token TEXT, p_cert TEXT)
RETURNS TABLE (status TEXT, tech_id VARCHAR, name VARCHAR, certifications TEXT, type_ratings TEXT, shift VARCHAR,
               availability VARCHAR, current_work_order VARCHAR) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN t.tech_id IS NULL THEN 'NONE' ELSE 'OK' END,
         t.tech_id, t.name, array_to_string(t.certifications, ', '), array_to_string(t.type_ratings, ', '), t.shift, t.availability,
         (SELECT w.wo_number FROM work_orders w WHERE w.assigned_tech = t.tech_id AND w.status <> 'CLOSED' ORDER BY w.wo_number LIMIT 1)
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN technicians t ON t.base_id = sc.base_id
         AND (trim(coalesce(p_cert, '')) IN ('', '*') OR upper(trim(p_cert)) = 'ALL'
              OR EXISTS (SELECT 1 FROM unnest(t.certifications || t.type_ratings) c WHERE upper(c) LIKE '%' || upper(trim(p_cert)) || '%'))
   ORDER BY CASE t.availability WHEN 'AVAILABLE' THEN 0 WHEN 'ON_TASK' THEN 1 ELSE 2 END, t.tech_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION aog_incidents_at(p_token TEXT)
RETURNS TABLE (status TEXT, aog_id VARCHAR, tail_number VARCHAR, aircraft_type VARCHAR, reported TEXT, hours_on_ground INTEGER,
               reason TEXT, severity VARCHAR, aog_status VARCHAR, resolution TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN g.aog_id IS NULL THEN 'NONE' ELSE 'OK' END,
         g.aog_id, g.tail_number, t.type_name, dt(g.reported_at),
         (extract(epoch FROM coalesce(g.resolved_at, clock_timestamp()::timestamp) - g.reported_at) / 3600)::int,
         g.reason, g.severity, g.status, g.resolution
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN aog_incidents g ON g.base_id = sc.base_id AND (g.status <> 'RESOLVED' OR g.resolved_at > clock_timestamp() - INTERVAL '30 days')
    LEFT JOIN aircraft a ON a.tail_number = g.tail_number
    LEFT JOIN aircraft_types t ON t.type_code = a.type_code
   ORDER BY CASE g.status WHEN 'OPEN' THEN 0 WHEN 'RESOLVING' THEN 1 ELSE 2 END, g.reported_at DESC
$$ LANGUAGE sql STABLE;

-- The base's shift-handover snapshot: AOGs, open work, parts on order, open cases, decisions in the last 24 hours.
-- Equipment data only - no technician, controller or reviewer names and no case ids (it goes to the handover agent as is).
CREATE OR REPLACE FUNCTION base_handover(p_token TEXT)
RETURNS TABLE (status TEXT, base VARCHAR, item_type TEXT, ref VARCHAR, tail_number VARCHAR, item_status VARCHAR, detail TEXT,
               due_or_eta TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN h.ref IS NULL THEN 'NONE' ELSE 'OK' END,
         b.base_name, h.item_type, h.ref, h.tail, h.st, h.detail, h.due
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN bases b ON b.base_id = sc.base_id
    LEFT JOIN LATERAL (
      SELECT 1 AS ord, 'AOG'::text AS item_type, g.aog_id::varchar AS ref, g.tail_number::varchar AS tail, g.status::varchar AS st,
             type_name_of(g.tail_number) || ' - ' || g.reason || coalesce(' | ' || g.resolution, '') AS detail,
             'on ground ' || (extract(epoch FROM clock_timestamp()::timestamp - g.reported_at) / 3600)::int || ' h' AS due
        FROM aog_incidents g WHERE g.base_id = sc.base_id AND g.status <> 'RESOLVED'
      UNION ALL
      SELECT 2, 'WORK_ORDER', w.wo_number, w.tail_number, w.status,
             w.priority || ' ATA ' || w.ata_chapter || ' - ' || w.description || ' | needs ' || w.required_cert || ' | '
             || CASE WHEN w.assigned_tech IS NULL THEN 'unassigned' ELSE 'technician assigned' END,
             'due ' || d(w.due_date)
        FROM work_orders w JOIN aircraft a ON a.tail_number = w.tail_number
       WHERE a.base_id = sc.base_id AND w.status <> 'CLOSED'
      UNION ALL
      SELECT 3, 'PART_ORDER', o.order_id, o.tail_number, o.status,
             o.quantity || ' x ' || o.part_number || ' ' || p.description || ' (' || o.priority || ') for ' || o.wo_number,
             'ETA ' || d(o.expected_delivery)
        FROM part_orders o JOIN parts p ON p.part_number = o.part_number
       WHERE o.base_id = sc.base_id AND o.status <> 'RECEIVED'
      UNION ALL
      SELECT 4, 'OPEN_CASE', r.label::varchar, c.tail_number, c.status, 'waiting for ' || r.team, 'reply due ' || dt(c.sla_due_at)
        FROM service_cases c JOIN case_routing r ON r.request_type = c.request_type
       WHERE c.base_id = sc.base_id AND c.status = 'OPEN'
      UNION ALL
      SELECT 5, 'DECISION', r.label::varchar, c.tail_number, c.status, coalesce(c.customer_message, ''), 'decided ' || dt(c.decided_at)
        FROM service_cases c JOIN case_routing r ON r.request_type = c.request_type
       WHERE c.base_id = sc.base_id AND c.status <> 'OPEN' AND c.decided_at > clock_timestamp() - INTERVAL '24 hours'
    ) h ON sc.staff_id IS NOT NULL
   ORDER BY h.ord, h.ref
$$ LANGUAGE sql STABLE;

-- The base's cases. Never the internal note, the agent brief or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, tail_number VARCHAR, about VARCHAR, team VARCHAR, case_status VARCHAR,
               opened_at TEXT, reply_due TEXT, requested_units NUMERIC, approved_units NUMERIC, decided_at TEXT,
               customer_message TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN c.case_id IS NULL THEN 'NONE' ELSE 'OK' END,
         c.case_id, r.label, c.tail_number, c.reference_id, r.team, c.status, dt(c.created_at), dt(c.sla_due_at),
         c.requested_amount, c.approved_amount, dt(c.decided_at),
         CASE WHEN c.case_id IS NULL THEN NULL
              WHEN c.status = 'OPEN' THEN 'Open - a person on the ' || r.team || ' team will decide.' ELSE c.customer_message END
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN service_cases c ON c.base_id = sc.base_id
    LEFT JOIN case_routing r ON r.request_type = c.request_type
   ORDER BY c.created_at DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- PART ORDER / EXPEDITE (two-step): rules -> propose (PROPOSED / BLOCKED, 15 minutes) -> confirm (re-check)
-- -> action event + trigger (order placed, or a maintenance-manager case when the spend is above the limit)
-- =====================================================================
CREATE OR REPLACE FUNCTION part_order_key(p_wo TEXT, p_part TEXT, p_qty TEXT, p_prio TEXT) RETURNS TEXT AS $$
  SELECT 'PART|' || norm_wo(p_wo) || '|' || coalesce(part_lookup(p_part), norm_ref(p_part)) || '|' || norm_qty(p_qty) || '|' || norm_priority(p_prio)
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION part_order_eval(p_base TEXT, p_limit NUMERIC, p_wo TEXT, p_part TEXT, p_qty TEXT, p_prio TEXT)
RETURNS TABLE (ok BOOLEAN, needs_approval BOOLEAN, reason_code TEXT, reason_text TEXT, wo_number VARCHAR, part_number VARCHAR,
               quantity INTEGER, priority TEXT, total_usd NUMERIC, expected_delivery DATE, summary TEXT) AS $$
  SELECT c.code = 'OK', (c.code = 'OK' AND c.total > p_limit), nullif(c.code, 'OK'),
         CASE c.code
           WHEN 'OK' THEN NULL
           WHEN 'NOT_FOUND' THEN 'I could not find work order ' || norm_wo(p_wo) || ' at your base. Nothing was ordered.'
           WHEN 'WO_CLOSED' THEN 'Work order ' || w.wo_number || ' is closed. Nothing was ordered.'
           WHEN 'PART_NOT_FOUND' THEN 'Part ' || norm_ref(p_part) || ' is not in the Northvale parts catalogue. Nothing was ordered.'
           WHEN 'PART_NOT_APPLICABLE' THEN 'Part ' || p.part_number || ' (' || p.description || ') fits the ' || pt.type_name
                || ', but ' || w.tail_number || ' is an ' || at.type_name || '. Nothing was ordered.'
           WHEN 'QTY_INVALID' THEN 'The quantity must be a whole number from 1 to 10. Nothing was ordered.'
           WHEN 'INVALID_PRIORITY' THEN 'The priority must be ROUTINE or EXPEDITE. Nothing was ordered.'
           WHEN 'ALREADY_ORDERED' THEN 'Part ' || p.part_number || ' is already on order for ' || w.wo_number
                || coalesce(' (' || c.existing || ')', '') || '. Nothing new was ordered.'
         END,
         w.wo_number, p.part_number, c.qty, c.prio, c.total, c.eta,
         CASE WHEN c.code = 'OK' THEN
           'Order ' || c.qty || ' x ' || p.part_number || ' ' || p.description || ' for ' || w.wo_number || ' on ' || w.tail_number
           || ' (' || at.type_name || '), ' || c.prio || ': ' || usd(c.total) || ' total (' || usd(p.unit_price) || ' each), expected delivery '
           || wday(c.eta) || ' ' || d(c.eta) || '. On hand at your base: ' || coalesce(ps.on_hand, 0) || '.'
           || CASE WHEN c.total > p_limit THEN ' This is above your ' || usd(p_limit) || ' per-order limit, so confirming sends it to a '
                   || 'maintenance manager for approval; nothing is ordered until they approve.' ELSE '' END
         END
    FROM (SELECT 1) one
    LEFT JOIN work_orders w ON w.wo_number = norm_wo(p_wo)
         AND w.tail_number IN (SELECT a0.tail_number FROM aircraft a0 WHERE a0.base_id = p_base)
    LEFT JOIN aircraft a ON a.tail_number = w.tail_number
    LEFT JOIN aircraft_types at ON at.type_code = a.type_code
    LEFT JOIN parts p ON p.part_number = part_lookup(p_part)
    LEFT JOIN aircraft_types pt ON pt.type_code = p.type_code
    LEFT JOIN part_stock ps ON ps.part_number = p.part_number AND ps.base_id = p_base
    CROSS JOIN LATERAL (
      SELECT q.qty, q.prio, q.qty * p.unit_price AS total,
             current_date + CASE WHEN q.prio = 'EXPEDITE' THEN p.expedite_days ELSE p.lead_days END AS eta,
             x.existing,
             CASE WHEN w.wo_number IS NULL THEN 'NOT_FOUND'
                  WHEN w.status = 'CLOSED' THEN 'WO_CLOSED'
                  WHEN p.part_number IS NULL THEN 'PART_NOT_FOUND'
                  WHEN p.type_code <> a.type_code THEN 'PART_NOT_APPLICABLE'
                  WHEN q.qty IS NULL OR q.qty < 1 OR q.qty > 10 THEN 'QTY_INVALID'
                  WHEN q.prio NOT IN ('ROUTINE','EXPEDITE') THEN 'INVALID_PRIORITY'
                  WHEN x.existing IS NOT NULL THEN 'ALREADY_ORDERED'
                  ELSE 'OK' END AS code
        FROM (SELECT CASE WHEN norm_qty(p_qty) ~ '^-?[0-9]{1,4}$' THEN norm_qty(p_qty)::int END AS qty,
                     norm_priority(p_prio) AS prio) q
        LEFT JOIN LATERAL (
          SELECT coalesce(
                   (SELECT 'order ' || o.order_id FROM part_orders o WHERE o.wo_number = w.wo_number AND o.part_number = p.part_number
                       AND o.status <> 'RECEIVED' LIMIT 1),
                   (SELECT 'waiting for manager approval in ' || sc2.case_id FROM service_cases sc2 JOIN pending_actions pa2
                        ON sc2.parked_action = 'PART_ORDER:' || pa2.proposal_id
                     WHERE pa2.wo_number = w.wo_number AND pa2.part_number = p.part_number AND sc2.status = 'OPEN' LIMIT 1)) AS existing
        ) x ON TRUE
    ) c
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_part_order_fn(p_token TEXT, p_wo TEXT, p_part TEXT, p_qty TEXT, p_prio TEXT)
RETURNS TABLE (controller_id VARCHAR, action_type VARCHAR, target_key TEXT, wo_number VARCHAR, part_number VARCHAR, quantity INTEGER,
               priority VARCHAR, total_usd NUMERIC, needs_approval BOOLEAN, outcome VARCHAR, reason_code VARCHAR, reason_text TEXT,
               summary TEXT) AS $$
  SELECT sc.staff_id, 'PART_ORDER'::varchar, part_order_key(p_wo, p_part, p_qty, p_prio), e.wo_number, e.part_number,
         CASE WHEN e.quantity BETWEEN -999 AND 9999 THEN e.quantity END,
         (CASE WHEN e.priority IN ('ROUTINE','EXPEDITE') THEN e.priority END)::varchar, e.total_usd, coalesce(e.needs_approval, FALSE),
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary
    FROM session_controller(p_token) sc
    CROSS JOIN LATERAL part_order_eval(sc.base_id, sc.spend_limit, p_wo, p_part, p_qty, p_prio) e
   WHERE sc.staff_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.controller_id = sc.staff_id AND pa.action_type = 'PART_ORDER'
                        AND pa.target_key = part_order_key(p_wo, p_part, p_qty, p_prio) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM action_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_part_order_result(p_token TEXT, p_wo TEXT, p_part TEXT, p_qty TEXT, p_prio TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, needs_manager_approval TEXT, total_usd TEXT, reason_code VARCHAR, reason_text TEXT,
               summary TEXT, expires_at TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN CASE WHEN pa.needs_approval THEN 'yes' ELSE 'no' END END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN usd(pa.total_usd) END,
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN pa.outcome = 'PROPOSED' AND pa.needs_approval THEN 'Nothing is ordered yet. Reply yes within 15 minutes to send it to a maintenance manager for approval.'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing is ordered yet. Reply yes within 15 minutes to place the order.'
              ELSE pa.reason_text END,
         pa.summary, CASE WHEN pa.outcome = 'PROPOSED' THEN dt(pa.expires_at) END
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.controller_id = sc.staff_id AND p.action_type = 'PART_ORDER'
                          AND p.target_key = part_order_key(p_wo, p_part, p_qty, p_prio)
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- TECHNICIAN DISPATCH (two-step): certified + type-rated, same base, AVAILABLE, work order open and unassigned
-- =====================================================================
CREATE OR REPLACE FUNCTION dispatch_key(p_wo TEXT, p_tech TEXT) RETURNS TEXT AS $$
  SELECT 'DSP|' || norm_wo(p_wo) || '|' || coalesce(tech_lookup(p_tech), norm_ref(p_tech))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION dispatch_eval(p_base TEXT, p_wo TEXT, p_tech TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, wo_number VARCHAR, tech_id VARCHAR, summary TEXT) AS $$
  SELECT c.code = 'OK', nullif(c.code, 'OK'),
         CASE c.code
           WHEN 'OK' THEN NULL
           WHEN 'NOT_FOUND' THEN 'I could not find work order ' || norm_wo(p_wo) || ' at your base. Nobody was dispatched.'
           WHEN 'WO_CLOSED' THEN 'Work order ' || w.wo_number || ' is closed. Nobody was dispatched.'
           WHEN 'ALREADY_ASSIGNED' THEN 'Work order ' || w.wo_number || ' already has a technician assigned (' || cur.name || ', ' || cur.tech_id
                || '). Nobody new was dispatched.'
           WHEN 'TECH_NOT_FOUND' THEN 'I could not find technician ' || norm_ref(p_tech) || '. Nobody was dispatched.'
           WHEN 'WRONG_BASE' THEN t.name || ' (' || t.tech_id || ') is based at ' || tb.base_name || ', not at your base. Nobody was dispatched.'
           WHEN 'NOT_CERTIFIED' THEN t.name || ' (' || t.tech_id || ') is not cleared for this job: ' || w.wo_number || ' needs '
                || w.required_cert || ' certification and an ' || a.type_code || ' type rating; ' || t.name || ' holds '
                || array_to_string(t.certifications, ', ') || ' (rated on ' || array_to_string(t.type_ratings, ', ') || '). Nobody was dispatched.'
           WHEN 'TECH_UNAVAILABLE' THEN t.name || ' (' || t.tech_id || ') is ' || CASE t.availability WHEN 'OFF' THEN 'off shift' ELSE 'on another task' END
                || ' right now. Nobody was dispatched.'
         END,
         w.wo_number, t.tech_id,
         CASE WHEN c.code = 'OK' THEN
           'Dispatch ' || t.name || ' (' || t.tech_id || '; ' || array_to_string(t.certifications, ', ') || '; rated on '
           || array_to_string(t.type_ratings, ', ') || '; ' || lower(t.shift) || ' shift) to ' || w.wo_number || ' on ' || w.tail_number
           || ' (ATA ' || w.ata_chapter || ': ' || w.description || '). The work order moves to IN_PROGRESS'
           || coalesce(' and ' || (SELECT g.aog_id FROM aog_incidents g WHERE g.tail_number = w.tail_number AND g.status = 'OPEN' LIMIT 1)
                       || ' moves to RESOLVING', '') || '.'
         END
    FROM (SELECT 1) one
    LEFT JOIN work_orders w ON w.wo_number = norm_wo(p_wo)
         AND w.tail_number IN (SELECT a0.tail_number FROM aircraft a0 WHERE a0.base_id = p_base)
    LEFT JOIN aircraft a ON a.tail_number = w.tail_number
    LEFT JOIN technicians cur ON cur.tech_id = w.assigned_tech
    LEFT JOIN technicians t ON t.tech_id = tech_lookup(p_tech)
    LEFT JOIN bases tb ON tb.base_id = t.base_id
    CROSS JOIN LATERAL (
      SELECT CASE WHEN w.wo_number IS NULL THEN 'NOT_FOUND'
                  WHEN w.status = 'CLOSED' THEN 'WO_CLOSED'
                  WHEN w.assigned_tech IS NOT NULL THEN 'ALREADY_ASSIGNED'
                  WHEN t.tech_id IS NULL THEN 'TECH_NOT_FOUND'
                  WHEN t.base_id <> p_base THEN 'WRONG_BASE'
                  WHEN NOT (w.required_cert = ANY (t.certifications)) OR NOT (a.type_code = ANY (t.type_ratings)) THEN 'NOT_CERTIFIED'
                  WHEN t.availability <> 'AVAILABLE' THEN 'TECH_UNAVAILABLE'
                  ELSE 'OK' END AS code
    ) c
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_dispatch_fn(p_token TEXT, p_wo TEXT, p_tech TEXT)
RETURNS TABLE (controller_id VARCHAR, action_type VARCHAR, target_key TEXT, wo_number VARCHAR, tech_id VARCHAR, outcome VARCHAR,
               reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT sc.staff_id, 'DISPATCH'::varchar, dispatch_key(p_wo, p_tech), e.wo_number, e.tech_id,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary
    FROM session_controller(p_token) sc
    CROSS JOIN LATERAL dispatch_eval(sc.base_id, p_wo, p_tech) e
   WHERE sc.staff_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.controller_id = sc.staff_id AND pa.action_type = 'DISPATCH'
                        AND pa.target_key = dispatch_key(p_wo, p_tech) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM action_events ae WHERE ae.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_dispatch_result(p_token TEXT, p_wo TEXT, p_tech TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, reason_code VARCHAR, reason_text TEXT, summary TEXT, expires_at TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nobody is dispatched yet. Reply yes within 15 minutes to dispatch.'
              ELSE pa.reason_text END,
         pa.summary, CASE WHEN pa.outcome = 'PROPOSED' THEN dt(pa.expires_at) END
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.controller_id = sc.staff_id AND p.action_type = 'DISPATCH'
                          AND p.target_key = dispatch_key(p_wo, p_tech)
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- CONFIRM (step 2 for both actions): re-checks EVERY rule; returns the action_events row only when still allowed.
-- A part order whose spend is above the controller's limit becomes a SPEND_APPROVAL event (-> manager case).
-- =====================================================================
CREATE OR REPLACE FUNCTION confirm_action_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, controller_id VARCHAR, action_type VARCHAR, wo_number VARCHAR,
               part_number VARCHAR, quantity INTEGER, priority VARCHAR, tech_id VARCHAR, total_usd NUMERIC, summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  sc RECORD; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev action_events; pe RECORD; de RECORD;
  v_id BIGINT; v_reference TEXT; v_type TEXT; v_outcome TEXT; v_text TEXT;
BEGIN
  SELECT * INTO sc FROM session_controller(p_token) s;
  IF sc.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.controller_id = sc.staff_id;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (sc.staff_id, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that proposal. Nothing was done.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM action_events a WHERE a.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (sc.staff_id, v_ref, 'ALREADY_DONE', 'This was already confirmed earlier (reference ' || ev.reference || '). Nothing new was done.',
              ev.reference, ev.summary);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (sc.staff_id, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (sc.staff_id, v_ref, 'EXPIRED', 'EXPIRED', 'This proposal expired after 15 minutes, so nothing was done. I can propose it again.', pa.summary);
    RETURN;
  END IF;
  IF pa.action_type = 'PART_ORDER' THEN
    SELECT * INTO pe FROM part_order_eval(sc.base_id, sc.spend_limit, pa.wo_number, pa.part_number, pa.quantity::text, pa.priority) x;
    IF NOT pe.ok THEN
      INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_code, reason_text, summary)
        VALUES (sc.staff_id, v_ref, 'BLOCKED', pe.reason_code, pe.reason_text, pa.summary);
      RETURN;
    END IF;
    IF pe.needs_approval THEN
      v_id := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
      v_reference := 'NVA-CASE-' || lpad(v_id::text, 6, '0');
      v_type := 'SPEND_APPROVAL'; v_outcome := 'MANAGER_APPROVAL';
      v_text := 'Above your ' || usd(sc.spend_limit) || ' limit, so nothing was ordered yet: case ' || v_reference
                || ' is with Maintenance Management, who will approve or reject it (reply due within 2 hours).';
    ELSE
      v_reference := 'PO-2026-' || lpad(nextval('po_seq')::text, 4, '0');
      v_type := 'PART_ORDER'; v_outcome := 'EXECUTED';
      v_text := 'Ordered. Expected delivery ' || wday(pe.expected_delivery) || ' ' || d(pe.expected_delivery) || '.';
    END IF;
    INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (sc.staff_id, v_ref, v_outcome, v_text, v_reference, pe.summary);
    RETURN QUERY SELECT nextval(pg_get_serial_sequence('action_events', 'event_id')), v_reference::varchar, pa.proposal_id,
                        sc.staff_id::varchar, v_type::varchar, pe.wo_number, pe.part_number, pe.quantity, pe.priority::varchar,
                        NULL::varchar, pe.total_usd, pe.summary;
    RETURN;
  END IF;
  -- DISPATCH
  SELECT * INTO de FROM dispatch_eval(sc.base_id, pa.wo_number, pa.tech_id) x;
  IF NOT de.ok THEN
    INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (sc.staff_id, v_ref, 'BLOCKED', de.reason_code, de.reason_text, pa.summary);
    RETURN;
  END IF;
  v_reference := 'NVA-DSP-' || lpad(nextval('dsp_seq')::text, 6, '0');
  INSERT INTO confirm_attempts (controller_id, proposal_ref, outcome, reason_text, reference, summary)
    VALUES (sc.staff_id, v_ref, 'EXECUTED', 'Dispatched.', v_reference, de.summary);
  RETURN QUERY SELECT nextval(pg_get_serial_sequence('action_events', 'event_id')), v_reference::varchar, pa.proposal_id,
                      sc.staff_id::varchar, 'DISPATCH'::varchar, de.wo_number, NULL::varchar, NULL::int, NULL::varchar, de.tech_id,
                      NULL::numeric, de.summary;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_action_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, reference VARCHAR, case_id VARCHAR, reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         CASE WHEN ca.outcome <> 'MANAGER_APPROVAL' THEN ca.reference END,
         CASE WHEN ca.outcome = 'MANAGER_APPROVAL' THEN ca.reference END,
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that proposal. Nothing was done.'
              ELSE ca.reason_text END,
         ca.summary
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN LATERAL (SELECT a.* FROM confirm_attempts a
                        WHERE a.controller_id = sc.staff_id AND a.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY a.attempt_id DESC LIMIT 1) ca ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded row that places a part order for a proposal (chat confirm, or a manager's approval with a quantity <= the
-- proposal). Same checks every time: WO still open, part still fits, quantity in range, proposal not ordered already.
CREATE OR REPLACE FUNCTION part_order_exec_row(p_proposal TEXT, p_qty NUMERIC, p_actor TEXT, p_case TEXT, p_order_id TEXT)
RETURNS TABLE (order_id VARCHAR, proposal_id TEXT, part_number VARCHAR, base_id VARCHAR, quantity INTEGER, wo_number VARCHAR,
               tail_number VARCHAR, priority VARCHAR, unit_price NUMERIC, total_usd NUMERIC, status VARCHAR, ordered_date DATE,
               expected_delivery DATE, ordered_by VARCHAR, approved_by VARCHAR, case_id VARCHAR) AS $$
  SELECT coalesce(p_order_id, 'PO-2026-' || lpad(nextval('po_seq')::text, 4, '0'))::varchar, pa.proposal_id, p.part_number, a.base_id,
         p_qty::int, w.wo_number, w.tail_number, pa.priority, p.unit_price, p_qty * p.unit_price, 'ORDERED'::varchar, current_date,
         current_date + CASE WHEN pa.priority = 'EXPEDITE' THEN p.expedite_days ELSE p.lead_days END,
         pa.controller_id, CASE WHEN p_case IS NOT NULL THEN p_actor END::varchar, p_case::varchar
    FROM pending_actions pa
    JOIN work_orders w ON w.wo_number = pa.wo_number
    JOIN aircraft a ON a.tail_number = w.tail_number
    JOIN parts p ON p.part_number = pa.part_number
   WHERE pa.proposal_id = p_proposal AND pa.action_type = 'PART_ORDER' AND pa.outcome = 'PROPOSED'
     AND w.status <> 'CLOSED' AND p.type_code = a.type_code
     AND p_qty >= 1 AND p_qty <= pa.quantity AND p_qty = trunc(p_qty)
     AND NOT EXISTS (SELECT 1 FROM part_orders o WHERE o.proposal_id = pa.proposal_id)
$$ LANGUAGE sql VOLATILE;

-- The confirmed action itself - atomic with the event row. Never an UPDATE from a tool.
CREATE OR REPLACE FUNCTION apply_action_event() RETURNS TRIGGER AS $$
DECLARE pa pending_actions; w work_orders; r case_routing;
BEGIN
  SELECT * INTO pa FROM pending_actions WHERE proposal_id = NEW.proposal_id;
  SELECT * INTO w FROM work_orders WHERE wo_number = NEW.wo_number;
  IF NEW.action_type = 'PART_ORDER' THEN
    INSERT INTO part_orders (order_id, proposal_id, part_number, base_id, quantity, wo_number, tail_number, priority, unit_price,
                             total_usd, status, ordered_date, expected_delivery, ordered_by, approved_by, case_id)
      SELECT * FROM part_order_exec_row(NEW.proposal_id, NEW.quantity, NEW.controller_id, NULL, NEW.reference);
  ELSIF NEW.action_type = 'SPEND_APPROVAL' THEN
    SELECT * INTO r FROM case_routing WHERE request_type = 'spend_approval';
    INSERT INTO service_cases (case_no, case_id, base_id, tail_number, opened_by, request_type, summary, reference_id, requested_amount,
                               unit_price, parked_action, agent_brief, sla_due_at)
      SELECT substring(NEW.reference FROM '[0-9]+$')::bigint, NEW.reference, a.base_id, w.tail_number, NEW.controller_id, 'spend_approval',
             NEW.summary, NEW.part_number, NEW.quantity, p.unit_price, 'PART_ORDER:' || NEW.proposal_id, NULL,
             clock_timestamp()::timestamp + r.sla_hours * INTERVAL '1 hour'
        FROM aircraft a, parts p WHERE a.tail_number = w.tail_number AND p.part_number = NEW.part_number;
    PERFORM audit('CASE_OPENED', NEW.controller_id, NEW.reference, 'spend_approval ' || NEW.quantity || ' x ' || NEW.part_number || ' ' || usd(NEW.total_usd));
  ELSIF NEW.action_type = 'DISPATCH' THEN
    UPDATE work_orders SET assigned_tech = NEW.tech_id, status = 'IN_PROGRESS' WHERE wo_number = NEW.wo_number;
    UPDATE technicians SET availability = 'ON_TASK' WHERE tech_id = NEW.tech_id;
    UPDATE aog_incidents SET status = 'RESOLVING',
           resolution = 'Certified technician dispatched to ' || NEW.wo_number || ' (' || NEW.reference || ')'
     WHERE tail_number = w.tail_number AND status = 'OPEN';
    PERFORM audit('TECH_DISPATCHED', NEW.controller_id, NEW.reference, NEW.tech_id || ' to ' || NEW.wo_number);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_action_event AFTER INSERT ON action_events FOR EACH ROW EXECUTE FUNCTION apply_action_event();

-- Every placed order (chat or manager approval): the work order waits for parts, audit row.
CREATE OR REPLACE FUNCTION apply_part_order() RETURNS TRIGGER AS $$
BEGIN
  UPDATE work_orders SET status = 'AWAITING_PARTS' WHERE wo_number = NEW.wo_number AND status = 'OPEN';
  IF NEW.proposal_id IS NOT NULL THEN
    PERFORM audit('PART_ORDERED', coalesce(NEW.approved_by, NEW.ordered_by), NEW.order_id,
                  NEW.quantity || ' x ' || NEW.part_number || ' ' || NEW.priority || ' ' || usd(NEW.total_usd) || ' for ' || NEW.wo_number
                  || coalesce(' (approved in ' || NEW.case_id || ')', ''));
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_part_order AFTER INSERT ON part_orders FOR EACH ROW EXECUTE FUNCTION apply_part_order();

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_tail TEXT, p_summary TEXT, p_brief TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, base_id VARCHAR, tail_number VARCHAR, opened_by VARCHAR, request_type VARCHAR,
               summary TEXT, reference_id VARCHAR, requested_amount NUMERIC, unit_price NUMERIC, parked_action VARCHAR, agent_brief TEXT,
               sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE sc RECORD; v_type TEXT := norm_request_type(p_type); v_tref TEXT := norm_tail(p_tail); r case_routing; v_tail TEXT;
        v_parked TEXT; v_existing TEXT; v_no BIGINT; v_case TEXT;
BEGIN
  SELECT * INTO sc FROM session_controller(p_token) s;
  IF sc.staff_id IS NULL THEN RETURN; END IF;
  SELECT * INTO r FROM case_routing cr WHERE cr.request_type = v_type AND cr.controller_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (controller_id, request_type, tail_ref, outcome, reason_code) VALUES (sc.staff_id, v_type, v_tref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  v_tail := base_tail(sc.base_id, p_tail);
  IF v_tail IS NULL THEN
    INSERT INTO case_requests (controller_id, request_type, tail_ref, outcome, reason_code) VALUES (sc.staff_id, v_type, v_tref, 'BLOCKED', 'NOT_FOUND');
    RETURN;
  END IF;
  IF v_type = 'return_to_service' THEN v_parked := 'RTS:' || v_tail; END IF;
  SELECT c.case_id INTO v_existing FROM service_cases c
   WHERE c.tail_number = v_tail AND c.request_type = v_type AND c.status = 'OPEN' ORDER BY c.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (controller_id, request_type, tail_ref, outcome, case_id) VALUES (sc.staff_id, v_type, v_tref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'NVA-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (controller_id, request_type, tail_ref, outcome, case_id) VALUES (sc.staff_id, v_type, v_tref, 'OPENED', v_case);
  PERFORM audit('CASE_OPENED', sc.staff_id, v_case, v_type || ' for ' || v_tail);
  RETURN QUERY SELECT v_no, v_case::varchar, sc.base_id, v_tail::varchar, sc.staff_id, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_tail::varchar, NULL::numeric, NULL::numeric,
                      v_parked::varchar, left(nullif(trim(p_brief), ''), 4000),
                      clock_timestamp()::timestamp + r.sla_hours * INTERVAL '1 hour';
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT, p_tail TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due TEXT, reason_code VARCHAR,
               reason_text TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.team, rt.sla_text, dt(s.sla_due_at),
         CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN sc.staff_id IS NULL THEN 'Please verify again (staff ID and code).'
              WHEN cr.outcome = 'OPENED' THEN 'The case is open. A person on the ' || rt.team || ' team will review it and decide.'
              WHEN cr.outcome = 'EXISTING' THEN 'There is already an open ' || rt.label || ' case for this aircraft, so no new case was opened. The ' || rt.team || ' team is on it.'
              WHEN cr.reason_code = 'NOT_FOUND' THEN 'I could not find that aircraft at your base, so no case was opened.'
              ELSE 'That is not a request I can open a case for here. A person can help with return-to-service sign-off, AD compliance, MEL deferrals, grounding or ungrounding, and reliability reviews.' END
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.controller_id = sc.staff_id AND q.request_type = norm_request_type(p_type)
                          AND q.tail_ref = norm_tail(p_tail)
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
-- The most units a reviewer may approve (NULL = the case carries no quantity): never more than the controller asked for.
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN split_part(s.parked_action, ':', 1) = 'PART_ORDER'
                THEN (SELECT pa.quantity FROM pending_actions pa WHERE pa.proposal_id = substr(s.parked_action, 12))
              ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Can the aircraft be returned to service in the system? Not while an AOG on it is still OPEN (nobody working it).
CREATE OR REPLACE FUNCTION rts_ready(p_tail TEXT) RETURNS BOOLEAN AS $$
  SELECT a.status <> 'IN_SERVICE' AND NOT EXISTS (SELECT 1 FROM aog_incidents g WHERE g.tail_number = a.tail_number AND g.status = 'OPEN')
    FROM aircraft a WHERE a.tail_number = p_tail
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL.
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE
    WHEN split_part(s.parked_action, ':', 1) = 'PART_ORDER' THEN
      pa.quantity || ' x ' || p.part_number || ' ' || p.description || ' at ' || usd(p.unit_price) || ' each = ' || usd(pa.total_usd)
      || ' (' || pa.priority || ', delivery about ' || CASE WHEN pa.priority = 'EXPEDITE' THEN p.expedite_days ELSE p.lead_days END
      || ' days after approval); work order ' || w.wo_number || ' (' || w.priority || ', ATA ' || w.ata_chapter || ': ' || w.description
      || ', ' || w.status || '); aircraft ' || a.tail_number || ' ' || t.type_name || ' is ' || a.status
      || coalesce('; ' || (SELECT g.aog_id || ' ' || g.status || ' for ' || (extract(epoch FROM clock_timestamp()::timestamp - g.reported_at) / 3600)::int || ' h'
                             FROM aog_incidents g WHERE g.tail_number = a.tail_number AND g.status <> 'RESOLVED' LIMIT 1), '')
      || '; on hand at ' || b.base_name || ': ' || coalesce((SELECT ps.on_hand FROM part_stock ps WHERE ps.part_number = p.part_number AND ps.base_id = a.base_id), 0)
      || '; controller limit ' || usd((SELECT c.spend_limit FROM controllers c WHERE c.staff_id = s.opened_by)) || '.'
    ELSE
      'Aircraft ' || a.tail_number || ' ' || t.type_name || ' at ' || b.base_name || ' is ' || a.status
      || '; ' || a.flight_hours || ' flight hours, ' || a.cycles || ' cycles; next check ' || a.next_check_type || ' due ' || d(a.next_check_due)
      || '; AOG: ' || coalesce((SELECT string_agg(g.aog_id || ' ' || g.status || coalesce(' (' || g.resolution || ')', ''), '; ')
                                  FROM aog_incidents g WHERE g.tail_number = a.tail_number AND g.status <> 'RESOLVED'), 'none open')
      || '; open work orders: ' || coalesce((SELECT string_agg(w2.wo_number || ' ATA ' || w2.ata_chapter || ' ' || w2.status
                                                               || CASE WHEN w2.assigned_tech IS NULL THEN ' unassigned' ELSE ' assigned' END, '; ' ORDER BY w2.wo_number)
                                               FROM work_orders w2 WHERE w2.tail_number = a.tail_number AND w2.status <> 'CLOSED'), 'none')
      || '; work orders in the last 30 days by ATA chapter: ' || coalesce((SELECT string_agg('ATA ' || x.ata_chapter || ' x' || x.n, ', ' ORDER BY x.n DESC, x.ata_chapter)
                                               FROM (SELECT w3.ata_chapter, count(*) AS n FROM work_orders w3 WHERE w3.tail_number = a.tail_number
                                                        AND w3.opened_date > current_date - 30 GROUP BY w3.ata_chapter) x), 'none')
      || CASE WHEN EXISTS (SELECT 1 FROM work_orders w4 WHERE w4.tail_number = a.tail_number AND w4.opened_date > current_date - 30
                             GROUP BY w4.ata_chapter HAVING count(*) >= 3)
              THEN ' (repeat-defect threshold met: 3 or more work orders in one ATA chapter in 30 days)' ELSE '' END
      || CASE WHEN split_part(s.parked_action, ':', 1) = 'RTS'
              THEN '; approving records the return-to-service sign-off: the aircraft goes IN_SERVICE and its AOG is resolved'
                   || CASE WHEN rts_ready(a.tail_number) THEN '' ELSE ' (not possible yet: an AOG on it is still OPEN)' END
              ELSE '' END || '.'
    END
    FROM service_cases s
    JOIN aircraft a ON a.tail_number = s.tail_number
    JOIN aircraft_types t ON t.type_code = a.type_code
    JOIN bases b ON b.base_id = a.base_id
    LEFT JOIN pending_actions pa ON split_part(s.parked_action, ':', 1) = 'PART_ORDER' AND pa.proposal_id = substr(s.parked_action, 12)
    LEFT JOIN parts p ON p.part_number = pa.part_number
    LEFT JOIN work_orders w ON w.wo_number = pa.wo_number
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id VARCHAR, request VARCHAR, tail_number VARCHAR, base VARCHAR, opened_at TEXT,
               age_hours INTEGER, reply_due TEXT, sla_status TEXT, requested_units NUMERIC, requested_spend_usd TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.tail_number, q.base_name, q.opened_at, q.age_hours, q.reply_due, q.sla_status, q.requested_amount,
         usd(q.requested_amount * q.unit_price)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, r.label, s.tail_number, b.base_name, dt(s.created_at) AS opened_at,
             (extract(epoch FROM clock_timestamp()::timestamp - s.created_at) / 3600)::int AS age_hours, dt(s.sla_due_at) AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at < clock_timestamp() + INTERVAL '1 hour' THEN 'DUE_SOON'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.unit_price, s.sla_due_at
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type JOIN bases b ON b.base_id = s.base_id
       WHERE sr.reviewer_id IS NOT NULL AND r.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, tail_number VARCHAR, base VARCHAR, opened_at TEXT,
               reply_due TEXT, controller_statement TEXT, agent_brief TEXT, requested_units NUMERIC, unit_price_usd TEXT,
               requested_spend_usd TEXT, max_approvable_units NUMERIC, your_spend_authority_usd TEXT, facts TEXT, options TEXT,
               decided_at TEXT, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.label, s.status, s.tail_number, b.base_name, dt(s.created_at), dt(s.sla_due_at), s.summary,
         CASE WHEN s.agent_brief IS NOT NULL THEN 'AI-prepared, not verified: ' || s.agent_brief END,
         s.requested_amount, usd(s.unit_price), usd(s.requested_amount * s.unit_price), case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL AND s.requested_amount IS NOT NULL THEN coalesce(usd(sr.approval_limit), 'no limit') END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.requested_amount IS NOT NULL THEN 'APPROVE (1 to ' || units_txt(case_eligible_max(s.case_id)) || ' at ' || usd(s.unit_price) || ' each'
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id) * s.unit_price
                           THEN '; above your ' || usd(sr.approval_limit) || ' authority it needs a senior manager' ELSE '' END
                   || ') or REJECT, with an internal note and a message for the controller.'
              WHEN split_part(s.parked_action, ':', 1) = 'RTS' THEN 'APPROVE (records the return-to-service sign-off: aircraft IN_SERVICE, AOG resolved) or REJECT, with an internal note and a message for the controller.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the controller.' END,
         dt(s.decided_at),
         (SELECT rd.decision || coalesce(' ' || units_txt(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT cr.request_type FROM case_routing cr WHERE cr.team = sr.team)   -- another team's case is invisible
    LEFT JOIN case_routing r ON r.request_type = s.request_type
    LEFT JOIN bases b ON b.base_id = s.base_id
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; r case_routing; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_amt_txt TEXT := norm_qty(p_amount); v_msg TEXT;
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
    v_amt := CASE WHEN v_amt_txt = '' THEN v_max WHEN v_amt_txt ~ '^-?[0-9]{1,4}$' THEN v_amt_txt::numeric END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The approved quantity must be a whole number of units from 1 to ' || units_txt(v_max)
                || ' (what the controller asked for) for this case.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND v_amt * s.unit_price > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', units_txt(v_amt) || ' at ' || usd(s.unit_price) || ' is ' || usd(v_amt * s.unit_price)
                || ', above your spend authority of ' || usd(rv.approval_limit) || '. The case stays open and needs a senior manager.');
      RETURN;
    END IF;
  END IF;
  IF v_dec = 'APPROVE' AND split_part(coalesce(s.parked_action, ''), ':', 1) = 'RTS' AND NOT coalesce(rts_ready(s.tail_number), FALSE) THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_READY', 'The system cannot record a return to service for ' || s.tail_number
              || ' yet: it is already in service or an AOG on it is still OPEN with nobody working it. The case stays open.');
    RETURN;
  END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'The ' || r.label || ' was approved' || coalesce(' for ' || units_txt(v_amt), '') || '.'
                  ELSE 'After review, the ' || r.label || ' was not approved. The ' || r.team || ' team will follow up.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, CASE WHEN v_dec = 'APPROVE' THEN v_amt END,
                      left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, decision VARCHAR, approved_units NUMERIC, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION','NOT_READY')
              THEN s.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.approved_amount END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND' AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN s.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'Ordered: ' || po.order_id || ' - ' || po.quantity || ' x ' || po.part_number || ' ' || p.description || ', '
                                 || usd(po.total_usd) || ', ' || po.priority || ', expected delivery ' || d(po.expected_delivery) || '.'
                            FROM part_orders po JOIN parts p ON p.part_number = po.part_number WHERE po.case_id = s.case_id),
                         (SELECT 'Return to service recorded (' || fe.reference || '): ' || fe.tail_number || ' is IN_SERVICE and its AOG is resolved.'
                            FROM fleet_events fe WHERE fe.case_id = s.case_id),
                         'Case approved; no automatic action - the ' || r.team || ' team completes it in the maintenance record.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN case_routing r ON r.request_type = s.request_type
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded row for a return to service (only from an approved return_to_service case, only when rts_ready).
CREATE OR REPLACE FUNCTION rts_exec_row(p_tail TEXT, p_actor TEXT, p_case TEXT)
RETURNS TABLE (reference VARCHAR, tail_number VARCHAR, event_type VARCHAR, actor VARCHAR, case_id VARCHAR) AS $$
  SELECT ('NVA-RTS-' || lpad(nextval('rts_seq')::text, 6, '0'))::varchar, a.tail_number, 'RETURN_TO_SERVICE'::varchar,
         p_actor::varchar, p_case::varchar
    FROM aircraft a
   WHERE a.tail_number = p_tail AND rts_ready(a.tail_number)
     AND NOT EXISTS (SELECT 1 FROM fleet_events fe WHERE fe.case_id = p_case)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION apply_fleet_event() RETURNS TRIGGER AS $$
BEGIN
  UPDATE aircraft SET status = 'IN_SERVICE' WHERE tail_number = NEW.tail_number;
  UPDATE aog_incidents SET status = 'RESOLVED', resolved_at = clock_timestamp(),
         resolution = coalesce(resolution || '; ', '') || 'returned to service (' || NEW.reference || ', ' || NEW.case_id || ')'
   WHERE tail_number = NEW.tail_number AND status <> 'RESOLVED';
  UPDATE technicians SET availability = 'AVAILABLE'
   WHERE tech_id IN (SELECT w.assigned_tech FROM work_orders w WHERE w.tail_number = NEW.tail_number AND w.priority = 'AOG' AND w.status = 'IN_PROGRESS');
  UPDATE work_orders SET status = 'CLOSED', closed_date = current_date
   WHERE tail_number = NEW.tail_number AND priority = 'AOG' AND status = 'IN_PROGRESS';
  PERFORM audit('RETURNED_TO_SERVICE', NEW.actor, NEW.reference, NEW.tail_number || ' (' || NEW.case_id || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_fleet_event AFTER INSERT ON fleet_events FOR EACH ROW EXECUTE FUNCTION apply_fleet_event();

-- The decision event: case status + controller message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := substr(coalesce(s.parked_action, ''), length(v_kind) + 2);
  IF v_kind = 'PART_ORDER' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO part_orders (order_id, proposal_id, part_number, base_id, quantity, wo_number, tail_number, priority, unit_price,
                             total_usd, status, ordered_date, expected_delivery, ordered_by, approved_by, case_id)
      SELECT * FROM part_order_exec_row(v_ref, NEW.approved_amount, NEW.reviewer_id, NEW.case_id, NULL);
    IF FOUND THEN v_done := 'ordered ' || units_txt(NEW.approved_amount) || ' of ' || s.reference_id; END IF;
  ELSIF v_kind = 'RTS' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO fleet_events (reference, tail_number, event_type, actor, case_id)
      SELECT * FROM rts_exec_row(v_ref, NEW.reviewer_id, NEW.case_id);
    IF FOUND THEN v_done := v_ref || ' returned to service'; END IF;
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id, NEW.decision || coalesce(' ' || units_txt(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- =====================================================================
-- EMAIL - the ops summary for one tail, only for a tail at the controller's base with an executed action
-- (a placed order, a dispatch or a decided case). SQL builds the text from what actually happened; it goes to the
-- EMAIL_TO ops mailbox.
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_tail TEXT)
RETURNS TABLE (code TEXT, controller_id VARCHAR, tail_number VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN sc.staff_id IS NULL THEN 'SESSION_INVALID' WHEN bt.tail IS NULL THEN 'NOT_FOUND'
              WHEN NOT (EXISTS (SELECT 1 FROM part_orders o WHERE o.tail_number = bt.tail AND o.proposal_id IS NOT NULL)
                     OR EXISTS (SELECT 1 FROM action_events ae JOIN work_orders w ON w.wo_number = ae.wo_number
                                 WHERE w.tail_number = bt.tail AND ae.action_type = 'DISPATCH')
                     OR EXISTS (SELECT 1 FROM service_cases c WHERE c.tail_number = bt.tail AND c.status <> 'OPEN' AND c.decided_at IS NOT NULL
                                   AND c.created_at > clock_timestamp() - INTERVAL '7 days' AND c.opened_by IN (SELECT ct.staff_id FROM controllers ct)))
                THEN 'NOTHING_TO_SEND'
              ELSE 'SEND_OK' END,
         sc.staff_id, bt.tail::varchar,
         'Northvale MRO ops summary - ' || coalesce(bt.tail, '') || ' (' || coalesce(type_name_of(bt.tail), '') || ')',
         'Northvale Aero Services - maintenance control, ' || b.base_name || chr(10) || chr(10)
         || 'Aircraft ' || bt.tail || ' (' || type_name_of(bt.tail) || ') status: ' || a.status || chr(10)
         || 'AOG: ' || coalesce((SELECT string_agg(g.aog_id || ' ' || g.status || ' - ' || g.reason || coalesce(' | ' || g.resolution, ''), chr(10))
                                    FROM aog_incidents g WHERE g.tail_number = bt.tail AND (g.status <> 'RESOLVED' OR g.resolved_at > clock_timestamp() - INTERVAL '1 day')), 'none open')
         || chr(10) || chr(10) || 'Part orders:' || chr(10)
         || coalesce((SELECT string_agg('- ' || o.order_id || ': ' || o.quantity || ' x ' || o.part_number || ' ' || p.description || ', ' || o.priority
                                        || ', ' || usd(o.total_usd) || ', expected ' || d(o.expected_delivery) || ' (' || o.status || ')'
                                        || coalesce(' - approved in ' || o.case_id, ''), chr(10) ORDER BY o.order_id)
                        FROM part_orders o JOIN parts p ON p.part_number = o.part_number
                       WHERE o.tail_number = bt.tail AND o.status <> 'RECEIVED'), '- none')
         || chr(10) || chr(10) || 'Technicians dispatched:' || chr(10)
         || coalesce((SELECT string_agg('- ' || ae.reference || ': ' || t.name || ' (' || t.tech_id || ') to ' || ae.wo_number, chr(10) ORDER BY ae.event_id)
                        FROM action_events ae JOIN work_orders w ON w.wo_number = ae.wo_number JOIN technicians t ON t.tech_id = ae.tech_id
                       WHERE w.tail_number = bt.tail AND ae.action_type = 'DISPATCH'), '- none')
         || chr(10) || chr(10) || 'Cases:' || chr(10)
         || coalesce((SELECT string_agg('- ' || c.case_id || ' ' || r.label || ': ' || c.status
                                        || CASE WHEN c.status = 'OPEN' THEN ' (with ' || r.team || ', reply due ' || dt(c.sla_due_at) || ')'
                                                ELSE coalesce(' - ' || c.customer_message, '') END, chr(10) ORDER BY c.case_no)
                        FROM service_cases c JOIN case_routing r ON r.request_type = c.request_type
                       WHERE c.tail_number = bt.tail AND (c.status = 'OPEN' OR c.decided_at > clock_timestamp() - INTERVAL '7 days')), '- none')
         || chr(10) || chr(10)
         || 'Return to service, AD compliance and MEL deferrals remain with Quality & Airworthiness. This summary lists what was '
         || 'recorded in the maintenance system; it is not an airworthiness release.' || chr(10) || chr(10)
         || 'Northvale MRO Ops Assistant (an AI assistant), on behalf of ' || sc.display_name
    FROM (SELECT * FROM session_controller(p_token)) sc
    LEFT JOIN LATERAL (SELECT base_tail(sc.base_id, p_tail) AS tail) bt ON TRUE
    LEFT JOIN aircraft a ON a.tail_number = bt.tail
    LEFT JOIN bases b ON b.base_id = sc.base_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_tail TEXT)
RETURNS TABLE (tail_number VARCHAR, controller_id VARCHAR, subject TEXT) AS $$
  SELECT e.tail_number, e.controller_id, e.subject FROM email_source(p_token, p_tail) e WHERE e.code = 'SEND_OK'
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_payload(p_token TEXT, p_tail TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, tail_number VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.code = 'SEND_OK' THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.code = 'SEND_OK' THEN NULL ELSE e.code END,
         CASE e.code WHEN 'SEND_OK' THEN 'The ops summary email is on its way to the maintenance-control mailbox.'
                     WHEN 'SESSION_INVALID' THEN 'Please verify again (staff ID and code).'
                     WHEN 'NOT_FOUND' THEN 'I could not find that aircraft at your base, so no email was sent.'
                     ELSE 'Nothing has been done on this aircraft yet (no part order, dispatch or decided case), so no email was sent.' END,
         CASE WHEN e.code = 'SEND_OK' THEN e.tail_number END,
         CASE WHEN e.code = 'SEND_OK' THEN e.subject ELSE 'Northvale MRO ops summary - not sent' END,
         CASE WHEN e.code = 'SEND_OK' THEN e.body ELSE 'No email was sent.' END
    FROM email_source(p_token, p_tail) e
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

CREATE OR REPLACE FUNCTION ref_ata_chapters(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM ata_chapter_guide g
          UNION ALL                                 -- catalogue part families: parts is the source of truth
          SELECT 'PART_FAMILY', 'ATA ' || p.ata_chapter::text || ' catalogue parts',
                 'Catalogue part families in this chapter (orientation only): '
                 || string_agg(p.description::text || ' (' || p.type_code::text || ')', '; '
                               ORDER BY p.type_code, p.description) || '.',
                 1000 + p.ata_chapter::int
            FROM parts p GROUP BY p.ata_chapter) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['ATA_CHAPTER','SYMPTOM','SHORTHAND','PART_FAMILY','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_repeat_defect_criteria(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM repeat_defect_guide g
          UNION ALL                                 -- who decides a repeat defect: case_routing is the source of truth
          SELECT 'WHO_DECIDES', c.label::text, c.team::text || ': ' || c.sla_text::text, 1000
            FROM case_routing c WHERE c.request_type = 'reliability_review') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['FLAG','WINDOW','SAME_SYSTEM','DIFFERENT_SYSTEM','TERM','WHO_DECIDES','RULE'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_handover_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM handover_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['SECTION','STATUS','STANDARD_LINE','RULE'], g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
