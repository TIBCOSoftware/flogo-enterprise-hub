-- Reset the demo: clears everything the assistant and the reviewers wrote (sessions, verify attempts, proposals,
-- investigations, review cases and decisions, cash applications, payment requests, recalls, refunds, write-offs,
-- payment events, emails, audit) and reloads the demo data with CURRENT_DATE-relative dates.
-- psql -d payments_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, deduction_writeoffs, fee_refunds, payment_recalls,
  payment_releases, payment_requests, payee_register, cash_postings, cash_applications, open_invoices, review_cases,
  service_teams, investigations, pending_actions, reviewer_verify_attempts, verify_attempts, client_sessions, reviewers,
  payment_events, payments, cutoff_rules, reason_codes, remittance_guide, payee_name_guide, accounts, clients
  RESTART IDENTITY CASCADE;

-- RESTART IDENTITY already resets owned sequences; restated so the id formats are obvious.
ALTER SEQUENCE inv_seq  RESTART WITH 2;     -- INV-2026-0002.. (0001 is seeded)
ALTER SEQUENCE case_seq RESTART WITH 1;     -- CASE-00001.. (00001-00004 are seeded)
ALTER SEQUENCE pmt_seq  RESTART WITH 101;   -- PMT-2026-000101.. for payments submitted through the assistant
ALTER SEQUENCE cap_seq  RESTART WITH 1;     -- CAP-00001.. (00001 is seeded)
ALTER SEQUENCE prq_seq  RESTART WITH 1;     -- PRQ-00001.. (00001 is seeded)
ALTER SEQUENCE wo_seq   RESTART WITH 1;     -- WO-00001..

\ir seed_data.sql
