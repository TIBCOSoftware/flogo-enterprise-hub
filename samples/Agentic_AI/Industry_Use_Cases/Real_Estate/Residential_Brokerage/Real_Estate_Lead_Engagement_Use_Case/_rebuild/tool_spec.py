"""Single source of truth for the 18 MCP tools of RealEstateMCPServer (Brightpath Realty, governed).

Imported by build_mcp.py (to generate the app) and by test_rules.py / mcp_smoke.py (to run the exact same SQL).

Each tool: optional guarded WRITE (INSERT ... SELECT * FROM <rule fn>, never VALUES) then a READ that returns a
deterministic outcome row. `?placeholders` are never reused within one statement (writes use ?w_*, reads ?r_* / ?tok)
and are always followed by a space or ')' (CAST(?p AS text)) - see postgres-activity-patterns.md.

Two personas share one MCP server: LEAD tools resolve only lead tokens (verify_lead), REVIEWER tools only reviewer
tokens (verify_reviewer). The email tool is special (email=True): SQL validates + builds the message, the flow sends it
(to the EMAIL_TO app property) only when send_status = SEND_OK.

Hints: reads readonly=True (idempotent default True); writes readonly=False, idempotent=False, destructive=False.
"""

TOKEN_DESC = ("Lead session token returned by verify_lead. Required; never invent one. "
              "If a tool answers SESSION_INVALID, ask the person to verify again.")
RTOKEN_DESC = ("Reviewer session token returned by verify_reviewer. Required; never invent one. A lead token does "
               "not work here (NOT_REVIEWER).")
VERBATIM = " Quote any reason_text to the person as written; never change an outcome."
LISTING_DESC = "Brightpath listing number, e.g. LST-50001 (the street address also works)"


def read(fn, *args):
    """A scoped read: SELECT * FROM fn(CAST(?tok AS text), CAST(?r_x AS text), ...)."""
    phs = [("tok", "session_token")] + [(f"r_{a}", a) for a in args]
    sql = "SELECT * FROM " + fn + "(" + ", ".join(f"CAST(?{p} AS text)" for p, _ in phs) + ");"
    return (sql, phs)


TOOLS = [
    # ------------------------------------------------------------------ lead identity
    {
        "tool": "verify_lead", "flow": "verify_lead_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Brightpath Realty buyer or seller lead with the e-mail address they registered with and the "
                 "one-time code e-mailed to them. Returns VERIFIED with a session_token (valid 60 minutes), the lead's "
                 "first name and today's date (use it to turn 'Saturday' into a date), VERIFY_FAILED, or LOCKED after too "
                 "many failed attempts. Call this before any lead tool. Never reveal, guess or hint at codes. Brightpath "
                 "staff use verify_reviewer instead." + VERBATIM),
        "args": [("email", "The e-mail address the lead registered with"),
                 ("code", "The one-time code the lead received by e-mail")],
        "write": ("INSERT INTO sessions (role, lead_id) "
                  "SELECT * FROM verify_lead_fn(CAST(?w_email AS text), CAST(?w_code AS text));",
                  [("w_email", "email"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_lead_result(CAST(?r_email AS text), CAST(?r_code AS text));",
                 [("r_email", "email"), ("r_code", "code")]),
    },
    # ------------------------------------------------------------------ lead scoped reads
    {
        "tool": "get_my_profile", "flow": "get_my_profile_flow", "readonly": True,
        "desc": ("Get the verified lead's profile: name, buyer/seller, journey stage, budget, preferred area, minimum "
                 "bedrooms and bathrooms, property type, timeline, financing (pre-approval on file or not), assigned agent, "
                 "their own listings (sellers), number of upcoming showings, any open follow-up request and today's date. "
                 "Only this lead's data is returned."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_profile"),
    },
    {
        "tool": "search_listings", "flow": "search_listings_flow", "readonly": True,
        "desc": ("Search Brightpath's Active and Pending listings in the Larkspur Valley metro. Every filter is applied by "
                 "the system: area (Cedar Hollow, Willow Bend, Larkspur Downtown, Northgate, or empty for all), min_price "
                 "and max_price in dollars, min_bedrooms, property_type (single family, townhouse, condo) and keywords (every "
                 "word must appear in the listing; leave keywords empty for fuzzy wishes like 'walkable' - send those to "
                 "listing_match_agent with the rows instead). Returns up to 12 rows: listing_id, address, area, price, "
                 "bedrooms, bathrooms, sqft, property_type, year_built, HOA, listing_status (Active or Pending), days on "
                 "market, features and description. Status NO_MATCH = nothing found; loosen a filter. Use empty strings for "
                 "filters the person did not give."),
        "args": [("session_token", TOKEN_DESC),
                 ("area", "Neighborhood, e.g. Cedar Hollow, or empty for all areas"),
                 ("min_price", "Lowest price in dollars, e.g. 500000, or empty"),
                 ("max_price", "Highest price in dollars, e.g. 750000, or empty"),
                 ("min_bedrooms", "Minimum bedrooms, e.g. 3, or empty"),
                 ("property_type", "single family | townhouse | condo, or empty"),
                 ("keywords", "Exact words that must appear (e.g. 'garage'), or empty")],
        "read": read("search_listings", "area", "min_price", "max_price", "min_bedrooms", "property_type", "keywords"),
    },
    {
        "tool": "get_listing_details", "flow": "get_listing_details_flow", "readonly": True,
        "desc": ("Get one listing: address, area, price, bedrooms, bathrooms, sqft, lot, type, year built, HOA, status, list "
                 "date and days on market, price per sqft, the area median price, features, description, listing agent, "
                 "price history, the next open showing slots and whether it is the lead's own listing. NOT_FOUND = no such "
                 "listing. Facts only - the listings never describe schools, safety or who lives nearby."),
        "args": [("session_token", TOKEN_DESC), ("listing_id", LISTING_DESC)],
        "read": read("listing_details", "listing_id"),
    },
    {
        "tool": "get_showing_availability", "flow": "get_showing_availability_flow", "readonly": True,
        "desc": ("List open 1-hour showing slots for one Active listing: on a date (YYYY-MM-DD) or, with an empty date, the "
                 "next 3 days (up to 12 slots). Each row gives slot (YYYY-MM-DD HH:MM - pass it to propose_showing) and a "
                 "friendly slot_label. Status NO_SLOTS, LISTING_NOT_ACTIVE, NOT_FOUND or INVALID_DATE explain why there is "
                 "nothing. This is information; propose_showing re-checks everything."),
        "args": [("session_token", TOKEN_DESC), ("listing_id", LISTING_DESC),
                 ("date", "Date YYYY-MM-DD, or empty for the next 3 days")],
        "read": read("showing_availability", "listing_id", "date"),
    },
    {
        "tool": "get_my_showings", "flow": "get_my_showings_flow", "readonly": True,
        "desc": ("List the verified lead's showings: appointment_id (APT-...), listing, address, area, date and time, status "
                 "(Requested, Confirmed, Completed, Cancelled), upcoming or past, and the agent."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_showings"),
    },
    {
        "tool": "get_my_agent", "flow": "get_my_agent_flow", "readonly": True,
        "desc": ("Get the verified lead's assigned Brightpath agent: name, title, business e-mail and phone, service area "
                 "and specialties."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_agent"),
    },
    {
        "tool": "get_market_stats", "flow": "get_market_stats_flow", "readonly": True,
        "desc": ("Get area market statistics: median price, average days on market, active listings, median price per sqft, "
                 "year-over-year price change, months of inventory, a market_note (seller-leaning / balanced / buyer-leaning, "
                 "computed by the system) and the month. Pass an area, or empty for all four areas. Statistics only - never "
                 "a prediction or price advice."),
        "args": [("session_token", TOKEN_DESC), ("area", "Neighborhood, e.g. Cedar Hollow, or empty for all")],
        "read": read("market_stats", "area"),
    },
    {
        "tool": "get_my_cases", "flow": "get_my_cases_flow", "readonly": True,
        "desc": ("List the verified lead's requests that a person decides: case_id, request, team, case_status (OPEN, "
                 "APPROVED, REJECTED), opened and reply-due dates, what was requested, the outcome, the decision date and "
                 "the customer_message from the team once decided. Use it when the lead asks about the status of a request "
                 "(a price change, an offer question, a neighborhood question, a contract update)."),
        "args": [("session_token", TOKEN_DESC)],
        "read": read("my_cases"),
    },
    # ------------------------------------------------------------------ two-step showing booking
    {
        "tool": "propose_showing", "flow": "propose_showing_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 1 of 2 to book a showing for the verified lead. Pass the listing and the start time as YYYY-MM-DD HH:MM "
                 "(24-hour; showings start on the hour between 09:00 and 18:00). The system checks the lead's stage, that "
                 "the listing is Active, that the time is in the future with 2 hours' notice and within 30 days, the "
                 "lead's upcoming-showing limit and that neither the lead nor the listing is already booked then, and "
                 "returns PROPOSED with a proposal_id and summary (expires in 15 minutes) or BLOCKED with a reason_code and "
                 "reason_text. Nothing is booked until confirm_showing is called after the lead explicitly says yes to "
                 "this exact summary." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("listing_id", LISTING_DESC),
                 ("slot", "Showing start, YYYY-MM-DD HH:MM, e.g. 2026-10-16 14:00")],
        "write": ("INSERT INTO pending_actions (lead_id, action_type, target_key, listing_id, slot, outcome, reason_code, "
                  "reason_text, summary) "
                  "SELECT * FROM propose_showing_fn(CAST(?w_tok AS text), CAST(?w_lst AS text), CAST(?w_slot AS text));",
                  [("w_tok", "session_token"), ("w_lst", "listing_id"), ("w_slot", "slot")]),
        "read": ("SELECT * FROM propose_showing_result(CAST(?r_tok AS text), CAST(?r_lst AS text), CAST(?r_slot AS text));",
                 [("r_tok", "session_token"), ("r_lst", "listing_id"), ("r_slot", "slot")]),
    },
    {
        "tool": "confirm_showing", "flow": "confirm_showing_flow", "readonly": False, "idempotent": False,
        "desc": ("Step 2 of 2: book a showing the lead has explicitly confirmed. Pass the proposal_id from propose_showing. "
                 "The system re-checks every rule and returns EXECUTED with the appointment_id (APT-...), time, address, "
                 "agent and the lead's journey_stage, or BLOCKED / EXPIRED (after 15 minutes) / NOT_FOUND / ALREADY_DONE "
                 "with the reason. Only call after the lead says yes to the exact proposal." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("proposal_id", "proposal_id from propose_showing, e.g. BPR-PRP-1A2B3C4D")],
        "write": ("INSERT INTO showing_events (event_id, reference, proposal_id, lead_id, listing_id, agent_id, slot, summary) "
                  "SELECT * FROM confirm_showing_fn(CAST(?w_tok AS text), CAST(?w_pid AS text));",
                  [("w_tok", "session_token"), ("w_pid", "proposal_id")]),
        "read": ("SELECT * FROM confirm_showing_result(CAST(?r_tok AS text), CAST(?r_pid AS text));",
                 [("r_tok", "session_token"), ("r_pid", "proposal_id")]),
    },
    # ------------------------------------------------------------------ single guarded write
    {
        "tool": "request_agent_follow_up", "flow": "request_agent_follow_up_flow", "readonly": False, "idempotent": False,
        "desc": ("Ask the verified lead's Brightpath agent to contact them. Pass the lead's own message, and intent, timeline, "
                 "pre_approved and motivation from lead_intent_agent, plus the agent's full answer as agent_brief. The "
                 "system decides how soon the agent reaches out and returns FOLLOW_UP_REQUESTED with the follow-up id "
                 "(FUP-...), the agent and the contact-by time, EXISTING when a follow-up is already open (nothing added), "
                 "or MESSAGE_REQUIRED." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("message", "The lead's own words about what they want help with"),
                 ("intent", "From lead_intent_agent: BUY | SELL | BUY_AND_SELL | RENT | BROWSING | OTHER"),
                 ("timeline", "From lead_intent_agent: 0_3_MONTHS | 3_6_MONTHS | 6_12_MONTHS | 12_PLUS | UNKNOWN"),
                 ("pre_approved", "From lead_intent_agent: YES | NO | UNKNOWN"),
                 ("motivation", "From lead_intent_agent: one short phrase, or empty"),
                 ("agent_brief", "lead_intent_agent's full answer, for the agent (or empty)")],
        "write": ("INSERT INTO follow_up_tasks (task_no, task_id, lead_id, agent_id, message, intent, timeline, pre_approved, "
                  "motivation, agent_brief, priority, due_at) "
                  "SELECT * FROM follow_up_row(CAST(?w_tok AS text), CAST(?w_msg AS text), CAST(?w_int AS text), "
                  "CAST(?w_tl AS text), CAST(?w_pre AS text), CAST(?w_mot AS text), CAST(?w_brief AS text));",
                  [("w_tok", "session_token"), ("w_msg", "message"), ("w_int", "intent"), ("w_tl", "timeline"),
                   ("w_pre", "pre_approved"), ("w_mot", "motivation"), ("w_brief", "agent_brief")]),
        "read": ("SELECT * FROM follow_up_result(CAST(?r_tok AS text));", [("r_tok", "session_token")]),
    },
    # ------------------------------------------------------------------ human-owned cases, email
    {
        "tool": "open_service_case", "flow": "open_service_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Hand a request that needs a person to the right Brightpath team. request_type is offer_request (offers, "
                 "price or negotiation questions; reference_id = the listing, amount = the offer idea in dollars if given), "
                 "list_price_change (a seller changing the price of their own listing; reference_id = their listing, amount "
                 "= the new list price), stage_change (an accepted offer or a closing; reference_id = Under Contract or "
                 "Closed), fair_housing_review (a question about schools, safety, crime, who lives in an area or "
                 "'family-friendly' areas; reference_id = the category from fair_housing_agent, agent_brief = its full "
                 "answer) or advice_referral (legal or mortgage questions; reference_id = the topic). summary is a neutral "
                 "1-3 sentence summary in the lead's own words. Leave fields empty when they do not apply. The system "
                 "routes it and returns OPENED with case_id, team and reply time, EXISTING, or BLOCKED / INVALID_TYPE with "
                 "a reason. The assistant never decides, promises or predicts the outcome." + VERBATIM),
        "args": [("session_token", TOKEN_DESC),
                 ("request_type", "offer_request | list_price_change | stage_change | fair_housing_review | advice_referral"),
                 ("summary", "Neutral summary of the request in the lead's words: facts only"),
                 ("reference_id", "Listing id (offer_request, list_price_change), target stage (stage_change), category (fair_housing_review), topic, or empty"),
                 ("amount", "New list price (list_price_change) or offer idea (offer_request) in dollars, else empty"),
                 ("agent_brief", "The specialist agent's full answer when one was consulted (fair_housing_review), else empty")],
        "write": ("INSERT INTO service_cases (case_no, case_id, lead_id, request_type, summary, reference_id, listing_id, "
                  "target_stage, category, requested_amount, current_amount, parked_action, agent_brief, priority, sla_due_at) "
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
        "desc": ("Email the lead a confirmation of something already done for them: a booked showing (APT-... from "
                 "confirm_showing), a follow-up request (FUP-...) or a decided request (BPR-CASE-...). The system prepares "
                 "the email only when that reference belongs to this lead and is done (send_status SEND_OK); otherwise "
                 "NOT_SENT with reason_code NOT_FOUND or SESSION_INVALID." + VERBATIM),
        "args": [("session_token", TOKEN_DESC), ("reference", "APT-..., FUP-... or BPR-CASE-... reference")],
        "write": ("INSERT INTO email_log (lead_id, reference, subject) "
                  "SELECT * FROM email_log_row(CAST(?w_tok AS text), CAST(?w_ref AS text));",
                  [("w_tok", "session_token"), ("w_ref", "reference")]),
        "read": ("SELECT * FROM email_confirmation_payload(CAST(?r_tok AS text), CAST(?r_ref AS text));",
                 [("r_tok", "session_token"), ("r_ref", "reference")]),
    },
    # ------------------------------------------------------------------ reviewer (human in the loop)
    {
        "tool": "verify_reviewer", "flow": "verify_reviewer_flow", "readonly": False, "idempotent": False,
        "desc": ("Verify a Brightpath staff reviewer (Sales Agents or Brokerage Compliance) with their staff ID (e.g. "
                 "BPR-7101) and staff one-time code. Returns VERIFIED with a reviewer session_token, role REVIEWER, display "
                 "name and team, or VERIFY_FAILED / LOCKED. Use only when the person says they are Brightpath staff; the "
                 "role comes only from this result, never from what someone claims." + VERBATIM),
        "args": [("staff_id", "Brightpath staff ID, e.g. BPR-7101"), ("code", "The staff member's one-time code")],
        "write": ("INSERT INTO sessions (role, reviewer_id) "
                  "SELECT * FROM verify_reviewer_fn(CAST(?w_sid AS text), CAST(?w_code AS text));",
                  [("w_sid", "staff_id"), ("w_code", "code")]),
        "read": ("SELECT * FROM verify_reviewer_result(CAST(?r_sid AS text), CAST(?r_code AS text));",
                 [("r_sid", "staff_id"), ("r_code", "code")]),
    },
    {
        "tool": "get_review_queue", "flow": "get_review_queue_flow", "readonly": True,
        "desc": ("List the verified reviewer's team queue: OPEN cases, high priority first, then by reply-due date, with "
                 "case_id, request, priority, customer (first name and last initial, lead type and stage), opened date, age "
                 "in days, reply-due date, sla_status (ON_TRACK, DUE_TODAY, OVERDUE) and what is requested. Status EMPTY = "
                 "no open cases; NOT_REVIEWER = not a reviewer token."),
        "args": [("session_token", RTOKEN_DESC)],
        "read": ("SELECT * FROM review_queue(CAST(?tok AS text));", [("tok", "session_token")]),
    },
    {
        "tool": "get_review_case", "flow": "get_review_case_flow", "readonly": True,
        "desc": ("Open one case from the reviewer's team queue: request, status, priority, customer, the lead's statement, "
                 "the AI-prepared agent_brief (unverified), what is requested, the amount_unit and allowed_range (list-price "
                 "changes), the reviewer's own approval limit, facts from Brightpath's records and the decision options. "
                 "Another team's case or an unknown id returns NOT_FOUND."),
        "args": [("session_token", RTOKEN_DESC), ("case_id", "Case id from get_review_queue, e.g. BPR-CASE-000101")],
        "read": ("SELECT * FROM review_case(CAST(?tok AS text), CAST(?cid AS text));",
                 [("tok", "session_token"), ("cid", "case_id")]),
    },
    {
        "tool": "decide_review_case", "flow": "decide_review_case_flow", "readonly": False, "idempotent": False,
        "desc": ("Record the reviewer's decision on a case in their team queue - only after the reviewer explicitly "
                 "confirmed the restated decision. decision is APPROVE or REJECT; amount is the approved new list price in "
                 "dollars for a list-price change (empty = the requested price; ignored for REJECT and other requests); "
                 "internal_note is required (at least 5 characters, never shown to the lead); customer_message is what the "
                 "lead will see. Approving a list-price change changes the price; approving a contract / closing update "
                 "sets the lead's status - both through the system's checks. Returns APPROVED / REJECTED with "
                 "executed_action, or BLOCKED with reason_code NOT_YOUR_TEAM, ALREADY_DECIDED, NOTE_REQUIRED, "
                 "AMOUNT_INVALID, OVER_AUTHORITY (case stays open for a senior reviewer), ACTION_BLOCKED or NOT_FOUND, or "
                 "NOT_REVIEWER." + VERBATIM),
        "args": [("session_token", RTOKEN_DESC),
                 ("case_id", "Case id, e.g. BPR-CASE-000101"),
                 ("decision", "APPROVE | REJECT"),
                 ("amount", "Approved new list price in dollars (list-price changes), or empty"),
                 ("internal_note", "Reviewer's internal note (required, at least 5 characters; never shown to the lead)"),
                 ("customer_message", "Message the lead will see with the outcome")],
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

# Columns that must NEVER appear in any LEAD tool output (asserted by test_rules.py / mcp_smoke.py).
HIDDEN_COLUMNS = {"email", "otp_code", "one_time_code", "internal_note", "agent_brief", "reviewer_id", "approval_limit",
                  "parked_action", "priority", "lead_id", "phone"}
# Columns that must never appear in REVIEWER tool output (minimum necessary).
HIDDEN_FROM_REVIEWER = {"email", "otp_code", "one_time_code", "last_name", "lead_id", "phone"}

# ----------------------------------------------------------------------------------------------------------------------
# A2A agent reference tools (RealEstateAgents). One per agent; each is the agent's ONLY database access.
# Flow: #act_postgresql_query (SELECT * FROM ref_<topic>(CAST(?lookup AS text))) -> #actreturn (rows as JSON text).
# The placeholder is ?lookup, not ?term: a placeholder must not share a name with a result column (Fields list).
# The model can supply only `term` (a word, a section name, or "" for the whole guide); it can never change the SQL.
# The tables hold reference data only (no lead, staff, case, session or contact data) - asserted by test_rules.py.
# ----------------------------------------------------------------------------------------------------------------------
REF_TERM_DESC = ("Optional lookup: one or more words separated by commas (for example a section name or a phrase from "
                 "your input), or an empty string for the whole guide (best). Never put personal details here.")
REF_COLUMNS = ["section", "term", "meaning"]
AGENT_REF_TOOLS = [
    {"agent": "listing_match_agent", "tool": "get_listing_match_guide", "fn": "ref_listing_match",
     "table": "listing_match_guide",
     "sections": ["COLUMN", "WALK_SCORE", "AMENITY", "RANKING", "EXCLUDE", "FAIR_HOUSING", "NOTE_LINE"],
     "desc": ("Reads Brightpath's listing-match guide from the brokerage database: what the listing columns mean, the "
              "walk-score bands, how to grade common amenity wishes (home office, yard, parking), the ranking order, the "
              "exclusion codes, the wishes that are never ranked under Fair Housing, and the standard note lines. Rows of "
              "section, term, meaning. Read-only reference data with no personal data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_listing_match(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "lead_intent_agent", "tool": "get_intent_glossary", "fn": "ref_lead_intent",
     "table": "lead_intent_guide",
     "sections": ["INTENT", "TIMELINE", "PRE_APPROVAL", "MOTIVATION", "RULE", "FIRST_CALL"],
     "desc": ("Reads Brightpath's lead-intent guide from the brokerage database: what each intent, timeline and "
              "pre-approval code means in plain words, how to phrase a motivation, the recording rules, and what a "
              "Brightpath agent prepares for the first call with each kind of lead. Rows of section, term, meaning. "
              "Read-only reference data with no personal data. Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_lead_intent(CAST(?lookup AS text));", [("lookup", "term")])},
    {"agent": "fair_housing_agent", "tool": "get_fair_housing_guide", "fn": "ref_fair_housing",
     "table": "fair_housing_guide",
     "sections": ["PROTECTED", "CATEGORY", "NEUTRAL_ANSWER", "ROUTING", "RULE"],
     "desc": ("Reads Brightpath's Fair Housing guide from the brokerage database: the protected characteristics under the "
              "US Fair Housing Act, the question categories with examples of steering-risk phrasing, the approved "
              "neutral answer for each category (with the objective public source to point to), who reviews a flagged "
              "question, and the rules. Rows of section, term, meaning. Read-only reference data with no personal data. "
              "Pass term \"\" for the whole guide."),
     "args": [("term", REF_TERM_DESC)],
     "read": ("SELECT * FROM ref_fair_housing(CAST(?lookup AS text));", [("lookup", "term")])},
]
