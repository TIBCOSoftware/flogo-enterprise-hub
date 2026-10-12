"""Single source of truth for the MCP tools and the dispute_triage_agent's tool.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py
(to run the exact same SQL against PostgreSQL before any app is built).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): it validates with SQL, then the flow sends the email only
when the SQL authorises it (send_status = SEND; a conditional branch, added in build_mcp.py).
"""

TOKEN_DESC = ("Session token returned by verify_customer. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the customer to verify again.")

TOOLS = [
    {
        "tool": "verify_customer", "flow": "verify_customer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the customer's identity with their Kestrel Bank customer id (e.g. CUST-2026-00101) and the "
                 "6-digit passcode from their Kestrel app. Returns VERIFIED with a session_token (valid 30 minutes) and "
                 "their name, NOT_VERIFIED when the id and passcode do not match, or LOCKED after 5 failed attempts in "
                 "15 minutes (no token is issued while locked, even with the right passcode; offer account recovery "
                 "only). Call this before any other customer tool. Never reveal, hint at or guess passcodes."),
        "args": [("customer_id", "Kestrel Bank customer id, e.g. CUST-2026-00101"),
                 ("passcode", "6-digit passcode the customer typed")],
        "write": ("INSERT INTO customer_sessions (customer_id) "
                  "SELECT customer_id FROM verify_and_record(CAST(?w_cid AS text), CAST(?w_code AS text));",
                  [("w_cid", "customer_id"), ("w_code", "passcode")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_cid AS text), CAST(?r_code AS text));",
                 [("r_cid", "customer_id"), ("r_code", "passcode")]),
    },
    {
        "tool": "get_my_accounts", "flow": "get_my_accounts_flow", "readonly": True,
        "desc": ("List the verified customer's own accounts: account id, masked number, type (CHECKING, SAVINGS, "
                 "CREDIT), balance, available balance, currency and status. Only this customer's accounts are returned. "
                 "Quote figures exactly as returned; never compute or estimate balances."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_accounts(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_transactions", "flow": "get_my_transactions_flow", "readonly": True,
        "desc": ("List the verified customer's own transactions, newest first, at most 25. Pass an empty search for "
                 "everything in the last 120 days, or a search term to filter: part of the statement descriptor or "
                 "merchant text (e.g. QUICKPAY, LUXEJET), a category, an amount (e.g. 249.99) or a transaction id. "
                 "Each row has transaction_id, date, descriptor, amount, DEBIT/CREDIT, POSTED/PENDING and any open "
                 "dispute id. Returns NO_MATCH when nothing matches. Use the transaction_id from here for "
                 "propose_dispute; never invent one."),
        "args": [("session_token", TOKEN_DESC),
                 ("search", "Optional filter text: descriptor words, category, amount or TXN- id. Empty string = all recent")],
        "read": ("SELECT * FROM my_transactions(CAST(?tok AS text), CAST(?q AS text));",
                 [("tok", "session_token"), ("q", "search")]),
    },
    {
        "tool": "get_my_cards", "flow": "get_my_cards_flow", "readonly": True,
        "desc": ("List the verified customer's own cards: card_id, last 4 digits, DEBIT/CREDIT, network, status "
                 "(ACTIVE, BLOCKED, EXPIRED), expiry, credit limit and, for a blocked card, the replacement's expected "
                 "delivery date. Only this customer's cards are returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cards(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_loans", "flow": "get_my_loans_flow", "readonly": True,
        "desc": ("List the verified customer's own loans: loan id, type (HOME, AUTO, PERSONAL), principal, "
                 "outstanding balance, interest rate, monthly payment, next due date and status. Read-only: the "
                 "assistant never approves, changes or defers a loan (hardship requests go to open_service_case)."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_loans(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "find_branch", "flow": "find_branch_flow", "readonly": True,
        "desc": ("Find Kestrel Bank branches by city (or branch name, state or ZIP). Public information: no "
                 "verification or session token needed. Pass an empty city to list all branches. Returns address, "
                 "phone and opening hours, or NOT_FOUND."),
        "args": [("city", "City name, e.g. Chicago (or branch name, state code or ZIP). Empty string = all branches")],
        "read": ("SELECT * FROM find_branch(CAST(?city AS text));", [("city", "city")]),
    },
    {
        "tool": "propose_card_block", "flow": "propose_card_block_flow", "readonly": False,
        "desc": ("Step 1 of 2 for blocking a lost, stolen, damaged or compromised card. Give the card (card_id such as "
                 "CARD-9001, or its last 4 digits) and the reason: LOST, STOLEN, DAMAGED or SUSPECTED_FRAUD. The system "
                 "checks every rule and returns PROPOSED with an action_id and the replacement card's expected delivery "
                 "date, or NOT_PROPOSED with reason_code CARD_NOT_FOUND (no card of this customer matches), "
                 "ALREADY_BLOCKED, CARD_EXPIRED, BAD_REASON or SESSION_INVALID. Nothing changes until "
                 "confirm_card_block is called after the customer's explicit yes."),
        "args": [("session_token", TOKEN_DESC),
                 ("card", "card_id (e.g. CARD-9001) or the card's last 4 digits (e.g. 1123)"),
                 ("reason", "LOST | STOLEN | DAMAGED | SUSPECTED_FRAUD")],
        "write": ("INSERT INTO pending_actions (action_type, customer_id, card_id, reason_code) "
                  "SELECT * FROM card_block_proposal_row(CAST(?w_tok AS text), CAST(?w_card AS text), CAST(?w_rsn AS text));",
                  [("w_tok", "session_token"), ("w_card", "card"), ("w_rsn", "reason")]),
        "read": ("SELECT * FROM propose_card_block_result(CAST(?r_tok AS text), CAST(?r_card AS text), CAST(?r_rsn AS text));",
                 [("r_tok", "session_token"), ("r_card", "card"), ("r_rsn", "reason")]),
    },
    {
        "tool": "confirm_card_block", "flow": "confirm_card_block_flow", "readonly": False,
        "desc": ("Step 2 of 2: block the card the customer has explicitly confirmed. Pass the action_id from "
                 "propose_card_block. The system re-checks every rule; proposals expire after 15 minutes. Returns "
                 "EXECUTED with block_id (BLK-NNNNN) and the replacement's expected delivery date, or NOT_EXECUTED with "
                 "reason_code NO_SUCH_PROPOSAL, EXPIRED, ALREADY_EXECUTED, SESSION_INVALID or a rule's code. Only call "
                 "after the customer says yes to the exact proposal; never call it without a fresh action_id."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id returned by propose_card_block, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO card_blocks (action_id, card_id, reason) "
                  "SELECT * FROM card_block_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_card_block_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "propose_dispute", "flow": "propose_dispute_flow", "readonly": False,
        "desc": ("Step 1 of 2 for disputing a card or account charge. Give the transaction_id (from "
                 "get_my_transactions), the reason_code (UNRECOGNISED, FRAUD, DUPLICATE, NOT_RECEIVED, NOT_AS_DESCRIBED, "
                 "CANCELLED_RECURRING or WRONG_AMOUNT) and the customer's own words. The system checks eligibility and "
                 "computes the quote: returns PROPOSED with action_id, amount, merchant, provisional_credit, "
                 "fraud_review and est_decision_date, or NOT_PROPOSED with reason_code NOT_YOUR_TRANSACTION, "
                 "NOT_A_DEBIT, PENDING_NOT_POSTED, OUTSIDE_WINDOW (older than 120 days), ALREADY_DISPUTED, BAD_REASON, "
                 "NOT_DUPLICATE or SESSION_INVALID. Read the amount, provisional credit and decision date back exactly "
                 "as returned; never compute or promise them yourself. Nothing is filed until confirm_dispute."),
        "args": [("session_token", TOKEN_DESC),
                 ("transaction_id", "transaction_id from get_my_transactions, e.g. TXN-50003"),
                 ("reason_code", "UNRECOGNISED | FRAUD | DUPLICATE | NOT_RECEIVED | NOT_AS_DESCRIBED | CANCELLED_RECURRING | WRONG_AMOUNT"),
                 ("customer_statement", "The customer's description of the problem, in their own words")],
        "write": ("INSERT INTO pending_actions (action_type, customer_id, transaction_id, reason_code, customer_statement, "
                  "amount, provisional_credit, fraud_review) "
                  "SELECT * FROM dispute_proposal_row(CAST(?w_tok AS text), CAST(?w_txn AS text), CAST(?w_rsn AS text), "
                  "CAST(?w_stmt AS text));",
                  [("w_tok", "session_token"), ("w_txn", "transaction_id"), ("w_rsn", "reason_code"),
                   ("w_stmt", "customer_statement")]),
        "read": ("SELECT * FROM propose_dispute_result(CAST(?r_tok AS text), CAST(?r_txn AS text), CAST(?r_rsn AS text));",
                 [("r_tok", "session_token"), ("r_txn", "transaction_id"), ("r_rsn", "reason_code")]),
    },
    {
        "tool": "confirm_dispute", "flow": "confirm_dispute_flow", "readonly": False,
        "desc": ("Step 2 of 2: file the dispute the customer has explicitly confirmed. Pass the action_id from "
                 "propose_dispute. The system re-checks every rule; proposals expire after 15 minutes. Returns FILED "
                 "with dispute_id (DSP-2026-NNNN), the provisional credit posted (if any), whether Fraud Operations "
                 "opened a review case, and the decision date; or NOT_FILED with reason_code NO_SUCH_PROPOSAL, EXPIRED, "
                 "ALREADY_EXECUTED, SESSION_INVALID or a rule's code. Only call after the customer says yes to the "
                 "exact proposal."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id returned by propose_dispute, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO disputes (action_id, customer_id, transaction_id, reason_code, customer_statement, amount, "
                  "provisional_credit, fraud_review, est_decision_date) "
                  "SELECT * FROM dispute_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_dispute_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False,
        "desc": ("Hand a request that needs a human to the right team: FEE_REFUND (refund of a fee such as overdraft), "
                 "LOAN_HARDSHIP (payment difficulty, deferral), CREDIT_LIMIT_INCREASE, COMPLAINT, "
                 "PERSONAL_DETAILS_CHANGE (address, phone, name), ACCOUNT_CLOSURE, BEREAVEMENT, FRAUD_REVIEW or OTHER. "
                 "The system routes it and returns CASE_OPENED with case_id (CASE-NNNNN), team and reply time in "
                 "business days, or NOT_OPENED with BAD_TYPE or SESSION_INVALID. The assistant never decides, approves, "
                 "promises or predicts the outcome of these requests."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "FEE_REFUND | LOAN_HARDSHIP | CREDIT_LIMIT_INCREASE | COMPLAINT | PERSONAL_DETAILS_CHANGE | ACCOUNT_CLOSURE | BEREAVEMENT | FRAUD_REVIEW | OTHER"),
                 ("customer_statement", "The customer's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the team: facts only, no recommendation")],
        "write": ("INSERT INTO service_cases (customer_id, request_type, customer_statement, agent_brief, assigned_team) "
                  "SELECT * FROM service_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_stmt AS text), "
                  "CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_stmt", "customer_statement"),
                   ("w_brief", "brief")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified customer's disputes (DSP-) and service cases (CASE-) with type, status, assigned "
                 "team, amount, provisional credit and the expected decision or reply date."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "email_my_confirmation", "flow": "email_my_confirmation_flow", "readonly": False, "idempotent": True,
        "email": True,
        "desc": ("Email the confirmation for a dispute (DSP-...) or card block (BLK-...) of this customer. Pass the "
                 "reference_id from confirm_dispute or confirm_card_block. The system sends the email only when that "
                 "reference belongs to this session's customer; otherwise it returns NOT_SENT with reason_code "
                 "NO_SUCH_REFERENCE or SESSION_INVALID. Call only after a successful filing or block."),
        "args": [("session_token", TOKEN_DESC),
                 ("reference_id", "dispute_id (DSP-2026-NNNN) or block_id (BLK-NNNNN)")],
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference_id")]),
    },
]

# Tool of the A2A dispute_triage_agent. A statement descriptor only - never customer identity.
LOOKUP_MERCHANT = {
    "desc": ("Decode a card-statement descriptor into the real merchant. Pass the descriptor text exactly as it "
             "appears on the transaction (e.g. QUICKPAY*XYZ 872-555), or a fragment of it. Returns matching merchant "
             "directory rows (most specific first): match_type (PREFIX_MATCH, PARTIAL_MATCH, KEYWORD_MATCH or "
             "NO_MATCH), merchant_name, category, billing_model (ONE_OFF or RECURRING), support_contact and notes on "
             "how the merchant bills. Read-only. Never pass any customer-identifying information."),
    "args": [("descriptor", "Statement descriptor text, e.g. STRMPLS*MEMBERSHIP 888-555")],
    "read": ("SELECT * FROM lookup_merchant(CAST(?dsc AS text));", [("dsc", "descriptor")]),
}
