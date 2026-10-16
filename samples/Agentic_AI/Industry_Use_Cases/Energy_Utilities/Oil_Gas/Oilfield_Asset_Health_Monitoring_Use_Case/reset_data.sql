-- Reset the Mesa Ridge Energy demo: clears everything the assistant and the reviewers wrote (sessions, verify attempts,
-- field notes, proposals, confirmed actions, work orders, alerts, shut-ins, cases, decisions, audit, email log) and reloads
-- the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- psql -d predictive_maintenance_governed -f reset_data.sql

TRUNCATE email_log, agent_audit, decide_attempts, review_decisions, case_requests, service_cases, alert_events, asset_events,
  confirm_attempts, action_events, pending_actions, field_notes, alert_attempts, alerts, work_orders, sensor_readings, assets,
  failure_modes, failure_horizon, confidence_lookup, sensor_thresholds, verify_attempts, sessions, reviewers, operators,
  case_routing, sites, field_note_guide, failure_match_guide, handover_guide RESTART IDENTITY CASCADE;

\ir seed_data.sql
