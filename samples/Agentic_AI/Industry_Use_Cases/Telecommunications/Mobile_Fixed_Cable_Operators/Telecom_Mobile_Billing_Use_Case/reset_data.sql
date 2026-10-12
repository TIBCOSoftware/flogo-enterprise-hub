-- Reset the Tidewell Mobile demo: clears everything the assistant wrote (sessions, proposals, events, confirm
-- attempts, cases, email log) and reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d mobile_billing -f reset_data.sql

TRUNCATE email_log, case_requests, service_cases, confirm_attempts, account_events, pending_actions,
  plan_changes, content_subscriptions, roaming_days, usage_cycles, unbilled_charges, payments, bill_lines,
  bills, customer_sessions, customers, case_routing, plans RESTART IDENTITY CASCADE;

\ir seed_data.sql
