"""Single source of truth for the 21 MCP tools of SemiOrdersMCPServer (Arcwell Components, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

Two personas share one MCP server: BUYER tools resolve only buyer tokens (verify_buyer), REVIEWER tools only reviewer
tokens (verify_reviewer). The email tool is special (email=True): SQL validates + builds the message, the flow sends it
(to the EMAIL_TO app property) only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Buyer session token returned by verify_buyer. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the buyer to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A buyer token does "
               "not work here (NOT_REVIEWER).")
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."
PART_DESC = "Arcwell part number, e.g. AW-MF-4012"


def read(fn, *args):
    """A scoped read: SELECT * FROM fn(CAST(?tok AS text), CAST(?r_x AS text), ...)."""
    phs = [("tok", "session_token")] + [(f"r_{a}", a) for a in args]
    sql = "SELECT * FROM " + fn + "(" + ", ".join(f"CAST(?{p} AS text)" for p, _ in phs) + ");"
    return (sql, phs)


TOOLS = [
    # ------------------------------------------------------------------ buyer identity
    {
        "tool": "verify_buyer", "flow": "verify_buyer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a buyer at an Arcwell customer account with the account number (AC-10021, ac10021 or 10021 all "
                 "work), the buyer's e-mail address on file and the one-time code e-mailed to them. Returns VERIFIED with "
                 "a session_token (valid 60 minutes), the buyer's first name and company, VERIFY_FAILED, or LOCKED after "
                 "too many failed attempts. Call this before any buyer tool. Never reveal, guess or hint at codes. Arcwell "
                 "staff use verify_reviewer instead." + VERBATIM),
        "args": [("account_id", "The customer account number, e.g. AC-10021"),
                 ("email", "The buyer's e-mail address on file"),
                 ("code", "The one-time code the buyer received by e-mail")],
        "write": ("INSERT INTO sessions (role, buyer_id) "
                  "SELECT * FROM verify_buyer_fn(CAST(?w_acct AS text), CAST(?w_email AS text), CAST(?w_code AS text));",
                  [("w_acct", "account_id"), ("w_email", "email"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_buyer_result(CAST(?r_acct AS text), CAST(?r_email AS text), CAST(?r_code AS text));",
                 [("r_acct", "account_id"), ("r_email", "email"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ buyer scoped reads
    {
        "tool": "get_my_account", "flow": "get_my_account_flow", "readonly": True,
        "desc": ("Get the verified buyer's customer account: account number, company, buyer name and title, industry, "
                 "location, payment terms, credit limit, open balance, available credit, credit_status (Good standing or "
                 "ON CREDIT HOLD with the reason), customer since, number of open order lines and the parts the account "
                 "gets change-notice alerts for. Only this account is returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_account"),
    },
    {
        "tool": "search_catalog", "flow": "search_catalog_flow", "readonly": True,
        "desc": ("Search the Arcwell catalog by keywords - part number, family (MOSFET, Schottky diode, Gate driver, "
                 "Microcontroller, Voltage regulator, Capacitor, TVS diode, Op amp, Logic), key specs (e.g. 650V 8A) or "
                 "package (TO-220, SOD-123, QFN-32 ...). Every keyword must match; spaces and punctuation are ignored. "
                 "Returns part_number, family, description, key specs, package, AEC grade, lifecycle (ACTIVE, NRND, EOL, "
                 "OBSOLETE), last-time-buy date, stock, lead time, MOQ and the lowest volume price. Status NO_MATCH = "
                 "nothing found; try fewer keywords. Use it to gather candidates for part_finder_agent."),
        "args": [("session_token", TOKEN_DESC),
                 ("query", "Keywords, e.g. 'MOSFET 650V TO-220' or a part number; empty lists the whole catalog")],
        "read": read("catalog_search", "query"),
    },
    {
        "tool": "get_part_details", "flow": "get_part_details_flow", "readonly": True,
        "desc": ("Get one Arcwell part: description, key specs, package, AEC grade, RoHS, lifecycle with a lifecycle_note "
                 "(including the last-time-buy date and replacement for end-of-life parts), MOQ, warranty months, the full "
                 "price-break table, stock, factory lead time, next receipt, number of recent change notices and the "
                 "datasheet link. NOT_FOUND = not in the catalog."),
        "args": [("session_token", TOKEN_DESC), ("part_number", PART_DESC)],
        "read": read("part_details", "part_number"),
    },
    {
        "tool": "get_price_and_stock", "flow": "get_price_and_stock_flow", "readonly": True,
        "desc": ("Get the price and availability of a part for a quantity: the unit price from the price-break table, the "
                 "tier applied, the extended price, the next price break, MOQ and whether the quantity meets it, stock and "
                 "whether it covers the quantity, the ship date if ordered today, lead time, next receipt, lifecycle and a "
                 "note. All numbers come from Arcwell's system - quote them exactly and never compute a price yourself. "
                 "This is information; propose_order re-checks everything."),
        "args": [("session_token", TOKEN_DESC), ("part_number", PART_DESC),
                 ("quantity", "Number of pieces, e.g. 5000")],
        "read": read("price_and_stock", "part_number", "quantity"),
    },
    {
        "tool": "get_cross_references", "flow": "get_cross_references_flow", "readonly": True,
        "desc": ("List Arcwell cross-references for a part: alt_part, relation (DROP_IN_REPLACEMENT, PIN_COMPATIBLE, "
                 "HIGHER_RATED, FUNCTIONAL_EQUIVALENT), notes on what differs, and the alternative's description, package, "
                 "lifecycle, stock and lowest volume price. Status NONE = no cross-reference on file."),
        "args": [("session_token", TOKEN_DESC), ("part_number", PART_DESC)],
        "read": read("cross_refs", "part_number"),
    },
    {
        "tool": "get_lifecycle_notices", "flow": "get_lifecycle_notices_flow", "readonly": True,
        "desc": ("List change notices (PCN) and end-of-life notices (EOL): pcn_id, part, type, title, the full notice "
                 "text, published / effective / last-time-buy dates, replacement part, the buyer's open lines on that part "
                 "(quantity and promised date) and whether the account is subscribed. Pass a part_number for one part, or "
                 "leave it empty for every notice on parts the account has open orders for or subscribes to."),
        "args": [("session_token", TOKEN_DESC), ("part_number", "Arcwell part number, or empty for all notices that affect the account")],
        "read": read("lifecycle_notices", "part_number"),
    },
    {
        "tool": "get_my_orders", "flow": "get_my_orders_flow", "readonly": True,
        "desc": ("List the verified buyer's orders, one row per line: order number (e.g. SO-2026-0014), PO number, order "
                 "date, line_ref (e.g. SO-2026-0014/2 - use it for request_expedite), part, description, quantity, unit "
                 "price, extended price, requested and promised dates, line_status (OPEN, PARTIALLY_SHIPPED, SHIPPED), "
                 "shipped quantity and date, and the warranty end date for shipped lines."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_orders"),
    },
    {
        "tool": "get_my_rmas", "flow": "get_my_rmas_flow", "readonly": True,
        "desc": ("List the verified buyer's returns (RMAs): rma_id, order, part, quantity, defect type, rma_status "
                 "(UNDER_REVIEW, APPROVED, REJECTED), opened date, credit memo (reference and amount once approved), the "
                 "Quality Engineering case and its status, and the customer_message from the team once decided."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_rmas"),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified buyer's account's requests that a person decides: case_id, request, what it is about, "
                 "team, case_status (OPEN, APPROVED, REJECTED), opened and reply-due dates, what was requested, the "
                 "outcome, the decision date and the customer_message from the team once decided. Use it when the buyer "
                 "asks about the status of a request, a credit review or an RMA decision."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_cases"),
    },
    # ------------------------------------------------------------------ two-step actions
    {
        "tool": "propose_order", "flow": "propose_order_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to place an order for the verified buyer's account. Pass the part number, the quantity in "
                 "pieces and the buyer's PO number. The system prices it from the price-break table and checks the part, "
                 "lifecycle and last-time-buy date, MOQ, stock, credit hold and credit limit, then returns PROPOSED with a "
                 "proposal_id, a priced summary and the ship date (expires in 15 minutes), or BLOCKED with a reason_code "
                 "and reason_text. A BLOCKED LARGE_LAST_TIME_BUY also returns a proposal_id: that is the reference_id for "
                 "open_service_case last_time_buy. Nothing is ordered until confirm_action is called after the buyer "
                 "explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("part_number", PART_DESC),
                 ("quantity", "Number of pieces, e.g. 5000"),
                 ("po_number", "The buyer's purchase order number, e.g. NPS-PO-8120")],
        "write": ("INSERT INTO pending_actions (account_id, buyer_id, action_type, target_key, part_number, quantity, unit_price, "
                  "extended, po_number, outcome, reason_code, reason_text, summary, ship_date) "
                  "SELECT * FROM propose_order_fn(CAST(?w_tok AS text), CAST(?w_part AS text), CAST(?w_qty AS text), "
                  "CAST(?w_po AS text));",
                  [("w_tok", "session_token"), ("w_part", "part_number"), ("w_qty", "quantity"), ("w_po", "po_number")]),
        "read": ("SELECT * FROM propose_order_result(CAST(?r_tok AS text), CAST(?r_part AS text), CAST(?r_qty AS text), "
                 "CAST(?r_po AS text));",
                 [("r_tok", "session_token"), ("r_part", "part_number"), ("r_qty", "quantity"), ("r_po", "po_number")]),
    },
    {
        "tool": "propose_rma", "flow": "propose_rma_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to open a return (RMA) for parts that failed or arrived wrong. Pass the order number and part "
                 "number from get_my_orders, the quantity to return, the buyer's own description of the problem, and the "
                 "defect_type, safety_relevant (YES/NO) and the full answer (triage_brief) from rma_triage_agent. The "
                 "system checks the line is the buyer's, shipped, inside the warranty and that the quantity is not more "
                 "than shipped minus earlier returns, then returns PROPOSED with a proposal_id and summary (expires in 15 "
                 "minutes) or BLOCKED with a reason. Nothing is opened until confirm_action is called after the buyer "
                 "explicitly says yes. Quality Engineering decides every RMA - never promise a credit." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("order_number", "Order number from get_my_orders, e.g. SO-2026-0011"),
                 ("part_number", PART_DESC),
                 ("quantity", "Number of pieces to return, e.g. 40"),
                 ("failure_description", "The buyer's own words about what went wrong: facts only"),
                 ("defect_type", "From rma_triage_agent: ELECTRICAL_FAILURE | PARAMETRIC_DRIFT | MECHANICAL_DAMAGE | SOLDERABILITY | WRONG_PART | OTHER"),
                 ("safety_relevant", "From rma_triage_agent: YES or NO"),
                 ("triage_brief", "rma_triage_agent's full answer, for the quality engineer (or empty)")],
        "write": ("INSERT INTO pending_actions (account_id, buyer_id, action_type, target_key, part_number, quantity, unit_price, "
                  "extended, order_number, line_id, failure_description, defect_type, safety_relevant, triage_brief, outcome, "
                  "reason_code, reason_text, summary) "
                  "SELECT * FROM propose_rma_fn(CAST(?w_tok AS text), CAST(?w_ord AS text), CAST(?w_part AS text), "
                  "CAST(?w_qty AS text), CAST(?w_desc AS text), CAST(?w_def AS text), CAST(?w_saf AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_ord", "order_number"), ("w_part", "part_number"), ("w_qty", "quantity"),
                   ("w_desc", "failure_description"), ("w_def", "defect_type"), ("w_saf", "safety_relevant"),
                   ("w_brief", "triage_brief")]),
        "read": ("SELECT * FROM propose_rma_result(CAST(?r_tok AS text), CAST(?r_ord AS text), CAST(?r_part AS text), "
                 "CAST(?r_qty AS text));",
                 [("r_tok", "session_token"), ("r_ord", "order_number"), ("r_part", "part_number"), ("r_qty", "quantity")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: execute a proposal the buyer has explicitly confirmed. Pass the proposal_id from propose_order "
                 "or propose_rma. The system re-checks every rule and returns EXECUTED with a reference (the new order "
                 "number SO-... or RMA number RMA-...; for an RMA also the Quality Engineering case_id, team and reply "
                 "date), or BLOCKED / EXPIRED (after 15 minutes) / NOT_FOUND / ALREADY_DONE with the reason. Only call "
                 "after the buyer says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from a propose tool, e.g. ARC-PRP-1A2B3C4D")],
        "write": ("INSERT INTO account_events (event_id, reference, proposal_id, account_id, buyer_id, action_type, part_number, "
                  "quantity, unit_price, extended, po_number, order_number, line_id, failure_description, defect_type, "
                  "safety_relevant, triage_brief, ship_date, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ single guarded writes
    {
        "tool": "request_expedite", "flow": "request_expedite_flow", "readonly": False, "idempotent": False,
        "desc": ("Pull in the ship date of one of the verified buyer's unshipped order lines. Pass the line_ref from "
                 "get_my_orders (e.g. SO-2026-0014/1) and the new date (YYYY-MM-DD). The system checks the line is the "
                 "buyer's, not shipped, that the date is in the future and earlier than the promised date, and that stock "
                 "or confirmed supply can meet it. Returns EXPEDITED with a reference (EXP-...) and the new promised date, "
                 "or BLOCKED with a reason - FACTORY_EXPEDITE_REQUIRED gives the earliest date possible without the factory "
                 "(offer open_service_case factory_expedite for anything earlier)." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("line_ref", "Order line from get_my_orders, e.g. SO-2026-0014/1"),
                 ("new_date", "Requested new ship date, YYYY-MM-DD")],
        "write": ("INSERT INTO expedite_events (event_id, reference, line_id, account_id, old_date, new_date, source, case_id) "
                  "SELECT * FROM expedite_row(CAST(?w_tok AS text), CAST(?w_line AS text), CAST(?w_date AS text));",
                  [("w_tok", "session_token"), ("w_line", "line_ref"), ("w_date", "new_date")]),
        "read": ("SELECT * FROM expedite_result(CAST(?r_tok AS text), CAST(?r_line AS text));",
                 [("r_tok", "session_token"), ("r_line", "line_ref")]),
    },
    {
        "tool": "subscribe_pcn_alerts", "flow": "subscribe_pcn_alerts_flow", "readonly": False, "idempotent": False,
        "desc": ("Subscribe the verified buyer's account to Arcwell change-notice e-mails (PCN and end-of-life notices) for "
                 "one part. Returns SUBSCRIBED, ALREADY_SUBSCRIBED (nothing added) or PART_NOT_FOUND, with the number of "
                 "notices already on file for that part." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("part_number", PART_DESC)],
        "write": ("INSERT INTO pcn_subscriptions (account_id, buyer_id, part_number) "
                  "SELECT * FROM subscribe_row(CAST(?w_tok AS text), CAST(?w_part AS text));",
                  [("w_tok", "session_token"), ("w_part", "part_number")]),
        "read": ("SELECT * FROM subscribe_result(CAST(?r_tok AS text), CAST(?r_part AS text));",
                 [("r_tok", "session_token"), ("r_part", "part_number")]),
    },
    # ------------------------------------------------------------------ human-owned cases, email
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that needs a person to the right Arcwell team. request_type is last_time_buy (reference_id "
                 "= the proposal_id of the LARGE_LAST_TIME_BUY propose_order result), factory_expedite (reference_id = the "
                 "line_ref, requested_date = the date the buyer needs, YYYY-MM-DD), credit_review (amount = the credit limit "
                 "asked for in dollars, or empty to ask only for a credit-hold release), or special_pricing (price match or "
                 "special price; reference_id = the part number if known). summary is a neutral 1-3 sentence summary in the "
                 "buyer's own words. Leave fields empty when they do not apply. The system routes it and returns OPENED with "
                 "case_id, team and reply time, EXISTING, or BLOCKED / INVALID_TYPE with a reason. RMAs are not opened "
                 "here (use propose_rma). The assistant never decides, promises or predicts the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "last_time_buy | factory_expedite | credit_review | special_pricing"),
                 ("summary", "Neutral summary of the request in the buyer's words: facts only"),
                 ("reference_id", "proposal_id (last_time_buy), line_ref (factory_expedite), part number (special_pricing), or empty"),
                 ("requested_date", "Date needed, YYYY-MM-DD (factory_expedite only), else empty"),
                 ("amount", "Credit limit asked for in dollars (credit_review only), else empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, account_id, buyer_id, request_type, summary, reference_id, "
                  "part_number, quantity, unit_price, po_number, line_id, requested_date, requested_amount, parked_action, "
                  "sla_due_at) "
                  "SELECT * FROM open_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_sum AS text), "
                  "CAST(?w_ref AS text), CAST(?w_date AS text), CAST(?w_amt AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_sum", "summary"), ("w_ref", "reference_id"),
                   ("w_date", "requested_date"), ("w_amt", "amount")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "email_confirmation", "flow": "email_confirmation_flow", "readonly": False, "idempotent": False,
        "email": True,
        "desc": ("Email the buyer a confirmation of something already done for their account: an order (SO-... reference "
                 "from confirm_action), a return (RMA-...), an expedite (EXP-...), or a decided request (ARC-CASE-...). The "
                 "system prepares the email only when that reference belongs to this account and is done (send_status "
                 "SEND_OK); otherwise NOT_SENT with reason_code NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("reference", "SO-..., RMA-..., EXP-... or ARC-CASE-... reference")],
        "write": ("INSERT INTO email_log (account_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify an Arcwell staff reviewer (Quality Engineering, Sales & Pricing or Credit) with their staff ID "
                 "(e.g. ACS-5101) and staff one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, "
                 "display name and team, or VERIFY_FAILED / LOCKED. Use only when the person says they are Arcwell staff; "
                 "the role comes only from this result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Arcwell staff ID, e.g. ACS-5101"), ("code", "The staff member's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases, safety-relevant first, then by reply-due date, with "
                 "case_id, request, priority, customer (company + buyer first name and last initial), opened date, age in "
                 "days, reply-due date, sla_status (ON_TRACK, DUE_TODAY, OVERDUE) and what is requested. Status EMPTY = no "
                 "open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, priority, customer, the customer's "
                 "statement, the AI-prepared agent_brief (unverified), what is requested, max_approvable with its "
                 "amount_unit (USD credit, units, or USD credit limit), the reviewer's own approval limit, facts from "
                 "Arcwell's records and the decision options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. ARC-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is what is approved in the case's "
                 "amount_unit (RMA: credit in dollars; last-time-buy: quantity in pieces; credit review: the new credit "
                 "limit in dollars; empty = the full requested amount; ignored for REJECT and for cases without an "
                 "amount); internal_note is required (at least 5 characters, never shown to the customer); "
                 "customer_message is what the buyer will see. Approving runs the parked action (credit memo, last-time-buy "
                 "order, factory expedite or credit change) through the system's checks. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, "
                 "AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior reviewer), ACTION_BLOCKED or NOT_FOUND, or "
                 "NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. ARC-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved amount in the case's amount_unit, or empty"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the customer)"),
                 ("customer_message", "Message the buyer will see with the outcome")],
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

# Columns that must NEVER appear in any BUYER tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"email", "otp_code", "one_time_code", "internal_note", "agent_brief", "reviewer_id", "approval_limit",
                  "parked_action", "triage_brief"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"email", "otp_code", "one_time_code", "last_name", "buyer_id"}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (SemiOrdersAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM ref_<topic>(CAST(?lookup AS text))) -> #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no customer, staff, case, session or contact data) - asserted by test_rules.py.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a section name or a phrase from "
                 "your input), or an empty string for the whole guide (best). Never put customer details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "part_finder_agent", "tool": "get_part_selection_guide", "fn": "ref_part_selection",
     "table": "part_selection_guide",
     "sections": ["ABBREVIATION", "COLUMN", "PACKAGE", "RANKING", "EXCLUDE", "REPLACEMENT", "NOTE_LINE"],
     "desc": ("Reads Arcwell's part-selection guide from the catalog database: BOM abbreviations, what the catalog columns "
              "mean (lifecycle, AEC grade), the package outlines, the ranking order, the exclusion codes, Arcwell's "
              "recommended replacement for each end-of-life, not-recommended or obsolete part, and the standard note "
              "lines. Rows of section, term, meaning. Read-only reference data with no customer data. Pass term \"\" for "
              "the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_part_selection(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "rma_triage_agent", "tool": "get_defect_taxonomy", "fn": "ref_defect_taxonomy",
     "table": "defect_taxonomy",
     "sections": ["DEFECT_TYPE", "SAFETY_SIGN", "EVIDENCE", "ROUTING", "RULE"],
     "desc": ("Reads Arcwell's RMA defect taxonomy from the quality database: the six defect types with examples, the "
              "safety signs that make a failure safety-relevant, the evidence Quality Engineering asks for with each "
              "defect type, who decides the disposition, and the triage rules. Rows of section, term, meaning. Read-only "
              "reference data with no customer data. Pass term \"\" for the whole taxonomy."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_defect_taxonomy(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "pcn_impact_agent", "tool": "get_pcn_glossary", "fn": "ref_pcn_guide",
     "table": "pcn_change_guide",
     "sections": ["NOTICE_TYPE", "CHANGE_TYPE", "TERM", "LINE_STATUS", "RULE"],
     "desc": ("Reads Arcwell's change-notice guide from the catalog database: PCN and EOL notice types, the change types "
              "with what a buyer should check for each, change-notice terms (effective date, last-time-buy, "
              "form-fit-function, MSL, date code, qualification report) in everyday words, the standard line-status "
              "phrases and the rules. Rows of section, term, meaning. Read-only reference data with no customer data. "
              "Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_pcn_guide(CAST(?lookup AS text));", [("lookup", "term")])},
]
