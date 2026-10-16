-- =============================================================================
-- RetailCo Beauty DB — Patch 001
-- Applied: 2026-05-13
-- =============================================================================
-- Run against an existing beauty_db to apply schema fixes without recreating
-- tables from scratch. Safe to run on a live database with existing data.
--
-- Usage:
--   psql -U postgres -d beauty_db -f beauty-schema-patch-001.sql
-- =============================================================================

-- ── Fix 1: loyalty_offers.offer_id ──────────────────────────────────────────
-- Problem: offer_id was VARCHAR(30) with no default, causing NOT NULL violation
--          on every INSERT from the Flogo MCP tool (CreateLoyaltyOffer).
--          Widened to VARCHAR(36) to accommodate UUID strings (36 chars).
-- Fix:     Widen column to VARCHAR(36) and add gen_random_uuid()::text as the
--          default so PostgreSQL auto-generates a UUID when no value is supplied.

ALTER TABLE loyalty_offers
  ALTER COLUMN offer_id TYPE VARCHAR(36),
  ALTER COLUMN offer_id SET DEFAULT gen_random_uuid()::text;

-- ── Fix 2: consultations.recommended_skus ───────────────────────────────────
-- Problem: recommended_skus was TEXT[] (array type) but the Flogo tool sends
--          a plain comma-separated string (e.g. "DR-VITC-SERUM,LA-ROCHE-TOLERIANE"),
--          causing "malformed array literal" on every INSERT.
-- Fix:     Change type to TEXT so comma-separated strings are stored as-is.

ALTER TABLE consultations
  ALTER COLUMN recommended_skus TYPE TEXT USING array_to_string(recommended_skus, ',');
