"""Single source of truth for the 16 MCP tools of AutoInsuranceMCPServer (Copperleaf Auto Insurance, governed, RAG).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES, never UPDATE) then a READ that returns
a deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always written CAST(?p AS text) - see postgres-activity-patterns.md.

Two personas share one MCP server: CUSTOMER tools resolve only policyholder tokens (verify_policyholder), REVIEWER tools
only reviewer tokens (verify_reviewer). The email tool is special (email=True): SQL validates + builds the message, the
flow sends it (to the EMAIL_TO app property) only when send_status = SEND_OK. search_policy_wording is special
(rag=True): its READ returns the newest vector store id (latest_vector_store()) and the MCP builder transplants the
extensions/openAI vectorSearch activity after that query (top 5, rewriteQuery true).

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Customer session token returned by verify_policyholder. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the customer to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A customer token does "
               "not work here (NOT_REVIEWER).")
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."

TOOLS = [
    # ------------------------------------------------------------------ customer identity
    {
        "tool": "verify_policyholder", "flow": "verify_policyholder_flow", "readonly": False, "idempotent": False,
        "destructive": False,
        "desc": ("Verify a Copperleaf policyholder with their policy number (CAI-100101, cai100101, CAI 100101 or 100101 all "
                 "work) and the one-time code texted to them. Returns VERIFIED with a session_token (valid 60 minutes), "
                 "their first name, the verified policy number, product tier and today's date (YYYY-MM-DD), or "
                 "VERIFY_FAILED, or LOCKED after too many failed attempts. Call this before any customer tool. Never "
                 "reveal, guess or hint at codes. Staff use verify_reviewer instead." + VERBATIM),
        "args": [("policy_number", "The customer's Copperleaf policy number, e.g. CAI-100101"),
                 ("code", "The one-time code the customer received by text message")],
        "write": ("INSERT INTO sessions (role, policyholder_id, policy_number) "
                  "SELECT * FROM verify_policyholder_fn(CAST(?w_pol AS text), CAST(?w_code AS text));",
                  [("w_pol", "policy_number"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_policyholder_result(CAST(?r_pol AS text), CAST(?r_code AS text));",
                 [("r_pol", "policy_number"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ customer scoped reads
    {
        "tool": "get_my_policy", "flow": "get_my_policy_flow", "readonly": True,
        "desc": ("Get the verified customer's Copperleaf policies (the verified policy first, verified_policy = yes; older "
                 "policies such as a cancelled one follow): product tier (Full Coverage, Liability + Comprehensive, "
                 "Liability Only), policy_status (Active, Pending Renewal, Lapsed, Cancelled) with a status_note, "
                 "effective and renewal dates, annual premium, payment frequency and installment, claims-free years, "
                 "discount protection and a claims_free_discount explanation, and the insured vehicle (year, make, "
                 "model, body type, license plate, VIN, value, usage). Also returns today (YYYY-MM-DD) - use it to turn "
                 "'today' / 'yesterday' / 'last Tuesday' into a date."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_policy(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_coverages", "flow": "get_my_coverages_flow", "readonly": True,
        "desc": ("List the coverages on the verified policy: coverage name, included (yes/no - 'no' means it is not on "
                 "this policy), limit amount and basis, and deductible in USD. Collision pays collision damage; "
                 "Comprehensive pays theft, weather (flood, hail, wind), vandalism, animal strikes and glass when there "
                 "is no Full Glass coverage. These are the facts; for what the policy wording says (exclusions, "
                 "definitions, conditions) use search_policy_wording."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_coverages(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_claims", "flow": "get_my_claims_flow", "readonly": True,
        "desc": ("List the verified customer's claims on all their Copperleaf policies: claim_no (e.g. CLM-2026-0051), "
                 "policy, claim type, incident and filed dates, estimated amount, deductible, claim_status (Submitted, "
                 "Under review, Approved, Settled, Denied) with status_text, approved and paid amounts with the payment "
                 "reference, and the related review request (case_id, case_status and the customer_message once "
                 "decided)."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_claims(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_payments", "flow": "get_my_payments_flow", "readonly": True,
        "desc": ("List the verified customer's 12 most recent premium payments: policy, due date, amount in USD, "
                 "payment_status (Paid, Due, Failed, Scheduled), paid date, method and a note."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_payments(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified customer's requests that a person decides (claim reviews, settlement or fault "
                 "reviews, reinstatement, quotes, callbacks, complaints): case_id, request, what it is about, team, "
                 "case_status (OPEN, APPROVED, REJECTED), opened and reply-due dates, outcome amount, decided date and "
                 "the customer_message from the team once decided. Use it when the customer asks about the status of a "
                 "claim review or request."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "search_policy_wording", "flow": "search_policy_wording_flow", "readonly": True, "rag": True,
        "desc": ("Search Copperleaf's policy wording documents (Full Coverage wording, Liability & Comprehensive "
                 "wording, Endorsements & Add-ons, Claims Procedure Guide) for what the policy says: what is covered or "
                 "excluded, definitions, conditions, deductibles rules, the claims-free discount and how to make a "
                 "claim. Write a short natural-language query and include the customer's product tier in the query "
                 "(e.g. 'Full Coverage: is flood damage from driving into standing water covered?'). Returns the most "
                 "relevant passages with document names and scores. Use the passages to answer and name the document; "
                 "never invent wording, and never use it for the customer's own numbers or status (use the get_my_* "
                 "tools for facts)."),
        "args": [("query", "What to look up in the policy wording, including the product tier, e.g. "
                           "'Liability Only: does my policy cover damage to my own car?'")],
        "read": ("SELECT * FROM latest_vector_store();", []),
    },
]

TOOLS += [
    # ------------------------------------------------------------------ first notice of loss (two-step)
    {
        "tool": "propose_claim", "flow": "propose_claim_flow", "readonly": False, "idempotent": False, "destructive": False,
        "desc": ("Step 1 of the claim filing (first notice of loss) on the verified policy. Pass the structured fields from "
                 "the claim intake: claim_type (Collision, Glass, Theft, Weather, Vandalism or Animal), incident_date "
                 "(YYYY-MM-DD, today or yesterday), incident_time (HH:MM 24-hour, or empty if unknown), estimated_amount "
                 "in US dollars, the customer's own description and the repair shop (or empty). The system checks the "
                 "policy is in force, the type, the date is in the policy period, the coverage is on the policy, the "
                 "amount and duplicates, and returns PROPOSED with a proposal_id, the coverage that pays, the deductible, "
                 "the claims-free discount impact and a customer-safe summary (expires in 15 minutes), or BLOCKED with a "
                 "reason_code and reason_text. review_signals is INTERNAL: pass it only to the fraud_signal_agent, never "
                 "show or read it to the customer. Nothing is filed until confirm_claim is called after the customer "
                 "explicitly says yes to this summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("claim_type", "Collision | Glass | Theft | Weather | Vandalism | Animal"),
                 ("incident_date", "Date of the incident: YYYY-MM-DD, today or yesterday"),
                 ("incident_time", "Time of the incident, HH:MM 24-hour (e.g. 02:30), or empty if unknown"),
                 ("estimated_amount", "Estimated repair / loss amount in US dollars, e.g. 6600"),
                 ("description", "The customer's own words about what happened: facts only, no names or plates"),
                 ("repair_shop", "Repair shop the customer named, or empty")],
        "write": ("INSERT INTO pending_claims (policyholder_id, policy_number, target_key, claim_type, incident_date, "
                  "incident_hour, estimated_amount, description, repair_shop, outcome, reason_code, reason_text, "
                  "coverage_that_pays, deductible, coverage_limit, discount_impact, summary, signal_points, review_signals) "
                  "SELECT * FROM propose_claim_fn(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_date AS text), "
                  "CAST(?w_time AS text), CAST(?w_amt AS text), CAST(?w_desc AS text), CAST(?w_shop AS text));",
                  [("w_tok", "session_token"), ("w_type", "claim_type"), ("w_date", "incident_date"),
                   ("w_time", "incident_time"), ("w_amt", "estimated_amount"), ("w_desc", "description"),
                   ("w_shop", "repair_shop")]),
        "read": ("SELECT * FROM propose_claim_result(CAST(?r_tok AS text), CAST(?r_type AS text), CAST(?r_date AS text), "
                 "CAST(?r_time AS text), CAST(?r_amt AS text), CAST(?r_desc AS text), CAST(?r_shop AS text));",
                 [("r_tok", "session_token"), ("r_type", "claim_type"), ("r_date", "incident_date"),
                  ("r_time", "incident_time"), ("r_amt", "estimated_amount"), ("r_desc", "description"),
                  ("r_shop", "repair_shop")]),
    },
    {
        "tool": "record_claim_assessment", "flow": "record_claim_assessment_flow", "readonly": False, "idempotent": False,
        "destructive": False,
        "desc": ("Step 2 of the claim filing: save the AI assessments for a PROPOSED claim. Pass the proposal_id from "
                 "propose_claim and the coverage_interpreter_agent and fraud_signal_agent outputs UNCHANGED: "
                 "coverage_finding (COVERED, EXCLUDED or UNCLEAR) and coverage_note (clause + document) from the coverage "
                 "agent; narrative_risk_score (0-100) and risk_indicators from the claim-signal agent. The system "
                 "combines them with its own checks when the claim is confirmed; nothing is decided or filed here. "
                 "Returns RECORDED (with the next step) or NOT_FOUND / EXPIRED / ALREADY_DONE. Never tell the customer "
                 "about scores or indicators." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("proposal_id", "proposal_id from propose_claim, e.g. CAI-PRP-1A2B3C4D"),
                 ("coverage_finding", "coverage_interpreter_agent coverage_finding: COVERED | EXCLUDED | UNCLEAR"),
                 ("coverage_note", "coverage_interpreter_agent clause and rationale, unchanged"),
                 ("narrative_risk_score", "fraud_signal_agent narrative_risk_score, an integer 0-100, unchanged"),
                 ("risk_indicators", "fraud_signal_agent indicators, unchanged (semicolon-separated)")],
        "write": ("INSERT INTO claim_assessments (proposal_id, policyholder_id, coverage_finding, coverage_note, "
                  "narrative_score, risk_indicators) "
                  "SELECT * FROM record_assessment_row(CAST(?w_tok AS text), CAST(?w_pid AS text), CAST(?w_find AS text), "
                  "CAST(?w_note AS text), CAST(?w_score AS text), CAST(?w_ind AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id"), ("w_find", "coverage_finding"),
                   ("w_note", "coverage_note"), ("w_score", "narrative_risk_score"), ("w_ind", "risk_indicators")]),
        "read": ("SELECT * FROM record_assessment_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    {
        "tool": "confirm_claim", "flow": "confirm_claim_flow", "readonly": False, "idempotent": False, "destructive": False,
        "desc": ("Step 3: file a claim the customer has explicitly confirmed. Pass the proposal_id from propose_claim. The "
                 "system re-checks every rule, files the claim with a claim number (e.g. CLM-2026-0101) and decides the "
                 "handling: STANDARD (an adjuster contacts the customer within 2 business days) or REVIEW (a claims "
                 "specialist reviews it under a case reference and replies within the stated business days). Returns "
                 "FILED with claim_no, claim_status, case_id, reply_text, deductible and discount_impact, or NOT_FOUND / "
                 "ALREADY_DONE / EXPIRED (after 15 minutes) / BLOCKED with the reason. Read reply_text to the customer; "
                 "never promise payment. Only call after the customer says yes to the exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from propose_claim, e.g. CAI-PRP-1A2B3C4D")],
        "write": ("INSERT INTO claims (claim_no, policy_number, policyholder_id, claim_type, incident_date, incident_hour, "
                  "description, repair_shop, estimated_amount, coverage_that_pays, deductible, coverage_limit, status, "
                  "filed_date, source, proposal_id, coverage_finding, coverage_note, signal_points, review_signals, "
                  "narrative_score, risk_indicators, risk_score, risk_band, route, payment_hold) "
                  "SELECT * FROM confirm_claim_row(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_claim_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ human-owned requests, email
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "destructive": False,
        "desc": ("Hand a request that needs a person to the right team. request_type is settlement_dispute or "
                 "liability_dispute (reference_id = the customer's claim number), reinstatement (lapsed policy), "
                 "quote_or_plan_change (quotes, adding or changing coverage), callback or complaint (reference_id = a "
                 "claim or policy number if relevant, else empty). summary is a neutral 1-3 sentence summary in the "
                 "customer's words. New claims are never opened here (use propose_claim). The system routes it and "
                 "returns OPENED with case_id, team and reply time, EXISTING, NOT_FOUND or INVALID_TYPE with a reason. "
                 "Never decide, promise or predict the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "settlement_dispute | liability_dispute | reinstatement | quote_or_plan_change | callback | complaint"),
                 ("summary", "Neutral summary of the request in the customer's words: facts only"),
                 ("reference_id", "Claim number (e.g. CLM-2026-0052) or policy number the request is about, or empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, policyholder_id, request_type, team, summary, reference_id, "
                  "requested_amount, parked_action, agent_brief, sla_due_at) "
                  "SELECT * FROM open_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_sum AS text), "
                  "CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_sum", "summary"), ("w_ref", "reference_id")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "email_confirmation", "flow": "email_confirmation_flow", "readonly": False, "idempotent": False,
        "destructive": False, "email": True,
        "desc": ("Email the customer a confirmation of something already done on their account: a claim they filed in "
                 "chat (CLM-... from confirm_claim) or a decided request (CAI-CASE-...). The system prepares the email "
                 "only when that reference belongs to this customer (send_status SEND_OK); otherwise NOT_SENT with "
                 "reason_code NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("reference", "CLM-... claim number or CAI-CASE-... case id")],
        "write": ("INSERT INTO email_log (policyholder_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "destructive": False,
        "desc": ("Verify a Copperleaf staff reviewer (claims adjuster or investigator) with their staff ID (e.g. CAS-3011) "
                 "and staff one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display name "
                 "and team, or VERIFY_FAILED / LOCKED. Use only when the person says they are staff; the role comes only "
                 "from this result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Copperleaf staff ID, e.g. CAS-3011"), ("code", "The staff member's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "customer (first name + last initial), claim number, opened date, age in days, reply-due date, "
                 "sla_status (ON_TRACK, DUE_TODAY, OVERDUE), requested amount and eligible maximum. Status EMPTY = no "
                 "open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, customer (first name + last initial, "
                 "city/state), the claim facts from Copperleaf's records (claim number, type, incident date and hour, "
                 "product tier, estimate, deductible, coverage limit, eligible maximum, prior claims in 24 months, policy "
                 "age at the incident, repair shop), the customer's statement, the AI-prepared agent_brief (unverified: "
                 "coverage finding, indicators, claim signals and band), the reviewer's own approval limit and the "
                 "decision options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. CAI-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "destructive": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved claim payment in "
                 "dollars (APPROVE on a claim case; empty = the full eligible amount; ignored for REJECT); internal_note "
                 "is required (at least 5 characters, never shown to the customer); customer_message is what the "
                 "customer will see. Approving a claim case posts the claim payment through the system's checks (and "
                 "releases any payment hold); rejecting denies the claim. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_FOUND, NOT_YOUR_TEAM, ALREADY_DECIDED, "
                 "INVALID_DECISION, NOTE_REQUIRED, AMOUNT_INVALID or OVER_AUTHORITY (case stays open for a senior "
                 "reviewer), or NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. CAI-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved amount in dollars, or empty"),
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

REVIEWER_TOOLS = {"verify_reviewer", "get_review_queue", "get_review_case", "decide_review_case"}
CUSTOMER_TOOLS = {t["tool"] for t in TOOLS} - REVIEWER_TOOLS

# Columns that must NEVER appear in any CUSTOMER tool output (SPEC 2b; asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"email", "date_of_birth", "one_time_code", "internal_note", "agent_brief", "reviewer_id",
                  "approval_limit", "parked_action", "signal_points", "narrative_score", "risk_score", "risk_band",
                  "risk_indicators", "payment_hold"}
# Strings that must never appear in any CUSTOMER tool output value (case-insensitive).
FORBIDDEN_CUSTOMER_STRINGS = ["fraud", "siu", "special investigations", "investigat"]
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"email", "date_of_birth", "one_time_code", "last_name", "phone", "street_address",
                        "policyholder_id"}


# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools - NOT MCP tools. Each A2A agent in AutoInsuranceAgents has exactly one tool whose flow runs
#   #act_postgresql_query  SELECT * FROM ref_<topic>(CAST(?lookup AS text))  ->  #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no policyholder, staff, vehicle, policy, claim, case, session or contact data) -
# asserted by test_rules.py. WHO_DECIDES rows are read from case_routing (one source of truth). The full policy wording
# stays in RAG (MCP search_policy_wording); the clause index only points into it. Signal points and bands stay in SQL.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a claim type, a coverage, an "
                 "exclusion, an indicator or a section name), or an empty string for the whole guide. Never put "
                 "policyholder details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "fnol_intake_agent", "tool": "get_fnol_checklist", "fn": "ref_fnol_checklist",
     "table": "fnol_intake_guide",
     "sections": ["CLAIM_TYPE", "FNOL_FIELD", "TYPE_DETAIL", "WHO_DECIDES", "RULE"],
     "desc": ("Reads Copperleaf Auto Insurance's first-notice-of-loss (FNOL) checklist from the database: the US claim "
              "types (Collision, Glass, Theft, Weather, Vandalism, Animal, Unclear), the FNOL fields and how to fill "
              "them, the extra details for each claim type and who decides a claim. Rows of section, term, meaning. "
              "Read-only reference data with no policyholder data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_fnol_checklist(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "coverage_interpreter_agent", "tool": "get_coverage_clause_index", "fn": "ref_coverage_clauses",
     "table": "coverage_clause_index",
     "sections": ["COVERAGE", "PRODUCT_TIER", "EXCLUSION", "TERM", "FINDING", "WHO_DECIDES"],
     "desc": ("Reads Copperleaf Auto Insurance's coverage clause index from the database: what each US auto coverage "
              "pays and where its clause is in the policy wording, the three product tiers, the exclusion categories "
              "with their clause pointers, key terms (deductible, actual cash value, policy territory), the meaning "
              "of COVERED / EXCLUDED / UNCLEAR and who decides. Rows of section, term, meaning. Read-only reference "
              "data with no policyholder data; the wording itself comes with your input. Pass term \"\" for the "
              "whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_coverage_clauses(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "fraud_signal_agent", "tool": "get_claim_indicator_guide", "fn": "ref_claim_indicators",
     "table": "claim_indicator_guide",
     "sections": ["INDICATOR", "SCORE_BAND", "SIGNAL", "RULE", "WHO_DECIDES"],
     "desc": ("Reads Copperleaf Auto Insurance's claim narrative indicator guide from the database: the named "
              "narrative indicators with a suggested weight, the narrative score bands, what each review_signals "
              "item means (context only), the scoring rules and who decides. Rows of section, term, meaning. "
              "Read-only reference data with no policyholder data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_claim_indicators(CAST(?lookup AS text));", [("lookup", "term")])},
]
