# Retail Banking Assistant — governed spec (Kestrel Bank)

Governed rebuild of `Industry_Use_Cases_old/Retail_Banking_Assistant_Use_Case` with the
`agentic-ai-use-case-builder` skill. Reference implementation to mirror file-for-file:
`Industry_Use_Cases/Airline_Passenger_Services_Use_Case/` (database.sql / seed_data.sql / reset_data.sql /
_rebuild/*.py). Kestrel Bank, its customers, accounts and merchants are fictional.

## Identity, apps, ports

| Item | Value |
|---|---|
| Persona | Retail customer of **Kestrel Bank** self-serving over chat (USD, en-US) |
| Database | `banking_governed` (original `banking` DB untouched) |
| Orchestrator | `RetailBankingAIOrchestrator.flogo` — WebSocket `9860` path `/retailbanking` |
| MCP server | `RetailBankingMCPServer.flogo` — MCP `9862` path `/retail-banking-mcp`, serverName `RetailBanking` |
| A2A agents | `RetailBankingAgents.flogo` — `dispute_triage_agent` on `9863` |
| Runtime LLM | `gpt-5.5` (property `LLM_Model`) |
| Email | Gmail SMTP 465 SSL; `Email_Username`, `Email_App_Password` (SECRET), `To_Email` (ops inbox) — same as Airline |

## Decision-framework classification

| Operation | Q1 human? | Q2 semantic? | Owner | Implemented as |
|---|---|---|---|---|
| Verify customer | no | no | Deterministic | `verify_customer` (customer_id + 6-digit passcode) → session token 30 min; 5 wrong → 15-min lock |
| Own accounts / transactions / cards / loans / cases | no | no | Deterministic | scoped reads `FROM my_x(token)` |
| Branch lookup | no | no | Deterministic | `find_branch(city)` (public data, no token) |
| Block lost/stolen card | no | no | Deterministic, two-step | `propose_card_block` → yes → `confirm_card_block` (card_blocks event + trigger: BLOCKED + replacement) |
| Dispute eligibility, provisional credit, decision date | no | no | Deterministic, two-step | `propose_dispute` → yes → `confirm_dispute` (disputes event + trigger) |
| Decode a cryptic descriptor, match the customer's words to a transaction, suggest reason code | no | **yes** | **Agent** | `dispute_triage_agent` (A2A, read-only `lookup_merchant`), never receives identity |
| Fee refund, loan hardship/deferral, credit-limit increase, complaint, personal-details change, account closure, bereavement, fraud review | **yes** | – | Human | `open_service_case` → `service_teams`; FRAUD_REVIEW also auto-opened by trigger |

## Rules (reason codes) — all in SQL

Session: `SESSION_INVALID` (unknown/expired token) on every scoped tool.

verify: `VERIFIED` / `NOT_VERIFIED` / `LOCKED` (5 failures in 15 min → locked; no token while locked).

propose_card_block(card, reason) — `card` = card_id (`CARD-9001`) or last 4 digits (`1123`):
- `CARD_NOT_FOUND` (no card of THIS customer matches), `ALREADY_BLOCKED`, `CARD_EXPIRED`,
  `BAD_REASON` (reason not in LOST | STOLEN | DAMAGED | SUSPECTED_FRAUD) → otherwise `PROPOSED`.
confirm_card_block(action_id): `NO_SUCH_PROPOSAL` (not this customer / wrong type), `EXPIRED` (>15 min),
`ALREADY_EXECUTED`, rules re-checked → `EXECUTED` with block_id `BLK-NNNNN`, replacement card delivery date
= `add_business_days(current_date, 5)`.

propose_dispute(transaction_id, reason_code, customer_statement):
- `NOT_YOUR_TRANSACTION` (absent or another customer's), `NOT_A_DEBIT`, `PENDING_NOT_POSTED`,
  `OUTSIDE_WINDOW` (txn_date older than 120 days), `ALREADY_DISPUTED` (an OPEN/UNDER_REVIEW dispute exists),
  `BAD_REASON` (not in UNRECOGNISED | FRAUD | DUPLICATE | NOT_RECEIVED | NOT_AS_DESCRIBED | CANCELLED_RECURRING | WRONG_AMOUNT),
  `NOT_DUPLICATE` (reason DUPLICATE but no other POSTED debit of the same customer, same merchant, same amount within 3 days)
  → otherwise `PROPOSED` with: amount, merchant, provisional_credit (= amount when reason ∈ {UNRECOGNISED, FRAUD,
  NOT_RECEIVED, DUPLICATE} AND amount ≤ 500.00, else 0), fraud_review (reason ∈ {UNRECOGNISED, FRAUD} OR amount > 1000),
  est_decision_date = `add_business_days(current_date, 10)`.
confirm_dispute(action_id): `NO_SUCH_PROPOSAL`, `EXPIRED`, `ALREADY_EXECUTED`, rules re-checked → `FILED` with
dispute_id `DSP-2026-NNNN` (sequence, starts after seeded 0001). Trigger on disputes insert:
- provisional_credit > 0 → INSERT a `CREDIT` / `PENDING` transaction "PROVISIONAL CREDIT <dispute_id>" on the same account;
- fraud_review → INSERT service_cases row `FRAUD_REVIEW` (team Fraud Operations, statement = customer_statement,
  brief = system text with dispute_id/amount/reason);
- audit rows.

open_service_case(request_type, customer_statement, brief): `BAD_TYPE` or `CASE_OPENED` with case_id `CASE-NNNNN`,
team, reply_within (business days). Types → teams:

| request_type | team | reply (business days) |
|---|---|---|
| FEE_REFUND | Customer Care | 2 |
| LOAN_HARDSHIP | Financial Support | 1 |
| CREDIT_LIMIT_INCREASE | Credit Risk | 3 |
| COMPLAINT | Complaints Resolution | 2 |
| PERSONAL_DETAILS_CHANGE | Identity & Account Servicing | 2 |
| ACCOUNT_CLOSURE | Identity & Account Servicing | 2 |
| BEREAVEMENT | Bereavement Support | 1 |
| FRAUD_REVIEW | Fraud Operations | 1 |
| OTHER | Customer Care | 3 |

email_my_confirmation(reference_id): reference = a `DSP-…` or `BLK-…` of THIS customer → `SEND` with subject/body
built by SQL; else `NOT_SENT` + reason (`NO_SUCH_REFERENCE`, `SESSION_INVALID`). Sends to the configured `To_Email`.

## Tables (sketch — names are binding, columns indicative)

customers(customer_id PK `CUST-2026-NNNNN`, first_name, last_name, phone, email, passcode_hash or passcode, created_at)
accounts(account_id PK `ACC-NNNN`, customer_id FK, account_number_masked, account_type CHECKING|SAVINGS|CREDIT, balance, available_balance, currency, status)
cards(card_id PK `CARD-NNNN`, customer_id FK, account_id FK, last4, card_number_masked, card_type DEBIT|CREDIT, network, status ACTIVE|BLOCKED|EXPIRED, expiry DATE, credit_limit)
transactions(transaction_id PK `TXN-NNNNN`, account_id FK, customer_id FK, card_id FK NULL, txn_date DATE, descriptor, amount NUMERIC, txn_type DEBIT|CREDIT, category, status POSTED|PENDING)
loans(loan_id PK, customer_id FK, loan_type HOME|AUTO|PERSONAL, principal, outstanding_balance, interest_rate, monthly_payment, next_due_date, status)
branches(branch_id, branch_name, address, city, state, zip, phone, hours) — 5 rows as the original
merchant_directory(descriptor_prefix, merchant_name, category, billing_model ONE_OFF|RECURRING, support_contact, notes) — ~10 rows
customer_sessions(session_token, customer_id, created_at, expires_at) · verify_attempts(customer_id, ok, at)
pending_actions(action_id `ACT-XXXXXXXX`, action_type CARD_BLOCK|DISPUTE, customer_id, card_id, transaction_id, reason_code, customer_statement, amount, provisional_credit, fraud_review, created_at, expires_at)
card_blocks(block_id `BLK-NNNNN`, action_id UNIQUE, card_id, reason, created_at) + trigger → cards.status, card_replacements
card_replacements(card_id, ordered_at, expected_delivery)
disputes(dispute_id `DSP-2026-NNNN`, action_id UNIQUE NULL, customer_id, transaction_id, reason_code, customer_statement, amount, provisional_credit, status OPEN|UNDER_REVIEW|RESOLVED, est_decision_date, created_at) + trigger
service_teams(request_type PK, team, reply_business_days) · service_cases(case_id `CASE-NNNNN`, customer_id, request_type, customer_statement, agent_brief, assigned_team, status, created_at)
agent_audit(id, at, customer_id, action VERIFY|CARD_BLOCK_PROPOSED|CARD_BLOCKED|DISPUTE_PROPOSED|DISPUTE_FILED|SERVICE_CASE_OPENED, ref, detail) — triggers only; no MCP tool exposes it
helper: add_business_days(date, int) skips Sat/Sun.

Lessons carried from Airline: make the session resolver **plpgsql** (not inlinable SQL); placeholders never repeat
within one statement (write `?w_*`, read `?r_*`); `CAST(?p AS text)` always; the optional transaction `search`
arg is handled inside `my_transactions(tok, search)` (empty string = all, last 120 days, newest first, max 25).

## Seed data (dates relative to CURRENT_DATE)

| Customer | Passcode | Story |
|---|---|---|
| CUST-2026-00101 James Miller | 482913 | ACC-1001 CHECKING $4,250.75, ACC-1002 SAVINGS $18,500; CARD-9001 DEBIT VISA ACTIVE ••1123; LOAN-3001 HOME. **TXN-50003 `QUICKPAY*XYZ 872-555` $249.99** POSTED 6 days ago (flagship UNRECOGNISED → provisional credit + FRAUD_REVIEW); TXN-50013 `QUICKPAY*XYZ 872-555` $18.75 (ambiguity by amount); a PENDING debit (PENDING_NOT_POSTED); a 150-day-old debit (OUTSIDE_WINDOW); payroll CREDIT (NOT_A_DEBIT) |
| CUST-2026-00102 Olivia Davis | 730516 | CARD-9002 CREDIT MC; **`STRMPLS*MEMBERSHIP 888-555` $15.99** 3 days ago (directory: StreamPlus, RECURRING → CANCELLED_RECURRING, no provisional credit); `OVERDRAFT FEE` $35.00 → FEE_REFUND human case; LOAN-3002 PERSONAL |
| CUST-2026-00103 William Garcia | 615204 | CARD-9003 DEBIT; **`LUXEJET TRAVEL 800-555` $1,850.00** → UNRECOGNISED: no provisional credit (> $500), FRAUD_REVIEW (> $1,000) |
| CUST-2026-00104 Sophia Martinez | 559371 | CARD-9004 CREDIT; TXN-50009 `GLOBAL*DIGITAL 900-555` $129 with seeded **DSP-2026-0001 OPEN** (ALREADY_DISPUTED); `CAFE LUMEN` $8.40 single (NOT_DUPLICATE); `ACME HARDWARE #212` $64.10 twice same day (valid DUPLICATE) |
| CUST-2026-00105 Benjamin Lee | 204867 | CARD-9005 **BLOCKED** (ALREADY_BLOCKED); LOAN-3003 AUTO → LOAN_HARDSHIP human case |
| CUST-2026-00106 Emma Johnson | 918342 | two accounts, CARD-9006 ACTIVE (plain) |
| CUST-2026-00107 Michael Brown | 377150 | CARD-9007 CREDIT **EXPIRED** (CARD_EXPIRED) |

Merchant directory must decode at least: `QUICKPAY*XYZ` (XYZ Gadgets Online, electronics web store, ONE_OFF, via the
QuickPay processor), `STRMPLS*` (StreamPlus video streaming, RECURRING monthly), `GLOBAL*DIGITAL` (Global Digital
Media app store, ONE_OFF), `LUXEJET` (LuxeJet Travel, flights/holidays, ONE_OFF), `ACME HARDWARE`, `CAFE LUMEN`,
plus a few distractors (`SQ *`, `AMZN MKTP`-style generic — fictional names).

## MCP tools (13) — single source of truth `_rebuild/tool_spec.py`

verify_customer(customer_id, passcode) · get_my_accounts(session_token) · get_my_transactions(session_token, search) ·
get_my_cards(session_token) · get_my_loans(session_token) · find_branch(city) · propose_card_block(session_token, card, reason) ·
confirm_card_block(session_token, action_id) · propose_dispute(session_token, transaction_id, reason_code, customer_statement) ·
confirm_dispute(session_token, action_id) · open_service_case(session_token, request_type, customer_statement, brief) ·
get_my_cases(session_token) (disputes + service cases) · email_my_confirmation(session_token, reference_id)

## A2A agent — `dispute_triage_agent` (RetailBankingAgents, :9863)

Input from the orchestrator: the customer's own words + the candidate transactions (transaction_id, descriptor, amount,
date only). Never name, customer_id, account number, token. Tool: `lookup_merchant(descriptor)` → merchant_directory
rows (read-only, no identity). Returns: the best-matching transaction_id, who the merchant really is and how it bills,
a recommended reason_code from the fixed list (or the ONE question to ask when it hinges on "did you cancel vs never
sign up"), and whether a card block is advisable (fraud signals). It never files, approves or promises anything.

## Orchestrator rules (prompt explains; SQL decides)

Verify first; never reveal/guess passcodes; LOCKED → recovery only. Disputes: get_my_transactions(search) →
dispute_triage_agent → tell the customer who the merchant is → propose_dispute → read back amount / provisional credit /
decision date exactly as returned → explicit yes → confirm_dispute. After an UNRECOGNISED/FRAUD filing, offer to block
the card (two-step). Human-owned requests → open_service_case, give case id + team + reply time, never decide/promise.
Out of scope (loan approval, investment/tax/legal advice, external payments/wires) → decline politely. Says it is an AI
when asked. Never reveal internal tool names, call history or audit. Per-connection conversationId from Sec-Websocket-Key.

## Acceptance (test ladder)

Step 1 SQL: every reason code above has a passing case; scoping (James cannot see/dispute Sophia's txn); two-step
expiry; trigger effects (card BLOCKED + replacement; provisional credit row; FRAUD_REVIEW case; audit rows); lockout.
Step 2: validate_governed_apps.py --local (G1–G9) + `fda cm` clean on all three apps.
Step 3: MCP smoke of all 13 tools incl. edge cases; direct A2A JSON-RPC call to :9863; WebSocket connect.
Step 4 chat e2e (DB-state assertions): James flagship (verify → decode QUICKPAY → dispute filed with provisional
credit + FRAUD_REVIEW → block CARD-9001 → email SEND), Olivia (CANCELLED_RECURRING + FEE_REFUND case), Benjamin
(ALREADY_BLOCKED + LOAN_HARDSHIP), Sophia (NOT_DUPLICATE), cross-customer injection refused, confirm-without-propose
refused, "are you a human?" → AI, out-of-scope loan approval declined.
