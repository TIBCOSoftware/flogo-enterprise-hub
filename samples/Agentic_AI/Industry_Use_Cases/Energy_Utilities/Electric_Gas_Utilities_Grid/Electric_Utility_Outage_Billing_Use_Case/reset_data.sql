-- Reset the Ridgeline Power & Light demo: clears everything the assistant and reviewers wrote (sessions, verify
-- attempts, proposals, events, tickets, appointments, reconnect orders, cases, decisions, audit, email log) and
-- reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d power_distribution_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, payment_arrangements, review_decisions, service_cases, tool_attempts,
  account_events, pending_actions, plan_changes, service_orders, appointments, appointment_slots, outage_tickets,
  outages, payments, bill_lines, bills, verify_attempts, sessions, reviewers, customers, case_routing, rate_plans,
  bill_glossary, outage_triage_guide, rate_plan_notes
  RESTART IDENTITY CASCADE;

\ir seed_data.sql
