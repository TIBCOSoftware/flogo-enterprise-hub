-- Reset the demo: clears everything the assistant wrote (sessions, verify attempts, proposals, investigations,
-- review cases, payment events, audit) and reloads the demo data with CURRENT_DATE-relative dates.
-- psql -d payments_governed -f reset_data.sql

TRUNCATE agent_audit, review_cases, service_teams, investigations, pending_actions, verify_attempts,
  client_sessions, payment_events, payments, cutoff_rules, reason_codes, accounts, clients RESTART IDENTITY CASCADE;

-- RESTART IDENTITY already resets owned sequences; restated so the id formats are obvious.
ALTER SEQUENCE inv_seq  RESTART WITH 2;   -- INV-2026-0002.. (0001 is seeded)
ALTER SEQUENCE case_seq RESTART WITH 1;   -- CASE-00001..

\ir seed_data.sql
