# Corporate Payment Investigation & Status — governed spec (Aurelia Global Bank)

Built with the `agentic-ai-use-case-builder` skill (governed, FDA-CLI method). Upgraded 2026-10-13 to the current
standard: three A2A agents, every agent's reference tool reads PostgreSQL, and the full human-in-the-loop reviewer
loop. Reference implementations: `Industry_Use_Cases/Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/`
(same industry, same reviewer-loop shape) and `Industry_Use_Cases/Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/`.
Aurelia Global Bank, its clients, staff, accounts, buyers, beneficiaries and payments are fictional.

**Why this applies to every large bank:** retail, commercial and transaction-banking institutions all run
high-value and cross-border payments; "where is my payment, why was it returned/held, trace it, recall it" is
the universal servicing pain, and cash application of short payments and verification of payee (the defence against
business email compromise) are the two most common corporate-servicing follow-ons. The AI reads the client's free
text, decodes return codes, reads remittance notes and compares company names; the database decides identity, scope,
eligibility, delivery estimates, the cash split, the name-check band and every state change; people own recalls,
held payments, disputed deductions and compliance.

## Identity, apps, ports

| Item | Value |
|---|---|
| Persona | An authorised user at a **corporate client** of Aurelia Global Bank (treasury / AP / AR), self-serving over chat; and an Aurelia **staff reviewer** (Payment Operations, Client Servicing) working a team queue in the same chatbot |
| Database | `payments_governed` |
| Orchestrator | `CorporatePaymentsAIOrchestrator.flogo` — WebSocket `9870` path `/corporatepayments` |
| MCP server | `CorporatePaymentsMCPServer.flogo` — MCP `9872` path `/corporate-payments-mcp`, serverName `CorporatePayments`, 22 tools |
| A2A agents | `CorporatePaymentsAgents.flogo` — `payment_triage_agent` `9873`, `remittance_match_agent` `9874`, `payee_name_match_agent` `9875` |
| Runtime LLM | `gpt-5.5` (property `LLM_Model`) |
| Email | Gmail SMTP 465 SSL; `Email_Username`, `Email_App_Password` (SECRET; portable placeholder until re-entered), `To_Email` (ops inbox) |

## Decision-framework classification

| Operation | Q1 human? | Q2 semantic? | Owner | Implemented as |
|---|---|---|---|---|
| Verify the user | no | no | Deterministic | `verify_client` (client_id + 6-digit passcode) → session token 30 min; 5 wrong → 15-min lock. Staff: `verify_reviewer` (staff id + code), role REVIEWER |
| See only the client's own payments / invoices / cases | no | no | Deterministic, scoped | scoped reads `FROM my_x(token)` |
| Payment status, rail, FX, fees, decoded return reason | no | no | Deterministic | rule functions; LLM quotes verbatim |
| Will it settle by the cutoff / SLA | no | no | Deterministic **arithmetic** | `delivery_estimate` from `cutoff_rules` (never guessed) |
| Raise a trace on a delayed payment | no | no | Deterministic, **two-step** | `propose_trace` → yes → `confirm_trace` (investigations + trigger) |
| Recall a payment (money reversal) | **yes** | no | Human, **two-step + reviewer** | `propose_recall` → yes → `confirm_recall` opens a Payment Ops case that **parks** `RECALL:<payment>`; a reviewer approves (recall executed) or rejects (status restored) |
| Decode a return code, match the client's words to a payment, recommend trace vs recall | no | **yes** | **Agent** | `payment_triage_agent` (read-only `lookup_reason_code`), never receives identity |
| Match a remittance / short-pay note to open invoices, name the deduction reasons | no | **yes** | **Agent** | `remittance_match_agent` (read-only `get_remittance_guide`), never receives identity |
| Which invoices are paid, the earned discount, what is disputed | no | no | Deterministic, **two-step** | `propose_cash_application` → yes → `confirm_cash_application` (`cash_assessment` validates the agent's output; posting + trigger) |
| Accept a disputed deduction over the tolerance | **yes** | – | Human (reviewer) | `DEDUCTION_REVIEW` case parks `DEDUCTION_WRITE_OFF:<application>` for Client Servicing |
| Compare the typed beneficiary name with the name on file | no | **yes** | **Agent** | `payee_name_match_agent` (read-only `get_payee_name_rules`), sees only the two names |
| Whether a new payment can go, needs a warning or is held | no | no | Deterministic, **two-step** | `propose_payment` → yes → `confirm_payment` (`payee_assessment` bands the agent verdict + SQL name score + amount) |
| Release or cancel a held payment | **yes** | – | Human (reviewer) | `PAYEE_VERIFICATION` case parks `RELEASE_PAYMENT:<request>` for Payment Operations |
| Fee waivers | **yes** | – | Human (reviewer) | `open_review_case` FEE_WAIVER parks `FEE_REFUND:<payment>` for Client Servicing |
| Compensation, suspected fraud, sanctions queries, payment repair | **yes** | – | Human | `open_review_case` → `service_teams` |

## Rules (reason codes) — all in SQL

Session: `SESSION_INVALID` (unknown/expired/reviewer token) on every client tool; `NOT_REVIEWER` on every reviewer tool.
verify: `VERIFIED` / `NOT_VERIFIED` / `LOCKED` (5 failures in 15 min → locked; no token while locked). Same for staff codes.

Unchanged from the first build: `get_payment_status` (`NOT_YOUR_PAYMENT`), `check_delivery_estimate`
(`ON_TRACK` / `PAST_CUTOFF` / `DELAYED` / `SETTLED` / `NOT_APPLICABLE` / `NO_ESTIMATE`), `propose_trace` / `confirm_trace`
(`NOT_YOUR_PAYMENT`, `NOT_TRACEABLE`, `ALREADY_UNDER_INVESTIGATION`, `BAD_REASON`; `NO_SUCH_PROPOSAL`, `EXPIRED`,
`ALREADY_EXECUTED` → `OPENED` INV-2026-NNNN), `propose_recall` / `confirm_recall` (`NOT_YOUR_PAYMENT`, `NOT_RECALLABLE`,
`ALREADY_RECALL_REQUESTED`, `BAD_REASON` → `SUBMITTED`: payment RECALL_REQUESTED, the status it replaced remembered,
Payment Operations case parking `RECALL:<payment>` for the full amount).

`get_my_payments` — INCOMING rows carry the payer (`ordering_party`), the remittance text and any applied cash
application; their beneficiary shows as `own account` (the client's legal name never travels to an agent).

`open_review_case(request_type, client_statement, brief, reference_id)` → `CASE_OPENED` / `ALREADY_OPEN` /
`NOT_OPENED` (`BAD_TYPE`, `BAD_REFERENCE`, `SESSION_INVALID`). RECALL, PAYEE_VERIFICATION and DEDUCTION_REVIEW are not
client-openable (they come only from the rules). FEE_WAIVER parks `FEE_REFUND:<payment>` (reference = a payment of
this client with an unrefunded fee; empty = the most recent one in 90 days), requested = the fee.

| request_type | team | reply (business days) | client-openable |
|---|---|---|---|
| RECALL | Payment Operations | 1 | no (confirm_recall) |
| PAYEE_VERIFICATION | Payment Operations | 1 | no (held payment) |
| PAYMENT_REPAIR | Payment Operations | 1 | yes |
| FEE_WAIVER | Client Servicing | 2 | yes |
| COMPENSATION | Client Servicing | 2 | yes |
| DEDUCTION_REVIEW | Client Servicing | 2 | no (cash posting) |
| FRAUD | Financial Crime | 1 | yes |
| SANCTIONS_QUERY | Sanctions & Compliance | 2 | yes |
| OTHER | Client Servicing | 3 | yes |

**Cash application.** `get_open_invoices(search)` lists the client's OPEN invoices (terms, early-pay date).
`propose_cash_application(payment_ref, remittance_text, invoice_numbers, deductions, confidence, agent_notes)`:
`NOT_YOUR_PAYMENT`, `NOT_INCOMING`, `FUNDS_NOT_RECEIVED` (not COMPLETED), `ALREADY_APPLIED`, `NO_INVOICES`,
`INVOICE_NOT_OPEN` (not an open invoice of this client in the payment currency), `LOW_CONFIDENCE` (not HIGH/MEDIUM),
`OVERPAYMENT`, `DEDUCTIONS_EXCEED_SHORT_PAY` → else `PROPOSED`. Deduction items must be `remittance_guide` DEDUCTION
terms (unknown ones are recorded in `ignored_items` and never used). The early-pay discount is recomputed from the
invoice terms on the payment's value date (`discount_pct` within `discount_days`); a claimed discount above that is
disputed as "not earned"; a short payment with no stated reason is `UNAPPLIED` and disputed. Disputed ≤
`small_balance_tolerance()` ($250) → written off; above → `review_amount`. `confirm_cash_application(application_id)`:
`NO_SUCH_APPLICATION`, `EXPIRED`, `ALREADY_APPLIED`, `INVOICES_CHANGED` → `APPLIED`: the posting trigger allocates
payment + earned discount + write-off to the invoices (oldest first), marks the application APPLIED, writes a
payment event and audit, and opens a `DEDUCTION_REVIEW` case parking `DEDUCTION_WRITE_OFF:<application>` for the
review amount (its brief = SQL facts + the agent's notes).

**Payments with verification of payee.** `check_payee_account(beneficiary_account, typed_name)` → `OK` with the name on
file (`payee_register`), `NOT_FOUND`. `propose_payment(from_account, beneficiary_account, typed_name, amount, purpose,
name_verdict, name_reasons, agent_notes)`: `ACCOUNT_NOT_FOUND`, `BENEFICIARY_NOT_FOUND`, `NAME_REQUIRED`,
`CURRENCY_MISMATCH`, `BAD_AMOUNT`, `OVER_CHANNEL_LIMIT` ($1,000,000) → else assessed by `payee_assessment`: verdict
validated (MATCH/CLOSE_MATCH/NO_MATCH), reasons validated against `payee_name_guide` REASON terms, deterministic
`name_similarity` (100 when the names are identical after the guide's own LEGAL_SUFFIX / ABBREVIATION /
TRANSLITERATION rows; else a character-pair Dice score). Band: score 100 → MATCH; agent MATCH and score ≥ 75 →
MATCH; agent NO_MATCH or score < 40 → NO_MATCH; else CLOSE_MATCH. MATCH → `PROPOSED`; CLOSE_MATCH ≤
`payee_hold_threshold()` ($10,000) → `PROPOSED_WITH_WARNING` (warning text names the account holder); CLOSE_MATCH above
it or NO_MATCH → `HELD_FOR_REVIEW` + `PAYEE_VERIFICATION` case parking `RELEASE_PAYMENT:<request>`. The client sees
the name check and the name on file, never the score or the agent's reasons. `confirm_payment(request_id,
acknowledge_warning)`: `NO_SUCH_REQUEST`, `HELD_FOR_REVIEW`, `CANCELLED`, `EXPIRED`, `WARNING_NOT_ACKNOWLEDGED`,
`ALREADY_SENT` → `SENT`: the release trigger creates the payment (INITIATED, value date from `cutoff_rules`).

**Reviewer loop.** `get_review_queue` (the team's OPEN cases by reply-due time; another team's cases never appear),
`get_review_case` (statement, AI brief marked unverified, facts from SQL, max approvable, own limit, options; another
team's case → `NOT_FOUND`), `decide_review_case(case_id, decision, amount, internal_note, customer_message)` →
`decide_case_row` returns 0 rows with a reason when blocked: `NOT_REVIEWER`, `NOT_FOUND`, `NOT_YOUR_TEAM`,
`ALREADY_DECIDED`, `INVALID_DECISION`, `NOTE_REQUIRED` (< 5 chars), `AMOUNT_INVALID` (≤ 0, above the eligible maximum,
or not the full amount for a recall / held payment), `OVER_AUTHORITY` (above the reviewer's approval limit; case stays
OPEN). The `review_decisions` trigger sets the case status + client message and runs the parked action through the
guarded rows: `fee_refund_row`, `recall_execute_row` (payment RECALLED), `payment_release_row` (payment submitted),
`deduction_writeoff_row` (invoice balance closed); REJECT cancels a held payment, restores a recalled payment's status,
leaves a deduction open; audit `CASE_DECIDED` (actor = reviewer).

email_my_confirmation(reference_id): INV- / CASE- / CAP- (applied) / PMT- (submitted through the assistant) of THIS
client → `SEND` (guarded `email_log` row, then the flow sends); else `NOT_SENT` (`NO_SUCH_REFERENCE`, `SESSION_INVALID`).

## Tables (names binding)

clients, accounts, reason_codes, cutoff_rules, payments (+ ordering_party, remittance_info, status_before_recall),
payment_events, reviewers (reviewer_id `AGB-NNNN`, display_name, team, one_time_code, approval_limit, active),
client_sessions (role CLIENT|REVIEWER), verify_attempts, reviewer_verify_attempts, pending_actions, investigations,
service_teams (+ label, client_openable), review_cases (+ currency, requested_amount, parked_action, status
OPEN|APPROVED|REJECTED, sla_due_at, customer_message, approved_amount, decided_at), review_decisions (insert-only),
decide_attempts, open_invoices, cash_applications (`CAP-NNNNN`), cash_postings, deduction_writeoffs (`WO-NNNNN`),
payee_register, payment_requests (`PRQ-NNNNN`), payment_releases, payment_recalls, fee_refunds,
remittance_guide, payee_name_guide (agent reference tables: section / term / meaning, no client data), agent_audit
(+ actor), email_log.

## Seed data (dates/times relative to CURRENT_DATE / now())

| Client | Passcode | Story |
|---|---|---|
| CLI-2026-00101 Northwind Manufacturing | 486201 | PMT-…01 SWIFT $250,000 IN_TRANSIT (trace); PMT-…02 SEPA €48,500 RETURNED AC04; PMT-…03 COMPLETED; PMT-…04 INITIATED 30 min ago (NOT_TRACEABLE); PMT-…05 past cutoff; **PMT-…13 INCOMING $46,728 from Harbor Retail Group** with "INV 4417/4425 LESS 2PCT EARLY PAY FRT DED 312.00"; open invoices 4398 (old), 4417 $30,000 and 4425 $18,000 (2/10 NET 30, 7 days old), 4431 $18,000, 4433 Summit $9,750; PMT-…14 $310,000 duplicate already RECALL_REQUESTED (CASE-00001) |
| CLI-2026-00102 Helios Trading | 730955 | PMT-…06 $780,000 wrong beneficiary (recall); PMT-…07 HELD (sanctions); PMT-…08 already under investigation; PMT-…15 INCOMING $61,850 from Coastal Grocers applied to invoice 7702 with a $3,150 damaged-goods deduction (CAP-00001, CASE-00004); open invoice 7715 |
| CLI-2026-00103 Veridian Foods | 615338 | PMT-…09 INCOMING (NOT_RECALLABLE); PMT-…10 $45 ACH fee (FEE_WAIVER); PMT-…11 completed 12 days ago; PRQ-00001 $42,500 to "new bank details" for Pacific Rim (CLOSE_MATCH over the threshold → HELD, CASE-00002) |
| CLI-2026-00104 Bramwell Logistics | 904177 | PMT-…12 COMPLETED with a $40 SWIFT fee (CASE-00003 fee waiver); pays ACME Corp (MATCH), Rotterdam Shipping BV "new bank details" (NO_MATCH → held), Atlas Freight (CLOSE_MATCH → warning) |

Reviewers: AGB-5001 Elena Park (Payment Operations, $250,000 — OVER_AUTHORITY on CASE-00001), AGB-5002 Marcus Webb
(Payment Operations, $2,000,000), AGB-5003 Sofia Alvarez (Client Servicing, $2,500 — OVER_AUTHORITY on CASE-00004).
Payee register: 4410028811 Acme Corporation Ltd, 7781200456 RD Global Trading LLC, 3390044127 Atlas Freight Forwarding
Inc, 5520019837 Pacific Rim Imports & Export LLC, DE44500105175407324931 Müller Logistik GmbH (EUR).

## MCP tools (22) — single source of truth `_rebuild/tool_spec.py`

Client: verify_client · get_my_payments · get_payment_status · get_payment_timeline · check_delivery_estimate ·
propose_trace · confirm_trace · propose_recall · confirm_recall · open_review_case · get_my_cases ·
email_my_confirmation · get_open_invoices · propose_cash_application · confirm_cash_application · check_payee_account ·
propose_payment · confirm_payment. Reviewer: verify_reviewer · get_review_queue · get_review_case · decide_review_case.
Hints: reads `readOnlyHint=true`; `decide_review_case` `destructiveHint=false`, `idempotentHint=false`.

## A2A agents (CorporatePaymentsAgents) — read-only, no identity, one PostgreSQL reference tool each

| Agent | Port | Input from the orchestrator | Tool (SQL) | Returns |
|---|---|---|---|---|
| `payment_triage_agent` (kept) | 9873 | the client's words + candidate payments (ref, direction, rail, amount, currency, beneficiary, status, return code, dates) | `lookup_reason_code(code)` → `reason_codes` | payment_ref, decoded reason, issue + urgency, next step or the one question |
| `remittance_match_agent` | 9874 | the remittance note + the incoming amount/currency/value date + candidate open invoices (number, buyer, date, open amount, terms) | `get_remittance_guide(term)` → `ref_remittance_guide` (DEDUCTION, NOTE_PATTERN, MATCH_RULE, CONFIDENCE, REVIEW_LINE, WHO_DECIDES from `service_teams`) | invoices, deductions (guide terms + amounts), confidence, explanation, review_note (verbatim table line) |
| `payee_name_match_agent` | 9875 | the typed beneficiary name + the name on file, nothing else | `get_payee_name_rules(term)` → `ref_payee_name_rules` (VERDICT, REASON, LEGAL_SUFFIX, ABBREVIATION, TRANSLITERATION, WHO_DECIDES) | verdict, reasons, explanation, verdict_note (verbatim table line) |

The deduction codes, confidence levels, verdict codes and reason codes are not in the prompts (only in the tables),
so each answer depends on the tool. SQL validates every agent answer that drives a decision (`cash_assessment`,
`payee_assessment`); `payee_name_norm` uses the same guide rows, so agent and SQL share one rule set.

## Orchestrator rules (prompt explains; SQL decides) — `_rebuild/orchestrator_prompt.txt`

Two personas (client verify / staff verify; the role only from the verify tool). Verify first; LOCKED → recovery
only. Investigations → payment_triage_agent → propose/confirm trace or recall (a recall is a request a person
decides). Cash application → get_my_payments + get_open_invoices → remittance_match_agent → propose (agent lines
passed unchanged) → read back → explicit yes → confirm → case for disputed deductions. New payment →
check_payee_account → payee_name_match_agent (two names only) → propose → PROPOSED / warning word for word /
HELD (no scores, no reasons) → explicit yes → confirm. Human-owned requests → open_review_case with reference_id.
Reviewer flow → queue → case (brief presented neutrally, marked AI-prepared) → decision + note + client message →
restate → explicit "confirm" → decide → report truthfully (OVER_AUTHORITY = needs a senior reviewer). Agents never
receive the client's legal name, ids, account numbers or tokens. Per-connection conversationId from Sec-Websocket-Key.

## Acceptance (test ladder)

Step 1 SQL (`test_rules.py`): every reason code above, scoping, two-step expiry + ALREADY_*, delivery arithmetic,
the cash split (earned / unearned discount, unapplied, tolerance), the name-check matrix, every reviewer reason code
with DB effects (recall executed / declined, payment released / cancelled, deduction written off, fee refunded),
minimum-necessary outputs, audit, and the agents' reference tables (rows, lookups, no personal data, SELECT-only).
Step 2: validate_flogo_apps.py + validate_governed_apps.py --local + `fda cm` clean on all three apps.
Step 3: mcp_smoke (all 22 tools incl. reviewer tools), a2a_smoke (each agent's tool queried PostgreSQL; table-only
text in the answer), ws_smoke.
Step 4 chat e2e (DB assertions): Northwind flagship, Helios recall + sanctions, Veridian NOT_RECALLABLE, Northwind
cash application (+ self-approval injection), Bramwell MATCH payment + NO_MATCH hold, cross-client injection,
confirm-without-propose, the Client Servicing reviewer approving the deduction on a separate connection, the client
reconnecting to see the outcome, minimisation of every agent input and each agent's PostgreSQL read.
