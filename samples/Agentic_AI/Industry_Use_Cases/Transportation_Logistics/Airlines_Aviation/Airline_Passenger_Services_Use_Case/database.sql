-- Meridian Passenger Services (GOVERNED) - schema, business rules and demo data.
-- Load:  createdb airline_governed  &&  psql -d airline_governed -f database.sql
--
-- =====================================================================
-- Airline Passenger Services - Governed Agentic AI
-- The rules live HERE, not in any prompt:
--   * session_booking()     identity: every read/write is scoped by a session token (PNR + PIN)
--   * connection_risk()     SAFE / AT_RISK / MISSED is ARITHMETIC in SQL, never the LLM's guess
--   * rebook_eval()         rebooking eligibility (ownership, disruption, route, time, seats)
--   * trg_rebooking_apply   the rebooking side effects happen atomically in the DB
--   * search_alternatives() keyword/route search for the A2A agent - NO passenger identity
--   * service_cases.assigned_team  human-owned requests (compensation, baggage...) routed by a table
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The one genuinely semantic step is the A2A agent ranking alternative flights against the
-- traveller's free-text preferences.
-- =====================================================================

DROP TABLE IF EXISTS agent_audit, verify_attempts, service_cases, service_teams, rebooking_log, rebookings,
  pending_actions, traveler_sessions, booking_segments, bookings, frequentflyer, passengers, flights CASCADE;

CREATE TABLE flights (
  flight_number        VARCHAR(10) PRIMARY KEY,
  origin               VARCHAR(3)  NOT NULL,
  origin_city          VARCHAR(50) NOT NULL,
  destination          VARCHAR(3)  NOT NULL,
  destination_city     VARCHAR(50) NOT NULL,
  scheduled_departure  TIMESTAMP   NOT NULL,
  scheduled_arrival    TIMESTAMP   NOT NULL,
  status               VARCHAR(20) NOT NULL DEFAULT 'ON_TIME'
                         CHECK (status IN ('ON_TIME','DELAYED','BOARDING','DEPARTED','CANCELLED')),
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

CREATE TABLE traveler_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  booking_id     INTEGER NOT NULL REFERENCES bookings,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes'
);

-- Brute-force throttle for the PIN step: N wrong PINs for a PNR -> a cooldown lock (OWASP identity-spoofing).
CREATE TABLE verify_attempts (
  pnr           VARCHAR(6) PRIMARY KEY,
  attempts      INTEGER NOT NULL DEFAULT 0,
  locked_until  TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
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

CREATE TABLE service_teams (
  request_type  VARCHAR(24) PRIMARY KEY,
  team          VARCHAR(60) NOT NULL,
  sla_days      INTEGER NOT NULL
);

CREATE TABLE service_cases (
  case_id             TEXT PRIMARY KEY DEFAULT 'SC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  booking_id          INTEGER NOT NULL REFERENCES bookings,
  pnr                 VARCHAR(6) NOT NULL,
  request_type        VARCHAR(24) NOT NULL REFERENCES service_teams,
  traveler_statement  TEXT NOT NULL,
  agent_brief         TEXT NOT NULL,            -- neutral summary written by the assistant; never a decision
  status              VARCHAR(12) NOT NULL DEFAULT 'OPEN',
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; travellers never see it.
CREATE TABLE agent_audit (
  audit_id  SERIAL PRIMARY KEY,
  at        TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  pnr       VARCHAR(6),
  action    VARCHAR(40) NOT NULL,   -- VERIFY_SESSION_ISSUED, REBOOK_PROPOSED, REBOOK_EXECUTED, SERVICE_CASE_OPENED
  detail    TEXT
);

-- =====================================================================
-- RULES
-- =====================================================================

-- Identity: a token is valid for its booking until it expires. ALWAYS returns exactly one row -
-- the booking when valid, or (null,null,null) when not - so dependent reads can emit SESSION_INVALID.
-- plpgsql (NOT sql) on purpose: an inlinable SQL function here merges its LEFT JOINs into the
-- caller's chained LEFT JOINs and mis-binds flight rows to an empty segment. plpgsql is opaque to
-- the planner, so callers see a clean one-row relation.
CREATE OR REPLACE FUNCTION session_booking(p_token TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, passenger_id VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT b.booking_id, b.pnr, b.passenger_id
      FROM (SELECT 1) one
      LEFT JOIN traveler_sessions s ON s.session_token = p_token AND s.expires_at > clock_timestamp()
      LEFT JOIN bookings b ON b.booking_id = s.booking_id;
END $$ LANGUAGE plpgsql STABLE;

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
        JOIN traveler_sessions se ON se.booking_id = b.booking_id AND se.expires_at > clock_timestamp()
       WHERE b.pnr = upper(trim(p_pnr)) AND b.verification_pin = trim(p_pin)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- Scoped read: the traveller's own itinerary with live flight status per leg.
CREATE OR REPLACE FUNCTION my_itinerary(p_token TEXT)
RETURNS TABLE (session_status TEXT, pnr VARCHAR, segment_order INTEGER, flight_number VARCHAR,
               origin VARCHAR, destination VARCHAR, scheduled_departure TIMESTAMP, estimated_departure TIMESTAMP,
               scheduled_arrival TIMESTAMP, estimated_arrival TIMESTAMP, flight_status VARCHAR, delay_minutes INTEGER,
               gate VARCHAR, seat VARCHAR, cabin VARCHAR, segment_status VARCHAR) AS $$
  SELECT CASE WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         sb.pnr, seg.segment_order, seg.flight_number, seg.origin, seg.destination,
         f.scheduled_departure, f.est_departure, f.scheduled_arrival, f.est_arrival,
         f.status, f.delay_minutes, f.gate, seg.seat_number, seg.cabin, seg.segment_status
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

-- Email confirmation: validated payload for the guarded email tool. Returns SENT_OK + recipient/subject/body
-- ONLY when the action is an executed rebooking for THIS session; otherwise NOT_SENT + reason, no recipient.
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_action TEXT)
RETURNS TABLE (send_status TEXT, reason TEXT, to_email VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN rb.rebooking_id IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN 'Confirmation email prepared.'
              WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID: verify again.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no rebooking with that id for this booking.'
              ELSE 'NOT_EXECUTED: that rebooking has not been confirmed yet, so there is nothing to email.' END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN p.email END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN 'Your Meridian rebooking is confirmed - ' || sb.pnr
              ELSE 'Meridian rebooking confirmation - not sent' END,
         CASE WHEN rb.rebooking_id IS NOT NULL THEN
           'Dear ' || p.first_name || ',' || chr(10) || chr(10)
           || 'Your booking ' || sb.pnr || ' has been rebooked.' || chr(10)
           || 'From flight ' || rb.from_flight || ' to flight ' || rb.to_flight
           || ', seat ' || rb.new_seat || '.' || chr(10)
           || 'New departure ' || to_char(f.est_departure,'YYYY-MM-DD HH24:MI')
           || ', arriving ' || to_char(f.est_arrival,'HH24:MI') || '.' || chr(10) || chr(10)
           || 'Thank you for flying Meridian.'
           ELSE 'No confirmation email was sent for action ' || upper(trim(coalesce(p_action,''))) || '.' END
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN passengers p ON p.passenger_id = sb.passenger_id
    LEFT JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.booking_id = sb.booking_id
    LEFT JOIN rebookings rb ON rb.action_id = pa.action_id
    LEFT JOIN flights f ON f.flight_number = rb.to_flight;
$$ LANGUAGE sql STABLE;

-- Human-owned requests -> routed to a team by the table, never decided by the LLM.
CREATE OR REPLACE FUNCTION service_case_row(p_token TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT)
RETURNS TABLE (booking_id INTEGER, pnr VARCHAR, request_type VARCHAR, traveler_statement TEXT, agent_brief TEXT) AS $$
  SELECT sb.booking_id, sb.pnr, t.request_type, left(coalesce(p_statement,''),4000), left(coalesce(p_brief,''),4000)
    FROM (SELECT * FROM session_booking(p_token)) sb
    JOIN service_teams t ON t.request_type = upper(trim(p_type))
   WHERE sb.booking_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM service_cases sc
                      WHERE sc.booking_id = sb.booking_id AND sc.request_type = t.request_type
                        AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION service_case_result(p_token TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'A person on the assigned team will review and reply. The assistant has not decided anything.'
              WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              ELSE 'BAD_REQUEST_TYPE: use COMPENSATION_CLAIM, BAGGAGE_CLAIM, SPECIAL_ASSISTANCE, COMPLAINT, NAME_CHANGE or OTHER.' END,
         c.case_id, c.request_type, t.team, t.sla_days, c.status, c.created_at
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN LATERAL (
      SELECT sc.* FROM service_cases sc
       WHERE sc.booking_id = sb.booking_id AND sc.request_type = upper(trim(p_type))
         AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes'
       ORDER BY sc.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sb.booking_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_id, c.request_type, t.team, c.status, c.created_at
    FROM (SELECT * FROM session_booking(p_token)) sb
    LEFT JOIN service_cases c ON c.booking_id = sb.booking_id
    LEFT JOIN service_teams t ON t.request_type = c.request_type
   ORDER BY c.created_at DESC;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change. Cannot be bypassed
-- by the LLM because they fire in the database, not the app.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (pnr, action, detail)
    SELECT b.pnr, 'VERIFY_SESSION_ISSUED', 'session issued for booking ' || b.pnr
      FROM bookings b WHERE b.booking_id = NEW.booking_id;
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
    VALUES (NEW.pnr, 'SERVICE_CASE_OPENED', NEW.request_type || ' (' || NEW.case_id || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_case AFTER INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION audit_case();

\ir seed_data.sql
