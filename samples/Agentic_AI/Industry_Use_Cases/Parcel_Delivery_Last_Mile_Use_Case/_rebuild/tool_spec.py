"""Single source of truth for the MCP tools and the delivery-options agent's tool.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py
(to run the exact same SQL against PostgreSQL before any app is built).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): it validates with SQL, then the flow sends the email only
when the SQL authorises it (a conditional branch, added in build_mcp.py).
"""

TOKEN_DESC = ("Session token returned by verify_recipient. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the recipient to verify again.")

TOOLS = [
    {
        "tool": "verify_recipient", "flow": "verify_recipient_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the recipient's identity with their 6-character Swiftbound account reference and the 4-digit "
                 "PIN from their Swiftbound app or delivery notification. Returns VERIFIED with a session_token (valid "
                 "60 minutes), their name and service area, or NOT_VERIFIED. Call this before any other tool. "
                 "Never reveal or guess PINs."),
        "args": [("account_ref", "6-character Swiftbound account reference, e.g. K4R2QX"),
                 ("pin", "4-digit verification PIN the recipient received")],
        "write": ("INSERT INTO recipient_sessions (recipient_id) "
                  "SELECT recipient_id FROM verify_and_record(CAST(?w_ref AS text), CAST(?w_pin AS text));",
                  [("w_ref", "account_ref"), ("w_pin", "pin")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_ref AS text), CAST(?r_pin AS text));",
                 [("r_ref", "account_ref"), ("r_pin", "pin")]),
    },
    {
        "tool": "get_my_parcels", "flow": "get_my_parcels_flow", "readonly": True,
        "desc": ("List the verified recipient's own parcels: tracking number, description, current status, any "
                 "exception, promised date and expected delivery. Only this recipient's parcels are returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_parcels(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_parcel_detail", "flow": "get_parcel_detail_flow", "readonly": True,
        "desc": ("Get the full detail of one parcel on the verified recipient's account: status, the plain-English "
                 "meaning of any exception code and the recommended next step, a computed delivery_health "
                 "(ON_TRACK / NEEDS_ATTENTION / LATE / DELIVERED), size, whether a signature is required, declared "
                 "value, destination area, the earliest date it can be rescheduled, and the current slot/pickup. "
                 "Returns NOT_FOUND for a tracking number that is not on this account."),
        "args": [("session_token", TOKEN_DESC), ("tracking_number", "Parcel tracking number, e.g. SB100000000001")],
        "read": ("SELECT * FROM parcel_detail(CAST(?tok AS text), CAST(?trk AS text));",
                 [("tok", "session_token"), ("trk", "tracking_number")]),
    },
    {
        "tool": "get_tracking_history", "flow": "get_tracking_history_flow", "readonly": True,
        "desc": ("Show the scan timeline for one parcel on the verified recipient's account: each scan with its time, "
                 "location, code and description. Returns NOT_FOUND for a parcel that is not on this account."),
        "args": [("session_token", TOKEN_DESC), ("tracking_number", "Parcel tracking number, e.g. SB100000000001")],
        "read": ("SELECT * FROM tracking_history(CAST(?tok AS text), CAST(?trk AS text));",
                 [("tok", "session_token"), ("trk", "tracking_number")]),
    },
    {
        "tool": "propose_reschedule", "flow": "propose_reschedule_flow", "readonly": False,
        "desc": ("Step 1 of 2 to reschedule a parcel onto a new delivery slot. Give the parcel's tracking number and "
                 "the chosen slot_id (from the delivery-options agent or get_parcel_detail). The system checks every "
                 "rule (ownership, the parcel is still reschedulable, the slot is in the parcel's area, not in the "
                 "past, and has capacity) and returns PROPOSED with an action_id and the slot date/window, or "
                 "NOT_PROPOSED with the reason. Nothing changes until confirm_reschedule is called."),
        "args": [("session_token", TOKEN_DESC), ("tracking_number", "The parcel's tracking number, e.g. SB100000000001"),
                 ("slot_id", "The chosen delivery slot id, e.g. SLOT-N1")],
        "write": ("INSERT INTO pending_actions (action_type, parcel_id, slot_id) "
                  "SELECT * FROM reschedule_proposal_row(CAST(?w_tok AS text), CAST(?w_trk AS text), CAST(?w_slot AS text));",
                  [("w_tok", "session_token"), ("w_trk", "tracking_number"), ("w_slot", "slot_id")]),
        "read": ("SELECT * FROM propose_reschedule_result(CAST(?r_tok AS text), CAST(?r_trk AS text), CAST(?r_slot AS text));",
                 [("r_tok", "session_token"), ("r_trk", "tracking_number"), ("r_slot", "slot_id")]),
    },
    {
        "tool": "confirm_reschedule", "flow": "confirm_reschedule_flow", "readonly": False,
        "desc": ("Step 2 of 2: execute a reschedule the recipient has explicitly confirmed. Pass the action_id from "
                 "propose_reschedule. The system re-checks every rule and expires proposals after 15 minutes. Returns "
                 "EXECUTED (with the new slot) or NOT_EXECUTED with the reason. Only call after the recipient says yes "
                 "to the exact proposal."),
        "args": [("session_token", TOKEN_DESC), ("action_id", "action_id returned by propose_reschedule, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO delivery_changes (action_id, parcel_id, action_type, slot_id) "
                  "SELECT * FROM reschedule_confirm_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_change_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "propose_redirect", "flow": "propose_redirect_flow", "readonly": False,
        "desc": ("Step 1 of 2 to redirect a parcel to a pickup point (locker or staffed shop). Give the tracking number "
                 "and the chosen pickup_id. The system checks every rule (ownership, the parcel is still redirectable, "
                 "the pickup point serves the parcel's area and fits its size, and - for unattended lockers - that the "
                 "parcel is not signature-required and not over the value limit) and returns PROPOSED with an action_id, "
                 "or NOT_PROPOSED with the reason. Nothing changes until confirm_redirect is called."),
        "args": [("session_token", TOKEN_DESC), ("tracking_number", "The parcel's tracking number, e.g. SB100000000002"),
                 ("pickup_id", "The chosen pickup point id, e.g. PU-N-SHOP1")],
        "write": ("INSERT INTO pending_actions (action_type, parcel_id, pickup_id) "
                  "SELECT * FROM redirect_proposal_row(CAST(?w_tok AS text), CAST(?w_trk AS text), CAST(?w_pick AS text));",
                  [("w_tok", "session_token"), ("w_trk", "tracking_number"), ("w_pick", "pickup_id")]),
        "read": ("SELECT * FROM propose_redirect_result(CAST(?r_tok AS text), CAST(?r_trk AS text), CAST(?r_pick AS text));",
                 [("r_tok", "session_token"), ("r_trk", "tracking_number"), ("r_pick", "pickup_id")]),
    },
    {
        "tool": "confirm_redirect", "flow": "confirm_redirect_flow", "readonly": False,
        "desc": ("Step 2 of 2: execute a redirect the recipient has explicitly confirmed. Pass the action_id from "
                 "propose_redirect. The system re-checks every rule and expires proposals after 15 minutes. Returns "
                 "EXECUTED (with the pickup point) or NOT_EXECUTED with the reason. Only call after the recipient says "
                 "yes to the exact proposal."),
        "args": [("session_token", TOKEN_DESC), ("action_id", "action_id returned by propose_redirect, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO delivery_changes (action_id, parcel_id, action_type, pickup_id) "
                  "SELECT * FROM redirect_confirm_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_change_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "email_confirmation", "flow": "email_confirmation_flow", "readonly": False, "idempotent": True,
        "email": True,
        "desc": ("Email the recipient the confirmation for a reschedule or redirect they have already executed. Pass the "
                 "action_id from confirm_reschedule or confirm_redirect. The system sends the email only when that change "
                 "belongs to this session and has been executed; otherwise it returns NOT_SENT with the reason. Call only "
                 "after a successful change."),
        "args": [("session_token", TOKEN_DESC), ("action_id", "action_id of the executed change")],
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False,
        "desc": ("Hand a request that needs a human to the right team: LOST_PARCEL (a parcel that never arrived), "
                 "DAMAGED_PARCEL (arrived damaged), MISSING_ITEMS (contents missing from the parcel), WRONG_DELIVERY "
                 "(delivered to the wrong place/person), DELIVERY_COMPLAINT (a complaint about the service) or OTHER. "
                 "The system routes it and returns CASE_OPENED with case_id, team and reply time. The assistant never "
                 "decides, promises or predicts compensation or outcomes."),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "LOST_PARCEL | DAMAGED_PARCEL | MISSING_ITEMS | WRONG_DELIVERY | DELIVERY_COMPLAINT | OTHER"),
                 ("tracking_number", "The tracking number this is about, if any (else empty)"),
                 ("recipient_statement", "The recipient's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the agent: facts only, no recommendation")],
        "write": ("INSERT INTO service_cases (recipient_id, account_ref, tracking_number, request_type, recipient_statement, agent_brief) "
                  "SELECT * FROM service_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_trk AS text), "
                  "CAST(?w_stmt AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_trk", "tracking_number"),
                   ("w_stmt", "recipient_statement"), ("w_brief", "brief")]),
        "read": ("SELECT * FROM service_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": "List the verified recipient's open and past service cases with the assigned team and status.",
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
]

# Tool of the A2A delivery-options agent. Area + size + constraints only - never recipient identity.
SEARCH_DELIVERY_OPTIONS = {
    "desc": ("Search the feasible delivery options for a parcel in a given service area: available delivery slots and "
             "pickup points the parcel can actually use. Pass the service area, the parcel size (SMALL/MEDIUM/LARGE), "
             "whether a signature is required (true/false), whether it is high value (true/false) and the earliest date "
             "a slot may be on (ISO date or empty). Returns up to 12 options (slots and pickup points). Never pass any "
             "recipient-identifying information."),
    "args": [("area", "Service area the parcel is going to, e.g. NORTHSIDE"),
             ("parcel_size", "SMALL, MEDIUM or LARGE"),
             ("needs_signature", "true if the parcel requires a signature, else false"),
             ("high_value", "true if the parcel is high value, else false"),
             ("after_date", "Earliest date a slot may be on (ISO date), or empty")],
    "read": ("SELECT * FROM search_delivery_options(CAST(?area AS text), CAST(?size AS text), CAST(?sig AS text), "
             "CAST(?hv AS text), CAST(?aft AS text));",
             [("area", "area"), ("size", "parcel_size"), ("sig", "needs_signature"), ("hv", "high_value"), ("aft", "after_date")]),
}
