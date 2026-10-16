"""Single source of truth for the 20 MCP tools of AssetHealthMCPServer (Mesa Ridge Energy, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

Two staff personas share one MCP server: OPERATOR tools resolve only operator tokens (verify_operator, scoped to the
operator's region), REVIEWER tools only reviewer tokens (verify_reviewer, scoped to the reviewer's team). The email
tool is special (email=True): SQL validates + builds the message, the flow sends it (to the EMAIL_TO app property, the
control-room mailbox) only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Operator session token returned by verify_operator. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the operator to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. An operator token does "
               "not work here (NOT_REVIEWER).")
ASSET_DESC = "Asset id in your region, e.g. PUMP-PB-W47 (the short well/station tag W47 also works)"
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."

TOOLS = [
    # ------------------------------------------------------------------ operator identity
    {
        "tool": "verify_operator", "flow": "verify_operator_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Mesa Ridge control-room operator with their staff ID (MRE-4101, mre4101 or 4101 all work) and "
                 "their one-time code. Returns VERIFIED with a session_token (valid 60 minutes), their name, their region and "
                 "their work-order limit, VERIFY_FAILED, or LOCKED after too many failed attempts. Call this before any "
                 "operator tool. Never reveal, guess or hint at codes. Production Engineering supervisors and HSE reviewers "
                 "use verify_reviewer instead." + VERBATIM),
        "args": [("staff_id", "The operator's Mesa Ridge staff ID, e.g. MRE-4101"),
                 ("code", "The operator's one-time code")],
        "write": ("INSERT INTO sessions (role, operator_id) "
                  "SELECT * FROM verify_operator_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_operator_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ operator scoped reads
    {
        "tool": "get_region_assets", "flow": "get_region_assets_flow", "readonly": True,
        "desc": ("List the assets in the verified operator's region with their health computed by Mesa Ridge's rules: asset "
                 "id, type, description, asset status (OPERATIONAL, MAINTENANCE, SHUT_IN), health_status (CRITICAL, WARNING, "
                 "NORMAL), worst sensor, likely failure mode, confidence, days to failure, open work order, open alerts and "
                 "the latest reading time. Worst health first. Never classify an asset yourself - quote these values."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM region_assets(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_asset_health", "flow": "get_asset_health_flow", "readonly": True,
        "desc": ("Get one asset's health as computed by the deterministic classifier: health_status, worst sensor, number of "
                 "anomalous sensors, failure mode and label, confidence, days to failure, the anomalies with their thresholds, "
                 "the recommended action and repair estimate, the latest reading (vibration g RMS, temperature F, pressure "
                 "psi, flow bbl/h, power kW), any open work order and work_order_allowed (yes, or no with the reason). An asset "
                 "in another region returns NOT_FOUND. Quote these values; never re-classify."),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC)],
        "read": ("SELECT * FROM asset_health(CAST(?tok AS text), CAST(?aid AS text));",
                 [("tok", "session_token"), ("aid", "asset_id")]),
    },
    {
        "tool": "get_sensor_readings", "flow": "get_sensor_readings_flow", "readonly": True,
        "desc": ("Get the last 24 hours of sensor readings for one asset in the operator's region, oldest first (one reading "
                 "every 4 hours): reading time, vibration (g RMS), temperature (F), pressure (psi), flow (bbl/h), power (kW). "
                 "Use it to describe a trend. NOT_FOUND = not in your region."),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC)],
        "read": ("SELECT * FROM sensor_readings_at(CAST(?tok AS text), CAST(?aid AS text));",
                 [("tok", "session_token"), ("aid", "asset_id")]),
    },
    {
        "tool": "get_work_orders", "flow": "get_work_orders_flow", "readonly": True,
        "desc": ("List work orders in the operator's region: open ones first, then those closed in the last 90 days. wo_number, "
                 "asset, type (CORRECTIVE, PREVENTIVE, SAFETY_INSPECTION), failure mode, symptom, priority, status (OPEN, "
                 "SCHEDULED, IN_PROGRESS, CLOSED), crew, scheduled date, estimate, approved budget and whether a supervisor "
                 "approved it. asset_id = ALL (or empty) for the whole region, or one asset; NOT_FOUND = asset not in your "
                 "region; NONE = no work orders."),
        "args": [("session_token", TOKEN_DESC), ("asset_id", "An asset id in your region, or ALL")],
        "read": ("SELECT * FROM work_orders_at(CAST(?tok AS text), CAST(?aid AS text));",
                 [("tok", "session_token"), ("aid", "asset_id")]),
    },
    {
        "tool": "get_alerts", "flow": "get_alerts_flow", "readonly": True,
        "desc": ("List alerts in the operator's region (open or acknowledged, plus the last 30 days): alert_id, asset, severity "
                 "(WARNING, CRITICAL), failure mode, message, status (OPEN, ACKNOWLEDGED, CLOSED), when and by whom (monitoring "
                 "system or control room). asset_id = ALL (or empty) or one asset."),
        "args": [("session_token", TOKEN_DESC), ("asset_id", "An asset id in your region, or ALL")],
        "read": ("SELECT * FROM alerts_at(CAST(?tok AS text), CAST(?aid AS text));",
                 [("tok", "session_token"), ("aid", "asset_id")]),
    },
    {
        "tool": "get_failure_modes", "flow": "get_failure_modes_flow", "readonly": True,
        "desc": ("List the failure modes that apply to one asset's type, with label, recommended action, typical parts, repair "
                 "estimate and downtime, the asset's current health line, and whether each mode matches the sensor "
                 "classification. Pass these rows (without anything about people) to field_note_triage_agent: it must pick "
                 "the failure mode and parts from this list only."),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC)],
        "read": ("SELECT * FROM failure_modes_for(CAST(?tok AS text), CAST(?aid AS text));",
                 [("tok", "session_token"), ("aid", "asset_id")]),
    },
    {
        "tool": "get_failure_history", "flow": "get_failure_history_flow", "readonly": True,
        "desc": ("Get Mesa Ridge's reliability library for the asset's type: closed work orders across all basins from the last "
                 "2 years with wo_number, past asset, basin, closed date, failure mode, the symptom as written, the fix applied, "
                 "parts used and downtime. Equipment data only (no people) - pass the rows to similar_failure_agent as they are."),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC)],
        "read": ("SELECT * FROM failure_history(CAST(?tok AS text), CAST(?aid AS text));",
                 [("tok", "session_token"), ("aid", "asset_id")]),
    },
    {
        "tool": "get_region_handover", "flow": "get_region_handover_flow", "readonly": True,
        "desc": ("Get the region's shift-handover snapshot: open cases (by request type) with their reply-due time, assets in "
                 "WARNING or CRITICAL with the anomalies, open work orders, open alerts, field notes from the last 12 hours and "
                 "decisions from the last 24 hours. Equipment data only (no people's names, no case ids) - it can be passed to "
                 "shift_handover_agent as is."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM region_handover(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    # ------------------------------------------------------------------ the governed fuzzy step
    {
        "tool": "log_field_note", "flow": "log_field_note_flow", "readonly": False, "idempotent": False,
        "desc": ("Log a technician's field note for an asset in your region together with field_note_triage_agent's reading of "
                 "it. Pass the note text exactly as written and the agent's failure_mode, urgency (LOW, MEDIUM, HIGH, "
                 "IMMEDIATE), safety_language (yes or no) and a one-line summary (likely parts and the safety phrase, if any). "
                 "The system checks the agent's output, reconciles it with the sensor classification and returns the next "
                 "step: SAFETY_CASE (safety language - an HSE case was opened or joined; no work order from this note), "
                 "WORK_ORDER_ELIGIBLE (a work order can be proposed) or MONITOR (sensors normal, or the asset already has work), "
                 "with agreement (AGREE, DIFFERENT, NO_SENSOR_ANOMALY, AGENT_MODE_INVALID), case_id and reason_text. "
                 "NOT_FOUND = asset not in your region." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC),
                 ("note_text", "The technician's note exactly as written"),
                 ("failure_mode", "The triage agent's failure mode, e.g. bearing_wear, or empty"),
                 ("urgency", "The triage agent's urgency: LOW, MEDIUM, HIGH or IMMEDIATE"),
                 ("safety_language", "yes if the triage agent found safety language, else no"),
                 ("summary", "The triage agent's one-line summary: likely parts and the safety phrase, if any")],
        "write": ("INSERT INTO field_notes (note_id, asset_id, operator_id, note_text, agent_failure_mode, agent_urgency, agent_safety, "
                  "agent_summary, health_status, sql_failure_mode, agreement, safety_source, safety_phrase, reconciled_action, case_id, "
                  "new_case) "
                  "SELECT * FROM field_note_row(CAST(?w_tok AS text), CAST(?w_aid AS text), CAST(?w_note AS text), CAST(?w_mode AS text), "
                  "CAST(?w_urg AS text), CAST(?w_safe AS text), CAST(?w_sum AS text));",
                  [("w_tok", "session_token"), ("w_aid", "asset_id"), ("w_note", "note_text"), ("w_mode", "failure_mode"),
                   ("w_urg", "urgency"), ("w_safe", "safety_language"), ("w_sum", "summary")]),
        "read": ("SELECT * FROM field_note_result(CAST(?r_tok AS text), CAST(?r_aid AS text), CAST(?r_note AS text));",
                 [("r_tok", "session_token"), ("r_aid", "asset_id"), ("r_note", "note_text")]),
    },
    # ------------------------------------------------------------------ two-step guarded write
    {
        "tool": "propose_work_order", "flow": "propose_work_order_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to create a corrective work order for an asset in your region. Pass the asset_id, a failure_mode "
                 "from get_failure_modes (empty = the sensor classification's mode) and a short note (the symptom, a similar "
                 "past fix). The system checks that the asset is not in MAINTENANCE or SHUT_IN, has no open work order and is "
                 "WARNING or CRITICAL, sets the priority, crew, scheduled date and estimate from Mesa Ridge's tables, and "
                 "returns PROPOSED with a proposal_id, estimate_usd, needs_supervisor_approval and a summary (expires in 15 "
                 "minutes), or BLOCKED with reason_code ASSET_IN_MAINTENANCE, ASSET_SHUT_IN, OPEN_WO_EXISTS, HEALTH_NORMAL, "
                 "FAILURE_MODE_INVALID or NOT_FOUND and a reason_text. needs_supervisor_approval = yes means the estimate is "
                 "above the operator's limit: confirming sends it to Production Engineering instead of creating it. Nothing "
                 "happens until confirm_action is called after the operator explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC),
                 ("failure_mode", "Failure mode from get_failure_modes, e.g. bearing_wear, or empty"),
                 ("note", "Short note for the crew: the symptom and any similar past fix")],
        "write": ("INSERT INTO pending_actions (operator_id, action_type, target_key, asset_id, failure_mode, note, priority, estimate_usd, "
                  "needs_approval, outcome, reason_code, reason_text, summary) "
                  "SELECT * FROM propose_work_order_fn(CAST(?w_tok AS text), CAST(?w_aid AS text), CAST(?w_mode AS text), "
                  "CAST(?w_note AS text));",
                  [("w_tok", "session_token"), ("w_aid", "asset_id"), ("w_mode", "failure_mode"), ("w_note", "note")]),
        "read": ("SELECT * FROM propose_work_order_result(CAST(?r_tok AS text), CAST(?r_aid AS text), CAST(?r_mode AS text));",
                 [("r_tok", "session_token"), ("r_aid", "asset_id"), ("r_mode", "failure_mode")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: carry out a work order the operator has explicitly confirmed. Pass the proposal_id from "
                 "propose_work_order. The system re-checks every rule and returns EXECUTED with the work_order number (e.g. "
                 "MRE-WO-1101), SUPERVISOR_APPROVAL with a case_id (estimate above the operator's limit: nothing is created "
                 "until a Production Engineering supervisor approves), or BLOCKED / EXPIRED (after 15 minutes) / NOT_FOUND / "
                 "ALREADY_DONE with the reason. Only call after the operator says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from propose_work_order, e.g. MRE-PRP-1A2B3C4D")],
        "write": ("INSERT INTO action_events (event_id, reference, proposal_id, operator_id, action_type, asset_id, failure_mode, "
                  "priority, estimate_usd, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    {
        "tool": "log_alert", "flow": "log_alert_flow", "readonly": False, "idempotent": False,
        "desc": ("Log an alert for an asset in your region. The severity, failure mode and message come from the sensor "
                 "classification, not from you. Returns LOGGED with the alert_id, ALREADY_LOGGED_TODAY (one alert per asset per "
                 "day - the existing alert is shown), HEALTH_NORMAL (no alert for a NORMAL asset) or NOT_FOUND. Closing an "
                 "alert is a Production Engineering decision (open_service_case alert_closure)." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC)],
        "write": ("INSERT INTO alerts (alert_id, asset_id, severity, failure_mode, message, logged_by) "
                  "SELECT * FROM alert_row(CAST(?w_tok AS text), CAST(?w_aid AS text));",
                  [("w_tok", "session_token"), ("w_aid", "asset_id")]),
        "read": ("SELECT * FROM alert_result(CAST(?r_tok AS text), CAST(?r_aid AS text));",
                 [("r_tok", "session_token"), ("r_aid", "asset_id")]),
    },
    # ------------------------------------------------------------------ human-owned cases, status, email
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that a person must decide to the right team. request_type is shut_in (shut-in or emergency "
                 "shutdown of an asset), safety_signal (gas odor, H2S, a spill, fire or an injury reported directly - a field "
                 "note with safety language is routed by log_field_note instead), threshold_change (changing a sensor "
                 "threshold) or alert_closure (closing the asset's open alert). summary is a neutral 1-3 sentence summary in the "
                 "operator's own words; agent_brief is an agent's output if relevant, else empty. The system routes it and "
                 "returns OPENED with case_id, team and reply time, EXISTING, or BLOCKED / INVALID_TYPE with a reason. The "
                 "assistant never shuts in, restarts or clears anything itself and never promises or predicts the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "shut_in | safety_signal | threshold_change | alert_closure"),
                 ("asset_id", ASSET_DESC),
                 ("summary", "Neutral summary of the request in the operator's words: facts only"),
                 ("agent_brief", "An agent's output if relevant, else empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, site_id, asset_id, opened_by, request_type, summary, reference_id, "
                  "requested_amount, parked_action, agent_brief, sla_due_at) "
                  "SELECT * FROM open_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_aid AS text), "
                  "CAST(?w_sum AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_aid", "asset_id"), ("w_sum", "summary"),
                   ("w_brief", "agent_brief")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text), CAST(?r_aid AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type"), ("r_aid", "asset_id")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the cases for assets in the operator's region (requests a person decides): case_id, request, asset, what "
                 "it is about, team, case_status (OPEN, APPROVED, REJECTED), opened and reply-due times, requested and approved "
                 "budget, and the customer_message from the reviewer once decided. Use it when the operator asks what happened "
                 "to a request or an approval."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "email_asset_summary", "flow": "email_asset_summary_flow", "readonly": False, "idempotent": False,
        "email": True,
        "desc": ("Email the control-room mailbox a summary for one asset in your region: its status and sensor health, open work "
                 "orders, alerts and cases. The system writes the email from what was actually recorded and sends it only when "
                 "something has been done on that asset (send_status SEND_OK); otherwise NOT_SENT with reason_code "
                 "NOTHING_TO_SEND, NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("asset_id", ASSET_DESC)],
        "write": ("INSERT INTO email_log (asset_id, operator_id, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_aid AS text));",
                  [("w_tok", "session_token"), ("w_aid", "asset_id")]),
        "read": ("SELECT * FROM email_payload(CAST(?r_tok AS text), CAST(?r_aid AS text));",
                 [("r_tok", "session_token"), ("r_aid", "asset_id")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Mesa Ridge reviewer (Production Engineering supervisor or HSE) with their staff ID (e.g. MRE-7101) "
                 "and one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display name and team, or "
                 "VERIFY_FAILED / LOCKED. Use only when the person says they are reviewing cases; the role comes only from this "
                 "result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Mesa Ridge staff ID, e.g. MRE-7101"), ("code", "The reviewer's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due time, with case_id, request, asset, "
                 "region, opened time, age in hours, reply-due time, sla_status (ON_TRACK, DUE_SOON, OVERDUE) and requested "
                 "budget. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, asset and region, the operator's statement, the "
                 "AI-prepared agent_brief (unverified), requested budget, maximum approvable budget, the reviewer's own budget "
                 "authority, the facts from Mesa Ridge's records (sensor health, work orders, alerts, field notes) and the "
                 "decision options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. MRE-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly confirmed the "
                 "restated decision. decision is APPROVE or REJECT; amount is the approved BUDGET in USD for a work order budget "
                 "approval (empty = the full estimate; ignored for REJECT and for cases without a budget); internal_note is "
                 "required (at least 5 characters, never shown to the operator); customer_message is what the operator will "
                 "see. Approving runs the parked action (create the work order, record the shut-in, create the safety-inspection "
                 "work order, close the alert) through the system's checks. Returns APPROVED / REJECTED with executed_action, "
                 "or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY "
                 "(case stays open for a senior supervisor), NOT_READY or NOT_FOUND, or NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. MRE-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved budget in USD, e.g. 68000, or empty"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the operator)"),
                 ("customer_message", "Message the operator will see with the outcome")],
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

# Columns that must NEVER appear in any OPERATOR tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"one_time_code", "internal_note", "agent_brief", "reviewer_id", "approval_limit", "parked_action",
                  "control_phone", "approved_by"}
# Columns that must never appear in REVIEWER tool output.
HIDDEN_FROM_REVIEWER = {"one_time_code"}


# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools - NOT MCP tools. Each A2A agent in AssetHealthAgents has exactly one tool whose flow runs
#   #act_postgresql_query  SELECT * FROM ref_<topic>(CAST(?lookup AS text))  ->  #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no staff, crew-member, reviewer, case, session, asset, work-order, alert or
# contact data) - asserted by test_rules.py. FAILURE_MODE rows are read from failure_modes and WHO_DECIDES from
# case_routing (one source of truth). classify_asset(), safety_keyword() and the HSE case trigger stay in SQL.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a safety word, a failure mode, "
                 "a field term, a match level, a status code or a section name), or an empty string for the whole "
                 "guide. Never put names, staff ids, asset ids, work orders or case ids here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "field_note_triage_agent", "tool": "get_field_note_guide", "fn": "ref_field_note_guide",
     "table": "field_note_guide",
     "sections": ["SAFETY_SIGN", "NOT_SAFETY", "CREW_CHECK", "FAILURE_MODE", "SHORTHAND", "WHO_DECIDES", "RULE"],
     "desc": ("Reads Mesa Ridge Energy's field-note guide from the database: the signs of safety language (literal "
              "words and common paraphrases), words that are not safety language by themselves, the standard crew "
              "check for each failure mode and for safety language, what each failure-mode code means per asset type, "
              "field shorthand for rod pumps, ESPs, compressors and wellhead valves, who decides a safety signal and "
              "the triage rules. Rows of section, term, meaning. Read-only reference data with no asset, work-order "
              "or personal data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_field_note_guide(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "similar_failure_agent", "tool": "get_failure_matching_guide", "fn": "ref_failure_matching",
     "table": "failure_match_guide",
     "sections": ["MATCH_LEVEL", "EXAMPLE", "TERM", "RULE"],
     "desc": ("Reads Mesa Ridge Energy's failure-matching guide from the database: the match levels STRONG, MODERATE, "
              "WEAK and NO_MATCH with their standard notes, worked examples, a glossary of oilfield failure terms and "
              "the ranking and copying rules. Rows of section, term, meaning. Read-only reference data with no asset, "
              "work-order or personal data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_failure_matching(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "shift_handover_agent", "tool": "get_handover_format_guide", "fn": "ref_handover_guide",
     "table": "handover_guide",
     "sections": ["SECTION", "STATUS", "STANDARD_LINE", "RULE"],
     "desc": ("Reads Mesa Ridge Energy's control-room shift-handover guide from the database: the handover sections in "
              "order and what each says, every status code in plain words, the standard handover lines (including the "
              "closing line) and the length and wording rules. Rows of section, term, meaning. Read-only reference "
              "data with no asset, work-order or personal data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_handover_guide(CAST(?lookup AS text));", [("lookup", "term")])},
]
