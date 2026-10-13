# Swiftbound Last-Mile Parcel Delivery (governed) — use-case spec

Built with the **agentic-ai-use-case-builder** skill (FDA-CLI method). Upgraded on 2026-10-13 to the current standard:
three A2A agents, every agent's tool reads PostgreSQL, and the full human-in-the-loop reviewer loop.

## 1. Business goal and audience

- **Who:** recipients of a fictional US last-mile carrier (Swiftbound), and Swiftbound staff reviewers (Claims,
  Investigations, Customer Relations).
- **Goal:** fewer missed deliveries and faster, fairer claims. Recipients self-serve tracking, rescheduling,
  redirection, delivery instructions and claims; staff decide compensation in the same chatbot.
- **Locale:** USA, USD. Runtime model: `gpt-5.5` on the orchestrator and all agents.

## 2. Decision framework (who owns what)

| Step | Owner | Where |
|---|---|---|
| Identity (recipient: account ref + PIN; staff: staff ID + code), role, scoping | Deterministic | `session_recipient`, `session_reviewer`, `verify_and_record`, `verify_reviewer_fn` |
| Status, lateness, exception meaning | Deterministic | `parcel_detail` (`delivery_health`), `exception_codes` |
| Reschedule / redirect eligibility and the change | Deterministic, two-step | `reschedule_eval` / `redirect_eval` → `pending_actions` → `delivery_changes` + `trg_delivery_change` |
| Ranking feasible options against preferences | **Agent** `delivery_options_agent` (9893) | reads `search_delivery_options()` |
| Damage description → claim type, packaging, cause, evidence | **Agent** `damage_claim_agent` (9894) | reads `ref_claim_guide()` |
| Claim eligibility and claimable amount | Deterministic | `claim_eval`, `claim_row_for` (least of claimed, declared value, coverage limit) |
| Access notes → safe place, access-code flag (masked), hazards, risk flags | **Agent** `delivery_instructions_agent` (9896) | reads `ref_delivery_instructions()` |
| Whether instructions can be saved | Deterministic, two-step | `instructions_eval` (safe_places, risk flags + SQL phrase scan, signature / high-value) → `pending_actions` → `delivery_instructions` + trigger |
| Compensation, wrong deliveries, complaints | **Human** | `service_cases` routed by `service_teams`; `decide_case_row` → `review_decisions` → `trg_review_decision` → `compensation_payments` |

## 3. Tools (MCP server, 18)

Recipient: `verify_recipient`, `get_my_parcels`, `get_parcel_detail`, `get_tracking_history`, `propose_reschedule`,
`confirm_reschedule`, `propose_redirect`, `confirm_redirect`, `propose_delivery_instructions`,
`confirm_delivery_instructions`, `open_damage_claim`, `open_service_case`, `get_my_cases`, `email_confirmation`
(guarded: `email_log` row + send only when the SQL says `SEND_OK`).
Reviewer: `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case`.
Every tool is `[GuardedWrite INSERT … SELECT * FROM rule_fn(…)] → ReadOutcome → Return`; the SQL is in `tool_spec.py`.

## 4. Agents (A2A, read-only, no identity)

| Agent | Port | Input (minimised) | Output | Reference tool → table |
|---|---|---|---|---|
| `delivery_options_agent` | 9893 | area, size, signature flag, value flag, earliest date, preferences | up to 3 ranked slots / pickup points | `search_delivery_options` → `delivery_slots`, `pickup_points` (kept as built) |
| `damage_claim_agent` | 9894 | the recipient's words + description, size, status, exception label | claim_type, packaging_condition, likely_cause, item_damage, evidence_to_send, claim_line, summary | `get_claim_guide` → `claim_guide` (+ WHO_DECIDES from `service_teams`) |
| `delivery_instructions_agent` | 9896 | the recipient's access notes + signature / value flags | safe_place, access_code_present, hazards, risk_flags, driver_note (codes masked), driver_line | `get_delivery_instructions_guide` → `safe_places`, `instruction_risk_flags`, `instruction_guide` |

The agents' terms are the SAME rows SQL validates against: an unknown packaging or cause term is recorded as
`NOT_STATED` / `UNKNOWN` and listed in `ignored_terms`; an unknown safe place is refused; unknown risk flags are
ignored, while known ones (from the agent or the SQL phrase scan) block the save. Port 9895 is skipped
(Feature_Samples BankAPIGateway).

## 5. Reviewer loop (human in the loop)

- `reviewers` (6, one per team; Hannah Brooks's $500 limit sits below the $650 lens claim and the $1,000 laptop claim
  → OVER_AUTHORITY demo; Victor Osei $2,500 is the senior damaged-parcel reviewer).
- Cases carry `requested_amount`, `parked_action` (`COMPENSATION:<claim_id>`), `sla_due_at` (trigger from
  `service_teams.sla_days`), `customer_message`, `approved_amount`, `decided_at`.
- `decide_case_row` reason codes: NOT_REVIEWER, NOT_FOUND, NOT_YOUR_TEAM, ALREADY_DECIDED, INVALID_DECISION,
  NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY (case stays OPEN). Approve executes `compensation_payment_row` (requires
  the parked action); reject executes nothing. Audit: `CASE_DECIDED` (actor = reviewer) + `COMPENSATION_PAID`.
- Seeded open cases: damaged (lens $650), lost (boots $160), missing contents (serum $45), wrong delivery (lamp),
  complaint.

## 6. Data

Database `parcel_delivery`; `database.sql` (schema + rules, re-runnable: a `DO` block drops the functions first),
`seed_data.sql` (dates relative to today), `reset_data.sql`. Case ids are sequential (`SC-00001…`) after every reset.

## 7. Known limitations

- Live SMTP needs the Gmail App Password re-entered in the MCP app (the shipped `SECRET:` is a portable placeholder).
- Access codes are never stored; in this demo the driver gets the code from the recipient in the app (not modelled).
- Wrong-delivery and complaint cases carry no automatic action on approval (the team completes them).
