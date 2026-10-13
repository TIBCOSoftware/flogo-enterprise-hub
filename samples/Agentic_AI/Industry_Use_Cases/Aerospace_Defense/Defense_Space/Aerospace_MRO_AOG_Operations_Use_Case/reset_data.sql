-- Reset the Northvale Aero Services demo: clears everything the assistant and the reviewers wrote (sessions, verify
-- attempts, proposals, confirmed actions, part orders, dispatches, return-to-service events, cases, decisions, audit,
-- email log) and reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d aerospace_mro_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, case_requests, service_cases, fleet_events, confirm_attempts,
  action_events, pending_actions, part_orders, aog_incidents, part_stock, parts, work_orders, technicians, aircraft,
  verify_attempts, sessions, reviewers, controllers, case_routing, aircraft_types, bases, ata_chapter_guide,
  repeat_defect_guide, handover_guide RESTART IDENTITY CASCADE;

\ir seed_data.sql
