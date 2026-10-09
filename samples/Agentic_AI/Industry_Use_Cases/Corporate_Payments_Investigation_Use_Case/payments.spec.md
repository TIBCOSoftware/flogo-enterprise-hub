# Corporate Payment Investigation & Status — governed spec (Aurelia Global Bank)

Built with the `agentic-ai-use-case-builder` skill (governed, FDA-CLI method). Reference implementation to
mirror file-for-file: `Industry_Use_Cases/Airline_Passenger_Services_Use_Case/` and
`Industry_Use_Cases/Retail_Banking_Assistant_Use_Case/` (database.sql / seed_data.sql / reset_data.sql /
_rebuild/*.py). Aurelia Global Bank, its clients, accounts, beneficiaries and payments are fictional.

**Why this applies to every large bank:** retail, commercial and transaction-banking institutions all run
high-value and cross-border payments; "where is my payment, why was it returned/held, trace it, recall it" is
the universal servicing pain. The AI reads the client's free text and decodes cryptic return-reason codes; the
database decides identity, scope, eligibility, delivery estimates and every state change; people own money
reversals and compliance.

## Identity, apps, ports

| Item | Value |
|---|---|
| Persona | An authorised user at a **corporate client** of Aurelia Global Bank (treasury / accounts-payable), self-serving over chat |
| Database | `payments_governed` |
| Orchestrator | `CorporatePaymentsAIOrchestrator.flogo` — WebSocket `9870` path `/corporatepayments` |
| MCP server | `CorporatePaymentsMCPServer.flogo` — MCP `9872` path `/corporate-payments-mcp`, serverName `CorporatePayments` |
| A2A agents | `CorporatePaymentsAgents.flogo` — `payment_triage_agent` on `9873` |
| Runtime LLM | `gpt-5.5` (property `LLM_Model`) |
| Email | Gmail SMTP 465 SSL; `Email_Username`, `Email_App_Password` (SECRET), `To_Email` (ops inbox) — reuse Airline creds |

## Decision-framework classification

| Operation | Q1 human? | Q2 semantic? | Owner | Implemented as |
|---|---|---|---|---|
| Verify the user | no | no | Deterministic | `verify_client` (client_id + 6-digit passcode) → session token 30 min; 5 wrong → 15-min lock |
| See only the client's own payments / cases | no | no | Deterministic, scoped | scoped reads `FROM my_x(token)` |
| Payment status, rail, FX, fees, decoded return reason | no | no | Deterministic | rule functions; LLM quotes verbatim |
| Will it settle by the cutoff / SLA | no | no | Deterministic **arithmetic** | `delivery_estimate` from `cutoff_rules` (never guessed) |
| Raise a trace / investigation on a delayed payment | no | no | Deterministic, **two-step** | `propose_trace` → yes → `confirm_trace` (investigations + trigger) |
| Recall / return a payment (money reversal) | **yes** | no | Human, **two-step** | `propose_recall` → yes → `confirm_recall` opens a **Payment Ops review case** (trigger); the assistant never reverses money |
| Decode a return/reason code, classify the free-text issue + urgency, recommend trace vs recall | no | **yes** | **Agent** | `payment_triage_agent` (A2A, read-only `lookup_reason_code`), never receives identity |
| Fee waivers, compensation, suspected fraud, sanctions queries, payment repair | **yes** | – | Human | `open_review_case` → `service_teams` |

## Rules (reason codes) — all in SQL

Session: `SESSION_INVALID` (unknown/expired token) on every scoped tool.
verify: `VERIFIED` / `NOT_VERIFIED` / `LOCKED` (5 failures in 15 min → locked; no token while locked).

get_payment_status(payment_ref): `NOT_YOUR_PAYMENT` (absent or another client's) → else a status row:
direction, rail, amount, currency, fx_rate, fees, beneficiary_name, beneficiary_bank, status
(INITIATED|IN_TRANSIT|COMPLETED|RETURNED|HELD|RECALL_REQUESTED|RECALLED), decoded return reason when RETURNED,
value_date, created_at.

check_delivery_estimate(payment_ref): `NOT_YOUR_PAYMENT` → else computes from `cutoff_rules` (rail+currency →
cutoff hour, settlement_days, business-day aware): returns `ON_TRACK` / `PAST_CUTOFF` (missed today's cutoff) /
`DELAYED` (past expected settlement, still not COMPLETED) / `SETTLED`, with the expected settlement date.

propose_trace(payment_ref, reason_code, client_statement):
- `NOT_YOUR_PAYMENT`, `NOT_TRACEABLE` (created < 2 hours ago — too soon; or status INITIATED),
  `ALREADY_UNDER_INVESTIGATION` (an OPEN investigation exists), `BAD_REASON` (reason_code not in the directory)
  → else `PROPOSED` with amount, beneficiary, decoded reason, est_response_date = `add_business_days(current_date, 3)`.
confirm_trace(action_id): `NO_SUCH_PROPOSAL` / `EXPIRED` (>15 min) / `ALREADY_EXECUTED`, rules re-checked →
`OPENED` with investigation_id `INV-2026-NNNN`. Trigger: audit + a payment_event "INVESTIGATION OPENED".

propose_recall(payment_ref, reason_code, client_statement):
- `NOT_YOUR_PAYMENT`, `NOT_RECALLABLE` (direction INCOMING, or status RETURNED/RECALLED/RECALL_REQUESTED, or
  COMPLETED more than 5 business days ago), `ALREADY_RECALL_REQUESTED`, `BAD_REASON`
  → else `PROPOSED` with a clear note: a recall is a **request** subject to the beneficiary bank and a human
  reviewer; it is **not** guaranteed and does not reverse funds automatically.
confirm_recall(action_id): `NO_SUCH_PROPOSAL` / `EXPIRED` / `ALREADY_EXECUTED`, rules re-checked → `SUBMITTED`:
sets the payment to RECALL_REQUESTED and (trigger) opens a **review_case** `RECALL` routed to **Payment Operations**,
returning the case_id; audit rows. The assistant states a person will decide.

open_review_case(request_type, client_statement, brief): `BAD_TYPE` or `CASE_OPENED` with case_id `CASE-NNNNN`,
team, reply_within (business days). Types → teams:

| request_type | team | reply (business days) |
|---|---|---|
| RECALL | Payment Operations | 1 |
| PAYMENT_REPAIR | Payment Operations | 1 |
| FEE_WAIVER | Client Servicing | 2 |
| COMPENSATION | Client Servicing | 2 |
| FRAUD | Financial Crime | 1 |
| SANCTIONS_QUERY | Sanctions & Compliance | 2 |
| OTHER | Client Servicing | 3 |

email_my_confirmation(reference_id): reference = an `INV-…` or `CASE-…` of THIS client → `SEND` with subject/body
built by SQL; else `NOT_SENT` + reason (`NO_SUCH_REFERENCE`, `SESSION_INVALID`). Sends to the configured `To_Email`.

Reads: get_my_payments(session_token, search) (empty = recent 90 days, newest first, max 25; non-empty searches
ref/beneficiary/amount back 18 months), get_payment_timeline(session_token, payment_ref) (GPI-style events),
get_my_cases(session_token) (investigations UNION review cases).

## Tables (sketch — names binding, columns indicative)

clients(client_id PK `CLI-2026-NNNNN`, legal_name, contact_email, passcode_hash, created_at)
accounts(account_id PK `ACC-NNNN`, client_id FK, account_number_masked, currency)
payments(payment_ref PK `PMT-2026-NNNNNN`, client_id FK, debtor_account FK, direction OUTGOING|INCOMING, rail
SWIFT|SEPA|FEDWIRE|FASTER_PAYMENTS|ACH, amount NUMERIC, currency, fx_rate NUMERIC NULL, fees NUMERIC,
beneficiary_name, beneficiary_bank_bic, status, return_reason_code NULL, value_date DATE, created_at TIMESTAMP)
payment_events(id, payment_ref FK, event_time, actor (agent bank/system), action, detail) — GPI-style timeline
reason_codes(code PK, rail, plain_language, category BENEFICIARY|COMPLIANCE|TECHNICAL|ACCOUNT|OTHER, typical_action)
cutoff_rules(rail, currency, cutoff_hour INT, settlement_days INT, PRIMARY KEY(rail,currency))
client_sessions(session_token, client_id, created_at, expires_at) · verify_attempts(client_id, ok, at)
pending_actions(action_id `ACT-XXXXXXXX`, action_type TRACE|RECALL, client_id, payment_ref, reason_code,
client_statement, created_at, expires_at, confirm_count, executed_no)
investigations(investigation_id `INV-2026-NNNN`, action_id UNIQUE NULL, client_id, payment_ref, reason_code,
client_statement, status OPEN|UNDER_REVIEW|RESOLVED, est_response_date, created_at) + trigger
review_cases(case_id `CASE-NNNNN`, client_id, request_type, payment_ref NULL, client_statement, agent_brief,
assigned_team, status, created_at) + recall trigger
service_teams(request_type PK, team, reply_business_days)
agent_audit(id, at, client_id, action VERIFY|TRACE_PROPOSED|TRACE_OPENED|RECALL_PROPOSED|RECALL_SUBMITTED|REVIEW_CASE_OPENED, ref, detail) — triggers only; no MCP tool exposes it
helpers: add_business_days(date,int); session_client(token) plpgsql STABLE; passcode_hash(id,code).

Lessons carried: session resolver is **plpgsql** (not inlinable SQL); placeholders never repeat within one
statement (`?w_*` write / `?r_*` read); always `CAST(?p AS text)`; the optional `search` arg handled inside
`my_payments(tok, search)`.

## Seed data (dates/times relative to CURRENT_DATE / now())

| Client | Passcode | Story |
|---|---|---|
| CLI-2026-00101 Northwind Manufacturing | 486201 | PMT-…01 OUTGOING SWIFT USD $250,000 **IN_TRANSIT** created 3 days ago (trace); PMT-…02 OUTGOING SEPA EUR €48,500 **RETURNED** reason `AC04` (account closed) 2 days ago; PMT-…03 OUTGOING FEDWIRE USD $12,000 **COMPLETED** (SETTLED); PMT-…04 OUTGOING SWIFT GBP £90,000 created today 30 min ago **INITIATED** (NOT_TRACEABLE); PMT-…05 OUTGOING SWIFT USD past expected settlement, still IN_TRANSIT (**DELAYED** / PAST_CUTOFF) |
| CLI-2026-00102 Helios Trading | 730955 | PMT-…06 OUTGOING SWIFT USD $780,000 IN_TRANSIT to the **wrong beneficiary** (recall → human Payment Ops); PMT-…07 OUTGOING SWIFT USD **HELD** (sanctions screening) → SANCTIONS_QUERY human; PMT-…08 already has an OPEN investigation (ALREADY_UNDER_INVESTIGATION) |
| CLI-2026-00103 Veridian Foods | 615338 | PMT-…09 **INCOMING** SEPA EUR (recall attempt → NOT_RECALLABLE); PMT-…10 OUTGOING with an unexpected `fees` charge → FEE_WAIVER human; a COMPLETED > 5 business days ago (recall → NOT_RECALLABLE) |
| CLI-2026-00104 Barco Logistics | 904177 | a clean COMPLETED payment; used for cross-client scoping (Northwind must not see/trace Barco's PMT) |

reason_codes directory must decode at least: `AC04` (account closed), `AC06` (account blocked), `BE01`
(beneficiary name/account mismatch), `AM05` (duplicate payment), `RR04` (regulatory/compliance),
`MS03` (reason not specified), `RC01` (bank identifier incorrect) — each with plain_language, category, typical_action.
cutoff_rules: at least SWIFT/USD (cutoff 16, T+1), SEPA/EUR (15, T+0), FEDWIRE/USD (18, same-day),
FASTER_PAYMENTS/GBP (immediate, T+0), ACH/USD (17, T+2).

## MCP tools (12) — single source of truth `_rebuild/tool_spec.py`

verify_client(client_id, passcode) · get_my_payments(session_token, search) · get_payment_status(session_token,
payment_ref) · get_payment_timeline(session_token, payment_ref) · check_delivery_estimate(session_token,
payment_ref) · propose_trace(session_token, payment_ref, reason_code, client_statement) · confirm_trace(session_token,
action_id) · propose_recall(session_token, payment_ref, reason_code, client_statement) · confirm_recall(session_token,
action_id) · open_review_case(session_token, request_type, client_statement, brief) · get_my_cases(session_token) ·
email_my_confirmation(session_token, reference_id)

## A2A agent — `payment_triage_agent` (CorporatePaymentsAgents, :9873)

Input from the orchestrator: the client's own words + the candidate payments (payment_ref, direction, rail,
amount, currency, beneficiary_name, status, return_reason_code, value_date, created_at only). Never legal name,
client_id, account number or token. Tool: `lookup_reason_code(code)` → reason_codes rows (read-only, no identity).
Returns: the best-matching payment_ref, the return/reason code decoded into plain language, the issue classified
(e.g. RETURNED_ACCOUNT_ISSUE / WRONG_BENEFICIARY / DELAYED_IN_TRANSIT / COMPLIANCE_HOLD / DUPLICATE) with an
urgency, and a recommended next step (raise a trace, request a recall, or open a human review case) — or the ONE
question to ask when it hinges on intent (e.g. "did the funds reach the wrong party, or not arrive at all?").
It never traces, recalls, files, approves or promises anything.

## Orchestrator rules (prompt explains; SQL decides)

Verify first (client id + 6-digit passcode); never reveal/guess passcodes; LOCKED → recovery only. Investigations:
get_my_payments(search) → payment_triage_agent (client words + candidate payment facts only, no identity) → tell
the client what the return/reason code means and the recommended step → for a delayed/missing payment propose_trace
→ read back amount/beneficiary/decoded reason/est response date exactly as returned → explicit yes → confirm_trace.
For a wrong-beneficiary or erroneous payment, propose_recall → make clear a recall is a request a person decides and
funds are not auto-reversed → explicit yes → confirm_recall (opens a Payment Ops review case). Human-owned requests
(fee waiver, compensation, fraud, sanctions query, payment repair) → open_review_case with a neutral brief; give
case id + team + reply time; never decide/promise/predict. Delivery estimates and fees come only from tools, quoted
verbatim — never computed in the prompt. email_my_confirmation only when asked and only with an INV-/CASE- reference.
Explain NOT_* outcomes using the returned reason, never override them. Honest that it is an AI. Never reveal internal
tool names, call history or audit. USD/EUR/GBP formatting per the payment. Per-connection conversationId from
Sec-Websocket-Key.

## Acceptance (test ladder)

Step 1 SQL: every reason code above has a passing case; scoping (Northwind cannot see/trace/recall Barco's payment);
two-step expiry + ALREADY_EXECUTED; delivery-estimate arithmetic (ON_TRACK/PAST_CUTOFF/DELAYED/SETTLED); trigger
effects (investigation opened + payment_event; recall → RECALL_REQUESTED + Payment Ops review case; audit rows);
lockout; reason-code decode; email payload SEND/NOT_SENT.
Step 2: validate_governed_apps.py --local (G1–G9) + `fda cm` clean on all three apps.
Step 3: MCP smoke of all 12 tools incl. edge cases; direct A2A JSON-RPC call to :9873; WebSocket connect.
Step 4 chat e2e (DB-state assertions): Northwind flagship (verify → decode AC04 return → propose/confirm trace on
the IN_TRANSIT payment → email), Helios (wrong-beneficiary → two-step recall → Payment Ops review case; sanctions
HELD → SANCTIONS_QUERY case), Veridian (incoming → NOT_RECALLABLE; fee → FEE_WAIVER case), cross-client injection
refused, confirm-without-propose refused, "are you a human?" → AI, delivery estimate not computed in chat.
