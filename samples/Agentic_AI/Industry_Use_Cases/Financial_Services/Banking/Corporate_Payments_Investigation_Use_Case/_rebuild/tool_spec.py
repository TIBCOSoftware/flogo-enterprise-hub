"""Single source of truth for the MCP tools and the payment_triage_agent's tool.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py
(to run the exact same SQL against PostgreSQL before any app is built).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
CAST(?p AS text) (followed by a space) - see postgres-activity-patterns.md. Write SQL uses ?w_*,
read SQL ?r_* (or ?tok for read-only). Every guarded write is INSERT ... SELECT * FROM <fn>(...),
never VALUES, so no argument reaches a table unchecked.

The email tool is special (email=True): it validates with SQL, then the flow sends the email only
when the SQL authorises it (send_status = SEND; a conditional branch, added in build_mcp.py).
"""

TOKEN_DESC = ("Session token returned by verify_client. Required; never invent a session token. "
              "If a tool answers SESSION_INVALID, ask the client to verify again.")

TOOLS = [
    {
        "tool": "verify_client", "flow": "verify_client_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the client's identity with their Aurelia Global Bank client id (e.g. CLI-2026-00101) and the "
                 "6-digit passcode from their corporate portal. Returns VERIFIED with a session_token (valid 30 minutes) "
                 "and their legal name, NOT_VERIFIED when the id and passcode do not match, or LOCKED after 5 failed "
                 "attempts in 15 minutes (no token is issued while locked, even with the right passcode; offer recovery "
                 "only). Call this before any other client tool. Never reveal, hint at or guess passcodes."),
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
        "write": ("INSERT INTO review_cases (action_id, client_id, request_type, payment_ref, client_statement, agent_brief, assigned_team) "
                  "SELECT * FROM recall_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_recall_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_review_case", "flow": "open_review_case_flow", "readonly": False,
        "desc": ("Hand a request that a person must own to the right team: RECALL, PAYMENT_REPAIR (fix beneficiary "
                 "details and re-send), FEE_WAIVER (waive or refund a charge), COMPENSATION, FRAUD (suspected fraud), "
                 "SANCTIONS_QUERY (a payment held for sanctions screening) or OTHER. The system routes it and returns "
                 "CASE_OPENED with case_id (CASE-NNNNN), the assigned team and reply time in business days, or "
                 "NOT_OPENED with BAD_TYPE or SESSION_INVALID. Supply a neutral brief: facts only, no recommendation. "
                 "The assistant never decides, approves, promises or predicts the outcome of these requests."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "RECALL | PAYMENT_REPAIR | FEE_WAIVER | COMPENSATION | FRAUD | SANCTIONS_QUERY | OTHER"),
                 ("client_statement", "The client's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the team: facts only, no recommendation")],
        "write": ("INSERT INTO review_cases (client_id, request_type, client_statement, agent_brief, assigned_team) "
                  "SELECT * FROM service_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_stmt AS text), "
                  "CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_stmt", "client_statement"),
                   ("w_brief", "brief")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified client's investigations (INV-) and review cases (CASE-) with type, status, the "
                 "related payment, the assigned team and the expected response or reply date."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "email_my_confirmation", "flow": "email_my_confirmation_flow", "readonly": False, "idempotent": True,
        "email": True,
        "desc": ("Email the confirmation for an investigation (INV-...) or review case (CASE-...) of this client. Pass "
                 "the reference_id from confirm_trace, confirm_recall or open_review_case. The system sends the email "
                 "only when that reference belongs to this session's client; otherwise it returns NOT_SENT with "
                 "reason_code NO_SUCH_REFERENCE or SESSION_INVALID. Call only after an investigation or case has been "
                 "opened, and only when the client asks."),
        "args": [("session_token", TOKEN_DESC),
                 ("reference_id", "investigation_id (INV-2026-NNNN) or case_id (CASE-NNNNN)")],
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference_id")]),
    },
]

# Tool of the A2A payment_triage_agent. A return/reason code only - never client identity.
LOOKUP_REASON_CODE = {
    "desc": ("Decode a payment return/reason code into plain language. Pass the code exactly as it appears on the "
             "payment (e.g. AC04, BE01, RR04). Returns the matching reason_codes row: match_status (OK or NO_MATCH), "
             "code, rail, plain_language, category (BENEFICIARY, COMPLIANCE, TECHNICAL, ACCOUNT or OTHER) and the "
             "typical_action that resolves it. Read-only. Never pass any client-identifying information."),
    "args": [("code", "Return/reason code, e.g. AC04")],
    "read": ("SELECT * FROM lookup_reason_code(CAST(?code AS text));", [("code", "code")]),
}
