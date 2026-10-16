-- Reset the demo: clears everything the assistant and the reviewers wrote (sessions, verify attempts, proposals,
-- card blocks, replacements, disputes, provisional credits, payments, holds, cases, decisions, deferrals, refunds,
-- email log, audit) and reloads the demo data with CURRENT_DATE-relative dates.
-- psql -d banking_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, loan_deferrals, payment_sends, payment_requests,
  payees, service_cases, service_teams, disputes, card_replacements, card_blocks, pending_actions,
  reviewer_verify_attempts, verify_attempts, customer_sessions, reviewers, merchant_directory, scam_signal_guide,
  hardship_guide, branches, loans, transactions, cards, accounts, customers RESTART IDENTITY CASCADE;

-- RESTART IDENTITY already resets owned sequences; restated so the id formats are obvious.
ALTER SEQUENCE txn_seq  RESTART WITH 60001;   -- TXN-60001.. system transactions (provisional credits, refunds, payments)
ALTER SEQUENCE blk_seq  RESTART WITH 1;       -- BLK-00001..
ALTER SEQUENCE dsp_seq  RESTART WITH 2;       -- DSP-2026-0002.. (0001 is seeded)
ALTER SEQUENCE case_seq RESTART WITH 1;       -- CASE-00001..
ALTER SEQUENCE pay_seq  RESTART WITH 1;       -- PAY-00001.. (00001 is William's seeded held payment)
ALTER SEQUENCE def_seq  RESTART WITH 1;       -- DEF-00001.. (reviewer-approved loan deferrals)

\ir seed_data.sql
