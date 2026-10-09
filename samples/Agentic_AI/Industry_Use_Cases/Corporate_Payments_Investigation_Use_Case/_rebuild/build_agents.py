#!/usr/bin/env python3
"""Build CorporatePaymentsAgents.flogo with fda only: ONE A2A agent (payment_triage_agent).
It is an agent because decoding a cryptic payment return/reason code and matching the client's own words
to one of several candidate payments is semantic reasoning. It gets the client's words + the candidate
payments (payment_ref, direction, rail, amount, currency, beneficiary_name, status, return_reason_code,
value_date, created_at) only - never the client's identity - and cannot write anything. Eligibility,
trace/recall and every state change are decided later by SQL (propose/confirm_trace, propose/confirm_recall).
Re-run:  python _rebuild/build_agents.py      (OUT_DIR=<empty dir> to replay)"""
import json, os
from fda_common import App, jtmp, result_columns
from tool_spec import LOOKUP_REASON_CODE as T

app = App("CorporatePaymentsAgents.flogo", os.environ.get("OUT_DIR"))
f = app.fda
NAME, PORT = "payment_triage_agent", "9873"
FLOW = f"{NAME}_flow"
TOOL = "lookup_reason_code"

ADESC = ("Triages a payment an Aurelia Global Bank corporate client is questioning: decodes cryptic return/reason "
         "codes into plain language, picks the candidate payment that best matches the client's words, classifies the "
         "issue with an urgency and recommends one next step (raise a trace, request a recall or open a human review "
         "case). Read-only: it looks up the reason-code directory; it cannot trace, recall, file or change anything.")
SYS = """You help triage a payment that an Aurelia Global Bank corporate client is asking about. You are given the
client's own words and a list of candidate payments, each with payment_ref, direction, rail, amount, currency,
beneficiary_name, status, return_reason_code, value_date and created_at only. You are never given the client's
identity, and you never ask for or use a legal name, client id, account number, passcode or session token.

1. When a candidate payment has a return_reason_code, call the lookup_reason_code tool with that code exactly as it
   appears. Use only what the tool returns to explain what the code means; if it returns NO_MATCH, say the code could
   not be decoded from the directory.
2. Pick the ONE candidate payment that best matches the client's words (payment_ref, amount, currency, beneficiary,
   rail, date, status, and what they describe). If two candidates fit equally well, say which detail (e.g. the amount
   or the beneficiary) would tell them apart.
3. Classify the issue as exactly ONE of: RETURNED_ACCOUNT_ISSUE, WRONG_BENEFICIARY, DELAYED_IN_TRANSIT,
   COMPLIANCE_HOLD, DUPLICATE or OTHER, and give an urgency of LOW, MEDIUM or HIGH based on the amount, the status and
   how time-sensitive the problem is.
4. Recommend exactly ONE next step: raise a trace (for a delayed or missing payment), request a recall (for funds
   sent to the wrong party or an erroneous payment) or open a human review case (for a compliance hold, suspected
   fraud, a fee dispute or anything a person must own). If the right step hinges on the client's intent, do not guess:
   give the single question to ask instead (for example, "did the funds reach the wrong party, or not arrive at all?").

You never raise a trace, request a recall, open a case, file anything, approve anything or promise a refund, recall,
outcome or timeline. Whether a payment can be traced or recalled is decided later by the bank's system, so never say a
payment is eligible. Never invent payments, codes, amounts or beneficiaries.

Reply in this short format:
payment_ref: <ref>
reason_code: <code decoded into plain language> (or none if the payment has no return/reason code)
issue: <one classification> - urgency <LOW, MEDIUM or HIGH>
next_step: <raise a trace | request a recall | open a human review case> (or question: <the one question to ask>)"""

print("== project + connections ==")
f("cp", "CorporatePaymentsAgents", "Aurelia Global Bank corporate-payments governed A2A agent - payment triage (read-only)")
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
f("ca", FLOW, "LookupReasonCode", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
f("ca", FLOW, "Return", "act_default_actreturn", "Simple Return")
sql, params = T["read"]
app.bake_pg(FLOW, "LookupReasonCode", "act_postgresql_query", sql,
            [(p, f"=$flow.toolParams.{a}") for p, a in params], result_columns(sql))
f("mm", f"{FLOW}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[LookupReasonCode].Output)")

f("cth", FLOW, NAME, T["desc"])
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolName", TOOL)
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolDescription", T["desc"])
f("wth", FLOW, f"{NAME}.{FLOW}", "--force", "--input", "toolParams:object", "--output", "response:object")
props = {a: {"type": "string", "description": d} for a, d in T["args"]}
req = ["code"]
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
