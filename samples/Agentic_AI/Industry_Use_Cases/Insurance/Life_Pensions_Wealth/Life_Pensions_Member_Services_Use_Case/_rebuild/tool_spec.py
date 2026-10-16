"""Single source of truth for the 20 MCP tools of LifePensionsMCPServer (Harborline Life & Retirement, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

Two personas share one MCP server: MEMBER tools resolve only member tokens (verify_member), REVIEWER tools only
reviewer tokens (verify_reviewer). The email tool is special (email=True): SQL validates + builds the message, the flow
sends it (to the EMAIL_TO app property) only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Member session token returned by verify_member. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the member to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A member token does "
               "not work here (NOT_REVIEWER).")
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."

TOOLS = [
    # ------------------------------------------------------------------ member identity
    {
        "tool": "verify_member", "flow": "verify_member_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Harborline plan member with their member ID (HLR-100101, hlr100101 or 100101 all work) and the "
                 "one-time code texted to them. Returns VERIFIED with a session_token (valid 60 minutes) and their first "
                 "name, VERIFY_FAILED, or LOCKED after too many failed attempts. Call this before any member tool. Never "
                 "reveal, guess or hint at codes. Staff use verify_reviewer instead." + VERBATIM),
        "args": [("member_id", "The member's Harborline member ID, e.g. HLR-100101"),
                 ("code", "The one-time code the member received by text message")],
        "write": ("INSERT INTO sessions (role, member_id) "
                  "SELECT * FROM verify_member_fn(CAST(?w_mid AS text), CAST(?w_code AS text));",
                  [("w_mid", "member_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_member_result(CAST(?r_mid AS text), CAST(?r_code AS text));",
                 [("r_mid", "member_id"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ member scoped reads
    {
        "tool": "get_my_profile", "flow": "get_my_profile_flow", "readonly": True,
        "desc": ("Get the verified member's profile: member ID, name, marital status on file, state, employer, annual "
                 "salary (used for 401(k) contributions), member since, and how many policies and retirement accounts "
                 "they hold. Only this member's profile is returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_profile(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_policies", "flow": "get_my_policies_flow", "readonly": True,
        "desc": ("List the verified member's insurance policies: policy_id (e.g. POL-1003), product type (TermLife, "
                 "WholeLife, CriticalIllness, IncomeProtection), product name, policy_status (Active, Lapsed, Pending, "
                 "Cancelled) with a status_note, coverage amount (lump sum, or the monthly benefit for Income "
                 "Protection), monthly premium, waiting period, dates and number of beneficiaries."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_policies(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_beneficiaries", "flow": "get_my_beneficiaries_flow", "readonly": True,
        "desc": ("List the beneficiaries named on the verified member's policies: policy, beneficiary name, relationship "
                 "(Spouse, Child, Parent, Sibling, Trust, Other), share percent, Primary or Contingent, date added. "
                 "Changing a beneficiary needs a person (open_service_case beneficiary_change)."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_beneficiaries(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_retirement_accounts", "flow": "get_my_retirement_accounts_flow", "readonly": True,
        "desc": ("List the verified member's retirement accounts (401(k), Roth IRA, Traditional IRA): account_id, balance, "
                 "vested balance, 401(k) contribution rate, the employer match formula, match_gap_pct and "
                 "unclaimed_match_per_year (employer match the member is not receiving now), annual salary, the annual "
                 "deferral limit, plan maximum rate, the highest rate allowed for this member, year-to-date contributions, "
                 "the next payroll date and a match_text. All numbers are computed by the system - use them exactly."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_retirement_accounts(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_holdings", "flow": "get_my_holdings_flow", "readonly": True,
        "desc": ("List the funds held in each of the verified member's retirement accounts: account_id, fund_id (e.g. "
                 "FND-001), fund name, category, risk level (Low/Medium/High), units, price (NAV), value in USD and "
                 "allocation percent of that account. Use account_id and fund_id when proposing a fund switch."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_holdings(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_contributions", "flow": "get_my_contributions_flow", "readonly": True,
        "desc": ("List the verified member's 12 most recent contributions and premium payments: date, what it was paid "
                 "into, type (Employee, Employer, Premium, Rollover) and amount in USD."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_contributions(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_claims", "flow": "get_my_claims_flow", "readonly": True,
        "desc": ("List the verified member's protection claims: claim_id (e.g. CLM-2026-0004), policy, claim type, amount, "
                 "claim_status (Submitted, UnderReview, Approved, Paid, Denied), filed date, the recorded date the member "
                 "stopped work or was diagnosed, decision_text (including the denial reason), approved and paid amounts "
                 "with the payment reference, and any related case (an appeal) with its status."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_claims(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified member's service cases (requests a person decides): case_id, request, what it is about, "
                 "team, case_status (OPEN, APPROVED, REJECTED), opened and reply-due dates, requested and outcome amounts, "
                 "and the customer_message from the team once decided. Use it when the member asks about the status of a "
                 "request or appeal."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_fund_catalog", "flow": "get_fund_catalog_flow", "readonly": True,
        "desc": ("List the Harborline fund lineup for plan members: fund_id, name, category, risk level, YTD / 1-year / "
                 "3-year returns (%), expense ratio (%), price (NAV) and whether it is open to new money. Past performance "
                 "is not a guarantee; this is information, not advice."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM fund_catalog(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    # ------------------------------------------------------------------ two-step changes
    {
        "tool": "propose_contribution_change", "flow": "propose_contribution_change_flow", "readonly": False,
        "idempotent": False,
        "desc": ("Step 1 of 2 to change the verified member's 401(k) payroll contribution rate. Pass the new rate as a whole "
                 "percent of pay (e.g. 6). The system checks the plan maximum and the IRS annual limit and returns "
                 "PROPOSED with a proposal_id, a summary and the effective payroll date (expires in 15 minutes), or BLOCKED "
                 "with a reason_code and reason_text. Nothing changes until confirm_action is called after the member "
                 "explicitly says yes to this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("new_rate_pct", "New contribution rate, whole percent of pay, e.g. 6")],
        "write": ("INSERT INTO pending_actions (member_id, action_type, target_key, account_id, new_rate, outcome, reason_code, "
                  "reason_text, summary, effective_date) "
                  "SELECT * FROM propose_contribution_fn(CAST(?w_tok AS text), CAST(?w_rate AS text));",
                  [("w_tok", "session_token"), ("w_rate", "new_rate_pct")]),
        "read": ("SELECT * FROM propose_contribution_result(CAST(?r_tok AS text), CAST(?r_rate AS text));",
                 [("r_tok", "session_token"), ("r_rate", "new_rate_pct")]),
    },
    {
        "tool": "propose_fund_switch", "flow": "propose_fund_switch_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to move money between funds inside one of the verified member's retirement accounts. Pass the "
                 "account_id and from_fund_id from get_my_holdings, the to_fund_id from get_fund_catalog, and the amount in "
                 "US dollars (e.g. 20000) or ALL for the whole holding. The system checks the holding and the lineup and "
                 "returns PROPOSED with a proposal_id, summary and trade date (expires in 15 minutes), or BLOCKED with a "
                 "reason. Nothing moves until confirm_action is called after the member explicitly says yes." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("account_id", "Retirement account id from get_my_holdings, e.g. RET-5001"),
                 ("from_fund_id", "Fund to move out of, e.g. FND-001"),
                 ("to_fund_id", "Fund to move into, e.g. FND-005"),
                 ("amount", "Dollar amount to move, e.g. 20000, or ALL")],
        "write": ("INSERT INTO pending_actions (member_id, action_type, target_key, account_id, from_fund, to_fund, amount, "
                  "outcome, reason_code, reason_text, summary, effective_date) "
                  "SELECT * FROM propose_switch_fn(CAST(?w_tok AS text), CAST(?w_acct AS text), CAST(?w_from AS text), "
                  "CAST(?w_to AS text), CAST(?w_amt AS text));",
                  [("w_tok", "session_token"), ("w_acct", "account_id"), ("w_from", "from_fund_id"), ("w_to", "to_fund_id"),
                   ("w_amt", "amount")]),
        "read": ("SELECT * FROM propose_switch_result(CAST(?r_tok AS text), CAST(?r_acct AS text), CAST(?r_from AS text), "
                 "CAST(?r_to AS text), CAST(?r_amt AS text));",
                 [("r_tok", "session_token"), ("r_acct", "account_id"), ("r_from", "from_fund_id"), ("r_to", "to_fund_id"),
                  ("r_amt", "amount")]),
    },
    {
        "tool": "confirm_action", "flow": "confirm_action_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: execute a proposal the member has explicitly confirmed. Pass the proposal_id from "
                 "propose_contribution_change or propose_fund_switch. The system re-checks every rule and returns EXECUTED "
                 "with a reference (e.g. HLR-ACT-000101), or BLOCKED / EXPIRED (after 15 minutes) / NOT_FOUND / "
                 "ALREADY_DONE with the reason. Only call after the member says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from a propose tool, e.g. HLR-PRP-1A2B3C4D")],
        "write": ("INSERT INTO account_events (event_id, reference, proposal_id, member_id, action_type, account_id, new_rate, "
                  "from_fund, to_fund, amount, effective_date, summary) "
                  "SELECT * FROM confirm_action_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_action_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ claims, human-owned cases, email
    {
        "tool": "file_claim", "flow": "file_claim_flow", "readonly": False, "idempotent": False,
        "desc": ("File a Critical Illness or Income Protection claim on one of the verified member's policies. Pass the "
                 "policy_id from get_my_policies, the claim_type (CriticalIllness or IncomeProtection), the member's own "
                 "description of what happened, and the documents_needed list from the claim intake step (or empty). The "
                 "system checks that the policy is Active, that the claim type matches the policy and that no claim is "
                 "already open on it, then returns FILED with claim_id, the claim-decision case_id, team and reply time, or "
                 "BLOCKED with a reason. A claims examiner decides every claim - never promise or predict payment."
                 + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("policy_id", "Policy id from get_my_policies, e.g. POL-1019"),
                 ("claim_type", "CriticalIllness | IncomeProtection"),
                 ("description", "The member's own words about what happened: facts only"),
                 ("documents_needed", "Semicolon-separated documents from the claim intake step, or empty")],
        "write": ("INSERT INTO claims (claim_id, policy_id, member_id, claim_type, amount, status, filed_date, description, "
                  "documents_needed, source) "
                  "SELECT * FROM file_claim_row(CAST(?w_tok AS text), CAST(?w_pol AS text), CAST(?w_type AS text), "
                  "CAST(?w_desc AS text), CAST(?w_docs AS text));",
                  [("w_tok", "session_token"), ("w_pol", "policy_id"), ("w_type", "claim_type"), ("w_desc", "description"),
                   ("w_docs", "documents_needed")]),
        "read": ("SELECT * FROM file_claim_result(CAST(?r_tok AS text), CAST(?r_pol AS text));",
                 [("r_tok", "session_token"), ("r_pol", "policy_id")]),
    },
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that needs a person to the right team. request_type is beneficiary_change (reference_id = "
                 "the policy_id, if known), claim_appeal (reference_id = the denied claim_id; agent_brief = the appeal "
                 "summary), withdrawal_rollover (reference_id = the account_id; amount = dollars or ALL), "
                 "investment_advice, or complaint. summary is a neutral 1-3 sentence summary in the member's own words. "
                 "Leave reference_id, amount and agent_brief empty when they do not apply. The system routes it and returns "
                 "OPENED with case_id, team and reply time, EXISTING, or BLOCKED / INVALID_TYPE with a reason. The assistant "
                 "never decides, promises or predicts the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "beneficiary_change | claim_appeal | withdrawal_rollover | investment_advice | complaint"),
                 ("summary", "Neutral summary of the request in the member's words: facts only"),
                 ("reference_id", "Policy, claim or account id the request is about, or empty"),
                 ("amount", "Withdrawal amount in dollars or ALL (withdrawal_rollover only), else empty"),
                 ("agent_brief", "The appeal summary for the examiner (claim_appeal only), else empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, member_id, request_type, summary, reference_id, "
                  "requested_amount, parked_action, agent_brief, sla_due_at) "
                  "SELECT * FROM open_case_row(CAST(?w_tok AS text), CAST(?w_type AS text), CAST(?w_sum AS text), "
                  "CAST(?w_ref AS text), CAST(?w_amt AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_type", "request_type"), ("w_sum", "summary"), ("w_ref", "reference_id"),
                   ("w_amt", "amount"), ("w_brief", "agent_brief")]),
        "read": ("SELECT * FROM open_case_result(CAST(?r_tok AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_type", "request_type")]),
    },
    {
        "tool": "email_confirmation", "flow": "email_confirmation_flow", "readonly": False, "idempotent": False,
        "email": True,
        "desc": ("Email the member a confirmation of something already done on their account: a completed change "
                 "(HLR-ACT-... reference from confirm_action), a claim they filed in chat (CLM-...), or a decided case "
                 "(HLR-CASE-...). The system prepares the email only when that reference belongs to this member and is "
                 "done (send_status SEND_OK); otherwise NOT_SENT with reason_code NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("reference", "HLR-ACT-..., CLM-... or HLR-CASE-... reference")],
        "write": ("INSERT INTO email_log (member_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Harborline staff reviewer (claims examiner or Policy & Retirement Services) with their staff ID "
                 "(e.g. HLS-2041) and staff one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, "
                 "display name and team, or VERIFY_FAILED / LOCKED. Use only when the person says they are staff; the role "
                 "comes only from this result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Harborline staff ID, e.g. HLS-2041"), ("code", "The staff member's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "member (first name + last initial), opened date, age in days, reply-due date, sla_status (ON_TRACK, "
                 "DUE_TODAY, OVERDUE) and requested amount. Status EMPTY = no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, member (first name + last initial), the "
                 "member's statement, the AI-prepared agent_brief (unverified), requested amount, max_approvable, the "
                 "reviewer's own approval limit, facts from Harborline's records and the decision options. Another team's "
                 "case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. HLR-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved amount in dollars "
                 "(APPROVE on a case with an amount; empty = the full eligible amount; ignored for REJECT); internal_note is "
                 "required (at least 5 characters, never shown to the member); customer_message is what the member will "
                 "see. Approving runs the parked action (claim payment or withdrawal) through the system's checks. Returns "
                 "APPROVED / REJECTED with executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, "
                 "NOTE_REQUIRED, AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior reviewer) or NOT_FOUND, or "
                 "NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. HLR-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved amount in dollars, or empty"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the member)"),
                 ("customer_message", "Message the member will see with the outcome")],
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

# Columns that must NEVER appear in any MEMBER tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"ssn", "email", "date_of_birth", "otp_code", "one_time_code", "internal_note", "agent_brief",
                  "reviewer_id", "approval_limit", "parked_action"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"ssn", "email", "date_of_birth", "otp_code", "one_time_code", "last_name", "member_id"}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (LifePensionsAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM ref_<topic>(CAST(?lookup AS text))) -> #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no member, beneficiary, staff, policy, claim, case, session or contact data) -
# asserted by test_rules.py. WHO_DECIDES / WHO_HELPS rows are read from case_routing (one source of truth).
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a claim type, a life event, a "
                 "denial reason or a section name), or an empty string for the whole guide. Never put member details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "claim_intake_agent", "tool": "get_claim_document_checklist", "fn": "ref_claim_checklist",
     "table": "claim_intake_guide",
     "sections": ["CLAIM_TYPE", "PRODUCT", "DOCUMENT", "WAITING_PERIOD", "WHO_DECIDES", "RULE"],
     "desc": ("Reads Harborline Life & Retirement's claim intake guide from the database: the claim types "
              "(CriticalIllness, IncomeProtection, NotClaimableHere), which product each claim type belongs to, the "
              "documents needed for each, the Income Protection waiting period and who decides a claim. Rows of "
              "section, term, meaning. Read-only reference data with no member data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_claim_checklist(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "life_event_agent", "tool": "get_life_event_checklist", "fn": "ref_life_event",
     "table": "life_event_guide",
     "sections": ["LIFE_EVENT", "RELATIONSHIP", "DESIGNATION", "SPOUSAL_CONSENT", "WHO_HELPS", "RULE"],
     "desc": ("Reads Harborline Life & Retirement's life-event checklist from the database: what is typically reviewed "
              "after each life event, the beneficiary relationship values, primary vs contingent beneficiaries and "
              "shares, ERISA spousal consent for 401(k) beneficiaries, and which team helps with what. Rows of section, "
              "term, meaning. Read-only reference data with no member data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_life_event(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "appeal_summary_agent", "tool": "get_appeal_review_guide", "fn": "ref_appeal_guide",
     "table": "appeal_review_guide",
     "sections": ["DENIAL_REASON", "WAITING_PERIOD", "NEW_EVIDENCE", "FAIR_REVIEW", "WHO_DECIDES", "BRIEF_RULE"],
     "desc": ("Reads Harborline Life & Retirement's appeal review guide from the database: the claim denial reason "
              "codes in plain words, the waiting (elimination) period, what counts as new evidence, the "
              "full-and-fair-review principle, who reviews an appeal and the rules for a neutral brief. Rows of "
              "section, term, meaning. Read-only reference data with no member data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_appeal_guide(CAST(?lookup AS text));", [("lookup", "term")])},
]
