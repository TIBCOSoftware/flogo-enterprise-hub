"""Single source of truth for the 18 MCP tools of HospitalCareMCPServer (Bellmont Regional Medical Center, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

Two staff personas share one MCP server: COORDINATOR tools resolve only coordinator tokens (verify_coordinator, scoped
to the coordinator's ward), REVIEWER tools only reviewer tokens (verify_reviewer, scoped to the reviewer's team). The
email tool is special (email=True): SQL validates + builds the message, the flow sends it (to the EMAIL_TO app property,
the demo stand-in for the patient's email on file) only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Coordinator session token returned by verify_coordinator. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the coordinator to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A coordinator token does "
               "not work here (NOT_REVIEWER).")
PATIENT_DESC = "Patient MRN from get_ward_discharges, e.g. MRN-4012"
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."

TOOLS = [
    # ------------------------------------------------------------------ coordinator identity
    {
        "tool": "verify_coordinator", "flow": "verify_coordinator_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Bellmont discharge coordinator with their staff ID (BMC-4101, bmc4101 or 4101 all work) and their "
                 "one-time code. Returns VERIFIED with a session_token (valid 60 minutes), their name and their ward, "
                 "VERIFY_FAILED, or LOCKED after too many failed attempts. Call this before any coordinator tool. Never "
                 "reveal, guess or hint at codes. Pharmacists, charge nurses and attendings reviewing cases use "
                 "verify_reviewer instead." + VERBATIM),
        "args": [("staff_id", "The coordinator's Bellmont staff ID, e.g. BMC-4101"),
                 ("code", "The coordinator's one-time code")],
        "write": ("INSERT INTO sessions (role, coordinator_id) "
                  "SELECT * FROM verify_coordinator_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_coordinator_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ coordinator scoped reads
    {
        "tool": "get_ward_discharges", "flow": "get_ward_discharges_flow", "readonly": True,
        "desc": ("List the discharges on the verified coordinator's ward: patient MRN and name, bed, discharge_status "
                 "(DISCHARGED = has left, ORDERED = discharge order signed but still on the unit, PENDING = no discharge "
                 "order yet), planned date, time left, the follow-up the order asks for and whether it is booked, how many "
                 "discharge medicines there are, how many are ordered and how many wait for a pharmacist, and the bed "
                 "status. Only this ward's patients are returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM ward_discharges(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_discharge_summary", "flow": "get_discharge_summary_flow", "readonly": True,
        "desc": ("Get one patient's discharge summary on the coordinator's ward: one row per discharge medicine with the "
                 "patient, bed, service, attending, discharge_status, follow-up required / specialty / window, isolation, "
                 "and for each medicine its code, name, high_alert flag, the prescribed instructions (quote them exactly; "
                 "never change or add to them), days' supply and order_status. A patient on another ward returns NOT_FOUND."),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC)],
        "read": ("SELECT * FROM discharge_summary(CAST(?tok AS text), CAST(?pid AS text));",
                 [("tok", "session_token"), ("pid", "patient_id")]),
    },
    {
        "tool": "get_patient_appointments", "flow": "get_patient_appointments_flow", "readonly": True,
        "desc": ("List a patient's appointments and scheduled tests (for example an echocardiogram or a follow-up visit): "
                 "type, specialty, date and time, weekday, location, clinician and status. Status NONE = nothing "
                 "scheduled; NOT_FOUND = not a patient on your ward."),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC)],
        "read": ("SELECT * FROM patient_appointments(CAST(?tok AS text), CAST(?pid AS text));",
                 [("tok", "session_token"), ("pid", "patient_id")]),
    },
    {
        "tool": "get_followup_slots", "flow": "get_followup_slots_flow", "readonly": True,
        "desc": ("List the clinic slots that are eligible for a patient's follow-up visit: only OPEN slots of the specialty "
                 "the discharge order asks for, inside the follow-up window. Each row: slot_id, weekday, date, time, "
                 "part_of_day, location, clinician, wheelchair_accessible and transport_available (hospital wheelchair "
                 "transport). If the patient cannot be booked, status says why (NO_FOLLOWUP_REQUIRED, ALREADY_BOOKED, "
                 "DISCHARGE_NOT_ORDERED, NOT_FOUND, NONE_AVAILABLE) with a reason_text."),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC)],
        "read": ("SELECT * FROM followup_slots(CAST(?tok AS text), CAST(?pid AS text));",
                 [("tok", "session_token"), ("pid", "patient_id")]),
    },
    {
        "tool": "get_pharmacy_orders", "flow": "get_pharmacy_orders_flow", "readonly": True,
        "desc": ("List a patient's pharmacy orders: order_id (e.g. RX-000101), medicine, days' supply, pickup location, "
                 "ready-by time, order status and whether it was released after a pharmacist review. Status NONE = no "
                 "orders yet."),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC)],
        "read": ("SELECT * FROM patient_pharmacy_orders(CAST(?tok AS text), CAST(?pid AS text));",
                 [("tok", "session_token"), ("pid", "patient_id")]),
    },
    {
        "tool": "get_ward_beds", "flow": "get_ward_beds_flow", "readonly": True,
        "desc": ("List the beds on the coordinator's ward: bed_id (e.g. 4A-10), bed status (OCCUPIED, AVAILABLE, "
                 "CLEANING_REQUESTED, CLEANING_IN_PROGRESS), the patient in it and their discharge status, and the "
                 "estimated ready time when housekeeping has it."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM ward_beds(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    # ------------------------------------------------------------------ two-step follow-up booking
    {
        "tool": "propose_followup", "flow": "propose_followup_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to book a patient's follow-up visit. Pass the patient_id and a slot_id from get_followup_slots. "
                 "The system checks that the discharge order asks for a follow-up, that the slot is open, of the right "
                 "specialty and inside the follow-up window, and returns PROPOSED with a proposal_id and a summary "
                 "(expires in 15 minutes), or BLOCKED with a reason_code and reason_text. Nothing is booked until "
                 "confirm_action is called after the coordinator explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC),
                 ("slot_id", "Clinic slot id from get_followup_slots, e.g. SLOT-C105")],
        "write": ("INSERT INTO pending_actions (coordinator_id, action_type, target_key, patient_id, slot_id, outcome, "
                  "reason_code, reason_text, summary) "
                  "SELECT * FROM propose_followup_fn(CAST(?w_tok AS text), CAST(?w_pid AS text), CAST(?w_slot AS text));",
                  [("w_tok", "session_token"), ("w_pid", "patient_id"), ("w_slot", "slot_id")]),
        "read": ("SELECT * FROM propose_followup_result(CAST(?r_tok AS text), CAST(?r_pid AS text), CAST(?r_slot AS text));",
                 [("r_tok", "session_token"), ("r_pid", "patient_id"), ("r_slot", "slot_id")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: book a follow-up the coordinator has explicitly confirmed. Pass the proposal_id from "
                 "propose_followup. The system re-checks every rule and returns EXECUTED with a reference (e.g. "
                 "BMC-APT-000101), or BLOCKED / EXPIRED (after 15 minutes) / NOT_FOUND / ALREADY_DONE with the reason. "
                 "Only call after the coordinator says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from propose_followup, e.g. BMC-PRP-1A2B3C4D")],
        "write": ("INSERT INTO appointment_events (event_id, reference, proposal_id, coordinator_id, patient_id, slot_id, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ guarded single-step writes
    {
        "tool": "order_discharge_meds", "flow": "order_discharge_meds_flow", "readonly": False, "idempotent": False,
        "desc": ("Order a patient's discharge medicines from the pharmacy. medication = ALL (or empty) for every medicine on "
                 "the discharge list, or one or more names or codes (e.g. 'aspirin, metoprolol'). Only medicines on the "
                 "patient's discharge list can be ordered (anything else is NOT_ON_DISCHARGE_LIST), and only once the "
                 "discharge order is signed. High-alert medicines (e.g. warfarin, oxycodone, enoxaparin, insulin) are not "
                 "dispensed: the system parks them in a pharmacist case (PHARMACIST_REVIEW with case_id). "
                 "pharmacist_brief = the medication reconciliation flags if a reconciliation was done, else empty; it is "
                 "attached to any pharmacist case. Returns one row per medicine: ORDERED (order_id, pickup, ready_by), "
                 "ALREADY_ORDERED, PHARMACIST_REVIEW, or BLOCKED with a reason." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC),
                 ("medication", "ALL, or medicine names / codes separated by commas"),
                 ("pharmacist_brief", "Medication reconciliation flags for the pharmacist, or empty")],
        "write": ("INSERT INTO pharmacy_orders (order_id, dm_id, patient_id, medication_code, days_supply, pickup_location, "
                  "ready_by, ordered_by, case_id) "
                  "SELECT * FROM med_order_rows(CAST(?w_tok AS text), CAST(?w_pid AS text), CAST(?w_med AS text), "
                  "CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_pid", "patient_id"), ("w_med", "medication"), ("w_brief", "pharmacist_brief")]),
        "read": ("SELECT * FROM order_meds_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "patient_id")]),
    },
    {
        "tool": "request_bed_turnover", "flow": "request_bed_turnover_flow", "readonly": False, "idempotent": False,
        "desc": ("Send a vacated bed on the coordinator's ward to housekeeping. Pass the bed_id (e.g. 4A-10). The system "
                 "only accepts a bed whose patient has actually left (discharge_status DISCHARGED); it returns REQUESTED "
                 "with a reference and the estimated ready time (45 minutes, or 90 for an isolation clean), or BLOCKED "
                 "with PATIENT_NOT_DISCHARGED, ALREADY_REQUESTED, BED_EMPTY or NOT_FOUND. An early turnover while the "
                 "patient is still on the unit needs the charge nurse (open_service_case bed_override)." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("bed_id", "Bed id on your ward, e.g. 4A-10")],
        "write": ("INSERT INTO bed_events (reference, bed_id, ward_id, patient_id, override, requested_by, case_id, estimated_ready) "
                  "SELECT * FROM bed_turnover_row(CAST(?w_tok AS text), CAST(?w_bed AS text));",
                  [("w_tok", "session_token"), ("w_bed", "bed_id")]),
        "read": ("SELECT * FROM bed_turnover_result(CAST(?r_tok AS text), CAST(?r_bed AS text));",
                 [("r_tok", "session_token"), ("r_bed", "bed_id")]),
    },
    # ------------------------------------------------------------------ human-owned cases, status, email
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that needs a person to the right team. request_type is med_rec_review (agent_brief = the "
                 "reconciliation flags), bed_override (early turnover while the patient is still on the unit; reference_id "
                 "= the bed_id, or empty for the patient's bed), clinical_question (any dosage or clinical question), "
                 "prescription_change (add, stop or change a medicine) or discharge_decision (whether or when the patient "
                 "can go home). summary is a neutral 1-3 sentence summary in the coordinator's own words. The system routes "
                 "it and returns OPENED with case_id, team and reply time, EXISTING, or BLOCKED / INVALID_TYPE with a "
                 "reason. The assistant never answers clinical questions and never decides, promises or predicts the "
                 "outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "med_rec_review | bed_override | clinical_question | prescription_change | discharge_decision"),
                 ("patient_id", PATIENT_DESC),
                 ("summary", "Neutral summary of the request in the coordinator's words: facts only"),
                 ("reference_id", "Bed id for bed_override, else empty"),
                 ("agent_brief", "Medication reconciliation flags (med_rec_review only), else empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, patient_id, ward_id, opened_by, request_type, summary, "
                  "reference_id, requested_amount, parked_action, agent_brief, sla_due_at) "
                  "SELECT * FROM open_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_pid AS text), "
                  "CAST(?w_sum AS text), CAST(?w_ref AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_pid", "patient_id"), ("w_sum", "summary"),
                   ("w_ref", "reference_id"), ("w_brief", "agent_brief")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type"), ("r_pid", "patient_id")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the cases for patients on the coordinator's ward (requests a person decides): case_id, request, "
                 "patient, what it is about, team, case_status (OPEN, APPROVED, REJECTED), opened and reply-due times, "
                 "requested and approved days' supply, and the customer_message from the reviewer once decided. Use it "
                 "when the coordinator asks what happened to a request."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "email_patient_summary", "flow": "email_patient_summary_flow", "readonly": False, "idempotent": False,
        "email": True,
        "desc": ("Email a patient on the coordinator's ward their discharge plan: booked appointments, medicines with "
                 "pickup and ready times, and medicines still with the pharmacist. The system writes the email from what "
                 "was actually arranged and sends it only when something has been arranged for that patient (send_status "
                 "SEND_OK); otherwise NOT_SENT with reason_code NOTHING_TO_SEND, NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("patient_id", PATIENT_DESC)],
        "write": ("INSERT INTO email_log (patient_id, coordinator_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "patient_id")]),
        "read": ("SELECT * FROM email_payload(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "patient_id")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Bellmont reviewer (pharmacist, charge nurse or attending) with their staff ID (e.g. BMC-7701) and "
                 "one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display name and team, or "
                 "VERIFY_FAILED / LOCKED. Use only when the person says they are reviewing cases; the role comes only from "
                 "this result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Bellmont staff ID, e.g. BMC-7701"), ("code", "The reviewer's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due time, with case_id, request, "
                 "patient (first name + last initial), ward, opened time, age in hours, reply-due time, sla_status "
                 "(ON_TRACK, DUE_SOON, OVERDUE) and requested days' supply. Status EMPTY = no open cases; NOT_REVIEWER = "
                 "not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, patient (first name + last initial), ward "
                 "and bed, the coordinator's statement, the AI-prepared agent_brief (unverified), requested and maximum "
                 "approvable days' supply, the reviewer's own approval limit, the facts from Bellmont's records and the "
                 "decision options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. BMC-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved days' supply "
                 "(high-alert medicine cases; empty = the full prescribed supply; ignored for REJECT and for cases without "
                 "a supply); internal_note is required (at least 5 characters, never shown to the coordinator); "
                 "customer_message is what the coordinator will see. Approving runs the parked action (dispense the "
                 "medicine, or send the bed to housekeeping) through the system's checks. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, "
                 "AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior pharmacist) or NOT_FOUND, or NOT_REVIEWER."
                 + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. BMC-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved days' supply, e.g. 14, or empty"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the coordinator)"),
                 ("customer_message", "Message the coordinator will see with the outcome")],
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

# Columns that must NEVER appear in any COORDINATOR tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"date_of_birth", "phone", "email", "home_address", "insurance_id", "one_time_code", "internal_note",
                  "agent_brief", "reviewer_id", "approval_limit", "parked_action"}
# Columns that must never appear in REVIEWER tool output (HIPAA minimum necessary).
HIDDEN_FROM_REVIEWER = {"date_of_birth", "phone", "email", "home_address", "insurance_id", "one_time_code", "last_name",
                        "patient_id"}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (HospitalCareAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM ref_<topic>(CAST(?lookup AS text))) -> #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no patient, staff, case, session or contact data) - asserted by test_rules.py.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a medicine name, a phrase from your "
                 "input, or a section name), or an empty string for the whole guide. Never put patient details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "discharge_instructions_agent", "tool": "get_plain_language_guide", "fn": "ref_plain_language",
     "table": "plain_language_guide",
     "sections": ["PRESCRIPTION_WORD", "PICKUP", "APPOINTMENT_TYPE", "PENDING", "READING_LEVEL", "SAFETY_NET"],
     "desc": ("Reads Bellmont Regional Medical Center's plain-language guide from the hospital database: prescription "
              "words and abbreviations in everyday words, pickup locations, appointment types, what to say while a "
              "pharmacist is still reviewing a medicine, reading-level rules and the safety-net sentence. Rows of "
              "section, term, meaning. Read-only reference data with no patient data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_plain_language(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "med_reconciliation_agent", "tool": "get_med_rec_reference", "fn": "ref_med_rec",
     "table": "med_rec_reference",
     "sections": ["COMMON_NAME", "DRUG_CLASS", "FLAG_TYPE", "ALWAYS_FLAG", "HIGH_ALERT", "RULE"],
     "desc": ("Reads Bellmont Regional Medical Center's medication reconciliation reference from the hospital database: "
              "common names people use for medicines, drug classes, the four flag types, combinations a pharmacist "
              "always wants flagged, and the hospital's high-alert medicine list. Rows of section, term, meaning. "
              "Read-only reference data with no patient data. Pass term \"\" for the whole reference."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_med_rec(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "followup_slot_agent", "tool": "get_slot_ranking_guide", "fn": "ref_slot_guide",
     "table": "slot_ranking_guide",
     "sections": ["PART_OF_DAY", "ACCESS_CODE", "TRANSPORT_CODE", "CONSTRAINT", "SEQUENCE", "RANKING"],
     "desc": ("Reads Bellmont Regional Medical Center's clinic slot guide from the hospital database: what morning, "
              "afternoon and evening mean, the wheelchair-access and transport codes, how to read constraints such as "
              "'needs wheelchair transport' or 'after a test', and the ranking rules. Rows of section, term, meaning. "
              "Read-only reference data with no patient data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_slot_guide(CAST(?lookup AS text));", [("lookup", "term")])},
]
