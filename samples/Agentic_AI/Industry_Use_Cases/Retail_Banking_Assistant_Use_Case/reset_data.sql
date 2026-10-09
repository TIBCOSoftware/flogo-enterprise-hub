-- Reset the demo: clears everything the assistant wrote (sessions, verify attempts, proposals, card blocks,
-- replacements, disputes, provisional credits, cases, audit) and reloads the demo data with
-- CURRENT_DATE-relative dates.
-- psql -d banking_governed -f reset_data.sql

TRUNCATE agent_audit, service_cases, service_teams, disputes, card_replacements, card_blocks,
  pending_actions, verify_attempts, customer_sessions, merchant_directory, branches, loans, transactions,
  cards, accounts, customers RESTART IDENTITY CASCADE;

-- RESTART IDENTITY already resets owned sequences; restated so the id formats are obvious.
ALTER SEQUENCE txn_seq  RESTART WITH 60001;   -- TXN-60001.. system transactions (provisional credits)
ALTER SEQUENCE blk_seq  RESTART WITH 1;       -- BLK-00001..
ALTER SEQUENCE dsp_seq  RESTART WITH 2;       -- DSP-2026-0002.. (0001 is seeded)
ALTER SEQUENCE case_seq RESTART WITH 1;       -- CASE-00001..

\ir seed_data.sql
