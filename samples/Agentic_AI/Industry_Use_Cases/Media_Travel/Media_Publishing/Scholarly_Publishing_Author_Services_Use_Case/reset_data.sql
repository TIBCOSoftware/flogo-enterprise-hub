-- Reset the demo: clears everything the assistant and the reviewers wrote (sessions, proposals, transfers, submission
-- checks, cases, decisions, APC waivers, statement exceptions, audit) and reloads the demo data with dates relative to today.
-- psql -d author_services -f reset_data.sql

TRUNCATE agent_audit, statement_exceptions, apc_reductions, decide_attempts, review_decisions, submission_checks,
  review_cases, transfers, pending_actions, reviewer_verify_attempts, author_sessions, reviewers, review_comments,
  manuscripts, authors, agreement_journals, oa_agreements, journals, submission_policies, institutions, review_teams,
  review_guide RESTART IDENTITY CASCADE;

-- RESTART IDENTITY already resets owned sequences; restated so the id formats are obvious.
ALTER SEQUENCE chk_seq RESTART WITH 1;   -- SCK-00001.. submission checks
ALTER SEQUENCE apr_seq RESTART WITH 1;   -- APR-00001.. reviewer-approved APC waivers
ALTER SEQUENCE exc_seq RESTART WITH 1;   -- EXC-00001.. reviewer-approved statements exceptions

\ir seed_data.sql
