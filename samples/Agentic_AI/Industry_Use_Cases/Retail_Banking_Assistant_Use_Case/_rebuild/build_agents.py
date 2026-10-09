#!/usr/bin/env python3
"""Build RetailBankingAgents.flogo with fda only: ONE A2A agent (dispute_triage_agent).
It is an agent because decoding a cryptic card-statement descriptor and matching the customer's own words
to one of several candidate transactions is semantic reasoning. It gets the customer's words + the candidate
transactions (transaction_id, descriptor, amount, date) only - never the customer's identity - and cannot
write anything. Eligibility, provisional credit and filing are decided later by SQL (propose/confirm_dispute).
Re-run:  python _rebuild/build_agents.py      (OUT_DIR=<empty dir> to replay)"""
import json, os
from fda_common import App, jtmp, result_columns
from tool_spec import LOOKUP_MERCHANT as T

app = App("RetailBankingAgents.flogo", os.environ.get("OUT_DIR"))
f = app.fda
NAME, PORT = "dispute_triage_agent", "9863"
FLOW = f"{NAME}_flow"
TOOL = "lookup_merchant"

ADESC = ("Triages a card or account charge the customer questions: decodes cryptic statement descriptors into the real "
         "merchant, picks the candidate transaction that best matches the customer's words, explains how the merchant "
         "bills (one-off or recurring) and recommends one dispute reason code and whether a card block is advisable. "
         "Read-only: it looks up the merchant directory; it cannot file, approve or change anything.")
SYS = """You help triage a card or account charge that a Kestrel Bank customer does not recognise or wants to question.
You are given the customer's own words and a list of candidate transactions, each with transaction_id, descriptor,
amount and date only. You are never given the customer's identity, and you never ask for or use a name, customer id,
account or card number, passcode or session token.

1. For each distinct descriptor among the candidates, call the lookup_merchant tool with the descriptor text exactly as
   it appears. Use only what the tool returns to say who the merchant is; if it returns NO_MATCH, say the merchant could
   not be identified from the descriptor.
2. Pick the ONE candidate transaction that best matches the customer's words (amount, date, merchant, what they
   describe). If two candidates fit equally well, say which detail (e.g. the amount) would tell them apart.
3. Explain in plain words who the merchant really is, what it sells, and how it bills: ONE_OFF or RECURRING, plus any
   billing notes and the support contact the tool returned.
4. Recommend exactly ONE reason_code from this list: UNRECOGNISED, FRAUD, DUPLICATE, NOT_RECEIVED, NOT_AS_DESCRIBED,
   CANCELLED_RECURRING, WRONG_AMOUNT. If the right code hinges on whether the customer cancelled a recurring service or
   never signed up for it, do not guess: give the single question to ask the customer instead.
5. Say whether blocking the card is advisable: yes when there are fraud signals (the customer never authorised the
   charge, does not recognise the merchant, or reports a lost or stolen card); otherwise no.

You never file a dispute, approve anything, or promise a refund, credit, outcome or timeline. Whether the charge can
be disputed and any provisional credit are decided later by the bank's system, so never say the charge is eligible.
Never invent merchants, transactions or amounts.

Reply in this short format:
transaction_id: <id>
merchant: <who it is and what it sells>
billing: <ONE_OFF or RECURRING, with a short note>
reason_code: <one code> (or question: <the one question to ask>)
card_block_advisable: <yes or no> - <one short reason>"""

print("== project + connections ==")
f("cp", "RetailBankingAgents", "Kestrel Bank Retail Banking governed A2A agent - dispute triage (read-only)")
app.llm_connection()
app.postgres_connection()
f("cap", f"{NAME}_PORT", "string", PORT)
f("cap", f"{NAME}_URL", "string", f"http://localhost:{PORT}")

print(f"== agent {NAME} ==")
f("ct", NAME, "tr_agent", ADESC)
f("sa", "trigger", f"{NAME}.settings.llmProviderConnection", "OpenAIConn", "-C", "connection")
f("sa", "trigger", f"{NAME}.settings.agentName", NAME)
f("sa", "trigger", f"{NAME}.settings.agentDescription", ADESC)
f("sa", "trigger", f"{NAME}.settings.agentType", "A2A Server")
f("sa", "trigger", f"{NAME}.settings.agentPort", f"{NAME}_PORT", "-C", "app-property")
f("sa", "trigger", f"{NAME}.settings.agentUrl", f"{NAME}_URL", "-C", "app-property")
f("sa", "trigger", f"{NAME}.settings.model", "LLM_Model", "-C", "app-property")
f("sa", "trigger", f"{NAME}.settings.temperature", "0", "--type", "number")       # 0 = omitted (gpt-5.x rejects others)
f("sa", "trigger", f"{NAME}.settings.enableGuardrails", "true", "--type", "boolean")
f("sa", "trigger", f"{NAME}.settings.rateLimit", "30", "--type", "number")       # OWASP resource-overload: cap requests/min
f("sa", "trigger", f"{NAME}.settings.tokenLimit", "6000", "--type", "number")    # cap inbound tokens per call
f("sa", "trigger", f"{NAME}.settings.redactSensitiveData", "true", "--type", "boolean")
f("sa", "trigger", f"{NAME}.settings.conversationStoreType", "Memory")
f("sa", "trigger", f"{NAME}.settings.memoryMaxSize", "20", "--type", "number")
f("sa", "trigger", f"{NAME}.settings.systemPrompt", SYS)

print(f"== tool flow {TOOL} ==")
f("cf", FLOW, T["desc"])
f("ca", FLOW, "LookupMerchant", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
f("ca", FLOW, "Return", "act_default_actreturn", "Simple Return")
sql, params = T["read"]
app.bake_pg(FLOW, "LookupMerchant", "act_postgresql_query", sql,
            [(p, f"=$flow.toolParams.{a}") for p, a in params], result_columns(sql))
f("mm", f"{FLOW}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[LookupMerchant].Output)")

f("cth", FLOW, NAME, T["desc"])
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolName", TOOL)
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolDescription", T["desc"])
f("wth", FLOW, f"{NAME}.{FLOW}", "--force", "--input", "toolParams:object", "--output", "response:object")
props = {a: {"type": "string", "description": d} for a, d in T["args"]}
req = ["descriptor"]
# INLINE schemas: the AI Agent Trigger reads toolParams only inline - a schema:// reference gives the LLM a
# tool with NO parameters (FGAI-155). The MCP Server trigger resolves references; this trigger does not.
_tp = json.dumps({"type": "object", "properties": props, "required": req})
f("sa", "handler", f"{NAME}.{FLOW}.schemas.output.toolParams", "--jsonValue",
  json.dumps({"type": "json", "value": _tp, "fe_metadata": _tp}), "--force")
_rs = '{"type":"object","properties":{"data":{"type":"string"}}}'
f("sa", "handler", f"{NAME}.{FLOW}.schemas.reply.response", "--jsonValue",
  json.dumps({"type": "json", "value": _rs, "fe_metadata": _rs}), "--force")

compact = json.dumps({a: {"type": "string"} for a, _ in T["args"]})
f("sa", "flow", f"{FLOW}.metadata.input", "--jsonFile",
  jtmp([{"name": "toolParams", "type": "object", "schema": {"type": "json", "value": compact}}]), "--force")
f("sa", "flow", f"{FLOW}.metadata.output", "--jsonFile",
  jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": '{"data":{"type":"string"}}'}}]), "--force")
fe_in = {"type": "object", "title": NAME, "properties": {"toolParams": {"type": "object", "properties": props, "required": req}}}
fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": {"data": {"type": "string"}}}}, "required": []}
f("sa", "flow", f"{FLOW}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
f("sa", "flow", f"{FLOW}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

print("\nA2A build complete:", app.file)
