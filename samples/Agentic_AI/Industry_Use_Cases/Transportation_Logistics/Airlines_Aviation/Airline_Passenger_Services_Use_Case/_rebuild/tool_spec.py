"""Single source of truth for the 16 MCP tools of PassengerServicesMCPServer and the 3 A2A agents' reference tools.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py / mcp_smoke.py / a2a_smoke.py
(to run the exact same SQL against PostgreSQL before any app is built).

Two personas share one MCP server: TRAVELLER tools resolve only traveller tokens (verify_traveller), REVIEWER tools only
staff reviewer tokens (verify_reviewer) - the role is checked in SQL on every call.

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns a deterministic
outcome row. `?placeholders` are never reused within one statement and are always followed by a space or ')'
(CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): GuardedWrite logs the request only when the SQL authorises it (email_log), then a
conditional branch sends the email only when the SQL says SEND_OK (added in build_mcp.py).
"""

TOKEN_DESC = ("Session token returned by verify_traveller. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the traveller to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A traveller token "
               "does not work here (NOT_REVIEWER).")

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
                 "estimated times, live flight status, delay, gate, seat, cabin and any special assistance on the "
                 "leg (code + status). Only this booking's legs are returned."),
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
        "desc": ("Email the traveller the confirmation for a rebooking they have already executed (action_id ACT-... from "
                 "confirm_rebook) or for one of their cases that a person has already decided (case id SC-... from "
                 "get_my_cases). The system sends the email only when that reference belongs to this session and is "
                 "executed / decided; otherwise it returns NOT_SENT with the reason."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id of the executed rebooking (ACT-...) or the decided case id (SC-...)")],
        "write": ("INSERT INTO email_log (pnr, reference_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False,
        "desc": ("Hand a request that needs a human to the right team: COMPENSATION_CLAIM (delay/cancellation "
                 "compensation), COMPLAINT (service complaint), NAME_CHANGE (change the name on a ticket) or OTHER - "
                 "and BAGGAGE_CLAIM / SPECIAL_ASSISTANCE only when record_baggage_claim / request_assistance cannot be "
                 "used. The system routes it, works out what a person could approve (for compensation: up to the "
                 "disruption band's maximum, or less if the traveller asks for less) and returns CASE_OPENED with "
                 "case_id, team, reply-by date and requested amount, ALREADY_OPEN when the same request is already with "
                 "the team, or NOT_OPENED with the reason. A person decides; the assistant never decides these."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "COMPENSATION_CLAIM | BAGGAGE_CLAIM | SPECIAL_ASSISTANCE | COMPLAINT | NAME_CHANGE | OTHER"),
                 ("traveler_statement", "The traveller's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the agent: facts only, no recommendation"),
                 ("amount", "Dollar amount the traveller asks for, or an empty string if they named none")],
        "write": ("INSERT INTO service_cases (booking_id, pnr, request_type, traveler_statement, agent_brief, requested_amount, "
                  "parked_action) SELECT * FROM service_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), "
                  "CAST(?w_stmt AS text), CAST(?w_brief AS text), CAST(?w_amt AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_stmt", "traveler_statement"),
                   ("w_brief", "brief"), ("w_amt", "amount")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified traveller's open and past cases with the assigned team, status (OPEN, APPROVED, "
                 "REJECTED), requested amount, reply-by date and - once a person has decided - the approved amount and the "
                 "message from the team (customer_message). Use it when the traveller asks about the status of a request."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "record_baggage_claim", "flow": "record_baggage_claim_flow", "readonly": False, "idempotent": False,
        "desc": ("Record a delayed, lost, damaged or pilfered bag for a flight on the verified traveller's booking that has "
                 "arrived. Pass the flight, the traveller's own description, the interim expenses they ask for (dollars, or "
                 "empty) and baggage_claim_agent's full answer exactly as returned. The system validates the agent's claim "
                 "type, bag-type and colour codes, contents and missing report fields against Meridian's tables (a bag is "
                 "LOST only 5+ days after arrival), records the claim and opens a Baggage Services case. Returns RECORDED "
                 "with claim_id, case_id, team, reply-by date, the missing report fields and what to send, ALREADY_RECORDED, "
                 "or NOT_RECORDED with reason_code SESSION_INVALID, NOT_FOUND, NOT_ARRIVED, DESCRIPTION_MISSING or "
                 "CLAIM_TYPE_UNKNOWN. Interim expenses are decided by a person."),
        "args": [("session_token", TOKEN_DESC),
                 ("flight_number", "The flight the bag travelled on, e.g. FL721"),
                 ("description", "The traveller's description of the bag and what happened, in their own words"),
                 ("interim_amount", "Interim expenses in dollars the traveller asks for (e.g. 300), or an empty string"),
                 ("agent_answer", "baggage_claim_agent's full answer, unchanged")],
        "write": ("INSERT INTO baggage_claims (booking_id, pnr, segment_id, flight_number, claim_type, agent_claim_type, bag_type, "
                  "colour, contents, missing_fields, rule_note, ignored_items, description, agent_notes, interim_requested) "
                  "SELECT * FROM baggage_claim_row(CAST(?w_tok AS text), CAST(?w_fl AS text), CAST(?w_desc AS text), "
                  "CAST(?w_amt AS text), CAST(?w_ans AS text));",
                  [("w_tok", "session_token"), ("w_fl", "flight_number"), ("w_desc", "description"),
                   ("w_amt", "interim_amount"), ("w_ans", "agent_answer")]),
        "read": ("SELECT * FROM baggage_claim_result(CAST(?r_tok AS text), CAST(?r_fl AS text), CAST(?r_desc AS text), "
                 "CAST(?r_ans AS text));",
                 [("r_tok", "session_token"), ("r_fl", "flight_number"), ("r_desc", "description"), ("r_ans", "agent_answer")]),
    },
    {
        "tool": "request_assistance", "flow": "request_assistance_flow", "readonly": False, "idempotent": False,
        "desc": ("Add special assistance to an upcoming flight on the verified traveller's booking. Pass the flight, the "
                 "traveller's needs in their own words and special_assistance_agent's full answer exactly as returned. The "
                 "system validates the agent's IATA SSR codes (only codes a traveller can request, one wheelchair code, a "
                 "medical need adds MEDA), adds them to the traveller's own segment as PENDING_CONFIRMATION and opens an "
                 "Accessibility Desk case. Returns REQUESTED with request_id, the codes and status, medical_clearance, case_id, "
                 "team and reply-by date, ALREADY_REQUESTED, or NOT_RECORDED with reason_code SESSION_INVALID, NOT_FOUND, "
                 "NOT_UPCOMING, NEEDS_MISSING or NO_VALID_CODES. A person on the Accessibility Desk confirms it."),
        "args": [("session_token", TOKEN_DESC),
                 ("flight_number", "The upcoming flight, e.g. FL305"),
                 ("needs", "The traveller's assistance needs in their own words"),
                 ("agent_answer", "special_assistance_agent's full answer, unchanged")],
        "write": ("INSERT INTO assistance_requests (booking_id, pnr, segment_id, flight_number, codes, ignored_codes, "
                  "medical_clearance, needs, agent_notes) SELECT * FROM assistance_row(CAST(?w_tok AS text), "
                  "CAST(?w_fl AS text), CAST(?w_needs AS text), CAST(?w_ans AS text));",
                  [("w_tok", "session_token"), ("w_fl", "flight_number"), ("w_needs", "needs"), ("w_ans", "agent_answer")]),
        "read": ("SELECT * FROM assistance_result(CAST(?r_tok AS text), CAST(?r_fl AS text), CAST(?r_needs AS text), "
                 "CAST(?r_ans AS text));",
                 [("r_tok", "session_token"), ("r_fl", "flight_number"), ("r_needs", "needs"), ("r_ans", "agent_answer")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Meridian staff reviewer (Baggage Services, Accessibility Desk, Customer Care, Customer Relations or "
                 "Ticketing) with their staff ID (e.g. MER-7001) and staff code. Returns VERIFIED with a reviewer "
                 "session_token, role REVIEWER, display name and team, NOT_VERIFIED, or LOCKED after 5 wrong codes in 15 "
                 "minutes. Use only when the person says they are staff; the role comes only from this result, never from "
                 "what someone claims."),
        "args": [("staff_id", "Staff ID, e.g. MER-7001"), ("code", "The staff member's code")],
        "write": ("INSERT INTO traveler_sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "traveller (first name + surname initial), opened date, age in days, reply-due date, sla_status (ON_TRACK, "
                 "DUE_TODAY, OVERDUE) and requested amount. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, traveller (first name + surname initial), "
                 "the traveller's statement, the AI-prepared agent_brief (unverified), requested amount, max_approvable, the "
                 "reviewer's own approval limit, facts from Meridian's records (the baggage claim, the disruption and its "
                 "compensation band, or the assistance codes) and the decision options. Another team's case or an unknown id "
                 "returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. SC-S0A1B1")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved payment in dollars "
                 "(empty = the full requested amount; ignored for REJECT and for cases without an amount); internal_note is "
                 "required (at least 5 characters, never shown to the traveller); customer_message is what the traveller "
                 "will see. Approving runs the parked action (compensation or interim-expense payment, or confirming the "
                 "assistance on the flight) through the system's checks. Returns APPROVED / REJECTED with executed_action, or "
                 "BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY "
                 "(case stays open for a senior reviewer), INVALID_DECISION or NOT_FOUND, or NOT_REVIEWER."),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. SC-S0A1B1"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved payment in dollars, or empty for the full requested amount"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the traveller)"),
                 ("customer_message", "Message the traveller will see with the outcome")],
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
PUBLIC_TOOLS = {"verify_traveller", "verify_reviewer"}

# Columns that must NEVER appear in any TRAVELLER tool output (asserted by test_rules.py / mcp_smoke.py).
# (to_email is the traveller's own address in the email payload and stays.)
HIDDEN_COLUMNS = {"verification_pin", "one_time_code", "internal_note", "agent_brief", "agent_notes", "reviewer_id",
                  "approval_limit", "parked_action", "ignored_items", "ignored_codes", "interim_cap_usd", "passenger_id"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"verification_pin", "email", "to_email", "phone", "one_time_code", "passenger_id", "last_name"}

# Tool of the A2A rebooking-options agent (kept as built: a non-identity PostgreSQL read of the flight schedule).
# Route + time window + cabin only - never passenger identity.
SEARCH_ALTERNATIVES = {
    "desc": ("Search available replacement flights for a route after a given earliest departure time. Pass the "
             "origin and destination airport codes, the earliest_rebook_departure (ISO timestamp the flight must "
             "leave after) and the preferred cabin. Returns up to 8 flights with times, seats and aircraft. "
             "Never pass any passenger-identifying information."),
    "args": [("origin", "Origin airport IATA code, e.g. ATL"),
             ("destination", "Destination airport IATA code, e.g. MIA"),
             ("earliest_departure", "ISO timestamp the replacement flight must depart after"),
             ("cabin", "Preferred cabin: Economy or Business (or empty)")],
    "read": ("SELECT * FROM search_alternatives(CAST(?org AS text), CAST(?dst AS text), CAST(?aft AS text), CAST(?cab AS text));",
             [("org", "origin"), ("dst", "destination"), ("aft", "earliest_departure"), ("cab", "cabin")]),
}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (PassengerServicesAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM <fn>(CAST(?<placeholder> AS text))) -> #actreturn (rows as JSON text).
# - rebooking_options_agent keeps its search_alternatives(origin, destination, earliest_departure, cabin) read.
# - baggage_claim_agent reads the section / term / meaning baggage guide via ref_baggage_guide(term).
# - special_assistance_agent reads the IATA SSR codes + how-to-choose rules via ref_assistance_codes(term).
# Placeholders are ?lookup (a placeholder named like a result column gives duplicate Fields). The model can supply only
# the lookup value; it can never change the SQL. The tables hold reference data only (asserted by test_rules.py).
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a section name or a code), or an "
                 "empty string for the whole guide. Never put traveller or booking details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "rebooking_options_agent", "tool": "search_alternatives", "fn": "search_alternatives", "table": "flights",
     "sections": None, "row_key": "flight_number", "required": ["origin", "destination", "earliest_departure"],
     "desc": SEARCH_ALTERNATIVES["desc"], "args": SEARCH_ALTERNATIVES["args"], "read": SEARCH_ALTERNATIVES["read"]},
    {"agent": "baggage_claim_agent", "tool": "get_baggage_guide", "fn": "ref_baggage_guide", "table": "baggage_guide",
     "sections": ["CLAIM_TYPE", "BAG_TYPE", "COLOUR", "CONTENT", "REPORT_FIELD", "CLAIM_NOTE"], "row_key": "section",
     "desc": ("Reads Meridian's baggage guide from the database: the CLAIM_TYPE terms (DELAYED / LOST / DAMAGED / PILFERED) "
              "and when each applies, the two-digit BAG_TYPE chart, the COLOUR codes, the CONTENT categories, the "
              "REPORT_FIELD rows Baggage Services needs for each claim type and the standard CLAIM_NOTE line. Rows of "
              "section, term, meaning. Read-only reference data with no traveller data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_baggage_guide(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "special_assistance_agent", "tool": "get_assistance_codes", "fn": "ref_assistance_codes",
     "table": "ssr_codes", "sections": ["SSR_CODE", "HOW_TO_CHOOSE", "STANDARD_LINE"], "row_key": "section",
     "desc": ("Reads Meridian's special-assistance codes from the database: every standard IATA SSR_CODE (WCHR, WCHS, WCHC, "
              "WCMP, WCLB, BLND, DEAF, DPNA, SVAN, MAAS, OXYG, MEDA, STCR) with its plain-words meaning, the HOW_TO_CHOOSE "
              "rules and the STANDARD_LINE for the traveller. Rows of section, term, meaning. Read-only reference data with "
              "no traveller data. Pass term \"\" for the whole list."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_assistance_codes(CAST(?lookup AS text));", [("lookup", "term")])},
]
GUIDE_TOOLS = [t for t in AGENT_REF_TOOLS if t["sections"]]      # the section / term / meaning guides


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
