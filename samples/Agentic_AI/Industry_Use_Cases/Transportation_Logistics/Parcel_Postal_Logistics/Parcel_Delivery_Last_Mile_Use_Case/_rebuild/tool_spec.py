"""Single source of truth for the 18 MCP tools of ParcelDeliveryMCPServer and the 3 A2A agents' reference tools.

Two personas share one MCP server: RECIPIENT tools resolve only recipient tokens (verify_recipient), REVIEWER tools only
reviewer tokens (verify_reviewer) - the role is checked in SQL on every call.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py
(to run the exact same SQL against PostgreSQL before any app is built).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement and are always
followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

The email tool is special (email=True): its guarded WRITE logs the request in email_log only when the SQL authorises
it, its READ returns the SQL-validated payload (send_status, subject, body), and build_mcp.py adds a conditional branch:
SendMail runs ONLY when send_status == "SEND_OK" (to the To_Email ops inbox); otherwise nothing is sent.
"""

TOKEN_DESC = ("Session token returned by verify_recipient. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the recipient to verify again.")

RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A recipient token does "
               "not work here (NOT_REVIEWER).")

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
        "desc": ("Email the recipient a confirmation of something already done for them: a reschedule or redirect they "
                 "executed, delivery instructions they saved (pass the action_id), or a case a person has decided (pass "
                 "the case id SC-...). The system sends the email only when that action or case belongs to this session "
                 "and is executed or decided; otherwise it returns NOT_SENT with the reason. Call only when the "
                 "recipient asks."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id of the executed change or saved instructions (ACT-...), or a decided case id (SC-...)")],
        "write": ("INSERT INTO email_log (recipient_id, reference_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False,
        "desc": ("Hand a request that needs a human to the right team (for compensation claims on a damaged, lost or "
                 "incomplete parcel use open_damage_claim instead): LOST_PARCEL (a parcel that never arrived), "
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
        "desc": ("List the verified recipient's open and past cases and claims: case id, claim id, request type, parcel, "
                 "assigned team, status (OPEN, APPROVED, REJECTED), the amount under review, and - once a person has "
                 "decided - the approved amount, any compensation paid and the customer_message from the team. Use it "
                 "when the recipient asks about the status of a claim or request."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    # ------------------------------------------------------------------ claims (damage_claim_agent)
    {
        "tool": "open_damage_claim", "flow": "open_damage_claim_flow", "readonly": False, "idempotent": False,
        "desc": ("Open a compensation claim for one of the verified recipient's own parcels that arrived damaged "
                 "(DAMAGED), arrived with items missing (MISSING_CONTENTS) or never arrived (LOST). Pass the tracking "
                 "number, the damage_claim_agent's claim_type, packaging_condition and likely_cause exactly as it returned "
                 "them, the amount the recipient is claiming (empty = the declared value), the recipient's own words and "
                 "the agent's full answer. The system checks the rules (ownership, delivery status, claim window, one open "
                 "claim per parcel), caps the claimable amount at the declared value and Swiftbound's coverage limit, and "
                 "returns CLAIM_OPENED with claim_id, case_id, team, reply date, the amount under review, why it was "
                 "capped and the evidence to send; ALREADY_OPEN; or NOT_OPENED with reason_code NOT_FOUND, BAD_CLAIM_TYPE, "
                 "NOT_DELIVERED_YET, DELIVERED_NOT_LOST, NOT_YET_LOST, RETURNED_TO_SENDER, CLAIM_WINDOW_CLOSED, BAD_AMOUNT "
                 "or SESSION_INVALID. A person decides the claim and any compensation; never promise an amount."),
        "args": [("session_token", TOKEN_DESC),
                 ("tracking_number", "The parcel's tracking number, e.g. SB100000000011"),
                 ("claim_type", "DAMAGED | MISSING_CONTENTS | LOST (from damage_claim_agent)"),
                 ("packaging_condition", "The packaging_condition from damage_claim_agent, exactly as returned"),
                 ("likely_cause", "The likely_cause from damage_claim_agent, exactly as returned"),
                 ("claimed_amount", "Amount the recipient claims in US dollars, or empty for the declared value"),
                 ("recipient_statement", "The recipient's description of the problem, in their own words"),
                 ("agent_notes", "damage_claim_agent's full answer, unchanged")],
        "write": ("INSERT INTO damage_claims (parcel_id, recipient_id, claim_type, packaging_condition, cause_category, "
                  "claimed_amount, declared_value, coverage_limit, eligible_amount, evidence_required, recipient_statement, "
                  "agent_notes, ignored_terms) "
                  "SELECT * FROM damage_claim_row(CAST(?w_tok AS text), CAST(?w_trk AS text), CAST(?w_type AS text), "
                  "CAST(?w_pack AS text), CAST(?w_cause AS text), CAST(?w_amt AS text), CAST(?w_stmt AS text), "
                  "CAST(?w_notes AS text));",
                  [("w_tok", "session_token"), ("w_trk", "tracking_number"), ("w_type", "claim_type"),
                   ("w_pack", "packaging_condition"), ("w_cause", "likely_cause"), ("w_amt", "claimed_amount"),
                   ("w_stmt", "recipient_statement"), ("w_notes", "agent_notes")]),
        "read": ("SELECT * FROM damage_claim_result(CAST(?r_tok AS text), CAST(?r_trk AS text), CAST(?r_type AS text), "
                 "CAST(?r_amt AS text));",
                 [("r_tok", "session_token"), ("r_trk", "tracking_number"), ("r_type", "claim_type"), ("r_amt", "claimed_amount")]),
    },
    # ------------------------------------------------------------------ delivery instructions (delivery_instructions_agent)
    {
        "tool": "propose_delivery_instructions", "flow": "propose_delivery_instructions_flow", "readonly": False,
        "idempotent": False,
        "desc": ("Step 1 of 2 to save delivery instructions (safe place, access-code flag, hazards) for one of the "
                 "verified recipient's own upcoming parcels. Pass the tracking number, the delivery_instructions_agent's "
                 "safe_place, access_code_present, hazards and risk_flags exactly as it returned them, the recipient's "
                 "own words and the agent's full answer. The system checks the safe place against Swiftbound's list, "
                 "scans for risky instructions, applies the signature and high-value rules, masks any access code and "
                 "returns PROPOSED with an action_id and the driver note, or NOT_PROPOSED with reason_code "
                 "RISKY_INSTRUCTION, SAFE_PLACE_UNKNOWN, SIGNATURE_REQUIRED, HIGH_VALUE_SAFE_PLACE, ALREADY_DELIVERED, "
                 "REDIRECTED_TO_PICKUP, NOT_FOUND or SESSION_INVALID. Nothing is saved until "
                 "confirm_delivery_instructions."),
        "args": [("session_token", TOKEN_DESC),
                 ("tracking_number", "The parcel's tracking number, e.g. SB100000000009"),
                 ("safe_place", "The safe_place from delivery_instructions_agent (e.g. SIDE_GATE), or NONE"),
                 ("access_code_present", "yes or no, from delivery_instructions_agent"),
                 ("hazards", "The hazards line from delivery_instructions_agent (e.g. DOG), or NONE"),
                 ("risk_flags", "The risk_flags line from delivery_instructions_agent, or NONE"),
                 ("instructions_text", "The recipient's access notes in their own words"),
                 ("agent_notes", "delivery_instructions_agent's full answer, unchanged")],
        "write": ("INSERT INTO pending_actions (action_type, parcel_id, safe_place, access_code_present, hazards, "
                  "notes_masked, agent_notes) "
                  "SELECT * FROM instructions_proposal_row(CAST(?w_tok AS text), CAST(?w_trk AS text), "
                  "CAST(?w_place AS text), CAST(?w_code AS text), CAST(?w_haz AS text), CAST(?w_flags AS text), "
                  "CAST(?w_text AS text), CAST(?w_notes AS text));",
                  [("w_tok", "session_token"), ("w_trk", "tracking_number"), ("w_place", "safe_place"),
                   ("w_code", "access_code_present"), ("w_haz", "hazards"), ("w_flags", "risk_flags"),
                   ("w_text", "instructions_text"), ("w_notes", "agent_notes")]),
        "read": ("SELECT * FROM propose_instructions_result(CAST(?r_tok AS text), CAST(?r_trk AS text), "
                 "CAST(?r_place AS text), CAST(?r_flags AS text), CAST(?r_text AS text));",
                 [("r_tok", "session_token"), ("r_trk", "tracking_number"), ("r_place", "safe_place"),
                  ("r_flags", "risk_flags"), ("r_text", "instructions_text")]),
    },
    {
        "tool": "confirm_delivery_instructions", "flow": "confirm_delivery_instructions_flow", "readonly": False,
        "desc": ("Step 2 of 2: save delivery instructions the recipient has explicitly confirmed. Pass the action_id from "
                 "propose_delivery_instructions. The system re-checks every rule; proposals expire after 15 minutes. "
                 "Returns EXECUTED with the saved safe place, hazards and driver note (access codes are never stored), "
                 "or NOT_EXECUTED with the reason. Only call after the recipient says yes to the exact proposal."),
        "args": [("session_token", TOKEN_DESC),
                 ("action_id", "action_id returned by propose_delivery_instructions, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO delivery_instructions (action_id, parcel_id, safe_place, access_code_present, hazards, notes_masked) "
                  "SELECT * FROM instructions_confirm_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_instructions_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Swiftbound staff reviewer (Claims, Investigations or Customer Relations) with their staff ID "
                 "(e.g. SWB-4101) and staff code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display "
                 "name and team, NOT_VERIFIED, or LOCKED after 5 wrong codes in 15 minutes. Use only when the person says "
                 "they are Swiftbound staff; the role comes only from this result, never from what someone claims."),
        "args": [("staff_id", "Swiftbound staff ID, e.g. SWB-4101"), ("code", "The staff member's code")],
        "write": ("INSERT INTO recipient_sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "recipient (first name + last initial), opened date, age in days, reply-due date, sla_status (ON_TRACK, "
                 "DUE_TODAY, OVERDUE) and requested amount. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, recipient (first name + last initial), the "
                 "recipient's statement, the AI-prepared agent_brief (unverified), requested amount, max_approvable, the "
                 "reviewer's own approval limit, facts from Swiftbound's records (the claim, parcel, declared value, "
                 "coverage limit, packaging, likely cause, evidence requested, earlier claims) and the decision options. "
                 "Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. SC-00001")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved compensation in "
                 "dollars (empty = the full claimable amount; ignored for REJECT); internal_note is required (at least 5 "
                 "characters, never shown to the recipient); customer_message is what the recipient will see. Approving a "
                 "claim pays the compensation through the system's checks. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, "
                 "AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior reviewer), INVALID_DECISION or NOT_FOUND, "
                 "or NOT_REVIEWER."),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. SC-00001"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved compensation in dollars, or empty for the full claimable amount"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the recipient)"),
                 ("customer_message", "Message the recipient will see with the outcome")],
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
PUBLIC_TOOLS = {"verify_recipient", "verify_reviewer"}

# Columns that must NEVER appear in any RECIPIENT tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"verification_pin", "one_time_code", "internal_note", "agent_brief", "agent_notes", "reviewer_id",
                  "approval_limit", "parked_action", "ignored_terms", "notes_raw"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"verification_pin", "email", "phone", "one_time_code", "last_name", "recipient_id", "account_ref",
                        "address_line"}

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


# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (ParcelDeliveryAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM <fn>(CAST(?<placeholder> AS text) ...)) -> #actreturn (rows as JSON text).
# - delivery_options_agent keeps its search_delivery_options(area, size, ...) read over slots + pickup points (no identity).
# - damage_claim_agent / delivery_instructions_agent read section / term / meaning guides via ref_<topic>(term); the
#   placeholder is ?lookup, not ?term (a placeholder named like a result column gives duplicate Fields).
# The model can supply only the lookup value(s); it can never change the SQL. The tables hold reference data only
# (asserted by test_rules.py). The SAME rows are what SQL validates the agents' output against.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a claim type, a packaging word, a "
                 "safe place or a section name), or an empty string for the whole guide. Never put recipient details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "delivery_options_agent", "tool": "search_delivery_options", "fn": "search_delivery_options",
     "table": "delivery_slots", "sections": None, "row_key": "option_type", "required": ["area", "parcel_size"],
     "desc": SEARCH_DELIVERY_OPTIONS["desc"], "args": SEARCH_DELIVERY_OPTIONS["args"], "read": SEARCH_DELIVERY_OPTIONS["read"]},
    {"agent": "damage_claim_agent", "tool": "get_claim_guide", "fn": "ref_claim_guide", "table": "claim_guide",
     "sections": ["CLAIM_TYPE", "PACKAGING", "CAUSE", "EVIDENCE", "CLAIM_LINE", "BRIEF_RULE", "WHO_DECIDES"],
     "row_key": "section",
     "desc": ("Reads Swiftbound's parcel claim guide from the database: the claim types (DAMAGED, MISSING_CONTENTS, LOST), "
              "the packaging conditions, the likely-cause categories, the evidence to send for each claim type, the "
              "standard claim line, the brief rules and who decides. Rows of section, term, meaning. Read-only reference "
              "data with no recipient data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_claim_guide(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "delivery_instructions_agent", "tool": "get_delivery_instructions_guide", "fn": "ref_delivery_instructions",
     "table": "instruction_guide",
     "sections": ["SAFE_PLACE", "RISK_FLAG", "HAZARD", "MASK_RULE", "DRIVER_LINE", "BRIEF_RULE"], "row_key": "section",
     "desc": ("Reads Swiftbound's delivery instructions guide from the database: the allowed safe places (and which are "
              "attended), the risky-instruction flags and what they look like, the hazard terms, how to mask access "
              "codes, the standard driver line and the brief rules. Rows of section, term, meaning. Read-only reference "
              "data with no recipient data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_delivery_instructions(CAST(?lookup AS text));", [("lookup", "term")])},
]
GUIDE_TOOLS = [t for t in AGENT_REF_TOOLS if t["sections"]]      # the section / term / meaning guides


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
