-- Reset the Tidewell Mobile demo: clears everything the assistant wrote (sessions, proposals, events, confirm
-- attempts, cases, reviewer decisions, executed case actions, audit, email log) and reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d mobile_billing -f reset_data.sql

TRUNCATE email_log, agent_audit, case_actions, decide_attempts, review_decisions, case_requests, service_cases,
  confirm_attempts, account_events, pending_actions,
  plan_changes, content_subscriptions, roaming_days, usage_cycles, unbilled_charges, payments, bill_lines,
  bills, reviewer_verify_attempts, customer_sessions, reviewers, customers, case_routing,
  plan_guide, charge_taxonomy, bill_glossary, plans RESTART IDENTITY CASCADE;

\ir seed_data.sql
