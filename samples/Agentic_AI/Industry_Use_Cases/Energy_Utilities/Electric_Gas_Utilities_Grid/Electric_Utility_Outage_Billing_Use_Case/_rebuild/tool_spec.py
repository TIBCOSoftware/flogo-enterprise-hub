"""Single source of truth for the 22 MCP tools of PowerUtilityMCPServer (Ridgeline Power & Light, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_*)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): SQL logs + validates, then the flow sends the email (to the EMAIL_TO app
property) with the SQL-built subject/body only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Session token returned by verify_customer. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the customer to verify again.")
STAFF_TOKEN_DESC = ("Staff session token returned by verify_reviewer. Required; never invent one and never use a "
                    "customer token. NOT_REVIEWER means the caller must verify as staff.")
VERBATIM = " Quote any reason_text to the user as written; never change an outcome."


def _tok(t="tok", a="session_token"):
    return (t, a)


TOOLS = [
    # ------------------------------------------------------------------ identity
    {
        "tool": "verify_customer", "flow": "verify_customer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Ridgeline Power & Light customer with their account number (RPL-100101, RPL 100101 or 100101 all "
                 "work) and the one-time code texted to them. Returns VERIFIED with a session_token (valid 30 minutes) and "
                 "their first name, VERIFY_FAILED, or VERIFY_LOCKED after too many attempts. Call this before any other "
                 "customer tool. Never reveal, guess or hint at codes." + VERBATIM),
        "args": [("account_number", "The customer's Ridgeline account number, e.g. RPL-100101"),
                 ("code", "The one-time code the customer received by text message")],
        "write": ("INSERT INTO sessions (role, principal_id, team) "
                  "SELECT * FROM verify_customer_fn(CAST(?w_acct AS text), CAST(?w_code AS text));",
                  [("w_acct", "account_number"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_acct AS text), CAST(?r_code AS text));",
                 [("r_acct", "account_number"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ scoped reads
    {
        "tool": "get_my_account", "flow": "get_my_account_flow", "readonly": True,
        "desc": ("Get the verified customer's account: name, account number, service address and service area, meter type "
                 "(SMART or ANALOG), connection status (CONNECTED, DISCONNECTED or RECONNECT_PENDING), rate plan, any "
                 "scheduled plan change, balance due, past-due amount and days past due, AutoPay, solar on file and "
                 "medical-baseline protection. Only this customer's account is returned." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_account(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_my_bills", "flow": "get_my_bills_flow", "readonly": True,
        "desc": ("List the verified customer's bills, newest first: bill_id, billing month, period, issue and due date, "
                 "meter read type (ACTUAL or ESTIMATED), kWh, total, credits, paid, outstanding and bill_status "
                 "(PAID / UNPAID / PAST_DUE). Amounts are in US dollars including taxes and fees."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_bills(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_bill_detail", "flow": "get_bill_detail_flow", "readonly": True,
        "desc": ("Get the line items of one bill on the verified customer's account: category, description and amount, "
                 "plus the read type, kWh and bill total. Returns status NOT_FOUND for a bill that is not on this account - "
                 "say you could not find it; never guess its contents."),
        "args": [("session_token", TOKEN_DESC), ("bill_id", "Bill id from get_my_bills, e.g. BL-100101-2609")],
        "read": ("SELECT * FROM bill_detail(CAST(?tok AS text), CAST(?bid AS text));", [_tok(), ("bid", "bill_id")]),
    },
    {
        "tool": "get_bill_comparison", "flow": "get_bill_comparison_flow", "readonly": True,
        "desc": ("Compare the verified customer's latest bill with the previous one by category (base_charge, energy, "
                 "power_cost_rider, credits, taxes_fees, other): previous amount, latest amount and delta, plus both totals "
                 "and the facts behind them - latest read type (ACTUAL or ESTIMATED), latest and previous kWh, kWh in the "
                 "same month last year and the % change, and cooling degree days this year vs last year (higher = hotter). "
                 "All numbers are computed by the system - use them exactly; never compute your own."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM bill_comparison(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_my_usage", "flow": "get_my_usage_flow", "readonly": True,
        "desc": ("Get the verified customer's electricity use for the last 3 billed months: kWh, on-peak and off-peak kWh "
                 "and the on-peak share (smart meters only), solar export kWh, average kWh per day, kWh in the same month "
                 "last year and the % change, cooling degree days vs last year, and the read type."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_usage(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_my_payments", "flow": "get_my_payments_flow", "readonly": True,
        "desc": ("List the verified customer's payments (date, amount, method, reference, bill) with the balance due, the "
                 "past-due amount, whether the account is past due (yes/no), days past due and AutoPay."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_payments(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_plan_options", "flow": "get_plan_options_flow", "readonly": True,
        "desc": ("List every Ridgeline rate plan (STANDARD, TOU, EV, SOLAR) for the verified customer with its rates, what "
                 "it needs (smart meter, solar), the system's estimated monthly base + energy cost on THIS customer's last 3 "
                 "bills, the current plan's estimate, the estimated monthly savings (positive = cheaper than now), whether it "
                 "is the current plan, eligible yes/no with reason_code/reason_text, and the effective date. Quote the "
                 "estimates exactly; never compute savings yourself. Only eligible plans can be proposed." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM plan_options(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_area_outages", "flow": "get_area_outages_flow", "readonly": True,
        "desc": ("Get the known outages in the verified customer's service area (cause, status, start, estimated "
                 "restoration, customers affected, a plain summary; planned outages included) and the customer's own open "
                 "outage ticket if any. Returns NO_KNOWN_OUTAGE when there is none in their area."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM area_outages(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_my_service_activity", "flow": "get_my_service_activity_flow", "readonly": True,
        "desc": ("List the verified customer's outage tickets (new or linked to a known outage), appointments, reconnect "
                 "orders and rate plan changes with their status and dates, newest first."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_service_activity(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_appointment_slots", "flow": "get_appointment_slots_flow", "readonly": True,
        "desc": ("List open technician slots (from tomorrow, with spots left) for appointment_type METER_UPGRADE (analog to "
                 "smart meter, free) or METER_INSPECTION, and whether that type is allowed for the verified customer "
                 "(allowed yes/no with reason_code, e.g. ALREADY_SMART)." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("appointment_type", "METER_UPGRADE | METER_INSPECTION")],
        "read": ("SELECT * FROM appointment_slots_for(CAST(?tok AS text), CAST(?typ AS text));",
                 [_tok(), ("typ", "appointment_type")]),
    },
    # ------------------------------------------------------------------ two-step actions
    {
        "tool": "propose_action", "flow": "propose_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 for REPORT_OUTAGE (target = NO_POWER, PARTIAL_POWER or FLICKERING) or CHANGE_RATE_PLAN "
                 "(target = plan code STANDARD, TOU, EV or SOLAR). The system checks every rule and returns PROPOSED with a "
                 "proposal_id, a summary (for an outage it says whether the report links to a known outage in the area or "
                 "opens a new crew ticket), price (estimated monthly cost for a plan), effective date and expiry (15 "
                 "minutes), or BLOCKED with a reason_code and reason_text. Nothing changes until confirm_action is called "
                 "after the customer explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("action_type", "REPORT_OUTAGE | CHANGE_RATE_PLAN"),
                 ("target", "NO_POWER / PARTIAL_POWER / FLICKERING (outage) or STANDARD / TOU / EV / SOLAR (plan)")],
        "write": ("INSERT INTO pending_actions (customer_id, action_type, target, outcome, reason_code, reason_text, "
                  "summary, price, effective_date, outage_id) "
                  "SELECT * FROM propose_action_fn(CAST(?w_tok AS text), CAST(?w_act AS text), CAST(?w_tgt AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_type"), ("w_tgt", "target")]),
        "read": ("SELECT * FROM propose_action_result(CAST(?r_tok AS text), CAST(?r_act AS text), CAST(?r_tgt AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_type"), ("r_tgt", "target")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: execute a proposal the customer has explicitly confirmed. Pass the proposal_id from "
                 "propose_action. The system re-checks every rule and returns EXECUTED with a reference (e.g. "
                 "RPL-ACT-000101) and, for an outage, the ticket id, whether it is LINKED to a known outage and the "
                 "estimated restoration; or BLOCKED / EXPIRED / NOT_FOUND / ALREADY_DONE with the reason. Only call after "
                 "the customer says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id returned by propose_action, e.g. RPL-PRP-1A2B3C4D")],
        "write": ("INSERT INTO account_events (event_id, reference, proposal_id, customer_id, action_type, target, price, "
                  "effective_date, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ single-step guarded writes
    {
        "tool": "book_appointment", "flow": "book_appointment_flow", "readonly": False, "idempotent": False,
        "desc": ("Book a technician appointment for the verified customer: appointment_type METER_UPGRADE (analog meters "
                 "only) or METER_INSPECTION, in a slot_id from get_appointment_slots. The system checks the slot (exists, "
                 "from tomorrow, spots left), the meter type and that no appointment of that type is already booked, and "
                 "returns BOOKED with an appointment_id (e.g. APPT-000101) or BLOCKED with the reason. Book only the slot "
                 "the customer chose." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("appointment_type", "METER_UPGRADE | METER_INSPECTION"),
                 ("slot_id", "slot_id from get_appointment_slots, e.g. SLOT-03")],
        "write": ("INSERT INTO appointments (appt_no, appointment_id, customer_id, appointment_type, slot_id) "
                  "SELECT * FROM book_appointment_row(CAST(?w_tok AS text), CAST(?w_typ AS text), CAST(?w_slot AS text));",
                  [("w_tok", "session_token"), ("w_typ", "appointment_type"), ("w_slot", "slot_id")]),
        "read": ("SELECT * FROM book_appointment_result(CAST(?r_tok AS text), CAST(?r_typ AS text), CAST(?r_slot AS text));",
                 [("r_tok", "session_token"), ("r_typ", "appointment_type"), ("r_slot", "slot_id")]),
    },
    {
        "tool": "request_reconnect", "flow": "request_reconnect_flow", "readonly": False, "idempotent": False,
        "desc": ("Ask to reconnect the verified customer's disconnected power service. The system reconnects only when the "
                 "service is disconnected, the past-due balance is cleared and no reconnection is already scheduled: it "
                 "returns RECONNECT_SCHEDULED with an order_id (e.g. SO-000101) and the time power will be back, or BLOCKED "
                 "with reason_code (PAST_DUE with amount_due, NOT_DISCONNECTED, ALREADY_REQUESTED). Nobody can override a "
                 "PAST_DUE block in this chat." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "write": ("INSERT INTO service_orders (order_no, order_id, customer_id, order_type, scheduled_by) "
                  "SELECT * FROM reconnect_row(CAST(?w_tok AS text));",
                  [("w_tok", "session_token")]),
        "read": ("SELECT * FROM reconnect_result(CAST(?r_tok AS text));", [("r_tok", "session_token")]),
    },
    # ------------------------------------------------------------------ human-owned
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that needs a person to the right team. request_type is billing_dispute (estimated-read "
                 "disputes, re-bills, refunds, credits - Billing Review), payment_arrangement (paying a past-due balance in "
                 "installments - Credit & Collections), medical_baseline (protection for life-support or medical equipment - "
                 "Customer Care) or hazardous_condition (downed, sparking or burning lines or equipment - Emergency "
                 "Dispatch). summary = the customer's request in their own words; agent_brief = a neutral 1-3 sentence brief "
                 "for the reviewer (e.g. the bill explanation or the triage result; facts only, no recommendation); "
                 "requested_amount = the dollar amount the customer asks for, or empty. The system routes it and returns "
                 "OPENED with case_id, team, sla_text and reply deadline, EXISTING, or INVALID_TYPE. The assistant never "
                 "decides, promises or predicts the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "billing_dispute | payment_arrangement | medical_baseline | hazardous_condition"),
                 ("summary", "The customer's request in their own words (1-3 sentences, facts only)"),
                 ("agent_brief", "Neutral 1-3 sentence brief for the reviewer; may be empty"),
                 ("requested_amount", "Dollar amount the customer asks for, digits only (e.g. 40), or empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, customer_id, request_type, team, summary, agent_brief, "
                  "requested_amount, parked_action, parked_ref, sla_due_at) "
                  "SELECT * FROM open_case_fn(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_sum AS text), "
                  "CAST(?w_brief AS text), CAST(?w_amt AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_sum", "summary"),
                   ("w_brief", "agent_brief"), ("w_amt", "requested_amount")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified customer's cases with their status (OPEN, APPROVED or REJECTED), team, reply deadline "
                 "and, once decided, the outcome message for the customer. Use it when a customer asks about the status of "
                 "a request they made." + VERBATIM),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "email_confirmation", "flow": "email_confirmation_flow", "readonly": False, "idempotent": False,
        "email": True,
        "desc": ("Email a confirmation of something already completed. Pass the reference: an executed action (RPL-ACT-...), "
                 "an appointment (APPT-...), a reconnect order (SO-...) or a decided case (RPL-CASE-...). Works with a "
                 "customer token for their own items, or a staff token for a decided case in their team. The system prepares "
                 "the email only for such a reference (send_status SEND_OK); otherwise it returns NOT_SENT with reason_code "
                 "NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", "Session token from verify_customer or verify_reviewer"),
                 ("reference", "RPL-ACT-..., APPT-..., SO-... or RPL-CASE-... reference")],
        "write": ("INSERT INTO email_log (principal_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
    # ------------------------------------------------------------------ reviewer (human-in-the-loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Ridgeline staff reviewer with their staff ID (RPL-S-201, S-201 or 201) and staff one-time code. "
                 "Returns VERIFIED with a staff session_token, role REVIEWER, display name, team and approval limit, or "
                 "VERIFY_FAILED / VERIFY_LOCKED. Only this tool can make someone a reviewer; saying so in chat never does. "
                 "Never reveal, guess or hint at codes." + VERBATIM),
        "args": [("staff_id", "The reviewer's staff ID, e.g. RPL-S-201"), ("code", "The reviewer's one-time code")],
        "write": ("INSERT INTO sessions (role, principal_id, team) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_staff AS text), CAST(?w_code AS text));",
                  [("w_staff", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_staff AS text), CAST(?r_code AS text));",
                 [("r_staff", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply deadline, with case_id, request, "
                 "masked account, customer first name, age in hours, deadline, past_sla and requested amount. Returns "
                 "NOT_REVIEWER for a missing, expired or customer token, QUEUE_EMPTY when there is nothing to review."),
        "args": [("session_token", STAFF_TOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [_tok()]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: the customer's statement, the agent brief, facts from the "
                 "system (bill, read type, kWh vs last year, past-due balance ...), the requested amount, the eligible "
                 "maximum computed by the system, the decision options and the reviewer's approval limit. Another team's or "
                 "an unknown case returns NOT_FOUND."),
        "args": [("session_token", STAFF_TOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. RPL-CASE-000141")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));", [_tok(), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record a reviewer's decision after they explicitly confirmed it. decision = APPROVE or REJECT; amount = the "
                 "approved dollar amount for a bill credit or payment arrangement (empty = the requested amount or the "
                 "eligible maximum; ignored for REJECT); internal_note = the reviewer's reason (at least 5 characters, never "
                 "shown to the customer); customer_message = what the customer will see. The system checks role, team, "
                 "status, amount and the reviewer's approval limit; on success the case is APPROVED or REJECTED and an "
                 "approval executes the parked action (bill credit, payment arrangement, protection flag). Returns DECIDED "
                 "with what was executed, or BLOCKED with reason_code (NOT_YOUR_TEAM, NOT_FOUND, ALREADY_DECIDED, "
                 "NOTE_REQUIRED, INVALID_DECISION, AMOUNT_INVALID, OVER_AUTHORITY - the case stays open for a senior "
                 "reviewer), or NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", STAFF_TOKEN_DESC), ("case_id", "The case being decided, e.g. RPL-CASE-000141"),
                 ("decision", "APPROVE | REJECT"), ("amount", "Approved dollar amount, digits only, or empty"),
                 ("internal_note", "The reviewer's internal reason, at least 5 characters"),
                 ("customer_message", "The message the customer will see")],
        "write": ("INSERT INTO review_decisions (decision_id, case_id, reviewer_id, decision, approved_amount, "
                  "internal_note, customer_message) "
                  "SELECT * FROM decide_case_row(CAST(?w_tok AS text), CAST(?w_case AS text), CAST(?w_dec AS text), "
                  "CAST(?w_amt AS text), CAST(?w_note AS text), CAST(?w_msg AS text));",
                  [("w_tok", "session_token"), ("w_case", "case_id"), ("w_dec", "decision"), ("w_amt", "amount"),
                   ("w_note", "internal_note"), ("w_msg", "customer_message")]),
        "read": ("SELECT * FROM decide_case_result(CAST(?r_tok AS text), CAST(?r_case AS text));",
                 [("r_tok", "session_token"), ("r_case", "case_id")]),
    },
]

# Columns that must NEVER appear in any tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"otp_code", "one_time_code", "email", "internal_notes", "internal_note", "credit_risk_score"}
# ...and never in a customer-facing output (the reviewer identity stays internal).
CUSTOMER_HIDDEN = HIDDEN_COLUMNS | {"reviewer_id", "display_name"}
CUSTOMER_TOOLS = {t["tool"] for t in TOOLS} - {"verify_reviewer", "get_review_queue", "get_review_case", "decide_review_case"}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (PowerUtilityAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM ref_<topic>(CAST(?lookup AS text))) -> #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no customer, staff, case, session or contact data) - asserted by test_rules.py.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a bill category, a phrase from "
                 "your input, or a section name), or an empty string for the whole guide. Never put customer details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "bill_explainer_agent", "tool": "get_bill_glossary", "fn": "ref_bill_glossary",
     "table": "bill_glossary",
     "sections": ["CATEGORY", "LINE_ITEM", "TOU_PERIOD", "COLUMN", "WEATHER", "READ_TYPE"],
     "desc": ("Reads Ridgeline Power & Light's bill glossary from the utility database: the bill-comparison categories, "
              "every bill line item (base charge, energy, on-peak / off-peak energy, power cost rider, solar and bill "
              "credits, taxes & fees), the time-of-use periods, the comparison and usage columns, cooling degree days "
              "and the meter read types (ACTUAL / ESTIMATED). Rows of section, term, meaning. Read-only reference data "
              "with no customer data. Pass term \"\" for the whole glossary."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_bill_glossary(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "outage_triage_agent", "tool": "get_outage_triage_guide", "fn": "ref_outage_triage",
     "table": "outage_triage_guide",
     "sections": ["CATEGORY", "HAZARD_SIGN", "CONNECTION", "NEXT_PATH", "ROUTING", "SAFETY_LINE", "RULE"],
     "desc": ("Reads Ridgeline Power & Light's outage triage guide from the utility database: the triage categories, "
              "the hazard signs (downed, sparking or burning lines, transformer fires, someone shocked ...), what each "
              "connection status means, the next paths, who acts on a hazard, the standard safety lines (including "
              "when to call 911) and the triage rules. Rows of section, term, meaning. Read-only reference data with no "
              "customer data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_outage_triage(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "rate_plan_agent", "tool": "get_rate_plan_glossary", "fn": "ref_rate_plans",
     "table": "rate_plan_notes",
     "sections": ["PLAN", "TOU_PERIOD", "COLUMN", "REASON_CODE", "ELIGIBILITY", "HABIT"],
     "desc": ("Reads Ridgeline Power & Light's rate plan guide from the utility database: every rate plan with its "
              "prices and what it needs, the on-peak window, the plan-comparison columns, the reason codes, the "
              "eligibility notes and how common habits move a time-of-use bill. Rows of section, term, meaning. "
              "Read-only reference data with no customer data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_rate_plans(CAST(?lookup AS text));", [("lookup", "term")])},
]
