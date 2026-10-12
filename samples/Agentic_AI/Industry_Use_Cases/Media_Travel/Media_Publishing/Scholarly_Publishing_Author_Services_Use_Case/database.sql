-- Scholarly Publishing Author Services - schema, business rules and demo data.
-- Load:  createdb author_services  &&  psql -d author_services -f database.sql

-- =====================================================================
-- Scholarly Publishing - Author Services Assistant
-- Schema + business rules. The rules live HERE, not in any prompt:
--   * session_author()        identity: every read/write is scoped by a session token
--   * transfer_eval()         transfer eligibility (status, integrity hold, scope, word limit)
--   * apc_quote()             APC price + institutional agreement coverage (arithmetic in SQL)
--   * trg_transfer_apply      the transfer side effects happen atomically in the DB
--   * review_cases.assigned_team  human-owned requests are routed by rule, not by the LLM
-- The MCP tools call these functions; the LLM never computes, filters or decides them.
-- =====================================================================

DROP TABLE IF EXISTS review_cases, transfers, pending_actions, author_sessions,
  manuscripts, authors, agreement_journals, oa_agreements, journals, institutions, review_teams CASCADE;

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
  submitted_on             DATE NOT NULL,
  last_updated             TIMESTAMP NOT NULL DEFAULT now(),
  integrity_hold           BOOLEAN NOT NULL DEFAULT FALSE,   -- never disclosed to the author
  transferred_from         VARCHAR(8) REFERENCES journals
);

CREATE TABLE author_sessions (
  session_token  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  author_id      VARCHAR(12) NOT NULL REFERENCES authors,
  created_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp(),
  expires_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp() + INTERVAL '60 minutes'
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

CREATE TABLE review_teams (
  request_type   VARCHAR(24) PRIMARY KEY,
  team           VARCHAR(60) NOT NULL,
  sla_days       INTEGER NOT NULL
);

CREATE TABLE review_cases (
  case_id           TEXT PRIMARY KEY DEFAULT 'RC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)),
  author_id         VARCHAR(12) NOT NULL REFERENCES authors,
  manuscript_id     VARCHAR(16) REFERENCES manuscripts,
  request_type      VARCHAR(24) NOT NULL REFERENCES review_teams,
  author_statement  TEXT NOT NULL,
  agent_brief       TEXT NOT NULL,          -- neutral summary written by the assistant; never a decision
  status            VARCHAR(12) NOT NULL DEFAULT 'OPEN',
  created_at        TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------
-- Rule: identity. A token is valid for its author until it expires.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION session_author(p_token TEXT) RETURNS VARCHAR AS $$
  SELECT author_id FROM author_sessions
   WHERE session_token = p_token AND expires_at > clock_timestamp();
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

-- ---------------------------------------------------------------------
-- Rule: may this author transfer this manuscript to this journal?
-- Returns one row: ok + a reason the assistant can explain verbatim.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_eval(p_author TEXT, p_manuscript TEXT, p_journal TEXT)
RETURNS TABLE (ok BOOLEAN, reason TEXT) AS $$
DECLARE m manuscripts; j journals;
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
        JOIN author_sessions se ON se.author_id = a.author_id AND se.expires_at > clock_timestamp()
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
               word_count INTEGER, keywords TEXT, abstract TEXT, transferred_from VARCHAR) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' WHEN m.manuscript_id IS NULL THEN 'NOT_FOUND' ELSE 'OK' END,
         m.manuscript_id, m.title, m.journal_code, j.title, m.status,
         CASE WHEN m.integrity_hold THEN 'With the editorial office.' ELSE m.status_detail END,
         CASE WHEN m.integrity_hold THEN NULL ELSE m.decision_summary END,
         m.article_type, m.word_count, m.keywords, m.abstract, m.transferred_from
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN manuscripts m ON m.corresponding_author_id = s.aid AND m.manuscript_id = upper(trim(p_manuscript))
    LEFT JOIN journals j ON j.journal_code = m.journal_code;
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

CREATE OR REPLACE FUNCTION review_case_result(p_token TEXT, p_manuscript TEXT, p_type TEXT)
RETURNS TABLE (outcome TEXT, reason TEXT, case_id TEXT, request_type VARCHAR, assigned_team VARCHAR,
               reply_within_business_days INTEGER, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN c.case_id IS NOT NULL THEN 'CASE_OPENED' ELSE 'NOT_OPENED' END,
         CASE WHEN c.case_id IS NOT NULL THEN 'A person on the assigned team will review and reply. The assistant has not decided anything.'
              WHEN s.aid IS NULL THEN 'SESSION_INVALID: identity not verified or session expired. Verify again.'
              WHEN NOT EXISTS (SELECT 1 FROM review_teams rt WHERE rt.request_type = upper(trim(p_type)))
                THEN 'BAD_REQUEST_TYPE: use APC_WAIVER, DECISION_APPEAL, AUTHORSHIP_CHANGE, INTEGRITY_QUERY or OTHER.'
              ELSE 'NOT_FOUND: no manuscript with that id for this author.' END,
         c.case_id, c.request_type, t.team, t.sla_days, c.status, c.created_at
    FROM (SELECT session_author(p_token) AS aid) s
    LEFT JOIN LATERAL (
      SELECT rc.* FROM review_cases rc
       WHERE rc.author_id = s.aid AND rc.request_type = upper(trim(p_type))
         AND coalesce(rc.manuscript_id,'') = upper(trim(coalesce(p_manuscript,'')))
         AND rc.created_at > clock_timestamp() - INTERVAL '10 minutes'
       ORDER BY rc.created_at DESC LIMIT 1) c ON TRUE
    LEFT JOIN review_teams t ON t.request_type = c.request_type;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION my_cases(p_token TEXT)
RETURNS TABLE (session_status TEXT, case_id TEXT, manuscript_id VARCHAR, request_type VARCHAR,
               assigned_team VARCHAR, status VARCHAR, created_at TIMESTAMP) AS $$
  SELECT CASE WHEN s.aid IS NULL THEN 'SESSION_INVALID' ELSE 'OK' END,
         c.case_id, c.manuscript_id, c.request_type, t.team, c.status, c.created_at
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
RETURNS TABLE (author_id VARCHAR, manuscript_id VARCHAR, request_type VARCHAR, author_statement TEXT, agent_brief TEXT) AS $$
  SELECT s.aid, NULLIF(upper(trim(coalesce(p_manuscript,''))),'')::VARCHAR, t.request_type,
         left(coalesce(p_statement,''), 4000), left(coalesce(p_brief,''), 4000)
    FROM (SELECT session_author(p_token) AS aid) s
    JOIN review_teams t ON t.request_type = upper(trim(p_type))
   WHERE s.aid IS NOT NULL
     AND (coalesce(trim(p_manuscript),'') = ''
          OR EXISTS (SELECT 1 FROM manuscripts m WHERE m.manuscript_id = upper(trim(p_manuscript)) AND m.corresponding_author_id = s.aid))
     AND NOT EXISTS (SELECT 1 FROM review_cases rc
                      WHERE rc.author_id = s.aid AND rc.request_type = t.request_type
                        AND coalesce(rc.manuscript_id,'') = upper(trim(coalesce(p_manuscript,'')))
                        AND rc.created_at > clock_timestamp() - INTERVAL '10 minutes');
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Demo data (fictional publisher, journals, people). Dates are relative to today.
-- ---------------------------------------------------------------------
INSERT INTO institutions VALUES
 ('INST-001','University of Northbridge','United Kingdom'),
 ('INST-002','Kestrel Institute of Technology','Norway'),
 ('INST-003','Harbourview College','Canada');

INSERT INTO oa_agreements VALUES
 ('AGR-001','INST-001','Northbridge Read & Publish 2026','Read & Publish',100, date_trunc('year',current_date)::date, (date_trunc('year',current_date) + interval '1 year - 1 day')::date, 250000, 118400),
 ('AGR-002','INST-002','Kestrel Publish & Read 2026','Publish & Read',100, date_trunc('year',current_date)::date, (date_trunc('year',current_date) + interval '1 year - 1 day')::date,  90000,  89200);

INSERT INTO journals (journal_code,title,subject_area,aims_scope,keywords,oa_model,apc_usd,word_limit,median_days_to_first_decision,accepts_transfers,is_active) VALUES
 ('JACI','Journal of Applied Climate Informatics','Climate Science',
  'Methods papers on data pipelines, sensor networks and software for climate records. We do not publish regional impact or hazard studies.',
  'climate data, data pipelines, reanalysis, sensor networks, research software','Hybrid',3400,8000,38,TRUE,TRUE),
 ('CHRR','Coastal Hazards and Risk Review','Earth & Environmental Science',
  'Coastal flooding, storm surge, sea-level rise and the risk they pose to people and infrastructure, including statistical and machine-learning risk models.',
  'coastal flooding, storm surge, sea-level rise, flood risk, hazard mapping, machine learning','Gold OA',2900,9000,41,TRUE,TRUE),
 ('EDSR','Environmental Data Science Reports','Earth & Environmental Science',
  'Short, reproducible studies that apply machine learning and statistics to environmental data, with open code and data.',
  'machine learning, downscaling, environmental data, reproducibility, deep learning','Gold OA',1850,6000,27,TRUE,TRUE),
 ('HCRL','Hydrology and Climate Resilience Letters','Earth & Environmental Science',
  'Hydrology, flood modelling, climate adaptation and resilience planning at catchment to city scale.',
  'hydrology, flood modelling, climate adaptation, resilience, rainfall','Hybrid',3100,8500,45,TRUE,TRUE),
 ('UPIS','Urban Planning and Infrastructure Studies','Social Science',
  'Policy and planning research on urban infrastructure, transport and housing.',
  'urban planning, infrastructure policy, housing, transport','Hybrid',2600,10000,60,TRUE,TRUE),
 ('CMLT','Computational Materials Letters','Materials Science',
  'Rapid communications on computational materials discovery and simulation.',
  'materials discovery, density functional theory, simulation, alloys','Gold OA',2200,5000,21,TRUE,TRUE),
 ('BIOM','Biomolecular Methods','Life Sciences',
  'New laboratory and computational methods for structural and molecular biology.',
  'protein structure, cryo-EM, molecular biology methods','Hybrid',3800,9000,50,TRUE,TRUE),
 ('NEUR','Frontiers of Neural Computation','Computer Science',
  'Theory and applications of neural networks and deep learning.',
  'neural networks, deep learning, representation learning, optimisation','Hybrid',3000,9000,44,FALSE,TRUE),
 ('GEOS','Geospatial Analytics Quarterly','Earth & Environmental Science',
  'Remote sensing, GIS and spatial statistics, including satellite-based flood and land-use mapping.',
  'remote sensing, GIS, spatial statistics, satellite imagery, flood mapping','Hybrid',2750,8000,52,TRUE,TRUE),
 ('OCEN','Ocean Dynamics Letters','Earth & Environmental Science',
  'Physical oceanography: circulation, waves, tides and sea level.',
  'ocean circulation, waves, tides, sea level','Gold OA',2400,7000,35,TRUE,TRUE),
 ('SOCM','Society and Medicine','Health Sciences',
  'Social determinants of health and health policy.',
  'public health, health policy, epidemiology','Hybrid',3300,8000,58,TRUE,TRUE),
 ('ENGR','Engineering Structures Review','Engineering',
  'Structural engineering, including flood-resilient infrastructure design.',
  'structural engineering, resilient design, infrastructure','Hybrid',2950,9000,47,TRUE,TRUE),
 ('RETR','Archive of Climate Methods (retired)','Climate Science',
  'Retired title. No longer accepting submissions.',
  'climate methods','Hybrid',0,8000,0,FALSE,FALSE);

INSERT INTO agreement_journals VALUES
 ('AGR-001','JACI'),('AGR-001','HCRL'),('AGR-001','EDSR'),('AGR-001','GEOS'),('AGR-001','UPIS'),('AGR-001','ENGR'),
 ('AGR-002','CMLT'),('AGR-002','EDSR'),('AGR-002','CHRR'),('AGR-002','OCEN');

INSERT INTO authors VALUES
 ('AUT-1001','0000-0002-1825-0097','Dr. Maya Okafor','maya.okafor@northbridge.example','INST-001','482913'),
 ('AUT-1002','0000-0004-7316-2588','Prof. Lars Eriksen','lars.eriksen@kestrel.example','INST-002','771204'),
 ('AUT-1003','0000-0003-1415-9269','Dr. Ana Ribeiro','ana.ribeiro@harbourview.example','INST-003','305118');

INSERT INTO manuscripts (manuscript_id,corresponding_author_id,journal_code,title,abstract,keywords,article_type,word_count,status,status_detail,decision_summary,submitted_on,last_updated,integrity_hold) VALUES
 ('MS-2026-0412','AUT-1001','JACI',
  'Machine-learning downscaling of compound coastal flood risk for small island states',
  'We present a gradient-boosted downscaling model that combines storm-surge hindcasts, tide-gauge records and rainfall reanalysis to estimate compound coastal flood risk at 250 m resolution for twelve small island states. Validated against surveyed flood extents, the model reduces error by 31% versus dynamical downscaling at a fraction of the compute cost. We release code and data.',
  'coastal flooding, compound flood risk, machine learning, downscaling, storm surge, small island states',
  'Research Article',7800,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer to a better-suited journal.',
  'Sound work, but out of scope: the journal publishes data-pipeline methods, not regional hazard studies. Reviewers praised the validation. Transfer offered.',
  current_date - 64, now() - interval '3 days', FALSE),
 ('MS-2026-0388','AUT-1001','HCRL',
  'Rainfall intensity trends and culvert failure in mid-sized UK towns',
  'An analysis of 40 years of rainfall intensity records against culvert failure reports in 58 towns.',
  'rainfall, hydrology, infrastructure failure, climate adaptation',
  'Research Article',6900,'UNDER_REVIEW',
  'Under review. Reviewers assigned; 2 of 3 reports received.',NULL,
  current_date - 41, now() - interval '6 days', FALSE),
 ('MS-2026-0301','AUT-1001','GEOS',
  'Sentinel-1 flood extent mapping with uncertainty bands',
  'A method for mapping flood extent from SAR imagery with calibrated uncertainty.',
  'remote sensing, flood mapping, uncertainty, satellite imagery',
  'Research Article',7100,'REVISION_REQUESTED',
  'Minor revision requested. Revised manuscript due in 21 days.',
  'Clarify the calibration dataset and add a comparison with optical imagery.',
  current_date - 95, now() - interval '9 days', FALSE),
 ('MS-2026-0450','AUT-1002','CHRR',
  'Storm-surge barriers and fjord ecosystems: a 30-year view',
  'Long-term monitoring of fjord ecology before and after storm-surge barrier construction.',
  'storm surge, coastal ecology, fjords, infrastructure',
  'Research Article',8200,'ACCEPTED',
  'Accepted. Awaiting open-access licence and APC arrangement before production.',
  'Accepted after one round of revision.',
  current_date - 120, now() - interval '2 days', FALSE),
 ('MS-2026-0433','AUT-1002','OCEN',
  'A unified wave-tide model for Arctic coastlines',
  'We couple spectral wave and tidal models for sea-ice-affected coasts, with an extended validation across 64 stations.',
  'waves, tides, arctic, coastal modelling, sea ice',
  'Research Article',11800,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'Strong modelling but beyond this letters journal''s length; suggested a transfer to a journal that takes long-form articles.',
  current_date - 70, now() - interval '5 days', FALSE),
 ('MS-2026-0419','AUT-1003','SOCM',
  'Neighbourhood heat exposure and emergency admissions',
  'Links heat exposure maps to emergency admissions across three cities.',
  'public health, heat, epidemiology',
  'Research Article',7400,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'Out of scope; transfer offered.',
  current_date - 50, now() - interval '4 days', TRUE);

INSERT INTO review_teams VALUES
 ('APC_WAIVER','Open Access Office',5),
 ('DECISION_APPEAL','Editorial Office (handling editor)',10),
 ('AUTHORSHIP_CHANGE','Editorial Office (authorship)',7),
 ('INTEGRITY_QUERY','Research Integrity Team',10),
 ('OTHER','Author Services',3);
