#!/usr/bin/env python3
"""Build ParcelDeliveryAgents.flogo with fda only: ONE A2A agent (delivery_options_agent).
It is an agent because ranking feasible delivery options against the recipient's free-text preferences is
semantic reasoning. It gets the parcel's area + size + constraints + preferences only - never the
recipient's identity - and cannot write anything.
Re-run:  python _rebuild/build_agents.py      (OUT_DIR=<empty dir> to replay)"""
import json, os
from fda_common import App, jtmp, result_columns
from tool_spec import SEARCH_DELIVERY_OPTIONS as T

app = App("ParcelDeliveryAgents.flogo", os.environ.get("OUT_DIR"))
f = app.fda
NAME, PORT = "delivery_options_agent", "9893"
FLOW = f"{NAME}_flow"

ADESC = ("Recommends delivery slots and pickup points for a parcel that needs a new delivery arrangement, from its "
         "area/size/constraints and the recipient's preferences. Read-only: it searches available options and ranks "
         "them; it cannot reschedule or redirect anything.")
SYS = """You recommend delivery options for a parcel that needs a new delivery arrangement. You are given the parcel's
service area, size, whether it needs a signature, whether it is high value, the earliest date a slot may be on, and the
recipient's free-text preferences. You are never given the recipient's identity.

1. Call the search_delivery_options tool exactly once with area, parcel_size, needs_signature, high_value and after_date.
2. From the returned options ONLY, rank up to 3 that best match the recipient's stated preferences (e.g. a particular day
   or time of day, an evening slot, a locker versus a staffed shop, somewhere near a given place). If a preference rules
   an option out, say so. Never include an option the tool did not return.
3. For each pick give: its type (delivery slot or pickup point), its id, when or where it is, and one short sentence on
   why it fits. If the tool returns no options, say clearly there is no available option for this parcel right now.

Never invent slots, pickup points, times or locations. Do not reschedule or redirect - that is confirmed elsewhere.
Reply as a short numbered list."""

print("== project + connections ==")
f("cp", "ParcelDeliveryAgents", "Swiftbound Parcel Delivery governed A2A agent - delivery options (read-only)")
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
f("sa", "trigger", f"{NAME}.settings.temperature", "0", "--type", "number")
f("sa", "trigger", f"{NAME}.settings.enableGuardrails", "true", "--type", "boolean")
f("sa", "trigger", f"{NAME}.settings.rateLimit", "30", "--type", "number")       # OWASP resource-overload: cap requests/min
f("sa", "trigger", f"{NAME}.settings.tokenLimit", "6000", "--type", "number")    # cap inbound tokens per call
f("sa", "trigger", f"{NAME}.settings.redactSensitiveData", "true", "--type", "boolean")
f("sa", "trigger", f"{NAME}.settings.conversationStoreType", "Memory")
f("sa", "trigger", f"{NAME}.settings.memoryMaxSize", "20", "--type", "number")
f("sa", "trigger", f"{NAME}.settings.systemPrompt", SYS)

print("== tool flow search_delivery_options ==")
f("cf", FLOW, T["desc"])
f("ca", FLOW, "SearchOptions", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
f("ca", FLOW, "Return", "act_default_actreturn", "Simple Return")
sql, params = T["read"]
app.bake_pg(FLOW, "SearchOptions", "act_postgresql_query", sql,
            [(p, f"=$flow.toolParams.{a}") for p, a in params], result_columns(sql))
f("mm", f"{FLOW}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[SearchOptions].Output)")

f("cth", FLOW, NAME, T["desc"])
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolName", "search_delivery_options")
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolDescription", T["desc"])
f("wth", FLOW, f"{NAME}.{FLOW}", "--force", "--input", "toolParams:object", "--output", "response:object")
props = {a: {"type": "string", "description": d} for a, d in T["args"]}
req = ["area", "parcel_size"]
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
