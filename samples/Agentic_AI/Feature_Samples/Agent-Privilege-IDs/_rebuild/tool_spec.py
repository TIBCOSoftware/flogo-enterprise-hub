"""Single source of truth for the BankOps MCP tools.

Imported by build_mcp.py (to generate the app) and by test_rules.py (to run the exact same SQL
against PostgreSQL before any app is built).

The agent's privilege ID is NEVER a tool argument. Every statement takes it from the verified JWT
(`$flow.tokenInfo.sub`), so the model cannot claim to be a different agent. Each tool:
  1. GuardedWrite - INSERT INTO agent_audit ... SELECT * FROM <decision fn>(agent, args): always one audit
     row (ALLOWED / DENIED / PENDING_APPROVAL); a trigger applies the side effect only when allowed.
  2. ReadOutcome  - SELECT * FROM <outcome fn>(agent, args): re-checks the agent and says what happened.
`scope` is the JWT scope the Flogo MCP Server trigger requires before it even shows the tool.
No tool declares readOnlyToolHint: even the lookups write an audit row, so none is side-effect free.
"""

# Parameter sources: "sub" / "scopes" come from the verified token, anything else is a tool argument.
TOKEN_SOURCES = {"sub": "=$flow.tokenInfo.sub", "scopes": "=coerce.toString($flow.tokenInfo.scopes)"}

AUDIT_COLS = "agent_audit (agent_id, tool, target, decision, reason, detail)"

TOOLS = [
    {
        "tool": "whoami", "flow": "whoami_flow", "scope": "", "readonly": False,
        "desc": ("Show this agent's own privilege ID as the bank's agent registry sees it: display name, accountable "
                 "owner, status, expiry, the scopes in its token and the tools it is entitled to. Use it when asked "
                 "what you are allowed to do."),
        "args": [],
        "write": (f"INSERT INTO {AUDIT_COLS} SELECT * FROM read_audit_row(CAST(?w_agent AS text), 'whoami', '');",
                  [("w_agent", "sub")]),
        "read": ("SELECT * FROM whoami(CAST(?r_agent AS text), CAST(?r_scopes AS text));",
                 [("r_agent", "sub"), ("r_scopes", "scopes")]),
    },
    {
        "tool": "get_account_summary", "flow": "get_account_summary_flow", "scope": "accounts:read", "readonly": False,
        "desc": ("Get an account's summary: customer name, account type, balance, daily transfer limit, status and its "
                 "cards (card id, type, last 4 digits, status). Returns access DENIED with a reason if this agent is not "
                 "permitted, or NOT_FOUND for an unknown account."),
        "args": [("account_id", "Account id, e.g. ACC-1001")],
        "write": (f"INSERT INTO {AUDIT_COLS} SELECT * FROM read_audit_row(CAST(?w_agent AS text), 'get_account_summary', "
                  "CAST(?w_acct AS text));", [("w_agent", "sub"), ("w_acct", "account_id")]),
        "read": ("SELECT * FROM account_summary(CAST(?r_agent AS text), CAST(?r_acct AS text));",
                 [("r_agent", "sub"), ("r_acct", "account_id")]),
    },
    {
        "tool": "list_recent_transactions", "flow": "list_recent_transactions_flow", "scope": "txns:read", "readonly": False,
        "desc": ("List an account's recent transactions (id, date, description, amount; negative = debit), newest first. "
                 "Returns access DENIED with a reason if this agent is not permitted."),
        "args": [("account_id", "Account id, e.g. ACC-1001")],
        "write": (f"INSERT INTO {AUDIT_COLS} SELECT * FROM read_audit_row(CAST(?w_agent AS text), 'list_recent_transactions', "
                  "CAST(?w_acct AS text));", [("w_agent", "sub"), ("w_acct", "account_id")]),
        "read": ("SELECT * FROM recent_transactions(CAST(?r_agent AS text), CAST(?r_acct AS text));",
                 [("r_agent", "sub"), ("r_acct", "account_id")]),
    },
    {
        "tool": "block_card", "flow": "block_card_flow", "scope": "cards:block", "readonly": False,
        "destructive": True, "idempotent": True,
        "desc": ("Block a lost, stolen or compromised card immediately. The bank's registry re-checks this agent's "
                 "privileges and the card's status. Returns CARD_BLOCKED, or NOT_EXECUTED with the reason. Only call it "
                 "when a staff member asks to block a specific card."),
        "args": [("card_id", "Card id, e.g. CARD-4421"), ("reason", "Why the card is being blocked, in a few words")],
        "write": (f"INSERT INTO {AUDIT_COLS} SELECT * FROM card_block_audit_row(CAST(?w_agent AS text), "
                  "CAST(?w_card AS text), CAST(?w_reason AS text));",
                  [("w_agent", "sub"), ("w_card", "card_id"), ("w_reason", "reason")]),
        "read": ("SELECT * FROM block_card_result(CAST(?r_agent AS text), CAST(?r_card AS text));",
                 [("r_agent", "sub"), ("r_card", "card_id")]),
    },
    {
        "tool": "request_limit_increase", "flow": "request_limit_increase_flow", "scope": "limits:request",
        "readonly": False, "idempotent": False,
        "desc": ("Request a higher daily transfer limit for an account. This NEVER changes the limit: it files an "
                 "approval request that a human supervisor must decide. Policy (cap 100000, must be an increase, one "
                 "pending request per account) is checked by the system. Returns SUBMITTED_FOR_HUMAN_APPROVAL with a "
                 "request_id, or NOT_SUBMITTED with the reason."),
        "args": [("account_id", "Account id, e.g. ACC-1001"),
                 ("new_daily_limit", "Requested daily transfer limit as a plain number, e.g. 25000"),
                 ("justification", "Why the customer needs it, in the staff member's words")],
        "write": (f"INSERT INTO {AUDIT_COLS} SELECT * FROM limit_request_audit_row(CAST(?w_agent AS text), "
                  "CAST(?w_acct AS text), CAST(?w_amt AS text), CAST(?w_why AS text));",
                  [("w_agent", "sub"), ("w_acct", "account_id"), ("w_amt", "new_daily_limit"), ("w_why", "justification")]),
        "read": ("SELECT * FROM limit_request_result(CAST(?r_agent AS text), CAST(?r_acct AS text));",
                 [("r_agent", "sub"), ("r_acct", "account_id")]),
    },
    {
        "tool": "get_request_status", "flow": "get_request_status_flow", "scope": "limits:request", "readonly": False,
        "desc": "Check the status of a limit-change approval request (PENDING, APPROVED or REJECTED) and who decided it.",
        "args": [("request_id", "Approval request id, e.g. APR-1001")],
        "write": (f"INSERT INTO {AUDIT_COLS} SELECT * FROM read_audit_row(CAST(?w_agent AS text), 'get_request_status', "
                  "CAST(?w_req AS text));", [("w_agent", "sub"), ("w_req", "request_id")]),
        "read": ("SELECT * FROM request_status(CAST(?r_agent AS text), CAST(?r_req AS text));",
                 [("r_agent", "sub"), ("r_req", "request_id")]),
    },
]

# The agents (privilege IDs) and the scopes their tokens carry. mint_agent_tokens.py issues the JWTs.
AGENTS = {
    "agt-insight-01":   {"name": "Customer Insight Agent", "scp": ["accounts:read", "txns:read"]},
    "agt-servicing-01": {"name": "Card Servicing Agent",
                         "scp": ["accounts:read", "txns:read", "cards:block", "limits:request"]},
    "agt-legacy-07":    {"name": "Legacy Reporting Agent", "scp": ["accounts:read"]},
    # orchestrated variant: the front-door agent may only call the specialist agents (signed with the SPECIALISTS secret)
    "agt-orchestrator-01": {"name": "Operations Orchestrator", "scp": ["agent:insight", "agent:servicing"]},
}
