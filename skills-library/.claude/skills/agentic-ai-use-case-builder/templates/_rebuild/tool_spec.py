# =============================================================================
# WORKED-EXAMPLE TEMPLATE - Airline Passenger Services (Meridian) governed use case.
#
# This is the proven tool spec from the Airline Passenger Services worked example.
# To build your own governed use case, copy the whole _rebuild/ folder into
# <YourUseCase>/_rebuild/ and ADAPT it (keep the structure - the value is a working
# reference - just change):
#   - app names / prefix       (PassengerServices... -> <YourUseCase>...)
#   - the tool_spec entries     below: tools, args, SQL (scoped reads + guarded writes)
#   - REVIEWER_TOOL_SPECS       after TOOLS: the 4 staff reviewer tools (generic placeholders; governed-patterns.md section 9)
#   - AGENT_REF_TOOLS           at the end: one ref_<topic>() reference read per A2A agent (generic placeholders)
#   - ports / endpoint paths    (9850 / 9852 / 9853, /passenger-services-gov-mcp, ...)
#   - the test assertions       (test_rules.py / mcp_smoke.py / chat_e2e.py expectations)
#
# References (relative to this file):
#   ..\..\references\fda-build-recipes.md  - the fda-only build driver pattern
#   ..\..\references\governed-patterns.md  - scoped reads / guarded writes / safe prompts
#   ..\..\references\testing-ladder.md     - the SQL -> MCP -> chat test ladder
#
# No secrets here: credentials are read at RUN time from config.md / env (see fda_common.py).
# =============================================================================
"""Single source of truth for the MCP tools (TOOLS) and the A2A agents' reference tools (AGENT_REF_TOOLS).

Imported by build_mcp.py / build_agents.py (to generate the apps), by test_rules.py (to run the exact
same SQL against PostgreSQL before any app is built) and by a2a_smoke.py / chat_e2e.py.

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): it validates with SQL, then the flow sends the email only
when the SQL authorises it (a conditional branch, added in build_mcp.py).
"""

TOKEN_DESC = ("Session token returned by verify_traveller. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the traveller to verify again.")

TOOLS = [
    {
        "tool": "verify_traveller", "flow": "verify_traveller_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the traveller's identity with their 6-character PNR (booking reference) and the 4-digit "
                 "PIN from their Meridian app or booking email. Returns VERIFIED with a session_token (valid 60 "
                 "minutes), their name and loyalty tier, or NOT_VERIFIED. Call this before any other tool. "
                 "Never reveal or guess PINs."),
        "args": [("pnr", "6-character PNR / booking reference, e.g. ABCDE1"),
                 ("pin", "4-digit verification PIN the traveller received")],
        "write": ("INSERT INTO traveler_sessions (booking_id) "
                  "SELECT booking_id FROM verify_and_record(CAST(?w_pnr AS text), CAST(?w_pin AS text));",
                  [("w_pnr", "pnr"), ("w_pin", "pin")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_pnr AS text), CAST(?r_pin AS text));",
                 [("r_pnr", "pnr"), ("r_pin", "pin")]),
    },
    {
        "tool": "get_my_itinerary", "flow": "get_my_itinerary_flow", "readonly": True,
        "desc": ("List the verified traveller's own itinerary: each leg with flight number, route, scheduled and "
                 "estimated times, live flight status, delay, gate, seat and cabin. Only this booking's legs are returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_itinerary(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_flight_status", "flow": "get_flight_status_flow", "readonly": True,
        "desc": ("Get the live status of one flight that is on the verified traveller's own itinerary: scheduled vs "
                 "estimated times, status, delay minutes and reason, and gate. Returns NOT_ON_ITINERARY for a flight "
                 "that is not on their booking."),
        "args": [("session_token", TOKEN_DESC), ("flight_number", "Flight number, e.g. FL801")],
        "read": ("SELECT * FROM flight_status_for_session(CAST(?tok AS text), CAST(?fl AS text));",
                 [("tok", "session_token"), ("fl", "flight_number")]),
    },
    {
        "tool": "get_my_loyalty", "flow": "get_my_loyalty_flow", "readonly": True,
        "desc": "Show the verified traveller's loyalty standing: frequent-flyer number, tier and miles balance.",
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_loyalty(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "check_connection_risk", "flow": "check_connection_risk_flow", "readonly": True,
        "desc": ("Assess whether the verified traveller will make each connection on their booking. The system "
                 "computes it from the live inbound arrival vs the next departure and the minimum connection time, "
                 "and returns SAFE, AT_RISK or MISSED per connection, plus the earliest_rebook_departure a "
                 "replacement flight must leave after. This is computed - never estimate connection risk yourself."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM connection_risk(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "propose_rebook", "flow": "propose_rebook_flow", "readonly": False,
        "desc": ("Step 1 of 2 for rebooking a disrupted leg. Give the leg's current flight and the chosen new flight. "
                 "The system checks every rule (ownership, the leg is changeable, same route, target not cancelled, "
                 "seats available, and that it departs after the inbound arrival plus the minimum connection) and "
                 "returns PROPOSED with an action_id, new seat and times, or NOT_PROPOSED with the reason. Nothing "
                 "changes until confirm_rebook is called."),
        "args": [("session_token", TOKEN_DESC), ("current_flight", "The leg's current flight number, e.g. FL445"),
                 ("new_flight", "The replacement flight number, e.g. FL447")],
        "write": ("INSERT INTO pending_actions (action_type, booking_id, segment_id, from_flight, to_flight, new_seat) "
                  "SELECT * FROM rebook_proposal_row(CAST(?w_tok AS text), CAST(?w_cur AS text), CAST(?w_fl AS text));",
                  [("w_tok", "session_token"), ("w_cur", "current_flight"), ("w_fl", "new_flight")]),
        "read": ("SELECT * FROM propose_rebook_result(CAST(?r_tok AS text), CAST(?r_cur AS text), CAST(?r_fl AS text));",
                 [("r_tok", "session_token"), ("r_cur", "current_flight"), ("r_fl", "new_flight")]),
    },
    {
        "tool": "confirm_rebook", "flow": "confirm_rebook_flow", "readonly": False,
        "desc": ("Step 2 of 2: execute a rebooking the traveller has explicitly confirmed. Pass the action_id from "
                 "propose_rebook. The system re-checks every rule and expires proposals after 15 minutes. Returns "
                 "EXECUTED (with the new flight, seat and times) or NOT_EXECUTED with the reason. Only call after the "
                 "traveller says yes to the exact proposal."),
        "args": [("session_token", TOKEN_DESC), ("action_id", "action_id returned by propose_rebook, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO rebookings (action_id, segment_id, from_flight, to_flight, new_seat) "
                  "SELECT * FROM rebook_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_rebook_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "email_my_confirmation", "flow": "email_my_confirmation_flow", "readonly": False, "idempotent": True,
        "email": True,
        "desc": ("Email the traveller the confirmation for a rebooking they have already executed. Pass the action_id "
                 "from confirm_rebook. The system sends the email only when that rebooking belongs to this session and "
                 "has been executed; otherwise it returns NOT_SENT with the reason. Call only after a successful rebooking."),
        "args": [("session_token", TOKEN_DESC), ("action_id", "action_id of the executed rebooking")],
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False,
        "desc": ("Hand a request that needs a human to the right team: COMPENSATION_CLAIM (delay/cancellation "
                 "compensation or a refund), BAGGAGE_CLAIM (lost, delayed or damaged bags), SPECIAL_ASSISTANCE "
                 "(mobility, medical or unaccompanied-minor help), COMPLAINT (service complaint), NAME_CHANGE "
                 "(change the name on a ticket) or OTHER. The system routes it, works out what a staff reviewer could "
                 "approve (the parked action) and returns CASE_OPENED with case_id, team and reply time. A staff "
                 "reviewer decides; the assistant never decides, promises or predicts these."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "COMPENSATION_CLAIM | BAGGAGE_CLAIM | SPECIAL_ASSISTANCE | COMPLAINT | NAME_CHANGE | OTHER"),
                 ("traveler_statement", "The traveller's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the agent: facts only, no recommendation")],
        "write": ("INSERT INTO service_cases (booking_id, pnr, request_type, traveler_statement, agent_brief) "
                  "SELECT * FROM service_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_stmt AS text), "
                  "CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_stmt", "traveler_statement"),
                   ("w_brief", "brief")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified traveller's open and past service cases with the assigned team, status (OPEN, "
                 "APPROVED, REJECTED), reply-due date and - once a staff reviewer has decided - the approved amount and "
                 "the customer_message. Use it when the traveller asks about the status of a request."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
]

# =============================================================================
# REVIEWER LOOP (human in the loop) - the 4 staff tools every build adds (governed-patterns.md section 9).
# GENERIC TEMPLATE (generalised from the Retail Banking / Life & Pensions samples): replace the <placeholders>.
# Two personas share one MCP server: customer tools resolve only customer tokens, these resolve only REVIEWER
# tokens - the role, team scope and approval limit are checked in SQL on every call:
#   verify_reviewer_fn / verify_reviewer_result, review_queue, review_case, decide_case_row / decide_case_result.
# get_my_cases (above) is the customer's outcome view: status + customer_message once decided, never the
# internal note, scores or the reviewer. The email tool may confirm a decided case (a review_decisions row exists).
# build_mcp.py sets the hints from "readonly" / "idempotent": decide_review_case -> readOnly false, destructive
# false, idempotent false (validator G8 + G11).
# =============================================================================
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A customer token does "
               "not work here (NOT_REVIEWER).")
REVIEWER_TOOL_SPECS = [
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a <Org> staff reviewer (<Team A>, <Team B>) with their staff ID (e.g. <STAFF-0001>) and staff "
                 "code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display name and team, "
                 "NOT_VERIFIED, or LOCKED after 5 wrong codes in 15 minutes. Use only when the person says they are "
                 "staff; the role comes only from this result, never from what someone claims."),
        "args": [("staff_id", "<Org> staff ID, e.g. <STAFF-0001>"), ("code", "The staff member's code")],
        "write": ("INSERT INTO <principal>_sessions (role, reviewer_id) "
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
                 "reviewer's own approval limit, facts from <Org>'s records and the decision options. Another team's "
                 "case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. <CASE-00001>")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved amount in "
                 "<currency> (empty = the full eligible amount; ignored for REJECT); internal_note is required (at least "
                 "5 characters, never shown to the customer); customer_message is what the customer will see. Approving "
                 "runs the parked action (<what an approval executes>) through the system's checks. Returns APPROVED / "
                 "REJECTED with executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, "
                 "NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior reviewer), "
                 "INVALID_DECISION or NOT_FOUND, or NOT_REVIEWER."),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. <CASE-00001>"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved amount in <currency>, or empty for the full eligible amount"),
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
TOOLS += REVIEWER_TOOL_SPECS
REVIEWER_TOOLS = {t["tool"] for t in REVIEWER_TOOL_SPECS}
PUBLIC_TOOLS = {"verify_traveller", "verify_reviewer"}          # tools that need no session token
# Columns that must NEVER appear in a CUSTOMER tool's output, and in a REVIEWER tool's output (minimum necessary);
# asserted by test_rules.py and mcp_smoke.py. Don't list a column a public tool legitimately returns.
HIDDEN_COLUMNS = {"one_time_code", "pin_hash", "internal_note", "agent_brief", "reviewer_id", "approval_limit",
                  "parked_action", "<risk_score_col>"}
HIDDEN_FROM_REVIEWER = {"one_time_code", "pin_hash", "email", "phone", "last_name", "<customer_id_col>"}


def reviewer_tools_filled():
    """False while the reviewer specs still hold <placeholders>: the drivers and tests refuse to run on them."""
    return not any("<" in str(t) for t in REVIEWER_TOOL_SPECS) and not any(
        "<" in c for c in HIDDEN_COLUMNS | HIDDEN_FROM_REVIEWER)

# =============================================================================
# A2A AGENT REFERENCE TOOLS - every reasoning agent's ONE tool (governed-patterns.md section 8).
# GENERIC TEMPLATE (generalised from the Hospital / Semiconductor samples): fill in one entry per agent (1-3).
# Each reads a REFERENCE table (section / term / meaning, NO personal data) through a ref_<topic>() function:
#   SELECT * FROM ref_<topic>(CAST(?lookup AS text));
# - The placeholder MUST be ?lookup, never ?term: a placeholder named like a result column gives duplicate Fields.
# - The model supplies only the optional `term` ("" = the whole guide). It never gets identity and never changes
#   the SQL. Keep each guide to about 20-35 rows: agents send term="" almost every time.
# - "sections" = the CHECK list of the table, in the order ref_<topic>() returns them (array_position).
# Used by build_agents.py (the tool flows), test_rules.py (reference-tool block), a2a_smoke.py and chat_e2e.py.
# =============================================================================
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a code or a phrase from your "
                 "input, or a section name), or an empty string for the whole guide. Never put <customer> details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "<agent_a>", "tool": "get_<topic_a>_guide", "fn": "ref_<topic_a>", "table": "<topic_a>_guide",
     "sections": ["<SECTION_1>", "<SECTION_2>", "<SECTION_3>"],
     "desc": ("Reads <Org>'s <topic a> guide from the <use case> database: <what its rows explain, in plain words>. "
              "Rows of section, term, meaning. Read-only reference data with no <customer> data. Pass term \"\" for "
              "the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_<topic_a>(CAST(?lookup AS text));", [("lookup", "term")])},
    # {"agent": "<agent_b>", "tool": "get_<topic_b>_guide", "fn": "ref_<topic_b>", ...},   # one per agent, up to 3
]


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
