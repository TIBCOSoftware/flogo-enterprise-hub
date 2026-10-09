# =============================================================================
# WORKED-EXAMPLE TEMPLATE - Airline Passenger Services (Meridian) governed use case.
#
# This is the proven tool spec from the Airline Passenger Services worked example.
# To build your own governed use case, copy the whole _rebuild/ folder into
# <YourUseCase>/_rebuild/ and ADAPT it (keep the structure - the value is a working
# reference - just change):
#   - app names / prefix       (PassengerServices... -> <YourUseCase>...)
#   - the tool_spec entries     below: tools, args, SQL (scoped reads + guarded writes)
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
"""Single source of truth for the MCP tools and the rebooking-options agent's tool.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py
(to run the exact same SQL against PostgreSQL before any app is built).

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
                 "(change the name on a ticket) or OTHER. The system routes it and returns CASE_OPENED with case_id, "
                 "team and reply time. The assistant never decides, promises or predicts these."),
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
        "desc": "List the verified traveller's open and past service cases with the assigned team and status.",
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
]

# Tool of the A2A rebooking-options agent. Route + time window + cabin only - never passenger identity.
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
