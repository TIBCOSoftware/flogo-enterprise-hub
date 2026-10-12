"""Single source of truth for the MCP tools and the journal-match agent's tool.

Imported by build_mcp.py / build_agents.py (to generate the apps) and by test_rules.py
(to run the exact same SQL against PostgreSQL before any app is built).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>) then a READ that
returns a deterministic outcome row. `?placeholders` are never reused within one statement
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.
"""

TOKEN_DESC = ("Session token returned by verify_author. Required; never invent one. "
              "If the tool answers SESSION_INVALID, ask the author to verify again.")

TOOLS = [
    {
        "tool": "verify_author", "flow": "verify_author_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify the author's identity with their ORCID iD and the 6-digit verification code "
                 "sent to their registered email. Returns status VERIFIED with a session_token (valid 60 minutes) "
                 "and the author's name, or NOT_VERIFIED. Call this before any other tool. "
                 "Never reveal or guess verification codes."),
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
                 "summary, article type, word count, keywords and abstract. Returns NOT_FOUND for any manuscript "
                 "that does not belong to this author."),
        "args": [("session_token", TOKEN_DESC), ("manuscript_id", "Manuscript id, e.g. MS-2026-0412")],
        "read": ("SELECT * FROM manuscript_detail(CAST(?tok AS text), CAST(?ms AS text));",
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
        "tool": "propose_transfer", "flow": "propose_transfer_flow", "readonly": False,
        "desc": ("Step 1 of 2 for transferring a manuscript that received a transfer offer to another journal. "
                 "The system checks every rule (ownership, transfer offer, editorial hold, target journal open to "
                 "transfers, word limit) and prices the APC. Returns PROPOSED with an action_id and the quote, or "
                 "NOT_PROPOSED with the reason. Nothing changes until confirm_transfer is called."),
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
                 "authors), INTEGRITY_QUERY (ethics, data, image or plagiarism concerns) or OTHER. The system routes it "
                 "and returns CASE_OPENED with case_id, team and reply time. The assistant never decides these requests."),
        "args": [("session_token", TOKEN_DESC),
                 ("manuscript_id", "Manuscript id the request is about, or an empty string if none"),
                 ("request_type", "APC_WAIVER | DECISION_APPEAL | AUTHORSHIP_CHANGE | INTEGRITY_QUERY | OTHER"),
                 ("author_statement", "The author's request in their own words"),
                 ("brief", "A neutral 2-4 sentence summary for the reviewer: facts only, no recommendation")],
        "write": ("INSERT INTO review_cases (author_id, manuscript_id, request_type, author_statement, agent_brief) "
                  "SELECT * FROM review_case_row(CAST(?w_tok AS text), CAST(?w_ms AS text), CAST(?w_type AS text), "
                  "CAST(?w_stmt AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_ms", "manuscript_id"), ("w_type", "request_type"),
                   ("w_stmt", "author_statement"), ("w_brief", "brief")]),
        "read": ("SELECT * FROM review_case_result(CAST(?r_tok AS text), CAST(?r_ms AS text), CAST(?r_type AS text));",
                 [("r_tok", "session_token"), ("r_ms", "manuscript_id"), ("r_type", "request_type")]),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": "List the verified author's open and past review cases with the assigned team and status.",
        "args": [("session_token", TOKEN_DESC)],
        "read": ("SELECT * FROM my_cases(CAST(?tok AS text));", [("tok", "session_token")]),
    },
]

# Tool of the A2A journal-match agent. Keywords only - the agent never sees author identity.
SEARCH_JOURNALS = {
    "desc": ("Search active journals that accept transfers by topic. Pass comma-separated keywords taken from the "
             "manuscript's title, abstract and keywords, and optionally a broad subject area. Returns up to 8 journals "
             "with aims & scope, OA model, APC, word limit and a relevance score."),
    "args": [("keywords", "Comma-separated topic keywords"), ("subject_area", "Optional broad subject area, or empty")],
    "read": ("SELECT * FROM search_journals(CAST(?kw AS text), CAST(?area AS text));",
             [("kw", "keywords"), ("area", "subject_area")]),
}
