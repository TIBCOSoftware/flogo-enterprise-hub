#!/usr/bin/env python3
# =============================================================================
# WORKED-EXAMPLE TEMPLATE - Airline Passenger Services (Meridian) governed use case.
#
# This is a proven, runnable reference driver from the Airline Passenger Services
# worked example. To build your own governed use case, copy the whole _rebuild/
# folder into <YourUseCase>/_rebuild/ and ADAPT it (keep the logic - the value is a
# working reference - just change):
#   - app names / prefix       (PassengerServices... -> <YourUseCase>...)
#   - the tool_spec.py entries  (tools, args, SQL: scoped reads + guarded writes)
#   - ports / endpoint paths    (9850 / 9852 / 9853, /passenger-services-gov-mcp, ...)
#   - the test assertions       (test_rules.py / mcp_smoke.py / chat_e2e.py expectations)
#
# References (relative to this file):
#   ..\..\references\fda-build-recipes.md  - the fda-only build driver pattern
#   ..\..\references\governed-patterns.md  - scoped reads / guarded writes / safe prompts
#   ..\..\references\testing-ladder.md     - the SQL -> MCP -> chat test ladder
#
# No secrets here: credentials are read at RUN time from config.md / env (see fda_common.py).
# =============================================================================
"""Build PassengerServicesAgents.flogo with fda only: ONE A2A agent (rebooking_options_agent).
It is an agent because ranking replacement flights against the traveller's free-text preferences is
semantic reasoning. It gets the route + earliest-departure cutoff + preferences only - never the
traveller's identity - and cannot write anything.
Re-run:  python _rebuild/build_agents.py      (OUT_DIR=<empty dir> to replay)"""
import json, os
from fda_common import App, jtmp, result_columns
from tool_spec import SEARCH_ALTERNATIVES as T

app = App("PassengerServicesAgents.flogo", os.environ.get("OUT_DIR"))
f = app.fda
NAME, PORT = "rebooking_options_agent", "9853"
FLOW = f"{NAME}_flow"

ADESC = ("Recommends replacement flights for a disrupted leg from the route, an earliest-departure cutoff and the "
         "traveller's preferences. Read-only: it searches available flights and ranks them; it cannot rebook anything.")
SYS = """You recommend replacement flights for a traveller whose connection is at risk or missed. You are given the
route (origin and destination airport codes), the earliest_departure a replacement must leave after, the preferred
cabin, and the traveller's free-text preferences. You are never given the traveller's identity.

1. Call the search_alternatives tool exactly once with origin, destination, earliest_departure and cabin.
2. From the returned flights ONLY, rank up to 3 that best match the traveller's stated preferences (e.g. arrive
   before a certain time, prefer a cabin, avoid a late-night/red-eye arrival, shortest trip). If a preference rules a
   flight out, say so. Never include a flight the tool did not return.
3. For each pick give: flight_number, departure time, arrival time, seats_available, cabin and one short sentence on
   why it fits. If the tool returns no flights, say clearly there is no same-day alternative on this route.

Never invent flights, times or seats. Do not rebook - that is confirmed elsewhere. Reply as a short numbered list."""

print("== project + connections ==")
f("cp", "PassengerServicesAgents", "Meridian Passenger Services governed A2A agent - rebooking options (read-only)")
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

print("== tool flow search_alternatives ==")
f("cf", FLOW, T["desc"])
f("ca", FLOW, "SearchAlternatives", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
f("ca", FLOW, "Return", "act_default_actreturn", "Simple Return")
sql, params = T["read"]
app.bake_pg(FLOW, "SearchAlternatives", "act_postgresql_query", sql,
            [(p, f"=$flow.toolParams.{a}") for p, a in params], result_columns(sql))
f("mm", f"{FLOW}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[SearchAlternatives].Output)")

f("cth", FLOW, NAME, T["desc"])
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolName", "search_alternatives")
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolDescription", T["desc"])
f("wth", FLOW, f"{NAME}.{FLOW}", "--force", "--input", "toolParams:object", "--output", "response:object")
props = {a: {"type": "string", "description": d} for a, d in T["args"]}
req = ["origin", "destination", "earliest_departure"]
f("cs", f"{NAME}_ToolParams", json.dumps({"type": "object", "properties": props, "required": req}))
f("sa", "handler", f"{NAME}.{FLOW}.schemas.output.toolParams", f"{NAME}_ToolParams", "-C", "schema", "--force")
f("cs", f"{NAME}_Resp", '{"type":"object","properties":{"data":{"type":"string"}}}')
f("sa", "handler", f"{NAME}.{FLOW}.schemas.reply.response", f"{NAME}_Resp", "-C", "schema", "--force")

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
