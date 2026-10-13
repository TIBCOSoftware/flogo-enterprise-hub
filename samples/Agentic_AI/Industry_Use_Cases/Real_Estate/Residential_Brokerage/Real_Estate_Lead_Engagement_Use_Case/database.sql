-- Brightpath Realty - Real Estate Lead Engagement (GOVERNED) - schema, business rules, demo data.
-- PostgreSQL 14+.  Database: realestate_governed
-- Load:  createdb realestate_governed  &&  psql -d realestate_governed -f database.sql
--
-- =====================================================================
-- Fictional US residential brokerage "Brightpath Realty" (Larkspur Valley metro), assistant "Harper".
-- The rules live HERE, not in any prompt:
--   * session_lead() / session_reviewer()     identity: every tool is scoped by a session token; lead and reviewer
--                                             tokens are not interchangeable (role checked)
--   * verify_*_fn()                           e-mail + one-time code (staff id + code) -> session;
--                                             5 failures / 15 min -> LOCKED
--   * my_* / search_listings / listing_*      scoped reads - only the caller's own rows; another lead's id -> NOT_FOUND
--   * showing_eval()                          Active listing, future slot in showing hours, notice, horizon, no double
--                                             booking, lead stage allows it, at most 3 upcoming showings
--   * propose_showing_fn() / confirm_showing_fn()  two-step: PROPOSED/BLOCKED with 15-minute expiry; confirm re-checks
--   * trg_showing_event                       the appointment is created in the DB and a New/Nurturing lead moves to
--                                             Active (lead_stage_events + trg_lead_stage_event)
--   * follow_up_row()                         agent follow-up; priority + due time from the intent agent's output, in SQL
--   * open_case_row()                         human-owned requests routed by case_routing (team + SLA)
--   * decide_case_row() + trg_review_decision the reviewer loop: role/team/authority/amount checks, then the parked
--                                             action (list-price change / stage change) runs through guarded rows
--   * email_log_row()                         email only for the caller's showing / follow-up / decided case
--   * ref_listing_match() / ref_lead_intent() / ref_fair_housing()  the A2A agents' ONLY database access:
--                                             read-only reference tables (listing-match guide, lead-intent guide,
--                                             Fair Housing guide + who reviews) with no lead, staff, case or contact
--                                             data; one optional lookup term, never an identity
-- Hidden from leads: one-time codes, internal_note, agent_brief, follow-up priority, reviewer identity, approval limits.
-- Fair Housing: no table holds school ratings, crime data or demographics - the assistant cannot steer on them.
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

DROP TABLE IF EXISTS email_log, agent_audit, listing_price_changes, decide_attempts, review_decisions, case_requests,
  service_cases, follow_up_attempts, follow_up_tasks, lead_stage_events, confirm_attempts, showing_events, pending_actions,
  appointments, lead_activity, verify_attempts, sessions, reviewers, leads, listings, agents, area_market_stats,
  case_routing, showing_policy,
  listing_match_guide, lead_intent_guide, fair_housing_guide CASCADE;

-- Agent reference tables: what the three A2A agents may read (through ref_* functions only). Same shape for all
-- three - section / term / meaning - and NO lead, staff, case, session or contact data, ever. No school, crime or
-- demographic data either (Fair Housing): the Fair Housing guide only says which questions are protected and where
-- the objective public sources are.
CREATE TABLE listing_match_guide (                -- listing_match_agent: columns, walk score, amenities, ranking
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('COLUMN', 'WALK_SCORE', 'AMENITY', 'RANKING', 'EXCLUDE',
                                                      'FAIR_HOUSING', 'NOTE_LINE')),
  term        VARCHAR(60) NOT NULL,               -- office with a door
  meaning     VARCHAR(400) NOT NULL,              -- a true home office - the strongest match ...
  UNIQUE (section, term)
);

CREATE TABLE lead_intent_guide (                  -- lead_intent_agent: intent / timeline / pre-approval meanings
  entry_id    SERIAL PRIMARY KEY,                 -- (the follow-up priority is decided in SQL, never here)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('INTENT', 'TIMELINE', 'PRE_APPROVAL', 'MOTIVATION', 'RULE',
                                                      'FIRST_CALL')),
  term        VARCHAR(60) NOT NULL,               -- 0_3_MONTHS
  meaning     VARCHAR(400) NOT NULL,              -- now, ASAP, "in a few weeks" ...
  UNIQUE (section, term)
);

CREATE TABLE fair_housing_guide (                 -- fair_housing_agent: protected classes, categories, neutral answers
  entry_id    SERIAL PRIMARY KEY,                 -- (the ROUTING row - who reviews - comes from case_routing)
  section     VARCHAR(20) NOT NULL CHECK (section IN ('PROTECTED', 'CATEGORY', 'NEUTRAL_ANSWER', 'RULE')),
  term        VARCHAR(60) NOT NULL,               -- SCHOOLS
  meaning     VARCHAR(400) NOT NULL,              -- Brightpath agents do not rate schools ...
  UNIQUE (section, term)
);

-- ---------------------------------------------------------------------
-- Policy, routing, market reference
-- ---------------------------------------------------------------------
CREATE TABLE showing_policy (                    -- exactly one row; edit here to change the thresholds
  id                    INTEGER PRIMARY KEY CHECK (id = 1),
  first_start_hour      INTEGER NOT NULL,        -- earliest showing start (local time)
  last_start_hour       INTEGER NOT NULL,        -- latest showing start
  min_notice_hours      INTEGER NOT NULL,        -- a showing must start at least this many hours from now
  max_days_ahead        INTEGER NOT NULL,        -- and no more than this many days ahead
  max_upcoming          INTEGER NOT NULL,        -- upcoming showings one lead may hold
  max_price_change_pct  NUMERIC(5,2) NOT NULL    -- a list-price change must stay within +/- this % of the current price
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE case_routing (
  request_type      VARCHAR(30) PRIMARY KEY,
  label             VARCHAR(40) NOT NULL,        -- lead-facing name
  team              VARCHAR(40) NOT NULL,
  sla_business_days INTEGER NOT NULL,
  sla_text          VARCHAR(160) NOT NULL,
  lead_openable     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE area_market_stats (
  area                  VARCHAR(40) PRIMARY KEY,  -- Cedar Hollow, Willow Bend, Larkspur Downtown, Northgate
  median_price          NUMERIC(12,2) NOT NULL,
  avg_days_on_market    INTEGER NOT NULL,
  active_listings       INTEGER NOT NULL,
  median_price_per_sqft NUMERIC(8,2) NOT NULL,
  yoy_price_change_pct  NUMERIC(5,2) NOT NULL,
  months_of_inventory   NUMERIC(4,1) NOT NULL,
  as_of_month           VARCHAR(20) NOT NULL
);

-- ---------------------------------------------------------------------
-- Brightpath agents, listings, leads, reviewers (staff)
-- ---------------------------------------------------------------------
CREATE TABLE agents (
  agent_id      VARCHAR(10) PRIMARY KEY,         -- AGT-101
  full_name     VARCHAR(60) NOT NULL,
  title         VARCHAR(40) NOT NULL,
  email         VARCHAR(100) NOT NULL,           -- business contact (shown to the agent's own leads as agent_email)
  phone         VARCHAR(20) NOT NULL,
  service_area  VARCHAR(80) NOT NULL,
  specialties   VARCHAR(120) NOT NULL
);

CREATE TABLE listings (
  listing_id      VARCHAR(10) PRIMARY KEY,       -- LST-50001
  address         VARCHAR(80) NOT NULL,          -- fictional street
  area            VARCHAR(40) NOT NULL REFERENCES area_market_stats (area),
  price           NUMERIC(12,2) NOT NULL CHECK (price > 0),
  bedrooms        INTEGER NOT NULL,
  bathrooms       NUMERIC(3,1) NOT NULL,
  sqft            INTEGER NOT NULL,
  lot_sqft        INTEGER,
  property_type   VARCHAR(20) NOT NULL CHECK (property_type IN ('Single Family','Townhouse','Condo')),
  year_built      INTEGER NOT NULL,
  hoa_monthly     NUMERIC(8,2),
  status          VARCHAR(10) NOT NULL CHECK (status IN ('Active','Pending','Sold','Withdrawn')),
  list_date       DATE NOT NULL,
  listing_agent_id VARCHAR(10) NOT NULL REFERENCES agents,
  seller_lead_id  VARCHAR(16),                   -- the Brightpath seller lead who owns it (FK added below)
  features        VARCHAR(400) NOT NULL,         -- facts only: no school, safety or demographic claims (Fair Housing)
  description     VARCHAR(500) NOT NULL
);
CREATE INDEX ix_listings_area ON listings (area, status, price);

CREATE TABLE leads (
  lead_id            VARCHAR(16) PRIMARY KEY,    -- LEAD-2026-00101
  first_name         VARCHAR(40) NOT NULL,
  last_name          VARCHAR(40) NOT NULL,
  email              VARCHAR(100) NOT NULL UNIQUE,  -- login factor; confirmations go to the EMAIL_TO demo inbox
  phone              VARCHAR(20) NOT NULL,       -- HIDDEN from reviewers and agents
  otp_code           VARCHAR(6) NOT NULL,        -- HIDDEN: demo stand-in for the e-mailed one-time code
  lead_type          VARCHAR(10) NOT NULL CHECK (lead_type IN ('Buyer','Seller','Both')),
  stage              VARCHAR(16) NOT NULL CHECK (stage IN ('New','Nurturing','Active','Under Contract','Closed','Lost')),
  budget_min         NUMERIC(12,2),
  budget_max         NUMERIC(12,2),
  preferred_area     VARCHAR(40),
  min_bedrooms       INTEGER,
  min_bathrooms      NUMERIC(3,1),
  property_type_pref VARCHAR(20),
  timeline           VARCHAR(20),
  pre_approved       BOOLEAN NOT NULL DEFAULT FALSE,
  pre_approval_amount NUMERIC(12,2),
  source             VARCHAR(30) NOT NULL,       -- Website, Open house, Referral, Listing inquiry
  assigned_agent_id  VARCHAR(10) NOT NULL REFERENCES agents,
  created_at         TIMESTAMP NOT NULL,
  last_activity_at   TIMESTAMP,
  active             BOOLEAN NOT NULL DEFAULT TRUE
);
ALTER TABLE listings ADD CONSTRAINT fk_listing_seller FOREIGN KEY (seller_lead_id) REFERENCES leads (lead_id);

CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,       -- BPR-7101 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(40) NOT NULL,          -- matches case_routing.team
  job_title       VARCHAR(40) NOT NULL,
  one_time_code   VARCHAR(6)  NOT NULL,          -- HIDDEN
  approval_limit  NUMERIC(12,2),                 -- list-price change magnitude in USD; NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL CHECK (role IN ('LEAD','REVIEWER')),
  lead_id        VARCHAR(16) REFERENCES leads,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'LEAD' AND lead_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND lead_id IS NULL))
);

-- Every verify call (throttle + readback).
CREATE TABLE verify_attempts (
  attempt_id   BIGSERIAL PRIMARY KEY,
  role         VARCHAR(10) NOT NULL,
  identifier   VARCHAR(100) NOT NULL,            -- normalised e-mail / staff id
  outcome      VARCHAR(14) NOT NULL CHECK (outcome IN ('VERIFIED','VERIFY_FAILED','LOCKED')),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_verify_attempts ON verify_attempts (role, identifier, created_at);

-- ---------------------------------------------------------------------
-- Engagement: activity, showings
-- ---------------------------------------------------------------------
CREATE TABLE lead_activity (
  activity_id   BIGSERIAL PRIMARY KEY,
  lead_id       VARCHAR(16) NOT NULL REFERENCES leads,
  listing_id    VARCHAR(10) REFERENCES listings,
  activity_type VARCHAR(30) NOT NULL,            -- Search | Viewed Listing | Saved Listing | Showing Booked | Stage Change | Follow-up Requested | Case Opened
  detail        VARCHAR(400),
  created_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_activity_lead ON lead_activity (lead_id, created_at);

CREATE TABLE appointments (
  appointment_id VARCHAR(12) PRIMARY KEY,        -- APT-70101
  lead_id        VARCHAR(16) NOT NULL REFERENCES leads,
  listing_id     VARCHAR(10) NOT NULL REFERENCES listings,
  agent_id       VARCHAR(10) NOT NULL REFERENCES agents,
  scheduled_for  TIMESTAMP NOT NULL,
  status         VARCHAR(10) NOT NULL CHECK (status IN ('Requested','Confirmed','Completed','Cancelled')),
  source         VARCHAR(6) NOT NULL DEFAULT 'SEED' CHECK (source IN ('SEED','CHAT')),
  notes          VARCHAR(300),
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_appt_lead ON appointments (lead_id, scheduled_for);
CREATE INDEX ix_appt_listing ON appointments (listing_id, scheduled_for);

-- ---------------------------------------------------------------------
-- Two-step showing booking: proposals -> confirmed events (the only path that creates an appointment)
-- ---------------------------------------------------------------------
CREATE TABLE pending_actions (
  proposal_id    TEXT PRIMARY KEY DEFAULT 'BPR-PRP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  lead_id        VARCHAR(16) NOT NULL REFERENCES leads,
  action_type    VARCHAR(14) NOT NULL CHECK (action_type IN ('BOOK_SHOWING')),
  target_key     TEXT NOT NULL,                  -- normalised request, shared by the write-row and the readback
  listing_id     VARCHAR(10),
  slot           TIMESTAMP,
  outcome        VARCHAR(10) NOT NULL CHECK (outcome IN ('PROPOSED','BLOCKED')),
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);
CREATE INDEX ix_pending_lead ON pending_actions (lead_id, action_type, target_key, created_at);

CREATE TABLE showing_events (
  event_id       BIGSERIAL PRIMARY KEY,
  reference      VARCHAR(12) NOT NULL UNIQUE,    -- APT-70101 (becomes the appointment id)
  proposal_id    TEXT NOT NULL UNIQUE REFERENCES pending_actions,
  lead_id        VARCHAR(16) NOT NULL REFERENCES leads,
  listing_id     VARCHAR(10) NOT NULL REFERENCES listings,
  agent_id       VARCHAR(10) NOT NULL REFERENCES agents,
  slot           TIMESTAMP NOT NULL,
  summary        TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE confirm_attempts (
  attempt_id     SERIAL PRIMARY KEY,
  lead_id        VARCHAR(16) NOT NULL REFERENCES leads,
  proposal_ref   TEXT NOT NULL,
  outcome        VARCHAR(14) NOT NULL,
  reason_code    VARCHAR(24),
  reason_text    TEXT,
  reference      VARCHAR(12),
  new_stage      VARCHAR(16),
  summary        TEXT,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Stage changes are events: SYSTEM (a confirmed showing) or REVIEWER (an approved stage_change case).
CREATE TABLE lead_stage_events (
  event_id     BIGSERIAL PRIMARY KEY,
  lead_id      VARCHAR(16) NOT NULL REFERENCES leads,
  old_stage    VARCHAR(16) NOT NULL,
  new_stage    VARCHAR(16) NOT NULL,
  source       VARCHAR(8) NOT NULL CHECK (source IN ('SYSTEM','REVIEWER')),
  reference    VARCHAR(20),                      -- the appointment / case that caused it
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Agent follow-ups (priority from the intent agent's output, in SQL)
-- ---------------------------------------------------------------------
CREATE TABLE follow_up_tasks (
  task_no      BIGSERIAL PRIMARY KEY,
  task_id      VARCHAR(12) NOT NULL UNIQUE,      -- FUP-90101
  lead_id      VARCHAR(16) NOT NULL REFERENCES leads,
  agent_id     VARCHAR(10) NOT NULL REFERENCES agents,
  message      TEXT NOT NULL,                    -- the lead's own words
  intent       VARCHAR(14) NOT NULL,
  timeline     VARCHAR(12) NOT NULL,
  pre_approved VARCHAR(8) NOT NULL,
  motivation   VARCHAR(300),
  agent_brief  TEXT,                             -- HIDDEN from the lead: lead_intent_agent's answer
  priority     VARCHAR(8) NOT NULL CHECK (priority IN ('HOT','WARM','NURTURE')),   -- HIDDEN from the lead
  due_at       TIMESTAMP NOT NULL,
  status       VARCHAR(6) NOT NULL DEFAULT 'Open' CHECK (status IN ('Open','Done')),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE follow_up_attempts (                -- every request_agent_follow_up call (readback)
  attempt_id   SERIAL PRIMARY KEY,
  lead_id      VARCHAR(16) NOT NULL REFERENCES leads,
  outcome      VARCHAR(20) NOT NULL,
  task_id      VARCHAR(12),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Human-owned cases, the reviewer loop, price changes, audit, email
-- ---------------------------------------------------------------------
CREATE TABLE service_cases (
  case_no          BIGSERIAL PRIMARY KEY,
  case_id          VARCHAR(16) NOT NULL UNIQUE,  -- BPR-CASE-000101
  lead_id          VARCHAR(16) NOT NULL REFERENCES leads,
  request_type     VARCHAR(30) NOT NULL REFERENCES case_routing,
  summary          TEXT NOT NULL,                -- the lead's request, in their words (neutral)
  reference_id     VARCHAR(40),                  -- listing id / target stage / fair-housing category
  listing_id       VARCHAR(10) REFERENCES listings,
  target_stage     VARCHAR(16),
  category         VARCHAR(20),                  -- fair_housing_review: normalised category
  requested_amount NUMERIC(12,2),                -- offer USD / new list price USD
  current_amount   NUMERIC(12,2),                -- list price when the case was opened
  parked_action    VARCHAR(40),                  -- LIST_PRICE:<listing> / STAGE:<lead>
  agent_brief      TEXT,                         -- AI-prepared neutral brief for the reviewer (never shown to the lead)
  priority         VARCHAR(8) NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('NORMAL','HIGH')),
  status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at       TIMESTAMP NOT NULL,
  customer_message TEXT,                         -- lead-safe outcome text, set by the decision
  approved_amount  NUMERIC(12,2),
  decided_at       TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cases_lead ON service_cases (lead_id, request_type, status);

CREATE TABLE case_requests (                     -- every open_service_case call (readback)
  request_id    SERIAL PRIMARY KEY,
  lead_id       VARCHAR(16) NOT NULL REFERENCES leads,
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

CREATE TABLE listing_price_changes (
  change_id    BIGSERIAL PRIMARY KEY,
  reference    VARCHAR(12) NOT NULL UNIQUE,      -- LPC-000101
  listing_id   VARCHAR(10) NOT NULL REFERENCES listings,
  old_price    NUMERIC(12,2) NOT NULL,
  new_price    NUMERIC(12,2) NOT NULL CHECK (new_price > 0),
  source       VARCHAR(8) NOT NULL CHECK (source IN ('SEED','REVIEWER')),
  case_id      VARCHAR(16),
  created_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE agent_audit (
  audit_id    BIGSERIAL PRIMARY KEY,
  event_type  VARCHAR(24) NOT NULL,              -- SHOWING_BOOKED / STAGE_CHANGED / FOLLOW_UP / CASE_OPENED / CASE_DECIDED / PRICE_CHANGED
  actor       VARCHAR(16) NOT NULL,              -- lead id, reviewer id, or SYSTEM
  subject_id  VARCHAR(40) NOT NULL,              -- reference / case id
  detail      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE email_log (
  email_id    SERIAL PRIMARY KEY,
  lead_id     VARCHAR(16) NOT NULL REFERENCES leads,
  reference   VARCHAR(16) NOT NULL,
  subject     TEXT NOT NULL,
  logged_at   TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

DROP SEQUENCE IF EXISTS appt_seq;
CREATE SEQUENCE appt_seq START 70101;            -- showings booked in chat: APT-70101, ... (reset in seed_data.sql)

-- =====================================================================
-- HELPERS
-- =====================================================================
-- $689,000 / $1,250.50 (locale-independent separators); whole dollars shown without cents
CREATE OR REPLACE FUNCTION usd(n NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN n IS NULL THEN NULL
              WHEN round(n, 2) = trunc(n) THEN '$' || to_char(trunc(n), 'FM999,999,999,990')
              ELSE '$' || to_char(round(n, 2), 'FM999,999,990.00') END
$$ LANGUAGE sql IMMUTABLE;
-- dates and times go out as text so every client shows 2026-10-13 / 2026-10-16 14:00, never an RFC3339 timestamp
CREATE OR REPLACE FUNCTION d(p DATE) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION dt(p TIMESTAMP) RETURNS TEXT AS $$ SELECT to_char(p, 'YYYY-MM-DD HH24:MI') $$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION dt_long(p TIMESTAMP) RETURNS TEXT AS $$
  SELECT trim(to_char(p, 'Day')) || ' ' || to_char(p, 'YYYY-MM-DD') || ' at ' || ltrim(to_char(p, 'HH12:MI AM'), '0')
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION today_text() RETURNS TEXT AS $$
  SELECT to_char(current_date, 'YYYY-MM-DD') || ' (' || trim(to_char(current_date, 'Day')) || ')'
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION norm_email(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(trim(coalesce(p, ''))), 100)
$$ LANGUAGE sql IMMUTABLE;
-- BPR-7101 / bpr7101 / 7101 -> BPR-7101
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{4}$' THEN 'BPR-' || x
              WHEN x ~ '^BPR[0-9]{4}$' THEN 'BPR-' || substr(x, 4)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- LST-50001 / lst50001 / 50001 / MLS LST 50001 -> LST-50001
CREATE OR REPLACE FUNCTION norm_listing(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^[0-9]{5}$' THEN 'LST-' || x
              WHEN x ~ 'LST[0-9]{5}$' THEN 'LST-' || right(x, 5)
              ELSE left(x, 40) END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- A listing by id, or by its street address ("1418 Quillfeather Ln" / "1418 quillfeather lane"); NULL when unknown.
CREATE OR REPLACE FUNCTION find_listing(p TEXT) RETURNS TEXT AS $$
  SELECT coalesce(
    (SELECT l.listing_id FROM listings l WHERE l.listing_id = norm_listing(p)),
    (SELECT l.listing_id FROM listings l
      WHERE length(trim(coalesce(p, ''))) >= 6
        AND lower(regexp_replace(trim(p), '[^A-Za-z0-9]', '', 'g'))
            LIKE lower(regexp_replace(split_part(l.address, ' ', 1) || split_part(l.address, ' ', 2), '[^A-Za-z0-9]', '', 'g')) || '%'
      ORDER BY l.listing_id LIMIT 1))
$$ LANGUAGE sql STABLE;
-- ids typed by people or the model: ' bpr-case-000101 ' -> 'BPR-CASE-000101'
CREATE OR REPLACE FUNCTION norm_ref(p TEXT) RETURNS TEXT AS $$
  SELECT left(upper(regexp_replace(trim(coalesce(p, '')), '\s+', '', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_request_type(p TEXT) RETURNS TEXT AS $$
  SELECT left(lower(regexp_replace(trim(coalesce(p, '')), '[\s-]+', '_', 'g')), 40)
$$ LANGUAGE sql IMMUTABLE;
-- '$598,000' / '598000' / '598k' / '$1.2M' -> '598000'; else upper text
CREATE OR REPLACE FUNCTION norm_amount(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^-?[0-9]+(\.[0-9]+)?$' THEN trim_scale(x::numeric)::text
              WHEN x ~ '^[0-9]+(\.[0-9]+)?K$' THEN trim_scale(substr(x, 1, length(x) - 1)::numeric * 1000)::text
              WHEN x ~ '^[0-9]+(\.[0-9]+)?M$' THEN trim_scale(substr(x, 1, length(x) - 1)::numeric * 1000000)::text
              ELSE left(x, 20) END
    FROM (SELECT upper(regexp_replace(trim(coalesce(p, '')), '[$,\s]|USD', '', 'gi')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION money_or_null(p TEXT) RETURNS NUMERIC AS $$
  SELECT CASE WHEN norm_amount(p) ~ '^[0-9]+(\.[0-9]+)?$' THEN round(norm_amount(p)::numeric, 2) END
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION int_or_null(p TEXT) RETURNS INTEGER AS $$
  SELECT CASE WHEN x ~ '^[0-9]{1,3}$' THEN x::int END
    FROM (SELECT regexp_replace(trim(coalesce(p, '')), '\s*\+?\s*(bd|bed|beds|bedrooms?|br)?\.?$', '', 'i') AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- '2026-10-20' (also 2026/10/20) -> date; anything else -> NULL
CREATE OR REPLACE FUNCTION date_or_null(p TEXT) RETURNS DATE AS $$
BEGIN
  IF trim(coalesce(p, '')) ~ '^\d{4}[-/]\d{1,2}[-/]\d{1,2}' THEN
    RETURN to_date(replace(substring(trim(p) FROM '^\d{4}[-/]\d{1,2}[-/]\d{1,2}'), '/', '-'), 'YYYY-MM-DD');
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN NULL;
END $$ LANGUAGE plpgsql IMMUTABLE;
-- '2026-10-16 14:00' / '2026-10-16T14:00' / '2026-10-16 2pm' / '2026-10-16 2:00 PM' -> timestamp; else NULL
CREATE OR REPLACE FUNCTION slot_or_null(p TEXT) RETURNS TIMESTAMP AS $$
DECLARE v_d DATE := date_or_null(p); m TEXT[]; h INT; mi INT;
BEGIN
  IF v_d IS NULL THEN RETURN NULL; END IF;
  m := regexp_match(lower(trim(p)), '^\d{4}[-/]\d{1,2}[-/]\d{1,2}[t\s,]+(?:at\s+)?(\d{1,2})(?::(\d{2}))?(?::\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?\s*$');
  IF m IS NULL THEN RETURN NULL; END IF;
  h := m[1]::int; mi := coalesce(m[2], '0')::int;
  IF m[3] IS NOT NULL THEN
    IF h < 1 OR h > 12 THEN RETURN NULL; END IF;
    IF left(m[3], 1) = 'p' AND h < 12 THEN h := h + 12; END IF;
    IF left(m[3], 1) = 'a' AND h = 12 THEN h := 0; END IF;
  END IF;
  IF h > 23 OR mi > 59 THEN RETURN NULL; END IF;
  RETURN v_d + make_time(h, mi, 0);
EXCEPTION WHEN others THEN RETURN NULL;
END $$ LANGUAGE plpgsql IMMUTABLE;
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

CREATE OR REPLACE FUNCTION audit(p_type TEXT, p_actor TEXT, p_subject TEXT, p_detail TEXT) RETURNS VOID AS $$
  INSERT INTO agent_audit (event_type, actor, subject_id, detail) VALUES (p_type, p_actor, p_subject, p_detail)
$$ LANGUAGE sql VOLATILE;

-- A slot is taken when the listing already has a Requested / Confirmed showing starting then.
CREATE OR REPLACE FUNCTION slot_taken(p_listing TEXT, p_slot TIMESTAMP) RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM appointments a WHERE a.listing_id = p_listing AND a.scheduled_for = p_slot
                    AND a.status IN ('Requested','Confirmed'))
$$ LANGUAGE sql STABLE;

-- Free showing slots for a listing: on the hour, in showing hours, notice and horizon respected, not taken.
CREATE OR REPLACE FUNCTION free_slots(p_listing TEXT, p_from DATE, p_to DATE)
RETURNS TABLE (slot TIMESTAMP) AS $$
  SELECT g.s FROM showing_policy pol
    CROSS JOIN LATERAL generate_series(greatest(p_from, current_date)::timestamp + make_interval(hours => pol.first_start_hour),
                                       least(p_to, current_date + pol.max_days_ahead)::timestamp + make_interval(hours => pol.last_start_hour),
                                       INTERVAL '1 hour') g(s)
   WHERE extract(hour FROM g.s) BETWEEN pol.first_start_hour AND pol.last_start_hour
     AND g.s >= clock_timestamp()::timestamp + make_interval(hours => pol.min_notice_hours)
     AND NOT slot_taken(p_listing, g.s)
   ORDER BY g.s
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- IDENTITY (leads and reviewers share the session mechanism; the role is always checked)
-- =====================================================================
-- Always exactly one row: the lead when the token is a valid LEAD token of an active lead, else NULL -> SESSION_INVALID.
CREATE OR REPLACE FUNCTION session_lead(p_token TEXT)
RETURNS TABLE (lead_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT l.lead_id
      FROM (SELECT 1) one
      LEFT JOIN sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'LEAD'
                          AND s.expires_at > clock_timestamp()
      LEFT JOIN leads l ON l.lead_id = s.lead_id AND l.active;
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

-- Guarded write-row for verify_lead: records the attempt (throttle per e-mail) and returns the sessions row ONLY for a
-- matching e-mail + one-time code while that e-mail is not locked (5 failures in 15 minutes).
CREATE OR REPLACE FUNCTION verify_lead_fn(p_email TEXT, p_code TEXT)
RETURNS TABLE (role VARCHAR, lead_id VARCHAR) AS $$
#variable_conflict use_column
DECLARE v_id TEXT := norm_email(p_email); v_match TEXT;
BEGIN
  IF (SELECT count(*) FROM verify_attempts a WHERE a.role = 'LEAD' AND a.identifier = v_id
        AND a.outcome = 'VERIFY_FAILED' AND a.created_at > clock_timestamp() - INTERVAL '15 minutes') >= 5 THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('LEAD', v_id, 'LOCKED');
    RETURN;
  END IF;
  SELECT l.lead_id INTO v_match FROM leads l
   WHERE lower(l.email) = v_id AND l.otp_code = trim(coalesce(p_code, '')) AND l.active;
  IF v_match IS NULL THEN
    INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('LEAD', v_id, 'VERIFY_FAILED');
    RETURN;
  END IF;
  INSERT INTO verify_attempts (role, identifier, outcome) VALUES ('LEAD', v_id, 'VERIFIED');
  RETURN QUERY SELECT 'LEAD'::varchar, v_match::varchar;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION verify_lead_result(p_email TEXT, p_code TEXT)
RETURNS TABLE (outcome TEXT, session_token TEXT, first_name VARCHAR, today TEXT, expires_at TEXT, reason_text TEXT) AS $$
  SELECT coalesce(CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NULL THEN 'VERIFY_FAILED' ELSE va.outcome END, 'VERIFY_FAILED'),
         CASE WHEN va.outcome = 'VERIFIED' THEN se.session_token END,
         CASE WHEN va.outcome = 'VERIFIED' THEN se.first_name END,
         today_text(),
         CASE WHEN va.outcome = 'VERIFIED' THEN dt(se.expires_at) END,
         CASE WHEN va.outcome = 'VERIFIED' AND se.session_token IS NOT NULL THEN 'You are verified. This session is valid for 60 minutes.'
              WHEN va.outcome = 'LOCKED' THEN 'Too many attempts. For your security, verification for this e-mail is paused for 15 minutes. Please try again later.'
              ELSE 'That e-mail address and one-time code do not match our records. Please check them and try again.' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT a.outcome FROM verify_attempts a WHERE a.role = 'LEAD' AND a.identifier = norm_email(p_email)
                        ORDER BY a.attempt_id DESC LIMIT 1) va ON TRUE
    LEFT JOIN LATERAL (SELECT s.session_token, l.first_name, s.expires_at
                         FROM leads l JOIN sessions s ON s.lead_id = l.lead_id AND s.role = 'LEAD' AND s.expires_at > clock_timestamp()
                        WHERE lower(l.email) = norm_email(p_email) AND l.otp_code = trim(coalesce(p_code, ''))
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
                        WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, ''))
                        ORDER BY s.created_at DESC LIMIT 1) se ON TRUE
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- SCOPED READS (lead) - every function starts FROM session_lead(token)
-- =====================================================================
CREATE OR REPLACE FUNCTION my_profile(p_token TEXT)
RETURNS TABLE (status TEXT, name TEXT, lead_type VARCHAR, journey_stage VARCHAR, budget TEXT, preferred_area VARCHAR,
               min_bedrooms INTEGER, min_bathrooms NUMERIC, property_type VARCHAR, timeline VARCHAR, financing TEXT,
               assigned_agent TEXT, my_listings TEXT, upcoming_showings BIGINT, open_follow_up TEXT, today TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         l.first_name || ' ' || l.last_name, l.lead_type, l.stage,
         CASE WHEN l.budget_max IS NOT NULL THEN coalesce(usd(l.budget_min) || ' - ', 'up to ') || usd(l.budget_max) END,
         l.preferred_area, l.min_bedrooms, l.min_bathrooms, l.property_type_pref, l.timeline,
         CASE WHEN l.lead_id IS NULL THEN NULL
              WHEN l.pre_approved THEN 'Pre-approval on file' || coalesce(' up to ' || usd(l.pre_approval_amount), '')
              ELSE 'No pre-approval on file' END,
         CASE WHEN l.lead_id IS NOT NULL THEN a.full_name || ' (' || a.title || ')' END,
         (SELECT string_agg(x.listing_id || ' ' || x.address || ', ' || x.area || ' - listed at ' || usd(x.price) || ' (' || x.status || ')',
                            '; ' ORDER BY x.listing_id) FROM listings x WHERE x.seller_lead_id = l.lead_id),
         (SELECT count(*) FROM appointments ap WHERE ap.lead_id = l.lead_id AND ap.status IN ('Requested','Confirmed')
             AND ap.scheduled_for > clock_timestamp()),
         (SELECT 'Requested ' || d(f.created_at::date) || '; your agent will reach out by ' || dt(f.due_at) FROM follow_up_tasks f
           WHERE f.lead_id = l.lead_id AND f.status = 'Open' ORDER BY f.created_at DESC LIMIT 1),
         today_text()
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN leads l ON l.lead_id = sl.lead_id
    LEFT JOIN agents a ON a.agent_id = l.assigned_agent_id
$$ LANGUAGE sql STABLE;

-- Structured search - every filter is applied HERE (area, price range, bedrooms, type, keywords). Active + Pending only.
CREATE OR REPLACE FUNCTION search_listings(p_token TEXT, p_area TEXT, p_min_price TEXT, p_max_price TEXT, p_min_beds TEXT,
                                           p_type TEXT, p_keywords TEXT)
RETURNS TABLE (status TEXT, listing_id VARCHAR, address VARCHAR, area VARCHAR, price NUMERIC, bedrooms INTEGER, bathrooms NUMERIC,
               sqft INTEGER, property_type VARCHAR, year_built INTEGER, hoa_monthly NUMERIC, listing_status VARCHAR,
               days_on_market INTEGER, features VARCHAR, description VARCHAR) AS $$
  WITH w AS (SELECT array_remove(array_agg(lower(regexp_replace(t, '[^A-Za-z0-9]', '', 'g'))), '') AS words
               FROM regexp_split_to_table(trim(coalesce(p_keywords, '')), '[\s,;/]+') t),
       f AS (SELECT lower(regexp_replace(coalesce(p_area, ''), '[^A-Za-z]', '', 'g')) AS area,
                    money_or_null(p_min_price) AS lo, money_or_null(p_max_price) AS hi, int_or_null(p_min_beds) AS beds,
                    lower(regexp_replace(coalesce(p_type, ''), '[^A-Za-z]', '', 'g')) AS typ),
       hits AS (SELECT x.* FROM listings x, w, f
                 WHERE x.status IN ('Active','Pending')
                   AND (f.area = '' OR f.area IN ('any','all','larkspurvalley')
                        OR lower(regexp_replace(x.area, '[^A-Za-z]', '', 'g')) LIKE '%' || f.area || '%')
                   AND (f.lo IS NULL OR x.price >= f.lo)
                   AND (f.hi IS NULL OR x.price <= f.hi)
                   AND (f.beds IS NULL OR x.bedrooms >= f.beds)
                   AND (f.typ = '' OR f.typ IN ('any','all')
                        OR (f.typ IN ('singlefamily','house','home','singlefamilyhome','detached') AND x.property_type = 'Single Family')
                        OR (f.typ IN ('townhouse','townhome','townhomes','townhouses') AND x.property_type = 'Townhouse')
                        OR (f.typ IN ('condo','condos','condominium','apartment') AND x.property_type = 'Condo'))
                   AND (coalesce(cardinality(w.words), 0) = 0
                        OR NOT EXISTS (SELECT 1 FROM unnest(w.words) k
                                        WHERE position(k IN lower(regexp_replace(x.address || x.area || x.features || x.description
                                                                                  || x.property_type, '[^A-Za-z0-9]', '', 'g'))) = 0)))
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' WHEN h.listing_id IS NULL THEN 'NO_MATCH' ELSE 'OK' END,
         h.listing_id, h.address, h.area, h.price, h.bedrooms, h.bathrooms, h.sqft, h.property_type, h.year_built, h.hoa_monthly,
         h.status, (current_date - h.list_date)::int, h.features, h.description
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN LATERAL (SELECT * FROM hits ORDER BY (hits.status = 'Active') DESC, hits.price LIMIT 12) h ON sl.lead_id IS NOT NULL
   ORDER BY (h.status = 'Active') DESC, h.price
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION listing_details(p_token TEXT, p_listing TEXT)
RETURNS TABLE (status TEXT, listing_id VARCHAR, address VARCHAR, area VARCHAR, price NUMERIC, bedrooms INTEGER, bathrooms NUMERIC,
               sqft INTEGER, lot_sqft INTEGER, property_type VARCHAR, year_built INTEGER, hoa_monthly NUMERIC,
               listing_status VARCHAR, list_date TEXT, days_on_market INTEGER, price_per_sqft NUMERIC, area_median_price NUMERIC,
               features VARCHAR, description VARCHAR, listing_agent VARCHAR, price_history TEXT, next_open_slots TEXT,
               your_listing TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' WHEN x.listing_id IS NULL OR x.status = 'Withdrawn' THEN 'NOT_FOUND' ELSE 'OK' END,
         x.listing_id, x.address, x.area, x.price, x.bedrooms, x.bathrooms, x.sqft, x.lot_sqft, x.property_type, x.year_built,
         x.hoa_monthly, x.status, d(x.list_date), (current_date - x.list_date)::int, round(x.price / nullif(x.sqft, 0), 0),
         m.median_price, x.features, x.description, a.full_name,
         coalesce((SELECT string_agg(d(c.created_at::date) || ': ' || usd(c.old_price) || ' -> ' || usd(c.new_price), '; ' ORDER BY c.created_at)
                     FROM listing_price_changes c WHERE c.listing_id = x.listing_id), CASE WHEN x.listing_id IS NOT NULL THEN 'No price changes' END),
         CASE WHEN x.status = 'Active' THEN coalesce((SELECT string_agg(dt(fs.slot), ', ' ORDER BY fs.slot)
                                                      FROM (SELECT * FROM free_slots(x.listing_id, current_date, current_date + 3) LIMIT 4) fs), 'none in the next 3 days')
              WHEN x.listing_id IS NOT NULL THEN 'Not available - the listing is ' || x.status END,
         CASE WHEN x.listing_id IS NOT NULL THEN yes_no(coalesce(x.seller_lead_id = sl.lead_id, FALSE)) END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN listings x ON x.listing_id = find_listing(p_listing) AND sl.lead_id IS NOT NULL
    LEFT JOIN area_market_stats m ON m.area = x.area
    LEFT JOIN agents a ON a.agent_id = x.listing_agent_id
$$ LANGUAGE sql STABLE;

-- Open showing slots for one listing: on a date (YYYY-MM-DD) or, when the date is empty, the next 3 days (max 12 slots).
CREATE OR REPLACE FUNCTION showing_availability(p_token TEXT, p_listing TEXT, p_date TEXT)
RETURNS TABLE (status TEXT, listing_id VARCHAR, address VARCHAR, slot TEXT, slot_label TEXT, note TEXT) AS $$
  WITH x AS (SELECT l.* FROM listings l WHERE l.listing_id = find_listing(p_listing)),
       rng AS (SELECT CASE WHEN trim(coalesce(p_date, '')) = '' THEN current_date ELSE date_or_null(p_date) END AS d1,
                      CASE WHEN trim(coalesce(p_date, '')) = '' THEN current_date + 3 ELSE date_or_null(p_date) END AS d2),
       s AS (SELECT fs.slot FROM x, rng, LATERAL free_slots(x.listing_id, rng.d1, rng.d2) fs
              WHERE x.status = 'Active' AND rng.d1 IS NOT NULL LIMIT 12)
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID'
              WHEN (SELECT count(*) FROM x) = 0 OR (SELECT status FROM x) = 'Withdrawn' THEN 'NOT_FOUND'
              WHEN (SELECT status FROM x) <> 'Active' THEN 'LISTING_NOT_ACTIVE'
              WHEN (SELECT d1 FROM rng) IS NULL THEN 'INVALID_DATE'
              WHEN s.slot IS NULL THEN 'NO_SLOTS' ELSE 'OK' END,
         (SELECT listing_id FROM x), (SELECT address FROM x), dt(s.slot), dt_long(s.slot),
         CASE WHEN sl.lead_id IS NULL THEN NULL
              WHEN (SELECT count(*) FROM x) = 0 THEN 'I could not find that listing.'
              WHEN (SELECT status FROM x) <> 'Active' THEN 'This listing is ' || (SELECT status FROM x) || ', so showings are not available.'
              WHEN (SELECT d1 FROM rng) IS NULL THEN 'Please give the date as YYYY-MM-DD.'
              WHEN s.slot IS NULL THEN 'No open slots then. Showings start on the hour between 09:00 and 18:00, at least 2 hours ahead and up to 30 days out.'
              ELSE 'Open slot (1 hour). Booking re-checks availability.' END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN s ON sl.lead_id IS NOT NULL
   ORDER BY s.slot
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_showings(p_token TEXT)
RETURNS TABLE (status TEXT, appointment_id VARCHAR, listing_id VARCHAR, address VARCHAR, area VARCHAR, scheduled_for TEXT,
               showing_status VARCHAR, timing TEXT, agent_name VARCHAR) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' WHEN ap.appointment_id IS NULL THEN 'NONE' ELSE 'OK' END,
         ap.appointment_id, ap.listing_id, x.address, x.area, dt(ap.scheduled_for), ap.status,
         CASE WHEN ap.appointment_id IS NULL THEN NULL WHEN ap.scheduled_for > clock_timestamp() THEN 'upcoming' ELSE 'past' END,
         a.full_name
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN appointments ap ON ap.lead_id = sl.lead_id
    LEFT JOIN listings x ON x.listing_id = ap.listing_id
    LEFT JOIN agents a ON a.agent_id = ap.agent_id
   ORDER BY ap.scheduled_for DESC
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_agent(p_token TEXT)
RETURNS TABLE (status TEXT, agent_name VARCHAR, title VARCHAR, agent_email VARCHAR, agent_phone VARCHAR, service_area VARCHAR,
               specialties VARCHAR) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         a.full_name, a.title, a.email, a.phone, a.service_area, a.specialties
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN leads l ON l.lead_id = sl.lead_id
    LEFT JOIN agents a ON a.agent_id = l.assigned_agent_id
$$ LANGUAGE sql STABLE;

-- Area market statistics (one area, or every area when empty). The market_note band is computed here.
CREATE OR REPLACE FUNCTION market_stats(p_token TEXT, p_area TEXT)
RETURNS TABLE (status TEXT, area VARCHAR, median_price NUMERIC, avg_days_on_market INTEGER, active_listings INTEGER,
               median_price_per_sqft NUMERIC, yoy_price_change_pct NUMERIC, months_of_inventory NUMERIC, market_note TEXT,
               as_of_month VARCHAR) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' WHEN m.area IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         m.area, m.median_price, m.avg_days_on_market, m.active_listings, m.median_price_per_sqft, m.yoy_price_change_pct,
         m.months_of_inventory,
         CASE WHEN m.area IS NULL THEN NULL
              WHEN m.months_of_inventory < 4 THEN 'Seller-leaning market (under 4 months of inventory).'
              WHEN m.months_of_inventory <= 6 THEN 'Balanced market (4-6 months of inventory).'
              ELSE 'Buyer-leaning market (over 6 months of inventory).' END,
         m.as_of_month
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN area_market_stats m ON sl.lead_id IS NOT NULL
         AND (regexp_replace(coalesce(p_area, ''), '[^A-Za-z]', '', 'g') = ''
              OR lower(regexp_replace(m.area, '[^A-Za-z]', '', 'g')) LIKE '%' || lower(regexp_replace(p_area, '[^A-Za-z]', '', 'g')) || '%')
   ORDER BY m.area
$$ LANGUAGE sql STABLE;

-- What the case asks for / what was approved, in words.
CREATE OR REPLACE FUNCTION case_requested_text(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.request_type
           WHEN 'offer_request' THEN 'talk to an agent about an offer / price on ' || coalesce(x.listing_id || ' ' || x.address, 'a listing')
                || coalesce(' (offer idea ' || usd(s.requested_amount) || ', list price ' || usd(s.current_amount) || ')', '')
           WHEN 'list_price_change' THEN 'change the list price of ' || x.listing_id || ' ' || x.address || ' from ' || usd(s.current_amount)
                || ' to ' || usd(s.requested_amount)
           WHEN 'stage_change' THEN 'update the status to ' || s.target_stage || coalesce(' (' || x.listing_id || ' ' || x.address || ')', '')
           WHEN 'fair_housing_review' THEN 'a reviewed answer to a neighborhood question (' || coalesce(s.category, 'OTHER') || ')'
           WHEN 'advice_referral' THEN 'a referral for a legal / mortgage question'
           ELSE NULL END
    FROM service_cases s LEFT JOIN listings x ON x.listing_id = s.listing_id WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION case_amount_text(p_case TEXT, p_amount NUMERIC) RETURNS TEXT AS $$
  SELECT CASE WHEN p_amount IS NULL THEN NULL
              WHEN s.request_type = 'list_price_change' THEN 'new list price ' || usd(p_amount)
              ELSE NULL END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The lead's own cases: status + the lead-safe outcome. Never the internal note, brief or reviewer.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, case_status VARCHAR, opened_on TEXT, reply_due TEXT,
               requested TEXT, outcome TEXT, decided_on TEXT, customer_message TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' WHEN s.case_id IS NULL THEN 'NONE' ELSE 'OK' END,
         s.case_id, r.label, r.team, s.status, d(s.created_at::date), d(s.sla_due_at::date),
         case_requested_text(s.case_id),
         CASE WHEN s.status = 'APPROVED' THEN 'Approved' || coalesce(' - ' || case_amount_text(s.case_id, s.approved_amount), '')
              WHEN s.status = 'REJECTED' THEN 'Not approved' END,
         d(s.decided_at::date),
         CASE WHEN s.status = 'OPEN' THEN 'Open - a person on our ' || r.team || ' team will reply.' ELSE s.customer_message END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN service_cases s ON s.lead_id = sl.lead_id
    LEFT JOIN case_routing r ON r.request_type = s.request_type
   ORDER BY s.created_at DESC
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- STAGE RULES - stage changes are events (lead_stage_events + trigger), never an UPDATE from a tool
-- =====================================================================
-- Allowed transitions: New/Nurturing -> Active (SYSTEM, a confirmed showing); New/Nurturing/Active -> Under Contract and
-- Under Contract -> Closed (REVIEWER, an approved stage_change case).
CREATE OR REPLACE FUNCTION stage_transition_ok(p_old TEXT, p_new TEXT) RETURNS BOOLEAN AS $$
  SELECT (p_new = 'Active' AND p_old IN ('New','Nurturing'))
      OR (p_new = 'Under Contract' AND p_old IN ('New','Nurturing','Active'))
      OR (p_new = 'Closed' AND p_old = 'Under Contract')
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_stage(p TEXT) RETURNS TEXT AS $$
  SELECT CASE upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g'))
           WHEN 'UNDERCONTRACT' THEN 'Under Contract' WHEN 'PENDING' THEN 'Under Contract' WHEN 'INESCROW' THEN 'Under Contract'
           WHEN 'ESCROW' THEN 'Under Contract' WHEN 'CONTRACT' THEN 'Under Contract' WHEN 'OFFERACCEPTED' THEN 'Under Contract'
           WHEN 'CLOSED' THEN 'Closed' WHEN 'CLOSING' THEN 'Closed' WHEN 'SOLD' THEN 'Closed' WHEN 'CLOSEDSOLD' THEN 'Closed'
           ELSE NULL END
$$ LANGUAGE sql IMMUTABLE;

-- Guarded row for a stage event: 0 rows unless the transition is allowed right now.
CREATE OR REPLACE FUNCTION stage_event_row(p_lead TEXT, p_new TEXT, p_source TEXT, p_ref TEXT)
RETURNS TABLE (lead_id VARCHAR, old_stage VARCHAR, new_stage VARCHAR, source VARCHAR, reference VARCHAR) AS $$
  SELECT l.lead_id, l.stage, p_new::varchar, p_source::varchar, p_ref::varchar
    FROM leads l
   WHERE l.lead_id = p_lead AND stage_transition_ok(l.stage, p_new)
     AND ((p_source = 'SYSTEM' AND p_new = 'Active') OR (p_source = 'REVIEWER' AND p_new IN ('Under Contract','Closed')))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_lead_stage_event() RETURNS TRIGGER AS $$
BEGIN
  UPDATE leads SET stage = NEW.new_stage, last_activity_at = clock_timestamp() WHERE lead_id = NEW.lead_id;
  INSERT INTO lead_activity (lead_id, activity_type, detail)
    VALUES (NEW.lead_id, 'Stage Change', NEW.old_stage || ' -> ' || NEW.new_stage || ' (' || NEW.source || coalesce(', ' || NEW.reference, '') || ')');
  PERFORM audit('STAGE_CHANGED', NEW.source, NEW.lead_id, NEW.old_stage || ' -> ' || NEW.new_stage || coalesce(' via ' || NEW.reference, ''));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_lead_stage_event AFTER INSERT ON lead_stage_events FOR EACH ROW EXECUTE FUNCTION apply_lead_stage_event();

-- =====================================================================
-- SHOWING RULES for the two-step booking
-- =====================================================================
-- In this order: lead stage, listing, listing status, slot format, past, notice, horizon, showing hours, upcoming limit,
-- the lead's own double booking, the listing's slot already taken.
CREATE OR REPLACE FUNCTION showing_eval(p_lead TEXT, p_listing TEXT, p_slot TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, reason_text TEXT, listing_id VARCHAR, slot TIMESTAMP, agent_id VARCHAR, summary TEXT) AS $$
#variable_conflict use_column
DECLARE l leads; x listings; a agents; pol showing_policy; v_slot TIMESTAMP := slot_or_null(p_slot); v_n INTEGER;
BEGIN
  SELECT * INTO l FROM leads z WHERE z.lead_id = p_lead;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID', 'Please verify your identity again.', NULL::varchar, NULL::timestamp, NULL::varchar, NULL::text; RETURN;
  END IF;
  SELECT * INTO pol FROM showing_policy;
  SELECT * INTO a FROM agents z WHERE z.agent_id = l.assigned_agent_id;
  IF l.stage IN ('Under Contract','Closed','Lost') THEN
    RETURN QUERY SELECT FALSE, 'LEAD_STAGE_BLOCKED',
      CASE l.stage WHEN 'Under Contract' THEN 'You are already under contract on a home, so new showings cannot be booked online. Your agent ' || a.full_name || ' can help if your plans change.'
                   WHEN 'Closed' THEN 'Your purchase has closed, so new showings cannot be booked online. Your agent ' || a.full_name || ' can help with anything new.'
                   ELSE 'Your home search is currently paused with us, so showings cannot be booked online. I can ask your agent to get back in touch first.' END,
      NULL::varchar, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  SELECT * INTO x FROM listings z WHERE z.listing_id = find_listing(p_listing);
  IF NOT FOUND OR x.status = 'Withdrawn' THEN
    RETURN QUERY SELECT FALSE, 'LISTING_NOT_FOUND', 'I could not find that listing, so no showing can be booked. Please check the listing number (for example LST-50001).',
      NULL::varchar, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF x.status <> 'Active' THEN
    RETURN QUERY SELECT FALSE, 'LISTING_NOT_ACTIVE', x.address || ' (' || x.listing_id || ') is ' || x.status
      || CASE x.status WHEN 'Pending' THEN ' - the sellers have accepted an offer' ELSE '' END
      || ', so showings are not available. I can show you similar active listings.',
      x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF v_slot IS NULL THEN
    RETURN QUERY SELECT FALSE, 'INVALID_SLOT', 'Please give the showing date and start time as YYYY-MM-DD HH:MM (for example 2026-10-16 14:00).',
      x.listing_id, NULL::timestamp, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF v_slot <= clock_timestamp()::timestamp THEN
    RETURN QUERY SELECT FALSE, 'SLOT_IN_PAST', dt(v_slot) || ' is in the past. Please pick a future time.',
      x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF v_slot < clock_timestamp()::timestamp + make_interval(hours => pol.min_notice_hours) THEN
    RETURN QUERY SELECT FALSE, 'TOO_SOON', 'Showings need at least ' || pol.min_notice_hours || ' hours'' notice, so ' || dt(v_slot)
      || ' is too soon. Please pick a later time.', x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF v_slot::date > current_date + pol.max_days_ahead THEN
    RETURN QUERY SELECT FALSE, 'TOO_FAR_AHEAD', 'Showings can be booked up to ' || pol.max_days_ahead || ' days ahead (until '
      || d(current_date + pol.max_days_ahead) || ').', x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF extract(minute FROM v_slot) <> 0 OR extract(hour FROM v_slot) < pol.first_start_hour OR extract(hour FROM v_slot) > pol.last_start_hour THEN
    RETURN QUERY SELECT FALSE, 'OUTSIDE_SHOWING_HOURS', 'Showings start on the hour between ' || lpad(pol.first_start_hour::text, 2, '0')
      || ':00 and ' || lpad(pol.last_start_hour::text, 2, '0') || ':00. Please pick one of those times.',
      x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  SELECT count(*) INTO v_n FROM appointments ap WHERE ap.lead_id = l.lead_id AND ap.status IN ('Requested','Confirmed')
     AND ap.scheduled_for > clock_timestamp();
  IF v_n >= pol.max_upcoming THEN
    RETURN QUERY SELECT FALSE, 'SHOWING_LIMIT', 'You already have ' || v_n || ' upcoming showings, the most we can hold at once. '
      || 'After one of them, or if your agent cancels one, you can book another.', x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM appointments ap WHERE ap.lead_id = l.lead_id AND ap.scheduled_for = v_slot AND ap.status IN ('Requested','Confirmed')) THEN
    RETURN QUERY SELECT FALSE, 'LEAD_DOUBLE_BOOKED', 'You already have a showing at ' || dt(v_slot) || '. Please pick another time.',
      x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  IF slot_taken(x.listing_id, v_slot) THEN
    RETURN QUERY SELECT FALSE, 'SLOT_TAKEN', 'That time (' || dt(v_slot) || ') is already booked for ' || x.address
      || '. Open times nearby: ' || coalesce((SELECT string_agg(dt(fs.slot), ', ' ORDER BY fs.slot)
                                              FROM (SELECT * FROM free_slots(x.listing_id, v_slot::date, v_slot::date + 1) LIMIT 4) fs), 'none in the next day') || '.',
      x.listing_id, v_slot, l.assigned_agent_id, NULL::text; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, NULL::text, NULL::text, x.listing_id, v_slot, l.assigned_agent_id,
    'Book a showing of ' || x.address || ', ' || x.area || ' (' || x.listing_id || ', ' || x.bedrooms || ' bd / ' || trim_scale(x.bathrooms)
    || ' ba, ' || usd(x.price) || ') on ' || dt_long(v_slot) || ' with your Brightpath agent ' || a.full_name || ' (about 1 hour).';
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION showing_key(p_listing TEXT, p_slot TEXT) RETURNS TEXT AS $$
  SELECT coalesce(find_listing(p_listing), norm_listing(p_listing)) || '|' || coalesce(dt(slot_or_null(p_slot)), norm_ref(p_slot))
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- TWO-STEP BOOKING: propose (PROPOSED or BLOCKED, 15-minute expiry) -> confirm (re-check) -> event + trigger
-- =====================================================================
CREATE OR REPLACE FUNCTION propose_showing_fn(p_token TEXT, p_listing TEXT, p_slot TEXT)
RETURNS TABLE (lead_id VARCHAR, action_type VARCHAR, target_key TEXT, listing_id VARCHAR, slot TIMESTAMP, outcome VARCHAR,
               reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT sl.lead_id, 'BOOK_SHOWING'::varchar, showing_key(p_listing, p_slot), e.listing_id, e.slot,
         (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)::varchar, e.reason_code::varchar, e.reason_text, e.summary
    FROM session_lead(p_token) sl
    CROSS JOIN LATERAL showing_eval(sl.lead_id, p_listing, p_slot) e
   WHERE sl.lead_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.lead_id = sl.lead_id AND pa.action_type = 'BOOK_SHOWING'
                        AND pa.target_key = showing_key(p_listing, p_slot) AND pa.expires_at > clock_timestamp()
                        AND pa.outcome = (CASE WHEN e.ok THEN 'PROPOSED' ELSE 'BLOCKED' END)
                        AND pa.reason_code IS NOT DISTINCT FROM e.reason_code
                        AND NOT EXISTS (SELECT 1 FROM showing_events se WHERE se.proposal_id = pa.proposal_id))
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_showing_result(p_token TEXT, p_listing TEXT, p_slot TEXT)
RETURNS TABLE (outcome TEXT, proposal_id TEXT, reason_code VARCHAR, reason_text TEXT, summary TEXT, listing_id VARCHAR,
               slot TEXT, expires_at TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(pa.outcome, 'BLOCKED') END,
         CASE WHEN pa.outcome = 'PROPOSED' THEN pa.proposal_id END,
         CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE pa.reason_code END,
         CASE WHEN sl.lead_id IS NULL THEN 'Please verify your identity again (your e-mail and one-time code).'
              WHEN pa.outcome = 'PROPOSED' THEN 'Nothing is booked yet. Reply yes within 15 minutes to book it.'
              ELSE pa.reason_text END,
         pa.summary, pa.listing_id, dt(pa.slot),
         CASE WHEN pa.outcome = 'PROPOSED' THEN dt(pa.expires_at) END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN LATERAL (SELECT p.* FROM pending_actions p
                        WHERE p.lead_id = sl.lead_id AND p.action_type = 'BOOK_SHOWING' AND p.target_key = showing_key(p_listing, p_slot)
                        ORDER BY p.created_at DESC LIMIT 1) pa ON TRUE
$$ LANGUAGE sql STABLE;

-- Guarded write-row for confirm: re-checks EVERY rule; returns the showing_events row only when executable.
CREATE OR REPLACE FUNCTION confirm_showing_fn(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (event_id BIGINT, reference VARCHAR, proposal_id TEXT, lead_id VARCHAR, listing_id VARCHAR, agent_id VARCHAR,
               slot TIMESTAMP, summary TEXT) AS $$
#variable_conflict use_column
DECLARE
  v_lead TEXT; v_ref TEXT := upper(trim(coalesce(p_proposal, ''))); pa pending_actions; ev showing_events; e RECORD;
  v_id BIGINT; v_reference TEXT; v_stage TEXT;
BEGIN
  SELECT s.lead_id INTO v_lead FROM session_lead(p_token) s;
  IF v_lead IS NULL THEN RETURN; END IF;
  SELECT * INTO pa FROM pending_actions p WHERE p.proposal_id = v_ref AND p.lead_id = v_lead;
  IF NOT FOUND THEN
    INSERT INTO confirm_attempts (lead_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_lead, v_ref, 'NOT_FOUND', 'NOT_FOUND', 'I could not find that showing request for you. Nothing was booked.');
    RETURN;
  END IF;
  SELECT * INTO ev FROM showing_events s WHERE s.proposal_id = pa.proposal_id;
  IF FOUND THEN
    INSERT INTO confirm_attempts (lead_id, proposal_ref, outcome, reason_text, reference, summary)
      VALUES (v_lead, v_ref, 'ALREADY_DONE', 'This showing was already booked earlier (reference ' || ev.reference || '). Nothing new was booked.',
              ev.reference, ev.summary);
    RETURN;
  END IF;
  IF pa.outcome = 'BLOCKED' THEN
    INSERT INTO confirm_attempts (lead_id, proposal_ref, outcome, reason_code, reason_text)
      VALUES (v_lead, v_ref, 'BLOCKED', pa.reason_code, pa.reason_text);
    RETURN;
  END IF;
  IF pa.expires_at <= clock_timestamp() THEN
    INSERT INTO confirm_attempts (lead_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_lead, v_ref, 'EXPIRED', 'EXPIRED', 'This showing request expired after 15 minutes, so nothing was booked. I can set it up again.', pa.summary);
    RETURN;
  END IF;
  SELECT * INTO e FROM showing_eval(v_lead, pa.listing_id, dt(pa.slot)) z;
  IF NOT e.ok THEN
    INSERT INTO confirm_attempts (lead_id, proposal_ref, outcome, reason_code, reason_text, summary)
      VALUES (v_lead, v_ref, 'BLOCKED', e.reason_code, e.reason_text, pa.summary);
    RETURN;
  END IF;
  v_id := nextval(pg_get_serial_sequence('showing_events', 'event_id'));
  v_reference := 'APT-' || nextval('appt_seq');
  SELECT CASE WHEN l.stage IN ('New','Nurturing') THEN 'Active' ELSE l.stage END INTO v_stage FROM leads l WHERE l.lead_id = v_lead;
  INSERT INTO confirm_attempts (lead_id, proposal_ref, outcome, reason_text, reference, new_stage, summary)
    VALUES (v_lead, v_ref, 'EXECUTED', 'Your showing is booked.', v_reference, v_stage, e.summary);
  RETURN QUERY SELECT v_id, v_reference::varchar, pa.proposal_id, v_lead::varchar, e.listing_id, e.agent_id, e.slot, e.summary;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION confirm_showing_result(p_token TEXT, p_proposal TEXT)
RETURNS TABLE (outcome TEXT, appointment_id VARCHAR, scheduled_for TEXT, address VARCHAR, agent_name VARCHAR, journey_stage VARCHAR,
               reason_code VARCHAR, reason_text TEXT, summary TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(ca.outcome, 'NOT_FOUND') END,
         ca.reference, dt(ap.scheduled_for), x.address, a.full_name,
         CASE WHEN ca.outcome = 'EXECUTED' THEN l.stage END,
         CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' WHEN ca.attempt_id IS NULL THEN 'NOT_FOUND' ELSE ca.reason_code END,
         CASE WHEN sl.lead_id IS NULL THEN 'Please verify your identity again (your e-mail and one-time code).'
              WHEN ca.attempt_id IS NULL THEN 'I could not find that showing request for you. Nothing was booked.'
              ELSE ca.reason_text END,
         ca.summary
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN leads l ON l.lead_id = sl.lead_id
    LEFT JOIN LATERAL (SELECT c.* FROM confirm_attempts c
                        WHERE c.lead_id = sl.lead_id AND c.proposal_ref = upper(trim(coalesce(p_proposal, '')))
                        ORDER BY c.attempt_id DESC LIMIT 1) ca ON TRUE
    LEFT JOIN appointments ap ON ap.appointment_id = ca.reference AND ca.outcome IN ('EXECUTED','ALREADY_DONE')
    LEFT JOIN listings x ON x.listing_id = ap.listing_id
    LEFT JOIN agents a ON a.agent_id = ap.agent_id
$$ LANGUAGE sql STABLE;

-- Side effects of a confirmed showing - atomic with the event row. Never an UPDATE from a tool.
--   appointment row, lead activity, and New/Nurturing -> Active through the guarded stage event.
CREATE OR REPLACE FUNCTION apply_showing_event() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO appointments (appointment_id, lead_id, listing_id, agent_id, scheduled_for, status, source, notes)
    VALUES (NEW.reference, NEW.lead_id, NEW.listing_id, NEW.agent_id, NEW.slot, 'Confirmed', 'CHAT', 'Booked by Harper after the lead confirmed.');
  INSERT INTO lead_activity (lead_id, listing_id, activity_type, detail)
    VALUES (NEW.lead_id, NEW.listing_id, 'Showing Booked', NEW.reference || ' on ' || dt(NEW.slot));
  UPDATE leads SET last_activity_at = clock_timestamp() WHERE lead_id = NEW.lead_id;
  PERFORM audit('SHOWING_BOOKED', NEW.lead_id, NEW.reference, NEW.summary);
  INSERT INTO lead_stage_events (lead_id, old_stage, new_stage, source, reference)
    SELECT * FROM stage_event_row(NEW.lead_id, 'Active', 'SYSTEM', NEW.reference);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_showing_event AFTER INSERT ON showing_events FOR EACH ROW EXECUTE FUNCTION apply_showing_event();

-- =====================================================================
-- AGENT FOLLOW-UP - the intent agent's output is normalised and turned into a priority + due time HERE
-- =====================================================================
CREATE OR REPLACE FUNCTION norm_intent(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('BUY','BUYER','BUYING','PURCHASE') THEN 'BUY'
              WHEN x IN ('SELL','SELLER','SELLING','LIST','LISTING') THEN 'SELL'
              WHEN x IN ('BUYANDSELL','BOTH','SELLANDBUY','BUYSELL') THEN 'BUY_AND_SELL'
              WHEN x IN ('RENT','RENTAL','RENTING','LEASE') THEN 'RENT'
              WHEN x IN ('BROWSING','BROWSE','JUSTBROWSING','JUSTLOOKING','RESEARCH') THEN 'BROWSING'
              ELSE 'OTHER' END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_timeline(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x ~ '^(03|0TO3|13|1TO3|LESSTHAN3|UNDER3|WITHIN3|UPTO3)MONTHS?$' OR x IN ('ASAP','IMMEDIATELY','NOW','RIGHTAWAY','1MONTH','2MONTHS','3MONTHS','03')
                THEN '0_3_MONTHS'
              WHEN x ~ '^(36|3TO6|46|4TO6|WITHIN6|UNDER6|UPTO6)MONTHS?$' OR x IN ('4MONTHS','5MONTHS','6MONTHS','36') THEN '3_6_MONTHS'
              WHEN x ~ '^(612|6TO12|WITHIN12|UNDER12|UPTO12)MONTHS?$' OR x IN ('9MONTHS','612','1YEAR','WITHINAYEAR') THEN '6_12_MONTHS'
              WHEN x ~ '^(12PLUS|12MONTHSPLUS|OVER12MONTHS|MORETHAN12MONTHS|12MONTHS|OVERAYEAR|NEXTYEAR|1YEARPLUS)$' THEN '12_PLUS'
              ELSE 'UNKNOWN' END
    FROM (SELECT upper(regexp_replace(replace(coalesce(p, ''), '+', 'PLUS'), '[^A-Za-z0-9]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION norm_tri(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('YES','Y','TRUE','PREAPPROVED') THEN 'YES' WHEN x IN ('NO','N','FALSE','NOTPREAPPROVED') THEN 'NO' ELSE 'UNKNOWN' END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;
-- HOT = 0-3 months and (selling, or buying with a pre-approval); WARM = within 6 months; NURTURE otherwise.
CREATE OR REPLACE FUNCTION follow_up_priority(p_intent TEXT, p_timeline TEXT, p_pre TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN p_timeline = '0_3_MONTHS' AND (p_intent IN ('SELL','BUY_AND_SELL') OR (p_intent = 'BUY' AND p_pre = 'YES')) THEN 'HOT'
              WHEN p_timeline IN ('0_3_MONTHS','3_6_MONTHS') AND p_intent IN ('BUY','SELL','BUY_AND_SELL') THEN 'WARM'
              ELSE 'NURTURE' END
$$ LANGUAGE sql IMMUTABLE;
-- HOT: within 4 business hours (weekday 08:00-14:00), else noon the next business day; WARM: next business day 17:00;
-- NURTURE: 3 business days, 17:00.
CREATE OR REPLACE FUNCTION follow_up_due(p_priority TEXT) RETURNS TIMESTAMP AS $$
  SELECT CASE p_priority
           WHEN 'HOT' THEN CASE WHEN extract(isodow FROM now()) < 6 AND localtime BETWEEN TIME '08:00' AND TIME '14:00'
                                THEN date_trunc('minute', localtimestamp) + INTERVAL '4 hours'
                                WHEN extract(isodow FROM now()) < 6 AND localtime < TIME '08:00' THEN current_date + TIME '12:00'
                                ELSE add_business_days(current_date, 1) + TIME '12:00' END
           WHEN 'WARM' THEN add_business_days(current_date, 1) + TIME '17:00'
           ELSE add_business_days(current_date, 3) + TIME '17:00' END
$$ LANGUAGE sql STABLE;

-- Guarded write-row: one open follow-up per lead; the priority is decided here, not by the model.
CREATE OR REPLACE FUNCTION follow_up_row(p_token TEXT, p_message TEXT, p_intent TEXT, p_timeline TEXT, p_pre TEXT,
                                         p_motivation TEXT, p_brief TEXT)
RETURNS TABLE (task_no BIGINT, task_id VARCHAR, lead_id VARCHAR, agent_id VARCHAR, message TEXT, intent VARCHAR, timeline VARCHAR,
               pre_approved VARCHAR, motivation VARCHAR, agent_brief TEXT, priority VARCHAR, due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_lead TEXT; l leads; v_existing TEXT; v_no BIGINT; v_id TEXT; v_int TEXT := norm_intent(p_intent);
        v_tl TEXT := norm_timeline(p_timeline); v_pre TEXT := norm_tri(p_pre); v_pri TEXT;
BEGIN
  SELECT s.lead_id INTO v_lead FROM session_lead(p_token) s;
  IF v_lead IS NULL THEN RETURN; END IF;
  SELECT * INTO l FROM leads z WHERE z.lead_id = v_lead;
  IF length(trim(coalesce(p_message, ''))) < 3 THEN
    INSERT INTO follow_up_attempts (lead_id, outcome) VALUES (v_lead, 'MESSAGE_REQUIRED');
    RETURN;
  END IF;
  SELECT f.task_id INTO v_existing FROM follow_up_tasks f WHERE f.lead_id = v_lead AND f.status = 'Open' ORDER BY f.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO follow_up_attempts (lead_id, outcome, task_id) VALUES (v_lead, 'EXISTING', v_existing);
    RETURN;
  END IF;
  IF v_pre = 'UNKNOWN' AND l.pre_approved THEN v_pre := 'YES'; END IF;      -- a pre-approval on file counts
  v_pri := follow_up_priority(v_int, v_tl, v_pre);
  v_no := nextval(pg_get_serial_sequence('follow_up_tasks', 'task_no'));
  v_id := 'FUP-' || (90000 + v_no);
  INSERT INTO follow_up_attempts (lead_id, outcome, task_id) VALUES (v_lead, 'FOLLOW_UP_REQUESTED', v_id);
  RETURN QUERY SELECT v_no, v_id::varchar, v_lead::varchar, l.assigned_agent_id, left(trim(p_message), 2000), v_int::varchar,
                      v_tl::varchar, v_pre::varchar, left(nullif(trim(p_motivation), ''), 300)::varchar, left(nullif(trim(p_brief), ''), 3000),
                      v_pri::varchar, follow_up_due(v_pri);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION follow_up_result(p_token TEXT)
RETURNS TABLE (outcome TEXT, follow_up_id VARCHAR, agent_name VARCHAR, contact_by TEXT, reason_text TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(fa.outcome, 'MESSAGE_REQUIRED') END,
         f.task_id, a.full_name, dt(f.due_at),
         CASE WHEN sl.lead_id IS NULL THEN 'Please verify your identity again (your e-mail and one-time code).'
              WHEN fa.outcome = 'FOLLOW_UP_REQUESTED' THEN 'Done. Your agent ' || a.full_name || ' will contact you by ' || dt(f.due_at) || '.'
              WHEN fa.outcome = 'EXISTING' THEN 'You already have a follow-up request open; your agent ' || a.full_name
                   || ' will contact you by ' || dt(f.due_at) || '. Nothing new was added.'
              ELSE 'Please tell me in a sentence what you would like your agent to help with.' END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN LATERAL (SELECT x.* FROM follow_up_attempts x WHERE x.lead_id = sl.lead_id ORDER BY x.attempt_id DESC LIMIT 1) fa ON TRUE
    LEFT JOIN follow_up_tasks f ON f.task_id = fa.task_id
    LEFT JOIN agents a ON a.agent_id = f.agent_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_follow_up() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO lead_activity (lead_id, activity_type, detail)
    VALUES (NEW.lead_id, 'Follow-up Requested', NEW.task_id || ': ' || left(NEW.message, 200));
  UPDATE leads SET last_activity_at = clock_timestamp() WHERE lead_id = NEW.lead_id;
  PERFORM audit('FOLLOW_UP', NEW.lead_id, NEW.task_id, NEW.priority || ' (' || NEW.intent || ', ' || NEW.timeline || ', pre-approved '
                || NEW.pre_approved || ') due ' || dt(NEW.due_at));
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_follow_up AFTER INSERT ON follow_up_tasks FOR EACH ROW EXECUTE FUNCTION apply_follow_up();

-- =====================================================================
-- HUMAN-OWNED CASES - routed by case_routing; the model never picks the team, SLA or outcome
-- =====================================================================
-- reference_id per type: offer_request = the listing (optional) + amount = the offer idea (optional);
-- list_price_change = the seller's own listing + amount = the new list price; stage_change = the target stage
-- (Under Contract / Closed); fair_housing_review = fair_housing_agent's category; advice_referral = the topic (optional).
CREATE OR REPLACE FUNCTION norm_fh_category(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN x IN ('SCHOOLS','SCHOOL','EDUCATION') THEN 'SCHOOLS'
              WHEN x IN ('SAFETYCRIME','SAFETY','CRIME','SAFEAREA') THEN 'SAFETY_CRIME'
              WHEN x IN ('DEMOGRAPHICS','DEMOGRAPHIC','RACE','ETHNICITY','NATIONALORIGIN','COLOR') THEN 'DEMOGRAPHICS'
              WHEN x IN ('FAMILYSTATUS','FAMILIALSTATUS','FAMILY','FAMILYFRIENDLY','CHILDREN','KIDS') THEN 'FAMILY_STATUS'
              WHEN x IN ('RELIGION','RELIGIOUS') THEN 'RELIGION'
              WHEN x IN ('DISABILITY','ACCESSIBILITY','HANDICAP') THEN 'DISABILITY'
              WHEN x IN ('OTHERPROTECTED','SEX','GENDER','PROTECTEDCLASS') THEN 'OTHER_PROTECTED'
              ELSE 'OTHER' END
    FROM (SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')) AS x) s
$$ LANGUAGE sql IMMUTABLE;

-- A list-price change must stay within +/- max_price_change_pct of the CURRENT list price and actually change it.
CREATE OR REPLACE FUNCTION price_change_ok(p_listing TEXT, p_new NUMERIC) RETURNS BOOLEAN AS $$
  SELECT p_new IS NOT NULL AND p_new > 0 AND p_new <> x.price
         AND abs(p_new - x.price) <= round(x.price * pol.max_price_change_pct / 100, 2)
    FROM listings x CROSS JOIN showing_policy pol WHERE x.listing_id = p_listing
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION price_range_text(p_listing TEXT) RETURNS TEXT AS $$
  SELECT usd(round(x.price * (1 - pol.max_price_change_pct / 100), 0)) || ' - ' || usd(round(x.price * (1 + pol.max_price_change_pct / 100), 0))
         || ' (within ' || trim_scale(pol.max_price_change_pct) || '% of the current ' || usd(x.price) || ')'
    FROM listings x CROSS JOIN showing_policy pol WHERE x.listing_id = p_listing
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION open_case_row(p_token TEXT, p_type TEXT, p_summary TEXT, p_ref TEXT, p_amount TEXT, p_brief TEXT)
RETURNS TABLE (case_no BIGINT, case_id VARCHAR, lead_id VARCHAR, request_type VARCHAR, summary TEXT, reference_id VARCHAR,
               listing_id VARCHAR, target_stage VARCHAR, category VARCHAR, requested_amount NUMERIC, current_amount NUMERIC,
               parked_action VARCHAR, agent_brief TEXT, priority VARCHAR, sla_due_at TIMESTAMP) AS $$
#variable_conflict use_column
DECLARE v_lead TEXT; l leads; v_type TEXT := norm_request_type(p_type); v_ref TEXT := nullif(trim(coalesce(p_ref, '')), '');
        r case_routing; x listings; v_listing TEXT; v_stage TEXT; v_cat TEXT; v_amt NUMERIC; v_cur NUMERIC;
        v_amt_txt TEXT := norm_amount(p_amount); v_parked TEXT; v_pri TEXT := 'NORMAL'; v_existing TEXT; v_no BIGINT; v_case TEXT;
BEGIN
  SELECT s.lead_id INTO v_lead FROM session_lead(p_token) s;
  IF v_lead IS NULL THEN RETURN; END IF;
  SELECT * INTO l FROM leads z WHERE z.lead_id = v_lead;
  SELECT * INTO r FROM case_routing z WHERE z.request_type = v_type AND z.lead_openable;
  IF NOT FOUND THEN
    INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code) VALUES (v_lead, v_type, v_ref, 'INVALID_TYPE', 'INVALID_TYPE');
    RETURN;
  END IF;
  IF v_type = 'offer_request' THEN
    IF v_ref IS NOT NULL THEN
      SELECT * INTO x FROM listings z WHERE z.listing_id = find_listing(v_ref) AND z.status IN ('Active','Pending');
      IF NOT FOUND THEN
        INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code, reason_text)
          VALUES (v_lead, v_type, v_ref, 'BLOCKED', 'NOT_FOUND', 'I could not find that listing among our active or pending listings, so no request was opened.');
        RETURN;
      END IF;
      v_listing := x.listing_id; v_ref := x.listing_id; v_cur := x.price;
    END IF;
    IF v_amt_txt <> '' THEN
      v_amt := money_or_null(p_amount);
      IF v_amt IS NULL OR v_amt <= 0 THEN
        INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code, reason_text)
          VALUES (v_lead, v_type, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'If you mention an offer amount, it must be a dollar amount above $0. No request was opened.');
        RETURN;
      END IF;
    END IF;
  ELSIF v_type = 'list_price_change' THEN
    SELECT * INTO x FROM listings z WHERE z.listing_id = find_listing(v_ref) AND z.seller_lead_id = v_lead;
    IF NOT FOUND THEN
      INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_lead, v_type, v_ref, 'BLOCKED', 'NOT_FOUND', 'I could not find a listing of yours with that number, so no price change was requested. Only the seller of a listing can ask to change its price.');
      RETURN;
    END IF;
    IF x.status <> 'Active' THEN
      INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_lead, v_type, x.listing_id, 'BLOCKED', 'NOT_ELIGIBLE', 'Your listing is ' || x.status || ', so its list price cannot be changed here. Your agent can explain the options.');
      RETURN;
    END IF;
    v_amt := money_or_null(p_amount);
    IF NOT coalesce(price_change_ok(x.listing_id, v_amt), FALSE) THEN
      INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_lead, v_type, x.listing_id, 'BLOCKED', 'AMOUNT_INVALID', 'The new list price must be a dollar amount different from today''s price and within '
                || price_range_text(x.listing_id) || '. Larger changes are a conversation with your agent. No request was opened.');
      RETURN;
    END IF;
    v_listing := x.listing_id; v_ref := x.listing_id; v_cur := x.price; v_parked := 'LIST_PRICE:' || x.listing_id;
  ELSIF v_type = 'stage_change' THEN
    v_stage := norm_stage(v_ref);
    IF v_stage IS NULL OR NOT stage_transition_ok(l.stage, v_stage) THEN
      INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, reason_code, reason_text)
        VALUES (v_lead, v_type, v_ref, 'BLOCKED', 'NOT_ELIGIBLE', CASE WHEN v_stage IS NULL
                  THEN 'I can ask your agent to update your status to Under Contract (an accepted offer) or Closed. Please say which one.'
                  ELSE 'Your status is ' || l.stage || ', so it cannot be changed to ' || v_stage || '.' END);
      RETURN;
    END IF;
    v_ref := v_stage; v_parked := 'STAGE:' || v_lead;
  ELSIF v_type = 'fair_housing_review' THEN
    v_cat := norm_fh_category(v_ref); v_ref := v_cat;
    v_pri := CASE WHEN v_cat IN ('DEMOGRAPHICS','FAMILY_STATUS','RELIGION','DISABILITY','OTHER_PROTECTED') THEN 'HIGH' ELSE 'NORMAL' END;
  ELSIF v_type = 'advice_referral' THEN
    v_ref := left(v_ref, 40);
  END IF;
  SELECT s.case_id INTO v_existing FROM service_cases s
   WHERE s.lead_id = v_lead AND s.request_type = v_type AND s.status = 'OPEN'
     AND (v_type IN ('stage_change','advice_referral') OR s.reference_id IS NOT DISTINCT FROM v_ref)
   ORDER BY s.created_at DESC LIMIT 1;
  IF v_existing IS NOT NULL THEN
    INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, case_id) VALUES (v_lead, v_type, v_ref, 'EXISTING', v_existing);
    RETURN;
  END IF;
  v_no := nextval(pg_get_serial_sequence('service_cases', 'case_no'));
  v_case := 'BPR-CASE-' || lpad(v_no::text, 6, '0');
  INSERT INTO case_requests (lead_id, request_type, reference_id, outcome, case_id) VALUES (v_lead, v_type, v_ref, 'OPENED', v_case);
  INSERT INTO lead_activity (lead_id, listing_id, activity_type, detail) VALUES (v_lead, v_listing, 'Case Opened', v_case || ' ' || v_type);
  PERFORM audit('CASE_OPENED', v_lead, v_case, v_type || coalesce(' for ' || v_ref, ''));
  RETURN QUERY SELECT v_no, v_case::varchar, v_lead::varchar, v_type::varchar,
                      left(coalesce(nullif(trim(p_summary), ''), '(no summary given)'), 2000), v_ref::varchar, v_listing::varchar,
                      v_stage::varchar, v_cat::varchar, v_amt, v_cur, v_parked::varchar, left(nullif(trim(p_brief), ''), 3000),
                      v_pri::varchar, add_business_days_ts(clock_timestamp()::timestamp, r.sla_business_days);
END $$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION open_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, case_id VARCHAR, request VARCHAR, team VARCHAR, sla_text VARCHAR, reply_due TEXT, requested TEXT,
               reason_code VARCHAR, reason_text TEXT) AS $$
  SELECT CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE coalesce(cr.outcome, 'INVALID_TYPE') END,
         cr.case_id, rt.label, rt.team, rt.sla_text, d(s.sla_due_at::date), case_requested_text(s.case_id),
         CASE WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE cr.reason_code END,
         CASE WHEN sl.lead_id IS NULL THEN 'Please verify your identity again (your e-mail and one-time code).'
              WHEN cr.outcome = 'OPENED' THEN 'Your request is open. A person on our ' || rt.team || ' team will review it and reply.'
              WHEN cr.outcome = 'EXISTING' THEN 'You already have an open ' || rt.label || ' request, so no new one was opened. Our ' || rt.team || ' team is on it.'
              WHEN cr.reason_text IS NOT NULL THEN cr.reason_text
              ELSE 'That is not a request I can open here. A person can help with offers and price questions, list-price changes, contract or closing updates, fair-housing questions and legal or mortgage questions.' END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN LATERAL (SELECT q.* FROM case_requests q WHERE q.lead_id = sl.lead_id AND q.request_type = norm_request_type(p_type)
                        ORDER BY q.request_id DESC LIMIT 1) cr ON TRUE
    LEFT JOIN case_routing rt ON rt.request_type = cr.request_type AND cr.outcome IN ('OPENED','EXISTING')
    LEFT JOIN service_cases s ON s.case_id = cr.case_id
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================
CREATE OR REPLACE FUNCTION customer_display(p_case TEXT) RETURNS TEXT AS $$
  SELECT l.first_name || ' ' || left(l.last_name, 1) || '. (' || lower(l.lead_type) || ' lead, ' || l.stage || ')'
    FROM service_cases s JOIN leads l ON l.lead_id = s.lead_id WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION case_amount_unit(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.request_type WHEN 'list_price_change' THEN 'USD new list price' ELSE 'no amount' END
    FROM service_cases s WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;
-- USD value of an approval compared with the reviewer's approval_limit: the size of the price change.
CREATE OR REPLACE FUNCTION case_value(p_case TEXT, p_amount NUMERIC) RETURNS NUMERIC AS $$
  SELECT CASE WHEN s.request_type = 'list_price_change' THEN abs(x.price - p_amount) END
    FROM service_cases s LEFT JOIN listings x ON x.listing_id = s.listing_id WHERE s.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no lead e-mail, phone or code).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE s.request_type
    WHEN 'offer_request' THEN
      coalesce(x.listing_id || ' ' || x.address || ', ' || x.area || ': ' || x.status || ', list price ' || usd(x.price) || ', '
               || (current_date - x.list_date) || ' days on market, area median ' || usd(m.median_price), 'No listing named')
      || coalesce('; offer idea ' || usd(s.requested_amount), '')
      || '; financing: ' || CASE WHEN l.pre_approved THEN 'pre-approval on file' || coalesce(' up to ' || usd(l.pre_approval_amount), '') ELSE 'no pre-approval on file' END
      || '. Approval means an agent will prepare / discuss the offer with the lead; nothing is submitted automatically.'
    WHEN 'list_price_change' THEN
      x.listing_id || ' ' || x.address || ', ' || x.area || ' (' || x.status || ', listed ' || d(x.list_date) || ', ' || (current_date - x.list_date)
      || ' days on market): current price ' || usd(x.price) || ', requested ' || usd(s.requested_amount) || ' (change '
      || usd(s.requested_amount - x.price) || ', ' || round((s.requested_amount - x.price) * 100 / x.price, 1) || '%); '
      || usd(round(x.price / x.sqft, 0)) || '/sqft vs area median ' || usd(m.median_price_per_sqft) || '/sqft; area median price '
      || usd(m.median_price) || ', ' || m.avg_days_on_market || ' avg days on market; showings in the last 30 days: '
      || (SELECT count(*) FROM appointments ap WHERE ap.listing_id = x.listing_id AND ap.scheduled_for BETWEEN now() - INTERVAL '30 days' AND now())
      || ', upcoming: ' || (SELECT count(*) FROM appointments ap WHERE ap.listing_id = x.listing_id AND ap.scheduled_for > now() AND ap.status IN ('Requested','Confirmed'))
      || '; allowed range ' || price_range_text(x.listing_id) || '.'
    WHEN 'stage_change' THEN
      'Lead status is ' || l.stage || '; requested ' || s.target_stage || '. Upcoming showings: '
      || (SELECT count(*) FROM appointments ap WHERE ap.lead_id = l.lead_id AND ap.scheduled_for > now() AND ap.status IN ('Requested','Confirmed'))
      || '. Approve only after the contract / closing is confirmed in the transaction file.'
    WHEN 'fair_housing_review' THEN
      'Category ' || coalesce(s.category, 'OTHER') || ', priority ' || s.priority || '. Reply with objective, public sources only (school district '
      || 'and city websites, the police department''s public data); never characterise a neighborhood, its residents or its schools. '
      || 'Your customer message is sent to the lead as the brokerage''s answer.'
    WHEN 'advice_referral' THEN
      'Topic: ' || coalesce(s.reference_id, 'not given') || '. Brightpath agents do not give legal or mortgage advice; reply with a referral '
      || '(a licensed real estate attorney or a lender of the lead''s choice).'
    ELSE 'No linked record.' END
    FROM service_cases s
    JOIN leads l ON l.lead_id = s.lead_id
    LEFT JOIN listings x ON x.listing_id = s.listing_id
    LEFT JOIN area_market_stats m ON m.area = x.area
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
   ORDER BY (q.priority = 'HIGH') DESC, q.sla_due_at
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id VARCHAR, request VARCHAR, case_status VARCHAR, priority VARCHAR, customer TEXT, opened_on TEXT,
               reply_due TEXT, customer_statement TEXT, agent_brief TEXT, requested TEXT, amount_unit TEXT, allowed_range TEXT,
               your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on TEXT, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN s.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         s.case_id, r.label, s.status, s.priority, customer_display(s.case_id), d(s.created_at::date), d(s.sla_due_at::date),
         s.summary, coalesce(s.agent_brief, CASE WHEN s.case_id IS NOT NULL THEN '(no AI brief for this request)' END),
         case_requested_text(s.case_id), case_amount_unit(s.case_id),
         CASE WHEN s.request_type = 'list_price_change' THEN price_range_text(s.listing_id) END,
         CASE WHEN s.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(s.case_id),
         CASE WHEN s.case_id IS NULL THEN NULL
              WHEN s.status <> 'OPEN' THEN 'Already decided.'
              WHEN s.request_type = 'list_price_change' THEN
                'APPROVE (the requested price, or a different new list price in ' || price_range_text(s.listing_id) || ')'
                || CASE WHEN sr.approval_limit IS NOT NULL THEN '; a change of more than your ' || usd(sr.approval_limit) || ' limit needs a senior reviewer' ELSE '' END
                || ' or REJECT, with an internal note and a message for the lead. Approval changes the list price.'
              WHEN s.request_type = 'stage_change' THEN 'APPROVE (sets the lead''s status to ' || s.target_stage || ') or REJECT, with an internal note and a message for the lead.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the lead (the message is the brokerage''s reply).' END,
         d(s.decided_at::date),
         (SELECT rd.decision || coalesce(' ' || case_amount_text(rd.case_id, rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = s.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND s.request_type IN (SELECT z.request_type FROM case_routing z WHERE z.team = sr.team)   -- another team's case is invisible
    LEFT JOIN case_routing r ON r.request_type = s.request_type
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id VARCHAR, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT, customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; s service_cases; r case_routing; x listings; l leads; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC;
        v_amt_txt TEXT := norm_amount(p_amount); v_msg TEXT;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) z;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO s FROM service_cases z WHERE z.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT * INTO r FROM case_routing z WHERE z.request_type = s.request_type;
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
  IF v_dec = 'APPROVE' AND s.request_type = 'list_price_change' THEN
    SELECT * INTO x FROM listings z WHERE z.listing_id = s.listing_id;
    IF x.status <> 'Active' THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ACTION_BLOCKED', 'The listing is now ' || x.status || ', so its price cannot be changed. The case stays open.');
      RETURN;
    END IF;
    v_amt := CASE WHEN v_amt_txt = '' THEN s.requested_amount ELSE money_or_null(p_amount) END;
    IF NOT coalesce(price_change_ok(x.listing_id, v_amt), FALSE) THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'AMOUNT_INVALID', 'The new list price must differ from the current price and stay within '
                || price_range_text(x.listing_id) || '.');
      RETURN;
    END IF;
    IF rv.approval_limit IS NOT NULL AND abs(x.price - v_amt) > rv.approval_limit THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'OVER_AUTHORITY', 'A ' || usd(abs(x.price - v_amt)) || ' price change is above your approval limit of '
                || usd(rv.approval_limit) || '. The case stays open and needs a senior reviewer (managing broker).');
      RETURN;
    END IF;
  ELSIF v_dec = 'APPROVE' AND s.request_type = 'stage_change' THEN
    SELECT * INTO l FROM leads z WHERE z.lead_id = s.lead_id;
    IF NOT stage_transition_ok(l.stage, s.target_stage) THEN
      INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
        VALUES (rv.reviewer_id, v_ref, 'BLOCKED', 'ACTION_BLOCKED', 'The lead''s status is now ' || l.stage || ', so it cannot move to ' || s.target_stage || '. The case stays open.');
      RETURN;
    END IF;
  END IF;
  IF v_dec = 'REJECT' THEN v_amt := NULL; END IF;
  v_msg := coalesce(nullif(trim(p_message), ''),
             CASE WHEN v_dec = 'APPROVE' THEN 'Your ' || r.label || ' request has been approved' || coalesce(' (' || case_amount_text(s.case_id, v_amt) || ')', '') || '.'
                  ELSE 'After review, your ' || r.label || ' request was not approved. Your Brightpath agent will follow up.' END);
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
                coalesce((SELECT 'List price of ' || c.listing_id || ' changed from ' || usd(c.old_price) || ' to ' || usd(c.new_price) || ' (' || c.reference || ').'
                            FROM listing_price_changes c WHERE c.case_id = s.case_id),
                         (SELECT 'Lead status updated from ' || e.old_stage || ' to ' || e.new_stage || '.'
                            FROM lead_stage_events e WHERE e.reference = s.case_id),
                         'Decision recorded; no automatic action - the team follows up with the lead.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = norm_ref(p_case)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN service_cases s ON s.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = s.case_id
$$ LANGUAGE sql STABLE;

-- Guarded row the decision trigger uses to change a list price (same checks every time).
CREATE OR REPLACE FUNCTION listing_price_row(p_case TEXT, p_new NUMERIC)
RETURNS TABLE (reference VARCHAR, listing_id VARCHAR, old_price NUMERIC, new_price NUMERIC, source VARCHAR, case_id VARCHAR) AS $$
  SELECT ('LPC-' || lpad(nextval(pg_get_serial_sequence('listing_price_changes', 'change_id'))::text, 6, '0'))::varchar,
         x.listing_id, x.price, p_new, 'REVIEWER'::varchar, s.case_id
    FROM service_cases s JOIN listings x ON x.listing_id = s.listing_id
   WHERE s.case_id = p_case AND s.request_type = 'list_price_change' AND x.status = 'Active'
     AND price_change_ok(x.listing_id, p_new)
     AND NOT EXISTS (SELECT 1 FROM listing_price_changes c WHERE c.case_id = s.case_id)
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION apply_listing_price_change() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.source = 'REVIEWER' THEN
    UPDATE listings SET price = NEW.new_price WHERE listing_id = NEW.listing_id;
    PERFORM audit('PRICE_CHANGED', coalesce(NEW.case_id, 'SYSTEM'), NEW.reference,
                  NEW.listing_id || ' ' || usd(NEW.old_price) || ' -> ' || usd(NEW.new_price));
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_listing_price_change AFTER INSERT ON listing_price_changes FOR EACH ROW EXECUTE FUNCTION apply_listing_price_change();

-- The decision event: case status + customer message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE s service_cases; v_kind TEXT; v_done TEXT := 'none';
BEGIN
  SELECT * INTO s FROM service_cases WHERE case_id = NEW.case_id;
  UPDATE service_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(s.parked_action, ''), ':', 1);
  IF v_kind = 'LIST_PRICE' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO listing_price_changes (reference, listing_id, old_price, new_price, source, case_id)
      SELECT * FROM listing_price_row(NEW.case_id, NEW.approved_amount);
    IF FOUND THEN v_done := 'list price of ' || s.listing_id || ' set to ' || usd(NEW.approved_amount); END IF;
  ELSIF v_kind = 'STAGE' AND NEW.decision = 'APPROVE' THEN
    INSERT INTO lead_stage_events (lead_id, old_stage, new_stage, source, reference)
      SELECT * FROM stage_event_row(s.lead_id, s.target_stage, 'REVIEWER', NEW.case_id);
    IF FOUND THEN v_done := 'lead status set to ' || s.target_stage; END IF;
  END IF;
  PERFORM audit('CASE_DECIDED', NEW.reviewer_id, NEW.case_id,
                NEW.decision || coalesce(' ' || case_amount_text(NEW.case_id, NEW.approved_amount), '') || '; executed: ' || v_done);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_review_decision AFTER INSERT ON review_decisions FOR EACH ROW EXECUTE FUNCTION apply_review_decision();

-- =====================================================================
-- EMAIL - only for the caller's showing (APT-), follow-up (FUP-) or decided case (BPR-CASE-)
-- =====================================================================
CREATE OR REPLACE FUNCTION email_source(p_token TEXT, p_reference TEXT)
RETURNS TABLE (lead_id VARCHAR, reference VARCHAR, kind TEXT, subject TEXT, detail TEXT) AS $$
  SELECT sl.lead_id, z.reference::varchar, z.kind, z.subject, z.detail
    FROM session_lead(p_token) sl
    JOIN LATERAL (
      SELECT ap.appointment_id::text AS reference, 'showing' AS kind,
             'Brightpath Realty showing confirmed ' || ap.appointment_id AS subject,
             'Your showing of ' || x.address || ', ' || x.area || ' (' || x.listing_id || ', ' || usd(x.price) || ') is booked for '
             || dt_long(ap.scheduled_for) || ' with your Brightpath agent ' || a.full_name || ' (' || a.phone || '). Reference: '
             || ap.appointment_id || '.' AS detail
        FROM appointments ap JOIN listings x ON x.listing_id = ap.listing_id JOIN agents a ON a.agent_id = ap.agent_id
       WHERE ap.lead_id = sl.lead_id AND ap.appointment_id = norm_ref(p_reference) AND ap.status IN ('Requested','Confirmed')
      UNION ALL
      SELECT f.task_id, 'follow-up', 'Brightpath Realty follow-up request ' || f.task_id,
             'Your agent ' || a.full_name || ' will contact you by ' || dt(f.due_at) || ' about: "' || left(f.message, 300) || '". Reference: ' || f.task_id || '.'
        FROM follow_up_tasks f JOIN agents a ON a.agent_id = f.agent_id
       WHERE f.lead_id = sl.lead_id AND f.task_id = norm_ref(p_reference)
      UNION ALL
      SELECT s.case_id, 'decision', 'Brightpath Realty reply to request ' || s.case_id,
             'Our ' || r.team || ' team has decided your ' || r.label || ' request (' || s.case_id || '): ' || lower(s.status) || '. '
             || s.customer_message
        FROM service_cases s JOIN case_routing r ON r.request_type = s.request_type
       WHERE s.lead_id = sl.lead_id AND s.case_id = norm_ref(p_reference)
         AND EXISTS (SELECT 1 FROM review_decisions rd WHERE rd.case_id = s.case_id)) z ON TRUE
   WHERE sl.lead_id IS NOT NULL
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_log_row(p_token TEXT, p_reference TEXT)
RETURNS TABLE (lead_id VARCHAR, reference VARCHAR, subject TEXT) AS $$
  SELECT e.lead_id, e.reference, e.subject FROM email_source(p_token, p_reference) e
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_reference TEXT)
RETURNS TABLE (send_status TEXT, reason_code TEXT, reason_text TEXT, reference VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN e.reference IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN e.reference IS NOT NULL THEN NULL WHEN sl.lead_id IS NULL THEN 'SESSION_INVALID' ELSE 'NOT_FOUND' END,
         CASE WHEN e.reference IS NOT NULL THEN 'Your confirmation email is on its way.'
              WHEN sl.lead_id IS NULL THEN 'Please verify your identity again (your e-mail and one-time code).'
              ELSE 'There is no showing, follow-up or decided request with that reference for you, so no email was sent.' END,
         e.reference,
         coalesce(e.subject, 'Brightpath Realty confirmation - not sent'),
         CASE WHEN e.reference IS NOT NULL THEN
           'Hello ' || l.first_name || ',' || chr(10) || chr(10)
           || 'This is a confirmation from Harper, the Brightpath Realty AI assistant.' || chr(10) || chr(10)
           || e.detail || chr(10) || chr(10)
           || 'Questions? Reply to this email or call Brightpath Realty at (555) 010-4400.' || chr(10)
           || 'Brightpath Realty is committed to equal housing opportunity.'
           ELSE 'No confirmation email was sent for reference ' || norm_ref(p_reference) || '.' END
    FROM (SELECT * FROM session_lead(p_token)) sl
    LEFT JOIN leads l ON l.lead_id = sl.lead_id
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

CREATE OR REPLACE FUNCTION ref_listing_match(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM listing_match_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['COLUMN','WALK_SCORE','AMENITY','RANKING','EXCLUDE','FAIR_HOUSING','NOTE_LINE'],
                           g.section::text), g.entry_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_lead_intent(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT g.section::text, g.term::text, g.meaning::text
    FROM lead_intent_guide g
   WHERE ref_match(p_term, g.section, g.term, g.meaning)
   ORDER BY array_position(ARRAY['INTENT','TIMELINE','PRE_APPROVAL','MOTIVATION','RULE','FIRST_CALL'], g.section::text),
            g.entry_id
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION ref_fair_housing(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM fair_housing_guide g
          UNION ALL                                 -- who reviews a flagged question has ONE source of truth: case_routing
          SELECT 'ROUTING', cr.label::text, ('reviewed by ' || cr.team || ': ' || cr.sla_text)::text, 1000
            FROM case_routing cr WHERE cr.request_type = 'fair_housing_review') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['PROTECTED','CATEGORY','NEUTRAL_ANSWER','ROUTING','RULE'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
