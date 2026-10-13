-- Reset the Arcwell Components demo: clears everything the assistant and reviewers wrote (sessions, verify attempts,
-- proposals, orders and RMAs placed in chat, expedites, alert subscriptions, cases, decisions, credit memos, credit
-- changes, audit, email log) and reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d semiconductor_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, credit_changes, credit_memos, decide_attempts, review_decisions, case_requests,
  service_cases, subscribe_attempts, pcn_subscriptions, expedite_events, expedite_attempts, rmas, confirm_attempts,
  account_events, pending_actions, order_lines, sales_orders, verify_attempts, sessions, reviewers, buyers, accounts,
  case_routing, pcn_notices, cross_references, inventory, price_breaks, parts, order_policy,
  part_selection_guide, defect_taxonomy, pcn_change_guide RESTART IDENTITY CASCADE;

\ir seed_data.sql
