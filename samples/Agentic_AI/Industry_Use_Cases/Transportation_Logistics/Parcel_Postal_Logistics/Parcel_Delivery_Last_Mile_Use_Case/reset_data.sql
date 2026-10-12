-- Reset the demo: clears everything the assistant wrote (sessions, proposals, changes, cases, logs)
-- and reloads the demo data with CURRENT_DATE-relative dates.
-- psql -d parcel_delivery -f reset_data.sql

TRUNCATE agent_audit, verify_attempts, service_cases, service_teams, delivery_change_log, delivery_changes,
  pending_actions, recipient_sessions, scan_events, parcels, pickup_points, delivery_slots, exception_codes,
  recipients RESTART IDENTITY CASCADE;

\ir seed_data.sql
