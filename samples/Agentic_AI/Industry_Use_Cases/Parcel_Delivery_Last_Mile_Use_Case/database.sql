-- Swiftbound Last-Mile Parcel Delivery (GOVERNED) - schema, business rules and demo data.
-- Load:  createdb parcel_delivery  &&  psql -d parcel_delivery -f database.sql
--
-- =====================================================================
-- Parcel Delivery - Governed Agentic AI
-- The rules live HERE, not in any prompt:
--   * session_recipient()     identity: every read/write is scoped by a session token (account ref + PIN)
--   * delivery_health()       ON_TRACK / NEEDS_ATTENTION / LATE is computed in SQL, never the LLM's guess
--   * reschedule_eval()       reschedule eligibility (ownership, status, slot area/capacity/date)
--   * redirect_eval()         redirect eligibility (ownership, status, pickup area/size/signature/value)
--   * trg_delivery_change     the reschedule/redirect side effects happen atomically in the DB
--   * search_delivery_options() feasible slots + pickup points for the A2A agent - NO recipient identity
--   * service_cases.assigned_team  human-owned requests (lost/damaged claims...) routed by a table
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The one genuinely semantic step is the A2A agent ranking the feasible delivery options against the
-- recipient's free-text preferences. Exception-code MEANINGS come from the exception_codes table (a
-- deterministic lookup), never invented by the model.
-- =====================================================================

DROP TABLE IF EXISTS agent_audit, verify_attempts, service_cases, service_teams, delivery_change_log,
  delivery_changes, pending_actions, recipient_sessions, scan_events, parcels, pickup_points,
  delivery_slots, exception_codes, recipients CASCADE;

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
  expected_delivery    TIMESTAMP,
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

CREATE TABLE recipient_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  recipient_id   VARCHAR(20) NOT NULL REFERENCES recipients,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes'
);

-- Brute-force throttle for the PIN step: N wrong PINs for an account ref -> a cooldown lock.
CREATE TABLE verify_attempts (
  account_ref   VARCHAR(8) PRIMARY KEY,
  attempts      INTEGER NOT NULL DEFAULT 0,
  locked_until  TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pending_actions (
  action_id     TEXT PRIMARY KEY DEFAULT 'ACT-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  action_type   VARCHAR(12) NOT NULL CHECK (action_type IN ('RESCHEDULE','REDIRECT')),
  parcel_id     INTEGER NOT NULL REFERENCES parcels,
  slot_id       VARCHAR(12) REFERENCES delivery_slots,
  pickup_id     VARCHAR(14) REFERENCES pickup_points,
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

CREATE TABLE delivery_change_log (
  id              SERIAL PRIMARY KEY,
  tracking_number VARCHAR(18) NOT NULL,
  recipient_id    VARCHAR(20),
  action_type     VARCHAR(12) NOT NULL,
  detail          TEXT NOT NULL,
  changed_at      TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE service_teams (
  request_type  VARCHAR(24) PRIMARY KEY,
  team          VARCHAR(60) NOT NULL,
  sla_days      INTEGER NOT NULL
);

CREATE TABLE service_cases (
  case_id             TEXT PRIMARY KEY DEFAULT 'SC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  recipient_id        VARCHAR(20) NOT NULL REFERENCES recipients,
  account_ref         VARCHAR(8)  NOT NULL,
  tracking_number     VARCHAR(18),
  request_type        VARCHAR(24) NOT NULL REFERENCES service_teams,
  recipient_statement TEXT NOT NULL,
  agent_brief         TEXT NOT NULL,            -- neutral summary written by the assistant; never a decision
  status              VARCHAR(12) NOT NULL DEFAULT 'OPEN',
  created_at          TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail (OWASP: repudiation / untraceability): one row per consequential state change the agent caused,
-- written by triggers so it cannot be bypassed. Back-office/ops read it by SQL; recipients never see it.
CREATE TABLE agent_audit (
  audit_id  SERIAL PRIMARY KEY,
  at        TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  account_ref VARCHAR(8),
  action    VARCHAR(40) NOT NULL,   -- VERIFY_SESSION_ISSUED, RESCHEDULE_PROPOSED, DELIVERY_CHANGE_EXECUTED, SERVICE_CASE_OPENED
  detail    TEXT
);

-- =====================================================================
-- RULES
-- =====================================================================

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
      LEFT JOIN recipient_sessions s ON s.session_token = p_token AND s.expires_at > clock_timestamp()
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
               current_slot VARCHAR, current_pickup VARCHAR) AS $$
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
         (SELECT pp.name || ' (' || pp.point_type || ')' FROM pickup_points pp WHERE pp.pickup_id = pc.redirect_pickup_id)
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

-- Email confirmation: validated payload for the guarded email tool. Returns SEND_OK + recipient/subject/body
-- ONLY when the action is an executed delivery change for THIS session; otherwise NOT_SENT + reason, no recipient.
CREATE OR REPLACE FUNCTION email_confirmation_payload(p_token TEXT, p_action TEXT)
RETURNS TABLE (send_status TEXT, reason TEXT, to_email VARCHAR, subject TEXT, body TEXT) AS $$
  SELECT CASE WHEN dc.change_id IS NOT NULL THEN 'SEND_OK' ELSE 'NOT_SENT' END,
         CASE WHEN dc.change_id IS NOT NULL THEN 'Confirmation email prepared.'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID: verify again.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no action with that id on this account.'
              ELSE 'NOT_EXECUTED: that change has not been confirmed yet, so there is nothing to email.' END,
         CASE WHEN dc.change_id IS NOT NULL THEN r.email END,
         CASE WHEN dc.change_id IS NOT NULL THEN 'Your Swiftbound delivery is updated - ' || pc.tracking_number
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
           ELSE 'No confirmation email was sent for action ' || upper(trim(coalesce(p_action,''))) || '.' END
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN recipients r ON r.recipient_id = sr.recipient_id
    LEFT JOIN pending_actions pa ON pa.action_id = upper(trim(p_action))
         AND EXISTS (SELECT 1 FROM parcels pc2 WHERE pc2.parcel_id = pa.parcel_id AND pc2.recipient_id = sr.recipient_id)
    LEFT JOIN parcels pc ON pc.parcel_id = pa.parcel_id
    LEFT JOIN delivery_changes dc ON dc.action_id = pa.action_id;
$$ LANGUAGE sql STABLE;

-- Human-owned requests -> routed to a team by the table, never decided by the LLM.
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
               reply_within_business_days INTEGER, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'A person on the assigned team will review and reply. The assistant has not decided anything.'
              WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              ELSE 'BAD_REQUEST_TYPE: use LOST_PARCEL, DAMAGED_PARCEL, MISSING_ITEMS, WRONG_DELIVERY, DELIVERY_COMPLAINT or OTHER.' END,
         c.case_id, c.request_type, t.team, t.sla_days, c.status, c.created_at
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT sc.* FROM service_cases sc
       WHERE sc.recipient_id = sr.recipient_id AND sc.request_type = upper(trim(p_type))
         AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes'
       ORDER BY sc.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN service_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_id TEXT, request_type VARCHAR, tracking_number VARCHAR,
               assigned_team VARCHAR, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN sr.recipient_id IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_id, c.request_type, c.tracking_number, t.team, c.status, c.created_at
    FROM (SELECT * FROM session_recipient(p_token)) sr
    LEFT JOIN service_cases c ON c.recipient_id = sr.recipient_id
    LEFT JOIN service_teams t ON t.request_type = c.request_type
   ORDER BY c.created_at DESC;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Audit trail: triggers write one agent_audit row per consequential state change.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_session() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, detail)
    SELECT r.account_ref, 'VERIFY_SESSION_ISSUED', 'session issued for account ' || r.account_ref
      FROM recipients r WHERE r.recipient_id = NEW.recipient_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON recipient_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_proposal() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, detail)
    SELECT r.account_ref, NEW.action_type || '_PROPOSED',
           'parcel ' || pc.tracking_number || ' -> ' || coalesce(NEW.slot_id, NEW.pickup_id) || ' (action ' || NEW.action_id || ')'
      FROM parcels pc JOIN recipients r ON r.recipient_id = pc.recipient_id WHERE pc.parcel_id = NEW.parcel_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_proposal AFTER INSERT ON pending_actions FOR EACH ROW EXECUTE FUNCTION audit_proposal();

CREATE OR REPLACE FUNCTION audit_change() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, detail)
    SELECT r.account_ref, 'DELIVERY_CHANGE_EXECUTED',
           NEW.action_type || ' ' || pc.tracking_number || ' -> ' || coalesce(NEW.slot_id, NEW.pickup_id)
      FROM parcels pc JOIN recipients r ON r.recipient_id = pc.recipient_id WHERE pc.parcel_id = NEW.parcel_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_change AFTER INSERT ON delivery_changes FOR EACH ROW EXECUTE FUNCTION audit_change();

CREATE OR REPLACE FUNCTION audit_case() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_audit (account_ref, action, detail)
    VALUES (NEW.account_ref, 'SERVICE_CASE_OPENED', NEW.request_type || ' (' || NEW.case_id || ')');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_case AFTER INSERT ON service_cases FOR EACH ROW EXECUTE FUNCTION audit_case();

\ir seed_data.sql
