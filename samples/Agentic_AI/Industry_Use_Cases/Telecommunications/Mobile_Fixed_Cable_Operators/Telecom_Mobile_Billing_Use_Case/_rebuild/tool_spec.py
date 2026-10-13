"""Single source of truth for the 18 MCP tools of MobileBillingMCPServer (Tidewell Mobile, governed): 14 customer tools
and 4 reviewer tools for the human-in-the-loop decision (one server; customer tokens come from verify_customer, reviewer
tokens from verify_reviewer - the role is checked in SQL on every call) - plus AGENT_REF_TOOLS, the one read-only
PostgreSQL reference tool of each A2A agent in MobileBillingAgents.

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
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A customer token does "
               "not work here. If a tool answers NOT_REVIEWER, ask the reviewer to verify again.")

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
                 "customer does not recognise - Fraud Team). reference is the bill_id the dispute or fraud case is about "
                 "(from get_my_bills; empty = the latest bill; ignored for Retention requests). brief is a neutral note "
                 "for the person who decides - for a charge question, the ChargeClassifier's full answer. The system "
                 "routes it, works out what a person could approve (a bill credit, reversing a SIM swap or blocking "
                 "premium content) and returns OPENED with case_id, team, sla_text, requested_amount and if_approved, "
                 "EXISTING when an open case of that type already exists, BAD_REFERENCE for a bill that is not on this "
                 "account, or INVALID_TYPE. The assistant never decides, promises or predicts the outcome, refunds or "
                 "credits." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "contract_cancellation | port_out | billing_dispute | suspected_fraud"),
                 ("summary", "A neutral 1-3 sentence summary of the customer's request in their words: facts only"),
                 ("brief", "Neutral note for the reviewer: the ChargeClassifier's full answer for a charge question, else a "
                           "one-line summary of the facts. No recommendation."),
                 ("reference", "bill_id the dispute or fraud case is about (from get_my_bills), or empty for the latest bill")],
        "write": ("INSERT INTO service_cases (case_no, case_id, customer_id, request_type, summary, agent_brief, "
                  "requested_amount, parked_action) "
                  "SELECT * FROM open_case_fn(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_sum AS text), "
                  "CAST(?w_brief AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_sum", "summary"), ("w_brief", "brief"),
                   ("w_ref", "reference")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "email_action_confirmation", "flow": "email_action_confirmation_flow", "readonly": False,
        "idempotent": False, "email": True,
        "desc": ("Email the confirmation of an action the customer has already completed, or the outcome of one of "
                 "their cases that a person has decided. Pass the reference from confirm_action (e.g. TW-ACT-000101) or a "
                 "decided case_id from get_my_cases (e.g. TW-CASE-000044). The system prepares the email only when that "
                 "reference is an executed action or a decided case on this customer's account (send_status SEND_OK); "
                 "otherwise it returns NOT_SENT with reason_code NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("reference", "The TW-ACT-... reference from confirm_action, or a decided TW-CASE-... case_id")],
        "write": ("INSERT INTO email_log (customer_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified customer's cases (newest first): case_id, request, team, case_status (OPEN, APPROVED "
                 "or REJECTED), opened date, reply-by date, requested amount and - once a person has decided - the "
                 "approved amount, the customer_message and the decision date. Use it when the customer asks about the "
                 "status of a request. Quote customer_message as written." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Tidewell staff reviewer (Billing Disputes, Fraud Team or Retention) with their staff ID (e.g. "
                 "TWS-7001) and staff code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display name "
                 "and team, VERIFY_FAILED, or LOCKED after 5 wrong codes in 15 minutes. Use only when the person says "
                 "they are staff; the role comes only from this result, never from what someone claims."),
        "args": [("staff_id", "Tidewell staff ID, e.g. TWS-7001"), ("code", "The staff member's sign-in code")],
        "write": ("INSERT INTO customer_sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "customer (first name + last initial), opened date, age in days, reply-due date, sla_status (ON_TRACK, "
                 "DUE_TODAY, OVERDUE) and requested amount. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, customer (first name + last initial), the "
                 "customer's statement, the AI-prepared agent_brief (unverified), requested amount, max_approvable, the "
                 "reviewer's own approval limit, facts from Tidewell's records (the bill's charges, credits already "
                 "granted, SIM swap and roaming-day facts, or plan facts), what approval executes and the decision "
                 "options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. TW-CASE-000041")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved credit in dollars "
                 "(empty = the full eligible amount; ignored for REJECT and for cases without an amount); internal_note is "
                 "required (at least 5 characters, never shown to the customer); customer_message is what the customer "
                 "will see. Approving runs the parked action (bill credit, SIM-swap reversal or premium content block) "
                 "through the system's checks; rejecting executes nothing. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, "
                 "AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior reviewer), INVALID_DECISION or NOT_FOUND, "
                 "or NOT_REVIEWER."),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. TW-CASE-000041"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved credit in dollars, or empty for the full eligible amount"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the customer)"),
                 ("customer_message", "Message the customer will see with the outcome")],
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
PUBLIC_TOOLS = {"verify_customer", "verify_reviewer"}

# Columns that must NEVER appear in any CUSTOMER tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"fraud_flag", "risk_score", "internal_notes", "ssn", "email", "otp_code", "one_time_code",
                  "internal_note", "agent_brief", "reviewer_id", "approval_limit", "parked_action"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"fraud_flag", "risk_score", "internal_notes", "ssn", "email", "otp_code", "one_time_code",
                        "mobile_number", "last_name", "customer_id"}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (MobileBillingAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM <fn>(CAST(?lookup AS text))) -> #actreturn (rows as JSON text).
# Each reads a section / term / meaning guide; the placeholder is ?lookup, not ?term (a placeholder named like a result
# column gives duplicate Fields). The model can supply only the one lookup value; it can never change the SQL. The tables
# hold reference data only (asserted by test_rules.py). PLAN rows come from plans and WHO_DECIDES rows from case_routing.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a plan code, a category, a line "
                 "item or a section name), or an empty string for the whole guide. Never put customer details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "PlanRecommender", "tool": "get_plan_guide", "fn": "ref_plan_guide", "table": "plan_guide",
     "sections": ["PLAN", "COLUMN", "REASON_CODE", "ELIGIBILITY", "HABIT", "ADD_ON", "STANDARD_LINE"], "row_key": "section",
     "desc": ("Reads Tidewell Mobile's plan guide from the database: every plan with its data, price and included roaming, "
              "the plan-comparison columns, the reason codes, the eligibility notes, the fit notes for common usage and "
              "travel habits, TravelPass and the standard closing line. Rows of section, term, meaning. Read-only "
              "reference data with no customer data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_plan_guide(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "ChargeClassifier", "tool": "get_charge_taxonomy", "fn": "ref_charge_taxonomy", "table": "charge_taxonomy",
     "sections": ["CATEGORY", "NEXT_PATH", "SIGNAL", "CUSTOMER_LINE", "WHO_DECIDES"], "row_key": "section",
     "desc": ("Reads Tidewell Mobile's charge taxonomy from the database: the charge categories, the suggested next paths, "
              "the signals that decide between them (days abroad, SIM swaps, unrecognised subscriptions, repeated "
              "lines), the customer line for each next path and who decides disputes and fraud cases. Rows of section, "
              "term, meaning. Read-only reference data with no customer data. Pass term \"\" for the whole taxonomy."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_charge_taxonomy(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "BillExplainer", "tool": "get_bill_glossary", "fn": "ref_bill_glossary", "table": "bill_glossary",
     "sections": ["CATEGORY", "LINE_ITEM", "RATE", "COLUMN", "STANDARD_LINE"], "row_key": "section",
     "desc": ("Reads Tidewell Mobile's bill glossary from the database: the bill-comparison categories, what each bill line "
              "item means in plain words, the pay-per-use and TravelPass rates, the comparison columns and the standard "
              "closing line. Rows of section, term, meaning. Read-only reference data with no customer data. Pass term "
              "\"\" for the whole glossary."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_bill_glossary(CAST(?lookup AS text));", [("lookup", "term")])},
]
GUIDE_TOOLS = [t for t in AGENT_REF_TOOLS if t["sections"]]      # all three are section / term / meaning guides


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
