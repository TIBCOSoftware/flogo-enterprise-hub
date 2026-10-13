"""Single source of truth for the 19 MCP tools of AerospaceMROMCPServer (Northvale Aero Services, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

Two staff personas share one MCP server: CONTROLLER tools resolve only controller tokens (verify_controller, scoped to
the controller's base), REVIEWER tools only reviewer tokens (verify_reviewer, scoped to the reviewer's team). The email
tool is special (email=True): SQL validates + builds the message, the flow sends it (to the EMAIL_TO app property, the
maintenance-control mailbox) only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Controller session token returned by verify_controller. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the controller to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A controller token does "
               "not work here (NOT_REVIEWER).")
TAIL_DESC = "Aircraft tail number at your base, e.g. N042NV"
WO_DESC = "Work order number, e.g. WO-2026-00101"
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."

TOOLS = [
    # ------------------------------------------------------------------ controller identity
    {
        "tool": "verify_controller", "flow": "verify_controller_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Northvale MRO controller with their staff ID (NVA-2101, nva2101 or 2101 all work) and their "
                 "one-time code. Returns VERIFIED with a session_token (valid 60 minutes), their name, their base and their "
                 "per-order part spend limit, VERIFY_FAILED, or LOCKED after too many failed attempts. Call this before any "
                 "controller tool. Never reveal, guess or hint at codes. Maintenance managers and Quality & Airworthiness "
                 "inspectors reviewing cases use verify_reviewer instead." + VERBATIM),
        "args": [("staff_id", "The controller's Northvale staff ID, e.g. NVA-2101"),
                 ("code", "The controller's one-time code")],
        "write": ("INSERT INTO sessions (role, controller_id) "
                  "SELECT * FROM verify_controller_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_controller_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ controller scoped reads
    {
        "tool": "get_base_fleet", "flow": "get_base_fleet_flow", "readonly": True,
        "desc": ("List the aircraft at the verified controller's base: tail number, aircraft type, platform, status (AOG, "
                 "GROUNDED, IN_MAINTENANCE, IN_SERVICE), flight hours, cycles, next check and due date, how many work orders "
                 "are open and any open AOG incident. Only this base's aircraft are returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM base_fleet(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_work_orders", "flow": "get_work_orders_flow", "readonly": True,
        "desc": ("List open work orders at the controller's base: wo_number, tail, aircraft type, type, ATA chapter, "
                 "description, priority, status (OPEN, AWAITING_PARTS, IN_PROGRESS), the certification the job requires, "
                 "the assigned technician (or unassigned), opened and due dates. tail_number = ALL (or empty) for the whole "
                 "base, or one tail. A tail at another base returns NOT_FOUND; NONE = no open work orders."),
        "args": [("session_token", TOKEN_DESC), ("tail_number", "A tail number at your base, or ALL")],
        "read": ("SELECT * FROM work_orders_at(CAST(?tok AS text), CAST(?tail AS text));",
                 [("tok", "session_token"), ("tail", "tail_number")]),
    },
    {
        "tool": "get_tail_history", "flow": "get_tail_history_flow", "readonly": True,
        "desc": ("Get one aircraft's maintenance history for the last 180 days (open and closed work orders): wo_number, "
                 "opened and closed dates, ATA chapter, type, description, status, and same_ata_last_30_days (how many work "
                 "orders in the same ATA chapter were opened on this tail in the last 30 days). Use it before a repeat-defect "
                 "check. A tail at another base returns NOT_FOUND."),
        "args": [("session_token", TOKEN_DESC), ("tail_number", TAIL_DESC)],
        "read": ("SELECT * FROM tail_history(CAST(?tok AS text), CAST(?tail AS text));",
                 [("tok", "session_token"), ("tail", "tail_number")]),
    },
    {
        "tool": "get_parts", "flow": "get_parts_flow", "readonly": True,
        "desc": ("Search the Northvale parts catalogue with stock at the controller's base: part_number, description, ATA "
                 "chapter, the aircraft type it fits, unit price, on hand at your base, reorder level, below_reorder, "
                 "standard lead days, expedite days and quantity already on order. search = ALL (or empty) for everything, "
                 "or words that must all match (part number, description, 'ata 29', aircraft type such as NV-450)."),
        "args": [("session_token", TOKEN_DESC), ("search", "Words to match, e.g. 'hydraulic NV-450', a part number, or ALL")],
        "read": ("SELECT * FROM parts_at(CAST(?tok AS text), CAST(?q AS text));",
                 [("tok", "session_token"), ("q", "search")]),
    },
    {
        "tool": "get_part_orders", "flow": "get_part_orders_flow", "readonly": True,
        "desc": ("List part orders at the controller's base: order_id (e.g. PO-2026-0101), part, quantity, tail, work order, "
                 "priority (ROUTINE or EXPEDITE), total in USD, status (ORDERED, IN_TRANSIT, RECEIVED), ordered date, "
                 "expected delivery and whether a manager approved the spend. Status NONE = no orders."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM part_orders_at(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_technicians", "flow": "get_technicians_flow", "readonly": True,
        "desc": ("List the technicians at the controller's base: tech_id (e.g. TECH-201), name, certifications, type "
                 "ratings, shift, availability (AVAILABLE, ON_TASK, OFF) and current work order. certification = a skill or "
                 "type rating to filter by (e.g. HYDRAULICS, NV-450), or ALL (or empty)."),
        "args": [("session_token", TOKEN_DESC), ("certification", "Certification or type rating to filter by, or ALL")],
        "read": ("SELECT * FROM technicians_at(CAST(?tok AS text), CAST(?cert AS text));",
                 [("tok", "session_token"), ("cert", "certification")]),
    },
    {
        "tool": "get_aog_incidents", "flow": "get_aog_incidents_flow", "readonly": True,
        "desc": ("List aircraft-on-ground (AOG) incidents at the controller's base (open, resolving, and resolved in the last "
                 "30 days): aog_id, tail, aircraft type, reported time, hours on ground, reason, severity, status (OPEN, "
                 "RESOLVING, RESOLVED) and resolution so far."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM aog_incidents_at(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_base_handover", "flow": "get_base_handover_flow", "readonly": True,
        "desc": ("Get the base's shift-handover snapshot: open AOGs, open work orders (with whether a technician is assigned), "
                 "parts on order with ETA, open cases (by request type) with their reply-due time, and decisions in the last 24 "
                 "hours. Equipment data only (no people's names, no case ids) - it can be passed to shift_handover_agent as is."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM base_handover(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    # ------------------------------------------------------------------ two-step guarded writes
    {
        "tool": "propose_part_order", "flow": "propose_part_order_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to order or expedite a part for a work order at your base. Pass the wo_number, a part_number "
                 "from get_parts, a quantity (1-10) and priority ROUTINE or EXPEDITE. The system checks that the work order "
                 "is open at your base, the part fits that aircraft type and is not already on order, works out the total "
                 "and the delivery date from the lead time, and returns PROPOSED with a proposal_id, total_usd, "
                 "needs_manager_approval and a summary (expires in 15 minutes), or BLOCKED with a reason_code and "
                 "reason_text. needs_manager_approval = yes means the spend is above the controller's per-order limit: "
                 "confirming sends it to a maintenance manager instead of ordering. Nothing happens until confirm_action is "
                 "called after the controller explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("wo_number", WO_DESC),
                 ("part_number", "Part number from get_parts, e.g. NV29-4471-SK"),
                 ("quantity", "Whole number of units, 1-10"),
                 ("priority", "ROUTINE or EXPEDITE")],
        "write": ("INSERT INTO pending_actions (controller_id, action_type, target_key, wo_number, part_number, quantity, priority, "
                  "total_usd, needs_approval, outcome, reason_code, reason_text, summary) "
                  "SELECT * FROM propose_part_order_fn(CAST(?w_tok AS text), CAST(?w_wo AS text), CAST(?w_part AS text), "
                  "CAST(?w_qty AS text), CAST(?w_prio AS text));",
                  [("w_tok", "session_token"), ("w_wo", "wo_number"), ("w_part", "part_number"), ("w_qty", "quantity"),
                   ("w_prio", "priority")]),
        "read": ("SELECT * FROM propose_part_order_result(CAST(?r_tok AS text), CAST(?r_wo AS text), CAST(?r_part AS text), "
                 "CAST(?r_qty AS text), CAST(?r_prio AS text));",
                 [("r_tok", "session_token"), ("r_wo", "wo_number"), ("r_part", "part_number"), ("r_qty", "quantity"),
                  ("r_prio", "priority")]),
    },
    {
        "tool": "propose_dispatch", "flow": "propose_dispatch_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to dispatch a technician to a work order at your base. Pass the wo_number and the tech_id from "
                 "get_technicians (a full name also works). The system checks that the work order is open and unassigned, "
                 "that the technician is at your base, holds the certification the job requires and a type rating for that "
                 "aircraft, and is AVAILABLE, and returns PROPOSED with a proposal_id and a summary (expires in 15 minutes), "
                 "or BLOCKED with reason_code NOT_CERTIFIED, TECH_UNAVAILABLE, WRONG_BASE, ALREADY_ASSIGNED, WO_CLOSED, "
                 "TECH_NOT_FOUND or NOT_FOUND and a reason_text. Nobody is dispatched until confirm_action is called after the "
                 "controller explicitly says yes." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("wo_number", WO_DESC),
                 ("tech_id", "Technician id from get_technicians, e.g. TECH-201")],
        "write": ("INSERT INTO pending_actions (controller_id, action_type, target_key, wo_number, tech_id, outcome, reason_code, "
                  "reason_text, summary) "
                  "SELECT * FROM propose_dispatch_fn(CAST(?w_tok AS text), CAST(?w_wo AS text), CAST(?w_tech AS text));",
                  [("w_tok", "session_token"), ("w_wo", "wo_number"), ("w_tech", "tech_id")]),
        "read": ("SELECT * FROM propose_dispatch_result(CAST(?r_tok AS text), CAST(?r_wo AS text), CAST(?r_tech AS text));",
                 [("r_tok", "session_token"), ("r_wo", "wo_number"), ("r_tech", "tech_id")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: carry out a part order or a dispatch the controller has explicitly confirmed. Pass the "
                 "proposal_id from propose_part_order or propose_dispatch. The system re-checks every rule and returns "
                 "EXECUTED with a reference (order PO-2026-0101 or dispatch NVA-DSP-000101), MANAGER_APPROVAL with a case_id "
                 "(spend above the controller's limit: nothing is ordered until a maintenance manager approves), or BLOCKED "
                 "/ EXPIRED (after 15 minutes) / NOT_FOUND / ALREADY_DONE with the reason. Only call after the controller says "
                 "yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from the propose tool, e.g. NVA-PRP-1A2B3C4D")],
        "write": ("INSERT INTO action_events (event_id, reference, proposal_id, controller_id, action_type, wo_number, part_number, "
                  "quantity, priority, tech_id, total_usd, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ human-owned cases, status, email
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that a person must decide to the right team. request_type is return_to_service "
                 "(return-to-service sign-off, including closing an AOG), ad_compliance (airworthiness directive compliance), "
                 "mel_deferral (deferring an item under the MEL), grounding_change (grounding or ungrounding an aircraft) or "
                 "reliability_review (a repeat defect; agent_brief = the repeat-defect agent's flag). summary is a neutral "
                 "1-3 sentence summary in the controller's own words. The system routes it and returns OPENED with case_id, "
                 "team and reply time, EXISTING, or BLOCKED / INVALID_TYPE with a reason. The assistant never signs off, "
                 "defers, grounds or releases an aircraft and never promises or predicts the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "return_to_service | ad_compliance | mel_deferral | grounding_change | reliability_review"),
                 ("tail_number", TAIL_DESC),
                 ("summary", "Neutral summary of the request in the controller's words: facts only"),
                 ("agent_brief", "Repeat-defect agent's flag (reliability_review only), else empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, base_id, tail_number, opened_by, request_type, summary, "
                  "reference_id, requested_amount, unit_price, parked_action, agent_brief, sla_due_at) "
                  "SELECT * FROM open_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_tail AS text), "
                  "CAST(?w_sum AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_tail", "tail_number"), ("w_sum", "summary"),
                   ("w_brief", "agent_brief")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text), CAST(?r_tail AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type"), ("r_tail", "tail_number")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the cases for aircraft at the controller's base (requests a person decides): case_id, request, tail, "
                 "what it is about, team, case_status (OPEN, APPROVED, REJECTED), opened and reply-due times, requested and "
                 "approved units, and the customer_message from the reviewer once decided. Use it when the controller asks "
                 "what happened to a request or an approval."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "email_ops_summary", "flow": "email_ops_summary_flow", "readonly": False, "idempotent": False,
        "email": True,
        "desc": ("Email the maintenance-control mailbox an ops summary for one aircraft at your base: its status and AOG, "
                 "part orders with delivery dates, technicians dispatched and its cases. The system writes the email from "
                 "what was actually recorded and sends it only when something has been done on that aircraft (send_status "
                 "SEND_OK); otherwise NOT_SENT with reason_code NOTHING_TO_SEND, NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("tail_number", TAIL_DESC)],
        "write": ("INSERT INTO email_log (tail_number, controller_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_tail AS text));",
                  [("w_tok", "session_token"), ("w_tail", "tail_number")]),
        "read": ("SELECT * FROM email_payload(CAST(?r_tok AS text), CAST(?r_tail AS text));",
                 [("r_tok", "session_token"), ("r_tail", "tail_number")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Northvale reviewer (maintenance manager or Quality & Airworthiness inspector) with their staff ID "
                 "(e.g. NVA-7101) and one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display "
                 "name and team, or VERIFY_FAILED / LOCKED. Use only when the person says they are reviewing cases; the role "
                 "comes only from this result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Northvale staff ID, e.g. NVA-7101"), ("code", "The reviewer's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due time, with case_id, request, tail, "
                 "base, opened time, age in hours, reply-due time, sla_status (ON_TRACK, DUE_SOON, OVERDUE), requested units "
                 "and requested spend in USD. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, tail and base, the controller's statement, "
                 "the AI-prepared agent_brief (unverified), requested units, unit price, requested spend, maximum approvable "
                 "units, the reviewer's own spend authority, the facts from Northvale's records and the decision options. "
                 "Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. NVA-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly confirmed "
                 "the restated decision. decision is APPROVE or REJECT; amount is the approved NUMBER OF UNITS for a part "
                 "spend approval (empty = everything requested; ignored for REJECT and for cases without a quantity); "
                 "internal_note is required (at least 5 characters, never shown to the controller); customer_message is what "
                 "the controller will see. Approving runs the parked action (place the part order, or record the return to "
                 "service) through the system's checks. Returns APPROVED / REJECTED with executed_action, or BLOCKED with "
                 "reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY (case stays open "
                 "for a senior manager), NOT_READY or NOT_FOUND, or NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. NVA-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved number of units, e.g. 2, or empty"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the controller)"),
                 ("customer_message", "Message the controller will see with the outcome")],
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

# Columns that must NEVER appear in any CONTROLLER tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"email", "phone", "one_time_code", "internal_note", "agent_brief", "reviewer_id", "approval_limit",
                  "parked_action"}
# Columns that must never appear in REVIEWER tool output.
HIDDEN_FROM_REVIEWER = {"email", "phone", "one_time_code"}


# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools - NOT MCP tools. Each A2A agent in AerospaceMROAgents has exactly one tool whose flow runs
#   #act_postgresql_query  SELECT * FROM ref_<topic>(CAST(?lookup AS text))  ->  #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no staff, technician, reviewer, case, session, tail, work-order or contact data) -
# asserted by test_rules.py. PART_FAMILY rows are read from parts and WHO_DECIDES from case_routing (one source of
# truth). The same-chapter count in the last 30 days stays in SQL (tail_history.same_ata_last_30_days).
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example an ATA chapter, a symptom, a "
                 "flag, a status code or a section name), or an empty string for the whole guide. Never put names, "
                 "staff ids, tails, work orders or case ids here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "fault_triage_agent", "tool": "get_ata_chapter_guide", "fn": "ref_ata_chapters",
     "table": "ata_chapter_guide",
     "sections": ["ATA_CHAPTER", "SYMPTOM", "SHORTHAND", "PART_FAMILY", "RULE"],
     "desc": ("Reads Northvale Aero Services' ATA chapter guide from the database: each ATA chapter (public standard) "
              "with what it covers, the certification the job needs and Northvale's standard triage note, symptom "
              "hints, crew write-up shorthand, the catalogue part families per chapter and the triage rules. Rows of "
              "section, term, meaning. Read-only reference data with no aircraft, work-order or personal data. Pass "
              "term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_ata_chapters(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "repeat_defect_agent", "tool": "get_repeat_defect_guide", "fn": "ref_repeat_defect_criteria",
     "table": "repeat_defect_guide",
     "sections": ["FLAG", "WINDOW", "SAME_SYSTEM", "DIFFERENT_SYSTEM", "TERM", "WHO_DECIDES", "RULE"],
     "desc": ("Reads Northvale Aero Services' repeat-defect criteria from the database: the flag levels REPEAT, "
              "POSSIBLE_REPEAT and NO_REPEAT with their standard reliability notes, the time window, what counts as "
              "the same or a different system, reliability-program terms and who decides. Rows of section, term, "
              "meaning. Read-only reference data with no aircraft, work-order or personal data. Pass term \"\" for "
              "the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_repeat_defect_criteria(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "shift_handover_agent", "tool": "get_handover_format_guide", "fn": "ref_handover_guide",
     "table": "handover_guide",
     "sections": ["SECTION", "STATUS", "STANDARD_LINE", "RULE"],
     "desc": ("Reads Northvale Aero Services' shift-handover guide from the database: the handover sections in order "
              "and what each says, every status code in plain words, the standard handover lines (including the "
              "closing line) and the length and wording rules. Rows of section, term, meaning. Read-only reference "
              "data with no aircraft, work-order or personal data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_handover_guide(CAST(?lookup AS text));", [("lookup", "term")])},
]
