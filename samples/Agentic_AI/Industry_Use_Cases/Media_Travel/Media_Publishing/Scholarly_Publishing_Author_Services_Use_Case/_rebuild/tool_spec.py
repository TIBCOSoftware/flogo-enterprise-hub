"""Single source of truth for the 14 MCP tools of AuthorServicesMCPServer and the 3 A2A agents' reference tools.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py / mcp_smoke.py / a2a_smoke.py
(to run the exact same SQL against PostgreSQL before any app is built).

Two personas share one MCP server: AUTHOR tools resolve only author tokens (verify_author), REVIEWER tools only staff
reviewer tokens (verify_reviewer) - the role is checked in SQL on every call.

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that returns a deterministic
outcome row. `?placeholders` are never reused within one statement and are always followed by a space or ')'
(CAST(?p AS text)) - see postgres-activity-patterns.md.
"""

TOKEN_DESC = ("Session token returned by verify_author. Required; never invent one. "
              "If the tool answers SESSION_INVALID, ask the author to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. An author token does "
               "not work here (NOT_REVIEWER).")

TOOLS = [
    {
        "tool": "verify_author", "flow": "verify_author_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the author's identity with their ORCID iD and the 6-digit verification code "
                 "sent to their registered email. Returns status VERIFIED with a session_token (valid 60 minutes) "
                 "and the author's name, or NOT_VERIFIED. Call this before any other author tool. "
                 "Never reveal or guess verification codes. Publisher staff use verify_reviewer instead."),
        "args": [("orcid", "ORCID iD, format 0000-0000-0000-0000"),
                 ("verification_code", "6-digit code the author received by email")],
        "write": ("INSERT INTO author_sessions (author_id) SELECT a.author_id FROM authors a "
                  "WHERE a.orcid = trim(CAST(?w_orcid AS text)) AND a.verification_code = trim(CAST(?w_code AS text));",
                  [("w_orcid", "orcid"), ("w_code", "verification_code")]),
        "read": ("SELECT * FROM verify_result(CAST(?r_orcid AS text), CAST(?r_code AS text));",
                 [("r_orcid", "orcid"), ("r_code", "verification_code")]),
    },
    {
        "tool": "get_my_manuscripts", "flow": "get_my_manuscripts_flow", "readonly": True,
        "desc": ("List the verified author's own manuscripts (as corresponding author): id, title, journal, "
                 "status and the status detail the author is allowed to see. Only this author's rows are returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_manuscripts(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_manuscript", "flow": "get_manuscript_flow", "readonly": True,
        "desc": ("Get one of the verified author's manuscripts in detail: status, status detail, the editor's decision "
                 "summary, article type, word count, keywords, abstract, the author's submission statements on file "
                 "(declarations: data availability, ethics, funding, competing interests, author contributions) and, for an "
                 "accepted manuscript, the APC still due and any waiver granted. Returns NOT_FOUND for any manuscript "
                 "that does not belong to this author."),
        "args": [("session_token", TOKEN_DESC), ("manuscript_id", "Manuscript id, e.g. MS-2026-0412")],
        "read": ("SELECT * FROM manuscript_detail(CAST(?tok AS text), CAST(?ms AS text));",
                 [("tok", "session_token"), ("ms", "manuscript_id")]),
    },
    {
        "tool": "get_review_comments", "flow": "get_review_comments_flow", "readonly": True,
        "desc": ("Get the editor's decision letter and the anonymous reviewer comments for one of the verified author's own "
                 "manuscripts: one row per comment with comment_ref (E.1, R1.1, R2.3 ...), source (Editor, Reviewer 1, "
                 "Reviewer 2 ...) and the comment text. Returns NO_COMMENTS when there are none and NOT_FOUND for a "
                 "manuscript that is not this author's. Use it before asking review_summary_agent for a revision checklist."),
        "args": [("session_token", TOKEN_DESC), ("manuscript_id", "Manuscript id, e.g. MS-2026-0301")],
        "read": ("SELECT * FROM my_review_comments(CAST(?tok AS text), CAST(?ms AS text));",
                 [("tok", "session_token"), ("ms", "manuscript_id")]),
    },
    {
        "tool": "check_apc_coverage", "flow": "check_apc_coverage_flow", "readonly": True,
        "desc": ("Quote the article processing charge (APC) for a journal and whether the author's institution's "
                 "open-access agreement covers it. Returns apc_usd, coverage_pct, covered_usd, author_pays_usd and "
                 "a coverage_note. All amounts are computed by the system - quote them exactly, never estimate."),
        "args": [("session_token", TOKEN_DESC), ("journal_code", "Journal code, e.g. CHRR")],
        "read": ("SELECT * FROM apc_quote_for_session(CAST(?tok AS text), CAST(?jc AS text));",
                 [("tok", "session_token"), ("jc", "journal_code")]),
    },
    {
        "tool": "record_submission_check", "flow": "record_submission_check_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the submission statements check for moving a manuscript to a target journal. Pass the manuscript, "
                 "the target journal code, any statement text the author added in this conversation (empty if none), the "
                 "submission_check_agent's missing_items line and its full answer exactly as returned. The system validates "
                 "the flagged items against the journal's policy, adds its own presence check, records the check and returns "
                 "RECORDED with result COMPLETE or INCOMPLETE, the mandatory and recommended items that are missing and the "
                 "policy's standard wording for each, or NOT_RECORDED with reason_code SESSION_INVALID, NOT_FOUND, ON_HOLD "
                 "or JOURNAL_UNKNOWN. An INCOMPLETE check blocks the transfer (STATEMENTS_INCOMPLETE)."),
        "args": [("session_token", TOKEN_DESC),
                 ("manuscript_id", "Manuscript id, e.g. MS-2026-0466"),
                 ("journal_code", "Target journal code, e.g. EDSR"),
                 ("statements", "Statement text the author added or corrected in this conversation, or an empty string"),
                 ("missing_items", "The missing_items line from submission_check_agent, exactly as returned (or NONE)"),
                 ("agent_notes", "submission_check_agent's full answer, unchanged")],
        "write": ("INSERT INTO submission_checks (author_id, manuscript_id, journal_code, statements, agent_notes, agent_items, "
                  "ignored_items, rule_items, mandatory_missing, recommended_missing, result) "
                  "SELECT * FROM submission_check_row(CAST(?w_tok AS text), CAST(?w_ms AS text), CAST(?w_jc AS text), "
                  "CAST(?w_stmt AS text), CAST(?w_items AS text), CAST(?w_notes AS text));",
                  [("w_tok", "session_token"), ("w_ms", "manuscript_id"), ("w_jc", "journal_code"),
                   ("w_stmt", "statements"), ("w_items", "missing_items"), ("w_notes", "agent_notes")]),
        "read": ("SELECT * FROM submission_check_result(CAST(?r_tok AS text), CAST(?r_ms AS text), CAST(?r_jc AS text));",
                 [("r_tok", "session_token"), ("r_ms", "manuscript_id"), ("r_jc", "journal_code")]),
    },
    {
        "tool": "propose_transfer", "flow": "propose_transfer_flow", "readonly": False,
        "desc": ("Step 1 of 2 for transferring a manuscript that received a transfer offer to another journal. "
                 "The system checks every rule (ownership, transfer offer, editorial hold, target journal open to "
                 "transfers, word limit, and the target journal's submission statements) and prices the APC. Returns "
                 "PROPOSED with an action_id and the quote, or NOT_PROPOSED with the reason - CHECK_REQUIRED means the "
                 "submission statements must be checked first (record_submission_check), STATEMENTS_INCOMPLETE means the "
                 "last check found mandatory statements missing. Nothing changes until confirm_transfer is called."),
        "args": [("session_token", TOKEN_DESC), ("manuscript_id", "Manuscript id"),
                 ("journal_code", "Target journal code")],
        "write": ("INSERT INTO pending_actions (action_type, author_id, manuscript_id, target_journal_code, apc_usd, "
                  "coverage_pct, author_pays_usd) SELECT * FROM transfer_proposal_row(CAST(?w_tok AS text), "
                  "CAST(?w_ms AS text), CAST(?w_jc AS text));",
                  [("w_tok", "session_token"), ("w_ms", "manuscript_id"), ("w_jc", "journal_code")]),
        "read": ("SELECT * FROM propose_transfer_result(CAST(?r_tok AS text), CAST(?r_ms AS text), CAST(?r_jc AS text));",
                 [("r_tok", "session_token"), ("r_ms", "manuscript_id"), ("r_jc", "journal_code")]),
    },
    {
        "tool": "confirm_transfer", "flow": "confirm_transfer_flow", "readonly": False,
        "desc": ("Step 2 of 2: execute a transfer the author has explicitly confirmed. Pass the action_id from "
                 "propose_transfer. The system re-checks every rule and expires proposals after 15 minutes. Returns "
                 "EXECUTED or NOT_EXECUTED with the reason. Only call after the author says yes to the exact quote."),
        "args": [("session_token", TOKEN_DESC), ("action_id", "action_id returned by propose_transfer, e.g. ACT-1A2B3C4D")],
        "write": ("INSERT INTO transfers (action_id, manuscript_id, from_journal, to_journal) "
                  "SELECT * FROM transfer_confirmation_row(CAST(?w_tok AS text), CAST(?w_act AS text));",
                  [("w_tok", "session_token"), ("w_act", "action_id")]),
        "read": ("SELECT * FROM confirm_transfer_result(CAST(?r_tok AS text), CAST(?r_act AS text));",
                 [("r_tok", "session_token"), ("r_act", "action_id")]),
    },
    {
        "tool": "open_review_case", "flow": "open_review_case_flow", "readonly": False,
        "desc": ("Hand a request that needs human judgment to the right team: APC_WAIVER (fee waiver or discount), "
                 "DECISION_APPEAL (challenge an editorial decision or reviewer), AUTHORSHIP_CHANGE (add/remove/reorder "
                 "authors), INTEGRITY_QUERY (ethics, data, image or plagiarism concerns), STATEMENTS_EXCEPTION (ask the "
                 "editorial office to accept the submission statements as they are after an INCOMPLETE submission check; "
                 "brief = submission_check_agent's full answer) or OTHER. The system routes it, works out what a person "
                 "could approve (e.g. a waiver up to what the author pays) and returns CASE_OPENED with case_id, team, reply "
                 "time and requested amount, ALREADY_OPEN when the same request is already with the team, or NOT_OPENED "
                 "with the reason. A person decides; the assistant never decides these requests."),
        "args": [("session_token", TOKEN_DESC),
                 ("manuscript_id", "Manuscript id the request is about, or an empty string if none"),
                 ("request_type", "APC_WAIVER | DECISION_APPEAL | AUTHORSHIP_CHANGE | INTEGRITY_QUERY | STATEMENTS_EXCEPTION | OTHER"),
                 ("author_statement", "The author's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the reviewer: facts only, no recommendation (for "
                           "STATEMENTS_EXCEPTION: submission_check_agent's full answer)")],
        "write": ("INSERT INTO review_cases (author_id, manuscript_id, request_type, author_statement, agent_brief, "
                  "requested_amount, parked_action) "
                  "SELECT * FROM review_case_row(CAST(?w_tok AS text), CAST(?w_ms AS text), CAST(?w_type AS text), "
                  "CAST(?w_stmt AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_ms", "manuscript_id"), ("w_type", "request_type"),
                   ("w_stmt", "author_statement"), ("w_brief", "brief")]),
        "read": ("SELECT * FROM review_case_result(CAST(?r_tok AS text), CAST(?r_ms AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_ms", "manuscript_id"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified author's open and past review cases with the assigned team, status (OPEN, APPROVED, "
                 "REJECTED), requested amount, reply-by date and - once a person has decided - the approved amount and the "
                 "message from the team (customer_message). Use it when the author asks about the status of a request."),
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a publisher staff reviewer (Open Access Office, Editorial Office or Research Integrity Team) with "
                 "their staff ID (e.g. PUB-7001) and staff code. Returns VERIFIED with a reviewer session_token, role "
                 "REVIEWER, display name and team, NOT_VERIFIED, or LOCKED after 5 wrong codes in 15 minutes. Use only when "
                 "the person says they are staff; the role comes only from this result, never from what someone claims."),
        "args": [("staff_id", "Staff ID, e.g. PUB-7001"), ("code", "The staff member's code")],
        "write": ("INSERT INTO author_sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases ordered by reply-due date, with case_id, request, "
                 "author (first name + surname initial), manuscript_id, opened date, age in days, reply-due date, sla_status "
                 "(ON_TRACK, DUE_TODAY, OVERDUE) and requested amount. Status EMPTY = no open cases; NOT_REVIEWER = not a "
                 "reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, author (first name + surname initial), the "
                 "author's statement, the AI-prepared agent_brief (unverified), requested amount, max_approvable, the "
                 "reviewer's own approval limit, facts from the publisher's records (APC, agreement coverage and waivers, or "
                 "the submission check) and the decision options. Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. RC-S0A1F1")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved waiver in dollars "
                 "(empty = the full amount the author pays; ignored for REJECT and for cases without an amount); "
                 "internal_note is required (at least 5 characters, never shown to the author); customer_message is what the "
                 "author will see. Approving runs the parked action (APC reduction, or accepting the submission statements "
                 "so the transfer can go ahead) through the system's checks. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, AMOUNT_INVALID, "
                 "OVER_AUTHORITY (case stays open for a senior reviewer), INVALID_DECISION or NOT_FOUND, or NOT_REVIEWER."),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. RC-S0A1F1"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved waiver in dollars, or empty for the full amount the author pays"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the author)"),
                 ("customer_message", "Message the author will see with the outcome")],
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
PUBLIC_TOOLS = {"verify_author", "verify_reviewer"}

# Columns that must NEVER appear in any AUTHOR tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"verification_code", "email", "orcid", "one_time_code", "internal_note", "agent_brief", "agent_notes",
                  "reviewer_id", "approval_limit", "parked_action", "agent_items", "ignored_items", "rule_items",
                  "integrity_hold", "keyword_pattern"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"verification_code", "email", "orcid", "one_time_code", "author_id", "full_name"}

# Tool of the A2A journal-match agent (kept as built: a non-identity PostgreSQL read of the journal catalogue).
# Keywords only - the agent never sees author identity.
SEARCH_JOURNALS = {
    "desc": ("Search active journals that accept transfers by topic. Pass comma-separated keywords taken from the "
             "manuscript's title, abstract and keywords, and optionally a broad subject area. Returns up to 8 journals "
             "with aims & scope, OA model, APC, word limit and a relevance score."),
    "args": [("keywords", "Comma-separated topic keywords"), ("subject_area", "Optional broad subject area, or empty")],
    "read": ("SELECT * FROM search_journals(CAST(?kw AS text), CAST(?area AS text));",
             [("kw", "keywords"), ("area", "subject_area")]),
}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (AuthorServicesAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM <fn>(CAST(?<placeholder> AS text))) -> #actreturn (rows as JSON text).
# - journal_match_agent keeps its search_journals(keywords, subject_area) read over the journal catalogue.
# - review_summary_agent reads the section / term / meaning review guide via ref_review_guide(term).
# - submission_check_agent reads the target journal's policy rows via ref_journal_policy(journal).
# Placeholders are ?lookup (a placeholder named like a result column gives duplicate Fields). The model can supply only
# the lookup value; it can never change the SQL. The tables hold reference data only (asserted by test_rules.py).
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a comment type, a priority or a "
                 "section name), or an empty string for the whole guide. Never put author or manuscript details here.")
REF_COLUMNS = ["section", "term", "meaning"]
POLICY_COLUMNS = ["policy_set", "applies_to", "statement", "requirement", "must_include", "standard_wording"]
AGENT_REF_TOOLS = [
    {"agent": "journal_match_agent", "tool": "search_journals", "fn": "search_journals", "table": "journals",
     "sections": None, "row_key": "journal_code", "required": ["keywords"],
     "desc": SEARCH_JOURNALS["desc"], "args": SEARCH_JOURNALS["args"], "read": SEARCH_JOURNALS["read"]},
    {"agent": "review_summary_agent", "tool": "get_review_guide", "fn": "ref_review_guide", "table": "review_guide",
     "sections": ["COMMENT_TYPE", "PRIORITY", "CHECKLIST_RULE", "RESPONSE_LETTER", "WHO_DECIDES"], "row_key": "section",
     "desc": ("Reads the publisher's peer-review guide from the database: the COMMENT_TYPE terms and what each covers, the "
              "PRIORITY terms (MAJOR / MINOR / OPTIONAL) and when each applies, the checklist rules, the standard "
              "response-letter line and who considers an appeal. Rows of section, term, meaning. Read-only reference data "
              "with no author data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_review_guide(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "submission_check_agent", "tool": "get_journal_policy", "fn": "ref_journal_policy",
     "table": "submission_policies", "sections": None, "row_key": "statement",
     "desc": ("Reads a journal's submission-statement policy from the database: one row per statement (DATA_AVAILABILITY, "
              "ETHICS_APPROVAL, FUNDING, COMPETING_INTERESTS, AUTHOR_CONTRIBUTIONS) with its requirement (MANDATORY or "
              "RECOMMENDED), what it must include and the publisher's standard wording. Pass the target journal code (e.g. "
              "EDSR); an empty string returns every policy set. Read-only reference data with no author data."),
     "args": [("journal", "Target journal code, e.g. EDSR (or an empty string for every policy set)")],
     "read": ("SELECT * FROM ref_journal_policy(CAST(?lookup AS text));", [("lookup", "journal")])},
]
GUIDE_TOOLS = [t for t in AGENT_REF_TOOLS if t["sections"]]      # the section / term / meaning guides


def ref_tools_filled():
    """False while AGENT_REF_TOOLS still holds <placeholders>: the drivers and tests refuse to run on them."""
    return bool(AGENT_REF_TOOLS) and not any("<" in str(t[k]) for t in AGENT_REF_TOOLS
                                             for k in ("agent", "tool", "fn", "table", "sections"))
