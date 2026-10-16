-- Reset the Bellmont Regional Medical Center demo: clears everything the assistant and the reviewers wrote (sessions,
-- verify attempts, proposals, bookings, orders, bed turnovers, cases, decisions, audit, email log) and reloads the demo
-- data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d hospital_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, case_requests, service_cases, bed_attempts, bed_events,
  med_order_attempts, pharmacy_orders, confirm_attempts, appointment_events, pending_actions, appointments, clinic_slots,
  discharge_medications, discharges, beds, patients, verify_attempts, sessions, reviewers, coordinators, case_routing,
  medication_catalog, specialties, wards, plain_language_guide, med_rec_reference, slot_ranking_guide
  RESTART IDENTITY CASCADE;

\ir seed_data.sql
