"""Single source of truth for the 22 MCP tools of CorporatePaymentsMCPServer and the 3 A2A agents' reference tools.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py / mcp_smoke.py / a2a_smoke.py
(to run the exact same SQL against PostgreSQL before any app is built).

Two personas share one MCP server: CLIENT tools resolve only client tokens (verify_client), REVIEWER tools only
reviewer tokens (verify_reviewer) - the role is checked in SQL on every call.

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
CAST(?p AS text) (followed by a space) - see postgres-activity-patterns.md. Write SQL uses ?w_*,
read SQL ?r_* (or ?tok for read-only). Every guarded write is INSERT ... SELECT * FROM <fn>(...),
never VALUES, so no argument reaches a table unchecked.

The email tool is special (email=True): it validates with SQL, then the flow sends the email only
when the SQL authorises it (send_status = SEND; a conditional branch, added in build_mcp.py).
"""

RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A client token does "
               "not work here (NOT_REVIEWER).")

TOKEN_DESC = ("Session token returned by verify_client. Required; never invent a session token. "
              "If a tool answers SESSION_INVALID, ask the client to verify again.")

TOOLS = [
    {
        "tool": "verify_client", "flow": "verify_client_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the client's identity with their Aurelia Global Bank client id (e.g. CLI-2026-00101) and the "
                 "6-digit passcode from their corporate portal. Returns VERIFIED with a session_token (valid 30 minutes) "
                 "and their legal name, NOT_VERIFIED when the id and passcode do not match, or LOCKED after 5 failed "
                 "attempts in 15 minutes (no token is issued while locked, even with the right passcode; offer recovery "
                 "only). Call this before any other client tool. Never reveal, hint at or guess passcodes. Aurelia "
                 "staff use verify_reviewer instead."),
        "args": [("client_id", "Aurelia Global Bank client id, e.g. CLI-2026-00101"),
                 ("passcode", "6-digit passcode the client typed")],
        "write": ("INSERT INTO client_sessions (client_id) "
                  "SELECT client_id FROM verify_and_record(CAST(?w_cid AS text), CAST(?w_code AS text));",
                  [("w_cid", "client_id"), ("w_code", "passcode")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_cid AS text), CAST(?r_code AS text));",
                 [("r_cid", "client_id"), ("r_code", "passcode")]),
    },
    {
        "tool": "get_my_payments", "flow": "get_my_payments_flow", "readonly": True,
        "desc": ("List the verified client's own payments, newest first, at most 25. Pass an empty search for everything "
                 "in the last 90 days, or a search term to filter back 18 months: part of the payment reference, the "
                 "beneficiary name or bank BIC, or an amount (e.g. 48500). Each row has payment_ref, direction "
                 "(OUTGOING/INCOMING), rail, amount, currency, fx_rate, fees, beneficiary, status and any return reason "
                 "code, value date, created-at and any open investigation id. Returns NO_MATCH when nothing matches. "
                 "Use the payment_ref from here for the other tools; never invent one."),
        "args": [("session_token", TOKEN_DESC),
                 ("search", "Optional filter: payment ref, beneficiary text, bank BIC or an amount. Empty string = all recent")],
        "read": ("SELECT * FROM my_payments(CAST(?tok AS text), CAST(?q AS text));",
                 [("tok", "session_token"), ("q", "search")]),
    },
    {
        "tool": "get_payment_status", "flow": "get_payment_status_flow", "readonly": True,
        "desc": ("Get the full status of one payment on the verified client's own accounts: direction, rail, amount, "
                 "currency, fx rate, fees, beneficiary and bank, status (INITIATED, IN_TRANSIT, COMPLETED, RETURNED, "
                 "HELD, RECALL_REQUESTED, RECALLED) and - when RETURNED - the return reason code decoded into plain "
                 "language. Returns NOT_YOUR_PAYMENT for a payment that is absent or belongs to another client. Quote "
                 "amounts, fees and the decoded reason exactly as returned."),
        "args": [("session_token", TOKEN_DESC), ("payment_ref", "Payment reference, e.g. PMT-2026-000001")],
        "read": ("SELECT * FROM payment_status_for_session(CAST(?tok AS text), CAST(?ref AS text));",
                 [("tok", "session_token"), ("ref", "payment_ref")]),
    },
    {
        "tool": "get_payment_timeline", "flow": "get_payment_timeline_flow", "readonly": True,
        "desc": ("Show the GPI-style event timeline of one payment on the verified client's own accounts: each step "
                 "with its time, the acting bank and what happened (initiated, debited, forwarded to the agent bank, in "
                 "transit, returned, completed...). Returns NOT_YOUR_PAYMENT for a payment that is not this client's."),
        "args": [("session_token", TOKEN_DESC), ("payment_ref", "Payment reference, e.g. PMT-2026-000001")],
        "read": ("SELECT * FROM payment_timeline(CAST(?tok AS text), CAST(?ref AS text));",
                 [("tok", "session_token"), ("ref", "payment_ref")]),
    },
    {
        "tool": "check_delivery_estimate", "flow": "check_delivery_estimate_flow", "readonly": True,
        "desc": ("Assess whether one payment on the verified client's own accounts will settle on time. The system "
                 "computes it deterministically from the rail/currency cutoff rules and business days - it is never "
                 "estimated by you. Returns the outcome ON_TRACK, PAST_CUTOFF (submitted after today's cutoff, so it "
                 "processes the next business day), DELAYED (past the expected settlement date and still not completed) "
                 "or SETTLED, with the expected settlement date, or NOT_YOUR_PAYMENT. Quote the outcome and date "
                 "verbatim; never compute a delivery estimate yourself."),
        "args": [("session_token", TOKEN_DESC), ("payment_ref", "Payment reference, e.g. PMT-2026-000001")],
        "read": ("SELECT * FROM delivery_estimate(CAST(?tok AS text), CAST(?ref AS text));",
                 [("tok", "session_token"), ("ref", "payment_ref")]),
    },
    {
        "tool": "propose_trace", "flow": "propose_trace_flow", "readonly": False,
        "desc": ("Step 1 of 2 for raising a trace / investigation on a delayed or missing payment. Give the payment_ref "
                 "(from get_my_payments), a return/reason code (use lookup_reason_code, or MS03 if none was given) and "
                 "the client's own words. The system checks every rule and returns PROPOSED with an action_id, the "
                 "amount, beneficiary, decoded reason and estimated response date, or NOT_PROPOSED with reason_code "
                 "NOT_YOUR_PAYMENT, NOT_TRACEABLE (submitted less than 2 hours ago, or still INITIATED), "
                 "ALREADY_UNDER_INVESTIGATION, BAD_REASON or SESSION_INVALID. Read the amount, beneficiary, decoded "
                 "reason and response date back exactly as returned. Nothing is opened until confirm_trace is called "
                 "after the client's explicit yes."),
        "args": [("session_token", TOKEN_DESC),
                 ("payment_ref", "Payment reference from get_my_payments, e.g. PMT-2026-000001"),
                 ("reason_code", "A return/reason code, e.g. MS03, AC04, BE01 (decode with lookup_reason_code)"),
                 ("client_statement", "The client's description of the problem, in their own words")],
        "write": ("INSERT INTO pending_actions (action_type, client_id, payment_ref, reason_code, client_statement, est_response_date) "
                  "SELECT * FROM trace_proposal_row(CAST(?w_tok AS text), CAST(?w_ref AS text), CAST(?w_rsn AS text), "
                  "CAST(?w_stmt AS text));",
                  [("w_tok", "session_token"), ("w_ref", "payment_ref"), ("w_rsn", "reason_code"),
                   ("w_stmt", "client_statement")]),
        "read": ("SELECT * FROM propose_trace_result(CAST(?r_tok AS text), CAST(?r_ref AS text), CAST(?r_rsn AS text));",
                 [("r_tok", "session_token"), ("r_ref", "payment_ref"), ("r_rsn", "reason_code")]),
    },
    {
        "tool": "confirm_trace", "flow": "confirm_trace_flow", "readonly": False,
        "desc": ("Step 2 of 2: open the trace the client has explicitly confirmed. Pass the action_id from "
                 "propose_trace. The system re-checks every rule; proposals expire after 15 minutes. Returns OPENED with "
                 "the investigation_id (INV-2026-NNNN) and the estimated response date, or NOT_EXECUTED with reason_code "
                 "NO_SUCH_PROPOSAL, EXPIRED, ALREADY_EXECUTED, SESSION_INVALID or a rule's code. Only call after the "
                 "client says yes to the exact proposal; never call it without a fresh action_id."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id returned by propose_trace, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO investigations (action_id, client_id, payment_ref, reason_code, client_statement, est_response_date) "
                  "SELECT * FROM trace_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_trace_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "propose_recall", "flow": "propose_recall_flow", "readonly": False,
        "desc": ("Step 1 of 2 for requesting a recall / return of a payment (for example sent to the wrong "
                 "beneficiary). Give the payment_ref, a return/reason code (e.g. BE01 for a wrong beneficiary) and the "
                 "client's own words. The system checks every rule and returns PROPOSED with an action_id, the amount, "
                 "beneficiary and decoded reason, or NOT_PROPOSED with reason_code NOT_YOUR_PAYMENT, NOT_RECALLABLE "
                 "(incoming payment, already returned/recalled, or completed more than 5 business days ago), "
                 "ALREADY_RECALL_REQUESTED, BAD_REASON or SESSION_INVALID. Make clear to the client that a recall is a "
                 "REQUEST a person at Payment Operations decides: it is not guaranteed and does NOT reverse the funds "
                 "automatically. Nothing is submitted until confirm_recall is called after the client's explicit yes."),
        "args": [("session_token", TOKEN_DESC),
                 ("payment_ref", "Payment reference from get_my_payments, e.g. PMT-2026-000006"),
                 ("reason_code", "A return/reason code, e.g. BE01 (wrong beneficiary); decode with lookup_reason_code"),
                 ("client_statement", "The client's description of the problem, in their own words")],
        "write": ("INSERT INTO pending_actions (action_type, client_id, payment_ref, reason_code, client_statement) "
                  "SELECT * FROM recall_proposal_row(CAST(?w_tok AS text), CAST(?w_ref AS text), CAST(?w_rsn AS text), "
                  "CAST(?w_stmt AS text));",
                  [("w_tok", "session_token"), ("w_ref", "payment_ref"), ("w_rsn", "reason_code"),
                   ("w_stmt", "client_statement")]),
        "read": ("SELECT * FROM propose_recall_result(CAST(?r_tok AS text), CAST(?r_ref AS text), CAST(?r_rsn AS text));",
                 [("r_tok", "session_token"), ("r_ref", "payment_ref"), ("r_rsn", "reason_code")]),
    },
    {
        "tool": "confirm_recall", "flow": "confirm_recall_flow", "readonly": False,
        "desc": ("Step 2 of 2: submit the recall the client has explicitly confirmed. Pass the action_id from "
                 "propose_recall. The system re-checks every rule; proposals expire after 15 minutes. Returns SUBMITTED "
                 "with the review case_id (CASE-NNNNN) and the assigned team (Payment Operations) - the payment is set "
                 "to RECALL_REQUESTED and a person decides the recall; funds are not auto-reversed. Otherwise returns "
                 "NOT_EXECUTED with reason_code NO_SUCH_PROPOSAL, EXPIRED, ALREADY_EXECUTED, SESSION_INVALID or a "
                 "rule's code. Only call after the client says yes to the exact proposal; state that a person will "
                 "decide and the funds are not reversed automatically."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id returned by propose_recall, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO review_cases (action_id, client_id, request_type, payment_ref, client_statement, agent_brief, "
                  "assigned_team, currency, requested_amount, parked_action) "
                  "SELECT * FROM recall_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_recall_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_review_case", "flow": "open_review_case_flow", "readonly": False,
        "desc": ("Hand a request that a person must own to the right team: PAYMENT_REPAIR (fix beneficiary details and "
                 "re-send), FEE_WAIVER (waive or refund a fee on a payment; reference_id = that payment_ref), "
                 "COMPENSATION, FRAUD (suspected fraud), SANCTIONS_QUERY (a payment held for sanctions screening) or OTHER. "
                 "A recall is not opened here - use propose_recall. The system routes it, works out what a person could "
                 "approve (for a fee waiver: refund that fee) and returns CASE_OPENED with case_id (CASE-NNNNN), the assigned "
                 "team, reply time and requested amount, ALREADY_OPEN when the same request is already with the team, or "
                 "NOT_OPENED with BAD_TYPE, BAD_REFERENCE or SESSION_INVALID. Supply a neutral brief: facts only, no "
                 "recommendation. A person decides; the assistant never decides, approves, promises or predicts the outcome."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "PAYMENT_REPAIR | FEE_WAIVER | COMPENSATION | FRAUD | SANCTIONS_QUERY | OTHER"),
                 ("client_statement", "The client's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the team: facts only, no recommendation"),
                 ("reference_id", "The payment_ref the request is about (required for FEE_WAIVER when known), or empty")],
        "write": ("INSERT INTO review_cases (client_id, request_type, client_statement, agent_brief, assigned_team, payment_ref, "
                  "currency, requested_amount, parked_action) "
                  "SELECT * FROM service_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_stmt AS text), "
                  "CAST(?w_brief AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_stmt", "client_statement"),
                   ("w_brief", "brief"), ("w_ref", "reference_id")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_tok AS text), CAST(?r_type AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type"), ("r_ref", "reference_id")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified client's investigations (INV-) and review cases (CASE-) with type, status (OPEN, "
                 "APPROVED or REJECTED for review cases), the related payment, the assigned team, the expected response or "
                 "reply date and - once a person has decided - the approved amount and the customer_message from the team. "
                 "Use it when the client asks about the status of a trace, a recall, a held payment, a deduction or a fee "
                 "waiver."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "email_my_confirmation", "flow": "email_my_confirmation_flow", "readonly": False, "idempotent": True,
        "email": True,
        "desc": ("Email the confirmation for an investigation (INV-...), review case (CASE-...), posted cash application "
                 "(CAP-...) or a payment submitted through the assistant (PMT-... from confirm_payment) of this client. The "
                 "system sends the email only when that reference belongs to this session's client; otherwise it returns "
                 "NOT_SENT with reason_code NO_SUCH_REFERENCE or SESSION_INVALID. Call only when the client asks."),
        "args": [("session_token", TOKEN_DESC),
                 ("reference_id", "INV-2026-NNNN, CASE-NNNNN, CAP-NNNNN or PMT-2026-NNNNNN")],
        "write": ("INSERT INTO email_log (client_id, reference_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference_id")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference_id")]),
    },
    # ------------------------------------------------------------------ cash application (receivables)
    {
        "tool": "get_open_invoices", "flow": "get_open_invoices_flow", "readonly": True,
        "desc": ("List the verified client's OPEN invoices (their receivables), oldest first, at most 25: invoice_no, buyer, "
                 "invoice date, due date, currency, amount, open amount, payment terms (for example 2/10 NET 30) and the "
                 "early-pay date. Pass an empty search for all open invoices, or a buyer name, an invoice number or an "
                 "amount. Returns NO_MATCH when nothing matches. These are the candidates for applying an incoming payment."),
        "args": [("session_token", TOKEN_DESC),
                 ("search", "Optional filter: buyer name, invoice number or amount. Empty string = all open invoices")],
        "read": ("SELECT * FROM my_open_invoices(CAST(?tok AS text), CAST(?q AS text));",
                 [("tok", "session_token"), ("q", "search")]),
    },
    {
        "tool": "propose_cash_application", "flow": "propose_cash_application_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 for applying an incoming payment to the client's open invoices. Pass the incoming payment_ref "
                 "(from get_my_payments), the remittance or short-pay note in the client's words, and the "
                 "remittance_match_agent's invoices line, deductions line and confidence exactly as it returned them, plus "
                 "its full answer as agent_notes. The system checks the invoices are this client's open invoices, keeps only "
                 "known deduction reasons, works out the early-pay discount the terms allow and what is disputed, and returns "
                 "PROPOSED with the breakdown (read it back exactly) or NOT_PROPOSED with reason_code NOT_YOUR_PAYMENT, "
                 "NOT_INCOMING, FUNDS_NOT_RECEIVED, ALREADY_APPLIED, NO_INVOICES, INVOICE_NOT_OPEN, LOW_CONFIDENCE, "
                 "OVERPAYMENT, DEDUCTIONS_EXCEED_SHORT_PAY or SESSION_INVALID. Nothing is posted until "
                 "confirm_cash_application."),
        "args": [("session_token", TOKEN_DESC),
                 ("payment_ref", "The incoming payment_ref from get_my_payments, e.g. PMT-2026-000013"),
                 ("remittance_text", "The remittance or short-pay note as the client gave it"),
                 ("invoice_numbers", "The invoices line from remittance_match_agent, exactly as returned (e.g. 4417, 4425)"),
                 ("deductions", "The deductions line from remittance_match_agent, exactly as returned (or NONE)"),
                 ("confidence", "The confidence from remittance_match_agent: HIGH, MEDIUM or LOW"),
                 ("agent_notes", "remittance_match_agent's full answer, unchanged")],
        "write": ("INSERT INTO cash_applications (client_id, payment_ref, remittance_text, currency, invoice_list, "
                  "invoices_total, payment_amount, discount_allowed, discount_accepted, deductions, ignored_items, "
                  "disputed_amount, auto_write_off, review_amount, agent_confidence, agent_notes) "
                  "SELECT * FROM cash_application_row(CAST(?w_tok AS text), CAST(?w_ref AS text), CAST(?w_rem AS text), "
                  "CAST(?w_inv AS text), CAST(?w_ded AS text), CAST(?w_conf AS text), CAST(?w_notes AS text));",
                  [("w_tok", "session_token"), ("w_ref", "payment_ref"), ("w_rem", "remittance_text"),
                   ("w_inv", "invoice_numbers"), ("w_ded", "deductions"), ("w_conf", "confidence"),
                   ("w_notes", "agent_notes")]),
        "read": ("SELECT * FROM propose_cash_application_result(CAST(?r_tok AS text), CAST(?r_ref AS text), "
                 "CAST(?r_inv AS text), CAST(?r_ded AS text), CAST(?r_conf AS text));",
                 [("r_tok", "session_token"), ("r_ref", "payment_ref"), ("r_inv", "invoice_numbers"),
                  ("r_ded", "deductions"), ("r_conf", "confidence")]),
    },
    {
        "tool": "confirm_cash_application", "flow": "confirm_cash_application_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: post the cash application the client has explicitly confirmed. Pass the application_id from "
                 "propose_cash_application. The system re-checks the payment and the invoices; proposals expire after 15 "
                 "minutes. Returns APPLIED with the invoice status and, when a disputed deduction is over the small-balance "
                 "tolerance, the review case_id, team and reply date (a person at Client Servicing decides the deduction); or "
                 "NOT_APPLIED with reason_code NO_SUCH_APPLICATION, EXPIRED, ALREADY_APPLIED, INVOICES_CHANGED or "
                 "SESSION_INVALID. Only call after the client says yes to the exact proposal."),
        "args": [("session_token", TOKEN_DESC),
                 ("application_id", "application_id returned by propose_cash_application, e.g. CAP-00002")],
        "write": ("INSERT INTO cash_postings (application_id) "
                  "SELECT * FROM cash_confirmation_row(CAST(?w_tok AS text), CAST(?w_app AS text));",
                  [("w_tok", "session_token"), ("w_app", "application_id")]),
        "read": ("SELECT * FROM confirm_cash_application_result(CAST(?r_tok AS text), CAST(?r_app AS text));",
                 [("r_tok", "session_token"), ("r_app", "application_id")]),
    },
    # ------------------------------------------------------------------ payments with verification of payee
    {
        "tool": "check_payee_account", "flow": "check_payee_account_flow", "readonly": True,
        "desc": ("Before a new payment, look up a beneficiary account in the name-check service: returns lookup_status OK with "
                 "the account's name_on_file, bank BIC, currency and rail, NOT_FOUND, or SESSION_INVALID. Pass the account "
                 "number the client gave and the beneficiary name they expect on it. Then compare the two names with "
                 "payee_name_match_agent before propose_payment."),
        "args": [("session_token", TOKEN_DESC),
                 ("beneficiary_account", "The beneficiary account number or IBAN the client gave, e.g. 4410028811"),
                 ("typed_name", "The beneficiary name the client expects on that account, in their words")],
        "read": ("SELECT * FROM payee_account_check(CAST(?tok AS text), CAST(?acct AS text), CAST(?nm AS text));",
                 [("tok", "session_token"), ("acct", "beneficiary_account"), ("nm", "typed_name")]),
    },
    {
        "tool": "propose_payment", "flow": "propose_payment_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 for a new payment to a beneficiary account. Pass the from-account (its currency such as USD, "
                 "its last 4 digits or its account_id), the beneficiary account, the name the client gave, the amount, the "
                 "client's own words about the payment, and payee_name_match_agent's verdict, reasons and full answer exactly "
                 "as it returned them. The system checks the rules, combines the agent's verdict with its own name check and "
                 "returns PROPOSED (ask for an explicit yes), PROPOSED_WITH_WARNING (read warning_text word for word first), "
                 "HELD_FOR_REVIEW (nothing sent; Payment Operations verifies the payee - give the case_id and reply date), or "
                 "NOT_PROPOSED with reason_code ACCOUNT_NOT_FOUND, BENEFICIARY_NOT_FOUND, NAME_REQUIRED, CURRENCY_MISMATCH, "
                 "BAD_AMOUNT, OVER_CHANNEL_LIMIT or SESSION_INVALID. Nothing is sent until confirm_payment."),
        "args": [("session_token", TOKEN_DESC),
                 ("from_account", "The client's account to pay from: currency (USD), last 4 digits or account_id"),
                 ("beneficiary_account", "The beneficiary account number from check_payee_account"),
                 ("typed_name", "The beneficiary name the client gave"),
                 ("amount", "Amount in the account currency, e.g. 185000.00"),
                 ("purpose", "The client's own words about what the payment is for"),
                 ("name_verdict", "The verdict from payee_name_match_agent, exactly as returned: MATCH, CLOSE_MATCH or NO_MATCH"),
                 ("name_reasons", "The reasons line from payee_name_match_agent, exactly as returned"),
                 ("agent_notes", "payee_name_match_agent's full answer, unchanged")],
        "write": ("INSERT INTO payment_requests (client_id, account_id, beneficiary_account, typed_name, registered_name, amount, "
                  "currency, rail, purpose, agent_verdict, agent_reasons, ignored_reasons, agent_notes, name_score, name_check, "
                  "status, warning_required) "
                  "SELECT * FROM payment_request_row(CAST(?w_tok AS text), CAST(?w_from AS text), CAST(?w_ben AS text), "
                  "CAST(?w_name AS text), CAST(?w_amt AS text), CAST(?w_purp AS text), CAST(?w_ver AS text), "
                  "CAST(?w_rsn AS text), CAST(?w_notes AS text));",
                  [("w_tok", "session_token"), ("w_from", "from_account"), ("w_ben", "beneficiary_account"),
                   ("w_name", "typed_name"), ("w_amt", "amount"), ("w_purp", "purpose"), ("w_ver", "name_verdict"),
                   ("w_rsn", "name_reasons"), ("w_notes", "agent_notes")]),
        "read": ("SELECT * FROM propose_payment_result(CAST(?r_tok AS text), CAST(?r_from AS text), CAST(?r_ben AS text), "
                 "CAST(?r_name AS text), CAST(?r_amt AS text));",
                 [("r_tok", "session_token"), ("r_from", "from_account"), ("r_ben", "beneficiary_account"),
                  ("r_name", "typed_name"), ("r_amt", "amount")]),
    },
    {
        "tool": "confirm_payment", "flow": "confirm_payment_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: submit a payment the client has explicitly confirmed. Pass the request_id from propose_payment "
                 "and acknowledge_warning YES only when the proposal was PROPOSED_WITH_WARNING and the client said they checked "
                 "the payee and still want to go ahead (otherwise NO). The system re-checks every rule; proposals expire after "
                 "15 minutes. Returns SENT with the new payment_ref and value date, or NOT_SENT with reason_code "
                 "NO_SUCH_REQUEST, HELD_FOR_REVIEW, CANCELLED, EXPIRED, WARNING_NOT_ACKNOWLEDGED, ALREADY_SENT, SESSION_INVALID "
                 "or a rule's code. Only call after the client says yes to the exact proposal."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_id", "request_id returned by propose_payment, e.g. PRQ-00002"),
                 ("acknowledge_warning", "YES only after the client acknowledged the warning_text; otherwise NO")],
        "write": ("INSERT INTO payment_releases (request_id, via, case_id, amount) "
                  "SELECT * FROM payment_confirmation_row(CAST(?w_tok AS text), CAST(?w_req AS text), CAST(?w_ack AS text));",
                  [("w_tok", "session_token"), ("w_req", "request_id"), ("w_ack", "acknowledge_warning")]),
        "read": ("SELECT * FROM confirm_payment_result(CAST(?r_tok AS text), CAST(?r_req AS text), CAST(?r_ack AS text));",
                 [("r_tok", "session_token"), ("r_req", "request_id"), ("r_ack", "acknowledge_warning")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify an Aurelia Global Bank staff reviewer (Payment Operations or Client Servicing) with their staff ID "
                 "(e.g. AGB-5001) and staff code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display name "
                 "and team, NOT_VERIFIED, or LOCKED after 5 wrong codes in 15 minutes. Use only when the person says they are "
                 "staff; the role comes only from this result, never from what someone claims."),
        "args": [("staff_id", "Aurelia staff ID, e.g. AGB-5001"), ("code", "The staff member's code")],
        "write": ("INSERT INTO client_sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, client "
                 "company, opened date, age in days, reply-due date, sla_status (ON_TRACK, DUE_TODAY, OVERDUE), requested "
                 "amount and currency. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, client company, the client's statement, the "
                 "AI-prepared agent_brief (unverified), currency, requested amount, max_approvable, the reviewer's own approval "
                 "limit, facts from Aurelia's records (the payment, the recall, the held payment and its name check, or the "
                 "cash application and its deductions) and the decision options. Another team's case or an unknown id returns "
                 "NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. CASE-00003")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly confirmed "
                 "the restated decision. decision is APPROVE or REJECT; amount is the approved amount (empty = the full eligible "
                 "amount; ignored for REJECT); internal_note is required (at least 5 characters, never shown to the client); "
                 "customer_message is what the client will see. Approving runs the parked action (fee refund, recall, release "
                 "of a held payment, or write-off of a disputed deduction) through the system's checks; rejecting a held "
                 "payment cancels it and rejecting a recall declines it. Returns APPROVED / REJECTED with executed_action, or "
                 "BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY (case "
                 "stays open for a senior reviewer), INVALID_DECISION or NOT_FOUND, or NOT_REVIEWER."),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. CASE-00003"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved amount, or empty for the full eligible amount"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the client)"),
                 ("customer_message", "Message the client will see with the outcome")],
        "write": ("INSERT INTO review_decisions (case_id, reviewer_id, decision, approved_amount, internal_note, customer_message) "
                  "SELECT * FROM decide_case_row(CAST(?w_tok AS text), CAST(?w_cid AS text), CAST(?w_dec AS text), "
                  "CAST(?w_amt AS text), CAST(?w_note AS text), CAST(?w_msg AS text));",
                  [("w_tok", "session_token"), ("w_cid", "case_id"), ("w_dec", "decision"), ("w_amt", "amount"),
                   ("w_note", "internal_note"), ("w_msg", "customer_message")]),
        "read": ("SELECT * FROM decide_case_result(CAST(?r_tok AS text), CAST(?r_cid AS text));",
                 [("r_tok", "session_token"), ("r_cid", "case_id")]),
    },
]

REVIEWER_TOOLS = {"verify_reviewer", "get_review_queue", "get_review_case", "decide_review_case"}
PUBLIC_TOOLS = {"verify_client", "verify_reviewer"}

# Columns that must NEVER appear in any CLIENT tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"passcode_hash", "contact_email", "one_time_code", "internal_note", "agent_brief", "agent_notes",
                  "reviewer_id", "approval_limit", "parked_action", "name_score", "agent_verdict", "agent_reasons",
                  "ignored_reasons", "ignored_items", "agent_confidence", "status_before_recall"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"passcode_hash", "contact_email", "one_time_code", "client_id"}

# Tool of the A2A payment_triage_agent (kept as built: a non-identity PostgreSQL read of the reason-code directory).
# A return/reason code only - never client identity.
LOOKUP_REASON_CODE = {
    "desc": ("Decode a payment return/reason code into plain language. Pass the code exactly as it appears on the "
             "payment (e.g. AC04, BE01, RR04). Returns the matching reason_codes row: match_status (OK or NO_MATCH), "
             "code, rail, plain_language, category (BENEFICIARY, COMPLIANCE, TECHNICAL, ACCOUNT or OTHER) and the "
             "typical_action that resolves it. Read-only. Never pass any client-identifying information."),
    "args": [("code", "Return/reason code, e.g. AC04")],
    "read": ("SELECT * FROM lookup_reason_code(CAST(?code AS text));", [("code", "code")]),
}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (CorporatePaymentsAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM <fn>(CAST(?<placeholder> AS text))) -> #actreturn (rows as JSON text).
# - payment_triage_agent keeps its lookup_reason_code(code) read over reason_codes (no client data).
# - remittance_match_agent / payee_name_match_agent read section / term / meaning guides via ref_<topic>(term); the
#   placeholder is ?lookup, not ?term (a placeholder named like a result column gives duplicate Fields).
# The model can supply only the one lookup value; it can never change the SQL. The tables hold reference data only
# (asserted by test_rules.py). WHO_DECIDES rows are read from service_teams (one source of truth).
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a deduction reason, a note "
                 "abbreviation, a legal-form word or a section name), or an empty string for the whole guide. Never put "
                 "client details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "payment_triage_agent", "tool": "lookup_reason_code", "fn": "lookup_reason_code", "table": "reason_codes",
     "sections": None, "row_key": "match_status",
     "desc": LOOKUP_REASON_CODE["desc"], "args": LOOKUP_REASON_CODE["args"], "read": LOOKUP_REASON_CODE["read"]},
    {"agent": "remittance_match_agent", "tool": "get_remittance_guide", "fn": "ref_remittance_guide",
     "table": "remittance_guide",
     "sections": ["DEDUCTION", "NOTE_PATTERN", "MATCH_RULE", "CONFIDENCE", "REVIEW_LINE", "WHO_DECIDES"], "row_key": "section",
     "desc": ("Reads Aurelia Global Bank's cash-application guide from the database: the deduction reason codes and what "
              "each means, the abbreviations buyers use in remittance notes, the matching rules, how to set the confidence, a "
              "standard review line and who decides a disputed deduction. Rows of section, term, meaning. Read-only reference "
              "data with no client data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_remittance_guide(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "payee_name_match_agent", "tool": "get_payee_name_rules", "fn": "ref_payee_name_rules",
     "table": "payee_name_guide",
     "sections": ["VERDICT", "REASON", "LEGAL_SUFFIX", "ABBREVIATION", "TRANSLITERATION", "WHO_DECIDES"],
     "row_key": "section",
     "desc": ("Reads Aurelia Global Bank's payee name-check rules from the database: what MATCH, CLOSE_MATCH and NO_MATCH "
              "mean, the reason codes, the legal-form words to ignore, standard abbreviations, how accented letters are "
              "written and who verifies a held payment. Rows of section, term, meaning. Read-only reference data with no "
              "client data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_payee_name_rules(CAST(?lookup AS text));", [("lookup", "term")])},
]
GUIDE_TOOLS = [t for t in AGENT_REF_TOOLS if t["sections"]]      # the section / term / meaning guides


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
