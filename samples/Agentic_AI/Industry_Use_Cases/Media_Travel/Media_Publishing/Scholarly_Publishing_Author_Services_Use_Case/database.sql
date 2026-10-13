-- Scholarly Publishing Author Services - schema, business rules and demo data.
-- Load:  createdb author_services  &&  psql -d author_services -f database.sql
--
-- =====================================================================
-- Scholarly Publishing - Author Services Assistant (governed)
-- Schema + business rules. The rules live HERE, not in any prompt:
--   * session_author() / session_reviewer()  identity: every read/write is scoped by a session token; author and
--                            staff-reviewer tokens share one table but are not interchangeable (the role is checked)
--   * transfer_eval()        transfer eligibility (status, editorial hold, scope, word limit, and the target journal's
--                            submission statements: a recent COMPLETE submission check or an editor's exception)
--   * submission_assessment()  the submission_check_agent's flagged statements are VALIDATED against the target
--                            journal's policy rows and COMBINED with a deterministic presence check -> COMPLETE /
--                            INCOMPLETE, recorded in submission_checks (an INCOMPLETE check blocks the transfer)
--   * apc_quote()            APC price + institutional agreement coverage (arithmetic in SQL)
--   * trg_transfer_apply     the transfer side effects happen atomically in the DB
--   * review_teams           human-owned requests are routed by a table, never by the LLM
--   * case_parking()         a case may PARK a typed action (APC_WAIVER:<manuscript> / ACCEPT_STATEMENTS:<check>)
--                            that runs ONLY when a staff reviewer of that team approves it
--   * reviewers + decide_case_row()  the human in the loop: own team only, approval limit (OVER_AUTHORITY), amount
--                            checks; review_decisions + trg_review_decision execute the parked action through the
--                            same guarded row functions (APC reduction / statements exception) and audit it
--   * search_journals() / ref_review_guide() / ref_journal_policy()  the agents' read-only reference reads - NO
--                            author identity in or out
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- The genuinely semantic steps are the three A2A agents: journal_match_agent (abstract vs aims & scope),
-- review_summary_agent (reviewer comments -> a revision checklist) and submission_check_agent (the author's
-- statements vs the target journal's policy).
-- All publishers, journals, institutions, staff and people are fictional.
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

DROP TABLE IF EXISTS agent_audit, statement_exceptions, apc_reductions, decide_attempts, review_decisions,
  submission_checks, review_cases, transfers, pending_actions, reviewer_verify_attempts, author_sessions, reviewers,
  review_comments, manuscripts, authors, agreement_journals, oa_agreements, journals, submission_policies,
  institutions, review_teams, review_guide CASCADE;
DROP SEQUENCE IF EXISTS chk_seq, apr_seq, exc_seq;

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

CREATE TABLE institutions (
  institution_id  VARCHAR(12) PRIMARY KEY,
  name            VARCHAR(120) NOT NULL,
  country         VARCHAR(60)  NOT NULL
);

CREATE TABLE oa_agreements (
  agreement_id    VARCHAR(12) PRIMARY KEY,
  institution_id  VARCHAR(12) NOT NULL REFERENCES institutions,
  name            VARCHAR(120) NOT NULL,
  model           VARCHAR(40)  NOT NULL,          -- Read & Publish, Publish & Read ...
  coverage_pct    INTEGER      NOT NULL CHECK (coverage_pct BETWEEN 0 AND 100),
  valid_from      DATE         NOT NULL,
  valid_to        DATE         NOT NULL,
  apc_budget_usd  NUMERIC(12,2) NOT NULL,
  apc_spent_usd   NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Agent reference table (submission_check_agent, through ref_journal_policy only): each journal follows one policy
-- set; each row is one statement the journal asks for, whether it is MANDATORY, what it must include and the
-- publisher's standard wording. keyword_pattern is the deterministic presence check SQL runs (never shown to agents).
-- Reference data only - no author, manuscript, case, session or contact data.
CREATE TABLE submission_policies (
  policy_set       VARCHAR(20) NOT NULL CHECK (policy_set IN ('STANDARD','OPEN_DATA','HUMAN_SUBJECTS')),
  statement        VARCHAR(24) NOT NULL CHECK (statement IN ('DATA_AVAILABILITY','ETHICS_APPROVAL','FUNDING',
                                                               'COMPETING_INTERESTS','AUTHOR_CONTRIBUTIONS')),
  sort_order       INTEGER NOT NULL,
  requirement      VARCHAR(12) NOT NULL CHECK (requirement IN ('MANDATORY','RECOMMENDED')),
  must_include     VARCHAR(300) NOT NULL,
  standard_wording VARCHAR(400) NOT NULL,
  keyword_pattern  VARCHAR(200) NOT NULL,
  PRIMARY KEY (policy_set, statement)
);

CREATE TABLE journals (
  journal_code        VARCHAR(8) PRIMARY KEY,
  title               VARCHAR(140) NOT NULL,
  subject_area        VARCHAR(80)  NOT NULL,
  aims_scope          TEXT         NOT NULL,
  keywords            TEXT         NOT NULL,
  oa_model            VARCHAR(20)  NOT NULL CHECK (oa_model IN ('Gold OA','Hybrid')),
  apc_usd             NUMERIC(10,2) NOT NULL,
  word_limit          INTEGER      NOT NULL,
  median_days_to_first_decision INTEGER NOT NULL,
  accepts_transfers   BOOLEAN      NOT NULL DEFAULT TRUE,
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
  policy_set          VARCHAR(20)  NOT NULL DEFAULT 'STANDARD',
  search              TSVECTOR GENERATED ALWAYS AS (
                        setweight(to_tsvector('english', title), 'A') ||
                        setweight(to_tsvector('english', keywords), 'A') ||
                        setweight(to_tsvector('english', subject_area), 'B') ||
                        setweight(to_tsvector('english', aims_scope), 'C')) STORED
);
CREATE INDEX journals_search_idx ON journals USING GIN (search);

CREATE TABLE agreement_journals (
  agreement_id  VARCHAR(12) REFERENCES oa_agreements,
  journal_code  VARCHAR(8)  REFERENCES journals,
  PRIMARY KEY (agreement_id, journal_code)
);

CREATE TABLE authors (
  author_id          VARCHAR(12) PRIMARY KEY,
  orcid              VARCHAR(19) UNIQUE NOT NULL,
  full_name          VARCHAR(120) NOT NULL,
  email              VARCHAR(120) NOT NULL,
  institution_id     VARCHAR(12) NOT NULL REFERENCES institutions,
  verification_code  VARCHAR(6)  NOT NULL   -- demo stand-in for an emailed one-time code / SSO
);

CREATE TABLE manuscripts (
  manuscript_id            VARCHAR(16) PRIMARY KEY,
  corresponding_author_id  VARCHAR(12) NOT NULL REFERENCES authors,
  journal_code             VARCHAR(8)  NOT NULL REFERENCES journals,
  title                    VARCHAR(240) NOT NULL,
  abstract                 TEXT NOT NULL,
  keywords                 TEXT NOT NULL,
  article_type             VARCHAR(40) NOT NULL,
  word_count               INTEGER NOT NULL,
  status                   VARCHAR(30) NOT NULL CHECK (status IN
                             ('SUBMITTED','UNDER_REVIEW','REVISION_REQUESTED','ACCEPTED','PUBLISHED',
                              'REJECTED','REJECTED_TRANSFER_ELIGIBLE','WITHDRAWN')),
  status_detail            TEXT NOT NULL,
  decision_summary         TEXT,
  declarations             TEXT NOT NULL DEFAULT '',   -- the author's statements as submitted (data, ethics, funding ...)
  submitted_on             DATE NOT NULL,
  last_updated             TIMESTAMP NOT NULL DEFAULT now(),
  integrity_hold           BOOLEAN NOT NULL DEFAULT FALSE,   -- never disclosed to the author
  transferred_from         VARCHAR(8) REFERENCES journals
);

-- The editor's decision letter and the anonymous reviewer comments for a manuscript (peer review is anonymous:
-- no reviewer names are stored). Read only through get_review_comments (the author's own manuscripts).
CREATE TABLE review_comments (
  comment_id     SERIAL PRIMARY KEY,
  manuscript_id  VARCHAR(16) NOT NULL REFERENCES manuscripts,
  comment_ref    VARCHAR(8)  NOT NULL,                -- E.1, R1.1, R2.3 ...
  source         VARCHAR(12) NOT NULL CHECK (source IN ('EDITOR','REVIEWER_1','REVIEWER_2','REVIEWER_3')),
  comment_text   TEXT NOT NULL,
  UNIQUE (manuscript_id, comment_ref)
);

-- Agent reference table (review_summary_agent, through ref_review_guide only): comment types, priority rules,
-- checklist rules and the standard response-letter line. Reference data only - no author or manuscript data.
-- The "who decides" row is NOT copied here: ref_review_guide reads it from review_teams (one source of truth).
CREATE TABLE review_guide (
  entry_id    SERIAL PRIMARY KEY,
  section     VARCHAR(20) NOT NULL CHECK (section IN ('COMMENT_TYPE','PRIORITY','CHECKLIST_RULE','RESPONSE_LETTER')),
  term        VARCHAR(60) NOT NULL,
  meaning     VARCHAR(300) NOT NULL,
  UNIQUE (section, term)
);

-- Human-owned request types -> team + SLA. The model supplies request_type; the table decides the rest.
CREATE TABLE review_teams (
  request_type    VARCHAR(24) PRIMARY KEY,
  label           VARCHAR(48) NOT NULL,              -- author-facing name
  team            VARCHAR(60) NOT NULL,
  sla_days        INTEGER NOT NULL,                  -- reply within N business days
  author_openable BOOLEAN NOT NULL DEFAULT TRUE
);

-- Staff reviewers (the human in the loop). team matches review_teams.team.
CREATE TABLE reviewers (
  reviewer_id     VARCHAR(10) PRIMARY KEY,           -- PUB-7001 (staff id)
  display_name    VARCHAR(60) NOT NULL,
  team            VARCHAR(60) NOT NULL,
  one_time_code   VARCHAR(6)  NOT NULL,              -- HIDDEN: demo stand-in for the staff sign-in code
  approval_limit  NUMERIC(12,2),                     -- NULL = no limit
  active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- One session table for both roles; every rule function checks the role.
CREATE TABLE author_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  role           VARCHAR(10) NOT NULL DEFAULT 'AUTHOR' CHECK (role IN ('AUTHOR','REVIEWER')),
  author_id      VARCHAR(12) REFERENCES authors,
  reviewer_id    VARCHAR(10) REFERENCES reviewers,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes',
  CHECK ((role = 'AUTHOR' AND author_id IS NOT NULL AND reviewer_id IS NULL)
      OR (role = 'REVIEWER' AND reviewer_id IS NOT NULL AND author_id IS NULL))
);

-- Brute-force throttle for the staff code step (5 wrong codes in 15 minutes -> locked).
CREATE TABLE reviewer_verify_attempts (
  attempt_id   SERIAL PRIMARY KEY,
  reviewer_id  VARCHAR(10) NOT NULL REFERENCES reviewers,
  ok           BOOLEAN NOT NULL,
  at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pending_actions (
  action_id            TEXT PRIMARY KEY DEFAULT 'ACT-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  action_type          VARCHAR(30) NOT NULL CHECK (action_type IN ('TRANSFER')),
  author_id            VARCHAR(12) NOT NULL REFERENCES authors,
  manuscript_id        VARCHAR(16) NOT NULL REFERENCES manuscripts,
  target_journal_code  VARCHAR(8)  NOT NULL REFERENCES journals,
  apc_usd              NUMERIC(10,2) NOT NULL,
  coverage_pct         INTEGER NOT NULL,
  author_pays_usd      NUMERIC(10,2) NOT NULL,
  status               VARCHAR(12) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','EXECUTED')),
  created_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '15 minutes'
);

CREATE TABLE transfers (
  transfer_id     SERIAL PRIMARY KEY,
  action_id       TEXT UNIQUE NOT NULL REFERENCES pending_actions,
  manuscript_id   VARCHAR(16) UNIQUE NOT NULL REFERENCES manuscripts,   -- a manuscript transfers once
  from_journal    VARCHAR(8) NOT NULL REFERENCES journals,
  to_journal      VARCHAR(8) NOT NULL REFERENCES journals,
  transferred_at  TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Every recorded submission check = what the submission_check_agent flagged (validated) + what SQL found + the result.
CREATE SEQUENCE chk_seq START 1;
CREATE TABLE submission_checks (
  check_id             VARCHAR(12) PRIMARY KEY DEFAULT 'SCK-' || lpad(nextval('chk_seq')::text, 5, '0'),
  author_id            VARCHAR(12) NOT NULL REFERENCES authors,
  manuscript_id        VARCHAR(16) NOT NULL REFERENCES manuscripts,
  journal_code         VARCHAR(8)  NOT NULL REFERENCES journals,
  statements           TEXT NOT NULL,             -- the statements checked (as submitted + anything the author added)
  agent_notes          TEXT,                      -- HIDDEN from authors: the agent's full answer (reviewers only)
  agent_items          TEXT,                      -- agent-flagged statements that exist in the journal's policy
  ignored_items        TEXT,                      -- anything else the model sent (recorded, never counted)
  rule_items           TEXT,                      -- MANDATORY statements the deterministic presence check found missing
  mandatory_missing    TEXT,
  recommended_missing  TEXT,
  result               VARCHAR(12) NOT NULL CHECK (result IN ('COMPLETE','INCOMPLETE')),
  created_at           TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);
ALTER SEQUENCE chk_seq OWNED BY submission_checks.check_id;

CREATE TABLE review_cases (
  case_id           TEXT PRIMARY KEY DEFAULT 'RC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  author_id         VARCHAR(12) NOT NULL REFERENCES authors,
  manuscript_id     VARCHAR(16) REFERENCES manuscripts,
  request_type      VARCHAR(24) NOT NULL REFERENCES review_teams,
  author_statement  TEXT NOT NULL,
  agent_brief       TEXT NOT NULL,          -- neutral summary by the assistant / an agent; never a decision (HIDDEN from authors)
  requested_amount  NUMERIC(12,2),          -- APC_WAIVER: what the author would pay (NULL = no amount)
  parked_action     VARCHAR(40),            -- runs ONLY on approval: APC_WAIVER:<manuscript> / ACCEPT_STATEMENTS:<check>
  status            VARCHAR(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED')),
  sla_due_at        TIMESTAMP,              -- set by trg_case_defaults from review_teams
  customer_message  TEXT,                   -- author-safe outcome text, set by the reviewer's decision
  approved_amount   NUMERIC(12,2),
  decided_at        TIMESTAMP,
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Insert-only decision events (one per case). trg_review_decision applies them.
CREATE TABLE review_decisions (
  decision_id      SERIAL PRIMARY KEY,
  case_id          TEXT NOT NULL UNIQUE REFERENCES review_cases,
  reviewer_id      VARCHAR(10) NOT NULL REFERENCES reviewers,
  decision         VARCHAR(8) NOT NULL CHECK (decision IN ('APPROVE','REJECT')),
  approved_amount  NUMERIC(12,2),
  internal_note    TEXT NOT NULL CHECK (length(trim(internal_note)) >= 5),   -- HIDDEN from authors
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

-- A reviewer-approved APC waiver (event row): the APC the author pays is reduced by waived_usd.
CREATE SEQUENCE apr_seq START 1;
CREATE TABLE apc_reductions (
  reduction_id     VARCHAR(12) PRIMARY KEY,      -- APR-00001
  manuscript_id    VARCHAR(16) NOT NULL REFERENCES manuscripts,
  case_id          TEXT NOT NULL UNIQUE REFERENCES review_cases,
  journal_code     VARCHAR(8) NOT NULL REFERENCES journals,
  apc_usd          NUMERIC(10,2) NOT NULL,
  covered_usd      NUMERIC(10,2) NOT NULL,
  waived_usd       NUMERIC(10,2) NOT NULL CHECK (waived_usd > 0),
  author_pays_usd  NUMERIC(10,2) NOT NULL CHECK (author_pays_usd >= 0),
  created_at       TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- An editor-approved exception to an INCOMPLETE submission check (event row): the transfer may then be proposed.
CREATE SEQUENCE exc_seq START 1;
CREATE TABLE statement_exceptions (
  exception_id   VARCHAR(12) PRIMARY KEY,        -- EXC-00001
  check_id       VARCHAR(12) NOT NULL UNIQUE REFERENCES submission_checks,
  case_id        TEXT NOT NULL UNIQUE REFERENCES review_cases,
  manuscript_id  VARCHAR(16) NOT NULL REFERENCES manuscripts,
  journal_code   VARCHAR(8)  NOT NULL REFERENCES journals,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- Audit trail: one row per consequential state change, written by triggers so it cannot be bypassed.
-- Operations read it by SQL; no MCP tool exposes it.
CREATE TABLE agent_audit (
  id         SERIAL PRIMARY KEY,
  at         TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  author_id  VARCHAR(12),
  actor      VARCHAR(12),            -- reviewer id for REVIEWER_VERIFY / CASE_DECIDED
  action     VARCHAR(30) NOT NULL,   -- VERIFY, REVIEWER_VERIFY, TRANSFER_PROPOSED, TRANSFERRED, SUBMISSION_CHECKED,
                                     -- CASE_OPENED, CASE_DECIDED, APC_REDUCED, STATEMENTS_EXCEPTION
  ref        TEXT,
  detail     TEXT
);

-- =====================================================================
-- RULES
-- =====================================================================

-- Identity: a token is valid for its AUTHOR until it expires (a reviewer token is not an author token).
CREATE OR REPLACE FUNCTION session_author(p_token TEXT) RETURNS VARCHAR AS $$
  SELECT author_id FROM author_sessions
   WHERE session_token = p_token AND role = 'AUTHOR' AND expires_at > clock_timestamp();
$$ LANGUAGE sql STABLE;

-- Reviewer identity: one row always - the reviewer when the token is a valid REVIEWER token of an active reviewer.
CREATE OR REPLACE FUNCTION session_reviewer(p_token TEXT)
RETURNS TABLE (reviewer_id VARCHAR, team VARCHAR, approval_limit NUMERIC, display_name VARCHAR) AS $$
BEGIN
  RETURN QUERY
    SELECT r.reviewer_id, r.team, r.approval_limit, r.display_name
      FROM (SELECT 1) one
      LEFT JOIN author_sessions s ON s.session_token = trim(coalesce(p_token, '')) AND s.role = 'REVIEWER'
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
  SELECT upper(regexp_replace(coalesce(p, ''), '[[:space:]$,]', '', 'g'))
$$ LANGUAGE sql IMMUTABLE;

-- PUB-7001 / pub7001 / PUB 7001 / 7001 -> PUB-7001
CREATE OR REPLACE FUNCTION norm_staff_id(p TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN d ~ '^[0-9]{4}$' THEN 'PUB-' || d ELSE upper(trim(coalesce(p, ''))) END
    FROM (SELECT regexp_replace(upper(trim(coalesce(p, ''))), '^PUB[[:space:]-]*', '') AS d) x
$$ LANGUAGE sql IMMUTABLE;

-- What a reviewer sees instead of the full name (minimum necessary): 'Dr. Maya Okafor' -> 'Dr. Maya O.'
CREATE OR REPLACE FUNCTION author_display(p_author TEXT) RETURNS TEXT AS $$
  SELECT regexp_replace(a.full_name, '[[:space:]]+([^[:space:]])[^[:space:]]*$', ' \1.') FROM authors a WHERE a.author_id = p_author
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Reviewer identity: staff id + staff code -> REVIEWER session (same token mechanism, role checked everywhere).
-- ---------------------------------------------------------------------
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
        JOIN author_sessions se ON se.reviewer_id = r.reviewer_id AND se.role = 'REVIEWER' AND se.expires_at > clock_timestamp()
       WHERE r.reviewer_id = norm_staff_id(p_staff) AND r.one_time_code = trim(coalesce(p_code, '')) AND r.active
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Rule: APC price and institutional agreement coverage (all arithmetic here).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apc_quote(p_author TEXT, p_journal TEXT)
RETURNS TABLE (journal_code VARCHAR, journal_title VARCHAR, oa_model VARCHAR, apc_usd NUMERIC,
               agreement_name VARCHAR, coverage_pct INTEGER, covered_usd NUMERIC,
               author_pays_usd NUMERIC, coverage_note TEXT) AS $$
  WITH j AS (SELECT * FROM journals WHERE journals.journal_code = upper(p_journal) AND is_active),
       a AS (SELECT ag.* FROM authors au
               JOIN oa_agreements ag ON ag.institution_id = au.institution_id
               JOIN agreement_journals aj ON aj.agreement_id = ag.agreement_id
              WHERE au.author_id = p_author AND aj.journal_code = upper(p_journal)
                AND current_date BETWEEN ag.valid_from AND ag.valid_to
              LIMIT 1),
       c AS (SELECT CASE WHEN a.agreement_id IS NULL THEN 0
                         WHEN a.apc_budget_usd - a.apc_spent_usd < j.apc_usd * a.coverage_pct / 100.0 THEN 0
                         ELSE a.coverage_pct END AS pct,
                    CASE WHEN a.agreement_id IS NULL THEN 'Not covered: your institution has no active agreement that includes this journal.'
                         WHEN a.apc_budget_usd - a.apc_spent_usd < j.apc_usd * a.coverage_pct / 100.0
                           THEN 'Not covered: your institution''s agreement budget for this year is used up.'
                         ELSE 'Covered by your institution''s ' || a.model || ' agreement.' END AS note,
                    a.name AS aname
               FROM j LEFT JOIN a ON TRUE)
  SELECT j.journal_code, j.title, j.oa_model, j.apc_usd, c.aname, c.pct,
         round(j.apc_usd * c.pct / 100.0, 2), round(j.apc_usd * (100 - c.pct) / 100.0, 2), c.note
    FROM j, c;
$$ LANGUAGE sql STABLE;

-- What the author still owes on a manuscript at its current journal: the quote minus any approved APC waivers.
CREATE OR REPLACE FUNCTION manuscript_apc_due(p_manuscript TEXT) RETURNS NUMERIC AS $$
  SELECT greatest(q.author_pays_usd - coalesce((SELECT sum(r.waived_usd) FROM apc_reductions r
                                                 WHERE r.manuscript_id = m.manuscript_id), 0), 0)
    FROM manuscripts m CROSS JOIN LATERAL apc_quote(m.corresponding_author_id, m.journal_code) q
   WHERE m.manuscript_id = p_manuscript
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Submission statements: the target journal's policy vs the author's statements.
-- ---------------------------------------------------------------------
-- 'missing_items: DATA_AVAILABILITY (incomplete), competing interests; Ethics' -> {COMPETING_INTERESTS,DATA_AVAILABILITY,ETHICS_APPROVAL}
CREATE OR REPLACE FUNCTION norm_items(p TEXT) RETURNS TEXT[] AS $$
  SELECT coalesce(array_agg(DISTINCT y ORDER BY y), '{}')
    FROM (SELECT CASE x WHEN 'DATA' THEN 'DATA_AVAILABILITY' WHEN 'DATA_AVAILABILITY_STATEMENT' THEN 'DATA_AVAILABILITY'
                        WHEN 'ETHICS' THEN 'ETHICS_APPROVAL' WHEN 'ETHICS_STATEMENT' THEN 'ETHICS_APPROVAL'
                        WHEN 'COMPETING_INTEREST' THEN 'COMPETING_INTERESTS' WHEN 'CONFLICT_OF_INTEREST' THEN 'COMPETING_INTERESTS'
                        WHEN 'CONFLICTS_OF_INTEREST' THEN 'COMPETING_INTERESTS' WHEN 'AUTHOR_CONTRIBUTION' THEN 'AUTHOR_CONTRIBUTIONS'
                        WHEN 'CONTRIBUTIONS' THEN 'AUTHOR_CONTRIBUTIONS' WHEN 'FUNDING_STATEMENT' THEN 'FUNDING'
                        ELSE x END AS y
            FROM (SELECT upper(regexp_replace(btrim(regexp_replace(w, '[[:space:]]*[(:].*$', '')), '[[:space:]-]+', '_', 'g')) AS x
                    FROM regexp_split_to_table(regexp_replace(coalesce(p, ''), '^[[:space:]]*missing[_ ]items[[:space:]]*:', '', 'i'),
                                               '[,;|' || chr(10) || ']') w) s
           WHERE x <> '' AND x NOT IN ('NONE', 'N/A', 'NA', 'NIL')) t
$$ LANGUAGE sql IMMUTABLE;

-- The assessment: agent items that exist in the journal's policy (validated) + MANDATORY statements the deterministic
-- presence check cannot find -> mandatory / recommended missing -> COMPLETE or INCOMPLETE. One row for an active journal.
CREATE OR REPLACE FUNCTION submission_assessment(p_journal TEXT, p_text TEXT, p_items TEXT)
RETURNS TABLE (policy_set TEXT, agent_items TEXT, ignored_items TEXT, rule_items TEXT, mandatory_missing TEXT,
               recommended_missing TEXT, result TEXT) AS $$
  WITH j AS (SELECT jj.* FROM journals jj WHERE jj.journal_code = upper(trim(coalesce(p_journal, ''))) AND jj.is_active),
       pol AS (SELECT sp.* FROM submission_policies sp JOIN j ON sp.policy_set = j.policy_set),
       ai AS (SELECT unnest(norm_items(p_items)) AS it),
       valid AS (SELECT pol.statement, pol.requirement, pol.sort_order FROM pol JOIN ai ON ai.it = pol.statement),
       rul AS (SELECT pol.statement, pol.requirement, pol.sort_order FROM pol
                WHERE pol.requirement = 'MANDATORY' AND coalesce(p_text, '') !~* pol.keyword_pattern),
       miss AS (SELECT * FROM valid UNION SELECT * FROM rul)
  SELECT (SELECT j.policy_set::text FROM j),
         (SELECT string_agg(v.statement, ', ' ORDER BY v.sort_order) FROM valid v),
         (SELECT string_agg(a.it, ', ' ORDER BY a.it) FROM ai a WHERE a.it NOT IN (SELECT pol.statement FROM pol)),
         (SELECT string_agg(r.statement, ', ' ORDER BY r.sort_order) FROM rul r),
         (SELECT string_agg(m.statement, ', ' ORDER BY m.sort_order) FROM miss m WHERE m.requirement = 'MANDATORY'),
         (SELECT string_agg(m.statement, ', ' ORDER BY m.sort_order) FROM miss m WHERE m.requirement = 'RECOMMENDED'),
         CASE WHEN EXISTS (SELECT 1 FROM miss m WHERE m.requirement = 'MANDATORY') THEN 'INCOMPLETE' ELSE 'COMPLETE' END
   WHERE EXISTS (SELECT 1 FROM j);
$$ LANGUAGE sql STABLE;

-- Gate used by transfer_eval: OK (a COMPLETE check in the last 24 hours, or an editor's exception in the last 30 days),
-- CHECK_REQUIRED (no recent check) or INCOMPLETE:<mandatory items>.
CREATE OR REPLACE FUNCTION statements_status(p_manuscript TEXT, p_journal TEXT) RETURNS TEXT AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM statement_exceptions e
                            WHERE e.manuscript_id = p_manuscript AND e.journal_code = p_journal
                              AND e.created_at > clock_timestamp() - INTERVAL '30 days') THEN 'OK'
              WHEN c.check_id IS NULL THEN 'CHECK_REQUIRED'
              WHEN c.result = 'COMPLETE' THEN 'OK'
              ELSE 'INCOMPLETE:' || coalesce(c.mandatory_missing, '') END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT sc.* FROM submission_checks sc
                        WHERE sc.manuscript_id = p_manuscript AND sc.journal_code = p_journal
                          AND sc.created_at > clock_timestamp() - INTERVAL '24 hours'
                        ORDER BY sc.created_at DESC, sc.check_id DESC LIMIT 1) c ON TRUE
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Rule: may this author transfer this manuscript to this journal?
-- Returns one row: ok + a reason the assistant can explain verbatim.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_eval(p_author TEXT, p_manuscript TEXT, p_journal TEXT)
RETURNS TABLE (ok BOOLEAN, reason TEXT) AS $$
DECLARE m manuscripts; j journals; v_st TEXT;
BEGIN
  IF p_author IS NULL THEN
    RETURN QUERY SELECT FALSE, 'SESSION_INVALID: identity not verified or session expired. Verify again.'; RETURN;
  END IF;
  SELECT * INTO m FROM manuscripts WHERE manuscript_id = upper(p_manuscript) AND corresponding_author_id = p_author;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'NOT_FOUND: no manuscript with that id for this author.'; RETURN;
  END IF;
  IF m.integrity_hold THEN
    RETURN QUERY SELECT FALSE, 'ON_HOLD: this manuscript is with the editorial office and cannot be transferred right now. The editorial office will contact the author.'; RETURN;
  END IF;
  IF m.status <> 'REJECTED_TRANSFER_ELIGIBLE' THEN
    RETURN QUERY SELECT FALSE, 'NOT_ELIGIBLE: only manuscripts that received a transfer offer can be transferred. Current status: ' || m.status || '.'; RETURN;
  END IF;
  SELECT * INTO j FROM journals WHERE journal_code = upper(p_journal) AND is_active;
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, 'JOURNAL_UNKNOWN: no active journal with code ' || coalesce(p_journal,'') || '.'; RETURN;
  END IF;
  IF j.journal_code = m.journal_code THEN
    RETURN QUERY SELECT FALSE, 'SAME_JOURNAL: the manuscript is already at ' || j.title || '.'; RETURN;
  END IF;
  IF NOT j.accepts_transfers THEN
    RETURN QUERY SELECT FALSE, 'CLOSED_TO_TRANSFERS: ' || j.title || ' does not accept transferred manuscripts.'; RETURN;
  END IF;
  IF m.word_count > j.word_limit THEN
    RETURN QUERY SELECT FALSE, 'OVER_WORD_LIMIT: the manuscript has ' || m.word_count || ' words; ' || j.title
                               || ' accepts up to ' || j.word_limit || '. Shorten it or choose another journal.'; RETURN;
  END IF;
  v_st := statements_status(m.manuscript_id, j.journal_code);
  IF v_st = 'CHECK_REQUIRED' THEN
    RETURN QUERY SELECT FALSE, 'CHECK_REQUIRED: the manuscript''s submission statements have not been checked against '
                               || j.title || '''s policy yet. Run the submission check, then propose the transfer again.'; RETURN;
  END IF;
  IF v_st LIKE 'INCOMPLETE:%' THEN
    RETURN QUERY SELECT FALSE, 'STATEMENTS_INCOMPLETE: ' || j.title || ' requires these statements, which are missing or incomplete: '
                               || substr(v_st, 12) || '. Add them and run the submission check again, or ask the editorial office '
                               || 'for an exception (STATEMENTS_EXCEPTION).'; RETURN;
  END IF;
  RETURN QUERY SELECT TRUE, 'ELIGIBLE'::TEXT;
END $$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Side effect: a confirmed transfer moves the manuscript atomically.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_transfer() RETURNS TRIGGER AS $$
BEGIN
  UPDATE manuscripts
     SET transferred_from = NEW.from_journal, journal_code = NEW.to_journal, status = 'SUBMITTED',
         status_detail = 'Transferred from ' || NEW.from_journal || '; received by the new journal''s editorial office.',
         decision_summary = NULL, last_updated = now()
   WHERE manuscript_id = NEW.manuscript_id;
  UPDATE pending_actions SET status = 'EXECUTED' WHERE action_id = NEW.action_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_transfer_apply AFTER INSERT ON transfers FOR EACH ROW EXECUTE FUNCTION apply_transfer();

-- ---------------------------------------------------------------------
-- Read models used by the MCP tools (one row of status even when empty).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION verify_result(p_orcid TEXT, p_code TEXT)
RETURNS TABLE (status TEXT, session_token TEXT, author_name VARCHAR, institution VARCHAR, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN s.session_token IS NULL THEN 'NOT_VERIFIED' ELSE 'VERIFIED' END,
         s.session_token, s.full_name, s.inst, s.expires_at
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (
      SELECT se.session_token, a.full_name, i.name AS inst, se.expires_at
        FROM authors a JOIN institutions i USING (institution_id)
        JOIN author_sessions se ON se.author_id = a.author_id AND se.role = 'AUTHOR' AND se.expires_at > clock_timestamp()
       WHERE a.orcid = trim(p_orcid) AND a.verification_code = trim(p_code)
       ORDER BY se.created_at DESC LIMIT 1) s ON TRUE;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_manuscripts(p_token TEXT)
RETURNS TABLE (session_status TEXT, manuscript_id VARCHAR, title VARCHAR, journal VARCHAR,
               status VARCHAR, status_detail TEXT, submitted_on DATE, last_updated TIMESTAMP) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         m.manuscript_id, m.title, j.title, m.status,
         CASE WHEN m.integrity_hold THEN 'With the editorial office.' ELSE m.status_detail END,
         m.submitted_on, m.last_updated
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN manuscripts m ON m.corresponding_author_id = s.aid
    LEFT JOIN journals j ON j.journal_code = m.journal_code
   ORDER BY m.submitted_on DESC;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION manuscript_detail(p_token TEXT, p_manuscript TEXT)
RETURNS TABLE (lookup_status TEXT, manuscript_id VARCHAR, title VARCHAR, journal_code VARCHAR, journal VARCHAR,
               status VARCHAR, status_detail TEXT, decision_summary TEXT, article_type VARCHAR,
               word_count INTEGER, keywords TEXT, abstract TEXT, transferred_from VARCHAR, declarations TEXT,
               apc_waived_usd NUMERIC, apc_due_usd NUMERIC) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' WHEN m.manuscript_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         m.manuscript_id, m.title, m.journal_code, j.title, m.status,
         CASE WHEN m.integrity_hold THEN 'With the editorial office.' ELSE m.status_detail END,
         CASE WHEN m.integrity_hold THEN NULL ELSE m.decision_summary END,
         m.article_type, m.word_count, m.keywords, m.abstract, m.transferred_from,
         CASE WHEN m.integrity_hold THEN NULL ELSE m.declarations END,
         CASE WHEN m.manuscript_id IS NOT NULL THEN
           (SELECT coalesce(sum(r.waived_usd), 0) FROM apc_reductions r WHERE r.manuscript_id = m.manuscript_id) END,
         CASE WHEN m.status = 'ACCEPTED' AND NOT m.integrity_hold THEN manuscript_apc_due(m.manuscript_id) END
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN manuscripts m ON m.corresponding_author_id = s.aid AND m.manuscript_id = upper(trim(p_manuscript))
    LEFT JOIN journals j ON j.journal_code = m.journal_code;
$$ LANGUAGE sql STABLE;

-- The editor's decision letter + anonymous reviewer comments for one of the author's own manuscripts.
-- NO_COMMENTS when there are none (also for a manuscript under an editorial hold - never disclosed).
CREATE OR REPLACE FUNCTION my_review_comments(p_token TEXT, p_manuscript TEXT)
RETURNS TABLE (lookup_status TEXT, manuscript_id VARCHAR, manuscript_title VARCHAR, status VARCHAR, comment_ref VARCHAR,
               source TEXT, comment_text TEXT) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' WHEN m.manuscript_id IS NULL THEN 'NOT_FOUND'
              WHEN c.comment_ref IS NULL THEN 'NO_COMMENTS' ELSE 'OK' END,
         m.manuscript_id, m.title, m.status, c.comment_ref,
         CASE c.source WHEN 'EDITOR' THEN 'Editor' WHEN 'REVIEWER_1' THEN 'Reviewer 1' WHEN 'REVIEWER_2' THEN 'Reviewer 2'
                       WHEN 'REVIEWER_3' THEN 'Reviewer 3' END,
         c.comment_text
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN manuscripts m ON m.corresponding_author_id = s.aid AND m.manuscript_id = upper(trim(coalesce(p_manuscript, '')))
    LEFT JOIN review_comments c ON c.manuscript_id = m.manuscript_id AND NOT m.integrity_hold
   ORDER BY c.source, c.comment_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apc_quote_for_session(p_token TEXT, p_journal TEXT)
RETURNS TABLE (lookup_status TEXT, journal_code VARCHAR, journal_title VARCHAR, oa_model VARCHAR, apc_usd NUMERIC,
               agreement_name VARCHAR, coverage_pct INTEGER, covered_usd NUMERIC, author_pays_usd NUMERIC, coverage_note TEXT) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' WHEN q.journal_code IS NULL THEN 'JOURNAL_UNKNOWN' ELSE 'OK' END,
         q.journal_code, q.journal_title, q.oa_model, q.apc_usd, q.agreement_name, q.coverage_pct,
         q.covered_usd, q.author_pays_usd, q.coverage_note
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN LATERAL apc_quote(s.aid, trim(p_journal)) q ON s.aid IS NOT NULL;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION propose_transfer_result(p_token TEXT, p_manuscript TEXT, p_journal TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, action_id TEXT, manuscript_id VARCHAR, target_journal VARCHAR,
               apc_usd NUMERIC, coverage_pct INTEGER, author_pays_usd NUMERIC, expires_at TIMESTAMP) AS $$
  SELECT CASE WHEN p.action_id IS NOT NULL THEN 'PROPOSED' ELSE 'NOT_PROPOSED' END,
         CASE WHEN p.action_id IS NOT NULL THEN 'Awaiting the author''s explicit confirmation. Nothing has changed yet.' ELSE e.reason END,
         p.action_id, p.manuscript_id, j.title, p.apc_usd, p.coverage_pct, p.author_pays_usd, p.expires_at
    FROM (SELECT session_author(p_token) AS aid) s
    CROSS JOIN LATERAL transfer_eval(s.aid, trim(p_manuscript), trim(p_journal)) e
    LEFT JOIN LATERAL (
      SELECT pa.* FROM pending_actions pa
       WHERE pa.author_id = s.aid AND pa.manuscript_id = upper(trim(p_manuscript))
         AND pa.target_journal_code = upper(trim(p_journal)) AND pa.status = 'PENDING'
         AND pa.expires_at > clock_timestamp() AND e.ok
       ORDER BY pa.created_at DESC LIMIT 1) p ON TRUE
    LEFT JOIN journals j ON j.journal_code = p.target_journal_code;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION confirm_transfer_result(p_token TEXT, p_action TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, manuscript_id VARCHAR, from_journal VARCHAR, to_journal VARCHAR,
               new_status VARCHAR, transferred_at TIMESTAMP) AS $$
  SELECT CASE WHEN t.transfer_id IS NOT NULL THEN 'EXECUTED' ELSE 'NOT_EXECUTED' END,
         CASE WHEN t.transfer_id IS NOT NULL THEN 'Transfer completed.'
              WHEN s.aid IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN pa.action_id IS NULL THEN 'ACTION_NOT_FOUND: no pending transfer with that id for this author.'
              WHEN pa.expires_at <= clock_timestamp() THEN 'EXPIRED: the proposal expired. Propose the transfer again.'
              ELSE (SELECT e.reason FROM transfer_eval(s.aid, pa.manuscript_id, pa.target_journal_code) e) END,
         t.manuscript_id, fj.title, tj.title, m.status, t.transferred_at
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.author_id = s.aid
    LEFT JOIN transfers t ON t.action_id = pa.action_id
    LEFT JOIN manuscripts m ON m.manuscript_id = t.manuscript_id
    LEFT JOIN journals fj ON fj.journal_code = t.from_journal
    LEFT JOIN journals tj ON tj.journal_code = t.to_journal;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Submission check: guarded write-row + readback.
-- ---------------------------------------------------------------------
-- A check is recorded ONLY for the author's own manuscript (not under an editorial hold) and an active journal. The
-- statements checked = the declarations on file + anything the author added in the conversation.
CREATE OR REPLACE FUNCTION submission_check_row(p_token TEXT, p_manuscript TEXT, p_journal TEXT, p_statements TEXT,
                                                p_items TEXT, p_notes TEXT)
RETURNS TABLE (author_id VARCHAR, manuscript_id VARCHAR, journal_code VARCHAR, statements TEXT, agent_notes TEXT,
               agent_items TEXT, ignored_items TEXT, rule_items TEXT, mandatory_missing TEXT, recommended_missing TEXT,
               result TEXT) AS $$
  SELECT s.aid, m.manuscript_id, j.journal_code, x.txt, left(coalesce(p_notes, ''), 6000), a.agent_items, a.ignored_items,
         a.rule_items, a.mandatory_missing, a.recommended_missing, a.result
    FROM (SELECT session_author(p_token) AS aid) s
    JOIN manuscripts m ON m.manuscript_id = upper(trim(coalesce(p_manuscript, ''))) AND m.corresponding_author_id = s.aid
                      AND NOT m.integrity_hold
    JOIN journals j ON j.journal_code = upper(trim(coalesce(p_journal, ''))) AND j.is_active
    CROSS JOIN LATERAL (SELECT concat_ws(chr(10), m.declarations,
                                         nullif(left(trim(coalesce(p_statements, '')), 4000), '')) AS txt) x
    CROSS JOIN LATERAL submission_assessment(j.journal_code, x.txt, p_items) a;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION submission_check_result(p_token TEXT, p_manuscript TEXT, p_journal TEXT)
RETURNS TABLE (outcome TEXT, reason_code TEXT, reason TEXT, check_id VARCHAR, manuscript_id VARCHAR, journal_code VARCHAR,
               journal TEXT, result VARCHAR, mandatory_missing TEXT, recommended_missing TEXT, policy_wording TEXT,
               next_step TEXT, checked_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.check_id IS NOT NULL THEN 'RECORDED' ELSE 'NOT_RECORDED' END,
         CASE WHEN c.check_id IS NOT NULL THEN c.result
              WHEN s.aid IS NULL THEN 'SESSION_INVALID'
              WHEN m.manuscript_id IS NULL THEN 'NOT_FOUND'
              WHEN m.integrity_hold THEN 'ON_HOLD'
              WHEN j.journal_code IS NULL THEN 'JOURNAL_UNKNOWN' ELSE 'NOT_RECORDED' END,
         CASE WHEN c.check_id IS NOT NULL AND c.result = 'COMPLETE'
                THEN 'The statements meet ' || j.title || '''s mandatory requirements.'
              WHEN c.check_id IS NOT NULL
                THEN 'Mandatory statements are missing or incomplete for ' || j.title || ': ' || c.mandatory_missing || '.'
              WHEN s.aid IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN m.manuscript_id IS NULL THEN 'NOT_FOUND: no manuscript with that id for this author.'
              WHEN m.integrity_hold THEN 'ON_HOLD: this manuscript is with the editorial office; the editorial office will contact the author.'
              WHEN j.journal_code IS NULL THEN 'JOURNAL_UNKNOWN: no active journal with code ' || coalesce(p_journal, '') || '.'
              ELSE 'NOT_RECORDED: the check could not be recorded. Try again.' END,
         c.check_id, c.manuscript_id, c.journal_code, j.title::text, c.result, c.mandatory_missing, c.recommended_missing,
         (SELECT string_agg(sp.statement || ' (' || sp.requirement || '): ' || sp.standard_wording, ' | ' ORDER BY sp.sort_order)
            FROM submission_policies sp
           WHERE sp.policy_set = j.policy_set
             AND sp.statement = ANY (string_to_array(concat_ws(', ', c.mandatory_missing, c.recommended_missing), ', '))),
         CASE WHEN c.check_id IS NULL THEN NULL
              WHEN c.result = 'COMPLETE' THEN 'The transfer can now be proposed with propose_transfer.'
              ELSE 'The transfer stays blocked until the mandatory statements are added. The author can add them and check '
                   || 'again, or ask the editorial office for an exception (open_review_case STATEMENTS_EXCEPTION).' END,
         c.created_at
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN manuscripts m ON m.manuscript_id = upper(trim(coalesce(p_manuscript, ''))) AND m.corresponding_author_id = s.aid
    LEFT JOIN journals j ON j.journal_code = upper(trim(coalesce(p_journal, ''))) AND j.is_active
    LEFT JOIN LATERAL (SELECT sc.* FROM submission_checks sc
                        WHERE sc.author_id = s.aid AND sc.manuscript_id = m.manuscript_id AND sc.journal_code = j.journal_code
                          AND sc.created_at > clock_timestamp() - INTERVAL '10 minutes'
                        ORDER BY sc.created_at DESC, sc.check_id DESC LIMIT 1) c ON TRUE;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Human-owned requests -> routed to a team by the table, never decided by the LLM. A case may PARK an action
-- (APC waiver, statements exception) that runs only when a reviewer of that team approves it.
-- ---------------------------------------------------------------------
-- What a new case parks for approval (derived in SQL, never chosen by the model):
--   APC_WAIVER           + an ACCEPTED manuscript of the author with something still to pay -> APC_WAIVER:<manuscript>,
--                          requested = what the author pays now (manuscript_apc_due)
--   STATEMENTS_EXCEPTION + the manuscript's latest submission check is INCOMPLETE -> ACCEPT_STATEMENTS:<check_id>
--                          (no such check -> NO_INCOMPLETE_CHECK, nothing is opened)
--   anything else        -> no parked action (the team completes it).
CREATE OR REPLACE FUNCTION case_parking(p_author TEXT, p_manuscript TEXT, p_type TEXT)
RETURNS TABLE (ok BOOLEAN, reason_code TEXT, parked_action TEXT, requested_amount NUMERIC) AS $$
#variable_conflict use_column
DECLARE v_type TEXT := upper(trim(coalesce(p_type, ''))); v_ms TEXT := upper(trim(coalesce(p_manuscript, '')));
        m manuscripts; c submission_checks; v_due NUMERIC;
BEGIN
  ok := TRUE; reason_code := 'OK';
  IF v_ms <> '' THEN
    SELECT * INTO m FROM manuscripts x WHERE x.manuscript_id = v_ms AND x.corresponding_author_id = p_author;
  END IF;
  IF v_type = 'APC_WAIVER' THEN
    IF m.manuscript_id IS NOT NULL AND m.status = 'ACCEPTED' THEN
      v_due := manuscript_apc_due(m.manuscript_id);
      IF v_due > 0 THEN parked_action := 'APC_WAIVER:' || m.manuscript_id; requested_amount := v_due; END IF;
    END IF;
  ELSIF v_type = 'STATEMENTS_EXCEPTION' THEN
    SELECT * INTO c FROM submission_checks x WHERE x.manuscript_id = m.manuscript_id AND x.author_id = p_author
     ORDER BY x.created_at DESC, x.check_id DESC LIMIT 1;
    IF c.check_id IS NULL OR c.result <> 'INCOMPLETE'
       OR EXISTS (SELECT 1 FROM statement_exceptions e WHERE e.check_id = c.check_id) THEN
      ok := FALSE; reason_code := 'NO_INCOMPLETE_CHECK'; RETURN NEXT; RETURN;
    END IF;
    parked_action := 'ACCEPT_STATEMENTS:' || c.check_id;
  END IF;
  RETURN NEXT;
END $$ LANGUAGE plpgsql STABLE;

-- Every case gets its reply-due time from the routing table (also cases opened by seeds).
CREATE OR REPLACE FUNCTION case_defaults() RETURNS TRIGGER AS $$
DECLARE t review_teams;
BEGIN
  SELECT * INTO t FROM review_teams WHERE request_type = NEW.request_type;
  NEW.sla_due_at := coalesce(NEW.sla_due_at, add_business_days(NEW.created_at::date, t.sla_days) + NEW.created_at::time);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_case_defaults BEFORE INSERT ON review_cases FOR EACH ROW EXECUTE FUNCTION case_defaults();

CREATE OR REPLACE FUNCTION review_case_result(p_token TEXT, p_manuscript TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, reply_by DATE, status VARCHAR, requested_amount NUMERIC,
               if_approved TEXT, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NULL THEN 'NOT_OPENED'
              WHEN c.created_at > clock_timestamp() - INTERVAL '10 minutes' THEN 'CASE_OPENED' ELSE 'ALREADY_OPEN' END,
         CASE WHEN c.case_id IS NOT NULL AND c.created_at > clock_timestamp() - INTERVAL '10 minutes'
                THEN 'A person on the assigned team will review and reply. The assistant has not decided anything.'
              WHEN c.case_id IS NOT NULL
                THEN 'This request is already open with the assigned team, so no new case was opened. A person will decide.'
              WHEN s.aid IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN t0.request_type IS NULL
                THEN 'BAD_REQUEST_TYPE: use APC_WAIVER, DECISION_APPEAL, AUTHORSHIP_CHANGE, INTEGRITY_QUERY, STATEMENTS_EXCEPTION or OTHER.'
              WHEN coalesce(trim(p_manuscript), '') <> ''
                   AND NOT EXISTS (SELECT 1 FROM manuscripts mm WHERE mm.manuscript_id = upper(trim(p_manuscript))
                                                                  AND mm.corresponding_author_id = s.aid)
                THEN 'NOT_FOUND: no manuscript with that id for this author.'
              WHEN NOT pk.ok THEN 'NO_INCOMPLETE_CHECK: there is no incomplete submission check for this manuscript, so there '
                   || 'is nothing for the editorial office to make an exception for. Run the submission check first.'
              ELSE 'NOT_OPENED: the case could not be recorded. Try again.' END,
         c.case_id, c.request_type, t.team, t.sla_days, c.sla_due_at::date, c.status, c.requested_amount,
         CASE split_part(coalesce(c.parked_action, ''), ':', 1)
              WHEN 'APC_WAIVER' THEN 'If a person approves it, the article processing charge for ' || split_part(c.parked_action, ':', 2)
                   || ' is reduced by the approved amount.'
              WHEN 'ACCEPT_STATEMENTS' THEN 'If the editorial office approves it, the transfer can go ahead with the statements as they are.' END,
         c.created_at
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN review_teams t0 ON t0.request_type = upper(trim(p_type)) AND t0.author_openable
    LEFT JOIN LATERAL (SELECT * FROM case_parking(s.aid, p_manuscript, p_type)) pk ON TRUE
    LEFT JOIN LATERAL (
      SELECT rc.* FROM review_cases rc
       WHERE rc.author_id = s.aid AND rc.request_type = upper(trim(p_type)) AND t0.request_type IS NOT NULL
         AND coalesce(rc.manuscript_id,'') = upper(trim(coalesce(p_manuscript,'')))
         AND (rc.created_at > clock_timestamp() - INTERVAL '10 minutes'
              OR (rc.status = 'OPEN' AND pk.parked_action IS NOT NULL AND rc.parked_action = pk.parked_action))
       ORDER BY rc.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN review_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- The author's own cases: status + the author-safe outcome once a person decided. Never the internal note, the AI
-- brief, the parked action or who decided.
CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_id TEXT, manuscript_id VARCHAR, request_type VARCHAR, assigned_team VARCHAR,
               status VARCHAR, requested_amount NUMERIC, approved_amount NUMERIC, customer_message TEXT, reply_by DATE,
               decided_on DATE, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_id, c.manuscript_id, c.request_type, t.team, c.status, c.requested_amount, c.approved_amount,
         c.customer_message, c.sla_due_at::date, c.decided_at::date, c.created_at
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN review_cases c ON c.author_id = s.aid
    LEFT JOIN review_teams t ON t.request_type = c.request_type
   ORDER BY c.created_at DESC;
$$ LANGUAGE sql STABLE;

-- Journal search for the journal-match agent: keywords only, no author data.
CREATE OR REPLACE FUNCTION search_journals(p_keywords TEXT, p_subject TEXT)
RETURNS TABLE (journal_code VARCHAR, title VARCHAR, subject_area VARCHAR, oa_model VARCHAR, apc_usd NUMERIC,
               word_limit INTEGER, median_days_to_first_decision INTEGER, aims_scope TEXT, relevance REAL) AS $$
  SELECT j.journal_code, j.title, j.subject_area, j.oa_model, j.apc_usd, j.word_limit,
         j.median_days_to_first_decision, j.aims_scope,
         ts_rank(j.search, q) + CASE WHEN coalesce(p_subject,'') <> '' AND j.subject_area ILIKE '%' || p_subject || '%' THEN 0.2 ELSE 0 END
    FROM journals j,
         websearch_to_tsquery('english',
           regexp_replace(trim(both ' ,;' from coalesce(p_keywords,'')), '\s*[,;]\s*', ' or ', 'g')) q
   WHERE j.is_active AND j.accepts_transfers AND j.search @@ q
   ORDER BY 9 DESC LIMIT 8;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Guarded writes. Each MCP write tool is  INSERT ... SELECT * FROM <fn>(...);
-- the function returns a row ONLY when every rule passes, so a blocked
-- request inserts nothing. The tool then reads the outcome back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_proposal_row(p_token TEXT, p_manuscript TEXT, p_journal TEXT)
RETURNS TABLE (action_type VARCHAR, author_id VARCHAR, manuscript_id VARCHAR, target_journal_code VARCHAR,
               apc_usd NUMERIC, coverage_pct INTEGER, author_pays_usd NUMERIC) AS $$
  SELECT 'TRANSFER'::VARCHAR, s.aid, upper(trim(p_manuscript))::VARCHAR, q.journal_code, q.apc_usd, q.coverage_pct, q.author_pays_usd
    FROM (SELECT session_author(p_token) AS aid) s
    CROSS JOIN LATERAL transfer_eval(s.aid, trim(p_manuscript), trim(p_journal)) e
    CROSS JOIN LATERAL apc_quote(s.aid, trim(p_journal)) q
   WHERE e.ok
     AND NOT EXISTS (SELECT 1 FROM pending_actions pa
                      WHERE pa.author_id = s.aid AND pa.manuscript_id = upper(trim(p_manuscript))
                        AND pa.target_journal_code = q.journal_code AND pa.status = 'PENDING'
                        AND pa.expires_at > clock_timestamp());
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION transfer_confirmation_row(p_token TEXT, p_action TEXT)
RETURNS TABLE (action_id TEXT, manuscript_id VARCHAR, from_journal VARCHAR, to_journal VARCHAR) AS $$
  SELECT pa.action_id, pa.manuscript_id, m.journal_code, pa.target_journal_code
    FROM (SELECT session_author(p_token) AS aid) s
    JOIN pending_actions pa ON pa.action_id = upper(trim(p_action)) AND pa.author_id = s.aid
    JOIN manuscripts m ON m.manuscript_id = pa.manuscript_id
    CROSS JOIN LATERAL transfer_eval(s.aid, pa.manuscript_id, pa.target_journal_code) e
   WHERE pa.status = 'PENDING' AND pa.expires_at > clock_timestamp() AND e.ok;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case_row(p_token TEXT, p_manuscript TEXT, p_type TEXT, p_statement TEXT, p_brief TEXT)
RETURNS TABLE (author_id VARCHAR, manuscript_id VARCHAR, request_type VARCHAR, author_statement TEXT, agent_brief TEXT,
               requested_amount NUMERIC, parked_action TEXT) AS $$
  SELECT s.aid, NULLIF(upper(trim(coalesce(p_manuscript,''))),'')::VARCHAR, t.request_type,
         left(coalesce(p_statement,''), 4000), left(coalesce(p_brief,''), 6000), pk.requested_amount, pk.parked_action
    FROM (SELECT session_author(p_token) AS aid) s
    JOIN review_teams t ON t.request_type = upper(trim(p_type)) AND t.author_openable
    CROSS JOIN LATERAL case_parking(s.aid, p_manuscript, p_type) pk
   WHERE s.aid IS NOT NULL AND pk.ok
     AND (coalesce(trim(p_manuscript),'') = ''
          OR EXISTS (SELECT 1 FROM manuscripts m WHERE m.manuscript_id = upper(trim(p_manuscript)) AND m.corresponding_author_id = s.aid))
     AND NOT EXISTS (SELECT 1 FROM review_cases rc
                      WHERE rc.author_id = s.aid AND rc.request_type = t.request_type
                        AND coalesce(rc.manuscript_id,'') = upper(trim(coalesce(p_manuscript,'')))
                        AND rc.created_at > clock_timestamp() - INTERVAL '10 minutes')
     AND NOT EXISTS (SELECT 1 FROM review_cases rc
                      WHERE pk.parked_action IS NOT NULL AND rc.parked_action = pk.parked_action AND rc.status = 'OPEN');
$$ LANGUAGE sql STABLE;

-- =====================================================================
-- THE REVIEWER LOOP (human in the loop): queue -> case -> decide -> trigger runs the parked action
-- =====================================================================

-- The most a reviewer may approve on a case (NULL = the case carries no amount).
CREATE OR REPLACE FUNCTION case_eligible_max(p_case TEXT) RETURNS NUMERIC AS $$
  SELECT CASE split_part(coalesce(c.parked_action, ''), ':', 1)
           WHEN 'APC_WAIVER' THEN manuscript_apc_due(split_part(c.parked_action, ':', 2))
           WHEN 'ACCEPT_STATEMENTS' THEN NULL
           ELSE c.requested_amount END
    FROM review_cases c WHERE c.case_id = p_case
$$ LANGUAGE sql STABLE;

-- Facts the reviewer needs, from SQL (minimum necessary: no email, ORCID, code or full surname).
CREATE OR REPLACE FUNCTION case_facts(p_case TEXT) RETURNS TEXT AS $$
  SELECT CASE split_part(coalesce(c.parked_action, ''), ':', 1)
    WHEN 'APC_WAIVER' THEN
      'Manuscript ' || m.manuscript_id || ' "' || m.title || '" is ' || m.status || ' at ' || j.title || ' (' || j.oa_model
      || '): APC ' || usd(q.apc_usd) || '; agreement: ' || coalesce(q.agreement_name, 'none') || ' covers ' || q.coverage_pct
      || ' percent (' || q.coverage_note || '); waived so far ' || usd((SELECT coalesce(sum(r.waived_usd), 0) FROM apc_reductions r
                                                                      WHERE r.manuscript_id = m.manuscript_id))
      || '; the author pays ' || usd(manuscript_apc_due(m.manuscript_id)) || ' now; APC waivers approved for this author in the last 12 months: '
      || (SELECT count(*) FROM review_cases x WHERE x.author_id = c.author_id AND x.request_type = 'APC_WAIVER'
                                             AND x.status = 'APPROVED' AND x.decided_at > clock_timestamp() - INTERVAL '365 days')
    WHEN 'ACCEPT_STATEMENTS' THEN
      'Submission check ' || sc.check_id || ' of ' || to_char(sc.created_at, 'YYYY-MM-DD HH24:MI') || ' for manuscript '
      || sc.manuscript_id || ' -> ' || sj.title || ' (policy ' || sj.policy_set || '): result ' || sc.result
      || '; mandatory missing: ' || coalesce(sc.mandatory_missing, 'none') || '; flagged by the agent: '
      || coalesce(sc.agent_items, 'none') || '; missing per the presence check: ' || coalesce(sc.rule_items, 'none')
      || '; statements checked: ' || left(sc.statements, 1200)
    ELSE
      CASE WHEN m.manuscript_id IS NOT NULL THEN
        'Manuscript ' || m.manuscript_id || ' "' || m.title || '" at ' || j.title || ', status ' || m.status
        || CASE WHEN m.decision_summary IS NOT NULL THEN '; decision summary: ' || m.decision_summary ELSE '' END
        || CASE WHEN m.integrity_hold THEN '; an editorial hold is in place' ELSE '' END
      ELSE 'No linked manuscript.' END
    END
    FROM review_cases c
    LEFT JOIN manuscripts m ON m.manuscript_id = coalesce(c.manuscript_id,
                                 CASE WHEN c.parked_action LIKE 'APC\_WAIVER:%' THEN split_part(c.parked_action, ':', 2) END)
    LEFT JOIN journals j ON j.journal_code = m.journal_code
    LEFT JOIN LATERAL apc_quote(m.corresponding_author_id, m.journal_code) q ON c.parked_action LIKE 'APC\_WAIVER:%'
    LEFT JOIN submission_checks sc ON sc.check_id = split_part(c.parked_action, ':', 2) AND c.parked_action LIKE 'ACCEPT\_STATEMENTS:%'
    LEFT JOIN journals sj ON sj.journal_code = sc.journal_code
   WHERE c.case_id = p_case
$$ LANGUAGE sql STABLE;

-- The reviewer's team queue: OPEN cases ordered by reply-due time. Another team's cases never appear.
CREATE OR REPLACE FUNCTION review_queue(p_token TEXT)
RETURNS TABLE (status TEXT, team VARCHAR, case_id TEXT, request VARCHAR, author TEXT, manuscript_id VARCHAR, opened_on DATE,
               age_days INTEGER, reply_due DATE, sla_status TEXT, requested_amount NUMERIC) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN q.case_id IS NULL THEN 'EMPTY' ELSE 'OK' END,
         sr.team, q.case_id, q.label, q.author, q.manuscript_id, q.opened_on, q.age_days, q.reply_due, q.sla_status,
         q.requested_amount
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (
      SELECT c.case_id, t.label, author_display(c.author_id) AS author, c.manuscript_id, c.created_at::date AS opened_on,
             (current_date - c.created_at::date)::int AS age_days, c.sla_due_at::date AS reply_due,
             CASE WHEN c.sla_due_at < clock_timestamp() THEN 'OVERDUE' WHEN c.sla_due_at::date = current_date THEN 'DUE_TODAY'
                  ELSE 'ON_TRACK' END AS sla_status,
             c.requested_amount, c.sla_due_at
        FROM review_cases c JOIN review_teams t ON t.request_type = c.request_type
       WHERE sr.reviewer_id IS NOT NULL AND t.team = sr.team AND c.status = 'OPEN') q ON TRUE
   ORDER BY q.sla_due_at, q.case_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION review_case(p_token TEXT, p_case TEXT)
RETURNS TABLE (status TEXT, case_id TEXT, request VARCHAR, case_status VARCHAR, author TEXT, manuscript_id VARCHAR,
               opened_on DATE, reply_due DATE, author_statement TEXT, agent_brief TEXT, requested_amount NUMERIC,
               max_approvable NUMERIC, your_approval_limit NUMERIC, facts TEXT, options TEXT, decided_on DATE, decision TEXT) AS $$
  SELECT CASE WHEN sr.reviewer_id IS NULL THEN 'NOT_REVIEWER' WHEN c.case_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         c.case_id, t.label, c.status, author_display(c.author_id), c.manuscript_id, c.created_at::date, c.sla_due_at::date,
         c.author_statement, c.agent_brief, c.requested_amount, case_eligible_max(c.case_id),
         CASE WHEN c.case_id IS NOT NULL THEN sr.approval_limit END,
         case_facts(c.case_id),
         CASE WHEN c.case_id IS NULL THEN NULL
              WHEN c.status <> 'OPEN' THEN 'Already decided.'
              WHEN c.parked_action LIKE 'ACCEPT\_STATEMENTS:%' THEN 'APPROVE accepts the statements as they are, so the transfer '
                   || 'to that journal can go ahead; REJECT keeps the transfer blocked until the statements are added. Give an '
                   || 'internal note and a message for the author.'
              WHEN case_eligible_max(c.case_id) IS NOT NULL THEN 'APPROVE a waiver of any amount up to '
                   || usd(case_eligible_max(c.case_id))
                   || CASE WHEN sr.approval_limit IS NOT NULL AND sr.approval_limit < case_eligible_max(c.case_id)
                           THEN ' (above your ' || usd(sr.approval_limit) || ' limit it needs a senior reviewer)' ELSE '' END
                   || ', or REJECT; with an internal note and a message for the author.'
              ELSE 'APPROVE or REJECT, with an internal note and a message for the author (the team completes the request).' END,
         c.decided_at::date,
         (SELECT rd.decision || coalesce(' ' || usd(rd.approved_amount), '') FROM review_decisions rd WHERE rd.case_id = c.case_id)
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN review_cases c ON c.case_id = norm_ref(p_case) AND sr.reviewer_id IS NOT NULL
         AND c.request_type IN (SELECT x.request_type FROM review_teams x WHERE x.team = sr.team)   -- another team's case is invisible
    LEFT JOIN review_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

-- Guarded write-row for a decision. 0 rows (and a reason in decide_attempts) when blocked.
CREATE OR REPLACE FUNCTION decide_case_row(p_token TEXT, p_case TEXT, p_decision TEXT, p_amount TEXT, p_note TEXT, p_message TEXT)
RETURNS TABLE (case_id TEXT, reviewer_id VARCHAR, decision VARCHAR, approved_amount NUMERIC, internal_note TEXT,
               customer_message TEXT) AS $$
#variable_conflict use_column
DECLARE rv RECORD; c review_cases; t review_teams; v_ref TEXT := norm_ref(p_case); v_dec TEXT; v_amt NUMERIC; v_max NUMERIC;
        v_txt TEXT := norm_amount(p_amount); v_msg TEXT;
BEGIN
  SELECT * INTO rv FROM session_reviewer(p_token) x;
  IF rv.reviewer_id IS NULL THEN RETURN; END IF;                         -- readback reports NOT_REVIEWER
  SELECT * INTO c FROM review_cases x WHERE x.case_id = v_ref;
  IF NOT FOUND THEN
    INSERT INTO decide_attempts (reviewer_id, case_ref, outcome, reason_code, reason_text)
      VALUES (rv.reviewer_id, left(v_ref, 40), 'BLOCKED', 'NOT_FOUND', 'There is no case with that number.');
    RETURN;
  END IF;
  SELECT * INTO t FROM review_teams x WHERE x.request_type = c.request_type;
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
                'The approved waiver must be more than $0 and no more than ' || usd(v_max) || ' (what the author pays now).');
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
                coalesce((SELECT 'APC waiver ' || r.reduction_id || ': ' || usd(r.waived_usd) || ' waived on ' || r.manuscript_id
                                 || '; the author now pays ' || usd(manuscript_apc_due(r.manuscript_id)) || ' (APC ' || usd(r.apc_usd) || ').'
                            FROM apc_reductions r WHERE r.case_id = c.case_id),
                         (SELECT 'Statements exception ' || e.exception_id || ' for ' || e.manuscript_id || ' -> ' || e.journal_code
                                 || ': the transfer can now be proposed.'
                            FROM statement_exceptions e WHERE e.case_id = c.case_id),
                         'Case approved; no automatic action - the team completes it.')
              WHEN da.outcome = 'REJECTED' THEN 'Case rejected; nothing was executed.' END,
         CASE WHEN da.outcome IN ('APPROVED','REJECTED') THEN rd.customer_message END
    FROM (SELECT * FROM session_reviewer(p_token)) sr
    LEFT JOIN LATERAL (SELECT a.* FROM decide_attempts a WHERE a.reviewer_id = sr.reviewer_id AND a.case_ref = left(norm_ref(p_case), 40)
                        ORDER BY a.attempt_id DESC LIMIT 1) da ON TRUE
    LEFT JOIN review_cases c ON c.case_id = norm_ref(p_case)
    LEFT JOIN review_decisions rd ON rd.case_id = c.case_id;
$$ LANGUAGE sql STABLE;

-- Guarded rows the decision trigger uses to execute the parked action (the same checks every time).
CREATE OR REPLACE FUNCTION apc_reduction_row(p_manuscript TEXT, p_amount NUMERIC, p_case TEXT)
RETURNS TABLE (reduction_id TEXT, manuscript_id TEXT, case_id TEXT, journal_code TEXT, apc_usd NUMERIC, covered_usd NUMERIC,
               waived_usd NUMERIC, author_pays_usd NUMERIC) AS $$
  SELECT 'APR-' || lpad(nextval('apr_seq')::text, 5, '0'), m.manuscript_id::text, p_case, m.journal_code::text, q.apc_usd,
         q.covered_usd, p_amount, manuscript_apc_due(m.manuscript_id) - p_amount
    FROM manuscripts m CROSS JOIN LATERAL apc_quote(m.corresponding_author_id, m.journal_code) q
   WHERE m.manuscript_id = p_manuscript AND m.status = 'ACCEPTED'
     AND p_amount > 0 AND p_amount <= manuscript_apc_due(m.manuscript_id)
     AND NOT EXISTS (SELECT 1 FROM apc_reductions r WHERE r.case_id = p_case)
     AND EXISTS (SELECT 1 FROM review_cases c WHERE c.case_id = p_case AND c.parked_action = 'APC_WAIVER:' || m.manuscript_id);
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION statement_exception_row(p_check TEXT, p_case TEXT)
RETURNS TABLE (exception_id TEXT, check_id TEXT, case_id TEXT, manuscript_id TEXT, journal_code TEXT) AS $$
  SELECT 'EXC-' || lpad(nextval('exc_seq')::text, 5, '0'), sc.check_id::text, p_case, sc.manuscript_id::text, sc.journal_code::text
    FROM submission_checks sc
   WHERE sc.check_id = p_check AND sc.result = 'INCOMPLETE'
     AND NOT EXISTS (SELECT 1 FROM statement_exceptions e WHERE e.check_id = sc.check_id OR e.case_id = p_case)
     AND EXISTS (SELECT 1 FROM review_cases c WHERE c.case_id = p_case AND c.parked_action = 'ACCEPT_STATEMENTS:' || sc.check_id);
$$ LANGUAGE sql VOLATILE;

-- The decision event: case status + author message, then the parked action through the guarded rows, then audit.
CREATE OR REPLACE FUNCTION apply_review_decision() RETURNS TRIGGER AS $$
DECLARE c review_cases; v_kind TEXT; v_ref TEXT; v_done TEXT := 'nothing';
BEGIN
  SELECT * INTO c FROM review_cases WHERE case_id = NEW.case_id;
  UPDATE review_cases SET status = CASE WHEN NEW.decision = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_amount = NEW.approved_amount, customer_message = NEW.customer_message, decided_at = NEW.decided_at
   WHERE case_id = NEW.case_id;
  v_kind := split_part(coalesce(c.parked_action, ''), ':', 1);
  v_ref := split_part(coalesce(c.parked_action, ''), ':', 2);
  IF NEW.decision = 'APPROVE' AND v_kind = 'APC_WAIVER' THEN
    INSERT INTO apc_reductions (reduction_id, manuscript_id, case_id, journal_code, apc_usd, covered_usd, waived_usd, author_pays_usd)
      SELECT * FROM apc_reduction_row(v_ref, NEW.approved_amount, NEW.case_id);
    IF FOUND THEN v_done := 'APC on ' || v_ref || ' reduced by ' || usd(NEW.approved_amount); END IF;
  ELSIF NEW.decision = 'APPROVE' AND v_kind = 'ACCEPT_STATEMENTS' THEN
    INSERT INTO statement_exceptions (exception_id, check_id, case_id, manuscript_id, journal_code)
      SELECT * FROM statement_exception_row(v_ref, NEW.case_id);
    IF FOUND THEN v_done := 'statements exception for check ' || v_ref; END IF;
  END IF;
  INSERT INTO agent_audit (author_id, actor, action, ref, detail)
    VALUES (c.author_id, NEW.reviewer_id, 'CASE_DECIDED', NEW.case_id,
            NEW.decision || coalesce(' ' || usd(NEW.approved_amount), '') || '; executed: ' || v_done);
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
    INSERT INTO agent_audit (author_id, actor, action, ref, detail)
      VALUES (NULL, NEW.reviewer_id, 'REVIEWER_VERIFY', NEW.reviewer_id,
              'reviewer session issued, expires ' || to_char(NEW.expires_at,'YYYY-MM-DD HH24:MI'));
  ELSE
    INSERT INTO agent_audit (author_id, action, ref, detail)
      VALUES (NEW.author_id, 'VERIFY', NEW.author_id, 'session issued, expires ' || to_char(NEW.expires_at,'YYYY-MM-DD HH24:MI'));
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_session AFTER INSERT ON author_sessions FOR EACH ROW EXECUTE FUNCTION audit_session();

CREATE OR REPLACE FUNCTION audit_event() RETURNS TRIGGER AS $$
BEGIN
  IF TG_TABLE_NAME = 'pending_actions' THEN
    INSERT INTO agent_audit (author_id, action, ref, detail)
      VALUES (NEW.author_id, 'TRANSFER_PROPOSED', NEW.action_id,
              NEW.manuscript_id || ' -> ' || NEW.target_journal_code || ', author pays ' || usd(NEW.author_pays_usd));
  ELSIF TG_TABLE_NAME = 'transfers' THEN
    INSERT INTO agent_audit (author_id, action, ref, detail)
      SELECT m.corresponding_author_id, 'TRANSFERRED', NEW.manuscript_id,
             NEW.from_journal || ' -> ' || NEW.to_journal || ' (action ' || NEW.action_id || ')'
        FROM manuscripts m WHERE m.manuscript_id = NEW.manuscript_id;
  ELSIF TG_TABLE_NAME = 'submission_checks' THEN
    INSERT INTO agent_audit (author_id, action, ref, detail)
      VALUES (NEW.author_id, 'SUBMISSION_CHECKED', NEW.check_id,
              NEW.manuscript_id || ' -> ' || NEW.journal_code || ': ' || NEW.result
              || coalesce(' (mandatory missing: ' || NEW.mandatory_missing || ')', ''));
  ELSIF TG_TABLE_NAME = 'review_cases' THEN
    INSERT INTO agent_audit (author_id, action, ref, detail)
      VALUES (NEW.author_id, 'CASE_OPENED', NEW.case_id,
              NEW.request_type || coalesce(' on ' || NEW.manuscript_id, '') || coalesce(' parks ' || NEW.parked_action, ''));
  ELSIF TG_TABLE_NAME = 'apc_reductions' THEN
    INSERT INTO agent_audit (author_id, action, ref, detail)
      SELECT m.corresponding_author_id, 'APC_REDUCED', NEW.reduction_id,
             NEW.manuscript_id || ': waived ' || usd(NEW.waived_usd) || ', author pays ' || usd(NEW.author_pays_usd)
             || ' (case ' || NEW.case_id || ')'
        FROM manuscripts m WHERE m.manuscript_id = NEW.manuscript_id;
  ELSIF TG_TABLE_NAME = 'statement_exceptions' THEN
    INSERT INTO agent_audit (author_id, action, ref, detail)
      SELECT m.corresponding_author_id, 'STATEMENTS_EXCEPTION', NEW.exception_id,
             NEW.manuscript_id || ' -> ' || NEW.journal_code || ' (check ' || NEW.check_id || ', case ' || NEW.case_id || ')'
        FROM manuscripts m WHERE m.manuscript_id = NEW.manuscript_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_proposal  AFTER INSERT ON pending_actions      FOR EACH ROW EXECUTE FUNCTION audit_event();
CREATE TRIGGER trg_audit_transfer  AFTER INSERT ON transfers            FOR EACH ROW EXECUTE FUNCTION audit_event();
CREATE TRIGGER trg_audit_check     AFTER INSERT ON submission_checks    FOR EACH ROW EXECUTE FUNCTION audit_event();
CREATE TRIGGER trg_audit_case      AFTER INSERT ON review_cases         FOR EACH ROW EXECUTE FUNCTION audit_event();
CREATE TRIGGER trg_audit_apc       AFTER INSERT ON apc_reductions       FOR EACH ROW EXECUTE FUNCTION audit_event();
CREATE TRIGGER trg_audit_exception AFTER INSERT ON statement_exceptions FOR EACH ROW EXECUTE FUNCTION audit_event();

-- =====================================================================
-- AGENT REFERENCE READS - the only SQL the review_summary_agent and submission_check_agent tools run
-- (SELECT * FROM ref_<topic>(CAST(?lookup AS text))). SELECT-only, STABLE, no identity argument. The lookup is the one
-- value the model may supply. (The journal_match_agent keeps its search_journals() read.)
-- =====================================================================
-- ref_review_guide: empty / NULL -> the whole guide; otherwise one or more words separated by , or ; - a row matches
-- when a word equals its section (spaces = underscores) or appears in its term or meaning (plain substring, no
-- wildcards). Unknown words -> 0 rows (never an error).
CREATE OR REPLACE FUNCTION ref_match(p_term TEXT, p_section TEXT, p_entry TEXT, p_meaning TEXT) RETURNS BOOLEAN AS $$
  SELECT regexp_replace(coalesce(p_term, ''), '[[:space:],;]', '', 'g') = ''
      OR EXISTS (SELECT 1 FROM regexp_split_to_table(lower(p_term), '[,;]') w
                  WHERE btrim(w) <> ''
                    AND (lower(p_section) = regexp_replace(btrim(w), '[[:space:]]+', '_', 'g')
                         OR strpos(lower(p_entry), btrim(w)) > 0 OR strpos(lower(p_meaning), btrim(w)) > 0))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION ref_review_guide(p_term TEXT)
RETURNS TABLE (section TEXT, term TEXT, meaning TEXT) AS $$
  SELECT r.sec, r.trm, r.mng
    FROM (SELECT g.section::text AS sec, g.term::text AS trm, g.meaning::text AS mng, g.entry_id AS ord
            FROM review_guide g
          UNION ALL                                 -- who considers an appeal: review_teams is the source of truth
          SELECT 'WHO_DECIDES', t.label::text,
                 'If you disagree with a reviewer, explain why politely in your response letter; to challenge the decision '
                 || 'itself, ask for a ' || t.label || ' - the ' || t.team || ' considers it and replies within '
                 || t.sla_days || ' business days.', 1000
            FROM review_teams t WHERE t.request_type = 'DECISION_APPEAL') r
   WHERE ref_match(p_term, r.sec, r.trm, r.mng)
   ORDER BY array_position(ARRAY['COMMENT_TYPE','PRIORITY','CHECKLIST_RULE','RESPONSE_LETTER','WHO_DECIDES'], r.sec), r.ord, r.trm
$$ LANGUAGE sql STABLE;

-- ref_journal_policy: empty / NULL -> every policy set (applies_to = the active journals that follow it); a journal code
-- -> that journal's policy rows; a policy set or statement code -> those rows. Unknown -> 0 rows (never an error).
CREATE OR REPLACE FUNCTION ref_journal_policy(p_journal TEXT)
RETURNS TABLE (policy_set TEXT, applies_to TEXT, statement TEXT, requirement TEXT, must_include TEXT, standard_wording TEXT) AS $$
  SELECT sp.policy_set::text,
         CASE WHEN EXISTS (SELECT 1 FROM journals j WHERE j.journal_code = upper(btrim(coalesce(p_journal, ''))) AND j.is_active)
              THEN upper(btrim(p_journal))
              ELSE (SELECT string_agg(j.journal_code, ', ' ORDER BY j.journal_code) FROM journals j
                     WHERE j.policy_set = sp.policy_set AND j.is_active) END,
         sp.statement::text, sp.requirement::text, sp.must_include::text, sp.standard_wording::text
    FROM submission_policies sp
   WHERE btrim(coalesce(p_journal, '')) = ''
      OR sp.policy_set = upper(btrim(p_journal))
      OR sp.statement = upper(btrim(p_journal))
      OR sp.policy_set = (SELECT j.policy_set FROM journals j WHERE j.journal_code = upper(btrim(p_journal)) AND j.is_active)
   ORDER BY array_position(ARRAY['STANDARD','OPEN_DATA','HUMAN_SUBJECTS'], sp.policy_set::text), sp.sort_order
$$ LANGUAGE sql STABLE;

\ir seed_data.sql
