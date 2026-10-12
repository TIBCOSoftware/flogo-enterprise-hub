-- Reset the demo: clears everything the assistant wrote (sessions, proposals, rebookings, cases,
-- the rebooking log) and reloads the demo data with CURRENT_DATE-relative flight times.
-- psql -d airline_governed -f reset_data.sql

TRUNCATE agent_audit, verify_attempts, service_cases, service_teams, rebooking_log, rebookings,
  pending_actions, traveler_sessions, booking_segments, bookings, frequentflyer, passengers, flights RESTART IDENTITY CASCADE;

\ir seed_data.sql
