-- Reset the demo: clears everything the assistant and the reviewers wrote (sessions, proposals, changes,
-- instructions, claims, cases, decisions, compensation payments, emails, logs) and reloads the demo data with
-- CURRENT_DATE-relative dates.
-- psql -d parcel_delivery -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, compensation_payments, damage_claims,
  delivery_instructions, reviewer_verify_attempts, verify_attempts, service_cases, service_teams, delivery_change_log,
  delivery_changes, pending_actions, recipient_sessions, reviewers, scan_events, parcels, pickup_points, delivery_slots,
  exception_codes, recipients, claim_guide, instruction_guide, safe_places, instruction_risk_flags RESTART IDENTITY CASCADE;

\ir seed_data.sql
