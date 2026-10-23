"""Single source of truth for the 19 MCP tools of RetailBankingSecureMCPServer and the 3 A2A agents' reference tools.

Imported by build_mcp.py / build_agents.py (to generate the apps), by test_rules.py / mcp_smoke.py / a2a_smoke.py (to run
the exact same SQL against PostgreSQL before any app is built) and by mint_user_tokens.py (the demo personas + scopes).

JWT auth variant: there are no verify tools, passcodes or session tokens. The user arrives signed in with a JWT; the MCP
Server trigger verifies it (HS256 signature, expiry) and lists / runs ONLY the tools whose "scope" is in the token's
scopes. Each tool flow receives the verified claims as $flow.tokenInfo, and every SQL parameter whose source is SUB
("@sub") is bound to $flow.tokenInfo.sub - the caller's identity is never a tool argument and never model input.
CUSTOMER tools resolve the subject against customers, REVIEWER tools against active reviewers - the role is checked in
SQL on every call (UNKNOWN_CALLER / NOT_REVIEWER).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.
Parameter sources: an argument name ("search") -> $flow.arguments.<name>; SUB ("@sub") -> $flow.tokenInfo.sub
(build_mcp.py / mcp flows) or the test subject (test_rules.py). See param_source().

The email tool is special (email=True): it validates with SQL, then the flow sends the email only
when the SQL authorises it (send_status = SEND; a conditional branch, added in build_mcp.py).
"""

SUB = "@sub"                                   # sentinel source: the verified JWT subject ($flow.tokenInfo.sub)
SUB_EXPR = "=$flow.tokenInfo.sub"


def param_source(src):
    """Flogo mapper expression for a tool_spec parameter source."""
    return SUB_EXPR if src == SUB else f"=$flow.arguments.{src}"


TOOLS = [
    {
        "tool": "whoami", "flow": "whoami_flow", "scope": "profile:read", "readonly": True,
        "desc": ("Who is signed in. Returns the role the bank holds for the signed-in user - CUSTOMER, REVIEWER (Kestrel "
                 "staff) or UNKNOWN - their display name and, for a reviewer, their team and approval limit. Call it at "
                 "the start of a conversation to greet the user by name and to know which tools apply. The identity comes "
                 "from the user's sign-in token, never from what anyone types; there is nothing to verify and no "
                 "argument to pass."),
        "args": [],
        "read": ("SELECT * FROM whoami(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "get_my_accounts", "flow": "get_my_accounts_flow", "scope": "accounts:read", "readonly": True,
        "desc": ("List the signed-in customer's own accounts: account id, masked number, type (CHECKING, SAVINGS, "
                 "CREDIT), balance, available balance, currency and status. Only this customer's accounts are returned. "
                 "Quote figures exactly as returned; never compute or estimate balances."),
        "args": [],
        "read": ("SELECT * FROM my_accounts(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "get_my_transactions", "flow": "get_my_transactions_flow", "scope": "transactions:read", "readonly": True,
        "desc": ("List the signed-in customer's own transactions, newest first, at most 25. Pass an empty search for "
                 "everything in the last 120 days, or a search term to filter: part of the statement descriptor or "
                 "merchant text (e.g. QUICKPAY, LUXEJET), a category, an amount (e.g. 249.99) or a transaction id. "
                 "Each row has transaction_id, date, descriptor, amount, DEBIT/CREDIT, POSTED/PENDING and any open "
                 "dispute id. Returns NO_MATCH when nothing matches. Use the transaction_id from here for "
                 "propose_dispute; never invent one."),
        "args": [("search", "Optional filter text: descriptor words, category, amount or TXN- id. Empty string = all recent")],
        "read": ("SELECT * FROM my_transactions(CAST(?sub AS text), CAST(?q AS text));",
                 [("sub", SUB), ("q", "search")]),
    },
    {
        "tool": "get_my_cards", "flow": "get_my_cards_flow", "scope": "cards:read", "readonly": True,
        "desc": ("List the signed-in customer's own cards: card_id, last 4 digits, DEBIT/CREDIT, network, status "
                 "(ACTIVE, BLOCKED, EXPIRED), expiry, credit limit and, for a blocked card, the replacement's expected "
                 "delivery date. Only this customer's cards are returned."),
        "args": [],
        "read": ("SELECT * FROM my_cards(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "get_my_loans", "flow": "get_my_loans_flow", "scope": "loans:read", "readonly": True,
        "desc": ("List the signed-in customer's own loans: loan id, type (HOME, AUTO, PERSONAL), principal, "
                 "outstanding balance, interest rate, monthly payment, next due date and status. Read-only: the "
                 "assistant never approves, changes or defers a loan (hardship requests go to open_service_case)."),
        "args": [],
        "read": ("SELECT * FROM my_loans(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "find_branch", "flow": "find_branch_flow", "scope": "branches:read", "readonly": True,
        "desc": ("Find Kestrel Bank branches by city (or branch name, state or ZIP). Public information for any signed-in "
                 "user. Pass an empty city to list all branches. Returns address, phone and opening hours, or NOT_FOUND."),
        "args": [("city", "City name, e.g. Chicago (or branch name, state code or ZIP). Empty string = all branches")],
        "read": ("SELECT * FROM find_branch(CAST(?city AS text));", [("city", "city")]),
    },
    {
        "tool": "propose_card_block", "flow": "propose_card_block_flow", "scope": "cards:block", "readonly": False,
        "desc": ("Step 1 of 2 for blocking a lost, stolen, damaged or compromised card. Give the card (card_id such as "
                 "CARD-9001, or its last 4 digits) and the reason: LOST, STOLEN, DAMAGED or SUSPECTED_FRAUD. The system "
                 "checks every rule and returns PROPOSED with an action_id and the replacement card's expected delivery "
                 "date, or NOT_PROPOSED with reason_code CARD_NOT_FOUND (no card of this customer matches), "
                 "ALREADY_BLOCKED, CARD_EXPIRED, BAD_REASON or UNKNOWN_CALLER. Nothing changes until "
                 "confirm_card_block is called after the customer's explicit yes."),
        "args": [("card", "card_id (e.g. CARD-9001) or the card's last 4 digits (e.g. 1123)"),
                 ("reason", "LOST | STOLEN | DAMAGED | SUSPECTED_FRAUD")],
        "write": ("INSERT INTO pending_actions (action_type, customer_id, card_id, reason_code) "
                  "SELECT * FROM card_block_proposal_row(CAST(?w_sub AS text), CAST(?w_card AS text), CAST(?w_rsn AS text));",
                  [("w_sub", SUB), ("w_card", "card"), ("w_rsn", "reason")]),
        "read": ("SELECT * FROM propose_card_block_result(CAST(?r_sub AS text), CAST(?r_card AS text), CAST(?r_rsn AS text));",
                 [("r_sub", SUB), ("r_card", "card"), ("r_rsn", "reason")]),
    },
    {
        "tool": "confirm_card_block", "flow": "confirm_card_block_flow", "scope": "cards:block", "readonly": False,
        "desc": ("Step 2 of 2: block the card the customer has explicitly confirmed. Pass the action_id from "
                 "propose_card_block. The system re-checks every rule; proposals expire after 15 minutes. Returns "
                 "EXECUTED with block_id (BLK-NNNNN) and the replacement's expected delivery date, or NOT_EXECUTED with "
                 "reason_code NO_SUCH_PROPOSAL, EXPIRED, ALREADY_EXECUTED, UNKNOWN_CALLER or a rule's code. Only call "
                 "after the customer says yes to the exact proposal; never call it without a fresh action_id."),
        "args": [("action_id", "action_id returned by propose_card_block, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO card_blocks (action_id, card_id, reason) "
                  "SELECT * FROM card_block_confirmation_row(CAST(?w_sub AS text), CAST(?w_act AS text));",
                  [("w_sub", SUB), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_card_block_result(CAST(?r_sub AS text), CAST(?r_act AS text));",
                 [("r_sub", SUB), ("r_act", "action_id")]),
    },
    {
        "tool": "propose_dispute", "flow": "propose_dispute_flow", "scope": "disputes:write", "readonly": False,
        "desc": ("Step 1 of 2 for disputing a card or account charge. Give the transaction_id (from "
                 "get_my_transactions), the reason_code (UNRECOGNISED, FRAUD, DUPLICATE, NOT_RECEIVED, NOT_AS_DESCRIBED, "
                 "CANCELLED_RECURRING or WRONG_AMOUNT) and the customer's own words. The system checks eligibility and "
                 "computes the quote: returns PROPOSED with action_id, amount, merchant, provisional_credit, "
                 "fraud_review and est_decision_date, or NOT_PROPOSED with reason_code NOT_YOUR_TRANSACTION, "
                 "NOT_A_DEBIT, PENDING_NOT_POSTED, OUTSIDE_WINDOW (older than 120 days), ALREADY_DISPUTED, BAD_REASON, "
                 "NOT_DUPLICATE or UNKNOWN_CALLER. Read the amount, provisional credit and decision date back exactly "
                 "as returned; never compute or promise them yourself. Nothing is filed until confirm_dispute."),
        "args": [("transaction_id", "transaction_id from get_my_transactions, e.g. TXN-50003"),
                 ("reason_code", "UNRECOGNISED | FRAUD | DUPLICATE | NOT_RECEIVED | NOT_AS_DESCRIBED | CANCELLED_RECURRING | WRONG_AMOUNT"),
                 ("customer_statement", "The customer's description of the problem, in their own words")],
        "write": ("INSERT INTO pending_actions (action_type, customer_id, transaction_id, reason_code, customer_statement, "
                  "amount, provisional_credit, fraud_review) "
                  "SELECT * FROM dispute_proposal_row(CAST(?w_sub AS text), CAST(?w_txn AS text), CAST(?w_rsn AS text), "
                  "CAST(?w_stmt AS text));",
                  [("w_sub", SUB), ("w_txn", "transaction_id"), ("w_rsn", "reason_code"),
                   ("w_stmt", "customer_statement")]),
        "read": ("SELECT * FROM propose_dispute_result(CAST(?r_sub AS text), CAST(?r_txn AS text), CAST(?r_rsn AS text));",
                 [("r_sub", SUB), ("r_txn", "transaction_id"), ("r_rsn", "reason_code")]),
    },
    {
        "tool": "confirm_dispute", "flow": "confirm_dispute_flow", "scope": "disputes:write", "readonly": False,
        "desc": ("Step 2 of 2: file the dispute the customer has explicitly confirmed. Pass the action_id from "
                 "propose_dispute. The system re-checks every rule; proposals expire after 15 minutes. Returns FILED "
                 "with dispute_id (DSP-2026-NNNN), the provisional credit posted (if any), whether Fraud Operations "
                 "opened a review case, and the decision date; or NOT_FILED with reason_code NO_SUCH_PROPOSAL, EXPIRED, "
                 "ALREADY_EXECUTED, UNKNOWN_CALLER or a rule's code. Only call after the customer says yes to the "
                 "exact proposal."),
        "args": [("action_id", "action_id returned by propose_dispute, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO disputes (action_id, customer_id, transaction_id, reason_code, customer_statement, amount, "
                  "provisional_credit, fraud_review, est_decision_date) "
                  "SELECT * FROM dispute_confirmation_row(CAST(?w_sub AS text), CAST(?w_act AS text));",
                  [("w_sub", SUB), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_dispute_result(CAST(?r_sub AS text), CAST(?r_act AS text));",
                 [("r_sub", SUB), ("r_act", "action_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "scope": "cases:write", "readonly": False,
        "desc": ("Hand a request that needs a human to the right team: FEE_REFUND (refund of a fee such as overdraft or "
                 "late fee; reference_id = the fee's transaction_id), LOAN_HARDSHIP (payment difficulty or deferral; "
                 "reference_id = the loan_id; brief = the hardship intake brief), CREDIT_LIMIT_INCREASE, COMPLAINT, "
                 "PERSONAL_DETAILS_CHANGE (address, phone, name), ACCOUNT_CLOSURE, BEREAVEMENT, FRAUD_REVIEW or OTHER. "
                 "The system routes it, works out what a person could approve (e.g. refund that fee, defer up to 3 loan "
                 "payments) and returns CASE_OPENED with case_id (CASE-NNNNN), team, reply time and requested amount, "
                 "ALREADY_OPEN when the same request is already with the team, or NOT_OPENED with BAD_TYPE, BAD_REFERENCE "
                 "or UNKNOWN_CALLER. A person decides; the assistant never decides, approves, promises or predicts the "
                 "outcome of these requests."),
        "args": [("request_type", "FEE_REFUND | LOAN_HARDSHIP | CREDIT_LIMIT_INCREASE | COMPLAINT | PERSONAL_DETAILS_CHANGE | ACCOUNT_CLOSURE | BEREAVEMENT | FRAUD_REVIEW | OTHER"),
                 ("customer_statement", "The customer's request in their own words"),
                 ("brief", "A neutral summary for the team (facts only, no recommendation); for LOAN_HARDSHIP the hardship intake brief"),
                 ("reference_id", "FEE_REFUND: the fee's transaction_id; LOAN_HARDSHIP: the loan_id; otherwise empty")],
        "write": ("INSERT INTO service_cases (customer_id, request_type, customer_statement, agent_brief, assigned_team, "
                  "requested_amount, parked_action) "
                  "SELECT * FROM service_case_row(CAST(?w_sub AS text), CAST(?w_type AS text), CAST(?w_stmt AS text), "
                  "CAST(?w_brief AS text), CAST(?w_ref AS text));",
                  [("w_sub", SUB), ("w_type", "request_type"), ("w_stmt", "customer_statement"),
                   ("w_brief", "brief"), ("w_ref", "reference_id")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_sub AS text), CAST(?r_type AS text), CAST(?r_ref AS text));",
                 [("r_sub", SUB), ("r_type", "request_type"), ("r_ref", "reference_id")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "scope": "cases:read", "readonly": True,
        "desc": ("List the signed-in customer's disputes (DSP-) and service cases (CASE-) with type, status (OPEN, "
                 "APPROVED, REJECTED for cases), assigned team, amount, provisional credit, the expected decision or reply "
                 "date and - once a person has decided - the approved amount and the customer_message from the team. Use "
                 "it when the customer asks about the status of a request, a payment security check or a hardship case."),
        "args": [],
        "read": ("SELECT * FROM my_cases(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "email_my_confirmation", "flow": "email_my_confirmation_flow", "scope": "email:send", "readonly": False, "idempotent": True,
        "email": True,
        "desc": ("Email the confirmation for a dispute (DSP-...), card block (BLK-...), decided case (CASE-...) or sent "
                 "payment (PAY-...) of this customer. Pass the reference from confirm_dispute, confirm_card_block, "
                 "confirm_payment or get_my_cases. The system sends the email only when that reference belongs to the "
                 "signed-in customer (and a case only once a person has decided it); otherwise it returns NOT_SENT with "
                 "reason_code NO_SUCH_REFERENCE or UNKNOWN_CALLER."),
        "args": [("reference_id", "DSP-2026-NNNN, BLK-NNNNN, CASE-NNNNN or PAY-NNNNN")],
        "write": ("INSERT INTO email_log (customer_id, reference_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_sub AS text), CAST(?w_ref AS text));",
                  [("w_sub", SUB), ("w_ref", "reference_id")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_sub AS text), CAST(?r_ref AS text));",
                 [("r_sub", SUB), ("r_ref", "reference_id")]),
    },
    # ------------------------------------------------------------------ payments to saved payees (scam protection)
    {
        "tool": "get_my_payees", "flow": "get_my_payees_flow", "scope": "payees:read", "readonly": True,
        "desc": ("List the signed-in customer's saved payees: payee_id, name, bank, masked account, payee_type (PERSON, "
                 "BUSINESS, INVESTMENT_PLATFORM, CRYPTO_EXCHANGE), date added, date last paid and is_new_payee (never paid "
                 "and added in the last 30 days). Payments go only to these payees; new payees are added in the Kestrel app."),
        "args": [],
        "read": ("SELECT * FROM my_payees(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "propose_payment", "flow": "propose_payment_flow", "scope": "payments:write", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 for paying a saved payee from the customer's own checking or savings account. Pass the "
                 "from-account (account_id), the payee (payee_id), the amount in dollars, the customer's own words about "
                 "the payment, and the scam_signal_agent's indicators, narrative_score and full answer exactly as it "
                 "returned them. The system checks the rules, combines the agent's signals with its own checks and returns "
                 "PROPOSED (ask for an explicit yes), PROPOSED_WITH_WARNING (read warning_text word for word first), "
                 "HELD_FOR_REVIEW (nothing sent; a fraud specialist reviews it - give the case_id and reply date), or "
                 "NOT_PROPOSED with reason_code ACCOUNT_NOT_FOUND, PAYEE_NOT_FOUND, BAD_AMOUNT, INSUFFICIENT_FUNDS, "
                 "OVER_DAILY_LIMIT or UNKNOWN_CALLER. Nothing is sent until confirm_payment."),
        "args": [("from_account", "account_id from get_my_accounts, e.g. ACC-1014 (checking or savings)"),
                 ("payee", "payee_id from get_my_payees, e.g. PYE-0102"),
                 ("amount", "Amount in US dollars, e.g. 1850.00"),
                 ("customer_story", "The customer's own words about what the payment is for and why they are making it"),
                 ("scam_indicators", "The indicators line from scam_signal_agent, exactly as returned (or NONE)"),
                 ("narrative_score", "The narrative_score from scam_signal_agent, exactly as returned"),
                 ("agent_notes", "scam_signal_agent's full answer, unchanged")],
        "write": ("INSERT INTO payment_requests (customer_id, account_id, payee_id, amount, customer_story, agent_notes, "
                  "narrative_indicators, ignored_indicators, narrative_score, signals, risk_points, risk_band, status, "
                  "warning_required) "
                  "SELECT * FROM payment_request_row(CAST(?w_sub AS text), CAST(?w_acct AS text), CAST(?w_payee AS text), "
                  "CAST(?w_amt AS text), CAST(?w_story AS text), CAST(?w_ind AS text), CAST(?w_score AS text), "
                  "CAST(?w_notes AS text));",
                  [("w_sub", SUB), ("w_acct", "from_account"), ("w_payee", "payee"), ("w_amt", "amount"),
                   ("w_story", "customer_story"), ("w_ind", "scam_indicators"), ("w_score", "narrative_score"),
                   ("w_notes", "agent_notes")]),
        "read": ("SELECT * FROM propose_payment_result(CAST(?r_sub AS text), CAST(?r_acct AS text), CAST(?r_payee AS text), "
                 "CAST(?r_amt AS text));",
                 [("r_sub", SUB), ("r_acct", "from_account"), ("r_payee", "payee"), ("r_amt", "amount")]),
    },
    {
        "tool": "confirm_payment", "flow": "confirm_payment_flow", "scope": "payments:write", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: send a payment the customer has explicitly confirmed. Pass the payment_id from "
                 "propose_payment and acknowledge_warning YES only when the proposal was PROPOSED_WITH_WARNING and the "
                 "customer said they read the warning and still want to go ahead (otherwise NO). The system re-checks every "
                 "rule; proposals expire after 15 minutes. Returns SENT with the payment details, or NOT_SENT with "
                 "reason_code NO_SUCH_PAYMENT, HELD_FOR_REVIEW, CANCELLED, EXPIRED, WARNING_NOT_ACKNOWLEDGED, ALREADY_SENT, "
                 "UNKNOWN_CALLER or a rule's code. Only call after the customer says yes to the exact proposal."),
        "args": [("payment_id", "payment_id returned by propose_payment, e.g. PAY-00002"),
                 ("acknowledge_warning", "YES only after the customer acknowledged the warning_text; otherwise NO")],
        "write": ("INSERT INTO payment_sends (payment_id, via, case_id, amount) "
                  "SELECT * FROM payment_confirmation_row(CAST(?w_sub AS text), CAST(?w_pay AS text), CAST(?w_ack AS text));",
                  [("w_sub", SUB), ("w_pay", "payment_id"), ("w_ack", "acknowledge_warning")]),
        "read": ("SELECT * FROM confirm_payment_result(CAST(?r_sub AS text), CAST(?r_pay AS text), CAST(?r_ack AS text));",
                 [("r_sub", SUB), ("r_pay", "payment_id"), ("r_ack", "acknowledge_warning")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "scope": "reviews:read", "readonly": True,
        "desc": ("List the signed-in reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "customer (first name + last initial), opened date, age in days, reply-due date, sla_status (ON_TRACK, "
                 "DUE_TODAY, OVERDUE) and requested amount. Status EMPTY = no open cases; NOT_REVIEWER = the signed-in user is not an active staff reviewer."),
        "args": [],
        "read": ("SELECT * FROM review_queue(CAST(?sub AS text));", [("sub", SUB)]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "scope": "reviews:read", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, customer (first name + last initial), the "
                 "customer's statement, the AI-prepared agent_brief (unverified), requested amount, max_approvable, the "
                 "reviewer's own approval limit, facts from Kestrel's records (fee, loan, held payment with its risk "
                 "signals, or dispute) and the decision options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("case_id", "Case id from get_review_queue, e.g. CASE-00003")],
        "read": ("SELECT * FROM review_case(CAST(?sub AS text), CAST(?cid AS text));",
                 [("sub", SUB), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "scope": "reviews:decide", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved amount in dollars "
                 "(empty = the full eligible amount; ignored for REJECT); internal_note is required (at least 5 characters, "
                 "never shown to the customer); customer_message is what the customer will see. Approving runs the parked "
                 "action (fee refund, loan payment deferral or release of a held payment) through the system's checks; "
                 "rejecting a held payment cancels it. Returns APPROVED / REJECTED with executed_action, or BLOCKED with "
                 "reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY (case stays "
                 "open for a senior reviewer), INVALID_DECISION or NOT_FOUND, or NOT_REVIEWER (the signed-in user is "
                 "not an active staff reviewer)."),
        "args": [("case_id", "Case id, e.g. CASE-00003"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved amount in dollars, or empty for the full eligible amount"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the customer)"),
                 ("customer_message", "Message the customer will see with the outcome")],
        "write": ("INSERT INTO review_decisions (case_id, reviewer_id, decision, approved_amount, internal_note, customer_message) "
                  "SELECT * FROM decide_case_row(CAST(?w_sub AS text), CAST(?w_cid AS text), CAST(?w_dec AS text), "
                  "CAST(?w_amt AS text), CAST(?w_note AS text), CAST(?w_msg AS text));",
                  [("w_sub", SUB), ("w_cid", "case_id"), ("w_dec", "decision"), ("w_amt", "amount"),
                   ("w_note", "internal_note"), ("w_msg", "customer_message")]),
        "read": ("SELECT * FROM decide_case_result(CAST(?r_sub AS text), CAST(?r_cid AS text));",
                 [("r_sub", SUB), ("r_cid", "case_id")]),
    },
]

REVIEWER_TOOLS = {"get_review_queue", "get_review_case", "decide_review_case"}
SHARED_TOOLS = {"whoami", "find_branch"}            # every signed-in persona sees these (profile:read, branches:read)
PUBLIC_TOOLS = {"find_branch"}                      # the only tool whose SQL does not bind the caller (@sub)
CUSTOMER_TOOLS = {t["tool"] for t in TOOLS} - REVIEWER_TOOLS - SHARED_TOOLS
SCOPES = {t["tool"]: t["scope"] for t in TOOLS}      # one required scope per tool (MCP handler settings.scope)

# ---------------------------------------------------------------------------------------------------------------------
# Personas + scopes (the identity provider's job; mint_user_tokens.py is the demo stand-in). The JWT sub is the
# customer_id / staff id; the scopes decide which tools the MCP Server trigger lists and runs for that token.
# ---------------------------------------------------------------------------------------------------------------------
CUSTOMER_VIEW_ONLY_SCOPES = ["profile:read", "accounts:read", "transactions:read", "cards:read", "loans:read",
                             "payees:read", "cases:read", "branches:read"]
CUSTOMER_FULL_SCOPES = CUSTOMER_VIEW_ONLY_SCOPES + ["cards:block", "disputes:write", "payments:write", "cases:write",
                                                   "email:send"]
REVIEWER_SCOPES = ["profile:read", "reviews:read", "reviews:decide", "branches:read"]


def _customer(sub, name, scopes=CUSTOMER_FULL_SCOPES):
    return {"sub": sub, "name": name, "role": "CUSTOMER", "scp": list(scopes)}


def _reviewer(sub, name, team):
    return {"sub": sub, "name": name, "role": "REVIEWER", "team": team, "scp": list(REVIEWER_SCOPES)}


PERSONAS = {
    "james":     _customer("CUST-2026-00101", "James Miller"),
    "olivia":    _customer("CUST-2026-00102", "Olivia Davis"),
    "william":   _customer("CUST-2026-00103", "William Garcia"),
    "sophia":    _customer("CUST-2026-00104", "Sophia Martinez"),
    "benjamin":  _customer("CUST-2026-00105", "Benjamin Lee"),
    "emma":      _customer("CUST-2026-00106", "Emma Johnson"),
    "michael":   _customer("CUST-2026-00107", "Michael Brown"),
    "patricia":  _customer("CUST-2026-00108", "Patricia Wilson"),
    # James signed in on a view-only channel (e.g. a smart-speaker or partner app): same sub, read scopes only.
    "james_view": _customer("CUST-2026-00101", "James Miller", CUSTOMER_VIEW_ONLY_SCOPES),
    "maya":      _reviewer("KST-7001", "Maya Chen", "Customer Care"),
    "daniel":    _reviewer("KST-7002", "Daniel Ortiz", "Financial Support"),
    "priya":     _reviewer("KST-7003", "Priya Nair", "Fraud Operations"),
}


def tools_for_scopes(scopes):
    """The tool names the MCP Server trigger should list for a token with these scopes."""
    return {t for t, sc in SCOPES.items() if sc in set(scopes)}


# Columns that must NEVER appear in any CUSTOMER tool output (asserted by test_rules.py / mcp_smoke.py). (find_branch's
# public branch phone is allowed; customer phone numbers are never returned. whoami is shared and checked on its own.)
HIDDEN_COLUMNS = {"email", "internal_note", "agent_brief", "agent_notes",
                  "reviewer_id", "approval_limit", "parked_action", "narrative_score", "narrative_indicators",
                  "ignored_indicators", "signals", "risk_points", "risk_band"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"email", "phone", "last_name", "customer_id"}

# Tool of the A2A dispute_triage_agent (kept as built: a non-identity PostgreSQL read of the merchant directory).
# A statement descriptor only - never customer identity.
LOOKUP_MERCHANT = {
    "desc": ("Decode a card-statement descriptor into the real merchant. Pass the descriptor text exactly as it "
             "appears on the transaction (e.g. QUICKPAY*XYZ 872-555), or a fragment of it. Returns matching merchant "
             "directory rows (most specific first): match_type (PREFIX_MATCH, PARTIAL_MATCH, KEYWORD_MATCH or "
             "NO_MATCH), merchant_name, category, billing_model (ONE_OFF or RECURRING), support_contact and notes on "
             "how the merchant bills. Read-only. Never pass any customer-identifying information."),
    "args": [("descriptor", "Statement descriptor text, e.g. STRMPLS*MEMBERSHIP 888-555")],
    "read": ("SELECT * FROM lookup_merchant(CAST(?dsc AS text));", [("dsc", "descriptor")]),
}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (RetailBankingAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM <fn>(CAST(?<placeholder> AS text))) -> #actreturn (rows as JSON text).
# - dispute_triage_agent keeps its lookup_merchant(descriptor) read over merchant_directory (no customer data).
# - scam_signal_agent / hardship_intake_agent read section / term / meaning guides via ref_<topic>(term); the
#   placeholder is ?lookup, not ?term (a placeholder named like a result column gives duplicate Fields).
# The model can supply only the one lookup value; it can never change the SQL. The tables hold reference data only
# (asserted by test_rules.py). WHO_DECIDES rows are read from service_teams (one source of truth).
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example an indicator, a cause, a program "
                 "or a section name), or an empty string for the whole guide. Never put customer details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "dispute_triage_agent", "tool": "lookup_merchant", "fn": "lookup_merchant", "table": "merchant_directory",
     "sections": None, "row_key": "match_type",
     "desc": LOOKUP_MERCHANT["desc"], "args": LOOKUP_MERCHANT["args"], "read": LOOKUP_MERCHANT["read"]},
    {"agent": "scam_signal_agent", "tool": "get_scam_signal_guide", "fn": "ref_scam_signals", "table": "scam_signal_guide",
     "sections": ["HIGH_RISK", "CAUTION", "PAYEE_TYPE", "SCORE_RULE", "REVIEW_STEP", "WHO_DECIDES"], "row_key": "section",
     "desc": ("Reads Kestrel Bank's payment-scam signal guide from the database: the HIGH_RISK and CAUTION indicator names "
              "of authorised push payment scams and what each looks like, the payee types, how to set the narrative "
              "score, the reviewer step for each indicator and who reviews a held payment. Rows of section, term, "
              "meaning. Read-only reference data with no customer data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_scam_signals(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "hardship_intake_agent", "tool": "get_hardship_guide", "fn": "ref_hardship_guide", "table": "hardship_guide",
     "sections": ["CAUSE", "DURATION", "PRODUCT", "PROGRAM", "DOCUMENT", "SUPPORT_LINE", "BRIEF_RULE", "WHO_DECIDES"],
     "row_key": "section",
     "desc": ("Reads Kestrel Bank's hardship intake guide from the database: the hardship cause and duration categories, "
              "the product names, the hardship programs and which products and durations each suits, the documents to "
              "request for each cause, the brief rules, a standard support line and who decides. Rows of section, term, "
              "meaning. Read-only reference data with no customer data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_hardship_guide(CAST(?lookup AS text));", [("lookup", "term")])},
]
GUIDE_TOOLS = [t for t in AGENT_REF_TOOLS if t["sections"]]      # the section / term / meaning guides


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
