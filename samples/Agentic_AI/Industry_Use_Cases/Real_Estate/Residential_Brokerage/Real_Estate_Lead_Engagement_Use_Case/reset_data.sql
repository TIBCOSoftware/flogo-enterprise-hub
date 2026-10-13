-- Reset the Brightpath Realty demo: clears everything the assistant and reviewers wrote (sessions, verify attempts,
-- showing proposals and bookings, stage changes, follow-ups, cases, decisions, price changes, audit, email log) and
-- reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d realestate_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, listing_price_changes, decide_attempts, review_decisions, case_requests, service_cases,
  follow_up_attempts, follow_up_tasks, lead_stage_events, confirm_attempts, showing_events, pending_actions, appointments,
  lead_activity, verify_attempts, sessions, reviewers, listings, leads, agents, area_market_stats, case_routing,
  showing_policy,
  listing_match_guide, lead_intent_guide, fair_housing_guide RESTART IDENTITY CASCADE;

\ir seed_data.sql
