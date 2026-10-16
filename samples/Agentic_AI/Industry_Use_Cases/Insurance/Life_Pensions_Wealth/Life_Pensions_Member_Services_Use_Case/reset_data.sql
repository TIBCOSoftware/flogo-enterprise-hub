-- Reset the Harborline Life & Retirement demo: clears everything the assistant and reviewers wrote (sessions, verify
-- attempts, proposals, events, claims filed in chat, cases, decisions, payments, withdrawals, audit, email log) and
-- reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d life_pensions_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, case_requests, file_claim_attempts, withdrawals,
  claim_payments, service_cases, confirm_attempts, account_events, pending_actions, rate_changes, claims, contributions,
  holdings, retirement_accounts, beneficiaries, policies, verify_attempts, sessions, reviewers, members, case_routing,
  funds, plan_limits, claim_intake_guide, life_event_guide, appeal_review_guide RESTART IDENTITY CASCADE;

\ir seed_data.sql
