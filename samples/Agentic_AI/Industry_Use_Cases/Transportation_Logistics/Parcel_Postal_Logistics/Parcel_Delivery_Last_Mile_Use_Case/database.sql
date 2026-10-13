-- Swiftbound Last-Mile Parcel Delivery (GOVERNED) - schema, business rules and demo data.
-- Load:  createdb parcel_delivery  &&  psql -d parcel_delivery -f database.sql
--
-- =====================================================================
-- Parcel Delivery - Governed Agentic AI
-- The rules live HERE, not in any prompt:
--   * session_recipient()     identity: every read/write is scoped by a session token (account ref + PIN)
--   * session_reviewer()      staff identity: a REVIEWER token (staff id + staff code) - never interchangeable with a
--                             recipient token; every function checks the role
--   * delivery_health()       ON_TRACK / NEEDS_ATTENTION / LATE is computed in SQL, never the LLM's guess
--   * reschedule_eval()       reschedule eligibility (ownership, status, slot area/capacity/date)
--   * redirect_eval()         redirect eligibility (ownership, status, pickup area/size/signature/value)
--   * trg_delivery_change     the reschedule/redirect side effects happen atomically in the DB
--   * search_delivery_options() feasible slots + pickup points for the delivery_options_agent - NO recipient identity
--   * claim_eval() + claim_row_for()  a damage / missing-contents / lost claim on the recipient's OWN parcel: the
--                             damage_claim_agent's claim type, packaging and cause are VALIDATED against claim_guide,
--                             the claimable amount is capped in SQL (declared value, coverage limit) and the claim
--                             opens a Claims case that parks COMPENSATION:<claim> for a person to decide
--   * instructions_eval()     delivery instructions (safe place, access code flag, hazards): the safe place must be in
--                             safe_places, risky instructions (instruction_risk_flags - from the agent AND a SQL phrase
--                             scan) block the save, signature-required / high-value parcels allow attended places only;
--                             access codes are never stored (mask_codes)
--   * service_teams           human-owned requests (lost/damaged claims...) routed by a table
--   * reviewers + decide_case_row()  the human-in-the-loop: a Swiftbound staff reviewer (role REVIEWER, own team only,
--                             approval limit) decides; review_decisions + trg_review_decision execute the parked action
--                             (the compensation payment) through the same guarded row function, and audit it
--   * ref_claim_guide() / ref_delivery_instructions()  the new agents' read-only reference tables - NO identity
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The genuinely semantic steps are the three A2A agents: delivery_options_agent (rank feasible options against the
-- recipient's free-text preferences), damage_claim_agent (free-text damage description -> claim type, packaging,
-- likely cause, evidence) and delivery_instructions_agent (free-text access notes -> structured instructions + risky
-- instruction flags). Exception-code MEANINGS come from the exception_codes table (a deterministic lookup).
-- Swiftbound, its recipients, staff, parcels and senders are fictional.
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

DROP TABLE IF EXISTS email_log, agent_audit, decide_attempts, review_decisions, compensation_payments, damage_claims,
  delivery_instructions, reviewer_verify_attempts, verify_attempts, service_cases, service_teams, delivery_change_log,
  delivery_changes, pending_actions, recipient_sessions, reviewers, scan_events, parcels, pickup_points,
  delivery_slots, exception_codes, recipients, claim_guide, instruction_guide, safe_places, instruction_risk_flags CASCADE;
DROP SEQUENCE IF EXISTS case_seq, claim_seq, comp_seq;

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

-- Recipients: the login identity. account_ref + a 4-digit PIN (the code sent to the app / notification).
CREATE TABLE recipients (
  recipient_id      VARCHAR(20) PRIMARY KEY,          -- RCP-2026-XXXXX
  account_ref       VARCHAR(8)  NOT NULL UNIQUE,      -- 6-char Swiftbound account reference (the login id)
  verification_pin  VARCHAR(4)  NOT NULL,             -- demo stand-in for the code in the app / texted to the recipient
  first_name        VARCHAR(50) NOT NULL,
  last_name         VARCHAR(50) NOT NULL,
  email             VARCHAR(100) NOT NULL,
  phone             VARCHAR(30),
  address_line      VARCHAR(120) NOT NULL,
  postcode          VARCHAR(10)  NOT NULL,
  service_area      VARCHAR(20)  NOT NULL             -- delivery area; slots and pickup points are area-scoped
);

-- Catalogue 1: available delivery time windows a parcel can be rescheduled onto. Area-scoped, capacity-limited.
CREATE TABLE delivery_slots (
  slot_id       VARCHAR(12) PRIMARY KEY,              -- SLOT-N1
  service_area  VARCHAR(20) NOT NULL,
  slot_date     DATE        NOT NULL,
  window_start  TIME        NOT NULL,
  window_end    TIME        NOT NULL,
  capacity      INTEGER     NOT NULL DEFAULT 5,
  booked_count  INTEGER     NOT NULL DEFAULT 0
);

-- Catalogue 2: pickup points (unattended lockers and staffed shops) a parcel can be redirected to.
CREATE TABLE pickup_points (
  pickup_id        VARCHAR(14) PRIMARY KEY,           -- PU-N-LOCK1
  point_type       VARCHAR(10) NOT NULL CHECK (point_type IN ('LOCKER','SHOP')),
  name             VARCHAR(80) NOT NULL,
  service_area     VARCHAR(20) NOT NULL,
  address_line     VARCHAR(120) NOT NULL,
  max_parcel_size  VARCHAR(10) NOT NULL DEFAULT 'LARGE' CHECK (max_parcel_size IN ('SMALL','MEDIUM','LARGE')),
  open_hours       VARCHAR(60) NOT NULL DEFAULT 'Mon-Sun 07:00-22:00'
);

-- Plain-English meaning of each cryptic tracking exception code. A deterministic lookup; the model never
-- invents what a code means - it explains the stored meaning and (for the semantic step) ranks options.
CREATE TABLE exception_codes (
  code            VARCHAR(4) PRIMARY KEY,
  label           VARCHAR(80)  NOT NULL,
  recipient_advice VARCHAR(200) NOT NULL
);

CREATE TABLE parcels (
  parcel_id            SERIAL PRIMARY KEY,
  tracking_number      VARCHAR(18) NOT NULL UNIQUE,   -- SB + 12 digits
  recipient_id         VARCHAR(20) NOT NULL REFERENCES recipients,
  description          VARCHAR(120) NOT NULL,
  sender               VARCHAR(80)  NOT NULL,
  declared_value       NUMERIC(10,2) NOT NULL DEFAULT 0,
  parcel_size          VARCHAR(10)  NOT NULL DEFAULT 'SMALL' CHECK (parcel_size IN ('SMALL','MEDIUM','LARGE')),
  signature_required   BOOLEAN      NOT NULL DEFAULT FALSE,
  service_level        VARCHAR(12)  NOT NULL DEFAULT 'STANDARD' CHECK (service_level IN ('STANDARD','EXPRESS')),
  destination_area     VARCHAR(20)  NOT NULL,
  destination_postcode VARCHAR(10)  NOT NULL,
  promised_date        DATE         NOT NULL,
  current_status       VARCHAR(20)  NOT NULL DEFAULT 'IN_TRANSIT'
                         CHECK (current_status IN ('IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERY_ATTEMPTED',
                                'EXCEPTION','RESCHEDULED','REDIRECTED','DELIVERED','RETURNED')),
  exception_code       VARCHAR(4)   REFERENCES exception_codes,
  attempts_made        INTEGER      NOT NULL DEFAULT 0,
  expected_delivery    TIMESTAMP,                     -- for DELIVERED parcels: when it was delivered
  current_slot_id      VARCHAR(12)  REFERENCES delivery_slots,
  redirect_pickup_id   VARCHAR(14)  REFERENCES pickup_points,
  last_scan_at         TIMESTAMP    NOT NULL DEFAULT clock_timestamp()
);

-- Tracking timeline: the scan history shown for a parcel (newest last).
CREATE TABLE scan_events (
  event_id     SERIAL PRIMARY KEY,
  parcel_id    INTEGER NOT NULL REFERENCES parcels,
  event_at     TIMESTAMP NOT NULL,
  location     VARCHAR(60) NOT NULL,
  scan_code    VARCHAR(16) NOT NULL,
  description  VARCHAR(120) NOT NULL
);

-- Staff reviewers (the human in the loop). team matches service_teams.team.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- SWB-4101 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(60) NOT NULL,
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN: demo stand-in for the staff sign-in code
  approval_limit  NUMERIC(10,2),                 -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role (recipient and reviewer tokens are
-- not interchangeable).
CREATE TABLE recipient_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL DEFAULT 'RECIPIENT' CHECK (role IN ('RECIPIENT','REVIEWER')),
  recipient_id   VARCHAR(20) REFERENCES recipients,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'RECIPIENT' AND recipient_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND recipient_id IS NULL))
);

-- Brute-force throttle for the PIN step: N wrong PINs for an account ref -> a cooldown lock.
CREATE TABLE verify_attempts (
  account_ref   VARCHAR(8) PRIMARY KEY,
  attempts      INTEGER NOT NULL DEFAULT 0,
  locked_until  TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Same throttle for the staff code step (5 wrong codes in 15 minutes -> locked). One row per attempt.
CREATE TABLE reviewer_verify_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  ok           BOOLEAN NOT NULL,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pending_actions (
  action_id     TEXT PRIMARY KEY DEFAULT 'ACT-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  action_type   VARCHAR(12) NOT NULL CHECK (action_type IN ('RESCHEDULE','REDIRECT','INSTRUCTIONS')),
  parcel_id     INTEGER NOT NULL REFERENCES parcels,
  slot_id       VARCHAR(12) REFERENCES delivery_slots,
  pickup_id     VARCHAR(14) REFERENCES pickup_points,
  safe_place          VARCHAR(30),               -- INSTRUCTIONS: a safe_places code (SQL-checked)
  access_code_present BOOLEAN,                   -- INSTRUCTIONS: a code was given - the code itself is never stored
  hazards             TEXT,                      -- INSTRUCTIONS: instruction_guide HAZARD terms (validated)
  notes_masked        TEXT,                      -- INSTRUCTIONS: the recipient's notes with any 3+ digit run masked
  agent_notes         TEXT,                      -- INSTRUCTIONS: the delivery_instructions_agent's answer (masked)
  status        VARCHAR(12) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','EXECUTED')),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

CREATE TABLE delivery_changes (
  change_id     SERIAL PRIMARY KEY,
  action_id     TEXT UNIQUE NOT NULL REFERENCES pending_actions,
  parcel_id     INTEGER NOT NULL REFERENCES parcels,
  action_type   VARCHAR(12) NOT NULL,
  slot_id       VARCHAR(12) REFERENCES delivery_slots,
  pickup_id     VARCHAR(14) REFERENCES pickup_points,
  changed_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Saved delivery instructions (insert-only event rows; the latest one per parcel is the one the driver sees).
CREATE TABLE delivery_instructions (
  instruction_id      SERIAL PRIMARY KEY,
  action_id           TEXT UNIQUE NOT NULL REFERENCES pending_actions,
  parcel_id           INTEGER NOT NULL REFERENCES parcels,
  safe_place          VARCHAR(30) NOT NULL,
  access_code_present BOOLEAN NOT NULL,
  hazards             TEXT NOT NULL,
  notes_masked        TEXT NOT NULL CHECK (notes_masked !~ '[0-9]{3,}'),   -- an access code can never be stored
  saved_at            TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE delivery_change_log (
  id              SERIAL PRIMARY KEY,
  tracking_number VARCHAR(18) NOT NULL,
  recipient_id    VARCHAR(20),
  action_type     VARCHAR(12) NOT NULL,
  detail          TEXT NOT NULL,
  changed_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Routing table for human-owned requests: team, reply time and (for claims) the claim type routed here.
CREATE TABLE service_teams (
  request_type  VARCHAR(24) PRIMARY KEY,
  team          VARCHAR(60) NOT NULL,
  sla_days      INTEGER NOT NULL,
  label         VARCHAR(60) NOT NULL,              -- plain words: "damaged-parcel claim"
  claim_type    VARCHAR(20) UNIQUE                 -- the damage_claim claim type routed to this team (NULL = none)
);

CREATE SEQUENCE case_seq START 1;
CREATE TABLE service_cases (
  case_id             TEXT PRIMARY KEY DEFAULT 'SC-' || lpad(nextval('case_seq')::text, 5, '0'),
  recipient_id        VARCHAR(20) NOT NULL REFERENCES recipients,
  account_ref         VARCHAR(8)  NOT NULL,
  tracking_number     VARCHAR(18),
  request_type        VARCHAR(24) NOT NULL REFERENCES service_teams,
  recipient_statement TEXT NOT NULL,
  agent_brief         TEXT NOT NULL,            -- neutral summary by the assistant / the damage_claim_agent; never a decision
  requested_amount    NUMERIC(10,2),            -- the claimable amount computed in SQL (NULL = no amount)
  parked_action       VARCHAR(40),              -- runs ONLY on approval: COMPENSATION:<claim_id>
  status              VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at          TIMESTAMP,                -- set by trg_case_defaults from service_teams
  customer_message    TEXT,                     -- recipient-safe outcome text, set by the reviewer's decision
  approved_amount     NUMERIC(10,2),
  decided_at          TIMESTAMP,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE case_seq OWNED BY service_cases.case_id;   -- deterministic SC-00001... after every reset

-- Claims on the recipient's own parcel (damaged / missing contents / lost). Opening one opens its Claims case.
CREATE SEQUENCE claim_seq START 1;
CREATE TABLE damage_claims (
  claim_id             VARCHAR(12) PRIMARY KEY DEFAULT 'CLM-' || lpad(nextval('claim_seq')::text, 5, '0'),
  parcel_id            INTEGER NOT NULL REFERENCES parcels,
  recipient_id         VARCHAR(20) NOT NULL REFERENCES recipients,
  claim_type           VARCHAR(20) NOT NULL CHECK (claim_type IN ('DAMAGED','MISSING_CONTENTS','LOST')),
  packaging_condition  VARCHAR(30) NOT NULL,     -- a claim_guide PACKAGING term (validated; NOT_STATED otherwise)
  cause_category       VARCHAR(30) NOT NULL,     -- a claim_guide CAUSE term (validated; UNKNOWN otherwise)
  claimed_amount       NUMERIC(10,2) NOT NULL,
  declared_value       NUMERIC(10,2) NOT NULL,
  coverage_limit       NUMERIC(10,2) NOT NULL,
  eligible_amount      NUMERIC(10,2) NOT NULL CHECK (eligible_amount > 0),   -- least(claimed, declared, coverage)
  evidence_required    TEXT NOT NULL,            -- from the claim_guide EVIDENCE row of the claim type
  recipient_statement  TEXT NOT NULL,
  agent_notes          TEXT NOT NULL,            -- HIDDEN from recipients: the damage_claim_agent's answer (the case brief)
  ignored_terms        TEXT,                     -- agent terms that are not in claim_guide (recorded, never used)
  case_id              TEXT REFERENCES service_cases,
  created_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE claim_seq OWNED BY damage_claims.claim_id;   -- reset_data.sql RESTART IDENTITY resets it

-- Insert-only decision events (one per case). trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          TEXT NOT NULL UNIQUE REFERENCES service_cases,
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(10,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from recipients
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

-- A reviewer-approved compensation payment (event row, written ONLY by trg_review_decision via compensation_payment_row).
CREATE SEQUENCE comp_seq START 1;
CREATE TABLE compensation_payments (
  payment_id    VARCHAR(12) PRIMARY KEY DEFAULT 'CMP-' || lpad(nextval('comp_seq')::text, 5, '0'),
  claim_id      VARCHAR(12) NOT NULL UNIQUE REFERENCES damage_claims,
  case_id       TEXT NOT NULL UNIQUE REFERENCES service_cases,
  recipient_id  VARCHAR(20) NOT NULL REFERENCES recipients,
  amount        NUMERIC(10,2) NOT NULL CHECK (amount > 0),
  paid_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE comp_seq OWNED BY compensation_payments.payment_id;

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; recipients never see it.
CREATE TABLE agent_audit (
  audit_id    SERIAL PRIMARY KEY,
  at          TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  account_ref VARCHAR(8),
  actor       VARCHAR(20),          -- reviewer id for REVIEWER_VERIFY / CASE_DECIDED
  action      VARCHAR(40) NOT NULL, -- VERIFY_SESSION_ISSUED, REVIEWER_VERIFY, RESCHEDULE_PROPOSED, DELIVERY_CHANGE_EXECUTED,
                                    -- INSTRUCTIONS_PROPOSED, INSTRUCTIONS_SAVED, CLAIM_OPENED, SERVICE_CASE_OPENED,
                                    -- CASE_DECIDED, COMPENSATION_PAID
  ref         TEXT,
  detail      TEXT
);

-- Guarded email requests that passed the SQL check (the flow then sends to To_Email).
CREATE TABLE email_log (
  email_id      SERIAL PRIMARY KEY,
  recipient_id  VARCHAR(20) NOT NULL REFERENCES recipients,
  reference_id  VARCHAR(20) NOT NULL,
  subject       TEXT NOT NULL,
  logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Reference tables of the two new A2A agents (NO personal data: no names, ids, emails, phones, tokens or free text
-- from recipients). Read only through ref_claim_guide() / ref_delivery_instructions(). The same rows are what SQL
-- validates the agents' output against - one source of truth.
-- ---------------------------------------------------------------------
-- damage_claim_agent: claim types, packaging conditions, likely causes, the evidence to send, the claim line.
CREATE TABLE claim_guide (
  entry_id  SERIAL PRIMARY KEY,
  section   VARCHAR(20) NOT NULL CHECK (section IN ('CLAIM_TYPE','PACKAGING','CAUSE','EVIDENCE','CLAIM_LINE','BRIEF_RULE')),
  term      VARCHAR(60) NOT NULL,
  meaning   VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- delivery_instructions_agent + instructions_eval(): the allowed safe places (attended = a person takes the parcel).
CREATE TABLE safe_places (
  place_code  VARCHAR(30) PRIMARY KEY,
  attended    BOOLEAN NOT NULL,
  meaning     VARCHAR(300) NOT NULL
);

-- Risky instructions: any match BLOCKS the save. phrases = the deterministic SQL scan of the recipient's own words.
CREATE TABLE instruction_risk_flags (
  flag_code  VARCHAR(30) PRIMARY KEY,
  phrases    TEXT[] NOT NULL,
  meaning    VARCHAR(300) NOT NULL
);

-- delivery_instructions_agent: hazards, how to mask access codes, the driver line, brief rules.
CREATE TABLE instruction_guide (
  entry_id  SERIAL PRIMARY KEY,
  section   VARCHAR(20) NOT NULL CHECK (section IN ('HAZARD','MASK_RULE','DRIVER_LINE','BRIEF_RULE')),
  term      VARCHAR(60) NOT NULL,
  meaning   VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- =====================================================================
-- RULES
-- =====================================================================

CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$ SELECT upper(trim(coalesce(p, ''))) $$ LANGUAGE sql IMMUTABLE;
-- '$1,234.50' / '1234.5' / ' 35 USD' -> '1234.50'-style text ('' when empty); 'ALL' stays 'ALL'.
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(regexp_replace(coalesce(p, ''), 'usd', '', 'gi'), '[[:space:]$,]', '', 'g'))
$$ LANGUAGE sql IMMUTABLE;
-- ' crushed corner ' / 'outer-damage only' -> 'CRUSHED_CORNER' / 'OUTER_DAMAGE_ONLY'
CREATE OR REPLACE FUNCTION norm_term(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(trim(coalesce(p, '')), '[[:space:]-]+', '_', 'g'))
$$ LANGUAGE sql IMMUTABLE;
-- 'DOG, steps; NONE' -> {DOG, STEPS}   (NONE / empty items dropped)
CREATE OR REPLACE FUNCTION term_list(p TEXT) RETURNS TEXT[] AS $$
  SELECT coalesce(array_agg(DISTINCT t ORDER BY t), '{}')
    FROM (SELECT norm_term(x) AS t FROM regexp_split_to_table(coalesce(p, ''), '[,;|]') x) y
   WHERE t <> '' AND t NOT IN ('NONE', 'N/A', 'NA', 'NO')
$$ LANGUAGE sql IMMUTABLE;
-- Access codes are never stored: every run of 3+ digits becomes [code withheld].
CREATE OR REPLACE FUNCTION mask_codes(p TEXT) RETURNS TEXT AS $$
  SELECT regexp_replace(left(coalesce(p, ''), 500), '[0-9]{3,}', '[code withheld]', 'g')
$$ LANGUAGE sql IMMUTABLE;
-- SWB-4101 / swb4101 / SWB 4101 / 4101 -> SWB-4101
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^[0-9]{4}$' THEN 'SWB-' || d ELSE upper(trim(coalesce(p, ''))) END
    FROM (SELECT regexp_replace(upper(trim(coalesce(p, ''))), '^SWB[[:space:]-]*', '') AS d) x
$$ LANGUAGE sql IMMUTABLE;
-- What a reviewer sees instead of the full name (minimum necessary).
CREATE OR REPLACE FUNCTION recipient_display(p_recipient TEXT) RETURNS TEXT AS $$
  SELECT r.first_name || ' ' || left(r.last_name, 1) || '.' FROM recipients r WHERE r.recipient_id = p_recipient
$$ LANGUAGE sql STABLE;
-- Swiftbound's carrier liability per parcel (the most a claim can pay, whatever the declared value).
CREATE OR REPLACE FUNCTION coverage_limit(p_service_level TEXT) RETURNS NUMERIC AS $$
  SELECT CASE upper(coalesce(p_service_level, '')) WHEN 'EXPRESS' THEN 2500::numeric ELSE 1000::numeric END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION claim_window_days() RETURNS INTEGER AS $$ SELECT 30 $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION lost_after_days() RETURNS INTEGER AS $$ SELECT 3 $$ LANGUAGE sql IMMUTABLE;

-- Constants / helpers
CREATE OR REPLACE FUNCTION high_value_threshold() RETURNS NUMERIC AS $$ SELECT 500::numeric $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION size_rank(s TEXT) RETURNS INTEGER AS $$
  SELECT CASE upper(coalesce(s,'')) WHEN 'SMALL' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LARGE' THEN 3 ELSE 2 END
$$ LANGUAGE sql IMMUTABLE;

-- Identity: a token is valid for its recipient until it expires. ALWAYS returns exactly one row -
-- the recipient when valid, or (null,null) when not - so dependent reads can emit SESSION_INVALID.
-- plpgsql (NOT sql) on purpose: an inlinable SQL function here would merge its LEFT JOINs into the
-- caller's chained LEFT JOINs and mis-bind rows. plpgsql is opaque to the planner.
CREATE OR REPLACE FUNCTION session_recipient(p_token TEXT)
RETURNS TABLE (recipient_id VARCHAR, account_ref VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.recipient_id, r.account_ref
      FROM (SELECT 1) one
      LEFT JOIN recipient_sessions s ON s.session_token = p_token AND s.role = 'RECIPIENT'
                                    AND s.expires_at > clock_timestamp()
      LEFT JOIN recipients r ON r.recipient_id = s.recipient_id;
END $$ LANGUAGE plpgsql STABLE;

-- Throttle: record a verify attempt and return the recipient_id ONLY on a correct, non-locked attempt.
-- Side-effecting (VOLATILE): N wrong PINs for an account ref lock it for a cooldown; a correct PIN clears it.
CREATE OR REPLACE FUNCTION verify_and_record(p_ref TEXT, p_pin TEXT)
RETURNS TABLE (recipient_id VARCHAR) AS $$
DECLARE v_ref TEXT := upper(trim(p_ref)); rc recipients; att verify_attempts; maxn INTEGER := 5;
BEGIN
  SELECT * INTO att FROM verify_attempts WHERE account_ref = v_ref;
  IF att.locked_until IS NOT NULL AND att.locked_until > clock_timestamp() THEN
    RETURN;                                  -- locked: no session, even if the PIN is right
  END IF;
  SELECT * INTO rc FROM recipients WHERE account_ref = v_ref;
  IF FOUND AND rc.verification_pin = trim(p_pin) THEN
    DELETE FROM verify_attempts WHERE account_ref = v_ref;    -- success: clear the counter
    RETURN QUERY SELECT rc.recipient_id; RETURN;
  END IF;
  IF rc.recipient_id IS NOT NULL THEN                   -- track failures only for real account refs
    INSERT INTO verify_attempts (account_ref, attempts, locked_until, updated_at)
      VALUES (v_ref, 1, NULL, clock_timestamp())
      ON CONFLICT (account_ref) DO UPDATE SET attempts = verify_attempts.attempts + 1,
        locked_until = CASE WHEN verify_attempts.attempts + 1 >= maxn THEN clock_timestamp() + INTERVAL '15 minutes' END,
        updated_at = clock_timestamp();
  END IF;
  RETURN;                                             -- no session
END $$ LANGUAGE plpgsql VOLATILE;

-- Verify: account ref + 4-digit PIN -> VERIFIED + token, LOCKED after too many wrong PINs, else NOT_VERIFIED.
CREATE OR REPLACE FUNCTION verify_result(p_ref TEXT, p_pin TEXT)
RETURNS TABLE (status TEXT, session_token TEXT, recipient_name TEXT, account_ref VARCHAR, service_area VARCHAR, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN va.locked_until > clock_timestamp() THEN 'LOCKED'
              WHEN s.session_token IS NULL THEN 'NOT_VERIFIED' ELSE 'VERIFIED' END,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.session_token END,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.recipient_name END,
         coalesce(s.account_ref, upper(trim(p_ref)))::varchar,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.service_area END,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.expires_at END
    FROM (SELECT 1) one
    LEFT JOIN verify_attempts va ON va.account_ref = upper(trim(p_ref))
    LEFT JOIN LATERAL (
      SELECT se.session_token, (r.first_name || ' ' || r.last_name) AS recipient_name,
             r.account_ref, r.service_area, se.expires_at
        FROM recipients r
        JOIN recipient_sessions se ON se.recipient_id = r.recipient_id AND se.expires_at > clock_timestamp()
       WHERE r.account_ref = upper(trim(p_ref)) AND r.verification_pin = trim(p_pin)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- Scoped read: the recipient's own parcels, newest promise first.
CREATE OR REPLACE FUNCTION my_parcels(p_token TEXT)
RETURNS TABLE (session_status TEXT, tracking_number VARCHAR, description VARCHAR, current_status VARCHAR,
               exception_code VARCHAR, exception_label VARCHAR, promised_date DATE, expected_delivery TIMESTAMP,
               destination_area VARCHAR) AS $$
  SELECT CASE WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         pc.tracking_number, pc.description, pc.current_status, pc.exception_code, ec.label,
         pc.promised_date, pc.expected_delivery, pc.destination_area
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN parcels pc ON pc.recipient_id = sr.recipient_id
    LEFT JOIN exception_codes ec ON ec.code = pc.exception_code
   ORDER BY pc.promised_date, pc.tracking_number;
$$ LANGUAGE sql STABLE;

-- Scoped read: one parcel the recipient owns, with the decode-relevant fields and a computed delivery_health.
-- A parcel that is not theirs returns NOT_FOUND (never another recipient's data).
CREATE OR REPLACE FUNCTION parcel_detail(p_token TEXT, p_tracking TEXT)
RETURNS TABLE (lookup_status TEXT, tracking_number VARCHAR, description VARCHAR, sender VARCHAR,
               current_status VARCHAR, exception_code VARCHAR, exception_label VARCHAR, exception_advice VARCHAR,
               delivery_health TEXT, declared_value NUMERIC, parcel_size VARCHAR, signature_required BOOLEAN,
               service_level VARCHAR, destination_area VARCHAR, destination_postcode VARCHAR, promised_date DATE,
               expected_delivery TIMESTAMP, attempts_made INTEGER, earliest_reschedule_date DATE,
               current_slot VARCHAR, current_pickup VARCHAR, saved_safe_place TEXT) AS $$
  SELECT CASE WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID' WHEN pc.parcel_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         pc.tracking_number, pc.description, pc.sender, pc.current_status, pc.exception_code, ec.label, ec.recipient_advice,
         CASE WHEN pc.current_status = 'DELIVERED' THEN 'DELIVERED'
              WHEN pc.current_status = 'RETURNED' THEN 'RETURNED'
              WHEN pc.exception_code IS NOT NULL THEN 'NEEDS_ATTENTION'
              WHEN pc.promised_date < current_date THEN 'LATE'
              ELSE 'ON_TRACK' END,
         pc.declared_value, pc.parcel_size, pc.signature_required, pc.service_level,
         pc.destination_area, pc.destination_postcode, pc.promised_date, pc.expected_delivery, pc.attempts_made,
         current_date AS earliest_reschedule_date,
         (SELECT sl.slot_id || ' (' || to_char(sl.slot_date,'YYYY-MM-DD') || ' '
                 || to_char(sl.window_start,'HH24:MI') || '-' || to_char(sl.window_end,'HH24:MI') || ')'
            FROM delivery_slots sl WHERE sl.slot_id = pc.current_slot_id),
         (SELECT pp.name || ' (' || pp.point_type || ')' FROM pickup_points pp WHERE pp.pickup_id = pc.redirect_pickup_id),
         (SELECT di.safe_place || CASE WHEN di.hazards <> 'NONE' THEN ' (hazards: ' || di.hazards || ')' ELSE '' END
            FROM delivery_instructions di WHERE di.parcel_id = pc.parcel_id ORDER BY di.saved_at DESC LIMIT 1)
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))
    LEFT JOIN exception_codes ec ON ec.code = pc.exception_code;
$$ LANGUAGE sql STABLE;

-- Scoped read: the scan timeline of a parcel the recipient owns.
CREATE OR REPLACE FUNCTION tracking_history(p_token TEXT, p_tracking TEXT)
RETURNS TABLE (lookup_status TEXT, tracking_number VARCHAR, event_at TIMESTAMP, location VARCHAR,
               scan_code VARCHAR, description VARCHAR) AS $$
  SELECT CASE WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID' WHEN pc.parcel_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         pc.tracking_number, ev.event_at, ev.location, ev.scan_code, ev.description
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))
    LEFT JOIN scan_events ev ON ev.parcel_id = pc.parcel_id
   ORDER BY ev.event_at;
$$ LANGUAGE sql STABLE;

-- Agent tool: feasible delivery options for a parcel's area/size/constraints after a date. NO recipient identity.
-- Returns both reschedule SLOTS (not full, not in the past, in-area) and PICKUP points the parcel can actually
-- use (in-area, fits the size, and - for unattended lockers - not signature-required and not high-value).
CREATE OR REPLACE FUNCTION search_delivery_options(p_area TEXT, p_size TEXT, p_needs_sig TEXT, p_high_value TEXT, p_after TEXT)
RETURNS TABLE (option_type TEXT, option_id VARCHAR, title TEXT, detail TEXT, when_available TEXT) AS $$
  SELECT 'SLOT'::TEXT, sl.slot_id,
         'Delivery slot on ' || to_char(sl.slot_date,'Dy YYYY-MM-DD'),
         to_char(sl.window_start,'HH24:MI') || '-' || to_char(sl.window_end,'HH24:MI') || ' in ' || sl.service_area,
         to_char(sl.slot_date,'YYYY-MM-DD') || ' ' || to_char(sl.window_start,'HH24:MI')
    FROM delivery_slots sl
   WHERE sl.service_area = upper(trim(p_area))
     AND sl.slot_date >= greatest(current_date, coalesce(nullif(trim(p_after),'')::date, current_date))
     AND sl.booked_count < sl.capacity
  UNION ALL
  SELECT 'PICKUP'::TEXT, pp.pickup_id,
         pp.name || ' (' || pp.point_type || ')',
         pp.address_line || ' - ' || pp.open_hours,
         'Ready to collect'
    FROM pickup_points pp
   WHERE pp.service_area = upper(trim(p_area))
     AND size_rank(p_size) <= size_rank(pp.max_parcel_size)
     AND NOT (pp.point_type = 'LOCKER' AND lower(coalesce(p_needs_sig,'')) = 'true')
     AND NOT (pp.point_type = 'LOCKER' AND lower(coalesce(p_high_value,'')) = 'true')
   ORDER BY 1, 5
   LIMIT 12;
$$ LANGUAGE sql STABLE;

-- Rule: may this recipient reschedule this parcel onto this slot? Returns ok + a reason to explain verbatim.
CREATE OR REPLACE FUNCTION reschedule_eval(p_token TEXT, p_tracking TEXT, p_slot TEXT)
RETURNS TABLE (ok BOOLEAN, reason TEXT) AS $$
DECLARE sr RECORD; pc parcels; sl delivery_slots;
BEGIN
  SELECT * INTO sr FROM session_recipient(p_token);
  IF sr.recipient_id IS NULL THEN RETURN QUERY SELECT FALSE, 'SESSION_INVALID: identity not verified or session expired. Verify again.'; RETURN; END IF;
  SELECT * INTO pc FROM parcels WHERE tracking_number = upper(trim(p_tracking)) AND recipient_id = sr.recipient_id;
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'NOT_FOUND: no parcel ' || coalesce(p_tracking,'') || ' on this account.'; RETURN; END IF;
  IF pc.current_status IN ('DELIVERED','RETURNED') THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_DELIVERED: parcel ' || pc.tracking_number || ' is ' || pc.current_status || ' and cannot be rescheduled.'; RETURN; END IF;
  IF pc.current_status = 'OUT_FOR_DELIVERY' THEN
    RETURN QUERY SELECT FALSE, 'OUT_FOR_FINAL: ' || pc.tracking_number || ' is already out for delivery today and cannot be rescheduled now.'; RETURN; END IF;
  SELECT * INTO sl FROM delivery_slots WHERE slot_id = upper(trim(p_slot));
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'SLOT_UNKNOWN: no delivery slot ' || coalesce(p_slot,'') || '.'; RETURN; END IF;
  IF sl.slot_id = pc.current_slot_id THEN
    RETURN QUERY SELECT FALSE, 'SAME_SLOT: the parcel is already scheduled for ' || sl.slot_id || '.'; RETURN; END IF;
  IF sl.slot_date < current_date THEN
    RETURN QUERY SELECT FALSE, 'SLOT_IN_PAST: ' || sl.slot_id || ' is on ' || to_char(sl.slot_date,'YYYY-MM-DD') || ', which is in the past.'; RETURN; END IF;
  IF sl.service_area <> pc.destination_area THEN
    RETURN QUERY SELECT FALSE, 'SLOT_WRONG_AREA: ' || sl.slot_id || ' serves ' || sl.service_area || ', not ' || pc.destination_area || '.'; RETURN; END IF;
  IF sl.booked_count >= sl.capacity THEN
    RETURN QUERY SELECT FALSE, 'SLOT_FULL: ' || sl.slot_id || ' has no capacity left.'; RETURN; END IF;
  RETURN QUERY SELECT TRUE, 'ELIGIBLE'::TEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Rule: may this recipient redirect this parcel to this pickup point?
CREATE OR REPLACE FUNCTION redirect_eval(p_token TEXT, p_tracking TEXT, p_pickup TEXT)
RETURNS TABLE (ok BOOLEAN, reason TEXT) AS $$
DECLARE sr RECORD; pc parcels; pp pickup_points;
BEGIN
  SELECT * INTO sr FROM session_recipient(p_token);
  IF sr.recipient_id IS NULL THEN RETURN QUERY SELECT FALSE, 'SESSION_INVALID: identity not verified or session expired. Verify again.'; RETURN; END IF;
  SELECT * INTO pc FROM parcels WHERE tracking_number = upper(trim(p_tracking)) AND recipient_id = sr.recipient_id;
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'NOT_FOUND: no parcel ' || coalesce(p_tracking,'') || ' on this account.'; RETURN; END IF;
  IF pc.current_status IN ('DELIVERED','RETURNED') THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_DELIVERED: parcel ' || pc.tracking_number || ' is ' || pc.current_status || ' and cannot be redirected.'; RETURN; END IF;
  IF pc.current_status = 'OUT_FOR_DELIVERY' THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_OUT: ' || pc.tracking_number || ' is already out for delivery today and can no longer be redirected.'; RETURN; END IF;
  SELECT * INTO pp FROM pickup_points WHERE pickup_id = upper(trim(p_pickup));
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'PICKUP_UNKNOWN: no pickup point ' || coalesce(p_pickup,'') || '.'; RETURN; END IF;
  IF pp.service_area <> pc.destination_area THEN
    RETURN QUERY SELECT FALSE, 'PICKUP_OUT_OF_AREA: ' || pp.pickup_id || ' is in ' || pp.service_area || ', which does not serve ' || pc.destination_area || '.'; RETURN; END IF;
  IF size_rank(pc.parcel_size) > size_rank(pp.max_parcel_size) THEN
    RETURN QUERY SELECT FALSE, 'OVERSIZE_FOR_LOCKER: a ' || pc.parcel_size || ' parcel does not fit ' || pp.pickup_id || ' (max ' || pp.max_parcel_size || ').'; RETURN; END IF;
  IF pp.point_type = 'LOCKER' AND pc.signature_required THEN
    RETURN QUERY SELECT FALSE, 'SIGNATURE_REQUIRED: ' || pc.tracking_number || ' needs a signature, so it cannot go to the unattended locker ' || pp.pickup_id || '. Choose a staffed shop.'; RETURN; END IF;
  IF pp.point_type = 'LOCKER' AND pc.declared_value > high_value_threshold() THEN
    RETURN QUERY SELECT FALSE, 'HIGH_VALUE_LOCKER: ' || pc.tracking_number || ' is over the ' || high_value_threshold() || ' value limit for an unattended locker. Choose a staffed shop.'; RETURN; END IF;
  RETURN QUERY SELECT TRUE, 'ELIGIBLE'::TEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Side effect: a confirmed delivery change applies atomically and writes the log.
CREATE OR REPLACE FUNCTION apply_delivery_change() RETURNS TRIGGER AS $$
DECLARE pc parcels; sl delivery_slots; pp pickup_points; rid VARCHAR;
BEGIN
  SELECT * INTO pc FROM parcels WHERE parcel_id = NEW.parcel_id;
  rid := pc.recipient_id;
  IF NEW.action_type = 'RESCHEDULE' THEN
    SELECT * INTO sl FROM delivery_slots WHERE slot_id = NEW.slot_id;
    UPDATE parcels SET current_slot_id = NEW.slot_id, current_status = 'RESCHEDULED', exception_code = NULL,
           expected_delivery = sl.slot_date + sl.window_start, last_scan_at = clock_timestamp()
     WHERE parcel_id = NEW.parcel_id;
    UPDATE delivery_slots SET booked_count = booked_count + 1 WHERE slot_id = NEW.slot_id;
    INSERT INTO delivery_change_log (tracking_number, recipient_id, action_type, detail)
      VALUES (pc.tracking_number, rid, 'RESCHEDULE', 'Rescheduled to ' || NEW.slot_id
              || ' (' || to_char(sl.slot_date,'YYYY-MM-DD') || ' ' || to_char(sl.window_start,'HH24:MI') || ')');
  ELSIF NEW.action_type = 'REDIRECT' THEN
    SELECT * INTO pp FROM pickup_points WHERE pickup_id = NEW.pickup_id;
    UPDATE parcels SET redirect_pickup_id = NEW.pickup_id, current_status = 'REDIRECTED', exception_code = NULL,
           last_scan_at = clock_timestamp()
     WHERE parcel_id = NEW.parcel_id;
    INSERT INTO delivery_change_log (tracking_number, recipient_id, action_type, detail)
      VALUES (pc.tracking_number, rid, 'REDIRECT', 'Redirected to ' || NEW.pickup_id || ' (' || pp.name || ')');
  END IF;
  UPDATE pending_actions SET status = 'EXECUTED' WHERE action_id = NEW.action_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_delivery_change AFTER INSERT ON delivery_changes FOR EACH ROW EXECUTE FUNCTION apply_delivery_change();

-- Guarded write rows: a pending action is written ONLY when every rule passes (and no duplicate is pending).
CREATE OR REPLACE FUNCTION reschedule_proposal_row(p_token TEXT, p_tracking TEXT, p_slot TEXT)
RETURNS TABLE (action_type VARCHAR, parcel_id INTEGER, slot_id VARCHAR) AS $$
  SELECT 'RESCHEDULE'::VARCHAR, pc.parcel_id, upper(trim(p_slot))::VARCHAR
    FROM session_recipient(p_token) sr
    JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))
    CROSS JOIN LATERAL reschedule_eval(p_token, p_tracking, p_slot) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.parcel_id = pc.parcel_id AND pa.action_type = 'RESCHEDULE'
                        AND pa.slot_id = upper(trim(p_slot)) AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_reschedule_result(p_token TEXT, p_tracking TEXT, p_slot TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, action_id TEXT, tracking_number VARCHAR, slot_id VARCHAR,
               slot_date DATE, slot_window TEXT, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN pa.action_id IS NOT NULL THEN 'PROPOSED' ELSE 'NOT_PROPOSED' END,
         CASE WHEN pa.action_id IS NOT NULL THEN 'Awaiting the recipient''s explicit confirmation. Nothing has changed yet.' ELSE e.reason END,
         pa.action_id, upper(trim(p_tracking))::varchar, pa.slot_id, sl.slot_date,
         (to_char(sl.window_start,'HH24:MI') || '-' || to_char(sl.window_end,'HH24:MI')), pa.expires_at
    FROM reschedule_eval(p_token, p_tracking, p_slot) e
    LEFT JOIN LATERAL (
      SELECT p.* FROM session_recipient(p_token) sr
       JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))
       JOIN pending_actions p ON p.parcel_id = pc.parcel_id AND p.action_type = 'RESCHEDULE'
        AND p.slot_id = upper(trim(p_slot)) AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
       WHERE e.ok ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
    LEFT JOIN delivery_slots sl ON sl.slot_id = pa.slot_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION reschedule_confirm_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, parcel_id INTEGER, action_type VARCHAR, slot_id VARCHAR) AS $$
  SELECT pa.action_id, pa.parcel_id, pa.action_type, pa.slot_id
    FROM session_recipient(p_token) sr
    JOIN parcels pc ON pc.recipient_id = sr.recipient_id
    JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.parcel_id = pc.parcel_id AND pa.action_type = 'RESCHEDULE'
    CROSS JOIN LATERAL reschedule_eval(p_token, pc.tracking_number, pa.slot_id) e
   WHERE pa.status = 'PENDING' AND pa.expires_at > clock_timestamp() AND e.ok;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION redirect_proposal_row(p_token TEXT, p_tracking TEXT, p_pickup TEXT)
RETURNS TABLE (action_type VARCHAR, parcel_id INTEGER, pickup_id VARCHAR) AS $$
  SELECT 'REDIRECT'::VARCHAR, pc.parcel_id, upper(trim(p_pickup))::VARCHAR
    FROM session_recipient(p_token) sr
    JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))
    CROSS JOIN LATERAL redirect_eval(p_token, p_tracking, p_pickup) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.parcel_id = pc.parcel_id AND pa.action_type = 'REDIRECT'
                        AND pa.pickup_id = upper(trim(p_pickup)) AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_redirect_result(p_token TEXT, p_tracking TEXT, p_pickup TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, action_id TEXT, tracking_number VARCHAR, pickup_id VARCHAR,
               pickup_name VARCHAR, point_type VARCHAR, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN pa.action_id IS NOT NULL THEN 'PROPOSED' ELSE 'NOT_PROPOSED' END,
         CASE WHEN pa.action_id IS NOT NULL THEN 'Awaiting the recipient''s explicit confirmation. Nothing has changed yet.' ELSE e.reason END,
         pa.action_id, upper(trim(p_tracking))::varchar, pa.pickup_id, pp.name, pp.point_type, pa.expires_at
    FROM redirect_eval(p_token, p_tracking, p_pickup) e
    LEFT JOIN LATERAL (
      SELECT p.* FROM session_recipient(p_token) sr
       JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))
       JOIN pending_actions p ON p.parcel_id = pc.parcel_id AND p.action_type = 'REDIRECT'
        AND p.pickup_id = upper(trim(p_pickup)) AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
       WHERE e.ok ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
    LEFT JOIN pickup_points pp ON pp.pickup_id = pa.pickup_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION redirect_confirm_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, parcel_id INTEGER, action_type VARCHAR, pickup_id VARCHAR) AS $$
  SELECT pa.action_id, pa.parcel_id, pa.action_type, pa.pickup_id
    FROM session_recipient(p_token) sr
    JOIN parcels pc ON pc.recipient_id = sr.recipient_id
    JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.parcel_id = pc.parcel_id AND pa.action_type = 'REDIRECT'
    CROSS JOIN LATERAL redirect_eval(p_token, pc.tracking_number, pa.pickup_id) e
   WHERE pa.status = 'PENDING' AND pa.expires_at > clock_timestamp() AND e.ok;
$$ LANGUAGE sql STABLE;

-- Unified confirm readback (works for either action type via the pending action).
CREATE OR REPLACE FUNCTION confirm_change_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, tracking_number VARCHAR, action_type VARCHAR, target TEXT,
               changed_at TIMESTAMP) AS $$
  SELECT CASE WHEN dc.change_id IS NOT NULL THEN 'EXECUTED' ELSE 'NOT_EXECUTED' END,
         CASE WHEN dc.change_id IS NOT NULL THEN 'Delivery change completed.'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no pending action with that id on this account.'
              WHEN pa.expires_at <= clock_timestamp() THEN 'EXPIRED: the proposal expired. Propose the change again.'
              WHEN pa.action_type = 'RESCHEDULE' THEN (SELECT e.reason FROM reschedule_eval(p_token, pc.tracking_number, pa.slot_id) e)
              ELSE (SELECT e.reason FROM redirect_eval(p_token, pc.tracking_number, pa.pickup_id) e) END,
         pc.tracking_number, pa.action_type,
         CASE WHEN pa.action_type = 'RESCHEDULE' THEN pa.slot_id ELSE pa.pickup_id END,
         dc.changed_at
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN pending_actions pa ON pa.action_id = upper(trim(p_action))
         AND EXISTS (SELECT 1 FROM parcels pc2 WHERE pc2.parcel_id = pa.parcel_id AND pc2.recipient_id = sr.recipient_id)
    LEFT JOIN parcels pc ON pc.parcel_id = pa.parcel_id
    LEFT JOIN delivery_changes dc ON dc.action_id = pa.action_id;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Human-owned requests -> routed to a team by the table, never decided by the LLM.
-- ---------------------------------------------------------------------
-- Every case gets its reply-due time from the routing table (also cases opened by triggers and seeds).
CREATE OR REPLACE FUNCTION case_defaults() RETURNS TRIGGER AS $$
DECLARE t service_teams;
BEGIN
  SELECT * INTO t FROM service_teams WHERE request_type = NEW.request_type;
  NEW.sla_due_at := coalesce(NEW.sla_due_at, add_business_days(NEW.created_at::date, t.sla_days) + NEW.created_at::time);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION case_defaults();

CREATE OR REPLACE FUNCTION service_case_row(p_token TEXT, p_type TEXT, p_tracking TEXT, p_statement TEXT, p_brief TEXT)
RETURNS TABLE (recipient_id VARCHAR, account_ref VARCHAR, tracking_number VARCHAR, request_type VARCHAR,
               recipient_statement TEXT, agent_brief TEXT) AS $$
  SELECT sr.recipient_id, sr.account_ref,
         (SELECT pc.tracking_number FROM parcels pc WHERE pc.recipient_id = sr.recipient_id AND pc.tracking_number = upper(trim(p_tracking))),
         t.request_type, left(coalesce(p_statement,''),4000), left(coalesce(p_brief,''),4000)
    FROM (SELECT * FROM session_recipient(p_token)) sr
    JOIN service_teams t ON t.request_type = upper(trim(p_type))
   WHERE sr.recipient_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM service_cases sc
                      WHERE sc.recipient_id = sr.recipient_id AND sc.request_type = t.request_type
                        AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, status VARCHAR, created_at TIMESTAMP, reply_by DATE) AS $$
  SELECT CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'A person on the assigned team will review and reply. The assistant has not decided anything.'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              ELSE 'BAD_REQUEST_TYPE: use LOST_PARCEL, DAMAGED_PARCEL, MISSING_ITEMS, WRONG_DELIVERY, DELIVERY_COMPLAINT or OTHER.' END,
         c.case_id, c.request_type, t.team, t.sla_days, c.status, c.created_at, c.sla_due_at::date
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT sc.* FROM service_cases sc
       WHERE sc.recipient_id = sr.recipient_id AND sc.request_type = upper(trim(p_type))
         AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes'
       ORDER BY sc.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The recipient's own cases (service cases and claims): status + the recipient-safe outcome once a person decided.
-- Never the internal note, the AI brief, the reviewer or how the amount was worked out beyond the claimable amount.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_id TEXT, claim_id VARCHAR, request_type VARCHAR, tracking_number VARCHAR,
               assigned_team VARCHAR, status VARCHAR, amount_under_review NUMERIC, approved_amount NUMERIC,
               compensation_paid NUMERIC, customer_message TEXT, reply_by DATE, decided_on DATE, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_id, dc.claim_id, c.request_type, c.tracking_number, t.team, c.status, c.requested_amount, c.approved_amount,
         cp.amount, c.customer_message, c.sla_due_at::date, c.decided_at::date, c.created_at
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN service_cases c ON c.recipient_id = sr.recipient_id
    LEFT JOIN service_teams t ON t.request_type = c.request_type
    LEFT JOIN damage_claims dc ON dc.case_id = c.case_id
    LEFT JOIN compensation_payments cp ON cp.case_id = c.case_id
   ORDER BY c.created_at DESC;
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- CLAIMS (damage_claim_agent): damaged / missing contents / lost, on the recipient's OWN parcel.
-- The agent's claim type, packaging and cause are validated against claim_guide; the claimable amount is computed
-- here (least of the claimed amount, the declared value and the coverage limit); compensation is decided by a person.
-- =====================================================================
CREATE OR REPLACE FUNCTION claim_eval(p_recipient TEXT, p_tracking TEXT, p_type TEXT, p_amount TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT) AS $$
DECLARE pc parcels; v_type TEXT := norm_term(p_type); v_amt TEXT := norm_amount(p_amount);
BEGIN
  IF p_recipient IS NULL THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'SESSION_INVALID: identity not verified or session expired. Verify again.'; RETURN; END IF;
  SELECT * INTO pc FROM parcels x WHERE x.tracking_number = norm_ref(p_tracking) AND x.recipient_id = p_recipient;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_FOUND', 'NOT_FOUND: no parcel ' || coalesce(p_tracking,'') || ' on this account.'; RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM claim_guide g WHERE g.section = 'CLAIM_TYPE' AND g.term = v_type) THEN
    RETURN QUERY SELECT FALSE, 'BAD_CLAIM_TYPE', 'BAD_CLAIM_TYPE: the claim type must be DAMAGED, MISSING_CONTENTS or LOST.'; RETURN; END IF;
  IF EXISTS (SELECT 1 FROM damage_claims c JOIN service_cases s ON s.case_id = c.case_id
              WHERE c.parcel_id = pc.parcel_id AND s.status <> 'REJECTED') THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_CLAIMED', 'ALREADY_CLAIMED: a claim for ' || pc.tracking_number || ' is already with the claims team.'; RETURN; END IF;
  IF v_type = 'DAMAGED' AND NOT (pc.current_status = 'DELIVERED' OR coalesce(pc.exception_code, '') = 'DMG') THEN
    RETURN QUERY SELECT FALSE, 'NOT_DELIVERED_YET', 'NOT_DELIVERED_YET: ' || pc.tracking_number
      || ' has not been delivered and no damage was reported in transit, so a damage claim cannot be opened yet.'; RETURN; END IF;
  IF v_type = 'MISSING_CONTENTS' AND pc.current_status <> 'DELIVERED' THEN
    RETURN QUERY SELECT FALSE, 'NOT_DELIVERED_YET', 'NOT_DELIVERED_YET: ' || pc.tracking_number
      || ' has not been delivered yet, so a missing-contents claim cannot be opened.'; RETURN; END IF;
  IF v_type = 'LOST' AND pc.current_status = 'DELIVERED' THEN
    RETURN QUERY SELECT FALSE, 'DELIVERED_NOT_LOST', 'DELIVERED_NOT_LOST: tracking shows ' || pc.tracking_number
      || ' as delivered. If it never reached you, a wrong-delivery investigation (WRONG_DELIVERY) is the right request.'; RETURN; END IF;
  IF v_type = 'LOST' AND pc.current_status = 'RETURNED' THEN
    RETURN QUERY SELECT FALSE, 'RETURNED_TO_SENDER', 'RETURNED_TO_SENDER: ' || pc.tracking_number
      || ' was returned to the sender, so it is not lost. Please contact the sender.'; RETURN; END IF;
  IF v_type = 'LOST' AND pc.promised_date > current_date - lost_after_days() THEN
    RETURN QUERY SELECT FALSE, 'NOT_YET_LOST', 'NOT_YET_LOST: ' || pc.tracking_number || ' was promised for '
      || to_char(pc.promised_date, 'YYYY-MM-DD') || '; a parcel can be claimed as lost ' || lost_after_days()
      || ' days after its promised date.'; RETURN; END IF;
  IF pc.current_status = 'DELIVERED'
     AND coalesce(pc.expected_delivery::date, pc.promised_date) < current_date - claim_window_days() THEN
    RETURN QUERY SELECT FALSE, 'CLAIM_WINDOW_CLOSED', 'CLAIM_WINDOW_CLOSED: claims must be made within ' || claim_window_days()
      || ' days of delivery, and ' || pc.tracking_number || ' was delivered on '
      || to_char(coalesce(pc.expected_delivery::date, pc.promised_date), 'YYYY-MM-DD') || '.'; RETURN; END IF;
  IF v_amt NOT IN ('', 'ALL', 'FULL') AND (v_amt !~ '^[0-9]+(\.[0-9]+)?$' OR v_amt::numeric <= 0) THEN
    RETURN QUERY SELECT FALSE, 'BAD_AMOUNT', 'BAD_AMOUNT: the claimed amount must be a positive dollar amount (or empty for the declared value).'; RETURN; END IF;
  IF pc.declared_value <= 0 THEN
    RETURN QUERY SELECT FALSE, 'NO_DECLARED_VALUE', 'NO_DECLARED_VALUE: ' || pc.tracking_number
      || ' has no declared value, so the claims team must review it - open a service case instead.'; RETURN; END IF;
  RETURN QUERY SELECT TRUE, 'ELIGIBLE', 'ELIGIBLE';
END $$ LANGUAGE plpgsql STABLE;

-- The claim row (token-free core, also used by the seed data): only when claim_eval passes.
CREATE OR REPLACE FUNCTION claim_row_for(p_recipient TEXT, p_tracking TEXT, p_type TEXT, p_packaging TEXT, p_cause TEXT,
                                         p_amount TEXT, p_statement TEXT, p_notes TEXT)
RETURNS TABLE (parcel_id INTEGER, recipient_id VARCHAR, claim_type VARCHAR, packaging_condition VARCHAR,
               cause_category VARCHAR, claimed_amount NUMERIC, declared_value NUMERIC, coverage_limit NUMERIC,
               eligible_amount NUMERIC, evidence_required TEXT, recipient_statement TEXT, agent_notes TEXT,
               ignored_terms TEXT) AS $$
  SELECT pc.parcel_id, pc.recipient_id, norm_term(p_type)::varchar,
         coalesce(pk.term, 'NOT_STATED')::varchar, coalesce(cs.term, 'UNKNOWN')::varchar,
         x.claimed, pc.declared_value, coverage_limit(pc.service_level),
         least(x.claimed, pc.declared_value, coverage_limit(pc.service_level)),
         ev.meaning::text, left(coalesce(p_statement, ''), 4000), left(coalesce(p_notes, ''), 4000),
         nullif(concat_ws(', ',
           CASE WHEN pk.term IS NULL AND norm_term(p_packaging) NOT IN ('', 'NONE') THEN 'packaging=' || norm_term(p_packaging) END,
           CASE WHEN cs.term IS NULL AND norm_term(p_cause) NOT IN ('', 'NONE') THEN 'cause=' || norm_term(p_cause) END), '')
    FROM parcels pc
    CROSS JOIN LATERAL claim_eval(p_recipient, p_tracking, p_type, p_amount) e
    CROSS JOIN LATERAL (SELECT CASE WHEN norm_amount(p_amount) IN ('', 'ALL', 'FULL') THEN pc.declared_value
                                    WHEN norm_amount(p_amount) ~ '^[0-9]+(\.[0-9]+)?$' THEN round(norm_amount(p_amount)::numeric, 2)
                               END AS claimed) x
    LEFT JOIN claim_guide pk ON pk.section = 'PACKAGING' AND pk.term = norm_term(p_packaging)
    LEFT JOIN claim_guide cs ON cs.section = 'CAUSE' AND cs.term = norm_term(p_cause)
    LEFT JOIN claim_guide ev ON ev.section = 'EVIDENCE' AND ev.term = norm_term(p_type)
   WHERE pc.recipient_id = p_recipient AND pc.tracking_number = norm_ref(p_tracking) AND e.ok;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for the open_damage_claim tool: the session's recipient only.
CREATE OR REPLACE FUNCTION damage_claim_row(p_token TEXT, p_tracking TEXT, p_type TEXT, p_packaging TEXT, p_cause TEXT,
                                            p_amount TEXT, p_statement TEXT, p_notes TEXT)
RETURNS TABLE (parcel_id INTEGER, recipient_id VARCHAR, claim_type VARCHAR, packaging_condition VARCHAR,
               cause_category VARCHAR, claimed_amount NUMERIC, declared_value NUMERIC, coverage_limit NUMERIC,
               eligible_amount NUMERIC, evidence_required TEXT, recipient_statement TEXT, agent_notes TEXT,
               ignored_terms TEXT) AS $$
  SELECT c.* FROM (SELECT * FROM session_recipient(p_token)) sr
   CROSS JOIN LATERAL claim_row_for(sr.recipient_id, p_tracking, p_type, p_packaging, p_cause, p_amount, p_statement, p_notes) c
   WHERE sr.recipient_id IS NOT NULL;
$$ LANGUAGE sql STABLE;

-- Opening a claim opens its Claims case (routed by service_teams.claim_type) and parks the compensation payment.
CREATE OR REPLACE FUNCTION open_claim_case() RETURNS TRIGGER AS $$
DECLARE t service_teams; pc parcels; r recipients;
BEGIN
  SELECT * INTO t FROM service_teams WHERE claim_type = NEW.claim_type;
  SELECT * INTO pc FROM parcels WHERE parcel_id = NEW.parcel_id;
  SELECT * INTO r FROM recipients WHERE recipient_id = NEW.recipient_id;
  INSERT INTO service_cases (recipient_id, account_ref, tracking_number, request_type, recipient_statement, agent_brief,
                             requested_amount, parked_action)
    VALUES (NEW.recipient_id, r.account_ref, pc.tracking_number, t.request_type, NEW.recipient_statement,
            CASE WHEN trim(NEW.agent_notes) <> '' THEN NEW.agent_notes ELSE 'No AI brief was provided.' END,
            NEW.eligible_amount, 'COMPENSATION:' || NEW.claim_id)
    RETURNING case_id INTO NEW.case_id;
  INSERT INTO agent_audit (account_ref, action, ref, detail)
    VALUES (r.account_ref, 'CLAIM_OPENED', NEW.claim_id,
            NEW.claim_type || ' on ' || pc.tracking_number || ', claimable ' || usd(NEW.eligible_amount) || ' -> case ' || NEW.case_id);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_claim_case BEFORE INSERT ON damage_claims FOR EACH ROW EXECUTE FUNCTION open_claim_case();

CREATE OR REPLACE FUNCTION damage_claim_result(p_token TEXT, p_tracking TEXT, p_type TEXT, p_amount TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, claim_id VARCHAR, case_id TEXT, tracking_number VARCHAR,
               claim_type VARCHAR, assigned_team VARCHAR, reply_by DATE, claimed_amount NUMERIC,
               amount_under_review NUMERIC, amount_note TEXT, evidence_to_send TEXT, next_step TEXT) AS $$
  SELECT CASE WHEN c.claim_id IS NULL THEN 'NOT_OPENED'
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CLAIM_OPENED' ELSE 'ALREADY_OPEN' END,
         CASE WHEN c.claim_id IS NULL THEN e.reason_code
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CLAIM_OPENED' ELSE 'ALREADY_OPEN' END,
         CASE WHEN c.claim_id IS NULL THEN e.reason
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                THEN 'Claim recorded and sent to the claims team. A person decides the claim and any compensation; the assistant has not decided or promised anything.'
              ELSE 'A claim for this parcel is already open with the claims team, so no new claim was opened. A person will decide it.' END,
         c.claim_id, c.case_id, pc.tracking_number, c.claim_type, t.team, s.sla_due_at::date, c.claimed_amount, c.eligible_amount,
         CASE WHEN c.claim_id IS NULL THEN NULL
              WHEN c.eligible_amount < c.claimed_amount AND c.eligible_amount = c.declared_value
                THEN 'Capped at the parcel''s declared value of ' || usd(c.declared_value) || '.'
              WHEN c.eligible_amount < c.claimed_amount
                THEN 'Capped at Swiftbound''s ' || usd(c.coverage_limit) || ' coverage limit for this service.'
              ELSE 'The full claimed amount is under review.' END,
         c.evidence_required,
         CASE WHEN c.claim_id IS NOT NULL THEN 'Send the evidence listed and keep the item and all of its packaging until a person has decided the claim.' END
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = norm_ref(p_tracking)
    LEFT JOIN LATERAL (SELECT x.* FROM damage_claims x JOIN service_cases y ON y.case_id = x.case_id
                        WHERE x.parcel_id = pc.parcel_id AND y.status <> 'REJECTED'
                        ORDER BY x.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_cases s ON s.case_id = c.case_id
    LEFT JOIN service_teams t ON t.request_type = s.request_type
    CROSS JOIN LATERAL claim_eval(sr.recipient_id, p_tracking, p_type, p_amount) e;
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- DELIVERY INSTRUCTIONS (delivery_instructions_agent): safe place, access-code flag, hazards - two steps.
-- The safe place must be in safe_places; risky instructions (the agent's flags validated against
-- instruction_risk_flags, PLUS a SQL phrase scan of the recipient's own words) block the save; signature-required
-- parcels may only be handed over, high-value parcels only to an attended place. Access codes are never stored.
-- =====================================================================
CREATE OR REPLACE FUNCTION risk_flags_found(p_flags TEXT, p_text TEXT) RETURNS TEXT[] AS $$
  SELECT coalesce(array_agg(f.flag_code::text ORDER BY f.flag_code), '{}')
    FROM instruction_risk_flags f
   WHERE f.flag_code = ANY (term_list(p_flags))
      OR EXISTS (SELECT 1 FROM unnest(f.phrases) ph WHERE strpos(lower(coalesce(p_text, '')), ph) > 0)
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION access_code_flag(p_flag TEXT, p_text TEXT) RETURNS BOOLEAN AS $$
  SELECT upper(trim(coalesce(p_flag, ''))) IN ('YES', 'TRUE', 'Y')
      OR (coalesce(p_text, '') ~* '(code|pin|keypad|passcode|combination)' AND coalesce(p_text, '') ~ '[0-9]{3,}')
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION hazards_valid(p TEXT) RETURNS TEXT AS $$
  SELECT coalesce(nullif(array_to_string(ARRAY(
           SELECT h FROM unnest(term_list(p)) h
            WHERE EXISTS (SELECT 1 FROM instruction_guide g WHERE g.section = 'HAZARD' AND g.term = h) ORDER BY h), ', '), ''),
         'NONE')
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION instructions_eval(p_token TEXT, p_tracking TEXT, p_place TEXT, p_flags TEXT, p_text TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT) AS $$
DECLARE sr RECORD; pc parcels; sp safe_places; v_flags TEXT[];
BEGIN
  SELECT * INTO sr FROM session_recipient(p_token);
  IF sr.recipient_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'SESSION_INVALID: identity not verified or session expired. Verify again.'; RETURN; END IF;
  SELECT * INTO pc FROM parcels x WHERE x.tracking_number = norm_ref(p_tracking) AND x.recipient_id = sr.recipient_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_FOUND', 'NOT_FOUND: no parcel ' || coalesce(p_tracking,'') || ' on this account.'; RETURN; END IF;
  IF pc.current_status IN ('DELIVERED','RETURNED') THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_DELIVERED', 'ALREADY_DELIVERED: parcel ' || pc.tracking_number || ' is '
      || pc.current_status || ', so delivery instructions no longer apply.'; RETURN; END IF;
  IF pc.current_status = 'REDIRECTED' THEN
    RETURN QUERY SELECT FALSE, 'REDIRECTED_TO_PICKUP', 'REDIRECTED_TO_PICKUP: ' || pc.tracking_number
      || ' is going to a pickup point, so doorstep instructions do not apply.'; RETURN; END IF;
  v_flags := risk_flags_found(p_flags, p_text);
  IF cardinality(v_flags) > 0 THEN
    RETURN QUERY SELECT FALSE, 'RISKY_INSTRUCTION', 'RISKY_INSTRUCTION: these instructions cannot be saved. '
      || (SELECT string_agg(f.meaning, ' ' ORDER BY f.flag_code) FROM instruction_risk_flags f WHERE f.flag_code = ANY (v_flags))
      || ' Choose a safe place at the address, or redirect the parcel to a pickup point.'; RETURN; END IF;
  SELECT * INTO sp FROM safe_places x WHERE x.place_code = norm_term(p_place);
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SAFE_PLACE_UNKNOWN', 'SAFE_PLACE_UNKNOWN: ' || coalesce(nullif(trim(p_place), ''), '(none)')
      || ' is not one of Swiftbound''s safe places: '
      || (SELECT string_agg(x.place_code, ', ' ORDER BY x.place_code) FROM safe_places x) || '.'; RETURN; END IF;
  IF pc.signature_required AND sp.place_code <> 'HAND_TO_RECIPIENT' THEN
    RETURN QUERY SELECT FALSE, 'SIGNATURE_REQUIRED', 'SIGNATURE_REQUIRED: ' || pc.tracking_number
      || ' needs a signature, so it can only be handed to you (HAND_TO_RECIPIENT), not left at ' || sp.place_code
      || '. You can also redirect it to a staffed shop.'; RETURN; END IF;
  IF pc.declared_value > high_value_threshold() AND NOT sp.attended THEN
    RETURN QUERY SELECT FALSE, 'HIGH_VALUE_SAFE_PLACE', 'HIGH_VALUE_SAFE_PLACE: ' || pc.tracking_number || ' is over the '
      || usd(high_value_threshold()) || ' value limit for leaving a parcel unattended. Choose HAND_TO_RECIPIENT or '
      || 'BUILDING_RECEPTION, or redirect it to a staffed shop.'; RETURN; END IF;
  RETURN QUERY SELECT TRUE, 'ELIGIBLE', 'ELIGIBLE';
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION instructions_proposal_row(p_token TEXT, p_tracking TEXT, p_place TEXT, p_code_flag TEXT,
                                                     p_hazards TEXT, p_flags TEXT, p_text TEXT, p_notes TEXT)
RETURNS TABLE (action_type VARCHAR, parcel_id INTEGER, safe_place VARCHAR, access_code_present BOOLEAN, hazards TEXT,
               notes_masked TEXT, agent_notes TEXT) AS $$
  SELECT 'INSTRUCTIONS'::varchar, pc.parcel_id, norm_term(p_place)::varchar, access_code_flag(p_code_flag, p_text),
         hazards_valid(p_hazards), mask_codes(p_text), mask_codes(left(coalesce(p_notes, ''), 2000))
    FROM session_recipient(p_token) sr
    JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = norm_ref(p_tracking)
    CROSS JOIN LATERAL instructions_eval(p_token, p_tracking, p_place, p_flags, p_text) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.parcel_id = pc.parcel_id AND pa.action_type = 'INSTRUCTIONS'
                        AND pa.safe_place = norm_term(p_place) AND pa.notes_masked = mask_codes(p_text)
                        AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_instructions_result(p_token TEXT, p_tracking TEXT, p_place TEXT, p_flags TEXT, p_text TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, action_id TEXT, tracking_number VARCHAR, safe_place VARCHAR,
               safe_place_meaning TEXT, access_code_present BOOLEAN, hazards TEXT, driver_note TEXT,
               expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN pa.action_id IS NOT NULL THEN 'PROPOSED' ELSE 'NOT_PROPOSED' END,
         CASE WHEN pa.action_id IS NOT NULL THEN 'PROPOSED' ELSE e.reason_code END,
         CASE WHEN pa.action_id IS NOT NULL
              THEN 'Awaiting the recipient''s explicit confirmation. Nothing has been saved yet. Access codes are never stored.'
              ELSE e.reason END,
         pa.action_id, norm_ref(p_tracking)::varchar, pa.safe_place, sp.meaning::text, pa.access_code_present, pa.hazards,
         pa.notes_masked, pa.expires_at
    FROM instructions_eval(p_token, p_tracking, p_place, p_flags, p_text) e
    LEFT JOIN LATERAL (
      SELECT p.* FROM session_recipient(p_token) sr
       JOIN parcels pc ON pc.recipient_id = sr.recipient_id AND pc.tracking_number = norm_ref(p_tracking)
       JOIN pending_actions p ON p.parcel_id = pc.parcel_id AND p.action_type = 'INSTRUCTIONS'
        AND p.safe_place = norm_term(p_place) AND p.notes_masked = mask_codes(p_text)
        AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
       WHERE e.ok ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
    LEFT JOIN safe_places sp ON sp.place_code = pa.safe_place;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION instructions_confirm_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, parcel_id INTEGER, safe_place VARCHAR, access_code_present BOOLEAN, hazards TEXT,
               notes_masked TEXT) AS $$
  SELECT pa.action_id, pa.parcel_id, pa.safe_place, pa.access_code_present, pa.hazards, pa.notes_masked
    FROM session_recipient(p_token) sr
    JOIN parcels pc ON pc.recipient_id = sr.recipient_id
    JOIN pending_actions pa ON pa.action_id = norm_ref(p_action) AND pa.parcel_id = pc.parcel_id AND pa.action_type = 'INSTRUCTIONS'
    CROSS JOIN LATERAL instructions_eval(p_token, pc.tracking_number, pa.safe_place, '', pa.notes_masked) e
   WHERE pa.status = 'PENDING' AND pa.expires_at > clock_timestamp() AND e.ok;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION confirm_instructions_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, tracking_number VARCHAR, safe_place VARCHAR,
               access_code_present BOOLEAN, hazards TEXT, driver_note TEXT, saved_at TIMESTAMP) AS $$
  SELECT CASE WHEN di.instruction_id IS NOT NULL THEN 'EXECUTED' ELSE 'NOT_EXECUTED' END,
         CASE WHEN di.instruction_id IS NOT NULL THEN 'EXECUTED'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND'
              WHEN pa.expires_at <= clock_timestamp() THEN 'EXPIRED'
              ELSE (SELECT e.reason_code FROM instructions_eval(p_token, pc.tracking_number, pa.safe_place, '', pa.notes_masked) e) END,
         CASE WHEN di.instruction_id IS NOT NULL THEN 'Delivery instructions saved. The driver sees them on the next attempt; access codes are never stored.'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no pending delivery instructions with that id on this account.'
              WHEN pa.expires_at <= clock_timestamp() THEN 'EXPIRED: the proposal expired. Propose the instructions again.'
              ELSE (SELECT e.reason FROM instructions_eval(p_token, pc.tracking_number, pa.safe_place, '', pa.notes_masked) e) END,
         pc.tracking_number, pa.safe_place, pa.access_code_present, pa.hazards, pa.notes_masked, di.saved_at
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN pending_actions pa ON pa.action_id = norm_ref(p_action) AND pa.action_type = 'INSTRUCTIONS'
         AND EXISTS (SELECT 1 FROM parcels pc2 WHERE pc2.parcel_id = pa.parcel_id AND pc2.recipient_id = sr.recipient_id)
    LEFT JOIN parcels pc ON pc.parcel_id = pa.parcel_id
    LEFT JOIN delivery_instructions di ON di.action_id = pa.action_id;
$$ LANGUAGE sql STABLE;

-- Side effect of saved instructions: the proposal is executed, the change log and the audit trail are written.
CREATE OR REPLACE FUNCTION apply_instructions() RETURNS TRIGGER AS $$
DECLARE pc parcels; r recipients;
BEGIN
  SELECT * INTO pc FROM parcels WHERE parcel_id = NEW.parcel_id;
  SELECT * INTO r FROM recipients WHERE recipient_id = pc.recipient_id;
  UPDATE pending_actions SET status = 'EXECUTED' WHERE action_id = NEW.action_id;
  INSERT INTO delivery_change_log (tracking_number, recipient_id, action_type, detail)
    VALUES (pc.tracking_number, pc.recipient_id, 'INSTRUCTIONS', 'Safe place ' || NEW.safe_place || '; access code given: '
            || CASE WHEN NEW.access_code_present THEN 'yes (not stored)' ELSE 'no' END || '; hazards: ' || NEW.hazards);
  INSERT INTO agent_audit (account_ref, action, ref, detail)
    VALUES (r.account_ref, 'INSTRUCTIONS_SAVED', NEW.action_id, pc.tracking_number || ' -> ' || NEW.safe_place);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_delivery_instructions AFTER INSERT ON delivery_instructions FOR EACH ROW EXECUTE FUNCTION apply_instructions();

-- =====================================================================
-- EMAIL: validated payload for the guarded email tool. SEND_OK + subject/body ONLY for this session's executed
-- delivery change (ACT-), saved delivery instructions (ACT-) or decided case (SC-, a review_decisions row exists);
-- otherwise NOT_SENT + reason. The flow sends to the configured To_Email; never internal notes or codes.
-- =====================================================================
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_action TEXT)
RETURNS TABLE (send_status TEXT, reason TEXT, to_email VARCHAR, subject TEXT, body TEXT, reference_id TEXT) AS $$
  SELECT CASE WHEN x.ok THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN x.ok THEN 'Confirmation email prepared.'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID: verify again.'
              WHEN sv0.case_id IS NOT NULL THEN 'NOT_DECIDED: that case has not been decided yet, so there is nothing to email.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no action or case with that id on this account.'
              ELSE 'NOT_EXECUTED: that change has not been confirmed yet, so there is nothing to email.' END,
         CASE WHEN x.ok THEN r.email END,
         CASE WHEN dc.change_id IS NOT NULL THEN 'Your Swiftbound delivery is updated - ' || pc.tracking_number
              WHEN di.instruction_id IS NOT NULL THEN 'Your Swiftbound delivery instructions are saved - ' || pc.tracking_number
              WHEN sv.case_id IS NOT NULL THEN 'Swiftbound - decision on your ' || st.label || ' (' || sv.case_id || ')'
              ELSE 'Swiftbound delivery confirmation - not sent' END,
         CASE WHEN dc.change_id IS NOT NULL THEN
           'Dear ' || r.first_name || ',' || chr(10) || chr(10)
           || 'The delivery of your parcel ' || pc.tracking_number || ' (' || pc.description || ') has been updated.' || chr(10)
           || CASE WHEN dc.action_type = 'RESCHEDULE'
                   THEN 'It is now scheduled for ' || coalesce((SELECT to_char(sl.slot_date,'YYYY-MM-DD') || ' '
                         || to_char(sl.window_start,'HH24:MI') || '-' || to_char(sl.window_end,'HH24:MI')
                         FROM delivery_slots sl WHERE sl.slot_id = dc.slot_id), dc.slot_id) || '.'
                   ELSE 'It will be available for collection at ' || coalesce((SELECT pp.name || ', ' || pp.address_line
                         FROM pickup_points pp WHERE pp.pickup_id = dc.pickup_id), dc.pickup_id) || '.' END || chr(10) || chr(10)
           || 'Thank you for choosing Swiftbound.'
              WHEN di.instruction_id IS NOT NULL THEN
           'Dear ' || r.first_name || ',' || chr(10) || chr(10)
           || 'Your delivery instructions for parcel ' || pc.tracking_number || ' (' || pc.description || ') are saved.' || chr(10)
           || 'Safe place: ' || di.safe_place || '. Hazards: ' || di.hazards || '. Access code given: '
           || CASE WHEN di.access_code_present THEN 'yes - for your security the code itself is not stored or emailed.' ELSE 'no.' END
           || chr(10) || chr(10) || 'Thank you for choosing Swiftbound.'
              WHEN sv.case_id IS NOT NULL THEN
           'Dear ' || r.first_name || ',' || chr(10) || chr(10)
           || 'Our ' || st.team || ' team has reviewed your ' || st.label || ' (case ' || sv.case_id || '): '
           || CASE WHEN sv.status = 'APPROVED' THEN 'approved' ELSE 'not approved' END || '.' || chr(10)
           || coalesce(sv.customer_message, '') || chr(10)
           || coalesce('Compensation of ' || usd(cp.amount) || ' has been paid (' || cp.payment_id || ').' || chr(10), '')
           || chr(10) || 'Thank you for choosing Swiftbound.'
              ELSE 'No confirmation email was sent for ' || norm_ref(p_action) || '.' END,
         norm_ref(p_action)
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN recipients r ON r.recipient_id = sr.recipient_id
    LEFT JOIN pending_actions pa ON pa.action_id = norm_ref(p_action)
         AND EXISTS (SELECT 1 FROM parcels pc2 WHERE pc2.parcel_id = pa.parcel_id AND pc2.recipient_id = sr.recipient_id)
    LEFT JOIN delivery_changes dc ON dc.action_id = pa.action_id
    LEFT JOIN delivery_instructions di ON di.action_id = pa.action_id
    LEFT JOIN service_cases sv0 ON sv0.case_id = norm_ref(p_action) AND sv0.recipient_id = sr.recipient_id
    LEFT JOIN service_cases sv ON sv.case_id = sv0.case_id
                              AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = sv.case_id)
    LEFT JOIN service_teams st ON st.request_type = sv.request_type
    LEFT JOIN compensation_payments cp ON cp.case_id = sv.case_id
    LEFT JOIN parcels pc ON pc.parcel_id = pa.parcel_id
    CROSS JOIN LATERAL (SELECT (dc.change_id IS NOT NULL OR di.instruction_id IS NOT NULL OR sv.case_id IS NOT NULL) AS ok) x;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for the email tool: the request is logged ONLY when the payload says SEND_OK (then the flow sends).
CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (recipient_id VARCHAR, reference_id TEXT, subject TEXT) AS $$
  SELECT sr.recipient_id, e.reference_id, e.subject
    FROM session_recipient(p_token) sr
    CROSS JOIN LATERAL email_confirmation_payload(p_token, p_action) e
   WHERE sr.recipient_id IS NOT NULL AND e.send_status = 'SEND_OK';
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- REVIEWER IDENTITY: staff id + staff code -> REVIEWER session (same token mechanism, role checked everywhere).
-- =====================================================================
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN recipient_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
                                    AND s.expires_at > clock_timestamp()
      LEFT JOIN reviewers r ON r.reviewer_id = s.reviewer_id AND r.active;
END $$ LANGUAGE plpgsql STABLE;

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
              ELSE 'VERIFIED: reviewer session valid for 60 minutes.' END,
         CASE WHEN lk.until IS NULL THEN s.session_token END,
         CASE WHEN lk.until IS NULL AND s.session_token IS NOT NULL THEN 'REVIEWER' END,
         CASE WHEN lk.until IS NULL THEN s.display_name END,
         CASE WHEN lk.until IS NULL THEN s.team END,
         CASE WHEN lk.until IS NULL THEN s.expires_at END
    FROM (SELECT reviewer_locked_until(p_staff) AS until) lk
    LEFT JOIN LATERAL (
      SELECT se.session_token, r.display_name::text AS display_name, r.team::text AS team, se.expires_at
        FROM reviewers r
        JOIN recipient_sessions se ON se.reviewer_id = r.reviewer_id AND se.role = 'REVIEWER' AND se.expires_at > clock_timestamp()
       WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN s.parked_action LIKE 'COMPENSATION:%'
              THEN (SELECT c.eligible_amount FROM damage_claims c WHERE c.claim_id = split_part(s.parked_action, ':', 2))
              ELSE s.requested_amount END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no email, phone, address, PIN or full last name).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN c.claim_id IS NOT NULL THEN
      'Claim ' || c.claim_id || ' (' || c.claim_type || ') on parcel ' || pc.tracking_number || ' "' || pc.description
      || '" from ' || pc.sender || ', ' || pc.service_level || ' service, status ' || pc.current_status
      || CASE WHEN pc.current_status = 'DELIVERED' AND pc.expected_delivery IS NOT NULL
              THEN ', delivered ' || to_char(pc.expected_delivery, 'YYYY-MM-DD') ELSE '' END
      || coalesce(', tracking exception ' || pc.exception_code, '')
      || '; declared value ' || usd(c.declared_value) || ', coverage limit ' || usd(c.coverage_limit)
      || ', claimed ' || usd(c.claimed_amount) || ', claimable ' || usd(c.eligible_amount)
      || '; packaging: ' || c.packaging_condition || '; likely cause: ' || c.cause_category
      || coalesce('; agent terms not in the claim guide (ignored): ' || c.ignored_terms, '')
      || '; evidence requested: ' || c.evidence_required
      || '; other claims by this recipient in the last 12 months: '
      || (SELECT count(*) FROM damage_claims o WHERE o.recipient_id = c.recipient_id AND o.claim_id <> c.claim_id
            AND o.created_at > clock_timestamp() - INTERVAL '365 days')
    ELSE coalesce('Parcel ' || p2.tracking_number || ' "' || p2.description || '" from ' || p2.sender || ', status '
                  || p2.current_status || ', declared value ' || usd(p2.declared_value), 'No linked parcel.')
    END
    FROM service_cases s
    LEFT JOIN damage_claims c ON c.claim_id = split_part(s.parked_action, ':', 2) AND s.parked_action LIKE 'COMPENSATION:%'
    LEFT JOIN parcels pc ON pc.parcel_id = c.parcel_id
    LEFT JOIN parcels p2 ON p2.tracking_number = s.tracking_number
   WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue: OPEN cases ordered by reply-due time. Another team's cases never appear.
CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id TEXT, request VARCHAR, recipient TEXT, opened_on DATE, age_days INTEGER,
               reply_due DATE, sla_status TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.recipient, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT s.case_id, t.label, recipient_display(s.recipient_id) AS recipient, s.created_at::date AS opened_on,
             (current_date - s.created_at::date)::int AS age_days, s.sla_due_at::date AS reply_due,
             CASE WHEN s.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN s.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             s.requested_amount, s.sla_due_at
        FROM service_cases s JOIN service_teams t ON t.request_type = s.request_type
       WHERE sr.reviewer_id IS NOT NULL AND t.team = sr.team AND s.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at, q.case_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id TEXT, request VARCHAR, case_status VARCHAR, recipient TEXT, opened_on DATE,
               reply_due DATE, recipient_statement TEXT, agent_brief TEXT, requested_amount NUMERIC, max_approvable NUMERIC,
               your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, t.label, s.status, recipient_display(s.recipient_id), s.created_at::date, s.sla_due_at::date,
         s.recipient_statement, s.agent_brief, s.requested_amount, case_eligible_max(s.case_id),
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN case_eligible_max(s.case_id) IS NOT NULL THEN 'APPROVE pays compensation of any amount up to '
                   || usd(case_eligible_max(s.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(s.case_id)
                           THEN ' (above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer)' ELSE '' END
                   || ', or REJECT pays nothing; give an internal note and a message for the recipient.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the recipient (no automatic action).' END,
         s.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT x.request_type FROM service_teams x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN service_teams t ON t.request_type = s.request_type;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id TEXT, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT,
               customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; t service_teams; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_txt TEXT := norm_amount(p_amount); v_msg TEXT;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM service_cases x WHERE x.case_id = v_ref;
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
                'The approved compensation must be more than $0 and no more than ' || usd(v_max) || ' for this claim.');
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
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || t.label || ' has been approved' || coalesce(' for ' || usd(v_amt), '') || '.'
                  ELSE 'After review, your ' || t.label || ' was not approved. We will email you the reasons.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT s.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id TEXT, decision VARCHAR, approved_amount NUMERIC, reason_code VARCHAR, reason_text TEXT,
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
                coalesce((SELECT 'Compensation of ' || usd(cp.amount) || ' paid to the recipient (' || cp.payment_id || ').'
                            FROM compensation_payments cp WHERE cp.case_id = s.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was paid or executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id;
$$ LANGUAGE sql STABLE;

-- Guarded row the decision trigger uses to execute the parked compensation (the same checks every time).
CREATE OR REPLACE FUNCTION compensation_payment_row(p_claim TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (claim_id VARCHAR, case_id TEXT, recipient_id VARCHAR, amount NUMERIC) AS $$
  SELECT c.claim_id, p_case, c.recipient_id, p_amount
    FROM damage_claims c
   WHERE c.claim_id = p_claim AND c.case_id = p_case AND p_amount > 0 AND p_amount <= c.eligible_amount
     AND NOT EXISTS (SELECT 1 FROM compensation_payments x WHERE x.claim_id = c.claim_id)
     AND EXISTS (SELECT 1 FROM service_cases s WHERE s.case_id = p_case AND s.parked_action = 'COMPENSATION:' || c.claim_id);
$$ LANGUAGE sql STABLE;

-- The decision event: case status + recipient message, then the parked action through the guarded row, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'nothing';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(s.parked_action, ''), ':', 2);
  IF NEW.decision = 'APPROVE' AND v_kind = 'COMPENSATION' THEN
    INSERT INTO compensation_payments (claim_id, case_id, recipient_id, amount)
      SELECT * FROM compensation_payment_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'compensation for ' || v_ref || ' paid ' || usd(NEW.approved_amount); END IF;
  END IF;
  INSERT INTO agent_audit (account_ref, actor, action, ref, detail)
    VALUES (s.account_ref, NEW.reviewer_id, 'CASE_DECIDED', NEW.case_id,
            NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

CREATE OR REPLACE FUNCTION audit_compensation() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, ref, detail)
    SELECT r.account_ref, 'COMPENSATION_PAID', NEW.payment_id, usd(NEW.amount) || ' for ' || NEW.claim_id || ' (case ' || NEW.case_id || ')'
      FROM recipients r WHERE r.recipient_id = NEW.recipient_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_compensation AFTER INSERT ON compensation_payments FOR EACH ROW EXECUTE FUNCTION audit_compensation();

-- =====================================================================
-- AGENT REFERENCE TOOLS (read-only, identity-free). One per new agent; the delivery_options_agent keeps
-- search_delivery_options() above.
-- =====================================================================
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

-- damage_claim_agent: claim types, packaging, causes, evidence, the claim line + who decides (from service_teams).
CREATE OR REPLACE FUNCTION ref_claim_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM claim_guide g
          UNION ALL                                 -- who decides a claim: service_teams is the source of truth
          SELECT 'WHO_DECIDES', t.claim_type::text,
                 'A person in ' || t.team || ' decides a ' || t.label || ' and any compensation, and replies within '
                 || t.sla_days || ' business days; the assistant never decides or promises an amount.', 1000
            FROM service_teams t WHERE t.claim_type IS NOT NULL) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CLAIM_TYPE','PACKAGING','CAUSE','EVIDENCE','CLAIM_LINE','BRIEF_RULE','WHO_DECIDES'], r.sec),
            r.ord, r.trm
$$ LANGUAGE sql STABLE;

-- delivery_instructions_agent: the allowed safe places + risky-instruction flags (the SAME tables SQL checks),
-- hazards, the masking rule, the driver line and brief rules.
CREATE OR REPLACE FUNCTION ref_delivery_instructions(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT 'SAFE_PLACE'::text AS sec, s.place_code::text AS trm,
                 s.meaning || CASE WHEN s.attended THEN ' Attended: a person takes the parcel.'
                                   ELSE ' Unattended: not allowed for signature-required or high-value parcels.' END AS mng,
                 0 AS ord
            FROM safe_places s
          UNION ALL
          SELECT 'RISK_FLAG', f.flag_code::text, f.meaning || ' Looks like: ' || array_to_string(f.phrases, '; ') || '.', 0
            FROM instruction_risk_flags f
          UNION ALL
          SELECT g.section::text, g.term::text, g.meaning::text, g.entry_id FROM instruction_guide g) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['SAFE_PLACE','RISK_FLAG','HAZARD','MASK_RULE','DRIVER_LINE','BRIEF_RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'REVIEWER' THEN
    INSERT INTO agent_audit (actor, action, ref, detail)
      VALUES (NEW.reviewer_id, 'REVIEWER_VERIFY', NEW.reviewer_id,
              'reviewer session issued, expires ' || to_char(NEW.expires_at, 'YYYY-MM-DD HH24:MI'));
  ELSE
    INSERT INTO agent_audit (account_ref, action, detail)
      SELECT r.account_ref, 'VERIFY_SESSION_ISSUED', 'session issued for account ' || r.account_ref
        FROM recipients r WHERE r.recipient_id = NEW.recipient_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON recipient_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_proposal() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, ref, detail)
    SELECT r.account_ref, NEW.action_type || '_PROPOSED', NEW.action_id,
           'parcel ' || pc.tracking_number || ' -> ' || coalesce(NEW.slot_id, NEW.pickup_id, NEW.safe_place, '?')
           || ' (action ' || NEW.action_id || ')'
      FROM parcels pc JOIN recipients r ON r.recipient_id = pc.recipient_id WHERE pc.parcel_id = NEW.parcel_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_proposal AFTER INSERT ON pending_actions FOR EACH ROW EXECUTE FUNCTION audit_proposal();

CREATE OR REPLACE FUNCTION audit_change() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, ref, detail)
    SELECT r.account_ref, 'DELIVERY_CHANGE_EXECUTED', NEW.action_id,
           NEW.action_type || ' ' || pc.tracking_number || ' -> ' || coalesce(NEW.slot_id, NEW.pickup_id)
      FROM parcels pc JOIN recipients r ON r.recipient_id = pc.recipient_id WHERE pc.parcel_id = NEW.parcel_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_change AFTER INSERT ON delivery_changes FOR EACH ROW EXECUTE FUNCTION audit_change();

CREATE OR REPLACE FUNCTION audit_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, ref, detail)
    VALUES (NEW.account_ref, 'SERVICE_CASE_OPENED', NEW.case_id, NEW.request_type || ' (' || NEW.case_id || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_case AFTER INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION audit_case();

\ir seed_data.sql
