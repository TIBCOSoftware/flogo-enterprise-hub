-- Reset the demo: clears everything the assistant and the reviewers wrote (sessions, proposals, rebookings, cases,
-- baggage claims, assistance requests, decisions, payments, confirmations, emails, audit) and reloads the demo data with
-- CURRENT_DATE-relative flight times.
-- psql -d airline_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, ssr_confirmations, service_payments, decide_attempts, review_decisions, segment_ssrs,
  assistance_requests, baggage_claims, verify_attempts, reviewer_verify_attempts, service_cases, service_teams,
  rebooking_log, rebookings, pending_actions, traveler_sessions, reviewers, booking_segments, bookings, frequentflyer,
  passengers, flights, compensation_bands, baggage_claim_types, baggage_report_fields, baggage_guide, ssr_codes,
  assistance_guide RESTART IDENTITY CASCADE;

-- RESTART IDENTITY already resets owned sequences; restated so the id formats are obvious.
ALTER SEQUENCE bag_seq RESTART WITH 1;    -- BAG-00001.. baggage claims
ALTER SEQUENCE ast_seq RESTART WITH 1;    -- AST-00001.. assistance requests
ALTER SEQUENCE pay_seq RESTART WITH 1;    -- PAY-00001.. reviewer-approved payments
ALTER SEQUENCE ssrc_seq RESTART WITH 1;   -- SSRC-00001.. reviewer-confirmed assistance

\ir seed_data.sql
