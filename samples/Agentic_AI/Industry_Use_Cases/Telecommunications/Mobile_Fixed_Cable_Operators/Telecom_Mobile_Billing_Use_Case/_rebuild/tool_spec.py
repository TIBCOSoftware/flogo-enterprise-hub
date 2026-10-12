"""Single source of truth for the 13 MCP tools of MobileBillingMCPServer (Tidewell Mobile, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py (to run the exact same SQL against
PostgreSQL before any app is built).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_*)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): it logs + validates with SQL, then the flow sends the email (to the
EMAIL_TO app property) with the SQL-built subject/body only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Session token returned by verify_customer. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the customer to verify again.")
VERBATIM = " Quote any reason_text to the customer as written; never change an outcome."

TOOLS = [
    {
        "tool": "verify_customer", "flow": "verify_customer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the customer with their Tidewell mobile number (2125550101, 212-555-0101, (212) 555-0101 "
                 "or +1 212 555 0101 all work) and the one-time code sent to that number. Returns VERIFIED with a "
                 "session_token (valid 30 minutes) and their first name, or VERIFY_FAILED. Call this before any "
                 "other tool. Never reveal, guess or hint at codes." + VERBATIM),
        "args": [("mobile_number", "The customer's Tidewell mobile number, e.g. (212) 555-0101"),
                 ("otp", "The one-time code the customer received by text message")],
        "write": ("INSERT INTO customer_sessions (customer_id) "
                  "SELECT customer_id FROM verify_customer_fn(CAST(?w_mob AS text), CAST(?w_otp AS text));",
                  [("w_mob", "mobile_number"), ("w_otp", "otp")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_mob AS text), CAST(?r_otp AS text));",
                 [("r_mob", "mobile_number"), ("r_otp", "otp")]),
    },
    {
        "tool": "get_my_account", "flow": "get_my_account_flow", "readonly": True,
        "desc": ("Get the verified customer's account: name, mobile number, current plan (code, name, monthly price "
                 "in USD, data allowance, roaming included), contract type (device installment plan or "
                 "month-to-month) and device installment end date, account_status (ACTIVE or ACCOUNT_HOLD), roaming "
                 "limit, TravelPass enrolment, AutoPay day, any scheduled plan change and the last SIM swap date. "
                 "Only this customer's account is returned." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_account(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_bills", "flow": "get_my_bills_flow", "readonly": True,
        "desc": ("List the verified customer's bills, newest first: bill_id, billing period, issue and due date, "
                 "total, amount paid, outstanding amount and bill_status (PAID / UNPAID / OVERDUE). Amounts are in "
                 "US dollars, including taxes & fees."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_bills(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_bill_detail", "flow": "get_bill_detail_flow", "readonly": True,
        "desc": ("Get the line items of one bill on the verified customer's account: category, description, amount "
                 "and charge date, plus the bill total. Returns status NOT_FOUND for a bill that is not on this "
                 "account - say you could not find it; never guess its contents."),
        "args": [("session_token", TOKEN_DESC), ("bill_id", "Bill id from get_my_bills, e.g. TWB-0101-2609")],
        "read": ("SELECT * FROM bill_detail(CAST(?tok AS text), CAST(?bid AS text));",
                 [("tok", "session_token"), ("bid", "bill_id")]),
    },
    {
        "tool": "get_bill_comparison", "flow": "get_bill_comparison_flow", "readonly": True,
        "desc": ("Compare the verified customer's latest bill with the previous one by category (plan, roaming, "
                 "premium_content, voice_sms, taxes_fees, other): previous amount, latest amount and the delta, plus "
                 "both bill totals. The deltas are computed by the system - use these numbers exactly; never "
                 "compute your own."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM bill_comparison(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_usage", "flow": "get_my_usage_flow", "readonly": True,
        "desc": ("Get the verified customer's usage in the current bill cycle: data used vs allowance, voice minutes "
                 "and texts used, days abroad and roaming charges so far this cycle, the roaming limit, TravelPass "
                 "enrolment, days left in the cycle, and for each of the last 3 cycles the data used and the "
                 "countries/days the phone was used abroad (from network roaming records)."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_usage(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_subscriptions", "flow": "get_my_subscriptions_flow", "readonly": True,
        "desc": ("List the verified customer's premium content subscriptions (item_id such as SUB-1001, service name, "
                 "ACTIVE or CANCELLED, monthly price, start date, end date) and their TravelPass enrolment (ENROLLED "
                 "or NOT_ENROLLED; $10 per day, charged only on days used abroad). Use the item_id when proposing "
                 "CANCEL_SUBSCRIPTION."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_subscriptions(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_payments", "flow": "get_my_payments_flow", "readonly": True,
        "desc": ("List the verified customer's payments (date, amount, method, reference, bill) with the current "
                 "balance_due, the past_due_amount, whether the account is overdue (yes/no), days overdue and the "
                 "AutoPay day."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_payments(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_eligible_plans", "flow": "get_eligible_plans_flow", "readonly": True,
        "desc": ("List every other Tidewell plan for the verified customer (data allowance, monthly price in USD, "
                 "device installment, roaming included) with change_type (UPGRADE / DOWNGRADE), the date it would "
                 "take effect, the monthly price difference, allowed (yes/no) and, when not allowed, the "
                 "reason_code and reason_text. Only plans with allowed = yes can be proposed." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM eligible_plans(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "propose_action", "flow": "propose_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 for any account change. action_type is one of ADD_TRAVEL_PASS (target = ON; enrols the "
                 "line in TravelPass for future trips, $10 per day used abroad), SET_ROAMING_LIMIT (target = 0, 50, "
                 "100 or 200 US dollars per bill cycle on pay-per-use roaming; 0 blocks pay-per-use roaming), "
                 "CANCEL_SUBSCRIPTION (target = premium content item_id, e.g. SUB-1001) or CHANGE_PLAN (target = "
                 "plan code BASIC5, ESS15, UNLPLUS, UNLPREM or UNLPLUSD). The system checks every rule and returns "
                 "PROPOSED with a proposal_id, a summary, price, effective date and expiry (15 minutes), or BLOCKED "
                 "with a reason_code and reason_text. Nothing changes until confirm_action is called after the "
                 "customer explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("action_type", "ADD_TRAVEL_PASS | SET_ROAMING_LIMIT | CANCEL_SUBSCRIPTION | CHANGE_PLAN"),
                 ("target", "ON (TravelPass), limit 0/50/100/200 (roaming limit), subscription item_id or plan code")],
        "write": ("INSERT INTO pending_actions (customer_id, action_type, target, outcome, reason_code, reason_text, "
                  "summary, price, effective_date) "
                  "SELECT * FROM propose_action_fn(CAST(?w_tok AS text), CAST(?w_act AS text), CAST(?w_tgt AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_type"), ("w_tgt", "target")]),
        "read": ("SELECT * FROM propose_action_result(CAST(?r_tok AS text), CAST(?r_act AS text), CAST(?r_tgt AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_type"), ("r_tgt", "target")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: execute a proposal the customer has explicitly confirmed. Pass the proposal_id from "
                 "propose_action. The system re-checks every rule and returns EXECUTED with a reference (e.g. "
                 "TW-ACT-000101), or BLOCKED / EXPIRED (proposals expire after 15 minutes) / NOT_FOUND / ALREADY_DONE "
                 "with the reason. Only call after the customer says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id returned by propose_action, e.g. TW-PRP-1A2B3C4D")],
        "write": ("INSERT INTO account_events (event_id, reference, proposal_id, customer_id, action_type, target, price, "
                  "effective_date, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that needs a person to the right team. request_type is contract_cancellation or "
                 "port_out (moving the number to another provider) - both Retention; billing_dispute (refunds, "
                 "credits, waivers, disputed charges - Billing Disputes); or suspected_fraud (SIM swap, charges the "
                 "customer does not recognise - Fraud Team). The system routes it and returns OPENED with case_id, "
                 "team and sla_text, EXISTING when an open case of that type already exists, or INVALID_TYPE. The "
                 "assistant never decides, promises or predicts the outcome, refunds or credits." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "contract_cancellation | port_out | billing_dispute | suspected_fraud"),
                 ("summary", "A neutral 1-3 sentence summary of the customer's request in their words: facts only")],
        "write": ("INSERT INTO service_cases (case_no, case_id, customer_id, request_type, summary) "
                  "SELECT * FROM open_case_fn(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_sum AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_sum", "summary")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "email_action_confirmation", "flow": "email_action_confirmation_flow", "readonly": False,
        "idempotent": False, "email": True,
        "desc": ("Email the confirmation of an action the customer has already completed. Pass the reference from "
                 "confirm_action (e.g. TW-ACT-000101). The system prepares the email only when that reference is an "
                 "executed action on this customer's account (send_status SEND_OK); otherwise it returns NOT_SENT "
                 "with reason_code NOT_FOUND or SESSION_INVALID. Call only after a successful confirm_action." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("reference", "The TW-ACT-... reference returned by confirm_action")],
        "write": ("INSERT INTO email_log (customer_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
]

# Columns that must NEVER appear in any tool output (asserted by test_rules.py).
HIDDEN_COLUMNS = {"fraud_flag", "risk_score", "internal_notes", "ssn", "email", "otp_code"}
