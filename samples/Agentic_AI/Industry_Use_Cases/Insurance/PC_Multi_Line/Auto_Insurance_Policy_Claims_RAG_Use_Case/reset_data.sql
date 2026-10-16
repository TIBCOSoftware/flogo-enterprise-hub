-- Reset the Copperleaf Auto Insurance demo: clears everything the assistant and reviewers wrote (sessions, verify
-- attempts, proposals, assessments, claims filed in chat, cases, decisions, claim payments, audit, email log) and
-- reloads the demo data with CURRENT_DATE-relative dates. Re-runnable.
-- document_index (the RAG vector-store handoff written by AutoInsuranceRAGIngestion) is deliberately NOT truncated.
-- psql -v ON_ERROR_STOP=1 -d auto_insurance_governed -f reset_data.sql

SET client_min_messages = warning;
TRUNCATE email_log, agent_audit, claim_payments, decide_attempts, review_decisions, case_requests, service_cases,
  confirm_attempts, assessment_attempts, claim_assessments, pending_claims, claims, payments, coverages, vehicles,
  verify_attempts, sessions, policies, reviewers, policyholders, case_routing, fnol_intake_guide,
  coverage_clause_index, claim_indicator_guide RESTART IDENTITY CASCADE;

\ir seed_data.sql
