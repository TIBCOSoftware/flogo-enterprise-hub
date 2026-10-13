-- Meridian Passenger Services (GOVERNED) - schema, business rules and demo data.
-- Load:  createdb airline_governed  &&  psql -d airline_governed -f database.sql
--
-- =====================================================================
-- Airline Passenger Services - Governed Agentic AI
-- The rules live HERE, not in any prompt:
--   * session_booking() / session_reviewer()  identity: every read/write is scoped by a session token. Traveller
--                           (PNR + PIN) and staff-reviewer tokens share one table but are not interchangeable
--   * connection_risk()     SAFE / AT_RISK / MISSED is ARITHMETIC in SQL, never the LLM's guess
--   * rebook_eval()         rebooking eligibility (ownership, disruption, route, time, seats)
--   * trg_rebooking_apply   the rebooking side effects happen atomically in the DB
--   * search_alternatives() route/time search for the rebooking agent - NO passenger identity
--   * baggage_assessment()  the baggage_claim_agent's claim type / bag codes / contents / missing report fields are
--                           VALIDATED against the reference tables (a bag is LOST only 5+ days after arrival) and
--                           recorded in baggage_claims; the claim opens a Baggage Services case
--   * assistance_assessment()  the special_assistance_agent's IATA SSR codes are validated (requestable codes only,
--                           one wheelchair code, medical needs add MEDA) and added to the traveller's own segment as
--                           PENDING_CONFIRMATION; the Accessibility Desk confirms
--   * service_teams         human-owned requests are routed by a table, never by the LLM
--   * case_parking()        a case may PARK a typed action (COMPENSATION:<flight> / INTERIM_EXPENSE:<claim> /
--                           CONFIRM_SSR:<request>) that runs ONLY when a staff reviewer of that team approves it
--   * reviewers + decide_case_row()  the human in the loop: own team only, approval limit (OVER_AUTHORITY), amount
--                           checks; review_decisions + trg_review_decision execute the parked action through the same
--                           guarded row functions (payment / SSR confirmation) and audit it
--   * ref_baggage_guide() / ref_assistance_codes()  the agents' read-only reference reads - NO identity in or out
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The genuinely semantic steps are the three A2A agents: rebooking_options_agent (rank flights against free-text
-- preferences), baggage_claim_agent (bag description -> claim type, bag codes, contents, missing report fields) and
-- special_assistance_agent (free-text needs -> standard IATA SSR codes).
-- Meridian and all travellers, staff, bookings and flights are fictional.
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

DROP TABLE IF EXISTS email_log, agent_audit, ssr_confirmations, service_payments, decide_attempts, review_decisions,
  segment_ssrs, assistance_requests, baggage_claims, verify_attempts, reviewer_verify_attempts, service_cases,
  service_teams, rebooking_log, rebookings, pending_actions, traveler_sessions, reviewers, booking_segments, bookings,
  frequentflyer, passengers, flights, compensation_bands, baggage_claim_types, baggage_report_fields, baggage_guide,
  ssr_codes, assistance_guide CASCADE;
DROP SEQUENCE IF EXISTS bag_seq, ast_seq, pay_seq, ssrc_seq;

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

CREATE TABLE flights (
  flight_number        VARCHAR(10) PRIMARY KEY,
  origin               VARCHAR(3)  NOT NULL,
  origin_city          VARCHAR(50) NOT NULL,
  destination          VARCHAR(3)  NOT NULL,
  destination_city     VARCHAR(50) NOT NULL,
  scheduled_departure  TIMESTAMP   NOT NULL,
  scheduled_arrival    TIMESTAMP   NOT NULL,
  status               VARCHAR(20) NOT NULL DEFAULT 'ON_TIME'
                         CHECK (status IN ('ON_TIME','DELAYED','BOARDING','DEPARTED','ARRIVED','CANCELLED')),
  gate                 VARCHAR(5),
  delay_minutes        INTEGER     NOT NULL DEFAULT 0,
  delay_reason         VARCHAR(200),
  seats_available      INTEGER     NOT NULL DEFAULT 0,
  cabin_available      VARCHAR(20) NOT NULL DEFAULT 'Economy',
  aircraft             VARCHAR(50) NOT NULL DEFAULT 'Boeing 737 MAX 9',
  -- effective times: estimated = scheduled + delay (a cancelled flight never "arrives")
  est_departure TIMESTAMP GENERATED ALWAYS AS
    (scheduled_departure + make_interval(mins => delay_minutes)) STORED,
  est_arrival   TIMESTAMP GENERATED ALWAYS AS
    (scheduled_arrival + make_interval(mins => delay_minutes)) STORED
);

CREATE TABLE passengers (
  passenger_id  VARCHAR(20) PRIMARY KEY,         -- PAX-2026-XXXXX
  first_name    VARCHAR(50) NOT NULL,
  last_name     VARCHAR(50) NOT NULL,
  email         VARCHAR(100) NOT NULL,
  phone         VARCHAR(30),
  nationality   VARCHAR(3)
);

CREATE TABLE frequentflyer (
  passenger_id          VARCHAR(20) PRIMARY KEY REFERENCES passengers,
  frequentflyer_number  VARCHAR(20) NOT NULL UNIQUE,
  tier                  VARCHAR(20) NOT NULL DEFAULT 'Basic'
                          CHECK (tier IN ('Basic','Silver','Gold','Platinum')),
  miles_balance         INTEGER NOT NULL DEFAULT 0,
  tier_miles_ytd        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE bookings (
  booking_id        SERIAL PRIMARY KEY,
  pnr               VARCHAR(6) NOT NULL UNIQUE,     -- 6-character PNR (the login id)
  passenger_id      VARCHAR(20) NOT NULL REFERENCES passengers,
  booking_status    VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED'
                      CHECK (booking_status IN ('CONFIRMED','CANCELLED','COMPLETED')),
  verification_pin  VARCHAR(4) NOT NULL,            -- demo stand-in for the code in the app / emailed to the traveller
  booking_date      DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE booking_segments (
  segment_id      SERIAL PRIMARY KEY,
  booking_id      INTEGER NOT NULL REFERENCES bookings,
  segment_order   INTEGER NOT NULL,
  flight_number   VARCHAR(10) NOT NULL REFERENCES flights,
  origin          VARCHAR(3) NOT NULL,
  destination     VARCHAR(3) NOT NULL,
  seat_number     VARCHAR(5),
  cabin           VARCHAR(20) NOT NULL DEFAULT 'Economy' CHECK (cabin IN ('Economy','Business')),
  segment_status  VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED'
                    CHECK (segment_status IN ('CONFIRMED','CHECKED_IN','BOARDED','COMPLETED','CANCELLED','REBOOKED')),
  rebooked_from   VARCHAR(10) REFERENCES flights       -- set when this leg was moved to a new flight
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE service_teams (
  request_type  VARCHAR(24) PRIMARY KEY,
  label         VARCHAR(40) NOT NULL,              -- traveller-facing name
  team          VARCHAR(60) NOT NULL,
  sla_days      INTEGER NOT NULL                   -- reply within N business days
);

-- Staff reviewers (the human in the loop). team matches service_teams.team.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,           -- MER-7001 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(60) NOT NULL,
  one_time_code   VARCHAR(6)  NOT NULL,              -- HIDDEN: demo stand-in for the staff sign-in code
  approval_limit  NUMERIC(12,2),                     -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE traveler_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL DEFAULT 'TRAVELER' CHECK (role IN ('TRAVELER','REVIEWER')),
  booking_id     INTEGER REFERENCES bookings,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'TRAVELER' AND booking_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND booking_id IS NULL))
);

-- Brute-force throttle for the PIN step: N wrong PINs for a PNR -> a cooldown lock (OWASP identity-spoofing).
CREATE TABLE verify_attempts (
  pnr           VARCHAR(6) PRIMARY KEY,
  attempts      INTEGER NOT NULL DEFAULT 0,
  locked_until  TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Brute-force throttle for the staff code step (5 wrong codes in 15 minutes -> locked).
CREATE TABLE reviewer_verify_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  ok           BOOLEAN NOT NULL,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pending_actions (
  action_id       TEXT PRIMARY KEY DEFAULT 'ACT-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  action_type     VARCHAR(20) NOT NULL CHECK (action_type IN ('REBOOK')),
  booking_id      INTEGER NOT NULL REFERENCES bookings,
  segment_id      INTEGER NOT NULL REFERENCES booking_segments,
  from_flight     VARCHAR(10) NOT NULL REFERENCES flights,
  to_flight       VARCHAR(10) NOT NULL REFERENCES flights,
  new_seat        VARCHAR(5),
  status          VARCHAR(12) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','EXECUTED')),
  created_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

CREATE TABLE rebookings (
  rebooking_id    SERIAL PRIMARY KEY,
  action_id       TEXT UNIQUE NOT NULL REFERENCES pending_actions,
  segment_id      INTEGER NOT NULL REFERENCES booking_segments,
  from_flight     VARCHAR(10) NOT NULL REFERENCES flights,
  to_flight       VARCHAR(10) NOT NULL REFERENCES flights,
  new_seat        VARCHAR(5),
  rebooked_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE rebooking_log (
  id              SERIAL PRIMARY KEY,
  pnr             VARCHAR(6) NOT NULL,
  passenger_id    VARCHAR(20),
  original_flight VARCHAR(10) NOT NULL,
  new_flight      VARCHAR(10) NOT NULL,
  original_seat   VARCHAR(5),
  new_seat        VARCHAR(5),
  rebooked_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE service_cases (
  case_id             TEXT PRIMARY KEY DEFAULT 'SC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  booking_id          INTEGER NOT NULL REFERENCES bookings,
  pnr                 VARCHAR(6) NOT NULL,
  request_type        VARCHAR(24) NOT NULL REFERENCES service_teams,
  traveler_statement  TEXT NOT NULL,
  agent_brief         TEXT NOT NULL,            -- neutral summary by the assistant / an agent; never a decision (HIDDEN from travellers)
  requested_amount    NUMERIC(10,2),            -- what a person could approve (computed in SQL; NULL = no amount)
  parked_action       VARCHAR(40),              -- runs ONLY on approval: COMPENSATION:<flight> / INTERIM_EXPENSE:<claim> / CONFIRM_SSR:<request>
  status              VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at          TIMESTAMP,                -- set by trg_case_defaults from service_teams
  customer_message    TEXT,                     -- traveller-safe outcome text, set by the reviewer's decision
  approved_amount     NUMERIC(10,2),
  decided_at          TIMESTAMP,
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Compensation bands for a disrupted booking (goodwill travel credit). Rules, not prompts: the most a person may approve.
CREATE TABLE compensation_bands (
  band               VARCHAR(12) PRIMARY KEY,
  cancelled          BOOLEAN NOT NULL DEFAULT FALSE,   -- TRUE = applies to a cancelled flight
  min_delay_minutes  INTEGER,                          -- delay bands: at least this many minutes late
  max_usd            NUMERIC(10,2) NOT NULL,
  label              VARCHAR(80) NOT NULL
);

-- ---------------------------------------------------------------------
-- Baggage: reference data (no personal data) + the claims the assistant records.
-- ---------------------------------------------------------------------
-- Claim types: the meaning is shown to the baggage_claim_agent; the interim cap is a RULE it never sees.
CREATE TABLE baggage_claim_types (
  claim_type              VARCHAR(10) PRIMARY KEY,
  meaning                 VARCHAR(300) NOT NULL,
  min_days_after_arrival  INTEGER NOT NULL DEFAULT 0,   -- LOST only this many days after the flight arrived
  interim_cap_usd         NUMERIC(10,2) NOT NULL,       -- HIDDEN from the agent: most a reviewer may approve as interim expenses
  sort_order              INTEGER NOT NULL
);

-- Report fields Baggage Services needs, and for which claim types.
CREATE TABLE baggage_report_fields (
  field         VARCHAR(20) PRIMARY KEY,
  meaning       VARCHAR(300) NOT NULL,
  required_for  TEXT[] NOT NULL,
  sort_order    INTEGER NOT NULL
);

-- Bag-type chart, colour codes, content categories and the standard claim note. Reference data only.
CREATE TABLE baggage_guide (
  entry_id  SERIAL PRIMARY KEY,
  section   VARCHAR(12) NOT NULL CHECK (section IN ('BAG_TYPE','COLOUR','CONTENT','CLAIM_NOTE')),
  term      VARCHAR(40) NOT NULL,
  meaning   VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- Every recorded baggage claim = what the agent mapped (validated) + what SQL found. Opens a Baggage Services case.
CREATE SEQUENCE bag_seq START 1;
CREATE TABLE baggage_claims (
  claim_id           VARCHAR(12) PRIMARY KEY DEFAULT 'BAG-' || lpad(nextval('bag_seq')::text, 5, '0'),
  case_id            TEXT NOT NULL UNIQUE DEFAULT 'SC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  booking_id         INTEGER NOT NULL REFERENCES bookings,
  pnr                VARCHAR(6) NOT NULL,
  segment_id         INTEGER NOT NULL REFERENCES booking_segments,
  flight_number      VARCHAR(10) NOT NULL REFERENCES flights,
  claim_type         VARCHAR(10) NOT NULL REFERENCES baggage_claim_types,
  agent_claim_type   VARCHAR(20),               -- what the agent said (e.g. LOST before the 5-day rule downgraded it)
  bag_type           VARCHAR(4),
  colour             VARCHAR(4),
  contents           TEXT,
  missing_fields     TEXT,                      -- agent-flagged fields that are required for the claim type + rule findings
  rule_note          TEXT,                      -- what the deterministic rules changed or found
  ignored_items      TEXT,                      -- anything else the model sent (recorded, never used)
  description        TEXT NOT NULL,             -- the traveller's own words
  agent_notes        TEXT,                      -- HIDDEN from travellers: the agent's full answer (reviewers only)
  interim_requested  NUMERIC(10,2),             -- interim expenses asked for, capped by the claim type (NULL = none)
  created_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE bag_seq OWNED BY baggage_claims.claim_id;

-- ---------------------------------------------------------------------
-- Special assistance: IATA SSR codes (reference) + requests on the traveller's own segment.
-- ---------------------------------------------------------------------
CREATE TABLE ssr_codes (
  code                   VARCHAR(4) PRIMARY KEY,
  label                  VARCHAR(60) NOT NULL,
  meaning                VARCHAR(300) NOT NULL,
  traveller_requestable  BOOLEAN NOT NULL DEFAULT TRUE,
  medical_clearance      BOOLEAN NOT NULL DEFAULT FALSE,  -- needs a medical clearance (MEDA) by the Accessibility Desk
  wheelchair_level       INTEGER,                         -- 1 WCHR, 2 WCHS, 3 WCHC: at most one per request
  sort_order             INTEGER NOT NULL
);

CREATE TABLE assistance_guide (
  entry_id  SERIAL PRIMARY KEY,
  section   VARCHAR(14) NOT NULL CHECK (section IN ('HOW_TO_CHOOSE','STANDARD_LINE')),
  term      VARCHAR(40) NOT NULL,
  meaning   VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

CREATE SEQUENCE ast_seq START 1;
CREATE TABLE assistance_requests (
  request_id         VARCHAR(12) PRIMARY KEY DEFAULT 'AST-' || lpad(nextval('ast_seq')::text, 5, '0'),
  case_id            TEXT NOT NULL UNIQUE DEFAULT 'SC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  booking_id         INTEGER NOT NULL REFERENCES bookings,
  pnr                VARCHAR(6) NOT NULL,
  segment_id         INTEGER NOT NULL REFERENCES booking_segments,
  flight_number      VARCHAR(10) NOT NULL REFERENCES flights,
  codes              TEXT NOT NULL,             -- validated SSR codes, comma-separated
  ignored_codes      TEXT,                      -- codes the model sent that were not used (unknown, not requestable, extra wheelchair, already on the segment)
  medical_clearance  BOOLEAN NOT NULL DEFAULT FALSE,
  needs              TEXT NOT NULL,             -- the traveller's own words
  agent_notes        TEXT,                      -- HIDDEN from travellers: the agent's full answer
  created_at         TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE ast_seq OWNED BY assistance_requests.request_id;

CREATE TABLE segment_ssrs (
  ssr_id        SERIAL PRIMARY KEY,
  segment_id    INTEGER NOT NULL REFERENCES booking_segments,
  request_id    VARCHAR(12) NOT NULL REFERENCES assistance_requests,
  ssr_code      VARCHAR(4) NOT NULL REFERENCES ssr_codes,
  status        VARCHAR(24) NOT NULL DEFAULT 'PENDING_CONFIRMATION' CHECK (status IN ('PENDING_CONFIRMATION','CONFIRMED')),
  confirmed_at  TIMESTAMP,
  UNIQUE (segment_id, ssr_code)
);

-- ---------------------------------------------------------------------
-- The reviewer loop: decision events, attempts, and what an approval executes.
-- ---------------------------------------------------------------------
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          TEXT NOT NULL UNIQUE REFERENCES service_cases,
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(10,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from travellers
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

-- A reviewer-approved payment (event row): goodwill compensation or interim baggage expenses.
CREATE SEQUENCE pay_seq START 1;
CREATE TABLE service_payments (
  payment_id   VARCHAR(12) PRIMARY KEY,          -- PAY-00001
  case_id      TEXT NOT NULL UNIQUE REFERENCES service_cases,
  booking_id   INTEGER NOT NULL REFERENCES bookings,
  kind         VARCHAR(16) NOT NULL CHECK (kind IN ('COMPENSATION','INTERIM_EXPENSE')),
  ref          VARCHAR(12) NOT NULL,             -- the flight (COMPENSATION) or the baggage claim (INTERIM_EXPENSE)
  amount_usd   NUMERIC(10,2) NOT NULL CHECK (amount_usd > 0),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- A reviewer-confirmed assistance request (event row): the segment's SSRs become CONFIRMED.
CREATE SEQUENCE ssrc_seq START 1;
CREATE TABLE ssr_confirmations (
  confirmation_id  VARCHAR(12) PRIMARY KEY,      -- SSRC-00001
  request_id       VARCHAR(12) NOT NULL UNIQUE REFERENCES assistance_requests,
  case_id          TEXT NOT NULL UNIQUE REFERENCES service_cases,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change, written by triggers so it
-- cannot be bypassed. Back-office/ops read it by SQL; travellers never see it.
CREATE TABLE agent_audit (
  audit_id  SERIAL PRIMARY KEY,
  at        TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  pnr       VARCHAR(6),
  actor     VARCHAR(10),                 -- reviewer id for REVIEWER_VERIFY / CASE_DECIDED
  action    VARCHAR(40) NOT NULL,        -- VERIFY_SESSION_ISSUED, REVIEWER_VERIFY, REBOOK_PROPOSED, REBOOK_EXECUTED,
                                         -- SERVICE_CASE_OPENED, BAGGAGE_CLAIM_RECORDED, ASSISTANCE_REQUESTED,
                                         -- CASE_DECIDED, PAYMENT_ISSUED, SSR_CONFIRMED, EMAIL_LOGGED
  detail    TEXT
);

-- Guarded email requests that passed the SQL check (the flow then sends to To_Email).
CREATE TABLE email_log (
  email_id      SERIAL PRIMARY KEY,
  pnr           VARCHAR(6) NOT NULL,
  reference_id  VARCHAR(20) NOT NULL,
  subject       TEXT NOT NULL,
  logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- =====================================================================
-- RULES
-- =====================================================================

-- Identity: a TRAVELER token is valid for its booking until it expires (a reviewer token is not a traveller token).
-- ALWAYS returns exactly one row - the booking when valid, or (null,null,null) when not - so dependent reads can
-- emit SESSION_INVALID. plpgsql (NOT sql) on purpose: an inlinable SQL function here merges its LEFT JOINs into the
-- caller's chained LEFT JOINs and mis-binds flight rows to an empty segment. plpgsql is opaque to the planner.
CREATE OR REPLACE FUNCTION session_booking(p_token TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, passenger_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT b.booking_id, b.pnr, b.passenger_id
      FROM (SELECT 1) one
      LEFT JOIN traveler_sessions s ON s.session_token = p_token AND s.role = 'TRAVELER'
                                   AND s.expires_at > clock_timestamp()
      LEFT JOIN bookings b ON b.booking_id = s.booking_id;
END $$ LANGUAGE plpgsql STABLE;

-- Reviewer identity: one row always - the reviewer when the token is a valid REVIEWER token of an active reviewer.
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN traveler_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
                                   AND s.expires_at > clock_timestamp()
      LEFT JOIN reviewers r ON r.reviewer_id = s.reviewer_id AND r.active;
END $$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Helpers (formatting, normalisation).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL ELSE '$' || to_char(n, 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$ SELECT upper(trim(coalesce(p, ''))) $$ LANGUAGE sql IMMUTABLE;

-- '$1,234.50' / '1234.5' / ' 35 ' -> '1234.50'-style text ('' when empty); 'ALL' stays 'ALL'.
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT upper(regexp_replace(coalesce(p, ''), '[[:space:]$,]|USD', '', 'gi'))
$$ LANGUAGE sql IMMUTABLE;

-- A positive dollar amount from free text, or NULL.
CREATE OR REPLACE FUNCTION parse_amount(p TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN norm_amount(p) ~ '^[0-9]+(\.[0-9]+)?$' AND norm_amount(p)::numeric > 0
              THEN round(norm_amount(p)::numeric, 2) END
$$ LANGUAGE sql IMMUTABLE;

-- MER-7001 / mer7001 / MER 7001 / 7001 -> MER-7001
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^[0-9]{4}$' THEN 'MER-' || d ELSE upper(trim(coalesce(p, ''))) END
    FROM (SELECT regexp_replace(upper(trim(coalesce(p, ''))), '^MER[[:space:]-]*', '') AS d) x
$$ LANGUAGE sql IMMUTABLE;

-- What a reviewer sees instead of the full name (minimum necessary): 'Linda Park' -> 'Linda P.'
CREATE OR REPLACE FUNCTION traveler_display(p_booking INTEGER) RETURNS TEXT AS $$
  SELECT p.first_name || ' ' || left(p.last_name, 1) || '.'
    FROM bookings b JOIN passengers p ON p.passenger_id = b.passenger_id WHERE b.booking_id = p_booking
$$ LANGUAGE sql STABLE;

-- Minimum legal connection time at the ATL hub (minutes). A rule, not a guess.
CREATE OR REPLACE FUNCTION min_connection_minutes() RETURNS INTEGER AS $$ SELECT 45 $$ LANGUAGE sql IMMUTABLE;

-- Throttle: record a verify attempt and return the booking_id ONLY on a correct, non-locked attempt.
-- Side-effecting (VOLATILE): N wrong PINs for a PNR lock it for a cooldown; a correct PIN clears the count.
-- Used inside the verify tool's INSERT ... SELECT, so a session is created only when it returns a row.
CREATE OR REPLACE FUNCTION verify_and_record(p_pnr TEXT, p_pin TEXT)
RETURNS TABLE (booking_id INTEGER) AS $$
DECLARE v_pnr TEXT := upper(trim(p_pnr)); bk bookings; att verify_attempts; maxn INTEGER := 5;
BEGIN
  SELECT * INTO att FROM verify_attempts WHERE pnr = v_pnr;
  IF att.locked_until IS NOT NULL AND att.locked_until > clock_timestamp() THEN
    RETURN;                                  -- locked: no session, even if the PIN is right
  END IF;
  SELECT * INTO bk FROM bookings WHERE pnr = v_pnr;
  IF FOUND AND bk.verification_pin = trim(p_pin) THEN
    DELETE FROM verify_attempts WHERE pnr = v_pnr;    -- success: clear the counter
    RETURN QUERY SELECT bk.booking_id; RETURN;
  END IF;
  IF bk.booking_id IS NOT NULL THEN                   -- track failures only for real PNRs (bounds the table)
    INSERT INTO verify_attempts (pnr, attempts, locked_until, updated_at)
      VALUES (v_pnr, 1, NULL, clock_timestamp())
      ON CONFLICT (pnr) DO UPDATE SET attempts = verify_attempts.attempts + 1,
        locked_until = CASE WHEN verify_attempts.attempts + 1 >= maxn THEN clock_timestamp() + INTERVAL '15 minutes' END,
        updated_at = clock_timestamp();
  END IF;
  RETURN;                                             -- no session
END $$ LANGUAGE plpgsql VOLATILE;

-- Verify: PNR + 4-digit PIN -> VERIFIED + token, LOCKED after too many wrong PINs, else NOT_VERIFIED.
CREATE OR REPLACE FUNCTION verify_result(p_pnr TEXT, p_pin TEXT)
RETURNS TABLE (status TEXT, session_token TEXT, passenger_name TEXT, pnr VARCHAR, tier VARCHAR, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN va.locked_until > clock_timestamp() THEN 'LOCKED'
              WHEN s.session_token IS NULL THEN 'NOT_VERIFIED' ELSE 'VERIFIED' END,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.session_token END,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.passenger_name END,
         coalesce(s.pnr, upper(trim(p_pnr)))::varchar,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.tier END,
         CASE WHEN va.locked_until > clock_timestamp() THEN NULL ELSE s.expires_at END
    FROM (SELECT 1) one
    LEFT JOIN verify_attempts va ON va.pnr = upper(trim(p_pnr))
    LEFT JOIN LATERAL (
      SELECT se.session_token, (p.first_name || ' ' || p.last_name) AS passenger_name,
             b.pnr, coalesce(ff.tier,'Basic') AS tier, se.expires_at
        FROM bookings b
        JOIN passengers p ON p.passenger_id = b.passenger_id
        LEFT JOIN frequentflyer ff ON ff.passenger_id = b.passenger_id
        JOIN traveler_sessions se ON se.booking_id = b.booking_id AND se.role = 'TRAVELER' AND se.expires_at > clock_timestamp()
       WHERE b.pnr = upper(trim(p_pnr)) AND b.verification_pin = trim(p_pin)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- The SSRs on one segment as the traveller may see them (a REJECTED assistance case shows NOT_CONFIRMED).
CREATE OR REPLACE FUNCTION segment_assistance(p_segment INTEGER) RETURNS TEXT AS $$
  SELECT string_agg(ss.ssr_code || ' ' ||
                    CASE WHEN ss.status = 'CONFIRMED' THEN 'CONFIRMED'
                         WHEN sc.status = 'REJECTED' THEN 'NOT_CONFIRMED' ELSE 'PENDING_CONFIRMATION' END,
                    ', ' ORDER BY ss.ssr_id)
    FROM segment_ssrs ss
    JOIN assistance_requests ar ON ar.request_id = ss.request_id
    LEFT JOIN service_cases sc ON sc.case_id = ar.case_id
   WHERE ss.segment_id = p_segment
$$ LANGUAGE sql STABLE;

-- Scoped read: the traveller's own itinerary with live flight status per leg (and any assistance on the leg).
CREATE OR REPLACE FUNCTION my_itinerary(p_token TEXT)
RETURNS TABLE (session_status TEXT, pnr VARCHAR, segment_order INTEGER, flight_number VARCHAR,
               origin VARCHAR, destination VARCHAR, scheduled_departure TIMESTAMP, estimated_departure TIMESTAMP,
               scheduled_arrival TIMESTAMP, estimated_arrival TIMESTAMP, flight_status VARCHAR, delay_minutes INTEGER,
               gate VARCHAR, seat VARCHAR, cabin VARCHAR, segment_status VARCHAR, assistance TEXT) AS $$
  SELECT CASE WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         sb.pnr, seg.segment_order, seg.flight_number, seg.origin, seg.destination,
         f.scheduled_departure, f.est_departure, f.scheduled_arrival, f.est_arrival,
         f.status, f.delay_minutes, f.gate, seg.seat_number, seg.cabin, seg.segment_status,
         segment_assistance(seg.segment_id)
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN booking_segments seg ON seg.booking_id = sb.booking_id
    LEFT JOIN flights f ON f.flight_number = seg.flight_number
   ORDER BY seg.segment_order;
$$ LANGUAGE sql STABLE;

-- Scoped read: the traveller's loyalty standing.
CREATE OR REPLACE FUNCTION my_loyalty(p_token TEXT)
RETURNS TABLE (session_status TEXT, passenger_name TEXT, frequentflyer_number VARCHAR, tier VARCHAR,
               miles_balance INTEGER, tier_miles_ytd INTEGER) AS $$
  SELECT CASE WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         (p.first_name || ' ' || p.last_name), ff.frequentflyer_number, ff.tier, ff.miles_balance, ff.tier_miles_ytd
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN passengers p ON p.passenger_id = sb.passenger_id
    LEFT JOIN frequentflyer ff ON ff.passenger_id = sb.passenger_id;
$$ LANGUAGE sql STABLE;

-- Scoped read: status of one flight that is on the traveller's own itinerary.
CREATE OR REPLACE FUNCTION flight_status_for_session(p_token TEXT, p_flight TEXT)
RETURNS TABLE (lookup_status TEXT, flight_number VARCHAR, origin VARCHAR, destination VARCHAR,
               scheduled_departure TIMESTAMP, estimated_departure TIMESTAMP, scheduled_arrival TIMESTAMP,
               estimated_arrival TIMESTAMP, status VARCHAR, delay_minutes INTEGER, delay_reason VARCHAR, gate VARCHAR) AS $$
  SELECT CASE WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID' WHEN f.flight_number IS NULL THEN 'NOT_ON_ITINERARY' ELSE 'OK' END,
         f.flight_number, f.origin, f.destination, f.scheduled_departure, f.est_departure,
         f.scheduled_arrival, f.est_arrival, f.status, f.delay_minutes, f.delay_reason, f.gate
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN booking_segments seg ON seg.booking_id = sb.booking_id AND seg.flight_number = upper(trim(p_flight))
    LEFT JOIN flights f ON f.flight_number = seg.flight_number;
$$ LANGUAGE sql STABLE;

-- Rule: connection risk for the traveller's booking. Pure arithmetic: compare the inbound leg's
-- effective arrival with the next leg's effective departure against the minimum connection time.
CREATE OR REPLACE FUNCTION connection_risk(p_token TEXT)
RETURNS TABLE (session_status TEXT, pnr VARCHAR, connection_at VARCHAR, inbound_flight VARCHAR,
               inbound_status VARCHAR, inbound_arrival TIMESTAMP, outbound_flight VARCHAR,
               outbound_departure TIMESTAMP, connection_minutes INTEGER, risk TEXT,
               earliest_rebook_departure TIMESTAMP, detail TEXT) AS $$
  WITH sb AS (SELECT * FROM session_booking(p_token)),
  legs AS (
    SELECT seg.segment_order, seg.flight_number, seg.destination,
           fi.status AS in_status, fi.est_arrival AS in_arr, seg.segment_status,
           lead(seg.flight_number)  OVER (ORDER BY seg.segment_order) AS next_flight,
           lead(fo_dep.est_departure) OVER (ORDER BY seg.segment_order) AS next_dep,
           lead(seg.destination)    OVER (ORDER BY seg.segment_order) AS next_dest
      FROM sb JOIN booking_segments seg ON seg.booking_id = sb.booking_id
      JOIN flights fi ON fi.flight_number = seg.flight_number
      JOIN flights fo_dep ON fo_dep.flight_number = seg.flight_number)
  SELECT CASE WHEN (SELECT booking_id FROM sb) IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         (SELECT pnr FROM sb), l.destination, l.flight_number, l.in_status, l.in_arr,
         l.next_flight,
         (SELECT fo.est_departure FROM flights fo WHERE fo.flight_number = l.next_flight),
         CASE WHEN l.next_flight IS NULL THEN NULL
              ELSE (EXTRACT(EPOCH FROM ((SELECT fo.est_departure FROM flights fo WHERE fo.flight_number = l.next_flight) - l.in_arr))/60)::INTEGER END,
         CASE WHEN l.next_flight IS NULL THEN 'NO_CONNECTION'
              WHEN l.in_status = 'CANCELLED' THEN 'MISSED'
              WHEN (EXTRACT(EPOCH FROM ((SELECT fo.est_departure FROM flights fo WHERE fo.flight_number = l.next_flight) - l.in_arr))/60) < min_connection_minutes() THEN 'MISSED'
              WHEN (EXTRACT(EPOCH FROM ((SELECT fo.est_departure FROM flights fo WHERE fo.flight_number = l.next_flight) - l.in_arr))/60) < min_connection_minutes() + 30 THEN 'AT_RISK'
              ELSE 'SAFE' END,
         CASE WHEN l.next_flight IS NULL THEN NULL
              ELSE l.in_arr + make_interval(mins => min_connection_minutes()) END,
         CASE WHEN l.next_flight IS NULL THEN 'Single leg to ' || l.destination || '; no connection.'
              WHEN l.in_status = 'CANCELLED' THEN 'Inbound ' || l.flight_number || ' is CANCELLED; the connection to ' || l.next_flight || ' cannot be made.'
              ELSE 'Inbound ' || l.flight_number || ' arrives ' || to_char(l.in_arr,'HH24:MI') || ', ' || l.next_flight
                   || ' departs ' || to_char((SELECT fo.est_departure FROM flights fo WHERE fo.flight_number = l.next_flight),'HH24:MI') || '.' END
    FROM legs l
   WHERE l.next_flight IS NOT NULL OR l.segment_order = 1;
$$ LANGUAGE sql STABLE;

-- Agent tool: alternative flights for a route after a given time. NO passenger identity is passed in.
CREATE OR REPLACE FUNCTION search_alternatives(p_origin TEXT, p_destination TEXT, p_after TEXT, p_cabin TEXT)
RETURNS TABLE (flight_number VARCHAR, origin VARCHAR, destination VARCHAR, scheduled_departure TIMESTAMP,
               estimated_departure TIMESTAMP, scheduled_arrival TIMESTAMP, estimated_arrival TIMESTAMP,
               status VARCHAR, seats_available INTEGER, cabin_available VARCHAR, aircraft VARCHAR) AS $$
  SELECT f.flight_number, f.origin, f.destination, f.scheduled_departure, f.est_departure,
         f.scheduled_arrival, f.est_arrival, f.status, f.seats_available, f.cabin_available, f.aircraft
    FROM flights f
   WHERE f.origin = upper(trim(p_origin)) AND f.destination = upper(trim(p_destination))
     AND f.status <> 'CANCELLED' AND f.seats_available > 0
     AND f.est_departure > coalesce(nullif(trim(p_after),'')::timestamp, now() - interval '1 year')
   ORDER BY f.est_departure
   LIMIT 8;
$$ LANGUAGE sql STABLE;

-- Rule: may this traveller rebook this leg (identified by its current flight) onto this flight?
-- Returns ok + a reason to explain verbatim.
CREATE OR REPLACE FUNCTION rebook_eval(p_token TEXT, p_current TEXT, p_flight TEXT)
RETURNS TABLE (ok BOOLEAN, reason TEXT) AS $$
DECLARE bk RECORD; seg booking_segments; inb flights; tgt flights; mins INTEGER;
BEGIN
  SELECT * INTO bk FROM session_booking(p_token);
  IF bk.booking_id IS NULL THEN RETURN QUERY SELECT FALSE, 'SESSION_INVALID: identity not verified or session expired. Verify again.'; RETURN; END IF;
  SELECT * INTO seg FROM booking_segments WHERE flight_number = upper(trim(p_current)) AND booking_id = bk.booking_id
   ORDER BY segment_order LIMIT 1;
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'NOT_FOUND: no leg on flight ' || coalesce(p_current,'') || ' for this booking.'; RETURN; END IF;
  IF seg.segment_status IN ('REBOOKED','CANCELLED','COMPLETED','BOARDED') THEN
    RETURN QUERY SELECT FALSE, 'ALREADY_REBOOKED: this leg is ' || seg.segment_status || ' and cannot be changed here.'; RETURN; END IF;
  SELECT * INTO tgt FROM flights WHERE flight_number = upper(trim(p_flight));
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'FLIGHT_UNKNOWN: no flight ' || coalesce(p_flight,'') || '.'; RETURN; END IF;
  IF tgt.flight_number = seg.flight_number THEN
    RETURN QUERY SELECT FALSE, 'SAME_FLIGHT: the leg is already on ' || tgt.flight_number || '.'; RETURN; END IF;
  IF tgt.origin <> seg.origin OR tgt.destination <> seg.destination THEN
    RETURN QUERY SELECT FALSE, 'WRONG_ROUTE: ' || tgt.flight_number || ' flies ' || tgt.origin || '->' || tgt.destination
                               || ', not ' || seg.origin || '->' || seg.destination || '.'; RETURN; END IF;
  IF tgt.status = 'CANCELLED' THEN RETURN QUERY SELECT FALSE, 'TARGET_CANCELLED: ' || tgt.flight_number || ' is cancelled.'; RETURN; END IF;
  IF tgt.seats_available <= 0 THEN RETURN QUERY SELECT FALSE, 'NO_SEATS: ' || tgt.flight_number || ' has no seats available.'; RETURN; END IF;
  -- the new flight must leave after the inbound leg actually gets the traveller to the hub, plus the minimum connection
  SELECT * INTO inb FROM flights fi JOIN booking_segments s2 ON s2.flight_number = fi.flight_number
    WHERE s2.booking_id = bk.booking_id AND s2.segment_order = seg.segment_order - 1;
  IF FOUND THEN
    IF inb.status = 'CANCELLED' THEN
      -- inbound cancelled: any seat-available later flight on the route is acceptable
      NULL;
    ELSE
      mins := (EXTRACT(EPOCH FROM (tgt.est_departure - inb.est_arrival))/60)::INTEGER;
      IF mins < min_connection_minutes() THEN
        RETURN QUERY SELECT FALSE, 'DEPARTS_TOO_EARLY: ' || tgt.flight_number || ' departs only ' || mins
                                   || ' min after your inbound arrives; the minimum connection is '
                                   || min_connection_minutes() || ' min.'; RETURN; END IF;
    END IF;
  END IF;
  RETURN QUERY SELECT TRUE, 'ELIGIBLE'::TEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Side effect: a confirmed rebooking moves the leg atomically and writes the audit log.
CREATE OR REPLACE FUNCTION apply_rebooking() RETURNS TRIGGER AS $$
DECLARE seg booking_segments; bk bookings; tgt flights; old_flight VARCHAR;
BEGIN
  SELECT * INTO seg FROM booking_segments WHERE segment_id = NEW.segment_id;
  SELECT * INTO bk  FROM bookings WHERE booking_id = seg.booking_id;
  SELECT * INTO tgt FROM flights WHERE flight_number = NEW.to_flight;
  old_flight := seg.flight_number;
  UPDATE booking_segments
     SET rebooked_from = old_flight, flight_number = NEW.to_flight,
         seat_number = NEW.new_seat, segment_status = 'REBOOKED'
   WHERE segment_id = NEW.segment_id;
  UPDATE flights SET seats_available = seats_available - 1 WHERE flight_number = NEW.to_flight;
  INSERT INTO rebooking_log (pnr, passenger_id, original_flight, new_flight, original_seat, new_seat)
    VALUES (bk.pnr, bk.passenger_id, old_flight, NEW.to_flight, seg.seat_number, NEW.new_seat);
  UPDATE pending_actions SET status = 'EXECUTED' WHERE action_id = NEW.action_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_rebooking_apply AFTER INSERT ON rebookings FOR EACH ROW EXECUTE FUNCTION apply_rebooking();

-- Guarded write row: a pending rebooking is written ONLY when every rule passes.
CREATE OR REPLACE FUNCTION rebook_proposal_row(p_token TEXT, p_current TEXT, p_flight TEXT)
RETURNS TABLE (action_type VARCHAR, booking_id INTEGER, segment_id INTEGER, from_flight VARCHAR, to_flight VARCHAR, new_seat VARCHAR) AS $$
  SELECT 'REBOOK'::VARCHAR, bk.booking_id, seg.segment_id, seg.flight_number, upper(trim(p_flight))::VARCHAR,
         coalesce(seg.seat_number, 'AUTO')::VARCHAR
    FROM session_booking(p_token) bk
    JOIN booking_segments seg ON seg.booking_id = bk.booking_id AND seg.flight_number = upper(trim(p_current))
    CROSS JOIN LATERAL rebook_eval(p_token, p_current, p_flight) e
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.segment_id = seg.segment_id AND pa.to_flight = upper(trim(p_flight))
                        AND pa.status = 'PENDING' AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_rebook_result(p_token TEXT, p_current TEXT, p_flight TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, action_id TEXT, from_flight VARCHAR, to_flight VARCHAR,
               new_seat VARCHAR, new_departure TIMESTAMP, new_arrival TIMESTAMP, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN pa.action_id IS NOT NULL THEN 'PROPOSED' ELSE 'NOT_PROPOSED' END,
         CASE WHEN pa.action_id IS NOT NULL THEN 'Awaiting the traveller''s explicit confirmation. Nothing has changed yet.' ELSE e.reason END,
         pa.action_id, pa.from_flight, pa.to_flight, pa.new_seat, f.est_departure, f.est_arrival, pa.expires_at
    FROM rebook_eval(p_token, p_current, p_flight) e
    LEFT JOIN LATERAL (
      SELECT p.* FROM session_booking(p_token) sb
       JOIN pending_actions p ON p.booking_id = sb.booking_id AND p.from_flight = upper(trim(p_current))
        AND p.to_flight = upper(trim(p_flight)) AND p.status = 'PENDING' AND p.expires_at > clock_timestamp()
       WHERE e.ok ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
    LEFT JOIN flights f ON f.flight_number = pa.to_flight;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION rebook_confirmation_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, segment_id INTEGER, from_flight VARCHAR, to_flight VARCHAR, new_seat VARCHAR) AS $$
  SELECT pa.action_id, pa.segment_id, pa.from_flight, pa.to_flight, pa.new_seat
    FROM session_booking(p_token) bk
    JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.booking_id = bk.booking_id
    CROSS JOIN LATERAL rebook_eval(p_token, pa.from_flight, pa.to_flight) e
   WHERE pa.status = 'PENDING' AND pa.expires_at > clock_timestamp() AND e.ok;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION confirm_rebook_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, pnr VARCHAR, from_flight VARCHAR, to_flight VARCHAR,
               new_seat VARCHAR, new_departure TIMESTAMP, new_arrival TIMESTAMP, rebooked_at TIMESTAMP) AS $$
  SELECT CASE WHEN rb.rebooking_id IS NOT NULL THEN 'EXECUTED' ELSE 'NOT_EXECUTED' END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN 'Rebooking completed.'
              WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no pending rebooking with that id for this booking.'
              WHEN pa.expires_at <= clock_timestamp() THEN 'EXPIRED: the proposal expired. Propose the rebooking again.'
              ELSE (SELECT e.reason FROM rebook_eval(p_token, pa.from_flight, pa.to_flight) e) END,
         sb.pnr, rb.from_flight, rb.to_flight, rb.new_seat, f.est_departure, f.est_arrival, rb.rebooked_at
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.booking_id = sb.booking_id
    LEFT JOIN rebookings rb ON rb.action_id = pa.action_id
    LEFT JOIN flights f ON f.flight_number = rb.to_flight;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Human-owned requests -> routed to a team by the table, never decided by the LLM.
-- ---------------------------------------------------------------------
-- Compensation: the most disrupted leg of the booking and the band it falls in (cancelled / 180+ / 60+ minutes late).
CREATE OR REPLACE FUNCTION compensation_eligibility(p_booking INTEGER)
RETURNS TABLE (flight_number VARCHAR, band VARCHAR, max_usd NUMERIC, detail TEXT) AS $$
  SELECT f.flight_number, cb.band, cb.max_usd,
         f.flight_number || ' ' || f.origin || '->' || f.destination || ' '
         || CASE WHEN f.status = 'CANCELLED' THEN 'was cancelled' ELSE 'was ' || f.delay_minutes || ' minutes late' END
         || ' (' || cb.label || ', up to ' || usd(cb.max_usd) || ')'
    FROM booking_segments s
    JOIN flights f ON f.flight_number = coalesce(s.rebooked_from, s.flight_number)
    JOIN LATERAL (SELECT b.* FROM compensation_bands b
                   WHERE (f.status = 'CANCELLED' AND b.cancelled)
                      OR (f.status <> 'CANCELLED' AND NOT b.cancelled AND f.delay_minutes >= b.min_delay_minutes)
                   ORDER BY b.max_usd DESC LIMIT 1) cb ON TRUE
   WHERE s.booking_id = p_booking
   ORDER BY cb.max_usd DESC, s.segment_order
   LIMIT 1
$$ LANGUAGE sql STABLE;

-- What a new case parks for approval (derived in SQL, never chosen by the model):
--   COMPENSATION_CLAIM + a leg in a compensation band and nothing paid yet -> COMPENSATION:<flight>,
--                        requested = the amount asked (if any), never above the band's maximum
--   anything else      -> no parked action (the team completes it). Baggage claims and assistance requests park their
--                        own actions when they are recorded (record_baggage_claim / request_assistance).
CREATE OR REPLACE FUNCTION case_parking(p_booking INTEGER, p_type TEXT, p_amount TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, parked_action TEXT, requested_amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE e RECORD;
BEGIN
  ok := TRUE; reason_code := 'OK';
  IF upper(trim(coalesce(p_type, ''))) = 'COMPENSATION_CLAIM' THEN
    SELECT * INTO e FROM compensation_eligibility(p_booking) x;
    IF e.max_usd > 0 AND NOT EXISTS (SELECT 1 FROM service_payments sp WHERE sp.booking_id = p_booking AND sp.kind = 'COMPENSATION') THEN
      parked_action := 'COMPENSATION:' || e.flight_number;
      requested_amount := least(coalesce(parse_amount(p_amount), e.max_usd), e.max_usd);
    END IF;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Every case gets its reply-due time from the routing table (also cases opened by triggers and seeds).
CREATE OR REPLACE FUNCTION case_defaults() RETURNS TRIGGER AS $$
DECLARE t service_teams;
BEGIN
  SELECT * INTO t FROM service_teams WHERE request_type = NEW.request_type;
  NEW.sla_due_at := coalesce(NEW.sla_due_at, add_business_days(NEW.created_at::date, t.sla_days) + NEW.created_at::time);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION case_defaults();

CREATE OR REPLACE FUNCTION service_case_row(p_token TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT, p_amount TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, request_type VARCHAR, traveler_statement TEXT, agent_brief TEXT,
               requested_amount NUMERIC, parked_action TEXT) AS $$
  SELECT sb.booking_id, sb.pnr, t.request_type, left(coalesce(p_statement,''),4000), left(coalesce(p_brief,''),4000),
         pk.requested_amount, pk.parked_action
    FROM (SELECT * FROM session_booking(p_token)) sb
    JOIN service_teams t ON t.request_type = upper(trim(p_type))
    CROSS JOIN LATERAL case_parking(sb.booking_id, p_type, p_amount) pk
   WHERE sb.booking_id IS NOT NULL AND pk.ok
     AND NOT EXISTS (SELECT 1 FROM service_cases sc
                      WHERE sc.booking_id = sb.booking_id AND sc.request_type = t.request_type
                        AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes')
     AND NOT EXISTS (SELECT 1 FROM service_cases sc
                      WHERE pk.parked_action IS NOT NULL AND sc.parked_action = pk.parked_action AND sc.status = 'OPEN');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, reply_by DATE, status VARCHAR, requested_amount NUMERIC,
               if_approved TEXT, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NULL THEN 'NOT_OPENED'
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CASE_OPENED' ELSE 'ALREADY_OPEN' END,
         CASE WHEN c.case_id IS NOT NULL AND c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                THEN 'A person on the assigned team will review and reply. The assistant has not decided anything.'
              WHEN c.case_id IS NOT NULL
                THEN 'This request is already open with the assigned team, so no new case was opened. A person will decide.'
              WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              ELSE 'BAD_REQUEST_TYPE: use COMPENSATION_CLAIM, BAGGAGE_CLAIM, SPECIAL_ASSISTANCE, COMPLAINT, NAME_CHANGE or OTHER.' END,
         c.case_id, c.request_type, t.team, t.sla_days, c.sla_due_at::date, c.status, c.requested_amount,
         CASE split_part(coalesce(c.parked_action, ''), ':', 1)
              WHEN 'COMPENSATION' THEN 'If a person approves it, a travel credit of up to ' || usd(c.requested_amount)
                   || ' is issued for the disruption on ' || split_part(c.parked_action, ':', 2) || '.'
              WHEN 'INTERIM_EXPENSE' THEN 'If a person approves it, interim expenses of up to ' || usd(c.requested_amount) || ' are paid.'
              WHEN 'CONFIRM_SSR' THEN 'If the Accessibility Desk confirms it, the assistance is confirmed on your flight.' END,
         c.created_at
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN service_teams t0 ON t0.request_type = upper(trim(p_type))
    LEFT JOIN LATERAL (SELECT * FROM case_parking(sb.booking_id, p_type, '')) pk ON TRUE
    LEFT JOIN LATERAL (
      SELECT sc.* FROM service_cases sc
       WHERE sc.booking_id = sb.booking_id AND sc.request_type = upper(trim(p_type)) AND t0.request_type IS NOT NULL
         AND (sc.created_at > clock_timestamp() - INTERVAL '10 minutes'
              OR (sc.status = 'OPEN' AND pk.parked_action IS NOT NULL AND sc.parked_action = pk.parked_action))
       ORDER BY sc.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The traveller's own cases: status + the traveller-safe outcome once a person decided. Never the internal note, the AI
-- brief, the parked action or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR, status VARCHAR,
               requested_amount NUMERIC, approved_amount NUMERIC, customer_message TEXT, reply_by DATE, decided_on DATE,
               created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_id, c.request_type, t.team, c.status, c.requested_amount, c.approved_amount, c.customer_message,
         c.sla_due_at::date, c.decided_at::date, c.created_at
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN service_cases c ON c.booking_id = sb.booking_id
    LEFT JOIN service_teams t ON t.request_type = c.request_type
   ORDER BY c.created_at DESC;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Baggage claim: the baggage_claim_agent's answer is VALIDATED here, then recorded; the claim opens a case.
-- Lines read from the agent's answer: claim_type, bag_type, colour, contents, missing_fields.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION baggage_assessment(p_booking INTEGER, p_flight TEXT, p_description TEXT, p_interim TEXT, p_agent TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, booking_id INTEGER, pnr VARCHAR, segment_id INTEGER,
               flight_number VARCHAR, claim_type VARCHAR, agent_claim_type VARCHAR, bag_type VARCHAR, colour VARCHAR,
               contents TEXT, missing_fields TEXT, rule_note TEXT, ignored_items TEXT, interim_requested NUMERIC) AS $$
#variable_conflict use_column
DECLARE bk bookings; seg booking_segments; fl flights; ct baggage_claim_types; v_ct TEXT; v_raw TEXT; tok TEXT; v_amt NUMERIC;
        v_cont TEXT[] := '{}'; v_miss TEXT[] := '{}'; v_ign TEXT[] := '{}'; v_note TEXT[] := '{}'; v_agent TEXT := coalesce(p_agent, '');
BEGIN
  ok := FALSE;
  SELECT * INTO bk FROM bookings x WHERE x.booking_id = p_booking;
  IF bk.booking_id IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  booking_id := bk.booking_id; pnr := bk.pnr;
  SELECT * INTO seg FROM booking_segments s WHERE s.booking_id = bk.booking_id AND s.flight_number = upper(trim(coalesce(p_flight, '')))
   ORDER BY s.segment_order LIMIT 1;
  IF NOT FOUND THEN
    reason_code := 'NOT_FOUND'; reason := 'NOT_FOUND: flight ' || coalesce(p_flight, '') || ' is not on this booking.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO fl FROM flights f WHERE f.flight_number = seg.flight_number;
  segment_id := seg.segment_id; flight_number := fl.flight_number;
  IF fl.status = 'CANCELLED' OR seg.segment_status = 'CANCELLED' OR fl.est_arrival > clock_timestamp() THEN
    reason_code := 'NOT_ARRIVED';
    reason := 'NOT_ARRIVED: ' || fl.flight_number || ' has not arrived, so a baggage claim cannot be recorded for it yet.';
    RETURN NEXT; RETURN;
  END IF;
  IF coalesce(trim(p_description), '') = '' THEN
    reason_code := 'DESCRIPTION_MISSING'; reason := 'DESCRIPTION_MISSING: describe the bag and what happened in the traveller''s own words.';
    RETURN NEXT; RETURN;
  END IF;
  v_ct := upper(coalesce(substring(v_agent from '(?i)claim_type[*_:[:space:]]*([a-z_]+)'), ''));
  agent_claim_type := left(nullif(v_ct, ''), 20);
  SELECT * INTO ct FROM baggage_claim_types t WHERE t.claim_type = v_ct;
  IF NOT FOUND THEN
    reason_code := 'CLAIM_TYPE_UNKNOWN';
    reason := 'CLAIM_TYPE_UNKNOWN: the baggage_claim_agent''s answer must give a claim_type of DELAYED, LOST, DAMAGED or PILFERED.';
    RETURN NEXT; RETURN;
  END IF;
  IF ct.min_days_after_arrival > 0 AND fl.est_arrival > clock_timestamp() - make_interval(days => ct.min_days_after_arrival) THEN
    v_note := v_note || ('LOST_TOO_EARLY: a bag is reported lost only ' || ct.min_days_after_arrival
                         || ' or more days after the flight arrived, so it is recorded as DELAYED.');
    SELECT * INTO ct FROM baggage_claim_types t WHERE t.claim_type = 'DELAYED';
  END IF;
  claim_type := ct.claim_type;
  -- bag type (two-digit chart code) and colour code must exist in the guide
  v_raw := substring(v_agent from '(?i)bag_type[*_:[:space:]]*([0-9]{2})');
  IF v_raw IS NOT NULL AND EXISTS (SELECT 1 FROM baggage_guide g WHERE g.section = 'BAG_TYPE' AND g.term = v_raw) THEN bag_type := v_raw;
  ELSIF v_raw IS NOT NULL THEN v_ign := v_ign || ('bag_type ' || v_raw); END IF;
  v_raw := upper(substring(v_agent from '(?i)colou?r[*_:[:space:]]*([a-z]{2})\M'));
  IF v_raw IS NOT NULL AND EXISTS (SELECT 1 FROM baggage_guide g WHERE g.section = 'COLOUR' AND g.term = v_raw) THEN colour := v_raw;
  ELSIF v_raw IS NOT NULL THEN v_ign := v_ign || ('colour ' || v_raw); END IF;
  -- contents: only the guide's CONTENT categories
  FOR tok IN SELECT upper(regexp_replace(w, '[^A-Za-z_]', '', 'g'))
               FROM regexp_split_to_table(coalesce(substring(v_agent from '(?i)contents[*_:[:space:]]*([^\n]*)'), ''), '[,;/]') w LOOP
    CONTINUE WHEN tok = '' OR tok = 'NONE' OR tok = ANY(v_cont);
    IF EXISTS (SELECT 1 FROM baggage_guide g WHERE g.section = 'CONTENT' AND g.term = tok) THEN v_cont := v_cont || tok;
    ELSE v_ign := v_ign || tok; END IF;
  END LOOP;
  -- missing report fields: only fields that this claim type needs
  FOR tok IN SELECT upper(regexp_replace(w, '[^A-Za-z_]', '', 'g'))
               FROM regexp_split_to_table(coalesce(substring(v_agent from '(?i)missing_fields[*_:[:space:]]*([^\n]*)'), ''), '[,;/]') w LOOP
    CONTINUE WHEN tok = '' OR tok = 'NONE' OR tok = ANY(v_miss);
    IF EXISTS (SELECT 1 FROM baggage_report_fields rf WHERE rf.field = tok AND ct.claim_type = ANY(rf.required_for)) THEN v_miss := v_miss || tok;
    ELSE v_ign := v_ign || tok; END IF;
  END LOOP;
  -- deterministic presence check: a bag tag number is two letters and six digits
  IF p_description !~ '[A-Za-z]{2}[[:space:]-]?[0-9]{6}' AND NOT ('BAG_TAG' = ANY(v_miss)) THEN
    v_miss := ARRAY['BAG_TAG'] || v_miss; v_note := v_note || 'BAG_TAG: no bag tag number in the description.'::text;
  END IF;
  -- interim expenses: what the traveller asks for, never above the claim type's cap
  v_amt := parse_amount(p_interim);
  IF v_amt IS NOT NULL THEN
    interim_requested := least(v_amt, ct.interim_cap_usd);
    IF v_amt > ct.interim_cap_usd THEN
      v_note := v_note || ('INTERIM_CAPPED: interim expenses for a ' || ct.claim_type || ' bag are capped at ' || usd(ct.interim_cap_usd) || '.');
    END IF;
  END IF;
  contents := nullif(array_to_string(v_cont, ', '), '');
  missing_fields := nullif(array_to_string(v_miss, ', '), '');
  rule_note := nullif(array_to_string(v_note, ' '), '');
  ignored_items := nullif(array_to_string(v_ign, ', '), '');
  IF EXISTS (SELECT 1 FROM baggage_claims b WHERE b.segment_id = seg.segment_id) THEN
    reason_code := 'ALREADY_RECORDED'; reason := 'ALREADY_RECORDED: a baggage claim for this flight is already on file.';
  ELSE
    ok := TRUE; reason_code := 'OK'; reason := 'OK';
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- The row a baggage claim is recorded from (0 rows when blocked). baggage_claim_core is also used by the seeds.
CREATE OR REPLACE FUNCTION baggage_claim_core(p_booking INTEGER, p_flight TEXT, p_description TEXT, p_interim TEXT, p_agent TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, segment_id INTEGER, flight_number VARCHAR, claim_type VARCHAR,
               agent_claim_type VARCHAR, bag_type VARCHAR, colour VARCHAR, contents TEXT, missing_fields TEXT, rule_note TEXT,
               ignored_items TEXT, description TEXT, agent_notes TEXT, interim_requested NUMERIC) AS $$
  SELECT a.booking_id, a.pnr, a.segment_id, a.flight_number, a.claim_type, a.agent_claim_type, a.bag_type, a.colour,
         a.contents, a.missing_fields, a.rule_note, a.ignored_items, left(trim(p_description), 4000), left(coalesce(p_agent, ''), 6000),
         a.interim_requested
    FROM baggage_assessment(p_booking, p_flight, p_description, p_interim, p_agent) a
   WHERE a.ok;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION baggage_claim_row(p_token TEXT, p_flight TEXT, p_description TEXT, p_interim TEXT, p_agent TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, segment_id INTEGER, flight_number VARCHAR, claim_type VARCHAR,
               agent_claim_type VARCHAR, bag_type VARCHAR, colour VARCHAR, contents TEXT, missing_fields TEXT, rule_note TEXT,
               ignored_items TEXT, description TEXT, agent_notes TEXT, interim_requested NUMERIC) AS $$
  SELECT c.* FROM session_booking(p_token) sb
   CROSS JOIN LATERAL baggage_claim_core(sb.booking_id, p_flight, p_description, p_interim, p_agent) c
   WHERE sb.booking_id IS NOT NULL;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION baggage_claim_result(p_token TEXT, p_flight TEXT, p_description TEXT, p_agent TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, claim_id TEXT, flight_number VARCHAR, claim_type VARCHAR,
               bag_type TEXT, colour TEXT, contents TEXT, missing_fields TEXT, what_to_send TEXT, rule_note TEXT,
               case_id TEXT, assigned_team VARCHAR, reply_by DATE, interim_requested NUMERIC, if_approved TEXT) AS $$
  SELECT CASE WHEN c.claim_id IS NULL THEN 'NOT_RECORDED'
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'RECORDED' ELSE 'ALREADY_RECORDED' END,
         CASE WHEN c.claim_id IS NOT NULL THEN 'OK' ELSE a.reason_code END,
         CASE WHEN c.claim_id IS NOT NULL AND c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                THEN 'Claim recorded and sent to Baggage Services. A person decides any interim payment; the assistant has not decided anything.'
              WHEN c.claim_id IS NOT NULL THEN 'A baggage claim for this flight is already on file; no new claim was recorded.'
              ELSE a.reason END,
         c.claim_id, c.flight_number, c.claim_type,
         CASE WHEN c.bag_type IS NOT NULL THEN c.bag_type || ' ' || split_part(bt.meaning, ' (', 1) END,
         CASE WHEN c.colour IS NOT NULL THEN c.colour || ' ' || split_part(co.meaning, ' (', 1) END,
         c.contents, c.missing_fields,
         (SELECT string_agg(rf.field || ': ' || rf.meaning, ' | ' ORDER BY rf.sort_order) FROM baggage_report_fields rf
           WHERE c.missing_fields IS NOT NULL AND rf.field = ANY(string_to_array(c.missing_fields, ', '))),
         c.rule_note, c.case_id, t.team, sc.sla_due_at::date, c.interim_requested,
         CASE WHEN c.interim_requested > 0 THEN 'If a person on Baggage Services approves it, interim expenses of up to '
                   || usd(c.interim_requested) || ' are paid.' END
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN LATERAL (SELECT x.* FROM baggage_claims x WHERE x.booking_id = sb.booking_id
                         AND x.flight_number = upper(trim(coalesce(p_flight, ''))) ORDER BY x.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN LATERAL baggage_assessment(sb.booking_id, p_flight, p_description, '', p_agent) a ON c.claim_id IS NULL
    LEFT JOIN baggage_guide bt ON bt.section = 'BAG_TYPE' AND bt.term = c.bag_type
    LEFT JOIN baggage_guide co ON co.section = 'COLOUR' AND co.term = c.colour
    LEFT JOIN service_cases sc ON sc.case_id = c.case_id
    LEFT JOIN service_teams t ON t.request_type = sc.request_type;
$$ LANGUAGE sql STABLE;

-- A recorded claim opens the Baggage Services case (parking INTERIM_EXPENSE:<claim> when interim expenses were asked for).
CREATE OR REPLACE FUNCTION open_baggage_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (pnr, action, detail)
    VALUES (NEW.pnr, 'BAGGAGE_CLAIM_RECORDED', NEW.claim_id || ' ' || NEW.claim_type || ' on ' || NEW.flight_number
            || coalesce(', interim asked ' || usd(NEW.interim_requested), ''));
  INSERT INTO service_cases (case_id, booking_id, pnr, request_type, traveler_statement, agent_brief, requested_amount,
                             parked_action, created_at)
    VALUES (NEW.case_id, NEW.booking_id, NEW.pnr, 'BAGGAGE_CLAIM', NEW.description, coalesce(NEW.agent_notes, ''),
            NEW.interim_requested, CASE WHEN NEW.interim_requested > 0 THEN 'INTERIM_EXPENSE:' || NEW.claim_id END, NEW.created_at);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_baggage_case AFTER INSERT ON baggage_claims FOR EACH ROW EXECUTE FUNCTION open_baggage_case();

-- ---------------------------------------------------------------------
-- Special assistance: the special_assistance_agent's ssr_codes line is VALIDATED here (requestable codes only, one
-- wheelchair code - the highest level wins, a medical need adds MEDA), then added to the traveller's own segment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assistance_assessment(p_booking INTEGER, p_flight TEXT, p_needs TEXT, p_agent TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason TEXT, booking_id INTEGER, pnr VARCHAR, segment_id INTEGER,
               flight_number VARCHAR, codes TEXT, ignored_codes TEXT, medical_clearance BOOLEAN) AS $$
#variable_conflict use_column
DECLARE bk bookings; seg booking_segments; fl flights; sc ssr_codes; tok TEXT; v_valid TEXT[] := '{}'; v_ign TEXT[] := '{}';
        v_wch TEXT; v_lvl INTEGER; v_med BOOLEAN := FALSE; v_already BOOLEAN := FALSE;
BEGIN
  ok := FALSE; medical_clearance := FALSE;
  SELECT * INTO bk FROM bookings x WHERE x.booking_id = p_booking;
  IF bk.booking_id IS NULL THEN
    reason_code := 'SESSION_INVALID'; reason := 'SESSION_INVALID: identity not verified or session expired. Verify again.';
    RETURN NEXT; RETURN;
  END IF;
  booking_id := bk.booking_id; pnr := bk.pnr;
  SELECT * INTO seg FROM booking_segments s WHERE s.booking_id = bk.booking_id AND s.flight_number = upper(trim(coalesce(p_flight, '')))
   ORDER BY s.segment_order LIMIT 1;
  IF NOT FOUND THEN
    reason_code := 'NOT_FOUND'; reason := 'NOT_FOUND: flight ' || coalesce(p_flight, '') || ' is not on this booking.';
    RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO fl FROM flights f WHERE f.flight_number = seg.flight_number;
  segment_id := seg.segment_id; flight_number := fl.flight_number;
  IF fl.status IN ('DEPARTED','ARRIVED','CANCELLED') OR seg.segment_status IN ('BOARDED','COMPLETED','CANCELLED')
     OR fl.est_departure <= clock_timestamp() THEN
    reason_code := 'NOT_UPCOMING'; reason := 'NOT_UPCOMING: ' || fl.flight_number || ' is not an upcoming flight, so assistance cannot be added to it.';
    RETURN NEXT; RETURN;
  END IF;
  IF coalesce(trim(p_needs), '') = '' THEN
    reason_code := 'NEEDS_MISSING'; reason := 'NEEDS_MISSING: describe the assistance needed in the traveller''s own words.';
    RETURN NEXT; RETURN;
  END IF;
  FOR tok IN SELECT upper(regexp_replace(w, '[^A-Za-z]', '', 'g'))
               FROM regexp_split_to_table(coalesce(substring(coalesce(p_agent, '') from '(?i)ssr_codes[*_:[:space:]]*([^\n]*)'), ''),
                                          '[,;/[:space:]]+') w LOOP
    CONTINUE WHEN tok = '' OR tok = 'NONE' OR tok = ANY(v_valid);
    SELECT * INTO sc FROM ssr_codes s WHERE s.code = tok;
    IF NOT FOUND OR NOT sc.traveller_requestable THEN v_ign := v_ign || tok; CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM segment_ssrs x WHERE x.segment_id = seg.segment_id AND x.ssr_code = tok) THEN
      v_ign := v_ign || (tok || ' (already on the flight)'); v_already := TRUE; CONTINUE;
    END IF;
    IF sc.wheelchair_level IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM segment_ssrs x JOIN ssr_codes y ON y.code = x.ssr_code
                  WHERE x.segment_id = seg.segment_id AND y.wheelchair_level IS NOT NULL) THEN
        v_ign := v_ign || (tok || ' (a wheelchair code is already on the flight)'); v_already := TRUE; CONTINUE;
      END IF;
      IF v_wch IS NULL OR sc.wheelchair_level > v_lvl THEN
        IF v_wch IS NOT NULL THEN v_ign := v_ign || (v_wch || ' (one wheelchair code)'); v_valid := array_remove(v_valid, v_wch); END IF;
        v_wch := tok; v_lvl := sc.wheelchair_level; v_valid := v_valid || tok;
      ELSE
        v_ign := v_ign || (tok || ' (one wheelchair code)');
      END IF;
      CONTINUE;
    END IF;
    v_valid := v_valid || tok;
    IF sc.medical_clearance THEN v_med := TRUE; END IF;
  END LOOP;
  IF v_med AND NOT ('MEDA' = ANY(v_valid))
     AND NOT EXISTS (SELECT 1 FROM segment_ssrs x WHERE x.segment_id = seg.segment_id AND x.ssr_code = 'MEDA') THEN
    v_valid := v_valid || 'MEDA'::text;
  END IF;
  ignored_codes := nullif(array_to_string(v_ign, ', '), '');
  IF cardinality(v_valid) = 0 THEN
    reason_code := CASE WHEN v_already THEN 'ALREADY_REQUESTED' ELSE 'NO_VALID_CODES' END;
    reason := CASE WHEN v_already THEN 'ALREADY_REQUESTED: that assistance is already on this flight.'
                   ELSE 'NO_VALID_CODES: the special_assistance_agent''s answer has no ssr_codes line with a standard code a traveller can request.' END;
    RETURN NEXT; RETURN;
  END IF;
  codes := (SELECT string_agg(s.code, ', ' ORDER BY s.sort_order) FROM ssr_codes s WHERE s.code = ANY(v_valid));
  medical_clearance := v_med OR 'MEDA' = ANY(v_valid);
  ok := TRUE; reason_code := 'OK'; reason := 'OK';
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION assistance_core(p_booking INTEGER, p_flight TEXT, p_needs TEXT, p_agent TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, segment_id INTEGER, flight_number VARCHAR, codes TEXT, ignored_codes TEXT,
               medical_clearance BOOLEAN, needs TEXT, agent_notes TEXT) AS $$
  SELECT a.booking_id, a.pnr, a.segment_id, a.flight_number, a.codes, a.ignored_codes, a.medical_clearance,
         left(trim(p_needs), 4000), left(coalesce(p_agent, ''), 6000)
    FROM assistance_assessment(p_booking, p_flight, p_needs, p_agent) a
   WHERE a.ok;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION assistance_row(p_token TEXT, p_flight TEXT, p_needs TEXT, p_agent TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, segment_id INTEGER, flight_number VARCHAR, codes TEXT, ignored_codes TEXT,
               medical_clearance BOOLEAN, needs TEXT, agent_notes TEXT) AS $$
  SELECT c.* FROM session_booking(p_token) sb
   CROSS JOIN LATERAL assistance_core(sb.booking_id, p_flight, p_needs, p_agent) c
   WHERE sb.booking_id IS NOT NULL;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION assistance_result(p_token TEXT, p_flight TEXT, p_needs TEXT, p_agent TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, request_id TEXT, flight_number VARCHAR, requested_codes TEXT,
               medical_clearance BOOLEAN, case_id TEXT, assigned_team VARCHAR, reply_by DATE, next_step TEXT) AS $$
  -- the latest request on this flight counts when it is fresh (just written) or when the rules say ALREADY_REQUESTED
  SELECT CASE WHEN r.request_id IS NULL THEN 'NOT_RECORDED'
              WHEN r.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'REQUESTED' ELSE 'ALREADY_REQUESTED' END,
         CASE WHEN r.request_id IS NOT NULL THEN 'OK' ELSE a.reason_code END,
         CASE WHEN r.request_id IS NOT NULL THEN 'Added to the flight as PENDING_CONFIRMATION. A person on the Accessibility Desk confirms it; the assistant has not confirmed anything.'
              ELSE a.reason END,
         r.request_id, r.flight_number,
         (SELECT string_agg(ss.ssr_code || ' (' || s.label || ') - ' || ss.status, '; ' ORDER BY s.sort_order)
            FROM segment_ssrs ss JOIN ssr_codes s ON s.code = ss.ssr_code WHERE ss.request_id = r.request_id),
         r.medical_clearance, r.case_id, t.team, sc.sla_due_at::date,
         CASE WHEN r.request_id IS NULL THEN NULL
              WHEN r.medical_clearance THEN 'The Accessibility Desk will contact the traveller for a medical information form (MEDIF) before confirming.'
              ELSE 'The Accessibility Desk confirms the request before the flight.' END
    FROM (SELECT * FROM session_booking(p_token)) sb
    CROSS JOIN LATERAL assistance_assessment(sb.booking_id, p_flight, p_needs, p_agent) a0
    LEFT JOIN LATERAL (SELECT x.* FROM assistance_requests x WHERE x.booking_id = sb.booking_id
                         AND x.flight_number = upper(trim(coalesce(p_flight, '')))
                         AND (x.created_at > clock_timestamp() - INTERVAL '10 minutes' OR a0.reason_code = 'ALREADY_REQUESTED')
                       ORDER BY x.created_at DESC LIMIT 1) r ON TRUE
    LEFT JOIN LATERAL (SELECT a0.reason_code, a0.reason WHERE r.request_id IS NULL) a ON TRUE
    LEFT JOIN service_cases sc ON sc.case_id = r.case_id
    LEFT JOIN service_teams t ON t.request_type = sc.request_type;
$$ LANGUAGE sql STABLE;

-- A recorded request adds its SSRs to the segment (PENDING_CONFIRMATION) and opens the Accessibility Desk case.
CREATE OR REPLACE FUNCTION open_assistance_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO segment_ssrs (segment_id, request_id, ssr_code)
    SELECT NEW.segment_id, NEW.request_id, c FROM unnest(string_to_array(NEW.codes, ', ')) c;
  INSERT INTO agent_audit (pnr, action, detail)
    VALUES (NEW.pnr, 'ASSISTANCE_REQUESTED', NEW.request_id || ' ' || NEW.codes || ' on ' || NEW.flight_number
            || CASE WHEN NEW.medical_clearance THEN ' (medical clearance needed)' ELSE '' END);
  INSERT INTO service_cases (case_id, booking_id, pnr, request_type, traveler_statement, agent_brief, parked_action, created_at)
    VALUES (NEW.case_id, NEW.booking_id, NEW.pnr, 'SPECIAL_ASSISTANCE', NEW.needs, coalesce(NEW.agent_notes, ''),
            'CONFIRM_SSR:' || NEW.request_id, NEW.created_at);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_assistance_case AFTER INSERT ON assistance_requests FOR EACH ROW EXECUTE FUNCTION open_assistance_case();

-- ---------------------------------------------------------------------
-- Email confirmation: validated payload for the guarded email tool. Returns SEND_OK + recipient/subject/body ONLY for an
-- executed rebooking (ACT-...) or a decided case (SC-...) of THIS session; otherwise NOT_SENT + reason, no recipient.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_action TEXT)
RETURNS TABLE (send_status TEXT, reason TEXT, reference_id TEXT, to_email VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN x.ok THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN x.ok THEN 'Confirmation email prepared.'
              WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID: verify again.'
              WHEN norm_ref(p_action) LIKE 'SC-%' AND sv0.case_id IS NOT NULL
                THEN 'NOT_DECIDED: that case has not been decided yet, so there is nothing to email.'
              WHEN norm_ref(p_action) LIKE 'SC-%' THEN 'CASE_NOT_FOUND: no case with that id for this booking.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no rebooking with that id for this booking.'
              ELSE 'NOT_EXECUTED: that rebooking has not been confirmed yet, so there is nothing to email.' END,
         norm_ref(p_action),
         CASE WHEN x.ok THEN p.email END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN 'Your Meridian rebooking is confirmed - ' || sb.pnr
              WHEN sv.case_id IS NOT NULL THEN 'Your Meridian ' || st.label || ' (' || sv.case_id || ') has been reviewed'
              ELSE 'Meridian confirmation - not sent' END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN
           'Dear ' || p.first_name || ',' || chr(10) || chr(10)
           || 'Your booking ' || sb.pnr || ' has been rebooked.' || chr(10)
           || 'From flight ' || rb.from_flight || ' to flight ' || rb.to_flight
           || ', seat ' || rb.new_seat || '.' || chr(10)
           || 'New departure ' || to_char(f.est_departure,'YYYY-MM-DD HH24:MI')
           || ', arriving ' || to_char(f.est_arrival,'HH24:MI') || '.' || chr(10) || chr(10)
           || 'Thank you for flying Meridian.'
              WHEN sv.case_id IS NOT NULL THEN
           'Dear ' || p.first_name || ',' || chr(10) || chr(10)
           || 'Our ' || st.team || ' team has reviewed your ' || st.label || ' (case ' || sv.case_id || '): '
           || CASE WHEN sv.status = 'APPROVED' THEN 'approved' ELSE 'not approved' END
           || coalesce(' for ' || usd(sv.approved_amount), '') || '.' || chr(10)
           || coalesce(sv.customer_message, '') || chr(10) || chr(10)
           || 'Thank you for flying Meridian.'
           ELSE 'No confirmation email was sent for ' || norm_ref(p_action) || '.' END
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN passengers p ON p.passenger_id = sb.passenger_id
    LEFT JOIN pending_actions pa ON pa.action_id = norm_ref(p_action) AND pa.booking_id = sb.booking_id
    LEFT JOIN rebookings rb ON rb.action_id = pa.action_id
    LEFT JOIN flights f ON f.flight_number = rb.to_flight
    LEFT JOIN service_cases sv0 ON sv0.case_id = norm_ref(p_action) AND sv0.booking_id = sb.booking_id
    LEFT JOIN service_cases sv ON sv.case_id = sv0.case_id AND sv.status IN ('APPROVED','REJECTED')
                              AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = sv.case_id)
    LEFT JOIN service_teams st ON st.request_type = sv.request_type
    CROSS JOIN LATERAL (SELECT (rb.rebooking_id IS NOT NULL OR sv.case_id IS NOT NULL) AS ok) x;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for the email tool: the request is logged ONLY when the payload says SEND_OK (then the flow sends).
CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (pnr VARCHAR, reference_id TEXT, subject TEXT) AS $$
  SELECT sb.pnr, e.reference_id, e.subject
    FROM session_booking(p_token) sb
    CROSS JOIN LATERAL email_confirmation_payload(p_token, p_action) e
   WHERE sb.booking_id IS NOT NULL AND e.send_status = 'SEND_OK';
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): verify -> queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
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
        JOIN traveler_sessions se ON se.reviewer_id = r.reviewer_id AND se.role = 'REVIEWER' AND se.expires_at > clock_timestamp()
       WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE split_part(coalesce(c.parked_action, ''), ':', 1) WHEN 'CONFIRM_SSR' THEN NULL ELSE c.requested_amount END
    FROM service_cases c WHERE c.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no email, phone, PIN or surname).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE split_part(coalesce(c.parked_action, ''), ':', 1)
    WHEN 'INTERIM_EXPENSE' THEN
      'Baggage claim ' || b.claim_id || ' (' || b.claim_type || ') on ' || bf.flight_number || ' ' || bf.origin || '->'
      || bf.destination || ', arrived ' || to_char(bf.est_arrival, 'YYYY-MM-DD') || '; bag: '
      || coalesce(b.bag_type || ' ' || split_part(bt.meaning, ' (', 1), 'type not given') || ', colour '
      || coalesce(b.colour, 'not given') || '; contents: ' || coalesce(b.contents, 'not given')
      || '; missing report fields: ' || coalesce(b.missing_fields, 'none')
      || coalesce('; rule notes: ' || b.rule_note, '')
      || '; interim expenses asked: ' || coalesce(usd(b.interim_requested), 'none') || ' (cap for ' || b.claim_type || ': '
      || usd(ct.interim_cap_usd) || '); payments already made on this booking: '
      || (SELECT count(*) FROM service_payments sp WHERE sp.booking_id = c.booking_id)
    WHEN 'COMPENSATION' THEN
      coalesce((SELECT e.detail FROM compensation_eligibility(c.booking_id) e), 'No disruption band applies any more')
      || '; compensation already paid on this booking: '
      || usd((SELECT coalesce(sum(sp.amount_usd), 0) FROM service_payments sp WHERE sp.booking_id = c.booking_id AND sp.kind = 'COMPENSATION'))
    WHEN 'CONFIRM_SSR' THEN
      'Assistance request ' || ar.request_id || ' on ' || af.flight_number || ' ' || af.origin || '->' || af.destination
      || ' departing ' || to_char(af.est_departure, 'YYYY-MM-DD HH24:MI') || ': '
      || (SELECT string_agg(ss.ssr_code || ' (' || s.label || ') ' || ss.status, '; ' ORDER BY s.sort_order)
            FROM segment_ssrs ss JOIN ssr_codes s ON s.code = ss.ssr_code WHERE ss.request_id = ar.request_id)
      || '; medical clearance needed: ' || CASE WHEN ar.medical_clearance THEN 'yes (MEDIF required)' ELSE 'no' END
    ELSE
      'No parked action. Booking legs: '
      || coalesce((SELECT string_agg(s.flight_number || ' ' || s.origin || '->' || s.destination || ' ' || f.status
                                     || CASE WHEN f.delay_minutes > 0 THEN ' ' || f.delay_minutes || ' min late' ELSE '' END,
                                     '; ' ORDER BY s.segment_order)
                     FROM booking_segments s JOIN flights f ON f.flight_number = s.flight_number WHERE s.booking_id = c.booking_id), 'none')
    END
    FROM service_cases c
    LEFT JOIN baggage_claims b ON b.case_id = c.case_id AND c.parked_action LIKE 'INTERIM\_EXPENSE:%'
    LEFT JOIN flights bf ON bf.flight_number = b.flight_number
    LEFT JOIN baggage_guide bt ON bt.section = 'BAG_TYPE' AND bt.term = b.bag_type
    LEFT JOIN baggage_claim_types ct ON ct.claim_type = b.claim_type
    LEFT JOIN assistance_requests ar ON ar.case_id = c.case_id AND c.parked_action LIKE 'CONFIRM\_SSR:%'
    LEFT JOIN flights af ON af.flight_number = ar.flight_number
   WHERE c.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue: OPEN cases ordered by reply-due time. Another team's cases never appear.
CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id TEXT, request VARCHAR, traveller TEXT, opened_on DATE, age_days INTEGER,
               reply_due DATE, sla_status TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.traveller, q.opened_on, q.age_days, q.reply_due, q.sla_status, q.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT c.case_id, t.label, traveler_display(c.booking_id) AS traveller, c.created_at::date AS opened_on,
             (current_date - c.created_at::date)::int AS age_days, c.sla_due_at::date AS reply_due,
             CASE WHEN c.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN c.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             c.requested_amount, c.sla_due_at
        FROM service_cases c JOIN service_teams t ON t.request_type = c.request_type
       WHERE sr.reviewer_id IS NOT NULL AND t.team = sr.team AND c.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at, q.case_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id TEXT, request VARCHAR, case_status VARCHAR, traveller TEXT, opened_on DATE, reply_due DATE,
               traveler_statement TEXT, agent_brief TEXT, requested_amount NUMERIC, max_approvable NUMERIC,
               your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN c.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         c.case_id, t.label, c.status, traveler_display(c.booking_id), c.created_at::date, c.sla_due_at::date,
         c.traveler_statement, c.agent_brief, c.requested_amount, case_eligible_max(c.case_id),
         CASE WHEN c.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(c.case_id),
         CASE WHEN c.case_id IS NULL THEN NULL
              WHEN c.status <> 'OPEN' THEN 'Already decided.'
              WHEN c.parked_action LIKE 'CONFIRM\_SSR:%' THEN 'APPROVE confirms the requested assistance on the flight; REJECT '
                   || 'leaves it unconfirmed. Give an internal note and a message for the traveller.'
              WHEN case_eligible_max(c.case_id) IS NOT NULL THEN 'APPROVE a payment of any amount up to '
                   || usd(case_eligible_max(c.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(c.case_id)
                           THEN ' (above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer)' ELSE '' END
                   || ', or REJECT; with an internal note and a message for the traveller.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the traveller (the team completes the request).' END,
         c.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = c.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases c ON c.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND c.request_type IN (SELECT x.request_type FROM service_teams x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id TEXT, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT,
               customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; c service_cases; t service_teams; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_txt TEXT := norm_amount(p_amount); v_msg TEXT;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO c FROM service_cases x WHERE x.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, left(v_ref, 40), 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT * INTO t FROM service_teams x WHERE x.request_type = c.request_type;
  IF t.team <> rv.team THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_YOUR_TEAM', 'That case is not in your team''s queue, so you cannot decide it.');
    RETURN;
  END IF;
  IF c.status <> 'OPEN' THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ALREADY_DECIDED', 'This case was already decided (' || c.status || '). Nothing was changed.');
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
  v_max := case_eligible_max(c.case_id);
  IF v_dec = 'APPROVE' AND v_max IS NOT NULL THEN
    v_amt := CASE WHEN v_txt = '' OR v_txt = 'ALL' OR v_txt = 'FULL' THEN v_max
                  WHEN v_txt ~ '^-?[0-9]+(\.[0-9]+)?$' THEN round(v_txt::numeric, 2) END;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > v_max THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID',
                'The approved amount must be more than $0 and no more than ' || usd(v_max) || ' (the amount requested, within policy).');
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
                  ELSE 'After review, your ' || t.label || ' was not approved. The team will write to you with the reasons.' END);
  INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_text)
    VALUES (rv.reviewer_id, v_ref, CASE WHEN v_dec = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END, 'Decision recorded.');
  RETURN QUERY SELECT c.case_id, rv.reviewer_id::varchar, v_dec::varchar, v_amt, left(trim(p_note), 2000), left(v_msg, 2000);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION decide_case_result(p_token TEXT, p_case TEXT)
RETURNS TABLE (outcome TEXT, case_id TEXT, decision VARCHAR, approved_amount NUMERIC, reason_code VARCHAR, reason_text TEXT,
               case_status VARCHAR, executed_action TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' ELSE coalesce(da.outcome, 'BLOCKED') END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED')
                   OR da.reason_code IN ('ALREADY_DECIDED','OVER_AUTHORITY','AMOUNT_INVALID','NOTE_REQUIRED','INVALID_DECISION')
              THEN c.case_id END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.decision END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.approved_amount END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN da.attempt_id IS NULL THEN 'NOT_FOUND' ELSE da.reason_code END,
         CASE WHEN sr.reviewer_id IS NULL THEN 'Only a verified reviewer can decide cases. Nothing was changed.'
              WHEN da.attempt_id IS NULL THEN 'There is no case with that number.'
              ELSE da.reason_text END,
         CASE WHEN da.outcome IS NOT NULL AND da.reason_code IS DISTINCT FROM 'NOT_FOUND'
                   AND da.reason_code IS DISTINCT FROM 'NOT_YOUR_TEAM' THEN c.status END,
         CASE WHEN da.outcome = 'APPROVED' THEN
                coalesce((SELECT 'Payment ' || p.payment_id || ': ' || usd(p.amount_usd) || ' '
                                 || CASE p.kind WHEN 'COMPENSATION' THEN 'travel credit for the disruption on ' || p.ref
                                                ELSE 'interim expenses for baggage claim ' || p.ref END || '.'
                            FROM service_payments p WHERE p.case_id = c.case_id),
                         (SELECT 'Assistance confirmed (' || x.confirmation_id || '): ' || ar.codes || ' on ' || ar.flight_number || '.'
                            FROM ssr_confirmations x JOIN assistance_requests ar ON ar.request_id = x.request_id
                           WHERE x.case_id = c.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = left(norm_ref(p_case), 40)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases c ON c.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = c.case_id;
$$ LANGUAGE sql STABLE;

-- Guarded rows the decision trigger uses to execute the parked action (the same checks every time).
CREATE OR REPLACE FUNCTION payment_row(p_case TEXT, p_kind TEXT, p_ref TEXT, p_amount NUMERIC)
RETURNS TABLE (payment_id TEXT, case_id TEXT, booking_id INTEGER, kind TEXT, ref TEXT, amount_usd NUMERIC) AS $$
  SELECT 'PAY-' || lpad(nextval('pay_seq')::text, 5, '0'), c.case_id, c.booking_id, p_kind, p_ref, p_amount
    FROM service_cases c
   WHERE c.case_id = p_case AND c.parked_action = p_kind || ':' || p_ref
     AND p_amount > 0 AND p_amount <= c.requested_amount
     AND NOT EXISTS (SELECT 1 FROM service_payments sp WHERE sp.case_id = p_case);
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION ssr_confirmation_row(p_request TEXT, p_case TEXT)
RETURNS TABLE (confirmation_id TEXT, request_id TEXT, case_id TEXT) AS $$
  SELECT 'SSRC-' || lpad(nextval('ssrc_seq')::text, 5, '0'), ar.request_id::text, p_case
    FROM assistance_requests ar
   WHERE ar.request_id = p_request
     AND NOT EXISTS (SELECT 1 FROM ssr_confirmations x WHERE x.request_id = ar.request_id OR x.case_id = p_case)
     AND EXISTS (SELECT 1 FROM service_cases c WHERE c.case_id = p_case AND c.parked_action = 'CONFIRM_SSR:' || ar.request_id);
$$ LANGUAGE sql VOLATILE;

-- A confirmation event confirms that request's SSRs on the segment.
CREATE OR REPLACE FUNCTION apply_ssr_confirmation() RETURNS TRIGGER AS $$
BEGIN
  UPDATE segment_ssrs SET status = 'CONFIRMED', confirmed_at = NEW.created_at WHERE request_id = NEW.request_id;
  INSERT INTO agent_audit (pnr, action, detail)
    SELECT ar.pnr, 'SSR_CONFIRMED', NEW.confirmation_id || ': ' || ar.codes || ' on ' || ar.flight_number || ' (case ' || NEW.case_id || ')'
      FROM assistance_requests ar WHERE ar.request_id = NEW.request_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_ssr_confirmation AFTER INSERT ON ssr_confirmations FOR EACH ROW EXECUTE FUNCTION apply_ssr_confirmation();

CREATE OR REPLACE FUNCTION audit_payment() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (pnr, action, detail)
    SELECT b.pnr, 'PAYMENT_ISSUED', NEW.payment_id || ': ' || NEW.kind || ' ' || usd(NEW.amount_usd) || ' for ' || NEW.ref
                                    || ' (case ' || NEW.case_id || ')'
      FROM bookings b WHERE b.booking_id = NEW.booking_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_payment AFTER INSERT ON service_payments FOR EACH ROW EXECUTE FUNCTION audit_payment();

-- The decision event: case status + traveller message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE c service_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'nothing';
BEGIN
  SELECT * INTO c FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(c.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(c.parked_action, ''), ':', 2);
  IF NEW.decision = 'APPROVE' AND v_kind IN ('COMPENSATION', 'INTERIM_EXPENSE') THEN
    INSERT INTO service_payments (payment_id, case_id, booking_id, kind, ref, amount_usd)
      SELECT * FROM payment_row(NEW.case_id, v_kind, v_ref, NEW.approved_amount);
    IF FOUND THEN v_done := v_kind || ' payment of ' || usd(NEW.approved_amount) || ' for ' || v_ref; END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'CONFIRM_SSR' THEN
    INSERT INTO ssr_confirmations (confirmation_id, request_id, case_id)
      SELECT * FROM ssr_confirmation_row(v_ref, NEW.case_id);
    IF FOUND THEN v_done := 'assistance confirmed for ' || v_ref; END IF;
  END IF;
  INSERT INTO agent_audit (pnr, actor, action, detail)
    VALUES (c.pnr, NEW.reviewer_id, 'CASE_DECIDED',
            NEW.case_id || ': ' || NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change. Cannot be bypassed
-- by the LLM because they fire in the database, not the app.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'REVIEWER' THEN
    INSERT INTO agent_audit (pnr, actor, action, detail)
      VALUES (NULL, NEW.reviewer_id, 'REVIEWER_VERIFY', 'reviewer session issued for ' || NEW.reviewer_id);
  ELSE
    INSERT INTO agent_audit (pnr, action, detail)
      SELECT b.pnr, 'VERIFY_SESSION_ISSUED', 'session issued for booking ' || b.pnr
        FROM bookings b WHERE b.booking_id = NEW.booking_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON traveler_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_proposal() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (pnr, action, detail)
    SELECT b.pnr, 'REBOOK_PROPOSED', NEW.from_flight || ' -> ' || NEW.to_flight || ' (action ' || NEW.action_id || ')'
      FROM bookings b WHERE b.booking_id = NEW.booking_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_proposal AFTER INSERT ON pending_actions FOR EACH ROW EXECUTE FUNCTION audit_proposal();

CREATE OR REPLACE FUNCTION audit_rebooking() RETURNS TRIGGER AS $$
DECLARE v_pnr VARCHAR;
BEGIN
  SELECT b.pnr INTO v_pnr FROM bookings b JOIN booking_segments s ON s.booking_id = b.booking_id
   WHERE s.segment_id = NEW.segment_id;
  INSERT INTO agent_audit (pnr, action, detail)
    VALUES (v_pnr, 'REBOOK_EXECUTED', NEW.from_flight || ' -> ' || NEW.to_flight || ' seat ' || NEW.new_seat);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_rebooking AFTER INSERT ON rebookings FOR EACH ROW EXECUTE FUNCTION audit_rebooking();

CREATE OR REPLACE FUNCTION audit_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (pnr, action, detail)
    VALUES (NEW.pnr, 'SERVICE_CASE_OPENED', NEW.request_type || ' (' || NEW.case_id || ')'
            || coalesce(' parks ' || NEW.parked_action, ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_case AFTER INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION audit_case();

CREATE OR REPLACE FUNCTION audit_email() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (pnr, action, detail) VALUES (NEW.pnr, 'EMAIL_LOGGED', NEW.reference_id || ': ' || NEW.subject);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_email AFTER INSERT ON email_log FOR EACH ROW EXECUTE FUNCTION audit_email();

-- =====================================================================
-- AGENT REFERENCE READS - the only SQL the baggage_claim_agent and special_assistance_agent tools run
-- (SELECT * FROM ref_<topic>(CAST(?lookup AS text))). SELECT-only, STABLE, no identity argument. The lookup is the one
-- value the model may supply. (The rebooking_options_agent keeps its search_alternatives() read.)
-- =====================================================================
-- empty / NULL -> the whole guide; otherwise one or more words separated by , or ; - a row matches when a word equals
-- its section (spaces = underscores) or appears in its term or meaning (plain substring, no wildcards). Unknown -> 0 rows.
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

-- The baggage guide: claim types and report fields come from the rule tables (one source of truth; the interim caps are
-- never returned), plus the bag-type chart, colour codes, content categories and the standard claim note.
CREATE OR REPLACE FUNCTION ref_baggage_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT 'CLAIM_TYPE'::text AS sec, t.claim_type::text AS trm,
                 t.meaning || CASE WHEN t.min_days_after_arrival > 0
                                   THEN ' Use it only ' || t.min_days_after_arrival || ' or more days after the flight arrived; before that the bag is DELAYED.'
                                   ELSE '' END AS mng, t.sort_order AS ord
            FROM baggage_claim_types t
          UNION ALL
          SELECT g.section::text, g.term::text, g.meaning::text, g.entry_id FROM baggage_guide g
          UNION ALL
          SELECT 'REPORT_FIELD', f.field::text, f.meaning || ' Needed for: ' || array_to_string(f.required_for, ', ') || '.', f.sort_order
            FROM baggage_report_fields f) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['CLAIM_TYPE','BAG_TYPE','COLOUR','CONTENT','REPORT_FIELD','CLAIM_NOTE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

-- The assistance codes: the IATA SSR codes from ssr_codes (one source of truth with the request rules) plus how to choose
-- and the standard line.
CREATE OR REPLACE FUNCTION ref_assistance_codes(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT 'SSR_CODE'::text AS sec, s.code::text AS trm,
                 s.label || ': ' || s.meaning
                 || CASE WHEN s.medical_clearance THEN ' Needs medical clearance (MEDA) by the Accessibility Desk.' ELSE '' END
                 || CASE WHEN NOT s.traveller_requestable THEN ' Arranged by the Accessibility Desk only.' ELSE '' END AS mng,
                 s.sort_order AS ord
            FROM ssr_codes s
          UNION ALL
          SELECT g.section::text, g.term::text, g.meaning::text, g.entry_id FROM assistance_guide g) r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['SSR_CODE','HOW_TO_CHOOSE','STANDARD_LINE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
